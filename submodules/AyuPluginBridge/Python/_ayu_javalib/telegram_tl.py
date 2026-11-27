"""Python-local Telegram TL object model (``org.telegram.tgnet``).

``TLRPC``, the ``org.telegram.tgnet.tl.TL_*`` holders and their nested classes are built from
the generated table in ``_telegram_tl_schema``: Android class names, hierarchy, field names and
Java defaults, with the constructor ids, field order and flag bits of the TL layer the iOS
client speaks. Objects serialize to and from binary TL exactly as Android's
``serializeToStream``/``readParams`` do, so the host exchanges them as opaque bytes
(``{"tl": "<base64>"}``, see ``protocol-telegram.md``) and needs no per-class mapping.

Flags follow Android: a flag bit that guards a boolean is derived from the boolean, a bit
Android derives from the value is derived the same way, and every other optional field is
written only when the caller set its bit in ``flags``.
"""
from __future__ import annotations

import base64
import struct
import zlib

PACKAGE = "org.telegram.tgnet."
WIRE_KEY = "tl"
VECTOR = 0x1CB5C415
BOOL_TRUE = 0x997275B5
BOOL_FALSE = 0xBC799737
MAX_OBJECT_BYTES = 4 * 1024 * 1024
MAX_SEND_BYTES = 1024 * 1024
MAX_DEPTH = 64
_MISSING = {}
_BY_ID = {}
# The host adapters of these names are bounded read-only snapshots (four user fields, three chat
# fields); the TL classes replace them so the names resolve to real, constructible types.
_HOST_SNAPSHOTS = ("User", "Chat")


def _bridge():
    import ayu_bridge
    return ayu_bridge


def _unsupported(message):
    """``UnsupportedAPI`` that ``hasattr``/``getattr`` defaults treat as a missing member."""
    base = _bridge().UnsupportedAPI
    cls = _MISSING.get(base)
    if cls is None:
        cls = _MISSING[base] = type("UnsupportedMember", (base, AttributeError), {})
    return cls(message)


def _array_list(items=()):
    from . import java_util
    return java_util.ArrayList(items) if items else java_util.ArrayList()


def _signed(value, bits):
    value &= (1 << bits) - 1
    return value - (1 << bits) if value >> (bits - 1) else value


def _integer(value, bits, what):
    """The unsigned bit pattern of a stream integer.

    A Java ``long`` is signed and is never wrapped. A 32-bit word or a byte is also taken
    unsigned, because constructor ids and flag words are written that way.
    """
    if type(value) is not int:
        raise TypeError(f"{what} must be an integer")
    if not -(1 << (bits - 1)) <= value < (1 << (bits - 1 if bits == 64 else bits)):
        raise ValueError(f"{what} {value} does not fit in {bits} bits")
    return value & ((1 << bits) - 1)


def _field_integer(value, bits, where):
    """A Java ``int``/``long`` field value: signed and in range, as Java could hold it."""
    if type(value) is not int:
        raise TypeError(f"{where} must be an integer, not {type(value).__name__}")
    if not -(1 << (bits - 1)) <= value < 1 << (bits - 1):
        raise ValueError(f"{where} = {value} is outside the signed {bits}-bit range")
    return value


def _is_local(value):
    """Whether a value really is a Python TL object (a host snapshot handle is not)."""
    return type.__instancecheck__(TLObject, value)


def as_bytes(value, what="byte[]"):
    """A Java ``byte[]`` argument (bytes, a list of signed or unsigned bytes, or a host array) as bytes."""
    if isinstance(value, (bytes, bytearray, memoryview)):
        return bytes(value)
    if value is None or isinstance(value, str):
        raise TypeError(f"{what} must be a byte array")
    try:
        items = list(value)
    except TypeError:
        raise TypeError(f"{what} must be a byte array") from None
    if len(items) > MAX_OBJECT_BYTES:
        raise ValueError(f"{what} exceeds the TL object size limit")
    result = bytearray(len(items))
    for index, item in enumerate(items):
        if type(item) is not int or not -128 <= item <= 255:
            raise TypeError(f"{what} must contain byte values")
        result[index] = item & 0xFF
    return bytes(result)


