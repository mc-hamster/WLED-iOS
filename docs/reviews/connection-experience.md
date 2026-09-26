# Connection experience review

Implementation follow-up: [connection workflow changes](connection-workflow-changes.md).
The findings below describe the pre-change behavior.

Reviewed 2026-09-26 against the current iOS source, connected-iPhone list screenshot,
and the preceding physical-device UI test evidence. This is a review and proposed
behavior specification, not an implementation of the recommendations. Newly
identified edge cases below have not all been reproduced on hardware.

## What the app actually does

| Question | Current behavior |
|---|---|
| Which transport controls this device? | One managed control client per saved MAC: Wi-Fi WebSocket or Bluetooth, selected by the saved connection preference and configured endpoint. |
| Can both be connected? | The ESP32 can remain on its network while this phone uses BLE; other network clients can also use it. That does not mean this app routes commands over both. Network discovery also runs independently. In Wi-Fi mode the embedded web UI has its own network activity in addition to the app's status WebSocket. |
| How can I tell? | Rows/header show Bluetooth or a network address, with a small status shape. The label derives from the effective selected transport, not a report of both transports' reachability. BLE detail says Connected/Connecting/Disconnected without including the transport in that sentence. |
| Is there fallback? | No failure-driven transport fallback. Both clients retry their own transport. There is only configuration fallback when the selected method lacks a usable saved endpoint; a failed connection does not invoke that fallback. |
| How do I choose? | Detail → Settings gear → Edit Device → Connection segmented picker. Changes save immediately and replace the old client. A method is disabled if its endpoint field is empty. |
| How do I disconnect? | No explicit per-device UI action. Backgrounding schedules client disconnect after two seconds; foregrounding reconnects. Switching transport destroys the old client. Deleting removes its saved record/client, but is not a sensible temporary disconnect action. |
| Does leaving detail disconnect? | No. The list owns clients for all saved devices. Hidden devices are filtered from display, not from client creation. |
| What does the row toggle do? | Light power. It does not connect/disconnect the app, power off the ESP32, or stop automatic reconnection. |
| What does pairing mean? | iOS owns pairing. The app's “Paired with iOS” card is unconditional; it is not evidence of a currently verified bond or an active usable session. |
| What features change? | Wi-Fi opens the firmware web interface. Bluetooth presents native power, brightness and color controls. Switching changes the available interface as well as transport. |

Source anchors: [transport resolution](../../wled/Model/DeviceConnection.swift),
[client ownership, lifecycle, filtering and actions](../../wled/ViewModel/DeviceWebsocketListViewModel.swift),
[route-dependent detail](../../wled/View/DeviceView.swift),
[status presentation](../../wled/View/DeviceInfoTwoRows.swift),
[Bluetooth detail](../../wled/View/BleDeviceDetailView.swift),
[edit form](../../wled/View/DeviceEdit/DeviceEditView.swift).

## Findings, ordered by impact

1. **High — Connection intent, actual route and reachability are conflated.**
   A selected Bluetooth button does not mean connected; a saved network address
   does not mean reachable. There is no view of the unused route. Show explicit
   “Connected via Bluetooth” / “Connecting via Wi-Fi” / “Disconnected” everywhere,
   separate from connection preference and saved configuration. Never call an
   untested route available merely because credentials or an address exist.

2. **High — No deliberate disconnect/reconnect ownership.**
   Simply loading the list opens all saved clients, including hidden entries.
   This can occupy BLE when another phone wants it. Provide Disconnect, stop
   retries and pending writes, retain pairing/configuration, and persist the
   user's disconnected intent across navigation, refresh and app relaunch.
   Connect explicitly clears it. “Hide” must not imply “Disconnect.” Offer a
   visible auto-connect preference; avoid opening unused BLE connections just
   to populate status rows. Exact advertising/concurrency limits depend on the
   firmware, but the current picker itself warns about another phone holding it.

3. **High — Offline controls can look successful or apply later.**
   BLE detail disables controls offline, but list controls remain enabled. List
   actions optimistically change local state; BLE can retain unsent state and
   reconnect, whereas Wi-Fi does not provide the same queue semantics. Users do
   not see sending, confirmed, failed or uncertain outcomes. Disable offline
   controls by default, display last confirmed state with a freshness label, and
   surface failures. If offline queuing is ever offered, make it explicit,
   cancellable, bounded in age, and cleared by Disconnect. Never replay an
   uncertain non-idempotent operation blindly after reconnect/fallback.

4. **High — A transport switch also changes the feature set and screen.**
   A user expecting to change radios loses the firmware web controls when BLE
   is selected. Keep core controls stable across transports; make the full web
   interface a clearly network-dependent action. Explain unavailable features
   inline and offer a deliberate switch. Until this is addressed, automatic
   fallback must not silently replace a web page or discard its unsaved edits.

