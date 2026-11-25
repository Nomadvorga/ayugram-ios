"""Callback binding on the existing native-owned Python lifecycle.

Binding captures the current generation; it never schedules work, starts a
thread, or grants a caller another plugin's scope. The host owns begin/stop.
"""
from ayu_bridge import BridgeError, UnsupportedAPI, runtime


def capture_scope(fn=None):
    return runtime.require()


class ManagedCallback:
    def __init__(self, fn, scope=None, once=False, allow_stopped=False, cleanup_task=False):
        if not callable(fn):
            raise TypeError("ManagedCallback requires a callable")
        self.scope = runtime.require(scope)
        if self.scope.state == "unloading":
            raise BridgeError("PLUGIN_UNLOADING", "Cannot bind callbacks during unload")
        if allow_stopped or cleanup_task:
            raise UnsupportedAPI("Callbacks after lifecycle revocation are unsupported")
        self._once = bool(once)
        self._cancel = None
        self._finished = False
        self._cancelled = False
        self._reference = runtime.callback(fn, once=once)

    @property
    def cancelled(self):
        return self._cancelled or (not self._finished and (
            runtime.scopes.get(self.scope.plugin_id) is not self.scope or
            self.scope.state not in ("loading", "active") or
            self._reference.callback_id not in self.scope.callbacks))

    def set_cancel(self, cancel):
        runtime.require(self.scope)
        if not callable(cancel):
            raise TypeError("cancel must be callable")
        if self.cancelled:
            cancel()
        elif not self._finished:
            self._cancel = cancel

    def cancel(self):
        runtime.require(self.scope)
        self._cancelled = True
        self.scope.callbacks.pop(self._reference.callback_id, None)
        cancel, self._cancel = self._cancel, None
        if cancel is not None:
            cancel()

    def __call__(self, *args, **kwargs):
        runtime.check_queue()
        if self.cancelled or self._finished:
            return None
        runtime.require(self.scope)
        fn, _ = self.scope.callbacks[self._reference.callback_id]
        if self._once:
            self._finished = True
            self._cancel = None
            self.scope.callbacks.pop(self._reference.callback_id, None)
        return fn(*args, **kwargs)


def bind(fn, *, once=False):
    return ManagedCallback(fn, capture_scope(fn), once)


def bind_task(fn, *, once=False, scope=None):
    return ManagedCallback(fn, scope or capture_scope(fn), once)


def bind_request(fn):
    return bind(fn, once=True)


def _host_lifecycle_only(*args, **kwargs):
    raise UnsupportedAPI("Plugin lifecycle transitions are owned by the native runtime; use BasePlugin lifecycle methods")


begin = stop = stop_all = plugin_context = cleanup_context = _host_lifecycle_only
on_plugin_load = on_plugin_unload = _host_lifecycle_only
