"""android.media.MediaMetadataRetriever over synthetic audio written by the test."""
from __future__ import annotations

import glob
import os
import sys
import tempfile
import unittest
import wave

import pymembers_fixtures  # noqa: F401  (puts the SDK on sys.path)
import ayu_bridge as bridge
import _ayu_javalib as javalib
from _ayu_javalib import android_media, java_lang

try:
    import mutagen
except ImportError:
    # The Mac interpreter lacks the bundled pure-Python package; use an unpacked runtime bundle when one exists.
    for candidate in glob.glob(os.path.expanduser("~/work/_refs/plugin-bridge-scratch/deps/*/PythonResources/python/lib/python3.*")):
        if os.path.isdir(os.path.join(candidate, "mutagen")):
            sys.path.append(candidate)
            break
    try:
        import mutagen
    except ImportError:
        mutagen = None

MMR = android_media.MediaMetadataRetriever


class ConstantsAndLifecycle(unittest.TestCase):
    def test_constants_have_the_aosp_values_and_unserved_ones_are_absent(self):
        self.assertEqual((MMR.METADATA_KEY_ALBUM, MMR.METADATA_KEY_ARTIST, MMR.METADATA_KEY_TITLE, MMR.METADATA_KEY_DURATION,
                          MMR.METADATA_KEY_MIMETYPE, MMR.METADATA_KEY_ALBUMARTIST, MMR.METADATA_KEY_HAS_AUDIO,
                          MMR.METADATA_KEY_BITRATE, MMR.METADATA_KEY_SAMPLERATE, MMR.METADATA_KEY_BITS_PER_SAMPLE),
                         (1, 2, 7, 9, 12, 13, 16, 20, 38, 39))
        for name in ("getFrameAtTime", "METADATA_KEY_YEAR", "getScaledFrameAtTime"):
            self.assertFalse(hasattr(MMR, name), name)
        self.assertIs(javalib.local_class("android.media.MediaMetadataRetriever"), MMR)

    def test_source_errors_and_release_follow_android(self):
        retriever = MMR()
        self.assertIsNone(retriever.extractMetadata(MMR.METADATA_KEY_DURATION))
        self.assertIsNone(retriever.getEmbeddedPicture())
        with self.assertRaises(java_lang.IllegalArgumentException):
            retriever.setDataSource(None)
        with self.assertRaises(java_lang.IllegalArgumentException):
            retriever.setDataSource("/nonexistent/ayu-wave6.mp3")
        with self.assertRaises(bridge.UnsupportedAPI):
            retriever.setDataSource(object())
        retriever.release()
        retriever.close()
        with self.assertRaises(java_lang.IllegalStateException):
            retriever.extractMetadata(MMR.METADATA_KEY_DURATION)


@unittest.skipIf(mutagen is None, "mutagen is not importable on this interpreter")
class AudioFiles(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)

    def path(self, name):
        return os.path.join(self.directory.name, name)

    def test_wav_reports_duration_format_and_no_tags(self):
        path = self.path("tone.wav")
        with wave.open(path, "wb") as out:
            out.setnchannels(1)
            out.setsampwidth(2)
            out.setframerate(8000)
            out.writeframes(b"\x00\x01" * 12000)
        retriever = MMR()
        retriever.setDataSource(path)
        self.assertEqual(retriever.extractMetadata(MMR.METADATA_KEY_DURATION), "1500")
        self.assertEqual(retriever.extractMetadata(MMR.METADATA_KEY_MIMETYPE), "audio/x-wav")
        self.assertEqual(retriever.extractMetadata(MMR.METADATA_KEY_SAMPLERATE), "8000")
        self.assertEqual(retriever.extractMetadata(MMR.METADATA_KEY_BITS_PER_SAMPLE), "16")
        self.assertEqual(retriever.extractMetadata(MMR.METADATA_KEY_BITRATE), "128000")
        self.assertEqual(retriever.extractMetadata(MMR.METADATA_KEY_HAS_AUDIO), "yes")
        self.assertEqual(retriever.extractMetadata(MMR.METADATA_KEY_NUM_TRACKS), "1")
        self.assertIsNone(retriever.extractMetadata(MMR.METADATA_KEY_TITLE))
        self.assertIsNone(retriever.extractMetadata(18))
        self.assertIsNone(retriever.getEmbeddedPicture())
        with self.assertRaises(bridge.UnsupportedAPI):
            retriever.extractMetadata(8)

    def test_mp3_reports_id3_tags_picture_and_bitrate(self):
        from mutagen.id3 import APIC, ID3, TALB, TIT2, TPE1
        path = self.path("song.mp3")
        with open(path, "wb") as out:
            out.write((b"\xff\xfb\x90\x00" + bytes(413)) * 200)
        tags = ID3()
        tags.add(TIT2(encoding=3, text="Название"))
        tags.add(TPE1(encoding=3, text="Artist"))
        tags.add(TALB(encoding=3, text="Album"))
        tags.add(APIC(encoding=3, mime="image/png", type=3, desc="", data=b"\x89PNG-cover"))
        tags.save(path)
        retriever = MMR()
        retriever.setDataSource(java_lang.jstr(path))
        self.assertEqual(retriever.extractMetadata(MMR.METADATA_KEY_TITLE), "Название")
        self.assertEqual(retriever.extractMetadata(MMR.METADATA_KEY_ARTIST), "Artist")
        self.assertEqual(retriever.extractMetadata(MMR.METADATA_KEY_ALBUM), "Album")
        self.assertIsNone(retriever.extractMetadata(MMR.METADATA_KEY_GENRE))
        self.assertEqual(retriever.extractMetadata(MMR.METADATA_KEY_MIMETYPE), "audio/mpeg")
        self.assertEqual(retriever.extractMetadata(MMR.METADATA_KEY_BITRATE), "128000")
        self.assertEqual(retriever.extractMetadata(MMR.METADATA_KEY_SAMPLERATE), "44100")
        self.assertIsNone(retriever.extractMetadata(MMR.METADATA_KEY_BITS_PER_SAMPLE))
        duration = int(retriever.extractMetadata(MMR.METADATA_KEY_DURATION))
        self.assertTrue(5100 <= duration <= 5300, duration)
        self.assertEqual(bytes(retriever.getEmbeddedPicture()), b"\x89PNG-cover")

    def test_other_containers_are_refused_not_guessed(self):
        path = self.path("clip.mp4")
        with open(path, "wb") as out:
            out.write(b"\x00\x00\x00\x18ftypisom\x00\x00\x00\x00isommp42" + bytes(64))
        with self.assertRaises(bridge.UnsupportedAPI):
            MMR().setDataSource(path)
        empty = self.path("empty.mp3")
        open(empty, "wb").close()
        with self.assertRaises(java_lang.RuntimeException):
            MMR().setDataSource(empty)


if __name__ == "__main__":
    unittest.main()
