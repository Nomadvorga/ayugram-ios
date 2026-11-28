# Other: support, telemetry capability and native account deletion

Prepared implementation: `ExteraOtherSettingsModel.swift`, `ExteraOtherSupportContext.swift`, `ExteraOtherSettingsController.swift` and 12 model XCTest methods. Root integration is provided as **unapplied patches**. No admin files, existing settings controller, localization files, backup files, workflow or BUILD files were edited. No commits or pushes.

## Reference inspected

Both source images were opened individually, including all visible text:

| Frame | Observed content |
| --- | --- |
| `photo_66_2026-11-25_21-26-04.jpg` | Other header; Support (exteraGram), Boosty then Universal; supporter footer; Support (AyuGram), Boosty then Tonkeeper; supporter footer; Google, Crashlytics then Analytics off; two-paragraph telemetry explanation; Export Settings beginning at the bottom. |
| `photo_67_2026-11-25_21-26-04.jpg` | Same scrolled page and fixed Other header; AyuGram support, Google services/explanation; **one final card: Export Settings → Reset Settings → Delete Account**, with deletion red. |

Reports `extera-reference-screens-45-66.md`, `extera-reference-screens-67-87.md` and matrix rows 66/67 were read. Runtime/visual acceptance in the matrix remains pending; the source frames do not prove an iOS result.

Android source HEAD `OtherPreferencesActivity.kt` and `RemoteUtils.java` were inspected with cached `git show`. HEAD has since combined donation sections and added Export Data, so its composition was not copied over the exact screenshot reference. The cached `vanilla-AyuGram-full-20261104.apk` was inspected directly: DEX methods `OtherPreferencesActivity.fillItems`, `getDonates`, `getDonatesAyu`, `handleDonateClick`, plus `RemoteTelegram.fetch`. Its decompiled cache in `C:/Users/PC/ayugram-apk-src` was used to decode the remote channel names and confirm the old support structure.

APK behavior: `donates` supplies exteraGram, `donates_ayu` supplies AyuGram, and `donates_banks` supplies the extera bank selector. Entries use `name#details`; normal URLs use the browser, wallet links use `ton://transfer/address?text=currentAccountId`, unhandled wallet links fall back to copying details. Card routes select bank details when available. Export Data is developer-gated in this APK, and is not in frames 66/67; the existing iOS takeout route remains in Additional Settings.

The decoded APK endpoint `https://update.ayugram.one/rc/current/android` was read to confirm the actual remote schema. It currently contains both reference groups (Boosty/Universal and Boosty/Tonkeeper). **Those current URLs/payment addresses are not compiled into production defaults.** No donation, bot start, channel join, settings reset or account deletion was performed.

## Implementation and exact composition

The new page orders sections as exteraGram support, AyuGram support, Google, the three-action account card, then Additional Settings. The account card consumes the tested `AccountRow.allCases` sequence. Support ordering is deterministic: Boosty → keeper → wallet → card → other names. That matches the visible reference ordering for both groups; Android stores the source in unordered string sets, so arbitrary set iteration is not reproduced.

Each section owns a separate 100-id range; support footers have a fixed id within their range. Loading or losing a catalog cannot reassign the Google/account/additional row identities. The catalog is bounded to 32 entries per project.

The support loader reads the same two pinned channels via native `resolvePeerByName` then `searchMessages` (empty query/history, 50 messages). Resolution must match **both namespace and numeric id**:

| Project | Resolved name | Required channel id |
| --- | --- | --- |
| exteraGram | `XS6GEcz5ZXMu82UvXQc` | `2227431611` |
| AyuGram | `UFhsu4hOFEufes73fkEeuw` | `2180718299` |

Messages are processed oldest first, and only that project's support keys are consumed. Unrelated remote flags cannot enable telemetry, plugins, ads or any other feature. No automatic join, read receipt or bot start is added. Requests are bounded to 12 seconds per source; each project can fail independently. Missing data shows an explanation and Refresh, not invented payment buttons. A failed refresh removes that project's in-memory catalog. There is no new disk cache, backup key or preference.

