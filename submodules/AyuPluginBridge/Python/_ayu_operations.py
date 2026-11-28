"""Host operations behind the SDK's Telegram entry points (see ``protocol-telegram.md``).

One table serves two purposes. Static preflight reports an ``OPERATION`` blocker for every
SDK symbol or plugin method a source references whose operations the host does not declare,
and the SDK functions themselves use ``declared``/``require`` so the same feature fails with
``UnsupportedAPI`` when it is called anyway.

A requirement is a tuple of alternatives; an alternative is a tuple of operations that must
all be declared. ``hooks.java_method`` and ``hooks.partial`` name Xposed-style patching of
Java methods and bytecode: an iOS host has no such targets and does not declare them.
``sdk.unprovided_member`` marks Android members that nothing provides; no host declares it.
"""
from __future__ import annotations

REQUEST = (("telegram.request",),)
SEND = (("telegram.send_message",),)
MENU_ANY = (("menus.add",), ("menus.register",))
MENU_FULL = (("menus.add",),)
XPOSED = (("hooks.java_method",),)
PARTIAL = (("hooks.partial",),)
PEER = (("telegram.peer",),)
FILES = (("telegram.files.path", "telegram.files.load"),)
CONNECTION = (("telegram.request", "telegram.request.cancel", "telegram.connection"),)
UNPROVIDED = (("sdk.unprovided_member",),)
# Fields the ``hooks.register`` send hook carries; a hook that touches any other needs the typed one,
# which carries these. No host can tell a hook the remaining Android fields.
FALLBACK_SEND_FIELDS = frozenset({"peer", "message", "caption"})
SEND_HOOK_FIELDS = ("peer", "message", "caption", "entities", "path", "replyToMsg", "replyToTopMsg", "notify",
                    "scheduleDate", "scheduleRepeatPeriod", "searchLinks", "invert_media", "effect_id",
                    "hasMediaSpoilers", "document", "photo", "monoForumPeer", "quick_reply_shortcut_id", "payStars")
SEND_HOOK = "add_on_send_message_hook()"

# Dotted SDK references (``module.symbol`` or deeper) as static inspection resolves them.
SYMBOLS = {
    "client_utils.send_request": REQUEST,
    "client_utils.send_message": SEND,
    "client_utils.send_text": SEND,
    "client_utils.send_photo": SEND,
    "client_utils.send_document": SEND,
    "client_utils.send_video": SEND,
    "client_utils.send_audio": SEND,
    "client_utils.edit_message": (("telegram.edit_message",),),
    "client_utils.get_connections_manager": CONNECTION,
    "client_utils.get_send_messages_helper": SEND,
    "client_utils.get_file_loader": FILES,
    "client_utils.get_media_controller": (("telegram.player",),),
    "client_utils.get_messages_storage": (("telegram.messages",),),
    "client_utils.get_media_data_controller": (("telegram.stickers",),),
    "client_utils.get_contacts_controller": (("telegram.contacts",),),
    "client_utils.get_location_controller": (("telegram.location",),),
    "client_utils.get_notifications_controller": (("telegram.notifications",),),
    "client_utils.get_secret_chat_helper": (("telegram.secret_chats",),),
    "client_utils.get_download_controller": (("telegram.downloads",),),
    "client_utils.get_notifications_settings": (("telegram.notifications",),),
    "tlrpc.ConnectionsManager": REQUEST,
    # ZwyLib, by member (importing the class needs nothing): ``Requests`` helpers send API requests,
    # two of them call controller members nothing provides; hooking and method lookup are Xposed.
    "zwylib.Requests.send": REQUEST,
    "zwylib.Requests.async_send": REQUEST,
    "zwylib.Requests.change_slowmode": REQUEST,
    "zwylib.Requests.ban": REQUEST,
    "zwylib.Requests.unban": REQUEST,
    "zwylib.Requests.get_message": REQUEST,
    "zwylib.Requests.get_messages": REQUEST,
    "zwylib.Requests.search_messages": REQUEST,
    "zwylib.Requests.get_chat_participant": REQUEST,
    "zwylib.Requests.reload_admins": UNPROVIDED,
    "zwylib.Requests.delete_messages": UNPROVIDED,
    "zwylib.hook_max_args_method": XPOSED,
    "zwylib.HookUtils.hook": XPOSED,
    "zwylib.HookUtils.unhook": XPOSED,
    "zwylib.HookUtils.hook_before": XPOSED,
    "zwylib.HookUtils.hook_after": XPOSED,
    "zwylib.HookUtils.hook_replace": XPOSED,
    "zwylib.HookUtils.find_method_by_args_count": XPOSED,
    "zwylib.HookUtils.find_method_by_args": XPOSED,
    "zwylib.HookUtils.find_max_args_method": XPOSED,
    "base_plugin.MenuItemType.CHAT_ACTION_MENU": MENU_FULL,
    "base_plugin.MenuItemType.DRAWER_MENU": MENU_FULL,
    "base_plugin.MenuItemType.MAIN_MENU": MENU_FULL,
    "base_plugin.MenuItemType.PROFILE_ACTION_MENU": MENU_FULL,
    "base_plugin.MenuItemTypes.CHAT_ACTION_MENU": MENU_FULL,
    "base_plugin.MenuItemTypes.DRAWER_MENU": MENU_FULL,
    "base_plugin.MenuItemTypes.MAIN_MENU": MENU_FULL,
    "base_plugin.MenuItemTypes.PROFILE_ACTION_MENU": MENU_FULL,
    # The Pillow subset is a facade over the host image service (``protocol-images.md``).
    "PIL.Image.open": (("image.decode",),),
    "PIL.Image.new": (("image.create",),),
    "PIL.Image.merge": (("image.merge",),),
    "PIL.Image.blend": (("image.blend",),),
    "PIL.Image.composite": (("image.paste",),),
    "PIL.Image.alpha_composite": (("image.alpha_composite",),),
    "PIL.ImageDraw.Draw": (("image.draw",),),
    "PIL.ImageDraw.ImageDraw": (("image.draw",),),
    "PIL.ImageFont.truetype": (("image.font.load",),),
    "PIL.ImageFont.load_default": (("image.font.load",),),
    "PIL.ImageFont.FreeTypeFont": (("image.font.load",),),
}

