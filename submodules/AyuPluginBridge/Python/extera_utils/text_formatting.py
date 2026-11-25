"""Portable Telegram HTML/Markdown formatting with UTF-16 entity offsets.

The public shapes follow exteraGram's SDK. Parsing returns Python RawEntity
values; conversion to TLRPC requires real, explicitly declared native classes.
"""
from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
import html
from html.parser import HTMLParser
import re


def add_surrogates(text: str) -> str:
    return "".join(
        c if ord(c) <= 0xFFFF else chr(0xD800 + ((ord(c) - 0x10000) >> 10)) + chr(0xDC00 + ((ord(c) - 0x10000) & 1023))
        for c in text)


def remove_surrogates(text: str) -> str:
    return text.encode("utf-16-le", "surrogatepass").decode("utf-16-le")


class TLEntityType(Enum):
    CODE = "code"
    PRE = "pre"
    STRIKETHROUGH = "strikethrough"
    TEXT_LINK = "text_link"
    BOLD = "bold"
    ITALIC = "italic"
    UNDERLINE = "underline"
    SPOILER = "spoiler"
    CUSTOM_EMOJI = "custom_emoji"
    BLOCKQUOTE = "blockquote"

    @classmethod
    def from_(cls, entity):
        if isinstance(entity, RawEntity):
            return entity.type
        from ayu_bridge import RemoteObject, runtime
        if isinstance(entity, RemoteObject):
            runtime.require(entity._scope)
            return next((kind for kind, name in _ENTITY_CLASSES.items()
                         if entity._class_name == "org.telegram.tgnet.TLRPC$" + name), None)
        return None


_ENTITY_CLASSES = {
    TLEntityType.CODE: "TL_messageEntityCode",
    TLEntityType.PRE: "TL_messageEntityPre",
    TLEntityType.STRIKETHROUGH: "TL_messageEntityStrike",
    TLEntityType.TEXT_LINK: "TL_messageEntityTextUrl",
    TLEntityType.BOLD: "TL_messageEntityBold",
    TLEntityType.ITALIC: "TL_messageEntityItalic",
    TLEntityType.UNDERLINE: "TL_messageEntityUnderline",
    TLEntityType.SPOILER: "TL_messageEntitySpoiler",
    TLEntityType.CUSTOM_EMOJI: "TL_messageEntityCustomEmoji",
    TLEntityType.BLOCKQUOTE: "TL_messageEntityBlockquote",
}


@dataclass
class RawEntity:
    type: TLEntityType
    offset: int
    length: int
    language: str | None = None
    url: str | None = None
    document_id: int | None = None
    collapsed: bool | None = None

    @property
    def TLRPC_ENTITIES_MAP(self):
        from java import jclass
        return {kind: jclass("org.telegram.tgnet.TLRPC$" + name)
                for kind, name in _ENTITY_CLASSES.items()}

    def to_tlrpc_object(self):
        from java import jclass
        # Resolve just the requested class, never require every entity adapter.
        entity = jclass("org.telegram.tgnet.TLRPC$" + _ENTITY_CLASSES[self.type])()
        entity.offset, entity.length = self.offset, self.length
        for kind, field in ((TLEntityType.PRE, "language"), (TLEntityType.TEXT_LINK, "url"),
                            (TLEntityType.CUSTOM_EMOJI, "document_id"), (TLEntityType.BLOCKQUOTE, "collapsed")):
            value = getattr(self, field)
            if self.type == kind and value is not None:
                setattr(entity, field, value)
        return entity


_HTML_TYPES = {"b": TLEntityType.BOLD, "strong": TLEntityType.BOLD,
               "i": TLEntityType.ITALIC, "em": TLEntityType.ITALIC,
               "u": TLEntityType.UNDERLINE, "s": TLEntityType.STRIKETHROUGH,
               "del": TLEntityType.STRIKETHROUGH, "strike": TLEntityType.STRIKETHROUGH,
               "code": TLEntityType.CODE, "pre": TLEntityType.PRE,
               "spoiler": TLEntityType.SPOILER, "tg-spoiler": TLEntityType.SPOILER,
               "blockquote": TLEntityType.BLOCKQUOTE, "a": TLEntityType.TEXT_LINK,
               "emoji": TLEntityType.CUSTOM_EMOJI}


