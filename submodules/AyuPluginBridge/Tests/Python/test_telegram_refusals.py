"""The Swift table of functions ``telegram.request`` refuses, recomputed from the iOS TL scheme."""
import importlib.util
from pathlib import Path
import re
import sys
import unittest

BRIDGE = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(BRIDGE / "Python"))

from _ayu_javalib import telegram_tl as tl


def _script():
    spec = importlib.util.spec_from_file_location("telegram_refused_functions", BRIDGE / "Build" / "telegram_refused_functions.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


SCRIPT = _script()


class RefusedFunctionTests(unittest.TestCase):
    def setUp(self):
        self.scheme = SCRIPT.SCHEME.read_text("utf-8")
        self.derived = SCRIPT.refused_functions(self.scheme)

    def test_swift_literal_matches_the_scheme(self):
        swift = SCRIPT.SWIFT.read_text("utf-8")
        self.assertEqual(SCRIPT.swift_table(swift), self.derived)
        # Regenerating the literal changes nothing, so the file also keeps the script's layout.
        self.assertIn(SCRIPT.swift_literal(self.derived), swift)

    def test_table_covers_what_the_contract_names(self):
        names = set(self.derived.values())
        declared = {name for name, _, _ in SCRIPT.functions(self.scheme)}
        self.assertEqual({name for name in declared if name.startswith("auth.")}, {name for name in names if name.startswith("auth.")})
        self.assertLessEqual(SCRIPT.ACCOUNT_FUNCTIONS, names)
        wrappers = {name for name in declared if name.startswith("invoke") or name == "initConnection"}
        self.assertEqual(wrappers, {name for name in names if "." not in name})
        self.assertGreaterEqual(wrappers, {"invokeAfterMsg", "invokeAfterMsgs", "invokeWithLayer", "invokeWithoutUpdates", "initConnection"})
        # Nothing else is refused: the bridge does not silently narrow the API.
        self.assertEqual({name for name in names if name.startswith("account.")}, set(SCRIPT.ACCOUNT_FUNCTIONS))
        self.assertEqual(len(names), len(self.derived))

    def test_a_wrapper_without_the_invoke_prefix_is_still_refused(self):
        scheme = ("boolTrue#997275b5 = Bool;\n---functions---\n"
                  "account.deleteAccount#a2c0cf74 flags:# reason:string = Bool;\n"
                  "account.resetAuthorization#df77f3bc hash:long = Bool;\n"
                  "account.resetPassword#9308ce1b = account.ResetPasswordResult;\n"
                  "account.updatePasswordSettings#a59b102f password:InputCheckPasswordSRP = Bool;\n"
                  "initConnection#c1cd5ea9 {X:Type} flags:# query:!X = X;\n"
                  "wrapQuery#00000001 {X:Type} query:!X = X;\n"
                  "help.getConfig#c4f9186b = Config;\n")
        refused = SCRIPT.refused_functions(scheme)
        self.assertEqual(refused[1], "wrapQuery")
        self.assertNotIn(0xC4F9186B, refused)
        with self.assertRaises(ValueError):
            SCRIPT.refused_functions(scheme.replace("account.resetPassword#9308ce1b", "account.other#9308ce1b"))

    def test_sdk_constructor_ids_agree_with_the_table(self):
        """The SDK serializes these functions with the ids the host refuses."""
        checked = 0
        for constructor, name in self.derived.items():
            cls = tl.class_for(constructor)
            if cls is None:
                continue
            self.assertTrue(tl.is_function(cls), name)
            self.assertEqual(cls.constructor & 0xFFFFFFFF, constructor)
            checked += 1
        self.assertGreaterEqual(checked, 30)
        log_out = tl.class_for(0x3E72BA19)
        self.assertEqual(tl.simple_name(log_out), "TL_auth_logOut")

    def test_swift_source_names_no_operation_in_a_scraped_literal(self):
        """The corpus meter reads ``let operations``/``let capabilities`` literals; the Telegram plane has none."""
        pattern = re.compile(r"\blet\s+(?:operations|capabilities)\s*=\s*\[")
        for name in ("AyuPluginTelegramBackend.swift", "AyuPluginTelegramBridge.swift", "AyuPluginTelegramHooks.swift"):
            self.assertIsNone(pattern.search((BRIDGE / "Integration" / name).read_text("utf-8")), name)


if __name__ == "__main__":
    unittest.main()
