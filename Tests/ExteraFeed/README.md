# Local channel feed settings tests

These host XCTest tests compile the exact production feed settings and settings store
with Foundation, Dispatch, and XCTest. They need no app bundle, login, simulator, Bazel,
or codesigning. A UUID-named UserDefaults suite replaces only the app group's build-time
identifier; the tests never access real account or app-group preferences.

Run from the repository root on macOS with Xcode's Swift toolchain:

```sh
TSAN_OPTIONS=halt_on_error=1 python3 tools/run_extera_xctests.py --sanitize=thread --warnings-as-errors \
  Swiftgram/SGSimpleSettings/Sources/AyuSettingsStore.swift \
  Swiftgram/SGSimpleSettings/Sources/ExteraFeedSettings.swift \
  Swiftgram/SGSimpleSettings/Sources/ExteraFeedHistoryPolicy.swift \
  Tests/ExteraFeed/ExteraFeedSettingsTests.swift
```

The runner copies these sources unchanged into a temporary Swift 5.9 package and runs
`swift test` in Swift 5 language mode with debug information, warnings as errors, and
Thread Sanitizer. SwiftPM discovers every XCTest method and supplies Xcode's XCTest
paths; the standalone `XCTMain` entry point is excluded in package builds because macOS
XCTest does not provide it. Build, test, and sanitizer failures fail the runner, and the
temporary package is removed when it exits. CI runs this same sanitizer command.

Coverage includes reopening persisted state, account isolation, cursor monotonicity,
per-channel read marks, shared read marks across categories, independent category and
main-feed membership, hidden/deleted/unknown category fallback, empty category behavior,
rename/reorder preservation, concurrent screen writes, and malformed storage recovery.
It also covers device-wide presentation preference persistence without account-state
mutation, full-registry bulk selections, deleted-category bulk actions, mark-all
scope across archive/category/unloaded channels, and bounded monotonic batch read marks.
The notification regression test makes a synchronous observer wait for a state read on
another queue. The wait is bounded: holding the feed lock while publishing fails the
test instead of hanging the host. The production setter batches store notifications
and releases its account-state lock before the batch publishes.

The suite does not exercise TelegramEngine/network history or UIKit. On a Mac, also build
the full app and verify channel/category navigation, background/foreground cancellation,
returning from the original chat, offline refresh preserving loaded posts, retry after
an unavailable history, and the loading limits. Visual changes require the simulator
recording/frame checks described in the repository's AGENTS.md.

The 22 model tests additionally cover category drag moves in both directions and to
the end, stale identities, hidden-category tab order, 2,500 channel queue completion,
four-request concurrency, cancellation/resumption, changed selections, and pagination
frontiers excluding exhausted channels. Queue/frontier tests execute the same production
policy used by `ExteraFeedContext`; they do not execute TelegramEngine RPCs.

The feed enumerates every subscribed broadcast channel in the local root/archive
registry and requests every selected eligible channel with at most four requests at once.
It retains at most 100 posts per channel and displays at most 1,000 merged messages. Visibility
tokens are shared across child pages; the last page disappearing or the app resigning
active cancels history requests and chat-list subscriptions. Returning resumes unfinished
pages using their existing pagination state. An unavailable/unchanged history response
keeps prior posts and offers a manual retry instead of claiming an empty/read feed.

Added on Windows. Swift compilation and execution are not available on this host;
tree-sitter parsing is a syntax check only.

```sh
uv run --with tree-sitter --with tree-sitter-swift python Tests/ExteraFeed/verify_swift_syntax.py
```

The renderer uses native Telegram message items with photos/video/round video/albums,
reaction chips, and comments. On Mac verify actual downloads and autoplay on cellular
and Wi-Fi, stopping playback on scroll/push/tab/background, opening/closing media,
custom reactions and removal, and the comment thread. Record and inspect labelled
frames before accepting visual behavior; expected frames and runtime gates are in
the handoff below.

The explicit Read All action now requires confirmation and enqueues the ordinary
TelegramEngine source-channel read-to-server-top operation. These model tests verify
the channel scope and local cursor updates, not confirmation UIKit or network sync.
The Mac runtime/frame checks and localization/API handoff are documented in
`docs/extera-feed-settings-implementation.md`.
