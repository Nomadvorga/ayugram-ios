"""exteraGram ``client_utils`` over the host's Telegram operations (``protocol-telegram.md``).

Requests, sending, editing and the controller getters use the typed ``telegram.*``
operations when the host declares them and Python-local controller classes when those are
usable. Otherwise each helper keeps forwarding to the host's ``client.call`` adapter of the
same name, which rejects what it does not implement; nothing is answered locally.
"""
import contextlib
import contextvars
import os

import _ayu_javalib
import _ayu_operations
from ayu_bridge import BridgeError, DynamicProxy, JavaClass, ProtocolError, RemoteObject, UnsupportedAPI, runtime

STAGE_QUEUE = "stageQueue"
GLOBAL_QUEUE = "globalQueue"
CACHE_CLEAR_QUEUE = "cacheClearQueue"
SEARCH_QUEUE = "searchQueue"
PHONE_BOOK_QUEUE = "phoneBookQueue"
THEME_QUEUE = "themeQueue"
EXTERNAL_NETWORK_QUEUE = "externalNetworkQueue"
PLUGINS_QUEUE = "pluginsQueue"


_hook_account = contextvars.ContextVar("ayu_hook_account", default=None)


def _account(account):
    if account is not None and (type(account) is not int or not 0 <= account < 2**63):
        raise ValueError("Account must be a nonnegative signed 64-bit integer")
    return account


def _int64(value, name):
    """Validate an Android ``long`` argument without accepting Python bools."""
    if type(value) is not int:
        raise TypeError(f"{name} must be an integer")
    if not -(2**63) <= value < 2**63:
        raise ValueError(f"{name} must fit in a signed 64-bit integer")
    return value


def get_hook_account():
    scope = runtime.require()
    binding = _hook_account.get()
    return binding[1] if binding is not None and binding[0] is scope else None


@contextlib.contextmanager
def account_scope(account):
    scope = runtime.require()
    token = _hook_account.set((scope, _account(account)))
    try:
        yield
    finally:
        _hook_account.reset(token)


def _with_account(function, account):
    scope = runtime.require()

    def callback(*args):
        runtime.require(scope)
        with account_scope(account):
            return function(*args)

    return callback


def run_on_queue(fn, queue_name=PLUGINS_QUEUE, delay=0):
    if not callable(fn):
        raise TypeError("Expected a callable")
    return runtime.schedule(_with_account(fn, get_hook_account()), queue=queue_name, delay=delay)


def run_on_ui_thread(function, delay=0):
    # Python callbacks still execute on the host's serial Python queue; native UI
    # operations produced by them are asynchronously marshalled to main.
    return run_on_queue(function, queue_name="main", delay=delay)


def _call(name, *args, **kwargs):
    return runtime.call("client.call", {"name": name, "args": list(args), "kwargs": kwargs})


def log(data):
    """Expose the reference SDK logger through the existing owned log adapter."""
    from android_utils import log as write_log
    return write_log(data)


def _local_class(java_name):
    """The usable Python-local class of that name, or None when the host's adapter serves it."""
    runtime.require()
    if java_name in runtime.capabilities.get("local_classes", ()):
        return _ayu_javalib.local_class(java_name)
    return None


def _resolve_account(account, helper):
    """Android's rule: an explicit account, else the account selected in the UI."""
    if account is not None:
        return _account(account)
    selected = get_selected_account()
    hook_account = get_hook_account()
    if hook_account is not None and hook_account != selected:
        key = (runtime.require().generation, helper, hook_account, selected)
        if key not in _warned_account_mismatches:
            if len(_warned_account_mismatches) >= 256:
                _warned_account_mismatches.clear()
            _warned_account_mismatches.add(key)
            log(f"{helper}() is using account {selected} because it is the one selected in the UI, "
                f"but it was called while handling account {hook_account}. "
                f"Pass account={hook_account}, or use get_client({hook_account}), if you meant that account. "
                f"Logged once per helper.")
    return selected


_warned_account_mismatches = set()


def _controller(helper, java_name, account):
    cls = _local_class(java_name)
    if cls is not None:
        return cls.getInstance(_resolve_account(account, helper))
    return _call(helper, account=_account(account))


