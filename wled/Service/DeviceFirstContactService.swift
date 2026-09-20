//
//  DeviceFirstContactService.swift
//  WLED
//
//  Created by Christophe Gagnier on 2025-12-16.
//

import Foundation
import CoreData
import OSLog

/// Service responsible for handling the first contact with a device.
/// It fetches device info and handles the creation or update of the Device entity in Core Data.
actor DeviceFirstContactService {

    private let persistenceController: PersistenceController
    private let urlSession: URLSession
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ca.cgagnier.wled-native", category: "DeviceFirstContactService")

    enum ServiceError: LocalizedError {
        case invalidURL
        case missingMacAddress
        case networkError(Error)
        case invalidBleResponse

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return String(localized:"The device address is invalid.", comment: "Invalid URL error")
            case .missingMacAddress:
                return String(localized:"The device did not report a valid MAC address.", comment: "Missing MAC error")
            case .networkError(let error):
                return String(localized: "Network error: \(error.localizedDescription)")
            case .invalidBleResponse:
                return String(localized: "The BLE device returned an invalid response.")
            }
        }
    }

    /// - Parameters:
    ///   - persistenceController: The Core Data controller.
    ///   - urlSession: Injected session for testability (defaults to .shared).
    init(persistenceController: PersistenceController = .shared, urlSession: URLSession = .shared) {
        self.persistenceController = persistenceController
        self.urlSession = urlSession
    }

    // MARK: - Public API

    /// Fetches device information using its address, then ensures a corresponding
    /// device record exists in the database (creating or updating its address
    /// as necessary).
    ///
    /// - Parameter rawAddress: The network address input (e.g., "http://192.168.1.1/" or "wled.local").
    /// - Returns: The NSManagedObjectID of the device (to be retrieved safely on the main thread).
    func fetchAndUpsertDevice(rawAddress: String) async throws -> NSManagedObjectID {
        let cleanAddress = sanitize(address: rawAddress)

        logger.debug("Initiating contact with: \(cleanAddress)")
        let info = try await fetchDeviceInfo(address: cleanAddress)

        guard let macAddress = info.mac, !macAddress.isEmpty else {
            logger.error("Could not retrieve MAC address for device at \(cleanAddress)")
            throw ServiceError.missingMacAddress
        }

        return try await upsertWifiDevice(macAddress: macAddress, hostname: cleanAddress, name: info.name)
    }

    func fetchAndUpsertBleDevice(
        peripheralID: UUID,
        bleName: String?,
        securityMode: BleSecurityMode,
        passkey: String?
    ) async throws -> NSManagedObjectID {
        let info = try await fetchBleDeviceInfo(
            peripheralID: peripheralID,
            bleName: bleName,
            securityMode: securityMode,
            passkey: passkey
        )

        guard let macAddress = info.mac, !macAddress.isEmpty else {
            throw ServiceError.missingMacAddress
        }

        return try await upsertBleDevice(
            macAddress: macAddress,
            peripheralID: peripheralID,
            bleName: bleName ?? info.name,
            name: info.name,
            securityMode: securityMode,
            passkey: passkey
        )
    }

    /// Attempts to identify and update a device using only the MAC address from mDNS/Discovery.
    /// This avoids a network call to the device if we already know who it is.
    ///
    /// - Parameters:
    ///   - macAddress: The MAC address found via mDNS (can be null/empty).
    ///   - address: The new IP address.
    /// - Returns: true if the device was found and processed (updated or skipped), false otherwise.
    func tryUpdateAddress(macAddress: String?, address: String) async -> Bool {
        guard let macAddress, !macAddress.isEmpty else { return false }

        // Ensure the address provided by mDNS is clean before saving
        let cleanAddress = sanitize(address: address)
        let logger = self.logger

        return await persistenceController.container.performBackgroundTask { context in
            let request: NSFetchRequest<Device> = Device.fetchRequest()
            request.predicate = NSPredicate(format: "macAddress == %@", macAddress)
            request.fetchLimit = 1

            guard let existingDevice = try? context.fetch(request).first else {
                return false
            }

            if existingDevice.address != address {
                logger.info("Fast update: IP changed for \(existingDevice.originalName ?? "Unknown") (\(macAddress))")
                existingDevice.address = cleanAddress

                do {
                    try context.save()
                } catch {
                    logger.error("Failed to save fast update: \(error.localizedDescription)")
                }
            }
            return true
        }
    }

    // MARK: - Private Helpers

    /// Removes schemes (http/https) and trailing slashes to ensure we store a clean hostname/IP.
    private func sanitize(address: String) -> String {
        var result = address

        // Remove scheme if present
        if let range = result.range(of: "://") {
            result = String(result[range.upperBound...])
        }

        // Remove trailing slashes
        while result.hasSuffix("/") {
            result.removeLast()
        }

        return result
    }

    /// Fetches device information from the specified address.
    private func fetchDeviceInfo(address: String) async throws -> Info {
        // Construct URL, ensuring http scheme and json/info path
        let urlString = "http://\(address)/json/info"

        guard let url = URL(string: urlString) else {
            throw ServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        do {
            let (data, _) = try await urlSession.data(for: request)
            return try JSONDecoder().decode(Info.self, from: data)
        } catch {
            throw ServiceError.networkError(error)
        }
    }

    /// Handles the Core Data logic to find, update, or create the device.
    @MainActor
    private func fetchBleDeviceInfo(
        peripheralID: UUID,
        bleName: String?,
        securityMode: BleSecurityMode,
        passkey: String?
    ) async throws -> Info {
        let session = BleBridgeSession(
            peripheralID: peripheralID,
            expectedName: bleName,
            securityMode: securityMode,
            passkey: passkey
        )

        defer {
            session.disconnect()
        }

        let response = try await session.request(method: "GET", path: "/json/info")
        guard response.status == 200 else {
            throw ServiceError.invalidBleResponse
        }

        do {
            return try JSONDecoder().decode(Info.self, from: response.body)
        } catch {
            throw ServiceError.networkError(error)
        }
    }

    private func upsertWifiDevice(macAddress: String, hostname: String, name: String?) async throws -> NSManagedObjectID {
        let logger = self.logger
        return try await persistenceController.container.performBackgroundTask { context in
            context.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump

            let request: NSFetchRequest<Device> = Device.fetchRequest()
            request.predicate = NSPredicate(format: "macAddress == %@", macAddress)
            request.fetchLimit = 1

            let device: Device

            if let existingDevice = try? context.fetch(request).first {
                // Check if updates are actually needed to minimize Core Data thrashing
                if existingDevice.address == hostname && existingDevice.originalName == name {
                    logger.debug("Device exists and is up to date: \(macAddress)")
                    device = existingDevice
                } else {
                    logger.debug("Updating existing device: \(macAddress)")
                    existingDevice.address = hostname
                    existingDevice.originalName = name
                    if existingDevice.connectionType == nil || existingDevice.connectionType?.isEmpty == true {
                        existingDevice.connectionType = DeviceConnectionType.wifi.rawValue
                    }
                    device = existingDevice
                }
            } else {
                logger.info("Creating new device: \(macAddress)")
                device = Device(context: context)
                device.macAddress = macAddress
                device.address = hostname
                device.originalName = name
                device.isHidden = false
                device.connectionType = DeviceConnectionType.wifi.rawValue
            }

            if context.hasChanges {
                try context.save()
            }

            return device.objectID
        }
    }

    private func upsertBleDevice(
        macAddress: String,
        peripheralID: UUID,
        bleName: String?,
        name: String?,
        securityMode: BleSecurityMode,
        passkey: String?
    ) async throws -> NSManagedObjectID {
        let logger = self.logger
        return try await persistenceController.container.performBackgroundTask { context in
            context.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump

            let request: NSFetchRequest<Device> = Device.fetchRequest()
            request.predicate = NSPredicate(format: "macAddress == %@", macAddress)
            request.fetchLimit = 1

            let identifierString = peripheralID.uuidString
            let device: Device

            if let existingDevice = try? context.fetch(request).first {
                logger.debug("Updating BLE settings for existing device: \(macAddress)")
                if existingDevice.address == nil || existingDevice.address?.isEmpty == true {
                    existingDevice.address = identifierString
                }
                existingDevice.originalName = name
                existingDevice.connectionType = DeviceConnectionType.ble.rawValue
                existingDevice.bleIdentifier = identifierString
                existingDevice.bleName = bleName
                existingDevice.bleSecurityMode = securityMode.rawValue
                existingDevice.blePasskey = passkey
                device = existingDevice
            } else {
                logger.info("Creating new BLE device: \(macAddress)")
                device = Device(context: context)
                device.macAddress = macAddress
                device.address = identifierString
                device.originalName = name
                device.isHidden = false
                device.connectionType = DeviceConnectionType.ble.rawValue
                device.bleIdentifier = identifierString
                device.bleName = bleName
                device.bleSecurityMode = securityMode.rawValue
                device.blePasskey = passkey
            }

            if context.hasChanges {
                try context.save()
            }

            return device.objectID
        }
    }
}
