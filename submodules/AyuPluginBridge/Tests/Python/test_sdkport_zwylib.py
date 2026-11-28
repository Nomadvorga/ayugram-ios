"""ZwyLib API over the bridge; synthetic plugins and a fake host only."""
from __future__ import annotations

import json
import logging
import os
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

import test_bridge as fixtures
import test_threads_model as thread_fixtures

import ayu_bridge as bridge
import zwylib
from base_plugin import HookResult, HookStrategy

LOCALE = "org.telegram.messenger.LocaleController"
DIALOG = "org.telegram.ui.ActionBar.AlertDialog"


class ZwyHost(thread_fixtures.ThreadHost):
    def __init__(self):
        super().__init__()
        self.capabilities["operations"].append("settings.replace")
        self.capabilities["classes"] += [LOCALE, DIALOG]
        self.language = "ru"
        self.clipboard = []
        self.showing = []

    def perform(self, request):
        owner, operation, arguments = request["plugin_id"], request["operation"], request["arguments"]
        if operation == "settings.replace":
            self.settings[owner] = arguments["values"]
            return None
        if operation == "ui.present":
            if arguments["kind"] == "bulletin":
                return None
            handle = "dialog-" + str(len(self.requests))
            self.handles[handle] = (owner, [])
            self.showing.append(handle)
            return {"$handle": handle, "$class": DIALOG}
        if operation == "client.call":
            if arguments["name"] == "copy_to_clipboard":
                self.clipboard.append(arguments["args"][0])
                return None
            if arguments["name"] == "get_last_fragment":
                return None
        if operation == "java.member":
            if arguments["name"] in ("getInstance", "getCurrentLocaleInfo", "isShowing", "dismiss"):
                return {"kind": "method"}
            if arguments["name"] == "pluralLangCode":
                return {"kind": "field", "value": self.language}
        if operation == "java.invoke" and arguments["name"] == "isShowing":
            return arguments["target"]["$handle"] in self.showing
        if operation == "java.invoke" and arguments["name"] == "dismiss":
            self.showing.remove(arguments["target"]["$handle"])
            return None
        if operation == "java.invoke" and arguments["name"] in ("getInstance", "getCurrentLocaleInfo"):
            handle = "locale-" + str(len(self.requests))
            self.handles[handle] = (owner, [])
            return {"$handle": handle, "$class": LOCALE}
        return super().perform(request)

    def presented(self, kind):
        return [r["arguments"]["config"] for r in self.requests
                if r["operation"] == "ui.present" and r["arguments"]["kind"] == kind]

    def logged(self):
        return [r["arguments"]["message"] for r in self.requests if r["operation"] == "log.write"]


def invoke(plugin_id, callback, arguments=()):
    return json.loads(bridge.invoke_callback_json(json.dumps({
        "version": 1, "plugin_id": plugin_id, "callback_id": callback["$callback"], "arguments": list(arguments)})))


class Case(thread_fixtures.ThreadCase):
    IMPORTS = ""

    def setUp(self):
        super().setUp()
        self.host = ZwyHost()
        sys.modules["_ayu_host"] = types.SimpleNamespace(dispatch=self.host.dispatch)
        self.home = tempfile.TemporaryDirectory()
        self.environment = patch.dict(os.environ, {"HOME": self.home.name})
        self.environment.start()

    def tearDown(self):
        try:
            super().tearDown()
        finally:
            self.environment.stop()
            self.home.cleanup()

    def load(self, body="    pass\n", plugin_id="sample", imports=None):
        return super().load(body, plugin_id, imports)


class PreflightTests(Case):
    def test_implemented_members_pass_and_unported_ones_stay_blockers(self):
        names = ("SettingsManager, SettingEntry, format_exc, format_exc_from, format_exc_only, UI, "
                 "arraylist_to_list, iterable_to_arraylist, async_manager, add_autoupdater_task, "
                 "remove_autoupdater_task, build_log, build_bulletin_helper, locales_controller, "
                 "command_manager, HookUtils, JsonCacheFile, Requests, Callback1, is_zwylib_version_sufficient, "
                 "DEFAULT_COMMAND_PREFIX, WRAP_CONTENT, CannotCastError, WrongArgumentAmountError")
        report = json.loads(bridge.preflight_plugin_json(fixtures.source(imports=f"from zwylib import {names}\n")))
        self.assertEqual(report["blockers"], [])
        report = json.loads(bridge.preflight_plugin_json(fixtures.source(
            imports="import zwylib\nfrom zwylib import DialogPicker, ensure_media_downloaded\n"
                    "zwylib.PluginUtils\nzwylib.safe_open_message\nzwylib.ExpandableSwitchManager\n")))
        self.assertEqual(sorted(item["detail"] for item in report["blockers"]), [
            "zwylib.DialogPicker", "zwylib.ExpandableSwitchManager", "zwylib.PluginUtils",
            "zwylib.ensure_media_downloaded", "zwylib.safe_open_message"])
        self.assertEqual(zwylib.DEFAULT_COMMAND_PREFIX, ".")


