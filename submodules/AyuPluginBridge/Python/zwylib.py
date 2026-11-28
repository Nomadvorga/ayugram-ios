"""ZwyLib 3.0.0 API for plugins that import the ``zwylib`` library plugin.

On Android ZwyLib is itself a plugin whose module other plugins import. Here
its public API is part of the SDK and every stateful object (locale cache,
command dispatcher, async loop, autoupdate tasks) belongs to the calling
plugin generation, so a plugin never reaches another plugin's state.

Members that need Telegram screens or the Android plugin registry
(``DialogPicker``, ``open_message``, ``PluginUtils``, ``ensure_media_downloaded``,
the expandable setting rows) are not defined, so preflight keeps reporting them.
The autoupdater only records tasks: iOS installs a plugin by explicit import,
so no update check ever runs.
"""
from __future__ import annotations

import asyncio
import copy
import inspect
import json
import logging
import os
import re
import shlex
import sys
import threading
import traceback
import zlib
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Any, Optional, Union, get_args, get_origin

from ayu_bridge import BridgeError, JavaClass, RemoteObject, UnsupportedAPI, runtime
from base_plugin import HookResult, HookStrategy, MethodReplacement
from ui.bulletin import BulletinHelper as _BulletinHelper

LIB_NAME = "ZwyLib"
__version__ = "3.0.0"
MATCH_PARENT = -1
WRAP_CONTENT = -2
DEFAULT_COMMAND_PREFIX = "."
_ID = "zwylib"
_ALLOWED_ARG_TYPES = (str, int, float, bool, Any)
_ALLOWED_ORIGIN = (Union, Optional)
_VERSION = re.compile(r"\s*v?(\d+(?:\.\d+)*)\s*((?:a|b|rc|alpha|beta|dev|pre)\.?\d*)?\s*\Z", re.IGNORECASE)


class _State:
    """ZwyLib objects of one plugin generation."""

    def __init__(self):
        self.locale = None
        self.locale_subscribers = {}
        self.async_manager = None
        self.command_manager = None
        self.autoupdater_tasks = []


def _state():
    scope = runtime.require()
    state = scope.__dict__.get("_ayu_zwylib")
    if state is None:
        state = scope.__dict__["_ayu_zwylib"] = _State()
    return state


def _plugin_id(plugin_id=None):
    """The calling plugin's id; ZwyLib's stack walk has the same answer here."""
    own = runtime.require().plugin_id
    if plugin_id is not None and plugin_id != own:
        raise BridgeError("OWNERSHIP", "ZwyLib state belongs to the calling plugin")
    return own


# ---- logs -------------------------------------------------------------------

def _safe_mapper(obj):
    try:
        return repr(obj) if isinstance(obj, RemoteObject) else str(obj)
    except Exception:
        return f"<UNREPRESENTABLE_{type(obj).__name__}>"


class _CustomLogger(logging.Logger):
    def setLevel(self, level):
        super().setLevel(level)
        # The logging manager only resets the level caches of loggers it registered.
        self._cache.clear()

    def _log(self, level, msg, args, exc_info=None, extra=None, stack_info=False, stacklevel=1):
        from android_utils import log
        func_name = sys._getframe(2).f_code.co_name
        text = f"{_safe_mapper(msg)} {' '.join(map(_safe_mapper, args))}".strip()
        output = f"[{logging.getLevelName(level)}] [{self.name}] [{func_name}] {text}"
        if exc_info:
            trace = traceback.format_exc() if exc_info is True else "".join(
                traceback.format_exception(type(exc_info), exc_info, exc_info.__traceback__))
            output += f"\n{trace.strip()}"
        log(output)


def build_log(plugin_name, level=logging.NOTSET):
    # ZwyLib registers the name with the process-wide logging manager; a logger
    # per call keeps plugins apart and still inherits the root level.
    logger = _CustomLogger(str(plugin_name))
    logger.parent = logging.root
    if level != logging.NOTSET:
        logger.setLevel(level)
    return logger


def format_exc():
    return traceback.format_exc().strip()


def format_exc_from(e):
    return "".join(traceback.format_exception(type(e), e, e.__traceback__)).strip()


def format_exc_only(e):
    return "".join(traceback.format_exception_only(type(e), e)).strip()


_logger = build_log(_ID)
_cmd_logger = build_log(_ID + ".commands")
_async_logger = build_log(_ID + ".async")
_req_logger = build_log(_ID + ".requests")
_hu_logger = build_log(_ID + ".hookutils")


# ---- locales ----------------------------------------------------------------

class _SmartString(str):
    def __call__(self, **kwargs):
        try:
            return self.format(**kwargs)
        except KeyError:
            return self


class _Locales:
    def __init__(self, locales):
        for language_code, locales_dict in locales.items():
            setattr(self, language_code, locales_dict)
        if "en" in locales:
            self.default = locales["en"]
        elif locales:
            self.default = locales[next(iter(locales))]
        else:
            self.default = {}

    def __getattr__(self, key):
        if key.startswith("__"):
            raise AttributeError(key)
        return self.get(key)

    @staticmethod
    def _get_plural_form(number, forms, lang):
        number = abs(number)
        if lang in ("ru", "uk") and len(forms) >= 3:
            if number % 10 == 1 and number % 100 != 11:
                return forms[0]
            if 2 <= number % 10 <= 4 and (number % 100 < 10 or number % 100 >= 20):
                return forms[1]
            return forms[2]
        if not forms:
            return ""
        if len(forms) == 1:
            return forms[0]
        return forms[0] if number == 1 else forms[1]

    def _get_from_default(self, key):
        return self.default.get(key, key)

    def _dictionary(self):
        dictionary = self.__dict__.get(locales_controller.get_current_locale(), self.default)
        return dictionary if isinstance(dictionary, dict) else self.default

    def get(self, key, dictionary=None):
        if not isinstance(dictionary, dict):
            dictionary = self._dictionary()
        value = dictionary.get(key)
        if value is None:
            value = self._get_from_default(key)
        if isinstance(value, str) and "{" in value and "}" in value:
            return _SmartString(value)
        return value

    def plural(self, key, number):
        lang = locales_controller.get_current_locale()
        forms = self._dictionary().get(key, self._get_from_default(key))
        if not isinstance(forms, list):
            return str(forms)
        return self._get_plural_form(number, forms, lang)


