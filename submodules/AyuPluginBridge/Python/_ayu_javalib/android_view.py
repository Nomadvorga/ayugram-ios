"""``android.view.WindowManager`` and its ``LayoutParams``: the constants and the value holder.

Only the data side is here: reaching a window (the activity's window or
the window service) stays a host matter and is not provided.
"""
from __future__ import annotations

from . import java_lang as _l
from .java_lang import Object

_OPAQUE = -1  # PixelFormat.OPAQUE


class LayoutParams(Object):
    FILL_PARENT = MATCH_PARENT = -1
    WRAP_CONTENT = -2

    FIRST_APPLICATION_WINDOW = TYPE_BASE_APPLICATION = 1
    TYPE_APPLICATION, TYPE_APPLICATION_STARTING, TYPE_DRAWN_APPLICATION, LAST_APPLICATION_WINDOW = 2, 3, 4, 99
    FIRST_SUB_WINDOW = TYPE_APPLICATION_PANEL = 1000
    TYPE_APPLICATION_MEDIA, TYPE_APPLICATION_SUB_PANEL, TYPE_APPLICATION_ATTACHED_DIALOG = 1001, 1002, 1003
    LAST_SUB_WINDOW = 1999
    FIRST_SYSTEM_WINDOW = TYPE_STATUS_BAR = 2000
    TYPE_SEARCH_BAR, TYPE_PHONE, TYPE_SYSTEM_ALERT, TYPE_KEYGUARD, TYPE_TOAST = 2001, 2002, 2003, 2004, 2005
    TYPE_SYSTEM_OVERLAY, TYPE_PRIORITY_PHONE, TYPE_SYSTEM_DIALOG, TYPE_KEYGUARD_DIALOG = 2006, 2007, 2008, 2009
    TYPE_SYSTEM_ERROR, TYPE_INPUT_METHOD, TYPE_INPUT_METHOD_DIALOG, TYPE_WALLPAPER = 2010, 2011, 2012, 2013
    TYPE_STATUS_BAR_PANEL, TYPE_PRIVATE_PRESENTATION, TYPE_ACCESSIBILITY_OVERLAY = 2014, 2030, 2032
    TYPE_APPLICATION_OVERLAY, LAST_SYSTEM_WINDOW = 2038, 2999

    FLAG_ALLOW_LOCK_WHILE_SCREEN_ON, FLAG_DIM_BEHIND, FLAG_BLUR_BEHIND, FLAG_NOT_FOCUSABLE = 0x1, 0x2, 0x4, 0x8
    FLAG_NOT_TOUCHABLE, FLAG_NOT_TOUCH_MODAL, FLAG_TOUCHABLE_WHEN_WAKING, FLAG_KEEP_SCREEN_ON = 0x10, 0x20, 0x40, 0x80
    FLAG_LAYOUT_IN_SCREEN, FLAG_LAYOUT_NO_LIMITS, FLAG_FULLSCREEN, FLAG_FORCE_NOT_FULLSCREEN = 0x100, 0x200, 0x400, 0x800
    FLAG_DITHER, FLAG_SECURE, FLAG_SCALED, FLAG_IGNORE_CHEEK_PRESSES = 0x1000, 0x2000, 0x4000, 0x8000
    FLAG_LAYOUT_INSET_DECOR, FLAG_ALT_FOCUSABLE_IM, FLAG_WATCH_OUTSIDE_TOUCH = 0x10000, 0x20000, 0x40000
    FLAG_SHOW_WHEN_LOCKED, FLAG_SHOW_WALLPAPER, FLAG_TURN_SCREEN_ON = 0x80000, 0x100000, 0x200000
    FLAG_DISMISS_KEYGUARD, FLAG_SPLIT_TOUCH, FLAG_HARDWARE_ACCELERATED = 0x400000, 0x800000, 0x1000000
    FLAG_LAYOUT_IN_OVERSCAN, FLAG_TRANSLUCENT_STATUS, FLAG_TRANSLUCENT_NAVIGATION = 0x2000000, 0x4000000, 0x8000000
    FLAG_LOCAL_FOCUS_MODE, FLAG_LAYOUT_ATTACHED_IN_DECOR = 0x10000000, 0x40000000
    FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS = -0x80000000  # a Java int

    SOFT_INPUT_MASK_STATE, SOFT_INPUT_STATE_UNSPECIFIED, SOFT_INPUT_STATE_UNCHANGED = 0x0f, 0, 1
    SOFT_INPUT_STATE_HIDDEN, SOFT_INPUT_STATE_ALWAYS_HIDDEN = 2, 3
    SOFT_INPUT_STATE_VISIBLE, SOFT_INPUT_STATE_ALWAYS_VISIBLE = 4, 5
    SOFT_INPUT_MASK_ADJUST, SOFT_INPUT_ADJUST_UNSPECIFIED, SOFT_INPUT_ADJUST_RESIZE = 0xf0, 0x00, 0x10
    SOFT_INPUT_ADJUST_PAN, SOFT_INPUT_ADJUST_NOTHING, SOFT_INPUT_IS_FORWARD_NAVIGATION = 0x20, 0x30, 0x100

    LAYOUT_IN_DISPLAY_CUTOUT_MODE_DEFAULT, LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES = 0, 1
    LAYOUT_IN_DISPLAY_CUTOUT_MODE_NEVER, LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS = 2, 3
    BRIGHTNESS_OVERRIDE_NONE, BRIGHTNESS_OVERRIDE_OFF, BRIGHTNESS_OVERRIDE_FULL = -1.0, 0.0, 1.0
    ROTATION_ANIMATION_ROTATE, ROTATION_ANIMATION_CROSSFADE = 0, 1
    ROTATION_ANIMATION_JUMPCUT, ROTATION_ANIMATION_SEAMLESS = 2, 3

    LAYOUT_CHANGED, TYPE_CHANGED, FLAGS_CHANGED, FORMAT_CHANGED, ANIMATION_CHANGED = 0x1, 0x2, 0x4, 0x8, 0x10
    DIM_AMOUNT_CHANGED, TITLE_CHANGED, ALPHA_CHANGED, MEMORY_TYPE_CHANGED = 0x20, 0x40, 0x80, 0x100
    SOFT_INPUT_MODE_CHANGED, SCREEN_ORIENTATION_CHANGED = 0x200, 0x400
    SCREEN_BRIGHTNESS_CHANGED, ROTATION_ANIMATION_CHANGED = 0x800, 0x1000

    def __init__(self, *args):
        if len(args) not in (0, 1, 2, 3, 5, 7) or not all(type(arg) is int for arg in args):
            raise TypeError("No WindowManager.LayoutParams constructor takes these arguments")
        self.width = self.height = self.MATCH_PARENT
        self.x = self.y = 0
        self.type, self.flags, self.format = self.TYPE_APPLICATION, 0, _OPAQUE
        if len(args) == 7:
            self.width, self.height, self.x, self.y = args[:4]
            args = args[4:]
        elif len(args) == 5:
            self.width, self.height = args[:2]
            args = args[2:]
        for name, value in zip(("type", "flags", "format"), args):
            setattr(self, name, value)
        self.horizontalWeight = self.verticalWeight = 0.0
        self.horizontalMargin = self.verticalMargin = 0.0
        self.softInputMode = self.gravity = self.windowAnimations = 0
        self.alpha = self.dimAmount = 1.0
        self.screenBrightness = self.buttonBrightness = self.BRIGHTNESS_OVERRIDE_NONE
        self.rotationAnimation = self.ROTATION_ANIMATION_ROTATE
        self.layoutInDisplayCutoutMode = self.LAYOUT_IN_DISPLAY_CUTOUT_MODE_DEFAULT
        self.screenOrientation = -1  # ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        self.preferredRefreshRate = 0.0
        self.preferredDisplayModeId = 0
        self.token = self.packageName = None
        self._title = ""

    def setTitle(self, title):
        self._title = "" if title is None else title

    def getTitle(self):
        return self._title


class WindowManager(Object):
    """The interface, for its nested ``LayoutParams``; its only instance is the window service."""
    LayoutParams = LayoutParams

    def __init__(self, *args):
        raise _l.unsupported("android.view.WindowManager is an interface; the window service is not provided")


def static_window_services(tree):
    """Where a source asks for the window service, which nothing provides, sorted.

    Found from the AST alone: ``getSystemService`` given ``"window"`` or ``<anything>.WINDOW_SERVICE``,
    and ``getWindowManager()``. A service name computed at run time is not seen.
    """
    import ast
    found = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        function = node.func
        name = function.attr if isinstance(function, ast.Attribute) else function.id if isinstance(function, ast.Name) else ""
        if name == "getWindowManager":
            found.add("getWindowManager()")
        elif name == "getSystemService" and node.args:
            argument = node.args[-1]
            if (isinstance(argument, ast.Constant) and argument.value == "window") or (
                    getattr(argument, "attr", None) or getattr(argument, "id", None)) == "WINDOW_SERVICE":
                found.add("getSystemService(window)")
    return sorted(found)


CLASSES = _l.register({
    "android.view.WindowManager": WindowManager,
    "android.view.WindowManager$LayoutParams": LayoutParams,
})
