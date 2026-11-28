"""Android classes and members composed over what the host or the application container provides.

A class names the operation it needs in ``__ayu_requires__``; a host that does not declare it
leaves the class a preflight ``CLASS`` blocker. ``HOST_MEMBERS`` holds the members of the host's
``Context`` and ``Uri`` this module serves: storage directories, the emulated package name, the
class loader, ``SharedPreferences`` (files of the calling plugin) and ``Uri.fromFile``.
"""
from __future__ import annotations

import json
import os
import threading
import traceback
import urllib.parse
import weakref

from . import returns, with_receiver
from . import java_lang as _l
from .java_io import File
from .java_lang import ClassCastException, IllegalArgumentException, NullPointerException, Object

_MAX_RECORD_BYTES = 4000


def _chunks(text):
    """Split a log line so every record fits the host's 4096-byte limit."""
    data = text.encode("utf-8", "replace")
    start = 0
    while start < len(data) or start == 0:
        end = min(start + _MAX_RECORD_BYTES, len(data))
        while end < len(data) and data[end] & 0xC0 == 0x80:
            end -= 1
        yield data[start:end].decode("utf-8", "replace")
        start = end
        if start >= len(data):
            break


class Log(Object):
    """``android.util.Log`` written to the host log; there is no logcat to read back."""
    __ayu_requires__ = ("log.write",)
    VERBOSE, DEBUG, INFO, WARN, ERROR, ASSERT = 2, 3, 4, 5, 6, 7
    _LEVELS = {2: "debug", 3: "debug", 4: "info", 5: "warning", 6: "error", 7: "critical"}

    def __init__(self):
        raise _l.unsupported("android.util.Log cannot be constructed")

    @staticmethod
    def getStackTraceString(throwable):
        if throwable is None:
            return ""
        if not isinstance(throwable, BaseException):
            raise TypeError("Expected a throwable")
        return "".join(traceback.format_exception(type(throwable), throwable, throwable.__traceback__))

    @staticmethod
    def isLoggable(tag, level):
        return level >= Log.INFO

    @staticmethod
    def println(priority, tag, message):
        if message is None:
            raise NullPointerException("println needs a message")
        level = Log._LEVELS.get(priority)
        if level is None:
            raise _l.IllegalArgumentException(f"Invalid log priority: {priority}")
        from ayu_bridge import runtime
        text = ("" if tag is None else _l.jstr(tag) + ": ") + _l.jstr(message)
        written = 0
        for chunk in _chunks(text):
            runtime.call("log.write", {"level": level, "message": chunk})
            written += len(chunk.encode("utf-8"))
        return written

    @staticmethod
    def _log(priority, args):
        if len(args) == 2 and isinstance(args[1], BaseException):
            tag, message, throwable = args[0], "", args[1]
        elif len(args) == 2:
            tag, message, throwable = args[0], args[1], None
        elif len(args) == 3:
            tag, message, throwable = args
        else:
            raise TypeError("takes (tag, message) or (tag, message, throwable)")
        if throwable is not None:
            message = _l.jstr(message) + "\n" + Log.getStackTraceString(throwable)
        return Log.println(priority, tag, message)


for _name, _priority in (("v", 2), ("d", 3), ("i", 4), ("w", 5), ("e", 6), ("wtf", 7)):
    setattr(Log, _name, staticmethod(lambda *args, _priority=_priority: Log._log(_priority, args)))


class ClipboardManager(Object):
    """Plain-text clipboard writes through the host's ``copy_to_clipboard`` client call.

    The host offers no way to read the clipboard or to observe it, so reads and
    listeners are unsupported. The instance comes from ``Context.getSystemService``, which this
    module serves on the host's ``Context`` (``HOST_MEMBERS``) through ``ClipboardManager._instance()``.
    """
    __ayu_requires__ = ("client.call",)

    def __init__(self):
        raise _l.unsupported("Use Context.getSystemService(Context.CLIPBOARD_SERVICE)")

    @staticmethod
    def _instance():
        from ayu_bridge import runtime
        runtime.require()
        return object.__new__(ClipboardManager)

    def setPrimaryClip(self, clip):
        if clip is None:
            raise NullPointerException("clip is null")
        from .android_content import ClipData
        if not isinstance(clip, ClipData):
            raise TypeError("Expected a Python-local ClipData")
        if clip.getItemCount() != 1 or clip.getItemAt(0).getText() is None:
            raise _l.unsupported("Only a single plain-text clip can be written to the clipboard")
        self.setText(clip.getItemAt(0).getText())

    def setText(self, text):
        from android_utils import copy_to_clipboard
        copy_to_clipboard(_l._text(text, "text"))

    def _unreadable(self, *args):
        raise _l.unsupported("The host does not let plugins read or observe the clipboard")

    getPrimaryClip = getPrimaryClipDescription = hasPrimaryClip = getText = hasText = _unreadable
    addPrimaryClipChangedListener = removePrimaryClipChangedListener = clearPrimaryClip = _unreadable


