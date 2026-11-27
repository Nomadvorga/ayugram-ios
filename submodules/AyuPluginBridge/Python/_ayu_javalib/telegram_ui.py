"""Python-local ``org.telegram.ui`` classes that can be expressed over host classes and operations.

``LayoutHelper`` asks the host for ``LayoutParams`` it builds itself. ``LaunchActivity`` exposes
the visible screen's context and fragment. With ``telegram.screen`` the fragment classes become
real Python types: ``get_last_fragment()`` returns a ``ChatActivity``, ``DialogsActivity`` or
``ProfileActivity`` wrapping the host's fragment adapter (every member the adapter has still
works), and a fragment a plugin constructs can be presented through ``telegram.navigation.open``.
Views, cells and everything a plugin would patch with a method hook are not modelled.
"""
from __future__ import annotations

from . import returns
from . import telegram_messenger as messenger
from . import telegram_tl as tl

PACKAGE = "org.telegram.ui."
_unsupported = tl._unsupported
_Java, _Meta = messenger._Java, messenger._Meta


def _runtime():
    from ayu_bridge import runtime
    return runtime


def _client():
    import client_utils
    return client_utils


def _is_rtl():
    return bool(_runtime().jclass("org.telegram.messenger.LocaleController").getInstance().isRTL())


def _absolute_gravity(gravity, rtl):
    """``Gravity.getAbsoluteGravity``."""
    start, end, relative = 0x00800003, 0x00800005, 0x00800000
    if not gravity & relative:
        return gravity
    if gravity & start == start:
        gravity = (gravity & ~start) | (5 if rtl else 3)
    elif gravity & end == end:
        gravity = (gravity & ~end) | (3 if rtl else 5)
    return gravity & ~relative


def _number(value, what):
    if type(value) not in (int, float) or value != value or abs(value) > 100_000:
        raise TypeError(f"{what} must be a bounded number")
    return value


class LayoutHelper(_Java):
    """``LayoutHelper``: frame and linear layout params, built by the host in one call.

    Sizes and margins are Android dp (negative sizes are MATCH_PARENT/WRAP_CONTENT); the host
    converts them, applies gravity and resolves start/end margins for its layout direction.
    """
    __ayu_requires__ = ("ui.layout_params",)
    MATCH_PARENT, WRAP_CONTENT = -1, -2

    @staticmethod
    def _params(kind, width, height, weight=None, gravity=None, margins=None, relative=False, pixels=False):
        arguments = {"kind": kind, "width": _number(width, "width"), "height": _number(height, "height")}
        if weight is not None:
            arguments["weight"] = float(_number(weight, "weight"))
        if gravity is not None:
            if type(gravity) is not int:
                raise TypeError("gravity must be an integer")
            arguments["gravity"] = gravity
        if margins is not None:
            if len(margins) != 4:
                raise TypeError("Four margins are required")
            arguments["margins"] = [_number(item, "margin") for item in margins]
        if relative:
            arguments["relative"] = True
        if pixels:
            arguments["margins_in_pixels"] = True
        result = _runtime().call("ui.layout_params", arguments)
        from ayu_bridge import ProtocolError, RemoteObject
        expected = "android.widget." + ("FrameLayout" if kind == "frame" else "LinearLayout") + "$LayoutParams"
        if not isinstance(result, RemoteObject) or result._class_name != expected:
            raise ProtocolError("ui.layout_params must return a LayoutParams reference")
        return result

    @staticmethod
    def getAbsoluteGravityStart():
        return 5 if _is_rtl() else 3

    @staticmethod
    def getAbsoluteGravityEnd():
        return 3 if _is_rtl() else 5

    @staticmethod
    def createFrame(width, height, gravity=None, *margins):
        """``createFrame(width, height[, gravity[, left, top, right, bottom]])``."""
        if margins and len(margins) != 4:
            raise TypeError("createFrame takes 2, 3 or 7 arguments")
        return LayoutHelper._params("frame", width, height, None, gravity, margins or None)

    @staticmethod
    def createFrameMarginPx(width, height, gravity, leftMarginPx, topMarginPx, rightMarginPx, bottomMarginPx):
        return LayoutHelper._params("frame", width, height, None, gravity,
                                    (leftMarginPx, topMarginPx, rightMarginPx, bottomMarginPx), pixels=True)

    @staticmethod
    def createFrameMatchParent():
        return LayoutHelper._params("frame", -1, -1)

    @staticmethod
    def createFrameRelatively(width, height, gravity, *margins):
        if margins and len(margins) != 4:
            raise TypeError("createFrameRelatively takes 3 or 7 arguments")
        return LayoutHelper._params("frame", width, height, None, gravity, margins or None, relative=True)

    @staticmethod
    def createLinear(width, height, *rest):
        """Android's ``createLinear`` overloads: a ``float`` third argument is the weight, an ``int`` the gravity."""
        count = len(rest)
        weight = gravity = margins = None
        if count in (1, 5):
            weight, gravity = (rest[0], None) if type(rest[0]) is float else (None, rest[0])
            margins = rest[1:] or None
        elif count in (2, 6):
            weight, gravity, margins = rest[0], rest[1], rest[2:] or None
        elif count == 4:
            margins = rest
        elif count:
            raise TypeError("createLinear does not take that many arguments")
        return LayoutHelper._params("linear", width, height, weight, gravity, margins)

    @staticmethod
    def createLinearRelatively(width, height, gravity, *margins):
        """Android hands the absolute gravity to ``LayoutParams(width, height, weight)``: it is the weight."""
        if margins and len(margins) != 4:
            raise TypeError("createLinearRelatively takes 3 or 7 arguments")
        if type(gravity) is not int:
            raise TypeError("gravity must be an integer")
        return LayoutHelper._params("linear", width, height, float(_absolute_gravity(gravity, _is_rtl())), None,
                                    margins or None, relative=True)