class _LocalesController:
    def refresh_locale(self):
        state = _state()
        controller = runtime.jclass("org.telegram.messenger.LocaleController")
        state.locale = controller.getInstance().getCurrentLocaleInfo().pluralLangCode
        for subscriber in list(state.locale_subscribers.values()):
            try:
                subscriber()
            except BridgeError:
                raise
            except Exception:
                _logger.error("An error occurred:", exc_info=True)

    def subscribe_to_refresh(self, sub):
        if not callable(sub):
            raise TypeError("Locale subscriber must be callable")
        _state().locale_subscribers[_plugin_id()] = sub

    def unsubscribe_from_refresh(self, plugin_id=None):
        _state().locale_subscribers.pop(_plugin_id(plugin_id), None)

    def get_current_locale(self):
        state = _state()
        if not state.locale:
            self.refresh_locale()
        return state.locale

    @staticmethod
    def generate_locale_class(dictionaries):
        return _Locales(dictionaries)


locales_controller = _LocalesController()
L = locales_controller.generate_locale_class({
    "en": {"copy_button": "Copy", "alert_done": "Done", "alert_cancel": "Cancel",
           "not_sufficient_zwylib_ver": "{plugin_name} needs " + LIB_NAME + " {version}+, got {cur_ver}.",
           "stub_command_message": "This command is a stub for registration of subcommand. Dont use it.",
           "likely_cmd_name_misspelling": "It seems like you have misspelled the command name.",
           "command_execution_error": "An error occurred executing command '{cmd_name}'"},
    "ru": {"copy_button": "\u0421\u043a\u043e\u043f\u0438\u0440\u043e\u0432\u0430\u0442\u044c",
           "alert_done": "\u0413\u043e\u0442\u043e\u0432\u043e", "alert_cancel": "\u041e\u0442\u043c\u0435\u043d\u0430"},
    "uk": {"copy_button": "\u0421\u043a\u043e\u043f\u0456\u044e\u0432\u0430\u0442\u0438",
           "alert_done": "\u0413\u043e\u0442\u043e\u0432\u043e",
           "alert_cancel": "\u0421\u043a\u0430\u0441\u0443\u0432\u0430\u0442\u0438"},
})


# ---- async ------------------------------------------------------------------

class _AsyncMarker:
    def __init__(self, obj, success_method, error_method=None):
        self.obj = obj
        self.success_method = success_method
        self.error_method = error_method


def _safe_set_future_result(future, result):
    if future.done():
        return
    loop = future.get_loop()
    if not loop.is_closed():
        loop.call_soon_threadsafe(lambda: future.done() or future.set_result(result))


def _safe_set_future_exception(future, exc):
    if future.done():
        return
    loop = future.get_loop()
    if not loop.is_closed():
        loop.call_soon_threadsafe(lambda: future.done() or future.set_exception(exc))


def _wrap_callback_methods(marker, future):
    target = marker.obj

    def original(method_name):
        saved = f"__zwy_orig_{method_name}"
        if hasattr(target, saved):
            return getattr(target, saved)
        method = getattr(target, method_name)
        setattr(target, saved, method)
        return method

    pure_success = original(marker.success_method)

    def wrapped_success(*cb_args):
        pure_success(*cb_args)
        _safe_set_future_result(future, cb_args[0] if len(cb_args) == 1 else cb_args)

    setattr(target, marker.success_method, wrapped_success)
    if marker.error_method:
        pure_error = original(marker.error_method)

        def wrapped_error(*cb_args):
            pure_error(*cb_args)
            _safe_set_future_exception(future, Exception("Java error: " + " ".join(map(str, cb_args))))

        setattr(target, marker.error_method, wrapped_error)


class _AsyncManager:
    """One asyncio loop on a worker thread of the calling plugin generation.

    Coroutines run on that thread; bridge calls they make are marshalled to
    the queue by the worker-thread model. The loop stops when the generation
    is torn down.
    """

    def __init__(self):
        self.loop = asyncio.new_event_loop()
        self.tasks = defaultdict(set)
        self._thread = None
        self._lock = threading.Lock()

    @property
    def thread(self):
        return self._thread

    @property
    def started(self):
        thread = self._thread
        return thread is not None and thread.is_alive()

    def _run_event_loop(self):
        asyncio.set_event_loop(self.loop)
        try:
            self.loop.run_forever()
        finally:
            try:
                pending = asyncio.all_tasks(self.loop)
                for task in pending:
                    task.cancel()
                if pending:
                    # Let cancelled tasks unwind; one that refuses is abandoned with the loop.
                    self.loop.run_until_complete(asyncio.wait(pending, timeout=1.0))
            except Exception:
                pass
            finally:
                self.loop.close()

    def _shutdown(self):
        if self.loop.is_closed():
            return
        if not self.started:
            self.loop.close()
            return
        try:
            self.loop.call_soon_threadsafe(self.loop.stop)
        except RuntimeError:
            pass

    def start(self):
        with self._lock:
            if self.started:
                _async_logger.warning("Async thread is already started.")
                return
            self._thread = threading.Thread(target=self._run_event_loop, daemon=True, name="ZwyAsyncThread")
            self._thread.start()

    def stop(self):
        for plugin_id in list(self.tasks):
            for task in self.tasks[plugin_id].copy():
                self.loop.call_soon_threadsafe(task.cancel)
            self.tasks[plugin_id].clear()

    def run_task(self, coro):
        if not self.started:
            self.start()
        plugin_id = _plugin_id()

        async def task_wrapper():
            current = asyncio.current_task()
            self.tasks[plugin_id].add(current)
            try:
                return await coro
            except asyncio.CancelledError:
                raise
            except Exception:
                _async_logger.error(f"Error in '{plugin_id}' task:", exc_info=True)
            finally:
                self.tasks[plugin_id].discard(current)

        return asyncio.run_coroutine_threadsafe(task_wrapper(), self.loop)

    def cancel_all_tasks(self):
        self.cancel_all_for(_plugin_id())

    def cancel_all_for(self, plugin_id):
        tasks = self.tasks.get(_plugin_id(plugin_id), set()).copy()
        for task in tasks:
            self.loop.call_soon_threadsafe(task.cancel)
        if tasks:
            self.tasks[plugin_id].clear()

    @staticmethod
    def as_callback(callback_obj, success, error=None):
        return _AsyncMarker(callback_obj, success, error)

    async def wrap_java_call(self, java_method, *args, **kwargs):
        future = asyncio.get_running_loop().create_future()
        arguments = list(args)
        for index, argument in enumerate(arguments):
            if isinstance(argument, _AsyncMarker):
                _wrap_callback_methods(argument, future)
                arguments[index] = argument.obj
                break
        try:
            java_method(*arguments, **kwargs)
        except Exception as error:
            if not future.done():
                future.set_exception(error)
        return await future


