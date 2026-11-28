"""java.lang provider, exercised directly: no host and no plugin source."""
from __future__ import annotations

import math
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Python"))

import ayu_bridge as bridge
from _ayu_javalib import java_lang as lang

String, Integer, Long, Double, Float, Boolean, Character = (
    lang.String, lang.Integer, lang.Long, lang.Double, lang.Float, lang.Boolean, lang.Character)


class ObjectModelTests(unittest.TestCase):
    def test_unimplemented_members_are_unsupported_and_read_as_absent(self):
        value = lang.Object()
        self.assertFalse(hasattr(value, "wait"))
        self.assertEqual(getattr(lang.Math, "fma", "absent"), "absent")
        with self.assertRaises(bridge.UnsupportedAPI) as caught:
            value.notify()
        self.assertIn("java.lang.Object.notify", caught.exception.message)
        with self.assertRaises(bridge.UnsupportedAPI):
            lang.Math.fma
        with self.assertRaises(AttributeError):
            value._private

    def test_object_identity_and_class_metadata(self):
        first, second = lang.Object(), lang.Object()
        self.assertTrue(first.equals(first))
        self.assertFalse(first.equals(second))
        self.assertEqual(first.hashCode(), lang.System.identityHashCode(first))
        self.assertRegex(first.toString(), r"^java\.lang\.Object@[0-9a-f]+$")
        self.assertEqual(str(first), first.toString())
        self.assertEqual(lang.System.identityHashCode(None), 0)
        cls = String("x").getClass()
        self.assertIs(cls, String.getClass())

        class Derived(lang.Object):
            pass

        self.assertEqual(Derived().getClass(), Derived.getClass())
        self.assertNotEqual(Derived.getClass(), lang.Object.getClass())
        self.assertNotIn(Derived, lang.Class._cache)
        self.assertEqual(Derived.getClass().getSuperclass(), lang.Object.getClass())
        self.assertEqual((cls.getName(), cls.getSimpleName(), cls.getPackageName()),
                         ("java.lang.String", "String", "java.lang"))
        self.assertTrue(cls.isInstance(String("y")))
        self.assertFalse(cls.isInstance("plain"))
        self.assertTrue(lang.Object.getClass().isAssignableFrom(cls))
        self.assertEqual(cls.toString(), "class java.lang.String")
        self.assertEqual(Integer.TYPE.getName(), "int")
        self.assertTrue(Integer.TYPE.isPrimitive())
        self.assertEqual(Integer.TYPE.toString(), "int")
        # Members are reflected from the class's model (``test_pymembers_reflection``); constructors are not.
        self.assertEqual(cls.getDeclaredMethod("length").getName(), "length")
        with self.assertRaises(bridge.UnsupportedAPI):
            cls.getDeclaredConstructors

    def test_enum_helper_matches_java_enum_contract(self):
        class Colour(lang.Enum):
            pass

        lang.enum_constants(Colour, "RED", "GREEN")
        self.assertEqual([item.name() for item in Colour.values()], ["RED", "GREEN"])
        self.assertIs(Colour.valueOf("GREEN"), Colour.GREEN)
        self.assertEqual((Colour.GREEN.ordinal(), str(Colour.RED), Colour.RED.compareTo(Colour.GREEN)), (1, "RED", -1))
        with self.assertRaises(lang.IllegalArgumentException):
            Colour.valueOf("BLUE")
        with self.assertRaises(lang.NullPointerException):
            Colour.valueOf(None)


