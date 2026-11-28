"""Android's ``BulletinHelper`` over the host's bulletin presentation.

The host draws three bulletin styles (simple, success, error) with optional
duration and one button. An ``icon_res_id`` is ``0`` or, on a host that declares
``resources.resolve``, ``R.raw.<name>``/``R.drawable.<name>``: the host shows its
own still icon for that name and refuses a name it does not map (Android's
Lottie animations are not played). Any other integer raises ``UNSUPPORTED_API``.
The stock "copied" and "saved" bulletins use fixed English texts instead of
Telegram's localized Android strings.
"""
from ayu_bridge import UnsupportedAPI, runtime


class BulletinHelper:
    DURATION_SHORT = 1500
    DURATION_LONG = 2750
    DURATION_PROLONG = 5000

    @staticmethod
    def _show(style, text, fragment=None, duration=None, button_text=None, on_click=None, icon=None):
        scope = runtime.require()
        config = {"style": style, "text": str(text)}
        if icon is not None:
            config["icon"] = icon
        if fragment is not None:
            config["fragment"] = fragment
        reference = None
        if duration is not None:
            if type(duration) is not int or not 1 <= duration <= 10_000:
                raise ValueError("Bulletin duration must be 1 to 10000 milliseconds")
            config["duration_ms"] = duration
        if button_text is not None:
            if not isinstance(button_text, str) or not button_text or len(button_text.encode("utf-8")) > 256:
                raise ValueError("Bulletin button text must be bounded nonempty text")
            if on_click is not None and not callable(on_click):
                raise TypeError("Bulletin button callback must be callable or None")
            reference = runtime.callback(on_click, once=True) if on_click is not None else None
            config["button"] = {"text": button_text, "on_click": reference}
        try:
            return runtime.call("ui.present", {"kind": "bulletin", "config": config})
        except BaseException:
            if reference is not None:
                scope.callbacks.pop(reference.callback_id, None)
            raise

    @staticmethod
    def _icon(icon_res_id):
        """The wire form of a bulletin icon: None for ``0``, a resource-id object for ``R.<kind>.<name>``."""
        if type(icon_res_id) is int and icon_res_id == 0:
            return None
        resource = getattr(icon_res_id, "to_bridge", None)
        if isinstance(icon_res_id, int) and callable(resource) and "resources.resolve" in runtime.capabilities["operations"]:
            return resource()
        raise UnsupportedAPI("Android bulletin icons require a native adapter")

    @classmethod
    def show_info(cls, message, fragment=None):
        return cls._show("simple", message, fragment)

    @classmethod
    def show_error(cls, message, fragment=None):
        return cls._show("error", message, fragment)

    @classmethod
    def show_success(cls, message, fragment=None):
        return cls._show("success", message, fragment)

    @classmethod
    def show_simple(cls, text, icon_res_id=0, fragment=None):
        return cls._show("simple", text, fragment, icon=cls._icon(icon_res_id))

    @classmethod
    def show_two_line(cls, title, subtitle, icon_res_id, fragment=None):
        return cls._show("simple", str(title) + "\n" + str(subtitle), fragment, icon=cls._icon(icon_res_id))

    @classmethod
    def show_with_button(cls, text, icon_res_id, button_text, on_click, fragment=None, duration=DURATION_PROLONG):
        return cls._show("simple", text, fragment, duration, button_text, on_click, icon=cls._icon(icon_res_id))

    @classmethod
    def show_undo(cls, text, on_undo, on_action=None, subtitle=None, fragment=None):
        """An undo bulletin: ``on_action`` runs once the bulletin expires without an undo."""
        if not callable(on_undo) or on_action is not None and not callable(on_action):
            raise TypeError("Undo callbacks must be callable")
        pending = []

        def undo():
            for registration in pending:
                registration.cancel()
            del pending[:]
            on_undo()

        def expire():
            del pending[:]
            on_action()

        if on_action is not None:
            pending.append(runtime.schedule(expire, queue="main", delay=cls.DURATION_PROLONG))
        try:
            return cls._show("simple", str(text) + ("\n" + str(subtitle) if subtitle else ""), fragment,
                             cls.DURATION_PROLONG, "Undo", undo)
        except BaseException:
            for registration in pending:
                registration.cancel()
            raise

    @classmethod
    def show_copied_to_clipboard(cls, message=None, fragment=None):
        """Show copy feedback only; clipboard access remains a separate host call."""
        return cls._show("simple", "Copied to clipboard" if message is None else message, fragment)

    @classmethod
    def show_link_copied(cls, is_private_link_info=False, fragment=None):
        text = "This link will only work for members of this chat." if is_private_link_info \
            else "Link copied to clipboard."
        return cls._show("simple", text, fragment)

    @classmethod
    def show_file_saved_to_gallery(cls, is_video=False, amount=1, fragment=None):
        kind = "video" if is_video else "photo"
        text = f"{amount} {kind}s saved to gallery" if amount > 1 else f"{kind.capitalize()} saved to gallery"
        return cls._show("simple", text, fragment)

    @classmethod
    def show_file_saved_to_downloads(cls, file_type_enum_name="UNKNOWN", amount=1, fragment=None):
        text = f"{amount} files saved to downloads" if amount > 1 else "File saved to downloads"
        return cls._show("simple", text, fragment)
