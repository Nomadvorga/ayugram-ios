"""Targeted Foundation host tests of production AI cache and backup flag orchestration.

Extracts production declarations verbatim. Only Keychain methods are omitted, the AI
singleton/initializer are opened for isolated fixtures, and unrelated backup entries
are replaced by one ordinary bool. An instrumented store counts reads/writes and
models the production nonlocking batch closure; it does not reimplement AI logic.
Requires swiftc; --emit-only prepares a reviewable harness on Windows.
"""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

from run_extera_backup_validation import declaration


def make_harness(repo):
    sources = repo / "Swiftgram/SGSimpleSettings/Sources"
    ai = (sources / "ExteraAISettings.swift").read_text(encoding="utf-8")
    ai = ai.replace("import Security\n", "")
    ai = ai[:ai.index("    public func apiKey(")] + ai[ai.index("    private func historyKey("):]
    ai = re.sub(r'^    private let keychainService = .*\n', '', ai, flags=re.M)
    ai = ai.replace("public static let shared = ExteraAISettings()", "public static var shared = ExteraAISettings()")
    ai = ai.replace("private init() {}", "fileprivate init() {}")
    backup = (sources / "ExteraSettingsBackup.swift").read_text(encoding="utf-8")
    start = backup.index("    private static let settings: [Setting] = [")
    end = backup.index("\n    ]", start) + len("\n    ]")
    flags = "\n".join(line for line in backup[start:end].splitlines() if any(helper in line for helper in ["aiBoolean(", "aiTemperature(", "aiSummaryPolicy("]))
    backup = backup[:start] + '''    private static let settings: [Setting] = [
''' + flags + '''
        boolean("extera.fixture", read: { SGSimpleSettings.shared.fixture }, write: { SGSimpleSettings.shared.fixture = $0 }),
    ]''' + backup[end:]
    start = backup.index("    private static func integer(")
    end = backup.index("    // Explicit allowlist:", start)
    backup = backup[:start] + backup[end:]
    browser = (sources / "ExteraBrowserSettings.swift").read_text(encoding="utf-8")
    stubs = r'''
import Foundation
import Dispatch

let APP_GROUP_IDENTIFIER = "extera-ai-validation-" + UUID().uuidString
let ayuSettingsDidChangeNotification = Notification.Name("ExteraAIValidationChanged")

final class AyuSettingsStore {
    static let shared = AyuSettingsStore()
    static let didChangeNotification = Notification.Name("FixtureStoreDidChange")
    var strings: [String: String] = [:]
    var reads = 0
    var writes = 0
    var depth = 0
    var onWrite: (() -> Void)?
    func string(_ key: String) -> String { reads += 1; return strings[key] ?? "" }
    func setString(_ value: String, _ key: String) {
        strings[key] = value
        writes += 1
        onWrite?()
    }
    func performBatchUpdates(_ body: () -> Void) {
        depth += 1
        body()
        depth -= 1
        if depth == 0 { NotificationCenter.default.post(name: Self.didChangeNotification, object: nil) }
    }
}

final class SGSimpleSettings {
    static let shared = SGSimpleSettings()
    var fixture = false
    var synchronizations = 0
    func synchronizeShared() { synchronizations += 1 }
}

func require(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}

func mustThrow(_ message: String, _ body: () throws -> Void) {
    do { try body() } catch { return }
    fatalError(message)
}
'''
    tests = r'''
let store = AyuSettingsStore.shared
let key = "extera.ai.configuration.v1"
let simple = SGSimpleSettings.shared
func seed(_ json: String) {
    store.strings = [key: json]
    store.reads = 0
    store.writes = 0
    store.onWrite = nil
    ExteraAISettings.shared = ExteraAISettings()
}
func document(_ settings: [String: Any]) throws -> ExteraSettingsBackup.ValidatedBackup {
    try ExteraSettingsBackup.validate(data: JSONSerialization.data(withJSONObject: [
        "format": ExteraSettingsBackup.format, "version": 1, "settings": settings
    ]))
}

// Old Codable payloads default all three independent flags to true; hot reads decode once.
seed("{}")
for _ in 0 ..< 10000 {
    let value = ExteraAISettings.shared.configuration
    require(value.showEditor && value.showSummaries && value.showInstantViewSummaries, "legacy default flags")
}
require(store.reads == 1, "layout reads repeatedly load/decode configuration")
seed("malformed")
for _ in 0 ..< 100 { require(ExteraAISettings.shared.configuration.showSummaries, "malformed defaults") }
require(store.reads == 1, "malformed default path is not cached")

seed("{}")
try ExteraAISettings.shared.update { value in
    value.services = [.init(id: "sentinel-service", name: "Private service", endpoint: "https://private.example/v1", model: "model")]
    value.roles = [.init(id: "sentinel-role", name: "Private role", prompt: "Private prompt")]
    value.selectedServiceId = "sentinel-service"
    value.selectedRoleId = "sentinel-role"
    value.saveHistory = false
    value.responseStreaming = false
    value.useForTextProcessing = true
    value.showEditor = false
    value.showSummaries = false
    value.showInstantViewSummaries = false
    value.showResponseOnly = true
    value.insertAsQuote = false
    value.temperature = 0.3
    value.replaceTelegramSummaries = true
}
try ExteraAISettings.shared.setHistory([.init(role: .user, content: "private question"), .init(role: .assistant, content: "private answer")], accountId: "account")
store.strings["credential-sentinel"] = "private-key"
let original = ExteraAISettings.shared.configuration
let privateHistory = ExteraAISettings.shared.history(accountId: "account")
let persisted = store.strings[key]

var aiNotifications = 0
let observer = NotificationCenter.default.addObserver(forName: ExteraAISettings.didChangeNotification, object: nil, queue: nil) { _ in
    // A different thread must read configuration while the notification is being delivered.
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { _ = ExteraAISettings.shared.configuration; finished.signal() }
    require(finished.wait(timeout: .now() + 3) == .success, "AI notification delivered under mutation lock")
    aiNotifications += 1
}
defer { NotificationCenter.default.removeObserver(observer) }
mustThrow("nonfinite update accepted") { try ExteraAISettings.shared.update { $0.temperature = .nan } }
mustThrow("duplicate service accepted") { try ExteraAISettings.shared.update { $0.services.append($0.services[0]) } }
mustThrow("oversized serialization accepted") { try ExteraAISettings.shared.update { $0.roles[0].prompt = String(repeating: "x", count: 1024 * 1024) } }
require(ExteraAISettings.shared.configuration == original && store.strings[key] == persisted, "failed update changed cache/persistence")
require(aiNotifications == 0, "failed update emitted AI success notification")

let exported = try JSONSerialization.jsonObject(with: ExteraSettingsBackup.exportData()) as! [String: Any]
let exportedSettings = exported["settings"] as! [String: Any]
require(Set(exportedSettings.keys) == ["extera.fixture", "extera.ai.showEditor", "extera.ai.showSummaries", "extera.ai.showInstantViewSummaries", "extera.ai.showResponseOnly", "extera.ai.insertAsQuote", "extera.ai.temperatureTenths", "extera.ai.replaceTelegramSummaries"], "unexpected AI backup scope")
let beforeValidation = store.strings
let writesBeforeValidation = store.writes
for flag in ["showEditor", "showSummaries", "showInstantViewSummaries", "showResponseOnly", "insertAsQuote"] {
    for invalid in [1, "true", NSNull()] as [Any] {
        mustThrow("invalid AI boolean accepted") { _ = try document(["extera.ai." + flag: invalid]) }
    }
}
for privateName in ["configuration.v1", "services", "roles", "history", "apiKey", "useForTextProcessing"] {
    mustThrow("private AI field accepted") { _ = try document(["extera.ai." + privateName: true]) }
}
for invalid in [-1, 21, 1.5, true, "10", NSNull()] as [Any] {
    mustThrow("invalid temperature accepted") { _ = try document(["extera.ai.temperatureTenths": invalid]) }
}
for invalid in [true, "auto", "", NSNull()] as [Any] {
    mustThrow("invalid summary policy accepted") { _ = try document(["extera.ai.replaceTelegramSummaries": invalid]) }
}
mustThrow("mixed valid/invalid flags accepted") {
    _ = try document(["extera.ai.showEditor": true, "extera.ai.showSummaries": "false", "extera.fixture": true])
}
require(store.strings == beforeValidation && store.writes == writesBeforeValidation, "validation mutated persistence")

var writes = store.writes
try ExteraSettingsBackup.apply(document(["extera.fixture": true]))
require(store.writes == writes && ExteraAISettings.shared.configuration == original, "unrelated partial import rewrote AI configuration")
store.onWrite = { require(ExteraAISettings.shared.configuration.showSummaries, "synchronous store reader saw stale AI cache") }
try ExteraSettingsBackup.apply(document(["extera.ai.showSummaries": true]))
store.onWrite = nil
var expected = original
expected.showSummaries = true
require(ExteraAISettings.shared.configuration == expected, "partial flag import changed missing flags/private configuration")
require(store.writes == writes + 1, "partial flag import must use one AI write")
writes = store.writes
try ExteraSettingsBackup.apply(document([
    "extera.ai.showEditor": true, "extera.ai.showSummaries": false, "extera.ai.showInstantViewSummaries": true
]))
require(store.writes == writes + 1, "multiple flags were serialized separately")
require(aiNotifications == 2, "one AI notification per successful flag update")

writes = store.writes
try ExteraSettingsBackup.reset()
expected = original
expected.showEditor = true
expected.showSummaries = true
expected.showInstantViewSummaries = true
expected.showResponseOnly = false
expected.insertAsQuote = true
expected.temperature = 1.0
expected.replaceTelegramSummaries = nil
require(ExteraAISettings.shared.configuration == expected, "reset changed private configuration or missed flag defaults")
require(store.writes == writes + 1 && !simple.fixture, "reset did not apply defaults in one AI write")
require(ExteraAISettings.shared.history(accountId: "account") == privateHistory, "reset changed history")
require(store.strings["credential-sentinel"] == "private-key", "reset changed credential sentinel")

for (policy, value) in [("automatic", nil), ("enabled", true), ("disabled", false)] as [(String, Bool?)] {
    writes = store.writes
    try ExteraSettingsBackup.apply(document([
        "extera.ai.replaceTelegramSummaries": policy,
        "extera.ai.temperatureTenths": 7,
        "extera.ai.showResponseOnly": true,
        "extera.ai.insertAsQuote": false
    ]))
    let updated = ExteraAISettings.shared.configuration
    require(updated.replaceTelegramSummaries == value && updated.temperature == 0.7, "scalar AI preferences failed to import")
    require(updated.showResponseOnly && !updated.insertAsQuote, "response flags failed to import")
    require(updated.services == original.services && updated.roles == original.roles, "scalar import changed services/roles")
    require(store.writes == writes + 1, "mixed AI preferences must serialize once")
    let exportedPolicy = try JSONSerialization.jsonObject(with: ExteraSettingsBackup.exportData()) as! [String: Any]
    let settings = exportedPolicy["settings"] as! [String: Any]
    require(settings["extera.ai.replaceTelegramSummaries"] as? String == policy, "summary automatic state lost in export")
}

// A valid backup can fail to persist against an out-of-limits legacy configuration.
// Both import and reset must fail before ordinary settings or shared synchronization change.
seed("{\"roles\":[{\"id\":\"duplicate\",\"name\":\"A\",\"prompt\":\"A\"},{\"id\":\"duplicate\",\"name\":\"B\",\"prompt\":\"B\"}]}")
simple.fixture = true
let synchronizations = simple.synchronizations
let beforeNotifications = aiNotifications
let invalidConfiguration = ExteraAISettings.shared.configuration
mustThrow("apply swallowed AI persistence failure") {
    try ExteraSettingsBackup.apply(document(["extera.fixture": false, "extera.ai.showEditor": false]))
}
mustThrow("reset swallowed AI persistence failure") { try ExteraSettingsBackup.reset() }
require(simple.fixture && simple.synchronizations == synchronizations && store.writes == 0, "failed AI import/reset partially wrote preferences")
require(ExteraAISettings.shared.configuration == invalidConfiguration && aiNotifications == beforeNotifications, "failed backup changed AI cache or notified success")
try ExteraSettingsBackup.apply(document(["extera.fixture": false]))
require(!simple.fixture && store.writes == 0, "AI-free import should not validate/rewrite legacy AI configuration")
print("Passed production AI cache, failure isolation, strict bool allowlist, partial import, grouped writes, private-state preservation, reset and notification-lock checks")
'''
    navigation = (sources / "ExteraNavigationSettings.swift").read_text(encoding="utf-8")
    return stubs + navigation + ai + "\nenum ExteraBrowserSettings {\n" + declaration(browser, "public static func normalizedHost") + "\n}\n" + backup + tests


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--emit-only", action="store_true")
    args = parser.parse_args()
    temporary_root = Path(os.environ["LOCALAPPDATA"]) / "Temp/opencode" if sys.platform == "win32" else None
    output = Path(tempfile.mkdtemp(prefix="extera-ai-backup-validation-", dir=temporary_root)) / "ExteraAIBackupHarness.swift"
    output.write_text(make_harness(args.repo), encoding="utf-8")
    print(f"Prepared production AI/backup harness: {output}")
    if args.emit_only:
        return 0
    compiler = shutil.which("swiftc")
    if not compiler:
        print("NOT RUN: swiftc unavailable; harness preparation is not a passing runtime test.", file=sys.stderr)
        return 2
    executable = output.with_suffix(".exe" if sys.platform == "win32" else "")
    subprocess.run([compiler, "-swift-version", "5", str(output), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=30)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
