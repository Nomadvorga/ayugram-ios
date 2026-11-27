"""Bounded YAML subset loader for plugin package manifests and string tables.

Android reads these files with PyYAML's ``safe_load``. This loader accepts the
subset package builders emit (block and flow mappings and sequences, plain,
quoted and block scalars, comments) and resolves plain scalars with PyYAML's
YAML 1.1 rules, so ``yes`` is ``True`` and ``1:30`` is ``90`` here too.
Anchors, aliases, tags, merge keys, complex keys, directives and multiple
documents raise ``YAMLError`` instead of being guessed at.
"""
from __future__ import annotations

import datetime
import re

MAX_CHARS = 1_048_576
MAX_DEPTH = 64
MAX_NODES = 100_000

_BOOL = {name: value for value, names in ((True, "yes Yes YES true True TRUE on On ON"),
                                          (False, "no No NO false False FALSE off Off OFF"))
         for name in names.split()}
_NULL = frozenset({"~", "null", "Null", "NULL", ""})
_INT = re.compile(r"[-+]?(?:0b[0-1_]+|0[0-7_]+|0|[1-9][0-9_]*|0x[0-9a-fA-F_]+|[1-9][0-9_]*(?::[0-5]?[0-9])+)\Z")
_FLOAT = re.compile(r"(?:[-+]?[0-9][0-9_]*\.[0-9_]*(?:[eE][-+][0-9]+)?|\.[0-9][0-9_]*(?:[eE][-+][0-9]+)?"
                    r"|[-+]?[0-9][0-9_]*(?::[0-5]?[0-9])+\.[0-9_]*|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN))\Z")
_TIMESTAMP = re.compile(
    r"(?P<year>[0-9]{4})-(?P<month>[0-9][0-9]?)-(?P<day>[0-9][0-9]?)"
    r"(?:(?:[Tt]|[ \t]+)(?P<hour>[0-9][0-9]?):(?P<minute>[0-9]{2}):(?P<second>[0-9]{2})(?:\.(?P<fraction>[0-9]*))?"
    r"(?:[ \t]*(?P<tz>Z|(?P<tz_sign>[-+])(?P<tz_hour>[0-9][0-9]?)(?::(?P<tz_minute>[0-9]{2}))?))?)?\Z")
_DATE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}\Z")
_ESCAPES = {"0": "\0", "a": "\a", "b": "\b", "t": "\t", "\t": "\t", "n": "\n", "v": "\v", "f": "\f", "r": "\r",
            "e": "\x1b", " ": " ", '"': '"', "/": "/", "\\": "\\", "N": "\x85", "_": "\xa0", "L": "\u2028",
            "P": "\u2029"}
_HEX_ESCAPES = {"x": 2, "u": 4, "U": 8}
_UNSUPPORTED_START = "&*!%@`"


class YAMLError(ValueError):
    """The document is malformed or uses YAML outside the supported subset."""


def _resolve(text):
    """A plain scalar as PyYAML's safe loader types it."""
    if text in _NULL:
        return None
    if text in _BOOL:
        return _BOOL[text]
    if text == "<<" or text == "=":
        raise YAMLError("Merge and value keys are not supported")
    if _INT.match(text):
        value = text.replace("_", "")
        sign = -1 if value.startswith("-") else 1
        value = value.lstrip("+-")
        if value == "0":
            return 0
        if value.startswith("0b"):
            return sign * int(value[2:], 2)
        if value.startswith("0x"):
            return sign * int(value[2:], 16)
        if value.startswith("0"):
            return sign * int(value, 8)
        if ":" in value:
            total = 0
            for part in value.split(":"):
                total = total * 60 + int(part)
            return sign * total
        return sign * int(value)
    if _FLOAT.match(text):
        value = text.replace("_", "").lower()
        sign = -1.0 if value.startswith("-") else 1.0
        value = value.lstrip("+-")
        if value == ".inf":
            return sign * float("inf")
        if value == ".nan":
            return float("nan")
        if ":" in value:
            total = 0.0
            for part in value.split(":"):
                total = total * 60 + float(part)
            return sign * total
        return sign * float(value)
    match = _TIMESTAMP.match(text)
    if match and (match.group("hour") is not None or _DATE.match(text)):
        try:
            year, month, day = (int(match.group(name)) for name in ("year", "month", "day"))
            if match.group("hour") is None:
                return datetime.date(year, month, day)
            fraction = int((match.group("fraction") or "")[:6].ljust(6, "0")) if match.group("fraction") else 0
            zone = None
            if match.group("tz_sign"):
                delta = datetime.timedelta(hours=int(match.group("tz_hour")),
                                           minutes=int(match.group("tz_minute") or 0))
                zone = datetime.timezone(-delta if match.group("tz_sign") == "-" else delta)
            elif match.group("tz"):
                zone = datetime.timezone.utc
            return datetime.datetime(year, month, day, int(match.group("hour")), int(match.group("minute")),
                                     int(match.group("second")), fraction, tzinfo=zone)
        except ValueError as error:
            raise YAMLError("Invalid timestamp") from error
    return text