def get_queue_by_name(queue_name):
    from _ayu_javalib import concurrency
    try:
        return concurrency.named_queue(queue_name)
    except BridgeError as error:
        if error.code != "UNSUPPORTED_API":
            raise
        log(f"Error getting queue '{queue_name}': {error.message}")
        return None


def get_last_fragment():
    cls = _local_class("org.telegram.ui.ActionBar.BaseFragment")
    if cls is not None:
        return cls._ayu_current()
    return _call("get_last_fragment")


def get_selected_account():
    result = _call("get_selected_account")
    if type(result) is not int or not 0 <= result < 2**63:
        raise ProtocolError("Host returned an invalid selected account")
    return result


def get_messages_controller(account=None):
    return _controller("get_messages_controller", "org.telegram.messenger.MessagesController", account)


def get_user_config(account=None):
    return _call("get_user_config", account=_account(account))


def get_connections_manager(account=None):
    return _controller("get_connections_manager", "org.telegram.tgnet.ConnectionsManager", account)


def get_send_messages_helper(account=None):
    return _controller("get_send_messages_helper", "org.telegram.messenger.SendMessagesHelper", account)


def get_media_data_controller(account=None):
    return _controller("get_media_data_controller", "org.telegram.messenger.MediaDataController", account)


def get_notification_center(account=None):
    runtime.require()
    _account(account)
    if account is not None:
        raise UnsupportedAPI("Account-specific notification centers require a native adapter")
    # The existing adapter is explicitly a global notification center.
    return _call("get_notification_center")


def get_account_instance(account=None):
    return _controller("get_account_instance", "org.telegram.messenger.AccountInstance", account)


def get_contacts_controller(account=None):
    return _call("get_contacts_controller", account=_account(account))


def get_location_controller(account=None):
    return _call("get_location_controller", account=_account(account))


def get_notifications_controller(account=None):
    return _call("get_notifications_controller", account=_account(account))


def get_messages_storage(account=None):
    return _controller("get_messages_storage", "org.telegram.messenger.MessagesStorage", account)


def get_file_loader(account=None):
    return _controller("get_file_loader", "org.telegram.messenger.FileLoader", account)


def get_secret_chat_helper(account=None):
    return _call("get_secret_chat_helper", account=_account(account))


def get_download_controller(account=None):
    return _call("get_download_controller", account=_account(account))


def get_notifications_settings(account=None):
    return _call("get_notifications_settings", account=_account(account))


def get_media_controller():
    cls = _local_class("org.telegram.messenger.MediaController")
    if cls is not None:
        return cls.getInstance()
    return _call("get_media_controller")


# ``SendMessagesHelper.SendMessageParams`` fields and their Java defaults, as the Android SDK lists them.
SEND_MESSAGE_DEFAULTS = {
    "peer": 0, "message": None, "caption": None, "location": None, "photo": None, "document": None,
    "videoEditedInfo": None, "user": None, "game": None, "poll": None, "pollSendParams": None, "pollIndex": 0,
    "todo": None, "invoice": None, "mediaWebPage": None, "cover": None, "path": None, "replyToMsg": None,
    "replyToTopMsg": None, "webPage": None, "retryMessageObject": None, "entities": None, "replyMarkup": None,
    "params": None, "searchLinks": True, "notify": True, "updateStickersOrder": False, "hasMediaSpoilers": False,
    "invert_media": False, "sendingHighQuality": False, "scheduleDate": 0, "scheduleRepeatPeriod": 0, "ttl": 0,
    "effect_id": 0, "stars": 0, "payStars": 0, "dice_stake": 0, "monoForumPeer": 0, "quick_reply_shortcut_id": 0,
    "quick_reply_shortcut": None, "parentObject": None, "sendAnimationData": None, "replyToStoryItem": None,
    "sendingStory": None, "replyQuote": None, "suggestionParams": None, "isLivePhoto": False,
    "livePhotoTimestamp": 0, "ephemeralReceiverBotId": 0, "richMessage": None, "richMessageInputUsers": None,
}
_ATTACH_KINDS = ("photo", "document", "video", "audio")


def _parse_mode(parse_mode):
    if parse_mode is not None:
        raise UnsupportedAPI("Text parse_mode requires a native formatting adapter")


