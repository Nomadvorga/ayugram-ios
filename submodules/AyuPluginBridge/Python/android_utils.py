"""Explicitly implemented portable Android utility subset."""
from ayu_bridge import runtime
from client_utils import get_last_fragment


def log(data):
    from log_utils import dump, _split_for_logcat
    text = str(data) if data is None or isinstance(data, (str, int, float, bool)) else dump(data)
    for chunk in _split_for_logcat(text, 3800):
        runtime.call("log.write", {"level": "info", "message": chunk})


def get_context():
    """Return the host-owned context descriptor for the visible surface.

    This is not an Android Application/Activity copy. It is the same bounded
    context adapter already exposed through ``get_last_fragment()``; callers
    still get ``UNSUPPORTED_API`` for members the host does not implement.
    """
    fragment = get_last_fragment()
    return fragment.getContext() if fragment is not None else None


def OnClickListener(fn):
    """Use the declared UIKit click proxy; listeners remain generation-owned."""
    if not callable(fn):
        raise TypeError("Click listener requires a callback")
    from java import dynamic_proxy, jclass
    from extera_utils.lifecycle import bind

    class Listener(dynamic_proxy(jclass("android.view.View$OnClickListener"))):
        def onClick(self, view):
            return callback(view)

    callback = bind(fn)
    return Listener()


def OnLongClickListener(fn):
    """Requires a declared native listener; unavailable hosts fail immediately."""
    if not callable(fn):
        raise TypeError("Long click listener requires a callback")
    from java import dynamic_proxy, jclass
    from extera_utils.lifecycle import bind

    class Listener(dynamic_proxy(jclass("android.view.View$OnLongClickListener"))):
        def onLongClick(self, view):
            result = callback(view)
            return True if result is None else bool(result)

    callback = bind(fn)
    return Listener()


def R(fn):
    """Create the existing generation-owned native Runnable proxy."""
    if not callable(fn):
        raise TypeError("fn must be callable")
    from java import dynamic_proxy, jclass
    from extera_utils.lifecycle import bind_task

    class Runnable(dynamic_proxy(jclass("java.lang.Runnable"))):
        def run(self):
            callback()

    callback = bind_task(fn)
    return Runnable()


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