def _system_service(*args):
    """``Context.getSystemService(name)`` for the services this SDK implements itself."""
    from ayu_bridge import runtime
    if len(args) != 1 or not isinstance(args[0], str):
        raise _l.unsupported("Context.getSystemService takes one service name")
    if args[0] != "clipboard":
        raise _l.unsupported("Android system service has no counterpart in this bridge: " + args[0][:64])
    # Raises when the host lacks the clipboard route; a host-declared manager is not this class.
    if runtime.jclass("android.content.ClipboardManager") is not ClipboardManager:
        raise _l.unsupported("The host declares its own ClipboardManager")
    return ClipboardManager._instance()


# --- Context: storage, identity and preferences -----------------------------------------------

# The application the bridge emulates (``_ayu_policy.APP_VERSION`` is its version).
PACKAGE_NAME = "com.exteragram.messenger"
_PREFERENCES_DIRECTORY = "shared_prefs"
_MAX_PREFERENCES_BYTES = 1024 * 1024
_MAX_NAME_BYTES = 128
# Preference files the reference client keeps for itself (``org.telegram.messenger``, ``com.exteragram.messenger``
# and its plugin host); a per-account file is one of the prefixes followed by the account number. The bridge
# cannot show them and must not pretend they are empty.
_APP_PREFERENCES = frozenset({
    "mainconfig", "userconfing", "Notifications", "emoji", "themeconfig", "langconfig", "systemConfig",
    "media_saved_pos", "shortcut_widget", "saved_tokens", "saved_tokens_login", "purchases", "camera", "uploadinfo",
    "webview_bots", "videoconvert", "stats", "sensitive_requests", "plugin_settings", "plugin_catalog",
    "plugin_analyzer_updates", "icon_picker", "google_bug_154855417", "drafts", "chatthemeconfig_emoji",
    "background_activity",
})
_APP_PREFERENCE_PREFIXES = (
    "mainconfig", "userconfig", "Notifications", "emoji", "stats", "drafts", "bot_drafts", "2voicedrafts_",
    "recent_reactions_", "top_reactions_", "saved_reactions_", "emojithemes_config_", "restrictedstatuses_",
    "replyicons_", "hashtag_search_history", "chatthemeconfig_", "avatar_constructor",
)
# Plugin threads may commit at once; Android serializes commits the same way.
_commit_lock = threading.RLock()
_KINDS = {"string": "java.lang.String", "int": "java.lang.Integer", "long": "java.lang.Long",
          "float": "java.lang.Float", "boolean": "java.lang.Boolean", "set": "java.util.HashSet"}


def _storage(base, *parts):
    """A directory of the bridge's own storage in the application container, created on demand."""
    import file_utils
    return file_utils._directory("Library", base, file_utils._STORAGE_NAME, *parts)


def _data(*parts):
    return _storage("Application Support", *parts)


def _cache(*parts):
    return _storage("Caches", *parts)


def _arity(args, count, name):
    if len(args) != count:
        raise TypeError(f"Context.{name} takes {count} argument{'' if count == 1 else 's'}")


def _files_dir(*args):
    """``getFilesDir()``: the directory that holds ``plugins/``, as on Android."""
    _arity(args, 0, "getFilesDir")
    return File(_data())


def _cache_dir(*args):
    _arity(args, 0, "getCacheDir")
    return File(_cache())


def _code_cache_dir(*args):
    _arity(args, 0, "getCodeCacheDir")
    return File(_cache("code_cache"))


def _external_files_path(args, name):
    _arity(args, 1, name)
    kind = args[0]
    if kind is None:
        return _data("external")
    # Android appends the type (``Environment.DIRECTORY_*``) to the external files directory.
    if not isinstance(kind, str) or not kind or kind.startswith("/") or ".." in kind.split("/") or "\0" in kind:
        raise _l.unsupported(f"Context.{name} takes None or a relative directory name")
    return _data("external", *[part for part in kind.split("/") if part])


