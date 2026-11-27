"""Class members of the Swift host, read from its adapter literals without compiling Swift.

The result has the shape of the ``members`` entry of ``runtime.capabilities``. A class is
listed only when every member argument of its adapter is a literal this reader resolves
(directly, through a ``let`` of the same member, or through a ``static let``); any other
class is left out, which the bridge SDK treats as unknown members. The built-in view
classes are the one approximation: the host computes their methods per class in code, so
they get the union of every view method (an upper bound: a method a particular view class
rejects is not noticed).
"""
from __future__ import annotations

import re
from typing import Any

_TOKEN = re.compile(r'//[^\n]*|/\*.*?\*/|"(?:[^"\\\n]|\\.)*"|[A-Za-z_][A-Za-z0-9_]*|\$[0-9]+|\S', re.S)
_MEMBER = re.compile(r"[A-Za-z][A-Za-z0-9_]*\Z")
_OPEN = {"(": ")", "[": "]", "{": "}"}
_ADAPTER = "AyuBridgeClassAdapter"
_ARGUMENTS = ("constants", "constructor", "staticMethods", "staticFields", "methods", "readableFields", "writableFields",
              "results")
MAX_DEPTH = 6


class _Source:
    """Tokens of one Swift file with matched brackets."""

    def __init__(self, text: str):
        self.tokens = [item for item in _TOKEN.findall(text) if not item.startswith(("//", "/*"))]
        self.match: dict[int, int] = {}
        self.parent: list[int] = []
        stack: list[int] = []
        for index, token in enumerate(self.tokens):
            self.parent.append(stack[-1] if stack else -1)
            if token in _OPEN:
                stack.append(index)
            elif token in _OPEN.values():
                if not stack or _OPEN[self.tokens[stack[-1]]] != token:
                    raise ValueError("unbalanced Swift source")
                self.match[stack.pop()] = index
        if stack:
            raise ValueError("unbalanced Swift source")

    def string(self, index: int) -> str | None:
        token = self.tokens[index]
        return token[1:-1] if token.startswith('"') and "\\" not in token else None

    def split(self, start: int, end: int) -> list[tuple[int, int]]:
        """Top-level comma-separated ranges of ``tokens[start:end]``."""
        parts, begin, index = [], start, start
        while index < end:
            token = self.tokens[index]
            if token in _OPEN:
                index = self.match[index]
            elif token == ",":
                parts.append((begin, index))
                begin = index + 1
            index += 1
        if begin < end:
            parts.append((begin, end))
        return parts

    def definition(self, name: str, before: int, static: bool = False) -> tuple[int, int, bool] | None:
        """The initializer range of the nearest enclosing ``let``/``var`` of a name, and whether it is ``let``.

        ``static`` looks at ``static let`` declarations only, as ``Self.name`` does.
        """
        block = self.parent[before]
        while not static:
            index = before - 1
            while index > block:
                if self.tokens[index] in _OPEN.values():
                    # Skip a closed block: its declarations are not in scope.
                    index = next(start for start, stop in self.match.items() if stop == index)
                elif self.tokens[index] == name and self.tokens[index - 1] in ("let", "var"):
                    start = index + 1
                    while start < len(self.tokens) and self.tokens[start] != "=":
                        if self.tokens[start] in _OPEN:
                            start = self.match[start]
                        elif self.tokens[start] in ("let", "var", "func", "}", "return"):
                            return None
                        start += 1
                    return self._initializer(start + 1, self.tokens[index - 1] == "let")
                index -= 1
            if block < 0:
                break
            before, block = block, self.parent[block]
        # A ``static let`` may be declared after its use.
        for index, token in enumerate(self.tokens):
            if token == name and self.tokens[index - 1] == "let" and self.tokens[index - 2] == "static":
                start = index + 1
                while start < len(self.tokens) and self.tokens[start] != "=":
                    start = self.match[start] + 1 if self.tokens[start] in _OPEN else start + 1
                return self._initializer(start + 1, True)
        return None

    def _initializer(self, start: int, constant: bool) -> tuple[int, int, bool] | None:
        if start >= len(self.tokens):
            return None
        if self.tokens[start] in _OPEN:
            end = self.match[start] + 1
        elif self.tokens[start] in ("Self", "self") and self.tokens[start + 1] == ".":
            end = start + 3
        elif start + 1 < len(self.tokens) and self.tokens[start + 1] == "(":
            end = self.match[start + 1] + 1
        else:
            end = start + 1
        return start, end, constant


