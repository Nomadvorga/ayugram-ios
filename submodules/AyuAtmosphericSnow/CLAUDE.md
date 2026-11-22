# AyuAtmosphericSnow — source-pinned native renderer

## Status, attribution, and scope

- Original plugin: **`atmospheric_snow` / NewYear Interface**, author **`@coshize`**, version **`1.0.1`**.
- Read-only original: `/data/data/com.termux/files/home/downloads/atmospheric_snow.plugin`.
- Supplied SHA-256: **`bbda8727d253e02542c1c1f51dca1d39d235e2a310b4ba096e5e6305472a6763`**. This renderer task did not recompute the hash, execute/import the plugin, or copy it into this module as a resource.
- Target context supplied by the parent: **`Nomadvorga/ayugram-ios`**, branch **`plugins-test`**, pin **`cc246f35559093e7bd645be367fb68f96b5b58f5`**. No original `AyuSnowEffect` baseline exists at the supplied pin; no code was imported from it.
- Authoritative cross-checks: `../../apk-analysis/atmospheric-spec.md` and `../../apk-analysis/atmospheric-settings.json`. Those artifacts were read, not modified by this renderer task. Source line anchors below refer to the original `.plugin`, not repository Swift files.
- **Unverified renderer implementation.** The renderer task performed no compilation, native tests, simulator/device execution, screenshots, recorded frames, integration, FPS measurement, commit, push, or publication. Creating the renderer alone does **not** connect a plugin to AyuGram; the parent supplies the integration described below.
- The renderer task was confined to this module's new Swift sources/tests and this notes file. The parent subsequently expanded delivery to BUILD wiring, bridge/service/import/settings UI, manager registration and real app attachments at the user's request. The user explicitly authorized GitHub IPA CI, superseding the earlier source-only `[skip ci]` plan. No local native build is allowed or performed in the Android environment.

The backend implements only this pinned plugin's native rendering contract. It is not a Python runtime, Android hook/reflection bridge, generic particle engine, or glass/blur replacement.

## Files

- `Sources/AtmosphericSnowConfiguration.swift`: primitive storage values, exact settings/enums, migration, errors.
- `Sources/AtmosphericSurface.swift`: strongly typed surface, geometry, visibility, motion, render-plane, and validation contracts.
- `Sources/AtmosphericParticleSystem.swift`: bounded deterministic native simulation and source-derived presentation equations.
- `Sources/AtmosphericSprites.swift`: generated snow/bulb/sparkle sprites and bounded source-color ownership.
- `Sources/AtmosphericDecoration.swift`: cached festive bodies and separate dynamic presentation/selected-tab state.
- `Sources/AtmosphericEffectView.swift`: touch-transparent UIKit view, visibility checks, shared weak display-link/event registry, terminal teardown.
- `Tests/AtmosphericSnowConfigurationTests.swift`, `Tests/AtmosphericParticleSystemTests.swift`, `Tests/AtmosphericDecorationTests.swift`, `Tests/AtmosphericEffectViewTests.swift`: **written but not run**; the parent wired `//submodules/AyuAtmosphericSnow:AyuAtmosphericSnowTests` with the pinned iPhone 17 / iOS 26.5 runner. IPA compilation alone does not run this target.

The sources use UIKit scene APIs (iOS 13+) and modern Swift concurrency annotations. The parent must check its actual SDK, deployment target, Swift language mode, and module/test target; compatibility has not been compiled here.

## Exact settings contract

There are **15 user keys and one internal marker**. Selector values are indices, not their physical multipliers. No separate `intensity`, glass style, profile style, collision setting, or named whole-theme preset exists.

