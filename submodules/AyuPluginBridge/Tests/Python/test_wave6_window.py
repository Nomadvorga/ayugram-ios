"""Wave 6 window lane: ``WindowManager.LayoutParams`` is data only; reaching a window stays refused."""
from __future__ import annotations

from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "Python"))

import _ayu_javalib as javalib
import _ayu_operations as operations
from _ayu_javalib import android_view as view


class WindowLayoutParamsTests(unittest.TestCase):
    def test_only_the_value_holder_is_registered(self):
        self.assertIn("android_view", javalib.PROVIDER_MODULES)
        self.assertIs(javalib.local_classes()["android.view.WindowManager$LayoutParams"], view.LayoutParams)
        # Wave 7 registers the interface for its nested constants; preflight blocks the window service.
        self.assertIs(javalib.local_classes()["android.view.WindowManager"].LayoutParams, view.LayoutParams)
        self.assertNotIn("android.view.Window", javalib.local_classes())

    def test_constants_match_aosp(self):
        params = view.LayoutParams
        self.assertEqual((params.FLAG_KEEP_SCREEN_ON, params.FLAG_SECURE, params.FLAG_FULLSCREEN), (0x80, 0x2000, 0x400))
        self.assertEqual((params.FLAG_NOT_FOCUSABLE, params.FLAG_NOT_TOUCHABLE, params.FLAG_NOT_TOUCH_MODAL), (8, 16, 32))
        self.assertEqual((params.FLAG_LAYOUT_IN_SCREEN, params.FLAG_LAYOUT_NO_LIMITS), (0x100, 0x200))
        self.assertEqual((params.FLAG_SHOW_WHEN_LOCKED, params.FLAG_TURN_SCREEN_ON), (0x80000, 0x200000))
        self.assertEqual(params.FLAG_HARDWARE_ACCELERATED, 0x1000000)
        self.assertEqual(params.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS, -2147483648)
        self.assertEqual((params.TYPE_PHONE, params.TYPE_APPLICATION_OVERLAY, params.TYPE_TOAST), (2002, 2038, 2005))
        self.assertEqual((params.SOFT_INPUT_ADJUST_RESIZE, params.SOFT_INPUT_ADJUST_NOTHING,
                          params.SOFT_INPUT_STATE_HIDDEN), (0x10, 0x30, 2))
        self.assertEqual(params.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES, 1)
        self.assertEqual((params.MATCH_PARENT, params.WRAP_CONTENT), (-1, -2))

    def test_constructors_fill_the_fields_android_fills(self):
        empty = view.LayoutParams()
        self.assertEqual((empty.width, empty.height, empty.type, empty.flags, empty.format), (-1, -1, 2, 0, -1))
        self.assertEqual((empty.alpha, empty.dimAmount, empty.screenBrightness, empty.gravity), (1.0, 1.0, -1.0, 0))
        typed = view.LayoutParams(2038, 8, -3)
        self.assertEqual((typed.width, typed.type, typed.flags, typed.format), (-1, 2038, 8, -3))
        sized = view.LayoutParams(-2, -2, 2002, 0x28, -3)
        self.assertEqual((sized.width, sized.height, sized.x, sized.y, sized.type, sized.flags), (-2, -2, 0, 0, 2002, 0x28))
        placed = view.LayoutParams(10, 20, 3, 4, 2038, 8, 1)
        self.assertEqual((placed.width, placed.height, placed.x, placed.y, placed.format), (10, 20, 3, 4, 1))
        placed.setTitle(None)
        self.assertEqual(placed.getTitle(), "")
        for bad in ((1, 2, 3, 4), (1.5,), ("a", 1)):
            with self.assertRaises(TypeError):
                view.LayoutParams(*bad)

    def test_reaching_a_window_is_still_refused(self):
        self.assertIn("getWindow", operations.UNPROVIDED_MEMBERS)
        self.assertIn("getDecorView", operations.UNPROVIDED_MEMBERS)


if __name__ == "__main__":
    unittest.main()
