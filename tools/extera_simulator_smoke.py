"""macOS-only, isolated simulator onboarding smoke; never logs in or drives account UI."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid
import zipfile


def version(value):
    parts = [int(part) for part in value.split(".")]
    return tuple((parts + [0, 0, 0])[:3])


def select_device(runtimes, devices, minimum):
    """Choose an available compatible iOS runtime and an ordinary iPhone type."""
    for runtime in sorted(runtimes, key=lambda item: version(item["version"]), reverse=True):
        if not runtime.get("isAvailable") or ".iOS-" not in runtime["identifier"]:
            continue
        runtime_version = version(runtime["version"])
        if runtime_version < version(minimum):
            continue
        encoded = (runtime_version[0] << 16) | (runtime_version[1] << 8) | runtime_version[2]
        supported = runtime.get("supportedDeviceTypes")
        supported_ids = {item["identifier"] if isinstance(item, dict) else item for item in supported or []}
        candidates = [
            device for device in devices
            if device["name"].startswith("iPhone")
            and "Duo" not in device["name"]
            and (not supported_ids or device["identifier"] in supported_ids)
            and device.get("minRuntimeVersion", 0) <= encoded
            and encoded <= device.get("maxRuntimeVersion", 0xFFFFFFFF)
        ]
        if candidates:
            # Prefer the newest ordinary iPhone generation, not a lexical-name winner
            # such as the much older "iPhone SE". Prefer the base model within a
            # generation; newer runtimes can omit it, in which case a Pro/Plus remains valid.
            def device_preference(item):
                name = item["name"]
                match = re.match(r"^iPhone (\d+)(?:\s|$)", name)
                if match:
                    generation = int(match.group(1))
                    suffix = name[match.end():].strip()
                    model_rank = 2 if not suffix else 1 if suffix.startswith("Pro") else 0
                    return generation, model_rank, name
                return 0, 0, name

            candidates.sort(key=device_preference, reverse=True)
            return runtime, candidates[0]
    raise RuntimeError(f"No available iOS runtime / iPhone pair supports minimum iOS {minimum}")


class Smoke:
    def __init__(self, args):
        self.args = args
        self.output = args.output.resolve()
        self.output.mkdir(parents=True, exist_ok=False)
        self.transcript = (self.output / "commands.log").open("w", encoding="utf-8")
        self.device = None
        self.recording = None
        self.stream = None
        self.handles = []
        self.pid = None
        self.executable = None
        self.started = time.time()
        self.report = {"status": "failed", "scope": "fresh install / onboarding launch only",
                       "commit": os.environ.get("GITHUB_SHA"),
                       "interactive_mcp": False, "authenticated_settings_and_chats": "not tested"}

    def run(self, *command, timeout=60, check=True):
        self.transcript.write(f"\n$ {shlex.join(str(part) for part in command)}\n")
        self.transcript.flush()
        result = subprocess.run([str(part) for part in command], text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
        self.transcript.write(result.stdout + f"\n[exit {result.returncode}]\n")
        self.transcript.flush()
        if check and result.returncode:
            raise RuntimeError(f"Command failed ({result.returncode}): {shlex.join(str(p) for p in command)}")
        return result.stdout

    def simctl(self, *command, **kwargs):
        return self.run("xcrun", "simctl", *command, **kwargs)

    def start_process(self, filename, *command):
        handle = (self.output / filename).open("w", encoding="utf-8")
        self.handles.append(handle)
        self.transcript.write(f"\n$ {shlex.join(command)} [background: {filename}]\n")
        self.transcript.flush()
        return subprocess.Popen(command, stdout=handle, stderr=subprocess.STDOUT)

    def stop_process(self, process, interrupt=False):
        if process is None:
            return None
        if process.poll() is None:
            process.send_signal(signal.SIGINT if interrupt else signal.SIGTERM)
        try:
            return process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
            raise RuntimeError("Own capture process failed to stop within 20 seconds")

    def verify_alive(self):
        # Simulator app PIDs are host PIDs. Check identity as well as liveness / zombie state.
        process = self.run("ps", "-p", str(self.pid), "-o", "pid=,stat=,comm=").strip()
        fields = process.split(None, 2)
        if len(fields) != 3 or int(fields[0]) != self.pid or "Z" in fields[1]:
            raise RuntimeError(f"Launched foreground process is no longer alive: {process}")
        if Path(fields[2]).name != self.executable:
            raise RuntimeError(f"Launched PID now identifies a different executable: {process}")

    def collect_crashes(self):
        if not self.device:
            return []
        destination = self.output / "crashes"
        destination.mkdir(exist_ok=True)
        roots = [Path.home() / "Library/Developer/CoreSimulator/Devices" / self.device / "data/Library/Logs/CrashReporter",
                 Path.home() / "Library/Logs/DiagnosticReports"]
        found = []
        for index, root in enumerate(roots):
            if not root.exists():
                continue
            for source in root.rglob("*"):
                if not source.is_file() or source.suffix not in (".ips", ".crash"):
                    continue
                if source.stat().st_mtime < self.started:
                    continue
                text = source.read_text(encoding="utf-8", errors="replace")
                # Host reports are shared: only take the exact launched PID's app report.
                own_pid = self.pid and re.search(rf'(?:"pid"\s*:\s*{self.pid}\b|Process:.*\[{self.pid}\])', text)
                own_name = self.executable and (self.executable in source.name or self.executable in text)
                if own_name and (index == 0 or own_pid):
                    target = destination / f"{index}-{source.name}"
                    shutil.copyfile(source, target)
                    found.append(target.name)
        return found

    def execute(self):
        if sys.platform != "darwin" or platform.machine() != "arm64":
            raise RuntimeError("Requires a native arm64 macOS runner with Xcode / iOS Simulator")
        ipa = self.args.ipa.absolute()
        # Explicitly restrict source to fresh published build outputs, never archive-root/bazel-out traversal.
        if "archive-root" in str(ipa) or not (
            ipa.parent == Path("build/artifacts").absolute()
            or ipa.parent == Path("bazel-bin/Telegram").absolute()
        ):
            raise RuntimeError("IPA must be directly in build/artifacts or bazel-bin/Telegram")
        build_started = float(self.args.build_start_file.read_text())
        if not ipa.is_file() or ipa.stat().st_mtime < build_started:
            raise RuntimeError("IPA is absent or older than this build's start marker")
        digest = hashlib.sha256()
        with ipa.open("rb") as archive:
            for chunk in iter(lambda: archive.read(1024 * 1024), b""):
                digest.update(chunk)
        self.report.update(ipa=str(ipa), ipa_sha256=digest.hexdigest(), build_started=build_started)
        self.run("xcodebuild", "-version")
        runtimes = json.loads(self.simctl("list", "runtimes", "--json"))
        devices = json.loads(self.simctl("list", "devicetypes", "--json"))
        (self.output / "runtimes.json").write_text(json.dumps(runtimes, indent=2))
        (self.output / "device-types.json").write_text(json.dumps(devices, indent=2))
        with tempfile.TemporaryDirectory(prefix="extera-simulator-") as temporary:
            stage = Path(temporary)
            with zipfile.ZipFile(ipa) as archive:
                for name in archive.namelist():
                    if name.startswith("/") or ".." in Path(name).parts:
                        raise RuntimeError("Unsafe path in IPA")
            self.run("ditto", "-xk", ipa, stage)
            apps = list((stage / "Payload").glob("*.app"))
            if len(apps) != 1:
                raise RuntimeError("Expected exactly one top-level .app in IPA")
            app = apps[0]
            with (app / "Info.plist").open("rb") as handle:
                info = plistlib.load(handle)
            bundle = info["CFBundleIdentifier"]
            self.executable = info["CFBundleExecutable"]
            if Path(self.executable).name != self.executable:
                raise RuntimeError("Invalid CFBundleExecutable")
            binary = app / self.executable
            archs = self.run("xcrun", "lipo", "-archs", binary).split()
            if "arm64" not in archs:
                raise RuntimeError("App does not contain arm64")
            macho = self.run("xcrun", "vtool", "-arch", "arm64", "-show-build", binary)
            (self.output / "macho-build-version.txt").write_text(macho)
            if not re.search(r"platform\s+(?:IOSSIMULATOR|7)\b", macho):
                raise RuntimeError("Mach-O arm64 platform is not IOSSIMULATOR (7)")
            if "iPhoneSimulator" not in info.get("CFBundleSupportedPlatforms", []):
                raise RuntimeError("App plist does not declare iPhoneSimulator")
            runtime, device_type = select_device(runtimes["runtimes"], devices["devicetypes"],
                                                 info.get("MinimumOSVersion", "0"))
            name = f"AyuGram-CI-{uuid.uuid4().hex[:12]}"
            # Retain the exact ID returned by our create; cleanup never enumerates/removes other devices.
            self.device = self.simctl("create", name, device_type["identifier"], runtime["identifier"]).strip()
            if not re.fullmatch(r"[0-9A-Fa-f-]{36}", self.device):
                self.device = None
                raise RuntimeError("simctl create returned an invalid device ID")
            self.report.update(device_udid=self.device, device_name=name, runtime=runtime,
                               device_type=device_type, bundle_id=bundle)
            self.simctl("boot", self.device)
            self.simctl("bootstatus", self.device, "-b", timeout=240)
            self.simctl("install", self.device, app, timeout=180)
            self.simctl("get_app_container", self.device, bundle, "app")
            self.stream = self.start_process(
                "simulator.log", "xcrun", "simctl", "spawn", self.device, "log", "stream",
                "--style", "compact", "--level", "info", "--predicate",
                f'process == "{self.executable}" OR process == "SpringBoard" OR process == "runningboardd"')
            self.recording = self.start_process(
                "recording.log", "xcrun", "simctl", "io", self.device, "recordVideo",
                "--codec=h264", "--force", str(self.output / "onboarding.mp4"))
            deadline = time.monotonic() + 30
            while "Recording started" not in (self.output / "recording.log").read_text():
                if self.recording.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("Native simctl recording did not start within 30 seconds")
                time.sleep(0.2)
            time.sleep(1)  # Short SpringBoard lead-in before a foreground launch.
            launched = self.simctl("launch", self.device, bundle)
            match = re.search(rf"{re.escape(bundle)}:\s*(\d+)\s*$", launched)
            if not match:
                raise RuntimeError("simctl launch did not return an app PID")
            self.pid = int(match[1])
            self.report.update(pid=self.pid, launch_mode="foreground (simctl launch without --background)")
            for _ in range(8):
                time.sleep(1)
                self.verify_alive()
            self.simctl("io", self.device, "screenshot", self.output / "onboarding.png")
            code = self.stop_process(self.recording, interrupt=True)
            self.recording = None
            if code != 0 or not (self.output / "onboarding.mp4").stat().st_size:
                raise RuntimeError(f"Native video capture failed (exit {code})")
            self.verify_alive()
            if self.stream.poll() is not None:
                raise RuntimeError("Simulator log stream exited unexpectedly")
            probe = shutil.which("ffprobe")
            if probe:
                timestamps = self.run(probe, "-v", "error", "-select_streams", "v:0", "-show_frames",
                                      "-show_entries", "frame=best_effort_timestamp_time,pts_time,pkt_dts_time",
                                      "-of", "json", self.output / "onboarding.mp4")
                parsed = json.loads(timestamps)
                if not parsed.get("frames"):
                    raise RuntimeError("ffprobe found no video frames")
                (self.output / "frame-timestamps.json").write_text(timestamps)
                self.report["frame_timestamps"] = "ffprobe frame-timestamps.json; variable rate, no FPS inferred"
            else:
                self.report["frame_timestamps"] = "ffprobe unavailable; no timing metrics measured"
            time.sleep(2)  # Allow CrashReporter to finish a report if the app just exited.
            self.verify_alive()
            crashes = self.collect_crashes()
            self.report["crashes"] = crashes
            if crashes:
                raise RuntimeError("Crash reports found for the smoke app")
            self.report["status"] = "passed"

    def finish(self):
        errors = []
        for process, interrupt in ((self.recording, True), (self.stream, False)):
            try:
                self.stop_process(process, interrupt)
            except Exception as error:
                errors.append(str(error))
        if self.device:
            # Logs and crash evidence precede deletion even when install/launch/capture failed.
            try:
                self.report["crashes"] = self.collect_crashes()
                self.simctl("spawn", self.device, "log", "show", "--last", "3m", "--style", "compact",
                            "--predicate", 'process == "SpringBoard" OR process == "runningboardd"',
                            timeout=30)
            except Exception as error:
                self.report.update(status="failed", diagnostic_error=str(error))
            for operation in ("shutdown", "delete"):
                try:
                    # Shutdown can fail if boot never completed; deletion must still be attempted.
                    self.simctl(operation, self.device, timeout=60, check=operation == "delete")
                except Exception as error:
                    errors.append(str(error))
        for handle in self.handles:
            handle.close()
        if self.report.get("crashes"):
            self.report["status"] = "failed"
            self.report.setdefault("error", "Crash reports found for the smoke app")
        if errors:
            self.report.update(status="failed", cleanup_errors=errors)
        (self.output / "result.json").write_text(json.dumps(self.report, indent=2) + "\n")
        self.transcript.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipa", type=Path, required=True)
    parser.add_argument("--build-start-file", type=Path, required=True,
                        help="File containing epoch seconds recorded before the successful build")
    parser.add_argument("--output", type=Path, required=True, help="New evidence directory (must not exist)")
    args = parser.parse_args()
    smoke = Smoke(args)
    # Python's finally performs scoped cleanup on normal CI termination as well as failures.
    def terminate(signum, frame):
        raise RuntimeError(f"Interrupted by signal {signum}")
    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGINT, terminate)
    try:
        smoke.execute()
    except Exception as error:
        smoke.report.update(status="failed", error=str(error))
        print(f"Simulator smoke failed: {error}", file=sys.stderr)
    finally:
        smoke.finish()
    print(json.dumps(smoke.report, indent=2))
    return 0 if smoke.report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
