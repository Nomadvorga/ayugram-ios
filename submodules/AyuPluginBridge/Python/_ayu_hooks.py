"""Typed host routes for ``BasePlugin`` request/update hooks, the send-message hook and menu items.

``BasePlugin`` uses these when the host declares the corresponding operation of
``protocol-telegram.md`` and keeps its ``hooks.register``/``menus.register`` forms otherwise.
Hook dispatch follows exteraGram's ``PythonPluginsEngine.executeHook``: a plugin exception or a
value of the wrong class leaves the object unchanged, ``CANCEL`` drops it, and ``MODIFY_FINAL``
stops the chain on the host.
"""
from __future__ import annotations

import uuid

import _ayu_mvel
import _ayu_operations
import _ayu_threads
from ayu_bridge import BridgeError, ProtocolError, Registration, UnsupportedAPI, runtime

SEND_MESSAGE_HOOK = "send_message_hook"
HOOKS = "telegram.hooks.set"
SEND_HOOK = "telegram.hooks.send_message"
MENUS = "menus.add"
MAX_HOOK_CONSTRUCTORS = 4096
MENU_TYPES = ("message_context_menu", "drawer_menu", "main_menu", "chat_action_menu", "profile_action_menu")


def _tl():
    from _ayu_javalib import telegram_tl
    return telegram_tl


def _log(message):
    from android_utils import log
    log(message)


class _State:
    def __init__(self):
        self.events = {}        # (name, match_substring) -> priority
        self.references = None  # callback references of the four TL hook kinds
        self.send = None        # typed send-message hook registration
        self.menus = {}         # item id -> Registration


def _state(plugin):
    state = plugin.__dict__.get("_ayu_hook_state")
    if state is None:
        state = plugin.__dict__["_ayu_hook_state"] = _State()
    return state


def _register(operation, config, kind):
    """``Runtime.register`` for an operation that returns a token ``hooks``/``menus.unregister`` accepts."""
    if _ayu_threads.off_queue(runtime):
        return _ayu_threads.marshal(runtime, _register, operation, config, kind)
    scope = runtime.require()
    if scope.state == "unloading":
        raise BridgeError("PLUGIN_UNLOADING", "Cannot register during unload")
    if len(scope.registrations) >= 1024:
        raise BridgeError("RESOURCE_LIMIT", "Plugin registration limit reached")
    before = set(scope.callbacks)
    try:
        token = runtime.call(operation, config)
        if not isinstance(token, str) or not token:
            raise ProtocolError("Expected registration token")
        return Registration(runtime, scope, kind, token, set(scope.callbacks) - before)
    except Exception:
        for callback_id in set(scope.callbacks) - before:
            scope.callbacks.pop(callback_id, None)
        raise


def _strategy(result):
    """Android reads ``str(result.strategy)`` and tests its suffix."""
    from base_plugin import HookStrategy
    value = getattr(result, "strategy", None)
    if isinstance(value, HookStrategy):
        return value
    if type(value) is int and 0 <= value <= 3:
        return HookStrategy(value)
    text = str(getattr(value, "name", value))
    for name in ("CANCEL", "MODIFY_FINAL", "MODIFY"):
        if text.endswith(name):
            return HookStrategy[name]
    return HookStrategy.DEFAULT


def _invoke(plugin, method, account, arguments):
    from client_utils import account_scope
    try:
        with account_scope(account):
            return getattr(plugin, method)(*arguments)
    except BridgeError:
        raise
    except Exception as error:
        # Android logs the failure and continues with the unmodified object.
        _log(f"Failed to execute {method}: {type(error).__name__}")
        return None


def _outcome(result, fields):
    """Wire result of one hook call; ``fields`` maps a ``HookResult`` field to its accepted class."""
    from base_plugin import HookStrategy
    wire = {"strategy": 0}
    wire.update({name: None for name in fields})
    if result is None:
        return wire
    strategy = _strategy(result)
    if strategy is HookStrategy.CANCEL:
        wire["strategy"] = int(strategy)
    elif strategy in (HookStrategy.MODIFY, HookStrategy.MODIFY_FINAL):
        wire["strategy"] = int(strategy)
        for name, accepted in fields.items():
            value = getattr(result, name, None)
            if isinstance(value, accepted):
                wire[name] = value
            elif value is not None:
                _log(f"Bad {name} type from a plugin hook: {type(value).__name__}")
    return wire


