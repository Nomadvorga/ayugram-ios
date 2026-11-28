"""``com.radolyn.ayugram.AyuState`` is absent on exteraGram Android; fragment members that stay refusals."""
from __future__ import annotations

from pymembers_fixtures import HostCase
import _ayu_inspection
import _ayu_operations

AYU = "com.radolyn.ayugram.AyuState"
GUARDED = ("try:\n    from com.radolyn.ayugram import AyuState\n    AYU = 'imported'\n"
           "except Exception as error:\n    AYU = isinstance(error, ImportError)\n")


class AyuStateTests(HostCase):
    def test_guarded_import_runs_the_fallback_and_does_not_block(self):
        self.assertIn(AYU, _ayu_inspection.ANDROID_ABSENT)
        self.assertEqual(self.blockers(GUARDED), [])
        scope = self.load(imports=GUARDED)
        self.assertIs(scope.module.AYU, True)

    def test_import_error_handler_catches_it_beside_a_declared_package(self):
        source = ("from com.exteragram.messenger.plugins import PluginsController\n"
                  "try:\n    from com.radolyn.ayugram import AyuState\n    AYU = 'imported'\n"
                  "except ImportError as error:\n    AYU = type(error).__name__\n")
        self.operations("plugins.list", "plugins.settings")
        self.assertEqual(self.blockers(source), [])
        scope = self.load(imports=source)
        self.assertEqual(scope.module.AYU, "ModuleNotFoundError")

    def test_unguarded_or_wrongly_guarded_import_blocks(self):
        self.assertEqual(self.blockers("from com.radolyn.ayugram import AyuState\n", code="CLASS"), [AYU])
        handled = "try:\n    from com.radolyn.ayugram import AyuState\nexcept ValueError:\n    pass\n"
        self.assertEqual(self.blockers(handled, code="CLASS"), [AYU])

    def test_other_classes_of_the_package_still_block(self):
        guarded = "try:\n    from com.radolyn.ayugram import AyuConfig\nexcept Exception:\n    pass\n"
        self.assertEqual(self.blockers(guarded, code="CLASS"), ["com.radolyn.ayugram.AyuConfig"])


class KeptRefusalsTests(HostCase):
    def test_members_without_a_faithful_host_stay_refusals(self):
        for name in ("finishFragment", "findMessageCell", "applyNewText", "queryFinalized", "getDeclaredField"):
            with self.subTest(name=name):
                self.assertIn(name, _ayu_operations.UNPROVIDED_MEMBERS)

    def test_closing_the_current_screen_blocks(self):
        imports = "from client_utils import get_last_fragment\n"
        body = ("    def on_plugin_load(self):\n"
                "        fragment = get_last_fragment()\n"
                "        if fragment:\n"
                "            fragment.finishFragment()\n")
        found = self.blockers(imports, body, code="OPERATION")
        self.assertTrue(any("finishFragment" in item for item in found), found)


if __name__ == "__main__":
    import unittest
    unittest.main()
