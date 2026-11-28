"""``java.io`` (and the ``java.util.zip`` stream classes) implemented in Python.

Paths are ordinary Python paths, exactly as in ``file_utils``: enabled plugins are
trusted application code and there is no fabricated Android directory layout.
Failures surface as Java's ``IOException`` family (or the ``false``/``null`` results
``java.io.File`` documents), never as success.

Deliberate differences from a JVM:
- ``byte[]`` buffers are ``bytearray``/``list``; a host-owned array cannot be filled.
- ``File.deleteOnExit`` and Java object serialization are not provided.
- ``ZipInputStream``/``ZipOutputStream`` spool the archive (in memory up to 8 MiB, then in
  a temporary file) because the zip directory needs a seekable source.
"""
from __future__ import annotations

import codecs
import io
import os
import struct
import sys

from . import java_lang as _l
from .java_lang import AutoCloseable, Comparable, NullPointerException, Object, jstr

IOException = _l._throwable("IOException", _l.Exception_)
FileNotFoundException = _l._throwable("FileNotFoundException", IOException)
EOFException = _l._throwable("EOFException", IOException)
UnsupportedEncodingException = _l._throwable("UnsupportedEncodingException", IOException)
UTFDataFormatException = _l._throwable("UTFDataFormatException", IOException)
InterruptedIOException = _l._throwable("InterruptedIOException", IOException)
UncheckedIOException = _l._throwable("UncheckedIOException", _l.RuntimeException)
ZipException = _l._throwable("ZipException", IOException)


def io_error(error, path=None):
    """The Java exception for a Python ``OSError``."""
    reason = os.strerror(error.errno) if getattr(error, "errno", None) else (str(error) or type(error).__name__)
    if path is not None:
        return FileNotFoundException(f"{path} ({reason})")
    return IOException(reason)


def path_of(value, what="path"):
    """Filesystem path string of a ``File``, ``Path`` or string argument."""
    if value is None:
        raise NullPointerException(what + " is null")
    if isinstance(value, File):
        return value.getPath()
    if isinstance(value, str):
        return str.__str__(value)
    if hasattr(type(value), "__fspath__"):
        return os.fspath(value)
    raise TypeError(f"Expected a file or path, got {type(value).__name__}")


class Closeable(AutoCloseable):
    pass


class Flushable(Object):
    def flush(self):
        raise _l.missing_member(type(self), "flush")


class Serializable(Object):
    pass


class FileFilter(Object):
    def accept(self, file):
        raise _l.missing_member(type(self), "accept")


class FilenameFilter(Object):
    def accept(self, directory, name):
        raise _l.missing_member(type(self), "accept")


def _normalize(path):
    if not path:
        return ""
    collapsed = "/" + "/".join(part for part in path.split("/") if part) if path.startswith("/") else \
        "/".join(part for part in path.split("/") if part)
    return collapsed


class File(Comparable):
    separator, separatorChar, pathSeparator, pathSeparatorChar = "/", "/", ":", ":"

    def __init__(self, *args):
        if len(args) == 1:
            if hasattr(type(args[0]), "getScheme") and hasattr(type(args[0]), "getPath"):
                if args[0].getScheme() != "file":
                    raise _l.IllegalArgumentException("URI scheme is not \"file\"")
                self._path = _normalize(args[0].getPath())
            else:
                self._path = _normalize(path_of(args[0], "pathname"))
        elif len(args) == 2:
            parent, child = args
            child = _normalize(path_of(child, "child"))
            if parent is None:
                self._path = child
            else:
                parent = _normalize(path_of(parent, "parent"))
                self._path = _normalize((parent or "/") + "/" + child) if child else parent
        else:
            raise TypeError("File takes (pathname) or (parent, child)")

    def __fspath__(self):
        return self._path

    def toString(self):
        return self._path

    def __repr__(self):
        return self._path

    def __eq__(self, other):
        return isinstance(other, File) and self._path == other._path

    def __hash__(self):
        return hash(self._path)

    def __lt__(self, other):
        return self._path < other._path

    def hashCode(self):
        return _l.string_hash(self._path) ^ 1234321

    def compareTo(self, other):
        return _l.String(self._path).compareTo(other.getPath())

    def to_bridge(self):
        return self._path

    def getPath(self):
        return self._path

    def getName(self):
        return self._path.rpartition("/")[2]

    def getParent(self):
        head, separator, _ = self._path.rpartition("/")
        if not separator:
            return None
        if not head:
            return "/" if self._path != "/" else None
        return head

    def getParentFile(self):
        parent = self.getParent()
        return None if parent is None else File(parent)

    def isAbsolute(self):
        return self._path.startswith("/")

    def getAbsolutePath(self):
        if self.isAbsolute():
            return self._path
        return _normalize(os.getcwd() + "/" + self._path)

    def getAbsoluteFile(self):
        return File(self.getAbsolutePath())

    def getCanonicalPath(self):
        try:
            return os.path.realpath(self.getAbsolutePath())
        except OSError as error:
            raise io_error(error) from None

    def getCanonicalFile(self):
        return File(self.getCanonicalPath())

    def toPath(self):
        from . import java_nio
        return java_nio.Paths.get(self._path)

    def toURI(self):
        from . import java_net
        path = self.getAbsolutePath()
        return java_net.URI("file", None, path + ("/" if self.isDirectory() and not path.endswith("/") else ""), None)

    def exists(self):
        return os.path.exists(self._path)

    def isFile(self):
        return os.path.isfile(self._path)

    def isDirectory(self):
        return os.path.isdir(self._path)

    def isHidden(self):
        return self.getName().startswith(".")

    def canRead(self):
        return os.access(self._path, os.R_OK)

    def canWrite(self):
        return os.access(self._path, os.W_OK)

    def canExecute(self):
        return os.access(self._path, os.X_OK)

    def length(self):
        try:
            return os.stat(self._path).st_size
        except OSError:
            return 0

    def lastModified(self):
        try:
            return os.stat(self._path).st_mtime_ns // 1_000_000
        except OSError:
            return 0

    def setLastModified(self, millis):
        if millis < 0:
            raise _l.IllegalArgumentException("Negative time")
        try:
            os.utime(self._path, ns=(os.stat(self._path).st_atime_ns, millis * 1_000_000))
            return True
        except OSError:
            return False

    def _chmod(self, bits, enable, owner_only):
        try:
            mode = os.stat(self._path).st_mode
            mask = bits & 0o700 if owner_only else bits
            os.chmod(self._path, mode | mask if enable else mode & ~mask)
            return True
        except OSError:
            return False

    def setReadable(self, readable, owner_only=True):
        return self._chmod(0o444, readable, owner_only)

    def setWritable(self, writable, owner_only=True):
        return self._chmod(0o222, writable, owner_only)

    def setExecutable(self, executable, owner_only=True):
        return self._chmod(0o111, executable, owner_only)

    def setReadOnly(self):
        return self._chmod(0o222, False, False)

    def createNewFile(self):
        try:
            os.close(os.open(self._path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o666))
            return True
        except FileExistsError:
            return False
        except OSError as error:
            raise io_error(error) from None

    def mkdir(self):
        try:
            os.mkdir(self._path)
            return True
        except OSError:
            return False

    def mkdirs(self):
        if os.path.exists(self._path):
            return False
        try:
            os.makedirs(self._path)
            return True
        except OSError:
            return False

    def delete(self):
        try:
            if os.path.isdir(self._path) and not os.path.islink(self._path):
                os.rmdir(self._path)
            else:
                os.remove(self._path)
            return True
        except OSError:
            return False

    def deleteOnExit(self):
        raise _l.unsupported("File.deleteOnExit is not supported: the host process outlives the plugin")

    def renameTo(self, target):
        if target is None:
            raise NullPointerException()
        try:
            os.rename(self._path, path_of(target))
            return True
        except OSError:
            return False

    def list(self, name_filter=None):
        try:
            names = sorted(os.listdir(self._path))
        except OSError:
            return None
        if name_filter is not None:
            names = [name for name in names if _l.call(name_filter, "accept", self, name)]
        return names

    def listFiles(self, file_filter=None):
        names = self.list()
        if names is None:
            return None
        files = [File(self, name) for name in names]
        if file_filter is None:
            return files
        import inspect
        try:
            arity = len(inspect.signature(file_filter if callable(file_filter) else file_filter.accept).parameters)
        except (TypeError, ValueError):
            arity = 1
        if arity >= 2:
            return [item for item in files if _l.call(file_filter, "accept", self, item.getName())]
        return [item for item in files if _l.call(file_filter, "accept", item)]

    def _space(self, field):
        try:
            stats = os.statvfs(self._path)
        except (OSError, AttributeError):
            return 0
        return stats.f_frsize * getattr(stats, field)

    def getTotalSpace(self):
        return self._space("f_blocks")

    def getFreeSpace(self):
        return self._space("f_bfree")

    def getUsableSpace(self):
        return self._space("f_bavail")

    @staticmethod
    def createTempFile(prefix, suffix=None, directory=None):
        import tempfile
        if prefix is None:
            raise NullPointerException()
        if len(prefix) < 3:
            raise _l.IllegalArgumentException("Prefix string \"" + prefix + "\" too short: length must be at least 3")
        try:
            handle, path = tempfile.mkstemp(".tmp" if suffix is None else suffix, prefix,
                                            None if directory is None else path_of(directory))
        except OSError as error:
            raise io_error(error) from None
        os.close(handle)
        return File(path)

    @staticmethod
    def listRoots():
        return [File("/")]


