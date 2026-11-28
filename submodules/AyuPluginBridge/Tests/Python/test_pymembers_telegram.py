"""Members of Telegram host classes the SDK serves or composes, and the operation behind a gated local class.

The host is synthetic and plugin sources are test-authored.
"""
from __future__ import annotations

import os
import unittest

from pymembers_fixtures import CONTEXT, LOADER, METRICS, UTILITIES, HostCase, entry
import _ayu_javalib as javalib
import ayu_bridge as bridge
import file_utils
from _ayu_javalib import android_graphics, java_io, java_lang, telegram_messenger

CONTROLLER = "org.telegram.messenger.MessagesController"
ACCOUNT = "org.telegram.messenger.AccountInstance"
CONFIG = "org.telegram.messenger.UserConfig"
PLUGINS = "com.exteragram.messenger.plugins.PluginsController"
STORAGE = ("Library", "Application Support", "AyuPluginFiles")


class ApplicationLoaderTests(HostCase):
    def test_files_dir_fixed_is_the_context_files_directory(self):
        self.declare(LOADER)
        self.declare(CONTEXT)
        scope = self.load(imports="from org.telegram.messenger import ApplicationLoader\n")
        with bridge.runtime.context(scope):
            loader = scope.module.ApplicationLoader
            root = loader.getFilesDirFixed()
            self.assertIs(type(root), java_io.File)
            self.assertEqual(root.getAbsolutePath(), os.path.join(self.home, *STORAGE))
            self.assertEqual(root.getAbsolutePath(), self.reference(CONTEXT).getFilesDir().getAbsolutePath())
            self.assertEqual(java_io.File(root, "plugins").getAbsolutePath(), file_utils.get_plugins_dir())
            child = loader.getFilesDirFixed("made/by plugin")
            self.assertEqual(child.getAbsolutePath(), os.path.join(self.home, *STORAGE, "made", "by plugin"))
            self.assertTrue(child.isDirectory())
            for arguments in ((1,), (None,), ("a", "b")):
                with self.subTest(arguments=arguments), self.assertRaises(TypeError):
                    loader.getFilesDirFixed(*arguments)
            # Android answers null when the child cannot be created.
            with open(os.path.join(self.home, *STORAGE, "file"), "w"):
                pass
            self.assertIsNone(loader.getFilesDirFixed("file/below"))
            self.assertEqual(self.host_requests(), [])