class _ScopedAsyncManager:
    """``zwylib.async_manager``: the async manager of the calling plugin generation."""

    def __getattr__(self, name):
        if name.startswith("__"):
            raise AttributeError(name)
        state = _state()
        if state.async_manager is None:
            import _ayu_threads
            manager = _AsyncManager()
            try:
                _ayu_threads.add_closer(manager._shutdown)
            except BaseException:
                manager.loop.close()
                raise
            state.async_manager = manager
        return getattr(state.async_manager, name)


async_manager = _ScopedAsyncManager()


def safe_func_call(func, args=None):
    if func is None:
        return None
    try:
        result = func(*(args or []))
        if asyncio.iscoroutine(result):
            return async_manager.run_task(result)
        return result
    except BridgeError:
        raise
    except Exception:
        _logger.error("An error occurred when tried to call func safely:", exc_info=True)
        return None


# ---- Java helpers -----------------------------------------------------------

class SingletonMeta(type):
    _instances = {}

    def __call__(cls, *args, **kwargs):
        if cls not in cls._instances:
            cls._instances[cls] = super().__call__(*args, **kwargs)
        return cls._instances[cls]


def _proxy(interface, method_name, function):
    from java import dynamic_proxy
    return type("ZwyProxy", (dynamic_proxy(runtime.jclass(interface)),), {method_name: function})()


def Callback1(fn):
    """``Utilities.Callback`` whose ``run(arg)`` calls ``fn(arg)``."""
    if not callable(fn):
        raise TypeError("Callback1 requires a callable")

    def run(self, arg):
        try:
            fn(arg)
        except BridgeError:
            raise
        except Exception:
            _logger.error("Error in Callback1.", exc_info=True)

    return _proxy("org.telegram.messenger.Utilities$Callback", "run", run)


def PyRunnable(fn):
    """``java.lang.Runnable`` whose ``run()`` calls ``fn()``."""
    if not callable(fn):
        raise TypeError("PyRunnable requires a callable")

    def run(self):
        try:
            fn()
        except BridgeError:
            raise
        except Exception:
            _logger.error("Error in PyRunnable:", exc_info=True)

    return _proxy("java.lang.Runnable", "run", run)


def arraylist_to_list(j_array_list):
    if not j_array_list:
        return None
    values = j_array_list.toArray()
    return values if isinstance(values, list) else list(values)


def iterable_to_arraylist(iterable, int_auto_convert=True):
    if iterable is None:
        return None
    from java import jint
    result = runtime.jclass("java.util.ArrayList")()
    for item in list(iterable):
        if int_auto_convert and isinstance(item, int):
            try:
                result.add(jint(item))
                continue
            except OverflowError:
                pass
        result.add(item)
    return result


def create_bundle(args):
    bundle = runtime.jclass("android.os.Bundle")()
    methods = {int: bundle.putInt, bool: bundle.putBoolean, str: bundle.putString, float: bundle.putFloat}
    for key, value in args.items():
        method = methods.get(type(value))
        if method is not None:
            method(key, value)
    return bundle


# ---- hooks ------------------------------------------------------------------

def _wrap_hook_callback(callback):
    def wrapped_hook_callback(param):
        return safe_func_call(callback, [param])
    return wrapped_hook_callback


class HookUtils:
    @staticmethod
    def _plugin(plugin_id=None):
        _plugin_id(plugin_id)
        plugin = runtime.require().instance
        if plugin is None:
            raise BridgeError("NO_PLUGIN_CONTEXT", "Hooks can be installed once the plugin instance exists")
        return plugin

    @classmethod
    def hook(cls, plugin_id, method_or_constructor, xposed_hook=None, priority=None, *,
             before=None, after=None, before_filters=None, after_filters=None):
        if xposed_hook is None and before is None and after is None:
            raise TypeError("xposed_hook or before or after cannot be None")
        options = {name: value for name, value in (
            ("before", before), ("after", after), ("before_filters", before_filters),
            ("after_filters", after_filters)) if value is not None}
        return cls._plugin(plugin_id).hook_method(method_or_constructor, xposed_hook, priority, **options)

    @classmethod
    def unhook(cls, unhook, plugin_id=None):
        return cls._plugin(plugin_id).unhook_method(unhook)

    @classmethod
    def get_private_field(cls, obj, field_name):
        if not isinstance(obj, RemoteObject) or not isinstance(field_name, str):
            return None
        from hook_utils import get_private_field
        try:
            return get_private_field(obj, field_name)
        except BridgeError as error:
            # ZwyLib answers None for a field it cannot read.
            _logger.error(f"Error accessing field '{field_name}': {error.code}")
            return None

    @staticmethod
    def _methods(clazz, method_name):
        if not clazz or isinstance(clazz, (str, bytes)):
            _hu_logger.warning(f"Error: got {type(clazz).__name__} instead of Class object")
            return None
        if isinstance(clazz, type):
            raise UnsupportedAPI("Reflection over a Python-local Java class requires a native adapter")
        if isinstance(clazz, JavaClass):
            clazz = clazz.getClass()
        return [method for method in clazz.getDeclaredMethods() if method.getName() == method_name]

    @staticmethod
    def _found(method, method_name, detail=""):
        if method is None:
            _hu_logger.warning(f"Cannot find method '{method_name}'{detail}.")
            return None
        method.setAccessible(True)
        return method

    @classmethod
    def find_method_by_args_count(cls, clazz, method_name, args_count=0):
        methods = cls._methods(clazz, method_name)
        if methods is None:
            return None
        method = next((item for item in methods if item.getParameterCount() == args_count), None)
        return cls._found(method, method_name, f" ({args_count} args)")

    @classmethod
    def find_method_by_args(cls, clazz, method_name, python_arg_types):
        methods = cls._methods(clazz, method_name)
        if methods is None:
            return None
        wanted = list(python_arg_types)
        method = next((item for item in methods
                       if all(left == right for left, right in zip(wanted, list(item.getParameterTypes())))), None)
        return cls._found(method, method_name)

    @classmethod
    def find_max_args_method(cls, clazz, method_name):
        methods = cls._methods(clazz, method_name)
        if methods is None:
            return None
        method = max(methods, key=lambda item: item.getParameterCount(), default=None)
        return cls._found(method, method_name)

    @classmethod
    def _checked(cls, member, callback):
        if member is None or not callable(callback):
            _hu_logger.warning("Invalid hook parameters: expected a class member and a callable")
            return False
        return True

    @classmethod
    def hook_before(cls, member, callback, **kwargs):
        if not cls._checked(member, callback):
            return None
        kwargs.pop("before", None)
        return cls.hook(None, member, before=_wrap_hook_callback(callback), **kwargs)

    @classmethod
    def hook_after(cls, member, callback, **kwargs):
        if not cls._checked(member, callback):
            return None
        kwargs.pop("after", None)
        return cls.hook(None, member, after=_wrap_hook_callback(callback), **kwargs)

    @classmethod
    def hook_replace(cls, member, callback, **kwargs):
        if not cls._checked(member, callback):
            return None
        wrapped = _wrap_hook_callback(callback)

        class ReplaceHook(MethodReplacement):
            def replace_hooked_method(self, param):
                return wrapped(param)

        kwargs.pop("xposed_hook", None)
        return cls.hook(None, member, ReplaceHook(), **kwargs)