class _LaunchMeta(_Meta):
    @property
    def instance(cls):
        """The activity context of the visible screen, as the host models an Android ``Context``."""
        fragment = _client().get_last_fragment()
        return None if fragment is None else fragment.getParentActivity()


class LaunchActivity(_Java, metaclass=_LaunchMeta):
    """``LaunchActivity``: ``instance`` and the last fragment of the visible screen."""
    __ayu_requires__ = ("client.call",)

    @staticmethod
    def getLastFragment():
        return _client().get_last_fragment()

    getSafeLastFragment = getLastFragment

    def onActivityResult(self, requestCode, resultCode, data):
        """The method behind the ``activity.result`` hook point (``_ayu_xposed``).

        The bridge raises the point with the result of a picker the plugin started; nothing else
        runs behind it, so a direct call only runs the plugin's own hooks.
        """
        import _ayu_xposed
        _ayu_xposed.fire(_ayu_xposed.ACTIVITY_RESULT, self, [requestCode, resultCode, data])

    onActivityResult.__ayu_java_signature__ = (("int", "int", "android.content.Intent"), "void")


def _bundle_long(arguments, key):
    """A ``Bundle`` number by key (local or host ``Bundle``), 0 when absent."""
    if arguments is None:
        return 0
    if isinstance(arguments, dict):
        value = arguments.get(key, 0)
    else:
        value = arguments.getLong(key, 0) or arguments.getInt(key, 0)
    if type(value) is not int:
        raise TypeError(f"Bundle value {key} must be an integer")
    return value


