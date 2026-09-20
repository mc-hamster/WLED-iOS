import Foundation

@MainActor
final class BleClient: NSObject, ObservableObject, DeviceConnectionClient {
    @Published var deviceState: DeviceWithState

    var onDeviceStateUpdated: ((DeviceStateInfo) -> Void)?

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private var session: BleBridgeSession?
    private var pendingState: WledState?
    private var isConnecting = false
    private var isSendingState = false
    private var isManuallyDisconnected = false
    private var retryCount = 0

    private let reconnectionDelay: TimeInterval = 2.5
    private let maxReconnectionDelay: TimeInterval = 60

    init(device: Device) {
        self.deviceState = DeviceWithState(initialDevice: device)
        super.init()
    }

    func connect() {
        guard !isConnecting else { return }
        guard let session = makeSession() else {
            deviceState.websocketStatus = .disconnected
            return
        }

        isManuallyDisconnected = false
        isConnecting = true
        deviceState.websocketStatus = .connecting

        Task {
            do {
                try await session.connect()
                let response = try await session.request(method: "GET", path: "/json")
                try handleBridgeResponse(response)
                retryCount = 0
                isConnecting = false
                deviceState.websocketStatus = .connected
                await sendPendingStateIfNeeded()
            } catch {
                await handleFailure(error)
            }
        }
    }

    func disconnect() {
        isManuallyDisconnected = true
        isConnecting = false
        pendingState = nil
        isSendingState = false
        session?.disconnect()
        deviceState.websocketStatus = .disconnected
    }

    func sendState(_ state: WledState) {
        pendingState = state
        if deviceState.websocketStatus == .connected {
            Task {
                await sendPendingStateIfNeeded()
            }
        } else {
            connect()
        }
    }

    func destroy() {
        disconnect()
    }

    private func makeSession() -> BleBridgeSession? {
        if let session {
            return session
        }

        guard let peripheralID = deviceState.device.bleIdentifierUUID else {
            return nil
        }

        let session = BleBridgeSession(
            peripheralID: peripheralID,
            expectedName: deviceState.device.bleName,
            securityMode: deviceState.device.bleSecurityModeValue,
            passkey: deviceState.device.blePasskey
        )
        session.onLivePayload = { [weak self] payload in
            Task { @MainActor in
                try? self?.handlePayload(payload)
            }
        }
        session.onPairingPromptSuggested = { message in
            print("BleClient: \(message)")
        }
        self.session = session
        return session
    }

    private func sendPendingStateIfNeeded() async {
        guard !isSendingState else { return }
        guard let state = pendingState else { return }
        guard let session = makeSession() else { return }

        pendingState = nil
        isSendingState = true

        do {
            let data = try encoder.encode(state)
            let body = String(decoding: data, as: UTF8.self)
            let response = try await session.request(method: "POST", path: "/json/state", body: body)
            try handleBridgeResponse(response, acceptsSuccessEnvelope: true)
        } catch {
            await handleFailure(error)
        }

        isSendingState = false

        if pendingState != nil {
            await sendPendingStateIfNeeded()
        }
    }

    private func handleBridgeResponse(_ response: BleBridgeResponse, acceptsSuccessEnvelope: Bool = false) throws {
        guard response.status == 200 else {
            throw BleBridgeSession.SessionError.requestFailed("BLE request failed with status \(response.status).")
        }

        if acceptsSuccessEnvelope, let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
           let success = json["success"] as? Bool, success {
            return
        }

        try handlePayload(response.body)
    }

    private func handlePayload(_ payload: Data) throws {
        let info = try decoder.decode(DeviceStateInfo.self, from: payload)
        deviceState.stateInfo = info
        deviceState.websocketStatus = .connected
        onDeviceStateUpdated?(info)
    }

    private func handleFailure(_ error: Error) async {
        print("BleClient: failure \(error.localizedDescription)")
        deviceState.websocketStatus = .disconnected
        isConnecting = false
        isSendingState = false

        if !isManuallyDisconnected {
            reconnect()
        }
    }

    private func reconnect() {
        let delay = min(reconnectionDelay * pow(2.0, Double(retryCount)), maxReconnectionDelay)
        retryCount += 1

        Task {
            try await Task.sleep(for: .seconds(delay))
            if !isManuallyDisconnected {
                connect()
            }
        }
    }
}