The engine's history facade has a `NoError` surface; empty/missing config is handled as unavailable. The helper cannot independently attest server freshness of any fallback data returned by that facade. Actual resolution, network behavior and wallet availability still require an authorized runtime check.

## Real action paths

| User action | Result |
| --- | --- |
| Boosty / Universal / HTTPS entry | In-app confirmation displays the complete destination. Open uses native `sharedContext.openExternalUrl`, preserving Telegram URL, bot and mini-app gates. |
| Tonkeeper / wallet | Validate raw TON workchain/address or friendly TON checksum. Confirm the address and current account ID sent as comment; open `ton://transfer` with **no amount**. Wallet handles final payment review/confirmation. If opening fails, offer Copy Address; clipboard is written only after that explicit tap. |
| Extera Card with bank data | Native action sheet lists remote banks, then shows their full details in an explicit copy confirmation. Without banks, use the plain details copy flow. |
| Export Settings | Calls the **existing** `ExteraBackupActions.perform(.exportSettings)` through root's retained bridge; same JSON schema, shared preferences, protected temporary file, activity sheet and cleanup. |
| Reset Settings | Calls the **existing** `.resetSettings` path; same confirmation, strict reset scope, native shared transactions and errors. The new page never calls reset directly. |
| Delete Account | In-app Continue confirmation names the current account ID. Only Continue fetches live `twoStepVerificationConfiguration`. Only a successful response constructs `TwoStepVerificationAccessConfiguration` and opens native `deleteAccountOptionsController`. |
| Additional Settings | Opens the previous Other category with `showOverview:false`. Existing browser/profile/story/feed/data/takeout/backup-import/source settings remain accessible. |

Delete refuses frozen accounts, ignores duplicate requests, publishes loading feedback, times out with Retry, and checks that the original page/navigation still exists before pushing. Unknown state **does not default to no password**. The native options/data flow retains its privacy/security alternatives, phone/password checks, cancel/back behavior and final server RPC. The helper never calls `engine.auth.deleteAccount`, sends a deletion reason, logs out, or changes the account removal timer. Opening this page alone never constructs a deletion/security controller.

## Explicit iOS adaptations

No Firebase Analytics/Crashlytics collection dependency or collector consumer was found in the iOS build graph. Their ordered Google rows show **Not included**, disabled with no toggle. The explanation is specific to this build and does not claim control over native Telegram service logs or Apple diagnostics. It does not promise deletion of previously uploaded data. An Android Boolean preference without a collector would be fake behavior; none is added or exported.

The supporter footer directs the user to each project's actual payment-page terms. This port does not grant a badge, fetch/forge a supporter count, or promise an iOS badge backend that has not been implemented. Native SF Symbols stand in for Android payment artwork. The shared SG extera rows supply support/actions, while the two unavailable service rows use native disabled ItemList disclosure items. Pixel parity, joins between row styles, Dynamic Type and animations are unverified until recorded frames are evaluated.

An explicit Refresh Support Options row appears only when a catalog is missing/empty; it does not add a row to the successful reference composition. A final Additional Settings link preserves existing iOS extras. The main export/reset/delete card remains in reference order. No settings/security/data screen opens automatically after screen construction.

## Root integration

```sh
git apply --check docs/integration/extera-other-root.patch
git apply --check docs/integration/extera-other-enru.patch
git apply docs/integration/extera-other-root.patch
git apply docs/integration/extera-other-enru.patch
```

The root patch adds a `.other && showOverview` branch in `sgSettingsController`, a small retained `exteraOtherBackupAction` wrapper **inside** `ExteraBackupController.swift` (so its private types stay private), and one CI host test step. The wrapper exposes only export/reset actions and reuses their existing implementation. The backup serializer/model is not patched. The EN/RU patch adds 21 matching keys. Existing native destination strings and existing Export/Reset/Other keys are reused.

