//
//  DeviceAddViewModel.swift
//  WLED
//
//  Created by Christophe Gagnier on 2025-12-21.
//

import Foundation
import CoreData

@MainActor
final class DeviceAddViewModel: ObservableObject {

    @Published var connectionType: DeviceConnectionType = .wifi
    @Published var address: String = ""
    @Published var selectedBlePeripheral: BleDiscoveredPeripheral?
    @Published var currentStep: Step = .form()

    private var addTask: Task<Void, Never>?
    private let firstContactService = DeviceFirstContactService()
    let bleDiscoveryService = BleDiscoveryService()

    var isAddressValid: Bool {
        (try? validatedDeviceAddress(address)) != nil
    }

    var canSubmit: Bool {
        switch connectionType {
        case .wifi:
            return isAddressValid
        case .ble:
            return selectedBlePeripheral != nil
        }
    }

    func submitCreateDevice() {
        guard currentStep.isForm, addTask == nil else { return }
        switch connectionType {
        case .wifi:
            if !isAddressValid {
                currentStep = .form(errorMessage: Error.enterValidAddress)
                return
            }
        case .ble:
            if selectedBlePeripheral == nil {
                currentStep = .form(errorMessage: Error.selectBleDevice)
                return
            }
        }

        currentStep = .adding
        addTask = Task {
            await findDevice()
            addTask = nil
        }
    }

    func cancel() {
        addTask?.cancel()
        addTask = nil
        bleDiscoveryService.stopScan()
    }

    /// Starts searching for the device and adds it, if one is found
    private func findDevice() async {
        do {
            let newDeviceId: NSManagedObjectID
            switch connectionType {
            case .wifi:
                newDeviceId = try await firstContactService.fetchAndUpsertDevice(rawAddress: address)
            case .ble:
                guard let selectedBlePeripheral else {
                    currentStep = .form(errorMessage: Error.selectBleDevice)
                    return
                }
                newDeviceId = try await firstContactService.fetchAndUpsertBleDevice(
                    peripheralID: selectedBlePeripheral.id,
                    bleName: selectedBlePeripheral.name
                )
            }

            try Task.checkCancellation()
            let viewContext = PersistenceController.shared.container.viewContext
            if let newDevice = viewContext.object(with: newDeviceId) as? Device {
                currentStep = .success(device: newDevice)
            }
        } catch is CancellationError {
            return
        } catch {
            currentStep = .form(errorMessage: error.localizedDescription)
        }
    }

    // MARK: - State enum
    enum Step: Equatable {
        case form(errorMessage: String = "")
        case adding
        case success(device: Device)

        var isForm: Bool {
            if case .form = self { return true }
            return false
        }

        var isSuccess: Bool {
            if case .success = self { return true }
            return false
        }
    }

    // MARK: - Struct with magic stuff
    struct Error {
        static let enterValidAddress = String(localized: "Please enter a valid address")
        static let selectBleDevice = String(localized: "Select a BLE device to continue")
        static let cantConnect = String(localized: "Could not connect to the device. Verify the address")
    }
}
