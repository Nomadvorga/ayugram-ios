# AyuAtmosphericUI

UIKit lifecycle adapters for explicit Atmospheric Snow surface owners. This is a leaf above `AyuAtmosphericHost`, with no renderer, interpreter, account-data or runtime-reflection dependency.

- Add a sentinel to the exact container that owns a surface. Publish geometry in that container's coordinates during its normal layout and visibility events.
- The sentinel draws nothing, never handles a touch, and never changes its own frame. The facade owns the native effect view's frame.
- Window/superview removal permanently detaches the current registration; reattachment creates a fresh one. Transient hiding uses `setOwnerVisible` and application lifecycle events.
- Container/screen ancestor-alpha changes still require an explicit owner event. Do not add per-frame tree scans or global-window discovery.
- `AtmosphericSurfaceVisibility` is typed containment forwarding, not a replacement for the application's normal appearance callbacks.
- No native build, device run or recorded-frame acceptance was performed in the Android staging environment.

The app's concrete owner bindings are listed in `../../docs/plugin-bridge.md`. ASDisplayNode helpers enter `MainActor.assumeIsolated` only from the existing UI layout/visibility callbacks; they are not background texture-layout hooks. Layout conversion already includes inherited transforms/alpha. Profile action geometry must not multiply a collapse scale twice. Profile controller callbacks suppress decoration while header views are lent to the expansion and restore current geometry after return. Section cards use the grouped-background span and a 26-point corner radius, not whole-row guesses.

Recorded-frame acceptance must still check continuous Core Animation alignment during interrupted tab/lens, keyboard, avatar expansion and section transitions, both legacy and iOS 26+ glass hierarchies. Source attachment and static wiring checks do not establish intermediate-frame alignment, native compilation or visual acceptance.
