"""``java.lang`` implemented in Python, plus the helpers the sibling providers share.

There is no JVM. These classes copy the documented Java behaviour of the members
they define; every other member raises ``UnsupportedAPI`` (also an
``AttributeError``, so ``hasattr`` keeps answering False as it does on Android).

Deliberate differences from a JVM:
- Java ``int``/``long`` values are Python ``int``; overloads that Java selects by
  static type are selected by value, as Chaquopy does (a value that fits 32 bits
  takes the ``int`` overload).
- ``byte[]`` results are ``ByteArray`` (a ``bytearray``): indexing yields 0..255,
  ``to_bridge`` yields Java's signed values.
- Regular expressions run on Python ``re``: indices count code points, and
  Unicode property classes, class intersections and ``\\G`` are rejected.
- ``String.format`` is locale independent (``Locale.ROOT`` digits and separators).
"""
from __future__ import annotations

import decimal
import math
import os
import re
import struct
import sys
import time
import traceback
import unicodedata
import weakref
import zlib

INT_MIN, INT_MAX = -(2 ** 31), 2 ** 31 - 1
LONG_MIN, LONG_MAX = -(2 ** 63), 2 ** 63 - 1

_names = {}
_missing_type = None
_stores = {}


def register(classes):
    """Record the Java names of a provider's classes for ``java_name``; returns ``classes``."""
    for name, cls in classes.items():
        _names.setdefault(cls, name)
    return classes


def java_name(value):
    """Fully qualified Java name of a local class or of an instance's class."""
    cls = value if isinstance(value, type) else type(value)
    for base in cls.__mro__:
        name = _names.get(base)
        if name is not None:
            return name
    return cls.__qualname__


def unsupported(message):
    from ayu_bridge import UnsupportedAPI
    return UnsupportedAPI(message)


def missing_member(owner, name):
    """The error for a member a local class does not implement."""
    global _missing_type
    if _missing_type is None:
        from ayu_bridge import UnsupportedAPI

        class UnsupportedMember(UnsupportedAPI, AttributeError):
            pass

        _missing_type = UnsupportedMember
    return _missing_type(f"{java_name(owner)}.{name} is not implemented by the Python-local class")


def active_scope():
    """The current plugin scope, or None outside a plugin context."""
    try:
        from ayu_bridge import BridgeError, runtime
    except ImportError:
        return None
    try:
        return runtime.require()
    except BridgeError:
        return None


def scoped_store(kind):
    """Mutable state owned by the current plugin generation (one shared store outside a plugin)."""
    scope = active_scope()
    key = scope.generation if scope is not None else None
    try:
        from ayu_bridge import runtime
        live = {item.generation for item in runtime.scopes.values()}
        for stale in [item for item in _stores if item[0] is not None and item[0] not in live]:
            del _stores[stale]
    except ImportError:
        pass
    return _stores.setdefault((key, kind), {})


def resolve(name, local):
    """The host's facade for ``name`` when the host declares it, else the local class."""
    try:
        from ayu_bridge import BridgeError, runtime
    except ImportError:
        return local
    capabilities = runtime.capabilities
    if not capabilities or name not in capabilities["classes"]:
        return local
    try:
        return runtime.jclass(name)
    except BridgeError:
        return local


class HostFirst:
    """Class attribute naming another Java class; a host declaration of it wins inside a plugin."""

    def __init__(self, name, local):
        self.name, self.local = name, local

    def __get__(self, instance, owner):
        return resolve(self.name, self.local)


class Hidden:
    """A member the Java class does not have although a Python base defines it; reads as missing."""

    def __init__(self, name):
        self.name = name

    def __get__(self, instance, owner):
        raise missing_member(owner, self.name)


class Lazy:
    """Class attribute computed on first access (for values that need a sibling provider)."""

    def __init__(self, factory):
        self.factory, self.ready, self.value = factory, False, None

    def __get__(self, instance, owner):
        if not self.ready:
            self.value, self.ready = self.factory(), True
        return self.value


def i32(value):
    value &= 0xFFFFFFFF
    return value - 0x100000000 if value & 0x80000000 else value


def i64(value):
    value &= 0xFFFFFFFFFFFFFFFF
    return value - 0x10000000000000000 if value & 0x8000000000000000 else value


def signed(value, bits):
    value &= (1 << bits) - 1
    return value - (1 << bits) if value >> (bits - 1) else value


def is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def fits_int(*values):
    return all(INT_MIN <= value <= INT_MAX for value in values)


