"""``android.text`` text containers, spans and helpers implemented in Python.

Spans are value objects: nothing here measures or draws text, so ``TextUtils.ellipsize``,
layouts, ``TextPaint`` and movement methods stay with the host. A local spannable handed
to the host is sent as its plain text. Indices are UTF-16 code units.

Deliberate differences from Android:
- ``SpannableStringBuilder`` edits follow the mark/point rules for insertions; a boundary
  inside a replaced range moves to the start (mark) or the end (point) of the new text.
- ``Html.fromHtml`` builds the text and the character spans it can express; an ``<img>``
  contributes its object-replacement character without an ``ImageSpan``, and list bullets
  and quote margins have no span.
"""
from __future__ import annotations

import unicodedata

from . import java_lang as _l
from .java_lang import CharSequence, Enum, IllegalArgumentException, IndexOutOfBoundsException, NullPointerException, Object


class Spanned(CharSequence):
    SPAN_POINT_MARK_MASK, SPAN_MARK_MARK, SPAN_MARK_POINT, SPAN_POINT_MARK, SPAN_POINT_POINT = 0x33, 0x11, 0x12, 0x21, 0x22
    SPAN_PARAGRAPH = 0x33
    SPAN_INCLUSIVE_EXCLUSIVE, SPAN_INCLUSIVE_INCLUSIVE, SPAN_EXCLUSIVE_EXCLUSIVE, SPAN_EXCLUSIVE_INCLUSIVE = \
        0x11, 0x12, 0x21, 0x22
    SPAN_COMPOSING, SPAN_INTERMEDIATE, SPAN_USER_SHIFT, SPAN_USER = 0x100, 0x200, 24, -16777216
    SPAN_PRIORITY_SHIFT, SPAN_PRIORITY = 16, 0xFF0000


class Spannable(Spanned):
    pass


class Editable(Spannable):
    pass


def _matches(span, kind):
    if kind is None or kind is Object:
        return True
    if isinstance(kind, _l.Class):
        return kind.isInstance(span)
    if isinstance(kind, type):
        return isinstance(span, kind)
    name = getattr(kind, "_name", None)
    if isinstance(name, str):
        # A host class facade matches host span handles of exactly that class.
        return type(span).__name__ == "RemoteObject" and getattr(span, "_class_name", None) == name
    raise TypeError("Expected a span class")