def _open(path, mode):
    try:
        return open(path, mode)
    except OSError as error:
        raise io_error(error, path) from None


def _slice(data, offset, count):
    if isinstance(data, (bytes, bytearray, memoryview)):
        _l.check_range(offset, count, len(data))
        return bytes(data[offset:offset + count])
    if isinstance(data, list):
        _l.check_range(offset, count, len(data))
        return _l.to_bytes(data[offset:offset + count])
    data = _l.to_bytes(data)
    _l.check_range(offset, count, len(data))
    return data[offset:offset + count]


# --- byte streams --------------------------------------------------------------------------

class InputStream(Closeable):
    """Subclasses supply ``_read(size)`` returning up to ``size`` bytes, ``b""`` at end of stream."""
    _closed = False
    _pushback = b""
    _marked = None
    _mark_limit = 0

    def _read(self, size):
        raise _l.missing_member(type(self), "read")

    def _available(self):
        return 0

    def _close(self):
        return None

    def _check(self):
        if self._closed:
            raise IOException("Stream closed")

    def _take(self, size):
        self._check()
        if self._pushback:
            data, self._pushback = self._pushback[:size], self._pushback[size:]
        else:
            try:
                data = self._read(size)
            except OSError as error:
                raise io_error(error) from None
        if self._marked is not None:
            self._marked += data
            if len(self._marked) > self._mark_limit:
                self._marked = None
        return data

    def read(self, *args):
        if not args:
            data = self._take(1)
            return data[0] if data else -1
        target = args[0]
        if target is None:
            raise NullPointerException()
        if len(args) == 3:
            offset, count = args[1], args[2]
        elif len(args) == 1:
            offset, count = 0, len(target)
        else:
            raise TypeError("read takes (), (buffer) or (buffer, offset, length)")
        _l.check_range(offset, count, len(target))
        if count == 0:
            return 0
        data = self._take(count)
        if not data:
            return -1
        _l.fill_bytes(target, offset, data)
        return len(data)

    def _drain(self, limit=None):
        chunks, total = [], 0
        while limit is None or total < limit:
            data = self._take(65536 if limit is None else min(65536, limit - total))
            if not data:
                break
            chunks.append(data)
            total += len(data)
        return b"".join(chunks)

    def readAllBytes(self):
        return _l.ByteArray(self._drain())

    def readNBytes(self, *args):
        if len(args) == 1:
            if args[0] < 0:
                raise _l.IllegalArgumentException("len < 0")
            return _l.ByteArray(self._drain(args[0]))
        target, offset, count = args
        _l.check_range(offset, count, len(target))
        data = self._drain(count)
        _l.fill_bytes(target, offset, data)
        return len(data)

    def skip(self, count):
        return len(self._drain(max(count, 0)))

    def available(self):
        self._check()
        return len(self._pushback) + self._available()

    def close(self):
        if not self._closed:
            self._closed = True
            try:
                self._close()
            except OSError as error:
                raise io_error(error) from None

    def markSupported(self):
        return False

    def mark(self, limit):
        if self.markSupported():
            self._marked, self._mark_limit = bytearray(), max(limit, 8192)

    def reset(self):
        self._check()
        if not self.markSupported():
            raise IOException("mark/reset not supported")
        if self._marked is None:
            raise IOException("Resetting to invalid mark")
        self._pushback = bytes(self._marked) + self._pushback
        self._marked = bytearray()

    def transferTo(self, output):
        total = 0
        while True:
            data = self._take(65536)
            if not data:
                return total
            output.write(data)
            total += len(data)


