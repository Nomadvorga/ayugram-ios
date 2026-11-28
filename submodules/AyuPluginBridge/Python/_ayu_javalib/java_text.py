"""``java.text`` date and number formatting implemented in Python.

Text fields (month and day names, AM/PM, the era) exist for English and Russian, with
the CLDR names Android prints. A format asked to produce them for another language
raises ``UnsupportedAPI`` instead of printing English; numeric patterns work for every
locale. A format built without a ``Locale`` uses the host's default locale when the
host declares ``java.util.Locale`` (read once per plugin generation). Number symbols
exist for the same two languages; the predefined ``DateFormat`` styles are the ``en_US``
ones, and long time-zone names (``zzzz``) are not available.
"""
from __future__ import annotations

import datetime as _datetime
import decimal
import math
import re
import unicodedata

from . import java_lang as _l
from . import java_util as _u
from .java_lang import Enum, IllegalArgumentException, NullPointerException, Object

MONTHS = ("January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
          "November", "December")
DAYS = ("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")
# Per language: months (format, standalone), abbreviated months (format, standalone),
# days and abbreviated days from Monday, AM/PM, and the era (abbreviated, wide).
_SYMBOLS = {
    "en": (MONTHS, MONTHS, tuple(name[:3] for name in MONTHS), tuple(name[:3] for name in MONTHS), DAYS,
           tuple(name[:3] for name in DAYS), ("AM", "PM"), ("AD", "Anno Domini")),
    "ru": (
        ("\u044f\u043d\u0432\u0430\u0440\u044f", "\u0444\u0435\u0432\u0440\u0430\u043b\u044f", "\u043c\u0430\u0440\u0442\u0430",
         "\u0430\u043f\u0440\u0435\u043b\u044f", "\u043c\u0430\u044f", "\u0438\u044e\u043d\u044f", "\u0438\u044e\u043b\u044f",
         "\u0430\u0432\u0433\u0443\u0441\u0442\u0430", "\u0441\u0435\u043d\u0442\u044f\u0431\u0440\u044f",
         "\u043e\u043a\u0442\u044f\u0431\u0440\u044f", "\u043d\u043e\u044f\u0431\u0440\u044f", "\u0434\u0435\u043a\u0430\u0431\u0440\u044f"),
        ("\u044f\u043d\u0432\u0430\u0440\u044c", "\u0444\u0435\u0432\u0440\u0430\u043b\u044c", "\u043c\u0430\u0440\u0442",
         "\u0430\u043f\u0440\u0435\u043b\u044c", "\u043c\u0430\u0439", "\u0438\u044e\u043d\u044c", "\u0438\u044e\u043b\u044c",
         "\u0430\u0432\u0433\u0443\u0441\u0442", "\u0441\u0435\u043d\u0442\u044f\u0431\u0440\u044c", "\u043e\u043a\u0442\u044f\u0431\u0440\u044c",
         "\u043d\u043e\u044f\u0431\u0440\u044c", "\u0434\u0435\u043a\u0430\u0431\u0440\u044c"),
        ("\u044f\u043d\u0432.", "\u0444\u0435\u0432\u0440.", "\u043c\u0430\u0440.", "\u0430\u043f\u0440.", "\u043c\u0430\u044f",
         "\u0438\u044e\u043d.", "\u0438\u044e\u043b.", "\u0430\u0432\u0433.", "\u0441\u0435\u043d\u0442.", "\u043e\u043a\u0442.",
         "\u043d\u043e\u044f\u0431.", "\u0434\u0435\u043a."),
        ("\u044f\u043d\u0432.", "\u0444\u0435\u0432\u0440.", "\u043c\u0430\u0440\u0442", "\u0430\u043f\u0440.", "\u043c\u0430\u0439",
         "\u0438\u044e\u043d\u044c", "\u0438\u044e\u043b\u044c", "\u0430\u0432\u0433.", "\u0441\u0435\u043d\u0442.", "\u043e\u043a\u0442.",
         "\u043d\u043e\u044f\u0431.", "\u0434\u0435\u043a."),
        ("\u043f\u043e\u043d\u0435\u0434\u0435\u043b\u044c\u043d\u0438\u043a", "\u0432\u0442\u043e\u0440\u043d\u0438\u043a", "\u0441\u0440\u0435\u0434\u0430",
         "\u0447\u0435\u0442\u0432\u0435\u0440\u0433", "\u043f\u044f\u0442\u043d\u0438\u0446\u0430", "\u0441\u0443\u0431\u0431\u043e\u0442\u0430",
         "\u0432\u043e\u0441\u043a\u0440\u0435\u0441\u0435\u043d\u044c\u0435"),
        ("\u043f\u043d", "\u0432\u0442", "\u0441\u0440", "\u0447\u0442", "\u043f\u0442", "\u0441\u0431", "\u0432\u0441"),
        ("AM", "PM"),
        ("\u043d. \u044d.", "\u043e\u0442 \u0420\u043e\u0436\u0434\u0435\u0441\u0442\u0432\u0430 \u0425\u0440\u0438\u0441\u0442\u043e\u0432\u0430")),
}
ENGLISH = _SYMBOLS["en"]
_NUMERIC = "yYuMLwWDdFHkKhmsSnNA"


