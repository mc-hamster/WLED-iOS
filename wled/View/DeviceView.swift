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
    @State private var refreshID = UUID()
    @State private var path = ""
    @State private var notice: String?
    @State private var unlock = false
    @State private var pin = ""
    @State private var unlocking = false
    @State private var unlockError: String?
    @State private var download: WorkspaceDownload?
    @State private var capabilityError: String?
    @State private var capabilitiesReady = false

    var body: some View {
        Group {
            if !device.isOnline {
                VStack(spacing: 18) {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash").font(.system(size: 38)).foregroundStyle(.secondary)
                    Text(device.manuallyDisconnected ? "Bluetooth is disconnected" : "Reconnect to your light").font(.title2.bold())
                    Text(device.recoveryMessage ?? "Your workspace will be ready when the connection returns.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Connect") { device.connectAction() }.buttonStyle(.borderedProminent)
                }.padding(30)
            } else if path.isEmpty {
                WorkspaceHomeView(navigate: navigate)
            } else if device.activeTransport == .wifi {
                WebView(url: URL(string: "http://\(device.device.wifiAddress)\(path)"), reload: $refresh) { download = WorkspaceDownload(url: $0) }
            } else if let capabilityError {
                VStack(spacing: 18) {
                    Image(systemName: "cable.connector").font(.system(size: 38)).foregroundStyle(.secondary)
                    Text("Workspace firmware needed").font(.title2.bold())
                    Text(capabilityError).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Check again") { Task { await checkCapabilities() } }.buttonStyle(.bordered)
                }.padding(30)
            } else if capabilitiesReady {
                DeviceWorkspaceWebView(device: device, path: path, refreshID: refreshID,
                    onUnlock: { unlock = true }, onNotice: { notice = $0 }, onDownload: { download = WorkspaceDownload(url: $0) })
            } else { ProgressView("Opening your workspace…") }
        }
        .navigationTitle("Device workspace")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Workspace home", systemImage: "square.grid.2x2") { navigate("") }
                    Button("All controls", systemImage: "slider.horizontal.3") { navigate("/") }
                    Button("Device settings", systemImage: "gearshape") { navigate("/settings") }
                    Button("Files & backups", systemImage: "folder") { navigate("/edit") }
                    Button("Custom palettes", systemImage: "paintpalette") { navigate("/cpal.htm") }
                    Button("Pixel art", systemImage: "square.grid.3x3") { navigate("/pixart.htm") }
                    Button("Pixel studio", systemImage: "wand.and.stars") { navigate("/pixelforge.htm") }
                    Button("Live preview", systemImage: "eye") { navigate("/liveview") }
                    Divider()
                    Button("Refresh", systemImage: "arrow.clockwise") { refresh = true; refreshID = UUID() }
                    if device.activeTransport == .ble {
                        Button("Unlock settings", systemImage: "lock.open") { unlock = true }
                        Button("Lock settings", systemImage: "lock") {
                            Task {
                                do { _ = try await device.workspaceJSON("/ble/auth", ["lock": true]); notice = "Device settings locked."; refreshID = UUID() }
                                catch { notice = error.localizedDescription }
                            }
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Workspace destinations")
            }
        }
        .task(id: "\(device.connectionEpoch)-\(device.isOnline)") { await checkCapabilities() }
        .alert("WLED", isPresented: Binding(get: { notice != nil && !unlock }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) { notice = nil }
        } message: { Text(notice ?? "") }
        .sheet(item: $download) { WorkspaceShareSheet(url: $0.url) }
        .sheet(isPresented: $unlock, onDismiss: { pin = ""; unlockError = nil }) {
            NavigationStack {
                Form {
                    Section {
                        SecureField("Settings PIN", text: $pin).keyboardType(.numberPad).textContentType(.oneTimeCode)
                        if let unlockError { Text(unlockError).foregroundStyle(.red) }
                    } header: { Text("Protected device settings") }
                      footer: { Text("Enter the settings PIN configured on WLED. This is separate from your Bluetooth pairing code.") }
                    Button {
                        Task {
                            unlocking = true
                            defer { unlocking = false }
                            do {
                                _ = try await device.workspaceJSON("/ble/auth", ["pin": pin])
                                pin = ""; notice = nil; unlock = false; refreshID = UUID()
                            } catch { unlockError = error.localizedDescription }
                        }
                    } label: {
                        HStack { Text("Unlock settings"); Spacer(); if unlocking { ProgressView() } }
                    }.disabled(unlocking || pin.isEmpty)
                }
                .navigationTitle("Unlock WLED")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { unlock = false } } }
            }.presentationDetents([.medium])
        }
    }

    private func navigate(_ destination: String) { path = destination; refreshID = UUID() }

    private func checkCapabilities() async {
        guard device.activeTransport == .ble, device.isOnline else { return }
        capabilitiesReady = false; capabilityError = nil
        let epoch = device.connectionEpoch
        do {
            let response = try await device.request(method: "GET", path: "/ble/capabilities")
            guard !Task.isCancelled, device.connectionEpoch == epoch, device.isOnline else { return }
            guard response.status == 200,
                  let capabilities = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                  (capabilities["version"] as? Int ?? 0) >= 2 else {
                capabilityError = "Install the Bluetooth workspace firmware over USB to use settings, files, and tools without Wi-Fi. Lighting controls remain available."
                return
            }
            capabilitiesReady = true
        } catch {
            guard !Task.isCancelled, device.connectionEpoch == epoch else { return }
            capabilityError = error.localizedDescription
        }
    }
}

#Preview { NavigationStack { DeviceView(device: PreviewData.onlineDevice) } }
