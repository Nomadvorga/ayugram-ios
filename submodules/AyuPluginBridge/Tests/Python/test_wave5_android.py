"""``android.os.Environment`` and ``android.os.StrictMode``: a synthetic host and a temporary ``HOME``."""
from __future__ import annotations

import os
import threading
import unittest

from pymembers_fixtures import HostCase
import ayu_bridge as bridge
from _ayu_javalib import android_compose, android_os, java_io, java_lang

STORAGE = ("Library", "Application Support", "AyuPluginFiles")
Environment = android_os.Environment
StrictMode = android_os.StrictMode


class EnvironmentTests(HostCase):
    def path(self, *parts):
        return os.path.join(self.home, *parts)

    def test_shared_storage_is_a_real_stable_directory_of_the_container(self):
        with bridge.runtime.context(self.load()):
            root = Environment.getExternalStorageDirectory()
            self.assertIs(type(root), java_io.File)
            self.assertEqual(root.getAbsolutePath(), self.path(*STORAGE, "external_storage"))
            self.assertTrue(root.isDirectory())
            downloads = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
            self.assertEqual(downloads.getPath(), self.path(*STORAGE, "external_storage", "Download"))
            self.assertTrue(downloads.isDirectory() and downloads.canWrite())
            self.assertEqual(downloads, java_io.File(root, "Download"))
            target = os.path.join(downloads.getPath(), "saved.txt")
            with open(target, "w", encoding="utf-8") as stream:
                stream.write("kept")
            again = Environment.getExternalStoragePublicDirectory("Download")
            self.assertEqual(again, downloads)
            self.assertEqual(java_io.File(again, "saved.txt").length(), 4)
            for name in ("DCIM", "Pictures", "Movies", "Music", "Documents"):
                self.assertTrue(Environment.getExternalStoragePublicDirectory(name).isDirectory(), name)
            # Only the directories a device ships exist before the caller makes them.
            custom = Environment.getExternalStoragePublicDirectory("Custom/inner")
            self.assertEqual(custom.getPath(), self.path(*STORAGE, "external_storage", "Custom", "inner"))
            self.assertFalse(custom.exists())
            self.assertTrue(custom.mkdirs())
            self.assertEqual(self.host_requests(), [])

    def test_public_directory_refuses_what_android_refuses_or_what_would_leave_the_storage(self):
        with bridge.runtime.context(self.load()):
            with self.assertRaises(java_lang.NullPointerException):
                Environment.getExternalStoragePublicDirectory(None)
            for kind in ("", "/etc", "../up", "a/../../b", "a\0b", 5):
                with self.subTest(kind), self.assertRaises(bridge.UnsupportedAPI):
                    Environment.getExternalStoragePublicDirectory(kind)

    def test_constants_have_the_android_values(self):
        self.assertEqual((Environment.DIRECTORY_DOWNLOADS, Environment.DIRECTORY_DCIM, Environment.DIRECTORY_PICTURES,
                          Environment.DIRECTORY_MOVIES, Environment.DIRECTORY_MUSIC, Environment.DIRECTORY_DOCUMENTS,
                          Environment.DIRECTORY_SCREENSHOTS, Environment.DIRECTORY_RECORDINGS),
                         ("Download", "DCIM", "Pictures", "Movies", "Music", "Documents", "Screenshots", "Recordings"))
        self.assertEqual((Environment.MEDIA_MOUNTED, Environment.MEDIA_MOUNTED_READ_ONLY, Environment.MEDIA_UNMOUNTED,
                          Environment.MEDIA_REMOVED, Environment.MEDIA_UNKNOWN),
                         ("mounted", "mounted_ro", "unmounted", "removed", "unknown"))

    def test_volume_queries_describe_built_in_mounted_storage(self):
        with bridge.runtime.context(self.load()):
            downloads = Environment.getExternalStoragePublicDirectory("Download")
            external = android_compose._external_files_dir(None)
            outside = java_io.File("/synthetic/elsewhere")
            self.assertEqual((Environment.getExternalStorageState(), Environment.getExternalStorageState(downloads),
                              Environment.getExternalStorageState(external), Environment.getExternalStorageState(outside)),
                             ("mounted", "mounted", "mounted", "unknown"))
            self.assertEqual((Environment.isExternalStorageRemovable(), Environment.isExternalStorageRemovable(external),
                              Environment.isExternalStorageEmulated(), Environment.isExternalStorageEmulated(downloads),
                              Environment.isExternalStorageManager(), Environment.isExternalStorageLegacy()),
                             (False, False, True, True, True, False))
            sibling = java_io.File(self.path(*STORAGE, "external_storage_other"))
            for path in (outside, sibling):
                with self.assertRaises(java_lang.IllegalArgumentException):
                    Environment.isExternalStorageRemovable(path)
            with self.assertRaises(TypeError):
                Environment.isExternalStorageRemovable("/a/path")

    def test_data_directory_is_the_container_and_measurable(self):
        with bridge.runtime.context(self.load()):
            data = Environment.getDataDirectory()
            self.assertEqual(data.getPath(), self.home)
            self.assertGreater(android_os.StatFs(data.getPath()).getTotalBytes(), 0)

    def test_unprovided_members_stay_absent(self):
        for name in ("getDownloadCacheDirectory", "getRootDirectory", "getStorageDirectory"):
            self.assertFalse(hasattr(Environment, name), name)

    def test_classes_are_registered(self):
        self.assertIs(android_os.CLASSES["android.os.Environment"], Environment)
        self.assertIs(android_os.CLASSES["android.os.StrictMode$VmPolicy$Builder"], StrictMode.VmPolicy.Builder)
        self.assertIs(android_os.CLASSES["android.os.StrictMode$ThreadPolicy"], StrictMode.ThreadPolicy)


