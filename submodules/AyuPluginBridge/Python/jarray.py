"""Top-level Jython-style ``jarray`` module (Android plugins import it beside ``java``)."""
from __future__ import annotations

import java
from java import jarray

__all__ = ["jarray", "zeros", "array"]

_TYPECODES = {"z": java.jboolean, "c": java.jchar, "b": java.jbyte, "h": java.jshort, "i": java.jint,
              "l": java.jlong, "f": java.jfloat, "d": java.jdouble}


def _component(kind):
    if isinstance(kind, str):
        if kind in _TYPECODES:
            return _TYPECODES[kind]
        # A one-letter string is a typecode; anything longer names a Java class.
        if len(kind) == 1:
            raise java.UnsupportedAPI(f"Unsupported jarray typecode: {kind}")
        return java.jclass(kind)
    return kind


def zeros(length, component="java.lang.Object"):
    return jarray(_component(component))(int(length))


def array(values, component="java.lang.Object"):
    return jarray(_component(component))(list(values))
