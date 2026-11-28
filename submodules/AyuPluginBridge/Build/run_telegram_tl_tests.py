#!/usr/bin/env python3
"""Runs the plugin bridge's TL builders on this Mac and checks their bytes with the SDK's TL parser.

`submodules/TelegramCore/Sources/AyuPlugins/AyuPluginTLBuilders.swift` rebuilds `User`, `Chat`,
`Message` and their parts for plugins through the generated `Api` constructors. TelegramCore
cannot be run here, but that file depends on TelegramApi and Foundation only, so this script

  1. generates TelegramApi's sources from `swift_scheme.tl` exactly as `typecheck_telegram.py`
     does (same cache, Bazel is never started),
  2. compiles TelegramApi (its table-driven Objective-C engine included) and the builders for
     macOS with swiftc/clang into a command-line tool, together with `Tests/TelegramTL/main.swift`,
  3. runs the tool and decodes every vector it prints with `Python/_ayu_javalib/telegram_tl.py`,
     the parser plugins use (strict: unknown constructors and trailing bytes fail), then compares
     the decoded fields with the values the vectors were built from.

This executes the real serializer over the builders' flag logic: a flag bit without its value
aborts the tool, as it would abort the app. It does not execute the Postbox-to-builder mapping
(`AyuPluginTLFromPostbox.swift`), which is type-checked only.

    python3 -B submodules/AyuPluginBridge/Build/run_telegram_tl_tests.py

Exit status: 0 all vectors match, 1 a vector differs or the tool failed, 2 it could not be built.
"""
from __future__ import annotations

import base64
import hashlib
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "Python"))

import typecheck_telegram as harness  # noqa: E402

REPO = harness.REPO
API = REPO / "submodules/TelegramApi"
BUILDERS = REPO / "submodules/TelegramCore/Sources/AyuPlugins/AyuPluginTLBuilders.swift"
VECTORS = HERE.parent / "Tests/TelegramTL/main.swift"
# Foundation-only logic of the TelegramCore hook points, executed by the same tool.
GATE = REPO / "submodules/TelegramCore/Sources/AyuPlugins/AyuPluginOrderedGate.swift"


def run(arguments: list[str], environment: dict) -> None:
    result = subprocess.run(arguments, env=environment, capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stdout + result.stderr)
        raise harness.Failure("command failed: " + " ".join(arguments[:6]) + " ...")


def build(cache: Path) -> Path:
    builder = harness.Builder(harness.Toolchain(), cache, "release", 4)
    generated = builder.genrule("submodules/TelegramApi", "TelegramApiGenerated") / "Generated"
    environment = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
    sdk = subprocess.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], env=environment, capture_output=True,
                         text=True, check=True).stdout.strip()
    objc = sorted((API / "ObjC/Sources").glob("*.m")) + [generated / "TLApiSchemaData.m"]
    api = sorted((API / "Sources").glob("*.swift")) + sorted(generated.glob("Api*.swift"))
    key = hashlib.sha256()
    for path in objc + api + sorted((API / "ObjC").rglob("*.h")):
        key.update(path.name.encode() + b"\0" + path.read_bytes())
    root = cache / "tl-tests" / key.hexdigest()[:20]
    headers = API / "ObjC/PublicHeaders"
    library = root / "libTelegramApi.a"
    if not library.is_file():
        root.mkdir(parents=True, exist_ok=True)
        (root / "module.modulemap").write_text(
            f'module TelegramApiObjC {{\n    umbrella header "{headers}/TelegramApiObjC/TelegramApiObjC.h"\n    export *\n}}\n')
        objects = []
        for source in objc:
            output = root / (source.stem + ".o")
            run(["xcrun", "--sdk", "macosx", "clang", "-c", "-fno-objc-arc", "-DTL_OBJC_DIRECT=1", "-O1", "-isysroot", sdk,
                 f"-I{headers}", f"-I{API / 'ObjC/Sources'}", str(source), "-o", str(output)], environment)
            objects.append(str(output))
        scratch = root / "libTelegramApi.partial.a"
        run(["xcrun", "--sdk", "macosx", "swiftc", "-sdk", sdk, "-parse-as-library", "-module-name", "TelegramApi", "-wmo",
             "-Onone", "-suppress-warnings", "-emit-module", "-emit-module-path", str(root / "TelegramApi.swiftmodule"),
             "-emit-library", "-static", "-o", str(scratch), f"-I{root}", "-Xcc", f"-I{headers}",
             "-Xcc", "-DTL_OBJC_DIRECT=1"] + [str(path) for path in api], environment)
        run(["xcrun", "--sdk", "macosx", "libtool", "-static", "-o", str(root / "libTelegramApiObjC.a")] + objects, environment)
        scratch.rename(library)
    tool = root / ("vectors-" + hashlib.sha256(BUILDERS.read_bytes() + GATE.read_bytes() + VECTORS.read_bytes()).hexdigest()[:20])
    if not tool.is_file():
        scratch = root / "vectors.partial"
        run(["xcrun", "--sdk", "macosx", "swiftc", "-sdk", sdk, "-module-name", "AyuPluginTLVectors", "-Onone",
             "-warnings-as-errors", f"-I{root}", "-Xcc", f"-I{headers}", "-Xcc", "-DTL_OBJC_DIRECT=1", f"-L{root}",
             "-lTelegramApi", "-lTelegramApiObjC", "-lz", str(BUILDERS), str(GATE), str(VECTORS), "-o", str(scratch)], environment)
        scratch.rename(tool)
    return tool


