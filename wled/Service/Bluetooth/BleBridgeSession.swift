import Foundation
@preconcurrency import CoreBluetooth

@MainActor
final class BleBridgeSession: NSObject {
    enum SessionError: LocalizedError {
        case bluetoothUnavailable
        case bluetoothUnauthorized
        case bluetoothUnsupported
        case deviceNotFound
        case serviceNotFound
        case rxCharacteristicNotFound
        case txCharacteristicNotFound
        case requestAlreadyInFlight
        case invalidResponse
        case requestFailed(String)
        case requestTimedOut

        var errorDescription: String? {
            switch self {
            case .bluetoothUnavailable:
                return "Bluetooth is unavailable."
            case .bluetoothUnauthorized:
                return "Bluetooth access is not authorized."
            case .bluetoothUnsupported:
                return "Bluetooth LE is not supported on this device."
            case .deviceNotFound:
                return "The BLE device could not be found."
            case .serviceNotFound:
                return "The WLED BLE service was not found."
            case .rxCharacteristicNotFound:
                return "The BLE RX characteristic was not found."
            case .txCharacteristicNotFound:
                return "The BLE TX characteristic was not found."
            case .requestAlreadyInFlight:
                return "A BLE request is already in flight."
            case .invalidResponse:
                return "The BLE device returned an invalid response."
            case .requestFailed(let message):
                return message
            case .requestTimedOut:
                return "The BLE request timed out."
            }
        }
    }

    let peripheralID: UUID
    let expectedName: String?
    let securityMode: BleSecurityMode
    let passkey: String?

    var onLivePayload: ((Data) -> Void)?
    var onPairingPromptSuggested: ((String) -> Void)?

    private lazy var centralManager = CBCentralManager(delegate: self, queue: nil)

    private var peripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private var txCharacteristic: CBCharacteristic?
    private var liveCharacteristic: CBCharacteristic?

    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var writeContinuation: CheckedContinuation<Void, Error>?
    private var responseContinuation: CheckedContinuation<BleBridgeResponse, Error>?

    private var scanTimeoutTask: Task<Void, Never>?
    private var responseTimeoutTask: Task<Void, Never>?

    private var isReady = false
    private var isManualDisconnect = false
    private var txSubscribed = false
    private var liveSubscribed = false

    private var responseExpectedLength: Int?
    private var responseBuffer = Data()
    private var liveExpectedLength: Int?
    private var liveBuffer = Data()

    init(
        peripheralID: UUID,
        expectedName: String? = nil,
        securityMode: BleSecurityMode,
        passkey: String?
    ) {
        self.peripheralID = peripheralID
        self.expectedName = expectedName
        self.securityMode = securityMode
        self.passkey = passkey
        super.init()
        _ = centralManager
    }

    func connect() async throws {
        if isReady {
            return
        }

        if securityMode == .passkey, let passkey, !passkey.isEmpty {
            onPairingPromptSuggested?("If iOS shows a Bluetooth pairing prompt, enter passkey \(passkey).")
        }

        try await withCheckedThrowingContinuation { continuation in
            readyContinuation = continuation
            isManualDisconnect = false

            switch centralManager.state {
            case .poweredOn:
                startConnectionFlow()
            case .unknown, .resetting:
                break
            case .unauthorized:
                failReady(with: SessionError.bluetoothUnauthorized)
            case .unsupported:
                failReady(with: SessionError.bluetoothUnsupported)
            default:
                failReady(with: SessionError.bluetoothUnavailable)
            }
        }
    }

    func disconnect() {
        isManualDisconnect = true
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        responseContinuation = nil
        writeContinuation = nil
        readyContinuation = nil

        if let peripheral {
            if peripheral.state != .disconnected {
                centralManager.cancelPeripheralConnection(peripheral)
            }
        }

        resetConnectionState()
    }

    func request(method: String, path: String, body: String = "") async throws -> BleBridgeResponse {
        guard responseContinuation == nil else {
            throw SessionError.requestAlreadyInFlight
        }

        try await connect()

        guard let rxCharacteristic else {
            throw SessionError.rxCharacteristicNotFound
        }

        let payload = "\(method.uppercased()) \(path)\n\n\(body)"
        guard let payloadData = payload.data(using: .utf8), payloadData.count <= UInt16.max else {
            throw SessionError.requestFailed("BLE request is too large.")
        }

        resetResponseBuffer()

        return try await withCheckedThrowingContinuation { continuation in
            responseContinuation = continuation
            responseTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(BleBridgeConstants.requestTimeout))
                self?.failResponse(with: SessionError.requestTimedOut)
            }

