"""Portable structured logging through the owner's declared log.write adapter."""
from __future__ import annotations

from collections import deque
from collections.abc import Mapping
from dataclasses import dataclass
from enum import Enum, IntEnum
import itertools
import sys
import time
import traceback

from ayu_bridge import BridgeError, DynamicProxy, JavaClass, RemoteObject, runtime

__all__ = ["LogLevel", "LogRecord", "Logger", "get_logger", "dump"]


class LogLevel(IntEnum):
    VERBOSE = 2
    DEBUG = 3
    INFO = 4
    WARNING = 5
    ERROR = 6
    OFF = 100


def _coerce_level(value):
    try:
        return LogLevel[value.strip().upper()] if isinstance(value, str) else LogLevel(value)
    except (KeyError, ValueError, TypeError):
        raise ValueError(f"Unknown log level: {value!r}") from None


def _split_for_logcat(text: str, limit: int) -> list[str]:
    if type(limit) is not int or limit < 4:
        raise ValueError("Log chunk limit must allow one UTF-8 code point")
    data = text.encode("utf-8", "replace")
    if len(data) <= limit:
        return [text]
    chunks = []
    while len(data) > limit:
        cut = limit
        while data[cut] & 0xC0 == 0x80:
            cut -= 1
        chunks.append(data[:cut].decode("utf-8"))
        data = data[cut:]
    if data:
        chunks.append(data.decode("utf-8"))
    return chunks


@dataclass
class LogRecord:
    level: LogLevel
    tag: str
    message: str
    location: str | None
    traceback: str | None
    created: float

    @property
    def text(self):
        text = f"[{self.location}] {self.message}" if self.location else self.message
        return text + "\n" + self.traceback if self.traceback else text


def _scalar(obj):
    if obj is None or isinstance(obj, (bool, int, float, complex, str)):
        return repr(obj)
    if isinstance(obj, (bytes, bytearray)):
        return repr(bytes(obj)) if len(obj) <= 32 else f"{type(obj).__name__}[{len(obj)}]"
    if isinstance(obj, Enum):
        return f"{type(obj).__name__}.{obj.name}"
    return None


def dump(obj, depth: int = 2, max_items: int = 20) -> str:
    """Bounded Python object inspection without private native reflection."""
    depth, max_items = max(0, int(depth)), max(0, int(max_items))
    path = set()

    def render(value, level, label=""):
        pad = "  " * level + label
        if isinstance(value, (RemoteObject, JavaClass, DynamicProxy)):
            # No hidden handle/field inspection, and no accidental host calls.
            return [pad + repr(value)]
        scalar = _scalar(value)
        if scalar is not None:
            return [pad + scalar]
        kind = "obj"
        if isinstance(value, Mapping):
            header, kind, total = f"{type(value).__name__}({len(value)})", "map", len(value)
            items = list(itertools.islice(((repr(k) + ": ", v) for k, v in value.items()), max_items))
        elif isinstance(value, (list, tuple, set, frozenset, deque)):
            header, kind, total = f"{type(value).__name__}({len(value)})", "seq", len(value)
            items = list(itertools.islice(((f"[{i}] = ", v) for i, v in enumerate(value)), max_items))
        else:
            fields = {}
            try:
                attrs = object.__getattribute__(value, "__dict__")
                if isinstance(attrs, dict):
                    fields.update(attrs)
            except (AttributeError, TypeError):
                pass
            for cls in type(value).__mro__:
                slots = cls.__dict__.get("__slots__", ())
                for name in ((slots,) if isinstance(slots, str) else slots):
                    if name not in fields and name not in ("__dict__", "__weakref__"):
                        try:
                            fields[name] = object.__getattribute__(value, name)
                        except AttributeError:
                            pass
            if not fields:
                return [pad + repr(value)[:300]]
            header, total = type(value).__name__, len(fields)
            items = list(itertools.islice(((name + " = ", v) for name, v in fields.items()), max_items))
        if id(value) in path:
            return [pad + header + " <cycle>"]
        brackets = ("[", "]") if kind == "seq" else ("{", "}")
        if level >= depth:
            return [pad + header + " " + brackets[0] + "…" + brackets[1]]
        if total == 0:
            return [pad + header + " " + "".join(brackets)]
        if kind != "obj" and len(items) == total and all(_scalar(v) is not None for _, v in items):
            inline = ", ".join((name if kind == "map" else "") + _scalar(v) for name, v in items)
            if len(inline) <= 100:
                return [pad + header + " " + brackets[0] + inline + brackets[1]]
        result = [pad + header]
        path.add(id(value))
        try:
            for name, child in items:
                result.extend(render(child, level + 1, name))
        finally:
            path.remove(id(value))
        if total > len(items):
            result.append("  " * (level + 1) + f"… {total - len(items)} more")
        return result

    return "\n".join(render(obj, 0))


class _Timer:
    def __init__(self, logger, label, level):
        self.logger, self.label, self.level = logger, label, level

    def __enter__(self):
        self.start = time.perf_counter()
        return self

    def __exit__(self, exc_type, exc, tb):
        self.logger.log(self.level, "%s took %.1f ms%s", self.label,
                        (time.perf_counter() - self.start) * 1000,
                        " (failed)" if exc_type else "")
        return False


