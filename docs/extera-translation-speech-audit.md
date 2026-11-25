# Translation and speech runtime audit

Reference: `C:\Users\PC\exteragram-reference`, read with `git show HEAD:<path>`;
the sparse checkout and `.extera-scratch` files were not changed. The comparison
is with original exteraGram's translator and speech implementations, not Telegram's defaults.

## Implemented

- Microsoft requests unseal the reference credential, decode its Base64 key and
  sign the host plus path/query with the reference form encoding and date format.
  No substitute credential or user API key is introduced.
- Microsoft and Yandex validate HTTP status, body size before JSON parsing, result
  count and nonempty translations. HTTP 429 is retained as `limitExceeded`;
  Yandex's unsupported-language response is retained as `invalidLanguage`.
- All HTTP providers have request/resource timeouts and at most two retries after
  the first attempt for transport errors, HTTP 408/429/5xx. Numeric `Retry-After`
  values are honoured, bounded to 1–30 seconds. Cancellation disposes pending
  retry delays and active requests.
- Microsoft/Yandex split text at grapheme boundaries with a 5,000 UTF-16-unit
  budget, preferring whitespace boundaries, and serialize batches of at most 20
  texts. This is deliberately below Microsoft's 10,000-character request ceiling.
  Blank input is kept locally. Leading/trailing whitespace is restored.
- Google's query is built with URL components, including an explicit optional
  source language. Literal `+`, `&`, `#`, newlines and other query characters are
  encoded as data. Long lines are split with a 1,500-byte budget at grapheme
  boundaries, preferring whitespace; URLs above 8,192 bytes fail locally.
  Chunks, lines and messages are serialized within each translation operation.
- Whole-chat text translation uses the provider batch path instead of starting
  an unbounded collection of single-message requests. Results are mapped back
  using the original request order and written to the original account's Postbox.
  The current source text/transcript must still match before writing a result.
  Completed voice transcripts can use alternate providers.
- System translation does not reconfigure an active SwiftUI translation task when
  another request arrives. Disposal removes queued tasks, suppresses late results
  and cancels active async work. A 90-second timeout lets the existing fallback run.
- Language detection uses a recognizer per invocation instead of a shared mutable
  recognizer. Entity removal uses UTF-16 ranges, handles entities ending exactly
  at the end of text, ignores overlapping ranges, and checks the cleaned text.
- Apple transcription owns its recognizer/task/temp file per subscription, checks
  cancellation after authorization and file preparation, resolves app languages
  to supported Speech locales, and cleans up on completion, failure or disposal.
  File preparation runs off the main queue; results are delivered on the main queue.
  Partial hypotheses replace previous text rather than being appended. Empty
  results fail instead of being saved as a fabricated ellipsis. A 180-second
  processing timeout releases stalled tasks.
- Speech synthesis installs its delegate before speaking, reports cancellation
  through the completion callback once, and accepts an optional explicit language.
- The formerly empty non-System `presentTranslateScreen` branch now opens the
  existing native `TextProcessingScreen` through `SharedAccountContext`'s factory.
  It keeps copy permissions, replacement and chat-translation callbacks, explicit
  target/ignored-language options, and falls back when System presentation cannot
  be hosted. Explicit provider selection wins over server defaults. The double-tap
  gesture uses this presenter; no broad ChatController files were edited.
- Native single-message translation now uses the configured default target. HTTP
  and System translation no longer wait for Telegram's unused AI style catalogue
  before their screen can open.
- The voice-file node captures its original context/message/file/resource and
  rejects callbacks after reuse. Rebinding cancels pending transcription and resets
  the old transcription state, including the state used during layout measurement.
  Telegram transcription's delayed tooltip uses the same identity guards.

## Integration APIs

`SGSimpleSettings.ExteraTranslationSettings.shared`:

- `appleSpeechLocaleIdentifier: String`: supported Speech locale, e.g. `en-US`;
  empty means the language passed by the caller (currently predicted chat/app language).
- `appleSpeechOnDeviceOnly: Bool`: default false lets Apple choose recognition;
  true requires on-device support and never permits Apple server recognition.

