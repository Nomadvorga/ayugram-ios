# Reverse image search protocol checks

These host tests compile the production Foundation-only upload/result URL logic. They
make no network requests and never read a private photo. On macOS, run from repo root:

```sh
OUT="$(mktemp -d)"
xcrun swiftc -swift-version 5 -parse-as-library -warnings-as-errors \
  submodules/GalleryUI/Sources/ExteraImageSearchProtocol.swift \
  Tests/ExteraImageSearch/ExteraImageSearchProtocolTests.swift \
  -o "$OUT/ExteraImageSearchProtocolTests"
"$OUT/ExteraImageSearchProtocolTests"
```

Coverage checks Android's real Yandex endpoint and multipart field, provider URL
encoding, absence of fabricated/public Telegram URLs and forced consent cookies,
rejection of non-Yandex upload redirects/result-image hosts, invalid/oversized JPEG
payloads, malformed responses, credential-bearing URLs, HTTP, and nonstandard ports.

Swift is unavailable on the implementation's Windows host. Sources were syntax-parsed
using tree-sitter; these tests still require compilation/execution on a Swift host.
See `docs/extera-image-search.md` for integration and device verification.
