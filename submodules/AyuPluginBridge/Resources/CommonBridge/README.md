# Common bridge: pinned 20-plugin compatibility audit

Source: `Nomadvorga/ayugram-src@a4b6bb472fd657e0f659531dae090e12c02a0aaa` for 19 inputs, plus a separately
SHA-256-pinned Premium Dialog Cards 2.1.1 source. **Not a claim that all 20 work.**

42,600 lines inspected as AST only. No supplied plugin execution; no device/native-test verification.

| Plugin | Path status | Value subsets | Application subsets | Unadapted classes | Missing SDK symbols |
|---|---|---:|---:|---:|---:|
| `atmospheric_snow.plugin` | Pinned native adapter; device unverified | 2 | 0 | 22 | 0 |
| `ball.plugin` | Blocked (Python path) | 0 | 0 | 10 | 0 |
| `fish_audio_integration.plugin` | Blocked (Python path) | 0 | 1 | 16 | 2 |
| `group_mentions.plugin` | Python bridge source; device unverified | 11 | 9 | 0 | 0 |
| `local_chat_archive.plugin` | Blocked (Python path) | 0 | 2 | 64 | 4 |
| `md3_loader.plugin` | Blocked (Python path) | 2 | 0 | 12 | 0 |
| `message_cleaner.plugin` | Blocked (Python path) | 3 | 1 | 39 | 4 |
| `music_bridge.plugin` | Blocked (Python path) | 0 | 0 | 8 | 0 |
| `music_tab.plugin` | Blocked (Python path) | 2 | 1 | 8 | 0 |
| `passguard.plugin` | Blocked (Python path) | 2 | 0 | 24 | 3 |
| `player_below.plugin` | Blocked (Python path) | 2 | 0 | 25 | 0 |
| `premium_dialog_cards.plugin` | Pinned native adapter; device unverified | 3 | 1 | 20 | 0 |
| `profile_info.plugin` | Blocked (Python path) | 3 | 0 | 23 | 3 |
| `pull_next_chat.plugin` | Blocked (Python path) | 4 | 1 | 16 | 0 |
| `quick_stickers.plugin` | Blocked (Python path) | 0 | 0 | 17 | 0 |
| `sand_box.plugin` | Blocked (Python path) | 0 | 0 | 9 | 0 |
| `screenshot_privacy.plugin` | Blocked (Python path) | 4 | 2 | 52 | 0 |
| `side_panel.plugin` | Blocked (Python path) | 5 | 2 | 65 | 2 |
| `spekgram.plugin` | Blocked (Python path) | 3 | 0 | 44 | 0 |
| `theme_per_account.plugin` | Blocked (Python path) | 0 | 1 | 3 | 0 |

See `compatibility.json` for each source hash, required API, hook/event form and missing class/symbol.

Atmospheric Snow, SandBox, Ball, Screenshot Privacy, Pull to Next Chat and Premium Dialog Cards bypass Python only for their exact pinned SHA-256. They are host-owned native routes and remain device-unverified.
Group Mentions is deliberately routed through the original Python source with narrow host shims; it is not a native reimplementation. The remaining 13 plugins stay blocked. Narrow app adapters are not a substitute for their remaining Telegram/iOS services.
See `APPLICATION-BRIDGES.md` for exact implemented members, per-plugin work packages and device checks.
