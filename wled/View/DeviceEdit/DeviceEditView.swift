import SwiftUI

struct DeviceEditView: View {
    @Environment(\.managedObjectContext) private var viewContext

    @StateObject private var viewModel: DeviceEditViewModel
    @StateObject private var bleDiscoveryService = BleDiscoveryService()
    @ObservedObject private var device: DeviceWithState
    @State private var showBlePicker = false

    init(device: DeviceWithState) {
        let context = device.device.managedObjectContext ?? PersistenceController.shared.container.viewContext
        _viewModel = StateObject(wrappedValue: DeviceEditViewModel(device: device, context: context))

        self.device = device
    }


    // MARK: - body

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Card(style: .device(color: device.currentColor)) {
                    DeviceInfoTwoRows(device: device)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))

                VStack(alignment: .leading) {
                    Text("Custom Name")
                    TextField("Custom Name", text: $viewModel.customName)
                        .submitLabel(.done)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Connection")
                    Picker("Connection", selection: $viewModel.connectionType) {
                        ForEach(DeviceConnectionType.allCases) { connectionType in
                            Text(connectionType.displayName)
                                .tag(connectionType)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text("Wi-Fi Address")
                    TextField("Wi-Fi Address", text: $viewModel.wifiAddress)
                        .keyboardType(.URL)
                        .textFieldStyle(.roundedBorder)

                    Divider()

                    Text("Bluetooth")
                    Button(viewModel.bleName.isEmpty ? "Select BLE Device" : viewModel.bleName) {
                        showBlePicker = true
                    }
                    .buttonStyle(.bordered)

                    if !viewModel.bleIdentifier.isEmpty {
                        Text(viewModel.bleIdentifier)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Picker("BLE Security", selection: $viewModel.bleSecurityMode) {
                        ForEach(BleSecurityMode.allCases) { mode in
                            Text(mode.displayName)
                                .tag(mode)
                        }
                    }
                    .pickerStyle(.menu)

                    if viewModel.bleSecurityMode == .passkey {
                        TextField("BLE Passkey", text: $viewModel.blePasskey)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                        Text("If iOS shows a Bluetooth pairing prompt, enter this passkey in the system dialog.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("Hide this Device", isOn: $viewModel.hideDevice)
                    .padding(.trailing, 2)
                    .padding(.bottom)

                HStack {
                    Text("Update Channel")
                    Spacer()
                    Picker("Update Channel", selection: $viewModel.branch) {
                        ForEach(Branch.allCases.filter { $0 != .unknown }) { branch in
                            Text(LocalizedStringKey(branch.nameKey))
                                .tag(branch)
                                .padding()
                        }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                .padding(.bottom)

                if device.stateInfo != nil && device.device.preferredConnectionType == .wifi {
                    Card {
                        if ((device.availableUpdateVersion ?? "").isEmpty) {
                            DeviceNoUpdateAvailable(
                                device: device,
                                isCheckingForUpdates: viewModel.isCheckingForUpdates
                            ) {
                                await viewModel.checkForUpdate()
                            }
                        } else {
                            DeviceUpdateAvailable(device: device)
                        }
                    }
                    .animation(.default, value: device.availableUpdateVersion)
                    .animation(.default, value: viewModel.isCheckingForUpdates)
                }

                Text("Mac Address: \(device.device.macAddress ?? "Unknown")")
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer()
            }
            .padding()
            .padding(.bottom, 100)
        }
        .navigationTitle("Edit Device")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showBlePicker) {
            BlePeripheralPickerView(discoveryService: bleDiscoveryService) { peripheral in
                viewModel.updateSelectedBlePeripheral(peripheral)
            }
        }
    }
}

// MARK: - Device No Update Available

struct DeviceNoUpdateAvailable: View {

    @ObservedObject var device: DeviceWithState
    let isCheckingForUpdates: Bool
    let onCheckForUpdate: () async -> Void

    var body: some View {
        Text("Your device is up to date")
        Text(
            "Version \(device.stateInfo?.info.version ?? String(localized: "unknown_version"))"
        )
        HStack {
            Button(action: {
                Task {
                    await onCheckForUpdate()
                }
            }) {
                Text(isCheckingForUpdates ? "Checking for Updates" : "Check for Update")
            }
            .buttonStyle(.bordered)
            .padding(.trailing)
            .disabled(isCheckingForUpdates)
            ProgressView()
                .opacity(isCheckingForUpdates ? 1 : 0)
        }
    }
}

// MARK: - Device Update Available

struct DeviceUpdateAvailable: View {

    @ObservedObject var device: DeviceWithState

    private let unknownVersion = String(localized: "unknown_version")

    var body: some View {
        HStack {
            Image(systemName: getUpdateIconName())
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 30.0, height: 30.0)
                .padding(.trailing)
            VStack(alignment: .leading) {
                Text("Update Available")
                Text("From \(device.stateInfo?.info.version ?? unknownVersion) to \(device.availableUpdateVersion ?? unknownVersion)")
                NavigationLink {
                    DeviceUpdateDetails(device: device)
                } label: {
                    Text("See Update")
                }
            }
        }
        .buttonStyle(.borderedProminent)
    }

    private func getUpdateIconName() -> String {
        if #available(iOS 17.0, *) {
            return "arrow.down.circle.dotted"
        } else {
            return "arrow.down.circle"
        }
    }
}

#Preview {
    NavigationStack {
        DeviceEditView(device: PreviewData.onlineDevice)
    }
}
