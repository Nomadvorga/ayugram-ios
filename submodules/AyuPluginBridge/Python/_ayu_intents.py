"""Android intents the bridge launches through ``intents.launch`` (see ``protocol.md``).

Three intent shapes have an iOS counterpart: a document picker (``ACTION_GET_CONTENT`` and
``ACTION_OPEN_DOCUMENT`` with ``startActivityForResult``), the share sheet (``ACTION_SEND`` and
``ACTION_SEND_MULTIPLE``, usually inside ``Intent.createChooser``) and opening a link
(``ACTION_VIEW`` of an ``http``, ``https`` or ``tg`` URI). ``ACTION_VIEW`` of a file the bridge may
share shows the same sheet as sharing it: there the user picks the application that opens it, as
in Android's "Open with". Every other shape is refused by name.

Picked documents are copies the host made into the plugin's part of the cache directory. The SDK
names each with a ``content://`` URI of its own authority and keeps the table that
``ContentResolver`` reads; the copies are removed when the plugin is unloaded.
"""
from __future__ import annotations

import ast
import os
import re
import urllib.parse

OPERATION = "intents.launch"
# Reserved: an Android intent action nothing on iOS can serve. No host declares it.
ANDROID_ONLY = "intents.android_only"
PACKAGE_NAME = "com.exteragram.messenger"
PROVIDER_AUTHORITY = PACKAGE_NAME + ".provider"
DOCUMENTS_AUTHORITY = PACKAGE_NAME + ".bridge.documents"

ACTION_VIEW = "android.intent.action.VIEW"
ACTION_SEND = "android.intent.action.SEND"
ACTION_SEND_MULTIPLE = "android.intent.action.SEND_MULTIPLE"
ACTION_GET_CONTENT = "android.intent.action.GET_CONTENT"
ACTION_OPEN_DOCUMENT = "android.intent.action.OPEN_DOCUMENT"
ACTION_CHOOSER = "android.intent.action.CHOOSER"
EXTRA_INTENT = "android.intent.extra.INTENT"
EXTRA_TITLE = "android.intent.extra.TITLE"
EXTRA_TEXT = "android.intent.extra.TEXT"
EXTRA_STREAM = "android.intent.extra.STREAM"
EXTRA_MIME_TYPES = "android.intent.extra.MIME_TYPES"
EXTRA_ALLOW_MULTIPLE = "android.intent.extra.ALLOW_MULTIPLE"
EXTRA_LOCAL_ONLY = "android.intent.extra.LOCAL_ONLY"
CATEGORY_OPENABLE = "android.intent.category.OPENABLE"
CATEGORY_DEFAULT = "android.intent.category.DEFAULT"
CATEGORY_BROWSABLE = "android.intent.category.BROWSABLE"
FLAG_GRANT_READ_URI_PERMISSION = 0x00000001
RESULT_OK, RESULT_CANCELED = -1, 0

# Actions that start an Android system screen or another application's activity. A source that
# builds an intent with one is blocked before it runs; the constants themselves stay plain data.
ANDROID_ONLY_ACTIONS = {
    "ACTION_CREATE_DOCUMENT": "android.intent.action.CREATE_DOCUMENT",
    "ACTION_OPEN_DOCUMENT_TREE": "android.intent.action.OPEN_DOCUMENT_TREE",
    "ACTION_PICK": "android.intent.action.PICK",
    "ACTION_INSTALL_PACKAGE": "android.intent.action.INSTALL_PACKAGE",
    "ACTION_UNINSTALL_PACKAGE": "android.intent.action.UNINSTALL_PACKAGE",
    "ACTION_DELETE": "android.intent.action.DELETE",
    "ACTION_DIAL": "android.intent.action.DIAL",
    "ACTION_CALL": "android.intent.action.CALL",
    "ACTION_SENDTO": "android.intent.action.SENDTO",
    "ACTION_EDIT": "android.intent.action.EDIT",
    "ACTION_INSERT": "android.intent.action.INSERT",
    "ACTION_WEB_SEARCH": "android.intent.action.WEB_SEARCH",
}
_ANDROID_ONLY_VALUES = frozenset(ANDROID_ONLY_ACTIONS.values())

