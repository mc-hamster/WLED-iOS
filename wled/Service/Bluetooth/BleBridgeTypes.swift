import Foundation
@preconcurrency import CoreBluetooth

@MainActor
enum BleBridgeConstants {
    static let serviceUUID = CBUUID(string: "7C2E0001-5D2B-4FD0-B1C2-0CC8F5470101")
    static let rxUUID = CBUUID(string: "7C2E0002-5D2B-4FD0-B1C2-0CC8F5470101")
    static let txUUID = CBUUID(string: "7C2E0003-5D2B-4FD0-B1C2-0CC8F5470101")
    static let liveUUID = CBUUID(string: "7C2E0004-5D2B-4FD0-B1C2-0CC8F5470101")
    static let defaultChunkSize = 180
    static let requestTimeout: TimeInterval = 10
}

struct BleBridgeResponse {
    let status: Int
    let contentType: String
    let body: Data
}

struct BleDiscoveredPeripheral: Identifiable, Hashable {
    let id: UUID
    let name: String
    let rssi: Int

    init(peripheral: CBPeripheral, rssi: NSNumber) {
        self.id = peripheral.identifier
        self.name = peripheral.name ?? "WLED BLE"
        self.rssi = rssi.intValue
    }

    var subtitle: String {
        "\(name) • RSSI \(rssi)"
    }
}
