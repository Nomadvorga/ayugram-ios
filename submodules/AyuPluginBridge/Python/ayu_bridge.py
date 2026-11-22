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
import re
import sys
import threading
import time
import types
import uuid
from dataclasses import dataclass, field
from typing import Any

from _ayu_inspection import import_inventory

VERSION = 1
SDK_MODULES = frozenset({"ayu_bridge", "base_plugin", "client_utils", "android_utils",
                         "hook_utils", "plugin_settings", "java", "ui", "ui.settings",
                         "ui.alert", "ui.bulletin"})
UNSUPPORTED_IMPORTS = {
    "threading": "Plugin-created Python threads are unsupported",
    "_thread": "Plugin-created Python threads are unsupported",
    "concurrent": "Plugin thread/process pools are unsupported",
    "multiprocessing": "Launching Python processes is unsupported",
    "subprocess": "Launching native processes is unsupported",
    "ctypes": "Dynamic native symbol access is unsupported; use explicit host adapters",
}
_ID = re.compile(r"^[A-Za-z][A-Za-z0-9_-]{1,31}$")
_current = contextvars.ContextVar("ayu_plugin_scope", default=None)


class BridgeError(RuntimeError):
    def __init__(self, code: str, message: str):
        self.code = code
        self.message = message
        super().__init__(f"{code}: {message}")


class ProtocolError(BridgeError):
    def __init__(self, message: str):
        super().__init__("PROTOCOL_ERROR", message)


class UnsupportedAPI(BridgeError):
    def __init__(self, message: str):
        super().__init__("UNSUPPORTED_API", message)


def _object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ProtocolError("Duplicate JSON key")
        result[key] = value
    return result


def parse_json(text):
    if not isinstance(text, str) or len(text) > 4_000_000:
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


