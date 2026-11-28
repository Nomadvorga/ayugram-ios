"""Wave 5 intents: ``ACTION_VIEW`` of a shareable file, and Android-only targets named by preflight."""
from __future__ import annotations

import os
import unittest

from pymembers_fixtures import CONTEXT, entry
from test_intents_launch import IMPORTS, IntentCase
import _ayu_intents
import _ayu_javalib as javalib
import ayu_bridge as bridge

LOADER = "org.telegram.messenger.ApplicationLoader"
MORE = "from androidx.core.content import FileProvider\nfrom java.io import File\nfrom android.content import ComponentName\n"


class ViewFileTests(IntentCase):
    def setUp(self):
        super().setUp()
        self.scope = self.load(imports=IMPORTS + MORE)

    def shared(self, name="export/report 1.pdf"):
        module = self.scope.module
        file = module.File(self.context().getFilesDir(), name)
        os.makedirs(file.getParentFile().getPath(), exist_ok=True)
        with open(file.getPath(), "wb") as stream:
            stream.write(b"%PDF")
        return file

    def test_a_file_of_the_plugin_storage_opens_through_the_sheet(self):
        with bridge.runtime.context(self.scope):
            module = self.scope.module
            Intent, Uri, FileProvider = module.Intent, module.Uri, module.FileProvider
            context = self.context()
            file = self.shared()
            uri = FileProvider.getUriForFile(context, context.getPackageName() + ".provider", file)
            expected = {"kind": "share", "files": [os.path.realpath(file.getPath())]}
            view = (Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/pdf")
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_ACTIVITY_NEW_TASK))
            self.assertEqual(_ayu_intents.plan(view, False), expected)
            self.assertEqual(_ayu_intents.plan(Intent.createChooser(view, "Open with"), False), expected)
            self.assertEqual(_ayu_intents.plan(Intent(Intent.ACTION_VIEW, Uri.fromFile(file)), False), expected)
            self.assertTrue(_ayu_intents.can_launch(view))

    def test_start_sends_the_share_request_without_a_callback(self):
        with bridge.runtime.context(self.scope):
            module = self.scope.module
            Intent, FileProvider = module.Intent, module.FileProvider
            context = self.context()
            file = self.shared("a.txt")
            uri = FileProvider.getUriForFile(context, context.getPackageName() + ".provider", file)
            context.startActivity(Intent(Intent.ACTION_VIEW).setDataAndType(uri, "text/plain"))
        self.assertEqual(len(self.launches), 1)
        request = self.launches[0]
        self.assertEqual(set(request), {"kind", "files", "context"})
        self.assertEqual((request["kind"], request["files"]), ("share", [os.path.realpath(file.getPath())]))

    def test_files_the_bridge_may_not_share_and_typed_links_stay_refused(self):
        with bridge.runtime.context(self.scope):
            module = self.scope.module
            Intent, Uri, File = module.Intent, module.Uri, module.File
            outside = File(self.home, "outside.txt")
            open(outside.getPath(), "wb").close()
            cases = {
                "The data URI names a file outside the plugin storage": Intent(Intent.ACTION_VIEW, Uri.fromFile(outside)),
                "The data URI names a file outside the plugin storage ": Intent(Intent.ACTION_VIEW).setDataAndType(
                    Uri.parse("content://media/external/images/1"), "image/*"),
                "Intent android.intent.action.VIEW of a file": Intent(Intent.ACTION_VIEW).setDataAndType(
                    Uri.parse("https://a.b/c.pdf"), "application/pdf"),
                "with the extra android.intent.extra.TEXT": Intent(Intent.ACTION_VIEW, Uri.fromFile(self.shared()))
                .putExtra(Intent.EXTRA_TEXT, "a"),
            }
            for expected, intent in cases.items():
                with self.subTest(expected=expected):
                    with self.assertRaises(bridge.UnsupportedAPI) as refused:
                        _ayu_intents.plan(intent, False)
                    self.assertIn(expected.strip(), refused.exception.message)
                    self.assertFalse(_ayu_intents.can_launch(intent))
            missing = Intent(Intent.ACTION_VIEW, Uri.fromFile(File(self.context().getFilesDir(), "gone.txt")))
            with self.assertRaises(javalib.local_class("java.io.FileNotFoundException")):
                _ayu_intents.plan(missing, False)
            with self.assertRaises(bridge.UnsupportedAPI) as refused:
                _ayu_intents.plan(Intent(Intent.ACTION_VIEW, Uri.fromFile(self.shared())), True)
            self.assertIn("cannot be started for a result", refused.exception.message)


class AndroidOnlyPreflightTests(IntentCase):
    def operation_blockers(self, body):
        self.declare(LOADER, {"applicationContext": {"$handle": "context", "$class": CONTEXT}},
                     entry(static_fields=["applicationContext"], results={"applicationContext": CONTEXT}))
        return self.blockers(IMPORTS + MORE + "from org.telegram.messenger import ApplicationLoader\n", body, "OPERATION")

    def test_served_shapes_are_not_blockers(self):
        body = ("    def on_plugin_load(self):\n"
                "        context = ApplicationLoader.applicationContext\n"
                "        send = Intent(Intent.ACTION_SEND).setType('text/plain').putExtra(Intent.EXTRA_TEXT, 'a')\n"
                "        context.startActivity(Intent.createChooser(send, 'Share'))\n"
                "        view = Intent(Intent.ACTION_VIEW, Uri.parse('tg://resolve?domain=a'))\n"
                "        view.setPackage(context.getPackageName())\n"
                "        view.setPackage('com.exteragram.messenger')\n"
                "        context.startActivity(view)\n"
                "        pick = Intent(Intent.ACTION_OPEN_DOCUMENT).setType('*/*').addCategory(Intent.CATEGORY_OPENABLE)\n"
                "        context.startActivityForResult(pick, 3)\n")
        self.assertEqual(self.blockers(IMPORTS + MORE, body), [])
        self.assertEqual(self.operation_blockers(body), [])

    def test_other_applications_and_settings_screens_are_named(self):
        body = ("    def on_plugin_load(self):\n"
                "        Intent(Intent.ACTION_VIEW, Uri.parse('https://a.b')).setPackage('com.android.chrome')\n"
                "        Intent().setClassName('com.termux', 'com.termux.app.RunCommandService')\n"
                "        Intent().setComponent(ComponentName('org.other', 'org.other.Main'))\n"
                "        Intent(self.Settings.ACTION_MANAGE_OVERLAY_PERMISSION)\n"
                "        Intent('android.settings.SETTINGS')\n")
        self.assertEqual(self.operation_blockers(body), [
            "intents.android_only (Intent Settings.ACTION_MANAGE_OVERLAY_PERMISSION)",
            "intents.android_only (Intent android.settings.SETTINGS)",
            "intents.android_only (Intent component of the package com.termux)",
            "intents.android_only (Intent component of the package org.other)",
            "intents.android_only (Intent package com.android.chrome)"])

    def test_static_actions_reads_only_literals(self):
        import ast
        tree = ast.parse("i.setPackage(name)\ni.setPackage('com.exteragram.messenger')\nComponentName(ctx.getPackageName(), 'a.B')\n"
                         "Intent(Other.ACTION_MANAGE_OVERLAY_PERMISSION)\ncfg.setClassName('a')\n")
        self.assertEqual(_ayu_intents.static_actions(tree), [])


if __name__ == "__main__":
    unittest.main()