class TLParseException(RuntimeError):
    """``org.telegram.tgnet.TLParseException``."""


class AbstractSerializedData:
    """``SerializedData``/``NativeByteBuffer`` over one bounded in-memory buffer.

    An output stream appends, an input stream reads from its position, and a
    ``NativeByteBuffer`` reads and writes at its position within a fixed capacity.
    """
    _positional = False

    def __init__(self, *args):
        self._data, self._position, self._calculate, self._input = bytearray(), 0, False, False
        self._limit = None
        if not args:
            return
        if len(args) != 1:
            raise _unsupported(type(self).__name__ + " constructor overload is not implemented")
        value = args[0]
        if type(value) is bool:
            self._calculate = value
        elif type(value) is int:
            if not 0 <= value <= MAX_OBJECT_BYTES:
                raise ValueError("Stream size is out of range")
            if self._positional:
                self._data = bytearray(value)
        elif self._positional:
            raise _unsupported("NativeByteBuffer constructor overload is not implemented")
        else:
            self._data, self._input = bytearray(as_bytes(value, "data")), True

    # Writing
    def _write(self, data):
        if self._calculate:
            self._position += len(data)
            return
        if self._input:
            raise _unsupported("An input SerializedData cannot be written")
        if self._positional:
            end = self._position + len(data)
            if end > self._capacity():
                raise IndexError("NativeByteBuffer overflow")
            self._data[self._position:end] = data
            self._position = end
            return
        if len(self._data) + len(data) > MAX_OBJECT_BYTES:
            raise ValueError("Serialized TL data exceeds the object size limit")
        self._data += data

    def writeInt32(self, x):
        self._write(struct.pack("<I", _integer(x, 32, "int")))

    def writeInt64(self, x):
        self._write(struct.pack("<Q", _integer(x, 64, "long")))

    def writeBool(self, value):
        if type(value) is not bool:
            raise TypeError("boolean expected")
        self.writeInt32(BOOL_TRUE if value else BOOL_FALSE)

    def writeBytes(self, b, offset=None, count=None):
        data = as_bytes(b)
        if offset is not None or count is not None:
            data = self._slice(data, offset, count)
        self._write(data)

    def writeByte(self, i):
        self._write(bytes((_integer(i, 8, "byte"),)))

    def writeString(self, s):
        if not isinstance(s, str):
            raise TypeError("String expected")
        self.writeByteArray(s.encode("utf-8", "surrogatepass"))

    def writeByteArray(self, b, offset=None, count=None):
        data = as_bytes(b)
        if offset is not None or count is not None:
            data = self._slice(data, offset, count)
        if len(data) <= 253:
            head = bytes((len(data),))
        else:
            if len(data) >= 1 << 24:
                raise ValueError("TL byte array is too long")
            head = b"\xfe" + len(data).to_bytes(3, "little")
        self._write(head + data + b"\0" * (-(len(head) + len(data)) % 4))

    def writeDouble(self, d):
        self._write(struct.pack("<d", float(d)))

    def writeFloat(self, f):
        self._write(struct.pack("<f", float(f)))

    def writeByteBuffer(self, buffer):
        if not isinstance(buffer, AbstractSerializedData):
            raise TypeError("NativeByteBuffer expected")
        self.writeByteArray(buffer._readable())

    @staticmethod
    def _slice(data, offset, count):
        if type(offset) is not int or type(count) is not int or offset < 0 or count < 0 or offset + count > len(data):
            raise IndexError("Byte range is outside the array")
        return data[offset:offset + count]

    # Reading
    def _capacity(self):
        return len(self._data)

    def _end(self):
        return self._capacity() if self._limit is None else self._limit

    def _readable(self):
        return bytes(self._data[self._position:self._end()]) if self._input or self._positional else bytes(self._data)

    def _read(self, count, exception, what):
        if self._calculate or not (self._input or self._positional) or count < 0 or self._position + count > self._end():
            if exception:
                raise TLParseException(f"read {what} error")
            return None
        data = bytes(self._data[self._position:self._position + count])
        self._position += count
        return data

    def readInt32(self, exception=False):
        data = self._read(4, exception, "int32")
        return 0 if data is None else struct.unpack("<i", data)[0]

    def readInt64(self, exception=False):
        data = self._read(8, exception, "int64")
        return 0 if data is None else struct.unpack("<q", data)[0]

    def readBool(self, exception=False):
        constructor = self.readInt32(exception) & 0xFFFFFFFF
        if constructor == BOOL_TRUE:
            return True
        if constructor != BOOL_FALSE and exception:
            raise TLParseException("Not bool value!")
        return False

    def readByte(self, exception=False):
        data = self._read(1, exception, "byte")
        return 0 if data is None else _signed(data[0], 8)

    def readBytes(self, b, exception=False):
        if not isinstance(b, (bytearray, list)):
            raise _unsupported("readBytes needs a bytearray or list to fill")
        data = self._read(len(b), exception, "bytes")
        if data is not None:
            b[:] = data if isinstance(b, bytearray) else [_signed(item, 8) for item in data]

    def readData(self, count, exception=False):
        if type(count) is not int:
            raise TypeError("count must be an integer")
        data = self._read(count, exception, "data")
        return b"" if data is None else data

    def readByteArray(self, exception=False):
        start = self._position
        head = self._read(1, exception, "byte array")
        if head is None:
            return b""
        length, used = head[0], 1
        if length >= 254:
            more = self._read(3, exception, "byte array")
            if more is None:
                self._position = start
                return b""
            length, used = int.from_bytes(more, "little"), 4
        data = self._read(length, exception, "byte array")
        if data is None or self._read(-(used + length) % 4, exception, "byte array") is None:
            self._position = start
            return b""
        return data

    def readString(self, exception=False):
        return self.readByteArray(exception).decode("utf-8", "replace")

    def readByteBuffer(self, exception=False):
        data = self.readByteArray(exception)
        buffer = NativeByteBuffer(len(data))
        buffer._data[:] = data
        return buffer

    def readFloat(self, exception=False):
        data = self._read(4, exception, "float")
        return 0.0 if data is None else struct.unpack("<f", data)[0]

    def readDouble(self, exception=False):
        data = self._read(8, exception, "double")
        return 0.0 if data is None else struct.unpack("<d", data)[0]

    def skip(self, count):
        if type(count) is not int or count < 0:
            raise ValueError("Invalid skip count")
        if self._calculate or not (self._input or self._positional):
            self._write(b"\0" * count)
        elif self._position + count <= self._end():
            self._position += count

    def getPosition(self):
        return self._position if self._calculate or self._input or self._positional else len(self._data)

    def remaining(self):
        return self._end() - self._position if self._input or self._positional else 0

    def length(self):
        if self._calculate or self._positional:
            return self._position
        return self._end() - self._position if self._input else len(self._data)