class _SpanText(Spanned):
    """Text in UTF-16 units plus spans as ``[what, start, end, flags]`` in attachment order."""

    def __init__(self, source="", start=None, end=None):
        text = _l.units(_l._text(source, "source"))
        start = 0 if start is None else start
        end = len(text) if end is None else end
        if start < 0 or end > len(text) or start > end:
            raise IndexOutOfBoundsException(f"start {start}, end {end}, length {len(text)}")
        self._chars, self._spans = text[start:end], []
        if isinstance(source, _SpanText):
            self._copy_spans(source, start, end, 0)

    def _copy_spans(self, source, start, end, offset):
        for what, span_start, span_end, flags in source._spans:
            if span_start > end or span_end < start:
                continue
            self._spans.append([what, max(span_start, start) - start + offset, min(span_end, end) - start + offset,
                                flags])

    def toString(self):
        return _l.from_units(self._chars)

    def to_bridge(self):
        return self.toString()

    def length(self):
        return len(self._chars)

    def __len__(self):
        return len(self.toString())

    def __repr__(self):
        return self.toString()

    def charAt(self, index):
        if not 0 <= index < len(self._chars):
            raise IndexOutOfBoundsException(f"charAt: {index} >= length {len(self._chars)}" if index >= 0
                                            else f"charAt: {index} < 0")
        return self._chars[index]

    def _range(self, start, end, operation):
        if end < start:
            raise IndexOutOfBoundsException(f"{operation} ({start} ... {end}) has end before start")
        if start > len(self._chars) or end > len(self._chars):
            raise IndexOutOfBoundsException(f"{operation} ({start} ... {end}) ends beyond length {len(self._chars)}")
        if start < 0 or end < 0:
            raise IndexOutOfBoundsException(f"{operation} ({start} ... {end}) starts before 0")

    def subSequence(self, start, end):
        self._range(start, end, "subSequence")
        return type(self)(self, start, end)

    def _entry(self, what):
        return next((entry for entry in self._spans if entry[0] is what), None)

    def getSpanStart(self, what):
        entry = self._entry(what)
        return -1 if entry is None else entry[1]

    def getSpanEnd(self, what):
        entry = self._entry(what)
        return -1 if entry is None else entry[2]

    def getSpanFlags(self, what):
        entry = self._entry(what)
        return 0 if entry is None else entry[3]

    def _selected(self, start, end, kind):
        for order, (what, span_start, span_end, flags) in enumerate(self._spans):
            if span_start > end or span_end < start:
                continue
            if span_start != span_end and start != end and (span_start == end or span_end == start):
                continue
            if _matches(what, kind):
                yield -(flags & Spanned.SPAN_PRIORITY), order, what, span_start, span_end

    def getSpans(self, start, end, kind=None):
        return [item[2] for item in sorted(self._selected(start, end, kind), key=lambda item: item[:2])]

    def nextSpanTransition(self, start, limit, kind=None):
        for what, span_start, span_end, _flags in self._spans:
            if not _matches(what, kind):
                continue
            if start < span_start < limit:
                limit = span_start
            if start < span_end < limit:
                limit = span_end
        return limit

    def equals(self, other):
        if not isinstance(other, _SpanText) or self._chars != other._chars or len(self._spans) != len(other._spans):
            return False
        return all(mine[0] is theirs[0] and mine[1:] == theirs[1:] for mine, theirs in zip(self._spans, other._spans))

    def hashCode(self):
        result = _l.string_hash(self.toString())
        result = _l.i32(result * 31 + len(self._spans))
        for what, start, end, flags in self._spans:
            if what is not self:
                result = _l.i32(result * 31 + _l.java_hash(what))
            for item in (start, end, flags):
                result = _l.i32(result * 31 + item)
        return result

    def _set(self, what, start, end, flags):
        if what is None:
            raise NullPointerException("span is null")
        self._range(start, end, "setSpan")
        if (flags & Spanned.SPAN_POINT_MARK_MASK) == Spanned.SPAN_PARAGRAPH:
            for position, name in ((start, "start"), (end, "end")):
                if position not in (0, len(self._chars)) and self._chars[position - 1] != "\n":
                    raise _l.RuntimeException(f"PARAGRAPH span must {name} at paragraph boundary")
        entry = self._entry(what)
        if entry is None:
            self._spans.append([what, start, end, flags])
        else:
            entry[1:] = [start, end, flags]

    def _remove(self, what):
        entry = self._entry(what)
        if entry is not None:
            self._spans.remove(entry)


class SpannedString(_SpanText):
    @staticmethod
    def valueOf(source):
        return source if isinstance(source, SpannedString) else SpannedString(source)


class SpannableString(_SpanText, Spannable):
    @staticmethod
    def valueOf(source):
        return source if isinstance(source, SpannableString) else SpannableString(source)

    def setSpan(self, what, start, end, flags):
        self._set(what, start, end, flags)

    def removeSpan(self, what):
        self._remove(what)


