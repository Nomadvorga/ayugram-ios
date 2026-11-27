"""The ``elyx`` facade that Elyx plugins import.

It exposes the public ``elyxcore`` API and, to code of a loaded package, the
values bound to that package: ``assets``, ``metainfo``, ``refmap``, ``settings``
and ``strings``. Outside a package those names do not exist.
"""
from elyxcore import (Asset, AssetNotFoundException, Assets, AssetsDirNotFoundException, Callback, Callback2,
                      Callback3, CallbackReturn, LazyDict, OnClickListener, Runnable, SettingsController, Strings,
                      gen, gen2, get_environment, import_module)

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


def __getattr__(name):
    import _ayu_packages
    return _ayu_packages.environment_value(name)
