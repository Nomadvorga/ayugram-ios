"""Top-level jarray facade (Android plugins import it beside ``java``)."""
from __future__ import annotations

from java import jarray

__all__ = ["jarray", "zeros"]


def zeros(length, component="java.lang.Object"):
    return jarray(component)([None] * int(length))
