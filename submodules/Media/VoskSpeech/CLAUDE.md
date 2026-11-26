# VoskSpeech invariants

This is the independent Vosk backend. Keep existing Apple Speech code frozen.
See `docs/extera-vosk-runtime.md` for integration, artifact evidence and tests.

- No recognition-triggered downloads, Apple authorization or server fallback.
- Exact Android 24-model IDs/URLs/order. Change a pin only through explicit
  checksum-gated ingestion; preserve original license/README files.
- Native model/recognizer ownership must end before the store-wide file lease.
  Never unlink model files while C code can reference them.
- Downloads use private UUID staging; hash before extraction/native parsing;
  bounded streaming extraction; clean cancel/error/interrupted staging.
- Core receives packed mono S16/16 kHz through `VoskPCMSource`. Media framework
  dependencies belong to the separate VoskSpeechAudio adapter.
- Use compares the captured configuration after native validation; UI selection
  writes run on the main actor. Deletion clears selection after physical removal.
- Treat host stubs, syntax parsing and artifact inspection as their exact evidence;
  none proves an iOS SDK link, recognition accuracy or recorded UI acceptance.
