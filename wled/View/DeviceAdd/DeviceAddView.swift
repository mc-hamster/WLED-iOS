
import SwiftUI

struct DeviceAddView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) var dismiss

    @ObservedObject private var viewModel = DeviceAddViewModel()

    var body: some View {
        NavigationView {
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
                        bleName: viewModel.selectedBlePeripheral?.name,
                        bleSecurityMode: viewModel.bleSecurityMode,
                        blePasskey: viewModel.blePasskey
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
                    Button("Cancel", systemImage: "xmark") {
                        dismiss()
                    }
                }
                if (viewModel.currentStep.isForm) {
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
            .navigationTitle("New Device")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
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

            if let selectedBlePeripheral = viewModel.selectedBlePeripheral {
                Text(selectedBlePeripheral.id.uuidString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Security", selection: $viewModel.bleSecurityMode) {
                ForEach(BleSecurityMode.allCases) { mode in
                    Text(mode.displayName)
                        .tag(mode)
                }
            }
            .pickerStyle(.menu)

            if viewModel.bleSecurityMode == .passkey {
                TextField("Passkey", text: $viewModel.blePasskey)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                Text("If iOS asks to pair, enter this passkey in the system prompt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if viewModel.bleSecurityMode == .none {
                Text("No passkey will be shown in the app. iOS will still handle any pairing requirements exposed by the peripheral.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
    let bleSecurityMode: BleSecurityMode
    let blePasskey: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(ControlSize.large)
                .padding()
            if connectionType == .wifi {
                Text("Adding \(address)")
            } else {
                Text("Connecting to \(bleName ?? "BLE Device")")
                if bleSecurityMode == .passkey {
                    Text("If iOS shows a pairing prompt, enter passkey \(blePasskey).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
