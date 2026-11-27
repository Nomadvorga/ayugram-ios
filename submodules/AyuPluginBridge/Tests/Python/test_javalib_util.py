"""java.util provider, exercised directly: no host and no plugin source."""
from __future__ import annotations

import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Python"))

import ayu_bridge as bridge
from _ayu_javalib import java_lang as lang
from _ayu_javalib import java_util as util


class ListTests(unittest.TestCase):
    def test_array_list_is_a_python_list_with_java_methods(self):
        values = util.ArrayList()
        self.assertTrue(values.add("b"))
        self.assertIsNone(values.add(0, "a"))
        self.assertTrue(values.addAll([3, 4]))
        self.assertFalse(values.addAll([]))
        self.assertIsInstance(values, list)
        self.assertIsInstance(values, util.List)
        self.assertIsInstance(values, util.Collection)
        self.assertIsInstance([], util.List)
        self.assertNotIsInstance([], util.ArrayList)
        self.assertEqual((values, len(values), values.size(), values[0], values.get(1)), (["a", "b", 3, 4], 4, 4, "a", "b"))
        self.assertEqual((values.toString(), str(values), json.dumps(values)), ("[a, b, 3, 4]", "[a, b, 3, 4]", '["a", "b", 3, 4]'))
        self.assertEqual(values.set(1, "B"), "b")
        self.assertEqual((values.indexOf(3), values.lastIndexOf("zz"), values.contains(4), 4 in values), (2, -1, True, True))
        self.assertEqual(values.remove(0), "a")
        self.assertIs(values.remove("zz"), False)
        self.assertIs(values.remove("B"), True)
        self.assertEqual((values, values.to_bridge(), type(values.to_bridge())), ([3, 4], [3, 4], list))
        self.assertEqual((values.hashCode(), util.ArrayList([1, 2]).hashCode()), (31 * (31 + 3) + 4, 994))
        self.assertTrue(values.equals([3, 4]))
        self.assertFalse(values.equals([4, 3]))
        self.assertEqual(util.ArrayList(10), [])
        self.assertEqual(util.ArrayList((1, 2)).clone(), [1, 2])
        values.clear()
        self.assertTrue(values.isEmpty())

    def test_index_errors_are_java_and_python_errors(self):
        values = util.ArrayList([1])
        with self.assertRaises(lang.IndexOutOfBoundsException) as caught:
            values.get(3)
        self.assertEqual(caught.exception.getMessage(), "Index 3 out of bounds for length 1")
        with self.assertRaises(IndexError):
            values.set(-1, 0)
        with self.assertRaises(lang.IndexOutOfBoundsException):
            values.add(5, 0)
        with self.assertRaises(lang.IllegalArgumentException):
            util.ArrayList(-1)
        with self.assertRaises(lang.NullPointerException):
            values.addAll(None)

    def test_iterators_sort_and_views(self):
        values = util.ArrayList([1, 2, 3, 4])
        iterator = values.iterator()
        while iterator.hasNext():
            if iterator.next() % 2 == 0:
                iterator.remove()
        self.assertEqual(values, [1, 3])
        with self.assertRaises(util.NoSuchElementException):
            iterator.next()
        self.assertEqual(list(values.iterator()), [1, 3])
        cursor = values.listIterator()
        cursor.next()
        cursor.add(2)
        cursor.next()
        cursor.set(30)
        self.assertEqual((values, cursor.previous(), cursor.nextIndex()), ([1, 2, 30], 30, 2))
        values.sort(lambda left, right: right - left)
        self.assertEqual(values, [30, 2, 1])
        values.sort(None)
        self.assertEqual(values, [1, 2, 30])
        values.sort(key=lambda item: -item)
        self.assertEqual(values, [30, 2, 1])
        values.replaceAll(lambda item: item * 2)
        self.assertTrue(values.removeIf(lambda item: item > 10))
        self.assertEqual(values, [4, 2])
        seen = []
        values.forEach(seen.append)
        self.assertEqual(seen, [4, 2])
        base = util.ArrayList([0, 1, 2, 3, 4])
        window = base.subList(1, 4)
        self.assertEqual((window.size(), window.get(0), list(window)), (3, 1, [1, 2, 3]))
        window.set(0, 10)
        window.add(99)
        self.assertEqual(base, [0, 10, 2, 3, 99, 4])
        window.clear()
        self.assertEqual(base, [0, 4])
        with self.assertRaises(lang.IndexOutOfBoundsException):
            base.subList(1, 9)
        with self.assertRaises(bridge.UnsupportedAPI):
            base.stream()

    def test_deques_stacks_and_queues(self):
        linked = util.LinkedList([1, 2, 3])
        linked.addFirst(0)
        linked.push(-1)
        self.assertEqual((linked.pop(), linked.poll(), linked.peek(), linked.peekLast(), linked.removeLast(), linked.remove()),
                         (-1, 0, 1, 3, 3, 1))
        self.assertEqual((linked, linked.offer(9), linked.getLast(), linked.get(0)), ([2, 9], True, 9, 2))
        self.assertIsNone(util.LinkedList().poll())
        with self.assertRaises(util.NoSuchElementException):
            util.LinkedList().removeFirst()
        deque = util.ArrayDeque()
        deque.push(1)
        deque.addLast(2)
        self.assertEqual((deque.pollFirst(), deque.pollLast(), deque.pollFirst()), (1, 2, None))
        with self.assertRaises(lang.NullPointerException):
            deque.add(None)
        self.assertFalse(hasattr(deque, "get"))
        stack = util.Stack()
        stack.push(1)
        self.assertEqual((stack.push(2), stack.peek(), stack.search(1), stack.pop(), stack.empty()), (2, 2, 2, 2, False))
        stack.pop()
        with self.assertRaises(util.EmptyStackException):
            stack.pop()
        queue = util.PriorityQueue()
        for item in (5, 1, 3):
            queue.add(item)
        self.assertEqual((queue.peek(), queue.poll(), queue.poll(), queue.size(), 5 in queue), (1, 1, 3, 1, True))
        longest = util.PriorityQueue(4, lambda left, right: len(right) - len(left))
        longest.addAll(["a", "ccc", "bb"])
        self.assertEqual(longest.poll(), "ccc")
        vector = util.Vector([1])
        vector.addElement(2)
        self.assertEqual((vector.elementAt(1), vector.firstElement(), list(vector.elements())), (2, 1, [1, 2]))