Both preferences use the cached `AyuSettingsStore`, its existing app-group defaults
and change notification. The new Swift file is included by the settings module's glob.
No duplicate string-store accessors were added after integrating master.

`LocalAudioTranscription.supportedTranscriptionLanguages() -> [String]` returns
available locale identifiers, sorted. Model availability is checked at runtime.

`Speak.speakText(text: String, language: String? = nil)` remains compatible with
existing callers.

`TranslateUI.TranslationScreenOptions` and `TranslationScreenOptionsConsumer` carry
the initial language options across the shared screen factory. The concrete
`TextProcessingScreen` implements the consumer; its content uses the options before
starting translation. `defaultTranslationTargetLanguage(_:)` exposes the same
configured target policy to that component without introducing a dependency cycle.

## Exact remaining parity gaps and ownership handoffs

- exteraGram's Vosk model listing/download/delete/unload controls and AI transcript
  postprocessing are absent on iOS. Apple Speech is the actual implemented backend;
  no Vosk or AI placeholder is exposed.
- Alternate HTTP providers translate plain text and regenerate detectable entities.
  They do not preserve bold/italic/custom emoji/text-link formatting via exteraGram's
  formatted-translation/HTML mapping. Poll and rich-message translation remains
  available through the Telegram message-ID path, not alternate HTTP providers.
- There is no shared dispatcher implementing exteraGram's full request scheduling,
  cross-call deduplication/cache, or four-attempt exponential-backoff policy.
  Serialization is per operation; URLSession connection limits are 2 for Google and
  4 for Microsoft/Yandex and are not an HTTP/2 stream/concurrent-operation limit.
- The 2 MiB response limit is a parsing limit after URLSession buffers the response,
  not a streaming network-memory limit. HTTP-date `Retry-After` is not interpreted.
- Apple has its own recognition duration/model constraints; processing is capped at
  180 seconds. A selected language requiring an unavailable on-device model fails
  without silently switching to another language or uploading to Apple servers.
- The parent/settings agent integrated the Apple controls' settings rows/localization
  and backup entries; their runtime integration is complete in this domain.
- The legacy `isExpanded` presentation hint is not consumed by the native
  TextProcessingScreen; that screen controls its own sheet expansion. Native
  `wasDismissed` is delivered when the screen is released; the System host calls it
  after dismissal completes.

## Verification

- Live Node HTTP probes built from the corrected request/signing algorithm returned
  HTTP 200 and Spanish translations for **Microsoft, Google and Yandex** using
  `Hello, world!` as non-sensitive test input. Microsoft returned `¡Hola, mundo!`,
  Google `¡Hola Mundo!`, Yandex `¡Hola, mundo!`. The credential was not printed.
  These probes verify endpoint/request compatibility, not compiled Swift execution.
- Tree-sitter's Swift grammar parsed the service/settings changes and new integration
  paths. The large existing TextProcessingScreen file contains two baseline grammar
  errors at trailing commas; its modified regions parse without additional errors.
  This is not Swift type checking. The factory return type, consumer protocol,
  AccountContext reference semantics, resource-ID equality and signal error types
  were checked against their declarations; both retry triggers use explicit
  `Signal<Void, ...>.single(())` types.
- Presentation checks on macOS should show the existing native translation sheet
  opening once for each non-System provider and double-tap Translate, preserving
  copy restrictions and replacement actions; System should open Apple's sheet over
  the currently presented controller. Record each open/close path and inspect
  labelled frames for clipping or duplicate sheets before calling appearance verified.
  For transcription reuse, start recognition then recycle the voice-file node to a
  different account/message/resource: no transcript or delayed tooltip may appear
  on the replacement message, and the old work must cancel.
- `git diff --check` passed for the owned paths.
- No iOS build, Apple Speech/System Translation runtime, simulator frame recording,
  permissions flow or device-only language-model test could run on Windows; Swift,
  Xcode and the simulator are unavailable. No performance improvement is claimed
  from measurements. A macOS full build plus translation/transcription device checks
  remain required before release.

Temporary probe/parser artifacts are under
`C:\Users\PC\AppData\Local\Temp\opencode`, outside the repository.
