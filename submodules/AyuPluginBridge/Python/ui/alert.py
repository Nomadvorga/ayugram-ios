"""Android-compatible basic alerts backed by an owned native presentation."""
from ayu_bridge import RemoteObject, UnsupportedAPI, runtime


class AlertDialogBuilder:
    ALERT_TYPE_MESSAGE = 0
    ALERT_TYPE_LOADING = 2
    ALERT_TYPE_SPINNER = 3
    BUTTON_POSITIVE = -1
    BUTTON_NEGATIVE = -2
    BUTTON_NEUTRAL = -3

    def __init__(self, context, progress_style=ALERT_TYPE_MESSAGE, resources_provider=None):
        self._scope = runtime.require()
        if type(progress_style) is not int or progress_style != self.ALERT_TYPE_MESSAGE or resources_provider is not None:
            raise UnsupportedAPI("Progress dialogs and Android resource providers require a native adapter")
        self.config = {"context": context}
        self._dialog = None
        self._released = False

    def get_context(self):
        runtime.require(self._scope)
        return self.config["context"]

    def _set(self, key, value):
        runtime.require(self._scope)
        if self._dialog is not None or self._released:
            raise UnsupportedAPI("Changing an already presented dialog requires a native adapter")
        self.config[key] = value
        return self

    def set_title(self, title):
        return self._set("title", str(title))

    def set_message(self, message):
        return self._set("message", str(message))

    def _listener(self, listener):
        if listener is None:
            return None
        if not callable(listener):
            raise TypeError("Dialog listener must be callable or None")

        def invoke(dialog, which):
            runtime.require(self._scope)
            self._released = True
            return listener(self, which)

        return invoke

    def set_items(self, items, listener=None, icons=None):
        if icons is not None:
            raise UnsupportedAPI("Android item icons require a native adapter")
        labels = list(items)
        if not 1 <= len(labels) <= 32 or not all(isinstance(item, str) and item for item in labels):
            raise ValueError("Dialog items must contain 1 to 32 nonempty labels")
        return self._set("items", {"labels": labels, "on_click": self._listener(listener)})

    def _button(self, key, text, listener):
        return self._set(key, {"text": str(text), "on_click": self._listener(listener)})

    def set_positive_button(self, text, listener=None):
        return self._button("positive_button", text, listener)

    def set_negative_button(self, text, listener=None):
        return self._button("negative_button", text, listener)

    def set_neutral_button(self, text, listener=None):
        return self._button("neutral_button", text, listener)

    def set_view(self, view, height=-2):
        runtime.require(self._scope)
        raise UnsupportedAPI("Custom Android dialog views require a native adapter")

    def set_cancelable(self, value):
        if type(value) is not bool:
            raise TypeError("cancelable must be a bool")
        return self._set("cancelable", value)

    def show(self):
        runtime.require(self._scope)
        if self._released:
            raise UnsupportedAPI("A dismissed dialog cannot be shown again; create a new builder")
        if self._dialog is None:
            result = runtime.call("ui.present", {"kind": "alert", "config": self.config})
            if not isinstance(result, RemoteObject):
                raise UnsupportedAPI("Host did not return an owned dialog")
            self._dialog = result
        return self

    def dismiss(self):
        runtime.require(self._scope)
        if self._dialog is not None and not self._released:
            self._dialog.dismiss()
            self._released = True

    def get_dialog(self):
        runtime.require(self._scope)
        return self._dialog
