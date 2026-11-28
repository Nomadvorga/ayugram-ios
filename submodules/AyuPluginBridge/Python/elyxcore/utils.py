"""Helpers of the Elyx plugin API.

``mvel_execute`` (Java MVEL expressions) and ``resize_image`` (Pillow) have no
counterpart in this SDK and are not defined.
"""
from __future__ import annotations

from ayu_bridge import BridgeError, JavaClass, runtime

_generated_classes = {}


def _log_failure(where, error):
    # Android logs the traceback; plugin exception text stays out of the host log.
    from android_utils import log
    try:
        log(f"[ERROR] [{where}] {type(error).__name__}")
    except BridgeError:
        pass


def _interface_name(java_class):
    import _ayu_javalib
    if isinstance(java_class, JavaClass):
        return java_class._name
    name = _ayu_javalib.local_name(java_class) if isinstance(java_class, type) else None
    if name is None:
        raise TypeError("gen requires a declared Java interface")
    return name


def gen(java_class, method_name, return_value=False, default_value=None):
    """A class implementing one method of a Java interface with a Python callable.

    ``Generated(fn, *args, **kwargs)`` calls ``fn(*java_args, *args, **kwargs)``;
    a failing ``fn`` is logged and yields ``default_value`` when ``return_value``.
    """
    from java import dynamic_proxy
    if default_value and not return_value:
        raise ValueError("provide default_value only if return_value is True")
    scope = runtime.require()
    name = _interface_name(java_class)
    cache = _generated_classes.setdefault(scope.generation, {})
    try:
        key = (name, method_name, return_value, default_value)
        cached = cache.get(key)
    except TypeError:
        key = cached = None
    if cached is not None:
        return cached

    def _run(instance, *java_args):
        try:
            value = instance._fn(*java_args, *instance._args, **instance._kwargs)
            if return_value:
                return value
        except BridgeError:
            raise
        except Exception as error:
            _log_failure("ElyxCore", error)
            if return_value:
                return default_value

    def __init__(self, fn, *args, **kwargs):
        self._fn = fn
        self._args = args
        self._kwargs = kwargs
        super(generated, self).__init__()

    generated = type("GeneratedProxyClass_" + name.rsplit(".", 1)[-1].replace("$", "_"),
                     (dynamic_proxy(java_class),), {"__init__": __init__, method_name: _run})
    if key is not None:
        if len(_generated_classes) > 64:
            # Generations that are gone no longer need their proxy classes.
            live = {item.generation for item in runtime.scopes.values()}
            for generation in [item for item in _generated_classes if item not in live]:
                del _generated_classes[generation]
        cache[key] = generated
    return generated


def gen2(java_class, return_value=False, **methods):
    """A class implementing several interface methods; ``Generated(*args, **kwargs)`` binds extra arguments."""
    from java import dynamic_proxy
    name = _interface_name(java_class)

    def _run(method):
        def _fn(instance, *java_args):
            try:
                value = method(*java_args, *instance._args, **instance._kwargs)
                if return_value:
                    return value
            except BridgeError:
                raise
            except Exception as error:
                _log_failure("ElyxCore", error)
        return _fn

    def __init__(self, *args, **kwargs):
        self._args = args
        self._kwargs = kwargs
        super(generated, self).__init__()

    generated = type("GeneratedProxyClass_" + name.rsplit(".", 1)[-1].replace("$", "_"),
                     (dynamic_proxy(java_class),),
                     {"__init__": __init__, **{key: _run(method) for key, method in methods.items()}})
    return generated


class LazyDict(dict):
    def __setattr__(self, key, value):
        self.__setitem__(key, value)

    def __getattr__(self, item):
        return self.__getitem__(item)


def safe_run_on_queue(fn):
    from client_utils import run_on_queue

    def _fn():
        try:
            fn()
        except BridgeError:
            raise
        except Exception as error:
            _log_failure("Elyx:RunOnQueue", error)

    run_on_queue(_fn)


def safe_func(fn):
    def _fn(*args, **kwargs):
        try:
            return fn(*args, **kwargs)
        except BridgeError:
            raise
        except Exception as error:
            _log_failure("Elyx:SafeFunc", error)

    return _fn


def hash_map(dict_):
    result = runtime.jclass("java.util.HashMap")()
    for key, value in dict_.items():
        result.put(key, value)
    return result
