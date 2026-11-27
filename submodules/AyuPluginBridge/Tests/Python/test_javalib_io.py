"""java.io, java.util.zip and java.nio providers against a temporary directory; no host."""
from __future__ import annotations

import os
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Python"))

import ayu_bridge as bridge
from _ayu_javalib import java_io as io
from _ayu_javalib import java_lang as lang
from _ayu_javalib import java_nio as nio


class TemporaryDirectoryCase(unittest.TestCase):
    def setUp(self):
        holder = tempfile.TemporaryDirectory()
        self.addCleanup(holder.cleanup)
        self.root = os.path.realpath(holder.name)

    def file(self, *parts):
        return io.File(self.root, "/".join(parts))

    def write(self, name, data):
        with open(os.path.join(self.root, name), "wb") as stream:
            stream.write(data)
        return self.file(name)

    def closing(self, stream):
        self.addCleanup(stream.close)
        return stream


class FileTests(TemporaryDirectoryCase):
    def test_path_arithmetic_needs_no_file_system(self):
        self.assertEqual([io.File(path).getPath() for path in ("a//b/", "/", "", "/a/")], ["a/b", "/", "", "/a"])
        self.assertEqual((io.File("", "b").getPath(), io.File("/a", "/b").getPath(), io.File(None, "c").getPath(),
                          io.File(io.File("/a"), "b/c").getPath()), ("/b", "/a/b", "c", "/a/b/c"))
        nested = io.File("/a/b/c.txt")
        self.assertEqual((nested.getName(), nested.getParent(), nested.getParentFile().getName(), nested.isAbsolute(),
                          io.File("x").getParent(), io.File("/").getParent(), io.File("/x").getParent(), str(nested),
                          os.fspath(nested), nested.to_bridge()),
                         ("c.txt", "/a/b", "b", True, None, None, "/", "/a/b/c.txt", "/a/b/c.txt", "/a/b/c.txt"))
        self.assertEqual((nested, nested.hashCode(), nested.compareTo(io.File("/a/b/d")) < 0, io.File("rel").getAbsolutePath()),
                         (io.File("/a/b", "c.txt"), lang.string_hash("/a/b/c.txt") ^ 1234321, True, os.getcwd() + "/rel"))
        self.assertEqual((nested.toURI().toString(), nested.toPath().toString(), io.File.separator), ("file:/a/b/c.txt", "/a/b/c.txt", "/"))
        with self.assertRaises(lang.NullPointerException):
            io.File(None)

    def test_file_system_operations_report_like_java(self):
        target = self.file("sub/x.txt")
        self.assertEqual((target.exists(), target.length(), target.lastModified(), target.delete(), target.list(),
                          target.listFiles()), (False, 0, 0, False, None, None))
        self.assertEqual((target.getParentFile().mkdirs(), target.getParentFile().mkdirs(), target.createNewFile(),
                          target.createNewFile(), target.isFile(), target.isDirectory(), target.canRead()),
                         (True, False, True, False, True, False, True))
        self.assertEqual((self.file("sub").mkdir(), self.file("sub").delete(), [item.getName() for item in self.file("").listFiles()],
                          self.file("sub").list(), self.file("sub").listFiles(lambda item: item.getName().endswith(".md")),
                          [item.getName() for item in self.file("sub").listFiles(lambda folder, name: name.startswith("x"))]),
                         (False, False, ["sub"], ["x.txt"], [], ["x.txt"]))
        self.assertTrue(target.setLastModified(1_700_000_000_000))
        self.assertEqual(target.lastModified(), 1_700_000_000_000)
        moved = self.file("y.txt")
        self.assertEqual((target.renameTo(moved), target.exists(), moved.exists(), target.renameTo(moved)), (True, False, True, False))
        self.assertTrue(moved.setReadOnly())
        if os.geteuid() != 0:
            self.assertFalse(moved.canWrite())
        self.assertTrue(moved.setWritable(True))
        self.assertEqual((moved.delete(), self.file("sub").delete(), self.file("sub").exists()), (True, True, False))
        self.assertGreater(self.file("").getTotalSpace(), 0)
        with self.assertRaises(io.IOException):
            self.file("absent/dir/new.txt").createNewFile()
        temporary = io.File.createTempFile("abc", ".bin", io.File(self.root))
        self.assertTrue(temporary.exists() and temporary.getName().endswith(".bin"))
        with self.assertRaises(lang.IllegalArgumentException):
            io.File.createTempFile("ab", None)
        with self.assertRaises(bridge.UnsupportedAPI):
            temporary.deleteOnExit()


