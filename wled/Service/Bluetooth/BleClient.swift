import Foundation

@MainActor
final class BleClient: NSObject, ObservableObject, DeviceConnectionClient {
    @Published var deviceState: DeviceWithState
    var onDeviceStateUpdated: ((DeviceStateInfo) -> Void)?
    private let automaticallyRetries: Bool
    private let session: any BleBridgeConnection
    private var pendingState: WledState?
    private var connectionTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var generation = 0
    private var retryCount = 0
    private var manuallyDisconnected = true

    init(device: Device, session: (any BleBridgeConnection)? = nil, automaticallyRetries: Bool = true) {
        self.automaticallyRetries = automaticallyRetries
        self.deviceState = DeviceWithState(initialDevice: device)
        self.session = session ?? BleBridgeSession(peripheralID: device.bleIdentifierUUID ?? UUID())
        super.init()
        self.session.onLivePayload = { [weak self] payload in
            guard let self, !self.manuallyDisconnected else { return }
            do { try self.handlePayload(payload) } catch { self.handleFailure(error) }
        }
        self.session.onDisconnect = { [weak self] error in self?.handleFailure(error) }
    }

    func connect() {
        guard connectionTask == nil, deviceState.websocketStatus != .connected else { return }
        manuallyDisconnected = false
        retryTask?.cancel()
        retryTask = nil
        deviceState.connectionError = nil
        deviceState.requiresUserAction = false
        deviceState.attemptedTransport = .ble
        deviceState.websocketStatus = .connecting
        let current = generation
        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.session.connect()
                let response = try await self.session.request(method: "GET", path: "/json", body: "")
                guard current == self.generation, !Task.isCancelled else { return }
                try self.handleBridgeResponse(response)
                self.retryCount = 0
                self.connectionTask = nil
                self.deviceState.activeTransport = .ble
                self.deviceState.websocketStatus = .connected
                self.sendPendingStateIfNeeded()
            } catch {
                if current == self.generation { self.handleFailure(error) }
            }
        }
    }

    func disconnect() {
        manuallyDisconnected = true
        generation += 1
        cancelTasks()
        pendingState = nil
        session.disconnect()
        deviceState.websocketStatus = .disconnected
        deviceState.activeTransport = nil
        deviceState.isSending = false
    }

    func destroy() { disconnect() }

    func sendState(_ state: WledState) {
        guard deviceState.isOnline, !manuallyDisconnected else {
            deviceState.commandMessage = "Not sent. Connect before changing the lights."
            return
        }
        deviceState.isSending = true
        deviceState.commandMessage = "Sending…"
        pendingState = pendingState?.merging(state) ?? state
        sendPendingStateIfNeeded()
    }

    private func sendPendingStateIfNeeded() {
        guard stateTask == nil, connectionTask == nil, deviceState.websocketStatus == .connected,
              pendingState != nil else { return }
        let current = generation
        stateTask = Task { [weak self] in
            guard let self else { return }
            do {
                while let state = self.pendingState {
                    try Task.checkCancellation()
                    self.pendingState = nil
                    let body = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
                    let response = try await self.session.request(method: "POST", path: "/json/state", body: body)
                    guard current == self.generation, !Task.isCancelled else { return }
                    try self.handleBridgeResponse(response, acceptsSuccessEnvelope: true)
                    // Read authoritative state even when live indications are not supported by older firmware.
                    let refreshed = try await self.session.request(method: "GET", path: "/json", body: "")
                    guard current == self.generation, !Task.isCancelled else { return }
                    try self.handleBridgeResponse(refreshed)
                }
                self.deviceState.isSending = false
                self.deviceState.commandMessage = "State refreshed from WLED"
                self.stateTask = nil
            } catch {
                if current == self.generation { self.handleFailure(error) }
            }
        }
    }

    private func handleBridgeResponse(_ response: BleBridgeResponse, acceptsSuccessEnvelope: Bool = false) throws {
        guard response.status == 200 else {
            throw BleBridgeSession.SessionError.requestFailed("WLED rejected the Bluetooth request (\(response.status)).")
        }
        if acceptsSuccessEnvelope,
           let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
           json["success"] as? Bool == true { return }
        try handlePayload(response.body)
    }

    private func handlePayload(_ payload: Data) throws {
        let info = try JSONDecoder().decode(DeviceStateInfo.self, from: payload)
        guard normalizedDeviceMAC(info.info.mac) == normalizedDeviceMAC(deviceState.device.macAddress),
              !normalizedDeviceMAC(info.info.mac).isEmpty else {
            throw BleBridgeSession.SessionError.pairingFailed("The connected device has a different identity. Remove it and add the correct device.")
        }
        deviceState.lastConfirmedAt = Date()
        deviceState.stateInfo = info
        onDeviceStateUpdated?(info)
    }

    private func cancelTasks() {
        connectionTask?.cancel()
        stateTask?.cancel()
        retryTask?.cancel()
        connectionTask = nil
        stateTask = nil
        retryTask = nil
    }

    private func handleFailure(_ error: Error) {
        guard !manuallyDisconnected else { return }
        if deviceState.isSending { deviceState.commandMessage = "Change not confirmed. Check the refreshed state before trying again." }
        deviceState.isSending = false
        pendingState = nil
        generation += 1
        cancelTasks()
        session.disconnect()
        deviceState.websocketStatus = .disconnected
        deviceState.connectionError = error.localizedDescription
        deviceState.activeTransport = nil
        deviceState.requiresUserAction = (error as? BleBridgeSession.SessionError)?.requiresUserAction == true
        if !automaticallyRetries || deviceState.requiresUserAction { return }
        let delay = min(2.5 * pow(2, Double(min(retryCount, 5))), 60)
        retryCount += 1
        let current = generation
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.generation == current, !self.manuallyDisconnected else { return }
            self.retryTask = nil
            self.connect()
        }
    }
}

