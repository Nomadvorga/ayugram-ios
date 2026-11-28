"""``android.content.Intent`` and the classes around launching one: results, documents, packages.

``Intent`` is a value with Android's member semantics; ``Context.startActivity`` and
``startActivityForResult`` (served here on the host's ``Context``) hand it to ``_ayu_intents``,
which knows the shapes the host operation ``intents.launch`` can show. ``ContentResolver`` reads
the documents a picker returned, files of the plugin storage named by ``FileProvider`` and
``file://`` paths. ``PackageManager`` answers for the one package that exists: the emulated client.
"""
from __future__ import annotations

import mimetypes
import os
import urllib.parse

import _ayu_intents
import _ayu_policy

from . import requires, returns, with_receiver
from . import java_lang as _l
from .android_content import ClipData, ComponentName
from .java_io import File, FileInputStream, FileNotFoundException, FileOutputStream
from .java_lang import IllegalArgumentException, NullPointerException, Object

PACKAGE_NAME = _ayu_intents.PACKAGE_NAME
_ACTIVITY = "org.telegram.ui.LaunchActivity"
_CONTEXT = "android.content.Context"
# ``versionCode`` of the arm64 build of the emulated release: ``APP_VERSION_CODE`` 7303 of exteraGram
# b4d852f times ten plus the ABI digit 5 (``TMessagesProj/build.gradle``). ``versionName`` is
# ``_ayu_policy.APP_VERSION``, the version ``__min_version__`` and ``__app_version__`` are judged against.
VERSION_CODE = 73035

ActivityNotFoundException = _l._throwable("ActivityNotFoundException", _l.RuntimeException)
NameNotFoundException = _l._throwable("NameNotFoundException", _l.Exception_)
CursorIndexOutOfBoundsException = _l._throwable("CursorIndexOutOfBoundsException", _l.IndexOutOfBoundsException)


def _class_name(value):
    """Java name of a class a plugin passed (a local class, a ``Class`` or a host facade)."""
    if isinstance(value, str):
        return value
    if isinstance(value, _l.Class):
        return value.getName()
    name = getattr(value, "_name", None) if not isinstance(value, type) else _l.java_name(value)
    if not isinstance(name, str):
        raise TypeError("Expected a Java class")
    return name