class ByteStreamTests(TemporaryDirectoryCase):
    def test_file_streams(self):
        target = self.file("data.bin")
        with io.FileOutputStream(target) as output:
            output.write(65)
            output.write(b"BC")
            output.write([68, 69, 70], 1, 2)
            output.write(bytearray(b"\xff"))
            output.write([-1])
            output.flush()
        with self.assertRaises(io.IOException) as caught:
            output.write(1)
        self.assertEqual(caught.exception.getMessage(), "Stream Closed")
        with io.FileOutputStream(target.getPath(), True) as output:
            output.write(b"!")
        source = io.FileInputStream(target)
        buffer, signed = bytearray(4), [0] * 3
        self.assertEqual((source.read(), source.available(), source.read(buffer), bytes(buffer), source.read(signed, 1, 2), signed),
                         (65, 7, 4, b"BCEF", 2, [0, -1, -1]))
        self.assertEqual((bytes(source.readAllBytes()), source.read(), source.read(buffer), source.read(buffer, 0, 0)), (b"!", -1, -1, 0))
        source.close()
        source.close()
        with self.assertRaises(io.IOException):
            source.read()
        with self.assertRaises(io.FileNotFoundException) as caught:
            io.FileInputStream(self.file("absent"))
        self.assertTrue(caught.exception.getMessage().endswith("absent (No such file or directory)"))
        self.assertIsInstance(caught.exception, io.IOException)
        self.assertNotIsInstance(caught.exception, OSError)
        with self.assertRaises(io.FileNotFoundException):
            io.FileOutputStream(self.file("no/such/dir/file"))
        with self.assertRaises(lang.IndexOutOfBoundsException):
            self.closing(io.FileInputStream(target)).read(buffer, 3, 4)
        with self.assertRaises(bridge.UnsupportedAPI):
            self.closing(io.FileInputStream(target)).read(b"immutable")

    def test_memory_filter_and_data_streams(self):
        memory = io.ByteArrayOutputStream()
        data = io.DataOutputStream(memory)
        data.writeInt(-2)
        data.writeUTF("h\u00e9\0")
        data.writeLong(5)
        data.writeDouble(1.5)
        data.writeBoolean(True)
        data.writeShort(-1)
        self.assertEqual((memory.size(), data.size(), len(memory), bytes(memory.toByteArray())[:4], memory.toByteArray().to_bridge()[:4]),
                         (30, 30, 30, b"\xff\xff\xff\xfe", [-1, -1, -1, -2]))
        reader = io.DataInputStream(io.ByteArrayInputStream(memory.toByteArray()))
        self.assertEqual((reader.readInt(), reader.readUTF(), reader.readLong(), reader.readDouble(), reader.readBoolean(),
                          reader.readUnsignedShort()), (-2, "h\u00e9\0", 5, 1.5, True, 65535))
        with self.assertRaises(io.EOFException):
            reader.readByte()
        buffered = io.BufferedInputStream(io.ByteArrayInputStream(b"abcdef"))
        self.assertTrue(buffered.markSupported())
        buffered.mark(10)
        self.assertEqual((buffered.read(), buffered.read()), (97, 98))
        buffered.reset()
        self.assertEqual((buffered.read(), bytes(buffered.readNBytes(2)), buffered.skip(10), buffered.read()), (97, b"bc", 3, -1))
        self.assertFalse(io.InputStream().markSupported())
        ranged = io.ByteArrayInputStream(b"abcdef", 2, 3)
        self.assertEqual((ranged.available(), bytes(ranged.readAllBytes())), (3, b"cde"))
        sink = io.ByteArrayOutputStream()
        piped = io.BufferedOutputStream(sink, 4)
        piped.write(b"ab")
        self.assertEqual(sink.size(), 0)
        piped.write(b"cd")
        piped.write(b"e")
        self.assertEqual(sink.size(), 4)
        piped.close()
        self.assertEqual((sink.toString(), sink.toString("UTF-8"), io.ByteArrayInputStream(b"xyz").transferTo(sink), sink.size()),
                         ("abcde", "abcde", 3, 8))
        sink.reset()
        self.assertEqual(sink.size(), 0)
        with self.assertRaises(TypeError):
            io.BufferedInputStream(object())
        with self.assertRaises(bridge.UnsupportedAPI):
            io.InputStream().read()

    def test_random_access_file(self):
        target = self.file("raf.bin")
        handle = io.RandomAccessFile(target, "rw")
        handle.write(b"hello")
        handle.seek(1)
        buffer = bytearray(2)
        self.assertEqual((handle.read(), handle.read(buffer), bytes(buffer), handle.length(), handle.getFilePointer()),
                         (101, 2, b"ll", 5, 4))
        handle.setLength(2)
        self.assertEqual((handle.length(), handle.getFilePointer(), handle.read()), (2, 2, -1))
        handle.close()
        with self.assertRaises(io.IOException):
            handle.read()
        with self.assertRaises(io.IOException):
            self.closing(io.RandomAccessFile(target, "r")).write(b"x")
        with self.assertRaises(lang.IllegalArgumentException):
            io.RandomAccessFile(target, "w")
        with self.assertRaises(io.FileNotFoundException):
            io.RandomAccessFile(self.file("absent"), "r")


