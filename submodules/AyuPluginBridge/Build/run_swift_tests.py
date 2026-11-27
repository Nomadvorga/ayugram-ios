#!/usr/bin/env python3
"""Build Tests/Swift into an XCTest bundle and run it on this Mac, without a simulator.

No Bazel, no xcodebuild, no app or IPA. The dependency modules, the bridge module and
the tests are compiled for the product's own target (arm64 iOS, iPhoneOS SDK) and linked
into an iOS test bundle. A copy of that bundle is retagged as Mac Catalyst with `vtool`
and ad-hoc signed, and Xcode's `xctest` runs it with `DYLD_FORCE_PLATFORM=6`, so UIKit
comes from the macOS iOSSupport frameworks. The retagged bundle exists only in the
scratch directory and is never shipped.

The Objective-C runtime (`ObjC/APBPythonRuntime.m`) is compiled unchanged against the
framework build of CPython that runs this script (it must be the version the runtime
embeds). The iOS link sees that interpreter through a generated text stub; at run time
the unmodified macOS library is loaded, which dyld allows in a Catalyst process. The
bundle carries the two resource bundles of the app (`AyuPythonResources.bundle` with a
copy of that interpreter's standard library, `AyuPluginSDK.bundle` with `Python/`), so the
end-to-end tests start Python through `AyuPluginService` exactly as the app does. The
pinned third-party distributions are not part of it.

The tests run with HOME and CFFIXED_USER_HOME inside the scratch directory. The preferences
daemon ignores that, so the `UserDefaults(suiteName:)` domains the tests create land in the
real ~/Library/Preferences; the ones that appear during the run are deleted afterwards.

    python3 -B submodules/AyuPluginBridge/Build/run_swift_tests.py
        [--only Class[/testName] ...] [--scratch DIR] [--verbose] [--timeout SECONDS]
        [--python-traceback] [--capabilities FILE]

`--capabilities FILE` writes the `runtime.capabilities` result of the host composed like
`AyuPluginService.shared` (application bridge, menu provider, application class registry,
no Telegram backend bound) to FILE, for
`python3 -X utf8 -B -m tools.plugin_inspector preflight-corpus --capabilities FILE`.
Without `--only` it runs just the test that produces the file.

The runtime never prints Python errors (plugin source may hold credentials). To see why
the interpreter failed, `--python-traceback` compiles a scratch copy of the runtime that
prints the traceback instead of discarding it (with the complete xctest output); that run
is for diagnosis only.

Exit status: 0 when every executed test passed, 1 on a test failure or crash, 2 when the
bundle could not be built.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import sysconfig
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import typecheck_swift as harness  # noqa: E402

BRIDGE = harness.BRIDGE
SUBMODULES = harness.SUBMODULES
BUNDLE = "AyuPluginBridgeTests"
CATALYST_PLATFORM = "6"
CAPABILITIES_TEST = "AyuPluginEndToEndCapabilitiesTests"
STDLIB_EXCLUDED = ("__pycache__", "test", "site-packages", "config-*", "idlelib", "tkinter", "turtledemo", "ensurepip")
TEST_SUITE_PREFERENCES = re.compile(
    r"Ayu[A-Za-z]*Tests\.(?:[A-Za-z]+\.)?[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}\.plist")


class BuildFailure(Exception):
    pass


def embedded_python_version() -> str:
    source = (BRIDGE / "ObjC" / "APBPythonRuntime.m").read_text(encoding="utf-8")
    match = re.search(r"lib/python(3\.\d+)/encodings", source)
    if not match:
        raise BuildFailure("Cannot read the embedded Python version from ObjC/APBPythonRuntime.m.")
    return match.group(1)


def host_python() -> tuple[Path, Path, Path]:
    """Framework search directory, library and home of the interpreter running this script."""
    wanted = embedded_python_version()
    running = f"{sys.version_info.major}.{sys.version_info.minor}"
    frameworks = sysconfig.get_config_var("PYTHONFRAMEWORKPREFIX")
    name = sysconfig.get_config_var("PYTHONFRAMEWORK")
    if running != wanted or not frameworks or not name:
        raise BuildFailure(
            f"The runtime embeds CPython {wanted} as a framework; run this script with a framework build "
            f"of python{wanted} (this is {running}, framework: {name or 'no'}).")
    library = Path(frameworks) / f"{name}.framework" / "Versions" / running / name
    home = Path(sys.base_prefix)
    if not library.is_file() or not (home / "lib" / f"python{running}" / "encodings" / "__init__.py").is_file():
        raise BuildFailure(f"Incomplete Python framework at {frameworks}.")
    return Path(frameworks), library, home


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--only", action="append", default=[], metavar="Class[/testName]",
                        help="run only this test class or method (repeatable)")
    parser.add_argument("--scratch", type=Path, help="keep build products and the log in this directory")
    parser.add_argument("--verbose", action="store_true", help="print the complete xctest output")
    parser.add_argument("--timeout", type=int, default=900, help="seconds allowed for the test run")
    parser.add_argument("--python-traceback", action="store_true",
                        help="diagnosis only: run a scratch copy of the runtime that prints Python tracebacks")
    parser.add_argument("--capabilities", type=Path, metavar="FILE",
                        help="write the runtime.capabilities result of the app's host composition to FILE")
    parser.add_argument("--without", action="append", default=[], metavar="FILE.swift",
                        help="leave this file of Tests/Swift out of the bundle (repeatable); its tests do not run")
    parser.add_argument("--files", nargs="+", default=[], metavar="FILE.swift",
                        help="build only these files of Tests/Swift (name the support files they need)")
    options = parser.parse_args()
    if options.capabilities:
        options.capabilities = options.capabilities.resolve()
        if not options.only:
            options.only = [CAPABILITIES_TEST]

    if options.scratch:
        options.scratch.mkdir(parents=True, exist_ok=True)
        return build_and_run(options.scratch.resolve(), options)
    with tempfile.TemporaryDirectory(prefix="apb-swift-tests-") as scratch:
        return build_and_run(Path(scratch).resolve(), options)


def suite_preference_files() -> set[Path]:
    directory = Path.home() / "Library" / "Preferences"
    if not directory.is_dir():
        return set()
    return {path for path in directory.iterdir() if TEST_SUITE_PREFERENCES.fullmatch(path.name)}


def build_and_run(scratch: Path, options: argparse.Namespace) -> int:
    try:
        bundle, environment = build(scratch, options.python_traceback, set(options.without), set(options.files))
    except BuildFailure as failure:
        print(failure)
        print("build: FAILED")
        return 2
    if options.capabilities:
        options.capabilities.unlink(missing_ok=True)
        environment["AYU_PLUGIN_TEST_CAPABILITIES_OUT"] = str(options.capabilities)
    existing = suite_preference_files()
    try:
        status = run_tests(scratch, bundle, environment, options)
        if options.capabilities:
            status = max(status, report_capabilities(options.capabilities))
        return status
    finally:
        for path in sorted(suite_preference_files() - existing):
            subprocess.run(["defaults", "delete", path.stem], capture_output=True)
            path.unlink(missing_ok=True)


def report_capabilities(path: Path) -> int:
    try:
        capabilities = json.loads(path.read_text(encoding="utf-8"))
        counts = ", ".join(f"{len(capabilities[key])} {key}"
                           for key in ("operations", "classes", "modules", "proxy_interfaces"))
        members = len(capabilities.get("members", {}).get("classes", {}))
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        print(f"capabilities: NOT WRITTEN ({path})")
        return 1
    print(f"capabilities: {path} ({counts}, member tables for {members} classes)")
    return 0


def build(scratch: Path, python_traceback: bool, without: set[str] = frozenset(),
          files: set[str] = frozenset()) -> tuple[Path, dict[str, str]]:
    developer = harness.developer_dir()
    frameworks, library, home = host_python()

    def tool(label: str, arguments: list[str]) -> str:
        result = harness.run(developer, arguments)
        if result.returncode != 0:
            raise BuildFailure(f"{(result.stdout + result.stderr).strip()}\n{label}: FAILED")
        return result.stdout

    sdk = tool("sdk", ["--sdk", "iphoneos", "--show-sdk-path"]).strip()
    swift_libraries = Path(tool("swiftc", ["--find", "swiftc"]).strip()).parents[1] / "lib" / "swift" / "iphoneos"
    platform = developer / "Platforms" / "iPhoneOS.platform" / "Developer"
    mac_platform = developer / "Platforms" / "MacOSX.platform" / "Developer"
    common = ["-sdk", sdk, "-target", harness.TARGET, "-parse-as-library", "-swift-version", "5"]

    objects = scratch / "objects"
    modules = scratch / "modules"
    clang = scratch / "AyuPluginPython"
    for directory in (objects, modules, clang):
        shutil.rmtree(directory, ignore_errors=True)
        directory.mkdir(parents=True)
    header = BRIDGE / "PublicHeaders" / "AyuPluginPython" / "APBPythonRuntime.h"
    (clang / "module.modulemap").write_text(
        f'module AyuPluginPython {{\n    header "{header}"\n    export *\n}}\n', encoding="utf-8")
    search = ["-I", str(modules), "-I", str(clang)]

    for name in harness.DEPENDENCIES:
        tool(name, [
            "swiftc", "-emit-module", "-emit-object", "-wmo", "-Onone", "-module-name", name, *common,
            "-emit-module-path", str(modules / f"{name}.swiftmodule"), "-o", str(objects / f"{name}.o"),
            *harness.swift_sources(SUBMODULES / name / "Sources"),
        ])
    tool("AyuPluginBridge", [
        "swiftc", "-emit-module", "-emit-object", "-wmo", "-Onone", "-enable-testing",
        "-module-name", "AyuPluginBridge", *common, "-warnings-as-errors", *search,
        "-emit-module-path", str(modules / "AyuPluginBridge.swiftmodule"),
        "-o", str(objects / "AyuPluginBridge.o"),
        *harness.swift_sources(BRIDGE / "Sources", BRIDGE / "Integration"),
    ])
    tool("Tests/Swift", [
        "swiftc", "-emit-object", "-wmo", "-Onone", "-module-name", "AyuPluginBridgeTestsLib",
        *common, *search, "-F", str(platform / "Library" / "Frameworks"), "-I", str(platform / "usr" / "lib"),
        "-o", str(objects / "AyuPluginBridgeTestsLib.o"),
        *(source for source in harness.swift_sources(BRIDGE / "Tests" / "Swift")
          if Path(source).name not in without and (not files or Path(source).name in files)),
    ])
    if files:
        print("only in the bundle: " + ", ".join(sorted(files - without)))
    elif without:
        print("left out of the bundle: " + ", ".join(sorted(without)))
    runtime_source = BRIDGE / "ObjC" / "APBPythonRuntime.m"
    if python_traceback:
        text = runtime_source.read_text(encoding="utf-8")
        discard = "    PyErr_Clear();\n    return APBError(2,"
        if text.count(discard) != 1:
            raise BuildFailure("--python-traceback: APBPythonError no longer has the expected shape.")
        runtime_source = scratch / "APBPythonRuntime.traceback.m"
        runtime_source.write_text(text.replace(discard, "    PyErr_Print();\n    return APBError(2,"), encoding="utf-8")
        print("runtime: scratch copy that prints Python tracebacks (diagnosis only)")
    tool("ObjC/APBPythonRuntime.m", [
        "clang", "-c", "-target", harness.TARGET, "-isysroot", sdk, "-fobjc-arc", "-fmodules", "-O0", "-g",
        "-I", str(header.parent), "-I", str(BRIDGE / "ObjC"), "-iframework", str(frameworks),
        "-o", str(objects / "APBPythonRuntime.o"), str(runtime_source),
    ])

    # The linker refuses a macOS library in an iOS link. The stub lists the interpreter's
    # exports for iOS and keeps its install name, so the real library is what gets loaded.
    stub_frameworks = scratch / "link-stubs"
    stub = stub_frameworks / f"{library.name}.framework" / f"{library.name}.tbd"
    shutil.rmtree(stub_frameworks, ignore_errors=True)
    stub.parent.mkdir(parents=True)
    tool("Python link stub", ["tapi", "stubify", str(library), "-o", str(stub)])
    text = stub.read_text(encoding="utf-8")
    retargeted = re.sub(r'"(arm64e?|x86_64)-macos"', r'"\1-ios"', text)
    if retargeted == text:
        raise BuildFailure("Python link stub: unexpected stub format\nPython link stub: FAILED")
    json.loads(retargeted)
    stub.write_text(retargeted, encoding="utf-8")

    linked = scratch / f"{BUNDLE}.ios"
    tool("link", [
        "clang", "-target", harness.TARGET, "-isysroot", sdk, "-bundle", "-fobjc-arc", "-fobjc-link-runtime",
        "-o", str(linked), *[str(path) for path in sorted(objects.glob("*.o"))],
        "-F", str(platform / "Library" / "Frameworks"), "-framework", "XCTest",
        "-L", str(platform / "usr" / "lib"), "-L", str(swift_libraries), "-L", f"{sdk}/usr/lib/swift",
        "-F", str(stub_frameworks), "-framework", library.name,
        "-Xlinker", "-rpath", "-Xlinker", "/usr/lib/swift",
        "-Xlinker", "-rpath", "-Xlinker", str(mac_platform / "Library" / "Frameworks"),
        "-Xlinker", "-rpath", "-Xlinker", str(mac_platform / "usr" / "lib"),
        "-Xlinker", "-w",
    ])

    bundle = scratch / f"{BUNDLE}.xctest"
    shutil.rmtree(bundle, ignore_errors=True)
    binary = bundle / "Contents" / "MacOS" / BUNDLE
    binary.parent.mkdir(parents=True)
    (bundle / "Contents" / "Info.plist").write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0"><dict>\n'
        f'<key>CFBundleExecutable</key><string>{BUNDLE}</string>\n'
        f'<key>CFBundleIdentifier</key><string>local.ayu.{BUNDLE}</string>\n'
        f'<key>CFBundleName</key><string>{BUNDLE}</string>\n'
        '<key>CFBundlePackageType</key><string>BNDL</string>\n'
        '</dict></plist>\n', encoding="utf-8")
    # Real directories: the resource locator refuses a payload that resolves outside its bundle.
    resources = bundle / "Contents" / "Resources"
    stdlib = Path("lib") / f"python{embedded_python_version()}"
    shutil.copytree(home / stdlib, resources / "AyuPythonResources.bundle" / "python" / stdlib,
                    ignore=shutil.ignore_patterns(*STDLIB_EXCLUDED))
    shutil.copytree(BRIDGE / "Python", resources / "AyuPluginSDK.bundle" / "Python",
                    ignore=shutil.ignore_patterns("__pycache__"))
    minimum = harness.TARGET.rsplit("ios", 1)[1]
    sdk_version = tool("sdk", ["--sdk", "iphoneos", "--show-sdk-version"]).strip()
    tool("retag", ["vtool", "-set-build-version", "maccatalyst", minimum, sdk_version, "-replace",
                   "-output", str(binary), str(linked)])
    tool("sign", ["codesign", "--force", "--sign", "-", str(binary)])
    print("build: ok")

    user_home = scratch / "home"
    shutil.rmtree(user_home, ignore_errors=True)
    user_home.mkdir()
    environment = {
        key: value for key, value in os.environ.items()
        if not key.startswith(("DYLD_", "PYTHON", "XCTest"))
    }
    environment.update(
        DEVELOPER_DIR=str(developer), DYLD_FORCE_PLATFORM=CATALYST_PLATFORM,
        HOME=str(user_home), CFFIXED_USER_HOME=str(user_home), AYU_PLUGIN_TEST_HOME=str(user_home),
    )
    return bundle, environment


def run_tests(scratch: Path, bundle: Path, environment: dict[str, str], options: argparse.Namespace) -> int:
    # Started by path: /usr/bin/xcrun is a protected binary and would drop DYLD_FORCE_PLATFORM.
    command = [str(Path(environment["DEVELOPER_DIR"]) / "usr" / "bin" / "xctest")]
    if options.only:
        command += ["-XCTest", ",".join(
            selection if "." in selection.split("/")[0] else f"AyuPluginBridgeTestsLib.{selection}"
            for selection in options.only)]
    command.append(str(bundle))
    log = scratch / "xctest.log"
    timed_out = False
    with log.open("w", encoding="utf-8") as output:
        try:
            status = subprocess.run(command, env=environment, cwd=scratch, stdout=output,
                                    stderr=subprocess.STDOUT, timeout=options.timeout).returncode
        except subprocess.TimeoutExpired:
            status, timed_out = -1, True
    lines = log.read_text(encoding="utf-8", errors="replace").splitlines()
    verbose = options.verbose or options.python_traceback
    if verbose:
        print("\n".join(lines))

    case = re.compile(r"^Test Case '-\[\S+?\.(\S+) (\S+)\]' (started|passed|failed|skipped)")
    outcome: dict[str, str] = {}
    for line in lines:
        match = case.match(line)
        if match:
            outcome[f"{match.group(1)}/{match.group(2)}"] = match.group(3)
    passed = sorted(name for name, state in outcome.items() if state == "passed")
    failed = sorted(name for name, state in outcome.items() if state == "failed")
    skipped = sorted(name for name, state in outcome.items() if state == "skipped")
    unfinished = sorted(name for name, state in outcome.items() if state == "started")

    if not verbose:
        notable = re.compile(r": error: -\[|Fatal error|: Test skipped - ")
        for line in lines:
            if notable.search(line):
                print(line)
    expected = re.compile(r": Expected failure in -\[\S+?\.(\S+) (\S+)\]:.*?Reason: \((.*)\)\s*$")
    known = sorted({f"{match.group(1)}/{match.group(2)}: {match.group(3)}" for match in map(expected.search, lines) if match})
    for finding in known:
        print(f"EXPECTED FAILURE: {finding}")
    for name in failed:
        print(f"FAILED: {name}")
    for name in unfinished:
        print(f"DID NOT FINISH: {name}")
    completed = any(re.match(r"Test Suite '(All|Selected) tests' (passed|failed) at ", line) for line in lines)
    if timed_out:
        print(f"xctest: timed out after {options.timeout} s")
    elif not completed:
        print(f"xctest: ended before the suite finished (status {status})")
        if not verbose:
            print("\n".join(lines[-25:]))
    print(f"tests: {len(outcome)} run, {len(passed)} passed, {len(failed)} failed, {len(skipped)} skipped"
          + (f", {len(unfinished)} unfinished" if unfinished else "")
          + (f"; {len(known)} expected failures in passed tests" if known else ""))
    if options.scratch:
        print(f"log: {log}")
    succeeded = completed and not timed_out and status == 0 and not failed and not unfinished and outcome
    return 0 if succeeded else 1


if __name__ == "__main__":
    sys.exit(main())
