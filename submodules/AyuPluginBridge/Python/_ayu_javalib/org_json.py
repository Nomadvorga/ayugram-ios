"""``org.json`` as shipped with Android, implemented in Python.

The parser is Android's lenient ``JSONTokener`` (comments, single quotes, unquoted
strings, ``=``/``;`` separators) and getters apply Android's coercions. ``JSONObject``
keeps insertion order.

Deliberate difference: a Python ``dict``/``list`` stored with ``put`` is wrapped as a
``JSONObject``/``JSONArray`` (Android would store a ``Map`` as-is and print its
``toString()``); ``to_bridge`` returns plain JSON-compatible data.
"""
from __future__ import annotations

import math

from . import java_lang as _l
from .java_lang import NullPointerException, Object, jstr


class JSONException(_l.Exception_):
    pass


class _Null(Object):
    def equals(self, other):
        return other is None or other is self

    def __eq__(self, other):
        return other is None or other is self

    def __hash__(self):
        return 0

    def __bool__(self):
        return False

    def hashCode(self):
        return 0

    def toString(self):
        return "null"

    def __repr__(self):
        return "null"

    def to_bridge(self):
        return None


NULL = _Null()


def _check_double(value):
    if isinstance(value, float) and not math.isfinite(value):
        raise JSONException("Forbidden numeric value: " + jstr(value))
    return value


def _wrap(value):
    """``JSONObject.wrap``: the JSON-model form of a value, or None when there is none."""
    if value is None or value is NULL:
        return NULL
    if isinstance(value, (JSONObject, JSONArray, bool, int, float, str)):
        return value
    if isinstance(value, dict):
        return JSONObject(value)
    if isinstance(value, (list, tuple, set, frozenset)):
        return JSONArray(value)
    if hasattr(type(value), "to_bridge"):
        return _wrap(value.to_bridge())
    if isinstance(value, (_l.Boolean, _l.CharSequence)):
        return bool(value) if isinstance(value, _l.Boolean) else value.toString()
    return None


def _stored(value):
    if isinstance(value, _l.Boolean):
        return bool(value)
    wrapped = _wrap(value) if isinstance(value, (dict, list, tuple, set, frozenset)) else value
    return _check_double(wrapped)