class CharacterStreamTests(TemporaryDirectoryCase):
    def test_readers(self):
        source = self.write("text.txt", "first\r\nsecond\rth\u00efrd\n\nlast".encode("utf-8"))
        reader = io.BufferedReader(io.InputStreamReader(io.FileInputStream(source), "UTF-8"))
        self.assertEqual([reader.readLine() for _ in range(6)], ["first", "second", "th\u00efrd", "", "last", None])
        reader.close()
        with self.assertRaises(io.IOException):
            reader.readLine()
        self.assertEqual(list(self.closing(io.BufferedReader(io.FileReader(source)))),
                         ["first", "second", "th\u00efrd", "", "last"])
        text = io.StringReader("ab\U0001F600")
        chars = [None] * 3
        self.assertEqual((text.read(), text.read(chars, 1, 2), chars, text.read(), text.read()),
                         (97, 2, [None, "b", "\ud83d"], 0xDE00, -1))
        marked = io.BufferedReader(io.StringReader("one\ntwo"))
        marked.mark(100)
        self.assertEqual(marked.readLine(), "one")
        marked.reset()
        self.assertEqual((marked.readLine(), marked.skip(1), chr(marked.read()), marked.ready()), ("one", 1, "w", True))
        utf16 = io.InputStreamReader(io.ByteArrayInputStream("hi".encode("utf-16")), "UTF-16")
        self.assertEqual((chr(utf16.read()), chr(utf16.read()), utf16.read()), ("h", "i", -1))
        numbered = io.LineNumberReader(io.StringReader("a\nb"))
        numbered.readLine()
        self.assertEqual(numbered.getLineNumber(), 1)
        with self.assertRaises(io.UnsupportedEncodingException):
            io.InputStreamReader(io.ByteArrayInputStream(b""), "no-such-charset")
        with self.assertRaises(bridge.UnsupportedAPI):
            marked.lines()

    def test_writers_and_print_streams(self):
        text = io.StringWriter()
        printer = io.PrintWriter(text)
        printer.println("hi")
        printer.print(1.0)
        printer.printf("%d-%s", 3, None).println()
        printer.write("tail", 1, 2)
        printer.append("!").flush()
        self.assertEqual((text.toString(), text.getBuffer().length(), str(text), printer.checkError()),
                         ("hi\n1.03-null\nai!", 16, "hi\n1.03-null\nai!", False))
        memory = io.ByteArrayOutputStream()
        stream = io.PrintStream(memory)
        stream.println("\u00e9")
        stream.print(True)
        stream.print(["o", "k"])
        stream.write(33)
        self.assertEqual(bytes(memory.toByteArray()), b"\xc3\xa9\ntrueok!")
        target = self.file("out.txt")
        writer = io.OutputStreamWriter(io.FileOutputStream(target), "UTF-8")
        writer.write("z\u00e9")
        writer.write(65)
        writer.append("bc", 1, 2).close()
        with io.BufferedWriter(io.FileWriter(target, True)) as buffered:
            buffered.newLine()
            buffered.write(["x", "y"])
        self.assertEqual(Path(target.getPath()).read_bytes(), b"z\xc3\xa9Ac\nxy")
        wide = io.ByteArrayOutputStream()
        writer = io.OutputStreamWriter(wide, "UTF-16")
        writer.write("a")
        writer.write("b")
        writer.flush()
        self.assertEqual((bytes(wide.toByteArray()), writer.getEncoding()), (b"\xfe\xff\x00a\x00b", "UTF-16"))
        failing = io.PrintStream(io.FileOutputStream(self.file("closed.txt")))
        failing.close()
        failing.println("dropped")
        self.assertTrue(failing.checkError())
        with self.assertRaises(io.IOException):
            io.StringWriter().append("x").close() or io.FileWriter(self.file("no/dir/x"))


