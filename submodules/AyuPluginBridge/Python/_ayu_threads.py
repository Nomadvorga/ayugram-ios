"""Plugin worker threads on top of the single native-owned Python queue.

``_ayu_host.dispatch`` only works on the interpreter's dedicated thread, inside
a native entry whose trusted owner is the calling plugin. A thread started by
plugin code therefore never talks to the host itself: ``Runtime`` hands the
operation to ``marshal``, the queue thread executes it during an entry of that
plugin, and the worker waits for the result. A worker asks the native queue
for such an entry with ``_ayu_host.wake``; where that is unavailable or the
queue is full, an idle queue is re-entered through a generation-owned
``scheduler.schedule`` pump. A queue thread that
blocks on a thread, condition or lock created by plugin code keeps servicing
that plugin's workers, so it cannot deadlock against a worker that is calling
the bridge.

Python cannot stop a thread. Unload sets the generation's stop event and fails
every pending and later bridge call of its threads; a thread that ignores both
runs until its function returns and keeps counting against ``MAX_THREADS``.
Worker threads are outside the cooperative execution budget of the queue.
"""
from __future__ import annotations

import _thread
import collections
import contextvars
import sys
import threading
import time
import weakref

MAX_THREADS_PER_PLUGIN = 64
MAX_THREADS = 256
MAX_PENDING_TASKS = 1024
CALL_TIMEOUT = 30.0
LOG_TIMEOUT = 2.0
PUMP_MIN_MS = 10
PUMP_MAX_MS = 2000
# The pump interval follows the time since a worker last needed the queue.
PUMP_IDLE_RATIO = 0.1
PUMP_GRACE = 2.0
DRAIN_CPU_SECONDS = 0.05
LINGER_SECONDS = 0.003
LINGER_TOTAL_SECONDS = 0.03
WAIT_SLICE_MIN = 0.0005
WAIT_SLICE_MAX = 0.01
MAX_DRAIN_DEPTH = 8
REQUIRED_OPERATIONS = ("scheduler.schedule", "scheduler.cancel")
THREAD_IMPORTS = frozenset({"threading", "concurrent"})
_STATE = "_ayu_thread_state"
_MARK = "_ayu_threads_original"

_registry_lock = _thread.allocate_lock()
_workers = {}
_starting = 0
_originals = {}
_raw_lock_types = (type(_thread.allocate_lock()),)


class _State:
    """Threads, pending bridge calls and the pump of one plugin generation."""

    def __init__(self, scope):
        self.scope = scope
        self.lock = _thread.allocate_lock()
        self.threads = {}
        self.starting = 0
        self.requests = collections.deque()
        # Held while no request has arrived since the queue last looked.
        self.signal = _thread.allocate_lock()
        self.signal.acquire()
        self.stop = None
        self.stopping = False
        self.closed = False
        self.pump = None
        self.pump_due = 0.0
        self.fired = False
        self.arming = False
        self.activity = time.monotonic()
        self.draining = 0
        self.closers = []
        self.pools = weakref.WeakSet()
        self.storage = {}
        self.uncaught = None
        self.failures = 0
        self.last_failure = None

    def live(self):
        return bool(self.threads or self.starting or self.requests)


class _Request:
    __slots__ = ("function", "args", "kwargs", "result", "error", "done", "started")

    def __init__(self, function, args, kwargs):
        self.function, self.args, self.kwargs = function, args, kwargs
        self.result = self.error = None
        self.started = False
        self.done = _thread.allocate_lock()
        self.done.acquire()


def _bridge():
    return sys.modules.get("ayu_bridge")


def _scope():
    variable = getattr(sys.modules.get("ayu_bridge"), "_current", None)
    return None if variable is None else variable.get()


def _state(scope, create=False):
    state = getattr(scope, _STATE, None)
    if state is None and create:
        with _registry_lock:
            state = getattr(scope, _STATE, None)
            if state is None:
                state = _State(scope)
                setattr(scope, _STATE, state)
    return state


def _unloaded():
    return _bridge().BridgeError("PLUGIN_UNLOADED", "Plugin generation is no longer active")


def _limit(message):
    return _bridge().BridgeError("RESOURCE_LIMIT", message)


# ---- runtime entry points -------------------------------------------------

