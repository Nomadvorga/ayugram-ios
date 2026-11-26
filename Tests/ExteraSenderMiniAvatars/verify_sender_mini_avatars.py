#!/usr/bin/env python3
"""Check persisted-setting, live-refresh and real bubble-avatar wiring."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[2]


def source(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


settings = source("Swiftgram/SGSimpleSettings/Sources/ExteraSettings.swift")
policy = source("Swiftgram/SGSimpleSettings/Sources/ExteraSenderMiniAvatarPolicy.swift")
bubble = source("submodules/TelegramUI/Components/Chat/ChatMessageBubbleItemNode/Sources/ChatMessageBubbleItemNode.swift")
history = source("submodules/TelegramUI/Sources/ChatHistoryListNode.swift")
chat_list = source("submodules/ChatListUI/Sources/Node/ChatListItem.swift")

assert "case senderMiniAvatars" in settings
assert "ExteraSettings.key(.senderMiniAvatars): false" in settings
assert "return self.value(.senderMiniAvatars)" in settings
assert "ExteraSenderMiniAvatarPolicy.shouldShow(" in bubble
assert "enabled: ExteraSettings.shared.senderMiniAvatars" in bubble
assert "isGroupOrChannel: chatLocationPeerId.isGroupOrChannel" in bubble
assert "supportsNativeSenderProfiles: supportsNativeSenderProfiles" in bubble
assert "supportsNativeSenderProfiles = info.flags.contains(.messagesShouldHaveProfiles)" in bubble
assert "peers[item.content.firstMessage.id.peerId] as? TelegramChannel" in bubble
assert "hasVisibleAuthorHeader: displayAuthorInfo && authorNameString != nil" in bubble
assert "hasRealAuthor: effectiveAuthor.map { $0.id != chatLocationPeerId && $0.id.namespace != Namespaces.Peer.Empty } ?? false" in bubble
assert "miniSenderAvatarPeer = EnginePeer(effectiveAuthor)" in bubble
assert "miniSenderAvatarPeer: miniSenderAvatarPeer" in bubble
assert "let titleAvatarPeer = miniSenderAvatarPeer ?? item.content.firstMessage.author.flatMap(EnginePeer.init)" in bubble
assert "ExteraSettings.shared.senderMiniAvatars," in history
assert "ayuSettingsDidChangeNotification" in history and "scheduleExteraRenderingRefresh()" in history
assert "guard settings != self.exteraRenderingSettings else { return }" in history
assert "self.setupItem(item: item, synchronousLoads: false)" in chat_list
assert "self.asyncLayout()(layoutParams.0" in chat_list
assert "settings.store" not in policy and "UserDefaults" not in policy

tests = source("Tests/ExteraSenderMiniAvatars/ExteraSenderMiniAvatarPolicyTests.swift")
cases = re.findall(r"\bfunc (test\w+)\(", tests)
assert len(cases) == 11 and len(set(cases)) == len(cases), cases

print("PASS: persisted default/accessor -> bubble policy -> effective sender AvatarNode source is connected")
print("PASS: existing Ayu notification refresh fingerprint includes the setting; chat-list row reapplies on setting changes")
print(f"PASS: {len(cases)} focused XCTest methods cover private/group/channel-profile/header/author/outgoing/disabled/preview/sidebar rules")
print("Source-level wiring check only; execute the XCTest fixture on a Swift host and verify bubble frames on iOS.")
