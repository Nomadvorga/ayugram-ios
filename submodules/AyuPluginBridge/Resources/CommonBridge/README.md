# Common bridge: pinned 19-plugin compatibility audit

Source: `Nomadvorga/ayugram-src@a4b6bb472fd657e0f659531dae090e12c02a0aaa`. **Not a claim that all 19 work.**

40,950 lines inspected as AST only. No supplied plugin execution; no device/native-test verification.

| Plugin | Path status | Value subsets | Unadapted classes | Missing SDK symbols |
|---|---|---:|---:|---:|
| `atmospheric_snow.plugin` | Pinned native adapter; device unverified | 2 | 22 | 0 |
| `ball.plugin` | Blocked (Python path) | 0 | 10 | 0 |
| `fish_audio_integration.plugin` | Blocked (Python path) | 0 | 17 | 2 |
| `group_mentions.plugin` | Blocked (Python path) | 0 | 8 | 1 |
| `local_chat_archive.plugin` | Blocked (Python path) | 0 | 66 | 4 |
| `md3_loader.plugin` | Blocked (Python path) | 2 | 12 | 0 |
| `message_cleaner.plugin` | Blocked (Python path) | 3 | 40 | 4 |
| `music_bridge.plugin` | Blocked (Python path) | 0 | 8 | 0 |
| `music_tab.plugin` | Blocked (Python path) | 2 | 9 | 0 |
| `passguard.plugin` | Blocked (Python path) | 2 | 24 | 3 |
| `player_below.plugin` | Blocked (Python path) | 2 | 25 | 0 |
| `profile_info.plugin` | Blocked (Python path) | 3 | 23 | 3 |
| `pull_next_chat.plugin` | Blocked (Python path) | 4 | 17 | 0 |
| `quick_stickers.plugin` | Blocked (Python path) | 0 | 17 | 0 |
| `sand_box.plugin` | Blocked (Python path) | 0 | 9 | 0 |
| `screenshot_privacy.plugin` | Blocked (Python path) | 4 | 54 | 0 |
| `side_panel.plugin` | Blocked (Python path) | 5 | 67 | 2 |
| `spekgram.plugin` | Blocked (Python path) | 3 | 44 | 0 |
| `theme_per_account.plugin` | Blocked (Python path) | 0 | 4 | 0 |

See `compatibility.json` for each source hash, required API, hook/event form and missing class/symbol.

Atmospheric Snow bypasses Python only for the exact pinned SHA-256; its Android/Python path remains blocked.
The other 18 remain blocked. Registry extensibility is infrastructure, not a substitute for real Telegram/iOS adapters.
