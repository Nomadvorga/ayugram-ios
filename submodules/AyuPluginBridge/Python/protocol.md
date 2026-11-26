# AyuPluginBridge Python ↔ native protocol v1

## Extensible class adapters (common bridge, first stage)

`AyuBridgeClassRegistry.standard.adding(...)` supplies explicit compiled native
classes to `AyuPluginService`/`AyuPluginNativeHost`. It cannot replace built-in
view, layout, array or proxy classes. Duplicate names, ambiguous members, reserved
reflection names, invalid constants and undeclared writable fields are rejected
when constructing the registry. No Java/JVM, private selector resolution, Java
subclassing or automatic Android API emulation is introduced.

Adapters declare constructors, static/instance methods, explicit read-only dynamic
`staticFields`, constants, readable and
writable fields, and `validateState`. Only declared members are exposed. Hidden
JSON state is not accessible through the private-field helpers. Constructors,
mutations, field writes and factory-created instances all run schema validation,
owned-reference checks and the aggregate `adapterStateBytesPerPlugin` quota
(default 1 MiB). Results additionally obey the response quota. Failed instance
calls roll back state and newly allocated handles. Adapters must be bounded,
side-effect-free synchronous transformations; irreversible app/UI effects belong
in a real application provider, not these closures.

`AyuBridgeAdapterContext` gives typed, read-only snapshots of current-owner
references. It is host-worker-only and generation-scoped; do not retain it or
start threads. Handles/callback tokens remain host-owned. Adapters cannot invent
callback tokens. Atomic classes below provide serial value operations, not plugin
thread support or a Java memory-model guarantee.

`context.callback(reference)` resolves an already registered Python callback on
the host worker and yields a revocable native sender that may be retained by a
native UI action. Sender delivery is asynchronous, generation/ownership checked,
and payload/reference quota validated before reaching the runtime. Never retain
the context itself. `provider.prepareCall` returns `AyuBridgeProviderResult` with
typed value/instance state, `commit(hostOwnedResult)` and `rollback()`: the host
validates and allocates the result before commit, and cancels prepared effects
when validation fails. Providers may not construct wire handles/callback tags.

Implemented **subsets**, not complete Java classes:

| Class | Implemented surface |
|---|---|
| Integer / Long | bounded constructor/valueOf, decimal parseInt/parseLong, toString, intValue, longValue, MIN_VALUE, MAX_VALUE, TYPE |
| Byte / Short | bounded signed 8-/16-bit constructor/valueOf, decimal parseByte/parseShort, toString, byteValue/shortValue/intValue/longValue with Java signed narrowing, MIN_VALUE, MAX_VALUE, TYPE |
| Boolean | bool/string constructor/valueOf, parseBoolean, booleanValue, TYPE |
| String | bounded empty/text/owned BMP `char[]` constructors; `length` (UTF-16 units), `isEmpty`, `toString`, UTF-16 `equals`/`compareTo`/search/prefix/suffix, Java `hashCode`, ASCII `trim`, concatenation, and bounded one-/two-index `substring`; `valueOf` accepts strings, signed integers, booleans and null only. Substring boundaries may not split a surrogate pair. Other constructors, floating-point/object formatting and String APIs reject. |
| Float | finite bounded numeric constructor, `parseFloat`, `valueOf`, `floatValue` and `TYPE`/finite range constants. NaN/infinities, hexadecimal syntax and Java-specific string formatting reject. |
| Object / CharSequence / WeakReference | `Object()` creates an opaque empty value and may use the host-wide `getClass` metadata path; identity/string methods are not emulated. `CharSequence` is a marker interface for exact bounded type checks and object-array components, not a general string API. `WeakReference` accepts null or a typed owned host reference, with `get`, `clear` and always-false `isEnqueued`; it does not retain the handle, but host values live until explicit release or generation cleanup, so Java GC and `ReferenceQueue` behavior are not provided. |
| ColorStateList | `valueOf(int)` creates an immutable single-color ARGB snapshot with `getDefaultColor`, `getColorForState(int[], int)` and `isStateful == false`. State-array constructors, stateful colors and resource/theme lookup reject. |
| SpannableString / SpannableStringBuilder / style spans | Bounded UTF-16 text snapshots with `length`, `toString`, `subSequence`, `setSpan`, `removeSpan`, `getSpanStart`/`getSpanEnd`/`getSpanFlags` and `getSpans` for Object, an exact registered class, or the bounded CharacterStyle/MetricAffectingSpan/UpdateAppearance/UpdateLayout hierarchy. The four standard inclusive/exclusive boundary constants are exposed. The builder also supports one-argument `append`, three-argument `replace` and two-index `delete`; ranges are checked and bounded, partial-overlap spans are removed on replacement, enclosing spans are expanded and following spans shifted. Value-only `StyleSpan`, `UnderlineSpan`, `StrikethroughSpan`, `TypefaceSpan` and `ForegroundColorSpan` expose only their documented constructors/getters. `TextView.setText`/`setHint` and `TextUtils.isEmpty` accept bounded owned String/Spannable values as plain text; span metadata is not sent to the UI or rendered. Telegram-specific spans, layouts, measurement, Android rendering and other overloads reject. |
| ByteArrayOutputStream / Collections | Bounded in-memory byte accumulation (`write(int)`, `write(owned byte[], offset, length)`, `writeBytes(owned byte[])`, `size`, `toByteArray`, `reset`, no-op `flush`/`close`) and read-only `Collections.singletonList`. `toByteArray` returns a Python list of signed byte values, not an owned Java `byte[]`; ordinary Python lists are not accepted as Java `byte[]` arguments. File/network streams, `writeTo`, formatting and other collection factories reject. |
| URL / URLEncoder | `URL` parses bounded absolute HTTP(S) values without opening them; selected protocol/host/authority/port/path/query/ref/file getters and string forms only. User-info, other schemes and network methods reject. `URLEncoder.encode` supports bounded UTF-8 form encoding only. |
| Scanner | Bounded in-memory text only, with ASCII-whitespace tokenization, `next`/`hasNext`, line reads, booleans and signed int/long reads. Files, streams, URLs, custom regex delimiters/locales/radices, floating-point parsing and resource APIs reject. |
| ArrayList | empty/capacity/array/list constructor, size, isEmpty, clear, get, set, add, addAll, remove, contains, indexOf, toArray; Python length/indexing |
| `java.lang.reflect.Array` | Bounded one-dimensional arrays of declared primitive or registered object/interface components. `newInstance(Class, length)` creates default-valued arrays; `getLength`, `get` and `set` access owned arrays with component validation. `getBoolean`/`getByte`/`getChar`/`getShort`/`getInt`/`getLong`/`getFloat`/`getDouble` and matching `set*` methods require an exact primitive component type. Generic `get` returns the bridge's JSON primitive value rather than a boxed Java wrapper. Nested/multidimensional arrays, widening conversions, `void`, non-array targets and unregistered component classes reject. Per-plugin total limits are 65,536 elements and 1 MiB encoded array state; the normal owned-object quota also applies. |
| HashMap | empty constructor, size, isEmpty, clear, containsKey, get, put, remove; typed JSON key/value pairs |
| AtomicLong | empty/value constructor, get, set, getAndSet, incrementAndGet, compareAndSet |
| AtomicBoolean | empty/value constructor, get, set, compareAndSet |
| System | currentTimeMillis, monotonic nanoTime |
| SystemClock | `uptimeMillis()` returns a monotonic millisecond reading suitable for measuring short intervals. It is backed by the iOS process uptime clock; Android boot-time origin and deep-sleep semantics are not promised. No sleep, elapsed-realtime or other overloads are exposed. |
| Resources / Configuration | `Resources.getConfiguration()` returns an owned, read-only visible-screen snapshot; `Configuration.orientation` and `ORIENTATION_UNDEFINED`, `ORIENTATION_PORTRAIT`, `ORIENTATION_LANDSCAPE` only |
| Gravity / TextView / LinearLayout / ScrollView | `Gravity` exposes a bounded subset of left/right/start/end/center/top/bottom constants. `TextView.setGravity`/`getGravity` read and apply text alignment; `LinearLayout.setGravity`/`getGravity` read and apply child-group alignment, and `getOrientation` reads its supported horizontal/vertical value. Basic positive `LinearLayout.LayoutParams` weights divide remaining main-axis space. `ScrollView` and `HorizontalScrollView` each own one direct child in a bounded, single-axis `UIScrollView` backing and support their documented fill-viewport flags. Per-child gravity, nested scrolling and Android fling physics are unsupported; clipping is limited to the View APIs documented below. |
| ProgressBar / CheckBox | `ProgressBar(Context)` maps the audited indeterminate subset to a native activity indicator; `ProgressBar(Context, null, 0x01010078)` maps the audited horizontal subset to a native progress view. The horizontal form supports bounded `setMax`/`getMax`, `setProgress`/`getProgress`, a single-color `ColorStateList.valueOf(int)` or null through `setProgressTintList`, and inherited visibility. The indeterminate form supports visibility only. `CheckBox(Context)` supports plain-text `setText`/`getText`, bounded `setTextSize`/`setTextColor`/`setPadding`, `setChecked`/`isChecked`, a single-color `ColorStateList.valueOf(int)` or null through `setButtonTintList`, and `setOnCheckedChangeListener` with the declared `CompoundButton.OnCheckedChangeListener` proxy. Listener delivery is asynchronous through the generation-owned callback queue. These UIKit controls do not promise Android style, drawable-state, measurement or animation parity; other constructors and overloads reject. |
| ViewConfiguration / haptics | `ViewConfiguration.get(owned Context)` returns a value adapter whose `getScaledTouchSlop()` is a fixed 8 native points; `getLongPressTimeout()` is a fixed 500 ms. These are bounded iOS-side values, not Android density, device-setting or timing parity. `View.performHapticFeedback(int)` accepts only the audited `LONG_PRESS` (0) and `CLOCK_TICK` (4) constants and queues UIKit impact/selection feedback; `true` means the request was accepted into the bounded native UI queue, not that hardware produced a sensation. Other constants, flags and overloads reject. |
| View.MeasureSpec | The static `MODE_SHIFT`, `MODE_MASK`, `UNSPECIFIED`, `EXACTLY` and `AT_MOST` constants plus `makeMeasureSpec(size, mode)`, `getMode(spec)` and `getSize(spec)` use signed 32-bit Android bit layouts. Sizes are restricted to the nonnegative 30-bit range and modes to the three standard values. This is a pure integer adapter; it does not implement `View.measure()` or Android layout traversal. |
| Color / ColorDrawable / GradientDrawable / View background | `Color` supports bounded `argb`, `rgb`, `parseColor` (Android named colors and `#RRGGBB`/`#AARRGGBB`), `HSVToColor`, `alpha`/`red`/`green`/`blue` and common color constants. `ColorDrawable` supports a bounded color-only constructor, `getColor` and `setColor`, preserving signed Java ARGB values. `GradientDrawable` supports solid rectangle/oval color, one corner radius and an optional uniform stroke. `View.setBackground` accepts an owned `ColorDrawable`, supported `GradientDrawable` or `null` and maps it to the native view. `View.getBackground` returns the live owned drawable when available, a validated ColorDrawable/GradientDrawable snapshot for a bounded background mutation, or null when absent. Gradients, per-corner radii, ripple/layer/resource/image drawables and Canvas rendering are unsupported. |
| Bundle / Intent / Uri / MotionEvent / Handler | Bounded local `Bundle` and `Intent` value containers, `Uri.parse` plus common read-only URI components, synthetic `MotionEvent` value snapshots, and `Handler.post`/`postDelayed` delivery through revocable callbacks. `Intent` does not launch OS activities; URI parsing does not open links or access the network; handler cancellation and Android queue/looper parity are unsupported. |
| ByteBuffer | `wrap(owned byte[])` copies at most 4,096 signed bytes into an owned cursor supporting capacity/position/limit, remaining/hasRemaining, relative and absolute byte get/put, flip/rewind/clear/mark/reset. Mutators return the same owned buffer handle. Slice/offset overloads, byte-order views, primitive reads/writes and returning a Java backing array are unsupported. |
| Rect / RectF | Bounded zero/four-coordinate constructors, mutable `left`/`top`/`right`/`bottom`, same-class `set`, `setEmpty`, `offset`, `offsetTo`, `inset`, `contains`, `intersect`, `union`, `sort`, `width`/`height`, `centerX`/`centerY`, `exactCenterX`/`exactCenterY` and `isEmpty`; `Rect` coordinates use signed 32-bit arithmetic, `RectF` values are finite bounded IEEE-754 single-precision coordinates. Cross-class conversions and Canvas/Bitmap drawing remain unsupported. |
| Paint | Bounded flags (`ANTI_ALIAS_FLAG`, `FILTER_BITMAP_FLAG`, `DITHER_FLAG`), color/alpha including `setARGB(a,r,g,b)` with 0–255 channels, stroke width/style/cap/join, text size, flag getters/setters, reset and same-class copy; `Paint.Style`, `Paint.Cap` and `Paint.Join` expose only their named enum constants. This is value-state only: Canvas rendering, shaders, paths, font metrics and other Paint APIs remain unsupported. |
| Path | Bounded command values for `moveTo`, `lineTo` (including the Java implicit origin), `close`, `reset`, `rewind`, `isEmpty` and same-class copy. Coordinates are finite and bounded, with at most 1,024 commands. Canvas rendering, curves, transforms, fill types and other Path overloads remain unsupported. |
| Matrix | Bounded 3×3 single-precision affine values with identity/copy/reset, `setScale`/`setTranslate`, and two-axis `preScale`/`postScale`/`preTranslate`/`postTranslate` plus `isIdentity`. Pivot overloads, perspective helpers, array-mutating maps, Canvas integration and other Matrix APIs remain unsupported. |
| TextView / EditText / ImageView | `TextView.setTextSize(size)` and `(COMPLEX_UNIT_PX|DIP|SP, size)` accept finite 1-256 values; PX is divided by the visible native screen scale, DIP uses points, and SP uses `UIFontMetrics` dynamic type scaling (not Android font-scale parity). `TextView.setText`/`setHint` accept bounded wire strings and owned `java.lang.String`/Spannable values, flattening them to plain text without Android span rendering. `TextView`/`EditText` support `addTextChangedListener`/`removeTextChangedListener` for owned `TextWatcher` proxies (up to eight registrations per view). For each edit, all registered `beforeTextChanged` callbacks run in registration order, followed by all `onTextChanged`, then all `afterTextChanged`; delivery is asynchronous and subject to the host callback queue bound. Snapshots are bounded plain strings; edit offsets/counts use UTF-16 units and the computed changed range never splits a Unicode scalar. Text input is capped at 65,536 UTF-8 bytes. `EditText.requestFocus()` reports true only when the attached, enabled native field becomes first responder; `hasFocus()` reports native first-responder state and `clearFocus()` resigns it. `EditText.setSelection(int)` positions a collapsed selection at a validated UTF-16 offset in its current text; `getSelectionStart()`/`getSelectionEnd()` read the native text-field selection or return -1 when unavailable. Other selection overloads and TextView selection reject. `EditText.setTypeface` follows the supported TextView subset. `EditText.setInputType` maps plain-text, password and no-suggestions flags; multiline is explicitly unsupported because the backing control is a single-line `UITextField`. `ImageButton` exposes this same bounded image subset and base View click behavior, but does not reproduce Android button chrome. `ImageView.ScaleType` supports `CENTER`, `FIT_XY`, `FIT_CENTER`, `CENTER_INSIDE`, `CENTER_CROP` and identity-only `MATRIX` mapped to the corresponding UIKit content mode; arbitrary image matrices are unsupported. `setColorFilter(int)`, `setColorFilter(int, PorterDuff.Mode)` and `setColorFilter(PorterDuffColorFilter)` support bounded ARGB colors with `PorterDuff.Mode.SRC_IN`; `getColorFilter` returns an owned filter snapshot or null, and `clearColorFilter` removes the tint. `setImageDrawable(null)` and `setImageResource(0)` clear an image; non-null drawables and nonzero resource IDs reject because no Android resource resolver is provided. Other Porter-Duff modes, bitmap and drawable/resource loading semantics remain unsupported. |
| TextUtils | `TextUtils.isEmpty` supports null, bounded wire strings and owned `java.lang.String`/Spannable values, inspecting only their bounded plain-text content. Other `CharSequence` implementations reject. |
| View / ViewGroup child order | `View.setContentDescription`/`getContentDescription` map bounded text to native accessibility labels; null clears the label. `isShown()` walks the native view's ancestor visibility; `isAttachedToWindow()` and the four padding getters read native view state. `getId()`/`setId(int)` preserve a signed 32-bit view ID (default `-1`); `findViewById(int)` searches the supported modeled subtree depth-first, including the receiver, and returns null when absent. `getMinimumWidth()`/`getMinimumHeight()` and their setters map to a bounded 0-100,000 native-point intrinsic-size floor; this is not Android density conversion. `setRotation(float)`/`getRotation()` apply/read a bounded degree value on the native view transform; `getScaleX()`/`getScaleY()` read the bounded view transform scale. `invalidate()` requests native redraw only; it does not provide Android Canvas drawing. `getParent()` returns an owned supported container or null when unparented; a root attached to the host mount has no modeled Android parent and rejects. `getRootView()` returns the top supported modeled view, treating a host-mounted root as its own Android root. `getTag()`/`setTag(Object)` support one bounded default tag containing null, JSON scalar values or a supported owned value/view handle; keyed tags, raw containers, proxy callbacks, reflection and class handles reject. `getChildCount()`/`getChildAt(index)` preserve bounded child order; out-of-range child lookup returns null. `getLayoutParams()` returns the owned object previously assigned or supplied to `addView` when it is still live, otherwise a new owned snapshot of the last known values; it returns null if no params are known. `setClickable(boolean)`/`isClickable()` expose the bounded clickability state; the setter gates the owned click callback, while `setOnClickListener` makes the view clickable. Touch-listener delivery remains separate. `post(Runnable)` and `postDelayed(Runnable, delayMs)` enqueue bounded, one-shot callbacks and return true when accepted; delivery remains asynchronous on the plugin callback queue and is revoked on generation unload. Delays are limited to 0–60,000 ms; Android Looper affinity, cancellation and frame timing are unsupported. `requestLayout()` queues a bounded host layout invalidation. `View` and supported Frame/Linear/Scroll containers have bounded subtype checks for casts and typed arrays; `ViewParent` and `ViewGroup` accept only those three containers. `ViewGroup.addView(child)`, `(child, index)`, `(child, layoutParams)`, and `(child, index, layoutParams)` use bounded child counts and current-parent indices; `-1` means append. Removing, releasing or unmounting a child updates parent/child snapshots; `bringToFront()` moves a nested child to the end of its parent's child order. Other overloads/params reject. |
| View elevation / clipping | `setElevation(float)`/`getElevation()` map a bounded nonnegative 0–100,000 native-point value to UIKit layer z-order; Android shadow rendering and density conversion are not provided. `FrameLayout`/`LinearLayout.setClipChildren(boolean)`/`getClipChildren()` map to native child-container clipping. `ViewOutlineProvider.BACKGROUND` and null are the only accepted outline providers; `getOutlineProvider()` returns the bounded marker. `setClipToOutline(boolean)`/`getClipToOutline()` track the requested state and clip only when the background provider and a supported ColorDrawable/GradientDrawable outline exist (rect, rounded rect or oval); background-less views have no clip path. ScrollView child clipping remains controlled by its viewport. |
| View Context | View construction accepts no argument, null or an owned `android.content.Context` adapter. `getContext()` returns that retained context or null. `getResources()` forwards only a read-only `android.content.res.Resources` result from the registered Context adapter and reuses a view-owned handle; contextless views and unsupported Context adapters fail explicitly. Context and cached Resources handles cannot be released while a live view retains them. Other Android Context methods remain unsupported. |
| Class | `Class.forName(name)` returns a class handle only for exact class names already registered by this host. Metadata is limited to name/simple name/package, primitive/array/interface/enum flags and registered array component type. `getDeclaredMethod(s)` returns name-only metadata for explicitly exposed members, without signatures or invocation; inherited members and arbitrary JVM/app reflection are unsupported. |
| AndroidUtilities | `dp(float)` accepts one finite value within ±100,000, uses density 1 in native UIKit points, applies `ceil` and returns an integer; `dpf2(float)` returns the unchanged fractional value in points. Neither multiplies by the physical screen scale. `runOnUIThread(Runnable[, delayMs])` schedules a one-shot callback on the serial Python queue with an optional 0–60,000 ms delay. `addToClipboard(text)` aliases the bounded application clipboard-write route and requires the currently visible owned screen context. Cancellation and Looper/thread affinity are unsupported; Python never runs on UIKit's main thread. |
| LocaleController | `getInstance()`, `isRTL()`, `getCurrentLocale()` and `getCurrentLocaleInfo().pluralLangCode` read Telegram's current presentation-language snapshot when bound by the app, with system locale fallback; the locale-info object is immutable and exposes only that read-only field. Android per-account locale overrides and localized-resource lookup are unsupported. |
| Browser | `openUrl(context, url)` queues only absolute HTTP(S) URLs or owned `android.net.Uri` values through the currently bound Telegram navigation route; non-web schemes, other overloads and external-launch behavior reject. |

