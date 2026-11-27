"""Intents, picked documents and the ``activity.result`` hook point against a scripted host."""
from __future__ import annotations

import json
import os
import unittest

from pymembers_fixtures import CONTEXT, HostCase, entry  # puts the SDK on the path
import _ayu_intents
import _ayu_javalib as javalib
import _ayu_xposed
import ayu_bridge as bridge

URI = "android.net.Uri"
ACTIVITY = "org.telegram.ui.LaunchActivity"
IMPORTS = ("from android.app import Activity\nfrom android.content import Intent\nfrom android.net import Uri\n"
           "from base_plugin import HookFilter, MethodHook, MethodReplacement, hook_filters\n"
           "from hook_utils import find_class\nfrom java.lang import Integer\n")


class IntentCase(HostCase):
    def setUp(self):
        super().setUp()
        self.operations(_ayu_intents.OPERATION, "client.call")

        def name_of(target, args):
            if not target["$handle"].startswith("class:"):
                raise bridge.UnsupportedAPI("Undeclared method")
            return CONTEXT

        def declared(target, args):
            if len(args) != 1:
                raise bridge.BridgeError("INVALID_ARGUMENTS", "Class.getDeclaredMethod supports name-only lookup")
            raise bridge.UnsupportedAPI("reflection target")

        self.declare(CONTEXT, {"getClass": lambda target, args: {"$handle": "class:context", "$class": CONTEXT},
                               "getName": name_of, "getDeclaredMethod": declared, "getDeclaredMethods": lambda target, args: []},
                     entry(methods=["getClass", "getResources"]))
        self.declare(URI, {"parse": lambda target, args: {"$handle": "uri:" + args[0], "$class": URI},
                           "toString": lambda target, args: target["$handle"][4:]},
                     entry(static_methods=["parse"], methods=["toString", "getScheme"]))
        self.launches = []
        perform = self.host.perform

        def launching(request):
            if request["operation"] == _ayu_intents.OPERATION and request["plugin_id"] in self.host.active:
                self.launches.append(request["arguments"])
                return "token-%d" % len(self.launches)
            return perform(request)

        self.host.perform = launching

    def context(self):
        return self.reference(CONTEXT, "context")

    def answer(self, scope, wire, launch=-1):
        """The host's picker callback for one recorded launch."""
        callback = self.launches[launch]["callback"]["$callback"]
        return bridge.invoke_callback_json(json.dumps({"version": 1, "plugin_id": scope.plugin_id, "callback_id": callback,
                                                       "arguments": [wire]}))

    def document(self, name, data, mime="text/plain"):
        path = os.path.join(self.home, name)
        with open(path, "wb") as stream:
            stream.write(data)
        return {"path": path, "name": name, "size": len(data), "mime_type": mime}

    def picked(self, token, *documents):
        return {"token": token, "result_code": -1, "documents": list(documents)}


