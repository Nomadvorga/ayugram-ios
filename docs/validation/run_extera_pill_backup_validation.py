"""Validate the proposed portable Pill backup using actual production Swift declarations.

Coherent manifest (the helper and root entry are integrated in the current tree):
  docs/integration/extera-pill-backup.patch                 original review patch
  AyuGram/SGSimpleSettings/Sources/ExteraPillPortableSettings.swift
  docs/validation/run_extera_pill_backup_validation.py       this harness/documentation

Policy: extera.pillStack.layout.v1 is a JSON string in the existing version-1 main
backup. Export projects only built-in ids, preserving visible/hidden order. Missing
or custom selection falls back to the first visible built-in (nil if none). Import
rejects custom ids rather than guessing their meaning. Import/reset use the existing
stack update(custom:) setter: local HTTP specs survive, appended hidden; no HTTP
spec, endpoint, provider grant, account currency/location/entry-time preference or
cached data is exported/reset/changed. Reset hides every built-in, enables infinite
scrolling and clears selection. Missing Pill key in an older partial backup leaves
the complete local layout untouched. Existing permissions are neither granted nor
revoked; provider runtime permission checks remain authoritative.

The helper is included by the existing SGSimpleSettings source glob (Foundation and
CoreFoundation only); no BUILD/UI/strings/schema-version change is needed. This script
never writes production files: when the root entry is absent it applies that exact patch
in memory; afterwards it reads the integrated production entry. A partially integrated
patch is an error. The current backup source is used as
the base, including its AI, style, native and Vosk entries; the targeted fixture set
also uses the current production bool/enum writers and the current AI-first
orchestration. The main Rule, Setting and export/validate/apply/reset/write scanner are
extracted verbatim. Full Pill model/settings/document, portable helper, style settings
and navigation validator are compiled unchanged. Only unrelated backup entries are
omitted. Store/shared-sync and unused AI update adapters are fixtures; there is no
replacement implementation of validation, projection or backup writes.

Combined custom-icon archive handoff: do not put the icon archive into the existing
256 KiB settings document or into the Pill key. The root-owned controller should use a
separate versioned outer bundle with the existing settings JSON plus base64 of
`ExteraUIIconPackStore.shared.exportBackup()`. Bound settings by
`ExteraSettingsBackup.maximumFileSize`, the decoded icon JSON by
`ExteraUIIconPackStore.maxBackupBytes`, base64 expansion by the corresponding encoded
limit, and the total by the sum plus a small fixed envelope allowance. Preflight the
whole bundle before any write: strict outer duplicate-key/UTF-8 grammar, production
`ExteraSettingsBackup.validate`, `prepareBackupRestore`, and
`ExteraUIIconRendering.validate` for every preview. Then commit through the existing
`ExteraSettingsBackup.apply` and `restoreBackup` APIs. For bounded compensation,
capture and validate the pre-import settings export and icon export before mutation;
apply settings first (the existing AI persistence is the only throwing settings write
and runs before ordinary setters), then call `restoreBackup`, which stages all pack
revisions before publishing its single catalog. If icon staging/publish fails, restore
the pre-import settings snapshot. Ordinary setters after AI persistence do not throw;
after icon publication there must be no further fallible work. A settings rollback can
itself fail at the AI persistence layer, and orphaned immutable icon revisions may be
left after a failed stage, so this is bounded compensation, not ACID or guaranteed
cross-store atomicity. If stronger guarantees are required, first extend the icon store
with an explicit prepare/stage token and a recoverable commit journal coordinated with
the settings write; do not fake atomicity by merely changing call order. Reset follows
the same preflight/snapshot process with a validated empty icon plan. Base icon-pack
selection remains the existing scalar allowlist; Pill HTTP specs, endpoints, grants and
account preferences remain outside the bundle.

Run on macOS/Swift host:
  python3 docs/validation/run_extera_pill_backup_validation.py
Prepare reviewable Swift without a compiler (not a runtime pass):
  python docs/validation/run_extera_pill_backup_validation.py --emit-only
Review applicability without mutation:
  git apply --check docs/integration/extera-pill-backup.patch

No UI change/recording is proposed. This host test cannot prove UserDefaults I/O
durability, multi-store transactions, full iOS linkage or live provider behavior.

Windows source check: patch applicability, helper/hypothetical-backup/harness Swift
syntax parsing, Python AST and generation of 63 wire fixtures passed. The emitted
backup harness and the independent 224-assertion Pill host suite were compiled and
executed with the pinned Swift 6.1.2 WSL toolchain. The Windows-only default runner
still needs swiftc on PATH; no production root backup, Pill models/settings, BUILD or
CI file was edited by this proposal.
"""

