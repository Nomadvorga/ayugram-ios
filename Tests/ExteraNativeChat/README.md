# Native chat settings checks

The production host fixtures check the native default, audio mixing precedence and
app-group persistence with post-write notifications (using an isolated defaults
suite), plus wallpaper-search query and pagination decisions:

```sh
python3 tools/run_extera_xctests.py --warnings-as-errors \
  AyuGram/SGSimpleSettings/Sources/AyuSettingsStore.swift \
  AyuGram/SGSimpleSettings/Sources/ExteraChatMediaSettings.swift \
  Tests/ExteraNativeChat/ExteraChatMediaSettingsTests.swift \
  submodules/TelegramUI/Components/Settings/WallpaperGridScreen/Sources/WallpaperSearchState.swift \
  Tests/ExteraNativeChat/WallpaperSearchStateTests.swift
```

The wallpaper-search suite covers query normalization/color scoping, stale response
rejection after clear/re-entry, one in-flight page, id deduplication, repeated/empty
page termination, retry state, and color-change reset. It is a strings-free host test;
the controller and Telegram network/gallery integration still require the app build.

Native tests are picked up by the existing test globs, without BUILD changes:

- `//submodules/TelegramAudio:TelegramAudioTests`: three new playback policy tests;
  includes existing recording microphone/type regression cases.
- `//submodules/TelegramPresentationData:TelegramPresentationDataTests`: six new
  native size inventory, independent font/list settings, corner bounds, square
  action background and bubble-free setting-preservation cases.

Use the full native test commands from CLAUDE.md with each explicit `--target`.
No XCTest run has passed on the Windows host: Swift and the iOS SDK are unavailable.
Native build, live image-bot/gallery verification, audio routing and recorded-frame
acceptance remain required. See [the screenshot/source matrix and handoff](../../docs/extera-native-chat-settings.md).