class IntentValueTests(IntentCase):
    def test_data_type_categories_flags_and_extras_follow_android(self):
        scope = self.load(imports=IMPORTS)
        with bridge.runtime.context(scope):
            Intent, Uri = scope.module.Intent, scope.module.Uri
            self.assertIs(Intent, javalib.local_class("android.content.Intent"))
            uri = Uri.parse("https://example.org/a")
            intent = Intent(Intent.ACTION_VIEW, uri)
            self.assertEqual((intent.getAction(), intent.getData(), intent.getDataString(), intent.getScheme()),
                             ("android.intent.action.VIEW", uri, "https://example.org/a", "https"))
            # setType clears the data and setData clears the type; setDataAndType keeps both.
            self.assertIs(intent.setType("image/*"), intent)
            self.assertEqual((intent.getData(), intent.getType()), (None, "image/*"))
            intent.setData(uri)
            self.assertEqual((intent.getData(), intent.getType()), (uri, None))
            intent.setDataAndType(uri, "text/plain")
            self.assertEqual((intent.getData(), intent.getType()), (uri, "text/plain"))
            self.assertIsNone(intent.getCategories())
            intent.addCategory(Intent.CATEGORY_OPENABLE).addCategory(Intent.CATEGORY_OPENABLE)
            self.assertEqual(list(intent.getCategories()), ["android.intent.category.OPENABLE"])
            self.assertTrue(intent.hasCategory(Intent.CATEGORY_OPENABLE))
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            self.assertEqual(intent.getFlags(), 0x10000001)
            intent.setFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            self.assertEqual(intent.getFlags(), 1)
            self.assertIsNone(intent.getExtras())
            intent.putExtra("text", "value").putExtra("count", 7).putExtra("flag", True).putExtra("ratio", 1.5)
            self.assertEqual((intent.getStringExtra("text"), intent.getIntExtra("count", -1), intent.getBooleanExtra("flag", False),
                              intent.getDoubleExtra("ratio", 0.0)), ("value", 7, True, 1.5))
            # A typed getter answers its default for another type and for a missing key.
            self.assertEqual((intent.getStringExtra("count"), intent.getIntExtra("text", -1), intent.getIntExtra("flag", -1),
                              intent.getBooleanExtra("absent", True), intent.hasExtra("absent")), (None, -1, -1, True, False))
            extras = intent.getExtras()
            self.assertEqual((extras.getString("text"), extras.getInt("count"), extras.getBoolean("flag")), ("value", 7, True))
            copy = Intent(intent)
            copy.putExtra("text", "other").setPackage("org.example")
            self.assertEqual((intent.getStringExtra("text"), intent.getPackage(), copy.getPackage()), ("value", None, "org.example"))
            self.assertEqual(Intent("a").setPackage("p").toString(), "Intent { act=a pkg=p }")
            self.assertEqual(Intent().toString(), "Intent { }")
            self.assertEqual((Intent.ACTION_CREATE_DOCUMENT, scope.module.Activity.RESULT_OK, scope.module.Activity.RESULT_CANCELED),
                             ("android.intent.action.CREATE_DOCUMENT", -1, 0))

    def test_chooser_carries_the_target_and_its_grants(self):
        scope = self.load(imports=IMPORTS)
        with bridge.runtime.context(scope):
            Intent, Uri = scope.module.Intent, scope.module.Uri
            uri = Uri.parse("file:///tmp/a.txt")
            target = Intent(Intent.ACTION_SEND).setDataAndType(uri, "text/plain")
            target.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_ACTIVITY_NEW_TASK)
            chooser = Intent.createChooser(target, "Share")
            self.assertEqual((chooser.getAction(), chooser.getParcelableExtra(Intent.EXTRA_INTENT), chooser.getStringExtra(Intent.EXTRA_TITLE)),
                             ("android.intent.action.CHOOSER", target, "Share"))
            self.assertEqual((chooser.getFlags(), chooser.getClipData().getItemAt(0).getUri(), chooser.getClipData().getDescription().getMimeType(0)),
                             (1, uri, "text/plain"))
            plain = Intent.createChooser(Intent(Intent.ACTION_SEND), None)
            self.assertEqual((plain.getFlags(), plain.getClipData(), plain.hasExtra(Intent.EXTRA_TITLE)), (0, None, False))
            restart = Intent.makeRestartActivityTask(target.setClassName("a.b", "a.b.C").getComponent())
            self.assertEqual((restart.getAction(), restart.getComponent().flattenToString(), restart.getFlags(), list(restart.getCategories())),
                             ("android.intent.action.MAIN", "a.b/a.b.C", 0x10008000, ["android.intent.category.LAUNCHER"]))

    def test_without_the_operation_the_host_adapter_and_its_members_stay(self):
        self.operations(remove=[_ayu_intents.OPERATION])
        self.declare("android.content.Intent", table=entry(constructor=True, methods=["addFlags"], static_fields=["ACTION_VIEW"]))
        scope = self.load(imports=IMPORTS)
        with bridge.runtime.context(scope):
            self.assertIsInstance(scope.module.Intent, bridge.JavaClass)
            with self.assertRaises(bridge.MissingMember):
                self.context().startActivity
            with self.assertRaises(bridge.MissingMember):
                self.context().startActivityForResult
            # Nothing that needs the host: the resolver and the package manager are still served.
            self.assertEqual(self.context().getPackageManager().getPackageInfo("com.exteragram.messenger", 0).versionName, "13.2.2")
        self.assertEqual(self.blockers(IMPORTS, "    def on_plugin_load(self):\n        Intent(Intent.ACTION_VIEW).setType('a/b')\n"),
                         [("OPERATION", "intents.launch (android.content.Intent.setType)")])