class Intent(Object):
    """``android.content.Intent``: action, data, type, categories, extras, flags, package, component.

    Replaces the host's four-field value adapter, which nothing can launch.
    """
    __ayu_requires__ = (_ayu_intents.OPERATION,)
    __ayu_overrides_host__ = True

    ACTION_MAIN = "android.intent.action.MAIN"
    ACTION_VIEW = _ayu_intents.ACTION_VIEW
    ACTION_SEND = _ayu_intents.ACTION_SEND
    ACTION_SEND_MULTIPLE = _ayu_intents.ACTION_SEND_MULTIPLE
    ACTION_GET_CONTENT = _ayu_intents.ACTION_GET_CONTENT
    ACTION_OPEN_DOCUMENT = _ayu_intents.ACTION_OPEN_DOCUMENT
    ACTION_CHOOSER = _ayu_intents.ACTION_CHOOSER
    ACTION_BATTERY_CHANGED = "android.intent.action.BATTERY_CHANGED"
    CATEGORY_DEFAULT = _ayu_intents.CATEGORY_DEFAULT
    CATEGORY_BROWSABLE = _ayu_intents.CATEGORY_BROWSABLE
    CATEGORY_OPENABLE = _ayu_intents.CATEGORY_OPENABLE
    CATEGORY_LAUNCHER = "android.intent.category.LAUNCHER"
    CATEGORY_HOME = "android.intent.category.HOME"
    EXTRA_INTENT = _ayu_intents.EXTRA_INTENT
    EXTRA_TITLE = _ayu_intents.EXTRA_TITLE
    EXTRA_TEXT = _ayu_intents.EXTRA_TEXT
    EXTRA_STREAM = _ayu_intents.EXTRA_STREAM
    EXTRA_MIME_TYPES = _ayu_intents.EXTRA_MIME_TYPES
    EXTRA_ALLOW_MULTIPLE = _ayu_intents.EXTRA_ALLOW_MULTIPLE
    EXTRA_LOCAL_ONLY = _ayu_intents.EXTRA_LOCAL_ONLY
    EXTRA_SUBJECT = "android.intent.extra.SUBJECT"
    EXTRA_HTML_TEXT = "android.intent.extra.HTML_TEXT"
    EXTRA_EMAIL = "android.intent.extra.EMAIL"
    EXTRA_RETURN_RESULT = "android.intent.extra.RETURN_RESULT"
    FLAG_GRANT_READ_URI_PERMISSION = 0x00000001
    FLAG_GRANT_WRITE_URI_PERMISSION = 0x00000002
    FLAG_GRANT_PERSISTABLE_URI_PERMISSION = 0x00000040
    FLAG_GRANT_PREFIX_URI_PERMISSION = 0x00000080
    FLAG_ACTIVITY_CLEAR_TASK = 0x00008000
    FLAG_ACTIVITY_REORDER_TO_FRONT = 0x00020000
    FLAG_ACTIVITY_NO_ANIMATION = 0x00010000
    FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS = 0x00800000
    FLAG_ACTIVITY_CLEAR_TOP = 0x04000000
    FLAG_ACTIVITY_MULTIPLE_TASK = 0x08000000
    FLAG_ACTIVITY_NEW_TASK = 0x10000000
    FLAG_ACTIVITY_SINGLE_TOP = 0x20000000
    FLAG_ACTIVITY_NO_HISTORY = 0x40000000
    _GRANT_FLAGS = 0x000000C3

    def __init__(self, *args):
        self._action = self._data = self._type = self._package = self._component = self._clip = None
        self._categories, self._extras, self._flags = [], {}, 0
        if not args:
            return
        first = args[0]
        if len(args) == 1 and isinstance(first, Intent):
            self._action, self._data, self._type = first._action, first._data, first._type
            self._package, self._component, self._clip = first._package, first._component, first._clip
            self._categories, self._extras, self._flags = list(first._categories), dict(first._extras), first._flags
        elif len(args) in (1, 2, 4) and (first is None or isinstance(first, str)):
            self._action = first
            if len(args) > 1:
                self._data = args[1]
            if len(args) == 4:
                self._component = ComponentName(PACKAGE_NAME, _class_name(args[3]))
        elif len(args) == 2:
            # ``Intent(Context packageContext, Class<?> cls)``.
            self._component = ComponentName(PACKAGE_NAME, _class_name(args[1]))
        else:
            raise TypeError("Intent takes (), (Intent), (action), (action, uri), (context, class) or (action, uri, context, class)")

    def clone(self):
        return Intent(self)

    def getAction(self):
        return self._action

    def setAction(self, action):
        if action is not None and not isinstance(action, str):
            raise TypeError("An intent action is a string")
        self._action = action
        return self

    def getData(self):
        return self._data

    def getDataString(self):
        return None if self._data is None else _ayu_intents.uri_text(self._data)

    def getScheme(self):
        text = self.getDataString()
        if text is None or ":" not in text:
            return None
        return text.partition(":")[0]

    def getType(self):
        return self._type

    def setData(self, data):
        # Android clears the type here and the data in ``setType``.
        self._data, self._type = data, None
        return self

    def setType(self, mime_type):
        if mime_type is not None and not isinstance(mime_type, str):
            raise TypeError("A MIME type is a string")
        self._data, self._type = None, mime_type
        return self

    def setDataAndType(self, data, mime_type):
        if mime_type is not None and not isinstance(mime_type, str):
            raise TypeError("A MIME type is a string")
        self._data, self._type = data, mime_type
        return self

    def addCategory(self, category):
        if not isinstance(category, str):
            raise TypeError("An intent category is a string")
        if category not in self._categories:
            self._categories.append(category)
        return self

    def removeCategory(self, category):
        if category in self._categories:
            self._categories.remove(category)

    def hasCategory(self, category):
        return category in self._categories

    def getCategories(self):
        if not self._categories:
            return None
        from . import java_util
        return java_util.HashSet(self._categories)

    def putExtra(self, name, value):
        if not isinstance(name, str):
            raise TypeError("An extra name is a string")
        self._extras[name] = value
        return self

    putParcelableArrayListExtra = putStringArrayListExtra = putIntegerArrayListExtra = putExtra
    putCharSequenceArrayListExtra = putExtra

    def putExtras(self, source):
        if isinstance(source, Intent):
            self._extras.update(source._extras)
        elif source is not None:
            # A local ``Bundle``.
            values = getattr(source, "_values", None)
            if not isinstance(values, dict):
                raise TypeError("putExtras takes an Intent or a Bundle")
            self._extras.update(values)
        return self

    def replaceExtras(self, source):
        self._extras = {}
        return self.putExtras(source)

    def hasExtra(self, name):
        return name in self._extras

    def removeExtra(self, name):
        self._extras.pop(name, None)

    def getExtras(self):
        if not self._extras:
            return None
        from . import android_os
        bundle = android_os.Bundle()
        for name, value in self._extras.items():
            if isinstance(value, bool):
                bundle.putBoolean(name, value)
            elif _l.is_int(value):
                bundle.putInt(name, value) if _l.fits_int(value) else bundle.putLong(name, value)
            elif isinstance(value, float):
                bundle.putDouble(name, value)
            elif isinstance(value, str):
                bundle.putString(name, value)
            elif isinstance(value, list) and all(isinstance(item, str) for item in value):
                bundle.putStringArrayList(name, value)
            elif isinstance(value, list):
                bundle.putParcelableArrayList(name, value)
            else:
                bundle.putParcelable(name, value)
        return bundle

    def _extra(self, name, accepted, default):
        # A typed getter answers its default for a missing key and for a value of another type.
        value = self._extras.get(name)
        return value if accepted(value) else default

    def getStringExtra(self, name):
        return self._extra(name, lambda value: isinstance(value, str), None)

    def getCharSequenceExtra(self, name):
        return self._extra(name, lambda value: isinstance(value, _l.CharSequence), None)

    def getBooleanExtra(self, name, default):
        return self._extra(name, lambda value: isinstance(value, bool), default)

    def getIntExtra(self, name, default):
        return self._extra(name, lambda value: _l.is_int(value) and _l.fits_int(value), default)

    def getLongExtra(self, name, default):
        return self._extra(name, _l.is_int, default)

    def getFloatExtra(self, name, default):
        return self._extra(name, lambda value: isinstance(value, float), default)

    getDoubleExtra = getFloatExtra

    def getParcelableExtra(self, name, *type_hint):
        value = self._extras.get(name)
        return None if isinstance(value, (bool, int, float, str, list, tuple)) else value

    getSerializableExtra = getParcelableExtra

    def getParcelableArrayListExtra(self, name, *type_hint):
        return self._extra(name, lambda value: isinstance(value, list), None)

    getStringArrayListExtra = getIntegerArrayListExtra = getStringArrayExtra = getParcelableArrayListExtra

    def getBundleExtra(self, name):
        return self._extra(name, lambda value: type(value).__name__ == "Bundle", None)

    def getFlags(self):
        return self._flags

    def _bits(self, flags):
        if not _l.is_int(flags):
            raise TypeError("Intent flags are an int")
        return _l.i32(flags)

    def setFlags(self, flags):
        self._flags = self._bits(flags)
        return self

    def addFlags(self, flags):
        self._flags = _l.i32(self._flags | self._bits(flags))
        return self

    def removeFlags(self, flags):
        self._flags = _l.i32(self._flags & ~self._bits(flags))

    def getPackage(self):
        return self._package

    def setPackage(self, package):
        if package is not None and not isinstance(package, str):
            raise TypeError("A package name is a string")
        self._package = package
        return self

    def getComponent(self):
        return self._component

    def setComponent(self, component):
        if component is not None and not isinstance(component, ComponentName):
            raise TypeError("setComponent takes a ComponentName")
        self._component = component
        return self

    def setClassName(self, package, class_name):
        # ``(String packageName, String className)`` or ``(Context packageContext, String className)``.
        self._component = ComponentName(package if isinstance(package, str) else PACKAGE_NAME, class_name)
        return self

    def setClass(self, context, cls):
        self._component = ComponentName(PACKAGE_NAME, _class_name(cls))
        return self

    def getClipData(self):
        return self._clip

    def setClipData(self, clip):
        if clip is not None and not isinstance(clip, ClipData):
            raise TypeError("setClipData takes a ClipData")
        self._clip = clip

    def resolveActivity(self, package_manager):
        """The component that would handle the intent; None when nothing in the bridge can launch it."""
        if not isinstance(package_manager, PackageManager):
            raise TypeError("resolveActivity takes a PackageManager")
        if self._component is not None or not _ayu_intents.can_launch(self):
            return None
        return ComponentName(PACKAGE_NAME, _ACTIVITY)

    @staticmethod
    def createChooser(target, title, *sender):
        if not isinstance(target, Intent):
            raise TypeError("createChooser takes an Intent")
        if len(sender) > 1 or sender and sender[0] is not None:
            raise _l.unsupported("Intent.createChooser with an IntentSender is not supported")
        chooser = Intent(Intent.ACTION_CHOOSER)
        chooser.putExtra(Intent.EXTRA_INTENT, target)
        if title is not None:
            chooser.putExtra(Intent.EXTRA_TITLE, title)
        # Android migrates the URI grants and the clip of the target to the chooser.
        grants = target._flags & Intent._GRANT_FLAGS
        if grants:
            clip = target._clip
            if clip is None and target._data is not None:
                clip = ClipData(None, [] if target._type is None else [target._type], ClipData.Item(target._data))
            if clip is not None:
                chooser.setClipData(clip)
                chooser.addFlags(grants)
        return chooser

    @staticmethod
    def makeMainActivity(component):
        intent = Intent(Intent.ACTION_MAIN)
        intent.setComponent(component)
        intent.addCategory(Intent.CATEGORY_LAUNCHER)
        return intent

    @staticmethod
    def makeRestartActivityTask(component):
        intent = Intent.makeMainActivity(component)
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK)
        return intent

    def toString(self):
        parts = []
        if self._action is not None:
            parts.append("act=" + self._action)
        if self._categories:
            parts.append("cat=[" + ",".join(self._categories) + "]")
        if self._data is not None:
            parts.append("dat=" + _ayu_intents.uri_text(self._data))
        if self._type is not None:
            parts.append("typ=" + self._type)
        if self._flags:
            parts.append("flg=0x%x" % (self._flags & 0xFFFFFFFF))
        if self._package is not None:
            parts.append("pkg=" + self._package)
        if self._component is not None:
            parts.append("cmp=" + self._component.flattenToShortString())
        if self._clip is not None:
            parts.append("clip={" + self._clip.toString() + "}")
        if self._extras:
            parts.append("(has extras)")
        return "Intent { " + " ".join(parts) + (" " if parts else "") + "}"


