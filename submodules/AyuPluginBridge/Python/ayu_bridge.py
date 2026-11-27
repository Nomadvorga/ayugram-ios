"""Owned Python SDK transport for AyuPluginBridge (protocol 1).

This is a compatibility boundary, not a Python security sandbox. Only the native
host may create handles, declare Java classes or approve a plugin for execution.
All public entry points must run on the same native-owned Python serial queue.
"""
from __future__ import annotations

import ast
import contextlib
import contextvars
import enum
import importlib.abc
import importlib.machinery
import itertools
import json
import math
import os
import re
import sys
import threading
import time
import types
import uuid
import weakref
from dataclasses import dataclass, field
from typing import Any

import _ayu_javalib
import _ayu_members
import _ayu_operations
import _ayu_policy
import _ayu_threads
from _ayu_inspection import NATIVE_PREFIXES, NATIVE_ROOTS, import_inventory, member_inventory

VERSION = 1
# Transport bounds shared with the native side (protocol.md, "Limits and validation").
MAX_JSON_CHARS = 6_000_000
MAX_REQUEST_BYTES = 262_144
MAX_TL_REQUEST_BYTES = 1_572_864
MAX_RESULT_BYTES = 1_048_576
SDK_MODULES = frozenset({
    "ayu_bridge", "base_plugin", "client_utils", "android_utils", "hook_utils",
    "plugin_settings", "zwylib", "java", "java.chaquopy", "jarray", "tlrpc", "ui", "ui.settings",
    "ui.alert", "ui.bulletin", "log_utils", "markdown_utils", "file_utils", "intents",
    "extera_utils", "extera_utils.classes", "extera_utils.lifecycle",
    "extera_utils.text_formatting", "extera_utils.get_caller", "extera_utils.metadata_parser",
    "_sdk_version", "elyx", "elyxcore", "elyxcore.assets", "elyxcore.localization", "elyxcore.settings",
    "elyxcore.utils", "audioop",
    "PIL", "PIL.Image", "PIL.ImageChops", "PIL.ImageColor", "PIL.ImageDraw", "PIL.ImageEnhance", "PIL.ImageFilter",
    "PIL.ImageFont", "PIL.ImageOps",
})
UNSUPPORTED_IMPORTS = {
    "_thread": "Low-level thread creation is unsupported; use threading",
    "multiprocessing": "Launching Python processes is unsupported",
    "subprocess": "Launching native processes is unsupported",
    "ctypes": "Dynamic native symbol access is unsupported; use explicit host adapters",
}
_ID = re.compile(r"^[A-Za-z][A-Za-z0-9_-]{1,31}$")
_METADATA_KEYS = frozenset({
    "__id__", "__name__", "__description__", "__author__", "__version__", "__icon__",
    "__min_version__", "__requirements__", "__app_version__", "__sdk_version__", "__category__",
    "__bridge_operations__",
})
_current = contextvars.ContextVar("ayu_plugin_scope", default=None)


class BridgeError(RuntimeError):
    def __init__(self, code: str, message: str):
        self.code = code
        self.message = message
        super().__init__(f"{code}: {message}")


class ProtocolError(BridgeError):
    def __init__(self, message: str):
        super().__init__("PROTOCOL_ERROR", message)


class DeliveryExpired(BridgeError):
    """A delivery for a callback or generation that was released while it waited.

    Raised by the embedding entry points only, before any plugin code runs. The runtime
    answers it with its own error code, and the embedding drops the delivery without
    flagging the plugin: a cancelled timer or a removed listener never runs.
    """


class UnsupportedAPI(BridgeError):
    def __init__(self, message: str):
        super().__init__("UNSUPPORTED_API", message)


class MissingMember(UnsupportedAPI, AttributeError):
    """A member the host class does not provide; ``hasattr`` and ``getattr`` defaults see it as absent."""


def _inventory(tree):
    try:
        return import_inventory(tree, SDK_MODULES)
    except (ValueError, RecursionError, OSError, UnicodeError, SyntaxError) as error:
        raise BridgeError("LOAD_REJECTED", "Static SDK inventory is invalid or exceeds its limits") from error


def _object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ProtocolError("Duplicate JSON key")
        result[key] = value
    return result


def parse_json(text):
    if not isinstance(text, str) or len(text) > MAX_JSON_CHARS:
        raise ProtocolError("Expected bounded JSON text")
    try:
        return json.loads(text, object_pairs_hook=_object,
                          parse_constant=lambda _: (_ for _ in ()).throw(ProtocolError("Nonfinite JSON number")))
    except (ValueError, RecursionError) as error:
        raise ProtocolError("Invalid JSON") from error


@dataclass
class Scope:
    plugin_id: str
    generation: str = field(default_factory=lambda: uuid.uuid4().hex)
    state: str = "loading"
    callbacks: dict = field(default_factory=dict)
    registrations: dict = field(default_factory=dict)
    module: Any = None
    module_key: str = ""
    source_filename: str = ""
    metadata: dict = field(default_factory=dict)
    settings_callbacks: set = field(default_factory=set)
    instance: Any = None
    remotes: Any = field(default_factory=weakref.WeakValueDictionary, repr=False, compare=False)