class MapSetTests(unittest.TestCase):
    def test_hash_map_is_a_dict_with_java_methods(self):
        mapping = util.HashMap()
        self.assertIsNone(mapping.put("a", 1))
        self.assertEqual(mapping.put("a", 2), 1)
        self.assertIsInstance(mapping, dict)
        self.assertIsInstance(mapping, util.Map)
        self.assertIsInstance({}, util.Map)
        self.assertEqual((mapping.get("a"), mapping.get("zz"), mapping.getOrDefault("zz", 9), mapping["a"]), (2, None, 9, 2))
        self.assertEqual((mapping.containsKey("a"), mapping.containsValue(2), mapping.size(), mapping.isEmpty()),
                         (True, True, 1, False))
        self.assertEqual((mapping.toString(), json.dumps(mapping), mapping.to_bridge()), ("{a=2}", '{"a": 2}', {"a": 2}))
        self.assertEqual((mapping.putIfAbsent("a", 5), mapping.putIfAbsent("b", 5)), (2, None))
        self.assertEqual((mapping.computeIfAbsent("c", lambda key: key * 2), mapping.merge("b", 1, lambda a, b: a + b)),
                         ("cc", 6))
        self.assertEqual((mapping.compute("b", lambda key, value: None), mapping.containsKey("b")), (None, False))
        self.assertEqual((mapping.replace("a", 7), mapping.replace("zz", 1), mapping.remove("zz"), mapping.remove("c")),
                         (2, None, None, "cc"))
        self.assertEqual((mapping.remove("a", 0), mapping.remove("a", 7), mapping), (False, True, {}))
        self.assertEqual(util.HashMap({"x": 1}).hashCode(), lang.string_hash("x") ^ 1)
        self.assertTrue(util.HashMap({"x": 1}).equals({"x": 1}))
        self.assertFalse(util.HashMap().containsKey([]))

    def test_map_views_are_live(self):
        mapping = util.HashMap({"x": 1, "y": 2})
        for entry in mapping.entrySet():
            entry.setValue(entry.getValue() * 10)
        self.assertEqual(mapping, {"x": 10, "y": 20})
        self.assertEqual([(key, value) for key, value in mapping.entrySet()], [("x", 10), ("y", 20)])
        keys, values = mapping.keySet(), mapping.values()
        self.assertEqual((list(keys), list(values), keys.contains("x"), values.contains(20), len(keys)),
                         (["x", "y"], [10, 20], True, True, 2))
        self.assertTrue(keys.remove("x"))
        self.assertEqual(mapping, {"y": 20})
        mapping.put("z", 30)
        self.assertEqual((list(keys), values.size()), (["y", "z"], 2))
        with self.assertRaises(lang.UnsupportedOperationException):
            keys.add("new")
        iterator = mapping.keySet().iterator()
        iterator.next()
        iterator.remove()
        self.assertEqual(mapping, {"z": 30})
        self.assertEqual(util.Map.entry("k", 1).getKey(), "k")
        self.assertIs(util.Map.Entry, util.CLASSES["java.util.Map$Entry"])

    def test_ordered_sorted_and_weak_maps(self):
        cache = util.LinkedHashMap(4, 0.75, True)
        cache.removeEldestEntry = lambda eldest: cache.size() > 2
        for key in "abc":
            cache.put(key, key.upper())
        self.assertEqual(list(cache), ["b", "c"])
        cache.get("b")
        cache.put("d", "D")
        self.assertEqual(list(cache), ["b", "d"])
        tree = util.TreeMap()
        for key in (3, 1, 2):
            tree.put(key, key * 2)
        self.assertEqual((list(tree), tree.toString(), dict(tree), json.dumps(tree)),
                         ([1, 2, 3], "{1=2, 2=4, 3=6}", {1: 2, 2: 4, 3: 6}, '{"1": 2, "2": 4, "3": 6}'))
        self.assertEqual((tree.firstKey(), tree.lastKey(), tree.floorKey(2), tree.lowerKey(1), tree.higherKey(3),
                          tree.ceilingKey(0)), (1, 3, 2, None, None, 1))
        self.assertEqual((tree.lastEntry().getValue(), list(tree.headMap(3)), list(tree.tailMap(2)),
                          list(tree.subMap(1, 3)), tree.pollFirstEntry().getKey(), list(tree.keySet())),
                         (6, [1, 2], [2, 3], [1, 2], 1, [2, 3]))
        with self.assertRaises(lang.UnsupportedOperationException):
            tree.headMap(3).put(0, 0)
        with self.assertRaises(lang.NullPointerException):
            tree.put(None, 1)
        with self.assertRaises(util.NoSuchElementException):
            util.TreeMap().firstKey()
        descending = util.TreeMap(lambda left, right: right - left)
        descending.putAll({1: "a", 2: "b"})
        self.assertEqual(list(descending), [2, 1])
        with self.assertRaises(lang.NullPointerException):
            util.Hashtable().put("k", None)
        weak = util.WeakHashMap()
        key = lang.Object()
        weak.put(key, 1)
        weak.put("text", 2)
        self.assertEqual((weak.size(), weak.get(key), weak.containsKey("text")), (2, 1, True))
        del key
        self.assertEqual((weak.size(), list(weak.keySet())), (1, ["text"]))

    def test_sets(self):
        values = util.HashSet([1, 2])
        self.assertEqual((values.add(1), values.add(3), values.remove(9), values.remove(1), values.contains(2)),
                         (False, True, False, True, True))
        self.assertIsInstance(values, util.Set)
        self.assertIsInstance(set(), util.Set)
        self.assertEqual((len(values), sorted(values), 2 in values, values == {2, 3}, values | {9}, values & {2},
                          str(values), sorted(values.to_bridge())), (2, [2, 3], True, True, {2, 3, 9}, {2}, "[2, 3]", [2, 3]))
        self.assertEqual(values.hashCode(), 5)
        self.assertTrue(values.removeAll([3]))
        self.assertTrue(values.retainAll([5]))
        self.assertTrue(values.isEmpty())
        ordered = util.LinkedHashSet(["b", "a", "b"])
        self.assertEqual(list(ordered), ["b", "a"])
        tree = util.TreeSet([3, 1, 2])
        self.assertEqual((list(tree), tree.first(), tree.last(), tree.floor(2), tree.lower(1), tree.ceiling(4), tree.higher(1)),
                         ([1, 2, 3], 1, 3, 2, None, None, 2))
        self.assertEqual((list(tree.headSet(3)), list(tree.tailSet(2)), list(tree.subSet(1, 3)), tree.pollFirst(),
                          tree.pollLast(), len(tree)), ([1, 2], [2, 3], [1, 2], 1, 3, 1))
        self.assertEqual(list(util.TreeSet(lambda left, right: right - left).descendingIterator()), [])
        self.assertFalse([] in util.HashSet())


