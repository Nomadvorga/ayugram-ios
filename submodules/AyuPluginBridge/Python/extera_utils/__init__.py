"""Explicitly implemented extera_utils compatibility facade.

Covers the surface observed in the pinned plugin corpus. Subclassing of native
Java classes is not possible without a JVM: ``java_subclass`` raises
``UnsupportedAPI`` at class-creation time so the load gate reports the real
gap, while pure-Python helpers (logging, text formatting, task binding) work
through the existing bridge adapters.
"""
from __future__ import annotations

from ayu_bridge import UnsupportedAPI, runtime
from base_plugin import BasePlugin, MethodHook, _Logger

__path__ = []  # allow extera_utils.classes style submodule resolution


Base = BasePlugin


def java_subclass(*bases):
    runtime.require()
    if not bases:
        raise TypeError("java_subclass requires at least one base class")
    names = []
    for base in bases:
        name = getattr(base, "_name", None)
        if not isinstance(name, str):
            raise TypeError("java_subclass bases must be declared Java class facades")
        names.append(name)
    raise UnsupportedAPI(f"Java subclassing is not supported on iOS: {', '.join(names)}")


def joverride(function):
    if not callable(function):
        raise TypeError("joverride must wrap a callable")
    return function


def joverload(*overloads):
    runtime.require()
    if not overloads:
        raise TypeError("joverload requires at least one implementation")
    for overload in overloads:
        if not callable(overload):
            raise TypeError("joverload implementations must be callable")
    return overloads[0]


def jconstructor(clazz):
    runtime.require()
    raise UnsupportedAPI("Java constructor reflection is not supported on iOS")


def jfield(clazz, name):
    runtime.require()
    raise UnsupportedAPI(f"Java field access is not supported on iOS: {name}")


def jgetmethod(clazz, name):
    runtime.require()
    raise UnsupportedAPI(f"Java method reflection is not supported on iOS: {name}")


def capture_scope():
    return runtime.require()


def bind_task(function, *, delay=0, queue=None):
    if not callable(function):
        raise TypeError("bind_task requires a callable")
    from client_utils import run_on_queue
    return run_on_queue(function, delay=int(delay), queue=queue)


class _Lifecycle:
    @staticmethod
    def on_plugin_load(function):
        if not callable(function):
            raise TypeError("on_plugin_load must decorate a callable")
        return function

    @staticmethod
    def on_plugin_unload(function):
        if not callable(function):
            raise TypeError("on_plugin_unload must decorate a callable")
        return function


lifecycle = _Lifecycle()


class _TextFormatting:
    @staticmethod
    def parse_text(text):
        if not isinstance(text, str):
            raise TypeError("parse_text requires a string")
        return runtime.call("text.parse", {"text": text})

    @staticmethod
    def bind_task(function, *, delay=0, queue=None):
        return bind_task(function, delay=delay, queue=queue)


text_formatting = _TextFormatting()
