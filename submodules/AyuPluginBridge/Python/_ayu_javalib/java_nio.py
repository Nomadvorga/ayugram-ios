"""``java.nio`` buffers, charsets, files and channels implemented in Python.

File access uses ordinary Python paths, as ``java_io`` and ``file_utils`` do.

Deliberate differences from a JVM:
- ``ByteBuffer.wrap`` shares a ``bytearray``; any other array argument is copied.
- Typed views (``asIntBuffer`` ...), memory mapping, file locks and ``java.util.stream``
  results (``Files.list``/``walk``/``lines``) are not provided.
"""
from __future__ import annotations

import codecs
import os
import struct
import sys

from . import returns
from . import java_io as _io
from . import java_lang as _l
from .java_lang import CharSequence, Comparable, Enum, IllegalArgumentException, NullPointerException, Object

BufferUnderflowException = _l._throwable("BufferUnderflowException", _l.RuntimeException)
BufferOverflowException = _l._throwable("BufferOverflowException", _l.RuntimeException)
ReadOnlyBufferException = _l._throwable("ReadOnlyBufferException", _l.UnsupportedOperationException)
InvalidMarkException = _l._throwable("InvalidMarkException", _l.IllegalStateException)
IllegalCharsetNameException = _l._throwable("IllegalCharsetNameException", IllegalArgumentException)
UnsupportedCharsetException = _l._throwable("UnsupportedCharsetException", IllegalArgumentException)
FileSystemException = _l._throwable("FileSystemException", _io.IOException)
NoSuchFileException = _l._throwable("NoSuchFileException", FileSystemException)
FileAlreadyExistsException = _l._throwable("FileAlreadyExistsException", FileSystemException)
DirectoryNotEmptyException = _l._throwable("DirectoryNotEmptyException", FileSystemException)
AccessDeniedException = _l._throwable("AccessDeniedException", FileSystemException)
NotDirectoryException = _l._throwable("NotDirectoryException", FileSystemException)
InvalidPathException = _l._throwable("InvalidPathException", IllegalArgumentException)
ClosedChannelException = _l._throwable("ClosedChannelException", _io.IOException)
NonReadableChannelException = _l._throwable("NonReadableChannelException", _l.IllegalStateException)
NonWritableChannelException = _l._throwable("NonWritableChannelException", _l.IllegalStateException)


class ByteOrder(Object):
    def __init__(self, name):
        self._name = name

    def toString(self):
        return self._name

    def __repr__(self):
        return self._name

    @staticmethod
    def nativeOrder():
        return ByteOrder.LITTLE_ENDIAN if sys.byteorder == "little" else ByteOrder.BIG_ENDIAN


ByteOrder.BIG_ENDIAN, ByteOrder.LITTLE_ENDIAN = ByteOrder("BIG_ENDIAN"), ByteOrder("LITTLE_ENDIAN")


class Buffer(Object):
    def capacity(self):
        return self._capacity

    def position(self, value=None):
        if value is None:
            return self._position
        if not 0 <= value <= self._limit:
            raise IllegalArgumentException(f"newPosition > limit: ({value} > {self._limit})" if value >= 0
                                           else f"newPosition < 0: ({value} < 0)")
        self._position = value
        if self._mark > value:
            self._mark = -1
        return self

    def limit(self, value=None):
        if value is None:
            return self._limit
        if not 0 <= value <= self._capacity:
            raise IllegalArgumentException(f"newLimit > capacity: ({value} > {self._capacity})" if value >= 0
                                           else f"newLimit < 0: ({value} < 0)")
        self._limit = value
        self._position = min(self._position, value)
        if self._mark > value:
            self._mark = -1
        return self

    def mark(self):
        self._mark = self._position
        return self

    def reset(self):
        if self._mark < 0:
            raise InvalidMarkException()
        self._position = self._mark
        return self

    def clear(self):
        self._position, self._limit, self._mark = 0, self._capacity, -1
        return self

    def flip(self):
        self._limit, self._position, self._mark = self._position, 0, -1
        return self

    def rewind(self):
        self._position, self._mark = 0, -1
        return self

    def remaining(self):
        return max(self._limit - self._position, 0)

    def hasRemaining(self):
        return self._position < self._limit

    def isReadOnly(self):
        return self._read_only


_FORMATS = {"Char": ("H", 2), "Short": ("h", 2), "Int": ("i", 4), "Long": ("q", 8), "Float": ("f", 4),
            "Double": ("d", 8)}


