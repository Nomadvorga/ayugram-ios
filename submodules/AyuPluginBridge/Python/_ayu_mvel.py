"""Android's menu-item condition strings (``MenuItemData(condition="message != null && ...")``).

exteraGram compiles the string with MVEL and evaluates it over the menu's context map
(``MenuItemRecord.checkCondition``): an empty condition shows the item, a string that does not
compile or an evaluation that throws hides it, and so does a name the map lacks. This module
evaluates the part of MVEL such conditions are written in, over the SDK's context map:

    ``null``/``nil``, ``true``, ``false``, integers, decimals, quoted strings; names of the map;
    ``a.b`` (field, getter ``getB``/``isB``, or a method ``b`` without arguments); ``a.m(...)``;
    a static member of a fully qualified class (``org.telegram.messenger.ChatObject.isChannel(chat)``);
    ``!``, ``&&``, ``||``, ``==``, ``!=``, ``<``, ``<=``, ``>``, ``>=``, a minus before a number
    and parentheses.

Anything else is refused when the item is added (``Unsupported``), never guessed. What Android
would evaluate but the SDK's models cannot answer (a member that raises ``UnsupportedAPI`` or is
not modelled) is *unknown*: ``&&`` and ``||`` then still answer when the other operand decides
the result, and an unknown result hides the item.
"""
from __future__ import annotations

import ast
import re

MAX_LENGTH = 4096
MAX_NODES = 512
MAX_DEPTH = 32

# The keys of ``_ayu_hooks._menu_context`` whose class is certain, for static checks.
CONTEXT_CLASSES = {
    "message": "org.telegram.messenger.MessageObject", "user": "org.telegram.tgnet.TLRPC$User",
    "chat": "org.telegram.tgnet.TLRPC$Chat", "userFull": "org.telegram.tgnet.TLRPC$UserFull",
    "chatFull": "org.telegram.tgnet.TLRPC$ChatFull", "encryptedChat": "org.telegram.tgnet.TLRPC$EncryptedChat",
}
CONTEXT_NAMES = frozenset(CONTEXT_CLASSES) | {"account", "dialog_id", "userId", "chatId", "fragment", "context"}

# MVEL words this subset does not implement; as names they would mean something else there.
_RESERVED = frozenset("""and or contains instanceof is in new if else for foreach while until do return def function empty
    with isdef var this soundslike strsim convertable_to assert import switch""".split())
_TOKEN = re.compile(r"""\s*(?:(?P<number>\d+(?:\.\d+)?[LlFfDd]?)(?![\w$.])|(?P<name>[A-Za-z_$][\w$]*)
    |(?P<string>'(?:[^'\\\n]|\\.)*'|"(?:[^"\\\n]|\\.)*")|(?P<operator>&&|\|\||==|!=|<=|>=|[<>!().,-]))""", re.X | re.A)
_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", "'": "'", '"': '"'}
_STRING_METHODS = {
    "length": lambda text: len(text.encode("utf-16-le", "surrogatepass")) // 2,
    "isEmpty": lambda text: not text, "toString": lambda text: text, "trim": lambda text: text.strip(" \t\n\r\x0b\x0c"),
    "equals": lambda text, other: isinstance(other, str) and text == other,
    "equalsIgnoreCase": lambda text, other: isinstance(other, str) and text.lower() == other.lower(),
    "contains": lambda text, other: _string(other) in text, "startsWith": lambda text, other: text.startswith(_string(other)),
    "endsWith": lambda text, other: text.endswith(_string(other)),
    "toLowerCase": lambda text: text.lower(), "toUpperCase": lambda text: text.upper(),
}


class Unsupported(ValueError):
    """The condition is outside the implemented subset (or is not MVEL at all)."""


class _Failed(Exception):
    """Android's evaluation throws here: the item is hidden."""


class _Unknown(Exception):
    """Android has an answer the SDK's models cannot give."""


def _string(value):
    if not isinstance(value, str):
        raise _Failed()
    return value


# --- Parsing -------------------------------------------------------------------

def _tokens(text):
    position, found = 0, []
    while text[position:].strip():
        match = _TOKEN.match(text, position)
        if match is None:
            raise Unsupported("unexpected text at offset %d" % (len(text) - len(text[position:].lstrip())))
        found.append((match.lastgroup, match.group(match.lastgroup)))
        position = match.end()
    return found


