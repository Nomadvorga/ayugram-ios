"""Account-scoped NotificationCenter served by the SDK (synthetic fixtures and host)."""
import json
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Python"))

import ayu_bridge as bridge
import test_bridge as harness
from test_client_compat import ClientHost
from _ayu_javalib import telegram_events as events

CENTER = "org.telegram.messenger.NotificationCenter"
IMPORTS = "from org.telegram.messenger import NotificationCenter\n"


class Observer:
    def __init__(self):
        self.seen = []

    def didReceivedNotification(self, id, account, args):
        self.seen.append((id, account, args))


class EventsHost(ClientHost):
    def __init__(self):
        super().__init__()
        if CENTER not in self.capabilities["classes"]:
            self.capabilities["classes"].append(CENTER)
        self.capabilities.setdefault("members", {"version": 1, "classes": {}})["classes"][CENTER] = {
            "constructor": False, "fields": [], "writable_fields": [], "methods": ["addObserver", "removeObserver"],
            "results": {"getGlobalInstance": CENTER}, "static_fields": ["activeAccountChanged"],
            "static_methods": ["getGlobalInstance"]}


class AccountCenterTests(unittest.TestCase):
    load = harness.BridgeTests.load
    tearDown = harness.BridgeTests.tearDown

    def setUp(self):
        harness.BridgeTests.setUp(self)
        self.host = EventsHost()
        sys.modules["_ayu_host"].dispatch = self.host.dispatch
        self.scope = self.load()
        events._centers.clear()
        context = bridge.runtime.context(self.scope)
        context.__enter__()
        self.addCleanup(context.__exit__, None, None, None)
        self.center_class = bridge.runtime.jclass(CENTER)

    def test_constants_are_distinct_ints_and_unserved_ids_are_missing(self):
        reload, interfaces = self.center_class.dialogsNeedReload, self.center_class.updateInterfaces
        self.assertIs(type(reload), int)
        self.assertIs(type(interfaces), int)
        self.assertEqual(len({reload, interfaces, 1}), 3)
        self.assertEqual(set(events.HOST_MEMBERS[CENTER]), {"getInstance", "dialogsNeedReload", "updateInterfaces"})

    def test_instance_is_per_account(self):
        first = self.center_class.getInstance(0)
        self.assertIs(first, self.center_class.getInstance(0))
        self.assertIsNot(first, self.center_class.getInstance(1))
        for bad in (-1, 16):
            with self.assertRaises(IndexError):
                self.center_class.getInstance(bad)
        with self.assertRaises(TypeError):
            self.center_class.getInstance()

    def test_post_reaches_observers_of_that_id_and_account_only(self):
        reload, interfaces = self.center_class.dialogsNeedReload, self.center_class.updateInterfaces
        center, other = self.center_class.getInstance(0), self.center_class.getInstance(1)
        observer, stranger = Observer(), Observer()
        center.addObserver(observer, reload)
        center.addObserver(observer, reload)
        other.addObserver(stranger, reload)
        center.postNotificationName(interfaces, 5)
        self.assertEqual(observer.seen, [])
        center.postNotificationName(reload)
        center.postNotificationName(reload, "a", 2)
        self.assertEqual(observer.seen, [(reload, 0, []), (reload, 0, ["a", 2])])
        self.assertEqual(stranger.seen, [])
        center.removeObserver(observer, reload)
        center.postNotificationName(reload)
        self.assertEqual(len(observer.seen), 2)

    def test_removal_during_a_post_still_delivers_that_post(self):
        reload = self.center_class.dialogsNeedReload
        center = self.center_class.getInstance(0)
        second = Observer()

        class Remover(Observer):
            def didReceivedNotification(self, id, account, args):
                center.removeObserver(second, id)

        center.addObserver(Remover(), reload)
        center.addObserver(second, reload)
        center.postNotificationName(reload)
        center.postNotificationName(reload)
        self.assertEqual(len(second.seen), 1)

    def test_unserved_id_is_refused_not_dropped(self):
        center = self.center_class.getInstance(0)
        for call in (lambda: center.postNotificationName(1), lambda: center.addObserver(Observer(), 77),
                     lambda: center.removeObserver(Observer(), 77)):
            with self.assertRaises(bridge.UnsupportedAPI):
                call()
        with self.assertRaises(TypeError):
            center.addObserver(object(), self.center_class.dialogsNeedReload)

    def blockers(self, body):
        report = json.loads(bridge.preflight_plugin_json(harness.source("events_fixture", body, IMPORTS)))
        return {(item.get("code"), item.get("detail")) for item in report["blockers"]}

    def test_preflight_passes_served_posts_and_keeps_unserved_ids_blocked(self):
        served = ("    def on_plugin_load(self):\n"
                  "        center = NotificationCenter.getInstance(0)\n"
                  "        center.postNotificationName(NotificationCenter.dialogsNeedReload)\n"
                  "        NotificationCenter.getInstance(0).postNotificationName(NotificationCenter.updateInterfaces, 1)\n")
        self.assertEqual(self.blockers(served), set())
        unserved = ("    def on_plugin_load(self):\n"
                    "        NotificationCenter.getInstance(0).postNotificationName(NotificationCenter.didReceiveNewMessages)\n")
        self.assertIn(CENTER + ".didReceiveNewMessages", {detail for _, detail in self.blockers(unserved)})
        missing = ("    def on_plugin_load(self):\n"
                   "        NotificationCenter.getInstance(0).postNotificationNameOnUIThread(NotificationCenter.dialogsNeedReload)\n")
        self.assertIn("postNotificationNameOnUIThread", " ".join(str(detail) for _, detail in self.blockers(missing)))


if __name__ == "__main__":
    unittest.main()
