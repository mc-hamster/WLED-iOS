# Phase 2: real iPhone BLE acceptance

`wledTests/BleHardwareTests.swift` is an opt-in XCTest suite using the production
`BleDiscoveryService`, `CoreBluetoothTransport`, `BleBridgeSession`, and
`BleClient`. It requires a physical iPhone and the dedicated WLED fixture. The
regular test run skips hardware unless the **test process** has `BLE_HIL=1`.

## Build the signed test bundle

Run these commands from the repository root with a configured Xcode signing
account. Set `HIL_TEAM_ID` to your development team and `HIL_PHONE_UDID` to the
physical device identifier shown in Xcode's Devices and Simulators window.
The team override applies to both the app and its test target.

```sh
HIL_TEAM_ID="YOUR_TEAM_ID"
HIL_PHONE_UDID="YOUR_IPHONE_UDID"
HIL_BUILD_ROOT="$(mktemp -d /tmp/wled-ios-hil.XXXXXX)"

xcodebuild -project wled.xcodeproj -scheme wled \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$HIL_BUILD_ROOT/DerivedData" \
  -clonedSourcePackagesDirPath "$HIL_BUILD_ROOT/SourcePackages" \
  -packageAuthorizationProvider netrc -skipPackagePluginValidation \
  -allowProvisioningUpdates DEVELOPMENT_TEAM="$HIL_TEAM_ID" \
  build-for-testing

HIL_XCTESTRUN="$(rg --files "$HIL_BUILD_ROOT/DerivedData/Build/Products" -g '*.xctestrun')"
test -f "$HIL_XCTESTRUN"
```

Use a fresh `/tmp` build root for the initial build. A previous package checkout
with numbered duplicate source files caused package compilation failures during
setup; an empty `SourcePackages` directory avoided that damaged cache. Keep this
build root for the run, and rebuild after source changes. The runner uses the
compiled app/test bundle; it never compiles current source automatically.

Package versions remain pinned in `Package.resolved`. The `netrc` package
authorization provider avoids public-package Keychain prompts. Plugin validation
is skipped for the pinned SwiftLint plugin, matching the repository build setup.
Resolve signing, provisioning, or signing-key access prompts before unattended
execution. Do not set `CODE_SIGNING_ALLOWED=NO` for the physical device build.

## Commission once, then run unattended

Connect the iPhone over USB and complete the one-time setup:

1. Accept **Trust This Computer** and unlock the phone with its passcode.
2. Enable Developer Mode, including its restart/confirmation, and trust the
   development app if iOS requests it.
3. Keep the phone powered, unlocked, and WLED foreground. For long runs, set
   Auto-Lock to **Never** when permitted by the phone's policy.
4. Accept WLED's Bluetooth and Local Network permission prompts.
5. During commissioning, accept iOS pairing and enter the ESP32's six-digit code
   from WLED's **Settings → Usermods → BleApiBridge**.
6. Before unattended **UI** tests, start the UI runner while a person is present.
   If the phone displays **Enter iPhone Passcode for XCTest** / **Enable UI
   Automation**, the owner must enter the iPhone passcode on the phone to enable
   Apple's UI automation permission. This is separate from Bluetooth permission,
   pairing and Developer Mode. The harness does not collect the passcode or bypass
   this prompt.

The first five steps were completed for the connected test phone, and the hosted
BLE/API tests can run unattended. UI automation permission remains pending: the
first UI attempt displayed that passcode prompt and failed to initialize within
60 seconds, before any UI test executed. The Mac wrapper verified exact fixture
restoration afterward; that cleanup is not a UI-test pass. Complete step 6 and
rerun the UI suite before claiming unattended UI coverage.

A replacement phone, app identity, or invalidated bond may require commissioning
again. The BLE commissioning session allows 180 seconds total for
connection readiness, including the protected TX read and pairing. The test never
reads, supplies, or prints the passkey.

Only one central may own this fixture. Stop all Mac Python BLE clients before
starting the iPhone suite. HTTP observation can run alongside iPhone BLE.

Use the signed `.xctestrun` from the build above. Set fixture options explicitly
when using a different board; these values identify the dedicated test fixture:

```sh
python3 scripts/run_ble_hil.py --xctestrun "$HIL_XCTESTRUN" \
  --device "$HIL_PHONE_UDID" --mode commissioning \
  --fixture-name WLED-db2cb8 --mac a4cb8fdb2cb8 --http-url http://10.10.41.74

python3 scripts/run_ble_hil.py --xctestrun "$HIL_XCTESTRUN" \
  --device "$HIL_PHONE_UDID" --mode functional --soak-seconds 0 \
  --fixture-name WLED-db2cb8 --mac a4cb8fdb2cb8 --http-url http://10.10.41.74

python3 scripts/run_ble_hil.py --xctestrun "$HIL_XCTESTRUN" \
  --device "$HIL_PHONE_UDID" --mode full --soak-seconds 600 --seed 20260925 \
  --fixture-name WLED-db2cb8 --mac a4cb8fdb2cb8 --http-url http://10.10.41.74
```

The first command selects
`WLEDTests/BleHardwareTests/testCommissioningAndCapabilities`. The functional
command selects `WLEDTests/BleHardwareTests/testFunctionalAPIAndSoak`. Full mode
runs unit tests, the functional/soak suite, and the separate reboot-recovery test;
commissioning is separate. `--mode reboot` selects
`WLEDTests/BleHardwareTests/testRebootRecovery` on its own. The
zero-second functional command is an optional short acceptance run. The orchestrator disables parallel
testing, injects the opt-in into a derived test configuration, and requires an
actual passing hardware test; an empty or skipped hardware run is a failure.
The original `.xctestrun` is preserved. Shell environment alone is insufficient
unless Xcode forwards it into the test process.

The runner prints its unique run directory. Query it from another terminal:

```sh
python3 scripts/run_ble_hil.py --status build/phase2/runs/RUN_DIRECTORY
```

`--mode unit` runs regression tests with hardware disabled. `--prepare-only`
writes the derived configurations and manifest without invoking Xcode or touching
hardware. `--output` must name a new directory. `--command-timeout` bounds each
Xcode stage; its default is `max(600, soak_seconds + 1500)` seconds. Timeout or
interruption gives XCTest a brief chance to clean up before terminating a stuck
process; it never turns that run into a pass.

Every hosted mode sets `BLE_HIL_ISOLATE_APP=1`. In DEBUG builds this replaces the
normal device-list screen with a passive test placeholder, preventing saved
devices from connecting while tests own the BLE session. Hardware access remains
a separate opt-in: unit mode sets `BLE_HIL=0` and excludes the hardware test class.
The separate UI runner clears inherited hosted-test variables and exercises the
normal application screens.

The hosted API tests disable the idle timer and restore its previous value
afterward. They exercise foreground acceptance. The separate UI suite below
adds a controlled Home/background/foreground transition; locked-phone operation
remains outside coverage. After the appropriate API or UI commissioning is
complete, no further permission or pairing interaction is expected while the
existing permissions and bond remain valid.

## Fixture and runtime options

| Test environment variable | Default | Meaning |
| --- | --- | --- |
| `BLE_HIL` | disabled | Must equal `1` to access hardware |
| `BLE_HIL_ISOLATE_APP` | `1` from hosted runner | Suppress normal saved-device connections in DEBUG test hosts |
| `BLE_HIL_NAME` | `WLED-db2cb8` | Exact advertised name used for discovery |
| `BLE_HIL_MAC` | `a4cb8fdb2cb8` | Required BLE and HTTP identity |
| `BLE_HIL_HTTP_URL` | `http://10.10.41.74` | Independent HTTP oracle |
| `BLE_HIL_PERIPHERAL_ID` | absent | Optional **iPhone-local** CoreBluetooth UUID |
| `BLE_HIL_SOAK_SECONDS` | `600` | Seeded workload duration, 0–3600 seconds |
| `BLE_HIL_SEED` | `20260925` | Reproducible operation selection |

Use the orchestrator's `--fixture-name`, `--mac`, `--http-url`,
`--peripheral-id`, `--soak-seconds`, and `--seed` options to set these values.
An iPhone CoreBluetooth UUID is not interchangeable with the Mac peripheral UUID.

