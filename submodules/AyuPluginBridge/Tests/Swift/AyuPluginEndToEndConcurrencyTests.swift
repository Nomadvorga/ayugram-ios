import Foundation
import XCTest
@testable import AyuPluginBridge

/// Scheduler, host-to-Python callbacks and plugin threads against the real host and interpreter.
@MainActor
final class AyuPluginEndToEndConcurrencyTests: XCTestCase {
    func testSchedulerAndListenerProxiesDeliverCallbacks() async throws {
        let stack = try AyuEndToEnd.shared()
        stack.bindApplication()
        let id = try await stack.start(AyuEndToEnd.source(id: "e2e_scheduler", """
        import threading
        import time
        from android.os import Handler, Looper
        from android.widget import TextView
        from android_utils import OnClickListener, R, run_on_ui_thread
        from base_plugin import BasePlugin
        from client_utils import GLOBAL_QUEUE, NotificationCenterDelegate, get_notification_center, run_on_queue
        from java import dynamic_proxy
        from java.lang import Runnable
        from org.telegram.messenger import AndroidUtilities, ApplicationLoader, NotificationCenter

        \(AyuEndToEnd.recorder)


        class AccountObserver(NotificationCenterDelegate):
            def __init__(self, plugin):
                super().__init__()
                self.plugin = plugin

            def didReceivedNotification(self, id, account, args):
                self.plugin.set_setting("notification", [id == NotificationCenter.activeAccountChanged, account, len(args)])


        class SchedulerPlugin(Recorder, BasePlugin):
            def mark(self, name):
                def run():
                    order = self.get_setting("order", [])
                    order.append(name)
                    self.set_setting("order", order)
                    self.set_setting("at_" + name, [threading.get_ident() == self.queue_thread, round((time.monotonic() - self.started) * 1000)])
                return run

            def on_plugin_load(self):
                self.started = time.monotonic()
                self.queue_thread = threading.get_ident()
                self.set_setting("order", [])
                run_on_ui_thread(self.mark("ui"))
                run_on_queue(self.mark("queue"))
                run_on_queue(self.mark("global"), GLOBAL_QUEUE)
                run_on_ui_thread(self.mark("ui_delayed"), delay=150)
                run_on_queue(self.mark("queue_delayed"), delay=250)
                cancelled = run_on_queue(self.mark("cancelled"), delay=100)
                self.record("cancel", cancelled.cancel)
                self.record("unknown_queue", lambda: run_on_queue(self.mark("unknown"), "noSuch" + "Queue"))
                self.record("negative_delay", lambda: run_on_queue(self.mark("negative"), delay=-1))
                self.record("not_callable", lambda: run_on_queue("text"))
                self.record("sync", lambda: self.get_setting("order"))
                run_on_queue(self.views, delay=350)

            def views(self):
                view = TextView(ApplicationLoader.applicationContext)
                self.record("view_post", lambda: [view.post(R(self.mark("view_post"))), view.postDelayed(R(self.mark("view_post_delayed")), 120)])
                self.record("utilities", lambda: AndroidUtilities.runOnUIThread(R(self.mark("utilities"))))
                self.record("click_listener", lambda: view.setOnClickListener(OnClickListener(lambda v: None)))

                class Task(dynamic_proxy(Runnable)):
                    def __init__(self, run):
                        super().__init__()
                        self.run = run
                self.record("own_proxy", lambda: view.post(Task(self.mark("own_proxy"))))

                class Incomplete(dynamic_proxy(Runnable)):
                    pass
                self.record("incomplete_proxy", lambda: view.post(Incomplete()))
                run_on_queue(self.handlers, delay=250)

            def handlers(self):
                handler = Handler(Looper.getMainLooper())
                removed = R(self.mark("removed"))
                self.record("handler", lambda: [handler.post(R(self.mark("handler"))), handler.postDelayed(R(self.mark("handler_delayed")), 120),
                                                handler.postDelayed(removed, 60), handler.removeCallbacks(removed), Looper.myLooper() is Looper.getMainLooper()])
                self.observer = AccountObserver(self)
                self.record("observe", lambda: get_notification_center().addObserver(self.observer, NotificationCenter.activeAccountChanged))
        """))
        func stored(_ key: String) -> AyuBridgeValue { stack.stored(id, key) }
        _ = await stack.waitForStored(id, "at_handler_delayed", timeout: 5)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(stored("sync"), .array([]), "A callback cannot fire inside the call that schedules it")
        XCTAssertEqual(stored("order"), .array(["ui", "queue", "global", "ui_delayed", "queue_delayed", "view_post", "utilities", "own_proxy",
            "view_post_delayed", "handler", "handler_delayed"].map(AyuBridgeValue.string)))
        for (name, earliest) in [("ui_delayed", 150), ("queue_delayed", 250), ("view_post_delayed", 470), ("handler_delayed", 720)] {
            let at = stored("at_" + name).array ?? []
            XCTAssertEqual(at.first, .bool(true), "\(name) runs on the Python queue thread")
            XCTAssertGreaterThanOrEqual(at.last?.integer ?? -1, Int64(earliest), "\(name) ran early")
            XCTAssertLessThan(at.last?.integer ?? .max, Int64(earliest + 400), "\(name) ran late")
        }
        XCTAssertEqual(stored("cancel"), .null)
        XCTAssertEqual(stored("unknown_queue").string?.hasPrefix("!BridgeError: UNSUPPORTED_API"), true, "\(stored("unknown_queue"))")
        XCTAssertEqual(stored("negative_delay").string?.hasPrefix("!ValueError"), true)
        XCTAssertEqual(stored("not_callable").string?.hasPrefix("!TypeError"), true)
        XCTAssertEqual(stored("view_post"), .array([.bool(true), .bool(true)]))
        XCTAssertEqual(stored("own_proxy"), .bool(true))
        XCTAssertEqual(stored("click_listener"), .null)
        XCTAssertEqual(stored("incomplete_proxy").string?.hasPrefix("!UnsupportedAPI"), true, "\(stored("incomplete_proxy"))")
        XCTAssertEqual(stored("handler"), .array([.bool(true), .bool(true), .bool(true), .null, .bool(true)]))
        XCTAssertEqual(stored("observe"), .null)

        // The app reports another active account; the observer registered through the proxy hears it.
        stack.application.updateAccounts([AyuPluginAccountSnapshot(index: 0, identity: UUID(), userID: 77, firstName: "Other")], selected: 0)
        let notification = await stack.waitForStored(id, "notification", timeout: 5)
        XCTAssertEqual(notification, .array([.bool(true), .integer(0), .integer(0)]))
        XCTAssertNil(stack.record(id)?.error)

        try await stack.service.disable(id)
        let order = stored("order")
        stack.application.updateAccounts([AyuPluginAccountSnapshot(index: 0, identity: UUID(), userID: 78, firstName: "Third")], selected: 0)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(stored("order"), order, "Nothing is delivered to an unloaded generation")
        await stack.remove(id)
        stack.unbindApplication()
    }