# Plain data, like every other constant: an intent built with one of these actions cannot be launched.
for _name, _value in _ayu_intents.ANDROID_ONLY_ACTIONS.items():
    setattr(Intent, _name, _value)


class Activity(Object):
    """``android.app.Activity`` result codes. The activity itself is the host's ``Context``."""
    RESULT_CANCELED, RESULT_OK, RESULT_FIRST_USER = 0, -1, 1

    def __init__(self, *args):
        raise _l.unsupported("android.app.Activity cannot be constructed")


class OpenableColumns(Object):
    DISPLAY_NAME, SIZE = "_display_name", "_size"

    def __init__(self, *args):
        raise _l.unsupported("android.provider.OpenableColumns cannot be constructed")


class Cursor(Object):
    """A fixed table of rows, as ``MatrixCursor``; what ``ContentResolver.query`` returns here."""
    FIELD_TYPE_NULL, FIELD_TYPE_INTEGER, FIELD_TYPE_FLOAT, FIELD_TYPE_STRING, FIELD_TYPE_BLOB = 0, 1, 2, 3, 4

    def __init__(self, *args):
        raise _l.unsupported("android.database.Cursor is an interface; a cursor comes from ContentResolver.query")

    @staticmethod
    def _of(columns, rows):
        cursor = object.__new__(Cursor)
        cursor._columns, cursor._rows, cursor._position, cursor._closed = list(columns), [list(row) for row in rows], -1, False
        return cursor

    def getCount(self):
        return len(self._rows)

    def getPosition(self):
        return self._position

    def moveToPosition(self, position):
        if position >= len(self._rows):
            self._position = len(self._rows)
            return False
        if position < 0:
            self._position = -1
            return False
        self._position = position
        return True

    def move(self, offset):
        return self.moveToPosition(self._position + offset)

    def moveToFirst(self):
        return self.moveToPosition(0)

    def moveToLast(self):
        return self.moveToPosition(len(self._rows) - 1)

    def moveToNext(self):
        return self.moveToPosition(self._position + 1)

    def moveToPrevious(self):
        return self.moveToPosition(self._position - 1)

    def isFirst(self):
        return self._position == 0 and bool(self._rows)

    def isLast(self):
        return self._position == len(self._rows) - 1 and bool(self._rows)

    def isBeforeFirst(self):
        return not self._rows or self._position == -1

    def isAfterLast(self):
        return not self._rows or self._position == len(self._rows)

    def getColumnCount(self):
        return len(self._columns)

    def getColumnNames(self):
        return list(self._columns)

    def getColumnName(self, index):
        return self._columns[index]

    def getColumnIndex(self, name):
        return self._columns.index(name) if name in self._columns else -1

    def getColumnIndexOrThrow(self, name):
        index = self.getColumnIndex(name)
        if index < 0:
            raise IllegalArgumentException(f"column '{name}' does not exist. Available columns: {self._columns}")
        return index

    def _value(self, column):
        if not 0 <= self._position < len(self._rows):
            raise CursorIndexOutOfBoundsException(f"Index {self._position} requested, with a size of {len(self._rows)}")
        if not _l.is_int(column) or not 0 <= column < len(self._columns):
            raise CursorIndexOutOfBoundsException(f"Requested column: {column}, # of columns: {len(self._columns)}")
        return self._rows[self._position][column]

    def isNull(self, column):
        return self._value(column) is None

    def getString(self, column):
        value = self._value(column)
        return None if value is None else _l.jstr(value)

    def _number(self, column, convert):
        value = self._value(column)
        if value is None:
            return convert(0)
        if isinstance(value, str):
            try:
                return convert(float(value)) if convert is float else convert(int(value))
            except ValueError:
                raise _l.NumberFormatException(f'For input string: "{value}"') from None
        return convert(value)

    def getLong(self, column):
        return self._number(column, int)

    def getInt(self, column):
        return _l.i32(self._number(column, int))

    def getShort(self, column):
        return _l.signed(self._number(column, int), 16)

    def getDouble(self, column):
        return self._number(column, float)

    def getFloat(self, column):
        return _l.to_float32(self._number(column, float))

    def getType(self, column):
        value = self._value(column)
        if value is None:
            return Cursor.FIELD_TYPE_NULL
        if isinstance(value, float):
            return Cursor.FIELD_TYPE_FLOAT
        return Cursor.FIELD_TYPE_STRING if isinstance(value, str) else Cursor.FIELD_TYPE_INTEGER

    def close(self):
        self._closed = True

    def isClosed(self):
        return self._closed

    def __enter__(self):
        return self

    def __exit__(self, *error):
        self.close()
        return False


