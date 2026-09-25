import SwiftUI
import CoreBluetooth

struct BlePeripheralPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ObservedObject var discoveryService: BleDiscoveryService
    let onSelect: (BleDiscoveredPeripheral) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(statusMessage, systemImage: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.secondary)
                    if discoveryService.bluetoothState == .unauthorized,
                       let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                        Button("Open Settings") { openURL(settingsURL) }
                    }
                }
                Section("Nearby WLED Devices") {
                    ForEach(discoveryService.peripherals) { peripheral in
                        Button {
                            onSelect(peripheral)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(peripheral.name).font(.headline)
                                    Text(peripheral.signalDescription).font(.caption).foregroundStyle(.secondary)
                                    if discoveryService.peripherals.filter({ $0.name == peripheral.name }).count > 1 {
                                        Text("Device ending in \(String(peripheral.id.uuidString.suffix(4)))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }
                        }
                        .disabled(discoveryService.bluetoothState != .poweredOn)
                    }
                }
                Section {
                    Text("Keep WLED powered on and nearby. Bluetooth bridge firmware must be installed. A device connected to another phone may not appear until that phone disconnects.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Nearby WLED")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button(discoveryService.isScanning ? "Stop" : "Scan") {
                        if discoveryService.isScanning { discoveryService.stopScan() } else { discoveryService.startScan() }
                    }
                    .disabled(discoveryService.bluetoothState != .poweredOn)
                }
            }
            .onAppear { discoveryService.startScan() }
            .onDisappear { discoveryService.stopScan() }
        }
    }

    private var statusMessage: String {
        switch discoveryService.bluetoothState {
        case .poweredOn: return discoveryService.isScanning ? "Looking for nearby WLED devices…" : "Scan paused"
        case .unauthorized: return "Allow Bluetooth access for WLED in Settings."
        case .unsupported: return "Bluetooth LE is not available on this device."
        case .poweredOff: return "Turn on Bluetooth to find WLED devices."
        default: return "Starting Bluetooth…"
        }
    }
}
