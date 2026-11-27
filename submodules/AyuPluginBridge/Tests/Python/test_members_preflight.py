"""Member-aware preflight through the bridge: the wire table, ``MEMBER`` blockers and probes at run time.

Plugin sources are synthetic; preflight only parses them.
"""
import json
import unittest

import test_bridge as fixtures
import ayu_bridge as bridge

NATIVE = {"constructor": True, "methods": ["echo"], "fields": ["answer"], "writable_fields": [],
          "static_methods": ["echo"], "static_fields": ["answer"], "results": {}}
USES = ('from java import jclass\nNative = jclass("example.Native")\n'
        'Native.echo(1)\nNative.vanished(1)\nNative().echo(2)\nNative().gone()\n')


class MemberPreflightTests(unittest.TestCase):
    setUp = fixtures.BridgeTests.setUp
    tearDown = fixtures.BridgeTests.tearDown
    load = fixtures.BridgeTests.load

    def publish(self, table=None, version=1):
        self.host.capabilities["members"] = {"version": version,
                                             "classes": {"example.Native": NATIVE} if table is None else table}

    def preflight(self, imports="", body="    pass\n"):
        return json.loads(bridge.preflight_plugin_json(fixtures.source("members", body, imports)))

    def blockers(self, report, code):
        return [item["detail"] for item in report["blockers"] if item["code"] == code]

    def test_missing_members_of_a_host_class_block_with_a_stable_message(self):
        self.publish()
        report = self.preflight(USES)
        self.assertEqual(self.blockers(report, "MEMBER"), ["example.Native.gone", "example.Native.vanished"])
        self.assertEqual(report["member_accesses"], {"verified": 4, "guarded": 0, "missing_accesses": 2, "unknown": 0, "unknown_java_style": 0})
        self.assertEqual(self.preflight(USES)["blockers"], report["blockers"])

    def test_host_that_publishes_no_table_keeps_todays_behaviour(self):
        report = self.preflight(USES)
        self.assertEqual(report["blockers"], [])
        self.assertEqual((report["member_accesses"]["verified"], report["member_accesses"]["unknown"]), (0, 6))
        self.assertNotIn("members", bridge.runtime._capabilities())

    def test_table_of_a_newer_version_is_ignored(self):
        self.publish(table="a shape this SDK does not know", version=2)
        self.assertEqual(self.preflight(USES)["blockers"], [])
        self.assertNotIn("members", bridge.runtime._capabilities())

    def test_malformed_table_is_a_protocol_error(self):
        for table in ({"example.Unknown": NATIVE}, {"example.Native": dict(NATIVE, methods=["_hidden"])},
                      {"example.Native": {"methods": []}}, [], None):
            self.host.capabilities["members"] = {"version": 1, "classes": table}
            with self.subTest(table=table), self.assertRaises(bridge.ProtocolError):
                self.preflight(USES)
        self.host.capabilities["members"] = {"classes": {}}
        with self.assertRaises(bridge.ProtocolError):
            self.preflight(USES)
        self.host.capabilities["extra"] = []
        with self.assertRaises(bridge.ProtocolError):
            self.preflight()

    def test_valid_table_is_stored_with_the_capabilities(self):
        self.publish()
        self.assertEqual(bridge.runtime._capabilities()["members"], {"example.Native": NATIVE})
        self.load("first")
        self.load("second")
        self.assertEqual(bridge.runtime.capabilities["members"], {"example.Native": NATIVE})

    def test_python_local_class_members_are_checked_on_any_host(self):
        report = self.preflight("from java.lang import Math\nMath.max(1, 2)\nMath.imaginary(1)\n")
        self.assertEqual(self.blockers(report, "MEMBER"), ["java.lang.Math.imaginary"])

    def test_constructor_and_write_messages(self):
        self.publish({"example.Native": dict(NATIVE, constructor=False)})
        report = self.preflight('from java import jclass\nNative = jclass("example.Native")\n'
                                'Native()\nNative.answer = 1\n')
        self.assertEqual(self.blockers(report, "MEMBER"), ["example.Native.<init>", "example.Native.answer (write)"])

    def test_probed_member_does_not_block(self):
        self.publish()
        report = self.preflight(USES, body=(
            '    def run(self):\n'
            '        if hasattr(Native, "optional"):\n'
            '            Native.optional()\n'
            '        try:\n'
            '            Native.newer()\n'
            '        except AttributeError:\n'
            '            Native.echo(0)\n'))
        self.assertEqual(self.blockers(report, "MEMBER"), ["example.Native.gone", "example.Native.vanished"])
        self.assertEqual(report["member_accesses"]["guarded"], 2)

    def test_curated_list_applies_to_unresolved_receivers_only(self):
        unresolved = "    def run(self, view):\n        view.getWindow()\n"
        resolved = "    def run(self, view):\n        Native().getWindow()\n"
        curated = "sdk.unprovided_member (getWindow())"
        imports = 'from java import jclass\nNative = jclass("example.Native")\n'
        self.publish()
        report = self.preflight(imports, unresolved)
        self.assertEqual((self.blockers(report, "OPERATION"), self.blockers(report, "MEMBER")), ([curated], []))
        report = self.preflight(imports, resolved)
        self.assertEqual((self.blockers(report, "OPERATION"), self.blockers(report, "MEMBER")),
                         ([], ["example.Native.getWindow"]))
        report = self.preflight(imports, resolved + "        view.getWindow()\n")
        self.assertEqual((self.blockers(report, "OPERATION"), self.blockers(report, "MEMBER")),
                         ([curated], ["example.Native.getWindow"]))
        # A member the table provides is no longer blocked by its name alone.
        self.publish({"example.Native": dict(NATIVE, methods=["echo", "getWindow"])})
        self.assertEqual(self.preflight(imports, resolved)["blockers"], [])
        # Without a table the receiver's members are unknown and the list still applies.
        del self.host.capabilities["members"]
        self.assertEqual(self.blockers(self.preflight(imports, resolved), "OPERATION"), [curated])

    def test_report_does_not_carry_analysis_internals(self):
        self.publish()
        report = self.preflight(USES)
        self.assertEqual(set(report["member_accesses"]), {"verified", "guarded", "missing_accesses", "unknown", "unknown_java_style"})

    def test_loading_is_not_blocked_by_members(self):
        self.publish()
        scope = self.load("loads", imports=USES.replace("Native.vanished(1)\n", "").replace("Native().gone()\n", ""))
        self.assertEqual(scope.plugin_id, "loads")


