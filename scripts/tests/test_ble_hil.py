"""Host configuration and binary provenance tests; no Xcode or hardware commands."""
import copy
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "run_ble_hil.py"
SPEC = importlib.util.spec_from_file_location("hosted_hil", SCRIPT)
hil = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(hil)


class HostedHarnessTests(unittest.TestCase):
    def test_all_hosted_modes_isolate_saved_devices_without_enabling_unit_hardware(self):
        base = {"TestConfigurations": [{"TestTargets": [{
            "BlueprintName": "WLEDTests", "TestBundlePath": "__TESTROOT__/WLEDTests.xctest",
            "EnvironmentVariables": {"BLE_HIL": "1", "BLE_HIL_ISOLATE_APP": "0"},
            "TestingEnvironmentVariables": {"BLE_HIL": "1", "BLE_HIL_ISOLATE_APP": "0"},
        }]}]}
        original = copy.deepcopy(base)
        for mode in ("unit", "commissioning", "functional", "reboot"):
            with self.subTest(mode=mode):
                document = hil.derive_configuration(base, Path("/tmp/unused"), mode, {"BLE_HIL_MAC": "a4cb8fdb2cb8"})
                target = list(hil.targets(document))[0]
                self.assertEqual(target["EnvironmentVariables"]["BLE_HIL_ISOLATE_APP"], "1")
                self.assertEqual(target["EnvironmentVariables"]["BLE_HIL"], "0" if mode == "unit" else "1")
                self.assertFalse(any(key.startswith("BLE_HIL") for key in target["TestingEnvironmentVariables"]))
                self.assertFalse(target["ParallelizationEnabled"])
                if mode == "unit":
                    self.assertEqual(target["SkipTestIdentifiers"], ["BleHardwareTests"])
                    self.assertNotIn("OnlyTestIdentifiers", target)
                else:
                    self.assertEqual(target["OnlyTestIdentifiers"], ["BleHardwareTests/" + hil.METHODS[mode]])
                self.assertEqual(base, original)

    def test_production_code_change_is_visible_even_when_debug_launcher_is_unchanged(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "WLED.app"
            tests = root / "WLEDTests.xctest"
            for bundle, executable in ((app, "WLED"), (tests, "WLEDTests")):
                bundle.mkdir()
                (bundle / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": executable}))
                (bundle / executable).write_bytes(bytes.fromhex("cffaedfe") + b"launcher")
            debug = app / "WLED.debug.dylib"
            debug.write_bytes(bytes.fromhex("cffaedfe") + b"production version one")
            embedded = app / "Frameworks" / "Dependency.framework" / "Dependency"
            embedded.parent.mkdir(parents=True)
            embedded.write_bytes(bytes.fromhex("cafebabe") + b"embedded code")
            (app / "resource.txt").write_text("not executable code")
            document = {"WLEDTests": {"TestBundlePath": str(tests), "TestHostPath": str(app / "WLED")}}
            first = hil.artifact_metadata(document)[0]["products"]
            first_host = first[0]
            before = {entry["path"]: entry["sha256"] for entry in first_host["code_binaries"]}
            self.assertIn(str(debug.resolve()), before)
            self.assertIn(str(embedded.resolve()), before)
            self.assertNotIn(str((app / "resource.txt").resolve()), before)
            self.assertEqual(len(first[1]["code_binaries"]), 1)
            debug.write_bytes(bytes.fromhex("cffaedfe") + b"production version two")
            second_host = hil.artifact_metadata(document)[0]["products"][0]
            after = {entry["path"]: entry["sha256"] for entry in second_host["code_binaries"]}
            self.assertEqual(first_host["executable_sha256"], second_host["executable_sha256"])
            self.assertNotEqual(before[str(debug.resolve())], after[str(debug.resolve())])

    def test_rebuild_during_fingerprinting_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "WLED.debug.dylib"
            binary.write_bytes(bytes.fromhex("cffaedfe") + b"old code")
            original = hil.sha256
            def change_after_hash(path):
                result = original(path)
                path.write_bytes(path.read_bytes() + b"changed")
                return result
            with patch.object(hil, "sha256", change_after_hash):
                with self.assertRaisesRegex(ValueError, "changed while fingerprinting"):
                    hil.code_fingerprints(root)


if __name__ == "__main__":
    unittest.main()
