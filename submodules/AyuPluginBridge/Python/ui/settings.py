"""Android settings rows.

The row classes are the Android SDK's dataclasses: construction validates
nothing, attributes are mutable, ``type`` holds the Android row type. The wire
descriptor is built the way the Kotlin host reads a row (``toString`` on texts,
truthiness for a switch default, incomplete rows dropped) and then mapped to
the native renderer's row types.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Callable, List

from ayu_bridge import RemoteObject, UnsupportedAPI, WireTarget, runtime

TYPE_SWITCH = "switch"
TYPE_INPUT = "input"
TYPE_SELECTOR = "selector"
TYPE_HEADER = "header"
TYPE_DIVIDER = "divider"
TYPE_TEXT = "text"
TYPE_EDIT_TEXT = "edit_text"
TYPE_CUSTOM = "custom"
MAX_KEY_BYTES = 256
MAX_ROWS = 256
# Sub-fragment pages whose row callbacks stay registered; older pages expire.
MAX_OPEN_PAGES = 8
# Android's default EditText length limit, the only one the native input row is sent.
_EDIT_TEXT_MAX_LENGTH = 256
_CALLBACKS = ("on_click", "on_change", "on_long_click", "create_sub_fragment")


class _Row:
    """Serialization shared by the row dataclasses; rows stay bound to their plugin."""

    def __post_init__(self):
        self._ayu_scope = runtime.require()

    def to_bridge(self):
        runtime.require(getattr(self, "_ayu_scope", None))
        descriptor = _descriptor(self)
        if descriptor is None:
            raise TypeError(f"{type(self).__name__} setting is incomplete and would be dropped by Android")
        return descriptor


@dataclass
class Switch(_Row):
    key: str
    text: str
    default: bool
    subtext: str = None
    icon: str = None
    on_change: Callable[[bool], None] = field(default=None, compare=False, repr=False)
    type: str = field(default=TYPE_SWITCH, init=False)
    on_long_click: Callable[[Any], None] = field(default=None, compare=False, repr=False)
    link_alias: str = None


@dataclass
class Selector(_Row):
    key: str
    text: str
    default: int
    items: List[str]
    icon: str = None
    on_change: Callable[[int], None] = field(default=None, compare=False, repr=False)
    type: str = field(default=TYPE_SELECTOR, init=False)
    on_long_click: Callable[[Any], None] = field(default=None, compare=False, repr=False)
    link_alias: str = None


@dataclass
class Input(_Row):
    key: str
    text: str
    default: str = ""
    subtext: str = None
    icon: str = None
    on_change: Callable[[str], None] = field(default=None, compare=False, repr=False)
    type: str = field(default=TYPE_INPUT, init=False)
    on_long_click: Callable[[Any], None] = field(default=None, compare=False, repr=False)
    link_alias: str = None


@dataclass
class Text(_Row):
    text: str
    subtext: str = None
    icon: str = None
    accent: bool = False
    red: bool = False
    on_click: Callable[[Any], None] = field(default=None, compare=False, repr=False)
    create_sub_fragment: Callable[[], List[Any]] = field(default=None, compare=False, repr=False)
    type: str = field(default=TYPE_TEXT, init=False)
    on_long_click: Callable[[Any], None] = field(default=None, compare=False, repr=False)
    link_alias: str = None


@dataclass
class Header(_Row):
    text: str
    type: str = field(default=TYPE_HEADER, init=False)


@dataclass
class Divider(_Row):
    text: str = None
    type: str = field(default=TYPE_DIVIDER, init=False)


@dataclass
class EditText(_Row):
    key: str
    hint: str
    default: str = ""
    multiline: bool = False
    max_length: int = 256
    mask: str = None
    on_change: Callable[[str], None] = field(default=None, compare=False, repr=False)
    type: str = field(default=TYPE_EDIT_TEXT, init=False)


@dataclass
class Custom(_Row):
    type: str = field(default=TYPE_CUSTOM, init=False)
    item: Any = field(default=None, compare=False, repr=False)
    view: Any = field(default=None, compare=False, repr=False)
    factory: Any = field(default=None, compare=False, repr=False)
    factory_args: Any = field(default=None, compare=False, repr=False)
    on_click: Callable[[Any], None] = field(default=None, compare=False, repr=False)
    on_long_click: Callable[[Any], None] = field(default=None, compare=False, repr=False)
    create_sub_fragment: Callable[[], List[Any]] = field(default=None, compare=False, repr=False)
    link_alias: str = None

    def __post_init__(self):
        super().__post_init__()
        if self.item is None and self.view is None and self.factory is None:
            raise ValueError("Either item or view or factory must be provided")
        # The settings screen has no adapter that hosts an Android UItem, View
        # or CustomSetting.Factory inside a row.
        raise UnsupportedAPI("Custom Android settings require a native view adapter")


class SimpleSettingFactory:
    def __init__(self, create_view, bind_view, *, is_clickable=False, is_shadow=False,
                 create_item=None, on_click=None, on_long_click=None,
                 attached_view=None, equals=None, content_equals=None):
        runtime.require()
        raise UnsupportedAPI("Android setting factories require a native view adapter")


def _text(value):
    """Kotlin reads row texts with ``toString``; a missing attribute stays absent."""
    if value is None:
        return None
    if isinstance(value, RemoteObject):
        raise UnsupportedAPI("A native object cannot be used as setting text")
    return str(value)


def _flag(value):
    try:
        return bool(value)
    except Exception:
        return False


def _key(value):
    key = _text(value)
    if key is not None and (not key or len(key.encode("utf-8")) > MAX_KEY_BYTES):
        raise ValueError("A setting key must be nonempty and at most 256 UTF-8 bytes")
    return key


def _sub_fragment(function):
    """Serialize a sub-fragment's rows, keeping only the newest pages' callbacks alive."""
    def rows():
        scope = runtime.require()
        pages = scope.__dict__.setdefault("_ayu_settings_pages", [])
        before = set(scope.callbacks)
        try:
            wire = runtime.encode(android_rows(function()))
        except Exception:
            for callback_id in set(scope.callbacks) - before:
                scope.callbacks.pop(callback_id, None)
            raise
        pages.append(set(scope.callbacks) - before)
        while len(pages) > MAX_OPEN_PAGES:
            for callback_id in pages.pop(0):
                scope.callbacks.pop(callback_id, None)
        return WireTarget(wire)
    return rows


def _descriptor(row):
    """The native row descriptor of one Android row object, or None when Android drops it."""
    def get(name, default=None):
        return getattr(row, name, default)

    kind = _text(get("type"))
    if kind is None:
        return None
    for name in _CALLBACKS:
        if get(name) is not None and not callable(get(name)):
            raise TypeError(f"{name} must be callable")
    key, text = _key(get("key")), _text(get("text"))
    default = get("default")
    result = None
    if kind == TYPE_HEADER:
        if text is not None:
            result = {"type": "Header", "text": text}
    elif kind == TYPE_DIVIDER:
        result = {"type": "Divider", "text": text}
    elif kind == TYPE_SWITCH:
        if key is not None and text is not None and default is not None:
            result = {"type": "Switch", "key": key, "text": text, "default": _flag(default),
                      "subtext": _text(get("subtext")), "on_change": get("on_change")}
    elif kind == TYPE_SELECTOR:
        items = get("items")
        if (key is not None and text is not None and default is not None
                and isinstance(items, (list, tuple)) and items and all(isinstance(item, str) for item in items)):
            result = {"type": "Selector", "key": key, "text": text, "default": int(default),
                      "items": list(items), "on_change": get("on_change")}
    elif kind == TYPE_INPUT:
        if key is not None and text is not None:
            result = {"type": "Input", "key": key, "text": text, "default": "" if default is None else str(default),
                      "subtext": _text(get("subtext")), "on_change": get("on_change")}
    elif kind == TYPE_EDIT_TEXT:
        hint = _text(get("hint"))
        if key is not None and hint is not None:
            # Rendered by the native text-input row; it reports a multiline editor as unsupported.
            # That row applies no input mask and no length limit of the plugin's choosing, and
            # accepting them would store text Android refuses.
            max_length = get("max_length", _EDIT_TEXT_MAX_LENGTH)
            if get("mask") is not None or type(max_length) is not int or max_length != _EDIT_TEXT_MAX_LENGTH:
                raise UnsupportedAPI("EditText mask and max_length require a native text-field adapter")
            result = {"type": "Input", "key": key, "text": hint, "hint": hint,
                      "default": "" if default is None else str(default),
                      "multiline": _flag(get("multiline", False)), "max_length": max_length,
                      "on_change": get("on_change")}
    elif kind == TYPE_TEXT:
        if text is not None:
            result = {"type": "Text", "text": text, "subtext": _text(get("subtext")),
                      "accent": _flag(get("accent", False)), "destructive": _flag(get("red", False)),
                      "on_click": get("on_click")}
            if get("create_sub_fragment") is not None:
                result["create_sub_fragment"] = _sub_fragment(get("create_sub_fragment"))
    elif kind == TYPE_CUSTOM:
        raise UnsupportedAPI("Custom Android settings require a native view adapter")
    if result is None:
        return None
    if kind not in (TYPE_HEADER, TYPE_DIVIDER, TYPE_EDIT_TEXT):
        result["icon"] = _text(get("icon"))
        result["on_long_click"] = get("on_long_click")
        result["link_alias"] = _text(get("link_alias"))
    return {name: value for name, value in result.items() if value is not None}


class _Descriptor:
    """A row already reduced to its native descriptor."""

    def __init__(self, scope, descriptor):
        self._scope, self._descriptor = scope, descriptor

    def to_bridge(self):
        runtime.require(self._scope)
        return self._descriptor


def android_rows(rows):
    """Rows of ``create_settings`` or a sub-fragment as Android's host reads them.

    ``None`` and an empty sequence mean no settings; a row Android would drop
    (no ``type``, or a required field missing) is dropped here too. Any object
    with the row attributes is accepted, as the Kotlin host reads attributes.
    """
    scope = runtime.require()
    if rows is None:
        return []
    if isinstance(rows, (str, bytes, dict)) or not hasattr(rows, "__iter__"):
        raise TypeError("Settings must be a list of setting rows")
    result = []
    for row in rows:
        owner = getattr(row, "_ayu_scope", scope)
        runtime.require(owner)
        descriptor = _descriptor(row)
        if descriptor is not None:
            if len(result) >= MAX_ROWS:
                raise ValueError("A settings page holds at most 256 rows")
            result.append(_Descriptor(scope, descriptor))
    return result
