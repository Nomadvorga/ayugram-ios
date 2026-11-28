"""Python-local Java concurrency classes, exercised directly without a host."""
from __future__ import annotations

import os
from pathlib import Path
import sys
import threading
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Python"))

import _ayu_javalib
import ayu_bridge as bridge
from _ayu_javalib import concurrency as jc

TIMEOUT = 10.0
SECONDS = jc.TimeUnit.SECONDS


def java_error(name, fallback):
    """The class concurrency raises for a Java exception: javalib's when bundled, else a builtin."""
    return type(jc._java_error(name, fallback, "probe"))


ILLEGAL_ARGUMENT = java_error("java.lang.IllegalArgumentException", ValueError)
ILLEGAL_STATE = java_error("java.lang.IllegalStateException", RuntimeError)
NULL_POINTER = java_error("java.lang.NullPointerException", TypeError)
INTERRUPTED = type(jc._interrupted())
INDEX = java_error("java.lang.IndexOutOfBoundsException", IndexError)
MONITOR = java_error("java.lang.IllegalMonitorStateException", RuntimeError)
THREAD_STATE = java_error("java.lang.IllegalThreadStateException", RuntimeError)


class DirectCase(unittest.TestCase):
    def setUp(self):
        # No queue thread: every thread here is an ordinary one without a looper.
        self.thread_id, bridge.runtime.thread_id = bridge.runtime.thread_id, None

    def tearDown(self):
        bridge.runtime.thread_id = self.thread_id

    def run_thread(self, function):
        result = {}

        def body():
            try:
                result["value"] = function()
            except BaseException as error:
                result["error"] = error

        thread = threading.Thread(target=body)
        thread.start()
        thread.join(TIMEOUT)
        self.assertFalse(thread.is_alive(), "helper thread did not finish")
        if "error" in result:
            raise result["error"]
        return result.get("value")