def plain(value, depth=0):
    """A decoded TL object as plain data: `{"_": class name, field: value}`."""
    from _ayu_javalib import telegram_tl as tl
    if isinstance(value, tl.TLObject):
        result = {"_": type(value).__name__}
        for name, item in vars(value).items():
            result[name] = plain(item, depth + 1)
        return result
    if isinstance(value, (list, tuple)) or type(value).__name__ in ("ArrayList", "Vector"):
        return [plain(item, depth + 1) for item in value]
    if isinstance(value, (bytes, bytearray)):
        return bytes(value)
    return value


def expectations(R):
    """Per vector: the TL base type to decode as, and field paths with their expected values."""
    banned_flags = sum(1 << bit for bit in (0, 1, 2, 19, 20, 21, 22, 23, 24, 25))
    return {
        "user.min": (R.User, {"_": "TL_user", "id": 5, "flags": 0, "flags2": 0, "first_name": None, "photo": None}),
        "user.full": (R.User, {
            "id": 0x1_0000_0001, "access_hash": -9, "self": True, "contact": True, "mutual_contact": True,
            "deleted": False, "bot": True, "bot_chat_history": True, "bot_nochats": True, "bot_inline_geo": True,
            "bot_attach_menu": True, "bot_can_edit": True, "bot_business": True, "bot_has_main_app": True,
            "bot_forum_view": True, "bot_forum_can_manage_topics": True, "bot_can_manage_bots": True,
            "bot_guestchat": True, "bot_guard": True, "bot_forum_sidebar": True, "verified": True, "support": True,
            "scam": True, "fake": True, "premium": True, "close_friend": True, "stories_hidden": True,
            "contact_require_premium": True, "min": False, "restricted": True, "first_name": "First",
            "last_name": "Last \U0001F600", "username": "name", "phone": "15550100", "bot_info_version": 0,
            "bot_inline_placeholder": "search", "bot_active_users": 9, "bot_verification_icon": 10,
            "linked_community_id": 13, "photo._": "TL_userProfilePhoto", "photo.photo_id": 77, "photo.dc_id": 2,
            "photo.has_video": True, "photo.personal": True, "photo.stripped_thumb": bytes([1, 2, 3, 4, 5]),
            "status._": "TL_userStatusOnline", "status.expires": 123, "restriction_reason.0.platform": "ios",
            "emoji_status._": "TL_emojiStatus", "emoji_status.document_id": 11, "emoji_status.until": 12,
            "usernames.0.username": "name", "usernames.0.editable": True, "usernames.0.active": True,
            "usernames.1.username": "other", "usernames.1.active": False, "color.color": 3,
            "color.background_emoji_id": 4, "profile_color._": "TL_peerColor", "profile_color.flags": 0,
        }),
        "user.deleted": (R.User, {"id": 6, "deleted": True, "min": True, "access_hash": 1, "bot": False,
                                  "bot_can_edit": False, "bot_inline_placeholder": None}),
        "user.status.empty": (R.User, {"status._": "TL_userStatusEmpty"}),
        "user.status.offline": (R.User, {"status._": "TL_userStatusOffline", "status.expires": 55}),
        "user.status.recently": (R.User, {"status._": "TL_userStatusRecently"}),
        "user.status.lastWeek": (R.User, {"status._": "TL_userStatusLastWeek"}),
        "user.status.lastMonth": (R.User, {"status._": "TL_userStatusLastMonth"}),
        "group.min": (R.Chat, {"_": "TL_chat", "id": 20, "title": "G", "participants_count": 3, "date": 100,
                               "version": 2, "flags": 0, "photo._": "TL_chatPhotoEmpty"}),
        "group.full": (R.Chat, {
            "_": "TL_chat", "id": 21, "creator": True, "left": True, "deactivated": True, "call_active": True,
            "call_not_empty": True, "noforwards": True, "migrated_to._": "TL_inputChannel",
            "migrated_to.channel_id": 900, "migrated_to.access_hash": 901, "admin_rights.change_info": True,
            "admin_rights.other": True, "default_banned_rights.flags": banned_flags,
            "default_banned_rights.send_messages": True, "default_banned_rights.send_media": True,
            "default_banned_rights.view_messages": True, "default_banned_rights.until_date": 2_000_000_000,
            "photo._": "TL_chatPhoto", "photo.photo_id": 77, "photo.has_video": True,
        }),
        "group.forbidden": (R.Chat, {"_": "TL_chatForbidden", "id": 22, "title": "Gone"}),
        "channel.min": (R.Chat, {"_": "TL_channel", "id": 30, "title": "C", "date": 200, "flags": 0, "flags2": 0}),
        "channel.full": (R.Chat, {
            "_": "TL_channel", "id": 31, "access_hash": 32, "min": True, "username": "chan", "creator": True,
            "left": True, "broadcast": True, "megagroup": True, "verified": True, "signatures": True, "scam": True,
            "has_link": True, "has_geo": True, "slowmode_enabled": True, "call_active": True,
            "call_not_empty": True, "fake": True, "gigagroup": True, "noforwards": True, "join_to_send": True,
            "join_request": True, "forum": True, "stories_hidden": True, "signature_profiles": True,
            "autotranslation": True, "broadcast_messages_allowed": True, "monoforum": True, "forum_tabs": True,
            "restricted": True, "restriction_reason.0.reason": "porn", "admin_rights.delete_messages": True,
            "banned_rights.flags": banned_flags, "default_banned_rights.send_plain": True,
            "default_banned_rights.send_messages": False, "default_banned_rights.until_date": 2**31 - 1,
            "participants_count": 1234, "usernames.0.active": True, "color.color": 1,
            "profile_color.background_emoji_id": 2, "emoji_status.document_id": 5, "level": 6,
            "subscription_until_date": 7, "bot_verification_icon": 8, "send_paid_messages_stars": 9,
            "linked_monoforum_id": 10, "linked_community_id": 11, "photo.photo_id": 78, "photo.dc_id": 4,
            "photo.has_video": False,
        }),
        "channel.forbidden": (R.Chat, {"_": "TL_channelForbidden", "id": 33, "access_hash": 34, "megagroup": True,
                                       "broadcast": False, "title": "Banned", "until_date": 2_000_000_000}),
        "channel.forbidden.nohash": (R.Chat, {"_": "TL_channel", "id": 35, "left": True}),
        "photo": (R.Photo, {
            "_": "TL_photo", "id": 40, "access_hash": 41, "file_reference": bytes([9, 9]), "dc_id": 5,
            "has_stickers": True, "sizes.0._": "TL_photoStrippedSize", "sizes.0.bytes": bytes([1, 2, 3, 4, 5]),
            "sizes.1._": "TL_photoSize", "sizes.1.type": "m", "sizes.1.w": 320, "sizes.1.h": 200,
            "sizes.1.size": 1000, "sizes.2._": "TL_photoSizeProgressive", "sizes.2.w": 1280,
        }),
        "document": (R.Document, {
            "_": "TL_document", "id": 50, "access_hash": 51, "file_reference": b"", "dc_id": 1,
            "mime_type": "video/mp4", "size": 5_000_000_000, "thumbs.0.w": 10,
            "attributes.0._": "TL_documentAttributeFilename", "attributes.0.file_name": "a.mp4",
            "attributes.1._": "TL_documentAttributeVideo", "attributes.1.w": 640, "attributes.1.duration": 1.5,
            "attributes.1.supports_streaming": True,
        }),
        "document.min": (R.Document, {"id": 52, "flags": 0, "mime_type": "", "size": 0}),
        "media.photo": (R.MessageMedia, {"_": "TL_messageMediaPhoto", "spoiler": True, "ttl_seconds": 10,
                                         "photo.id": 40}),
        "media.photo.min": (R.MessageMedia, {"_": "TL_messageMediaPhoto", "flags": 1, "photo.id": 40}),
        "media.document": (R.MessageMedia, {"_": "TL_messageMediaDocument", "spoiler": True, "nopremium": True,
                                            "video": True, "round": True, "voice": True, "ttl_seconds": 20,
                                            "document.id": 50}),
        "media.document.min": (R.MessageMedia, {"_": "TL_messageMediaDocument", "flags": 1, "document.id": 50}),
        "media.webpage": (R.MessageMedia, {"_": "TL_messageMediaWebPage", "webpage._": "TL_webPageEmpty",
                                           "webpage.id": 95, "webpage.url": "https://example.org/"}),
        "media.webpage.min": (R.MessageMedia, {"_": "TL_messageMediaWebPage", "webpage.id": 96, "webpage.flags": 0}),
        "media.unsupported": (R.MessageMedia, {"_": "TL_messageMediaUnsupported"}),
        "userFull.min": (R.UserFull, {"_": "TL_userFull", "id": 100, "flags": 0, "flags2": 0, "common_chats_count": 0,
                                      "settings._": "TL_peerSettings", "settings.flags": 0,
                                      "notify_settings._": "TL_peerNotifySettings", "notify_settings.flags": 0}),
        "userFull.full": (R.UserFull, {
            "id": 101, "about": "About", "blocked": True, "phone_calls_available": True, "phone_calls_private": True,
            "can_pin_message": True, "has_scheduled": True, "video_calls_available": True,
            "voice_messages_forbidden": True, "translations_disabled": True, "read_dates_private": True,
            "contact_require_premium": True, "pinned_msg_id": 102, "common_chats_count": 3, "ttl_period": 86400,
            "profile_photo.id": 40, "personal_photo.id": 40, "fallback_photo.id": 40, "settings.report_spam": True,
            "settings.add_contact": True, "settings.block_contact": True, "settings.share_contact": True,
            "settings.need_contacts_exception": True, "settings.autoarchived": True, "settings.invite_members": True,
            "settings.geo_distance": 500, "notify_settings.show_previews": False,
            "notify_settings.mute_until": 2**31 - 1,
        }),
        "groupFull.min": (R.ChatFull, {"_": "TL_chatFull", "id": 110, "about": "", "flags": 0,
                                       "participants._": "TL_chatParticipantsForbidden",
                                       "participants.chat_id": 110}),
        "groupFull.full": (R.ChatFull, {
            "_": "TL_chatFull", "id": 111, "about": "Group about", "participants._": "TL_chatParticipants",
            "participants.version": 7, "participants.participants.0._": "TL_chatParticipantCreator",
            "participants.participants.0.user_id": 1, "participants.participants.0.rank": "boss",
            "participants.participants.1._": "TL_chatParticipantAdmin", "participants.participants.1.inviter_id": 1,
            "participants.participants.2._": "TL_chatParticipant", "participants.participants.2.date": 11,
            "chat_photo.id": 40, "notify_settings.show_previews": True, "notify_settings.mute_until": 0,
            "pinned_msg_id": 112, "ttl_period": 60, "has_scheduled": True,
        }),
        "channelFull.min": (R.ChatFull, {"_": "TL_channelFull", "id": 120, "about": "", "flags": 0, "flags2": 0,
                                         "chat_photo._": "TL_photoEmpty", "pts": 0, "unread_count": 0}),
        "channelFull.full": (R.ChatFull, {
            "_": "TL_channelFull", "id": 121, "about": "Channel about", "participants_count": 1000,
            "admins_count": 5, "kicked_count": 6, "banned_count": 0, "read_inbox_max_id": 7,
            "read_outbox_max_id": 8, "unread_count": 9, "chat_photo.id": 40, "notify_settings.mute_until": 5,
            "migrated_from_chat_id": 122, "migrated_from_max_id": 123, "pinned_msg_id": 124,
            "available_min_id": 125, "linked_chat_id": 126, "slowmode_seconds": 30,
            "slowmode_next_send_date": 127, "pts": 128, "ttl_period": 129, "can_view_participants": True,
            "can_set_username": True, "can_set_stickers": True, "hidden_prehistory": True, "has_scheduled": True,
            "can_view_stats": True, "participants_hidden": True, "translations_disabled": True, "antispam": True,
        }),
        "dialog.min": (R.Dialog, {
            "_": "TL_dialog", "flags": 0, "peer._": "TL_peerUser", "peer.user_id": 130, "pinned": False,
            "unread_mark": False, "top_message": 0, "read_inbox_max_id": 0, "read_outbox_max_id": 0, "unread_count": 0,
            "unread_mentions_count": 0, "unread_reactions_count": 0, "unread_poll_votes_count": 0, "folder_id": 0,
            "pts": 0, "draft": None, "notify_settings._": "TL_peerNotifySettings", "notify_settings.flags": 0,
        }),
        "dialog.full": (R.Dialog, {
            "_": "TL_dialog", "peer._": "TL_peerChannel", "peer.channel_id": 131, "pinned": True, "unread_mark": True,
            "view_forum_as_messages": False, "top_message": 132, "read_inbox_max_id": 133, "read_outbox_max_id": 134,
            "unread_count": 135, "unread_mentions_count": 136, "unread_reactions_count": 137,
            "unread_poll_votes_count": 138, "notify_settings.show_previews": True,
            "notify_settings.mute_until": 2 ** 31 - 1, "pts": 139, "folder_id": 1, "draft": None, "ttl_period": 0,
        }),
        "dialog.group": (R.Dialog, {"_": "TL_dialog", "flags": 16, "peer._": "TL_peerChat", "peer.chat_id": 140,
                                    "folder_id": 1, "pinned": False}),
        "dialog.folder": (R.Dialog, {
            "_": "TL_dialogFolder", "pinned": True, "folder._": "TL_folder", "folder.id": 1,
            "folder.title": "Archived Chats", "folder.photo": None, "peer._": "TL_peerChat", "peer.chat_id": 141,
            "top_message": 142, "unread_muted_peers_count": 143, "unread_unmuted_peers_count": 144,
            "unread_muted_messages_count": 145, "unread_unmuted_messages_count": 146,
        }),
        "forward": (R.MessageFwdHeader, {
            "from_id._": "TL_peerChannel", "from_id.channel_id": 60, "from_name": "Hidden", "date": 300,
            "channel_post": 61, "post_author": "Author", "saved_from_peer._": "TL_peerUser",
            "saved_from_peer.user_id": 62, "saved_from_msg_id": 63, "psa_type": "covid", "imported": True,
        }),
        "forward.min": (R.MessageFwdHeader, {"flags": 0, "date": 301, "from_id": None}),
        "reply": (R.MessageReplyHeader, {
            "reply_to_msg_id": 70, "reply_to_peer_id._": "TL_peerChat", "reply_to_peer_id.chat_id": 71,
            "reply_to_top_id": 72, "forum_topic": True, "quote": True, "quote_text": "quote",
            "quote_entities.0._": "TL_messageEntityBold", "quote_entities.0.length": 4, "quote_offset": 2,
        }),
        "reply.min": (R.MessageReplyHeader, {"flags": 1 << 4, "reply_to_msg_id": 73}),
        "reply.noquote": (R.MessageReplyHeader, {"flags": 1 << 4, "reply_to_msg_id": 74, "quote": False}),
        "message.min": (R.Message, {"_": "TL_message", "id": 80, "peer_id._": "TL_peerUser", "peer_id.user_id": 81,
                                    "date": 400, "message": "", "flags": 0, "flags2": 0, "from_id": None}),
        "message.full": (R.Message, {
            "id": 82, "peer_id.channel_id": 83, "from_id.user_id": 84, "date": 401,
            "message": "Bold text \U0001F600", "out": True, "mentioned": True, "media_unread": True, "silent": True,
            "post": True, "from_scheduled": True, "edit_hide": True, "pinned": True, "noforwards": True,
            "invert_media": True, "saved_peer_id.user_id": 85, "fwd_from.channel_post": 61, "via_bot_id": 86,
            "reply_to.reply_to_msg_id": 70, "media._": "TL_messageMediaDocument", "media.video": True,
            "media.document.id": 50, "entities.0._": "TL_messageEntityBold", "views": 87, "forwards": 0,
            "edit_date": 402, "post_author": "Signed", "grouped_id": 88, "ttl_period": 89, "effect": 90,
        }),
        "message.forwards": (R.Message, {"id": 91, "peer_id._": "TL_peerChat", "views": 0, "forwards": 5,
                                         "flags": 1 << 10}),
    }


