"""Reflection requests are limited to adapters explicitly implemented by host."""
from ayu_bridge import runtime
from java import jclass


def find_class(name):
    return jclass(name)


def get_private_field(target, name):
    return runtime.call("java.get_private_field", {"target": target, "name": name})


def set_private_field(target, name, value):
    return runtime.call("java.set_private_field", {"target": target, "name": name, "value": value})