# ``BasePlugin``/``AccountClient`` methods, matched on any receiver unless the source defines
# a function of that name itself.
METHODS = {
    "add_hook": (("telegram.hooks.set",),),
    "add_on_send_message_hook": (("telegram.hooks.send_message",), ("hooks.register",)),
    "add_menu_item": MENU_ANY,
    "hook_method": XPOSED,
    "hook_all_methods": XPOSED,
    "hook_all_constructors": XPOSED,
    "hook_call_site": PARTIAL,
    "hook_field_read": PARTIAL,
    "hook_field_write": PARTIAL,
    "hook_string_constant": PARTIAL,
    "hook_return_value": PARTIAL,
    "send_request": REQUEST,
    "send_message": SEND,
    "send_text": SEND,
    "send_photo": SEND,
    "send_document": SEND,
    "send_video": SEND,
    "send_audio": SEND,
    "edit_message": (("telegram.edit_message",),),
    # ``AccountClient`` getters (``get_client().get_file_loader()``), as their ``client_utils`` namesakes.
    "get_connections_manager": CONNECTION,
    "get_send_messages_helper": SEND,
    "generatePhotoSizes": (("image.decode", "image.resize", "image.encode", "image.transpose", "image.convert",
                            "image.create", "image.alpha_composite", "telegram.connection"),),
    "get_file_loader": FILES,
    "get_messages_storage": (("telegram.messages",),),
    "get_media_data_controller": (("telegram.stickers",),),
    "get_contacts_controller": (("telegram.contacts",),),
    "get_location_controller": (("telegram.location",),),
    "get_notifications_controller": (("telegram.notifications",),),
    "get_secret_chat_helper": (("telegram.secret_chats",),),
    "get_download_controller": (("telegram.downloads",),),
    "get_notifications_settings": (("telegram.notifications",),),
    # ``MessagesController`` state changes, one host operation each.
    "deleteMessages": (("telegram.action.delete_messages",),),
    "markDialogAsRead": (("telegram.action.read_dialog",),),
    "processUpdates": (("telegram.action.process_updates",),),
    "putUser": (("telegram.action.store_peers",),),
    "putUsers": (("telegram.action.store_peers",),),
    "putChat": (("telegram.action.store_peers",),),
    "putChats": (("telegram.action.store_peers",),),
    "loadFullUser": (("telegram.action.load_full_peer",),),
    "loadFullChat": (("telegram.action.load_full_peer",),),
}
# Android members that no host adapter and no Python-local class provides, so a call fails
# wherever it is made. Found by auditing plugins that otherwise pass; this is a list, not a
# proof that every other member exists. Remove a name when something implements it.
UNPROVIDED_MEMBERS = (
    "addDialogToFolder", "readAllDialogs",                                  # MessagesController, MessagesStorage
    "applyNewText",                                                        # MessageObject (needs its text layout)
    "prepareSendingPhoto", "prepareSendingDocument",                       # SendMessagesHelper
    "findMessageCell", "finishFragment",                                    # ChatActivity, BaseFragment
    "getWindow", "getDecorView",                                            # Activity
    "smoothScrollBy",                                                       # views
    "getDeclaredField", "queryFinalized",                                   # reflection, SQLiteDatabase
    "quantize", "getpalette", "putpalette", "getexif", "getmask", "set_variation_by_name",  # Pillow outside the PIL subset
)
# Of those, the members something does provide for the classes it models. The entry stays as the net
# for receivers static inspection cannot name, where plugins reach Android internals nothing models:
# ``Class.getDeclaredField`` finds the fields of ``java_reflect``'s models and no private field.
MODELLED_MEMBERS = frozenset({"getDeclaredField"})
METHODS.update(dict.fromkeys(UNPROVIDED_MEMBERS, UNPROVIDED))
METHOD_NAMES = frozenset(METHODS)