class ByteBuffer(Buffer, Comparable):
    def __init__(self, *args):
        raise _l.unsupported("Use ByteBuffer.allocate or ByteBuffer.wrap")

    @staticmethod
    def _make(data, offset, capacity, position=0, limit=None, read_only=False, direct=False):
        buffer = object.__new__(ByteBuffer)
        buffer._data, buffer._offset, buffer._capacity = data, offset, capacity
        buffer._position, buffer._limit, buffer._mark = position, capacity if limit is None else limit, -1
        buffer._read_only, buffer._direct, buffer._big = read_only, direct, True
        return buffer

    @staticmethod
    def allocate(capacity):
        if capacity < 0:
            raise IllegalArgumentException(f"capacity < 0: ({capacity} < 0)")
        return ByteBuffer._make(_l.ByteArray(capacity), 0, capacity)

    @staticmethod
    def allocateDirect(capacity):
        buffer = ByteBuffer.allocate(capacity)
        buffer._direct = True
        return buffer

    @staticmethod
    def wrap(array, offset=0, length=None):
        if array is None:
            raise NullPointerException()
        data = array if isinstance(array, bytearray) else _l.ByteArray(_l.to_bytes(array))
        length = len(data) - offset if length is None else length
        _l.check_range(offset, length, len(data))
        return ByteBuffer._make(data, 0, len(data), offset, offset + length)

    def _copy(self, **changes):
        buffer = ByteBuffer._make(self._data, self._offset, self._capacity, self._position, self._limit,
                                  self._read_only, self._direct)
        buffer._mark, buffer._big = self._mark, self._big
        for name, value in changes.items():
            setattr(buffer, name, value)
        return buffer

    def duplicate(self):
        return self._copy()

    def asReadOnlyBuffer(self):
        return self._copy(_read_only=True)

    def slice(self, *args):
        index, length = args if args else (self._position, self.remaining())
        _l.check_range(index, length, self._limit)
        return ByteBuffer._make(self._data, self._offset + index, length, 0, length, self._read_only, self._direct)

    def isDirect(self):
        return self._direct

    def hasArray(self):
        return not self._read_only and not self._direct

    def array(self):
        if self._read_only:
            raise ReadOnlyBufferException()
        if self._direct:
            raise _l.UnsupportedOperationException()
        return self._data

    def arrayOffset(self):
        self.array()
        return self._offset

    def order(self, order=None):
        if order is None:
            return ByteOrder.BIG_ENDIAN if self._big else ByteOrder.LITTLE_ENDIAN
        self._big = order is ByteOrder.BIG_ENDIAN
        return self

    def _writable(self):
        if self._read_only:
            raise ReadOnlyBufferException()

    def _next(self, size, error):
        if self._limit - self._position < size:
            raise error()
        start = self._offset + self._position
        self._position += size
        return start

    def _at(self, index, size):
        if index < 0 or index + size > self._limit:
            raise _l.IndexOutOfBoundsException(f"Index {index} out of bounds for length {self._limit}")
        return self._offset + index

    def get(self, *args):
        if not args:
            return _l.signed(self._data[self._next(1, BufferUnderflowException)], 8)
        if _l.is_int(args[0]) and len(args) == 1:
            return _l.signed(self._data[self._at(args[0], 1)], 8)
        if _l.is_int(args[0]):
            index, target, rest = args[0], args[1], args[2:]
            offset, length = rest if rest else (0, len(target))
            _l.check_range(offset, length, len(target))
            start = self._at(index, length)
        else:
            target, rest = args[0], args[1:]
            offset, length = rest if rest else (0, len(target))
            _l.check_range(offset, length, len(target))
            start = self._next(length, BufferUnderflowException)
        _l.fill_bytes(target, offset, bytes(self._data[start:start + length]))
        return self

    def put(self, *args):
        self._writable()
        first = args[0]
        if len(args) == 1 and _l.is_int(first):
            self._data[self._next(1, BufferOverflowException)] = first & 0xFF
        elif len(args) == 2 and _l.is_int(first) and _l.is_int(args[1]):
            self._data[self._at(first, 1)] = args[1] & 0xFF
        elif isinstance(first, ByteBuffer):
            if first is self:
                raise IllegalArgumentException("The source buffer is this buffer")
            data = bytes(first._data[first._offset + first._position:first._offset + first._limit])
            start = self._next(len(data), BufferOverflowException)
            first._position = first._limit
            self._data[start:start + len(data)] = data
        else:
            index = None
            if _l.is_int(first):
                index, args = first, args[1:]
            data = _io._slice(*args) if len(args) == 3 else _l.to_bytes(args[0])
            start = self._next(len(data), BufferOverflowException) if index is None else self._at(index, len(data))
            self._data[start:start + len(data)] = data
        return self

    def compact(self):
        self._writable()
        data = bytes(self._data[self._offset + self._position:self._offset + self._limit])
        self._data[self._offset:self._offset + len(data)] = data
        self._position, self._limit, self._mark = len(data), self._capacity, -1
        return self

    def _bytes(self):
        return bytes(self._data[self._offset + self._position:self._offset + self._limit])

    def __bytes__(self):
        return self._bytes()

    def __eq__(self, other):
        return isinstance(other, ByteBuffer) and self._bytes() == other._bytes()

    def __hash__(self):
        return hash(self._bytes())

    def hashCode(self):
        result = 1
        for item in reversed(self._bytes()):
            result = (31 * result + _l.signed(item, 8)) & 0xFFFFFFFF
        return _l.i32(result)

    def compareTo(self, other):
        mine, theirs = [_l.signed(item, 8) for item in self._bytes()], [_l.signed(item, 8) for item in other._bytes()]
        return (mine > theirs) - (mine < theirs)

    def toString(self):
        return f"java.nio.HeapByteBuffer[pos={self._position} lim={self._limit} cap={self._capacity}]"


