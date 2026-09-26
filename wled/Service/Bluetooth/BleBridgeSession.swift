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
        case liveFrameTimedOut
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
            case .requestTooLarge: return "This request exceeds WLED’s Bluetooth request limit. Use Wi-Fi for larger changes."
            case .invalidResponse: return "WLED sent an incomplete or invalid Bluetooth response. Please reconnect."
            case .requestTimedOut: return "WLED did not respond. Keep the device nearby and try again."
            case .liveFrameTimedOut: return "WLED’s live state update was incomplete. Reconnecting to refresh the device."
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
    private let liveFrameTimeout: Duration
    private var readyWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var responseContinuation: CheckedContinuation<BleBridgeResponse, Error>?
    private var writeContinuation: CheckedContinuation<Void, Error>?
    private var connectionTimer: Task<Void, Never>?
    private var responseTimer: Task<Void, Never>?
    private var liveTimer: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var connectionID: UUID?
    private var requestID: UUID?
    private var liveFragmentID: UUID?
    private var pendingResponse: BleBridgeResponse?
    private var writesFinished = false
    private var writeLength = 20
    private(set) var maximumRequestBytes = 4096
    private var isReady = false
    private var responseAssembler = BleFrameAssembler()
    private var liveAssembler = BleFrameAssembler()

    convenience init(peripheralID: UUID) {
        // iOS owns pairing and bond storage; app fields cannot change peripheral security.
        self.init(transport: CoreBluetoothTransport(peripheralID: peripheralID))
    }

    init(transport: any BleTransport, connectionTimeout: Duration = .seconds(90),
         requestTimeout: Duration = .seconds(30), liveFrameTimeout: Duration = .seconds(10)) {
        self.transport = transport
        self.connectionTimeout = connectionTimeout
        self.requestTimeout = requestTimeout
        self.liveFrameTimeout = liveFrameTimeout
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
        guard payload.count <= maximumRequestBytes else { throw SessionError.requestTooLarge }
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
            let response: BleBridgeResponse = try await withTaskCancellationHandler {
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
            try Task.checkCancellation()
            guard requestID == id, isReady else { throw SessionError.disconnected }
            try updateCapabilities(from: response, method: method, path: path)
            return response
        } catch {
            // Unidentified late packets must never become the next request's response.
            if requestID == id { fail(error, notify: !(error is CancellationError)) }
            throw error
        }
    }

    private func updateCapabilities(from response: BleBridgeResponse, method: String, path: String) throws {
        guard method.uppercased() == "GET", response.status == 200,
              ["/json", "/json/info", "/json/si"].contains(path) else { return }
        struct CapabilityEnvelope: Decodable {
            struct InfoEnvelope: Decodable { var ble: BleCapabilities? }
            var ble: BleCapabilities?
            var info: InfoEnvelope?
        }
        let envelope = try JSONDecoder().decode(CapabilityEnvelope.self, from: response.body)
        guard let capabilities = envelope.ble ?? envelope.info?.ble else { return }
        guard capabilities.protocol == 1, (256...4096).contains(capabilities.maxRequest) else {
            throw SessionError.invalidResponse
        }
        maximumRequestBytes = capabilities.maxRequest
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
            trace("TX bytes=\(data.count) frame=\(responseAssembler.progressDescription) waiter=\(responseContinuation != nil) pending=\(pendingResponse != nil) writesFinished=\(writesFinished)")
            // There are no request IDs on the wire. Unexpected TX bytes must
            // retire the connection, including a second response before the
            // final write acknowledgement releases the first response.
            guard responseContinuation != nil, pendingResponse == nil else {
                fail(SessionError.invalidResponse)
                return
            }
            if let requestID { armResponseTimeout(id: requestID) }
            do {
                if let payload = try responseAssembler.append(data) {
                    let response = try BleBridgeCodec.parseResponse(payload)
                    pendingResponse = response
                    finishResponseIfReady()
                }
            } catch { trace("TX parsing failed: \(error)"); fail(error) }
        case .live(let data):
            trace("LIVE bytes=\(data.count) frame=\(liveAssembler.progressDescription)")
            do {
                if let payload = try liveAssembler.append(data) {
                    cancelLiveTimeout()
                    onLivePayload?(payload)
                } else {
                    armLiveTimeout()
                }
            } catch { trace("LIVE parsing failed: \(error)"); fail(error) }
        case .failed(let error): fail(error)
        }
    }

    private func trace(_ message: @autoclosure () -> String) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["BLE_HIL_TRACE"] == "1" {
            print("BLE TRACE \(Date().timeIntervalSince1970) \(message())")
        }
        #endif
    }

    private func armResponseTimeout(id: UUID) {
        responseTimer?.cancel()
        responseTimer = Task { [weak self, requestTimeout] in
            do { try await Task.sleep(for: requestTimeout) } catch { return }
            guard let self, self.requestID == id else { return }
            self.fail(SessionError.requestTimedOut)
        }
    }

    private func armLiveTimeout() {
        cancelLiveTimeout()
        guard let connectionID else { return }
        let fragmentID = UUID()
        liveFragmentID = fragmentID
        liveTimer = Task { [weak self, liveFrameTimeout] in
            do { try await Task.sleep(for: liveFrameTimeout) } catch { return }
            guard let self, self.connectionID == connectionID,
                  self.liveFragmentID == fragmentID else { return }
            self.fail(SessionError.liveFrameTimedOut)
        }
    }

    private func cancelLiveTimeout() {
        liveTimer?.cancel()
        liveTimer = nil
        liveFragmentID = nil
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
        maximumRequestBytes = 4096
        connectionTimer?.cancel()
        responseTimer?.cancel()
        cancelLiveTimeout()
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
