"""Which members each declared Java class provides, for static preflight.

Host classes: the table the host publishes in ``runtime.capabilities`` (``members``), plus the
members the SDK serves itself (``HOST_MEMBERS``). Python-local classes: read from the class
objects and the source of their provider modules. A member a provider defines only to raise
is not provided. Nothing here executes plugin code, and a question that cannot be answered
from these sources is answered ``None`` (unknown), never yes or no.
"""
from __future__ import annotations

import ast
import functools
import sys
import types
from pathlib import Path

import _ayu_javalib

VERSION = 1
MAX_CLASSES = 4096
MAX_NAMES = 2048
MAX_NAME_BYTES = 128
LISTS = ("methods", "fields", "writable_fields", "static_methods", "static_fields")
_KEYS = frozenset(LISTS + ("constructor", "results"))
_SDK_ROOT = Path(__file__).resolve().parent
_MAX_SOURCE_BYTES = 4 * 1024 * 1024
# Helpers whose call builds the error for an unimplemented member; a Java exception raised
# the same way is the member's documented behaviour instead.
_JAVA_THROWABLE_SUFFIXES = ("Exception", "Error")
_PYTHON_ERRORS = frozenset({"NotImplementedError"})


def validate(value, classes):
    """The host's member table by class name, or None when it publishes none this SDK reads.

    ``value`` is the ``members`` entry of ``runtime.capabilities``. A table of a newer version
    is ignored as a whole; a malformed one raises ``ValueError``.
    """
    if not isinstance(value, dict) or type(value.get("version")) is not int or value["version"] < 1:
        raise ValueError("Invalid member table")
    if value["version"] != VERSION:
        return None
    table = value.get("classes")
    if set(value) != {"version", "classes"} or not isinstance(table, dict) or len(table) > MAX_CLASSES:
        raise ValueError("Invalid member table")
    declared = set(classes)
    for name, entry in table.items():
        if name not in declared or not isinstance(entry, dict) or set(entry) != _KEYS:
            raise ValueError("Invalid class member declaration")
        if type(entry["constructor"]) is not bool:
            raise ValueError("Invalid class member declaration")
        for key in LISTS:
            names = entry[key]
            if not isinstance(names, list) or len(names) > MAX_NAMES or len(set(map(str, names))) != len(names):
                raise ValueError("Invalid class member list")
            for member in names:
                if (not isinstance(member, str) or not member.isascii() or not member.isidentifier()
                        or member.startswith("_") or len(member) > MAX_NAME_BYTES):
                    raise ValueError("Invalid class member name")
        if not set(entry["writable_fields"]) <= set(entry["fields"]):
            raise ValueError("Invalid class member declaration")
        results = entry["results"]
        members = set().union(*(entry[key] for key in LISTS))
        if not isinstance(results, dict) or not all(
                member in members and isinstance(result, str) and result in declared for member, result in results.items()):
            raise ValueError("Invalid class member result")
    return table


class _Unreadable(Exception):
    """A provider's source cannot be matched to its objects, so its members stay unknown."""


def _own_nodes(function):
    """Nodes of a function's body, without nested functions, lambdas and classes."""
    pending = list(function.body)
    while pending:
        node = pending.pop()
        yield node
        pending.extend(child for child in ast.iter_child_nodes(node)
                       if not isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda, ast.ClassDef)))


def _never_returns(function):
    """Whether every path through a function definition ends in ``raise``."""
    return (isinstance(function.body[-1], ast.Raise)
            and not any(isinstance(node, (ast.Return, ast.Yield, ast.YieldFrom)) for node in _own_nodes(function)))


def _is_stub(function):
    """A definition that only reports the member as unimplemented."""
    if not _never_returns(function):
        return False
    raised = function.body[-1].exc
    callee = raised.func if isinstance(raised, ast.Call) else raised
    name = callee.id if isinstance(callee, ast.Name) else callee.attr if isinstance(callee, ast.Attribute) else ""
    return name in _PYTHON_ERRORS or not name.endswith(_JAVA_THROWABLE_SUFFIXES)


