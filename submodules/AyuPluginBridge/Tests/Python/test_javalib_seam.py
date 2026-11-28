"""The bundled javalib providers through the class seam, with a synthetic host and plugins."""
from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from unittest.mock import patch

import test_bridge as fixtures
import _ayu_javalib as javalib
import ayu_bridge as bridge
import hook_utils
import java
from _ayu_javalib import android_compose, android_graphics, android_text, java_io, java_lang, java_net, java_util

PROVIDERS = ("java_lang", "java_util", "java_io", "java_nio", "java_net", "java_text", "java_time", "org_json",
             "android_os", "android_text", "android_util", "android_content", "android_graphics", "android_compose")


class RegistryTests(unittest.TestCase):
    def test_every_provider_is_listed_and_loads_without_a_host(self):
        self.assertTrue(set(PROVIDERS) <= set(javalib.PROVIDER_MODULES))
        classes = javalib.local_classes()
        for provider in PROVIDERS:
            module = sys.modules["_ayu_javalib." + provider]
            self.assertTrue(module.CLASSES, provider)
            for name, cls in module.CLASSES.items():
                self.assertIs(classes[name], cls, name)
        for name in ("java.io.File", "android.os.Build", "android.os.Build$VERSION", "java.util.ArrayList", "org.json.JSONObject",
                     "android.content.ClipData", "android.graphics.PorterDuff", "java.nio.file.Files", "java.text.SimpleDateFormat"):
            self.assertIn(name, classes)

    def test_only_composed_classes_need_host_operations(self):
        gated = {name for name, cls in javalib.local_classes().items() if javalib.requirements(cls)}
        mine = {name for provider in PROVIDERS for name in sys.modules["_ayu_javalib." + provider].CLASSES}
        self.assertEqual(gated & mine, {"android.util.Log", "android.content.ClipboardManager"})
        usable = javalib.local_class_names([])
        self.assertNotIn("android.util.Log", usable)
        self.assertIn("java.io.File", usable)
        self.assertIn("android.util.Log", javalib.local_class_names(["log.write"]))
        self.assertEqual(javalib.missing_operations("android.content.ClipboardManager", ["log.write"]), ("client.call",))

    def test_names_reserved_for_other_providers_are_not_declared(self):
        mine = {name for provider in PROVIDERS for name in sys.modules["_ayu_javalib." + provider].CLASSES}
        reserved = {"java.lang.Thread", "java.lang.Runnable", "java.lang.ThreadLocal", "java.util.Timer", "java.util.TimerTask",
                    "android.os.Looper", "android.os.Handler", "android.os.HandlerThread", "android.os.Message", "android.os.Process",
                    "android.os.CountDownTimer", "android.os.AsyncTask"}
        self.assertEqual(mine & reserved, set())
        self.assertFalse([name for name in mine if name.startswith(("java.util.concurrent.", "org.telegram.", "com.exteragram."))])

    def test_java_names_round_trip(self):
        for name, cls in javalib.local_classes().items():
            if name.startswith(("java.", "javax.", "org.json.", "android.")):
                self.assertEqual(javalib.local_class(javalib.local_name(cls)), cls, name)
        self.assertEqual((java_lang.java_name(java_io.File), java_lang.java_name(java_util.ArrayList([1])),
                          java_lang.java_name(android_graphics.PorterDuff.Mode)),
                         ("java.io.File", "java.util.ArrayList", "android.graphics.PorterDuff$Mode"))


