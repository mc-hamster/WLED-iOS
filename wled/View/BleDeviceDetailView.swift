import SwiftUI

struct BleDeviceDetailView: View {
    @ObservedObject var device: DeviceWithState
    let onSendState: (WledState) -> Void
    let onReconnect: () -> Void
    @State private var showConnection = false
    @State private var brightness: Double = 128
    @State private var editingBrightness = false

    private var mainSegment: Segment? {
        device.stateInfo?.state.segment?.first { $0.id == device.stateInfo?.state.mainSegment }
            ?? device.stateInfo?.state.segment?.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card {
                    HStack {
                        Label(device.connectionSummary, systemImage: device.isOnline ? "checkmark.circle" : "antenna.radiowaves.left.and.right")
                        Spacer()
                        if device.websocketStatus == .connecting { ProgressView() }
                    }
                    if let error = device.connectionError {
                        Text(error).font(.callout).foregroundStyle(.secondary)
                    }
                    Button("Connection") { showConnection = true }.buttonStyle(.bordered)
                    if let recovery = device.recoveryMessage { Text(recovery).font(.callout).foregroundStyle(.secondary) }
                    if let command = device.commandMessage { Text(command).font(.caption).foregroundStyle(.secondary) }
                    if !device.isOnline, let date = device.lastConfirmedAt {
                        Text("Last confirmed \(date.formatted(date: .omitted, time: .shortened)) — values may have changed.").font(.caption)
                    }
                }
                Card {
                    Toggle("Power", isOn: Binding(
                        get: { device.stateInfo?.state.isOn ?? false },
                        set: { onSendState(WledState(isOn: $0)) }
                    ))
                    HStack {
                        Text("Brightness")
                        Spacer()
                        Text("\(Int(brightness / 255 * 100))%")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $brightness, in: 1...255, step: 1) { editing in
                        editingBrightness = editing
                        if !editing { onSendState(WledState(brightness: Int64(brightness))) }
                    }
                    .accessibilityLabel("Brightness")
                    ColorPicker("Color", selection: Binding(
                        get: { device.currentColor },
                        set: { color in
                            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                            guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
                            let white = mainSegment?.colors?.first?.dropFirst(3).first ?? 0
                            let colors: [[Int64]] = [[Int64((red * 255).rounded()), Int64((green * 255).rounded()),
                                                      Int64((blue * 255).rounded()), white]]
                            onSendState(WledState(segment: [Segment(id: mainSegment?.id ?? 0, colors: colors)]))
                        }
                    ), supportsOpacity: false)
                }
                .disabled(!device.isOnline)
                Card {
                    NavigationLink("Full web interface") { DeviceWebInterfaceView(device: device) }
                        .disabled(device.activeTransport != .wifi || !device.isOnline)
                    if device.activeTransport != .wifi {
                        Text("Effects, presets and advanced settings in the full web interface require Wi-Fi. Choose Wi-Fi in Connection.").font(.callout).foregroundStyle(.secondary)
                    }
                    Text("Power changes the lights, not the connection. iOS manages Bluetooth pairing.").font(.caption).foregroundStyle(.secondary)
                    if let version = device.stateInfo?.info.version { Text("Firmware \(version)").font(.caption) }
                }
            }
            .padding()
        }
        .sheet(isPresented: $showConnection) { ConnectionView(device: device) }
        .navigationTitle(device.device.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: device.websocketStatus) { _ in
            // A lost response may leave the authoritative value unchanged.
            // Reset the local slider even when that value won't trigger onChange.
            editingBrightness = false
            brightness = Double(device.stateInfo?.state.brightness ?? 128)
        }
        .onAppear { brightness = Double(device.stateInfo?.state.brightness ?? 128) }
        .onChange(of: device.stateInfo?.state.brightness) { value in
            if !editingBrightness, let value { brightness = Double(max(1, value)) }
        }
    }
}