class ThrowableTests(unittest.TestCase):
    def test_hierarchy_messages_and_causes(self):
        cause = lang.IllegalStateException("inner")
        error = lang.RuntimeException("outer", cause)
        self.assertIsInstance(error, Exception)
        self.assertIsInstance(error, lang.Exception_)
        self.assertIsInstance(error, lang.Throwable)
        self.assertEqual(lang.Exception_.__name__, "Exception")
        self.assertEqual((error.getMessage(), error.getCause(), str(error)),
                         ("outer", cause, "java.lang.RuntimeException: outer"))
        self.assertIsNone(lang.Exception_().getMessage())
        self.assertEqual(lang.Exception_().toString(), "java.lang.Exception")
        wrapped = lang.RuntimeException(cause)
        self.assertEqual(wrapped.getMessage(), "java.lang.IllegalStateException: inner")
        self.assertIs(lang.Exception_("x").initCause(cause).getCause(), cause)
        with self.assertRaises(lang.IllegalStateException):
            error.initCause(cause)
        with self.assertRaises(TypeError):
            lang.Exception_(5)

    def test_java_exceptions_are_caught_by_java_and_matching_python_types(self):
        for java, python in ((lang.IllegalArgumentException, ValueError), (lang.NumberFormatException, ValueError),
                             (lang.IllegalStateException, RuntimeError), (lang.NullPointerException, TypeError),
                             (lang.IndexOutOfBoundsException, IndexError),
                             (lang.ArithmeticException, ArithmeticError)):
            with self.assertRaises(python):
                raise java("x")
            with self.assertRaises(lang.RuntimeException):
                raise java("x")
        self.assertFalse(issubclass(lang.RuntimeException, ValueError))

    def test_stack_trace_is_the_python_one(self):
        def thrower():
            raise lang.IllegalArgumentException("bad")

        try:
            thrower()
        except lang.IllegalArgumentException as error:
            trace = error.getStackTrace()
        self.assertEqual(trace[0].getMethodName(), "thrower")
        self.assertEqual(trace[0].getFileName(), Path(__file__).name)
        self.assertEqual(lang.Throwable().getStackTrace()[0].getMethodName(), "test_stack_trace_is_the_python_one")


