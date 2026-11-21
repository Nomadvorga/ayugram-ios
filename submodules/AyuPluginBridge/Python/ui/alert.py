"""Fluent alert descriptor; show always delegates to a declared native adapter."""
from ayu_bridge import runtime


class AlertDialogBuilder:
    def __init__(self, context, *args, **kwargs):
        if args or kwargs:
            raise TypeError("Unsupported AlertDialogBuilder constructor options")
        self._scope = runtime.require()
        self.config = {"context": context}

    def _set(self, key, value):
        runtime.require(self._scope)
        self.config[key] = value
        return self

    def set_title(self, title):
        return self._set("title", str(title))

    def set_message(self, message):
        return self._set("message", str(message))

    def set_items(self, items, on_click):
        if not callable(on_click):
            raise TypeError("Item callback must be callable")
        return self._set("items", {"labels": list(items), "on_click": on_click})

    def _button(self, key, text, on_click):
        if on_click is not None and not callable(on_click):
            raise TypeError("Button callback must be callable or None")
        return self._set(key, {"text": str(text), "on_click": on_click})

    def set_positive_button(self, text, on_click=None):
        return self._button("positive_button", text, on_click)

    def set_negative_button(self, text, on_click=None):
        return self._button("negative_button", text, on_click)

    def set_neutral_button(self, text, on_click=None):
        return self._button("neutral_button", text, on_click)

    def set_view(self, view):
        return self._set("view", view)

    def set_cancelable(self, value):
        return self._set("cancelable", bool(value))

    def show(self):
        runtime.require(self._scope)
        return runtime.call("ui.present", {"kind": "alert", "config": self.config})
