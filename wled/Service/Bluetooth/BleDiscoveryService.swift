import Foundation
@preconcurrency import CoreBluetooth

@MainActor
final class BleDiscoveryService: NSObject, ObservableObject {
    @Published private(set) var peripherals: [BleDiscoveredPeripheral] = []
    @Published private(set) var isScanning = false
    @Published private(set) var bluetoothState: CBManagerState = .unknown

    private lazy var centralManager = CBCentralManager(delegate: self, queue: nil)
    private var peripheralMap: [UUID: BleDiscoveredPeripheral] = [:]

    override init() {
        super.init()
        _ = centralManager
    }

    func startScan() {
        guard bluetoothState == .poweredOn else { return }
        peripheralMap.removeAll()
        peripherals = []
        isScanning = true
        centralManager.scanForPeripherals(
            withServices: [BleBridgeConstants.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func stopScan() {
        centralManager.stopScan()
        isScanning = false
    }
}

extension BleDiscoveryService: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            self.bluetoothState = central.state
            if central.state != .poweredOn {
                self.stopScan()
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            let discovered = BleDiscoveredPeripheral(peripheral: peripheral, rssi: RSSI)
            self.peripheralMap[discovered.id] = discovered
            self.peripherals = self.peripheralMap.values.sorted {
                if $0.name == $1.name {
                    return $0.rssi > $1.rssi
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }
}
