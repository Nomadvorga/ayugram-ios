"""Synthetic pinned-audit/provenance tests; SDK inputs remain static data."""
import copy
import hashlib
import json
from pathlib import Path
import runpy
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "submodules/AyuPluginBridge/Build/audit-plugin-requirements.py"
AUDIT = runpy.run_path(str(SCRIPT))
AuditError = AUDIT["AuditError"]


class PinnedAuditTests(unittest.TestCase):
    def fixture(self, root):
        bridge, plugins = root / "bridge", root / "plugins"
        for folder in ("Python", "Sources", "Integration", "ObjC", "PublicHeaders"):
            (bridge / folder).mkdir(parents=True)
        (bridge / "Python/ayu_bridge.py").write_text(
            'raise RuntimeError("SDK_MUST_NEVER_EXECUTE")\nSDK_MODULES = frozenset({"ayu_bridge", "ui", "ui.settings"})\n', encoding="utf-8")
        (bridge / "Python/ui").mkdir()
        (bridge / "Python/ui/__init__.py").write_text("", encoding="utf-8")
        (bridge / "Python/ui/settings.py").write_text("class Text: pass\n", encoding="utf-8")
        (bridge / "Sources/Host.swift").write_text("struct Host {}\n", encoding="utf-8")
        (bridge / "Integration/App.swift").write_text("struct App {}\n", encoding="utf-8")
        (bridge / "ObjC/Runtime.m").write_text("void runtime(void) {}\n", encoding="utf-8")
        (bridge / "PublicHeaders/runtime.h").write_text("void runtime(void);\n", encoding="utf-8")
        plugins.mkdir()
        records = []
        raw = b'raise RuntimeError("PLUGIN_MUST_NEVER_EXECUTE")\n'
        for index in range(19):
            name = f"sample_{index}.plugin"
            (plugins / name).write_bytes(raw)
            records.append({"file": name, "sha256": hashlib.sha256(raw).hexdigest(),
                            "blob": hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest(),
                            "bytes": len(raw), "lines": 1, "status": "blocked_not_runtime_compatible",
                            "python_path": "blocked", "required_unwired_features": ["method_hooks"]})
        catalog = {"source_repo": "Nomadvorga/ayugram-src", "source_commit": AUDIT["SOURCE_COMMIT"],
                   "source_total_lines": 19, "device_launch_verified": False, "native_tests_executed": False,
                   "plugins_runtime_verified": [], "plugins": records, "sdk_sha256": {"old": "stale"},
                   "extra_route_metadata": {"preserve": ["native adapters", "limitations"]}}
        path = root / "catalog.json"
        path.write_text(json.dumps(catalog), encoding="utf-8")
        return bridge, plugins, path, catalog

    def test_sdk_modules_are_ast_literal_and_sdk_never_executes(self):
        with tempfile.TemporaryDirectory() as directory:
            bridge, _, _, _ = self.fixture(Path(directory))
            self.assertEqual(AUDIT["sdk_modules"](bridge), {"ayu_bridge", "ui", "ui.settings"})
            (bridge / "Python/ayu_bridge.py").write_text('SDK_MODULES = discover_modules()\n', encoding="utf-8")
            with self.assertRaises(AuditError):
                AUDIT["sdk_modules"](bridge)

    def test_refresh_changes_only_hashes_and_preserves_every_requirement(self):
        with tempfile.TemporaryDirectory() as directory:
            bridge, plugins, path, catalog = self.fixture(Path(directory))
            before = copy.deepcopy(catalog)
            refreshed = AUDIT["refresh_implementation_hashes"](path, plugins, provenance=before, bridge=bridge)
            expected = copy.deepcopy(before)
            expected["sdk_sha256"] = AUDIT["implementation_hashes"](bridge)
            self.assertEqual(refreshed, expected)
            self.assertEqual(json.loads(path.read_text(encoding="utf-8")), expected)
            self.assertEqual(refreshed["plugins"], before["plugins"])

    def test_refresh_checks_source_bytes_size_blob_and_line_count(self):
        for field, value in (("sha256", "0" * 64), ("blob", "0" * 40), ("bytes", 1), ("lines", 2)):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as directory:
                bridge, plugins, path, catalog = self.fixture(Path(directory))
                catalog["plugins"][0][field] = value
                if field == "lines":
                    catalog["source_total_lines"] += 1
                path.write_text(json.dumps(catalog), encoding="utf-8")
                with self.assertRaises(AuditError):
                    AUDIT["refresh_implementation_hashes"](path, plugins, provenance=catalog, bridge=bridge)

    def test_refresh_rejects_changed_catalog_provenance_and_runtime_claims(self):
        with tempfile.TemporaryDirectory() as directory:
            bridge, plugins, path, catalog = self.fixture(Path(directory))
            changed = copy.deepcopy(catalog)
            changed["plugins"][0]["sha256"] = "0" * 64
            path.write_text(json.dumps(changed), encoding="utf-8")
            with self.assertRaises(AuditError):
                AUDIT["refresh_implementation_hashes"](path, plugins, provenance=catalog, bridge=bridge)
            changed = copy.deepcopy(catalog)
            changed["execution_verified"] = True
            path.write_text(json.dumps(changed), encoding="utf-8")
            with self.assertRaises(AuditError):
                AUDIT["refresh_implementation_hashes"](path, plugins, provenance=catalog, bridge=bridge)

    def test_hash_inventory_includes_nested_python_and_native_implementations(self):
        with tempfile.TemporaryDirectory() as directory:
            bridge, _, _, _ = self.fixture(Path(directory))
            hashes = AUDIT["implementation_hashes"](bridge)
            self.assertEqual(set(hashes), {"Python/ayu_bridge.py", "Python/ui/__init__.py", "Python/ui/settings.py",
                                          "Sources/Host.swift", "Integration/App.swift", "ObjC/Runtime.m", "PublicHeaders/runtime.h"})
            (bridge / "Python/new.py").write_text("raise RuntimeError('STATIC_ONLY')\n", encoding="utf-8")
            self.assertIn("Python/new.py", AUDIT["implementation_hashes"](bridge))

    def test_dry_refresh_verifies_but_does_not_write(self):
        with tempfile.TemporaryDirectory() as directory:
            bridge, plugins, path, catalog = self.fixture(Path(directory))
            before = path.read_bytes()
            AUDIT["refresh_implementation_hashes"](path, plugins, provenance=catalog, bridge=bridge, write=False)
            self.assertEqual(path.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
