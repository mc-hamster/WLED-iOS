import SwiftUI
import Combine

struct DeviceView: View {
    @ObservedObject var device: DeviceWithState
    var devices: AnyPublisher<[DeviceWithState], Never>? = nil
    var onSendState: (WledState) -> Void = { _ in }
    var onReconnect: () -> Void = {}
    @State private var showConnection = false

    var body: some View {
        BleDeviceDetailView(device: device, onSendState: onSendState, onReconnect: onReconnect)
            .onAppear { device.openAction() }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Button { showConnection = true } label: { DeviceInfoTwoRows(device: device) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Connection: \(device.connectionSummary)")
                }
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        DeviceEditView(device: device, devices: devices)
                    } label: { Label("Settings", systemImage: "gear").badge(device.hasUpdateAvailable ? 1 : 0) }
                }
            }
            .sheet(isPresented: $showConnection) { ConnectionView(device: device, devices: devices) }
    }
}

struct DeviceWebInterfaceView: View {
    @ObservedObject var device: DeviceWithState
    @State private var refresh = false
    @State private var downloadFinished = false
    var body: some View {
        Group {
            if device.isOnline && device.activeTransport == .wifi {
                WebView(url: URL(string: "http://\(device.device.wifiAddress)"), reload: $refresh) { _ in downloadFinished = true }
            } else {
                VStack(spacing: 16) {
                    Text("The full web interface needs Wi-Fi").font(.headline)
                    Text("Your basic controls remain available over Bluetooth. Close this page and choose Wi-Fi in Connection to open the full interface.")
                }.padding()
            }
        }
        .navigationTitle("Web interface · Wi-Fi")
        .toolbar { Button("Refresh") { refresh = true } }
        .alert("Download completed", isPresented: $downloadFinished) { Button("OK", role: .cancel) {} }
    }
}

#Preview { NavigationStack { DeviceView(device: PreviewData.onlineDevice) } }