def _names(source: _Source, start: int, end: int, keys: bool, position: int, depth: int = 0) -> set[str] | None:
    """String keys (or elements) of a literal expression, following ``let`` names; None when not certain."""
    tokens = source.tokens
    if depth > MAX_DEPTH or start >= end:
        return None
    if tokens[start] in ("Set", "Array") and end - start >= 3 and tokens[start + 1] == "(" and source.match[start + 1] == end - 1:
        return _names(source, start + 2, end - 1, keys, position, depth + 1)
    static = tokens[start] in ("Self", "self") and end - start == 3 and tokens[start + 1] == "."
    if static:
        start += 2
    if tokens[start] == "Dictionary" and end - start > 6 and tokens[start + 1] == "(" and source.match[start + 1] == end - 1:
        # ``Dictionary(uniqueKeysWithValues: table.map { key, ... in (key, ...) })``: the keys of ``table``.
        first = start + 2
        if (tokens[first] == "uniqueKeysWithValues" and tokens[first + 3:first + 6] == [".", "map", "{"]
                and tokens[first + 7] in (",", "in") and tokens[first + 6] != "_"):
            body = tokens[first + 6:source.match[first + 5]]
            pair = body.index("in") + 1 if "in" in body else len(body)
            if body[pair:pair + 3] == ["(", body[0], ","]:
                for keys_first in (True, False):
                    found_names = _names(source, first + 2, first + 3, keys_first, position, depth + 1)
                    if found_names is not None:
                        return found_names
        return None
    if end - start == 1 and re.match(r"[A-Za-z_]\w*\Z", tokens[start]):
        found = source.definition(tokens[start], position, static)
        if found is None:
            return _computed_names(source, tokens[start], depth)
        first, last, constant = found
        if not constant or last < len(tokens) and tokens[last] in (".", "+", "?", "as", "(", "["):
            return None
        return _names(source, first, last, keys, first, depth + 1)
    if tokens[start] != "[" or source.match[start] != end - 1:
        return None
    if end - start == 3 and tokens[start + 1] == ":" or end - start == 2:
        return set()
    result = set()
    for first, last in source.split(start + 1, end - 1):
        name = source.string(first)
        if name is None or not _MEMBER.match(name):
            return None
        if keys != (last - first > 1 and tokens[first + 1] == ":") or not keys and last - first != 1:
            return None
        result.add(name)
    return result


def _computed_names(source: _Source, name: str, depth: int) -> set[str] | None:
    """Keys of ``static var name: [...] { var keys = [:]; for (_, key) in list.enumerated() { keys[key] = ... }; return keys }``."""
    tokens = source.tokens
    for index, token in enumerate(tokens):
        if token != name or tokens[index - 1] != "var" or tokens[index - 2] != "static":
            continue
        brace = index + 1
        while brace < len(tokens) and tokens[brace] not in ("{", "="):
            brace = source.match[brace] + 1 if tokens[brace] in _OPEN else brace + 1
        if brace >= len(tokens) or tokens[brace] != "{":
            return None
        body = tokens[brace + 1:source.match[brace]]
        if body.count("for") != 1 or body[0] != "var" or body[-2] != "return" or body[-1] != body[1] or body.count(body[1]) != 3:
            return None
        loop = body.index("for")
        try:
            source_at = body.index("in", loop) + 1
            block = body.index("{", source_at)
        except ValueError:
            return None
        variables = [item for item in body[loop + 1:source_at - 1] if item not in ("(", ")", ",", "_")]
        iterated = body[source_at:block]
        if iterated[1:] not in ([], [".", "enumerated", "(", ")"]) or body[block + 1:block + 5] != [body[1], "[", variables[-1], "]"]:
            return None
        position = brace + 1 + source_at
        return _names(source, position, position + 1, False, position, depth + 1)
    return None


