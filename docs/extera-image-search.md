# Gallery photo tools and reverse image search

The photo gallery navigation bar adds a magnifier labelled **Photo Tools** beside its
existing buttons. It applies the gallery's selected-medium resolver and excludes secret
chats, secret/view-once media, paid media, ads, and message/peer copy-protected content.
Video quality/original playback code is untouched.

The utility displays a cached image preview, local metadata, cached-file SHA-256, image
copy, fingerprint copy, and Yandex / Google Lens / Bing / TinEye provider choices. It
observes complete cached resource data without starting a Telegram download. Photos
must have a complete cached representation or original image document under 32 MB.
ImageIO downsamples before decoding to a maximum side of 1280 pixels; a fresh opaque
JPEG at quality 0.9 removes original EXIF/GPS metadata. The preview is that JPEG. Copy
uses the same JPEG with local-only pasteboard storage expiring after two minutes.
EXIF fields and a GPS-present marker are displayed locally; raw GPS coordinates are
not displayed or copied automatically. Telegram photo representations often have no
EXIF. The fingerprint describes the actual cached file, not an unavailable original.

## Android grounding and upload disclosure

Reference files read with `git show HEAD:<path>` from `exteragram-reference`:

- `TMessagesProj/src/main/java/com/exteragram/messenger/components/ReverseImageSearch.java`
- `TMessagesProj/src/main/java/com/exteragram/messenger/components/SearchPhotoPopupWrapper.java`

Their four provider choices all upload to Yandex, not to four independent upload APIs:

`POST https://yandex.com/images/touch/search?rpt=imageview&format=json&request=...`

The `request` query contains `{"blocks":[{"block":"cbir-uploader__get-cbir-id"}]}`.
Multipart field `upfile` sends `image.jpg` as `image/jpeg`. The response's first block
`params` supplies `cbirId` and `originalImageUrl`. These real returned values populate
Yandex image search, Google's `lens.google.com/uploadbyurl`, Bing's `imgurl:` query,
or TinEye's `search?url=`. No Telegram message link or invented public image URL is used.

The provider picker explicitly explains that **Yandex receives the image for every
provider**, and another provider receives the Yandex-hosted URL. The preview and
confirmation precede any upload. Upload cancellation cannot retract already-sent bytes.
No live endpoint request was made during implementation. The code does not seed or
accept consent cookies on the user's behalf. Browser verification/consent may therefore
be required; endpoint changes, CAPTCHA, or regional restrictions produce visible failure.

The URLSession is ephemeral, excludes shared cookies/cache, bounds request/response
sizes and timeouts, restricts redirects to HTTPS Yandex hosts, and accepts only HTTPS
Yandex-owned returned image hosts. Search results open in SFSafariViewController.
Closing/backgrounding cancels uploads; retries require another provider confirmation.
Returned service URLs and image bytes are not logged or persisted by this utility.

This port derives endpoint/provider behavior from exteraGram (2022–2026 exteraGram),
under its GPL-3.0-or-later license and additional terms. See the existing third-party
notice and the reference repository's LICENSE / ADDITIONAL_TERMS.md.

## Build integration

GalleryUI already globs `Sources/**/*.swift`; add direct dependency
`//Swiftgram/SGStrings:SGStrings` because the new controller imports SGStrings.
Foundation/UIKit/SafariServices are already used. ImageIO and CryptoKit are Apple SDK
modules; deployment must support CryptoKit (iOS 13+). No new Postbox access or import
was added. New code obtains cache bytes through TelegramEngine.Resources.

New strings use `Extera.Image*` i18n keys with English fallbacks. Parent owns EN/RU
localization and BUILD edits.

## Verification still required on macOS/device

Host protocol tests: `Tests/ExteraImageSearch/README.md`. No Swift compiler, iOS SDK,
simulator, or visual recording tools are available on the Windows implementation host.
Tree-sitter checks syntax only; a full app build remains required.

Before recording, expected layout: existing gallery buttons remain visible, Photo Tools
shows only for an eligible selected photo, its preview matches the gallery image, and
all provider/copy/metadata controls scroll within safe-area bounds without clipped text.
Test portrait/landscape, dark/light, large text and iPad presentation. Record labelled
simulator frames as required by AGENTS.md. Verify album/rich-message selection, incomplete
cache feedback, copied JPEG orientation, absence of EXIF/GPS in copied/uploaded JPEG,
each provider with a deliberately public test photo, failed network, cancellation,
backgrounding, and protected/secret/paid media hiding. Never use a private user photo
to test the third-party endpoint without explicit authorization.
