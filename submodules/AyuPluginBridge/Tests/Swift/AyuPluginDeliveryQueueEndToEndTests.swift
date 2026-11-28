import Foundation
import XCTest
@testable import AyuPluginBridge

/// A backend that only holds `telegram.request` completions until the test answers them.
private final class HeldRequestBackend: AyuPluginTelegramBackend, @unchecked Sendable {
    typealias Completion = @Sendable (AyuPluginTelegramRequestResult) -> Void
    let held = AyuTestBox<[Completion]>([])
    let functions = AyuTestBox<[Data]>([])
    let operations: Set<String> = [AyuPluginTelegramBridge.Operation.request, AyuPluginTelegramBridge.Operation.requestCancel]
    let sendMessageParameters: Set<String> = []
    let sendHookMutableFields: Set<String> = []

    func sendRequest(account: AyuPluginTelegramAccount, function: Data, flags: Int32, completion: @escaping Completion) throws -> AyuPluginTelegramCancellation {
        self.functions.update { $0.append(function) }
        self.held.update { $0.append(completion) }
        return AyuPluginTelegramCancellation {}
    }
    func connectionState(account: AyuPluginTelegramAccount, completion: @escaping @Sendable (Result<AyuPluginTelegramConnectionState, AyuPluginTelegramBackendError>) -> Void) { completion(.failure(.unsupported("test"))) }
    func hookFilterDidChange(_ filter: AyuPluginTelegramHookFilter) {}
    func sendMessage(account: AyuPluginTelegramAccount, message: AyuPluginTelegramOutgoingMessage, completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void) { completion(.failure(.unsupported("test"))) }
    func editMessage(account: AyuPluginTelegramAccount, edit: AyuPluginTelegramMessageEdit, completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void) { completion(.failure(.unsupported("test"))) }
    func peer(account: AyuPluginTelegramAccount, kind: AyuPluginTelegramPeerKind, id: Int64, completion: @escaping @Sendable (Result<Data?, AyuPluginTelegramBackendError>) -> Void) { completion(.failure(.unsupported("test"))) }
    func messages(account: AyuPluginTelegramAccount, dialogID: Int64, ids: [Int32], completion: @escaping @Sendable (Result<[Data?], AyuPluginTelegramBackendError>) -> Void) { completion(.failure(.unsupported("test"))) }
    func navigate(account: AyuPluginTelegramAccount, target: AyuPluginTelegramNavigationTarget, completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void) { completion(.failure(.unsupported("test"))) }
    func filePath(account: AyuPluginTelegramAccount, target: Data, cache: Bool, completion: @escaping @Sendable (Result<String, AyuPluginTelegramBackendError>) -> Void) { completion(.failure(.unsupported("test"))) }
    func loadFile(account: AyuPluginTelegramAccount, target: Data, parent: Data?, priority: Int32, cacheType: Int32, completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void) { completion(.failure(.unsupported("test"))) }
    func cancelFileLoad(account: AyuPluginTelegramAccount, target: Data, completion: @escaping @Sendable (Result<Void, AyuPluginTelegramBackendError>) -> Void) { completion(.failure(.unsupported("test"))) }
    func player(action: AyuPluginTelegramPlayerAction, completion: @escaping @Sendable (Result<AyuPluginTelegramPlayerState, AyuPluginTelegramBackendError>) -> Void) { completion(.failure(.unsupported("test"))) }
}

/// Boxed `dataJSON#7d748d04 data:string`.
private func dataJSON(_ text: String) -> Data {
    var data = Data([0x04, 0x8d, 0x74, 0x7d])
    let bytes = Array(text.utf8)
    if bytes.count < 254 {
        data.append(UInt8(bytes.count))
    } else {
        data.append(contentsOf: [254, UInt8(bytes.count & 0xff), UInt8((bytes.count >> 8) & 0xff), UInt8((bytes.count >> 16) & 0xff)])
    }
    data.append(contentsOf: bytes)
    while data.count % 4 != 0 { data.append(0) }
    return data
}

/// Host-to-Python deliveries under a burst: every callback reaches the real interpreter exactly
/// once and in the order its producer handed it over, while the interpreter is busy.
@MainActor
final class AyuPluginDeliveryQueueEndToEndTests: XCTestCase {
    /// Rows shared by the fixtures: `Busy` keeps the interpreter in one callback, `Dump` stores what arrived.
    private static let rows = """
        def busy(self, view):
            time.sleep(0.6)

        def dump(self):
            self.set_setting("seen", self.seen)
            return []

        def create_settings(self):
            return [Text(text="Busy", on_click=self.busy), Input(key="value", text="Value", default="", on_change=self.changed),
                    Text(text="Dump", create_sub_fragment=self.dump)]
    """