class BaseFragment(_Java):
    """``BaseFragment``: the host's fragment adapter with a Python type, or a fragment to present.

    Replaces the host adapter and forwards every member it does not define to it.
    """
    __ayu_requires__ = ("client.call", "telegram.screen")
    __ayu_overrides_host__ = True
    _ayu_kind = None

    def __init__(self, args=None):
        values = self.__dict__
        values["arguments"], values["_host"], values["_info"] = args, None, None

    @classmethod
    def _ayu_current(cls):
        runtime = _runtime()
        info = runtime.call("telegram.screen", {})
        if info is None:
            return None
        if not isinstance(info, dict) or type(info.get("account")) is not int or not isinstance(info.get("kind"), str):
            from ayu_bridge import ProtocolError
            raise ProtocolError("Host returned an invalid screen description")
        host = runtime.call("client.call", {"name": "get_last_fragment", "args": [], "kwargs": {}})
        kind = {"chat": ChatActivity, "dialogs": DialogsActivity, "profile": ProfileActivity}.get(info["kind"], BaseFragment)
        fragment = object.__new__(kind)
        values = fragment.__dict__
        values["arguments"], values["_host"], values["_info"] = None, host, info
        return fragment

    def __getattr__(self, name):
        host = self.__dict__.get("_host")
        if host is None or name.startswith("_"):
            raise _unsupported(f"{type(self).__name__}.{name} is not available on a fragment that is not on screen")
        return getattr(host, name)

    def to_bridge(self):
        if self._host is None:
            raise _unsupported("A fragment that is not on screen cannot be passed to the host")
        return self._host

    def getArguments(self):
        return self.arguments

    def getCurrentAccount(self):
        if self._info is not None:
            return self._info["account"]
        return _client().get_selected_account()

    def getMessagesController(self):
        return _client().get_messages_controller(self.getCurrentAccount())

    def getUserConfig(self):
        return _client().get_user_config(self.getCurrentAccount())

    def getConnectionsManager(self):
        return _client().get_connections_manager(self.getCurrentAccount())

    def getSendMessagesHelper(self):
        return _client().get_send_messages_helper(self.getCurrentAccount())

    def getMessagesStorage(self):
        return _client().get_messages_storage(self.getCurrentAccount())

    def getAccountInstance(self):
        return _client().get_account_instance(self.getCurrentAccount())

    def presentFragment(self, fragment, *options):
        """Open a constructed chat/profile fragment or plugin settings; other fragments go to the host adapter."""
        target = getattr(fragment, "_ayu_present", None)
        if callable(target) and getattr(fragment, "_host", None) is None:
            target(self.getCurrentAccount())
            return True
        if self._host is None:
            raise _unsupported("presentFragment needs a fragment that is on screen")
        return self._host.presentFragment(fragment, *options)


class _Navigable(BaseFragment):
    __ayu_requires__ = ("client.call", "telegram.screen", "telegram.navigation.open", "telegram.peer")

    def _dialog(self):
        if self._info is not None:
            value = self._info.get("dialog_id", 0)
            if type(value) is not int:
                from ayu_bridge import ProtocolError
                raise ProtocolError("Host returned an invalid dialog id")
            return value
        user, chat = _bundle_long(self.arguments, "user_id"), _bundle_long(self.arguments, "chat_id")
        if _bundle_long(self.arguments, "enc_id"):
            raise _unsupported("Secret chats cannot be opened by a plugin")
        return user if user else -chat

    def getDialogId(self):
        return self._dialog()

    def _ayu_present(self, account):
        dialog_id = self._dialog()
        if dialog_id == 0:
            raise ValueError("The fragment has no user_id or chat_id argument")
        arguments = {"account": account, "dialog_id": dialog_id, "screen": self._ayu_kind}
        message_id = _bundle_long(self.arguments, "message_id")
        if message_id:
            arguments["message_id"] = message_id
        _runtime().call("telegram.navigation.open", arguments)


class ChatActivity(_Navigable):
    """``ChatActivity``: the visible chat (dialog, topic, peers) or a chat to open."""
    _ayu_kind = "chat"
    MODE_DEFAULT, MODE_SCHEDULED, MODE_PINNED, MODE_SAVED = 0, 1, 2, 3
    MODE_QUICK_REPLIES, MODE_EDIT_BUSINESS_LINK, MODE_SEARCH, MODE_SUGGESTIONS, MODE_WELCOME_MESSAGES = 5, 6, 7, 8, 9

    @staticmethod
    def of(dialogId, messageId=None):
        messenger._int(dialogId, 64, "dialogId")
        arguments = {"user_id": dialogId} if dialogId >= 0 else {"chat_id": -dialogId}
        if messageId is not None:
            arguments["message_id"] = messenger._int(messageId, 32, "messageId")
        return ChatActivity(arguments)

    def _controller(self):
        return messenger.MessagesController._ayu_usable().getInstance(self.getCurrentAccount())

    def getCurrentUser(self):
        dialog_id = self._dialog()
        return self._controller().getUser(dialog_id) if dialog_id > 0 else None

    def getCurrentChat(self):
        dialog_id = self._dialog()
        return self._controller().getChat(-dialog_id) if dialog_id < 0 else None

    def _number(self, key):
        if self._info is None:
            return 0
        value = self._info.get(key, 0)
        if type(value) is not int:
            from ayu_bridge import ProtocolError
            raise ProtocolError("Host returned an invalid chat screen value")
        return value

    def getTopicId(self):
        return self._number("topic_id")

    def getThreadId(self):
        return self._number("topic_id")

    def getChatMode(self):
        return self._number("chat_mode")

    def isThreadChat(self):
        return self._number("topic_id") != 0