class ValueTests(Case):
    def test_loggers_format_like_zwylib_and_inherit_the_root_level(self):
        scope = self.load()

        def work():
            quiet = zwylib.build_log("quiet")
            quiet.info("hidden below the root level")
            quiet.warning("shown", 1, {"a": 2})
            quiet.setLevel(logging.INFO)
            quiet.info("raised level")
            self.assertEqual((quiet.level, quiet.getEffectiveLevel()), (logging.INFO, logging.INFO))
            loud = zwylib.build_log("loud", logging.DEBUG)
            loud.debug("detail")
            try:
                raise ValueError("synthetic")
            except ValueError as error:
                loud.error("failed:", exc_info=True)
                return zwylib.format_exc(), zwylib.format_exc_from(error), zwylib.format_exc_only(error)

        with patch.object(logging.root, "level", logging.WARNING):
            full, from_error, only = self.enter(scope, work)
        self.assertTrue(full.startswith("Traceback") and full.endswith("ValueError: synthetic"))
        self.assertEqual(full, from_error)
        self.assertEqual(only, "ValueError: synthetic")
        lines = self.host.logged()
        self.assertEqual(lines[0], "[WARNING] [quiet] [work] shown 1 {'a': 2}")
        self.assertEqual(lines[1], "[INFO] [quiet] [work] raised level")
        self.assertEqual(lines[2], "[DEBUG] [loud] [work] detail")
        self.assertTrue(lines[3].startswith("[ERROR] [loud] [work] failed:\nTraceback"))
        self.assertEqual(len(lines), 4)

    def test_locales_follow_the_host_language_with_english_fallback(self):
        scope = self.load()
        table = {"en": {"hello": "Hello {name}", "only_en": "English", "items": ["item", "items"]},
                 "ru": {"hello": "Privet {name}", "items": ["one", "few", "many"]}}

        def work():
            refreshed = []
            locale = zwylib.locales_controller.generate_locale_class(table)
            zwylib.locales_controller.subscribe_to_refresh(lambda: refreshed.append(True))
            values = [locale.hello(name="A"), locale.hello(), locale.only_en, locale.missing_key,
                      locale.plural("items", 1), locale.plural("items", 3), locale.plural("items", 11)]
            self.host.language = "de"
            values.append(locale.hello(name="B"))
            zwylib.locales_controller.refresh_locale()
            values += [locale.hello(name="B"), locale.plural("items", 5), refreshed]
            zwylib.locales_controller.unsubscribe_from_refresh()
            zwylib.locales_controller.refresh_locale()
            return values

        self.assertEqual(self.enter(scope, work), [
            "Privet A", "Privet {name}", "English", "missing_key", "one", "few", "many",
            "Privet B", "Hello B", "items", [True, True]])

    def test_setting_entries_and_manager_use_the_owner_namespace(self):
        scope = self.load()

        def work():
            entry = zwylib.SettingEntry("volume", 3, icon="msg_settings")
            row = entry.as_switch(text="Volume", subtext="Level")
            values = [entry.plugin_id, entry.get(), row.key, row.default, row.icon, row.text]
            entry.set(9)
            zwylib.SettingsManager.set("sample", "plain", "x", reload_settings=False)
            values += [entry.get(), zwylib.SettingsManager.get("sample", "plain"),
                       zwylib.SettingsManager.get("sample", "absent", 4),
                       entry.safe_get(lambda value: 1 / (value - 9)), entry.safe_get(int)]
            zwylib.SettingsManager.remove_setting("plain")
            zwylib.SettingsManager.reload()
            return values

        self.assertEqual(self.enter(scope, work), ["sample", 3, "volume", 3, "msg_settings", "Volume", 9, "x", 4,
                                                    1 / (3 - 9), 9])
        self.assertEqual(self.host.settings["sample"], {"volume": 9})
        writes = [r["arguments"] for r in self.host.requests if r["operation"] == "settings.set"]
        self.assertEqual([write["reload_settings"] for write in writes], [True, False])
        replaces = [r["arguments"] for r in self.host.requests if r["operation"] == "settings.replace"]
        self.assertEqual([item["reload_settings"] for item in replaces], [False, True])
        with bridge.runtime.context(scope):
            for call in (lambda: zwylib.SettingsManager.get("other", "key"),
                         lambda: zwylib.SettingsManager.remove_setting("key", "other"),
                         lambda: zwylib.SettingsManager.reload("other")):
                with self.subTest(call=call), self.assertRaisesRegex(bridge.BridgeError, "OWNERSHIP"):
                    call()

    def test_json_cache_files_persist_under_the_plugin_storage(self):
        scope = self.load()
        default = {"seen": []}

        def work():
            cache = zwylib.JsonCacheFile("synthetic_cache", default, compress=True)
            cache.content["seen"].append(1)
            cache.write()
            again = zwylib.JsonCacheFile("synthetic_cache", default)
            raw = zwylib.CacheFile("synthetic_cache")
            plain = zwylib.JsonCacheFile("plain_cache", [])
            plain.content = ["a"]
            plain.write()
            with open(plain.path, "rb") as stream:
                stored = stream.read()
            again.wipe()
            for name in ("../escape", "a/b", "", ".."):
                with self.subTest(name=name), self.assertRaises(ValueError):
                    zwylib.JsonCacheFile(name, {})
            return again.path, json.loads(raw.content), stored, zwylib.JsonCacheFile("synthetic_cache", default).content

        path, raw, stored, wiped = self.enter(scope, work)
        self.assertEqual(default, {"seen": []})
        self.assertEqual(raw, {"seen": [1]})
        self.assertEqual(stored, b'["a"]')
        self.assertEqual(wiped, {"seen": []})
        self.assertTrue(os.path.realpath(path).startswith(os.path.realpath(self.home.name) + os.sep))

    def test_array_list_helpers_use_the_java_list(self):
        scope = self.load()

        def work():
            array = zwylib.iterable_to_arraylist((1, "two", 2 ** 40))
            return (type(array).__name__, array.size(), zwylib.arraylist_to_list(array),
                    zwylib.iterable_to_arraylist(None), zwylib.arraylist_to_list(None),
                    zwylib.arraylist_to_list(zwylib.iterable_to_arraylist([])))

        self.assertEqual(self.enter(scope, work), ("ArrayList", 3, [1, "two", 2 ** 40], None, None, None))

    def test_version_checks(self):
        scope = self.load()

        def work():
            return (zwylib.is_zwylib_version_sufficient("Plugin", "2.0.6"),
                    zwylib.is_zwylib_version_sufficient("Plugin", "3.0"),
                    zwylib.is_zwylib_version_sufficient("Plugin", "3.0.1", notify=False),
                    zwylib.is_zwylib_version_sufficient("Plugin", "3.1"),
                    zwylib.is_client_version_sufficient("12.10.6"), zwylib.is_client_version_sufficient("99.0"),
                    zwylib.is_client_version_sufficient("not a version"))

        self.assertEqual(self.enter(scope, work), (True, True, False, False, True, False, False))
        errors = [c["text"] for c in self.host.presented("bulletin") if c["style"] == "error"]
        self.assertEqual(errors, ["Plugin needs ZwyLib 3.1+, got 3.0.0."])
        with bridge.runtime.context(scope), self.assertRaises(ValueError):
            zwylib.is_zwylib_version_sufficient("Plugin", "latest")

    def test_bulletin_helper_prefixes_and_copies_through_the_host(self):
        scope = self.load()

        def work():
            helper = zwylib.build_bulletin_helper("Demo")
            helper.show_info("info")
            helper.show_error("error")
            zwylib.build_bulletin_helper().show_success("plain")
            helper.show_error_with_copy("copy me", 42)
            with self.assertRaises(AttributeError):
                helper.show_error_with_post_redirect

        self.enter(scope, work)
        shown = self.host.presented("bulletin")
        self.assertEqual([(c["style"], c["text"]) for c in shown], [
            ("simple", "Demo: info"), ("error", "Demo: error"), ("success", "plain"), ("error", "Demo: copy me")])
        self.assertEqual(shown[3]["button"]["text"], "\u0421\u043a\u043e\u043f\u0438\u0440\u043e\u0432\u0430\u0442\u044c")
        invoke("sample", shown[3]["button"]["on_click"])
        self.assertEqual(self.host.clipboard, ["42"])

    def test_autoupdate_tasks_are_recorded_and_never_scheduled(self):
        scope = self.load()

        def work():
            zwylib.add_autoupdater_task(100, 7)
            zwylib.add_autoupdater_task("sample", 100, 7)
            zwylib.add_autoupdater_task("sample", 200, 9)
            recorded = [(task.plugin_id, task.channel_id, task.message_id)
                        for task in scope.__dict__["_ayu_zwylib"].autoupdater_tasks]
            with self.assertRaisesRegex(bridge.BridgeError, "OWNERSHIP"):
                zwylib.add_autoupdater_task("other", 1, 2)
            zwylib.remove_autoupdater_task()
            return recorded, scope.__dict__["_ayu_zwylib"].autoupdater_tasks

        with patch.object(logging.root, "level", logging.WARNING):
            recorded, remaining = self.enter(scope, work)
        self.assertEqual(recorded, [("sample", 100, 7), ("sample", 200, 9)])
        self.assertEqual(remaining, [])
        self.assertEqual(self.host.scheduled(), [])
        self.assertEqual(sum("not auto-updated on iOS" in line for line in self.host.logged()), 2)


