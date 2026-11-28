import json
import unittest

import test_bridge as fixtures
import ayu_bridge as bridge


class SendParamsCompatibilityTests(unittest.TestCase):
    setUp = fixtures.BridgeTests.setUp
    tearDown = fixtures.BridgeTests.tearDown

    def test_send_hook_supports_attributes_and_dictionary_with_exact_ids(self):
        text = fixtures.source("sendattrs", imports="from base_plugin import HookResult, HookStrategy\n",
            body=('    def on_plugin_load(self):\n        self.add_on_send_message_hook()\n'
                  '    def on_send_message_hook(self, account, params):\n'
                  '        assert params.peer == 9007199254740993\n'
                  '        assert params["message"] == params.message\n'
                  '        assert params.caption is None\n'
                  '        params.message += " changed"\n'
                  '        return HookResult(HookStrategy.MODIFY_FINAL, params=params)\n'))
        bridge.load_plugin(text)
        request = next(r for r in self.host.requests if r["operation"] == "hooks.register")
        callback = request["arguments"]["callback"]["$callback"]
        result = json.loads(bridge.invoke_callback_json(json.dumps({"version": 1, "plugin_id": "sendattrs",
            "callback_id": callback, "arguments": [3, {"peer": 9007199254740993, "message": "original"}]})))
        self.assertEqual(result["strategy"], 3)
        self.assertEqual(result["params"], {"peer": 9007199254740993, "message": "original changed"})

    def test_undeclared_send_fields_are_not_fabricated(self):
        from base_plugin import _SendMessageParams
        params = _SendMessageParams(peer=4, message="test")
        with self.assertRaises(AttributeError):
            _ = params.unknown_native_field
        with self.assertRaises(bridge.UnsupportedAPI):
            params.unknown_native_field = True


if __name__ == "__main__":
    unittest.main()