| Source key | Public Swift field / type | Default | Indices / meaning |
| --- | --- | --- | --- |
| `snow_enabled` | `snowEnabled: Bool` | `true` | Falling snow only |
| `snow_area` | `snowArea: AtmosphericSnowArea` | `0` / `.everywhere` | `0 everywhere`, `1 chatsOnly`, `2 chatListAndChats` |
| `navbar_festive_enabled` | `navbarFestiveEnabled: Bool` | `true` | Navbar wash/decor/selected glow |
| `glass_pills_enabled` | `glassPillsEnabled: Bool` | `true` | Glass roles, including profile tabs; not profile actions/avatar/cards |
| `profile_festive_enabled` | `profileFestiveEnabled: Bool` | `true` | Profile actions, avatar, grouped cards |
| `navbar_style` | `navbarStyle: AtmosphericFestiveStyle` | `0` / `.snowcapAndGarland` | `0 snowcapAndGarland`, `1 frostAndIcicles`, `2 warmGarland`, `3 auroraAndSparkles` |
| `navbar_garland_palette` | `navbarGarlandPalette: AtmosphericGarlandPalette` | `0` / `.holidayMix` | `0 holidayMix`, `1 warmGold`, `2 icyNeon` |
| `navbar_active_glow` | `navbarActiveGlow: Bool` | `true` | Selected-tab glow and extra non-thin glass sparks; not a master switch |
| `snow_density` | `snowDensity: AtmosphericSnowDensity` | `1` / `.medium` | `0 light = 26`, `1 medium = 50`, `2 heavy = 82` particles |
| `snow_speed` | `snowSpeed: AtmosphericSnowSpeed` | `1` / `.normal` | `0 slow = 0.6`, `1 normal = 1.0`, `2 fast = 1.55` vertical multipliers |
| `snow_wind` | `snowWind: AtmosphericSnowWind` | `1` / `.breeze` | `0 calm = 0`, `1 breeze = 18`, `2 blizzard = 48` points/s before gust/layer factors |
| `snow_style` | `snowStyle: AtmosphericSnowStyle` | `2` / `.mixed` | `0 bokeh`, `1 crystals`, `2 mixed` |
| `snow_size` | `snowSize: AtmosphericSnowSize` | `0` / `.verySmall` | `0 verySmall = 0.45`, `1 small = 0.70`, `2 normal = 1.0`, `3 large = 1.35`, `4 veryLarge = 1.75` |
| `snow_opacity` | `snowOpacity: AtmosphericSnowOpacity` | `4` / `.bright` | `0 barelyVisible = 0.25`, `1 translucent = 0.50`, `2 soft = 0.75`, `3 normal = 1.0`, `4 bright = 1.35` |
| `snow_color` | `snowColor: AtmosphericSnowColor` | `0` / `.automatic` | `0 automatic`, `1 white`, `2 icyBlue`, `3 warm` |
| `snow_defaults_v` | read-only `sourceDefaultsVersion: AtmosphericSettingValue` | `.integer(1)` after migration | Internal marker, not user UI or animation state |

All selector enums have `Int` raw values, `CaseIterable`, `Codable`, and `Sendable` conformance. Physical accessors are `AtmosphericSnowDensity.particleCount: Int`, `AtmosphericSnowSpeed.multiplier: Double`, `AtmosphericSnowWind.strength: Double`, `AtmosphericSnowSize.multiplier: Double`, and `AtmosphericSnowOpacity.multiplier: Double`.

The public storage boundary is:

```swift
public enum AtmosphericSettingValue: Equatable, Sendable, Codable {
    case boolean(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case null
}

// AtmosphericSnowConfiguration API signatures:
public init(settings: [String: AtmosphericSettingValue]) throws
public static func migrateSettings(
    _ settings: [String: AtmosphericSettingValue]
) throws -> AtmosphericSettingsMigration
public var settings: [String: AtmosphericSettingValue] { get }
public static let supportedKeys: Set<String>
public static let pluginIdentifier = "atmospheric_snow"
public static let sourceVersion = "1.0.1"
public static let sourceSHA256 = "bbda8727d253e02542c1c1f51dca1d39d235e2a310b4ba096e5e6305472a6763"
```

The nonthrowing typed initializer is already migrated and accepts these exact arguments:

```swift
public init(
    snowEnabled: Bool = true,
    snowArea: AtmosphericSnowArea = .everywhere,
    navbarFestiveEnabled: Bool = true,
    glassPillsEnabled: Bool = true,
    profileFestiveEnabled: Bool = true,
    navbarStyle: AtmosphericFestiveStyle = .snowcapAndGarland,
    navbarGarlandPalette: AtmosphericGarlandPalette = .holidayMix,
    navbarActiveGlow: Bool = true,
    snowDensity: AtmosphericSnowDensity = .medium,
    snowSpeed: AtmosphericSnowSpeed = .normal,
    snowWind: AtmosphericSnowWind = .breeze,
    snowStyle: AtmosphericSnowStyle = .mixed,
    snowSize: AtmosphericSnowSize = .verySmall,
    snowOpacity: AtmosphericSnowOpacity = .bright,
    snowColor: AtmosphericSnowColor = .automatic
)
```

`AtmosphericSnowConfiguration` is an `Equatable, Sendable` value; the 15 settings fields are mutable typed properties. Copy and update a snapshot off the draw path, then deliver it to the main-actor view. There is no settings dictionary lookup or JSON decoding in animation/drawing callbacks.

### Coercion, fallbacks, migration, persistence

- Source `int(value)` semantics are represented for primitives: booleans become 0/1; finite numeric values truncate toward zero; decimal strings support whitespace, sign, underscores, and Unicode decimal digits. Malformed/out-of-range selectors use **that key's default**, never endpoint clamping. Positive overflowing version strings do not accidentally trigger migration.
- Switches preserve source primitive truthiness: zero/null/empty string are false; nonzero numbers and nonempty strings, including `"false"`, are true. The host should normally store typed booleans/indices, not textual aliases.
- Unknown keys throw `AtmosphericSettingsError.unsupportedKey(String)`; non-finite numeric values throw `.nonFiniteNumber(String)`. Codable rejects arrays/objects and non-finite encoding with decoding/encoding errors. These are intentional strict native boundary failures, not silent success.
- The only migration is v1 (source L384–401). Missing, malformed, zero, negative, or integer-coerced `<1` marker overwrites these keys **in order**, even if customized: `snow_density=1`, `snow_speed=1`, `snow_wind=1`, `snow_style=2`, `snow_size=0`, `snow_opacity=4`, `snow_color=0`, then `snow_defaults_v=1`. Other supplied keys are unchanged.
- An integer-coerced marker `>=1` preserves the supplied dictionary and marker, including future versions. Plugin version `1.0.1` is not a second migration.
- `AtmosphericSettingsMigration` exposes read-only `values: [String: AtmosphericSettingValue]`, `didApplySnowDefaultsMigration: Bool`, and `changedKeys: [String]`. It is pure and does not persist anything. The parent owns namespace-only persistence and can write the seven selectors before the marker (marker last); retry on partial persistence failure. The renderer does not reproduce Android's swallowed storage exceptions.
- `init(settings:)` applies the migration before creating a typed snapshot, but does not persist it. To persist the exact migration result, use `migrateSettings` first. `configuration.settings` is the canonical typed output for all 16 keys, preserving the marker; it is not the unnormalized original dictionary.
- All five feature switches remain independent. Area filters snowfall only: `.chatsOnly` includes `.chat`, `.chatListAndChats` includes `.chat`/`.chatList`; both also preserve the explicit `.lookupFailed` exception fallback and exclude `.unavailable`. The backend never discovers controllers itself.
- There is **no reset/clear settings UI in the original source**. View `reset(seed:)` is a native simulation/testing extension, not a settings reset. Unload/invalidation never deletes preferences. Any parent reset/clear UI is a separately documented host extension, scoped only to `atmospheric_snow`.

## Exact UIKit adapter interface

All view APIs are **`@MainActor`**. The value contracts are strongly typed `Equatable, Sendable`; no `Any`, Python handles, arbitrary selector names, or untyped host pointers are accepted.

