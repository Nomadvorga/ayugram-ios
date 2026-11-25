import Dispatch
import Foundation
import XCTest

// Compile with the production wrappers and RWLock; see README.md.
private final class Shared<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

private final class ObservedValues: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []

    func append(_ value: Int) {
        self.lock.lock()
        self.storage.append(value)
        self.lock.unlock()
    }

    var values: [Int] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storage
    }
}

/// Pauses a defaults operation after the wrapper has entered it. The pause lets
/// the tests reproduce stale cold reads and reversed persistence order without
/// depending on the scheduler winning a narrow race window.
private final class InstrumentedDefaults: UserDefaults, @unchecked Sendable {
    private let instrumentationLock = NSLock()
    private var pauseRead = false
    private var pauseWrite = false
    private var dictionaryReadCount = 0
    private var writeObserver: (@Sendable (String) -> Void)?
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)

    func pauseNextRead() {
        self.instrumentationLock.lock()
        self.pauseRead = true
        self.instrumentationLock.unlock()
    }

    func pauseNextWrite() {
        self.instrumentationLock.lock()
        self.pauseWrite = true
        self.instrumentationLock.unlock()
    }

    func observeWrites(_ observer: (@Sendable (String) -> Void)?) {
        self.instrumentationLock.lock()
        self.writeObserver = observer
        self.instrumentationLock.unlock()
    }

    var dictionaryReads: Int {
        self.instrumentationLock.lock()
        defer { self.instrumentationLock.unlock() }
        return self.dictionaryReadCount
    }

    override func integer(forKey defaultName: String) -> Int {
        let value = super.integer(forKey: defaultName)
        self.instrumentationLock.lock()
        let pause = defaultName == "value" && self.pauseRead
        if pause { self.pauseRead = false }
        self.instrumentationLock.unlock()
        if pause {
            self.entered.signal()
            _ = self.resume.wait(timeout: .now() + 5.0)
        }
        return value
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        self.instrumentationLock.lock()
        let pause = defaultName == "value" && self.pauseWrite
        if pause { self.pauseWrite = false }
        self.instrumentationLock.unlock()
        if pause {
            self.entered.signal()
            _ = self.resume.wait(timeout: .now() + 5.0)
        }
        super.set(value, forKey: defaultName)
        self.instrumentationLock.lock()
        let observer = self.writeObserver
        self.instrumentationLock.unlock()
        observer?(defaultName)
    }

    override func dictionary(forKey defaultName: String) -> [String: Any]? {
        self.instrumentationLock.lock()
        self.dictionaryReadCount += 1
        self.instrumentationLock.unlock()
        return super.dictionary(forKey: defaultName)
    }
}

final class ExteraSettingsStoreTests: XCTestCase {
    private func withDefaults(_ body: (InstrumentedDefaults) throws -> Void) throws {
        let suite = "ExteraSettingsStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(InstrumentedDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    func testConcurrentWritersKeepCacheAndDefaultsInTheSameOrder() throws {
        try self.withDefaults { defaults in
            let setting = Shared(UserDefault<Int>(key: "value", userDefaults: defaults))
            defaults.pauseNextWrite()
            let writers = DispatchGroup()
            let secondFinished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async(group: writers) {
                setting.value.wrappedValue = 1
            }
            XCTAssertEqual(defaults.entered.wait(timeout: .now() + 2.0), .success)
            defer { defaults.resume.signal() }
            DispatchQueue.global().async(group: writers) {
                setting.value.wrappedValue = 2
                secondFinished.signal()
            }
            // The unfixed wrapper lets writer 2 finish while writer 1 is paused,
            // then persists 1 over 2. A serialized setter blocks writer 2 here.
            _ = secondFinished.wait(timeout: .now() + 0.1)
            defaults.resume.signal()
            let result = writers.wait(timeout: .now() + 5.0)
            XCTAssertEqual(result, .success)
            guard result == .success else { return }
            XCTAssertEqual(setting.value.wrappedValue, 2)
            XCTAssertEqual(defaults.integer(forKey: "value"), 2)
        }
    }