def hook_max_args_method(clazz, method_name, hook_instance):
    method = HookUtils.find_max_args_method(clazz, method_name)
    if not method:
        _hu_logger.warning(f"Failed to hook {method_name}.")
        return
    HookUtils.hook(None, method, hook_instance)


# ---- versions ---------------------------------------------------------------

def _version(text):
    match = _VERSION.match(str(text))
    if match is None:
        raise ValueError(f"Invalid version: {text!r}")
    release = [int(part) for part in match.group(1).split(".")]
    while len(release) > 1 and release[-1] == 0:
        release.pop()
    # A pre-release sorts before the release it precedes.
    return tuple(release), 0 if match.group(2) else 1


def is_client_version_sufficient(version_to_compare):
    import _ayu_policy
    try:
        return _version(_ayu_policy.APP_VERSION) >= _version(version_to_compare)
    except ValueError:
        _logger.error("An error occurred:", exc_info=True)
    return False


def is_zwylib_version_sufficient(plugin_name, version, notify=True):
    is_sufficient = _version(__version__) >= _version(version)
    if notify and not is_sufficient:
        _bulletin.show_error(L.not_sufficient_zwylib_ver(
            plugin_name=plugin_name, version=version, cur_ver=__version__))
    return is_sufficient


# ---- bulletins --------------------------------------------------------------

class _InnerBulletinHelper(_BulletinHelper):
    def __init__(self, prefix=None):
        self.prefix = "" if not prefix or not prefix.strip() else f"{prefix}:"

    def _get_prefixed_text(self, text):
        return f"{self.prefix} {text}" if self.prefix else text

    def show_info(self, message, fragment=None):
        _BulletinHelper.show_info(self._get_prefixed_text(message), fragment)

    def show_error(self, message, fragment=None):
        _BulletinHelper.show_error(self._get_prefixed_text(message), fragment)

    def show_success(self, message, fragment=None):
        _BulletinHelper.show_success(self._get_prefixed_text(message), fragment)

    def _show_with_copy(self, style, message, text_to_copy):
        from android_utils import copy_to_clipboard
        text = str(text_to_copy)
        _BulletinHelper._show(style, self._get_prefixed_text(message), None, _BulletinHelper.DURATION_PROLONG,
                              str(L.copy_button), lambda: copy_to_clipboard(text))

    def show_info_with_copy(self, message, copy_text):
        self._show_with_copy("simple", message, copy_text)

    def show_error_with_copy(self, message, copy_text):
        self._show_with_copy("error", message, copy_text)

    def show_success_with_copy(self, message, copy_text):
        self._show_with_copy("success", message, copy_text)


def build_bulletin_helper(prefix=None):
    return _InnerBulletinHelper(prefix)


_bulletin = build_bulletin_helper()


# ---- settings ---------------------------------------------------------------

class SettingEntry:
    def __init__(self, key, default, icon=None):
        self.key = key
        self.default = default
        self.icon = icon
        self.plugin_id = _plugin_id()

    def get(self):
        return SettingsManager.get(self.plugin_id, self)

    def safe_get(self, factory, bulletin_text=None, log_text=None):
        try:
            return factory(self.get())
        except BridgeError:
            raise
        except Exception:
            _logger.error(log_text or f"Error getting setting '{self.key}', using default instead. Trace:",
                          exc_info=True)
            if bulletin_text:
                _bulletin.show_error(bulletin_text)
            return factory(self.default)

    def set(self, value):
        SettingsManager.set(self.plugin_id, self.key, value)

    def _bind(self, component_cls, **kwargs):
        kwargs["key"] = self.key
        kwargs["default"] = self.default
        if self.icon:
            kwargs["icon"] = self.icon
        return component_cls(**kwargs)

    def as_input(self, **kwargs):
        from ui.settings import Input
        return self._bind(Input, **kwargs)

    def as_selector(self, **kwargs):
        from ui.settings import Selector
        return self._bind(Selector, **kwargs)

    def as_switch(self, **kwargs):
        from ui.settings import Switch
        return self._bind(Switch, **kwargs)


class SettingsManager:
    @classmethod
    def get(cls, plugin_id, item, default=None):
        import plugin_settings
        if isinstance(item, SettingEntry):
            return plugin_settings.get_setting(plugin_id, item.key, item.default)
        return plugin_settings.get_setting(plugin_id, item, default)

    @classmethod
    def set(cls, plugin_id, item, value, reload_settings=True):
        import plugin_settings
        key = item.key if isinstance(item, SettingEntry) else item
        plugin_settings.set_setting(plugin_id, key, value, reload_settings=bool(reload_settings))

    @classmethod
    def reload(cls, plugin_id=None):
        """Ask the host to rebuild the settings screen (an unchanged, reloading write)."""
        import plugin_settings
        plugin_id = _plugin_id(plugin_id)
        plugin_settings.set_all_settings(plugin_id, plugin_settings.get_all_settings(plugin_id),
                                         reload_settings=True)

    @classmethod
    def remove_setting(cls, key, plugin_id=None):
        import plugin_settings
        plugin_id = _plugin_id(plugin_id)
        values = plugin_settings.get_all_settings(plugin_id)
        if key in values:
            del values[key]
            plugin_settings.set_all_settings(plugin_id, values)


