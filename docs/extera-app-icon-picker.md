# App icon picker: frames 20, 22 and 24

Implemented in `Swiftgram/SGSettingsUI/Sources/ExteraAppIconController.swift`.
Public entry: `exteraAppIconController(context: AccountContext) -> ViewController`.
The settings route is owned by the root task and must push that entry for `.appIcon`.

## Reference and intended appearance

Read both audits (`extera-reference-screens-01-22.md`, `extera-reference-screens-23-44.md`) and individually opened original frames 20, 22, 24 from Downloads. All three show **four columns**, image above label, a rounded selection background and a circular check at the image's lower right. Frame 22 shows the large expanded preview and title; frame 20 shows the compact preview after scrolling. Frame 24 shows the shorter AyuGram catalog. Their footer action changes between `Выбрать` for a draft choice and `Оставить такую` for the current icon.

The controller implements that composition using a scroll view, rounded catalog surface, an artwork-colored hero gradient, four-column grid, independent back button, AyuGram/exteraGram segments and a fixed wide capsule action. The hero shows the original description or credited author where available. Light colors follow the presentation theme. Content respects `sideInsets(forBandFrom:to:)`; the bottom action uses `bottomEdgeSideInsets()`. Wide layouts cap the grid and button at 600 points. The large preview fades into the compact header only near the end of the hero's scroll range.

Expected frames for future simulator verification: the entire grid and hero travel with the scroll offset; as the panel reaches the back button's lower edge, the compact image and header background become visible while the large image/title fade. There must be no duplicated full-opacity previews, cell clipping, overlapping labels, or last row hidden behind the action. Tapping a cell updates the hero and selection together, without changing the installed icon. Back discards the draft. Selecting the installed icon closes the screen; selecting another icon invokes the existing binding. Check normal speed, scroll in both directions, back gesture, pending/success/error, both themes, iPad/rotation and VoiceOver. Capture and label simulator frames per `AGENTS.md` before claiming visual parity.

## Registered iOS catalog

The former binding and BUILD exposed only `SGDefault`. The bundled `Telegram/Telegram-iOS/Resources/ExteraAppIconCatalog.json` now maps all 42 original Android catalog entries to stable iOS names: 10 AyuGram and 32 exteraGram. `SGDefault` stays the default, and its shipped `@2x`/`@3x` files remain byte-identical to HEAD. Existing legacy plist identifiers remain untouched. There are 41 new alternate names, listed in `Telegram/BUILD` and both alternate plist fragments. The AppDelegate change is confined to `getAvailableAlternateIcons`, reading the bundled catalog and falling back to the original `SGDefault` when unavailable. The existing primary Icon Composer icon remains `Swiftgram`.

The two segments appear when both real families have registered, loadable icons. Draft choices are remembered per family while this controller is open. Winter follows Android's December–February visibility rule, and also remains visible when installed outside that season; the assets are bundled year-round. In November the exteraGram grid therefore has the 31 icons shown in the reference. Monet uses the original vector paths with the measured reference palette, background `#2D3134` and foreground `#C2E8FF`. It is a static iOS alternate icon; Android system wallpaper-color adaptation is unavailable through this API.

The picker mirrors Theme Settings' `Signal<[PresentationAppIcon], NoError>.single(...)` around `applicationBindings.getAvailableAlternateIcons()`. SharedAccountContext has no independent `appIcons` signal in this checkout. Every selectable icon must be returned by the bindings, have a loadable image in `getAppBundle()`, and either be the default or have an exact `CFBundleAlternateIcons` registration. iPad checks its effective `CFBundleIcons~ipad` dictionary before falling back to `CFBundleIcons`. Unknown installed alternate names are preserved as the current system name; the picker does not falsely mark the first visible item as installed.

## Apply and data flow

Installed state is read with `applicationBindings.getAlternateIconName()` at load/appearance, on application activation, and after completion. A local draft stores the selected catalog name. No defaults, theme preference, account DB or mirror of the installed icon is written.

Confirming a new icon retains Theme Settings' Telegram Premium peer check through `context.engine.data.get(...)`. A locked Premium selection opens the existing shared-context Premium intro. Successful entitlement checking calls `applicationBindings.requestSetAlternateIconName(icon.isDefault ? nil : icon.name, completion)` on main. The application implementation already delegates that to `UIApplication.setAlternateIconName` and calls back with success. That implementation, its extension bindings, and its callback chain are untouched. While pending, cells, segments and action are disabled and an activity indicator replaces the action title. The completion returns to main, rereads installed state, and closes on success. Failure retains the draft, restores the action and shows a native localized alert. A callback after leaving the screen does not pop another controller or present an alert over it.

The binding exposes only a Boolean, so the alert uses a generic localized error instead of inventing an NSError description. There is no direct `UIApplication.shared` call in the feature and no change to extension behavior.

