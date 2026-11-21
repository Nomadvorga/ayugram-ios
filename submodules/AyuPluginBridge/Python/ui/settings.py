"""Serializable native setting rows, owned by the creating plugin generation."""
from __future__ import annotations

from ayu_bridge import runtime


class _Component:
    positional = ()
    allowed = frozenset({"text", "subtext", "icon", "key", "default", "on_click",
                         "on_change", "items", "multiline", "hint", "input_type",
                         "enabled", "link_alias", "accent", "destructive"})

    def __init__(self, *args, **config):
        self._scope = runtime.require()
        if len(args) > len(self.positional):
            raise TypeError(f"Too many positional arguments for {type(self).__name__}")
        for name, value in zip(self.positional, args):
            if name in config:
                raise TypeError(f"Duplicate component argument: {name}")
            config[name] = value
        unknown = set(config) - self.allowed
        if unknown:
            raise TypeError("Unsupported setting options: " + ", ".join(sorted(unknown)))
        for callback in ("on_click", "on_change"):
            if callback in config and config[callback] is not None and not callable(config[callback]):
                raise TypeError(f"{callback} must be callable")
        for name in ("text", "subtext", "key", "hint"):
            if name in config and not isinstance(config[name], str):
                raise TypeError(f"{name} must be text")
        self.config = config

    def to_bridge(self):
        runtime.require(self._scope)
        return {"type": type(self).__name__, **self.config}


class Header(_Component):
    positional = ("text",)


class Divider(_Component):
    positional = ("text",)


class Text(_Component):
    positional = ("text", "icon", "on_click")


class _Setting(_Component):
    positional = ("key", "text", "default")

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        if not self.config.get("key"):
            raise ValueError("A setting key is required")


class Input(_Setting):
    pass


class Switch(_Setting):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        if "default" in self.config and type(self.config["default"]) is not bool:
            raise TypeError("Switch default must be bool")


class Selector(_Setting):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        items = self.config.get("items")
        if not isinstance(items, (list, tuple)) or not items or not all(isinstance(item, str) for item in items):
            raise TypeError("Selector requires nonempty text items")
        default = self.config.get("default", 0)
        if type(default) is not int or not 0 <= default < len(items):
            raise ValueError("Selector default is outside its items")
        self.config["items"] = list(items)
