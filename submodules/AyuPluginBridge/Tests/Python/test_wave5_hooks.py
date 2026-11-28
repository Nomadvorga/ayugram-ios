"""Hook registrations Android drops (a non-hook object where ``xposed_hook`` belongs) against a scripted host."""
from __future__ import annotations

import unittest
from unittest import mock

from pymembers_fixtures import HostCase  # puts the SDK on the path
import _ayu_hook_map
import ayu_bridge as bridge

IMPORTS = ("from base_plugin import MethodHook, MethodReplacement\nfrom hook_utils import find_class\n\n\n"
           "class Resume(MethodHook):\n    def after_hooked_method(self, param):\n        pass\n")
LOAD = "    def on_plugin_load(self):\n"
DROPPED = {
    "hook_method": "        self.hook_method('org.telegram.ui.ChatActivity', 'onResume', Resume())\n",
    "hook_all_methods": "        self.hook_all_methods(find_class('org.telegram.ui.ChatActivity'), 'onResume', 'after', Resume())\n",
    "hook_all_constructors": "        self.hook_all_constructors(find_class('org.telegram.ui.ChatActivity'), xposed_hook=1)\n",
}
REAL = {
    "hook_method": "        self.hook_method(find_class('org.telegram.ui.ChatActivity').getClass().getDeclaredMethod('onResume'), Resume())\n",
    "hook_all_methods": "        self.hook_all_methods(find_class('org.telegram.ui.ChatActivity'), 'onResume', Resume())\n",
    "hook_all_constructors": "        self.hook_all_constructors(find_class('org.telegram.ui.ChatActivity'), Resume())\n",
}


class PreflightTests(HostCase):
    def operation_blockers(self, body):
        return self.blockers(IMPORTS, LOAD + body, "OPERATION")

    def test_a_call_android_drops_needs_no_hook_target(self):
        for api, line in DROPPED.items():
            with self.subTest(api):
                self.assertEqual(self.operation_blockers(line), [])
        self.assertEqual(self.operation_blockers("".join(DROPPED.values())), [])

    def test_a_real_hook_on_an_unmapped_target_stays_blocked(self):
        for api, line in REAL.items():
            with self.subTest(api):
                self.assertEqual(self.operation_blockers(line), [f"hooks.java_method ({api}())"])
                # One dropped call does not excuse another call of the same API.
                self.assertEqual(self.operation_blockers(DROPPED[api] + line), [f"hooks.java_method ({api}())"])

    def test_only_a_truthy_literal_in_the_hook_position_is_dropped(self):
        cases = {
            "        self.hook_method('org.telegram.ui.ChatActivity', self.name, Resume())\n": "hook_method",
            "        self.hook_method('org.telegram.ui.ChatActivity', '', after=self.done)\n": "hook_method",
            "        self.hook_method('org.telegram.ui.ChatActivity', None, 'onResume')\n": "hook_method",
            "        self.hook_method('org.telegram.ui.ChatActivity', *self.rest)\n": "hook_method",
            "        self.hook_all_methods(find_class('org.telegram.ui.ChatActivity'), 'onResume', 0, before=self.done)\n": "hook_all_methods",
            "        self.hook_all_methods('org.telegram.ui.ChatActivity', 'onResume')\n": "hook_all_methods",
        }
        for line, api in cases.items():
            with self.subTest(line):
                self.assertEqual(self.operation_blockers(line), [f"hooks.java_method ({api}())"])


class RuntimeTests(HostCase):
    def registrations(self):
        return [item for item in self.host.requests if item["operation"] == "hooks.register"]

    def test_android_logs_and_returns_none_without_registering(self):
        scope = self.load(imports=IMPORTS)
        plugin, module = scope.instance, scope.module
        with bridge.runtime.context(scope), mock.patch("android_utils.log") as log:
            self.assertIsNone(plugin.hook_method("org.telegram.ui.ChatActivity", "onResume", module.Resume()))
            self.assertIsNone(plugin.hook_all_methods("org.telegram.ui.ChatActivity", "onResume", 7, before=print))
            self.assertIsNone(plugin.hook_all_constructors("org.telegram.ui.ChatActivity", object()))
        self.assertEqual([call.args[0].partition("] ")[2] for call in log.call_args_list],
                         ["Could not determine hook type for str.", "Could not determine hook type for int.",
                          "Could not determine hook type for object."])
        self.assertEqual(self.registrations(), [])

    def test_a_hook_object_still_goes_to_the_host(self):
        scope = self.load(imports=IMPORTS)
        plugin, module = scope.instance, scope.module
        with bridge.runtime.context(scope):
            for register in (lambda: plugin.hook_method("org.telegram.ui.ChatActivity", module.Resume()),
                             lambda: plugin.hook_all_methods("org.telegram.ui.ChatActivity", "onResume", module.Resume()),
                             lambda: plugin.hook_all_constructors("org.telegram.ui.ChatActivity", module.Resume())):
                try:
                    register()
                except bridge.BridgeError:
                    pass
        self.assertEqual([item["arguments"]["kind"] for item in self.registrations()],
                         ["java_method", "java_all_methods", "java_all_constructors"])

    def test_what_android_takes_for_a_hook(self):
        scope = self.load(imports=IMPORTS)
        module = scope.module

        class Replace(module.MethodReplacement):
            pass

        class Duck:
            def before_hooked_method(self, param):
                pass

        class Named:
            replace_hooked_method = None

        class Bare(module.MethodHook):
            pass

        for hook in (module.Resume(), Replace(), Duck(), Named(), Bare(), None, "", 0):
            self.assertFalse(_ayu_hook_map.undetermined(hook), hook)
        for hook in ("onResume", 7, object(), print):
            self.assertTrue(_ayu_hook_map.undetermined(hook), hook)


if __name__ == "__main__":
    unittest.main()