def _fold(lines, glued=()):
    """Fold the lines of a multi-line flow scalar.

    One line break becomes a space and n empty lines between two lines become
    n newlines. The last line always counts as content, even when it is empty.
    A line whose index is in ``glued`` follows an escaped line break.
    """
    result, empty = lines[0], 0
    for index, line in enumerate(lines[1:], 1):
        if index in glued:
            result += line
            continue
        if line == "" and index < len(lines) - 1:
            empty += 1
            continue
        result += "\n" * empty if empty else " "
        result += line
        empty = 0
    return result


def _double_quoted(raw):
    """Decode the body of a double-quoted scalar (without its quotes)."""
    physical = raw.split("\n")
    lines, glued, continues = [], set(), False
    for number, line in enumerate(physical):
        tokens, index = [], 0
        if continues:
            glued.add(number)
        continues = False
        while index < len(line):
            char = line[index]
            if char != "\\":
                tokens.append((char, False))
                index += 1
                continue
            if index + 1 == len(line):
                if number == len(physical) - 1:
                    raise YAMLError("Unterminated escape in a double-quoted scalar")
                continues = True
                break
            code = line[index + 1]
            if code in _ESCAPES:
                tokens.append((_ESCAPES[code], True))
                index += 2
            elif code in _HEX_ESCAPES:
                width = _HEX_ESCAPES[code]
                digits = line[index + 2:index + 2 + width]
                if len(digits) != width or not re.fullmatch(r"[0-9a-fA-F]+", digits):
                    raise YAMLError("Invalid escape in a double-quoted scalar")
                try:
                    tokens.append((chr(int(digits, 16)), True))
                except (ValueError, OverflowError) as error:
                    raise YAMLError("Invalid escape in a double-quoted scalar") from error
                index += 2 + width
            else:
                raise YAMLError("Unknown escape in a double-quoted scalar")
        # Only unescaped blanks next to a line break are dropped.
        blank = ((" ", False), ("\t", False))
        if number:
            while tokens and tokens[0] in blank:
                tokens.pop(0)
        if number < len(physical) - 1 and not continues:
            while tokens and tokens[-1] in blank:
                tokens.pop()
        lines.append("".join(char for char, _ in tokens))
    return _fold(lines, glued)


def _single_quoted(raw):
    lines = raw.split("\n")
    parts = [lines[0].rstrip(" \t") if len(lines) > 1 else lines[0]]
    for number, line in enumerate(lines[1:], 1):
        parts.append(line.strip(" \t") if number < len(lines) - 1 else line.lstrip(" \t"))
    return _fold(parts).replace("''", "'")


def _quoted_end(text, start):
    """Index just past the closing quote of the quoted scalar starting at ``start``, or -1."""
    quote, index = text[start], start + 1
    while index < len(text):
        char = text[index]
        if quote == '"' and char == "\\":
            index += 2
            continue
        if char == quote:
            if quote == "'" and text[index + 1:index + 2] == "'":
                index += 2
                continue
            return index + 1
        index += 1
    return -1


def _comment_free(text):
    """``text`` without a trailing comment; only for text holding no quoted scalar."""
    for index, char in enumerate(text):
        if char == "#" and (index == 0 or text[index - 1] in " \t"):
            return text[:index].rstrip(" \t")
    return text.rstrip(" \t")


