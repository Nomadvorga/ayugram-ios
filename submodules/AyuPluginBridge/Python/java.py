"""Registry-backed Java syntax facade; there is no JVM or symbol lookup."""
from __future__ import annotations

import math
import sys
import types

import _ayu_javalib
from ayu_bridge import DynamicProxy, JavaClass, RemoteObject, UnsupportedAPI, runtime

# Allow java.lang etc. to be resolved by the registry-backed native importer.
__path__ = []


def jclass(name):
    return runtime.jclass(name)


def _local_name(value):
    """Java name when ``value`` is a Python-local Java class (or a subclass of one)."""
    return _ayu_javalib.local_name(value) if isinstance(value, type) else None


def dynamic_proxy(*interfaces):
    scope = runtime.require()
    if not interfaces:
        raise TypeError("At least one declared interface is required")
    local = [interface for interface in interfaces if _local_name(interface) is not None]
    if local:
        # A local interface is an ordinary Python base class: the proxy is consumed by
        # other local classes, and reaches the host only through the interface's to_bridge.
        if len(local) != len(interfaces):
            raise UnsupportedAPI("A proxy cannot combine host-declared and Python-local interfaces")
        try:
            return type("LocalListenerProxy", tuple(dict.fromkeys(local)), {"__module__": __name__})
        except TypeError as error:
            raise UnsupportedAPI("These Python-local interfaces cannot be combined in one proxy") from error
    names, methods = [], []
    for interface in interfaces:
        if not isinstance(interface, JavaClass):
            raise TypeError("dynamic_proxy requires declared Java interface facades")
        runtime.require(interface._scope)
        name = interface._name
        declared = runtime.capabilities["proxy_interfaces"].get(name)
        if declared is None:
            raise UnsupportedAPI(f"No native proxy adapter for {name}")
        names.append(name)
        methods.extend(declared)
    return type("NativeListenerProxy", (DynamicProxy,), {
        "_ayu_interfaces": tuple(names),
        "_ayu_interfaces_methods": tuple(dict.fromkeys(methods)),
        "__module__": __name__,
    })


class _Primitive:
    def __init__(self, name, bits=None, floating=False):
        self.__ayu_java_type__ = name
        self.bits, self.floating = bits, floating

    def __call__(self, value=0):
        name = self.__ayu_java_type__
        if name == "boolean":
            if type(value) is bool:
                return value
            if type(value) is int and value in (0, 1):
                return bool(value)
            raise ValueError("jboolean accepts bool or 0/1")
        if name == "char":
            if isinstance(value, str) and len(value) == 1 and ord(value) <= 65535:
                return value
            raise ValueError("jchar requires one UTF-16 code unit")
        if self.floating:
            result = float(value)
            if not math.isfinite(result) or name == "float" and abs(result) > 3.4028234663852886e38:
                raise OverflowError(f"Invalid Java {name}")
            return result
        result = int(value)
        if not -(2 ** (self.bits - 1)) <= result < 2 ** (self.bits - 1):
            raise OverflowError(f"Value is outside Java {name} range")
        return result


jbyte = _Primitive("byte", 8)
jshort = _Primitive("short", 16)
jint = _Primitive("int", 32)
jlong = _Primitive("long", 64)
jfloat = _Primitive("float", floating=True)
jdouble = _Primitive("double", floating=True)
jboolean = _Primitive("boolean")
jchar = _Primitive("char")
_SIGNATURES = {"Z": jboolean, "B": jbyte, "S": jshort, "I": jint, "J": jlong, "F": jfloat, "D": jdouble,
               "C": jchar}


class LocalArray(list):
    """Fixed-length array of a Python-local Java class; it never becomes a host array."""

    def __init__(self, component, values):
        super().__init__(values)
        self.component = component

    @property
    def length(self):
        return len(self)

    def _check(self, value):
        if not (value is None or type(value) in (bool, int, float, str) or isinstance(value, self.component)):
            raise TypeError("Array element is not an instance of " + _local_name(self.component))
        return value

    def __setitem__(self, index, value):
        if isinstance(index, slice):
            value = [self._check(item) for item in value]
            if len(value) != len(range(*index.indices(len(self)))):
                raise ValueError("A Java array cannot change its length")
        else:
            self._check(value)
        super().__setitem__(index, value)

    def _fixed(self, *args, **kwargs):
        raise TypeError("A Java array cannot change its length")

    append = extend = insert = pop = remove = clear = __delitem__ = __iadd__ = __imul__ = _fixed