InputSerializedData = OutputSerializedData = AbstractSerializedData


class SerializedData(AbstractSerializedData):
    def toByteArray(self):
        return bytes(self._data)

    def cleanup(self):
        self._data, self._position = bytearray(), 0


class NativeByteBuffer(AbstractSerializedData):
    _positional = True

    def position(self, *args):
        if not args:
            return self._position
        (value,) = args
        if type(value) is not int or not 0 <= value <= self._end():
            raise ValueError("Invalid buffer position")
        self._position = value
        return None

    def limit(self, *args):
        if not args:
            return self._end()
        (value,) = args
        if type(value) is not int or not 0 <= value <= self._capacity():
            raise ValueError("Invalid buffer limit")
        self._limit = value
        self._position = min(self._position, value)
        return None

    def capacity(self):
        return self._capacity()

    def rewind(self):
        self._position = 0

    def hasRemaining(self):
        return self.remaining() > 0

    def reuse(self):
        self._position, self._limit = 0, None


def _class_name(cls):
    return getattr(cls, "_ayu_java_name", cls.__name__)


def _parse_wire(text):
    items = []
    for part in text.split():
        name, _, spec = part.partition(":")
        code, _, condition = spec.partition("@")
        word = bit = None
        mode = ""
        if condition:
            body = condition.rstrip("?ze")
            mode = condition[len(body):]
            word, bit = (int(piece) for piece in body.split("."))
        items.append((name, code, word, bit, mode))
    return tuple(items)


