import SwiftUI

struct BleDeviceDetailView: View {
    @ObservedObject var device: DeviceWithState
    let onSendState: (WledState) -> Void
    let onReconnect: () -> Void
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
                        Label(device.websocketStatus.toString(), systemImage: device.isOnline ? "checkmark.circle" : "antenna.radiowaves.left.and.right")
                        Spacer()
                        if device.websocketStatus == .connecting { ProgressView() }
                    }
                    if let error = device.connectionError {
                        Text(error).font(.callout).foregroundStyle(.secondary)
                    }
                    if !device.isOnline { Button("Reconnect", action: onReconnect).buttonStyle(.bordered) }
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
                    Text("Paired with iOS").font(.headline)
                    Text("WLED reconnects automatically when this app is active and the device is nearby.")
                        .foregroundStyle(.secondary)
                    if let version = device.stateInfo?.info.version { Text("Firmware \(version)").font(.caption) }
                }
            }
            .padding()
        }
        .navigationTitle(device.device.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { brightness = Double(device.stateInfo?.state.brightness ?? 128) }
        .onChange(of: device.stateInfo?.state.brightness) { value in
            if !editingBrightness, let value { brightness = Double(max(1, value)) }
        }
    }
}