MAX_TYPES = 16
MAX_SHARE_FILES = 16
MAX_TEXT_BYTES = 65_536
MAX_URL_BYTES = 8_192
MAX_DOCUMENTS = 32
_MIME = re.compile(r"(?:\*/\*|[a-z0-9!#$&^_.+-]{1,63}/(?:\*|[a-z0-9!#$&^_.+-]{1,63}))\Z")
_VIEW_SCHEMES = ("http", "https", "tg")
_PICK_EXTRAS = frozenset({EXTRA_MIME_TYPES, EXTRA_ALLOW_MULTIPLE, EXTRA_LOCAL_ONLY, EXTRA_TITLE})
_SHARE_EXTRAS = frozenset({EXTRA_TEXT, EXTRA_STREAM, EXTRA_TITLE})


def _unsupported(message):
    from ayu_bridge import UnsupportedAPI
    return UnsupportedAPI(message)


def _lang():
    from _ayu_javalib import java_lang
    return java_lang


def _log(message):
    from android_utils import log
    log(message)


def uri_text(uri, what="uri"):
    """The string form of a ``Uri`` a plugin passed."""
    if uri is None:
        raise _lang().NullPointerException(what + " is null")
    if type(uri).__name__ == "RemoteObject" and uri._class_name == "android.net.Uri":
        text = uri.toString()
    elif not isinstance(uri, (str, bytes, type)) and callable(getattr(uri, "toString", None)):
        text = uri.toString()
    else:
        raise TypeError(f"Expected an android.net.Uri, got {type(uri).__name__}")
    if not isinstance(text, str):
        raise TypeError("Uri.toString() did not return a string")
    return text


# --- storage the bridge may hand to other applications ----------------------------------------

def _roots():
    """``(name, directory)`` of the plugin storage ``FileProvider`` serves, the most specific first.

    The names of the reference client's ``provider_paths.xml`` where it has the same directory;
    ``files`` covers the rest of the bridge's files directory.
    """
    import file_utils
    files = file_utils._location("Library", "Application Support", file_utils._STORAGE_NAME)
    cache = file_utils._location("Library", "Caches", file_utils._STORAGE_NAME)
    return tuple((name, os.path.join(files, name)) for name in ("plugins", "logs", "cache", "temp")) + (
        ("files", files), ("shared_cache", cache))


def _inside(path, directory):
    try:
        return os.path.commonpath([os.path.realpath(path), os.path.realpath(directory)]) == os.path.realpath(directory)
    except ValueError:
        return False


def provider_uri(authority, path):
    """``FileProvider.getUriForFile``: the ``content://`` text for a file of the plugin storage."""
    lang = _lang()
    if authority != PROVIDER_AUTHORITY:
        raise lang.IllegalArgumentException("Couldn't find meta-data for provider with authority " + lang.jstr(authority))
    absolute = os.path.abspath(path)
    for name, directory in _roots():
        if absolute != directory and _inside(absolute, directory):
            relative = os.path.relpath(os.path.realpath(absolute), os.path.realpath(directory))
            return f"content://{authority}/{name}/" + urllib.parse.quote(relative, safe="/")
    raise lang.IllegalArgumentException("Failed to find configured root that contains " + absolute)


def _provider_path(parts):
    """The file a ``FileProvider`` URI of this bridge names, or None."""
    segments = [urllib.parse.unquote(item) for item in parts.path.split("/") if item]
    directory = dict(_roots()).get(segments[0]) if len(segments) >= 2 else None
    if directory is None or any(item in ("..", ".") or "\0" in item for item in segments[1:]):
        return None
    path = os.path.join(directory, *segments[1:])
    return path if _inside(path, directory) else None


def _documents():
    """Picked documents of the current plugin generation by URI text."""
    return _lang().scoped_store("intent_documents")


def resolve(text):
    """What a URI names for ``ContentResolver``: ``(kind, record)`` or None when no provider answers.

    ``("document", record)`` is a picked document, ``("provider", record)`` a ``FileProvider`` file
    and ``("file", record)`` a ``file://`` path; ``record`` has ``path`` and ``name``.
    """
    try:
        parts = urllib.parse.urlsplit(text)
    except ValueError:
        return None
    if parts.scheme == "content":
        if parts.netloc == DOCUMENTS_AUTHORITY:
            record = _documents().get(text)
            return None if record is None else ("document", record)
        if parts.netloc == PROVIDER_AUTHORITY:
            path = _provider_path(parts)
            return None if path is None else ("provider", {"path": path, "name": os.path.basename(path)})
        return None
    if parts.scheme == "file" and parts.netloc in ("", "localhost"):
        path = urllib.parse.unquote(parts.path)
        return ("file", {"path": path, "name": os.path.basename(path)}) if os.path.isabs(path) else None
    return None