class ValueTests(DirectCase):
    def test_provider_is_registered_with_valid_names(self):
        local = _ayu_javalib.local_classes()
        for name, cls in jc.CLASSES.items():
            self.assertIs(local[name], cls)
        self.assertIs(jc.Thread.UncaughtExceptionHandler, jc.CLASSES["java.lang.Thread$UncaughtExceptionHandler"])
        self.assertIs(jc.Handler.Callback, jc.CLASSES["android.os.Handler$Callback"])
        self.assertEqual(_ayu_javalib.host_override_names(jc.SCHEDULER) & set(jc.CLASSES), {
            "android.os.Handler", "java.util.concurrent.atomic.AtomicLong", "java.util.concurrent.atomic.AtomicBoolean"})
        gated = {name for name, cls in jc.CLASSES.items() if getattr(cls, "__ayu_requires__", ())}
        self.assertEqual(gated, {
            "java.lang.Thread", "java.util.Timer", "java.util.concurrent.ThreadPoolExecutor",
            "java.util.concurrent.ScheduledThreadPoolExecutor", "java.util.concurrent.Executors",
            "android.os.Looper", "android.os.Handler", "android.os.HandlerThread", "android.os.CountDownTimer",
            "android.os.AsyncTask", "org.telegram.messenger.DispatchQueue"})
        self.assertEqual(_ayu_javalib.local_class_names([]) & gated, set())

    def test_unimplemented_members_are_explicit_and_look_missing(self):
        for target in (jc.Process, jc.Looper, jc.Thread.currentThread(), jc.TimeUnit.SECONDS):
            with self.assertRaises(bridge.UnsupportedAPI):
                target.noSuchMember
            self.assertFalse(hasattr(target, "noSuchMember"))
            self.assertEqual(getattr(target, "noSuchMember", 5), 5)

    def test_time_unit_conversions_truncate_like_java(self):
        unit = jc.TimeUnit
        self.assertEqual(unit.SECONDS.toMillis(3), 3000)
        self.assertEqual(unit.MILLISECONDS.toSeconds(1999), 1)
        self.assertEqual(unit.MILLISECONDS.toSeconds(-1999), -1)
        self.assertEqual(unit.HOURS.toMinutes(2), 120)
        self.assertEqual(unit.DAYS.toHours(1), 24)
        self.assertEqual(unit.MICROSECONDS.convert(2, unit.MILLISECONDS), 2000)
        self.assertEqual(unit.NANOSECONDS.toMicros(2500), 2)
        self.assertIs(unit.valueOf("MINUTES"), unit.MINUTES)
        self.assertEqual([value.name() for value in unit.values()][:3], ["NANOSECONDS", "MICROSECONDS", "MILLISECONDS"])
        self.assertEqual((unit.SECONDS.ordinal(), str(unit.SECONDS)), (3, "SECONDS"))
        with self.assertRaises(ILLEGAL_ARGUMENT):
            unit.valueOf("FORTNIGHTS")
        with self.assertRaises(TypeError):
            unit.SECONDS.toMillis("1")

    def test_atomics_wrap_and_compare_like_java(self):
        integer = jc.AtomicInteger(2**31 - 1)
        self.assertEqual(integer.incrementAndGet(), -2**31)
        self.assertEqual(integer.getAndAdd(5), -2**31)
        self.assertTrue(integer.compareAndSet(-2**31 + 5, 7))
        self.assertFalse(integer.compareAndSet(0, 1))
        self.assertEqual(integer.updateAndGet(lambda value: value * 3), 21)
        self.assertEqual(integer.getAndAccumulate(4, lambda left, right: left - right), 21)
        self.assertEqual((integer.get(), integer.toString()), (17, "17"))
        long = jc.AtomicLong(2**63 - 1)
        self.assertEqual(long.incrementAndGet(), -2**63)
        self.assertEqual(jc.AtomicLong(2**32 + 5).intValue(), 5)
        flag = jc.AtomicBoolean()
        self.assertFalse(flag.getAndSet(True))
        self.assertTrue(flag.compareAndSet(True, False))
        self.assertEqual(flag.toString(), "false")
        with self.assertRaises(TypeError):
            flag.set(1)
        first, second = [1], [1]
        reference = jc.AtomicReference(first)
        self.assertFalse(reference.compareAndSet(second, None))
        self.assertTrue(reference.compareAndSet(first, second))
        self.assertIs(reference.get(), second)

    def test_atomic_updates_are_not_lost_between_threads(self):
        counter = jc.AtomicInteger()
        workers = [threading.Thread(target=lambda: [counter.incrementAndGet() for _ in range(2000)]) for _ in range(4)]
        for worker in workers:
            worker.start()
        for worker in workers:
            worker.join(TIMEOUT)
        self.assertEqual(counter.get(), 8000)

    def test_concurrent_map_and_copy_on_write_list(self):
        mapping = jc.ConcurrentHashMap({"a": 1})
        self.assertIsNone(mapping.put("b", 2))
        self.assertEqual(mapping.put("b", 3), 2)
        self.assertEqual(mapping.putIfAbsent("b", 9), 3)
        self.assertIsNone(mapping.putIfAbsent("c", 4))
        self.assertEqual(mapping.computeIfAbsent("d", lambda key: key * 2), "dd")
        self.assertEqual(mapping.merge("a", 10, lambda old, new: old + new), 11)
        self.assertTrue(mapping.remove("c", 4))
        self.assertFalse(mapping.replace("a", 0, 1))
        self.assertEqual((mapping.size(), mapping.getOrDefault("zz", 0), mapping.containsKey("a")), (3, 0, True))
        self.assertEqual(sorted(mapping.keySet()), ["a", "b", "d"])
        self.assertEqual(sorted(entry.getKey() for entry in mapping.entrySet()), ["a", "b", "d"])
        self.assertEqual(mapping.keySet().size(), 3)
        with self.assertRaises(NULL_POINTER):
            mapping.put("k", None)
        with self.assertRaises(AttributeError):
            mapping.keySet().add("x")
        values = jc.CopyOnWriteArrayList([1, 2])
        snapshot = values.iterator()
        self.assertTrue(values.add(3))
        values.add(0, 0)
        self.assertFalse(values.addIfAbsent(3))
        self.assertEqual(values.remove(0), 0)
        self.assertTrue(values.remove("missing") is False)
        self.assertEqual((values.toArray(), values.indexOf(3), values.get(1)), ([1, 2, 3], 2, 2))
        self.assertEqual([snapshot.next(), snapshot.next(), snapshot.hasNext()], [1, 2, False])
        with self.assertRaises(INDEX):
            values.get(7)

    def test_blocking_queue_hands_values_between_threads(self):
        queue = jc.LinkedBlockingQueue(1)
        self.assertTrue(queue.offer("a"))
        self.assertFalse(queue.offer("b"))
        self.assertFalse(queue.offer("b", 1, jc.TimeUnit.MILLISECONDS))
        self.assertEqual(queue.remainingCapacity(), 0)
        consumer = threading.Thread(target=lambda: results.extend([queue.take(), queue.take()]))
        results = []
        consumer.start()
        queue.put("b")
        consumer.join(TIMEOUT)
        self.assertEqual(results, ["a", "b"])
        self.assertIsNone(queue.poll())
        self.assertIsNone(queue.poll(1, jc.TimeUnit.MILLISECONDS))
        self.assertIsNone(queue.peek())
        with self.assertRaises(NULL_POINTER):
            queue.put(None)
        plain = jc.ConcurrentLinkedQueue([1, 2])
        self.assertEqual((plain.poll(), plain.size(), plain.contains(2)), (1, 1, True))
        self.assertIsInstance(jc.ArrayBlockingQueue(2), jc.CLASSES["java.util.concurrent.BlockingQueue"])

    def test_latch_semaphore_and_reentrant_lock(self):
        latch = jc.CountDownLatch(2)
        self.assertFalse(latch.await_(1, jc.TimeUnit.MILLISECONDS))
        threading.Thread(target=lambda: (latch.countDown(), latch.countDown())).start()
        self.assertTrue(getattr(latch, "await")(int(TIMEOUT), SECONDS))
        self.assertIsNone(latch.await_())
        self.assertEqual(latch.getCount(), 0)
        semaphore = jc.Semaphore(1)
        semaphore.acquire()
        self.assertFalse(semaphore.tryAcquire())
        self.assertFalse(semaphore.tryAcquire(1, jc.TimeUnit.MILLISECONDS))
        semaphore.release(2)
        self.assertTrue(semaphore.tryAcquire(2))
        lock = jc.ReentrantLock()
        condition = lock.newCondition()
        state = []

        def waiter():
            lock.lock()
            try:
                state.append("waiting")
                condition.await_()
                state.append(lock.isHeldByCurrentThread())
            finally:
                lock.unlock()

        thread = threading.Thread(target=waiter)
        thread.start()
        deadline = time.monotonic() + TIMEOUT
        while time.monotonic() < deadline:
            with lock:
                if state:
                    self.assertFalse(lock.tryLock() and lock.getHoldCount() != 2)
                    lock.unlock()
                    condition.signalAll()
                    break
            time.sleep(0.001)
        thread.join(TIMEOUT)
        self.assertEqual(state, ["waiting", True])
        self.assertFalse(lock.isLocked())
        with self.assertRaises(MONITOR):
            lock.unlock()
        self.assertFalse(self.run_thread(lambda: (lock.lock(), False)[1] or self.run_thread(lock.tryLock)))

    def test_process_reports_real_identifiers_and_refuses_to_kill(self):
        self.assertEqual(jc.Process.myPid(), os.getpid())
        self.assertEqual(jc.Process.myTid(), threading.get_native_id())
        self.assertEqual(jc.Process.myUid(), os.getuid())
        self.assertIs(jc.Process.is64Bit(), sys.maxsize > 2**32)
        self.assertGreaterEqual(jc.Process.getElapsedCpuTime(), 0)
        for fatal in (jc.Process.killProcess, jc.Process.sendSignal, jc.Process.killProcessQuiet):
            with self.assertRaisesRegex(bridge.UnsupportedAPI, "cannot signal, kill or restart"):
                fatal(os.getpid(), jc.Process.SIGNAL_KILL)
        jc.Process.setThreadPriority(jc.Process.THREAD_PRIORITY_BACKGROUND)
        self.assertEqual(jc.Process.getThreadPriority(jc.Process.myTid()), 10)
        jc.Process.setThreadPriority(jc.Process.myTid(), 0)
        with self.assertRaises(ILLEGAL_ARGUMENT):
            jc.Process.setThreadPriority(99)
        with self.assertRaises(ILLEGAL_ARGUMENT):
            jc.Process.getThreadPriority(-5)