_DOCUMENT_COLUMNS = ("document_id", "mime_type", "_display_name", "last_modified", "flags", "_size")
_PROVIDER_COLUMNS = ("_display_name", "_size")


class ContentResolver(Object):
    """Reads what the bridge itself can name: picked documents, ``FileProvider`` files and ``file://`` paths.

    There are no other content providers: a URI of another authority has none, as Android reports
    for an authority nobody registered.
    """
    SCHEME_CONTENT, SCHEME_FILE, SCHEME_ANDROID_RESOURCE = "content", "file", "android.resource"

    def __init__(self, *args):
        raise _l.unsupported("Use Context.getContentResolver()")

    @staticmethod
    def _instance():
        from ayu_bridge import runtime
        runtime.require()
        return object.__new__(ContentResolver)

    @staticmethod
    def _resolve(uri):
        text = _ayu_intents.uri_text(uri)
        return text, _ayu_intents.resolve(text)

    def openInputStream(self, uri):
        text, found = ContentResolver._resolve(uri)
        if found is None:
            raise FileNotFoundException("No content provider: " + text)
        return FileInputStream(found[1]["path"])

    def openOutputStream(self, uri, mode="w"):
        text, found = ContentResolver._resolve(uri)
        if found is None:
            raise FileNotFoundException("No content provider: " + text)
        if found[0] == "document":
            raise _l.unsupported("A picked document is a read-only copy: the bridge cannot write to the original")
        if mode not in ("w", "wt", "wa", "rwt"):
            raise _l.unsupported("ContentResolver.openOutputStream takes the mode w, wt, wa or rwt")
        return FileOutputStream(found[1]["path"], mode == "wa")

    def getType(self, uri):
        _, found = ContentResolver._resolve(uri)
        if found is None or found[0] == "file":
            return None
        if found[0] == "document":
            return found[1]["mime_type"]
        return mimetypes.guess_type(found[1]["name"])[0] or "application/octet-stream"

    def query(self, uri, projection, *selection):
        """One row describing the document or file; None when no provider answers the URI."""
        if len(selection) not in (2, 3, 4):
            raise TypeError("ContentResolver.query takes (uri, projection, selection, selectionArgs, sortOrder)")
        _, found = ContentResolver._resolve(uri)
        if found is None or found[0] == "file":
            return None
        kind, record = found
        try:
            status = os.stat(record["path"])
        except OSError:
            return Cursor._of(_DOCUMENT_COLUMNS if kind == "document" else _PROVIDER_COLUMNS, [])
        values = {"_display_name": record["name"], "_size": status.st_size}
        if kind == "document":
            values.update({"document_id": record["id"], "mime_type": record["mime_type"],
                           "last_modified": int(status.st_mtime * 1000), "flags": 0})
            # A documents provider answers every requested column, null where it has no value.
            columns = _DOCUMENT_COLUMNS if projection is None else [_l._text(name, "column") for name in projection]
        else:
            # ``FileProvider`` drops the columns it does not know.
            columns = _PROVIDER_COLUMNS if projection is None else [name for name in projection if name in values]
        return Cursor._of(columns, [[values.get(name) for name in columns]])

    def takePersistableUriPermission(self, uri, flags):
        # Nothing the bridge names outlives the plugin generation, so no grant is persistable.
        raise _l.SecurityException("No persistable permission grants found for Uri " + _ayu_intents.uri_text(uri))

    releasePersistableUriPermission = takePersistableUriPermission

    def getPersistedUriPermissions(self):
        return []


