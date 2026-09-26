#!/usr/bin/env python3
"""Run already-built physical-iPhone tests and keep a private, pollable record.

Build-for-testing is a separate step. Run commissioning while a person can
accept iOS permission/pairing prompts, then run full unattended with the phone
unlocked and WLED foreground. This script never builds, changes bonds, supplies
passkeys, or operates another BLE central. A skipped/empty HIL run is a failure.

Examples:
  python3 scripts/run_ble_hil.py --xctestrun build/.../wled_iphoneos27.0-arm64.xctestrun \
      --device DEVICE_UDID --mode commissioning
  python3 scripts/run_ble_hil.py --xctestrun build/.../wled_iphoneos27.0-arm64.xctestrun \
      --device DEVICE_UDID --mode full --soak-seconds 600
  python3 scripts/run_ble_hil.py --status build/phase2/runs/RUN_DIRECTORY

All runtime artifacts are private (directory 0700, files 0600). Console output
contains status and artifact paths, never raw Xcode output or test attachments.
"""
from __future__ import annotations

import argparse
import copy
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import sys
import time
from urllib.parse import urlsplit
import uuid


ROOT = Path(__file__).resolve().parents[1]
HARDWARE_CLASS = "BleHardwareTests"
METHODS = {"commissioning": "testCommissioningAndCapabilities",
           "functional": "testFunctionalAPIAndSoak",
           "reboot": "testRebootRecovery"}


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def private_json(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", encoding="utf-8") as output:
        json.dump(value, output, indent=2)
        output.write("\n")
    temporary.chmod(0o600)
    temporary.replace(path)


def source_fingerprints(root):
    """Hash source and checked-in configuration, never credentials or build data."""
    candidates = []
    for directory in (root / "wled", root / "wledTests", root / "scripts"):
        if directory.exists():
            candidates.extend(directory.rglob("*"))
    project = root / "wled.xcodeproj"
    candidates.extend([project / "project.pbxproj", project / "xcshareddata/xcschemes/wled.xcscheme",
                       project / "project.xcworkspace/xcshareddata/swiftpm/Package.resolved"])
    allowed = {".swift", ".py", ".plist", ".xcscheme", ".pbxproj", ".resolved", ".xcstrings"}
    result = {}
    for path in sorted(set(candidates)):
        if path.is_file() and not path.is_symlink() and "secret" not in path.name.lower():
            if path.suffix in allowed or path.name in ("contents", ".xccurrentversion"):
                result[str(path.relative_to(root))] = sha256(path)
    return result


def targets(document):
    if "TestConfigurations" in document:
        for configuration in document["TestConfigurations"]:
            if configuration.get("IsEnabled", True):
                yield from configuration.get("TestTargets", [])
    else:
        # Older version-1 xctestrun files use target names as root keys.
        for name, target in document.items():
            if not name.startswith("__") and isinstance(target, dict) and "TestBundlePath" in target:
                target.setdefault("BlueprintName", name)
                yield target


def rebase_testroot(value, original_root):
    if isinstance(value, str):
        return value.replace("__TESTROOT__", str(original_root))
    if isinstance(value, list):
        return [rebase_testroot(item, original_root) for item in value]
    if isinstance(value, dict):
        return {key: rebase_testroot(item, original_root) for key, item in value.items()}
    return value


def derive_configuration(base, original_root, mode, fixture):
    document = rebase_testroot(copy.deepcopy(base), original_root)
    test_targets = list(targets(document))
    if len(test_targets) != 1 or test_targets[0].get("BlueprintName") != "WLEDTests":
        raise ValueError("Expected exactly one enabled WLEDTests target/configuration")
    target = test_targets[0]
    if target.get("IsUITestBundle") or target.get("UseDestinationArtifacts"):
        raise ValueError("Expected an app-hosted, locally built unit-test bundle")
    environment = target.setdefault("EnvironmentVariables", {})
    testing_environment = target.setdefault("TestingEnvironmentVariables", {})
    for mapping in (environment, testing_environment):
        for key in list(mapping):
            if key.startswith("BLE_HIL"):
                del mapping[key]
    # Never inherit a shell-supplied opt-in. Unit mode always disables hardware.
    environment["BLE_HIL"] = "0" if mode == "unit" else "1"
    # Even mocked hosted tests must not let the normal UI auto-connect saved peers.
    environment["BLE_HIL_ISOLATE_APP"] = "1"
    if mode != "unit":
        environment.update(fixture)
    target["ParallelizationEnabled"] = False
    target["UserAttachmentLifetime"] = "keepAlways"
    target["SystemAttachmentLifetime"] = "keepNever"
    target.pop("OnlyTestIdentifiers", None)
    target.pop("SkipTestIdentifiers", None)
    if mode == "unit":
        target["SkipTestIdentifiers"] = [HARDWARE_CLASS]
    else:
        target["OnlyTestIdentifiers"] = [f"{HARDWARE_CLASS}/{METHODS[mode]}"]
    return document


def code_fingerprints(bundle):
    """Include Debug code dylibs and embedded Mach-O binaries, not just the launcher."""
    magic = {bytes.fromhex(value) for value in ("feedface", "cefaedfe", "feedfacf", "cffaedfe",
                                                "cafebabe", "bebafeca", "cafebabf", "bfbafeca")}
    result = []
    for path in sorted(bundle.rglob("*")):
        if not path.is_file() or path.is_symlink():
            continue
        with path.open("rb") as source:
            if source.read(4) not in magic:
                continue
        before = path.stat()
        digest = sha256(path)
        after = path.stat()
        if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
            raise ValueError("Built code changed while fingerprinting")
        result.append({"path": str(path.resolve()), "sha256": digest, "size_bytes": after.st_size,
                       "mtime_utc": datetime.fromtimestamp(after.st_mtime, timezone.utc).isoformat()})
    return result


def artifact_metadata(document):
    result = []
    for target in targets(document):
        host = target.get("TestHostPath", "")
        bundle = target.get("TestBundlePath", "").replace("__TESTHOST__", host)
        entry = {"target": target.get("BlueprintName"), "products": []}
        for kind, location in (("host", host), ("tests", bundle)):
            path = Path(location)
            # Xcode may use an executable as TestHostPath, not an .app path.
            info_path = path / "Info.plist" if path.is_dir() else path.parent / "Info.plist"
            if not info_path.is_file():
                raise ValueError(f"Missing built {kind} Info.plist")
            info = plistlib.loads(info_path.read_bytes())
            executable = info_path.parent / info.get("CFBundleExecutable", "")
            if not executable.is_file():
                raise ValueError(f"Missing built {kind} executable")
            allowed = ("CFBundleIdentifier", "CFBundleVersion", "CFBundleShortVersionString",
                       "MinimumOSVersion", "DTXcode", "DTXcodeBuild", "DTSDKName", "DTSDKBuild",
                       "DTPlatformName", "DTPlatformVersion")
            entry["products"].append({"kind": kind, "path": str(path),
                                      "executable_sha256": sha256(executable),
                                      "executable_mtime_utc": datetime.fromtimestamp(executable.stat().st_mtime, timezone.utc).isoformat(),
                                      "code_binaries": code_fingerprints(info_path.parent),
                                      "info": {key: info[key] for key in allowed if key in info}})
        result.append(entry)
    return result


def test_command(configuration, device, result_path, command_timeout):
    return ["xcodebuild", "test-without-building", "-xctestrun", str(configuration),
            "-destination", f"platform=iOS,id={device}", "-destination-timeout", "60",
            "-parallel-testing-enabled", "NO", "-parallel-testing-worker-count", "1",
            "-maximum-concurrent-test-device-destinations", "1", "-test-timeouts-enabled", "YES",
            "-maximum-test-execution-time-allowance", str(math.ceil(command_timeout)),
            "-resultBundlePath", str(result_path)]


def stop_process(process):
    """Give XCTest a chance to finish cleanup before escalating a stuck run."""
    for sig, wait_seconds in ((signal.SIGINT, 10), (signal.SIGTERM, 5), (signal.SIGKILL, 5)):
        if process.poll() is not None:
            return
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            return
        try:
            process.wait(timeout=wait_seconds)
            return
        except subprocess.TimeoutExpired:
            pass


def read_result_summary(path):
    result = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(path), "--compact"],
                            capture_output=True, text=True, timeout=30, check=True)
    raw = json.loads(result.stdout)
    # Failure messages and attachments remain in the private xcresult only.
    allowed = ("result", "totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures", "startTime", "finishTime")
    return {key: raw[key] for key in allowed if key in raw}


