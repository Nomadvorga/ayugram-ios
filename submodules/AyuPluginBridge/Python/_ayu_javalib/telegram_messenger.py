"""Python-local ``org.telegram.messenger`` classes (and ``org.telegram.tgnet.ConnectionsManager``).

Pure logic over TL objects follows Android: ``MessageObject`` accessors, the ``ChatObject``/
``UserObject``/``DialogObject`` predicates, ``FileLoader`` naming helpers and ``Utilities``.
Everything that needs the application goes through a named host operation of
``protocol-telegram.md``; a class whose useful members need one declares it in
``__ayu_requires__`` and stays a preflight blocker until the host declares it. A member that
is not implemented raises ``UnsupportedAPI``, and so does a static helper given a host object:
the host's user and chat snapshots are not TL objects and would be judged wrongly.

Deviations: ``MessageObject`` does not compute ``type``, layouts or localized service and
media labels; unknown-title/artist fallbacks use the reference client's English strings;
``SharedConfig.streamMkv`` is taken as its default (off); ``byte[]`` results are ``bytes``.
"""
from __future__ import annotations

import functools
import hashlib
import math
import os
import re
import secrets
import time
import unicodedata
import zlib

from . import HostField, returns
from . import java_lang as _l
from . import telegram_tl as tl
from .android_graphics import Point
from .java_io import File

PACKAGE = "org.telegram.messenger."
TLRPC = tl.TLRPC
_unsupported = tl._unsupported
# Executable extensions ``MessageObject.isV`` refuses to treat as video, as Java ``String.hashCode`` values.
_NOT_VIDEO = frozenset(int(item, 16) for item in (
    "17890 1794a 17a1c 17a21 17af5 17c14 17c15 17d07 18085 180a8 1813a 18181 1819f 181e5 181f8 1840a "
    "184dc 184e4 184fe 185a8 18770 1889f 188be 1897a 18a12 18a5e 18c54 18d27 18dde 1909c 190ac 193ec "
    "1940e 194d5 1968a 1974d 197e1 197ee 197f3 1981a 1981f 19886 1988b 19a1b 19c3c 19c47 19c4f 19eda "
    "1a000 1a285 1a329 1a59c 1a5d4 1a5d5 1a735 1a75e 1a77d 1a783 1a78a 1a78e 1a81a 1ad00 1ad24 1b0a2 "
    "1b0d1 1b123 1b18d 1b1cc 1b2a1 1b2a5 1b31e 1b33c 1b37a 1b386 1b639 1b848 1b894 1b8de 1b9db 1b9ec "
    "1bc22 1bc24 1bcad 1bcbe 1bdb5 1becd 1c079 1c0ea 1c11a 1bdd2 1c3b7 1c56f 1c739 1c747 1c781 1c9e2 "
    "1cb21 1cc50 1ccb2 1cd07 1cd0a 1cd0c 1cea7 1d09b 18538 18417 194e1 1b178 17a7e 1b274 1c1d9 1d017 "
    "1c270 1ba8b e30 21bd7bf 1d77f 333e3f 348d4c e55 349c84 c9e5d0cb e09 da6 2e06d4 a473e8a5 eac d97 "
    "2dd5ba 3498c3 1b0f2 d49 35c854 35ce71 c70 18203 2f2240 1cfff dfc 35c681 383059 dfd d1075a44 c8f "
    "31ece8 c22 ab2f7e36 edc 3107ab b549144c 1be64 ebd32e77 6cc0c23"
).split())


def _runtime():
    from ayu_bridge import runtime
    return runtime


def _call(operation, arguments):
    return _runtime().call(operation, arguments)


def _client():
    import client_utils
    return client_utils


def _operations():
    import _ayu_operations
    return _ayu_operations


def _java_util():
    from . import java_util
    return java_util


# One ``telegram.dialogs`` answer serves the reads of the next quarter second, so a loop over
# ``getDialog`` or ``dialogs_dict`` is one host call. Any state change made through this module drops it.
_DIALOGS_TTL = 0.25
_dialog_cache = {}


def _dialog_entries(account):
    now = time.monotonic()
    cached = _dialog_cache.get(account)
    if cached is not None and 0 <= now - cached[0] < _DIALOGS_TTL:
        return cached[1]
    result = _call("telegram.dialogs", {"account": account})
    if not isinstance(result, list) or len(result) > 2000:
        raise _runtime_error("Host returned an invalid dialog list")
    for entry in result:
        if (not isinstance(entry, dict) or set(entry) != {"dialog", "last_message_date", "pinned_num"}
                or any(type(entry[key]) is not int or not 0 <= entry[key] < 1 << 31 for key in ("last_message_date", "pinned_num"))):
            raise _runtime_error("Host returned an invalid dialog")
    _dialog_cache.clear()
    _dialog_cache[account] = (now, result)
    return result


def _int(value, bits, what):
    if type(value) is not int or not -(1 << (bits - 1)) <= value < 1 << (bits - 1):
        raise TypeError(f"{what} must be a {bits}-bit integer")
    return value


def _account(value):
    if type(value) is not int or not 0 <= value < 2 ** 31:
        raise ValueError("Account must be a nonnegative integer")
    return value


def _java_hash(text):
    """``String.hashCode()`` as an unsigned 32-bit value."""
    value = 0
    data = text.encode("utf-16-le", "surrogatepass")
    for index in range(0, len(data), 2):
        value = (value * 31 + data[index] + (data[index + 1] << 8)) & 0xFFFFFFFF
    return value


class _Meta(type):
    def __getattr__(cls, name):
        raise _unsupported(f"{cls.__name__}.{name} is not implemented")


class _Java(metaclass=_Meta):
    # ``Class.getClass()`` and ``object.getClass()``: the ``java.lang.Class`` mirror with the Java name.
    getClass = _l._GetClass()

    def __getattr__(self, name):
        raise _unsupported(f"{type(self).__name__}.{name} is not implemented")


def _is_host(value):
    return type(value).__name__ in ("RemoteObject", "JavaClass")


def _local_arguments(cls):
    """Make every public static method of a helper class refuse host objects.

    These helpers read TL fields and test TL classes. A host object is a bounded snapshot of
    some other class, so the same logic would answer for it wrongly instead of failing.
    """
    def guard(name, function):
        @functools.wraps(function)
        def checked(*args, **kwargs):
            for value in args + tuple(kwargs.values()):
                if _is_host(value):
                    from ayu_bridge import UnsupportedAPI
                    raise UnsupportedAPI(f"{cls.__name__}.{name} needs a local TL object, not the host object {value!r}")
            return function(*args, **kwargs)
        return checked

    for name, member in list(vars(cls).items()):
        if isinstance(member, staticmethod) and not name.startswith("_"):
            setattr(cls, name, staticmethod(guard(name, member.__func__)))
    return cls


# --- R: symbolic resource ids -------------------------------------------------

class ResourceId(int):
    """``R.<kind>.<name>``: an Android resource named symbolically.

    Android's integers are build artifacts with no meaning on iOS. The value keeps ``int``
    behaviour (nonzero, hashable) and reaches the host as ``{"resource": kind, "name": name}``,
    which the host resolves against its own assets or rejects.
    """

    def __new__(cls, kind, name):
        value = int.__new__(cls, 0x7F000000 | zlib.crc32(f"{kind}/{name}".encode("utf-8")) & 0xFFFFFF or 0x7F000001)
        value.kind, value.name = kind, name
        return value

    def __eq__(self, other):
        if isinstance(other, ResourceId):
            return (self.kind, self.name) == (other.kind, other.name)
        return int.__eq__(self, other)

    def __ne__(self, other):
        result = self.__eq__(other)
        return result if result is NotImplemented else not result

    __hash__ = int.__hash__

    def __repr__(self):
        return f"R.{self.kind}.{self.name}"

    def to_bridge(self):
        return {"resource": self.kind, "name": self.name}


class _ResourceKind(type):
    def __getattr__(cls, name):
        if name.startswith("_") or not name.isidentifier():
            raise AttributeError(name)
        _require_resource_kind(cls)
        return ResourceId(cls.__name__, name)


def _require_resource_kind(kind):
    """Inside a plugin, a kind the host has no table for raises instead of naming a resource."""
    from ayu_bridge import BridgeError, UnsupportedAPI, runtime
    try:
        runtime.require()
        available = runtime.capabilities["operations"]
    except BridgeError:
        return  # no plugin scope: the symbolic value alone, as in tools and unit tests
    for operation in kind.__ayu_requires__:
        if operation not in available:
            raise UnsupportedAPI(f"R.{kind.__name__} needs host operation {operation}")


class R:
    """``org.telegram.messenger.R``; every identifier names a resource the host resolves when it is used.

    Usable only on a host that declares ``resources.resolve``: no adapter accepts the symbolic form
    otherwise, and Android's integers mean nothing on iOS. That operation covers ``R.drawable`` and
    ``R.raw`` (icons). ``R.string`` needs ``resources.strings`` and the remaining kinds
    ``resources.android``; no host declares those two (see ``protocol-telegram.md``).
    """
    __ayu_requires__ = ("resources.resolve",)


_RESOURCE_KINDS = ("drawable", "raw", "string", "style", "id", "color", "dimen", "attr", "layout", "mipmap",
                   "font", "xml", "anim", "array", "plurals", "bool", "integer", "menu", "styleable")
_ICON_KINDS = ("drawable", "raw")
for _kind in _RESOURCE_KINDS:
    _extra = () if _kind in _ICON_KINDS else ("resources.strings",) if _kind == "string" else ("resources.android",)
    setattr(R, _kind, _ResourceKind(_kind, (), {"__module__": __name__, "__qualname__": "R." + _kind,
                                                "__ayu_requires__": R.__ayu_requires__ + _extra}))


# --- Static helpers over TL objects --------------------------------------------

@_local_arguments
class DialogObject(_Java):
    @staticmethod
    def isChannel(dialog):
        return dialog is not None and dialog.flags & 1 != 0

    @staticmethod
    def makeFolderDialogId(folderId):
        return 0x2000000000000000 | _int(folderId, 32, "folderId")

    @staticmethod
    def isFolderDialogId(dialogId):
        value = _int(dialogId, 64, "dialogId") & 0xFFFFFFFFFFFFFFFF
        return value & 0x2000000000000000 != 0 and value & 0x8000000000000000 == 0

    @staticmethod
    def initDialog(dialog):
        """Sets the local ``id`` of a dialog that has none: from its peer, or from its folder."""
        if dialog is None or dialog.id != 0:
            return
        if isinstance(dialog, TLRPC.TL_dialogFolder):
            if dialog.folder is not None:
                dialog.id = DialogObject.makeFolderDialogId(dialog.folder.id)
        elif isinstance(dialog, TLRPC.TL_dialog) and dialog.peer is not None:
            dialog.id = DialogObject.getPeerDialogId(dialog.peer)

    @staticmethod
    def getDialogId(obj):
        if isinstance(obj, TLRPC.User):
            return obj.id
        if isinstance(obj, TLRPC.Chat):
            return -obj.id
        return 0

    @staticmethod
    def getPeerDialogId(peer):
        if peer is None:
            return 0
        if peer.user_id != 0:
            return peer.user_id
        if peer.chat_id != 0:
            return -peer.chat_id
        return -peer.channel_id

    @staticmethod
    def isEncryptedDialog(dialogId):
        value = _int(dialogId, 64, "dialogId") & 0xFFFFFFFFFFFFFFFF
        return value & 0x4000000000000000 != 0 and value & 0x8000000000000000 == 0

    @staticmethod
    def isChatDialog(dialogId):
        return not DialogObject.isEncryptedDialog(dialogId) and not DialogObject.isFolderDialogId(dialogId) and dialogId < 0

    @staticmethod
    def isUserDialog(dialogId):
        return not DialogObject.isEncryptedDialog(dialogId) and not DialogObject.isFolderDialogId(dialogId) and dialogId > 0

    @staticmethod
    def makeEncryptedDialogId(chatId):
        return 0x4000000000000000 | _int(chatId, 64, "chatId") & 0xFFFFFFFF

    @staticmethod
    def getEncryptedChatId(dialogId):
        return tl._signed(_int(dialogId, 64, "dialogId"), 32)

    @staticmethod
    def getFolderId(dialogId):
        return tl._signed(_int(dialogId, 64, "dialogId"), 32)


def _usernames(owner, editable):
    for item in owner.usernames or ():
        if item is not None and (item.active and not editable or item.editable) and item.username:
            return item.username
    return None


_EXTRA_DIACRITICS = re.compile("([\u0300-\u036f]{1,2})[\u0300-\u036f]+")
_RTL_MARKS = re.compile("[\u200e\u200f\u202a-\u202e]")


def _java_trim(value):
    """``String.trim``: only code points up to U+0020, unlike ``str.strip``."""
    start, end = 0, len(value)
    while start < end and value[start] <= " ":
        start += 1
    while end > start and value[end - 1] <= " ":
        end -= 1
    return value[start:end]


def _name_display_order():
    """``LocaleController.nameDisplayOrder`` as ``recreateFormatters`` sets it."""
    locale = _runtime().jclass(PACKAGE + "LocaleController").getInstance().getCurrentLocale()
    language = locale.getLanguage()
    return 2 if str("en" if language is None else language).lower() == "ko" else 1


def _format_name(first, last):
    """``ContactsController.formatName(firstName, lastName)`` (``maxLength`` 0)."""
    first = "" if first is None else _java_trim(str(first))
    last = "" if last is None else _java_trim(str(last))
    parts = (first, last) if _name_display_order() == 1 else (last, first)
    return " ".join(part for part in parts if part)


