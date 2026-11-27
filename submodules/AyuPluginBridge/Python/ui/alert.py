"""Android's ``AlertDialogBuilder`` over the host's owned alert presentation.

The builder is a local descriptor; each ``show`` of a dialog that is not on
screen performs one ``ui.present``. The host draws a system alert, so dim,
blur, button colour key, resources provider and custom view height have no
visual effect, and a button marked red keeps its default colour (logged once
per plugin generation). What the host cannot present or report raises
``UNSUPPORTED_API``: progress styles, item icons, top images and animations,
clickable message links, cancel and back-button listeners, and changing a
dialog that is already on screen.

The host calls back for the buttons and items the plugin set. It does not
call back when the user closes a dialog another way (the Cancel button the
host adds to a cancelable alert without a negative button, a tap outside a
custom-view dialog), but its owned dialog answers ``isShowing``. The builder
asks before it relies on the dialog being on screen, so such a dismissal is
noticed, and the dismiss listener runs, the next time the plugin uses the
builder or its dialog; it cannot be told apart from any other dismissal.

Android releases the Java dialog after a dismissal and logs instead of showing
it once that object is collected. The builder here keeps its description, so
``show`` after a dismissal presents the dialog again.
"""
from ayu_bridge import BridgeError, RemoteObject, UnsupportedAPI, runtime


def _log(message):
    from android_utils import log
    log(message)


def _text(value):
    """Android accepts any CharSequence; the host alert takes plain text."""
    if isinstance(value, RemoteObject):
        value = value.toString()
    return str(value)


class _AlertDialog:
    """The members of Android's ``AlertDialog`` this bridge can honour."""

    def __init__(self, builder):
        self._builder = builder

    def show(self):
        self._builder.show()

    def dismiss(self):
        self._builder.dismiss()

    cancel = dismiss

    def isShowing(self):
        return self._builder._on_screen()

    def setCancelable(self, cancelable):
        self._builder.set_cancelable(cancelable)

    def setCanceledOnTouchOutside(self, cancel):
        self._builder.set_canceled_on_touch_outside(cancel)

    def setProgress(self, progress):
        self._builder.set_progress(progress)

    def __getattr__(self, name):
        if name.startswith("_"):
            raise AttributeError(name)
        raise UnsupportedAPI(f"AlertDialog.{name} requires a native dialog adapter")


