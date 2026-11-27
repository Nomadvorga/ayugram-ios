"""``android.os`` value classes implemented in Python.

``Build`` does not describe an Android device, because there is none:

- ``VERSION.SDK_INT``/``RELEASE``/``CODENAME`` name the Android API level this bridge
  emulates: the ``targetSdkVersion`` of the Android application whose plugin SDK it
  ports (API 36, Android 16). A plugin's ``SDK_INT >= N`` test therefore selects the
  modern API path, and an API the bridge lacks still fails as ``UnsupportedAPI``.
- ``MANUFACTURER``/``BRAND`` are ``Apple`` and ``MODEL``/``DEVICE``/``PRODUCT`` are the
  hardware identifier the operating system reports (for example ``iPhone15,2``).
- ``SUPPORTED_ABIS`` and its 32/64-bit variants are empty: no Android ABI can be loaded.
- Every other field is ``Build.UNKNOWN``, Android's own value for an unavailable property.
"""
from __future__ import annotations

import os
import sys
import time

from . import java_lang as _l
from .java_lang import NullPointerException, Object

EMULATED_SDK_INT = 36
EMULATED_RELEASE = "16"


def _hardware_model():
    if sys.platform == "ios":
        try:
            import platform
            model = platform.ios_ver().model
            if model:
                return model
        except (AttributeError, OSError):
            pass
    try:
        return os.uname().machine or "unknown"
    except (AttributeError, OSError):
        return "unknown"


class _Version(Object):
    SDK_INT = EMULATED_SDK_INT
    SDK = str(EMULATED_SDK_INT)
    RELEASE = EMULATED_RELEASE
    RELEASE_OR_CODENAME = EMULATED_RELEASE
    RELEASE_OR_PREVIEW_DISPLAY = EMULATED_RELEASE
    CODENAME = "REL"
    INCREMENTAL = "unknown"
    BASE_OS = ""
    SECURITY_PATCH = ""
    PREVIEW_SDK_INT = 0
    MEDIA_PERFORMANCE_CLASS = 0

    def __init__(self):
        raise _l.unsupported("android.os.Build.VERSION cannot be constructed")


class _VersionCodes(Object):
    CUR_DEVELOPMENT = 10000

    def __init__(self):
        raise _l.unsupported("android.os.Build.VERSION_CODES cannot be constructed")


for _level, _name in enumerate((
        "BASE", "BASE_1_1", "CUPCAKE", "DONUT", "ECLAIR", "ECLAIR_0_1", "ECLAIR_MR1", "FROYO", "GINGERBREAD",
        "GINGERBREAD_MR1", "HONEYCOMB", "HONEYCOMB_MR1", "HONEYCOMB_MR2", "ICE_CREAM_SANDWICH",
        "ICE_CREAM_SANDWICH_MR1", "JELLY_BEAN", "JELLY_BEAN_MR1", "JELLY_BEAN_MR2", "KITKAT", "KITKAT_WATCH",
        "LOLLIPOP", "LOLLIPOP_MR1", "M", "N", "N_MR1", "O", "O_MR1", "P", "Q", "R", "S", "S_V2", "TIRAMISU",
        "UPSIDE_DOWN_CAKE", "VANILLA_ICE_CREAM", "BAKLAVA"), start=1):
    setattr(_VersionCodes, _name, _level)


class Build(Object):
    UNKNOWN = "unknown"
    MANUFACTURER = "Apple"
    BRAND = "Apple"
    MODEL = _hardware_model()
    DEVICE = MODEL
    PRODUCT = MODEL
    BOARD = HARDWARE = BOOTLOADER = RADIO = SERIAL = UNKNOWN
    ID = DISPLAY = FINGERPRINT = HOST = USER = TAGS = TYPE = UNKNOWN
    SOC_MANUFACTURER = SOC_MODEL = SKU = ODM_SKU = UNKNOWN
    CPU_ABI = CPU_ABI2 = UNKNOWN
    SUPPORTED_ABIS = SUPPORTED_32_BIT_ABIS = SUPPORTED_64_BIT_ABIS = ()
    TIME = 0
    VERSION = _Version
    VERSION_CODES = _VersionCodes

    def __init__(self):
        raise _l.unsupported("android.os.Build cannot be constructed")

    @staticmethod
    def getRadioVersion():
        return None


