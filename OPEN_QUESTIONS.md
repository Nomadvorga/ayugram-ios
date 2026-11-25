# Open questions

## Plugin port — 2026-11-25

- Native validation: the available environment is Windows. Full compilation, Swift tests and recorded simulator/device frames require macOS/Xcode; no native success has been asserted.
- Version policy: determine real application/SDK compatibility semantics for Android `__min_version__`, `__app_version__` and `__sdk_version__` against this iOS fork. SDK declaration counts are insufficient to claim a complete Android SDK version.
- Remaining native contracts: implement exact host interception/menu/request/update/media services in order of corpus reach; see `docs/plugins-corpus-compatibility.md`. No blanket Android/Xposed/DEX equivalence is available on iOS.
- Package formats: `.elyx`/`.eaf` need explicit entry-point/resource/module loading and signed iOS binary compatibility. Current archive handling is inspection only.