class RemoteObject:
    """A native object reference bound to one plugin load generation."""
    def __init__(self, runtime, scope, handle, class_name):
        object.__setattr__(self, "_runtime", runtime)
        object.__setattr__(self, "_scope", scope)
        object.__setattr__(self, "_handle", handle)
        object.__setattr__(self, "_class_name", class_name)

    def __repr__(self):
        return f"<native {self._class_name}>"

    def __str__(self):
        # Chaquopy's str() of a Java object is its toString(); a class without one keeps the repr.
        try:
            text = self._runtime.member(self._target(), "toString")()
        except BridgeError:
            return repr(self)
        return text if isinstance(text, str) else repr(self)

    def __eq__(self, other):
        # Two references to one host object are that object, as `==` is on Java references.
        if not isinstance(other, RemoteObject):
            return NotImplemented
        return self._scope is other._scope and self._handle == other._handle

    def __hash__(self):
        return hash(self._handle)

    def __bool__(self):
        self._runtime.require(self._scope)
        return True

    def _target(self):
        self._runtime.require(self._scope)
        return {"$handle": self._handle, "$class": self._class_name}

    def __getattr__(self, name):
        if name.startswith("_"):
            raise AttributeError(name)
        return self._runtime.member(self._target(), name)

    def __setattr__(self, name, value):
        if name.startswith("_"):
            raise AttributeError("Native reference internals are read-only")
        self._runtime.call("java.set_field", {"target": self, "name": name, "value": value})

    def __len__(self):
        value = self._runtime.call("java.length", {"target": self})
        if type(value) is not int or value < 0:
            raise ProtocolError("Invalid native collection length")
        return value

    def __getitem__(self, index):
        if type(index) is not int:
            raise TypeError("Native collection requires an integer index")
        if index < 0:
            index += len(self)
        if index < 0 or index >= len(self):
            raise IndexError(index)
        return self._runtime.call("java.get_item", {"target": self, "index": index})

    def __setitem__(self, index, value):
        if type(index) is not int or index < 0 or index >= len(self):
            raise IndexError(index)
        self._runtime.call("java.set_item", {"target": self, "index": index, "value": value})

    def __iter__(self):
        for index in range(len(self)):
            yield self[index]


class NativeMethod:
    def __init__(self, runtime, scope, target, name):
        self.runtime, self.scope, self.target, self.name = runtime, scope, target, name

    def __call__(self, *args, **kwargs):
        self.runtime.require(self.scope)
        return self.runtime.call("java.invoke", {"target": self.target, "name": self.name,
                                                  "args": list(args), "kwargs": kwargs})


class JavaClass:
    def __init__(self, runtime, scope, name):
        object.__setattr__(self, "_runtime", runtime)
        object.__setattr__(self, "_scope", scope)
        object.__setattr__(self, "_name", name)

    def _target(self):
        self._runtime.require(self._scope)
        return {"class_name": self._name}

    def __call__(self, *args, **kwargs):
        self._runtime.require(self._scope)
        return self._runtime.call("java.construct", {"class_name": self._name,
                                                     "args": list(args), "kwargs": kwargs})

    def __getattr__(self, name):
        if name.startswith("_"):
            raise AttributeError(name)
        return self._runtime.member(self._target(), name)

    def __setattr__(self, name, value):
        if name.startswith("_"):
            raise AttributeError("Java class internals are read-only")
        self._runtime.call("java.set_field", {"target": self._target(), "name": name, "value": value})

    def __repr__(self):
        return f"<declared Java class {self._name}>"


class DynamicProxy:
    """Base for explicitly declared native listener adapters."""
    _ayu_interfaces = ()

    def __init__(self, *args, **kwargs):
        if args or kwargs:
            raise TypeError("Proxy constructor does not accept native arguments")
        self._ayu_scope = runtime.require()
        self._ayu_native = None

    def _reference(self):
        scope = runtime.require(self._ayu_scope)
        if self._ayu_native is None:
            callbacks = {}
            for name in self._ayu_interfaces_methods:
                method = getattr(self, name, None)
                if not callable(method):
                    raise UnsupportedAPI(f"Proxy listener has no implementation: {name}")
                callbacks[name] = runtime.callback(method)
            self._ayu_native = runtime.call("java.proxy", {"interfaces": list(self._ayu_interfaces),
                                                            "callbacks": callbacks})
            if not isinstance(self._ayu_native, RemoteObject):
                raise ProtocolError("java.proxy must return a native handle")
        return self._ayu_native


class Registration:
    def __init__(self, runtime, scope, kind, token, callback_ids=()):
        self.runtime, self.scope, self.kind, self.token = runtime, scope, kind, token
        self.callback_ids, self.closed = set(callback_ids), False
        scope.registrations[(kind, token)] = self

    def cancel(self):
        if self.closed:
            return
        self.runtime.require(self.scope)
        operation = {"schedule": "scheduler.cancel", "hook": "hooks.unregister",
                     "menu": "menus.unregister"}[self.kind]
        try:
            self.runtime.call(operation, {"token": self.token})
        finally:
            self._forget()

    def _forget(self):
        self.closed = True
        self.scope.registrations.pop((self.kind, self.token), None)
        for callback_id in self.callback_ids:
            self.scope.callbacks.pop(callback_id, None)

    unhook = cancel
    dispose = cancel


