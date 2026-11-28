"""Wave 7 messenger lane: ``AndroidUtilities.findActivity`` over the host's screen ``Context``."""
from __future__ import annotations

from pymembers_fixtures import CONTEXT, UTILITIES, HostCase, entry
import ayu_bridge as bridge
import java

CONFIG = "org.telegram.messenger.UserConfig"
IMPORTS = "from org.telegram.messenger import AndroidUtilities, ApplicationLoader\n"


class FindActivityTests(HostCase):
    def setUp(self):
        super().setUp()
        self.declare_application()

    def test_preflight_knows_the_member(self):
        body = "    def on_plugin_load(self):\n        self.activity = AndroidUtilities.findActivity(ApplicationLoader.applicationContext)\n"
        self.assertEqual(self.blockers(IMPORTS, body), [])

    def test_a_host_context_is_its_own_activity_and_null_stays_null(self):
        scope = self.load(imports=IMPORTS)
        with bridge.runtime.context(scope):
            utilities = java.jclass(UTILITIES)
            context = self.reference(CONTEXT, "context")
            self.assertIs(utilities.findActivity(context), context)
            self.assertIsNone(utilities.findActivity(None))
        self.assertNotIn((UTILITIES, "findActivity"), self.host_requests("java.invoke"))

    def test_anything_else_is_refused(self):
        scope = self.load(imports=IMPORTS)
        with bridge.runtime.context(scope):
            utilities = java.jclass(UTILITIES)
            for value in ("context", 1, self.reference("android.content.res.Resources", "resources")):
                with self.subTest(value=value), self.assertRaises(bridge.UnsupportedAPI):
                    utilities.findActivity(value)
            with self.assertRaises(TypeError):
                utilities.findActivity()


class IsValidAccountTests(HostCase):
    def setUp(self):
        super().setUp()
        self.asked = []

        def instance(target, args):
            self.asked.append(args[0])
            if args[0] != 0:
                raise bridge.BridgeError("ACCOUNT_UNAVAILABLE", "Requested account is not active")
            return {"$handle": "config", "$class": CONFIG}

        self.declare(CONFIG, {"getInstance": instance, "isClientActivated": lambda target, args: True},
                     entry(methods=["isClientActivated"], static_methods=["getInstance"], results={"getInstance": CONFIG}))

    def test_preflight_knows_the_member(self):
        body = "    def on_plugin_load(self):\n        self.valid = UserConfig.isValidAccount(0)\n"
        self.assertEqual(self.blockers("from org.telegram.messenger import UserConfig\n", body), [])

    def test_only_a_signed_in_account_below_the_android_limit_is_valid(self):
        scope = self.load(imports="from org.telegram.messenger import UserConfig\n")
        with bridge.runtime.context(scope):
            config = java.jclass(CONFIG)
            self.assertIs(config.isValidAccount(0), True)
            self.assertIs(config.isValidAccount(1), False)
            self.assertIs(config.isValidAccount(-1), False)
            self.assertIs(config.isValidAccount(16), False)
            self.assertEqual(self.asked, [0, 1])
            for value in ("0", 1.0, None, True, 1 << 31):
                with self.subTest(value=value), self.assertRaises(TypeError):
                    config.isValidAccount(value)

    def test_another_host_failure_is_not_read_as_an_invalid_account(self):
        scope = self.load(imports="from org.telegram.messenger import UserConfig\n")
        self.script[CONFIG]["getInstance"] = lambda target, args: (_ for _ in ()).throw(bridge.BridgeError("INVALID_HANDLE", "expired"))
        with bridge.runtime.context(scope), self.assertRaises(bridge.BridgeError):
            java.jclass(CONFIG).isValidAccount(0)


if __name__ == "__main__":
    import unittest
    unittest.main()
