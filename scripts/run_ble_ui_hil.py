#!/usr/bin/env python3
"""Run already-built iPhone UI HIL with an independent Mac HTTP observer.

Requires a signed build-for-testing of scheme wled-ble-ui, the already-bonded
iPhone unlocked, and no other BLE central. Saves private artifacts before any
mutation, disables runtime UDP sending while native UI writes run, and restores
the exact HTTP baseline even if XCTest fails. No configuration is persisted.

Example:
  python3 scripts/run_ble_ui_hil.py --xctestrun build/.../wled-ble-ui.xctestrun \
      --device 00008140-000818111AE3001C

The UI runner never receives network credentials or a passkey. --prepare-only
requires a previously captured /json snapshot via --baseline-json and executes
no commands or network operations. --status DIR reads an existing status file.
"""
from __future__ import annotations

import argparse
import asyncio
import copy
import ipaddress
import json
import math
import os
from pathlib import Path
import plistlib
import re
import signal
import time
from urllib.parse import urlsplit
import uuid

import run_ble_hil as common


MAX_BODY = 262144
SELECTOR = "BleUserInterfaceTests/testNativeBluetoothControlsAndForegroundReconnect"
CORE_FIELDS = ("on", "bri", "transition", "bs", "ps", "pl", "ledmap", "nl", "udpn", "lor", "mainseg", "seg")


class CheckFailure(RuntimeError):
    pass


def check(condition, message):
    if not condition:
        raise CheckFailure(message)


def normalize_mac(value):
    value = value.lower().replace(":", "").replace("-", "") if isinstance(value, str) else ""
    check(re.fullmatch(r"[0-9a-f]{12}", value) is not None, "Missing or invalid MAC identity")
    return value


def projection(state):
    """Core JSON API state, including every field of every serialized segment.

    Excludes transient error flags and usermod telemetry such as connected/live.
    No serialized core field is dropped from the segment dictionaries.
    """
    return copy.deepcopy({key: state[key] for key in CORE_FIELDS if key in state})


def validate_snapshot(value, expected_mac):
    check(isinstance(value, dict) and isinstance(value.get("state"), dict) and isinstance(value.get("info"), dict),
          "HTTP response lacks state/info objects")
    check(normalize_mac(value["info"].get("mac")) == expected_mac, "Fixture MAC identity mismatch")
    check(type(value["info"].get("uptime")) is int and value["info"]["uptime"] >= 0, "Fixture lacks uptime")
    return value


def fixture_baseline(snapshot, expected_mac):
    validate_snapshot(snapshot, expected_mac)
    state, info = snapshot["state"], snapshot["info"]
    check(type(state.get("ps")) is int and state["ps"] <= 0, "Active preset is unsupported")
    check(type(state.get("pl")) is int and state["pl"] < 0, "Active playlist is unsupported")
    check(isinstance(state.get("nl"), dict) and state["nl"].get("on") is False, "Active or unknown nightlight is unsupported")
    check(info.get("live") is False, "Active or unknown realtime input is unsupported")
    check(type(state.get("on")) is bool and type(state.get("bri")) is int and 1 <= state["bri"] <= 255,
          "Fixture lacks restorable global power/brightness")
    check(isinstance(state.get("udpn"), dict) and type(state["udpn"].get("send")) is bool,
          "Fixture lacks runtime UDP send flag")
    segments = state.get("seg")
    check(isinstance(segments, list) and segments, "Fixture lacks active segments")
    ids = set()
    for segment in segments:
        check(isinstance(segment, dict) and type(segment.get("id")) is int and type(segment.get("frz")) is bool,
              "Every segment must expose ID and freeze flag")
        check(segment["id"] not in ids, "Duplicate segment IDs")
        ids.add(segment["id"])
    return {
        "schema": 1, "expected_mac": expected_mac, "captured_utc": common.utc_now(),
        "projection": projection(state),
        "restore": {"on": state["on"], "bri": state["bri"],
                    "seg": [{"id": segment["id"], "frz": segment["frz"]} for segment in segments],
                    "udpn": {"send": state["udpn"]["send"]}},
        "info": {key: info[key] for key in ("mac", "name", "ver", "vid", "uptime", "live") if key in info},
    }


