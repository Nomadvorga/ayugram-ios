from ayu_bridge import UnsupportedAPI, runtime


class BulletinHelper:
    DURATION_SHORT = 1500
    DURATION_LONG = 2750
    DURATION_PROLONG = 5000

    @staticmethod
    def _show(style, text, fragment=None):
        config = {"style": style, "text": str(text)}
        if fragment is not None:
            config["fragment"] = fragment
        return runtime.call("ui.present", {"kind": "bulletin", "config": config})

    @staticmethod
    def show_success(message, fragment=None):
        return BulletinHelper._show("success", message, fragment)

    @staticmethod
    def show_error(message, fragment=None):
        return BulletinHelper._show("error", message, fragment)

    @staticmethod
    def show_info(message, fragment=None):
        return BulletinHelper._show("simple", message, fragment)

    @staticmethod
    def show_simple(text, icon_res_id=0, fragment=None):
        if type(icon_res_id) is not int or icon_res_id != 0:
            raise UnsupportedAPI("Android bulletin icons require a native adapter")
        return BulletinHelper._show("simple", text, fragment)

    @staticmethod
    def show_copied_to_clipboard(message=None, fragment=None):
        """Show copy feedback only; clipboard access remains a separate host call."""
        return BulletinHelper._show("simple", "Copied to clipboard" if message is None else message, fragment)

    @staticmethod
    def show_with_button(text, icon_res_id, button_text, on_click, fragment=None, duration=DURATION_PROLONG):
        if type(icon_res_id) is not int or icon_res_id != 0:
            raise UnsupportedAPI("Android bulletin icons require a native adapter")
        if not isinstance(button_text, str) or not button_text or len(button_text.encode("utf-8")) > 256:
            raise ValueError("Bulletin button text must be bounded nonempty text")
        if on_click is not None and not callable(on_click):
            raise TypeError("Bulletin button callback must be callable or None")
        if type(duration) is not int or not 1 <= duration <= 10_000:
            raise ValueError("Bulletin duration must be 1 to 10000 milliseconds")
        scope = runtime.require()
        reference = runtime.callback(on_click, once=True) if on_click is not None else None
        config = {"style": "simple", "text": str(text), "duration_ms": duration,
                  "button": {"text": button_text, "on_click": reference}}
        if fragment is not None:
            config["fragment"] = fragment
        try:
            return runtime.call("ui.present", {"kind": "bulletin", "config": config})
        except BaseException:
            if reference is not None:
                scope.callbacks.pop(reference.callback_id, None)
            raise

    @staticmethod
    def show_two_line(title, subtitle, icon_res_id, fragment=None):
        if type(icon_res_id) is not int or icon_res_id != 0:
            raise UnsupportedAPI("Android bulletin icons require a native adapter")
        return BulletinHelper._show("simple", str(title) + "\n" + str(subtitle), fragment)