class AndroidUtilitiesTests(HostCase):
    IMPORTS = "from org.telegram.messenger import AndroidUtilities\n"

    def utilities(self, **host):
        self.declare_application(**host)
        scope = self.load(imports=self.IMPORTS)
        return scope, scope.module.AndroidUtilities

    def test_density_is_the_factor_of_the_hosts_dp(self):
        scope, utilities = self.utilities()
        with bridge.runtime.context(scope):
            self.assertEqual(utilities.density, 1.0)
            self.assertIs(type(utilities.density), float)
            self.assertEqual(self.host.requests[-1]["arguments"]["args"], [1.0])
            # Android: dpf2(v) == density * v, whatever the host's unit is.
            self.assertEqual(utilities.dpf2(7.5), utilities.density * 7.5)
        bridge.unload_plugin("sample")
        scope, utilities = self.utilities(density=2.75)
        with bridge.runtime.context(scope):
            self.assertEqual(utilities.density, 2.75)

    def test_display_size_is_the_screen_in_the_unit_of_dp(self):
        scope, utilities = self.utilities(scale=3.0, pixels=(1206, 2622))
        with bridge.runtime.context(scope):
            size = utilities.displaySize
            self.assertIs(type(size), android_graphics.Point)
            self.assertEqual((size.x, size.y), (402, 874))
            self.assertIsNot(size, utilities.displaySize)
        bridge.unload_plugin("sample")
        scope, utilities = self.utilities(scale=2.0, pixels=(750, 1335), density=2.0)
        with bridge.runtime.context(scope):
            # ceil(screenWidthDp * density), as Android keeps it.
            self.assertEqual((utilities.displaySize.x, utilities.displaySize.y), (750, 1335))

    def test_invalid_host_answers_are_protocol_errors(self):
        scope, utilities = self.utilities()
        with bridge.runtime.context(scope):
            for value in (0, -1.0, True, "1", None):
                self.script[UTILITIES]["dpf2"] = lambda target, args, value=value: value
                with self.subTest(value=value), self.assertRaises(bridge.ProtocolError):
                    utilities.density
            self.script[UTILITIES]["dpf2"] = lambda target, args: args[0]
            for field, value in (("density", 0), ("widthPixels", 0), ("heightPixels", 1.5), ("density", "3")):
                saved = self.script[METRICS][field]
                self.script[METRICS][field] = value
                with self.subTest(field=field, value=value), self.assertRaises(bridge.ProtocolError):
                    utilities.displaySize
                self.script[METRICS][field] = saved

    def test_display_size_fails_when_the_host_has_no_screen(self):
        scope, utilities = self.utilities()

        def unavailable(target, args):
            raise bridge.BridgeError("screen_unavailable", "No visible display context")

        self.script[CONTEXT]["getResources"] = unavailable
        with bridge.runtime.context(scope), self.assertRaises(bridge.BridgeError) as caught:
            utilities.displaySize
        self.assertEqual(caught.exception.code, "screen_unavailable")

    def test_typeface_names_and_cache_directory(self):
        scope, utilities = self.utilities()
        with bridge.runtime.context(scope):
            self.assertEqual((utilities.TYPEFACE_ROBOTO_MEDIUM, utilities.TYPEFACE_ROBOTO_REGULAR, utilities.TYPEFACE_ROBOTO_MONO,
                              utilities.TYPEFACE_ROBOTO_MEDIUM_ITALIC, utilities.TYPEFACE_ROBOTO_CONDENSED_BOLD),
                             ("fonts/rmedium.ttf", "fonts/rregular.ttf", "fonts/rmono.ttf", "fonts/rmediumitalic.ttf",
                              "fonts/rcondensedbold.ttf"))
            # Android prefers the external cache directory.
            self.assertEqual(utilities.getCacheDir().getAbsolutePath(),
                             self.reference(CONTEXT).getExternalCacheDir().getAbsolutePath())
            # The typefaces themselves need the host.
            for name in ("bold", "getTypeface", "statusBarHeight"):
                with self.subTest(name), self.assertRaises(bridge.MissingMember):
                    getattr(utilities, name)

    def test_preflight_knows_the_composed_fields(self):
        self.declare_application()
        body = ("    def on_plugin_load(self):\n"
                "        width = AndroidUtilities.displaySize.x - AndroidUtilities.dp(84)\n"
                "        scaled = AndroidUtilities.density * 2\n"
                "        AndroidUtilities.getCacheDir().getAbsolutePath()\n"
                "        AndroidUtilities.displaySize.z\n"
                "        AndroidUtilities.density = 2\n"
                "        AndroidUtilities.bold()\n")
        self.assertEqual(self.blockers(self.IMPORTS, body), [
            ("MEMBER", "android.graphics.Point.z"), ("MEMBER", "org.telegram.messenger.AndroidUtilities.bold"),
            ("MEMBER", "org.telegram.messenger.AndroidUtilities.density (write)")])


class UserConfigTests(HostCase):
    def test_account_limit_and_client_user_id(self):
        self.declare(CONFIG, {"getClientUserId": lambda target, args: 5_000_000_001 if target.get("$handle") else None},
                     entry(methods=["getClientUserId"], static_methods=["getInstance"], results={"getInstance": CONFIG}))
        scope = self.load(imports="from org.telegram.messenger import UserConfig\n")
        with bridge.runtime.context(scope):
            config = scope.module.UserConfig
            self.assertEqual((config.MAX_ACCOUNT_COUNT, config.MAX_ACCOUNT_DEFAULT_COUNT), (16, 8))
            self.assertEqual(self.reference(CONFIG).clientUserId, 5_000_000_001)
            self.assertEqual(self.host_requests("java.invoke"), [(CONFIG, "getClientUserId")])
        body = ("    def on_plugin_load(self):\n"
                "        for index in range(UserConfig.MAX_ACCOUNT_COUNT):\n"
                "            UserConfig.getInstance(index).clientUserId\n"
                "        UserConfig.getInstance(0).isPremium()\n")
        self.assertEqual(self.blockers("from org.telegram.messenger import UserConfig\n", body),
                         [("MEMBER", "org.telegram.messenger.UserConfig.isPremium")])