class Parser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.text = ""
        self.entities = []
        self.tag_entities = {}

    def handle_starttag(self, tag, attrs):
        kind = _HTML_TYPES.get(tag)
        if kind is None:
            return
        attrs, extra = dict(attrs), {}
        if kind == TLEntityType.PRE:
            extra["language"] = attrs.get("language", attrs.get("lang", ""))
        elif kind == TLEntityType.TEXT_LINK:
            extra["url"] = attrs.get("href", "")
        elif kind == TLEntityType.BLOCKQUOTE:
            extra["collapsed"] = "expandable" in attrs or "collapsed" in attrs
        elif kind == TLEntityType.CUSTOM_EMOJI:
            value = attrs.get("id", attrs.get("document_id", "0"))
            if not value or not value.isdecimal():
                return
            extra["document_id"] = int(value)
        self.tag_entities.setdefault(tag, []).append(RawEntity(kind, len(self.text), 0, **extra))

    def handle_data(self, data):
        data = add_surrogates(data)
        for entries in self.tag_entities.values():
            for entity in entries:
                entity.length += len(data)
        self.text += data

    def handle_endtag(self, tag):
        entries = self.tag_entities.get(tag)
        if entries:
            self.entities.append(entries.pop())
            if not entries:
                del self.tag_entities[tag]


def _entity_tags(entity, mode):
    kind = TLEntityType.from_(entity)
    if kind is None:
        return None
    if mode == "html":
        if kind == TLEntityType.TEXT_LINK:
            return '<a href="' + html.escape(entity.url or "", quote=True) + '">', "</a>"
        if kind == TLEntityType.CUSTOM_EMOJI:
            return f'<emoji id="{int(entity.document_id)}">', "</emoji>"
        if kind == TLEntityType.PRE:
            language = getattr(entity, "language", "") or ""
            return (f'<pre language="{html.escape(language, quote=True)}">' if language else "<pre>"), "</pre>"
        if kind == TLEntityType.BLOCKQUOTE:
            collapsed = getattr(entity, "collapsed", False)
            return ("<blockquote expandable>" if collapsed else "<blockquote>"), "</blockquote>"
        tag = {TLEntityType.BOLD: "b", TLEntityType.ITALIC: "i", TLEntityType.UNDERLINE: "u",
               TLEntityType.STRIKETHROUGH: "s"}.get(kind, kind.value)
        return f"<{tag}>", f"</{tag}>"
    if kind == TLEntityType.TEXT_LINK:
        return "[", f"]({entity.url})"
    if kind == TLEntityType.CUSTOM_EMOJI:
        return "![", f"](tg://emoji?id={entity.document_id})"
    if kind == TLEntityType.PRE:
        return f"```{getattr(entity, 'language', '') or ''}\n", "\n```"
    delim = {TLEntityType.BOLD: "*", TLEntityType.ITALIC: "_", TLEntityType.UNDERLINE: "__",
             TLEntityType.STRIKETHROUGH: "~", TLEntityType.SPOILER: "||", TLEntityType.CODE: "`"}.get(kind)
    return (delim, delim) if delim else ("> ", "")


