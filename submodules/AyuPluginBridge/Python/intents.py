"""Portable Android SDK URI parsing; OS intent interception is unsupported."""
from dataclasses import dataclass
from typing import Callable

from ayu_bridge import UnsupportedAPI


class IntentsManager:
    @dataclass
    class HandlerInfo:
        callback: Callable
        scheme: str | None = None
        host: str | None = None
        path: str | None = None
        required_path_args_names: list[str] | None = None
        priority: int | None = 0
        action: str | None = None
        whitelist_flags: list[int] | None = None
        blacklist_flags: list[int] | None = None
        type: str | None = None
        categories: list[str] | None = None

    @dataclass
    class HandlerHandle:
        handler_id: str

        def unhandle(self):
            return IntentsManager.unhandle(self.handler_id)

    class HandlerNotRegistered(Exception):
        def __init__(self, handler_id):
            super().__init__(f"Handler '{handler_id}' is not registered.")

    @staticmethod
    def parse(url: str) -> dict[str, str]:
        """Match the SDK's split-based parser, including its raw query/path values."""
        if not isinstance(url, str):
            raise TypeError("url must be a string")
        if "://" not in url:
            raise ValueError("Invalid uri")
        scheme, rest = url.split("://", 1)
        host, separator, path = rest.partition("/")
        result = {"scheme": scheme, "host": host}
        if separator:
            result["path"] = path
        if "?" in rest:
            result["query"] = rest.split("?", 1)[1]
        return result

    @staticmethod
    def new_global_before_handler(info):
        raise UnsupportedAPI("Android intent interception is unavailable on iOS")

    @staticmethod
    def new_global_after_handler(info):
        raise UnsupportedAPI("Android intent interception is unavailable on iOS")

    @staticmethod
    def unhandle(handler_id):
        raise UnsupportedAPI("Android intent interception is unavailable on iOS")
