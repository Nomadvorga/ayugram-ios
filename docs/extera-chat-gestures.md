# Chat gestures and composer port

Implementation is in `AyuGram/SGSimpleSettings/Sources/ExteraChatSettings.swift`,
`AyuGram/SGDoubleTapMessageAction/Sources/SGDoubleTapMessageAction.swift`,
`submodules/TelegramUI/Sources/Chat/ChatControllerExteraGestures.swift`, and the existing
`ChatController`, display-node loader, and mention-panel integration points.

## Public settings contract

All properties below are read/write on `ExteraChatSettings.shared` in `SGSimpleSettings`.

| Property | Type | Default / persistence |
| --- | --- | --- |
| `doubleTapIncoming` | `DoubleTapAction` | `.reaction`, `extera.chat.doubleTapIncoming` |
| `doubleTapOutgoing` | `DoubleTapAction` | `.inherit`, `extera.chat.doubleTapOutgoing` |
| `hideKeyboardOnScroll` | `Bool` | `false`, `extera.chat.hideKeyboardOnScroll` |
| `swipeToReplyIncoming` | `Bool` | `true`, `extera.chat.swipeToReplyIncoming` |
| `swipeToReplyOutgoing` | `Bool` | `true`, `extera.chat.swipeToReplyOutgoing` |
| `addCommaAfterMention` | `Bool` | Alias of existing `SGSimpleSettings.shared.commaAfterMention`; no new storage key |

`DoubleTapAction: Int, CaseIterable` has stable IDs: `inherit = -1`, `disabled = 0`,
`reaction = 1`, `reply = 2`, `copy = 3`, `forward = 4`, `edit = 5`, `save = 6`,
`delete = 8`, `translate = 9`. ID 7 (Android Repeat) is intentionally not exposed.
These are action IDs, not the Android incoming menu's shifted positional indices.
`inherit` resolves the legacy outgoing none/edit/default preference; incoming inherit
resolves to reaction. `effectiveDoubleTapAction(incoming:)` exposes this resolution.
`isSwipeToReplyEnabled(incoming:)` exposes the reply gesture policy.

## Behavior and permissions

- Bubble double taps use the existing shared Swiftgram handler. The controller's default-reaction
  callback also routes sticker double taps; explicit picker selections retain normal reactions.
- Reply reuses the previous swipe eligibility rules and does not depend on the swipe toggle.
- Edit uses the same `canEditMessage` rule as the context menu, including rights and edit expiry,
  then the existing composer setup and recording-discard flow. Frozen accounts are checked.
- Copy rejects protected content and copies message text through the existing pasteboard/toast path.
- Forward and Save reject secret chats and protected messages and query available message actions
  before invoking the existing forward or Saved Messages path. Save preserves sender names.
- Delete uses the existing confirmation/undo flow. Service, ephemeral, failed, and pending outgoing
  messages are excluded because some existing delete handlers can delete them immediately.
- Translate uses the existing text-selection translation handler and its configured provider.
- Keyboard dismissal runs once when a user begins dragging, after pending history transactions.
  It uses the existing `dismissInput` path for system, rich composer, and entity keyboards; the
  recording/persistent bot-keyboard guards stay in that path. No work was added per scroll frame.
- Mention insertion uses `replacingFlatRange` so rich composer content outside the replacement is
  preserved. Legacy and modern mention panels read the same existing comma preference.

## Remaining parity gaps

- Android supports an ordered enabled swipe-action sequence, a drag-distance action carousel,
  looping, and reversed ordering. This port only adds incoming/outgoing reply enablement to the
  existing iOS swipe gesture. It adds no inert loop/reversal settings.
- Android Repeat is absent from the double-tap action selector. The separate message-menu
  implementation supplies Repeat through the send pipeline, with permission and payment-state guards.
- Unlimited recent stickers is absent. TelegramCore caps recent-sticker insertion in multiple
  state/update paths and replaces the list during server synchronization. A keyboard-only change
  cannot provide unlimited persistence. No inert setting was added.
- Non-bubble sticker nodes can gate their reaction callback on reaction eligibility before the
  controller receives it. Custom double tap on non-reactable stickers (including some Saved Messages
  cases) needs a message-rendering-owned gesture seam. Bubble actions use the shared handler and
  do not have this limitation.
- Copy and Translate currently operate on message text/captions, not rendered images or a flattened
  rich document with attachments. Image Copy and structured rich-text export belong to separate paths.

## Verification status

Windows host: no Swift/Xcode or iOS simulator was available. No build, device execution, visual,
or animation verification is claimed. Targeted `git diff --check` passed. A Node script outside
the repository checked delimiter counts, conflict markers, registered settings defaults, shared
mention preference storage, and dispatcher action coverage. The user's `bracket_check.py` was
read but not changed. Existing Bazel source globs include both new Swift files.

On a Mac, build the full app with the root guide's supported Make.py command. Then verify incoming
and outgoing text, captions, albums, stickers, Saved Messages, secret/protected chats, expired edits,
forum thread heads, pending sends, and service messages for every exposed action. Delete should
always present confirmation on eligible ordinary messages. Test both CoreList and ListView backends,
legacy/native rich composer modes, system/entity keyboards, active recordings, persistent bot keyboards,
and comma insertion with/without usernames and chained mentions. With scroll dismissal enabled,
the keyboard and composer should close together through the existing transition while the history
remains continuous; recording controls must remain present during an active recording. Record and
evaluate labelled simulator frames as required by AGENTS.md before marking visual behavior verified.
