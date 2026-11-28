# Compiler fixes for run 45692107515

Failed device build: [run 45692107515](https://github.com/Nomadvorga/ayugram-ios/actions/runs/45692107515),
head `030f9549d29daedcc94c5b03fbc23b2c2104c8d6`, Xcode 27.1 / iPhoneOS 27.1,
arm64, deployment target iOS 15. The failed action was compiling
`//AyuGram/SGSettingsUI:SGSettingsUI` at 2026-11-25 20:56:23–24 UTC.
The full failed log was retrieved with `gh run view 45692107515 --log-failed`.
It contains five distinct failing source locations; some diagnostics repeat
during module emission and compilation. The preceding Objective-C availability
and Rust warnings are not the reported fatal compiler errors.

## Applied minimal fixes

These four files were clean before editing and are outside active AI/root and
frozen style work. The exact manifest is `extera-build-fixes-manifest.json`.

| Source location in failed run | Actual diagnostic | Applied change |
| --- | --- | --- |
| `ExteraAppIconController.swift:514:18` | overriding non-open method / missing override | Rename private `push` to `pushIconController`, including its one call. It conflicts with the existing public non-open `Display.ViewController.push`. |
| `ExteraFeedPostItem.swift:70:17` | stored property cannot override `inHierarchy`; override access too narrow | Rename local lifecycle flag to `feedNodeIsInHierarchy`, preserving both lifecycle assignments and its playback visibility guard. `ASDisplayNode` already supplies readonly `inHierarchy`. |
| `AyuReadHistoryController.swift:134:204` | weak capture differs from implicit strong outer capture | Make the outer signal map's existing strong capture explicit with `[actions]`. Preserve the inner navigation action's weak capture. |
| `ExteraSpeechRecognitionController.swift:212:31` | captured mutable `failure` referenced in concurrently executing code | Snapshot the completed error in the `MainActor.run` capture list: `[weak self, failure]`. Preserve cancellation/result handling. |

No setting, visibility policy, navigation destination, request, or fallback is
changed by these fixes. No new dependency or test target is required.

## Root-owned proposal, not applied

`ExteraSettingsOverviewController.swift:202:18` has the same non-open `push`
collision. Root owns navigation integration, so its source was left untouched.
`extera-build-fixes.patch` renames that helper to `pushOverviewController` and
updates all three calls (Ayu category, SG category and search). It preserves the
current NavigationController push behavior. Do not add `override`: the base
method is non-open in another module.

`git apply --check -- docs/integration/extera-build-fixes.patch` passed against
the current working tree. Root may apply the proposal after reconciling its
concurrent routing work. This patch contains only the unapplied overview fix;
the other four fixes are already in the working tree.

## Validation and limits

All four edited sources and an in-memory copy with the proposed overview rename
passed tree-sitter Swift parsing. Scoped `git diff --check` passed. Identifier
checks confirm every old private helper/flag reference was replaced; the
proposal covers the overview helper and all three calls.

This Windows worker has no iOS Swift/Xcode toolchain, so these are source fixes
for the actual logged diagnostics, not a successful rebuild claim. Rerun the
device build after root integrates the overview patch; later compiler errors may
surface after SGSettingsUI module emission succeeds. No commit or push was made.
Frozen style sources/manifest and active AI/root integration were not edited.
