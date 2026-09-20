import Foundation

@MainActor
protocol DeviceConnectionClient: AnyObject {
    var deviceState: DeviceWithState { get }
    var onDeviceStateUpdated: ((DeviceStateInfo) -> Void)? { get set }

    func connect()
    func disconnect()
    func sendState(_ state: WledState)
    func destroy()
}
