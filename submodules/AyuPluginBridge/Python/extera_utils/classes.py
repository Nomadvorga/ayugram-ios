"""Declared listener interfaces work; JVM/DexMaker generation is unavailable."""
from ayu_bridge import DynamicProxy, UnsupportedAPI

Base = DynamicProxy


def _unsupported(*args, **kwargs):
    raise UnsupportedAPI("Java subclass, bytecode and reflection declarations require an unavailable JVM adapter")


# Fail at declaration rather than silently selecting an overload or returning an
# inert decorator. These names match the Android SDK's class generation API.
java_subclass = _unsupported
joverride = _unsupported
joverload = _unsupported
jmethod = _unsupported
jconstructor = _unsupported
jpreconstructor = _unsupported
jfield = _unsupported
jgetmethod = _unsupported
jsetmethod = _unsupported
jclassbuilder = _unsupported
jmvelmethod = _unsupported
jmveloverride = _unsupported
jMVELmethod = _unsupported
jMVELoverride = _unsupported
class_proxy = _unsupported
collect_peers = _unsupported
release_plugin = _unsupported


class JHelper:
    Override = staticmethod(_unsupported)
    Overload = staticmethod(_unsupported)
    Method = staticmethod(_unsupported)
    MVELMethod = staticmethod(_unsupported)
    MVELOverride = staticmethod(_unsupported)
    Constructor = staticmethod(_unsupported)
    PreConstructor = staticmethod(_unsupported)
    Field = staticmethod(_unsupported)
    GetMethod = staticmethod(_unsupported)
    SetMethod = staticmethod(_unsupported)
    ClassBuilder = staticmethod(_unsupported)


def make_interface(name, methods):
    if not isinstance(name, str) or not name:
        raise TypeError("Interface name must be a nonempty string")
    methods = tuple(dict.fromkeys(methods))
    if not methods or not all(isinstance(method, str) and method for method in methods):
        raise TypeError("Interface methods must be nonempty method names")
    return type("JavaInterface", (), {"__ayu_interface_name__": name,
                                      "__ayu_interface_methods__": methods})