The fixture must have no active preset identity, playlist, nightlight, or realtime
input. Full functional coverage requires an existing RGB/RGBW segment, advertised
simple effects, HTTP's fixed palette list, and enough request capacity for its
complete restoration payload. Missing prerequisites fail the
selected full functional suite before control writes. LED wiring, geometry,
segment creation/deletion, presets, configuration files, and pairing settings are
never changed.

## Functional acceptance

Each named scenario records its outcome and duration. This exercises functional
JSON operations on the real phone, in addition to BLE connection behavior:

- **Native app controls:** real `BleClient.sendState` changes power and brightness;
  app state and HTTP must agree. A transparent recorder fails observed errors even
  if the app would automatically reconnect.
- **Segment controls:** existing segment selection, power, brightness 0/1/127/255,
  and WLED's retained-opacity semantics.
- **Colors:** all three color slots, RGB/RGBW arrays, a partial channel object,
  empty-slot preservation, and six-digit hex color.
- **Effects and palettes:** advertised Solid/Blink/Breathe modes, fixed palette
  IDs from HTTP, and speed/intensity boundary values. `fxdef:false` preserves
  unrelated effect settings and geometry.
- **LIVE:** an HTTP mutation must produce matching BLE readback and LIVE state;
  every iteration changes a value to avoid accepting stale state.
- **Error semantics:** malformed/non-object JSON, unsupported route, and unsupported
  method produce 400/404/405 without changing state.
- **Framing:** an exact advertised-maximum-size request and fragmented multibyte
  UTF-8 use the production transport's ATT write budget.
- **Reconnect:** five fresh sessions each execute an immediate first info request.
- **Soak:** seeded brightness/readback, speed/intensity, reconnect/readback,
  HTTP-to-LIVE, and effect-list operations, with uptime and available heap samples.

Control assertions compare BLE and HTTP state. The suite checks untouched
segment geometry/options throughout. Unexpected uptime rollback fails acceptance. Heap
reports describe observed values without inventing a leak threshold. A bounded
45-second absolute request timer supplements the production session's inactivity
timeout. Scan, connection, HTTP, polling, cycle count, and overall test execution
are also bounded.

## Controlled reboot recovery

The separate reboot test holds an actual `BleClient` through an HTTP `/reset`.
It verifies both transport identities before reset, observes the BLE disconnect,
and requires same-device HTTP uptime rollback plus a changed boot epoch. It then
allows up to 90 seconds from the reset request for the production client's
automatic reconnect policy to recover; the test never calls `connect` again.
Native state must identify the new boot, and a new brightness command must agree
with HTTP. Existing bonds stay intact; no pairing interaction is expected.

This test uses the same saved runtime state and independent restoration checks.
Only an independently proved, explicitly requested reboot may reset the uptime
guard. The JSON report includes before/after uptime, boot-epoch shift, observed
disconnects, reconnect attempts, acknowledgement status, and recovery duration.
An interrupted reset acknowledgement alone does not prove a reboot.

Coverage is idle-client software reset and subsequent native API recovery. It does
not cover physical power interruption, reset during partial RX/in-flight TX,
bond deletion, or changing the firmware's pairing code. A reboot can restore boot
defaults for other volatile state; this dedicated fixture must retain the segment
geometry/options checked by the suite.

## Separate native app UI acceptance

The opt-in `wled-ble-ui` scheme contains only
`WLEDUIHILTests/BleUserInterfaceTests/testNativeBluetoothControlsAndForegroundReconnect`.
Build it separately, after the same signing and permission setup. Run it after
the API suite has finished; the two suites must never compete for the fixture.
Complete the additional iPhone **Enable UI Automation** passcode prompt described
above before scheduling an unattended UI run.

Use a **different DerivedData directory for the UI scheme**, as the commands below
do. A UI build in the API suite's DerivedData directory was observed to remove
the hosted test bundle from `WLED.app/PlugIns`, invalidating the API suite's
existing build products. If a directory was shared, rebuild the `wled` scheme
with `build-for-testing` and derive a fresh API run configuration before running
the API tests again. An old `.xctestrun` alone cannot restore the missing bundle.