class _Plan:
    """Per-class layout derived once from the generated table."""

    def __init__(self, cls):
        immutable, factories, names = {}, [], set()
        for base in reversed(cls.__mro__):
            for part in base.__dict__.get("_ayu_own", "").split():
                name, _, spec = part.partition(":")
                kind, _, default = spec.partition("=")
                names.add(name)
                immutable.pop(name, None)
                factories[:] = [item for item in factories if item[0] != name]
                if kind == "A":
                    factories.append((name, _array_list))
                elif kind.startswith("n"):
                    factories.append((name, _lazy_class(kind[1:])))
                elif kind in "ilbd":
                    value = int(default) if default else 0
                    immutable[name] = bool(value) if kind == "b" else float(value) if kind == "d" else value
                else:
                    immutable[name] = default[1:-1] if kind == "s" and default else None
        self.immutable, self.factories, self.names = immutable, tuple(factories), frozenset(names)
        text = cls.__dict__.get("_ayu_wire")
        self.wire = None if text is None else _parse_wire(text)
        self.words = () if self.wire is None else tuple(item[0] for item in self.wire if item[1] == "#")
        self.derived = () if self.wire is None else tuple(
            (word, 1 << bit, name, "t" if code == "t" else mode)
            for name, code, word, bit, mode in self.wire if word is not None and (code == "t" or mode))


def _lazy_class(key):
    def construct():
        return _TABLE[key]()
    return construct


def _plan(cls):
    plan = cls.__dict__.get("_ayu_plan")
    if plan is None:
        plan = _Plan(cls)
        type.__setattr__(cls, "_ayu_plan", plan)
    return plan


def _present(value, mode):
    if value is None:
        return False
    if mode == "?z":
        return value != 0
    if mode == "?e":
        return len(value) > 0
    return True


def _write_value(stream, code, value, where, depth):
    if code == "#":
        stream.writeInt32(value)
    elif code == "i":
        stream.writeInt32(_field_integer(value, 32, where))
    elif code == "l":
        stream.writeInt64(_field_integer(value, 64, where))
    elif code == "d":
        if type(value) not in (int, float):
            raise TypeError(f"{where} must be a number")
        stream.writeDouble(value)
    elif code == "s":
        if not isinstance(value, str):
            raise TypeError(f"{where} must be a String, not {type(value).__name__}")
        stream.writeString(value)
    elif code == "y":
        stream.writeByteArray(as_bytes(value, where))
    elif code == "B":
        stream.writeBool(value)
    elif code in "qQ":
        data = as_bytes(value, where)
        if len(data) != (16 if code == "q" else 32):
            raise ValueError(f"{where} has the wrong length")
        stream.writeBytes(data)
    elif code == "o":
        if not _is_local(value):
            raise TypeError(f"{where} must be a local TLObject, not {type(value).__name__}")
        value._serialize(stream, depth + 1)
    elif code[0] == "V":
        if value is None or isinstance(value, (str, bytes)):
            raise TypeError(f"{where} must be a list")
        items = list(value)
        stream.writeInt32(VECTOR)
        stream.writeInt32(len(items))
        for item in items:
            _write_value(stream, code[1:], item, where, depth)
    else:
        raise _unsupported(f"{where} has no TL encoding")