def _adapters(source: _Source) -> list[tuple[list[str], dict[str, Any] | None]]:
    """Every adapter expression: the class names it is built for and its members (None when not certain)."""
    tokens = source.tokens
    found = []
    for index, token in enumerate(tokens):
        if token != _ADAPTER or index + 1 >= len(tokens) or tokens[index + 1] != "(":
            continue
        arguments = {}
        for first, last in source.split(index + 2, source.match[index + 1]):
            if last - first >= 2 and tokens[first + 1] == ":":
                arguments[tokens[first]] = (first + 2, last)
        if "name" not in arguments:
            continue
        names = _class_names(source, *arguments["name"], index)
        if not names:
            continue
        entry: dict[str, Any] | None = {}
        for label in _ARGUMENTS:
            if label not in arguments:
                entry[label] = False if label == "constructor" else {} if label == "results" else set()
                continue
            first, last = arguments[label]
            if label == "constructor":
                value: Any = _is_closure(source, first, last, index)
            elif label == "results":
                value = _class_map(source, first, last, index)
            else:
                value = _names(source, first, last, label not in ("readableFields", "writableFields"), index)
            if value is None:
                entry = None
                break
            entry[label] = value
        found.append((names, entry))
    return found


def _class_map(source: _Source, start: int, end: int, position: int) -> dict[str, str] | None:
    """A ``["member": class name]`` literal whose values are string literals or ``static let`` names."""
    tokens = source.tokens
    if tokens[start] != "[" or source.match[start] != end - 1:
        return None
    if end - start == 3 and tokens[start + 1] == ":":
        return {}
    result = {}
    for first, last in source.split(start + 1, end - 1):
        member = source.string(first)
        names = _class_names(source, first + 2, last, position) if last - first > 2 and tokens[first + 1] == ":" else []
        if member is None or not _MEMBER.match(member) or len(names) != 1:
            return None
        result[member] = names[0]
    return result


def _is_closure(source: _Source, start: int, end: int, position: int, depth: int = 0) -> bool | None:
    tokens = source.tokens
    if tokens[start] == "nil" and end - start == 1:
        return False
    if tokens[start] == "{" and source.match[start] == end - 1:
        return True
    if end - start == 1 and depth < MAX_DEPTH:
        found = source.definition(tokens[start], position)
        if found is not None and found[2]:
            return _is_closure(source, found[0], found[1], found[0], depth + 1)
    return None


def _class_names(source: _Source, start: int, end: int, position: int) -> list[str]:
    """The class name of an adapter: a literal, a ``static let``, or the literals its factory is called with."""
    tokens = source.tokens
    if end - start == 1 and source.string(start) is not None:
        return [source.string(start)]
    static = tokens[start] in ("Self", "self") and end - start == 3 and tokens[start + 1] == "."
    if static:
        start += 2
    if end - start != 1:
        return []
    found = source.definition(tokens[start], position, static)
    if found is not None:
        return [source.string(found[0])] if found[1] - found[0] == 1 and source.string(found[0]) is not None else []
    parameter = tokens[start]
    # A factory parameter: the class names are the string literals its calls pass first.
    block = source.parent[position]
    while block >= 0:
        header = block - 1
        while header > 0 and tokens[header] not in ("{", "}", "func"):
            header -= 1
        if tokens[header] == "func" and tokens[header + 2] == "(":
            parameters = source.split(header + 3, source.match[header + 2])
            if not parameters or parameter not in tokens[parameters[0][0]:parameters[0][1]]:
                return []
            factory, names = tokens[header + 1], []
            for index, token in enumerate(tokens):
                if token != factory or tokens[index - 1] == "func" or index + 1 >= len(tokens) or tokens[index + 1] != "(":
                    continue
                # ``.factory(`` on anything but the type itself is another API of that name.
                if tokens[index - 1] == "." and tokens[index - 2] not in ("Self", "self"):
                    continue
                first, last = source.split(index + 2, source.match[index + 1])[0]
                if last - first > 2 and tokens[first + 1] == ":":
                    first += 2
                name = _class_names(source, first, last, index) if (first, last) != (start, end) else []
                if len(name) != 1:
                    return []
                names += name
            return names
        block = source.parent[block]
    return []


