"""java.text, java.time, java.net value classes and org.json, exercised directly; no host."""
from __future__ import annotations

import math
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Python"))

import ayu_bridge as bridge
from _ayu_javalib import java_io as io
from _ayu_javalib import java_lang as lang
from _ayu_javalib import java_net as net
from _ayu_javalib import java_text as text
from _ayu_javalib import java_time as time
from _ayu_javalib import java_util as util
from _ayu_javalib import org_json as json

MOMENT = 1700000000123  # 2023-11-14T22:13:20.123Z, a Tuesday


class SimpleDateFormatTests(unittest.TestCase):
    def formatted(self, pattern, zone="GMT+05:30"):
        formatter = text.SimpleDateFormat(pattern, util.Locale.US)
        formatter.setTimeZone(util.TimeZone.getTimeZone(zone))
        return formatter.format(util.Date(MOMENT))

    def test_format_letters(self):
        cases = {
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ": "2023-11-15T03:43:20.123+0530",
            "EEE, d MMM yyyy hh:mm a z": "Wed, 15 Nov 2023 03:43 AM GMT+05:30",
            "EEEE MMMM dd yy": "Wednesday November 15 23",
            "D w W F u k K h": "319 46 3 3 3 3 3 3",
            "yyyyMMdd HHmmss": "20231115 034320",
            "XXX XX X": "+05:30 +0530 +0530",
            "''yy'year' G": "'23year AD",
            "y M d H m s S": "2023 11 15 3 43 20 123",
        }
        for pattern, expected in cases.items():
            with self.subTest(pattern):
                self.assertEqual(self.formatted(pattern), expected)
        self.assertEqual((self.formatted("HH:mm z X", "UTC"), self.formatted("kk", "GMT+02:00"), self.formatted("Z", "GMT-08:00")),
                         ("22:13 UTC Z", "24", "-0800"))
        formatter = text.SimpleDateFormat("yyyy")
        self.assertEqual((formatter.toPattern(), formatter.format(MOMENT)[:2], formatter.clone() == formatter), ("yyyy", "20", True))

    def test_parse(self):
        formatter = text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSZ", util.Locale.US)
        self.assertEqual(formatter.parse("2023-11-14T22:13:20.123+0000").getTime(), MOMENT)
        self.assertEqual(formatter.parse("2023-11-15T03:43:20.123+0530").getTime(), MOMENT)
        utc = util.TimeZone.getTimeZone("UTC")

        def parsed(pattern, value):
            parser = text.SimpleDateFormat(pattern, util.Locale.US)
            parser.setTimeZone(utc)
            return parser.parse(value).getTime()

        day = 86_400_000
        self.assertEqual(parsed("yyyyMMdd", "19700102"), day)
        self.assertEqual(parsed("d MMM yyyy h:mm a", "2 January 1970 3:07 PM"), day + (15 * 60 + 7) * 60_000)
        self.assertEqual(parsed("dd/MM/yyyy", "32/01/1970"), 31 * day)
        self.assertEqual(parsed("HH:mm", "01:30"), 5_400_000)
        self.assertEqual(parsed("yyyy-MM-dd HH:mm XXX", "1970-01-01 05:30 +05:30"), 0)
        self.assertEqual(util.Date(parsed("yy", "99")).toInstant().toString()[:4], "1999")
        with self.assertRaises(text.ParseException) as caught:
            formatter.parse("2023-11-xx")
        self.assertEqual((caught.exception.getMessage(), caught.exception.getErrorOffset()), ('Unparseable date: "2023-11-xx"', 8))
        position = text.ParsePosition(0)
        self.assertEqual((formatter.parse("garbage", position), position.getErrorIndex(), position.getIndex()), (None, 0, 0))

    def test_russian_names(self):
        russian, utc = util.Locale("ru", "RU"), util.TimeZone.getTimeZone("UTC")
        cases = {
            "d MMMM yyyy, EEEE": "14 \u043d\u043e\u044f\u0431\u0440\u044f 2023, \u0432\u0442\u043e\u0440\u043d\u0438\u043a",
            "d MMM yy, EEE": "14 \u043d\u043e\u044f\u0431. 23, \u0432\u0442",
            "LLLL": "\u043d\u043e\u044f\u0431\u0440\u044c",
            "h:mm a": "10:13 PM",
        }
        for pattern, expected in cases.items():
            with self.subTest(pattern):
                formatter = text.SimpleDateFormat(pattern, russian)
                formatter.setTimeZone(utc)
                self.assertEqual(formatter.format(util.Date(MOMENT)), expected)
        parser = text.SimpleDateFormat("d MMMM yyyy", russian)
        parser.setTimeZone(utc)
        self.assertEqual(parser.parse("2 \u042f\u041d\u0412\u0410\u0420\u042f 1970").getTime(), 86_400_000)
        with self.assertRaises(text.ParseException):
            parser.parse("2 January 1970")
        zoned = time.ZonedDateTime.ofInstant(time.Instant.ofEpochMilli(MOMENT), time.ZoneOffset.UTC)
        self.assertEqual(zoned.format(time.DateTimeFormatter.ofPattern("d MMMM", russian)), "14 \u043d\u043e\u044f\u0431\u0440\u044f")
        self.assertEqual((text.DecimalFormat("#,##0.00", text.DecimalFormatSymbols(russian)).format(1234567.5),
                          text.NumberFormat.getPercentInstance(russian).format(0.256), text.NumberFormat.getInstance(russian).parse("1\u00a0234,5")),
                         ("1\u00a0234\u00a0567,50", "26\u00a0%", 1234.5))

    def test_rejections(self):
        with self.assertRaises(lang.IllegalArgumentException) as caught:
            text.SimpleDateFormat("yyyy QQ")
        self.assertEqual(caught.exception.getMessage(), "Illegal pattern character 'Q'")
        with self.assertRaises(lang.IllegalArgumentException):
            text.SimpleDateFormat("'open")
        with self.assertRaises(bridge.UnsupportedAPI):
            text.SimpleDateFormat("d MMMM", util.Locale("de"))
        self.assertEqual(text.SimpleDateFormat("dd.MM", util.Locale("de")).toPattern(), "dd.MM")
        with self.assertRaises(bridge.UnsupportedAPI):
            self.formatted("zzzz")
        with self.assertRaises(bridge.UnsupportedAPI):
            text.SimpleDateFormat("yyyy").setLenient(False)
        self.assertEqual(text.SimpleDateFormat("dd.MM.yyyy", util.Locale("ru")).format(util.Date(0))[2], ".")
        self.assertEqual((text.DateFormat.getDateInstance(text.DateFormat.MEDIUM, util.Locale.US).toPattern(),
                          text.DateFormat.getTimeInstance(text.DateFormat.SHORT, util.Locale.US).toPattern()), ("MMM d, y", "h:mm a"))
        with self.assertRaises(bridge.UnsupportedAPI):
            text.DateFormat.getDateInstance(text.DateFormat.MEDIUM, util.Locale.FRANCE)