def _read_value(stream, code, depth):
    if code == "i" or code == "#":
        return stream.readInt32(True)
    if code == "l":
        return stream.readInt64(True)
    if code == "d":
        return stream.readDouble(True)
    if code == "s":
        return stream.readString(True)
    if code == "y":
        return stream.readByteArray(True)
    if code == "B":
        return stream.readBool(True)
    if code in "qQ":
        return stream.readData(16 if code == "q" else 32, True)
    if code == "o":
        return _read_object(stream, stream.readInt32(True), depth + 1)
    if code[0] == "V":
        constructor = stream.readInt32(True) & 0xFFFFFFFF
        if constructor != VECTOR:
            raise TLParseException(f"can't parse magic {constructor:x} in Vector")
        count = stream.readInt32(True)
        if count < 0 or count > stream.remaining():
            raise TLParseException("Vector size exceeds the remaining data")
        return _array_list([_read_value(stream, code[1:], depth) for _ in range(count)])
    raise _unsupported("TL field has no decoding")


def _read_object(stream, constructor, depth, expected=None):
    if depth > MAX_DEPTH:
        raise TLParseException("TL nesting exceeds its limit")
    cls = _BY_ID.get(constructor & 0xFFFFFFFF)
    if cls is None or expected is not None and not issubclass(cls, expected):
        owner = "TLObject" if expected is None else expected.__name__
        raise TLParseException(f"can't parse magic {constructor & 0xFFFFFFFF:x} in {owner}")
    instance = cls()
    instance._read(stream, depth)
    return instance


class _TLMeta(type):
    """``isinstance`` that answers for the host's ``TLRPC$User``/``TLRPC$Chat`` snapshot handles.

    A handle is an instance of the snapshot's own class and of its bases, as on Android, and of
    no unrelated class. Which concrete subclass it is (``TL_channel``, ``TL_userEmpty``) is not
    known, so that question raises instead of answering no.
    """

    def __instancecheck__(cls, instance):
        if type.__instancecheck__(cls, instance):
            return True
        if type(instance).__name__ != "RemoteObject":
            return False
        snapshot = _SNAPSHOT_CLASSES.get(getattr(instance, "_class_name", None))
        if snapshot is None:
            return False
        if issubclass(snapshot, cls):
            return True
        if issubclass(cls, snapshot):
            raise _bridge().UnsupportedAPI(
                f"The host's {snapshot.__name__} snapshot does not tell whether it is a {cls.__name__}")
        return False


_SNAPSHOT_CLASSES = {}