5. **High — Address editing can interrupt control before the user finishes.**
   Edit Device writes the address after a 0.5-second pause, without the Add
   screen's address validation. In Wi-Fi mode this can recreate the live client
   for a partial address; a full URL accepted on Add is not normalized the same
   way here. Use draft → Validate/Test → Apply. Keep the old route usable when
   feasible and explain failures. Verify the returned MAC before attaching a new
   address to an existing device. BLE replacement already has a same-device
   identity check; Wi-Fi editing lacks the equivalent.

6. **Medium — Pairing claims and recovery guidance overpromise.**
   The unconditional pairing card can appear during failure or before a working
   session. Replace it with factual copy about iOS managing pairing, and use
   verified connection evidence for success. Explain canceled/rejected pairing,
   code unavailable, no prompt, lost bond after firmware reset and incompatible
   bridge firmware separately. Pairing-code instructions point into a network
   settings page: a BLE-first user without network access needs an actual
   documented way to obtain the code. Removing from this app must not claim to
   remove an iOS bond; any OS or firmware pairing reset is a separate action.

7. **Medium — Recovery is active but largely invisible.**
   BLE retries transient errors with 2.5-second exponential backoff capped at
   60 seconds; some errors require action and stop retries. Initial BLE setup
   can wait up to 90 seconds, with 30-second request timeouts. UI shows generic
   status and Reconnect, not retry timing, Cancel or a clear stopped state.
   Show “Reconnecting via Bluetooth,” reason, retry/cancel controls, and tailored
   permission actions. Do not infer “another phone is connected” from a timeout;
   present it only as one possible cause without direct evidence.

8. **Medium — Discovery and adding are asymmetric.**
   Bluetooth Add upserts by MAC and changes the preferred connection to BLE;
   network Add/discovery generally preserves an existing preference. Both can
   report “was added” even when updating an existing device. Say “Bluetooth
   added to Kitchen” and ask/offer whether to use it now. Prefer one device card
   with multiple verified connection methods. Support duplicate names, stopped
   scans, stale results, already-connected devices not advertising, and devices
   saved but not currently discoverable. Explain disabled choices with setup
   actions instead of unexplained gray buttons.

9. **Medium — Offline grouping and stale values are ambiguous.**
   A disconnected device can remain in the main group for a 60-second grace
   period (with periodic regrouping). Preserve stable ordering if desired, but
   always show current status and last successful response; “last seen” and
   “connected now” are different facts. Do not imply light power from an old
   cached value. The Wi-Fi status WebSocket and the embedded web page can also
   fail independently: one connected icon must not imply the page is ready.

10. **Medium — Permission messaging is too global.**
    A prominent “Local Network Access Required” banner can appear while BLE is
    usable. Scope it to network features, say Bluetooth still works, and offer
    Open Settings. Likewise distinguish Bluetooth off, denied permission,
    unsupported hardware and device unreachable. Network reachability does not
    require internet access; “Wi-Fi” is currently a label for a local network
    route, not proof of the phone's physical interface or the board's SSID.

11. **Medium — Disconnect, power, hide, remove and reset are not clearly separated.**
    Keep these distinct: Lights On/Off changes output; Disconnect releases this
    app's session; Hide changes organization; Remove forgets the saved app
    entry; reset pairing changes security state; factory reset changes the
    device. Use explicit labels and reserve confirmation for destructive steps.
    Automatic discovery can re-add a deleted network device, so a persistent
    “ignore this device” choice may be needed when removal must stick.

12. **Medium — Multi-controller behavior needs explicit expectations.**
    Another browser/phone can alter WLED while this app is connected. Show
    authoritative updates without implying exclusive control. Bluetooth
    handoff needs a real Disconnect action. Across multiple saved devices,
    avoid retry storms, intrusive pairing prompts and unused radio sessions.
    Across multiple windows, define connection ownership so one window cannot
    silently undo another's explicit disconnect.

Sources: [BLE retry/queue](../../wled/Service/Bluetooth/BleClient.swift),
[BLE errors/timeouts](../../wled/Service/Bluetooth/BleBridgeSession.swift),
[Wi-Fi client](../../wled/Service/Websocket/WebsocketClient.swift),
[list controls](../../wled/View/DeviceListItemView.swift),
[editing persistence](../../wled/View/DeviceEdit/DeviceEditViewModel.swift),
[identity and upsert](../../wled/Service/DeviceFirstContactService.swift),
[Add flow](../../wled/View/DeviceAdd/DeviceAddView.swift),
[picker](../../wled/View/DeviceAdd/BlePeripheralPickerView.swift),
[permission banner](../../wled/View/LocalNetworkWarningView.swift),
[web view](../../wled/View/WebView.swift).

## Proposed connection UI and behavior

Use a tappable status on the list and detail, leading to the same Connection
sheet from either screen. Retain a link from Edit Device. The sheet displays:

- **Using now:** Connected via Bluetooth. All native controls use this route.
- **Connection mode:** Automatic / Wi-Fi only / Bluetooth only.
- **Wi-Fi:** In use, recently verified reachable, saved but not checked,
  unavailable with reason, or not configured. Show address as secondary detail.
