"""Legacy SDK Markdown parser; portable entities use Telegram UTF-16 ranges.

Unlike text_formatting.Markdown, this API rejects unclosed delimiters and
supports numeric custom emoji targets: ``[emoji](12345)``.
"""
from __future__ import annotations

from dataclasses import dataclass
import re

from extera_utils.text_formatting import RawEntity, TLEntityType

__all__ = ["parse_markdown"]


@dataclass
class ParsedMessage:
    text: str
    entities: tuple[RawEntity, ...]


def count_chars_until(string: str, stop_chars: str, start_index: int = 0) -> int:
    for index in range(start_index, len(string)):
        if string[index] in stop_chars:
            return index - start_index
    return len(string) - start_index


def to_utf16_len(s: str) -> int:
    return len(s.encode("utf-16-le")) // 2


def parse_markdown(markdown: str) -> ParsedMessage:
    if not isinstance(markdown, str):
        raise TypeError("parse_markdown requires a string")
    markdown = markdown.replace("\r\n", "\n").strip()
    message, entities, stack = "", [], []
    offset = 0
    markers = {"*": TLEntityType.BOLD, "_": TLEntityType.ITALIC,
               "__": TLEntityType.UNDERLINE, "~": TLEntityType.STRIKETHROUGH,
               "||": TLEntityType.SPOILER}

    def add_entity(kind, start, *, trim=True, **kwargs):
        piece = message[start:]
        if trim:
            piece = piece.rstrip(" \r\n")
        if piece:
            entities.append(RawEntity(kind, to_utf16_len(message[:start]), to_utf16_len(piece), **kwargs))

    def read_until(start, terminator):
        value = ""
        while start < len(markdown):
            if markdown[start] == terminator:
                return value, start
            if markdown[start] == "\\" and start + 1 < len(markdown):
                start += 1
            value += markdown[start]
            start += 1
        return value, start

    while offset < len(markdown):
        count = count_chars_until(markdown, "*_~`[]|!\\", offset)
        message += markdown[offset:offset + count]
        offset += count
        if offset == len(markdown):
            break
        marker = markdown[offset]
        offset += 1
        following = markdown[offset:offset + 1]
        if marker == "\\":
            message += following or "\\"
            offset += bool(following)
            continue
        if marker == "[":
            label, close = read_until(offset, "]")
            if markdown[close:close + 2] != "](":
                message += "["
                continue
            target, end = read_until(close + 2, ")")
            if end == len(markdown):
                message += "[" + label + "]("
                offset = close + 2
                continue
            start = len(message)
            message += label
            if target.isdecimal():
                add_entity(TLEntityType.CUSTOM_EMOJI, start, trim=False, document_id=int(target))
            else:
                add_entity(TLEntityType.TEXT_LINK, start, trim=False, url=target)
            offset = end + 1
            continue
        if marker == "`":
            fence_start = offset - 1
            while markdown[offset:offset + 1] == "`":
                offset += 1
            token = markdown[fence_start:offset]
            language = None
            if len(token) >= 3:
                match = re.match(r"([^\s\n]+)", markdown[offset:])
                if match:
                    language = match.group(1)
                    offset += len(language)
                if markdown[offset:offset + 1] == "\n":
                    offset += 1
            close = markdown.find(token, offset)
            if close < 0:
                raise ValueError(f"Unclosed {token} opened near offset {fence_start}!")
            start = len(message)
            message += markdown[offset:close]
            add_entity(TLEntityType.PRE if len(token) >= 3 else TLEntityType.CODE, start, language=language)
            offset = close + len(token)
            continue
        if marker in ("_", "|") and following == marker:
            marker += following
            offset += 1
        if marker not in markers or (marker == "_" and re.search(r"@\w+$", message)):
            message += marker
            continue
        if stack and stack[-1][0] == marker:
            _, start = stack.pop()
            add_entity(markers[marker], start)
        else:
            stack.append((marker, len(message)))
    if stack:
        raise ValueError("Found unclosed markdown elements")
    return ParsedMessage(message, tuple(sorted(entities, key=lambda entity: entity.offset)))
