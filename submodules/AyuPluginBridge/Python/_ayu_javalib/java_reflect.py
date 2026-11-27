"""``java.lang.reflect`` over the classes this bridge models.

There is no JVM to reflect on. A ``Field`` or ``Method`` exists for a member the class is known
to have and reads, writes or calls it the way plugin code would by name:

- a Python-local class has the public attributes its provider defines (a definition that only
  raises is not a member) and the instance fields its methods assign;
- a host class has what the host's member table lists for it, plus what the SDK serves on it
  (``HOST_MEMBERS``); a class the host publishes no table for cannot be reflected on.

A member outside that model throws ``NoSuchFieldException``/``NoSuchMethodException`` with
Android's message. Deliberate differences: every modelled member is public and accessible
(``setAccessible`` only records the flag), parameter types select nothing beyond their count,
field and parameter types are not known, and an inherited instance field is found on the class
that inherits it as well as on the one that declares it.
"""
from __future__ import annotations

import inspect

from . import java_lang as _l

LOOKUPS, REFLECTION = _l.REFLECTION_LOOKUPS, _l.REFLECTION
# What the host answers on every class object besides the class's own static methods.
_HOST_CLASS_METHODS = frozenset({"forName", "getName", "getSimpleName", "getPackageName", "isPrimitive", "isArray",
                                 "isInterface", "isEnum", "getComponentType", "getDeclaredMethod", "getDeclaredMethods"})

InvocationTargetException = _l._throwable("InvocationTargetException", _l.ReflectiveOperationException)
InvocationTargetException.getTargetException = lambda self: self.getCause()


def _runtime():
    from ayu_bridge import runtime
    return runtime


def _members():
    import _ayu_members
    return _ayu_members


def _local_model(cls, declared):
    """``(fields, methods)`` of a Python-local class as ``{name: is static}``; ``declared`` leaves out inherited statics."""
    members = _members()
    table = members.local(cls)
    if table is None:
        raise _l.unsupported("The members of " + _l.java_name(cls) + " cannot be read")
    fields, methods = {}, {}
    for name in table.static:
        value = table.values[name]
        # ``to_bridge`` is the seam's wire hook, not a member of the Java class.
        if declared and name not in vars(cls) or name == "to_bridge":
            continue
        if isinstance(value, (staticmethod, classmethod)):
            methods[name] = True
        elif members._function(value) is not None and not isinstance(value, property):
            methods[name] = False
        elif isinstance(value, property):
            fields[name] = False
        elif not isinstance(value, type) and not hasattr(type(value), "__get__"):
            fields[name] = True
    for name in table.instance - table.static:
        fields[name] = False
    return fields, methods


def _host_model(name, capabilities):
    """``(fields, methods)`` of a host class: the host's table and what the SDK serves on the class."""
    import _ayu_javalib
    capabilities = _runtime().capabilities if capabilities is None else capabilities
    entry = (capabilities.get("members") or {}).get(name)
    if entry is None:
        raise _l.unsupported("The host publishes no members of " + name + " to reflect on")
    fields = dict.fromkeys(entry["fields"], False)
    fields.update(dict.fromkeys(entry["static_fields"], True))
    methods = dict.fromkeys(set(entry["methods"]) - {"getClass"}, False)
    methods.update(dict.fromkeys(set(entry["static_methods"]) - _HOST_CLASS_METHODS, True))
    for member, value in (_ayu_javalib._loaded()[2].get(name) or {}).items():
        # A served ``Class`` lookup answers for the class object; it is not a member of the class.
        if member in fields or member in methods or member in REFLECTION:
            continue
        if isinstance(value, _ayu_javalib.HostField):
            fields[member] = None  # read on the class or on an object, whichever the caller has
        elif callable(value):
            methods[member] = None
        else:
            fields[member] = True
    return fields, methods


