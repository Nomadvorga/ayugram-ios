"""Reflection requests are limited to adapters explicitly implemented by host."""
from ayu_bridge import JavaClass, RemoteObject, WireTarget, runtime
from base_plugin import MethodHook
from java import jclass


def find_class(class_name):
    return jclass(class_name)


def get_private_field(obj, field_name):
    return runtime.call("java.get_private_field", {"target": obj, "name": field_name})


def set_private_field(obj, field_name, new_value):
    runtime.call("java.set_private_field", {"target": obj, "name": field_name, "value": new_value})
    return True


def set_field(obj, field_name, new_value):
    """Set a field only when the host explicitly exposes it as writable.

    This matches the common ``hook_utils.set_field`` call shape without
    emulating Java reflection: the bridge validates the object owner and the
    native adapter's writable-field declaration.
    """
    return set_private_field(obj, field_name, new_value)


def get_static_private_field(clazz, field_name):
    """Only an explicitly adapted static field, not arbitrary private reflection."""
    if not isinstance(clazz, JavaClass):
        raise TypeError("Expected a declared Java class")
    runtime.require(clazz._scope)
    return runtime.call("java.get_private_field", {"target": WireTarget(clazz._target()), "name": field_name})


def set_static_private_field(clazz, field_name, new_value):
    if not isinstance(clazz, JavaClass):
        raise TypeError("Expected a declared Java class")
    runtime.require(clazz._scope)
    runtime.call("java.set_private_field", {"target": WireTarget(clazz._target()),
                                           "name": field_name, "value": new_value})
    return True


def java_class(clazz):
    """Resolve declared class facades; arbitrary Class.forName is unavailable."""
    if isinstance(clazz, str):
        return jclass(clazz)
    if isinstance(clazz, JavaClass):
        runtime.require(clazz._scope)
        return clazz
    from ayu_bridge import RemoteObject, UnsupportedAPI
    if isinstance(clazz, RemoteObject) and clazz._class_name == "java.lang.Class":
        runtime.require(clazz._scope)
        return clazz
    raise UnsupportedAPI("Class reflection requires a declared native class adapter")


def get_method(clazz, method_name, *param_types):
    owner = java_class(clazz)
    return owner.getDeclaredMethod(method_name, *(java_class(param) for param in param_types))


def get_constructor(clazz, *param_types):
    owner = java_class(clazz)
    return owner.getDeclaredConstructor(*(java_class(param) for param in param_types))


def get_field(clazz, field_name):
    """Read an explicitly adapted field or obtain a declared field descriptor."""
    if isinstance(clazz, RemoteObject):
        runtime.require(clazz._scope)
        return runtime.call("java.get_private_field", {"target": clazz, "name": field_name})
    return java_class(clazz).getDeclaredField(field_name)
