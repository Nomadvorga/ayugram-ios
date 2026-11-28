"""Plugin worker-thread model, with synthetic plugins and a fake host only.

The test thread plays the native serial queue: it loads plugins, enters their
callbacks and delivers the scheduler callbacks the fake host recorded.
"""
from __future__ import annotations

import json
import sys
import threading
import time
import types
import unittest

import test_bridge as fixtures
import _ayu_threads as threads
import ayu_bridge as bridge

TIMEOUT = 10.0
_TUNABLES = ("MAX_THREADS_PER_PLUGIN", "MAX_THREADS", "MAX_PENDING_TASKS", "CALL_TIMEOUT", "LOG_TIMEOUT",
             "PUMP_MIN_MS", "PUMP_MAX_MS")


class ThreadHost(fixtures.FakeHost):
    """Fake host that records which thread dispatched and can deliver scheduled callbacks."""

    def __init__(self):
        super().__init__()
        self.dispatch_threads = set()

    def dispatch(self, text):
        self.dispatch_threads.add(threading.get_ident())
        return super().dispatch(text)

    def scheduled(self, queue=None):
        return [(token, args) for token, (_, args) in list(self.tokens.items())
                if "delay_ms" in args and queue in (None, args["queue"])]

    def fire(self, token):
        owner, args = self.tokens.pop(token)
        return bridge.invoke_callback_json(json.dumps({
            "version": 1, "plugin_id": owner, "callback_id": args["callback"]["$callback"], "arguments": []}))

    def run_due(self, queue=None):
        """Deliver every callback scheduled so far, soonest first, as the native timers would."""
        due = sorted(self.scheduled(queue), key=lambda item: item[1]["delay_ms"])
        for token, _ in due:
            if token in self.tokens:
                self.fire(token)
        return len(due)


class ThreadCase(unittest.TestCase):
    IMPORTS = "import threading\n"

    def setUp(self):
        self.host = ThreadHost()
        self.old_host = sys.modules.get("_ayu_host")
        sys.modules["_ayu_host"] = types.SimpleNamespace(dispatch=self.host.dispatch)
        bridge.runtime.scopes.clear()
        bridge.runtime.capabilities = None
        bridge.runtime.thread_id = None
        self.queue = threading.get_ident()
        self.tunables = {name: getattr(threads, name) for name in _TUNABLES}

    def tearDown(self):
        for plugin_id in list(bridge.runtime.scopes):
            try:
                bridge.unload_plugin(plugin_id)
            except Exception:
                pass
        for name, value in self.tunables.items():
            setattr(threads, name, value)
        deadline = time.monotonic() + TIMEOUT
        while threads._workers and time.monotonic() < deadline:
            time.sleep(0.001)
        leaked = dict(threads._workers)
        if self.old_host is None:
            sys.modules.pop("_ayu_host", None)
        else:
            sys.modules["_ayu_host"] = self.old_host
        self.assertEqual(leaked, {}, "a synthetic plugin thread outlived its test")

    def load(self, body, plugin_id="sample", imports=None):
        bridge.load_plugin(fixtures.source(plugin_id, body, self.IMPORTS if imports is None else imports),
                           expected_id=plugin_id)
        return bridge.runtime.scopes[plugin_id]

    def enter(self, scope, function, *args):
        """Run plugin code the way a native entry of that plugin does."""
        with bridge.runtime.context(scope):
            return function(*args)

    def pump(self, predicate, message="condition", queue=None):
        deadline = time.monotonic() + TIMEOUT
        while not predicate():
            if time.monotonic() > deadline:
                self.fail(f"Timed out waiting for {message}")
            self.host.run_due(queue)
            # Yield the interpreter lock so the plugin's threads can make progress.
            time.sleep(0.0005)

    def wait(self, event, message="event"):
        self.assertTrue(event.wait(TIMEOUT), f"Timed out waiting for {message}")


WORKER = '''
    def on_plugin_load(self):
        self.seen = {}
        self.done = threading.Event()
        self.worker = threading.Thread(target=self.work, name="synthetic-worker", daemon=True)
        self.worker.start()

    def work(self):
        from ayu_bridge import runtime
        from client_utils import run_on_ui_thread
        self.seen["scope"] = runtime.require()
        self.seen["thread"] = threading.get_ident()
        self.seen["main"] = threading.current_thread() is threading.main_thread()
        self.set_setting("answer", 41)
        self.seen["value"] = self.get_setting("answer", 0) + 1
        run_on_ui_thread(lambda: self.seen.__setitem__("ui", threading.get_ident()))
        self.done.set()
'''


