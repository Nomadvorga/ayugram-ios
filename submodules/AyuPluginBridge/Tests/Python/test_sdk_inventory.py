"""Synthetic AST-only inventory fixtures; no attachment source is executed."""
import ast
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


SDK = Path(__file__).resolve().parents[2] / "Python"
sys.path.insert(0, str(SDK))
import _ayu_inspection as inspection


class SDKInventoryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.root_patch = mock.patch.object(inspection, "_SDK_ROOT", self.root)
        self.root_patch.start()
        self.clear_caches()
        self.write("extera_utils/__init__.py", "public = 1\n")
        self.write("extera_utils/text_formatting.py", "def parse_text(text): pass\nbind_task = None\n")
        self.write("extera_utils/classes.py", "Base = None\njava_subclass = None\n")
        self.write("extera_utils/lifecycle.py", "bind_task = None\ncapture_scope = None\n")
        self.write("java.py", "jclass = None\n")
        self.write("hook_utils.py", "find_class = None\n")
        self.modules = {"extera_utils", "java", "hook_utils"}

    def tearDown(self):
        self.root_patch.stop()
        self.clear_caches()
        self.directory.cleanup()

    def clear_caches(self):
        inspection.sdk_symbols.cache_clear()
        inspection._sdk_surface.cache_clear()

    def write(self, name, source):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source, encoding="utf-8")
        self.clear_caches()

    def inventory(self, source):
        return inspection.import_inventory(ast.parse(source), self.modules)

    def test_nested_imports_checked_even_when_only_root_is_registered(self):
        report = self.inventory(
            "from extera_utils.text_formatting import parse_text as parse\n"
            "from extera_utils.classes import Base\n"
            "from extera_utils.lifecycle import capture_scope\n"
            "raise AssertionError('AST only')\n")
        self.assertEqual(report["unsupported_sdk_symbols"], {})
        self.assertEqual(report["imported_symbols"]["extera_utils.classes"], ["Base"])
        report = self.inventory("from extera_utils.classes import nonexistent as Base\n")
        self.assertEqual(report["unsupported_sdk_symbols"], {"extera_utils.classes": ["nonexistent"]})

    def test_nested_module_aliases_and_package_child_aliases(self):
        for source in (
                "import extera_utils.text_formatting as formatting\nformatting.absent()\n",
                "import extera_utils.text_formatting\nextera_utils.text_formatting.absent()\n",
                "from extera_utils import text_formatting as formatting\nformatting.absent()\n"):
            with self.subTest(source=source):
                self.assertEqual(self.inventory(source)["unsupported_sdk_symbols"],
                                 {"extera_utils.text_formatting": ["absent"]})

    def test_missing_dotted_module_is_not_accepted_by_package_prefix(self):
        for source in ("import extera_utils.missing\n", "from extera_utils.missing import value\n",
                       "import extera_utils.missing.deep as child\n"):
            with self.subTest(source=source):
                self.assertEqual(self.inventory(source)["unsupported_sdk_symbols"], {"extera_utils": ["missing"]})
        self.assertEqual(self.inventory("from extera_utils import missing\n")["unsupported_sdk_symbols"],
                         {"extera_utils": ["missing"]})

    def test_alias_collisions_cannot_hide_unsupported_uses(self):
        report = self.inventory(
            "import extera_utils.classes as sdk\nsdk.absent()\n"
            "import extera_utils.text_formatting as sdk\nsdk.parse_text('x')\n")
        self.assertIn("absent", report["unsupported_sdk_symbols"]["extera_utils.classes"])

    def test_function_scopes_do_not_contaminate_sibling_aliases(self):
        report = self.inventory(
            "def first():\n import extera_utils.classes as sdk\n return sdk.Base\n"
            "def second():\n import extera_utils.text_formatting as sdk\n return sdk.parse_text('x')\n")
        self.assertEqual(report["unsupported_sdk_symbols"], {})
        report = self.inventory(
            "import java as sdk\n"
            "def local(sdk):\n return sdk.jclass('local.not.java')\n"
            "def inherited():\n return sdk.jclass('real.Class')\n")
        self.assertEqual(report["classes"], ["real.Class"])

    def test_assignment_aliases_preserve_modules_and_class_lookups(self):
        report = self.inventory(
            "import extera_utils.text_formatting as formatting\n"
            "alias = formatting\nalias.absent()\n"
            "import java\nlookup = java.jclass\nlookup('native.Assigned')\n"
            "left = right\nright = left\n")
        self.assertEqual(report["unsupported_sdk_symbols"], {"extera_utils.text_formatting": ["absent"]})
        self.assertEqual(report["classes"], ["native.Assigned"])

    def test_methods_use_enclosing_import_not_class_body_binding(self):
        report = self.inventory(
            "import java as sdk\nclass Example:\n sdk = None\n"
            " def method(self):\n  return sdk.jclass('native.Method')\n")
        self.assertEqual(report["classes"], ["native.Method"])

    def test_qualified_aliased_and_starred_class_lookups(self):
        report = self.inventory(
            "import java as j\nfrom java import jclass as lookup\n"
            "from hook_utils import *\n"
            "j.jclass('native.First')\nlookup(name='native.Second')\n"
            "find_class('native.Third')\nlookup(computed)\n"
            "def find_class(name): return name\n")
        self.assertEqual(report["classes"], ["native.First", "native.Second", "native.Third"])
        self.assertEqual(report["dynamic_class_lookup_lines"], [7])
        self.assertEqual(self.inventory("def find_class(name): return name\nfind_class('local')\n")["classes"], [])

    def test_optional_import_error_fallback_is_reported_without_erasing_blockers(self):
        report = self.inventory(
            "try:\n from extera_utils.classes import absent as helper\n"
            "except ImportError:\n from extera_utils.lifecycle import bind_task as helper\n"
            "helper()\n")
        self.assertEqual(report["optional_imports"],
                         [{"module": "extera_utils.classes", "line": 2, "handler_line": 3}])
        self.assertEqual(report["unsupported_sdk_symbols"], {"extera_utils.classes": ["absent"]})
        self.assertEqual(report["imported_symbols"]["extera_utils.lifecycle"], ["bind_task"])

    def test_broad_and_reraising_handlers_are_not_optional_evidence(self):
        for handler, body in (("Exception", "pass"), ("BaseException", "pass"),
                              ("(ImportError, Exception)", "pass"), ("ImportError", "raise")):
            with self.subTest(handler=handler, body=body):
                report = self.inventory(f"try:\n import java\nexcept {handler}:\n {body}\n")
                self.assertEqual(report["optional_imports"], [])
        report = self.inventory("try:\n import java\nexcept (ImportError, ModuleNotFoundError):\n pass\n")
        self.assertEqual(len(report["optional_imports"]), 1)

    def test_deferred_function_body_is_not_guarded_by_surrounding_try(self):
        report = self.inventory("try:\n def deferred():\n  import java\nexcept ImportError:\n pass\n")
        self.assertEqual(report["optional_imports"], [])

    def test_all_controls_star_exports_not_explicit_public_imports(self):
        self.write("java.py", "jclass = None\nother = None\n_private = None\n"
                   "__all__ = ['jclass']\n__all__ += ['_private']\n")
        self.assertIn("other", inspection.sdk_symbols("java"))
        self.assertEqual(self.inventory("from java import other\n")["unsupported_sdk_symbols"], {})
        report = self.inventory("from java import *\njclass('native.Star')\nother('unrelated')\n")
        self.assertEqual(report["classes"], ["native.Star"])
        self.assertEqual(inspection._sdk_surface("java")[1], frozenset({"jclass", "_private"}))

    def test_exports_do_not_stop_scanning_later_bindings(self):
        self.write("java.py", "__all__ = ['jclass']\njclass = None\nlater = None\na, b = 1, 2\n")
        self.assertTrue({"jclass", "later", "a", "b"} <= inspection.sdk_symbols("java"))

    def test_star_imports_include_bound_children_but_not_unimported_children(self):
        self.write("extera_utils/__init__.py", "from . import classes\n")
        self.assertEqual(inspection._sdk_surface("extera_utils")[1], frozenset({"classes"}))
        self.assertIn("lifecycle", inspection.sdk_symbols("extera_utils"))

    def test_relative_star_reexports_and_cycles(self):
        self.write("extera_utils/__init__.py", "from .classes import *\n")
        self.assertIn("Base", inspection.sdk_symbols("extera_utils"))
        self.write("extera_utils/classes.py", "from . import *\n")
        with self.assertRaisesRegex(ValueError, "Cyclic"):
            inspection.sdk_symbols("extera_utils")

    def test_invalid_exports_fail_explicitly(self):
        for source in ("__all__ = compute()\n", "__all__ = ['undefined']\n",
                       "__all__ = [1]\n", "__all__ = ['../escape']\n"):
            with self.subTest(source=source):
                self.write("java.py", source)
                with self.assertRaises(ValueError):
                    inspection.sdk_symbols("java")

    def test_module_paths_are_confined(self):
        for name in ("../secret", "java/other", "", ".java", "java..child"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                inspection.sdk_symbols(name)
        with self.assertRaisesRegex(ValueError, "not bundled"):
            inspection.sdk_symbols("java.missing")

    def test_sdk_source_and_plugin_ast_are_bounded(self):
        self.write("java.py", "#" + "x" * inspection._MAX_SOURCE_BYTES)
        with self.assertRaisesRegex(ValueError, "size limit"):
            inspection.sdk_symbols("java")
        expression = ast.Name(id="value", ctx=ast.Load())
        for _ in range(inspection._MAX_DEPTH + 1):
            expression = ast.Attribute(value=expression, attr="member", ctx=ast.Load())
        with self.assertRaisesRegex(ValueError, "AST limits"):
            inspection.import_inventory(ast.Expression(expression), self.modules)
        with mock.patch.object(inspection, "_MAX_NODES", 8):
            with self.assertRaisesRegex(ValueError, "AST limits"):
                self.inventory("a = 1\nb = 2\nc = 3\n")

    def test_alias_depth_is_bounded_and_alias_cycles_terminate(self):
        source = "import java as alias0\n" + "".join(
            f"alias{index} = alias{index - 1}\n" for index in range(1, inspection._MAX_DEPTH + 2))
        source += f"alias{inspection._MAX_DEPTH + 1}.jclass('native.Class')\n"
        with self.assertRaisesRegex(ValueError, "alias limits"):
            self.inventory(source)
        report = self.inventory("import java\na = b\nb = a\na.jclass('not.proven')\n")
        self.assertEqual(report["classes"], [])

    def test_non_sdk_optional_dependency_is_not_claimed_as_bundled(self):
        self.write("requests.py", "get = None\n")
        report = self.inventory("import requests\nrequests.not_supported()\n")
        self.assertEqual(report["unsupported_sdk_symbols"], {})
        self.assertEqual(report["imported_symbols"], {})


if __name__ == "__main__":
    unittest.main()