## Strings for root integration

The root task owns `en/ru` string files. This file consumes these keys through SGStrings using the current presentation language:

| Key | English | Russian |
| --- | --- | --- |
| `Extera.AppIcon.Select` | Select | Выбрать |
| `Extera.AppIcon.KeepCurrent` | Keep This Icon | Оставить такую |
| `Extera.AppIcon.Default` | Main | Основная |
| `Extera.AppIcon.Current` | Current | Текущая |
| `Extera.AppIcon.Empty` | No app icons are available. | Нет доступных иконок приложения. |
| `Extera.AppIcon.Error` | Could not change the app icon. Please try again. | Не удалось изменить иконку приложения. Повторите попытку. |
| `Extera.AppIcon.Name.Winter` | Winter | Зима |
| `Extera.AppIcon.Name.Orbit` | Orbit | Орбита |
| `Extera.AppIcon.Name.Editor` | Editor | Редактор |
| `Extera.AppIcon.Name.Sus` | Impostor | Предатель |
| `Extera.AppIcon.Name.Invincible` | Invincible | Неуязвимый |
| `Extera.AppIcon.Name.IceAge` | Ice Age | Ледник |
| `Extera.AppIcon.Name.Cyberpunk` | Cyberpunk | Киберпанк |
| `Extera.AppIcon.Name.Space` | Space | Космос |
| `Extera.AppIcon.Name.Sunset` | Sunset | Закат |
| `Extera.AppIcon.Name.Amethyst` | Amethyst | Аметист |
| `Extera.AppIcon.Name.Aurora` | Aurora | Аврора |
| `Extera.AppIcon.Name.Google` | Google | Google |

Back/OK and legacy Telegram catalog display names use PresentationStrings. Other names, author handles and descriptions retain original source text. Description text currently comes from the English APK resources. Actual icon identifiers remain unchanged.

## Original artwork, provenance and overview assets

No icon designs were invented or generated by an image model. The importer composites real original foreground/background layers using Android's adaptive viewport and resizes with Pillow LANCZOS. It renders original XML/SVG paths through `@resvg/resvg-js@2.6.2`; raster sources are 432×432 APK layers or higher-resolution upstream masters (including 1000×1000). The 1024 raster exports are resampled artwork, not additional source detail. The central crop is `(72, 72, 360, 360)` on a 432-square master, equivalent to Android drawing layers into `[-size/4, -size/4, 5*size/4, 5*size/4]`. Outputs are unmasked RGB PNGs at 20, 29, 40, 58, 60, 76, 80, 87, 120, 152, 167, 180 and 1024 pixels; the 41 new icons also have standard 120/180 `@2x`/`@3x` files. A source alpha residue of 254 is flattened over black; no rounded corners are baked into launcher PNGs.

Original layers, author catalog, unmodified notices/licenses and a contact sheet live under `Telegram/Telegram-iOS/AppIconSources/`. `provenance.json` records every source/output SHA-256, original APK ZIP entry for byte-identical raster inputs, decoded XML resource hashes, source git paths/revision, renderer integrity and overview copies. These source files are outside the app resource glob. The small catalog JSON is bundled by the existing AppResources target; the PNGs use existing `.alticon` filegroups.

- Exact reference APK: `vanilla-AyuGram-full-20261104.apk`, SHA-256 `b7195bd9f3126543566acf3e1e5d3d1cc1fa163db927e85918877f7cb65cb113`. Its build metadata identifies revision `6029a7feaad350cbdd99a91178ea34ad623f1e4f`. Ayu variants are imported from its real resources because the available older Ayu repository checkout lacks them.
- extera masters and author catalog: <https://github.com/exteraSquad/exteraGram>, revision `b4d852f48f2734a0bee1a74a0939be621612262a`, original `TMessagesProj/appicons` paths. Where available, the importer uses the upstream master and records both its hash and the corresponding APK resource hash.
- Ayu notices: <https://github.com/AyuGram/AyuGram4A>, revision `7013145676d36d82ee13c02a89f72097b7490dcd`. This is the notice source, not a claim that the newer APK artwork exists at that revision.
- Renderer: `@resvg/resvg-js@2.6.2`, npm integrity `sha512-xBaJish5OeGmniDj9cW5PRa/PtmuVU3ziqrbr5xJj901ZDN4TosrVaNZpEiLZAxdfnhAe7uQ7QFWfjPe9d9K2Q==`. Import environment: Pillow 12.2.0. The renderer is installed outside the repository and is not a build/runtime dependency.

The root overview controllers can directly use `UIImage(bundleImageName: "AyuOverviewIcon")` and `UIImage(bundleImageName: "ExteraOverviewIcon")`. Each imageset contains `Contents.json` and a universal PNG, picked up by the existing `SGUIAssets` glob:

