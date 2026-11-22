"""Reflection requests are limited to adapters explicitly implemented by host."""
from ayu_bridge import JavaClass, WireTarget, runtime
from java import jclass


def find_class(name):
    return jclass(name)


def get_private_field(target, name):
    return runtime.call("java.get_private_field", {"target": target, "name": name})


def set_private_field(target, name, value):
    return runtime.call("java.set_private_field", {"target": target, "name": name, "value": value})


def get_static_private_field(clazz, name):
    """Only an explicitly adapted static field, not arbitrary private reflection."""
    if not isinstance(clazz, JavaClass):
        raise TypeError("Expected a declared Java class")
    runtime.require(clazz._scope)
    return runtime.call("java.get_private_field", {"target": WireTarget(clazz._target()), "name": name})
