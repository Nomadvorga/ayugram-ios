"""``PluginsController.getPluginPath`` and names Android's SDK does not have; synthetic plugins and a fake host."""
from __future__ import annotations

import os
import unittest

from pymembers_fixtures import HostCase
import ayu_bridge as bridge

IMPORT = "from com.exteragram.messenger.plugins import PluginsController\n"
PLUGINS = "com.exteragram.messenger.plugins.PluginsController"


class PluginPathTests(HostCase):
    def setUp(self):
        super().setUp()
        self.operations("plugins.list", "plugins.settings")
        perform = self.host.perform

        def listing(request):
            if request["operation"] == "plugins.list":
                return [{"id": "sample", "name": "Synthetic Plugin", "enabled": True},
                        {"id": "packed", "name": "Synthetic Package", "enabled": False}]
            return perform(request)

        self.host.perform = listing
        self.storage = os.path.join(self.home, "Library", "Application Support", "AyuPlugins")
        os.makedirs(self.storage)

    def store(self, name, text="__id__ = 'sample'\n"):
        with open(os.path.join(self.storage, name), "w", encoding="utf-8") as file:
            file.write(text)

    def test_path_is_the_file_the_service_stored(self):
        self.store("sample.plugin")
        self.store("packed.elyx", "archive")
        scope = self.load(imports=IMPORT)
        with bridge.runtime.context(scope):
            controller = scope.module.PluginsController.getInstance()
            path = controller.getPluginPath("sample")
            self.assertEqual(path, os.path.join(self.storage, "sample.plugin"))
            with open(path, "rb") as file:
                self.assertEqual(file.read(), b"__id__ = 'sample'\n")
            self.assertEqual(controller.getPluginPath("packed"), os.path.join(self.storage, "packed.elyx"))

    def test_unknown_and_empty_ids_have_no_path(self):
        self.store("absent.plugin")
        scope = self.load(imports=IMPORT)
        with bridge.runtime.context(scope):
            controller = scope.module.PluginsController.getInstance()
            for value in (None, "", "absent", "../sample"):
                with self.subTest(value=value):
                    self.assertIsNone(controller.getPluginPath(value))
            # Android builds the path of a listed plugin without looking at the file.
            self.assertEqual(controller.getPluginPath("sample"), os.path.join(self.storage, "sample.plugin"))
            with self.assertRaises(TypeError):
                controller.getPluginPath(7)

    def test_preflight_accepts_the_member(self):
        body = ("    def on_plugin_load(self):\n"
                "        PluginsController.getInstance().getPluginPath('sample')\n")
        self.assertEqual(self.blockers(IMPORT, body), [])
        body = body.replace("getPluginPath", "getPluginEngine")
        self.assertEqual(self.blockers(IMPORT, body), [("MEMBER", PLUGINS + ".getPluginEngine")])


class AndroidAbsentNamesTests(HostCase):
    """Android's SDK has no ``ui.dialogs`` and no ``client_utils.get_current_fragment``: both imports fail there."""

    GUARDED = ("try:\n    from ui.dialogs import show_alert\n    DIALOGS = 'imported'\n"
               "except Exception as error:\n    DIALOGS = isinstance(error, ImportError)\n"
               "try:\n    from client_utils import get_current_fragment\n    FRAGMENT = 'imported'\n"
               "except ImportError as error:\n    FRAGMENT = type(error).__name__\n")

    def test_names_missing_on_android_stay_missing(self):
        import client_utils
        self.assertFalse(hasattr(client_utils, "get_current_fragment"))
        with self.assertRaises(ImportError):
            __import__("ui.dialogs")

    def test_guarded_import_runs_the_fallback_and_does_not_block(self):
        self.assertEqual(self.blockers(self.GUARDED), [])
        scope = self.load(imports=self.GUARDED)
        self.assertEqual((scope.module.DIALOGS, scope.module.FRAGMENT), (True, "ImportError"))

    def test_unguarded_import_blocks(self):
        self.assertEqual(self.blockers("from ui.dialogs import show_alert\n", code="SDK_MEMBER"), ["ui.dialogs"])
        self.assertEqual(self.blockers("from client_utils import get_current_fragment\n", code="SDK_MEMBER"),
                         ["client_utils.get_current_fragment"])
        handled = "try:\n    from ui.dialogs import show_alert\nexcept ValueError:\n    pass\n"
        self.assertEqual(self.blockers(handled, code="SDK_MEMBER"), ["ui.dialogs"])

    def test_guarded_import_of_a_name_android_has_still_blocks(self):
        guarded = ("try:\n    from client_utils import _prepare_document\n    from ui.sheets import show\n"
                   "except ImportError:\n    pass\n")
        self.assertEqual(sorted(self.blockers(guarded, code="SDK_MEMBER")), ["client_utils._prepare_document", "ui.sheets"])


if __name__ == "__main__":
    unittest.main()
