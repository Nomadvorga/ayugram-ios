"""Link and exercise the pinned Vosk iOS Simulator archive in a fresh simulator."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
import wave
import zipfile


ROOT = Path(__file__).resolve().parents[2]
SDK_URL = "https://github.com/ishantve/VoskSpeechKit/releases/download/0.1.2/libvosk.xcframework.zip"
SDK_SHA256 = "1891ad61293278363f75f2b4e5313c606183d0acd14f4b1ff1a71f5629c676f9"
SDK_BYTES = 48_290_797
SIMULATOR_ARCHIVE_SHA256 = "7933cf4794fad8f066de78ed1b6f70797b41ce3f43b5944e151c6a1f6c08d76c"
SIMULATOR_SLICES = {
    "arm64": "873ec6ce80f1462909a3ba5441a26ef75614729c768a0e878ff88e1907a22e6d",
    "x86_64": "86c47a5c99d23c79b8bd922ccffc12d4896a68f86ffe248ad587d176f7ca580b",
}
MODEL_URL = "https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip"
MODEL_NAME = "vosk-model-small-en-us-0.15"
MODEL_SHA256 = "30f26242c4eb449f948e42cb302dd7a686cb29a3423a8367f99ff41780942498"
MODEL_BYTES = 41_205_931
MODEL_EXPANDED_BYTES = 70_898_967
MODEL_ENTRY_COUNT = 20
FIXTURE_URL = (
    "https://raw.githubusercontent.com/alphacep/vosk-api/"
    "4ab9821510b488efb7740094714a130bd3545e90/python/example/test.wav"
)
FIXTURE_SHA256 = "dcfea5712c43a43ba7ae8083afb39d36993e5a69c46e88b68aaa72b65cb615bb"
FIXTURE_BYTES = 265_914
BUNDLE_ID = "org.ayugram.extera.vosk-native-smoke"
REQUIRED_SYMBOLS = (
    "vosk_model_new",
    "vosk_model_free",
    "vosk_recognizer_new",
    "vosk_recognizer_accept_waveform",
    "vosk_recognizer_result",
    "vosk_recognizer_final_result",
    "vosk_recognizer_free",
    "vosk_set_log_level",
)


class SmokeFailure(RuntimeError):
    pass


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def write_json(path, value):
    temporary = path.with_suffix(path.suffix + ".partial")
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    temporary.replace(path)


def run(command, *, timeout=60, capture=True):
    command = [str(part) for part in command]
    print("$ " + " ".join(command), flush=True)
    result = subprocess.run(
        command,
        check=False,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
        text=True,
        timeout=timeout,
    )
    output = result.stdout or "" if capture else ""
    if output:
        print(output, end="" if output.endswith("\n") else "\n", flush=True)
    if result.returncode:
        raise SmokeFailure(f"Command exited {result.returncode}: {' '.join(command)}\n{output[-12000:]}")
    return output


def stream_command(command, log_path, *, timeout):
    command = [str(part) for part in command]
    print("$ " + " ".join(command), flush=True)
    with log_path.open("w", encoding="utf-8") as log:
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            assert process.stdout is not None
            for line in process.stdout:
                print(line, end="", flush=True)
                log.write(line)
                log.flush()
            return_code = process.wait(timeout=timeout)
        except BaseException:
            process.kill()
            process.wait()
            raise
    if return_code:
        tail = "\n".join(log_path.read_text(encoding="utf-8", errors="replace").splitlines()[-120:])
        raise SmokeFailure(f"Xcode build exited {return_code}; last output:\n{tail}")


def download_verified(url, path, byte_count, expected_sha256):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_file() and path.stat().st_size == byte_count and sha256_file(path) == expected_sha256:
        print(f"PASS: cached {path.name}, SHA-256 {expected_sha256}")
        return

    partial = path.with_suffix(path.suffix + ".partial")
    partial.unlink(missing_ok=True)
    last_error = None
    for attempt in range(1, 4):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "AyuGram-iOS-VoskSimulatorSmoke/1"})
            with urllib.request.urlopen(request, timeout=90) as response, partial.open("wb") as output:
                size = 0
                while block := response.read(1024 * 1024):
                    size += len(block)
                    if size > byte_count:
                        raise SmokeFailure(f"Download exceeded pinned byte count: {url}")
                    output.write(block)
            if partial.stat().st_size != byte_count or sha256_file(partial) != expected_sha256:
                raise SmokeFailure(
                    f"Checksum/size mismatch for {url}: bytes={partial.stat().st_size}, sha256={sha256_file(partial)}"
                )
            partial.replace(path)
            print(f"PASS: downloaded {path.name}, {byte_count} bytes, SHA-256 {expected_sha256}")
            return
        except Exception as error:
            last_error = error
            partial.unlink(missing_ok=True)
            print(f"Download attempt {attempt}/3 failed: {error}", flush=True)
    raise SmokeFailure(f"Could not acquire pinned artifact {url}: {last_error}")


def safe_zip_members(archive):
    for entry in archive.infolist():
        path = PurePosixPath(entry.filename)
        unix_mode = (entry.external_attr >> 16) & 0o170000
        if path.is_absolute() or ".." in path.parts or unix_mode == 0o120000:
            raise SmokeFailure(f"Unsafe ZIP entry: {entry.filename}")


def prepare_model(cache_dir):
    archive_path = cache_dir / (MODEL_NAME + ".zip")
    download_verified(MODEL_URL, archive_path, MODEL_BYTES, MODEL_SHA256)
    destination = cache_dir / "model"
    if destination.is_dir() and (destination / "am/final.mdl").is_file():
        return destination
    shutil.rmtree(destination, ignore_errors=True)
    destination.mkdir(parents=True)
    with zipfile.ZipFile(archive_path) as archive:
        safe_zip_members(archive)
        if archive.testzip() is not None:
            raise SmokeFailure("Pinned Vosk model ZIP has a CRC error")
        entries = archive.infolist()
        expanded = sum(entry.file_size for entry in entries)
        if len(entries) != MODEL_ENTRY_COUNT or expanded != MODEL_EXPANDED_BYTES:
            raise SmokeFailure(f"Unexpected model archive shape: entries={len(entries)}, expanded={expanded}")
        if any(PurePosixPath(entry.filename).parts[0] != MODEL_NAME for entry in entries):
            raise SmokeFailure("Model ZIP does not contain exactly the pinned root directory")
        archive.extractall(destination)
    model_path = destination / MODEL_NAME
    if not (model_path / "am/final.mdl").is_file():
        raise SmokeFailure("Expected acoustic model file is absent after verified extraction")
    print(f"PASS: extracted model {MODEL_NAME}, {expanded} bytes across {len(entries)} checked entries")
    return model_path


def prepare_audio(cache_dir):
    wav_path = cache_dir / "vosk-test.wav"
    download_verified(FIXTURE_URL, wav_path, FIXTURE_BYTES, FIXTURE_SHA256)
    pcm_path = cache_dir / "vosk-test.pcm"
    with wave.open(str(wav_path), "rb") as audio:
        format_info = {
            "channels": audio.getnchannels(),
            "sample_width_bytes": audio.getsampwidth(),
            "sample_rate_hz": audio.getframerate(),
            "frames": audio.getnframes(),
            "compression": audio.getcomptype(),
        }
        if format_info != {
            "channels": 1,
            "sample_width_bytes": 2,
            "sample_rate_hz": 16000,
            "frames": 132928,
            "compression": "NONE",
        }:
            raise SmokeFailure(f"Unexpected pinned speech fixture WAV format: {format_info}")
        pcm_path.write_bytes(audio.readframes(audio.getnframes()))
    if pcm_path.stat().st_size != format_info["frames"] * 2:
        raise SmokeFailure("Decoded PCM fixture length does not match WAV frame count")
    return pcm_path, format_info


def prepare_sdk(cache_dir, architecture):
    archive_path = cache_dir / "libvosk-0.1.2.xcframework.zip"
    download_verified(SDK_URL, archive_path, SDK_BYTES, SDK_SHA256)
    library_name = "libvosk.xcframework/ios-arm64_x86_64-simulator/libvosk.a"
    with zipfile.ZipFile(archive_path) as archive:
        safe_zip_members(archive)
        if archive.testzip() is not None:
            raise SmokeFailure("Pinned Vosk SDK ZIP has a CRC error")
        info = plistlib.loads(archive.read("libvosk.xcframework/Info.plist"))
        simulator = next(
            (item for item in info["AvailableLibraries"] if item.get("SupportedPlatformVariant") == "simulator"),
            None,
        )
        if not simulator or architecture not in simulator["SupportedArchitectures"]:
            raise SmokeFailure(f"SDK XCFramework has no {architecture} iOS Simulator slice")
        if library_name not in archive.namelist():
            raise SmokeFailure(f"SDK XCFramework library is absent: {library_name}")
        fat_path = cache_dir / "libvosk-simulator-fat.a"
        fat_path.write_bytes(archive.read(library_name))
    if sha256_file(fat_path) != SIMULATOR_ARCHIVE_SHA256:
        raise SmokeFailure("Simulator fat archive does not match the independently recorded SDK evidence")

    thin_path = cache_dir / "libvosk-simulator-thin.a"
    run(["xcrun", "lipo", "-thin", architecture, fat_path, "-output", thin_path])
    thin_sha = sha256_file(thin_path)
    if thin_sha != SIMULATOR_SLICES[architecture]:
        raise SmokeFailure(f"Unexpected {architecture} simulator slice SHA-256: {thin_sha}")
    library_dir = cache_dir / "link"
    library_dir.mkdir(exist_ok=True)
    shutil.copyfile(thin_path, library_dir / "libvosk.a")
    print(f"PASS: selected exact iOS Simulator {architecture} archive slice, SHA-256 {thin_sha}")
    return library_dir


def select_simulator_device():
    details = json.loads(run(["xcrun", "simctl", "list", "devices", "available", "--json"]))
    candidates = []
    for runtime, devices in details["devices"].items():
        match = re.search(r"iOS-(\d+)-(\d+)(?:-(\d+))?$", runtime)
        if not match:
            continue
        version = tuple(int(part or 0) for part in match.groups())
        for device in devices:
            if not device.get("isAvailable", True) or not device.get("deviceTypeIdentifier"):
                continue
            name = device.get("name", "")
            if not name.startswith("iPhone") or "Duo" in name:
                continue
            candidates.append((version, name, runtime, device["deviceTypeIdentifier"]))
    if not candidates:
        raise SmokeFailure("No available iPhone simulator runtime/device type found")

    def preference(candidate):
        version, name, _, _ = candidate
        generation_match = re.match(r"iPhone (\d+)", name)
        generation = int(generation_match.group(1)) if generation_match else 0
        suffix = name[generation_match.end():].strip() if generation_match else name
        model_rank = {"": 4, "Pro": 3, "Pro Max": 2, "Plus": 1, "Air": 0}.get(suffix, 0)
        return version, generation, model_rank, name

    return max(candidates, key=preference)


def build_simulator_app(output_dir, library_dir, architecture):
    project = ROOT / "Tests/ExteraVosk/SimulatorSmoke/VoskNativeSmoke.xcodeproj"
    derived = output_dir.parent / "VoskNativeSmokeDerivedData"
    shutil.rmtree(derived, ignore_errors=True)
    build_log = output_dir / "xcodebuild.log"
    command = [
        "xcodebuild",
        "-project", project,
        "-scheme", "VoskNativeSmoke",
        "-configuration", "Debug",
        "-sdk", "iphonesimulator",
        "-destination", "generic/platform=iOS Simulator",
        "-derivedDataPath", derived,
        "ARCHS=" + architecture,
        "ONLY_ACTIVE_ARCH=YES",
        "CODE_SIGNING_ALLOWED=NO",
        "LIBRARY_SEARCH_PATHS=" + str(library_dir),
        "HEADER_SEARCH_PATHS=" + str(ROOT / "submodules/VoskNative/include"),
        "OTHER_LDFLAGS=$(inherited) -lvosk -lc++ -framework Accelerate -framework UIKit -framework Foundation -lz",
        "build",
    ]
    stream_command(command, build_log, timeout=600)
    app_path = derived / "Build/Products/Debug-iphonesimulator/VoskNativeSmoke.app"
    executable = app_path / "VoskNativeSmoke"
    if not executable.is_file():
        raise SmokeFailure(f"Built simulator app executable is missing: {executable}")
    nm_output = run(["xcrun", "nm", "-gU", executable])
    defined = set()
    for line in nm_output.splitlines():
        fields = line.split()
        if len(fields) >= 2 and fields[-2].upper() != "U":
            defined.add(fields[-1].lstrip("_"))
    missing = sorted(set(REQUIRED_SYMBOLS) - defined)
    if missing:
        raise SmokeFailure("Simulator executable is missing linked Vosk symbols: " + ", ".join(missing))
    print("PASS: final simulator executable defines all eight Native Vosk C API symbols")
    return app_path, executable


def parse_native_report(path):
    try:
        events = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    except (OSError, json.JSONDecodeError) as error:
        raise SmokeFailure(f"Cannot read native recognizer JSONL report: {error}") from error
    event_names = [event.get("event") for event in events]
    if "error" in event_names:
        raise SmokeFailure("Native smoke emitted an error event: " + json.dumps(events, ensure_ascii=False))
    for required in ("model_loaded", "recognizer_created", "final", "complete"):
        if required not in event_names:
            raise SmokeFailure(f"Native smoke report lacks required event {required}: {event_names}")
    pieces = []
    for event in events:
        if event.get("event") in ("segment", "final"):
            value = event.get("value")
            if not isinstance(value, dict) or not isinstance(value.get("text"), str):
                raise SmokeFailure(f"Native recognizer result is malformed: {event}")
            text = value["text"].strip()
            if text:
                pieces.append(text)
    recognized_text = " ".join(pieces)
    if not recognized_text:
        raise SmokeFailure("Vosk loaded the model but recognized no text from the pinned speech fixture")
    return events, recognized_text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="Directory for CI-verifiable smoke evidence")
    args = parser.parse_args()
    if sys.platform != "darwin" or not shutil.which("xcrun") or not shutil.which("xcodebuild"):
        parser.error("This actual SDK smoke requires macOS with Xcode and iOS Simulator")
    if platform.machine() not in SIMULATOR_SLICES:
        parser.error(f"Unsupported simulator host architecture: {platform.machine()}")

    output_dir = args.output.resolve()
    output_dir.mkdir(parents=True, exist_ok=False)
    cache_dir = Path(tempfile.gettempdir()) / "extera-vosk-native-simulator-smoke"
    cache_dir.mkdir(parents=True, exist_ok=True)
    receipt = {
        "status": "running",
        "phase": "prepare",
        "platform": "iOS Simulator",
        "host_architecture": platform.machine(),
        "sdk": {"url": SDK_URL, "sha256": SDK_SHA256, "bytes": SDK_BYTES},
        "model": {
            "name": MODEL_NAME,
            "url": MODEL_URL,
            "sha256": MODEL_SHA256,
            "archive_bytes": MODEL_BYTES,
            "expanded_bytes": MODEL_EXPANDED_BYTES,
            "license": "Apache-2.0 (catalogue pin)",
        },
        "audio_fixture": {"url": FIXTURE_URL, "sha256": FIXTURE_SHA256, "bytes": FIXTURE_BYTES},
        "started_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    receipt_path = output_dir / "report.json"
    write_json(receipt_path, receipt)
    simulator_udid = None
    try:
        architecture = platform.machine()
        receipt["phase"] = "verified_inputs"
        library_dir = prepare_sdk(cache_dir, architecture)
        model_path = prepare_model(cache_dir)
        pcm_path, wav_format = prepare_audio(cache_dir)
        receipt["sdk"].update({
            "simulator_archive_sha256": SIMULATOR_ARCHIVE_SHA256,
            "architecture": architecture,
            "selected_slice_sha256": SIMULATOR_SLICES[architecture],
        })
        receipt["model"]["extracted_model_path"] = str(model_path.relative_to(cache_dir))
        receipt["audio_fixture"].update({
            "format": wav_format,
            "derived_pcm_sha256": sha256_file(pcm_path),
            "derived_pcm_bytes": pcm_path.stat().st_size,
        })

        xcode_version = run(["xcodebuild", "-version"])
        simulator_sdk_version = run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"]).strip()
        clang_version = run(["xcrun", "--sdk", "iphonesimulator", "clang", "--version"]).splitlines()[0]
        receipt["toolchain"] = {
            "xcode": xcode_version.strip(),
            "ios_simulator_sdk": simulator_sdk_version,
            "clang": clang_version,
        }

        receipt["phase"] = "debug_link"
        app_path, executable = build_simulator_app(output_dir, library_dir, architecture)
        receipt["sdk"]["linked_symbols"] = list(REQUIRED_SYMBOLS)
        receipt["sdk"]["simulator_executable_sha256"] = sha256_file(executable)
        shutil.copytree(model_path, app_path / "model")
        shutil.copyfile(pcm_path, app_path / "fixture.pcm")

        version, device_name, runtime, device_type = select_simulator_device()
        simulator_name = "AyuGram Vosk Native Smoke " + str(os.environ.get("GITHUB_RUN_ID", "local"))
        simulator_udid = run(["xcrun", "simctl", "create", simulator_name, device_type, runtime]).strip()
        receipt["simulator"] = {
            "name": simulator_name,
            "device_type": device_type,
            "compatible_device": device_name,
            "runtime": runtime,
            "runtime_version": ".".join(map(str, version)),
            "udid": simulator_udid,
        }

        receipt["phase"] = "simulator_boot"
        run(["xcrun", "simctl", "boot", simulator_udid])
        run(["xcrun", "simctl", "bootstatus", simulator_udid, "-b"], timeout=360)
        run(["xcrun", "simctl", "install", simulator_udid, app_path], timeout=180)
        data_container = Path(run(["xcrun", "simctl", "get_app_container", simulator_udid, BUNDLE_ID, "data"]).strip())
        cache_container = data_container / "Library/Caches"
        status_path = cache_container / "vosk-native-status.json"
        native_path = cache_container / "vosk-native-results.jsonl"

        receipt["phase"] = "native_recognition"
        launch_output = run(["xcrun", "simctl", "launch", simulator_udid, BUNDLE_ID], timeout=60)
        receipt["simulator"]["launch_output"] = launch_output.strip()
        write_json(receipt_path, receipt)
        deadline = time.monotonic() + 240
        while time.monotonic() < deadline and not status_path.is_file():
            time.sleep(1)
        if not status_path.is_file():
            raise SmokeFailure("Simulator app did not produce native smoke status within 240 seconds")
        app_status = json.loads(status_path.read_text(encoding="utf-8"))
        shutil.copyfile(native_path, output_dir / "native-results.jsonl")
        receipt["app_status"] = app_status
        if app_status.get("status") != "passed" or app_status.get("exit_code") != 0:
            raise SmokeFailure("Simulator app reported native Vosk failure: " + json.dumps(app_status))

        events, recognized_text = parse_native_report(native_path)
        receipt["native_events"] = events
        receipt["model_loaded"] = "model_loaded" in [event.get("event") for event in events]
        receipt["recognizer_created"] = "recognizer_created" in [event.get("event") for event in events]
        receipt["recognized_text"] = recognized_text
        receipt["phase"] = "complete"
        receipt["status"] = "passed"
        receipt["finished_at_utc"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        write_json(receipt_path, receipt)
        print(f"PASS: Vosk model loaded and recognizer created in {runtime} simulator {simulator_udid}")
        print("PASS: recognized text: " + recognized_text)
        print(f"PASS: evidence saved to {output_dir}")
    except Exception as error:
        receipt["status"] = "failed"
        receipt["error"] = str(error)
        receipt["finished_at_utc"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        write_json(receipt_path, receipt)
        raise
    finally:
        if simulator_udid:
            for command in (["shutdown", simulator_udid], ["delete", simulator_udid]):
                try:
                    run(["xcrun", "simctl", *command], timeout=90)
                except Exception as error:
                    print(f"WARNING: simulator cleanup failed: {error}", flush=True)


if __name__ == "__main__":
    main()