class StringTests(unittest.TestCase):
    def test_string_is_a_str_with_utf16_indices(self):
        text = String("h\u00e9\U0001F600!")
        self.assertIsInstance(text, str)
        self.assertIsInstance("plain", lang.CharSequence)
        self.assertNotIsInstance("plain", String)
        self.assertEqual((text.length(), len(text)), (5, 4))
        self.assertEqual(text.charAt(2), "\ud83d")
        self.assertEqual(text.codePointAt(2), 0x1F600)
        self.assertEqual(text.substring(4), "!")
        self.assertEqual(text.substring(2, 4), "\U0001F600")
        self.assertEqual(text.indexOf("!"), 4)
        self.assertEqual(text.to_bridge(), "h\u00e9\U0001F600!")
        self.assertIs(type(text.to_bridge()), str)
        with self.assertRaises(lang.StringIndexOutOfBoundsException):
            text.substring(3, 9)
        with self.assertRaises(lang.StringIndexOutOfBoundsException):
            text.charAt(5)

    def test_constructors(self):
        self.assertEqual(String(), "")
        self.assertEqual(String(b"\xd0\xb6"), "\u0436")
        self.assertEqual(String([-48, -74], "UTF-8"), "\u0436")
        self.assertEqual(String(b"abcdef", 1, 3), "bcd")
        self.assertEqual(String(b"\xe9", "ISO-8859-1"), "\u00e9")
        self.assertEqual(String(["a", "b", "c"], 1, 2), "bc")
        self.assertEqual(String(lang.StringBuilder("sb")), "sb")
        self.assertEqual(String(b"\xff"), "\ufffd")
        with self.assertRaises(lang.NullPointerException):
            String(None)
        from _ayu_javalib import java_io
        with self.assertRaises(java_io.UnsupportedEncodingException):
            String(b"x", "no-such-charset")

    def test_hash_and_comparisons(self):
        self.assertEqual(String("hello").hashCode(), 99162322)
        self.assertEqual(String("").hashCode(), 0)
        self.assertEqual(lang.string_hash("Aa"), lang.string_hash("BB"))
        self.assertEqual(lang.string_hash("polygenelubricants"), -2147483648)
        self.assertTrue(String("a").equals("a"))
        self.assertFalse(String("a").equals(None))
        self.assertTrue(String("Ab").equalsIgnoreCase("aB"))
        self.assertEqual(String("apple").compareTo("banana"), -1)
        self.assertEqual(String("abc").compareTo("ab"), 1)
        self.assertEqual(String("B").compareToIgnoreCase("a"), 1)

    def test_search_and_transformations(self):
        text = String("  Hello, World  ")
        self.assertEqual(text.trim(), "Hello, World")
        self.assertEqual(String("a\u2003").trim(), "a\u2003")
        self.assertTrue(String(" \t").isBlank())
        self.assertEqual(String("abcabc").lastIndexOf("b"), 4)
        self.assertEqual(String("abcabc").lastIndexOf("b", 3), 1)
        self.assertEqual(String("abcabc").indexOf("c", 3), 5)
        self.assertEqual(String("abc").indexOf(98), 1)
        self.assertTrue(String("abc").startsWith("bc", 1))
        self.assertFalse(String("abc").startsWith("a", 9))
        self.assertTrue(String("abc").contains("bc"))
        self.assertEqual(String("a.b").replace(".", "-"), "a-b")
        self.assertEqual(String("aXbX").toLowerCase(), "axbx")
        self.assertEqual(String("ab").concat("c"), "abc")
        self.assertEqual(String("ab").repeat(2), "abab")
        self.assertEqual(String("ab").toCharArray(), ["a", "b"])
        self.assertEqual(bytes(String("\u00e9").getBytes()), b"\xc3\xa9")
        self.assertEqual(bytes(String("a").getBytes("UTF-16")), b"\xfe\xff\x00a")
        self.assertEqual(String("\u00e9").getBytes("UTF-8").to_bridge(), [-61, -87])

    def test_regex_methods_use_java_semantics(self):
        self.assertEqual(String("a,b,,").split(","), ["a", "b"])
        self.assertEqual(String("a,b,,").split(",", -1), ["a", "b", "", ""])
        self.assertEqual(String("a,b,c").split(",", 2), ["a", "b,c"])
        self.assertEqual(String("").split(","), [""])
        self.assertEqual(String("abc").split(""), ["a", "b", "c"])
        self.assertEqual(String("a.b").split("\\."), ["a", "b"])
        self.assertEqual(String("a  b").split(), ["a", "b"])
        self.assertEqual(String("a1b22").replaceAll("(\\d+)", "<$1>"), "a<1>b<22>")
        self.assertEqual(String("a1b22").replaceFirst("\\d", "\\$"), "a$b22")
        self.assertTrue(String("Hello").matches("(?i)hello"))
        self.assertFalse(String("Hello!").matches("Hello"))
        with self.assertRaises(lang.PatternSyntaxException):
            String("x").matches("(")
        with self.assertRaises(lang.IndexOutOfBoundsException):
            String("x").replaceAll("x", "$3")

    def test_static_helpers(self):
        self.assertEqual(String.valueOf(None), "null")
        self.assertEqual(String.valueOf(True), "true")
        self.assertEqual(String.valueOf(1.0), "1.0")
        self.assertEqual(String.valueOf(["h", "i"]), "hi")
        self.assertEqual(String.join(",", ["a", "b"]), "a,b")
        self.assertEqual(String.join("-", "a", "b", "c"), "a-b-c")
        self.assertEqual(String.join(",", [1, None]), "1,null")

    def test_format(self):
        cases = [
            (("%5d|%-5s|%05.1f", 42, "ab", 3.14159), "   42|ab   |003.1"),
            (("%,d %+d %(d", 1234567, 5, -3), "1,234,567 +5 (3)"),
            (("%x %X %o %#x", -1, 255, 8, 255), "ffffffff FF 10 0xff"),
            (("%s %S %b %c %%", None, "up", None, 65), "null UP false A %"),
            (("%.2f %.0f %.1f", 1.005, 0.5, 0.25), "1.01 1 0.3"),
            (("%e %.2E", 12345.678, 0.000123), "1.234568e+04 1.23E-04"),
            (("%g %g", 0.0001234, 1234567.0), "0.000123400 1.23457e+06"),
            (("%2$s %1$s %<s", "a", "b"), "b a a"),
            (("%10.3s|", "abcdef"), "       abc|"),
            (("%d%n", 2 ** 40), "1099511627776\n"),
            (("%f", float("nan")), "NaN"),
        ]
        for args, expected in cases:
            with self.subTest(args[0]):
                self.assertEqual(String.format(*args), expected)
        self.assertEqual(String.format(object(), "%d", 1), "1")
        with self.assertRaises(lang.MissingFormatArgumentException):
            String.format("%s %s", "only")
        with self.assertRaises(lang.UnknownFormatConversionException):
            String.format("%q", 1)
        with self.assertRaises(lang.IllegalFormatConversionException):
            String.format("%d", "text")
        with self.assertRaises(lang.IllegalFormatConversionException):
            String.format("%f", 1)
        with self.assertRaises(bridge.UnsupportedAPI):
            String.format("%tY", 0)

    def test_string_builder(self):
        builder = lang.StringBuilder("ab")
        self.assertIs(builder.append(1).append(True).append(None).append(1.5), builder)
        self.assertEqual(builder.toString(), "ab1truenull1.5")
        builder.insert(0, "X").deleteCharAt(1).replace(0, 1, "__").delete(2, 3)
        self.assertEqual(str(builder), "__1truenull1.5")
        self.assertEqual((builder.length(), len(builder), builder.indexOf("true"), builder.charAt(2)), (14, 14, 3, "1"))
        builder.setLength(3)
        self.assertEqual(builder.reverse().toString(), "1__")
        self.assertEqual(lang.StringBuilder().append(["a", "b"], 1, 1).toString(), "b")
        self.assertEqual(lang.StringBuilder(16).toString(), "")
        self.assertEqual(lang.StringBuffer("q").to_bridge(), "q")
        self.assertIsInstance(builder, lang.CharSequence)
        with self.assertRaises(lang.StringIndexOutOfBoundsException):
            builder.deleteCharAt(9)