class DecimalFormatTests(unittest.TestCase):
    def test_format(self):
        cases = [("#,##0.00", 1234567.891, "1,234,567.89"), ("0.0", 0.25, "0.2"), ("0.0", 0.35, "0.4"), ("#.##", 0.5, ".5"),
                 ("000", 7, "007"), ("#,###", 1234567, "1,234,567"), ("0.00%", 0.1234, "12.34%"), ("#", 2.5, "2"),
                 ("#", 3.5, "4"), ("0.0", -0.001, "-0.0"), ("$#,##0.00;($#,##0.00)", -1234.5, "($1,234.50)"),
                 ("0.###", 1.0, "1"), ("#,##0.###", 1234.56789, "1,234.568"), ("'#'0", 5, "#5"), ("0.0", math.nan, "NaN"),
                 ("0", -math.inf, "-\u221e"), ("0.", 5, "5."), ("#,##,##0", 1234567, "1,234,567")]
        for pattern, value, expected in cases:
            with self.subTest(pattern=pattern, value=value):
                self.assertEqual(text.DecimalFormat(pattern).format(value), expected)
        rounding = text.CLASSES["java.math.RoundingMode"]
        half_up = text.DecimalFormat("0.00")
        half_up.setRoundingMode(rounding.HALF_UP)
        floor = text.DecimalFormat("0")
        floor.setRoundingMode(rounding.FLOOR)
        self.assertEqual((half_up.format(1.005), half_up.format(-1.005), floor.format(-1.5), floor.format(1.5),
                          half_up.getRoundingMode()), ("1.01", "-1.01", "-2", "1", rounding.HALF_UP))
        symbols = text.DecimalFormatSymbols()
        symbols.setDecimalSeparator(",")
        symbols.setGroupingSeparator(" ")
        custom = text.DecimalFormat("#,##0.0", symbols)
        custom.setMaximumFractionDigits(3)
        custom.setMinimumIntegerDigits(6)
        self.assertEqual((custom.format(12345.6789), custom.toPattern()), ("012 345,679", "#,##0.0"))
        self.assertEqual((text.NumberFormat.getInstance().format(1234.5678), text.NumberFormat.getIntegerInstance().format(2.5),
                          text.NumberFormat.getPercentInstance().format(0.256)), ("1,234.568", "2", "26%"))
        for call in (lambda: text.DecimalFormat("0.0E0"), lambda: text.DecimalFormatSymbols(util.Locale.GERMANY),
                     text.NumberFormat.getCurrencyInstance):
            with self.assertRaises(bridge.UnsupportedAPI):
                call()
        with self.assertRaises(lang.IllegalArgumentException):
            text.DecimalFormat("0#")
        with self.assertRaises(lang.IllegalArgumentException):
            text.DecimalFormat("0").format("text")

    def test_parse(self):
        results = [text.DecimalFormat("#,##0.00").parse("1,234.50"), text.DecimalFormat("0%").parse("50%"),
                   text.DecimalFormat("0").parse("-12"), text.DecimalFormat("0.0").parse("3.0"),
                   text.DecimalFormat("0;(0)").parse("(7)"), text.DecimalFormat("0").parse("12abc")]
        self.assertEqual(results, [1234.5, 0.5, -12, 3, -7, 12])
        self.assertEqual([type(item) for item in results], [float, float, int, int, int, int])
        with self.assertRaises(text.ParseException) as caught:
            text.DecimalFormat("0").parse("abc")
        self.assertEqual(caught.exception.getMessage(), 'Unparseable number: "abc"')
        position = text.ParsePosition(2)
        self.assertEqual((text.DecimalFormat("0").parse("x=42;", position), position.getIndex()), (42, 4))
        self.assertEqual(text.Normalizer.normalize("\u00e9", text.Normalizer.Form.NFD), "e\u0301")
        self.assertTrue(text.Normalizer.isNormalized("e", text.Normalizer.Form.NFC))