    func testColdReadCannotReplaceANewerWrite() throws {
        try self.withDefaults { defaults in
            defaults.set(10, forKey: "value")
            let setting = Shared(UserDefault<Int>(key: "value", userDefaults: defaults))
            defaults.pauseNextRead()
            let operations = DispatchGroup()
            let writerFinished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async(group: operations) {
                _ = setting.value.wrappedValue
            }
            XCTAssertEqual(defaults.entered.wait(timeout: .now() + 2.0), .success)
            defer { defaults.resume.signal() }
            DispatchQueue.global().async(group: operations) {
                setting.value.wrappedValue = 42
                writerFinished.signal()
            }
            // The old getter has already extracted 10 but has not cached it.
            // It must not overwrite the setter's cache after that setter returns.
            _ = writerFinished.wait(timeout: .now() + 0.1)
            defaults.resume.signal()
            let result = operations.wait(timeout: .now() + 5.0)
            XCTAssertEqual(result, .success)
            guard result == .success else { return }
            XCTAssertEqual(setting.value.wrappedValue, 42)
            XCTAssertEqual(defaults.integer(forKey: "value"), 42)
        }
    }

    func testConcurrentCacheReadsAndWritesStress() throws {
        try self.withDefaults { defaults in
            defaults.register(defaults: ["text": "initial"])
            let number = Shared(UserDefault<Int>(key: "number", userDefaults: defaults))
            let text = Shared(UserDefault<String>(key: "text", userDefaults: defaults))
            for round in 0 ..< 8 {
                DispatchQueue.concurrentPerform(iterations: 256) { index in
                    number.value.wrappedValue = round * 256 + index
                    text.value.wrappedValue = "value-\(round)-\(index)"
                    XCTAssertGreaterThanOrEqual(number.value.wrappedValue, 0)
                    XCTAssertTrue(text.value.wrappedValue.hasPrefix("value-"))
                }
                // No writer remains: disk and cache must agree regardless of
                // which writer acquired the lock last. Do not mask this with a
                // final serial setter before comparing.
                XCTAssertEqual(number.value.wrappedValue, defaults.integer(forKey: "number"))
                XCTAssertEqual(text.value.wrappedValue, defaults.string(forKey: "text"))
            }
        }
    }

    func testSynchronousDefaultsCallbackCanReadAndSetTheSamePreference() throws {
        try self.withDefaults { defaults in
            let setting = Shared(UserDefault<Int>(key: "value", userDefaults: defaults))
            let observed = ObservedValues()
            // Model a synchronous defaults notification after its write has been
            // committed. This runs on every host, independent of Foundation's
            // platform-specific notification timing.
            defaults.observeWrites { key in
                guard key == "value" else { return }
                let value = setting.value.wrappedValue
                observed.append(value)
                if value == 1 {
                    setting.value.wrappedValue = 2
                }
            }
            defer { defaults.observeWrites(nil) }
            let operation = DispatchGroup()
            DispatchQueue.global().async(group: operation) {
                setting.value.wrappedValue = 1
            }
            let result = operation.wait(timeout: .now() + 2.0)
            XCTAssertEqual(result, .success, "A synchronous defaults callback deadlocked the cache lock")
            guard result == .success else { return }
            XCTAssertEqual(observed.values, [1, 2])
            XCTAssertEqual(setting.value.wrappedValue, 2, "The outer setter must not republish 1 after its observer sets 2")
            XCTAssertEqual(defaults.integer(forKey: "value"), 2)
        }
    }