class SpannableStringBuilder(_SpanText, Editable):
    @staticmethod
    def valueOf(source):
        return source if isinstance(source, SpannableStringBuilder) else SpannableStringBuilder(source)

    def setSpan(self, what, start, end, flags):
        self._set(what, start, end, flags)

    def removeSpan(self, what):
        self._remove(what)

    def clearSpans(self):
        del self._spans[:]

    def clear(self):
        self._chars = ""
        del self._spans[:]

    def _moved(self, position, kind, start, end, inserted):
        if position < start or position == start and start < end:
            return position
        if position > end:
            return position + inserted - (end - start)
        if start == end:
            return start + inserted if kind == 2 else start
        if position == end or kind == 2:
            return start + inserted
        return start

    def replace(self, start, end, text, text_start=None, text_end=None):
        self._range(start, end, "replace")
        source = _l.units(_l._text(text, "text"))
        text_start = 0 if text_start is None else text_start
        text_end = len(source) if text_end is None else text_end
        if text_start < 0 or text_end > len(source) or text_start > text_end:
            raise IndexOutOfBoundsException(f"start {text_start}, end {text_end}, length {len(source)}")
        inserted = text_end - text_start
        kept = []
        for entry in self._spans:
            what, span_start, span_end, flags = entry
            swallowed = start < end and span_start >= start and span_end <= end and \
                (flags & Spanned.SPAN_POINT_MARK_MASK) == Spanned.SPAN_EXCLUSIVE_EXCLUSIVE and \
                (span_start > start or span_end < end or not inserted)
            if swallowed:
                continue
            entry[1] = self._moved(span_start, (flags & 0xF0) >> 4, start, end, inserted)
            entry[2] = max(entry[1], self._moved(span_end, flags & 0x0F, start, end, inserted))
            kept.append(entry)
        self._spans = kept
        self._chars = self._chars[:start] + source[text_start:text_end] + self._chars[end:]
        if isinstance(text, _SpanText):
            for what, span_start, span_end, flags in text._spans:
                if span_start > text_end or span_end < text_start or self._entry(what) is not None:
                    continue
                self._spans.append([what, max(span_start, text_start) - text_start + start,
                                    min(span_end, text_end) - text_start + start, flags])
        return self

    def append(self, *args):
        if len(args) == 3 and not _l.is_int(args[1]):
            text, what, flags = args
            start = len(self._chars)
            self.replace(start, start, text)
            self._set(what, start, len(self._chars), flags)
            return self
        if len(args) not in (1, 3):
            raise TypeError("append takes (text), (text, start, end) or (text, what, flags)")
        text = "null" if args[0] is None else args[0]
        return self.replace(len(self._chars), len(self._chars), text, *args[1:])

    def insert(self, where, text, *bounds):
        return self.replace(where, where, text, *bounds)

    def delete(self, start, end):
        return self.replace(start, end, "")

    def getFilters(self):
        return []

    def setFilters(self, filters):
        if filters is None:
            raise IllegalArgumentException()
        if len(filters):
            raise _l.unsupported("Input filters on a SpannableStringBuilder are not supported")


# --- spans ---------------------------------------------------------------------------------

class UpdateAppearance(Object):
    pass


class UpdateLayout(UpdateAppearance):
    pass


class CharacterStyle(Object):
    @staticmethod
    def wrap(style):
        return style

    def getUnderlying(self):
        return self


class MetricAffectingSpan(CharacterStyle, UpdateLayout):
    pass


class ClickableSpan(CharacterStyle, UpdateAppearance):
    pass


def _span(name, base, *fields, check=None):
    """A value span whose constructor arguments are exposed by the named getters."""
    def __init__(self, *args):
        required = [getter for getter, default in fields if default is _REQUIRED]
        if not len(required) <= len(args) <= len(fields):
            raise TypeError(f"{name} takes {len(required)} to {len(fields)} arguments")
        values = list(args) + [default for _getter, default in fields[len(args):]]
        self._values = tuple(check(values) if check else values)

    members = {"__module__": __name__, "__qualname__": name, "__init__": __init__}
    for index, (getter, _default) in enumerate(fields):
        members[getter] = lambda self, _index=index: self._values[_index]
    return _l.JavaMeta(name, base if isinstance(base, tuple) else (base,), members)


_REQUIRED = object()


def _int_color(values):
    if not _l.is_int(values[0]):
        raise TypeError("Expected a packed int color")
    return [_l.i32(values[0])] + values[1:]


def _float_first(values):
    return [_l.to_float32(values[0])] + values[1:]


def _family(values):
    if values[0] is not None and not isinstance(values[0], str):
        # TypefaceSpan(Typeface): the family is unknown, the typeface is kept.
        return [None, values[0]]
    return [values[0], None]


ForegroundColorSpan = _span("ForegroundColorSpan", (CharacterStyle, UpdateAppearance),
                            ("getForegroundColor", _REQUIRED), check=_int_color)