class TLObject(metaclass=_TLMeta):
    """``org.telegram.tgnet.TLObject``."""
    _ayu_java_name = PACKAGE + "TLObject"
    _ayu_own = "networkType:i disableFree:b"
    _ayu_result = None

    def __init__(self):
        plan = _plan(type(self))
        values = self.__dict__
        values.update(plan.immutable)
        for name, factory in plan.factories:
            values[name] = factory()

    def __setattr__(self, name, value):
        if name not in _plan(type(self)).names and not name.startswith("_"):
            raise AttributeError(f"{type(self).__name__} has no field {name}")
        object.__setattr__(self, name, value)

    def __getattr__(self, name):
        raise _unsupported(f"{type(self).__name__} has no member {name}")

    def __repr__(self):
        return f"<{_class_name(type(self)).rpartition('.')[2].replace('$', '.')}>"

    def _flags(self, plan):
        """Flag words as Android writes them; the object's fields are updated like Java's."""
        values = self.__dict__
        words = [values[name] & 0xFFFFFFFF if type(values[name]) is int else 0 for name in plan.words]
        for word, mask, name, mode in plan.derived:
            on = bool(values[name]) if mode == "t" else _present(values[name], mode)
            words[word] = words[word] | mask if on else words[word] & ~mask
        for name, word in zip(plan.words, words):
            values[name] = _signed(word, 32)
        return words

    def _serialize(self, stream, depth):
        if depth > MAX_DEPTH:
            raise ValueError("TL nesting exceeds its limit")
        plan = _plan(type(self))
        if plan.wire is None:
            raise _unsupported(f"{type(self).__name__} has no TL layout")
        stream.writeInt32(self.constructor)
        words = self._flags(plan)
        values = self.__dict__
        for name, code, word, bit, _ in plan.wire:
            if code == "t" or word is not None and not words[word] >> bit & 1:
                continue
            _write_value(stream, code, values[name], f"{type(self).__name__}.{name}", depth)

    def _read(self, stream, depth):
        plan = _plan(type(self))
        if plan.wire is None:
            raise _unsupported(f"{type(self).__name__} has no TL layout")
        values, words = self.__dict__, []
        for name, code, word, bit, _ in plan.wire:
            if code == "#":
                values[name] = _read_value(stream, code, depth)
                words.append(values[name] & 0xFFFFFFFF)
            elif code == "t":
                values[name] = bool(words[word] >> bit & 1)
            elif word is None or words[word] >> bit & 1:
                values[name] = _read_value(stream, code, depth)

    def serializeToStream(self, stream):
        if not isinstance(stream, AbstractSerializedData):
            raise TypeError("serializeToStream needs a SerializedData or NativeByteBuffer")
        self._serialize(stream, 0)

    def readParams(self, stream, exception=False):
        if not isinstance(stream, AbstractSerializedData):
            raise TypeError("readParams needs a SerializedData or NativeByteBuffer")
        try:
            self._read(stream, 0)
        except TLParseException:
            if exception:
                raise

    def getObjectSize(self):
        stream = SerializedData(True)
        self._serialize(stream, 0)
        return stream.length()

    def freeResources(self):
        return None

    def deserializeResponse(self, stream, constructor, exception=False):
        """The response object of this request, as ``TLMethod.deserializeResponse`` returns it."""
        result = type(self)._ayu_result
        if result is None:
            return None
        try:
            return _read_result(result, stream, constructor)
        except TLParseException:
            if exception:
                raise
            return None

    @classmethod
    def TLdeserialize(cls, stream, constructor, exception=False):
        """The object for ``constructor`` when it is this class or one of its subclasses."""
        if not isinstance(stream, AbstractSerializedData) or type(constructor) is not int:
            raise TypeError("TLdeserialize(stream, constructor, exception)")
        try:
            return _read_object(stream, constructor, 0, None if cls is TLObject else cls)
        except TLParseException:
            if exception:
                raise
            return None

    def to_bridge(self):
        data = encode(self)
        if len(data) > MAX_SEND_BYTES:
            raise ValueError("TL object exceeds the size the host accepts")
        return {WIRE_KEY: base64.b64encode(data).decode("ascii")}


class Vector(TLObject):
    """``org.telegram.tgnet.Vector``: the response of a function that returns a bare TL vector."""
    _ayu_java_name = PACKAGE + "Vector"
    _ayu_own = "objects:A"
    constructor = _signed(VECTOR, 32)

    class Int(TLObject):
        _ayu_java_name = PACKAGE + "Vector$Int"
        _ayu_own = "value:i"

        def __init__(self, x=0):
            super().__init__()
            self.value = x

        def _serialize(self, stream, depth):
            stream.writeInt32(self.value)

        def _read(self, stream, depth):
            self.value = stream.readInt32(True)

    class Long(TLObject):
        _ayu_java_name = PACKAGE + "Vector$Long"
        _ayu_own = "value:l"

        def __init__(self, x=0):
            super().__init__()
            self.value = x

        def _serialize(self, stream, depth):
            stream.writeInt64(self.value)

        def _read(self, stream, depth):
            self.value = stream.readInt64(True)

    def _serialize(self, stream, depth):
        stream.writeInt32(VECTOR)
        stream.writeInt32(len(self.objects))
        for item in self.objects:
            if not _is_local(item):
                raise TypeError("Vector.objects must hold local TLObject values")
            item._serialize(stream, depth + 1)

    def _read(self, stream, depth, code="o"):
        count = stream.readInt32(True)
        if count < 0 or count > stream.remaining():
            raise TLParseException("Vector size exceeds the remaining data")
        for _ in range(count):
            if code == "i":
                item = Vector.Int(stream.readInt32(True))
            elif code == "l":
                item = Vector.Long(stream.readInt64(True))
            elif code == "o":
                item = _read_object(stream, stream.readInt32(True), depth + 1)
            else:
                item = _read_value(stream, code, depth)
            self.objects.append(item)

    def readParams(self, stream, exception=False, code="o"):
        try:
            self._read(stream, 0, code)
        except TLParseException:
            if exception:
                raise

    def toIntArray(self):
        return _array_list([item.value for item in self.objects if isinstance(item, Vector.Int)])

    def toLongArray(self):
        return _array_list([item.value for item in self.objects if isinstance(item, Vector.Long)])


