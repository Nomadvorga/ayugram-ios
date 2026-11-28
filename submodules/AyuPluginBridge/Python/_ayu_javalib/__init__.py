"""Python-local implementations of Java classes, resolved after the host registry.

A provider is a sibling module listed in ``PROVIDER_MODULES`` that defines
``CLASSES: dict[str, type]`` keyed by the fully qualified Java name (``$`` for
nested classes). Providers are imported on first lookup, never at SDK import,
and a listed provider whose file is absent is skipped. A class may declare
``__ayu_requires__ = ("operation.name", ...)``; it is advertised only to a
host that declares every one of those operations.

The host registry wins unless the local class itself sets
``__ayu_overrides_host__ = True`` (for a host adapter that implements less than
the local class does): this module only answers which local classes
exist and which of them a given operation set makes usable. ``Runtime`` in
``ayu_bridge`` applies the precedence rule.
"""
from __future__ import annotations

import functools
import importlib
import re
import types
from pathlib import Path

PROVIDER_MODULES = (
    "java_lang", "java_reflect", "java_util", "java_io", "java_nio", "java_net", "java_text", "java_time", "org_json",
    "android_os", "android_text", "android_util", "android_content", "android_graphics", "android_bitmap", "android_compose",
    "android_intents", "android_media", "android_exif", "android_view",
    "concurrency", "telegram_tl", "telegram_messenger", "telegram_images", "telegram_events", "telegram_ui", "exteragram",
)
# Same grammar and length bound as the native class registry.
_CLASS_NAME = re.compile(r"[A-Za-z][A-Za-z0-9_.$]*\Z")
_MAX_NAME_BYTES = 256

_registry = None


class ProviderError(RuntimeError):
    """A bundled provider violates the seam contract; this is an SDK defect."""


def valid_class_name(name):
    return (isinstance(name, str) and len(name.encode("utf-8", "surrogatepass")) <= _MAX_NAME_BYTES
            and _CLASS_NAME.match(name) is not None and ".." not in name and not name.endswith("."))


def _provider_exists(name):
    return any((Path(entry) / (name + ".py")).is_file() for entry in __path__)


def requirements(cls):
    """Host operations a local class needs, validated."""
    required = getattr(cls, "__ayu_requires__", ())
    if not isinstance(required, (tuple, list)) or not all(isinstance(item, str) and item for item in required):
        raise ProviderError(f"Invalid __ayu_requires__ on {cls.__module__}.{cls.__qualname__}")
    return tuple(required)


def overrides_host(cls):
    """Whether a local class replaces a host adapter of the same name, validated.

    Read from the class's own namespace so a subclass does not inherit it.
    """
    flag = vars(cls).get("__ayu_overrides_host__", False)
    if type(flag) is not bool:
        raise ProviderError(f"Invalid __ayu_overrides_host__ on {cls.__module__}.{cls.__qualname__}")
    return flag


class HostField:
    """A read-only field of a host class in ``HOST_MEMBERS`` whose value ``getter(receiver)`` computes on each read."""
    __slots__ = ("getter",)

    def __init__(self, getter):
        self.getter = getter


def with_receiver(function):
    """Mark a ``HOST_MEMBERS`` function as taking the host object (or class facade) it is called on first."""
    function.__ayu_receiver__ = True
    return function


def returns(result):
    """Declare the class whose instance a ``HOST_MEMBERS`` function always returns, for static preflight.

    ``result`` is a Python-local class or the name of a host class.
    """
    def declare(function):
        function.__ayu_returns__ = result
        return function
    return declare


def requires(*operations):
    """Declare the host operations a ``HOST_MEMBERS`` function needs; a host without them does not get the member."""
    def declare(function):
        function.__ayu_requires__ = operations
        return function
    return declare


def _host_members(provider, module, members):
    """Validate a provider's ``HOST_MEMBERS`` and merge it into ``members``."""
    declared = getattr(module, "HOST_MEMBERS", {})
    if not isinstance(declared, dict):
        raise ProviderError(f"Provider {provider} must define HOST_MEMBERS as a dict")
    for class_name, entries in declared.items():
        if not valid_class_name(class_name) or not isinstance(entries, dict):
            raise ProviderError(f"Provider {provider} declares invalid host members")
        for name, value in entries.items():
            if not isinstance(name, str) or not name.isidentifier() or name.startswith("_"):
                raise ProviderError(f"Provider {provider} declares an invalid member of {class_name}")
            computed = value.getter if isinstance(value, HostField) else value
            if not (isinstance(computed, types.FunctionType)
                    or computed is value and (value is None or type(value) in (bool, int, float, str))):
                raise ProviderError(f"Member {class_name}.{name} must be a constant, a function or a HostField")
            if name in members.setdefault(class_name, {}):
                raise ProviderError(f"Member {class_name}.{name} is declared twice")
            members[class_name][name] = value


