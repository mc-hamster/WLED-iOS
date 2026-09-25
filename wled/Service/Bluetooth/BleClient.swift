import Foundation

@MainActor
final class BleClient: NSObject, ObservableObject, DeviceConnectionClient {
    @Published var deviceState: DeviceWithState
    var onDeviceStateUpdated: ((DeviceStateInfo) -> Void)?
    private let session: any BleBridgeConnection
    private var pendingState: WledState?
    private var connectionTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var generation = 0
    private var retryCount = 0
    private var manuallyDisconnected = true

    init(device: Device, session: (any BleBridgeConnection)? = nil) {
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
    }

    func destroy() { disconnect() }

    func sendState(_ state: WledState) {
        pendingState = pendingState?.merging(state) ?? state
        if deviceState.websocketStatus == .connected { sendPendingStateIfNeeded() } else { connect() }
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
        generation += 1
        cancelTasks()
        session.disconnect()
        deviceState.websocketStatus = .disconnected
        deviceState.connectionError = error.localizedDescription
        if (error as? BleBridgeSession.SessionError)?.requiresUserAction == true { return }
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
                  segment: newer.segment ?? segment)
    }
}