    func testFoundationDefaultsNotificationCanReenterWhenDeliveredSynchronously() throws {
        try self.withDefaults { defaults in
            let setting = Shared(UserDefault<Int>(key: "value", userDefaults: defaults))
            let observed = ObservedValues()
            let token = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: nil) { _ in
                observed.append(setting.value.wrappedValue)
            }
            defer { NotificationCenter.default.removeObserver(token) }
            let operation = DispatchGroup()
            DispatchQueue.global().async(group: operation) {
                setting.value.wrappedValue = 77
            }
            let result = operation.wait(timeout: .now() + 2.0)
            XCTAssertEqual(result, .success, "Foundation's defaults notification deadlocked a reentrant getter")
            guard result == .success else { return }
            // Some hosts defer or omit this notification for an isolated suite.
            // The deterministic callback test above always covers synchronous
            // reentry; validate every real notification that this host delivers.
            XCTAssertTrue(observed.values.allSatisfy { $0 == 77 })
            XCTAssertEqual(setting.value.wrappedValue, 77)
            XCTAssertEqual(defaults.integer(forKey: "value"), 77)
        }
    }

    func testDefaultsCallbackOnAnotherQueueCanReadDuringAWrite() throws {
        try self.withDefaults { defaults in
            let setting = Shared(UserDefault<Int>(key: "value", userDefaults: defaults))
            let observed = ObservedValues()
            let acknowledgements = ObservedValues()
            let observerQueue = DispatchQueue(label: "ExteraSettingsStoreTests.defaultsObserver")
            let reader = DispatchGroup()
            defaults.observeWrites { key in
                guard key == "value" else { return }
                let acknowledged = DispatchSemaphore(value: 0)
                observerQueue.async(group: reader) {
                    observed.append(setting.value.wrappedValue)
                    acknowledged.signal()
                }
                // Model NotificationCenter delivering synchronously on a
                // different queue, as MediaPicker's queue: .main observer can.
                // Bound the wait so a regression reports a failure instead of
                // deadlocking the test runner's main thread permanently.
                let result = acknowledged.wait(timeout: .now() + 1.0)
                acknowledgements.append(result == .success ? 1 : 0)
            }
            defer { defaults.observeWrites(nil) }
            let writer = DispatchGroup()
            DispatchQueue.global().async(group: writer) {
                setting.value.wrappedValue = 77
            }
            let result = writer.wait(timeout: .now() + 3.0)
            XCTAssertEqual(result, .success)
            guard result == .success else { return }
            XCTAssertEqual(reader.wait(timeout: .now() + 2.0), .success)
            XCTAssertEqual(acknowledgements.values, [1], "The observer must read before the defaults setter returns")
            XCTAssertEqual(observed.values, [77])
            XCTAssertEqual(setting.value.wrappedValue, 77)
            XCTAssertEqual(defaults.integer(forKey: "value"), 77)
        }
    }

    func testConcurrentFirstDictionaryReadsInitializeOnlyOnce() throws {
        try self.withDefaults { defaults in
            let seed = Dictionary(uniqueKeysWithValues: (0 ..< 32).map { ("key-\($0)", $0) })
            defaults.set(seed, forKey: "dictionary")
            // Each round is a fresh cache; its first API reads run concurrently.
            for round in 0 ..< 16 {
                let dictionary = Shared(UserDefaultsBackedDictionary<String, Int>(userDefaultsKey: "dictionary", userDefaults: defaults, threadSafe: true))
                DispatchQueue.concurrentPerform(iterations: 128) { index in
                    XCTAssertEqual(Set(dictionary.value.keys), Set(seed.keys))
                    XCTAssertEqual(Set(dictionary.value.values), Set(seed.values))
                    XCTAssertTrue(dictionary.value.contains("key-\(index % 32)"))
                    XCTAssertEqual(dictionary.value["key-\(index % 32)"], index % 32)
                }
                XCTAssertEqual(defaults.dictionaryReads, round + 1)
            }
            XCTAssertEqual(defaults.dictionary(forKey: "dictionary") as? [String: Int], seed)
        }
    }

    func testDictionaryMutationsRemainAtomicAndPersisted() throws {
        try self.withDefaults { defaults in
            defaults.set(["count": 0], forKey: "dictionary")
            let dictionary = Shared(UserDefaultsBackedDictionary<String, Int>(userDefaultsKey: "dictionary", userDefaults: defaults, threadSafe: true))
            DispatchQueue.concurrentPerform(iterations: 512) { index in
                dictionary.value.mutateValue(forKey: "count") { $0 + 1 }
                dictionary.value.set(value: index, forKey: "key-\(index)")
                XCTAssertTrue(dictionary.value.contains("count"))
                XCTAssertNotNil(dictionary.value.value(forKey: "count"))
                _ = dictionary.value.keys
                _ = dictionary.value.values
            }
            XCTAssertEqual(dictionary.value["count"], 512)
            XCTAssertEqual(dictionary.value.keys.count, 513)
            let stored = try XCTUnwrap(defaults.dictionary(forKey: "dictionary") as? [String: Int])
            XCTAssertEqual(stored["count"], 512)
            for index in 0 ..< 512 {
                XCTAssertEqual(dictionary.value["key-\(index)"], index)
                XCTAssertEqual(stored["key-\(index)"], index)
            }
        }
    }

    func testMissingDictionaryAndRepeatedDrop() throws {
        try self.withDefaults { defaults in
            for threadSafe in [false, true] {
                let key = "missing-\(threadSafe)"
                let dictionary = UserDefaultsBackedDictionary<String, Int>(userDefaultsKey: key, userDefaults: defaults, threadSafe: threadSafe)
                XCTAssertTrue(dictionary.isEmpty)
                XCTAssertTrue(dictionary.values.isEmpty)
                XCTAssertFalse(dictionary.contains("absent"))
                XCTAssertNil(dictionary["absent"])
                XCTAssertNil(dictionary.remove("absent"))
                dictionary.drop()
                dictionary.drop()
                XCTAssertTrue(dictionary.isEmpty)
                XCTAssertNil(defaults.object(forKey: key))
                dictionary["present"] = 7
                XCTAssertEqual(dictionary.removeValue(forKey: "present"), 7)
                dictionary["again"] = 8
                dictionary.drop()
                XCTAssertNil(dictionary["again"])
                XCTAssertNil(defaults.object(forKey: key))
            }
        }
    }

    func testDropRestoresRegisteredDictionaryDefaults() throws {
        try self.withDefaults { defaults in
            defaults.register(defaults: ["dictionary": ["registered": 3], "unrelated": "keep"])
            for threadSafe in [false, true] {
                let dictionary = UserDefaultsBackedDictionary<String, Int>(userDefaultsKey: "dictionary", userDefaults: defaults, threadSafe: threadSafe)
                XCTAssertEqual(dictionary["registered"], 3)
                dictionary["custom"] = 4
                dictionary.drop()
                XCTAssertEqual(dictionary["registered"], 3)
                XCTAssertNil(dictionary["custom"])
                XCTAssertEqual(defaults.string(forKey: "unrelated"), "keep")
                XCTAssertEqual(defaults.dictionary(forKey: "dictionary") as? [String: Int], ["registered": 3])
            }
        }
    }

    func testNonThreadSafeDictionaryRetainsLazyDefaultRead() throws {
        try self.withDefaults { defaults in
            let dictionary = UserDefaultsBackedDictionary<String, Int>(userDefaultsKey: "late", userDefaults: defaults, threadSafe: false)
            XCTAssertEqual(defaults.dictionaryReads, 0)
            defaults.register(defaults: ["late": ["registered": 3]])
            XCTAssertEqual(dictionary["registered"], 3)
            XCTAssertEqual(defaults.dictionaryReads, 1)
        }
    }

    func testRegisteredScalarDefaultsAndSupportedTypesArePreserved() throws {
        try self.withDefaults { defaults in
            defaults.register(defaults: ["flag": true, "small": 42, "large": 99, "text": "registered", "array": ["a", "b"]])
            XCTAssertTrue(UserDefault<Bool>(key: "flag", userDefaults: defaults).wrappedValue)
            XCTAssertEqual(UserDefault<Int32>(key: "small", userDefaults: defaults).wrappedValue, 42)
            XCTAssertEqual(UserDefault<Int64>(key: "large", userDefaults: defaults).wrappedValue, 99)
            XCTAssertEqual(UserDefault<String>(key: "text", userDefaults: defaults).wrappedValue, "registered")
            XCTAssertEqual(UserDefault<[String]>(key: "array", userDefaults: defaults).wrappedValue, ["a", "b"])
            XCTAssertEqual(UserDefault<Int>(key: "missing", userDefaults: defaults).wrappedValue, 0)
        }
    }

    static let allTests = [
        ("testConcurrentWritersKeepCacheAndDefaultsInTheSameOrder", testConcurrentWritersKeepCacheAndDefaultsInTheSameOrder),
        ("testColdReadCannotReplaceANewerWrite", testColdReadCannotReplaceANewerWrite),
        ("testConcurrentCacheReadsAndWritesStress", testConcurrentCacheReadsAndWritesStress),
        ("testSynchronousDefaultsCallbackCanReadAndSetTheSamePreference", testSynchronousDefaultsCallbackCanReadAndSetTheSamePreference),
        ("testFoundationDefaultsNotificationCanReenterWhenDeliveredSynchronously", testFoundationDefaultsNotificationCanReenterWhenDeliveredSynchronously),
        ("testDefaultsCallbackOnAnotherQueueCanReadDuringAWrite", testDefaultsCallbackOnAnotherQueueCanReadDuringAWrite),
        ("testConcurrentFirstDictionaryReadsInitializeOnlyOnce", testConcurrentFirstDictionaryReadsInitializeOnlyOnce),
        ("testDictionaryMutationsRemainAtomicAndPersisted", testDictionaryMutationsRemainAtomicAndPersisted),
        ("testMissingDictionaryAndRepeatedDrop", testMissingDictionaryAndRepeatedDrop),
        ("testDropRestoresRegisteredDictionaryDefaults", testDropRestoresRegisteredDictionaryDefaults),
        ("testNonThreadSafeDictionaryRetainsLazyDefaultRead", testNonThreadSafeDictionaryRetainsLazyDefaultRead),
        ("testRegisteredScalarDefaultsAndSupportedTypesArePreserved", testRegisteredScalarDefaultsAndSupportedTypesArePreserved),
    ]
}

@main
private enum ExteraSettingsStoreTestRunner {
    static func main() {
        XCTMain([testCase(ExteraSettingsStoreTests.allTests)])
    }
}