extension WledState {
    /// Keep independent control changes while the preceding BLE write is in flight.
    func merging(_ newer: WledState) -> WledState {
        WledState(isOn: newer.isOn ?? isOn, brightness: newer.brightness ?? brightness,
                  transition: newer.transition ?? transition,
                  selectedPresetId: newer.selectedPresetId ?? selectedPresetId,
                  selectedPlaylistId: newer.selectedPlaylistId ?? selectedPlaylistId,
                  nightlight: newer.nightlight ?? nightlight,
                  liveDataOverride: newer.liveDataOverride ?? liveDataOverride,
                  mainSegment: newer.mainSegment ?? mainSegment,
                  segment: mergingSegments(newer.segment))
    }

    private func mergingSegments(_ newer: [Segment]?) -> [Segment]? {
        guard let newer else { return segment }
        guard let older = segment else { return newer }
        let olderIDs = older.compactMap(\.id)
        let newerIDs = newer.compactMap(\.id)
        // Missing IDs use array positions in WLED. Repeated IDs can be ordered
        // operations. Keep those arrays intact instead of inventing targets or
        // changing their order. Geometry commands also remain intact: an old
        // stop could shadow a newer len. Native controls use explicit IDs and
        // do not change segment geometry.
        guard olderIDs.count == older.count, newerIDs.count == newer.count,
              Set(olderIDs).count == older.count, Set(newerIDs).count == newer.count,
              !older.contains(where: { $0.changesGeometry }),
              !newer.contains(where: { $0.changesGeometry }) else { return newer }
        var combined = older
        for update in newer {
            if let index = combined.firstIndex(where: { $0.id == update.id }) {
                combined[index] = combined[index].mergingControlFields(update)
            } else {
                combined.append(update)
            }
        }
        return combined
    }
}

private extension Segment {
    var changesGeometry: Bool {
        start != nil || stop != nil || length != nil || grouping != nil || spacing != nil
    }

    func mergingControlFields(_ newer: Segment) -> Segment {
        Segment(id: newer.id ?? id,
                start: newer.start ?? start, stop: newer.stop ?? stop,
                length: newer.length ?? length, grouping: newer.grouping ?? grouping,
                spacing: newer.spacing ?? spacing, isOn: newer.isOn ?? isOn,
                brightness: newer.brightness ?? brightness, colors: mergingColorSlots(newer.colors),
                effect: newer.effect ?? effect, effectSpeed: newer.effectSpeed ?? effectSpeed,
                effectInt64ensity: newer.effectInt64ensity ?? effectInt64ensity,
                palette: newer.palette ?? palette, isSelected: newer.isSelected ?? isSelected,
                isReversed: newer.isReversed ?? isReversed, isMirrored: newer.isMirrored ?? isMirrored)
    }

    func mergingColorSlots(_ newer: [[Int64]]?) -> [[Int64]]? {
        guard let newer else { return colors }
        guard var combined = colors else { return newer }
        // Empty/missing color slots leave their previous value unchanged. A
        // supplied RGB/RGBW array replaces the whole slot, including white.
        for (index, color) in newer.enumerated() where !color.isEmpty {
            while combined.count <= index { combined.append([]) }
            combined[index] = color
        }
        return combined
    }
}
