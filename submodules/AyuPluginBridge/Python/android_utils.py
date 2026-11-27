"""Android utility helpers over the host's declared listener proxies."""
from ayu_bridge import runtime
from client_utils import get_last_fragment

_LEGACY_LOG_CHUNK_BYTES = 3800


def log(data):
    from log_utils import dump, _split_for_logcat
    text = str(data) if data is None or isinstance(data, (str, int, float, bool)) else dump(data)
    for chunk in _split_for_logcat(text, _LEGACY_LOG_CHUNK_BYTES):
        runtime.call("log.write", {"level": "info", "message": chunk})


def get_context():
    """Return the host-owned context descriptor for the visible surface.

    This is not an Android Application/Activity copy. It is the same bounded
    context adapter already exposed through ``get_last_fragment()``; callers
    still get ``UNSUPPORTED_API`` for members the host does not implement.
    """
    fragment = get_last_fragment()
    return fragment.getContext() if fragment is not None else None


def _log_failure(where, error):
    # Android logs the traceback; plugin exception text stays out of the host log.
    try:
        log(f"Error in {where} listener: {type(error).__name__}")
    except Exception:
        pass


def _listener(interface, methods):
    """A listener object over one declared host proxy interface.

    ``jclass`` raises ``UNSUPPORTED_API`` while the host does not declare the
    interface, so an undeclared listener can never be handed to a view.
    """
    from java import dynamic_proxy, jclass
    return type("Listener", (dynamic_proxy(jclass(interface)),), dict(methods))()


def _bound(fn, name):
    if not callable(fn):
        raise TypeError(name + " requires a callback")
    from extera_utils.lifecycle import bind
    return bind(fn)


def OnClickListener(fn):
    callback = _bound(fn, "OnClickListener")

    def onClick(self, _view):
        from ayu_bridge import BridgeError
        try:
            callback(_view)
        except BridgeError:
            raise
        except Exception as error:
            _log_failure("onClick", error)

    return _listener("android.view.View$OnClickListener", {"onClick": onClick})


def OnLongClickListener(fn):
    callback = _bound(fn, "OnLongClickListener")

    def onLongClick(self, _view):
        from ayu_bridge import BridgeError
        try:
            result = callback(_view)
            return True if result is None else bool(result)
        except BridgeError:
            raise
        except Exception as error:
            _log_failure("onLongClick", error)
            return False

    return _listener("android.view.View$OnLongClickListener", {"onLongClick": onLongClick})


def OnTouchListener(fn):
    """``View.OnTouchListener`` whose callback receives ``(view, event)``."""
    callback = _bound(fn, "OnTouchListener")

    def onTouch(self, view, event):
        from ayu_bridge import BridgeError
        try:
            return bool(callback(view, event))
        except BridgeError:
            raise
        except Exception as error:
            _log_failure("onTouch", error)
            return False

    return _listener("android.view.View$OnTouchListener", {"onTouch": onTouch})


def R(fn):
    """A generation-owned ``java.lang.Runnable`` that runs ``fn``."""
    if not callable(fn):
        raise TypeError("fn must be callable")
    from extera_utils.lifecycle import ManagedCallback, bind_task
    callback = fn if isinstance(fn, ManagedCallback) else bind_task(fn)

    def run(self):
        callback()

    return _listener("java.lang.Runnable", {"run": run})


def run_on_ui_thread(func, delay=0):
    from client_utils import run_on_ui_thread as schedule
    return schedule(func, delay=delay)


def copy_to_clipboard(text):
    """Copy bounded text through the app-owned clipboard and screen adapter."""
    runtime.require()
    if not isinstance(text, str):
        raise TypeError("Clipboard text must be a string")
    if len(text.encode("utf-8")) > 65_536:
        raise ValueError("Clipboard text exceeds the 65536-byte limit")
    return runtime.call("client.call", {
        "name": "copy_to_clipboard",
        "args": [text],
        "kwargs": {},
    })