def _load():
    classes, owners, members = {}, {}, {}
    for provider in PROVIDER_MODULES:
        if not isinstance(provider, str) or not provider.isidentifier():
            raise ProviderError("Invalid provider module name")
        if not _provider_exists(provider):
            continue
        # An import failure in a provider that exists is a defect and must surface.
        module = importlib.import_module(__name__ + "." + provider)
        declared = getattr(module, "CLASSES", None)
        if not isinstance(declared, dict):
            raise ProviderError(f"Provider {provider} must define a CLASSES dict")
        for name, cls in declared.items():
            if not valid_class_name(name):
                raise ProviderError(f"Provider {provider} declares an invalid Java class name: {name!r}")
            if not isinstance(cls, type):
                raise ProviderError(f"Provider {provider} maps {name} to a non-class")
            if name in classes:
                raise ProviderError(f"Java class {name} is declared by both {owners[name]} and {provider}")
            requirements(cls)
            overrides_host(cls)
            classes[name], owners[name] = cls, provider
        _host_members(provider, module, members)
    for name, cls in classes.items():
        outer, separator, inner = name.rpartition("$")
        if separator and outer in classes and getattr(classes[outer], inner, None) is not cls:
            raise ProviderError(f"Nested class {name} must be the attribute {inner} of its outer class")
    names = {}
    for name, cls in classes.items():
        # One Python class may back several Java names; the first one names it in errors.
        names.setdefault(cls, name)
    return classes, names, members


def _loaded():
    global _registry
    if _registry is None:
        _registry = _load()
    return _registry


def reset():
    """Forget loaded providers (tests that change PROVIDER_MODULES or __path__)."""
    global _registry
    _registry = None


def local_classes():
    """Every bundled local class by Java name, regardless of host operations."""
    return dict(_loaded()[0])


def missing_operations(name, host_operations):
    """Operations the named local class still needs, or None if it is not local."""
    cls = _loaded()[0].get(name) if isinstance(name, str) else None
    if cls is None:
        return None
    available = set(host_operations)
    return tuple(item for item in requirements(cls) if item not in available)


def local_class(name, host_operations=None):
    """The local class for a Java name, or None.

    With ``host_operations`` the class is returned only when every operation in
    its ``__ayu_requires__`` is declared; without it the lookup is unconditional.
    """
    cls = _loaded()[0].get(name) if isinstance(name, str) else None
    if cls is None or host_operations is None:
        return cls
    available = set(host_operations)
    return cls if all(item in available for item in requirements(cls)) else None


def local_class_names(host_operations):
    """Java names of the local classes usable with the given host operations."""
    available = set(host_operations)
    return frozenset(name for name, cls in _loaded()[0].items()
                     if all(item in available for item in requirements(cls)))


def host_override_names(host_operations):
    """Usable local names that replace a host adapter of the same name."""
    classes = _loaded()[0]
    return frozenset(name for name in local_class_names(host_operations) if overrides_host(classes[name]))


def host_member(class_name, name):
    """A member the SDK serves itself on a host class, as a 1-tuple, or None.

    Providers declare ``HOST_MEMBERS = {host class name: {member: value}}`` for members that are
    pure data, yield a Python-local object or are composed over what the host answers. A plain
    value is a constant; a function is the method, called with the plugin's arguments (after the
    receiver when marked ``with_receiver``); a ``HostField`` is a computed field. ``served_member``
    applies the precedence: a member the host's own table lists stays the host's.
    """
    entries = _loaded()[2].get(class_name) if isinstance(class_name, str) else None
    return (entries[name],) if entries and name in entries else None


def _host_declares(capabilities, class_name, name, static):
    """Whether the host's own member table lists the member for that kind of target."""
    entry = (capabilities.get("members") or {}).get(class_name)
    if entry is None:
        return False
    return any(name in entry[key] for key in (("static_methods", "static_fields") if static else ("methods", "fields")))