    /// Callbacks that arrive while the interpreter is still inside `on_plugin_load` wait for it; none is dropped.
    func testCallbackBurstWhileTheInterpreterIsBusyIsDelivered() async throws {
        let stack = try AyuEndToEnd.shared()
        let id = try await stack.start(AyuEndToEnd.source(id: "e2e_burst", """
        from android_utils import run_on_ui_thread
        from base_plugin import BasePlugin


        class BurstPlugin(BasePlugin):
            def mark(self, number):
                return lambda: self.set_setting("ran", self.get_setting("ran", []) + [number])

            def on_plugin_load(self):
                for number in range(8):
                    run_on_ui_thread(self.mark(number))
        """))
        let ran = await stack.waitForStored(id, "ran", timeout: 5) { $0.array?.count == 8 }
        XCTAssertEqual(ran, .array((0..<8).map { .integer(Int64($0)) }))
        XCTAssertNil(stack.record(id)?.error)
        await stack.remove(id)
    }

    func testPluginThreadsReachTheBridgeAndStopOnUnload() async throws {
        let stack = try AyuEndToEnd.shared()
        let source = AyuEndToEnd.source(id: "e2e_threads", """
        import builtins
        import threading
        import time
        from concurrent.futures import ThreadPoolExecutor
        from android.net import Uri
        from android.os import Handler, HandlerThread, Looper
        from android_utils import R
        from base_plugin import BasePlugin
        from java.lang import Thread

        \(AyuEndToEnd.recorder)

        LOG = builtins.__dict__.setdefault("_ayu_e2e_thread_log", [])


        class ThreadsPlugin(Recorder, BasePlugin):
            def on_plugin_load(self):
                queue_thread = threading.get_ident()
                self.set_setting("previous_generation", list(LOG))
                del LOG[:]
                if self.get_setting("mode") == "report":
                    return

                def worker(name):
                    self.set_setting("worker_" + name, [threading.get_ident() != queue_thread, threading.current_thread().name, self.get_setting("seed", "default")])
                joined = threading.Thread(target=worker, args=("joined",), name="e2e-joined")
                joined.start()
                joined.join(10)
                self.record("joined", lambda: [joined.is_alive(), self.get_setting("worker_joined")])

                def square(number):
                    self.set_setting("pool_%d" % number, number * number)
                    return [self.get_setting("pool_%d" % number), threading.get_ident() != queue_thread]
                def pool():
                    with ThreadPoolExecutor(max_workers=3) as executor:
                        return [future.result(10) for future in [executor.submit(square, number) for number in range(6)]]
                self.record("pool", pool)

                def host_adapter():
                    return Uri.parse("https://example.org/from/worker").getLastPathSegment()
                def host_from_worker():
                    with ThreadPoolExecutor(max_workers=1) as executor:
                        return executor.submit(host_adapter).result(10)
                self.record("host_adapter_from_worker", host_from_worker)

                def failing():
                    raise ValueError("synthetic worker failure")
                def failure():
                    with ThreadPoolExecutor(max_workers=1) as executor:
                        return type(executor.submit(failing).exception(10)).__name__
                self.record("worker_exception", failure)

                java_thread = Thread(R(lambda: self.set_setting("java_thread", threading.get_ident() != queue_thread)))
                self.record("java_thread_state", lambda: [java_thread.start(), java_thread.join(10000), java_thread.isAlive()])

                looper_thread = HandlerThread("e2e-looper")
                looper_thread.start()
                handler = Handler(looper_thread.getLooper())
                self.record("looper_post", lambda: handler.post(R(lambda: self.set_setting("looper", [threading.get_ident() != queue_thread, Looper.myLooper() is looper_thread.getLooper(), Looper.myLooper() is Looper.getMainLooper()]))))
                self.record("timer", lambda: threading.Timer(0.05, lambda: self.set_setting("timer", threading.get_ident() != queue_thread)).start())

                def polite():
                    ticks = 0
                    while not self.stop_event.wait(0.02):
                        ticks += 1
                        self.set_setting("ticks", ticks)
                    LOG.append(["polite stopped", ticks > 0])
                def stubborn():
                    while True:
                        try:
                            self.set_setting("stubborn", time.monotonic())
                        except BaseException as error:
                            LOG.append(["stubborn refused", type(error).__name__, getattr(error, "code", None)])
                            return
                        time.sleep(0.02)
                threading.Thread(target=polite, name="e2e-polite", daemon=True).start()
                threading.Thread(target=stubborn, name="e2e-stubborn", daemon=True).start()
                self.record("live_threads", lambda: sorted(thread.name for thread in threading.enumerate() if thread.name.startswith("e2e-")))

            def on_plugin_unload(self):
                self.set_setting("stop_event_at_unload", self.stop_event.is_set())
        """)
        let id = try await stack.start(source)
        let ticks = await stack.waitForStored(id, "ticks", timeout: 10) { ($0.integer ?? 0) >= 5 }
        _ = await stack.waitForStored(id, "looper", timeout: 5)
        _ = await stack.waitForStored(id, "timer", timeout: 5)
        func stored(_ key: String) -> AyuBridgeValue { stack.stored(id, key) }
        XCTAssertGreaterThanOrEqual(ticks.integer ?? 0, 5, "A free-running worker is served while the queue is idle")
        XCTAssertEqual(stored("joined"), .array([.bool(false), .array([.bool(true), .string("e2e-joined"), .string("default")])]), "join on the queue thread serves the worker's bridge calls")
        XCTAssertEqual(stored("pool"), .array((0..<6).map { .array([.integer(Int64($0 * $0)), .bool(true)]) }))
        XCTAssertEqual(stored("host_adapter_from_worker"), .string("worker"))
        XCTAssertEqual(stored("worker_exception"), .string("ValueError"))
        XCTAssertEqual(stored("java_thread"), .bool(true))
        XCTAssertEqual(stored("java_thread_state"), .array([.null, .null, .bool(false)]))
        XCTAssertEqual(stored("looper_post"), .bool(true))
        XCTAssertEqual(stored("looper"), .array([.bool(true), .bool(true), .bool(false)]), "A HandlerThread runs its messages on its own looper")
        XCTAssertEqual(stored("timer"), .bool(true))
        XCTAssertEqual(stored("live_threads"), .array([.string("e2e-looper"), .string("e2e-polite"), .string("e2e-stubborn")]))
        XCTAssertNil(stack.record(id)?.error)

        try await stack.service.disable(id)
        let stubbornAtUnload = stack.stored(id, "stubborn")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(stack.stored(id, "stubborn"), stubbornAtUnload, "No bridge call of an unloaded generation reaches the host")
        XCTAssertEqual(stack.stored(id, "stop_event_at_unload"), .bool(true))

        // The next generation reports what the threads of the unloaded one ran into.
        try stack.store(id, "mode", .string("report"))
        try await stack.service.enable(id)
        let previous = stack.stored(id, "previous_generation").array ?? []
        XCTAssertTrue(previous.contains(.array([.string("polite stopped"), .bool(true)])), "\(previous)")
        XCTAssertTrue(previous.contains(.array([.string("stubborn refused"), .string("BridgeError"), .string("PLUGIN_UNLOADED")])), "\(previous)")
        await stack.remove(id)
    }
}