class ParseException(_l.Exception_):
    def __init__(self, message, offset):
        _l.Exception_.__init__(self, message)
        self._offset = offset

    def getErrorOffset(self):
        return self._offset


class ParsePosition(Object):
    def __init__(self, index):
        self._index, self._error = index, -1

    def getIndex(self):
        return self._index

    def setIndex(self, index):
        self._index = index

    def getErrorIndex(self):
        return self._error

    def setErrorIndex(self, index):
        self._error = index

    def toString(self):
        return f"java.text.ParsePosition[index={self._index},errorIndex={self._error}]"


def tokenize(pattern, letters, error, skip=""):
    """Split a date pattern into ``(letter, count)`` fields and ``(None, text)`` literals.

    Unquoted characters in ``skip`` are dropped (DateTimeFormatter's optional-section brackets).
    """
    if pattern is None:
        raise NullPointerException()
    tokens, index, size = [], 0, len(pattern)
    while index < size:
        char = pattern[index]
        if char == "'":
            if pattern[index + 1:index + 2] == "'":
                tokens.append((None, "'"))
                index += 2
                continue
            end, text = index + 1, []
            while True:
                if end >= size:
                    raise IllegalArgumentException("Unterminated quote")
                if pattern[end] == "'":
                    if pattern[end + 1:end + 2] == "'":
                        text.append("'")
                        end += 2
                        continue
                    break
                text.append(pattern[end])
                end += 1
            tokens.append((None, "".join(text)))
            index = end + 1
        elif char.isascii() and char.isalpha():
            end = index
            while end < size and pattern[end] == char:
                end += 1
            if char not in letters:
                raise IllegalArgumentException(error(char))
            tokens.append((char, end - index))
            index = end
        else:
            if char not in skip:
                tokens.append((None, char))
            index += 1
    merged = []
    for letter, value in tokens:
        if letter is None and merged and merged[-1][0] is None:
            merged[-1] = (None, merged[-1][1] + value)
        else:
            merged.append((letter, value))
    return merged


def has_text_fields(tokens):
    return any(letter in ("G", "a") or letter in ("M", "L", "E") and count >= 3 or letter == "E"
               for letter, count in tokens if letter is not None)


def _language(locale):
    language = locale.getLanguage()
    if not isinstance(language, str):
        raise TypeError("Expected a Locale")
    return language


def language_of(locale):
    """Language code of a Python-local or host ``Locale``; the default locale when None."""
    if locale is not None:
        return _language(locale)
    resolved = _l.resolve("java.util.Locale", _u.Locale)
    if resolved is _u.Locale:
        return _u.Locale.getDefault().getLanguage()
    # The device language cannot change while the application runs, so one host read
    # per plugin generation is enough.
    store = _l.scoped_store("locale")
    if "host_language" not in store:
        store["host_language"] = _language(resolved.getDefault())
    return store["host_language"]


def symbols_for(locale, tokens):
    """Name tables for the text fields of ``tokens``; the locale is consulted only when needed."""
    if not has_text_fields(tokens):
        return ENGLISH
    language = language_of(locale)
    symbols = _SYMBOLS.get(language or "en")
    if symbols is None:
        raise _l.unsupported(f"Month, day and AM/PM names are not available for the language '{language}'")
    return symbols


def _english_only(locale, what):
    language = language_of(locale)
    if language not in ("", "en"):
        raise _l.unsupported(f"{what} are only available for English, not for '{language}'")