class UtilityTests(unittest.TestCase):
    def test_arrays(self):
        arrays = util.Arrays
        self.assertEqual((arrays.asList(1, 2), arrays.asList([1, 2]), arrays.toString([1, 2.0, "x", None]),
                          arrays.toString(None), arrays.toString(b"\xff")), ([1, 2], [1, 2], "[1, 2.0, x, null]", "null", "[-1]"))
        self.assertEqual((arrays.copyOf([1, 2], 4), arrays.copyOf(["a"], 2), arrays.copyOf([True], 2), arrays.copyOf([1, 2], 1),
                          arrays.copyOfRange([1, 2, 3], 1, 5)), ([1, 2, 0, 0], ["a", None], [True, False], [1], [2, 3, 0, 0]))
        self.assertEqual(bytes(arrays.copyOf(b"ab", 3)), b"ab\x00")
        self.assertEqual((arrays.hashCode([1, 2]), arrays.hashCode(None), arrays.equals([1], [1]), arrays.equals(None, [1])),
                         (994, 0, True, False))
        target = [3, 1, 2, 9, 0]
        arrays.sort(target, 0, 3)
        self.assertEqual(target, [1, 2, 3, 9, 0])
        arrays.sort(target, lambda left, right: right - left)
        self.assertEqual(target, [9, 3, 2, 1, 0])
        arrays.fill(target, 1, 3, 7)
        self.assertEqual((target, arrays.binarySearch([1, 3, 5], 3), arrays.binarySearch([1, 3, 5], 4)), ([9, 7, 7, 1, 0], 1, -3))
        with self.assertRaises(lang.NegativeArraySizeException):
            arrays.copyOf([1], -1)

    def test_collections(self):
        collections = util.Collections
        values = [3, 1, 2]
        collections.sort(values)
        collections.reverse(values)
        collections.swap(values, 0, 2)
        self.assertEqual((values, collections.max(values), collections.min(values, lambda a, b: b - a),
                          collections.frequency([1, 1, 2], 1), collections.disjoint([1], [2])), ([1, 2, 3], 3, 3, 2, True))
        collections.sort(values, collections.reverseOrder())
        self.assertEqual(values, [3, 2, 1])
        for view in (collections.unmodifiableList(values), collections.emptyList(), collections.singletonList(1),
                     collections.nCopies(2, "x")):
            with self.assertRaises(lang.UnsupportedOperationException):
                view.add(1)
        read_only = collections.unmodifiableList(values)
        values.append(0)
        self.assertEqual((read_only.size(), read_only.get(3), list(collections.nCopies(2, "x")), collections.emptyMap().size()),
                         (4, 0, ["x", "x"], 0))
        with self.assertRaises(lang.UnsupportedOperationException):
            collections.unmodifiableMap({"a": 1}).put("b", 2)
        with self.assertRaises(lang.UnsupportedOperationException):
            collections.singleton(1).add(2)
        guarded = collections.synchronizedMap(util.HashMap())
        guarded.put("a", 1)
        self.assertEqual((guarded.get("a"), guarded.size(), list(guarded.keySet())), (1, 1, ["a"]))
        shared = util.ArrayList()
        collections.synchronizedList(shared).add(1)
        self.assertEqual(shared, [1])
        weak = collections.newSetFromMap(util.WeakHashMap())
        member = lang.Object()
        self.assertEqual((weak.add(member), weak.add(member), weak.contains(member), len(weak)), (True, False, True, 1))
        with self.assertRaises(lang.IllegalArgumentException):
            collections.newSetFromMap({"k": True})
        self.assertEqual(collections.list(collections.enumeration([1, 2])), [1, 2])

    def test_objects_optional_and_comparator(self):
        objects = util.Objects
        self.assertEqual((objects.hash(1, 2), objects.hash("a", None), objects.hashCode(None), objects.equals(None, None),
                          objects.equals(1, True), objects.toString(None), objects.toString(None, "d"), objects.isNull(None)),
                         (994, 3968, 0, True, False, "null", "d", True))
        self.assertEqual(objects.requireNonNull(5), 5)
        with self.assertRaises(lang.NullPointerException) as caught:
            objects.requireNonNull(None, "needed")
        self.assertEqual(caught.exception.getMessage(), "needed")
        optional = util.Optional
        self.assertEqual((optional.ofNullable(None).orElse(5), optional.of(3).map(lambda value: value + 1).get(),
                          optional.empty().isPresent(), optional.of(1).filter(lambda value: value > 5).isEmpty(),
                          optional.of("x").toString(), optional.empty().toString()), (5, 4, False, True, "Optional[x]", "Optional.empty"))
        with self.assertRaises(util.NoSuchElementException):
            optional.empty().get()
        with self.assertRaises(lang.NullPointerException):
            optional.of(None)
        by_length = util.Comparator.comparing(len).thenComparing(util.Comparator.naturalOrder())
        words = util.ArrayList(["bb", "a", "ab"])
        words.sort(by_length)
        self.assertEqual(words, ["a", "ab", "bb"])
        words.sort(by_length.reversed())
        self.assertEqual((words, util.Comparator.nullsFirst(util.Comparator.naturalOrder()).compare(None, 1)),
                         (["bb", "ab", "a"], -1))

    def test_random_reproduces_the_java_generator(self):
        self.assertEqual(util.Random(42).nextInt(), -1170105035)
        zero = util.Random(0)
        self.assertEqual(zero.nextInt(), -1155484576)
        self.assertEqual(util.Random(0).nextInt(100), 60)
        self.assertEqual(util.Random(0).nextLong(), -4962768465676381896)
        self.assertEqual(util.Random(0).nextDouble(), 0.730967787376657)
        self.assertEqual(util.Random(0).nextGaussian(), 0.8025330637390305)
        self.assertIs(util.Random(0).nextBoolean(), True)
        buffer = bytearray(5)
        util.Random(0).nextBytes(buffer)
        self.assertEqual(buffer[:4], (-1155484576 & 0xFFFFFFFF).to_bytes(4, "little"))
        self.assertTrue(5 <= util.Random().nextInt(5, 10) < 10)
        with self.assertRaises(lang.IllegalArgumentException):
            util.Random(0).nextInt(0)

    def test_uuid_and_base64(self):
        uuid = util.UUID.fromString("123e4567-e89b-12d3-a456-426614174000")
        self.assertEqual((uuid.toString(), uuid.getMostSignificantBits(), uuid.getLeastSignificantBits(), uuid.version(),
                          uuid.variant()), ("123e4567-e89b-12d3-a456-426614174000", 0x123E4567E89B12D3,
                                            0xA456426614174000 - 2 ** 64, 1, 2))
        self.assertEqual(util.UUID(uuid.getMostSignificantBits(), uuid.getLeastSignificantBits()), uuid)
        self.assertEqual(str(util.UUID.nameUUIDFromBytes(b"hello")), "5d41402a-bc4b-3a76-b971-9d911017c592")
        self.assertEqual((util.UUID.randomUUID().version(), util.UUID(0, 1).compareTo(util.UUID(0, 2)), uuid.to_bridge()),
                         (4, -1, "123e4567-e89b-12d3-a456-426614174000"))
        with self.assertRaises(lang.IllegalArgumentException):
            util.UUID.fromString("not-a-uuid")
        codec = util.Base64
        self.assertEqual((codec.getEncoder().encodeToString(b"hello"), bytes(codec.getDecoder().decode("aGVsbG8=")),
                          bytes(codec.getDecoder().decode("aGVsbG8")), codec.getUrlEncoder().encodeToString(b"\xfb\xff"),
                          bytes(codec.getUrlDecoder().decode("-_8")), codec.getEncoder().withoutPadding().encodeToString(b"a")),
                         ("aGVsbG8=", b"hello", b"hello", "-_8=", b"\xfb\xff", "YQ"))
        self.assertEqual(bytes(codec.getMimeEncoder().encode(b"x" * 60)).count(b"\r\n"), 1)
        self.assertEqual(bytes(codec.getMimeDecoder().decode("aGVs\r\nbG8=")), b"hello")
        for broken in ("a", "aGVs!G8=", "aGVsbG8=="):
            with self.subTest(broken), self.assertRaises(lang.IllegalArgumentException):
                codec.getDecoder().decode(broken)

    def test_small_text_helpers(self):
        joiner = util.StringJoiner(",", "[", "]")
        self.assertEqual((joiner.setEmptyValue("none").toString(), joiner.add(1).add("b").toString()), ("none", "[1,b]"))
        tokens = util.StringTokenizer("a b  c")
        self.assertEqual((tokens.countTokens(), tokens.nextToken(), list(tokens), tokens.hasMoreTokens()), (3, "a", ["b", "c"], False))
        self.assertEqual(list(util.StringTokenizer("a,b", ",", True)), ["a", ",", "b"])
        self.assertEqual((util.Locale("RU", "ru").toString(), util.Locale.US.toLanguageTag(), util.Locale.ROOT.toString(),
                          util.Locale.forLanguageTag("pt-BR").getCountry(), util.Locale("en") == util.Locale.ENGLISH),
                         ("ru_RU", "en-US", "", "BR", True))
        self.assertFalse(hasattr(util.Locale.US, "getDisplayLanguage"))