# ---- cache files ------------------------------------------------------------

def _cache_directory():
    from file_utils import get_plugins_dir
    path = os.path.join(get_plugins_dir(), "cache")
    os.makedirs(path, exist_ok=True)
    return path


class CacheFile:
    def __init__(self, filename, read_on_init=True, compress=False):
        if not isinstance(filename, str) or not filename or os.path.basename(filename) != filename \
                or filename in (".", ".."):
            raise ValueError("Cache file name must be a plain file name")
        self.filename = filename
        self.path = os.path.join(_cache_directory(), filename)
        self._content = b""
        self.compress = compress
        self.logger = build_log(_ID + ".cache")
        if read_on_init:
            self.read()

    def read(self):
        if not os.path.exists(self.path):
            return
        try:
            with open(self.path, "rb") as file:
                content = file.read()
        except OSError:
            self.logger.error(f"Failed to load data from '{self.filename}':", exc_info=True)
            return
        if not content:
            return
        if len(content) >= 2 and (content[0] & 0x0F) == 8 and (content[0] * 256 + content[1]) % 31 == 0:
            try:
                content = zlib.decompress(content)
            except zlib.error:
                self.logger.error(f"Header matched in '{self.filename}' but decompress failed:", exc_info=True)
        self._content = content

    def write(self):
        data = self._content if self._content is not None else b""
        if self.compress and data:
            data = zlib.compress(data, level=6)
        try:
            with open(self.path, "wb") as file:
                file.write(data)
        except PermissionError:
            self.logger.error(f"Have no permissions to edit '{self.filename}':", exc_info=True)

    def wipe(self):
        self._content = b""
        self.write()

    def delete(self):
        if not os.path.exists(self.path):
            self.logger.error(f"File '{self.filename}' does not exist.")
            return
        try:
            os.remove(self.path)
        except OSError:
            self.logger.error(f"Failed to delete '{self.filename}':", exc_info=True)

    @property
    def content(self):
        return self._content

    @content.setter
    def content(self, value):
        self._content = value


class JsonCacheFile(CacheFile):
    def __init__(self, filename, default, read_on_init=True, compress=False):
        self._default = default
        self.json_content = self._get_copy_of_default()
        super().__init__(filename, read_on_init, compress)

    def _get_copy_of_default(self):
        return copy.deepcopy(self._default)

    def read(self):
        super().read()
        if not self._content:
            self.json_content = self._get_copy_of_default()
            return
        try:
            self.json_content = json.loads(self._content.decode("utf-8", errors="replace"))
        except ValueError:
            self.logger.error(f"Failed to load JSON from '{self.filename}':", exc_info=True)
            self.json_content = self._get_copy_of_default()

    def write(self):
        self._content = json.dumps(self.json_content, ensure_ascii=False).encode("utf-8", errors="replace")
        super().write()

    def wipe(self):
        self.json_content = self._get_copy_of_default()
        self.write()

    @property
    def content(self):
        return self.json_content

    @content.setter
    def content(self, value):
        self.json_content = value


# ---- Telegram requests ------------------------------------------------------

def _tlrpc():
    return runtime.jclass("org.telegram.tgnet.TLRPC")


def _is_updates(value):
    if isinstance(value, RemoteObject):
        return value._class_name == "org.telegram.tgnet.TLRPC$TL_updates"
    return type(value).__name__ == "TL_updates"


def process_updates(updates):
    if not _is_updates(updates):
        return
    from client_utils import get_messages_controller
    get_messages_controller().processUpdates(updates, False)


def _request_callback_factory(callback):
    def inner_callback(response, error):
        process_updates(response)
        if callback:
            callback(response, error)
    return inner_callback


