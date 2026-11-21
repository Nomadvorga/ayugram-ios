"""Settings helpers always address the currently owned plugin scope."""
from ayu_bridge import runtime


def get_setting(key, default=None):
    return runtime.call("settings.get", {"key": key, "default": default})


def set_setting(key, value, reload_settings=False):
    return runtime.call("settings.set", {"key": key, "value": value,
                                         "reload_settings": bool(reload_settings)})


def get_all_settings():
    return runtime.call("settings.all", {})


def set_all_settings(values):
    if not isinstance(values, dict):
        raise TypeError("Settings must be a dictionary")
    runtime.encode(values)
    for key, value in values.items():
        set_setting(key, value)
