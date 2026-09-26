import Foundation
import CoreData

@MainActor
class WebsocketClient: NSObject, ObservableObject, URLSessionWebSocketDelegate, DeviceConnectionClient {
    @Published var deviceState: DeviceWithState
    var onDeviceStateUpdated: ((DeviceStateInfo) -> Void)?
    private var socket: URLSessionWebSocketTask?
    nonisolated let urlSession: URLSession
    private let delegateProxy: WeakSessionDelegate
    private let automaticallyRetries: Bool
    private var manuallyDisconnected = true
    private var generation = 0
    private var retryCount = 0
    private var retryTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var commandTimer: Task<Void, Never>?
    private var apiTasks: [UUID: Task<(Data, URLResponse), Error>] = [:]

    init(device: Device, automaticallyRetries: Bool = true, configuration: URLSessionConfiguration = .default) {
        deviceState = DeviceWithState(initialDevice: device)
        self.automaticallyRetries = automaticallyRetries
        let proxy = WeakSessionDelegate()
        delegateProxy = proxy
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        urlSession = URLSession(configuration: configuration, delegate: proxy, delegateQueue: .main)
        super.init()
        proxy.delegate = self
        deviceState.requestAction = { [weak self] method, path, body, contentType in
            guard let self else { throw DeviceAPIError.disconnected }
            return try await self.request(method: method, path: path, body: body, contentType: contentType)
        }
    }

