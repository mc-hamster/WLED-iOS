# Bluetooth support in this fork

Use this app's `ble` branch with the `ble_api_bridge` usermod from [mc-hamster/WLED](https://github.com/mc-hamster/WLED/tree/ble/usermods/ble_api_bridge). Stock WLED firmware and stock App Store releases are not this paired fork. Wi-Fi devices continue to use the upstream app's interface.

## First connection

1. Install the correct BLE firmware for your board. Open its Wi-Fi interface and find the six-digit code under **Settings → Usermods → BleApiBridge**.
2. Add a device in the app, select **Bluetooth**, and select a nearby WLED device.
3. Tap **Add**. Accept the system pairing prompt and enter the firmware's code when iOS asks.
4. Tap **Done**, open the light, and use power, brightness, and color controls.

The firmware generates a persistent per-device code; it no longer universally uses `123456`. iOS manages the bond. The app does not need or store your code. It waits for encrypted service readiness before sending commands, allowing up to 90 seconds for discovery/pairing. Normal commands have a separate 30-second idle deadline.

Keep WLED powered and nearby. Only one phone or reference client can occupy the bridge at a time. The app reconnects automatically while active after ordinary link loss. Pairing and permission errors wait for an explicit retry to avoid repeated system prompts. Discovery explains unavailable Bluetooth and links to app Settings when permission is denied.

If WLED's pairing information changes, forget that device in **iOS Settings → Bluetooth** and reconnect. Changing the firmware code revokes its existing bonds. Factory erasure also removes the stored code and keys. The app cannot silently dismiss system pairing or delete system bonds.

## Controls and limits

Native Bluetooth control includes power, brightness, main-segment RGB color with the white channel preserved, and state updates from changes made elsewhere. It is not a tunnel for WLED's entire web interface. Preset/effect editing, full configuration pages, files, and firmware uploads continue to require Wi-Fi. The bridge's documented JSON routes remain available to other clients.

A saved device can have both a Wi-Fi address and a Bluetooth identifier. Choose its connection in **Edit Device**. If selecting a replacement Bluetooth identifier, the app verifies that it reports the same WLED MAC address before saving. Adding a different light belongs in the device list. Stock firmware updates are suppressed for recognized BLE firmware because those builds would remove Bluetooth.

Existing upstream v2 databases migrate to the new v3 schema. The earlier BLE fork's modified v2 schema is retained as v3. Legacy passkey/security-option values are cleared; iOS's system bond is unaffected.

## Building and verification

Open `wled.xcodeproj`, select the `wled` scheme, resolve the pinned packages, and select a simulator or your signed iPhone target. Deployment target remains iOS 16. Dependencies are pinned in `Package.resolved`: Swift Collections 1.7.0, SwiftLintPlugins 0.65.1, MarkdownUI 2.4.1, NetworkImage 6.0.1, and swift-cmark 0.9.0.

A reproducible unsigned simulator test command (replace the destination with an installed simulator):

```sh
xcodebuild -project wled.xcodeproj -scheme wled \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath build/DerivedData \
  -clonedSourcePackagesDirPath build/SourcePackages \
  -packageAuthorizationProvider netrc -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO test
```

The package authorization provider avoids macOS Keychain prompts for public packages in unattended builds. Plugin validation is skipped only for the pinned SwiftLint plugin, matching the upstream CI approach. For a signed device install, configure your own development team in Xcode.

Review results: 41 tests / 46 parameterized executions passed on iOS 27 Simulator, including cancellation and timeout races, serialization, live-state interleaving, ATT boundaries, UTF-8, reconnect behavior, actual SQLite migration, and removal of old pairing fields. An unsigned generic iPhone build also passed. Simulator tests use a fake transport: **actual iPhone/ESP32 pairing, RF behavior, older iOS versions, and manual visual/accessibility inspection remain to be verified.**

The detailed [cross-repository review and hardware acceptance matrix](https://github.com/mc-hamster/WLED/blob/ble/docs/BLUETOOTH_REVIEW.md) is also available locally at `../WLED/docs/BLUETOOTH_REVIEW.md` when both forks are checked out together. These changes have not been pushed; use that local copy until publication.
