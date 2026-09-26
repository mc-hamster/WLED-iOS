//
//  DeviceEditViewModel.swift
//  WLED
//
//  Created by Christophe Gagnier on 2025-12-23.
//

import Foundation
import CoreData
import Combine

@MainActor
class DeviceEditViewModel: ObservableObject {
    private let context: NSManagedObjectContext

    private var cancellables = Set<AnyCancellable>()
    private var deviceObservation: AnyCancellable?
    private var verificationTask: Task<Void, Never>?

    @Published var device: DeviceWithState

    @Published var isVerifyingAddress = false
    @Published var addressMessage: String?
    private var addressTask: Task<Void, Never>?

    @Published var wifiAddress: String = ""
    @Published var bleName: String = ""
    @Published var bleIdentifier: String = ""
    @Published var bleConnectionError: String?
    @Published var isVerifyingBluetooth = false
    @Published var customName: String = ""
    @Published var hideDevice: Bool = false
    @Published var branch: Branch = .unknown

    @Published var isCheckingForUpdates: Bool = false

    init(device: DeviceWithState, context: NSManagedObjectContext) {
        self.context = context
        self.device = device
        wifiAddress = device.device.wifiAddress
        bleName = device.device.bleName ?? ""
        bleIdentifier = device.device.bleIdentifier ?? ""
        customName = device.device.customName ?? ""
        hideDevice = device.device.isHidden
        branch = device.device.branchValue

        setupCustomNameDebouncedListener()
        setupHideDeviceListener()
        setupBranchListener()
        observeDevice()
    }

    // MARK: - Form change listeners

    /// Saves the custom name every seconds when there are changes to the value
    private func setupCustomNameDebouncedListener() {
        $customName
            .debounce(for: .seconds(0.5), scheduler: RunLoop.main)
            .sink { [weak self] newCustomName in
                guard let self = self else { return }

                // Check if the value actually changed from the saved value
                // to prevent saving when the view first loads
                if self.device.device.customName != newCustomName {
                    self.device.device.customName = newCustomName
                    self.saveDevice()
                }
            }
            .store(in: &cancellables)
    }

    private func setupHideDeviceListener() {
        $hideDevice
            .removeDuplicates() // Only fire if the bool actually flips
            .sink { [weak self] isHidden in
                guard let self = self else { return }

                // Check against the source of truth to prevent loops
                if self.device.device.isHidden != isHidden {
                    self.device.device.isHidden = isHidden
                    self.saveDevice()
                }
            }
            .store(in: &cancellables)
    }

    private func setupBranchListener() {
        $branch
            .removeDuplicates()
            .sink { [weak self] newBranch in
                guard let self = self else { return }

                if self.device.device.branchValue != newBranch {
                    self.device.device.branchValue = newBranch
                    self.device.device.skipUpdateTag = ""
                    self.saveDevice()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    /// Navigation can outlive a transport client. Keep form edits while following its replacement.
    func updateCurrentDevice(from devices: [DeviceWithState]) {
        guard let current = devices.first(where: { $0.id == device.id }), current !== device else { return }
        device = current
        observeDevice()
    }

    private func observeDevice() {
        deviceObservation = device.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func applyWifiAddress() {
        guard !isVerifyingAddress else { return }
        isVerifyingAddress = true
        addressMessage = nil
        let draft = wifiAddress
        let expectedMAC = device.device.macAddress
        addressTask = Task {
            defer { isVerifyingAddress = false; addressTask = nil }
            do {
                let address = try validatedDeviceAddress(draft)
                let info = try await DeviceFirstContactService().fetchDeviceInfo(address: address)
                try Task.checkCancellation()
                guard normalizedDeviceMAC(info.mac) == normalizedDeviceMAC(expectedMAC), !normalizedDeviceMAC(info.mac).isEmpty else {
                    throw DeviceAddressError.differentDevice
                }
                device.device.address = address
                try context.save()
                wifiAddress = address
                addressMessage = "Address verified and saved."
            } catch is CancellationError { addressMessage = "Address check canceled. Saved address unchanged." }
            catch { addressMessage = error.localizedDescription }
        }
    }

    func cancelAddressVerification() { addressTask?.cancel() }

    func checkForUpdate() async {
        isCheckingForUpdates = true
        print("Refreshing available Releases")
        await ReleaseService(context: context).refreshVersions()
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: WLEDNativeApp.dateLastUpdateKey)

        device.device.skipUpdateTag = ""
        isCheckingForUpdates = false
        saveDevice()
    }

    func updateSelectedBlePeripheral(_ peripheral: BleDiscoveredPeripheral) {
        guard !isVerifyingBluetooth else { return }
        if peripheral.id == device.device.bleIdentifierUUID {
            bleName = peripheral.name
            device.device.bleName = peripheral.name
            bleConnectionError = nil
            saveDevice()
            return
        }
        isVerifyingBluetooth = true
        bleConnectionError = nil
        verificationTask = Task {
            defer { isVerifyingBluetooth = false; verificationTask = nil }
            do {
                let info = try await DeviceFirstContactService().fetchBleDeviceInfo(
                    peripheralID: peripheral.id
                )
                try Task.checkCancellation()
                guard let selectedMac = info.mac, let savedMac = device.device.macAddress, !savedMac.isEmpty,
                      selectedMac.caseInsensitiveCompare(savedMac) == .orderedSame else {
                    bleConnectionError = "That is a different WLED device. Add it from the device list instead."
                    return
                }
                bleName = peripheral.name
                bleIdentifier = peripheral.id.uuidString
                device.device.bleName = peripheral.name
                device.device.bleIdentifier = peripheral.id.uuidString
                device.device.blePasskey = nil
                saveDevice()
            } catch is CancellationError { } catch { bleConnectionError = error.localizedDescription }
        }
    }

    func cancelBluetoothVerification() { verificationTask?.cancel() }

    private func saveDevice() {
        do {
            try context.save()
        } catch {
            let nsError = error as NSError
            print("Unresolved error saving device: \(nsError), \(nsError.userInfo)")
        }
    }
}