```sh
HIL_UI_BUILD_ROOT="$(mktemp -d /tmp/wled-ios-ui-hil.XXXXXX)"

xcodebuild -project wled.xcodeproj -scheme wled-ble-ui \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$HIL_UI_BUILD_ROOT/DerivedData" \
  -clonedSourcePackagesDirPath "$HIL_UI_BUILD_ROOT/SourcePackages" \
  -packageAuthorizationProvider netrc -skipPackagePluginValidation \
  -allowProvisioningUpdates DEVELOPMENT_TEAM="$HIL_TEAM_ID" \
  build-for-testing

HIL_UI_XCTESTRUN="$(rg --files "$HIL_UI_BUILD_ROOT/DerivedData/Build/Products" -g '*.xctestrun')"
test -f "$HIL_UI_XCTESTRUN"

python3 scripts/run_ble_ui_hil.py --xctestrun "$HIL_UI_XCTESTRUN" \
  --device "$HIL_PHONE_UDID" --mac a4cb8fdb2cb8 \
  --advertised-name WLED-db2cb8 --http-url http://10.10.41.74
```

The UI runner uses the actual app screens and does not create another Bluetooth
central or request Local Network permission itself. Its process receives
`BLE_UI_HIL=1` through a derived `.xctestrun`. The launched application explicitly
receives `BLE_HIL=0` so the DEBUG hosted-test isolation does not replace the normal
app flow. The original build configuration remains unchanged.

The test selects an existing saved fixture by display name and validates its MAC
in Edit Device before control writes. An existing Bluetooth entry is reused. A
missing entry, or an existing Wi-Fi entry, takes the native Add Device → Bluetooth
discovery/upsert path. `--device-name NAME` overrides the saved display name when
it differs from HTTP `info.name`; ambiguous names fail instead of selecting an
arbitrary device. The app runs in English with portrait orientation for stable
accessibility labels.

Coverage includes native power roundtrips, a brightness slider change followed by
app termination/relaunch and readback, and Home for four seconds followed by
foreground activation, reconnection, and another power roundtrip. Four seconds
exceeds the app's two-second background-disconnect policy. The Color control must
exist and be enabled, but the test does not manipulate the system color picker or
claim UI color-change coverage. If a Bluetooth entry already existed, that run
does not claim new-device discovery/Add coverage.

The Mac wrapper independently captures `/json` before mutation and requires the
expected MAC, no active preset, playlist, nightlight or realtime input, and
restorable power, brightness, segment freeze flags and UDP send state. It saves
the private baseline before temporarily disabling runtime UDP sends: native app
writes cannot add per-request UDP suppression. Every Mac HTTP mutation first
rechecks identity and supplies `tt:0` and `udpn.nn:true`. No configuration is
persisted.

During XCTest, the Mac polls HTTP every 0.5 seconds by default, recording bounded
request timings, power, brightness, uptime and error types. A pass requires an
actual one-test, one-pass, zero-failure, zero-skip result, observed power off and
on, a brightness value different from baseline, and no observed uptime rollback.
Xcode exit status alone is insufficient. A fast transition missed between HTTP
samples produces insufficient evidence and fails; it is never inferred to pass.
HTTP request failures remain in the evidence file even if later observations
satisfy the assertions. Identity or malformed-state checks fail the run.

The wrapper stops a still-running Xcode process before cleanup. It restores exact
global power/brightness, every segment's original freeze flag, and runtime UDP
send state, then compares the complete core API state projection twice, one
second apart. The projection includes all serialized segment fields and excludes
transient error flags and usermod connection telemetry. Restoration mismatch
fails acceptance. The UI test separately restores the original saved connection
preference and attempts UI state restoration. Exact raw brightness restoration
belongs to the Mac oracle because XCTest slider positioning is approximate.
An added saved device entry is retained.

The default outer deadline is 900 seconds; bounded process termination,
restoration retries and result extraction follow it. Each HTTP request has a
three-second absolute budget. `--timeout` changes the outer deadline and
`--interval` accepts 0.5–1 second polling. `--no-brightness` selects power/lifecycle
coverage only and explicitly disables brightness claims. Keep the phone powered
and unlocked with Auto-Lock disabled; this UI suite does not change that setting.