class PlanTests(IntentCase):
    def setUp(self):
        super().setUp()
        self.scope = self.load(imports=IMPORTS + "from androidx.core.content import FileProvider\nfrom java.io import File\n")

    def plan(self, build, for_result=False):
        with bridge.runtime.context(self.scope):
            return _ayu_intents.plan(build(self.scope.module.Intent, self.scope.module.Uri), for_result)

    def refused(self, build, for_result=False):
        with self.assertRaises(bridge.UnsupportedAPI) as raised:
            self.plan(build, for_result)
        return raised.exception.message

    def test_pickers(self):
        self.assertEqual(self.plan(lambda Intent, Uri: Intent.createChooser(
            Intent(Intent.ACTION_GET_CONTENT).setType("Image/*").addCategory(Intent.CATEGORY_OPENABLE), "Pick"), True),
            {"kind": "pick", "types": ["image/*"], "multiple": False})

    def test_picker_with_mime_list_and_multiple(self):
        self.assertEqual(self.plan(lambda Intent, Uri: Intent(Intent.ACTION_OPEN_DOCUMENT).setType("*/*")
                                   .putExtra(Intent.EXTRA_MIME_TYPES, ["audio/mpeg", "audio/*", "audio/mpeg"])
                                   .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, True)
                                   .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION), True),
                         {"kind": "pick", "types": ["audio/mpeg", "audio/*"], "multiple": True})

    def test_picker_refusals(self):
        self.assertIn("needs startActivityForResult", self.refused(lambda Intent, Uri: Intent(Intent.ACTION_GET_CONTENT).setType("*/*")))
        self.assertIn("extra android.intent.extra.INITIAL_URI", self.refused(
            lambda Intent, Uri: Intent(Intent.ACTION_OPEN_DOCUMENT).setType("*/*").putExtra("android.intent.extra.INITIAL_URI", 1), True))
        self.assertIn("category android.intent.category.HOME", self.refused(
            lambda Intent, Uri: Intent(Intent.ACTION_GET_CONTENT).setType("*/*").addCategory(Intent.CATEGORY_HOME), True))
        self.assertIn("invalid MIME type", self.refused(lambda Intent, Uri: Intent(Intent.ACTION_GET_CONTENT).setType("images"), True))
        with self.assertRaises(javalib.local_class("android.content.ActivityNotFoundException")):
            self.plan(lambda Intent, Uri: Intent(Intent.ACTION_GET_CONTENT), True)

    def test_links(self):
        self.assertEqual(self.plan(lambda Intent, Uri: Intent(Intent.ACTION_VIEW, Uri.parse("https://example.org/x?y=1"))
                                   .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)), {"kind": "view", "url": "https://example.org/x?y=1"})
        # The emulated client's own package is this application.
        self.assertEqual(self.plan(lambda Intent, Uri: Intent(Intent.ACTION_VIEW).setData(Uri.parse("tg://resolve?domain=a"))
                                   .setPackage("com.exteragram.messenger")), {"kind": "view", "url": "tg://resolve?domain=a"})

    def test_refusals_name_the_action(self):
        cases = {
            "Intent android.intent.action.VIEW for the Android package org.other":
                lambda Intent, Uri: Intent(Intent.ACTION_VIEW, Uri.parse("https://a.b")).setPackage("org.other"),
            "Intent android.intent.action.VIEW of a file": lambda Intent, Uri: Intent(Intent.ACTION_VIEW).setDataAndType(Uri.parse("https://a.b/c.pdf"), "application/pdf"),
            "Intent android.intent.action.VIEW of a market: URI": lambda Intent, Uri: Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=a")),
            "Intent android.intent.action.CREATE_DOCUMENT cannot be launched": lambda Intent, Uri: Intent(Intent.ACTION_CREATE_DOCUMENT).setType("a/b"),
            "Intent android.settings.action.MANAGE_OVERLAY_PERMISSION cannot be launched":
                lambda Intent, Uri: Intent("android.settings.action.MANAGE_OVERLAY_PERMISSION", Uri.parse("package:a")),
            "Intent android.intent.action.MAIN for the Android component a.b/.C": lambda Intent, Uri: Intent(Intent.ACTION_MAIN).setClassName("a.b", "a.b.C"),
            "Intent android.intent.action.SEND without EXTRA_TEXT or EXTRA_STREAM": lambda Intent, Uri: Intent(Intent.ACTION_SEND).setType("text/plain"),
            "Intent android.intent.action.SEND with the extra android.intent.extra.EMAIL":
                lambda Intent, Uri: Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_TEXT, "a").putExtra(Intent.EXTRA_EMAIL, ["a@b"]),
            "Intent null cannot be launched": lambda Intent, Uri: Intent(),
        }
        for expected, build in cases.items():
            with self.subTest(expected=expected):
                self.assertIn(expected, self.refused(build))
        self.assertIn("cannot be started for a result", self.refused(
            lambda Intent, Uri: Intent(Intent.ACTION_VIEW, Uri.parse("https://a.b")), True))

    def test_sharing_text_and_files_of_the_plugin_storage(self):
        scope = self.scope
        with bridge.runtime.context(scope):
            module = scope.module
            Intent, Uri, File, FileProvider = module.Intent, module.Uri, module.File, module.FileProvider
            context = self.context()
            directory = context.getFilesDir()
            shared = File(directory, "export/a b.json")
            os.makedirs(shared.getParentFile().getPath())
            with open(shared.getPath(), "wb") as stream:
                stream.write(b"{}")
            uri = FileProvider.getUriForFile(context, context.getPackageName() + ".provider", shared)
            self.assertEqual(uri.toString(), "content://com.exteragram.messenger.provider/files/export/a%20b.json")
            send = Intent(Intent.ACTION_SEND).setType("application/json").putExtra(Intent.EXTRA_STREAM, uri).putExtra(Intent.EXTRA_TEXT, "note")
            self.assertEqual(_ayu_intents.plan(Intent.createChooser(send, "Share"), False),
                             {"kind": "share", "text": "note", "files": [os.path.realpath(shared.getPath())]})
            several = Intent(Intent.ACTION_SEND_MULTIPLE).putParcelableArrayListExtra(Intent.EXTRA_STREAM, [uri, Uri.fromFile(shared)])
            self.assertEqual(_ayu_intents.plan(several, False), {"kind": "share", "files": [os.path.realpath(shared.getPath())]})
            resolver = context.getContentResolver()
            with resolver.openInputStream(uri) as stream:
                self.assertEqual(bytes(stream.readAllBytes()), b"{}")
            self.assertEqual(resolver.getType(uri), "application/json")
            cursor = resolver.query(uri, None, None, None, None)
            self.assertEqual((cursor.getColumnNames(), cursor.moveToFirst(), cursor.getString(0), cursor.getLong(1)),
                             (["_display_name", "_size"], True, "a b.json", 2))
            output = resolver.openOutputStream(uri)
            output.write(b"[1]")
            output.close()
            with open(shared.getPath(), "rb") as stream:
                self.assertEqual(stream.read(), b"[1]")
            # Android's errors for an unknown authority and for a file no configured root contains.
            with self.assertRaises(ValueError) as raised:
                FileProvider.getUriForFile(context, "org.other.provider", shared)
            self.assertIn("Couldn't find meta-data for provider with authority org.other.provider", str(raised.exception))
            outside = File(self.home, "outside.txt")
            open(outside.getPath(), "wb").close()
            with self.assertRaises(ValueError) as raised:
                FileProvider.getUriForFile(context, "com.exteragram.messenger.provider", outside)
            self.assertIn("Failed to find configured root that contains", str(raised.exception))
            with self.assertRaises(bridge.UnsupportedAPI) as refused:
                _ayu_intents.plan(Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_STREAM, Uri.fromFile(outside)), False)
            self.assertIn("outside the plugin storage", refused.exception.message)
            self.assertIsNone(resolver.query(Uri.parse("content://media/external/images/1"), None, None, None, None))
            with self.assertRaises(javalib.local_class("java.io.FileNotFoundException")):
                resolver.openInputStream(Uri.parse("content://media/external/images/1"))


