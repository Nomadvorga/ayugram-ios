"""Compile the actual production AyuSettingsStore with independent Foundation-only tests.

Requires swiftc; --emit-only prepares the host harness without claiming test success.
The production store is included verbatim and uses an isolated temporary defaults suite.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--emit-only", action="store_true")
    args = parser.parse_args()
    source = (args.repo / "Swiftgram/SGSimpleSettings/Sources/AyuSettingsStore.swift").read_text(encoding="utf-8")
    suite = "extera.store.validation." + uuid.uuid4().hex
    harness = "import Foundation\nimport Dispatch\nlet APP_GROUP_IDENTIFIER = " + json.dumps(suite) + "\n" + source + r'''

final class NotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { self.lock.lock(); self.count += 1; self.lock.unlock() }
    var value: Int { self.lock.lock(); defer { self.lock.unlock() }; return self.count }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

let store = AyuSettingsStore.shared
defer { store.userDefaults.removePersistentDomain(forName: APP_GROUP_IDENTIFIER) }
let notifications = NotificationCounter()
let observer = NotificationCenter.default.addObserver(forName: ayuSettingsDidChangeNotification, object: nil, queue: nil) { _ in
    // A custom observer must be able to reenter every getter.
    _ = store.bool("boolean")
    _ = store.int("integer")
    _ = store.string("string")
    _ = store.intDictionary("dictionary")
    notifications.increment()
}
defer { NotificationCenter.default.removeObserver(observer) }

store.register(defaults: ["boolean": false, "integer": 0, "string": "", "dictionary": [String: Int]()])
require(store.bool("boolean") == false, "registered bool default")
require(store.int("integer") == 0, "registered integer default")
require(store.string("string") == "", "registered string default")
require(store.intDictionary("dictionary").isEmpty, "registered dictionary default")
require(store.userDefaults.persistentDomain(forName: APP_GROUP_IDENTIFIER)?["boolean"] == nil, "registered value must initially be absent from persistent domain")

store.setBool(false, "boolean")
store.setInt(0, "integer")
store.setString("", "string")
store.setIntDictionary([:], "dictionary")
let persisted = store.userDefaults.persistentDomain(forName: APP_GROUP_IDENTIFIER) ?? [:]
for key in ["boolean", "integer", "string", "dictionary"] {
    require(persisted[key] != nil, "first explicit default write was skipped: " + key)
}
require(notifications.value == 4, "first writes must each notify outside a batch")
store.setBool(false, "boolean")
store.setInt(0, "integer")
store.setString("", "string")
store.setIntDictionary([:], "dictionary")
require(notifications.value == 4, "equal writes after first explicit write must not notify")

var before = notifications.value
store.performBatchUpdates {
    store.setBool(true, "boolean")
    store.performBatchUpdates {
        store.setInt(12, "integer")
        store.setString("updated", "string")
    }
    require(notifications.value == before, "nested batch notified before outer completion")
    store.setIntDictionary(["value": 12], "dictionary")
}
require(notifications.value == before + 1, "nested batch must emit one final notification")
require(store.bool("boolean") && store.int("integer") == 12 && store.string("string") == "updated", "batch writes not visible")

before = notifications.value
store.performBatchUpdates {}
require(notifications.value == before + 1, "empty/external-only batch must notify")
before = notifications.value
store.performBatchUpdates {
    store.userDefaults.set(true, forKey: "swiftgram-only-sentinel")
}
require(notifications.value == before + 1, "external defaults-only batch must notify")

before = notifications.value
let workerFinished = DispatchSemaphore(value: 0)
store.performBatchUpdates {
    DispatchQueue.global().async {
        store.setInt(81, "worker")
        workerFinished.signal()
    }
    require(workerFinished.wait(timeout: .now() + 3) == .success, "batch closure held the store lock across caller code")
    require(notifications.value == before, "worker setter escaped notification batch")
}
require(notifications.value == before + 1, "batch including worker write must notify once")

// Overlapping batches are a single global coalescing window, not independent transactions.
let innerEntered = DispatchSemaphore(value: 0)
let outerReturned = DispatchSemaphore(value: 0)
let overlapFinished = DispatchSemaphore(value: 0)
before = notifications.value
store.performBatchUpdates {
    DispatchQueue.global().async {
        store.performBatchUpdates {
            innerEntered.signal()
            require(outerReturned.wait(timeout: .now() + 3) == .success, "overlap outer never returned")
            store.setString("overlap", "overlap")
        }
        overlapFinished.signal()
    }
    require(innerEntered.wait(timeout: .now() + 3) == .success, "overlap inner never entered")
}
require(notifications.value == before, "overlapping batch emitted while another remained open")
outerReturned.signal()
require(overlapFinished.wait(timeout: .now() + 3) == .success, "overlap batch never completed")
require(notifications.value == before + 1, "overlapping batches must coalesce into one notification")

DispatchQueue.concurrentPerform(iterations: 500) { index in store.setInt(index, "contended") }
require(store.int("contended") == store.userDefaults.integer(forKey: "contended"), "concurrent writers left cache and defaults inconsistent")

let reentry = NotificationCenter.default.addObserver(forName: ayuSettingsDidChangeNotification, object: nil, queue: nil) { _ in
    if store.int("reentry") == 1 { store.setInt(2, "reentry") }
}
store.setInt(1, "reentry")
NotificationCenter.default.removeObserver(reentry)
require(store.int("reentry") == 2 && store.userDefaults.integer(forKey: "reentry") == 2, "custom observer write reentry failed")
print("Passed production AyuSettingsStore first-write, equality, nesting, empty/external batch, overlapping batch, concurrent writer and observer reentry checks")
'''
    temporary_root = Path(os.environ["LOCALAPPDATA"]) / "Temp/opencode" if sys.platform == "win32" else None
    output = Path(tempfile.mkdtemp(prefix="ayu-store-validation-", dir=temporary_root)) / "AyuSettingsStoreHarness.swift"
    output.write_text(harness, encoding="utf-8")
    print(f"Prepared actual production store harness: {output}")
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