class Logger:
    def __init__(self, tag: str, *, show_location: bool = True):
        if not isinstance(tag, str) or not tag:
            raise ValueError("tag must be a non-empty string")
        self._tag, self._parent, self._level = tag, None, None
        self._children, self._handlers = {}, []
        self._show_location = show_location
        self._dispatching = False
        self._scope = None

    @property
    def tag(self):
        return self._tag

    @property
    def level(self):
        return self._level

    @level.setter
    def level(self, value):
        self._level = None if value is None else _coerce_level(value)

    @property
    def effective_level(self):
        return self._level if self._level is not None else self._parent.effective_level if self._parent else LogLevel.INFO

    def is_enabled_for(self, level):
        return LogLevel.OFF > _coerce_level(level) >= self.effective_level

    def child(self, name):
        logger = self
        for part in str(name).split("."):
            if part:
                if part not in logger._children:
                    child = Logger(logger.tag + "." + part, show_location=logger._show_location)
                    child._parent, child._scope = logger, logger._scope
                    logger._children[part] = child
                logger = logger._children[part]
        return logger

    def add_handler(self, handler):
        if not callable(handler):
            raise TypeError("handler must be callable")
        if handler not in self._handlers:
            self._handlers.append(handler)

    def remove_handler(self, handler):
        if handler not in self._handlers:
            return False
        self._handlers.remove(handler)
        return True

    def log(self, level, msg, *args, exc_info=None, stacklevel=1):
        level = _coerce_level(level)
        if not self.is_enabled_for(level):
            return
        if self._scope is None:
            self._scope = runtime.require()
        else:
            runtime.require(self._scope)
        message = str(msg)
        if args:
            values = args[0] if len(args) == 1 and isinstance(args[0], Mapping) and args[0] else args
            try:
                message %= values
            except (TypeError, ValueError, KeyError) as error:
                message += f" {values!r} (formatting failed: {type(error).__name__}: {error})"
        tb = None
        if exc_info:
            info = (type(exc_info), exc_info, exc_info.__traceback__) if isinstance(exc_info, BaseException) else exc_info if isinstance(exc_info, tuple) else sys.exc_info()
            if len(info) == 3 and info[0] is not None:
                tb = "".join(traceback.format_exception(*info)).rstrip()
        location = None
        if self._show_location:
            frame = sys._getframe(1)
            try:
                while frame and frame.f_globals.get("__name__") == __name__:
                    frame = frame.f_back
                for _ in range(max(0, int(stacklevel) - 1)):
                    frame = frame.f_back if frame else None
                if frame:
                    from os.path import basename
                    location = f"{basename(frame.f_code.co_filename)}:{frame.f_code.co_name}:{frame.f_lineno}"
            finally:
                del frame
        record = LogRecord(level, self.tag, message, location, tb, time.time())
        for chunk in _split_for_logcat(f"[{self.tag}] {record.text}", 4000):
            runtime.call("log.write", {"level": "debug" if level == LogLevel.VERBOSE else level.name.lower(), "message": chunk})
        chain, logger = [], self
        while logger:
            chain.append(logger)
            logger = logger._parent
        if any(logger._dispatching for logger in chain):
            return
        for logger in chain:
            logger._dispatching = True
        try:
            for logger in chain:
                for handler in tuple(logger._handlers):
                    try:
                        handler(record)
                    except BridgeError:
                        raise
                    except Exception:
                        runtime.call("log.write", {"level": "error", "message": "Plugin log handler failed"})
        finally:
            for logger in chain:
                logger._dispatching = False

    def verbose(self, msg, *args, exc_info=None, stacklevel=1):
        return self.log(LogLevel.VERBOSE, msg, *args, exc_info=exc_info, stacklevel=stacklevel)

    def debug(self, msg, *args, exc_info=None, stacklevel=1):
        return self.log(LogLevel.DEBUG, msg, *args, exc_info=exc_info, stacklevel=stacklevel)

    def info(self, msg, *args, exc_info=None, stacklevel=1):
        return self.log(LogLevel.INFO, msg, *args, exc_info=exc_info, stacklevel=stacklevel)

    def warning(self, msg, *args, exc_info=None, stacklevel=1):
        return self.log(LogLevel.WARNING, msg, *args, exc_info=exc_info, stacklevel=stacklevel)

    def error(self, msg, *args, exc_info=None, stacklevel=1):
        return self.log(LogLevel.ERROR, msg, *args, exc_info=exc_info, stacklevel=stacklevel)

    def exception(self, msg, *args, stacklevel=1):
        return self.log(LogLevel.ERROR, msg, *args, exc_info=True, stacklevel=stacklevel)

    def dump(self, obj, label=None, *, level=LogLevel.DEBUG, depth=2, max_items=20, stacklevel=1):
        if self.is_enabled_for(level):
            text = dump(obj, depth=depth, max_items=max_items)
            self.log(level, text if label is None else f"{label}: {text}", stacklevel=stacklevel)

    def timed(self, label, level=LogLevel.DEBUG):
        return _Timer(self, label, _coerce_level(level))


def get_logger(name=None):
    scope = runtime.require()
    logger = getattr(scope, "_ayu_sdk_logger", None)
    if logger is None:
        logger = Logger(f"plugin.{scope.plugin_id}")
        logger._scope = scope
        scope._ayu_sdk_logger = logger
    if name:
        for prefix in (f"ElyxPlugins.{scope.plugin_id}", scope.plugin_id):
            if name == prefix:
                name = ""
                break
            if name.startswith(prefix + "."):
                name = name[len(prefix) + 1:]
                break
    return logger.child(name) if name else logger
