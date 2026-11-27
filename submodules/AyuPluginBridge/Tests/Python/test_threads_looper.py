"""Looper/Handler and the other threading classes through the seam, with a fake host."""
from __future__ import annotations

import json
import threading
import time
import types
import unittest
from unittest.mock import patch

import test_bridge as fixtures
import test_threads_model as model
import _ayu_threads as threads
import ayu_bridge as bridge
from _ayu_javalib import concurrency as jc

TIMEOUT = model.TIMEOUT
IMPORTS = ("import threading\n"
           "from java.lang import Thread\n"
           "from java.util.concurrent import CountDownLatch, Executors, TimeUnit\n"
           "from android.os import AsyncTask, CountDownTimer, Handler, HandlerThread, Looper, Message, Process\n"
           "from org.telegram.messenger import DispatchQueue\n")


class SeamCase(model.ThreadCase):
    IMPORTS = IMPORTS

    def delays(self, queue="main"):
        return sorted(args["delay_ms"] for _, args in self.host.scheduled(queue))

    def operations(self, name):
        return [request for request in self.host.requests if request["operation"] == name]


class MainLooperTests(SeamCase):
    BODY = '''
    def on_plugin_load(self):
        self.order = []
        self.handler = Handler(Looper.getMainLooper())
        self.where = {"load": Looper.myLooper() is Looper.getMainLooper(),
                      "equal": Looper.myLooper() == Looper.getMainLooper(),
                      "current": Looper.getMainLooper().isCurrentThread(),
                      "thread": Looper.getMainLooper().getThread() is Thread.currentThread()}

    def tick(self):
        self.order.append("tick")

    def post(self):
        self.handler.post(self.tick)
        self.handler.postDelayed(self.tick, 250)
        self.handler.postDelayed(lambda: self.order.append("late"), 1500)
        self.handler.postDelayed(lambda: self.order.append("clamped"), -5)

    def cancel(self):
        self.handler.removeCallbacks(self.tick)
        return self.handler.hasCallbacks(self.tick)

    def probe(self):
        done = threading.Event()
        def work():
            self.where["worker"] = Looper.myLooper()
            self.where["worker_current"] = Looper.getMainLooper().isCurrentThread()
            Handler(Looper.getMainLooper()).post(
                lambda: self.where.__setitem__("posted", Looper.myLooper() is Looper.getMainLooper()))
            try:
                Handler()
            except RuntimeError as error:
                self.where["error"] = str(error)
            done.set()
        Thread(work).start()
        return done
'''

    def test_main_looper_is_the_queue_thread_and_only_it(self):
        scope = self.load(self.BODY)
        plugin = scope.instance
        self.assertEqual(plugin.where, {"load": True, "equal": True, "current": True, "thread": True})
        done = self.enter(scope, plugin.probe)
        self.pump(done.is_set, "the worker probe")
        self.pump(lambda: "posted" in plugin.where, "the callback posted from the worker")
        self.assertIsNone(plugin.where["worker"])
        self.assertFalse(plugin.where["worker_current"])
        self.assertTrue(plugin.where["posted"])
        self.assertIn("has not called Looper.prepare()", plugin.where["error"])
        with self.assertRaisesRegex(bridge.UnsupportedAPI, "serial plugin queue"):
            self.enter(scope, jc.Looper.loop)
        with self.assertRaisesRegex(RuntimeError, "Only one Looper"):
            self.enter(scope, jc.Looper.prepare)

    def test_post_delayed_uses_main_queue_milliseconds_and_cancellation(self):
        scope = self.load(self.BODY)
        plugin = scope.instance
        self.enter(scope, plugin.post)
        self.assertEqual(self.delays(), [0, 0, 250, 1500])
        self.assertEqual(len(scope.registrations), 4)
        # Both pending posts of the same runnable are removed, matched by equality.
        self.assertFalse(self.enter(scope, plugin.cancel))
        self.assertEqual(self.delays(), [0, 1500])
        self.assertEqual(len(self.operations("scheduler.cancel")), 2)
        self.assertEqual(len(scope.registrations), 2)
        self.host.run_due()
        self.assertEqual(plugin.order, ["clamped", "late"])
        self.assertEqual(scope.registrations, {})
        self.assertEqual(scope.callbacks, {})

    def test_messages_and_bulk_removal_on_the_main_looper(self):
        scope = self.load('''
    def on_plugin_load(self):
        self.seen = []
        plugin = self

        class Receiver(Handler):
            def handleMessage(self, message):
                plugin.seen.append((message.what, message.obj))

        self.receiver = Receiver(Looper.getMainLooper())
        self.other = Handler(Looper.getMainLooper(), lambda message: plugin.seen.append("claimed") or True)

    def send(self):
        token = object()
        self.receiver.sendEmptyMessageDelayed(1, 100)
        self.receiver.sendMessage(Message.obtain(self.receiver, 2, "payload"))
        self.receiver.postDelayed(lambda: self.seen.append("tokened"), token, 100)
        self.other.sendEmptyMessage(3)
        self.receiver.removeMessages(1)
        self.receiver.removeCallbacksAndMessages(token)
        return self.receiver.hasMessages(1), self.receiver.hasMessages(2)

    def clear(self):
        self.receiver.sendEmptyMessage(4)
        self.receiver.removeCallbacksAndMessages(None)
        try:
            self.receiver.postAtFrontOfQueue(print)
        except Exception as error:
            return type(error).__name__
''')
        plugin = scope.instance
        self.assertEqual(self.enter(scope, plugin.send), (False, True))
        self.host.run_due()
        self.assertEqual(plugin.seen, [(2, "payload"), "claimed"])
        self.assertEqual(self.enter(scope, plugin.clear), "UnsupportedMember")
        self.assertEqual(self.host.scheduled("main"), [])

    def test_local_handler_replaces_a_weaker_host_adapter(self):
        self.host.capabilities["classes"] += ["android.os.Handler", "java.lang.Runnable"]
        self.host.capabilities["proxy_interfaces"]["java.lang.Runnable"] = ["run"]
        scope = self.load('''
    def on_plugin_load(self):
        from java import dynamic_proxy, jclass
        self.ran = []
        plugin = self

        class Task(dynamic_proxy(Runnable)):
            def run(self):
                plugin.ran.append("proxy")

        self.task = Task()
        self.handler = Handler(Looper.getMainLooper())
        self.same = jclass("android.os.Handler") is Handler
        self.handler.postDelayed(self.task, 40)
        self.handler.post(self.task)
        self.handler.removeCallbacks(self.task)
        self.handler.post(self.task)

    def to_host(self):
        from java import jclass
        return jclass("example.Native")(self.handler)

    def from_host(self):
        from java import jclass
        return Handler(jclass("example.Native")())

    def host_runnable(self):
        from java import jclass
        return self.handler.post(jclass("example.Native")())
''', imports=IMPORTS + "from java.lang import Runnable\n")
        plugin = scope.instance
        self.assertIsInstance(plugin.handler, jc.Handler)
        self.assertTrue(plugin.same)
        self.assertEqual(self.operations("java.construct"), [])
        authorized = self.operations("plugin.authorize")[0]["arguments"]["classes"]
        self.assertNotIn("android.os.Handler", authorized)
        self.assertIn("java.lang.Runnable", authorized)
        self.assertEqual(self.delays(), [0])
        self.host.run_due()
        self.assertEqual(plugin.ran, ["proxy"])
        with self.assertRaisesRegex(bridge.UnsupportedAPI, "cannot be passed to the host: android.os.Handler"):
            self.enter(scope, plugin.to_host)
        with self.assertRaisesRegex(bridge.UnsupportedAPI, "host object cannot be used as a Looper"):
            self.enter(scope, plugin.from_host)
        with self.assertRaisesRegex(bridge.UnsupportedAPI, "host object cannot be used as a Runnable"):
            self.enter(scope, plugin.host_runnable)

    def test_looper_classes_stay_blocked_without_the_host_scheduler(self):
        self.host.capabilities["operations"].remove("scheduler.schedule")
        source = fixtures.source(imports="from android.os import Looper, Process\nfrom java.lang import Thread\n"
                                         "from java.util.concurrent import TimeUnit\n")
        blockers = json.loads(bridge.preflight_plugin_json(source))["blockers"]
        self.assertEqual(blockers, [{"code": "CLASS", "detail": "android.os.Looper"},
                                    {"code": "CLASS", "detail": "java.lang.Thread"}])

    def test_count_down_timer_follows_the_android_schedule(self):
        scope = self.load('''
    def on_plugin_load(self):
        self.ticks = []
        plugin = self

        class Timer(CountDownTimer):
            def onTick(self, left):
                plugin.ticks.append(left)

            def onFinish(self):
                plugin.ticks.append("finish")

        self.Timer = Timer
        self.timer = Timer(2500, 1000)
''')
        plugin = scope.instance
        clock = [100.0]
        shim = types.SimpleNamespace(monotonic=lambda: clock[0], time=time.time, sleep=time.sleep,
                                     process_time=time.process_time)
        with patch.object(jc, "time", shim):
            self.assertIs(self.enter(scope, plugin.timer.start), plugin.timer)
            for advance, expected in ((0.0, [1000]), (1.0, [1000]), (1.0, [500]), (0.5, [])):
                clock[0] += advance
                self.assertEqual(self.host.run_due(), 1)
                self.assertEqual(self.delays(), expected)
            self.assertEqual(plugin.ticks, [2500, 1500, 500, "finish"])
            self.enter(scope, plugin.timer.start)
            self.enter(scope, plugin.timer.cancel)
            self.assertEqual(self.host.scheduled("main"), [])
            self.enter(scope, plugin.Timer(0, 10).start)
        self.assertEqual(plugin.ticks[-1], "finish")
        self.assertEqual(self.host.scheduled("main"), [])


