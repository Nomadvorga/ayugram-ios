"""Wave 7: the video keys and frame options of android.media.MediaMetadataRetriever."""
from __future__ import annotations

import os
import tempfile
import unittest
import wave

import test_wave6_media as wave6
from _ayu_javalib import android_media

MMR = android_media.MediaMetadataRetriever


class VideoConstants(unittest.TestCase):
    def test_video_keys_and_options_have_the_aosp_values(self):
        self.assertEqual((MMR.METADATA_KEY_VIDEO_WIDTH, MMR.METADATA_KEY_VIDEO_HEIGHT, MMR.METADATA_KEY_VIDEO_ROTATION),
                         (18, 19, 24))
        self.assertEqual((MMR.OPTION_PREVIOUS_SYNC, MMR.OPTION_NEXT_SYNC, MMR.OPTION_CLOSEST_SYNC, MMR.OPTION_CLOSEST),
                         (0, 1, 2, 3))

    def test_frame_extraction_stays_undefined_until_the_host_serves_it(self):
        for name in ("getFrameAtTime", "getScaledFrameAtTime", "getFrameAtIndex", "METADATA_KEY_HAS_VIDEO"):
            self.assertFalse(hasattr(MMR, name), name)

    @unittest.skipIf(wave6.mutagen is None, "mutagen is not importable on this interpreter")
    def test_video_keys_answer_null_for_an_audio_only_file(self):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "tone.wav")
            with wave.open(path, "wb") as out:
                out.setnchannels(1)
                out.setsampwidth(2)
                out.setframerate(8000)
                out.writeframes(b"\x00\x00" * 800)
            retriever = MMR()
            retriever.setDataSource(path)
            for key in (MMR.METADATA_KEY_VIDEO_WIDTH, MMR.METADATA_KEY_VIDEO_HEIGHT, MMR.METADATA_KEY_VIDEO_ROTATION):
                self.assertIsNone(retriever.extractMetadata(key))
            retriever.release()


if __name__ == "__main__":
    unittest.main()