def _shared_path(uri, what="EXTRA_STREAM"):
    """The local file an ``EXTRA_STREAM`` or data URI names, when the bridge may share it."""
    text = uri_text(uri, what)
    found = resolve(text)
    if found is not None:
        kind, record = found
        path = record["path"]
        if kind != "file" or any(path != directory and _inside(path, directory) for _, directory in _roots()):
            if not os.path.isfile(path):
                from _ayu_javalib import java_io
                raise java_io.FileNotFoundException(path + " (No such file or directory)")
            return os.path.realpath(path)
    raise _unsupported(what + " names a file outside the plugin storage: only a picked document, a "
                       "FileProvider URI or a file of the plugin directories can be shared")


# --- launching --------------------------------------------------------------------------------

def _mime_types(target, action):
    listed = target._extras.get(EXTRA_MIME_TYPES)
    if isinstance(listed, (str, bytes)):
        raise TypeError("EXTRA_MIME_TYPES must be a String[]")
    try:
        # A ``String[]`` is a Python list or a host array; both iterate.
        types = [] if listed is None else list(listed)
    except TypeError:
        raise TypeError("EXTRA_MIME_TYPES must be a String[]") from None
    if not types and target.getType() is not None:
        types = [target.getType()]
    if not types:
        from _ayu_javalib import android_intents
        raise android_intents.ActivityNotFoundException(
            "No Activity found to handle Intent { act=" + action + " }: a document picker needs a MIME type")
    found = []
    for item in types:
        text = item.lower() if isinstance(item, str) else None
        if text is None or not _MIME.match(text):
            raise _unsupported(f"Intent {action} with an invalid MIME type")
        if text not in found:
            found.append(text)
    if len(found) > MAX_TYPES:
        raise _unsupported(f"Intent {action} with more than {MAX_TYPES} MIME types")
    return found


def plan(intent, for_result):
    """The ``intents.launch`` arguments of an intent, without its context and callback.

    Raises ``UnsupportedAPI`` naming the action (or the component, package, category or extra)
    for a shape the bridge cannot launch.
    """
    target = intent
    if intent.getAction() == ACTION_CHOOSER:
        target = intent._extras.get(EXTRA_INTENT)
        if not isinstance(target, type(intent)):
            raise _unsupported("Intent android.intent.action.CHOOSER without a target intent cannot be launched")
    action = target.getAction()
    name = "Intent " + _lang().jstr(action)
    if target.getComponent() is not None:
        raise _unsupported(f"{name} for the Android component {target.getComponent().flattenToShortString()} "
                           "cannot be launched: activities and services do not exist on iOS")
    package = target.getPackage()
    if package is not None and package != PACKAGE_NAME:
        raise _unsupported(f"{name} for the Android package {package} cannot be launched: no such application exists on iOS")
    categories = set(target._categories)
    if action in (ACTION_GET_CONTENT, ACTION_OPEN_DOCUMENT):
        if not for_result:
            raise _unsupported(f"{name} needs startActivityForResult: a picker without a result has no use")
        for item in sorted(categories - {CATEGORY_OPENABLE, CATEGORY_DEFAULT}):
            raise _unsupported(f"{name} with the category {item} cannot be launched")
        for item in sorted(set(target._extras) - _PICK_EXTRAS):
            raise _unsupported(f"{name} with the extra {item} cannot be launched")
        if target.getData() is not None:
            raise _unsupported(f"{name} with a data URI cannot be launched")
        multiple = target._extras.get(EXTRA_ALLOW_MULTIPLE, False)
        if type(multiple) is not bool:
            raise TypeError("EXTRA_ALLOW_MULTIPLE must be a boolean")
        return {"kind": "pick", "types": _mime_types(target, action), "multiple": multiple}
    if for_result:
        raise _unsupported(f"{name} cannot be started for a result: only document pickers report one")
    if action in (ACTION_SEND, ACTION_SEND_MULTIPLE):
        for item in sorted(categories - {CATEGORY_DEFAULT}):
            raise _unsupported(f"{name} with the category {item} cannot be launched")
        for item in sorted(set(target._extras) - _SHARE_EXTRAS):
            raise _unsupported(f"{name} with the extra {item} cannot be launched")
        request = {"kind": "share"}
        text = target._extras.get(EXTRA_TEXT)
        if text is not None:
            text = _lang()._text(text, "EXTRA_TEXT")
            if len(text.encode("utf-8", "surrogatepass")) > MAX_TEXT_BYTES:
                from ayu_bridge import BridgeError
                raise BridgeError("RESOURCE_LIMIT", "EXTRA_TEXT is too long to share")
            if text:
                request["text"] = text
        stream = target._extras.get(EXTRA_STREAM)
        if stream is not None:
            streams = list(stream) if action == ACTION_SEND_MULTIPLE and isinstance(stream, (list, tuple)) else [stream]
            if len(streams) > MAX_SHARE_FILES:
                from ayu_bridge import BridgeError
                raise BridgeError("RESOURCE_LIMIT", f"More than {MAX_SHARE_FILES} files cannot be shared at once")
            files = list(dict.fromkeys(_shared_path(item) for item in streams))
            if files:
                request["files"] = files
        if len(request) == 1:
            raise _unsupported(f"{name} without EXTRA_TEXT or EXTRA_STREAM has nothing to share")
        return request
    if action == ACTION_VIEW:
        for item in sorted(categories - {CATEGORY_DEFAULT, CATEGORY_BROWSABLE}):
            raise _unsupported(f"{name} with the category {item} cannot be launched")
        for item in sorted(target._extras):
            raise _unsupported(f"{name} with the extra {item} cannot be launched")
        if target.getData() is None:
            from _ayu_javalib import android_intents
            raise android_intents.ActivityNotFoundException("No Activity found to handle Intent { act=" + action + " }")
        url = uri_text(target.getData(), "data")
        scheme = url.partition(":")[0].lower()
        if scheme in ("content", "file"):
            return {"kind": "share", "files": [_shared_path(target.getData(), "The data URI")]}
        if target.getType() is not None:
            raise _unsupported(f"{name} of a file cannot be launched: iOS has no viewer application to hand it to")
        if scheme not in _VIEW_SCHEMES:
            raise _unsupported(f"{name} of a {scheme}: URI cannot be launched: only http, https and tg links open")
        if len(url.encode("utf-8", "surrogatepass")) > MAX_URL_BYTES:
            from ayu_bridge import BridgeError
            raise BridgeError("RESOURCE_LIMIT", "The URI is too long to open")
        return {"kind": "view", "url": url}
    raise _unsupported(f"{name} cannot be launched: it has no iOS counterpart in this bridge")


