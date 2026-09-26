# Bluetooth workspace

This private fork adds a transport-independent native Light Studio and an offline
advanced workspace. It must be paired with firmware advertising
`GET /ble/capabilities` version 2. The wire framing remains protocol 1.

## Feature map

| Interface | Bluetooth implementation |
| --- | --- |
| Power, brightness, colors and white/CCT | Native controls with device readback |
| Effects, palettes and custom effect parameters | Native searchable catalogs and metadata-driven controls |
| Segments, matrix geometry and mapping | Native editors plus full bundled WLED controls |
| Scenes and playlists | Durable save/delete receipts and verified library refresh; rename preserves live state |
| Transition/nightlight | Native timing controls |
| LED, Wi-Fi, UI, sync, time, security, usermods and matrix settings | Bundled forms using the shared firmware settings handler |
| PIN protection | Session-scoped `/ble/auth`, separate from Bluetooth pairing |
| Files and configuration/preset backups | Chunked reads/writes with stable SHA-256 revisions and atomic replacement |
| Custom palettes, pixel art, pixel studio | Bundled tools; selected-device requests use Bluetooth |
| Live preview and pixel packets | `/json/live`, bounded `/ble/ddp`, backpressure and negotiated chunk sizes |
| Firmware updates | USB, matching these profiles' Wi-Fi capability |

Network integrations need their normal network to function. Bluetooth configuration
does not turn MQTT, UDP synchronization, NTP, or internet resources into offline
services. Pixel streaming over Bluetooth has a lower practical frame rate than
Wi-Fi; the app bounds queued data and surfaces failures.

## App boundaries

`DeviceConnectionController` pins the selected client and generation.
`BleRequestQueue` serializes all protocol requests because the wire protocol has
no request IDs. Cancellation drains any outstanding reply before starting another
request. `WorkspaceOperationQueue` holds a permit for an entire multi-chunk file
operation while ordinary lighting commands remain usable. The connection epoch is
captured before queueing, so a queued mutation cannot migrate to a new session.

`DeviceWorkspaceWebView` serves local assets using `wled-local://device`. Its
message bridge verifies that origin, validates local paths, and accepts only
supported operations. The JavaScript adapter supports fetch, XHR, ordered forms,
WebSocket JSON/live/pixel traffic, dialogs and native share-sheet downloads.
Controller requests never fall back to an HTTP host. Uploaded compressed pages
are inflated with CRC and output-size checks. The website data store is ephemeral.

`bridge.js` and `native.css` are app-specific. Refresh the other assets with:

```sh
python3 scripts/sync_workspace_assets.py
```

The normal workspace uses its bundled interface. To run a custom controller page,
open **Files & backups**, select the uploaded HTML file and choose **Open page**.
That explicitly reads the controller copy, including compressed `.htm.gz` pages,
even when its name matches a bundled page.

Controller pages use the separate local origin `wled-local://files`. Their
scripts and styles prefer controller files, with packaged assets as a fallback
when a file is absent. This keeps WebKit's cached bundled resources from masking
custom files. Home links read the controller's `index.htm`; the app's bridge and
native stylesheet remain bundled. Both origins use the same selected Bluetooth
connection. The bundled controls omit the unsolicited upgrade-report prompt.

The script takes the sibling firmware tree by default and writes a source manifest
and the firmware license into the bundle. Firmware HTML is adapted for local asset
paths and the native connection. The editor uses its bundled textarea fallback
instead of requiring an external code-editor download.

## Firmware boundaries

The paired firmware exposes bounded administration routes instead of an arbitrary
HTTP proxy. `/ble/fs` and `/ble/request` stage one transfer, acknowledge offsets,
check SHA-256 and commit only after validation. Disconnect/timeout clears staging.
Reserved credentials are protected. Saved settings and presets return
`success:true,saved:true` only after persistence completes; reboot, radio disable
and pairing-code changes wait for final response delivery. Reads and writes use
the same settings/state logic as HTTP.

For disruptive saves, receipts may include `reboot:true`, `reconnect:true`, or
`bluetoothEnabled:false`. The app avoids reloading a dead page. Disabling Bluetooth
also stops connection demand and automatic fallback until the user chooses a new
connection. No mutation is automatically replayed after an ambiguous disconnect.

USB serial `B` is an explicit, physical-access pairing-code retrieval command.
The passkey is not broadcast in Bluetooth metadata or unsolicited logs.

## Software verification

- Firmware host protocol/file tests, including corruption, truncation, invalid
  paths and persistence fault injection.
- Standard ESP32 and each supported BLE firmware profile compile.
- Simulator service tests cover queue cancellation, session replacement,
  persistence receipts, multi-chunk files, SHA mismatch, staged aborts, negotiated
  pixel-packet splitting, compressed pages and stale-session rejection.
- Node tests exercise real bundled JavaScript fetch/XHR/forms, duplicate fields,
  zero-byte uploads, PIN prompts, DDP, downloads and reconnect save notices.
- Hosted WebKit tests exercise local assets, the actual custom origin and native
  fetch/XHR bridging; rendered SwiftUI tests cover light/dark and Dynamic Type.
- UI automation is a separate suite; screenshot-service failure is not a pass.

Useful commands from the iOS repository:

```sh
node --test scripts/workspace/bridge.test.mjs
xcodebuild -project wled.xcodeproj -scheme wled \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath build/TransportDerivedData \
  -clonedSourcePackagesDirPath build/TransportPackages \
  -packageAuthorizationProvider netrc -skipPackagePluginValidation \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test
```

## Real-device acceptance

Software-only checks do not establish radio throughput, pairing or persistence on
the board. Use a USB-connected, unlocked iPhone and the intended controller. Before
flashing, identify the chip/flash profile and back up existing configuration,
presets and relevant flash partitions. Prefer an application-only update when the
partition map is already compatible; do not erase credentials or pairing casually.

Use the existing [hardware guide](PHASE2-HIL.md) for signed build and fixture
identity setup. Additional workspace acceptance must cover:

1. With phone Wi-Fi disabled, open every native tab and advanced tool, change an
   effect/palette/color and verify state from the real device.
2. Read catalogs, settings scripts, PIN status and live data through Bluetooth.
3. Upload, download, replace with an empty file and delete a unique temporary file;
   compare exact bytes and SHA-256 and verify cleanup after errors.
4. Back up preset/configuration files; save/rename/delete a temporary scene and
   playlist, verify durable contents and restore the original files exactly.
5. Change a reversible setting, verify it survives restart and restore it. Exercise
   locked settings, unlock, relock and failed PIN throttling without logging secrets.
6. Interrupt a staged upload/reconnect and verify no partial destination or replay.
7. Verify pixel streaming/live preview, file editor, palette editing and backups.
8. Review phone layouts, large text, VoiceOver labels and actual touch interaction.

Keep hardware result bundles private and distinguish executed passes, skips and
pending checks. Preserve the backup until restoration is verified. Pairing-code
rotation, disabling Bluetooth and network-changing settings require a recovery
path and deliberate testing; they are not part of an unattended smoke test.