def _read_result(result, stream, constructor):
    if result == "o":
        return _read_object(stream, constructor, 0)
    if constructor & 0xFFFFFFFF != VECTOR:
        raise TLParseException(f"can't parse magic {constructor & 0xFFFFFFFF:x} in Vector")
    vector = Vector()
    vector.readParams(stream, True, result[1:])
    return vector


def encode(value):
    """Boxed TL bytes of an object."""
    if not _is_local(value):
        raise TypeError(f"Expected a local TLObject, not {type(value).__name__}")
    stream = SerializedData()
    value._serialize(stream, 0)
    return stream.toByteArray()


def decode(data, expected=None):
    """The object of boxed TL bytes; trailing bytes are an error."""
    data = as_bytes(data, "TL data")
    if len(data) > MAX_OBJECT_BYTES:
        raise TLParseException("TL data exceeds the object size limit")
    stream = SerializedData(data)
    value = _read_object(stream, stream.readInt32(True), 0, expected)
    if stream.remaining():
        raise TLParseException("Trailing bytes after the TL object")
    return value


def decode_response(request, data):
    """The response of a TL function (its object or class) from boxed TL bytes: an object or a ``Vector``."""
    cls = request if isinstance(request, type) else type(request)
    if not is_function(cls):
        raise TypeError("Expected a TL function")
    data = as_bytes(data, "TL data")
    if len(data) > MAX_OBJECT_BYTES:
        raise TLParseException("TL data exceeds the object size limit")
    stream = SerializedData(data)
    value = _read_result(cls._ayu_result, stream, stream.readInt32(True))
    if stream.remaining():
        raise TLParseException("Trailing bytes after the TL response")
    return value


def _wire_bytes(value):
    if not isinstance(value, dict) or set(value) != {WIRE_KEY} or not isinstance(value[WIRE_KEY], str):
        raise _bridge().ProtocolError("Expected a TL wire value")
    try:
        return base64.b64decode(value[WIRE_KEY], validate=True)
    except ValueError:
        raise _bridge().ProtocolError("TL wire value is not base64") from None


def from_bridge(value, expected=None):
    """Decode a host ``{"tl": base64}`` value; ``None`` stays ``None``."""
    if value is None:
        return None
    try:
        return decode(_wire_bytes(value), expected)
    except TLParseException as error:
        raise _bridge().ProtocolError(f"Host sent an undecodable TL object: {error}") from None


def response_from_bridge(request, value):
    if value is None:
        return None
    try:
        return decode_response(request, _wire_bytes(value))
    except TLParseException as error:
        raise _bridge().ProtocolError(f"Host sent an undecodable TL response: {error}") from None


def simple_name(cls):
    """``Class.getSimpleName()``, the name Android passes to request and update hooks."""
    return _class_name(cls).rpartition("$")[2].rpartition(".")[2]


def classes_named(name, substring=False):
    """Wire classes whose simple name equals (or contains) ``name``."""
    return [cls for cls in _BY_ID.values()
            if (name in simple_name(cls) if substring else simple_name(cls) == name)]


def is_function(cls):
    return isinstance(cls, type) and issubclass(cls, TLObject) and cls._ayu_result is not None


def class_for(constructor):
    return _BY_ID.get(constructor & 0xFFFFFFFF)


def _holder(java_name):
    return type(java_name.rpartition(".")[2], (), {"_ayu_java_name": java_name, "__module__": __name__,
                                                    "__doc__": "``" + java_name + "``."})