class AlertDialogBuilder:
    ALERT_TYPE_MESSAGE = 0
    ALERT_TYPE_LOADING = 2
    ALERT_TYPE_SPINNER = 3

    BUTTON_POSITIVE = -1
    BUTTON_NEGATIVE = -2
    BUTTON_NEUTRAL = -3

    def __init__(self, context, progress_style=ALERT_TYPE_MESSAGE, resources_provider=None):
        self._scope = runtime.require()
        if type(progress_style) is not int or progress_style != self.ALERT_TYPE_MESSAGE:
            raise UnsupportedAPI("Progress dialogs require a native adapter")
        self._context = context
        self._progress_style = progress_style
        self.config = {"context": context}
        self._alert_dialog = None
        self._native = None
        self._showing = False
        self._clicking = False
        self._callback_ids = set()
        self._cancelable = True
        self._canceled_on_touch_outside = True
        self._presented_cancelable = None
        self._on_dismiss = None

    def get_context(self):
        runtime.require(self._scope)
        return self._context

    def _set(self, key, value):
        runtime.require(self._scope)
        if self._on_screen():
            raise UnsupportedAPI("Changing a dialog that is on screen requires a native adapter")
        if value is None:
            self.config.pop(key, None)
        else:
            self.config[key] = value
        return self

    def set_title(self, title):
        return self._set("title", None if title is None else _text(title))

    def set_message(self, message):
        return self._set("message", None if message is None else _text(message))

    def set_message_text_view_clickable(self, clickable):
        runtime.require(self._scope)
        if clickable:
            raise UnsupportedAPI("Clickable dialog message links require a native adapter")
        return self

    def _on_screen(self):
        """Whether the dialog is on screen, noticing a dismissal the host did not call back for."""
        runtime.require(self._scope)
        # Android delivers a click while the dialog is still showing and closes it afterwards.
        if self._showing and not self._clicking and self._native.isShowing() is not True:
            self._finish()
        return self._showing

    def _finish(self):
        """The dialog left the screen: release its callbacks and report the dismissal."""
        if not self._showing:
            return
        self._showing = False
        self._native = None
        scope = runtime.require(self._scope)
        for callback_id in self._callback_ids:
            scope.callbacks.pop(callback_id, None)
        self._callback_ids = set()
        listener = self._on_dismiss
        if listener is not None:
            try:
                listener(self)
            except BridgeError:
                raise
            except Exception as error:
                _log("Error in AlertDialog DismissListener: " + type(error).__name__)

    def _listener(self, listener, name):
        if listener is not None and not callable(listener):
            raise TypeError("Dialog listener must be callable or None")

        def invoke(dialog=None, which=None):
            runtime.require(self._scope)
            self._clicking = True
            try:
                if listener is not None:
                    listener(self, which)
            except BridgeError:
                raise
            except Exception as error:
                _log(f"Error in AlertDialog {name}: {type(error).__name__}")
            finally:
                self._clicking = False
                # Android closes the dialog after a button or item click.
                self._finish()

        return invoke

    def _button(self, key, text, listener):
        return self._set(key, {"text": _text(text), "on_click": self._listener(listener, "ButtonClickListener")})

    def set_positive_button(self, text, listener=None):
        return self._button("positive_button", text, listener)

    def set_negative_button(self, text, listener=None):
        return self._button("negative_button", text, listener)

    def set_neutral_button(self, text, listener=None):
        return self._button("neutral_button", text, listener)

    def make_button_red(self, button_type):
        """Accepted without visual effect: the host alert has no way to colour a button.

        Android passes the id to ``AlertDialog.getButton(int)``, which refuses anything but a
        Java int and ignores an id that names no button. The dialog works as before; the
        missing styling is logged once per plugin generation.
        """
        scope = runtime.require(self._scope)
        if type(button_type) is not int:
            raise TypeError("Button type must be an int")
        if not -2 ** 31 <= button_type < 2 ** 31:
            raise OverflowError("Button type does not fit a Java int")
        if not scope.__dict__.get("_ayu_alert_red_logged"):
            scope.__dict__["_ayu_alert_red_logged"] = True
            _log("AlertDialogBuilder: red button styling is not rendered on iOS; the button keeps its default colour.")
        return self

    def _unreported(self, listener, what):
        """A listener for an event the host never reports: only ``None`` (no listener) is accepted."""
        runtime.require(self._scope)
        if listener is None:
            return self
        if not callable(listener):
            raise TypeError("Dialog listener must be callable or None")
        raise UnsupportedAPI(f"Dialog {what} listeners require a native adapter")

    def set_on_back_button_listener(self, listener=None):
        return self._unreported(listener, "back-button")

    def set_view(self, view, height=-2):
        if view is not None and not isinstance(view, RemoteObject):
            raise UnsupportedAPI("A dialog view must be a view owned by the native host")
        return self._set("view", view)

    def set_items(self, items, listener=None, icons=None):
        if icons:
            raise UnsupportedAPI("Android item icons require a native adapter")
        labels = [_text(item) for item in items]
        if not 1 <= len(labels) <= 32 or not all(labels):
            raise ValueError("Dialog items must contain 1 to 32 nonempty labels")
        return self._set("items", {"labels": labels, "on_click": self._listener(listener, "ItemsClickListener")})

    def set_on_dismiss_listener(self, listener=None):
        runtime.require(self._scope)
        if listener is not None and not callable(listener):
            raise TypeError("Dialog listener must be callable or None")
        self._on_dismiss = listener
        return self

    def set_on_cancel_listener(self, listener=None):
        return self._unreported(listener, "cancel")

    def set_top_image(self, res_id, background_color):
        runtime.require(self._scope)
        raise UnsupportedAPI("Dialog top images require a native adapter")

    def set_top_drawable(self, drawable, background_color):
        runtime.require(self._scope)
        raise UnsupportedAPI("Dialog top images require a native adapter")

    def set_top_animation(self, res_id, size, auto_repeat, background_color, layer_colors=None):
        runtime.require(self._scope)
        raise UnsupportedAPI("Dialog top animations require a native adapter")

    def set_top_animation_is_new(self, is_new):
        runtime.require(self._scope)
        return self

    def set_dim_enabled(self, enabled):
        runtime.require(self._scope)
        return self

    def set_dialog_button_color_key(self, theme_key):
        runtime.require(self._scope)
        return self

    def set_blurred_background(self, blur, blur_behind_if_possible=True):
        runtime.require(self._scope)
        return self

    def create(self):
        """Android builds the dialog without showing it; here it becomes addressable."""
        runtime.require(self._scope)
        if self._alert_dialog is None:
            self._alert_dialog = _AlertDialog(self)
        return self

    def _effective_cancelable(self):
        # iOS has no back button: both Android switches mean dismissal by an outside tap.
        return self._cancelable and self._canceled_on_touch_outside

    def show(self):
        scope = runtime.require(self._scope)
        # Android leaves a dialog that is on screen alone and shows one that is not.
        if self._on_screen():
            return self
        self.create()
        config = dict(self.config)
        if not self._effective_cancelable():
            config["cancelable"] = False
        before = set(scope.callbacks)
        result = runtime.call("ui.present", {"kind": "alert", "config": config})
        self._callback_ids = set(scope.callbacks) - before
        if not isinstance(result, RemoteObject):
            for callback_id in self._callback_ids:
                scope.callbacks.pop(callback_id, None)
            self._callback_ids = set()
            raise UnsupportedAPI("Host did not return an owned dialog")
        self._native = result
        self._presented_cancelable = self._effective_cancelable()
        self._showing = True
        return self

    def dismiss(self):
        runtime.require(self._scope)
        if self._showing:
            try:
                # The host ignores this for a dialog the user already closed.
                self._native.dismiss()
            finally:
                self._finish()

    def get_dialog(self):
        runtime.require(self._scope)
        return self._alert_dialog

    def get_button(self, button_type):
        runtime.require(self._scope)
        if self._alert_dialog is None:
            return None
        raise UnsupportedAPI("Dialog button views require a native adapter")

    def set_progress(self, progress):
        runtime.require(self._scope)
        if self._alert_dialog is None:
            _log("AlertDialogBuilder: set_progress called before dialog is created.")

    def _changed_cancel_policy(self):
        if self._on_screen() and self._effective_cancelable() != self._presented_cancelable:
            raise UnsupportedAPI("Changing a dialog that is on screen requires a native adapter")

    def set_cancelable(self, cancelable):
        runtime.require(self._scope)
        if self._alert_dialog is None:
            _log("AlertDialogBuilder: set_cancelable is best called after create() or show().")
            return
        previous, self._cancelable = self._cancelable, bool(cancelable)
        try:
            self._changed_cancel_policy()
        except UnsupportedAPI:
            self._cancelable = previous
            raise

    def set_canceled_on_touch_outside(self, cancel):
        runtime.require(self._scope)
        if self._alert_dialog is None:
            _log("AlertDialogBuilder: set_canceled_on_touch_outside is best called after create() or show().")
            return
        previous, self._canceled_on_touch_outside = self._canceled_on_touch_outside, bool(cancel)
        try:
            self._changed_cancel_policy()
        except UnsupportedAPI:
            self._canceled_on_touch_outside = previous
            raise