class ProfileActivity(_Navigable):
    """``ProfileActivity``: the visible profile's dialog, or a profile to open."""
    _ayu_kind = "profile"


class DialogsActivity(BaseFragment):
    """``DialogsActivity``: the chat list as a fragment type; the dialog picker cannot be presented."""
    _ayu_kind = "dialogs"


def _mult_alpha(*args):
    """``Theme.multAlpha(color, multiply)``: the colour with its alpha scaled, as Android truncates and clamps it."""
    if len(args) != 2:
        raise TypeError("Theme.multAlpha takes (color, multiply)")
    color, multiply = args
    lang = messenger._l
    if not lang.is_int(color) or isinstance(multiply, bool) or not isinstance(multiply, (int, float)):
        raise TypeError("Theme.multAlpha takes (color, multiply)")
    color = lang.i32(color)
    if multiply == 1:
        return color
    scaled = lang.to_float32(((color >> 24) & 0xFF) * lang.to_float32(multiply))
    # Java's float-to-int cast: NaN is 0, the rest is truncated; then clamped to a byte.
    alpha = 0 if scaled != scaled else int(max(0.0, min(255.0, scaled)))
    return lang.i32((color & 0x00FFFFFF) | (alpha << 24))


def _dialog_listener(listener, method):
    """A Java dialog listener as a Python function: an implementation of ``method`` or, as Chaquopy converts one, a callable."""
    if listener is None:
        return None
    bound = getattr(listener, method, None)
    if callable(bound):
        return bound
    if callable(listener):
        return listener
    raise TypeError(f"Dialog listener must implement {method}")


def _unrendered(what):
    """A layout hint the host's dialog does not render: accepted, and logged once per plugin generation."""
    seen = messenger._l.scoped_store("dialog_hints")
    if what not in seen:
        seen[what] = True
        from android_utils import log
        log(f"AlertDialog: {what} is not rendered on iOS; the dialog keeps the host's layout.")


def _literal_style(arguments, index):
    """Whether literal constructor arguments leave the progress style at ``ALERT_TYPE_MESSAGE``."""
    return len(arguments) <= index or arguments[index] is ... or arguments[index] == 0