def _unparse(text, entities, mode):
    text = add_surrogates(text)
    entries = []
    for entity in entities:
        tags = _entity_tags(entity, mode)
        if tags is None:
            continue
        start, end = entity.offset, entity.offset + entity.length
        if type(start) is not int or type(entity.length) is not int or start < 0 or end > len(text) or end < start:
            raise ValueError("Entity range is outside the UTF-16 text")
        # A range splitting a surrogate pair cannot represent a Telegram entity.
        for boundary in (start, end):
            if 0 < boundary < len(text) and 0xD800 <= ord(text[boundary - 1]) <= 0xDBFF and 0xDC00 <= ord(text[boundary]) <= 0xDFFF:
                raise ValueError("Entity range splits a UTF-16 surrogate pair")
        if end > start:
            entries.append((start, end, tags, entity))
    entries.sort(key=lambda entry: (entry[0], -entry[1]))
    # Crossing ranges cannot be emitted as nested HTML/Markdown.
    stack = []
    for start, end, _, _ in entries:
        while stack and start >= stack[-1]:
            stack.pop()
        if stack and end > stack[-1]:
            raise ValueError("Formatting entity ranges cross")
        stack.append(end)
    opens, closes = {}, {}
    for index, (start, end, tags, entity) in enumerate(entries):
        opens.setdefault(start, []).append((index, tags[0]))
        closes.setdefault(end, []).append((index, tags[1]))
        if mode == "markdown" and TLEntityType.from_(entity) == TLEntityType.BLOCKQUOTE:
            for pos in range(start, end - 1):
                if text[pos] == "\n":
                    opens.setdefault(pos + 1, []).append((index, "> "))
    result = []
    for offset in range(len(text) + 1):
        result.extend(tag for _, tag in sorted(closes.get(offset, ()), reverse=True))
        result.extend(tag for _, tag in sorted(opens.get(offset, ())))
        if offset < len(text):
            result.append(html.escape(text[offset], quote=False) if mode == "html" else text[offset])
    return remove_surrogates("".join(result))


class HTML:
    @staticmethod
    def parse(text: str) -> dict:
        if not isinstance(text, str):
            raise TypeError("HTML.parse requires a string")
        # Android's helper trims whitespace outside an outer formatting tag.
        text = re.sub(r'^\s*(<[\w<>=\s"]*>)\s*', r"\1", text)
        text = re.sub(r"\s*(</[\w</>]*>)\s*$", r"\1", text)
        parser = Parser()
        parser.feed(text)
        parser.close()
        return {"message": remove_surrogates(parser.text),
                "entities": sorted((e for e in parser.entities if e.length > 0), key=lambda e: e.offset)}

    @staticmethod
    def unparse(text: str, entities: list) -> str:
        return _unparse(text, entities, "html")


BOLD_DELIM, ITALIC_DELIM, UNDERLINE_DELIM = "*", "_", "__"
STRIKE_DELIM, SPOILER_DELIM, CODE_DELIM, PRE_DELIM = "~", "||", "`", "```"
BLOCKQUOTE_DELIM, BLOCKQUOTE_EXPANDABLE_DELIM, BLOCKQUOTE_EXPANDABLE_END_DELIM = ">", "**>", "||"
MARKDOWN_ESCAPABLE_CHARS = "\\_*[]()~`|>!"
ESCAPED_MARKDOWN_RE = re.compile(r"\\([" + re.escape(MARKDOWN_ESCAPABLE_CHARS) + r"])")
MARKDOWN_RE = re.compile(r"(```|`|__|\|\||\*|_|~)|(!?)\[(.+?)]\((.+?)\)")
FIXED_WIDTH_DELIMS = [CODE_DELIM, PRE_DELIM]


def replace_once(source: str, old: str, new: str, start: int):
    return source[:start] + source[start:].replace(old, new, 1)