class HttpOracle:
    """Literal-IP HTTP with a three-second absolute request/body budget."""

    def __init__(self, origin, expected_mac):
        url = urlsplit(origin)
        check(url.scheme == "http" and url.path in ("", "/") and not any((url.username, url.password, url.query, url.fragment)),
              "Use an HTTP literal-IP origin without credentials/path/query")
        self.host = str(ipaddress.ip_address(url.hostname))
        self.port = url.port or 80
        check(1 <= self.port <= 65535, "Invalid HTTP port")
        self.expected_mac = expected_mac

    async def request(self, update=None):
        writer = None
        try:
            async with asyncio.timeout(3):
                reader, writer = await asyncio.open_connection(self.host, self.port, limit=16384)
                authority = f"[{self.host}]" if ":" in self.host else self.host
                body = b"" if update is None else json.dumps(update, separators=(",", ":"), allow_nan=False).encode()
                method = "GET" if update is None else "POST"
                headers = (f"{method} /json HTTP/1.1\r\nHost: {authority}:{self.port}\r\n"
                           "Accept: application/json\r\nConnection: close\r\n")
                if update is not None:
                    headers += f"Content-Type: application/json\r\nContent-Length: {len(body)}\r\n"
                writer.write(headers.encode("ascii") + b"\r\n" + body)
                await writer.drain()
                header = await reader.readuntil(b"\r\n\r\n")
                lines = header.split(b"\r\n")
                status = lines[0].split()
                check(len(status) >= 2 and status[1] == b"200", "HTTP request returned a non-200 status")
                fields = {}
                for line in lines[1:]:
                    if line:
                        key, value = line.split(b":", 1)
                        fields[key.lower()] = value.strip().lower()
                payload = bytearray()
                if fields.get(b"transfer-encoding") == b"chunked":
                    while True:
                        size = int((await reader.readuntil(b"\r\n")).split(b";", 1)[0].strip(), 16)
                        check(0 <= size <= MAX_BODY - len(payload), "HTTP body exceeds 256 KiB")
                        if size == 0:
                            break
                        payload.extend(await reader.readexactly(size))
                        check(await reader.readexactly(2) == b"\r\n", "Invalid chunk terminator")
                elif b"content-length" in fields:
                    size = int(fields[b"content-length"])
                    check(0 <= size <= MAX_BODY, "HTTP body exceeds 256 KiB")
                    payload.extend(await reader.readexactly(size))
                else:
                    while chunk := await reader.read(min(8192, MAX_BODY + 1 - len(payload))):
                        payload.extend(chunk)
                        check(len(payload) <= MAX_BODY, "HTTP body exceeds 256 KiB")
                return validate_snapshot(json.loads(payload), self.expected_mac)
        finally:
            if writer is not None:
                writer.close()
                try:
                    async with asyncio.timeout(0.2):
                        await writer.wait_closed()
                except (Exception, asyncio.CancelledError):
                    pass

    async def write(self, update):
        await self.request()  # Identity proof immediately before every mutation.
        payload = copy.deepcopy(update)
        payload["tt"] = 0
        payload["v"] = True
        payload["udpn"] = {**payload.get("udpn", {}), "nn": True}
        return await self.request(payload)


def ui_configuration(base, source_root, args, baseline):
    document = common.rebase_testroot(copy.deepcopy(base), source_root)
    targets = list(common.targets(document))
    check(len(targets) == 1 and targets[0].get("BlueprintName") == "WLEDUIHILTests", "Expected exactly one enabled WLEDUIHILTests target")
    target = targets[0]
    check(target.get("IsUITestBundle") is True and bool(target.get("UITargetAppPath")), "Expected a locally built UI test bundle and target app")
    check(not target.get("UseDestinationArtifacts"), "Destination-only artifacts are unsupported")
    environment = target.setdefault("EnvironmentVariables", {})
    for mapping in (environment, target.setdefault("TestingEnvironmentVariables", {}), target.setdefault("UITargetAppEnvironmentVariables", {})):
        for key in list(mapping):
            if key.startswith(("BLE_HIL", "BLE_UI_")):
                del mapping[key]
    environment.update({"BLE_UI_HIL": "1", "BLE_UI_MAC": args.mac, "BLE_UI_NAME": args.advertised_name,
                        "BLE_UI_DEVICE_NAME": args.device_name or baseline["info"].get("name") or "WLED"})
    if getattr(args, "fallback_address", None):
        environment["BLE_UI_FALLBACK_ADDRESS"] = args.fallback_address
    if args.brightness:
        environment["BLE_UI_BRIGHTNESS"] = str(baseline["restore"]["bri"])
    target["ParallelizationEnabled"] = False
    target["UserAttachmentLifetime"] = "keepAlways"
    target["SystemAttachmentLifetime"] = "keepNever"
    target["OnlyTestIdentifiers"] = [SELECTOR]
    target.pop("SkipTestIdentifiers", None)
    return document


