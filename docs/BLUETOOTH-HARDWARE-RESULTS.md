# Bluetooth workspace hardware acceptance — 2026-09-26

The private firmware and iOS app were installed on the connected ESP32-S3 and
iPhone 16 Pro Max (iOS 27.2). The controller's HTTP address was unreachable.
Device control used Bluetooth; independent state observation and restoration
used USB. Phone Wi-Fi itself was not disabled.

The controller has 16 MB physical flash and 8 MB PSRAM. Its existing partition
table matched the S3 BLE profile. A private 16 MB flash backup was verified
before flashing only the application at `0x10000`; existing partitions, settings,
files and Bluetooth bonds were preserved. No upstream contribution or push is
part of this work.

## Executed results

| Check | Result |
| --- | --- |
| Mac BLE capabilities, settings/catalog reads, file commit/readback, checksum rejection, abort, large staged request and cleanup | 7 checks passed |
| Production iPhone CoreBluetooth workspace | Passed, 1 test, no skips; 220 effects, 220 metadata entries, 72 palettes, 30 live pixels, settings script and 12,345-byte/empty file lifecycle |
| Persistent scenes, rename, inactive playlist storage and deletion | Passed; original preset bytes restored exactly |
| Reversible UI setting and restart durability | Passed; complete public configuration restored |
| PIN protection, failed attempt throttling, relock/reconnect/restart | Passed; original blank PIN restored and verified after restart |
| Interrupted upload/reconnect | Passed; unfinished transfer rejected and no destination installed |
| Reboot verification | Three resets proven through uptime changes |
| DDP packet and live-preview readback | One correct 30-pixel RGB packet at device brightness; USB independently observed realtime mode; truncated packet rejected; exact runtime restoration verified |
| Real WebKit and routing | Final 5 focused simulator checks passed (1 WebKit, 4 routing/encoding/delegate): controller HTML/script/style precedence, fallback/home links, callbacks, UTF-8, and layout at 440/320 points; earlier 8-check run also covered 4 HIL cleanup/state-validation cases |
| Phone Studio UI walkthrough | Final build passed, 1 test, no skips; 412 successful USB observations, zero failures; power/brightness/effect/palette, scene library and cancelled save sheet, offline settings/full controls/custom palette pages, and reconnect readback; exact restoration |

The final passing UI run is `build/phase2/ui-runs/20260926T180511Z-6d5dbb`. All
six physical screenshots were reviewed after the layout and encoding corrections.
An earlier final-build attempt timed out enabling iOS automation before the test
body; the app was reopened and the retry passed. The earlier functional pass is
`build/phase2/ui-runs/20260926T174857Z-aa81dd` (391 USB observations).

An effect-only difference appeared between those runs' starting states; its source
was not established. The original Solid-effect runtime was restored again and
its complete state projection matched at 0, 5, 10, 20 and 30 seconds, including
after terminating and normally relaunching the app. This is recorded in
`final-original-restoration.json` in the final UI run directory.

The final iPhone API run is `build/phase2/runs/20260926T173835Z-workspace-d05336`.
It verifies every serialized segment field and stable top-level controls remain
unchanged, along with byte-identical configuration/preset responses and temporary
file removal. This is a workspace smoke test, not an exhaustive settings test.

Firmware evidence is in the sibling repository under
`build_output/ble-parity-hardware/20260926-usb-preflight/` and
`build_output/ble-parity-hardware/20260926-persistence/`. Recovery files are private
and must stay outside source control. Canonical firmware images and firmware source/artifact hashes
are in `../WLED/build_output/ble-parity/manifest.json`.

Final signed iOS API/UI products, build logs and source hashes are retained under
`build/ble-parity-artifacts/20260926/manifest.json`. Both ZIP archives were
extracted to fresh temporary folders, compared byte-for-byte, and passed strict
signature verification. Extract outside iCloud-backed folders before installing;
Finder metadata on loose app bundles can invalidate their signatures.

## Issues found and corrected

- The first real 1 KB file read exhausted the firmware loop stack. Checked heap
  scratch buffers reduced nested transfer/read/hash frames from 5,728 to 1,392
  bytes. The corrected image passed the same reproduction and later suites.
- USB's 256-byte receive queue dropped long unpaced test commands. The observer
  now sends 64-byte chunks with a 10 ms pause; it still requires an acknowledgement
  and two exact restoration readbacks.
- WebKit delegate signatures needed explicit main-actor completion handlers.
  Corrected Objective-C callbacks now handle navigation and native dialogs.
- Controller pages now use a separate local origin, preventing bundled resource
  caches from replacing their scripts/styles. Custom home links retain the
  controller page.
- Bundled controls no longer show or save unsolicited upgrade-report preferences.
  Deliberate factory-reset receipts no longer appear as ordinary save failures.
- The first phone walkthrough exposed empty-space tap misses in plain button
  rows. Native rows now define their complete visible touch area.
- Real phone screenshots exposed a wrapped development banner overlapping the
  controls, crowded toolbar labels, search text touching its icon, and incorrectly
  decoded palette-editor text. The workspace now measures its header, preserves
  search insets, fits toolbar cells, and declares UTF-8 for textual responses.

## Coverage limits

Physical LED appearance, CCT hardware, sustained animation throughput, all
settings categories, palette/pixel-tool save/import/export, playlist playback,
phone VoiceOver/large text/landscape, range/interference and long background
sessions need separate hands-on coverage. Passkey rotation, disabling Bluetooth,
factory reset, power cuts and low-space fault injection were not performed on
the user's configured device. Their implementation and host tests must not be
described as real-device passes.

The user confirmed physical light-output verification is unavailable for now.
Reported pixel values and USB state observations do not establish visible LED
output; that hands-on check remains pending.

Network services still need their networks. Firmware installation remains USB
for these single-application profiles, matching their Wi-Fi update capability.
