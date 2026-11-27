"""Python-local Java threading classes over the plugin worker-thread model.

Every thread here is a ``threading.Thread``, so ``_ayu_threads`` attributes it to
the plugin generation, caps it, and marshals its bridge calls onto the serial
Python queue. That queue thread is the model's main looper: plugin callbacks
and everything posted to ``Looper.getMainLooper()`` run on it, and native UI
work produced there is marshalled to UIKit's main thread by the host.

Thread priorities are recorded hints: Python threads share the interpreter
lock, so no OS scheduling class is applied. ``Thread.interrupt`` wakes only the
blocking methods of this module. Collection views are immutable snapshots.
"""
from __future__ import annotations

import _thread
import collections
import heapq
import itertools
import os
import sys
import threading
import time
import weakref

SCHEDULER = ("scheduler.schedule", "scheduler.cancel")
QUEUE_NAMES = ("stageQueue", "globalQueue", "cacheClearQueue", "searchQueue", "phoneBookQueue",
               "themeQueue", "externalNetworkQueue", "pluginsQueue")
KEEP_ALIVE_SECONDS = 30.0
_MISSING = {}
_sequence = itertools.count(1)


def _bridge():
    import ayu_bridge
    return ayu_bridge


def _threads():
    import _ayu_threads
    return _ayu_threads


def _unsupported(message):
    """``UnsupportedAPI`` that ``hasattr``/``getattr`` defaults treat as a missing member."""
    base = _bridge().UnsupportedAPI
    cls = _MISSING.get(base)
    if cls is None:
        cls = _MISSING[base] = type("UnsupportedMember", (base, AttributeError), {})
    return cls(message)


def _java_error(name, fallback, message):
    """The javalib exception class for ``name`` when it is bundled, else a builtin."""
    import _ayu_javalib
    cls = _ayu_javalib.local_class(name)
    return (cls if isinstance(cls, type) and issubclass(cls, BaseException) else fallback)(message)


def _illegal_argument(message):
    return _java_error("java.lang.IllegalArgumentException", ValueError, message)


def _illegal_state(message):
    return _java_error("java.lang.IllegalStateException", RuntimeError, message)


def _null(message):
    return _java_error("java.lang.NullPointerException", TypeError, message)


try:
    from . import java_lang as _java_lang
except ImportError:  # the thread model also works without javalib's java.lang provider
    _java_lang = None


class InterruptedException(Exception if _java_lang is None else _java_lang.Exception_):
    """``java.lang.InterruptedException``: a blocked thread was woken by ``Thread.interrupt``.

    It is declared here because only the thread model raises it. ``Thread.sleep`` and
    ``join``, latches, semaphores, conditions, blocking queues, ``Future.get`` and
    ``awaitTermination`` raise it after clearing the thread's interrupt flag, as Java does.
    """


if _java_lang is None:
    InterruptedException.getMessage = lambda self: str(self) or None
else:
    _java_lang.register({"java.lang.InterruptedException": InterruptedException})


def _interrupted():
    return InterruptedException("Thread was interrupted")


def _own(closer):
    """Tie a thread-owning object to the calling plugin generation, if there is one."""
    threads = _threads()
    if threads._scope() is not None:
        threads.add_closer(closer)


def _disown(closer):
    _threads().remove_closer(closer)


def _integer(value, name):
    if type(value) is float and value == int(value):
        value = int(value)
    if type(value) is not int:
        raise TypeError(f"{name} must be an integer")
    return value


def _local(value, what):
    """Reject host references: a local class cannot run or wrap a native object."""
    bridge = _bridge()
    if isinstance(value, (bridge.RemoteObject, bridge.JavaClass)):
        raise _unsupported(f"A host object cannot be used as a {what} by a Python-local class")
    return value


def _task(value, method="run"):
    """The zero-argument callable behind a Runnable-like value."""
    _local(value, "Runnable")
    target = None if isinstance(value, type) else getattr(value, method, None)
    if callable(target):
        return target
    if callable(value):
        return value
    if value is None:
        raise _null("Runnable is null")
    raise TypeError(f"Expected a callable or an object with {method}()")


def _function(value, *methods):
    """A Java functional-interface argument as a Python callable."""
    _local(value, "callback")
    if not isinstance(value, type):
        for method in methods:
            target = getattr(value, method, None)
            if callable(target):
                return target
    if callable(value):
        return value
    raise TypeError("Expected a callable or a functional interface object")


class _JavaType(type):
    def __getattr__(cls, name):
        if name.startswith("_"):
            raise AttributeError(name)
        raise _unsupported(f"{cls.__name__}.{name} is not implemented")


class _Java(metaclass=_JavaType):
    def __getattr__(self, name):
        if name.startswith("_"):
            raise AttributeError(name)
        raise _unsupported(f"{type(self).__name__}.{name} is not implemented")


class _Overload:
    """A Java name that is static on the class and an instance method on objects."""

    def __init__(self, static, instance):
        self.static, self.instance = static, instance

    def __get__(self, instance, owner):
        if instance is None:
            return self.static
        return self.instance.__get__(instance, owner)


class _Iterator:
    def __init__(self, values):
        self._values = collections.deque(values)

    def hasNext(self):
        return bool(self._values)

    def next(self):
        if not self._values:
            raise _java_error("java.util.NoSuchElementException", StopIteration, "No more elements")
        return self._values.popleft()

    def __iter__(self):
        return self

    def __next__(self):
        if not self._values:
            raise StopIteration
        return self._values.popleft()


class _View(tuple):
    """Immutable snapshot returned where Java returns a collection."""

    def size(self):
        return len(self)

    def isEmpty(self):
        return not self

    def contains(self, value):
        return value in self

    def get(self, index):
        return self[index]

    def toArray(self):
        return list(self)

    def iterator(self):
        return _Iterator(self)


def _await(condition, done, timeout=None):
    """Wait on a held condition until ``done()``; False on timeout.

    ``Thread.interrupt`` on the waiting thread raises InterruptedException.
    """
    thread = Thread._peek()
    deadline = None if timeout is None else time.monotonic() + timeout
    if thread is not None:
        thread._blocker = condition
    try:
        while True:
            if thread is not None and thread._take_interrupt():
                raise _interrupted()
            if done():
                return True
            remaining = None if deadline is None else deadline - time.monotonic()
            if remaining is not None and remaining <= 0:
                return False
            condition.wait(remaining)
    finally:
        if thread is not None:
            thread._blocker = None


# ---- java.util.concurrent.TimeUnit ----------------------------------------

