"""Telegram SDK routes against a synthetic host that declares the ``protocol-telegram.md`` operations."""
import ast
import json
from pathlib import Path
import re
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Python"))

import _ayu_javalib
import _ayu_operations
import ayu_bridge as bridge
import client_utils as client
import test_bridge as harness
from _ayu_javalib import telegram_messenger as messenger
from _ayu_javalib import telegram_tl as tl
from _ayu_javalib import telegram_ui as ui
from base_plugin import HookResult, HookStrategy, MenuItemData, MenuItemType

R = tl.TLRPC
PROTOCOL = Path(__file__).resolve().parents[2] / "Python" / "protocol-telegram.md"
IMAGE_PROTOCOL = Path(__file__).resolve().parents[2] / "Python" / "protocol-images.md"
OPERATIONS = [
    "telegram.request", "telegram.request.cancel", "telegram.connection", "telegram.hooks.set",
    "telegram.hooks.send_message", "telegram.send_message", "telegram.edit_message", "menus.add", "telegram.peer",
    "telegram.messages", "telegram.screen", "telegram.navigation.open", "telegram.files.path", "telegram.files.load",
    "telegram.player", "plugins.list", "plugins.settings", "ui.layout_params", "resources.resolve",
]
CONFIG, FRAGMENT, CONTEXT = "org.telegram.messenger.UserConfig", "org.telegram.ui.ActionBar.BaseFragment", "android.content.Context"
FRAME, LINEAR = "android.widget.FrameLayout$LayoutParams", "android.widget.LinearLayout$LayoutParams"


def user(user_id=42, access_hash=9, name="Ann"):
    value = R.TL_user()
    value.id, value.access_hash, value.first_name = user_id, access_hash, name
    value.flags |= 1 | 2
    return value


def text_message(message_id=5, text="hi", dialog=42):
    value = R.TL_message()
    value.id, value.message, value.peer_id = message_id, text, R.TL_peerUser()
    value.peer_id.user_id = dialog
    return value


class TelegramHost(harness.FakeHost):
    def __init__(self, operations=OPERATIONS):
        super().__init__()
        self.capabilities["operations"] += list(operations)
        self.capabilities["classes"] += [CONFIG, FRAGMENT, CONTEXT, FRAME, LINEAR, "org.telegram.messenger.MessagesController",
                                         "org.telegram.tgnet.TLRPC$User"]
        self.capabilities["classes"] += ["org.telegram.tgnet.TLRPC$Chat"]
        # Ids of the bounded user/chat snapshots today's host adapters return, by handle.
        self.calls, self.results, self.peers, self.snapshots = [], {}, {}, {}

    def perform(self, request):
        operation, arguments = request["operation"], request["arguments"]
        if operation == "client.call":
            name = arguments["name"]
            if name == "get_selected_account":
                return 0
            if name == "get_user_config":
                return {"$handle": "config", "$class": CONFIG}
            if name == "get_last_fragment":
                return {"$handle": "fragment", "$class": FRAGMENT}
            return {"name": name, "args": arguments["args"], "kwargs": arguments["kwargs"]}
        if operation == "java.member" and arguments["name"] in ("getClientUserId", "getParentActivity", "presentFragment"):
            return {"kind": "method"}
        if operation == "java.member" and arguments["name"] == "id" and arguments["target"]["$handle"] in self.snapshots:
            return {"kind": "field", "value": self.snapshots[arguments["target"]["$handle"]]}
        if operation == "java.invoke" and arguments["name"] == "getClientUserId":
            return 100
        if operation == "java.invoke" and arguments["name"] == "getParentActivity":
            return {"$handle": "context", "$class": CONTEXT}
        if operation in OPERATIONS:
            self.calls.append((operation, arguments))
            if operation == "telegram.peer":
                return self.peers.get((arguments["kind"], arguments["id"]))
            if operation in ("telegram.hooks.send_message", "menus.add"):
                token = "typed-" + str(len(self.requests))
                self.tokens[token] = (request["plugin_id"], arguments)
                return token
            if operation == "ui.layout_params":
                return {"$handle": "params", "$class": FRAME if arguments["kind"] == "frame" else LINEAR}
            return self.results.get(operation)
        return super().perform(request)

    def last(self, operation):
        return next(arguments for name, arguments in reversed(self.calls) if name == operation)


class TelegramCase(unittest.TestCase):
    load = harness.BridgeTests.load
    tearDown = harness.BridgeTests.tearDown
    operations = OPERATIONS

    def setUp(self):
        harness.BridgeTests.setUp(self)
        self.host = TelegramHost(self.operations)
        sys.modules["_ayu_host"].dispatch = self.host.dispatch

    def fire(self, scope, reference, *arguments):
        callback_id = reference["$callback"] if isinstance(reference, dict) else reference
        return json.loads(bridge.invoke_callback_json(json.dumps({
            "version": 1, "plugin_id": scope.plugin_id, "callback_id": callback_id, "arguments": list(arguments)})))