@_local_arguments
class UserObject(_Java):
    # Without ``telegram.peer`` the only users a plugin can obtain are the host's snapshots.
    __ayu_requires__ = ("telegram.peer",)
    REPLY_BOT = 1271266957
    ANONYMOUS = 2666000
    VERIFY = 489000

    @staticmethod
    def isDeleted(user):
        return user is None or isinstance(user, TLRPC.TL_userEmpty) or user.deleted

    @staticmethod
    def isContact(user):
        return user is not None and (user.contact or user.mutual_contact)

    @staticmethod
    def isUserSelf(user):
        return user is not None and user.self

    @staticmethod
    def isReplyUser(user):
        value = user if type(user) is int else None if user is None else user.id
        return value in (708513, UserObject.REPLY_BOT)

    @staticmethod
    def isAnonymous(user):
        return user is not None and user.id == UserObject.ANONYMOUS

    @staticmethod
    def isBot(user):
        return user is not None and user.bot

    @staticmethod
    def isService(user_id):
        return _int(user_id, 64, "user_id") in (333000, 777000, 42777)

    @staticmethod
    def getUserName(user):
        if UserObject.isDeleted(user):
            raise _unsupported("UserObject.getUserName of a deleted user needs Telegram Android's HiddenName string")
        name = _RTL_MARKS.sub("", _EXTRA_DIACRITICS.sub(r"\1", _format_name(user.first_name, user.last_name)))
        if not name and user.phone:
            raise _unsupported("UserObject.getUserName of a nameless user needs Telegram Android's PhoneFormat")
        return name

    @staticmethod
    def getPublicUsername(user, editable=False):
        if user is None:
            return None
        if user.username:
            return user.username
        return _usernames(user, editable)

    @staticmethod
    def hasPublicUsername(user, username):
        if user is None or username is None:
            return False
        def same(value):
            return value is not None and value.lower() == username.lower()

        return same(user.username) or any(item is not None and item.active and same(item.username)
                                          for item in user.usernames or ())

    @staticmethod
    def hasPhoto(user):
        return user is not None and user.photo is not None and not isinstance(user.photo, TLRPC.TL_userProfilePhotoEmpty)

    @staticmethod
    def getPhoto(user):
        return user.photo if UserObject.hasPhoto(user) else None

    @staticmethod
    def isBotForum(user):
        return user is not None and user.bot_forum_view

    @staticmethod
    def isBotForumSidebar(user):
        return UserObject.isBotForum(user) and user.bot_forum_sidebar

    @staticmethod
    def isBotForumWithEditableTopics(user):
        return user is not None and user.bot_forum_view and user.bot_forum_can_manage_topics


@_local_arguments
class ChatObject(_Java):
    # Without ``telegram.peer`` the only chats a plugin can obtain are the host's snapshots.
    __ayu_requires__ = ("telegram.peer",)
    CHAT_TYPE_CHAT, CHAT_TYPE_CHANNEL, CHAT_TYPE_USER, CHAT_TYPE_MEGAGROUP, CHAT_TYPE_FORUM = 0, 2, 3, 4, 5
    ACTION_PIN, ACTION_CHANGE_INFO, ACTION_BLOCK_USERS, ACTION_INVITE, ACTION_ADD_ADMINS, ACTION_POST = range(6)
    ACTION_SEND, ACTION_SEND_MEDIA, ACTION_SEND_STICKERS, ACTION_EMBED_LINKS, ACTION_SEND_POLLS = 6, 7, 8, 9, 10
    ACTION_VIEW, ACTION_EDIT_MESSAGES, ACTION_DELETE_MESSAGES, ACTION_MANAGE_CALLS, ACTION_MANAGE_TOPICS = 11, 12, 13, 14, 15
    ACTION_SEND_PHOTO, ACTION_SEND_VIDEO, ACTION_SEND_MUSIC, ACTION_SEND_DOCUMENTS = 16, 17, 18, 19
    ACTION_SEND_VOICE, ACTION_SEND_ROUND, ACTION_SEND_PLAIN, ACTION_SEND_TEXT, ACTION_SEND_GIFS = 20, 21, 22, 22, 23
    ACTION_MANAGE_DIRECT, ACTION_MANAGE_TAGS, ACTION_SEND_REACTIONS = 24, 25, 26
    ACTION_MANAGE_LINKED_CHATS, ACTION_MANAGE_WELCOME = 27, 28
    # The right of ``TL_chatBannedRights`` that bans an action, and of ``TL_chatAdminRights`` that grants it.
    _BANNED = {0: "pin_messages", 1: "change_info", 3: "invite_users", 6: "send_messages", 7: "send_media",
               8: "send_stickers", 9: "embed_links", 10: "send_polls", 11: "view_messages", 15: "manage_topics",
               16: "send_photos", 17: "send_videos", 18: "send_audios", 19: "send_docs", 20: "send_voices",
               21: "send_roundvideos", 26: "send_reactions", 22: "send_plain", 27: "manage_linked_peers"}
    _ADMIN = {0: "pin_messages", 15: "manage_topics", 1: "change_info", 3: "invite_users", 4: "add_admins",
              5: "post_messages", 12: "edit_messages", 13: "delete_messages", 2: "ban_users", 14: "manage_call",
              27: "manage_linked_peers"}
    _CHAT_ADMIN = {**_ADMIN, 28: "manage_welcome_messages", 24: "manage_direct_messages", 25: "manage_ranks"}
    _ADMIN_ACTIONS = frozenset({0, 1, 3, 4, 5, 12, 13, 2, 15})

    @staticmethod
    def _chat(value, account, negate=False):
        """Android's ``(chat)`` and ``(account, id)``/``(id, account)`` overloads."""
        if account is None:
            return value
        return MessagesController._ayu_usable().getInstance(account).getChat(-value if negate else value)

    @staticmethod
    def _forbidden(chat):
        return isinstance(chat, (TLRPC.TL_chatForbidden, TLRPC.TL_channelForbidden, TLRPC.TL_communityForbidden))

    @staticmethod
    def isCommunity(chat):
        return isinstance(chat, (TLRPC.TL_community, TLRPC.TL_communityForbidden))

    @staticmethod
    def isChannel(chat, currentAccount=None):
        chat = ChatObject._chat(chat, currentAccount)
        return isinstance(chat, (TLRPC.TL_channel, TLRPC.TL_channelForbidden)) or ChatObject.isCommunity(chat)

    @staticmethod
    def isChannelOrGiga(chat):
        return ChatObject.isChannel(chat) and (not chat.megagroup or chat.gigagroup)

    @staticmethod
    def isMegagroup(chat, chatId=None):
        # Java: isMegagroup(Chat) and isMegagroup(int currentAccount, long chatId).
        if chatId is not None:
            chat = ChatObject._chat(chatId, chat)
        return ChatObject.isChannel(chat) and chat.megagroup

    @staticmethod
    def isChannelAndNotMegaGroup(chat, currentAccount=None):
        chat = ChatObject._chat(chat, currentAccount)
        return ChatObject.isChannel(chat) and not ChatObject.isMegagroup(chat)

    @staticmethod
    def isForum(chat, dialogId=None):
        # Java: isForum(Chat) and isForum(int currentAccount, long dialogId).
        if dialogId is not None:
            chat = ChatObject._chat(dialogId, chat, negate=True)
        return chat is not None and chat.forum

    @staticmethod
    def isMonoForum(chat, dialogId=None):
        if dialogId is not None:
            chat = ChatObject._chat(dialogId, chat, negate=True)
        return chat is not None and chat.monoforum

    @staticmethod
    def isLeftFromChat(chat):
        return chat is None or isinstance(chat, TLRPC.TL_chatEmpty) or ChatObject._forbidden(chat) or chat.left or chat.deactivated

    @staticmethod
    def isNotInChat(chat):
        return (chat is None or isinstance(chat, TLRPC.TL_chatEmpty) or ChatObject._forbidden(chat)
                or chat.left or chat.kicked or chat.deactivated)

    @staticmethod
    def isInChat(chat):
        return not ChatObject.isNotInChat(chat)

    @staticmethod
    def isDiscussionGroup(chat, chatFull):
        # Java: isDiscussionGroup(Chat, ChatFull) and isDiscussionGroup(int currentAccount, long chatId).
        if type(chat) is int:
            controller = MessagesController._ayu_usable().getInstance(chat)
            chat, chatFull = controller.getChat(chatFull), controller.getChatFull(chatFull)
        return ChatObject.isMegagroup(chat) and chatFull is not None and chatFull.linked_chat_id != 0

    @staticmethod
    def hasAdminRights(chat):
        return chat is not None and (chat.creator or chat.admin_rights is not None and chat.admin_rights.flags != 0)

    @staticmethod
    def getPublicUsername(chat, editable=False):
        if chat is None:
            return None
        if chat.username and not editable:
            return chat.username
        return _usernames(chat, editable)

    @staticmethod
    def isPublic(chat):
        return bool(ChatObject.getPublicUsername(chat))

    # Rights. Android's checks for chats of TL layers before 93 have no class here: this schema is one layer.
    @staticmethod
    def _banned(rights, action):
        name = ChatObject._BANNED.get(action)
        return rights is not None and name is not None and getattr(rights, name)

    @staticmethod
    def isActionBannedByDefault(chat, action):
        return chat is not None and ChatObject._banned(chat.default_banned_rights, action)

    @staticmethod
    def isActionBanned(chat, action):
        return chat is not None and (ChatObject._banned(chat.banned_rights, action)
                                     or ChatObject._banned(chat.default_banned_rights, action))

    @staticmethod
    def canUserDoAdminAction(chat, action):
        # Java: canUserDoAdminAction(TL_chatAdminRights, int) and canUserDoAdminAction(Chat, int).
        if isinstance(chat, TLRPC.TL_chatAdminRights):
            rights, names = chat, ChatObject._ADMIN
        elif chat is None:
            return False
        elif chat.creator:
            return True
        else:
            rights, names = chat.admin_rights, ChatObject._CHAT_ADMIN
        name = names.get(action)
        return rights is not None and name is not None and getattr(rights, name)

    @staticmethod
    def canUserDoAction(chat, *arguments):
        # Java: canUserDoAction(Chat, int) and canUserDoAction(Chat, ChannelParticipant, int).
        if len(arguments) not in (1, 2):
            raise TypeError("ChatObject.canUserDoAction takes (chat, [participant,] action)")
        action = arguments[-1]
        if chat is None:
            return True
        holder = chat
        if len(arguments) == 2:
            holder = arguments[0]
            if holder is None:
                return False
        if ChatObject.canUserDoAdminAction(holder.admin_rights if holder is not chat else chat, action):
            return True
        if ChatObject._banned(holder.banned_rights, action):
            return False
        if action not in ChatObject._BANNED:
            return False
        if holder.admin_rights is not None and action not in ChatObject._ADMIN_ACTIONS:
            return True
        return chat.default_banned_rights is not None and not ChatObject._banned(chat.default_banned_rights, action)

    @staticmethod
    def isKickedFromChat(chat):
        return (chat is None or isinstance(chat, TLRPC.TL_chatEmpty) or ChatObject._forbidden(chat) or chat.kicked
                or chat.deactivated or chat.banned_rights is not None and chat.banned_rights.view_messages)

    @staticmethod
    def isIgnoredChatRestrictionsForBoosters(chat):
        # Java: (ChatFull), and (Chat), which reads the selected account's full chat.
        if chat is None:
            return False
        if not isinstance(chat, TLRPC.ChatFull):
            account = _runtime().jclass("org.telegram.messenger.UserConfig").selectedAccount
            chat = MessagesController._ayu_usable().getInstance(account).getChatFull(chat.id)
        return chat is not None and chat.boosts_unrestrict > 0 and chat.boosts_applied - chat.boosts_unrestrict >= 0

    @staticmethod
    def _unrestricted(chat, action):
        return ChatObject.isIgnoredChatRestrictionsForBoosters(chat) or ChatObject.canUserDoAction(chat, action)

    @staticmethod
    def canSendMessages(chat):
        if ChatObject.isNotInChat(chat) and chat is not None and chat.join_to_send:
            return False
        return ChatObject._unrestricted(chat, ChatObject.ACTION_SEND)

    @staticmethod
    def canSendPlain(chat):
        return ChatObject._unrestricted(chat, ChatObject.ACTION_SEND_PLAIN)

    @staticmethod
    def canSendStickers(chat):
        return ChatObject._unrestricted(chat, ChatObject.ACTION_SEND_STICKERS)

    @staticmethod
    def canSendEmbed(chat):
        return ChatObject._unrestricted(chat, ChatObject.ACTION_EMBED_LINKS)

    @staticmethod
    def canSendPhoto(chat):
        return ChatObject._unrestricted(chat, ChatObject.ACTION_SEND_PHOTO)

    @staticmethod
    def canSendVideo(chat):
        return ChatObject._unrestricted(chat, ChatObject.ACTION_SEND_VIDEO)

    @staticmethod
    def canSendMusic(chat):
        return ChatObject._unrestricted(chat, ChatObject.ACTION_SEND_MUSIC)

    @staticmethod
    def canSendDocument(chat):
        return ChatObject._unrestricted(chat, ChatObject.ACTION_SEND_DOCUMENTS)

    @staticmethod
    def canSendVoice(chat):
        return ChatObject._unrestricted(chat, ChatObject.ACTION_SEND_VOICE)

    @staticmethod
    def canSendRoundVideo(chat):
        return ChatObject._unrestricted(chat, ChatObject.ACTION_SEND_ROUND)

    @staticmethod
    def canSendPolls(chat):
        return not ChatObject.isMonoForum(chat) and ChatObject._unrestricted(chat, ChatObject.ACTION_SEND_POLLS)

    @staticmethod
    def canSendAnyMedia(chat):
        return any(check(chat) for check in (
            ChatObject.canSendPhoto, ChatObject.canSendVideo, ChatObject.canSendRoundVideo, ChatObject.canSendVoice,
            ChatObject.canSendDocument, ChatObject.canSendMusic, ChatObject.canSendStickers))

    @staticmethod
    def canPost(chat):
        return ChatObject.canUserDoAction(chat, ChatObject.ACTION_POST)

    @staticmethod
    def canAddUsers(chat):
        return ChatObject.canUserDoAction(chat, ChatObject.ACTION_INVITE)

    @staticmethod
    def canChangeChatInfo(chat):
        return ChatObject.canUserDoAction(chat, ChatObject.ACTION_CHANGE_INFO)

    @staticmethod
    def canAddAdmins(chat):
        return ChatObject.canUserDoAction(chat, ChatObject.ACTION_ADD_ADMINS)

    @staticmethod
    def canBlockUsers(chat):
        return ChatObject.canUserDoAction(chat, ChatObject.ACTION_BLOCK_USERS)

    @staticmethod
    def canManageCalls(chat):
        return ChatObject.canUserDoAction(chat, ChatObject.ACTION_MANAGE_CALLS)

    @staticmethod
    def canPinMessages(chat):
        return (ChatObject.canUserDoAction(chat, ChatObject.ACTION_PIN)
                or ChatObject.isChannel(chat) and not chat.megagroup and chat.admin_rights is not None
                and chat.admin_rights.edit_messages)

    @staticmethod
    def canCreateTopic(chat):
        return ChatObject.canUserDoAction(chat, ChatObject.ACTION_MANAGE_TOPICS)

    @staticmethod
    def canManageTopics(chat):
        return ChatObject.canUserDoAdminAction(chat, ChatObject.ACTION_MANAGE_TOPICS)

    @staticmethod
    def shouldSendAnonymously(chat):
        return chat is not None and chat.admin_rights is not None and chat.admin_rights.anonymous

    @staticmethod
    def canWriteToChat(chat):
        return (not ChatObject.isChannel(chat) or chat.creator
                or chat.admin_rights is not None and chat.admin_rights.post_messages
                or not chat.broadcast and not chat.gigagroup or chat.gigagroup and ChatObject.hasAdminRights(chat))

    @staticmethod
    def canSendAsPeers(chat):
        return ChatObject.isChannel(chat) and (
            not chat.megagroup and chat.signatures and ChatObject.hasAdminRights(chat) and ChatObject.canWriteToChat(chat)
            or chat.megagroup and (ChatObject.isPublic(chat) or chat.has_geo or chat.has_link))

    @staticmethod
    def isSidebarEnabled(chat):
        return chat is not None and (chat.forum and chat.forum_sidebar or chat.monoforum)

    @staticmethod
    def areTabsEnabled(chat):
        # Android also honours its debug switch ``SharedConfig.forceForumTabs``; this application has none.
        return chat is not None and chat.forum_tabs