class StrictModeTests(unittest.TestCase):
    def setUp(self):
        self.addCleanup(setattr, StrictMode, "_vm", StrictMode.VmPolicy.LAX)
        self.addCleanup(StrictMode.setThreadPolicy, StrictMode.ThreadPolicy.LAX)

    def test_permissive_policies_install_and_read_back(self):
        policy = StrictMode.VmPolicy.Builder().build()
        self.assertIsNone(StrictMode.setVmPolicy(policy))
        self.assertIs(StrictMode.getVmPolicy(), policy)
        self.assertIsInstance(StrictMode.VmPolicy.Builder(policy).build(), StrictMode.VmPolicy)
        thread = StrictMode.ThreadPolicy.Builder().permitAll().build()
        previous = StrictMode.allowThreadDiskWrites()
        self.assertIs(previous, StrictMode.ThreadPolicy.LAX)
        StrictMode.setThreadPolicy(thread)
        self.assertIs(StrictMode.getThreadPolicy(), thread)
        seen = []
        worker = threading.Thread(target=lambda: seen.append(StrictMode.getThreadPolicy()))
        worker.start()
        worker.join()
        # A thread policy belongs to the thread that set it.
        self.assertEqual(seen, [StrictMode.ThreadPolicy.LAX])

    def test_detection_cannot_be_requested(self):
        for builder, names in ((StrictMode.VmPolicy.Builder(), ("detectAll", "detectFileUriExposure", "penaltyLog", "penaltyDeath")),
                               (StrictMode.ThreadPolicy.Builder(), ("detectAll", "detectDiskReads", "detectNetwork", "penaltyDialog"))):
            for name in names:
                self.assertFalse(hasattr(builder, name), name)
        self.assertFalse(hasattr(StrictMode, "enableDefaults"))

    def test_arguments_are_checked(self):
        with self.assertRaises(java_lang.NullPointerException):
            StrictMode.setVmPolicy(None)
        with self.assertRaises(java_lang.NullPointerException):
            StrictMode.setThreadPolicy(None)
        with self.assertRaises(TypeError):
            StrictMode.setVmPolicy(StrictMode.ThreadPolicy.LAX)
        with self.assertRaises(TypeError):
            StrictMode.VmPolicy.Builder(StrictMode.ThreadPolicy.LAX)
        with self.assertRaises(bridge.UnsupportedAPI):
            StrictMode()


if __name__ == "__main__":
    unittest.main()