class RegexTests(unittest.TestCase):
    def test_matcher(self):
        pattern = util.Pattern.compile(r"(\w+)@(?<host>\w+)\.com", util.Pattern.CASE_INSENSITIVE)
        matcher = pattern.matcher("a@B.com, c@d.COM")
        found = []
        while matcher.find():
            found.append((matcher.group(), matcher.group(1), matcher.group("host"), matcher.start(), matcher.end(2)))
        self.assertEqual(found, [("a@B.com", "a", "B", 0, 3), ("c@d.COM", "c", "d", 9, 12)])
        self.assertEqual((matcher.groupCount(), matcher.replaceAll("$2:$1"), matcher.replaceFirst("${host}"), pattern.pattern(),
                          pattern.flags()), (2, "B:a, d:c", "B, c@d.COM", r"(\w+)@(?<host>\w+)\.com", 2))
        self.assertEqual((util.Pattern.matches("a*b", "aaab"), pattern.matcher("x a@b.com").matches(),
                          pattern.matcher("a@b.com x").lookingAt(), pattern.split("x a@b.com y"),
                          util.Pattern.compile(util.Pattern.quote("a.b")).matcher("a.b").matches(),
                          util.Pattern.compile(util.Pattern.quote("a.b")).matcher("axb").matches()),
                         (True, False, True, ["x ", " y"], True, False))
        with self.assertRaises(lang.IllegalStateException):
            pattern.matcher("zzz").group()
        with self.assertRaises(lang.IndexOutOfBoundsException):
            matcher.reset().find() and matcher.group(7)
        with self.assertRaises(lang.IllegalArgumentException):
            matcher.group("absent")
        buffer, each = lang.StringBuffer(), util.Pattern.compile("o").matcher("foo boo")
        while each.find():
            each.appendReplacement(buffer, "0")
        each.appendTail(buffer)
        self.assertEqual((buffer.toString(), each.find(4), each.start()), ("f00 b00", True, 5))
        empty = util.Pattern.compile("x*").matcher("ab")
        positions = []
        while empty.find():
            positions.append(empty.start())
        self.assertEqual(positions, [0, 1, 2])
        self.assertEqual(util.Matcher.quoteReplacement("$1\\"), "\\$1\\\\")