The backup bridge API is `(ViewController, ExteraOtherSettingsModel.SettingsAction) -> Void`. The page owns the closure; it retains one existing `ExteraBackupActions` instance whose presenter reference remains weak. The only action cases are `.exportSettings` and `.resetSettings`.

The native delete signature was checked directly in `submodules/SettingsUI/Sources/DeleteAccountOptionsController.swift`: `public func deleteAccountOptionsController(context: AccountContext, navigationController: NavigationController, hasTwoStepAuth: Bool, twoStepAuthData: TwoStepVerificationAccessConfiguration?) -> ViewController`. The access configuration's public initializer was checked in `TwoStepVerificationUnlockController.swift`. Neither API needs a framework change.

UIKit action handlers use `exteraOtherAfterAlertAction` for confirmations **and** the bank sheet. It queues work on the next main turn after UIKit starts automatic dismissal, registers for the active transition's completion, and executes directly when dismissal has no animated coordinator or the coordinator declines registration. A once gate prevents duplicate execution. It never relies on a second `alert.dismiss(completion:)` during UIKit auto-dismissal. Confirmed export/reset handlers remain owned by the existing backup implementation. Actual Reduce Motion/animated-dismiss behavior still needs the frame tests below.

All imports are existing SGSettingsUI dependency edges; source globs include the three new production files. No BUILD change is required. No new persisted preferences means **no strict backup schema/default/reset additions**. Admin and optional-author files remain frozen and isolated.

Exact SGSettingsUI imports used: AccountContext, Display, ItemListUI, SGItemListUI, SGSimpleSettings, SGStrings, SettingsUI, SwiftSignalKit, TelegramCore, TelegramPresentationData, plus system Foundation/UIKit. All ten module imports are already direct `AyuGram/SGSettingsUI/BUILD` dependencies. The pure model imports only Foundation and is included by SGSimpleSettings's existing source glob.

## Freeze manifest for root

Integrate these new files together with the two patches; no other current-wave files are required:

| Path | Role |
| --- | --- |
| `AyuGram/SGSimpleSettings/Sources/ExteraOtherSettingsModel.swift` | Pure composition/capability/support parser and destination policy |
| `AyuGram/SGSettingsUI/Sources/ExteraOtherSupportContext.swift` | Pinned native Telegram support catalog loader |
| `AyuGram/SGSettingsUI/Sources/ExteraOtherSettingsController.swift` | Reference composition, real actions, confirmation and native deletion entry |
| `Tests/ExteraOther/ExteraOtherSettingsModelTests.swift` | 12 host test methods |
| `Tests/ExteraOther/verify_swift_syntax.py` | Four-file syntax verification |
| `Tests/ExteraOther/README.md` | Exact host/syntax commands and boundaries |
| `docs/extera-other-settings.md` | This handoff and visual expectations |
| `docs/integration/extera-other-root.patch` | Root routing + backup bridge + CI step, unapplied |
| `docs/integration/extera-other-enru.patch` | Matching 21-key EN/RU additions, unapplied |

The root handoff follows notice `030f9549`; final checks observed HEAD `899a2b3e` in the concurrent tree. Both patches passed applicability against that live tree without modifying its global files. Root's independent menu/picker work is outside this manifest. The nine manifest files are frozen for root integration after this handoff; no commit or push was made by this work.

The new sources can compile before the root patches because backup behavior is an injected closure. The page becomes reachable only when root applies the host patch. Additional Settings calls the original category with the interception guard off, avoiding recursion. Global search retains its existing behavior; no unrelated search index was rewritten.

## Checks and expected recorded frames