BackgroundColorSpan = _span("BackgroundColorSpan", (CharacterStyle, UpdateAppearance),
                            ("getBackgroundColor", _REQUIRED), check=_int_color)
StyleSpan = _span("StyleSpan", MetricAffectingSpan, ("getStyle", _REQUIRED), ("getFontWeightAdjustment", _l.INT_MAX))
UnderlineSpan = _span("UnderlineSpan", (CharacterStyle, UpdateAppearance))
StrikethroughSpan = _span("StrikethroughSpan", (CharacterStyle, UpdateAppearance))
SuperscriptSpan = _span("SuperscriptSpan", MetricAffectingSpan)
SubscriptSpan = _span("SubscriptSpan", MetricAffectingSpan)
TypefaceSpan = _span("TypefaceSpan", MetricAffectingSpan, ("getFamily", _REQUIRED), ("getTypeface", None),
                     check=_family)
RelativeSizeSpan = _span("RelativeSizeSpan", MetricAffectingSpan, ("getSizeChange", _REQUIRED), check=_float_first)
ScaleXSpan = _span("ScaleXSpan", MetricAffectingSpan, ("getScaleX", _REQUIRED), check=_float_first)
AbsoluteSizeSpan = _span("AbsoluteSizeSpan", MetricAffectingSpan, ("getSize", _REQUIRED), ("getDip", False))
URLSpan = _span("URLSpan", ClickableSpan, ("getURL", _REQUIRED))
QuoteSpan = _span("QuoteSpan", Object, ("getColor", -16776961))


class _Alignment(Enum):
    pass


class _TruncateAt(Enum):
    pass


_l.enum_constants(_Alignment, "ALIGN_NORMAL", "ALIGN_OPPOSITE", "ALIGN_CENTER")
_l.enum_constants(_TruncateAt, "START", "MIDDLE", "END", "MARQUEE")


class Layout(Object):
    """Layout constants and the alignment enum; laying text out needs the host's text engine."""
    Alignment = _Alignment
    DIR_LEFT_TO_RIGHT, DIR_RIGHT_TO_LEFT = 1, -1
    BREAK_STRATEGY_SIMPLE, BREAK_STRATEGY_HIGH_QUALITY, BREAK_STRATEGY_BALANCED = 0, 1, 2
    HYPHENATION_FREQUENCY_NONE, HYPHENATION_FREQUENCY_NORMAL, HYPHENATION_FREQUENCY_FULL = 0, 1, 2
    JUSTIFICATION_MODE_NONE, JUSTIFICATION_MODE_INTER_WORD = 0, 1
    DEFAULT_LINESPACING_MULTIPLIER, DEFAULT_LINESPACING_ADDITION = 1.0, 0.0

    def __init__(self, *args):
        raise _l.unsupported("android.text.Layout needs the host's text layout engine")

    @staticmethod
    def getDesiredWidth(*args):
        raise _l.unsupported("Layout.getDesiredWidth needs text measurement from the host")


class TextWatcher(Object):
    def beforeTextChanged(self, text, start, count, after):
        raise _l.missing_member(type(self), "beforeTextChanged")

    def onTextChanged(self, text, start, before, count):
        raise _l.missing_member(type(self), "onTextChanged")

    def afterTextChanged(self, editable):
        raise _l.missing_member(type(self), "afterTextChanged")