class WorkerBridgeTests(ThreadCase):
    def test_thread_inherits_its_generation_and_calls_the_bridge_through_the_queue(self):
        scope = self.load(WORKER)
        plugin = scope.instance
        self.pump(plugin.done.is_set, "the worker's bridge calls")
        self.pump(lambda: "ui" in plugin.seen, "the callback posted by the worker")
        self.assertIs(plugin.seen["scope"], scope)
        self.assertNotEqual(plugin.seen["thread"], self.queue)
        self.assertFalse(plugin.seen["main"])
        self.assertEqual(plugin.seen["value"], 42)
        self.assertEqual(self.host.settings["sample"]["answer"], 41)
        # Python callbacks and every host dispatch stay on the serial queue.
        self.assertEqual(plugin.seen["ui"], self.queue)
        self.assertEqual(self.host.dispatch_threads, {self.queue})
        self.assertEqual({request["plugin_id"] for request in self.host.requests
                          if request["operation"].startswith("settings.")}, {"sample"})

    def test_queue_helpers_schedule_and_cancel_from_a_worker(self):
        scope = self.load('''
    def on_plugin_load(self):
        self.ran = []
        self.done = threading.Event()
        threading.Thread(target=self.work, daemon=True).start()

    def work(self):
        import android_utils
        from client_utils import GLOBAL_QUEUE, STAGE_QUEUE, run_on_queue
        run_on_queue(lambda: self.ran.append("global"), GLOBAL_QUEUE, 250)
        android_utils.run_on_ui_thread(lambda: self.ran.append("ui"), 100)
        run_on_queue(lambda: self.ran.append("cancelled"), STAGE_QUEUE, 50).cancel()
        self.done.set()
''')
        plugin = scope.instance
        # Only the worker pump is delivered here; the plugin's own callbacks stay scheduled.
        self.pump(lambda: plugin.done.is_set() and not self.host.scheduled("pluginsQueue"), "the worker",
                  queue="pluginsQueue")
        self.assertEqual(sorted((args["queue"], args["delay_ms"]) for _, args in self.host.scheduled()),
                         [("globalQueue", 250), ("main", 100)])
        self.host.run_due()
        self.assertEqual(plugin.ran, ["ui", "global"])
        self.assertEqual(self.host.dispatch_threads, {self.queue})
        self.assertEqual(scope.callbacks, {})

    def test_two_plugins_keep_their_threads_apart(self):
        body = '''
    def on_plugin_load(self):
        self.done = threading.Event()
        threading.Thread(target=self.work, daemon=True).start()

    def work(self):
        self.set_setting("owner", self.id)
        self.done.set()
'''
        first, second = self.load(body, "first"), self.load(body, "second")
        self.pump(lambda: first.instance.done.is_set() and second.instance.done.is_set(), "both workers")
        self.assertEqual(self.host.settings, {"first": {"owner": "first"}, "second": {"owner": "second"}})

    def test_worker_does_not_inherit_callback_context_variables(self):
        scope = self.load('''
    def on_plugin_load(self):
        self.done = threading.Event()

    def spawn(self):
        from client_utils import account_scope, get_hook_account
        with account_scope(7):
            self.inside = get_hook_account()
            threading.Thread(target=self.work, daemon=True).start()

    def work(self):
        from client_utils import get_hook_account
        self.account = get_hook_account()
        self.done.set()
''')
        self.enter(scope, scope.instance.spawn)
        self.wait(scope.instance.done, "the worker")
        self.assertEqual(scope.instance.inside, 7)
        self.assertIsNone(scope.instance.account)

    def test_bridge_errors_reach_the_worker_as_exceptions(self):
        scope = self.load('''
    def on_plugin_load(self):
        self.done = threading.Event()
        threading.Thread(target=self.work, daemon=True).start()

    def work(self):
        from ayu_bridge import runtime, BridgeError
        try:
            runtime.call("missing.operation")
        except BridgeError as error:
            self.code = error.code
        self.done.set()
''')
        self.pump(scope.instance.done.is_set, "the worker")
        self.assertEqual(scope.instance.code, "UNSUPPORTED_API")

    def test_pump_runs_only_while_threads_are_alive(self):
        scope = self.load('''
    def on_plugin_load(self):
        self.release = threading.Event()
        self.thread = threading.Thread(target=self.release.wait, args=(%r,), daemon=True)
        self.thread.start()
''' % TIMEOUT)
        self.assertEqual(len(self.host.scheduled("pluginsQueue")), 1)
        for _ in range(5):
            self.host.run_due()
            self.assertEqual(len(self.host.scheduled("pluginsQueue")), 1, "exactly one pump stays armed")
        self.assertLessEqual(len(scope.callbacks), 1)
        scope.instance.release.set()
        scope.instance.thread.join(TIMEOUT)
        self.pump(lambda: not self.host.scheduled(), "the pump to stop")
        self.assertEqual(scope.registrations, {})
        self.assertEqual(scope.callbacks, {})

    def test_pump_backs_off_while_workers_are_quiet_and_recovers_when_woken(self):
        threads.PUMP_MIN_MS, threads.PUMP_MAX_MS = 10, 2000
        scope = self.load('''
    def on_plugin_load(self):
        self.release = threading.Event()
        self.thread = threading.Thread(target=self.release.wait, args=(%r,), daemon=True)
        self.thread.start()

    def wake(self):
        self.release.set()
''' % TIMEOUT)
        state = threads._state(scope)
        self.assertEqual(self.host.scheduled()[0][1]["delay_ms"], 10)
        state.activity -= 60
        self.host.run_due()
        self.assertEqual(self.host.scheduled()[0][1]["delay_ms"], 2000)
        # Waking a waiting worker from the queue re-arms the pump at once.
        self.enter(scope, scope.instance.wake)
        self.assertEqual([args["delay_ms"] for _, args in self.host.scheduled()], [10])
        scope.instance.thread.join(TIMEOUT)

    def test_pump_dropped_by_the_host_is_rearmed_at_the_next_entry(self):
        scope = self.load('''
    def on_plugin_load(self):
        self.done = threading.Event()
        self.go = threading.Event()
        threading.Thread(target=self.work, daemon=True).start()

    def work(self):
        self.go.wait(%r)
        self.set_setting("served", True)
        self.done.set()
''' % TIMEOUT)
        state = threads._state(scope)
        (token, _), = self.host.scheduled("pluginsQueue")
        del self.host.tokens[token]  # a full native queue rejects the callback
        scope.instance.go.set()
        deadline = time.monotonic() + TIMEOUT
        while not state.requests and time.monotonic() < deadline:
            time.sleep(0.0005)
        self.assertEqual(self.host.scheduled(), [])
        state.pump_due -= 60
        # Any later entry of the plugin serves the waiting worker and restores the pump.
        self.enter(scope, lambda: None)
        self.wait(scope.instance.done, "the worker")
        self.assertEqual(self.host.settings["sample"], {"served": True})
        self.pump(lambda: not self.host.scheduled() and not state.threads, "the pump to stop")
        self.assertEqual(scope.registrations, {})

    def test_worker_call_times_out_when_the_queue_never_returns(self):
        threads.CALL_TIMEOUT = 0.05
        scope = self.load('''
    def on_plugin_load(self):
        self.done = threading.Event()
        threading.Thread(target=self.work, daemon=True).start()

    def work(self):
        from ayu_bridge import BridgeError
        try:
            self.set_setting("k", 1)
        except BridgeError as error:
            self.code = error.code
        self.done.set()
''')
        self.wait(scope.instance.done, "the worker timeout")
        self.assertEqual(scope.instance.code, "QUEUE_TIMEOUT")
        self.assertNotIn("sample", self.host.settings)
        self.assertFalse(threads._state(scope).requests)

    def test_uncaught_worker_exception_is_logged_without_details(self):
        scope = self.load('''
    def on_plugin_load(self):
        self.thread = threading.Thread(target=self.work, name="failing", daemon=True)
        self.thread.start()

    def work(self):
        raise ValueError("synthetic secret")
''')
        self.pump(lambda: not scope.instance.thread.is_alive(), "the failing thread")
        logs = [request["arguments"] for request in self.host.requests if request["operation"] == "log.write"]
        self.assertEqual(logs, [{"level": "error", "message": "Uncaught ValueError in plugin thread failing"}])
        self.assertEqual(threads._state(scope).last_failure, "ValueError")


