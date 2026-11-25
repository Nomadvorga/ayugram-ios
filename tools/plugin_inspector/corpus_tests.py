"""Synthetic corpus behavior and redaction tests; no attachment execution."""
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import warnings
import zipfile

from .corpus import CorpusError, inventory_corpus, main, render_markdown
from .inspector import inspect_source


class CorpusTests(unittest.TestCase):
    def test_flat_deterministic_duplicates_and_no_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = root / "NEVER_CREATED"
            source = 'from base_plugin import BasePlugin\nfrom java import jclass\nA = jclass("android.view.View")\nopen(' + repr(str(marker)) + ', "w").write("PRIVATE_LITERAL")\n'
            (root / "first.plugin").write_text(source, encoding="utf-8")
            (root / "second.plugin").write_text(source, encoding="utf-8")
            nested = root / "nested"
            nested.mkdir()
            (nested / "ignored.plugin").write_text("if (", encoding="utf-8")
            first = inventory_corpus(root)
            (root / "first.plugin").rename(root / "renamed.plugin")
            second = inventory_corpus(root)
            self.assertEqual(first, second)
            self.assertEqual(first["statistics"]["attachments"], 2)
            self.assertEqual(first["statistics"]["unique_plugin_sources"], 1)
            row = first["requirements"]["java_classes"]["ranked"][0]
            self.assertEqual((row["files"], row["unique_sources"]), (2, 1))
            text = json.dumps(first) + render_markdown(first)
            for forbidden in ("PRIVATE_LITERAL", str(root), "first.plugin", "renamed.plugin", "NEVER_CREATED"):
                self.assertNotIn(forbidden, text)
            self.assertFalse(marker.exists())
            self.assertFalse(first["execution_verified"])
            self.assertTrue(first["runtime_validation_required"])

    def test_archive_source_is_parsed_in_memory_and_paths_omitted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with zipfile.ZipFile(root / "bundle.elyx", "w") as archive:
                archive.writestr("PRIVATE_MEMBER/module.py", 'raise RuntimeError("NEVER_RUN")\nimport requests\n')
                archive.writestr("PRIVATE_IMAGE.png", b"not an image")
                archive.writestr("PRIVATE_NATIVE.so", b"not a native binary")
                archive.writestr("../escape.py", b"import PRIVATE_API")
            report = inventory_corpus(root)
            self.assertEqual(report["statistics"]["parsed_source_units"], 1)
            self.assertEqual(report["statistics"]["archive_member_kinds"], {
                "python_source": 1, "image": 1, "native_binary": 1})
            self.assertEqual(report["statistics"]["archive_issues"], {"unsafe_or_encrypted_member": 1})
            self.assertNotIn("PRIVATE", json.dumps(report))
            self.assertNotIn("NEVER_RUN", json.dumps(report))

    def test_sdk_comparison_is_exact_and_not_support(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            corpus = root / "corpus"
            android = root / "android"
            bridge = root / "bridge"
            for path in (corpus, android, bridge):
                path.mkdir()
            (corpus / "sample.plugin").write_text(
                'from base_plugin import BasePlugin, OnlyAndroid\n'
                'class P(BasePlugin):\n def f(self):\n  self.missing()\n', encoding="utf-8")
            (android / "base_plugin.py").write_text(
                "raise RuntimeError('NEVER_RUN')\nclass BasePlugin:\n def missing(self): pass\nclass OnlyAndroid: pass\n", encoding="utf-8")
            (bridge / "base_plugin.py").write_text("class BasePlugin: pass\n", encoding="utf-8")
            report = inventory_corpus(corpus, android_sdk=android, bridge_sdk=bridge)
            gaps = {row["api"] for row in report["requirements"]["android_declared_bridge_absent"]["ranked"]}
            self.assertEqual(gaps, {"base_plugin.OnlyAndroid", "base_plugin.BasePlugin.missing"})
            self.assertEqual(report["statistics"]["static_status"], {"unknown": 1})
            self.assertFalse(report["execution_verified"])

    def test_rank_limit_and_malformed_inputs_are_visible(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "good.plugin").write_text("import requests\nimport httpx\n", encoding="utf-8")
            (root / "bad.plugin").write_text('if ("PRIVATE_ERROR"', encoding="utf-8")
            (root / "bad.eaf").write_bytes(b"PRIVATE_INVALID_ZIP")
            report = inventory_corpus(root, rank_limit=1)
            self.assertEqual(report["requirements"]["external_imports"]["omitted_targets"], 1)
            self.assertEqual(report["statistics"]["source_errors"], {"invalid_or_excessive_python": 1})
            self.assertEqual(report["statistics"]["archive_issues"], {"unreadable_archive": 1})
            self.assertNotIn("PRIVATE", json.dumps(report))

    def test_bounds_and_output_protection(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            plugin = root / "sample.plugin"
            plugin.write_text("import os", encoding="utf-8")
            with patch("sys.stderr", io.StringIO()):
                self.assertEqual(main([str(root), "--output", str(plugin)]), 2)
            self.assertEqual(plugin.read_text(encoding="utf-8"), "import os")
            with patch("tools.plugin_inspector.corpus.MAX_FILES", 0):
                with self.assertRaises(CorpusError):
                    inventory_corpus(root)
            with self.assertRaises(CorpusError):
                inventory_corpus(root, rank_limit=201)

    def test_parse_warnings_never_disclose_source(self):
        with warnings.catch_warnings(record=True) as caught:
            warnings.simplefilter("always")
            report = inspect_source('PRIVATE = "\\q"\n')
        self.assertFalse(caught)
        self.assertNotIn("PRIVATE", json.dumps(report))

    def test_archive_limits_rejected_before_source_read(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with zipfile.ZipFile(root / "sample.eaf", "w") as archive:
                archive.writestr("one.py", "import os")
                archive.writestr("two.py", "import sys")
            with patch("tools.plugin_inspector.corpus.MAX_ARCHIVE_MEMBERS", 1):
                with self.assertRaises(CorpusError):
                    inventory_corpus(root)

    def test_sdk_wildcard_exports_are_static_declarations(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            corpus, sdk = root / "corpus", root / "sdk"
            corpus.mkdir()
            sdk.mkdir()
            (corpus / "sample.plugin").write_text("from plugin_settings import Text\n", encoding="utf-8")
            (sdk / "plugin_settings.py").write_text("from settings import *\n", encoding="utf-8")
            (sdk / "settings.py").write_text("class Text: pass\n", encoding="utf-8")
            report = inventory_corpus(corpus, android_sdk=sdk)
            row = report["requirements"]["sdk_symbols"]["ranked"][0]
            self.assertEqual(row["android_declaration"], "declared")


if __name__ == "__main__":
    unittest.main()