class Runtime:
    def __init__(self):
        self.thread_id = None
        self.scopes = {}
        self.request_ids = itertools.count(1)
        self.capabilities = None
        self.execution_limits = {"load": 2.0, "callback": 0.25, "event": 0.25,
                                 "settings": 0.5, "unload": 0.5}

    @contextlib.contextmanager
    def budget(self, scope, phase):
        """Cooperative CPU guard, not a hostile-code containment boundary.

        Only lines in the original plugin source trigger checks. The budget is
        interpreter-thread CPU time, not elapsed wall time; synchronous I/O waits
        do not consume it. Blocking native calls cannot be interrupted and a
        plugin can catch the timeout exception. No native watchdog is implied.
        """
        deadline = time.thread_time() + self.execution_limits[phase]
        previous = sys.gettrace()
        count = 0
        # A package's modules live below one directory; a .plugin has no source root.
        root = scope.__dict__.get("source_root")

        def trace(frame, event, arg):
            nonlocal count
            name = frame.f_code.co_filename
            if name != scope.source_filename and not (root and name.startswith(root)):
                return None
            if event == "line":
                count += 1
                if count % 64 == 0 and time.thread_time() >= deadline:
                    raise BridgeError("EXECUTION_TIMEOUT", f"Plugin {phase} exceeded cooperative time budget")
            return trace

        sys.settrace(trace)
        try:
            yield
            if time.thread_time() >= deadline:
                raise BridgeError("EXECUTION_TIMEOUT", f"Plugin {phase} exceeded cooperative time budget")
        finally:
            sys.settrace(previous)

    def check_queue(self, worker=False):
        """Pin the runtime to the native queue thread.

        ``worker`` also admits a thread the calling plugin generation started
        through ``threading``; such a thread reaches the host only by
        ``_ayu_threads.marshal``.
        """
        ident = threading.get_ident()
        if self.thread_id is None and not _ayu_threads.is_worker():
            self.thread_id = ident
            _ayu_threads.install()
        if self.thread_id != ident and not (worker and _ayu_threads.admit(_current.get())):
            raise BridgeError("WRONG_QUEUE", "Use the native Python serial queue")

    def require(self, expected=None):
        self.check_queue(True)
        scope = _current.get()
        if scope is None or self.scopes.get(scope.plugin_id) is not scope:
            raise BridgeError("NO_PLUGIN_CONTEXT", "No active plugin scope")
        if scope.state not in ("loading", "active", "unloading"):
            raise BridgeError("PLUGIN_UNLOADED", "Plugin generation is no longer active")
        if expected is not None and scope is not expected:
            raise BridgeError("OWNERSHIP", "Object belongs to another plugin generation")
        return scope

    @contextlib.contextmanager
    def context(self, scope):
        self.check_queue()
        token = _current.set(scope)
        try:
            _ayu_threads.service(self, scope)
            yield scope
        finally:
            _current.reset(token)

    def encode(self, value, depth=0):
        scope = self.require()
        if depth > 64:
            raise ProtocolError("Value nesting exceeds protocol limit")
        if isinstance(value, CallbackReference):
            self.require(value.scope)
            if value.callback_id not in scope.callbacks:
                raise BridgeError("CALLBACK_EXPIRED", "Callback has been released")
            return {"$callback": value.callback_id}
        if isinstance(value, WireTarget):
            self.require(value.scope)
            return value.value
        if value is None or type(value) in (bool, str, int):
            if type(value) is int and not -(2**63) <= value < 2**63:
                raise ProtocolError("Integer exceeds signed 64-bit range")
            return value
        if type(value) is float:
            if not math.isfinite(value):
                raise ProtocolError("Nonfinite floating-point value")
            return value
        if isinstance(value, enum.Enum):
            return self.encode(value.value, depth + 1)
        if isinstance(value, RemoteObject):
            self.require(value._scope)
            return value._target()
        if isinstance(value, JavaClass):
            self.require(value._scope)
            return {"$java_class": value._name}
        if isinstance(value, DynamicProxy):
            return self.encode(value._reference(), depth + 1)
        if isinstance(value, type) and _ayu_javalib.local_name(value) is not None:
            name = _ayu_javalib.local_name(value)
            # A local class that overrides a host adapter still names a class the host declares.
            if name in self.capabilities["classes"] and _ayu_javalib.local_class(name) is value:
                return {"$java_class": name}
            # A class object is callable; it must not be mistaken for a plugin callback.
            raise UnsupportedAPI("Python-local Java class cannot be passed to the host: "
                                 + _ayu_javalib.local_name(value))
        if callable(value):
            return self.encode(self.callback(value), depth + 1)
        if hasattr(type(value), "to_bridge"):
            return self.encode(value.to_bridge(), depth + 1)
        if isinstance(value, (tuple, list)):
            return [self.encode(item, depth + 1) for item in value]
        if isinstance(value, dict):
            if any(type(key) is not str for key in value):
                raise ProtocolError("JSON object keys must be strings")
            if any(key.startswith("$") for key in value):
                raise ProtocolError("Reserved wire keys cannot be supplied by plugins")
            return {key: self.encode(item, depth + 1) for key, item in value.items()}
        local = _ayu_javalib.local_name(value)
        if local is not None:
            raise UnsupportedAPI(f"Python-local Java object cannot be passed to the host: {local}")
        raise ProtocolError(f"Unsupported bridge value type: {type(value).__name__}")

    def decode(self, value, depth=0):
        scope = self.require()
        if depth > 64:
            raise ProtocolError("Value nesting exceeds protocol limit")
        if isinstance(value, list):
            return [self.decode(item, depth + 1) for item in value]
        if isinstance(value, dict):
            if "$handle" in value or "$class" in value:
                if set(value) != {"$handle", "$class"} or not all(isinstance(value[k], str) and value[k] for k in value):
                    raise ProtocolError("Malformed native reference")
                if value["$class"] not in self.capabilities["classes"]:
                    raise ProtocolError("Host returned an undeclared native class")
                # One wrapper per host reference, so `is` and identity-keyed containers hold as on Android.
                key = (value["$handle"], value["$class"])
                remote = scope.remotes.get(key)
                if remote is None:
                    remote = scope.remotes[key] = RemoteObject(self, scope, value["$handle"], value["$class"])
                return remote
            if "$java_class" in value:
                if set(value) != {"$java_class"}:
                    raise ProtocolError("Malformed Java class reference")
                return self.jclass(value["$java_class"])
            if any(key.startswith("$") for key in value):
                raise ProtocolError("Unknown reserved response value")
            return {key: self.decode(item, depth + 1) for key, item in value.items()}
        if value is None or type(value) in (bool, str, int):
            if type(value) is int and not -(2**63) <= value < 2**63:
                raise ProtocolError("Response integer exceeds signed 64-bit range")
            return value
        if type(value) is float and math.isfinite(value):
            return value
        raise ProtocolError("Unsupported response value")

    def _dispatch(self, plugin_id, operation, arguments):
        self.check_queue()
        import _ayu_host
        request_id = str(next(self.request_ids))
        request = {"version": VERSION, "id": request_id, "plugin_id": plugin_id,
                   "operation": operation, "arguments": arguments}
        text = json.dumps(request, allow_nan=False, separators=(",", ":"))
        # ASCII, so characters are bytes. Only the operations that carry TL values get the larger envelope.
        if len(text) > (MAX_TL_REQUEST_BYTES if operation.startswith("telegram.") else MAX_REQUEST_BYTES):
            raise BridgeError("RESOURCE_LIMIT", "Request is too large")
        try:
            response = parse_json(_ayu_host.dispatch(text))
        except BridgeError:
            raise
        except Exception as error:
            raise BridgeError("TRANSPORT_ERROR", "Native dispatch failed") from error
        if not isinstance(response, dict) or type(response.get("version")) is not int or response.get("version") != VERSION or response.get("id") != request_id:
            raise ProtocolError("Response version or correlation ID mismatch")
        if set(response) == {"version", "id", "error"}:
            error = response["error"]
            if not isinstance(error, dict) or set(error) != {"code", "message"} or not all(isinstance(v, str) for v in error.values()):
                raise ProtocolError("Malformed native error")
            raise BridgeError(error["code"], error["message"])
        if set(response) != {"version", "id", "result"}:
            raise ProtocolError("Response must have exactly one result or error")
        return response["result"]

    def call(self, operation, arguments=None):
        if _ayu_threads.off_queue(self):
            return _ayu_threads.marshal(self, self.call, operation, arguments)
        scope = self.require()
        if operation not in self.capabilities["operations"]:
            raise UnsupportedAPI(f"Host does not declare operation {operation}")
        before = set(scope.callbacks)
        try:
            encoded = self.encode(arguments or {})
            # Wire tags created by the encoder must not be encoded a second time.
            return self.decode(self._dispatch(scope.plugin_id, operation, encoded))
        except Exception:
            for callback_id in set(scope.callbacks) - before:
                scope.callbacks.pop(callback_id, None)
            raise

    def callback(self, function, once=False):
        if _ayu_threads.off_queue(self):
            return _ayu_threads.marshal(self, self.callback, function, once)
        scope = self.require()
        if not callable(function):
            raise TypeError("Expected a callable")
        if len(scope.callbacks) >= 4096:
            raise BridgeError("RESOURCE_LIMIT", "Plugin callback limit reached")
        callback_id = scope.generation + ":" + uuid.uuid4().hex
        scope.callbacks[callback_id] = (function, bool(once))
        return CallbackReference(callback_id)

    def member(self, target, name):
        if not isinstance(name, str) or not name or name.startswith("_"):
            raise UnsupportedAPI("Invalid native member name")
        served = _ayu_javalib.serve(self, target, name)
        if served is not None:
            return served[0]
        try:
            result = self.call("java.member", {"target": WireTarget(target), "name": name})
        except BridgeError as error:
            # Android code probes for members; the host's refusal has to read as a missing attribute.
            if error.code != "UNSUPPORTED_API" or isinstance(error, AttributeError):
                raise
            raise MissingMember(error.message) from None
        if not isinstance(result, dict) or result.get("kind") not in ("method", "field", "class"):
            raise ProtocolError("Malformed native member descriptor")
        if result["kind"] == "method" and set(result) == {"kind"}:
            return NativeMethod(self, self.require(), WireTarget(target), name)
        if result["kind"] == "field" and set(result) == {"kind", "value"}:
            return result["value"]
        if result["kind"] == "class" and set(result) == {"kind", "class_name"}:
            return self.jclass(result["class_name"])
        raise ProtocolError("Invalid native member descriptor fields")

    def jclass(self, name):
        """The Python-local class when it is usable, else the host facade for a declared class."""
        scope = self.require()
        if isinstance(name, str):
            # local_classes holds a host-declared name only when the local class overrides it.
            if name in self.capabilities.get("local_classes", ()):
                return _ayu_javalib.local_class(name)
            if name in self.capabilities["classes"]:
                return JavaClass(self, scope, name)
            needed = _ayu_javalib.missing_operations(name, self.capabilities["operations"])
            if needed:
                raise UnsupportedAPI(f"Java class {name} needs undeclared host operation {needed[0]}")
        raise UnsupportedAPI(f"Java class is not declared by host: {name}")

    @staticmethod
    def _declared_classes(capabilities):
        """Host classes plus the Python-local classes this host makes usable."""
        return set(capabilities["classes"]) | set(capabilities.get("local_classes", ()))

    @staticmethod
    def _undeclared_imports(imports, from_imports, declared, modules):
        allowed = SDK_MODULES | set(modules) | set(getattr(sys, "stdlib_module_names", ()))
        for name in imports:
            native = name.startswith(NATIVE_PREFIXES)
            # Names imported from a Java package are checked class by class.
            if native and name in from_imports and name not in allowed:
                continue
            if any(c.startswith(name + ".") for c in declared):
                continue
            if name in allowed or not native and name.split(".")[0] in allowed:
                continue
            yield name

    @staticmethod
    def _class_path_imports(imports, from_imports, declared):
        """Imports whose module path names a Java class, which Chaquopy cannot resolve.

        Its import hook serves ``from <package> import <Class>`` only: ``import pkg.Class`` and
        ``from pkg.Outer import Nested`` raise ImportError on Android. Returns those modules and
        the class names static inspection derived from their imported symbols.
        """
        modules = {name for name in imports if name.startswith(NATIVE_PREFIXES) and name in declared
                   and not any(item.startswith(name + ".") for item in declared)}
        return modules, {module + "." + symbol for module in modules for symbol in from_imports.get(module, ())}

    @staticmethod
    def _requirements(metadata):
        """``__requirements__`` entries as Android reads them: one string or a list of constants."""
        requirements = _ayu_policy.requirement_list(metadata.get("__requirements__", []))
        if requirements is None:
            raise BridgeError("LOAD_REJECTED", "__requirements__ must be a string or a list of constants")
        if len(requirements) > _ayu_policy.MAX_REQUIREMENTS:
            raise BridgeError("LOAD_REJECTED", "__requirements__ exceeds its entry limit")
        return requirements

    @staticmethod
    def _unbundled_requirements(requirements, capabilities):
        """Requirements no bundled module satisfies; nothing is ever installed."""
        modules = SDK_MODULES | set(capabilities["modules"]) | set(getattr(sys, "stdlib_module_names", ()))
        return _ayu_policy.requirement_findings(requirements, modules)

    def schedule(self, function, queue="pluginsQueue", delay=0):
        if _ayu_threads.off_queue(self):
            return _ayu_threads.marshal(self, self.schedule, function, queue, delay)
        scope = self.require()
        if scope.state == "unloading":
            raise BridgeError("PLUGIN_UNLOADING", "Cannot schedule during unload")
        if len(scope.registrations) >= 1024:
            raise BridgeError("RESOURCE_LIMIT", "Plugin registration limit reached")
        if not isinstance(queue, str) or type(delay) not in (int, float) or delay < 0 or not math.isfinite(delay):
            raise ValueError("Invalid queue or delay")
        reference = self.callback(function, once=True)
        try:
            token = self.call("scheduler.schedule", {"queue": queue, "delay_ms": delay, "callback": reference})
            if not isinstance(token, str) or not token:
                raise ProtocolError("Expected scheduling token")
            return Registration(self, scope, "schedule", token, [reference.callback_id])
        except Exception:
            scope.callbacks.pop(reference.callback_id, None)
            raise

    def register(self, kind, config):
        if _ayu_threads.off_queue(self):
            return _ayu_threads.marshal(self, self.register, kind, config)
        scope = self.require()
        if scope.state == "unloading":
            raise BridgeError("PLUGIN_UNLOADING", "Cannot register during unload")
        if len(scope.registrations) >= 1024:
            raise BridgeError("RESOURCE_LIMIT", "Plugin registration limit reached")
        before = set(scope.callbacks)
        try:
            token = self.call({"hook": "hooks.register", "menu": "menus.register"}[kind], config)
            if not isinstance(token, str) or not token:
                raise ProtocolError("Expected registration token")
            return Registration(self, scope, kind, token, set(scope.callbacks) - before)
        except Exception:
            for callback_id in set(scope.callbacks) - before:
                scope.callbacks.pop(callback_id, None)
            raise

    def _capabilities(self):
        caps = self._dispatch("$runtime", "runtime.capabilities", {})
        if not isinstance(caps, dict) or set(caps) - {"members"} != {"operations", "classes", "modules", "proxy_interfaces"}:
            raise ProtocolError("Malformed host capabilities")
        for key in ("operations", "classes", "modules"):
            if not isinstance(caps[key], list) or not all(isinstance(v, str) and v for v in caps[key]):
                raise ProtocolError("Invalid capability list")
        if not isinstance(caps["proxy_interfaces"], dict):
            raise ProtocolError("Invalid proxy registry")
        for name, methods in caps["proxy_interfaces"].items():
            if name not in caps["classes"] or not isinstance(methods, list) or not all(isinstance(m, str) and m and not m.startswith("_") for m in methods):
                raise ProtocolError("Invalid proxy interface declaration")
        if "members" in caps:
            # A host that publishes no table, or one of a newer version, has unknown members.
            try:
                caps["members"] = _ayu_members.validate(caps["members"], caps["classes"])
            except ValueError as error:
                raise ProtocolError("Invalid class member table") from error
            if caps["members"] is None:
                del caps["members"]
        # A class the host declares wins unless the local class explicitly overrides it.
        shadowed = set(caps["classes"]) - _ayu_javalib.host_override_names(caps["operations"])
        caps["local_classes"] = _ayu_javalib.local_class_names(caps["operations"]) - shadowed
        return caps

    def inspect(self, source, filename="plugin.plugin"):
        self.check_queue()
        if not isinstance(source, str) or len(source.encode("utf-8")) > 4_194_304:
            raise BridgeError("LOAD_REJECTED", "Plugin source must be bounded UTF-8 text")
        try:
            tree = ast.parse(source, filename=filename)
        except (SyntaxError, ValueError, RecursionError) as error:
            raise BridgeError("LOAD_REJECTED", "Plugin source has invalid syntax") from error
        # Validate the AST budget before literal evaluation or repeated traversal.
        inventory = _inventory(tree)
        metadata = {}
        for node in tree.body:
            if isinstance(node, (ast.Assign, ast.AnnAssign)):
                targets = node.targets if isinstance(node, ast.Assign) else [node.target]
                for target in targets:
                    if isinstance(target, ast.Name) and target.id in _METADATA_KEYS:
                        if target.id in metadata:
                            raise BridgeError("LOAD_REJECTED", "Duplicate plugin metadata")
                        try:
                            metadata[target.id] = ast.literal_eval(node.value)
                        except (ValueError, TypeError, RecursionError):
                            raise BridgeError("LOAD_REJECTED", "Metadata must be literal")
        plugin_id = metadata.get("__id__")
        if not isinstance(plugin_id, str) or not _ID.fullmatch(plugin_id) or not isinstance(metadata.get("__name__"), str) or not metadata["__name__"].strip():
            raise BridgeError("LOAD_REJECTED", "Literal valid __id__ and __name__ are required")
        imports, classes = set(), set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                imports.update(alias.name for alias in node.names)
            elif isinstance(node, ast.ImportFrom):
                if node.level:
                    raise BridgeError("LOAD_REJECTED", "Relative plugin imports are not supported")
                if node.module:
                    imports.add(node.module)
                    if node.module.startswith(NATIVE_PREFIXES) and node.module not in SDK_MODULES:
                        if any(alias.name == "*" for alias in node.names):
                            raise BridgeError("LOAD_REJECTED", "Wildcard native imports are unsupported")
        try:
            json.dumps(metadata, allow_nan=False)
        except (TypeError, ValueError, RecursionError) as error:
            raise BridgeError("LOAD_REJECTED", "Metadata must contain finite JSON-compatible literals") from error
        classes.update(inventory["classes"])
        return tree, metadata, sorted(imports), sorted(classes)

    def inspect_plugin_json(self, source, filename="plugin.plugin"):
        tree, metadata, imports, classes = self.inspect(source, filename)
        inventory = _inventory(tree)
        requirements = self._requirements(metadata)
        warnings = []
        if any(name.split(".")[0] == "_thread" for name in imports):
            warnings.append("UNSUPPORTED_THREADING: plugin-created Python threads cannot enter the native bridge")
        unsupported = {name: UNSUPPORTED_IMPORTS[name.split(".")[0]] for name in imports
                       if name.split(".")[0] in UNSUPPORTED_IMPORTS}
        return json.dumps({"metadata": metadata, "imports": imports, "classes": classes,
                           "requirements": requirements, "warnings": warnings,
                           "sdk_modules": sorted(SDK_MODULES),
                           "python_stdlib_candidates": sorted(getattr(sys, "stdlib_module_names", ())),
                            "unsupported_imports": unsupported,
                            "imported_symbols": inventory["imported_symbols"],
                             "unsupported_sdk_symbols": inventory["unsupported_sdk_symbols"],
                             "optional_imports": inventory.get("optional_imports", []),
                             "sdk_requirements": _ayu_operations.requirements(
                                 inventory["sdk_references"], inventory["method_calls"],
                                 inventory["send_hook_fields"], inventory.get("hook_targets"),
                                 inventory.get("intent_actions", ())),
                            "unguarded_native_imports": inventory["unguarded_native_imports"],
                            "dynamic_class_lookup_lines": inventory["dynamic_class_lookup_lines"]}, allow_nan=False)

    def preflight_plugin_json(self, source, filename="plugin.plugin"):
        report = json.loads(self.inspect_plugin_json(source, filename))
        capabilities = self._capabilities()
        blockers = []

        def block(code, detail):
            blockers.append({"code": code, "detail": detail})

        for module, symbols in report["unsupported_sdk_symbols"].items():
            for symbol in symbols:
                block("SDK_MEMBER", module + "." + symbol)
        for name in report["unsupported_imports"]:
            block("IMPORT", name)
        # Worker threads reach the host through its scheduler; without it they stay unsupported.
        for name in _ayu_threads.unavailable_imports(report["imports"], capabilities["operations"]):
            block("IMPORT", name)
        declared = self._declared_classes(capabilities)
        class_modules, class_symbols = self._class_path_imports(report["imports"], report["imported_symbols"], declared)
        for name in report["classes"]:
            if name not in declared and name not in class_symbols:
                block("CLASS", name)
        # A class-path import fails on Android too; it blocks only where no handler absorbs the ImportError.
        unguarded = report["unguarded_native_imports"]
        for name in sorted(class_modules.intersection(unguarded["modules"]) | class_symbols.intersection(unguarded["symbols"])):
            block("IMPORT", name + " (a Java class is not an importable module)")
        for name in self._undeclared_imports([name for name in report["imports"] if name not in class_modules],
                                             report["imported_symbols"], declared, capabilities["modules"]):
            block("DEPENDENCY", name)
        for finding in self._unbundled_requirements(report["requirements"], capabilities):
            block("REQUIREMENT", finding)
        for finding in _ayu_policy.version_findings(report["metadata"]):
            block("VERSION_POLICY", finding)
        required = report["metadata"].get("__bridge_operations__", [])
        if not isinstance(required, list) or not all(isinstance(name, str) and name for name in required):
            raise BridgeError("LOAD_REJECTED", "__bridge_operations__ must be a literal string list")
        for name in required:
            if name not in capabilities["operations"]:
                block("OPERATION", name)
        report["member_accesses"] = self._member_accesses(ast.parse(source, filename=filename), capabilities)
        # The curated list of unprovided members is the net under receivers inspection cannot
        # resolve; where every use of a name was resolved, the MEMBER check has spoken for it.
        unresolved = set(report["member_accesses"].pop("unresolved"))
        required = {name: groups for name, groups in report["sdk_requirements"].items()
                    if name[:-2] not in _ayu_operations.UNPROVIDED_MEMBERS or not name.endswith("()")
                    or name[:-2] in unresolved}
        # SDK entry points the source references whose host operations are not declared.
        for finding in _ayu_operations.missing(required, capabilities["operations"]):
            block("OPERATION", finding)
        for finding in report["member_accesses"].pop("gated"):
            block("OPERATION", finding)
        for finding in report["member_accesses"].pop("missing"):
            block("MEMBER", finding)
        if report["dynamic_class_lookup_lines"]:
            report["warnings"].append("DYNAMIC_CLASSES: computed native classes are checked only at runtime")
        report["blockers"] = blockers
        return json.dumps(report, allow_nan=False)

    @staticmethod
    def _member_accesses(tree, capabilities):
        """Java member accesses on receivers whose class static inspection is certain of.

        ``missing`` lists, once each, the members neither the host class nor the Python-local class
        provides (``Class.member``, ``Class.member (write)``, ``Class.<init>``); the counts say how
        many accesses were verified, were missing behind a probe, or have an unknown receiver.
        """
        try:
            tables = _ayu_members.Tables(capabilities)
            found = member_inventory(tree, SDK_MODULES, tables, frozenset(_ayu_operations.UNPROVIDED_MEMBERS))
        except (ValueError, RecursionError, OSError, UnicodeError, SyntaxError) as error:
            raise BridgeError("LOAD_REJECTED", "Static SDK inventory is invalid or exceeds its limits") from error
        suffix = {"read": "", "write": " (write)", "construct": ""}
        # A member only the gated Python-local class of that name provides is its operation's blocker.
        gates = [(tables.gate(item["class"], item["member"], item["use"]), item) for item in found["missing"]]
        found["gated"] = sorted({f'{gate} ({item["class"]}.{item["member"]})' for gate, item in gates if gate})
        found["missing"] = sorted({item["class"] + "." + item["member"] + suffix[item["use"]] for gate, item in gates if not gate})
        return found

    @staticmethod
    def _source_path(filename):
        """A plugin file's path below the SDK's plugins directory, computed without creating anything.

        The plugin's storage is real, so directories it makes next to ``__file__`` are writable; the
        source itself is not stored there. Without an application container the name stays as given.
        """
        if os.path.isabs(filename):
            return filename
        import file_utils
        try:
            return file_utils._plugin_file(filename)
        except UnsupportedAPI:
            return filename

    def load_plugin(self, source, filename="plugin.plugin", expected_id=None):
        self.check_queue()
        tree, metadata, imports, classes = self.inspect(source, filename)
        inventory = _inventory(tree)
        plugin_id = metadata["__id__"]
        if expected_id is not None and expected_id != plugin_id:
            raise BridgeError("LOAD_REJECTED", "Plugin ID does not match trusted expected ID")
        if inventory["unsupported_sdk_symbols"]:
            module = sorted(inventory["unsupported_sdk_symbols"])[0]
            symbol = inventory["unsupported_sdk_symbols"][module][0]
            raise BridgeError("LOAD_REJECTED", f"SDK member is not implemented: {module}.{symbol}")
        for name in imports:
            reason = UNSUPPORTED_IMPORTS.get(name.split(".")[0])
            if reason:
                raise BridgeError("LOAD_REJECTED", f"{reason}: {name}")
        if plugin_id in self.scopes:
            raise BridgeError("ALREADY_LOADED", "Unload the current plugin generation first")
        if len(self.scopes) >= 32:
            raise BridgeError("RESOURCE_LIMIT", "Loaded plugin limit reached")
        capabilities = self._capabilities()
        if self.scopes and self.capabilities != capabilities:
            raise ProtocolError("Host capabilities changed while plugins are active")
        self.capabilities = capabilities
        for name in _ayu_threads.unavailable_imports(imports, capabilities["operations"]):
            raise BridgeError("LOAD_REJECTED", f"Plugin threads need the host scheduler: {name}")
        declared = self._declared_classes(self.capabilities)
        class_modules, class_symbols = self._class_path_imports(imports, inventory["imported_symbols"], declared)
        for name in classes:
            if name not in declared and name not in class_symbols:
                raise BridgeError("LOAD_REJECTED", f"Undeclared Java class: {name}")
        unguarded = inventory["unguarded_native_imports"]
        for name in sorted(class_modules.intersection(unguarded["modules"]) | class_symbols.intersection(unguarded["symbols"])):
            raise BridgeError("LOAD_REJECTED", f"A Java class is not an importable module: {name}")
        for name in self._undeclared_imports([name for name in imports if name not in class_modules],
                                             inventory["imported_symbols"], declared, self.capabilities["modules"]):
            raise BridgeError("LOAD_REJECTED", f"Undeclared dependency: {name}")
        for finding in self._unbundled_requirements(self._requirements(metadata), self.capabilities):
            raise BridgeError("LOAD_REJECTED", f"Requirement is not bundled: {finding}")
        for finding in _ayu_policy.version_findings(metadata):
            raise BridgeError("LOAD_REJECTED", f"Version constraint is not satisfied: {finding}")
        # The host must reject unsupported statically identified APIs here, before
        # even the first top-level statement. Requirements and version constraints
        # are settled above, so the host is sent no requirement left to install and
        # the versions the constraints were evaluated against.
        # Python-local classes never reach the host, so only its own are submitted.
        host_classes = [name for name in classes if name in self.capabilities["classes"]
                        and name not in self.capabilities["local_classes"]]
        approval = self._dispatch(plugin_id, "plugin.authorize", {
            "metadata": metadata, "imports": imports, "classes": host_classes, "requirements": [],
            "version_policy": {"app_version": _ayu_policy.APP_VERSION, "sdk_version": _ayu_policy.SDK_VERSION}})
        if approval is not True:
            raise BridgeError("LOAD_REJECTED", "Host did not explicitly authorize execution")
        # Plugin code sees the path its file has on Android, as ``__file__`` and in its frames.
        filename = self._source_path(filename)
        scope = Scope(plugin_id, metadata=metadata, source_filename=filename)
        self.scopes[plugin_id] = scope
        module_name = "_ayu_plugin_" + scope.generation
        module = types.ModuleType(module_name)
        module.__file__ = filename
        # Android plugin metadata uses __name__ as a human-readable title. Python
        # decorators and forward annotations require __name__ to identify a real
        # sys.modules entry, so relocate only that top-level literal assignment.
        # The original display value remains authoritative in parsed metadata.
        for statement in tree.body:
            if isinstance(statement, ast.Assign):
                targets = statement.targets
            elif isinstance(statement, ast.AnnAssign):
                targets = [statement.target]
            else:
                continue
            for target in targets:
                if isinstance(target, ast.Name) and target.id == "__name__":
                    target.id = "__ayu_display_name__"
        scope.module = module
        scope.module_key = module_name
        sys.modules[module_name] = module
        try:
            with self.context(scope), self.budget(scope, "load"):
                self.call("plugin.activate", {"metadata": metadata, "generation": scope.generation})
                install_native_importer()
                # The SDK's own __future__ imports must not change how plugin code compiles.
                exec(compile(tree, filename, "exec", dont_inherit=True), module.__dict__)
                from base_plugin import BasePlugin
                if module.__dict__.get("__name__") != module_name:
                    raise BridgeError("LOAD_REJECTED", "Plugin modified its runtime module identity")
                candidates = [value for value in module.__dict__.values() if isinstance(value, type) and value is not BasePlugin and issubclass(value, BasePlugin) and value.__module__ == module_name]
                if len(candidates) != 1:
                    raise BridgeError("LOAD_REJECTED", "Expected exactly one plugin class")
                scope.instance = candidates[0]()
                scope.instance.on_plugin_load()
                scope.state = "active"
            return {"plugin_id": plugin_id, "metadata": metadata, "generation": scope.generation}
        except BaseException:
            with self.context(scope):
                self._cleanup(scope)
            raise

    def _cleanup(self, scope):
        # Deactivate is an atomic host cleanup barrier: revoke handles, cancel all
        # scheduled work, remove hooks/menus/listeners for this generation.
        scope.callbacks.clear()
        for registration in list(scope.registrations.values()):
            registration._forget()
        try:
            self._dispatch(scope.plugin_id, "plugin.deactivate", {"generation": scope.generation})
        finally:
            scope.state = "unloaded"
            _ayu_threads.close(scope)
            if scope.module is not None:
                sys.modules.pop(scope.module_key, None)
            scope.instance = None
            scope.module = None
            self.scopes.pop(scope.plugin_id, None)

    def unload_plugin(self, plugin_id):
        self.check_queue()
        scope = self.scopes.get(plugin_id)
        if scope is None:
            raise BridgeError("NOT_LOADED", "Plugin is not loaded")
        with self.context(scope):
            scope.state = "unloading"
            _ayu_threads.signal_stop(scope)
            # Revocation precedes user unload code so already enqueued callbacks
            # cannot enter it. Native host calls remain valid until deactivate.
            scope.callbacks.clear()
            try:
                with self.budget(scope, "unload"):
                    scope.instance.on_plugin_unload()
            finally:
                self._cleanup(scope)
        return True

    def invoke_callback_json(self, text):
        self.check_queue()
        event = parse_json(text)
        if not isinstance(event, dict) or set(event) != {"version", "plugin_id", "callback_id", "arguments"} or event["version"] != VERSION:
            raise ProtocolError("Malformed callback event")
        if type(event["version"]) is not int or not isinstance(event["plugin_id"], str) or not isinstance(event["callback_id"], str):
            raise ProtocolError("Invalid callback identity")
        scope = self.scopes.get(event["plugin_id"])
        if scope is None or scope.state != "active":
            raise DeliveryExpired("CALLBACK_EXPIRED", "Plugin callback generation is inactive")
        entry = scope.callbacks.get(event["callback_id"])
        if entry is None:
            raise DeliveryExpired("CALLBACK_EXPIRED", "Unknown or released callback")
        if not isinstance(event["arguments"], list):
            raise ProtocolError("Callback arguments must be an array")
        function, once = entry
        if once:
            scope.callbacks.pop(event["callback_id"], None)
            for registration in list(scope.registrations.values()):
                if event["callback_id"] in registration.callback_ids:
                    registration._forget()
        with self.context(scope), self.budget(scope, "callback"):
            result = function(*self.decode(event["arguments"]))
            text = json.dumps(self.encode(result), allow_nan=False, separators=(",", ":"))
            if len(text) > MAX_RESULT_BYTES:
                raise BridgeError("RESOURCE_LIMIT", "Callback result is too large")
            return text

    def service_workers(self, plugin_id):
        """Native wake (``_ayu_host.wake``): serve the calls this plugin's worker threads have queued."""
        self.check_queue()
        scope = self.scopes.get(plugin_id)
        if scope is None or scope.state != "active":
            return False
        with self.context(scope):
            return _ayu_threads.serve(scope)

    def emit_event_json(self, text):
        self.check_queue()
        event = parse_json(text)
        if not isinstance(event, dict) or set(event) != {"version", "plugin_id", "generation", "name", "arguments"} or event["version"] != VERSION:
            raise ProtocolError("Malformed lifecycle event")
        if type(event["version"]) is not int or not isinstance(event["plugin_id"], str) or not isinstance(event["generation"], str):
            raise ProtocolError("Invalid lifecycle identity")
        if event["name"] != "app" or not isinstance(event["arguments"], list) or len(event["arguments"]) != 1:
            raise UnsupportedAPI("Only explicit app lifecycle events are supported")
        scope = self.scopes.get(event["plugin_id"])
        if scope is None or scope.state != "active" or event["generation"] != scope.generation:
            raise DeliveryExpired("NOT_LOADED", "Plugin event generation is not active")
        from base_plugin import AppEvent
        with self.context(scope), self.budget(scope, "event"):
            scope.instance.on_app_event(AppEvent(event["arguments"][0]))
        return True

    def serialize_settings(self, plugin_id):
        self.check_queue()
        scope = self.scopes.get(plugin_id)
        if scope is None or scope.state != "active":
            raise BridgeError("NOT_LOADED", "Plugin is not active")
        with self.context(scope), self.budget(scope, "settings"):
            from ui.settings import android_rows
            settings = android_rows(scope.instance.create_settings())
            previous = scope.settings_callbacks
            before = set(scope.callbacks)
            try:
                result = json.dumps(self.encode(settings), allow_nan=False, separators=(",", ":"))
            except Exception:
                for callback_id in set(scope.callbacks) - before:
                    scope.callbacks.pop(callback_id, None)
                raise
            scope.settings_callbacks = set(scope.callbacks) - before
            for callback_id in previous:
                scope.callbacks.pop(callback_id, None)
            return result