class NumberTests(unittest.TestCase):
    def test_integer_parsing_is_strict(self):
        self.assertEqual(Integer.parseInt("-123"), -123)
        self.assertEqual(Integer.parseInt("+7"), 7)
        self.assertEqual(Integer.parseInt("ff", 16), 255)
        self.assertEqual(Integer.parseInt("-80000000", 16), -2 ** 31)
        self.assertEqual(Long.parseLong("9223372036854775807"), 2 ** 63 - 1)
        self.assertEqual(Integer.parseUnsignedInt("4294967295"), -1)
        for bad in ("", "+", "-", "1_0", " 1", "1 ", "2147483648", "0x10", "1.0"):
            with self.subTest(bad):
                with self.assertRaises(lang.NumberFormatException) as caught:
                    Integer.parseInt(bad)
                self.assertEqual(caught.exception.getMessage(), f'For input string: "{bad}"')
        with self.assertRaises(lang.NumberFormatException) as caught:
            Integer.parseInt(None)
        self.assertEqual(caught.exception.getMessage(), "s == null")
        with self.assertRaises(lang.NumberFormatException) as caught:
            Integer.parseInt("zz", 16)
        self.assertEqual(caught.exception.getMessage(), 'For input string: "zz" under radix 16')
        with self.assertRaises(ValueError):
            Integer.parseInt("x")

    def test_integer_boxes_are_ints_with_java_methods(self):
        box = Integer.valueOf(5)
        self.assertIsInstance(box, int)
        self.assertIsInstance(box, lang.Number)
        self.assertEqual((box + 1, box.intValue(), box.doubleValue(), box.toString(), str(box), box.hashCode()),
                         (6, 5, 5.0, "5", "5", 5))
        self.assertIs(type(box.to_bridge()), int)
        self.assertEqual(Integer("12"), 12)
        self.assertEqual(Integer.valueOf("-7f", 16), -127)
        self.assertTrue(box.equals(5))
        self.assertFalse(box.equals(True))
        self.assertEqual(box.compareTo(9), -1)
        self.assertEqual(Long(2 ** 40).intValue(), 0)
        self.assertEqual(Integer(300).byteValue(), 44)
        self.assertEqual(Long.hashCode(2 ** 40), 256)
        self.assertEqual(Long(-1).hashCode(), 0)
        with self.assertRaises(OverflowError):
            Integer(2 ** 31)
        with self.assertRaises(OverflowError):
            lang.Byte(128)
        with self.assertRaises(TypeError):
            Integer(True)
        with self.assertRaises(TypeError):
            Integer(1.5)

    def test_integer_static_helpers(self):
        self.assertEqual((Integer.MAX_VALUE, Integer.MIN_VALUE, Long.MAX_VALUE), (2 ** 31 - 1, -2 ** 31, 2 ** 63 - 1))
        self.assertEqual(Integer.toHexString(-1), "ffffffff")
        self.assertEqual(Long.toHexString(-1), "f" * 16)
        self.assertEqual(Integer.toBinaryString(5), "101")
        self.assertEqual(Integer.toString(255, 16), "ff")
        self.assertEqual(Integer.toString(-255, 2), "-11111111")
        self.assertEqual(Integer.toUnsignedString(-1), "4294967295")
        self.assertEqual(Integer.toUnsignedLong(-1), 4294967295)
        self.assertEqual((Integer.bitCount(-1), Integer.numberOfLeadingZeros(1), Integer.numberOfTrailingZeros(8)),
                         (32, 31, 3))
        self.assertEqual((Integer.highestOneBit(100), Integer.reverse(1), Integer.reverseBytes(1)),
                         (64, -2 ** 31, 16777216))
        self.assertEqual(Integer.rotateLeft(-2 ** 31, 1), 1)
        self.assertEqual(Integer.sum(2 ** 31 - 1, 1), -2 ** 31)
        self.assertEqual((Integer.compare(1, 2), Integer.signum(-9), Integer.compareUnsigned(-1, 1)), (-1, -1, 1))
        self.assertEqual(Integer.divideUnsigned(-1, 2), 2 ** 31 - 1)
        self.assertEqual((Integer.decode("0x10"), Integer.decode("-010"), Integer.decode("#ff")), (16, -8, 255))
        self.assertEqual((lang.Short.parseShort("-32768"), lang.Byte.toUnsignedInt(-1)), (-32768, 255))
        with self.assertRaises(lang.ArithmeticException):
            Integer.divideUnsigned(1, 0)

    def test_double_and_float(self):
        for value, expected in ((1.0, "1.0"), (100.5, "100.5"), (1e7, "1.0E7"), (1234567.0, "1234567.0"),
                                (0.001, "0.001"), (1e-4, "1.0E-4"), (1.5e-10, "1.5E-10"), (1e21, "1.0E21"),
                                (-0.0, "-0.0"), (math.inf, "Infinity"), (-math.inf, "-Infinity"),
                                (math.nan, "NaN"), (123456789012.0, "1.23456789012E11")):
            with self.subTest(value):
                self.assertEqual(Double.toString(value), expected)
        self.assertEqual(Float.toString(0.1), "0.1")
        self.assertEqual(Float(0.1).toString(), "0.1")
        self.assertEqual(Float.toString(16777216.0), "1.6777216E7")
        self.assertNotEqual(float(Float(0.1)), 0.1)
        self.assertEqual(Double.parseDouble(" 1.5e3 "), 1500.0)
        self.assertEqual(Double.parseDouble("0x1p3"), 8.0)
        self.assertEqual(Double.parseDouble("1.5f"), 1.5)
        self.assertEqual(Double.parseDouble("-Infinity"), -math.inf)
        self.assertTrue(Double("NaN").isNaN())
        self.assertTrue(Double.isNaN(math.nan))
        self.assertEqual(Float.parseFloat("3.4e39"), math.inf)
        for bad in ("abc", "1_0", "nan", "inf", "1,5"):
            with self.subTest(bad), self.assertRaises(lang.NumberFormatException):
                Double.parseDouble(bad)
        with self.assertRaises(lang.NumberFormatException) as caught:
            Double.parseDouble("  ")
        self.assertEqual(caught.exception.getMessage(), "empty String")
        with self.assertRaises(lang.NullPointerException):
            Double.parseDouble(None)
        self.assertEqual((Double(2.9).intValue(), Double(-2.9).intValue(), Double(1e30).intValue(),
                          Double(math.nan).longValue()), (2, -2, 2 ** 31 - 1, 0))
        self.assertEqual((Double.compare(0.0, -0.0), Double.compare(math.nan, math.inf)), (1, 1))
        self.assertTrue(Double(math.nan).equals(math.nan))
        self.assertFalse(Double(0.0).equals(-0.0))
        self.assertEqual(Double.doubleToLongBits(1.0), 0x3FF0000000000000)
        self.assertEqual(Double.longBitsToDouble(0x4000000000000000), 2.0)
        self.assertEqual(Float.floatToIntBits(1.0), 0x3F800000)
        self.assertEqual(Double(1.0).hashCode(), 1072693248)
        self.assertEqual(Double(3.5) + 1, 4.5)

    def test_boolean_and_character(self):
        self.assertIs(Boolean.valueOf("TRUE"), Boolean.TRUE)
        self.assertIs(Boolean.valueOf(False), Boolean.FALSE)
        self.assertTrue(Boolean.parseBoolean("True"))
        self.assertFalse(Boolean.parseBoolean("yes"))
        self.assertFalse(Boolean.parseBoolean(None))
        self.assertEqual((Boolean.TRUE == True, bool(Boolean.FALSE), Boolean(True).booleanValue()), (True, False, True))  # noqa: E712
        self.assertEqual((Boolean.TRUE.toString(), Boolean.toString(False), Boolean.TRUE.hashCode(), Boolean.hashCode(False)),
                         ("true", "false", 1231, 1237))
        self.assertIs(Boolean.TRUE.to_bridge(), True)
        self.assertNotEqual(Boolean.TRUE, 1)
        self.assertEqual(Boolean.TYPE.getName(), "boolean")
        self.assertTrue(Character.isDigit("5"))
        self.assertTrue(Character.isLetter("\u0436"))
        self.assertFalse(Character.isLetterOrDigit("_"))
        self.assertTrue(Character.isWhitespace("\n"))
        self.assertFalse(Character.isWhitespace("\u00a0"))
        self.assertEqual((Character.toUpperCase("a"), Character.toUpperCase(97), Character.toLowerCase("Q")), ("A", 65, "q"))
        self.assertEqual((Character.digit("f", 16), Character.digit("g", 16), Character.forDigit(11, 16)), (15, -1, "b"))
        self.assertEqual(Character.getNumericValue("z"), 35)
        self.assertEqual(Character.toChars(0x1F600), ["\ud83d", "\ude00"])
        self.assertEqual(Character("a").charValue(), "a")
        self.assertEqual(Character("a").hashCode(), 97)
        with self.assertRaises(TypeError):
            Character("ab")