class RequestTests(TelegramCase):
    def test_send_request_serializes_and_decodes(self):
        scope = self.load()
        self.host.results["telegram.request"] = 7
        seen = []
        request = R.TL_users_getUsers()
        request.id.add(R.TL_inputUserSelf())
        with bridge.runtime.context(scope):
            self.assertEqual(client.send_request(request, lambda response, error: seen.append((response, error))), 7)
        sent = self.host.last("telegram.request")
        self.assertEqual((sent["account"], sent["flags"], sent["request"]), (0, 0, request.to_bridge()))
        vector = tl.Vector()
        vector.objects.add(user())
        self.fire(scope, sent["callback"], vector.to_bridge(), None)
        response, error = seen[0]
        self.assertEqual((type(response), response.objects[0].first_name, error), (tl.Vector, "Ann", None))
        with self.assertRaises(bridge.BridgeError):
            self.fire(scope, sent["callback"], None, None)

    def test_errors_cancellation_and_invalid_requests(self):
        scope = self.load()
        self.host.results["telegram.request"] = 8
        failure = R.TL_error()
        failure.code, failure.text = 420, "FLOOD_WAIT_3"
        seen = []
        with bridge.runtime.context(scope):
            client.get_client(3).send_request(R.TL_help_getConfig(), lambda *result: seen.append(result))
            sent = self.host.last("telegram.request")
            self.assertEqual(sent["account"], 3)
            for bad in ({"synthetic": True}, R.TL_inputPeerSelf(), None):
                with self.subTest(bad=bad), self.assertRaises(TypeError):
                    client.send_request(bad, lambda *result: None)
            self.host.results["telegram.request"] = 0
            before = len(scope.callbacks)
            with self.assertRaises(bridge.ProtocolError):
                client.send_request(R.TL_help_getConfig(), lambda *result: None)
            self.assertEqual(len(scope.callbacks), before)
        self.fire(scope, sent["callback"], None, failure.to_bridge())
        self.assertEqual((seen[0][0], seen[0][1].text), (None, "FLOOD_WAIT_3"))
        scope2 = self.load("second")
        self.host.results["telegram.request"] = 9
        with bridge.runtime.context(scope2):
            client.send_request(R.TL_help_getConfig(), lambda *result: 1 / 0)
        # A failing delegate is logged, as on Android, and the cancelled form delivers (None, None).
        self.assertIsNone(self.fire(scope2, self.host.last("telegram.request")["callback"], None, None))

    def test_connections_manager_facade(self):
        scope = self.load()
        self.host.results.update({"telegram.request": 11, "telegram.connection": {
            "time_ms": 1_700_000_123_456, "time_difference": -2, "state": 3, "datacenter_id": 2}})
        seen = []

        class Delegate(_ayu_javalib.local_class("org.telegram.tgnet.RequestDelegate")):
            def run(self, response, error):
                seen.append((response, error, client.get_hook_account()))

        with bridge.runtime.context(scope):
            manager = client.get_connections_manager(4)
            self.assertIsInstance(manager, messenger.ConnectionsManager)
            self.assertEqual(manager.sendRequest(R.TL_help_getConfig(), Delegate(), manager.RequestFlagFailOnServerErrors), 11)
            self.assertEqual(self.host.last("telegram.request")["flags"], 2)
            cancelled = self.host.last("telegram.request")["callback"]
            before = len(scope.callbacks)
            manager.cancelRequest(11, True)
            self.assertEqual(self.host.last("telegram.request.cancel"), {"account": 4, "request_id": 11})
            # The host never invokes a cancelled request's callback, so the SDK does not keep it.
            self.assertEqual(len(scope.callbacks), before - 1)
            manager.cancelRequest(11, True)
            manager.cancelRequest(999)
            self.assertEqual(len(scope.callbacks), before - 1)
            self.host.results["telegram.request"] = 12
            self.assertEqual(manager.sendRequest(R.TL_help_getConfig(), Delegate()), 12)
            self.assertEqual((manager.getCurrentTime(), manager.getCurrentTimeMillis(), manager.getConnectionState()),
                             (1_700_000_123, 1_700_000_123_456, manager.ConnectionStateConnected))
            with self.assertRaises(bridge.UnsupportedAPI):
                manager.sendRequest(R.TL_help_getConfig(), Delegate(), object(), 0)
            self.assertIs(runtime_class("org.telegram.tgnet.ConnectionsManager"), messenger.ConnectionsManager)
        with self.assertRaises(bridge.BridgeError):
            self.fire(scope, cancelled, R.TL_boolTrue().to_bridge(), None)
        self.fire(scope, self.host.last("telegram.request")["callback"], R.TL_boolTrue().to_bridge(), None)
        self.assertEqual((type(seen[0][0]), seen[0][1], seen[0][2]), (R.TL_boolTrue, None, 4))
        self.assertEqual(vars(scope)["_ayu_tl_requests"], {})


def runtime_class(name):
    return bridge.runtime.jclass(name)


HOOK_BODY = '''    def on_plugin_load(self):
        self.seen = []
    def pre_request_hook(self, request_name, account, request):
        self.seen.append(("pre", request_name, account, request.message))
        if request.message == "drop":
            return HookResult(HookStrategy.CANCEL)
        if request.message == "boom":
            raise RuntimeError("synthetic")
        if request.message == "wrong":
            return HookResult(HookStrategy.MODIFY, request="not a TL object")
        request.message = request.message.upper()
        return HookResult(HookStrategy.MODIFY_FINAL, request=request)
    def post_request_hook(self, request_name, account, response, error):
        self.seen.append(("post", request_name, type(response).__name__, None if error is None else error.text))
        return HookResult(HookStrategy.CANCEL)
    def on_update_hook(self, update_name, account, update):
        self.seen.append(("update", update_name, update.message.message))
        return HookResult(strategy="MODIFY", update=update)
    def on_updates_hook(self, container_name, account, updates):
        self.seen.append(("updates", container_name, len(updates.updates)))
    def on_send_message_hook(self, account, params):
        self.seen.append(("send", account, params.peer, params.message, [type(e).__name__ for e in params.entities or []],
                          None if params.replyToMsg is None else params.replyToMsg.getId()))
        if params.message == "keep":
            return HookResult()
        params.message = params.message + "!"
        params.entities = None
        return HookResult(HookStrategy.MODIFY, params=params)
'''
HOOK_IMPORTS = "from base_plugin import HookResult, HookStrategy\n"


