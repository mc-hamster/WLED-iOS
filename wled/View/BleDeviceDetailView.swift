import SwiftUI

struct BleDeviceDetailView: View {
    @ObservedObject var device: DeviceWithState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card(style: .device(color: device.currentColor)) {
                    DeviceInfoTwoRows(device: device)
                }

                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Bluetooth Control")
                            .font(.headline)
                        Text("This device is connected through the BLE bridge. Live state updates and JSON state changes are available in the native app.")
                            .foregroundStyle(.secondary)
                        if let version = device.stateInfo?.info.version {
                            Text("Version \(version)")
                        }
                        Text("Power: \(device.stateInfo?.state.isOn == true ? "On" : "Off")")
                        if let brightness = device.stateInfo?.state.brightness {
                            Text("Brightness: \(brightness)")
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Connection")
                            .font(.headline)
                        Text("Peripheral: \(device.device.bleName ?? "Unknown")")
                        Text(device.device.bleIdentifier ?? "No peripheral selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(device.device.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}
