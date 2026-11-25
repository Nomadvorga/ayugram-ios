# Reverse image search protocol checks

These host tests compile the production Foundation-only upload/result URL logic. They
make no network requests and never read a private photo. On macOS, run from repo root:

```sh
python3 tools/run_extera_xctests.py --warnings-as-errors \
  submodules/GalleryUI/Sources/ExteraImageSearchProtocol.swift \
  Tests/ExteraImageSearch/ExteraImageSearchProtocolTests.swift
```

The runner copies these sources unchanged into a temporary Swift 5.9 package and runs
`swift test` in Swift 5 language mode with warnings as errors. SwiftPM discovers every
XCTest method and supplies Xcode's XCTest paths; the standalone `XCTMain` entry point is
excluded in package builds because macOS XCTest does not provide it. Build or test
failures fail the runner, and the temporary package is removed when it exits.

Coverage checks Android's real Yandex endpoint and multipart field, provider URL
encoding, absence of fabricated/public Telegram URLs and forced consent cookies,
rejection of non-Yandex upload redirects/result-image hosts, invalid/oversized JPEG
payloads, malformed responses, credential-bearing URLs, HTTP, and nonstandard ports.

Swift is unavailable on the implementation's Windows host. Sources were syntax-parsed
using tree-sitter; these tests still require compilation/execution on a Swift host.
See `docs/extera-image-search.md` for integration and device verification.