def _typed(name, code, size):
    def getter(self, index=None):
        start = self._next(size, BufferUnderflowException) if index is None else self._at(index, size)
        value = struct.unpack((">" if self._big else "<") + code, bytes(self._data[start:start + size]))[0]
        return chr(value) if name == "Char" else value

    def setter(self, *args):
        self._writable()
        index, value = (None, args[0]) if len(args) == 1 else args
        if name == "Char":
            value = ord(value) if isinstance(value, str) else value & 0xFFFF
        elif name in ("Short", "Int", "Long"):
            value = _l.signed(value, size * 8)
        elif name == "Float":
            value = _l.to_float32(value)
        start = self._next(size, BufferOverflowException) if index is None else self._at(index, size)
        self._data[start:start + size] = struct.pack((">" if self._big else "<") + code, value)
        return self

    setattr(ByteBuffer, "get" + name, getter)
    setattr(ByteBuffer, "put" + name, setter)


for _name, (_code, _size) in _FORMATS.items():
    _typed(_name, _code, _size)


class CharBuffer(CharSequence):
    """The read-only text result of ``Charset.decode``."""

    def __init__(self, *args):
        raise _l.unsupported("Use CharBuffer.wrap")

    @staticmethod
    def wrap(text):
        buffer = object.__new__(CharBuffer)
        buffer._text = _l._text(text) if not isinstance(text, (list, tuple)) else _l.from_units("".join(text))
        return buffer

    def toString(self):
        return self._text

    def remaining(self):
        return _l.utf16_length(self._text)

    def hasRemaining(self):
        return bool(self._text)

    def array(self):
        return list(_l.units(self._text))


_CANONICAL = {"utf-8": "UTF-8", "utf-16-be": "UTF-16BE", "utf-16-le": "UTF-16LE", "iso8859-1": "ISO-8859-1",
              "ascii": "US-ASCII", "utf-32": "UTF-32", "utf-32-be": "UTF-32BE", "utf-32-le": "UTF-32LE"}


class Charset(Comparable):
    def __init__(self, *args):
        raise _l.unsupported("Use Charset.forName")

    @staticmethod
    def forName(name):
        if name is None:
            raise IllegalArgumentException("Null charset name")
        if not name or not all(char.isalnum() and char.isascii() or char in "-+.:_" for char in name):
            raise IllegalCharsetNameException(name)
        charset = object.__new__(Charset)
        if name.upper() in ("UTF-16", "UTF16"):
            charset._name = "UTF-16"
            return charset
        try:
            codec = codecs.lookup(name).name
        except LookupError:
            raise UnsupportedCharsetException(name) from None
        charset._name = _CANONICAL.get(codec) or (
            "windows-" + codec[2:] if codec.startswith("cp125") else codec.upper())
        return charset

    @staticmethod
    def isSupported(name):
        try:
            Charset.forName(name)
            return True
        except UnsupportedCharsetException:
            return False

    @staticmethod
    def defaultCharset():
        return StandardCharsets.UTF_8

    def name(self):
        return self._name

    def displayName(self, locale=None):
        return self._name

    def toString(self):
        return self._name

    def __repr__(self):
        return self._name

    def canEncode(self):
        return True

    def encode(self, text):
        return ByteBuffer.wrap(_l.encode_text(_l._text(text), self))

    def decode(self, buffer):
        text = _l.decode_bytes(buffer._bytes(), self)
        buffer.position(buffer.limit())
        return CharBuffer.wrap(text)

    def __eq__(self, other):
        return isinstance(other, Charset) and self._name == other._name

    def __hash__(self):
        return hash(self._name)

    def hashCode(self):
        return _l.string_hash(self._name)

    def compareTo(self, other):
        return _l.String(self._name.lower()).compareTo(other._name.lower())

    def to_bridge(self):
        return self._name


class StandardCharsets(Object):
    def __init__(self):
        raise _l.unsupported("java.nio.charset.StandardCharsets cannot be constructed")


for _field, _charset in (("UTF_8", "UTF-8"), ("UTF_16", "UTF-16"), ("UTF_16BE", "UTF-16BE"),
                         ("UTF_16LE", "UTF-16LE"), ("ISO_8859_1", "ISO-8859-1"), ("US_ASCII", "US-ASCII")):
    setattr(StandardCharsets, _field, Charset.forName(_charset))


