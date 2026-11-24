# Plugins

Original AyuGram plugin sources, kept here verbatim for the iOS bridge work.
They are reference inputs: the app does not import or execute them at build time,
and the iOS routes reimplement audited contracts natively.

## Supported by the app now

This build has no general `.plugin` runtime. Import accepts only these pinned
sources; every other file is rejected before it is written or executed.

| Supported file | Route |
| --- | --- |
| `atmospheric_snow.plugin` | Native, Python-free |
| `ball.plugin` | Native |
| `pull_next_chat.plugin` | Native |
| `sand_box.plugin` | Native, audited `GAME_HTML` in WKWebView |
| `screenshot_privacy.plugin` | Native shield |
| `group_mentions.plugin` | Pinned Python source |

The remaining files below are reference material for future work. They are not
importable and are not claimed to run.

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `atmospheric_snow.plugin` | 175422 | `bbda8727d253e02542c1c1f51dca1d39d235e2a310b4ba096e5e6305472a6763` |
| `ball.plugin` | 20574 | `89f079f2a055ba851b6efec90a2c57d233b1f7204102363b2a637fa06579ea8f` |
| `fish_audio_integration.plugin` | 44482 | `712d5fafb3b2a5c65fb31812fb80a7c3cef376ea123a7a50191710c1abb0d904` |
| `group_mentions.plugin` | 28308 | `25ae71486b29481d57cc36eaf40e931522a655227d2870dfc898174b8d96f28e` |
| `local_chat_archive.plugin` | 214052 | `eec9a132595171f861376e02b2e9a791a825f493576bf921df154662e91beabe` |
| `md3_loader.plugin` | 20709 | `7fc0d5a642328d4becf2e7072e1a0f67611adf6b224080816c934c5af6b876a0` |
| `message_cleaner.plugin` | 149178 | `0c8ef27f742af17837b5db494d3d73a784544f42fc3acb0bd7210f9315b8f788` |
| `music_bridge.plugin` | 44400 | `7e7dd825824f3d0160e730b0638ac4d993b7e225029c3305d274951b3fd6a58c` |
| `music_tab.plugin` | 12925 | `784131522216c43d86a9ac1af627bf4082af17be0202da8e11104a18b7bb144e` |
| `passguard.plugin` | 173638 | `d161e81b25f4863d0a374f56f39c5a565f84b0743b55925acb1b3573d23458c8` |
| `player_below.plugin` | 89661 | `9da5241f0c5827c25e58a04efdc970836a71d4edbd19feaebe0827c8da78aeac` |
| `profile_info.plugin` | 134608 | `69076df05ba89c804d0b9e944c1ecc17ed6b69e9eb0f9051c7c57ffef6722792` |
| `pull_next_chat.plugin` | 32931 | `69975fd768369d2a46d28dbe87f8c580f772d0f974ce8434fca58f65babed709` |
| `quick_stickers.plugin` | 27529 | `abdad44b0acf3730008cb37d38d3c89610522f8bf20ec7f3906f8860c905c1ac` |
| `sand_box.plugin` | 61843 | `9bd2c5ffa93e6a866212a4e0fd263b6216dc10080bbd55c79f40625e8942f8e5` |
| `screenshot_privacy.plugin` | 182662 | `ce11a973f667623b84aadd1fc68d50fedf410e605759c251789383641cbef23e` |
| `side_panel.plugin` | 147350 | `105989fc0af1333ca68c05ae2fb9b73f3ece2262e1521ed0b8e7561dedb2bddf` |
| `spekgram.plugin` | 175215 | `4535dc52fc4eb168757aa9bcd255574aadf8cc3d2e6e8dd613208f52675df0f1` |
| `theme_per_account.plugin` | 16624 | `b9f2165a87a4140db947bc3ace304ebf088854b45f35a303437837d532da2f02` |