class PackageInfo(Object):
    def __init__(self):
        self.packageName = None
        self.versionName = None
        self.versionCode = 0

    def getLongVersionCode(self):
        return self.versionCode


class PackageManager(Object):
    """The one installed package is the emulated client; every other package is not installed."""
    NameNotFoundException = NameNotFoundException
    PERMISSION_GRANTED, PERMISSION_DENIED = 0, -1
    GET_ACTIVITIES, GET_META_DATA, MATCH_DEFAULT_ONLY = 0x00000001, 0x00000080, 0x00010000

    def __init__(self, *args):
        raise _l.unsupported("Use Context.getPackageManager()")

    @staticmethod
    def _instance():
        from ayu_bridge import runtime
        runtime.require()
        return object.__new__(PackageManager)

    def getPackageInfo(self, package, flags):
        if not isinstance(package, str) or not _l.is_int(flags):
            raise TypeError("PackageManager.getPackageInfo takes (packageName, flags)")
        if package != PACKAGE_NAME:
            raise NameNotFoundException(package)
        info = PackageInfo()
        info.packageName, info.versionName, info.versionCode = PACKAGE_NAME, _ayu_policy.APP_VERSION, VERSION_CODE
        return info

    def getLaunchIntentForPackage(self, package):
        if not isinstance(package, str):
            raise NullPointerException("packageName is null")
        if package != PACKAGE_NAME:
            return None
        intent = Intent(Intent.ACTION_MAIN)
        intent.addCategory(Intent.CATEGORY_LAUNCHER)
        intent.setPackage(package)
        intent.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        intent.setClassName(package, _ACTIVITY)
        return intent