# --- java.nio.file -------------------------------------------------------------------------

class StandardCopyOption(Enum):
    pass


class StandardOpenOption(Enum):
    pass


class LinkOption(Enum):
    pass


_l.enum_constants(StandardCopyOption, "REPLACE_EXISTING", "COPY_ATTRIBUTES", "ATOMIC_MOVE")
_l.enum_constants(StandardOpenOption, "READ", "WRITE", "APPEND", "TRUNCATE_EXISTING", "CREATE", "CREATE_NEW",
                  "DELETE_ON_CLOSE", "SPARSE", "SYNC", "DSYNC")
_l.enum_constants(LinkOption, "NOFOLLOW_LINKS")


def _path(value):
    if value is None:
        raise NullPointerException()
    if isinstance(value, Path):
        return value._path
    return _io.path_of(value)


def _file_error(error, path, other=None):
    import errno
    if isinstance(error, FileNotFoundError):
        return NoSuchFileException(path)
    if isinstance(error, FileExistsError):
        return FileAlreadyExistsException(other or path)
    if isinstance(error, PermissionError):
        return AccessDeniedException(path)
    if isinstance(error, NotADirectoryError):
        return NotDirectoryException(path)
    if getattr(error, "errno", None) == errno.ENOTEMPTY:
        return DirectoryNotEmptyException(path)
    reason = os.strerror(error.errno) if getattr(error, "errno", None) else str(error)
    return FileSystemException(f"{path}: {reason}")


class Path(Comparable):
    def __init__(self, *args):
        raise _l.unsupported("Use Paths.get or Path.of")

    @staticmethod
    def of(first, *more):
        path = object.__new__(Path)
        parts = [_io.path_of(first, "path")] + [_io.path_of(item, "path") for item in more]
        if any("\0" in part for part in parts):
            raise InvalidPathException("Nul character not allowed")
        path._path = _io._normalize("/".join(part for part in parts if part))
        return path

    def __fspath__(self):
        return self._path

    def toString(self):
        return self._path

    def __repr__(self):
        return self._path

    def __eq__(self, other):
        return isinstance(other, Path) and self._path == other._path

    def __hash__(self):
        return hash(self._path)

    def hashCode(self):
        return _l.string_hash(self._path)

    def compareTo(self, other):
        return _l.String(self._path).compareTo(other._path)

    def to_bridge(self):
        return self._path

    def _names(self):
        return [part for part in self._path.split("/") if part]

    def isAbsolute(self):
        return self._path.startswith("/")

    def getRoot(self):
        return Path.of("/") if self.isAbsolute() else None

    def getFileName(self):
        names = self._names()
        return Path.of(names[-1]) if names else (None if self._path == "/" else Path.of(""))

    def getParent(self):
        names = self._names()
        if not names or len(names) == 1 and not self.isAbsolute():
            return None
        return Path.of(("/" if self.isAbsolute() else "") + "/".join(names[:-1]))

    def getNameCount(self):
        return len(self._names())

    def getName(self, index):
        names = self._names()
        if not 0 <= index < len(names):
            raise IllegalArgumentException()
        return Path.of(names[index])

    def iterator(self):
        from . import java_util
        return java_util.Iterator([Path.of(name) for name in self._names()])

    def __iter__(self):
        return iter([Path.of(name) for name in self._names()])

    def resolve(self, other):
        other = _path(other)
        if other.startswith("/"):
            return Path.of(other)
        return Path.of(self._path, other) if other else self

    def resolveSibling(self, other):
        parent = self.getParent()
        return Path.of(_path(other)) if parent is None else parent.resolve(other)

    def relativize(self, other):
        other = Path.of(_path(other))
        if self.isAbsolute() != other.isAbsolute():
            raise IllegalArgumentException("'other' is different type of Path")
        mine, theirs = self._names(), other._names()
        common = 0
        while common < min(len(mine), len(theirs)) and mine[common] == theirs[common]:
            common += 1
        return Path.of("/".join([".."] * (len(mine) - common) + theirs[common:]))

    def normalize(self):
        result = []
        for name in self._names():
            if name == ".":
                continue
            if name == ".." and result and result[-1] != "..":
                result.pop()
            elif name != ".." or not self.isAbsolute():
                result.append(name)
        return Path.of(("/" if self.isAbsolute() else "") + "/".join(result))

    def toAbsolutePath(self):
        return self if self.isAbsolute() else Path.of(os.getcwd(), self._path)

    def toRealPath(self, *options):
        try:
            return Path.of(os.path.realpath(self._path, strict=True))
        except OSError as error:
            raise _file_error(error, self._path) from None

    def toFile(self):
        return _io.File(self._path)

    def toUri(self):
        return self.toAbsolutePath().toFile().toURI()

    def startsWith(self, other):
        other = Path.of(_path(other))
        names = other._names()
        return self.isAbsolute() == other.isAbsolute() and self._names()[:len(names)] == names and \
            (bool(names) or other.isAbsolute())

    def endsWith(self, other):
        other = Path.of(_path(other))
        names = other._names()
        if other.isAbsolute():
            return self == other
        return bool(names) and self._names()[-len(names):] == names


