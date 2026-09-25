import Foundation

enum DeviceConnectionType: String, CaseIterable, Identifiable {
    case wifi = "wifi"
    case ble = "ble"

    var id: Self { self }

    var displayName: String {
        switch self {
        case .wifi:
            return "Wi-Fi"
        case .ble:
            return "Bluetooth"
        }
    }
}

extension Device {
    var connectionTypeValue: DeviceConnectionType {
        get {
            guard let rawValue = connectionType else {
                return bleIdentifierUUID != nil ? .ble : .wifi
            }
            return DeviceConnectionType(rawValue: rawValue) ?? .wifi
        }
        set {
            connectionType = newValue.rawValue
        }
    }

    var bleIdentifierUUID: UUID? {
        guard let bleIdentifier, !bleIdentifier.isEmpty else {
            return nil
        }
        return UUID(uuidString: bleIdentifier)
    }

    var preferredConnectionType: DeviceConnectionType {
        switch connectionTypeValue {
        case .ble where bleIdentifierUUID != nil:
            return .ble
        case .wifi where !wifiAddress.isEmpty:
            return .wifi
        case .ble:
            return !wifiAddress.isEmpty ? .wifi : .ble
        case .wifi:
            return bleIdentifierUUID != nil ? .ble : .wifi
        }
    }

    var supportsNativeBleControl: Bool {
        preferredConnectionType == .ble
    }

    var wifiAddress: String {
        get {
            guard let address, UUID(uuidString: address) == nil else { return "" }
            return address
        }
        set { address = newValue }
    }
}
