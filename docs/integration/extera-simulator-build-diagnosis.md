# Simulator build diagnosis

No additional compiler-error locations were found in old simulator run
[45689872902](https://github.com/Nomadvorga/ayugram-ios/actions/runs/45689872902).
Its errors are a subset of the five SGSettingsUI locations already diagnosed
from device run 45692107515. No duplicate fix or production change is needed
from this investigation.

## Completed old simulator run

- Head: `f33d63821e0e90105e61a01775fc2786ae000cb2`.
- Metadata: `status=completed`, `conclusion=failure`, title `Build IPA`.
- Evidence: `gh run view 45689872902 --log-failed` and
  `gh run view 45689872902 --json headSha,status,conclusion,url,displayTitle`.
- Failed action: compiling `//AyuGram/SGSettingsUI:SGSettingsUI`, reported at
  `AyuGram/SGSettingsUI/BUILD:9:14`, 2026-11-25 21:13:24 UTC.
- Build invocation: `--ios_multi_cpus=sim_arm64`, `-c dbg`, disk cache
  `debug_sim_arm64`. Bazel reported elapsed time `4405.309s` and target
  `//Telegram:Swiftgram` failed.

The full failed log contains 13 source diagnostic occurrences at four unique
locations. Repeated module-emission/compilation diagnostics are counted once
per location below. Paths are relative to `AyuGram/SGSettingsUI/Sources/`.

| Location in failed head | Exact compiler diagnostics | Relation to existing fixes |
| --- | --- | --- |
| `ExteraAppIconController.swift:514:18` | `overriding non-open instance method outside of its defining module`; `overriding declaration requires an 'override' keyword` | Already covered by private helper rename to `pushIconController`. |
| `ExteraFeedPostItem.swift:70:17` | `overriding property must be as accessible as its enclosing type`; `cannot override with a stored property 'inHierarchy'` | Already covered by local flag rename to `feedNodeIsInHierarchy`. |
| `ExteraSettingsOverviewController.swift:202:18` | `overriding non-open instance method outside of its defining module`; `overriding declaration requires an 'override' keyword` | Already covered by root's applied `pushOverviewController` rename. |
| `ExteraSpeechRecognitionController.swift:212:31` | `reference to captured var 'failure' in concurrently-executing code; this is an error in the Swift 6 language mode` | Already covered by immutable capture snapshot `[weak self, failure]`. |

`AyuReadHistoryController.swift:134:204`, the fifth location in the device run,
is not reported in this older simulator log. Its absence is not evidence that
the fix is unnecessary or that a newer head compiled successfully.

The remaining failure messages are consequences of these source errors:
`emit-module command failed with exit code 1`, the Bazel SwiftCompile action
failure, `Build did NOT complete successfully`, and Make.py's
`subprocess.CalledProcessError` / process exit 1. No additional source compiler
error was found in the retrieved failed log. Earlier warnings do not introduce
another fatal diagnostic in this run.

## Newer simulator run: single metadata check

One metadata request was made for
[45692132775](https://github.com/Nomadvorga/ayugram-ios/actions/runs/45692132775):

```sh
gh run view 45692132775 --json headSha,status,conclusion,url,displayTitle
```

The response at that check was:

```json
{
  "headSha": "030f9549d29daedcc94c5b03fbc23b2c2104c8d6",
  "status": "in_progress",
  "conclusion": "",
  "displayTitle": "Build IPA",
  "url": "https://github.com/Nomadvorga/ayugram-ios/actions/runs/45692132775"
}
```

It was not known completed, so no log was fetched for this run. No repeated
metadata request, polling, or watcher change was performed. The existing watcher
remains responsible for completion notification. This receipt records the
observed status only; it makes no claim about the run's later outcome.

## Ownership and validation receipt

The complete file manifest for this task is one new documentation file:
`docs/integration/extera-simulator-build-diagnosis.md`.

Validation extracted all source `error:` locations from the full old simulator
failed log and compared them with the five previously reported device locations:
four matched, zero additional locations. Non-source failure lines were also
reviewed. No production source, existing fix patch/manifest, frozen style file,
AI/root file, BUILD file, or workflow was edited. No commit or push was made.
This is log diagnosis, not a local rebuild or validation of the fixed head.