class InputType(Object):
    __ayu_overrides_host__ = True  # the Swift adapter is a subset; the host neither takes nor returns one
    TYPE_MASK_CLASS, TYPE_MASK_VARIATION, TYPE_MASK_FLAGS, TYPE_NULL = 0xF, 0xFF0, 0xFFF000, 0
    TYPE_CLASS_TEXT, TYPE_CLASS_NUMBER, TYPE_CLASS_PHONE, TYPE_CLASS_DATETIME = 1, 2, 3, 4
    TYPE_TEXT_FLAG_CAP_CHARACTERS, TYPE_TEXT_FLAG_CAP_WORDS, TYPE_TEXT_FLAG_CAP_SENTENCES = 0x1000, 0x2000, 0x4000
    TYPE_TEXT_FLAG_AUTO_CORRECT, TYPE_TEXT_FLAG_AUTO_COMPLETE, TYPE_TEXT_FLAG_MULTI_LINE = 0x8000, 0x10000, 0x20000
    TYPE_TEXT_FLAG_IME_MULTI_LINE, TYPE_TEXT_FLAG_NO_SUGGESTIONS = 0x40000, 0x80000
    TYPE_TEXT_FLAG_ENABLE_TEXT_CONVERSION_SUGGESTIONS = 0x100000
    TYPE_TEXT_VARIATION_NORMAL, TYPE_TEXT_VARIATION_URI, TYPE_TEXT_VARIATION_EMAIL_ADDRESS = 0x0, 0x10, 0x20
    TYPE_TEXT_VARIATION_EMAIL_SUBJECT, TYPE_TEXT_VARIATION_SHORT_MESSAGE = 0x30, 0x40
    TYPE_TEXT_VARIATION_LONG_MESSAGE, TYPE_TEXT_VARIATION_PERSON_NAME = 0x50, 0x60
    TYPE_TEXT_VARIATION_POSTAL_ADDRESS, TYPE_TEXT_VARIATION_PASSWORD = 0x70, 0x80
    TYPE_TEXT_VARIATION_VISIBLE_PASSWORD, TYPE_TEXT_VARIATION_WEB_EDIT_TEXT = 0x90, 0xA0
    TYPE_TEXT_VARIATION_FILTER, TYPE_TEXT_VARIATION_PHONETIC = 0xB0, 0xC0
    TYPE_TEXT_VARIATION_WEB_EMAIL_ADDRESS, TYPE_TEXT_VARIATION_WEB_PASSWORD = 0xD0, 0xE0
    TYPE_NUMBER_FLAG_SIGNED, TYPE_NUMBER_FLAG_DECIMAL = 0x1000, 0x2000
    TYPE_NUMBER_VARIATION_NORMAL, TYPE_NUMBER_VARIATION_PASSWORD = 0x0, 0x10
    TYPE_DATETIME_VARIATION_NORMAL, TYPE_DATETIME_VARIATION_DATE, TYPE_DATETIME_VARIATION_TIME = 0x0, 0x10, 0x20


class InputFilter(Object):
    def filter(self, source, start, end, dest, dstart, dend):
        raise _l.missing_member(type(self), "filter")


class _LengthFilter(InputFilter):
    def __init__(self, maximum):
        self._max = maximum

    def getMax(self):
        return self._max

    def filter(self, source, start, end, dest, dstart, dend):
        keep = self._max - (_l.utf16_length(_l._text(dest)) - (dend - dstart))
        if keep <= 0:
            return ""
        if keep >= end - start:
            return None
        keep += start
        text = _l.units(_l._text(source))
        if "\ud800" <= text[keep - 1] <= "\udbff":
            keep -= 1
            if keep == start:
                return ""
        return _l.from_units(text[start:keep])


class _AllCaps(InputFilter):
    def __init__(self, locale=None):
        pass

    def filter(self, source, start, end, dest, dstart, dend):
        text = _l.units(_l._text(source))[start:end]
        upper = _l.from_units(text).upper()
        return None if upper == _l.from_units(text) else upper


InputFilter.LengthFilter, InputFilter.AllCaps = _LengthFilter, _AllCaps


