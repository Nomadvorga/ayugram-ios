# Recording microphone selection: frame 81

The chat appearance page now contains a real microphone selector and a separate permission link.
`ExteraChatAppearanceSettings.microphone` persists `automatic`, `builtin` or `headset` under
`ExteraChatAppearanceSettings.microphoneKey` (`extera.chatAppearance.microphone`). The default and
unknown-value fallback are `automatic`. Device UIDs are not persisted.

## Input options and iOS limits

The selector's inventory comes exclusively from `AVAudioSession.availableInputs`, through
`TelegramAudio/RecordingMicrophoneInput.swift`. Settings read the session; they never activate it,
change its category/mode, request microphone permission, or steal an existing call/player holder.
When iOS reports no inputs, only automatic is enabled. The saved explicit preference remains visible
with an automatic-fallback explanation; the unavailable options remain disabled. Opening the screen,
opening the sheet and tapping an input do not start a recording session.

Input classification is independent of playback routing:

| Reported input port | Choice |
| --- | --- |
| Built-in microphone | `builtin` |
| Wired headset microphone | `headset` |
| Bluetooth HFP/LE **input** | `headset` |
| USB audio **input**, including USB-C headsets and external microphones | `headset` |
| A2DP, headphones, speakers, line input and other ports | Not a supported microphone choice |

The UI labels the third category **Headset / External Mic** and lists the actual candidate device
names in its multiline header. Bluetooth or wired headphones appearing only in `currentRoute.outputs`
do not create a microphone option. When several accessory inputs exist, the policy keeps an already
active matching input; otherwise it uses iOS's available-input order. This is a category preference,
not a saved preference for one accessory UID.

`availableInputs` is category-dependent and may be nil while idle or playing media. No synthetic
"connected headset" is inferred from outputs or cached from an old session. Inputs are checked again
after recording activation; a previously saved explicit category can therefore apply even when the
idle settings page could not enumerate it. Route changes update both the page and an open selector.
A tap rechecks current availability before saving, so an unplugged device cannot be newly selected
from a stale sheet. Choosing a category only saves the preference; the existing notification tells
an active recorder to apply it on its own queue.

Selecting a Bluetooth microphone can also switch output to its bidirectional profile and change
sample rate/quality. iOS and the hardware decide which input/output combinations are possible.
This implementation does not promise arbitrary A2DP-output/HFP-input combinations, add noise
suppression, force a microphone orientation/data source, or claim Android processing equivalence.

## Recording ownership and application

Voice messages (`ManagedAudioRecorder.start`) and round messages
(`VideoMessageCameraScreen.requestAudioSession`) already request `ManagedAudioSessionType.record`.
The camera implementations use the application audio session and disable automatic category
configuration, so no camera-engine fork is required. Other users of the same `.record` session,
including story/media recording, receive the same recording-input policy. Calls have distinct types.

`ManagedAudioSessionImpl` applies the preference only after `setActive(true)` succeeds, while a
nondeactivating recording holder owns the session, the current session type is `.record`, no
CallKit session is active, and the category supports recording. `setup()` alone is insufficient.
All input mutations and reapplications run on the manager's existing serial queue.

- `automatic`, an absent input, or the existing `respectsSystemRecordingInput` debug override means
  `setPreferredInput(nil)`. The debug setting retains precedence over saved explicit preferences;
  the page and sheet explain it when enabled.
- An explicit category resolves only to an available `AVAudioSessionPortDescription`, then calls
  `setPreferredInput` on the active recording session. Equal preferred UIDs are not reapplied,
  preventing the route notifications produced by this operation from creating a loop.
- Native recording setup can force the speaker, which can also force the built-in microphone.
  When an accessory is selected, or automatic/system fallback has an available accessory input,
  the manager first clears only its recorder-owned speaker override. It does not add a new output
  override. This allows public input selection to work within iOS's supported route combinations.