class FileProvider(Object):
    """``androidx.core.content.FileProvider``: ``content://`` names for files of the plugin storage."""

    def __init__(self, *args):
        raise _l.unsupported("androidx.core.content.FileProvider cannot be constructed")

    @staticmethod
    def getUriForFile(context, authority, file):
        if file is None:
            raise NullPointerException("file is null")
        if not isinstance(file, File):
            raise TypeError("FileProvider.getUriForFile takes a java.io.File")
        from ayu_bridge import runtime
        return runtime.jclass("android.net.Uri").parse(_ayu_intents.provider_uri(authority, file.getAbsolutePath()))


# --- members of the host's Context, BaseFragment and Uri ---------------------------------------

@requires(_ayu_intents.OPERATION)
@with_receiver
def _start_activity(context, *args):
    """``startActivity(intent)``; an options ``Bundle`` has no meaning here and must be null."""
    if len(args) not in (1, 2):
        raise TypeError("startActivity takes (intent) or (intent, options)")
    if len(args) == 2 and args[1] is not None:
        raise _l.unsupported("startActivity with activity options is not supported")
    _ayu_intents.start(context, args[0])


@requires(_ayu_intents.OPERATION)
@with_receiver
def _start_activity_for_result(context, *args):
    if len(args) not in (2, 3):
        raise TypeError("startActivityForResult takes (intent, requestCode) or (intent, requestCode, options)")
    if len(args) == 3 and args[2] is not None:
        raise _l.unsupported("startActivityForResult with activity options is not supported")
    _ayu_intents.start(context, args[0], args[1])


