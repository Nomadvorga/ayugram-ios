# AyuAtmosphericHost

Typed UIKit surface attachment seam for the source-pinned Atmospheric Snow adapter.

- This module knows no Python, Telegram account data, Android classes or arbitrary selectors.
- `AtmosphericHost.shared` is disabled at process startup. The plugin service supplies a trusted native factory only after a user-driven, checksum-verified enable.
- Application components own `AtmosphericSurfaceAttachment` and publish local geometry, selected tab geometry, page context and visibility during their normal layout/lifecycle passes. No whole-view-tree discovery or polling is allowed.
- The registry holds attachments weakly. `disable()` synchronously removes every effect view, calls its animation cleanup and revokes the generation. Hosts must call `detach()` when their surface is permanently removed.
- The attachment, as parent, owns the effect view frame. The renderer must never mutate its own frame and must pass through every touch.
- Geometry describes the actual target pill/avatar/card. Non-snow canvases extend 12 points around it so caps, halos and icicles are not cut off at the pill edge; target and selected-tab rectangles are translated into that canvas, without changing the original UI component. Ancestor clipping still applies. Navbar background/foreground passes share this canvas and geometry.
- The attachment checks window membership, hidden/transparent ancestors and window intersection at host events. The renderer independently gates app/scene activity, Reduce Motion and animation clocks and checks actual decorated visibility while enrolled. Host lifecycle updates are required when visibility changes without layout; this facade creates no polling display link to discover hidden surfaces becoming visible again.
- Owners may pass `isDarkTheme`; otherwise `AtmosphericHost.shared.updateTheme(isDark:)` provides the explicitly forwarded Telegram presentation theme, with UIKit traits used only if neither context exists. Root theme changes refresh registrations even when component geometry is unchanged.
- `glassDrawsFrostWash` is false for owner-specific actionbar/filter/search/profile-tabs/composer routes. Only an explicit generic blurred-background route uses wash; navbar wash is its separate background plane. Action scale/reference size are typed geometry inputs, not persistent settings.
- This is not a generic Android hook implementation. Native source compatibility belongs to `AyuPluginBridge`, rendering belongs to `AyuAtmosphericSnow`.
- Native compilation and recorded-frame visual acceptance require macOS/Xcode; no passing tests, pixel parity or FPS are implied by these source files.