def requirements(references, method_calls, send_hook_fields=None, hook_targets=None, intent_actions=(),
                 window_services=(), send_hook_resend=False):
    """Requirements of what a source references, keyed by the SDK symbol or ``<method>()``.

    ``send_hook_fields`` is what ``on_send_message_hook`` touches of its parameters (None when
    that is not known, as for a caller that did not analyse it): beyond the fallback's fields
    the hook needs the typed operation. ``hook_targets`` is ``_ayu_xposed.static_targets``: a
    hook API all of whose calls name mapped targets needs their points' operations instead of
    ``hooks.java_method``. ``intent_actions`` is ``_ayu_intents.static_actions``.
    """
    found = {name: SYMBOLS[name] for name in references if name in SYMBOLS}
    # ``client_utils.send_request(...)`` is one use, already found as the symbol.
    direct = {name.rpartition(".")[2] for name in found}
    found.update({name + "()": METHODS[name] for name in method_calls if name in METHODS and name not in direct})
    if SEND_HOOK in found:
        if send_hook_fields is None:
            extra = lost = None
        else:
            from client_utils import SEND_MESSAGE_DEFAULTS
            # A name Android's object lacks raises there too; the plugin already copes with that.
            used = set(send_hook_fields).intersection(SEND_MESSAGE_DEFAULTS)
            extra, lost = sorted(used - FALLBACK_SEND_FIELDS), sorted(used.difference(SEND_HOOK_FIELDS))
        if extra is None or extra:
            del found[SEND_HOOK]
            found["on_send_message_hook params" + ("." + extra[0] if extra else "")] = (("telegram.hooks.send_message",),)
        if lost:
            found["on_send_message_hook params." + lost[0]] = UNPROVIDED
    for api, labels in (hook_targets or {}).items():
        if labels is not None and api + "()" in found:
            import _ayu_xposed
            del found[api + "()"]
            found.update({f"{api}(): {label}": _ayu_xposed.requirement(label) for label in labels})
    # Reserved: an Android-only intent action; no host declares it.
    found.update({"Intent " + action: (("intents.android_only",),) for action in intent_actions})
    # ``_ayu_javalib.android_view.static_window_services``: the window service is not provided.
    found.update(dict.fromkeys(window_services, UNPROVIDED))
    if send_hook_resend:
        # ``_ayu_inspection.send_hook_resend``: ``SendMessagesHelper.sendMessage`` refuses a delivered object.
        found["sendMessage(on_send_message_hook params)"] = UNPROVIDED
    return {name: [list(group) for group in groups] for name, groups in sorted(found.items())}


def missing(required, operations):
    """One finding per requirement the host cannot meet: its first undeclared operation and the user."""
    available = set(operations)
    findings = []
    for name, groups in sorted(required.items()):
        if not any(all(operation in available for operation in group) for group in groups):
            lacking = next(operation for operation in groups[0] if operation not in available)
            findings.append(f"{lacking} ({name})")
    return findings


def declared(*operations):
    """Whether the current host declares every named operation."""
    from ayu_bridge import runtime
    runtime.require()
    available = runtime.capabilities["operations"]
    return all(operation in available for operation in operations)


def require(operation, feature):
    """Raise ``UnsupportedAPI`` unless the host declares ``operation``."""
    if not declared(operation):
        from ayu_bridge import UnsupportedAPI
        raise UnsupportedAPI(f"{feature} needs host operation {operation}")