import argparse
import base64
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

from run_extera_backup_validation import declaration


def proposed_backup(repo):
    """Apply unique exact-context hunks in memory; never ask git to alter the tree."""
    relative = "AyuGram/SGSimpleSettings/Sources/ExteraSettingsBackup.swift"
    source = (repo / relative).read_text(encoding="utf-8")
    markers = ["        case pillConfiguration\n", "    private static func pillConfiguration()", "        pillConfiguration(),"]
    present = [marker in source for marker in markers]
    if all(present):
        return source, "integrated production entry"
    if any(present):
        raise ValueError("Partial Pill backup integration; review the production file before running")
    patch = (repo / "docs/integration/extera-pill-backup.patch").read_text(encoding="utf-8")
    if patch.count("diff --git ") != 1 or f"+++ b/{relative}\n" not in patch:
        raise ValueError("Expected exactly the main backup proposal")
    lines = patch.splitlines(keepends=True)
    original = source.splitlines(keepends=True)
    output = []
    cursor = 0
    index = 0
    hunks = 0
    while index < len(lines):
        match = re.match(r"@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", lines[index])
        if not match:
            index += 1
            continue
        old, new = [], []
        index += 1
        while index < len(lines) and not lines[index].startswith("@@"):
            line = lines[index]
            if not line.startswith((" ", "+", "-")):
                raise ValueError("Unexpected patch line")
            if line.startswith((" ", "-")):
                old.append(line[1:])
            if line.startswith((" ", "+")):
                new.append(line[1:])
            index += 1
        if len(old) != int(match[2] or 1) or len(new) != int(match[4] or 1):
            raise ValueError("Corrupt proposal hunk lengths")
        positions = [n for n in range(cursor, len(original) - len(old) + 1) if original[n:n + len(old)] == old]
        if len(positions) != 1:
            raise ValueError("Proposal context changed or ambiguous; root must refresh patch")
        position = positions[0]
        output.extend(original[cursor:position] + new)
        cursor = position + len(old)
        hunks += 1
    if hunks != 3:
        raise ValueError("Expected all three Pill integration hunks")
    return "".join(output + original[cursor:]), "proposal applied only in memory"


def fixtures():
    """Independent wire fixtures; assertions execute the extracted Swift validator."""
    ids = ["builtin." + name for name in ("weather", "gram", "btc", "usd", "storage", "proxy", "entryTime")]
    root = {"version": 1, "layout": {"visible": ids[:2], "hidden": ids[2:], "infiniteScrolling": True, "selected": ids[1]}}
    result = []

    def add(name, value, accepts=False):
        raw = value if isinstance(value, str) else json.dumps(value, separators=(",", ":"))
        result.append((name, raw, accepts))

    def altered(field, value):
        document = json.loads(json.dumps(root))
        document["layout"][field] = value
        return document

    add("valid", root, True)
    for split in range(len(ids) + 1):
        visible = list(reversed(ids))[:split]
        hidden = list(reversed(ids))[split:]
        add(f"ordered-partition-{split}", {"version": 1, "layout": {"visible": visible, "hidden": hidden, "infiniteScrolling": False, "selected": visible[-1] if visible else None}}, True)
    no_selection = json.loads(json.dumps(root))
    del no_selection["layout"]["selected"]
    add("absent-optional-selection", no_selection, True)
    for value in (True, False, 0, 2, "1", None, 1.5):
        add("version-" + repr(value), dict(root, version=value))
    for value in (0, 1, "true", None, [], {}):
        add("bool-" + repr(value), altered("infiniteScrolling", value))
    for value in ("builtin.unknown", "custom.00000000-0000-0000-0000-000000000001", "weather", 1, True):
        add("unknown-enum-" + repr(value), altered("visible", [value, ids[1]]))
    add("duplicate-visible", altered("visible", [ids[0], ids[0], ids[1]]))
    add("overlapping-order", altered("hidden", ids[1:]))
    add("missing-inventory", altered("hidden", ids[3:]))
    add("wrong-array-type", altered("visible", "builtin.weather"))
    for value in (ids[2], "builtin.unknown", "custom.any", True, 0, [], {}):
        add("invalid-selected-" + repr(value), altered("selected", value))
    for field in ("visible", "hidden", "infiniteScrolling"):
        document = json.loads(json.dumps(root))
        del document["layout"][field]
        add("missing-" + field, document)
    for field in ("url", "grants", "currency", "entryTimeAutoRefresh", "customHTTPPills", "format"):
        add("unknown-layout-" + field, altered(field, "sentinel"))
        add("unknown-root-" + field, dict(root, **{field: "sentinel"}))
    raw = json.dumps(root, separators=(",", ":"))
    add("duplicate-version", raw.replace('"version":1', '"version":2,"version":1'))
    add("duplicate-layout", '{"layout":{},' + raw[1:])
    add("escaped-duplicate-version", raw.replace('"version":1', '"version":1,"\\u0076ersion":1'))
    add("duplicate-infinite", raw.replace('"infiniteScrolling":true', '"infiniteScrolling":false,"infiniteScrolling":true'))
    add("escaped-duplicate-visible", raw.replace('"visible":', '"\\u0076isible":[],"visible":'))
    add("trailing-comma", raw[:-1] + ",}")
    add("oversize", " " * (64 * 1024) + raw)
    add("not-json", "not JSON")
    add("scalar", "true")
    return result


