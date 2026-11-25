"""Explicit extera-style SDK surface; native support is capability-gated."""
from __future__ import annotations

from dataclasses import dataclass
from enum import Enum, IntEnum
from functools import wraps

from ayu_bridge import BridgeError, Registration, UnsupportedAPI, runtime


class HookStrategy(IntEnum):
    DEFAULT = 0
    CANCEL = 1
    MODIFY = 2
    MODIFY_FINAL = 3

    @classmethod
    def _missing_(cls, value):
        # The bridge uses integer strategy tags; Android accepts SDK names.
        if isinstance(value, str):
            return cls.__members__.get(value)


@dataclass
class HookResult:
    strategy: HookStrategy = HookStrategy.DEFAULT
    request: object = None
    response: object = None
    update: object = None
    updates: object = None
    error: object = None
    params: object = None

    def __post_init__(self):
        self.strategy = HookStrategy(self.strategy)

    def to_bridge(self):
        return {"strategy": int(self.strategy), "request": self.request,
                "response": self.response, "update": self.update,
                "updates": self.updates, "error": self.error, "params": self.params}


class _SendMessageParams(dict):
    """Supported send fields accept both Android attributes and mapping access.

    Native validates replacements and owns account/destination. Undeclared Java
    fields are not fabricated on this DTO.
    """
    _fields = frozenset({"peer", "message", "caption"})

    def __getattr__(self, name):
        if name not in self._fields:
            raise AttributeError(name)
        return self.get(name)

    def __setattr__(self, name, value):
        if name not in self._fields:
            raise UnsupportedAPI("Send parameter field requires a native adapter")
        self[name] = value


class AppEvent(str, Enum):
    START = "START"
    RESUME = "RESUME"
    PAUSE = "PAUSE"
    STOP = "STOP"

    @classmethod
    def _missing_(cls, value):
        if isinstance(value, str) and value.startswith("app_"):
            return cls.__members__.get(value[4:].upper())


class MenuItemType(str, Enum):
    MESSAGE_CONTEXT_MENU = "MESSAGE_CONTEXT_MENU"
    CHAT_ACTION_MENU = "CHAT_ACTION_MENU"
    DRAWER_MENU = "DRAWER_MENU"
    MAIN_MENU = "MAIN_MENU"
    PROFILE_ACTION_MENU = "PROFILE_ACTION_MENU"

    @classmethod
    def _missing_(cls, value):
        if isinstance(value, str):
            return cls.__members__.get(value.upper())


MenuItemTypes = MenuItemType


class MenuItemData:
    def __init__(self, menu_type=None, text=None, on_click=None, item_id=None,
                 icon=None, subtext=None, condition=None, priority=0,
                 on_long_click=None, **kwargs):
        menu_type = kwargs.pop("type", menu_type)
        if kwargs:
            raise TypeError("Unknown menu options: " + ", ".join(sorted(kwargs)))
        if menu_type is None or not isinstance(text, str) or not callable(on_click):
            raise TypeError("Menu item requires type, text and on_click")
        if on_long_click is not None and not callable(on_long_click):
            raise TypeError("on_long_click must be callable")
        self.menu_type = MenuItemType(menu_type)
        self.text, self.on_click = text, on_click
        self.item_id, self.icon, self.subtext = item_id, icon, subtext
        self.condition, self.priority = condition, int(priority)
        self.on_long_click = on_long_click

    @property
    def config(self):
        return self.to_bridge()

    def to_bridge(self):
        result = {"type": MenuItemType(self.menu_type).value, "text": self.text,
                  "on_click": self.on_click, "priority": self.priority}
        for name in ("item_id", "icon", "subtext", "condition", "on_long_click"):
            value = getattr(self, name)
            if value is not None:
                result[name] = value
        return result


@dataclass
class PluginMetadata:
    id: str
    name: str
    description: str
    author: str
    version: str
    icon: str
    min_version: str
    requirements: list[str]


