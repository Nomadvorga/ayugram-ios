"""Reflection requests are limited to adapters explicitly implemented by host.

Python-local Java objects have no JVM fields to reflect on. A TL object exposes exactly the
fields of its Java class; a local class exposes its declared constants; everything else is
refused rather than read from Python internals.
"""
import _ayu_javalib
from ayu_bridge import JavaClass, RemoteObject, UnsupportedAPI, WireTarget, runtime
from base_plugin import MethodHook
from java import jclass


def _local_fields(obj):
    """Field names of a Python-local Java object that reflection may touch, or None for a host object."""
    if isinstance(obj, (RemoteObject, JavaClass)) or _ayu_javalib.local_name(obj) is None:
        return None
    from _ayu_javalib import telegram_tl
    if isinstance(obj, telegram_tl.TLObject):
        return telegram_tl._plan(type(obj)).names
    return frozenset()


def _local_field(obj, field_name, fields):
    if not isinstance(field_name, str) or field_name not in fields:
        raise UnsupportedAPI(f"{_ayu_javalib.local_name(obj)} does not expose field {field_name}")
    return field_name


def find_class(class_name):
    return jclass(class_name)


def get_private_field(obj, field_name):
    runtime.require()
    fields = _local_fields(obj)
    if fields is not None:
        return getattr(obj, _local_field(obj, field_name, fields))
    return runtime.call("java.get_private_field", {"target": obj, "name": field_name})


def set_private_field(obj, field_name, new_value):
    runtime.require()
    fields = _local_fields(obj)
    if fields is not None:
        setattr(obj, _local_field(obj, field_name, fields), new_value)
        return True
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
    if isinstance(clazz, type) and _ayu_javalib.local_name(clazz) is not None:
        runtime.require()
        value = None if not isinstance(field_name, str) or field_name.startswith("_") else vars(clazz).get(field_name)
        if type(value) not in (bool, int, float, str):
            raise UnsupportedAPI(f"{_ayu_javalib.local_name(clazz)} does not expose static field {field_name}")
        return value
    if not isinstance(clazz, JavaClass):
        raise TypeError("Expected a declared Java class")
    runtime.require(clazz._scope)
    return runtime.call("java.get_private_field", {"target": WireTarget(clazz._target()), "name": field_name})


def set_static_private_field(clazz, field_name, new_value):
    if isinstance(clazz, type) and _ayu_javalib.local_name(clazz) is not None:
        runtime.require()
        raise UnsupportedAPI(f"Static fields of {_ayu_javalib.local_name(clazz)} cannot be changed")
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
    if isinstance(clazz, type) and _ayu_javalib.local_name(clazz) is not None:
        runtime.require()
        return clazz
    if isinstance(clazz, RemoteObject) and clazz._class_name == "java.lang.Class":
        runtime.require(clazz._scope)
        return clazz
    raise UnsupportedAPI("Class reflection requires a declared native class adapter")


def _reflective(clazz, what):
    """A host class facade; a Python-local class has no Method, Constructor or Field objects."""
    owner = java_class(clazz)
    if isinstance(owner, type):
        raise UnsupportedAPI(f"{what} of the Python-local class {_ayu_javalib.local_name(owner)} cannot be reflected")
    return owner


def get_method(clazz, method_name, *param_types):
    owner = _reflective(clazz, "Methods")
    return owner.getDeclaredMethod(method_name, *(java_class(param) for param in param_types))


def get_constructor(clazz, *param_types):
    owner = _reflective(clazz, "Constructors")
    return owner.getDeclaredConstructor(*(java_class(param) for param in param_types))


def get_field(clazz, field_name):
    """Read an explicitly adapted field or obtain a declared field descriptor."""
    if isinstance(clazz, RemoteObject):
        runtime.require(clazz._scope)
        return runtime.call("java.get_private_field", {"target": clazz, "name": field_name})
    if _local_fields(clazz) is not None:
        return get_private_field(clazz, field_name)
    return _reflective(clazz, "Fields").getDeclaredField(field_name)