    /// Runs the `Dump` row and returns the setting it stores, read behind everything queued for
    /// the plugin so far. Callbacks that come through the native host reach that queue
    /// asynchronously, and the dump itself is refused while the queue is full, so it is repeated
    /// until `accepted` or a deadline.
    private func dump(_ stack: AyuEndToEnd, _ id: String, _ rows: [AyuPluginSetting], _ key: String, until accepted: (AyuBridgeValue) -> Bool) async throws -> AyuBridgeValue {
        let dump = try XCTUnwrap(rows[2].descriptor["create_sub_fragment"]["$callback"].string)
        let deadline = Date().addingTimeInterval(15)
        while true {
            let ran = (try? await stack.service.subpage(pluginID: id, callbackID: dump)) != nil
            let value = stack.stored(id, key)
            if (ran && accepted(value)) || Date() >= deadline { return value }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func seen(_ stack: AyuEndToEnd, _ id: String, _ rows: [AyuPluginSetting], count: Int) async throws -> [AyuBridgeValue] {
        try await self.dump(stack, id, rows, "seen") { ($0.array?.count ?? 0) >= count }.array ?? []
    }

    func testSettingsCallbackBurstIsDeliveredExactlyOnceInOrder() async throws {
        let stack = try AyuEndToEnd.shared()
        let id = try await stack.start(AyuEndToEnd.source(id: "e2e_burst_rows", """
        import time
        from base_plugin import BasePlugin
        from ui.settings import Input, Text


        class BurstPlugin(BasePlugin):
            def on_plugin_load(self):
                self.seen = []

            def changed(self, value):
                index, _, padding = value.partition(":")
                self.seen.append([int(index), len(padding)])

        \(Self.rows)
        """))
        let rows = try await stack.service.settings(id)
        let sizes = [0, 64, 1024, 8000]
        stack.service.activate(rows[0], pluginID: id)
        for index in 0..<300 {
            try await stack.service.set(rows[1], value: .string("\(index):" + String(repeating: "x", count: sizes[index % sizes.count])), pluginID: id)
        }
        let seen = try await self.seen(stack, id, rows, count: 300)
        let expected = (0..<300).map { AyuBridgeValue.array([.integer(Int64($0)), .integer(Int64(sizes[$0 % sizes.count]))]) }
        XCTAssertEqual(seen.count, expected.count, "delivered callbacks")
        XCTAssertEqual(seen, expected)
        XCTAssertNil(stack.record(id)?.error)
        await stack.remove(id)
    }

    func testTelegramResponseBurstReachesEveryRequestCallback() async throws {
        let stack = try AyuEndToEnd.shared()
        stack.bindApplication()
        let backend = HeldRequestBackend()
        AyuPluginTelegramBridge.shared.bind(backend: backend)
        defer { AyuPluginTelegramBridge.shared.bind(backend: nil); stack.unbindApplication() }
        let id = try await stack.start(AyuEndToEnd.source(id: "e2e_burst_requests", """
        import time
        from base_plugin import BasePlugin
        from client_utils import send_request
        from org.telegram.tgnet import TLRPC
        from ui.settings import Input, Text


        class RequestPlugin(BasePlugin):
            def on_plugin_load(self):
                self.seen = []
                for index in range(64):
                    send_request(TLRPC.TL_help_getNearestDc(), self.answer(index))

            def answer(self, index):
                def done(response, error):
                    if error is not None:
                        self.seen.append([index, error.code, error.text])
                    elif response is None:
                        self.seen.append([index, None, None])
                    else:
                        self.seen.append([index, int(response.data.partition(":")[0]), len(response.data)])
                return done

            def changed(self, value):
                pass

        \(Self.rows)
        """))
        let rows = try await stack.service.settings(id)
        let completions = backend.held.value
        XCTAssertEqual(completions.count, 64)
        let sizes = [8, 200, 20_000, 150_000]
        let payloads = completions.indices.map { index -> String in
            let prefix = "\(index):"
            return prefix + String(repeating: "j", count: sizes[index % sizes.count] - prefix.utf8.count)
        }
        stack.service.activate(rows[0], pluginID: id)
        await Task.detached {
            for (completion, payload) in zip(completions, payloads) { completion(.response(dataJSON(payload))) }
        }.value
        let seen = try await self.seen(stack, id, rows, count: 64)
        let expected = completions.indices.map { AyuBridgeValue.array([.integer(Int64($0)), .integer(Int64($0)), .integer(Int64(sizes[$0 % sizes.count]))]) }
        XCTAssertEqual(seen.count, expected.count, "delivered request callbacks")
        XCTAssertEqual(seen, expected)
        XCTAssertNil(stack.record(id)?.error)
        await stack.remove(id)
    }

    /// More response bytes than a plugin's queue holds: every request callback still fires once,
    /// in order, the ones without room with the transport failure of the contract.
    func testResponsesBeyondTheQueueBytesArriveAsTransportFailures() async throws {
        let stack = try AyuEndToEnd.shared()
        stack.bindApplication()
        let backend = HeldRequestBackend()
        AyuPluginTelegramBridge.shared.bind(backend: backend)
        defer { AyuPluginTelegramBridge.shared.bind(backend: nil); stack.unbindApplication() }
        let id = try await stack.start(AyuEndToEnd.source(id: "e2e_burst_overflow", """
        import time
        from base_plugin import BasePlugin
        from client_utils import send_request
        from org.telegram.tgnet import TLRPC
        from ui.settings import Input, Text


        class OverflowPlugin(BasePlugin):
            def on_plugin_load(self):
                self.seen = []
                for index in range(64):
                    send_request(TLRPC.TL_help_getNearestDc(), self.answer(index))

            def answer(self, index):
                def done(response, error):
                    if error is not None:
                        self.seen.append([index, error.code, error.text])
                    else:
                        self.seen.append([index, int(response.data.partition(":")[0]), len(response.data)])
                return done

            def changed(self, value):
                pass

        \(Self.rows)
        """))
        let rows = try await stack.service.settings(id)
        let completions = backend.held.value
        XCTAssertEqual(completions.count, 64)
        // 64 x 250 KiB of TL is about 21 MiB of JSON for an 8 MiB queue.
        let size = 256_000
        stack.service.activate(rows[0], pluginID: id)
        await Task.detached {
            for (index, completion) in completions.enumerated() {
                let prefix = "\(index):"
                completion(.response(dataJSON(prefix + String(repeating: "j", count: size - prefix.utf8.count))))
            }
        }.value
        let seen = try await self.seen(stack, id, rows, count: 64)
        XCTAssertEqual(seen.map { $0.array?.first }, (0..<64).map { AyuBridgeValue.integer(Int64($0)) }, "each callback once, in order")
        let answered = seen.filter { $0.array?[2] == .integer(Int64(size)) }
        let failed = seen.filter { $0.array?[1] == .integer(-1) && $0.array?[2] == .string("CALLBACK_QUEUE_FULL") }
        XCTAssertEqual(answered.count + failed.count, 64)
        XCTAssertGreaterThanOrEqual(answered.count, 24, "8 MiB of responses fit")
        XCTAssertGreaterThan(failed.count, 0)
        XCTAssertNil(stack.record(id)?.error, "The plugin was told; nothing was discarded")
        await stack.remove(id)
    }

    /// The contract's TL bounds through the real transport: 1 MiB to the host, 4 MiB from it.
    func testTLValuesCrossAtTheContractBoundsAndFailExplicitlyPastThem() async throws {
        let stack = try AyuEndToEnd.shared()
        stack.bindApplication()
        let backend = HeldRequestBackend()
        AyuPluginTelegramBridge.shared.bind(backend: backend)
        defer { AyuPluginTelegramBridge.shared.bind(backend: nil); stack.unbindApplication() }
        let id = try await stack.start(AyuEndToEnd.source(id: "e2e_tl_bounds", """
        from base_plugin import BasePlugin
        from client_utils import send_request
        from org.telegram.tgnet import TLRPC

        \(AyuEndToEnd.recorder)


        class BoundsPlugin(Recorder, BasePlugin):
            def request(self, length):
                function = TLRPC.TL_messages_getEmojiKeywords()
                function.lang_code = "x" * length
                return function

            def answer(self, name):
                def done(response, error):
                    self.set_setting(name, [None if response is None else len(response.data), None if error is None else [error.code, error.text]])
                return done

            def on_plugin_load(self):
                # A boxed function with one string: 8 bytes of header, then the padded text.
                self.record("at_bound", lambda: send_request(self.request(1048576 - 8), self.answer("largest")) > 0)
                self.record("past_bound", lambda: send_request(self.request(1048576 - 4), self.answer("never")))
                self.record("second", lambda: send_request(self.request(2), self.answer("too_large")) > 0)
        """))
        XCTAssertEqual(stack.stored(id, "at_bound"), .bool(true))
        XCTAssertEqual(stack.stored(id, "past_bound"), .string("!ValueError: TL object exceeds the size the host accepts"))
        XCTAssertEqual(backend.functions.value.map(\.count), [1_048_576, 8])
        let completions = backend.held.value
        XCTAssertEqual(completions.count, 2)
        // dataJSON: 8 bytes of header, then the padded text.
        completions[0](.response(dataJSON(String(repeating: "/", count: 4_194_304 - 8))))
        completions[1](.response(dataJSON(String(repeating: "/", count: 4_194_304 - 4))))
        let largest = await stack.waitForStored(id, "largest")
        let tooLarge = await stack.waitForStored(id, "too_large")
        XCTAssertEqual(largest, .array([.integer(4_194_296), .null]))
        XCTAssertEqual(tooLarge, .array([.null, .array([.integer(500), .string("RESPONSE_TOO_LARGE")])]))
        XCTAssertNil(stack.record(id)?.error)
        await stack.remove(id)
    }

    /// A worker thread's bridge call is served by a native wake, not by the scheduled pump. The
    /// pump is held at 1.5 s here: without the wake the first call waits for it, with the wake
    /// the calls return at once.
    func testWorkerThreadCallAfterIdleIsServedWithoutWaitingForThePump() async throws {
        let stack = try AyuEndToEnd.shared()
        let id = try await stack.start(AyuEndToEnd.source(id: "e2e_worker_wake", """
        import sys
        import threading
        import time
        from base_plugin import BasePlugin

        _ayu_threads = sys.modules["_ayu_threads"]


        class WakePlugin(BasePlugin):
            def on_plugin_load(self):
                self.saved = (_ayu_threads.PUMP_MIN_MS, _ayu_threads.PUMP_MAX_MS, _ayu_threads._wake)
                _ayu_threads.PUMP_MIN_MS = _ayu_threads.PUMP_MAX_MS = 1500
                _ayu_threads._wake = lambda current: False
                threading.Thread(target=self.work, daemon=True).start()

            def call(self):
                time.sleep(0.3)
                started = time.monotonic()
                self.set_setting("tick", started)
                return round((time.monotonic() - started) * 1000, 3)

            def work(self):
                try:
                    pumped = self.call()
                    _ayu_threads._wake = self.saved[2]
                    woken = [self.call() for _ in range(3)]
                    self.set_setting("latencies", [pumped] + woken)
                finally:
                    _ayu_threads.PUMP_MIN_MS, _ayu_threads.PUMP_MAX_MS, _ayu_threads._wake = self.saved
        """))
        let latencies = await stack.waitForStored(id, "latencies", timeout: 20).array?.compactMap(\.number) ?? []
        print("E2E-WAKE latencies ms \(latencies)")
        XCTAssertEqual(latencies.count, 4)
        XCTAssertGreaterThan(latencies.first ?? 0, 500, "without the wake the call waits for the pump")
        XCTAssertLessThan(latencies.dropFirst().max() ?? .infinity, 300, "served by the wake")
        await stack.remove(id)
    }

    /// Fixture with a busy row and a counting click row; unload stores how many clicks arrived.
    private static let clicks = """
    import time
    from base_plugin import BasePlugin
    from ui.settings import Text


    class ClickPlugin(BasePlugin):
        def on_plugin_load(self):
            self.count = 0

        def busy(self, view):
            time.sleep(0.6)

        def clicked(self, view):
            self.count += 1

        def dump(self):
            self.set_setting("count", self.count)
            return []

        def on_plugin_unload(self):
            self.set_setting("count_at_unload", self.count)

        def create_settings(self):
            return [Text(text="Busy", on_click=self.busy), Text(text="Click", on_click=self.clicked), Text(text="Dump", create_sub_fragment=self.dump)]
    """

    /// Listener-like callbacks have no producer quota: past the queue bound they are discarded,
    /// and the plugin's record says so.
    func testCallbacksBeyondTheQueueBoundAreDiscardedAndThePluginIsFlagged() async throws {
        let stack = try AyuEndToEnd.shared()
        let id = try await stack.start(AyuEndToEnd.source(id: "e2e_burst_flood", Self.clicks))
        let rows = try await stack.service.settings(id)
        stack.service.activate(rows[0], pluginID: id)
        for _ in 0..<1500 { stack.service.activate(rows[1], pluginID: id) }
        let count = try await self.dump(stack, id, rows, "count") { ($0.integer ?? 0) >= 1024 }
        let delivered = try XCTUnwrap(count.integer)
        // 1024 pending and at most 15 beside the busy callback on the interpreter queue.
        XCTAssertGreaterThanOrEqual(delivered, 1024)
        XCTAssertLessThanOrEqual(delivered, 1039)
        XCTAssertEqual(stack.record(id)?.error, AyuPluginService.deliveryOverflowMessage)
        await stack.remove(id)
    }

    /// Unload drops what is still queued for the generation, and the next load starts clean.
    func testUnloadDiscardsQueuedDeliveriesOfTheGeneration() async throws {
        let stack = try AyuEndToEnd.shared()
        let id = try await stack.start(AyuEndToEnd.source(id: "e2e_burst_unload", Self.clicks))
        let rows = try await stack.service.settings(id)
        stack.service.activate(rows[0], pluginID: id)
        for _ in 0..<500 { stack.service.activate(rows[1], pluginID: id) }
        try await stack.service.disable(id)
        let atUnload = try XCTUnwrap(stack.stored(id, "count_at_unload").integer)
        XCTAssertLessThanOrEqual(atUnload, 15, "only what was already on the interpreter queue ran")

        try await stack.service.enable(id)
        try await Task.sleep(nanoseconds: 300_000_000)
        try await stack.service.disable(id)
        XCTAssertEqual(stack.stored(id, "count_at_unload"), .integer(0), "nothing of the old generation reached the new one")
        XCTAssertNil(stack.record(id)?.error)
        await stack.remove(id)
    }

    func testTimerBurstBehindABusyCallbackFiresEveryTimerOnce() async throws {
        let stack = try AyuEndToEnd.shared()
        let id = try await stack.start(AyuEndToEnd.source(id: "e2e_burst_timers", """
        import time
        from base_plugin import BasePlugin
        from client_utils import run_on_queue
        from ui.settings import Input, Text


        class TimerPlugin(BasePlugin):
            def on_plugin_load(self):
                self.seen = []
                run_on_queue(lambda: time.sleep(0.5), delay=150)
                for index in range(100):
                    run_on_queue(lambda index=index: self.seen.append(index), delay=300)

            def changed(self, value):
                pass

        \(Self.rows)
        """))
        let rows = try await stack.service.settings(id)
        let seen = try await self.seen(stack, id, rows, count: 100)
        XCTAssertEqual(seen.count, 100, "fired timers")
        XCTAssertEqual(Set(seen.compactMap(\.integer)), Set(0..<100))
        XCTAssertNil(stack.record(id)?.error)
        await stack.remove(id)
    }

    /// Android `removeCallbacks`/cancel: a task that has not started never runs, and nothing is
    /// reported, also when it had already fired and waited on the interpreter queue.
    func testTimersCancelledBehindABusyCallbackNeverRunAndAreNotReported() async throws {
        let stack = try AyuEndToEnd.shared()
        let id = try await stack.start(AyuEndToEnd.source(id: "e2e_timer_cancel", """
        import time
        from android.os import Handler, Looper
        from android_utils import R
        from base_plugin import BasePlugin
        from client_utils import run_on_queue
        from ui.settings import Input, Text


        class CancelPlugin(BasePlugin):
            def on_plugin_load(self):
                self.seen = []
                self.handler = Handler(Looper.getMainLooper())
                self.posted = [R(lambda index=index: self.seen.append(["handler", index])) for index in range(4)]
                run_on_queue(self.cancel_all, delay=100)
                self.timers = [run_on_queue(lambda index=index: self.seen.append(["timer", index]), delay=300) for index in range(4)]
                for runnable in self.posted:
                    self.handler.postDelayed(runnable, 300)

            def cancel_all(self):
                # All eight fire while this callback runs and wait behind it on the interpreter queue.
                time.sleep(0.8)
                for timer in self.timers:
                    timer.cancel()
                for runnable in self.posted:
                    self.handler.removeCallbacks(runnable)
                self.seen.append("cancelled")
                run_on_queue(lambda: self.seen.append("after"), delay=20)

            def changed(self, value):
                pass

        \(Self.rows)
        """))
        let rows = try await stack.service.settings(id)
        let seen = try await self.seen(stack, id, rows, count: 2)
        XCTAssertEqual(seen, [.string("cancelled"), .string("after")], "no cancelled task ran, and the cancel itself raised nothing")
        XCTAssertNil(stack.record(id)?.error, "an expired delivery is not a handler failure")
        await stack.remove(id)
    }

    func testHandlerExceptionStillFlagsThePlugin() async throws {
        let stack = try AyuEndToEnd.shared()
        let id = try await stack.start(AyuEndToEnd.source(id: "e2e_timer_raise", """
        import time
        from base_plugin import BasePlugin
        from client_utils import run_on_queue
        from ui.settings import Input, Text


        class RaisePlugin(BasePlugin):
            def on_plugin_load(self):
                self.seen = []
                run_on_queue(self.fail, delay=20)

            def fail(self):
                self.seen.append("ran")
                raise ValueError("handler failure")

            def changed(self, value):
                pass

        \(Self.rows)
        """))
        let rows = try await stack.service.settings(id)
        let seen = try await self.seen(stack, id, rows, count: 1)
        XCTAssertEqual(seen, [.string("ran")])
        let deadline = Date().addingTimeInterval(5)
        while stack.record(id)?.error == nil, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(stack.record(id)?.error?.hasPrefix("Ошибка обработчика Python"), true)
        await stack.remove(id)
    }

    /// Timers that fire while the plugin unloads reach the interpreter after it: they do not
    /// run, and neither that generation nor the next one is flagged.
    func testTimersFiringDuringUnloadNeverRunAndAreNotReported() async throws {
        let stack = try AyuEndToEnd.shared()
        let id = try await stack.start(AyuEndToEnd.source(id: "e2e_timer_unload", """
        import time
        from base_plugin import BasePlugin
        from client_utils import run_on_queue


        class UnloadPlugin(BasePlugin):
            def on_plugin_load(self):
                self.ran = 0
                self.set_setting("loads", self.get_setting("loads", 0) + 1)
                if self.get_setting("loads", 0) == 1:
                    for index in range(8):
                        run_on_queue(self.fired, delay=400)

            def fired(self):
                self.ran += 1
                self.set_setting("ran", self.ran)

            def on_plugin_unload(self):
                self.set_setting("ran_at_unload", self.ran)
                time.sleep(0.9)
        """))
        try await stack.service.disable(id)
        XCTAssertEqual(stack.stored(id, "ran_at_unload"), .integer(0), "the unload began before the timers fired")
        try await stack.service.enable(id)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(stack.stored(id, "ran"), .null, "no timer of the unloaded generation ran")
        XCTAssertEqual(stack.stored(id, "loads"), .integer(2))
        XCTAssertNil(stack.record(id)?.error)
        await stack.remove(id)
    }

    /// The periodic pattern: a callback that schedules itself again holds one timer slot, so
    /// a plugin can keep all 128 busy.
    func testEveryTimerSlotCanHoldASelfReschedulingTimer() async throws {
        let stack = try AyuEndToEnd.shared()
        let id = try await stack.start(AyuEndToEnd.source(id: "e2e_timer_periodic", """
        import time
        from android_utils import run_on_ui_thread
        from base_plugin import BasePlugin
        from client_utils import run_on_queue
        from ui.settings import Input, Text


        class PeriodicPlugin(BasePlugin):
            def on_plugin_load(self):
                self.seen = [0] * 128
                self.failures = []
                for index in range(128):
                    self.again(index)

            def again(self, index):
                tick = lambda: self.tick(index)
                if index % 2:
                    run_on_ui_thread(tick, 40)
                else:
                    run_on_queue(tick, delay=40)

            def tick(self, index):
                self.seen[index] += 1
                if self.seen[index] < 6:
                    try:
                        self.again(index)
                    except Exception as error:
                        self.failures.append([index, self.seen[index], str(error)])
                        self.set_setting("failures", self.failures)

            def changed(self, value):
                pass

        \(Self.rows)
        """))
        let rows = try await stack.service.settings(id)
        let ticks = try await self.dump(stack, id, rows, "seen") { $0.array?.allSatisfy { $0.integer == 6 } == true }
        XCTAssertEqual(stack.stored(id, "failures"), .null, "no timer was refused a slot")
        XCTAssertEqual(ticks.array, Array(repeating: .integer(6), count: 128), "every timer ticked through six periods")
        XCTAssertNil(stack.record(id)?.error)
        await stack.remove(id)
    }
}
