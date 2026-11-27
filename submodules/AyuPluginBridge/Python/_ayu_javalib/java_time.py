"""``java.time`` value classes implemented in Python on ``datetime``.

Years are limited to 1..9999 (Python's ``datetime`` range). Text fields exist for
English only, as in ``java_text``; ``DateTimeFormatter`` parsing covers the numeric and
English-name pattern letters. ``Period``, ``Clock``, ``OffsetDateTime`` and the chrono
calendars are not provided.
"""
from __future__ import annotations

import calendar as _calendar
import datetime as _datetime
import re

from . import java_lang as _l
from . import java_text as _t
from . import java_util as _u
from .java_lang import Comparable, Enum, IllegalArgumentException, NullPointerException, Object

DateTimeException = _l._throwable("DateTimeException", _l.RuntimeException)
DateTimeParseException = _l._throwable("DateTimeParseException", DateTimeException)
ZoneRulesException = _l._throwable("ZoneRulesException", DateTimeException)
UnsupportedTemporalTypeException = _l._throwable("UnsupportedTemporalTypeException", DateTimeException)

_NANOS = 1_000_000_000
_UTC = _datetime.timezone.utc
_EPOCH = _datetime.datetime(1970, 1, 1)


def _fraction(nano):
    if not nano:
        return ""
    text = "%09d" % nano
    return "." + (text[:3] if text[3:] == "000000" else text[:6] if text[6:] == "000" else text)


class DayOfWeek(Enum):
    def getValue(self):
        return self._ordinal + 1

    @classmethod
    def of(cls, value):
        if not 1 <= value <= 7:
            raise DateTimeException(f"Invalid value for DayOfWeek: {value}")
        return cls._constants[value - 1]

    def plus(self, days):
        return self._constants[(self._ordinal + days) % 7]

    def minus(self, days):
        return self.plus(-days)


class Month(Enum):
    def getValue(self):
        return self._ordinal + 1

    @classmethod
    def of(cls, value):
        if not 1 <= value <= 12:
            raise DateTimeException(f"Invalid value for MonthOfYear: {value}")
        return cls._constants[value - 1]

    def plus(self, months):
        return self._constants[(self._ordinal + months) % 12]

    def minus(self, months):
        return self.plus(-months)

    def length(self, leap):
        return (31, 29 if leap else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)[self._ordinal]


_l.enum_constants(DayOfWeek, *(name.upper() for name in _t.DAYS))
_l.enum_constants(Month, *(name.upper() for name in _t.MONTHS))