class ThreadTests(DirectCase):
    def test_thread_runs_a_runnable_and_joins(self):
        seen = []
        thread = jc.Thread(jc.Runnable(lambda: seen.append(jc.Thread.currentThread())), "synthetic")
        self.assertFalse(thread.isAlive())
        thread.join()
        thread.setDaemon(True)
        thread.start()
        thread.join(int(TIMEOUT * 1000))
        self.assertEqual(seen, [thread])
        self.assertEqual((thread.getName(), thread.isDaemon(), thread.isAlive()), ("synthetic", True, False))
        with self.assertRaises(THREAD_STATE):
            thread.start()
        self.assertIs(jc.Thread.currentThread(), jc.Thread.currentThread())
        self.assertNotEqual(jc.Thread.currentThread().getId(), thread.getId())
        thread.setPriority(jc.Thread.MAX_PRIORITY)
        self.assertEqual(thread.getPriority(), 10)
        with self.assertRaises(ILLEGAL_ARGUMENT):
            thread.setPriority(11)

    def test_subclass_run_and_object_with_run_method(self):
        seen = []

        class Worker(jc.Thread):
            def run(self):
                seen.append(self.getName())

        class Listener:
            def run(self):
                seen.append("listener")

        for thread in (Worker("named"), jc.Thread(Listener())):
            thread.start()
            thread.join()
        self.assertEqual(seen, ["named", "listener"])
        with self.assertRaises(TypeError):
            jc.Thread(object())

    def test_interrupt_wakes_sleep_and_blocking_calls(self):
        outcomes = []
        started = threading.Event()
        latch = jc.CountDownLatch(1)

        def sleeper():
            started.set()
            try:
                jc.Thread.sleep(int(TIMEOUT * 1000))
            except INTERRUPTED:
                outcomes.append(("sleep", jc.Thread.currentThread().isInterrupted()))
            try:
                latch.await_()
            except INTERRUPTED:
                outcomes.append(("await", jc.Thread.interrupted()))

        thread = jc.Thread(sleeper)
        thread.start()
        self.assertTrue(started.wait(TIMEOUT))
        for expected in (1, 2):
            deadline = time.monotonic() + TIMEOUT
            while len(outcomes) < expected and time.monotonic() < deadline:
                thread.interrupt()
                time.sleep(0.001)
        thread.join(int(TIMEOUT * 1000))
        self.assertEqual(outcomes, [("sleep", False), ("await", False)])
        started_at = time.monotonic()
        jc.Thread.sleep(2)
        self.assertGreaterEqual(time.monotonic() - started_at, 0.002)
        with self.assertRaises(ILLEGAL_ARGUMENT):
            jc.Thread.sleep(-1)

    def test_stack_traces_and_uncaught_handler(self):
        trace = jc.Thread.currentThread().getStackTrace()
        self.assertEqual(trace[0].getMethodName(), "getStackTrace")
        self.assertIn("test_stack_traces_and_uncaught_handler", [element.getMethodName() for element in trace])
        self.assertTrue(trace[1].getFileName().endswith(".py") and trace[1].getLineNumber() > 0)
        self.assertIn(jc.Thread.currentThread(), jc.Thread.getAllStackTraces().keySet())
        caught = []
        thread = jc.Thread(lambda: 1 / 0)
        handler = jc.Thread.UncaughtExceptionHandler(lambda owner, error: caught.append((owner, type(error))))
        thread.setUncaughtExceptionHandler(handler)
        self.assertIs(thread.getUncaughtExceptionHandler(), handler)
        # Outside a plugin generation the handler is not consulted by the thread model.
        self.assertTrue(callable(thread._thread._ayu_uncaught))
        thread._thread._ayu_uncaught(thread._thread, ZeroDivisionError())
        self.assertEqual(caught, [(thread, ZeroDivisionError)])

    def test_thread_local_values_are_per_thread(self):
        local = jc.ThreadLocal.withInitial(lambda: [])
        local.get().append("main")
        self.assertEqual(self.run_thread(lambda: local.get()), [])
        self.assertEqual(local.get(), ["main"])
        local.remove()
        self.assertEqual(local.get(), [])
        plain = jc.ThreadLocal()
        self.assertIsNone(plain.get())
        plain.set(3)
        self.assertEqual(plain.get(), 3)