def _offset_text(minutes, style):
    sign, minutes = ("-" if minutes < 0 else "+"), abs(minutes)
    hours, rest = divmod(minutes, 60)
    if style == "basic":
        return "%s%02d%02d" % (sign, hours, rest)
    if style == "colon":
        return "%s%02d:%02d" % (sign, hours, rest)
    if style == "hour":
        return "%s%02d" % (sign, hours) + ("%02d" % rest if rest else "")
    return "GMT%s%d" % (sign, hours) + (":%02d" % rest if rest else "")


def zone_name(moment):
    name = moment.tzname() or ""
    if name == "UTC" or name and not name.startswith("UTC"):
        return name
    return "GMT" + _offset_text(moment.utcoffset() // _datetime.timedelta(minutes=1), "colon")


def format_fields(tokens, moment, nano, modern, zone_id=None, symbols=ENGLISH):
    """Render tokens for an aware (or naive) datetime; ``modern`` selects DateTimeFormatter letters."""
    out = []
    months, standalone, short_months, short_standalone, days, short_days, markers, eras = symbols
    calendar = None

    def week(field):
        nonlocal calendar
        if calendar is None:
            calendar = _u.GregorianCalendar(moment.year, moment.month - 1, moment.day)
        return calendar.get(field)

    def offset():
        if moment.tzinfo is None:
            raise _l.unsupported("This value has no time zone to format")
        return moment.utcoffset() // _datetime.timedelta(minutes=1)

    for letter, count in tokens:
        if letter is None:
            out.append(count)
        elif letter == "G":
            out.append(eras[1] if modern and count == 4 else eras[0][0].upper() if count == 5 else eras[0])
        elif letter == "y" or letter == "u" and modern or letter == "Y":
            year = moment.year
            if letter == "Y" and moment.month == 12 and week(_u.Calendar.WEEK_OF_YEAR) == 1:
                year += 1
            out.append("%02d" % (year % 100) if count == 2 else str(year).rjust(count, "0"))
        elif letter == "u":
            out.append(str(moment.isoweekday()).rjust(count, "0"))
        elif letter in "ML":
            wide, short = (standalone, short_standalone) if letter == "L" else (months, short_months)
            if count >= 5:
                out.append(standalone[moment.month - 1][0].upper())
            elif count == 4:
                out.append(wide[moment.month - 1])
            elif count == 3:
                out.append(short[moment.month - 1])
            else:
                out.append(str(moment.month).rjust(count, "0"))
        elif letter == "E":
            out.append(days[moment.weekday()][0].upper() if count >= 5 else days[moment.weekday()] if count == 4
                       else short_days[moment.weekday()])
        elif letter == "a":
            out.append(markers[moment.hour >= 12])
        elif letter == "Q" or letter == "q":
            quarter = (moment.month - 1) // 3 + 1
            out.append(("1st", "2nd", "3rd", "4th")[quarter - 1] + " quarter" if count == 4 else
                       "Q%d" % quarter if count == 3 else str(quarter).rjust(count, "0"))
        elif letter == "S":
            out.append(("%09d" % nano)[:count].ljust(count, "0") if modern
                       else str(nano // 1_000_000).rjust(count, "0"))
        elif letter == "z":
            if count >= 4:
                raise _l.unsupported("Long time-zone names are not available")
            offset()
            out.append(zone_name(moment))
        elif letter == "Z":
            minutes = offset()
            if modern and count == 4:
                out.append("GMT" + (_offset_text(minutes, "colon") if minutes else ""))
            elif modern and count == 5:
                out.append(_offset_text(minutes, "colon") if minutes else "Z")
            else:
                out.append(_offset_text(minutes, "basic"))
        elif letter in "Xx":
            minutes = offset()
            if minutes == 0 and letter == "X":
                out.append("Z")
            else:
                out.append(_offset_text(minutes, ("hour", "basic", "colon")[min(count, 3) - 1]))
        elif letter == "O":
            minutes = offset()
            out.append("GMT" if not minutes else _offset_text(minutes, "short") if count == 1
                       else "GMT" + _offset_text(minutes, "colon"))
        elif letter == "V":
            if count != 2 or zone_id is None:
                raise IllegalArgumentException("Pattern letter count must be 2: V")
            out.append(zone_id)
        else:
            value = {
                "w": lambda: week(_u.Calendar.WEEK_OF_YEAR), "W": lambda: week(_u.Calendar.WEEK_OF_MONTH),
                "D": lambda: moment.timetuple().tm_yday, "d": lambda: moment.day,
                "F": lambda: (moment.day - 1) // 7 + 1, "H": lambda: moment.hour,
                "k": lambda: moment.hour or 24, "K": lambda: moment.hour % 12, "h": lambda: moment.hour % 12 or 12,
                "m": lambda: moment.minute, "s": lambda: moment.second, "n": lambda: nano,
                "N": lambda: ((moment.hour * 60 + moment.minute) * 60 + moment.second) * 1_000_000_000 + nano,
                "A": lambda: ((moment.hour * 60 + moment.minute) * 60 + moment.second) * 1000 + nano // 1_000_000,
            }[letter]()
            out.append(str(value).rjust(count, "0"))
    return "".join(out)


def _match_name(text, position, *tables):
    """(index, length) of the longest name from the tables that starts at ``position``."""
    lowered = text[position:].lower()
    best = None
    for names in tables:
        for index, name in enumerate(names):
            if lowered.startswith(name.lower()) and (best is None or len(name) > best[1]):
                best = (index, len(name))
    return best


def parse_fields(tokens, text, position, symbols=ENGLISH):
    """Parse ``text`` from ``position``; returns ``(fields, end)`` or ``(None, error_index)``."""
    fields = {}
    months, standalone, short_months, short_standalone, days, short_days, markers, eras = symbols
    for index, (letter, count) in enumerate(tokens):
        if letter is None:
            if not text.startswith(count, position):
                return None, position
            position += len(count)
            continue
        if letter in "ML" and count >= 3:
            found = _match_name(text, position, months, standalone, short_months, short_standalone)
            if found is None:
                return None, position
            fields["M"], position = found[0] + 1, position + found[1]
        elif letter == "E":
            found = _match_name(text, position, days, short_days)
            if found is None:
                return None, position
            position += found[1]
        elif letter == "a":
            found = _match_name(text, position, markers)
            if found is None:
                return None, position
            fields["a"], position = found[0], position + found[1]
        elif letter == "G":
            found = _match_name(text, position, eras)
            if found is None:
                return None, position
            position += found[1]
        elif letter in "zZXxO":
            match = re.compile(r"(Z|UTC|GMT|UT)?(?:([+-])(\d{1,2})(?::?(\d{2}))?)?").match(text, position)
            if match is None or match.end() == position:
                return None, position
            minutes = int(match.group(3) or 0) * 60 + int(match.group(4) or 0)
            fields["offset"], position = -minutes if match.group(2) == "-" else minutes, match.end()
        elif letter in _NUMERIC:
            following = tokens[index + 1][0] if index + 1 < len(tokens) else None
            adjacent = following is not None and following in _NUMERIC and not (following in "ML" and
                                                                              tokens[index + 1][1] >= 3)
            match = re.compile(r"\d{%d}" % count if adjacent else r"-?\d+" if letter in "yu" else r"\d+").match(
                text, position)
            if match is None:
                return None, position
            value = int(match.group())
            if letter in "yY" and count <= 2 and len(match.group()) == 2:
                fields["short_year"] = True
            fields["M" if letter == "L" else letter] = value
            position = match.end()
        else:
            return None, position
    return fields, position


def resolve_fields(fields, zone, modern=False):
    """Epoch milliseconds of parsed fields, with Java's lenient overflow."""
    year = fields.get("y", fields.get("u" if modern else "Y", fields.get("Y", 1970)))
    if fields.get("short_year"):
        # A two-digit year lands within 80 years before and 20 years after now.
        base = _datetime.datetime.now().year - 80
        year = base // 100 * 100 + year
        if year < base:
            year += 100
    if "offset" in fields:
        zone = _u.TimeZone.getTimeZone("GMT" + _offset_text(fields["offset"], "colon"))
    calendar = _u.GregorianCalendar(zone)
    calendar.clear()
    hour = fields.get("H")
    if hour is None and "k" in fields:
        hour = fields["k"] % 24
    if hour is None:
        half = fields["K"] if "K" in fields else fields["h"] % 12 if "h" in fields else 0
        hour = half + 12 * fields.get("a", 0)
    if "D" in fields and "M" not in fields:
        calendar.set(year, 0, fields["D"], hour, fields.get("m", 0), fields.get("s", 0))
    else:
        calendar.set(year, fields.get("M", 1) - 1, fields.get("d", 1), hour, fields.get("m", 0), fields.get("s", 0))
    if "S" in fields:
        calendar.set(_u.Calendar.MILLISECOND, fields["S"])
    return calendar.getTimeInMillis()


class Format(Object):
    def parseObject(self, text, *position):
        return self.parse(text, *position)


class DateFormat(Format):
    FULL, LONG, MEDIUM, SHORT, DEFAULT = 0, 1, 2, 3, 2
    _DATES = ("EEEE, MMMM d, y", "MMMM d, y", "MMM d, y", "M/d/yy")
    _TIMES = (None, "h:mm:ss a z", "h:mm:ss a", "h:mm a")

    def __init__(self):
        if type(self) is DateFormat:
            raise _l.unsupported("Use DateFormat.getDateInstance or SimpleDateFormat")

    @staticmethod
    def _style(style, table):
        if not 0 <= style <= 3:
            raise IllegalArgumentException(f"Illegal style {style}")
        if table[style] is None:
            raise _l.unsupported("The FULL time style needs long time-zone names")
        return table[style]

    @staticmethod
    def _locale(args):
        locale = args[0] if args else None
        _english_only(locale, "Predefined date styles")
        return locale

    @staticmethod
    def getDateInstance(style=2, *locale):
        return SimpleDateFormat(DateFormat._style(style, DateFormat._DATES), DateFormat._locale(locale))

    @staticmethod
    def getTimeInstance(style=2, *locale):
        return SimpleDateFormat(DateFormat._style(style, DateFormat._TIMES), DateFormat._locale(locale))

    @staticmethod
    def getDateTimeInstance(date_style=2, time_style=2, *locale):
        joiner = " 'at' " if date_style <= 1 else ", "
        return SimpleDateFormat(DateFormat._style(date_style, DateFormat._DATES) + joiner +
                                DateFormat._style(time_style, DateFormat._TIMES), DateFormat._locale(locale))

    @staticmethod
    def getInstance():
        return DateFormat.getDateTimeInstance(3, 3)


class SimpleDateFormat(DateFormat):
    _LETTERS = "GyYMLwWDdFEuaHkKhmsSzZX"

    def __init__(self, pattern=None, locale=None):
        self._locale = locale
        self._zone = _u.TimeZone.getDefault()
        if pattern is None:
            _english_only(locale, "Predefined date styles")
            pattern = "M/d/yy, h:mm a"
        self.applyPattern(pattern)

    def applyPattern(self, pattern):
        tokens = tokenize(pattern, SimpleDateFormat._LETTERS, lambda char: f"Illegal pattern character '{char}'")
        self._symbols = symbols_for(self._locale, tokens)
        self._pattern, self._tokens = pattern, tokens

    def toPattern(self):
        return self._pattern

    def setTimeZone(self, zone):
        if zone is None:
            raise NullPointerException()
        self._zone = zone

    def getTimeZone(self):
        return self._zone

    def isLenient(self):
        return True

    def setLenient(self, lenient):
        if not lenient:
            raise _l.unsupported("Strict date parsing is not supported")

    def format(self, value, *ignored):
        if ignored:
            raise _l.unsupported("format(Object, StringBuffer, FieldPosition) is not supported")
        if hasattr(type(value), "getTime"):
            millis = value.getTime()
            millis = millis.getTime() if hasattr(type(millis), "getTime") else millis
        elif _l.is_int(value):
            millis = value
        else:
            raise IllegalArgumentException("Cannot format given Object as a Date")
        moment = _u.to_datetime(millis, self._zone)
        return format_fields(self._tokens, moment, millis % 1000 * 1_000_000, False, None, self._symbols)

    def parse(self, text, position=None):
        if text is None:
            raise NullPointerException()
        start = 0 if position is None else position.getIndex()
        fields, end = parse_fields(self._tokens, text, start, self._symbols)
        if fields is None:
            if position is None:
                raise ParseException(f'Unparseable date: "{text}"', end)
            position.setErrorIndex(end)
            return None
        if position is not None:
            position.setIndex(end)
        return _u.Date(resolve_fields(fields, self._zone))

    def clone(self):
        copy = SimpleDateFormat(self._pattern, self._locale)
        copy._zone = self._zone
        return copy

    def __eq__(self, other):
        return isinstance(other, SimpleDateFormat) and self._pattern == other._pattern and self._zone == other._zone

    def __hash__(self):
        return hash(self._pattern)

    def hashCode(self):
        return _l.string_hash(self._pattern)


# --- numbers -------------------------------------------------------------------------------

class _RoundingMode(Enum):
    pass


_l.enum_constants(_RoundingMode, "UP", "DOWN", "CEILING", "FLOOR", "HALF_UP", "HALF_DOWN", "HALF_EVEN", "UNNECESSARY")
_ROUNDING = {"UP": decimal.ROUND_UP, "DOWN": decimal.ROUND_DOWN, "CEILING": decimal.ROUND_CEILING,
             "FLOOR": decimal.ROUND_FLOOR, "HALF_UP": decimal.ROUND_HALF_UP, "HALF_DOWN": decimal.ROUND_HALF_DOWN,
             "HALF_EVEN": decimal.ROUND_HALF_EVEN}


class DecimalFormatSymbols(Object):
    """Decimal and grouping separators for English and Russian; other languages reject."""
    _SEPARATORS = {"": (".", ","), "en": (".", ","), "ru": (",", "\u00a0")}

    def __init__(self, locale=None):
        language = language_of(locale)
        if language not in DecimalFormatSymbols._SEPARATORS:
            raise _l.unsupported(f"Number symbols are not available for the language '{language}'")
        self._decimal, self._grouping = DecimalFormatSymbols._SEPARATORS[language]
        self._minus, self._percent = "-", "%"

    @staticmethod
    def getInstance(locale=None):
        return DecimalFormatSymbols(locale)

    def getDecimalSeparator(self):
        return self._decimal

    def setDecimalSeparator(self, char):
        self._decimal = char

    def getGroupingSeparator(self):
        return self._grouping

    def setGroupingSeparator(self, char):
        self._grouping = char

    def getMinusSign(self):
        return self._minus

    def setMinusSign(self, char):
        self._minus = char

    def getPercent(self):
        return self._percent

    def getZeroDigit(self):
        return "0"

    def getNaN(self):
        return "NaN"

    def getInfinity(self):
        return "\u221e"

    def clone(self):
        copy = object.__new__(DecimalFormatSymbols)
        copy.__dict__.update(self.__dict__)
        return copy


class NumberFormat(Format):
    INTEGER_FIELD, FRACTION_FIELD = 0, 1

    def __init__(self):
        if type(self) is NumberFormat:
            raise _l.unsupported("Use NumberFormat.getInstance or DecimalFormat")

    @staticmethod
    def _symbols(locale):
        return DecimalFormatSymbols(locale[0] if locale else None)

    @staticmethod
    def getInstance(*locale):
        return DecimalFormat("#,##0.###", NumberFormat._symbols(locale))

    getNumberInstance = getInstance

    @staticmethod
    def getIntegerInstance(*locale):
        result = DecimalFormat("#,##0", NumberFormat._symbols(locale))
        result.setParseIntegerOnly(True)
        return result

    @staticmethod
    def getPercentInstance(*locale):
        symbols = NumberFormat._symbols(locale)
        # CLDR separates the percent sign with a no-break space in Russian.
        return DecimalFormat("#,##0\u00a0%" if symbols.getDecimalSeparator() == "," else "#,##0%", symbols)

    @staticmethod
    def getCurrencyInstance(*locale):
        raise _l.unsupported("Currency formats are not supported")


class DecimalFormat(NumberFormat):
    """Fixed-point decimal patterns (``#,##0.00``, ``0.#%``). Exponent and currency patterns reject."""

    def __init__(self, pattern="#,##0.###", symbols=None):
        self._symbols = symbols if symbols is not None else NumberFormat._symbols(())
        self._rounding, self._integer_only = "HALF_EVEN", False
        self.applyPattern(pattern)

    def applyPattern(self, pattern):
        if pattern is None:
            raise NullPointerException()
        positive, _, negative = self._split(pattern)
        self._pattern = pattern
        self._prefix, body, self._suffix = self._affixes(positive)
        self._negative = None
        if negative:
            prefix, _, suffix = self._affixes(negative)
            self._negative = (prefix, suffix)
        if "E" in body or "\u00a4" in pattern:
            raise _l.unsupported("Exponent and currency number patterns are not supported")
        self._multiplier = 100 if "%" in self._prefix + self._suffix else \
            1000 if "\u2030" in self._prefix + self._suffix else 1
        whole, dot, fraction = body.partition(".")
        if not re.fullmatch(r"[#,]*[0,]*", whole) or not re.fullmatch(r"0*#*", fraction) or not body:
            raise IllegalArgumentException(f'Malformed pattern "{pattern}"')
        self._grouping = len(whole) - whole.rfind(",") - 1 if "," in whole else 0
        self._grouping_used = self._grouping > 0
        self._min_integer = whole.count("0")
        self._max_integer = _l.INT_MAX
        self._min_fraction, self._max_fraction = fraction.count("0"), len(fraction)
        self._always_point = bool(dot) and not fraction

    @staticmethod
    def _split(pattern):
        quoted, index = False, 0
        for index, char in enumerate(pattern):
            if char == "'":
                quoted = not quoted
            elif char == ";" and not quoted:
                return pattern[:index], ";", pattern[index + 1:]
        return pattern, "", ""

    @staticmethod
    def _affixes(pattern):
        """(prefix, number body, suffix) with quotes removed from the affixes."""
        prefix, body, suffix, quoted, stage = [], [], [], False, 0
        index = 0
        while index < len(pattern):
            char = pattern[index]
            if char == "'":
                if pattern[index + 1:index + 2] == "'":
                    (prefix if stage == 0 else suffix).append("'")
                    index += 2
                    continue
                quoted = not quoted
            elif not quoted and char in "#0,.E" and stage < 2:
                stage = 1
                body.append(char)
            else:
                if stage == 1:
                    stage = 2
                (prefix if stage == 0 else suffix).append(char)
            index += 1
        return "".join(prefix), "".join(body), "".join(suffix)

    def toPattern(self):
        return self._pattern

    def getDecimalFormatSymbols(self):
        return self._symbols.clone()

    def setDecimalFormatSymbols(self, symbols):
        self._symbols = symbols.clone()

    def setRoundingMode(self, mode):
        if mode is None:
            raise NullPointerException()
        self._rounding = mode.name()

    def getRoundingMode(self):
        return _RoundingMode.valueOf(self._rounding)

    def setGroupingUsed(self, used):
        self._grouping_used = bool(used)

    def isGroupingUsed(self):
        return self._grouping_used

    def setGroupingSize(self, size):
        self._grouping = size

    def getGroupingSize(self):
        return self._grouping

    def setParseIntegerOnly(self, value):
        self._integer_only = bool(value)

    def isParseIntegerOnly(self):
        return self._integer_only

    def setMinimumFractionDigits(self, digits):
        self._min_fraction = max(digits, 0)
        self._max_fraction = max(self._max_fraction, self._min_fraction)

    def setMaximumFractionDigits(self, digits):
        self._max_fraction = max(digits, 0)
        self._min_fraction = min(self._min_fraction, self._max_fraction)

    def setMinimumIntegerDigits(self, digits):
        self._min_integer = max(digits, 0)
        self._max_integer = max(self._max_integer, self._min_integer)

    def setMaximumIntegerDigits(self, digits):
        self._max_integer = max(digits, 0)
        self._min_integer = min(self._min_integer, self._max_integer)

    def getMinimumFractionDigits(self):
        return self._min_fraction

    def getMaximumFractionDigits(self):
        return self._max_fraction

    def getMinimumIntegerDigits(self):
        return self._min_integer

    def getMaximumIntegerDigits(self):
        return self._max_integer

    def format(self, value, *ignored):
        if ignored:
            raise _l.unsupported("format(Object, StringBuffer, FieldPosition) is not supported")
        if isinstance(value, bool) or not isinstance(value, (int, float, decimal.Decimal)):
            raise IllegalArgumentException("Cannot format given Object as a Number")
        negative = value < 0 or isinstance(value, float) and math.copysign(1.0, value) < 0 and value == 0
        if isinstance(value, float) and value != value:
            return self._symbols.getNaN()
        if isinstance(value, float) and value in (math.inf, -math.inf):
            body = self._symbols.getInfinity()
        else:
            number = abs(decimal.Decimal(repr(value)) if isinstance(value, float) else decimal.Decimal(value))
            if self._rounding == "UNNECESSARY":
                rounded = number * self._multiplier
                if rounded != rounded.quantize(decimal.Decimal(1).scaleb(-self._max_fraction)):
                    raise _l.ArithmeticException("Rounding needed with the rounding method being set to "
                                                 "RoundingMode.UNNECESSARY")
            with decimal.localcontext() as context:
                context.prec = 400
                mode = _ROUNDING.get(self._rounding, decimal.ROUND_HALF_EVEN)
                if negative and mode in (decimal.ROUND_CEILING, decimal.ROUND_FLOOR):
                    mode = decimal.ROUND_FLOOR if mode == decimal.ROUND_CEILING else decimal.ROUND_CEILING
                number = (number * self._multiplier).quantize(decimal.Decimal(1).scaleb(-self._max_fraction),
                                                              rounding=mode)
            whole, _, fraction = format(number, "f").partition(".")
            whole = whole.lstrip("0")
            if len(whole) > self._max_integer:
                whole = whole[len(whole) - self._max_integer:]
            whole = whole.rjust(self._min_integer, "0")
            fraction = fraction.rstrip("0").ljust(self._min_fraction, "0")
            if self._grouping_used and self._grouping > 0 and len(whole) > self._grouping:
                head = len(whole) % self._grouping or self._grouping
                whole = self._symbols.getGroupingSeparator().join(
                    [whole[:head]] + [whole[index:index + self._grouping]
                                      for index in range(head, len(whole), self._grouping)])
            body = whole + (self._symbols.getDecimalSeparator() + fraction if fraction or self._always_point else "")
        if negative:
            prefix, suffix = self._negative or (self._symbols.getMinusSign() + self._prefix, self._suffix)
            return prefix + body + suffix
        return self._prefix + body + self._suffix

    def parse(self, text, position=None):
        if text is None:
            raise NullPointerException()
        start = 0 if position is None else position.getIndex()
        index, negative = start, False
        prefix, suffix = self._negative or (self._symbols.getMinusSign() + self._prefix, self._suffix)
        plain, minus = text.startswith(self._prefix, index), text.startswith(prefix, index)
        if plain and minus:
            # The longer matching prefix wins, as in Java.
            plain, minus = len(self._prefix) >= len(prefix), len(prefix) > len(self._prefix)
        if plain:
            index += len(self._prefix)
        elif minus:
            negative, index = True, index + len(prefix)
        else:
            index = len(text)
        digits, point, seen = [], None, False
        while index < len(text):
            char = text[index]
            if char.isdigit():
                digits.append(str(unicodedata.digit(char)))
                seen = True
            elif char == self._symbols.getDecimalSeparator() and point is None and not self._integer_only:
                point = len(digits)
            elif char == self._symbols.getGroupingSeparator() and self._grouping_used and point is None and seen:
                pass
            else:
                break
            index += 1
        ending = suffix if negative else self._suffix
        if not seen or not text.startswith(ending, index):
            if position is None:
                raise ParseException(f'Unparseable number: "{text}"', start)
            position.setErrorIndex(start)
            return None
        index += len(ending)
        if position is not None:
            position.setIndex(index)
        value = decimal.Decimal("".join(digits) or "0").scaleb(-(len(digits) - point) if point is not None else 0)
        value /= self._multiplier
        if negative:
            value = -value
        if value == value.to_integral_value() and _l.LONG_MIN <= value <= _l.LONG_MAX:
            return -0.0 if negative and value == 0 else int(value)
        return float(value)


class _Form(Enum):
    pass


_l.enum_constants(_Form, "NFD", "NFC", "NFKD", "NFKC")


class Normalizer(Object):
    Form = _Form

    def __init__(self):
        raise _l.unsupported("java.text.Normalizer cannot be constructed")

    @staticmethod
    def normalize(text, form):
        return unicodedata.normalize(form.name(), _l._text(text))

    @staticmethod
    def isNormalized(text, form):
        text = _l._text(text)
        return unicodedata.normalize(form.name(), text) == text


CLASSES = _l.register({
    "java.text.Format": Format,
    "java.text.DateFormat": DateFormat,
    "java.text.SimpleDateFormat": SimpleDateFormat,
    "java.text.NumberFormat": NumberFormat,
    "java.text.DecimalFormat": DecimalFormat,
    "java.text.DecimalFormatSymbols": DecimalFormatSymbols,
    "java.text.ParseException": ParseException,
    "java.text.ParsePosition": ParsePosition,
    "java.text.Normalizer": Normalizer,
    "java.text.Normalizer$Form": _Form,
    "java.math.RoundingMode": _RoundingMode,
})