def units(text):
    """``text`` as UTF-16 code units, one Python character per unit."""
    if text.isascii() or max(text) <= "\uffff":
        return text
    raw = text.encode("utf-16-le", "surrogatepass")
    return "".join(map(chr, struct.unpack("<%dH" % (len(raw) // 2), raw)))


def from_units(text):
    """Recombine surrogate pairs produced by ``units``."""
    if text.isascii() or not any("\ud800" <= char <= "\udfff" for char in text):
        return text
    return text.encode("utf-16-le", "surrogatepass").decode("utf-16-le", "surrogatepass")


def utf16_length(text):
    return len(text) if text.isascii() else len(text) + sum(1 for char in text if char > "\uffff")


def string_hash(text):
    result = 0
    for char in units(text):
        result = (31 * result + ord(char)) & 0xFFFFFFFF
    return i32(result)


def identity_hash(value):
    if value is None:
        return 0
    handle = getattr(value, "_handle", None) if type(value).__name__ == "RemoteObject" else None
    if isinstance(handle, str):
        # Two facades of one host object must hash alike.
        return zlib.crc32(handle.encode("utf-8")) & 0x7FFFFFFF
    address = id(value)
    return ((address >> 4) ^ (address >> 35)) & 0x7FFFFFFF


def double_bits(value):
    return struct.unpack(">q", struct.pack(">d", float("nan") if value != value else value))[0]


def java_hash(value):
    """``Objects.hashCode`` for a Python value standing in for a Java one."""
    if value is None:
        return 0
    if isinstance(value, bool):
        return 1231 if value else 1237
    if isinstance(value, str):
        return string_hash(value)
    if isinstance(value, int):
        return int(value) if INT_MIN <= value <= INT_MAX else i32(value ^ ((value & 0xFFFFFFFFFFFFFFFF) >> 32))
    if isinstance(value, float):
        bits = double_bits(value)
        return i32(bits ^ ((bits & 0xFFFFFFFFFFFFFFFF) >> 32))
    method = getattr(type(value), "hashCode", None)
    if method is not None and method is not Object.hashCode:
        return value.hashCode()
    if isinstance(value, (list, tuple)):
        result = 1
        for item in value:
            result = (31 * result + java_hash(item)) & 0xFFFFFFFF
        return i32(result)
    if isinstance(value, dict):
        return i32(sum(java_hash(key) ^ java_hash(item) for key, item in value.items()))
    if isinstance(value, (set, frozenset)):
        return i32(sum(java_hash(item) for item in value))
    if isinstance(value, (bytes, bytearray)):
        result = 1
        for item in value:
            result = (31 * result + signed(item, 8)) & 0xFFFFFFFF
        return i32(result)
    return identity_hash(value)


def java_equals(left, right):
    """``Objects.equals`` for Python values standing in for Java ones."""
    if left is None or right is None:
        return left is right
    if isinstance(left, bool) != isinstance(right, bool):
        return False
    method = getattr(type(left), "equals", None)
    if method is not None and method is not Object.equals:
        return bool(left.equals(right))
    try:
        return bool(left == right)
    except Exception:
        return left is right


def _digits(sign, digits, exponent):
    digits = "".join(map(str, digits))
    stripped = digits.rstrip("0") or "0"
    exponent += len(digits) - len(stripped)
    point = len(stripped) + exponent
    if -2 <= point <= 7:
        if point <= 0:
            text = "0." + "0" * -point + stripped
        elif point >= len(stripped):
            text = stripped + "0" * (point - len(stripped)) + ".0"
        else:
            text = stripped[:point] + "." + stripped[point:]
    else:
        text = stripped[0] + "." + (stripped[1:] or "0") + "E" + str(point - 1)
    return ("-" if sign else "") + text


def _special(value):
    if value != value:
        return "NaN"
    if value in (math.inf, -math.inf):
        return "Infinity" if value > 0 else "-Infinity"
    if value == 0:
        return "-0.0" if math.copysign(1.0, value) < 0 else "0.0"
    return None


def double_to_string(value):
    """``Double.toString``."""
    value = float(value)
    return _special(value) or _digits(*decimal.Decimal(repr(value)).as_tuple())


def to_float32(value):
    value = float(value)
    try:
        return struct.unpack("f", struct.pack("f", value))[0]
    except OverflowError:
        return math.copysign(math.inf, value)


def float_to_string(value):
    """``Float.toString``: the shortest decimal that identifies the 32-bit value."""
    value = to_float32(value)
    special = _special(value)
    if special:
        return special
    for precision in range(1, 10):
        text = "%.*g" % (precision, value)
        if to_float32(float(text)) == value:
            break
    return _digits(*decimal.Decimal(text).as_tuple())


def jstr(value):
    """Java string conversion (``String.valueOf``)."""
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, str):
        return str.__str__(value)
    if isinstance(value, Float):
        return float_to_string(value)
    if isinstance(value, float):
        return double_to_string(value)
    if isinstance(value, int):
        return int.__repr__(value)
    if isinstance(value, (bytes, bytearray)):
        return "[B@%x" % identity_hash(value)
    if getattr(type(value), "toString", None) is not None:
        text = value.toString()
        return str.__str__(text) if isinstance(text, str) else jstr(text)
    if isinstance(value, (list, tuple)):
        return "[" + ", ".join(jstr(item) for item in value) + "]"
    if isinstance(value, dict):
        return "{" + ", ".join(jstr(key) + "=" + jstr(item) for key, item in value.items()) + "}"
    return str(value)


class ByteArray(bytearray):
    """A Java ``byte[]`` held by Python-local classes."""

    @property
    def length(self):
        return len(self)

    def to_bridge(self):
        return [signed(item, 8) for item in self]


def to_bytes(value):
    """Python ``bytes`` for a Java ``byte[]`` argument (bytes-like, or integers signed or unsigned)."""
    if isinstance(value, (bytes, bytearray, memoryview)):
        return bytes(value)
    if value is None:
        raise NullPointerException("byte array is null")
    if isinstance(value, str) or type(value).__name__ == "RemoteObject":
        raise unsupported("Expected a Python-local byte array")
    try:
        return bytes(item & 0xFF for item in value)
    except TypeError as error:
        raise unsupported("Expected a byte array") from error


def fill_bytes(target, offset, data):
    """Copy ``data`` into a caller's Java ``byte[]`` buffer."""
    if isinstance(target, (bytearray, memoryview)):
        target[offset:offset + len(data)] = data
    elif isinstance(target, list):
        target[offset:offset + len(data)] = [signed(item, 8) for item in data]
    elif type(target).__name__ == "RemoteObject":
        raise unsupported("A host-owned array cannot be filled by a Python-local stream; use a bytearray")
    else:
        raise unsupported("Expected a mutable byte array (bytearray or list)")


def check_range(offset, count, length):
    if offset < 0 or count < 0 or offset + count > length:
        raise IndexOutOfBoundsException(f"Range [{offset}, {offset} + {count}) out of bounds for length {length}")


# ``Class`` members that find fields and methods (``java_reflect``); the first four take the member's name.
REFLECTION_LOOKUPS = frozenset({"getDeclaredField", "getField", "getDeclaredMethod", "getMethod"})
REFLECTION = REFLECTION_LOOKUPS | {"getDeclaredFields", "getFields", "getDeclaredMethods", "getMethods"}


class JavaMeta(type):
    def __getattr__(cls, name):
        if name.startswith("_"):
            raise AttributeError(name)
        raise missing_member(cls, name)


class _GetClass:
    def __get__(self, instance, owner):
        target = owner if instance is None else type(instance)
        return lambda: Class._of(target)


class Object(metaclass=JavaMeta):
    """``java.lang.Object`` and the base of every Python-local Java class."""

    def __getattr__(self, name):
        if name.startswith("_"):
            raise AttributeError(name)
        raise missing_member(type(self), name)

    def equals(self, other):
        try:
            return bool(self == other)
        except Exception:
            return self is other

    def hashCode(self):
        return identity_hash(self)

    def toString(self):
        return "%s@%x" % (java_name(self), self.hashCode())

    def __str__(self):
        return self.toString()

    getClass = _GetClass()


class Iterable(Object):
    def iterator(self):
        raise missing_member(type(self), "iterator")

    def forEach(self, action):
        for item in self:
            _call(action, "accept", item)


class Comparable(Object):
    def compareTo(self, other):
        raise missing_member(type(self), "compareTo")


class Cloneable(Object):
    pass


class AutoCloseable(Object):
    def close(self):
        raise missing_member(type(self), "close")

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False


def _call(function, method, *args):
    """Invoke a Java functional-interface argument: a Python callable or an object with ``method``."""
    if function is None:
        raise NullPointerException()
    target = getattr(function, method, None) if not callable(function) or hasattr(type(function), method) else None
    return target(*args) if target is not None else function(*args)


call = _call


def compare(left, right):
    """Natural ordering used by sorted collections: ``compareTo`` or Python ordering."""
    method = getattr(type(left), "compareTo", None)
    if method is not None:
        return left.compareTo(right)
    if left is None or right is None:
        raise NullPointerException()
    try:
        return -1 if left < right else 1 if left > right else 0
    except TypeError as error:
        raise ClassCastException(f"{type(left).__name__} cannot be compared to {type(right).__name__}") from error


class StackTraceElement(Object):
    def __init__(self, declaringClass, methodName, fileName, lineNumber):
        self._class, self._method, self._file, self._line = declaringClass, methodName, fileName, lineNumber

    def getClassName(self):
        return self._class

    def getMethodName(self):
        return self._method

    def getFileName(self):
        return self._file

    def getLineNumber(self):
        return self._line

    def isNativeMethod(self):
        return False

    def toString(self):
        return f"{self._class}.{self._method}({self._file}:{self._line})"

    def __eq__(self, other):
        return isinstance(other, StackTraceElement) and self.toString() == other.toString()

    def __hash__(self):
        return hash(self.toString())


def _frames(frame):
    result = []
    while frame is not None and len(result) < 1024:
        code = frame.f_code
        result.append(StackTraceElement(frame.f_globals.get("__name__", ""), code.co_name,
                                        os.path.basename(code.co_filename), frame.f_lineno))
        frame = frame.f_back
    return result


class Throwable(Object, Exception):
    """Java throwables are Python exceptions; the stack trace is the Python one."""

    def __init__(self, *args):
        message, cause = None, None
        if len(args) == 1:
            if isinstance(args[0], BaseException):
                cause = args[0]
                message = cause.toString() if isinstance(cause, Throwable) else jstr(cause)
            else:
                message = args[0]
        elif len(args) == 2:
            message, cause = args
        elif args:
            raise TypeError(f"{java_name(self)} takes at most 2 arguments")
        if message is not None and not isinstance(message, str):
            raise TypeError("Throwable message must be a string")
        if cause is not None and not isinstance(cause, BaseException):
            raise TypeError("Throwable cause must be an exception")
        Exception.__init__(self, *(() if message is None else (message,)))
        self._message = message
        self._suppressed = []
        self._trace = None
        if cause is not None:
            self.__cause__ = cause

    def getMessage(self):
        return self._message

    def getLocalizedMessage(self):
        return self.getMessage()

    def getCause(self):
        return self.__cause__

    def initCause(self, cause):
        if self.__cause__ is not None:
            raise IllegalStateException("Can't overwrite cause")
        if cause is self:
            raise IllegalArgumentException("Self-causation not permitted")
        self.__cause__ = cause
        return self

    def addSuppressed(self, exception):
        if exception is None:
            raise NullPointerException("Cannot suppress a null exception.")
        if exception is self:
            raise IllegalArgumentException("Self-suppression not permitted")
        self._suppressed.append(exception)

    def getSuppressed(self):
        return list(self._suppressed)

    def fillInStackTrace(self):
        self._trace = _frames(sys._getframe(1))
        return self

    def getStackTrace(self):
        if self._trace is not None:
            return list(self._trace)
        if self.__traceback__ is not None:
            return [StackTraceElement(frame.f_globals.get("__name__", ""), frame.f_code.co_name,
                                      os.path.basename(frame.f_code.co_filename), line)
                    for frame, line in reversed(list(traceback.walk_tb(self.__traceback__)))]
        return _frames(sys._getframe(1))

    def setStackTrace(self, trace):
        self._trace = list(trace)

    def printStackTrace(self, target=None):
        text = "".join(traceback.format_exception(type(self), self, self.__traceback__))
        if target is None:
            sys.stderr.write(text)
        elif hasattr(target, "print"):
            getattr(target, "print")(text)
        else:
            target.write(text)

    def toString(self):
        message = self.getLocalizedMessage()
        return java_name(self) + (": " + message if message is not None else "")


class Exception_(Throwable):
    pass


Exception_.__name__ = Exception_.__qualname__ = "Exception"


class Error(Throwable):
    pass


def _throwable(name, *bases):
    return JavaMeta(name, bases, {"__module__": __name__, "__qualname__": name})


RuntimeException = _throwable("RuntimeException", Exception_)
# These are also the Python exception a caller of the equivalent Python operation expects,
# so ``except ValueError`` around ``Integer.parseInt`` or ``except IndexError`` around
# ``List.get`` keeps working in plugins that mix both styles.
IllegalArgumentException = _throwable("IllegalArgumentException", RuntimeException, ValueError)
IllegalStateException = _throwable("IllegalStateException", RuntimeException, RuntimeError)
NumberFormatException = _throwable("NumberFormatException", IllegalArgumentException)
IllegalThreadStateException = _throwable("IllegalThreadStateException", IllegalArgumentException, RuntimeError)
IllegalMonitorStateException = _throwable("IllegalMonitorStateException", RuntimeException, RuntimeError)
NullPointerException = _throwable("NullPointerException", RuntimeException, TypeError)
IndexOutOfBoundsException = _throwable("IndexOutOfBoundsException", RuntimeException, IndexError)
ArrayIndexOutOfBoundsException = _throwable("ArrayIndexOutOfBoundsException", IndexOutOfBoundsException)
StringIndexOutOfBoundsException = _throwable("StringIndexOutOfBoundsException", IndexOutOfBoundsException)
UnsupportedOperationException = _throwable("UnsupportedOperationException", RuntimeException)
ArithmeticException = _throwable("ArithmeticException", RuntimeException, ArithmeticError)
ClassCastException = _throwable("ClassCastException", RuntimeException, TypeError)
NegativeArraySizeException = _throwable("NegativeArraySizeException", RuntimeException)
ArrayStoreException = _throwable("ArrayStoreException", RuntimeException)
SecurityException = _throwable("SecurityException", RuntimeException)
ReflectiveOperationException = _throwable("ReflectiveOperationException", Exception_)
ClassNotFoundException = _throwable("ClassNotFoundException", ReflectiveOperationException)
NoSuchFieldException = _throwable("NoSuchFieldException", ReflectiveOperationException)
NoSuchMethodException = _throwable("NoSuchMethodException", ReflectiveOperationException)
IllegalAccessException = _throwable("IllegalAccessException", ReflectiveOperationException)
InstantiationException = _throwable("InstantiationException", ReflectiveOperationException)
CloneNotSupportedException = _throwable("CloneNotSupportedException", Exception_)
AssertionError_ = _throwable("AssertionError", Error)
LinkageError = _throwable("LinkageError", Error)
NoClassDefFoundError = _throwable("NoClassDefFoundError", LinkageError)
UnsatisfiedLinkError = _throwable("UnsatisfiedLinkError", LinkageError)
VirtualMachineError = _throwable("VirtualMachineError", Error)
OutOfMemoryError = _throwable("OutOfMemoryError", VirtualMachineError)
StackOverflowError = _throwable("StackOverflowError", VirtualMachineError)
PatternSyntaxException = _throwable("PatternSyntaxException", IllegalArgumentException)
IllegalFormatException = _throwable("IllegalFormatException", IllegalArgumentException)
MissingFormatArgumentException = _throwable("MissingFormatArgumentException", IllegalFormatException)
UnknownFormatConversionException = _throwable("UnknownFormatConversionException", IllegalFormatException)
IllegalFormatConversionException = _throwable("IllegalFormatConversionException", IllegalFormatException)


# --- regular expressions -------------------------------------------------------------------

UNIX_LINES, CASE_INSENSITIVE, COMMENTS, MULTILINE, LITERAL, DOTALL, UNICODE_CASE, CANON_EQ = 1, 2, 4, 8, 16, 32, 64, 128
UNICODE_CHARACTER_CLASS = 256
_POSIX = {
    "Lower": "a-z", "Upper": "A-Z", "ASCII": "\\x00-\\x7f", "Alpha": "a-zA-Z", "Digit": "0-9",
    "Alnum": "a-zA-Z0-9", "Punct": "!-/:-@\\[-`{-~", "Graph": "!-~", "Print": "\\x20-~", "Blank": " \\t",
    "Cntrl": "\\x00-\\x1f\\x7f", "XDigit": "0-9a-fA-F", "Space": " \\t\\n\\x0b\\f\\r",
}
_HORIZONTAL = " \\t\\xa0\\u1680\\u180e\\u2000-\\u200a\\u202f\\u205f\\u3000"
_VERTICAL = "\\n\\x0b\\f\\r\\x85\\u2028\\u2029"
_INLINE = re.compile(r"\(\?([a-zA-Z]*)(?:-([a-zA-Z]*))?([:)])")


def _syntax(message, pattern):
    return PatternSyntaxException(f"{message} near index 0\n{pattern}")


def _literal(char, in_class):
    if in_class:
        return "\\" + char if char in "\\]^-[" else char
    return re.escape(char)


def translate_regex(pattern, flags=0):
    """Translate Java regex syntax and flags to a compiled Python pattern."""
    if not isinstance(pattern, str):
        raise NullPointerException("regex is null")
    if flags & ~0x1FF:
        raise IllegalArgumentException("Unknown flag 0x%x" % flags)
    if flags & CANON_EQ:
        raise unsupported("Pattern.CANON_EQ is not supported")
    options = 0
    if flags & CASE_INSENSITIVE:
        options |= re.IGNORECASE
    if flags & MULTILINE:
        options |= re.MULTILINE
    if flags & DOTALL:
        options |= re.DOTALL
    if flags & COMMENTS:
        options |= re.VERBOSE
    inline = "".join(match.group(1) + (match.group(2) or "") for match in _INLINE.finditer(pattern))
    if not flags & (UNICODE_CASE | UNICODE_CHARACTER_CLASS) and "u" not in inline and "U" not in inline:
        # Java's predefined classes and case folding are ASCII-only unless asked otherwise.
        options |= re.ASCII
    if flags & LITERAL:
        source = re.escape(pattern)
    else:
        dot = None if flags & (DOTALL | UNIX_LINES) or "s" in inline or "d" in inline else "[^" + _VERTICAL + "]"
        source = _translate(pattern, dot)
    try:
        return re.compile(source, options)
    except re.error as error:
        raise PatternSyntaxException(f"{error.msg} near index {error.pos or 0}\n{pattern}") from None
    except RecursionError:
        raise PatternSyntaxException(f"Pattern too complex near index 0\n{pattern}") from None


def _translate(pattern, dot):
    out, index, size = [], 0, len(pattern)
    in_class = False
    # One entry per open group: the inline flag groups that must be closed with it.
    groups = [[]]
    while index < size:
        char = pattern[index]
        if char == "\\":
            if index + 1 >= size:
                raise _syntax("Unexpected internal error", pattern)
            following = pattern[index + 1]
            index += 2
            if following == "Q":
                end = pattern.find("\\E", index)
                literal = pattern[index:] if end < 0 else pattern[index:end]
                index = size if end < 0 else end + 2
                out.append("".join(_literal(item, in_class) for item in literal))
            elif following in "pP":
                if pattern[index:index + 1] == "{":
                    end = pattern.find("}", index)
                    if end < 0:
                        raise _syntax("Unclosed character family", pattern)
                    name, index = pattern[index + 1:end], end + 1
                else:
                    name, index = pattern[index:index + 1], index + 1
                body = _POSIX.get(name)
                if body is None:
                    raise unsupported(f"Regex character property \\p{{{name}}} is not supported")
                if in_class:
                    if following == "P":
                        raise unsupported("A negated property inside a character class is not supported")
                    out.append(body)
                else:
                    out.append(("[^" if following == "P" else "[") + body + "]")
            elif following in "hHvV":
                body = _HORIZONTAL if following in "hH" else _VERTICAL
                if in_class:
                    if following in "HV":
                        raise unsupported("A negated whitespace class inside a character class is not supported")
                    out.append(body)
                else:
                    out.append(("[^" if following in "HV" else "[") + body + "]")
            elif following == "R" and not in_class:
                out.append("(?:\\r\\n|[" + _VERTICAL + "])")
            elif following == "z" and not in_class:
                out.append("\\Z")
            elif following == "Z" and not in_class:
                out.append("(?=\\n?\\Z)")
            elif following == "e":
                out.append("\\x1b")
            elif following == "c" and index < size:
                out.append(_literal(chr(ord(pattern[index]) ^ 64), in_class))
                index += 1
            elif following == "x" and pattern[index:index + 1] == "{":
                end = pattern.find("}", index)
                try:
                    out.append(_literal(chr(int(pattern[index + 1:end], 16)), in_class))
                except (ValueError, OverflowError):
                    raise _syntax("Illegal hexadecimal escape sequence", pattern) from None
                index = end + 1
            elif following == "0":
                match = re.match(r"[0-3][0-7]{2}|[0-7]{1,2}", pattern[index:])
                if match is None:
                    raise _syntax("Illegal octal escape sequence", pattern)
                out.append(_literal(chr(int(match.group(), 8)), in_class))
                index += match.end()
            elif following == "k" and pattern[index:index + 1] == "<":
                end = pattern.find(">", index)
                if end < 0:
                    raise _syntax("named capturing group is missing trailing '>'", pattern)
                out.append("(?P=" + pattern[index + 1:end] + ")")
                index = end + 1
            elif following in "GXN" or following == "b" and pattern[index:index + 1] == "{":
                raise unsupported(f"Regex construct \\{following} is not supported")
            else:
                out.append("\\" + following)
            continue
        if in_class:
            if char == "[":
                raise unsupported("Nested regex character classes are not supported")
            if char == "&" and pattern[index + 1:index + 2] == "&":
                raise unsupported("Regex character class intersection is not supported")
            if char == "]":
                in_class = False
            out.append(char)
            index += 1
            continue
        if char == "[":
            in_class = True
            out.append(char)
            index += 1
            if pattern[index:index + 1] == "^":
                out.append("^")
                index += 1
            if pattern[index:index + 1] == "]":
                out.append("\\]")
                index += 1
            continue
        if char == "(":
            match = _INLINE.match(pattern, index)
            if match is not None:
                on, off, end = match.group(1), match.group(2) or "", match.group(3)
                if set(on + off) - set("idmsuxU"):
                    raise _syntax("Unknown inline modifier", pattern)
                if "d" in on + off:
                    raise unsupported("The regex UNIX_LINES inline flag is not supported")
                on, off = on.replace("u", "").replace("U", ""), off.replace("u", "").replace("U", "")
                opener = "(?" + on + ("-" + off if off else "") + ":" if on or off else "(?:"
                index = match.end()
                out.append(opener)
                if end == ")":
                    # Java applies a bare flag group to the rest of the enclosing group.
                    groups[-1].append(opener)
                else:
                    groups.append([])
                continue
            if pattern.startswith("(?<", index) and pattern[index + 3:index + 4] not in ("=", "!"):
                out.append("(?P<")
                index += 3
            else:
                out.append("(")
                index += 1
            groups.append([])
            continue
        if char == ")":
            if len(groups) == 1:
                raise _syntax("Unmatched closing ')'", pattern)
            out.append(")" * len(groups.pop()) + ")")
            index += 1
            continue
        if char == "|" and groups[-1]:
            out.append(")" * len(groups[-1]) + "|" + "".join(groups[-1]))
            index += 1
            continue
        out.append(dot if char == "." and dot else char)
        index += 1
    if in_class:
        raise _syntax("Unclosed character class", pattern)
    if len(groups) != 1:
        raise _syntax("Unclosed group", pattern)
    out.append(")" * len(groups[0]))
    return "".join(out)


def expand_replacement(match, replacement):
    """Java ``Matcher`` replacement-string expansion for one match."""
    out, index, size = [], 0, len(replacement)
    while index < size:
        char = replacement[index]
        if char == "\\":
            if index + 1 >= size:
                raise IllegalArgumentException("character to be escaped is missing")
            out.append(replacement[index + 1])
            index += 2
        elif char == "$":
            index += 1
            if index >= size:
                raise IllegalArgumentException("Illegal group reference: group index is missing")
            if replacement[index] == "{":
                end = replacement.find("}", index)
                if end < 0:
                    raise IllegalArgumentException("named capturing group is missing trailing '}'")
                name = replacement[index + 1:end]
                if name not in match.re.groupindex:
                    raise IllegalArgumentException("No group with name {" + name + "}")
                out.append(match.group(name) or "")
                index = end + 1
            elif "0" <= replacement[index] <= "9":
                number = int(replacement[index])
                index += 1
                if number > match.re.groups:
                    raise IndexOutOfBoundsException("No group " + str(number))
                while index < size and "0" <= replacement[index] <= "9":
                    following = number * 10 + int(replacement[index])
                    if following > match.re.groups:
                        break
                    number, index = following, index + 1
                out.append(match.group(number) or "")
            else:
                raise IllegalArgumentException("Illegal group reference")
        else:
            out.append(char)
            index += 1
    return "".join(out)


def regex_split(compiled, text, limit=0):
    """``Pattern.split`` / ``String.split``."""
    result, index = [], 0
    for match in compiled.finditer(text):
        if limit > 0 and len(result) == limit - 1:
            break
        if index == 0 and match.start() == 0 and match.end() == 0:
            continue
        result.append(text[index:match.start()])
        index = match.end()
    if index == 0:
        return [text]
    result.append(text[index:])
    if limit == 0:
        while result and result[-1] == "":
            result.pop()
    return result


# --- java.util.Formatter -------------------------------------------------------------------

_SPECIFIER = re.compile(r"%(\d+\$|<)?([-#+ 0,(]*)(\d+)?(\.\d+)?([tT])?(.)", re.DOTALL)


def _group(digits):
    head = len(digits) % 3 or 3
    return digits[:head] + "".join("," + digits[index:index + 3] for index in range(head, len(digits), 3))


def _fixed(value, precision):
    quantum = decimal.Decimal(1).scaleb(-precision)
    with decimal.localcontext() as context:
        context.prec = 400
        return format(decimal.Decimal(repr(abs(value))).quantize(quantum, rounding=decimal.ROUND_HALF_UP), "f")


def _scientific(value, precision):
    number = decimal.Decimal(repr(abs(value)))
    if number == 0:
        return "0" + ("." + "0" * precision if precision else "") + "e+00"
    with decimal.localcontext() as context:
        context.prec = precision + 1
        context.rounding = decimal.ROUND_HALF_UP
        rounded = +number
    exponent = rounded.adjusted()
    digits = "".join(map(str, rounded.as_tuple().digits)).ljust(precision + 1, "0")
    return digits[0] + ("." + digits[1:precision + 1] if precision else "") + "e%s%02d" % (
        "-" if exponent < 0 else "+", abs(exponent))


def _conversion_error(conversion, value):
    kind = {bool: "java.lang.Boolean", str: "java.lang.String", float: "java.lang.Double",
            int: "java.lang.Integer"}.get(type(value), java_name(value))
    return IllegalFormatConversionException(f"{conversion} != {kind}")


def java_format(template, args):
    """``String.format`` with ``Locale.ROOT`` conventions; date/time and ``%a`` conversions reject."""
    if not isinstance(template, str):
        raise NullPointerException("format is null")
    out, position, ordinary, previous = [], 0, 0, -1
    for match in _SPECIFIER.finditer(template):
        if "%" in template[position:match.start()]:
            raise UnknownFormatConversionException("Conversion = '%'")
        out.append(template[position:match.start()])
        position = match.end()
        reference, flags, width, precision, time_prefix, conversion = match.groups()
        width = int(width) if width else None
        precision = int(precision[1:]) if precision else None
        if time_prefix:
            raise unsupported("Date/time format conversions are not supported")
        if conversion == "%" or conversion == "n":
            text = "%" if conversion == "%" else "\n"
            out.append(text.rjust(width) if width and "-" not in flags else text.ljust(width or 0))
            continue
        if conversion not in "bBhHsScCdoxXeEfgG":
            if conversion in "aA":
                raise unsupported("Hexadecimal floating-point formatting is not supported")
            raise UnknownFormatConversionException(f"Conversion = '{conversion}'")
        if reference == "<":
            index = previous
        elif reference:
            index = int(reference[:-1]) - 1
        else:
            index, ordinary = ordinary, ordinary + 1
        if index < 0 or index >= len(args):
            raise MissingFormatArgumentException(f"Format specifier '{match.group()}'")
        previous = index
        value = args[index]
        lower = conversion.lower()
        sign = ""
        if lower == "b":
            text = "false" if value is None else jstr(value) if isinstance(value, (bool, Boolean)) else "true"
        elif lower == "h":
            text = "null" if value is None else "%x" % (java_hash(value) & 0xFFFFFFFF)
        elif lower == "s":
            text = jstr(value)
        elif lower == "c":
            if value is None:
                text = "null"
            elif isinstance(value, str) and len(value) == 1:
                text = value
            elif is_int(value) and 0 <= value <= 0x10FFFF:
                text = chr(value)
            else:
                raise _conversion_error(conversion, value)
        elif lower in "dox":
            if value is None:
                text = "null"
            elif not is_int(value):
                raise _conversion_error(conversion, value)
            elif lower == "d":
                text = str(abs(value))
                if "," in flags:
                    text = _group(text)
                sign = "-" if value < 0 else "+" if "+" in flags else " " if " " in flags else ""
                if value < 0 and "(" in flags:
                    sign, text = "", "(" + text + ")"
            else:
                if value < 0:
                    value &= 0xFFFFFFFF if value >= INT_MIN else 0xFFFFFFFFFFFFFFFF
                text = format(value, "o" if lower == "o" else "x")
                if "#" in flags:
                    text = ("0" if lower == "o" else "0x") + text
        else:
            if value is None:
                text = "null"
            elif not isinstance(value, (float, decimal.Decimal)) or isinstance(value, bool):
                raise _conversion_error(conversion, value)
            else:
                value = float(value)
                sign = "-" if math.copysign(1.0, value) < 0 and value == value else \
                    "+" if "+" in flags else " " if " " in flags else ""
                if value != value:
                    text, sign = "NaN", ""
                elif value in (math.inf, -math.inf):
                    text = "Infinity"
                else:
                    places = 6 if precision is None else precision
                    if lower == "f":
                        text = _fixed(value, places)
                    elif lower == "e":
                        text = _scientific(value, places)
                    else:
                        places = places or 1
                        rounded = abs(float(_scientific(value, places - 1)))
                        if rounded != 0 and (rounded < 1e-4 or rounded >= 10 ** places):
                            text = _scientific(value, places - 1)
                        else:
                            exponent = math.floor(math.log10(rounded)) if rounded else 0
                            text = _fixed(value, max(places - exponent - 1, 0))
                    if "," in flags and lower != "e":
                        whole, dot, fraction = text.partition(".")
                        text = _group(whole) + dot + fraction
                    if "(" in flags and sign == "-":
                        sign, text = "", "(" + text + ")"
        if precision is not None and lower in "bhs":
            text = text[:precision]
        if conversion.isupper():
            text = text.upper()
        if width is not None and len(sign + text) < width:
            if "-" in flags:
                text = (sign + text).ljust(width)
            elif "0" in flags and lower in "doxefg" and text not in ("null", "NaN", "Infinity", "NAN", "INFINITY"):
                text = sign + text.rjust(width - len(sign), "0")
            else:
                text = (sign + text).rjust(width)
        else:
            text = sign + text
        out.append(text)
    if "%" in template[position:]:
        raise UnknownFormatConversionException("Conversion = '%'")
    out.append(template[position:])
    return "".join(out)


# --- java.lang.Class -----------------------------------------------------------------------

_PRIMITIVES = ("boolean", "byte", "char", "short", "int", "long", "float", "double", "void")


class Class(Object):
    """Class metadata for Python-local classes, host facades and primitives.

    Fields and methods are the ones ``java_reflect`` models; constructors are not reflected.
    """
    _cache = {}

    def __init__(self, *args):
        raise unsupported("java.lang.Class cannot be constructed")

    @classmethod
    def _of(cls, target):
        # Only bundled classes and primitives are cached: a plugin's own subclass must not
        # be kept alive past its generation.
        shared = isinstance(target, str) or isinstance(target, type) and target in _names
        found = cls._cache.get(target) if shared else None
        if found is None:
            found = object.__new__(cls)
            found._target = target
            if shared:
                cls._cache[target] = found
        return found

    @staticmethod
    def forName(name, initialize=True, loader=None):
        if not isinstance(name, str):
            raise NullPointerException("name is null")
        if name in _PRIMITIVES:
            raise ClassNotFoundException(name)
        from ayu_bridge import BridgeError, runtime
        try:
            target = runtime.jclass(name)
        except BridgeError as error:
            if error.code != "UNSUPPORTED_API":
                raise
            raise ClassNotFoundException(name) from error
        return target.getClass() if isinstance(target, type) and issubclass(target, Object) else Class._of(target)

    def _host_name(self):
        return getattr(self._target, "_name", None) if not isinstance(self._target, (type, str)) else None

    def getName(self):
        if isinstance(self._target, str):
            return self._target
        return self._host_name() or java_name(self._target)

    def getTypeName(self):
        return self.getName().replace("$", ".")

    def getCanonicalName(self):
        return self.getName().replace("$", ".")

    def getSimpleName(self):
        return re.split(r"[.$]", self.getName())[-1]

    def getPackageName(self):
        return self.getName().rpartition(".")[0]

    def isPrimitive(self):
        return isinstance(self._target, str)

    def isArray(self):
        return False

    def isEnum(self):
        return isinstance(self._target, type) and issubclass(self._target, Enum) and self._target is not Enum

    def isInstance(self, value):
        if isinstance(self._target, type):
            return isinstance(value, self._target)
        if isinstance(self._target, str) or value is None:
            return False
        actual = getattr(value, "_class_name", None) if type(value).__name__ == "RemoteObject" else None
        if actual is None:
            return False
        if actual == self._host_name():
            return True
        raise unsupported("The host class hierarchy is not known to Python-local java.lang.Class")

    def isAssignableFrom(self, other):
        if not isinstance(other, Class):
            raise NullPointerException()
        if isinstance(self._target, type) and isinstance(other._target, type):
            return issubclass(other._target, self._target)
        if self.getName() == other.getName():
            return True
        if isinstance(self._target, (type, str)) and isinstance(other._target, (type, str)):
            return False
        raise unsupported("The host class hierarchy is not known to Python-local java.lang.Class")

    def cast(self, value):
        if value is None or self.isInstance(value):
            return value
        raise ClassCastException(f"Cannot cast {type(value).__name__} to {self.getName()}")

    def getSuperclass(self):
        if not isinstance(self._target, type):
            if isinstance(self._target, str):
                return None
            raise unsupported("The host class hierarchy is not known to Python-local java.lang.Class")
        if self._target is Object:
            return None
        for base in self._target.__mro__[1:]:
            if base in _names:
                return Class._of(base)
        return Class._of(Object)

    def newInstance(self):
        if isinstance(self._target, str):
            raise InstantiationException(self._target)
        return self._target()

    def _reflect(self, member, arguments):
        target = self._target
        if isinstance(target, type):
            from . import java_reflect
            return java_reflect.reflect(target, member, arguments)
        if not isinstance(target, str):
            # A host class: the host's own reflection, and what the SDK serves on its facade.
            return getattr(target, member)(*arguments)
        if member not in REFLECTION_LOOKUPS:
            return []
        if member.endswith("Field"):
            raise NoSuchFieldException(*arguments[:1])
        raise NoSuchMethodException(target + "." + jstr(arguments[0] if arguments else None) + " []")

    def getDeclaredField(self, name):
        return self._reflect("getDeclaredField", (name,))

    def getField(self, name):
        return self._reflect("getField", (name,))

    def getDeclaredFields(self):
        return self._reflect("getDeclaredFields", ())

    def getFields(self):
        return self._reflect("getFields", ())

    def getDeclaredMethod(self, name, *parameterTypes):
        return self._reflect("getDeclaredMethod", (name,) + parameterTypes)

    def getMethod(self, name, *parameterTypes):
        return self._reflect("getMethod", (name,) + parameterTypes)

    def getDeclaredMethods(self):
        return self._reflect("getDeclaredMethods", ())

    def getMethods(self):
        return self._reflect("getMethods", ())

    def getClassLoader(self):
        return ClassLoader.getSystemClassLoader()

    def desiredAssertionStatus(self):
        return False

    def hashCode(self):
        return string_hash(self.getName())

    def __eq__(self, other):
        if not isinstance(other, Class):
            return False
        if isinstance(self._target, type) and isinstance(other._target, type):
            return self._target is other._target
        return self.getName() == other.getName()

    def __hash__(self):
        return hash(self.getName())

    def toString(self):
        return ("" if self.isPrimitive() else "class ") + self.getName()


def _primitive(name):
    return HostFirst(name, Class._of(name))


class ClassLoader(Object):
    """Resolves names through the bridge class registry; nothing is loaded from bytes or files."""
    _system = None

    def __init__(self, *args):
        raise unsupported("Custom class loaders are not supported: there is no JVM to define classes in")

    @staticmethod
    def getSystemClassLoader():
        if ClassLoader._system is None:
            ClassLoader._system = object.__new__(ClassLoader)
        return ClassLoader._system

    def loadClass(self, name, resolve=False):
        return Class.forName(name)

    def getParent(self):
        return None


class Enum(Comparable):
    """Base of Python-local Java enums; ``enum_constants`` installs the constants."""
    _constants = ()

    def __init__(self, name, ordinal):
        self._name, self._ordinal = name, ordinal

    def name(self):
        return self._name

    def ordinal(self):
        return self._ordinal

    def toString(self):
        return self._name

    def __repr__(self):
        return java_name(self) + "." + self._name

    def compareTo(self, other):
        if type(other) is not type(self):
            raise ClassCastException("Cannot compare constants of different enums")
        return self._ordinal - other._ordinal

    def hashCode(self):
        return identity_hash(self)

    def getDeclaringClass(self):
        return Class._of(type(self))

    @classmethod
    def values(cls):
        return list(cls._constants)

    @classmethod
    def valueOf(cls, name):
        if name is None:
            raise NullPointerException("Name is null")
        for constant in cls._constants:
            if constant._name == name:
                return constant
        raise IllegalArgumentException(f"No enum constant {java_name(cls)}.{name}")


def enum_constants(cls, *names):
    """Create the constants of a Python-local Java enum class in declaration order."""
    constants = []
    for ordinal, name in enumerate(names):
        constant = cls(name, ordinal)
        setattr(cls, name, constant)
        constants.append(constant)
    cls._constants = tuple(constants)
    return cls


# --- strings -------------------------------------------------------------------------------

class _CharSequenceMeta(JavaMeta):
    def __instancecheck__(cls, instance):
        # Chaquopy hands Java strings to Python as ``str``.
        return type.__instancecheck__(cls, instance) or cls is CharSequence and isinstance(instance, str)


class CharSequence(Object, metaclass=_CharSequenceMeta):
    def length(self):
        return utf16_length(self.toString())

    def charAt(self, index):
        text = units(self.toString())
        if not 0 <= index < len(text):
            raise StringIndexOutOfBoundsException(f"index {index}, length {len(text)}")
        return text[index]

    def subSequence(self, start, end):
        text = units(self.toString())
        if start < 0 or end > len(text) or start > end:
            raise StringIndexOutOfBoundsException(f"begin {start}, end {end}, length {len(text)}")
        return from_units(text[start:end])

    def isEmpty(self):
        return self.length() == 0

    def __len__(self):
        return len(self.toString())


def _text(value, what="string"):
    if value is None:
        raise NullPointerException(what + " is null")
    if isinstance(value, str):
        return str.__str__(value)
    if isinstance(value, CharSequence):
        return value.toString()
    raise TypeError(f"Expected a {what}, got {type(value).__name__}")


def _charset_name(charset):
    if charset is None:
        return "utf-8"
    name = charset if isinstance(charset, str) else charset.name() if hasattr(charset, "name") else None
    if not isinstance(name, str):
        raise TypeError("Expected a charset or charset name")
    import codecs
    try:
        return codecs.lookup("utf-16-be" if name.upper() in ("UTF-16", "UTF16") else name).name
    except LookupError:
        from . import java_io
        raise java_io.UnsupportedEncodingException(name) from None


charset_name = _charset_name


def _is_utf16(charset):
    name = charset if isinstance(charset, str) or charset is None else charset.name()
    return name is not None and name.upper() in ("UTF-16", "UTF16")


def decode_bytes(data, charset=None):
    """Java decoding: malformed input is replaced, and UTF-16 honours a byte order mark."""
    data, name = to_bytes(data), _charset_name(charset)
    if _is_utf16(charset):
        if data[:2] == b"\xff\xfe":
            return data[2:].decode("utf-16-le", "replace")
        if data[:2] == b"\xfe\xff":
            data = data[2:]
    return data.decode(name, "replace")


def encode_text(text, charset=None):
    data = text.encode(_charset_name(charset), "replace")
    return ByteArray(b"\xfe\xff" + data if _is_utf16(charset) else data)


class String(str, CharSequence):
    """``java.lang.String`` as a ``str`` subclass; indices are UTF-16 code units."""

    def __new__(cls, *args):
        if not args:
            return str.__new__(cls, "")
        first = args[0]
        if isinstance(first, str) and len(args) == 1:
            return str.__new__(cls, first)
        if isinstance(first, CharSequence) and len(args) == 1:
            return str.__new__(cls, first.toString())
        if isinstance(first, (list, tuple)) and all(isinstance(item, str) and len(item) == 1 for item in first):
            chars = "".join(first)
            if len(args) == 3:
                check_range(args[1], args[2], len(chars))
                chars = chars[args[1]:args[1] + args[2]]
            elif len(args) != 1:
                raise TypeError("Unsupported String constructor")
            return str.__new__(cls, from_units(chars))
        if isinstance(first, (bytes, bytearray, memoryview, list, tuple)):
            data = to_bytes(first)
            rest = args[1:]
            if len(rest) >= 2 and is_int(rest[0]) and is_int(rest[1]):
                check_range(rest[0], rest[1], len(data))
                data, rest = data[rest[0]:rest[0] + rest[1]], rest[2:]
            if len(rest) > 1:
                raise TypeError("Unsupported String constructor")
            return str.__new__(cls, decode_bytes(data, rest[0] if rest else None))
        if first is None:
            raise NullPointerException("String source is null")
        raise TypeError("Unsupported String constructor")

    def __str__(self):
        return str.__str__(self)

    def toString(self):
        return str.__str__(self)

    def to_bridge(self):
        return str.__str__(self)

    def length(self):
        return utf16_length(self)

    def isEmpty(self):
        return len(self) == 0

    def isBlank(self):
        return not str.strip(self)

    def codePointAt(self, index):
        text = units(self)
        if not 0 <= index < len(text):
            raise StringIndexOutOfBoundsException(f"index {index}, length {len(text)}")
        return ord(from_units(text[index:index + 2])[0])

    def substring(self, begin, end=None):
        text = units(self)
        end = len(text) if end is None else end
        if begin < 0 or end > len(text) or begin > end:
            raise StringIndexOutOfBoundsException(f"begin {begin}, end {end}, length {len(text)}")
        return from_units(text[begin:end])

    def _needle(self, value):
        return chr(value) if is_int(value) else _text(value)

    def indexOf(self, value, start=0):
        return units(self).find(units(self._needle(value)), max(start, 0))

    def lastIndexOf(self, value, start=None):
        text, needle = units(self), units(self._needle(value))
        if start is None:
            return text.rfind(needle)
        return -1 if start < 0 else text.rfind(needle, 0, start + len(needle))

    def contains(self, value):
        return _text(value) in str.__str__(self)

    def startsWith(self, prefix, offset=0):
        text = units(self)
        return 0 <= offset <= len(text) and text.startswith(units(_text(prefix)), offset)

    def endsWith(self, suffix):
        return str.endswith(self, _text(suffix))

    def equals(self, other):
        return isinstance(other, str) and str.__eq__(self, other)

    def contentEquals(self, other):
        return other is not None and str.__eq__(self, _text(other))

    def equalsIgnoreCase(self, other):
        return isinstance(other, str) and _fold(self) == _fold(other)

    def compareTo(self, other):
        left, right = units(self), units(_text(other))
        for a, b in zip(left, right):
            if a != b:
                return ord(a) - ord(b)
        return len(left) - len(right)

    def compareToIgnoreCase(self, other):
        return String(_fold(self)).compareTo(_fold(_text(other)))

    def hashCode(self):
        return string_hash(self)

    def concat(self, other):
        return str.__str__(self) + _text(other)

    def replace(self, old, new, *count):
        if count:
            return str.replace(self, old, new, *count)
        return str.replace(self, _text(old), _text(new))

    def replaceAll(self, regex, replacement):
        replacement = _text(replacement, "replacement")
        return translate_regex(regex).sub(lambda match: expand_replacement(match, replacement), str.__str__(self))

    def replaceFirst(self, regex, replacement):
        replacement = _text(replacement, "replacement")
        return translate_regex(regex).sub(lambda match: expand_replacement(match, replacement),
                                          str.__str__(self), count=1)

    def matches(self, regex):
        return translate_regex(regex).fullmatch(str.__str__(self)) is not None

    def split(self, *args, **kwargs):
        if not args or kwargs or args[0] is None:
            # No Java overload takes these; keep ``str.split`` for Python-style callers.
            return str.split(self, *args, **kwargs)
        limit = args[1] if len(args) > 1 else 0
        return regex_split(translate_regex(args[0]), str.__str__(self), limit)

    def trim(self):
        return str.strip(self, "".join(map(chr, range(33))))

    def strip(self, *args):
        return str.strip(self, *args)

    def stripLeading(self):
        return str.lstrip(self)

    def stripTrailing(self):
        return str.rstrip(self)

    def toLowerCase(self, locale=None):
        return str.lower(self)

    def toUpperCase(self, locale=None):
        return str.upper(self)

    def toCharArray(self):
        return list(units(self))

    def chars(self):
        raise unsupported("java.util.stream is not supported")

    def getBytes(self, charset=None):
        return encode_text(str.__str__(self), charset)

    def intern(self):
        return sys.intern(str.__str__(self))

    def repeat(self, count):
        if count < 0:
            raise IllegalArgumentException(f"count is negative: {count}")
        return str.__str__(self) * count

    def subSequence(self, start, end):
        return self.substring(start, end)

    def charAt(self, index):
        return CharSequence.charAt(self, index)

    def join(*args):
        # Java's static ``String.join(delimiter, elements...)`` and ``str.join`` share this shape.
        if not args:
            raise TypeError("join requires a delimiter")
        delimiter, elements = _text(args[0], "delimiter"), args[1:]
        if len(elements) == 1 and not isinstance(elements[0], str):
            elements = elements[0]
        return delimiter.join(jstr(item) for item in elements)

    @staticmethod
    def format(*args):
        if args and not isinstance(args[0], str) and len(args) > 1:
            args = args[1:]  # a leading Locale; formatting is locale independent
        if not args:
            raise TypeError("format requires a format string")
        return java_format(args[0], args[1:])

    @staticmethod
    def valueOf(*args):
        if len(args) == 3:
            return String(*args).toString()
        if len(args) != 1:
            raise TypeError("String.valueOf takes one value or (char[], offset, count)")
        value = args[0]
        if isinstance(value, (list, tuple)) and value and all(
                isinstance(item, str) and len(item) == 1 for item in value):
            return from_units("".join(value))
        return jstr(value)

    copyValueOf = valueOf


def _fold(text):
    return str.lower(str.upper(str.__str__(text)))


class StringBuilder(CharSequence):
    def __init__(self, value=None):
        if value is None or is_int(value):
            if is_int(value) and value < 0:
                raise NegativeArraySizeException(str(value))
            self._value = ""
        else:
            self._value = _text(value)

    def toString(self):
        return self._value

    def to_bridge(self):
        return self._value

    def __repr__(self):
        return self._value

    def __eq__(self, other):
        return self is other

    def __hash__(self):
        return id(self)

    def __contains__(self, item):
        return item in self._value

    def append(self, *args):
        if len(args) == 3:
            value, start, end = args
            if isinstance(value, (list, tuple)):
                check_range(start, end, len(value))
                self._value += from_units("".join(value[start:start + end]))
            else:
                text = units(_text(value) if value is not None else "null")
                if start < 0 or start > end or end > len(text):
                    raise IndexOutOfBoundsException(f"start {start}, end {end}, length {len(text)}")
                self._value += from_units(text[start:end])
        elif len(args) == 1:
            value = args[0]
            if isinstance(value, (list, tuple)) and value and all(
                    isinstance(item, str) and len(item) == 1 for item in value):
                self._value += "".join(value)
            else:
                self._value += jstr(value)
            self._value = from_units(self._value)
        else:
            raise TypeError("append takes one value or (value, start, end)")
        return self

    def appendCodePoint(self, code_point):
        if not 0 <= code_point <= 0x10FFFF:
            raise IllegalArgumentException(f"Not a valid Unicode code point: 0x{code_point:X}")
        self._value += chr(code_point)
        return self

    def _bounds(self, start, end):
        size = utf16_length(self._value)
        if start < 0 or start > size or start > end:
            raise StringIndexOutOfBoundsException(f"start {start}, end {end}, length {size}")
        return units(self._value), min(end, size)

    def insert(self, offset, value):
        text = units(self._value)
        if not 0 <= offset <= len(text):
            raise StringIndexOutOfBoundsException(f"offset {offset}, length {len(text)}")
        inserted = "".join(value) if isinstance(value, (list, tuple)) else jstr(value)
        self._value = from_units(text[:offset] + units(inserted) + text[offset:])
        return self

    def delete(self, start, end):
        text, end = self._bounds(start, end)
        self._value = from_units(text[:start] + text[end:])
        return self

    def deleteCharAt(self, index):
        text = units(self._value)
        if not 0 <= index < len(text):
            raise StringIndexOutOfBoundsException(f"index {index},length {len(text)}")
        self._value = from_units(text[:index] + text[index + 1:])
        return self

    def replace(self, start, end, value):
        text, end = self._bounds(start, end)
        self._value = from_units(text[:start] + units(_text(value)) + text[end:])
        return self

    def reverse(self):
        self._value = self._value[::-1]
        return self

    def setCharAt(self, index, char):
        text = units(self._value)
        if not 0 <= index < len(text):
            raise StringIndexOutOfBoundsException(f"index {index},length {len(text)}")
        self._value = from_units(text[:index] + char + text[index + 1:])

    def setLength(self, length):
        if length < 0:
            raise StringIndexOutOfBoundsException(f"String index out of range: {length}")
        text = units(self._value)
        self._value = from_units(text[:length] + "\0" * (length - len(text)))

    def indexOf(self, value, start=0):
        return units(self._value).find(units(_text(value)), max(start, 0))

    def lastIndexOf(self, value, start=None):
        return String(self._value).lastIndexOf(value, start)

    def substring(self, start, end=None):
        return String(self._value).substring(start, end)

    def capacity(self):
        return max(16, utf16_length(self._value))

    def ensureCapacity(self, minimum):
        return None

    def trimToSize(self):
        return None

    def compareTo(self, other):
        return String(self._value).compareTo(other.toString())


class StringBuffer(StringBuilder):
    pass


# --- numbers -------------------------------------------------------------------------------

def _digit(char, radix):
    code = ord(char)
    if 48 <= code <= 57:
        value = code - 48
    elif 97 <= code <= 122:
        value = code - 87
    elif 65 <= code <= 90:
        value = code - 55
    else:
        value = unicodedata.decimal(char, -1)
    return value if 0 <= value < radix else -1


def _bad_number(text, radix=10):
    return NumberFormatException('For input string: "%s"%s' % (text, "" if radix == 10 else f" under radix {radix}"))


def parse_integer(text, radix=10, bits=32, unsigned=False):
    if text is None:
        raise NumberFormatException("s == null")
    text = _text(text)
    if not 2 <= radix <= 36:
        raise NumberFormatException(f"radix {radix} out of range")
    body = text[1:] if text[:1] in ("+", "-") else text
    if not body or unsigned and text[:1] == "-":
        raise _bad_number(text, radix)
    value = 0
    for char in body:
        digit = _digit(char, radix)
        if digit < 0:
            raise _bad_number(text, radix)
        value = value * radix + digit
    if text[0] == "-":
        value = -value
    low, high = (0, (1 << bits) - 1) if unsigned else (-(1 << (bits - 1)), (1 << (bits - 1)) - 1)
    if not low <= value <= high:
        raise _bad_number(text, radix)
    return signed(value, bits) if unsigned else value


def to_radix(value, radix):
    if not 2 <= radix <= 36:
        radix = 10
    digits, number = [], abs(value)
    while True:
        number, remainder = divmod(number, radix)
        digits.append("0123456789abcdefghijklmnopqrstuvwxyz"[remainder])
        if not number:
            break
    return ("-" if value < 0 else "") + "".join(reversed(digits))


def truncate(value, bits=32):
    """Java's narrowing of a floating-point value to an integer type."""
    if value != value:
        return 0
    low, high = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    if value in (math.inf, -math.inf):
        return high if value > 0 else low
    return max(low, min(high, int(value)))


class Number(Object):
    def intValue(self):
        return truncate(self, 32) if isinstance(self, float) else i32(int(self))

    def longValue(self):
        return truncate(self, 64) if isinstance(self, float) else i64(int(self))

    def shortValue(self):
        return signed(self.intValue(), 16)

    def byteValue(self):
        return signed(self.intValue(), 8)

    def floatValue(self):
        return to_float32(self)

    def doubleValue(self):
        return float(self)


class _Integral(int, Number):
    _BITS = 32

    def __new__(cls, value=None):
        if cls is _Integral:
            raise TypeError("abstract")
        if isinstance(value, str):
            value = parse_integer(value, 10, cls._BITS)
        elif not is_int(value):
            raise TypeError(f"{cls.__name__} requires an integer or a decimal string")
        if not -(1 << (cls._BITS - 1)) <= value < 1 << (cls._BITS - 1):
            raise OverflowError(f"Value is outside Java {cls.__name__} range")
        return int.__new__(cls, value)

    def toString(*args):
        # Instance ``toString()`` and static ``toString(value[, radix])``.
        if len(args) == 1 and isinstance(args[0], _Integral):
            return int.__repr__(args[0])
        if not args or len(args) > 2 or not all(is_int(item) for item in args):
            raise TypeError("toString takes (value[, radix])")
        return to_radix(args[0], args[1] if len(args) == 2 else 10)

    def __str__(self):
        return int.__repr__(self)

    def __repr__(self):
        return int.__repr__(self)

    def to_bridge(self):
        return int(self)

    def equals(self, other):
        return is_int(other) and int(self) == int(other)

    def compareTo(self, other):
        return (int(self) > int(other)) - (int(self) < int(other))

    @classmethod
    def valueOf(cls, value, radix=10):
        return cls(parse_integer(value, radix, cls._BITS) if isinstance(value, str) else value)

    @classmethod
    def decode(cls, text):
        text = _text(text)
        if not text:
            raise NumberFormatException("Zero length string")
        negative, body = text[0] == "-", text[1:] if text[0] in "+-" else text
        radix = 10
        if body[:2].lower() == "0x":
            radix, body = 16, body[2:]
        elif body[:1] == "#":
            radix, body = 16, body[1:]
        elif body[:1] == "0" and len(body) > 1:
            radix, body = 8, body[1:]
        if body[:1] in ("+", "-"):
            raise NumberFormatException("Sign character in wrong position")
        try:
            return cls(parse_integer(("-" if negative else "") + body, radix, cls._BITS))
        except NumberFormatException:
            raise _bad_number(text) from None

    @classmethod
    def _unsigned(cls, value):
        return value & ((1 << cls._BITS) - 1)

    @classmethod
    def compare(cls, left, right):
        return (left > right) - (left < right)

    @classmethod
    def compareUnsigned(cls, left, right):
        return cls.compare(cls._unsigned(left), cls._unsigned(right))

    @classmethod
    def signum(cls, value):
        return (value > 0) - (value < 0)

    @classmethod
    def toHexString(cls, value):
        return format(cls._unsigned(value), "x")

    @classmethod
    def toOctalString(cls, value):
        return format(cls._unsigned(value), "o")

    @classmethod
    def toBinaryString(cls, value):
        return format(cls._unsigned(value), "b")

    @classmethod
    def toUnsignedString(cls, value, radix=10):
        return to_radix(cls._unsigned(value), radix)

    @classmethod
    def divideUnsigned(cls, dividend, divisor):
        if divisor == 0:
            raise ArithmeticException("/ by zero")
        return signed(cls._unsigned(dividend) // cls._unsigned(divisor), cls._BITS)

    @classmethod
    def remainderUnsigned(cls, dividend, divisor):
        if divisor == 0:
            raise ArithmeticException("/ by zero")
        return signed(cls._unsigned(dividend) % cls._unsigned(divisor), cls._BITS)

    @classmethod
    def bitCount(cls, value):
        return bin(cls._unsigned(value)).count("1")

    @classmethod
    def numberOfLeadingZeros(cls, value):
        return cls._BITS - cls._unsigned(value).bit_length()

    @classmethod
    def numberOfTrailingZeros(cls, value):
        value = cls._unsigned(value)
        return cls._BITS if value == 0 else (value & -value).bit_length() - 1

    @classmethod
    def highestOneBit(cls, value):
        value = cls._unsigned(value)
        return signed(1 << (value.bit_length() - 1), cls._BITS) if value else 0

    @classmethod
    def lowestOneBit(cls, value):
        value = cls._unsigned(value)
        return signed(value & -value, cls._BITS)

    @classmethod
    def reverse(cls, value):
        return signed(int(format(cls._unsigned(value), "0%db" % cls._BITS)[::-1], 2), cls._BITS)

    @classmethod
    def reverseBytes(cls, value):
        return signed(int.from_bytes(cls._unsigned(value).to_bytes(cls._BITS // 8, "big"), "little"), cls._BITS)

    @classmethod
    def rotateLeft(cls, value, distance):
        value, distance = cls._unsigned(value), distance % cls._BITS
        return signed((value << distance) | (value >> (cls._BITS - distance)), cls._BITS)

    @classmethod
    def rotateRight(cls, value, distance):
        return cls.rotateLeft(value, -distance)

    @classmethod
    def sum(cls, left, right):
        return signed(left + right, cls._BITS)

    @classmethod
    def max(cls, left, right):
        return max(left, right)

    @classmethod
    def min(cls, left, right):
        return min(left, right)


class _BoxHash:
    """``hashCode`` that is both the instance method and the static ``hashCode(value)``."""

    def __init__(self, function):
        self.function = function

    def __get__(self, instance, owner):
        if instance is None:
            return self.function
        return lambda: self.function(instance)


class Integer(_Integral):
    __ayu_overrides_host__ = True  # the Swift adapter is a subset; the host neither takes nor returns one
    _BITS = 32
    MIN_VALUE, MAX_VALUE, SIZE, BYTES = INT_MIN, INT_MAX, 32, 4
    TYPE = _primitive("int")
    hashCode = _BoxHash(lambda value: i32(value))

    @staticmethod
    def parseInt(text, radix=10):
        return parse_integer(text, radix, 32)

    @staticmethod
    def parseUnsignedInt(text, radix=10):
        return parse_integer(text, radix, 32, unsigned=True)

    @staticmethod
    def toUnsignedLong(value):
        return value & 0xFFFFFFFF

    @staticmethod
    def getInteger(name, default=None):
        value = System.getProperty(name) if isinstance(name, str) and name else None
        try:
            return Integer.decode(value) if value is not None else default
        except NumberFormatException:
            return default


class Long(_Integral):
    __ayu_overrides_host__ = True  # the Swift adapter is a subset; the host neither takes nor returns one
    _BITS = 64
    MIN_VALUE, MAX_VALUE, SIZE, BYTES = LONG_MIN, LONG_MAX, 64, 8
    TYPE = _primitive("long")
    hashCode = _BoxHash(lambda value: i32(value ^ ((value & 0xFFFFFFFFFFFFFFFF) >> 32)))

    @staticmethod
    def parseLong(text, radix=10):
        return parse_integer(text, radix, 64)

    @staticmethod
    def parseUnsignedLong(text, radix=10):
        return parse_integer(text, radix, 64, unsigned=True)


class Short(_Integral):
    __ayu_overrides_host__ = True  # the Swift adapter is a subset; the host neither takes nor returns one
    _BITS = 16
    MIN_VALUE, MAX_VALUE, SIZE, BYTES = -32768, 32767, 16, 2
    TYPE = _primitive("short")
    hashCode = _BoxHash(lambda value: int(value))

    @staticmethod
    def parseShort(text, radix=10):
        return parse_integer(text, radix, 16)

    @staticmethod
    def toUnsignedInt(value):
        return value & 0xFFFF


class Byte(_Integral):
    __ayu_overrides_host__ = True  # the Swift adapter is a subset; the host neither takes nor returns one
    _BITS = 8
    MIN_VALUE, MAX_VALUE, SIZE, BYTES = -128, 127, 8, 1
    TYPE = _primitive("byte")
    hashCode = _BoxHash(lambda value: int(value))

    @staticmethod
    def parseByte(text, radix=10):
        return parse_integer(text, radix, 8)

    @staticmethod
    def toUnsignedInt(value):
        return value & 0xFF


_DECIMAL = re.compile(r"[+-]?(NaN|Infinity|(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?[fFdD]?)\Z")
_HEX_FLOAT = re.compile(r"[+-]?0[xX]([0-9a-fA-F]+\.?[0-9a-fA-F]*|\.[0-9a-fA-F]+)[pP][+-]?\d+[fFdD]?\Z")


def parse_double(text):
    if text is None:
        raise NullPointerException("s == null")
    body = _text(text).strip("".join(map(chr, range(33))))
    if not body:
        raise NumberFormatException("empty String")
    if _HEX_FLOAT.match(body):
        return float.fromhex(body.rstrip("fFdD") if body[-1] in "dD" else body)
    if not _DECIMAL.match(body):
        raise _bad_number(text)
    if body.lstrip("+-") == "NaN":
        return math.nan
    if body.lstrip("+-") == "Infinity":
        return -math.inf if body[0] == "-" else math.inf
    return float(body.rstrip("fFdD"))


def compare_double(left, right):
    """``Double.compare``: -0.0 sorts below 0.0 and NaN above everything."""
    if left < right:
        return -1
    if left > right:
        return 1
    a, b = double_bits(left), double_bits(right)
    return (a > b) - (a < b)


class _Floating(float, Number):
    def __str__(self):
        return self.toString()

    def __repr__(self):
        return self.toString()

    def to_bridge(self):
        return float(self)

    def isNaN(*args):
        return args[-1] != args[-1]

    def isInfinite(*args):
        return args[-1] in (math.inf, -math.inf)

    @staticmethod
    def isFinite(value):
        return math.isfinite(value)

    def compareTo(self, other):
        return compare_double(float(self), float(other))

    @staticmethod
    def compare(left, right):
        return compare_double(float(left), float(right))

    @staticmethod
    def sum(left, right):
        return left + right

    @staticmethod
    def max(left, right):
        return Math.max(float(left), float(right))

    @staticmethod
    def min(left, right):
        return Math.min(float(left), float(right))


class Double(_Floating):
    MAX_VALUE, MIN_VALUE, MIN_NORMAL = 1.7976931348623157e308, 5e-324, 2.2250738585072014e-308
    POSITIVE_INFINITY, NEGATIVE_INFINITY, NaN = math.inf, -math.inf, math.nan
    SIZE, BYTES, MAX_EXPONENT, MIN_EXPONENT = 64, 8, 1023, -1022
    TYPE = _primitive("double")

    def __new__(cls, value=None):
        if isinstance(value, str):
            value = parse_double(value)
        elif isinstance(value, bool) or not isinstance(value, (int, float)):
            raise TypeError("Double requires a number or a string")
        return float.__new__(cls, value)

    def toString(*args):
        if len(args) != 1:
            raise TypeError("toString takes one value")
        return double_to_string(args[0])

    def equals(self, other):
        return isinstance(other, float) and not isinstance(other, Float) and double_bits(self) == double_bits(other)

    hashCode = _BoxHash(lambda value: java_hash(float(value)))

    @staticmethod
    def valueOf(value):
        return Double(value)

    @staticmethod
    def parseDouble(text):
        return parse_double(text)

    @staticmethod
    def doubleToLongBits(value):
        return double_bits(value)

    @staticmethod
    def doubleToRawLongBits(value):
        return struct.unpack(">q", struct.pack(">d", value))[0]

    @staticmethod
    def longBitsToDouble(bits):
        return struct.unpack(">d", struct.pack(">q", i64(bits)))[0]


def _float_bits(value):
    return struct.unpack(">i", struct.pack(">f", math.nan if value != value else to_float32(value)))[0]


class Float(_Floating):
    __ayu_overrides_host__ = True  # the Swift adapter is a subset; the host neither takes nor returns one
    MAX_VALUE, MIN_VALUE, MIN_NORMAL = 3.4028234663852886e38, 1.401298464324817e-45, 1.1754943508222875e-38
    POSITIVE_INFINITY, NEGATIVE_INFINITY, NaN = math.inf, -math.inf, math.nan
    SIZE, BYTES, MAX_EXPONENT, MIN_EXPONENT = 32, 4, 127, -126
    TYPE = _primitive("float")

    def __new__(cls, value=None):
        if isinstance(value, str):
            value = parse_double(value)
        elif isinstance(value, bool) or not isinstance(value, (int, float)):
            raise TypeError("Float requires a number or a string")
        return float.__new__(cls, to_float32(value))

    def toString(*args):
        if len(args) != 1:
            raise TypeError("toString takes one value")
        return float_to_string(args[0])

    def equals(self, other):
        return isinstance(other, Float) and _float_bits(self) == _float_bits(other)

    hashCode = _BoxHash(lambda value: _float_bits(value))

    @staticmethod
    def valueOf(value):
        return Float(value)

    @staticmethod
    def parseFloat(text):
        return to_float32(parse_double(text))

    @staticmethod
    def floatToIntBits(value):
        return _float_bits(value)

    @staticmethod
    def floatToRawIntBits(value):
        return struct.unpack(">i", struct.pack(">f", to_float32(value)))[0]

    @staticmethod
    def intBitsToFloat(bits):
        return struct.unpack(">f", struct.pack(">i", i32(bits)))[0]


class Boolean(Comparable):
    __ayu_overrides_host__ = True  # the Swift adapter is a subset; the host neither takes nor returns one
    TYPE = _primitive("boolean")

    def __init__(self, value=None):
        if isinstance(value, Boolean):
            value = value._value
        elif isinstance(value, str) or value is None:
            value = Boolean.parseBoolean(value)
        elif not isinstance(value, bool):
            raise TypeError("Boolean requires a bool or a string")
        self._value = value

    def booleanValue(self):
        return self._value

    def __bool__(self):
        return self._value

    def __eq__(self, other):
        return isinstance(other, (bool, Boolean)) and self._value == bool(other)

    def __hash__(self):
        return hash(self._value)

    def __repr__(self):
        return "true" if self._value else "false"

    def to_bridge(self):
        return self._value

    def compareTo(self, other):
        return Boolean.compare(self._value, bool(other))

    def toString(*args):
        if len(args) != 1 or not isinstance(args[0], (bool, Boolean)):
            raise TypeError("toString takes one boolean")
        return "true" if args[0] else "false"

    hashCode = _BoxHash(lambda value: 1231 if value else 1237)

    @staticmethod
    def parseBoolean(text):
        return isinstance(text, str) and text.lower() == "true"

    @staticmethod
    def valueOf(value):
        if isinstance(value, Boolean):
            value = value._value
        elif not isinstance(value, bool):
            value = Boolean.parseBoolean(value)
        return Boolean.TRUE if value else Boolean.FALSE

    @staticmethod
    def compare(left, right):
        return (bool(left) > bool(right)) - (bool(left) < bool(right))

    @staticmethod
    def logicalAnd(left, right):
        return bool(left) and bool(right)

    @staticmethod
    def logicalOr(left, right):
        return bool(left) or bool(right)

    @staticmethod
    def logicalXor(left, right):
        return bool(left) != bool(right)

    @staticmethod
    def getBoolean(name):
        return Boolean.parseBoolean(System.getProperty(name)) if isinstance(name, str) and name else False


Boolean.TRUE, Boolean.FALSE = Boolean(True), Boolean(False)


def _char_arg(value):
    if isinstance(value, str) and len(value) == 1:
        return value, True
    if is_int(value) and 0 <= value <= 0x10FFFF:
        return chr(value), False
    raise TypeError("Expected a char or a code point")


def _char_result(char, as_char):
    return char if as_char else ord(char)


class Character(str, Comparable):
    MIN_VALUE, MAX_VALUE = "\u0000", "\uffff"
    MIN_RADIX, MAX_RADIX = 2, 36
    MIN_CODE_POINT, MAX_CODE_POINT, MIN_SUPPLEMENTARY_CODE_POINT = 0, 0x10FFFF, 0x10000
    MIN_HIGH_SURROGATE, MAX_HIGH_SURROGATE = "\ud800", "\udbff"
    MIN_LOW_SURROGATE, MAX_LOW_SURROGATE = "\udc00", "\udfff"
    SIZE, BYTES = 16, 2
    TYPE = _primitive("char")

    def __new__(cls, value):
        if not isinstance(value, str) or len(value) != 1 or value > "\uffff":
            raise TypeError("Character requires one UTF-16 code unit")
        return str.__new__(cls, value)

    def __str__(self):
        return str.__str__(self)

    def to_bridge(self):
        return str.__str__(self)

    def charValue(self):
        return str.__str__(self)

    def compareTo(self, other):
        return ord(self) - ord(other)

    def equals(self, other):
        return isinstance(other, str) and str.__eq__(self, other)

    hashCode = _BoxHash(lambda value: ord(value))

    def toString(*args):
        if len(args) != 1:
            raise TypeError("toString takes one char")
        return _char_arg(args[0])[0]

    @staticmethod
    def valueOf(char):
        return Character(char)

    @staticmethod
    def compare(left, right):
        return ord(left) - ord(right)

    @staticmethod
    def isDigit(value):
        return unicodedata.category(_char_arg(value)[0]) == "Nd"

    @staticmethod
    def isLetter(value):
        return unicodedata.category(_char_arg(value)[0]).startswith("L")

    @staticmethod
    def isLetterOrDigit(value):
        return Character.isLetter(value) or Character.isDigit(value)

    @staticmethod
    def isAlphabetic(value):
        return unicodedata.category(_char_arg(value)[0])[0] == "L" or unicodedata.category(_char_arg(value)[0]) == "Nl"

    @staticmethod
    def isUpperCase(value):
        return unicodedata.category(_char_arg(value)[0]) == "Lu"

    @staticmethod
    def isLowerCase(value):
        return unicodedata.category(_char_arg(value)[0]) == "Ll"

    @staticmethod
    def isWhitespace(value):
        char = _char_arg(value)[0]
        if char in "\t\n\x0b\x0c\r\x1c\x1d\x1e\x1f":
            return True
        return unicodedata.category(char) in ("Zs", "Zl", "Zp") and char not in "\u00a0\u2007\u202f"

    @staticmethod
    def isSpaceChar(value):
        return unicodedata.category(_char_arg(value)[0]) in ("Zs", "Zl", "Zp")

    @staticmethod
    def isISOControl(value):
        code = ord(_char_arg(value)[0])
        return code <= 0x1F or 0x7F <= code <= 0x9F

    @staticmethod
    def isSurrogate(char):
        return "\ud800" <= char <= "\udfff"

    @staticmethod
    def isHighSurrogate(char):
        return "\ud800" <= char <= "\udbff"

    @staticmethod
    def isLowSurrogate(char):
        return "\udc00" <= char <= "\udfff"

    @staticmethod
    def isValidCodePoint(code_point):
        return 0 <= code_point <= 0x10FFFF

    @staticmethod
    def isSupplementaryCodePoint(code_point):
        return 0x10000 <= code_point <= 0x10FFFF

    @staticmethod
    def charCount(code_point):
        return 2 if code_point >= 0x10000 else 1

    @staticmethod
    def toChars(code_point):
        if not 0 <= code_point <= 0x10FFFF:
            raise IllegalArgumentException(f"Not a valid Unicode code point: 0x{code_point:X}")
        return list(units(chr(code_point)))

    @staticmethod
    def toCodePoint(high, low):
        return ((ord(high) - 0xD800) << 10) + (ord(low) - 0xDC00) + 0x10000

    @staticmethod
    def toUpperCase(value):
        char, as_char = _char_arg(value)
        upper = char.upper()
        return _char_result(upper if len(upper) == 1 else char, as_char)

    @staticmethod
    def toLowerCase(value):
        char, as_char = _char_arg(value)
        lower = char.lower()
        return _char_result(lower if len(lower) == 1 else char, as_char)

    @staticmethod
    def toTitleCase(value):
        char, as_char = _char_arg(value)
        title = char.title()
        return _char_result(title if len(title) == 1 else char, as_char)

    @staticmethod
    def digit(value, radix):
        return _digit(_char_arg(value)[0], radix) if 2 <= radix <= 36 else -1

    @staticmethod
    def forDigit(digit, radix):
        if not 2 <= radix <= 36 or not 0 <= digit < radix:
            return "\0"
        return "0123456789abcdefghijklmnopqrstuvwxyz"[digit]

    @staticmethod
    def getNumericValue(value):
        char = _char_arg(value)[0]
        digit = _digit(char, 36)
        if digit >= 0:
            return digit
        number = unicodedata.numeric(char, None)
        if number is None:
            return -1
        return int(number) if number == int(number) and number >= 0 else -2


# --- Math / System / Runtime ---------------------------------------------------------------

def _width(*values):
    return 32 if fits_int(*values) else 64


def _exact(value, bits):
    if not -(1 << (bits - 1)) <= value < 1 << (bits - 1):
        raise ArithmeticException("integer overflow" if bits == 32 else "long overflow")
    return value


def _float_result(function):
    def wrapped(*args):
        try:
            return function(*map(float, args))
        except ValueError:
            return math.nan
        except OverflowError:
            return math.inf
    return staticmethod(wrapped)


class Math(Object):
    PI, E = math.pi, math.e

    def __init__(self):
        raise unsupported("java.lang.Math cannot be constructed")

    @staticmethod
    def abs(value):
        if is_int(value):
            # Java's overflow: the most negative int/long has no positive counterpart.
            return value if value in (INT_MIN, LONG_MIN) else abs(value)
        return abs(float(value))

    @staticmethod
    def max(left, right):
        if is_int(left) and is_int(right):
            return max(left, right)
        left, right = float(left), float(right)
        if left != left or right != right:
            return math.nan
        if left == right == 0:
            return left if math.copysign(1.0, left) > 0 else right
        return max(left, right)

    @staticmethod
    def min(left, right):
        if is_int(left) and is_int(right):
            return min(left, right)
        left, right = float(left), float(right)
        if left != left or right != right:
            return math.nan
        if left == right == 0:
            return left if math.copysign(1.0, left) < 0 else right
        return min(left, right)

    @staticmethod
    def clamp(value, low, high):
        if low > high:
            raise IllegalArgumentException(f"{low} > {high}")
        return min(high, max(value, low))

    @staticmethod
    def round(value):
        value = float(value)
        if value != value:
            return 0
        if value in (math.inf, -math.inf):
            return LONG_MAX if value > 0 else LONG_MIN
        return max(LONG_MIN, min(LONG_MAX, math.floor(decimal.Decimal(value) + decimal.Decimal("0.5"))))

    @staticmethod
    def rint(value):
        value = float(value)
        return value if not math.isfinite(value) else math.copysign(float(round(value)), value)

    @staticmethod
    def floor(value):
        value = float(value)
        return value if not math.isfinite(value) else math.copysign(float(math.floor(value)), value)

    @staticmethod
    def ceil(value):
        value = float(value)
        return value if not math.isfinite(value) else math.copysign(float(math.ceil(value)), value)

    @staticmethod
    def signum(value):
        value = float(value)
        return value if value != value or value == 0 else math.copysign(1.0, value)

    @staticmethod
    def pow(base, exponent):
        base, exponent = float(base), float(exponent)
        try:
            return math.pow(base, exponent)
        except ValueError:
            if base == 0 and exponent < 0:
                odd = exponent == int(exponent) and int(exponent) % 2 == 1
                return -math.inf if odd and math.copysign(1.0, base) < 0 else math.inf
            return math.nan
        except OverflowError:
            return -math.inf if base < 0 and exponent % 2 == 1 else math.inf

    @staticmethod
    def sqrt(value):
        value = float(value)
        return math.nan if value < 0 or value != value else math.sqrt(value)

    @staticmethod
    def cbrt(value):
        value = float(value)
        return value if not math.isfinite(value) or value == 0 else math.copysign(abs(value) ** (1.0 / 3.0), value)

    @staticmethod
    def log(value):
        value = float(value)
        return -math.inf if value == 0 else math.nan if value < 0 or value != value else math.log(value)

    @staticmethod
    def log10(value):
        value = float(value)
        return -math.inf if value == 0 else math.nan if value < 0 or value != value else math.log10(value)

    @staticmethod
    def log1p(value):
        value = float(value)
        return -math.inf if value == -1 else math.nan if value < -1 or value != value else math.log1p(value)

    sin, cos, tan = _float_result(math.sin), _float_result(math.cos), _float_result(math.tan)
    asin, acos, atan = _float_result(math.asin), _float_result(math.acos), _float_result(math.atan)
    sinh, cosh, tanh = _float_result(math.sinh), _float_result(math.cosh), _float_result(math.tanh)
    atan2, hypot = _float_result(math.atan2), _float_result(math.hypot)
    exp, expm1 = _float_result(math.exp), _float_result(math.expm1)
    toRadians, toDegrees = _float_result(math.radians), _float_result(math.degrees)

    @staticmethod
    def random():
        import random
        return random.random()

    @staticmethod
    def floorDiv(left, right):
        if right == 0:
            raise ArithmeticException("/ by zero")
        return signed(left // right, _width(left, right))

    @staticmethod
    def floorMod(left, right):
        if right == 0:
            raise ArithmeticException("/ by zero")
        return left % right

    @staticmethod
    def addExact(left, right):
        return _exact(left + right, _width(left, right))

    @staticmethod
    def subtractExact(left, right):
        return _exact(left - right, _width(left, right))

    @staticmethod
    def multiplyExact(left, right):
        return _exact(left * right, _width(left, right))

    @staticmethod
    def negateExact(value):
        return _exact(-value, _width(value))

    @staticmethod
    def incrementExact(value):
        return _exact(value + 1, _width(value))

    @staticmethod
    def decrementExact(value):
        return _exact(value - 1, _width(value))

    @staticmethod
    def toIntExact(value):
        return _exact(value, 32)


class System(Object):
    """Clock, properties and array copy. ``exit`` and environment mutation are not provided."""
    __ayu_overrides_host__ = True  # the Swift adapter is a subset; the host neither takes nor returns one

    def __init__(self):
        raise unsupported("java.lang.System cannot be constructed")

    out = Lazy(lambda: _print_stream("stdout"))
    err = Lazy(lambda: _print_stream("stderr"))

    @staticmethod
    def currentTimeMillis():
        return time.time_ns() // 1_000_000

    @staticmethod
    def nanoTime():
        return time.monotonic_ns()

    @staticmethod
    def identityHashCode(value):
        return identity_hash(value)

    @staticmethod
    def lineSeparator():
        return "\n"

    @staticmethod
    def arraycopy(source, source_position, target, target_position, length):
        if source is None or target is None:
            raise NullPointerException()
        if any(type(item).__name__ == "RemoteObject" for item in (source, target)):
            raise unsupported("System.arraycopy needs Python-local arrays")
        if length < 0 or source_position < 0 or target_position < 0 or \
                source_position + length > len(source) or target_position + length > len(target):
            raise ArrayIndexOutOfBoundsException(
                f"arraycopy: length {length}, source {source_position}/{len(source)}, "
                f"destination {target_position}/{len(target)}")
        chunk = list(source[source_position:source_position + length])
        if isinstance(target, (bytearray, memoryview)) and not isinstance(source, (bytes, bytearray, memoryview)):
            chunk = [item & 0xFF for item in chunk]
        elif not isinstance(target, (bytearray, memoryview)) and isinstance(source, (bytes, bytearray, memoryview)):
            chunk = [signed(item, 8) for item in chunk]
        for offset, item in enumerate(chunk):
            target[target_position + offset] = item

    @staticmethod
    def _defaults():
        import tempfile
        uname = os.uname() if hasattr(os, "uname") else None
        return {
            "line.separator": "\n", "file.separator": "/", "path.separator": ":",
            "os.name": uname.sysname if uname else sys.platform,
            "os.arch": uname.machine if uname else "", "os.version": uname.release if uname else "",
            "java.io.tmpdir": tempfile.gettempdir(), "user.dir": os.getcwd(),
            "user.home": os.path.expanduser("~"), "file.encoding": "UTF-8",
        }

    @staticmethod
    def _key(name):
        if name is None:
            raise NullPointerException("key can't be null")
        if not isinstance(name, str) or not name:
            raise IllegalArgumentException("key can't be empty")
        return name

    @staticmethod
    def getProperty(name, default=None):
        store = scoped_store("properties")
        name = System._key(name)
        if name in store:
            return store[name] if store[name] is not None else default
        return System._defaults().get(name, default)

    @staticmethod
    def setProperty(name, value):
        if not isinstance(value, str):
            raise NullPointerException("value can't be null")
        previous = System.getProperty(name)
        scoped_store("properties")[name] = value
        return previous

    @staticmethod
    def clearProperty(name):
        previous = System.getProperty(name)
        scoped_store("properties")[name] = None
        return previous

    @staticmethod
    def getenv(name=None):
        if name is None:
            raise unsupported("The process environment map is not exposed")
        return os.environ.get(name)

    @staticmethod
    def gc():
        import gc
        gc.collect()

    @staticmethod
    def exit(status):
        raise unsupported("A plugin cannot terminate the host application")


def _print_stream(name):
    from . import java_io
    return java_io.PrintStream(java_io.ProcessStream(name))


class Runtime(Object):
    _instance = None

    def __init__(self):
        raise unsupported("Use Runtime.getRuntime()")

    @staticmethod
    def getRuntime():
        if Runtime._instance is None:
            Runtime._instance = object.__new__(Runtime)
        return Runtime._instance

    def availableProcessors(self):
        return os.cpu_count() or 1

    def gc(self):
        System.gc()

    def exit(self, status):
        raise unsupported("A plugin cannot terminate the host application")

    halt = exit

    def exec(self, *args):
        raise unsupported("Launching native processes is unsupported")


class Modifier(Object):
    PUBLIC, PRIVATE, PROTECTED, STATIC, FINAL, SYNCHRONIZED = 1, 2, 4, 8, 16, 32
    VOLATILE, TRANSIENT, NATIVE, INTERFACE, ABSTRACT, STRICT = 64, 128, 256, 512, 1024, 2048
    _NAMES = ((1, "public"), (4, "protected"), (2, "private"), (1024, "abstract"), (8, "static"), (16, "final"),
              (128, "transient"), (64, "volatile"), (32, "synchronized"), (256, "native"), (2048, "strictfp"),
              (512, "interface"))

    @staticmethod
    def toString(modifiers):
        return " ".join(name for bit, name in Modifier._NAMES if modifiers & bit)


for _name, _bit in (("isPublic", 1), ("isPrivate", 2), ("isProtected", 4), ("isStatic", 8), ("isFinal", 16),
                    ("isSynchronized", 32), ("isVolatile", 64), ("isTransient", 128), ("isNative", 256),
                    ("isInterface", 512), ("isAbstract", 1024), ("isStrict", 2048)):
    setattr(Modifier, _name, staticmethod(lambda modifiers, _bit=_bit: bool(modifiers & _bit)))


class Reference(Object):
    """Weak when Python can reference the referent weakly, otherwise strong until ``clear``.

    A host object's facade is held strongly: the host keeps the object alive until the
    plugin generation ends, so dropping the facade must not make ``get`` return null.
    """

    def __init__(self, referent, queue=None):
        if queue is not None:
            raise unsupported("ReferenceQueue is not supported")
        self._strong, self._weak = None, None
        if referent is not None:
            try:
                if type(referent).__name__ == "RemoteObject":
                    raise TypeError
                self._weak = weakref.ref(referent)
            except TypeError:
                self._strong = referent

    def get(self):
        return self._weak() if self._weak is not None else self._strong

    def clear(self):
        self._strong, self._weak = None, None

    def isEnqueued(self):
        return False

    def enqueue(self):
        return False


class WeakReference(Reference):
    __ayu_overrides_host__ = True  # the Swift adapter is a subset; the host neither takes nor returns one
    pass


class SoftReference(Reference):
    """Holds its referent strongly: Python has no memory-pressure notification to clear it on."""

    def __init__(self, referent, queue=None):
        Reference.__init__(self, None, queue)
        self._strong = referent


CLASSES = register({
    "java.lang.Object": Object,
    "java.lang.Iterable": Iterable,
    "java.lang.Comparable": Comparable,
    "java.lang.Cloneable": Cloneable,
    "java.lang.AutoCloseable": AutoCloseable,
    "java.lang.CharSequence": CharSequence,
    "java.lang.String": String,
    "java.lang.StringBuilder": StringBuilder,
    "java.lang.StringBuffer": StringBuffer,
    "java.lang.Number": Number,
    "java.lang.Integer": Integer,
    "java.lang.Long": Long,
    "java.lang.Short": Short,
    "java.lang.Byte": Byte,
    "java.lang.Double": Double,
    "java.lang.Float": Float,
    "java.lang.Boolean": Boolean,
    "java.lang.Character": Character,
    "java.lang.Math": Math,
    "java.lang.StrictMath": Math,
    "java.lang.System": System,
    "java.lang.Runtime": Runtime,
    "java.lang.Class": Class,
    "java.lang.ClassLoader": ClassLoader,
    "java.lang.Enum": Enum,
    "java.lang.StackTraceElement": StackTraceElement,
    "java.lang.reflect.Modifier": Modifier,
    "java.lang.ref.Reference": Reference,
    "java.lang.ref.WeakReference": WeakReference,
    "java.lang.ref.SoftReference": SoftReference,
    "java.lang.Throwable": Throwable,
    "java.lang.Exception": Exception_,
    "java.lang.Error": Error,
    "java.lang.RuntimeException": RuntimeException,
    "java.lang.IllegalArgumentException": IllegalArgumentException,
    "java.lang.IllegalStateException": IllegalStateException,
    "java.lang.NumberFormatException": NumberFormatException,
    "java.lang.IllegalThreadStateException": IllegalThreadStateException,
    "java.lang.IllegalMonitorStateException": IllegalMonitorStateException,
    "java.lang.NullPointerException": NullPointerException,
    "java.lang.IndexOutOfBoundsException": IndexOutOfBoundsException,
    "java.lang.ArrayIndexOutOfBoundsException": ArrayIndexOutOfBoundsException,
    "java.lang.StringIndexOutOfBoundsException": StringIndexOutOfBoundsException,
    "java.lang.UnsupportedOperationException": UnsupportedOperationException,
    "java.lang.ArithmeticException": ArithmeticException,
    "java.lang.ClassCastException": ClassCastException,
    "java.lang.NegativeArraySizeException": NegativeArraySizeException,
    "java.lang.ArrayStoreException": ArrayStoreException,
    "java.lang.SecurityException": SecurityException,
    "java.lang.ReflectiveOperationException": ReflectiveOperationException,
    "java.lang.ClassNotFoundException": ClassNotFoundException,
    "java.lang.NoSuchFieldException": NoSuchFieldException,
    "java.lang.NoSuchMethodException": NoSuchMethodException,
    "java.lang.IllegalAccessException": IllegalAccessException,
    "java.lang.InstantiationException": InstantiationException,
    "java.lang.CloneNotSupportedException": CloneNotSupportedException,
    "java.lang.AssertionError": AssertionError_,
    "java.lang.LinkageError": LinkageError,
    "java.lang.NoClassDefFoundError": NoClassDefFoundError,
    "java.lang.UnsatisfiedLinkError": UnsatisfiedLinkError,
    "java.lang.VirtualMachineError": VirtualMachineError,
    "java.lang.OutOfMemoryError": OutOfMemoryError,
    "java.lang.StackOverflowError": StackOverflowError,
})