class Paths(Object):
    def __init__(self):
        raise _l.unsupported("java.nio.file.Paths cannot be constructed")

    @staticmethod
    def get(first, *more):
        if hasattr(type(first), "getScheme") and not more:
            return _io.File(first).toPath()
        return Path.of(first, *more)


def _has(options, option):
    return any(item is option for item in options)


def _lines(lines):
    return "".join(_l._text(line) + "\n" for line in lines)


class Files(Object):
    def __init__(self):
        raise _l.unsupported("java.nio.file.Files cannot be constructed")

    @staticmethod
    def exists(path, *options):
        return os.path.lexists(_path(path)) if _has(options, LinkOption.NOFOLLOW_LINKS) else os.path.exists(_path(path))

    @staticmethod
    def notExists(path, *options):
        return not Files.exists(path, *options)

    @staticmethod
    def isDirectory(path, *options):
        return os.path.isdir(_path(path))

    @staticmethod
    def isRegularFile(path, *options):
        return os.path.isfile(_path(path))

    @staticmethod
    def isSymbolicLink(path):
        return os.path.islink(_path(path))

    @staticmethod
    def isReadable(path):
        return os.access(_path(path), os.R_OK)

    @staticmethod
    def isWritable(path):
        return os.access(_path(path), os.W_OK)

    @staticmethod
    def isExecutable(path):
        return os.access(_path(path), os.X_OK)

    @staticmethod
    def isHidden(path):
        return os.path.basename(_path(path)).startswith(".")

    @staticmethod
    def isSameFile(first, second):
        try:
            return os.path.samefile(_path(first), _path(second))
        except OSError as error:
            raise _file_error(error, _path(first)) from None

    @staticmethod
    def size(path):
        try:
            return os.stat(_path(path)).st_size
        except OSError as error:
            raise _file_error(error, _path(path)) from None

    @staticmethod
    def _read(path):
        try:
            with open(_path(path), "rb") as stream:
                return stream.read()
        except OSError as error:
            raise _file_error(error, _path(path)) from None

    @staticmethod
    def readAllBytes(path):
        return _l.ByteArray(Files._read(path))

    @staticmethod
    def readString(path, charset=None):
        return _l.decode_bytes(Files._read(path), charset)

    @staticmethod
    def readAllLines(path, charset=None):
        from . import java_util
        import re
        text = _l.decode_bytes(Files._read(path), charset)
        lines = re.split(r"\r\n|\r|\n", text)
        if lines and lines[-1] == "":
            lines.pop()
        return java_util.ArrayList(lines)

    @staticmethod
    def _mode(options, default="wb"):
        options = [item for item in options if isinstance(item, StandardOpenOption)]
        if _has(options, StandardOpenOption.DELETE_ON_CLOSE):
            raise _l.unsupported("StandardOpenOption.DELETE_ON_CLOSE is not supported")
        if not options:
            return default
        if _has(options, StandardOpenOption.CREATE_NEW):
            return "xb"
        if _has(options, StandardOpenOption.APPEND):
            return "ab" if _has(options, StandardOpenOption.CREATE) else "r+b:append"
        if _has(options, StandardOpenOption.TRUNCATE_EXISTING):
            return "wb" if _has(options, StandardOpenOption.CREATE) else "r+b:truncate"
        return "r+b:create" if _has(options, StandardOpenOption.CREATE) else "r+b"

    @staticmethod
    def _open(path, options, default="wb"):
        path, mode = _path(path), Files._mode(options, default)
        try:
            if mode == "r+b:create":
                return os.fdopen(os.open(path, os.O_RDWR | os.O_CREAT, 0o666), "r+b")
            stream = open(path, mode.split(":")[0])
            if mode.endswith(":append"):
                stream.seek(0, os.SEEK_END)
            elif mode.endswith(":truncate"):
                stream.truncate(0)
            return stream
        except OSError as error:
            raise _file_error(error, path) from None

    @staticmethod
    def write(path, data, *options):
        if isinstance(data, str):
            raise TypeError("Files.write takes bytes or lines; use Files.writeString for text")
        charset = next((item for item in options if isinstance(item, Charset)), None)
        payload = _l.to_bytes(data) if isinstance(data, (bytes, bytearray, memoryview)) or \
            isinstance(data, (list, tuple)) and all(_l.is_int(item) for item in data) and data else \
            bytes(_l.encode_text(_lines(data), charset))[2 if _l._is_utf16(charset) else 0:]
        with Files._open(path, options) as stream:
            try:
                stream.write(payload)
            except OSError as error:
                raise _file_error(error, _path(path)) from None
        return path if isinstance(path, Path) else Path.of(_path(path))

    @staticmethod
    def writeString(path, text, *options):
        charset = next((item for item in options if isinstance(item, Charset)), None)
        return Files.write(path, bytes(_l.encode_text(_l._text(text), charset)), *options)

    @staticmethod
    def newInputStream(path, *options):
        try:
            return _io._FileSource(open(_path(path), "rb"))
        except OSError as error:
            raise _file_error(error, _path(path)) from None

    @staticmethod
    def newOutputStream(path, *options):
        return _PathOutput(Files._open(path, options))

    @staticmethod
    def newBufferedReader(path, charset=None):
        return _io.BufferedReader(_io.InputStreamReader(Files.newInputStream(path), charset))

    @staticmethod
    def newBufferedWriter(path, *options):
        charset = next((item for item in options if isinstance(item, Charset)), None)
        return _io.BufferedWriter(_io.OutputStreamWriter(Files.newOutputStream(path, *options), charset))

    @staticmethod
    def copy(source, target, *options):
        import shutil
        if isinstance(source, _io.InputStream):
            path = _path(target)
            if os.path.lexists(path) and not _has(options, StandardCopyOption.REPLACE_EXISTING):
                raise FileAlreadyExistsException(path)
            try:
                with open(path, "wb") as stream:
                    return source.transferTo(_PathOutput(stream, close=False))
            except OSError as error:
                raise _file_error(error, path) from None
        if isinstance(target, _io.OutputStream):
            with Files.newInputStream(source) as stream:
                return stream.transferTo(target)
        origin, destination = _path(source), _path(target)
        try:
            if os.path.lexists(destination):
                if not _has(options, StandardCopyOption.REPLACE_EXISTING):
                    raise FileAlreadyExistsException(destination)
                if os.path.isdir(destination) and not os.path.islink(destination):
                    os.rmdir(destination)
                else:
                    os.remove(destination)
            if os.path.isdir(origin):
                os.mkdir(destination)
            elif _has(options, StandardCopyOption.COPY_ATTRIBUTES):
                shutil.copy2(origin, destination)
            else:
                shutil.copyfile(origin, destination)
        except OSError as error:
            raise _file_error(error, origin if not os.path.lexists(origin) else destination) from None
        return target if isinstance(target, Path) else Path.of(destination)

    @staticmethod
    def move(source, target, *options):
        origin, destination = _path(source), _path(target)
        try:
            if os.path.lexists(destination) and not _has(options, StandardCopyOption.REPLACE_EXISTING) and \
                    not _has(options, StandardCopyOption.ATOMIC_MOVE):
                raise FileAlreadyExistsException(destination)
            os.replace(origin, destination)
        except OSError as error:
            raise _file_error(error, origin if not os.path.lexists(origin) else destination) from None
        return target if isinstance(target, Path) else Path.of(destination)

    @staticmethod
    def delete(path):
        path = _path(path)
        try:
            if os.path.isdir(path) and not os.path.islink(path):
                os.rmdir(path)
            else:
                os.remove(path)
        except OSError as error:
            raise _file_error(error, path) from None

    @staticmethod
    def deleteIfExists(path):
        try:
            Files.delete(path)
            return True
        except NoSuchFileException:
            return False

    @staticmethod
    def createFile(path, *attributes):
        try:
            os.close(os.open(_path(path), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o666))
        except OSError as error:
            raise _file_error(error, _path(path)) from None
        return path if isinstance(path, Path) else Path.of(_path(path))

    @staticmethod
    def createDirectory(path, *attributes):
        try:
            os.mkdir(_path(path))
        except OSError as error:
            raise _file_error(error, _path(path)) from None
        return path if isinstance(path, Path) else Path.of(_path(path))

    @staticmethod
    def createDirectories(path, *attributes):
        target = _path(path)
        try:
            os.makedirs(target, exist_ok=True)
        except OSError as error:
            raise _file_error(error, target) from None
        return path if isinstance(path, Path) else Path.of(target)

    @staticmethod
    def createTempFile(*args):
        import tempfile
        directory = _path(args[0]) if isinstance(args[0], (Path, _io.File)) else None
        prefix, suffix = (args[1], args[2]) if directory is not None else (args[0], args[1])
        try:
            handle, name = tempfile.mkstemp(suffix if suffix is not None else ".tmp", prefix or "", directory)
        except OSError as error:
            raise _file_error(error, directory or tempfile.gettempdir()) from None
        os.close(handle)
        return Path.of(name)

    @staticmethod
    def createTempDirectory(*args):
        import tempfile
        directory = _path(args[0]) if isinstance(args[0], (Path, _io.File)) else None
        prefix = args[1] if directory is not None else args[0]
        try:
            return Path.of(tempfile.mkdtemp(prefix=prefix or "", dir=directory))
        except OSError as error:
            raise _file_error(error, directory or tempfile.gettempdir()) from None

    @staticmethod
    def list(path):
        raise _l.unsupported("java.util.stream is not supported; use File.listFiles()")

    walk = lines = find = list