def is_worker():
    """True on a thread a plugin started through ``threading``."""
    return threading.get_ident() in _workers


def admit(scope):
    """Whether the calling thread is a live worker of exactly this generation."""
    state = _workers.get(threading.get_ident())
    if state is None or scope is None or state.scope is not scope:
        return False
    if state.closed:
        raise _unloaded()
    return True


def off_queue(runtime):
    return runtime.thread_id is not None and threading.get_ident() != runtime.thread_id


def on_queue():
    """True on the serial Python queue thread, the model's main looper."""
    bridge = _bridge()
    return bridge is not None and bridge.runtime.thread_id == threading.get_ident()


def queue_ident():
    bridge = _bridge()
    return None if bridge is None else bridge.runtime.thread_id


def unavailable_imports(imports, operations):
    """Thread imports the declared host cannot serve, in source order."""
    if all(operation in operations for operation in REQUIRED_OPERATIONS):
        return []
    return [name for name in imports if name.split(".")[0] in THREAD_IMPORTS]


def state():
    """Thread state of the calling plugin generation, for provider classes."""
    return _state(_bridge().runtime.require(), create=True)


def stop_event(scope=None):
    """Android's ``BasePlugin.stop_event``: set when the generation starts unloading.

    A thread that outlives its generation may still read the event of the scope it holds.
    """
    current = _state(scope if scope is not None else _bridge().runtime.require(), create=True)
    with current.lock:
        if current.stop is None:
            current.stop = threading.Event()
            if current.stopping or current.closed:
                current.stop.set()
        return current.stop


def add_closer(function):
    """Run ``function`` on the queue when the calling generation is torn down."""
    current = state()
    with current.lock:
        if current.closed:
            raise _unloaded()
        if len(current.closers) >= MAX_PENDING_TASKS:
            raise _limit("Plugin thread resource limit reached")
        current.closers.append(function)


def remove_closer(function):
    current = _state(_scope())
    if current is not None:
        with current.lock:
            try:
                current.closers.remove(function)
            except ValueError:
                pass


def signal_stop(scope):
    """Unload has begun: release every loop that waits on the stop event."""
    current = _state(scope, create=True)
    current.stopping = True
    if current.stop is not None:
        current.stop.set()


def close(scope):
    """The generation is gone: fail its workers' bridge calls and drop its pools."""
    current = _state(scope)
    if current is None:
        return
    with current.lock:
        current.closed = current.stopping = True
        requests = list(current.requests)
        current.requests.clear()
        closers, current.closers = current.closers[::-1], []
    current.pump = None
    if current.stop is not None:
        current.stop.set()
    for request in requests:
        request.error = _unloaded()
        request.done.release()
    for pool in list(current.pools):
        closers.append(lambda pool=pool: pool.shutdown(wait=False, cancel_futures=True))
    for closer in closers:
        try:
            closer()
        except Exception:
            pass
    current.storage.clear()
    current.uncaught = None


def marshal(runtime, function, *args, **kwargs):
    """Run a bridge operation of a worker thread on the queue and wait for it."""
    return _marshal(runtime, CALL_TIMEOUT, function, args, kwargs)


def _marshal(runtime, timeout, function, args, kwargs):
    scope = runtime.require()
    if not off_queue(runtime):
        return function(*args, **kwargs)
    current = _state(scope, create=True)
    request = _Request(function, args, kwargs)
    with current.lock:
        if current.closed:
            raise _unloaded()
        current.requests.append(request)
    try:
        current.signal.release()
    except RuntimeError:
        pass
    if not current.draining:
        _wake(current)
    if not request.done.acquire(True, timeout):
        with current.lock:
            if not request.started:
                try:
                    current.requests.remove(request)
                except ValueError:
                    pass
                raise _bridge().BridgeError(
                    "QUEUE_TIMEOUT", "The Python serial queue did not service this worker thread in time")
        request.done.acquire()
    if request.error is not None:
        raise request.error
    return request.result


def _wake(current):
    """Ask the native queue for an entry of this plugin now; the pump stays as the fallback.

    ``_ayu_host.wake`` may be called on any thread. It is absent on a host without it and
    returns ``False`` when the native queue is full.
    """
    wake = getattr(sys.modules.get("_ayu_host"), "wake", None)
    if wake is None:
        return False
    try:
        return bool(wake(current.scope.plugin_id))
    except Exception:
        return False