@functools.lru_cache(maxsize=None)
def _source(filename):
    """Function definitions by first line and class definitions by qualified name, of one SDK file."""
    try:
        path = Path(filename).resolve()
        # Providers are read from the SDK and from where the class seam loads them.
        if not any(path.is_relative_to(root) for root in [_SDK_ROOT] + [Path(item).resolve() for item in _ayu_javalib.__path__]):
            return None
        with path.open("rb") as stream:
            data = stream.read(_MAX_SOURCE_BYTES + 1)
        if len(data) > _MAX_SOURCE_BYTES:
            raise _Unreadable(filename)
        tree = ast.parse(data.decode("utf-8"))
    except (OSError, ValueError, SyntaxError, RecursionError) as error:
        raise _Unreadable(filename) from error
    functions, classes = {}, {}
    pending = [(tree, "")]
    while pending:
        node, prefix = pending.pop()
        for child in ast.iter_child_nodes(node):
            inner = prefix
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)):
                # A code object starts at its first decorator.
                functions[min([child.lineno] + [item.lineno for item in child.decorator_list])] = child
                inner = prefix + child.name + ".<locals>."
            elif isinstance(child, ast.ClassDef):
                classes.setdefault(prefix + child.name, child)
                inner = prefix + child.name + "."
            pending.append((child, inner))
    return functions, classes


def _definition(function):
    """The ``def`` node of an SDK function; None for code that is not SDK source (builtins, stdlib)."""
    code = getattr(function, "__code__", None)
    if code is None:
        return None
    source = _source(code.co_filename)
    # A lambda is an expression: it cannot be a body that only raises.
    if source is None or code.co_name == "<lambda>":
        return None
    node = source[0].get(code.co_firstlineno)
    if node is None or node.name != code.co_name:
        raise _Unreadable(code.co_filename)
    return node


def _function(value):
    """The plain function behind a class attribute, or None."""
    for _ in range(8):
        if isinstance(value, (staticmethod, classmethod)):
            value = value.__func__
        elif isinstance(value, property):
            value = value.fget
        elif isinstance(value, functools.partial):
            value = value.func
        elif isinstance(value, types.FunctionType) and hasattr(value, "__wrapped__"):
            value = value.__wrapped__
        else:
            break
    return value if isinstance(value, types.FunctionType) else None


def _lookup(cls, name):
    """A class attribute as stored (no descriptor runs), as a 1-tuple; None when no base defines it."""
    for base in cls.__mro__:
        if name in vars(base):
            return (vars(base)[name],)
    return None


def _provided(value):
    """Whether a stored class attribute is an implementation."""
    function = _function(value)
    if function is None and not isinstance(value, (type, staticmethod, classmethod, property)):
        # A descriptor whose ``__get__`` only raises hides a name a Python base defines.
        function = _function(vars(type(value)).get("__get__"))
    definition = _definition(function) if function is not None else None
    return definition is None or not _is_stub(definition)


def _answers_other_names(cls):
    """Whether a ``__getattr__`` of the class can answer names its bases do not define."""
    for name in ("__getattr__", "__getattribute__"):
        found = _lookup(cls, name)
        function = _function(found[0]) if found is not None else None
        if function is not None:
            definition = _definition(function)
            if definition is None or not _never_returns(definition):
                return True
    return False


def _stored_fields(definition):
    """Instance fields the methods of one class definition assign, and whether more may exist."""
    names, more = set(), False

    def literal(node):
        return node.value if isinstance(node, ast.Constant) and isinstance(node.value, str) else None

    for method in definition.body:
        # ``__setattr__`` stores what a caller assigns, which is not a field of its own.
        if (not isinstance(method, (ast.FunctionDef, ast.AsyncFunctionDef)) or not method.args.args
                or method.name == "__setattr__"):
            continue
        receiver = method.args.args[0].arg
        # ``values = self.__dict__`` then ``values["field"] = ...``
        stores = {target.id for node in ast.walk(method) if isinstance(node, ast.Assign)
                  and isinstance(node.value, ast.Attribute) and node.value.attr == "__dict__"
                  for target in node.targets if isinstance(target, ast.Name)}

        def is_store(node):
            return (isinstance(node, ast.Attribute) and node.attr == "__dict__"
                    or isinstance(node, ast.Name) and node.id in stores)

        for node in ast.walk(method):
            if (isinstance(node, ast.Attribute) and isinstance(node.ctx, ast.Store)
                    and isinstance(node.value, ast.Name) and node.value.id == receiver):
                names.add(node.attr)
            elif isinstance(node, ast.Subscript) and isinstance(node.ctx, ast.Store) and is_store(node.value):
                key = literal(node.slice)
                names.add(key) if key is not None else None
                more = more or key is None
            elif isinstance(node, ast.Call):
                callee = node.func
                if isinstance(callee, ast.Attribute) and callee.attr == "update" and is_store(callee.value):
                    more = True
                elif (isinstance(callee, ast.Name) and callee.id == "setattr"
                      or isinstance(callee, ast.Attribute) and callee.attr == "__setattr__"):
                    key = literal(node.args[1]) if len(node.args) == 3 else None
                    names.add(key) if key is not None else None
                    more = more or key is None
    return names, more