def _attributes(document, kind):
    return [item for item in document.attributes if isinstance(item, kind)]


@_local_arguments
class FileLoader(_Java):
    """``FileLoader``: Android file naming, and local paths/downloads through the host."""
    __ayu_requires__ = ("telegram.files.path", "telegram.files.load")
    PRIORITY_LOW, PRIORITY_NORMAL, PRIORITY_NORMAL_UP, PRIORITY_HIGH = 0, 1, 2, 3
    MEDIA_DIR_IMAGE, MEDIA_DIR_AUDIO, MEDIA_DIR_VIDEO, MEDIA_DIR_DOCUMENT, MEDIA_DIR_CACHE = 0, 1, 2, 3, 4
    MEDIA_DIR_FILES, MEDIA_DIR_STORIES, MEDIA_DIR_IMAGE_PUBLIC, MEDIA_DIR_VIDEO_PUBLIC = 5, 6, 100, 101
    IMAGE_TYPE_LOTTIE, IMAGE_TYPE_ANIMATION, IMAGE_TYPE_SVG, IMAGE_TYPE_SVG_WHITE = 1, 2, 3, 4
    IMAGE_TYPE_THEME_PREVIEW, IMAGE_TYPE_SVG_DOCUMENT, PRELOAD_CACHE_TYPE = 5, 6, 11
    DEFAULT_MAX_FILE_SIZE = 1024 * 1024 * 2001
    DEFAULT_MAX_FILE_SIZE_PREMIUM = DEFAULT_MAX_FILE_SIZE * 2

    def __init__(self, account):
        self.__dict__["currentAccount"] = _account(account)

    @staticmethod
    def getInstance(num):
        return FileLoader(num)

    @staticmethod
    def fixFileName(fileName):
        if fileName is not None:
            fileName = re.sub("[\u0001-\u001f<>\u202e:\"/\\\\|?*\u007f]+", "", fileName).strip(
                "".join(map(chr, range(33))))
        return fileName

    @staticmethod
    def getDocumentFileName(document):
        if document is None:
            return None
        if document.file_name_fixed is not None:
            return document.file_name_fixed
        fileName = document.file_name
        if fileName is None:
            for attribute in _attributes(document, TLRPC.TL_documentAttributeFilename):
                fileName = attribute.file_name
        fileName = FileLoader.fixFileName(fileName)
        return fileName if fileName is not None else ""

    @staticmethod
    def getExtensionByMimeType(mime):
        return {"video/mp4": ".mp4", "video/x-matroska": ".mkv", "audio/ogg": ".ogg"}.get(mime, "")

    @staticmethod
    def getDocumentExtension(document):
        fileName = FileLoader.getDocumentFileName(document)
        index = fileName.rfind(".")
        ext = fileName[index + 1:] if index != -1 else None
        if not ext:
            ext = document.mime_type
        return (ext or "").upper()

    @staticmethod
    def getAttachFileName(attach, *args):
        if len(args) > 2:
            raise TypeError("getAttachFileName(attach[, size], ext)")
        size, ext = (None, args[0]) if len(args) == 1 else args if args else (None, None)
        if isinstance(attach, TLRPC.Document):
            name = FileLoader.getDocumentFileName(attach)
            index = name.rfind(".")
            docExt = "" if index == -1 else name[index:]
            if len(docExt) <= 1:
                docExt = FileLoader.getExtensionByMimeType(attach.mime_type)
            return f"{attach.dc_id}_{attach.id}" + (docExt if len(docExt) > 1 else "")
        if isinstance(attach, TLRPC.TL_secureFile):
            return f"{attach.dc_id}_{attach.id}.jpg"
        if isinstance(attach, (TLRPC.PhotoSize, TLRPC.TL_videoSize)):
            location = attach.location
            if location is None or isinstance(location, TLRPC.TL_fileLocationUnavailable):
                return ""
            default = "jpg" if isinstance(attach, TLRPC.PhotoSize) else "mp4"
            return f"{location.volume_id}_{location.local_id}." + (ext if ext is not None else default)
        if isinstance(attach, TLRPC.FileLocation):
            if isinstance(attach, TLRPC.TL_fileLocationUnavailable):
                return ""
            return f"{attach.volume_id}_{attach.local_id}." + (ext if ext is not None else "jpg")
        if isinstance(attach, (TLRPC.UserProfilePhoto, TLRPC.ChatPhoto)):
            if size is None and isinstance(attach, TLRPC.UserProfilePhoto):
                size = "s"
            if attach.photo_small is not None:
                return FileLoader.getAttachFileName(attach.photo_small if size == "s" else attach.photo_big, ext)
            return f"{attach.photo_id}_{'null' if size is None else size}." + (ext if ext is not None else "jpg")
        if isinstance(attach, tl.TLObject) or attach is None:
            return ""
        raise _unsupported("FileLoader.getAttachFileName does not support " + type(attach).__name__)

    @staticmethod
    def getClosestPhotoSizeWithSize(sizes, side, byMinSide=False, toIgnore=None, ignoreStripped=False):
        if not sizes:
            return None
        lastSide, closest = 0, None
        for item in sizes:
            if (item is None or item is toIgnore or isinstance(item, (TLRPC.TL_photoSizeEmpty, TLRPC.TL_photoPathSize))
                    or ignoreStripped and isinstance(item, TLRPC.TL_photoStrippedSize)):
                continue
            unavailable = (side > 100 and closest is not None and closest.location is not None
                           and closest.location.dc_id == -(2 ** 31))
            cached = isinstance(item, TLRPC.TL_photoCachedSize)
            if byMinSide:
                current = min(item.h, item.w)
                take = closest is None or unavailable or cached or side > lastSide and lastSide < current
            else:
                current = max(item.w, item.h)
                take = closest is None or unavailable or cached or current <= side and lastSide < current
            if take:
                closest, lastSide = item, current
        return closest

    # Host-backed instance members.
    def _target(self, value):
        if isinstance(value, MessageObject):
            value = value.messageOwner
        locate = vars(type(value)).get("_ayu_file_target")
        if locate is not None:
            value = locate(value)
        if not isinstance(value, tl.TLObject):
            raise TypeError("Expected a TL object or MessageObject")
        return value

    def _path(self, target, cache):
        result = _call("telegram.files.path", {"account": self.currentAccount, "target": self._target(target),
                                                "cache": bool(cache)})
        if not isinstance(result, str) or not result.startswith("/"):
            raise _runtime_error("Host returned an invalid file path")
        return _runtime().jclass("java.io.File")(result)

    def getPathToMessage(self, message, useFileDatabaseQueue=True):
        if message is None:
            return _runtime().jclass("java.io.File")("")
        return self._path(message, False)

    def getPathToAttach(self, attach, *args):
        """``getPathToAttach(attach[, ext][, forceCache])``; the extension does not select another file."""
        if len(args) > 3:
            raise TypeError("getPathToAttach(attach[, size][, ext], forceCache)")
        return self._path(attach, bool(args and args[-1] is True))

    def loadFile(self, *args):
        """``loadFile(document|photoSize|…, parentObject, priority, cacheType)`` and its shorter forms."""
        if not args:
            raise TypeError("loadFile needs a file object")
        target = self._target(args[0])
        numbers = [item for item in args[1:] if type(item) is int]
        parent = next((item for item in args[1:] if isinstance(item, (MessageObject, tl.TLObject))), None)
        arguments = {"account": self.currentAccount, "target": target,
                     "priority": numbers[0] if numbers else FileLoader.PRIORITY_NORMAL,
                     "cache_type": numbers[1] if len(numbers) > 1 else 0}
        if parent is not None:
            arguments["parent"] = self._target(parent)
        _call("telegram.files.load", arguments)

    def cancelLoadFile(self, target, *args):
        _call("telegram.files.load", {"account": self.currentAccount, "target": self._target(target), "cancel": True})


def _runtime_error(message):
    from ayu_bridge import ProtocolError
    return ProtocolError(message)


# --- MessageObject --------------------------------------------------------------