The View transform subset also supports bounded rotation X/Y, pivot X/Y and positive camera distance in addition to rotation Z, scale and translation. Pivots are local coordinates; the host preserves parent-owned frame and anchor-point layout. UIKit 3D-layer output is not Android rendering parity.

The animation subset is deliberately split from frame callbacks. `LinearInterpolator`,
`DecelerateInterpolator` and `OvershootInterpolator` expose bounded constructors and
`getInterpolation(float)` as pure value adapters. `View.animate()` returns an owned
`ViewPropertyAnimator` descriptor supporting the audited alpha/translation/scale/
rotation-Z/X/Y setters, duration/start-delay, those three interpolators, `withEndAction`,
`start` and `cancel`. UIKit performs the animation natively; Python is never called
per frame. Custom `TimeInterpolator` proxies, `ValueAnimator` update listeners and
Android timing parity remain unsupported. `ValueAnimator.areAnimatorsEnabled()` is
provided only as a read-only capability for plugins that gate an already-native
animation path.

Primitive descriptors: byte, short, int, long, char, boolean, float, double, void.

`ScrollView` and `HorizontalScrollView` expose single-axis `getScrollX()`/
`getScrollY()`, `scrollTo`, `scrollBy` and `smoothScrollTo`; the cross-axis
coordinate must be zero, offsets are signed 32-bit native points and clamp to
content bounds. `smoothScrollTo` uses UIKit animation without Android timing or
physics parity. Each supports `setFillViewport(boolean)`/`isFillViewport()`;
fill-viewport expands the single child to at least the available viewport extent
on the scrolling axis, accounting for child padding and margins. `ScrollView`
supports vertical scrollbar visibility, while `HorizontalScrollView` supports
horizontal scrollbar visibility. Both accept `setClipToPadding(true)` and
`setOverScrollMode(OVER_SCROLL_NEVER)`. Other overscroll modes, false
clip-to-padding, the opposite-axis scrollbar, smooth-scroll-by, flings, nested
scrolling, Android scroll callbacks and two-axis scrolling remain unsupported.
`View.setFocusable`/`isFocusable` and `setSelected`/`isSelected` preserve bounded
booleans only; UIKit first-responder behavior and Android state-list drawable
rendering are not implied.
`ViewConfiguration` and haptics use only the fixed values and two feedback
constants documented in the table; Android device configuration and haptic
hardware behavior are not emulated.
The ProgressBar and CheckBox surfaces are restricted to the constructors and
members in the table above; indeterminate progress uses a native activity indicator,
and checkbox-change callbacks remain asynchronous and generation-bound.
`View.setBackgroundDrawable` is an alias for `setBackground` and accepts only
the same owned ColorDrawable/GradientDrawable values or `null`.
Arrays support the eight non-void primitives and bounded arrays of a registered
object/interface component, with `java.lang.reflect.Array` providing the documented
one-dimensional operations. Nulls, owned references and the documented wire-string
values for `Object`/`CharSequence`/`String` components are checked; only explicitly
modeled relationships are assignable, including `EditText`/`CheckBox` to `TextView`
and `CheckBox` to `CompoundButton`, alongside the documented `View`/`ViewGroup`,
`CharSequence`/`Spanned` and span-interface relationships. Arbitrary object arrays
and general Java covariance remain unsupported. ArrayList `toArray` returns a
JSON/Python list, not a Java Object[] instance. Collection equality is typed JSON
value/reference equality, not arbitrary Java `equals`/`hashCode`; `remove(integer)`
is the index overload. Non-listed methods/overloads must fail explicitly.