def serve(scope):
    """The native wake entry of ``scope``: drain as the pump callback does."""
    current = getattr(scope, _STATE, None)
    if current is None or current.closed:
        return False
    try:
        if _drain(current, DRAIN_CPU_SECONDS, True):
            current.activity = time.monotonic()
        _ensure_pump(current)
    except Exception:
        pass
    return True


def service(runtime, scope):
    """A native entry of ``scope`` began on the queue: serve its waiting workers."""
    current = getattr(scope, _STATE, None)
    if current is None or current.closed or current.draining:
        return
    pump = current.pump
    if pump is not None and pump.closed and not current.fired:
        # This entry delivers the pump callback, which drains and re-arms itself.
        current.fired = True
        return
    try:
        if current.requests and _drain(current, DRAIN_CPU_SECONDS, False):
            current.activity = time.monotonic()
        _ensure_pump(current)
    except Exception:
        pass


# ---- queue side -----------------------------------------------------------

def _drain(current, cpu_limit, linger):
    """Execute pending worker requests of ``current`` on the queue thread."""
    if current.draining >= MAX_DRAIN_DEPTH:
        return 0
    runtime = _bridge().runtime
    started_cpu, started = time.thread_time(), time.monotonic()
    served = 0
    current.draining += 1
    try:
        while not current.closed:
            with current.lock:
                request = current.requests.popleft() if current.requests else None
                if request is not None:
                    request.started = True
            if request is None:
                if not (linger and served) or time.monotonic() - started >= LINGER_TOTAL_SECONDS:
                    break
                # A worker that just got its answer usually asks again at once.
                if not current.signal.acquire(True, LINGER_SECONDS) and not current.requests:
                    break
                continue
            try:
                with runtime.context(current.scope):
                    request.result = request.function(*request.args, **request.kwargs)
            except BaseException as error:
                request.error = error
            finally:
                request.done.release()
            served += 1
            if cpu_limit is not None and time.thread_time() - started_cpu >= cpu_limit:
                break
    finally:
        current.draining -= 1
    return served


def _pump_delay(current, now):
    if current.requests:
        return 1
    return int(min(PUMP_MAX_MS, max(PUMP_MIN_MS, (now - current.activity) * PUMP_IDLE_RATIO * 1000)))


def _ensure_pump(current):
    """Keep one scheduled queue re-entry alive while the generation has threads."""
    bridge = _bridge()
    runtime, scope = bridge.runtime, current.scope
    if (current.arming or current.closed or scope.state not in ("loading", "active")
            or bridge._current.get() is not scope or not on_queue()):
        return
    operations = (runtime.capabilities or {}).get("operations", ())
    if not all(operation in operations for operation in REQUIRED_OPERATIONS):
        return
    now = time.monotonic()
    pump = current.pump
    if pump is not None and pump.closed:
        pump = current.pump = None
    if not current.live():
        return
    delay = _pump_delay(current, now)
    if pump is not None:
        if now <= current.pump_due + PUMP_GRACE and current.pump_due - now <= delay / 1000 + WAIT_SLICE_MAX:
            return
        # Too far away for the current activity, or never delivered by a full host queue.
        current.pump = None
        try:
            pump.cancel()
        except Exception:
            pump._forget()
    current.arming = True
    try:
        current.fired = False
        current.pump = runtime.schedule(lambda: _pump(current), queue="pluginsQueue", delay=delay)
        current.pump_due = now + delay / 1000
    except Exception:
        current.pump = None
    finally:
        current.arming = False


def _pump(current):
    current.pump, current.fired = None, False
    try:
        if _drain(current, DRAIN_CPU_SECONDS, True):
            current.activity = time.monotonic()
        _ensure_pump(current)
    except Exception:
        pass


def _kick(current):
    """Queue-thread plugin code woke or created a worker: poll soon."""
    current.activity = time.monotonic()
    try:
        _ensure_pump(current)
    except Exception:
        pass


def _pumpable():
    """State of the plugin running on the queue thread while it has workers."""
    bridge = sys.modules.get("ayu_bridge")
    if bridge is None or bridge.runtime.thread_id != threading.get_ident():
        return None
    current = getattr(bridge._current.get(), _STATE, None)
    if current is None or current.closed or not current.live():
        return None
    return current