class MathSystemTests(unittest.TestCase):
    def test_rounding_and_overflow_follow_java(self):
        math_ = lang.Math
        self.assertEqual((math_.round(2.5), math_.round(-2.5), math_.round(0.49999999999999994), math_.round(math.nan)),
                         (3, -2, 0, 0))
        self.assertEqual((math_.rint(2.5), math_.rint(3.5), math_.floor(-0.5), math_.ceil(-0.5)), (2.0, 4.0, -1.0, -0.0))
        self.assertEqual(math.copysign(1, math_.ceil(-0.5)), -1)
        self.assertEqual((math_.abs(-2 ** 31), math_.abs(-5), math_.abs(-1.5)), (-2 ** 31, 5, 1.5))
        self.assertEqual((math_.floorDiv(-7, 2), math_.floorMod(-7, 3), math_.floorDiv(-2 ** 31, -1)), (-4, 2, -2 ** 31))
        self.assertEqual((math_.max(1, 2), math_.max(1, 2.5), math_.min(-0.0, 0.0)), (2, 2.5, -0.0))
        self.assertEqual((math_.pow(2, 10), math_.pow(0, -1), math_.signum(-3.0)), (1024.0, math.inf, -1.0))
        self.assertTrue(math.isnan(math_.sqrt(-1)))
        self.assertTrue(math.isnan(math_.log(-1)))
        self.assertEqual(math_.log(0), -math.inf)
        self.assertAlmostEqual(math_.toDegrees(math_.PI), 180.0)
        self.assertEqual(math_.addExact(2 ** 31, 1), 2 ** 31 + 1)
        self.assertEqual(math_.toIntExact(7), 7)
        for call in (lambda: math_.addExact(2 ** 31 - 1, 1), lambda: math_.multiplyExact(2 ** 62, 2),
                     lambda: math_.toIntExact(2 ** 31), lambda: math_.negateExact(-2 ** 31),
                     lambda: math_.floorMod(1, 0)):
            with self.assertRaises(lang.ArithmeticException):
                call()
        self.assertTrue(0 <= math_.random() < 1)

    def test_system(self):
        system = lang.System
        self.assertGreater(system.currentTimeMillis(), 1_600_000_000_000)
        self.assertLessEqual(system.nanoTime(), system.nanoTime())
        self.assertEqual(system.getProperty("line.separator"), "\n")
        self.assertEqual(system.getProperty("file.separator"), "/")
        self.assertIsNone(system.getProperty("synthetic.absent"))
        self.assertEqual(system.getProperty("synthetic.absent", "fallback"), "fallback")
        self.assertIsNone(system.setProperty("synthetic.key", "one"))
        self.assertEqual(system.setProperty("synthetic.key", "two"), "one")
        self.assertEqual(system.clearProperty("synthetic.key"), "two")
        self.assertIsNone(system.getProperty("synthetic.key"))
        with self.assertRaises(lang.IllegalArgumentException):
            system.getProperty("")
        with self.assertRaises(lang.NullPointerException):
            system.getProperty(None)
        target = [0] * 5
        system.arraycopy([1, 2, 3], 1, target, 2, 2)
        self.assertEqual(target, [0, 0, 2, 3, 0])
        buffer = bytearray(3)
        system.arraycopy([-1, 5], 0, buffer, 1, 2)
        self.assertEqual(buffer, b"\x00\xff\x05")
        with self.assertRaises(lang.ArrayIndexOutOfBoundsException):
            system.arraycopy([1], 0, target, 4, 2)
        for call in (lambda: system.exit(0), lambda: lang.Runtime.getRuntime().exit(0),
                     lambda: lang.Runtime.getRuntime().exec("ls")):
            with self.assertRaises(bridge.UnsupportedAPI):
                call()
        self.assertGreaterEqual(lang.Runtime.getRuntime().availableProcessors(), 1)
        self.assertIs(lang.Runtime.getRuntime(), lang.Runtime.getRuntime())

    def test_modifier_and_references(self):
        modifier = lang.Modifier
        self.assertTrue(modifier.isStatic(modifier.STATIC | modifier.PUBLIC))
        self.assertFalse(modifier.isFinal(modifier.STATIC))
        self.assertTrue(modifier.isAbstract(1024))
        self.assertEqual(modifier.toString(25), "public static final")
        referent = lang.Object()
        weak = lang.WeakReference(referent)
        self.assertIs(weak.get(), referent)
        del referent
        self.assertIsNone(weak.get())
        self.assertEqual(lang.WeakReference("text").get(), "text")
        soft = lang.SoftReference(lang.Object())
        self.assertIsNotNone(soft.get())
        soft.clear()
        self.assertIsNone(soft.get())
        with self.assertRaises(bridge.UnsupportedAPI):
            lang.WeakReference(lang.Object(), object())

    def test_regex_translation(self):
        compiled = lang.translate_regex(r"(?<year>\d{4})-(?i)ab|c")
        self.assertEqual(compiled.pattern, r"(?P<year>\d{4})-(?i:ab)|(?i:c)")
        self.assertEqual(lang.translate_regex(r"\p{Alpha}+\Q.*\E\z").pattern, r"[a-zA-Z]+\.\*\Z")
        self.assertIsNone(lang.translate_regex("a.b").match("a\rb"))
        self.assertIsNotNone(lang.translate_regex("a.b", lang.DOTALL).match("a\nb"))
        self.assertIsNone(lang.translate_regex(r"\d").match("\u0663"))
        self.assertIsNotNone(lang.translate_regex(r"\d", lang.UNICODE_CHARACTER_CLASS).match("\u0663"))
        self.assertIsNotNone(lang.translate_regex("a+", lang.LITERAL).match("a+"))
        self.assertIsNotNone(lang.translate_regex(r"x*+y").match("xxy"))
        for unsupported in (r"\p{L}", r"[a-z&&[^b]]", r"\Ga", r"[a[b]]"):
            with self.subTest(unsupported), self.assertRaises(bridge.UnsupportedAPI):
                lang.translate_regex(unsupported)
        for broken in ("(", "[a", "a)", "*a"):
            with self.subTest(broken), self.assertRaises(lang.PatternSyntaxException):
                lang.translate_regex(broken)

    def test_value_helpers(self):
        self.assertEqual(lang.java_hash([1, 2]), 994)
        self.assertEqual(lang.java_hash(None), 0)
        self.assertEqual(lang.java_hash(True), 1231)
        self.assertEqual(lang.jstr([1, None, "a", 2.0]), "[1, null, a, 2.0]")
        self.assertEqual(lang.jstr({"k": True}), "{k=true}")
        data = lang.ByteArray(b"\xff\x01")
        self.assertEqual((data.to_bridge(), data.length, bytes(data)), ([-1, 1], 2, b"\xff\x01"))
        self.assertEqual(lang.to_bytes([-1, 255, 0]), b"\xff\xff\x00")
        with self.assertRaises(bridge.UnsupportedAPI):
            lang.fill_bytes(b"immutable", 0, b"x")


if __name__ == "__main__":
    unittest.main()