class _PathOutput(_io.OutputStream):
    def __init__(self, raw, close=True):
        self._raw, self._owned = raw, close

    def _write(self, data):
        self._raw.write(data)

    def _flush(self):
        self._raw.flush()

    def _close(self):
        if self._owned:
            self._raw.close()


# --- java.nio.channels ---------------------------------------------------------------------

class Channel(_io.Closeable):
    _open = True

    def isOpen(self):
        return self._open

    def _check(self):
        if not self._open:
            raise ClosedChannelException()

    def read(self, buffer):
        self._check()
        if not isinstance(buffer, ByteBuffer):
            raise TypeError("Expected a Python-local java.nio.ByteBuffer")
        buffer._writable()
        if not buffer.hasRemaining():
            return 0
        data = self._read_bytes(buffer.remaining())
        if not data:
            return -1
        buffer.put(data)
        return len(data)

    def write(self, buffer):
        self._check()
        if not isinstance(buffer, ByteBuffer):
            raise TypeError("Expected a Python-local java.nio.ByteBuffer")
        data = buffer._bytes()
        self._write_bytes(data)
        buffer.position(buffer.limit())
        return len(data)

    def close(self):
        if self._open:
            self._open = False
            self._close()


class _StreamChannel(Channel):
    def __init__(self, stream):
        self._stream = stream

    def _read_bytes(self, size):
        if not isinstance(self._stream, _io.InputStream):
            raise NonReadableChannelException()
        return self._stream._take(size)

    def _write_bytes(self, data):
        if not isinstance(self._stream, _io.OutputStream):
            raise NonWritableChannelException()
        self._stream.write(data)

    def _close(self):
        self._stream.close()