def _static_names(source: _Source, name: str, keys: bool) -> set[str] | None:
    """Names of a ``static let`` literal declared anywhere in the file."""
    tokens = source.tokens
    for index, token in enumerate(tokens):
        if token == name and tokens[index - 1] == "let" and tokens[index - 2] == "static":
            start = index + 1
            while tokens[start] != "=":
                start = source.match[start] + 1 if tokens[start] in _OPEN else start + 1
            start += 1
            if tokens[start] == "[":
                return _names(source, start, source.match[start] + 1, keys, start)
    return None


def _builtin(source: _Source, registered: set[str]) -> tuple[dict[str, dict[str, Any]], set[str]]:
    """Members of the classes the native host implements without an adapter, and the upper-bound ones."""
    tokens = source.tokens
    classes: dict[str, set[str]] = {}
    for index, token in enumerate(tokens):
        if token == "classes" and tokens[index - 1] == "let" and tokens[index - 2] == "static":
            start = index + 1
            while tokens[start] != "=":
                start = source.match[start] + 1 if tokens[start] in _OPEN else start + 1
            start += 1
            if tokens[start] != "[":
                return {}, set()
            for first, last in source.split(start + 1, source.match[start]):
                name = source.string(first)
                constants = _names(source, first + 2, last, True, first) if name and tokens[first + 1] == ":" else None
                if name is None or constants is None:
                    return {}, set()
                classes[name] = constants
    reflection = _static_names(source, "reflectionMethods", False)
    views = _strings(source, "viewClasses")
    layout_fields = _static_names(source, "layoutFields", False)
    view_methods: set[str] | None = set()
    for name, keys in (("readMethods", False), ("writeMethods", True), ("otherWriteMethods", True),
                       ("scrollReadMethods", False), ("scrollWriteMethods", True), ("progressReadMethods", False)):
        names = _static_names(source, name, keys)
        view_methods = None if names is None or view_methods is None else view_methods | names
    exact_methods: dict[str, set[str]] = {}
    body = _function_body(source, "methods")
    if body is None or reflection is None or views is None or view_methods is None or layout_fields is None:
        return {}, set()
    index = body[0]
    while index < body[1]:
        # ``if name == "X" { return [...] }`` is the complete method list of X.
        if (tokens[index] == "if" and tokens[index + 1] == "name" and tokens[index + 2] == "=" and tokens[index + 3] == "="
                and source.string(index + 4) is not None and tokens[index + 5] == "{" and tokens[index + 6] == "return"
                and tokens[index + 7] == "[" and source.match[index + 7] + 1 == source.match[index + 5]):
            names = _names(source, index + 7, source.match[index + 7] + 1, False, index)
            if names is not None:
                exact_methods[source.string(index + 4)] = names
            index = source.match[index + 5]
        elif source.string(index) is not None and _MEMBER.match(source.string(index)):
            view_methods.add(source.string(index))
        index += 1
    result, upper = {}, set()
    for name, constants in classes.items():
        if name in registered or name.startswith("["):
            continue
        layout = name.endswith("$LayoutParams")
        if name in views:
            methods = view_methods | {"getClass"}
            upper.add(name)
        elif name in exact_methods:
            methods = exact_methods[name]
        elif layout:
            methods = {"getClass"}
        else:
            methods = set()
        fields = set(layout_fields) if layout else set()
        result[name] = {"constructor": layout or name in views, "methods": methods, "fields": fields,
                        "writable_fields": set(fields), "static_methods": set(reflection), "static_fields": constants,
                        "results": {}}
    return result, upper