class ZipTests(TemporaryDirectoryCase):
    def test_zip_round_trip(self):
        archive = self.file("a.zip")
        output = io.ZipOutputStream(io.FileOutputStream(archive))
        with self.assertRaises(io.ZipException):
            output.write(b"no entry")
        output.putNextEntry(io.ZipEntry("a.txt"))
        output.write(b"AAA")
        output.closeEntry()
        stored = io.ZipEntry("dir/b.txt")
        stored.setMethod(io.ZipEntry.STORED)
        output.putNextEntry(stored)
        output.write(b"BB")
        with self.assertRaises(io.ZipException):
            output.putNextEntry(io.ZipEntry("a.txt"))
        output.close()
        entries = []
        with io.ZipInputStream(io.FileInputStream(archive)) as source:
            while True:
                entry = source.getNextEntry()
                if entry is None:
                    break
                entries.append((entry.getName(), entry.isDirectory(), entry.getSize(), entry.getMethod(),
                                bytes(source.readAllBytes()), source.read()))
        self.assertEqual(entries, [("a.txt", False, 3, 8, b"AAA", -1), ("dir/b.txt", False, 2, 0, b"BB", -1)])
        with io.ZipFile(archive) as opened:
            self.assertEqual((opened.size(), [entry.getName() for entry in opened.entries()],
                              bytes(opened.getInputStream(opened.getEntry("a.txt")).readAllBytes()), opened.getEntry("zz"),
                              opened.getName()), (2, ["a.txt", "dir/b.txt"], b"AAA", None, archive.getPath()))
        with self.assertRaises(lang.IllegalStateException):
            opened.size()
        self.assertIsNone(self.closing(io.ZipInputStream(io.ByteArrayInputStream(b"not a zip"))).getNextEntry())
        with self.assertRaises(io.ZipException):
            io.ZipFile(self.write("bad.zip", b"not a zip"))
        with self.assertRaises(io.IOException):
            io.ZipFile(self.file("absent.zip"))

    def test_gzip_and_checksums(self):
        memory = io.ByteArrayOutputStream()
        with io.GZIPOutputStream(memory) as output:
            output.write(b"gzip me")
        packed = bytes(memory.toByteArray())
        self.assertEqual(bytes(io.GZIPInputStream(io.ByteArrayInputStream(packed)).readAllBytes()), b"gzip me")
        with self.assertRaises(io.ZipException) as caught:
            io.GZIPInputStream(io.ByteArrayInputStream(b"not gzip"))
        self.assertEqual(caught.exception.getMessage(), "Not in GZIP format")
        with self.assertRaises(io.EOFException):
            io.GZIPInputStream(io.ByteArrayInputStream(packed[:12])).readAllBytes()
        with self.assertRaises(io.EOFException):
            io.GZIPInputStream(io.ByteArrayInputStream(b""))
        checksum = io.CRC32()
        checksum.update(b"hel")
        checksum.update([108, 111], 0, 2)
        self.assertEqual(checksum.getValue(), 907060870)
        checksum.reset()
        self.assertEqual((checksum.getValue(), io.Adler32().getValue()), (0, 1))