class SystemClock(Object):
    """Monotonic readings of the host process clock; Android's boot-time origin is not promised."""
    __ayu_overrides_host__ = True  # the Swift adapter is a subset; the host neither takes nor returns one

    def __init__(self):
        raise _l.unsupported("android.os.SystemClock cannot be constructed")

    @staticmethod
    def uptimeMillis():
        return time.monotonic_ns() // 1_000_000

    @staticmethod
    def elapsedRealtime():
        return time.monotonic_ns() // 1_000_000

    @staticmethod
    def elapsedRealtimeNanos():
        return time.monotonic_ns()

    @staticmethod
    def currentThreadTimeMillis():
        return time.thread_time_ns() // 1_000_000


class BaseBundle(Object):
    """String-keyed value map.

    As on Android a typed getter answers its default when the key is missing or was
    stored by a different typed setter (``putInt`` then ``getLong`` gives 0).
    """

    def __init__(self, source=None):
        self._values, self._kinds = {}, {}
        if isinstance(source, BaseBundle):
            self.putAll(source)
        elif source is not None and not _l.is_int(source):
            raise TypeError("Bundle takes no argument, a capacity or another Bundle")

    def size(self):
        return len(self._values)

    def isEmpty(self):
        return not self._values

    def clear(self):
        self._values.clear()
        self._kinds.clear()

    def containsKey(self, key):
        return key in self._values

    def get(self, key):
        return self._values.get(key)

    def remove(self, key):
        self._values.pop(key, None)
        self._kinds.pop(key, None)

    def keySet(self):
        from . import java_util
        return java_util.HashSet(self._values)

    def putAll(self, other):
        self._values.update(other._values)
        self._kinds.update(other._kinds)

    def _store(self, kind, key, value):
        if key is not None and not isinstance(key, str):
            raise TypeError("Bundle keys are strings")
        self._values[key] = value
        self._kinds[key] = kind

    def _load(self, kind, key, default):
        return self._values[key] if self._kinds.get(key) == kind and self._values[key] is not None else default

    def getBundle(self, key):
        return self._load("Bundle", key, None)

    def putBundle(self, key, value):
        if value is not None and not isinstance(value, BaseBundle):
            raise TypeError("putBundle requires a Bundle")
        self._store("Bundle", key, value)

    def __len__(self):
        return len(self._values)

    def __contains__(self, key):
        return key in self._values

    def __eq__(self, other):
        return isinstance(other, BaseBundle) and self._values == other._values

    __hash__ = None

    def toString(self):
        return "Bundle[" + _l.jstr(self._values) + "]"

    def to_bridge(self):
        return dict(self._values)


def _scalar(name, kinds, default, convert):
    def put(self, key, value):
        if isinstance(value, bool) != (bool in kinds) or not isinstance(value, kinds):
            if value is not None or default is not None:
                raise TypeError(f"put{name} requires {' or '.join(kind.__name__ for kind in kinds)}")
        self._store(name, key, convert(value) if convert and value is not None else value)

    def get(self, key, fallback=default):
        return self._load(name, key, fallback)

    setattr(BaseBundle, "put" + name, put)
    setattr(BaseBundle, "get" + name, get)


def _integer(bits):
    def convert(value):
        if not -(1 << (bits - 1)) <= value < 1 << (bits - 1):
            raise OverflowError(f"Value is outside the Java {bits}-bit range")
        return int(value)
    return convert


def _char(value):
    if len(value) != 1 or value > "\uffff":
        raise ValueError("putChar requires one UTF-16 code unit")
    return value


