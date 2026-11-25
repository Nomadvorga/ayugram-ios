"""Run actual production Swift validators in a small Foundation-only host executable.

No validation logic is reimplemented here. The Swift declarations are extracted verbatim
from the working tree; Python supplies independent JSON fixtures and drives swiftc.
Requires a Swift toolchain (macOS recommended). --emit-only prepares the harness on Windows.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import random
import re
import shutil
import subprocess
import sys
import tempfile


def declaration(source, marker):
    start = source.index("    " + marker)
    end = re.search(r"^    \}", source[start:], re.M)
    if end is None:
        raise ValueError("Declaration not found: " + marker)
    return source[start:start + end.end()]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--emit-only", action="store_true")
    args = parser.parse_args()
    sources = args.repo / "Swiftgram/SGSimpleSettings/Sources"
    backup = (sources / "ExteraSettingsBackup.swift").read_text(encoding="utf-8")
    browser = (sources / "ExteraBrowserSettings.swift").read_text(encoding="utf-8")
    navigation = (sources / "ExteraNavigationSettings.swift").read_text(encoding="utf-8")
    declarations = [declaration(backup, marker) for marker in ["public enum BackupError", "fileprivate enum Value", "private enum Rule", "private static func rejectDuplicateKeys", "private struct JSONStructureValidator"]]
    cases = []

    def case(name, raw, accepts):
        if isinstance(raw, str):
            raw = raw.encode("utf-8")
        cases.append((name, raw, accepts))

    for name, raw in [
        ("empty-object", "{}"), ("empty-array", "[]"), ("scalar-string", '"hello"'),
        ("escaped-key", '{"\\u0061":1}'), ("nested", '{"a":[true,false,null,{"b":"c"}]}'),
        ("numbers", "[0,-0,1,-2,1.5,2e3,-1.2E-4]"),
        ("whitespace", ' \r\n\t { "x" : 1 } \r\n\t'),
        ("unicode", '{"é":"Привет 你好 😀"}'),
        ("braces-in-string", '{"a":"} ], { \\\" \\\\"}'),
        ("surrogate-pair", '{"x":"\\uD83D\\uDE00"}'),
        ("depth-16", "[" * 16 + "0" + "]" * 16),
    ]:
        # Ensure the independently authored fixture itself is valid JSON.
        json.loads(raw)
        case(name, raw, True)
    for name, raw in [
        ("empty", ""), ("duplicate-root", '{"a":1,"a":2}'),
        ("escaped-duplicate", '{"a":1,"\\u0061":2}'),
        ("duplicate-nested", '{"x":[{"a":1,"a":2}]}'),
        ("object-trailing-comma", '{"a":1,}'), ("array-trailing-comma", "[1,]"),
        ("missing-comma", '[1 2]'), ("missing-colon", '{"a" 1}'),
        ("missing-key", '{:1}'), ("unquoted-key", '{a:1}'), ("string-key-only", '{"a"}'),
        ("wrong-closer", '[1}'), ("two-documents", '{} {}'), ("garbage", '{}garbage'),
        ("comment", '{/*hello*/"a":1}'), ("raw-control", '{"a":"\x01"}'),
        ("invalid-escape", '{"a":"\\q"}'), ("truncated-escape", b'{"a":"\\'),
        ("truncated-unicode", '{"a":"\\u123"}'), ("unpaired-surrogate", '{"a":"\\uD800"}'),
        ("plus-sign", '[+1]'), ("leading-zero", '[01]'), ("negative-leading-zero", '[-01]'),
        ("missing-fraction", '[1.]'), ("missing-integer", '[.1]'), ("missing-exponent", '[1e+]'),
        ("infinity", '[Infinity]'), ("nan", '[NaN]'), ("truncated-literal", '[tru]'),
        ("depth-17", "[" * 17 + "0" + "]" * 17),
        ("invalid-utf8-value", b'{"a":"\xff"}'),
        ("overlong-utf8", b'{"a":"\xc0\xaf"}'),
        ("utf16", '{"a":1}'.encode('utf-16')),
        ("utf32", '{"a":1}'.encode('utf-32')),
    ]:
        case(name, raw, False)
    case("utf8-bom", b"\xef\xbb\xbf" + b'{"a":1}', True)
    rng = random.Random(861)
    for index in range(100):
        value = {"key" + str(i): [rng.randrange(-100, 100), rng.choice([True, False, None]), "quote \" slash \\ braces {} 😀"] for i in range(rng.randrange(1, 6))}
        raw = json.dumps(value, ensure_ascii=rng.choice([True, False]), separators=(",", ":"))
        case("generated-" + str(index), raw, True)
        case("generated-trailing-" + str(index), raw[:-1] + ",}", False)

    rows = []
    for name, raw, accepted in cases:
        rows.append(f'            ({json.dumps(name)}, Data(base64Encoded: "{base64.b64encode(raw).decode()}")!, {str(accepted).lower()}),')
    bindings = '\nlet APP_GROUP_IDENTIFIER = "extera-validator-" + UUID().uuidString\nlet ayuSettingsDidChangeNotification = Notification.Name("ExteraValidationChanged")\nenum SGSimpleSettings { static let shared = 0 }\n'
    harness = "import CoreFoundation\nimport Foundation\n" + bindings + navigation + "\nenum ExteraBrowserSettings {\n" + declaration(browser, "public static func normalizedHost") + "\n}\n\nenum ExteraSettingsBackup {\n" + "\n\n".join(declarations)
    harness += """

    static func runTests() throws {
        var count = 0
        let cases: [(String, Data, Bool)] = [
""" + "\n".join(rows) + """
        ]
        for (name, data, expected) in cases {
            var accepted = false
            do { try self.rejectDuplicateKeys(data); accepted = true } catch {}
            guard accepted == expected else { fatalError("structure fixture failed: \\(name), expected \\(expected)") }
            count += 1
        }
        func rule(_ name: String, _ rule: Rule, _ json: String, _ expected: Bool) throws {
            let object = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
            var accepted = false
            do { _ = try rule.validate(object); accepted = true } catch {}
            guard accepted == expected else { fatalError("rule fixture failed: \\(name), expected \\(expected)") }
            count += 1
        }
        try rule("bool-true", .boolean, "true", true)
        try rule("bool-number-one", .boolean, "1", false)
        try rule("bool-number-zero", .boolean, "0", false)
        try rule("bool-string", .boolean, "\\\"true\\\"", false)
        try rule("bool-null", .boolean, "null", false)
        try rule("integer-valid", .integer(0 ... 28), "28", true)
        try rule("integer-bool", .integer(0 ... 28), "true", false)
        try rule("integer-over", .integer(0 ... 28), "29", false)
        try rule("integer-negative", .integer(0 ... 28), "-1", false)
        try rule("integer-fraction", .integer(0 ... 28), "1.5", false)
        try rule("integer-string", .integer(0 ... 28), "\\\"1\\\"", false)
        try rule("integer-set-valid", .integerSet([-1, 0, 1, 8, 9]), "8", true)
        try rule("integer-set-hole", .integerSet([-1, 0, 1, 8, 9]), "7", false)
        try rule("enum-valid", .string(["degrees", "radians"]), "\\\"degrees\\\"", true)
        try rule("enum-invalid", .string(["degrees", "radians"]), "\\\"deg\\\"", false)
        try rule("text-valid", .text(maximumLength: 5, allowedCharacters: nil), "\\\"hello\\\"", true)
        try rule("text-too-long", .text(maximumLength: 5, allowedCharacters: nil), "\\\"longer\\\"", false)
        try rule("text-leading-space", .text(maximumLength: 5, allowedCharacters: nil), "\\\" hi\\\"", false)
        try rule("text-control", .text(maximumLength: 5, allowedCharacters: nil), "\\\"a\\\\nb\\\"", false)
        try rule("hosts-valid", .exactHosts, "[\\\"example.com\\\",\\\"a.example.com\\\"]", true)
        try rule("hosts-empty", .exactHosts, "[]", true)
        try rule("hosts-duplicate", .exactHosts, "[\\\"example.com\\\",\\\"example.com\\\"]", false)
        try rule("hosts-url", .exactHosts, "[\\\"https://example.com\\\"]", false)
        try rule("hosts-uppercase", .exactHosts, "[\\\"EXAMPLE.com\\\"]", false)
        try rule("hosts-wildcard", .exactHosts, "[\\\"*.example.com\\\"]", false)
        try rule("hosts-port", .exactHosts, "[\\\"example.com:443\\\"]", false)
        try rule("hosts-mixed", .exactHosts, "[\\\"example.com\\\",1]", false)
        let defaults = try JSONEncoder().encode(ExteraNavigationSettings.Configuration())
        let navigation = String(decoding: defaults, as: UTF8.self)
        func jsonString(_ value: String) throws -> String {
            return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        }
        try rule("navigation-defaults", .navigationConfiguration, try jsonString(navigation), true)
        try rule("navigation-empty", .navigationConfiguration, try jsonString("{}"), false)
        try rule("navigation-wrong-type", .navigationConfiguration, "true", false)
        let duplicate = "{\\\"barMode\\\":0," + String(navigation.dropFirst())
        try rule("navigation-duplicate", .navigationConfiguration, try jsonString(duplicate), false)
        print("Passed \\(count) production Swift validation fixtures")
    }
}

try ExteraSettingsBackup.runTests()
"""
    temporary_root = Path(os.environ["LOCALAPPDATA"]) / "Temp/opencode" if sys.platform == "win32" else None
    output = Path(tempfile.mkdtemp(prefix="extera-backup-validation-", dir=temporary_root)) / "ExteraBackupValidationHarness.swift"
    output.write_text(harness, encoding="utf-8")
    print(f"Prepared actual production validator harness: {output}")
    if args.emit_only:
        return 0
    compiler = shutil.which("swiftc")
    if not compiler:
        print("NOT RUN: swiftc unavailable; harness preparation is not a passing runtime test.", file=sys.stderr)
        return 2
    executable = output.with_suffix(".exe" if sys.platform == "win32" else "")
    subprocess.run([compiler, str(output), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
