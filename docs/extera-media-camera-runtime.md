# Camera regulator, static zoom and volume-unmute

Scope: Android references 60/63/64 in `extera-reference-screens-45-66.md` and the
Camera/Photo/Video entries in Android `ChatsPreferencesActivity.kt`. Implementation
date: 2026-11-25. Production changes are uncommitted. Windows validation does not
establish a successful iOS build, device behavior or visual parity.

## Settings and actual consumers

| Public property | Persistent key | Registered default | Runtime consumer |
| --- | --- | --- | --- |
| `ExteraMediaSettings.zoomSlider` | `extera.media.zoomSlider` | `true` | `VideoMessageCameraScreen.Node` displays a `UISlider` below the live round-video preview when the active device supports a variable zoom range |
| `ExteraMediaSettings.staticZoom` | `extera.media.staticZoom` | `false` | Slider release and pinch end/cancellation retain or reset the active lens factor |
| `ExteraMediaSettings.unmuteWithVolumeButtons` | `extera.media.unmuteWithVolumeButtons` | `false` | `UniversalVideoGalleryItemNode` observes public system output-volume changes and enables sound for eligible playback |

Root owns the settings UI, en/ru text, backup, BUILD and CI integration. These names
and defaults are unchanged. There is no additional stored startup zoom value and no
new build dependency: the screen already imports Camera and SGSimpleSettings;
GalleryUI uses AVFoundation for public `AVAudioSession` observation.

## Round-video zoom behavior

The real round-video path is `VideoMessageCameraScreen` with `CameraLegacy` or
`CameraNeo`. Android Camera1/CameraX are not exposed as pretend iOS backend choices.

`CameraProtocol.updateZoom(_:completion:)` executes on each backend's capture/session
queue and returns a `CameraZoomState?` on the main queue. `CameraZoomUpdate` supports
reading, slider fraction, multiplicative pinch delta and reset. A read does not
cancel an existing zoom ramp. Writes cancel an existing ramp and clamp through the
capture device's actual minimum/maximum. Missing devices return nil.

`CameraZoomState` validates finite positive ordered bounds, clamps the neutral/current
factor, recovers nonfinite current values to neutral, maps slider position
logarithmically and handles a fixed device range without division by zero. It
supports a device-reported lower bound below 1; the capture backend's existing final
AVCaptureDevice clamp remains authoritative. Invalid pinch/fraction inputs leave
the current factor unchanged; oversized finite deltas clamp to the actual device.

The regulator is visible only in live capture, when enabled and zoom is variable.
Hiding it does not disable pinch zoom. The layout reserves its space before the
asynchronous device response so the preview entrance has one resting frame. The
slider appears after entrance and fades with the preview on exit. Space remains
reserved on fixed-range devices while the setting is enabled. It is absent in
result preview and while capture is paused or the camera is dismissing. It has the
standard adjustable UISlider accessibility behavior and a factor relative to the
active lens's neutral value.

With static zoom enabled, slider release, long pinch release and cancellation keep
the in-session factor. With it disabled, slider release and long/cancelled pinch
reset immediately to neutral. The pre-existing quick-pinch exception (at most 0.5 s)
is preserved and keeps its factor even with static zoom disabled. No smooth reset
ramp is claimed by this implementation.

Position changes reset the newly selected lens; a flash-only state notification
does not reset zoom. A reset is enqueued on the next main turn, after the synchronous
position setter has scheduled its backend switch, then runs on the backend serial
queue. Old UI snapshots are invalidated and the slider is disabled until the new
snapshot arrives. Legacy uses the additional front device only during dual capture;
single-front capture uses the main device. Legacy reset uses `neutralZoomFactor`
(which can differ from 1 for a virtual device); Neo's wide-camera neutral is 1.
Existing preferred startup camera and last-camera memory are preserved.

## Volume-unmute and public iOS limits

