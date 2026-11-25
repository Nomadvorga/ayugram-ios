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
The notification regression test makes a synchronous observer wait for a state read on
another queue. The wait is bounded: holding the feed lock while publishing fails the
test instead of hanging the host. The production setter batches store notifications
and releases its account-state lock before the batch publishes.

The suite does not exercise TelegramEngine/network history or UIKit. On a Mac, also build
the full app and verify channel/category navigation, background/foreground cancellation,
returning from the original chat, offline refresh preserving loaded posts, retry after
an unavailable history, and the loading limits. Visual changes require the simulator
recording/frame checks described in the repository's AGENTS.md.

The feed caps a selection at 40 channels, retains at most 100 posts per channel,
displays at most 1,000 merged posts, and scans at most 2,000 chats per list. Visibility
tokens are shared across child pages; the last page disappearing or the app resigning
active cancels history requests and chat-list subscriptions. Returning resumes unfinished
pages using their existing pagination state. An unavailable/unchanged history response
keeps prior posts and offers a manual retry instead of claiming an empty/read feed.

Added on Windows. Swift compilation and execution are not available on this host;
tree-sitter parsing is a syntax check only.
