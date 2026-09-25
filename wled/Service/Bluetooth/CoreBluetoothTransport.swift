import Foundation
@preconcurrency import CoreBluetooth

@MainActor
enum BleTransportEvent {
    case ready(maximumWriteLength: Int)
    case writeCompleted(Error?)
    case response(Data), live(Data), failed(Error)
}

@MainActor
protocol BleTransport: AnyObject {
    var onEvent: ((BleTransportEvent) -> Void)? { get set }
    func start()
    func stop()
    func write(_ data: Data)
}

/// Keeps Core Bluetooth callbacks on the main queue and ignores callbacks from retired connections.
@MainActor
final class CoreBluetoothTransport: NSObject, BleTransport {
    var onEvent: ((BleTransportEvent) -> Void)?
    private let peripheralID: UUID
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var tx: CBCharacteristic?
    private var live: CBCharacteristic?
    private var didReadPairingProbe = false
    private var didBecomeReady = false

    init(peripheralID: UUID) { self.peripheralID = peripheralID }

    func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func stop() {
        let retiringCentral = central
        central = nil
        retiringCentral?.delegate = nil
        retiringCentral?.stopScan()
        peripheral?.delegate = nil
        if let peripheral { retiringCentral?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        rx = nil
        tx = nil
        live = nil
        didReadPairingProbe = false
        didBecomeReady = false
    }

    func write(_ data: Data) {
        guard let peripheral, let rx, didBecomeReady else {
            onEvent?(.failed(BleBridgeSession.SessionError.disconnected))
            return
        }
        peripheral.writeValue(data, for: rx, type: .withResponse)
    }

    private func connect(_ peripheral: CBPeripheral) {
        guard self.peripheral == nil, let central else { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    private func report(_ error: Error) {
        // Preserve actionable recovery for an iOS bond that the device no longer has.
        let nsError = error as NSError
        if nsError.domain == CBErrorDomain && nsError.code == CBError.peerRemovedPairingInformation.rawValue {
            onEvent?(.failed(BleBridgeSession.SessionError.pairingFailed(
                "WLED’s pairing information changed. In iOS Settings → Bluetooth, forget this WLED device, then add it again."
            )))
        } else if (nsError.domain == CBATTErrorDomain && [CBATTError.insufficientAuthentication.rawValue,
                    CBATTError.insufficientEncryption.rawValue, CBATTError.insufficientEncryptionKeySize.rawValue].contains(nsError.code))
                    || (nsError.domain == CBErrorDomain && nsError.code == CBError.encryptionTimedOut.rawValue) {
            onEvent?(.failed(BleBridgeSession.SessionError.pairingFailed(
                "Pairing was not completed. Tap Reconnect and enter the code from WLED Settings → Usermods → BleApiBridge."
            )))
        } else {
            onEvent?(.failed(error))
        }
    }

    private func finishIfReady() {
        guard !didBecomeReady, didReadPairingProbe, tx?.isNotifying == true,
              live == nil || live?.isNotifying == true, let peripheral else { return }
        didBecomeReady = true
        // withResponse may allow a 512-byte long write; the withoutResponse limit reflects ATT MTU.
        let limit = min(peripheral.maximumWriteValueLength(for: .withResponse),
                        peripheral.maximumWriteValueLength(for: .withoutResponse))
        onEvent?(.ready(maximumWriteLength: limit))
    }
}

extension CoreBluetoothTransport: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            guard central === self.central else { return }
            switch central.state {
            case .poweredOn:
                if let peripheral = central.retrievePeripherals(withIdentifiers: [peripheralID]).first {
                    connect(peripheral)
                } else {
                    central.scanForPeripherals(withServices: [BleBridgeConstants.serviceUUID])
                }
            case .unknown, .resetting:
                if self.peripheral != nil { report(BleBridgeSession.SessionError.bluetoothUnavailable) }
            case .unauthorized: report(BleBridgeSession.SessionError.bluetoothUnauthorized)
            case .unsupported: report(BleBridgeSession.SessionError.bluetoothUnsupported)
            default: report(BleBridgeSession.SessionError.bluetoothUnavailable)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            guard central === self.central, peripheral.identifier == peripheralID else { return }
            connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard central === self.central, peripheral === self.peripheral else { return }
            peripheral.discoverServices([BleBridgeConstants.serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard central === self.central else { return }
            report(error ?? BleBridgeSession.SessionError.deviceNotFound)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard central === self.central, peripheral === self.peripheral else { return }
            report(error ?? BleBridgeSession.SessionError.disconnected)
        }
    }
}

extension CoreBluetoothTransport: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        MainActor.assumeIsolated {
            guard peripheral === self.peripheral else { return }
            report(BleBridgeSession.SessionError.disconnected)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === self.peripheral else { return }
            if let error { report(error); return }
            guard let service = peripheral.services?.first(where: { $0.uuid == BleBridgeConstants.serviceUUID }) else {
                report(BleBridgeSession.SessionError.serviceNotFound); return
            }
            peripheral.discoverCharacteristics([BleBridgeConstants.rxUUID, BleBridgeConstants.txUUID,
                                                BleBridgeConstants.liveUUID], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === self.peripheral else { return }
            if let error { report(error); return }
            rx = service.characteristics?.first { $0.uuid == BleBridgeConstants.rxUUID }
            tx = service.characteristics?.first { $0.uuid == BleBridgeConstants.txUUID }
            live = service.characteristics?.first { $0.uuid == BleBridgeConstants.liveUUID }
            guard rx?.properties.contains(.write) == true else {
                report(BleBridgeSession.SessionError.rxCharacteristicNotFound); return
            }
            guard let tx, tx.properties.contains(.read), tx.properties.contains(.indicate) else {
                report(BleBridgeSession.SessionError.txCharacteristicNotFound); return
            }
            if let live, !live.properties.contains(.indicate) {
                report(BleBridgeSession.SessionError.invalidResponse); return
            }
            // A protected read triggers iOS pairing before starting the shorter request deadline.
            peripheral.readValue(for: tx)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === self.peripheral else { return }
            if let error { report(error); return }
            guard characteristic.isNotifying else { report(BleBridgeSession.SessionError.disconnected); return }
            finishIfReady()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === self.peripheral, characteristic === rx else { return }
            if let error { report(error); return }
            onEvent?(.writeCompleted(nil))
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral === self.peripheral else { return }
            if let error { report(error); return }
            guard let data = characteristic.value else { return }
            if characteristic === tx && !didReadPairingProbe {
                guard data == Data("ready".utf8) else { report(BleBridgeSession.SessionError.invalidResponse); return }
                didReadPairingProbe = true
                peripheral.setNotifyValue(true, for: characteristic)
                if let live { peripheral.setNotifyValue(true, for: live) }
            } else if characteristic === tx {
                onEvent?(.response(data))
            } else if characteristic === live {
                onEvent?(.live(data))
            }
        }
    }
}