def _pumped(current, attempt, timeout):
    """Block the queue thread on ``attempt(seconds)`` while serving ``current``."""
    deadline = None if timeout is None else time.monotonic() + timeout
    pause = WAIT_SLICE_MIN
    while True:
        step = pause
        if deadline is not None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return attempt(0)
            step = min(pause, remaining)
        if attempt(step):
            return True
        pause = WAIT_SLICE_MIN if _drain(current, None, True) else min(pause * 2, WAIT_SLICE_MAX)


# ---- threading hooks ------------------------------------------------------

def _start(thread):
    scope = _scope()
    started = getattr(thread, "_started", None)
    if scope is None or started is None or started.is_set():
        return _originals["start"](thread)
    global _starting
    bridge = _bridge()
    bridge.runtime.require()
    _patch_pools()
    current = _state(scope, create=True)
    with _registry_lock:
        with current.lock:
            if current.closed:
                raise _unloaded()
            if (len(current.threads) + current.starting >= MAX_THREADS_PER_PLUGIN
                    or len(_workers) + _starting >= MAX_THREADS):
                raise _limit("Plugin thread limit reached")
            current.starting += 1
        _starting += 1
    run = thread.run
    # Android threads start without the caller's context variables; only the
    # plugin generation is inherited.
    context = contextvars.Context()
    context.run(bridge._current.set, scope)
    entered = []

    def bootstrap():
        global _starting
        ident = threading.get_ident()
        entered.append(ident)
        with _registry_lock:
            _starting -= 1
            _workers[ident] = current
            with current.lock:
                current.starting -= 1
                current.threads[ident] = thread
        try:
            context.run(_guarded, current, thread, run)
        finally:
            with _registry_lock:
                _workers.pop(ident, None)
                with current.lock:
                    current.threads.pop(ident, None)
            thread.__dict__.pop("run", None)

    thread.run = bootstrap
    try:
        _originals["start"](thread)
    except BaseException:
        if not entered:
            with _registry_lock:
                _starting -= 1
                with current.lock:
                    current.starting -= 1
            thread.__dict__.pop("run", None)
        raise
    if on_queue():
        _kick(current)


def _guarded(current, thread, run):
    try:
        run()
    except SystemExit:
        pass
    except BaseException as error:
        handler = getattr(thread, "_ayu_uncaught", None) or current.uncaught
        if handler is not None and not current.closed:
            try:
                handler(thread, error)
            except BaseException:
                pass
        elif threading.excepthook is not getattr(threading, "__excepthook__", threading.excepthook):
            raise
        report_failure(error, thread.name)


def report_failure(error, name=None):
    """Record a failure of plugin thread code without printing plugin data."""
    current = _workers.get(threading.get_ident()) or _state(_scope())
    if current is None:
        return
    current.failures += 1
    current.last_failure = type(error).__name__
    bridge = _bridge()
    try:
        if not current.closed and "log.write" in bridge.runtime.capabilities["operations"]:
            name = threading.current_thread().name if name is None else name
            message = f"Uncaught {type(error).__name__} in plugin thread {name}"[:512]
            _marshal(bridge.runtime, LOG_TIMEOUT, bridge.runtime.call,
                     ("log.write", {"level": "error", "message": message}), {})
    except BaseException:
        pass


def _join(thread, timeout=None):
    current = _pumpable()
    if current is None or timeout is not None and not timeout > 0:
        return _originals["join"](thread, timeout)
    _originals["join"](thread, 0)

    def attempt(seconds):
        if thread.is_alive() and seconds > 0:
            _originals["join"](thread, seconds)
        return not thread.is_alive()

    _pumped(current, attempt, timeout)


def _wait(condition, timeout=None):
    current = _pumpable()
    if current is None or timeout is not None and not timeout > 0:
        return _originals["wait"](condition, timeout)
    if not condition._is_owned():
        raise RuntimeError("cannot wait on un-acquired lock")
    waiter = _thread.allocate_lock()
    waiter.acquire()
    condition._waiters.append(waiter)
    saved = condition._release_save()
    acquired = False
    try:
        acquired = _pumped(current, lambda seconds: waiter.acquire(True, seconds), timeout)
        return acquired
    finally:
        condition._acquire_restore(saved)
        if not acquired:
            try:
                condition._waiters.remove(waiter)
            except ValueError:
                pass