@_local_arguments
class MessageObject(_Java):
    """``MessageObject`` over a ``TLRPC.Message``: identifiers, media classification and audio metadata."""
    TYPE_TEXT, TYPE_PHOTO, TYPE_VOICE, TYPE_VIDEO, TYPE_GEO, TYPE_ROUND_VIDEO, TYPE_LOADING = 0, 1, 2, 3, 4, 5, 6
    TYPE_GIF, TYPE_FILE, TYPE_DATE, TYPE_ACTION_PHOTO, TYPE_CONTACT, TYPE_STICKER, TYPE_MUSIC = 8, 9, 10, 11, 12, 13, 14
    TYPE_ANIMATED_STICKER, TYPE_PHONE_CALL, TYPE_POLL, TYPE_GIFT_PREMIUM, TYPE_EMOJIS = 15, 16, 17, 18, 19
    TYPE_EXTENDED_MEDIA_PREVIEW, TYPE_SUGGEST_PHOTO, TYPE_ACTION_WALLPAPER, TYPE_STORY, TYPE_STORY_MENTION = 20, 21, 22, 23, 24
    TYPE_GIFT_PREMIUM_CHANNEL, TYPE_GIVEAWAY, TYPE_JOINED_CHANNEL, TYPE_GIVEAWAY_RESULTS, TYPE_PAID_MEDIA = 25, 26, 27, 28, 29
    TYPE_GIFT_STARS, TYPE_GIFT_THEME_UPDATE, TYPE_SUGGEST_BIRTHDAY, TYPE_GIFT_OFFER, TYPE_GIFT_OFFER_REJECTED = 30, 31, 32, 33, 34
    TYPE_SHARING_OFFER, TYPE_ARTICLE, TYPE_COMMUNITY_CHANGED, TYPE_UNSUPPORTED = 35, 36, 37, 38
    POSITION_FLAG_LEFT, POSITION_FLAG_RIGHT, POSITION_FLAG_TOP, POSITION_FLAG_BOTTOM = 1, 2, 4, 8

    def __init__(self, accountNum, message, *layout):
        """``MessageObject(accountNum, message, …)``; the remaining Android arguments only drive text layout."""
        if not isinstance(message, TLRPC.Message):
            raise TypeError("MessageObject needs a TLRPC.Message")
        values = self.__dict__
        values["currentAccount"] = _account(accountNum)
        values["messageOwner"] = message
        values["replyMessageObject"] = next((item for item in layout if isinstance(item, MessageObject)), None)
        values["audioProgress"], values["audioProgressSec"], values["deleted"], values["eventId"] = 0.0, 0, False, 0
        values["isTopicMainMessage"] = False

    def __setattr__(self, name, value):
        if name not in ("messageOwner", "replyMessageObject", "audioProgress", "audioProgressSec", "deleted",
                        "eventId", "currentAccount", "isTopicMainMessage"):
            raise _unsupported(f"MessageObject.{name} is not implemented")
        object.__setattr__(self, name, value)

    def to_bridge(self):
        return {"dialog_id": self.getDialogId(), "id": self.getId(), "message": self.messageOwner}

    @property
    def messageText(self):
        owner = self.messageOwner
        if isinstance(owner, TLRPC.TL_messageService) or not self.isMediaEmpty():
            raise _unsupported("MessageObject.messageText of service and media messages is a localized label")
        return owner.message

    @property
    def caption(self):
        owner = self.messageOwner
        if self.isRoundVideo() or self.isMediaEmpty() or isinstance(MessageObject.getMedia(owner), TLRPC.TL_messageMediaGame):
            return None
        return owner.message or None

    # Identity
    def getId(self):
        owner = self.messageOwner
        return owner.ephemeralAnchorMsgId if owner.ephemeralAnchorMsgId != 0 else owner.id

    def getRealId(self):
        owner = self.messageOwner
        return owner.realId if owner.realId != 0 else owner.id

    def getChatId(self=None, message=None):
        owner = message if message is not None else self.messageOwner if isinstance(self, MessageObject) else self
        if owner is None:
            return 0
        if isinstance(owner.peer_id, TLRPC.TL_peerChat):
            return owner.peer_id.chat_id
        if isinstance(owner.peer_id, TLRPC.TL_peerChannel):
            return owner.peer_id.channel_id
        return 0

    @staticmethod
    def getPeerId(peer):
        if peer is None:
            return 0
        if isinstance(peer, TLRPC.TL_peerChat):
            return -peer.chat_id
        if isinstance(peer, TLRPC.TL_peerChannel):
            return -peer.channel_id
        return peer.user_id

    def getGroupId(self):
        return self.messageOwner.grouped_id

    getGroupIdForUse = getGroupId

    def isOut(self):
        return MessageObject._owner(self).out

    def isFromUser(self):
        owner = self.messageOwner
        return isinstance(owner.from_id, TLRPC.TL_peerUser) and not owner.post

    def isReply(self):
        owner = self.messageOwner
        reply = owner.reply_to
        return (not (self.replyMessageObject is not None and isinstance(self.replyMessageObject.messageOwner, TLRPC.TL_messageEmpty))
                and reply is not None and (reply.reply_to_msg_id != 0 or reply.reply_to_random_id != 0)
                and owner.flags & TLRPC.MESSAGE_FLAG_REPLY != 0)

    def getReplyMsgId(self):
        reply = self.messageOwner.reply_to
        return reply.reply_to_msg_id if reply is not None else 0

    def getEntities(self):
        return self.messageOwner.entities

    def isMediaEmpty(self=None, message=None):
        owner = message if message is not None else self.messageOwner if isinstance(self, MessageObject) else self
        if owner is None:
            return True
        media = MessageObject.getMedia(owner)
        return media is None or isinstance(media, (TLRPC.TL_messageMediaEmpty, TLRPC.TL_messageMediaWebPage))

    def _owner(self):
        """The message of an instance call, or of a static call made with a ``TLRPC.Message``."""
        return self.messageOwner if isinstance(self, MessageObject) else self

    # Each accessor below is Android's instance method and its static overload on a TLRPC.Message.
    def getDialogId(self):
        message = MessageObject._owner(self)
        if message.dialog_id == 0 and message.peer_id is not None:
            if message.peer_id.chat_id != 0:
                message.dialog_id = -message.peer_id.chat_id
            elif message.peer_id.channel_id != 0:
                message.dialog_id = -message.peer_id.channel_id
            elif message.from_id is None or message.out or message.guestchat_via_from is not None:
                message.dialog_id = message.peer_id.user_id
            else:
                message.dialog_id = message.from_id.user_id
        return message.dialog_id

    def getFromChatId(self):
        return MessageObject.getPeerId(MessageObject._owner(self).from_id)

    def isSavedFromMegagroup(self):
        forward = self.messageOwner.fwd_from
        if forward is None or forward.saved_from_peer is None or forward.saved_from_peer.channel_id == 0:
            return False
        controller = MessagesController._ayu_usable().getInstance(self.currentAccount)
        return ChatObject.isMegagroup(controller.getChat(forward.saved_from_peer.channel_id))

    def getSenderId(self):
        """Who wrote the message; for one saved from another chat, who wrote it there."""
        message = self.messageOwner
        forward = message.fwd_from
        saved = forward.saved_from_peer if forward is not None else None
        if saved is None:
            if message.from_id is not None:
                return MessageObject.getPeerId(message.from_id)
            # Android answers the bare channel id of a post here, not the negative dialog id.
            return message.peer_id.channel_id if message.post else 0
        origin = forward.from_id
        from_user = isinstance(origin, TLRPC.TL_peerUser)
        if saved.user_id != 0:
            return origin.user_id if from_user else saved.user_id
        if saved.channel_id == 0 and saved.chat_id == 0:
            return 0
        if from_user and (saved.channel_id == 0 or self.isSavedFromMegagroup()):
            return origin.user_id
        if isinstance(origin, (TLRPC.TL_peerChannel, TLRPC.TL_peerChat)):
            return MessageObject.getPeerId(origin)
        return -saved.channel_id if saved.channel_id != 0 else -saved.chat_id

    # Topics
    @staticmethod
    def _saved_peer(peer):
        return -peer.chat_id if peer.chat_id != 0 else -peer.channel_id if peer.channel_id != 0 else peer.user_id

    def getMonoForumTopicId(self):
        message = MessageObject._owner(self)
        if message is None or message.saved_peer_id is None:
            return 0
        return MessageObject._saved_peer(message.saved_peer_id)

    @staticmethod
    def getSavedDialogId(selfId, message):
        if message.saved_peer_id is not None:
            return MessageObject._saved_peer(message.saved_peer_id)
        if message.from_id.user_id != selfId:
            return 0
        forward = message.fwd_from
        if forward is not None and forward.saved_from_peer is not None:
            return DialogObject.getPeerDialogId(forward.saved_from_peer)
        return UserObject.ANONYMOUS if forward is not None and forward.from_id is None else selfId

    def getTopicId(self, *arguments):
        """``getTopicId()``, and static ``getTopicId(currentAccount, message[, sureIsForum | forumTypeFlags])``."""
        if isinstance(self, MessageObject) and not arguments:
            controller = MessagesController._ayu_usable().getInstance(self.currentAccount)
            dialog = self.getDialogId()
            chat, user = controller.getChat(-dialog), controller.getUser(dialog)
            account, message = self.currentAccount, self.messageOwner
            flags = ((MessagesStorage.FORUM_TYPE_CHAT if ChatObject.isForum(chat) else 0)
                     | (MessagesStorage.FORUM_TYPE_DIRECT if ChatObject.isMonoForum(chat) else 0)
                     | (MessagesStorage.FORUM_TYPE_BOT if UserObject.isBotForum(user) else 0))
        elif isinstance(self, MessageObject) or len(arguments) not in (1, 2):
            raise TypeError("MessageObject.getTopicId takes () or (currentAccount, message[, sureIsForum])")
        else:
            account, message, flags = _account(self), arguments[0], arguments[1] if len(arguments) == 2 else False
        if type(flags) is bool:
            return MessageObject._topic(account, message, flags, False)
        topic = MessageObject._topic(account, message, bool(flags & MessagesStorage.FORUM_TYPE_CHAT),
                                     bool(flags & MessagesStorage.FORUM_TYPE_DIRECT))
        # -1 is a bot forum's pending topic.
        return -1 if topic == 0 and flags & MessagesStorage.FORUM_TYPE_BOT else topic

    @staticmethod
    def _topic(account, message, forum, monoforum):
        own = _client().get_user_config(account).getClientUserId()
        if monoforum:
            return MessageObject.getMonoForumTopicId(message)
        if message.flags & 0x40000000 and DialogObject.getPeerDialogId(message.peer_id) == own:
            return message.quick_reply_shortcut_id
        if not forum and DialogObject.getPeerDialogId(message.peer_id) == own:
            return MessageObject.getSavedDialogId(own, message)
        if isinstance(message.action, TLRPC.TL_messageActionTopicCreate):
            return message.id
        reply = message.reply_to
        if reply is None or not reply.forum_topic:
            return 1 if forum else 0  # 1 is the general topic
        first, second = reply.reply_to_top_id, reply.reply_to_msg_id
        if isinstance(message, TLRPC.TL_messageService) and not isinstance(message.action, TLRPC.TL_messageActionPinMessage):
            first, second = second, first
        return first if first != 0 else second

    def getMedia(self):
        owner = MessageObject._owner(self)
        if owner is None:
            return None
        media = owner.media
        if (media is not None and not isinstance(media, TLRPC.TL_messageMediaPaidMedia) and media.extended_media
                and isinstance(media.extended_media[0], TLRPC.TL_messageExtendedMedia)):
            return media.extended_media[0].media
        return media

    def getDocument(self):
        message = MessageObject._owner(self)
        if message is None:
            return None
        if message.rich_message is not None:
            raise _unsupported("MessageObject.getDocument does not read rich messages")
        media = MessageObject.getMedia(message)
        if isinstance(media, TLRPC.TL_messageMediaWebPage):
            return media.webpage.document
        if isinstance(media, TLRPC.TL_messageMediaGame):
            return media.game.document
        if isinstance(media, TLRPC.TL_messageMediaStory):
            story = media.storyItem
            if story is not None and story.media is not None and story.media.document is not None:
                return story.media.document
        elif isinstance(media, TLRPC.TL_messageMediaPaidMedia):
            extended = media.extended_media
            if len(extended) == 1 and isinstance(extended[0], TLRPC.TL_messageExtendedMedia):
                return extended[0].media.document
        return media.document if media is not None else None

    def getPhoto(self):
        message = MessageObject._owner(self)
        if message is not None and message.rich_message is not None:
            raise _unsupported("MessageObject.getPhoto does not read rich messages")
        media = MessageObject.getMedia(message)
        if isinstance(media, TLRPC.TL_messageMediaWebPage):
            return media.webpage.photo
        return media.photo if media is not None else None

    def _media_document(self, webpage_requires_page=False):
        """The document Android's ``is*Message`` helpers classify."""
        media = MessageObject.getMedia(MessageObject._owner(self))
        if isinstance(media, TLRPC.TL_messageMediaWebPage) and (not webpage_requires_page or media.webpage is not None):
            return media.webpage.document
        return media.document if media is not None else None

    def isVoice(self):
        return MessageObject.isVoiceDocument(MessageObject._media_document(self))

    def isRoundVideo(self):
        return MessageObject.isRoundVideoDocument(MessageObject._media_document(self, True))

    def isGif(self):
        message = MessageObject._owner(self)
        media = MessageObject.getMedia(message)
        if isinstance(media, TLRPC.TL_messageMediaWebPage):
            return MessageObject.isGifDocument(media.webpage.document)
        return media is not None and MessageObject.isGifDocument(media.document, message.grouped_id != 0)

    def isVideo(self):
        message = MessageObject._owner(self)
        if message is not None and message.rich_message is not None:
            raise _unsupported("MessageObject.isVideo does not read rich messages")
        media = MessageObject.getMedia(message)
        if media is not None and MessageObject.isVideoStickerDocument(media.document):
            return False
        return MessageObject.isVideoDocument(MessageObject._media_document(self))

    def isMusic(self):
        music = MessageObject.isMusicDocument(MessageObject._media_document(self))
        if isinstance(self, MessageObject):
            return music and not self.isVideo() and not self.isRoundVideo()
        return music

    def isPhoto(self):
        message = MessageObject._owner(self)
        if message is not None and message.rich_message is not None:
            raise _unsupported("MessageObject.isPhoto does not read rich messages")
        media = MessageObject.getMedia(message)
        if isinstance(media, TLRPC.TL_messageMediaWebPage):
            return isinstance(media.webpage.photo, TLRPC.TL_photo) and not isinstance(media.webpage.document, TLRPC.TL_document)
        if message is not None and message.action is not None and message.action.photo is not None:
            return isinstance(message.action.photo, TLRPC.TL_photo)
        return isinstance(media, TLRPC.TL_messageMediaPhoto) and not media.live_photo

    def isForwarded(self):
        message = MessageObject._owner(self)
        return message.flags & TLRPC.MESSAGE_FLAG_FWD != 0 and message.fwd_from is not None

    def getSize(self):
        media = MessageObject.getMedia(MessageObject._owner(self))
        if isinstance(media, TLRPC.TL_messageMediaWebPage) and media.webpage is not None:
            document = media.webpage.document
        elif isinstance(media, TLRPC.TL_messageMediaGame):
            document = media.game.document
        else:
            document = media.document if media is not None else None
        return document.size if document is not None else 0

    def getFileName(self):
        """``getFileName()`` and its static forms for a Message, MessageMedia or Document."""
        owner = MessageObject._owner(self)
        if isinstance(owner, TLRPC.Document):
            return FileLoader.getAttachFileName(owner)
        if isinstance(owner, TLRPC.Message):
            document = MessageObject.getDocument(owner)
            if isinstance(self, MessageObject) and document is not None:
                return FileLoader.getAttachFileName(document)
            media = MessageObject.getMedia(owner)
        else:
            media, document = owner, getattr(owner, "document", None)
        if isinstance(media, TLRPC.TL_messageMediaDocument):
            return FileLoader.getAttachFileName(document)
        if isinstance(media, TLRPC.TL_messageMediaPhoto):
            raise _unsupported("MessageObject.getFileName of a photo needs AndroidUtilities.getPhotoSize")
        if isinstance(media, TLRPC.TL_messageMediaWebPage) and media.webpage is not None:
            return FileLoader.getAttachFileName(media.webpage.document)
        return ""

    isVoiceMessage, isRoundVideoMessage, isGifMessage, isVideoMessage = isVoice, isRoundVideo, isGif, isVideo
    isMusicMessage, isForwardedMessage, getMessageSize = isMusic, isForwarded, getSize

    def getDocumentName(self):
        return FileLoader.getDocumentFileName(self.getDocument())

    def getDuration(self):
        document = self.getDocument()
        if document is None:
            return 0
        for attribute in document.attributes:
            if isinstance(attribute, (TLRPC.TL_documentAttributeAudio, TLRPC.TL_documentAttributeVideo)):
                return attribute.duration
        return 0

    def getMusicTitle(self, unknown=True):
        document = self.getDocument()
        if document is not None:
            for attribute in document.attributes:
                if isinstance(attribute, TLRPC.TL_documentAttributeAudio):
                    if attribute.voice:
                        if not unknown:
                            return None
                        raise _unsupported("MessageObject.getMusicTitle of a voice message is a localized date")
                    title = attribute.title or FileLoader.getDocumentFileName(document)
                    return title or ("Unknown title" if unknown else title)
                if isinstance(attribute, TLRPC.TL_documentAttributeVideo) and attribute.round_message:
                    raise _unsupported("MessageObject.getMusicTitle of a video message is a localized date")
            fileName = FileLoader.getDocumentFileName(document)
            if fileName:
                return fileName
        return "Unknown title" if unknown else None

    def getMusicAuthor(self, unknown=True):
        document = self.getDocument()
        if document is not None:
            for attribute in document.attributes:
                if isinstance(attribute, TLRPC.TL_documentAttributeAudio) and not attribute.voice:
                    return attribute.performer or ("Unknown artist" if unknown else attribute.performer)
                if (isinstance(attribute, TLRPC.TL_documentAttributeAudio)
                        or isinstance(attribute, TLRPC.TL_documentAttributeVideo) and attribute.round_message):
                    if not unknown:
                        return None
                    raise _unsupported("MessageObject.getMusicAuthor of a voice message is the sender's localized name")
        return "Unknown artist" if unknown else None

    # Document classification (static on Android).
    @staticmethod
    def isVoiceDocument(document):
        if document is not None:
            for attribute in _attributes(document, TLRPC.TL_documentAttributeAudio):
                return attribute.voice
        return False

    @staticmethod
    def isMusicDocument(document):
        if document is None:
            return False
        for attribute in _attributes(document, TLRPC.TL_documentAttributeAudio):
            return not attribute.voice
        if document.mime_type:
            mime = document.mime_type.lower()
            if mime in ("audio/flac", "audio/ogg", "audio/opus", "audio/x-opus+ogg", "audio/wav", "audio/x-wav"):
                return True
            return mime == "application/octet-stream" and FileLoader.getDocumentFileName(document).endswith(".opus")
        return False

    @staticmethod
    def _video_size(document):
        width = height = 0
        animated = False
        for attribute in document.attributes:
            if isinstance(attribute, TLRPC.TL_documentAttributeAnimated):
                animated = True
            elif isinstance(attribute, TLRPC.TL_documentAttributeVideo):
                width, height = attribute.w, attribute.h
        return width, height, animated

    @staticmethod
    def isRoundVideoDocument(document):
        if document is not None and document.mime_type == "video/mp4":
            width = height = 0
            round_message = False
            for attribute in _attributes(document, TLRPC.TL_documentAttributeVideo):
                width, height, round_message = attribute.w, attribute.h, attribute.round_message
            return round_message and width <= 1280 and height <= 1280
        return False

    @staticmethod
    def isNewGifDocument(document):
        if document is not None and document.mime_type == "video/mp4":
            width, height, animated = MessageObject._video_size(document)
            return animated and width <= 1280 and height <= 1280
        return False

    @staticmethod
    def isGifDocument(document, hasGroup=False):
        return (document is not None and document.mime_type is not None
                and (document.mime_type == "image/gif" and not hasGroup or MessageObject.isNewGifDocument(document)))

    @staticmethod
    def isStickerDocument(document):
        if document is not None and _attributes(document, TLRPC.TL_documentAttributeSticker):
            return document.mime_type in ("image/webp", "video/webm")
        return False

    @staticmethod
    def isVideoStickerDocument(document):
        if document is not None and _attributes(document, (TLRPC.TL_documentAttributeSticker,
                                                           TLRPC.TL_documentAttributeCustomEmoji)):
            return document.mime_type == "video/webm"
        return False

    @staticmethod
    def isStaticStickerDocument(document):
        return document is not None and document.mime_type == "image/webp"

    @staticmethod
    def isAnimatedStickerDocument(document, allowWithoutSet=None):
        if allowWithoutSet is None:
            return document is not None and document.mime_type == "video/webm"
        if document is not None and (document.mime_type == "application/x-tgsticker" and document.thumbs
                                     or document.mime_type == "application/x-tgsdice"):
            if allowWithoutSet:
                return True
            for attribute in document.attributes:
                if isinstance(attribute, TLRPC.TL_documentAttributeSticker):
                    return isinstance(attribute.stickerset, TLRPC.TL_inputStickerSetShortName)
                if isinstance(attribute, TLRPC.TL_documentAttributeCustomEmoji):
                    return True
        return False

    @staticmethod
    def isWebM(document):
        return document is not None and document.mime_type == "video/webm"

    @staticmethod
    def isAnimatedEmoji(document):
        return document is not None and bool(_attributes(document, TLRPC.TL_documentAttributeCustomEmoji))

    @staticmethod
    def isV(ext):
        return ext is None or _java_hash(ext.lower()) in _NOT_VIDEO

    @staticmethod
    def isVideoDocument(document):
        if document is None:
            return False
        animated = video = False
        filename = None
        width = height = 0
        for attribute in document.attributes:
            if isinstance(attribute, TLRPC.TL_documentAttributeVideo):
                if attribute.round_message:
                    return False
                video, width, height = True, attribute.w, attribute.h
            elif isinstance(attribute, TLRPC.TL_documentAttributeAnimated):
                animated = True
            elif isinstance(attribute, TLRPC.TL_documentAttributeFilename):
                filename = attribute.file_name
        if filename is not None and "." in filename and MessageObject.isV(filename[filename.rfind(".") + 1:]):
            return False
        if animated and (width > 1280 or height > 1280):
            animated = False
        return video and not animated

    def isVideoSticker(self):
        document = self.getDocument() if isinstance(self, MessageObject) else self
        return document is not None and MessageObject.isVideoStickerDocument(document)

    def _raw_sticker(self):
        document = self.getDocument()
        return MessageObject.isStickerDocument(document) or MessageObject.isVideoSticker(document)

    def _raw_animated_sticker(self):
        owner = self.messageOwner
        secret = DialogObject.isEncryptedDialog(self.getDialogId())
        if secret and owner.stickerVerified != 1:
            return False
        return MessageObject.isAnimatedStickerDocument(self.getDocument(), not secret or self.isOut())

    def _media_type(self):
        """Android's ``setType`` for a message with media; 1000 is its unset value, None a service type."""
        owner = self.messageOwner
        if isinstance(owner, TLRPC.TL_messageService):
            return None
        if not isinstance(owner, TLRPC.TL_message):
            return 1000
        media = MessageObject.getMedia(owner)
        if isinstance(media, TLRPC.TL_messageMediaUnsupported):
            return MessageObject.TYPE_UNSUPPORTED
        if owner.restriction_reason:
            raise _unsupported("MessageObject type of a message with restriction reasons needs the app's restriction rules")
        if owner.rich_message is not None or isinstance(media, TLRPC.TL_messageMediaWidget):
            return MessageObject.TYPE_ARTICLE
        if isinstance(owner.media, TLRPC.TL_messageMediaPaidMedia):
            return MessageObject.TYPE_PAID_MEDIA
        if self.isMediaEmpty():
            return MessageObject.TYPE_TEXT
        if (not isinstance(owner.media, TLRPC.TL_messageMediaPaidMedia) and owner.media.extended_media
                and isinstance(owner.media.extended_media[0], TLRPC.TL_messageExtendedMediaPreview)):
            return MessageObject.TYPE_EXTENDED_MEDIA_PREVIEW
        if media.ttl_seconds != 0 and (isinstance(media.photo, TLRPC.TL_photoEmpty)
                                       or isinstance(self.getDocument(), TLRPC.TL_documentEmpty)
                                       or isinstance(media, TLRPC.TL_messageMediaDocument) and self.getDocument() is None):
            return MessageObject.TYPE_DATE
        if isinstance(media, TLRPC.TL_messageMediaGiveaway):
            return MessageObject.TYPE_GIVEAWAY
        if isinstance(media, TLRPC.TL_messageMediaGiveawayResults):
            return MessageObject.TYPE_GIVEAWAY_RESULTS
        if isinstance(media, TLRPC.TL_messageMediaDice):
            return MessageObject.TYPE_ANIMATED_STICKER
        if isinstance(media, TLRPC.TL_messageMediaPhoto):
            return MessageObject.TYPE_VIDEO if self.isVideo() else MessageObject.TYPE_PHOTO
        if isinstance(media, (TLRPC.TL_messageMediaGeo, TLRPC.TL_messageMediaVenue, TLRPC.TL_messageMediaGeoLive)):
            return MessageObject.TYPE_GEO
        if self.isRoundVideo():
            return MessageObject.TYPE_ROUND_VIDEO
        if self.isVideo():
            return MessageObject.TYPE_VIDEO
        if self.isVoice():
            return MessageObject.TYPE_VOICE
        if self.isMusic():
            return MessageObject.TYPE_MUSIC
        if isinstance(media, TLRPC.TL_messageMediaContact):
            return MessageObject.TYPE_CONTACT
        if isinstance(media, (TLRPC.TL_messageMediaPoll, TLRPC.TL_messageMediaToDo)):
            return MessageObject.TYPE_POLL
        if isinstance(media, TLRPC.TL_messageMediaDocument):
            document = self.getDocument()
            if document is not None and document.mime_type is not None:
                # hasValidGroupId() here: every document that reaches this branch counts as isDocument().
                if MessageObject.isGifDocument(document, self.getGroupId() != 0):
                    return MessageObject.TYPE_GIF
                if self._raw_sticker():
                    return MessageObject.TYPE_STICKER
                if self._raw_animated_sticker():
                    return MessageObject.TYPE_ANIMATED_STICKER
            return MessageObject.TYPE_FILE
        if isinstance(media, (TLRPC.TL_messageMediaGame, TLRPC.TL_messageMediaInvoice)):
            return MessageObject.TYPE_TEXT
        if isinstance(media, TLRPC.TL_messageMediaStory):
            return MessageObject.TYPE_STORY_MENTION if media.via_mention else MessageObject.TYPE_STORY
        return 1000

    def _may_be_big_emoji(self):
        """Whether Android may show this text message as one big emoji, whose sticker is app state."""
        owner = self.messageOwner
        media = MessageObject.getMedia(owner)
        if not isinstance(owner, TLRPC.TL_message) or owner.grouped_id != 0 or owner.restriction_reason:
            return False
        if media is not None and not isinstance(media, TLRPC.TL_messageMediaEmpty):
            return False
        text, entities = owner.message or "", owner.entities
        if not text or len(entities) > 1 or entities and not isinstance(entities[0], TLRPC.TL_messageEntityCustomEmoji):
            return False
        keycap = "\u20e3" in text
        for char in text:
            if char < "\x80":
                if not (keycap and char in "0123456789#*"):
                    return False
            elif char != "\u2139" and unicodedata.category(char)[0] in "LZ":
                return False
        return True

    def isSticker(self):
        if not isinstance(self, MessageObject):
            raise TypeError("MessageObject.isSticker is an instance method")
        if self._may_be_big_emoji():
            raise _unsupported("MessageObject.isSticker of an emoji-only text message needs the app's animated emoji")
        kind = self._media_type()
        return self._raw_sticker() if kind == 1000 else kind == MessageObject.TYPE_STICKER

    def isDocument(self):
        if not isinstance(self, MessageObject):
            raise TypeError("MessageObject.isDocument is an instance method")
        # An emoji-only text message has either no document or a sticker type, so the answer is the same.
        if self.getDocument() is None or self.isVideo() or self.isMusic() or self.isVoice():
            return False
        return self._media_type() not in (MessageObject.TYPE_STICKER, MessageObject.TYPE_ANIMATED_STICKER,
                                          MessageObject.TYPE_EMOJIS)


