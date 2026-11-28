# Other composition checks

The 12 XCTest methods exercise the production model: reference order, absent telemetry capability, separate project catalogs, last-message override/removal, malformed/duplicate entries, executable URL rejection, real Universal URL routing, wallet account comment without amount, TON checksum/address injection, card-bank/copy differences, and bounded remote input. They do not claim UI/network/2FA coverage.

On a Swift host:

```sh
python3 tools/run_extera_xctests.py --warnings-as-errors \
  AyuGram/SGSimpleSettings/Sources/ExteraOtherSettingsModel.swift \
  Tests/ExteraOther/ExteraOtherSettingsModelTests.swift
```

Syntax-only on this Windows host:

```powershell
C:\Users\PC\.local\bin\uv.exe run --with tree-sitter --with tree-sitter-swift python Tests/ExteraOther/verify_swift_syntax.py
git apply --check docs/integration/extera-other-root.patch
git apply --check docs/integration/extera-other-enru.patch
```

The XCTest command was attempted here and stopped with `swift is unavailable; XCTest requires a Swift host toolchain`. Test methods are prepared, not executed. Full iOS typecheck/link and actual simulator recordings remain root/macOS work.

Root instructions, native route details, limitations and **expected visual frames before recording**: `docs/extera-other-settings.md`. Only the two supplied Other patches should be integrated for this feature; admin files are frozen and optional author hooks remain excluded.