```swift
// AtmosphericEffectView: public final UIView subclass, @MainActor
public init(
    configuration: AtmosphericSnowConfiguration = .init(),
    surface: AtmosphericSurface = .snow,
    renderPlane: AtmosphericRenderPlane = .combined,
    seed: UInt64 = AtmosphericEffectView.defaultSeed,
    motionPolicy: AtmosphericMotionPolicy = .system
) throws

public func update(configuration next: AtmosphericSnowConfiguration) throws
public func update(surface next: AtmosphericSurface) throws
public func update(hostState: AtmosphericHostState)
public func update(motionPolicy: AtmosphericMotionPolicy)
public func reset(seed: UInt64)
public func prepareForRendering() throws
public func refreshVisibility()
public func invalidate()

public nonisolated static let defaultSeed: UInt64 = 0x415955534E4F5731
```

Read-only adapter properties: `configuration: AtmosphericSnowConfiguration`, `surface: AtmosphericSurface`, `renderPlane: AtmosphericRenderPlane`, `hostState: AtmosphericHostState`, `motionPolicy: AtmosphericMotionPolicy`, `renderingError: AtmosphericRenderingError?`, `isInvalidated: Bool`, `isAnimationScheduled: Bool`, `particleCount: Int`, `isEffectVisible: Bool`. Scheduling/count/visibility are diagnostics, **not** FPS or verified app readiness.

- Init starts with **zero frame** and `AtmosphericHostState(pageKind: .unavailable, isVisible: false)`. The host assigns frame/bounds, installs the view in its chosen hierarchy, and supplies visibility/page state. The effect never assigns its own frame, bounds, center, or UIKit transform.
- Config/surface updates validate and prepare before committing; a thrown invalid request keeps the previous valid state. UIKit layout/window/trait callbacks prepare as needed. Required sprite/gradient allocation failures are `.graphicsAllocationFailed`; explicit preparation failure clears active/cache resources, stops enrollment, and records `renderingError`. A static bitmap can instead fall back to already-cached vector commands.
- `invalidate()` is **terminal and idempotent**: unregister from clock/events, release per-view graphics/cache references and particle storage, and set `.invalidatedView`. Subsequent config/surface/prepare calls throw that error; stale host/motion/seed messages and visibility refreshes cannot restart it. Create a new view for a new generation. The parent must additionally revoke its own queued generation callbacks and remove its attachments.
- `reset(seed:)` re-seeds native particles and sets a frozen sample to zero; active views rejoin the shared phase on the next tick. It does not reset other surfaces or settings.
- Hit testing always returns nil/false, even if a host re-enables user interaction. The overlay is transparent/nonopaque and excluded from accessibility elements; host controls/content remain accessible.

### Surface and geometry signatures

All rectangles and clip rectangles use the **effect view's local UIKit-point coordinate space**. They are not window coordinates, safe-area guesses, Android pixels, or inferred whole-row frames.