| Asset under `Swiftgram/SGSettingsUI/Images.xcassets/` | Original/copy source | PNG SHA-256 |
| --- | --- | --- |
| `AyuOverviewIcon.imageset` | Byte-for-byte copy of `Telegram/Telegram-iOS/Swiftgram.icon/Assets/AyuGram.png` | `a5d0540dd69fe9d8ecf26ceeda8875a0b992f7bf41dffd86c88bf9d8faeb5104` |
| `ExteraOverviewIcon.imageset` | Copy of `Telegram/Telegram-iOS/ExteraDefault.alticon/ExteraDefault_1024x1024.png`, composited/resized from original Android default artwork | `796cea9a3e1f22a962bc935ddb226956c2e7de6c208252372e633828df9af829` |

The extera default foreground is `TMessagesProj/appicons/exteragram/default/ic_launcher_foreground.webp`, SHA-256 `0b384db29831e53a8b07adfa6dba986f8061677fcc7150c5fcf53ae367af14bc`, byte-identical to APK `res/bIw.webp`; its original background is the solid source color `#E83030`.

## Source terms and root handoff

The unmodified Ayu GPL-2 license and README, extera GPL-3-or-later license, `ADDITIONAL_TERMS.md`, icon README and author catalog are preserved beside the source layers and checksummed. Original per-icon authors remain in the bundled metadata. extera's additional terms require an attribution notice linking <https://github.com/exteraSquad/exteraGram> where the modified app displays its name/version/legal notices. Root owns that overview/About integration.

Section 3 of those terms explicitly grants no trademark rights to use exteraGram's name/logos/app icons as a modified version's name or icon. The local asset implementation does not establish distribution permission. Root has been informed of that restriction; a distribution decision remains outside this delegated implementation.

## Reproduce and check

Use the pinned input repositories/APK and an extracted APK tree containing `resources/res` and `sources`. Install the pinned renderer with a lockfile/integrity verification outside the repository, then:

```powershell
py tools/import_extera_app_icons.py --android C:\Users\PC\ayugram-apk-src --apk 'C:\Users\PC\Downloads\Telegram Desktop\vanilla-AyuGram-full-20261104.apk' --extera C:\Users\PC\exteragram-reference --ayu C:\Users\PC\AppData\Local\Temp\opencode\ayu-app-icon-source --renderer C:\Users\PC\AppData\Local\Temp\opencode\app-icon-renderer\node_modules\@resvg\resvg-js
py tools/check_extera_app_icons.py
```

Importing regenerates derived PNGs, metadata and provenance, while preserving the shipped SGDefault files. Both scripts operate locally and make no network requests. The source APK and git clones are inputs and are not included in the repository.

## Validation and limits

- Tree-sitter Swift parsed the new controller without syntax errors. The complete AppDelegate has the same pre-existing parser error at `nonisolated(unsafe)` on line 654 in HEAD and the working tree; the inserted catalog code introduces no new parser errors.
- `py build-system/Make/PostboxImportCheck.py` completed successfully. Its repository scan covers `Telegram`/`submodules`, so the new Swiftgram file also received a direct check with that guard's import/access/media-conformance helpers: no forbidden access.
- `py tools/check_extera_app_icons.py` verifies all 42 mappings, 628 generated PNG hashes/dimensions/RGB mode, source and notice checksums, both overview copies, both plist fragments and BUILD agreement, preservation of legacy plist entries and shipped SGDefault bytes, and byte-equivalence of the native completion chain. It checks repository inputs, not a final IPA.
- Checked the application binding callback implementation, SharedAccountContext signatures, native navigation APIs, build source/asset globs, and existing Theme Settings names/entitlement flow against source. The generated contact sheet and overview images were opened for source-artwork inspection; these are not simulator frames.
- Inspected the pinned `ali-fareed/rules_apple` revision `485016eb5b0948cc17307064e7977a6d68e94046`: `resources_support.bzl` copies all PNGs from `.alticon` folders as loose bundle resources; `tools/alticonstool/alticonstool.py` uses each folder stem as the identifier and all filename stems (stripping `@scale`) as `CFBundleIconFiles` for both device families. The generated naming follows that implementation. Final bundle contents still require a macOS build check.
- This Windows session has no Xcode/UIKit typechecking, iOS build or running simulator. **Runtime, native icon confirmation, failure recovery and visual/animation parity are unverified.** No simulator recordings or frame claims are made.
- Task changes comprise the picker, original/derived icon assets, both overview imagesets, metadata/provenance/import/check scripts, icon-only BUILD/plist registrations and the AppDelegate catalog section. SGItemListUI, root navigation/settings route, translations and workflows are owned by other tasks and were not edited here. No commit or push was made.
