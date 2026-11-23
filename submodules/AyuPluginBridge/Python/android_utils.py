"""Explicitly implemented portable Android utility subset."""
from ayu_bridge import runtime
from client_utils import get_last_fragment, run_on_ui_thread


def log(message):
    return runtime.call("log.write", {"level": "info", "message": str(message)})


def get_context():
    """Return the host-owned context descriptor for the visible surface.

    This is not an Android Application/Activity copy. It is the same bounded
    context adapter already exposed through ``get_last_fragment()``; callers
    still get ``UNSUPPORTED_API`` for members the host does not implement.
    """
    fragment = get_last_fragment()
    return fragment.getContext() if fragment is not None else None


def OnClickListener(callback):
    """Use the declared UIKit click proxy; listeners remain generation-owned."""
    if not callable(callback):
        raise TypeError("Click listener requires a callback")
    from java import dynamic_proxy, jclass

    class Listener(dynamic_proxy(jclass("android.view.View$OnClickListener"))):
        def onClick(self, view):
            return callback(view)

    return Listener()
