"""Synthetic portable SDK contracts. No supplied attachment is imported/executed."""
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

SDK = Path(__file__).resolve().parents[2] / "Python"
sys.path.insert(0, str(SDK))

import ayu_bridge as bridge
import android_utils
import file_utils
import hook_utils
from extera_utils import classes, lifecycle
from extera_utils.get_caller import get_plugin_id, _plugin_id_from_location
from extera_utils.metadata_parser import MAX_SOURCE_BYTES, get_metadata
from extera_utils.text_formatting import (HTML, Markdown, RawEntity, TLEntityType as E,
                                         add_surrogates, remove_surrogates, parse_text)
from intents import IntentsManager
from log_utils import Logger, LogLevel, dump, get_logger, _split_for_logcat
from markdown_utils import parse_markdown, to_utf16_len
import test_bridge as fixtures


class FormattingTests(unittest.TestCase):
    def test_surrogate_conversion_is_idempotent(self):
        text = "a😀𝄞z"
        expanded = add_surrogates(text)
        self.assertEqual(len(expanded), 6)
        self.assertEqual(add_surrogates(expanded), expanded)
        self.assertEqual(remove_surrogates(expanded), text)

    def test_html_nested_entities_and_utf16_offsets(self):
        parsed = HTML.parse('😀<b>x<i>😀</i>y</b> &amp; <emoji id="123">😎</emoji>')
        self.assertEqual(parsed["message"], "😀x😀y & 😎")
        self.assertEqual([(e.type, e.offset, e.length) for e in parsed["entities"]],
                         [(E.BOLD, 2, 4), (E.ITALIC, 3, 2), (E.CUSTOM_EMOJI, 9, 2)])
        self.assertEqual(parsed["entities"][-1].document_id, 123)

    def test_html_entities_decode_once(self):
        self.assertEqual(HTML.parse("&amp;lt; &lt;tag&gt;")["message"], "&lt; <tag>")
        parsed = HTML.parse("<b>&#128512;</b>")
        self.assertEqual(parsed["message"], "😀")
        self.assertEqual(parsed["entities"][0].length, 2)

    def test_html_optional_fields_and_unclosed_tags(self):
        parsed = HTML.parse('<pre lang="py">x</pre><blockquote expandable>y</blockquote><b>z')
        self.assertEqual(parsed["message"], "xyz")
        self.assertEqual(parsed["entities"][0].language, "py")
        self.assertTrue(parsed["entities"][1].collapsed)
        self.assertEqual(len(parsed["entities"]), 2)

    def test_html_unparse_round_trip_escapes_text_and_attributes(self):
        text = '😀<&"'
        entities = [RawEntity(E.BOLD, 0, 5), RawEntity(E.TEXT_LINK, 2, 3, url='https://a/?q="&x=<')]
        rendered = HTML.unparse(text, entities)
        self.assertIn("&lt;&amp;", rendered)
        self.assertIn("&quot;&amp;x=&lt;", rendered)
        parsed = HTML.parse(rendered)
        self.assertEqual(parsed["message"], text)
        self.assertEqual([(e.type, e.offset, e.length) for e in parsed["entities"]],
                         [(E.BOLD, 0, 5), (E.TEXT_LINK, 2, 3)])
        self.assertEqual(entities[0].type, E.BOLD)
        self.assertEqual(HTML.unparse("<&", []), "&lt;&amp;")

    def test_unparse_rejects_crossing_invalid_and_split_ranges(self):
        for text, entities in (("abcd", [RawEntity(E.BOLD, 0, 3), RawEntity(E.ITALIC, 1, 3)]),
                               ("a", [RawEntity(E.BOLD, 0, 2)]),
                               ("😀", [RawEntity(E.BOLD, 0, 1)])):
            with self.subTest(text=text), self.assertRaises(ValueError):
                HTML.unparse(text, entities)

    def test_markdown_portable_markup_and_escaping(self):
        parsed = Markdown.parse(r"😀 *bold* __under__ ~strike~ ||hidden|| \*literal\* [site](https://e.test)")
        self.assertEqual(parsed["message"], "😀 bold under strike hidden *literal* site")
        self.assertEqual([e.type for e in parsed["entities"]], [E.BOLD, E.UNDERLINE, E.STRIKETHROUGH, E.SPOILER, E.TEXT_LINK])
        self.assertEqual(parsed["entities"][0].offset, 3)
        self.assertEqual(Markdown.parse("`*<&*`", strict=True)["message"], "*<&*")
        self.assertEqual(Markdown.parse("<b>x</b>", strict=True)["entities"], [])

    def test_markdown_pre_and_quotes(self):
        parsed = Markdown.parse("```py\nprint('<')\n```\n> one\n> two\nend")
        self.assertIn("print('<')", parsed["message"])
        self.assertEqual(parsed["entities"][0].type, E.PRE)
        self.assertEqual(parsed["entities"][0].language, "py")
        quote = next(e for e in parsed["entities"] if e.type == E.BLOCKQUOTE)
        self.assertEqual(quote.length, 7)
        expanded = Markdown.parse("**> one\n> two||")
        self.assertTrue(expanded["entities"][0].collapsed)
        self.assertEqual(expanded["message"], "one\ntwo")

    def test_markdown_unparse_utf16_and_links(self):
        entities = [RawEntity(E.BOLD, 2, 1), RawEntity(E.CUSTOM_EMOJI, 3, 2, document_id=99)]
        self.assertEqual(Markdown.unparse("😀x😎", entities), "😀*x*![😎](tg://emoji?id=99)")

    def test_legacy_markdown_nested_utf16_and_numeric_emoji(self):
        parsed = parse_markdown("😀 *a _😀_ b* [😎](123) [site](https://e.test)")
        self.assertEqual(parsed.text, "😀 a 😀 b 😎 site")
        self.assertIsInstance(parsed.entities, tuple)
        self.assertEqual([(e.type, e.offset, e.length) for e in parsed.entities],
                         [(E.BOLD, 3, 6), (E.ITALIC, 5, 2), (E.CUSTOM_EMOJI, 10, 2), (E.TEXT_LINK, 13, 4)])
        self.assertEqual(to_utf16_len("😀"), 2)

    def test_legacy_markdown_rejects_unclosed_and_preserves_escapes(self):
        for text in ("*unclosed", "`unclosed", "*cross _close*"):
            with self.subTest(text=text), self.assertRaises(ValueError):
                parse_markdown(text)
        self.assertEqual(parse_markdown(r"\*literal\* @a_b [broken").text, "*literal* @a_b [broken")
        parsed = parse_markdown("```py\nx  \n```")
        self.assertEqual(parsed.text, "x  \n")
        self.assertEqual(parsed.entities[0].length, 1)

    def test_parse_text_plain_contract(self):
        self.assertEqual(parse_text("<b>x</b>", None, True), {"caption": "<b>x</b>", "entities": []})
        self.assertEqual(parse_text("plain", "HTML"), {"message": "plain", "entities": []})


