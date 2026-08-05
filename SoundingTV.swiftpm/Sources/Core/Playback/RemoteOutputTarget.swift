import Foundation

enum PlaybackOutput: Equatable, Hashable, Sendable {
    case thisDevice
    case companion(DeviceClass)

    var isCompanion: Bool {
        switch self {
        case .thisDevice: return false
        case .companion: return true
        }
    }

    var companionClass: DeviceClass? {
        switch self {
        case .thisDevice: return nil
        case .companion(let deviceClass): return deviceClass
        }
    }

    var displayName: String {
        switch self {
        case .thisDevice: return "This \(DeviceClass.current.displayName)"
        case .companion(let deviceClass): return deviceClass.displayName
        }
    }

    var symbolName: String {
        switch self {
        case .thisDevice: return DeviceClass.current.symbolName
        case .companion(let deviceClass): return deviceClass.symbolName
        }
    }

    static let deviceClassesWithCompanionServerToday: [DeviceClass] = [.tv]
}

@MainActor
protocol CompanionOutputTarget: AnyObject {
    var isReachable: Bool { get }

    func sendPlayback(track: Track, queue: [Track], index: Int, position: TimeInterval, isPlaying: Bool)

    func pausePlayback()
}