class JavaTimeTests(unittest.TestCase):
    def setUp(self):
        self.instant = time.Instant.ofEpochMilli(MOMENT)
        self.zone = time.ZoneId.of("GMT+3")
        self.zoned = time.ZonedDateTime.ofInstant(self.instant, self.zone)

    def test_instant_and_duration(self):
        instant = self.instant
        self.assertEqual((str(instant), instant.getEpochSecond(), instant.getNano(), instant.toEpochMilli(), str(time.Instant.EPOCH),
                          str(time.Instant.ofEpochSecond(1, 500)), time.Instant.parse("2023-11-14T22:13:20.123Z"),
                          instant.plusSeconds(60).isAfter(instant), instant.minusMillis(123).getNano(), instant.to_bridge()),
                         ("2023-11-14T22:13:20.123Z", 1700000000, 123_000_000, MOMENT, "1970-01-01T00:00:00Z",
                          "1970-01-01T00:00:01.000000500Z", instant, True, 0, MOMENT))
        self.assertGreater(time.Instant.now().toEpochMilli(), 1_600_000_000_000)
        with self.assertRaises(time.DateTimeParseException):
            time.Instant.parse("yesterday")
        duration = time.Duration
        self.assertEqual([str(item) for item in (duration.ofSeconds(3661), duration.ofMillis(1500), duration.ofSeconds(-90),
                                                 duration.ZERO, duration.ofDays(1))],
                         ["PT1H1M1S", "PT1.5S", "PT-1M-30S", "PT0S", "PT24H"])
        self.assertEqual((duration.between(instant, instant.plusSeconds(90)).toMinutes(), duration.ofHours(25).toDays(),
                          duration.ofSeconds(5).plusMillis(250).toMillis(), duration.ofMinutes(1) == duration.ofSeconds(60),
                          duration.ofSeconds(-1).isNegative(), duration.ofSeconds(7).dividedBy(2).toMillis()),
                         (1, 1, 5250, True, True, 3500))

    def test_zones_and_zoned_date_time(self):
        zoned = self.zoned
        self.assertEqual((str(zoned), zoned.getHour(), zoned.getDayOfMonth(), zoned.getDayOfWeek(), zoned.getMonth(), str(zoned.getOffset()),
                          zoned.getZone().getId(), zoned.toInstant(), str(zoned.toLocalDate()), str(zoned.toLocalTime()),
                          str(zoned.withZoneSameInstant(time.ZoneOffset.UTC)), zoned.plusDays(1).getDayOfMonth(),
                          zoned.plusHours(23).getDayOfMonth(), zoned.toEpochSecond(), zoned.getNano()),
                         ("2023-11-15T01:13:20.123+03:00[GMT+03:00]", 1, 15, time.DayOfWeek.WEDNESDAY, time.Month.NOVEMBER, "+03:00",
                          "GMT+03:00", self.instant, "2023-11-15", "01:13:20.123", "2023-11-14T22:13:20.123Z", 16, 16, 1700000000,
                          123_000_000))
        self.assertEqual((time.ZoneId.of("Z"), time.ZoneId.of("+05:30").getId(), time.ZoneId.of("UTC").getId(), str(time.ZoneOffset.ofHours(-8)),
                          time.ZoneOffset.ofHoursMinutes(5, 30).getTotalSeconds(), time.ZoneId.systemDefault() == time.ZoneId.systemDefault()),
                         (time.ZoneOffset.UTC, "+05:30", "UTC", "-08:00", 19800, True))
        import zoneinfo
        with self.assertRaises(time.ZoneRulesException if zoneinfo.available_timezones() else bridge.UnsupportedAPI):
            time.ZoneId.of("Synthetic/Nowhere")
        with self.assertRaises(time.DateTimeException):
            time.ZoneOffset.ofHours(19)
        self.assertEqual(time.ZonedDateTime.parse("2023-11-15T01:13:20.123+03:00").toInstant(), self.instant)

    def test_local_types(self):
        date = time.LocalDate.of(2024, 1, 31)
        self.assertEqual([str(item) for item in (date, date.plusMonths(1), date.plusDays(1), date.minusYears(4), date.withDayOfMonth(1),
                                                 time.LocalDate.ofEpochDay(0), date.atStartOfDay(), date.atTime(10, 30))],
                         ["2024-01-31", "2024-02-29", "2024-02-01", "2020-01-31", "2024-01-01", "1970-01-01", "2024-01-31T00:00",
                          "2024-01-31T10:30"])
        self.assertEqual((date.getDayOfWeek(), date.isLeapYear(), date.lengthOfMonth(), date.toEpochDay(), date.isBefore(date.plusDays(1)),
                          date == time.LocalDate.of(2024, time.Month.JANUARY, 31), hasattr(date, "getHour"), hasattr(date, "getYear")),
                         (time.DayOfWeek.WEDNESDAY, True, 31, 19753, True, True, False, True))
        moment = time.LocalDateTime.of(2024, 3, 10, 1, 30)
        self.assertEqual([str(item) for item in (moment, moment.plusSeconds(5), moment.plusNanos(1), moment.toLocalTime(),
                                                 time.LocalTime.of(23, 30).plusHours(2), time.LocalTime.NOON,
                                                 moment.atZone(time.ZoneOffset.UTC))],
                         ["2024-03-10T01:30", "2024-03-10T01:30:05", "2024-03-10T01:30:00.000000001", "01:30", "01:30", "12:00",
                          "2024-03-10T01:30Z"])
        self.assertEqual((moment.toEpochSecond(time.ZoneOffset.UTC), time.LocalTime.of(1, 2, 3).toSecondOfDay(), hasattr(time.LocalTime.NOON, "getYear")),
                         (1710034200, 3723, False))
        for call in (lambda: time.LocalDate.of(2023, 2, 29), lambda: time.LocalTime.of(24, 0), lambda: date.withDayOfMonth(32),
                     lambda: time.LocalDateTime.of(2024, 13, 1, 0, 0)):
            with self.assertRaises(time.DateTimeException):
                call()
        unit = time.ChronoUnit
        self.assertEqual((unit.DAYS.between(date, time.LocalDate.of(2024, 3, 1)), unit.MONTHS.between(date, time.LocalDate.of(2024, 3, 30)),
                          unit.YEARS.between(time.LocalDate.of(2000, 2, 29), date), unit.HOURS.between(moment, moment.plusDays(1)),
                          unit.SECONDS.between(self.instant, self.instant.plusMillis(2500)), unit.WEEKS.between(date, date.minusDays(15)),
                          str(unit.HALF_DAYS), str(unit.MINUTES.getDuration()), len(unit.values())),
                         (30, 1, 23, 24, 2, -2, "HalfDays", "PT1M", 16))
        with self.assertRaises(time.UnsupportedTemporalTypeException):
            unit.HOURS.between(date, date)

    def test_formatter(self):
        formatter, zoned = time.DateTimeFormatter, self.zoned
        cases = {
            "yyyy-MM-dd HH:mm:ss": "2023-11-15 01:13:20", "dd MMM uuuu, hh:mm a": "15 Nov 2023, 01:13 AM",
            "EEEE, MMMM d": "Wednesday, November 15", "HH:mm:ss.SSS xxx VV": "01:13:20.123 +03:00 GMT+03:00",
            "yy/M/d Z O": "23/11/15 +0300 GMT+3", "'Q'Q QQQ": "Q4 Q4", "ss.SSSSSS n": "20.123000 123000000", "[HH][:mm]": "01:13",
        }
        for pattern, expected in cases.items():
            with self.subTest(pattern):
                self.assertEqual(zoned.format(formatter.ofPattern(pattern)), expected)
        self.assertEqual((formatter.ISO_LOCAL_DATE.format(zoned), formatter.ISO_LOCAL_DATE_TIME.format(zoned),
                          formatter.ISO_OFFSET_DATE_TIME.format(zoned), formatter.ISO_INSTANT.format(self.instant),
                          formatter.ISO_LOCAL_TIME.format(time.LocalTime.of(1, 2, 3, 500_000_000)),
                          formatter.ofPattern("yyyy HH").withZone(time.ZoneOffset.UTC).format(self.instant)),
                         ("2023-11-15", "2023-11-15T01:13:20.123", "2023-11-15T01:13:20.123+03:00", "2023-11-14T22:13:20.123Z",
                          "01:02:03.5", "2023 22"))
        for call in (lambda: formatter.ofPattern("yyyy").format(self.instant), lambda: formatter.ofPattern("HH").format(time.LocalDate.of(2024, 1, 1)),
                     lambda: formatter.ofPattern("xxx").format(time.LocalDateTime.of(2024, 1, 1, 0, 0)),
                     lambda: formatter.ISO_OFFSET_DATE_TIME.format(time.LocalDateTime.of(2024, 1, 1, 0, 0))):
            with self.assertRaises(time.UnsupportedTemporalTypeException):
                call()
        with self.assertRaises(lang.IllegalArgumentException):
            formatter.ofPattern("yyyy f")
        with self.assertRaises(bridge.UnsupportedAPI):
            formatter.ofPattern("MMMM", util.Locale("de"))
        self.assertEqual([str(item) for item in (
            time.LocalDate.parse("2024-02-29"), time.LocalDate.parse("05/03/24", formatter.ofPattern("dd/MM/yy")),
            time.LocalDate.parse("30/02/2023", formatter.ofPattern("dd/MM/yyyy")), time.LocalDateTime.parse("2024-03-10T01:30:15.250"),
            time.LocalDateTime.parse("10.03.2024 14:05", formatter.ofPattern("dd.MM.yyyy HH:mm")), time.LocalTime.parse("10:15:30"),
            formatter.ofPattern("yyyy-MM-dd HH:mm XXX").parse("2024-01-02 03:04 +02:00"))],
            ["2024-02-29", "2024-03-05", "2023-02-28", "2024-03-10T01:30:15.250", "2024-03-10T14:05", "10:15:30", "2024-01-02T03:04+02:00"])
        for value, pattern in (("2024-02-30", None), ("x", None), ("31/13/2024", "dd/MM/yyyy"), ("2024-01-01T00:00", None)):
            with self.subTest(value), self.assertRaises(time.DateTimeParseException):
                time.LocalDate.parse(value, formatter.ofPattern(pattern)) if pattern else time.LocalDate.parse(value)
        self.assertEqual((str(util.Date(MOMENT).toInstant()), getattr(util.Date, "from")(self.instant).getTime(),
                          util.TimeZone.getTimeZone("GMT+3").toZoneId().getId()), ("2023-11-14T22:13:20.123Z", MOMENT, "GMT+03:00"))


