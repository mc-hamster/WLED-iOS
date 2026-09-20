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

enum BleSecurityMode: String, CaseIterable, Identifiable {
    case systemDefault = "systemDefault"
    case passkey = "passkey"
    case none = "none"

    var id: Self { self }

    var displayName: String {
        switch self {
        case .systemDefault:
            return "System Default"
        case .passkey:
            return "Passkey"
        case .none:
            return "No Passkey"
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

    var bleSecurityModeValue: BleSecurityMode {
        get {
            guard let rawValue = bleSecurityMode else {
                return .systemDefault
            }
            return BleSecurityMode(rawValue: rawValue) ?? .systemDefault
        }
        set {
            bleSecurityMode = newValue.rawValue
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
        case .wifi where !(address ?? "").isEmpty:
            return .wifi
        case .ble:
            return !(address ?? "").isEmpty ? .wifi : .ble
        case .wifi:
            return bleIdentifierUUID != nil ? .ble : .wifi
        }
    }

    var supportsNativeBleControl: Bool {
        preferredConnectionType == .ble
    }

    var wifiAddress: String {
        get { address ?? "" }
        set { address = newValue }
    }
}