def _notify(condition, n=1):
    waiting = bool(condition._waiters)
    _originals["notify"](condition, n)
    if waiting:
        current = _pumpable()
        if current is not None and not current.draining:
            _kick(current)


class _PluginLock:
    """A lock made by plugin code; the queue thread serves workers while it waits."""

    def __init__(self, lock):
        self._lock = lock

    def acquire(self, blocking=True, timeout=-1):
        lock = self._lock
        if lock.acquire(False):
            return True
        if not blocking or timeout == 0:
            return lock.acquire(blocking, timeout)
        current = _pumpable()
        if current is None or timeout != -1 and not timeout > 0:
            return lock.acquire(blocking, timeout)
        return _pumped(current, lambda seconds: lock.acquire(True, seconds), None if timeout == -1 else timeout)

    def release(self):
        self._lock.release()

    def locked(self):
        return self._lock.locked()

    def __enter__(self):
        return self.acquire()

    def __exit__(self, *exception):
        self._lock.release()

    def __getattr__(self, name):
        return getattr(self._lock, name)

    def __repr__(self):
        return repr(self._lock)


class _PluginRLock(_PluginLock):
    def _is_owned(self):
        return self._lock._is_owned()

    def _release_save(self):
        return self._lock._release_save()

    def _acquire_restore(self, saved):
        self.acquire()
        for _ in range(saved[0] - 1):
            self._lock.acquire()


class _LockType(type):
    def __instancecheck__(cls, instance):
        return isinstance(instance, _raw_lock_types + (_PluginLock,))


class Lock(metaclass=_LockType):
    """``threading.Lock``: a plain lock outside plugin code."""

    def __new__(cls, *args, **kwargs):
        lock = _thread.allocate_lock(*args, **kwargs)
        if _scope() is None:
            return lock
        _patch_pools()
        return _PluginLock(lock)


def RLock(*args, **kwargs):
    lock = _originals["RLock"](*args, **kwargs)
    return lock if _scope() is None or not hasattr(lock, "_release_save") else _PluginRLock(lock)


def _submit(pool, fn, /, *args, **kwargs):
    scope = _scope()
    if scope is None:
        return _originals["submit"](pool, fn, *args, **kwargs)
    _bridge().runtime.require()
    current = _state(scope, create=True)
    if current.closed:
        raise _unloaded()
    pending = getattr(pool, "_work_queue", None)
    if pending is not None and pending.qsize() >= MAX_PENDING_TASKS:
        raise _limit("Plugin executor pending work limit reached")
    current.pools.add(pool)
    future = _originals["submit"](pool, fn, *args, **kwargs)
    if on_queue() and not current.draining:
        _kick(current)
    return future


def _patch_pools():
    """Bound and track ``ThreadPoolExecutor`` once plugin code has imported it."""
    if "submit" in _originals:
        return
    module = sys.modules.get("concurrent.futures.thread")
    pool = getattr(module, "ThreadPoolExecutor", None)
    if pool is None or "submit" not in vars(pool):
        return
    if getattr(pool.submit, _MARK, None) is not None:
        _originals["submit"] = getattr(pool.submit, _MARK)
        return
    _originals["submit"] = pool.submit
    setattr(_submit, _MARK, pool.submit)
    pool.submit = _submit


def install():
    """Hook ``threading`` once. Every hook is inert outside plugin code."""
    if _originals:
        return
    thread, condition = threading.Thread, threading.Condition
    previous = getattr(thread.start, _MARK, None)
    if previous is not None:
        # Another copy of this module is already installed; it serves this interpreter.
        _originals.update(previous)
        return
    _originals.update(start=thread.start, join=thread.join, RLock=threading.RLock, Lock=threading.Lock)
    setattr(_start, _MARK, _originals)
    thread.start = _start
    thread.join = _join
    if all(hasattr(condition, name) for name in ("_is_owned", "_release_save", "_acquire_restore")):
        _originals.update(wait=condition.wait, notify=condition.notify)
        condition.wait = _wait
        condition.notify = _notify
    threading.Lock = Lock
    threading.RLock = RLock
    _patch_pools()