- **Bluetooth:** In use, nearby, saved but not checked, permission needed,
  unavailable with reason, or not configured. Do not probe by connecting in a
  way that silently occupies the device or triggers pairing.
- **Actions:** Disconnect / Connect, Change connection, Set up missing method,
  and context-specific troubleshooting. Explain that lights keep their state
  when disconnecting.

Use “Connected via …” for an active verified route. Use “Saved” for configuration
only. The phone's Wi-Fi icon and the board's network association are not control
route indicators. If a future operation explicitly uses a different route,
label that operation and its requirement; do not contradict the main status.
Use text plus icons, not color alone; support VoiceOver, large text, long names,
localization and reduced motion. Label the row switch “Lights,” not an ambiguous
unlabeled connection-adjacent toggle.

Recommended eventual Automatic policy: prefer a healthy configured network
route; attempt a previously commissioned BLE method when network control fails;
show “Using Bluetooth — Wi-Fi unavailable.” Manual modes never silently change
transport. Do not pair automatically during fallback. Re-check identity and read
fresh state before enabling controls on a new route. Show failure on both routes
with actionable reasons. Keep a healthy fallback route stable during interaction;
return to the preferred route at an idle boundary only after sustained recovery,
with an explicit status update. Bound retries and cancel them on Disconnect.

Automatic is a proposed feature, not current behavior. First ship clear route
status, explicit disconnect and safe switching. Add fallback only after common
controls, command outcome rules and route ownership are defined. A request whose
response was lost may already have changed the device: refresh before retrying;
never send the same write over two routes concurrently. A failed manual switch
should offer return to the previous method, not silently override the selection.

Maintain separate model fields for saved connection methods, user mode,
manual-disconnect intent, attempted route, actual active route, route health and
verification time, recovery reason, capability set and command outcome. One
observable connection controller should drive list, detail and editor. The
previous stale-wrapper fixes help, but a preference enum plus generic
`websocketStatus` cannot express the full experience.

## Acceptance cases for the next implementation

| Scenario | Required experience / verification |
|---|---|
| Fresh BLE-only device, no network | Setup explains prerequisites/code access; connect without suggesting internet is required. |
| Fresh Wi-Fi-only or unsupported BLE firmware | Useful network control; BLE is unavailable with an explanation, not a broken choice. |
| Both methods saved and reachable | Exactly one active control route; explicit active label and mode; unused method status is honest. |
| Board on Wi-Fi while phone uses BLE | Says Bluetooth; board network association never changes the claim. |
| Manual switch in detail or editor | Same device and navigation survive; connecting state; readback; controls enable only when ready. |
| Failed manual switch | Failure reason plus Retry/Return; no misleading selected-equals-connected state. |
| Automatic fallback and recovery | Visible route changes, bounded retries, no flapping, no duplicated/uncertain write replay. |
| Disconnect, then navigate/refresh/relaunch | No retry or queued write; saved device/pairing and light state remain; Connect resumes deliberately. |
| Leave detail, hide device, second phone | Defined ownership; hidden/listed status does not unexpectedly monopolize BLE. |
| Multiple devices / rapid device switching | Route and errors remain attached to the correct device; no unbounded competing attempts. |
| Bluetooth off or permission denied/restored | Specific guidance and Settings where appropriate; no false pairing/connected claim. |
| Local Network denied while BLE works | Scope warning to network; BLE remains fully usable. |
| Wrong LAN, router loss, DHCP change, stale IP, VPN | Reachability tested against device; explain failure without assuming internet or SSID equality. |
| Address replaced by another device | Verify identity before writes; never silently retarget a saved card. |
| Pairing canceled, rejected, reset or no prompt | Recoverable action state; no endless generic spinner or unconditional paired claim. |
| Same-name nearby devices / duplicate add | Unambiguous identity; one record per verified device; explicit existing-device update result. |
| Another central occupies BLE | Do not guarantee discovery; troubleshooting and handoff guidance without claiming unverified cause. |
| Device reboot / app kill / background and return | Accurate last-known versus live values; reread before controls; honor manual disconnect. |
| In-flight write when radio drops or route changes | Report uncertain outcome; reconcile with readback; no delayed surprise changes. |
| Another controller changes power/brightness | Authoritative state updates; no stale optimistic success. |
| Wi-Fi web page fails but status socket works, or reverse | Distinguish page availability from native connection status. |
| Feature requires network while using BLE | Explain capability limitation; explicit switch; preserve any draft edits. |
| Remove / hide / reset pairing | Distinct effects; no false claim of OS bond deletion; rediscovery policy explicit. |
| Accessibility and localization | Status understandable without color; VoiceOver identifies route/state/actions; large text fits. |

Existing physical tests establish selected transport replacement, visible BLE
connection state in Edit Device, basic controls, relaunch and short foreground
recovery. They do not establish this entire matrix. Add focused model tests for
policy/command outcomes and targeted real-device UI/HIL coverage for route loss,
manual disconnect and multi-controller behavior; do not equate a passing BLE
protocol suite with a complete connection experience.