class _Parser:
    def __init__(self, text):
        self.items, self.index, self.nodes = _tokens(text), 0, 0

    def peek(self, *operators):
        if self.index < len(self.items):
            kind, value = self.items[self.index]
            if kind == "operator" and value in operators:
                return value
        return None

    def take(self, *operators):
        value = self.peek(*operators)
        if value is not None:
            self.index += 1
        return value

    def expect(self, operator):
        if self.take(operator) is None:
            raise Unsupported("expected " + operator)

    def node(self, *parts):
        self.nodes += 1
        if self.nodes > MAX_NODES:
            raise Unsupported("the condition is too large")
        return parts

    def binary(self, operand, kind, *operators):
        def parse(depth):
            left = operand(depth)
            while True:
                operator = self.take(*operators)
                if operator is None:
                    return left
                left = self.node(kind, operator, left, operand(depth))
        return parse

    def expression(self, depth=0):
        if depth > MAX_DEPTH:
            raise Unsupported("the condition is nested too deeply")
        relation = self.binary(self.unary, "compare", "<=", ">=", "<", ">")
        equality = self.binary(relation, "equal", "==", "!=")
        conjunction = self.binary(equality, "and", "&&")
        return self.binary(conjunction, "or", "||")(depth + 1)

    def unary(self, depth):
        if depth > MAX_DEPTH:
            raise Unsupported("the condition is nested too deeply")
        if self.take("!"):
            return self.node("not", self.unary(depth + 1))
        if self.take("-"):
            if self.index >= len(self.items) or self.items[self.index][0] != "number":
                raise Unsupported("arithmetic")
            return self.node("value", -self.primary(depth)[1])
        return self.primary(depth)

    def primary(self, depth):
        if self.index >= len(self.items):
            raise Unsupported("the condition ends early")
        kind, value = self.items[self.index]
        self.index += 1
        if kind == "number":
            digits = value.rstrip("LlFfDd")
            node = self.node("value", float(digits) if "." in digits or value[-1] in "FfDd" else int(digits))
        elif kind == "string":
            body = re.sub(r"\\(.)", self.escape, value[1:-1])
            node = self.node("value", body)
        elif kind == "name":
            if value in ("null", "nil"):
                node = self.node("value", None)
            elif value in ("true", "false"):
                node = self.node("value", value == "true")
            elif value in _RESERVED:
                raise Unsupported("MVEL keyword " + value)
            elif self.peek("("):
                raise Unsupported("function call " + value + "()")
            else:
                return self.chain(("name", value), depth)
        elif value == "(":
            node = self.expression(depth + 1)
            self.expect(")")
        else:
            raise Unsupported("unexpected " + value)
        return self.chain(("of", node), depth) if self.peek(".") else node

    @staticmethod
    def escape(match):
        if match.group(1) not in _ESCAPES:
            raise Unsupported("string escape \\" + match.group(1))
        return _ESCAPES[match.group(1)]

    def chain(self, root, depth):
        """``root.a.b(c).d``: one node, so that a qualified class name stays in one piece."""
        steps = []
        while self.take("."):
            if self.index >= len(self.items) or self.items[self.index][0] != "name":
                raise Unsupported("member access")
            name = self.items[self.index][1]
            self.index += 1
            if self.take("("):
                arguments = []
                if not self.take(")"):
                    while True:
                        arguments.append(self.expression(depth + 1))
                        if self.take(")"):
                            break
                        self.expect(",")
                steps.append((name, tuple(arguments)))
            else:
                steps.append((name, None))
        return self.node("chain", root, tuple(steps))


def compile(text):
    """The parsed condition, or None for the empty one (which always holds). Raises ``Unsupported``."""
    if not isinstance(text, str):
        raise TypeError("A condition is a string")
    if len(text) > MAX_LENGTH:
        raise Unsupported("the condition is too long")
    if not text:
        return None
    parser = _Parser(text)
    if not parser.items:
        raise Unsupported("the condition is blank")
    tree = parser.expression()
    if parser.index != len(parser.items):
        raise Unsupported("unexpected " + parser.items[parser.index][1])
    return tree


def _class_split(root, steps):
    """``(class name, remaining steps)`` when ``root.steps`` starts with a qualified class name."""
    if root[0] != "name" or not root[1][:1].islower():
        return None
    for index, (name, arguments) in enumerate(steps):
        if arguments is not None:
            return None
        if name[:1].isupper():
            return ".".join((root[1],) + tuple(step[0] for step in steps[:index + 1])), steps[index + 1:]
    return None