class Requests:
    @staticmethod
    def send(req, callback, delay=None, **kwargs):
        from android_utils import run_on_ui_thread
        from client_utils import send_request
        for name, value in kwargs.items():
            setattr(req, name, value)
        run_on_ui_thread(lambda: send_request(req, _request_callback_factory(callback)), delay=delay or 0)

    @classmethod
    async def async_send(cls, req, delay=None, **kwargs):
        loop = asyncio.get_running_loop()
        future = loop.create_future()

        def callback(response, error):
            def settle():
                if future.done():
                    return
                if error:
                    future.set_exception(Exception(f"Error {error.code}: {error.text}"))
                else:
                    future.set_result(response)
            loop.call_soon_threadsafe(settle)

        cls.send(req, callback, delay, **kwargs)
        return await future

    @staticmethod
    def reload_admins(chat_id):
        from client_utils import get_messages_controller
        get_messages_controller().loadChannelAdmins(chat_id, False)

    @staticmethod
    def delete_messages(messages, peer_id, topic_id=None):
        from android_utils import run_on_ui_thread
        from client_utils import get_messages_controller
        run_on_ui_thread(lambda: get_messages_controller().deleteMessages(
            iterable_to_arraylist(messages), None, None, peer_id, topic_id or 0, True, 0))

    @staticmethod
    async def change_slowmode(chat_id, seconds=0, delay=0):
        from client_utils import get_messages_controller
        process_updates(await Requests.async_send(
            _tlrpc().TL_channels_toggleSlowMode(), delay,
            channel=get_messages_controller().getInputChannel(chat_id), seconds=seconds))

    @staticmethod
    async def ban(chat_id, peer_id, until_date=None, delay=0):
        from client_utils import get_messages_controller
        banned_rights = _tlrpc().TL_chatBannedRights()
        banned_rights.until_date = until_date or 0
        for name in ("view_messages", "send_messages", "send_media", "send_stickers", "send_gifs", "send_games",
                     "send_inline", "embed_links", "send_polls", "change_info", "invite_users", "pin_messages",
                     "manage_topics", "send_photos", "send_videos", "send_roundvideos", "send_audios",
                     "send_voices", "send_docs", "send_plain"):
            setattr(banned_rights, name, True)
        controller = get_messages_controller()
        process_updates(await Requests.async_send(
            _tlrpc().TL_channels_editBanned(), delay, participant=controller.getInputPeer(peer_id),
            channel=controller.getInputChannel(controller.getChat(chat_id)), banned_rights=banned_rights))

    @staticmethod
    async def unban(chat_id, target_peer_id, delay=0):
        from client_utils import get_messages_controller
        controller = get_messages_controller()
        await Requests.async_send(
            _tlrpc().TL_channels_editBanned(), delay, participant=controller.getInputPeer(target_peer_id),
            channel=controller.getInputChannel(chat_id), banned_rights=_tlrpc().TL_chatBannedRights())

    @classmethod
    async def get_message(cls, peer_id, message_id):
        return await cls.get_messages(peer_id, [message_id])

    @staticmethod
    async def get_messages(peer_id, messages):
        from client_utils import get_messages_controller
        controller = get_messages_controller()
        if runtime.jclass("org.telegram.messenger.ChatObject").isChannel(controller.getChat(-peer_id)):
            req = _tlrpc().TL_channels_getMessages()
            req.channel = controller.getInputChannel(-peer_id)
        else:
            req = _tlrpc().TL_messages_getMessages()
        return await Requests.async_send(req, id=iterable_to_arraylist(messages))

    @staticmethod
    async def search_messages(peer_id, delay=0, **kwargs):
        from client_utils import get_messages_controller
        controller = get_messages_controller()
        req = _tlrpc().TL_messages_search()
        req.peer = controller.getInputPeer(peer_id)
        req.filter = kwargs.pop("filter", None) or _tlrpc().TL_inputMessagesFilterEmpty()
        req.q = kwargs.pop("q", "")
        from_id = kwargs.pop("from_id", None)
        if from_id:
            req.from_id = controller.getInputPeer(from_id)
            req.flags |= 1
        top_msg_id = kwargs.pop("top_msg_id", None)
        if top_msg_id:
            req.top_msg_id = top_msg_id
            req.flags |= 2
        saved_peer_id = kwargs.pop("saved_peer_id", None)
        if saved_peer_id:
            req.saved_peer_id = controller.getInputPeer(saved_peer_id)
            req.flags |= 4
        saved_reaction = kwargs.pop("saved_reaction", None)
        if saved_reaction:
            req.saved_reaction.add(saved_reaction.toTLReaction())
            req.flags |= 8
        return await Requests.async_send(req, delay, **kwargs)

    @staticmethod
    async def get_chat_participant(chat_id, target_peer_id):
        from client_utils import get_messages_controller
        controller = get_messages_controller()
        return await Requests.async_send(
            _tlrpc().TL_channels_getParticipant(), channel=controller.getInputChannel(chat_id),
            participant=controller.getInputPeer(target_peer_id))


# ---- autoupdater ------------------------------------------------------------

@dataclass
class _UpdaterTask:
    plugin_id: str
    channel_id: int
    message_id: int


def add_autoupdater_task(plugin_id, channel_id, message_id=None):
    """Record an autoupdate source: ``(channel_id, message_id)`` or ``(plugin_id, channel_id, message_id)``.

    Only the record is kept. Plugins reach iOS through an explicit import, so
    nothing downloads or installs the referenced file.
    """
    if isinstance(plugin_id, int):
        channel_id, message_id = plugin_id, channel_id
        plugin_id = None
    task = _UpdaterTask(_plugin_id(plugin_id), channel_id, message_id)
    tasks = _state().autoupdater_tasks
    if task not in tasks:
        tasks.append(task)
        _logger.warning(f"Autoupdate task for '{task.plugin_id}' is recorded only: plugins are not auto-updated on iOS.")


def remove_autoupdater_task(plugin_id=None):
    plugin_id = _plugin_id(plugin_id)
    state = _state()
    state.autoupdater_tasks = [task for task in state.autoupdater_tasks if task.plugin_id != plugin_id]


# ---- commands ---------------------------------------------------------------

class CannotCastError(Exception):
    pass


class WrongArgumentAmountError(Exception):
    pass


class MissingRequiredArguments(Exception):
    pass


class InvalidTypeError(Exception):
    pass


@dataclass
class _ArgSpec:
    name: str
    annotation: Any
    kind: Any
    default: Any = inspect.Parameter.empty
    is_optional: bool = False

    @classmethod
    def from_parameter(cls, param):
        annotation = param.annotation if param.annotation != inspect.Parameter.empty else Any
        is_optional = get_origin(annotation) in (Union, Optional) and type(None) in get_args(annotation)
        return cls(param.name, annotation, param.kind, param.default, is_optional)


@dataclass
class _Command:
    func: Any
    name: str
    aliases: list = field(default_factory=list)
    args: list = field(default_factory=list)
    subcommands: dict = field(default_factory=dict)
    error_handler: Any = None

    def stub_subcommand(self, name):
        command = _InternalCmdUtils.create_stub_command(name)
        _InternalCmdUtils.register_command(self.subcommands, command, self.name, True)
        return command

    def subcommand(self, name, aliases=None):
        def decorator(func):
            command = _InternalCmdUtils.create_command(func, name)
            if aliases:
                command.aliases = aliases
            _InternalCmdUtils.register_command(self.subcommands, command, self.name, True)
            return command
        return decorator

    def register_error_handler(self, func):
        if len(inspect.signature(func).parameters) != 3:
            raise MissingRequiredArguments("Error handler must have only 'param', 'account' and 'exception' arguments.")
        self.error_handler = func
        return func


