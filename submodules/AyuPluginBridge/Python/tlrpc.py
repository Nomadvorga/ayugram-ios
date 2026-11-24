"""Explicit TLRPC/ConnectionsManager compatibility facade.

TL constructors become plain Python structures backed by the host's typed
message DTOs; there is no TL serializer here — a plugin builds request objects
and the native host maps the supported subset onto iOS Telegram calls.
Unmapped constructors keep every attribute readable (None) so plugins can
inspect but the host refuses to send what it cannot express.
"""
from __future__ import annotations

from ayu_bridge import runtime


def _encode(value):
    if isinstance(value, _TLObject):
        return {k: _encode(v) for k, v in value.__dict__.items()}
    if isinstance(value, list):
        return [_encode(v) for v in value]
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    raise TypeError(f"TL object contains unsupported value: {type(value).__name__}")


class _TLObject:
    __slots__ = ("__dict__",)

    def __init__(self, **kwargs):
        for key, value in kwargs.items():
            setattr(self, key, value)

    def __repr__(self):
        fields = ", ".join(f"{k}={v!r}" for k, v in self.__dict__.items())
        return f"{type(self).__name__}({fields})"


def _constructor(name):
    def make(**kwargs):
        runtime.require()
        return _TLObject(**kwargs)
    make.__name__ = name
    return type(name, (), {"__init__": make, "__slots__": ()})


class _TLNamespace:
    """Lazily generates TL_xxx constructor classes; known field sets stay
    explicit so a typo surfaces at build time, not on the wire."""

    _KNOWN = {
        "TL_messageEntityTextUrl": {"offset", "length", "url"},
        "TL_messageEntityUrl": {"offset", "length"},
        "TL_messageEntityBold": {"offset", "length"},
        "TL_messageEntityItalic": {"offset", "length"},
        "TL_messageEntityCode": {"offset", "length"},
        "TL_messageEntityBlockquote": {"offset", "length"},
        "TL_peerUser": {"user_id"},
        "TL_peerChat": {"chat_id"},
        "TL_peerChannel": {"channel_id"},
        "TL_inputPeerEmpty": set(),
        "TL_inputPeerUser": {"user_id", "access_hash"},
        "TL_inputPeerChat": {"chat_id"},
        "TL_inputPeerChannel": {"channel_id", "access_hash"},
        "TL_inputStickerSetShortName": {"short_name"},
        "TL_messageMediaWebPage": {"webpage"},
        "TL_channel": {"id", "title", "access_hash"},
        "TL_chat": {"id", "title"},
        "Message": {"id", "peer_id", "message", "date", "entities", "media"},
        "Document": {"id", "mime_type", "attributes"},
        "Photo": {"id", "sizes"},
        "User": {"id", "first_name", "last_name", "username"},
        "Chat": {"id", "title", "creator", "kicked", "left"},
    }

    def __getitem__(self, name):
        if not isinstance(name, str) or not name.startswith("TL_"):
            raise KeyError(name)
        fields = self._KNOWN.get(name, set())
        namespace = type(self)

        def make(**kwargs):
            runtime.require()
            extra = set(kwargs) - fields
            if extra:
                raise TypeError(f"{name} has no fields {sorted(extra)}")
            return _TLObject(**kwargs)
        make.__name__ = name
        return type(name, (), {"__init__": make, "__slots__": (), "_ayu_fields": fields})


class TLRPC:
    TL = _TLNamespace()

    @staticmethod
    def TL_error(**kwargs):
        runtime.require()
        return _TLObject(**kwargs)


tlrpc_module = TLRPC()


class ConnectionsManager:
    @staticmethod
    def getInstance(*args):
        if args:
            raise TypeError("getInstance accepts no arguments")
        return ConnectionsManager

    @staticmethod
    def sendRequest(request, on_result=None, on_error=None, **kwargs):
        runtime.require()
        if not isinstance(request, _TLObject):
            raise TypeError("sendRequest requires a TL request object")
        if kwargs.get("flag") is not None and not isinstance(kwargs["flag"], int):
            raise TypeError("flag must be an integer request flag")
        return runtime.call("client.send_request", {"request": _encode(request)})

    @staticmethod
    def getClientTypeId():
        return runtime.call("client.type_id", {})

    @staticmethod
    def setDelegate(delegate):
        runtime.require()
        raise UnsupportedAPIError()


class UnsupportedAPIError(RuntimeError):
    pass


tlrpc = TLRPC()