_scalar("Boolean", (bool,), False, None)
_scalar("Byte", (int,), 0, _integer(8))
_scalar("Short", (int,), 0, _integer(16))
_scalar("Int", (int,), 0, _integer(32))
_scalar("Long", (int,), 0, _integer(64))
_scalar("Float", (int, float), 0.0, _l.to_float32)
_scalar("Double", (int, float), 0.0, float)
_scalar("Char", (str,), "\0", _char)
_scalar("String", (str,), None, None)


def _reference(name):
    def put(self, key, value):
        self._store(name, key, value)

    def get(self, key, *ignored):
        return self._load(name, key, None)

    setattr(BaseBundle, "put" + name, put)
    setattr(BaseBundle, "get" + name, get)


for _kind in ("CharSequence", "IntArray", "LongArray", "StringArray", "BooleanArray", "DoubleArray", "FloatArray",
              "ByteArray", "CharSequenceArray", "StringArrayList", "IntegerArrayList", "ParcelableArrayList",
              "Parcelable", "Serializable"):
    _reference(_kind)


class Bundle(BaseBundle):
    __ayu_overrides_host__ = True  # the Swift adapter is a subset; the host neither takes nor returns one
    EMPTY = None

    def clone(self):
        return Bundle(self)

    def deepCopy(self):
        result = Bundle(self)
        for key, value in self._values.items():
            if isinstance(value, BaseBundle):
                result._values[key] = value.deepCopy() if isinstance(value, Bundle) else type(value)(value)
            elif isinstance(value, (list, bytearray)):
                result._values[key] = type(value)(value)
        return result


Bundle.EMPTY = Bundle()


class PersistableBundle(BaseBundle):
    pass


class StatFs(Object):
    """File-system space of the volume holding a path, read with ``statvfs``."""

    def __init__(self, path):
        if path is None:
            raise NullPointerException()
        self._path = os.fspath(path)
        self.restat(self._path)

    def restat(self, path):
        try:
            self._stats = os.statvfs(os.fspath(path))
        except (OSError, AttributeError) as error:
            raise _l.IllegalArgumentException(f"Invalid path: {os.fspath(path)}") from error
        self._path = os.fspath(path)

    def getBlockSizeLong(self):
        return self._stats.f_frsize

    def getBlockCountLong(self):
        return self._stats.f_blocks

    def getFreeBlocksLong(self):
        return self._stats.f_bfree

    def getAvailableBlocksLong(self):
        return self._stats.f_bavail

    def getBlockSize(self):
        return _l.i32(self._stats.f_frsize)

    def getBlockCount(self):
        return _l.i32(self._stats.f_blocks)

    def getFreeBlocks(self):
        return _l.i32(self._stats.f_bfree)

    def getAvailableBlocks(self):
        return _l.i32(self._stats.f_bavail)

    def getTotalBytes(self):
        return self._stats.f_frsize * self._stats.f_blocks

    def getFreeBytes(self):
        return self._stats.f_frsize * self._stats.f_bfree

    def getAvailableBytes(self):
        return self._stats.f_frsize * self._stats.f_bavail


class FileUtils(Object):
    def __init__(self):
        raise _l.unsupported("android.os.FileUtils cannot be constructed")

    @staticmethod
    def copy(source, target, *args):
        from . import java_io
        if args or not isinstance(source, java_io.InputStream) or not isinstance(target, java_io.OutputStream):
            raise _l.unsupported("FileUtils.copy supports Python-local (InputStream, OutputStream) only")
        return source.transferTo(target)

    @staticmethod
    def closeQuietly(closeable):
        if closeable is not None:
            try:
                closeable.close()
            except Exception:
                pass


CLASSES = _l.register({
    "android.os.Build": Build,
    "android.os.Build$VERSION": _Version,
    "android.os.Build$VERSION_CODES": _VersionCodes,
    "android.os.SystemClock": SystemClock,
    "android.os.BaseBundle": BaseBundle,
    "android.os.Bundle": Bundle,
    "android.os.PersistableBundle": PersistableBundle,
    "android.os.StatFs": StatFs,
    "android.os.FileUtils": FileUtils,
})
