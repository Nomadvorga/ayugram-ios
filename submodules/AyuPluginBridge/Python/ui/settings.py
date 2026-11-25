"""Android SDK row constructors with native-owned serialization and callbacks."""
from __future__ import annotations

from ayu_bridge import UnsupportedAPI, runtime


class _Component:
    bridge_type = None
    positional = ()
    defaults = {}
    required = ()
    # Existing bridge extensions remain accepted as keywords.
    extensions = frozenset({"enabled", "input_type", "multiline", "hint", "destructive"})
    callbacks = ("on_click", "on_change", "on_long_click", "create_sub_fragment")

    def __init__(self, *args, **config):
        object.__setattr__(self, "_scope", runtime.require())
        if len(args) > len(self.positional):
            raise TypeError(f"Too many positional arguments for {type(self).__name__}")
        for name, value in zip(self.positional, args):
            if name in config:
                raise TypeError(f"Duplicate component argument: {name}")
            config[name] = value
        unknown = set(config) - set(self.positional) - self.extensions
        if unknown:
            raise TypeError("Unsupported setting options: " + ", ".join(sorted(unknown)))
        missing = [name for name in self.required if name not in config]
        if missing:
            raise TypeError("Missing setting arguments: " + ", ".join(missing))
        object.__setattr__(self, "config", {**self.defaults, **config})
        self._validate()

    @property
    def type(self):
        return self.bridge_type.lower()

    def __getattr__(self, name):
        config = self.__dict__.get("config", {})
        if name in config:
            return config[name]
        raise AttributeError(name)

    def __setattr__(self, name, value):
        if name in self.positional or name in self.extensions:
            self.config[name] = value
        else:
            object.__setattr__(self, name, value)

    def _validate(self):
        for callback in self.callbacks:
            value = self.config.get(callback)
            if value is not None and not callable(value):
                raise TypeError(f"{callback} must be callable")
        for name in ("text", "subtext", "icon", "key", "hint", "link_alias"):
            if name in self.config and self.config[name] is not None and not isinstance(self.config[name], str):
                raise TypeError(f"{name} must be text")
        if "text" in self.required and not isinstance(self.config.get("text"), str):
            raise TypeError("text must be text")
        for name in ("accent", "red", "destructive", "enabled", "multiline"):
            if name in self.config and type(self.config[name]) is not bool:
                raise TypeError(f"{name} must be bool")

    def to_bridge(self):
        runtime.require(self._scope)
        self._validate()
        config = {name: value for name, value in self.config.items() if value is not None}
        if "red" in config:
            config["destructive"] = config.pop("red") or config.get("destructive", False)
        # Native protocol names deliberately differ from Android's lowercase
        # `type` attributes. Preserve the existing renderer's wire contract.
        return {"type": self.bridge_type, **config}


class Header(_Component):
    bridge_type = "Header"
    positional = ("text",)
    required = ("text",)


class Divider(_Component):
    bridge_type = "Divider"
    positional = ("text",)
    defaults = {"text": None}


class Text(_Component):
    bridge_type = "Text"
    positional = ("text", "subtext", "icon", "accent", "red", "on_click",
                  "create_sub_fragment", "on_long_click", "link_alias")
    required = ("text",)
    defaults = {"subtext": None, "icon": None, "accent": False, "red": False,
                "on_click": None, "create_sub_fragment": None,
                "on_long_click": None, "link_alias": None}


class _Setting(_Component):
    required = ("key", "text")

    def _validate(self):
        super()._validate()
        key = self.config.get("key")
        if not isinstance(key, str) or not key or len(key.encode("utf-8")) > 256:
            raise ValueError("A bounded setting key is required")


class Input(_Setting):
    bridge_type = "Input"
    positional = ("key", "text", "default", "subtext", "icon", "on_change",
                  "on_long_click", "link_alias")
    defaults = {"default": "", "subtext": None, "icon": None, "on_change": None,
                "on_long_click": None, "link_alias": None}

    def _validate(self):
        super()._validate()
        if not isinstance(self.config.get("default"), str):
            raise TypeError("Input default must be text")


class Switch(_Setting):
    bridge_type = "Switch"
    positional = ("key", "text", "default", "subtext", "icon", "on_change",
                  "on_long_click", "link_alias")
    required = ("key", "text", "default")
    defaults = {"subtext": None, "icon": None, "on_change": None,
                "on_long_click": None, "link_alias": None}

    def _validate(self):
        super()._validate()
        if type(self.config.get("default")) is not bool:
            raise TypeError("Switch default must be bool")


class Selector(_Setting):
    bridge_type = "Selector"
    positional = ("key", "text", "default", "items", "icon", "on_change",
                  "on_long_click", "link_alias")
    required = ("key", "text", "default", "items")
    defaults = {"icon": None, "on_change": None, "on_long_click": None, "link_alias": None}

    def _validate(self):
        super()._validate()
        items = self.config.get("items")
        if not isinstance(items, (list, tuple)) or not items or not all(isinstance(item, str) for item in items):
            raise TypeError("Selector requires nonempty text items")
        default = self.config.get("default")
        if type(default) is not int or not 0 <= default < len(items):
            raise ValueError("Selector default is outside its items")
        self.config["items"] = list(items)


class EditText(_Setting):
    bridge_type = "EditText"
    positional = ("key", "hint", "default", "multiline", "max_length", "mask", "on_change")
    required = ("key", "hint")
    defaults = {"default": "", "multiline": False, "max_length": 256,
                "mask": None, "on_change": None}

    @property
    def type(self):
        return "edit_text"

    def to_bridge(self):
        runtime.require(self._scope)
        raise UnsupportedAPI("EditText settings require a native editor adapter")


class Custom:
    def __init__(self, item=None, view=None, factory=None, factory_args=None,
                 on_click=None, on_long_click=None, create_sub_fragment=None,
                 link_alias=None):
        runtime.require()
        raise UnsupportedAPI("Custom Android settings require a native view adapter")


class SimpleSettingFactory:
    def __init__(self, create_view, bind_view, *, is_clickable=False, is_shadow=False,
                 create_item=None, on_click=None, on_long_click=None,
                 attached_view=None, equals=None, content_equals=None):
        runtime.require()
        raise UnsupportedAPI("Android setting factories require a native view adapter")