class CallbackReference:
    def __init__(self, callback_id):
        self.callback_id = callback_id
        self.scope = runtime.require()

    def to_bridge(self):
        # Runtime.encode handles this type specially below, so ordinary user
        # dictionaries can never impersonate a callback reference.
        raise ProtocolError("Callback wire references must be encoded by runtime")


class WireTarget:
    def __init__(self, value):
        self.value, self.scope = value, runtime.require()


runtime = Runtime()


class NativePackage(types.ModuleType):
    def __getattr__(self, name):
        if name.startswith("_"):
            raise AttributeError(name)
        return runtime.jclass(self.__name__ + "." + name)


class NativeImporter(importlib.abc.MetaPathFinder, importlib.abc.Loader):
    def find_spec(self, fullname, path=None, target=None):
        # ``java`` itself is the SDK facade module; only its subpackages are Java packages.
        if not (fullname.startswith(NATIVE_PREFIXES) or fullname in NATIVE_ROOTS and fullname != "java"):
            return None
        if fullname in SDK_MODULES:
            return None
        runtime.require()
        declared = runtime._declared_classes(runtime.capabilities)
        if not any(name.startswith(fullname + ".") for name in declared):
            if fullname in declared:
                # As with Chaquopy's import hook, a class is imported from its package, never as a module.
                raise ModuleNotFoundError(f"No module named {fullname!r}: it is a Java class", name=fullname)
            raise UnsupportedAPI(f"Native package not declared: {fullname}")
        return importlib.machinery.ModuleSpec(fullname, self, is_package=True)

    def create_module(self, spec):
        module = NativePackage(spec.name)
        module.__path__ = []
        return module

    def exec_module(self, module):
        return None  # Package namespace only; individual symbols require registry lookup.