def _external_files_dir(*args):
    """``getExternalFilesDir(type)``: iOS has no shared storage, so a directory of the same container."""
    return File(_external_files_path(args, "getExternalFilesDir"))


def _external_files_dirs(*args):
    return [File(_external_files_path(args, "getExternalFilesDirs"))]


def _external_cache_dir(*args):
    _arity(args, 0, "getExternalCacheDir")
    return File(_cache("external"))


def _dir(*args):
    """``getDir(name, mode)``: Android's ``app_<name>`` directory of the application data."""
    _arity(args, 2, "getDir")
    name, mode = args
    if not isinstance(name, str) or not _l.is_int(mode):
        raise TypeError("Context.getDir takes (name, mode)")
    if "/" in name:
        raise IllegalArgumentException(f"File app_{name} contains a path separator")
    if mode != 0 or not name or "\0" in name or len(name.encode("utf-8", "replace")) > _MAX_NAME_BYTES:
        raise _l.unsupported("Context.getDir takes a short name and MODE_PRIVATE")
    return File(_data("app_" + name))


def _package_name(*args):
    _arity(args, 0, "getPackageName")
    return PACKAGE_NAME


@returns(_l.ClassLoader)
def _class_loader(*args):
    """``getClassLoader()``: the loader that resolves names through the bridge's class registry."""
    _arity(args, 0, "getClassLoader")
    from ayu_bridge import runtime
    runtime.require()
    return _l.ClassLoader.getSystemClassLoader()


@with_receiver
def _application_context(context, *args):
    _arity(args, 0, "getApplicationContext")
    return context


class _Listener(Object):
    """``SharedPreferences.OnSharedPreferenceChangeListener``."""

    def onSharedPreferenceChanged(self, sharedPreferences, key):
        raise _l.missing_member(type(self), "onSharedPreferenceChanged")


class _Editor(Object):
    """``SharedPreferences.Editor``: changes are collected and take effect in ``commit``/``apply``."""

    def __init__(self, preferences):
        if not isinstance(preferences, SharedPreferences):
            raise _l.unsupported("Use SharedPreferences.edit()")
        self._preferences, self._modified, self._clear = preferences, {}, False

    def _put(self, key, entry):
        if not isinstance(key, str):
            raise TypeError("A preference key must be a string")
        # Android keeps one pending value per key; the last call for a key wins.
        self._modified.pop(key, None)
        self._modified[key] = entry

    def putString(self, key, value):
        self._put(key, None if value is None else ("string", _l._text(value)))
        return self

    def putStringSet(self, key, values):
        self._put(key, None if values is None else ("set", frozenset(_l._text(item, "set element") for item in values)))
        return self

    def putInt(self, key, value):
        if not _l.is_int(value) or not _l.fits_int(value):
            raise TypeError("putInt requires a 32-bit int")
        self._put(key, ("int", value))
        return self

    def putLong(self, key, value):
        if not _l.is_int(value) or not _l.LONG_MIN <= value <= _l.LONG_MAX:
            raise TypeError("putLong requires a 64-bit int")
        self._put(key, ("long", value))
        return self

    def putFloat(self, key, value):
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise TypeError("putFloat requires a number")
        self._put(key, ("float", _l.to_float32(value)))
        return self

    def putBoolean(self, key, value):
        if not isinstance(value, (bool, _l.Boolean)):
            raise TypeError("putBoolean requires a boolean")
        self._put(key, ("boolean", bool(value)))
        return self

    def remove(self, key):
        self._put(key, None)
        return self

    def clear(self):
        self._clear = True
        return self

    def _commit(self):
        """Android's ``commitToMemory``: a ``clear`` comes first whatever the call order was."""
        preferences = self._preferences
        with _commit_lock:
            values, changed = dict(preferences._values), []
            cleared, self._clear = self._clear, False
            if cleared:
                values.clear()
            modified, self._modified = self._modified, {}
            for key, entry in modified.items():
                if entry is None:
                    if key not in values:
                        continue
                    del values[key]
                elif values.get(key) == entry:
                    continue
                else:
                    values[key] = entry
                changed.append(key)
            written = True
            if cleared and preferences._values or changed:
                written = preferences._write(values)
                preferences._values = values
        preferences._notify(cleared, changed)
        return written

    def commit(self):
        return self._commit()

    def apply(self):
        self._commit()


