"""``android.content`` value classes implemented in Python.

Only data holders and interfaces live here. Anything that reaches the operating
system (``Context``, ``Intent`` launching, receivers, providers, the clipboard
service itself) belongs to the host; ``ClipboardManager`` is in ``android_compose``
because it is composed over a host operation.
"""
from __future__ import annotations

from . import java_lang as _l
from .java_lang import Comparable, IllegalArgumentException, NullPointerException, Object, jstr


class ClipDescription(Object):
    MIMETYPE_TEXT_PLAIN = "text/plain"
    MIMETYPE_TEXT_HTML = "text/html"
    MIMETYPE_TEXT_URILIST = "text/uri-list"
    MIMETYPE_TEXT_INTENT = "text/vnd.android.intent"
    MIMETYPE_UNKNOWN = "application/octet-stream"

    def __init__(self, label, mime_types=None):
        if isinstance(label, ClipDescription) and mime_types is None:
            label, mime_types = label._label, label._types
        if mime_types is None:
            raise NullPointerException("mimeTypes is null")
        self._label, self._types = label, [str(item) for item in mime_types]

    def getLabel(self):
        return self._label

    def getMimeTypeCount(self):
        return len(self._types)

    def getMimeType(self, index):
        if not 0 <= index < len(self._types):
            raise _l.ArrayIndexOutOfBoundsException(f"length={len(self._types)}; index={index}")
        return self._types[index]

    @staticmethod
    def compareMimeTypes(concrete, desired):
        if desired == "*/*" or concrete == desired:
            return True
        return desired.endswith("/*") and concrete.startswith(desired[:-1])

    def hasMimeType(self, mime_type):
        return any(ClipDescription.compareMimeTypes(item, mime_type) for item in self._types)

    def filterMimeTypes(self, mime_type):
        found = [item for item in self._types if ClipDescription.compareMimeTypes(item, mime_type)]
        return found or None

    def toString(self):
        return "ClipDescription { " + " ".join(self._types) + (
            ' "' + jstr(self._label) + '"' if self._label is not None else "") + " }"


class _Item(Object):
    def __init__(self, *args):
        self._text = self._html = self._intent = self._uri = None
        if not 1 <= len(args) <= 4:
            raise TypeError("ClipData.Item takes (text), (text, html), (intent), (uri) or (text, html, intent, uri)")
        if len(args) == 4:
            self._text, self._html, self._intent, self._uri = args
        elif len(args) == 3:
            self._text, self._intent, self._uri = args
        elif len(args) == 2:
            self._text, self._html = args
        elif args[0] is None or isinstance(args[0], _l.CharSequence):
            self._text = args[0]
        elif type(args[0]).__name__ == "RemoteObject" and getattr(args[0], "_class_name", "").endswith("Intent"):
            self._intent = args[0]
        else:
            self._uri = args[0]
        if self._html is not None and self._text is None:
            raise IllegalArgumentException("Plain text must be supplied if HTML text is supplied")

    def getText(self):
        return self._text

    def getHtmlText(self):
        return self._html

    def getIntent(self):
        return self._intent

    def getUri(self):
        return self._uri

    def coerceToText(self, context=None):
        if self._text is not None:
            return self._text
        if self._uri is not None:
            return jstr(self._uri.toString() if hasattr(self._uri, "toString") else self._uri)
        if self._intent is not None:
            raise _l.unsupported("Coercing an Intent clip item to text needs the host")
        return ""

    def toString(self):
        return "ClipData.Item { " + ("T:" + jstr(self._text) if self._text is not None else
                                    "U:" + jstr(self._uri) if self._uri is not None else "NULL") + " }"