# --- Host-backed controllers ----------------------------------------------------

def _peer(account, kind, identifier, expected):
    if identifier is None or _int(identifier, 64, "id") <= 0:
        # Android's peer maps hold positive ids only, and the host accepts no other id.
        return None
    value = _call("telegram.peer", {"account": account, "kind": kind, "id": identifier})
    return tl.from_bridge(value, expected)


class MessagesController(_Java):
    """``MessagesController``: cached users and chats as TL objects, and Android's input-peer rules.

    Replaces the host adapter, which exposes only the account's own profile and the visible chat.
    """
    __ayu_requires__ = ("client.call", "telegram.peer")
    __ayu_overrides_host__ = True
    UPDATE_MASK_NAME, UPDATE_MASK_AVATAR, UPDATE_MASK_STATUS, UPDATE_MASK_CHAT_AVATAR = 1, 2, 4, 8
    UPDATE_MASK_CHAT_NAME, UPDATE_MASK_CHAT_MEMBERS, UPDATE_MASK_USER_PRINT, UPDATE_MASK_USER_PHONE = 16, 32, 64, 128
    UPDATE_MASK_READ_DIALOG_MESSAGE, UPDATE_MASK_SELECT_DIALOG, UPDATE_MASK_PHONE = 256, 512, 1024
    UPDATE_MASK_NEW_MESSAGE, UPDATE_MASK_SEND_STATE, UPDATE_MASK_CHAT, UPDATE_MASK_CHAT_ADMINS = 2048, 4096, 8192, 16384
    UPDATE_MASK_MESSAGE_TEXT, UPDATE_MASK_CHECK, UPDATE_MASK_REORDER = 32768, 65536, 131072
    UPDATE_MASK_EMOJI_INTERACTIONS, UPDATE_MASK_EMOJI_STATUS, UPDATE_MASK_REACTIONS_READ = 262144, 524288, 1048576
    UPDATE_MASK_ALL = 2 | 4 | 1 | 8 | 16 | 32 | 64 | 128 | 256 | 1024
    DIALOG_FILTER_FLAG_CONTACTS, DIALOG_FILTER_FLAG_NON_CONTACTS, DIALOG_FILTER_FLAG_GROUPS = 0x1, 0x2, 0x4
    DIALOG_FILTER_FLAG_CHANNELS, DIALOG_FILTER_FLAG_BOTS, DIALOG_FILTER_FLAG_EXCLUDE_MUTED = 0x8, 0x10, 0x20
    DIALOG_FILTER_FLAG_EXCLUDE_READ, DIALOG_FILTER_FLAG_EXCLUDE_ARCHIVED, DIALOG_FILTER_FLAG_ONLY_ARCHIVED = 0x40, 0x80, 0x100
    DIALOG_FILTER_FLAG_ALL_CHATS = 0x1 | 0x2 | 0x4 | 0x8 | 0x10
    DIALOG_FILTER_FLAG_CHATLIST, DIALOG_FILTER_FLAG_CHATLIST_ADMIN = 0x200, 0x400

    def __init__(self, account):
        self.__dict__["currentAccount"] = _account(account)

    @classmethod
    def _ayu_usable(cls):
        """This class when the host makes it usable; pure helpers that need peers raise otherwise."""
        runtime = _runtime()
        runtime.require()
        if PACKAGE + "MessagesController" not in runtime.capabilities.get("local_classes", ()):
            raise _unsupported("Reading cached users and chats needs host operation telegram.peer")
        return cls

    @staticmethod
    def getInstance(num):
        return MessagesController(num)

    def _self_id(self):
        return _client().get_user_config(self.currentAccount).getClientUserId()

    def getUser(self, id):
        return _peer(self.currentAccount, "user", id, TLRPC.User)

    def getChat(self, id):
        return _peer(self.currentAccount, "chat", id, TLRPC.Chat)

    def getUserFull(self, uid):
        return _peer(self.currentAccount, "user_full", uid, TLRPC.UserFull)

    def getChatFull(self, chatId):
        return _peer(self.currentAccount, "chat_full", chatId, TLRPC.ChatFull)

    def getUserOrChat(self, dialogId):
        return self.getUser(dialogId) if _int(dialogId, 64, "dialogId") > 0 else self.getChat(-dialogId)

    def isForum(self, value):
        dialog_id = value.getDialogId() if isinstance(value, MessageObject) else _int(value, 64, "dialogId")
        chat = self.getChat(-dialog_id)
        return chat is not None and chat.forum

    def getPeer(self, id):
        if _int(id, 64, "id") < 0:
            if ChatObject.isChannel(self.getChat(-id)):
                peer = TLRPC.TL_peerChannel()
                peer.channel_id = -id
            else:
                peer = TLRPC.TL_peerChat()
                peer.chat_id = -id
            return peer
        peer = TLRPC.TL_peerUser()
        peer.user_id = id
        return peer

    @staticmethod
    def _origin(value):
        """The message a min user or chat was seen in, when it has no access hash."""
        dialog_id, message_id = getattr(value, "fromMessageDialogId", 0), getattr(value, "fromMessageId", 0)
        return (dialog_id, message_id) if value.access_hash == 0 and dialog_id != 0 and message_id != 0 else None

    def _local(self, value):
        """The cached TL object behind a host ``TLRPC$User``/``TLRPC$Chat`` snapshot; other values as they are."""
        if not _is_host(value):
            return value
        name = getattr(value, "_class_name", None)
        found = (self.getUser(value.id) if name == tl.PACKAGE + "TLRPC$User"
                 else self.getChat(value.id) if name == tl.PACKAGE + "TLRPC$Chat" else None)
        if found is None:
            from ayu_bridge import UnsupportedAPI
            raise UnsupportedAPI(f"MessagesController needs a local TL object, not the host object {value!r}")
        return found

    def getInputPeer(self, value):
        """``getInputPeer(long id | Peer | User | Chat)``."""
        value = self._local(value)
        if isinstance(value, TLRPC.User):
            return self._input_user_peer(value.id, value)
        if isinstance(value, TLRPC.Chat):
            return self._input_chat_peer(value.id, value)
        if isinstance(value, TLRPC.Peer):
            if isinstance(value, TLRPC.TL_peerChat):
                peer = TLRPC.TL_inputPeerChat()
                peer.chat_id = value.chat_id
                return peer
            if isinstance(value, TLRPC.TL_peerChannel):
                return self._input_channel_peer(value.channel_id, self.getChat(value.channel_id), value.channel_id)
            return self._input_user_peer(value.user_id, self.getUser(value.user_id))
        if _int(value, 64, "id") == self._self_id():
            return TLRPC.TL_inputPeerSelf()
        if value < 0:
            chat = self.getChat(-value)
            if ChatObject.isChannel(chat):
                return self._input_channel_peer(-value, chat, value)
            peer = TLRPC.TL_inputPeerChat()
            peer.chat_id = -value
            return peer
        return self._input_user_peer(value, self.getUser(value), value)

    def _input_channel_peer(self, channel_id, chat, exclude=None):
        origin = self._origin(chat) if chat is not None else None
        if origin is not None and origin[0] != exclude:
            peer = TLRPC.TL_inputPeerChannelFromMessage()
            peer.channel_id, peer.peer, peer.msg_id = channel_id, self.getInputPeer(origin[0]), origin[1]
            return peer
        peer = TLRPC.TL_inputPeerChannel()
        peer.channel_id = channel_id
        if chat is not None:
            peer.access_hash = chat.access_hash
        return peer

    def _input_chat_peer(self, chat_id, chat):
        if ChatObject.isChannel(chat):
            return self._input_channel_peer(chat_id, chat)
        peer = TLRPC.TL_inputPeerChat()
        peer.chat_id = chat_id
        return peer

    def _input_user_peer(self, user_id, user, exclude=None):
        origin = self._origin(user) if user is not None else None
        if origin is not None and origin[0] != exclude:
            peer = TLRPC.TL_inputPeerUserFromMessage()
            peer.user_id, peer.peer, peer.msg_id = user_id, self.getInputPeer(origin[0]), origin[1]
            return peer
        peer = TLRPC.TL_inputPeerUser()
        peer.user_id = user_id
        if user is not None:
            peer.access_hash = user.access_hash
        return peer

    def getInputUser(self, value):
        """``getInputUser(long userId | User | InputPeer)``."""
        value = self._local(value)
        if isinstance(value, TLRPC.InputPeer):
            if isinstance(value, TLRPC.TL_inputPeerSelf):
                return TLRPC.TL_inputUserSelf()
            if value.access_hash == 0:
                origin = self._origin(self.getUser(value.user_id))
                if origin is not None:
                    result = TLRPC.TL_inputUserFromMessage()
                    result.user_id, result.peer, result.msg_id = value.user_id, self.getInputPeer(origin[0]), origin[1]
                    return result
            result = TLRPC.TL_inputUser()
            result.user_id, result.access_hash = value.user_id, value.access_hash
            return result
        user = value if isinstance(value, TLRPC.User) or value is None else self.getUser(value)
        if user is None:
            return TLRPC.TL_inputUserEmpty()
        if user.id == self._self_id():
            return TLRPC.TL_inputUserSelf()
        origin = self._origin(user)
        if origin is not None:
            result = TLRPC.TL_inputUserFromMessage()
            result.user_id, result.peer, result.msg_id = user.id, self.getInputPeer(origin[0]), origin[1]
            return result
        result = TLRPC.TL_inputUser()
        result.user_id, result.access_hash = user.id, user.access_hash
        return result

    def getInputChannel(self, value):
        """``getInputChannel(long chatId | Chat | InputPeer)``."""
        value = self._local(value)
        if isinstance(value, TLRPC.InputPeer):
            result = TLRPC.TL_inputChannel()
            result.channel_id, result.access_hash = value.channel_id, value.access_hash
            return result
        chat = value if isinstance(value, TLRPC.Chat) or value is None else self.getChat(value)
        if not ChatObject.isChannel(chat):
            return TLRPC.TL_inputChannelEmpty()
        origin = self._origin(chat)
        if origin is not None:
            result = TLRPC.TL_inputChannelFromMessage()
            result.channel_id, result.peer, result.msg_id = chat.id, self.getInputPeer(origin[0]), origin[1]
            return result
        result = TLRPC.TL_inputChannel()
        result.channel_id, result.access_hash = chat.id, chat.access_hash
        return result

    def openByUserName(self, username, fragment, type, progress=None):
        """``openByUserName(username, fragment, type[, progress])``.

        As on Android nothing happens without a username or a fragment. ``type`` 0 opens a
        non-bot user's profile and the chat of anything else; every other value opens the chat.
        The host navigates from the visible screen, so ``fragment`` must be that screen.
        """
        if username is None or fragment is None:
            return
        if not isinstance(username, str) or not username:
            raise TypeError("username must be a nonempty string")
        from ayu_bridge import UnsupportedAPI
        if "telegram.navigation.open" not in _runtime().capabilities["operations"]:
            raise UnsupportedAPI("MessagesController.openByUserName needs host operation telegram.navigation.open")
        if progress is not None:
            raise UnsupportedAPI("MessagesController.openByUserName with a Browser.Progress is not implemented")
        host = fragment if _is_host(fragment) else getattr(fragment, "__dict__", {}).get("_host")
        if getattr(host, "_class_name", None) != "org.telegram.ui.ActionBar.BaseFragment":
            raise UnsupportedAPI("MessagesController.openByUserName needs a fragment that is on screen")
        _call("telegram.navigation.open", {"account": self.currentAccount, "username": username,
                                           "type": _int(type, 32, "type")})

    # State changes: one host operation each (``telegram.action.*`` in protocol-telegram.md).

    def _action(self, name, member, **arguments):
        operation = "telegram.action." + name
        if operation not in _runtime().capabilities["operations"]:
            raise _unsupported("MessagesController." + member + " needs host operation " + operation)
        arguments["account"] = self.currentAccount
        _dialog_cache.clear()
        return _call(operation, arguments)

    def deleteMessages(self, messages, randoms, encryptedChat, dialogId, *rest):
        """Every Android overload: ``(..., dialogId, [topicId,] forAll, mode[, cacheOnly, ...])``.

        Deletes cloud messages of a chat for this account, or for everyone with ``forAll``. Secret
        chats, scheduled and quick-reply messages (``mode`` other than 0) and a cache-only
        deletion have no host operation and raise.
        """
        if encryptedChat is not None or randoms:
            raise _unsupported("MessagesController.deleteMessages in a secret chat is not implemented")
        if rest and type(rest[0]) is int and len(rest) in (3, 4):   # (topicId, forAll, mode[, cacheOnly])
            rest = rest[1:]
        if len(rest) < 2 or type(rest[0]) is not bool or type(rest[1]) not in (int, bool):
            raise TypeError("deleteMessages(messages, randoms, encryptedChat, dialogId, [topicId,] forAll, mode, ...)")
        if rest[1]:
            raise _unsupported("MessagesController.deleteMessages of scheduled or quick-reply messages is not implemented")
        if len(rest) > 2 and rest[2]:
            raise _unsupported("MessagesController.deleteMessages with cacheOnly is not implemented")
        ids = [_int(item, 32, "message id") for item in (messages or ())]
        if not ids:
            return
        dialog = _int(dialogId, 64, "dialogId")
        for start in range(0, len(ids), 100):
            self._action("delete_messages", "deleteMessages", dialog_id=dialog, ids=ids[start:start + 100], revoke=rest[0])

    def markDialogAsRead(self, dialogId, maxPositiveId, maxNegativeId, maxDate, popup, threadId, countDiff, readNow, scheduledCount):
        if threadId:
            raise _unsupported("MessagesController.markDialogAsRead of a thread is not implemented")
        self._action("read_dialog", "markDialogAsRead", dialog_id=_int(dialogId, 64, "dialogId"),
                     max_id=_int(maxPositiveId, 32, "maxPositiveId"))

    def addDialogToFolder(self, dialogIds, folderId, pinnedNum, *rest):
        """Both Android overloads: ``(dialogId, folderId, pinnedNum, taskId)`` and
        ``(dialogIds, folderId, pinnedNum, peers, taskId)``.

        Moves dialogs of the chat list into the main list (folder 0) or the archive (1), unpinned,
        and returns Android's result: 0 when no dialog was moved, 2 when the archive appeared with
        the move, otherwise 1. Pinning the moved dialog (``pinnedNum`` above zero), a secret chat
        and resuming a pending task (``taskId``) have no host operation and raise.
        """
        single = type(dialogIds) is int
        if len(rest) != (1 if single else 2):
            raise TypeError("addDialogToFolder(dialogId, folderId, pinnedNum, taskId) or "
                            "(dialogIds, folderId, pinnedNum, peers, taskId)")
        folder = _int(folderId, 32, "folderId")
        if _int(rest[-1], 64, "taskId"):
            raise _unsupported("MessagesController.addDialogToFolder for a pending task is not implemented")
        if _int(pinnedNum, 32, "pinnedNum") > 0:
            raise _unsupported("MessagesController.addDialogToFolder with a pinned position is not implemented")
        if folder not in (0, 1):
            raise _unsupported("MessagesController.addDialogToFolder moves dialogs to the main list or the archive only")
        dialogs = []
        for item in ([dialogIds] if single else list(dialogIds or ())):
            dialog = _int(item, 64, "dialogId")
            if DialogObject.isEncryptedDialog(dialog):
                raise _unsupported("MessagesController.addDialogToFolder of a secret chat is not implemented")
            if dialog != 0 and not DialogObject.isFolderDialogId(dialog) and dialog not in dialogs:
                dialogs.append(dialog)
        result = 0
        for start in range(0, len(dialogs), 100):
            moved = self._action("add_dialogs_to_folder", "addDialogToFolder", dialog_ids=dialogs[start:start + 100], folder_id=folder)
            if type(moved) is not int or moved not in (0, 1, 2):
                raise _runtime_error("Host returned an invalid folder result")
            result = max(result, moved)
        return result

    def processUpdates(self, updates, fromQueue=False):
        if not isinstance(updates, TLRPC.Updates):
            raise TypeError("updates must be a TLRPC.Updates")
        self._action("process_updates", "processUpdates", updates=updates.to_bridge())

    def _store(self, member, users, chats):
        for kind, values in ((TLRPC.User, users), (TLRPC.Chat, chats)):
            if any(not isinstance(value, kind) for value in values):
                raise TypeError(member + " takes " + kind.__name__ + " objects")
        for start in range(0, max(len(users), len(chats)), 200):
            self._action("store_peers", member, users=[value.to_bridge() for value in users[start:start + 200]],
                         chats=[value.to_bridge() for value in chats[start:start + 200]])

    def putUser(self, user, fromCache, force=False):
        if user is None:
            return False
        self._store("putUser", [user], [])
        return True

    def putUsers(self, users, fromCache):
        self._store("putUsers", list(users or ()), [])

    def putChat(self, chat, fromCache):
        if chat is not None:
            self._store("putChat", [], [chat])

    def putChats(self, chats, fromCache):
        self._store("putChats", [], list(chats or ()))

    def loadFullUser(self, user, classGuid, force, whenReceivedFullUser=None):
        if whenReceivedFullUser is not None:
            raise _unsupported("MessagesController.loadFullUser with a callback is not implemented")
        if user is None:
            return
        self._action("load_full_peer", "loadFullUser", kind="user", id=_int(getattr(user, "id", None), 64, "user.id"))

    def loadFullChat(self, chatId, classGuid, force):
        self._action("load_full_peer", "loadFullChat", kind="chat", id=_int(chatId, 64, "chatId"))

    # The chat list (``telegram.dialogs``). Android keeps live lists; here every read returns a new
    # snapshot of the host's answer, in Android's order (drafts do not move a dialog up).

    def _dialogs(self, member):
        operation = "telegram.dialogs"
        if operation not in _runtime().capabilities["operations"]:
            raise _unsupported("MessagesController." + member + " needs host operation " + operation)
        dialogs, seen = [], set()
        try:
            for entry in _dialog_entries(self.currentAccount):
                dialog = tl.from_bridge(entry["dialog"], TLRPC.Dialog)
                DialogObject.initDialog(dialog)
                if dialog is None or dialog.id == 0 or dialog.id in seen:
                    raise _runtime_error("Host returned an invalid dialog")
                seen.add(dialog.id)
                dialog.last_message_date, dialog.pinnedNum = entry["last_message_date"], entry["pinned_num"]
                dialog.isFolder = isinstance(dialog, TLRPC.TL_dialogFolder)
                dialogs.append(dialog)
        except Exception:
            # An answer that cannot be decoded is not kept for the next read.
            _dialog_cache.clear()
            raise
        # ``dialogComparator``: the archive's row, pinned dialogs by ``pinnedNum``, then the newest first.
        dialogs.sort(key=lambda dialog: (not dialog.isFolder, not dialog.pinned,
                                         -dialog.pinnedNum if dialog.pinned else -dialog.last_message_date))
        return dialogs

    @property
    def allDialogs(self):
        return _java_util().ArrayList(self._dialogs("allDialogs"))

    def getAllDialogs(self):
        return _java_util().ArrayList(self._dialogs("getAllDialogs"))

    def getDialogs(self, folderId):
        """The dialogs of the main list (0, the archive's row included) or of the archive (1)."""
        folder = _int(folderId, 32, "folderId")
        return _java_util().ArrayList([dialog for dialog in self._dialogs("getDialogs")
                                       if (0 if dialog.isFolder else dialog.folder_id) == folder])

    @property
    def dialogs_dict(self):
        from .android_util import LongSparseArray
        result = LongSparseArray()
        for dialog in self._dialogs("dialogs_dict"):
            result.put(dialog.id, dialog)
        return result

    def getDialog(self, did):
        did = _int(did, 64, "did")
        return next((dialog for dialog in self._dialogs("getDialog") if dialog.id == did), None)

    def getUserConfig(self):
        return _client().get_user_config(self.currentAccount)

    def getConnectionsManager(self):
        return _client().get_connections_manager(self.currentAccount)


