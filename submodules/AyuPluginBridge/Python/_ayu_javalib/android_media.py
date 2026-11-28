"""``android.media.MediaMetadataRetriever`` for audio-only files, read by the bundled ``mutagen``.

Only containers that cannot carry video Android would decode are accepted (MP3,
FLAC, Ogg Vorbis/Opus, WAV); any other file is refused as unsupported instead of
answered wrongly. Video keys, frame extraction and the tag keys whose Android
mapping differs per container are not defined, so their use stays a blocker.
"""
from __future__ import annotations

import base64
import os

from . import java_lang as _l
from .java_lang import IllegalArgumentException, IllegalStateException, Object, RuntimeException

_TAGS = {1: "album", 2: "artist", 4: "composer", 6: "genre", 7: "title", 13: "albumartist"}
# Android answers null for these on a file with one audio track and nothing else.
_ABSENT = frozenset((17, 18, 19, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37))


def _load(path):
    try:
        import mutagen
        from mutagen.flac import FLAC
        from mutagen.mp3 import MP3
        from mutagen.oggopus import OggOpus
        from mutagen.oggvorbis import OggVorbis
        from mutagen.wave import WAVE
    except ImportError:
        raise _l.unsupported("MediaMetadataRetriever needs the bundled mutagen package") from None
    mimes = ((MP3, "audio/mpeg"), (FLAC, "audio/flac"), (OggVorbis, "audio/ogg"), (OggOpus, "audio/ogg"),
             (WAVE, "audio/x-wav"))
    try:
        parsed = mutagen.File(path)
    except Exception:
        parsed = None
    for kind, mime in mimes:
        if type(parsed) is kind:
            return parsed, mutagen.File(path, easy=True), mime
    raise _l.unsupported("MediaMetadataRetriever reads only MP3, FLAC, Ogg Vorbis/Opus and WAV audio on iOS")


class MediaMetadataRetriever(Object):
    METADATA_KEY_ALBUM = 1
    METADATA_KEY_ARTIST = 2
    METADATA_KEY_COMPOSER = 4
    METADATA_KEY_GENRE = 6
    METADATA_KEY_TITLE = 7
    METADATA_KEY_DURATION = 9
    METADATA_KEY_NUM_TRACKS = 10
    METADATA_KEY_MIMETYPE = 12
    METADATA_KEY_ALBUMARTIST = 13
    METADATA_KEY_HAS_AUDIO = 16
    # Answered null: the accepted containers never carry a video track.
    METADATA_KEY_VIDEO_WIDTH = 18
    METADATA_KEY_VIDEO_HEIGHT = 19
    METADATA_KEY_BITRATE = 20
    METADATA_KEY_VIDEO_ROTATION = 24
    METADATA_KEY_SAMPLERATE = 38
    METADATA_KEY_BITS_PER_SAMPLE = 39

    OPTION_PREVIOUS_SYNC = 0
    OPTION_NEXT_SYNC = 1
    OPTION_CLOSEST_SYNC = 2
    OPTION_CLOSEST = 3

    def __init__(self):
        self._released = False
        self._source = None

    def _check(self):
        if self._released:
            raise IllegalStateException("No retriever available")

    def setDataSource(self, path):
        self._check()
        if path is None:
            raise IllegalArgumentException("null path")
        if not isinstance(path, str):
            raise _l.unsupported("MediaMetadataRetriever.setDataSource takes only a file path on iOS")
        path = str.__str__(path)
        if not os.path.isfile(path):
            raise IllegalArgumentException(path + " does not exist")
        if os.path.getsize(path) == 0:
            raise RuntimeException("setDataSource failed: status = 0x80000000")
        self._source = _load(path)

    def extractMetadata(self, keyCode):
        self._check()
        if self._source is None:
            return None
        parsed, easy, mime = self._source
        key = int(keyCode)
        info = parsed.info
        if key in _TAGS:
            values = (easy.tags or {}).get(_TAGS[key]) if easy is not None else None
            return str(values[0]) if values else None
        if key == 9:
            return str(int(info.length * 1000))
        if key == 10:
            return "1"
        if key == 12:
            return mime
        if key == 16:
            return "yes"
        if key == 20:
            bitrate = int(getattr(info, "bitrate", 0) or 0)
            return str(bitrate) if bitrate > 0 else None
        if key == 38:
            rate = int(getattr(info, "sample_rate", 0) or 0)
            return str(rate) if rate > 0 else None
        if key == 39:
            bits = int(getattr(info, "bits_per_sample", 0) or 0)
            return str(bits) if bits > 0 else None
        if key in _ABSENT:
            return None
        raise _l.unsupported(f"MediaMetadataRetriever.extractMetadata({key}) is not provided on iOS")

    def getEmbeddedPicture(self):
        self._check()
        if self._source is None:
            return None
        parsed = self._source[0]
        data = None
        if hasattr(parsed, "pictures"):
            data = parsed.pictures[0].data if parsed.pictures else None
        elif parsed.tags is not None and hasattr(parsed.tags, "getall"):
            frames = parsed.tags.getall("APIC")
            data = frames[0].data if frames else None
        elif parsed.tags is not None:
            from mutagen.flac import Picture
            blocks = parsed.tags.get("metadata_block_picture") or ()
            try:
                data = Picture(base64.b64decode(blocks[0])).data if blocks else None
            except Exception:
                data = None
        return _l.ByteArray(data) if data else None

    def release(self):
        self._released = True
        self._source = None

    def close(self):
        self.release()


CLASSES = _l.register({
    "android.media.MediaMetadataRetriever": MediaMetadataRetriever,
})