def result_passed(mode, returncode, summary):
    if returncode != 0 or summary.get("result") != "Passed" or summary.get("failedTests") != 0:
        return False
    if mode == "unit":
        return summary.get("passedTests", 0) > 0
    return summary.get("totalTestCount") == summary.get("passedTests") == 1 and summary.get("skippedTests") == 0


def run_stage(stage, run_directory, status, command_timeout):
    stage["started_utc"] = utc_now()
    stage["status"] = "running"
    started = time.monotonic()
    process = None
    last_console = -30.0
    log_path = Path(stage["log"])
    try:
        with log_path.open("xb") as log:
            log_path.chmod(0o600)
            process = subprocess.Popen(stage["command"], stdout=log, stderr=subprocess.STDOUT,
                                       cwd=ROOT, start_new_session=True)
            stage["pid"] = process.pid
            while process.poll() is None:
                elapsed = time.monotonic() - started
                stage["elapsed_seconds"] = round(elapsed, 1)
                stage["log_bytes"] = log_path.stat().st_size
                private_json(run_directory / "status.json", status)
                if elapsed - last_console >= 30:
                    print(json.dumps({"mode": stage["mode"], "status": "running", "elapsed_seconds": round(elapsed, 1),
                                      "log_bytes": stage["log_bytes"], "status_file": str(run_directory / "status.json")}), flush=True)
                    last_console = elapsed
                if elapsed >= command_timeout:
                    stage["status"] = "timed_out"
                    stop_process(process)
                    break
                time.sleep(1)
            stage["returncode"] = process.poll()
    except KeyboardInterrupt:
        stage["status"] = "interrupted"
        if process is not None:
            stop_process(process)
        raise
    except Exception as error:
        stage["status"] = "error"
        stage["error_type"] = type(error).__name__
        if process is not None:
            stop_process(process)
    finally:
        stage["elapsed_seconds"] = round(time.monotonic() - started, 1)
        stage["finished_utc"] = utc_now()
        if stage["status"] == "running":
            stage["status"] = "failed"
        try:
            stage["summary"] = read_result_summary(Path(stage["xcresult"]))
            if stage["status"] == "failed" and result_passed(stage["mode"], stage.get("returncode"), stage["summary"]):
                stage["status"] = "passed"
        except Exception as error:
            stage["result_error_type"] = type(error).__name__
        private_json(run_directory / "status.json", status)
    return stage["status"] == "passed"


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--status", type=Path, help="Read a previous run's status; no commands are executed")
    parser.add_argument("--xctestrun", type=Path, help="Signed build-for-testing output; never modified")
    parser.add_argument("--device", help="Physical iPhone UDID")
    parser.add_argument("--mode", choices=("commissioning", "functional", "reboot", "unit", "full"), default="full")
    parser.add_argument("--output", type=Path, help="New run directory; defaults to build/phase2/runs/<unique timestamp>")
    parser.add_argument("--fixture-name", default="WLED-db2cb8")
    parser.add_argument("--mac", default="a4cb8fdb2cb8")
    parser.add_argument("--http-url", default="http://10.10.41.74")
    parser.add_argument("--peripheral-id", help="Optional iPhone-local CoreBluetooth UUID, never the Mac UUID")
    parser.add_argument("--soak-seconds", type=int, default=600)
    parser.add_argument("--seed", type=int, default=20260925)
    parser.add_argument("--command-timeout", type=float, help="Whole xcodebuild timeout per stage; default max(600, soak+1500)")
    parser.add_argument("--prepare-only", action="store_true", help="Write configurations/manifests without running any commands or accessing hardware")
    args = parser.parse_args(argv)
    if args.status:
        return args
    if not args.xctestrun or not args.device:
        parser.error("--xctestrun and --device are required")
    args.xctestrun = args.xctestrun.resolve()
    if not args.xctestrun.is_file():
        parser.error("--xctestrun does not exist")
    if not re.fullmatch(r"[A-Za-z0-9-]+", args.device):
        parser.error("invalid device identifier")
    args.mac = args.mac.lower().replace(":", "").replace("-", "")
    if not re.fullmatch(r"[0-9a-f]{12}", args.mac):
        parser.error("--mac must contain exactly 12 hex digits")
    if not 0 <= args.soak_seconds <= 3600 or not 0 <= args.seed <= (2**64 - 1):
        parser.error("soak must be 0..3600 seconds and seed must be an unsigned 64-bit integer")
    if not args.fixture_name or any(ord(char) < 32 for char in args.fixture_name):
        parser.error("invalid fixture name")
    try:
        url = urlsplit(args.http_url)
        if url.scheme not in ("http", "https") or not url.hostname or url.username or url.password or url.query or url.fragment or url.path not in ("", "/"):
            raise ValueError()
        if url.port is not None and not 1 <= url.port <= 65535:
            raise ValueError()
        if args.peripheral_id:
            args.peripheral_id = str(uuid.UUID(args.peripheral_id))
    except ValueError:
        parser.error("invalid HTTP origin or peripheral UUID")
    if args.command_timeout is None:
        args.command_timeout = max(600, args.soak_seconds + 1500)
    if not math.isfinite(args.command_timeout) or args.command_timeout < 1:
        parser.error("--command-timeout must be positive and finite")
    return args