def _returned_class(function, definition, owner):
    """The class whose instance every ``return`` of an SDK method yields, or None when not certain.

    ``return self`` yields the receiver's class ``owner``; ``return Name(...)`` yields the module's
    class of that name, directly or through a local variable assigned nothing else.
    """
    decorators = {item.id for item in definition.decorator_list if isinstance(item, ast.Name)}
    arguments = definition.args.posonlyargs + definition.args.args
    receiver = None if "staticmethod" in decorators or not arguments else arguments[0].arg
    # Every value a local name is bound to; None for a binding that is not a plain assignment.
    plain = {id(node.targets[0]): node.value for node in _own_nodes(definition)
             if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name)}
    assigned = {}
    for node in _own_nodes(definition):
        if isinstance(node, ast.Name) and isinstance(node.ctx, ast.Store):
            assigned.setdefault(node.id, []).append(plain.get(id(node)))

    def constructed(node, follow=True):
        if isinstance(node, ast.Name):
            if node.id == receiver and node.id not in assigned:
                return None if "classmethod" in decorators else owner
            if follow and node.id in assigned:
                found = {None if value is None else constructed(value, False) for value in assigned[node.id]}
                return found.pop() if len(found) == 1 else None
            return None
        if (isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id not in assigned
                and not any(item.arg == node.func.id for item in arguments[1 if receiver else 0:])):
            if node.func.id == receiver:
                return owner if "classmethod" in decorators else None
            target = function.__globals__.get(node.func.id)
            if isinstance(target, type) and _lookup(target, "__new__")[0] is object.__new__:
                return target
        return None

    found = {None if node.value is None else constructed(node.value)
             for node in _own_nodes(definition) if isinstance(node, ast.Return)}
    return found.pop() if len(found) == 1 else None


class _Local:
    """Members of one Python-local class."""

    def __init__(self, cls):
        self.cls = cls
        self.static, self.values = set(), {}
        # A metaclass attribute (a class-level property) reads as a static member too.
        for base in cls.__mro__ + type(cls).__mro__:
            for name in vars(base):
                if name.startswith("_") or name in self.values:
                    continue
                self.values[name] = vars(base)[name]
                if _provided(vars(base)[name]):
                    self.static.add(name)
        self.open_static = _answers_other_names(type(cls))
        fields, more = set(getattr(cls, "__slots__", ()) or ()), False
        generated, planned = _generated_fields(cls)
        for base in cls.__mro__:
            if base is planned:
                continue
            filename = getattr(sys.modules.get(vars(base).get("__module__")), "__file__", None)
            source = _source(filename) if isinstance(filename, str) else None
            definition = source[1].get(base.__qualname__) if source else None
            if definition is not None:
                names, extra = _stored_fields(definition)
                fields |= names
                more = more or extra
            elif isinstance(filename, str) and filename.endswith(".py") and source is None:
                # A base written in Python outside the SDK (the standard library): its fields are not read.
                more = True
        fields |= generated
        self.instance = self.static | {name for name in fields if isinstance(name, str) and not name.startswith("_")}
        self.open_instance = more or _answers_other_names(cls)
        constructor = (_lookup(cls, "__init__") or (None,))[0], (_lookup(cls, "__new__") or (None,))[0]
        self.constructor = all(_provided(item) for item in constructor if item is not None)
        setter = _lookup(cls, "__setattr__")
        self.restricts_writes = setter is not None and setter[0] is not object.__setattr__

    def result(self, name, static):
        """The class whose instance a call of the member returns, when its definition makes that certain."""
        value = self.values.get(name)
        if isinstance(value, property) or static and not isinstance(value, (staticmethod, classmethod)):
            return None
        function = _function(value)
        declared = getattr(function, "__ayu_returns__", None)
        if isinstance(declared, type):
            return declared
        definition = _definition(function) if function is not None else None
        return _returned_class(function, definition, self.cls) if definition is not None else None


def _generated_fields(cls):
    """Fields of a TL class and the base whose instances get them from the schema plan, not from assignments."""
    from _ayu_javalib import telegram_tl
    if not issubclass(cls, telegram_tl.TLObject):
        return set(), None
    return set(telegram_tl._plan(cls).names), telegram_tl.TLObject


_locals = {}


def local(cls):
    """The ``_Local`` table of a Python-local class, or None when its provider cannot be read."""
    if cls not in _locals:
        try:
            _locals[cls] = _Local(cls)
        except _Unreadable:
            _locals[cls] = None
    return _locals[cls]