COMMANDS = '''
    def on_plugin_load(self):
        import zwylib
        from base_plugin import HookResult, HookStrategy
        self.calls = []
        dp = zwylib.command_manager.get_dispatcher()
        self.prefix = dp.prefix

        @dp.register_command("add", aliases=["plus"])
        def add(params, account, left: int, right: float = 1.5, *rest: str) -> HookResult:
            self.calls.append((params.message, account, left, right, rest))
            params.message = str(left + right)
            return HookResult(strategy=HookStrategy.MODIFY, params=params)

        @add.subcommand("twice")
        def twice(params, account, flag: bool) -> HookResult:
            self.calls.append(("twice", flag))
            return HookResult(strategy=HookStrategy.CANCEL)

        @dp.register_command("boom")
        def boom(params, account) -> HookResult:
            raise RuntimeError("synthetic")

        @boom.register_error_handler
        def handle(params, account, error):
            self.calls.append(("handled", type(error).__name__))
            return HookResult(strategy=HookStrategy.CANCEL)

        @dp.register_command("later")
        async def later(params, account, text: str):
            self.calls.append(("later", text))
            self.set_setting("later", text)

        self.errors = []
        for bad in (lambda params: None, lambda params, account: None):
            try:
                dp.register_command("bad")(bad)
            except Exception as error:
                self.errors.append(type(error).__name__)
        dp.register_stub_command("group")
'''