class WorkerClassTests(SeamCase):
    def test_java_thread_executor_and_latch_reach_the_bridge(self):
        scope = self.load('''
    def on_plugin_load(self):
        self.names = []
        self.latch = CountDownLatch(2)
        self.executor = Executors.newFixedThreadPool(2)

    def run(self):
        Thread(self.work, "java-worker").start()
        future = self.executor.submit(self.work)
        reached = self.latch.await_(%(timeout)d, TimeUnit.SECONDS)
        return reached, future.get(%(timeout)d, TimeUnit.SECONDS)

    def work(self):
        self.set_setting("from", Thread.currentThread().getName())
        self.names.append(Thread.currentThread().getName())
        self.latch.countDown()
        return Process.myTid()
''' % {"timeout": int(TIMEOUT)})
        plugin = scope.instance
        reached, tid = self.enter(scope, plugin.run)
        self.assertTrue(reached)
        self.assertNotEqual(tid, threading.get_native_id())
        self.assertEqual(len(plugin.names), 2)
        self.assertIn("java-worker", plugin.names)
        self.assertEqual(self.host.dispatch_threads, {self.queue})
        bridge.unload_plugin("sample")
        with self.assertRaises(jc.RejectedExecutionException):
            plugin.executor.execute(print)

    def test_default_uncaught_handler_is_per_plugin(self):
        body = '''
    def on_plugin_load(self):
        self.caught = []
        self.done = threading.Event()
        self.before = Thread.getDefaultUncaughtExceptionHandler()
        plugin = self

        class Handler_(Thread.UncaughtExceptionHandler):
            def uncaughtException(self, thread, error):
                plugin.caught.append((thread.getName(), type(error).__name__))
                plugin.done.set()

        self.installed = Handler_()
        Thread.setDefaultUncaughtExceptionHandler(self.installed)
        self.after = Thread.getDefaultUncaughtExceptionHandler()

    def fail(self):
        Thread(lambda: 1 / 0, "doomed").start()
        threading.Thread(target=lambda: [][1], name="python-doomed", daemon=True).start()
'''
        scope, other = self.load(body), self.load("    pass\n", "other")
        plugin = scope.instance
        self.assertIsNone(plugin.before)
        self.assertIs(plugin.after, plugin.installed)
        self.assertIsNone(self.enter(other, jc.Thread.getDefaultUncaughtExceptionHandler))
        self.enter(scope, plugin.fail)
        self.pump(lambda: len(plugin.caught) == 2, "both failures")
        self.assertEqual(sorted(plugin.caught), [("doomed", "ZeroDivisionError"), ("python-doomed", "IndexError")])

    def test_async_task_runs_in_a_worker_and_finishes_on_the_queue(self):
        scope = self.load('''
    def on_plugin_load(self):
        self.events = []
        plugin = self

        class Task(AsyncTask):
            def onPreExecute(self):
                plugin.events.append(("pre", Looper.myLooper() is Looper.getMainLooper()))

            def doInBackground(self, *params):
                plugin.events.append(("background", Looper.myLooper() is None, params))
                self.publishProgress(50)
                plugin.set_setting("progress", 50)
                return sum(params)

            def onProgressUpdate(self, *values):
                plugin.events.append(("progress", Looper.myLooper() is Looper.getMainLooper(), values))

            def onPostExecute(self, result):
                plugin.events.append(("post", Looper.myLooper() is Looper.getMainLooper(), result))

        self.task = Task()

    def start(self):
        self.task.execute(1, 2)
        self.status = self.task.getStatus()
        AsyncTask.execute(lambda: self.events.append(("static", Looper.myLooper() is None)))
        try:
            self.task.execute()
        except Exception as error:
            self.again = str(error)
''')
        plugin = scope.instance
        self.enter(scope, plugin.start)
        self.assertIs(plugin.status, jc.AsyncTask.Status.RUNNING)
        self.assertIn("already been executed", plugin.again)
        self.pump(lambda: len(plugin.events) == 5, "the task callbacks")
        self.assertEqual(plugin.events[0], ("pre", True))
        self.assertEqual(sorted(plugin.events[1:], key=lambda event: event[0]), [
            ("background", True, (1, 2)), ("post", True, 3), ("progress", True, (50,)), ("static", True)])
        self.assertIs(plugin.task.getStatus(), jc.AsyncTask.Status.FINISHED)
        self.assertEqual(self.enter(scope, plugin.task.get), 3)
        self.assertEqual(self.host.settings["sample"]["progress"], 50)

    def test_handler_thread_and_dispatch_queue_stop_on_unload(self):
        scope = self.load('''
    def on_plugin_load(self):
        self.seen = []
        self.ready = threading.Event()
        self.thread = HandlerThread("plugin-looper")
        self.thread.start()
        self.queue = DispatchQueue("plugin-queue")
        Handler(self.thread.getLooper()).post(self.on_looper)
        self.queue.postRunnable(self.on_queue)

    def on_looper(self):
        self.seen.append(("looper", Looper.myLooper() is self.thread.getLooper(),
                          Looper.myLooper() is Looper.getMainLooper()))
        self.set_setting("looper", True)

    def on_queue(self):
        self.seen.append(("queue", Thread.currentThread().getName()))
        self.set_setting("queue", True)
        self.ready.set()
''')
        plugin = scope.instance
        self.pump(lambda: plugin.ready.is_set() and len(plugin.seen) == 2, "the looper threads")
        self.assertEqual(sorted(plugin.seen), [("looper", True, False), ("queue", "plugin-queue")])
        self.assertEqual(self.host.settings["sample"], {"looper": True, "queue": True})
        self.assertEqual(len(threads._state(scope).threads), 2)
        bridge.unload_plugin("sample")
        plugin.thread.join(int(TIMEOUT * 1000))
        plugin.queue.join(int(TIMEOUT * 1000))
        self.assertFalse(plugin.thread.isAlive() or plugin.queue.isAlive())

    def test_named_app_queues_schedule_on_the_host(self):
        scope = self.load('''
    def on_plugin_load(self):
        self.ran = []

    def post(self, queue):
        self.ran_on = lambda: self.ran.append(Looper.myLooper() is Looper.getMainLooper())
        self.kept = queue.postRunnable(self.ran_on)
        queue.postRunnable(self.cancelled, 700)
        queue.postRunnable(self.cancelled, 900)
        queue.cancelRunnable(self.cancelled)

    def cancelled(self):
        self.ran.append("cancelled")
''')
        plugin, queue = scope.instance, jc.named_queue("globalQueue")
        self.assertIsInstance(queue, jc.DispatchQueue)
        self.assertIs(queue, jc.named_queue("globalQueue"))
        self.assertEqual((queue.getName(), queue.isAlive()), ("globalQueue", True))
        self.enter(scope, plugin.post, queue)
        self.assertTrue(plugin.kept)
        self.assertEqual(self.delays("globalQueue"), [0])
        self.host.run_due()
        self.assertEqual(plugin.ran, [True])
        self.enter(scope, queue.postRunnable, plugin.cancelled, 5)
        self.enter(scope, queue.cleanupQueue)
        self.assertEqual(self.host.scheduled("globalQueue"), [])
        for call in (queue.start, queue.recycle, lambda: jc.named_queue("madeUpQueue")):
            with self.assertRaises(bridge.UnsupportedAPI):
                call()
        self.assertEqual(set(jc.QUEUE_NAMES), {
            "stageQueue", "globalQueue", "cacheClearQueue", "searchQueue", "phoneBookQueue", "themeQueue",
            "externalNetworkQueue", "pluginsQueue"})


if __name__ == "__main__":
    unittest.main()