class FileInputStream(InputStream):
    def __init__(self, source):
        self._path = path_of(source, "file")
        self._file = _open(self._path, "rb")

    def _read(self, size):
        return self._file.read(size)

    def _available(self):
        try:
            return max(os.fstat(self._file.fileno()).st_size - self._file.tell(), 0)
        except OSError:
            return 0

    def _close(self):
        self._file.close()

    def getChannel(self):
        from . import java_nio
        self._check()
        return java_nio.FileChannel._of(self._file, readable=True, writable=False)

    def getFD(self):
        raise _l.unsupported("java.io.FileDescriptor is not supported")


class ByteArrayInputStream(InputStream):
    def __init__(self, data, offset=0, length=None):
        data = _l.to_bytes(data)
        offset = max(0, min(offset, len(data)))
        end = len(data) if length is None else min(offset + length, len(data))
        self._data, self._position, self._mark_position = data[:end], offset, offset

    def _check(self):
        return None

    def _read(self, size):
        data = self._data[self._position:self._position + size]
        self._position += len(data)
        return data

    def _available(self):
        return len(self._data) - self._position

    def markSupported(self):
        return True

    def mark(self, limit=0):
        self._mark_position = self._position

    def reset(self):
        self._position = self._mark_position


class FilterInputStream(InputStream):
    def __init__(self, source):
        if not isinstance(source, InputStream):
            raise TypeError("Expected a Python-local java.io.InputStream")
        self._source = source

    def _read(self, size):
        return self._source._take(size)

    def _available(self):
        return self._source.available()

    def _close(self):
        self._source.close()


class BufferedInputStream(FilterInputStream):
    def __init__(self, source, size=8192):
        if size <= 0:
            raise _l.IllegalArgumentException("Buffer size <= 0")
        FilterInputStream.__init__(self, source)

    def markSupported(self):
        return True


class DataInputStream(FilterInputStream):
    def readFully(self, target, offset=0, length=None):
        length = len(target) - offset if length is None else length
        _l.check_range(offset, length, len(target))
        data = self._drain(length)
        if len(data) < length:
            raise EOFException()
        _l.fill_bytes(target, offset, data)

    def _exact(self, size):
        data = self._drain(size)
        if len(data) < size:
            raise EOFException()
        return data

    def skipBytes(self, count):
        return self.skip(count)

    def readBoolean(self):
        return self._exact(1)[0] != 0

    def readByte(self):
        return struct.unpack(">b", self._exact(1))[0]

    def readUnsignedByte(self):
        return self._exact(1)[0]

    def readShort(self):
        return struct.unpack(">h", self._exact(2))[0]

    def readUnsignedShort(self):
        return struct.unpack(">H", self._exact(2))[0]

    def readChar(self):
        return chr(struct.unpack(">H", self._exact(2))[0])

    def readInt(self):
        return struct.unpack(">i", self._exact(4))[0]

    def readLong(self):
        return struct.unpack(">q", self._exact(8))[0]

    def readFloat(self):
        return struct.unpack(">f", self._exact(4))[0]

    def readDouble(self):
        return struct.unpack(">d", self._exact(8))[0]

    def readUTF(self):
        data = self._exact(self.readUnsignedShort())
        try:
            # Modified UTF-8: NUL is two bytes and supplementary characters are surrogate pairs.
            return _l.from_units(data.replace(b"\xc0\x80", b"\x00").decode("utf-8", "surrogatepass"))
        except UnicodeDecodeError:
            raise UTFDataFormatException("malformed input") from None


class OutputStream(Closeable, Flushable):
    """Subclasses supply ``_write(data)`` for a ``bytes`` chunk."""
    _closed = False

    def _write(self, data):
        raise _l.missing_member(type(self), "write")

    def _flush(self):
        return None

    def _close(self):
        return None

    def _check(self):
        if self._closed:
            raise IOException("Stream Closed")

    def _put(self, data):
        self._check()
        try:
            self._write(data)
        except OSError as error:
            raise io_error(error) from None

    def write(self, *args):
        if len(args) == 1:
            if args[0] is None:
                raise NullPointerException()
            self._put(bytes((args[0] & 0xFF,)) if _l.is_int(args[0]) else _l.to_bytes(args[0]))
        elif len(args) == 3:
            self._put(_slice(*args))
        else:
            raise TypeError("write takes (byte), (bytes) or (bytes, offset, length)")

    def flush(self):
        self._check()
        try:
            self._flush()
        except OSError as error:
            raise io_error(error) from None

    def close(self):
        if self._closed:
            return
        try:
            self._flush()
            self._close()
        except OSError as error:
            raise io_error(error) from None
        finally:
            self._closed = True


class FileOutputStream(OutputStream):
    def __init__(self, target, append=False):
        self._path = path_of(target, "file")
        self._file = _open(self._path, "ab" if append else "wb")

    def _write(self, data):
        self._file.write(data)

    def _flush(self):
        self._file.flush()

    def _close(self):
        self._file.close()

    def getChannel(self):
        from . import java_nio
        self._check()
        return java_nio.FileChannel._of(self._file, readable=False, writable=True)

    def getFD(self):
        raise _l.unsupported("java.io.FileDescriptor is not supported")


class ByteArrayOutputStream(OutputStream):
    def __init__(self, size=32):
        if size < 0:
            raise _l.IllegalArgumentException(f"Negative initial size: {size}")
        self._buffer = bytearray()

    def _check(self):
        return None

    def _write(self, data):
        self._buffer += data

    def writeBytes(self, data):
        self._buffer += _l.to_bytes(data)

    def writeTo(self, output):
        output.write(bytes(self._buffer))

    def toByteArray(self):
        return _l.ByteArray(self._buffer)

    def size(self):
        return len(self._buffer)

    def reset(self):
        del self._buffer[:]

    def toString(self, charset=None):
        return _l.decode_bytes(bytes(self._buffer), charset)

    def __len__(self):
        return len(self._buffer)


class FilterOutputStream(OutputStream):
    def __init__(self, target):
        if not isinstance(target, OutputStream):
            raise TypeError("Expected a Python-local java.io.OutputStream")
        self._target = target

    def _write(self, data):
        self._target.write(data)

    def _flush(self):
        self._target.flush()

    def _close(self):
        self._target.close()


