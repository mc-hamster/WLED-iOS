import SwiftUI
import Combine

struct ConnectionView: View {
    @ObservedObject var device: DeviceWithState
    var devices: AnyPublisher<[DeviceWithState], Never>? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                ConnectionSections(device: device)
                Section {
                    NavigationLink("Set up connection methods") {
                        DeviceEditView(device: device, devices: devices)
                    }
                }
            }
            .navigationTitle("Connection")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct ConnectionSections: View {
    @ObservedObject var device: DeviceWithState
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section("Using now") {
            Label(device.connectionSummary, systemImage: device.isOnline ? "checkmark.circle" : "antenna.radiowaves.left.and.right")
                .accessibilityIdentifier("connection-summary")
            if let error = device.connectionError { Text(error).foregroundStyle(.secondary) }
            if let recovery = device.recoveryMessage { Text(recovery).font(.callout).foregroundStyle(.secondary) }
            if device.isOnline || device.websocketStatus == .connecting || (!device.manuallyDisconnected && device.recoveryMessage != nil) {
                Button("Disconnect") { device.disconnectAction() }
                    .accessibilityIdentifier("disconnect-device")
            }
            if !device.isOnline && device.websocketStatus != .connecting {
                Button("Connect") { device.connectAction() }
                    .accessibilityIdentifier("connect-device")
            }
            if device.isOnline, device.device.connectionMode == .automatic, device.activeTransport == .ble, !device.device.wifiAddress.isEmpty {
                Button("Try Wi-Fi again") { device.connectAction() }
            }
            Text("Disconnect releases this app's connection. It keeps your saved device and leaves the lights unchanged.").font(.caption)
        }
        Section("Connection mode") {
            Picker("Connection", selection: Binding(get: { device.device.connectionMode }, set: { device.modeAction($0) })) {
                Text("Automatic").tag(DeviceConnectionMode.automatic)
                Text("Wi-Fi").tag(DeviceConnectionMode.wifi)
                Text("Bluetooth").tag(DeviceConnectionMode.ble)
            }.pickerStyle(.segmented)
            Text(device.device.connectionMode == .automatic
                 ? "Prefers Wi-Fi, then tries saved Bluetooth if Wi-Fi fails. A working fallback stays in use until you reconnect. iOS may ask to pair again if pairing information changed."
                 : "Uses only this method. A failed connection will not silently switch methods.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Connect automatically when app opens", isOn: Binding(get: { device.autoConnect }, set: { device.autoConnectAction($0) }))
            Text("Otherwise, opening this device connects it. A manual Disconnect always stays disconnected until you tap Connect. Hidden devices do not connect automatically.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Saved methods") {
            method(.wifi, detail: device.device.wifiAddress.isEmpty ? "Not configured — set an address in Edit Device" : device.device.wifiAddress)
            method(.ble, detail: device.device.bleIdentifierUUID == nil ? "Not configured — select a device in Edit Device" : device.device.bleName ?? "Saved Bluetooth device")
            Text("Saved does not mean reachable. The unused method is not connected or continuously checked.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Troubleshooting") {
            Text("Wi-Fi needs a route to WLED on your local network and Local Network permission, but does not need internet access. Bluetooth needs permission, power and a nearby device with bridge firmware. If it cannot be found, another phone may be using it.")
            Text("iOS manages Bluetooth pairing. This app cannot delete an iOS bond. If pairing was reset, follow the iOS prompt or check the device's pairing instructions.")
            if let settings = URL(string: UIApplication.openSettingsURLString) {
                Button("Open iOS Settings") { openURL(settings) }
            }
        }.font(.callout)
    }

    private func method(_ route: DeviceConnectionType, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(route.displayName).font(.headline)
            Text(detail).font(.subheadline)
            if let message = device.routeMessages[route] {
                Text(message).font(.caption).foregroundStyle(.secondary)
            } else if route == .wifi ? !device.device.wifiAddress.isEmpty : device.device.bleIdentifierUUID != nil {
                Text("Saved · Not checked").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
