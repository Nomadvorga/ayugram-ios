"""Explicitly implemented portable Android utility subset."""
from ayu_bridge import runtime
from client_utils import run_on_ui_thread


def log(message):
    return runtime.call("log.write", {"level": "info", "message": str(message)})


def OnClickListener(callback):
    """Use the declared UIKit click proxy; listeners remain generation-owned."""
    if not callable(callback):
        raise TypeError("Click listener requires a callback")
    from java import dynamic_proxy, jclass

    class Listener(dynamic_proxy(jclass("android.view.View$OnClickListener"))):
        def onClick(self, view):
            return callback(view)

    return Listener()
