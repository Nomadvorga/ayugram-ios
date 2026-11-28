"""Wave 7 window lane: ``WindowManager`` serves its constants; asking for the window service is a blocker."""
from __future__ import annotations

import ast
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Python"))

import _ayu_inspection as inspection
import _ayu_javalib as javalib
import _ayu_operations as operations
from _ayu_javalib import android_view as view

USES_SERVICE = """
from java import jclass
from android.content import Context
WindowManager = jclass("android.view.WindowManager")
def show(ctx, overlay):
    wm = ctx.getSystemService(Context.WINDOW_SERVICE)
    wm.addView(overlay, WindowManager.LayoutParams(-2, -2, WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY, 8, -3))
"""
CONSTANTS_ONLY = """
from java import jclass
FLAG = jclass("android.view.WindowManager").LayoutParams.FLAG_KEEP_SCREEN_ON
def copy(ctx):
    return ctx.getSystemService("clipboard")
"""


class WindowManagerTests(unittest.TestCase):
    def test_interface_serves_nested_constants_and_has_no_instance(self):
        manager = javalib.local_classes()["android.view.WindowManager"]
        self.assertIs(manager, view.WindowManager)
        self.assertIs(manager.LayoutParams, view.LayoutParams)
        self.assertEqual(manager.LayoutParams.FLAG_KEEP_SCREEN_ON, 0x80)
        with self.assertRaises(Exception) as raised:
            manager()
        self.assertIn("interface", str(raised.exception))

    def test_static_scan_finds_every_way_to_the_window_service(self):
        scan = lambda source: view.static_window_services(ast.parse(source))
        self.assertEqual(scan(USES_SERVICE), ["getSystemService(window)"])
        self.assertEqual(scan("a.getSystemService('window')"), ["getSystemService(window)"])
        self.assertEqual(scan("a.getSystemService(self.Context.WINDOW_SERVICE)"), ["getSystemService(window)"])
        self.assertEqual(scan("a.getSystemService(WINDOW_SERVICE)"), ["getSystemService(window)"])
        self.assertEqual(scan("w = act.getWindowManager()"), ["getWindowManager()"])
        self.assertEqual(scan(CONSTANTS_ONLY), [])
        self.assertEqual(scan("a.getSystemService(Context.CLIPBOARD_SERVICE)"), [])

    def test_window_service_is_a_requirement_no_host_meets(self):
        required = operations.requirements((), (), window_services=["getSystemService(window)"])
        self.assertEqual(required, {"getSystemService(window)": [["sdk.unprovided_member"]]})
        self.assertEqual(operations.missing(required, {"ui.alert"}), ["sdk.unprovided_member (getSystemService(window))"])
        self.assertEqual(operations.requirements((), ()), {})

    def test_inspection_inventory_carries_the_scan(self):
        source = Path(inspection.__file__).read_text(encoding="utf-8")
        self.assertIn('"window_services": _window_services(tree)', source)
        bridge = (Path(inspection.__file__).parent / "ayu_bridge.py").read_text(encoding="utf-8")
        self.assertIn('inventory.get("window_services", ())', bridge)

    def test_reaching_the_activity_window_is_still_refused(self):
        self.assertIn("getWindow", operations.UNPROVIDED_MEMBERS)
        self.assertIn("getDecorView", operations.UNPROVIDED_MEMBERS)
        self.assertNotIn("android.view.Window", javalib.local_classes())


if __name__ == "__main__":
    unittest.main()
