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
    @Published var bleSecurityMode: BleSecurityMode = .passkey
    @Published var blePasskey: String = "123456"
    @Published var selectedBlePeripheral: BleDiscoveredPeripheral?
    @Published var currentStep: Step = .form()

    private let firstContactService = DeviceFirstContactService()
    let bleDiscoveryService = BleDiscoveryService()

    var isAddressValid: Bool {
        let cleanedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedAddress.isEmpty else { return false }

        let addressWithScheme: String
        if cleanedAddress.lowercased().hasPrefix("http://") || cleanedAddress.lowercased().hasPrefix("https://") {
            addressWithScheme = cleanedAddress
        } else {
            addressWithScheme = "http://\(cleanedAddress)"
        }

        guard let components = URLComponents(string: addressWithScheme) else {
            return false
        }

        // This prevents valid URLs that are empty or just schemes (like "http://")
        guard let host = components.host, !host.isEmpty else {
            return false
        }

        return true
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

        Task {
            await findDevice()
        }
    }

    /// Starts searching for the device and adds it, if one is found
    private func findDevice() async {
        currentStep = .adding
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
                    bleName: selectedBlePeripheral.name,
                    securityMode: bleSecurityMode,
                    passkey: bleSecurityMode == .passkey ? blePasskey.trimmingCharacters(in: .whitespacesAndNewlines) : nil
                )
            }

            let viewContext = PersistenceController.shared.container.viewContext
            if let newDevice = viewContext.object(with: newDeviceId) as? Device {
                currentStep = .success(device: newDevice)
            }
        } catch (let error) {
            print("Error: \(error)")
            currentStep = .form(errorMessage: Error.cantConnect)
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
    }

    // MARK: - Struct with magic stuff
    struct Error {
        static let enterValidAddress = String(localized: "Please enter a valid address")
        static let selectBleDevice = String(localized: "Select a BLE device to continue")
        static let cantConnect = String(localized: "Could not connect to the device. Verify the address")
    }
}