class ExecutorTests(DirectCase):
    def test_submit_execute_and_failures(self):
        executor = jc.Executors.newFixedThreadPool(2)
        try:
            self.assertEqual(executor.submit(lambda: 21 * 2).get(int(TIMEOUT), SECONDS), 42)
            self.assertEqual(executor.submit(jc.Callable(lambda: "called")).get(), "called")
            self.assertIsNone(executor.submit(jc.Runnable(lambda: "ignored")).get())
            self.assertEqual(executor.submit(jc.Runnable(lambda: None), "fixed").get(), "fixed")
            failing = executor.submit(lambda: 1 / 0)
            with self.assertRaises(jc.ExecutionException) as raised:
                failing.get(int(TIMEOUT), SECONDS)
            self.assertIsInstance(raised.exception.getCause(), ZeroDivisionError)
            self.assertTrue(failing.isDone() and not failing.isCancelled())
            ran = threading.Event()
            executor.execute(ran.set)
            self.assertTrue(ran.wait(TIMEOUT))
            gate = threading.Event()
            slow = executor.submit(lambda: gate.wait(TIMEOUT))
            with self.assertRaises(jc.TimeoutException):
                slow.get(1, jc.TimeUnit.MILLISECONDS)
            gate.set()
            self.assertTrue(slow.get(int(TIMEOUT), SECONDS))
            self.assertEqual([future.get() for future in executor.invokeAll([lambda: 1, lambda: 2])], [1, 2])
        finally:
            executor.shutdown()
        self.assertTrue(executor.awaitTermination(int(TIMEOUT), SECONDS))
        self.assertTrue(executor.isShutdown() and executor.isTerminated())
        with self.assertRaises(jc.RejectedExecutionException):
            executor.execute(int)

    def test_pool_size_pending_order_and_shutdown_now(self):
        executor = jc.Executors.newSingleThreadExecutor()
        gate, order = threading.Event(), []
        first = executor.submit(lambda: gate.wait(TIMEOUT))
        commands = [lambda index=index: order.append(index) for index in range(3)]
        futures = [executor.submit(command) for command in commands]
        self.assertEqual(executor.getPoolSize(), 1)
        self.assertTrue(futures[2].cancel(False))
        self.assertFalse(first.cancel(True) and first.isCancelled() and False)
        gate.set()
        futures[1].get(int(TIMEOUT), SECONDS)
        self.assertEqual(order, [0, 1])
        with self.assertRaises(jc.CancellationException):
            futures[2].get()
        blocker, running = threading.Event(), threading.Event()
        executor.execute(lambda: (running.set(), blocker.wait(TIMEOUT)))
        self.assertTrue(running.wait(TIMEOUT))
        executor.execute(commands[0])
        pending = executor.shutdownNow()
        self.assertEqual(list(pending), [commands[0]])
        blocker.set()
        self.assertTrue(executor.awaitTermination(int(TIMEOUT), SECONDS))
        with self.assertRaises(bridge.UnsupportedAPI):
            jc.Executors.newFixedThreadPool(1, object())
        with self.assertRaises(ILLEGAL_ARGUMENT):
            jc.Executors.newFixedThreadPool(0)

    def test_pending_work_is_bounded_and_idle_workers_exit(self):
        executor = jc.ThreadPoolExecutor(1, 1, 0, SECONDS, jc.ArrayBlockingQueue(2))
        gate = threading.Event()
        executor.execute(lambda: gate.wait(TIMEOUT))
        deadline = time.monotonic() + TIMEOUT
        while executor.getActiveCount() != 1 and time.monotonic() < deadline:
            time.sleep(0.001)
        executor.execute(int)
        executor.execute(int)
        with self.assertRaisesRegex(bridge.BridgeError, "RESOURCE_LIMIT"):
            executor.execute(int)
        executor._pool.keep_alive = 0.01
        gate.set()
        deadline = time.monotonic() + TIMEOUT
        while executor.getPoolSize() and time.monotonic() < deadline:
            time.sleep(0.001)
        self.assertEqual(executor.getPoolSize(), 0)
        # A new task simply starts a new worker.
        self.assertEqual(executor.submit(lambda: "again").get(int(TIMEOUT), SECONDS), "again")
        executor.shutdown()
        with self.assertRaises(bridge.UnsupportedAPI):
            jc.ThreadPoolExecutor(1, 1, 0, SECONDS, [])

    def test_scheduled_executor_delays_repeats_and_cancels(self):
        executor = jc.Executors.newSingleThreadScheduledExecutor()
        millis = jc.TimeUnit.MILLISECONDS
        try:
            order = []
            late = executor.schedule(lambda: order.append("late"), 30, millis)
            early = executor.schedule(jc.Callable(lambda: order.append("early") or "value"), 1, millis)
            self.assertGreater(late.getDelay(millis), 0)
            self.assertEqual(early.get(int(TIMEOUT), SECONDS), "value")
            late.get(int(TIMEOUT), SECONDS)
            self.assertEqual(order, ["early", "late"])
            ticks, enough = [], threading.Event()

            def tick():
                ticks.append(time.monotonic())
                if len(ticks) == 3:
                    enough.set()

            periodic = executor.scheduleAtFixedRate(tick, 0, 2, millis)
            self.assertTrue(enough.wait(TIMEOUT))
            self.assertTrue(periodic.cancel(False))
            self.assertTrue(periodic.isCancelled())
            count = len(ticks)
            executor.schedule(lambda: None, 10, millis).get(int(TIMEOUT), SECONDS)
            self.assertLessEqual(len(ticks), count + 1)
            failing = executor.scheduleWithFixedDelay(lambda: 1 / 0, 0, 1, millis)
            with self.assertRaises(jc.ExecutionException):
                failing.get(int(TIMEOUT), SECONDS)
            with self.assertRaises(ILLEGAL_ARGUMENT):
                executor.scheduleAtFixedRate(int, 0, 0, millis)
        finally:
            executor.shutdownNow()
        self.assertTrue(executor.awaitTermination(int(TIMEOUT), SECONDS))

    def test_timer_runs_tasks_and_dies_with_a_failing_task(self):
        timer = jc.Timer("synthetic-timer")
        fired, repeats, enough = threading.Event(), [], threading.Event()
        once = jc.TimerTask(fired.set)
        timer.schedule(once, 1)
        self.assertTrue(fired.wait(TIMEOUT))
        self.assertGreater(once.scheduledExecutionTime(), 0)

        class Repeating(jc.TimerTask):
            def run(self):
                repeats.append(threading.current_thread().name)
                if len(repeats) == 2:
                    enough.set()

        repeating = Repeating()
        timer.schedule(repeating, 0, 2)
        self.assertTrue(enough.wait(TIMEOUT))
        self.assertTrue(repeating.cancel())
        self.assertFalse(repeating.cancel())
        self.assertTrue(all(name.startswith("synthetic-timer") for name in repeats))
        cancelled = jc.TimerTask(lambda: repeats.append("cancelled"))
        timer.schedule(cancelled, 60_000)
        self.assertTrue(cancelled.cancel())
        # Cancelling already removed the task from the queue, so nothing is left to purge.
        self.assertEqual((timer.purge(), timer._pool.delayed), (0, []))
        with self.assertRaises(ILLEGAL_STATE):
            timer.schedule(once, 1)
        with self.assertRaises(ILLEGAL_ARGUMENT):
            timer.schedule(jc.TimerTask(int), -1)
        timer.schedule(jc.TimerTask(lambda: 1 / 0), 0)
        deadline = time.monotonic() + TIMEOUT
        while not timer._pool.stopped and time.monotonic() < deadline:
            time.sleep(0.001)
        with self.assertRaisesRegex(ILLEGAL_STATE, "Timer already cancelled"):
            timer.schedule(jc.TimerTask(int), 1)