class CommandTests(Case):
    def send(self, text, account=0):
        hooks = [args for _, (_, args) in self.host.tokens.items() if args.get("kind") == "send_message"]
        self.assertEqual(len(hooks), 1)
        return invoke("sample", hooks[0]["callback"], [account, {"peer": 1, "message": text}])

    def test_commands_dispatch_typed_arguments_from_the_send_hook(self):
        scope = self.load(COMMANDS)
        plugin = scope.instance
        self.assertEqual((plugin.prefix, plugin.errors), (".", ["MissingRequiredArguments", "InvalidTypeError"]))
        result = self.send(".add 2")
        self.assertEqual((result["strategy"], result["params"]["message"]), (int(HookStrategy.MODIFY), "3.5"))
        self.send('.plus 2 0.5 "a b" c')
        self.assertEqual(self.send(".add twice yes")["strategy"], int(HookStrategy.CANCEL))
        self.assertEqual(self.send(".boom")["strategy"], int(HookStrategy.CANCEL))
        for ignored in ("add 2", ".unknown 1", ".", ""):
            self.assertEqual(self.send(ignored)["strategy"], int(HookStrategy.DEFAULT))
        self.assertEqual(plugin.calls, [(".add 2", 0, 2, 1.5, ()), ('.plus 2 0.5 "a b" c', 0, 2, 0.5, ("a b", "c")),
                                        ("twice", True), ("handled", "RuntimeError")])
        # A wrong argument is reported to the user and the message is not sent.
        self.assertEqual(self.send(".add nope")["strategy"], int(HookStrategy.CANCEL))
        self.assertEqual(self.send(".group")["strategy"], int(HookStrategy.CANCEL))
        texts = [c["text"] for c in self.host.presented("bulletin")]
        self.assertEqual(len(texts), 2)
        self.assertIn("'add'", texts[0])

    def test_async_commands_run_on_the_plugin_loop_and_reach_the_bridge(self):
        scope = self.load(COMMANDS)
        self.assertEqual(self.send(".later hello")["strategy"], int(HookStrategy.CANCEL))
        self.pump(lambda: self.host.settings.get("sample", {}).get("later") == "hello", "the async command")
        self.assertEqual(scope.instance.calls, [("later", "hello")])

    def test_prefix_is_validated_and_remembered(self):
        scope = self.load(COMMANDS)

        def work():
            dp = zwylib.command_manager.get_dispatcher()
            dp.set_prefix("bad prefix")
            before = dp.prefix
            dp.set_prefix("!")
            return before, dp.validate_prefix(""), zwylib.command_manager.get_dispatcher() is dp

        self.assertEqual(self.enter(scope, work), (".", False, True))
        self.assertEqual(self.send("!add 1")["strategy"], int(HookStrategy.MODIFY))
        self.assertEqual(self.send(".add 1")["strategy"], int(HookStrategy.DEFAULT))
        bridge.unload_plugin("sample")
        again = self.load(COMMANDS)
        self.assertEqual(again.instance.prefix, "!")
        with bridge.runtime.context(again), self.assertRaisesRegex(bridge.BridgeError, "OWNERSHIP"):
            zwylib.command_manager.get_dispatcher("other")


