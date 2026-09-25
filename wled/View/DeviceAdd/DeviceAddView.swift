import SwiftUI

struct DeviceAddView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) var dismiss

    @StateObject private var viewModel = DeviceAddViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack {
                    switch viewModel.currentStep {
                    case .form(let errorMessage):
                        DeviceAddStep1FormView(
                            viewModel: viewModel,
                            errorMessage: errorMessage
                        )
                    case .adding:
                        DeviceAddStep2LoadingView(
                            connectionType: viewModel.connectionType,
                            address: viewModel.address,
                            bleName: viewModel.selectedBlePeripheral?.name
                        )
                    case .success(let device):
                        DeviceAddStep3Success(device: device)
                    }
                    Spacer()
                }
                .padding()
                .animation(.easeInOut, value: viewModel.currentStep)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(viewModel.currentStep.isSuccess ? "Done" : "Cancel") {
                            viewModel.cancel()
                            dismiss()
                        }
                    }
                    if viewModel.currentStep.isForm {
                        ToolbarItem(placement: .primaryAction) {
                            Button("Add", systemImage: "checkmark") {
                                withAnimation {
                                    viewModel.submitCreateDevice()
                                }
                            }
                            .disabled(!viewModel.canSubmit)
                        }
                    }
                }
            }
            .navigationTitle("New Device")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .onDisappear { viewModel.cancel() }
    }
}

// MARK: - Step 1: Form

struct DeviceAddStep1FormView: View {

    @ObservedObject var viewModel: DeviceAddViewModel
    @FocusState private var focusedField: Field?

    let errorMessage: String
    let state = DeviceAddViewModel.Step.self

    var body: some View {
        VStack(alignment: .leading) {
            Picker("Connection Type", selection: $viewModel.connectionType) {
                ForEach(DeviceConnectionType.allCases) { connectionType in
                    Text(connectionType.displayName)
                        .tag(connectionType)
                }
            }
            .pickerStyle(.segmented)

            if viewModel.connectionType == .wifi {
                Text("IP Address or URL")
                TextField("IP Address or URL", text: $viewModel.address)
                    .keyboardType(.URL)
                    .submitLabel(.done)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .address)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(
                                errorMessage.isEmpty ? Color.clear : Color.red
                            )
                    )
                    .onSubmit {
                        withAnimation {
                            viewModel.submitCreateDevice()
                        }
                    }
            } else {
                DeviceAddBleForm(viewModel: viewModel)
            }

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(Font.caption.bold())
            }
        }
        .onAppear {
            focusedField = .address
        }
    }

    enum Field: Hashable {
        case address
    }
}

struct DeviceAddBleForm: View {
    @ObservedObject var viewModel: DeviceAddViewModel
    @State private var showBlePicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("BLE Device")
            Button(viewModel.selectedBlePeripheral?.name ?? "Select BLE Device") {
                showBlePicker = true
            }
            .buttonStyle(.bordered)

            Label("Pair securely with iOS", systemImage: "lock.shield")
                .font(.subheadline)
            Text("Find your six-digit pairing code in WLED Settings → Usermods → BleApiBridge. Enter it only when iOS asks. Your iPhone remembers this device for next time.")
                .font(.caption)
                .foregroundStyle(.secondary)

        }
        .sheet(isPresented: $showBlePicker) {
            BlePeripheralPickerView(discoveryService: viewModel.bleDiscoveryService) { peripheral in
                viewModel.selectedBlePeripheral = peripheral
            }
        }
    }
}

// MARK: - Step 2: Adding, Loading indicator

struct DeviceAddStep2LoadingView: View {
    let connectionType: DeviceConnectionType
    let address: String
    let bleName: String?

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(ControlSize.large)
                .padding()
            if connectionType == .wifi {
                Text("Adding \(address)")
            } else {
                Text("Connecting to \(bleName ?? "BLE Device")")
                Text("Keep WLED nearby. Accept the iOS pairing prompt and enter the device’s six-digit code if asked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Step 3: Success

struct DeviceAddStep3Success: View {
    let device: Device

    var body: some View {
        Image(systemName: "checkmark.seal")
            .font(.system(size: 50))
            .foregroundStyle(.green)
            .padding()
        Text("\(device.displayName) was added")
    }
}

#Preview {
    DeviceAddView()
}