class ByteBufferTests(unittest.TestCase):
    def test_relative_absolute_and_typed_access(self):
        buffer = nio.ByteBuffer.allocate(16)
        self.assertIs(buffer.putInt(1).putLong(-2).put(7).putShort(300), buffer)
        self.assertEqual((buffer.position(), buffer.limit(), buffer.capacity(), buffer.remaining()), (15, 16, 16, 1))
        buffer.flip()
        self.assertEqual((buffer.getInt(), buffer.getLong(), buffer.get(), buffer.getShort(), buffer.hasRemaining(), str(buffer)),
                         (1, -2, 7, 300, False, "java.nio.HeapByteBuffer[pos=15 lim=15 cap=16]"))
        little = nio.ByteBuffer.wrap(bytearray(b"\x01\x02\x03\x04")).order(nio.ByteOrder.LITTLE_ENDIAN)
        self.assertEqual((little.getInt(0), little.order(), little.get(3), nio.ByteBuffer.wrap([1, -1]).get(1), bytes(little)),
                         (0x04030201, nio.ByteOrder.LITTLE_ENDIAN, 4, -1, b"\x01\x02\x03\x04"))
        self.assertEqual((nio.ByteBuffer.allocate(8).putDouble(1.5).getDouble(0), nio.ByteBuffer.allocate(2).putChar("x").getChar(0),
                          nio.ByteBuffer.allocate(4).putInt(2 ** 31).getInt(0), nio.ByteBuffer.allocate(4).putFloat(0.5).getFloat(0)),
                         (1.5, "x", -2 ** 31, 0.5))
        self.assertIn(nio.ByteOrder.nativeOrder(), (nio.ByteOrder.BIG_ENDIAN, nio.ByteOrder.LITTLE_ENDIAN))

    def test_views_bounds_and_sharing(self):
        backing = bytearray(b"abcdef")
        buffer = nio.ByteBuffer.wrap(backing)
        target = bytearray(2)
        buffer.get(target)
        self.assertEqual((bytes(target), buffer.position(), buffer.slice().remaining(), buffer.duplicate().get(), buffer.array() is backing,
                          buffer.hasArray(), buffer.arrayOffset()), (b"ab", 2, 4, 99, True, True, 0))
        buffer.put(0, 90)
        self.assertEqual(backing[0], 90)
        buffer.mark().get()
        buffer.reset()
        self.assertEqual((buffer.position(), buffer.compact().position(), bytes(backing), buffer.clear().remaining()), (2, 4, b"cdefef", 6))
        window = nio.ByteBuffer.wrap(b"0123456789", 2, 3)
        self.assertEqual((window.position(), window.limit(), window.capacity(), bytes(window)), (2, 5, 10, b"234"))
        read_only = buffer.asReadOnlyBuffer()
        for call in (lambda: read_only.put(1), read_only.array, read_only.compact):
            with self.assertRaises(nio.ReadOnlyBufferException):
                call()
        with self.assertRaises(nio.BufferUnderflowException):
            nio.ByteBuffer.allocate(1).getInt()
        with self.assertRaises(nio.BufferOverflowException):
            nio.ByteBuffer.allocate(1).putInt(1)
        with self.assertRaises(lang.IndexOutOfBoundsException):
            nio.ByteBuffer.allocate(1).get(1)
        with self.assertRaises(nio.InvalidMarkException):
            nio.ByteBuffer.allocate(1).reset()
        with self.assertRaises(lang.IllegalArgumentException):
            nio.ByteBuffer.allocate(1).position(2)
        with self.assertRaises(lang.UnsupportedOperationException):
            nio.ByteBuffer.allocateDirect(1).array()
        self.assertEqual((nio.ByteBuffer.wrap(b"ab"), nio.ByteBuffer.wrap(b"ab").hashCode(), nio.ByteBuffer.wrap(b"a").compareTo(nio.ByteBuffer.wrap(b"b"))),
                         (nio.ByteBuffer.wrap(b"xab", 1, 2), 31 * (31 + 98) + 97, -1))
        self.assertFalse(hasattr(buffer, "asIntBuffer"))

    def test_charsets(self):
        utf8 = nio.StandardCharsets.UTF_8
        self.assertEqual((utf8.name(), str(utf8), nio.Charset.forName("utf8") == utf8, nio.Charset.forName("windows-1251").name(),
                          nio.Charset.forName("latin1").name(), nio.Charset.defaultCharset(), nio.Charset.isSupported("x-absent")),
                         ("UTF-8", "UTF-8", True, "windows-1251", "ISO-8859-1", utf8, False))
        self.assertEqual((utf8.decode(utf8.encode("h\u00e9")).toString(), bytes(lang.String("\u00e9").getBytes(nio.StandardCharsets.ISO_8859_1)),
                          lang.String(b"\xe9", nio.StandardCharsets.ISO_8859_1), bytes(nio.StandardCharsets.UTF_16.encode("a")),
                          bytes(lang.String("a").getBytes(nio.StandardCharsets.UTF_16LE))),
                         ("h\u00e9", b"\xe9", "\u00e9", b"\xfe\xff\x00a", b"a\x00"))
        with self.assertRaises(nio.UnsupportedCharsetException):
            nio.Charset.forName("x-absent")
        with self.assertRaises(nio.IllegalCharsetNameException):
            nio.Charset.forName("bad name")