class TextUtils(Object):
    TruncateAt = _l.HostFirst("android.text.TextUtils$TruncateAt", _TruncateAt)
    CAP_MODE_CHARACTERS, CAP_MODE_WORDS, CAP_MODE_SENTENCES = 0x1000, 0x2000, 0x4000

    def __init__(self):
        raise _l.unsupported("android.text.TextUtils cannot be constructed")

    @staticmethod
    def isEmpty(text):
        return text is None or _l._text(text) == ""

    @staticmethod
    def equals(first, second):
        if first is None or second is None:
            return first is second
        return _l._text(first) == _l._text(second)

    @staticmethod
    def join(delimiter, tokens):
        return _l._text(delimiter, "delimiter").join(_l.jstr(item) for item in tokens)

    @staticmethod
    def split(text, expression):
        text = _l._text(text)
        if not text:
            return []
        compiled = expression._compiled if hasattr(expression, "_compiled") else _l.translate_regex(expression)
        return _l.regex_split(compiled, text, -1)

    @staticmethod
    def htmlEncode(text):
        return "".join({"<": "&lt;", ">": "&gt;", "&": "&amp;", "'": "&#39;", '"': "&quot;"}.get(char, char)
                       for char in _l._text(text))

    @staticmethod
    def isDigitsOnly(text):
        return all(unicodedata.category(char) == "Nd" for char in _l._text(text))

    @staticmethod
    def isGraphic(text):
        chars = text if isinstance(text, str) and len(text) == 1 else _l._text(text)
        return any(unicodedata.category(char) not in ("Cc", "Cf", "Cs", "Cn", "Zl", "Zp", "Zs") for char in chars)

    @staticmethod
    def getTrimmedLength(text):
        return _l.utf16_length(_l._text(text).strip("".join(map(chr, range(33)))))

    @staticmethod
    def substring(source, start, end):
        return _l.String(_l._text(source)).substring(start, end)

    @staticmethod
    def indexOf(text, needle, start=0, end=None):
        source = _l.units(_l._text(text))
        return source.find(_l.units(_l._text(needle)), start, len(source) if end is None else end)

    @staticmethod
    def lastIndexOf(text, needle, start=0, last=None):
        source = _l.units(_l._text(text))
        last = len(source) - 1 if last is None else last
        return source.rfind(_l.units(_l._text(needle)), start, last + 1)

    @staticmethod
    def regionMatches(first, first_offset, second, second_offset, length):
        one, two = _l.units(_l._text(first)), _l.units(_l._text(second))
        if first_offset < 0 or second_offset < 0 or first_offset + length > len(one) or \
                second_offset + length > len(two):
            return False
        return one[first_offset:first_offset + length] == two[second_offset:second_offset + length]

    @staticmethod
    def stringOrSpannedString(text):
        if text is None:
            return None
        if isinstance(text, SpannedString) or isinstance(text, str):
            return text
        return SpannedString(text) if isinstance(text, _SpanText) else _l._text(text)

    @staticmethod
    def concat(*texts):
        if len(texts) == 1 and isinstance(texts[0], (list, tuple)):
            texts = texts[0]
        if not any(isinstance(item, _SpanText) for item in texts):
            return "".join("null" if item is None else _l._text(item) for item in texts)
        builder = SpannableStringBuilder()
        for item in texts:
            builder.append(item)
        return SpannedString(builder)

    @staticmethod
    def replace(template, sources, destinations):
        builder = SpannableStringBuilder(template)
        for source, destination in zip(sources, destinations):
            where = TextUtils.indexOf(builder, source)
            if where >= 0:
                builder.replace(where, where + _l.utf16_length(source), destination)
        return builder

    @staticmethod
    def expandTemplate(template, *values):
        if len(values) == 1 and isinstance(values[0], (list, tuple)):
            values = values[0]
        if len(values) > 9:
            raise IllegalArgumentException("max of 9 values are supported")
        builder, index = SpannableStringBuilder(template), 0
        while index < builder.length():
            if builder.charAt(index) != "^":
                index += 1
                continue
            following = builder.charAt(index + 1) if index + 1 < builder.length() else ""
            if following == "^":
                builder.delete(index + 1, index + 2)
                index += 1
            elif following and following in "123456789":
                which = int(following) - 1
                if which >= len(values):
                    raise IllegalArgumentException(f"template requests value ^{which + 1}; only {len(values)} provided")
                builder.replace(index, index + 2, values[which])
                index += _l.utf16_length(_l._text(values[which]))
            else:
                index += 1
        return builder

    @staticmethod
    def copySpansFrom(source, start, end, kind, destination, offset):
        for what in source.getSpans(start, end, kind):
            span_start, span_end = max(source.getSpanStart(what), start), min(source.getSpanEnd(what), end)
            destination.setSpan(what, span_start - start + offset, span_end - start + offset,
                                source.getSpanFlags(what))

    @staticmethod
    def ellipsize(*args):
        raise _l.unsupported("TextUtils.ellipsize needs text measurement from the host")


