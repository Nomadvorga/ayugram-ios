# Sender mini-avatar regression checks

The persisted `extera.senderMiniAvatars` preference controls a small avatar of
the last real author beside the last-message preview in an eligible group row.
It does not alter the chat avatar or message-bubble author layout.

The policy requires a real group and author and a visible message preview. It
suppresses the mini avatar for drafts, typing/activity rows, anonymous authors,
private chats, and special rows. Media-only last messages still count as a
preview, and the avatar is placed beside the row preview rather than over the
chat avatar or inside a message bubble.

Run the pure production visibility gate and its focused XCTest cases on a Mac
with Swift/XCTest:

```sh
python3 tools/run_extera_xctests.py --warnings-as-errors \
  AyuGram/SGSimpleSettings/Sources/ExteraSenderMiniAvatarPolicy.swift \
  Tests/ExteraSenderMiniAvatars/ExteraSenderMiniAvatarPolicyTests.swift
```

Run the cross-file persisted-setting/runtime wiring check on any Python 3 host:

```sh
python3 Tests/ExteraSenderMiniAvatars/verify_sender_mini_avatars.py
```

The host regression tests do not substitute for building the iOS app or
recording real chat frames. On device/simulator, check a private chat, group
preview with text and media-only last messages, anonymous authors, drafts,
typing/activity, special rows, and toggling the setting while the list is open.
The expected result is a small sender avatar at the start of the preview line;
the main chat avatar and message bubbles remain unchanged.