class BufferedOutputStream(FilterOutputStream):
    def __init__(self, target, size=8192):
        if size <= 0:
            raise _l.IllegalArgumentException("Buffer size <= 0")
        FilterOutputStream.__init__(self, target)
        self._size, self._pending = size, bytearray()

    def _write(self, data):
        self._pending += data
        if len(self._pending) >= self._size:
            self._drain()

    def _drain(self):
        if self._pending:
            data = bytes(self._pending)
            del self._pending[:]
            self._target.write(data)

    def _flush(self):
        self._drain()
        self._target.flush()


class DataOutputStream(FilterOutputStream):
    def __init__(self, target):
        FilterOutputStream.__init__(self, target)
        self._written = 0

    def _write(self, data):
        self._target.write(data)
        self._written += len(data)

    def size(self):
        return min(self._written, _l.INT_MAX)

    def writeBoolean(self, value):
        self._put(b"\x01" if value else b"\x00")

    def writeByte(self, value):
        self._put(bytes((value & 0xFF,)))

    def writeShort(self, value):
        self._put(struct.pack(">H", value & 0xFFFF))

    def writeChar(self, value):
        self._put(struct.pack(">H", (ord(value) if isinstance(value, str) else value) & 0xFFFF))

    def writeInt(self, value):
        self._put(struct.pack(">I", value & 0xFFFFFFFF))

    def writeLong(self, value):
        self._put(struct.pack(">Q", value & 0xFFFFFFFFFFFFFFFF))

    def writeFloat(self, value):
        self._put(struct.pack(">f", _l.to_float32(value)))

    def writeDouble(self, value):
        self._put(struct.pack(">d", value))

    def writeBytes(self, text):
        self._put(bytes(ord(char) & 0xFF for char in _l.units(text)))

    def writeChars(self, text):
        self._put(text.encode("utf-16-be", "surrogatepass"))

    def writeUTF(self, text):
        data = _l.units(text).encode("utf-8", "surrogatepass").replace(b"\x00", b"\xc0\x80")
        if len(data) > 65535:
            raise UTFDataFormatException(f"encoded string too long: {len(data)} bytes")
        self._put(struct.pack(">H", len(data)) + data)


class ProcessStream(OutputStream):
    """The interpreter's ``stdout``/``stderr`` as a byte sink (``System.out``/``System.err``)."""

    def __init__(self, name):
        self._name, self._decoder = name, codecs.getincrementaldecoder("utf-8")("replace")

    def _write(self, data):
        getattr(sys, self._name).write(self._decoder.decode(data))

    def _flush(self):
        getattr(sys, self._name).flush()

    def close(self):
        return None


# --- character streams ---------------------------------------------------------------------

class Reader(Closeable):
    """Subclasses supply ``_read_text(size)`` returning up to ``size`` UTF-16 units, ``""`` at end."""
    _closed = False
    _pending = ""
    _marked = None

    def _read_text(self, size):
        raise _l.missing_member(type(self), "read")

    def _close(self):
        return None

    def _check(self):
        if self._closed:
            raise IOException("Stream closed")

    def _take(self, size):
        self._check()
        if not self._pending:
            try:
                self._pending = self._read_text(max(size, 1))
            except OSError as error:
                raise io_error(error) from None
        text, self._pending = self._pending[:size], self._pending[size:]
        if self._marked is not None:
            self._marked += text
        return text

    def read(self, *args):
        if not args:
            text = self._take(1)
            return ord(text) if text else -1
        target = args[0]
        if target is None:
            raise NullPointerException()
        offset, count = (args[1], args[2]) if len(args) == 3 else (0, len(target))
        _l.check_range(offset, count, len(target))
        if count == 0:
            return 0
        text = self._take(count)
        if not text:
            return -1
        if not isinstance(target, list):
            raise _l.unsupported("Expected a Python list as the char[] buffer")
        target[offset:offset + len(text)] = list(text)
        return len(text)

    def _all(self):
        parts = []
        while True:
            text = self._take(65536)
            if not text:
                return "".join(parts)
            parts.append(text)

    def skip(self, count):
        if count < 0:
            raise _l.IllegalArgumentException("skip value is negative")
        skipped = 0
        while skipped < count:
            text = self._take(min(65536, count - skipped))
            if not text:
                break
            skipped += len(text)
        return skipped

    def ready(self):
        self._check()
        return bool(self._pending)

    def markSupported(self):
        return False

    def mark(self, limit):
        if not self.markSupported():
            raise IOException("mark() not supported")
        self._marked = ""

    def reset(self):
        self._check()
        if not self.markSupported():
            raise IOException("reset() not supported")
        if self._marked is None:
            raise IOException("Mark invalid")
        self._pending, self._marked = self._marked + self._pending, ""

    def close(self):
        if not self._closed:
            self._closed = True
            try:
                self._close()
            except OSError as error:
                raise io_error(error) from None

    def transferTo(self, writer):
        text = self._all()
        writer.write(text)
        return len(text)


class StringReader(Reader):
    def __init__(self, text):
        self._text, self._position = _l.units(_l._text(text)), 0

    def _read_text(self, size):
        text = self._text[self._position:self._position + size]
        self._position += len(text)
        return text

    def markSupported(self):
        return True

    def ready(self):
        self._check()
        return True


class InputStreamReader(Reader):
    def __init__(self, source, charset=None):
        if not isinstance(source, InputStream):
            raise TypeError("Expected a Python-local java.io.InputStream")
        self._source, self._charset = source, charset
        # UTF-16 picks its byte order from the first bytes (big-endian without a mark).
        self._decoder = None if _l._is_utf16(charset) else codecs.getincrementaldecoder(
            _l.charset_name(charset))("replace")
        self._ended = False

    def getEncoding(self):
        return {"utf-8": "UTF8", "utf-16-be": "UTF-16", "iso8859-1": "ISO8859_1", "ascii": "ASCII"}.get(
            _l.charset_name(self._charset), _l.charset_name(self._charset).upper())

    def _read_text(self, size):
        while not self._ended:
            data = self._source._take(max(size, 4096))
            self._ended = not data
            if self._decoder is None:
                little = data[:2] == b"\xff\xfe"
                if little or data[:2] == b"\xfe\xff":
                    data = data[2:]
                self._decoder = codecs.getincrementaldecoder("utf-16-le" if little else "utf-16-be")("replace")
            text = self._decoder.decode(data, final=self._ended)
            if text:
                return _l.units(text)
        return ""

    def ready(self):
        self._check()
        return bool(self._pending) or self._source.available() > 0

    def _close(self):
        self._source.close()