Static SDK inspection now records aliased/qualified class lookups, imported SDK
symbols, missing SDK symbols and computed class-lookup locations before source
activation. This is conservative AST inventory, not full Python name/scope or
runtime compatibility analysis. `android_utils.OnClickListener` forwards through
the declared generation-owned click proxy; `get_static_private_field` exposes
only declared constants/static readers; `get_client` forwards to an owned AccountClient and
does not manufacture a Telegram provider.

The hash-pinned plugin requirements table lives in
`Resources/CommonBridge/compatibility.json` and its README. It records zero
runtime-verified plugins. Atmospheric Snow retains its exact-hash native route;
the other source routes have independent blockers. The shared service has narrow
native account, visible-screen, basic alert/bulletin, generation-bound app-lifecycle,
global account-change notification, clipboard-write and message-context-menu adapters.
See `Resources/CommonBridge/APPLICATION-BRIDGES.md` for exact supported members.
The only notification id is `activeAccountChanged`; observer proxies must be
declared `NotificationCenter$NotificationCenterDelegate` values and delivery is
asynchronous, owner/generation checked and quota-bounded. Only
`MESSAGE_CONTEXT_MENU` is wired; Android MVEL conditions and other menu types
remain unsupported. Theme control, requests/messages, method hooks, graphics
and media remain unsupported. Camera, passcode, screen-capture and destructive-message
features require real iOS adapters respecting platform and account invariants.