class Duration(Comparable):
    def __init__(self, *args):
        raise _l.unsupported("Use Duration.ofSeconds and the other factories")

    @staticmethod
    def _of(nanos):
        duration = object.__new__(Duration)
        duration._nanos = nanos
        if not _l.LONG_MIN <= nanos // _NANOS <= _l.LONG_MAX:
            raise _l.ArithmeticException("long overflow")
        return duration

    @staticmethod
    def ofNanos(value):
        return Duration._of(value)

    @staticmethod
    def ofMillis(value):
        return Duration._of(value * 1_000_000)

    @staticmethod
    def ofSeconds(value, adjustment=0):
        return Duration._of(value * _NANOS + adjustment)

    @staticmethod
    def ofMinutes(value):
        return Duration._of(value * 60 * _NANOS)

    @staticmethod
    def ofHours(value):
        return Duration._of(value * 3600 * _NANOS)

    @staticmethod
    def ofDays(value):
        return Duration._of(value * 86400 * _NANOS)

    @staticmethod
    def between(start, end):
        return Duration._of(_instant_nanos(end) - _instant_nanos(start))

    def getSeconds(self):
        return self._nanos // _NANOS

    def getNano(self):
        return self._nanos % _NANOS

    def toNanos(self):
        return _exact_long(self._nanos)

    def toMillis(self):
        return _exact_long(self._nanos // 1_000_000)

    def toSeconds(self):
        return self._nanos // _NANOS

    def toMinutes(self):
        return self._nanos // _NANOS // 60

    def toHours(self):
        return self._nanos // _NANOS // 3600

    def toDays(self):
        return self._nanos // _NANOS // 86400

    def isZero(self):
        return self._nanos == 0

    def isNegative(self):
        return self._nanos < 0

    def negated(self):
        return Duration._of(-self._nanos)

    def abs(self):
        return Duration._of(abs(self._nanos))

    def plus(self, other):
        return Duration._of(self._nanos + other._nanos)

    def minus(self, other):
        return Duration._of(self._nanos - other._nanos)

    def multipliedBy(self, factor):
        return Duration._of(self._nanos * factor)

    def dividedBy(self, divisor):
        if divisor == 0:
            raise _l.ArithmeticException("Cannot divide by zero")
        quotient = abs(self._nanos) // abs(divisor)
        return Duration._of(quotient if (self._nanos < 0) == (divisor < 0) else -quotient)

    def compareTo(self, other):
        return (self._nanos > other._nanos) - (self._nanos < other._nanos)

    def __eq__(self, other):
        return isinstance(other, Duration) and self._nanos == other._nanos

    def __lt__(self, other):
        return self._nanos < other._nanos

    def __hash__(self):
        return hash(self._nanos)

    def toString(self):
        if self._nanos == 0:
            return "PT0S"
        total = abs(self._nanos)
        seconds, nano = divmod(total, _NANOS)
        hours, minutes, seconds = seconds // 3600, seconds % 3600 // 60, seconds % 60
        sign = "-" if self._nanos < 0 else ""
        text = "PT" + (f"{sign}{hours}H" if hours else "") + (f"{sign}{minutes}M" if minutes else "")
        if seconds or nano:
            text += f"{sign}{seconds}" + (("." + ("%09d" % nano).rstrip("0")) if nano else "") + "S"
        return text


for _unit, _factor in (("Nanos", 1), ("Millis", 1_000_000), ("Seconds", _NANOS), ("Minutes", 60 * _NANOS),
                       ("Hours", 3600 * _NANOS), ("Days", 86400 * _NANOS)):
    setattr(Duration, "plus" + _unit, lambda self, value, _factor=_factor: Duration._of(self._nanos + value * _factor))
    setattr(Duration, "minus" + _unit, lambda self, value, _factor=_factor: Duration._of(self._nanos - value * _factor))
Duration.ZERO = Duration._of(0)


def _exact_long(value):
    if not _l.LONG_MIN <= value <= _l.LONG_MAX:
        raise _l.ArithmeticException("long overflow")
    return value


def _instant_nanos(value):
    """Nanoseconds on a common time line for two temporals of the same kind."""
    if isinstance(value, Instant):
        return value._seconds * _NANOS + value._nano
    if isinstance(value, ZonedDateTime):
        return _instant_nanos(value.toInstant())
    if isinstance(value, LocalDateTime):
        return (value._moment - _EPOCH) // _datetime.timedelta(seconds=1) * _NANOS + value._nano
    if isinstance(value, LocalTime):
        return value.toNanoOfDay()
    raise UnsupportedTemporalTypeException("Unsupported unit: Seconds")


class ZoneId(Object):
    def __init__(self, *args):
        raise _l.unsupported("Use ZoneId.of or ZoneId.systemDefault")

    @staticmethod
    def _wrap(zone, identifier=None):
        result = object.__new__(ZoneId)
        result._zone, result._id = zone, identifier or zone.getID()
        return result

    @staticmethod
    def of(identifier):
        if identifier is None:
            raise NullPointerException("zoneId")
        if identifier == "Z":
            return ZoneOffset.UTC
        if identifier[:1] in "+-":
            return ZoneOffset.of(identifier)
        zone = _u.TimeZone.getTimeZone(identifier)
        if zone.getID() == "GMT" and identifier not in ("GMT", "UTC", "UT", "Etc/GMT", "Etc/UTC") and \
                not re.fullmatch(r"(GMT|UTC|UT)[+-].*", identifier):
            raise ZoneRulesException("Unknown time-zone ID: " + identifier)
        return ZoneId._wrap(zone, identifier if zone.getID() in ("GMT", "UTC") else zone.getID())

    @staticmethod
    def systemDefault():
        zone = _u.TimeZone.getDefault()
        return ZoneId._wrap(zone, zone.getID())

    @staticmethod
    def getAvailableZoneIds():
        return _u.HashSet(_u.TimeZone.getAvailableIDs())

    def getId(self):
        return self._id

    def normalized(self):
        return self

    def toString(self):
        return self._id

    def __repr__(self):
        return self._id

    def __eq__(self, other):
        return isinstance(other, ZoneId) and self._id == other._id

    def __hash__(self):
        return hash(self._id)

    def to_bridge(self):
        return self._id


class ZoneOffset(ZoneId, Comparable):
    @staticmethod
    def ofTotalSeconds(seconds):
        if not -64800 <= seconds <= 64800:
            raise DateTimeException("Zone offset not in valid range: -18:00 to +18:00")
        result = object.__new__(ZoneOffset)
        result._seconds = seconds
        hours, rest = divmod(abs(seconds), 3600)
        result._id = "Z" if seconds == 0 else "%s%02d:%02d" % ("-" if seconds < 0 else "+", hours, rest // 60) + \
            (":%02d" % (rest % 60) if rest % 60 else "")
        result._zone = _u.TimeZone._make("GMT" + ("" if seconds == 0 else result._id),
                                         _datetime.timezone(_datetime.timedelta(seconds=seconds)))
        return result

    @staticmethod
    def ofHours(hours):
        return ZoneOffset.ofTotalSeconds(hours * 3600)

    @staticmethod
    def ofHoursMinutes(hours, minutes):
        if hours > 0 > minutes or hours < 0 < minutes:
            raise DateTimeException("Zone offset minutes and seconds must have the same sign as the hours")
        return ZoneOffset.ofTotalSeconds(hours * 3600 + minutes * 60)

    @staticmethod
    def of(identifier):
        if identifier == "Z":
            return ZoneOffset.UTC
        match = re.fullmatch(r"([+-])(\d{1,2})(?::?(\d{2}))?(?::?(\d{2}))?", identifier or "")
        if match is None:
            raise DateTimeException("Invalid ID for ZoneOffset, invalid format: " + _l.jstr(identifier))
        seconds = int(match.group(2)) * 3600 + int(match.group(3) or 0) * 60 + int(match.group(4) or 0)
        return ZoneOffset.ofTotalSeconds(-seconds if match.group(1) == "-" else seconds)

    def getTotalSeconds(self):
        return self._seconds

    def compareTo(self, other):
        return other._seconds - self._seconds


ZoneOffset.UTC = ZoneOffset.ofTotalSeconds(0)
ZoneOffset.MIN, ZoneOffset.MAX = ZoneOffset.ofTotalSeconds(-64800), ZoneOffset.ofTotalSeconds(64800)


def _zone(value):
    if value is None:
        raise NullPointerException("zone")
    if isinstance(value, _u.TimeZone):
        return ZoneId._wrap(value, value.getID())
    if not isinstance(value, ZoneId):
        raise TypeError("Expected a ZoneId")
    return value


class Instant(Comparable):
    def __init__(self, *args):
        raise _l.unsupported("Use Instant.now, Instant.ofEpochSecond or Instant.ofEpochMilli")

    @staticmethod
    def _of(seconds, nano=0):
        seconds, nano = seconds + nano // _NANOS, nano % _NANOS
        if not -31557014167219200 <= seconds <= 31556889864403199:
            raise DateTimeException("Instant exceeds minimum or maximum instant")
        instant = object.__new__(Instant)
        instant._seconds, instant._nano = seconds, nano
        return instant

    @staticmethod
    def now():
        import time
        return Instant._of(0, time.time_ns())

    @staticmethod
    def ofEpochSecond(seconds, adjustment=0):
        return Instant._of(seconds, adjustment)

    @staticmethod
    def ofEpochMilli(millis):
        return Instant._of(millis // 1000, millis % 1000 * 1_000_000)

    @staticmethod
    def parse(text):
        match = re.fullmatch(r"(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,9}))?)?Z", _l._text(text))
        try:
            if match is None:
                raise ValueError
            moment = _datetime.datetime(*(int(item or 0) for item in match.groups()[:6]))
        except ValueError:
            raise DateTimeParseException(f"Text '{text}' could not be parsed at index 0") from None
        return Instant._of((moment - _EPOCH) // _datetime.timedelta(seconds=1),
                           int((match.group(7) or "").ljust(9, "0")))

    def getEpochSecond(self):
        return self._seconds

    def getNano(self):
        return self._nano

    def toEpochMilli(self):
        return _exact_long(self._seconds * 1000 + self._nano // 1_000_000)

    def plus(self, duration):
        return Instant._of(self._seconds, self._nano + duration._nanos)

    def minus(self, duration):
        return Instant._of(self._seconds, self._nano - duration._nanos)

    def isBefore(self, other):
        return self._key() < other._key()

    def isAfter(self, other):
        return self._key() > other._key()

    def _key(self):
        return self._seconds, self._nano

    def compareTo(self, other):
        return (self._key() > other._key()) - (self._key() < other._key())

    def __eq__(self, other):
        return isinstance(other, Instant) and self._key() == other._key()

    def __lt__(self, other):
        return self._key() < other._key()

    def __hash__(self):
        return hash(self._key())

    def hashCode(self):
        return _l.i32((self._seconds ^ ((self._seconds & 0xFFFFFFFFFFFFFFFF) >> 32)) + 51 * self._nano)

    def atZone(self, zone):
        return ZonedDateTime.ofInstant(self, zone)

    def _utc(self):
        try:
            return _EPOCH + _datetime.timedelta(seconds=self._seconds)
        except OverflowError:
            raise DateTimeException("Instant is outside the supported year range 1..9999") from None

    def toString(self):
        moment = self._utc()
        return _date_text(moment) + "T%02d:%02d:%02d" % (moment.hour, moment.minute, moment.second) + \
            _fraction(self._nano) + "Z"

    def to_bridge(self):
        return self.toEpochMilli()


for _unit, _factor in (("Nanos", 1), ("Millis", 1_000_000), ("Seconds", _NANOS)):
    setattr(Instant, "plus" + _unit, lambda self, value, _factor=_factor:
            Instant._of(self._seconds, self._nano + value * _factor))
    setattr(Instant, "minus" + _unit, lambda self, value, _factor=_factor:
            Instant._of(self._seconds, self._nano - value * _factor))
Instant.EPOCH = Instant._of(0)


def _checked(function, *args):
    try:
        return function(*args)
    except (ValueError, OverflowError) as error:
        raise DateTimeException(str(error)) from None


def _shift_months(moment, months):
    total = moment.year * 12 + moment.month - 1 + months
    year, month = total // 12, total % 12 + 1
    if not 1 <= year <= 9999:
        raise DateTimeException(f"Invalid value for Year: {year}")
    return moment.replace(year=year, month=month, day=min(moment.day, _calendar.monthrange(year, month)[1]))


class _Temporal(Comparable):
    """Shared field access over ``self._moment`` (a ``datetime``) and ``self._nano``."""
    _nano = 0

    def getYear(self):
        return self._moment.year

    def getMonthValue(self):
        return self._moment.month

    def getMonth(self):
        return Month.of(self._moment.month)

    def getDayOfMonth(self):
        return self._moment.day

    def getDayOfYear(self):
        return self._moment.timetuple().tm_yday

    def getDayOfWeek(self):
        return DayOfWeek.of(self._moment.isoweekday())

    def getHour(self):
        return self._moment.hour

    def getMinute(self):
        return self._moment.minute

    def getSecond(self):
        return self._moment.second

    def getNano(self):
        return self._nano

    def format(self, formatter):
        return formatter.format(self)

    def isBefore(self, other):
        return self._key() < other._key()

    def isAfter(self, other):
        return self._key() > other._key()

    def isEqual(self, other):
        return self._key() == other._key()

    def compareTo(self, other):
        return (self._key() > other._key()) - (self._key() < other._key())

    def __eq__(self, other):
        return type(other) is type(self) and self._identity() == other._identity()

    def __lt__(self, other):
        return self._key() < other._key()

    def __hash__(self):
        return hash(self._identity())

    def _key(self):
        return self._moment.replace(tzinfo=None), self._nano

    def _identity(self):
        return self._key()

    def __repr__(self):
        return self.toString()

    def _with(self, moment, nano=None):
        copy = object.__new__(type(self))
        copy.__dict__.update(self.__dict__)
        copy._moment = moment
        if nano is not None:
            copy._nano = nano
        return copy

    def _shift(self, delta):
        return self._with(_checked(lambda: self._moment + delta))

    def plusYears(self, value):
        return self._with(_shift_months(self._moment, 12 * value))

    def plusMonths(self, value):
        return self._with(_shift_months(self._moment, value))

    def plusWeeks(self, value):
        return self._shift(_datetime.timedelta(weeks=value))

    def plusDays(self, value):
        return self._shift(_datetime.timedelta(days=value))

    def plusHours(self, value):
        return self._shift(_datetime.timedelta(hours=value))

    def plusMinutes(self, value):
        return self._shift(_datetime.timedelta(minutes=value))

    def plusSeconds(self, value):
        return self._shift(_datetime.timedelta(seconds=value))

    def plusNanos(self, value):
        total = self._nano + value
        return self._with(_checked(lambda: self._moment + _datetime.timedelta(seconds=total // _NANOS)), total % _NANOS)

    def plus(self, duration):
        return self.plusNanos(duration._nanos)

    def minus(self, duration):
        return self.plusNanos(-duration._nanos)

    def _replace(self, **fields):
        return self._with(_checked(lambda: self._moment.replace(**fields)))

    def withYear(self, value):
        return self._replace(year=value, day=min(self._moment.day, _calendar.monthrange(
            value if 1 <= value <= 9999 else 2000, self._moment.month)[1]))

    def withMonth(self, value):
        if not 1 <= value <= 12:
            raise DateTimeException(f"Invalid value for MonthOfYear: {value}")
        return self._replace(month=value, day=min(self._moment.day,
                                                  _calendar.monthrange(self._moment.year, value)[1]))

    def withDayOfMonth(self, value):
        return self._replace(day=value)

    def withHour(self, value):
        return self._replace(hour=value)

    def withMinute(self, value):
        return self._replace(minute=value)

    def withSecond(self, value):
        return self._replace(second=value)

    def withNano(self, value):
        if not 0 <= value < _NANOS:
            raise DateTimeException(f"Invalid value for NanoOfSecond: {value}")
        return self._with(self._moment, value)


for _unit in ("Years", "Months", "Weeks", "Days", "Hours", "Minutes", "Seconds", "Nanos"):
    setattr(_Temporal, "minus" + _unit,
            lambda self, value, _name="plus" + _unit: getattr(self, _name)(-value))


def _hide(cls, *names):
    for name in names:
        setattr(cls, name, _l.Hidden(name))


_DATE_FIELDS = ("getYear", "getMonthValue", "getMonth", "getDayOfMonth", "getDayOfYear", "getDayOfWeek", "plusYears",
                "plusMonths", "plusWeeks", "plusDays", "minusYears", "minusMonths", "minusWeeks", "minusDays",
                "withYear", "withMonth", "withDayOfMonth")
_TIME_FIELDS = ("getHour", "getMinute", "getSecond", "getNano", "plusHours", "plusMinutes", "plusSeconds", "plusNanos",
                "minusHours", "minusMinutes", "minusSeconds", "minusNanos", "withHour", "withMinute", "withSecond",
                "withNano", "plus", "minus")


def _time_text(moment, nano):
    return "%02d:%02d" % (moment.hour, moment.minute) + (
        ":%02d" % moment.second + _fraction(nano) if moment.second or nano else "")


def _date_text(moment):
    return "%04d-%02d-%02d" % (moment.year, moment.month, moment.day)


class LocalDate(_Temporal):
    def __init__(self, *args):
        raise _l.unsupported("Use LocalDate.of, LocalDate.now or LocalDate.parse")

    @staticmethod
    def _make(moment):
        date = object.__new__(LocalDate)
        date._moment = moment.replace(hour=0, minute=0, second=0, microsecond=0, tzinfo=None)
        return date

    @staticmethod
    def of(year, month, day):
        month = month.getValue() if isinstance(month, Month) else month
        try:
            return LocalDate._make(_datetime.datetime(year, month, day))
        except (ValueError, OverflowError):
            raise DateTimeException(f"Invalid date {year}-{month}-{day}") from None

    @staticmethod
    def now(zone=None):
        return ZonedDateTime.now(zone).toLocalDate()

    @staticmethod
    def ofEpochDay(day):
        return LocalDate._make(_checked(lambda: _EPOCH + _datetime.timedelta(days=day)))

    @staticmethod
    def ofInstant(instant, zone):
        return ZonedDateTime.ofInstant(instant, zone).toLocalDate()

    @staticmethod
    def parse(text, formatter=None):
        formatter = formatter or DateTimeFormatter.ISO_LOCAL_DATE
        moment, _nano, _zone_id = formatter._parse(text)
        return LocalDate._make(moment)

    def toEpochDay(self):
        return (self._moment - _EPOCH).days

    def lengthOfMonth(self):
        return _calendar.monthrange(self._moment.year, self._moment.month)[1]

    def lengthOfYear(self):
        return 366 if self.isLeapYear() else 365

    def isLeapYear(self):
        return _calendar.isleap(self._moment.year)

    def atStartOfDay(self, zone=None):
        start = LocalDateTime._make(self._moment, 0)
        return start if zone is None else start.atZone(zone)

    def atTime(self, hour, minute=0, second=0, nano=0):
        if isinstance(hour, LocalTime):
            return LocalDateTime._make(self._moment.replace(hour=hour._moment.hour, minute=hour._moment.minute,
                                                            second=hour._moment.second), hour._nano)
        return LocalDateTime.of(self._moment.year, self._moment.month, self._moment.day, hour, minute, second, nano)

    def toString(self):
        return _date_text(self._moment)


_hide(LocalDate, *_TIME_FIELDS)


class LocalTime(_Temporal):
    def __init__(self, *args):
        raise _l.unsupported("Use LocalTime.of, LocalTime.now or LocalTime.parse")

    @staticmethod
    def _make(moment, nano):
        time = object.__new__(LocalTime)
        time._moment = moment.replace(year=1970, month=1, day=1, microsecond=0, tzinfo=None)
        time._nano = nano
        return time

    @staticmethod
    def of(hour, minute, second=0, nano=0):
        if not 0 <= nano < _NANOS:
            raise DateTimeException(f"Invalid value for NanoOfSecond: {nano}")
        try:
            return LocalTime._make(_datetime.datetime(1970, 1, 1, hour, minute, second), nano)
        except ValueError:
            raise DateTimeException(f"Invalid time {hour}:{minute}:{second}") from None

    @staticmethod
    def now(zone=None):
        return ZonedDateTime.now(zone).toLocalTime()

    @staticmethod
    def ofSecondOfDay(seconds):
        if not 0 <= seconds < 86400:
            raise DateTimeException(f"Invalid value for SecondOfDay: {seconds}")
        return LocalTime._make(_EPOCH + _datetime.timedelta(seconds=seconds), 0)

    @staticmethod
    def parse(text, formatter=None):
        formatter = formatter or DateTimeFormatter.ISO_LOCAL_TIME
        moment, nano, _zone_id = formatter._parse(text)
        return LocalTime._make(moment, nano)

    def toSecondOfDay(self):
        return self._moment.hour * 3600 + self._moment.minute * 60 + self._moment.second

    def toNanoOfDay(self):
        return self.toSecondOfDay() * _NANOS + self._nano

    def _with(self, moment, nano=None):
        # Time arithmetic wraps around midnight.
        return LocalTime._make(moment, self._nano if nano is None else nano)

    def toString(self):
        return _time_text(self._moment, self._nano)


_hide(LocalTime, *_DATE_FIELDS)
LocalTime.MIDNIGHT, LocalTime.NOON = LocalTime.of(0, 0), LocalTime.of(12, 0)
LocalTime.MIN, LocalTime.MAX = LocalTime.of(0, 0), LocalTime.of(23, 59, 59, 999_999_999)


class LocalDateTime(_Temporal):
    def __init__(self, *args):
        raise _l.unsupported("Use LocalDateTime.of, LocalDateTime.now or LocalDateTime.parse")

    @staticmethod
    def _make(moment, nano):
        value = object.__new__(LocalDateTime)
        value._moment, value._nano = moment.replace(microsecond=0, tzinfo=None), nano
        return value

    @staticmethod
    def of(*args):
        if len(args) == 2 and isinstance(args[0], LocalDate):
            return args[0].atTime(args[1])
        if not 5 <= len(args) <= 7:
            raise TypeError("LocalDateTime.of takes (year, month, day, hour, minute[, second[, nano]])")
        year, month, day, hour, minute = args[:5]
        month = month.getValue() if isinstance(month, Month) else month
        second, nano = (list(args[5:]) + [0, 0])[:2]
        if not 0 <= nano < _NANOS:
            raise DateTimeException(f"Invalid value for NanoOfSecond: {nano}")
        try:
            return LocalDateTime._make(_datetime.datetime(year, month, day, hour, minute, second), nano)
        except (ValueError, OverflowError):
            raise DateTimeException(f"Invalid date-time {args}") from None

    @staticmethod
    def now(zone=None):
        return ZonedDateTime.now(zone).toLocalDateTime()

    @staticmethod
    def ofInstant(instant, zone):
        return ZonedDateTime.ofInstant(instant, zone).toLocalDateTime()

    @staticmethod
    def ofEpochSecond(seconds, nano, offset):
        return ZonedDateTime.ofInstant(Instant.ofEpochSecond(seconds, nano), offset).toLocalDateTime()

    @staticmethod
    def parse(text, formatter=None):
        formatter = formatter or DateTimeFormatter.ISO_LOCAL_DATE_TIME
        moment, nano, _zone_id = formatter._parse(text)
        return LocalDateTime._make(moment, nano)

    def toLocalDate(self):
        return LocalDate._make(self._moment)

    def toLocalTime(self):
        return LocalTime._make(self._moment, self._nano)

    def atZone(self, zone):
        return ZonedDateTime._local(self._moment, self._nano, _zone(zone))

    def toEpochSecond(self, offset):
        return (self._moment - _EPOCH) // _datetime.timedelta(seconds=1) - offset.getTotalSeconds()

    def toInstant(self, offset):
        return Instant._of(self.toEpochSecond(offset), self._nano)

    def toString(self):
        return _date_text(self._moment) + "T" + _time_text(self._moment, self._nano)


class ZonedDateTime(_Temporal):
    def __init__(self, *args):
        raise _l.unsupported("Use ZonedDateTime.now, ZonedDateTime.of or ZonedDateTime.ofInstant")

    @staticmethod
    def _make(moment, nano, zone):
        value = object.__new__(ZonedDateTime)
        value._moment, value._nano, value._zone_id = moment.replace(microsecond=0), nano, zone
        return value

    @staticmethod
    def _local(moment, nano, zone):
        aware = moment.replace(tzinfo=zone._zone._tz)
        # A local time inside a daylight-saving gap is moved to the instant it denotes.
        instant = _u.from_datetime(aware)
        return ZonedDateTime._make(_u.to_datetime(instant, zone._zone), nano, zone)

    @staticmethod
    def now(zone=None):
        return ZonedDateTime.ofInstant(Instant.now(), ZoneId.systemDefault() if zone is None else zone)

    @staticmethod
    def ofInstant(instant, zone):
        zone = _zone(zone)
        if instant is None:
            raise NullPointerException("instant")
        return ZonedDateTime._make(_u.to_datetime(instant._seconds * 1000, zone._zone), instant._nano, zone)

    @staticmethod
    def of(*args):
        if len(args) == 2:
            return args[0].atZone(args[1])
        if len(args) == 3:
            return args[0].atTime(args[1]).atZone(args[2])
        if len(args) != 8:
            raise TypeError("ZonedDateTime.of takes (year, month, day, hour, minute, second, nano, zone)")
        return LocalDateTime.of(*args[:7]).atZone(args[7])

    @staticmethod
    def parse(text, formatter=None):
        formatter = formatter or DateTimeFormatter.ISO_ZONED_DATE_TIME
        moment, nano, zone_id = formatter._parse(text)
        if moment.tzinfo is None:
            raise DateTimeParseException(f"Text '{text}' could not be parsed: no zone or offset")
        if zone_id is not None:
            return LocalDateTime._make(moment, nano).atZone(ZoneId.of(zone_id))
        offset = ZoneOffset.ofTotalSeconds(moment.utcoffset() // _datetime.timedelta(seconds=1))
        return ZonedDateTime._make(moment.replace(tzinfo=offset._zone._tz), nano, offset)

    def getZone(self):
        return self._zone_id

    def getOffset(self):
        return ZoneOffset.ofTotalSeconds(self._moment.utcoffset() // _datetime.timedelta(seconds=1))

    def toInstant(self):
        return Instant._of(self.toEpochSecond(), self._nano)

    def toEpochSecond(self):
        return _u.from_datetime(self._moment) // 1000

    def toLocalDateTime(self):
        return LocalDateTime._make(self._moment, self._nano)

    def toLocalDate(self):
        return LocalDate._make(self._moment)

    def toLocalTime(self):
        return LocalTime._make(self._moment, self._nano)

    def withZoneSameInstant(self, zone):
        return ZonedDateTime.ofInstant(self.toInstant(), zone)

    def withZoneSameLocal(self, zone):
        return ZonedDateTime._local(self._moment.replace(tzinfo=None), self._nano, _zone(zone))

    def _with(self, moment, nano=None):
        # Date fields move on the local time line; the zone then fixes the offset.
        return ZonedDateTime._local(moment.replace(tzinfo=None), self._nano if nano is None else nano, self._zone_id)

    def _instant_shift(self, nanos):
        return ZonedDateTime.ofInstant(Instant._of(self.toEpochSecond(), self._nano + nanos), self._zone_id)

    def plusHours(self, value):
        return self._instant_shift(value * 3600 * _NANOS)

    def plusMinutes(self, value):
        return self._instant_shift(value * 60 * _NANOS)

    def plusSeconds(self, value):
        return self._instant_shift(value * _NANOS)

    def plusNanos(self, value):
        return self._instant_shift(value)

    def _key(self):
        return self.toEpochSecond(), self._nano

    def _identity(self):
        return self._moment.replace(tzinfo=None), self._nano, self._zone_id.getId(), self._moment.utcoffset()

    def toString(self):
        offset = self.getOffset()
        return _date_text(self._moment) + "T" + _time_text(self._moment, self._nano) + offset.getId() + (
            "" if isinstance(self._zone_id, ZoneOffset) else "[" + self._zone_id.getId() + "]")


class ChronoUnit(Enum):
    def getDuration(self):
        return Duration._of(self._span)

    def isDateBased(self):
        return self._ordinal >= 7

    def isTimeBased(self):
        return self._ordinal < 7

    def between(self, start, end):
        if type(start) is not type(end):
            raise DateTimeException("Both temporals must be of the same type")
        if self._ordinal >= 14:
            raise UnsupportedTemporalTypeException("Unsupported unit: " + self.toString())
        if isinstance(start, ZonedDateTime) and self._ordinal >= 7:
            # Date units count on the local time line of the first value's zone.
            start, end = start.toLocalDateTime(), end.withZoneSameInstant(start.getZone()).toLocalDateTime()
        if self._ordinal in (9, 10, 11, 12, 13):
            if isinstance(start, (Instant, LocalTime)):
                raise UnsupportedTemporalTypeException("Unsupported unit: " + self.toString())
            first, second = start._moment.replace(tzinfo=None), end._moment.replace(tzinfo=None)
            months = (second.year - first.year) * 12 + second.month - first.month
            tail_first = (first.day, first.time(), getattr(start, "_nano", 0))
            tail_second = (second.day, second.time(), getattr(end, "_nano", 0))
            if months > 0 and tail_second < tail_first:
                months -= 1
            elif months < 0 and tail_second > tail_first:
                months += 1
            size = {9: 1, 10: 12, 11: 120, 12: 1200, 13: 12000}[self._ordinal]
            return abs(months) // size * (1 if months >= 0 else -1)
        if isinstance(start, LocalDate):
            if self._ordinal < 7:
                raise UnsupportedTemporalTypeException("Unsupported unit: " + self.toString())
            delta = (end.toEpochDay() - start.toEpochDay()) * 86400 * _NANOS
        else:
            delta = _instant_nanos(end) - _instant_nanos(start)
        return abs(delta) // self._span * (1 if delta >= 0 else -1)

    def toString(self):
        return self._text


_l.enum_constants(ChronoUnit, "NANOS", "MICROS", "MILLIS", "SECONDS", "MINUTES", "HOURS", "HALF_DAYS", "DAYS",
                  "WEEKS", "MONTHS", "YEARS", "DECADES", "CENTURIES", "MILLENNIA", "ERAS", "FOREVER")
for _constant, _span in zip(ChronoUnit._constants, (
        1, 1000, 1_000_000, _NANOS, 60 * _NANOS, 3600 * _NANOS, 43200 * _NANOS, 86400 * _NANOS, 604800 * _NANOS,
        31556952 * _NANOS // 12, 31556952 * _NANOS, 315569520 * _NANOS, 3155695200 * _NANOS, 31556952000 * _NANOS,
        31556952000000000 * _NANOS, _l.LONG_MAX * _NANOS + 999_999_999)):
    _constant._span = _span
    _constant._text = "".join(part.capitalize() for part in _constant.name().split("_"))


class DateTimeFormatter(Object):
    _LETTERS = "GuyDMLdQqYwWEFaHkKhmsSAnNVzOXxZ"

    def __init__(self, *args):
        raise _l.unsupported("Use DateTimeFormatter.ofPattern or an ISO constant")

    @staticmethod
    def _make(pattern, iso=None, locale=None, zone=None):
        formatter = object.__new__(DateTimeFormatter)
        formatter._pattern, formatter._iso, formatter._locale, formatter._zone = pattern, iso, locale, zone
        formatter._tokens = None if pattern is None else _t.tokenize(
            pattern, DateTimeFormatter._LETTERS, lambda char: f"Unknown pattern letter: {char}", skip="[]")
        formatter._symbols = _t.ENGLISH if formatter._tokens is None else _t.symbols_for(locale, formatter._tokens)
        return formatter

    @staticmethod
    def ofPattern(pattern, locale=None):
        if pattern is None:
            raise NullPointerException("pattern")
        return DateTimeFormatter._make(pattern, None, locale)

    def withZone(self, zone):
        return DateTimeFormatter._make(self._pattern, self._iso, self._locale, None if zone is None else _zone(zone))

    def withLocale(self, locale):
        return DateTimeFormatter._make(self._pattern, self._iso, locale, self._zone)

    def getZone(self):
        return self._zone

    def toString(self):
        return self._pattern if self._pattern is not None else "ISO"

    def format(self, temporal):
        if temporal is None:
            raise NullPointerException("temporal")
        if isinstance(temporal, Instant):
            if self._zone is None and self._iso != "instant":
                raise UnsupportedTemporalTypeException("Unsupported field: YearOfEra")
            if self._iso == "instant":
                return temporal.toString()
            temporal = temporal.atZone(self._zone)
        elif isinstance(temporal, ZonedDateTime) and self._zone is not None:
            temporal = temporal.withZoneSameInstant(self._zone)
        if not isinstance(temporal, _Temporal):
            raise TypeError("Expected a java.time temporal")
        moment, nano = temporal._moment, temporal._nano
        if self._iso is not None:
            date, time = _date_text(moment), "%02d:%02d:%02d" % (moment.hour, moment.minute, moment.second) + \
                _fraction(nano).rstrip("0")
            has_date, has_time = not isinstance(temporal, LocalTime), not isinstance(temporal, LocalDate)
            suffix = temporal.getOffset().getId() if moment.tzinfo is not None and "local" not in self._iso else ""
            if self._iso in ("date", "local_date"):
                return self._need(has_date, "YearOfEra") or date + suffix
            if self._iso in ("time", "local_time"):
                return self._need(has_time, "HourOfDay") or time + suffix
            self._need(has_date, "YearOfEra")
            self._need(has_time, "HourOfDay")
            text = date + "T" + time
            if self._iso == "local_date_time" or self._iso == "date_time" and moment.tzinfo is None:
                return text
            if moment.tzinfo is None:
                raise UnsupportedTemporalTypeException("Unsupported field: OffsetSeconds")
            text += temporal.getOffset().getId()
            if self._iso == "instant":
                return temporal.toInstant().toString()
            if self._iso in ("zoned_date_time", "date_time") and not isinstance(temporal._zone_id, ZoneOffset):
                text += "[" + temporal._zone_id.getId() + "]"
            return text
        for letter, _count in self._tokens:
            if letter is not None and letter in "HkKhmsSAnNa" and isinstance(temporal, LocalDate):
                raise UnsupportedTemporalTypeException("Unsupported field: HourOfDay")
            if letter is not None and letter in "GuyDMLdQqYwWEF" and isinstance(temporal, LocalTime):
                raise UnsupportedTemporalTypeException("Unsupported field: YearOfEra")
        zone_id = temporal._zone_id.getId() if isinstance(temporal, ZonedDateTime) else None
        try:
            return _t.format_fields(self._tokens, moment, nano, True, zone_id, self._symbols)
        except Exception as error:
            if getattr(error, "code", None) == "UNSUPPORTED_API" and moment.tzinfo is None:
                raise UnsupportedTemporalTypeException("Unsupported field: OffsetSeconds") from None
            raise

    @staticmethod
    def _need(present, field):
        if not present:
            raise UnsupportedTemporalTypeException("Unsupported field: " + field)
        return None

    def _parse(self, text):
        """(datetime, nano, zone id) of a parsed text; the datetime is aware when an offset was read."""
        text = _l._text(text, "text")
        if self._iso is not None:
            match = re.fullmatch(
                r"(?:(\d{4})-(\d{2})-(\d{2}))?T?(?:(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,9}))?)?)?"
                r"(Z|[+-]\d{2}:\d{2}(?::\d{2})?)?(?:\[([^\]]+)\])?", text)
            if match is None:
                raise DateTimeParseException(f"Text '{text}' could not be parsed at index 0")
            has_date, has_time, has_offset = bool(match.group(1)), bool(match.group(4)), bool(match.group(8))
            wants_date = self._iso not in ("time", "local_time")
            wants_time = self._iso not in ("date", "local_date")
            offset = "no" if "local" in self._iso else "yes" if self._iso in (
                "offset_date_time", "zoned_date_time", "instant") else "maybe"
            if match is None or has_date != wants_date or has_time != wants_time or \
                    ("T" in text) != (wants_date and wants_time) or has_offset != (offset == "yes") and \
                    offset != "maybe" or match.group(9) and self._iso not in ("zoned_date_time", "date_time") or \
                    self._iso == "instant" and match.group(8) != "Z":
                raise DateTimeParseException(f"Text '{text}' could not be parsed at index 0")
            try:
                moment = _datetime.datetime(int(match.group(1) or 1970), int(match.group(2) or 1),
                                            int(match.group(3) or 1), int(match.group(4) or 0),
                                            int(match.group(5) or 0), int(match.group(6) or 0))
            except ValueError as error:
                raise DateTimeParseException(f"Text '{text}' could not be parsed: {error}") from None
            if match.group(8):
                moment = moment.replace(tzinfo=ZoneOffset.of(match.group(8))._zone._tz)
            return moment, int((match.group(7) or "").ljust(9, "0")), match.group(9)
        tokens = [(letter, count) for letter, count in self._tokens]
        fields, end = _t.parse_fields([("y" if letter == "u" else letter, count) for letter, count in tokens], text, 0,
                                      self._symbols)
        if fields is None or end != len(text):
            index = end if fields is None else end
            raise DateTimeParseException(f"Text '{text}' could not be parsed at index {index}")
        nano = 0
        fraction = next((count for letter, count in tokens if letter == "S"), None)
        if "S" in fields:
            nano = int(str(fields.pop("S")).rjust(fraction, "0")[:9].ljust(9, "0"))
        if "n" in fields:
            nano = fields["n"]
        if fields.pop("short_year", False):
            fields["y"] = 2000 + fields["y"] % 100
        limits = {"M": (1, 12), "d": (1, 31), "H": (0, 23), "k": (1, 24), "h": (1, 12), "K": (0, 11),
                  "m": (0, 59), "s": (0, 59), "y": (1, 9999), "D": (1, 366)}
        for name, (low, high) in limits.items():
            if name in fields and not low <= fields[name] <= high:
                raise DateTimeParseException(f"Text '{text}' could not be parsed: Invalid value for {name}")
        if "d" in fields and "M" in fields:
            # SMART resolution: the day is capped at the month's length.
            fields["d"] = min(fields["d"], _calendar.monthrange(fields.get("y", 1970), fields["M"])[1])
        zone = self._zone._zone if self._zone is not None else _u.TimeZone.getTimeZone("UTC")
        try:
            millis = _t.resolve_fields(fields, zone, True)
        except IllegalArgumentException as error:
            raise DateTimeParseException(f"Text '{text}' could not be parsed: {error.getMessage()}") from None
        if "offset" in fields:
            offset = ZoneOffset.ofTotalSeconds(fields["offset"] * 60)
            return _u.to_datetime(millis, offset._zone), nano, None
        moment = _u.to_datetime(millis, zone)
        return (moment if self._zone is not None else moment.replace(tzinfo=None)), nano, None

    def parse(self, text):
        moment, nano, zone_id = self._parse(text)
        if zone_id is not None:
            return LocalDateTime._make(moment, nano).atZone(ZoneId.of(zone_id))
        if moment.tzinfo is not None:
            offset = ZoneOffset.ofTotalSeconds(moment.utcoffset() // _datetime.timedelta(seconds=1))
            return ZonedDateTime._make(moment.replace(tzinfo=offset._zone._tz), nano, offset)
        return LocalDateTime._make(moment, nano)


for _name, _iso in (("ISO_LOCAL_DATE", "local_date"), ("ISO_LOCAL_TIME", "local_time"),
                    ("ISO_LOCAL_DATE_TIME", "local_date_time"), ("ISO_OFFSET_DATE_TIME", "offset_date_time"),
                    ("ISO_ZONED_DATE_TIME", "zoned_date_time"), ("ISO_DATE_TIME", "date_time"),
                    ("ISO_DATE", "date"), ("ISO_TIME", "time"), ("ISO_INSTANT", "instant")):
    setattr(DateTimeFormatter, _name, DateTimeFormatter._make(None, _iso))


CLASSES = _l.register({
    "java.time.Instant": Instant,
    "java.time.Duration": Duration,
    "java.time.ZoneId": ZoneId,
    "java.time.ZoneOffset": ZoneOffset,
    "java.time.LocalDate": LocalDate,
    "java.time.LocalTime": LocalTime,
    "java.time.LocalDateTime": LocalDateTime,
    "java.time.ZonedDateTime": ZonedDateTime,
    "java.time.DayOfWeek": DayOfWeek,
    "java.time.Month": Month,
    "java.time.DateTimeException": DateTimeException,
    "java.time.temporal.ChronoUnit": ChronoUnit,
    "java.time.temporal.UnsupportedTemporalTypeException": UnsupportedTemporalTypeException,
    "java.time.zone.ZoneRulesException": ZoneRulesException,
    "java.time.format.DateTimeFormatter": DateTimeFormatter,
    "java.time.format.DateTimeParseException": DateTimeParseException,
})
