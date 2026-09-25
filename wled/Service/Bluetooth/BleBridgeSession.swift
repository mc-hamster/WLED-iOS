import Foundation

@MainActor
protocol BleBridgeConnection: AnyObject {
    var onLivePayload: ((Data) -> Void)? { get set }
    var onDisconnect: ((Error) -> Void)? { get set }
    func connect() async throws
    func disconnect()
    func request(method: String, path: String, body: String) async throws -> BleBridgeResponse
}

@MainActor
final class BleBridgeSession: BleBridgeConnection {
    enum SessionError: LocalizedError {
        case bluetoothUnavailable, bluetoothUnauthorized, bluetoothUnsupported
        case deviceNotFound, serviceNotFound, rxCharacteristicNotFound, txCharacteristicNotFound
        case requestAlreadyInFlight, requestTooLarge, invalidResponse, requestTimedOut, connectionTimedOut, disconnected
        case requestFailed(String), pairingFailed(String)

        var requiresUserAction: Bool {
            switch self {
            case .bluetoothUnauthorized, .bluetoothUnsupported, .serviceNotFound,
                 .rxCharacteristicNotFound, .txCharacteristicNotFound, .pairingFailed: return true
            default: return false
            }
        }

        var errorDescription: String? {
            switch self {
            case .bluetoothUnavailable: return "Turn on Bluetooth, then try again."
            case .bluetoothUnauthorized: return "Allow Bluetooth access for WLED in Settings, then try again."
            case .bluetoothUnsupported: return "Bluetooth LE is not available on this device."
            case .deviceNotFound: return "Keep your WLED device powered on and nearby, then try again."
            case .serviceNotFound, .rxCharacteristicNotFound, .txCharacteristicNotFound:
                return "This device needs firmware with the WLED Bluetooth bridge enabled."
            case .requestAlreadyInFlight: return "A Bluetooth request is already in progress."
            case .requestTooLarge: return "This request exceeds WLED’s 4096-byte Bluetooth limit. Use Wi-Fi for larger changes."
            case .invalidResponse: return "WLED sent an incomplete or invalid Bluetooth response. Please reconnect."
            case .requestTimedOut: return "WLED did not respond. Keep the device nearby and try again."
            case .connectionTimedOut: return "Connection timed out. Keep WLED nearby and accept the iOS pairing prompt."
            case .disconnected: return "The Bluetooth connection was lost."
            case .requestFailed(let message), .pairingFailed(let message): return message
            }
        }
    }

    var onLivePayload: ((Data) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    private let transport: any BleTransport
    private let connectionTimeout: Duration
    private let requestTimeout: Duration
    private var readyWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var responseContinuation: CheckedContinuation<BleBridgeResponse, Error>?
    private var writeContinuation: CheckedContinuation<Void, Error>?
    private var connectionTimer: Task<Void, Never>?
    private var responseTimer: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var connectionID: UUID?
    private var requestID: UUID?
    private var pendingResponse: BleBridgeResponse?
    private var writesFinished = false
    private var writeLength = 20
    private var isReady = false
    private var responseAssembler = BleFrameAssembler()
    private var liveAssembler = BleFrameAssembler()

    convenience init(peripheralID: UUID) {
        // iOS owns pairing and bond storage; app fields cannot change peripheral security.
        self.init(transport: CoreBluetoothTransport(peripheralID: peripheralID))
    }

    init(transport: any BleTransport, connectionTimeout: Duration = .seconds(90),
         requestTimeout: Duration = .seconds(30)) {
        self.transport = transport
        self.connectionTimeout = connectionTimeout
        self.requestTimeout = requestTimeout
        transport.onEvent = { [weak self] event in self?.handle(event) }
    }

    func connect() async throws {
        try Task.checkCancellation()
        if isReady { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                readyWaiters[waiterID] = continuation
                guard connectionID == nil else { return }
                let id = UUID()
                connectionID = id
                connectionTimer = Task { [weak self, connectionTimeout] in
                    do { try await Task.sleep(for: connectionTimeout) } catch { return }
                    guard let self, self.connectionID == id, !self.isReady else { return }
                    self.fail(SessionError.connectionTimedOut)
                }
                transport.start()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let waiter = self.readyWaiters.removeValue(forKey: waiterID) else { return }
                waiter.resume(throwing: CancellationError())
                if self.readyWaiters.isEmpty && !self.isReady { self.fail(CancellationError(), notify: false) }
            }
        }
        try Task.checkCancellation()
    }