class FileChannel(Channel):
    def __init__(self, *args):
        raise _l.unsupported("Use getChannel() of a file stream or FileChannel.open")

    @staticmethod
    def _of(raw, readable, writable):
        channel = object.__new__(FileChannel)
        channel._raw, channel._readable, channel._writable = raw, readable, writable
        return channel

    @staticmethod
    def open(path, *options):
        options = [item for item in options if isinstance(item, StandardOpenOption)]
        writable = any(item in (StandardOpenOption.WRITE, StandardOpenOption.APPEND) for item in options)
        if not writable:
            try:
                return FileChannel._of(open(_path(path), "rb"), True, False)
            except OSError as error:
                raise _file_error(error, _path(path)) from None
        readable = _has(options, StandardOpenOption.READ)
        return FileChannel._of(Files._open(path, options, "r+b"), readable, True)

    def _call(self, function, *args):
        self._check()
        try:
            return function(*args)
        except ValueError:
            raise ClosedChannelException() from None
        except OSError as error:
            raise _io.io_error(error) from None

    def _read_bytes(self, size):
        if not self._readable:
            raise NonReadableChannelException()
        return self._call(self._raw.read, size)

    def _write_bytes(self, data):
        if not self._writable:
            raise NonWritableChannelException()
        self._call(self._raw.write, data)

    def size(self):
        if self._writable:
            self._call(self._raw.flush)
        return self._call(lambda: os.fstat(self._raw.fileno()).st_size)

    def position(self, value=None):
        if value is None:
            return self._call(self._raw.tell)
        if value < 0:
            raise IllegalArgumentException("Negative position")
        self._call(self._raw.seek, value)
        return self

    def _at(self, position, function):
        if position < 0:
            raise IllegalArgumentException("Negative position")
        saved = self.position()
        self.position(position)
        try:
            return function()
        finally:
            self.position(saved)

    def read(self, buffer, position=None):
        if position is None:
            return Channel.read(self, buffer)
        return self._at(position, lambda: Channel.read(self, buffer))

    def write(self, buffer, position=None):
        if position is None:
            return Channel.write(self, buffer)
        return self._at(position, lambda: Channel.write(self, buffer))

    def truncate(self, size):
        if not self._writable:
            raise NonWritableChannelException()
        if size < 0:
            raise IllegalArgumentException("Negative size")
        if size < self.size():
            position = self.position()
            self._call(self._raw.truncate, size)
            self.position(min(position, size))
        return self

    def force(self, metadata):
        if self._writable:
            self._call(self._raw.flush)
            self._call(lambda: os.fsync(self._raw.fileno()))

    def transferTo(self, position, count, target):
        if not isinstance(target, Channel):
            raise TypeError("Expected a Python-local channel")
        if position < 0 or count < 0:
            raise IllegalArgumentException()

        def copy():
            total = 0
            while total < count:
                data = self._read_bytes(min(65536, count - total))
                if not data:
                    break
                target._check()
                target._write_bytes(data)
                total += len(data)
            return total

        return self._at(position, copy)

    def transferFrom(self, source, position, count):
        if not isinstance(source, Channel):
            raise TypeError("Expected a Python-local channel")
        if position < 0 or count < 0:
            raise IllegalArgumentException()
        if position > self.size():
            return 0

        def copy():
            total = 0
            while total < count:
                source._check()
                data = source._read_bytes(min(65536, count - total))
                if not data:
                    break
                self._write_bytes(data)
                total += len(data)
            return total

        return self._at(position, copy)

    def map(self, *args):
        raise _l.unsupported("Memory-mapped files are not supported")

    def lock(self, *args):
        raise _l.unsupported("File locks are not supported")

    tryLock = lock

    def _close(self):
        try:
            self._raw.close()
        except OSError as error:
            raise _io.io_error(error) from None