class FileReader(InputStreamReader):
    def __init__(self, source, charset=None):
        InputStreamReader.__init__(self, FileInputStream(source), charset)


class BufferedReader(Reader):
    def __init__(self, source, size=8192):
        if not isinstance(source, Reader):
            raise TypeError("Expected a Python-local java.io.Reader")
        if size <= 0:
            raise _l.IllegalArgumentException("Buffer size <= 0")
        self._source = source

    def _read_text(self, size):
        return self._source._take(max(size, 8192))

    def markSupported(self):
        return True

    def ready(self):
        self._check()
        return bool(self._pending) or self._source.ready()

    def readLine(self):
        parts = []
        while True:
            text = self._take(8192)
            if not text:
                return _join_line(parts) if parts else None
            for index, char in enumerate(text):
                if char in "\r\n":
                    parts.append(text[:index])
                    rest = text[index + 1:]
                    if char == "\r":
                        if not rest:
                            rest = self._take(1)
                        if rest[:1] == "\n":
                            rest = rest[1:]
                    self._unread(rest)
                    return _join_line(parts)
            parts.append(text)

    def _unread(self, text):
        if text:
            self._pending = text + self._pending
            if self._marked is not None:
                self._marked = self._marked[:len(self._marked) - len(text)]

    def lines(self):
        raise _l.unsupported("java.util.stream is not supported; iterate the reader or call readLine()")

    def __iter__(self):
        while True:
            line = self.readLine()
            if line is None:
                return
            yield line

    def _close(self):
        self._source.close()


def _join_line(parts):
    return _l.from_units("".join(parts))


class LineNumberReader(BufferedReader):
    def __init__(self, source, size=8192):
        BufferedReader.__init__(self, source, size)
        self._line = 0

    def readLine(self):
        line = BufferedReader.readLine(self)
        if line is not None:
            self._line += 1
        return line

    def getLineNumber(self):
        return self._line

    def setLineNumber(self, number):
        self._line = number


class Writer(Closeable, Flushable):
    """Subclasses supply ``_write_text(text)``."""
    _closed = False

    def _write_text(self, text):
        raise _l.missing_member(type(self), "write")

    def _flush(self):
        return None

    def _close(self):
        return None

    def _check(self):
        if self._closed:
            raise IOException("Stream closed")

    def _put(self, text):
        self._check()
        try:
            self._write_text(text)
        except OSError as error:
            raise io_error(error) from None

    def write(self, *args):
        if not args or len(args) not in (1, 3):
            raise TypeError("write takes (char), (text) or (text, offset, length)")
        value = args[0]
        if value is None:
            raise NullPointerException()
        if _l.is_int(value):
            text = chr(value & 0xFFFF)
        elif isinstance(value, (list, tuple)):
            text = "".join(value)
        else:
            text = _l.units(_l._text(value))
        if len(args) == 3:
            _l.check_range(args[1], args[2], len(text))
            text = text[args[1]:args[1] + args[2]]
        self._put(_l.from_units(text))

    def append(self, value, *bounds):
        text = "null" if value is None else _l._text(value)
        if bounds:
            start, end = bounds
            text = _l.units(text)
            if start < 0 or start > end or end > len(text):
                raise _l.IndexOutOfBoundsException(f"start {start}, end {end}, length {len(text)}")
            text = _l.from_units(text[start:end])
        self._put(text)
        return self

    def flush(self):
        self._check()
        try:
            self._flush()
        except OSError as error:
            raise io_error(error) from None

    def close(self):
        if self._closed:
            return
        try:
            self._flush()
            self._close()
        except OSError as error:
            raise io_error(error) from None
        finally:
            self._closed = True


class StringWriter(Writer):
    def __init__(self, size=16):
        if size < 0:
            raise _l.IllegalArgumentException("Negative buffer size")
        self._buffer = _l.StringBuffer()

    def _check(self):
        return None

    def _write_text(self, text):
        self._buffer.append(text)

    def getBuffer(self):
        return self._buffer

    def toString(self):
        return self._buffer.toString()


class OutputStreamWriter(Writer):
    def __init__(self, target, charset=None):
        if not isinstance(target, OutputStream):
            raise TypeError("Expected a Python-local java.io.OutputStream")
        self._target, self._charset, self._started = target, charset, False
        _l.charset_name(charset)

    def getEncoding(self):
        return {"utf-8": "UTF8", "utf-16-be": "UTF-16", "iso8859-1": "ISO8859_1", "ascii": "ASCII"}.get(
            _l.charset_name(self._charset), _l.charset_name(self._charset).upper())

    def _write_text(self, text):
        data = bytes(_l.encode_text(text, self._charset))
        if _l._is_utf16(self._charset):
            # One byte order mark for the stream, not one per write.
            data = data[2:] if self._started else data
        self._started = True
        self._target.write(data)

    def _flush(self):
        self._target.flush()

    def _close(self):
        self._target.close()


class FileWriter(OutputStreamWriter):
    def __init__(self, target, *args):
        append = next((item for item in args if isinstance(item, bool)), False)
        charset = next((item for item in args if not isinstance(item, bool)), None)
        OutputStreamWriter.__init__(self, FileOutputStream(target, append), charset)


class BufferedWriter(Writer):
    def __init__(self, target, size=8192):
        if not isinstance(target, Writer):
            raise TypeError("Expected a Python-local java.io.Writer")
        if size <= 0:
            raise _l.IllegalArgumentException("Buffer size <= 0")
        self._target, self._size, self._parts, self._length = target, size, [], 0

    def _write_text(self, text):
        self._parts.append(text)
        self._length += len(text)
        if self._length >= self._size:
            self._drain()

    def _drain(self):
        if self._parts:
            text, self._parts, self._length = "".join(self._parts), [], 0
            self._target.write(text)

    def newLine(self):
        self._put("\n")

    def _flush(self):
        self._drain()
        self._target.flush()

    def _close(self):
        self._target.close()


class _Printing:
    """``print``/``println``/``printf`` shared by ``PrintStream`` and ``PrintWriter``.

    As in Java these never throw ``IOException``; ``checkError`` reports a failure.
    """
    _failed = False
    _autoflush = False

    def _emit(self, text):
        try:
            self._emit_text(text)
            if self._autoflush and "\n" in text:
                self._flush()
        except (IOException, OSError):
            self._failed = True

    def print(self, value):
        if isinstance(value, (list, tuple)) and value and all(isinstance(item, str) and len(item) == 1 for item in value):
            value = "".join(value)
        self._emit(jstr(value))

    def println(self, *value):
        if len(value) > 1:
            raise TypeError("println takes at most one value")
        if value:
            self.print(value[0])
        self._emit("\n")

    def printf(self, *args):
        if args and not isinstance(args[0], str) and len(args) > 1:
            args = args[1:]
        self._emit(_l.java_format(args[0], args[1:]))
        return self

    format = printf

    def checkError(self):
        try:
            if not self._closed:
                self._flush()
        except (IOException, OSError):
            self._failed = True
        return self._failed


