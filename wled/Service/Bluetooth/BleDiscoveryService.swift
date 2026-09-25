import Foundation
@preconcurrency import CoreBluetooth

@MainActor
final class BleDiscoveryService: NSObject, ObservableObject {
    @Published private(set) var peripherals: [BleDiscoveredPeripheral] = []
    @Published private(set) var isScanning = false
    @Published private(set) var bluetoothState: CBManagerState = .unknown

    private lazy var centralManager = CBCentralManager(delegate: self, queue: nil)
    private var scanRequested = false
    private var peripheralMap: [UUID: BleDiscoveredPeripheral] = [:]

    override init() {
        super.init()
    }

    func startScan() {
        scanRequested = true
        guard centralManager.state == .poweredOn else { return }
        peripheralMap.removeAll()
        peripherals = []
        isScanning = true
        centralManager.scanForPeripherals(
            withServices: [BleBridgeConstants.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func stopScan() {
        scanRequested = false
        if isScanning { centralManager.stopScan() }
        isScanning = false
    }
}

extension BleDiscoveryService: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            self.bluetoothState = central.state
            if central.state == .poweredOn && self.scanRequested {
                self.startScan()
            } else if central.state != .poweredOn {
                self.isScanning = false
                self.peripheralMap.removeAll()
                self.peripherals = []
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        MainActor.assumeIsolated {
            guard self.scanRequested, self.isScanning else { return }
            let discovered = BleDiscoveredPeripheral(
                id: peripheral.identifier,
                name: advertisedName ?? peripheral.name ?? "WLED",
                rssi: RSSI.intValue
            )
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