class QueueWaitTests(ThreadCase):
    """The queue thread must keep serving a worker it is waiting for."""

    BODY = '''
    def on_plugin_load(self):
        self.lock = threading.Lock()
        self.rlock = threading.RLock()
        self.event = threading.Event()
        self.condition = threading.Condition()
        self.ready = False
        self.count = 0

    def chatty(self, count):
        for index in range(count):
            self.set_setting("n", index)
            self.count += 1

    def join(self):
        thread = threading.Thread(target=self.chatty, args=(25,))
        thread.start()
        thread.join(%(timeout)r)
        return thread.is_alive()

    def held(self, lock):
        entered = threading.Event()
        def work():
            with lock:
                entered.set()
                self.chatty(5)
        thread = threading.Thread(target=work, daemon=True)
        thread.start()
        if not entered.wait(%(timeout)r):
            return "worker never took the lock"
        acquired = lock.acquire(timeout=%(timeout)r)
        if acquired:
            lock.release()
        thread.join(%(timeout)r)
        return acquired

    def signalled(self):
        def work():
            self.chatty(5)
            self.event.set()
        threading.Thread(target=work, daemon=True).start()
        return self.event.wait(%(timeout)r)

    def notified(self):
        def work():
            self.chatty(5)
            with self.condition:
                self.ready = True
                self.condition.notify_all()
        threading.Thread(target=work, daemon=True).start()
        with self.condition:
            return self.condition.wait_for(lambda: self.ready, %(timeout)r)

    def pooled(self):
        from concurrent.futures import ThreadPoolExecutor, as_completed
        with ThreadPoolExecutor(max_workers=2, thread_name_prefix="synthetic") as executor:
            futures = [executor.submit(self.task, index) for index in range(4)]
            return sorted(future.result(%(timeout)r) for future in as_completed(futures, %(timeout)r))

    def task(self, index):
        self.set_setting("task", index)
        return index * 2

    def queued(self):
        import queue
        results = queue.Queue()
        def work():
            self.chatty(3)
            results.put("done")
        threading.Thread(target=work, daemon=True).start()
        return results.get(timeout=%(timeout)r)
''' % {"timeout": TIMEOUT}

    def test_join_does_not_deadlock_against_a_worker_calling_the_bridge(self):
        scope = self.load(self.BODY)
        started = time.monotonic()
        self.assertFalse(self.enter(scope, scope.instance.join))
        self.assertLess(time.monotonic() - started, TIMEOUT / 2)
        self.assertEqual(scope.instance.count, 25)
        self.assertEqual(self.host.settings["sample"]["n"], 24)
        self.assertEqual(self.host.dispatch_threads, {self.queue})

    def test_lock_held_by_a_worker_that_calls_the_bridge(self):
        scope = self.load(self.BODY)
        self.assertIs(self.enter(scope, scope.instance.held, scope.instance.lock), True)
        self.assertIs(self.enter(scope, scope.instance.held, scope.instance.rlock), True)
        self.assertEqual(scope.instance.count, 10)

    def test_event_condition_future_and_queue_waits_serve_the_worker(self):
        scope = self.load(self.BODY, imports="import threading\nimport concurrent.futures\n")
        plugin = scope.instance
        self.assertTrue(self.enter(scope, plugin.signalled))
        self.assertTrue(self.enter(scope, plugin.notified))
        self.assertEqual(self.enter(scope, plugin.pooled), [0, 2, 4, 6])
        self.assertEqual(self.enter(scope, plugin.queued), "done")
        self.assertEqual(self.host.dispatch_threads, {self.queue})

    def test_unload_may_join_its_worker(self):
        scope = self.load('''
    def on_plugin_load(self):
        self.calls = 0
        self.thread = threading.Thread(target=self.work)
        self.thread.start()

    def work(self):
        self.stop_event.wait(%(timeout)r)
        self.set_setting("flushed", True)
        self.calls += 1

    def on_plugin_unload(self):
        self.thread.join(%(timeout)r)
        self.joined = not self.thread.is_alive()
''' % {"timeout": TIMEOUT})
        plugin = scope.instance
        self.assertTrue(bridge.unload_plugin("sample"))
        self.assertTrue(plugin.joined)
        self.assertEqual(plugin.calls, 1)
        self.assertEqual(self.host.settings["sample"]["flushed"], True)

    def test_plain_waits_outside_plugin_code_are_untouched(self):
        lock, condition = threading.Lock(), threading.Condition()
        self.assertNotIsInstance(lock, threads._PluginLock)
        self.assertIsInstance(lock, threading.Lock)
        self.assertNotIsInstance(threading.RLock(), threads._PluginLock)
        with condition:
            self.assertFalse(condition.wait(0.001))
        thread = threading.Thread(target=lambda: None)
        thread.start()
        thread.join(TIMEOUT)
        self.assertFalse(thread.is_alive())
        self.assertNotIn(thread.ident, threads._workers)