class TimeUnit(_Java):
    def __init__(self, name, ordinal, nanos):
        self._name, self._ordinal, self._nanos = name, ordinal, nanos

    def _to(self, duration, nanos):
        total = _integer(duration, "duration") * self._nanos
        return -(-total // nanos) if total < 0 else total // nanos

    def toNanos(self, duration):
        return self._to(duration, 1)

    def toMicros(self, duration):
        return self._to(duration, 1_000)

    def toMillis(self, duration):
        return self._to(duration, 1_000_000)

    def toSeconds(self, duration):
        return self._to(duration, 1_000_000_000)

    def toMinutes(self, duration):
        return self._to(duration, 60_000_000_000)

    def toHours(self, duration):
        return self._to(duration, 3_600_000_000_000)

    def toDays(self, duration):
        return self._to(duration, 86_400_000_000_000)

    def convert(self, duration, unit):
        return unit._to(duration, self._nanos)

    def sleep(self, duration):
        Thread.sleep(self.toMillis(duration))

    def name(self):
        return self._name

    def ordinal(self):
        return self._ordinal

    def toString(self):
        return self._name

    __str__ = __repr__ = toString

    @staticmethod
    def values():
        return list(TimeUnit._VALUES)

    @staticmethod
    def valueOf(name):
        for unit in TimeUnit._VALUES:
            if unit._name == name:
                return unit
        raise _illegal_argument(f"No enum constant TimeUnit.{name}")


TimeUnit._VALUES = tuple(TimeUnit(name, index, nanos) for index, (name, nanos) in enumerate((
    ("NANOSECONDS", 1), ("MICROSECONDS", 1_000), ("MILLISECONDS", 1_000_000), ("SECONDS", 1_000_000_000),
    ("MINUTES", 60_000_000_000), ("HOURS", 3_600_000_000_000), ("DAYS", 86_400_000_000_000))))
for _unit in TimeUnit._VALUES:
    setattr(TimeUnit, _unit._name, _unit)
del _unit


def _seconds(arguments, what):
    """``()`` -> None, ``(timeout, TimeUnit)`` -> seconds."""
    if not arguments:
        return None
    if len(arguments) != 2 or not isinstance(arguments[1], TimeUnit):
        raise TypeError(f"{what} takes no arguments or (timeout, TimeUnit)")
    return max(0, arguments[1].toNanos(arguments[0])) / 1_000_000_000


# ---- java.lang ------------------------------------------------------------

class Runnable(_Java):
    def __init__(self, function=None):
        if function is not None and not callable(function):
            raise TypeError("Runnable requires a callable")
        self._function = function

    def run(self):
        if self._function is None:
            raise NotImplementedError("Runnable.run is abstract")
        return self._function()


class Callable(_Java):
    def __init__(self, function=None):
        if function is not None and not callable(function):
            raise TypeError("Callable requires a callable")
        self._function = function

    def call(self):
        if self._function is None:
            raise NotImplementedError("Callable.call is abstract")
        return self._function()


class StackTraceElement:
    """One Python frame of a thread, in the shape of java.lang.StackTraceElement."""

    def __init__(self, frame):
        code = frame.f_code
        owner = frame.f_locals.get("self")
        self._class = (type(owner).__module__ + "." + type(owner).__qualname__ if owner is not None
                       else frame.f_globals.get("__name__", ""))
        self._method, self._file, self._line = code.co_name, os.path.basename(code.co_filename), frame.f_lineno

    def getClassName(self):
        return self._class

    def getMethodName(self):
        return self._method

    def getFileName(self):
        return self._file

    def getLineNumber(self):
        return self._line

    def isNativeMethod(self):
        return False

    def toString(self):
        return f"{self._class}.{self._method}({self._file}:{self._line})"

    __str__ = __repr__ = toString


class _ThreadMap(dict):
    def keySet(self):
        return _View(self.keys())

    def values(self):
        return _View(dict.values(self))

    def size(self):
        return len(self)

    def isEmpty(self):
        return not self

    def containsKey(self, key):
        return key in self


class Thread(_Java):
    __ayu_requires__ = SCHEDULER
    MIN_PRIORITY, NORM_PRIORITY, MAX_PRIORITY = 1, 5, 10
    _wrappers = weakref.WeakKeyDictionary()

    class UncaughtExceptionHandler(_Java):
        def __init__(self, function=None):
            self._function = function

        def uncaughtException(self, thread, throwable):
            if self._function is None:
                raise NotImplementedError("UncaughtExceptionHandler.uncaughtException is abstract")
            return self._function(thread, throwable)

    def __init__(self, *arguments):
        values = list(arguments)
        if len(values) >= 2 and values[0] is None:
            values.pop(0)  # a null ThreadGroup
        target = name = None
        if len(values) == 1 and isinstance(values[0], str):
            name = values[0]
        elif values:
            target = values[0]
            if len(values) > 1:
                name = values[1]
            if len(values) > 2:
                _integer(values[2], "stackSize")  # a suggestion in Java as well
            if len(values) > 3 or name is not None and not isinstance(name, str):
                raise _unsupported("Thread constructor overload is not implemented")
        self._setup(None, target, name)

    def _setup(self, python_thread, target, name):
        self._runnable = None if target is None else _task(target)
        self._id = next(_sequence)
        self._java_daemon = False
        self._priority = Thread.NORM_PRIORITY
        self._interrupt = False
        self._blocker = None
        self._handler = None
        self._finished = False
        self._done = threading.Condition()
        self._owned = python_thread is None
        if python_thread is None:
            python_thread = threading.Thread(target=self._bootstrap, name=name or f"Thread-{self._id}", daemon=True)
        self._thread = python_thread
        Thread._wrappers[python_thread] = self

    @classmethod
    def _wrap(cls, python_thread):
        wrapper = Thread._wrappers.get(python_thread)
        if wrapper is None:
            wrapper = object.__new__(Thread)
            wrapper._setup(python_thread, None, None)
        return wrapper

    @staticmethod
    def _peek():
        return Thread._wrappers.get(threading.current_thread())

    def _take_interrupt(self):
        interrupted, self._interrupt = self._interrupt, False
        return interrupted

    def _bootstrap(self):
        try:
            self.run()
        finally:
            with self._done:
                self._finished = True
                self._done.notify_all()

    def run(self):
        if self._runnable is not None:
            self._runnable()

    def start(self):
        if not self._owned or self._thread.ident is not None:
            raise _java_error("java.lang.IllegalThreadStateException", RuntimeError, "Thread already started")
        self._thread.start()

    def join(self, *arguments):
        if len(arguments) > 2:
            raise TypeError("join takes at most (millis, nanos)")
        timeout = None
        if arguments:
            millis = _integer(arguments[0], "millis") + (1 if len(arguments) == 2 and arguments[1] else 0)
            if millis < 0:
                raise _illegal_argument("timeout value is negative")
            timeout = millis / 1000 if millis else None
        if not self._owned:
            if self._thread is threading.current_thread():
                raise _unsupported("A thread cannot join itself")
            self._thread.join(timeout)
            return
        with self._done:
            _await(self._done, lambda: self._finished or self._thread.ident is None, timeout)

    def isAlive(self):
        return self._thread.is_alive()

    def interrupt(self):
        self._interrupt = True
        blocker = self._blocker
        if blocker is not None:
            with blocker:
                blocker.notify_all()

    def isInterrupted(self):
        return self._interrupt

    @staticmethod
    def interrupted():
        thread = Thread._peek()
        return thread is not None and thread._take_interrupt()

    def getName(self):
        return self._thread.name

    def setName(self, name):
        if not isinstance(name, str):
            raise _null("name cannot be null")
        self._thread.name = name

    def getId(self):
        return self._id

    threadId = getId

    def isDaemon(self):
        return self._java_daemon

    def setDaemon(self, daemon):
        if self._thread.ident is not None:
            raise _java_error("java.lang.IllegalThreadStateException", RuntimeError, "Thread already started")
        self._java_daemon = bool(daemon)

    def getPriority(self):
        return self._priority

    def setPriority(self, priority):
        if not Thread.MIN_PRIORITY <= _integer(priority, "priority") <= Thread.MAX_PRIORITY:
            raise _illegal_argument("Thread priority out of range")
        self._priority = priority

    def getUncaughtExceptionHandler(self):
        return self._handler

    def setUncaughtExceptionHandler(self, handler):
        self._handler = handler
        if handler is None:
            self._thread.__dict__.pop("_ayu_uncaught", None)
        else:
            function = _function(handler, "uncaughtException")
            self._thread._ayu_uncaught = lambda _thread, error: function(self, error)

    @staticmethod
    def getDefaultUncaughtExceptionHandler():
        return _threads().state().storage.get("thread.default_handler")

    @staticmethod
    def setDefaultUncaughtExceptionHandler(handler):
        """Per plugin generation: it never observes another plugin's threads."""
        state = _threads().state()
        if handler is None:
            state.storage.pop("thread.default_handler", None)
            state.uncaught = None
            return
        function = _function(handler, "uncaughtException")
        state.storage["thread.default_handler"] = handler
        state.uncaught = lambda thread, error: function(Thread._wrap(thread), error)

    def getStackTrace(self):
        frame = sys._current_frames().get(self._thread.ident)
        elements = []
        while frame is not None and len(elements) < 256:
            elements.append(StackTraceElement(frame))
            frame = frame.f_back
        return elements

    @staticmethod
    def getAllStackTraces():
        return _ThreadMap((wrapper, wrapper.getStackTrace())
                          for wrapper in map(Thread._wrap, threading.enumerate()))

    @staticmethod
    def currentThread():
        return Thread._wrap(threading.current_thread())

    @staticmethod
    def sleep(millis, nanos=0):
        seconds = _integer(millis, "millis") / 1000 + _integer(nanos, "nanos") / 1_000_000_000
        if millis < 0 or nanos < 0:
            raise _illegal_argument("timeout value is negative")
        condition = threading.Condition()
        with condition:
            _await(condition, lambda: False, seconds)

    @staticmethod
    def yield_():
        time.sleep(0)

    def toString(self):
        return f"Thread[{self._thread.name},{self._priority}]"

    __str__ = __repr__ = toString


setattr(Thread, "yield", Thread.__dict__["yield_"])


class ThreadLocal(_Java):
    def __init__(self, supplier=None):
        self._values = threading.local()
        self._supplier = None if supplier is None else _function(supplier, "get")

    def initialValue(self):
        return None if self._supplier is None else self._supplier()

    def get(self):
        try:
            return self._values.value
        except AttributeError:
            self._values.value = self.initialValue()
            return self._values.value

    def set(self, value):
        self._values.value = value

    def remove(self):
        self._values.__dict__.pop("value", None)

    @staticmethod
    def withInitial(supplier):
        return ThreadLocal(supplier)


# ---- java.util.concurrent: synchronizers ----------------------------------

class ExecutionException(Exception):
    def __init__(self, cause=None):
        super().__init__(repr(cause))
        self.__cause__ = cause if isinstance(cause, BaseException) else None
        self._cause = cause

    def getCause(self):
        return self._cause

    def getMessage(self):
        return str(self)


class TimeoutException(Exception):
    def getMessage(self):
        return str(self) or None


class CancellationException(RuntimeError):
    def getMessage(self):
        return str(self) or None


class RejectedExecutionException(RuntimeError):
    def getMessage(self):
        return str(self) or None


class CountDownLatch(_Java):
    def __init__(self, count):
        if _integer(count, "count") < 0:
            raise _illegal_argument("count < 0")
        self._count = count
        self._condition = threading.Condition()

    def countDown(self):
        with self._condition:
            if self._count > 0:
                self._count -= 1
                if self._count == 0:
                    self._condition.notify_all()

    def getCount(self):
        return self._count

    def await_(self, *arguments):
        """``await()`` returns None; ``await(timeout, unit)`` returns whether the count reached zero."""
        timeout = _seconds(arguments, "await")
        with self._condition:
            reached = _await(self._condition, lambda: self._count == 0, timeout)
        return reached if arguments else None

    def toString(self):
        return f"CountDownLatch[Count = {self._count}]"

    __str__ = __repr__ = toString


setattr(CountDownLatch, "await", CountDownLatch.await_)


class Semaphore(_Java):
    def __init__(self, permits, fair=False):
        self._permits = _integer(permits, "permits")
        self._condition = threading.Condition()

    @staticmethod
    def _count(arguments):
        count = _integer(arguments[0], "permits") if arguments else 1
        if count < 0:
            raise _illegal_argument("permits < 0")
        return count

    def acquire(self, *arguments):
        count = self._count(arguments[:1])
        with self._condition:
            _await(self._condition, lambda: self._permits >= count)
            self._permits -= count

    def tryAcquire(self, *arguments):
        """``()``, ``(permits)``, ``(timeout, unit)`` or ``(permits, timeout, unit)``."""
        count = self._count(arguments[:1]) if len(arguments) in (1, 3) else 1
        timeout = _seconds(arguments[-2:], "tryAcquire") if len(arguments) >= 2 else 0
        with self._condition:
            if not _await(self._condition, lambda: self._permits >= count, timeout):
                return False
            self._permits -= count
            return True

    def release(self, *arguments):
        count = self._count(arguments[:1])
        with self._condition:
            self._permits += count
            self._condition.notify_all()

    def availablePermits(self):
        return self._permits

    def drainPermits(self):
        with self._condition:
            permits, self._permits = self._permits, 0
            return permits


class Condition(_Java):
    """``java.util.concurrent.locks.Condition`` of a ReentrantLock."""

    def __init__(self, lock):
        self._lock = lock
        self._condition = threading.Condition(lock._lock)
        self._signals = 0

    def await_(self, *arguments):
        timeout = _seconds(arguments, "await")
        lock, ticket = self._lock, self._signals
        if not lock.isHeldByCurrentThread():
            raise _java_error("java.lang.IllegalMonitorStateException", RuntimeError, "Lock is not held")
        holds, lock._owner, lock._holds = lock._holds, None, 0
        try:
            signalled = _await(self._condition, lambda: self._signals != ticket, timeout)
        finally:
            lock._owner, lock._holds = threading.get_ident(), holds
        return signalled if arguments else None

    def signal(self):
        self._signals += 1
        self._condition.notify()

    def signalAll(self):
        self._signals += 1
        self._condition.notify_all()


setattr(Condition, "await", Condition.await_)


class Lock(_Java):
    """``java.util.concurrent.locks.Lock``; ReentrantLock is the implementation."""

    def lock(self):
        raise NotImplementedError("Lock.lock is abstract")

    def unlock(self):
        raise NotImplementedError("Lock.unlock is abstract")


class ReentrantLock(Lock):
    def __init__(self, fair=False):
        self._lock = threading.RLock()
        self._owner = None
        self._holds = 0

    def lock(self):
        self._lock.acquire()
        self._owner, self._holds = threading.get_ident(), self._holds + 1

    lockInterruptibly = lock

    def tryLock(self, *arguments):
        timeout = _seconds(arguments, "tryLock")
        acquired = self._lock.acquire(False) if not timeout else self._lock.acquire(True, timeout)
        if acquired:
            self._owner, self._holds = threading.get_ident(), self._holds + 1
        return acquired

    def unlock(self):
        if self._owner != threading.get_ident():
            raise _java_error("java.lang.IllegalMonitorStateException", RuntimeError, "Lock is not held")
        self._holds -= 1
        if not self._holds:
            self._owner = None
        self._lock.release()

    def isLocked(self):
        return self._holds > 0

    def isHeldByCurrentThread(self):
        return self._owner == threading.get_ident()

    def getHoldCount(self):
        return self._holds if self.isHeldByCurrentThread() else 0

    def newCondition(self):
        return Condition(self)

    def __enter__(self):
        self.lock()
        return self

    def __exit__(self, *exception):
        self.unlock()


class _Atomic(_Java):
    _BITS = None

    def __init__(self, value=None):
        self._guard = _thread.allocate_lock()
        self._value = self._coerce(self._ZERO if value is None else value)

    def _coerce(self, value):
        if self._BITS is None:
            return value
        if type(value) is not int:
            raise TypeError("Expected an integer")
        half = 1 << (self._BITS - 1)
        return (value + half) % (1 << self._BITS) - half

    def get(self):
        return self._value

    getPlain = getAcquire = getOpaque = get

    def set(self, value):
        value = self._coerce(value)
        with self._guard:
            self._value = value

    lazySet = setPlain = setRelease = setOpaque = set

    def getAndSet(self, value):
        value = self._coerce(value)
        with self._guard:
            previous, self._value = self._value, value
        return previous

    def _same(self, current, expected):
        return current == expected

    def compareAndSet(self, expected, value):
        value = self._coerce(value)
        with self._guard:
            if not self._same(self._value, expected):
                return False
            self._value = value
            return True

    weakCompareAndSet = weakCompareAndSetPlain = compareAndSet

    def _update(self, function, previous):
        # The updater runs unlocked and is retried on interference, as in Java.
        while True:
            current = self._value
            updated = self._coerce(function(current))
            with self._guard:
                if self._value is current or self._value == current:
                    self._value = updated
                    return current if previous else updated

    def getAndUpdate(self, function):
        return self._update(_function(function, "applyAsInt", "applyAsLong", "apply"), True)

    def updateAndGet(self, function):
        return self._update(_function(function, "applyAsInt", "applyAsLong", "apply"), False)

    def getAndAccumulate(self, value, function):
        function = _function(function, "applyAsInt", "applyAsLong", "apply")
        return self._update(lambda current: function(current, value), True)

    def accumulateAndGet(self, value, function):
        function = _function(function, "applyAsInt", "applyAsLong", "apply")
        return self._update(lambda current: function(current, value), False)

    def toString(self):
        return "true" if self._value is True else "false" if self._value is False else str(self._value)

    __str__ = toString


class AtomicInteger(_Atomic):
    _BITS, _ZERO = 32, 0

    def getAndAdd(self, delta):
        return self._update(lambda current: current + delta, True)

    def addAndGet(self, delta):
        return self._update(lambda current: current + delta, False)

    def getAndIncrement(self):
        return self.getAndAdd(1)

    def getAndDecrement(self):
        return self.getAndAdd(-1)

    def incrementAndGet(self):
        return self.addAndGet(1)

    def decrementAndGet(self):
        return self.addAndGet(-1)

    def intValue(self):
        return (self._value + 2**31) % 2**32 - 2**31

    def longValue(self):
        return self._value

    def doubleValue(self):
        return float(self._value)

    floatValue = doubleValue


class AtomicLong(AtomicInteger):
    __ayu_overrides_host__ = True  # the Swift adapter is a subset; the host neither takes nor returns one
    _BITS = 64


class AtomicBoolean(_Atomic):
    __ayu_overrides_host__ = True  # the Swift adapter is a subset; the host neither takes nor returns one
    _ZERO = False

    def _coerce(self, value):
        if type(value) is not bool:
            raise TypeError("Expected a boolean")
        return value


class AtomicReference(_Atomic):
    _ZERO = None

    def _same(self, current, expected):
        return current is expected


# ---- java.util.concurrent: collections ------------------------------------

class _Entry:
    def __init__(self, owner, key, value):
        self._owner, self._key, self._value = owner, key, value

    def getKey(self):
        return self._key

    def getValue(self):
        return self._value

    def setValue(self, value):
        previous, self._value = self._value, value
        self._owner.put(self._key, value)
        return previous


class ConcurrentHashMap(_Java):
    def __init__(self, *arguments):
        self._guard = threading.RLock()
        self._items = {}
        if arguments and not isinstance(arguments[0], (int, float)):
            self.putAll(arguments[0])

    @staticmethod
    def _check(*values):
        if any(value is None for value in values):
            raise _null("ConcurrentHashMap does not permit null keys or values")

    def size(self):
        return len(self._items)

    mappingCount = size

    def isEmpty(self):
        return not self._items

    def get(self, key):
        return self._items.get(key)

    def getOrDefault(self, key, default):
        return self._items.get(key, default)

    def containsKey(self, key):
        return key in self._items

    def containsValue(self, value):
        return value in list(self._items.values())

    contains = containsValue

    def put(self, key, value):
        self._check(key, value)
        with self._guard:
            previous = self._items.get(key)
            self._items[key] = value
        return previous

    def putIfAbsent(self, key, value):
        self._check(key, value)
        with self._guard:
            if key in self._items:
                return self._items[key]
            self._items[key] = value
            return None

    def putAll(self, other):
        items = other.items() if isinstance(other, dict) else [(entry.getKey(), entry.getValue())
                                                                for entry in other.entrySet()]
        for key, value in list(items):
            self.put(key, value)

    def remove(self, key, *value):
        with self._guard:
            if value:
                if key in self._items and self._items[key] == value[0]:
                    del self._items[key]
                    return True
                return False
            return self._items.pop(key, None)

    def replace(self, key, *values):
        self._check(key, *values)
        with self._guard:
            if len(values) == 2:
                if key in self._items and self._items[key] == values[0]:
                    self._items[key] = values[1]
                    return True
                return False
            if key not in self._items:
                return None
            previous, self._items[key] = self._items[key], values[0]
            return previous

    def computeIfAbsent(self, key, function):
        function = _function(function, "apply")
        with self._guard:
            if key not in self._items:
                value = function(key)
                if value is None:
                    return None
                self._items[key] = value
            return self._items[key]

    def computeIfPresent(self, key, function):
        return self._compute(key, _function(function, "apply"), True)

    def compute(self, key, function):
        return self._compute(key, _function(function, "apply"), False)

    def _compute(self, key, function, present_only):
        with self._guard:
            if present_only and key not in self._items:
                return None
            value = function(key, self._items.get(key))
            if value is None:
                self._items.pop(key, None)
            else:
                self._items[key] = value
            return value

    def merge(self, key, value, function):
        self._check(key, value)
        function = _function(function, "apply")
        return self._compute(key, lambda _key, current: value if current is None else function(current, value), False)

    def clear(self):
        with self._guard:
            self._items.clear()

    def keySet(self):
        return _View(list(self._items))

    keys = keySet

    def values(self):
        return _View(list(self._items.values()))

    def entrySet(self):
        return _View(_Entry(self, key, value) for key, value in list(self._items.items()))

    def forEach(self, function):
        function = _function(function, "accept")
        for key, value in list(self._items.items()):
            function(key, value)

    def __len__(self):
        return len(self._items)

    def __contains__(self, key):
        return key in self._items

    def __iter__(self):
        return iter(list(self._items))

    def __getitem__(self, key):
        return self._items[key]

    def __setitem__(self, key, value):
        self.put(key, value)

    def __delitem__(self, key):
        with self._guard:
            del self._items[key]

    def items(self):
        return list(self._items.items())

    def toString(self):
        return "{" + ", ".join(f"{key}={value}" for key, value in self.items()) + "}"

    __str__ = toString


def _elements(values):
    if values is None:
        raise _null("Collection is null")
    return list(values)


class CopyOnWriteArrayList(_Java):
    def __init__(self, values=()):
        self._guard = threading.RLock()
        self._items = tuple(_elements(values))

    def size(self):
        return len(self._items)

    def isEmpty(self):
        return not self._items

    def get(self, index):
        return self._items[self._index(index)]

    def _index(self, index, extra=0):
        if not 0 <= _integer(index, "index") < len(self._items) + extra:
            raise _java_error("java.lang.IndexOutOfBoundsException", IndexError, f"Index: {index}")
        return index

    def contains(self, value):
        return value in self._items

    def indexOf(self, value):
        return self._items.index(value) if value in self._items else -1

    def add(self, *arguments):
        with self._guard:
            if len(arguments) == 2:
                index = self._index(arguments[0], 1)
                self._items = self._items[:index] + (arguments[1],) + self._items[index:]
                return None
            self._items += (arguments[0],)
            return True

    def addIfAbsent(self, value):
        with self._guard:
            if value in self._items:
                return False
            self._items += (value,)
            return True

    def addAll(self, values):
        values = tuple(_elements(values))
        with self._guard:
            self._items += values
        return bool(values)

    def set(self, index, value):
        with self._guard:
            previous = self._items[self._index(index)]
            self._items = self._items[:index] + (value,) + self._items[index + 1:]
        return previous

    def remove(self, value):
        """An ``int`` argument is the index overload, as in Java."""
        with self._guard:
            if type(value) is int:
                removed = self._items[self._index(value)]
                self._items = self._items[:value] + self._items[value + 1:]
                return removed
            if value not in self._items:
                return False
            index = self._items.index(value)
            self._items = self._items[:index] + self._items[index + 1:]
            return True

    def clear(self):
        with self._guard:
            self._items = ()

    def toArray(self):
        return list(self._items)

    def iterator(self):
        return _Iterator(self._items)

    def forEach(self, function):
        function = _function(function, "accept")
        for value in self._items:
            function(value)

    def __len__(self):
        return len(self._items)

    def __iter__(self):
        return iter(self._items)

    def __getitem__(self, index):
        return self._items[index]

    def __contains__(self, value):
        return value in self._items

    def toString(self):
        return "[" + ", ".join(str(value) for value in self._items) + "]"

    __str__ = toString


class ConcurrentLinkedQueue(_Java):
    _CAPACITY = None

    def __init__(self, values=()):
        self._condition = threading.Condition()
        self._items = collections.deque()
        if type(values) is int:
            if values <= 0:
                raise _illegal_argument("capacity must be positive")
            self._CAPACITY = values
        elif values is not None:
            for value in _elements(values):
                self.add(value)

    def _full(self):
        return self._CAPACITY is not None and len(self._items) >= self._CAPACITY

    def offer(self, value, *timeout):
        if value is None:
            raise _null("Queue does not permit null elements")
        with self._condition:
            if self._full() and not (timeout and _await(self._condition, lambda: not self._full(),
                                                        _seconds(timeout, "offer"))):
                return False
            self._items.append(value)
            self._condition.notify_all()
            return True

    def add(self, value):
        if not self.offer(value):
            raise _illegal_state("Queue full")
        return True

    def poll(self, *timeout):
        with self._condition:
            if not self._items and not (timeout and _await(self._condition, lambda: bool(self._items),
                                                          _seconds(timeout, "poll"))):
                return None
            value = self._items.popleft()
            self._condition.notify_all()
            return value

    def peek(self):
        with self._condition:
            return self._items[0] if self._items else None

    def remove(self, *value):
        with self._condition:
            if not value:
                if not self._items:
                    raise _java_error("java.util.NoSuchElementException", LookupError, "Queue is empty")
                self._condition.notify_all()
                return self._items.popleft()
            try:
                self._items.remove(value[0])
            except ValueError:
                return False
            self._condition.notify_all()
            return True

    def element(self):
        with self._condition:
            if not self._items:
                raise _java_error("java.util.NoSuchElementException", LookupError, "Queue is empty")
            return self._items[0]

    def contains(self, value):
        return value in list(self._items)

    def size(self):
        return len(self._items)

    def isEmpty(self):
        return not self._items

    def clear(self):
        with self._condition:
            self._items.clear()
            self._condition.notify_all()

    def toArray(self):
        return list(self._items)

    def iterator(self):
        return _Iterator(list(self._items))

    def __len__(self):
        return len(self._items)

    def __iter__(self):
        return iter(list(self._items))


class LinkedBlockingQueue(ConcurrentLinkedQueue):
    """Also the implementation behind the ``BlockingQueue`` interface name."""

    def put(self, value):
        if value is None:
            raise _null("Queue does not permit null elements")
        with self._condition:
            _await(self._condition, lambda: not self._full())
            self._items.append(value)
            self._condition.notify_all()

    def take(self):
        with self._condition:
            _await(self._condition, lambda: bool(self._items))
            value = self._items.popleft()
            self._condition.notify_all()
            return value

    def remainingCapacity(self):
        return 2**31 - 1 if self._CAPACITY is None else self._CAPACITY - len(self._items)

    def drainTo(self, target, limit=None):
        with self._condition:
            count = len(self._items) if limit is None else min(len(self._items), _integer(limit, "maxElements"))
            for _ in range(count):
                target.add(self._items.popleft())
            self._condition.notify_all()
            return count


class ArrayBlockingQueue(LinkedBlockingQueue):
    def __init__(self, capacity, fair=False, values=()):
        if type(capacity) is not int:
            raise TypeError("capacity must be an integer")
        super().__init__(capacity)
        for value in _elements(values):
            self.add(value)


# ---- java.util.concurrent: futures and executors --------------------------

class Future(_Java):
    """Also ``FutureTask``: ``Future(callable)`` or ``Future(runnable, result)``."""

    def __init__(self, *arguments):
        if len(arguments) > 2:
            raise TypeError("FutureTask takes (callable) or (runnable, result)")
        self._condition = threading.Condition()
        self._state = "new"
        self._result = self._error = None
        self._command = arguments[0] if arguments else None
        if len(arguments) == 2:
            run, fixed = _task(arguments[0]), arguments[1]
            self._call = lambda: (run(), fixed)[1]
        elif arguments:
            self._call = _task(arguments[0], "call")
        else:
            self._call = None
        self._pool = None
        self._due = self._period = None
        self._fixed_rate = False
        # Nobody holds the future of an ``execute``d command, so its failure is reported.
        self._detached = False

    def run(self):
        with self._condition:
            if self._state != "new" or self._call is None:
                return
            self._state = "running"
        try:
            result, error = self._call(), None
        except BaseException as failure:
            result, error = None, failure
        with self._condition:
            if self._state != "running":
                return
            if error is None and self._period is not None and self._pool is not None and self._pool._requeue(self):
                self._state = "new"
                return
            self._result, self._error = result, error
            self._state = "done"
            self._condition.notify_all()
        self.done()

    def done(self):
        """FutureTask hook, called once the task completes."""

    def cancel(self, mayInterruptIfRunning=False):
        with self._condition:
            if self._state in ("done", "cancelled"):
                return False
            if self._state == "running" and self._period is None:
                return False
            self._state = "cancelled"
            self._condition.notify_all()
        if self._pool is not None:
            self._pool._forget(self)
        return True

    def isCancelled(self):
        return self._state == "cancelled"

    def isDone(self):
        return self._state in ("done", "cancelled")

    def get(self, *arguments):
        timeout = _seconds(arguments, "get")
        with self._condition:
            if not _await(self._condition, self.isDone, timeout):
                raise TimeoutException()
            if self._state == "cancelled":
                raise CancellationException()
            if self._error is not None:
                raise ExecutionException(self._error)
            return self._result

    def getDelay(self, unit):
        remaining = 0 if self._due is None else self._due - time.monotonic()
        return unit.convert(int(remaining * 1_000_000_000), TimeUnit.NANOSECONDS)


def _uncaught(error):
    """A task without a future failed: tell the generation's default handler and the log."""
    threads = _threads()
    state = threads._workers.get(threading.get_ident())
    handler = None if state is None else state.uncaught
    if handler is not None:
        try:
            handler(threading.current_thread(), error)
        except BaseException:
            pass
    threads.report_failure(error)


class _Pool:
    """Bounded worker pool with delayed tasks; idle workers exit so nothing stays parked."""

    def __init__(self, name, maximum, keep_alive=KEEP_ALIVE_SECONDS, capacity=None):
        if maximum <= 0:
            raise _illegal_argument("Pool size must be positive")
        self.name, self.maximum, self.keep_alive = name, maximum, keep_alive
        self.capacity = min(capacity or _threads().MAX_PENDING_TASKS, _threads().MAX_PENDING_TASKS)
        self.condition = threading.Condition()
        self.ready = collections.deque()
        self.delayed = []
        self.workers = set()
        self.idle = self.active = self.started = self.completed = 0
        self.stopped = False
        self.failed = None
        _own(self.shutdown_now)

    def submit(self, future, delay=None, period=None, fixed_rate=False, detached=False):
        future._pool, future._period, future._fixed_rate, future._detached = self, period, fixed_rate, detached
        with self.condition:
            if self.stopped:
                raise RejectedExecutionException("Executor has been shut down")
            if len(self.ready) + len(self.delayed) >= self.capacity:
                raise _bridge().BridgeError("RESOURCE_LIMIT", "Plugin executor pending work limit reached")
            if delay is None:
                self.ready.append(future)
            else:
                future._due = time.monotonic() + max(0.0, delay)
                heapq.heappush(self.delayed, (future._due, next(_sequence), future))
            if (not self.idle or not self.workers) and len(self.workers) < self.maximum:
                self._spawn(future)
            self.condition.notify()
        return future

    def _spawn(self, future):
        worker = threading.Thread(target=self._work, name=f"{self.name}-{self.started + 1}", daemon=True)
        self.workers.add(worker)
        try:
            worker.start()
        except BaseException:
            self.workers.discard(worker)
            if self.workers:
                return  # The running workers will reach the task.
            self._drop(future)
            raise
        self.started += 1

    def _drop(self, future):
        try:
            self.ready.remove(future)
        except ValueError:
            self.delayed = [entry for entry in self.delayed if entry[2] is not future]
            heapq.heapify(self.delayed)

    def _forget(self, future):
        with self.condition:
            self._drop(future)
            self.condition.notify_all()

    def _requeue(self, future):
        """Schedule the next run of a periodic task; False once the pool has stopped."""
        with self.condition:
            if self.stopped:
                return False
            now = time.monotonic()
            future._due = future._due + future._period if future._fixed_rate else now + future._period
            heapq.heappush(self.delayed, (future._due, next(_sequence), future))
            self.condition.notify()
            return True

    def _take(self):
        """Next runnable task and the seconds until the earliest delayed one; holds the condition."""
        if self.ready:
            return self.ready.popleft(), None
        if self.delayed:
            wait = self.delayed[0][0] - time.monotonic()
            if wait <= 0:
                return heapq.heappop(self.delayed)[2], None
            return None, wait
        return None, None

    def _work(self):
        worker = threading.current_thread()
        try:
            while True:
                with self.condition:
                    idle_since = time.monotonic()
                    while True:
                        future, wait = self._take()
                        if future is not None:
                            break
                        if self.stopped and not self.delayed:
                            return
                        spare = self.keep_alive - (time.monotonic() - idle_since)
                        # One waiter keeps watching the delayed heap; the others time out.
                        if spare <= 0 and (wait is None or self.idle):
                            return
                        timeout = spare if wait is None else min(wait, spare) if self.idle else wait
                        self.idle += 1
                        try:
                            self.condition.wait(max(timeout, 0.001))
                        finally:
                            self.idle -= 1
                    self.active += 1
                try:
                    future.run()
                    if future._error is not None and future._detached:
                        _uncaught(future._error)
                        if self.failed is not None:
                            self.failed(future._error)
                finally:
                    with self.condition:
                        self.active -= 1
                        self.completed += 1
                        self.condition.notify_all()
        finally:
            with self.condition:
                self.workers.discard(worker)
                self.condition.notify_all()

    def shutdown(self):
        with self.condition:
            self.stopped = True
            periodic = [entry[2] for entry in self.delayed if entry[2]._period is not None]
            self.condition.notify_all()
        _disown(self.shutdown_now)
        for future in periodic:
            future.cancel(False)

    def shutdown_now(self):
        _disown(self.shutdown_now)
        with self.condition:
            self.stopped = True
            pending = list(self.ready) + [entry[2] for entry in sorted(self.delayed, key=lambda entry: entry[:2])]
            self.ready.clear()
            self.delayed = []
            workers = list(self.workers)
            self.condition.notify_all()
        for worker in workers:
            wrapper = Thread._wrappers.get(worker)
            if wrapper is not None:
                wrapper.interrupt()
        return pending

    def terminated(self):
        return self.stopped and not self.workers and not self.ready and not self.delayed


class Executor(_Java):
    def execute(self, command):
        raise NotImplementedError("Executor.execute is abstract")


class ExecutorService(Executor):
    """Interface name; ``Executors`` returns ThreadPoolExecutor instances."""


class ScheduledExecutorService(ExecutorService):
    pass


class ThreadPoolExecutor(ExecutorService):
    __ayu_requires__ = SCHEDULER

    def __init__(self, corePoolSize, maximumPoolSize=None, keepAliveTime=None, unit=None, workQueue=None, *extra):
        if extra:
            raise _unsupported("ThreadPoolExecutor thread factories and rejection handlers are not implemented")
        maximum = corePoolSize if maximumPoolSize is None else maximumPoolSize
        if _integer(corePoolSize, "corePoolSize") < 0 or _integer(maximum, "maximumPoolSize") <= 0 or maximum < corePoolSize:
            raise _illegal_argument("Invalid pool size")
        capacity = None
        if workQueue is not None:
            if not isinstance(workQueue, LinkedBlockingQueue) or workQueue.size():
                raise _unsupported("ThreadPoolExecutor needs an empty LinkedBlockingQueue or ArrayBlockingQueue")
            capacity = workQueue._CAPACITY
        self._core, self._maximum = corePoolSize, maximum
        self._pool = _Pool(f"pool-{next(_sequence)}-thread", maximum, capacity=capacity)

    def execute(self, command):
        future = Future(_task(command), None)
        future._command = command
        self._pool.submit(future, detached=True)

    def submit(self, task, *result):
        """``submit(Callable)``, ``submit(Runnable)`` or ``submit(Runnable, result)``.

        A bare Python callable is a Callable: its return value is the result.
        """
        if len(result) > 1:
            raise TypeError("submit takes (task) or (runnable, result)")
        runnable = not isinstance(task, type) and callable(getattr(task, "run", None))
        if result or runnable and not callable(getattr(task, "call", None)):
            future = Future(_task(task), result[0] if result else None)
        else:
            future = Future(task)
        future._command = task
        return self._pool.submit(future)

    def invokeAll(self, tasks, *timeout):
        futures = [self.submit(task) for task in _elements(tasks)]
        deadline = None if not timeout else time.monotonic() + _seconds(timeout, "invokeAll")
        for future in futures:
            with future._condition:
                done = _await(future._condition, future.isDone,
                              None if deadline is None else max(0.0, deadline - time.monotonic()))
            if not done:
                future.cancel(True)
        return futures

    def shutdown(self):
        self._pool.shutdown()

    def shutdownNow(self):
        return _View(future._command for future in self._pool.shutdown_now())

    def isShutdown(self):
        return self._pool.stopped

    def isTerminated(self):
        return self._pool.terminated()

    def awaitTermination(self, timeout, unit):
        with self._pool.condition:
            return _await(self._pool.condition, self._pool.terminated, _seconds((timeout, unit), "awaitTermination"))

    def getPoolSize(self):
        return len(self._pool.workers)

    def getActiveCount(self):
        return self._pool.active

    def getCorePoolSize(self):
        return self._core

    def getMaximumPoolSize(self):
        return self._maximum

    def getCompletedTaskCount(self):
        return self._pool.completed

    def getTaskCount(self):
        pool = self._pool
        return pool.completed + pool.active + len(pool.ready) + len(pool.delayed)

    def close(self):
        self._pool.shutdown()

    def __enter__(self):
        return self

    def __exit__(self, *exception):
        self._pool.shutdown()


class ScheduledThreadPoolExecutor(ThreadPoolExecutor, ScheduledExecutorService):
    def __init__(self, corePoolSize, *extra):
        if extra:
            raise _unsupported("ScheduledThreadPoolExecutor thread factories are not implemented")
        if _integer(corePoolSize, "corePoolSize") < 0:
            raise _illegal_argument("Invalid pool size")
        super().__init__(max(corePoolSize, 1))

    def schedule(self, command, delay, unit):
        future = Future(command) if callable(getattr(command, "call", None)) else Future(_task(command), None)
        return self._pool.submit(future, delay=unit.toNanos(delay) / 1_000_000_000)

    def _periodic(self, command, initial, period, unit, fixed_rate):
        if period <= 0:
            raise _illegal_argument("period must be positive")
        return self._pool.submit(Future(_task(command), None), delay=unit.toNanos(initial) / 1_000_000_000,
                                 period=unit.toNanos(period) / 1_000_000_000, fixed_rate=fixed_rate)

    def scheduleAtFixedRate(self, command, initialDelay, period, unit):
        return self._periodic(command, initialDelay, period, unit, True)

    def scheduleWithFixedDelay(self, command, initialDelay, delay, unit):
        return self._periodic(command, initialDelay, delay, unit, False)


class Executors(_Java):
    __ayu_requires__ = SCHEDULER

    @staticmethod
    def _plain(arguments, what):
        if arguments:
            raise _unsupported(f"Executors.{what} with a ThreadFactory is not implemented")

    @staticmethod
    def newSingleThreadExecutor(*factory):
        Executors._plain(factory, "newSingleThreadExecutor")
        return ThreadPoolExecutor(1)

    @staticmethod
    def newFixedThreadPool(threads, *factory):
        Executors._plain(factory, "newFixedThreadPool")
        return ThreadPoolExecutor(threads)

    @staticmethod
    def newCachedThreadPool(*factory):
        Executors._plain(factory, "newCachedThreadPool")
        return ThreadPoolExecutor(0, _threads().MAX_THREADS_PER_PLUGIN)

    @staticmethod
    def newScheduledThreadPool(corePoolSize, *factory):
        Executors._plain(factory, "newScheduledThreadPool")
        return ScheduledThreadPoolExecutor(corePoolSize)

    @staticmethod
    def newSingleThreadScheduledExecutor(*factory):
        Executors._plain(factory, "newSingleThreadScheduledExecutor")
        return ScheduledThreadPoolExecutor(1)

    @staticmethod
    def callable(task, *result):
        run = _task(task)
        return Callable(lambda: (run(), result[0] if result else None)[1])


# ---- java.util.Timer ------------------------------------------------------

class TimerTask(_Java):
    def __init__(self, function=None):
        self._function = function
        self._future = None
        self._cancelled = False
        self._scheduled = 0

    def run(self):
        if self._function is None:
            raise NotImplementedError("TimerTask.run is abstract")
        return self._function()

    def cancel(self):
        cancelled, self._cancelled = self._cancelled, True
        future = self._future
        return not cancelled and future is not None and future.cancel(False)

    def scheduledExecutionTime(self):
        return self._scheduled


class Timer(_Java):
    __ayu_requires__ = SCHEDULER

    def __init__(self, *arguments):
        names = [value for value in arguments if isinstance(value, str)]
        if len(arguments) > 2 or len(names) > 1 or any(type(value) not in (str, bool) for value in arguments):
            raise TypeError("Timer takes (), (name), (isDaemon) or (name, isDaemon)")
        self._pool = _Pool(names[0] if names else f"Timer-{next(_sequence)}", 1)
        # A task that throws ends its timer, as it ends the Java timer thread.
        self._pool.failed = lambda error: self.cancel()

    def _schedule(self, task, delay, period, fixed_rate):
        if not isinstance(task, TimerTask):
            raise TypeError("Timer.schedule requires a TimerTask; a start Date is not supported")
        if _integer(delay, "delay") < 0 or period is not None and _integer(period, "period") <= 0:
            raise _illegal_argument("Negative delay or non-positive period")
        if task._future is not None or task._cancelled:
            raise _illegal_state("Task already scheduled or cancelled")

        def run():
            task._scheduled = int(time.time() * 1000)
            task.run()

        try:
            task._future = self._pool.submit(Future(run, None), delay=delay / 1000, detached=True,
                                             period=None if period is None else period / 1000, fixed_rate=fixed_rate)
        except RejectedExecutionException:
            raise _illegal_state("Timer already cancelled.") from None

    def schedule(self, task, delay, period=None):
        self._schedule(task, delay, period, False)

    def scheduleAtFixedRate(self, task, delay, period):
        self._schedule(task, delay, period, True)

    def cancel(self):
        self._pool.shutdown_now()

    def purge(self):
        with self._pool.condition:
            kept = [entry for entry in self._pool.delayed if not entry[2].isCancelled()]
            removed = len(self._pool.delayed) - len(kept)
            self._pool.delayed = kept
            heapq.heapify(kept)
            return removed


# ---- android.os: loopers and handlers -------------------------------------

class _Post:
    __slots__ = ("key", "registration")

    def __init__(self, key):
        self.key, self.registration = key, None


class _HostPosts:
    """Callbacks one plugin generation has pending on a host scheduler queue."""

    def __init__(self, queue):
        self.queue = queue

    def _pending(self):
        return _threads().state().storage.setdefault(("posts", self.queue), [])

    def post(self, key, function, delay):
        pending = self._pending()
        if len(pending) >= _threads().MAX_PENDING_TASKS:
            raise _bridge().BridgeError("RESOURCE_LIMIT", "Plugin pending callback limit reached")
        entry = _Post(key)

        def deliver():
            try:
                pending.remove(entry)
            except ValueError:
                return None  # removed while the host callback was already queued
            return function()

        # Listed before scheduling: a worker's post may be delivered before schedule returns to it.
        pending.append(entry)
        try:
            entry.registration = _bridge().runtime.schedule(deliver, queue=self.queue, delay=max(0, delay))
        except BaseException:
            try:
                pending.remove(entry)
            except ValueError:
                pass
            raise
        return True

    def remove(self, matches):
        pending = self._pending()
        removed = [entry for entry in list(pending) if matches(entry.key)]
        for entry in removed:
            try:
                pending.remove(entry)
            except ValueError:
                continue
            if entry.registration is not None:
                try:
                    entry.registration.cancel()
                except _bridge().BridgeError:
                    pass  # already delivered or revoked by the host
        return len(removed)

    def has(self, matches):
        return any(matches(entry.key) for entry in list(self._pending()))


class Message(_Java):
    def __init__(self):
        self.what = self.arg1 = self.arg2 = 0
        self.obj = self.replyTo = None
        self._target = self._callback = None

    @staticmethod
    def obtain(*arguments):
        """``()``, ``(Message)``, ``(Handler)``, ``(h, Runnable)``, ``(h, what[, obj])``, ``(h, what, arg1, arg2[, obj])``."""
        message = Message()
        if not arguments:
            return message
        first, rest = arguments[0], arguments[1:]
        if isinstance(first, Message):
            if rest:
                raise TypeError("Message.obtain(Message) takes one argument")
            message.copyFrom(first)
            message._target, message._callback = first._target, first._callback
            return message
        if first is not None and not isinstance(first, Handler):
            raise TypeError("Message.obtain expects a Handler")
        message._target = first
        if len(rest) == 1 and type(rest[0]) is not int:
            message._callback = rest[0]
            _task(rest[0])
        elif rest:
            if len(rest) not in (1, 2, 3, 4):
                raise TypeError("Unsupported Message.obtain overload")
            message.what = _integer(rest[0], "what")
            if len(rest) == 2:
                message.obj = rest[1]
            elif len(rest) >= 3:
                message.arg1, message.arg2 = _integer(rest[1], "arg1"), _integer(rest[2], "arg2")
                message.obj = rest[3] if len(rest) == 4 else None
        return message

    def copyFrom(self, other):
        self.what, self.arg1, self.arg2, self.obj, self.replyTo = other.what, other.arg1, other.arg2, other.obj, other.replyTo

    def getTarget(self):
        return self._target

    def setTarget(self, target):
        self._target = target

    def getCallback(self):
        return self._callback

    def sendToTarget(self):
        if self._target is None:
            raise _null("Message has no target")
        self._target.sendMessage(self)

    def recycle(self):
        self.__init__()


class Looper(_Java):
    """The main looper is the serial plugin queue; other loopers belong to worker threads."""
    __ayu_requires__ = SCHEDULER

    def __init__(self, *arguments):
        raise _unsupported("Looper has no public constructor; use Looper.prepare() or Looper.getMainLooper()")

    @classmethod
    def _new(cls, main=False):
        looper = object.__new__(cls)
        looper._main = main
        looper._thread = None
        looper._condition = threading.Condition()
        looper._heap = []
        looper._quitting = False
        looper._posts = _HostPosts("main") if main else None
        return looper

    @staticmethod
    def getMainLooper():
        global _MAIN_LOOPER
        if _MAIN_LOOPER is None:
            _MAIN_LOOPER = Looper._new(True)
        return _MAIN_LOOPER

    @staticmethod
    def myLooper():
        if _threads().on_queue():
            return Looper.getMainLooper()
        return getattr(threading.current_thread(), "_ayu_looper", None)

    @staticmethod
    def prepare():
        if Looper.myLooper() is not None:
            raise RuntimeError("Only one Looper may be created per thread")
        Looper._new()._bind()

    def _bind(self):
        if _threads().on_queue() or getattr(threading.current_thread(), "_ayu_looper", None) is not None:
            raise RuntimeError("Only one Looper may be created per thread")
        self._thread = threading.current_thread()
        self._thread._ayu_looper = self
        # Unload ends the loop; nothing else can wake a thread parked in it.
        _own(self.quit)

    @staticmethod
    def loop():
        looper = Looper.myLooper()
        if looper is None:
            raise RuntimeError("No Looper; Looper.prepare() wasn't called on this thread.")
        if looper._main:
            raise _unsupported("Looper.loop() would block the serial plugin queue; the host runs the main looper")
        try:
            while True:
                message = looper._next()
                if message is None:
                    return
                try:
                    message._target.dispatchMessage(message)
                except Exception as error:
                    # Android would crash the app here; the queue keeps serving its other messages.
                    _uncaught(error)
        finally:
            _disown(looper.quit)

    def _next(self):
        with self._condition:
            while True:
                if self._heap:
                    wait = self._heap[0][0] - time.monotonic()
                    if wait <= 0:
                        return heapq.heappop(self._heap)[2]
                    if self._quitting:
                        return None
                    self._condition.wait(wait)
                elif self._quitting:
                    return None
                else:
                    self._condition.wait()

    def _enqueue(self, message, delay, front):
        if self._main:
            if front:
                raise _unsupported("The main looper cannot reorder callbacks already handed to the host")
            target = message._target
            return self._posts.post(message, lambda: target.dispatchMessage(message), delay)
        with self._condition:
            if self._quitting:
                return False
            if len(self._heap) >= _threads().MAX_PENDING_TASKS:
                raise _bridge().BridgeError("RESOURCE_LIMIT", "Looper pending message limit reached")
            order = next(_sequence)
            due = (float("-inf"), -order) if front else (time.monotonic() + max(0, delay) / 1000, order)
            heapq.heappush(self._heap, due + (message,))
            self._condition.notify()
        return True

    def _remove(self, matches):
        if self._main:
            return self._posts.remove(matches)
        with self._condition:
            kept = [entry for entry in self._heap if not matches(entry[2])]
            removed = len(self._heap) - len(kept)
            self._heap = kept
            heapq.heapify(kept)
            return removed

    def _has(self, matches):
        if self._main:
            return self._posts.has(matches)
        with self._condition:
            return any(matches(entry[2]) for entry in self._heap)

    def _quit(self, safe):
        if self._main:
            raise _illegal_state("Main thread not allowed to quit.")
        with self._condition:
            self._quitting = True
            now = time.monotonic()
            # quitSafely still delivers what is already due.
            self._heap = [entry for entry in self._heap if safe and entry[0] <= now]
            heapq.heapify(self._heap)
            self._condition.notify_all()

    def quit(self):
        self._quit(False)

    def quitSafely(self):
        self._quit(True)

    def getThread(self):
        if self._main:
            ident = _threads().queue_ident()
            for thread in threading.enumerate():
                if thread.ident == ident:
                    return Thread._wrap(thread)
            raise _illegal_state("The plugin queue thread is not running")
        return None if self._thread is None else Thread._wrap(self._thread)

    def isCurrentThread(self):
        return _threads().on_queue() if self._main else self._thread is threading.current_thread()

    def toString(self):
        return "Looper (main)" if self._main else f"Looper ({getattr(self._thread, 'name', 'unbound')})"

    __str__ = __repr__ = toString


_MAIN_LOOPER = None


class Handler(_Java):
    __ayu_requires__ = SCHEDULER
    # The host adapter has no Looper constructor and cannot cancel callbacks.
    __ayu_overrides_host__ = True

    class Callback(_Java):
        def __init__(self, function=None):
            self._function = function

        def handleMessage(self, message):
            if self._function is None:
                raise NotImplementedError("Handler.Callback.handleMessage is abstract")
            return self._function(message)

    def __init__(self, *arguments):
        if len(arguments) > 2:
            raise _unsupported("Handler constructor overload is not implemented")
        looper = callback = None
        for value in arguments:
            if isinstance(value, Looper):
                looper = value
            elif value is not None:
                callback = _function(_local(value, "Looper or Handler.Callback"), "handleMessage")
        if looper is None:
            looper = Looper.myLooper()
            if looper is None:
                raise RuntimeError("Can't create handler inside thread " + threading.current_thread().name
                                   + " that has not called Looper.prepare()")
        self._looper, self._callback = looper, callback

    def getLooper(self):
        return self._looper

    def handleMessage(self, message):
        """Subclasses receive messages here."""

    def dispatchMessage(self, message):
        if message._callback is not None:
            _task(message._callback)()
            return
        if self._callback is not None and self._callback(message):
            return
        self.handleMessage(message)

    def _send(self, message, delay, front=False):
        if type(delay) not in (int, float):
            raise TypeError("delayMillis must be a number")
        message._target = self
        return self._looper._enqueue(message, delay, front)

    def post(self, runnable):
        return self._send(Message.obtain(self, runnable), 0)

    def postDelayed(self, runnable, *arguments):
        """``(runnable, delayMillis)`` or ``(runnable, token, delayMillis)``."""
        if len(arguments) not in (1, 2):
            raise TypeError("postDelayed takes (runnable, delayMillis) or (runnable, token, delayMillis)")
        message = Message.obtain(self, runnable)
        if len(arguments) == 2:
            message.obj = arguments[0]
        return self._send(message, arguments[-1])

    def postAtFrontOfQueue(self, runnable):
        return self._send(Message.obtain(self, runnable), 0, True)

    def removeCallbacks(self, runnable, token=None):
        self._looper._remove(lambda message: message._target is self and message._callback is not None
                             and message._callback == runnable and (token is None or message.obj is token))

    def hasCallbacks(self, runnable):
        return self._looper._has(lambda message: message._target is self and message._callback is not None
                                 and message._callback == runnable)

    def removeCallbacksAndMessages(self, token):
        self._looper._remove(lambda message: message._target is self and (token is None or message.obj is token))

    def obtainMessage(self, *arguments):
        return Message.obtain(self, *arguments)

    def sendMessage(self, message):
        return self._send(message, 0)

    def sendMessageDelayed(self, message, delayMillis):
        return self._send(message, delayMillis)

    def sendMessageAtFrontOfQueue(self, message):
        return self._send(message, 0, True)

    def sendEmptyMessage(self, what):
        return self._send(Message.obtain(self, what), 0)

    def sendEmptyMessageDelayed(self, what, delayMillis):
        return self._send(Message.obtain(self, what), delayMillis)

    def _plain(self, what, obj):
        return lambda message: (message._target is self and message._callback is None and message.what == what
                                and (obj is None or message.obj is obj))

    def removeMessages(self, what, obj=None):
        self._looper._remove(self._plain(what, obj))

    def hasMessages(self, what, obj=None):
        return self._looper._has(self._plain(what, obj))


class HandlerThread(Thread):
    def __init__(self, name, priority=0):
        if not isinstance(name, str):
            raise TypeError("HandlerThread requires a name")
        super().__init__(name)
        self._thread_priority = _integer(priority, "priority")
        self._looper = None
        self._ready = threading.Condition()

    def run(self):
        Looper.prepare()
        with self._ready:
            self._looper = Looper.myLooper()
            self._ready.notify_all()
        self.onLooperPrepared()
        Looper.loop()

    def onLooperPrepared(self):
        """Subclasses may prepare state before the loop starts."""

    def getLooper(self):
        with self._ready:
            while self._looper is None and self.isAlive():
                _await(self._ready, lambda: self._looper is not None, 0.05)
        return self._looper if self.isAlive() else None

    def quit(self):
        looper = self.getLooper()
        if looper is not None:
            looper.quit()
        return looper is not None

    def quitSafely(self):
        looper = self.getLooper()
        if looper is not None:
            looper.quitSafely()
        return looper is not None

    def getThreadId(self):
        return self._thread.native_id if self._thread.native_id is not None else -1


class DispatchQueue(Thread):
    """``org.telegram.messenger.DispatchQueue``: a thread that runs posted runnables in order."""
    _indexes = itertools.count()

    def __init__(self, threadName, start=True, priority=None):
        if not isinstance(threadName, str):
            raise TypeError("DispatchQueue requires a thread name")
        super().__init__(threadName)
        if priority is not None:
            _integer(priority, "priority")
        self.index = next(DispatchQueue._indexes)
        self._looper = Looper._new()
        self._queue_handler = Handler(self._looper, lambda message: (self.handleMessage(message), True)[1])
        if start:
            self.start()

    def run(self):
        self._looper._bind()
        self.onLooperPrepared()
        Looper.loop()

    def onLooperPrepared(self):
        """Subclasses may prepare state before the loop starts."""

    def handleMessage(self, message):
        """Subclasses receive messages sent with ``sendMessage``."""

    def postRunnable(self, runnable, delay=0):
        return self._queue_handler.post(runnable) if delay <= 0 else self._queue_handler.postDelayed(runnable, delay)

    def postToFrontRunnable(self, runnable):
        return self._queue_handler.postAtFrontOfQueue(runnable)

    def cancelRunnable(self, runnable):
        self._queue_handler.removeCallbacks(runnable)

    def cancelRunnables(self, runnables):
        for runnable in runnables:
            self._queue_handler.removeCallbacks(runnable)

    def cleanupQueue(self):
        self._queue_handler.removeCallbacksAndMessages(None)

    def sendMessage(self, message, delay):
        if delay <= 0:
            self._queue_handler.sendMessage(message)
        else:
            self._queue_handler.sendMessageDelayed(message, delay)

    def recycle(self):
        self._looper.quit()

    def isReady(self):
        return True

    def getHandler(self):
        return self._queue_handler


class _HostQueue(DispatchQueue):
    """One of the app's named queues: its runnables run on the serial plugin queue."""

    def __init__(self, name):
        self._name = name
        self._posts = _HostPosts(name)
        self.index = QUEUE_NAMES.index(name)

    def postRunnable(self, runnable, delay=0):
        if type(delay) not in (int, float):
            raise TypeError("delay must be a number")
        return self._posts.post(runnable, _task(runnable), delay)

    def cancelRunnable(self, runnable):
        self._posts.remove(lambda posted: posted == runnable)

    def cancelRunnables(self, runnables):
        for runnable in runnables:
            self.cancelRunnable(runnable)

    def cleanupQueue(self):
        """Removes only the calling plugin's pending runnables."""
        self._posts.remove(lambda posted: True)

    def getName(self):
        return self._name

    def isAlive(self):
        return True

    def toString(self):
        return f"DispatchQueue[{self._name}]"

    __str__ = __repr__ = toString

    def _host_owned(self, *arguments, **options):
        raise _unsupported(f"{self._name} is owned by the host and is not a plugin thread")

    start = run = join = interrupt = setName = setDaemon = setPriority = getStackTrace = _host_owned
    postToFrontRunnable = sendMessage = recycle = getHandler = setUncaughtExceptionHandler = _host_owned


_HOST_QUEUES = {}


def named_queue(name):
    """The ``Utilities.<name>`` queue object, e.g. for ``telegram_messenger.Utilities``."""
    if name not in QUEUE_NAMES:
        raise _unsupported(f"Unknown dispatch queue: {name}")
    queue = _HOST_QUEUES.get(name)
    if queue is None:
        queue = _HOST_QUEUES[name] = _HostQueue(name)
    return queue


class CountDownTimer(_Java):
    __ayu_requires__ = SCHEDULER

    def __init__(self, millisInFuture, countDownInterval):
        self._millis = _integer(millisInFuture, "millisInFuture")
        self._interval = _integer(countDownInterval, "countDownInterval")
        self._cancelled = False
        self._stop = 0.0
        self._handler = Handler()

    def onTick(self, millisUntilFinished):
        raise NotImplementedError("CountDownTimer.onTick is abstract")

    def onFinish(self):
        raise NotImplementedError("CountDownTimer.onFinish is abstract")

    def start(self):
        self._cancelled = False
        if self._millis <= 0:
            self.onFinish()
            return self
        self._stop = time.monotonic() + self._millis / 1000
        self._handler.post(self._step)
        return self

    def cancel(self):
        self._cancelled = True
        self._handler.removeCallbacks(self._step)

    def _step(self):
        if self._cancelled:
            return
        left = int((self._stop - time.monotonic()) * 1000)
        if left <= 0:
            self.onFinish()
            return
        started = time.monotonic()
        self.onTick(left)
        spent = int((time.monotonic() - started) * 1000)
        if left < self._interval:
            delay = max(0, left - spent)
        else:
            delay = self._interval - spent
            while delay < 0:
                delay += self._interval
        if not self._cancelled:
            self._handler.postDelayed(self._step, delay)


class _ScopedExecutor(Executor):
    """A static executor field: each plugin generation gets its own pool."""

    def __init__(self, key, threads):
        self._key, self._size = key, threads

    def _executor(self):
        storage = _threads().state().storage
        executor = storage.get(self._key)
        if executor is None:
            executor = storage[self._key] = ThreadPoolExecutor(self._size)
        return executor

    def execute(self, command):
        self._executor().execute(command)

    def submit(self, task, *result):
        return self._executor().submit(task, *result)


class AsyncTask(_Java):
    __ayu_requires__ = SCHEDULER
    SERIAL_EXECUTOR = _ScopedExecutor("asynctask.serial", 1)
    THREAD_POOL_EXECUTOR = _ScopedExecutor("asynctask.pool", 4)

    class Status(_Java):
        def __init__(self, name):
            self._name = name

        def name(self):
            return self._name

        def toString(self):
            return self._name

        __str__ = __repr__ = toString

    def __init__(self):
        self._status = AsyncTask.Status.PENDING
        self._cancelled = False
        self._future = None
        self._main = Handler(Looper.getMainLooper())

    def onPreExecute(self):
        pass

    def doInBackground(self, *params):
        raise NotImplementedError("AsyncTask.doInBackground is abstract")

    def onProgressUpdate(self, *values):
        pass

    def onPostExecute(self, result):
        pass

    def onCancelled(self, *result):
        pass

    def getStatus(self):
        return self._status

    def isCancelled(self):
        return self._cancelled

    def cancel(self, mayInterruptIfRunning=False):
        if self._cancelled or self._status is AsyncTask.Status.FINISHED:
            return False
        self._cancelled = True
        if self._future is not None:
            self._future.cancel(mayInterruptIfRunning)
        return True

    def publishProgress(self, *values):
        if not self._cancelled:
            self._main.post(lambda: self.onProgressUpdate(*values))

    def _finish(self, result):
        if self._cancelled:
            self.onCancelled(result)
        else:
            self.onPostExecute(result)
        self._status = AsyncTask.Status.FINISHED

    def executeOnExecutor(self, executor, *params):
        if self._status is not AsyncTask.Status.PENDING:
            raise _illegal_state("Cannot execute task: the task has already been executed or is running")
        self._status = AsyncTask.Status.RUNNING
        self.onPreExecute()

        def work():
            result = None
            try:
                if not self._cancelled:
                    result = self.doInBackground(*params)
                return result
            finally:
                self._main.post(lambda: self._finish(result))

        self._future = Future(work)
        executor.execute(self._future)
        return self

    def _execute(self, *params):
        return self.executeOnExecutor(AsyncTask.SERIAL_EXECUTOR, *params)

    @staticmethod
    def _execute_runnable(runnable):
        AsyncTask.SERIAL_EXECUTOR.execute(runnable)

    execute = _Overload(_execute_runnable.__func__, _execute)

    def get(self, *arguments):
        if self._future is None:
            raise _illegal_state("AsyncTask has not been executed")
        return self._future.get(*arguments)


AsyncTask.Status.PENDING = AsyncTask.Status("PENDING")
AsyncTask.Status.RUNNING = AsyncTask.Status("RUNNING")
AsyncTask.Status.FINISHED = AsyncTask.Status("FINISHED")


class Process(_Java):
    """Real identifiers of the app process; nothing here can signal or end it."""
    FIRST_APPLICATION_UID, LAST_APPLICATION_UID = 10000, 19999
    SIGNAL_QUIT, SIGNAL_KILL, SIGNAL_USR1 = 3, 9, 10
    THREAD_PRIORITY_DEFAULT = 0
    THREAD_PRIORITY_LOWEST = 19
    THREAD_PRIORITY_BACKGROUND = 10
    THREAD_PRIORITY_FOREGROUND = -2
    THREAD_PRIORITY_DISPLAY = -4
    THREAD_PRIORITY_URGENT_DISPLAY = -8
    THREAD_PRIORITY_VIDEO = -10
    THREAD_PRIORITY_AUDIO = -16
    THREAD_PRIORITY_URGENT_AUDIO = -19
    THREAD_PRIORITY_MORE_FAVORABLE = -1
    THREAD_PRIORITY_LESS_FAVORABLE = 1

    @staticmethod
    def myPid():
        return os.getpid()

    @staticmethod
    def myTid():
        return threading.get_native_id()

    @staticmethod
    def myUid():
        return os.getuid()

    @staticmethod
    def is64Bit():
        return sys.maxsize > 2**32

    @staticmethod
    def getElapsedCpuTime():
        return int(time.process_time() * 1000)

    @staticmethod
    def _find(tid):
        for thread in threading.enumerate():
            if thread.native_id == tid:
                return thread
        raise _illegal_argument(f"Given thread {tid} does not exist")

    @staticmethod
    def setThreadPriority(*arguments):
        """``(priority)`` for the calling thread or ``(tid, priority)``; a recorded hint only."""
        if len(arguments) not in (1, 2):
            raise TypeError("setThreadPriority takes (priority) or (tid, priority)")
        priority = _integer(arguments[-1], "priority")
        if not -20 <= priority <= 19:
            raise _illegal_argument("Thread priority out of range")
        thread = threading.current_thread() if len(arguments) == 1 else Process._find(arguments[0])
        thread._ayu_priority = priority

    @staticmethod
    def getThreadPriority(tid):
        return getattr(Process._find(tid), "_ayu_priority", Process.THREAD_PRIORITY_DEFAULT)

    @staticmethod
    def _fatal(*arguments, **options):
        raise _unsupported("A plugin cannot signal, kill or restart the app process on iOS")

    killProcess = sendSignal = killProcessQuiet = killProcessGroup = _fatal


CLASSES = {
    "java.lang.Runnable": Runnable,
    "java.lang.InterruptedException": InterruptedException,
    "java.lang.Thread": Thread,
    "java.lang.Thread$UncaughtExceptionHandler": Thread.UncaughtExceptionHandler,
    "java.lang.ThreadLocal": ThreadLocal,
    "java.util.Timer": Timer,
    "java.util.TimerTask": TimerTask,
    "java.util.concurrent.Callable": Callable,
    "java.util.concurrent.TimeUnit": TimeUnit,
    "java.util.concurrent.CountDownLatch": CountDownLatch,
    "java.util.concurrent.Semaphore": Semaphore,
    "java.util.concurrent.Future": Future,
    "java.util.concurrent.FutureTask": Future,
    "java.util.concurrent.ScheduledFuture": Future,
    "java.util.concurrent.Executor": Executor,
    "java.util.concurrent.ExecutorService": ExecutorService,
    "java.util.concurrent.ScheduledExecutorService": ScheduledExecutorService,
    "java.util.concurrent.ThreadPoolExecutor": ThreadPoolExecutor,
    "java.util.concurrent.ScheduledThreadPoolExecutor": ScheduledThreadPoolExecutor,
    "java.util.concurrent.Executors": Executors,
    "java.util.concurrent.ExecutionException": ExecutionException,
    "java.util.concurrent.TimeoutException": TimeoutException,
    "java.util.concurrent.CancellationException": CancellationException,
    "java.util.concurrent.RejectedExecutionException": RejectedExecutionException,
    "java.util.concurrent.ConcurrentHashMap": ConcurrentHashMap,
    "java.util.concurrent.CopyOnWriteArrayList": CopyOnWriteArrayList,
    "java.util.concurrent.ConcurrentLinkedQueue": ConcurrentLinkedQueue,
    "java.util.concurrent.BlockingQueue": LinkedBlockingQueue,
    "java.util.concurrent.LinkedBlockingQueue": LinkedBlockingQueue,
    "java.util.concurrent.ArrayBlockingQueue": ArrayBlockingQueue,
    "java.util.concurrent.atomic.AtomicInteger": AtomicInteger,
    "java.util.concurrent.atomic.AtomicLong": AtomicLong,
    "java.util.concurrent.atomic.AtomicBoolean": AtomicBoolean,
    "java.util.concurrent.atomic.AtomicReference": AtomicReference,
    "java.util.concurrent.locks.Lock": Lock,
    "java.util.concurrent.locks.ReentrantLock": ReentrantLock,
    "java.util.concurrent.locks.Condition": Condition,
    "android.os.Looper": Looper,
    "android.os.Handler": Handler,
    "android.os.Handler$Callback": Handler.Callback,
    "android.os.HandlerThread": HandlerThread,
    "android.os.Message": Message,
    "android.os.Process": Process,
    "android.os.CountDownTimer": CountDownTimer,
    "android.os.AsyncTask": AsyncTask,
    "android.os.AsyncTask$Status": AsyncTask.Status,
    "org.telegram.messenger.DispatchQueue": DispatchQueue,
}
