import Foundation
import Combine

/// Owns one command route and stable UI state for a saved device.
@MainActor
final class DeviceConnectionController: DeviceConnectionClient {
    let deviceState: DeviceWithState
    var onDeviceStateUpdated: ((DeviceStateInfo) -> Void)?
    private let defaults: UserDefaults
    private let factory: (Device, DeviceConnectionType) -> any DeviceConnectionClient
    private var client: (any DeviceConnectionClient)?
    private var observation: AnyCancellable?
    private var retry: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var generation = 0
    private var demanded = false
    private var paused = false
    private var retries = 0
    private var tried = Set<DeviceConnectionType>()
    private var signature = ""
    private var key: String { "connection.\(deviceState.id)" }
    var attemptTimeout: Duration = .seconds(20)
    var retryDelay: Duration = .seconds(3)

    init(device: Device, defaults: UserDefaults = .standard,
         factory: @escaping (Device, DeviceConnectionType) -> any DeviceConnectionClient = { device, route in
             switch route {
             case .wifi: return WebsocketClient(device: device, automaticallyRetries: false)
             case .ble: return BleClient(device: device, automaticallyRetries: false)
             }
         }) {
        self.deviceState = DeviceWithState(initialDevice: device)
        self.defaults = defaults
        self.factory = factory
        deviceState.manuallyDisconnected = defaults.bool(forKey: key + ".disconnected")
        deviceState.autoConnect = defaults.object(forKey: key + ".auto") as? Bool ?? (device.connectionMode == .wifi)
        deviceState.connectAction = { [weak self] in self?.connectByUser() }
        deviceState.disconnectAction = { [weak self] in self?.disconnectByUser() }
        deviceState.openAction = { [weak self] in
            guard let self, !self.deviceState.manuallyDisconnected else { return }
            self.demanded = true
            self.connect()
        }
        deviceState.modeAction = { [weak self] mode in self?.setMode(mode) }
        deviceState.autoConnectAction = { [weak self] enabled in
            guard let self else { return }
            self.defaults.set(enabled, forKey: self.key + ".auto")
            self.deviceState.autoConnect = enabled
        }
        signature = configuration
    }

    private var configuration: String {
        let device = deviceState.device
        return "\(device.connectionMode.rawValue)|\(device.wifiAddress)|\(device.bleIdentifier ?? "")"
    }

    func reconfigure() {
        guard signature != configuration else { return }
        signature = configuration
        retire()
        tried.removeAll()
        retries = 0
        deviceState.routeMessages = [:]
        // Editing a method never undoes an explicit Disconnect.
        connect()
    }

    private func setMode(_ mode: DeviceConnectionMode) {
        deviceState.device.connectionMode = mode
        do { try deviceState.device.managedObjectContext?.save() }
        catch { deviceState.connectionError = "Could not save the connection choice: \(error.localizedDescription)"; return }
        demanded = true
        reconfigure()
    }

    func connectByUser() {
        defaults.set(false, forKey: key + ".disconnected")
        deviceState.manuallyDisconnected = false
        demanded = true
        paused = false
        retries = 0
        tried.removeAll()
        retire()
        connect()
    }

    func disconnectByUser() {
        defaults.set(true, forKey: key + ".disconnected")
        deviceState.manuallyDisconnected = true
        demanded = false
        disconnect()
        deviceState.recoveryMessage = "Disconnected. Lights keep their current state. Tap Connect to resume."
    }

    func connect() {
        paused = false
        guard !deviceState.manuallyDisconnected, client == nil, retry == nil,
              demanded || (deviceState.autoConnect && !deviceState.device.isHidden) else { return }
        retries = 0
        tried.removeAll()
        start(deviceState.device.preferredConnectionType)
    }

    func disconnect() {
        paused = true
        retire()
        deviceState.recoveryMessage = nil
    }

    func destroy() { disconnect() }

    private func retire() {
        generation += 1
        retry?.cancel(); retry = nil
        deadline?.cancel(); deadline = nil
        observation?.cancel(); observation = nil
        let old = client
        client = nil
        old?.onDeviceStateUpdated = nil
        old?.destroy()
        if deviceState.isSending {
            deviceState.commandMessage = "Connection changed before confirmation. Check the current state; the change may have reached WLED."
        }
        deviceState.isSending = false
        if let route = deviceState.activeTransport ?? deviceState.attemptedTransport,
           ["In use", "Connecting…"].contains(deviceState.routeMessages[route] ?? "") {
            deviceState.routeMessages[route] = "Not connected"
        }
        deviceState.activeTransport = nil
        deviceState.websocketStatus = .disconnected
    }

