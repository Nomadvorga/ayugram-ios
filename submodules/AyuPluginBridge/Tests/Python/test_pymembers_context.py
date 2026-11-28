"""``android.content.Context`` members the SDK serves on the host's context: storage, identity, preferences.

The host is synthetic, the application container is a temporary ``HOME`` and plugin sources are test-authored.
"""
from __future__ import annotations

import gc
import json
import os
import unittest
from unittest.mock import patch

from pymembers_fixtures import CONTEXT, LOADER, HostCase, entry
import ayu_bridge as bridge
import file_utils
from _ayu_javalib import android_compose, java_io, java_lang, java_util

STORAGE = ("Library", "Application Support", "AyuPluginFiles")
CACHE = ("Library", "Caches", "AyuPluginFiles")


class ContextCase(HostCase):
    def setUp(self):
        HostCase.setUp(self)
        self.declare(CONTEXT)

    def context(self):
        return self.reference(CONTEXT, "context")

    def path(self, *parts):
        return os.path.join(self.home, *parts)


class DirectoryTests(ContextCase):
    def test_directories_are_real_and_laid_out_like_android(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            context = self.context()
            expected = {
                "getFilesDir": ((), self.path(*STORAGE)),
                "getCacheDir": ((), self.path(*CACHE)),
                "getCodeCacheDir": ((), self.path(*CACHE, "code_cache")),
                "getExternalCacheDir": ((), self.path(*CACHE, "external")),
                "getExternalFilesDir": ((None,), self.path(*STORAGE, "external")),
                "getDir": (("database", 0), self.path(*STORAGE, "app_database")),
            }
            for name, (arguments, path) in expected.items():
                with self.subTest(name):
                    found = getattr(context, name)(*arguments)
                    self.assertIs(type(found), java_io.File)
                    self.assertEqual(found.getAbsolutePath(), path)
                    self.assertTrue(found.isDirectory())
            self.assertEqual(context.getExternalFilesDir("Download").getAbsolutePath(), self.path(*STORAGE, "external", "Download"))
            self.assertEqual([item.getAbsolutePath() for item in context.getExternalFilesDirs(None)],
                             [self.path(*STORAGE, "external")])
            # Android keeps plugin files in ``plugins`` below the files directory.
            self.assertEqual(java_io.File(context.getFilesDir(), "plugins").getAbsolutePath(), file_utils.get_plugins_dir())
            self.assertEqual(context.getCacheDir().getAbsolutePath(), file_utils.get_cache_dir())
            # The SDK answers; the host is never asked for these members.
            self.assertEqual(self.host_requests(), [])

    def test_arguments_are_checked_like_android(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            context = self.context()
            for name, arguments in (("getFilesDir", (1,)), ("getCacheDir", ("a",)), ("getExternalFilesDir", ()),
                                    ("getDir", ("name",)), ("getDir", (1, 0)), ("getPackageName", (1,)),
                                    ("getSharedPreferences", ("name",)), ("getSharedPreferences", (1, 0))):
                with self.subTest(name=name, arguments=arguments), self.assertRaises(TypeError):
                    getattr(context, name)(*arguments)
            with self.assertRaises(java_lang.IllegalArgumentException) as caught:
                context.getDir("a/b", 0)
            self.assertEqual(caught.exception.getMessage(), "File app_a/b contains a path separator")
            for arguments in (("name", 1), ("", 0), ("x" * 200, 0)):
                with self.subTest(arguments=arguments), self.assertRaises(bridge.UnsupportedAPI):
                    context.getDir(*arguments)
            for kind in ("/absolute", "../up", "a/../../b", "", 7):
                with self.subTest(kind=kind), self.assertRaises(bridge.UnsupportedAPI):
                    context.getExternalFilesDir(kind)
            self.assertFalse(os.path.exists(self.path("Library", "up")))

    def test_without_an_application_container_the_directories_are_unsupported(self):
        scope = self.load()
        with bridge.runtime.context(scope), patch.dict(os.environ, {"HOME": "relative"}):
            for name in ("getFilesDir", "getCacheDir", "getExternalCacheDir"):
                with self.subTest(name), self.assertRaises(bridge.UnsupportedAPI):
                    getattr(self.context(), name)()

    def test_members_need_a_plugin_scope(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            context = self.context()
        with self.assertRaises(bridge.BridgeError) as caught:
            context.getFilesDir
        self.assertEqual(caught.exception.code, "NO_PLUGIN_CONTEXT")


class IdentityTests(ContextCase):
    def test_package_name_is_the_emulated_application(self):
        self.declare(LOADER)
        scope = self.load(imports="from org.telegram.messenger import ApplicationLoader\n")
        with bridge.runtime.context(scope):
            self.assertEqual(self.context().getPackageName(), "com.exteragram.messenger")
            self.assertEqual(scope.module.ApplicationLoader.getApplicationId(), "com.exteragram.messenger")
            with self.assertRaises(TypeError):
                scope.module.ApplicationLoader.getApplicationId(1)

    def test_application_context_is_the_context_itself(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            context = self.context()
            application = context.getApplicationContext()
            self.assertIsInstance(application, bridge.RemoteObject)
            self.assertEqual((application._handle, application._class_name), ("context", CONTEXT))
            self.assertEqual(application.getApplicationContext().getPackageName(), "com.exteragram.messenger")

    def test_class_loader_resolves_names_through_the_bridge(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            loader = self.context().getClassLoader()
            self.assertIsInstance(loader, java_lang.ClassLoader)
            self.assertIs(loader, self.context().getClassLoader())
            self.assertEqual(loader.loadClass("java.io.File").getName(), "java.io.File")
            self.assertEqual(loader.loadClass("example.Native").getName(), "example.Native")
            for name in ("dalvik.system.InMemoryDexClassLoader", "org.telegram.Missing"):
                with self.subTest(name), self.assertRaises(java_lang.ClassNotFoundException):
                    loader.loadClass(name)
            # A DEX loader would take it as its parent: a local object never reaches the host.
            with self.assertRaises(bridge.UnsupportedAPI):
                bridge.runtime.jclass("example.Native").echo(loader)

    def test_host_that_declares_a_member_answers_it_itself(self):
        self.declare(CONTEXT, {"getPackageName": lambda target, args: "host.package"},
                     entry(methods=["getClass", "getPackageName"]))
        scope = self.load()
        with bridge.runtime.context(scope):
            context = self.context()
            self.assertEqual(context.getPackageName(), "host.package")
            self.assertEqual(self.host_requests(), [(CONTEXT, "getPackageName")])
            self.assertIs(type(context.getFilesDir()), java_io.File)


class Recorder:
    def __init__(self):
        self.seen = []

    def onSharedPreferenceChanged(self, preferences, key):
        self.seen.append((preferences, key))


class SharedPreferencesTests(ContextCase):
    def preferences(self, name="state"):
        return self.context().getSharedPreferences(name, 0)

    def test_values_keep_their_java_type(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            preferences = self.preferences()
            self.assertIsInstance(preferences, android_compose.SharedPreferences)
            self.assertIs(preferences, self.preferences())
            self.assertIsNot(preferences, self.preferences("other"))
            editor = preferences.edit()
            self.assertIsNot(editor, preferences.edit())
            chained = (editor.putString("text", "value").putInt("int", -7).putLong("long", 2 ** 40).putFloat("float", 0.1)
                       .putBoolean("flag", True).putStringSet("set", ["b", "a", "b"]))
            self.assertIs(chained, editor)
            # Nothing is visible before commit or apply.
            self.assertFalse(preferences.contains("text"))
            self.assertIs(editor.commit(), True)
            self.assertEqual((preferences.getString("text", None), preferences.getInt("int", 0), preferences.getLong("long", 0),
                              preferences.getBoolean("flag", False)), ("value", -7, 2 ** 40, True))
            self.assertEqual(preferences.getFloat("float", 0.0), java_lang.to_float32(0.1))
            found = preferences.getStringSet("set", None)
            self.assertIsInstance(found, java_util.HashSet)
            self.assertEqual(sorted(found), ["a", "b"])
            self.assertEqual((preferences.getString("absent", "fallback"), preferences.getInt("absent", 5),
                              preferences.getStringSet("absent", None)), ("fallback", 5, None))
            everything = preferences.getAll()
            self.assertIsInstance(everything, java_util.HashMap)
            self.assertEqual(sorted(everything.keySet()), ["flag", "float", "int", "long", "set", "text"])
            for getter, key in (("getInt", "long"), ("getLong", "int"), ("getString", "int"), ("getBoolean", "text"),
                                ("getFloat", "int"), ("getStringSet", "text")):
                with self.subTest(getter=getter, key=key), self.assertRaises(java_lang.ClassCastException):
                    getattr(preferences, getter)(key, None)
            with self.assertRaises(java_lang.ClassCastException) as caught:
                preferences.getInt("long", 0)
            self.assertEqual(caught.exception.getMessage(), "java.lang.Long cannot be cast to java.lang.Integer")

    def test_editor_rejects_values_java_would_not_take(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            editor = self.preferences().edit()
            for method, value in (("putInt", 2 ** 31), ("putInt", True), ("putInt", 1.5), ("putLong", 2 ** 63),
                                  ("putFloat", "1"), ("putBoolean", 1), ("putString", 5)):
                with self.subTest(method=method, value=value), self.assertRaises(TypeError):
                    getattr(editor, method)("key", value)
            with self.assertRaises(TypeError):
                editor.putString(None, "value")
            with self.assertRaises(bridge.UnsupportedAPI):
                android_compose.SharedPreferences()

    def test_commit_applies_clear_first_and_removals(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            preferences = self.preferences()
            preferences.edit().putString("old", "1").putString("kept", "2").apply()
            # Android clears before it applies the edits, whatever order they were made in.
            preferences.edit().putString("new", "3").clear().putString("kept", "4").apply()
            self.assertEqual(sorted(preferences.getAll().keySet()), ["kept", "new"])
            self.assertEqual(preferences.getString("kept", None), "4")
            preferences.edit().putString("new", None).remove("kept").remove("never").putStringSet("set", None).apply()
            self.assertEqual(len(preferences.getAll()), 0)
            self.assertIsNone(preferences.edit().putInt("a", 1).apply())
            editor = preferences.edit().putInt("b", 2)
            editor.apply()
            # A committed editor starts empty again.
            preferences.edit().remove("b").apply()
            editor.apply()
            self.assertFalse(preferences.contains("b"))

    def test_values_persist_per_plugin_and_name(self):
        scope = self.load("first")
        with bridge.runtime.context(scope):
            self.preferences().edit().putString("owner", "first").putStringSet("tags", {"x"}).putFloat("ratio", float("inf")).commit()
            self.preferences("other name/..".replace("/", "_")).edit().putInt("n", 1).commit()
        stored = self.path(*STORAGE, "shared_prefs", "first")
        self.assertEqual(sorted(os.listdir(stored)), ["other%20name_...json", "state.json"])
        with open(os.path.join(stored, "state.json"), encoding="utf-8") as stream:
            self.assertEqual(json.load(stream)["values"]["owner"], ["string", "first"])
        bridge.unload_plugin("first")
        scope = self.load("first")
        with bridge.runtime.context(scope):
            preferences = self.preferences()
            self.assertEqual((preferences.getString("owner", None), sorted(preferences.getStringSet("tags", None)),
                              preferences.getFloat("ratio", 0.0)), ("first", ["x"], float("inf")))
            self.assertFalse(self.preferences("other").contains("owner"))
        other = self.load("second")
        with bridge.runtime.context(other):
            # Another plugin opening the same name reads its own file, never this one.
            self.assertEqual(len(self.preferences().getAll()), 0)
            self.preferences().edit().putString("owner", "second").apply()
        with bridge.runtime.context(scope):
            self.assertEqual(self.preferences().getString("owner", None), "first")

    def test_damaged_file_reads_as_empty(self):
        directory = self.path(*STORAGE, "shared_prefs", "sample")
        os.makedirs(directory)
        for text in ("not json", '{"version": 2, "values": {"a": ["int", 1]}}', '{"version": 1, "values": {"a": ["int", "1"]}}',
                     '{"version": 1, "values": {"a": ["float", "x"]}}', '{"version": 1, "values": {"a": ["date", 1]}}', "[]"):
            with self.subTest(text):
                with open(os.path.join(directory, "state.json"), "w", encoding="utf-8") as stream:
                    stream.write(text)
                scope = self.load()
                with bridge.runtime.context(scope):
                    self.assertEqual(len(self.preferences().getAll()), 0)
                bridge.unload_plugin("sample")

    def test_names_are_checked_and_application_files_are_refused(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            with self.assertRaises(java_lang.IllegalArgumentException) as caught:
                self.preferences("a/b")
            self.assertEqual(caught.exception.getMessage(), "File a/b.xml contains a path separator")
            for name in ("mainconfig", "mainconfig3", "userconfing", "userconfig0", "Notifications2", "plugin_settings",
                         "media_saved_pos", "recent_reactions_1", "emoji"):
                with self.subTest(name), self.assertRaises(bridge.UnsupportedAPI):
                    self.preferences(name)
            for arguments in (("", 0), ("x" * 129, 0), ("name", 1), ("name", 2)):
                with self.subTest(arguments=arguments), self.assertRaises(bridge.UnsupportedAPI):
                    self.context().getSharedPreferences(*arguments)
            # A plugin's own names are its own, also when they resemble the application's.
            for name in ("mainconfig_backup", "my_plugin", "emoji_cache"):
                self.assertEqual(len(self.context().getSharedPreferences(name, 4).getAll()), 0)
            self.assertFalse(os.path.exists(self.path(*STORAGE, "shared_prefs", "sample", "mainconfig.json")))

    def test_listeners_hear_changes_and_are_held_weakly(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            preferences = self.preferences()
            recorder, calls = Recorder(), []

            def function(changed, key):
                calls.append(key)

            with self.assertRaises(java_lang.NullPointerException):
                preferences.registerOnSharedPreferenceChangeListener(None)
            preferences.registerOnSharedPreferenceChangeListener(recorder)
            preferences.registerOnSharedPreferenceChangeListener(recorder)
            preferences.registerOnSharedPreferenceChangeListener(function)
            preferences.edit().putString("a", "1").putInt("b", 2).apply()
            # Android reports the changed keys last to first, once per listener.
            self.assertEqual(recorder.seen, [(preferences, "b"), (preferences, "a")])
            self.assertEqual(calls, ["b", "a"])
            del recorder.seen[:], calls[:]
            # An unchanged value and the removal of an absent key change nothing.
            preferences.edit().putString("a", "1").remove("absent").commit()
            self.assertEqual((recorder.seen, calls), ([], []))
            # A clear is reported as a null key first; keys it removed are not reported one by one.
            preferences.edit().clear().putString("c", "3").apply()
            self.assertEqual(calls, [None, "c"])
            preferences.unregisterOnSharedPreferenceChangeListener(function)
            del recorder.seen[:], calls[:]
            preferences.edit().putString("c", "4").apply()
            self.assertEqual((len(recorder.seen), calls), (1, []))
            del recorder
            gc.collect()
            preferences.registerOnSharedPreferenceChangeListener(lambda changed, key: calls.append(key))
            gc.collect()
            preferences.edit().putString("c", "5").apply()
            self.assertEqual(calls, [])

            class Owner:
                def changed(self, source, key):
                    calls.append(key)

            owner = Owner()
            preferences.registerOnSharedPreferenceChangeListener(owner.changed)
            preferences.registerOnSharedPreferenceChangeListener(owner.changed)
            preferences.edit().putString("c", "6").apply()
            self.assertEqual(calls, ["c"])
            preferences.unregisterOnSharedPreferenceChangeListener(owner.changed)
            preferences.edit().putString("c", "7").apply()
            self.assertEqual(calls, ["c"])

    def test_failed_write_is_reported_by_commit_and_kept_in_memory(self):
        scope = self.load()
        with bridge.runtime.context(scope):
            preferences = self.preferences()
            with patch.object(os, "replace", side_effect=OSError("synthetic")):
                self.assertIs(preferences.edit().putString("a", "1").commit(), False)
                self.assertIsNone(preferences.edit().putString("b", "2").apply())
            self.assertEqual((preferences.getString("a", None), preferences.getString("b", None)), ("1", "2"))
            self.assertIs(preferences.edit().putString("huge", "x" * (1024 * 1024)).commit(), False)
            # Committing nothing writes nothing and succeeds.
            with patch.object(os, "replace", side_effect=OSError("synthetic")):
                self.assertIs(preferences.edit().putString("a", "1").commit(), True)


class PreflightTests(ContextCase):
    IMPORTS = "from org.telegram.messenger import ApplicationLoader\nfrom android.content import Context\n"

    def setUp(self):
        ContextCase.setUp(self)
        self.declare_application()

    def test_served_members_are_provided_and_their_results_are_checked(self):
        body = ("    def on_plugin_load(self):\n"
                "        context = ApplicationLoader.applicationContext\n"
                "        base = context.getFilesDir().getAbsolutePath()\n"
                "        context.getCacheDir().mkdirs()\n"
                "        context.getApplicationContext().getExternalFilesDir(None).exists()\n"
                "        preferences = context.getSharedPreferences('state', Context.MODE_PRIVATE)\n"
                "        preferences.edit().putString('a', 'b').putInt('c', 1).apply()\n"
                "        preferences.getBoolean('d', False)\n"
                "        context.getClassLoader().loadClass(context.getPackageName())\n"
                "        ApplicationLoader.getFilesDirFixed().getAbsolutePath()\n")
        report = self.preflight(self.IMPORTS, body)
        self.assertEqual(report["blockers"], [])
        self.assertEqual((report["member_accesses"]["missing_accesses"], report["member_accesses"]["unknown"]), (0, 0))

    def test_members_nothing_provides_stay_blockers(self):
        body = ("    def on_plugin_load(self):\n"
                "        context = ApplicationLoader.applicationContext\n"
                "        context.getContentResolver().insert(None, None)\n"
                "        context.getFilesDir().vanished()\n"
                "        context.getSharedPreferences('state', 0).edit().putDouble('a', 1.0)\n"
                "        context.getSharedPreferences('state', 0).getDouble('a', 1.0)\n"
                "        context.getClassLoader().defineClass('x')\n"
                "        context.getNoBackupFilesDir()\n"
                "        context.MODE_PRIVATE = 1\n")
        self.assertEqual(self.blockers(self.IMPORTS, body, "MEMBER"), [
            "android.content.ContentResolver.insert", "android.content.Context.MODE_PRIVATE (write)",
            "android.content.Context.getNoBackupFilesDir", "android.content.SharedPreferences$Editor.putDouble",
            "android.content.SharedPreferences.getDouble", "java.io.File.vanished", "java.lang.ClassLoader.defineClass"])

    def test_files_dir_is_no_longer_a_curated_unprovided_member(self):
        import _ayu_operations
        self.assertNotIn("getFilesDir", _ayu_operations.UNPROVIDED_MEMBERS)
        body = "    def on_plugin_load(self):\n        self.activity.getFilesDir()\n"
        self.assertEqual(self.blockers(self.IMPORTS, body), [])


if __name__ == "__main__":
    unittest.main()
