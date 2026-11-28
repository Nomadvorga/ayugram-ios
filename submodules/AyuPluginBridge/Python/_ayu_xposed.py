"""Xposed method hooks served by named hook points instead of method patching.

``TARGETS`` lists the Android methods the bridge can raise itself: each belongs to a hook point,
an event with a typed payload, and names the host operation that makes the point real. A hook
on a listed target is kept by the SDK and run with a synthesized ``MethodHookParam`` when the
point fires; a hook on any other target stays the reserved ``hooks.java_method``.

A target is named the way Android names it: the method is a member of its Python-local class, so
``java_reflect`` finds it, and the class of a host object stands for an Android class through
``HOST_CLASSES``. The design is in ``docs/plugins-xposed-hook-mapping.md`` ("Implemented").
Nothing here patches code: a point fires only where the bridge calls ``fire``.
"""
from __future__ import annotations

import ast
import itertools
from dataclasses import dataclass

import _ayu_hook_map
import _ayu_javalib

# ``XC_MethodHook.PRIORITY_DEFAULT``.
PRIORITY_DEFAULT = 50
MAX_HOOKS = 256
APIS = ("hook_method", "hook_all_methods", "hook_all_constructors")


@dataclass(frozen=True)
class HookPoint:
    """A named event the bridge raises; ``operation`` is the host operation it cannot exist without."""
    name: str
    operation: str


@dataclass(frozen=True)
class Target:
    """One Android method served by a point: ``parameters`` and ``result`` are Java type names.

    ``live_receiver`` lets static preflight take the method named on the class of an object it
    cannot type (``activity.getClass()``) for this target: no other class the bridge hands out
    declares a method of that name, and at run time another class has no such method.
    """
    class_name: str
    method: str
    parameters: tuple
    result: str
    point: HookPoint
    live_receiver: bool = False

    @property
    def label(self):
        return self.class_name + "." + self.method


ACTIVITY_RESULT_POINT = HookPoint("activity.result", "intents.launch")
# The result of a picker the plugin itself started with ``startActivityForResult``.
ACTIVITY_RESULT = Target("org.telegram.ui.LaunchActivity", "onActivityResult",
                         ("int", "int", "android.content.Intent"), "void", ACTIVITY_RESULT_POINT, live_receiver=True)

URL_OPEN_POINT = HookPoint("url.open", "hooks.url_open")
_URL_SIGNATURE = ("android.content.Context", "java.lang.String")
# Android chains its ``openUrl`` overloads into each other; the point reports the one a link tap enters.
URL_OPEN = Target("org.telegram.messenger.browser.Browser", "openUrl", _URL_SIGNATURE, "void", URL_OPEN_POINT)
URL_OPEN_SYSTEM = Target("org.telegram.messenger.browser.Browser", "openUrlInSystemBrowser", _URL_SIGNATURE, "void",
                         URL_OPEN_POINT)

TARGETS = {(target.class_name, target.method): (target,) for target in (ACTIVITY_RESULT, URL_OPEN, URL_OPEN_SYSTEM)}
# A host class whose objects are, for naming a hook target, instances of an Android class.
HOST_CLASSES = {"android.content.Context": "org.telegram.ui.LaunchActivity"}
_LIVE_RECEIVER = {target.method: target for overloads in TARGETS.values() for target in overloads if target.live_receiver}


def _lang():
    from _ayu_javalib import java_lang
    return java_lang


def _log(message):
    from android_utils import log
    log(message)


def android_class(value):
    """The Android class name of what a plugin passed as a class or ``java.lang.Class``, or None."""
    lang = _lang()
    if isinstance(value, lang.Class):
        name = value.getName()
    elif isinstance(value, type):
        name = _ayu_javalib.local_name(value)
    elif type(value).__name__ == "JavaClass":
        name = value._name
    elif type(value).__name__ == "RemoteObject":
        # A class handle and an instance carry the same class tag; only a class answers ``getName``.
        from ayu_bridge import BridgeError
        try:
            name = value._runtime.call("java.invoke", {"target": value, "name": "getName", "args": [], "kwargs": {}})
        except BridgeError:
            return None
    else:
        return None
    return HOST_CLASSES.get(name, name) if isinstance(name, str) else None