class DateTests(unittest.TestCase):
    def test_date_and_time_zone(self):
        utc = util.TimeZone.getTimeZone("UTC")
        self.assertEqual((utc.getID(), utc.getRawOffset(), utc.getOffset(0), utc.useDaylightTime()), ("UTC", 0, 0, False))
        custom = util.TimeZone.getTimeZone("GMT+3")
        self.assertEqual((custom.getID(), custom.getRawOffset(), util.TimeZone.getTimeZone("GMT-05:30").getOffset(0)),
                         ("GMT+03:00", 10800000, -19800000))
        import zoneinfo
        if zoneinfo.available_timezones():
            self.assertEqual(util.TimeZone.getTimeZone("Synthetic/Nowhere").getID(), "GMT")
        else:
            with self.assertRaises(bridge.UnsupportedAPI):
                util.TimeZone.getTimeZone("Synthetic/Nowhere")
        self.assertEqual(util.TimeZone.getDefault(), util.TimeZone.getDefault())
        epoch = util.Date(0)
        self.assertEqual((epoch.getTime(), util.Date(5).after(epoch), epoch.before(util.Date(5)), epoch.compareTo(util.Date(0)),
                          epoch == util.Date(0), epoch.hashCode(), util.Date(2 ** 40).hashCode(), epoch.to_bridge()),
                         (0, True, True, 0, True, 0, 256, 0))
        self.assertGreater(util.Date().getTime(), 1_600_000_000_000)
        util.TimeZone.setDefault(utc)
        try:
            self.assertEqual((epoch.toString(), epoch.getYear(), epoch.getMonth(), epoch.getDate(), epoch.getDay(),
                              epoch.getHours()), ("Thu Jan 01 00:00:00 UTC 1970", 70, 0, 1, 4, 0))
        finally:
            lang.scoped_store("timezone").pop("default", None)
        with self.assertRaises(TypeError):
            util.Date("2020")

    def test_calendar_fields_are_deferred_and_lenient(self):
        calendar = util.Calendar.getInstance(util.TimeZone.getTimeZone("UTC"))
        calendar.setTimeInMillis(1700000000000)
        fields = util.Calendar
        self.assertEqual([calendar.get(field) for field in (fields.YEAR, fields.MONTH, fields.DAY_OF_MONTH, fields.DAY_OF_WEEK,
                                                           fields.HOUR_OF_DAY, fields.HOUR, fields.AM_PM, fields.MINUTE,
                                                           fields.SECOND, fields.DAY_OF_YEAR, fields.WEEK_OF_YEAR,
                                                           fields.WEEK_OF_MONTH, fields.ZONE_OFFSET)],
                         [2023, 10, 14, fields.TUESDAY, 22, 10, fields.PM, 13, 20, 318, 46, 3, 0])
        calendar.set(2024, fields.JANUARY, 31)
        calendar.set(fields.MONTH, fields.FEBRUARY)
        calendar.set(fields.DAY_OF_MONTH, 1)
        self.assertEqual((calendar.get(fields.MONTH), calendar.get(fields.DATE)), (1, 1))
        calendar.set(2024, 0, 31)
        calendar.set(fields.MONTH, 1)
        self.assertEqual((calendar.get(fields.MONTH), calendar.get(fields.DATE)), (2, 2))
        calendar.set(2024, 0, 31, 10, 0, 0)
        calendar.add(fields.MONTH, 1)
        self.assertEqual((calendar.get(fields.MONTH), calendar.get(fields.DATE), calendar.getActualMaximum(fields.DATE)), (1, 29, 29))
        calendar.add(fields.DAY_OF_MONTH, 1)
        calendar.add(fields.HOUR_OF_DAY, -11)
        self.assertEqual((calendar.get(fields.MONTH), calendar.get(fields.DATE), calendar.get(fields.HOUR_OF_DAY)), (1, 29, 23))
        calendar.set(fields.DAY_OF_WEEK, fields.SUNDAY)
        self.assertEqual(calendar.get(fields.DATE), 25)
        gregorian = util.GregorianCalendar(2021, 11, 31)
        self.assertEqual((gregorian.get(fields.WEEK_OF_YEAR), gregorian.getActualMaximum(fields.DAY_OF_YEAR),
                          gregorian.isLeapYear(2024), gregorian.isLeapYear(1900)), (1, 365, True, False))
        clone = calendar.clone()
        clone.add(fields.YEAR, 1)
        self.assertTrue(calendar.before(clone))
        self.assertEqual(calendar.getTime().getTime(), calendar.getTimeInMillis())
        with self.assertRaises(bridge.UnsupportedAPI):
            calendar.setLenient(False)
        with self.assertRaises(bridge.UnsupportedAPI):
            util.Calendar()


if __name__ == "__main__":
    unittest.main()
