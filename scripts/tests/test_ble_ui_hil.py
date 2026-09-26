"""No-device regression tests for the UI HIL orchestrator.

Run from WLED-iOS with:
  python3 -m unittest discover -s scripts/tests -p test_ble_ui_hil.py -v

All sockets, Xcode launches and device observations are replaced with fixtures.
"""
import asyncio
import copy
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import types
import unittest
from unittest.mock import patch, AsyncMock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import run_ble_ui_hil as ui

MAC = '001122334455'
SNAPSHOT = {'info': {'mac': MAC, 'uptime': 1000, 'live': False, 'name': 'WLED'},
 'state': {'on': True, 'bri': 128, 'transition': 7, 'bs': 0, 'ps': -1, 'pl': -1,
  'ledmap': 0, 'nl': {'on': False, 'dur': 60, 'mode': 1, 'tbri': 0, 'rem': -1},
  'udpn': {'send': True, 'recv': True, 'sgrp': 1, 'rgrp': 1}, 'lor': 0, 'mainseg': 0,
  'seg': [{'id': 0, 'frz': True, 'col': [[255, 0, 0]], 'fx': 0, 'on': True}]}}
BASE = {'TestConfigurations': [{'TestTargets': [{'BlueprintName': 'WLEDUIHILTests',
 'IsUITestBundle': True, 'UITargetAppPath': '__TESTROOT__/WLED.app',
 'TestHostPath': '__TESTROOT__/Runner.app', 'TestBundlePath': '__TESTHOST__/PlugIns/UITest.xctest',
 'EnvironmentVariables': {'KEEP': 'yes', 'BLE_HIL': '1', 'BLE_UI_NAME': 'stale'},
 'TestingEnvironmentVariables': {'BLE_HIL': '1'},
 'UITargetAppEnvironmentVariables': {'BLE_UI_HIL': '1'}}]}]}
SUMMARY = {'result': 'Passed', 'totalTestCount': 1, 'passedTests': 1, 'failedTests': 0, 'skippedTests': 0}


class FakeWriter:
    def __init__(self): self.data = b''; self.closed = False
    def write(self, data): self.data += data
    async def drain(self): pass
    def close(self): self.closed = True
    async def wait_closed(self): pass


class FakeOracle(ui.HttpOracle):
    def __init__(self, *args):
        super().__init__(*args)
        self.value = copy.deepcopy(SNAPSHOT)
        self.calls = []
        self.running = False
        self.polls = 0
        self.process = types.SimpleNamespace(pid=99999999, returncode=None)
        self.failure = None
        self.corrupt_after = False
    async def request(self, update=None):
        self.calls.append(copy.deepcopy(update))
        if update is not None:
            for key in ('on', 'bri'):
                if key in update: self.value['state'][key] = update[key]
            if 'seg' in update:
                for segment in update['seg']:
                    current = next(s for s in self.value['state']['seg'] if s['id'] == segment['id'])
                    current.update(segment)
            if 'udpn' in update:
                self.value['state']['udpn'].update({k: v for k, v in update['udpn'].items() if k != 'nn'})
            if self.corrupt_after and 'on' in update:
                self.value['state']['seg'][0]['fx'] = 1
        elif self.running:
            self.polls += 1
            if self.failure:
                self.running = False
                raise self.failure
            self.value['state'].update(on=self.polls > 1, bri=96)
            self.value['state']['seg'][0]['frz'] = False
            if self.polls >= 2:
                self.running = False
                self.process.returncode = 0
        return ui.validate_snapshot(copy.deepcopy(self.value), MAC)


class UiHilRunnerTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = self.root / 'source.xctestrun'
        self.source.write_bytes(plistlib.dumps(BASE))
        self.output = self.root / 'output'; self.output.mkdir()
        self.args = types.SimpleNamespace(http_url='http://127.0.0.1', mac=MAC, prepare_only=False,
            baseline_json=None, xctestrun=self.source, device='test-device', timeout=30, interval=0,
            brightness=True, advertised_name='WLED-test', device_name=None)
    def tearDown(self): self.temp.cleanup()

    async def run_case(self, *, failure=None, summary=None, corrupt=False, snapshot=None):
        fake = FakeOracle(self.args.http_url, MAC)
        fake.failure = failure; fake.corrupt_after = corrupt
        if snapshot is not None: fake.value = copy.deepcopy(snapshot)
        report = {'status': 'preparing'}
        async def launch(*args, **kwargs):
            assert fake.value['state']['udpn']['send'] is False
            assert (self.output / 'baseline.json').exists()
            fake.running = True
            return fake.process
        async def stop(process):
            fake.running = False
            if process and process.returncode is None: process.returncode = -2
        async def fast_sleep(*args): pass
        with patch.object(ui, 'HttpOracle', return_value=fake), \
             patch.object(ui.common, 'source_fingerprints', return_value={}), \
             patch.object(ui, 'build_metadata', return_value=[]), \
             patch.object(ui.asyncio, 'create_subprocess_exec', side_effect=launch) as launcher, \
             patch.object(ui, 'stop_process', side_effect=stop), \
             patch.object(ui.asyncio, 'sleep', side_effect=fast_sleep), \
             patch.object(ui.common, 'read_result_summary', return_value=SUMMARY if summary is None else summary), \
             patch('builtins.print'):
            await ui.run(self.args, self.output, report)
        return report, fake, launcher

    async def test_success_restores_all_and_prevents_notifications(self):
        report, fake, launcher = await self.run_case()
        self.assertEqual(report['status'], 'passed')
        self.assertTrue(report['restored_exact'])
        self.assertEqual(fake.value['state'], SNAPSHOT['state'])
        updates = [call for call in fake.calls if call is not None]
        self.assertFalse(updates[0]['udpn']['send'])
        self.assertTrue(updates[-1]['udpn']['send'])
        for update in updates:
            self.assertEqual(update['tt'], 0)
            self.assertTrue(update['udpn']['nn'])
            self.assertTrue(update['v'])
        for index, call in enumerate(fake.calls):
            if call is not None: self.assertIsNone(fake.calls[index - 1])
        self.assertEqual((self.output / 'baseline.json').stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.output / 'ui.xctestrun').stat().st_mode & 0o777, 0o600)

    async def test_active_fixture_never_writes_or_launches(self):
        bad = copy.deepcopy(SNAPSHOT); bad['state']['pl'] = 2
        report, fake, launcher = await self.run_case(snapshot=bad)
        self.assertEqual(report['status'], 'error')
        self.assertFalse(any(call is not None for call in fake.calls))
        launcher.assert_not_called()

    async def test_cancel_still_restores(self):
        report, fake, _ = await self.run_case(failure=asyncio.CancelledError())
        self.assertEqual(report['status'], 'interrupted')
        self.assertTrue(report['restored_exact'])
        self.assertEqual(fake.value['state'], SNAPSHOT['state'])

    async def test_identity_failure_stops_and_restores(self):
        report, fake, _ = await self.run_case(failure=ui.CheckFailure('Fixture MAC identity mismatch'))
        self.assertEqual(report['status'], 'failed')
        self.assertTrue(report['oracle_integrity_failure'])
        self.assertTrue(report['restored_exact'])

    async def test_passing_xcode_cannot_hide_other_segment_mutation(self):
        report, fake, _ = await self.run_case(corrupt=True)
        self.assertEqual(report['status'], 'failed')
        self.assertFalse(report['restored_exact'])
        self.assertEqual(len(report['restoration_attempts']), 3)

    async def test_empty_skipped_xcresult_cannot_pass(self):
        report, _, _ = await self.run_case(summary={'result': 'Passed', 'totalTestCount': 1, 'passedTests': 0, 'failedTests': 0, 'skippedTests': 1})
        self.assertEqual(report['status'], 'failed')
        self.assertTrue(report['evidence']['passed'])

    async def test_offline_preparation_does_not_access_devices(self):
        self.args.prepare_only = True
        self.args.baseline_json = self.root / 'baseline-input.json'
        self.args.baseline_json.write_text(json.dumps(SNAPSHOT))
        report, fake, launcher = await self.run_case()
        self.assertEqual(report['status'], 'prepared_no_hardware')
        self.assertEqual(fake.calls, [])
        launcher.assert_not_called()

    async def test_http_framing_and_identity(self):
        payload = json.dumps(SNAPSHOT).encode()
        responses = [b'Content-Length: ' + str(len(payload)).encode() + b'\r\n\r\n' + payload,
            b'Transfer-Encoding: chunked\r\n\r\n' + hex(len(payload))[2:].encode() + b'\r\n' + payload + b'\r\n0\r\n\r\n',
            b'Content-Type: application/json\r\n\r\n' + payload]
        for response in responses:
            reader = asyncio.StreamReader(); reader.feed_data(b'HTTP/1.1 200 OK\r\n' + response); reader.feed_eof()
            writer = FakeWriter()
            with patch.object(ui.asyncio, 'open_connection', AsyncMock(return_value=(reader, writer))):
                self.assertEqual(await ui.HttpOracle('http://127.0.0.1', MAC).request(), SNAPSHOT)
            self.assertTrue(writer.closed)
            self.assertTrue(writer.data.startswith(b'GET /json HTTP/1.1'))
        reader = asyncio.StreamReader(); reader.feed_data(b'HTTP/1.1 200 OK\r\n\r\n' + payload); reader.feed_eof()
        with patch.object(ui.asyncio, 'open_connection', AsyncMock(return_value=(reader, FakeWriter()))):
            with self.assertRaises(ui.CheckFailure):
                await ui.HttpOracle('http://127.0.0.1', '000000000000').write({'on': False})

    def test_xctestrun_configuration_and_evidence(self):
        baseline = ui.fixture_baseline(SNAPSHOT, MAC)
        original = copy.deepcopy(BASE)
        config = ui.ui_configuration(BASE, self.root, self.args, baseline)
        self.assertEqual(BASE, original)
        target = next(ui.common.targets(config))
        self.assertEqual(target['EnvironmentVariables']['BLE_UI_BRIGHTNESS'], '128')
        self.assertEqual(target['EnvironmentVariables']['BLE_UI_HIL'], '1')
        self.assertEqual(target['EnvironmentVariables']['KEEP'], 'yes')
        self.assertNotIn('BLE_HIL', target['EnvironmentVariables'])
        self.assertEqual(target['TestingEnvironmentVariables'], {})
        self.assertEqual(target['UITargetAppEnvironmentVariables'], {})
        self.assertEqual(target['OnlyTestIdentifiers'], [ui.SELECTOR])
        good = [{'ok': True, 'on': False, 'bri': 96, 'uptime': 1001}, {'ok': True, 'on': True, 'bri': 96, 'uptime': 1002}]
        self.assertTrue(ui.evidence(good, baseline, True)['passed'])
        good[0]['uptime'] = 1; good[1]['uptime'] = 2
        self.assertFalse(ui.evidence(good, baseline, True)['passed'])
        self.assertFalse(ui.evidence([], baseline, True)['passed'])

    def test_ui_target_production_dylib_is_fingerprinted_separately_from_runner(self):
        app = self.root / 'WLED.app'
        app.mkdir()
        (app / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleExecutable': 'WLED', 'DTPlatformName': 'iphoneos'}))
        (app / 'WLED').write_bytes(bytes.fromhex('cffaedfe') + b'unchanged launcher')
        debug = app / 'WLED.debug.dylib'
        debug.write_bytes(bytes.fromhex('cffaedfe') + b'production version one')
        document = ui.common.rebase_testroot(BASE, self.root)
        # The UI runner/test products are distinct from the application under test.
        with patch.object(ui.common, 'artifact_metadata', side_effect=lambda _: []):
            first = ui.build_metadata(document)[0]
            debug.write_bytes(bytes.fromhex('cffaedfe') + b'production version two')
            second = ui.build_metadata(document)[0]
        before = {entry['path']: entry['sha256'] for entry in first['code_binaries']}
        after = {entry['path']: entry['sha256'] for entry in second['code_binaries']}
        self.assertIn(str(debug.resolve()), before)
        self.assertIn(str((app / 'WLED').resolve()), before)
        self.assertEqual(first['executable_sha256'], second['executable_sha256'])
        self.assertNotEqual(before[str(debug.resolve())], after[str(debug.resolve())])

if __name__ == '__main__': unittest.main()