class _Flow:
    """Recursive-descent parser for one flow collection."""

    def __init__(self, text, budget):
        self.text, self.index, self.budget = text, 0, budget

    def skip(self):
        while self.index < len(self.text):
            char = self.text[self.index]
            if char in " \t\n":
                self.index += 1
            elif char == "#" and (self.index == 0 or self.text[self.index - 1] in " \t\n"):
                while self.index < len(self.text) and self.text[self.index] != "\n":
                    self.index += 1
            else:
                break

    def peek(self):
        self.skip()
        return self.text[self.index] if self.index < len(self.text) else ""

    def scalar(self, key=False):
        """A quoted or plain flow scalar as ``(value, was_quoted)``."""
        char = self.peek()
        if char in "\"'":
            end = _quoted_end(self.text, self.index)
            if end < 0:
                raise YAMLError("Unterminated quoted scalar")
            raw = self.text[self.index + 1:end - 1]
            self.index = end
            return (_double_quoted(raw) if char == '"' else _single_quoted(raw)), True
        if char and char in _UNSUPPORTED_START:
            raise YAMLError("Anchors, aliases and tags are not supported")
        start = self.index
        while self.index < len(self.text):
            char = self.text[self.index]
            following = self.text[self.index + 1:self.index + 2]
            if char in ",[]{}" or char == ":" and (following == "" or following in " \t\n,[]{}"):
                break
            if char == "#" and self.index > start and self.text[self.index - 1] in " \t\n":
                break
            self.index += 1
        lines = [line.strip(" \t") for line in self.text[start:self.index].split("\n")]
        return _fold(lines).strip(" \t"), False

    def value(self, depth):
        self.budget.spend(depth)
        char = self.peek()
        if char == "[":
            self.index += 1
            items = []
            while True:
                if self.peek() == "]":
                    self.index += 1
                    return items
                if self.peek() == "":
                    raise YAMLError("Unterminated flow sequence")
                item = self.entry(depth + 1)
                items.append(item)
                if self.peek() == ",":
                    self.index += 1
                elif self.peek() != "]":
                    raise YAMLError("Expected ',' or ']' in a flow sequence")
        if char == "{":
            self.index += 1
            mapping = {}
            while True:
                if self.peek() == "}":
                    self.index += 1
                    return mapping
                if self.peek() == "":
                    raise YAMLError("Unterminated flow mapping")
                key, value = self.pair(depth + 1)
                mapping[key] = value
                if self.peek() == ",":
                    self.index += 1
                elif self.peek() != "}":
                    raise YAMLError("Expected ',' or '}' in a flow mapping")
        if char in "" or char in "]},:":
            raise YAMLError("Expected a flow value")
        text, quoted = self.scalar()
        return text if quoted else _resolve(text)

    def pair(self, depth):
        if self.peek() in "[{":
            raise YAMLError("Collection keys are not supported")
        if self.peek() == "?":
            raise YAMLError("Complex keys are not supported")
        text, quoted = self.scalar(key=True)
        key = text if quoted else _resolve(text)
        if self.peek() != ":":
            return key, None
        self.index += 1
        if self.peek() in ",}":
            return key, None
        return key, self.value(depth)

    def entry(self, depth):
        """A flow sequence entry: a value, or a single ``key: value`` pair."""
        start = self.index
        value = self.value(depth)
        if self.peek() == ":" and not isinstance(value, (list, dict)):
            self.index = start
            key, item = self.pair(depth)
            return {key: item}
        return value


class _Budget:
    def __init__(self):
        self.nodes = 0

    def spend(self, depth):
        self.nodes += 1
        if self.nodes > MAX_NODES or depth > MAX_DEPTH:
            raise YAMLError("YAML document exceeds its node or nesting limit")