def _callbacks(plugin):
    tl = _tl()
    root = tl.TLRPC

    def pre(account, request):
        value = tl.from_bridge(request)
        result = _invoke(plugin, "pre_request_hook", account, (tl.simple_name(type(value)), account, value))
        return _outcome(result, {"request": tl.TLObject})

    def post(account, constructor, response, error):
        cls = tl.class_for(constructor) if type(constructor) is int else None
        if cls is None or not tl.is_function(cls):
            raise ProtocolError("Host named an unknown request constructor")
        value = tl.response_from_bridge(cls, response)
        failure = tl.from_bridge(error, root.TL_error)
        result = _invoke(plugin, "post_request_hook", account, (tl.simple_name(cls), account, value, failure))
        wire = _outcome(result, {"response": tl.TLObject, "error": root.TL_error})
        if wire["strategy"] == 1:
            # A response cannot be cancelled; Android ignores CANCEL here.
            wire["strategy"] = 0
        return wire

    def update(account, value):
        value = tl.from_bridge(value, root.Update)
        result = _invoke(plugin, "on_update_hook", account, (tl.simple_name(type(value)), account, value))
        return _outcome(result, {"update": root.Update})

    def updates(account, value):
        value = tl.from_bridge(value, root.Updates)
        result = _invoke(plugin, "on_updates_hook", account, (tl.simple_name(type(value)), account, value))
        return _outcome(result, {"updates": root.Updates})

    return {"on_request": pre, "on_response": post, "on_update": update, "on_updates": updates}


def _sync(plugin, state):
    """Replace the generation's TL hook set: one priority per constructor, as Android's per-event maximum."""
    tl = _tl()
    root = tl.TLRPC
    targets = {"requests": {}, "updates": {}, "containers": {}}
    for (name, substring), priority in state.events.items():
        for cls in tl.classes_named(name, substring):
            kind = ("requests" if tl.is_function(cls) else "updates" if issubclass(cls, root.Update)
                    else "containers" if issubclass(cls, root.Updates) else None)
            if kind is not None:
                constructor = cls.constructor & 0xFFFFFFFF
                targets[kind][constructor] = max(targets[kind].get(constructor, priority), priority)
    if sum(len(items) for items in targets.values()) > MAX_HOOK_CONSTRUCTORS:
        raise BridgeError("RESOURCE_LIMIT", "Hook names match too many TL constructors")
    if state.references is None:
        state.references = {name: runtime.callback(function) for name, function in _callbacks(plugin).items()}
    config = {kind: [[constructor, priority] for constructor, priority in sorted(items.items())]
              for kind, items in targets.items()}
    config.update(state.references)
    runtime.call(HOOKS, config)


def _matches_send(name, match_substring):
    return name in SEND_MESSAGE_HOOK if match_substring else name == SEND_MESSAGE_HOOK


class EventHook:
    """Handle of one ``add_hook`` name; Android itself returns nothing."""

    def __init__(self, plugin, key):
        self._plugin, self._key = plugin, key

    def cancel(self):
        state = _state(self._plugin)
        if state.events.pop(self._key, None) is not None:
            _sync(self._plugin, state)

    unhook = dispose = cancel


def typed_hooks():
    return _ayu_operations.declared(HOOKS)


def add_hook(plugin, name, match_substring, priority):
    state = _state(plugin)
    key = (name, match_substring)
    # ``EventHookRecord`` equality ignores priority: registering the same name again changes nothing.
    if key not in state.events:
        state.events[key] = priority
        try:
            _sync(plugin, state)
        except BaseException:
            state.events.pop(key, None)
            raise
    if _matches_send(name, match_substring):
        plugin.add_on_send_message_hook(priority)
    return EventHook(plugin, key)


def remove_hook(plugin, name):
    """Android's ``removeEventHook``: every record of that name, whatever its match mode."""
    state = _state(plugin)
    removed = [key for key in state.events if key[0] == name]
    for key in removed:
        del state.events[key]
    if removed:
        _sync(plugin, state)
    if name == SEND_MESSAGE_HOOK and state.send is not None:
        registration, state.send = state.send, None
        registration.cancel()


def typed_send_hook():
    return _ayu_operations.declared(SEND_HOOK)