def served_member(capabilities, class_name, name, static):
    """How the SDK itself answers ``name`` on a host class, as ``(kind, value)``, or None when the host answers.

    ``("member", value)`` is a ``HOST_MEMBERS`` entry; ``("class", cls)`` is a nested class that is
    Python-local although its outer class is the host's; ``("getClass", class_name)`` is
    ``Class.getClass()`` on the class itself (Chaquopy's spelling of ``Class.class``), composed over
    the host's ``Class.forName``; ``("reflect", name)`` is a field or method lookup of the class's
    ``Class`` object, answered from the class's member model (``java_reflect``). A member the host's
    table lists for that target stays the host's, except ``("forName", None)``: ``Class.forName``
    also has to find the Python-local classes the host does not know.
    """
    if not isinstance(class_name, str):
        return None
    if static and (class_name, name) == ("java.lang.Class", "forName") and class_name in capabilities["classes"]:
        return ("forName", None)
    if _host_declares(capabilities, class_name, name, static):
        return None
    found = host_member(class_name, name)
    if found is not None:
        needed = getattr(found[0], "__ayu_requires__", ())
        return ("member", found[0]) if all(item in capabilities["operations"] for item in needed) else None
    if static:
        nested = class_name + "$" + name
        if nested in capabilities.get("local_classes", ()) and nested not in capabilities["classes"]:
            return ("class", local_class(nested))
        if name == "getClass" and "java.lang.Class" in capabilities["classes"]:
            return ("getClass", class_name)
        if name in _REFLECTION and "java.lang.Class" in capabilities["classes"]:
            return ("reflect", name)
    return None


# ``java_lang.REFLECTION``, repeated here because providers load on first use.
_REFLECTION = frozenset({"getDeclaredField", "getField", "getDeclaredMethod", "getMethod",
                         "getDeclaredFields", "getFields", "getDeclaredMethods", "getMethods"})


def _for_name(runtime, *arguments):
    """``Class.forName(name[, initialize, loader])``: the local mirror of a Python-local class, else the host's object."""
    from ayu_bridge import BridgeError, WireTarget
    from . import java_lang
    if not 1 <= len(arguments) <= 3:
        raise TypeError("Class.forName takes (name[, initialize, loader])")
    name = arguments[0]
    if not isinstance(name, str):
        raise java_lang.NullPointerException("className == null")
    if name in runtime.capabilities["local_classes"]:
        return java_lang.Class.forName(name)
    try:
        return runtime.call("java.invoke", {"target": WireTarget({"class_name": "java.lang.Class"}), "name": "forName",
                                            "args": [name], "kwargs": {}})
    except BridgeError as error:
        if error.code != "UNSUPPORTED_API":
            raise
        raise java_lang.ClassNotFoundException(name) from None


def _is_class_object(runtime, target):
    """Whether a host object is a ``Class``: the host gives it the class's name, so only its members tell."""
    from ayu_bridge import BridgeError, WireTarget
    try:
        runtime.call("java.member", {"target": WireTarget(target), "name": "isPrimitive"})
    except BridgeError as error:
        if error.code != "UNSUPPORTED_API":
            raise
        return False
    return True


def _reflect(class_name, name, *arguments):
    from . import java_reflect
    return java_reflect.reflect(class_name, name, arguments)


def serve(runtime, target, name):
    """The value of an SDK-served member of a host target as a 1-tuple, or None when the host answers it."""
    scope = runtime.require()
    static = "class_name" in target
    class_name = target.get("class_name") if static else target.get("$class")
    found = served_member(runtime.capabilities, class_name, name, static)
    if (found is None and not static and name in _REFLECTION and served_member(runtime.capabilities, class_name, name, True)
            and _is_class_object(runtime, target)):
        # The host's Class object of a class answers what the class's facade answers.
        found = ("reflect", name)
    if found is None:
        return None
    kind, value = found
    if kind == "getClass":
        return (lambda: runtime.jclass("java.lang.Class").forName(value),)
    if kind == "forName":
        return (functools.partial(_for_name, runtime),)
    if kind == "reflect":
        return (functools.partial(_reflect, class_name, value),)
    if kind == "member" and (isinstance(value, HostField) or getattr(value, "__ayu_receiver__", False)):
        import ayu_bridge
        receiver = (ayu_bridge.JavaClass(runtime, scope, class_name) if static
                    else ayu_bridge.RemoteObject(runtime, scope, target["$handle"], class_name))
        return (value.getter(receiver),) if isinstance(value, HostField) else (functools.partial(value, receiver),)
    return (value,)


def local_name(value):
    """Java name of a local class, or of the local class an object is an instance of."""
    names = _loaded()[1]
    for base in (value if isinstance(value, type) else type(value)).__mro__:
        try:
            name = names.get(base)
        except TypeError:  # a class whose metaclass makes it unhashable
            name = None
        if name is not None:
            return name
    return None