def _number_text(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(int(value))
    _check_double(value)
    if value == 0 and math.copysign(1.0, value) < 0:
        return "-0"
    if value == int(value) and abs(value) < 2 ** 63:
        return str(int(value))
    return _l.double_to_string(value)


def _quote(text):
    out = ['"']
    for char in text:
        if char in '"\\/':
            out.append("\\" + char)
        elif char == "\t":
            out.append("\\t")
        elif char == "\b":
            out.append("\\b")
        elif char == "\n":
            out.append("\\n")
        elif char == "\r":
            out.append("\\r")
        elif char == "\f":
            out.append("\\f")
        elif char <= "\x1f":
            out.append("\\u%04x" % ord(char))
        else:
            out.append(char)
    out.append('"')
    return "".join(out)


def _write(value, indent, level):
    if value is None or value is NULL:
        return "null"
    if isinstance(value, JSONObject):
        if not value._values:
            return "{}"
        if indent is None:
            return "{" + ",".join(_quote(key) + ":" + _write(item, None, 0)
                                  for key, item in value._values.items()) + "}"
        pad, inner = " " * (indent * level), " " * (indent * (level + 1))
        return "{\n" + ",\n".join(inner + _quote(key) + ": " + _write(item, indent, level + 1)
                                   for key, item in value._values.items()) + "\n" + pad + "}"
    if isinstance(value, JSONArray):
        if not value._values:
            return "[]"
        if indent is None:
            return "[" + ",".join(_write(item, None, 0) for item in value._values) + "]"
        pad, inner = " " * (indent * level), " " * (indent * (level + 1))
        return "[\n" + ",\n".join(inner + _write(item, indent, level + 1) for item in value._values) + \
            "\n" + pad + "]"
    if isinstance(value, (bool, int, float)) and not isinstance(value, str):
        return _number_text(value)
    return _quote(jstr(value))


def _plain(value):
    if value is NULL:
        return None
    if isinstance(value, JSONObject):
        return {key: _plain(item) for key, item in value._values.items()}
    if isinstance(value, JSONArray):
        return [_plain(item) for item in value._values]
    return value


def _mismatch(index, value, kind):
    if value is None:
        return JSONException(f"Value at {index} is null.")
    return JSONException(f"Value {jstr(value)} at {index} of type {_type_name(value)} cannot be converted to {kind}")


def _type_name(value):
    if isinstance(value, bool):
        return "java.lang.Boolean"
    if isinstance(value, str):
        return "java.lang.String"
    if isinstance(value, int):
        return "java.lang.Integer" if _l.fits_int(value) else "java.lang.Long"
    if isinstance(value, float):
        return "java.lang.Double"
    return _l.java_name(value)


def _to_boolean(value):
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        if value.lower() == "true":
            return True
        if value.lower() == "false":
            return False
    return None


def _to_double(value):
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return _l.parse_double(value)
        except _l.NumberFormatException:
            return None
    return None


def _to_integer(bits):
    def convert(value):
        if isinstance(value, bool):
            return None
        if isinstance(value, int):
            return _l.signed(value, bits)
        if isinstance(value, float):
            return _l.truncate(value, bits)
        if isinstance(value, str):
            if bits == 64:
                try:
                    return _l.parse_integer(value, 10, 64)
                except _l.NumberFormatException:
                    pass
            number = _to_double(value)
            return None if number is None else _l.truncate(number, bits)
        return None
    return convert


def _to_string(value):
    # As on Android, JSONObject.NULL converts to the text "null".
    return None if value is None else jstr(value)


_CONVERSIONS = {
    "Boolean": (_to_boolean, "boolean", False), "Double": (_to_double, "double", math.nan),
    "Int": (_to_integer(32), "int", 0), "Long": (_to_integer(64), "long", 0),
    "String": (_to_string, "String", ""),
    "JSONObject": (lambda value: value if isinstance(value, JSONObject) else None, "JSONObject", None),
    "JSONArray": (lambda value: value if isinstance(value, JSONArray) else None, "JSONArray", None),
}


def _accessors(cls):
    """Install ``getX``/``optX`` for every conversion on a container with ``get``/``opt``."""
    for suffix, (convert, kind, default) in _CONVERSIONS.items():
        def getter(self, key, _convert=convert, _kind=kind):
            value = self.get(key)
            result = _convert(value)
            if result is None:
                raise _mismatch(_l.jstr(key) if not _l.is_int(key) else key, value, _kind)
            return result

        def option(self, key, fallback=default, _convert=convert):
            value = self.opt(key)
            result = None if value is None else _convert(value)
            return fallback if result is None else result

        setattr(cls, "get" + suffix, getter)
        setattr(cls, "opt" + suffix, option)
    return cls


class JSONTokener(Object):
    def __init__(self, text):
        if text is None:
            raise NullPointerException()
        text = _l._text(text)
        # Consume a byte order mark, as Android does.
        self._text, self._position = text[1:] if text[:1] == "\ufeff" else text, 0

    def syntaxError(self, message):
        return JSONException(message + self.toString())

    def toString(self):
        return f" at character {self._position} of {self._text}"

    def more(self):
        return self._position < len(self._text)

    def next(self, *args):
        if not args:
            if self._position >= len(self._text):
                return "\0"
            self._position += 1
            return self._text[self._position - 1]
        if _l.is_int(args[0]):
            if self._position + args[0] > len(self._text):
                raise self.syntaxError(f"{args[0]} is out of bounds")
            self._position += args[0]
            return self._text[self._position - args[0]:self._position]
        result = self.next()
        if result != args[0]:
            raise self.syntaxError(f"Expected {args[0]} but was {result}")
        return result

    def back(self):
        self._position = max(self._position - 1, 0)

    def skipPast(self, text):
        found = self._text.find(text, self._position)
        self._position = len(self._text) if found < 0 else found + len(text)

    def skipTo(self, char):
        found = self._text.find(char, self._position)
        if found < 0:
            return "\0"
        self._position = found
        return char

    def nextClean(self):
        code = self._clean()
        return "\0" if code is None else code

    def _clean(self):
        text, size = self._text, len(self._text)
        while self._position < size:
            char = text[self._position]
            self._position += 1
            if char in "\t \n\r":
                continue
            if char == "/":
                following = text[self._position:self._position + 1]
                if following == "*":
                    end = text.find("*/", self._position + 1)
                    if end < 0:
                        raise self.syntaxError("Unterminated comment")
                    self._position = end + 2
                    continue
                if following == "/":
                    self._skip_line()
                    continue
                return char
            if char == "#":
                self._skip_line()
                continue
            return char
        return None

    def _skip_line(self):
        while self._position < len(self._text):
            char = self._text[self._position]
            self._position += 1
            if char in "\r\n":
                break

    def nextValue(self):
        char = self._clean()
        if char is None:
            raise self.syntaxError("End of input")
        if char == "{":
            return self._object()
        if char == "[":
            return self._array()
        if char in "'\"":
            return self.nextString(char)
        self._position -= 1
        return self._literal()

    def nextString(self, quote):
        parts, start = [], self._position
        text = self._text
        while self._position < len(text):
            char = text[self._position]
            self._position += 1
            if char == quote:
                parts.append(text[start:self._position - 1])
                return "".join(parts)
            if char == "\\":
                if self._position == len(text):
                    raise self.syntaxError("Unterminated escape sequence")
                parts.append(text[start:self._position - 1])
                parts.append(self._escape())
                start = self._position
        raise self.syntaxError("Unterminated string")

    def _escape(self):
        char = self._text[self._position]
        self._position += 1
        if char == "u":
            digits = self._text[self._position:self._position + 4]
            if len(digits) < 4:
                raise self.syntaxError("Unterminated escape sequence")
            self._position += 4
            try:
                return chr(_l.parse_integer(digits, 16, 32))
            except _l.NumberFormatException:
                raise self.syntaxError("Invalid escape sequence: " + digits) from None
        return {"t": "\t", "b": "\b", "n": "\n", "r": "\r", "f": "\f"}.get(char, char)

    def _literal(self):
        start = self._position
        while self._position < len(self._text) and self._text[self._position] not in "{}[]/\\:,=;# \t\f\r\n":
            self._position += 1
        literal = self._text[start:self._position]
        if not literal:
            raise self.syntaxError("Expected literal value")
        lowered = literal.lower()
        if lowered == "null":
            return NULL
        if lowered == "true":
            return True
        if lowered == "false":
            return False
        if "." not in literal:
            base, digits = 10, literal
            if literal[:2].lower() == "0x":
                base, digits = 16, literal[2:]
            elif literal[:1] == "0" and len(literal) > 1:
                base, digits = 8, literal[1:]
            try:
                return _l.parse_integer(digits, base, 64)
            except _l.NumberFormatException:
                pass
        try:
            return _l.parse_double(literal)
        except _l.NumberFormatException:
            return literal

    def _object(self):
        result = JSONObject()
        first = self._clean()
        if first == "}":
            return result
        if first is not None:
            self._position -= 1
        while True:
            name = self.nextValue()
            if not isinstance(name, str):
                if name is NULL:
                    raise self.syntaxError("Names cannot be null")
                raise self.syntaxError(f"Names must be strings, but {jstr(name)} is of type {_type_name(name)}")
            separator = self._clean()
            if separator not in (":", "="):
                raise self.syntaxError("Expected ':' after " + name)
            if self._text[self._position:self._position + 1] == ">":
                self._position += 1
            result.put(name, self.nextValue())
            following = self._clean()
            if following == "}":
                return result
            if following not in (";", ","):
                raise self.syntaxError("Unterminated object")

    def _array(self):
        result = JSONArray()
        has_trailing_separator = False
        while True:
            char = self._clean()
            if char is None:
                raise self.syntaxError("Unterminated array")
            if char == "]":
                if has_trailing_separator:
                    result.put(None)
                return result
            if char in ",;":
                result.put(None)
                has_trailing_separator = True
                continue
            self._position -= 1
            result.put(self.nextValue())
            following = self._clean()
            if following == "]":
                return result
            if following not in (",", ";"):
                raise self.syntaxError("Unterminated array")
            has_trailing_separator = True


def _parse(source, kind):
    tokener = source if isinstance(source, JSONTokener) else JSONTokener(source)
    value = tokener.nextValue()
    if not isinstance(value, kind):
        raise JSONException(f"Value {jstr(value)} of type {_type_name(value)} cannot be converted to {kind.__name__}")
    return value


@_accessors
class JSONObject(Object):
    NULL = NULL

    def __init__(self, *args):
        self._values = {}
        if not args:
            return
        source = args[0]
        if len(args) == 2:
            for name in args[1]:
                value = source.opt(name)
                if value is not None:
                    self._values[name] = value
        elif isinstance(source, (str, JSONTokener)):
            self._values = _parse(source, JSONObject)._values
        elif isinstance(source, JSONObject):
            self._values = dict(source._values)
        elif isinstance(source, dict):
            for key, value in source.items():
                if key is None:
                    raise NullPointerException("key == null")
                wrapped = _wrap(value)
                if wrapped is None:
                    raise JSONException(f"Value {jstr(value)} of type {_type_name(value)} is not JSON data")
                self._values[jstr(key)] = _check_double(wrapped)
        elif source is None:
            raise NullPointerException()
        else:
            raise TypeError("JSONObject takes a JSON string, a map, a JSONTokener or another JSONObject")

    @staticmethod
    def _name(name):
        if name is None:
            raise JSONException("Names must be non-null")
        return name

    def length(self):
        return len(self._values)

    def put(self, name, value):
        if value is None:
            self._values.pop(name, None)
            return self
        self._values[JSONObject._name(name)] = _stored(value)
        return self

    def putOpt(self, name, value):
        if name is None or value is None:
            return self
        return self.put(name, value)

    def accumulate(self, name, value):
        current = self._values.get(JSONObject._name(name))
        if current is None:
            return self.put(name, value)
        if isinstance(current, JSONArray):
            current.put(value)
        else:
            self._values[name] = JSONArray([current]).put(value)
        return self

    def append(self, name, value):
        current = self._values.get(JSONObject._name(name))
        if current is None:
            self._values[name] = JSONArray().put(value)
        elif isinstance(current, JSONArray):
            current.put(value)
        else:
            raise JSONException(f"Key {name} is not a JSONArray")
        return self

    def remove(self, name):
        return self._values.pop(name, None)

    def isNull(self, name):
        value = self._values.get(name)
        return value is None or value is NULL

    def has(self, name):
        return name in self._values

    def get(self, name):
        value = self._values.get(name)
        if value is None:
            raise JSONException("No value for " + jstr(name))
        return value

    def opt(self, name):
        return self._values.get(name)

    def keys(self):
        from . import java_util
        return java_util.Iterator(list(self._values), self.remove)

    def keySet(self):
        from . import java_util
        return java_util.LinkedHashSet(self._values)

    def names(self):
        return JSONArray(list(self._values)) if self._values else None

    def toJSONArray(self, names):
        if names is None or names.length() == 0:
            return None
        result = JSONArray()
        for index in range(names.length()):
            result.put(self.opt(JSONArray._to_name(names.opt(index))))
        return result

    def toString(self, indent=None):
        return _write(self, indent if indent else None, 0)

    def to_bridge(self):
        return _plain(self)

    def __len__(self):
        return len(self._values)

    def __iter__(self):
        return iter(list(self._values))

    def __contains__(self, name):
        return name in self._values

    def __getitem__(self, name):
        return self.get(name)

    def __eq__(self, other):
        return self is other

    def __hash__(self):
        return id(self)

    def __repr__(self):
        return self.toString()

    @staticmethod
    def numberToString(number):
        if number is None:
            raise JSONException("Number must be non-null")
        return _number_text(number)

    @staticmethod
    def quote(text):
        return '""' if text is None else _quote(text)

    @staticmethod
    def wrap(value):
        return _wrap(value)


@_accessors
class JSONArray(Object):
    def __init__(self, source=None):
        self._values = []
        if source is None:
            return
        if isinstance(source, (str, JSONTokener)):
            self._values = _parse(source, JSONArray)._values
        elif isinstance(source, JSONArray):
            self._values = list(source._values)
        elif isinstance(source, (list, tuple, set, frozenset)) or hasattr(type(source), "__iter__"):
            for value in source:
                wrapped = _wrap(value)
                self.put(value if wrapped is None else wrapped)
        else:
            raise JSONException("Not a primitive array: " + type(source).__name__)

    @staticmethod
    def _to_name(value):
        return _to_string(value) if value is not None and value is not NULL else None

    def length(self):
        return len(self._values)

    def put(self, *args):
        if len(args) == 1:
            self._values.append(_stored(args[0]))
        elif len(args) == 2:
            index, value = args
            if index < 0:
                raise JSONException(f"Index {index} out of range [0..{len(self._values)})")
            value = _stored(value)
            while len(self._values) <= index:
                self._values.append(None)
            self._values[index] = value
        else:
            raise TypeError("put takes (value) or (index, value)")
        return self

    def isNull(self, index):
        value = self.opt(index)
        return value is None or value is NULL

    def get(self, index):
        if not _l.is_int(index) or not 0 <= index < len(self._values):
            raise JSONException(f"Index {index} out of range [0..{len(self._values)})")
        value = self._values[index]
        if value is None:
            raise JSONException(f"Value at {index} is null.")
        return value

    def opt(self, index):
        return self._values[index] if _l.is_int(index) and 0 <= index < len(self._values) else None

    def remove(self, index):
        return self._values.pop(index) if _l.is_int(index) and 0 <= index < len(self._values) else None

    def join(self, separator):
        return separator.join(_write(value, None, 0) for value in self._values)

    def toJSONObject(self, names):
        result = JSONObject()
        length = min(names.length(), len(self._values))
        if length == 0:
            return None
        for index in range(length):
            result.put(JSONArray._to_name(names.opt(index)), self.opt(index))
        return result

    def toString(self, indent=None):
        return _write(self, indent if indent else None, 0)

    def to_bridge(self):
        return _plain(self)

    def __len__(self):
        return len(self._values)

    def __iter__(self):
        return iter(list(self._values))

    def __getitem__(self, index):
        return self.get(index)

    def __eq__(self, other):
        return isinstance(other, JSONArray) and self._values == other._values

    def __hash__(self):
        return len(self._values)

    def hashCode(self):
        return _l.java_hash(self._values)

    def __repr__(self):
        return self.toString()


CLASSES = _l.register({
    "org.json.JSONObject": JSONObject,
    "org.json.JSONArray": JSONArray,
    "org.json.JSONException": JSONException,
    "org.json.JSONTokener": JSONTokener,
})