class SharedPreferences(Object):
    """``android.content.SharedPreferences`` of the calling plugin.

    Android keeps one XML file per name in the application's data; here each plugin has its own
    files (``shared_prefs/<plugin id>/<name>.json`` of the bridge's storage), so a plugin never
    reads another plugin's or the application's preferences. Values keep their Java type: a
    getter of another type throws ``ClassCastException``. ``apply`` writes before it returns,
    and listeners, which are held weakly as on Android, run inside ``commit``/``apply``.
    """
    Editor = _Editor
    OnSharedPreferenceChangeListener = _Listener

    def __init__(self, *args):
        raise _l.unsupported("Use Context.getSharedPreferences(name, mode)")

    @staticmethod
    def _open(name, mode):
        if not isinstance(name, str) or not _l.is_int(mode):
            raise TypeError("Context.getSharedPreferences takes (name, mode)")
        if "/" in name:
            raise IllegalArgumentException(f"File {name}.xml contains a path separator")
        if mode not in (0, 4) or not name or "\0" in name or len(name.encode("utf-8", "replace")) > _MAX_NAME_BYTES:
            raise _l.unsupported("Context.getSharedPreferences takes a short name and MODE_PRIVATE")
        if name in _APP_PREFERENCES or any(
                name.startswith(prefix) and name[len(prefix):].isdigit() for prefix in _APP_PREFERENCE_PREFIXES):
            raise _l.unsupported("The application's own preferences are not available to plugins: " + name)
        from ayu_bridge import runtime
        scope = runtime.require()
        opened = _l.scoped_store("shared_preferences")
        if name not in opened:
            preferences = object.__new__(SharedPreferences)
            preferences._path = os.path.join(_data(_PREFERENCES_DIRECTORY, scope.plugin_id),
                                             urllib.parse.quote(name, safe="") + ".json")
            preferences._values, preferences._listeners = preferences._read(), []
            opened[name] = preferences
        return opened[name]

    def _read(self):
        """Stored values by key as ``(kind, value)``; a missing or damaged file is empty, as on Android."""
        try:
            with open(self._path, "rb") as stream:
                data = stream.read(_MAX_PREFERENCES_BYTES + 1)
            stored = json.loads(data.decode("utf-8")) if len(data) <= _MAX_PREFERENCES_BYTES else None
        except (OSError, ValueError, RecursionError):
            return {}
        values = {}
        entries = stored.get("values") if isinstance(stored, dict) and stored.get("version") == 1 else None
        for key, entry in entries.items() if isinstance(entries, dict) else ():
            if not isinstance(entry, list) or len(entry) != 2 or entry[0] not in _KINDS:
                return {}
            kind, value = entry
            if kind == "set":
                if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
                    return {}
                value = frozenset(value)
            elif kind == "float":
                # Written as text: JSON has no infinities or NaN.
                try:
                    value = float(value) if isinstance(value, str) else None
                except ValueError:
                    value = None
            elif type(value) is not {"string": str, "int": int, "long": int, "boolean": bool}[kind]:
                value = None
            if value is None:
                return {}
            values[key] = (kind, value)
        return values

    def _write(self, values):
        entries = {}
        for key, (kind, value) in values.items():
            entries[key] = [kind, sorted(value) if kind == "set" else repr(value) if kind == "float" else value]
        data = json.dumps({"version": 1, "values": entries}, ensure_ascii=False, separators=(",", ":")).encode(
            "utf-8", "surrogatepass")
        if len(data) > _MAX_PREFERENCES_BYTES:
            return False
        temporary = self._path + ".tmp"
        try:
            with open(temporary, "wb") as stream:
                stream.write(data)
            os.replace(temporary, self._path)
        except OSError:
            return False
        return True

    def _notify(self, cleared, changed):
        listeners = [item for item in (reference() for reference in self._listeners) if item is not None]
        # Android (API 30) reports a clear as a null key first, then the changed keys last to first.
        for key in ([None] if cleared else []) + changed[::-1]:
            for listener in listeners:
                _l.call(listener, "onSharedPreferenceChanged", self, key)

    def _get(self, key, kind, default):
        entry = self._values.get(key)
        if entry is None:
            return default
        if entry[0] != kind:
            raise ClassCastException(f"{_KINDS[entry[0]]} cannot be cast to {_KINDS[kind]}")
        return entry[1]

    def getString(self, key, defValue):
        return self._get(key, "string", defValue)

    def getInt(self, key, defValue):
        return self._get(key, "int", defValue)

    def getLong(self, key, defValue):
        return self._get(key, "long", defValue)

    def getFloat(self, key, defValue):
        return self._get(key, "float", defValue)

    def getBoolean(self, key, defValue):
        return self._get(key, "boolean", defValue)

    def getStringSet(self, key, defValues):
        from . import java_util
        found = self._get(key, "set", None)
        return defValues if found is None else java_util.HashSet(sorted(found))

    def getAll(self):
        from . import java_util
        return java_util.HashMap({key: java_util.HashSet(sorted(value)) if kind == "set" else value
                                  for key, (kind, value) in self._values.items()})

    def contains(self, key):
        return key in self._values

    def edit(self):
        return _Editor(self)

    def registerOnSharedPreferenceChangeListener(self, listener):
        if listener is None:
            raise NullPointerException("listener is null")
        if not any(reference() == listener for reference in self._listeners):
            method = getattr(listener, "__self__", None) is not None and hasattr(listener, "__func__")
            self._listeners.append(weakref.WeakMethod(listener) if method else weakref.ref(listener))

    def unregisterOnSharedPreferenceChangeListener(self, listener):
        self._listeners = [reference for reference in self._listeners
                           if reference() is not None and reference() != listener]