- Unplugging an accessory removes it from the inventory and clears its preferred input. The saved
  category remains intact, allowing a later reconnect to apply it again. Unknown/empty inventories
  also fall back to automatic; a stale `currentRoute.inputs` entry is never treated as available.
- A rejected explicit port is cleared to automatic and logged. The same failed attempt is suppressed
  until selection/inventory changes or another activation occurs. Availability changes invalidate
  that failure even if the accessory later reconnects under the same UID. Clearing errors are
  logged rather than reported as a successful hardware switch.
- Before a transition from recording to a call or playback, a recorder-owned preferred input is
  released; native output setup then takes over. The ownership flag also covers an already-matching
  preferred input adopted by the recorder. Interruption/media-service loss disables reapplication
  until successful activation. Normal deactivation clears the recording state.

The existing call holder precedence, call output classification, CallKit activation, recording
category/mode/options, mixing policy, pause-music behavior and speaker/earpiece output logic remain
under their existing code, with the recording speaker-override release described above. Settings
only read routes and save preferences; the recording route observer can release its own speaker
override but never recategorizes the session. Native recording setup no longer enters the legacy force-built-in branch
or chooses a "Bottom" data source on an arbitrary first port: recording input selection is owned by
the new policy. The legacy `forceBuiltInMic` flag remains in the native call/playback branch; the
new three-choice preference is authoritative for recordings and defaults to system selection.

## Root integration

Root owns all BUILD, localization, backup and workflow edits. Required handoff:

- Add `//submodules/TelegramAudio:TelegramAudio` to `AyuGram/SGSettingsUI/BUILD` dependencies.
  TelegramAudio already depends on SGSimpleSettings; the source/test BUILD globs already include
  the new adapter and native test file. No other dependency is added by this implementation.
- Add `ExteraChatAppearanceSettings.microphoneKey` to backup validation/import/export with allowed
  strings `automatic`, `builtin`, `headset`, default `automatic`, and unknown-value fallback.
- The existing host model test command also includes the new microphone policy tests. The native
  audio target is `//submodules/TelegramAudio:TelegramAudioTests`; it includes the existing call
  output/holder tests and five new snapshot/activation tests.

New localization keys, all prefixed `Extera.ChatAppearance.`:

| Suffix | English | Russian |
| --- | --- | --- |
| `Microphone.automatic` | Automatic (iOS) | Автоматически (iOS) |
| `Microphone.builtin` | Built-in Microphone | Встроенный микрофон |
| `Microphone.headset` | Headset / External Mic | Гарнитура / внешний микрофон |
| `MicrophoneUnavailable` | Unavailable — automatic | Недоступно — автоматически |
| `MicrophoneRoutingInfo` | Selects the microphone for recordings. Unavailable inputs fall back to automatic. Bluetooth may also change playback output and recording quality. Headphones without a microphone are not an input. | Выбор микрофона для записи. Если вход недоступен, используется автоматический выбор. Bluetooth также может изменить вывод звука и качество записи. Наушники без микрофона не являются входом. |
| `MicrophoneAvailabilityInfo` | iOS has not reported microphone inputs for this session. Availability will be checked again when recording starts. | iOS не сообщила о микрофонных входах для этой сессии. Их доступность будет проверена при начале записи. |
| `MicrophoneSystemOverride` | System microphone control is enabled in Debug Settings and overrides this choice. | В настройках отладки включён системный выбор микрофона. Он имеет приоритет над этим выбором. |
| `MicrophonePermission` | Microphone Permission | Доступ к микрофону |

Reuse existing `Microphone` as the selector's title and `MicrophoneInfo` as the separate permission
link's explanation. No permission link is presented as an input selector.

## Tests and verification status

The direct-source host suite has thirteen tests total, including persistence/defaults/notifications
for all three microphone values, option availability, built-in/accessory selection, disconnect and
reconnect fallback, multiple accessories, and the system-microphone override. It compiles the exact
production model and store with an isolated app-group suite; see
[`Tests/ExteraChatAppearance/README.md`](../Tests/ExteraChatAppearance/README.md).