class AccountInstance(_Java):
    """``AccountInstance``: the controllers of one account.

    Replaces the host adapter, which offers the user config and messages controller only; each
    getter resolves like the matching ``client_utils`` helper.
    """
    __ayu_requires__ = ("client.call", "telegram.peer")
    __ayu_overrides_host__ = True

    def __init__(self, account):
        self.__dict__["currentAccount"] = _account(account)

    @staticmethod
    def getInstance(num):
        instance = AccountInstance(num)
        # The host validates the account index and fails for an inactive one.
        instance.getUserConfig()
        return instance

    def getCurrentAccount(self):
        return self.currentAccount

    def getUserConfig(self):
        return _client().get_user_config(self.currentAccount)

    def getMessagesController(self):
        return _client().get_messages_controller(self.currentAccount)

    def getConnectionsManager(self):
        return _client().get_connections_manager(self.currentAccount)

    def getSendMessagesHelper(self):
        return _client().get_send_messages_helper(self.currentAccount)

    def getMediaDataController(self):
        return _client().get_media_data_controller(self.currentAccount)

    def getMessagesStorage(self):
        return _client().get_messages_storage(self.currentAccount)

    def getFileLoader(self):
        return _client().get_file_loader(self.currentAccount)

    def getContactsController(self):
        return _client().get_contacts_controller(self.currentAccount)

    def getNotificationsController(self):
        return _client().get_notifications_controller(self.currentAccount)

    def getLocationController(self):
        return _client().get_location_controller(self.currentAccount)

    def getDownloadController(self):
        return _client().get_download_controller(self.currentAccount)

    def getSecretChatHelper(self):
        return _client().get_secret_chat_helper(self.currentAccount)

    def getNotificationsSettings(self):
        return _client().get_notifications_settings(self.currentAccount)

    def getNotificationCenter(self):
        # The host has one global notification center; an account-scoped one is not provided.
        raise _unsupported("AccountInstance.getNotificationCenter needs an account-scoped notification adapter")