# --- Evaluation ----------------------------------------------------------------

def _modelled(action):
    """Runs a read of the SDK's models: a refusal of theirs is unknown, any other error is Android's."""
    from ayu_bridge import BridgeError, UnsupportedAPI
    try:
        return action()
    except (_Failed, _Unknown):
        raise
    except (UnsupportedAPI, AttributeError, NotImplementedError):
        raise _Unknown() from None
    except BridgeError:
        raise
    except Exception:
        raise _Failed() from None


def _property(target, name):
    if target is None:
        raise _Failed()
    if isinstance(target, dict):
        if name not in target:
            raise _Failed()
        return target[name]
    if isinstance(target, (str, int, float)):
        raise _Unknown()

    def read():
        try:
            value = getattr(target, name)
        except AttributeError:
            for getter in ("get" + name[:1].upper() + name[1:], "is" + name[:1].upper() + name[1:]):
                method = getattr(target, getter, None)
                if callable(method):
                    return method()
            raise
        # MVEL reads ``a.b`` through a method ``b()`` as well.
        return value() if callable(value) and not isinstance(value, type) else value
    return _modelled(read)


def _call(target, name, arguments):
    if target is None:
        raise _Failed()
    if isinstance(target, str):
        method = _STRING_METHODS.get(name)
        if method is None:
            raise _Unknown()
        if len(arguments) != method.__code__.co_argcount - 1:
            raise _Failed()
        return method(target, *arguments)
    if isinstance(target, (bool, int, float, dict)):
        raise _Unknown()
    return _modelled(lambda: getattr(target, name)(*arguments))


def _truth(value):
    if type(value) is not bool:
        raise _Failed()
    return value


def _number(value):
    return type(value) in (int, float)


def _evaluate(node, context):
    kind = node[0]
    if kind == "value":
        return node[1]
    if kind == "not":
        return not _truth(_evaluate(node[1], context))
    if kind in ("and", "or"):
        decides = kind == "or"
        try:
            left = _truth(_evaluate(node[2], context))
        except _Unknown:
            # The other operand may decide the result whatever this one is.
            try:
                right = _truth(_evaluate(node[3], context))
            except (_Failed, _Unknown):
                raise _Unknown() from None
            if right is decides:
                return decides
            raise _Unknown() from None
        return left if left is decides else _truth(_evaluate(node[3], context))
    if kind == "equal":
        left, right = _evaluate(node[2], context), _evaluate(node[3], context)
        if left is None or right is None:
            same = left is None and right is None
        elif _number(left) and _number(right):
            same = left == right
        elif isinstance(left, (bool, int, float, str)) or isinstance(right, (bool, int, float, str)):
            same = type(left) is type(right) and left == right
        else:
            same = bool(_modelled(lambda: left == right))
        return same if node[1] == "==" else not same
    if kind == "compare":
        left, right = _evaluate(node[2], context), _evaluate(node[3], context)
        if not (_number(left) and _number(right) or isinstance(left, str) and isinstance(right, str)):
            raise _Failed()
        return {"<": left < right, "<=": left <= right, ">": left > right, ">=": left >= right}[node[1]]
    root, steps = node[1], node[2]
    if root[0] == "of":
        value = _evaluate(root[1], context)
    elif root[1] in context:
        value = context[root[1]]
    else:
        split = _class_split(root, steps)
        if split is None:
            raise _Failed()             # a name the map lacks: Android cannot resolve it
        from ayu_bridge import runtime
        name, steps = split
        value = _modelled(lambda: runtime.jclass(name))
    for name, arguments in steps:
        if arguments is None:
            value = _property(value, name)
        else:
            value = _call(value, name, [_evaluate(argument, context) for argument in arguments])
    return value


def evaluate(tree, context):
    """``(shown, known)``: whether the item is shown, and whether that is Android's answer."""
    if tree is None:
        return True, True
    try:
        return _truth(_evaluate(tree, context)), True
    except _Failed:
        return False, True
    except _Unknown:
        return False, False


# --- Static inspection -----------------------------------------------------------