The only event source is KVO on public
[`AVAudioSession.outputVolume`](https://developer.apple.com/documentation/avfaudio/avaudiosession/outputvolume).
Apple documents this systemwide value as user-controlled and KVO-observable.
There are no private notifications, hardware-button interceptors, hidden MPVolumeView
controls, category changes or audio-session activation in this feature.

Public iOS APIs cannot consume the hardware key, keep system volume unchanged when
the user presses it, distinguish a button from Control Center/other system volume
changes, or detect a press that leaves volume at an endpoint. Accordingly, **system
volume still changes normally**. This is an iOS adaptation of Android's behavior.
Output-route changes can also produce volume changes; KVO does not identify intent.

The sample predicate rejects missing/no-op/nonfinite/out-of-range values, noise at or
below 0.0001 and a resulting zero volume. Both increases and decreases with a positive
result can enable sound. There is no initial KVO event that unmutes on opening.

Observation is scoped to the foreground, visible central nonsecret item and
invalidated on visibility, centrality, item setup, foreground changes and deinit.
Queued main-thread callbacks carry an observation generation and recheck runtime
eligibility. Replacing a media node clears the old playback status. Before unmuting,
the app must be active, the node attached to a window, central/visible, not animating
out, and own the actual content node. Secret media, Live Photos, animations, unknown
content types, paused playback and PiP are excluded. Playback must be playing or
buffering while playing. Native `soundMuted` and ordinary sound-disabled playback
are supported; HLS uses its public file classification and playback status.

The consumer calls `setSoundMuted(false)` and, when sound is disabled,
`setSoundEnabled(true)`. The existing Native/HLS implementations enable sound without
seeking (`seek: .none`). No explicit play/restart/seek is issued here. Existing
background-pause preferences and PiP eligibility guards remain in place.

## Validation and remaining evidence

Windows checks and the exact host harness are in
[`Tests/ExteraMedia`](../Tests/ExteraMedia/README.md). Tree-sitter syntax checks pass
for the changed production/test files and emitted policy wrapper. Neo's two
pre-existing grammar errors at zero-based rows 106/107 (`value: ()`) match `HEAD`;
an in-memory `Void()` normalization parses the complete changed file cleanly.
Ten source integration contracts pass. Swift behavioral assertions are prepared
and emitted, **not executed**: this environment has no `swiftc`, Xcode or iOS
Simulator. No iOS build or recorded-frame verification is claimed.

Before visual sign-off, follow root `AGENTS.md`: record the real screen with
`simctl io recordVideo`, generate labelled frame sheets via `tools/animation_sheet.py`,
and inspect the sheets and every flagged frame. The expected frames are: one round
preview moves into its reserved position; slider appears below it after entrance;
the slider never covers flash/flip, cancel/send/trash, the input panel or safe-area
blocks; preview and slider fade together on exit; no slider remains over a result.
Capture entrance/exit, preview return, light/dark, regulator off/on, short screens
with system/bot keyboards, tablet orientations and Duo reserved corners. Inspect
frame timestamps and cite evidence before calling the visuals verified.

Real-device checks must cover both backends, front/back, single/dual camera where
supported, physical/virtual cameras, min/max factors, rapid flips, pinch/slider
release with static zoom off/on, background pause/resume and unavailable/fixed zoom
devices. Confirm the new lens's neutral rather than a hardcoded 1 on virtual Legacy
devices. Verify volume-unmute with Native/HLS, muted starts, buffering, paused
playback, item swipes, background, PiP, secret media, Live Photos, animations, Control
Center, Bluetooth/route changes and volume endpoints. It must preserve the playhead
and exclude ineligible players.

## Other media-reference gaps

Existing photo `disableGalleryCamera` maps to `.none` in
`MediaPickerUI/Sources/MediaPickerScreen.swift`; an Android floating replacement
camera button with tap/hold parity was not added in this camera/gallery scope.
No unsupported photo setting was introduced. Original quality, double-tap seeking,
startup-camera selection and background pause are existing independent consumers;
this change does not claim a fresh device audit of them. Speech/model management
belongs to the next assignment and is untouched here.