def main(argv=None):
    args = parse_args(argv)
    if args.status:
        print((args.status / "status.json").read_text())
        return 0
    os.umask(0o077)
    run_directory = (args.output or ROOT / "build/phase2/runs" / (
        datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + args.mode + "-" + uuid.uuid4().hex[:6])).resolve()
    run_directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    (run_directory / ".gitignore").write_text("*\n")
    with args.xctestrun.open("rb") as source:
        base = plistlib.load(source)
    fixture = {"BLE_HIL_NAME": args.fixture_name, "BLE_HIL_MAC": args.mac,
               "BLE_HIL_HTTP_URL": args.http_url, "BLE_HIL_SOAK_SECONDS": str(args.soak_seconds),
               "BLE_HIL_SEED": str(args.seed)}
    if args.peripheral_id:
        fixture["BLE_HIL_PERIPHERAL_ID"] = args.peripheral_id
    modes = ("unit", "functional", "reboot") if args.mode == "full" else (args.mode,)
    status = {"status": "prepared", "started_utc": utc_now(), "directory": str(run_directory), "stages": []}
    metadata = {"input_xctestrun": str(args.xctestrun), "input_xctestrun_sha256": sha256(args.xctestrun),
                "source_sha256": source_fingerprints(ROOT), "device": args.device, "fixture": fixture,
                "mode": args.mode, "command_timeout_seconds": args.command_timeout,
                "notes": ["Source hashes describe checkout at preparation time; binary hashes identify what actually runs.",
                          "Commissioning is separate and may require user interaction. Full runs unit, functional/soak, then reboot recovery.",
                          "Keep the physical phone unlocked, powered, and foreground; disconnect every other BLE central.",
                          "Private xcodebuild logs and xcresult may contain device metadata and test attachments."]}
    for mode in modes:
        derived = derive_configuration(base, args.xctestrun.parent, mode, fixture)
        configuration = run_directory / f"{mode}.xctestrun"
        with configuration.open("xb") as output:
            plistlib.dump(derived, output)
        configuration.chmod(0o600)
        if "build_artifacts" not in metadata:
            metadata["build_artifacts"] = artifact_metadata(derived)
        stage = {"mode": mode, "status": "pending", "configuration": str(configuration),
                 "configuration_sha256": sha256(configuration), "xcresult": str(run_directory / f"{mode}.xcresult"),
                 "log": str(run_directory / f"{mode}.log")}
        stage["command"] = test_command(configuration, args.device, Path(stage["xcresult"]), args.command_timeout)
        status["stages"].append(stage)
    private_json(run_directory / "metadata.json", metadata)
    private_json(run_directory / "status.json", status)
    print(json.dumps({"status": "prepared", "directory": str(run_directory), "modes": modes}), flush=True)
    if args.prepare_only:
        return 0
    status["status"] = "running"
    try:
        for stage in status["stages"]:
            if not run_stage(stage, run_directory, status, args.command_timeout):
                status["status"] = "failed"
                break
        else:
            status["status"] = "passed"
    except KeyboardInterrupt:
        status["status"] = "interrupted"
    finally:
        status["finished_utc"] = utc_now()
        private_json(run_directory / "status.json", status)
        print(json.dumps({"status": status["status"], "directory": str(run_directory),
                          "stages": [{"mode": item["mode"], "status": item["status"], "summary": item.get("summary")}
                                     for item in status["stages"]]}), flush=True)
    return 0 if status["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