            Task { @MainActor in
                do {
                    try await self.sendChunks(payloadData, to: rxCharacteristic)
                } catch {
                    self.failResponse(with: error)
                }
            }
        }
    }

    private func startConnectionFlow() {
        if let peripheral {
            connectPeripheral(peripheral)
            return
        }

        if let retrieved = centralManager.retrievePeripherals(withIdentifiers: [peripheralID]).first {
            connectPeripheral(retrieved)
            return
        }

        centralManager.scanForPeripherals(withServices: [BleBridgeConstants.serviceUUID])
        scanTimeoutTask?.cancel()
        scanTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            self?.handleScanTimeout()
        }
    }

    private func handleScanTimeout() {
        centralManager.stopScan()
        failReady(with: SessionError.deviceNotFound)
    }

    private func connectPeripheral(_ peripheral: CBPeripheral) {
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        centralManager.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        centralManager.connect(peripheral)
    }

    private func resetConnectionState() {
        isReady = false
        txSubscribed = false
        liveSubscribed = false
        rxCharacteristic = nil
        txCharacteristic = nil
        liveCharacteristic = nil
        resetResponseBuffer()
        resetLiveBuffer()
    }

    private func resetResponseBuffer() {
        responseExpectedLength = nil
        responseBuffer = Data()
    }

    private func resetLiveBuffer() {
        liveExpectedLength = nil
        liveBuffer = Data()
    }

    private func maybeFinishReady() {
        guard !isReady else { return }
        guard rxCharacteristic != nil else { return }
        guard txCharacteristic != nil else { return }
        guard txSubscribed else { return }

        if liveCharacteristic != nil && !liveSubscribed {
            return
        }

        isReady = true
        readyContinuation?.resume()
        readyContinuation = nil
    }

    private func failReady(with error: Error) {
        readyContinuation?.resume(throwing: error)
        readyContinuation = nil
    }

    private func failWrite(with error: Error) {
        writeContinuation?.resume(throwing: error)
        writeContinuation = nil
    }

    private func failResponse(with error: Error) {
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        responseContinuation?.resume(throwing: error)
        responseContinuation = nil
        resetResponseBuffer()
    }

    private func completeResponse(_ response: BleBridgeResponse) {
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        responseContinuation?.resume(returning: response)
        responseContinuation = nil
        resetResponseBuffer()
    }

    private func sendChunks(_ payload: Data, to characteristic: CBCharacteristic) async throws {
        let firstChunkBudget = max(BleBridgeConstants.defaultChunkSize - 2, 1)
        let totalLength = UInt16(payload.count)
        var firstChunk = Data()
        firstChunk.append(UInt8(totalLength & 0xFF))
        firstChunk.append(UInt8((totalLength >> 8) & 0xFF))
        firstChunk.append(payload.prefix(firstChunkBudget))
        try await writeChunk(firstChunk, to: characteristic)

        var offset = firstChunkBudget
        while offset < payload.count {
            let end = min(offset + BleBridgeConstants.defaultChunkSize, payload.count)
            try await writeChunk(payload.subdata(in: offset..<end), to: characteristic)
            offset = end
        }
    }

    private func writeChunk(_ chunk: Data, to characteristic: CBCharacteristic) async throws {
        guard let peripheral else {
            throw SessionError.bluetoothUnavailable
        }

        try await withCheckedThrowingContinuation { continuation in
            writeContinuation = continuation
            peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
        }
    }

    private func handleResponseChunk(_ data: Data) {
        if responseExpectedLength == nil {
            guard data.count >= 2 else { return }
            responseExpectedLength = Int(data[0]) | (Int(data[1]) << 8)
            responseBuffer.append(data.dropFirst(2))
        } else {
            responseBuffer.append(data)
        }

        guard let responseExpectedLength, responseBuffer.count >= responseExpectedLength else {
            return
        }

        let completeData = responseBuffer.prefix(responseExpectedLength)
        do {
            completeResponse(try parseResponse(Data(completeData)))
        } catch {
            failResponse(with: error)
        }
    }

    private func handleLiveChunk(_ data: Data) {
        if liveExpectedLength == nil {
            guard data.count >= 2 else { return }
            liveExpectedLength = Int(data[0]) | (Int(data[1]) << 8)
            liveBuffer.append(data.dropFirst(2))
        } else {
            liveBuffer.append(data)
        }

        guard let liveExpectedLength, liveBuffer.count >= liveExpectedLength else {
            return
        }

        let completeData = Data(liveBuffer.prefix(liveExpectedLength))
        onLivePayload?(completeData)
        resetLiveBuffer()
    }

    private func parseResponse(_ data: Data) throws -> BleBridgeResponse {
        guard let text = String(data: data, encoding: .utf8) else {
            throw SessionError.invalidResponse
        }

        let headerParts = text.components(separatedBy: "\n\n")
        guard headerParts.count >= 2 else {
            throw SessionError.invalidResponse
        }

        let header = headerParts[0]
        let bodyText = headerParts.dropFirst().joined(separator: "\n\n")
        let statusParts = header.split(separator: " ", maxSplits: 1)
        guard statusParts.count == 2, let status = Int(statusParts[0]) else {
            throw SessionError.invalidResponse
        }

        guard let body = bodyText.data(using: .utf8) else {
            throw SessionError.invalidResponse
        }

        return BleBridgeResponse(status: status, contentType: String(statusParts[1]), body: body)
    }
}

