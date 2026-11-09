import Foundation

struct OutputDevice: Identifiable, Hashable, Sendable {
    static let localID = "this-device"

    let id: String
    let name: String
    let deviceClass: DeviceClass

    var isLocal: Bool { id == Self.localID }

    var symbolName: String { deviceClass.symbolName }

    var deviceClassIfRemote: DeviceClass? { isLocal ? nil : deviceClass }

    var linkSessionId: String? {
        id.hasPrefix(Self.linkedPrefix) ? String(id.dropFirst(Self.linkedPrefix.count)) : nil
    }

    private static let linkedPrefix = "linked."

    static var thisDevice: OutputDevice {
        OutputDevice(id: localID, name: "This \(DeviceClass.current.displayName)", deviceClass: .current)
    }

    static func linked(sessionId: String, name: String, deviceClass: DeviceClass) -> OutputDevice {
        OutputDevice(id: linkedPrefix + sessionId, name: name, deviceClass: deviceClass)
    }

    static let deviceClassesThatAcceptOutput: [DeviceClass] = [.tv]
}