class ClipData(Object):
    Item = _Item

    def __init__(self, *args):
        if len(args) == 3:
            self._description, item = ClipDescription(args[0], args[1]), args[2]
        elif len(args) == 2:
            self._description, item = ClipDescription(args[0]), args[1]
        elif len(args) == 1 and isinstance(args[0], ClipData):
            self._description, self._items = ClipDescription(args[0]._description), list(args[0]._items)
            return
        else:
            raise TypeError("ClipData takes (label, mimeTypes, item) or (description, item)")
        if item is None:
            raise NullPointerException("item is null")
        self._items = [item]

    @staticmethod
    def newPlainText(label, text):
        return ClipData(label, [ClipDescription.MIMETYPE_TEXT_PLAIN], _Item(text))

    @staticmethod
    def newHtmlText(label, text, html):
        return ClipData(label, [ClipDescription.MIMETYPE_TEXT_HTML], _Item(text, html))

    @staticmethod
    def newRawUri(label, uri):
        return ClipData(label, [ClipDescription.MIMETYPE_TEXT_URILIST], _Item(None, None, uri))

    @staticmethod
    def newUri(resolver, label, uri):
        raise _l.unsupported("ClipData.newUri needs a ContentResolver; use newRawUri")

    def getDescription(self):
        return self._description

    def addItem(self, *args):
        item = args[-1]
        if item is None:
            raise NullPointerException("item is null")
        self._items.append(item)

    def getItemCount(self):
        return len(self._items)

    def getItemAt(self, index):
        if not 0 <= index < len(self._items):
            raise _l.IndexOutOfBoundsException(f"Index {index} out of bounds for length {len(self._items)}")
        return self._items[index]

    def toString(self):
        return "ClipData { " + " ".join(self._description._types) + " {" + \
            " ".join(item.toString() for item in self._items) + "} }"


class ContentValues(Object):
    """Typed name/value set; the ``getAs*`` conversions follow Android's."""
    TAG = "ContentValues"

    def __init__(self, source=None):
        self._values = {}
        if isinstance(source, ContentValues):
            self._values.update(source._values)
        elif source is not None and not _l.is_int(source):
            raise TypeError("ContentValues takes no argument, a size or another ContentValues")

    def put(self, key, value):
        self._values[key] = value

    def putNull(self, key):
        self._values[key] = None

    def putAll(self, other):
        self._values.update(other._values)

    def size(self):
        return len(self._values)

    def isEmpty(self):
        return not self._values

    def remove(self, key):
        self._values.pop(key, None)

    def clear(self):
        self._values.clear()

    def containsKey(self, key):
        return key in self._values

    def get(self, key):
        return self._values.get(key)

    def getAsString(self, key):
        value = self._values.get(key)
        return None if value is None else jstr(value)

    def _number(self, key, convert, parse):
        value = self._values.get(key)
        if value is None:
            return None
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            return convert(value)
        if isinstance(value, _l.CharSequence):
            try:
                return parse(jstr(value))
            except _l.NumberFormatException:
                return None
        return None

    @staticmethod
    def _integer(bits):
        return lambda value: _l.signed(_l.truncate(value, 64) if isinstance(value, float) else value, bits)

    def getAsInteger(self, key):
        return self._number(key, ContentValues._integer(32), _l.Integer.parseInt)

    def getAsLong(self, key):
        return self._number(key, ContentValues._integer(64), _l.Long.parseLong)

    def getAsShort(self, key):
        return self._number(key, ContentValues._integer(16), _l.Short.parseShort)

    def getAsByte(self, key):
        return self._number(key, ContentValues._integer(8), _l.Byte.parseByte)

    def getAsDouble(self, key):
        return self._number(key, float, _l.parse_double)

    def getAsFloat(self, key):
        return self._number(key, _l.to_float32, _l.Float.parseFloat)

    def getAsBoolean(self, key):
        value = self._values.get(key)
        if isinstance(value, (bool, _l.Boolean)):
            return bool(value)
        if isinstance(value, _l.CharSequence):
            return _l.Boolean.parseBoolean(jstr(value)) or jstr(value) == "1"
        if isinstance(value, (int, float)):
            return value != 0
        return None

    def getAsByteArray(self, key):
        value = self._values.get(key)
        return value if isinstance(value, (bytes, bytearray)) else None

    def keySet(self):
        from . import java_util
        return java_util.HashSet(self._values)

    def valueSet(self):
        from . import java_util
        return java_util.HashSet(java_util.SimpleEntry(key, value) for key, value in self._values.items())

    def __len__(self):
        return len(self._values)

    def __contains__(self, key):
        return key in self._values

    def __eq__(self, other):
        return isinstance(other, ContentValues) and self._values == other._values

    __hash__ = None

    def hashCode(self):
        return _l.java_hash(self._values)

    def toString(self):
        return " ".join(jstr(key) + "=" + jstr(value) for key, value in self._values.items())

    def to_bridge(self):
        return dict(self._values)