`TelegramAudio/Tests/RecordingMicrophoneInputTests.swift` adds five pure native tests: AVAudioSession
port classification, output-only headphones/A2DP exclusion, nil/empty inventories, activation/holder/
CallKit gates, and rejection of every playback/call type. These construct snapshots and call the real
policy helpers; they do not activate the test process's shared audio session. Run the audio target
with the supported full Make.py test invocation from `CLAUDE.md`; its existing holder/output tests
must also pass to guard call behavior.

The host XCTest command was attempted after this change and stopped because Swift is unavailable.
All thirteen touched implementation/test Swift files passed the installed tree-sitter Swift parser
with zero ERROR/missing nodes. Scoped `git diff --check` passed. Native Swift typechecking, the full
iOS build, XCTest, live input selection, accessory recording and simulator recordings cannot run on
this Windows host. No hardware-routing or visual acceptance pass is claimed.

## Expected frames before recording

Follow `AGENTS.md`: record with `simctl io recordVideo`, extract labelled frames using
`tools/animation_sheet.py`, then inspect every frame and flagged transition. These are acceptance
expectations, not observations from a recording:

The existing native sheet should rise as one surface from below the screen in about 0.5 seconds
with its spring transition, while the backdrop fades in over about 0.4 seconds. Header, choices and
cancel group move together; the underlying list stays still. On selection or cancellation, the sheet
leaves downward over about 0.35 seconds and the backdrop fades over about 0.3 seconds. Inspect any
spring overshoot for clipping, duplicated content or separation between groups; there should be no
new independent bounce from rebuilding the microphone choices.

1. Open the page and microphone sheet in light/dark, English/Russian, normal/large text and with
   VoiceOver. The page shows the saved value; the sheet has exactly three preference choices,
   automatic always enabled, the saved preference bold, and absent inputs disabled. The permission
   link remains separately labelled. No audio activation/recording indicator is triggered by opening
   the page, opening the sheet, cancellation or changing a preference while idle.
2. With a real wired headset, USB-C headset/external microphone, Bluetooth HFP/LE input, and with
   output-only headphones/A2DP, verify that only real input options enable. Actual candidate names
   wrap in the header; names are not appended to single-line action buttons. No clipped header,
   doubled rows or ambiguous claim that headphones necessarily supply a microphone.
3. Connect/disconnect while the sheet is open. Enabled states and names change in that same sheet;
   the saved preference stays visible, automatic remains usable, and unavailable saved preferences
   show automatic fallback on the page. The sheet neither dismisses nor duplicates itself. Reopen
   to confirm persistence. A disconnected accessory tapped through an old UI event must not save.
4. With the system-microphone debug setting on, both page and sheet display its precedence. Changing
   saved preferences must not pin an input while that setting governs an active recording.

## Device audio acceptance

Simulator frames do not establish hardware behavior. On a real device, test voice and round recording
with each category, music mixing both on/off, start tone both on/off, built-in input while headphones
are outputs, and accessory removal/reconnect during a locked recording. Check the actual
`currentRoute.inputs`, `preferredInput`, ongoing waveform/timer, decoded samples and playback of the
saved result. Missing/rejected ports should leave a usable automatic route; API success alone does
not prove the hardware chose the requested microphone. Bluetooth quality/output changes follow iOS.

Also test voice/video/group calls on receiver, speaker, wired and Bluetooth routes: change the saved
recording preference while a call owns the session, trigger route notifications, attempt a recording
under the active call holder, and finish a recording before starting a call. Native call routing must
retain control. Repeat playback/earpiece switching after recording and interruption/resume. The
manager must not change category/mix/call-output policy from a settings/route observer; only an
active recorder may release the speaker override it owns, as described above. Attach real
frame/time references and audio-route evidence before declaring visual or device acceptance complete.
