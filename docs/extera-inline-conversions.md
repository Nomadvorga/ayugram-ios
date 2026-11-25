# Native inline calculator and conversions

The existing `ExteraMathEngine.suggestion(in:caret:options:)` composer path now
understands base conversion, measures/temperatures, durations, time zones and
currencies. The production parser evaluates typed operands, rejects mismatched
dimensions and never evaluates code. Currency results require dated real rates;
the engine emits a non-insertable pending suggestion when those rates are absent.

Source: exteraGram Android `com/exteragram/messenger/inline/` at reference commit
`b4d852f48f2734a0bee1a74a0939be621612262a`,
particularly `math/{MathExpression,MathOperators,MathUnit,MathFormat}.kt`,
`units/Measures.kt`, `time/TimeZones.kt`, `rates/{Currencies,CurrencyRates}.kt`,
`InlineRates.kt` and `utils/network/ExchangeRates.java`. Copyright exteraGram,
2022–2026; GPL-3.0-or-later and upstream additional terms. See the existing
`docs/third-party` attribution materials. This is native app code, with no plugin
or expression-runtime dependency.

## Composer integration

`ChatInterfaceInputContextPanels.swift` gates the factory on `inlineResults`
(with its recording/commands/selection guards) and passes independent feature
switches into options, equivalent to:

```swift
let settings = ExteraMathSettings.shared
let options = ExteraMathEngine.Options(
    degrees: settings.inlineAngleUnit == .degrees,
    grouping: settings.inlineDigitGrouping,
    decimalSeparator: Locale.current.decimalSeparator ?? ".",
    units: settings.inlineUnits,
    currencies: settings.inlineCurrencies,
    timeZones: settings.inlineTimeZones,
    arithmetic: settings.inlineMathResult,
    imperial: settings.resolvedImperial,
    localCurrency: settings.resolvedTargetCurrency
)
```

The panel uses the same suggestion method, injects a real cached rate snapshot,
and loads the same public Coinbase USD endpoint used by Android only for a valid
currency suggestion. Its request sends no draft, amounts, account identifiers or
requested currency pair. Edits/dismissal cancel URLSession work and clear its
callback; requests time out after 10/15 seconds, reject non-200 responses, and
cap received data at 1 MiB. Snapshots refresh after five minutes, expire after
24 hours and retry failures after at least 30 seconds. Cache is memory-only.
The row displays the fetch timestamp. A failed/unavailable response leaves a
disabled row and never invents a conversion. Copy/insertion excludes the date.

The four Foundation-only engine/unit/zone/rate files remain at their existing
paths. `//submodules/TelegramUI:ExteraMathSources` supplies them to the static
`//Swiftgram/SGMath` module; TelegramUI excludes those four from its own source
glob and imports SGMath. SGSettingsUI also imports SGMath, so the standalone
`exteraInlineSettingsController(context:)` runs its help examples with the same
parser and rate cache as the composer. `Options(settings:preview:)` centralizes
preference resolution. The preview flag enables disabled functions for help only;
it retains the user's angle, grouping, currency and measurement choices.

SGMath has no UI dependencies. The graph is TelegramUI → SGSettingsUI → SGMath →
SGSimpleSettings (and TelegramUI → SGMath), without a cycle. SGMath's sources
filegroup is not a dependency on the TelegramUI library. It links inside the
existing TelegramUIFramework. The framework's export-rule CcInfo traversal
includes transitive static archives, so this adds neither a new framework client
nor a new `provided_by_frameworks` entry.

## Settings UI / backup integration needed by their owning sessions

Existing settings properties remain source-compatible. Add these persisted keys
to the backup allowlist/schema and expose their public properties in settings:

| Key | Property | Type/default |
| --- | --- | --- |
| `extera.inlineUnits` | `inlineUnits` | Bool / true |
| `extera.inlineCurrencies` | `inlineCurrencies` | Bool / true |
| `extera.inlineTimeZones` | `inlineTimeZones` | Bool / true |
| `extera.inlineImperial` | `inlineImperial` | Bool / false |
| `extera.inlineTargetCurrency` | `inlineTargetCurrency` | String / `auto` |
| `extera.inlineMeasureSystem` | `inlineMeasureSystem` | String / `auto`, `metric`, `imperial` |