Regenerate the static table with `Build/audit-plugin-requirements.py`, supplying
the pinned source manifest and read-only source directory. Never commit the
reference `.plugin` files. Synthetic SDK tests may execute only test-authored
fixtures, never these supplied plugins. Swift test sources are independent of
Python/offline checks and require the authorized native test environment.

This file describes the implemented Python API contract. An adapter not explicitly implemented by the host must fail with `UNSUPPORTED_API`; registration or member lookup must never pretend success. This SDK is not a sandbox for untrusted Python. One interpreter and one native-owned serial Python queue are required; no plugin Python threads may call bridge APIs. UI effects are enqueued on main; main must never synchronously wait for Python. Native callbacks must return to the Python queue after dispatch returns, never re-enter Python inside `_ayu_host.dispatch`.

## Transport and ownership

Injected extension module: `_ayu_host.dispatch(request_json: str) -> response_json: str`.

Request: `{"version":1,"id":"17","plugin_id":"example","operation":"settings.get","arguments":{"key":"enabled","default":false}}`.

Success: `{"version":1,"id":"17","result":false}`.

Failure: `{"version":1,"id":"17","error":{"code":"UNSUPPORTED_API","message":"Adapter is unavailable"}}`.

Response must contain exactly version/id/result or version/id/error. Unknown fields, duplicate JSON keys, mismatched IDs, nonfinite values and malformed reference tags fail. IDs are decimal strings, correlation only. Host MUST use its externally established trusted owner (native TLS), compare request plugin_id with it, and check ownership/generation on every native handle, token and callback. Request plugin_id is not authority. The host must not leak credentials into errors.