```swift
public enum AtmosphericSurface: Equatable, Sendable {
    case snow
    case navigationBar(AtmosphericNavigationBarGeometry)
    case glassPill(role: AtmosphericGlassPillRole, geometry: AtmosphericPillGeometry)
    case profileAvatar(AtmosphericAvatarGeometry)
    case profileAction(AtmosphericProfileActionGeometry)
    case sectionCard(AtmosphericSectionCardGeometry)
    // public var kind: AtmosphericSurfaceKind { get }
    // public func validate() throws
}

public enum AtmosphericRenderPlane: Equatable, Sendable {
    case background, foreground, combined
}
public enum AtmosphericMotionPolicy: Equatable, Sendable {
    case system, reduced, full
}
public enum AtmosphericPageKind: Equatable, Sendable {
    case chat, chatList, profile, other, unavailable, lookupFailed
}
public enum AtmosphericPillShape: Equatable, Sendable {
    case automatic
    case roundedRectangle(cornerRadius: CGFloat)
}
public enum AtmosphericGlassPillRole: Equatable, Sendable {
    case button, folder, header, search, profileTabs, messageInput, blurredDrawable
}

// AtmosphericHostState initializer / mutable fields:
public init(pageKind: AtmosphericPageKind = .unavailable, isVisible: Bool = false)
// AtmosphericSurfaceVisibility initializer / mutable fields:
public init(isVisible: Bool = true, opacity: CGFloat = 1)
// .visible and .hidden are public static presets on AtmosphericSurfaceVisibility.

// AtmosphericPillGeometry initializer / mutable fields:
public init(
    rect: CGRect,
    shape: AtmosphericPillShape = .automatic,
    visibility: AtmosphericSurfaceVisibility = .visible,
    clipRect: CGRect? = nil,
    drawsFrostWash: Bool = false,
    drawsTopDecoration: Bool = true,
    drawsBottomDecoration: Bool = true,
    clampsTopEdge: Bool? = nil
)
// AtmosphericSelectedTabGeometry:
public init(rect: CGRect, visibility: AtmosphericSurfaceVisibility = .visible)
// AtmosphericNavigationBarGeometry:
public init(pill: AtmosphericPillGeometry, selectedTab: AtmosphericSelectedTabGeometry? = nil)
// AtmosphericAvatarGeometry:
public init(
    rect: CGRect,
    visibility: AtmosphericSurfaceVisibility = .visible,
    expansionProgress: CGFloat = 0,
    hasStories: Bool = false,
    insetProgress: CGFloat = 1,
    foregroundAlpha: CGFloat = 0,
    clipRect: CGRect? = nil
)
// AtmosphericProfileActionGeometry:
public init(
    pill: AtmosphericPillGeometry,
    expansionFraction: CGFloat = 1,
    scale: CGFloat = 1,
    expandedReferenceSize: CGSize? = nil
)
// AtmosphericSectionCardGeometry:
public init(pill: AtmosphericPillGeometry)
```

`AtmosphericSurfaceKind` has string/Codable/Sendable cases `snow`, `navigationBar`, `glassPill`, `profileAvatar`, `profileAction`, `sectionCard` for diagnostics.

### Explicit validation / unsupported contracts

- `AtmosphericGeometryError` cases: `invalidRectangle`, `invalidOpacity`, `invalidCornerRadius`, `invalidProgress(String)`, `unsupportedDimensions(AtmosphericSurfaceKind)`, `unsupportedRenderPlane(AtmosphericSurfaceKind)`, `unsupportedShape(AtmosphericSurfaceKind)`, `unsupportedFrostWash(AtmosphericSurfaceKind)`. These and settings/rendering errors are `Error, Equatable, Sendable, LocalizedError`.
- Rectangles must have finite origins/extents/maxima and positive width/height. An empty clip rectangle is invalid: represent an invisible/fully clipped target with `.hidden` visibility and a nil or valid clip, not a zero-size clip. Opacity/progress/scale must be finite in `0...1`; explicit radii finite/nonnegative and then source-clamped to half dimensions.
- Navbar pill width/height must be `>20` points. Host supplies actual pill and selected-child translated geometry; this view does not apply Android's 7.67-dp padding to its frame.
- Glass pills require width `24...1200`, height `22...88`. `.messageInput` permits height through **520**. `.blurredDrawable` narrows width to **650**. Roles are explicit; a tall composer is not silently collapsed to a small button.
- Profile avatar requires both dimensions `>=38` and width/height difference `<=12`; the centered reference ring uses the smaller side.
- Profile actions require width `24...1200`, height `32...120`, **explicit `.roundedRectangle(cornerRadius:)`**, and **no frost wash**. Expanded reference size, if supplied, obeys the same width/height limits. One view is one action, not an inferred set of three.
- Section cards require width `120...1200`, height `28...1800`, an explicit rounded-rectangle radius, and no wash. They represent host-grouped qualifying profile sections, not every cell or an arbitrary list.
- `.background` is accepted only for navbar and glass pills with `drawsFrostWash=true`; otherwise it throws `.unsupportedRenderPlane`. `.foreground` and `.combined` are supported for all surfaces; snow has no background-only pass.
- Arbitrary `CGPath` outlines, meshes, custom collision masks, invented styles/settings, Android private class lookup, and missing host adapters are **not supported**. The typed API has no arbitrary-path case. The parent bridge must report unsupported host geometry/API explicitly, not substitute a rectangle or acknowledge an attachment that it cannot make.