class AsyncTests(Case):
    def test_tasks_run_on_a_generation_thread_and_marshal_bridge_calls(self):
        scope = self.load()

        async def job(value):
            import asyncio
            await asyncio.sleep(0)
            scope.instance.set_setting("async", value)
            return value * 2

        async def failing():
            raise RuntimeError("synthetic")

        def start():
            manager = zwylib.async_manager
            return manager.run_task(job(21)), manager.run_task(failing()), manager.loop, manager.thread

        future, failed, loop, thread = self.enter(scope, start)
        self.pump(lambda: future.done() and failed.done(), "the async tasks")
        self.assertEqual(future.result(), 42)
        self.assertIsNone(failed.result())
        self.assertEqual(self.host.settings["sample"]["async"], 21)
        self.assertEqual(self.host.dispatch_threads, {self.queue})
        self.assertEqual(thread.name, "ZwyAsyncThread")
        self.assertTrue(self.enter(scope, lambda: zwylib.async_manager.started))
        self.assertIs(self.enter(scope, lambda: zwylib.async_manager.loop), loop)
        bridge.unload_plugin("sample")
        thread.join(thread_fixtures.TIMEOUT)
        self.assertFalse(thread.is_alive())
        self.assertTrue(loop.is_closed())

    def test_each_plugin_generation_has_its_own_loop(self):
        left, right = self.load(plugin_id="left"), self.load(plugin_id="right")
        loops = [self.enter(scope, lambda: zwylib.async_manager.loop) for scope in (left, right)]
        self.assertIsNot(loops[0], loops[1])

    def test_callback_objects_resolve_a_wrapped_java_call(self):
        scope = self.load()

        class Listener:
            def __init__(self):
                self.seen = []

            def onSuccess(self, value):
                self.seen.append(value)

            def onError(self, code, text):
                self.seen.append((code, text))

        listener, failing = Listener(), Listener()

        async def job():
            manager = zwylib.async_manager
            value = await manager.wrap_java_call(lambda target, extra: target.onSuccess(extra),
                                                 manager.as_callback(listener, "onSuccess", "onError"), "done")
            try:
                await manager.wrap_java_call(lambda target: target.onError(7, "bad"),
                                             manager.as_callback(failing, "onSuccess", "onError"))
            except Exception as error:
                return value, str(error)

        future = self.enter(scope, lambda: zwylib.async_manager.run_task(job()))
        self.pump(future.done, "the wrapped calls")
        self.assertEqual(future.result(), ("done", "Java error: 7 bad"))
        self.assertEqual((listener.seen, failing.seen), (["done"], [(7, "bad")]))

    def test_selector_dialog_resolves_to_the_clicked_index(self):
        scope = self.load()
        fragment = types.SimpleNamespace(getParentActivity=lambda: None)
        with patch("client_utils.get_last_fragment", return_value=fragment):
            future = self.enter(scope, lambda: zwylib.async_manager.run_task(
                zwylib.UI.SelectorDialog.show(title="Pick", items=["A", "B"], current_index=1)))
            self.pump(lambda: self.host.presented("alert"), "the selector dialog")
            config = self.host.presented("alert")[0]
            self.assertEqual((config["title"], config["items"]["labels"]), ("Pick", ["A", "\u2713 B"]))
            invoke("sample", config["items"]["on_click"], [None, 0])
            self.pump(future.done, "the selection")
        self.assertEqual(future.result(), 0)


