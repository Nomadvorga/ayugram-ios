"""Android's plugin lifecycle helpers on the native-owned generation scope.

A ``PluginScope`` is the Android view of one bridge load generation. Binding
captures that generation; it never schedules work, starts a thread, or grants a
caller another plugin's scope. A bound callback runs on whichever thread calls
it, exactly as on Android: a plugin worker thread may invoke it, and any bridge
call it makes there is marshalled to the queue by ``_ayu_threads``.
"""
import contextlib
import contextvars
import threading
import weakref

import _ayu_threads
from ayu_bridge import BridgeError, Scope, UnsupportedAPI, runtime

_ATTRIBUTE = "_ayu_lifecycle"
MAX_CLEANUPS = 1024
_cleanup_scope = contextvars.ContextVar("plugin_cleanup", default=None)
_cleanup_requests = contextvars.ContextVar("plugin_cleanup_requests", default=None)


def _report_error(error):
    # Android prints the traceback to stderr; the host log gets the type only.
    try:
        runtime.call("log.write", {"level": "error",
                                   "message": "Lifecycle callback failed: " + type(error).__name__})
    except Exception:
        pass


class PluginScope:
    """One plugin generation: its stop event, bound callbacks and cleanups."""

    def __init__(self, scope):
        if not isinstance(scope, Scope):
            raise TypeError("PluginScope wraps a native-owned plugin generation")
        self._scope = scope
        self.plugin_id = scope.plugin_id
        self._callbacks = weakref.WeakSet()
        self._cleanups = []
        self._lock = threading.RLock()

    @property
    def stop_event(self):
        return _ayu_threads.stop_event(self._scope)

    def _alive(self):
        """The generation can still reach the host (it is not deactivated)."""
        return (runtime.scopes.get(self.plugin_id) is self._scope
                and self._scope.state in ("loading", "active", "unloading"))

    def _stopped(self):
        return self.stop_event.is_set() or not self._alive() or self._scope.state == "unloading"

    def close(self):
        """Stop the generation's bound work and run its registered cleanups."""
        with self._lock:
            self.stop_event.set()
            callbacks = [callback for callback in self._callbacks if callback not in self._cleanups]
            cleanups, self._cleanups = self._cleanups[::-1], []
            self._callbacks.clear()
        for callback in callbacks + cleanups:
            callback.cancel()

    def register_cleanup(self, cleanup):
        if not callable(cleanup):
            raise TypeError("Cleanup must be callable")
        callback = ManagedCallback(None, self)
        with self._lock:
            if not self.stop_event.is_set():
                if len(self._cleanups) >= MAX_CLEANUPS:
                    raise BridgeError("RESOURCE_LIMIT", "Plugin cleanup limit reached")
                self._cleanups.append(callback)

        def run_cleanup():
            with cleanup_context(self):
                cleanup()

        callback.set_cancel(run_cleanup)
        return callback


def _plugin_scope(scope):
    if isinstance(scope, PluginScope):
        return scope
    if not isinstance(scope, Scope):
        raise TypeError("Expected a plugin lifecycle scope")
    existing = getattr(scope, _ATTRIBUTE, None)
    if existing is None:
        existing = PluginScope(scope)
        setattr(scope, _ATTRIBUTE, existing)
    return existing


def capture_scope(fn=None):
    """The lifecycle scope of the calling plugin generation."""
    return _plugin_scope(runtime.require())