class PortableHostTests(unittest.TestCase):
    # Reuse only the fixture lifecycle, not the inherited bridge tests.
    setUp = fixtures.BridgeTests.setUp
    tearDown = fixtures.BridgeTests.tearDown
    load = fixtures.BridgeTests.load

    def test_native_entity_conversion_uses_python_local_tl_class_without_host_adapter(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            entity = parse_text("<b>text</b>")["entities"][0]
        self.assertEqual((type(entity).__name__, entity.offset, entity.length), ("TL_messageEntityBold", 0, 4))

    def test_native_entity_conversion_uses_only_requested_class(self):
        class_name = "org.telegram.tgnet.TLRPC$TL_messageEntityBold"
        self.host.capabilities["classes"].append(class_name)
        scope = self.load()
        original = self.host.perform

        def perform(request):
            return None if request["operation"] == "java.set_field" else original(request)

        with patch.object(self.host, "perform", side_effect=perform), bridge.runtime.context(scope):
            parsed = parse_text("😀<b>x</b>")
        entity = parsed["entities"][0]
        self.assertIsInstance(entity, bridge.RemoteObject)
        writes = [r["arguments"] for r in self.host.requests if r["operation"] == "java.set_field"]
        self.assertEqual([(r["name"], r["value"]) for r in writes], [("offset", 2), ("length", 1)])

    def test_binders_do_not_schedule_and_are_revoked_on_unload(self):
        scope = self.load()
        calls = []
        with bridge.runtime.context(scope):
            bound = lifecycle.bind_task(lambda value: calls.append(value), once=True)
            self.assertFalse(self.host.tokens)
            bound(1)
            bound(2)
            self.assertEqual(calls, [1])
            bound = lifecycle.bind(lambda: calls.append(3))
        bridge.unload_plugin("sample")
        self.assertTrue(bound.cancelled)
        self.assertIsNone(bound())
        self.assertEqual(calls, [1])

    def test_binder_cancel_and_cross_owner_rejection(self):
        left, right = self.load("left"), self.load("right")
        calls = []
        with bridge.runtime.context(left):
            bound = lifecycle.bind(lambda: calls.append("called"))
            bound.set_cancel(lambda: calls.append("cancelled"))
        with bridge.runtime.context(right), self.assertRaisesRegex(bridge.BridgeError, "OWNERSHIP"):
            bound()
        with bridge.runtime.context(left):
            bound.cancel()
            bound.cancel()
            bound()
        self.assertEqual(calls, ["cancelled"])

    def test_logging_levels_handlers_formatting_and_owner_scope(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            logger = get_logger()
            logger.level = "DEBUG"
            self.assertIs(get_logger(), logger)
            child = logger.child("network")
            records = []
            logger.add_handler(records.append)
            child.debug("value=%(value)s", {"value": 9})
            self.assertEqual(records[0].message, "value=9")
            self.assertEqual(records[0].level, LogLevel.DEBUG)
            self.assertEqual(records[0].tag, "plugin.sample.network")
            self.assertTrue(logger.remove_handler(records.append))
            self.assertFalse(logger.remove_handler(records.append))
            child.level = "OFF"
            before = len(self.host.requests)
            child.error("filtered")
            self.assertEqual(len(self.host.requests), before)
        other = self.load("other")
        with bridge.runtime.context(other), self.assertRaisesRegex(bridge.BridgeError, "OWNERSHIP"):
            logger.info("wrong owner")

    def test_log_chunks_and_android_dump(self):
        scope = self.load()
        text = "😀é\n" * 3000
        chunks = _split_for_logcat(text, 19)
        self.assertEqual("".join(chunks), text)
        self.assertTrue(all(len(chunk.encode("utf-8")) <= 19 for chunk in chunks))
        with bridge.runtime.context(scope):
            android_utils.log({"key": 1})
        entry = next(r for r in self.host.requests if r["operation"] == "log.write")
        self.assertIn("'key': 1", entry["arguments"]["message"])

    def test_logging_exceptions_timing_and_handler_failures(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            logger = Logger("test", show_location=False)
            records = []

            def failing_handler(record):
                raise ValueError("synthetic handler failure")

            logger.add_handler(failing_handler)
            logger.add_handler(records.append)
            try:
                raise ValueError("synthetic exception")
            except ValueError:
                logger.exception("failure %s", 1)
            self.assertIn("synthetic exception", records[0].traceback)
            self.assertEqual(records[0].message, "failure 1")
            with patch("log_utils.time.perf_counter", side_effect=[1, 1.025]):
                with logger.timed("work", level="INFO"):
                    pass
            self.assertEqual(records[1].message, "work took 25.0 ms")

    def test_hook_helpers_use_declared_reflection_and_keep_keyword_signatures(self):
        scope = self.load()
        original = self.host.perform
        with bridge.runtime.context(scope):
            clazz = hook_utils.find_class(class_name="example.Native")
            self.assertIs(hook_utils.java_class(clazz), clazz)
            self.assertEqual(hook_utils.java_class("example.Native")._name, clazz._name)

            def perform(request):
                op, args = request["operation"], request["arguments"]
                if op == "java.member" and args["name"] == "getDeclaredMethod":
                    return {"kind": "method"}
                if op == "java.invoke" and args["name"] == "getDeclaredMethod":
                    return "synthetic method descriptor"
                if op == "java.set_private_field":
                    return None
                if op == "java.get_private_field":
                    return 7
                return original(request)

            with patch.object(self.host, "perform", side_effect=perform):
                self.assertEqual(hook_utils.get_method(clazz, "echo"), "synthetic method descriptor")
                self.assertTrue(hook_utils.set_static_private_field(clazz, field_name="declared", new_value=8))
                self.assertEqual(hook_utils.get_static_private_field(clazz, field_name="declared"), 7)

    def test_file_operations_with_synthetic_temp_files(self):
        scope = self.load()
        with bridge.runtime.context(scope), tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            file_utils.ensure_dir_exists(root / "nested")
            text, binary = root / "text.txt", root / "nested" / "blob.bin"
            self.assertIsNone(file_utils.write_file(text, "hello 😀"))
            self.assertIsNone(file_utils.write_file_bytes(binary, b"\x00\xff"))
            self.assertEqual(file_utils.read_file(text), "hello 😀")
            self.assertEqual(file_utils.read_file_bytes(binary), b"\x00\xff")
            self.assertEqual(file_utils.list_dir(root, recursive=True, extensions=[".bin"]), [str(binary)])
            self.assertEqual(file_utils.list_dir(root, include_files=False, include_dirs=True), [str(root / "nested")])
            self.assertTrue(file_utils.delete_file(text))
            self.assertFalse(file_utils.delete_file(text))
            self.assertIsNone(file_utils.read_file(text))

    def test_android_scheduling_and_runnable_use_existing_adapters(self):
        self.host.capabilities["classes"].append("java.lang.Runnable")
        self.host.capabilities["proxy_interfaces"]["java.lang.Runnable"] = ["run"]
        scope = self.load()
        calls = []
        with bridge.runtime.context(scope):
            task = android_utils.run_on_ui_thread(lambda: calls.append("scheduled"), delay=12)
            record = self.host.tokens[task.token][1]
            self.assertEqual((record["queue"], record["delay_ms"]), ("main", 12))
            runnable = android_utils.R(lambda: calls.append("run"))
            bridge.runtime.encode(runnable)
            runnable.run()
        self.assertEqual(calls, ["run"])

    def test_clipboard_uses_bounded_native_client_adapter(self):
        scope = self.load()
        native_calls = []
        original = self.host.perform

        def perform(request):
            if request["operation"] == "client.call":
                arguments = request["arguments"]
                native_calls.append(arguments)
                self.assertEqual(arguments["name"], "copy_to_clipboard")
                self.assertEqual(arguments["kwargs"], {})
                self.assertEqual(len(arguments["args"]), 1)
                return None
            return original(request)

        with patch.object(self.host, "perform", side_effect=perform), bridge.runtime.context(scope):
            self.assertIsNone(android_utils.copy_to_clipboard("Copied 😀"))
            self.assertEqual(native_calls[0]["args"], ["Copied 😀"])
            for invalid in (None, 1, b"bytes"):
                with self.subTest(invalid=invalid), self.assertRaises(TypeError):
                    android_utils.copy_to_clipboard(invalid)
            with self.assertRaises(ValueError):
                android_utils.copy_to_clipboard("x" * 65_537)
        self.assertEqual(len(native_calls), 1)

    def test_unavailable_native_helpers_fail_explicitly(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            for call in (lambda: file_utils.FilesController.register(file_utils.FilesController.FileInfo("txt", lambda value: None)),
                         lambda: android_utils.OnLongClickListener(lambda view: True),
                         lambda: classes.joverride(), lambda: classes.joverload("x", []),
                         lambda: lifecycle.on_plugin_load(lambda: None),
                         lambda: IntentsManager.new_global_before_handler(IntentsManager.HandlerInfo(lambda: None)),
                         lambda: hook_utils.get_method("example.Native", "unsupported")):
                with self.subTest(call=call), self.assertRaises(bridge.BridgeError) as caught:
                    call()
                self.assertEqual(caught.exception.code, "UNSUPPORTED_API")


class PortableValueTests(unittest.TestCase):
    def test_dump_is_bounded_and_cycle_safe(self):
        value = {"a": [1, 2, 3]}
        value["cycle"] = value
        self.assertIn("<cycle>", dump(value, depth=3))
        self.assertIn("2 more", dump([1, 2, 3], max_items=1))
        self.assertIn("…", dump(value, depth=0))
        self.assertEqual(dump({"a": 1}), "dict(1) {'a': 1}")

    def test_uri_parser_preserves_android_raw_split_semantics(self):
        self.assertEqual(IntentsManager.parse("https://example.test/path?q=a%20b"),
                         {"scheme": "https", "host": "example.test", "path": "path?q=a%20b", "query": "q=a%20b"})
        with self.assertRaises(ValueError):
            IntentsManager.parse("missing scheme")

    def test_metadata_is_literal_and_never_executes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "synthetic.plugin"
            marker = Path(directory) / "must-not-exist"
            path.write_text('__id__ = "synthetic"\n__requirements__ = ["one", "two"]\n'
                            '__min_version__ = "12.0"\n__author__ = str(123)\n'
                            'class Ignored:\n    __name__ = "nested"\n'
                            f'open({str(marker)!r}, "w").write("bad")\n', encoding="utf-8")
            self.assertEqual(get_metadata(path), {"id": "synthetic", "requirements": "one,two", "app_version": ">=12.0"})
            self.assertFalse(marker.exists())

    def test_metadata_parser_accepts_the_shared_four_mib_source_limit(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bounded.plugin"
            prefix = '__id__ = "bounded"\n'
            source = prefix + "#" + "x" * (MAX_SOURCE_BYTES - len(prefix.encode("utf-8")) - 1)
            self.assertEqual(len(source.encode("utf-8")), 4 * 1024 * 1024)
            path.write_bytes(source.encode("utf-8"))
            self.assertEqual(get_metadata(path), {"id": "bounded"})

            path.write_bytes((source + "x").encode("utf-8"))
            with self.assertRaisesRegex(ValueError, "source limit"):
                get_metadata(path)

    def test_get_caller_handles_namespaces_and_windows_paths(self):
        self.assertEqual(_plugin_id_from_location("irrelevant", "ElyxPlugins.my_plugin.utils"), "my_plugin")
        self.assertEqual(_plugin_id_from_location(r"C:\plugins\example.plugin"), "example")
        location, plugin_id = get_plugin_id(self.test_get_caller_handles_namespaces_and_windows_paths)
        self.assertIn("test_portable_sdk.py:", location)
        self.assertEqual(plugin_id, "test_portable_sdk")


if __name__ == "__main__":
    unittest.main()
