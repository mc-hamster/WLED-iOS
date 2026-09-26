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

    var connectionMode: DeviceConnectionMode {
        get { DeviceConnectionMode(rawValue: connectionType ?? "") ?? (bleIdentifierUUID != nil && wifiAddress.isEmpty ? .ble : .wifi) }
        set { connectionType = newValue.rawValue }
    }

    var preferredConnectionType: DeviceConnectionType {
        switch connectionMode {
        case .ble: return .ble
        case .wifi: return .wifi
        case .automatic: return wifiAddress.isEmpty ? .ble : .wifi
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

enum DeviceConnectionMode: String, CaseIterable, Identifiable {
    case automatic, wifi, ble
    var id: Self { self }
    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .wifi: return "Wi-Fi only"
        case .ble: return "Bluetooth only"
        }
    }
}

func normalizedDeviceMAC(_ value: String?) -> String {
    (value ?? "").lowercased().filter { $0.isHexDigit }
}

/// A network endpoint, not a URL path or a change to the device's network settings.
func validatedDeviceAddress(_ input: String) throws -> String {
    let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let text = raw.contains("://") ? raw : "http://" + raw
    guard let url = URLComponents(string: text), url.scheme == "http",
          let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
          url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/",
          !host.contains(where: { $0.isWhitespace }),
          url.port == nil || (1...65535).contains(url.port!) else {
        throw DeviceAddressError.invalid
    }
    let formattedHost = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    return formattedHost + (url.port.map { ":\($0)" } ?? "")
}

enum DeviceAddressError: LocalizedError {
    case invalid, differentDevice
    var errorDescription: String? {
        switch self {
        case .invalid: return "Enter a local IP address or hostname, optionally with an HTTP port. Do not include a page path or HTTPS."
        case .differentDevice: return "That address belongs to a different device. The saved connection was not changed."
        }
    }
}