class HookTests(TelegramCase):
    def send_message_request(self, text):
        request = R.TL_messages_sendMessage()
        request.peer, request.message, request.random_id = R.TL_inputPeerSelf(), text, 1
        return request

    def test_add_hook_registers_constructors_and_dispatches_like_android(self):
        scope = self.load(body=HOOK_BODY, imports=HOOK_IMPORTS)
        plugin = scope.instance
        new_message = _ayu_javalib.local_class("org.telegram.tgnet.tl.TL_update$TL_updateNewMessage")
        with bridge.runtime.context(scope):
            handle = plugin.add_hook("TL_messages_sendMessage", priority=4)
            plugin.add_hook("TL_messages_sendMessage", priority=9)   # same record: ignored
            plugin.add_hook("TL_updateNewMessage")
            plugin.add_hook("TL_updates", False, 2)
        config = self.host.last("telegram.hooks.set")
        self.assertEqual(config["requests"], [[0xFEF48F62, 4]])
        self.assertEqual(config["updates"], [[new_message.constructor & 0xFFFFFFFF, 0]])
        self.assertEqual(config["containers"], [[R.TL_updates.constructor & 0xFFFFFFFF, 2]])
        modified = self.fire(scope, config["on_request"], 2, self.send_message_request("hello").to_bridge())
        self.assertEqual(modified["strategy"], 3)
        self.assertEqual(tl.from_bridge(modified["request"]).message, "HELLO")
        self.assertEqual(self.fire(scope, config["on_request"], 2, self.send_message_request("drop").to_bridge()),
                         {"strategy": 1, "request": None})
        for text in ("boom", "wrong"):
            result = self.fire(scope, config["on_request"], 2, self.send_message_request(text).to_bridge())
            self.assertEqual((result["request"], result["strategy"]), (None, 2 if text == "wrong" else 0))
        failure = R.TL_error()
        failure.code, failure.text = 400, "BAD"
        self.assertEqual(self.fire(scope, config["on_response"], 2, 0xFEF48F62, None, failure.to_bridge()),
                         {"strategy": 0, "response": None, "error": None})
        update = new_message()
        update.message = text_message(text="incoming")
        result = self.fire(scope, config["on_update"], 1, update.to_bridge())
        self.assertEqual((result["strategy"], tl.from_bridge(result["update"]).message.message), (2, "incoming"))
        container = R.TL_updates()
        container.updates.add(update)
        self.assertEqual(self.fire(scope, config["on_updates"], 1, container.to_bridge()), {"strategy": 0, "updates": None})
        self.assertEqual([item[:2] for item in plugin.seen],
                         [("pre", "TL_messages_sendMessage")] * 4 + [("post", "TL_messages_sendMessage"),
                          ("update", "TL_updateNewMessage"), ("updates", "TL_updates")])
        self.assertEqual(plugin.seen[0][2], 2)
        self.assertEqual(plugin.seen[4][2:], ("NoneType", "BAD"))
        with self.assertRaises(bridge.ProtocolError):
            self.fire(scope, config["on_response"], 2, 1, None, None)
        with bridge.runtime.context(scope):
            plugin.remove_hook(handle)
            self.assertEqual(self.host.last("telegram.hooks.set")["requests"], [])
            plugin.remove_hook("TL_updates")
            self.assertEqual(self.host.last("telegram.hooks.set")["containers"], [])
            plugin.add_hook("TL_messages_send", True, 1)
            self.assertGreater(len(self.host.last("telegram.hooks.set")["requests"]), 5)
            with self.assertRaises(ValueError):
                plugin.add_hook("")

    def test_send_message_hook_uses_android_params(self):
        scope = self.load(body=HOOK_BODY, imports=HOOK_IMPORTS)
        plugin = scope.instance
        with bridge.runtime.context(scope):
            first = plugin.add_on_send_message_hook(5)
            self.assertIs(plugin.add_hook("send_message_hook", False, 7), first)
        registered = self.host.last("telegram.hooks.send_message")
        self.assertEqual(registered["priority"], 5)
        self.assertEqual(sum(name == "telegram.hooks.send_message" for name, _ in self.host.calls), 1)
        entity = R.TL_messageEntityBold()
        entity.offset, entity.length = 0, 1
        wire = {"peer": -77, "message": "x", "entities": [entity.to_bridge()], "replyToMsg": text_message(31).to_bridge()}
        result = self.fire(scope, registered["callback"], 1, wire)
        self.assertEqual(plugin.seen[-1], ("send", 1, -77, "x", ["TL_messageEntityBold"], 31))
        self.assertEqual((result["strategy"], result["params"]["message"], result["params"]["entities"], result["params"]["peer"],
                          result["params"]["replyToMsg"], result["params"]["notify"]), (2, "x!", None, -77, 31, True))
        self.assertEqual(self.fire(scope, registered["callback"], 1, {"peer": 1, "message": "keep"}), {"strategy": 0, "params": None})
        with self.assertRaises(bridge.ProtocolError):
            self.fire(scope, registered["callback"], 1, {"peer": 1, "unknown": 2})
        with bridge.runtime.context(scope):
            plugin.remove_hook("send_message_hook")
        self.assertNotIn(first.token, self.host.tokens)

    def test_hook_params_refuse_what_the_host_cannot_tell_or_apply(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            params = messenger.SendMessageParams._ayu_from_wire({"peer": 5, "message": "x", "path": "/a"}, 0)
            self.assertEqual((params.entities, params.notify, params.path, params.scheduleDate), (None, True, "/a", 0))
            # Android has these fields, the hook contract does not: no default is invented for them.
            for read in (lambda: params.replyMarkup, lambda: getattr(params, "webPage", None), lambda: hasattr(params, "ttl")):
                with self.assertRaises(bridge.UnsupportedAPI) as caught:
                    read()
                self.assertNotIsInstance(caught.exception, AttributeError)
            self.assertFalse(hasattr(params, "caption_entities"))
            params.message = "y"
            self.assertEqual(params._ayu_to_wire()["message"], "y")
            with self.assertRaises(bridge.UnsupportedAPI):
                messenger.SendMessagesHelper(0).sendMessage(params)
            # The host applies only the modifiable fields; another change is refused, not dropped.
            params.path = "/b"
            with self.assertRaises(bridge.UnsupportedAPI):
                params._ayu_to_wire()
            params.path = "/a"
            params.replyMarkup = R.TL_replyKeyboardHide()
            with self.assertRaises(bridge.UnsupportedAPI):
                params._ayu_to_wire()

    def test_send_message_params_class(self):
        params_class = messenger.SendMessageParams
        simple = params_class.of("text", -5)
        self.assertEqual((simple.message, simple.peer, simple.notify, simple.searchLinks, simple.scheduleDate), ("text", -5, True, True, 0))
        self.assertFalse(params_class().notify)
        with self.assertRaises(AttributeError):
            simple.not_a_field = 1
        with self.assertRaises(bridge.UnsupportedAPI):
            params_class.of(1, 2, 3)
        self.assertIs(messenger.SendMessagesHelper.SendMessageParams, params_class)


class ReflectionTests(TelegramCase):
    operations = ()

    def test_hook_utils_expose_only_declared_fields_of_local_objects(self):
        import hook_utils
        scope = self.load()
        message = text_message()
        with bridge.runtime.context(scope):
            self.assertIs(hook_utils.find_class("org.telegram.tgnet.TLRPC$TL_message"), R.TL_message)
            self.assertIs(hook_utils.java_class(R.TL_message), R.TL_message)
            self.assertEqual((hook_utils.get_private_field(message, "id"), hook_utils.get_field(message, "message")), (5, "hi"))
            self.assertTrue(hook_utils.set_private_field(message, "id", 6))
            self.assertEqual((message.id, hook_utils.get_static_private_field(R, "LAYER"),
                              hook_utils.get_static_private_field(messenger.FileLoader, "PRIORITY_HIGH")), (6, 233, 3))
            for call in (lambda: hook_utils.get_private_field(message, "_ayu_plan"), lambda: hook_utils.get_private_field(message, "__dict__"),
                         lambda: hook_utils.set_private_field(message, "nope", 1),
                         lambda: hook_utils.get_private_field(messenger.MessageObject(0, message), "messageOwner"),
                         lambda: hook_utils.get_static_private_field(messenger.MessageObject, "getMedia"),
                         lambda: hook_utils.set_static_private_field(R, "LAYER", 1),
                         lambda: hook_utils.get_method(R.TL_message, "readParams"),
                         lambda: hook_utils.get_constructor(messenger.MessageObject),
                         lambda: hook_utils.find_class("org.telegram.ui.Cells.ChatMessageCell")):
                with self.subTest(call=call), self.assertRaises(bridge.UnsupportedAPI):
                    call()


class LegacyRouteTests(TelegramCase):
    operations = ()

    def test_helpers_keep_their_existing_routes_without_typed_operations(self):
        scope = self.load(body=HOOK_BODY, imports=HOOK_IMPORTS)
        with bridge.runtime.context(scope):
            self.assertEqual(client.send_message({"peer": 7, "message": "x"})["name"], "send_message")
            self.assertEqual(client.get_connections_manager()["name"], "get_connections_manager")
            self.assertIsInstance(client.get_last_fragment(), bridge.RemoteObject)
            registration = scope.instance.add_hook("TL_messages_sendMessage")
            self.assertEqual(self.host.tokens[registration.token][1]["kind"], "request")
            send = scope.instance.add_hook("send_message_hook")
            self.assertEqual(self.host.tokens[send.token][1]["kind"], "send_message")
            menu = scope.instance.add_menu_item(MenuItemData(MenuItemType.MESSAGE_CONTEXT_MENU, "Item", lambda context: None))
            self.assertIsInstance(menu, bridge.Registration)
            for call in (lambda: client.send_photo(1, "/tmp/a.jpg"), lambda: scope.instance.hook_call_site(None, None, None),
                         lambda: runtime_class("org.telegram.messenger.FileLoader"),
                         lambda: runtime_class("org.telegram.ui.Components.LayoutHelper")):
                with self.subTest(call=call), self.assertRaises(bridge.UnsupportedAPI):
                    call()
            self.assertIs(runtime_class("org.telegram.tgnet.TLRPC$User"), R.User)
            self.assertIsInstance(runtime_class("org.telegram.messenger.MessagesController"), bridge.JavaClass)
            self.assertIs(runtime_class("org.telegram.ui.LaunchActivity"), ui.LaunchActivity)
            self.assertEqual(ui.LaunchActivity.instance._class_name, CONTEXT)
            self.assertEqual(client.get_queue_by_name("nope"), None)

    def test_fallback_send_params_refuse_fields_the_host_does_not_carry(self):
        from base_plugin import _SendMessageParams
        params = _SendMessageParams(peer=4, message="x")
        self.assertEqual((params.peer, params.message, params.caption), (4, "x", None))
        for read in (lambda: params.entities, lambda: getattr(params, "replyToMsg", None), lambda: hasattr(params, "document")):
            with self.assertRaises(bridge.UnsupportedAPI) as caught:
                read()
            self.assertNotIsInstance(caught.exception, AttributeError)
        # Not an Android field either: a probe answers as it does on Android.
        self.assertFalse(hasattr(params, "caption_entities"))


class SendTests(TelegramCase):
    def test_send_message_sends_only_explicit_fields(self):
        scope = self.load()
        reply = messenger.MessageObject(0, text_message(31))
        with bridge.runtime.context(scope):
            self.assertIsNone(client.send_message({"peer": -5, "message": "<b>hi</b>", "notify": True, "scheduleDate": 0,
                                                   "replyToMsg": reply, "params": {"a": 1}, "bogus": 1}, "HTML", account=2))
            sent = self.host.last("telegram.send_message")
            self.assertEqual(sent["account"], 2)
            self.assertEqual(set(sent["params"]), {"peer", "message", "entities", "replyToMsg", "params"})
            self.assertEqual((sent["params"]["message"], sent["params"]["params"], sent["params"]["replyToMsg"]["id"]),
                             ("hi", {"a": "1"}, 31))
            self.assertIsInstance(tl.from_bridge(sent["params"]["entities"][0]), R.TL_messageEntityBold)
            client.send_text(9, "plain", notify=False)
            self.assertEqual(self.host.last("telegram.send_message")["params"], {"peer": 9, "message": "plain", "notify": False})
            client.send_photo(9, "/tmp/a.jpg", "cap", True)
            self.assertEqual(self.host.last("telegram.send_message")["params"],
                             {"peer": 9, "path": "/tmp/a.jpg", "caption": "cap", "sendingHighQuality": True, "attach": {"kind": "photo"}})
            client.get_client(1).send_audio(9, "/tmp/a.mp3")
            self.assertEqual(self.host.last("telegram.send_message")["params"]["attach"], {"kind": "audio"})
            helper = client.get_send_messages_helper(6)
            helper.sendMessage(messenger.SendMessageParams.of("direct", 12))
            self.assertEqual(self.host.last("telegram.send_message"), {"account": 6, "params": {"peer": 12, "message": "direct"}})
            for bad in (lambda: client.send_message({"peer": 2 ** 63, "message": "x"}), lambda: client.send_message({"peer": 1}, "rtf"),
                        lambda: client.send_document(1, ""), lambda: helper.sendMessage("text", 1)):
                with self.subTest(bad=bad), self.assertRaises((ValueError, TypeError, bridge.UnsupportedAPI)):
                    bad()

    def test_edit_message(self):
        scope = self.load()
        target = messenger.MessageObject(0, text_message(31, dialog=-9 if False else 42))
        with bridge.runtime.context(scope):
            client.edit_message(target, "*new*", parse_mode="markdown", account=1)
            sent = self.host.last("telegram.edit_message")
            self.assertEqual((sent["account"], sent["dialog_id"], sent["message_id"], sent["text"], len(sent["entities"])), (1, 42, 31, "new", 1))
            count = len(self.host.calls)
            self.assertIsNone(client.edit_message("not a message", "x"))
            self.assertIsNone(client.edit_message(target))
            self.assertIsNone(client.edit_message(target, file_path="/nonexistent/synthetic.jpg"))
            self.assertEqual(len(self.host.calls), count)


class MenuTests(TelegramCase):
    def test_menu_items_use_android_ids_and_context(self):
        scope = self.load()
        plugin = scope.instance
        seen = []
        self.host.results["telegram.screen"] = {"kind": "chat", "account": 1, "dialog_id": 42}
        with bridge.runtime.context(scope):
            item_id = plugin.add_menu_item(MenuItemData(MenuItemType.CHAT_ACTION_MENU, "Open", seen.append, icon="msg_open",
                                                         subtext="More", priority=3, on_long_click=lambda context: seen.append("long"),
                                                         condition=lambda context: context["dialog_id"] > 0))
            named = plugin.add_menu_item(MenuItemData(MenuItemType.MESSAGE_CONTEXT_MENU, "Copy", seen.append, item_id="copy"))
            self.assertEqual(named, "copy")
            with self.assertRaises(bridge.UnsupportedAPI):
                plugin.add_menu_item(MenuItemData(MenuItemType.DRAWER_MENU, "Cond", seen.append, condition="user.id + 1 > 2"))
        self.assertIsInstance(item_id, str)
        config = next(arguments for name, arguments in self.host.calls if name == "menus.add")
        self.assertEqual({key: config[key] for key in ("type", "item_id", "text", "icon", "subtext", "priority")},
                         {"type": "chat_action_menu", "item_id": item_id, "text": "Open", "icon": "msg_open", "subtext": "More", "priority": 3})
        context = {"account": 1, "dialog_id": 42, "user": user().to_bridge(), "message": text_message().to_bridge()}
        self.assertIs(self.fire(scope, config["condition"], context), True)
        self.assertIs(self.fire(scope, config["condition"], {"account": 1, "dialog_id": -4}), False)
        self.fire(scope, config["on_click"], context)
        self.fire(scope, config["on_long_click"], context)
        clicked = seen[0]
        self.assertEqual((clicked["account"], clicked["dialog_id"], clicked["userId"], clicked["user"].first_name,
                          clicked["message"].getId(), clicked["message"].currentAccount), (1, 42, 42, "Ann", 5, 1))
        self.assertIsInstance(clicked["fragment"], ui.ChatActivity)
        self.assertEqual((clicked["fragment"].getDialogId(), clicked["context"]._class_name, seen[1]), (42, CONTEXT, "long"))
        with self.assertRaises(bridge.ProtocolError):
            self.fire(scope, config["on_click"], {"dialog_id": 1})
        with bridge.runtime.context(scope):
            replaced = plugin.add_menu_item(MenuItemData(MenuItemType.MESSAGE_CONTEXT_MENU, "Copy 2", seen.append, item_id="copy"))
            self.assertEqual(replaced, "copy")
            self.assertEqual(sum(1 for _, item in self.host.tokens.values() if item.get("item_id") == "copy"), 1)
            self.assertTrue(plugin.remove_menu_item("copy"))
            self.assertFalse(plugin.remove_menu_item("copy"))
            self.assertTrue(plugin.remove_menu_item(item_id))
        self.assertFalse(any(item.get("item_id") for _, item in self.host.tokens.values()))


class ControllerTests(TelegramCase):
    def test_messages_controller_reads_peers_and_builds_input_peers(self):
        scope = self.load()
        channel = R.TL_channel()
        channel.id, channel.access_hash, channel.title, channel.megagroup = 77, 5, "Room", True
        channel.photo = R.TL_chatPhotoEmpty()
        channel.flags |= 1 << 13   # access_hash is present
        self.host.peers.update({("user", 42): user().to_bridge(), ("user", 100): user(100).to_bridge(),
                                ("chat", 77): channel.to_bridge()})
        with bridge.runtime.context(scope):
            controller = client.get_messages_controller(1)
            self.assertIsInstance(controller, messenger.MessagesController)
            self.assertIs(runtime_class("org.telegram.messenger.MessagesController"), messenger.MessagesController)
            found = controller.getUser(42)
            self.assertEqual((type(found), found.first_name, controller.getUser(1), controller.getUser(None)), (R.TL_user, "Ann", None, None))
            self.assertEqual(self.host.last("telegram.peer"), {"account": 1, "kind": "user", "id": 1})
            # Android answers null for an id its maps cannot hold; the host is not asked for one.
            asked = len(self.host.calls)
            self.assertEqual((controller.getUser(0), controller.getChat(-77), controller.getUserFull(-1), controller.getChatFull(0)),
                             (None, None, None, None))
            self.assertEqual(len(self.host.calls), asked)
            with self.assertRaises(TypeError):
                controller.getUser("42")
            peer = controller.getInputPeer(42)
            self.assertEqual((type(peer), peer.user_id, peer.access_hash), (R.TL_inputPeerUser, 42, 9))
            self.assertIsInstance(controller.getInputPeer(100), R.TL_inputPeerSelf)
            channel_peer = controller.getInputPeer(-77)
            self.assertEqual((type(channel_peer), channel_peer.channel_id, channel_peer.access_hash), (R.TL_inputPeerChannel, 77, 5))
            self.assertEqual((type(controller.getInputPeer(-8)), controller.getInputPeer(-8).chat_id), (R.TL_inputPeerChat, 8))
            self.assertEqual((type(controller.getInputUser(42)), type(controller.getInputUser(100)), type(controller.getInputUser(1))),
                             (R.TL_inputUser, R.TL_inputUserSelf, R.TL_inputUserEmpty))
            self.assertEqual((type(controller.getInputChannel(77)), type(controller.getInputChannel(8)), type(controller.getPeer(-77))),
                             (R.TL_inputChannel, R.TL_inputChannelEmpty, R.TL_peerChannel))
            self.assertEqual((messenger.ChatObject.isChannel(77, 1), messenger.ChatObject.isForum(1, -77), controller.isForum(-77)),
                             (True, False, False))
            # Android does nothing without a fragment; with one, ``type`` reaches the host.
            controller.openByUserName("durov", None, 0)
            controller.openByUserName(None, object(), 0)
            self.assertFalse(any(name == "telegram.navigation.open" for name, _ in self.host.calls))
            self.host.results["telegram.screen"] = {"kind": "dialogs", "account": 1}
            fragment = client.get_last_fragment()
            controller.openByUserName("durov", fragment, 0)
            self.assertEqual(self.host.last("telegram.navigation.open"), {"account": 1, "username": "durov", "type": 0})
            controller.openByUserName("durov", fragment._host, 1)
            self.assertEqual(self.host.last("telegram.navigation.open"), {"account": 1, "username": "durov", "type": 1})
            for arguments in (("durov", ui.ChatActivity(None), 0), ("durov", fragment, 0, object()), ("durov", object(), 0)):
                with self.assertRaises(bridge.UnsupportedAPI):
                    controller.openByUserName(*arguments)
            with self.assertRaises(TypeError):
                controller.openByUserName("durov", fragment, "1")
            self.assertEqual(sum(name == "telegram.navigation.open" for name, _ in self.host.calls), 2)
            # A host snapshot of a user or chat is replaced by the cached TL object of this account.
            self.host.snapshots.update(ann=42, room=77, stranger=5)
            ann, room, stranger = (bridge.RemoteObject(bridge.runtime, scope, handle, "org.telegram.tgnet.TLRPC$" + kind)
                                   for handle, kind in (("ann", "User"), ("room", "Chat"), ("stranger", "User")))
            self.assertEqual((type(controller.getInputUser(ann)), controller.getInputUser(ann).access_hash,
                              type(controller.getInputChannel(room)), controller.getInputPeer(room).channel_id),
                             (R.TL_inputUser, 9, R.TL_inputChannel, 77))
            for call in (lambda: controller.getInputUser(stranger), lambda: controller.getInputPeer(fragment._host)):
                with self.assertRaises(bridge.UnsupportedAPI):
                    call()
            account = client.get_client(1)
            self.assertEqual([type(item) for item in (account.get_messages_controller(), account.get_connections_manager(),
                                                      account.get_file_loader(), account.get_send_messages_helper(),
                                                      account.get_messages_storage(), account.get_account_instance())],
                             [messenger.MessagesController, messenger.ConnectionsManager, messenger.FileLoader,
                              messenger.SendMessagesHelper, messenger.MessagesStorage, messenger.AccountInstance])
            self.assertEqual((account.get_messages_controller().currentAccount, account.get_file_loader().currentAccount), (1, 1))
            instance = client.get_account_instance(1)
            self.assertIsInstance(instance.getMessagesController(), messenger.MessagesController)
            self.assertEqual((instance.getCurrentAccount(), instance.getUserConfig()._class_name), (1, CONFIG))
            self.host.peers[("user", 5)] = R.TL_inputPeerSelf().to_bridge()
            with self.assertRaises(bridge.ProtocolError):
                controller.getUser(5)

    def test_files_storage_and_player(self):
        scope = self.load()
        playing = text_message(8)
        self.host.results.update({"telegram.files.path": "/cache/2_9.mp3", "telegram.messages": [playing.to_bridge()],
                                  "telegram.player": {"account": 2, "paused": True, "message": playing.to_bridge(),
                                                      "progress": 0.5, "position_ms": 4200}})
        with bridge.runtime.context(scope):
            loader = client.get_file_loader(2)
            target = messenger.MessageObject(2, playing)
            self.assertEqual(str(loader.getPathToMessage(target).getAbsolutePath()), "/cache/2_9.mp3")
            self.assertEqual(self.host.last("telegram.files.path"), {"account": 2, "target": playing.to_bridge(), "cache": False})
            document = R.TL_document()
            document.mime_type, document.file_reference = "a/b", b""
            loader.loadFile(document, target, loader.PRIORITY_HIGH, 1)
            self.assertEqual(self.host.last("telegram.files.load"), {"account": 2, "target": document.to_bridge(), "priority": 3,
                                                                    "cache_type": 1, "parent": playing.to_bridge()})
            self.assertEqual(client.get_messages_storage(2).getMessage(42, 8).id, 8)
            player = client.get_media_controller()
            current = player.getPlayingMessageObject()
            self.assertEqual((current.getId(), current.currentAccount, current.audioProgress, current.audioProgressSec), (8, 2, 0.5, 4))
            self.assertEqual((player.getProgressMs(target), player.getProgressMs(messenger.MessageObject(2, text_message(9))),
                              player.getDuration()), (4200, -1, 0))
            self.assertEqual((player.isMessagePaused(), player.isPlayingMessage(target), player.pauseMessage(target)), (True, True, True))
            self.assertEqual(self.host.last("telegram.player"), {"action": "pause"})
            self.host.results["telegram.files.path"] = "relative"
            with self.assertRaises(bridge.ProtocolError):
                loader.getPathToAttach(document)

    def test_fragments_layout_and_plugins(self):
        scope = self.load()
        self.host.peers[("user", 42)] = user().to_bridge()
        self.host.results.update({"telegram.screen": {"kind": "chat", "account": 1, "dialog_id": 42, "topic_id": 6},
                                  "plugins.list": [{"id": "other", "name": "Other", "version": "2.0", "enabled": True}]})
        with bridge.runtime.context(scope):
            fragment = client.get_last_fragment()
            chat = runtime_class("org.telegram.ui.ChatActivity")
            self.assertIsInstance(fragment, chat)
            self.assertIsInstance(fragment, runtime_class("org.telegram.ui.ActionBar.BaseFragment"))
            self.assertEqual((fragment.getDialogId(), fragment.getTopicId(), fragment.getCurrentAccount(), fragment.getCurrentUser().first_name,
                              fragment.getCurrentChat(), fragment.getParentActivity()._class_name), (42, 6, 1, "Ann", None, CONTEXT))
            self.assertEqual(bridge.runtime.encode(fragment), {"$handle": "fragment", "$class": FRAGMENT})
            self.assertTrue(fragment.presentFragment(chat.of(-9, 3)))
            self.assertEqual(self.host.last("telegram.navigation.open"), {"account": 1, "dialog_id": -9, "screen": "chat", "message_id": 3})
            with self.assertRaises(bridge.UnsupportedAPI):
                bridge.runtime.encode(chat.of(1))
            self.host.results["telegram.screen"] = None
            self.assertIsNone(client.get_last_fragment())
            layout = runtime_class("org.telegram.ui.Components.LayoutHelper")
            self.assertEqual(layout.createLinear(-1, -2, 1.0, 17, 8, 0, 8, 4)._class_name, LINEAR)
            self.assertEqual(self.host.last("ui.layout_params"), {"kind": "linear", "width": -1, "height": -2, "weight": 1.0, "gravity": 17,
                                                                "margins": [8, 0, 8, 4]})
            layout.createFrameRelatively(40, 40.5, 0x800003, 1, 2, 3, 4)
            self.assertEqual(self.host.last("ui.layout_params"), {"kind": "frame", "width": 40, "height": 40.5, "gravity": 0x800003,
                                                                "margins": [1, 2, 3, 4], "relative": True})
            controller = runtime_class("com.exteragram.messenger.plugins.PluginsController").getInstance()
            other = controller.plugins.get("other")
            self.assertEqual((other.getName(), other.getVersion(), other.isEnabled(), controller.plugins.get("none"), controller.isPluginActive("other")),
                             ("Other", "2.0", True, None, True))
            controller.loadPluginSettings("sample")
            self.assertEqual(self.host.last("plugins.settings"), {"action": "reload", "plugin_id": "sample"})
            settings = runtime_class("com.exteragram.messenger.plugins.ui.PluginSettingsActivity")
            self.host.results["telegram.screen"] = {"kind": "dialogs", "account": 0}
            client.get_last_fragment().presentFragment(settings(other))
            self.assertEqual(self.host.last("plugins.settings"), {"action": "open", "plugin_id": "other"})
            self.host.results["plugins.list"] = [{"id": 1}]
            with self.assertRaises(bridge.ProtocolError):
                controller.plugins


USER_SOURCE = '''from client_utils import send_request, get_last_fragment, send_message as deliver
from base_plugin import MenuItemData, MenuItemType
import client_utils
from org.telegram.tgnet import TLRPC
from org.telegram.messenger import MessageObject, FileLoader

class Plugin(BasePlugin):
    def on_plugin_load(self):
        self.add_hook("TL_updateNewMessage")
        self.add_on_send_message_hook()
        self.add_menu_item(MenuItemData(menu_type=MenuItemType.CHAT_ACTION_MENU, text="x", on_click=self.clicked))
        self.hook_method(None, before=self.clicked)
        client_utils.edit_message(None, "x")
        self.resend(1)
    def resend(self, value):
        return value
    def send_text(self, value):
        return value
    def clicked(self, context):
        self.send_text("local method")
'''


class PreflightTests(TelegramCase):
    operations = ()

    def blockers(self, text):
        report = json.loads(bridge.preflight_plugin_json(text))
        return report, sorted((item["code"], item["detail"]) for item in report["blockers"])

    def test_undeclared_operations_block_the_sdk_entry_points_that_need_them(self):
        text = '__id__ = "gated"\n__name__ = "Gated"\nfrom base_plugin import BasePlugin\n' + USER_SOURCE
        report, blockers = self.blockers(text)
        self.assertEqual(blockers, [
            ("CLASS", "org.telegram.messenger.FileLoader"),
            ("OPERATION", "hooks.java_method (hook_method())"),
            ("OPERATION", "menus.add (base_plugin.MenuItemType.CHAT_ACTION_MENU)"),
            ("OPERATION", "telegram.edit_message (client_utils.edit_message)"),
            ("OPERATION", "telegram.hooks.set (add_hook())"),
            ("OPERATION", "telegram.request (client_utils.send_request)"),
            ("OPERATION", "telegram.send_message (client_utils.send_message)"),
        ])
        self.assertEqual(report["sdk_requirements"]["add_on_send_message_hook()"], [["telegram.hooks.send_message"], ["hooks.register"]])
        self.assertNotIn("send_text()", report["sdk_requirements"])
        self.assertNotIn("client_utils.get_last_fragment", report["sdk_requirements"])

    def test_declared_operations_leave_only_what_ios_cannot_provide(self):
        self.host.capabilities["operations"] += OPERATIONS
        text = '__id__ = "gated"\n__name__ = "Gated"\nfrom base_plugin import BasePlugin\n' + USER_SOURCE
        self.assertEqual(self.blockers(text)[1], [("OPERATION", "hooks.java_method (hook_method())")])
        clean = harness.source("clean", imports="from org.telegram.tgnet import TLRPC\nfrom org.telegram.messenger import MessageObject, DialogObject\n",
                               body="    def on_plugin_load(self):\n        self.user = DialogObject.isUserDialog(5)\n")
        resources = harness.source("icons", imports="from org.telegram.messenger import R\n",
                                   body="    def on_plugin_load(self):\n        self.icon = R.drawable.msg_info\n")
        self.assertEqual(self.blockers(resources)[1], [])
        self.host.capabilities["operations"] = [item for item in self.host.capabilities["operations"] if item not in OPERATIONS]
        self.assertEqual(self.blockers(clean)[1], [])
        # No adapter of a host without ``resources.resolve`` accepts a symbolic resource id.
        self.assertEqual(self.blockers(resources)[1], [("CLASS", "org.telegram.messenger.R")])
        peers = harness.source("peers", imports="from org.telegram.messenger import ChatObject, UserObject\n")
        self.assertEqual(self.blockers(peers)[1], [("CLASS", "org.telegram.messenger.ChatObject"),
                                                   ("CLASS", "org.telegram.messenger.UserObject")])

    def hook_source(self, body, extra=""):
        return harness.source("hooked", imports="from base_plugin import HookResult, HookStrategy\n",
                              body="    def on_plugin_load(self):\n        self.add_on_send_message_hook()\n"
                                   "    def on_send_message_hook(self, account, params):\n" + body + extra)

    def test_send_hook_fields_decide_which_hook_the_plugin_needs(self):
        typed = "telegram.hooks.send_message (on_send_message_hook params"
        basic = self.hook_source(
            "        if not params.message or params.peer > 0 or params is None:\n            return HookResult()\n"
            "        text = getattr(params, 'caption', None) or params.get('message') or params['message']\n"
            "        alias = params\n        alias.message = self.shout(alias) + f'{params}'\n"
            "        if hasattr(params, 'caption_entities') and isinstance(params, dict):\n            pass\n"
            "        result = HookResult(HookStrategy.MODIFY)\n        result.params = params\n        return result\n",
            "    def shout(self, values):\n        return values.message.upper()\n")
        report, blockers = self.blockers(basic)
        self.assertEqual(blockers, [])
        self.assertEqual(report["sdk_requirements"]["add_on_send_message_hook()"], [["telegram.hooks.send_message"], ["hooks.register"]])
        cases = {
            "        params.entities = None\n        return HookResult(HookStrategy.MODIFY, params=params)\n": ".entities)",
            "        return HookResult() if getattr(params, 'replyToMsg', None) else None\n": ".replyToMsg)",
            "        return params.get('entities')\n": ".entities)",
            "        self.kept = params\n        return HookResult()\n": ")",
            "        return self.work(params)\n": ")",                       # ``work`` is not this plugin's
            "        return getattr(params, self.field)\n": ")",
            "        return params.get(self.field)\n": ")",
            "        run(lambda: self.later(params))\n": ")",
        }
        for body, suffix in cases.items():
            with self.subTest(body=body):
                self.assertEqual(self.blockers(self.hook_source(body))[1], [("OPERATION", typed + suffix)])
        helper = self.hook_source("        return self.work(account, values=params)\n",
                                  "    def work(self, account, values):\n        return self.deeper(values)\n"
                                  "    def deeper(self, item):\n        return item.document or self.work(0, item)\n")
        self.assertEqual(self.blockers(helper)[1], [("OPERATION", typed + ".document)")])
        signature = harness.source("odd", body="    def on_plugin_load(self):\n        self.add_on_send_message_hook()\n"
                                              "    def on_send_message_hook(self, *args):\n        return None\n")
        self.assertEqual(self.blockers(signature)[1], [("OPERATION", typed + ")")])
        # No host can tell a hook the fields outside the hook contract, whatever it declares.
        lost = self.hook_source("        return params.replyMarkup or params.entities\n")
        unprovided = ("OPERATION", "sdk.unprovided_member (on_send_message_hook params.replyMarkup)")
        self.assertEqual(self.blockers(lost)[1], [unprovided, ("OPERATION", typed + ".entities)")])
        self.host.capabilities["operations"] += OPERATIONS
        self.assertEqual(self.blockers(lost)[1], [unprovided])
        for body in cases:
            self.assertEqual(self.blockers(self.hook_source(body))[1], [])
        # A caller that did not analyse the hook (a package) gets the strict requirement.
        self.assertEqual(_ayu_operations.requirements([], ["add_on_send_message_hook"]),
                         {"on_send_message_hook params": [["telegram.hooks.send_message"]]})
        self.assertEqual(_ayu_operations.requirements([], ["add_on_send_message_hook"], ["message", "not_android"]),
                         {"add_on_send_message_hook()": [["telegram.hooks.send_message"], ["hooks.register"]]})

    def test_client_getters_zwylib_and_unprovided_members_are_gated(self):
        text = harness.source(
            "members", imports="import zwylib\nfrom zwylib import HookUtils, Requests\nfrom client_utils import get_client\n",
            body="    def on_plugin_load(self):\n        get_client().get_file_loader()\n        get_client().get_user_config()\n"
                 "        Requests.send(None, None)\n        HookUtils.get_private_field(self, 'x')\n"
                 "        HookUtils.hook_before(None, None)\n        zwylib.hook_max_args_method(None, 'x', None)\n"
                 "        self.root = self.activity.getWindow().getDecorView()\n        self.list.smoothScrollBy(0, 5)\n"
                 "        self.getPhoto()\n    def getPhoto(self):\n        return None\n")
        expected = [("OPERATION", "hooks.java_method (zwylib.HookUtils.hook_before)"),
                    ("OPERATION", "hooks.java_method (zwylib.hook_max_args_method)"),
                    ("OPERATION", "sdk.unprovided_member (getDecorView())"),
                    ("OPERATION", "sdk.unprovided_member (getWindow())"),
                    ("OPERATION", "sdk.unprovided_member (smoothScrollBy())"),
                    ("OPERATION", "telegram.files.path (get_file_loader())"),
                    ("OPERATION", "telegram.request (zwylib.Requests.send)")]
        self.assertEqual(self.blockers(text)[1], expected)
        self.host.capabilities["operations"] += OPERATIONS
        self.assertEqual(self.blockers(text)[1], expected[:5])
        # Importing the classes needs nothing; every member that reaches the host is in the table.
        unused = harness.source("unused", imports="from zwylib import HookUtils, Requests\n")
        self.assertEqual(self.blockers(unused)[1], [])
        import zwylib
        for owner, free in ((zwylib.Requests, ()), (zwylib.HookUtils, ("get_private_field",))):
            for member in vars(owner):
                if not member.startswith("_") and member not in free:
                    with self.subTest(member=member):
                        self.assertIn(f"zwylib.{owner.__name__}.{member}", _ayu_operations.SYMBOLS)

    def test_unprovided_members_are_provided_by_nothing(self):
        root = Path(__file__).resolve().parents[2]
        names = set()
        for path in (root / "Python").rglob("*.py"):
            if path.name == "_ayu_operations.py":
                continue
            for node in ast.walk(ast.parse(path.read_text("utf-8"))):
                if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                    names.add(node.name)
                elif isinstance(node, ast.Constant) and isinstance(node.value, str):
                    names.update(re.findall(r"[A-Za-z_][A-Za-z0-9_]*", node.value) if len(node.value) < 4096 else ())
        for folder in ("Sources", "Integration"):
            for path in (root / folder).glob("*.swift"):
                names.update(re.findall(r'"([A-Za-z_][A-Za-z0-9_]*)"', path.read_text("utf-8")))
        # A modelled member is provided for the classes that have a model and stays the net for the rest.
        self.assertLessEqual(_ayu_operations.MODELLED_MEMBERS, set(_ayu_operations.UNPROVIDED_MEMBERS))
        self.assertLessEqual(_ayu_operations.MODELLED_MEMBERS, names)
        self.assertEqual(sorted(names.intersection(_ayu_operations.UNPROVIDED_MEMBERS) - _ayu_operations.MODELLED_MEMBERS), [])
        self.assertEqual(len(set(_ayu_operations.UNPROVIDED_MEMBERS)), len(_ayu_operations.UNPROVIDED_MEMBERS))

    def test_every_gated_operation_is_specified(self):
        documents = {"telegram": PROTOCOL.read_text("utf-8"), "image": IMAGE_PROTOCOL.read_text("utf-8")}
        named = {operation for groups in list(_ayu_operations.SYMBOLS.values()) + list(_ayu_operations.METHODS.values())
                 for group in groups for operation in group}
        for cls in _ayu_javalib.local_classes().values():
            if cls.__module__.rpartition(".")[2] in ("telegram_tl", "telegram_messenger", "telegram_ui", "exteragram"):
                named.update(_ayu_javalib.requirements(cls))
        for operation in sorted(named | set(OPERATIONS)):
            with self.subTest(operation=operation):
                contract = documents["image"] if operation.startswith("image.") else documents["telegram"]
                self.assertIn("`" + operation + "`", contract)


if __name__ == "__main__":
    unittest.main()