class RemoteObject:
    """A native object reference bound to one plugin load generation."""
    def __init__(self, runtime, scope, handle, class_name):
        object.__setattr__(self, "_runtime", runtime)
        object.__setattr__(self, "_scope", scope)
        object.__setattr__(self, "_handle", handle)
        object.__setattr__(self, "_class_name", class_name)

    def __repr__(self):
        return f"<native {self._class_name}>"

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

        def trace(frame, event, arg):
            nonlocal count
            if frame.f_code.co_filename != scope.source_filename:
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

    def check_queue(self):
        ident = threading.get_ident()
        if self.thread_id is None:
            self.thread_id = ident
        if self.thread_id != ident:
            raise BridgeError("WRONG_QUEUE", "Use the native Python serial queue")

    def require(self, expected=None):
        self.check_queue()
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
                return RemoteObject(self, scope, value["$handle"], value["$class"])
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
        try:
            response = parse_json(_ayu_host.dispatch(json.dumps(request, allow_nan=False, separators=(",", ":"))))
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
        result = self.call("java.member", {"target": WireTarget(target), "name": name})
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
        scope = self.require()
        if not isinstance(name, str) or name not in self.capabilities["classes"]:
            raise UnsupportedAPI(f"Java class is not declared by host: {name}")
        return JavaClass(self, scope, name)

    def schedule(self, function, queue="pluginsQueue", delay=0):
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
        if not isinstance(caps, dict) or set(caps) != {"operations", "classes", "modules", "proxy_interfaces"}:
            raise ProtocolError("Malformed host capabilities")
        for key in ("operations", "classes", "modules"):
            if not isinstance(caps[key], list) or not all(isinstance(v, str) and v for v in caps[key]):
                raise ProtocolError("Invalid capability list")
        if not isinstance(caps["proxy_interfaces"], dict):
            raise ProtocolError("Invalid proxy registry")
        for name, methods in caps["proxy_interfaces"].items():
            if name not in caps["classes"] or not isinstance(methods, list) or not all(isinstance(m, str) and m and not m.startswith("_") for m in methods):
                raise ProtocolError("Invalid proxy interface declaration")
        return caps

    def inspect(self, source, filename="plugin.plugin"):
        self.check_queue()
        if not isinstance(source, str) or len(source.encode("utf-8")) > 2_000_000:
            raise BridgeError("LOAD_REJECTED", "Plugin source must be bounded UTF-8 text")
        try:
            tree = ast.parse(source, filename=filename)
        except SyntaxError as error:
            raise BridgeError("LOAD_REJECTED", "Plugin source has invalid syntax") from error
        metadata = {}
        for node in tree.body:
            if isinstance(node, (ast.Assign, ast.AnnAssign)):
                targets = node.targets if isinstance(node, ast.Assign) else [node.target]
                for target in targets:
                    if isinstance(target, ast.Name) and target.id.startswith("__") and target.id.endswith("__"):
                        if target.id in metadata:
                            raise BridgeError("LOAD_REJECTED", "Duplicate plugin metadata")
                        try:
                            metadata[target.id] = ast.literal_eval(node.value)
                        except (ValueError, TypeError):
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
                    if node.module.startswith(("android.", "androidx.", "org.telegram.", "java.", "javax.", "com.")):
                        for alias in node.names:
                            if alias.name == "*":
                                raise BridgeError("LOAD_REJECTED", "Wildcard native imports are unsupported")
                            classes.add(node.module + "." + alias.name)
        try:
            json.dumps(metadata, allow_nan=False)
        except (TypeError, ValueError, RecursionError) as error:
            raise BridgeError("LOAD_REJECTED", "Metadata must contain finite JSON-compatible literals") from error
        classes.update(import_inventory(tree, SDK_MODULES)["classes"])
        return tree, metadata, sorted(imports), sorted(classes)

    def inspect_plugin_json(self, source, filename="plugin.plugin"):
        tree, metadata, imports, classes = self.inspect(source, filename)
        inventory = import_inventory(tree, SDK_MODULES)
        requirements = metadata.get("__requirements__", [])
        if not isinstance(requirements, list) or not all(isinstance(v, str) for v in requirements):
            raise BridgeError("LOAD_REJECTED", "__requirements__ must be a literal string list")
        warnings = []
        if any(name.split(".")[0] in ("threading", "_thread") for name in imports):
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
                            "dynamic_class_lookup_lines": inventory["dynamic_class_lookup_lines"]}, allow_nan=False)

    def load_plugin(self, source, filename="plugin.plugin", expected_id=None):
        self.check_queue()
        tree, metadata, imports, classes = self.inspect(source, filename)
        inventory = import_inventory(tree, SDK_MODULES)
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
        for name in classes:
            if name not in self.capabilities["classes"]:
                raise BridgeError("LOAD_REJECTED", f"Undeclared Java class: {name}")
        allowed = SDK_MODULES | set(self.capabilities["modules"]) | set(getattr(sys, "stdlib_module_names", ()))
        for name in imports:
            native_package = any(c.startswith(name + ".") for c in self.capabilities["classes"])
            if name not in allowed and name.split(".")[0] not in allowed and not native_package:
                raise BridgeError("LOAD_REJECTED", f"Undeclared dependency: {name}")
        requirements = metadata.get("__requirements__", [])
        if not isinstance(requirements, list) or not all(isinstance(v, str) for v in requirements):
            raise BridgeError("LOAD_REJECTED", "__requirements__ must be a literal string list")
        # The host must reject unavailable pip dependencies/versions and unsupported
        # statically identified APIs here, before even the first top-level statement.
        approval = self._dispatch(plugin_id, "plugin.authorize", {"metadata": metadata, "imports": imports,
                                                                  "classes": classes, "requirements": requirements})
        if approval is not True:
            raise BridgeError("LOAD_REJECTED", "Host did not explicitly authorize execution")
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
                exec(compile(tree, filename, "exec"), module.__dict__)
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
            raise BridgeError("CALLBACK_EXPIRED", "Plugin callback generation is inactive")
        entry = scope.callbacks.get(event["callback_id"])
        if entry is None:
            raise BridgeError("CALLBACK_EXPIRED", "Unknown or released callback")
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
            return json.dumps(self.encode(result), allow_nan=False, separators=(",", ":"))

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
            raise BridgeError("NOT_LOADED", "Plugin event generation is not active")
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
            settings = scope.instance.create_settings()
            if not isinstance(settings, list):
                raise ProtocolError("create_settings must return a list")
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
        if not (fullname == "android" or fullname.startswith("android.") or fullname == "org" or fullname.startswith("org.telegram") or fullname.startswith("java.")):
            return None
        scope = runtime.require()
        if not any(name.startswith(fullname + ".") for name in runtime.capabilities["classes"]):
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


def load_plugin(source, filename="plugin.plugin", expected_id=None):
    return runtime.load_plugin(source, filename, expected_id=expected_id)


def unload_plugin(plugin_id):
    return runtime.unload_plugin(plugin_id)


def invoke_callback_json(text):
    return runtime.invoke_callback_json(text)


def emit_event_json(text):
    return runtime.emit_event_json(text)


def serialize_settings(plugin_id):
    return runtime.serialize_settings(plugin_id)
