"""Run the production icon selection model and its existing XCTest suite on a Swift host.

The test's app-module import is removed because the verbatim production source is
compiled directly into the temporary host target. Only unrelated application bindings
are supplied; no persistence/normalization logic is replaced.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import base64
import io
import json
import shutil
import struct
import zipfile
import zlib


def archive(entries, method=zipfile.ZIP_STORED, level=None):
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w", compression=method, compresslevel=level) as output:
        for name, data in entries:
            output.writestr(name, data)
    return stream.getvalue()


def fixture_source():
    metadata = json.dumps({"packId": "custom.fixture", "packName": "Fixture", "icons": {"msg_copy": "icons/copy.svg"}}).encode()
    image = b"<svg viewBox='0 0 24 24'><path d='M2 2 L22 2 L12 22 Z' fill='#fff'/></svg>"
    entries = [("metadata.json", metadata), ("icons/copy.svg", image)]
    # Java ZipOutputStream (Android export level 0) sets bit 3 and writes data descriptors.
    class NonSeekable(io.BytesIO):
        def seekable(self):
            return False
        def seek(self, *args):
            raise io.UnsupportedOperation()
    stream = NonSeekable()
    with zipfile.ZipFile(stream, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=0) as output:
        for name, data in entries:
            output.writestr(name, data)
    valid = [archive(entries), archive(entries, zipfile.ZIP_DEFLATED, 9), stream.getvalue()]
    # Force dynamic and fixed Huffman trees independently of Python ZIP's chosen heuristics.
    for strategy in [zlib.Z_FIXED, zlib.Z_DEFAULT_STRATEGY]:
        payload = bytes((i * 13 + i // 17) % 256 for i in range(24000))
        compressor = zlib.compressobj(6, zlib.DEFLATED, -15, strategy=strategy)
        compressed = compressor.compress(payload) + compressor.flush()
        name = b"extra.bin"
        crc = zlib.crc32(payload)
        local = struct.pack("<IHHHHHIIIHH", 0x04034b50, 20, 0, 8, 0, 33, crc, len(compressed), len(payload), len(name), 0) + name + compressed
        central = struct.pack("<IHHHHHHIIIHHHHHII", 0x02014b50, 20, 20, 0, 8, 0, 33, crc, len(compressed), len(payload), len(name), 0, 0, 0, 0, 0, 0) + name
        valid.append(local + central + struct.pack("<IHHHHIIH", 0x06054b50, 0, 0, 1, 1, len(central), len(local), 0))
    invalid = {
        "traversal": archive(entries + [("../escape", b"x")]),
        "absolute": archive(entries + [("/absolute", b"x")]),
        "backslash": archive(entries + [("x\\y", b"x")]),
        "case collision": archive(entries + [("A", b"a"), ("a", b"b")]),
        "directory file collision": archive(entries + [("path", b"x"), ("path/file", b"y")]),
        "compression bomb": archive(entries + [("bomb", b"x" * 100000)], zipfile.ZIP_DEFLATED, 9),
        "too many entries": archive([(f"x{i}", b"") for i in range(3001)]),
        "truncated": valid[0][:-3],
    }
    corrupt = bytearray(valid[0]); corrupt[45] ^= 1; invalid["CRC"] = bytes(corrupt)
    encrypted = bytearray(valid[0]); encrypted[6] |= 1; invalid["encrypted"] = bytes(encrypted)
    method = bytearray(valid[0]); method[8] = 99; invalid["unknown method"] = bytes(method)
    link = zipfile.ZipInfo("symlink"); link.create_system = 3; link.external_attr = 0o120777 << 16
    invalid["symlink"] = archive(entries + [(link, b"/outside")])
    def literal(data):
        return 'Data(base64Encoded: "' + base64.b64encode(data).decode() + '")!'
    return "import Foundation\nenum UIIconArchiveFixtures {\n" + \
        "static let metadata = " + literal(metadata) + "\nstatic let image = " + literal(image) + \
        "\nstatic let valid = [" + ",\n".join(literal(data) for data in valid[:3]) + \
        "]\nstatic let streams = [" + ",\n".join(literal(data) for data in valid[3:]) + \
        "]\nstatic let invalid: [String: Data] = [" + ",\n".join(json.dumps(key) + ": " + literal(data) for key, data in invalid.items()) + "]\n}\n"


def swift_host_environment():
    """Find the Linux Swift toolchain even when the WSL login PATH has no swift."""
    override = os.environ.get("EXTERA_SWIFT_PATH")
    candidates = []
    if override:
        candidates.append(Path(override))
    found = shutil.which("swift")
    if found:
        candidates.append(Path(found))
    candidates.extend(Path("/mnt/c/Users").glob(
        "*/AppData/Local/Temp/opencode/ui-icons-swift/swift-*/usr/bin/swift"
    ))
    swift = next((path for path in candidates if path.is_file()), None)
    if swift is None:
        raise RuntimeError(
            "Swift host toolchain not found. Set EXTERA_SWIFT_PATH to the swift "
            "executable, for example /mnt/c/Users/PC/AppData/Local/Temp/opencode/"
            "ui-icons-swift/swift-6.1.2-RELEASE-ubuntu24.04/usr/bin/swift."
        )
    environment = os.environ.copy()
    environment["PATH"] = str(swift.parent) + os.pathsep + environment.get("PATH", "")

    # The downloaded Ubuntu toolchain uses the checked-out support libraries. Do
    # not overwrite caller-provided paths; prepend the known support locations.
    toolchain_root = swift.parent.parent.parent
    support_root = toolchain_root.parent / "support"
    support_lib = support_root / "usr/lib/x86_64-linux-gnu"
    support_include = support_root / "usr/include/c++/15"
    support_target_include = support_root / "usr/include/x86_64-linux-gnu/c++/15"
    if support_lib.is_dir():
        environment["LD_LIBRARY_PATH"] = str(support_lib) + os.pathsep + environment.get("LD_LIBRARY_PATH", "")
        environment["LIBRARY_PATH"] = str(support_lib) + os.pathsep + environment.get("LIBRARY_PATH", "")
    include_paths = [path for path in (support_include, support_target_include) if path.is_dir()]
    if include_paths:
        environment["CPLUS_INCLUDE_PATH"] = os.pathsep.join(map(str, include_paths)) + os.pathsep + environment.get("CPLUS_INCLUDE_PATH", "")
    return str(swift), environment


def main():
    repo = Path(__file__).resolve().parents[2]
    temporary_root = Path(os.environ["LOCALAPPDATA"]) / "Temp/opencode" if sys.platform == "win32" else None
    with tempfile.TemporaryDirectory(prefix="extera-ui-icons-tests-", dir=temporary_root) as directory:
        output = Path(directory)
        bindings = output / "ApplicationBindings.swift"
        bindings.write_text('''import Foundation
let APP_GROUP_IDENTIFIER = "ExteraUIIconHostTests." + UUID().uuidString
let ayuSettingsDidChangeNotification = Notification.Name("ExteraUIIconHostSettingsChanged")
enum SGSimpleSettings { static let shared = 0 }
''', encoding="utf-8")
        test = output / "ExteraUIIconSettingsTests.swift"
        source = repo / "Swiftgram/SGSimpleSettings/Tests/ExteraUIIconSettingsTests.swift"
        test.write_text(source.read_text(encoding="utf-8").replace("import SGSimpleSettings\n", ""), encoding="utf-8")
        fixtures = output / "UIIconArchiveFixtures.swift"
        fixtures.write_text(fixture_source(), encoding="utf-8")
        sources = [
            repo / "Swiftgram/SGSimpleSettings/Sources/ExteraUIIconSettings.swift",
            repo / "Swiftgram/SGSimpleSettings/Sources/ExteraUIIconArchive.swift",
            repo / "Swiftgram/SGSimpleSettings/Sources/ExteraUIIconPackStore.swift",
            repo / "Swiftgram/SGSimpleSettings/Sources/ExteraUIIconVector.swift",
            repo / "Tests/ExteraUIIcons/ExteraUIIconPackStoreTests.swift",
            bindings, test, fixtures,
        ]
        if sys.platform.startswith("linux"):
            # CryptoKit is an Apple SDK module; Swift Crypto supplies the same SHA-256 on Linux.
            for path in sources:
                if path.parent != output:
                    shutil.copy2(path, output / path.name)
            manifest = '''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "UIIconHostTests", dependencies: [.package(url: "https://github.com/apple/swift-crypto.git", exact: "3.12.3")], targets: [.testTarget(name: "UIIconHostTests", dependencies: [.product(name: "Crypto", package: "swift-crypto")], path: ".", exclude: ["Package.swift"])], swiftLanguageVersions: [.v5])
'''
            (output / "Package.swift").write_text(manifest, encoding="utf-8")
            scratch = ["--scratch-path", os.environ["EXTERA_UI_ICON_TEST_BUILD"]] if "EXTERA_UI_ICON_TEST_BUILD" in os.environ else []
            swift, environment = swift_host_environment()
            return subprocess.run([swift, "test", "--package-path", str(output), *scratch, "--jobs", "4", "-Xswiftc", "-warnings-as-errors"], env=environment).returncode
        return subprocess.run([
            sys.executable, str(repo / "tools/run_extera_xctests.py"), "--warnings-as-errors",
            *map(str, sources),
        ], cwd=repo).returncode


if __name__ == "__main__":
    raise SystemExit(main())