HOOKS = ("    def on_plugin_load(self):\n"
         "        self.seen = []\n"
         "    def note(self, label):\n"
         "        def callback(param):\n"
         "            self.seen.append((label, list(param.args[:2]), param.args[2]))\n"
         "        return callback\n")


class ActivityResultTests(IntentCase):
    def start(self, scope, multiple=False, code=77):
        Intent = scope.module.Intent
        intent = Intent(Intent.ACTION_GET_CONTENT).setType("*/*").addCategory(Intent.CATEGORY_OPENABLE)
        if multiple:
            intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, True)
        self.context().startActivityForResult(intent, code)

    def test_start_sends_one_closed_request_with_a_one_shot_callback(self):
        scope = self.load(imports=IMPORTS, body=HOOKS)
        with bridge.runtime.context(scope):
            self.assertIsNone(self.start(scope))
            Intent, Uri = scope.module.Intent, scope.module.Uri
            self.context().startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://example.org")))
            self.context().startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).putExtra(Intent.EXTRA_TEXT, "hi"), None), None)
            callbacks = len(scope.callbacks)
            with self.assertRaises(bridge.UnsupportedAPI):
                self.context().startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).setType("a/b"), 1)
            with self.assertRaises(TypeError):
                self.context().startActivity("intent")
            self.assertEqual(len(scope.callbacks), callbacks)
        pick, view, share = self.launches
        self.assertEqual({key: value for key, value in pick.items() if key != "callback"},
                         {"kind": "pick", "types": ["*/*"], "multiple": False, "context": {"$handle": "context", "$class": CONTEXT}})
        self.assertEqual(view, {"kind": "view", "url": "https://example.org", "context": {"$handle": "context", "$class": CONTEXT}})
        self.assertEqual(share, {"kind": "share", "text": "hi", "context": {"$handle": "context", "$class": CONTEXT}})
        self.answer(scope, {"token": "token-1", "result_code": 0, "documents": []}, launch=0)
        with self.assertRaises(bridge.BridgeError) as expired:
            self.answer(scope, {"token": "token-1", "result_code": 0, "documents": []}, launch=0)
        self.assertEqual(expired.exception.code, "CALLBACK_EXPIRED")

    def test_result_runs_the_hooks_in_xposed_order_and_reads_the_document(self):
        scope = self.load(imports=IMPORTS, body=HOOKS)
        plugin = scope.instance
        with bridge.runtime.context(scope):
            context = self.context()
            method = context.getClass().getDeclaredMethod("onActivityResult", scope.module.Integer.TYPE, scope.module.Integer.TYPE, scope.module.Intent)
            self.assertEqual((method.getName(), method.getDeclaringClass().getName()), ("onActivityResult", ACTIVITY))
            low = plugin.hook_method(method, priority=10, before=plugin.note("low before"), after=plugin.note("low after"))
            high = plugin.hook_all_methods(scope.module.find_class(ACTIVITY), "onActivityResult", priority=90,
                                           before=plugin.note("high before"), after=plugin.note("high after"))
            default = plugin.hook_method(method, before=plugin.note("default before"))
            self.assertEqual((type(low).__name__, [type(item).__name__ for item in high], low.getHookedMethod(), default.getCallback().plugin),
                             ("Unhook", ["Unhook"], method, plugin))
            self.start(scope)
        self.answer(scope, self.picked("token-1", self.document("note.txt", b"picked bytes")))
        labels = [label for label, _, _ in plugin.seen]
        # Higher priority first (the default is 50); after hooks in reverse.
        self.assertEqual(labels, ["high before", "default before", "low before", "low after", "high after"])
        self.assertEqual({tuple(codes) for _, codes, _ in plugin.seen}, {(77, -1)})
        data = plugin.seen[0][2]
        with bridge.runtime.context(scope):
            uri = data.getData()
            self.assertEqual(uri.toString(), "content://com.exteragram.messenger.bridge.documents/document/token-1/0/note.txt")
            self.assertEqual((data.getFlags(), data.getClipData(), uri.getAuthority(), uri.getPathSegments()[-1]),
                             (1, None, "com.exteragram.messenger.bridge.documents", "note.txt"))
            resolver = self.context().getContentResolver()
            stream = resolver.openInputStream(uri)
            buffer = bytearray(6)
            self.assertEqual((stream.read(buffer), bytes(buffer), stream.read(), bytes(stream.readAllBytes()), stream.read()),
                             (6, b"picked", 0x20, b"bytes", -1))
            stream.close()
            self.assertEqual(resolver.getType(uri), "text/plain")
            cursor = resolver.query(uri, None, None, None, None)
            self.assertEqual((cursor.getCount(), cursor.moveToFirst(), cursor.getString(cursor.getColumnIndex("_display_name")),
                              cursor.getLong(cursor.getColumnIndex("_size")), cursor.getColumnIndex("absent"), cursor.moveToNext()),
                             (1, True, "note.txt", 12, -1, False))
            projected = resolver.query(uri, ["_size", "owner"], None, None, None)
            projected.moveToFirst()
            self.assertEqual((projected.getColumnNames(), projected.getInt(0), projected.isNull(1)), (["_size", "owner"], 12, True))
            with self.assertRaises(javalib.local_class("android.database.CursorIndexOutOfBoundsException")):
                resolver.query(uri, None, None, None, None).getString(0)
            with self.assertRaises(javalib.local_class("java.lang.SecurityException")):
                resolver.takePersistableUriPermission(uri, 1)
            with self.assertRaises(bridge.UnsupportedAPI):
                resolver.openOutputStream(uri)
            self.assertEqual(resolver.getPersistedUriPermissions(), [])
            # The same URI text parsed again names the same document.
            with resolver.openInputStream(scope.module.Uri.parse(uri.toString())) as again:
                self.assertEqual(bytes(again.readAllBytes()), b"picked bytes")

    def test_a_result_set_before_stops_lower_hooks_and_unhook_removes_one(self):
        scope = self.load(imports=IMPORTS, body=HOOKS)
        plugin = scope.instance
        with bridge.runtime.context(scope):
            activity = scope.module.find_class(ACTIVITY)

            class Consume(scope.module.MethodHook):
                def before_hooked_method(self, param):
                    plugin.seen.append(("consume", list(param.args[:2]), param.thisObject))
                    param.args[1] = 5
                    param.setResult(None)

            first = plugin.hook_all_methods(activity, "onActivityResult", Consume(), 60)
            plugin.hook_all_methods(activity, "onActivityResult", after=plugin.note("skipped"), priority=10)
            plugin.hook_all_methods(activity, "onActivityResult", after=plugin.note("above"), priority=70)
            self.start(scope, code=3)
        self.answer(scope, {"token": "token-1", "result_code": 0, "documents": []})
        # The hook below the one that set a result never runs; the one above sees the changed argument.
        with bridge.runtime.context(scope):
            self.assertEqual(plugin.seen, [("consume", [3, 0], self.context()), ("above", [3, 5], None)])
        plugin.seen.clear()
        with bridge.runtime.context(scope):
            plugin.unhook_method(first[0])
            self.assertEqual(_ayu_xposed.hook_count(_ayu_xposed.ACTIVITY_RESULT), 2)
            self.start(scope, code=4)
        self.answer(scope, {"token": "token-2", "result_code": 0, "documents": [], "error": "SCREEN_UNAVAILABLE"})
        self.assertEqual([label for label, _, _ in plugin.seen], ["skipped", "above"])

    def test_several_documents_arrive_as_clip_data(self):
        scope = self.load(imports=IMPORTS, body=HOOKS)
        plugin = scope.instance
        with bridge.runtime.context(scope):
            plugin.hook_all_methods(scope.module.find_class(ACTIVITY), "onActivityResult", after=plugin.note("after"))
            self.start(scope, multiple=True)
        self.assertTrue(self.launches[0]["multiple"])
        self.answer(scope, self.picked("token-1", self.document("a.mp3", b"one", "audio/mpeg"), self.document("b.txt", b"second")))
        data = plugin.seen[0][2]
        with bridge.runtime.context(scope):
            clip = data.getClipData()
            self.assertEqual((data.getData(), clip.getItemCount(), clip.getDescription().getMimeTypeCount()), (None, 2, 2))
            resolver = self.context().getContentResolver()
            read = []
            for index in range(2):
                with resolver.openInputStream(clip.getItemAt(index).getUri()) as stream:
                    read.append(bytes(stream.readAllBytes()))
            self.assertEqual(read, [b"one", b"second"])

    def test_replacement_filters_and_failures(self):
        scope = self.load(imports=IMPORTS, body=HOOKS)
        plugin = scope.instance
        with bridge.runtime.context(scope):
            module = scope.module
            activity = module.find_class(ACTIVITY)

            class Replace(module.MethodReplacement):
                def replace_hooked_method(self, param):
                    plugin.seen.append(("replace", list(param.args[:2]), param.method.getName()))
                    return "replaced"

            class Filtered(module.MethodHook):
                @module.hook_filters(module.HookFilter.ArgumentEqual(0, 8), module.HookFilter.ArgumentIsNull(2))
                def before_hooked_method(self, param):
                    plugin.seen.append(("filtered", list(param.args[:2]), None))
                    raise RuntimeError("synthetic")

                @module.hook_filters(module.HookFilter.RESULT_NOT_NULL)
                def after_hooked_method(self, param):
                    plugin.seen.append(("result", list(param.args[:2]), param.getResult()))

            plugin.hook_all_methods(activity, "onActivityResult", Filtered(), 80)
            plugin.hook_all_methods(activity, "onActivityResult", Replace(), 20)
            with self.assertRaises(bridge.UnsupportedAPI):
                plugin.hook_all_methods(activity, "onActivityResult", before=plugin.note("x"),
                                        before_filters=[module.HookFilter.Condition("param != null")])
            with self.assertRaises(TypeError):
                plugin.hook_all_methods(activity, "onActivityResult")
            # Android logs an object that is no hook and returns None.
            self.assertIsNone(plugin.hook_all_methods(activity, "onActivityResult", object()))
            self.start(scope, code=8)
            self.start(scope, code=9)
        self.answer(scope, {"token": "token-1", "result_code": 0, "documents": []}, launch=0)
        self.assertEqual(plugin.seen, [("filtered", [8, 0], None), ("replace", [8, 0], "onActivityResult"), ("result", [8, 0], "replaced")])
        plugin.seen.clear()
        self.answer(scope, {"token": "token-2", "result_code": 0, "documents": []}, launch=1)
        self.assertEqual([label for label, _, _ in plugin.seen], ["replace", "result"])

    def test_naming_the_target_and_everything_else_needs_java_method(self):
        scope = self.load(imports=IMPORTS, body=HOOKS)
        plugin = scope.instance
        with bridge.runtime.context(scope):
            module = scope.module
            activity = module.find_class(ACTIVITY)
            mirror = activity.getClass()
            found = [method for method in mirror.getDeclaredMethods() if method.getName() == "onActivityResult"]
            handle = self.context().getClass()
            listed = [method for method in handle.getDeclaredMethods() if method.getName() == "onActivityResult"]
            self.assertEqual((len(found), found, mirror.getDeclaredMethod("onActivityResult", module.Integer.TYPE, module.Integer.TYPE, module.Intent)),
                             (1, listed, found[0]))
            self.assertEqual(type(plugin.hook_method(found[0], after=plugin.note("after"))).__name__, "Unhook")
            with self.assertRaises(javalib.local_class("java.lang.NoSuchMethodException")):
                mirror.getDeclaredMethod("onResume")
            # The class handle keeps the host's own answer for a name no point serves.
            with self.assertRaises(bridge.BridgeError):
                handle.getDeclaredMethod("onResume")
            with self.assertRaises(bridge.MissingMember):
                self.context().getDeclaredMethod("onActivityResult")
            # Any other target goes the way it always went: to the host's ``hooks.register``, which has no such kind.
            with self.assertRaises(bridge.UnsupportedAPI):
                plugin.hook_all_methods(activity, "onResume", after=plugin.note("after"))
            before = len(self.host.requests)
            plugin.hook_all_methods(module.find_class("example.Native"), "onActivityResult", after=plugin.note("after"))
            self.assertEqual([item["arguments"]["kind"] for item in self.host.requests[before:] if item["operation"] == "hooks.register"],
                             ["java_all_methods"])
            self.assertEqual(_ayu_xposed.hook_count(_ayu_xposed.ACTIVITY_RESULT), 1)
            # A direct call of the method runs the plugin's hooks on it; nothing else is behind the point.
            activity.onActivityResult(self.context(), 1, 0, None)
            self.assertEqual(plugin.seen, [("after", [1, 0], None)])

    def test_invalid_host_results_are_protocol_errors(self):
        scope = self.load(imports=IMPORTS, body=HOOKS)
        with bridge.runtime.context(scope):
            for _ in range(4):
                self.start(scope)
        document = self.document("a.txt", b"a")
        for index, wire in enumerate(({"token": "token-1", "result_code": -1, "documents": []},
                                      {"token": "token-1", "result_code": 0, "documents": [document]},
                                      self.picked("token-1", dict(document, path="relative.txt")),
                                      self.picked("token/1", document))):
            with self.subTest(wire=wire), self.assertRaises(bridge.BridgeError) as raised:
                self.answer(scope, wire, launch=index)
            self.assertEqual(raised.exception.code, "PROTOCOL_ERROR")