class FilesTests(TemporaryDirectoryCase):
    def test_paths(self):
        path = nio.Paths.get("/a", "b", "c.txt")
        self.assertEqual((str(path), str(path.getFileName()), str(path.getParent()), path.getNameCount(), str(path.getName(1)),
                          path.isAbsolute(), str(path.getRoot()), str(nio.Paths.get("a/../b/./c").normalize()),
                          str(path.relativize(nio.Paths.get("/a/x/y"))), str(path.resolve("d")), str(path.resolve("/z")),
                          str(path.resolveSibling("d")), path.startsWith("/a/b"), path.endsWith("c.txt"), path.endsWith("b"),
                          path.toFile().getName(), os.fspath(path), [str(item) for item in path], path == nio.Path.of("/a/b/c.txt")),
                         ("/a/b/c.txt", "c.txt", "/a/b", 3, "b", True, "/", "b/c", "../../x/y", "/a/b/c.txt/d", "/z", "/a/b/d", True, True,
                          False, "c.txt", "/a/b/c.txt", ["a", "b", "c.txt"], True))
        self.assertIsNone(nio.Paths.get("x").getParent())
        with self.assertRaises(nio.InvalidPathException):
            nio.Paths.get("a\0b")

    def test_files(self):
        files, option = nio.Files, nio.StandardCopyOption
        source = nio.Paths.get(self.root, "a", "b.txt")
        files.createDirectories(source.getParent())
        self.assertIs(files.write(source, b"hello\nworld\n"), source)
        self.assertEqual((files.exists(source), files.notExists(source), files.size(source), bytes(files.readAllBytes(source)),
                          files.readAllLines(source), files.readString(source), files.isDirectory(source.getParent()),
                          files.isRegularFile(source)), (True, False, 12, b"hello\nworld\n", ["hello", "world"], "hello\nworld\n", True, True))
        copy = nio.Paths.get(self.root, "c.txt")
        self.assertEqual(files.copy(source, copy), copy)
        with self.assertRaises(nio.FileAlreadyExistsException) as caught:
            files.copy(source, copy)
        self.assertIsInstance(caught.exception, io.IOException)
        files.copy(source, copy, option.REPLACE_EXISTING)
        files.write(copy, ["x", "y"], nio.StandardOpenOption.APPEND)
        self.assertEqual(files.readAllLines(copy), ["hello", "world", "x", "y"])
        self.assertEqual((files.copy(io.ByteArrayInputStream(b"zz"), copy, option.REPLACE_EXISTING), files.readString(copy)), (2, "zz"))
        sink = io.ByteArrayOutputStream()
        self.assertEqual((files.copy(copy, sink), sink.toString()), (2, "zz"))
        with self.assertRaises(nio.NoSuchFileException) as caught:
            files.delete(nio.Paths.get(self.root, "absent"))
        self.assertTrue(caught.exception.getMessage().endswith("absent"))
        with self.assertRaises(nio.DirectoryNotEmptyException):
            files.delete(source.getParent())
        with self.assertRaises(nio.NoSuchFileException):
            files.readAllBytes(nio.Paths.get(self.root, "absent"))
        with self.assertRaises(nio.NoSuchFileException):
            files.write(nio.Paths.get(self.root, "absent"), b"x", nio.StandardOpenOption.WRITE)
        with self.assertRaises(nio.FileAlreadyExistsException):
            files.write(copy, b"x", nio.StandardOpenOption.CREATE_NEW)
        self.assertEqual((files.deleteIfExists(copy), files.deleteIfExists(copy), files.move(source, copy), files.exists(source)),
                         (True, False, copy, False))
        with files.newBufferedWriter(source) as writer:
            writer.write("line")
            writer.newLine()
        with files.newBufferedReader(source) as reader:
            self.assertEqual((reader.readLine(), reader.readLine()), ("line", None))
        with files.newOutputStream(source, nio.StandardOpenOption.APPEND) as output:
            output.write(b"+")
        with files.newInputStream(source) as stream:
            self.assertEqual(bytes(stream.readAllBytes()), b"line\n+")
        temporary = files.createTempFile(nio.Paths.get(self.root), "pre", ".suf")
        self.assertTrue(files.exists(temporary) and str(temporary.getFileName()).startswith("pre"))
        with self.assertRaises(bridge.UnsupportedAPI):
            files.list(source.getParent())
        with self.assertRaises(TypeError):
            files.write(source, "text")
        self.assertEqual((files.writeString(source, "t\u00e9xt"), files.readString(source)), (source, "t\u00e9xt"))
        with self.assertRaises(bridge.UnsupportedAPI):
            files.newOutputStream(source, nio.StandardOpenOption.DELETE_ON_CLOSE)

    def test_channels(self):
        source = self.write("in.bin", b"hello world!")
        reader, writer = io.FileInputStream(source), io.FileOutputStream(self.file("out.bin"))
        channel = reader.getChannel()
        self.assertEqual((channel.size(), channel.transferTo(0, channel.size(), writer.getChannel()), channel.position()), (12, 12, 0))
        reader.close()
        writer.close()
        self.assertEqual(Path(self.root, "out.bin").read_bytes(), b"hello world!")
        opened = nio.FileChannel.open(nio.Paths.get(source.getPath()), nio.StandardOpenOption.READ)
        buffer = nio.ByteBuffer.allocate(5)
        self.assertEqual((opened.read(buffer), bytes(buffer.flip()), opened.position(), opened.read(nio.ByteBuffer.allocate(4), 6),
                          opened.position(), opened.isOpen()), (5, b"hello", 5, 4, 5, True))
        with self.assertRaises(nio.NonWritableChannelException):
            opened.write(nio.ByteBuffer.wrap(b"x"))
        opened.close()
        with self.assertRaises(nio.ClosedChannelException):
            opened.size()
        sink = io.ByteArrayOutputStream()
        wrapped = nio.Channels.newChannel(sink)
        self.assertEqual((wrapped.write(nio.ByteBuffer.wrap(b"chan")), sink.toString()), (4, "chan"))
        with self.assertRaises(nio.NonReadableChannelException):
            wrapped.read(nio.ByteBuffer.allocate(1))
        writable = nio.FileChannel.open(nio.Paths.get(self.root, "new.bin"), nio.StandardOpenOption.CREATE,
                                        nio.StandardOpenOption.WRITE)
        writable.write(nio.ByteBuffer.wrap(b"abcdef"))
        writable.truncate(3)
        self.assertEqual((writable.size(), writable.position()), (3, 3))
        self.assertEqual(writable.transferFrom(nio.Channels.newChannel(io.ByteArrayInputStream(b"XY")), 3, 10), 2)
        writable.close()
        self.assertEqual(Path(self.root, "new.bin").read_bytes(), b"abcXY")
        with self.assertRaises(bridge.UnsupportedAPI):
            self.closing(nio.FileChannel.open(nio.Paths.get(source.getPath()))).map(None, 0, 1)


if __name__ == "__main__":
    unittest.main()