@returns(ContentResolver)
def _content_resolver(*args):
    if args:
        raise TypeError("Context.getContentResolver takes no arguments")
    return ContentResolver._instance()


@returns(PackageManager)
def _package_manager(*args):
    if args:
        raise TypeError("Context.getPackageManager takes no arguments")
    return PackageManager._instance()


def _invoke(target, name, args):
    return target._runtime.call("java.invoke", {"target": target, "name": name, "args": list(args), "kwargs": {}})


def _activity_class():
    """The ``java.lang.Class`` of the Android class an activity context is an instance of."""
    from ayu_bridge import runtime
    return runtime.jclass(_ACTIVITY).getClass()


@with_receiver
def _declared_method(target, *args):
    """``getDeclaredMethod`` on the class of an activity context.

    A method a hook point serves is a member of the Python-local ``LaunchActivity``; any other
    name is the host's own answer for its ``Context`` class.
    """
    import _ayu_xposed
    if args and isinstance(args[0], str) and _ayu_xposed.mapped(_CONTEXT, args[0]) is not None:
        if _ayu_xposed.android_class(target) is None:
            from ayu_bridge import MissingMember
            raise MissingMember("getDeclaredMethod is a member of the Context class, not of a Context")
        return _activity_class().getDeclaredMethod(*args)
    return _invoke(target, "getDeclaredMethod", args)


@with_receiver
def _declared_methods(target, *args):
    """``getDeclaredMethods`` on the class of an activity context: the hookable methods, then the host's list."""
    import _ayu_xposed
    listed = _invoke(target, "getDeclaredMethods", args)
    return [method for method in _activity_class().getDeclaredMethods()
            if _ayu_xposed.mapped(_CONTEXT, method.getName()) is not None] + list(listed)


@with_receiver
def _uri_authority(uri, *args):
    if args:
        raise TypeError("Uri.getAuthority takes no arguments")
    try:
        parts = urllib.parse.urlsplit(uri.toString())
    except ValueError:
        return None
    return urllib.parse.unquote(parts.netloc) if parts.netloc else None


@with_receiver
def _uri_path_segments(uri, *args):
    if args:
        raise TypeError("Uri.getPathSegments takes no arguments")
    try:
        parts = urllib.parse.urlsplit(uri.toString())
    except ValueError:
        return []
    return [urllib.parse.unquote(item) for item in parts.path.split("/") if item]


HOST_MEMBERS = {
    _CONTEXT: {
        "startActivity": _start_activity, "startActivityForResult": _start_activity_for_result,
        "getContentResolver": _content_resolver, "getPackageManager": _package_manager,
        "getDeclaredMethod": _declared_method, "getDeclaredMethods": _declared_methods,
    },
    "org.telegram.ui.ActionBar.BaseFragment": {"startActivityForResult": _start_activity_for_result},
    "android.net.Uri": {"getAuthority": _uri_authority, "getPathSegments": _uri_path_segments},
}

CLASSES = _l.register({
    "android.content.Intent": Intent,
    "android.content.ActivityNotFoundException": ActivityNotFoundException,
    "android.content.ContentResolver": ContentResolver,
    "android.content.pm.PackageManager": PackageManager,
    "android.content.pm.PackageManager$NameNotFoundException": NameNotFoundException,
    "android.content.pm.PackageInfo": PackageInfo,
    "android.app.Activity": Activity,
    "android.database.Cursor": Cursor,
    "android.database.CursorIndexOutOfBoundsException": CursorIndexOutOfBoundsException,
    "android.provider.OpenableColumns": OpenableColumns,
    "androidx.core.content.FileProvider": FileProvider,
})