class ComponentName(Comparable):
    def __init__(self, package, class_name):
        if class_name is None:
            raise NullPointerException("class name is null")
        if isinstance(class_name, _l.Class):
            class_name = class_name.getName()
        if not isinstance(package, str):
            if package is None:
                raise NullPointerException("package name is null")
            package = package.getPackageName()
        self._package, self._class = package, class_name

    def getPackageName(self):
        return self._package

    def getClassName(self):
        return self._class

    def getShortClassName(self):
        if self._class.startswith(self._package) and self._class[len(self._package):len(self._package) + 1] == ".":
            return self._class[len(self._package):]
        return self._class

    def flattenToString(self):
        return self._package + "/" + self._class

    def flattenToShortString(self):
        return self._package + "/" + self.getShortClassName()

    @staticmethod
    def unflattenFromString(text):
        package, separator, name = text.partition("/")
        if not separator or not name:
            return None
        return ComponentName(package, package + name if name.startswith(".") else name)

    @staticmethod
    def createRelative(package, class_name):
        if not class_name:
            raise IllegalArgumentException("class name cannot be empty")
        return ComponentName(package, package + class_name if class_name.startswith(".") else class_name)

    def __eq__(self, other):
        return isinstance(other, ComponentName) and (self._package, self._class) == (other._package, other._class)

    def __hash__(self):
        return hash((self._package, self._class))

    def hashCode(self):
        return _l.i32(_l.string_hash(self._package) + _l.string_hash(self._class))

    def compareTo(self, other):
        return _l.String(self._package).compareTo(other._package) or _l.String(self._class).compareTo(other._class)

    def toShortString(self):
        return "{" + self._package + "/" + self._class + "}"

    def toString(self):
        return "ComponentInfo{" + self._package + "/" + self._class + "}"

    def to_bridge(self):
        return self.flattenToString()


MalformedMimeTypeException = _l._throwable("MalformedMimeTypeException", _l.Exception_)


class IntentFilter(Object):
    """Action/category/data description. Matching against a live ``Intent`` belongs to the host."""
    SYSTEM_HIGH_PRIORITY, SYSTEM_LOW_PRIORITY = 1000, -1000
    MalformedMimeTypeException = MalformedMimeTypeException

    def __init__(self, *args):
        self._actions, self._categories, self._schemes, self._types, self._priority = [], [], [], [], 0
        if len(args) == 1 and isinstance(args[0], IntentFilter):
            source = args[0]
            self._actions, self._categories = list(source._actions), list(source._categories)
            self._schemes, self._types, self._priority = list(source._schemes), list(source._types), source._priority
        elif args:
            if len(args) > 2:
                raise TypeError("IntentFilter takes (), (action), (action, dataType) or (IntentFilter)")
            self.addAction(args[0])
            if len(args) == 2:
                self.addDataType(args[1])

    @staticmethod
    def create(action, data_type):
        try:
            return IntentFilter(action, data_type)
        except MalformedMimeTypeException as error:
            raise _l.RuntimeException("Bad MIME type", error) from error

    def _add(self, values, value):
        if value is None:
            raise NullPointerException()
        if value not in values:
            values.append(str(value))

    def addAction(self, action):
        self._add(self._actions, action)

    def countActions(self):
        return len(self._actions)

    def getAction(self, index):
        return self._actions[index]

    def hasAction(self, action):
        return action in self._actions

    def matchAction(self, action):
        return self.hasAction(action)

    def actionsIterator(self):
        from . import java_util
        return java_util.Iterator(self._actions)

    def addCategory(self, category):
        self._add(self._categories, category)

    def countCategories(self):
        return len(self._categories)

    def getCategory(self, index):
        return self._categories[index]

    def hasCategory(self, category):
        return category in self._categories

    def categoriesIterator(self):
        from . import java_util
        return java_util.Iterator(self._categories) if self._categories else None

    def addDataScheme(self, scheme):
        self._add(self._schemes, scheme)

    def countDataSchemes(self):
        return len(self._schemes)

    def getDataScheme(self, index):
        return self._schemes[index]

    def hasDataScheme(self, scheme):
        return scheme in self._schemes

    def addDataType(self, data_type):
        main, separator, sub = data_type.partition("/")
        if not main or separator and not sub:
            raise MalformedMimeTypeException(data_type)
        if not separator:
            # Android accepts a bare top-level type as "type/*".
            data_type = main
        self._add(self._types, data_type)

    def countDataTypes(self):
        return len(self._types)

    def getDataType(self, index):
        return self._types[index]

    def hasDataType(self, data_type):
        main = data_type.partition("/")[0]
        return any(item in (data_type, main, main + "/*", "*", "*/*") for item in self._types)

    def setPriority(self, priority):
        self._priority = priority

    def getPriority(self):
        return self._priority