class PluginError(Exception):
    def __init__(self, message, plugin_id=None):
        super().__init__(message)
        self.plugin_id = plugin_id


class IntentHookType(IntEnum):
    BEFORE = 0
    AFTER = 1


class XposedHook:
    pass


class MethodHook(XposedHook):
    def before_hooked_method(self, param):
        return None

    def after_hooked_method(self, param):
        return None


class MethodReplacement(MethodHook):
    def replace_hooked_method(self, param):
        raise NotImplementedError


class BaseHook(MethodHook):
    def __init__(self, plugin=None, *, before=None, after=None,
                 before_filters=None, after_filters=None):
        for callback in (before, after):
            if callback is not None and not callable(callback):
                raise TypeError("Hook callbacks must be callable")
        self.plugin, self.before, self.after = plugin, before, after
        self.before_filters, self.after_filters = before_filters, after_filters

    def before_hooked_method(self, param):
        if self.before is not None:
            return self.before(param)

    def after_hooked_method(self, param):
        if self.after is not None:
            return self.after(param)


@dataclass
class HookFilterData:
    filter_type: str
    arg_index: int | None = None
    or_filters: object = None
    mvel_expression: str | None = None
    instance_of: object = None
    object: object = None

    def to_java_filter(self):
        raise UnsupportedAPI("Native method hook filters are unavailable")


class HookFilter(str, Enum):
    RESULT_IS_NULL = "result_is_null"
    RESULT_IS_TRUE = "result_is_true"
    RESULT_IS_FALSE = "result_is_false"
    RESULT_NOT_NULL = "result_not_null"

    @property
    def filter_data(self):
        return HookFilterData(self.value)

    @staticmethod
    def ResultIsInstanceOf(clazz):
        return HookFilterData("result_is_instance_of", instance_of=clazz)

    @staticmethod
    def ResultEqual(value):
        return HookFilterData("result_equal", object=value)

    @staticmethod
    def ResultNotEqual(value):
        return HookFilterData("result_not_equal", object=value)

    @staticmethod
    def ArgumentIsNull(index):
        return HookFilterData("argument_is_null", arg_index=index)

    @staticmethod
    def ArgumentIsTrue(index):
        return HookFilterData("argument_is_true", arg_index=index)

    @staticmethod
    def ArgumentIsFalse(index):
        return HookFilterData("argument_is_false", arg_index=index)

    @staticmethod
    def ArgumentNotNull(index):
        return HookFilterData("argument_not_null", arg_index=index)

    @staticmethod
    def ArgumentIsInstanceOf(index, clazz):
        return HookFilterData("argument_is_instance_of", arg_index=index, instance_of=clazz)

    @staticmethod
    def ArgumentEqual(index, value):
        return HookFilterData("argument_equal", arg_index=index, object=value)

    @staticmethod
    def ArgumentNotEqual(index, value):
        return HookFilterData("argument_not_equal", arg_index=index, object=value)

    @staticmethod
    def Condition(condition, object=None):
        return HookFilterData("condition", mvel_expression=condition, object=object)

    @staticmethod
    def Or(*filters):
        if not filters:
            return None
        return HookFilterData("or", or_filters=[
            item.filter_data if isinstance(item, HookFilter) else item
            for item in filters if isinstance(item, (HookFilter, HookFilterData))
        ])


def hook_filters(*filters):
    if len(filters) == 1 and isinstance(filters[0], list):
        filters = tuple(filters[0])
    values = []
    for item in filters:
        if isinstance(item, HookFilter):
            item = item.filter_data
        if not isinstance(item, HookFilterData):
            raise TypeError("Expected HookFilter or HookFilterData")
        values.append(item)

    def decorator(function):
        function.__hook_filters__ = values
        return function
    return decorator


