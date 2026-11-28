"""Members Android's own classes lack: a plugin that absorbs their absence runs the same on both platforms."""
from __future__ import annotations

from pymembers_fixtures import HostCase, entry
import ayu_bridge as bridge
import java

THEME = "org.telegram.ui.ActionBar.Theme"
IMPORTS = "from org.telegram.ui.ActionBar import Theme\n"


class AndroidAbsentMemberTests(HostCase):
    def setUp(self):
        super().setUp()
        self.declare(THEME, {"getColor": lambda target, args: -1}, entry(static_methods=["getColor"], static_fields=["key_dialogTextBlack"]))

    def blockers_of(self, statements):
        return self.blockers(IMPORTS, "    def on_plugin_load(self):\n" + "".join("        " + line + "\n" for line in statements))

    def test_an_absorbed_read_of_a_key_android_lacks_blocks_nothing(self):
        for handler in ("except Exception as error:", "except:", "except (ValueError, AttributeError):", "except BaseException:"):
            with self.subTest(handler=handler):
                self.assertEqual(self.blockers_of(["try:", "    color = Theme.getColor(Theme.key_dialogButtonRed)", handler, "    color = 0"]), [])

    def test_the_same_read_blocks_when_nothing_absorbs_it(self):
        missing = [("MEMBER", THEME + ".key_dialogButtonRed")]
        self.assertEqual(self.blockers_of(["color = Theme.key_dialogButtonRed"]), missing)
        self.assertEqual(self.blockers_of(["try:", "    color = Theme.key_dialogButtonRed", "except ValueError:", "    color = 0"]), missing)
        self.assertEqual(self.blockers_of(["try:", "    color = Theme.key_dialogButtonRed", "except Exception:", "    raise"]), missing)
        # The function runs after the try has ended.
        self.assertEqual(self.blockers_of(["try:", "    read = lambda: Theme.key_dialogButtonRed", "except Exception:", "    read = None"]), missing)

    def test_a_key_android_has_still_blocks_behind_a_blanket_handler(self):
        self.assertEqual(self.blockers_of(["try:", "    color = Theme.key_actionBarDefault", "except Exception:", "    color = 0"]),
                         [("MEMBER", THEME + ".key_actionBarDefault")])

    def test_the_read_raises_what_the_handler_absorbs(self):
        scope = self.load(imports=IMPORTS)
        with bridge.runtime.context(scope):
            with self.assertRaises(AttributeError):
                java.jclass(THEME).key_dialogButtonRed