_importer = NativeImporter()


def install_native_importer():
    if _importer not in sys.meta_path:
        sys.meta_path.insert(0, _importer)


def inspect_plugin_json(source, filename="plugin.plugin"):
    return runtime.inspect_plugin_json(source, filename)


def preflight_plugin_json(source, filename="plugin.plugin"):
    return runtime.preflight_plugin_json(source, filename)


def load_plugin(source, filename="plugin.plugin", expected_id=None):
    return runtime.load_plugin(source, filename, expected_id=expected_id)


def inspect_package_json(path, filename="plugin.elyx"):
    import _ayu_packages
    return _ayu_packages.inspect_package_json(runtime, path, filename)


def preflight_package_json(path, filename="plugin.elyx"):
    import _ayu_packages
    return _ayu_packages.preflight_package_json(runtime, path, filename)


def load_package(path, filename="plugin.elyx", expected_id=None):
    import _ayu_packages
    return _ayu_packages.load_package(runtime, path, filename, expected_id=expected_id)


def unload_plugin(plugin_id):
    return runtime.unload_plugin(plugin_id)


def invoke_callback_json(text):
    return runtime.invoke_callback_json(text)


def emit_event_json(text):
    return runtime.emit_event_json(text)


def service_workers(plugin_id):
    return runtime.service_workers(plugin_id)


def serialize_settings(plugin_id):
    return runtime.serialize_settings(plugin_id)