LOOPING = '''
    def on_plugin_load(self):
        self.started = threading.Event()
        self.finished = threading.Event()
        self.errors = []
        self.thread = threading.Thread(target=self.loop, daemon=True)
        self.thread.start()

    def loop(self):
        from ayu_bridge import BridgeError
        self.started.set()
        self.stop_event.wait(%(timeout)r)
        self.stopped = self.stop_event.is_set()
        for attempt in (lambda: self.set_setting("late", 1), lambda: self.log("late"),
                        lambda: threading.Thread(target=print).start()):
            try:
                attempt()
            except BridgeError as error:
                self.errors.append(error.code)
        self.finished.set()
''' % {"timeout": TIMEOUT}


class LifecycleTests(ThreadCase):
    def test_unload_signals_threads_and_revokes_their_bridge_access(self):
        scope = self.load(LOOPING)
        plugin = scope.instance
        self.wait(plugin.started, "the worker")
        self.assertFalse(plugin.stop_event.is_set())
        bridge.unload_plugin("sample")
        self.wait(plugin.finished, "the worker to observe unload")
        self.assertTrue(plugin.stopped)
        self.assertEqual(plugin.errors, ["PLUGIN_UNLOADED"] * 3)
        self.assertNotIn("sample", self.host.settings)
        self.assertEqual(self.host.scheduled(), [])

    def test_worker_blocked_in_a_bridge_call_is_released_by_unload(self):
        scope = self.load('''
    def on_plugin_load(self):
        self.finished = threading.Event()
        threading.Thread(target=self.work, daemon=True).start()

    def work(self):
        from ayu_bridge import BridgeError
        try:
            self.set_setting("never", 1)
        except BridgeError as error:
            self.code = error.code
        self.finished.set()
''')
        plugin, state = scope.instance, threads._state(scope)
        deadline = time.monotonic() + TIMEOUT
        while not state.requests and time.monotonic() < deadline:
            time.sleep(0.001)
        self.assertEqual(len(state.requests), 1)
        # Teardown without another entry of the plugin: the pending call is never served.
        bridge.runtime._cleanup(scope)
        self.wait(plugin.finished, "the blocked worker")
        self.assertEqual(plugin.code, "PLUGIN_UNLOADED")
        self.assertNotIn("sample", self.host.settings)

    def test_reload_starts_clean_and_the_old_thread_cannot_reach_the_new_generation(self):
        first = self.load(LOOPING)
        old = first.instance
        self.wait(old.started, "the first generation's worker")
        bridge.unload_plugin("sample")
        second = self.load(WORKER)
        self.assertIsNot(second, first)
        self.assertNotEqual(second.generation, first.generation)
        self.wait(old.finished, "the old worker")
        self.assertEqual(old.errors, ["PLUGIN_UNLOADED"] * 3)
        self.pump(second.instance.done.is_set, "the new generation's worker")
        self.assertEqual(self.host.settings["sample"], {"answer": 41})
        self.assertIs(second.instance.seen["scope"], second)
        self.assertEqual(threads._state(first).threads, {})

    def test_failed_load_closes_the_threads_it_started(self):
        with self.assertRaisesRegex(RuntimeError, "synthetic load failure"):
            self.load('''
    def on_plugin_load(self):
        Plugin.started = threading.Event()
        Plugin.finished = threading.Event()
        threading.Thread(target=self.work, daemon=True).start()
        Plugin.started.wait(%r)
        raise RuntimeError("synthetic load failure")

    def work(self):
        from ayu_bridge import BridgeError
        Plugin.started.set()
        try:
            while True:
                self.get_setting("k", 0)
        except BridgeError as error:
            Plugin.code = error.code
        Plugin.finished.set()
''' % TIMEOUT)
        self.assertEqual(bridge.runtime.scopes, {})

    def test_executor_is_shut_down_on_unload(self):
        scope = self.load('''
    def on_plugin_load(self):
        from concurrent.futures import ThreadPoolExecutor
        self.gate = threading.Event()
        self.executor = ThreadPoolExecutor(max_workers=1)
        self.running = self.executor.submit(self.gate.wait, %r)
        self.queued = self.executor.submit(lambda: "never")
''' % TIMEOUT, imports="import threading\nimport concurrent.futures\n")
        plugin = scope.instance
        bridge.unload_plugin("sample")
        self.assertTrue(plugin.queued.cancelled())
        with self.assertRaisesRegex(RuntimeError, "after shutdown"):
            plugin.executor.submit(print)
        plugin.gate.set()
        self.assertTrue(plugin.running.result(TIMEOUT))