def make_harness(repo):
    sources = repo / "AyuGram/SGSimpleSettings/Sources"
    backup, mode = proposed_backup(repo)
    # All code before aiBoolean is the production enum header and its actual type declarations.
    header = backup[:backup.index("    private static func aiBoolean(")]
    methods = "\n\n".join(declaration(backup, marker) for marker in (
        "private static func boolean(", "private static func pillConfiguration()",
    ))
    # Extract actual existing bool and string-enum entries, including their real setters/defaults.
    start = backup.index("        Setting(name: ExteraStyleSettings.separatorStyleKey,")
    end = backup.index("\n        }),", start) + len("\n        }),")
    enum_entry = backup[start:end]
    bool_entry = next(line for line in backup.splitlines() if line.startswith("        boolean(ExteraStyleSettings.glassMessageMenuKey,"))
    pill_entry = next(line for line in backup.splitlines() if line.strip() == "pillConfiguration(),")
    settings = "\n    private static let settings: [Setting] = [\n" + "\n".join((pill_entry, bool_entry, enum_entry)) + "\n    ]\n"
    by_name = next(line for line in backup.splitlines() if line.startswith("    private static let settingsByName:"))
    # Export, validate, apply, reset, AI-before-ordinary-write ordering and JSON scanner unchanged.
    orchestration = backup[backup.index("    /// Call on the main queue,"):]
    reduced = header + methods + settings + by_name + "\n" + orchestration
    browser = (sources / "ExteraBrowserSettings.swift").read_text(encoding="utf-8")
    actual = "\n".join((sources / name).read_text(encoding="utf-8") for name in (
        "ExteraPillSettings.swift", "ExteraPillStackSettings.swift", "ExteraPillParity.swift", "ExteraPillStrings.swift",
        "ExteraPillPortableSettings.swift", "ExteraStyleSettings.swift", "ExteraNavigationSettings.swift",
    ))
    adapters = r'''
import Foundation
import CoreFoundation

let APP_GROUP_IDENTIFIER = "PillBackupNavigation." + UUID().uuidString
let ayuSettingsDidChangeNotification = Notification.Name("PillBackupFixtureChanged")
final class AyuSettingsStore: @unchecked Sendable {
    static let shared = AyuSettingsStore()
    static let suite = "PillBackupValidation." + UUID().uuidString
    let userDefaults = UserDefaults(suiteName: AyuSettingsStore.suite)!
    var writes = 0
    func register(defaults: [String: Any]) { userDefaults.register(defaults: defaults) }
    func int(_ key: String) -> Int { userDefaults.integer(forKey: key) }
    func bool(_ key: String) -> Bool { userDefaults.bool(forKey: key) }
    func string(_ key: String) -> String { userDefaults.string(forKey: key) ?? "" }
    func setInt(_ value: Int, _ key: String) { writes += 1; userDefaults.set(value, forKey: key) }
    func setBool(_ value: Bool, _ key: String) { writes += 1; userDefaults.set(value, forKey: key) }
    func setString(_ value: String, _ key: String) { writes += 1; userDefaults.set(value, forKey: key) }
    func performBatchUpdates(_ body: () -> Void) { body() }
}
final class SGSimpleSettings {
    static let shared = SGSimpleSettings()
    var synchronizations = 0
    func synchronizeShared() { synchronizations += 1 }
}
struct ExteraAIConfiguration {}
final class ExteraAISettings {
    static let shared = ExteraAISettings()
    func update(_ body: (inout ExteraAIConfiguration) -> Void) throws {
        fatalError("Pill-only backup must never invoke AI persistence")
    }
}
func require(_ value: @autoclosure () throws -> Bool, _ message: String) rethrows {
    if try !value() { fatalError(message) }
}
func mustThrow(_ message: String, _ body: () throws -> Void) {
    do { try body() } catch { return }
    fatalError(message)
}
func persistedState(_ defaults: UserDefaults) -> [String: Any] {
    defaults.persistentDomain(forName: AyuSettingsStore.suite) ?? [:]
}
'''
    tests = r'''
let store = AyuSettingsStore.shared
let defaults = store.userDefaults
let stack = ExteraPillStackSettings.shared
let customSettings = ExteraPillSettings.shared
let style = ExteraStyleSettings.shared
let key = ExteraPillPortableSettings.key
let boolKey = ExteraStyleSettings.glassMessageMenuKey
let enumKey = ExteraStyleSettings.separatorStyleKey
let ids = ExteraBuiltinPill.allCases.map { $0.id }
defer {
    defaults.removePersistentDomain(forName: AyuSettingsStore.suite)
    UserDefaults(suiteName: APP_GROUP_IDENTIFIER)?.removePersistentDomain(forName: APP_GROUP_IDENTIFIER)
}
func document(_ settings: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["format": ExteraSettingsBackup.format, "version": 1, "settings": settings])
}
func apply(_ settings: [String: Any]) throws {
    try ExteraSettingsBackup.apply(ExteraSettingsBackup.validate(data: document(settings)))
}
func exported() throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: ExteraSettingsBackup.exportData()) as! [String: Any]
    return object["settings"] as! [String: Any]
}
func noWrites(_ name: String, _ operation: () throws -> Void) {
    let state = NSDictionary(dictionary: persistedState(defaults))
    let writes = store.writes
    let syncs = SGSimpleSettings.shared.synchronizations
    mustThrow(name, operation)
    require(state.isEqual(to: persistedState(defaults)), "\(name): partial preferences write")
    require(writes == store.writes && syncs == SGSimpleSettings.shared.synchronizations, "\(name): partial setters/sync")
}
let a = ExteraPillSpec(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, label: "Private A", url: "https://private.example/a?secret=sentinel")
let b = ExteraPillSpec(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, enabled: false, label: "Private B", url: "https://private.example/b")
try customSettings.replace([a, b])
let custom = customSettings.pills
let ca = ExteraPillStackLayout.customId(a.id), cb = ExteraPillStackLayout.customId(b.id)
stack.allow("weather", account: 101, value: true)
stack.allow("btc", account: 202, value: false)
stack.allowWeather(source: "private-location", account: 101, value: true)
stack.allowCustom(a, account: 101, value: true)
stack.setCurrency("EUR", account: 101)
stack.setEntryTimeAutoRefresh(true, account: 101)
defaults.set("opaque-cache", forKey: "extera.pillStack.cache.sentinel")
let privateState = persistedState(defaults).filter { $0.key.hasPrefix("extera.pillStack.") && $0.key != ExteraPillStackSettings.key || $0.key == "extera.customHTTPPills.v1" }
func privateStateUnchanged() {
    for (name, value) in privateState {
        require(NSDictionary(dictionary: [name: value]).isEqual(to: [name: defaults.object(forKey: name)!]), "private state changed: \(name)")
    }
    require(customSettings.pills == custom, "HTTP specs changed")
    let actualKeys = Set(persistedState(defaults).keys.filter { $0.hasPrefix("extera.pillStack.") && $0 != ExteraPillStackSettings.key })
    require(actualKeys == Set(privateState.keys.filter { $0.hasPrefix("extera.pillStack.") }), "new account grant/preference created")
}
var local = ExteraPillStackLayout()
local.visible = ["builtin.usd", ca, "builtin.storage", cb]
local.hidden = ids.reversed().filter { !local.visible.contains($0) }
local.infiniteScrolling = false
local.selected = ca
stack.update(custom: custom) { $0 = local }
let originalLayoutBytes = defaults.data(forKey: ExteraPillStackSettings.key)
let beforeExport = NSDictionary(dictionary: persistedState(defaults))
let firstExport = try exported()
let wire = firstExport[key] as! String
require(Set(firstExport.keys) == [key, boolKey, enumKey], "unexpected exported settings")
try require(ExteraSettingsBackup.exportData() == ExteraSettingsBackup.exportData(), "nondeterministic export")
require(!wire.contains("custom.") && !wire.contains("private") && !wire.contains("http") && !wire.contains("101"), "portable layout leaked installation data")
let projected = try ExteraPillStackDocument.decode(Data(wire.utf8), custom: [])
require(projected.visible == ["builtin.usd", "builtin.storage"], "visible built-in order lost")
require(projected.hidden == local.hidden && !projected.infiniteScrolling, "hidden order/scrolling lost")
require(projected.selected == "builtin.usd", "custom selection must fall back to first visible built-in")
require(beforeExport.isEqual(to: persistedState(defaults)), "export mutated preferences")
local.selected = "builtin.storage"
require(ExteraPillPortableSettings.projection(local).selected == "builtin.storage", "valid selected built-in lost")
local.visible = [ca]
local.hidden = ids + [cb]
local.selected = ca
require(ExteraPillPortableSettings.projection(local).selected == nil, "all-custom visible projection selected a hidden built-in")

// Same wire imports on another installation with an empty custom inventory.
let targetSuite = "PillBackupTarget." + UUID().uuidString
let targetDefaults = UserDefaults(suiteName: targetSuite)!
defer { targetDefaults.removePersistentDomain(forName: targetSuite) }
let target = ExteraPillStackSettings(userDefaults: targetDefaults)
ExteraPillPortableSettings.applyValidated(projected, settings: target, custom: [])
require(target.layout == projected, "projection is not portable to empty installation")
require(Set((targetDefaults.persistentDomain(forName: targetSuite) ?? [:]).keys) == [ExteraPillStackSettings.key], "target created grants/account settings")

// Validation is pure; valid import uses the actual main Setting writer, retaining HTTP specs.
let validated = try ExteraSettingsBackup.validate(data: document([key: wire]))
require(validated.settingCount == 1, "Pill layout must be one setting")
require(defaults.data(forKey: ExteraPillStackSettings.key) == originalLayoutBytes, "validation wrote layout")
try ExteraSettingsBackup.apply(validated)
let applied = stack.layout
require(applied == projected.normalized(custom: custom), "apply did not normalize with current custom specs")
require(applied.hidden.suffix(2) == [ca, cb] && !applied.visible.contains(ca), "import implicitly activated local custom pill")
privateStateUnchanged()
let appliedBytes = defaults.data(forKey: ExteraPillStackSettings.key)
try apply([boolKey: true, enumKey: "fullWidth"])
require(defaults.data(forKey: ExteraPillStackSettings.key) == appliedBytes, "missing Pill key rewrote layout")
require(style.glassMessageMenu && style.separatorStyle == .fullWidth, "real bool/enum entries not applied")
for invalid in [1, 0, "true", NSNull()] as [Any] {
    noWrites("strict bool entry") { try apply([key: wire, boolKey: invalid]) }
}
for invalid in [true, "unknown", 0, NSNull()] as [Any] {
    noWrites("strict enum entry") { try apply([key: wire, enumKey: invalid]) }
}
for invalid in [true, 1, [:], NSNull()] as [Any] {
    noWrites("layout must be JSON string") { try apply([key: invalid, boolKey: false]) }
}
'''
    rows = []
    for name, raw, accepts in fixtures():
        encoded = base64.b64encode(raw.encode("utf-8")).decode("ascii")
        rows.append(f'    ({json.dumps(name)}, String(decoding: Data(base64Encoded: "{encoded}")!, as: UTF8.self), {str(accepts).lower()}),')
    tests += '\nlet fixtures: [(String, String, Bool)] = [\n' + "\n".join(rows) + '\n]\n'
    tests += r'''
for (name, json, accepts) in fixtures {
    if accepts {
        let before = NSDictionary(dictionary: persistedState(defaults))
        let backup = try ExteraSettingsBackup.validate(data: document([key: json]))
        require(before.isEqual(to: persistedState(defaults)), "valid \(name) changed storage during validation")
        try ExteraSettingsBackup.apply(backup)
        _ = try ExteraPillStackDocument.validate(stack.layout, custom: custom)
        let exportedWire = try exported()[key] as! String
        _ = try ExteraSettingsBackup.validate(data: document([key: exportedWire]))
        privateStateUnchanged()
    } else {
        noWrites(name) { try apply([boolKey: false, enumKey: "none", key: json]) }
    }
}
let encodedWire = String(decoding: try JSONEncoder().encode(wire), as: UTF8.self)
let prefix = #"{"format":"exteragram-ios-settings","version":1,"settings":{"#
for raw in [
    prefix + "\"\(key)\":\(encodedWire),\"\(key)\":\(encodedWire)}}",
    prefix + "\"\(key)\":\(encodedWire)},\"settings\":{\"\(boolKey)\":true}}",
    "{\"format\":\"exteragram-ios-settings\",\"version\":true,\"settings\":{\"\(key)\":\(encodedWire)}}",
    "{\"format\":\"exteragram-ios-settings\",\"version\":1,\"unknown\":true,\"settings\":{\"\(key)\":\(encodedWire)}}"
] {
    noWrites("outer duplicate/type/unknown-field") {
        try ExteraSettingsBackup.apply(ExteraSettingsBackup.validate(data: Data(raw.utf8)))
    }
}
for forbidden in ["extera.customHTTPPills.v1", "extera.pillStack.101.allow.weather", "extera.pillStack.101.currency", "extera.pillStack.101.entryTimeAutoRefresh", "extera.pillStack.101.customURL", "extera.pillStack.cache"] {
    noWrites("excluded \(forbidden)") { try apply([key: wire, forbidden: true]) }
}
try ExteraSettingsBackup.reset()
let reset = stack.layout
require(reset.visible.isEmpty && reset.hidden == ids + [ca, cb] && reset.selected == nil && reset.infiniteScrolling, "reset missed portable defaults/current-inventory normalization")
require(!style.glassMessageMenu && style.separatorStyle == .line, "actual reset defaults not applied")
privateStateUnchanged()
let resetWire = try exported()[key] as! String
require(resetWire == ExteraPillPortableSettings.configurationJSON(ExteraPillStackLayout()), "reset/export default canonical projection mismatch")
print("PASS: \(fixtures.count) production Pill wire fixtures; portable projection/import/reset, actual backup bool/enum entries, duplicate keys, unknown fields, no partial writes and private-state preservation")
'''
    return adapters + actual + "\nenum ExteraBrowserSettings {\n" + declaration(browser, "public static func normalizedHost") + "\n}\n" + reduced + tests, mode


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--emit-only", action="store_true")
    args = parser.parse_args()
    harness, mode = make_harness(args.repo)
    temporary_root = Path(os.environ["LOCALAPPDATA"]) / "Temp/opencode" if sys.platform == "win32" else None
    output = Path(tempfile.mkdtemp(prefix="extera-pill-backup-validation-", dir=temporary_root)) / "ExteraPillBackupHarness.swift"
    output.write_text(harness, encoding="utf-8")
    print(f"Prepared actual production Pill/backup harness ({mode}): {output}")
    print(f"Independent wire fixtures: {len(fixtures())}")
    if args.emit_only:
        return 0
    compiler = shutil.which("swiftc")
    if not compiler:
        print("NOT RUN: swiftc unavailable; harness preparation is not a passing runtime test.", file=sys.stderr)
        return 2
    executable = output.with_suffix(".exe" if sys.platform == "win32" else "")
    subprocess.run([compiler, "-swift-version", "5", "-warnings-as-errors", str(output), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=45)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
