"""The ``url.open`` hook point: ``Browser.openUrl`` / ``openUrlInSystemBrowser`` hooks around a URL the app opens."""
from __future__ import annotations

import ast
import unittest
from unittest import mock

import pymembers_fixtures  # noqa: F401  puts the SDK on the path
import _ayu_xposed

BROWSER = "org.telegram.messenger.browser.Browser"
CONTEXT = object()


class UrlOpenTests(unittest.TestCase):
    def setUp(self):
        self.store, self.seen = {}, []
        for name, value in (("_store", lambda: self.store), ("method_of", lambda target: None)):
            patcher = mock.patch.object(_ayu_xposed, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def hook(self, label, target=_ayu_xposed.URL_OPEN, priority=50, before=None, after=None):
        hook = _ayu_xposed._Hook()
        installed = self.store.setdefault(target, [])
        hook.target, hook.store, hook.active, hook.callback = target, self.store, True, None
        hook.priority, hook.order, hook.before_filters, hook.after_filters = priority, len(installed), (), ()

        def phase(name, extra):
            def run(param):
                self.seen.append((f"{label} {name}", list(param.args)))
                if extra is not None:
                    extra(param)
            return run
        hook.before, hook.after = phase("before", before), phase("after", after)
        installed.append(hook)
        installed.sort(key=lambda item: (-item.priority, item.order))
        return _ayu_xposed.Unhook(hook)

    def test_both_methods_are_targets_of_one_point_and_need_its_operation(self):
        for method, target in (("openUrl", _ayu_xposed.URL_OPEN), ("openUrlInSystemBrowser", _ayu_xposed.URL_OPEN_SYSTEM)):
            self.assertEqual(_ayu_xposed.mapped(BROWSER, method), (target,))
            self.assertEqual(target.parameters, ("android.content.Context", "java.lang.String"))
            self.assertEqual(_ayu_xposed.requirement(f"{BROWSER}.{method}"), (("hooks.url_open",),))
        self.assertIsNone(_ayu_xposed.mapped(BROWSER, "openUrlInternal"))

    def test_static_preflight_names_the_target(self):
        source = ("class P(BasePlugin):\n    def on_plugin_load(self):\n"
                  f"        self.hook_all_methods(find_class('{BROWSER}'), 'openUrl', Hook(self))\n")
        self.assertEqual(_ayu_xposed.static_targets(ast.parse(source)), {"hook_all_methods": [f"{BROWSER}.openUrl"]})

    def test_without_a_hook_the_url_passes_untouched_and_no_context_is_resolved(self):
        self.assertEqual(_ayu_xposed.open_url("https://a.example/"), "https://a.example/")

    def test_before_and_after_run_in_xposed_order_with_context_then_url(self):
        self.hook("low", priority=10)
        self.hook("high", priority=90)
        self.assertEqual(_ayu_xposed.open_url("https://a.example/", CONTEXT), "https://a.example/")
        args = [CONTEXT, "https://a.example/"]
        self.assertEqual(self.seen, [("high before", args), ("low before", args), ("low after", args), ("high after", args)])

    def test_a_rewritten_url_is_the_one_opened_and_lower_hooks_see_it(self):
        def rewrite(param):
            param.args[1] = "https://b.example/"
        self.hook("high", priority=90, before=rewrite)
        self.hook("low", priority=10, after=lambda param: param.args.__setitem__(1, "https://late.example/"))
        self.assertEqual(_ayu_xposed.open_url("https://a.example/", CONTEXT), "https://b.example/")
        self.assertEqual(self.seen[1], ("low before", [CONTEXT, "https://b.example/"]))

    def test_a_result_set_before_cancels_the_open_and_one_set_after_does_not(self):
        cancel = self.hook("cancel", before=lambda param: param.setResult(None))
        self.assertIsNone(_ayu_xposed.open_url("https://a.example/", CONTEXT))
        self.assertEqual([label for label, _ in self.seen], ["cancel before", "cancel after"])
        cancel.unhook()
        self.hook("late", after=lambda param: param.setResult(None))
        self.assertEqual(_ayu_xposed.open_url("https://a.example/", CONTEXT), "https://a.example/")

    def test_a_null_url_or_a_throwable_cancels(self):
        first = self.hook("null", before=lambda param: param.args.__setitem__(1, None))
        self.assertIsNone(_ayu_xposed.open_url("https://a.example/", CONTEXT))
        first.unhook()
        self.hook("throw", before=lambda param: param.setThrowable(ValueError("no")))
        with mock.patch.object(_ayu_xposed, "_log", lambda message: None):
            self.assertIsNone(_ayu_xposed.open_url("https://a.example/", CONTEXT))

    def test_an_unhooked_callback_is_not_run_and_each_method_fires_its_own_hooks(self):
        handle = self.hook("open")
        self.hook("system", target=_ayu_xposed.URL_OPEN_SYSTEM)
        self.assertEqual(_ayu_xposed.open_url("tel:1", CONTEXT, system_browser=True), "tel:1")
        self.assertEqual([label for label, _ in self.seen], ["system before", "system after"])
        handle.unhook()
        del self.seen[:]
        self.assertEqual(_ayu_xposed.open_url("https://a.example/", CONTEXT), "https://a.example/")
        self.assertEqual((self.seen, _ayu_xposed.hook_count(_ayu_xposed.URL_OPEN)), ([], 0))


if __name__ == "__main__":
    unittest.main()