@returns(SharedPreferences)
def _shared_preferences(*args):
    _arity(args, 2, "getSharedPreferences")
    return SharedPreferences._open(*args)


@with_receiver
@returns("android.net.Uri")
def _uri_from_file(uri, *args):
    """``Uri.fromFile(file)``: the ``file://`` URI of the absolute path, made by the host's ``Uri.parse``."""
    if len(args) != 1:
        raise TypeError("Uri.fromFile takes one java.io.File")
    if args[0] is None:
        raise NullPointerException("file")
    if not isinstance(args[0], File):
        raise TypeError("Uri.fromFile takes one java.io.File")
    # ``Uri.encode(path, "/")``: everything but unreserved characters and the separator is escaped.
    return uri.parse("file://" + urllib.parse.quote(args[0].getAbsolutePath(), safe="/_-!.~'()*"))


# Service names are plain Android constants; only ``clipboard`` resolves to a service.
HOST_MEMBERS = {"android.net.Uri": {"fromFile": _uri_from_file}, "android.content.Context": {
    "getFilesDir": _files_dir, "getCacheDir": _cache_dir, "getCodeCacheDir": _code_cache_dir,
    "getExternalFilesDir": _external_files_dir, "getExternalFilesDirs": _external_files_dirs,
    "getExternalCacheDir": _external_cache_dir, "getDir": _dir,
    "getPackageName": _package_name, "getClassLoader": _class_loader,
    "getApplicationContext": _application_context, "getSharedPreferences": _shared_preferences,
    "MODE_PRIVATE": 0, "MODE_MULTI_PROCESS": 4, "MODE_APPEND": 32768,
    "getSystemService": _system_service,
    "CLIPBOARD_SERVICE": "clipboard", "WINDOW_SERVICE": "window", "ACTIVITY_SERVICE": "activity",
    "INPUT_METHOD_SERVICE": "input_method", "AUDIO_SERVICE": "audio", "VIBRATOR_SERVICE": "vibrator",
    "WIFI_SERVICE": "wifi", "ALARM_SERVICE": "alarm", "TELEPHONY_SERVICE": "phone",
    "NOTIFICATION_SERVICE": "notification", "CONNECTIVITY_SERVICE": "connectivity", "POWER_SERVICE": "power",
    "LOCATION_SERVICE": "location", "SENSOR_SERVICE": "sensor", "ACCESSIBILITY_SERVICE": "accessibility",
    "KEYGUARD_SERVICE": "keyguard", "BATTERY_SERVICE": "batterymanager",
}}

CLASSES = _l.register({
    "android.util.Log": Log,
    "android.content.ClipboardManager": ClipboardManager,
    "android.content.SharedPreferences": SharedPreferences,
    "android.content.SharedPreferences$Editor": _Editor,
    "android.content.SharedPreferences$OnSharedPreferenceChangeListener": _Listener,
})