def _delegate(value):
    """``run`` of a ``RequestDelegate``-like object, or a plain callable; ``None`` stays ``None``."""
    if value is None:
        return None
    run = None if isinstance(value, type) else getattr(value, "run", None)
    if callable(run):
        return run
    if callable(value):
        return value
    raise TypeError("Expected a RequestDelegate or a callable")


class ConnectionsManager(_Java):
    """``org.telegram.tgnet.ConnectionsManager``: requests, cancellation and server time."""
    __ayu_requires__ = ("telegram.request", "telegram.request.cancel", "telegram.connection")
    ConnectionTypeGeneric, ConnectionTypeDownload, ConnectionTypeUpload, ConnectionTypePush = 1, 2, 4, 8
    ConnectionTypeDownload2 = 2 | 1 << 16
    FileTypePhoto, FileTypeVideo, FileTypeAudio, FileTypeFile = 0x01000000, 0x02000000, 0x03000000, 0x04000000
    RequestFlagEnableUnauthorized, RequestFlagFailOnServerErrors, RequestFlagCanCompress = 1, 2, 4
    RequestFlagWithoutLogin, RequestFlagTryDifferentDc, RequestFlagForceDownload, RequestFlagInvokeAfter = 8, 16, 32, 64
    RequestFlagNeedQuickAck, RequestFlagDoNotWaitFloodWait, RequestFlagListenAfterCancel = 128, 1024, 2048
    RequestFlagFailOnServerErrorsExceptFloodWait, RequestFlagSmallDownload, RequestFlagDownloadByteBudget = 65536, 131072, 262144
    ConnectionStateConnecting, ConnectionStateWaitingForNetwork, ConnectionStateConnected = 1, 2, 3
    ConnectionStateConnectingToProxy, ConnectionStateUpdating = 4, 5
    DEFAULT_DATACENTER_ID = 2 ** 31 - 1

    def __init__(self, account):
        self.__dict__["currentAccount"] = _account(account)

    @staticmethod
    def getInstance(num):
        return ConnectionsManager(num)

    def sendRequest(self, object, onComplete=None, *rest):
        """``sendRequest(object, completionBlock[, flags | quickAckBlock, flags | …])``.

        Quick-ack and write-to-socket delegates, a datacenter and a connection type are not
        forwarded: passing a non-null/non-default one is refused.
        """
        flags = 0
        integers = [item for item in rest if type(item) is int]
        others = [item for item in rest if type(item) not in (int, bool) and item is not None]
        if integers:
            flags = integers[0]
            if any(value not in (ConnectionsManager.DEFAULT_DATACENTER_ID, ConnectionsManager.ConnectionTypeGeneric)
                   for value in integers[1:]):
                raise _unsupported("ConnectionsManager.sendRequest cannot choose a datacenter or connection type")
        if others:
            raise _unsupported("ConnectionsManager.sendRequest does not deliver quick-ack or socket delegates")
        deliver = _delegate(onComplete)
        account = self.currentAccount

        def completed(response, error):
            if deliver is None:
                return
            client = _client()
            from ayu_bridge import BridgeError
            try:
                with client.account_scope(account):
                    deliver(response, error)
            except BridgeError:
                raise
            except Exception:
                client.log("RequestDelegate callback failed")

        return _client().send_tl_request(object, completed, account, flags)

    def cancelRequest(self, token, notifyServer=True, onCancelled=None):
        if onCancelled is not None:
            raise _unsupported("ConnectionsManager.cancelRequest does not report cancellation")
        _client().cancel_tl_request(self.currentAccount, _int(token, 32, "token"))

    def _state(self):
        state = _call("telegram.connection", {"account": self.currentAccount})
        if not isinstance(state, dict) or any(type(state.get(key)) is not int for key in
                                              ("time_ms", "time_difference", "state", "datacenter_id")):
            raise _runtime_error("Host returned an invalid connection state")
        return state

    def getCurrentTimeMillis(self):
        return self._state()["time_ms"]

    def getCurrentTime(self):
        return self._state()["time_ms"] // 1000

    def getTimeDifference(self):
        return self._state()["time_difference"]

    def getConnectionState(self):
        return self._state()["state"]

    def getCurrentDatacenterId(self):
        return self._state()["datacenter_id"]


@_local_arguments
class SendMessageParams(_Java):
    """``SendMessagesHelper.SendMessageParams``: every Android field, with Java defaults."""
    _FIELDS = None
    # Fields a host may supply to the send-message hook, and the ones it applies when a hook changes them.
    _WIRE = _operations().SEND_HOOK_FIELDS
    _MODIFIABLE = ("peer", "message", "caption", "entities", "replyToMsg", "replyToTopMsg", "notify", "scheduleDate",
                   "scheduleRepeatPeriod", "searchLinks", "invert_media", "effect_id", "hasMediaSpoilers")

    def __init__(self):
        self.__dict__.update(SendMessageParams._defaults())

    def __getattr__(self, name):
        if name in SendMessageParams._defaults():
            # Only an object delivered to the send-message hook lacks a field: the host cannot tell it.
            from ayu_bridge import UnsupportedAPI
            raise UnsupportedAPI(f"The send-message hook does not carry SendMessageParams.{name}")
        raise _unsupported(f"SendMessageParams.{name} is not implemented")

    @staticmethod
    def _defaults():
        if SendMessageParams._FIELDS is None:
            fields = dict(_client().SEND_MESSAGE_DEFAULTS)
            # ``notify`` has no Java initializer; the SDK's ``send_message`` is what defaults it to true.
            fields.update(notify=False, sendMessageChatArguments=None)
            SendMessageParams._FIELDS = fields
        return SendMessageParams._FIELDS

    def __setattr__(self, name, value):
        if name not in SendMessageParams._defaults():
            raise AttributeError(f"SendMessageParams has no field {name}")
        object.__setattr__(self, name, value)

    @staticmethod
    def of(*args):
        """The ``of`` overloads up to the document/photo forms; the 26-argument form is not provided."""
        params = SendMessageParams()
        count, first = len(args), args[0] if args else None
        if count == 2:
            names = ("message", "peer")
            params.searchLinks = params.notify = True
        elif count == 1 and isinstance(first, MessageObject):
            params.retryMessageObject, params.peer = first, first.getDialogId()
            return params
        elif count == 9:
            kind = ("user" if isinstance(first, TLRPC.User) else "invoice" if isinstance(first, TLRPC.TL_messageMediaInvoice)
                    else "poll" if isinstance(first, TLRPC.TL_messageMediaPoll) else "game" if isinstance(first, TLRPC.TL_game)
                    else "location")
            names = (kind, "peer", "replyToMsg", "replyToTopMsg", "replyMarkup", "params", "notify", "scheduleDate",
                     "scheduleRepeatPeriod")
        elif count == 14:
            names = ("message", "peer", "replyToMsg", "replyToTopMsg", "webPage", "searchLinks", "entities", "replyMarkup",
                     "params", "notify", "scheduleDate", "scheduleRepeatPeriod", "sendAnimationData", "updateStickersOrder")
        elif count in (17, 18):
            names = ("document", "videoEditedInfo", "path", "peer", "replyToMsg", "replyToTopMsg", "caption", "entities",
                     "replyMarkup", "params", "notify", "scheduleDate", "scheduleRepeatPeriod", "ttl", "parentObject",
                     "sendAnimationData", "updateStickersOrder", "hasMediaSpoilers")[:count]
        elif count in (15, 16):
            names = ("photo", "path", "peer", "replyToMsg", "replyToTopMsg", "caption", "entities", "replyMarkup", "params",
                     "notify", "scheduleDate", "scheduleRepeatPeriod", "ttl", "parentObject", "updateStickersOrder",
                     "hasMediaSpoilers")[:count]
        else:
            raise _unsupported(f"SendMessageParams.of with {count} arguments is not implemented")
        for name, value in zip(names, args):
            setattr(params, name, value)
        _int(params.peer, 64, "peer")
        return params

    @staticmethod
    def _ayu_from_wire(wire, account):
        """Parameters of an outgoing message as the host describes them to the send-message hook."""
        wire = dict(wire) if isinstance(wire, dict) else None
        # ``complete``: the keys describe the whole message, every other Android field has its Java default.
        complete = False if wire is None else wire.pop("complete", False)
        if wire is None or type(wire.get("peer")) is not int or not set(wire) <= set(SendMessageParams._WIRE) or type(complete) is not bool:
            raise _runtime_error("Host sent invalid send-message parameters")
        params = SendMessageParams()
        params.notify = True
        if not complete:
            # A field the host cannot describe is absent, so reading it raises instead of answering a default.
            for name in set(params.__dict__).difference(SendMessageParams._WIRE):
                del params.__dict__[name]
        for name, value in wire.items():
            if name == "entities":
                value = tl._array_list([tl.from_bridge(item, TLRPC.MessageEntity) for item in value or ()])
            elif name in ("replyToMsg", "replyToTopMsg"):
                message = tl.from_bridge(value, TLRPC.Message)
                value = None if message is None else MessageObject(account, message)
            elif name in ("document", "photo"):
                value = tl.from_bridge(value, TLRPC.TL_document if name == "document" else TLRPC.TL_photo)
            object.__setattr__(params, name, value)
        params.__dict__["_ayu_delivered"] = dict(params.__dict__)
        params.__dict__["_ayu_complete"] = complete
        return params

    def _ayu_to_wire(self):
        """The modifiable fields a hook may change; the host validates and applies them."""
        delivered = self.__dict__.get("_ayu_delivered", {})
        for name, value in self.__dict__.items():
            if name in SendMessageParams._MODIFIABLE or name.startswith("_"):
                continue
            if name not in delivered or delivered[name] is not value and delivered[name] != value:
                from ayu_bridge import UnsupportedAPI
                raise UnsupportedAPI(f"A send-message hook cannot change SendMessageParams.{name}")
        _int(self.peer, 64, "peer")
        wire = {"peer": self.peer, "message": self.message, "caption": self.caption,
                "entities": None if self.entities is None else list(self.entities)}
        for name in ("notify", "scheduleDate", "scheduleRepeatPeriod", "searchLinks", "invert_media", "effect_id",
                     "hasMediaSpoilers"):
            wire[name] = getattr(self, name)
        for name in ("replyToMsg", "replyToTopMsg"):
            value = getattr(self, name)
            wire[name] = None if value is None else value.getId()
        return wire


class SendMessagesHelper(_Java):
    """``SendMessagesHelper``: ``sendMessage(SendMessageParams)`` through the host's send route."""
    __ayu_requires__ = ("telegram.send_message",)
    SendMessageParams = SendMessageParams

    def __init__(self, account):
        self.__dict__["currentAccount"] = _account(account)

    @staticmethod
    def getInstance(num):
        return SendMessagesHelper(num)

    def generatePhotoSizes(self, *args):
        from . import telegram_photo_sizes
        if len(args) != 2:
            raise _unsupported("SendMessagesHelper.generatePhotoSizes takes (path, uri)")
        path, uri = args
        if uri is not None:
            raise _unsupported("SendMessagesHelper.generatePhotoSizes of a content Uri")
        if path is not None and not isinstance(path, str):
            raise TypeError("generatePhotoSizes takes a String path")
        return telegram_photo_sizes.generate(TLRPC, path, _compose()._external_cache_dir().getAbsolutePath(),
                                             ConnectionsManager(self.currentAccount).getCurrentTime)

    def sendMessage(self, *args):
        if len(args) != 1 or not isinstance(args[0], SendMessageParams):
            raise _unsupported("SendMessagesHelper.sendMessage accepts a SendMessageParams object")
        values = {name: value for name, value in vars(args[0]).items()
                  if name != "sendMessageChatArguments" and not name.startswith("_")}
        if "_ayu_delivered" in vars(args[0]) and not vars(args[0]).get("_ayu_complete"):
            # Sent again it would lose what the host could not describe (an attachment, a quote, preview options).
            raise _unsupported("A SendMessageParams delivered to the send-message hook cannot be sent again: "
                               "the host did not describe every field of this message")
        if args[0].sendMessageChatArguments is not None:
            raise _unsupported("SendMessageChatArguments are not forwarded")
        client = _client()
        # ``notify`` is a Java boolean without a default; the wire omits fields equal to the SDK defaults.
        _call("telegram.send_message", {"account": self.currentAccount,
                                         "params": client._send_wire(values, None)})


class MessagesStorage(_Java):
    """``MessagesStorage``: cached messages by id."""
    __ayu_requires__ = ("telegram.messages",)

    def __init__(self, account):
        self.__dict__["currentAccount"] = _account(account)

    @staticmethod
    def getInstance(num):
        return MessagesStorage(num)

    FORUM_TYPE_CHAT, FORUM_TYPE_CHAT_TABS, FORUM_TYPE_DIRECT, FORUM_TYPE_BOT = 1, 2, 4, 8

    def getMessage(self, dialogId, msgId):
        result = _call("telegram.messages", {"account": self.currentAccount, "dialog_id": _int(dialogId, 64, "dialogId"),
                                              "ids": [_int(msgId, 64, "msgId")]})
        if not isinstance(result, list) or len(result) != 1:
            raise _runtime_error("Host returned an invalid message list")
        return tl.from_bridge(result[0], TLRPC.Message)

    def readAllDialogs(self, folderId):
        """Marks every dialog with unread messages as read: of one folder, or of all for a negative id."""
        operation = "telegram.action.read_all_dialogs"
        if operation not in _runtime().capabilities["operations"]:
            raise _unsupported("MessagesStorage.readAllDialogs needs host operation " + operation)
        _dialog_cache.clear()
        _call(operation, {"account": self.currentAccount, "folder_id": _int(folderId, 32, "folderId")})


