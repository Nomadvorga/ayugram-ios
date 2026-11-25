# Camera zoom and gallery volume-unmute validation

`MediaModelTests.swift` exercises production bounds, neutral reset, fixed zoom devices,
logarithmic slider round trips, invalid samples, overflowing pinch deltas and the volume
sample policy. The runner copies `CameraZoom.swift` verbatim and extracts
`ExteraMediaSettings.shouldUnmuteVideo` verbatim into a Foundation-only host wrapper.
It does not substitute a second implementation or a fake settings store.

On a host with Swift/Foundation:

```sh
python3 Tests/ExteraMedia/run_model_tests.py
```

The command compiles with `-warnings-as-errors` and runs assertions. A missing compiler
is an error. To prepare the exact same sources without executing them on Windows:

```powershell
py Tests/ExteraMedia/run_model_tests.py --emit-only --output C:\Users\PC\AppData\Local\Temp\opencode\extera-media-host
```

The emitted three Swift files can also be compiled directly with `swiftc *.swift -o
MediaModelTests`, then run. Emission alone is **not a model-test pass**.

Available Windows checks:

```powershell
py Tests/ExteraMedia/verify_integration.py
py Tests/ExteraMedia/verify_swift_syntax.py
```

The first checks ten source integration contracts, including both backends, lens
selection, static release, lifecycle gates and preservation of background pause.
It cannot establish runtime behavior. The second requires `tree_sitter` and
`tree_sitter_swift`; it parses production and test sources plus the emitted wrapper.
For Neo, it verifies that the two `value: ()` grammar errors also exist in `HEAD`,
then parses an in-memory `Void()` normalization. It does not edit production or
silently ignore other parser failures. Tree-sitter cannot typecheck iOS APIs.

No BUILD or CI files are changed. The new Camera production source is covered by
the existing source glob. Host tests are standalone; adding them to a Bazel test
target requires its explicit source list to include the new model and test runner.

See [runtime semantics and remaining device/frame checks](../../docs/extera-media-camera-runtime.md).