## Navbar planes and source pulses

**`.combined` is the standalone-preview default, not production navbar layering.** For real content, construct two views with the same configuration, local geometry, host state, frame, and motion policy:

```swift
let background = try AtmosphericEffectView(
    configuration: configuration, surface: .navigationBar(geometry), renderPlane: .background
)
let foreground = try AtmosphericEffectView(
    configuration: configuration, surface: .navigationBar(geometry), renderPlane: .foreground
)
// Parent installs background below icons/text and foreground above them, then supplies frame/state.
```

- Background draws **only** unconditional navbar frost wash and optional selected-tab fill.
- Foreground draws style decoration, optional selected-tab rim, and sparkles; it does **not** redraw wash/fill.
- Generic navbar sparks exist only in style 3; styles 0/1/2 have no generic glass glow sparks. Selected fill/rim/two sparks depend on `navbarActiveGlow` and a visible selected geometry.
- Both passes receive one shared-clock sample per native display tick. Source L2249–2353 / inspector §6.4:
  - Fill RGB `(130,210,255)`, `int((dark ? 34 : 42) * (.72 + .28*sin(t*2.3)))`, half-minimum selected radius.
  - Rim selected rect inset `.6`, width `1.05`, RGB `(175,226,255)`, alpha `int(115*(.65 + .35*sin(t*2.3)))`.
  - Upper-right spark `(maxX-7,minY+7)`, size `3`, RGB `(235,248,255)`, alpha `int(210*(.725 + .275*sin(t*3.1)))`.
  - Lower-left spark `(minX+8,maxY-7)`, size `2.2`, RGB `(255,232,170)`, alpha `int(170*(.725 + .275*sin(t*2.7+1.9)))`.
  - Spark sprite alpha follows source 16-level quantization; host target opacity is separate. Frequencies are **radians/second**, not Hz.

Use the same separation for glass wash where it must precede content. Profile actions/avatar/cards are foreground decoration with no interior wash.

## Source-derived rendering and host obligations

- Native particles preserve source 48/34/18% layer selection, associated radius/speed/sway/alpha ranges, 128-entry sine lookup, gust/layer factors, spin, respawn/wrapping, 7% top/88% bottom fades, layer shimmer, eight snow alpha buckets, and six 10-degree crystal rotation buckets. The particle array is not depth-sorted. Counts are fixed **26/50/82 per snow view**, never area-normalized.
- Snow style 0 is grain layer 0 plus bokeh layers 1/2; style 1 is grain layer 0 plus crystals layers 1/2; style 2 uses crystal flags and **grain for noncrystals, never bokeh**. Size affects drawing radius only; speed affects vertical motion only; calm retains sway.
- Shared festive style 0 has rim/cap/static wire/bulbs; style 1 rim/cap/icicles/highlights (avatar has no icicles); style 2 wire/static bulbs with **no pill frost rim**, but **retains the avatar's cold ring** and honors every palette; style 3 rim/animated sparks, **no moving aurora field**. Style-3 sparks survive glow off. Thin actions/cards omit extra glow sparks but retain style-3 sparks. Garlands never blink.
- Avatar fade is `clamp((.55-expansionProgress)/.35,0,1)` (full through `.20`, absent at `.55`). Story inset uses `floor(3.5*displayScale)/displayScale * (1-expansionProgress) * insetProgress * (1-foregroundAlpha)`, normalized/rounded into a 96-point reference ring; final alpha must exceed `.04` and effective outer radius be at least 18.
- Action fade is `clamp((expansionFraction-.68)/.32,0,1)`, with fade `>.05`, scale `>.25`, final target alpha `>.04`, clip intersection at least `12x14`, and supplied bottom clip allowing at least 65% height. Reference shrink hides at min actual/reference ratio `<=.68`; reference transforms use actual/reference times action scale when scale `<.999` or dimensions `<.98` reference. Without a reference, action scale is a visibility gate, not an extra transform. The host owns remembering fully expanded reference sizes, deleted/text/background/header-scroll/expanded-avatar suppression and effective source alpha.
- Card grouping, qualifying section ownership, exclusions, translation, first-child group alpha, and recycling state belong to the parent, as specified in inspector §9. Supply top/bottom flags for partially clipped groups (source thresholds top `>=-36`, bottom `<=listHeight+24`), actual radius, alpha, and clip. The backend never scans a list or draws every row as a card.
- `visibility.opacity` is additional drawable/action alpha, **not** alpha already applied to the overlay by UIKit. The renderer applies fade itself; do not pre-multiply avatar/action expansion fade again. Supply host-specific suppression via `visibility.isVisible`/host state. `drawsTopDecoration` suppresses cap/garland, `drawsBottomDecoration` suppresses icicles; rim/style-3 sparks remain subject to clip. Nil `clampsTopEdge` uses `rect.minY<=1.8`; crossing that threshold changes real static geometry.
- Parent must update local rectangles/clip/alpha/expansion during layout, scroll, reuse, and transitions; explicitly refresh visibility after ancestor hidden/alpha/clipping/transform changes **including re-show**. Allocate overlay bounds large enough for cap/aura/icicle overhang where intended. Unsupported non-rounded geometry needs a bridge error, not a guessed fallback.
- Parent must deduplicate ownership: one eligible root snow overlay, one navbar view per plane, one glass target per owner, and one action/card per actual target. Do not redecorate navbar or profile-action backgrounds through a generic glass adapter, even when their own feature switch is off. Profile tabs belong to glass; actions/avatar/cards belong to profile.