def lookup(value, path: str):
    for part in path.split("."):
        value = value[int(part)] if isinstance(value, list) else value[part]
    return value


def check(output: str) -> list[str]:
    from _ayu_javalib import telegram_tl as tl
    expected = expectations(tl.TLRPC)
    problems: list[str] = []
    seen = set()
    for line in output.splitlines():
        name, _, rest = line.partition("\t")
        if name == "bannedFlags":
            all_bits = sum(1 << bit for bit in (0, 1, 2, 19, 20, 21, 22, 23, 24, 25))
            media_only = sum(1 << bit for bit in (2, 19, 20, 21, 22, 23, 24))
            if [int(item) for item in rest.split("\t")] != [all_bits, media_only, 1 << 25]:
                problems.append(f"bannedFlags: {rest!r}")
            seen.add(name)
            continue
        if name == "gate":
            if rest != "ok":
                problems.append(f"gate: {rest}")
            seen.add(name)
            continue
        if name not in expected:
            problems.append(f"{name}: no expectation")
            continue
        seen.add(name)
        base, fields = expected[name]
        try:
            decoded = plain(tl.decode(base64.b64decode(rest), base))
        except Exception as error:  # the parser's own error type, or a missing class
            problems.append(f"{name}: does not decode as {base.__name__}: {error}")
            continue
        for path, want in fields.items():
            try:
                got = lookup(decoded, path)
            except (KeyError, IndexError, TypeError):
                problems.append(f"{name}: no field {path}")
                continue
            if got != want or type(got) is not type(want) and not (isinstance(got, int) and isinstance(want, int)):
                problems.append(f"{name}: {path} is {got!r}, expected {want!r}")
    problems.extend(f"{name}: vector missing" for name in sorted(set(expected) | {"bannedFlags", "gate"}) if name not in seen)
    return problems


def main() -> int:
    try:
        tool = build(harness.DEFAULT_CACHE)
    except (harness.Failure, subprocess.CalledProcessError) as failure:
        print(f"error: {failure}", file=sys.stderr)
        return 2
    result = subprocess.run([str(tool)], capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        print(f"FAILED: the vector tool exited with {result.returncode}", file=sys.stderr)
        return 1
    problems = check(result.stdout)
    for problem in problems:
        print("FAIL    " + problem)
    count = len(result.stdout.splitlines())
    print(f"{'FAILED' if problems else 'ok'}: {count} vectors, {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