class MediaController(_Java):
    """``MediaController``: the audio player's current message and transport controls."""
    __ayu_requires__ = ("telegram.player",)

    @staticmethod
    def getInstance():
        return MediaController()

    def _player(self, action, **arguments):
        arguments["action"] = action
        state = _call("telegram.player", arguments)
        if not isinstance(state, dict) or type(state.get("paused")) is not bool or type(state.get("account")) is not int:
            raise _runtime_error("Host returned an invalid player state")
        return state

    def getPlayingMessageObject(self):
        state = self._player("state")
        message = tl.from_bridge(state.get("message"), TLRPC.Message)
        if message is None:
            return None
        playing = MessageObject(state["account"], message)
        progress, position = state.get("progress", 0.0), state.get("position_ms", 0)
        if type(progress) in (int, float) and type(position) is int:
            playing.audioProgress, playing.audioProgressSec = float(progress), position // 1000
        return playing

    def _same(self, messageObject, state):
        message = tl.from_bridge(state.get("message"), TLRPC.Message)
        return (message is not None and isinstance(messageObject, MessageObject)
                and (messageObject.getDialogId(), messageObject.getId()) == (MessageObject.getDialogId(message), message.id))

    def isMessagePaused(self):
        state = self._player("state")
        return state.get("message") is None or state["paused"]

    def getProgressMs(self, messageObject):
        state = self._player("state")
        position = state.get("position_ms")
        return position if type(position) is int and self._same(messageObject, state) else -1

    def getDuration(self):
        duration = self._player("state").get("duration_ms")
        return duration if type(duration) is int else 0

    def isPlayingMessage(self, messageObject):
        return self._same(messageObject, self._player("state"))

    def pauseMessage(self, messageObject):
        if not self._same(messageObject, self._player("state")):
            return False
        self._player("pause")
        return True

    def playMessage(self, messageObject, *args):
        if args:
            raise _unsupported("MediaController.playMessage options are not implemented")
        if not self._same(messageObject, self._player("state")):
            raise _unsupported("MediaController.playMessage can only resume the current message")
        self._player("resume")
        return True

    def playNextMessage(self):
        self._player("next")

    def playPreviousMessage(self):
        self._player("previous")

    def cleanupPlayer(self, notify=True, stopService=True, *rest):
        self._player("stop")

    def seekToProgress(self, messageObject, progress):
        if type(progress) not in (int, float) or not 0 <= progress <= 1:
            raise ValueError("progress must be between 0 and 1")
        if not self._same(messageObject, self._player("state")):
            return False
        self._player("seek", progress=float(progress))
        return True


# --- Utilities and build constants ----------------------------------------------

class _SecureRandom:
    """The ``java.security.SecureRandom`` members plugins use on ``Utilities.random``."""

    def nextInt(self, bound=None):
        if bound is None:
            return tl._signed(secrets.randbits(32), 32)
        if type(bound) is not int or bound <= 0:
            raise ValueError("bound must be positive")
        return secrets.randbelow(bound)

    def nextLong(self):
        return tl._signed(secrets.randbits(64), 64)

    def nextBoolean(self):
        return bool(secrets.randbits(1))

    def nextFloat(self):
        return secrets.randbits(24) / (1 << 24)

    def nextDouble(self):
        return secrets.randbits(53) / (1 << 53)

    def nextBytes(self, target):
        if not isinstance(target, (bytearray, list)):
            raise _unsupported("nextBytes needs a bytearray or list to fill")
        data = secrets.token_bytes(len(target))
        target[:] = data if isinstance(target, bytearray) else [tl._signed(item, 8) for item in data]


class _UtilitiesMeta(_Meta):
    def __getattr__(cls, name):
        if name.endswith("Queue"):
            from . import concurrency
            if name in concurrency.QUEUE_NAMES:
                return concurrency.named_queue(name)
        return super().__getattr__(name)


class _Callback:
    def run(self, *args):
        raise NotImplementedError("run is not implemented")


class Utilities(_Java, metaclass=_UtilitiesMeta):
    random = fastRandom = _SecureRandom()

    @staticmethod
    def parseInt(value):
        if value is None:
            return 0
        match = re.search(r"-?[0-9]+", str(value))
        if match is None:
            return 0
        return tl._signed(int(match.group(0)), 32)

    @staticmethod
    def parseLong(value):
        match = None if value is None else re.search(r"[\-0-9]+", value)
        try:
            number = 0 if match is None else int(match.group(0))
        except ValueError:
            return 0
        return number if -(2 ** 63) <= number < 2 ** 63 else 0

    @staticmethod
    def parseIntToString(value):
        match = re.search(r"[\-0-9]+", value)
        return match.group(0) if match else None

    @staticmethod
    def bytesToHex(data):
        return "" if data is None else tl.as_bytes(data).hex().upper()

    @staticmethod
    def hexToBytes(text):
        if text is None:
            return None
        if len(text) % 2 or re.fullmatch(r"[0-9a-fA-F]*", text) is None:
            raise ValueError("hexToBytes needs an even number of hexadecimal digits")
        return bytes.fromhex(text)

    @staticmethod
    def bytesToInt(data):
        return tl._signed(int.from_bytes(tl.as_bytes(data)[:4], "little"), 32)

    @staticmethod
    def bytesToLong(data):
        return tl._signed(int.from_bytes(tl.as_bytes(data)[:8], "little"), 64)

    @staticmethod
    def MD5(text):
        if text is None:
            return None
        return hashlib.md5(text.encode("utf-8", "surrogatepass")).hexdigest()

    @staticmethod
    def SHA256(text):
        if text is None:
            return None
        return hashlib.sha256(text.encode("utf-8", "surrogatepass")).hexdigest()

    @staticmethod
    def computeSHA1(data, offset=0, length=None):
        data = tl.as_bytes(data)
        return hashlib.sha1(data[offset:len(data) if length is None else offset + length]).digest()

    @staticmethod
    def computeSHA256(*parts):
        if len(parts) == 3 and type(parts[1]) is int and type(parts[2]) is int:
            data = tl.as_bytes(parts[0])
            return hashlib.sha256(data[parts[1]:parts[1] + parts[2]]).digest()
        digest = hashlib.sha256()
        for part in parts:
            digest.update(tl.as_bytes(part))
        return digest.digest()

    @staticmethod
    def generateRandomString(length=16):
        if type(length) is not int or not 0 <= length <= 65536:
            raise ValueError("Invalid random string length")
        alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return "".join(secrets.choice(alphabet) for _ in range(length))

    @staticmethod
    def clamp(value, maxValue, minValue):
        import math
        if isinstance(value, float) and math.isnan(value):
            return minValue
        if isinstance(value, float) and math.isinf(value):
            return maxValue
        return max(min(value, maxValue), minValue)

    @staticmethod
    def clamp01(value):
        return Utilities.clamp(value, 1.0, 0.0)


for _name in ("Callback", "CallbackVoidReturn", "Callback0Return", "CallbackReturn", "Callback2Return", "Callback3Return",
              "Callback2", "Callback3", "Callback4", "Callback4Return", "Callback5", "Callback5Return", "IndexedConsumer"):
    type.__setattr__(Utilities, _name, type(_name, (_Callback,), {
        "__module__": __name__, "__qualname__": "Utilities." + _name,
        "__doc__": f"``Utilities.{_name}``: implement ``run``."}))


class BuildVars(_Java):
    """``BuildVars`` of the emulated Android client; API credentials are not exposed."""
    DEBUG_VERSION = DEBUG_PRIVATE_VERSION = LOGS_ENABLED = False
    USE_CLOUD_STRINGS = True


def _build_version():
    import _ayu_policy
    return _ayu_policy.APP_VERSION


BuildVars.BUILD_VERSION_STRING = _build_version()
# ``BuildConfig.VERSION_CODE`` of the reference client's 13.2.2; it changes with ``_ayu_policy.APP_VERSION``.
BuildVars.BUILD_VERSION = 7303


# --- Members of host classes that are pure data or composed over what the host answers ---------

def _compose():
    from . import android_compose
    return android_compose


@returns(File)
def _files_dir_fixed(*args):
    """``ApplicationLoader.getFilesDirFixed()`` and ``getFilesDirFixed(child)``, which creates the child directory."""
    if not args:
        return _compose()._files_dir()
    if len(args) != 1 or not isinstance(args[0], str):
        raise TypeError("ApplicationLoader.getFilesDirFixed takes no argument or a child name")
    directory = File(_compose()._files_dir(), args[0])
    try:
        os.makedirs(directory.getAbsolutePath(), exist_ok=True)
    except OSError:
        # Android logs the failure and answers null.
        return None
    return directory


def _application_id(*args):
    if args:
        raise TypeError("ApplicationLoader.getApplicationId takes no arguments")
    return _compose().PACKAGE_NAME


def _density(utilities):
    """``AndroidUtilities.density``: Android defines ``dpf2(v)`` as ``density * v``, so it is the host's ``dpf2(1)``."""
    value = utilities.dpf2(1.0)
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not 0 < value < math.inf:
        from ayu_bridge import ProtocolError
        raise ProtocolError("AndroidUtilities.dpf2 must return a positive number")
    return float(value)


def _display_size(utilities):
    """``AndroidUtilities.displaySize``: the screen in the unit of ``dp``.

    Android keeps ``ceil(screenWidthDp * density)``; the host's display metrics are physical
    pixels at the screen scale, so the size in dp is ``pixels / metrics.density``.
    """
    metrics = _runtime().jclass(PACKAGE + "ApplicationLoader").applicationContext.getResources().getDisplayMetrics()
    scale, size = metrics.density, (metrics.widthPixels, metrics.heightPixels)
    if (isinstance(scale, bool) or not isinstance(scale, (int, float)) or not 0 < scale < math.inf
            or not all(type(item) is int and item > 0 for item in size)):
        from ayu_bridge import ProtocolError
        raise ProtocolError("The host returned invalid display metrics")
    density = _density(utilities)
    return Point(*(math.ceil(round(item / scale * density, 3)) for item in size))


@returns(File)
def _utilities_cache_dir(*args):
    """``AndroidUtilities.getCacheDir()``: Android prefers the external cache directory."""
    if args:
        raise TypeError("AndroidUtilities.getCacheDir takes no arguments")
    return _compose()._external_cache_dir()


def _find_activity(*args):
    """``AndroidUtilities.findActivity(context)``: null for null, else the Activity behind the context.

    Every host ``Context`` is the visible screen's Activity (what ``getParentActivity()`` answers), so it is its own answer.
    """
    if len(args) != 1:
        raise TypeError("AndroidUtilities.findActivity takes one Context")
    context = args[0]
    if context is None:
        return None
    if getattr(context, "_class_name", None) != "android.content.Context":
        raise _unsupported("AndroidUtilities.findActivity of an object that is not a host Context")
    return context


def _is_valid_account(*args):
    """``UserConfig.isValidAccount(num)``: an index below ``MAX_ACCOUNT_COUNT`` whose account is signed in."""
    if len(args) != 1:
        raise TypeError("UserConfig.isValidAccount takes one account index")
    num = _int(args[0], 32, "num")
    if not 0 <= num < 16:
        return False
    from ayu_bridge import BridgeError
    try:
        return bool(_runtime().jclass(PACKAGE + "UserConfig").getInstance(num).isClientActivated())
    except BridgeError as error:
        # The host has no UserConfig for an index without an account; Android's is empty there.
        if str(error.code).upper() != "ACCOUNT_UNAVAILABLE":
            raise
        return False


def _client_user_id(config):
    """``UserConfig.clientUserId``: the field behind ``getClientUserId()``."""
    return config.getClientUserId()


_CONTROLLER_CONSTANTS = {name: value for name, value in vars(MessagesController).items()
                         if name.startswith(("UPDATE_MASK_", "DIALOG_FILTER_FLAG_")) and name != "UPDATE_MASK_CHAT_ADMINS"}

HOST_MEMBERS = {
    PACKAGE + "ApplicationLoader": {"getFilesDirFixed": _files_dir_fixed, "getApplicationId": _application_id},
    PACKAGE + "AndroidUtilities": {
        "density": HostField(_density), "displaySize": HostField(_display_size), "getCacheDir": _utilities_cache_dir,
        "findActivity": _find_activity,
        "TYPEFACE_ROBOTO_CONDENSED_BOLD": "fonts/rcondensedbold.ttf", "TYPEFACE_ROBOTO_REGULAR": "fonts/rregular.ttf",
        "TYPEFACE_ROBOTO_ITALIC": "fonts/ritalic.ttf", "TYPEFACE_ROBOTO_MEDIUM": "fonts/rmedium.ttf",
        "TYPEFACE_ROBOTO_EXTRA_BOLD": "fonts/rextrabold.ttf", "TYPEFACE_ROBOTO_MEDIUM_ITALIC": "fonts/rmediumitalic.ttf",
        "TYPEFACE_ROBOTO_MONO": "fonts/rmono.ttf", "TYPEFACE_MERRIWEATHER_BOLD": "fonts/mw_bold.ttf",
        "TYPEFACE_NUNITO_EXTRABOLD": "fonts/nunito_extrabold.ttf",
    },
    PACKAGE + "UserConfig": {"MAX_ACCOUNT_COUNT": 16, "MAX_ACCOUNT_DEFAULT_COUNT": 8,
                             "clientUserId": HostField(_client_user_id), "isValidAccount": _is_valid_account},
    # The host adapter answers while ``telegram.peer`` is undeclared; its constants are the same data.
    PACKAGE + "MessagesController": dict(_CONTROLLER_CONSTANTS),
}

CLASSES = {
    PACKAGE + "R": R,
    PACKAGE + "DialogObject": DialogObject,
    PACKAGE + "UserObject": UserObject,
    PACKAGE + "ChatObject": ChatObject,
    PACKAGE + "FileLoader": FileLoader,
    PACKAGE + "MessageObject": MessageObject,
    PACKAGE + "MessagesController": MessagesController,
    PACKAGE + "AccountInstance": AccountInstance,
    PACKAGE + "SendMessagesHelper": SendMessagesHelper,
    PACKAGE + "SendMessagesHelper$SendMessageParams": SendMessageParams,
    PACKAGE + "MessagesStorage": MessagesStorage,
    PACKAGE + "MediaController": MediaController,
    PACKAGE + "Utilities": Utilities,
    PACKAGE + "BuildVars": BuildVars,
    "org.telegram.tgnet.ConnectionsManager": ConnectionsManager,
}
CLASSES.update({PACKAGE + "R$" + kind: getattr(R, kind) for kind in _RESOURCE_KINDS})
CLASSES.update({PACKAGE + "Utilities$" + name: cls for name, cls in vars(Utilities).items()
                if isinstance(cls, type) and issubclass(cls, _Callback)})
_l.register(CLASSES)
