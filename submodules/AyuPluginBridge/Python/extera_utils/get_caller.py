"""Diagnostic caller locations. These strings never confer plugin authority."""
import os
import sys

ELYX_PLUGIN_NAMESPACE = "ElyxPlugins"


def _get_callable_location(fn):
    seen = set()
    for _ in range(5):
        if fn is None or id(fn) in seen:
            break
        seen.add(id(fn))
        code = getattr(fn, "__code__", None)
        if code is not None:
            return code.co_filename, code.co_name, code.co_firstlineno, getattr(fn, "__module__", "")
        target = getattr(fn, "__wrapped__", None)
        if target is None:
            target = getattr(fn, "__func__", None)
        if target is None:
            target = getattr(fn, "func", None)
        if target is None:
            target = getattr(type(fn), "__call__", None)
        fn = target
    return None


def _plugin_id_from_location(filename, module_name=""):
    parts = str(module_name).split(".")
    if len(parts) > 1 and parts[0] == ELYX_PLUGIN_NAMESPACE:
        return parts[1]
    parts = str(filename).replace("\\", "/").split("/")
    if ELYX_PLUGIN_NAMESPACE in parts:
        index = parts.index(ELYX_PLUGIN_NAMESPACE) + 1
        if index < len(parts):
            return parts[index]
    return os.path.splitext(parts[-1])[0]


def _format_location(filename, function, lineno, module_name=""):
    name = str(filename).replace("\\", "/").rsplit("/", 1)[-1]
    return f"[{name}:{function}:{lineno}] ", _plugin_id_from_location(filename, module_name)


def get_plugin_id(fn=None):
    location = _get_callable_location(fn)
    if location is not None:
        return _format_location(*location)
    frame = sys._getframe(1)
    try:
        frame = frame.f_back
        if frame:
            return _format_location(frame.f_code.co_filename, frame.f_code.co_name,
                                    frame.f_lineno, frame.f_globals.get("__name__", ""))
    finally:
        del frame
    return "", ""