class AlertDialog(messenger._l.Object):
    """``org.telegram.ui.ActionBar.AlertDialog`` over the SDK's ``ui.alert`` presentation.

    The dialog is a description until ``show``; the host then presents one alert and answers
    ``isShowing``/``dismiss`` for it. Listeners receive this object as Android's ``dialog``.
    What ``ui.alert`` refuses is refused here the same way: a progress style (``ALERT_TYPE_LOADING``,
    ``ALERT_TYPE_SPINNER``) and changing a dialog that is on screen raise ``UNSUPPORTED_API``, and a
    red button is only logged. Members the host alert has no counterpart for (button views, the
    window, top images, cancel and back-button listeners) are not defined.
    """
    __ayu_overrides_host__ = True
    __ayu_requires__ = ("ui.present",)
    ALERT_TYPE_MESSAGE, ALERT_TYPE_LOADING, ALERT_TYPE_SPINNER = 0, 2, 3
    BUTTON_POSITIVE, BUTTON_NEGATIVE, BUTTON_NEUTRAL, BUTTON_NEGATIVE_2 = -1, -2, -3, -4
    _BUTTONS = {-1: "positive_button", -2: "negative_button", -3: "neutral_button"}

    def __init__(self, context, progressStyle, resourcesProvider=None):
        from ui.alert import AlertDialogBuilder
        if type(progressStyle) is not int:
            raise TypeError("AlertDialog takes (Context, int progressStyle[, ResourcesProvider])")
        presenter = AlertDialogBuilder(context, progressStyle, resourcesProvider)
        # ``ui.alert`` applies the cancel switches to a created dialog only.
        presenter.create()
        presenter.set_on_dismiss_listener(self._dismissed)
        self._presenter = presenter
        self._pre_dismiss = self._on_dismiss = None
        self._can_cancel = True

    @staticmethod
    def __ayu_constructs__(arguments):
        """Static preflight: whether a construction with these literal arguments (``...`` for any other) can succeed."""
        return _literal_style(arguments, 1)

    def _dismissed(self, presenter):
        # Android runs the dialog's own listener inside dismiss() and the Dialog one after it.
        for listener in (self._pre_dismiss, self._on_dismiss):
            if listener is not None:
                listener(self)

    def _button(self, button, text, listener):
        key = self._BUTTONS.get(button)
        if key is None:
            raise tl._unsupported("AlertDialog has no host button for id " + repr(button))
        click = _dialog_listener(listener, "onClick")
        if text is None:
            # Android shows no button without a text.
            self._presenter._set(key, None)
        else:
            self._presenter._button(key, text, None if click is None else lambda presenter, which: click(self, which))

    def getContext(self):
        return self._presenter.get_context()

    def show(self):
        self._presenter.show()

    def dismiss(self):
        self._presenter.dismiss()

    def cancel(self):
        # Dialog.cancel() tells the cancel listener, which cannot be set here, and dismisses.
        self._presenter.dismiss()

    def isShowing(self):
        return self._presenter.get_dialog().isShowing()

    def setTitle(self, text):
        self._presenter.set_title(text)

    def setMessage(self, text):
        self._presenter.set_message(text)

    def setMessageTextViewClickable(self, value):
        self._presenter.set_message_text_view_clickable(value)

    def setPositiveButton(self, text, listener):
        self._button(self.BUTTON_POSITIVE, text, listener)

    def setNegativeButton(self, text, listener):
        self._button(self.BUTTON_NEGATIVE, text, listener)

    def setNeutralButton(self, text, listener):
        self._button(self.BUTTON_NEUTRAL, text, listener)

    def setButton(self, type, text, listener):
        self._button(type, text, listener)

    def setOnDismissListener(self, listener):
        self._on_dismiss = _dialog_listener(listener, "onDismiss")

    def setCancelable(self, flag):
        self._presenter.set_cancelable(flag)

    def setCanceledOnTouchOutside(self, cancel):
        self._presenter.set_canceled_on_touch_outside(cancel)

    def setCanCancel(self, value):
        # Read by the progress styles' "stop loading?" prompt only.
        self._can_cancel = bool(value)

    def redPositive(self):
        self._presenter.make_button_red(self.BUTTON_POSITIVE)

    def makeRed(self, button):
        self._presenter.make_button_red(button)


