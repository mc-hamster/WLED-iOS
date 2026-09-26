import Testing
import Foundation
import CoreData
@testable import WLED
@MainActor
struct DeviceUpdateServiceTests {

    /// Parse real JSON capability bits, including firmware predating the opt field.
    @Test(arguments: ["0", "76", "77", "null"])
    func updateAvailabilityRespectsFirmwareCapabilities(option: String) throws {
        let persistence = PersistenceController(inMemory: true)
        let device = Device(context: persistence.container.viewContext)
        device.connectionType = "wifi"
        let model = DeviceWithState(initialDevice: device)
        model.availableUpdateVersion = "v99.0.0"
        #expect(!model.hasUpdateAvailable)
        let json = "{\"state\":{},\"info\":{\"leds\":{},\"wifi\":{},\"name\":\"WLED\",\"opt\":\(option)}}"
        model.stateInfo = try JSONDecoder().decode(DeviceStateInfo.self, from: Data(json.utf8))
        #expect(model.canInstallStockFirmware == (option == "77" || option == "null"))
        #expect(model.hasUpdateAvailable == model.canInstallStockFirmware)

        device.connectionType = "ble"
        #expect(!model.canInstallStockFirmware)
        #expect(!model.hasUpdateAvailable)
    }

    @Test func bluetoothFirmwareIsProtectedEvenWhenUsingWiFi() throws {
        let persistence = PersistenceController(inMemory: true)
        let device = Device(context: persistence.container.viewContext)
        device.connectionType = "wifi"
        let model = DeviceWithState(initialDevice: device)
        let json = #"{"state":{},"info":{"leds":{},"wifi":{},"name":"WLED","opt":77,"ble":{"protocol":1,"maxRequest":4096,"security":"passkey"}}}"#
        model.stateInfo = try JSONDecoder().decode(DeviceStateInfo.self, from: Data(json.utf8))
        model.availableUpdateVersion = "v99.0.0"
        #expect(!model.canInstallStockFirmware)
        #expect(!model.hasUpdateAvailable)
    }

    @Test func staleUpdateScreenCannotDownloadOrUploadUSBOnlyFirmware() async throws {
        let persistence = PersistenceController(inMemory: true)
        let device = Device(context: persistence.container.viewContext)
        device.connectionType = "wifi"
        device.address = "192.0.2.1"
        let model = DeviceWithState(initialDevice: device)
        let json = #"{"state":{},"info":{"leds":{},"wifi":{},"name":"WLED","opt":77}}"#
        model.stateInfo = try JSONDecoder().decode(DeviceStateInfo.self, from: Data(json.utf8))
        let version = Version(context: persistence.container.viewContext)
        let service = DeviceUpdateService(device: model, version: version)

        model.stateInfo?.info.opt = 76
        #expect(await service.downloadBinary() == false)
        do {
            try await service.installUpdate()
            Issue.record("USB-only firmware must reject installation before file or network access")
        } catch UpdateError.unsupportedFirmware {
            // Expected even with no cached binary: capability validation runs first.
        }
    }

    @Test func determineAsset_OlderVersion_NoOverride() {
        // Version older than 0.16.0, should keep raw release
        let targetVersion = "0.15.0"
        
        #expect(DeviceUpdateService.determineAsset(byRelease: "ESP32_V4", targetVersion: targetVersion) == "ESP32_V4")
        #expect(DeviceUpdateService.determineAsset(byRelease: "ESP32", targetVersion: targetVersion) == "ESP32")
        #expect(DeviceUpdateService.determineAsset(byRelease: "ESP8266", targetVersion: targetVersion) == "ESP8266")
    }

    @Test func determineAsset_NewVersion_WithOverride() {
        // Version 0.16.0+ where dictionary mapping applies
        let targetVersion = "0.16.0"
        
        #expect(DeviceUpdateService.determineAsset(byRelease: "ESP32_V4", targetVersion: targetVersion) == "ESP32")
        #expect(DeviceUpdateService.determineAsset(byRelease: "esp32_v4", targetVersion: targetVersion) == "ESP32")
    }
    
    @Test func determineAsset_NewVersion_NoOverride() {
        // Version 0.16.0+ but no dictionary mapping applies
        let targetVersion = "0.16.0"
        
        #expect(DeviceUpdateService.determineAsset(byRelease: "ESP32_S2", targetVersion: targetVersion) == "ESP32_S2")
        #expect(DeviceUpdateService.determineAsset(byRelease: "ESP8266", targetVersion: targetVersion) == "ESP8266")
    }

    @Test func determineAsset_PreRelease_Threshold() {
        // Pre-release testing around the 0.16.0 boundary
        let targetVersionBeta = "0.16.0-b2"
        let targetVersionOlderBeta = "0.15.0-b5"
        
        #expect(DeviceUpdateService.determineAsset(byRelease: "ESP32_V4", targetVersion: targetVersionOlderBeta) == "ESP32_V4")
        #expect(DeviceUpdateService.determineAsset(byRelease: "ESP32_V4", targetVersion: targetVersionBeta) == "ESP32")
    }
    
    @Test func determineAsset_InvalidVersion() {
        // Invalid semantic version structure, should throw warning log and fallback to raw release
        let invalidVersion = "invalid_version_string"
        
        #expect(DeviceUpdateService.determineAsset(byRelease: "ESP32_V4", targetVersion: invalidVersion) == "ESP32_V4")
    }
}
