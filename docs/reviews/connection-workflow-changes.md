# Connection workflow implementation

This implements the actionable changes from [the connection experience review](connection-experience.md).

## User-visible behavior

- List, detail, editor and Connection sheet report **Connected via Wi-Fi**, **Connected via Bluetooth**, connecting, disconnected, or **Disconnected by you**. The mode picker represents intent; status represents the active route.
- A common Connection sheet is available from the list and native controls. It separates current usage, saved methods, mode, auto-connect and troubleshooting. Unused saved methods are never labeled reachable without a check.
- **Automatic** prefers a configured network route, tries saved Bluetooth when it fails, and retains a healthy fallback until explicit reconnect or lifecycle reconnection. **Try Wi-Fi again** is available while using fallback. Wi-Fi and Bluetooth modes never silently choose the other route.
- **Disconnect** releases the session, cancels retries and pending commands, preserves saved methods and light output, and persists across navigation/refresh/relaunch. Only explicit Connect clears this intent. Choosing a different mode while disconnected does not reconnect.
- Automatic list connection defaults on for existing Wi-Fi mode and off for Bluetooth/Automatic mode. Opening a device starts an on-demand connection unless manually disconnected. Hidden devices are excluded from automatic connection; hiding an already-active device is only an organizational action.
- Native power, brightness and color controls work on both transports. The **Full web interface** is an explicit Wi-Fi-dependent action, with an explanation when unavailable. Its web context is cleared when removed from the view hierarchy.
- List and detail controls are disabled offline; list controls no longer change displayed state optimistically. No offline writes are queued. Sending/readback/uncertain-outcome messages are visible. Route changes never replay a pending command on the replacement route.
- The light-power switch in the list is explicitly labeled **Lights**. Disconnect, Hide and Remove remain distinct. Removing a discovered network device suppresses automatic re-add; explicitly adding it again clears suppression.
- Address edits remain drafts. **Test and Apply Address** normalizes/validates the endpoint, reads its identity, and requires the same MAC before saving. It does not change WLED's network settings. A failed verification leaves the saved route alone.
- Adding Bluetooth to an existing record preserves its selected mode. Add reports that the device is saved, rather than implying every upsert created a new device.
- The unconditional “Paired with iOS” claim is removed. Pairing instructions describe iOS ownership and explain obtaining the code before BLE-first setup. The app does not promise that deleting a record deletes an OS bond.
- Bluetooth discovery ends after 20 seconds, supports explicit rescan, explains empty results and possible ownership by another phone, and labels RSSI as a discovery-time observation.
- Local Network permission messaging explicitly says Bluetooth can still work. Connection help distinguishes transport requirements, internet access, pairing and possible device occupancy.
- Disconnected devices are grouped using current connection status instead of the previous 60-second online grace period. Retained values are identified as last-known state.

## Model and transport rules

`DeviceConnectionController` owns a single command route and stable `DeviceWithState` per saved device. Mode/endpoint changes reconfigure it without replacing the object observed by navigation destinations. Generation checks retire old callbacks before a new route starts. One list model is shared by the application's windows.

The existing persisted connection-type field supports `automatic`, `wifi`, and `ble`; existing explicit modes remain explicit. Manual-disconnect and auto-connect preferences are stored per device in UserDefaults. A legacy UUID accidentally stored as a network address is still rejected as a network endpoint; manual Wi-Fi now reports the missing endpoint rather than silently selecting BLE.

Automatic attempts each configured route once per cycle, then allows at most two additional cycles. Action-required errors stop retries after any eligible alternate route has been tried. Network setup is bounded to 20 seconds; BLE allows 90 seconds for iOS setup. The route controller disables each transport's independent retry loop, so there are no competing fallback/retry owners. Standalone transport clients retain their existing retry behavior for direct callers and HIL tests.

Both production transports require returned MAC identity to match the saved record before becoming usable. Wi-Fi is considered connected only after a valid initial state response, not simply a WebSocket handshake. Generation/cancellation guards prevent late Wi-Fi callbacks from resurrecting a retired connection. A read-only `{"v":true}` state refresh checks idle network connections every ten seconds; stale responses and unanswered writes become explicit failures.

A command with a lost response is treated as uncertain. Its intent is discarded on disconnect/failure; reconnection reads authoritative state. The app does not assert exactly-once delivery or replay arbitrary operations across transports. “State refreshed from WLED” describes a readback, not exclusive control over changes from other clients.

## Deliberate boundaries

- iOS owns pairing prompts and bonds. A saved Bluetooth identifier cannot prove that a bond remains valid; Automatic mode warns that iOS may request pairing again after security state changes. The app cannot promise silent repair or implement a reliable app-only “forget iOS bond” command.
- A healthy Bluetooth fallback is not continually probed or replaced during interaction. The user can choose Try Wi-Fi again; later normal reconnection starts with the preferred network route. This avoids route flapping and unnecessary radio claims.
- No new BLE configuration/provisioning API or firmware pairing-code delivery mechanism was invented. The UI explains the existing prerequisite; the installer/firmware must provide the code when network settings are inaccessible.
- No factory reset, security reset or duplicate factory-reset UI was added. These are distinct destructive device operations.
- Text status, labels and existing scalable controls improve accessibility. A complete VoiceOver, largest-text and translation audit across supported iOS versions remains separate validation.
- Sharing the app's connection model removes duplicate per-window ownership; multi-window lifecycle behavior still needs targeted iPad validation.

## Verification and failure retention

The first connection UI run passed on the physical iPhone with 419 independent HTTP samples, zero HTTP failures and exact ESP32 state restoration. It covered native transport switching, Automatic choosing healthy Wi-Fi, persistent Disconnect across relaunch, explicit reconnect, BLE power/brightness, and foreground recovery.

Seventy unit tests passed, including new policy tests for one-route fallback/no write replay, manual-mode behavior, persistent disconnect, unused BLE ownership, bounded retry cancellation, draft addresses, offline command rejection and identity rejection. Thirteen Python runner tests passed.

An initial API HIL attempt rejected a test-only placeholder MAC (`fixture`) under the new production identity check. The HIL fixture now uses the identity already verified during preparation; the failed run restored the board exactly. An initial extended UI attempt failed before test initialization because iOS requested renewed “Enable UI Automation” passcode authentication; it also restored the board exactly. These are retained, not recorded as product passes.

The final API run (`build/phase2/connection-workflow-api-final`) passed all 70 unit methods, the functional API suite, and reboot recovery. Automatic BLE recovery completed within 13 seconds and exact state restoration passed. The final physical UI run (`build/phase2/connection-workflow-ui-final`) also passed: Wi-Fi native control, persistent Disconnect/relaunch, real Wi-Fi failure → BLE fallback → restored Wi-Fi, Bluetooth controls, brightness readback and foreground recovery. All 404 independent HTTP samples succeeded; exact board state, the original app address and connection preference were restored. The final UI run covers the additional slider reset on connection changes; the preceding 70-unit/API build differs only in those two view files. All 86 source fingerprints recorded for the final UI run match the workspace. The extended test uses `scripts/ble_fallback_proxy.py`: it forwards only `/json/info` from the actual fixture and rejects the Wi-Fi WebSocket. The test temporarily verifies/applies that address, requires real BLE fallback and a native power roundtrip, then restores the original network address and preference. The proxy never forwards control writes.

The temporary read-only fault server was stopped after restoration. Firmware was unchanged. The prior successful fallback run retained one HTTP observation timeout (397 successful samples); the final run had none. No upstream submission was made.
