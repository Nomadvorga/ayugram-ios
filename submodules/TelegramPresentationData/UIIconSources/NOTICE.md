# Original interface artwork

These are UI glyphs, separate from the app's home-screen icons.

- Solar Icon Set: 480 Design / @Design480. Original project: https://github.com/480-Design/Solar-Icon-Set; creator links are preserved in `Solar-README.md`. Iconify's Solar metadata identifies CC BY 4.0 (`Solar-license-metadata.json`); a copy of that license is in `Solar-CC-BY-4.0.txt`. The original project's README does not itself include a license file. This metadata is preserved as secondary evidence, not represented as a license header embedded in each Android vector.
- Remix Icon: Copyright (c) 2017–2026 Remix Design, https://github.com/Remix-Design/RemixIcon. The retrieved original `Remix Icon License v1.0` is preserved in `Remix-License.txt`.
- Android adaptations and catalog: exteraGram contributors, https://github.com/exteraSquad/exteraGram, revision `b4d852f48f2734a0bee1a74a0939be621612262a`. The original `LICENSE`, `ADDITIONAL_TERMS.md`, and `BaseIconPacks.kt` are retained. Those additional terms explicitly leave third-party artwork under its original authors' terms.

All 74 imported vector geometries match the cached reference APK's decoded resources. The iOS adaptation converts original paths and strokes to 24-point transparent template PNGs at 1x/2x/3x. It preserves fill rules, stroke widths/caps/joins, path order and untransformed groups; no replacement artwork is drawn by hand. These rendering/format changes are modifications for iOS.

`provenance.json` records original vector hashes, git paths, the reference APK hash, decoded-resource hashes and generated-output hashes. `android-inventory.json` records the complete Solar/Remix Android replacement maps, including three shared popup-background remaps per pack. `third-party-notices.json` records downloaded notice URLs, immutable git blob identifiers where available, and SHA-256 values. No remote notice download is involved in the Ayu overview URL verification.

The picker retains the Solar and Remix author credits. The parent overview's existing exteraGram attribution/link remains root-owned. These notices do not assert that the exteraGram GPL license replaces third-party terms or resolve the previously reported app-identity/trademark question.