def _build():
    from . import _telegram_tl_schema as schema
    text = zlib.decompress(base64.b85decode(schema.TABLE)).decode("utf-8")
    rows = {}
    for line in text.split("\n"):
        if line:
            parts = line.split("|")
            rows[parts[0]] = parts + [""] * (7 - len(parts))
    root = _holder(PACKAGE + "TLRPC")
    for item in schema.CONSTANTS.split():
        name, _, value = item.partition("=")
        setattr(root, name, int(value))
    classes = {PACKAGE + "TLRPC": root}
    table = {}

    def owner(key):
        if not key.startswith("tl."):
            return root, PACKAGE + "TLRPC$" + key, key
        holder_name, _, nested = key[3:].partition("$")
        java_name = PACKAGE + "tl." + holder_name
        holder = classes.get(java_name)
        if holder is None:
            holder = classes[java_name] = _holder(java_name)
        return holder, java_name + "$" + nested, nested

    def create(key):
        cls = table.get(key)
        if cls is not None:
            return cls
        _, base, constructor, own, wire, result, constants = rows[key]
        holder, java_name, attribute = owner(key)
        namespace = {"__module__": __name__, "__qualname__": holder.__name__ + "." + attribute,
                     "_ayu_java_name": java_name, "_ayu_own": own}
        if constructor and wire != "-":
            namespace["_ayu_wire"] = wire
        if result:
            namespace["_ayu_result"] = result
        if constructor:
            namespace["constructor"] = _signed(int(constructor, 16), 32)
        snapshot = key in _HOST_SNAPSHOTS
        if snapshot:
            namespace["__ayu_overrides_host__"] = True
        for item in constants.split():
            name, _, value = item.partition("=")
            namespace[name] = int(value)
        cls = table[key] = type(attribute, (create(base) if base else TLObject,), namespace)
        if "_ayu_wire" in namespace:
            _BY_ID[int(constructor, 16)] = cls
        setattr(holder, attribute, cls)
        classes[java_name] = cls
        if snapshot:
            _SNAPSHOT_CLASSES[java_name] = cls
        return cls

    for key in rows:
        create(key)
    return classes, table


class RequestDelegate:
    """``org.telegram.tgnet.RequestDelegate``: implement ``run(response, error)``."""

    def run(self, response, error):
        raise NotImplementedError("RequestDelegate.run is not implemented")


class RequestDelegateTimestamp:
    """``org.telegram.tgnet.RequestDelegateTimestamp``: implement ``run(response, error, responseTime)``."""

    def run(self, response, error, responseTime):
        raise NotImplementedError("RequestDelegateTimestamp.run is not implemented")


class QuickAckDelegate:
    """``org.telegram.tgnet.QuickAckDelegate``: implement ``run()``."""

    def run(self):
        raise NotImplementedError("QuickAckDelegate.run is not implemented")


class WriteToSocketDelegate:
    """``org.telegram.tgnet.WriteToSocketDelegate``: implement ``run()``."""

    def run(self):
        raise NotImplementedError("WriteToSocketDelegate.run is not implemented")


CLASSES, _TABLE = _build()
TLRPC = CLASSES[PACKAGE + "TLRPC"]
CLASSES.update({
    PACKAGE + "TLObject": TLObject,
    PACKAGE + "Vector": Vector,
    PACKAGE + "Vector$Int": Vector.Int,
    PACKAGE + "Vector$Long": Vector.Long,
    PACKAGE + "TLParseException": TLParseException,
    PACKAGE + "AbstractSerializedData": AbstractSerializedData,
    PACKAGE + "SerializedData": SerializedData,
    PACKAGE + "NativeByteBuffer": NativeByteBuffer,
    PACKAGE + "RequestDelegate": RequestDelegate,
    PACKAGE + "RequestDelegateTimestamp": RequestDelegateTimestamp,
    PACKAGE + "QuickAckDelegate": QuickAckDelegate,
    PACKAGE + "WriteToSocketDelegate": WriteToSocketDelegate,
})
