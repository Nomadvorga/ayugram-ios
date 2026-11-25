# Simulator validation on the xcode-27 runner

The **Build IPA** workflow offers `debug_sim_arm64` and `release_sim_arm64` through
`workflow_dispatch`, alongside the existing device configurations. Both simulator
configurations are implemented by `Make.py` (`set_configuration` uses
`--ios_multi_cpus=sim_arm64`, with `dbg` or `opt`). Push builds still default to
`debug_arm64`. The existing `xcode-27` runner must be an Apple Silicon Mac with an
available iOS Simulator runtime; this workflow does not download runtimes.

Choose a simulator configuration in GitHub Actions → Build IPA → Run workflow.
After the normal full app build, `tools/extera_simulator_smoke.py` performs an
isolated smoke run. A failed assertion returns exit code 1 and fails the job.
Evidence uploads run even after smoke failure; uploading evidence or an IPA does
not change the failed smoke result. Disk cache keys **and directories** include
the configuration, separating simulator/device and debug/release results. The
repository download cache remains shared. No additional `.bazelrc` changes are
introduced by simulator validation.

## What runs automatically

1. Record a build-start marker before invoking `Make.py`. After success, rename
   its exact `build/artifacts/Swiftgram.ipa` output to `AyuGram.ipa` and install
   that fresh IPA, requiring its mtime to be at least the
   marker time and recording its SHA-256. The script also accepts an explicit
   `bazel-bin/Telegram/*.ipa` with that freshness requirement. It never searches
   `bazel-out` or installs an `archive-root` bundle. Bazel cache hits can preserve
   an old source mtime: use the wrapper's fresh copy in `build/artifacts` in that
   case; the script fails conservatively on an old direct `bazel-bin` file.
2. Extract to a private temporary directory. Check the main Mach-O arm64 slice
   with `vtool`: platform must be `IOSSIMULATOR` (numeric 7). Also require
   `iPhoneSimulator` in the app plist. `lipo -archs` alone is insufficient because
   physical-device binaries can also be arm64.
3. Select the newest **available** iOS runtime compatible with `MinimumOSVersion`
   and a supported ordinary iPhone device type. Create a uniquely named
   `AyuGram-CI-*` device, boot it with a bounded wait, and install the extracted
   `.app`. No pre-existing simulator is used or altered.
4. Start an app/SpringBoard/runningboard log stream and native
   `xcrun simctl io <owned-udid> recordVideo --codec=h264`. Wait up to 30 seconds
   for recording readiness, record a one-second SpringBoard lead-in, then issue
   `simctl launch <owned-udid> <bundle-id>` in its default foreground mode.
   Check the returned PID, executable identity and non-zombie liveness once per
   second for eight seconds. Take `onboarding.png`, finalize the recording with
   SIGINT, and check the same process again. No login, taps, URL navigation,
   keyboard input, permission grants, or account actions are performed.
5. If `ffprobe` is installed, export its per-frame timestamps and require at
   least one video frame. Otherwise report that timestamps were not measured.
   Recording is variable-rate: there is no assumed 30/60 FPS or invented latency,
   smoothness, frame-drop, or animation metric.
6. Save crash reports belonging to the new device / exact launched host PID and
   bounded system log evidence before deleting the device. A matching app crash
   fails the run. Cleanup stops only the capture subprocesses it created,
   shuts down/deletes only the UUID returned by its own `simctl create`, and
   removes its extraction temporary directory. It never uses `delete unavailable`,
   `erase all`, `shutdown all`, or a shared user simulator. SIGTERM/SIGINT trigger
   this cleanup too. An uncatchable process/host kill can leave the uniquely
   named device behind; cleanup failures are reported as job failures.

Before viewing the recording, expect SpringBoard followed by the app's first-run
launch/onboarding surface, with the app still alive at the end. The PNG and video
are evidence for a human to inspect for blank screens, clipping, launch flashes
or unexpected prompts. Automatic liveness does not assert pixels or accessibility
content. The launch command requests foreground; this is not an independent
accessibility assertion of the frontmost screen or a UI responsiveness test.

## Scope and evidence

A new device has no Telegram account. **This smoke covers launch/onboarding, not
Extera settings, settings animations, authenticated chats, or account behaviour.**
There is no interactive XcodeBuildMCP session on the runner. A passing smoke must
not be reported as visual validation of `SGSettingsController` or its settings
animations. Those need a separately authorized, already authenticated simulator
and real UI interaction, followed by inspection of recorded frames under
`AGENTS.md`. No automated login is attempted.

Download `AyuGram-simulator-evidence-<configuration>-<run-number>` for:

- `result.json`: passed/failed, actual runtime/type/UUID, bundle ID, launched PID,
  source IPA hash, GitHub commit, scope, crash list, errors, and timestamp availability.
- `commands.log`, `simulator.log`, `recording.log`: commands, exit codes, native
  recording output, app/system logs. On early failure, only evidence collected up
  to that point exists; absence of a screenshot/video is not a pass.
- `macho-build-version.txt`, `runtimes.json`, `device-types.json`: input/platform
  and simulator selection evidence.
- `onboarding.png`, `onboarding.mp4`, and, when available,
  `frame-timestamps.json` from **ffprobe**. Do not substitute ffmpeg frame times.
- `crashes/`: matching new app crash reports, if any.

## Local checks and rerun

CLI help is portable and does not create a simulator:

```sh
python3 tools/extera_simulator_smoke.py --help
python3 -c 'import ast, pathlib; ast.parse(pathlib.Path("tools/extera_simulator_smoke.py").read_text())'
```

On an arm64 Mac, write a marker **before** a successful full simulator build using
the repository's usual Make.py arguments and `--outputBuildArtifactsPath=build/artifacts`:

```sh
mkdir -p build
python3 -c 'import pathlib,time; pathlib.Path("build/simulator-build-start.txt").write_text(str(time.time()))'
# Run the normal Make.py build --configuration=debug_sim_arm64 ... here.
python3 tools/extera_simulator_smoke.py \
  --ipa build/artifacts/Swiftgram.ipa \
  --build-start-file build/simulator-build-start.txt \
  --output build/simulator-validation-local-1
```

The evidence directory must not already exist, preventing a new run from
overwriting prior evidence. Use a new output name for each local run. Windows
can check syntax and CLI behaviour; it cannot execute the simulator stage.
