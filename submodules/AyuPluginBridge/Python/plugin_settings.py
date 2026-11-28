"""Android settings signatures restricted to the current native-owned plugin.

The scoped ``get_setting(key, default)``/``set_setting(key, value)`` forms are
also supported. An explicit plugin ID never grants access to another owner.
"""
from __future__ import annotations

import math

from ayu_bridge import BridgeError, UnsupportedAPI, runtime

_MISSING = object()


def _owner(plugin_id=None):
    scope = runtime.require()
    if plugin_id is not None and plugin_id != scope.plugin_id:
        raise BridgeError("OWNERSHIP", "Settings belong to the active plugin")
    return scope


def _key(key):
    if not isinstance(key, str) or not key or len(key.encode("utf-8")) > 256:
        raise ValueError("Setting key must be a nonempty bounded string")
    return key


def _persistent(value, depth=0):
    # Do not use runtime.encode for validation: it can register callbacks and
    # accepts native handles, neither of which belongs in persistent settings.
    if depth > 64:
        raise ValueError("Settings exceed the nesting limit")
    if value is None or type(value) in (bool, str):
        return
    if type(value) is int:
        if not -(2 ** 63) <= value < 2 ** 63:
            raise ValueError("Settings integers must fit signed Int64")
        return
    if type(value) is float:
        if not math.isfinite(value):
            raise ValueError("Settings numbers must be finite")
        return
    if isinstance(value, (list, tuple)):
        for item in value:
            _persistent(item, depth + 1)
        return
    if isinstance(value, dict):
        for key, item in value.items():
            if not isinstance(key, str) or key.startswith("$"):
                raise ValueError("Settings objects require ordinary string keys")
            _persistent(item, depth + 1)
        return
    raise TypeError("Settings values must be JSON data")


def _bind(args, kwargs, last, last_default=_MISSING):
    # Android's forms have three arguments, the scoped forms have two.
    # Explicit plugin_id or a positional owner plus keyword key is unambiguous.
    fields = ("plugin_id", "key", last) if (
        len(args) > 2 or "plugin_id" in kwargs or (args and "key" in kwargs)
        or (len(args) == 2 and last in kwargs)
    ) else ("key", last)
    if len(args) > len(fields):
        raise TypeError("Too many setting arguments")
    result = dict(zip(fields, args))
    for name, value in kwargs.items():
        if name not in fields or name in result:
            raise TypeError("Unknown or duplicate setting argument: " + name)
        result[name] = value
    if "key" not in result or (last not in result and last_default is _MISSING):
        raise TypeError("Missing setting argument")
    _owner(result.get("plugin_id"))
    return _key(result["key"]), result.get(last, last_default)


def get_setting(*args, **kwargs):
    key, default = _bind(args, kwargs, "default", None)
    _persistent(default)
    return runtime.call("settings.get", {"key": key, "default": default})


def set_setting(*args, reload_settings=False, **kwargs):
    key, value = _bind(args, kwargs, "value")
    _persistent(value)
    return runtime.call("settings.set", {"key": key, "value": value,
                                         "reload_settings": bool(reload_settings)})


def get_all_settings(plugin_id=None):
    _owner(plugin_id)
    result = runtime.call("settings.all", {})
    if not isinstance(result, dict):
        raise BridgeError("PROTOCOL_ERROR", "settings.all must return an object")
    return result


def set_all_settings(*args, plugin_id=None, settings=_MISSING, reload_settings=False):
    if len(args) > 2:
        raise TypeError("Too many settings arguments")
    if len(args) == 2:
        if plugin_id is not None or settings is not _MISSING:
            raise TypeError("Duplicate settings arguments")
        plugin_id, settings = args
    elif args:
        if settings is _MISSING:
            settings = args[0]
        elif plugin_id is None:
            plugin_id = args[0]
        else:
            raise TypeError("Duplicate settings arguments")
    _owner(plugin_id)
    if not isinstance(settings, dict):
        raise TypeError("Settings must be a dictionary")
    # Validate every key/value before mutating persistence or callback state.
    for key, value in settings.items():
        _key(key)
        _persistent(value)
    _persistent(settings)
    if "settings.replace" in runtime.capabilities["operations"]:
        # One host transaction validates the complete namespace before commit.
        # Do not fall back after rejection: the failure must preserve old data.
        return runtime.call("settings.replace", {"values": settings,
                                                  "reload_settings": bool(reload_settings)})
    # Older hosts can only set individual keys. This fallback reaches the exact
    # final namespace only when no existing keys need removal; it is not atomic.
    existing = get_all_settings()
    if set(existing) - set(settings):
        raise UnsupportedAPI("Replacing settings that removes keys requires a native settings adapter")
    if not settings and reload_settings:
        raise UnsupportedAPI("Reloading empty settings requires a native settings adapter")
    items = list(settings.items())
    for index, (key, value) in enumerate(items):
        set_setting(key, value, reload_settings=reload_settings and index == len(items) - 1)


def clear_settings(plugin_id=None, *, reload_settings=False):
    return set_all_settings(plugin_id=plugin_id, settings={}, reload_settings=reload_settings)
