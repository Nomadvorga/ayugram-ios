# Ayu overview: exact reference APK destinations

Verified locally on 2026-11-25 by executing the APK's original lsparanoid decoder classes. No website lookup or inferred URL was used. APK SHA-256: `b7195bd9f3126543566acf3e1e5d3d1cc1fa163db927e85918877f7cb65cb113`.

| Row | Display label | Actual onClick value | Decoder key | Activity line |
|---|---|---|---|---|
| Channel | `@ayugram` | username `ayugram` | `-227472729048344L` | 200 |
| Chats | `@ayugramchat` | username `ayugramchat` | `-227507088786712L` | 203 |
| Translation | `Crowdin` | `https://translate.ayugram.one` | `-227455549179160L` | 206 |
| Documentation | `ayugram.one` | `https://docs.ayugram.one` | `-227257980683544L` | 209 |

The Android handler passes channel/chat usernames to `openByUserName`; an iOS `https://t.me/ayugram` or `https://t.me/ayugramchat` route is an adaptation of those verified usernames. The APK does **not** use `crowdin.com/project/ayugram` or the bare `https://ayugram.one` as the two website destinations. Redirects and present-day network availability were not checked.

Reproduce with a JDK and the cached decompilation:

```powershell
py tools/decode_ayu_overview_links.py --android C:/Users/PC/ayugram-apk-src
```

The tool compiles only `Deobfuscator$AyuGram4A$TMessagesProj.java`, `DeobfuscatorHelper.java`, and `RandomHelper.java` into an isolated temporary directory, invokes all eight row/handler keys, and reports source hashes. Original cached source hashes:

| Source under `ayugram-apk-src/sources` | SHA-256 |
|---|---|
| `com/radolyn/ayugram/preferences/AyuMainPreferencesActivity.java` | `c2df97dfe55491066441684befa990e3d0ab132c3444db48eb207a314377fb81` |
| `org/lsposed/lsparanoid/Deobfuscator$AyuGram4A$TMessagesProj.java` | `e2da5c20180d673560bbda875eb46f6a337c5515ff13474ef0363dec4510259b` |
| `org/lsposed/lsparanoid/DeobfuscatorHelper.java` | `31cc3b25b9a0baacd4a074c06f9673e4dbd1004b2fdde654b5dbe7a3276522f9` |
| `org/lsposed/lsparanoid/RandomHelper.java` | `a55768fa8472695526dcb4cf86ac33a6fdc5e97805b6ea9f756001519091d2b7` |

Root-owned controllers and the accepted snapshot were not edited by this verification.