class PackageManagerTests(IntentCase):
    def test_only_the_emulated_client_is_installed(self):
        scope = self.load(imports=IMPORTS + "from android.content.pm import PackageManager\n")
        with bridge.runtime.context(scope):
            Intent = scope.module.Intent
            manager = self.context().getPackageManager()
            self.assertIsInstance(manager, scope.module.PackageManager)
            info = manager.getPackageInfo("com.exteragram.messenger", 0)
            self.assertEqual((info.packageName, info.versionName, info.versionCode, info.getLongVersionCode()),
                             ("com.exteragram.messenger", "13.2.2", 73035, 73035))
            with self.assertRaises(scope.module.PackageManager.NameNotFoundException) as missing:
                manager.getPackageInfo("org.telegram.messenger", 0)
            self.assertEqual(missing.exception.getMessage(), "org.telegram.messenger")
            self.assertIsNone(manager.getLaunchIntentForPackage("com.whatsapp"))
            launch = manager.getLaunchIntentForPackage("com.exteragram.messenger")
            self.assertEqual(launch.toString(), "Intent { act=android.intent.action.MAIN cat=[android.intent.category.LAUNCHER] "
                                                "flg=0x10000000 pkg=com.exteragram.messenger cmp=com.exteragram.messenger/org.telegram.ui.LaunchActivity }")
            # Nothing can launch a component; a link or a picker resolves to the client itself.
            self.assertIsNone(launch.resolveActivity(manager))
            self.assertIsNone(Intent(Intent.ACTION_VIEW, scope.module.Uri.parse("market://a")).resolveActivity(manager))
            self.assertEqual(Intent(Intent.ACTION_VIEW, scope.module.Uri.parse("https://a.b")).resolveActivity(manager).getClassName(), ACTIVITY)
            self.assertEqual(Intent(Intent.ACTION_GET_CONTENT).setType("*/*").resolveActivity(manager).getPackageName(), "com.exteragram.messenger")
            with self.assertRaises(bridge.UnsupportedAPI):
                manager.getApplicationLabel(None)


