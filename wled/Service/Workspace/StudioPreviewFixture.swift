#if DEBUG
import Foundation
import SwiftUI
import CryptoKit

/// Deterministic simulator-only design and interaction fixture. Never opens a radio or network route.
@MainActor
final class StudioPreviewFixture: ObservableObject {
    let persistence = PersistenceController(inMemory: true)
    let device: DeviceWithState
    var state: [String: Any] = ["on": true, "bri": 184, "transition": 7, "mainseg": 0, "ps": 1,
        "nl": ["on": false, "dur": 30, "mode": 1, "tbri": 0],
        "seg": [["id": 0, "n": "Living room", "start": 0, "stop": 120, "len": 120, "on": true, "bri": 255,
                  "col": [[255, 142, 72, 0], [18, 33, 80, 0], [80, 48, 128, 0]], "fx": 1, "sx": 120, "ix": 180, "pal": 1,
                  "c1": 128, "c2": 90, "c3": 16, "sel": true, "rev": false, "mi": false, "grp": 1, "spc": 0, "lc": 1]]]
    let info: [String: Any] = ["mac": "aabbccddeeff", "name": "Living room", "ver": "17.0.0", "wifi": [:],
        "leds": ["count": 120, "maxseg": 16, "lc": 1], "opt": 0,
        "ble": ["protocol": 1, "maxRequest": 4096, "security": "passkey"]]
    let effects = ["Solid", "Breathe", "Aurora", "Candle", "Colorwaves", "Fire 2012", "Fireworks", "Gradient", "Rainbow", "Sparkle", "Twinkle"]
    let palettes = ["Default", "Sunset", "Ocean", "Forest", "Aurora", "Lava", "Pastel", "Party"]
    var presets: [String: Any] = ["1": ["n": "Golden hour", "on": true, "bri": 184], "2": ["n": "After dark", "on": true, "bri": 72], "3": ["n": "Ocean drift", "on": true, "bri": 135], "4": ["n": "Evening flow", "playlist": ["ps": [1,2,3], "dur": [100,100,100], "transition": [7,7,7], "repeat": 0, "end": 0]]]

    init() {
        let record = Device(context: persistence.container.viewContext)
        record.macAddress = "aabbccddeeff"; record.customName = "Living room"; record.connectionType = "ble"
        device = DeviceWithState(initialDevice: record)
        device.activeTransport = .ble; device.websocketStatus = .connected
        device.requestAction = { [weak self] method, path, body, _ in
            guard let self else { throw WorkspaceError.connectionChanged }
            return try await self.request(method: method, path: path, body: body)
        }
        refresh()
    }

    private func refresh() {
        if let bytes = try? JSONSerialization.data(withJSONObject: ["state": state, "info": info]) {
            device.stateInfo = try? JSONDecoder().decode(DeviceStateInfo.self, from: bytes)
            device.rawStatePayload = bytes
            device.lastConfirmedAt = Date()
        }
    }

    func request(method: String, path: String, body: Data) async throws -> DeviceAPIResponse {
        let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        if path == "/ble/capabilities" { return try .json(["version": 2, "authorized": true, "pinRequired": false]) }
        if path == "/ble/auth" { return try .json(["success": true, "authorized": true]) }
        if path.hasPrefix("/settings/s.js") { return DeviceAPIResponse(status: 200, contentType: "application/javascript", body: Data("function GetV(){}".utf8)) }
        if path == "/json/effects" { return try .json(effects) }
        if path == "/json/fxdata" { return try .json(effects.map { _ in "Speed,Intensity,Custom 1,Custom 2,Custom 3,Option 1,Option 2,Option 3;!,!,!;!;1" }) }
        if path == "/json/palettes" { return try .json(palettes) }
        if path.hasPrefix("/json/palx") { return try .json(["m": 0, "p": ["1": [[0,255,90,50], [128,255,180,80], [255,124,60,180]], "2": [[0,18,50,120], [128,50,150,180], [255,80,200,230]]]]) }
        if path == "/json/info" { return try .json(info) }
        if path == "/json/state", method == "GET" { return try .json(state) }
        if path == "/json" { return try .json(["state": state, "info": info, "effects": effects, "palettes": palettes]) }
        if path == "/json/live" { return try .json(["leds": Array(repeating: "FF8E48", count: 120)]) }
        if path == "/ble/fs", payload["op"] as? String == "list" {
            return try .json(["files": [["name": "/presets.json", "size": 300]], "next": NSNull()])
        }
        if path == "/ble/fs", payload["op"] as? String == "read" {
            guard payload["path"] as? String == "/presets.json" else {
                return DeviceAPIResponse(status: 404, contentType: "application/json", body: Data("{\"error\":\"File not found\"}".utf8))
            }
            let bytes = try JSONSerialization.data(withJSONObject: presets, options: .sortedKeys)
            let offset = payload["offset"] as? Int ?? 0, next = min(offset + 1024, bytes.count)
            return try .json(["size": bytes.count, "offset": offset, "next": next, "eof": next == bytes.count,
                "revision": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), "data": bytes.subdata(in: offset..<next).base64EncodedString()])
        }
        if method == "POST", path == "/json/state" {
            for (key,value) in payload where key != "seg" { state[key] = value }
            if let segments = payload["seg"] as? [[String: Any]] {
                var current = state["seg"] as? [[String: Any]] ?? []
                for change in segments {
                    if let index = current.firstIndex(where: { $0["id"] as? Int == change["id"] as? Int }) { current[index].merge(change) { _, new in new } }
                    else { current.append(change) }
                }
                state["seg"] = current
            }
            if let id = payload["psave"] as? Int { presets[String(id)] = ["n": payload["n"] ?? "Scene", "on": true] }
            if let id = payload["pdel"] as? Int { presets[String(id)] = nil }
            refresh()
            return try .json(["success": true, "saved": true])
        }
        return try .json(["state": state, "info": info])
    }
}

struct StudioPreviewRoot: View {
    @StateObject private var fixture = StudioPreviewFixture()
    var body: some View {
        NavigationStack {
            DeviceView(device: fixture.device, onSendState: { state in
                Task { _ = try? await fixture.request(method: "POST", path: "/json/state", body: JSONEncoder().encode(state)) }
            })
        }
            .environment(\.managedObjectContext, fixture.persistence.container.viewContext)
    }
}
#endif