class _InternalCmdUtils:
    @staticmethod
    def register_command(target, command, plugin_id, is_subcommand=False):
        kind = "Subcommand" if is_subcommand else "Command"
        names = [command.name] + command.aliases
        for name in names:
            if not name or " " in name:
                _cmd_logger.error(f"{kind} name/alias must be nonempty and contain no spaces.")
                return
        for name in names:
            if name in target:
                _cmd_logger.error(f"{kind} name/alias '{name}' is already registered.")
                return
        for name in names:
            target[name] = command

    @staticmethod
    def _is_allowed_type(arg_type):
        if arg_type in _ALLOWED_ARG_TYPES or arg_type is type(None):
            return True
        if get_origin(arg_type) in _ALLOWED_ORIGIN:
            return all(_InternalCmdUtils._is_allowed_type(item) for item in get_args(arg_type))
        return False

    @staticmethod
    def _cast_arg(arg, target_type):
        if target_type == str or target_type == Any:
            return arg
        if target_type == int:
            return int(arg)
        if target_type == float:
            return float(arg)
        if target_type == bool:
            if arg.lower() in ("true", "1", "yes", "on"):
                return True
            if arg.lower() in ("false", "0", "no", "off"):
                return False
            raise CannotCastError(f"Cannot cast '{arg}' to bool")
        raise CannotCastError(f"Unsupported target type: {target_type}")

    @staticmethod
    def _smart_cast(arg, annotation):
        if annotation in _ALLOWED_ARG_TYPES:
            try:
                return _InternalCmdUtils._cast_arg(arg, annotation)
            except Exception:
                raise CannotCastError(f"Could not cast '{arg}' to {annotation}")
        if get_origin(annotation) is Union:
            for possible in get_args(annotation):
                if possible is type(None):
                    continue
                try:
                    return _InternalCmdUtils._cast_arg(arg, possible)
                except Exception:
                    continue
            raise CannotCastError(f"Could not cast '{arg}' to any of: {get_args(annotation)}")
        raise CannotCastError(f"Unsupported annotation: {annotation}")

    @staticmethod
    def parse_args(raw_args, command_args):
        out = []
        variadic = inspect.Parameter.VAR_POSITIONAL
        required = sum(1 for arg in command_args if not arg.is_optional
                       and arg.default == inspect.Parameter.empty and arg.kind != variadic)
        if not any(arg.kind == variadic for arg in command_args) and len(raw_args) > len(command_args):
            raise WrongArgumentAmountError(f"Expected at most {len(command_args)} arguments, got {len(raw_args)}.")
        if len(raw_args) < required:
            raise WrongArgumentAmountError(f"Expected at least {required} arguments, got {len(raw_args)}.")
        for index, spec in enumerate(command_args):
            if spec.kind == variadic:
                out.extend(_InternalCmdUtils._smart_cast(arg, spec.annotation) for arg in raw_args[index:])
                break
            if index < len(raw_args):
                out.append(_InternalCmdUtils._smart_cast(raw_args[index], spec.annotation))
            elif spec.default != inspect.Parameter.empty:
                out.append(spec.default)
            elif spec.is_optional:
                out.append(None)
            else:
                raise WrongArgumentAmountError(
                    f"Expected argument {index} of type {spec.annotation}, but none provided.")
        return tuple(out)

    @staticmethod
    def create_command(func, name):
        try:
            # Annotations are strings under ``from __future__ import annotations``.
            signature = inspect.signature(func, eval_str=True)
        except Exception:
            signature = inspect.signature(func)
        parameters = list(signature.parameters.values())
        if len(parameters) < 2:
            raise MissingRequiredArguments(
                "Command must have 'param' variable as first argument and 'account' variable as second argument")
        args = [_ArgSpec.from_parameter(param) for param in parameters]
        for index, arg in enumerate(args):
            checked = (get_origin(arg.annotation) or arg.annotation) \
                if arg.kind == inspect.Parameter.VAR_POSITIONAL else arg.annotation
            if not _InternalCmdUtils._is_allowed_type(checked):
                raise InvalidTypeError(f"Command argument (index: {index}) has an unsupported type: {arg.annotation}")
        return_type = signature.return_annotation
        if inspect.iscoroutinefunction(func):
            if return_type not in (inspect.Parameter.empty, None):
                raise InvalidTypeError(f"Async command function must return NoneType, got {return_type}")
        elif return_type != HookResult:
            raise InvalidTypeError(f"Command function must return {HookResult} object, got {return_type}")
        return _Command(func=func, name=name, args=args)

    @staticmethod
    def stub_command_callback(_, __, *args) -> HookResult:
        _bulletin.show_info(L.likely_cmd_name_misspelling if args else L.stub_command_message)
        return HookResult(strategy=HookStrategy.CANCEL)

    @staticmethod
    def create_stub_command(name):
        return _Command(func=_InternalCmdUtils.stub_command_callback, name=name, args=list(_stub_command_args))

    @staticmethod
    def show_command_exception(cmd, exc, from_err_handler=False):
        message = f"Uncaught exception occurred while the execution of '{cmd.name}' command"
        if from_err_handler:
            message += "'s ERROR HANDLER"
        message += ":\n" + format_exc_from(exc)
        _cmd_logger.error(message)
        _bulletin.show_error_with_copy(L.command_execution_error(cmd_name=cmd.name), message)


_stub_command_args = [_ArgSpec.from_parameter(param) for param in
                      inspect.signature(_InternalCmdUtils.stub_command_callback).parameters.values()]


class Dispatcher:
    def __init__(self, plugin_id, prefix, commands_priority):
        self.plugin_id = plugin_id
        self.prefix = prefix
        self.commands_priority = commands_priority
        self.listeners = {}

    @staticmethod
    def validate_prefix(prefix):
        return bool(prefix) and " " not in prefix

    def set_prefix(self, prefix):
        if not self.validate_prefix(prefix):
            _cmd_logger.error(f"{self.plugin_id} dp: Prefix validation failed.")
            return
        self.prefix = prefix
        command_manager.update_dispatcher_prefix_cache(self.plugin_id)

    def register_command(self, name, aliases=None):
        def decorator(func):
            command = _InternalCmdUtils.create_command(func, name)
            if aliases:
                command.aliases = aliases
            _InternalCmdUtils.register_command(self.listeners, command, self.plugin_id)
            return command
        return decorator

    def register_stub_command(self, name):
        command = _InternalCmdUtils.create_stub_command(name)
        _InternalCmdUtils.register_command(self.listeners, command, self.plugin_id)
        return command

    def unregister_command(self, name):
        self.listeners.pop(name, None)


