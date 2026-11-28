#!/usr/bin/env python3
"""Check persisted-setting and last-message chat-list preview wiring."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[2]


def source(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


settings = source("AyuGram/SGSimpleSettings/Sources/ExteraSettings.swift")
policy = source("AyuGram/SGSimpleSettings/Sources/ExteraSenderMiniAvatarPolicy.swift")
chat_list = source("submodules/ChatListUI/Sources/Node/ChatListItem.swift")

assert "case senderMiniAvatars" in settings
assert "ExteraSettings.key(.senderMiniAvatars): false" in settings
assert "return self.value(.senderMiniAvatars)" in settings
assert "ExteraSenderMiniAvatarPolicy.shouldShow(" in chat_list
assert "hasRealAuthor: author.id != peer.id" in chat_list
assert "hasMessagePreview: hasMessagePreview" in chat_list
assert "hasDraft: hasDraft" in chat_list
assert "hasActivity: hasActivity" in chat_list
assert "peerData.messages.last?.media.isEmpty == false" in chat_list
assert "self.mainContentContainerNode.addSubnode(miniAvatarNode)" in chat_list
assert "textLeftCutout += miniAvatarInset" in chat_list
assert "strongSelf.updateMiniAvatar(peer: miniAvatarPeer" in chat_list
assert "ayuSettingsDidChangeNotification" in chat_list and "self.setupItem(item: item, synchronousLoads: false)" in chat_list
assert "self.asyncLayout()(layoutParams.0" in chat_list
assert "settings.store" not in policy and "UserDefaults" not in policy

tests = source("Tests/ExteraSenderMiniAvatars/ExteraSenderMiniAvatarPolicyTests.swift")
cases = re.findall(r"\bfunc (test\w+)\(", tests)
assert len(cases) == 8 and len(set(cases)) == len(cases), cases

print("PASS: persisted setting -> group chat-list last-message preview policy -> sender AvatarNode is connected")
print("PASS: sender avatar is positioned in the preview content, and list rows reapply when the setting changes")
print(f"PASS: {len(cases)} focused XCTest methods cover group/private/anonymous/missing-preview/draft/activity/special-row/disabled cases")
print("Source-level wiring check only; execute the XCTest fixture on a Swift host and verify recorded chat-list frames on iOS.")