class _AlertDialogBuilder(messenger._l.Object):
    """``AlertDialog.Builder``: every setter fills the dialog it will return and answers the builder."""
    __ayu_requires__ = ("ui.present",)

    def __init__(self, context, *arguments):
        # Builder(Context), Builder(Context, ResourcesProvider), Builder(Context, int progressViewStyle, ResourcesProvider)
        style, provider = arguments if len(arguments) == 2 else (0, *arguments) if len(arguments) == 1 else (0, None)
        if len(arguments) > 2 or type(style) is not int or type(provider) in (bool, int, float, str):
            raise TypeError("AlertDialog.Builder takes (Context[, [int progressViewStyle,] ResourcesProvider])")
        self._dialog = AlertDialog(context, style, provider)

    @staticmethod
    def __ayu_constructs__(arguments):
        return len(arguments) != 3 or _literal_style(arguments, 1)

    def getContext(self):
        return self._dialog.getContext()

    def setTitle(self, title):
        self._dialog.setTitle(title)
        return self

    def setMessage(self, message):
        self._dialog.setMessage(message)
        return self

    def setMessageTextViewClickable(self, value):
        self._dialog.setMessageTextViewClickable(value)
        return self

    def setPositiveButton(self, text, listener):
        self._dialog.setPositiveButton(text, listener)
        return self

    def setNegativeButton(self, text, listener):
        self._dialog.setNegativeButton(text, listener)
        return self

    def setNeutralButton(self, text, listener):
        self._dialog.setNeutralButton(text, listener)
        return self

    def setButton(self, button, text, listener):
        self._dialog.setButton(button, text, listener)
        return self

    def setItems(self, items, *arguments):
        # setItems(CharSequence[], OnClickListener), setItems(CharSequence[], int[] icons, OnClickListener)
        if len(arguments) not in (1, 2):
            raise TypeError("AlertDialog.Builder.setItems takes (items, [icons,] listener)")
        dialog, click = self._dialog, _dialog_listener(arguments[-1], "onClick")
        dialog._presenter.set_items(items, None if click is None else lambda presenter, which: click(dialog, which),
                                    arguments[0] if len(arguments) == 2 else None)
        return self

    def setView(self, view, height=-2):
        self._dialog._presenter.set_view(view, height)
        return self

    def setOnDismissListener(self, listener):
        self._dialog.setOnDismissListener(listener)
        return self

    def setOnPreDismissListener(self, listener):
        self._dialog._pre_dismiss = _dialog_listener(listener, "onDismiss")
        return self

    def setDimEnabled(self, enabled):
        self._dialog._presenter.set_dim_enabled(enabled)
        return self

    def setDimAlpha(self, alpha):
        _unrendered("the dim amount")
        return self

    def setDialogButtonColorKey(self, key):
        self._dialog._presenter.set_dialog_button_color_key(key)
        return self

    def setBlurredBackground(self, blur):
        self._dialog._presenter.set_blurred_background(blur)
        return self

    def setTopAnimationIsNew(self, value):
        self._dialog._presenter.set_top_animation_is_new(value)
        return self

    def setCustomViewOffset(self, offset):
        _unrendered("the custom view offset")
        return self

    def forceVerticalButtons(self):
        _unrendered("the vertical button layout")
        return self

    def setWidth(self, width):
        _unrendered("the custom width")
        return self

    def makeCustomMaxHeight(self):
        _unrendered("the custom maximum height")
        return self

    def makeRed(self, button):
        self._dialog.makeRed(button)
        return self

    @returns(AlertDialog)
    def create(self):
        return self._dialog

    @returns(AlertDialog)
    def show(self):
        self._dialog.show()
        return self._dialog


class _OnButtonClickListener(messenger._l.Object):
    """``AlertDialog.OnButtonClickListener``: ``onClick(dialog, which)``."""

    def onClick(self, dialog, which):
        raise messenger._l.missing_member(type(self), "onClick")


AlertDialog.Builder = _AlertDialogBuilder
AlertDialog.OnButtonClickListener = _OnButtonClickListener

# Pure functions of host classes.
HOST_MEMBERS = {PACKAGE + "ActionBar.Theme": {"multAlpha": _mult_alpha}}

CLASSES = {
    PACKAGE + "Components.LayoutHelper": LayoutHelper,
    PACKAGE + "LaunchActivity": LaunchActivity,
    PACKAGE + "ActionBar.BaseFragment": BaseFragment,
    PACKAGE + "ChatActivity": ChatActivity,
    PACKAGE + "ProfileActivity": ProfileActivity,
    PACKAGE + "DialogsActivity": DialogsActivity,
    PACKAGE + "ActionBar.AlertDialog": AlertDialog,
    PACKAGE + "ActionBar.AlertDialog$Builder": _AlertDialogBuilder,
    PACKAGE + "ActionBar.AlertDialog$OnButtonClickListener": _OnButtonClickListener,
}
messenger._l.register(CLASSES)