class Markdown:
    @staticmethod
    def protect_escaped_chars(text):
        escaped = {}

        def replace(match):
            placeholder = f"\uE000{len(escaped)}\uE001"
            while placeholder in text or placeholder in escaped:
                placeholder += "\uE002"
            escaped[placeholder] = match.group(1)
            return placeholder

        return ESCAPED_MARKDOWN_RE.sub(replace, text), escaped

    @staticmethod
    def restore_escaped_chars(text, escaped_chars):
        for placeholder, value in escaped_chars.items():
            text = text.replace(placeholder, value)
        return text

    @staticmethod
    def escape_and_create_quotes(text, strict):
        result, quote = [], []
        expandable = False

        def flush():
            if quote:
                result.append(("<blockquote expandable>" if expandable else "<blockquote>") + "\n".join(quote) + "</blockquote>")
                quote.clear()

        for line in text.splitlines():
            if line.startswith("**>"):
                flush()
                expandable = True
                line = line[3:].removeprefix(" ")
            elif line.startswith(">"):
                line = line[1:].removeprefix(" ")
            elif not expandable:
                flush()
                result.append(html.escape(line) if strict else line)
                continue
            finish = expandable and line.endswith("||")
            if finish:
                line = line[:-2]
            quote.append(html.escape(line) if strict else line)
            if finish:
                flush()
                expandable = False
        flush()
        return "\n".join(result)

    @classmethod
    def parse(cls, text: str, strict: bool = False):
        if not isinstance(text, str):
            raise TypeError("Markdown.parse requires a string")
        text, escaped = cls.protect_escaped_chars(text)
        # Quote recognition must precede HTML escaping. Code is escaped below.
        text = cls.escape_and_create_quotes(text, strict=False)
        output, active, offset = [], set(), 0
        tags = {"*": "b", "_": "i", "__": "u", "~": "s", "||": "spoiler"}
        while offset < len(text):
            if text.startswith("```", offset) or text[offset] == "`":
                delim = "```" if text.startswith("```", offset) else "`"
                start = offset + len(delim)
                close = text.find(delim, start)
                if close == -1:
                    output.append(html.escape(text[offset:]) if strict else text[offset:])
                    break
                piece = text[start:close]
                if delim == "```":
                    language, separator, content = piece.partition("\n")
                    output.append('<pre language="' + html.escape(language, quote=True) + '">' + html.escape((separator + content) if separator else "") + "</pre>")
                else:
                    output.append("<code>" + html.escape(piece) + "</code>")
                offset = close + len(delim)
                continue
            match = MARKDOWN_RE.match(text, offset)
            if match:
                delim, emoji, label, url = match.groups()
                if label is not None:
                    if emoji:
                        emoji_id = url.removeprefix("tg://emoji?id=")
                        output.append('<emoji id="' + html.escape(emoji_id, quote=True) + '">' + html.escape(label) + "</emoji>")
                    else:
                        output.append('<a href="' + html.escape(url, quote=True) + '">' + html.escape(label) + "</a>")
                else:
                    output.append(f"</{tags[delim]}>" if delim in active else f"<{tags[delim]}>")
                    active.symmetric_difference_update((delim,))
                offset = match.end()
                continue
            # Existing HTML is accepted by the non-strict Android parser.
            # The quote tags above must survive strict escaping as well.
            if text[offset] == "<":
                tag = re.match(r"</?blockquote(?: expandable)?>", text[offset:])
                if tag:
                    output.append(tag.group())
                    offset += len(tag.group())
                    continue
            output.append(html.escape(text[offset]) if strict else text[offset])
            offset += 1
        rendered = "".join(output)
        for placeholder, value in escaped.items():
            rendered = rendered.replace(placeholder, html.escape(value))
        return HTML.parse(rendered)

    @staticmethod
    def unparse(text: str, entities: list):
        return _unparse(text, entities, "markdown")


def parse_text(text: str, parse_mode: str | None = "HTML", is_caption: bool = False) -> dict:
    key = "caption" if is_caption else "message"
    if not isinstance(text, str):
        raise TypeError("parse_text requires a string")
    if not parse_mode:
        return {key: text, "entities": []}
    result = (Markdown if parse_mode.lower() == "markdown" else HTML).parse(text)
    return {key: result["message"], "entities": [entity.to_tlrpc_object() for entity in result["entities"]]}


def bind_task(function, **kwargs):
    """Compatibility alias for the lifecycle binder (does not schedule work)."""
    from extera_utils.lifecycle import bind_task as bind
    return bind(function, **kwargs)