def fn_hook_filters(field_name):
    def decorator(function):
        function.__hook_filters__ = lambda instance: getattr(instance, field_name, []) or []
        return function
    return decorator


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
    def __init_subclass__(cls, **kwargs):
        super().__init_subclass__(**kwargs)
        # Android's lifecycle owns cleanup independently of a plugin's unload
        # override. Keep that guarantee even when it omits super() or raises.
        unload = cls.__dict__.get("on_plugin_unload")
        if unload is not None:
            @wraps(unload)
            def unload_and_cleanup(self, *args, **kw):
                try:
                    return unload(self, *args, **kw)
                finally:
                    self._run_cleanups()
            cls.on_plugin_unload = unload_and_cleanup

    def __init__(self):
        self._ayu_scope = runtime.require()
        self.logger = _Logger(self._ayu_scope)
        self._ayu_cleanup = []
        self._ayu_request_hooks = {}
        self.error_message = None

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

    def client(self, account=None):
        self._scope()
        from client_utils import get_client
        return get_client(account=account)

    @property
    def description(self):
        return self._scope().metadata.get("__description__", "")

    @property
    def author(self):
        return self._scope().metadata.get("__author__", "")

    @property
    def icon(self):
        return self._scope().metadata.get("__icon__")

    @property
    def min_version(self):
        return self._scope().metadata.get("__min_version__", "")

    @property
    def requirements(self):
        return list(self._scope().metadata.get("__requirements__", []))

    @property
    def enabled(self):
        return self._scope().state == "active"

    @property
    def initialized(self):
        return self._scope().state == "active"

    def on_plugin_load(self):
        pass

    def on_plugin_unload(self):
        self._run_cleanups()

    def _run_cleanups(self):
        pending, self._ayu_cleanup = self._ayu_cleanup, []
        first_error = None
        for cleanup in reversed(pending):
            try:
                cleanup()
            except Exception as error:
                if first_error is None:
                    first_error = error
        if first_error is not None:
            raise first_error

    def on_app_event(self, event_type):
        pass

    def create_settings(self):
        return []

    def _key(self, key):
        self._scope()
        if not isinstance(key, str) or not key or len(key.encode("utf-8")) > 256:
            raise ValueError("Setting/state key must be a nonempty bounded string")
        return key

    def get_setting(self, key, default=None):
        self._scope()
        from plugin_settings import get_setting
        return get_setting(key, default)

    def set_setting(self, key, value, reload_settings=False):
        self._scope()
        from plugin_settings import set_setting
        return set_setting(key, value, reload_settings=reload_settings)

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

    def import_settings(self, settings, reload_settings=True):
        self._scope()
        from plugin_settings import set_all_settings
        return set_all_settings(self.id, settings, reload_settings=reload_settings)

    def register_cleanup(self, callback):
        scope = self._scope()
        if scope.state == "unloading":
            raise BridgeError("PLUGIN_UNLOADING", "Cannot register cleanup during unload")
        if not callable(callback):
            raise TypeError("Cleanup must be callable")
        if len(self._ayu_cleanup) >= 1024:
            raise BridgeError("RESOURCE_LIMIT", "Plugin cleanup limit reached")
        self._ayu_cleanup.append(callback)
        return callback

    def log(self, message):
        return self.logger.info(message)

    def add_on_send_message_hook(self, priority=0):
        self._scope()
        def callback(account, params):
            if isinstance(params, dict):
                params = _SendMessageParams(params)
            return self.on_send_message_hook(account, params)
        return runtime.register("hook", {"kind": "send_message", "priority": int(priority),
                                          "callback": self._account_hook(callback, 0)})

    def _account_hook(self, function, account_index):
        @wraps(function)
        def callback(*args, **kwargs):
            self._scope()
            from client_utils import account_scope
            account = args[account_index] if len(args) > account_index else kwargs.get("account")
            with account_scope(account):
                return function(*args, **kwargs)
        return callback

    def add_hook(self, name, match_substring=False, priority=0):
        self._scope()
        if not isinstance(name, str) or not name:
            raise ValueError("Request hook name is required")
        if type(match_substring) is not bool:
            raise TypeError("match_substring must be bool")
        registration = runtime.register("hook", {"kind": "request", "name": name,
                                          "match_substring": match_substring, "priority": int(priority),
                                          "pre": self._account_hook(self.pre_request_hook, 1),
                                          "post": self._account_hook(self.post_request_hook, 1),
                                          "update": self._account_hook(self.on_update_hook, 1),
                                          "updates": self._account_hook(self.on_updates_hook, 1)})
        self._ayu_request_hooks.setdefault(name, []).append(registration)
        return registration

    def remove_hook(self, registration):
        self._scope()
        if isinstance(registration, str):
            registrations = self._ayu_request_hooks.get(registration, [])
            for owned in list(registrations):
                owned.cancel()
                registrations.remove(owned)
            self._ayu_request_hooks.pop(registration, None)
            return None
        if not isinstance(registration, Registration) or registration.kind != "hook":
            raise TypeError("Expected owned hook registration")
        return registration.cancel()

    def on_send_message_hook(self, account, params):
        return HookResult()

    def pre_request_hook(self, request_name, account, request):
        return HookResult()

    def post_request_hook(self, request_name, account, response, error):
        return HookResult()

    def on_update_hook(self, update_name, account, update):
        return HookResult()

    def on_updates_hook(self, container_name, account, updates):
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
        if isinstance(registration, str):
            registration = self._scope().registrations.get(("menu", registration))
            if registration is None:
                return False
        if not isinstance(registration, Registration) or registration.kind != "menu":
            raise TypeError("Expected owned menu registration")
        registration.cancel()
        return True

    def _method_hook(self, kind, hook, priority, *, before=None, after=None,
                     before_filters=None, after_filters=None, **target):
        self._scope()
        if before_filters or after_filters:
            raise UnsupportedAPI("Native method hook filters are unavailable")
        if hook is not None and (before is not None or after is not None):
            raise TypeError("Pass xposed_hook or before/after callbacks")
        if hook is None:
            if before is None and after is None:
                raise TypeError("xposed_hook or before or after is required")
            hook = BaseHook(self, before=before, after=after)
        if getattr(hook, "before_filters", None) or getattr(hook, "after_filters", None):
            raise UnsupportedAPI("Native method hook filters are unavailable")
        config = {"kind": kind, "priority": 0 if priority is None else int(priority), **target}
        replacement = getattr(hook, "replace_hooked_method", None)
        if callable(replacement):
            config["replace"] = replacement
        else:
            for phase in ("before", "after"):
                callback = getattr(hook, phase + "_hooked_method", None)
                if callable(callback):
                    if getattr(callback, "__hook_filters__", None):
                        raise UnsupportedAPI("Native method hook filters are unavailable")
                    if getattr(callback, "__func__", None) is not getattr(MethodHook, phase + "_hooked_method"):
                        config[phase] = callback
            if "before" not in config and "after" not in config:
                raise TypeError("Expected a method hook callback")
        return runtime.register("hook", config)

    def hook_method(self, method_or_constructor, xposed_hook=None, priority=None, **callbacks):
        return self._method_hook("java_method", xposed_hook, priority,
                                 method=method_or_constructor, **callbacks)

    def hook_all_methods(self, hook_class, method_name, xposed_hook=None, priority=None, **callbacks):
        if not isinstance(method_name, str) or not method_name:
            raise ValueError("Method name is required")
        return self._method_hook("java_all_methods", xposed_hook, priority,
                                 java_class=hook_class, name=method_name, **callbacks)

    def hook_all_constructors(self, hook_class, xposed_hook=None, priority=None, **callbacks):
        return self._method_hook("java_all_constructors", xposed_hook, priority,
                                 java_class=hook_class, **callbacks)

    def unhook_method(self, registration):
        return self.remove_hook(registration)