class _ChannelInput(_io.InputStream):
    def __init__(self, channel):
        self._channel = channel

    def _read(self, size):
        self._channel._check()
        return self._channel._read_bytes(size)

    def _close(self):
        self._channel.close()


class _ChannelOutput(_io.OutputStream):
    def __init__(self, channel):
        self._channel = channel

    def _write(self, data):
        self._channel._check()
        self._channel._write_bytes(data)

    def _close(self):
        self._channel.close()


class Channels(Object):
    def __init__(self):
        raise _l.unsupported("java.nio.channels.Channels cannot be constructed")

    @staticmethod
    def newChannel(stream):
        if isinstance(stream, _io.FileInputStream):
            return stream.getChannel()
        if isinstance(stream, _io.FileOutputStream):
            return stream.getChannel()
        if not isinstance(stream, (_io.InputStream, _io.OutputStream)):
            raise TypeError("Expected a Python-local java.io stream")
        return _StreamChannel(stream)

    @staticmethod
    def newInputStream(channel):
        return _ChannelInput(channel)

    @staticmethod
    def newOutputStream(channel):
        return _ChannelOutput(channel)


@returns(ByteBuffer)
def _allocate(capacity):
    return ByteBuffer.allocate(capacity)


@returns(ByteBuffer)
def _allocate_direct(capacity):
    return ByteBuffer.allocateDirect(capacity)


# A buffer a plugin allocates is its own memory: the Python-local class, even where the host adapts ``ByteBuffer``
# for the buffers it wraps. It cannot be passed to a host member.
HOST_MEMBERS = {"java.nio.ByteBuffer": {"allocate": _allocate, "allocateDirect": _allocate_direct}}

CLASSES = _l.register({
    "java.nio.Buffer": Buffer,
    "java.nio.ByteBuffer": ByteBuffer,
    "java.nio.CharBuffer": CharBuffer,
    "java.nio.ByteOrder": ByteOrder,
    "java.nio.BufferUnderflowException": BufferUnderflowException,
    "java.nio.BufferOverflowException": BufferOverflowException,
    "java.nio.ReadOnlyBufferException": ReadOnlyBufferException,
    "java.nio.InvalidMarkException": InvalidMarkException,
    "java.nio.charset.Charset": Charset,
    "java.nio.charset.StandardCharsets": StandardCharsets,
    "java.nio.charset.IllegalCharsetNameException": IllegalCharsetNameException,
    "java.nio.charset.UnsupportedCharsetException": UnsupportedCharsetException,
    "java.nio.file.Path": Path,
    "java.nio.file.Paths": Paths,
    "java.nio.file.Files": Files,
    "java.nio.file.StandardCopyOption": StandardCopyOption,
    "java.nio.file.StandardOpenOption": StandardOpenOption,
    "java.nio.file.LinkOption": LinkOption,
    "java.nio.file.FileSystemException": FileSystemException,
    "java.nio.file.NoSuchFileException": NoSuchFileException,
    "java.nio.file.FileAlreadyExistsException": FileAlreadyExistsException,
    "java.nio.file.DirectoryNotEmptyException": DirectoryNotEmptyException,
    "java.nio.file.AccessDeniedException": AccessDeniedException,
    "java.nio.file.NotDirectoryException": NotDirectoryException,
    "java.nio.file.InvalidPathException": InvalidPathException,
    "java.nio.channels.Channel": Channel,
    "java.nio.channels.ReadableByteChannel": Channel,
    "java.nio.channels.WritableByteChannel": Channel,
    "java.nio.channels.FileChannel": FileChannel,
    "java.nio.channels.Channels": Channels,
    "java.nio.channels.ClosedChannelException": ClosedChannelException,
    "java.nio.channels.NonReadableChannelException": NonReadableChannelException,
    "java.nio.channels.NonWritableChannelException": NonWritableChannelException,
})
