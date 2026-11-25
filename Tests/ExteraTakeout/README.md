# Native takeout checks

Windows source/API audit (no network or account access):

```powershell
C:\Users\PC\.local\bin\python3.12.exe Tests/ExteraTakeout/validate_source.py
```

On a Swift host, compile the real Foundation-only production models/writer:

```sh
swiftc submodules/TelegramCore/Sources/TelegramEngine/Messages/ExteraTakeoutModels.swift \
  submodules/TelegramCore/Sources/TelegramEngine/Messages/ExteraTakeoutWriter.swift \
  Tests/ExteraTakeout/main.swift -o /tmp/extera-takeout-tests
/tmp/extera-takeout-tests /tmp/extera-takeout-fixture.zip
python3 Tests/ExteraTakeout/validate_source.py /tmp/extera-takeout-fixture.zip
```

The fixture destination must not already exist. Tests cover flag/date choices,
wait errors/redaction, streamed JSON, HTML injection escaping, filename isolation,
archive scope disclosure, ZIP output, cancellation, byte limits and cleanup.
The independent Python ZIP reader verifies CRCs and binary content.

Swift is unavailable on this Windows host, so the Swift executable and its ZIP
round trip are **not run here**. The source audit is not a Swift typecheck.
See `docs/extera-takeout.md` for required account/simulator integration checks.
