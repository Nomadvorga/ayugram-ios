from ayu_bridge import runtime


class BulletinHelper:
    @staticmethod
    def _show(style, text, **kwargs):
        return runtime.call("ui.present", {"kind": "bulletin", "config": {
            "style": style, "text": str(text), **kwargs}})

    @staticmethod
    def show_success(text, **kwargs):
        return BulletinHelper._show("success", text, **kwargs)

    @staticmethod
    def show_error(text, **kwargs):
        return BulletinHelper._show("error", text, **kwargs)

    @staticmethod
    def show_simple(text, **kwargs):
        return BulletinHelper._show("simple", text, **kwargs)