    private func configured(_ route: DeviceConnectionType) -> Bool {
        route == .wifi ? !deviceState.device.wifiAddress.isEmpty : deviceState.device.bleIdentifierUUID != nil
    }

    private func start(_ route: DeviceConnectionType) {
        guard !paused, !deviceState.manuallyDisconnected else { return }
        guard configured(route) else {
            deviceState.connectionError = "Set up \(route.displayName) in Edit Device before connecting."
            return
        }
        tried.insert(route)
        let current = generation
        let transport = factory(deviceState.device, route)
        client = transport
        deviceState.attemptedTransport = route
        deviceState.connectionError = nil
        deviceState.requiresUserAction = false
        deviceState.websocketStatus = .connecting
        deviceState.routeMessages[route] = "Connecting…"
        transport.onDeviceStateUpdated = { [weak self] info in
            guard let self, self.generation == current else { return }
            self.deviceState.stateInfo = info
            self.deviceState.lastConfirmedAt = Date()
            self.onDeviceStateUpdated?(info)
        }
        // objectWillChange fires before values change. Read on the next main-actor turn.
        observation = transport.deviceState.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == current else { return }
                self.synchronize(route: route)
            }
        }
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: route == .ble ? .seconds(90) : self?.attemptTimeout ?? .seconds(20)) }
            catch { return }
            guard let self, self.generation == current, !self.deviceState.isOnline else { return }
            self.failed(route: route, message: "\(route.displayName) did not respond.", requiresAction: false)
        }
        transport.connect()
    }

    private func synchronize(route: DeviceConnectionType) {
        guard let client else { return }
        let state = client.deviceState
        deviceState.commandMessage = state.commandMessage ?? deviceState.commandMessage
        deviceState.isSending = state.isSending
        if state.websocketStatus == .connected {
            deadline?.cancel(); deadline = nil
            deviceState.websocketStatus = .connected
            deviceState.activeTransport = route
            deviceState.connectionError = nil
            deviceState.routeMessages[route] = "In use"
            if deviceState.device.connectionMode == .automatic && route != deviceState.device.preferredConnectionType {
                deviceState.recoveryMessage = "Using \(route.displayName) because the preferred connection was unavailable. This route stays in use until you reconnect."
            } else { deviceState.recoveryMessage = nil }
        } else if state.websocketStatus == .disconnected, let error = state.connectionError {
            failed(route: route, message: error, requiresAction: state.requiresUserAction)
        }
    }

    private func failed(route: DeviceConnectionType, message: String, requiresAction: Bool) {
        retire()
        deviceState.routeMessages[route] = message
        deviceState.connectionError = message
        deviceState.requiresUserAction = requiresAction
        let alternate: DeviceConnectionType = route == .wifi ? .ble : .wifi
        if deviceState.device.connectionMode == .automatic, configured(alternate), !tried.contains(alternate) {
            deviceState.recoveryMessage = "Trying \(alternate.displayName)…"
            start(alternate)
            return
        }
        guard !requiresAction, retries < 2 else {
            deviceState.recoveryMessage = "Automatic retries stopped. Check the connection methods, then tap Connect to retry."
            return
        }
        retries += 1
        deviceState.recoveryMessage = "Retrying in a few seconds (\(retries) of 2). You can Disconnect to stop."
        let current = generation
        retry = Task { [weak self, retryDelay] in
            do { try await Task.sleep(for: retryDelay) } catch { return }
            guard let self, self.generation == current, !self.paused, !self.deviceState.manuallyDisconnected else { return }
            self.tried.removeAll()
            self.start(self.deviceState.device.preferredConnectionType)
        }
    }

    func sendState(_ state: WledState) {
        guard deviceState.isOnline, !deviceState.manuallyDisconnected else {
            deviceState.commandMessage = "Not sent. Connect before changing the lights."
            return
        }
        deviceState.isSending = true
        deviceState.commandMessage = "Sending…"
        client?.sendState(state)
    }
}