class BoundTests(ThreadCase):
    BODY = '''
    def on_plugin_load(self):
        self.gate = threading.Event()
        self.threads = []

    def spawn(self):
        thread = threading.Thread(target=self.gate.wait, args=(%r,), daemon=True)
        thread.start()
        self.threads.append(thread)

    def release(self):
        self.gate.set()
        for thread in self.threads:
            thread.join(%r)
        self.threads = []
        self.gate = threading.Event()
''' % (TIMEOUT, TIMEOUT)

    def test_live_threads_per_plugin_are_capped(self):
        threads.MAX_THREADS_PER_PLUGIN = 2
        scope, other = self.load(self.BODY), self.load(self.BODY, "other")
        plugin = scope.instance
        self.enter(scope, plugin.spawn)
        self.enter(scope, plugin.spawn)
        with self.assertRaisesRegex(bridge.BridgeError, "RESOURCE_LIMIT"):
            self.enter(scope, plugin.spawn)
        self.assertEqual(len(threads._state(scope).threads), 2)
        # The cap is per generation, and a finished thread frees its slot.
        self.enter(other, other.instance.spawn)
        self.enter(scope, plugin.release)
        self.enter(scope, plugin.spawn)
        self.enter(scope, plugin.release)
        self.enter(other, other.instance.release)

    def test_interpreter_wide_cap_counts_every_plugin(self):
        threads.MAX_THREADS = 2
        scope, other = self.load(self.BODY), self.load(self.BODY, "other")
        self.enter(scope, scope.instance.spawn)
        self.enter(other, other.instance.spawn)
        with self.assertRaisesRegex(bridge.BridgeError, "RESOURCE_LIMIT"):
            self.enter(other, other.instance.spawn)
        self.enter(scope, scope.instance.release)
        self.enter(other, other.instance.release)

    def test_executor_workers_count_and_pending_work_is_bounded(self):
        threads.MAX_THREADS_PER_PLUGIN = 2
        threads.MAX_PENDING_TASKS = 3
        scope = self.load('''
    def on_plugin_load(self):
        from concurrent.futures import ThreadPoolExecutor
        self.gate = threading.Event()
        self.executor = ThreadPoolExecutor(max_workers=2)

    def fill(self):
        return [self.executor.submit(self.gate.wait, %r) for _ in range(5)]

    def submit(self):
        return self.executor.submit(print)

    def finish(self):
        self.gate.set()
        self.executor.shutdown(wait=True)
''' % TIMEOUT, imports="import threading\nimport concurrent.futures\n")
        plugin = scope.instance
        futures = self.enter(scope, plugin.fill)
        self.assertEqual(len(threads._state(scope).threads), 2)
        with self.assertRaisesRegex(bridge.BridgeError, "pending work limit"):
            self.enter(scope, plugin.submit)
        with self.assertRaisesRegex(bridge.BridgeError, "thread limit"):
            self.enter(scope, threading.Thread(target=print).start)
        self.enter(scope, plugin.finish)
        self.assertTrue(all(future.result(TIMEOUT) for future in futures))