def _chains(node):
    if node[0] == "chain":
        yield node
        if node[1][0] == "of":
            yield from _chains(node[1][1])
        for _, arguments in node[2]:
            for argument in arguments or ():
                yield from _chains(argument)
    elif node[0] == "not":
        yield from _chains(node[1])
    elif node[0] != "value":
        yield from _chains(node[2])
        yield from _chains(node[3])


def _fold(node, assignments, depth=0):
    """The string a condition expression always is, None for a callable or no condition, else ``...``."""
    if isinstance(node, ast.Constant):
        return node.value if isinstance(node.value, str) else None if node.value is None else ...
    if isinstance(node, ast.Lambda):
        return None
    if depth > 8:
        return ...
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        left, right = _fold(node.left, assignments, depth + 1), _fold(node.right, assignments, depth + 1)
        return left + right if isinstance(left, str) and isinstance(right, str) else ...
    if isinstance(node, (ast.Name, ast.Attribute)):
        values = assignments.get(node.id if isinstance(node, ast.Name) else node.attr, ())
        if len(values) == 1:
            return None if values[0] is None else _fold(values[0], assignments, depth + 1)
    return ...


def static_conditions(tree):
    """``(conditions, dynamic)``: the literal condition strings of the source's menu items, and how
    many conditions are computed in a way inspection does not follow."""
    assignments = {}
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            assignments.setdefault(node.name, []).append(None)      # a callable condition
        elif isinstance(node, (ast.Assign, ast.AnnAssign, ast.AugAssign)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            for target in targets:
                for item in ast.walk(target):
                    name = item.id if isinstance(item, ast.Name) else item.attr if isinstance(item, ast.Attribute) else None
                    if name is not None:
                        simple = isinstance(node, (ast.Assign, ast.AnnAssign)) and item is target and node.value is not None
                        assignments.setdefault(name, []).append(node.value if simple else ast.Starred(ast.Constant(0)))
    conditions, dynamic = set(), 0
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        name = node.func.id if isinstance(node.func, ast.Name) else node.func.attr if isinstance(node.func, ast.Attribute) else None
        if name not in ("MenuItemData", "add_menu_item"):
            continue
        values = [keyword.value for keyword in node.keywords if keyword.arg == "condition"]
        if name == "MenuItemData" and len(node.args) > 6:
            values.append(node.args[6])
        for value in values:
            folded = _fold(value, assignments)
            if isinstance(folded, str):
                conditions.add(folded)
            elif folded is ...:
                dynamic += 1
    return sorted(conditions), dynamic


def blockers(conditions, tables):
    """``(code, detail)`` for each literal condition the SDK cannot evaluate as Android does:
    syntax outside the subset, a class the host lacks, a member the class's model lacks."""
    found = set()
    for text in conditions:
        try:
            tree = compile(text)
        except Unsupported as error:
            shown = text if len(text) <= 80 else text[:77] + "..."
            found.add(("OPERATION", f"sdk.unprovided_member (MenuItemData condition, {error}: {shown})"))
            continue
        for _, root, steps in _chains(tree) if tree is not None else ():
            static = False
            if root[0] == "name" and root[1] in CONTEXT_CLASSES:
                reference = tables.named(CONTEXT_CLASSES[root[1]])
            elif root[0] == "name" and root[1] not in CONTEXT_NAMES and _class_split(root, steps):
                name, steps = _class_split(root, steps)
                reference, static = tables.named(name), True
                if reference is None:
                    found.add(("CLASS", name))
            else:
                continue
            for name, arguments in steps:
                if reference is None:
                    break
                capital = name[:1].upper() + name[1:]
                # ``a.b`` is a field, a getter or a method ``b()``; ``a.b(...)`` only that method.
                for candidate in (name,) if arguments is not None else (name, "get" + capital, "is" + capital):
                    provided, value = tables.access(reference, candidate, static)
                    if provided is not False:
                        break
                if provided is False:
                    found.add(("MEMBER", tables.label(reference) + "." + name))
                if not provided:
                    break
                if arguments is not None or candidate != name or value is None:
                    value = tables.call(reference, candidate, static)
                if not value:
                    break
                reference, static = value[1], value[0] == "class"
    return sorted(found)


def preflight(conditions, capabilities):
    """The blockers of a source's literal conditions on a host: only the typed menus evaluate them."""
    if "menus.add" not in capabilities["operations"]:
        return [("OPERATION", "menus.add (MenuItemData condition)")] if conditions else []
    import _ayu_members
    return blockers(conditions, _ayu_members.Tables(capabilities))
