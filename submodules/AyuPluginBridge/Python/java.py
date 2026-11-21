"""Registry-backed Java syntax facade; there is no JVM or symbol lookup."""
from __future__ import annotations

import math

from ayu_bridge import DynamicProxy, JavaClass, UnsupportedAPI, runtime

# Allow java.lang etc. to be resolved by the registry-backed native importer.
__path__ = []


def jclass(name):
    return runtime.jclass(name)


def dynamic_proxy(*interfaces):
    scope = runtime.require()
    if not interfaces:
        raise TypeError("At least one declared interface is required")
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


def jarray(component):
    scope = runtime.require()
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
    if not isinstance(clazz, JavaClass):
        raise TypeError("cast requires a declared Java class")
    runtime.require(clazz._scope)
    return runtime.call("java.cast", {"class_name": clazz._name, "value": value})