class ForeignThreadTests(ThreadCase):
    def run_foreign(self, function):
        result = {}

        def body():
            try:
                result["value"] = function()
            except bridge.BridgeError as error:
                result["code"] = error.code

        thread = threading.Thread(target=body)
        thread.start()
        thread.join(TIMEOUT)
        self.assertFalse(thread.is_alive())
        return result

    def test_thread_not_started_by_plugin_code_is_still_rejected(self):
        scope = self.load("    pass\n")

        def impersonate():
            bridge._current.set(scope)
            return bridge.runtime.require()

        def call():
            bridge._current.set(scope)
            return bridge.runtime.call("settings.set", {"key": "k", "value": 1, "reload_settings": False})

        self.assertEqual(self.run_foreign(impersonate), {"code": "WRONG_QUEUE"})
        self.assertEqual(self.run_foreign(call), {"code": "WRONG_QUEUE"})
        self.assertEqual(self.run_foreign(lambda: bridge.inspect_plugin_json(fixtures.source())),
                         {"code": "WRONG_QUEUE"})
        self.assertNotIn("sample", self.host.settings)

    def test_worker_cannot_use_queue_only_entry_points_or_another_generation(self):
        scope = self.load('''
    def on_plugin_load(self):
        self.codes = []
        self.done = threading.Event()

    def spawn(self, attempts):
        threading.Thread(target=self.work, args=(attempts,), daemon=True).start()

    def work(self, attempts):
        from ayu_bridge import BridgeError
        for attempt in attempts:
            try:
                attempt()
                self.codes.append(None)
            except BridgeError as error:
                self.codes.append(error.code)
        self.done.set()
''')
        other = self.load("    pass\n", "other")

        def impersonate():
            bridge._current.set(other)
            return bridge.runtime.require()

        self.enter(scope, scope.instance.spawn, [
            lambda: bridge.unload_plugin("sample"),
            lambda: bridge.runtime.context(scope).__enter__(),
            lambda: bridge.runtime._dispatch("sample", "settings.all", {}),
            impersonate])
        self.wait(scope.instance.done, "the worker")
        self.assertEqual(scope.instance.codes, ["WRONG_QUEUE"] * 4)
        self.assertIn("sample", bridge.runtime.scopes)

    def test_orphan_cannot_pin_the_queue_after_a_runtime_reset(self):
        scope = self.load('''
    def on_plugin_load(self):
        self.go = threading.Event()
        self.done = threading.Event()
        threading.Thread(target=self.work, daemon=True).start()

    def work(self):
        from ayu_bridge import runtime, BridgeError
        self.go.wait(%r)
        try:
            runtime.require()
        except BridgeError as error:
            self.code = error.code
        self.done.set()
''' % TIMEOUT)
        bridge.runtime.thread_id = None
        scope.instance.go.set()
        self.wait(scope.instance.done, "the worker")
        self.assertIsNone(bridge.runtime.thread_id)
        bridge.runtime.check_queue()
        self.assertEqual(bridge.runtime.thread_id, self.queue)