def _parsed(final, parse_mode):
    """Android's ``parse_mode`` step: entities for the message, else for the caption."""
    if not parse_mode:
        return {}
    if not isinstance(parse_mode, str) or parse_mode.lower() not in ("html", "markdown"):
        raise ValueError(f"Invalid parse mode: {parse_mode}. Must be 'html' or 'markdown'.")
    from extera_utils.text_formatting import parse_text
    if final.get("message"):
        return parse_text(final["message"], parse_mode)
    if final.get("caption"):
        return parse_text(final["caption"], parse_mode, True)
    return {}


def _send_wire(params, parse_mode, attach=None):
    """Non-default ``SendMessageParams`` fields in wire form; the host rejects what it cannot send."""
    final = dict(params)
    final.update(_parsed({**SEND_MESSAGE_DEFAULTS, **params}, parse_mode))
    wire = {}
    for key, value in final.items():
        if not isinstance(key, str) or key not in SEND_MESSAGE_DEFAULTS:
            # Android logs a field it cannot set and sends the rest.
            log(f"Could not set parameter '{key}': SendMessageParams has no such field")
            continue
        default = SEND_MESSAGE_DEFAULTS[key]
        if value is None or type(value) is type(default) and value == default:
            continue
        if key == "params":
            if not isinstance(value, dict):
                raise TypeError("params must be a dictionary")
            value = {str(name): str(item) for name, item in value.items()}
        elif key in ("entities", "richMessageInputUsers"):
            value = list(value)
        wire[key] = value
    _int64(wire.get("peer", 0), "peer")
    if attach is not None:
        wire["attach"] = attach
    return wire


def send_message(params: dict, parse_mode: str = None, *, account=None):
    runtime.require()
    if not isinstance(params, dict):
        raise TypeError("send_message requires a parameter dictionary")
    if "peer" in params:
        _int64(params["peer"], "peer")
    if _ayu_operations.declared("telegram.send_message"):
        runtime.call("telegram.send_message", {"account": _resolve_account(account, "send_message"),
                                                "params": _send_wire(params, parse_mode)})
        return None
    _parse_mode(parse_mode)
    # Keep the dictionary intact: the host must reject every unsupported field.
    return _call("send_message", params, account=_account(account))


def send_text(peer: int, text: str, *, account=None, parse_mode=None, **kwargs):
    runtime.require()
    _int64(peer, "peer")
    if not isinstance(text, str):
        raise TypeError("text must be a string")
    params = {"peer": peer, "message": text}
    params.update(kwargs)
    return send_message(params, parse_mode, account=account)


def _send_file(helper, kind, peer, file_path, caption, account, parse_mode, kwargs, **extra):
    runtime.require()
    _int64(peer, "peer")
    if not isinstance(file_path, str) or not file_path:
        raise TypeError("file_path must be a nonempty string")
    if not isinstance(caption, str):
        raise TypeError("caption must be a string")
    _ayu_operations.require("telegram.send_message", helper)
    params = {"peer": peer, "path": file_path, "caption": caption}
    params.update(extra)
    params.update(kwargs)
    # The host reads the file and prepares the media (sizes, thumbnail, duration) itself.
    runtime.call("telegram.send_message", {"account": _resolve_account(account, helper),
                                            "params": _send_wire(params, parse_mode, {"kind": kind})})
    return None


def send_photo(peer: int, file_path: str, caption: str = "", high_quality: bool = False,
               *, account=None, parse_mode=None, **kwargs):
    if type(high_quality) is not bool:
        raise TypeError("high_quality must be a bool")
    return _send_file("send_photo", "photo", peer, file_path, caption, account, parse_mode, kwargs,
                      sendingHighQuality=high_quality)


def send_document(peer: int, file_path: str, caption: str = "", *, account=None,
                  parse_mode=None, **kwargs):
    return _send_file("send_document", "document", peer, file_path, caption, account, parse_mode, kwargs)


def send_video(peer: int, file_path: str, caption: str = "", *, account=None,
               parse_mode=None, **kwargs):
    return _send_file("send_video", "video", peer, file_path, caption, account, parse_mode, kwargs)


def send_audio(peer: int, file_path: str, caption: str = "", *, account=None,
               parse_mode=None, **kwargs):
    return _send_file("send_audio", "audio", peer, file_path, caption, account, parse_mode, kwargs)


_EDIT_KINDS = {".jpg": "photo", ".jpeg": "photo", ".png": "photo", ".webp": "photo", ".mp4": "video",
               ".mov": "video", ".mkv": "video", ".mp3": "audio", ".m4a": "audio", ".ogg": "audio",
               ".opus": "audio", ".flac": "audio"}