class _CommandManager:
    """Dispatches the calling plugin's text commands from its own send-message hook."""

    def __init__(self):
        self._dispatchers = {}
        self._prefixes_cache = JsonCacheFile("zwylib__cmds_prefixes", {})
        self._hook = None

    def _ensure_hook(self, priority):
        if self._hook is not None:
            return
        from base_plugin import _SendMessageParams

        def on_send_message(account, params):
            from client_utils import account_scope
            if isinstance(params, dict):
                params = _SendMessageParams(params)
            with account_scope(account):
                return self.handle_send_message_hook(params, account)

        self._hook = runtime.register("hook", {"kind": "send_message", "priority": int(priority),
                                               "callback": on_send_message})

    def get_dispatcher(self, plugin_id=None, prefix="default", commands_priority=-1):
        plugin_id = _plugin_id(plugin_id)
        if not prefix or prefix == "default":
            prefix = DEFAULT_COMMAND_PREFIX
        if plugin_id in self._prefixes_cache.content:
            prefix = self._prefixes_cache.content[plugin_id]
        if plugin_id not in self._dispatchers:
            self._ensure_hook(commands_priority)
            self._dispatchers[plugin_id] = Dispatcher(plugin_id, prefix, commands_priority)
        return self._dispatchers[plugin_id]

    def remove_dispatcher(self, plugin_id=None):
        self._dispatchers.pop(_plugin_id(plugin_id), None)

    def unregister_all(self):
        self._dispatchers.clear()

    def update_dispatcher_prefix_cache(self, plugin_id):
        dispatcher = self.get_dispatcher(plugin_id)
        if dispatcher.prefix == DEFAULT_COMMAND_PREFIX:
            self._prefixes_cache.content.pop(plugin_id, None)
        else:
            self._prefixes_cache.content[plugin_id] = dispatcher.prefix
        self._prefixes_cache.write()

    def handle_send_message_hook(self, params, account):
        original_text = getattr(params, "message", None)
        if not original_text:
            return HookResult()
        for dispatcher in list(self._dispatchers.values()):
            if not original_text.startswith(dispatcher.prefix):
                continue
            args = shlex.split(original_text[len(dispatcher.prefix):].strip())
            if not args:
                continue
            cmd = dispatcher.listeners.get(args[0])
            if not cmd:
                continue
            args = args[1:]
            while args and args[0] in cmd.subcommands:
                cmd = cmd.subcommands[args[0]]
                args = args[1:]
            args[0:0] = [params, account]
            try:
                parsed_args = _InternalCmdUtils.parse_args(args, cmd.args)
                if inspect.iscoroutinefunction(cmd.func):
                    async_manager.run_task(cmd.func(*parsed_args))
                    return HookResult(strategy=HookStrategy.CANCEL)
                return cmd.func(*parsed_args)
            except BridgeError:
                raise
            except Exception as error:
                if not cmd.error_handler:
                    _InternalCmdUtils.show_command_exception(cmd, error)
                    return HookResult(strategy=HookStrategy.CANCEL)
                try:
                    if inspect.iscoroutinefunction(cmd.error_handler):
                        async_manager.run_task(cmd.error_handler(params, account, error))
                        return HookResult(strategy=HookStrategy.CANCEL)
                    return cmd.error_handler(params, account, error)
                except BridgeError:
                    raise
                except Exception as handler_error:
                    _InternalCmdUtils.show_command_exception(cmd, handler_error, from_err_handler=True)
                    return HookResult(strategy=HookStrategy.CANCEL)
        return HookResult()


class _ScopedCommandManager:
    """``zwylib.command_manager``: the command manager of the calling plugin generation."""

    def __getattr__(self, name):
        if name.startswith("__"):
            raise AttributeError(name)
        state = _state()
        if state.command_manager is None:
            state.command_manager = _CommandManager()
        return getattr(state.command_manager, name)


command_manager = _ScopedCommandManager()


# ---- dialogs ----------------------------------------------------------------

class UI:
    """ZwyLib's alert helpers. Its popup menus, input dialogs and bottom sheets
    are built from Android views and are not provided."""

    @dataclass
    class AlertButton:
        text: str
        on_click: Any = None
        type: int = -1
        red: bool = False

    class AlertDialog:
        def __init__(self, title, text, buttons):
            self.text = text
            self.title = title
            self.buttons = buttons
            self._builder = None

        def show(self):
            from client_utils import get_last_fragment
            from ui.alert import AlertDialogBuilder
            builder = self._builder
            if builder is not None and builder.get_dialog().isShowing():
                _logger.warning("Alert already shown.")
                return
            fragment = get_last_fragment()
            builder = AlertDialogBuilder(fragment.getParentActivity() if fragment is not None else None,
                                         AlertDialogBuilder.ALERT_TYPE_MESSAGE)
            builder.set_title(self.title)
            builder.set_message(self.text)
            builder.create()
            builder.set_cancelable(True)
            builder.set_canceled_on_touch_outside(True)
            for button in self.buttons:
                if not button:
                    continue
                if button.type == AlertDialogBuilder.BUTTON_POSITIVE:
                    builder.set_positive_button(button.text, button.on_click)
                elif button.type == AlertDialogBuilder.BUTTON_NEGATIVE:
                    builder.set_negative_button(button.text, button.on_click)
                elif button.type == AlertDialogBuilder.BUTTON_NEUTRAL:
                    builder.set_neutral_button(button.text, button.on_click)
                if button.red:
                    builder.make_button_red(button.type)
            builder.show()
            self._builder = builder

        def dismiss(self):
            builder, self._builder = self._builder, None
            if builder is not None:
                builder.dismiss()

    class SelectorDialog:
        @classmethod
        async def show(cls, title, items, current_index=-1):
            """Resolve to the chosen index, or None when the dialog is cancelled by its button."""
            from android_utils import run_on_ui_thread
            from client_utils import get_last_fragment
            from ui.alert import AlertDialogBuilder
            future = asyncio.get_running_loop().create_future()

            def show_on_ui():
                fragment = get_last_fragment()
                if not fragment:
                    _safe_set_future_result(future, None)
                    return
                builder = AlertDialogBuilder(fragment.getParentActivity())
                builder.set_title(title)
                builder.set_items([("\u2713 " if index == current_index else "") + str(item)
                                   for index, item in enumerate(items)],
                                  lambda _, which: _safe_set_future_result(future, which))
                builder.set_negative_button(str(L.alert_cancel))
                builder.set_on_dismiss_listener(lambda _: _safe_set_future_result(future, None))
                builder.show()

            run_on_ui_thread(show_on_ui)
            return await future
