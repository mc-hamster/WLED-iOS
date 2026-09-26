import Foundation
import SwiftUI

@MainActor
final class StudioModel: ObservableObject {
    let device: DeviceWithState
    @Published var state: [String: Any] = [:]
    @Published var info: [String: Any] = [:]
    @Published var selectedSegmentID = 0
    @Published var effects: [String] = []
    @Published var effectMetadata: [String] = []
    @Published var palettes: [String] = []
    @Published var paletteColors: [Int: [Color]] = [:]
    @Published var presets: [StudioPreset] = []
    @Published var isLoading = false
    @Published var isLoadingCatalogs = false
    @Published var isLoadingPresets = false
    @Published var controlRevision = 0
    @Published var isMutatingLibrary = false
    @Published var error: String?
    @Published var libraryError: String?
    @Published var notice: String?
    var catalogsLoaded = false
    var libraryLoaded = false
    @Published private var pendingCommands = 0
    private var colorTask: Task<Void, Never>?
    private var pendingColors: [Int: [Int: [Int]]] = [:]
    private var colorWriteInFlight = false
    var isLoadingLibrary: Bool { isLoadingCatalogs || isLoadingPresets }
    var isSaving: Bool { pendingCommands > 0 || isMutatingLibrary }

    init(device: DeviceWithState) {
        self.device = device
        ingest(device.stateInfo?.state)
        selectedSegmentID = stateNumber("mainseg")
    }

    var segments: [StudioSegment] {
        (state["seg"] as? [[String: Any]] ?? []).map { StudioSegment(raw: $0) }
    }
    var segment: StudioSegment? { segments.first { $0.id == selectedSegmentID } ?? segments.first }
    var accent: Color { segment?.color(at: 0) ?? device.currentColor }
    var effectID: Int { segment?.number("fx") ?? 0 }
    var effectName: String { effects.indices.contains(effectID) ? effects[effectID] : (effectID == 0 ? "Solid color" : "Effect \(effectID)") }
    var paletteID: Int { segment?.number("pal") ?? 0 }
    var paletteName: String { paletteEntries.first { $0.id == paletteID }?.name ?? "Palette \(paletteID)" }
    var paletteEntries: [StudioCatalogEntry] {
        var result = palettes.enumerated().map { StudioCatalogEntry(id: $0.offset, name: $0.element) }
        let usermodNames = info["umpalnames"] as? [String] ?? []
        result += usermodNames.prefix(55).enumerated().map { StudioCatalogEntry(id: 255 - $0.offset, name: $0.element) }
        let customCount = min(max(info["cpalcount"] as? Int ?? 0, 0), max(0, 200 - palettes.count))
        result += (0..<customCount).map { StudioCatalogEntry(id: 200 - $0, name: "Custom \($0)") }
        return result
    }
    var parameters: [StudioEffectParameter] {
        StudioEffectParameter.controls(metadata: effectMetadata.indices.contains(effectID) ? effectMetadata[effectID] : nil, effect: effectID)
    }
    var ledCount: Int { ((info["leds"] as? [String: Any])?["count"] as? Int) ?? 0 }
    var maxSegments: Int { min(max(((info["leds"] as? [String: Any])?["maxseg"] as? Int) ?? 32, 1), 256) }
    var nextPresetID: Int? { (1...250).first { candidate in !presets.contains { $0.id == candidate } } }
    var nextSegmentID: Int? { (0..<maxSegments).first { candidate in !segments.contains { $0.id == candidate } } }

    func stateNumber(_ key: String, default value: Int = 0) -> Int { (state[key] as? NSNumber)?.intValue ?? value }
    func stateFlag(_ key: String, default value: Bool = false) -> Bool { state[key] as? Bool ?? value }

    /// Notifications omit some advanced fields in the native response model. Keep those fields intact.
    func ingest(_ value: WledState?) {
        guard let value, let data = try? JSONEncoder().encode(value),
              let incoming = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var merged = state
        for (key, newValue) in incoming where key != "seg" { merged[key] = newValue }
        if let incomingSegments = incoming["seg"] as? [[String: Any]] {
            let prior = state["seg"] as? [[String: Any]] ?? []
            merged["seg"] = incomingSegments.map { fresh -> [String: Any] in
                let id = fresh["id"] as? Int
                var result = prior.first { ($0["id"] as? Int) == id } ?? [:]
                result.merge(fresh) { _, new in new }
                return result
            }
        }
        state = merged
        reconcileSelection()
    }

    func ingest(rawPayload: Data?) {
        guard let rawPayload,
              let root = try? JSONSerialization.jsonObject(with: rawPayload) as? [String: Any] else { return }
        if let updated = root["state"] as? [String: Any] {
            state = updated
        } else if root["seg"] != nil {
            state = root
        }
        if let updatedInfo = root["info"] as? [String: Any] { info = updatedInfo }
        reconcileSelection()
    }