def mapped(class_name, method):
    """The targets of a class and method name, or None."""
    return TARGETS.get((HOST_CLASSES.get(class_name, class_name), method))


def _reflected(member):
    """The targets a ``java.lang.reflect.Method`` of the SDK's reflection names, or None."""
    reflected = _ayu_javalib.local_class("java.lang.reflect.Method")
    if reflected is None or not isinstance(member, reflected):
        return None
    class_name = android_class(member.getDeclaringClass())
    return None if class_name is None else mapped(class_name, member.getName())


def method_of(target):
    """The reflected ``Method`` of a target, as ``Class.getDeclaredMethod`` returns it; None without reflection."""
    from ayu_bridge import BridgeError, runtime
    lang = _lang()
    try:
        return runtime.jclass(target.class_name).getClass().getDeclaredMethod(target.method, *target.parameters)
    except (BridgeError, AttributeError, lang.Throwable):
        return None


class MethodHookParam:
    """``XC_MethodHook.MethodHookParam`` built by the bridge for one firing of a point."""

    def __init__(self, method, this_object, args):
        self.method, self.thisObject, self.args = method, this_object, list(args)
        self._result, self._throwable, self._return_early, self._extra = None, None, False, None

    def getResult(self):
        return self._result

    def setResult(self, result):
        self._result, self._throwable, self._return_early = result, None, True

    def getThrowable(self):
        return self._throwable

    def hasThrowable(self):
        return self._throwable is not None

    def setThrowable(self, throwable):
        if throwable is not None and not isinstance(throwable, BaseException):
            raise TypeError("setThrowable takes an exception")
        self._throwable, self._result, self._return_early = throwable, None, True

    def getResultOrThrowable(self):
        if self._throwable is not None:
            raise self._throwable
        return self._result

    def getExtra(self):
        if self._extra is None:
            from ayu_bridge import runtime
            self._extra = runtime.jclass("android.os.Bundle")()
        return self._extra


class Unhook:
    """``XC_MethodHook.Unhook``."""

    def __init__(self, hook):
        self._hook = hook

    def getHookedMethod(self):
        return method_of(self._hook.target)

    def getCallback(self):
        return self._hook.callback

    def unhook(self):
        hook = self._hook
        if hook.active:
            hook.active = False
            installed = hook.store.get(hook.target, [])
            if hook in installed:
                installed.remove(hook)

    cancel = dispose = unhook


class _Hook:
    __slots__ = ("target", "callback", "priority", "order", "before", "after", "before_filters", "after_filters",
                 "active", "store")


_order = itertools.count()


def _store():
    """Hooks of the current plugin generation by target, each list in firing order."""
    return _lang().scoped_store("xposed_hooks")


def _filters(source, hook):
    """Android's ``cast_to_array_list`` over a ``__hook_filters__`` value, as ``HookFilterData``."""
    from ayu_bridge import UnsupportedAPI
    from base_plugin import HookFilter, HookFilterData
    values = source(hook) if callable(source) else source
    result = []
    for item in values or ():
        item = item.filter_data if isinstance(item, HookFilter) else item
        if not isinstance(item, HookFilterData):
            raise TypeError("Expected HookFilter or HookFilterData")
        pending = [item]
        while pending:
            current = pending.pop()
            if current.filter_type == "condition":
                raise UnsupportedAPI("MVEL hook filter conditions are not evaluated; filter in the callback")
            pending.extend(current.or_filters or ())
        result.append(item)
    return result


def _is_instance(value, clazz):
    lang = _lang()
    if isinstance(clazz, lang.Class):
        return clazz.isInstance(value)
    if isinstance(clazz, type):
        return isinstance(value, clazz)
    name = getattr(clazz, "_name", None)
    return isinstance(name, str) and getattr(value, "_class_name", None) == name


def _passes(item, param, is_before):
    """``HookFilter.execute``."""
    kind = item.filter_type
    if kind == "or":
        return any(_passes(inner, param, is_before) for inner in item.or_filters or ())
    if kind.startswith("argument_"):
        index = item.arg_index
        if type(index) is not int or not 0 <= index < len(param.args):
            return False
        value = param.args[index]
    elif kind.startswith("result_"):
        if is_before:
            return False
        value = param.getResult()
    else:
        return False
    test = kind.partition("_")[2]
    if test == "equal":
        return value == item.object
    if test == "not_equal":
        return value != item.object
    if test == "is_instance_of":
        return item.instance_of is not None and _is_instance(value, item.instance_of)
    if test == "is_null":
        return value is None
    if test == "not_null":
        return value is not None
    if test == "is_true":
        return value is True
    if test == "is_false":
        return value is False
    return False