class ManagedCallback:
    def __init__(self, fn, scope=None, once=False, allow_stopped=False, cleanup_task=False):
        if fn is not None and not callable(fn):
            raise TypeError("ManagedCallback requires a callable")
        self.scope = capture_scope(fn) if scope is None else _plugin_scope(scope)
        if self.scope._alive():
            runtime.require(self.scope._scope)
        self._fn = fn
        self._cleanup_task = cleanup_task
        self._allow_stopped = allow_stopped
        self._once = once or allow_stopped
        self._cancel = None
        self._finished = False
        self._cancelled = False
        self._lock = threading.RLock()
        if not allow_stopped:
            with self.scope._lock:
                if self.scope._stopped():
                    self._fn = None
                    self._cancelled = True
                else:
                    self.scope._callbacks.add(self)

    def _unavailable(self):
        if self._allow_stopped:
            return not self.scope._alive()
        return self.scope._stopped()

    @property
    def cancelled(self):
        with self._lock:
            return self._cancelled or self._unavailable()

    @staticmethod
    def _run_cancel(cancel):
        # Android reports and swallows a failing cancel action so the rest still run.
        try:
            cancel()
        except Exception as error:
            _report_error(error)

    def set_cancel(self, cancel):
        if not callable(cancel):
            raise TypeError("cancel must be callable")
        with self._lock:
            cancelled = self._cancelled
            if not cancelled and not self._finished:
                self._cancel = cancel
        if cancelled:
            self._run_cancel(cancel)

    def _detach(self):
        with self.scope._lock:
            self.scope._callbacks.discard(self)
            if self in self.scope._cleanups:
                self.scope._cleanups.remove(self)

    def cancel(self):
        with self._lock:
            self._cancelled = True
            self._fn = None
            cancel, self._cancel = self._cancel, None
        self._detach()
        if cancel is not None:
            self._run_cancel(cancel)

    def __call__(self, *args, **kwargs):
        if self.cancelled or self._finished:
            return None
        # A callback never runs under another plugin's authority.
        runtime.require(self.scope._scope)
        with self._lock:
            if self._cancelled or self._finished:
                return None
            fn = self._fn
            if self._once:
                self._finished = True
                self._fn = None
                self._cancel = None
        if self._once:
            self._detach()
        if fn is None:
            return None
        cleanup_token = _cleanup_scope.set(None)
        request_token = _cleanup_requests.set(self.scope if self._cleanup_task else None)
        try:
            return fn(*args, **kwargs)
        finally:
            _cleanup_requests.reset(request_token)
            _cleanup_scope.reset(cleanup_token)


def bind(fn, *, once=False):
    return ManagedCallback(fn, capture_scope(fn), once)


def bind_task(fn, *, once=False, scope=None):
    scope = capture_scope(fn) if scope is None else _plugin_scope(scope)
    allow_stopped = _cleanup_scope.get() is scope
    return ManagedCallback(fn, scope, once, allow_stopped=allow_stopped, cleanup_task=allow_stopped)


def bind_request(fn):
    scope = capture_scope(fn)
    allow_stopped = _cleanup_requests.get() is scope
    return ManagedCallback(fn, scope, once=True, allow_stopped=allow_stopped)


@contextlib.contextmanager
def cleanup_context(scope):
    """Run unload code: tasks and requests bound inside may still complete."""
    scope = _plugin_scope(scope)
    runtime.require(scope._scope)
    cleanup_token = _cleanup_scope.set(scope)
    request_token = _cleanup_requests.set(scope)
    try:
        yield
    finally:
        _cleanup_requests.reset(request_token)
        _cleanup_scope.reset(cleanup_token)


@contextlib.contextmanager
def plugin_context(plugin_id):
    """Android enters a plugin's scope here; a plugin may only name itself."""
    if runtime.require().plugin_id != plugin_id:
        raise BridgeError("OWNERSHIP", "A plugin cannot enter another plugin's lifecycle")
    yield


def stop(plugin_id):
    """Close the calling plugin's own lifecycle scope."""
    scope = runtime.require()
    if scope.plugin_id != plugin_id:
        raise BridgeError("OWNERSHIP", "A plugin cannot stop another plugin's lifecycle")
    _plugin_scope(scope).close()


def _host_lifecycle_only(*args, **kwargs):
    raise UnsupportedAPI("Plugin lifecycle transitions are owned by the native runtime; use BasePlugin lifecycle methods")


begin = stop_all = _host_lifecycle_only
on_plugin_load = on_plugin_unload = _host_lifecycle_only