    func refresh() async {
        guard device.isOnline, !isLoading else { return }
        isLoading = true
        defer { isLoading = false; controlRevision += 1 }
        do {
            try await readState()
            error = nil
        } catch {
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }

    func readState(expectedEpoch: UUID? = nil) async throws {
        let result = try await json(path: "/json", expectedEpoch: expectedEpoch)
        guard let root = result as? [String: Any], let updated = root["state"] as? [String: Any] else {
            throw StudioError("The device returned an incomplete light state. Pull down to try again.")
        }
        state = updated
        info = root["info"] as? [String: Any] ?? info
        reconcileSelection()
    }

    private func reconcileSelection() {
        if !segments.contains(where: { $0.id == selectedSegmentID }) {
            selectedSegmentID = segments.first?.id ?? 0
        }
    }

    func send(_ payload: [String: Any]) {
        Task { await apply(payload) }
    }

    @discardableResult
    func apply(_ payload: [String: Any]) async -> Bool {
        guard device.isOnline else { error = "Reconnect to change your lights."; return false }
        let epoch = device.connectionEpoch
        pendingCommands += 1
        notice = nil
        defer { pendingCommands -= 1; controlRevision += 1 }
        do {
            _ = try await json(method: "POST", path: "/json/state", payload: payload, expectedEpoch: epoch)
            try await readState(expectedEpoch: epoch)
            if let preset = payload["ps"] as? Int {
                for _ in 0..<10 where stateNumber("ps", default: -1) != preset && stateNumber("pl", default: -1) != preset {
                    try await Task.sleep(for: .milliseconds(150))
                    try await readState(expectedEpoch: epoch)
                }
                guard stateNumber("ps", default: -1) == preset || stateNumber("pl", default: -1) == preset else {
                    throw StudioError("The selected scene has not been confirmed by the device.")
                }
            }
            error = nil
            return true
        } catch {
            self.error = "The change could not be confirmed. \(error.localizedDescription)"
            return false
        }
    }

    func sendSegment(_ payload: [String: Any]) {
        guard let segment else { return }
        var body = payload
        body["id"] = segment.id
        send(["seg": [body]])
    }

    func setColor(_ color: Color, slot: Int) {
        guard let segment else { return }
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
        var channels = segment.colors
        while channels.count < 3 { channels.append([0, 0, 0, 0]) }
        let white = channels[slot].count > 3 ? channels[slot][3] : 0
        channels[slot] = [Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()), white]
        pendingColors[segment.id, default: [:]][slot] = channels[slot]
        scheduleColorFlush()
    }

    func cancelPendingColorChanges() {
        colorTask?.cancel()
        colorTask = nil
        pendingColors = [:]
    }

    private func scheduleColorFlush() {
        colorTask?.cancel()
        let epoch = device.connectionEpoch
        colorTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self else { return }
            self.colorTask = nil
            await self.flushColors(epoch: epoch)
        }
    }

    private func flushColors(epoch: UUID) async {
        guard !colorWriteInFlight else { return }
        guard device.connectionEpoch == epoch, device.isOnline else { cancelPendingColorChanges(); return }
        var changes: [[String: Any]] = []
        for (id, slots) in pendingColors {
            guard let segment = segments.first(where: { $0.id == id }) else { continue }
            var colors = segment.colors
            while colors.count < 3 { colors.append([0, 0, 0, 0]) }
            for (slot, channels) in slots { colors[slot] = channels }
            changes.append(["id": id, "col": colors])
        }
        pendingColors = [:]
        guard !changes.isEmpty else { return }
        colorWriteInFlight = true
        _ = await apply(["seg": changes])
        colorWriteInFlight = false
        if !pendingColors.isEmpty { scheduleColorFlush() }
    }

    func setWhite(_ value: Int, slot: Int) {
        guard let segment else { return }
        var channels = segment.colors
        while channels.count < 3 { channels.append([0, 0, 0, 0]) }
        while channels[slot].count < 4 { channels[slot].append(0) }
        channels[slot][3] = value
        sendSegment(["col": channels])
    }

    func checkConnection(_ epoch: UUID) throws {
        try Task.checkCancellation()
        guard device.isOnline, device.connectionEpoch == epoch else {
            throw StudioError("The connection changed. Reconnect and refresh before trying again.")
        }
    }

    func json(method: String = "GET", path: String, payload: [String: Any]? = nil, expectedEpoch: UUID? = nil) async throws -> Any {
        let epoch = expectedEpoch ?? device.connectionEpoch
        try checkConnection(epoch)
        let data = try payload.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let response = try await device.workspaceRequest(method: method, path: path, body: data)
        try checkConnection(epoch)
        guard (200..<300).contains(response.status) else {
            throw StudioError("The device returned status \(response.status) for \(path).")
        }
        let object = try JSONSerialization.jsonObject(with: response.body)
        if let envelope = object as? [String: Any], let code = envelope["error"] as? Int, code != 0 {
            throw StudioError("WLED could not complete the request (error \(code)).")
        }
        return object
    }
}