The new measurement key wins over the legacy boolean. On first initialization,
an explicitly stored old true becomes imperial and an explicitly stored false
becomes metric. A fresh installation becomes auto; auto uses the device region's
measurement region: US/LR/MM use imperial, other regions metric, matching Android
`InlineResults.isImperial()` (the UK remains metric). `inlineImperial` remains a source-compatible facade: reads
resolve the new preference and writes select an explicit system. New-system
writes also persist the corresponding old boolean for older clients. Backup
allowlist/schema integration for the new key belongs to the root settings owner.

`resolvedTargetCurrency` resolves `auto` using the current device locale and USD
fallback. Other values are ISO codes, or BTC/ETH/SOL/USDT/GRAM. The setter accepts
3–4 ASCII letters; the engine validates actual supported codes and falls back to
USD. Suggested UI: three feature toggles, measurement system toggle, and target
currency selection with automatic choice. Arithmetic is independently controlled
by `inlineMathResult`; date/time and unit/currency conversions remain available.

Add localization strings (the row currently provides English fallback text):

| Key | English | Russian |
| --- | --- | --- |
| `Extera.Math.LoadingRates` | Loading exchange rates… | Загрузка курсов валют… |
| `Extera.Math.RatesUnavailable` | Exchange rates unavailable | Курсы валют недоступны |

Settings-row keys/titles and description text belong to the settings owner. These
are suggested titles, not additional runtime keys used by this implementation:
Unit conversion / Конвертация единиц; Currency conversion / Конвертация валют;
Time zones / Часовые пояса; Imperial units / Имперские единицы;
Target currency / Целевая валюта; Automatic / Автоматически.

## Supported examples

- `hex(255) =`, `dec(ff, 16) =`, `0xff + 1 =`, `255 to bin =`.
- `5 kg to lb =`, `100 km/h to mph =`, `32°F to °C =`, `1 m² to ft² =`.
- `1 km + 500 m =`, `5 kg / 500 g =`, `12% of 10 kg =`.
- `90 min =`, `2 h + 45 min =`, `90 min to h =`.
- `6pm est =`, `12:00 in tokyo =`, `now in new york =`,
  `12:00 utc+05:30 to utc =`, `12:00 по москве в токио =`.
- `100 dollars to euros =`, `5k ₽ to $ =`, `50$ to GRAM =`.

Measures reproduce Android's scales, metric/imperial implicit counterparts,
Russian unit labels and fixed 30-day month / 365-day year conversions. Aliases
include the upstream English/Russian measure forms and major currency aliases.
Time zones include all upstream built-in city aliases plus IANA identifiers.
Named abbreviations use regional DST rules on today's date, as on Android.

## Limits and verification

Input is limited to 512 UTF-16 units, 256 tokens, 32 parser recursion levels;
suggestion scanning only copies a bounded current-line suffix. Base conversion
requires an integer within ±(2^53−1); accumulation checks overflow before each
digit. Ordinary formatted numbers retain the existing magnitude limits. Units
carry dimensions through arithmetic; products of two measures, mismatched units,
unit powers and dimensional function arguments are rejected. Time-zone parsing
accepts at most 20 words and three-word zone names. It uses Foundation IANA/DST
rules with forward gap resolution and the earlier overlap occurrence.

XCTest cases compile the exact production engine, units, rates and time-zone
sources. See `Tests/ExteraMath/README.md`. No Swift compiler or iOS simulator is
available on this Windows host. Tree-sitter syntax checks do not substitute for
compilation, XCTest execution, a full app build, or recorded-frame UI verification.
The Windows reference-data check passed for 39 units and all 251 built-in zone
aliases; 11 numerical regressions passed using the production unit scales/offsets.
Tree-sitter passed for all math production sources, settings and the XCTest source.

Known remaining Android parity gaps: account-specific Telegram Stars pricing
(XTR is deliberately unsupported rather than assigned a fabricated value),
network-backed arbitrary place lookup, Russian place-name inflection beyond
explicit aliases, Android's permissive expression extraction from prose, some
rare currency aliases and ambiguous currency/measure word disambiguation, and
persistent exchange-rate cache across app launches. A plain unadorned `k` keeps
its arithmetic multiplier meaning; Kelvin is `kelvin` or `°K`. These gaps do not
block the examples above or the existing inline suggestion entry point.