class GatedOverrideTests(HostCase):
    """``MessagesController``: the host adapter answers until ``telegram.peer`` makes the local class usable."""
    IMPORTS = "from org.telegram.messenger import MessagesController, AccountInstance\n"
    BODY = ("    def on_plugin_load(self):\n"
            "        controller = MessagesController.getInstance(0)\n"
            "        controller.getChat(1)\n"
            "        controller.getInputPeer(1)\n"
            "        controller.openByUserName('name', None, 0)\n"
            "        controller.rebuildAllCaches([], False)\n"
            "        MessagesController.UPDATE_MASK_NAME | MessagesController.DIALOG_FILTER_FLAG_BOTS\n"
            "        AccountInstance.getInstance(0).getSendMessagesHelper()\n")

    def setUp(self):
        HostCase.setUp(self)
        self.declare(CONTROLLER, table=entry(methods=["getChat", "getUser"], static_methods=["getInstance"],
                                             results={"getInstance": CONTROLLER}))
        self.declare(ACCOUNT, table=entry(methods=["getMessagesController"], static_methods=["getInstance"],
                                          results={"getInstance": ACCOUNT}))

    def test_member_of_the_gated_local_class_is_an_operation_blocker(self):
        self.assertEqual(self.blockers(self.IMPORTS, self.BODY), [
            ("OPERATION", "telegram.peer (org.telegram.messenger.AccountInstance.getSendMessagesHelper)"),
            ("OPERATION", "telegram.peer (org.telegram.messenger.MessagesController.getInputPeer)"),
            ("OPERATION", "telegram.peer (org.telegram.messenger.MessagesController.openByUserName)"),
            # Nothing provides it, whatever the host declares.
            ("MEMBER", "org.telegram.messenger.MessagesController.rebuildAllCaches")])
        report = self.preflight(self.IMPORTS, self.BODY)
        self.assertNotIn("gated", report["member_accesses"])
        self.assertEqual(report["member_accesses"]["missing_accesses"], 4)

    def test_declared_operations_leave_only_what_nothing_provides(self):
        self.operations("telegram.peer")
        found = self.blockers(self.IMPORTS, self.BODY)
        self.assertEqual([item for item in found if item[0] == "MEMBER"],
                         [("MEMBER", "org.telegram.messenger.MessagesController.rebuildAllCaches")])
        self.assertFalse([item for item in found if "telegram.peer" in item[1]])

    def test_constants_are_served_on_the_host_adapter(self):
        scope = self.load(imports=self.IMPORTS)
        with bridge.runtime.context(scope):
            controller = scope.module.MessagesController
            self.assertIsInstance(controller, bridge.JavaClass)
            self.assertEqual((controller.UPDATE_MASK_NAME, controller.UPDATE_MASK_ALL, controller.DIALOG_FILTER_FLAG_BOTS,
                              controller.DIALOG_FILTER_FLAG_ALL_CHATS, controller.DIALOG_FILTER_FLAG_CHATLIST_ADMIN),
                             (1, 1535, 16, 31, 1024))
            self.assertEqual(self.host_requests(), [])
            # The reference client has no such constant.
            with self.assertRaises(bridge.MissingMember):
                controller.UPDATE_MASK_CHAT_ADMINS
        local = telegram_messenger.MessagesController
        self.assertEqual((local.UPDATE_MASK_ALL, local.DIALOG_FILTER_FLAG_ALL_CHATS), (1535, 31))

    def test_gate_answers_only_for_a_gated_overriding_class(self):
        import _ayu_members
        capabilities = bridge.runtime._capabilities()
        tables = _ayu_members.Tables(capabilities)
        self.assertEqual(tables.gate(CONTROLLER, "getInputPeer", "read"), "telegram.peer")
        self.assertEqual(tables.gate(CONTROLLER, "<init>", "construct"), "telegram.peer")
        self.assertIsNone(tables.gate(CONTROLLER, "rebuildAllCaches", "read"))
        self.assertIsNone(tables.gate("example.Native", "echo", "read"))
        self.assertIsNone(tables.gate("java.io.File", "vanished", "read"))
        self.operations("telegram.peer")
        self.assertIsNone(_ayu_members.Tables(bridge.runtime._capabilities()).gate(CONTROLLER, "getInputPeer", "read"))