def _sink(target, charset, binary):
    """The stream a ``PrintStream``/``PrintWriter`` constructor argument names."""
    if isinstance(target, OutputStream):
        return target if binary else OutputStreamWriter(target, charset)
    if isinstance(target, Writer) and not binary:
        return target
    stream = FileOutputStream(target)
    return stream if binary else OutputStreamWriter(stream, charset)


class PrintStream(_Printing, FilterOutputStream):
    def __init__(self, target, *args):
        self._autoflush = next((item for item in args if isinstance(item, bool)), False)
        self._charset = next((item for item in args if not isinstance(item, bool)), None)
        _l.charset_name(self._charset)
        FilterOutputStream.__init__(self, _sink(target, None, True))

    def _emit_text(self, text):
        self._put(bytes(_l.encode_text(text, self._charset))[2 if _l._is_utf16(self._charset) else 0:])

    def write(self, *args):
        try:
            FilterOutputStream.write(self, *args)
        except IOException:
            self._failed = True

    def flush(self):
        try:
            FilterOutputStream.flush(self)
        except IOException:
            self._failed = True

    def close(self):
        try:
            FilterOutputStream.close(self)
        except IOException:
            self._failed = True

    def append(self, value, *bounds):
        text = "null" if value is None else _l._text(value)
        self._emit(_l.from_units(_l.units(text)[bounds[0]:bounds[1]]) if bounds else text)
        return self


class PrintWriter(_Printing, Writer):
    def __init__(self, target, *args):
        self._autoflush = next((item for item in args if isinstance(item, bool)), False)
        charset = next((item for item in args if not isinstance(item, bool)), None)
        self._target = _sink(target, charset, False)

    def _write_text(self, text):
        self._target.write(text)

    def _emit_text(self, text):
        self._put(text)

    def _flush(self):
        self._target.flush()

    def _close(self):
        self._target.close()

    def write(self, *args):
        try:
            Writer.write(self, *args)
        except IOException:
            self._failed = True

    def flush(self):
        try:
            Writer.flush(self)
        except IOException:
            self._failed = True

    def close(self):
        try:
            Writer.close(self)
        except IOException:
            self._failed = True


class RandomAccessFile(Closeable):
    def __init__(self, target, mode):
        if mode not in ("r", "rw", "rws", "rwd"):
            raise _l.IllegalArgumentException(
                f'Illegal mode "{mode}" must be one of "r", "rw", "rws", or "rwd"')
        path = path_of(target, "file")
        if mode == "r":
            self._file = _open(path, "rb")
        else:
            try:
                self._file = os.fdopen(os.open(path, os.O_RDWR | os.O_CREAT, 0o666), "r+b")
            except OSError as error:
                raise io_error(error, path) from None
        self._writable = mode != "r"

    def _call(self, function, *args):
        try:
            return function(*args)
        except ValueError:
            raise IOException("Stream Closed") from None
        except OSError as error:
            raise io_error(error) from None

    def read(self, *args):
        if not args:
            data = self._call(self._file.read, 1)
            return data[0] if data else -1
        target = args[0]
        offset, count = (args[1], args[2]) if len(args) == 3 else (0, len(target))
        _l.check_range(offset, count, len(target))
        if count == 0:
            return 0
        data = self._call(self._file.read, count)
        if not data:
            return -1
        _l.fill_bytes(target, offset, data)
        return len(data)

    def readFully(self, target, offset=0, length=None):
        length = len(target) - offset if length is None else length
        _l.check_range(offset, length, len(target))
        data = self._call(self._file.read, length)
        if len(data) < length:
            raise EOFException()
        _l.fill_bytes(target, offset, data)

    def write(self, *args):
        if not self._writable:
            raise IOException("Bad file descriptor")
        if len(args) == 1:
            data = bytes((args[0] & 0xFF,)) if _l.is_int(args[0]) else _l.to_bytes(args[0])
        else:
            data = _slice(*args)
        self._call(self._file.write, data)

    def seek(self, position):
        if position < 0:
            raise IOException("Negative seek offset")
        self._call(self._file.seek, position)

    def getFilePointer(self):
        return self._call(self._file.tell)

    def length(self):
        self._call(self._file.flush)
        return self._call(lambda: os.fstat(self._file.fileno()).st_size)

    def setLength(self, length):
        if not self._writable:
            raise IOException("Bad file descriptor")
        position = self.getFilePointer()
        self._call(self._file.truncate, length)
        self._call(self._file.seek, min(position, length))

    def skipBytes(self, count):
        position, size = self.getFilePointer(), self.length()
        step = max(0, min(count, size - position))
        self.seek(position + step)
        return step

    def getChannel(self):
        from . import java_nio
        return java_nio.FileChannel._of(self._file, readable=True, writable=self._writable)

    def close(self):
        self._call(self._file.close)


# --- java.util.zip -------------------------------------------------------------------------

def _zip_error(error):
    """The Java exception for a Python zip/gzip failure, or None when it is not one."""
    import zipfile
    import zlib
    if isinstance(error, EOFError):
        return EOFException("Unexpected end of ZLIB input stream")
    if type(error).__name__ == "BadGzipFile":
        return ZipException("Not in GZIP format")
    if isinstance(error, (zipfile.BadZipFile, zlib.error)):
        return ZipException(str(error) or "invalid stored data")
    if isinstance(error, OSError):
        return io_error(error)
    return None


def _translated(function, *args):
    try:
        return function(*args)
    except _l.Throwable:
        raise
    except Exception as error:
        translated = _zip_error(error)
        if translated is None:
            raise
        raise translated from None


class _FileSource(InputStream):
    """A Python binary file as an ``InputStream``."""

    def __init__(self, raw):
        self._raw = raw

    def _read(self, size):
        return _translated(self._raw.read, size)

    def _close(self):
        self._raw.close()


class _Readable(io.RawIOBase):
    """A Java ``InputStream`` as a Python binary file."""

    def __init__(self, stream):
        self._stream = stream

    def readable(self):
        return True

    def readinto(self, buffer):
        data = self._stream._take(len(buffer))
        buffer[:len(data)] = data
        return len(data)


