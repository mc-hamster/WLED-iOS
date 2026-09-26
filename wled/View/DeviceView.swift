import SwiftUI
import Combine

struct DeviceView: View {
    @Environment(\.colorScheme) var colorScheme
    @ObservedObject var device: DeviceWithState
    var devices: AnyPublisher<[DeviceWithState], Never>? = nil
    var onSendState: (WledState) -> Void = { _ in }
    var onReconnect: () -> Void = {}

    @State var showDownloadFinished = false
    @State var shouldWebViewRefresh = false

    @State var showEditDeviceView = false

    var body: some View {
        Group {
            if device.device.preferredConnectionType == .ble {
                BleDeviceDetailView(device: device, onSendState: onSendState, onReconnect: onReconnect)
                    .toolbar { toolbar }
            } else {
                ZStack {
                    WebView(url: getDeviceAddress(), reload: $shouldWebViewRefresh) { _ in
                        withAnimation {
                            showDownloadFinished = true
                        }
                        Task {
                            try await Task.sleep(for: .seconds(3))
                            withAnimation {
                                showDownloadFinished = false
                            }
                        }
                    }
                    if showDownloadFinished {
                        VStack {
                            Spacer()
                            Text("Download Completed")
                                .font(.title3)
                                .padding()
                                .background(.regularMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 15))
                                .padding(.bottom)
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(1)
                    }
                }
                .navigationTitle(device.device.displayName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
            }
        }
    }

    @ToolbarContentBuilder
    var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            DeviceInfoTwoRows(device: device)
        }
        ToolbarItem(placement: .primaryAction) {
            NavigationLink {
                DeviceEditView(device: device, devices: devices)
            } label: {
                Label("Settings", systemImage: "gear")
                    .badge(getToolbarBadgeCount())
            }
        }
        if device.device.preferredConnectionType == .wifi {
            ToolbarItem(placement: .automatic) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    shouldWebViewRefresh = true
                }
            }
        }
    }

    func getDeviceAddress() -> URL? {
        guard let deviceAddress = device.device.address,
              let url = URL(string: "http://\(deviceAddress)") else {
            return nil
        }
        return url
    }

    func getToolbarBadgeCount() -> Int {
        return device.hasUpdateAvailable ? 1 : 0
    }
}

#Preview {
    NavigationStack {
        DeviceView(device: PreviewData.onlineDevice)
    }
}
