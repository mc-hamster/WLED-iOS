import Testing
import Foundation
import CoreData
import SwiftUI
@testable import WLED

@MainActor
struct StudioModelTests {
    @Test func metadataKeepsHiddenSlotsAndTogglePositions() {
        let controls = StudioEffectParameter.controls(metadata: "!,Spread,,Jitter=18,!,Reverse,,Overlay;!,!;!", effect: 150)
        #expect(controls.map(\.key) == ["sx", "ix", "c2", "c3", "o1", "o3"])
        #expect(controls.map(\.title) == ["Speed", "Spread", "Jitter", "Custom 3", "Reverse", "Overlay"])
        #expect(controls.first { $0.key == "c3" }?.maximum == 31)
        #expect(controls.last?.isToggle == true)
        #expect(StudioEffectParameter.controls(metadata: ";!;", effect: 0).isEmpty)
    }

    @Test func missingMetadataUsesFirmwareCompatibleFallback() {
        #expect(StudioEffectParameter.controls(metadata: nil, effect: 42).map(\.key) == ["sx", "ix"])
        #expect(StudioEffectParameter.controls(metadata: "", effect: 130).map(\.key) == ["sx", "ix", "c1", "c2", "c3"])
    }

    @Test func presetLibraryExcludesDeletedAndReservedEntries() {
        let scenes = StudioPreset.decode([
            "0": [:], "7": ["n": "Evening"], "3": ["n": "", "playlist": ["ps": [7]]],
            "8": [:], "255": ["n": "Temporary"], "invalid": ["n": "No"]
        ])
        #expect(scenes.map(\.id) == [3, 7])
        #expect(scenes.first?.name == "Scene 3")
        #expect(scenes.first?.isPlaylist == true)
    }

    @Test func presetNamesRespectFirmwareUTF8BufferWithoutSplittingCharacters() {
        let name = StudioPreset.validName("  \(String(repeating: "🌅", count: 12))  ")
        #expect(name == String(repeating: "🌅", count: 8))
        #expect(name.utf8.count == 32)
        #expect(StudioPreset.validName("  Evening  ") == "Evening")
    }

    @Test func liveNotificationPreservesUnknownSegmentFieldsWithoutResurrectingDeletedSegments() {
        let persistence = PersistenceController(inMemory: true)
        let saved = Device(context: persistence.container.viewContext)
        saved.macAddress = "aabbccddeeff"
        let model = StudioModel(device: DeviceWithState(initialDevice: saved))
        model.state = ["seg": [["id": 2, "startY": 4, "stopY": 12, "cct": 80, "c3": 7, "bm": 6], ["id": 3]]]
        model.selectedSegmentID = 3
        model.ingest(WledState(brightness: 170, segment: [Segment(id: 2, effect: 42)]))
        #expect(model.segment?.id == 2)
        #expect(model.segment?.number("cct") == 80)
        #expect(model.segment?.number("stopY") == 12)
        #expect(model.segment?.number("bm") == 6)
        #expect(model.segment?.number("fx") == 42)
        #expect(model.segments.count == 1)
        #expect(model.stateNumber("bri") == 170)
    }

    @Test func rawLiveStateUpdatesAdvancedControlsChangedByOtherClients() {
        let persistence = PersistenceController(inMemory: true)
        let saved = Device(context: persistence.container.viewContext)
        saved.macAddress = "aabbccddeeff"
        let model = StudioModel(device: DeviceWithState(initialDevice: saved))
        model.state = ["seg": [["id": 0, "cct": 80, "c3": 7, "bm": 6]]]
        model.ingest(rawPayload: Data(#"{"state":{"on":true,"seg":[{"id":0,"cct":200,"c3":27,"bm":2}]},"info":{"cpalcount":1}}"#.utf8))
        #expect(model.segment?.number("cct") == 200)
        #expect(model.segment?.number("c3") == 27)
        #expect(model.segment?.number("bm") == 2)
        #expect(model.info["cpalcount"] as? Int == 1)
    }

    @Test func colorDragCoalescesLatestValuesAndPreservesIndependentSlots() async throws {
        let persistence = PersistenceController(inMemory: true)
        let saved = Device(context: persistence.container.viewContext)
        saved.macAddress = "aabbccddeeff"
        let device = DeviceWithState(initialDevice: saved)
        device.websocketStatus = .connected
        device.activeTransport = .ble
        let model = StudioModel(device: device)
        model.state = ["seg": [["id": 0, "col": [[0, 0, 0, 20], [0, 0, 0, 30], [0, 0, 0, 0]]]]]
        var posts: [[String: Any]] = []
        device.requestAction = { method, _, body, _ in
            if method == "POST" {
                let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
                posts.append(payload)
                model.state["seg"] = payload["seg"]
                return try .json(["success": true])
            }
            return try .json(["state": model.state, "info": [:]])
        }
        model.setColor(Color(red: 1, green: 0, blue: 0), slot: 0)
        model.setColor(Color(red: 0, green: 0, blue: 1), slot: 1)
        model.setColor(Color(red: 0, green: 1, blue: 0), slot: 0)
        for _ in 0..<40 where posts.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        #expect(posts.count == 1)
        #expect(model.segment?.colors[0] == [0, 255, 0, 20])
        #expect(model.segment?.colors[1] == [0, 0, 255, 30])
        model.setColor(.red, slot: 0)
        model.cancelPendingColorChanges()
        try await Task.sleep(for: .milliseconds(250))
        #expect(posts.count == 1, "Leaving the screen cancels unsent color edits")
    }

    @Test func acceptedPresetWriteWithoutPersistenceReceiptIsNotReportedAsSaved() async {
        let persistence = PersistenceController(inMemory: true)
        let saved = Device(context: persistence.container.viewContext)
        saved.macAddress = "aabbccddeeff"
        let device = DeviceWithState(initialDevice: saved)
        device.websocketStatus = .connected
        device.activeTransport = .ble
        let model = StudioModel(device: device)
        model.presets = StudioPreset.decode(["1": ["n": "Evening"]])
        var paths: [String] = []
        device.requestAction = { _, path, _, _ in
            paths.append(path)
            return try .json(["success": true])
        }
        let accepted = await model.savePreset(id: 1, name: "Evening")
        #expect(!accepted)
        #expect(model.notice == nil)
        #expect(model.error?.contains("did not confirm") == true)
        #expect(paths == ["/json/state"], "An old matching scene name must not substitute for a persistence receipt")
        paths.removeAll()
        let renamed = await model.renamePreset(model.presets[0], name: "Evening")
        #expect(!renamed)
        #expect(model.notice == nil)
        #expect(paths == ["/ble/presets"], "Rename also requires the device's persistence receipt")
    }

    @Test func customPalettesKeepFirmwareIDsAndIgnoreInvalidCounts() {
        let persistence = PersistenceController(inMemory: true)
        let saved = Device(context: persistence.container.viewContext)
        saved.macAddress = "aabbccddeeff"
        let model = StudioModel(device: DeviceWithState(initialDevice: saved))
        model.palettes = ["Default", "Random"]
        model.info = ["cpalcount": 2, "umpalnames": ["Audio colors"]]
        #expect(model.paletteEntries.map(\.id) == [0, 1, 255, 200, 199])
        model.info = ["cpalcount": -1]
        #expect(model.paletteEntries.count == 2)
    }
}