class _Writable(io.RawIOBase):
    """A Java ``OutputStream`` as a Python binary file."""

    def __init__(self, stream):
        self._stream = stream

    def writable(self):
        return True

    def write(self, data):
        self._stream.write(bytes(data))
        return len(data)


class _Checksum(Object):
    _START = 0

    def __init__(self):
        self._value = self._START

    def update(self, *args):
        data = bytes((args[0] & 0xFF,)) if len(args) == 1 and _l.is_int(args[0]) else \
            _l.to_bytes(args[0]) if len(args) == 1 else _slice(*args)
        self._value = self._function(data, self._value)

    def getValue(self):
        return self._value

    def reset(self):
        self._value = self._START


class CRC32(_Checksum):
    @staticmethod
    def _function(data, value):
        import zlib
        return zlib.crc32(data, value)


class Adler32(_Checksum):
    _START = 1

    @staticmethod
    def _function(data, value):
        import zlib
        return zlib.adler32(data, value)


class GZIPInputStream(InputStream):
    def __init__(self, source, size=512):
        import gzip
        if not isinstance(source, InputStream):
            raise TypeError("Expected a Python-local java.io.InputStream")
        self._source = source
        self._gzip = gzip.GzipFile(fileobj=io.BufferedReader(_Readable(source)), mode="rb")
        # Java reads and validates the header in the constructor.
        if not _translated(self._gzip.peek, 1):
            raise EOFException()

    def _read(self, size):
        return _translated(self._gzip.read, size)

    def _close(self):
        self._gzip.close()
        self._source.close()


class GZIPOutputStream(OutputStream):
    def __init__(self, target, *args):
        import gzip
        if not isinstance(target, OutputStream):
            raise TypeError("Expected a Python-local java.io.OutputStream")
        self._target, self._finished = target, False
        self._gzip = gzip.GzipFile(fileobj=_Writable(target), mode="wb", mtime=0)

    def _write(self, data):
        self._gzip.write(data)

    def _flush(self):
        if not self._finished:
            self._gzip.flush()
        self._target.flush()

    def finish(self):
        if not self._finished:
            self._finished = True
            self._gzip.close()

    def _close(self):
        self.finish()
        self._target.close()


class ZipEntry(Object):
    STORED, DEFLATED = 0, 8

    def __init__(self, name):
        if isinstance(name, ZipEntry):
            self.__dict__.update(name.__dict__)
            return
        if name is None:
            raise NullPointerException("name")
        if len(name.encode("utf-8", "replace")) > 0xFFFF:
            raise _l.IllegalArgumentException("entry name too long")
        self._name, self._size, self._compressed, self._crc, self._method, self._time = name, -1, -1, -1, -1, -1
        self._comment, self._extra = None, None

    @staticmethod
    def _from(info):
        import time
        entry = ZipEntry(info.filename)
        entry._size, entry._compressed, entry._crc, entry._method = \
            info.file_size, info.compress_size, info.CRC, info.compress_type
        try:
            entry._time = int(time.mktime(tuple(info.date_time) + (0, 0, -1))) * 1000
        except (OverflowError, ValueError):
            entry._time = -1
        entry._comment = info.comment.decode("utf-8", "replace") if info.comment else None
        entry._extra = _l.ByteArray(info.extra) if info.extra else None
        return entry

    def getName(self):
        return self._name

    def isDirectory(self):
        return self._name.endswith("/")

    def getSize(self):
        return self._size

    def setSize(self, size):
        if size < 0:
            raise _l.IllegalArgumentException("invalid entry size")
        self._size = size

    def getCompressedSize(self):
        return self._compressed

    def setCompressedSize(self, size):
        self._compressed = size

    def getCrc(self):
        return self._crc

    def setCrc(self, crc):
        if not 0 <= crc <= 0xFFFFFFFF:
            raise _l.IllegalArgumentException("invalid entry crc-32")
        self._crc = crc

    def getMethod(self):
        return self._method

    def setMethod(self, method):
        if method not in (ZipEntry.STORED, ZipEntry.DEFLATED):
            raise _l.IllegalArgumentException("invalid compression method")
        self._method = method

    def getTime(self):
        return self._time

    def setTime(self, millis):
        self._time = millis

    def getComment(self):
        return self._comment

    def setComment(self, comment):
        self._comment = comment

    def getExtra(self):
        return self._extra

    def setExtra(self, extra):
        self._extra = None if extra is None else _l.ByteArray(_l.to_bytes(extra))

    def toString(self):
        return self._name

    def hashCode(self):
        return _l.string_hash(self._name)


class ZipFile(Closeable):
    OPEN_READ, OPEN_DELETE = 1, 4

    def __init__(self, source, *args):
        import zipfile
        if any(item & ZipFile.OPEN_DELETE for item in args if _l.is_int(item)):
            raise _l.unsupported("ZipFile.OPEN_DELETE is not supported")
        self._path = path_of(source, "file")
        try:
            self._zip = zipfile.ZipFile(self._path, "r")
        except zipfile.BadZipFile:
            raise ZipException("error in opening zip file") from None
        except OSError as error:
            raise io_error(error, self._path) from None

    def _archive(self):
        if self._zip.fp is None:
            raise _l.IllegalStateException("zip file closed")
        return self._zip

    def getName(self):
        return self._path

    def getComment(self):
        return self._archive().comment.decode("utf-8", "replace") or None

    def size(self):
        return len(self._archive().infolist())

    def entries(self):
        from . import java_util
        return java_util.Iterator([ZipEntry._from(info) for info in self._archive().infolist()])

    def stream(self):
        raise _l.unsupported("java.util.stream is not supported")

    def getEntry(self, name):
        archive = self._archive()
        for candidate in (name, name + "/"):
            try:
                return ZipEntry._from(archive.getinfo(candidate))
            except KeyError:
                continue
        return None

    def getInputStream(self, entry):
        archive = self._archive()
        try:
            return _FileSource(_translated(archive.open, entry.getName(), "r"))
        except KeyError:
            return None

    def close(self):
        self._zip.close()


def _spool():
    import tempfile
    return tempfile.SpooledTemporaryFile(max_size=8 * 1024 * 1024)


