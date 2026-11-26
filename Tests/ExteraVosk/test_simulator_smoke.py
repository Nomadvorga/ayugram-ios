import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("run_simulator_smoke.py")
SPEC = importlib.util.spec_from_file_location("extera_vosk_simulator_smoke", SCRIPT)
SMOKE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(SMOKE)


class AppStatusTests(unittest.TestCase):
    def test_missing_or_partial_status_is_not_terminal(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "status.json"
            self.assertIsNone(SMOKE.read_app_status(path))
            path.write_text("{", encoding="utf-8")
            self.assertIsNone(SMOKE.read_app_status(path))
            self.assertFalse(SMOKE.is_terminal_app_status(path))

    def test_running_status_is_not_terminal(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "status.json"
            path.write_text(json.dumps({"status": "running", "phase": "native_started"}), encoding="utf-8")
            self.assertFalse(SMOKE.is_terminal_app_status(path))

    def test_passed_and_failed_statuses_are_terminal(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "status.json"
            for status in ("passed", "failed"):
                with self.subTest(status=status):
                    path.write_text(json.dumps({"status": status}), encoding="utf-8")
                    self.assertTrue(SMOKE.is_terminal_app_status(path))


if __name__ == "__main__":
    unittest.main()