def build_metadata(document):
    metadata = common.artifact_metadata(document)
    target = next(common.targets(document))
    app = Path(target["UITargetAppPath"])
    info = plistlib.loads((app / "Info.plist").read_bytes())
    check(info.get("DTPlatformName") == "iphoneos", "UI target app is not an iPhoneOS build")
    executable = app / info["CFBundleExecutable"]
    metadata.append({"target_app": str(app), "executable_sha256": common.sha256(executable),
                     "code_binaries": common.code_fingerprints(app),
                     "info": {key: info[key] for key in ("CFBundleIdentifier", "CFBundleVersion", "DTXcode", "DTXcodeBuild", "DTSDKName", "DTSDKBuild") if key in info}})
    return metadata


def command_for(configuration, args, output):
    return common.test_command(configuration, args.device, output / "ui.xcresult", args.timeout)


def evidence(samples, baseline, brightness):
    observed = [sample for sample in samples if sample.get("ok")]
    powers = {sample["on"] for sample in observed}
    changed_brightness = any(sample["bri"] != baseline["restore"]["bri"] for sample in observed)
    uptimes = [baseline["info"]["uptime"], *(sample["uptime"] for sample in observed)]
    rollbacks = [(before, after) for before, after in zip(uptimes, uptimes[1:]) if after < before]
    return {"successful_samples": len(observed), "failed_samples": len(samples) - len(observed),
            "observed_power_off": False in powers, "observed_power_on": True in powers,
            "observed_brightness_change": changed_brightness, "brightness_required": brightness,
            "uptime_rollbacks": rollbacks,
            "passed": powers == {False, True} and (changed_brightness or not brightness) and not rollbacks}


async def stop_process(process):
    if process is None or process.returncode is not None:
        return
    for sig, seconds in ((signal.SIGINT, 10), (signal.SIGTERM, 5), (signal.SIGKILL, 3)):
        if process.returncode is not None:
            return
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            return
        try:
            await asyncio.wait_for(process.wait(), seconds)
            return
        except TimeoutError:
            pass
    raise CheckFailure("Xcode process did not terminate within cleanup deadline")


async def restore(oracle, baseline, report):
    report["restoration_attempts"] = []
    for attempt in range(1, 4):
        item = {"attempt": attempt, "started_utc": common.utc_now()}
        report["restoration_attempts"].append(item)
        try:
            await oracle.write(baseline["restore"])
            first = await oracle.request()
            check(projection(first["state"]) == baseline["projection"], "Core API projection differs after restoration")
            await asyncio.sleep(1)
            second = await oracle.request()
            check(projection(second["state"]) == baseline["projection"], "Restored core API projection did not remain stable")
            item["status"] = "verified"
            report["restored_exact"] = True
            return
        except Exception as error:
            item["status"] = "failed"
            item["error_type"] = type(error).__name__
            if isinstance(error, CheckFailure):
                item["reason"] = str(error)
            await asyncio.sleep(0.5)
    report["restored_exact"] = False


async def shield_cleanup(operation):
    task = asyncio.create_task(operation)
    while True:
        try:
            return await asyncio.shield(task)
        except asyncio.CancelledError:
            if task.done():
                return task.result()
            # Repeated task cancellation must not interrupt the authorized restore.
            continue


