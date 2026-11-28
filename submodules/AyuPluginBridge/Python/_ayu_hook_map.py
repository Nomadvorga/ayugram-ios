"""Hook registrations Android itself drops, so they need no hook target on iOS either.

Android's ``__get_java_callback_instance`` builds a callback only from a ``MethodReplacement``, a
``MethodHook``, or an object with ``replace_hooked_method`` or a callable ``before_hooked_method`` /
``after_hooked_method``. Any other truthy ``xposed_hook`` (a method name passed where the hook
belongs) makes ``hook_method``/``hook_all_methods``/``hook_all_constructors`` log
``Could not determine hook type for <type>.`` and return None without looking at the target.
"""
from __future__ import annotations

import ast

# Position of ``xposed_hook`` per API.
HOOK_ARGUMENT = {"hook_method": 1, "hook_all_methods": 2, "hook_all_constructors": 1}
_LITERALS = (str, bytes, int, float)


def undetermined(xposed_hook):
    """Whether Android cannot tell what kind of hook this truthy object is."""
    from base_plugin import MethodHook, MethodReplacement
    if not xposed_hook or isinstance(xposed_hook, (MethodReplacement, MethodHook)):
        return False
    if hasattr(xposed_hook, "replace_hooked_method"):
        return False
    return not any(callable(getattr(xposed_hook, name, None)) for name in ("before_hooked_method", "after_hooked_method"))


def message(xposed_hook):
    return f"Could not determine hook type for {type(xposed_hook).__name__}."


def static_undetermined(api, positional, keywords):
    """Whether one hook call passes a truthy literal as ``xposed_hook``: Android registers nothing for it."""
    index = HOOK_ARGUMENT.get(api)
    if index is None:
        return False
    node = positional[index] if len(positional) > index else keywords.get("xposed_hook")
    return isinstance(node, ast.Constant) and isinstance(node.value, _LITERALS) and bool(node.value)