class _Mirror:
    """The reference of the ``java.lang.Class`` object of a Python-local class: the mirror's own members, the class's model."""
    __slots__ = ("of",)

    def __init__(self, of):
        self.of = of

    def __eq__(self, other):
        return type(other) is _Mirror and other.of is self.of

    def __hash__(self):
        return hash(self.of)


class Tables:
    """Member questions about the classes one host's capabilities make usable.

    A class reference is a Java class name (a host class) or a Python class (a local one);
    ``named`` turns a declared Java name into one with the runtime's precedence. ``getClass()`` of
    a local class yields an instance of a third kind of reference, its ``Class`` mirror.
    """

    def __init__(self, capabilities):
        self.host_classes = frozenset(capabilities["classes"])
        self.local_classes = frozenset(capabilities.get("local_classes", ()))
        self.host_members = capabilities.get("members") or {}
        self.operations = frozenset(capabilities.get("operations", ()))
        self._capabilities = capabilities
        self._host = {}

    def named(self, name):
        """The reference of a declared class, or None."""
        if name in self.local_classes:
            return _ayu_javalib.local_class(name)
        return name if name in self.host_classes else None

    @staticmethod
    def _plain(reference):
        """A mirror answers member questions as the Python-local ``java.lang.Class`` it is an instance of."""
        return _ayu_javalib.local_class("java.lang.Class") if isinstance(reference, _Mirror) else reference

    @staticmethod
    def reflects(reference):
        """The class whose members a ``Class`` reference looks up: a mirror's class, else the class itself."""
        return reference.of if isinstance(reference, _Mirror) else reference

    @staticmethod
    def label(reference):
        """The Java name a blocker reports."""
        reference = Tables._plain(reference)
        return reference if isinstance(reference, str) else _ayu_javalib.local_name(reference) or reference.__qualname__

    def _host_entry(self, name):
        if name not in self._host:
            entry = self.host_members.get(name)
            self._host[name] = None if entry is None else {key: frozenset(entry[key]) for key in LISTS}
        return self._host[name]

    def _local_value(self, value):
        """What reading a stored class attribute of a local class yields: ('class' | 'instance', reference)."""
        if type(value).__name__ == "HostFirst" and isinstance(getattr(value, "name", None), str):
            reference = self.named(value.name)
            return ("class", reference) if reference is not None else None
        if isinstance(value, type):
            return ("class", value) if _ayu_javalib.local_name(value) is not None else None
        if callable(value) or isinstance(value, (staticmethod, classmethod, property)) or hasattr(type(value), "__get__"):
            return None
        name = _ayu_javalib.local_name(value)
        return ("instance", type(value)) if name is not None and type(value).__module__.startswith("_ayu_javalib.") else None

    def _unusable_nested(self, value):
        """Whether a stored attribute is a local class this host's operations do not make usable (``R.string``)."""
        if not isinstance(value, type):
            return False
        try:
            name = _ayu_javalib.local_name(value)
        except TypeError:
            return False
        return (name is not None and _ayu_javalib.local_class(name) is value
                and name not in self.local_classes and name not in self.host_classes)

    def _host_result(self, reference, member):
        """The host class a member's value or call result is declared to be an instance of."""
        result = (self.host_members.get(reference) or {}).get("results", {}).get(member)
        # The object is the host's own, whatever local class shares its name.
        return ("instance", result) if result in self.host_classes else None

    def _served_result(self, function, receiver):
        """What a function the SDK serves on a host class certainly returns, as ('instance', reference) or None.

        ``receiver`` is the host class of the object a receiver-taking function may return.
        """
        returned = getattr(function, "__ayu_returns__", None)
        try:
            definition = _definition(function) if returned is None else None
            returned = _returned_class(function, definition, receiver) if definition is not None else returned
        except _Unreadable:
            return None
        if isinstance(returned, str):
            return ("instance", returned) if returned in self.host_classes else None
        return ("instance", returned) if returned is not None and _ayu_javalib.local_name(returned) is not None else None

    def _served(self, reference, member, static):
        """``(provided value, call result)`` of a member the SDK serves on a host class, or None."""
        found = _ayu_javalib.served_member(self._capabilities, reference, member, static)
        if found is None:
            return None
        kind, value = found
        if kind == "class":
            return ("class", value), None
        if kind == "getClass":
            # The host's Class object answers what the class itself answers.
            return None, ("class", reference)
        if isinstance(value, _ayu_javalib.HostField):
            return self._served_result(value.getter, None), None
        if isinstance(value, types.FunctionType):
            return None, self._served_result(value, reference if getattr(value, "__ayu_receiver__", False) else None)
        return None, None

    def gate(self, label, member, use):
        """The undeclared operation behind a member only the gated local class of a host name provides.

        A local class that overrides a host adapter is unusable while the host lacks one of its
        operations; the adapter then answers, and a member it lacks is not missing but gated.
        """
        cls = _ayu_javalib.local_class(label)
        if (cls is None or label not in self.host_classes or label in self.local_classes
                or not _ayu_javalib.overrides_host(cls)):
            return None
        needed = _ayu_javalib.missing_operations(label, self.operations)
        table = local(cls) if needed else None
        if table is None:
            return None
        if use == "construct":
            provided = table.constructor
        elif use == "write":
            provided = not table.restricts_writes or member in table.instance
        else:
            provided = member in table.instance
        return needed[0] if provided else None

    def access(self, reference, member, static, store=False):
        """``(provided, value)`` for ``reference.member``: True, False or None, and what the read yields."""
        reference = self._plain(reference)
        if isinstance(reference, str):
            served = self._served(reference, member, static)
            if served is not None:
                return (not store), served[0]
            nested = reference + "$" + member
            if static and not store and nested in self.host_classes:
                # The host answers a nested class itself; the runtime then applies its precedence.
                return True, ("class", self.named(nested))
            entry = self._host_entry(reference)
            if entry is None:
                return None, None
            if store:
                return (not static and member in entry["writable_fields"]), None
            if static:
                if member in entry["static_fields"]:
                    return True, self._host_result(reference, member)
                return member in entry["static_methods"], None
            if member in entry["fields"]:
                return True, self._host_result(reference, member)
            return member in entry["methods"], None
        table = local(reference)
        if table is None:
            return None, None
        if store:
            if static or not table.restricts_writes or member in table.instance:
                return True, None
            return (None if table.open_instance else False), None
        names, more = (table.static, table.open_static) if static else (table.instance, table.open_instance)
        if member in names:
            if member in table.values and self._unusable_nested(table.values[member]):
                return False, None
            return True, self._local_value(table.values[member]) if member in table.values else None
        return (None if more else False), None

    def call(self, reference, member, static):
        """('instance', reference) for what ``reference.member(...)`` returns, or None when not certain."""
        reference = self._plain(reference)
        if isinstance(reference, str):
            served = self._served(reference, member, static)
            if served is not None:
                return served[1]
            entry = self._host_entry(reference)
            if entry is None or member not in entry["static_methods" if static else "methods"]:
                return None
            # An object's Class object answers what its class answers.
            return self._host_result(reference, member) or (("class", reference) if member == "getClass" else None)
        table = local(reference)
        if table is None or member not in (table.static if static else table.instance):
            return None
        if member == "getClass" and type(table.values.get(member)).__name__ == "_GetClass":
            return ("instance", _Mirror(reference))
        try:
            returned = table.result(member, static)
        except _Unreadable:
            return None
        return ("instance", returned) if returned is not None else None

    def reflected(self, reference, lookup, name):
        """Whether ``Class.<lookup>(name)`` of a class finds the member: True, False, or None when not certain.

        ``lookup`` is one of ``getDeclaredField``, ``getField``, ``getDeclaredMethod``, ``getMethod``. The
        answer comes from the model ``java_reflect`` serves the lookup from; a lookup the host answers
        itself and a class without a model are not certain.
        """
        from _ayu_javalib import java_reflect
        if isinstance(reference, str):
            served = _ayu_javalib.served_member(self._capabilities, reference, lookup, True)
            if served is None or served[0] != "reflect":
                return None
        elif not isinstance(reference, _Mirror):
            return None
        return java_reflect.has_member(self.reflects(reference), 0 if lookup.endswith("Field") else 1, name, self._capabilities)

    def construct(self, reference, arguments=None):
        """Whether ``reference(...)`` can construct: True, False or None.

        ``arguments`` are the call's positional arguments where the source spells them as literals
        (``...`` for any other expression), or None when they are not known. A local class whose
        constructor refuses some values says so in ``__ayu_constructs__(arguments)``.
        """
        reference = self._plain(reference)
        if isinstance(reference, str):
            entry = self.host_members.get(reference)
            return None if entry is None else entry["constructor"]
        table = local(reference)
        if table is None:
            return None
        accepts = vars(reference).get("__ayu_constructs__")
        if table.constructor and arguments is not None and isinstance(accepts, staticmethod):
            return bool(accepts.__func__(arguments))
        return table.constructor