class ThemeTests(HostCase):
    def test_mult_alpha_scales_truncates_and_clamps_the_alpha(self):
        self.declare("org.telegram.ui.ActionBar.Theme", table=entry(static_methods=["getColor"]))
        scope = self.load(imports="from org.telegram.ui.ActionBar import Theme\n")
        with bridge.runtime.context(scope):
            theme = scope.module.Theme
            # 0xFF336699 as Java's int; alpha 255 * 0.5 = 127.5, truncated.
            self.assertEqual(theme.multAlpha(-13408615, 0.5), 0x7F336699)
            self.assertEqual(theme.multAlpha(0xFF336699, 0.5), 0x7F336699)
            self.assertEqual(theme.multAlpha(-13408615, 1), -13408615)
            self.assertEqual(theme.multAlpha(0x80FFFFFF - (1 << 32), 4.0), -1)
            self.assertEqual(theme.multAlpha(-1, -2.0), 0x00FFFFFF)
            self.assertEqual(theme.multAlpha(-1, float("nan")), 0x00FFFFFF)
            self.assertEqual(theme.multAlpha(0x40102030, 0.3), 0x13102030)
            for arguments in ((1,), (1, 2, 3), ("1", 1.0), (1, "1"), (1.5, 1.0), (1, True)):
                with self.subTest(arguments=arguments), self.assertRaises(TypeError):
                    theme.multAlpha(*arguments)
            self.assertEqual(self.host_requests(), [])
        body = "    def on_plugin_load(self):\n        Theme.multAlpha(Theme.getColor(1), 0.5)\n        Theme.key_divider\n"
        self.assertEqual(self.blockers("from org.telegram.ui.ActionBar import Theme\n", body),
                         [("MEMBER", "org.telegram.ui.ActionBar.Theme.key_divider")])


class FacadeClassTests(HostCase):
    def test_local_facades_answer_get_class_with_their_java_name(self):
        self.operations("telegram.peer", "plugins.list", "plugins.settings")
        scope = self.load(imports="from org.telegram.messenger import MessagesController, BuildVars\n"
                                  "from com.exteragram.messenger.plugins import PluginsController\n")
        with bridge.runtime.context(scope):
            controller = scope.module.MessagesController
            self.assertIs(controller, telegram_messenger.MessagesController)
            mirror = controller.getClass()
            self.assertIsInstance(mirror, java_lang.Class)
            self.assertEqual((mirror.getName(), mirror.getSimpleName(), mirror.getPackageName()),
                             (CONTROLLER, "MessagesController", "org.telegram.messenger"))
            self.assertEqual(controller.getInstance(0).getClass(), mirror)
            self.assertIsInstance(mirror.getClassLoader(), java_lang.ClassLoader)
            self.assertEqual(scope.module.PluginsController.getInstance().getClass().getName(), PLUGINS)
            # Members are reflected from the class's model; Java selects ``getUser(Long)`` by its parameter.
            self.assertEqual(mirror.getDeclaredMethod("getUser", java_lang.Long.getClass()).getName(), "getUser")
            with self.assertRaises(java_lang.NoSuchMethodException):
                mirror.getDeclaredMethod("getUser")
            self.assertEqual(scope.module.BuildVars.BUILD_VERSION, 7303)
        body = ("    def on_plugin_load(self):\n"
                "        MessagesController.getClass().getName()\n"
                "        PluginsController.getInstance().getClass().getSimpleName()\n"
                "        BuildVars.BUILD_VERSION\n")
        self.assertEqual(self.blockers("from org.telegram.messenger import MessagesController, BuildVars\n"
                                       "from com.exteragram.messenger.plugins import PluginsController\n", body), [])

    def test_plugins_controller_lists_plugins_and_names_their_directory(self):
        self.operations("plugins.list", "plugins.settings")
        perform = self.host.perform

        def listing(request):
            if request["operation"] == "plugins.list":
                return [{"id": "sample", "name": "Synthetic Plugin", "enabled": True}]
            return perform(request)

        self.host.perform = listing
        scope = self.load(imports="from com.exteragram.messenger.plugins import PluginsController\n")
        with bridge.runtime.context(scope):
            controller = scope.module.PluginsController.getInstance()
            self.assertEqual(list(controller.getPlugins().keySet()), ["sample"])
            self.assertEqual(controller.getPlugins().get("sample").getName(), controller.plugins.get("sample").getName())
            directory = controller.pluginsDir
            self.assertIs(type(directory), java_io.File)
            self.assertEqual(directory.getAbsolutePath(), file_utils.get_plugins_dir())
            for name in ("setPluginEnabled", "deletePlugin", "getPluginEngine"):
                with self.subTest(name), self.assertRaises(bridge.UnsupportedAPI):
                    getattr(controller, name)
        self.assertNotIn(PLUGINS, javalib.local_class_names(["plugins.list"]))


if __name__ == "__main__":
    unittest.main()