class SeamTests(unittest.TestCase):
    load = fixtures.BridgeTests.load

    def setUp(self):
        fixtures.BridgeTests.setUp(self)
        javalib.reset()
        self.addCleanup(fixtures.BridgeTests.tearDown, self)
        self.client_calls = []
        perform = self.host.perform

        def extended(request):
            if request["operation"] == "client.call" and request["plugin_id"] in self.host.active:
                self.client_calls.append(request["arguments"])
                return None
            return perform(request)

        self.host.perform = extended

    def blockers(self, text):
        return {(item["code"], item["detail"]) for item in json.loads(bridge.preflight_plugin_json(text))["blockers"]}

    def test_preflight_accepts_local_classes_and_keeps_gated_ones_blocked(self):
        imports = ("from java.io import File, FileOutputStream, BufferedReader\n"
                   "from java.util import ArrayList, HashMap, Locale\n"
                   "from java.lang import String, Integer, Exception, System\n"
                   "from android.os import Build\n"
                   "from android.content import ClipData, ClipboardManager\n"
                   "from android.graphics import PorterDuff, Color\n"
                   "from android.util import Log, Base64\n"
                   "from org.json import JSONObject\n"
                   "from java import jclass\n"
                   "Version = jclass('android.os.Build$VERSION')\n"
                   "import java.nio.file\n")
        text = fixtures.source(imports=imports)
        self.assertEqual(self.blockers(text), set())
        self.host.capabilities["operations"].remove("log.write")
        self.host.capabilities["operations"].remove("client.call")
        self.assertEqual(self.blockers(text), {("CLASS", "android.util.Log"), ("CLASS", "android.content.ClipboardManager")})
        absent = fixtures.source(imports="from android.graphics import Bitmap\nfrom android.os import DropBoxManager\n"
                                         "from java.lang import InterruptedException\n")
        self.assertEqual({detail for code, detail in self.blockers(absent) if code == "CLASS"} - {"java.lang.InterruptedException"},
                         {"android.graphics.Bitmap", "android.os.DropBoxManager"})

    def test_plugin_uses_local_classes_and_sends_plain_values_to_the_host(self):
        with tempfile.TemporaryDirectory() as directory:
            body = (
                "    def on_plugin_load(self):\n"
                f"        folder = File({directory!r}, 'made')\n"
                "        created = folder.mkdirs()\n"
                "        target = File(folder, 'note.txt')\n"
                "        stream = FileOutputStream(target)\n"
                "        stream.write(String('line one\\nline two').getBytes('UTF-8'))\n"
                "        stream.close()\n"
                "        reader = BufferedReader(InputStreamReader(FileInputStream(target)))\n"
                "        lines = ArrayList()\n"
                "        line = reader.readLine()\n"
                "        while line is not None:\n"
                "            lines.add(line)\n"
                "            line = reader.readLine()\n"
                "        reader.close()\n"
                "        summary = HashMap()\n"
                "        summary.put('created', created)\n"
                "        summary.put('size', target.length())\n"
                "        summary.put('modern', Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)\n"
                "        summary.put('maker', Build.MANUFACTURER)\n"
                "        summary.put('parsed', Integer.parseInt('42') + Integer.valueOf(1))\n"
                "        summary.put('json', JSONObject().put('k', lines.size()).toString())\n"
                "        summary.put('color', Color.parseColor('#ff0000'))\n"
                "        self.set_setting('lines', lines)\n"
                "        self.set_setting('summary', summary)\n"
                "        self.set_setting('path', target.getAbsolutePath())\n"
                "        self.set_setting('text', StringBuilder('a').append(1).append(Boolean.TRUE).append(Double(1.5)).toString())\n"
                "        try:\n"
                "            Integer.parseInt('nope')\n"
                "        except Exception as error:\n"
                "            self.set_setting('error', error.getMessage())\n")
            imports = ("from java.io import File, FileOutputStream, FileInputStream, InputStreamReader, BufferedReader\n"
                       "from java.util import ArrayList, HashMap\n"
                       "from java.lang import String, StringBuilder, Integer, Boolean, Double, Exception\n"
                       "from android.os import Build\nfrom android.graphics import Color\nfrom org.json import JSONObject\n")
            self.load(body=body, imports=imports)
            settings = self.host.settings["sample"]
            self.assertEqual(settings["lines"], ["line one", "line two"])
            self.assertEqual(settings["summary"], {"created": True, "size": 17, "modern": True, "maker": "Apple", "parsed": 43,
                                                   "json": '{"k":2}', "color": -65536})
            self.assertEqual((settings["path"], settings["text"], settings["error"]),
                             (os.path.join(directory, "made", "note.txt"), "a1true1.5", 'For input string: "nope"'))
        authorize = next(item for item in self.host.requests if item["operation"] == "plugin.authorize")
        self.assertEqual(authorize["arguments"]["classes"], [])

    def test_lookup_paths_agree_and_the_host_declaration_wins(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            self.assertIs(java.jclass("java.util.ArrayList"), java_util.ArrayList)
            self.assertIs(hook_utils.find_class("android.os.Build$VERSION"), javalib.local_class("android.os.Build").VERSION)
            self.assertIs(__import__("java.io", fromlist=["File"]).File, java_io.File)
            self.assertIsInstance(java.jclass("android.text.SpannableString"), bridge.JavaClass)
            self.assertIs(java.jclass("android.text.style.BackgroundColorSpan"), android_text.BackgroundColorSpan)
            self.assertNotIn("android.text.SpannableString", bridge.runtime.capabilities["local_classes"])
            self.assertEqual(java_lang.Class.forName("java.io.File").getName(), "java.io.File")
            self.assertEqual(java_lang.Class.forName("example.Native").getName(), "example.Native")
            self.assertIs(java_lang.ClassLoader.getSystemClassLoader().loadClass("java.util.HashMap"), java_util.HashMap.getClass())
            with self.assertRaises(java_lang.ClassNotFoundException):
                java_lang.Class.forName("synthetic.Absent")
            native = java.jclass("example.Native")
            self.assertEqual(native.echo(java_util.ArrayList([1, java_util.HashMap({"k": java_lang.String("v")})])), [1, {"k": "v"}])
            self.assertEqual(native.echo(java_io.File("/a/b")), "/a/b")
            self.assertEqual(native.echo([java_lang.Integer(7), java_lang.Boolean.TRUE, java_lang.Double(1.5), java_lang.StringBuilder("sb")]),
                             [7, True, 1.5, "sb"])
            with self.assertRaises(bridge.UnsupportedAPI):
                native.echo(java_lang.Object())
            with self.assertRaises(bridge.UnsupportedAPI):
                native.echo(java_io.ByteArrayOutputStream())
            array = java.jarray(java_lang.String)(["a", None])
            self.assertEqual((len(array), array.length), (2, 2))
            proxy = java.dynamic_proxy(java.jclass("android.content.DialogInterface$OnClickListener"))

            class Listener(proxy):
                def onClick(self, dialog, which):
                    return which

            self.assertEqual(Listener().onClick(None, -1), -1)

    def test_nested_class_attributes_prefer_the_host_declaration(self):
        self.host.capabilities["classes"] += ["android.graphics.PorterDuff$Mode", "android.text.TextUtils$TruncateAt"]
        scope = self.load(imports="from android.graphics import PorterDuff, Shader\nfrom android.text import TextUtils\n"
                                  "mode = PorterDuff.Mode\ntile = Shader.TileMode\ntruncate = TextUtils.TruncateAt\n")
        module = scope.module
        self.assertIsInstance(module.mode, bridge.JavaClass)
        self.assertIsInstance(module.truncate, bridge.JavaClass)
        self.assertEqual(module.mode._name, "android.graphics.PorterDuff$Mode")
        self.assertIs(module.tile, android_graphics.CLASSES["android.graphics.Shader$TileMode"])
        self.assertIs(android_graphics.PorterDuff.Mode, android_graphics.CLASSES["android.graphics.PorterDuff$Mode"])

    def test_log_is_written_through_the_host_log_operation(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            log = java.jclass("android.util.Log")
            self.assertIs(log, android_compose.Log)
            self.assertEqual(log.d("Tag", "message"), len("Tag: message"))
            log.e("Tag", "failed", java_lang.RuntimeException("cause"))
            self.assertEqual(log.println(log.WARN, "T", "\u00e9" * 3000), 6003)
            with self.assertRaises(java_lang.IllegalArgumentException):
                log.println(99, "T", "m")
        records = [item["arguments"] for item in self.host.requests if item["operation"] == "log.write"]
        self.assertEqual((records[0], records[1]["level"], [item["level"] for item in records[2:]]),
                         ({"level": "debug", "message": "Tag: message"}, "error", ["warning", "warning"]))
        self.assertIn("java.lang.RuntimeException: cause", records[1]["message"])
        self.assertTrue(all(len(item["message"].encode("utf-8")) <= 4096 for item in records))

    def test_clipboard_manager_writes_plain_text_through_the_client_call(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            manager = java.jclass("android.content.ClipboardManager")._instance()
            clip = java.jclass("android.content.ClipData").newPlainText("label", "copied text")
            manager.setPrimaryClip(clip)
            self.assertEqual(self.client_calls, [{"name": "copy_to_clipboard", "args": ["copied text"], "kwargs": {}}])
            for call in (manager.getPrimaryClip, manager.hasPrimaryClip, lambda: manager.addPrimaryClipChangedListener(None),
                         lambda: manager.setPrimaryClip(java.jclass("android.content.ClipData").newRawUri("l", "content://x")),
                         java.jclass("android.content.ClipboardManager")):
                with self.assertRaises(bridge.UnsupportedAPI):
                    call()
            with self.assertRaises(java_lang.NullPointerException):
                manager.setPrimaryClip(None)
        with self.assertRaises(bridge.BridgeError):
            android_compose.ClipboardManager._instance()

    def test_url_connection_uses_the_requests_policy(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            with self.assertRaises(bridge.UnsupportedAPI):
                java_net.URL("https://example.invalid/").openConnection()
        bridge.unload_plugin("sample")
        self.host.capabilities["modules"].append("requests")
        scope = self.load()
        import requests
        calls = []

        def respond(method, url, **options):
            calls.append((method, url, options))
            status = 404 if url.endswith("/missing") else 500 if url.endswith("/broken") else 200
            return requests.Response(status, b"payload " + (options.get("data") or b""), {"Content-Type": "text/plain", "X-One": "1"}, url)

        with bridge.runtime.context(scope), patch.object(requests, "request", respond):
            connection = java_net.URL("https://example.invalid/path?q=1#frag").openConnection()
            self.assertIsInstance(connection, java_net.HttpsURLConnection)
            connection.setRequestMethod("POST")
            connection.setRequestProperty("Accept", "text/plain")
            connection.setConnectTimeout(2000)
            connection.setReadTimeout(3000)
            connection.setDoOutput(True)
            connection.getOutputStream().write(b"body")
            self.assertEqual((connection.getResponseCode(), connection.getResponseMessage(), connection.getContentType(),
                              connection.getHeaderField("x-one"), connection.getHeaderFields().get("X-One").get(0),
                              bytes(connection.getInputStream().readAllBytes()), connection.getErrorStream(), connection.getContentLength()),
                             (200, "OK", "text/plain", "1", "1", b"payload body", None, -1))
            self.assertEqual(calls, [("POST", "https://example.invalid/path?q=1",
                                      {"headers": {"Accept": "text/plain"}, "data": b"body", "timeout": 5.0, "allow_redirects": True})])
            with self.assertRaises(java_lang.IllegalStateException):
                connection.setRequestMethod("GET")
            self.assertEqual(bytes(java_net.URL("https://example.invalid/stream").openStream().readAllBytes()), b"payload ")
            missing = java_net.URL("https://example.invalid/missing").openConnection()
            self.assertEqual(missing.getResponseCode(), 404)
            with self.assertRaises(java_io.FileNotFoundException):
                missing.getInputStream()
            self.assertEqual(bytes(missing.getErrorStream().readAllBytes()), b"payload ")
            with self.assertRaises(java_io.IOException) as caught:
                java_net.URL("https://example.invalid/broken").openStream()
            self.assertIn("Server returned HTTP response code: 500", caught.exception.getMessage())
            with self.assertRaises(java_io.IOException) as caught:
                java_net.URL("http://example.invalid/").openConnection().getResponseCode()
            self.assertEqual(caught.exception.getMessage(), "Cleartext HTTP traffic to example.invalid not permitted")
            with self.assertRaises(java_net.ProtocolException):
                java_net.URL("https://example.invalid/").openConnection().setRequestMethod("FETCH")
            with self.assertRaises(bridge.UnsupportedAPI):
                java_net.URL("https://example.invalid/").openConnection().setSSLSocketFactory(None)

        def fail(method, url, **options):
            raise requests.Timeout("HTTPS request timed out")

        with bridge.runtime.context(scope), patch.object(requests, "request", fail):
            with self.assertRaises(java_net.SocketTimeoutException):
                java_net.URL("https://example.invalid/").openStream()

    def test_formats_without_a_locale_follow_the_host_default_locale(self):
        from _ayu_javalib import java_text
        self.host.capabilities["classes"].append("java.util.Locale")
        perform, language, reads = self.host.perform, ["ru"], []

        def with_locale(request):
            arguments = request["arguments"]
            target = arguments.get("target", {}) if isinstance(arguments, dict) else {}
            if request["operation"] == "java.member" and arguments["name"] in ("getDefault", "getLanguage"):
                return {"kind": "method"}
            if request["operation"] == "java.invoke" and arguments["name"] == "getDefault":
                return {"$handle": "locale", "$class": "java.util.Locale"}
            if request["operation"] == "java.invoke" and arguments["name"] == "getLanguage" and target.get("$handle") == "locale":
                reads.append(request["plugin_id"])
                return language[0]
            return perform(request)

        self.host.perform = with_locale
        scope = self.load()
        with bridge.runtime.context(scope):
            formatter = java_text.SimpleDateFormat("d MMMM")
            formatter.setTimeZone(java_util.TimeZone.getTimeZone("UTC"))
            self.assertEqual(formatter.format(java_util.Date(0)), "1 \u044f\u043d\u0432\u0430\u0440\u044f")
            self.assertEqual(java_text.DecimalFormat("0.0").format(1.5), "1,5")
            self.assertEqual(java_text.SimpleDateFormat("HH:mm").toPattern(), "HH:mm")
            self.assertEqual(reads, ["sample"])
            formatter = java_text.SimpleDateFormat("d MMMM", java_util.Locale.US)
            formatter.setTimeZone(java_util.TimeZone.getTimeZone("UTC"))
            self.assertEqual(formatter.format(0), "1 January")
        bridge.unload_plugin("sample")
        language[0] = "de"
        scope = self.load()
        with bridge.runtime.context(scope):
            with self.assertRaises(bridge.UnsupportedAPI):
                java_text.SimpleDateFormat("d MMMM")
            with self.assertRaises(bridge.UnsupportedAPI):
                java_text.DecimalFormat("0.0")
            self.assertEqual(java_text.DecimalFormat("0.0", java_text.DecimalFormatSymbols(java_util.Locale.US)).format(1.5), "1.5")

    def test_system_properties_and_defaults_are_scoped_to_the_plugin_generation(self):
        first = self.load("first")
        second = self.load("second")
        with bridge.runtime.context(first):
            java_lang.System.setProperty("synthetic.scoped", "one")
            java_util.Locale.setDefault(java_util.Locale("fr", "FR"))
            self.assertEqual(java_lang.System.getProperty("synthetic.scoped"), "one")
        with bridge.runtime.context(second):
            self.assertIsNone(java_lang.System.getProperty("synthetic.scoped"))
            self.assertNotEqual(java_util.Locale.getDefault(), java_util.Locale("fr", "FR"))
        generation = first.generation
        bridge.unload_plugin("first")
        with bridge.runtime.context(second):
            java_lang.System.setProperty("synthetic.other", "two")
        self.assertFalse([key for key in java_lang._stores if key[0] == generation])


if __name__ == "__main__":
    unittest.main()