def edit_message(message_obj, text=None, file_path=None, with_spoiler=False,
                 *, account=None, parse_mode=None, **kwargs):
    runtime.require()
    if not _ayu_operations.declared("telegram.edit_message"):
        _parse_mode(parse_mode)
        if file_path is not None or with_spoiler is not False or kwargs:
            raise UnsupportedAPI("Media, spoilers and edit options require a native edit adapter")
        return _call("edit_message", message_obj, text, account=_account(account))
    message_class = runtime.jclass("org.telegram.messenger.MessageObject")
    if not isinstance(message_class, type) or not isinstance(message_obj, message_class):
        log("'message_obj' must be a valid MessageObject instance.")
        return None
    if text is None and file_path is None:
        log("edit_message called with no changes (text or file_path). Cancelled.")
        return None
    if file_path is not None and not (isinstance(file_path, str) and os.path.exists(file_path)):
        log(f"Media file not found at path: {file_path}")
        return None
    arguments = {"account": _resolve_account(account, "edit_message"), "dialog_id": message_obj.getDialogId(),
                 "message_id": message_obj.getId()}
    if text is not None:
        if not isinstance(text, str):
            raise TypeError("text must be a string")
        parsed = _parsed({"message": text}, parse_mode) if text and parse_mode else {"message": text, "entities": []}
        arguments["text"] = parsed["message"]
        arguments["entities"] = list(parsed.get("entities") or [])
    if file_path:
        arguments["attach"] = {"kind": _EDIT_KINDS.get(os.path.splitext(file_path)[1].lower(), "document"),
                               "path": file_path, "spoiler": bool(with_spoiler)}
    if kwargs:
        arguments["params"] = {str(key): str(value) for key, value in kwargs.items()}
    runtime.call("telegram.edit_message", arguments)
    log(f"Edit request sent for message {message_obj.getId()} in dialog {message_obj.getDialogId()}.")
    return None


class _ClientCallbackProxy(DynamicProxy):
    """Resolve native interfaces only within a plugin's active generation."""
    def __init__(self, interface_name, method_name):
        from java import dynamic_proxy, jclass

        interface = jclass(interface_name)
        if not isinstance(interface, JavaClass):
            # A Python-local interface: the delegate is called by Python-local classes only.
            super().__init__()
            self._ayu_interfaces, self._ayu_interfaces_methods, self._ayu_local = (), (method_name,), True
            return
        proxy = dynamic_proxy(interface)
        if proxy._ayu_interfaces_methods != (method_name,):
            raise UnsupportedAPI("Host does not declare the SDK callback interface signature")
        super().__init__()
        self._ayu_interfaces = proxy._ayu_interfaces
        self._ayu_interfaces_methods = proxy._ayu_interfaces_methods
        self._ayu_local = False

    def _export_callback(self, function, *, once=False):
        scope = runtime.require(self._ayu_scope)
        if self._ayu_local:
            raise UnsupportedAPI("A delegate of a Python-local interface cannot be passed to the host")
        if scope.state == "unloading":
            raise BridgeError("PLUGIN_UNLOADING", "Cannot export callbacks during unload")
        if self._ayu_native is None:
            before = set(scope.callbacks)
            try:
                reference = runtime.callback(function, once=once)
                native = runtime.call("java.proxy", {
                    "interfaces": list(self._ayu_interfaces),
                    "callbacks": {self._ayu_interfaces_methods[0]: reference},
                })
                if not isinstance(native, RemoteObject) or native._class_name != self._ayu_interfaces[0]:
                    raise ProtocolError("java.proxy must return a handle for the requested native interface")
                self._ayu_native = native
            except BaseException:
                for callback_id in set(scope.callbacks) - before:
                    scope.callbacks.pop(callback_id, None)
                raise
        return self._ayu_native