The wrapper prints a unique private directory under `build/phase2/ui-runs` with
`baseline.json`, `metadata.json`, `http-samples.jsonl`, `results.json`, `status.json`,
the derived `.xctestrun`, Xcode log and `.xcresult`. Metadata includes source and
executed-build hashes. Read progress without accessing either device:

```sh
python3 scripts/run_ble_ui_hil.py --status build/phase2/ui-runs/RUN_DIRECTORY
```

`--output` must name a new directory. For offline configuration validation,
`--prepare-only --baseline-json SAVED_JSON_SNAPSHOT` requires a previously saved
raw `/json` snapshot and makes no network request or Xcode invocation. Live runs
always capture a fresh baseline. Permission prompts, invalidated bonds, a locked
phone or unavailable connectivity can still prevent acceptance; the run fails
within its bounds rather than asking for input indefinitely. Force-killing the
Mac wrapper or losing device power can prevent restoration, so retain its private
baseline until `restored_exact` is true.

## Restoration and evidence

Before mutation, the suite captures global power/brightness and every existing
segment's power, brightness, colors, effect, speed, intensity, palette, selection,
and freeze flag. Global power-on can clear other segments' freeze flags, so all
are restored after global fields. It also saves the runtime UDP send flag: native
`WledState` has no per-request sync suppression field, so only this runtime flag
is temporarily disabled. Raw session writes use `udpn.nn:true`.

Restoration runs in a separate uncancelled task after normal completion or failure.
It verifies identity again, restores through BLE, and checks BLE plus HTTP. If BLE
restoration fails, an independently identified HTTP fallback restores and verifies
the fixture. That recovery remains a failed acceptance result because BLE
verification did not pass. Restoration verifies API-visible state, not effect
animation phase or physical light output.

Restoration requires the test process to remain alive. Force-quitting, a killed
test host, loss of power, or exhausted device connectivity can prevent cleanup.
Keep the dedicated fixture's independent baseline/backup until restoration is
verified. Runtime state restoration does not certify persisted flash contents.

The `.xcresult` includes a `Phase 2 hardware results` or
`Phase 2 reboot recovery results` JSON attachment containing
named cases, latency, operation counts, heap/uptime samples, restoration evidence,
and explicit exclusions. No raw configuration, passkey, or backend error payload
is written by the harness. The orchestrator saves separate result bundles, logs,
configuration/source fingerprints, and pollable `status.json` in a unique private
run directory (directory mode `0700`, files `0600`). Source hashes describe the
checkout when the run was prepared; they do not establish which source was
compiled. Runner metadata separately fingerprints the actual Mach-O files
in the selected app and test bundles, including the UI target app,
`WLED.debug.dylib`, the launcher, test executable, and embedded code. In Debug
builds the launcher alone does not
identify the production app code. Keep those compiled products unchanged for the
run. A scenario failure remains a failure after cleanup. A guide or a
successful commissioning run is not evidence that the full acceptance run passed;
consult that run's `status.json`, result bundle, and restoration record. Local
session results are summarized separately in ignored `build/phase2/PHASE2-RESULTS.md`.

Current exclusions are sustained background or locked operation, bond deletion/passkey rotation,
radio range/interference, physical power cycling, persisted preset/configuration
changes, physical LED output, and effect animation timing. A passing run means
the selected coverage passed; it does not prove every BLE or iOS behavior.
Physical button behavior, visual/color accuracy, broader accessibility review,
and older iOS versions require separate tests. The separate UI test covers only
the foreground lifecycle and controls described above; a build or prepared
configuration does not establish that those tests passed on the phone.

## Runner maintenance

Run the retained orchestrator tests from the repository root after changing the
runner scripts:

```sh
python3 -m unittest discover -s scripts/tests -p 'test_*.py' -v
```

These tests use fake HTTP and subprocess responses; they do not build the app or
access either device. They check configuration isolation, compiled-code
fingerprints, result handling, and restoration/failure behavior. The current
13-test verification is recorded in `build/phase2/runner-final2-tests.log`.
