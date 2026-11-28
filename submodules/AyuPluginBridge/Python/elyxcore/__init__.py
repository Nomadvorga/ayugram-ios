"""Public API for structured Elyx plugins (``.elyx`` / ``.eaf`` packages).

Plugin code imports supported symbols from ``elyx``::

    from elyx import Asset, Assets, SettingsController, Strings

Values bound to the calling plugin are served by the same facade::

    from elyx import assets, metainfo, refmap, settings, strings

The listener helpers create their proxy class on first use, because a Java
interface is only known once a plugin generation is active. ``mvel_execute``
is not provided: MVEL scripts need a JVM.
"""
from __future__ import annotations

from elyxcore.assets import Asset, AssetNotFoundException, Assets, AssetsDirNotFoundException
from elyxcore.localization import Strings
from elyxcore.settings import SettingsController
from elyxcore.utils import LazyDict, gen, gen2


class _Listener:
    """``Listener(fn, *args, **kwargs)``: an instance of ``gen(interface, method)``."""

    def __init__(self, interface, method, return_value=False):
        self._interface, self._method, self._return_value = interface, method, return_value

    def _class(self):
        from ayu_bridge import runtime
        return gen(runtime.jclass(self._interface), self._method, self._return_value)

    def __call__(self, fn, *args, **kwargs):
        return self._class()(fn, *args, **kwargs)


OnClickListener = _Listener("android.view.View$OnClickListener", "onClick")
Runnable = _Listener("java.lang.Runnable", "run")
Callback = _Listener("org.telegram.messenger.Utilities$Callback", "run")
Callback2 = _Listener("org.telegram.messenger.Utilities$Callback2", "run")
Callback3 = _Listener("org.telegram.messenger.Utilities$Callback3", "run")
CallbackReturn = _Listener("org.telegram.messenger.Utilities$CallbackReturn", "run", True)


def get_environment():
    """Return assets, settings, strings and metadata for the calling plugin."""
    import _ayu_packages
    return _ayu_packages.environment()


def import_module(name, package=None):
    """Import a module relative to the calling plugin when it exists locally."""
    import _ayu_packages
    return _ayu_packages.import_module(name, package)


__all__ = (
    "Asset",
    "AssetNotFoundException",
    "Assets",
    "AssetsDirNotFoundException",
    "Callback",
    "Callback2",
    "Callback3",
    "CallbackReturn",
    "LazyDict",
    "OnClickListener",
    "Runnable",
    "SettingsController",
    "Strings",
    "gen",
    "gen2",
    "get_environment",
    "import_module",
)
