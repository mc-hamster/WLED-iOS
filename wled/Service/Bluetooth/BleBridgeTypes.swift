import Foundation
@preconcurrency import CoreBluetooth

@MainActor
enum BleBridgeConstants {
    static let serviceUUID = CBUUID(string: "7C2E0001-5D2B-4FD0-B1C2-0CC8F5470101")
    static let rxUUID = CBUUID(string: "7C2E0002-5D2B-4FD0-B1C2-0CC8F5470101")
    static let txUUID = CBUUID(string: "7C2E0003-5D2B-4FD0-B1C2-0CC8F5470101")
    static let liveUUID = CBUUID(string: "7C2E0004-5D2B-4FD0-B1C2-0CC8F5470101")
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

    init(id: UUID, name: String, rssi: Int) {
        self.id = id
        self.name = name
        self.rssi = rssi
    }

    var signalDescription: String {
        if rssi == 127 { return "Signal unavailable" }
        if rssi >= -60 { return "Strong signal" }
        if rssi >= -80 { return "Good signal" }
        return "Weak signal · move closer"
    }
}