async def run(args, output, report):
    oracle = HttpOracle(args.http_url, args.mac)
    process = None
    baseline = None
    touched = False
    started = time.monotonic()
    samples = report["samples"] = []
    report["restored_exact"] = False
    try:
        raw = json.loads(args.baseline_json.read_text()) if args.prepare_only else await oracle.request()
        baseline = fixture_baseline(raw, args.mac)
        common.private_json(output / "baseline.json", baseline)
        base = plistlib.loads(args.xctestrun.read_bytes())
        configuration = ui_configuration(base, args.xctestrun.parent, args, baseline)
        path = output / "ui.xctestrun"
        with path.open("xb") as stream:
            plistlib.dump(configuration, stream)
        path.chmod(0o600)
        hashes = common.source_fingerprints(common.ROOT)
        for source in sorted((common.ROOT / "wledUITests").rglob("*.swift")):
            hashes[str(source.relative_to(common.ROOT))] = common.sha256(source)
        scheme = common.ROOT / "wled.xcodeproj/xcshareddata/xcschemes/wled-ble-ui.xcscheme"
        hashes[str(scheme.relative_to(common.ROOT))] = common.sha256(scheme)
        command = command_for(path, args, output)
        common.private_json(output / "metadata.json", {
            "source_sha256": hashes, "build_artifacts": build_metadata(configuration),
            "input_xctestrun": str(args.xctestrun), "input_xctestrun_sha256": common.sha256(args.xctestrun),
            "configuration_sha256": common.sha256(path), "command": command, "device": args.device,
            "expected_mac": args.mac, "poll_interval_seconds": args.interval,
            "notes": ["Core API projection excludes transient error flags and usermod connection telemetry.",
                      "Source hashes describe preparation time; binary hashes identify what actually executes.",
                      "UI handles saved-app connection preference; Mac HTTP restores device state.",
                      "No passkeys, credentials, cfg or raw Bluetooth payloads are captured."]})
        if args.prepare_only:
            report["status"] = "prepared_no_hardware"
            return
        # Record restoration responsibility BEFORE sending an ambiguously applied POST.
        touched = True
        suppressed = await oracle.write({"udpn": {"send": False}})
        check(suppressed["state"].get("udpn", {}).get("send") is False, "Runtime UDP sending was not disabled")
        expected = copy.deepcopy(baseline["projection"])
        expected["udpn"]["send"] = False
        check(projection(suppressed["state"]) == expected, "UDP suppression changed another core API field")
        report["status"] = "running"
        common.private_json(output / "status.json", report)
        last_console = -30.0
        with (output / "xcodebuild.log").open("xb") as log:
            process = await asyncio.create_subprocess_exec(*command, stdout=log, stderr=log, cwd=common.ROOT, start_new_session=True)
            report["pid"] = process.pid
            with (output / "http-samples.jsonl").open("x") as observations:
                while process.returncode is None:
                    elapsed = time.monotonic() - started
                    if elapsed >= args.timeout:
                        report["status"] = "timed_out"
                        break
                    began = time.monotonic()
                    sample = {"elapsed_seconds": round(elapsed, 3), "ok": False}
                    try:
                        snapshot = await oracle.request()
                        state, info = snapshot["state"], snapshot["info"]
                        check(type(state.get("on")) is bool and type(state.get("bri")) is int, "Malformed power/brightness observation")
                        check(state.get("udpn", {}).get("send") is False, "Runtime UDP suppression changed during UI test")
                        sample.update({"ok": True, "on": state["on"], "bri": state["bri"], "uptime": info["uptime"]})
                    except Exception as error:
                        sample["error_type"] = type(error).__name__
                        if isinstance(error, CheckFailure):
                            sample["reason"] = str(error)
                            report["oracle_integrity_failure"] = True
                    sample["duration_seconds"] = round(time.monotonic() - began, 3)
                    samples.append(sample)
                    observations.write(json.dumps(sample) + "\n")
                    observations.flush()
                    report["elapsed_seconds"] = round(time.monotonic() - started, 1)
                    report["evidence"] = evidence(samples, baseline, args.brightness)
                    common.private_json(output / "status.json", {key: value for key, value in report.items() if key != "samples"})
                    if elapsed - last_console >= 30:
                        print(json.dumps({"status": "running", "elapsed_seconds": report["elapsed_seconds"], "samples": len(samples), "directory": str(output)}), flush=True)
                        last_console = elapsed
                    if report.get("oracle_integrity_failure"):
                        break
                    await asyncio.sleep(max(0, args.interval - (time.monotonic() - began)))
        report["returncode"] = process.returncode
    except asyncio.CancelledError:
        report["status"] = "interrupted"
    except Exception as error:
        report["status"] = "error"
        report["error_type"] = type(error).__name__
        if isinstance(error, CheckFailure):
            report["reason"] = str(error)
    finally:
        async def cleanup():
            try:
                await stop_process(process)
            except Exception as error:
                report["stop_error_type"] = type(error).__name__
            if process is not None:
                report["returncode"] = process.returncode
            if touched and baseline is not None:
                await restore(oracle, baseline, report)
        await shield_cleanup(cleanup())
        if process is not None:
            try:
                report["xctest_summary"] = common.read_result_summary(output / "ui.xcresult")
            except Exception as error:
                report["xcresult_error_type"] = type(error).__name__
        if baseline is not None:
            report["evidence"] = evidence(samples, baseline, args.brightness)
        if not args.prepare_only:
            passed = (report.get("status") == "running" and report.get("restored_exact")
                      and report.get("evidence", {}).get("passed") and not report.get("oracle_integrity_failure")
                      and not report.get("stop_error_type")
                      and common.result_passed("ui", report.get("returncode"), report.get("xctest_summary", {})))
            if report.get("status") == "running":
                report["status"] = "passed" if passed else "failed"
        report["finished_utc"] = common.utc_now()
        report["elapsed_seconds"] = round(time.monotonic() - started, 3)
        common.private_json(output / "results.json", report)
        common.private_json(output / "status.json", {key: value for key, value in report.items() if key != "samples"})


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--status", type=Path)
    parser.add_argument("--xctestrun", type=Path)
    parser.add_argument("--device")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--http-url", default="http://10.10.41.74")
    parser.add_argument("--mac", default="a4cb8fdb2cb8")
    parser.add_argument("--advertised-name", default="WLED-db2cb8")
    parser.add_argument("--fallback-address", help="Read-only fault proxy endpoint for a verified Wi-Fi failure/BLE fallback test")
    parser.add_argument("--device-name", help="Saved app display name, if it differs from firmware info.name")
    parser.add_argument("--no-brightness", dest="brightness", action="store_false", help="Verify power/lifecycle only; do not claim brightness coverage")
    parser.add_argument("--timeout", type=float, default=900, help="Whole test deadline; bounded process stop/restoration follow")
    parser.add_argument("--interval", type=float, default=0.5)
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--baseline-json", type=Path, help="Offline /json snapshot, only for --prepare-only")
    args = parser.parse_args(argv)
    if args.status:
        return args
    if not args.xctestrun or not args.device or not re.fullmatch(r"[A-Za-z0-9-]+", args.device):
        parser.error("--xctestrun and a valid physical --device are required")
    args.xctestrun = args.xctestrun.resolve()
    if not args.xctestrun.is_file():
        parser.error("xctestrun does not exist")
    if not math.isfinite(args.timeout) or not 30 <= args.timeout <= 3600 or not 0.5 <= args.interval <= 1:
        parser.error("timeout must be 30..3600 seconds and interval 0.5..1 second")
    if args.prepare_only != bool(args.baseline_json):
        parser.error("--prepare-only requires --baseline-json; live runs capture their own baseline")
    try:
        args.mac = normalize_mac(args.mac)
        HttpOracle(args.http_url, args.mac)
        if args.fallback_address:
            HttpOracle("http://" + args.fallback_address, args.mac)
    except (CheckFailure, ValueError, TypeError):
        parser.error("invalid fixture MAC or literal-IP HTTP origin")
    return args


def main(argv=None):
    args = parse_args(argv)
    if args.status:
        print((args.status / "status.json").read_text())
        return 0
    os.umask(0o077)
    output = (args.output or common.ROOT / "build/phase2/ui-runs" / (time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + uuid.uuid4().hex[:6])).resolve()
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    (output / ".gitignore").write_text("*\n")
    report = {"status": "preparing", "started_utc": common.utc_now(), "directory": str(output), "brightness_enabled": args.brightness}
    common.private_json(output / "status.json", report)
    try:
        asyncio.run(run(args, output, report))
    except KeyboardInterrupt:
        report["status"] = "interrupted"
        common.private_json(output / "status.json", report)
    print(json.dumps({key: value for key, value in report.items() if key not in ("samples", "restoration_attempts")}, indent=2), flush=True)
    return 0 if report["status"] in ("passed", "prepared_no_hardware") else 1


if __name__ == "__main__":
    raise SystemExit(main())