class MissingMemberAtRunTimeTests(unittest.TestCase):
    setUp = fixtures.BridgeTests.setUp
    tearDown = fixtures.BridgeTests.tearDown
    load = fixtures.BridgeTests.load

    def test_missing_host_member_reads_as_a_missing_attribute(self):
        scope = self.load("probing")
        with bridge.runtime.context(scope):
            native = bridge.runtime.jclass("example.Native")
            instance = native()
            for target in (native, instance):
                self.assertTrue(hasattr(target, "echo"))
                self.assertFalse(hasattr(target, "absent"))
                self.assertEqual(getattr(target, "absent", 5), 5)
                self.assertEqual(getattr(target, "answer", 5), 42)
                with self.assertRaises(bridge.MissingMember) as caught:
                    target.absent
                self.assertIsInstance(caught.exception, AttributeError)
                self.assertIsInstance(caught.exception, bridge.UnsupportedAPI)
                self.assertEqual((caught.exception.code, caught.exception.message), ("UNSUPPORTED_API", "Undeclared member"))

    def test_other_host_failures_are_not_missing_attributes(self):
        scope = self.load("failing")
        with bridge.runtime.context(scope):
            native = bridge.runtime.jclass("example.Native")
            self.host.response_override = lambda request: json.dumps({
                "version": 1, "id": request["id"], "error": {"code": "OWNERSHIP", "message": "Wrong owner"}})
            with self.assertRaises(bridge.BridgeError) as caught:
                hasattr(native, "echo")
            self.assertEqual(caught.exception.code, "OWNERSHIP")
            self.assertNotIsInstance(caught.exception, AttributeError)


if __name__ == "__main__":
    unittest.main()
