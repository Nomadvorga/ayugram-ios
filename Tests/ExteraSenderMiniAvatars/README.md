# Sender mini-avatar regression checks

Root cause: the persisted `extera.senderMiniAvatars` preference was consumed by
the chat-list row only; the message-bubble author layout never read it, and the
chat-history live-refresh fingerprint omitted it. Enabling the setting could
show a last-sender badge in a group chat-list row but could not affect sender
avatars in actual message bubbles or invalidate an open history.

Production now reads that preference while laying out a real incoming
group/channel author header. The policy deliberately
requires the existing native author header and a real peer; private chats,
outgoing messages, anonymous/signature-only senders, previews, merged/hidden
headers and the side-panel navigation header retain their native behavior.

Run the pure production visibility gate and its focused XCTest cases on a Mac
with Swift/XCTest:

```sh
python3 tools/run_extera_xctests.py --warnings-as-errors \
  Swiftgram/SGSimpleSettings/Sources/ExteraSenderMiniAvatarPolicy.swift \
  Tests/ExteraSenderMiniAvatars/ExteraSenderMiniAvatarPolicyTests.swift
```

Run the cross-file persisted-setting/runtime wiring check on any Python 3 host:

```sh
python3 Tests/ExteraSenderMiniAvatars/verify_sender_mini_avatars.py
```

The host regression tests do not substitute for building the iOS app or
recording real chat frames. On device/simulator, check a private chat, a group
with multiple authors, a channel with profiles, a channel without profiles,
merged messages, outgoing messages, and toggling the setting with a chat already
open. The expected result is a 26-point author image beside only a native-visible
incoming group/channel sender name; existing bubble gutter avatars, private-chat
layout and sidebar topic navigation remain unchanged.