class ZipInputStream(InputStream):
    def __init__(self, source, charset=None):
        if not isinstance(source, InputStream):
            raise TypeError("Expected a Python-local java.io.InputStream")
        self._source, self._zip, self._infos, self._entry, self._spooled = source, None, None, None, None

    def _load(self):
        import zipfile
        self._spooled = _spool()
        while True:
            data = self._source._take(65536)
            if not data:
                break
            self._spooled.write(data)
        self._spooled.seek(0)
        try:
            self._zip = zipfile.ZipFile(self._spooled, "r")
            self._infos = iter(self._zip.infolist())
        except zipfile.BadZipFile:
            # Java finds no entry header and reports the end of the archive.
            self._infos = iter(())

    def getNextEntry(self):
        self._check()
        if self._infos is None:
            self._load()
        self.closeEntry()
        info = next(self._infos, None)
        if info is None:
            return None
        self._entry = _translated(self._zip.open, info, "r")
        return ZipEntry._from(info)

    def closeEntry(self):
        self._check()
        if self._entry is not None:
            self._entry.close()
            self._entry = None
        self._pushback = b""

    def _read(self, size):
        return b"" if self._entry is None else _translated(self._entry.read, size)

    def _available(self):
        return 0 if self._entry is None else 1

    def _close(self):
        if self._entry is not None:
            self._entry.close()
        if self._zip is not None:
            self._zip.close()
        if self._spooled is not None:
            self._spooled.close()
        self._source.close()


class ZipOutputStream(OutputStream):
    STORED, DEFLATED = 0, 8

    def __init__(self, target, charset=None):
        import zipfile
        if not isinstance(target, OutputStream):
            raise TypeError("Expected a Python-local java.io.OutputStream")
        self._target, self._spooled = target, _spool()
        self._zip = zipfile.ZipFile(self._spooled, "w", zipfile.ZIP_DEFLATED)
        self._entry, self._names, self._method, self._level, self._finished = None, set(), 8, None, False

    def setMethod(self, method):
        if method not in (0, 8):
            raise _l.IllegalArgumentException("invalid compression method")
        self._method = method

    def setLevel(self, level):
        if not -1 <= level <= 9:
            raise _l.IllegalArgumentException("invalid compression level")
        self._level = None if level < 0 else level

    def setComment(self, comment):
        data = (comment or "").encode("utf-8")
        if len(data) > 0xFFFF:
            raise _l.IllegalArgumentException("ZIP file comment too long.")
        self._zip.comment = data

    def putNextEntry(self, entry):
        import time
        import zipfile
        self._check()
        self.closeEntry()
        name = entry.getName()
        if name in self._names:
            raise ZipException("duplicate entry: " + name)
        stamp = time.time() if entry.getTime() < 0 else entry.getTime() / 1000
        # The zip format cannot represent a time before 1980.
        info = zipfile.ZipInfo(name, time.localtime(max(stamp, 315561600))[:6])
        method = self._method if entry.getMethod() < 0 else entry.getMethod()
        info.compress_type = zipfile.ZIP_DEFLATED if method == 8 else zipfile.ZIP_STORED
        if entry.getComment():
            info.comment = entry.getComment().encode("utf-8")
        if entry.getExtra():
            info.extra = bytes(entry.getExtra())
        if self._level is not None:
            for attribute in ("compress_level", "_compresslevel"):
                try:
                    setattr(info, attribute, self._level)
                except AttributeError:
                    pass
        self._names.add(name)
        self._entry = _translated(self._zip.open, info, "w")

    def closeEntry(self):
        self._check()
        if self._entry is not None:
            self._entry.close()
            self._entry = None

    def _write(self, data):
        if self._entry is None:
            raise ZipException("no current ZIP entry")
        self._entry.write(data)

    def _flush(self):
        self._target.flush()

    def finish(self):
        if self._finished:
            return
        self.closeEntry()
        self._finished = True
        self._zip.close()
        self._spooled.seek(0)
        while True:
            data = self._spooled.read(65536)
            if not data:
                break
            self._target.write(data)
        self._spooled.close()

    def _close(self):
        self.finish()
        self._target.close()


CLASSES = _l.register({
    "java.io.File": File,
    "java.io.Closeable": Closeable,
    "java.io.Flushable": Flushable,
    "java.io.Serializable": Serializable,
    "java.io.FileFilter": FileFilter,
    "java.io.FilenameFilter": FilenameFilter,
    "java.io.InputStream": InputStream,
    "java.io.FileInputStream": FileInputStream,
    "java.io.ByteArrayInputStream": ByteArrayInputStream,
    "java.io.FilterInputStream": FilterInputStream,
    "java.io.BufferedInputStream": BufferedInputStream,
    "java.io.DataInputStream": DataInputStream,
    "java.io.OutputStream": OutputStream,
    "java.io.FileOutputStream": FileOutputStream,
    "java.io.ByteArrayOutputStream": ByteArrayOutputStream,
    "java.io.FilterOutputStream": FilterOutputStream,
    "java.io.BufferedOutputStream": BufferedOutputStream,
    "java.io.DataOutputStream": DataOutputStream,
    "java.io.PrintStream": PrintStream,
    "java.io.Reader": Reader,
    "java.io.StringReader": StringReader,
    "java.io.InputStreamReader": InputStreamReader,
    "java.io.FileReader": FileReader,
    "java.io.BufferedReader": BufferedReader,
    "java.io.LineNumberReader": LineNumberReader,
    "java.io.Writer": Writer,
    "java.io.StringWriter": StringWriter,
    "java.io.OutputStreamWriter": OutputStreamWriter,
    "java.io.FileWriter": FileWriter,
    "java.io.BufferedWriter": BufferedWriter,
    "java.io.PrintWriter": PrintWriter,
    "java.io.RandomAccessFile": RandomAccessFile,
    "java.io.IOException": IOException,
    "java.io.FileNotFoundException": FileNotFoundException,
    "java.io.EOFException": EOFException,
    "java.io.UnsupportedEncodingException": UnsupportedEncodingException,
    "java.io.UTFDataFormatException": UTFDataFormatException,
    "java.io.InterruptedIOException": InterruptedIOException,
    "java.io.UncheckedIOException": UncheckedIOException,
    "java.util.zip.ZipEntry": ZipEntry,
    "java.util.zip.ZipFile": ZipFile,
    "java.util.zip.ZipInputStream": ZipInputStream,
    "java.util.zip.ZipOutputStream": ZipOutputStream,
    "java.util.zip.ZipException": ZipException,
    "java.util.zip.GZIPInputStream": GZIPInputStream,
    "java.util.zip.GZIPOutputStream": GZIPOutputStream,
    "java.util.zip.CRC32": CRC32,
    "java.util.zip.Adler32": Adler32,
})
