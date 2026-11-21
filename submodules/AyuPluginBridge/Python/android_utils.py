"""Explicitly implemented portable Android utility subset."""
from ayu_bridge import runtime
from client_utils import run_on_ui_thread


def log(message):
    return runtime.call("log.write", {"level": "info", "message": str(message)})