def _strings(source: _Source, name: str) -> set[str] | None:
    """Elements of a ``static let`` string collection whose values are not member names (class names)."""
    tokens = source.tokens
    for index, token in enumerate(tokens):
        if token == name and tokens[index - 1] == "let" and tokens[index - 2] == "static":
            start = index + 1
            while tokens[start] != "=":
                start = source.match[start] + 1 if tokens[start] in _OPEN else start + 1
            start += 1
            if tokens[start] != "[":
                return None
            values = [source.string(first) if last - first == 1 else None
                      for first, last in source.split(start + 1, source.match[start])]
            return None if None in values else set(values)
    return None


def _function_body(source: _Source, name: str) -> tuple[int, int] | None:
    """The body of ``static func <name>(for name: String)``."""
    tokens = source.tokens
    for index, token in enumerate(tokens):
        if (token == name and tokens[index - 1] == "func" and tokens[index - 2] == "static" and tokens[index + 1] == "("):
            brace = source.match[index + 1] + 1
            while brace < len(tokens) and tokens[brace] != "{":
                brace += 1
            return (brace + 1, source.match[brace]) if brace < len(tokens) else None
    return None


def scrape_members(sources: dict[str, str]) -> dict[str, Any]:
    """``{"table": members entry, "disabled": class names, "upper_bound": class names}``.

    ``sources`` maps a Swift file name to its text. ``disabled`` names the adapters a file's
    ``enabled`` filter leaves out and nothing else registers: they are not host classes.
    """
    table: dict[str, dict[str, Any]] = {}
    registered: set[str] = set()
    disabled: set[str] = set()
    reflection: set[str] | None = None
    parsed = {}
    for name, text in sorted(sources.items()):
        try:
            parsed[name] = _Source(text)
        except ValueError:
            continue
    for name, source in parsed.items():
        reflection = reflection or _static_names(source, "reflectionMethods", False)
    for name, source in parsed.items():
        if _ADAPTER not in source.tokens:
            continue
        # ``let enabled: Set<String> = [...]`` filters the adapters of its file.
        enabled = None
        for index, token in enumerate(source.tokens):
            if token == "enabled" and source.tokens[index - 1] == "let":
                found = source.definition("enabled", index + 2)
                if found is not None and source.tokens[found[0]] == "[":
                    values = [source.string(first) for first, last in source.split(found[0] + 1, found[1] - 1)]
                    enabled = None if None in values else set(values)
        for names, entry in _adapters(source):
            for class_name in names:
                if enabled is not None and class_name not in enabled:
                    disabled.add(class_name)
                    continue
                if class_name in registered:
                    table.pop(class_name, None)  # two adapter expressions for one name: not certain
                    continue
                registered.add(class_name)
                if entry is None or reflection is None:
                    continue
                table[class_name] = {
                    "constructor": entry["constructor"], "methods": entry["methods"] | {"getClass"},
                    "fields": entry["readableFields"], "writable_fields": entry["writableFields"],
                    "static_methods": entry["staticMethods"] | reflection,
                    "static_fields": entry["constants"] | entry["staticFields"], "results": entry["results"],
                }
    upper: set[str] = set()
    builtin: dict[str, dict[str, Any]] = {}
    for name, source in parsed.items():
        found, bound = _builtin(source, registered)
        if found:
            builtin, upper = found, bound
    # The host adds members in code for these; their literal lists alone would be too small.
    known = set(builtin)
    for class_name in ("java.lang.Class", "android.text.TextUtils", "java.lang.reflect.Array",
                       "android.view.ViewOutlineProvider", "android.widget.LinearLayout$LayoutParams"):
        builtin.pop(class_name, None)
    table.update(builtin)
    builtin = dict.fromkeys(known)
    for entry in table.values():
        entry["writable_fields"] = entry["writable_fields"] & entry["fields"]
        # A result names a class of the table or the declaration is not usable.
        entry["results"] = {member: name for member, name in entry["results"].items()
                            if name in registered or name in builtin}
    return {"table": {"version": 1, "classes": {name: {key: sorted(value) if isinstance(value, set) else value
                                                       for key, value in entry.items()}
                                                for name, entry in sorted(table.items())}},
            "disabled": sorted(disabled - registered - set(builtin)), "upper_bound": sorted(upper)}
