import SwiftUI
import CoreBluetooth

struct BlePeripheralPickerView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var discoveryService: BleDiscoveryService
    let onSelect: (BleDiscoveredPeripheral) -> Void

    var body: some View {
        NavigationStack {
            List {
                if bluetoothUnavailableMessage != nil {
                    Section {
                        Text(bluetoothUnavailableMessage ?? "")
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(discoveryService.peripherals) { peripheral in
                    Button {
                        onSelect(peripheral)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(peripheral.name)
                            Text(peripheral.id.uuidString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("RSSI \(peripheral.rssi)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Select BLE Device")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(discoveryService.isScanning ? "Stop" : "Scan") {
                        if discoveryService.isScanning {
                            discoveryService.stopScan()
                        } else {
                            discoveryService.startScan()
                        }
                    }
                }
            }
            .onAppear {
                discoveryService.startScan()
            }
            .onDisappear {
                discoveryService.stopScan()
            }
        }
    }

    private var bluetoothUnavailableMessage: String? {
        switch discoveryService.bluetoothState {
        case .poweredOn:
            return discoveryService.peripherals.isEmpty ? "Scanning for WLED BLE devices..." : nil
        case .unauthorized:
            return "Bluetooth permission is required to discover BLE devices."
        case .unsupported:
            return "Bluetooth LE is not supported on this device."
        case .poweredOff:
            return "Turn Bluetooth on to discover BLE devices."
        default:
            return "Bluetooth is starting up."
        }
    }
}