def can_launch(intent):
    """Whether ``startActivity`` or ``startActivityForResult`` would accept the intent."""
    from ayu_bridge import BridgeError
    for for_result in (False, True):
        try:
            plan(intent, for_result)
            return True
        except (BridgeError, TypeError, _lang().Exception_):
            continue
    return False


def _activity(context):
    """The host reference of what a plugin called ``startActivity`` on, and the activity context for a hook."""
    reference = context.to_bridge() if hasattr(type(context), "to_bridge") else context
    if type(reference).__name__ != "RemoteObject":
        raise TypeError("startActivity needs an Android Context")
    if reference._class_name == "android.content.Context":
        return reference, reference
    return reference, reference.getParentActivity()


def start(context, intent, request_code=None):
    """``Context.startActivity(intent)``, or ``startActivityForResult(intent, request_code)``."""
    import _ayu_operations
    from ayu_bridge import ProtocolError, runtime
    scope = runtime.require()
    _ayu_operations.require(OPERATION, "Context.startActivity")
    if intent is None:
        raise _lang().NullPointerException("intent is null")
    from _ayu_javalib import android_intents
    if not isinstance(intent, android_intents.Intent):
        raise TypeError(f"Expected an android.content.Intent, got {type(intent).__name__}")
    if request_code is not None and (type(request_code) is not int or not _lang().fits_int(request_code)):
        raise TypeError("requestCode must be a 32-bit int")
    # Android reports no result for a negative request code.
    for_result = request_code is not None and request_code >= 0
    request = plan(intent, for_result)
    reference, activity = _activity(context)
    request["context"] = reference
    callback = None
    if request["kind"] == "pick":
        callback = runtime.callback(lambda wire: _deliver(activity, request_code, wire), once=True)
        request["callback"] = callback
    try:
        token = runtime.call(OPERATION, request)
    except BaseException:
        if callback is not None:
            scope.callbacks.pop(callback.callback_id, None)
        raise
    if not isinstance(token, str) or not token:
        raise ProtocolError("intents.launch must return a token")


