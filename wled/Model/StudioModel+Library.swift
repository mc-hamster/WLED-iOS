import Foundation
import SwiftUI

extension StudioModel {
    func loadCatalogs(force: Bool = false) async {
        guard device.isOnline, !isLoadingCatalogs, !catalogsLoaded || force else { return }
        isLoadingCatalogs = true
        let epoch = device.connectionEpoch
        defer { isLoadingCatalogs = false }
        do {
            guard let names = try await json(path: "/json/effects", expectedEpoch: epoch) as? [String] else {
                throw StudioError("The effect catalog could not be read.")
            }
            effects = names
            effectMetadata = (try await json(path: "/json/fxdata", expectedEpoch: epoch)) as? [String] ?? []
            guard let names = try await json(path: "/json/palettes", expectedEpoch: epoch) as? [String] else {
                throw StudioError("The palette catalog could not be read.")
            }
            palettes = names
            catalogsLoaded = true
            libraryError = nil
        } catch {
            if !(error is CancellationError) { libraryError = error.localizedDescription }
        }
    }

    func loadPalettePreviews() async {
        guard device.isOnline, paletteColors.isEmpty else { return }
        // Previews are a progressively loaded enhancement; palette names and selection stay available.
        let epoch = device.connectionEpoch
        var page = 0
        var lastPage = 0
        repeat {
            do {
                guard let response = try await json(path: "/json/palx?page=\(page)", expectedEpoch: epoch) as? [String: Any] else { return }
                lastPage = min(response["m"] as? Int ?? 0, 32)
                if let entries = response["p"] as? [String: Any] {
                    for (key, value) in entries {
                        guard let id = Int(key), let stops = value as? [Any] else { continue }
                        let colors = stops.compactMap { item -> Color? in
                            guard let stop = item as? [Int], stop.count >= 4 else { return nil }
                            return Color(red: Double(stop[1]) / 255, green: Double(stop[2]) / 255, blue: Double(stop[3]) / 255)
                        }
                        if !colors.isEmpty { paletteColors[id] = colors }
                    }
                }
            } catch { return }
            page += 1
        } while page <= lastPage && !Task.isCancelled
    }

    func loadPresets(force: Bool = false) async {
        guard device.isOnline, !isLoadingPresets, !libraryLoaded || force else { return }
        isLoadingPresets = true
        defer { isLoadingPresets = false }
        do {
            try await readPresets()
            libraryError = nil
        } catch {
            if !(error is CancellationError) { libraryError = error.localizedDescription }
        }
    }

    private func readPresets(expectedEpoch: UUID? = nil) async throws {
        let epoch = expectedEpoch ?? device.connectionEpoch
        try checkConnection(epoch)
        let response = try await device.workspaceRequest(path: "/presets.json")
        try checkConnection(epoch)
        if response.status == 404 {
            presets = []
            libraryLoaded = true
            return
        }
        guard (200..<300).contains(response.status),
              let dictionary = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw StudioError("Your scenes could not be read. Try refreshing the library.")
        }
        presets = StudioPreset.decode(dictionary)
        libraryLoaded = true
    }

    @discardableResult
    func savePreset(id: Int, name: String, contents: [String: Any]? = nil) async -> Bool {
        guard (1...250).contains(id) else { error = "Choose a scene number from 1 to 250."; return false }
        guard !StudioPreset.validName(name).isEmpty else { error = "Give the scene a name."; return false }
        guard beginLibraryMutation() else { return false }
        defer { isMutatingLibrary = false }
        let epoch = device.connectionEpoch
        var payload = contents ?? ["ib": true, "sb": true]
        payload["psave"] = id
        payload["n"] = StudioPreset.validName(name)
        if contents != nil { payload["o"] = true }
        do {
            try await writeLibraryMutation(payload, expectedEpoch: epoch)
            // Wi-Fi releases may acknowledge before their filesystem save completes.
            for _ in 0..<5 {
                try await Task.sleep(for: .milliseconds(250))
                try await readPresets(expectedEpoch: epoch)
                if presets.contains(where: { $0.id == id && $0.name == (payload["n"] as? String) }) {
                    notice = "Scene saved on your device."
                    return true
                }
            }
            error = "The scene save was accepted, but could not be verified. Refresh the library before trying again."
        } catch { self.error = "The scene save could not be verified. \(error.localizedDescription)" }
        return false
    }

    func renamePreset(_ preset: StudioPreset, name: String) async -> Bool {
        let title = StudioPreset.validName(name)
        guard !title.isEmpty else { error = "Give the scene a name."; return false }
        if device.activeTransport != .ble {
            return await savePreset(id: preset.id, name: title, contents: preset.raw)
        }
        guard beginLibraryMutation() else { return false }
        defer { isMutatingLibrary = false }
        let epoch = device.connectionEpoch
        do {
            guard let receipt = try await json(method: "POST", path: "/ble/presets", payload: ["op": "rename", "id": preset.id, "name": title], expectedEpoch: epoch) as? [String: Any],
                  receipt["success"] as? Bool == true, receipt["saved"] as? Bool == true else {
                throw StudioError("The device did not confirm the scene was renamed. Refresh before trying again.")
            }
            try await readPresets(expectedEpoch: epoch)
            guard presets.contains(where: { $0.id == preset.id && $0.name == title }) else {
                throw StudioError("The new scene name could not be confirmed.")
            }
            error = nil
            notice = "Scene renamed."
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    /// A matching old scene name cannot prove a replacement was persisted.
    /// Bluetooth workspace firmware issues this receipt after the filesystem write completes.
    private func writeLibraryMutation(_ body: [String: Any], expectedEpoch: UUID) async throws {
        var payload = body
        payload["v"] = false
        let requiresReceipt = device.activeTransport == .ble
        defer { controlRevision += 1 }
        let reply = try await json(method: "POST", path: "/json/state", payload: payload, expectedEpoch: expectedEpoch)
        if requiresReceipt {
            guard let receipt = reply as? [String: Any], receipt["success"] as? Bool == true,
                  receipt["saved"] as? Bool == true else {
                throw StudioError("The device did not confirm the scene was saved. Refresh before trying again.")
            }
        }
        try await readState(expectedEpoch: expectedEpoch)
        error = nil
    }

    private func beginLibraryMutation() -> Bool {
        guard !isMutatingLibrary else { error = "Wait for the current scene save to finish."; return false }
        isMutatingLibrary = true
        notice = nil
        return true
    }

    func deletePreset(_ preset: StudioPreset) async -> Bool {
        guard beginLibraryMutation() else { return false }
        defer { isMutatingLibrary = false }
        let epoch = device.connectionEpoch
        do {
            try await writeLibraryMutation(["pdel": preset.id], expectedEpoch: epoch)
            for _ in 0..<5 {
                try await Task.sleep(for: .milliseconds(250))
                try await readPresets(expectedEpoch: epoch)
                if !presets.contains(where: { $0.id == preset.id }) {
                    notice = "Scene deleted."
                    return true
                }
            }
            error = "The scene deletion could not be confirmed. Refresh your library."
        } catch { self.error = error.localizedDescription }
        return false
    }
}