class PreflightTests(IntentCase):
    HOOK = ("    def on_plugin_load(self):\n"
            "        activity = self.activity()\n"
            "        method = activity.getClass().getDeclaredMethod('onActivityResult', Integer.TYPE, Integer.TYPE, Intent)\n"
            "        self.hook_method(method, after=self.done)\n"
            "        self.hook_all_methods(find_class('org.telegram.ui.LaunchActivity'), 'onActivityResult', after=self.done)\n"
            "        for item in find_class('org.telegram.ui.LaunchActivity').getClass().getDeclaredMethods():\n"
            "            if item.getName() == 'onActivityResult' and True:\n"
            "                self.hook_method(item, after=self.done)\n")

    def operation_blockers(self, body):
        return self.blockers(IMPORTS, body, "OPERATION")

    def test_mapped_targets_pass_and_need_the_points_operation(self):
        self.assertEqual(self.operation_blockers(self.HOOK), [])
        self.operations(remove=[_ayu_intents.OPERATION])
        self.assertEqual(self.operation_blockers(self.HOOK), [
            "intents.launch (hook_all_methods(): org.telegram.ui.LaunchActivity.onActivityResult)",
            "intents.launch (hook_method(): org.telegram.ui.LaunchActivity.onActivityResult)"])

    def test_every_other_target_stays_java_method(self):
        cases = {
            "        self.hook_all_methods(find_class('org.telegram.ui.LaunchActivity'), 'onResume', after=self.done)\n": "hook_all_methods()",
            "        self.hook_all_methods(find_class('org.telegram.ui.ChatActivity'), 'onActivityResult', after=self.done)\n": "hook_all_methods()",
            "        self.hook_all_methods(find_class('org.telegram.ui.LaunchActivity'), self.name, after=self.done)\n": "hook_all_methods()",
            "        self.hook_method(self.find(), after=self.done)\n": "hook_method()",
            "        for item in find_class('org.telegram.ui.LaunchActivity').getClass().getDeclaredMethods():\n"
            "            if item.getName() == 'onActivityResult' or item.getName() == 'onResume':\n"
            "                self.hook_method(item, after=self.done)\n": "hook_method()",
            "        self.hook_all_constructors(find_class('org.telegram.ui.LaunchActivity'), after=self.done)\n": "hook_all_constructors()",
        }
        for body, api in cases.items():
            with self.subTest(body=body):
                self.assertEqual(self.operation_blockers(self.HOOK + body), [f"hooks.java_method ({api})"] if api != "hook_all_constructors()" else
                                 ["hooks.java_method (hook_all_constructors())"])

    def test_one_unresolved_call_keeps_the_blocker_for_its_api_only(self):
        body = self.HOOK + "        self.hook_method(self.find(), after=self.done)\n"
        self.assertEqual(self.operation_blockers(body), ["hooks.java_method (hook_method())"])

    def test_android_only_actions_are_blocked_by_name(self):
        body = ("    def on_plugin_load(self):\n"
                "        Intent(Intent.ACTION_CREATE_DOCUMENT)\n"
                "        Intent().setAction('android.settings.action.MANAGE_OVERLAY_PERMISSION')\n"
                "        Intent(Intent.ACTION_GET_CONTENT)\n"
                "        text = Intent.ACTION_OPEN_DOCUMENT_TREE\n")
        self.assertEqual(self.operation_blockers(body), [
            "intents.android_only (Intent android.intent.action.CREATE_DOCUMENT)",
            "intents.android_only (Intent android.settings.action.MANAGE_OVERLAY_PERMISSION)"])

    def test_members_of_the_family_are_checked(self):
        body = ("    def on_plugin_load(self):\n"
                "        context = ApplicationLoader.applicationContext\n"
                "        intent = Intent(Intent.ACTION_SEND).setType('text/plain').putExtra(Intent.EXTRA_TEXT, 'a')\n"
                "        context.startActivity(Intent.createChooser(intent, 'Share'))\n"
                "        context.startActivityForResult(intent, 1)\n"
                "        context.getContentResolver().openInputStream(None)\n"
                "        context.getContentResolver().delete(None, None, None)\n"
                "        context.getPackageManager().getPackageInfo('a', 0).versionName\n"
                "        context.getPackageManager().getInstalledPackages(0)\n"
                "        intent.getSelector()\n")
        self.declare("org.telegram.messenger.ApplicationLoader", {"applicationContext": {"$handle": "context", "$class": CONTEXT}},
                     entry(static_fields=["applicationContext"], results={"applicationContext": CONTEXT}))
        self.assertEqual(self.blockers(IMPORTS + "from org.telegram.messenger import ApplicationLoader\n", body), [
            ("MEMBER", "android.content.ContentResolver.delete"), ("MEMBER", "android.content.Intent.getSelector"),
            ("MEMBER", "android.content.pm.PackageManager.getInstalledPackages")])


if __name__ == "__main__":
    unittest.main()
