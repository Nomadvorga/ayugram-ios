import math
import pathlib
import re
import unittest

SOURCE = pathlib.Path(__file__).resolve().parents[2] / "Sources" / "AyuBridgeJavaRuntime.swift"
NAMES = ("AccelerateDecelerateInterpolator", "AccelerateInterpolator", "AnticipateInterpolator",
         "AnticipateOvershootInterpolator", "BounceInterpolator")


class Wave6AnimWiringTests(unittest.TestCase):
    def setUp(self):
        self.text = SOURCE.read_text(encoding="utf-8")

    def test_interpolators_are_enabled_and_registered(self):
        enabled = re.search(r"let enabled: Set<String> = \[(.*?)\]", self.text, re.S).group(1)
        for name in NAMES:
            self.assertIn('"android.view.animation.%s"' % name, enabled)
            self.assertIn('self.interpolatorAdapter("android.view.animation.%s"' % name, self.text)

    def test_formulas_are_the_aosp_ones(self):
        self.assertIn("cos((input + 1) * Double.pi) / 2 + 0.5", self.text)
        self.assertIn("factor == 1 ? input * input : pow(input, 2 * factor)", self.text)
        self.assertIn("input * input * ((tension + 1) * input - tension)", self.text)
        for constant in ("1.1226", "0.3535", "0.54719", "0.7408", "0.8526", "0.9644", "1.0435"):
            self.assertIn(constant, self.text)
        self.assertAlmostEqual(math.cos(1.25 * math.pi) / 2 + 0.5, 0.14644660940672627)


if __name__ == "__main__":
    unittest.main()