def model(owner, declared=False, capabilities=None):
    """``(fields, methods)`` of a Python-local class or a host class name (of the current host, or of ``capabilities``)."""
    return _host_model(owner, capabilities) if isinstance(owner, str) else _local_model(owner, declared)


def has_member(owner, kind, name, capabilities=None):
    """Whether a class has the field (``kind`` 0) or method (1) ``name``, for static preflight.

    None when the class has no model, or when the model lacks the name but the class may hold
    members its source does not spell out (fields stored under computed names, ``__getattr__``).
    """
    from ayu_bridge import UnsupportedAPI
    try:
        found = name in model(owner, False, capabilities)[kind]
    except UnsupportedAPI:
        return None
    if not found and isinstance(owner, type) and _members().local(owner).open_instance:
        return None
    return found


def _owner_name(owner):
    return owner if isinstance(owner, str) else _l.java_name(owner)


def _class_of(owner):
    """The ``Class`` object of a model's owner: the local mirror, or the host's own object."""
    if isinstance(owner, str):
        return _runtime().jclass("java.lang.Class").forName(owner)
    return _l.Class._of(owner)


def _type_text(value):
    if isinstance(value, _l.Class):
        return value.toString()
    name = getattr(value, "_class_name", None) or getattr(value, "_name", None)
    return "class " + name if isinstance(name, str) else type(value).__name__


class AccessibleObject(_l.Object):
    """Base of ``Field`` and ``Method``: an owner (Python class or host class name), a name and staticness."""

    def __init__(self, *args):
        raise _l.unsupported(_l.java_name(self) + " objects come from java.lang.Class")

    @classmethod
    def _of(cls, owner, name, static):
        member = object.__new__(cls)
        member._owner, member._name, member._static, member._accessible = owner, name, static, False
        return member

    def _receiver(self, target):
        """What the member is read on: the class for a static member, else the checked object."""
        owner = self._owner
        if self._static or self._static is None and target is None:
            return _runtime().jclass(owner) if isinstance(owner, str) else owner
        if target is None:
            raise _l.NullPointerException("null receiver")
        if not (isinstance(target, owner) if isinstance(owner, type) else type(target).__name__ == "RemoteObject"):
            raise _l.IllegalArgumentException("object is not an instance of declaring class")
        return target

    def setAccessible(self, flag):
        self._accessible = bool(flag)

    def isAccessible(self):
        return self._accessible

    def getName(self):
        return self._name

    def getDeclaringClass(self):
        return _class_of(self._owner)

    def getModifiers(self):
        return _l.Modifier.PUBLIC | (_l.Modifier.STATIC if self._static else 0)

    def __eq__(self, other):
        return type(other) is type(self) and (other._owner, other._name) == (self._owner, self._name)

    def __hash__(self):
        return hash((_owner_name(self._owner), self._name))

    def hashCode(self):
        return _l.string_hash(_owner_name(self._owner)) ^ _l.string_hash(self._name)

    def toString(self):
        return "public " + ("static " if self._static else "") + _owner_name(self._owner) + "." + self._name


class Field(AccessibleObject):
    def get(self, target):
        return getattr(self._receiver(target), self._name)

    def set(self, target, value):
        setattr(self._receiver(target), self._name, value)

    def _typed(self, target, accepted, what):
        value = self.get(target)
        if type(value) not in accepted:
            raise _l.IllegalArgumentException(f"Attempt to get {type(value).__name__} field \""
                                              f"{_owner_name(self._owner)}.{self._name}\" with illegal data type conversion to {what}")
        return value

    def getBoolean(self, target):
        return self._typed(target, (bool,), "boolean")

    def getInt(self, target):
        return self._typed(target, (int,), "int")

    def getLong(self, target):
        return self._typed(target, (int,), "long")

    def getFloat(self, target):
        return float(self._typed(target, (int, float), "float"))

    def getDouble(self, target):
        return float(self._typed(target, (int, float), "double"))

    setBoolean = setInt = setLong = setFloat = setDouble = set


