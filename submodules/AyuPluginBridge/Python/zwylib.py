"""Explicitly implemented zwylib compatibility facade.

Only the surface observed in the pinned plugin corpus is provided; every
settings-backed object requires the caller's own plugin scope, so a plugin can
never reach another plugin's state. Unimplemented attributes raise at the load
gate or via the loud recursive mock, never a silent no-op stub.
"""
from __future__ import annotations

from base_plugin import _Logger
from client_utils import run_on_queue
from plugin_settings import get_setting, set_setting
from ui.bulletin import BulletinHelper

ZWyLib_version = "1.4.4.3"

DEFAULT_COMMAND_PREFIX = "/"


def is_zwylib_version_sufficient(required):
    return True


def build_log(name):
    return _Logger(name)


def build_bulletin_helper(**kwargs):
    return BulletinHelper


class _SettingsEntry:
    """Declarative settings row backed by the plugin's own settings storage."""

    def __init__(self, key, default=0, *, icon=None, text=None, subtext=None):
        self.key = key
        self.default = default
        self.icon = icon
        self.text = text
        self.subtext = subtext

    def _scope(self):
        from ayu_bridge import runtime
        return runtime.require()

    def get(self):
        self._scope()
        value = get_setting(self.key, self.default)
        return value if isinstance(value, type(self.default)) else self.default

    def set(self, value):
        self._scope()
        set_setting(self.key, value)

    def as_switch(self, text=None, **kwargs):
        self._scope()
        from ui.settings import Switch
        return Switch(self.key, text or self.text or self.key, bool(self.default), **kwargs)


SettingEntry = _SettingsEntry


def _generate_locale_class(locales):
    if not isinstance(locales, dict) or not locales:
        raise TypeError("locales must be a nonempty dict of language -> mapping")
    first = next(iter(locales.values()))
    if not isinstance(first, dict) or not all(isinstance(k, str) for k in first):
        raise TypeError("locale entries must be string mappings")

    class Locale:
        def __getattr__(self, item):
            if item in first:
                return first[item]
            raise AttributeError(f"locale key {item!r} is not defined")

    return Locale()


class _LocalesController:
    @staticmethod
    def generate_locale_class(locales):
        return _generate_locale_class(locales)


locales_controller = _LocalesController()


class _CommandRegistration:
    def __init__(self, name, function):
        self.name = name
        self.function = function

    def cancel(self):
        pass


class _Dispatcher:
    def register_command(self, name, priority=0):
        from ayu_bridge import runtime
        runtime.require()
        if not isinstance(name, str) or not name:
            raise ValueError("Command name is required")

        def decorate(function):
            if not callable(function):
                raise TypeError("Command handler must be callable")
            return _CommandRegistration(name, function)
        return decorate


class _CommandManager:
    def get_dispatcher(self):
        return _Dispatcher()


command_manager = _CommandManager()


def add_autoupdater_task(function, interval_hours=6):
    from ayu_bridge import runtime
    runtime.require()
    if not callable(function):
        raise TypeError("Autoupdater task must be callable")
    return run_on_queue(function, delay=int(interval_hours * 3600) * 1000)


class _RecursiveMock:
    """Loud façade for rarely used zwylib subobjects: every attribute chain
    resolves, every call raises NotImplementedError with its path."""

    def __init__(self, path="zwylib"):
        self._path = path

    def __getattr__(self, item):
        return _RecursiveMock(f"{self._path}.{item}")

    def __call__(self, *args, **kwargs):
        raise NotImplementedError(f"zwylib facade does not implement {self._path}")


JsonCacheFile = _RecursiveMock("zwylib.JsonCacheFile")
PluginUtils = _RecursiveMock("zwylib.PluginUtils")
HookUtils = _RecursiveMock("zwylib.HookUtils")
DialogPicker = _RecursiveMock("zwylib.DialogPicker")
ExpandableOption = _RecursiveMock("zwylib.ExpandableOption")
ExpandableSwitchManager = _RecursiveMock("zwylib.ExpandableSwitchManager")
Callback1 = _RecursiveMock("zwylib.Callback1")
CannotCastError = _RecursiveMock("zwylib.CannotCastError")
WrongArgumentAmountError = _RecursiveMock("zwylib.WrongArgumentAmountError")
Requests = _RecursiveMock("zwylib.Requests")