class RequestCallback(_ClientCallbackProxy):
    """One-shot ``RequestDelegate.run(response, error)`` bound to its owner.

    Like Android, an omitted account means no callback account override. Native
    export requires a declared RequestDelegate adapter; this wrapper never
    substitutes an untyped callback token for that native interface.
    """
    def __init__(self, fn, account=None):
        if not callable(fn):
            raise TypeError("RequestCallback requires a callable")
        account = _account(account)
        super().__init__("org.telegram.tgnet.RequestDelegate", "run")
        from extera_utils.lifecycle import bind_request

        self._account = account
        self._fn = bind_request(fn)

    def run(self, response, error):
        runtime.require(self._ayu_scope)
        try:
            with account_scope(self._account):
                self._fn(response, error)
        except BridgeError:
            raise
        except Exception:
            # Android logs callback failures. Keep native/lifecycle errors
            # explicit, and omit plugin exception/source data from this log.
            from android_utils import log
            log("RequestDelegate callback failed")

    def _reference(self):
        return self._export_callback(self.run, once=True)


class NotificationCenterDelegate(_ClientCallbackProxy):
    """Subclass and implement ``didReceivedNotification(id, account, args)``.

    Native payloads are forwarded unchanged. A JSON list remains a list rather
    than being advertised as a Java Object[]; owned native arrays stay native.
    """
    def __init__(self):
        super().__init__("org.telegram.messenger.NotificationCenter$NotificationCenterDelegate",
                         "didReceivedNotification")

    def didReceivedNotification(self, id, account, args):
        raise UnsupportedAPI("NotificationCenterDelegate requires didReceivedNotification implementation")

    def _dispatch_notification(self, id, account, args):
        runtime.require(self._ayu_scope)
        # Android uses -1 for notifications without an account. Keep that value
        # in the callback while letting get_client resolve the selected account.
        if type(account) is not int:
            raise ProtocolError("Notification account must be an integer")
        with account_scope(None if account == -1 else _account(account)):
            self.didReceivedNotification(id, account, args)

    def _reference(self):
        runtime.require(self._ayu_scope)
        implementation = getattr(self, "didReceivedNotification", None)
        if not callable(implementation) or getattr(implementation, "__func__", None) is NotificationCenterDelegate.didReceivedNotification:
            raise UnsupportedAPI("NotificationCenterDelegate requires didReceivedNotification implementation")
        return self._export_callback(self._dispatch_notification)


def _tl():
    from _ayu_javalib import telegram_tl
    return telegram_tl


def send_tl_request(request, deliver, account, flags=0):
    """``telegram.request``: send a TL function and deliver ``(response, error)`` once.

    ``deliver`` receives the decoded response object (or ``Vector``) and a ``TLRPC.TL_error``,
    one of them ``None``; both are ``None`` when a pre-request hook cancelled the request.
    """
    scope = runtime.require()
    tl = _tl()
    if not isinstance(request, tl.TLObject) or not tl.is_function(type(request)):
        raise TypeError("A TL function object is required")
    if type(flags) is not int or not 0 <= flags < 2**31:
        raise ValueError("Invalid request flags")

    pending = vars(scope).setdefault("_ayu_tl_requests", {})
    key = []

    def completed(response, error):
        runtime.require(scope)
        if key:
            pending.pop(key[0], None)
        deliver(tl.response_from_bridge(request, response), tl.from_bridge(error, tl.TLRPC.TL_error))

    reference = runtime.callback(completed, once=True)
    try:
        result = runtime.call("telegram.request", {"account": account, "request": request, "flags": flags,
                                                    "callback": reference})
        if type(result) is not int or not 0 < result < 2**31:
            raise ProtocolError("Host returned an invalid request id")
        key.append((account, result))
        pending[key[0]] = reference.callback_id
        return result
    except BaseException:
        scope.callbacks.pop(reference.callback_id, None)
        raise


def cancel_tl_request(account, request_id):
    """``telegram.request.cancel``; the cancelled request's callback never fires, so it is dropped here."""
    scope = runtime.require()
    runtime.call("telegram.request.cancel", {"account": account, "request_id": request_id})
    callback_id = vars(scope).get("_ayu_tl_requests", {}).pop((account, request_id), None)
    if callback_id is not None:
        scope.callbacks.pop(callback_id, None)