## Lifecycle, cache policy, and explicit native differences

- One main-run-loop `.common` `CADisplayLink` is shared by weak view registrations. Requested cadence is **30**, not measured FPS. Elapsed advances once per tick; delta is clamped to `0...0.05`. No Python, JSON, persistence, path/gradient/color/sprite construction, or image resizing occurs in the display-link callback.
- Animation requires an enabled/visible target, positive view bounds, attached window, foreground-active scene, visible ancestor chain/clipping, active application, and full-motion policy. Actual decorated bounds are checked and the surviving rectangle is propagated through ancestor clips, so an offscreen or cumulatively clipped target does not keep a viewport overlay animating. Rotated bounds remain conservative rectangles; custom masks and occlusion require explicit host visibility suppression. Hidden/window-detached/disabled/reduced/static targets are not kept in a polling link. Ancestor walks fail closed beyond 128 levels.
- A dormant **weak** event registry handles app/scene/accessibility changes without a background polling timer. `.system` follows Reduce Motion; `.reduced` freezes current particles/shimmer/pulses but preserves static decoration; `.full` explicitly overrides it. Resume does not simulate missed physics time; decorated phase re-synchronizes with the common clock.
- UUID registration identity and a lifetime cleanup token prevent delayed deinit cleanup from removing a different view at a reused memory address. Link/proxy/clock/view references do not form a view-retaining cycle. `invalidate()` revokes the view immediately; parent generation checks remain mandatory for parent-owned callbacks.
- Each view retains **one last immutable festive body and one last selected-tab geometry**, not a historical geometry dictionary. Body keys cover canonical size/radius/circle classification, style/material/palette/theme as relevant, native scale, wash, thin/rim/edge/clamp inputs, and plane; they exclude origin, opacity, clip, and fade. Presentation-only updates reuse paths/bitmaps. Avatar key uses rounded reference inset/style/palette/scale/plane; no-stories expansion/resize updates only fade/transform. Selected-tab translation/opacity are separate from cached paths. Crossing resolved clamp/inset buckets or changing actual size/material legitimately rebuilds the last variant.
- Static raster batches are capped at 2048 per dimension and 1,048,576 pixels (**4 MiB RGBA per batch**); larger/tall shapes draw cached vector commands instead. Sprites cover the fixed five snow RGB variants, ten palette bulb colors, and four sparkle colors; snow atlas storage is capped at five variants. The last observed view's teardown purges shared sprite-cache ownership. Invalidating clears the per-view body/tab/atlas/particle references.
- Android dp-like lengths/speeds map to UIKit **points**, not all to screen pixels. Raw-pixel optimizations are explicitly adapted: resize threshold `80/displayScale` points, snow diameters in 4-native-pixel buckets capped at 64 pixels, thin body sizes snapped to 8x4 native-pixel units. Avatar uses a 96-point reference; tall decorations use 140-point reference geometry, with actual-height rim/bottom placement.
- SplitMix64 gives injectable/reproducible **native** seeds; it is not Python's unseeded Mersenne Twister stream. Particle positions/random sequences are not claimed identical.
- CoreGraphics rasterization, gradients, premultiplication, filtering, and color-space behavior differ from Android Canvas/Paint/LightingColorFilter. Sprites are generated natively, not imported Android textures; no byte/pixel equivalence is claimed.
- Native updates are immediate and typed, without Android's `.40s` settings polling, `.25s` stale area cache, private-class scans, or broken/limited backup paths. Actual host registration/geometry is still entirely parent work. There is no promised automatic action/avatar discovery/fallback.
- Native scheduling deliberately replaces nonuniform Android draw-trigger intervals (including cards with no periodic invalidation) with a visible shared clock. Background/foreground navbar samples are synchronized; Android pre-draw reads existing elapsed before post-draw advances it. These timing choices require future recorded-frame review.
- Native static baking is immediate and bounded, not Android third-hit/global `.015s` bake budgeting or height-less strip-cache sharing. Top/bottom flags and clip are honored consistently; source unbaked/full-bitmap branches sometimes ignore edge flags, and tall thin rims differ before/after baking. This implementation uses the documented steady-state rim/bottom intent rather than recreating those cache artifacts. Visual/tall-strip equivalence is **unverified**.