`runtime.capabilities` is requested before code execution with request plugin_id `$runtime`; the host may special-case this read-only bootstrap operation when invoked from a native load with a trusted plugin owner. All other operations require exact owner match. Alternatively return the same capability payload under the trusted owner; the Python implementation currently uses the explicit `$runtime` bootstrap ID.

Wire values: null/bool/string/signed-int64/finite-double, arrays, string-keyed objects. Native reference: `{"$handle":"opaque-id","$class":"declared.class.Name"}`. Python callback: `{"$callback":"opaque-generation-bound-id"}`. Java class reference passed as a value: `{"$java_class":"declared.class.Name"}`. Tags are created by SDK objects only. Host return references must name a declared class. Ordinary dictionaries with reserved `$` keys are rejected by the encoder. No raw pointers, native symbol names, arbitrary selectors or dlsym.

## Native-facing Python entry points (ayu_bridge module)

- `inspect_plugin_json(source, filename="plugin.plugin") -> str`: JSON object containing `metadata`, `imports`, `classes`, `requirements`, `warnings`, `sdk_modules`, `python_stdlib_candidates`, `unsupported_imports`. `sdk_modules` lists this SDK's built-in entry modules. `python_stdlib_candidates` is only CPython's potential stdlib inventory, not evidence that an iOS build ships/supports every entry. `unsupported_imports` maps statically observed disallowed imports to explicit reasons (threading/_thread/concurrent/multiprocessing/subprocess/ctypes). Host-declared extra dependencies remain opt-in. AST only; no plugin execution and no host calls. Known threading imports are rejected by load/preflight because plugin threads are not a supported execution model.
- `preflight_plugin_json(source, filename="plugin.plugin") -> str`: inspection report plus `blockers` (`code`, `detail`) for missing SDK members, forbidden imports, undeclared dependencies, native classes, external requirements and declared operations. Uses host capabilities but never authorizes or executes the source. Computed class names add a warning and remain runtime-checked. The application also rejects version constraints until a version policy is implemented. Empty blockers are not proof that arbitrary method calls or all stdlib candidates will work on iOS.
- `load_plugin(source, filename="plugin.plugin", expected_id=None) -> dict`: parses literals, verifies expected ID, obtains capabilities, preflights classes/imports/threading, obtains explicit host authorization, then activates the owned host generation, compiles/executes source in a unique module, constructs exactly one BasePlugin subclass, and calls on_plugin_load. Raises BridgeError on failure and revokes partially registered work.
- `unload_plugin(plugin_id) -> bool`: calls on_plugin_unload then always atomically deactivates native scope and drops callbacks/module. on_plugin_unload may call native APIs, but cannot schedule/register new work. Old callbacks are invalid before unload code starts.
- `serialize_settings(plugin_id) -> str`: JSON array of component descriptors. Callback tags in the current generation remain live until unload (or component callbacks are replaced by a later settings serialization).
- `invoke_callback_json(text) -> str`: accepts `{"version":1,"plugin_id":"example","callback_id":"...","arguments":[...]}`. Returns JSON-encoded callback result (not an RPC response envelope). Host must authenticate owner and callback registration before entry. Inactive/unknown callbacks raise CALLBACK_EXPIRED.
- `emit_event_json(text) -> bool`: accepts `{"version":1,"plugin_id":"example","generation":"<exact load generation>","name":"app","arguments":["RESUME"]}`. Missing/stale generations reject rather than target a newer load. Only app events START/RESUME/PAUSE/STOP are accepted. START is emitted after each successful Python activation; STOP is a background transition, not guaranteed OS termination. Hooks use registered callback IDs instead.

All entry points run on the same queue/thread. WRONG_QUEUE is raised on another thread. Main interpreter execution is not a security isolation boundary; this layer only scopes bridge state, references and callbacks.

Execution module identity is always the unique `_ayu_plugin_<generation>` name registered in sys.modules. The loader rewrites only the top-level literal `__name__` display-metadata assignment (including annotated/chained assignment targets) to `__ayu_display_name__` in the in-memory AST. Parsed metadata and BasePlugin.name retain the original human-readable title. At runtime `__name__` means Python module identity, not display title; this preserves decorators such as dataclass with forward annotations. No sys.modules alias is registered by display title, so two plugins may share a title safely. Subsequent dynamic mutation of runtime __name__ is unsupported and load-rejected when detected.

## Bootstrap, lifecycle, settings and state

| Operation | Arguments | Result |
|---|---|---|
| runtime.capabilities | `{}` | Exact object `{operations:[str], classes:[str], modules:[str], proxy_interfaces:{className:[methodName]}}`; names are explicit supported classes/import dependencies, not arbitrary prefixes |
| plugin.authorize | `{metadata:object, imports:[str], classes:[str], requirements:[str]}` | literal `true` only on approval, otherwise error; MUST validate available dependencies and SDK/app constraints before execution |
| plugin.activate | `{metadata:object, generation:str}` | null on success; native establishes generation before lifecycle registrations |
| plugin.deactivate | `{generation:str}` | null; atomic cleanup barrier: cancel all jobs; unregister hooks, menus, proxies/UI listeners; revoke all handles and callbacks for this owner/generation. Must work even after a failed load before activate |
| settings.get | `{key:str, default:JSON}` | stored value or default; always owner-scoped |
| settings.set | `{key:str, value:JSON, reload_settings:bool}` | null |
| settings.all | `{}` | ordinary JSON dictionary of this owner's settings |
| settings.replace | `{values:object,reload_settings:bool}` | null; validate all keys/values and encoded namespace quota before one owner-scoped write; `{}` clears it |
| state.get | `{key:str, default:JSON}` | transient state value or default, owner-scoped |
| state.set | `{key:str, value:JSON}` | null |
| log.write | `{level:str,message:str}` | null |