class DialogInterface(Object):
    """Button constants and listener interfaces; a dialog itself is a host or UI-layer object."""
    BUTTON_POSITIVE, BUTTON_NEGATIVE, BUTTON_NEUTRAL = -1, -2, -3
    BUTTON1, BUTTON2, BUTTON3 = -1, -2, -3

    def cancel(self):
        raise _l.missing_member(type(self), "cancel")

    def dismiss(self):
        raise _l.missing_member(type(self), "dismiss")


def _listener(name, method):
    def unimplemented(self, *args):
        raise _l.missing_member(type(self), method)

    unimplemented.__name__ = method
    listener = _l.JavaMeta(name, (Object,), {"__module__": __name__, "__qualname__": "DialogInterface." + name,
                                             method: unimplemented})
    setattr(DialogInterface, name, listener)
    return listener


_LISTENERS = {name: _listener(name, method) for name, method in (
    ("OnClickListener", "onClick"), ("OnDismissListener", "onDismiss"), ("OnCancelListener", "onCancel"),
    ("OnShowListener", "onShow"), ("OnKeyListener", "onKey"), ("OnMultiChoiceClickListener", "onClick"))}


# Android constants of classes the host adapts: pure data, whatever the adapter does with them.
HOST_MEMBERS = {"android.content.Intent": {
    "ACTION_GET_CONTENT": "android.intent.action.GET_CONTENT", "ACTION_PICK": "android.intent.action.PICK",
    "ACTION_OPEN_DOCUMENT": "android.intent.action.OPEN_DOCUMENT",
    "ACTION_CREATE_DOCUMENT": "android.intent.action.CREATE_DOCUMENT",
    "ACTION_OPEN_DOCUMENT_TREE": "android.intent.action.OPEN_DOCUMENT_TREE",
    "ACTION_SEND_MULTIPLE": "android.intent.action.SEND_MULTIPLE",
    "ACTION_BATTERY_CHANGED": "android.intent.action.BATTERY_CHANGED",
    "CATEGORY_OPENABLE": "android.intent.category.OPENABLE", "CATEGORY_DEFAULT": "android.intent.category.DEFAULT",
    "CATEGORY_BROWSABLE": "android.intent.category.BROWSABLE",
    "EXTRA_STREAM": "android.intent.extra.STREAM", "EXTRA_TEXT": "android.intent.extra.TEXT",
    "EXTRA_TITLE": "android.intent.extra.TITLE", "EXTRA_SUBJECT": "android.intent.extra.SUBJECT",
    "EXTRA_MIME_TYPES": "android.intent.extra.MIME_TYPES", "EXTRA_ALLOW_MULTIPLE": "android.intent.extra.ALLOW_MULTIPLE",
    "FLAG_GRANT_READ_URI_PERMISSION": 0x00000001, "FLAG_GRANT_WRITE_URI_PERMISSION": 0x00000002,
    "FLAG_GRANT_PERSISTABLE_URI_PERMISSION": 0x00000040, "FLAG_ACTIVITY_CLEAR_TASK": 0x00008000,
    "FLAG_ACTIVITY_CLEAR_TOP": 0x04000000, "FLAG_ACTIVITY_SINGLE_TOP": 0x20000000,
    "FLAG_ACTIVITY_NO_HISTORY": 0x40000000,
}}

CLASSES = _l.register({
    "android.content.ClipData": ClipData,
    "android.content.ClipData$Item": _Item,
    "android.content.ClipDescription": ClipDescription,
    "android.content.ContentValues": ContentValues,
    "android.content.ComponentName": ComponentName,
    "android.content.IntentFilter": IntentFilter,
    "android.content.IntentFilter$MalformedMimeTypeException": MalformedMimeTypeException,
    "android.content.DialogInterface": DialogInterface,
    **{"android.content.DialogInterface$" + name: listener for name, listener in _LISTENERS.items()},
})