def _local_array(component):
    def construct(values):
        if type(values) is int:
            if values < 0 or values > 100000:
                raise ValueError("Invalid native array length")
            values = [None] * values
        else:
            values = list(values)
            if len(values) > 100000:
                raise ValueError("Native array exceeds supported length")
        array = LocalArray(component, values)
        for value in values:
            array._check(value)
        return array

    return construct


def _signature_component(signature):
    """Chaquopy accepts a JNI type signature in place of a component class."""
    if signature in _SIGNATURES:
        return _SIGNATURES[signature]
    if signature.startswith("L") and signature.endswith(";") and len(signature) > 2:
        return jclass(signature[1:-1].replace("/", "."))
    raise UnsupportedAPI(f"Unsupported array component signature: {signature}")


def jarray(component):
    scope = runtime.require()
    if isinstance(component, str):
        component = _signature_component(component)
    if _local_name(component) is not None:
        return _local_array(component)
    if isinstance(component, JavaClass):
        runtime.require(component._scope)
        name = component._name
    elif isinstance(component, _Primitive):
        name = component.__ayu_java_type__
    else:
        raise TypeError("Array component must be a Java class or primitive")

    def construct(values):
        runtime.require(scope)
        if type(values) is int:
            if values < 0 or values > 100000:
                raise ValueError("Invalid native array length")
            default = False if name == "boolean" else "\0" if name == "char" else 0 if isinstance(component, _Primitive) else None
            values = [default] * values
        else:
            values = list(values)
            if len(values) > 100000:
                raise ValueError("Native array exceeds supported length")
        if isinstance(component, _Primitive):
            values = [component(value) for value in values]
        return runtime.call("java.array", {"component": name, "values": values})

    return construct


def cast(clazz, value):
    runtime.require()
    if isinstance(clazz, str):
        clazz = jclass(clazz)
    if _local_name(clazz) is not None:
        if value is None or isinstance(value, clazz):
            return value
        if isinstance(value, RemoteObject):
            name = _local_name(clazz)
            # A local class that overrides a host adapter leaves host instances to the host's cast.
            if name in runtime.capabilities["classes"] and _ayu_javalib.local_class(name) is clazz:
                return runtime.call("java.cast", {"class_name": name, "value": value})
            raise UnsupportedAPI("A host object cannot be cast to the Python-local class " + name)
        raise TypeError("Value is not an instance of " + _local_name(clazz))
    if not isinstance(clazz, JavaClass):
        raise TypeError("cast requires a declared Java class")
    runtime.require(clazz._scope)
    return runtime.call("java.cast", {"class_name": clazz._name, "value": value})


# Chaquopy functions with no counterpart here: there is no JVM to subclass, load DEX into or
# detach from, so they fail on access instead of being absent or doing nothing.
_UNAVAILABLE = {
    "static_proxy": "Java subclasses cannot be defined without a JVM",
    "constructor": "Java subclasses cannot be defined without a JVM",
    "method": "Java subclasses cannot be defined without a JVM",
    "Override": "Java subclasses cannot be defined without a JVM",
    "add_class_loader": "DEX class loaders do not exist on iOS",
    "remove_class_loader": "DEX class loaders do not exist on iOS",
    "get_class_loaders": "DEX class loaders do not exist on iOS",
    "unload_class_loader": "DEX class loaders do not exist on iOS",
    "unload_classes": "DEX class loaders do not exist on iOS",
    "set_import_enabled": "the Java import hook cannot be reconfigured",
    "detach": "there is no JVM thread to detach",
}


def __getattr__(name):
    if name in _UNAVAILABLE:
        raise UnsupportedAPI(f"java.{name} is unavailable: {_UNAVAILABLE[name]}")
    raise AttributeError(f"module 'java' has no attribute {name!r}")


# Chaquopy implements these functions in the extension module ``java.chaquopy`` and re-exports
# them from ``java``; plugins import them from either name.
chaquopy = types.ModuleType(__name__ + ".chaquopy")
chaquopy.__getattr__ = __getattr__
for _name, _value in list(globals().items()):
    if not _name.startswith("_") and _name not in ("chaquopy", "annotations") and not isinstance(_value, types.ModuleType):
        setattr(chaquopy, _name, _value)
sys.modules[chaquopy.__name__] = chaquopy