    func connect() {
        guard socket == nil else { return }
        manuallyDisconnected = false
        deviceState.connectionError = nil
        deviceState.requiresUserAction = false
        deviceState.attemptedTransport = .wifi
        let address: String
        do { address = try validatedDeviceAddress(deviceState.device.wifiAddress) }
        catch { fail(error.localizedDescription, requiresAction: true); return }
        guard let url = URL(string: "ws://\(address)/ws") else { return }
        retryTask?.cancel(); retryTask = nil
        deviceState.websocketStatus = .connecting
        let task = urlSession.webSocketTask(with: URLRequest(url: url, timeoutInterval: 10))
        socket = task
        let current = generation
        task.resume()
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard let self, self.generation == current else { return }
                guard self.deviceState.isOnline, !self.deviceState.isSending else { continue }
                if let last = self.deviceState.lastConfirmedAt, Date().timeIntervalSince(last) > 25 {
                    self.fail("Wi-Fi stopped responding. Reconnecting to refresh WLED.")
                    return
                }
                // WLED supports an application-level state read; this does not change lights.
                do { try await task.send(.string(#"{"v":true}"#)) }
                catch { self.fail("Wi-Fi stopped responding: \(error.localizedDescription)"); return }
            }
        }
        receiveTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await task.receive()
                    guard let self, self.generation == current else { return }
                    let data: Data
                    switch message {
                    case .data(let bytes): data = bytes
                    case .string(let text): data = Data(text.utf8)
                    @unknown default: continue
                    }
                    // Success envelopes aren't state; wait for authoritative data.
                    guard let info = try? JSONDecoder().decode(DeviceStateInfo.self, from: data) else { continue }
                    guard !normalizedDeviceMAC(info.info.mac).isEmpty,
                          normalizedDeviceMAC(info.info.mac) == normalizedDeviceMAC(self.deviceState.device.macAddress) else {
                        self.fail("This network address belongs to a different device. Check the address in Edit Device.", requiresAction: true)
                        return
                    }
                    self.deviceState.rawStatePayload = data
                    self.deviceState.stateInfo = info
                    self.deviceState.lastConfirmedAt = Date()
                    self.deviceState.activeTransport = .wifi
                    self.deviceState.websocketStatus = .connected
                    self.retryCount = 0
                    if self.deviceState.isSending {
                        self.deviceState.isSending = false
                        self.deviceState.commandMessage = "State refreshed from WLED"
                        self.commandTimer?.cancel()
                    }
                    self.onDeviceStateUpdated?(info)
                }
            } catch {
                guard let self, self.generation == current, !self.manuallyDisconnected else { return }
                self.fail("Wi-Fi connection unavailable. Check WLED's power, address and Local Network permission. \(error.localizedDescription)")
            }
        }
    }

    func disconnect() {
        manuallyDisconnected = true
        generation += 1
        deviceState.connectionEpoch = UUID()
        retryTask?.cancel(); retryTask = nil
        receiveTask?.cancel(); receiveTask = nil
        commandTimer?.cancel(); commandTimer = nil
        healthTask?.cancel(); healthTask = nil
        for task in apiTasks.values { task.cancel() }
        apiTasks.removeAll()
        socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        deviceState.websocketStatus = .disconnected
        deviceState.activeTransport = nil
        deviceState.isSending = false
    }

    private func fail(_ message: String, requiresAction: Bool = false) {
        if deviceState.isSending { deviceState.commandMessage = "Change not confirmed. Check the refreshed state before trying again." }
        disconnect()
        manuallyDisconnected = false
        deviceState.connectionError = message
        deviceState.requiresUserAction = requiresAction
        guard automaticallyRetries, !requiresAction else { return }
        let delay = min(2.5 * pow(2, Double(min(retryCount, 5))), 60)
        retryCount += 1
        let current = generation
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.generation == current, !self.manuallyDisconnected else { return }
            self.connect()
        }
    }

    func sendState(_ state: WledState) {
        guard deviceState.isOnline, !manuallyDisconnected, let socket else {
            deviceState.commandMessage = "Not sent. Connect before changing the lights."
            return
        }
        do {
            let data = try JSONEncoder().encode(state)
            deviceState.isSending = true
            deviceState.commandMessage = "Sending…"
            let current = generation
            socket.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == current, let error else { return }
                    self.fail("Change not confirmed: \(error.localizedDescription)")
                }
            }
            commandTimer?.cancel()
            commandTimer = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard let self, self.generation == current, self.deviceState.isSending else { return }
                self.fail("WLED did not confirm the change. Reconnect to read its current state.")
            }
        } catch { deviceState.commandMessage = "Not sent: \(error.localizedDescription)" }
    }

    func destroy() { disconnect(); urlSession.invalidateAndCancel() }
    deinit { urlSession.invalidateAndCancel() }

    func request(method: String, path: String, body: Data = Data()) async throws -> DeviceAPIResponse {
        try await request(method: method, path: path, body: body, contentType: nil)
    }

    func request(method: String, path: String, body: Data, contentType: String?) async throws -> DeviceAPIResponse {
        try Task.checkCancellation()
        try validateDeviceAPIRequest(method: method, path: path)
        guard deviceState.isOnline, !manuallyDisconnected else { throw DeviceAPIError.disconnected }
        let address = try validatedDeviceAddress(deviceState.device.wifiAddress)
        guard let url = URL(string: "http://\(address)\(path)") else { throw DeviceAPIError.invalidRequest }
        let current = generation
        var request = URLRequest(url: url)
        request.httpMethod = method.uppercased()
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if !body.isEmpty {
            request.httpBody = body
            let type = contentType ?? (path.hasPrefix("/settings/") ? "application/x-www-form-urlencoded" : "application/json")
            guard !type.contains("\r"), !type.contains("\n") else { throw DeviceAPIError.invalidRequest }
            request.setValue(type, forHTTPHeaderField: "Content-Type")
        }
        let requestID = UUID()
        let operation = Task { try await urlSession.data(for: request) }
        apiTasks[requestID] = operation
        defer { apiTasks[requestID] = nil }
        let (data, response) = try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
        try Task.checkCancellation()
        guard current == generation, deviceState.isOnline, !manuallyDisconnected else {
            throw DeviceAPIError.connectionChanged
        }
        guard let http = response as? HTTPURLResponse else { throw DeviceAPIError.invalidResponse }
        let route = String(path.split(separator: "?", maxSplits: 1).first ?? "")
        if http.statusCode == 200, ["/json", "/json/si"].contains(route), method.uppercased() == "GET" {
            let info = try JSONDecoder().decode(DeviceStateInfo.self, from: data)
            guard !normalizedDeviceMAC(info.info.mac).isEmpty,
                  normalizedDeviceMAC(info.info.mac) == normalizedDeviceMAC(deviceState.device.macAddress) else {
                fail("This network address belongs to a different device. Check the address in Edit Device.", requiresAction: true)
                throw DeviceAPIError.invalidResponse
            }
            deviceState.rawStatePayload = data
            deviceState.stateInfo = info
            deviceState.lastConfirmedAt = Date()
            onDeviceStateUpdated?(info)
        }
        return DeviceAPIResponse(status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream", body: data)
    }
}

// MARK: - WeakSessionDelegate

// Helper to break the strong reference cycle between URLSession and WebsocketClient
// @unchecked Sendable Justification:
// 1. Problem: This class inherits `Sendable` conformance from `NSObject` but has a mutable `delegate` property, which triggers a concurrency warning.
// 2. Safety: We manually verify thread safety because this delegate is exclusively used by a URLSession configured with `OperationQueue.main`.
// 3. Conclusion: All access to the mutable `delegate` property is guaranteed to occur on the main thread, making the compiler's strict check unnecessary here.
final class WeakSessionDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    weak var delegate: URLSessionWebSocketDelegate?

    init(_ delegate: URLSessionWebSocketDelegate? = nil) {
        self.delegate = delegate
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        delegate?.urlSession?(session, webSocketTask: webSocketTask, didOpenWithProtocol: `protocol`)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        delegate?.urlSession?(session, webSocketTask: webSocketTask, didCloseWith: closeCode, reason: reason)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url, let destination = request.url,
              destination.scheme == original.scheme, destination.host == original.host,
              destination.port == original.port else { completionHandler(nil); return }
        completionHandler(request)
    }
}