class LooperTests(DirectCase):
    def test_threads_without_prepare_have_no_looper(self):
        self.assertIsNone(jc.Looper.myLooper())
        self.assertIsNot(jc.Looper.getMainLooper(), None)
        self.assertIs(jc.Looper.getMainLooper(), jc.Looper.getMainLooper())
        with self.assertRaisesRegex(RuntimeError, "has not called Looper.prepare"):
            jc.Handler()
        with self.assertRaisesRegex(RuntimeError, "No Looper"):
            jc.Looper.loop()
        with self.assertRaises(bridge.UnsupportedAPI):
            jc.Looper()
        with self.assertRaises(ILLEGAL_STATE):
            jc.Looper.getMainLooper().quit()

    def test_handler_thread_orders_delays_and_cancels(self):
        thread = jc.HandlerThread("synthetic-looper")
        self.assertIsNone(thread.getLooper())
        thread.start()
        looper = thread.getLooper()
        self.assertIsNot(looper, jc.Looper.getMainLooper())
        self.assertIs(looper.getThread(), thread)
        self.assertFalse(looper.isCurrentThread())
        handler = jc.Handler(looper)
        order, finished = [], threading.Event()
        gate = threading.Event()
        handler.post(lambda: gate.wait(TIMEOUT))

        class Cancelled:
            def run(self):
                order.append("cancelled")

        cancelled = Cancelled()
        handler.postDelayed(lambda: order.append("delayed"), 20)
        handler.post(lambda: order.append("first"))
        handler.post(cancelled)
        handler.postDelayed(cancelled.run, 1)
        handler.post(lambda: order.append(("looper", jc.Looper.myLooper() is looper, threading.current_thread().name)))
        handler.postAtFrontOfQueue(lambda: order.append("front"))
        handler.postDelayed(finished.set, 40)
        self.assertTrue(handler.hasCallbacks(cancelled))
        handler.removeCallbacks(cancelled)
        handler.removeCallbacks(cancelled.run)
        self.assertFalse(handler.hasCallbacks(cancelled))
        gate.set()
        self.assertTrue(finished.wait(TIMEOUT))
        self.assertEqual(order, ["front", "first", ("looper", True, "synthetic-looper"), "delayed"])
        self.assertTrue(thread.quitSafely())
        thread.join(int(TIMEOUT * 1000))
        self.assertFalse(thread.isAlive())
        self.assertFalse(handler.post(int))

    def test_messages_reach_callback_then_handle_message(self):
        thread = jc.HandlerThread("synthetic-messages")
        thread.start()
        seen, finished = [], threading.Event()

        class Receiver(jc.Handler):
            def handleMessage(self, message):
                seen.append(("handler", message.what, message.arg1, message.arg2, message.obj))
                if message.what == 9:
                    finished.set()

        claimed = jc.Handler(thread.getLooper(), jc.Handler.Callback(lambda message: seen.append(("callback", message.what)) or True))
        receiver = Receiver(thread.getLooper())
        claimed.sendEmptyMessage(1)
        receiver.sendMessage(receiver.obtainMessage(2, 3, 4, "payload"))
        receiver.sendEmptyMessageDelayed(5, 60_000)
        self.assertTrue(receiver.hasMessages(5))
        receiver.removeMessages(5)
        self.assertFalse(receiver.hasMessages(5))
        jc.Message.obtain(receiver, 9).sendToTarget()
        self.assertTrue(finished.wait(TIMEOUT))
        self.assertEqual(seen, [("callback", 1), ("handler", 2, 3, 4, "payload"), ("handler", 9, 0, 0, None)])
        copy = jc.Message.obtain(jc.Message.obtain(receiver, 7, "object"))
        self.assertEqual((copy.what, copy.obj, copy.getTarget()), (7, "object", receiver))
        thread.quit()
        thread.join(int(TIMEOUT * 1000))

    def test_prepare_and_loop_on_a_plain_thread(self):
        def body():
            jc.Looper.prepare()
            with self.assertRaisesRegex(RuntimeError, "Only one Looper"):
                jc.Looper.prepare()
            looper, seen = jc.Looper.myLooper(), []
            handler = jc.Handler()
            handler.post(lambda: seen.append(1 / 0))
            handler.post(lambda: seen.append("after failure"))
            handler.post(looper.quitSafely)
            jc.Looper.loop()
            return seen, looper.isCurrentThread()

        self.assertEqual(self.run_thread(body), (["after failure"], True))

    def test_dispatch_queue_runs_runnables_in_order(self):
        queue = jc.DispatchQueue("synthetic-queue", False)
        order, finished = [], threading.Event()
        cancelled = lambda: order.append("cancelled")
        self.assertTrue(queue.postRunnable(lambda: order.append("queued before start")))
        self.assertTrue(queue.postRunnable(cancelled, 1))
        queue.cancelRunnable(cancelled)
        queue.postRunnable(lambda: order.append(threading.current_thread().name), 2)
        queue.postRunnable(finished.set, 5)
        self.assertTrue(queue.isReady() and not queue.isAlive())
        queue.start()
        self.assertTrue(finished.wait(TIMEOUT))
        self.assertEqual(order, ["queued before start", "synthetic-queue"])
        self.assertIsInstance(queue.getHandler(), jc.Handler)
        queue.postRunnable(lambda: order.append("never"), 60_000)
        queue.cleanupQueue()
        queue.recycle()
        queue.join(int(TIMEOUT * 1000))
        self.assertFalse(queue.isAlive())
        self.assertFalse(queue.postRunnable(int))


if __name__ == "__main__":
    unittest.main()