Persistent settings belong to plugin ID, transient native state/handles/jobs belong to plugin ID AND generation. Host handles storage type and size limits. Successful writes with `reload_settings=true` enqueue an owner/generation-tagged main-thread notification; settings screens coalesce refreshes and reject stale generations. Metadata literals are parsed without exec. Importing threading or `_thread` is load-rejected: original Music Bridge/Fish files requiring Python threads are therefore not fully compatible yet. No silent thread emulation is implemented.

## Scheduling and callbacks

`scheduler.schedule`: `{queue:str,delay_ms:number,callback:{$callback:str}}` → nonempty opaque token string. Queue `main` means schedule a callback back onto the Python serial queue after main scheduling/host prerequisites, NOT execute Python code on main. UI calls made by that callback go to main asynchronously. Other conventional queue names are pluginsQueue/globalQueue/stageQueue/cacheClearQueue/searchQueue/phoneBookQueue/themeQueue/externalNetworkQueue. Host must reject unsupported queues, not run a Python callback on an arbitrary thread. Jobs are one-shot; a callback cannot fire synchronously inside schedule. `scheduler.cancel`: `{token:str}` → null; cancellation must prevent callback entry if it has not begun.

`hooks.register`: `{kind:str,...config}` → opaque token string. Kinds used by SDK: `send_message`, `request` (name,priority), `java_method` (method native ref, before/after callback tags,priority), `java_all_methods` / `java_all_constructors` (class native value, optional name, before/after tags,priority). Unsupported hook kind/target must error before registering. Hook callback receives host-adapted JSON arguments/native refs. `hooks.unregister`: `{token:str}` → null.

`menus.register`: `{type:str,text:str,on_click:callback,...config}` → opaque token.
Only `MESSAGE_CONTEXT_MENU` is wired to the chat message context menu. Supported
optional fields are `item_id` (string), `icon` (one of the native mapped icon
names), `priority` (signed 32-bit integer), and `condition` (Python callback).
`subtext`, `on_long_click`, MVEL condition strings, and other menu types reject
explicitly. A condition and click callback receive one object containing exact
signed-Int64 `account`, `dialog_id`, and `message_id` values; no Java message or
fragment object is constructed. The native provider retains no adapter context,
rechecks callback generation and current chat before dispatch, bounds
registrations/evaluations, and revokes items on unregister or deactivate.
`menus.unregister`: `{token:str}` → null.

Tokens cannot be shared across owners. Host must not invoke retained callback IDs after cancel/deactivate. Python also checks generation and drops one-shot callbacks on invocation.

## Java facade

`jclass(name)` performs an exact Python-side lookup in capabilities.classes and returns a class facade; it does NOT call `java.class` or load a JVM class. Native reflection objects are ordinary owned references returned by supported methods such as getClass/getDeclaredMethod. Arbitrary reflection targets remain unsupported.

Target formats: static class target `{"class_name":"android.view.View"}` or owned object reference `{"$handle":"...","$class":"..."}`. A Java class used in an argument is the separate `$java_class` tag.

| Operation | Exact arguments | Result |
|---|---|---|
| java.member | `{target:target,name:str}` | `{kind:"method"}`, `{kind:"field",value:wireValue}`, or `{kind:"class",class_name:str}`. Missing/unsupported member → error; never guessed as a method |
| java.construct | `{class_name:str,args:[wireValue],kwargs:object}` | owned native reference; adapter may reject overload/kwargs |
| java.invoke | `{target:target,name:str,args:[wireValue],kwargs:object}` | wireValue; supported explicit methods only |
| java.set_field | `{target:target,name:str,value:wireValue}` | null; readonly/unsupported field → error |
| java.length | `{target:objectRef}` | nonnegative int |
| java.get_item | `{target:objectRef,index:int}` | wireValue |
| java.set_item | `{target:objectRef,index:int,value:wireValue}` | null |
| java.array | `{component:str,values:[wireValue]}` | owned array reference with declared class; component is primitive name or declared Java class |
| java.cast | `{class_name:str,value:wireValue}` | type-checked native reference/value; incompatible type → error |
| java.proxy | `{interfaces:[str],callbacks:{methodName:callbackTag}}` | owned listener reference. Interfaces/method names must come from capabilities.proxy_interfaces |
| java.get_private_field | `{target:objectRef,name:str}` | wireValue, explicitly adapted fields only |
| java.set_private_field | `{target:objectRef,name:str,value:wireValue}` | null, explicitly adapted fields only |

`org.telegram.*`, `android.*`, and `java.*` package imports are provided only if a declared class exists below the package; class access still requires exact registration. Nested classes are returned via `java.member` kind=class, e.g. View.OnClickListener. Native import namespaces may be cached by Python, but class/handle lookup always uses current owner. `jint/jlong/jfloat/jdouble/jboolean/jbyte/jshort/jchar` validate/coerce primitive Python values; arrays are host-owned, not placeholder Python lists. dynamic_proxy only supports explicitly declared interfaces and verifies all required methods when exporting the listener.

## Higher-level helpers

