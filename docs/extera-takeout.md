# Native cloud-chat takeout export

This implements a server-backed **cloud chat history subset** of Android exteraGram's
account export. It is not complete Telegram Desktop/account takeout parity and does
not use the existing cached-chat exporter.

## Entry points

- `exteraTakeoutController(context:) -> ViewController` in SGSettingsUI. Push this from
  the parent settings. It provides setup, explicit start/cancel, progress, and a ZIP
  share sheet with iPad anchoring and temporary result ownership.
- `context.engine.messages.exportAccountTakeout(options:) -> Signal<ExteraTakeoutEvent,
  ExteraTakeoutError>` in TelegramCore. Each subscription starts a session; dispose
  cancels and requests unsuccessful session completion. Retain the completed
  `ExteraTakeoutResult` through sharing and call `remove()` afterwards.

Choices include personal/bot/private/public group/channel histories, left channels,
inclusive start and exclusive end dates, JSON/HTML/both, no media/photos/photos plus
files, and per-file size limits. The UI permits 8/32/128/512 MiB. Content is bounded
to 2 GiB; ZIP creation needs roughly another copy's storage and uses ZIP32 without
compression. Limits fail explicitly, never report a truncated archive as success.

## Protocol and paging

Requests match `swift_scheme.tl`, Android `export/api/TakeoutRequests.java` and
`ExportApi.java`, and the existing iOS `MacOS/MacRequests.swift` primitives.
`account.initTakeoutSession` uses only the selected message/file flags. Every later
request, including media parts and finish, is wrapped in `invokeWithTakeout`.
Dialog/history requests also use `invokeWithMessagesRange` over server-provided
`messages.getSplitRanges`. Generic TL wrappers prepend schema constructor bytes
while preserving the generated inner request's result decoder. No schema or
network implementation is modified, and TelegramApi stays internal to Core.

Main/archive dialogs are paged separately within each split with pinned dialogs
excluded from subsequent pages. Nonchannel histories are exported per split;
channel histories use the last split. Selected left channels are paged separately.
Peer-plus-split targets are deduplicated with a 50,000-segment ceiling. Histories
page backward using the lowest positive id as an exclusive cursor, reject a stalled
cursor, deduplicate overlap within each page, and stop on an empty server page or
the selected start date. Files stream in 512 KiB parts via a download worker for
their data center. No Postbox history is stored or marked read.

JSON streams chat segments with messages newest first within each split. Splits
and migrated groups are not merged into one conversation. HTML is a script-free,
escaped transcript with relative media links. `manifest.json` records scope,
choices, counts and omissions. Server filenames are labels only; generated safe
paths are used for saved bytes.

The initializer's subscription is allowed to resolve for up to 60 seconds after
UI cancellation so a late returned takeout id can be closed. Other requests time
out after 60 seconds. Session cleanup is best effort with a 15-second timeout;
network loss, process termination, or an initializer accepted by the server whose
response never arrives can leave a server session for Telegram to expire. Successful
output requires Telegram to return true for successful session completion. No
automatic takeout-delay bypass or unbounded flood retry is attempted.

## Explicit remaining parity

- Secret chats (device-local), profile/account information and photos, contacts,
  authorizations, other-data takeout files, stories and profile music.
- Persisted jobs/resume, background execution across suspension, destination picker
  before download, disk-capacity preflight, encrypted archive and ZIP64/compression.
- Full formatted entities, rich messages, poll/game/contact/location payloads,
  reactions, detailed service actions and sender-name directory. Plain text, ids,
  dates, direction, reply/group ids and media descriptors are exported.
- Topic navigation and migration merging. Public/left history availability remains
  controlled by Telegram; access errors fail the export instead of silently skipping
  a chat. There is no fallback to an own-messages-only `messages.search` export yet.
- CDN redirects and file-reference refresh. Unsupported/ephemeral/oversized/missing
  media are labelled with a skip reason and counted. Photo exports select the largest
  ordinary/progressive JPEG size. Alternative videos, live-photo video, previews,
  paid-media payloads and other nested attachments are not downloaded.
- Parallel exports are not coordinated across screens/accounts; keep one job per
  account. UI errors from Core currently have English descriptions; setup/progress
  labels use `Extera.Takeout.*` localization keys with fallbacks.

## Validation and acceptance

Tree-sitter source parsing, the schema/signature audit and the Postbox importer
guard can run on Windows. Swift tests in `Tests/ExteraTakeout` need a Swift host.
No iOS compile, live private-account takeout, simulator execution or visual
acceptance is claimed here.

On Apple tooling, build the app and run the Foundation writer/archive tests first.
With an authorized test account verify more than 100 dialogs/messages, archive and
pinned boundary cases, accounts with multiple split ranges, same ids in different
splits/channels, empty/deleted dialogs, date boundaries, left/private/public access,
media on another DC and final chunks. Inspect JSON validity, HTML escaping, ZIP CRCs,
file size limits, skipped reasons and disk failure. Test TAKEOUT_INIT_DELAY, flood
wait, cancellation during initialization/history/media/packaging/finish, navigating
back, retries, share dismissal and temporary directory cleanup. Confirm history is
not marked read and no export appears after cancellation.

Before visual recording, expected frames: setup controls stay inside safe bands;
Start disables choices while progress updates without shifting the buttons; Cancel
settles to a stopped state without a late share sheet; completed sharing opens over
the same screen and anchors correctly on iPad. Record real speed with `simctl io
recordVideo`, generate labelled frames and inspect light/dark plus entry/exit paths
under root AGENTS.md. These checks remain outstanding.