class DialogAndHookTests(Case):
    def test_alert_dialog_maps_buttons_onto_the_builder(self):
        scope = self.load()
        clicked = []

        def work():
            dialog = zwylib.UI.AlertDialog(title="Title", text="Text", buttons=[
                zwylib.UI.AlertButton("Delete", lambda builder, which: clicked.append(which)),
                zwylib.UI.AlertButton("Keep", type=-2), None])
            dialog.show()
            dialog.show()
            return dialog

        dialog = self.enter(scope, work)
        config, = self.host.presented("alert")
        self.assertEqual((config["title"], config["message"], config["positive_button"]["text"],
                          config["negative_button"]["text"]), ("Title", "Text", "Delete", "Keep"))
        self.assertTrue(any("Alert already shown." in line for line in self.host.logged()))
        invoke("sample", config["positive_button"]["on_click"], [None, -1])
        self.assertEqual(clicked, [-1])
        # Once the click closed it, the same dialog can be shown and dismissed again.
        self.enter(scope, dialog.show)
        self.assertEqual((len(self.host.presented("alert")), len(self.host.showing)), (2, 2))
        self.enter(scope, dialog.dismiss)
        self.assertEqual(len(self.host.showing), 1)
        # The host cannot colour a button: a red one is presented uncoloured and that is logged.
        red = zwylib.UI.AlertDialog("Title", "Text", [zwylib.UI.AlertButton("Delete", red=True)])
        self.enter(scope, red.show)
        self.assertEqual(self.host.presented("alert")[2]["positive_button"]["text"], "Delete")
        self.assertEqual(sum("red button styling is not rendered on iOS" in line for line in self.host.logged()), 1)
        with bridge.runtime.context(scope), self.assertRaises(AttributeError):
            zwylib.UI.BottomSheet

    def test_hooks_register_through_the_plugin_and_reflection_is_not_faked(self):
        scope = self.load()
        seen = []

        def work():
            registration = zwylib.HookUtils.hook_before("synthetic member", lambda param: seen.append(param))
            replaced = zwylib.HookUtils.hook_replace("synthetic member", lambda param: "replacement", priority=5)
            with self.assertRaises(bridge.UnsupportedAPI):
                zwylib.HookUtils.find_max_args_method(bridge.runtime.jclass("java.util.ArrayList"), "add")
            with self.assertRaises(TypeError):
                zwylib.HookUtils.hook(None, "synthetic member")
            with self.assertRaisesRegex(bridge.BridgeError, "OWNERSHIP"):
                zwylib.HookUtils.hook("other", "synthetic member", before=print)
            return (registration, replaced, zwylib.HookUtils.hook_after(None, print),
                    zwylib.HookUtils.hook_before("member", "not callable"),
                    zwylib.HookUtils.find_max_args_method(None, "x"),
                    zwylib.HookUtils.get_private_field("not a java object", "field"))

        with patch.object(logging.root, "level", logging.WARNING):
            registration, replaced, *rejected = self.enter(scope, work)
        self.assertEqual(rejected, [None, None, None, None])
        hooks = [args for _, (_, args) in self.host.tokens.items() if args.get("kind") == "java_method"]
        self.assertEqual([(hook["method"], hook["priority"], "replace" in hook) for hook in hooks],
                         [("synthetic member", 0, False), ("synthetic member", 5, True)])
        invoke("sample", hooks[0]["before"], ["param"])
        self.assertEqual(invoke("sample", hooks[1]["replace"], ["param"]), "replacement")
        self.assertEqual(seen, ["param"])
        self.enter(scope, lambda: zwylib.HookUtils.unhook(registration))
        self.assertTrue(registration.closed)


if __name__ == "__main__":
    unittest.main()
