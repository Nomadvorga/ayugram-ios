"""Additional client helper contracts using synthetic host operations only."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Python"))

import ayu_bridge as bridge
import client_utils as client
import test_bridge as harness
from test_client_compat import ClientHost


class ExpansionHost(ClientHost):
    request_result = 2**63 - 1

    def perform(self, request):
        args = request.get("arguments", {})
        if (request["operation"] == "client.call" and args.get("name") == "send_request"
                and self.synthetic_requests):
            if request["plugin_id"] not in self.active:
                raise bridge.BridgeError("OWNERSHIP", "Inactive owner")
            self.client_requests.append(args)
            return self.request_result
        return super().perform(request)


class ClientExpansionTests(unittest.TestCase):
    load = harness.BridgeTests.load
    tearDown = harness.BridgeTests.tearDown

    def setUp(self):
        harness.BridgeTests.setUp(self)
        self.host = ExpansionHost()
        sys.modules["_ayu_host"].dispatch = self.host.dispatch
        self.scope = self.load()

    def test_send_text_preserves_signed_int64_peer_boundaries(self):
        self.host.synthetic_messages = True
        with bridge.runtime.context(self.scope):
            low = client.send_text(-(2**63), "low", account=2**53 + 17)
            high = client.send_text(2**63 - 1, "high", account=2**63 - 1)

        self.assertEqual(low["args"][0], {"peer": -(2**63), "message": "low"})
        self.assertEqual(low["kwargs"], {"account": 2**53 + 17})
        self.assertEqual(high["args"][0], {"peer": 2**63 - 1, "message": "high"})
        self.assertEqual(high["kwargs"], {"account": 2**63 - 1})

    def test_invalid_peer_values_fail_before_transport(self):
        self.host.synthetic_messages = True
        with bridge.runtime.context(self.scope):
            before = len(self.host.client_requests)
            for peer, error in ((True, TypeError), (1.0, TypeError), ("7", TypeError),
                                (-(2**63) - 1, ValueError), (2**63, ValueError)):
                with self.subTest(peer=peer), self.assertRaises(error):
                    client.send_text(peer, "not sent")
            for params in ({"peer": False, "message": "not sent"},
                           {"peer": 2**63, "message": "not sent"}):
                with self.subTest(params=params), self.assertRaises((TypeError, ValueError)):
                    client.send_message(params)
            with self.assertRaises(TypeError):
                client.send_text(1, None)
            self.assertEqual(len(self.host.client_requests), before)

    def test_log_uses_only_existing_owner_scoped_host_logging(self):
        with bridge.runtime.context(self.scope):
            self.assertIsNone(client.log("synthetic client log"))

        log_requests = [request for request in self.host.requests if request["operation"] == "log.write"]
        self.assertEqual(len(log_requests), 1)
        self.assertEqual(log_requests[0]["arguments"], {
            "level": "info", "message": "synthetic client log"})
        self.assertEqual(log_requests[0]["plugin_id"], self.scope.plugin_id)

    def test_invalid_send_request_result_releases_registered_callback(self):
        self.host.synthetic_requests = True
        with bridge.runtime.context(self.scope):
            for result in (True, 1.0, -1, 2**63, None):
                before = dict(self.scope.callbacks)
                self.host.request_result = result
                with self.subTest(result=result), self.assertRaises(bridge.ProtocolError):
                    client.send_request({"synthetic": True}, lambda *_: None, account=9)
                self.assertEqual(self.scope.callbacks, before)

    def test_send_request_rejects_during_unload_without_consuming_quota(self):
        self.host.synthetic_requests = True
        with bridge.runtime.context(self.scope):
            self.scope.state = "unloading"
            before = dict(self.scope.callbacks)
            request_count = len(self.host.client_requests)
            try:
                with self.assertRaisesRegex(bridge.BridgeError, "PLUGIN_UNLOADING"):
                    client.send_request({}, lambda *_: None, account=1)
            finally:
                self.scope.state = "active"
            self.assertEqual(self.scope.callbacks, before)
            self.assertEqual(len(self.host.client_requests), request_count)

    def test_send_request_callback_quota_failure_does_not_call_host(self):
        self.host.synthetic_requests = True
        with bridge.runtime.context(self.scope):
            for index in range(4096):
                bridge.runtime.callback(lambda: index)
            request_count = len(self.host.client_requests)
            with self.assertRaisesRegex(bridge.BridgeError, "RESOURCE_LIMIT"):
                client.send_request({}, lambda *_: None, account=1)
            self.assertEqual(len(self.host.client_requests), request_count)


if __name__ == "__main__":
    unittest.main()
