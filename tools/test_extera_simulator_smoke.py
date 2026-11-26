import unittest

from extera_simulator_smoke import select_device


class SelectDeviceTests(unittest.TestCase):
    def setUp(self):
        self.runtime = {
            "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
            "version": "27.2",
            "isAvailable": True,
            "supportedDeviceTypes": [],
        }

    def device(self, name):
        return {
            "identifier": f"com.apple.CoreSimulator.SimDeviceType.{name.replace(' ', '-')}",
            "name": name,
            "minRuntimeVersion": (27 << 16) | (2 << 8),
            "maxRuntimeVersion": 0xFFFFFFFF,
        }

    def select(self, names):
        devices = [self.device(name) for name in names]
        self.runtime["supportedDeviceTypes"] = [device["identifier"] for device in devices]
        return select_device([self.runtime], devices, "15.0")[1]["name"]

    def test_prefers_newest_base_model_when_available(self):
        self.assertEqual(
            self.select(["iPhone 17", "iPhone 18 Pro", "iPhone 18 Pro Max", "iPhone 18"]),
            "iPhone 18",
        )

    def test_prefers_pro_over_pro_max_when_base_is_unavailable(self):
        self.assertEqual(
            self.select(["iPhone 18 Pro Max", "iPhone 18 Pro"]),
            "iPhone 18 Pro",
        )

    def test_newer_compatible_generation_precedes_older_base_model(self):
        self.assertEqual(
            self.select(["iPhone 17", "iPhone 18 Pro"]),
            "iPhone 18 Pro",
        )


if __name__ == "__main__":
    unittest.main()
