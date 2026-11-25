# Cached chat text export verification

The export covers messages already stored in the cloud-message namespace on this
device. It does not download history, fill holes, include media files, or perform
Telegram account takeout. Pages use a fixed maximum message index rather than a
database snapshot spanning the entire operation: deletion/editing/backfilling of
older cached messages while exporting can affect subsequent pages.

## Paging, ordering, and database responsiveness

- Seed 0, 1, 255, 256, 257, and 769 cached cloud messages. Parse the resulting JSON
  with `JSONSerialization`; verify every expected ID appears exactly once and is
  ordered by `(timestamp, id)`, including equal timestamps across page boundaries.
- Include untagged messages, service messages, and media captions. Untagged rows
  must be present; scheduled/local/secret namespaces must be absent. Media files
  must not be fetched or embedded. An empty cache returns valid `messages: []`.
- Insert a new message above the captured maximum index after the first page.
  Verify it is absent and the original maximum appears exactly once. Test an
  original maximum with `id == Int32.max` to exercise the timestamp successor.
- Delete the original maximum and an intermediate page boundary before those
  pages are read. Export must terminate, with no duplicates or infinite loop.
- Interleave an ordinary Postbox transaction between export pages. Verify it
  runs before export finishes. Profile JSON projection/serialization and confirm
  it runs on `CachedChatTextExport`, not the Postbox or main queue.

## Protection and text projection

- A secret chat, a group/channel with copy protection, and a private chat with
  either `CachedUserData.flags.copyProtectionEnabled` or
  `myCopyProtectionEnabled` must return failure before exporting messages.
- Enable chat protection between pages. The next page must fail the whole
  export; no partial file may be shared. Message-level protected and secret or
  view-once media messages must be omitted.
- Export rich messages with empty legacy `message.text`: paragraphs, headings,
  lists, quotes, table cells, formulas and captions must project into text in
  document order. When present, `fullInstantPage` takes priority over the preview.
  Verify ordinary text, Unicode, quotes, backslashes and newlines round-trip.

## Size, errors, and cancellation

- Exercise a JSON output just below, exactly at, and above 64 MiB, counting every
  comma and the closing `]}`. At most 64 MiB is returned; exceeding the bound
  fails as a whole rather than sharing truncated JSON.
- Inject serialization failure, a non-progressing page cursor, and an unwritable
  temporary directory. Completion receives `nil` on the main queue; the progress
  overlay closes and the failure alert appears. No temporary JSON remains.
- Dispose before the initial transaction, while a page is in flight, during
  serialization, before a file write, during a write, and after writing but before
  main-queue delivery. No later page, completion callback, failure alert, or share
  sheet is permitted; any generated file is removed. A write already in progress
  may finish, but its result must be removed before it can be shared.
- Verify unique filenames for simultaneous exports of the same chat. Cancelling
  one must not remove the other's output. All successful writes must be atomic
  and protected until first user authentication.

## UI and file ownership

- Start export from the menu and tap the loading overlay's cancel control. It
  must dismiss, dispose the task and produce no share sheet or failure alert.
  Dismissing/deallocating the progress overlay must also dispose its owned task.
- Remove the source controller/window during scanning, writing, and the delay
  between progress dismissal and sharing. A returned file must be removed.
- Complete or cancel the iOS share sheet. Both paths remove its temporary URL.
  Before the main-queue completion takes ownership, disposing the export owns
  cleanup; after transfer, the UI owns cleanup until share-sheet completion.
- On iPad, the activity popover must anchor to the actual presenter's view and
  remain inside its bounds. Verify success/failure does not present through an
  actively dismissing controller.
- On a Mac with Xcode, build the full app and record the export start, cancel,
  failure and share paths. Evaluate the recorded frames following root
  `AGENTS.md`; static checks on Windows do not verify appearance or animation.