def send_request(request, fn, *, account=None):
    scope = runtime.require()
    if scope.state == "unloading":
        raise BridgeError("PLUGIN_UNLOADING", "Cannot send requests during unload")
    if not callable(fn):
        raise TypeError("send_request requires a response callback")
    if _ayu_operations.declared("telegram.request"):
        resolved = _resolve_account(account, "send_request")

        def deliver(response, error):
            try:
                with account_scope(resolved):
                    fn(response, error)
            except BridgeError:
                raise
            except Exception:
                # Android logs a failing RequestDelegate; plugin exception text stays out of the log.
                log("RequestDelegate callback failed")

        return send_tl_request(request, deliver, resolved)
    resolved = get_selected_account() if account is None else _account(account)
    reference = runtime.callback(_with_account(fn, resolved), once=True)
    try:
        result = _call("send_request", request, reference, account=resolved)
        if type(result) is not int or not 0 <= result < 2**63:
            raise ProtocolError("Host returned an invalid request id")
        return result
    except BaseException:
        scope.callbacks.pop(reference.callback_id, None)
        raise


class AccountClient:
    """An explicit account bound to the creating plugin's load generation."""
    __slots__ = ("_scope", "_account")

    def __init__(self, account: int):
        self._scope = runtime.require()
        if account is None:
            raise ValueError("AccountClient requires an account")
        self._account = _account(account)

    @property
    def account(self):
        runtime.require(self._scope)
        return self._account

    def __repr__(self):
        return f"AccountClient(account={self.account})"

    def __eq__(self, other):
        return (isinstance(other, AccountClient) and self._scope is other._scope
                and self._account == other._account)

    def __hash__(self):
        return hash((AccountClient, id(self._scope), self._account))

    def _call(self, name, *args, **kwargs):
        runtime.require(self._scope)
        if "account" in kwargs:
            raise TypeError("AccountClient already binds an account")
        kwargs["account"] = self.account
        return _call(name, *args, **kwargs)

    def send_message(self, params: dict, parse_mode: str = None):
        return send_message(params, parse_mode, account=self.account)

    def send_text(self, peer: int, text: str, *, parse_mode=None, **kwargs):
        return send_text(peer, text, account=self.account, parse_mode=parse_mode, **kwargs)

    def send_photo(self, peer: int, file_path: str, caption: str = "", high_quality: bool = False,
                   *, parse_mode=None, **kwargs):
        return send_photo(peer, file_path, caption, high_quality, account=self.account,
                          parse_mode=parse_mode, **kwargs)

    def send_document(self, peer: int, file_path: str, caption: str = "", *, parse_mode=None, **kwargs):
        return send_document(peer, file_path, caption, account=self.account, parse_mode=parse_mode, **kwargs)

    def send_video(self, peer: int, file_path: str, caption: str = "", *, parse_mode=None, **kwargs):
        return send_video(peer, file_path, caption, account=self.account, parse_mode=parse_mode, **kwargs)

    def send_audio(self, peer: int, file_path: str, caption: str = "", *, parse_mode=None, **kwargs):
        return send_audio(peer, file_path, caption, account=self.account, parse_mode=parse_mode, **kwargs)

    def edit_message(self, message_obj, text=None, file_path=None, with_spoiler=False,
                     *, parse_mode=None, **kwargs):
        return edit_message(message_obj, text, file_path, with_spoiler, account=self.account,
                            parse_mode=parse_mode, **kwargs)

    def send_request(self, request, fn):
        return send_request(request, fn, account=self.account)

    def get_messages_controller(self):
        return get_messages_controller(self.account)

    def get_user_config(self):
        return self._call("get_user_config")

    def get_connections_manager(self):
        return get_connections_manager(self.account)

    def get_send_messages_helper(self):
        return get_send_messages_helper(self.account)

    def get_media_data_controller(self):
        return get_media_data_controller(self.account)

    def get_notification_center(self):
        return get_notification_center(self.account)

    def get_account_instance(self):
        return get_account_instance(self.account)

    def get_contacts_controller(self):
        return self._call("get_contacts_controller")

    def get_location_controller(self):
        return self._call("get_location_controller")

    def get_notifications_controller(self):
        return self._call("get_notifications_controller")

    def get_messages_storage(self):
        return get_messages_storage(self.account)

    def get_file_loader(self):
        return get_file_loader(self.account)

    def get_secret_chat_helper(self):
        return self._call("get_secret_chat_helper")

    def get_download_controller(self):
        return self._call("get_download_controller")

    def get_notifications_settings(self):
        return self._call("get_notifications_settings")


def get_client(account=None):
    runtime.require()
    if account is None:
        account = get_hook_account()
    if account is None:
        account = get_selected_account()
    return AccountClient(account=account)