extension BleBridgeSession: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                if self.readyContinuation != nil && !self.isReady {
                    self.startConnectionFlow()
                }
            case .unauthorized:
                self.failReady(with: SessionError.bluetoothUnauthorized)
            case .unsupported:
                self.failReady(with: SessionError.bluetoothUnsupported)
            case .poweredOff, .resetting:
                self.resetConnectionState()
            default:
                self.failReady(with: SessionError.bluetoothUnavailable)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            guard peripheral.identifier == self.peripheralID else { return }
            self.connectPeripheral(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            peripheral.delegate = self
            peripheral.discoverServices([BleBridgeConstants.serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            self.failReady(with: error ?? SessionError.deviceNotFound)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            self.resetConnectionState()
            if let error {
                self.failReady(with: error)
                self.failResponse(with: error)
                self.failWrite(with: error)
            } else if !self.isManualDisconnect {
                let disconnectError = SessionError.requestFailed("The BLE device disconnected.")
                self.failReady(with: disconnectError)
                self.failResponse(with: disconnectError)
                self.failWrite(with: disconnectError)
            }
        }
    }
}

extension BleBridgeSession: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                self.failReady(with: error)
                return
            }

            guard let service = peripheral.services?.first(where: { $0.uuid == BleBridgeConstants.serviceUUID }) else {
                self.failReady(with: SessionError.serviceNotFound)
                return
            }

            peripheral.discoverCharacteristics(
                [BleBridgeConstants.rxUUID, BleBridgeConstants.txUUID, BleBridgeConstants.liveUUID],
                for: service
            )
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                self.failReady(with: error)
                return
            }

            self.rxCharacteristic = service.characteristics?.first(where: { $0.uuid == BleBridgeConstants.rxUUID })
            self.txCharacteristic = service.characteristics?.first(where: { $0.uuid == BleBridgeConstants.txUUID })
            self.liveCharacteristic = service.characteristics?.first(where: { $0.uuid == BleBridgeConstants.liveUUID })

            guard self.rxCharacteristic != nil else {
                self.failReady(with: SessionError.rxCharacteristicNotFound)
                return
            }
            guard let txCharacteristic = self.txCharacteristic else {
                self.failReady(with: SessionError.txCharacteristicNotFound)
                return
            }

            peripheral.setNotifyValue(true, for: txCharacteristic)
            if let liveCharacteristic = self.liveCharacteristic {
                peripheral.setNotifyValue(true, for: liveCharacteristic)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                self.failReady(with: error)
                return
            }

            if characteristic.uuid == BleBridgeConstants.txUUID {
                self.txSubscribed = characteristic.isNotifying
            } else if characteristic.uuid == BleBridgeConstants.liveUUID {
                self.liveSubscribed = characteristic.isNotifying
            }

            self.maybeFinishReady()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                self.failWrite(with: error)
                return
            }

            self.writeContinuation?.resume()
            self.writeContinuation = nil
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                self.failResponse(with: error)
                return
            }

            guard let data = characteristic.value, !data.isEmpty else {
                return
            }

            if characteristic.uuid == BleBridgeConstants.txUUID {
                self.handleResponseChunk(data)
            } else if characteristic.uuid == BleBridgeConstants.liveUUID {
                self.handleLiveChunk(data)
            }
        }
    }
}