`client.call`: `{name:str,args:[wireValue],kwargs:object}` → wireValue. Implemented Python entry helpers: get_last_fragment, get_messages_controller, get_user_config, get_connections_manager, get_send_messages_helper, get_media_data_controller, get_notification_center, get_account_instance, get_selected_account, send_message, edit_message, send_request, copy_to_clipboard (the route used by `android_utils.copy_to_clipboard`). Native host must explicitly implement each name, preserve account/reply/topic/schedule context and error otherwise. AccountClient adds account to kwargs; no plugin-global mutable current account is stored by the SDK.

`ui.present`: `{kind:"alert"|"bulletin",config:object}` → owned native UI reference or null for a fire-and-forget bulletin. Alert config contains builder setters including on_click callback tags; fluent setters are local descriptor construction, show performs presentation. Only supported options may be accepted by host. Components: `{type:"Header"|"Divider"|"Text"|"Input"|"Switch"|"Selector",...config}` with callbacks encoded as `$callback` values. Host renders native rows, validates setting keys and dispatches changes/clicks through registered callbacks.

## Optional HTTPS requests subset

`requests.py` is bundled compatibility code, not upstream requests or a pip installation. It is deliberately NOT in SDK_MODULES: the host must advertise `requests` in capabilities.modules only when this file, Python ssl/socket/native dependencies and valid trust roots are actually packaged. On iOS the opener explicitly loads checksum-pinned packaged `certifi.where()` through `ssl.create_default_context(cafile=...)`; a missing/invalid trust store fails closed, without disabling verification. Other platforms use system default verification. This compatibility layer is not a network sandbox.

Supported: `request/get/post/put/patch/delete/head/options` at module and per-instance `Session` level, with headers and CookieJar, context manager/close; `get` accepts positional params, `post/put/patch` accept positional data, and `head` defaults to allow_redirects=False (explicit override supported); HTTPS-only absolute URLs without embedded userinfo; params, form/text/bytes data or JSON; headers; positive scalar timeout (default 15 seconds, maximum 60 seconds); allow_redirects bool; stream=False; verify=True. Response exposes status_code, content, text, json(), case-insensitive headers, url, ok and raise_for_status(). urllib HTTP status errors become Response objects; only raise_for_status raises HTTPError for 4xx/5xx. Exceptions namespace includes RequestException, ConnectionError, Timeout, SSLError, HTTPError, InvalidURL, TooManyRedirects, ContentTooLarge, ContentDecodingError, UnsupportedOption, JSONDecodeError. Error messages omit URLs, response bodies and credential values.

Redirects resolve relative paths through urllib; HTTPS→HTTP/nonweb destinations are rejected. Authorization/Proxy-Authorization/Cookie headers are stripped when scheme/host/port origin changes. 307/308 preserve method/body; 301/302/303 use the explicitly implemented requests-style method change. Maximum redirects is five. Transport-controlled Host/Content-Length/Transfer-Encoding overrides are rejected. Bodies are fully buffered with limits of 8 MiB outbound and 16 MiB inbound/decompressed; gzip decoding is bounded, unsupported content encodings error. Accept-Encoding defaults to identity.

Not implemented: streaming/iter_content, multipart/files, auth helpers, custom certificates/verify paths, proxies overrides, retries, per-connect/read tuple timeouts, hooks/adapters, arbitrary requests subpackages or asynchronous cancellation. The shim also checks a monotonic elapsed deadline between redirects and before/after bounded reads. A blocking socket read/open cannot be interrupted by these checks, so this is not a hard total wall timeout. urllib blocks the interpreter queue until completion; UI main must never wait for it. The SDK does not simulate Python threads. This only addresses a dependency import/API subset; supplied Fish/Music plugins still fail the independent threading preflight and other native adapters may be unavailable. SDK callback/load budgets count interpreter-thread CPU time via time.thread_time, so I/O waiting does not consume the 250 ms callback CPU budget. This does not add asynchronous execution or a native watchdog.

## Limits and validation

The source limit is **4 MiB UTF-8**, aligned across the installer, Objective-C load/preflight and Python inspection. Wire request/response limits remain independently bounded; AST depth/node quotas still apply even within the byte limit.

Python bounds: source 4 MiB UTF-8, JSON input 4 million characters, nesting 64, 32 loaded scopes, 4096 callbacks and 1024 registrations per plugin. Native host must separately bound its handles/queues and preserve signed Int64 values. A cooperative `sys.settrace` CPU-time budget uses `time.thread_time` and checks every 64 original-source line events: load 2 CPU seconds, callback/event 250 CPU ms, settings/unload 500 CPU ms. The previous trace is restored. Elapsed wall time and I/O waits are not the budget. This interrupts ordinary Python loops but is catchable and cannot interrupt blocking native/stdlib calls; it is not a hostile-code watchdog or sandbox, and no native watchdog is implemented by this SDK.

No upstream requests/pip installation, Android emulator, arbitrary Java class/member, arbitrary Swift selector, Python native extension loader, unrestricted method hooking, Android Canvas renderer, full Android layout engine, or background-thread compatibility is supplied in these Python files. The optional requests facade above is only its documented subset. Host capabilities must advertise only adapters really implemented. A plugin may pass static inspection and later request a dynamically computed unsupported API: it must then receive an explicit failure. Static inspection is a preflight, not proof of full compatibility or a security sandbox.

Tests in Tests/Python use a fake injected host, test-authored synthetic source and offline source/hash fixtures only. They cover owner isolation, response validation, generation-bound lifecycle events, remote reference round trips, callback lifetime, unload cleanup, enums, undeclared classes and pre-execution rejection. HTTPS fixtures use a fake urllib opener and fake clock; no live service is contacted. No supplied plugin is executed. Offline source wiring and hash checks do not execute Swift, establish native UI behavior or verify device startup. Native integration still requires the authorized iOS test environment and real device/recorded-frame verification.
