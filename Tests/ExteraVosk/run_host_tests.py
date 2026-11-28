"""Prepare/run exact production Foundation, ZIP and model-store sources on macOS.

No SDK/model/network downloads. Native C calls are replaced only in the host
test target; this does not test the iOS Vosk binary or audio converter.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[2]


def emit(base):
    settings = base / 'Sources/SGSimpleSettings'
    core = base / 'Sources/VoskCore'
    native = base / 'Sources/CVosk'
    tests = base / 'Sources/HostTests'
    for p in [settings, core, native / 'include', tests]:
        p.mkdir(parents=True, exist_ok=True)
    for name in ['AyuSettingsStore', 'ExteraTranslationSettings', 'ExteraSpeechSettings', 'ExteraVoskSettings']:
        shutil.copyfile(ROOT / f'AyuGram/SGSimpleSettings/Sources/{name}.swift', settings / f'{name}.swift')
    (settings / 'HostEnvironment.swift').write_text('''import Foundation
let APP_GROUP_IDENTIFIER = "org.ayugram.tests.vosk." + UUID().uuidString
final class SGSimpleSettings: @unchecked Sendable {
    static let shared = SGSimpleSettings()
    enum TranscriptionBackend: String { case apple, telegram }
    var transcriptionBackend = TranscriptionBackend.telegram.rawValue
}
''', encoding='utf-8')
    linux_host = sys.platform.startswith('linux')
    if linux_host:
        (core / 'HostPlatformCompatibility.swift').write_text('''import Foundation
import FoundationNetworking

// The production store asks Apple Foundation for this capacity value. Linux
// Foundation exposes the corresponding volume-capacity resource under its
// general key, so keep the production call unchanged in the host projection.
extension URLResourceKey {
    static var volumeAvailableCapacityForImportantUsageKey: URLResourceKey { .volumeAvailableCapacityKey }
}
extension URLResourceValues {
    var volumeAvailableCapacityForImportantUsage: Int? { self.volumeAvailableCapacity }
}
''', encoding='utf-8')
    for path in (ROOT / 'submodules/Media/VoskSpeech/Sources').glob('*.swift'):
        if path.name != 'VoskTranscription.swift':
            destination = core / path.name
            source = path.read_text(encoding='utf-8')
            # CryptoKit is an Apple SDK module. Swift Crypto exposes the same
            # SHA-256 API for this Linux-only host projection; production source
            # remains unchanged and the iOS target keeps CryptoKit.
            if linux_host:
                if path.name == 'VoskModelStore.swift':
                    source = source.replace('import CryptoKit', 'import Crypto', 1)
                if path.name == 'VoskRecognizer.swift':
                    source = source.replace('import Darwin', 'import Glibc', 1)
                if path.name == 'VoskDownload.swift':
                    source = source.replace('import Foundation\n', 'import Foundation\nimport FoundationNetworking\n', 1)
            destination.write_text(source, encoding='utf-8')
    # @testable imports need a library compiled with testing enabled.
    shutil.copyfile(ROOT / 'submodules/VoskNative/Sources/VoskInflate.c', native / 'VoskInflate.c')
    for name in ['VoskInflate.h', 'vosk_api.h']:
        shutil.copyfile(ROOT / 'submodules/VoskNative/include' / name, native / 'include' / name)
    (native / 'include/CVosk.h').write_text('#include "VoskInflate.h"\n#include "vosk_api.h"\n', encoding='utf-8')
    shutil.copyfile(ROOT / 'Tests/ExteraVosk/NativeHostStub.c', native / 'NativeHostStub.c')
    shutil.copyfile(ROOT / 'Tests/ExteraVosk/HostTests.swift', tests / 'HostTests.swift')
    fixture = base / 'fixtures'
    fixture.mkdir(exist_ok=True)
    model_name = 'vosk-model-test'
    files = {'am/final.mdl': b'test-model\n' * 300000, 'conf/model.conf': b'--sample-frequency=16000\n', 'graph/words.txt': b'hello 1\n'}
    cases = {
        'valid': [(model_name + '/' + name, data) for name, data in files.items()],
        'traversal': [(model_name + '/../escape', b'escape')],
        'absolute': [('/escape', b'escape')],
        'backslash': [(model_name + '/..\\escape', b'escape')],
        'duplicate': [(model_name + '/am/final.mdl', b'a'), (model_name + '/AM/FINAL.MDL', b'b')],
        'file-parent': [(model_name + '/am', b'a'), (model_name + '/am/final.mdl', b'b')],
        'extra-root': [('other/am/final.mdl', b'a')],
        'symlink': [(model_name + '/am/final.mdl', b'../../outside')],
    }
    manifest = []
    for name, items in cases.items():
        path = fixture / (name + '.zip')
        with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            for entry, data in items:
                if name == 'symlink':
                    info = zipfile.ZipInfo(entry)
                    info.create_system = 3
                    info.external_attr = 0o120777 << 16
                    archive.writestr(info, data)
                else:
                    archive.writestr(entry, data)
        with zipfile.ZipFile(path) as archive:
            entries = archive.infolist()
        manifest.append({'fixture': name, 'path': str(path), 'name': model_name,
                         'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                         'archiveBytes': path.stat().st_size, 'expandedBytes': sum(e.file_size for e in entries),
                         'largestEntryBytes': max(e.file_size for e in entries), 'entryCount': len(entries)})
    (fixture / 'manifest.json').write_text(json.dumps(manifest), encoding='utf-8')
    crypto_path = os.environ.get('SWIFT_CRYPTO_PATH')
    crypto_dependency = ''
    crypto_target_dependency = ''
    if crypto_path:
        crypto_path = str(Path(crypto_path).resolve())
        crypto_dependency = f'\n    dependencies: [.package(path: {json.dumps(crypto_path)})],'
        crypto_target_dependency = ', .product(name: "Crypto", package: "swift-crypto")'
    elif linux_host:
        crypto_dependency = '\n    dependencies: [.package(url: "https://github.com/apple/swift-crypto.git", exact: "3.12.3")],'
        crypto_target_dependency = ', .product(name: "Crypto", package: "swift-crypto")'
    (base / 'Package.swift').write_text(f'''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "ExteraVoskHost", platforms: [.macOS(.v13)],{crypto_dependency} targets: [
    .target(name: "SGSimpleSettings"),
    .target(name: "CVosk", publicHeadersPath: "include", linkerSettings: [.linkedLibrary("z")]),
    .target(name: "VoskCore", dependencies: ["CVosk", "SGSimpleSettings"{crypto_target_dependency}], swiftSettings: [.unsafeFlags(["-enable-testing", "-warnings-as-errors"])]),
    .executableTarget(name: "HostTests", dependencies: ["VoskCore", "SGSimpleSettings"]),
])
''', encoding='utf-8')
    return fixture / 'manifest.json'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--emit-only', action='store_true')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    parent = Path(os.environ['LOCALAPPDATA']) / 'Temp/opencode' if os.name == 'nt' else Path(tempfile.gettempdir())
    base = args.output or Path(tempfile.mkdtemp(prefix='extera-vosk-host-', dir=parent))
    manifest = emit(base)
    print('Exact-source host harness emitted: ' + str(base), flush=True)
    if args.emit_only:
        print('EMITTED ONLY; Swift tests not executed')
        return
    swift = shutil.which('swift')
    if not swift:
        raise SystemExit('BLOCKED: Swift toolchain absent; use --emit-only')
    subprocess.run([swift, 'run', '--package-path', str(base), 'HostTests', str(manifest)], check=True, timeout=180)


if __name__ == '__main__':
    main()