def _document(token, index, wire):
    """Register one picked document and return its ``content://`` URI object."""
    from ayu_bridge import ProtocolError, runtime
    if (not isinstance(wire, dict) or set(wire) != {"path", "name", "size", "mime_type"}
            or not isinstance(wire["path"], str) or not os.path.isabs(wire["path"])
            or not isinstance(wire["name"], str) or not wire["name"] or "/" in wire["name"] or "\0" in wire["name"]
            or type(wire["size"]) is not int or wire["size"] < 0
            or not isinstance(wire["mime_type"], str) or not _MIME.match(wire["mime_type"])):
        raise ProtocolError("Host returned an invalid picked document")
    text = f"content://{DOCUMENTS_AUTHORITY}/document/{token}/{index}/" + urllib.parse.quote(wire["name"], safe="")
    _documents()[text] = dict(wire, id=f"{token}:{index}")
    return runtime.jclass("android.net.Uri").parse(text)


def _deliver(activity, request_code, wire):
    """The host's answer to a picker: build the result ``Intent`` and raise ``activity.result``."""
    import _ayu_xposed
    from ayu_bridge import ProtocolError
    from _ayu_javalib import android_content, android_intents
    if (not isinstance(wire, dict) or not set(wire) <= {"token", "result_code", "documents", "error"}
            or not isinstance(wire.get("token"), str) or not re.fullmatch(r"[A-Za-z0-9-]{1,64}", wire["token"])
            or wire.get("result_code") not in (RESULT_OK, RESULT_CANCELED) or type(wire["result_code"]) is not int
            or not isinstance(wire.get("documents"), list) or len(wire["documents"]) > MAX_DOCUMENTS
            or (wire["result_code"] == RESULT_OK) != bool(wire["documents"])
            or not isinstance(wire.get("error", ""), str)):
        raise ProtocolError("Host returned an invalid picker result")
    if wire.get("error"):
        _log("The document picker returned nothing: " + wire["error"][:128])
    data = None
    if wire["result_code"] == RESULT_OK:
        uris = [_document(wire["token"], index, item) for index, item in enumerate(wire["documents"])]
        data = android_intents.Intent()
        if len(uris) == 1:
            data.setData(uris[0])
        else:
            # Android's document UI returns several documents as ``ClipData`` and no data URI.
            types = list(dict.fromkeys(item["mime_type"] for item in wire["documents"]))
            clip = android_content.ClipData(None, types, android_content.ClipData.Item(uris[0]))
            for uri in uris[1:]:
                clip.addItem(android_content.ClipData.Item(uri))
            data.setClipData(clip)
        data.addFlags(FLAG_GRANT_READ_URI_PERMISSION)
    _ayu_xposed.fire(_ayu_xposed.ACTIVITY_RESULT, activity, [request_code, wire["result_code"], data])


# --- static preflight -------------------------------------------------------------------------

def _own_package(node):
    """Whether an argument is certainly not the name of another Android application."""
    return not (isinstance(node, ast.Constant) and isinstance(node.value, str) and node.value != PACKAGE_NAME)


def static_actions(tree):
    """What a source gives to an ``Intent`` that only Android can serve, sorted.

    Found from the AST alone: an action given to the constructor or to ``setAction`` as
    ``<anything>.ACTION_<NAME>`` of the table above, its string value, ``Settings.ACTION_<NAME>``
    or an ``android.settings.`` string; and a literal package of another application given to
    ``setPackage``, ``setClassName`` or ``ComponentName``.
    """
    found = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call) or not node.args:
            continue
        function = node.func
        name = function.attr if isinstance(function, ast.Attribute) else function.id if isinstance(function, ast.Name) else ""
        argument = node.args[0]
        if name == "setPackage" and len(node.args) == 1 and not _own_package(argument):
            found.add("package " + argument.value[:128])
        elif name in ("setClassName", "ComponentName") and len(node.args) == 2 and not _own_package(argument):
            found.add("component of the package " + argument.value[:128])
        if name not in ("Intent", "setAction"):
            continue
        if isinstance(argument, ast.Attribute) and argument.attr in ANDROID_ONLY_ACTIONS:
            found.add(ANDROID_ONLY_ACTIONS[argument.attr])
        elif isinstance(argument, ast.Attribute) and argument.attr.startswith("ACTION_") and (
                getattr(argument.value, "attr", None) or getattr(argument.value, "id", None)) == "Settings":
            found.add("Settings." + argument.attr[:128])
        elif isinstance(argument, ast.Constant) and isinstance(argument.value, str) and (
                argument.value in _ANDROID_ONLY_VALUES or argument.value.startswith("android.settings.")):
            found.add(argument.value[:128])
    return sorted(found)
