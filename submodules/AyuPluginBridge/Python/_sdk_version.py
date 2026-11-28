"""Version markers of the emulated Android plugins SDK.

The version is the one ``_ayu_policy`` evaluates ``__sdk_version__`` against.
Android's safe-mode importer and Xposed bootstrap have no iOS counterpart: the
bridge has no safe mode, so ``Z.c()`` only reports the state that is true here.
"""
import _ayu_policy

__all__ = ["__version__", "version", "version_str", "__beta__", "beta", "SafeModeImporter", "Z", "X"]

__version__ = _ayu_policy.SDK_VERSION
version = tuple(int(part) for part in __version__.split("."))
version_str = __version__

__beta__ = False
beta = __beta__


class SafeModeImporter:
    IS_OLD_VERSION = False
    I = True
    E = False

    @classmethod
    def c(cls):
        if not cls.I:
            raise RuntimeError("SDK not initialized.")
        if cls.E:
            if cls.IS_OLD_VERSION:
                raise RuntimeError("App version is too old. Please update app to last stable version.")
            raise RuntimeError("Safe mode enabled")


Z = SafeModeImporter.INSTANCE = SafeModeImporter()


class X:
    BUILD_VERSION = None