class Method(AccessibleObject):
    def invoke(self, target, *arguments):
        function = getattr(self._receiver(target), self._name)
        try:
            return function(*arguments)
        except _l.Throwable as error:
            # Java reports what the method itself throws wrapped; a bridge refusal is not the method's.
            raise InvocationTargetException(error) from error

    def _signature(self):
        """``(parameter type names, return type name)`` a local function declares as ``__ayu_java_signature__``, or None."""
        function = getattr(self._owner, self._name, None) if isinstance(self._owner, type) else None
        return getattr(function, "__ayu_java_signature__", None)

    def getParameterCount(self):
        declared = self._signature()
        if declared is not None:
            return len(declared[0])
        if isinstance(self._owner, type):
            try:
                parameters = list(inspect.signature(getattr(self._owner, self._name)).parameters.values())
            except (TypeError, ValueError):
                parameters = None
            # One Python definition with optional or variable arguments stands for several Java overloads.
            if parameters is not None and all(item.kind in (item.POSITIONAL_ONLY, item.POSITIONAL_OR_KEYWORD)
                                              and item.default is item.empty for item in parameters):
                return len(parameters) - (0 if self._static else 1)
        raise _l.unsupported(f"The parameters of {_owner_name(self._owner)}.{self._name} are not known")

    @staticmethod
    def _type(name):
        return _l.Class._of(name) if name in _l._PRIMITIVES else _l.Class.forName(name)

    def getParameterTypes(self):
        declared = self._signature()
        if declared is None:
            raise _l.unsupported(f"The parameter types of {_owner_name(self._owner)}.{self._name} are not known")
        return [self._type(name) for name in declared[0]]

    def getReturnType(self):
        declared = self._signature()
        if declared is None:
            raise _l.unsupported(f"The return type of {_owner_name(self._owner)}.{self._name} is not known")
        return self._type(declared[1])

    def toString(self):
        return super().toString() + "()"


def _accepts(cls, name, static, count):
    """Whether a local method can be called with ``count`` arguments (what its parameter types can select)."""
    try:
        signature = inspect.signature(getattr(cls, name))
        signature.bind(*([None] * (count + (0 if static else 1))))
    except TypeError:
        return False
    except ValueError:
        return True
    return True


def reflect(owner, member, arguments):
    """``Class.<member>(*arguments)`` for a Python-local class or a host class name."""
    declared = "Declared" in member
    fields, methods = model(owner, declared)
    if member in ("getDeclaredFields", "getFields", "getDeclaredMethods", "getMethods"):
        if arguments:
            raise TypeError(f"Class.{member} takes no arguments")
        found, kind = (fields, Field) if member.endswith("Fields") else (methods, Method)
        return [kind._of(owner, name, found[name]) for name in sorted(found)]
    if not arguments or not isinstance(arguments[0], str):
        raise _l.NullPointerException("name == null")
    name = arguments[0]
    if member.endswith("Field"):
        if len(arguments) != 1:
            raise TypeError(f"Class.{member} takes the field name")
        if name not in fields:
            raise _l.NoSuchFieldException(name)
        return Field._of(owner, name, fields[name])
    types = arguments[1:]
    if len(types) == 1 and isinstance(types[0], (list, tuple)):
        types = tuple(types[0])
    if name not in methods or isinstance(owner, type) and not _accepts(owner, name, methods[name], len(types)):
        raise _l.NoSuchMethodException(f"{_owner_name(owner)}.{name} [{', '.join(map(_type_text, types))}]")
    return Method._of(owner, name, methods[name])


CLASSES = _l.register({
    "java.lang.reflect.AccessibleObject": AccessibleObject,
    "java.lang.reflect.Field": Field,
    "java.lang.reflect.Method": Method,
    "java.lang.reflect.InvocationTargetException": InvocationTargetException,
})
