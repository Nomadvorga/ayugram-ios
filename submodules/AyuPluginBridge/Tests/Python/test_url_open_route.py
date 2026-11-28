"""``hooks.url_open``: the host asks a plugin's ``Browser.openUrl`` hooks about a URL through one dispatcher."""
from __future__ import annotations

import json

from pymembers_fixtures import CONTEXT, HostCase, entry  # puts the SDK on the path
import ayu_bridge as bridge

BROWSER = "org.telegram.messenger.browser.Browser"
LOADER = "org.telegram.messenger.ApplicationLoader"
IMPORTS = "from hook_utils import find_class\n"
BODY = ("    def on_plugin_load(self):\n"
        "        self.seen = []\n"
        "    def note(self, label, then=None):\n"
        "        def callback(param):\n"
        "            self.seen.append((label, param.args[1]))\n"
        "            if then is not None:\n"
        "                then(param)\n"
        "        return callback\n")


class UrlOpenRouteTests(HostCase):
    def setUp(self):
        super().setUp()
        self.operations("hooks.url_open")
        self.declare(BROWSER, {}, entry(static_methods=["openUrl", "openUrlInSystemBrowser"]))
        self.declare(LOADER, {"applicationContext": {"$handle": "context", "$class": CONTEXT}}, entry(static_fields=["applicationContext"]))
        self.declare(CONTEXT, {}, entry(methods=["getResources"]))
        self.routes = []
        perform = self.host.perform

        def routing(request):
            if request["operation"] == "hooks.url_open" and request["plugin_id"] in self.host.active:
                self.routes.append(request["arguments"])
                return None
            return perform(request)

        self.host.perform = routing

    def ask(self, scope, url, system_browser=False):
        """The host's question about one URL, through the dispatcher it was last given."""
        callback = self.routes[-1]["callback"]["$callback"]
        return json.loads(bridge.invoke_callback_json(json.dumps({
            "version": 1, "plugin_id": scope.plugin_id, "callback_id": callback, "arguments": [url, system_browser]})))

    def test_the_first_hook_registers_one_dispatcher_and_a_higher_priority_replaces_it(self):
        scope = self.load(imports=IMPORTS, body=BODY)
        plugin = scope.instance
        self.assertEqual(self.routes, [])
        with bridge.runtime.context(scope):
            browser = scope.module.find_class(BROWSER)
            plugin.hook_all_methods(browser, "openUrl", before=plugin.note("open"))
            plugin.hook_all_methods(browser, "openUrlInSystemBrowser", before=plugin.note("system"), priority=20)
            plugin.hook_all_methods(browser, "openUrl", before=plugin.note("high"), priority=90)
        self.assertEqual([route["priority"] for route in self.routes], [50, 90])
        self.assertEqual(len({route["callback"]["$callback"] for route in self.routes}), 1)

    def test_the_dispatcher_answers_with_the_url_a_rewrite_or_a_cancellation(self):
        scope = self.load(imports=IMPORTS, body=BODY)
        plugin = scope.instance

        def rewrite(param):
            if param.args[1].startswith("https://music."):
                param.args[1] = "https://other.example/track"
            elif param.args[1].startswith("https://blocked."):
                param.setResult(None)

        with bridge.runtime.context(scope):
            browser = scope.module.find_class(BROWSER)
            plugin.hook_all_methods(browser, "openUrl", before=plugin.note("open", rewrite))
            plugin.hook_all_methods(browser, "openUrlInSystemBrowser", before=plugin.note("system"))
        self.assertEqual(self.ask(scope, "https://a.example/"), {"url": "https://a.example/"})
        self.assertEqual(self.ask(scope, "https://music.example/1"), {"url": "https://other.example/track"})
        self.assertEqual(self.ask(scope, "https://blocked.example/"), {"url": None})
        self.assertEqual(self.ask(scope, "tel:1", system_browser=True), {"url": "tel:1"})
        self.assertEqual(plugin.seen, [("open", "https://a.example/"), ("open", "https://music.example/1"),
                                       ("open", "https://blocked.example/"), ("system", "tel:1")])

    def test_without_the_operation_the_hook_is_refused_and_nothing_is_routed(self):
        self.operations(remove=("hooks.url_open",))
        scope = self.load(imports=IMPORTS, body=BODY)
        with bridge.runtime.context(scope), self.assertRaises(bridge.UnsupportedAPI):
            scope.instance.hook_all_methods(scope.module.find_class(BROWSER), "openUrl", before=scope.instance.note("open"))
        self.assertEqual(self.routes, [])


if __name__ == "__main__":
    import unittest
    unittest.main()