    func disconnect() { fail(CancellationError(), notify: false) }

    func request(method: String, path: String, body: String = "") async throws -> BleBridgeResponse {
        try Task.checkCancellation()
        // Claim the slot before connect() suspends, so simultaneous callers cannot overwrite continuations.
        guard requestID == nil else { throw SessionError.requestAlreadyInFlight }
        let payload = Data("\(method.uppercased()) \(path)\n\n\(body)".utf8)
        guard payload.count <= 4096 else { throw SessionError.requestTooLarge }
        let id = UUID()
        requestID = id
        defer { if requestID == id { requestID = nil } }
        do {
            try await connect()
            try Task.checkCancellation()
            let chunks = try BleBridgeCodec.chunks(payload, maximumWriteLength: writeLength)
            responseAssembler.reset()
            pendingResponse = nil
            writesFinished = false
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    responseContinuation = continuation
                    armResponseTimeout(id: id)
                    sendTask = Task { [weak self] in
                        guard let self else { return }
                        do {
                            for chunk in chunks {
                                try Task.checkCancellation()
                                guard self.requestID == id, self.isReady else { throw SessionError.disconnected }
                                try await withCheckedThrowingContinuation { continuation in
                                    self.writeContinuation = continuation
                                    self.transport.write(chunk)
                                }
                            }
                            if self.requestID == id {
                                self.writesFinished = true
                                self.finishResponseIfReady()
                            }
                        } catch {
                            if self.requestID == id { self.fail(error) }
                        }
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard let self, self.requestID == id else { return }
                    self.fail(CancellationError(), notify: false)
                }
            }
        } catch {
            // Unidentified late packets must never become the next request's response.
            if requestID == id { fail(error, notify: !(error is CancellationError)) }
            throw error
        }
    }

    private func handle(_ event: BleTransportEvent) {
        guard connectionID != nil else { return }
        switch event {
        case .ready(let maximumWriteLength):
            guard maximumWriteLength >= 3 else { fail(SessionError.invalidResponse); return }
            isReady = true
            writeLength = min(244, maximumWriteLength)
            connectionTimer?.cancel()
            connectionTimer = nil
            let waiters = readyWaiters.values
            readyWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        case .writeCompleted(let error):
            if let error { fail(error); return }
            let waiter = writeContinuation
            writeContinuation = nil
            waiter?.resume()
            if let requestID { armResponseTimeout(id: requestID) }
        case .response(let data):
            guard responseContinuation != nil else { return }
            if let requestID { armResponseTimeout(id: requestID) }
            do {
                if let payload = try responseAssembler.append(data) {
                    let response = try BleBridgeCodec.parseResponse(payload)
                    pendingResponse = response
                    finishResponseIfReady()
                }
            } catch { fail(error) }
        case .live(let data):
            do {
                if let payload = try liveAssembler.append(data) { onLivePayload?(payload) }
            } catch { fail(error) }
        case .failed(let error): fail(error)
        }
    }

    private func armResponseTimeout(id: UUID) {
        responseTimer?.cancel()
        responseTimer = Task { [weak self, requestTimeout] in
            do { try await Task.sleep(for: requestTimeout) } catch { return }
            guard let self, self.requestID == id else { return }
            self.fail(SessionError.requestTimedOut)
        }
    }

    private func finishResponseIfReady() {
        guard writesFinished, let response = pendingResponse, let waiter = responseContinuation else { return }
        responseTimer?.cancel()
        responseTimer = nil
        pendingResponse = nil
        responseContinuation = nil
        waiter.resume(returning: response)
    }

    private func fail(_ error: Error, notify: Bool = true) {
        let wasActive = connectionID != nil
        connectionID = nil
        isReady = false
        connectionTimer?.cancel()
        responseTimer?.cancel()
        sendTask?.cancel()
        connectionTimer = nil
        responseTimer = nil
        sendTask = nil
        let ready = readyWaiters.values
        readyWaiters.removeAll()
        let response = responseContinuation
        responseContinuation = nil
        let write = writeContinuation
        writeContinuation = nil
        requestID = nil
        pendingResponse = nil
        writesFinished = false
        responseAssembler.reset()
        liveAssembler.reset()
        transport.stop()
        for waiter in ready { waiter.resume(throwing: error) }
        response?.resume(throwing: error)
        write?.resume(throwing: error)
        if notify && wasActive { onDisconnect?(error) }
    }
}