Run the commands in `Tests/ExteraOther/README.md`. This Windows host has no Swift/Xcode, so XCTest execution/typecheck/full iOS build and simulator recording cannot be claimed. Parser and patch applicability results are recorded in the task handoff after validation.

Final source handoff validation:

| Check | Result |
| --- | --- |
| New production sources plus XCTest source | All four parse with tree-sitter-swift; this is syntax validation only |
| Both integration patches, together | `git apply --check` passed |
| Hypothetical root integration, in memory | Host context matched; patched settings and backup controllers parse; workflow/localizations composed without writing host files |
| EN/RU additions | All 21 keys match controller usage, exist once per language, and have matching sets |
| BUILD dependencies | All ten non-system imports already have direct dependency edges; both production source globs include the new files |
| Native account options API | Exact public signature and public access-configuration initializer checked at source; call uses matching labels and optional argument |
| Confirmation scheduling | Static inspection confirms the transition helper is used by confirmations/bank sheet, with no second UIKit dismiss and no deletion RPC |
| Whitespace / fixture | Manifest whitespace passed; public friendly TON zero-address checksum fixture independently checked |
| Host XCTest, 12 methods | Attempted; blocked by `swift is unavailable; XCTest requires a Swift host toolchain` |
| Full iOS compile/link, UIKit action execution, network/wallet/native deletion flows, recorded frames | Pending macOS; no runtime success or visual completion claimed |

Exact host CI command (also included in the unapplied workflow patch):

```sh
python3 tools/run_extera_xctests.py --warnings-as-errors \
  AyuGram/SGSimpleSettings/Sources/ExteraOtherSettingsModel.swift \
  Tests/ExteraOther/ExteraOtherSettingsModelTests.swift
```

Before capture, expected behavior per `AGENTS.md`:

1. Open Other from overview and category links, then Back. Native push/pop moves the page with its navigation header; no intermediate legacy Other page or duplicate title should flash. No payment or deletion screen opens on entry.
2. Frame 66 composition: both project headings/cards precede Google. With current remote entries: extera Boosty/Universal, Ayu Boosty/Tonkeeper. Loading becomes the complete catalog in a single list update; there must be no duplicate card or dangling separator. Failure shows explanation/Refresh and leaves export/reset/delete usable.
3. Frame 67 composition: Google remains above exactly Export → Reset → red Delete Account in one card. Both unavailable telemetry rows display status without a switch or a live tap. Scroll under the navigation surface must not expose a transparent gap or clipped heading.
4. Open and cancel support confirmations, bank action sheet and copy confirmation. Each predecessor dismisses before the next sheet appears; there must be no overlap, wrong iPad popover anchor or truncated destination. Cancel must leave clipboard and external apps untouched.
5. Wallet Open shows the destination and account-ID disclosure, then hands off to the wallet. Test missing-wallet fallback and Cancel, without approving a transfer. No amount is preselected by this code.
6. Export presents the same native share sheet and temporary JSON as backup. Cancel returns to Other. Reset opens the existing confirmation; **cancel it** for routine visual testing. Test actual reset separately only with an explicit in-app decision on a designated test account/configuration.
7. Delete Account opens the Continue alert only. Cancel must send no configuration/deletion request. After an explicit Continue on a designated test account, record loading and the native options page; Back/Cancel must leave the account intact. Verify no-password and password-enabled test accounts, timeout/Retry, frozen context and navigating away during the request. **Do not approve final deletion as part of visual validation.**
8. Record EN/RU, light/dark, large text, VoiceOver and iPad popovers. In the shared renderer, inspect the Google card joins and the red deletion row. Capture open/dismiss/back at real speed using `simctl io recordVideo`; generate labelled sheets/`frames.tsv` with `tools/animation_sheet.py`, then evaluate clipping, gaps/jumps and transitions with frame/time references.

There are no current iOS recordings or passed runtime frames for this work. The Windows source handoff is concrete; functional/visual acceptance is still pending root's macOS build and authorized simulator review.