def _phases(plugin, xposed_hook, before, after, before_filters, after_filters):
    """``(callback, before, after, before filters, after filters)`` as Android's ``__get_java_callback_instance``.

    None when the hook type cannot be determined, which Android logs before it returns None.
    """
    from base_plugin import BaseHook, MethodHook, MethodReplacement
    if xposed_hook is None and before is None and after is None:
        raise TypeError("xposed_hook or before or after cannot be None")
    if xposed_hook:
        hook = xposed_hook
        replace = getattr(hook, "replace_hooked_method", None)
        if isinstance(hook, MethodReplacement) or not isinstance(hook, MethodHook) and callable(replace):
            def replaced(param):
                # ``XC_MethodReplacement``: the returned value is the result and the original never runs.
                try:
                    param.setResult(replace(param))
                except Exception as error:
                    _log(f"Method replacement failed: {type(error).__name__}")
                    param.setResult(None)
            return hook, replaced, None, [], []
        phases = []
        for name in ("before_hooked_method", "after_hooked_method"):
            method = getattr(hook, name, None)
            enabled = callable(method)
            if enabled and isinstance(hook, MethodHook):
                # A ``MethodHook`` phase exists only where the subclass overrides it.
                enabled = getattr(method, "__func__", None) is not getattr(MethodHook, name)
            phases.append(method if enabled else None)
        if phases == [None, None]:
            return None
        return (hook, phases[0], phases[1],
                _filters(getattr(phases[0], "__hook_filters__", None), hook) if phases[0] else [],
                _filters(getattr(phases[1], "__hook_filters__", None), hook) if phases[1] else [])
    if not (before or after) or (before and not callable(before)) or (after and not callable(after)):
        raise TypeError("xposed_hook or before or after cannot be None")
    hook = BaseHook(plugin, before=before, after=after, before_filters=before_filters, after_filters=after_filters)
    return (hook, hook.before_hooked_method if before else None, hook.after_hooked_method if after else None,
            _filters(before_filters, hook) if before else [], _filters(after_filters, hook) if after else [])


def _install(plugin, targets, xposed_hook, priority, before, after, before_filters, after_filters):
    from ayu_bridge import BridgeError, runtime
    import _ayu_operations
    scope = runtime.require()
    if scope.state == "unloading":
        raise BridgeError("PLUGIN_UNLOADING", "Cannot register during unload")
    for target in targets:
        _ayu_operations.require(target.point.operation, f"A hook on {target.label}")
    phases = _phases(plugin, xposed_hook, before, after, before_filters, after_filters)
    if phases is None:
        _log(f"Could not determine hook type for {type(xposed_hook).__name__}.")
        return None
    if priority is not None and type(priority) is not int:
        raise TypeError("priority must be an int")
    store = _store()
    if sum(len(items) for items in store.values()) + len(targets) > MAX_HOOKS:
        raise BridgeError("RESOURCE_LIMIT", "Method hook limit reached")
    unhooks = []
    for target in targets:
        hook = _Hook()
        hook.target, hook.store, hook.active = target, store, True
        hook.callback, hook.before, hook.after, hook.before_filters, hook.after_filters = phases
        hook.priority, hook.order = PRIORITY_DEFAULT if priority is None else priority, next(_order)
        installed = store.setdefault(target, [])
        installed.append(hook)
        # Xposed runs the higher priority first; equal priorities keep the order they were added in.
        installed.sort(key=lambda item: (-item.priority, item.order))
        unhooks.append(Unhook(hook))
    return unhooks


def hook_method(plugin, member, xposed_hook=None, priority=None, *, before=None, after=None,
                before_filters=None, after_filters=None):
    """``BasePlugin.hook_method`` for a reflected method a point serves; ``NotImplemented`` for any other member.

    Returns one ``Unhook``, or None when the hook type cannot be determined (Android logs and returns None).
    Reflection does not tell overloads apart, so every overload of the name is hooked.
    """
    targets = _reflected(member)
    if targets is None:
        return NotImplemented
    unhooks = _install(plugin, list(targets), xposed_hook, priority, before, after, before_filters, after_filters)
    return unhooks[0] if unhooks else None