# --- Html ----------------------------------------------------------------------------------

_HEADINGS = (1.5, 1.4, 1.3, 1.2, 1.1, 1.0)
_BLOCK_FLAGS = {"p": 1, "div": 16, "blockquote": 32, "ul": 8, "li": 4}
_HTML_COLORS = {"darkgray": 0xFFA9A9A9, "gray": 0xFF808080, "lightgray": 0xFFD3D3D3, "darkgrey": 0xFFA9A9A9,
                "grey": 0xFF808080, "lightgrey": 0xFFD3D3D3, "green": 0xFF008000}


def _html_color(text):
    from .android_graphics import Color
    if not text:
        return None
    named = _HTML_COLORS.get(text.lower())
    if named is not None:
        return _l.i32(named)
    try:
        return Color.parseColor(text)
    except IllegalArgumentException:
        try:
            return _l.i32(_l.Integer.decode(text) | 0xFF000000) if text[:1] != "#" else None
        except _l.NumberFormatException:
            return None


def _from_html(source, flags):
    from html.parser import HTMLParser
    builder = SpannableStringBuilder()
    stack = []

    def newlines(count):
        text = builder._chars
        if not text:
            return
        existing = len(text) - len(text.rstrip("\n"))
        if existing < count:
            builder.append("\n" * (count - existing))

    def margin(tag):
        return 1 if flags & _BLOCK_FLAGS.get(tag, 2 if tag[:1] == "h" else 0) else 2

    class Parser(HTMLParser):
        def handle_starttag(self, tag, attributes):
            attributes = dict(attributes)
            if tag == "br":
                builder.append("\n")
                return
            if tag == "img":
                builder.append("\ufffc")
                return
            spans = []
            if tag in ("p", "div", "blockquote", "ul", "li") or tag in ("h1", "h2", "h3", "h4", "h5", "h6"):
                newlines(margin(tag))
            if tag in ("b", "strong"):
                spans.append(StyleSpan(1))
            elif tag in ("i", "em", "cite", "dfn"):
                spans.append(StyleSpan(2))
            elif tag == "u":
                spans.append(UnderlineSpan())
            elif tag in ("s", "strike", "del"):
                spans.append(StrikethroughSpan())
            elif tag == "big":
                spans.append(RelativeSizeSpan(1.25))
            elif tag == "small":
                spans.append(RelativeSizeSpan(0.8))
            elif tag == "sup":
                spans.append(SuperscriptSpan())
            elif tag == "sub":
                spans.append(SubscriptSpan())
            elif tag == "tt":
                spans.append(TypefaceSpan("monospace"))
            elif tag == "a":
                if attributes.get("href") is not None:
                    spans.append(URLSpan(attributes["href"]))
            elif tag == "font":
                color = _html_color(attributes.get("color"))
                if color is not None:
                    spans.append(ForegroundColorSpan(color))
                if attributes.get("face"):
                    spans.append(TypefaceSpan(attributes["face"]))
            elif tag in ("h1", "h2", "h3", "h4", "h5", "h6"):
                spans.extend((RelativeSizeSpan(_HEADINGS[int(tag[1]) - 1]), StyleSpan(1)))
            stack.append((tag, builder.length(), spans))

        def handle_endtag(self, tag):
            for index in range(len(stack) - 1, -1, -1):
                if stack[index][0] == tag:
                    _tag, start, spans = stack.pop(index)
                    if builder.length() > start:
                        for span in spans:
                            builder.setSpan(span, start, builder.length(), Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                    break
            if tag in ("p", "div", "blockquote", "ul", "li") or tag in ("h1", "h2", "h3", "h4", "h5", "h6"):
                newlines(margin(tag))

        def handle_data(self, data):
            out = []
            for char in data:
                if char in " \n\t\r":
                    previous = out[-1] if out else builder._chars[-1:] or "\n"
                    if previous not in " \n":
                        out.append(" ")
                else:
                    out.append(char)
            if out:
                builder.append("".join(out))

    parser = Parser(convert_charrefs=True)
    parser.feed(source)
    parser.close()
    return builder


class Html(Object):
    FROM_HTML_MODE_LEGACY, FROM_HTML_MODE_COMPACT = 0, 63
    FROM_HTML_SEPARATOR_LINE_BREAK_PARAGRAPH, FROM_HTML_SEPARATOR_LINE_BREAK_HEADING = 1, 2
    FROM_HTML_SEPARATOR_LINE_BREAK_LIST_ITEM, FROM_HTML_SEPARATOR_LINE_BREAK_LIST = 4, 8
    FROM_HTML_SEPARATOR_LINE_BREAK_DIV, FROM_HTML_SEPARATOR_LINE_BREAK_BLOCKQUOTE = 16, 32
    FROM_HTML_OPTION_USE_CSS_COLORS = 256
    TO_HTML_PARAGRAPH_LINES_CONSECUTIVE, TO_HTML_PARAGRAPH_LINES_INDIVIDUAL = 0, 1

    def __init__(self):
        raise _l.unsupported("android.text.Html cannot be constructed")

    @staticmethod
    def fromHtml(source, flags=0, image_getter=None, tag_handler=None):
        if image_getter is not None or tag_handler is not None:
            raise _l.unsupported("Html.fromHtml image getters and tag handlers are not supported")
        return _from_html(_l._text(source, "source"), flags)

    @staticmethod
    def escapeHtml(text):
        out, text = [], _l._text(text)
        index = 0
        while index < len(text):
            char = text[index]
            if char == "<":
                out.append("&lt;")
            elif char == ">":
                out.append("&gt;")
            elif char == "&":
                out.append("&amp;")
            elif ord(char) > 0x7E or char < " ":
                out.append("&#%d;" % ord(char))
            elif char == " ":
                while text[index + 1:index + 2] == " ":
                    out.append("&nbsp;")
                    index += 1
                out.append(" ")
            else:
                out.append(char)
            index += 1
        return "".join(out)

    @staticmethod
    def toHtml(*args):
        raise _l.unsupported("Html.toHtml is not supported")


CLASSES = _l.register({
    "android.text.Spanned": Spanned,
    "android.text.Spannable": Spannable,
    "android.text.Editable": Editable,
    "android.text.SpannedString": SpannedString,
    "android.text.SpannableString": SpannableString,
    "android.text.SpannableStringBuilder": SpannableStringBuilder,
    "android.text.TextUtils": TextUtils,
    "android.text.TextUtils$TruncateAt": _TruncateAt,
    "android.text.TextWatcher": TextWatcher,
    "android.text.InputType": InputType,
    "android.text.InputFilter": InputFilter,
    "android.text.InputFilter$LengthFilter": _LengthFilter,
    "android.text.InputFilter$AllCaps": _AllCaps,
    "android.text.Html": Html,
    "android.text.Layout": Layout,
    "android.text.Layout$Alignment": _Alignment,
    "android.text.style.CharacterStyle": CharacterStyle,
    "android.text.style.MetricAffectingSpan": MetricAffectingSpan,
    "android.text.style.UpdateAppearance": UpdateAppearance,
    "android.text.style.UpdateLayout": UpdateLayout,
    "android.text.style.ClickableSpan": ClickableSpan,
    "android.text.style.ForegroundColorSpan": ForegroundColorSpan,
    "android.text.style.BackgroundColorSpan": BackgroundColorSpan,
    "android.text.style.StyleSpan": StyleSpan,
    "android.text.style.UnderlineSpan": UnderlineSpan,
    "android.text.style.StrikethroughSpan": StrikethroughSpan,
    "android.text.style.SuperscriptSpan": SuperscriptSpan,
    "android.text.style.SubscriptSpan": SubscriptSpan,
    "android.text.style.TypefaceSpan": TypefaceSpan,
    "android.text.style.RelativeSizeSpan": RelativeSizeSpan,
    "android.text.style.ScaleXSpan": ScaleXSpan,
    "android.text.style.AbsoluteSizeSpan": AbsoluteSizeSpan,
    "android.text.style.URLSpan": URLSpan,
    "android.text.style.QuoteSpan": QuoteSpan,
})