class NetTests(unittest.TestCase):
    def test_url(self):
        url = net.URL("https://user@Example.com:8443/a/b.txt?x=1&y=2#frag")
        self.assertEqual((url.getProtocol(), url.getHost(), url.getPort(), url.getDefaultPort(), url.getPath(), url.getQuery(), url.getRef(),
                          url.getFile(), url.getAuthority(), url.getUserInfo(), str(url), url.toURI().getHost(), url.to_bridge()),
                         ("https", "Example.com", 8443, 443, "/a/b.txt", "x=1&y=2", "frag", "/a/b.txt?x=1&y=2", "user@Example.com:8443", "user",
                          "https://user@Example.com:8443/a/b.txt?x=1&y=2#frag", "Example.com", "https://user@Example.com:8443/a/b.txt?x=1&y=2#frag"))
        self.assertEqual(url, net.URL("https://user@example.com:8443/a/b.txt?x=1&y=2#frag"))
        self.assertEqual((net.URL("http://[::1]:80/x").getHost(), net.URL("http://a.com").getPort(), net.URL("http://a.com").getPath(),
                          net.URL("http://a.com:80/") == net.URL("http://a.com/"), str(net.URL(net.URL("https://a.com/dir/page.html"), "other.html")),
                          str(net.URL(net.URL("https://a.com/dir/page.html"), "/root?q")), str(net.URL("https", "a.com", 444, "/f")),
                          str(net.URL("https", "a.com", "/f")), net.URL("file:/tmp/x").getPath()),
                         ("[::1]", -1, "", True, "https://a.com/dir/other.html", "https://a.com/root?q", "https://a.com:444/f", "https://a.com/f",
                          "/tmp/x"))
        for value, message in (("nope", "no protocol: nope"), ("foo://x", "unknown protocol: foo"), (None, "null")):
            with self.subTest(value):
                with self.assertRaises(net.MalformedURLException) as caught:
                    net.URL(value)
                self.assertEqual(caught.exception.getMessage(), message)
                self.assertIsInstance(caught.exception, io.IOException)
        with self.assertRaises(bridge.UnsupportedAPI):
            url.openConnection()
        with self.assertRaises(bridge.UnsupportedAPI):
            net.URL("file:/tmp/x").openStream()

    def test_uri(self):
        uri = net.URI("http://a.com:81/p%20q/r?x=%41#f")
        self.assertEqual((uri.getScheme(), uri.getHost(), uri.getPort(), uri.getPath(), uri.getRawPath(), uri.getQuery(), uri.getRawQuery(),
                          uri.getFragment(), uri.isAbsolute(), uri.isOpaque(), uri.getAuthority(), uri.toURL().getHost(), str(uri)),
                         ("http", "a.com", 81, "/p q/r", "/p%20q/r", "x=A", "x=%41", "f", True, False, "a.com:81", "a.com",
                          "http://a.com:81/p%20q/r?x=%41#f"))
        self.assertEqual((net.URI("mailto:a@b.c").isOpaque(), net.URI("mailto:a@b.c").getSchemeSpecificPart(), net.URI("mailto:a@b.c").getPath(),
                          str(net.URI("/a/./b/../c").normalize()), str(net.URI("http://h/a/b").resolve("../c?z")), str(net.URI("http://h/a/b").resolve("c")),
                          str(net.URI("http://h/a/").relativize(net.URI("http://h/a/b/c"))), str(net.URI("file", None, "/tmp/a b", None)),
                          net.URI.create("x").getPath(), net.URI("x").isAbsolute(), net.URI("HTTP://H/p") == net.URI("http://h/p"),
                          str(net.URI("https", "u", "h", 8, "/p q", "k=v w", "f"))),
                         (True, "a@b.c", None, "/a/c", "http://h/c?z", "http://h/a/c", "b/c", "file:/tmp/a%20b", "x", False, True,
                          "https://u@h:8/p%20q?k=v%20w#f"))
        with self.assertRaises(net.URISyntaxException) as caught:
            net.URI("a b")
        self.assertEqual((caught.exception.getMessage(), caught.exception.getIndex(), caught.exception.getReason(), caught.exception.getInput()),
                         ("Illegal character at index 1: a b", 1, "Illegal character", "a b"))
        with self.assertRaises(lang.IllegalArgumentException) as caught:
            net.URI.create("a b")
        self.assertIsInstance(caught.exception.getCause(), net.URISyntaxException)
        with self.assertRaises(lang.IllegalArgumentException):
            net.URI("relative").toURL()

    def test_form_encoding(self):
        self.assertEqual((net.URLEncoder.encode("a b&c=d/\u00e9~*-_.", "UTF-8"), net.URLEncoder.encode("\u00e9", "ISO-8859-1"),
                          net.URLEncoder.encode("x y"), net.URLDecoder.decode("a+b%26c%3Dd%2F%C3%A9", "UTF-8"), net.URLDecoder.decode("%E9", "ISO-8859-1"),
                          net.URLDecoder.decode("plain")), ("a+b%26c%3Dd%2F%C3%A9%7E*-_.", "%E9", "x+y", "a b&c=d/\u00e9", "\u00e9", "plain"))
        for broken in ("%", "%zz", "%+1", "abc%4"):
            with self.subTest(broken), self.assertRaises(lang.IllegalArgumentException):
                net.URLDecoder.decode(broken, "UTF-8")
        with self.assertRaises(io.UnsupportedEncodingException):
            net.URLEncoder.encode("x", "no-such-charset")


