"""Portable client helpers; native operations require explicit host adapters.

Android media preparation and text parsing have no portable implementation here.
Those options fail explicitly rather than dropping content or formatting.
"""
import contextlib
import contextvars

from ayu_bridge import BridgeError, DynamicProxy, ProtocolError, RemoteObject, UnsupportedAPI, runtime

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


def get_last_fragment():
    return _call("get_last_fragment")


def get_selected_account():
    result = _call("get_selected_account")
    if type(result) is not int or not 0 <= result < 2**63:
        raise ProtocolError("Host returned an invalid selected account")
    return result


def get_messages_controller(account=None):
    return _call("get_messages_controller", account=_account(account))


def get_user_config(account=None):
    return _call("get_user_config", account=_account(account))


def get_connections_manager(account=None):
    return _call("get_connections_manager", account=_account(account))


def get_send_messages_helper(account=None):
    return _call("get_send_messages_helper", account=_account(account))


def get_media_data_controller(account=None):
    return _call("get_media_data_controller", account=_account(account))


def get_notification_center(account=None):
    runtime.require()
    _account(account)
    if account is not None:
        raise UnsupportedAPI("Account-specific notification centers require a native adapter")
    # The existing adapter is explicitly a global notification center.
    return _call("get_notification_center")


def get_account_instance(account=None):
    return _call("get_account_instance", account=_account(account))


def get_contacts_controller(account=None):
    return _call("get_contacts_controller", account=_account(account))


def get_location_controller(account=None):
    return _call("get_location_controller", account=_account(account))


def get_notifications_controller(account=None):
    return _call("get_notifications_controller", account=_account(account))


def get_messages_storage(account=None):
    return _call("get_messages_storage", account=_account(account))


def get_file_loader(account=None):
    return _call("get_file_loader", account=_account(account))


def get_secret_chat_helper(account=None):
    return _call("get_secret_chat_helper", account=_account(account))


def get_download_controller(account=None):
    return _call("get_download_controller", account=_account(account))


def get_notifications_settings(account=None):
    return _call("get_notifications_settings", account=_account(account))


def get_media_controller():
    return _call("get_media_controller")


def _parse_mode(parse_mode):
    if parse_mode is not None:
        raise UnsupportedAPI("Text parse_mode requires a native formatting adapter")


def send_message(params: dict, parse_mode: str = None, *, account=None):
    runtime.require()
    if not isinstance(params, dict):
        raise TypeError("send_message requires a parameter dictionary")
    if "peer" in params:
        _int64(params["peer"], "peer")
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


def send_photo(peer: int, file_path: str, caption: str = "", high_quality: bool = False,
               *, account=None, parse_mode=None, **kwargs):
    runtime.require()
    raise UnsupportedAPI("send_photo requires a native media preparation adapter")


def send_document(peer: int, file_path: str, caption: str = "", *, account=None,
                  parse_mode=None, **kwargs):
    runtime.require()
    raise UnsupportedAPI("send_document requires a native media preparation adapter")


def send_video(peer: int, file_path: str, caption: str = "", *, account=None,
               parse_mode=None, **kwargs):
    runtime.require()
    raise UnsupportedAPI("send_video requires a native media preparation adapter")


def send_audio(peer: int, file_path: str, caption: str = "", *, account=None,
               parse_mode=None, **kwargs):
    runtime.require()
    raise UnsupportedAPI("send_audio requires a native media preparation adapter")


def edit_message(message_obj, text=None, file_path=None, with_spoiler=False,
                 *, account=None, parse_mode=None, **kwargs):
    runtime.require()
    _parse_mode(parse_mode)
    if file_path is not None or with_spoiler is not False or kwargs:
        raise UnsupportedAPI("Media, spoilers and edit options require a native edit adapter")
    return _call("edit_message", message_obj, text, account=_account(account))


class _ClientCallbackProxy(DynamicProxy):
    """Resolve native interfaces only within a plugin's active generation."""
    def __init__(self, interface_name, method_name):
        from java import dynamic_proxy, jclass

        proxy = dynamic_proxy(jclass(interface_name))
        if proxy._ayu_interfaces_methods != (method_name,):
            raise UnsupportedAPI("Host does not declare the SDK callback interface signature")
        super().__init__()
        self._ayu_interfaces = proxy._ayu_interfaces
        self._ayu_interfaces_methods = proxy._ayu_interfaces_methods

    def _export_callback(self, function, *, once=False):
        scope = runtime.require(self._ayu_scope)
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


def send_request(request, fn, *, account=None):
    scope = runtime.require()
    if scope.state == "unloading":
        raise BridgeError("PLUGIN_UNLOADING", "Cannot send requests during unload")
    if not callable(fn):
        raise TypeError("send_request requires a response callback")
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
        return self._call("get_messages_controller")

    def get_user_config(self):
        return self._call("get_user_config")

    def get_connections_manager(self):
        return self._call("get_connections_manager")

    def get_send_messages_helper(self):
        return self._call("get_send_messages_helper")

    def get_media_data_controller(self):
        return self._call("get_media_data_controller")

    def get_notification_center(self):
        return get_notification_center(self.account)

    def get_account_instance(self):
        return self._call("get_account_instance")

    def get_contacts_controller(self):
        return self._call("get_contacts_controller")

    def get_location_controller(self):
        return self._call("get_location_controller")

    def get_notifications_controller(self):
        return self._call("get_notifications_controller")

    def get_messages_storage(self):
        return self._call("get_messages_storage")

    def get_file_loader(self):
        return self._call("get_file_loader")

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