def hook_all_methods(plugin, hook_class, method_name, xposed_hook=None, priority=None, *, before=None, after=None,
                     before_filters=None, after_filters=None):
    """``BasePlugin.hook_all_methods`` for a mapped class and name: a list of ``Unhook``; else ``NotImplemented``."""
    class_name = android_class(hook_class)
    overloads = mapped(class_name, method_name) if class_name is not None else None
    if overloads is None:
        return NotImplemented
    return _install(plugin, list(overloads), xposed_hook, priority, before, after, before_filters, after_filters)


def _run(function, filters, param, is_before, label):
    if function is None or not all(_passes(item, param, is_before) for item in filters):
        return
    from ayu_bridge import BridgeError
    try:
        function(param)
    except BridgeError as error:
        # ``PyMethodHook`` catches everything a callback throws; a bridge failure is still worth its code.
        _log(f"Hook callback on {label} failed: {error.code}")
    except Exception as error:
        _log(f"Hook callback on {label} failed: {type(error).__name__}")


def fire(target, this_object, args):
    """Raise ``target`` for the current plugin generation, as ``XposedBridge.handleHookedMethod`` runs its hooks.

    Before hooks run from the highest priority down and stop after one that set a result or a
    throwable; the after hooks of those that ran follow in reverse. There is no original method
    behind a point, so nothing runs between the phases. Returns the ``MethodHookParam``.
    """
    hooks = [hook for hook in _store().get(target, ()) if hook.active]
    param = MethodHookParam(method_of(target) if hooks else None, this_object, args)
    ran = 0
    for hook in hooks:
        ran += 1
        _run(hook.before, hook.before_filters, param, True, target.label)
        if param._return_early:
            break
    # What the original method would have been called with, and whether Xposed would have skipped it.
    param._call_args, param._call_skipped = list(param.args), param._return_early
    # Xposed walks one snapshot of the callbacks: a hook removed while the point fires still gets its after phase.
    for hook in reversed(hooks[:ran]):
        _run(hook.after, hook.after_filters, param, False, target.label)
    if param.hasThrowable():
        _log(f"A hook on {target.label} set {type(param.getThrowable()).__name__}; the bridge has no caller to throw it to")
    return param


def hook_count(target):
    return sum(1 for hook in _store().get(target, ()) if hook.active)


def open_url(url, context=None, system_browser=False):
    """Raise ``url.open`` for a URL the app is about to open: the URL to open, or None when a hook cancelled it.

    A before hook cancels by setting a result or a throwable (Xposed then skips the original) and
    rewrites by replacing ``args[1]``; ``Browser.openUrl`` itself returns at once for a null URL.
    The after phase runs before the app opens the URL: the method is void and nothing reads its result.
    """
    target = URL_OPEN_SYSTEM if system_browser else URL_OPEN
    if not hook_count(target):
        return url
    if context is None:
        from ayu_bridge import runtime
        context = runtime.jclass("org.telegram.messenger.ApplicationLoader").applicationContext
    param = fire(target, None, [context, url])
    if param._call_skipped or len(param._call_args) < 2 or param._call_args[1] is None:
        return None
    return str(param._call_args[1])


# --- static preflight ----------------------------------------------------------------------

_CLASS_FINDERS = frozenset({"find_class", "jclass"})
_METHOD_FINDERS = frozenset({"getDeclaredMethod", "getMethod"})
_METHOD_LISTS = frozenset({"getDeclaredMethods", "getMethods"})
_ACTIVITY = "org.telegram.ui.LaunchActivity"
_MAX_DEPTH = 12
_MAX_STEPS = 20_000


