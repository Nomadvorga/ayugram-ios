"""Explicit extera-style SDK surface; native support is capability-gated."""
from __future__ import annotations

from dataclasses import dataclass
from enum import Enum, IntEnum

from ayu_bridge import BridgeError, Registration, runtime


class HookStrategy(IntEnum):
    DEFAULT = 0
    CANCEL = 1
    MODIFY = 2
    MODIFY_FINAL = 3


@dataclass
class HookResult:
    strategy: HookStrategy = HookStrategy.DEFAULT
    request: object = None
    response: object = None
    params: object = None

    def __post_init__(self):
        self.strategy = HookStrategy(self.strategy)

    def to_bridge(self):
        return {"strategy": int(self.strategy), "request": self.request,
                "response": self.response, "params": self.params}


class AppEvent(str, Enum):
    START = "START"
    RESUME = "RESUME"
    PAUSE = "PAUSE"
    STOP = "STOP"


class MenuItemType(str, Enum):
    MESSAGE_CONTEXT_MENU = "MESSAGE_CONTEXT_MENU"
    CHAT_ACTION_MENU = "CHAT_ACTION_MENU"
    DRAWER_MENU = "DRAWER_MENU"
    PROFILE_ACTION_MENU = "PROFILE_ACTION_MENU"


MenuItemTypes = MenuItemType


class MenuItemData:
    def __init__(self, menu_type=None, text=None, on_click=None, **kwargs):
        menu_type = kwargs.pop("type", menu_type)
        if menu_type is None or not isinstance(text, str) or not callable(on_click):
            raise TypeError("Menu item requires type, text and on_click")
        self.config = {"type": MenuItemType(menu_type).value, "text": text,
                       "on_click": on_click, **kwargs}

    def to_bridge(self):
        return dict(self.config)


class MethodHook:
    def before_hooked_method(self, param):
        return None

    def after_hooked_method(self, param):
        return None


class MethodReplacement(MethodHook):
    def replace_hooked_method(self, param):
        raise NotImplementedError


class _Logger:
    def __init__(self, scope):
        self.scope = scope

    def _log(self, level, message):
        runtime.require(self.scope)
        return runtime.call("log.write", {"level": level, "message": str(message)})

    def debug(self, message):
        return self._log("debug", message)

    def info(self, message):
        return self._log("info", message)

    def warning(self, message):
        return self._log("warning", message)

    warn = warning

    def error(self, message):
        return self._log("error", message)

    exception = error


class BasePlugin:
    def __init__(self):
        self._ayu_scope = runtime.require()
        self.logger = _Logger(self._ayu_scope)
        self._ayu_cleanup = []

    def _scope(self):
        return runtime.require(self._ayu_scope)

    @property
    def id(self):
        return self._scope().plugin_id

    @property
    def name(self):
        return self._scope().metadata.get("__name__", self.id)

    @property
    def version(self):
        return self._scope().metadata.get("__version__", "1.0")

    @property
    def client(self):
        from client_utils import AccountClient
        return AccountClient()

    def on_plugin_load(self):
        pass

    def on_plugin_unload(self):
        for cleanup in reversed(self._ayu_cleanup):
            cleanup()
        self._ayu_cleanup.clear()

    def on_app_event(self, event_type):
        pass

    def create_settings(self):
        return []

    def _key(self, key):
        self._scope()
        if not isinstance(key, str) or not key or len(key) > 256:
            raise ValueError("Setting/state key must be a nonempty bounded string")
        return key

    def get_setting(self, key, default=None):
        return runtime.call("settings.get", {"key": self._key(key), "default": default})

    def set_setting(self, key, value, reload_settings=False):
        return runtime.call("settings.set", {"key": self._key(key), "value": value,
                                             "reload_settings": bool(reload_settings)})

    def get_all_settings(self):
        self._scope()
        result = runtime.call("settings.all", {})
        if not isinstance(result, dict):
            raise BridgeError("PROTOCOL_ERROR", "settings.all must return an object")
        return result

    def get_state(self, key, default=None):
        return runtime.call("state.get", {"key": self._key(key), "default": default})

    def set_state(self, key, value):
        return runtime.call("state.set", {"key": self._key(key), "value": value})

    def export_settings(self):
        return self.get_all_settings()

    def import_settings(self, values):
        if not isinstance(values, dict):
            raise TypeError("Settings must be a dictionary")
        # Validate the entire payload before any native write. Host persistence
        # remains nontransactional; propagate an error rather than claim success.
        runtime.encode(values)
        for key in values:
            self._key(key)
        for key, value in values.items():
            self.set_setting(key, value)

    def register_cleanup(self, callback):
        self._scope()
        if not callable(callback):
            raise TypeError("Cleanup must be callable")
        self._ayu_cleanup.append(callback)
        return callback

    def log(self, message):
        return self.logger.info(message)

    def add_on_send_message_hook(self, priority=0):
        self._scope()
        return runtime.register("hook", {"kind": "send_message", "priority": int(priority),
                                          "callback": self.on_send_message_hook})

    def add_hook(self, name, priority=0):
        self._scope()
        if not isinstance(name, str) or not name:
            raise ValueError("Request hook name is required")
        return runtime.register("hook", {"kind": "request", "name": name, "priority": int(priority),
                                          "pre": self.pre_request_hook, "post": self.post_request_hook,
                                          "update": self.on_update_hook, "updates": self.on_updates_hook})

    def remove_hook(self, registration):
        self._scope()
        if not isinstance(registration, Registration) or registration.kind != "hook":
            raise TypeError("Expected owned hook registration")
        return registration.cancel()

    def on_send_message_hook(self, account, params):
        return HookResult()

    def pre_request_hook(self, account, request):
        return HookResult()

    def post_request_hook(self, account, response):
        return HookResult()

    def on_update_hook(self, account, update):
        return HookResult()

    def on_updates_hook(self, account, updates):
        return HookResult()

    def add_menu_item(self, item=None, **kwargs):
        self._scope()
        if item is None:
            item = MenuItemData(**kwargs)
        elif kwargs:
            raise TypeError("Pass MenuItemData or keyword config, not both")
        if not isinstance(item, MenuItemData):
            raise TypeError("Expected MenuItemData")
        return runtime.register("menu", item.to_bridge())

    def remove_menu_item(self, registration):
        self._scope()
        if not isinstance(registration, Registration) or registration.kind != "menu":
            raise TypeError("Expected owned menu registration")
        return registration.cancel()

    def _method_hook(self, kind, hook, priority, **target):
        self._scope()
        if not isinstance(hook, MethodHook):
            raise TypeError("Expected MethodHook")
        config = {"kind": kind, "priority": int(priority), **target}
        if isinstance(hook, MethodReplacement):
            config["replace"] = hook.replace_hooked_method
        else:
            config["before"] = hook.before_hooked_method
            config["after"] = hook.after_hooked_method
        return runtime.register("hook", config)

    def hook_method(self, method, hook, priority=0):
        return self._method_hook("java_method", hook, priority, method=method)

    def hook_all_methods(self, clazz, name, hook, priority=0):
        return self._method_hook("java_all_methods", hook, priority, java_class=clazz, name=name)

    def hook_all_constructors(self, clazz, hook, priority=0):
        return self._method_hook("java_all_constructors", hook, priority, java_class=clazz)

    def unhook_method(self, registration):
        return self.remove_hook(registration)
