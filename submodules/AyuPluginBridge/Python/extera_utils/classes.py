"""Explicit extera_utils.classes surface: proxy bases only, no native subclassing."""
from __future__ import annotations

from ayu_bridge import DynamicProxy, UnsupportedAPI

from extera_utils import java_subclass, joverride  # re-exports used by plugins

Base = DynamicProxy


def make_interface(name, methods):
    if not isinstance(name, str) or not name:
        raise TypeError("Interface name must be a nonempty string")
    methods = tuple(dict.fromkeys(methods))
    if not methods or not all(isinstance(m, str) for m in methods):
        raise TypeError("Interface methods must be nonempty method names")
    return type("JavaInterface", (), {
        "__ayu_interface_name__": name,
        "__ayu_interface_methods__": methods,
    })