class _Inspector:
    """What each hook call of a source names, read from the AST alone.

    Values are followed through single assignments, ``self`` attributes, loops over literal
    sequences and over ``getDeclaredMethods()`` narrowed by a ``getName()`` test. Anything else
    is unknown, and a hook whose target is unknown is not served.
    """

    def __init__(self, tree):
        self.parents, self.bindings, self.steps = {}, {}, 0
        pending = [(tree, None)]
        while pending:
            node, scope = pending.pop()
            inner = node if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)) else scope
            if inner is not scope:
                arguments = node.args
                for item in arguments.posonlyargs + arguments.args + arguments.kwonlyargs + [arguments.vararg, arguments.kwarg]:
                    if item is not None:
                        self._bind((id(inner), item.arg), None)
            self._collect(node, scope)
            for child in ast.iter_child_nodes(node):
                self.parents[id(child)] = node
                pending.append((child, inner))
        self.scopes = {}
        pending = [(tree, None)]
        while pending:
            node, scope = pending.pop()
            self.scopes[id(node)] = scope
            inner = node if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)) else scope
            pending.extend((child, inner) for child in ast.iter_child_nodes(node))

    def _bind(self, key, value):
        self.bindings.setdefault(key, []).append(value)

    def _key(self, target, scope):
        if isinstance(target, ast.Name):
            return (id(scope) if scope is not None else None, target.id)
        if isinstance(target, ast.Attribute) and isinstance(target.value, ast.Name) and target.value.id == "self":
            return ("self", target.attr)
        return None

    def _bind_target(self, target, value, scope):
        key = self._key(target, scope)
        if key is not None:
            self._bind(key, value)
        elif isinstance(target, (ast.Tuple, ast.List, ast.Starred)):
            for item in ast.walk(target):
                if isinstance(item, (ast.Name, ast.Attribute)):
                    inner = self._key(item, scope)
                    if inner is not None:
                        self._bind(inner, None)

    def _collect(self, node, scope):
        if isinstance(node, ast.Assign):
            for target in node.targets:
                self._bind_target(target, ("value", node.value), scope)
        elif isinstance(node, (ast.AnnAssign, ast.NamedExpr)) and node.value is not None:
            self._bind_target(node.target, ("value", node.value), scope)
        elif isinstance(node, ast.AugAssign):
            self._bind_target(node.target, None, scope)
        elif isinstance(node, (ast.For, ast.AsyncFor, ast.comprehension)):
            self._bind_target(node.target, ("item", node.iter), scope)
        elif isinstance(node, (ast.With, ast.AsyncWith)):
            for item in node.items:
                if item.optional_vars is not None:
                    self._bind_target(item.optional_vars, None, scope)
        elif isinstance(node, ast.ExceptHandler) and node.name:
            self._bind((id(scope) if scope is not None else None, node.name), None)
        elif isinstance(node, ast.ImportFrom) and node.module and not node.level:
            for alias in node.names:
                self._bind((id(scope) if scope is not None else None, alias.asname or alias.name),
                           ("class", node.module + "." + alias.name))
        elif isinstance(node, ast.Import):
            for alias in node.names:
                self._bind((id(scope) if scope is not None else None, (alias.asname or alias.name).split(".")[0]), None)
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            self._bind((id(scope) if scope is not None else None, node.name), None)

    def _lookup(self, node):
        """Bindings of a name or ``self`` attribute read at ``node``, or None when it has none here."""
        if isinstance(node, ast.Attribute):
            return self.bindings.get(("self", node.attr))
        scope = self.scopes.get(id(node))
        while True:
            found = self.bindings.get((id(scope) if scope is not None else None, node.id))
            if found is not None or scope is None:
                return found
            scope = self.scopes.get(id(scope))

    def _named(self, node, variable):
        """The one method name a ``getName()`` test around ``node`` leaves for the loop variable, or None."""
        names = set()
        current = node
        while id(current) in self.parents:
            parent = self.parents[id(current)]
            tests = []
            if isinstance(parent, ast.If) and current is not parent.test and current in parent.body:
                tests.append(parent.test)
            elif isinstance(parent, ast.IfExp) and current is parent.body:
                tests.append(parent.test)
            elif isinstance(parent, (ast.ListComp, ast.GeneratorExp, ast.SetComp)):
                tests.extend(test for generator in parent.generators for test in generator.ifs)
            elif isinstance(parent, ast.comprehension):
                tests.extend(parent.ifs)
            for test in tests:
                # Only a conjunction of tests narrows: ``or`` and ``not`` let other methods through.
                if any(isinstance(item, (ast.Or, ast.Not)) for item in ast.walk(test)):
                    return None
                for compare in ast.walk(test):
                    if not isinstance(compare, ast.Compare) or len(compare.ops) != 1 or not isinstance(compare.ops[0], ast.Eq):
                        continue
                    sides = [compare.left, compare.comparators[0]]
                    literal = [side.value for side in sides if isinstance(side, ast.Constant) and isinstance(side.value, str)]
                    reads = any(isinstance(call, ast.Call) and isinstance(call.func, ast.Attribute)
                                and call.func.attr == "getName" and isinstance(call.func.value, ast.Name)
                                and call.func.value.id == variable for side in sides for call in ast.walk(side))
                    if len(literal) == 1 and reads:
                        names.add(literal[0])
            if isinstance(parent, (ast.For, ast.AsyncFor)) and self._key(parent.target, None) == (None, variable):
                break
            current = parent
        return names.pop() if len(names) == 1 else None

    def value(self, node, depth=0):
        """The set of things ``node`` can be, or None when that is not certain.

        ``("class", name)``, ``("mirror", name or None)`` (a ``java.lang.Class``), ``("instance", name)``,
        ``("method", class or None, name)``, ``("methods", class or None, name or None)`` and ``("str", text)``.
        """
        self.steps += 1
        if depth > _MAX_DEPTH or self.steps > _MAX_STEPS:
            return None
        if isinstance(node, ast.Constant):
            if node.value is None:
                return frozenset()
            return frozenset({("str", node.value)}) if isinstance(node.value, str) else None
        if isinstance(node, ast.Name) or (isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name)
                                           and node.value.id == "self"):
            bindings = self._lookup(node)
            if not bindings:
                return None
            found = set()
            for binding in bindings:
                if binding is None:
                    return None
                if binding[0] == "class":
                    found.add(binding)
                    continue
                values = self.value(binding[1], depth + 1)
                if values is None:
                    return None
                if binding[0] == "item":
                    values = self._items(values, node)
                    if values is None:
                        return None
                found |= values
            return frozenset(found)
        if isinstance(node, ast.Attribute):
            if node.attr == "instance" and self.value(node.value, depth + 1) == {("class", _ACTIVITY)}:
                return frozenset({("instance", _ACTIVITY)})
            return None
        if isinstance(node, (ast.List, ast.Tuple)):
            found = set()
            for element in node.elts:
                values = self.value(element, depth + 1)
                if values is None:
                    return None
                found.add(("sequence", values))
            return frozenset(found)
        if isinstance(node, (ast.ListComp, ast.GeneratorExp)) and len(node.generators) == 1 and isinstance(node.elt, ast.Name):
            return self.value(node.elt, depth + 1)
        if isinstance(node, ast.Subscript):
            values = self.value(node.value, depth + 1)
            return self._items(values, node) if values is not None else None
        if isinstance(node, ast.IfExp):
            first, second = self.value(node.body, depth + 1), self.value(node.orelse, depth + 1)
            return None if first is None or second is None else first | second
        if isinstance(node, ast.Call):
            return self._call(node, depth)
        return None

    def _items(self, values, site):
        """Elements of a sequence value read at ``site`` (a loop variable or a subscript)."""
        found = set()
        for value in values:
            if value[0] == "sequence":
                found |= value[1]
            elif value[0] == "methods":
                name = value[2]
                if name is None and isinstance(site, ast.Name):
                    name = self._named(site, site.id)
                if name is None:
                    return None
                found.add(("method", value[1], name))
            elif value[0] == "method":
                # A comprehension over narrowed methods was evaluated through its element.
                found.add(value)
            else:
                return None
        return frozenset(found)

    def _classes(self, node, depth, mirrors):
        """Class names an expression denotes as a class proxy (or, with ``mirrors``, as a ``Class``)."""
        values = self.value(node, depth + 1)
        if not values:
            return None
        names = set()
        for value in values:
            if value[0] not in (("mirror",) if mirrors else ("class", "mirror")):
                return None
            names.add(value[1])
        return names

    def _call(self, node, depth):
        function = node.func
        name = function.attr if isinstance(function, ast.Attribute) else function.id if isinstance(function, ast.Name) else None
        first = node.args[0] if node.args else None
        literal = first.value if isinstance(first, ast.Constant) and isinstance(first.value, str) else None
        if name in _CLASS_FINDERS and literal is not None:
            return frozenset({("class", literal)})
        if name == "forName" and literal is not None:
            return frozenset({("mirror", literal)})
        if name == "get_method" and len(node.args) >= 2:
            owners, names = self._classes(first, depth, False), self.value(node.args[1], depth + 1)
            if owners is None or not names or any(item[0] != "str" for item in names):
                return None
            return frozenset(("method", owner, item[1]) for owner in owners for item in names)
        if not isinstance(function, ast.Attribute):
            return None
        if name == "getParentActivity" and not node.args:
            return frozenset({("instance", _ACTIVITY)})
        if name == "getClass" and not node.args:
            values = self.value(function.value, depth + 1)
            if values is None:
                # The class of an object inspection cannot type.
                return frozenset({("mirror", None)})
            if not values or any(value[0] not in ("class", "instance") for value in values):
                return None
            return frozenset(("mirror", value[1]) for value in values)
        if name in _METHOD_FINDERS and first is not None:
            owners, names = self._classes(function.value, depth, True), self.value(first, depth + 1)
            if owners is None or not names or any(item[0] != "str" for item in names):
                return None
            return frozenset(("method", owner, item[1]) for owner in owners for item in names)
        if name in _METHOD_LISTS and not node.args:
            owners = self._classes(function.value, depth, True)
            return None if owners is None else frozenset(("methods", owner, None) for owner in owners)
        return None

    @staticmethod
    def _target(owner, name):
        """Labels of the mapped overloads of a method, or None when it is not mapped."""
        if owner is None:
            target = _LIVE_RECEIVER.get(name)
            return None if target is None else {target.label}
        overloads = TARGETS.get((HOST_CLASSES.get(owner, owner), name))
        return None if overloads is None else {target.label for target in overloads}

    def site(self, api, call):
        """Labels of the mapped targets one hook call names, or None when it names anything else."""
        arguments = {keyword.arg: keyword.value for keyword in call.keywords if keyword.arg}
        positional = list(call.args)
        if any(isinstance(item, ast.Starred) for item in positional) or any(keyword.arg is None for keyword in call.keywords):
            return None
        labels = set()
        if _ayu_hook_map.static_undetermined(api, positional, arguments):
            # Android registers nothing for this call, whatever target it names.
            return labels
        if api == "hook_method":
            member = positional[0] if positional else arguments.get("method_or_constructor")
            values = self.value(member) if member is not None else None
            if not values:
                return None
            for value in values:
                found = self._target(value[1], value[2]) if value[0] == "method" else None
                if found is None:
                    return None
                labels |= found
            return labels
        if api == "hook_all_methods":
            owner = positional[0] if positional else arguments.get("hook_class")
            method = positional[1] if len(positional) > 1 else arguments.get("method_name")
            names = self.value(method) if method is not None else None
            if owner is None or not names or any(item[0] != "str" for item in names):
                return None
            owners = self.value(owner)
            if owners is None:
                owners = {("mirror", None)}
            if not owners or any(item[0] not in ("class", "mirror") for item in owners):
                return None
            for item in owners:
                for method_name in names:
                    found = self._target(item[1], method_name[1])
                    if found is None:
                        return None
                    labels |= found
            return labels
        return None


def static_targets(tree):
    """Per hook API a source calls: the sorted labels of the mapped targets it names, or None.

    The list is empty when every call of the API is one Android drops (``_ayu_hook_map``).

    None means at least one call of that API names a target inspection cannot resolve or the
    table does not list; such a source needs ``hooks.java_method``.
    """
    calls = [node for node in ast.walk(tree) if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
             and node.func.attr in APIS]
    if not calls:
        return {}
    inspector = _Inspector(tree)
    found = {}
    for call in calls:
        api = call.func.attr
        labels = inspector.site(api, call)
        if labels is None or found.get(api, set()) is None:
            found[api] = None
        else:
            found.setdefault(api, set()).update(labels)
    return {api: None if labels is None else sorted(labels) for api, labels in found.items()}


def requirement(label):
    """The operation requirement of a mapped target label, as ``_ayu_operations`` groups."""
    class_name, _, method = label.rpartition(".")
    return tuple(dict.fromkeys((target.point.operation,) for target in TARGETS[(class_name, method)]))