## Verification handoff — all native acceptance remains pending

### Parent integration seam

`AyuPluginBridge/Integration/AyuAtmosphericPluginAdapter.swift` selects this backend only for the source SHA-256 above, owns the original preference namespace and exact migration, and rejects stale settings generations. `AyuAtmosphericRendering.swift` translates the typed settings/surfaces, supplies Telegram theme overrides and two navbar planes, reports graphics/geometry errors, and terminally invalidates views on disable. `AyuAtmosphericHost` owns weak registrations, frames and generation revocation; `AyuAtmosphericUI` carries actual UI-owner lifecycle events. Non-snow canvases include bounded 12-point overhang for icicles/caps/halos instead of clipping at the target pill edge. The original attachment is not a repository resource and is never executed by this route.

Source inventory and static settings/wiring checks are not compilation, test execution or recorded-frame acceptance. These remain separate requirements even after publication and a successful IPA build.

Written tests cover defaults/every preset, primitive coercion and unsupported values, v1/future-marker migration, independent area semantics, bounded/deterministic simulation and numeric motion equations, fade/sprite/alpha/diameter choices, resize/clamped time, presentation/cache reuse, navbar plane partition, style-3 glow-off behavior, static garlands/style-2 cold ring, geometry caps, touch/frame ownership, actual-target/cumulative-clip visibility, reduced motion/window removal, weak view ownership, and terminal invalidation. **They have not been compiled or run.**

Parent acceptance must still include:

1. Actual iOS compilation/type-checking with the target SDK/language/deployment settings and explicit build/test targets.
2. Source-only bridge/settings/import validation without executing the attachment; unsupported geometry/API reporting and namespace-only persistence.
3. Real host attachments, lifecycle/generation revocation, owner deduplication, and correct pre/post content layering.
4. Native test execution and recorded frames on real app surfaces: all snow/festive styles/palettes/themes, selected-tab pulses, tall 520 input, avatar story/expansion fade, action transforms/clipping, grouped-card scrolling/reuse, feature switches, Reduce Motion, scene/app backgrounding, and unload.

No checkbox for compilation, tests, app integration, recorded frames, visual parity, animation smoothness, or measured performance is closed by the presence of this source module.