def add_send_hook(plugin, priority):
    state = _state(plugin)
    if state.send is not None:
        return state.send
    params_class = runtime.jclass("org.telegram.messenger.SendMessagesHelper$SendMessageParams")

    def callback(account, params):
        value = params_class._ayu_from_wire(params, account)
        result = _invoke(plugin, "on_send_message_hook", account, (account, value))
        wire = _outcome(result, {"params": params_class})
        if wire["params"] is not None:
            wire["params"] = wire["params"]._ayu_to_wire()
        return wire

    state.send = _register(SEND_HOOK, {"priority": priority, "callback": callback}, "hook")
    return state.send


def typed_menus():
    return _ayu_operations.declared(MENUS)


def _menu_context(wire):
    """Android's ``MenuContextBuilder`` map from the host's bounded context object."""
    import client_utils
    tl = _tl()
    root = tl.TLRPC
    if not isinstance(wire, dict) or type(wire.get("account")) is not int:
        raise ProtocolError("Menu context must name its account")
    account = wire["account"]
    context = {"account": account}
    if type(wire.get("dialog_id")) is int:
        context["dialog_id"] = wire["dialog_id"]
    for key, name, expected in (("user", "user", root.User), ("chat", "chat", root.Chat),
                                ("user_full", "userFull", root.UserFull), ("chat_full", "chatFull", root.ChatFull),
                                ("encrypted_chat", "encryptedChat", root.EncryptedChat)):
        value = tl.from_bridge(wire.get(key), expected)
        if value is not None:
            context[name] = value
            if key in ("user", "chat"):
                context[name + "Id"] = value.id
    message = tl.from_bridge(wire.get("message"), root.Message)
    if message is not None:
        message_class = runtime.jclass("org.telegram.messenger.MessageObject")
        context["message"] = message_class(account, message, False, False)
    with client_utils.account_scope(account):
        fragment = client_utils.get_last_fragment()
    if fragment is not None:
        context["fragment"] = fragment
        context["context"] = fragment.getParentActivity()
    return context


def _mvel_condition(compiled, text):
    logged = []

    def condition(context):
        shown, known = _ayu_mvel.evaluate(compiled, context)
        if not known and not logged:
            # Once per item: Android may show it where a model of the SDK could not answer.
            logged.append(True)
            _log(f"Menu item {text!r} is hidden where its condition reads something the SDK does not model")
        return shown
    return condition


def add_menu_item(plugin, item):
    """``PluginsController.addMenuItem``: returns the item id, replacing this plugin's item of that id."""
    from client_utils import account_scope
    state = _state(plugin)
    menu_type = str(getattr(item.menu_type, "value", item.menu_type)).lower()
    if menu_type not in MENU_TYPES:
        raise UnsupportedAPI(f"Unknown menu type: {menu_type}")
    condition = item.condition
    if isinstance(condition, str):
        # Android's form: an MVEL expression over the context map (``MenuItemRecord.checkCondition``).
        try:
            compiled = _ayu_mvel.compile(condition)
        except _ayu_mvel.Unsupported as error:
            raise UnsupportedAPI(f"This MVEL menu condition is not evaluated ({error}); pass a Python callable") from None
        condition = None if compiled is None else _mvel_condition(compiled, item.text)
    if condition is not None and not callable(condition):
        raise TypeError("condition must be a string or callable")
    if item.icon is not None and not isinstance(item.icon, str):
        raise TypeError("icon must be a drawable name")
    if item.subtext is not None and not isinstance(item.subtext, str):
        raise TypeError("subtext must be a string")
    item_id = item.item_id if isinstance(item.item_id, str) and item.item_id else str(uuid.uuid4())

    def bound(function, default=None):
        def callback(wire):
            context = _menu_context(wire)
            try:
                with account_scope(context["account"]):
                    return function(context)
            except BridgeError:
                raise
            except Exception as error:
                _log(f"Menu item callback failed: {type(error).__name__}")
                return default
        return callback

    config = {"type": menu_type, "item_id": item_id, "text": item.text, "priority": item.priority,
              "on_click": bound(item.on_click)}
    if item.icon:
        config["icon"] = item.icon
    if item.subtext:
        config["subtext"] = item.subtext
    if item.on_long_click is not None:
        config["on_long_click"] = bound(item.on_long_click)
    if condition is not None:
        config["condition"] = bound(lambda context: bool(condition(context)), False)
    previous = state.menus.pop(item_id, None)
    if previous is not None:
        previous.cancel()
    state.menus[item_id] = _register(MENUS, config, "menu")
    return item_id


def remove_menu_item(plugin, item_id):
    registration = _state(plugin).menus.pop(item_id, None) if isinstance(item_id, str) else None
    if registration is None:
        return False
    registration.cancel()
    return True