class _Parser:
    def __init__(self, text):
        self.lines = text.split("\n")
        self.position = 0
        self.started = False
        self.budget = _Budget()

    # ---- line access ----

    @staticmethod
    def _indent(line):
        stripped = line.lstrip(" ")
        if stripped.startswith("\t"):
            raise YAMLError("Tabs cannot indent YAML")
        return len(line) - len(stripped)

    def _peek(self):
        """``(indent, content)`` of the next line that holds content, skipping blanks and comments."""
        while self.position < len(self.lines):
            line = self.lines[self.position]
            content = line.strip(" \t")
            if content == "" or content.startswith("#"):
                self.position += 1
                continue
            if self._marker(line) and self.started:
                return None
            return self._indent(line), line[self._indent(line):].rstrip(" \t")
        return None

    @staticmethod
    def _marker(line):
        """Whether the line is a document start or end marker."""
        return line[:3] in ("---", "...") and line[3:4] in ("", " ", "\t")

    # ---- structure ----

    @staticmethod
    def _is_sequence(content):
        return content == "-" or content.startswith("- ")

    @staticmethod
    def _split_key(content):
        """``(key, rest)`` when the line starts a block mapping entry, else None."""
        if content[0] in "\"'":
            end = _quoted_end(content, 0)
            if end < 0:
                return None
            after = content[end:].lstrip(" \t")
            if not after.startswith(":") or after[1:2] not in ("", " ", "\t"):
                return None
            raw = content[1:end - 1]
            return (_double_quoted(raw) if content[0] == '"' else _single_quoted(raw)), after[1:].lstrip(" \t")
        if content[0] in "[{":
            return None
        for index, char in enumerate(content):
            if char == "#" and index and content[index - 1] in " \t":
                return None
            if char == ":" and content[index + 1:index + 2] in ("", " ", "\t"):
                key = content[:index].rstrip(" \t")
                if not key:
                    raise YAMLError("Empty mapping keys are not supported")
                if key[0] in _UNSUPPORTED_START or key == "?" or key.startswith("? "):
                    raise YAMLError("Anchors, aliases, tags and complex keys are not supported")
                return _resolve(key), content[index + 1:].lstrip(" \t")
        return None

    def node(self, parent_indent, depth):
        """The block node on the next content line, which is indented deeper than ``parent_indent``."""
        self.budget.spend(depth)
        indent, content = self._peek()
        if self._is_sequence(content):
            return self.sequence(indent, depth)
        if self._split_key(content) is not None:
            return self.mapping(indent, depth)
        self.position += 1
        return self.value(content, parent_indent, depth)

    def mapping(self, indent, depth):
        result = {}
        while True:
            entry = self._peek()
            if entry is None or entry[0] < indent:
                return result
            if entry[0] > indent:
                raise YAMLError("Unexpected indentation")
            pair = self._split_key(entry[1])
            if pair is None:
                raise YAMLError("Expected a mapping entry")
            self.position += 1
            self.budget.spend(depth)
            key, rest = pair
            result[key] = self.value(rest, indent, depth + 1, in_mapping=True)

    def sequence(self, indent, depth):
        result = []
        while True:
            entry = self._peek()
            if entry is None or entry[0] < indent or entry[0] == indent and not self._is_sequence(entry[1]):
                return result
            if entry[0] > indent:
                raise YAMLError("Unexpected indentation")
            self.budget.spend(depth)
            rest = entry[1][1:]
            if rest.strip(" \t") == "":
                self.position += 1
                following = self._peek()
                result.append(self.node(indent, depth + 1) if following and following[0] > indent else None)
                continue
            # The entry's own content is a node indented at its column.
            self.lines[self.position] = " " * (indent + 1) + rest
            result.append(self.node(indent, depth + 1))

    # ---- values ----

    def value(self, rest, parent_indent, depth, in_mapping=False):
        """The value whose first line holds ``rest``; following lines belong to it while indented deeper."""
        self.budget.spend(depth)
        first = rest[:1]
        if rest == "" or first == "#":
            following = self._peek()
            if following is None:
                return None
            if following[0] > parent_indent:
                return self.node(parent_indent, depth)
            if in_mapping and following[0] == parent_indent and self._is_sequence(following[1]):
                return self.sequence(parent_indent, depth)
            return None
        if first in "|>":
            return self.block_scalar(rest, parent_indent)
        if first in "\"'":
            return self.quoted(rest, parent_indent)
        if first in "[{":
            return self.flow(rest, parent_indent, depth)
        if first in _UNSUPPORTED_START:
            raise YAMLError("Anchors, aliases, tags and directives are not supported")
        if rest == "?" or rest.startswith("? "):
            raise YAMLError("Complex keys are not supported")
        if rest == "-" or rest.startswith("- "):
            raise YAMLError("Sequence entries are not allowed here")
        lines = [_comment_free(rest)]
        if ": " in lines[0] or lines[0].endswith(":"):
            raise YAMLError("Mapping values are not allowed here")
        commented = lines[0] != rest.rstrip(" \t")
        while self.position < len(self.lines):
            line = self.lines[self.position]
            content = line.strip(" \t")
            if content == "":
                lines.append("")
                self.position += 1
                continue
            if self._indent(line) <= parent_indent or content.startswith("#") or self._marker(line):
                break
            if commented:
                raise YAMLError("A plain scalar cannot continue after a comment")
            text = _comment_free(content)
            if ": " in text or text.endswith(":"):
                raise YAMLError("Mapping values are not allowed here")
            commented = text != content
            lines.append(text)
            self.position += 1
        while lines and lines[-1] == "":
            lines.pop()
        return _fold(lines) if len(lines) > 1 else _resolve(lines[0])

    def _collect(self, rest, parent_indent, finished):
        """Join ``rest`` with following deeper lines until ``finished(text)`` gives an end index."""
        text = rest
        while True:
            end = finished(text)
            if end >= 0:
                tail = text[end:].strip(" \t")
                if tail and not (tail.startswith("#") and text[end:end + 1] in " \t"):
                    raise YAMLError("Unexpected text after a scalar or flow collection")
                return text[:end]
            if self.position >= len(self.lines):
                raise YAMLError("Unterminated scalar or flow collection")
            line = self.lines[self.position]
            if self._marker(line):
                raise YAMLError("Unterminated scalar or flow collection")
            if len(text) + len(line) > MAX_CHARS:
                raise YAMLError("YAML scalar exceeds its size limit")
            text += "\n" + line
            self.position += 1

    def quoted(self, rest, parent_indent):
        text = self._collect(rest, parent_indent, lambda value: _quoted_end(value, 0))
        return _double_quoted(text[1:-1]) if text[0] == '"' else _single_quoted(text[1:-1])

    def flow(self, rest, parent_indent, depth):
        def finished(text):
            level, index, token_start = 0, 0, True
            while index < len(text):
                char = text[index]
                # A quote opens a scalar only where a token may start, not inside a plain scalar.
                if char in "\"'" and token_start:
                    index = _quoted_end(text, index)
                    if index < 0:
                        return -1
                    token_start = False
                    continue
                if char == "#" and index and text[index - 1] in " \t\n":
                    newline = text.find("\n", index)
                    if newline < 0:
                        return -1
                    index = newline
                    continue
                if char in "[{":
                    level += 1
                elif char in "]}":
                    level -= 1
                    if level == 0:
                        return index + 1
                if char in "[{,":
                    token_start = True
                elif char == ":" and text[index + 1:index + 2] in ("", " ", "\t", "\n"):
                    token_start = True
                elif char not in " \t\n":
                    token_start = False
                index += 1
            return -1

        text = self._collect(rest, parent_indent, finished)
        parser = _Flow(text, self.budget)
        value = parser.value(depth)
        if parser.peek() != "":
            raise YAMLError("Unexpected text after a flow collection")
        return value

    def block_scalar(self, header, parent_indent):
        folded = header[0] == ">"
        chomping, explicit = None, None
        for char in _comment_free(header[1:]):
            if char in "+-" and chomping is None:
                chomping = char
            elif char in "123456789" and explicit is None:
                explicit = int(char)
            else:
                raise YAMLError("Invalid block scalar header")
        indent = None if explicit is None else max(parent_indent, 0) + explicit
        chunks, breaks, line_break = [], [], ""
        while self.position < len(self.lines):
            line = self.lines[self.position]
            width = len(line) - len(line.lstrip(" "))
            if line.strip(" ") == "" and (indent is None or width < indent):
                breaks.append("\n")
                self.position += 1
                continue
            if indent is None:
                if width <= parent_indent:
                    break
                indent = width
            if width < indent:
                break
            text = line[indent:]
            leading = text[:1] not in (" ", "\t")
            if chunks:
                previous_leading = self._leading
                if folded and line_break == "\n" and previous_leading and leading:
                    chunks.append(" " if not breaks else "")
                else:
                    chunks.append(line_break)
            chunks.extend(breaks)
            chunks.append(text)
            self._leading = leading
            line_break, breaks = "\n", []
            self.position += 1
        if not chunks:
            return "".join(breaks) if chomping == "+" else ""
        if chomping != "-":
            chunks.append(line_break)
        if chomping == "+":
            chunks.extend(breaks)
        return "".join(chunks)

    def document(self):
        entry = self._peek()
        if entry is not None and entry[1].startswith("%"):
            raise YAMLError("YAML directives are not supported")
        if entry is not None and entry[1][:3] == "---" and self._marker(self.lines[self.position]):
            rest = entry[1][3:].strip(" \t")
            if rest and not rest.startswith("#"):
                self.lines[self.position] = " " + rest
            else:
                self.position += 1
        self.started = True
        value = None if self._peek() is None else self.node(-1, 0)
        if self._peek() is not None:
            raise YAMLError("Unexpected content after the document")
        if self.position < len(self.lines) and self.lines[self.position][:3] == "...":
            self.position += 1
        # Only blank lines and comments may follow the document.
        self.started = False
        if self._peek() is not None:
            raise YAMLError("Multiple documents are not supported")
        return value


def safe_load(text):
    """Parse one YAML document from text or UTF-8 bytes."""
    if isinstance(text, (bytes, bytearray)):
        try:
            text = bytes(text).decode("utf-8-sig")
        except UnicodeDecodeError as error:
            raise YAMLError("YAML must be UTF-8 text") from error
    if not isinstance(text, str):
        raise TypeError("YAML source must be text")
    if len(text) > MAX_CHARS:
        raise YAMLError("YAML document exceeds its size limit")
    if text.startswith("\ufeff"):
        text = text[1:]
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    try:
        return _Parser(text).document()
    except RecursionError as error:
        raise YAMLError("YAML document exceeds its nesting limit") from error