class JsonTests(unittest.TestCase):
    def test_parse_and_typed_access(self):
        value = json.JSONObject('{"a": 1, "b": "x/y", "c": [1, 2.5, null, true], "d": {"e": 1.0}, "n": null, "big": 12345678901}')
        self.assertEqual(str(value), '{"a":1,"b":"x\\/y","c":[1,2.5,null,true],"d":{"e":1},"n":null,"big":12345678901}')
        self.assertEqual((value.getInt("a"), value.getString("a"), value.getDouble("a"), value.getJSONArray("c").length(),
                          value.getJSONObject("d").getDouble("e"), value.getLong("big"), value.getInt("big"), value.isNull("n"), value.isNull("zz"),
                          value.has("n"), value.has("zz"), value.optString("n"), value.optString("zz"), value.optString("zz", "d"),
                          value.optInt("b", 7), value.optInt("zz"), value.optBoolean("zz"), value.opt("zz"), value.optJSONObject("a"),
                          value.length(), len(value), list(value.keys()), str(value.names()), "a" in value, value["a"], list(value)[:2]),
                         (1, "1", 1.0, 4, 1.0, 12345678901, -539222987, True, True, True, False, "null", "", "d", 7, 0, False, None, None,
                          6, 6, ["a", "b", "c", "d", "n", "big"], '["a","b","c","d","n","big"]', True, 1, ["a", "b"]))
        self.assertTrue(math.isnan(value.optDouble("zz")))
        self.assertEqual(value.to_bridge(), {"a": 1, "b": "x/y", "c": [1, 2.5, None, True], "d": {"e": 1.0}, "n": None, "big": 12345678901})
        self.assertEqual((json.JSONObject('{"t":"TRUE","n":"12.9"}').getBoolean("t"), json.JSONObject('{"t":"TRUE","n":"12.9"}').getInt("n"),
                          json.JSONObject('{"t":"TRUE","n":"12.9"}').getDouble("n")), (True, 12, 12.9))

    def test_errors_use_android_messages(self):
        value = json.JSONObject('{"a": 1, "b": "x"}')
        cases = [(lambda: value.getInt("b"), "Value x at b of type java.lang.String cannot be converted to int"),
                 (lambda: value.get("zz"), "No value for zz"),
                 (lambda: value.getJSONObject("a"), "Value 1 at a of type java.lang.Integer cannot be converted to JSONObject"),
                 (lambda: json.JSONObject("[1]"), "Value [1] of type org.json.JSONArray cannot be converted to JSONObject"),
                 (lambda: json.JSONObject("{"), "End of input at character 1 of {"),
                 (lambda: json.JSONObject('{"a" 1}'), "Expected ':' after a at character 6 of {\"a\" 1}"),
                 (lambda: value.put("x", math.nan), "Forbidden numeric value: NaN"),
                 (lambda: json.JSONArray("[1"), "Unterminated array at character 2 of [1"),
                 (lambda: json.JSONArray([1]).get(5), "Index 5 out of range [0..1)"),
                 (lambda: json.JSONArray().put(1, 5).get(0), "Value at 0 is null."),
                 (lambda: value.put(None, 1), "Names must be non-null")]
        for call, message in cases:
            with self.subTest(message):
                with self.assertRaises(json.JSONException) as caught:
                    call()
                self.assertEqual(caught.exception.getMessage(), message)
        self.assertIs(json.JSONArray("[null]").get(0), json.JSONObject.NULL)
        self.assertIsInstance(json.JSONException("x"), lang.Exception_)

    def test_building_and_lenient_parsing(self):
        value = json.JSONObject()
        self.assertIs(value.put("s", 'q"\n').put("f", 1.5).put("i", 3).put("t", True).put("l", [1, {"k": None}]).put("gone", None)
                      .putOpt("z", None).accumulate("acc", 1).accumulate("acc", 2), value)
        self.assertEqual(str(value), '{"s":"q\\"\\n","f":1.5,"i":3,"t":true,"l":[1,{"k":null}],"acc":[1,2]}')
        self.assertEqual((value.remove("f"), value.has("f"), value.put("i", None).has("i"), value.getJSONArray("l").getJSONObject(1).isNull("k")),
                         (1.5, False, False, True))
        boxed = json.JSONObject().put("b", lang.Boolean.TRUE).put("n", lang.Integer(7)).put("s", lang.String("x")).put("d", lang.Double(1.5))
        self.assertEqual((str(boxed), boxed.getBoolean("b"), boxed.to_bridge()), ('{"b":true,"n":7,"s":"x","d":1.5}', True, {"b": True, "n": 7, "s": "x", "d": 1.5}))
        self.assertEqual(json.JSONObject('{"a":[1,{"b":[]}],"c":{}}').toString(2),
                         '{\n  "a": [\n    1,\n    {\n      "b": []\n    }\n  ],\n  "c": {}\n}')
        array = json.JSONArray()
        array.put(1).put("two").put(5, True)
        self.assertEqual((str(array), array.length(), array.isNull(3), array.optInt(0), array.getBoolean(5), array.join("|"), array.opt(99),
                          array.remove(0), len(array), json.JSONArray([1, 2]) == json.JSONArray("[1,2]"), json.JSONArray((1, [2])).to_bridge()),
                         ('[1,"two",null,null,null,true]', 6, True, 1, True, '1|"two"|null|null|null|true', None, 1, 5, True, [1, [2]]))
        lenient = json.JSONObject("{a:b, 'c'=>0x10; d:010 /* comment */, e:TRUE, // line\n f:1e3, g: -5, h: 1.50}")
        self.assertEqual(str(lenient), '{"a":"b","c":16,"d":8,"e":true,"f":1000,"g":-5,"h":1.5}')
        self.assertEqual((str(json.JSONObject({"m": {"x": [1, 2]}, "n": None})), json.JSONObject.quote("a/b"), json.JSONObject.quote(None),
                          json.JSONObject.numberToString(1.0), json.JSONObject.numberToString(1.5e20), json.JSONObject.NULL.equals(None),
                          str(json.JSONObject.NULL), str(json.JSONObject(lenient, ["a", "zz"])), str(json.JSONArray("[1,,2,]")),
                          str(json.JSONObject("\ufeff{}")), json.JSONObject.wrap(object())),
                         ('{"m":{"x":[1,2]},"n":null}', '"a\\/b"', '""', "1", "1.5E20", True, "null", '{"a":"b"}', "[1,null,2,null]", "{}", None))
        tokener = json.JSONTokener(' {"a":1} tail')
        self.assertEqual((str(tokener.nextValue()), tokener.more(), tokener.nextClean(), tokener.next(3)), ('{"a":1}', True, "t", "ail"))


if __name__ == "__main__":
    unittest.main()