class PreflightTests(ThreadCase):
    def blockers(self, imports):
        return json.loads(bridge.preflight_plugin_json(fixtures.source(imports=imports)))["blockers"]

    def test_thread_imports_pass_only_with_the_host_scheduler(self):
        imports = "import threading\nfrom concurrent.futures import ThreadPoolExecutor\nimport queue\n"
        self.assertEqual(self.blockers(imports), [])
        self.host.capabilities["operations"].remove("scheduler.cancel")
        self.assertEqual(self.blockers(imports), [{"code": "IMPORT", "detail": "concurrent.futures"},
                                                  {"code": "IMPORT", "detail": "threading"}])
        with self.assertRaisesRegex(bridge.BridgeError, "LOAD_REJECTED"):
            bridge.load_plugin(fixtures.source(imports=imports))
        self.assertEqual(bridge.runtime.scopes, {})

    def test_process_and_native_symbol_imports_stay_unsupported(self):
        for name in ("multiprocessing", "subprocess", "ctypes", "_thread"):
            with self.subTest(name=name):
                self.assertEqual(self.blockers(f"import {name}\n"), [{"code": "IMPORT", "detail": name}])
                with self.assertRaisesRegex(bridge.BridgeError, "LOAD_REJECTED"):
                    bridge.load_plugin(fixtures.source(imports=f"import {name}\n"))


if __name__ == "__main__":
    unittest.main()
