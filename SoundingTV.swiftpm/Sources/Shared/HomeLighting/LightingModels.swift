import Foundation

enum LightingIntensity: String, Codable, CaseIterable, Identifiable, Sendable {
    case subtle
    case party
    case off

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .subtle: return "Subtle"
        case .party: return "Party"
        case .off: return "Off"
        }
    }

    var brightnessRange: ClosedRange<Double> {
        switch self {
        case .subtle: return 0.15...0.60
        case .party: return 0.25...1.00
        case .off: return 0...0
        }
    }

    var dropPulseSpacing: TimeInterval? {
        switch self {
        case .subtle: return nil
        case .party: return 24
        case .off: return nil
        }
    }

    var wireValue: Double {
        switch self {
        case .off: return 0
        case .subtle: return 1
        case .party: return 2
        }
    }

    init(wireValue: Double) {
        switch Int(wireValue.rounded()) {
        case 1: self = .subtle
        case 2: self = .party
        default: self = .off
        }
    }
}

struct LightColor: Equatable, Sendable, Codable {
    var hue: Double
    var saturation: Double

    init(hue: Double, saturation: Double) {
        let wrapped = hue.truncatingRemainder(dividingBy: 360)
        self.hue = wrapped < 0 ? wrapped + 360 : wrapped
        self.saturation = min(1, max(0, saturation))
    }

    static let warmGlow = LightColor(hue: 32, saturation: 0.62)
}

struct LightState: Equatable, Sendable {
    var isOn: Bool
    var color: LightColor
    var brightness: Double

    init(isOn: Bool = true, color: LightColor, brightness: Double) {
        self.isOn = isOn
        self.color = color
        self.brightness = min(1, max(0, brightness))
    }

    func isClose(to other: LightState) -> Bool {
        guard isOn == other.isOn else { return false }
        guard isOn else { return true }
        return LightState.hueDistance(color.hue, other.color.hue) < 2
            && abs(color.saturation - other.color.saturation) < 0.02
            && abs(brightness - other.brightness) < 0.01
    }

    static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }
}

struct LightCapabilities: OptionSet, Hashable, Sendable {
    let rawValue: Int

    static let power = LightCapabilities(rawValue: 1 << 0)
    static let brightness = LightCapabilities(rawValue: 1 << 1)
    static let color = LightCapabilities(rawValue: 1 << 2)
}

struct LightWriteChanges: Equatable, Sendable {
    var isOn: Bool?
    var hue: Double?
    var saturation: Double?
    var brightness: Double?

    var isEmpty: Bool { isOn == nil && hue == nil && saturation == nil && brightness == nil }

    var characteristicCount: Int {
        [isOn != nil, hue != nil, saturation != nil, brightness != nil].filter { $0 }.count
    }

    static func between(_ previous: LightState?, _ next: LightState, capabilities: LightCapabilities) -> LightWriteChanges {
        var changes = LightWriteChanges()
        if capabilities.contains(.power), previous?.isOn != next.isOn {
            changes.isOn = next.isOn
        }
        guard next.isOn else { return changes }
        if capabilities.contains(.color) {
            if previous.map({ LightState.hueDistance($0.color.hue, next.color.hue) >= 2 }) ?? true {
                changes.hue = next.color.hue
            }
            if previous.map({ abs($0.color.saturation - next.color.saturation) >= 0.02 }) ?? true {
                changes.saturation = next.color.saturation
            }
        }
        if capabilities.contains(.brightness),
           previous.map({ abs($0.brightness - next.brightness) >= 0.01 }) ?? true {
            changes.brightness = next.brightness
        }
        return changes
    }
}

enum LightCueKind: Equatable, Sendable {
    case phrase
    case drop
    case dropRelease
    case breakdown
}

struct LightCue: Equatable, Sendable {
    let time: TimeInterval
    let state: LightState
    let kind: LightCueKind
}

enum HomeAccessState: Equatable, Sendable {
    case notRequested
    case waiting
    case denied
    case ready
}

struct HomeLightInfo: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let roomID: String
    let capabilities: LightCapabilities
}

struct HomeRoomInfo: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let lights: [HomeLightInfo]
}

struct HomeInfo: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isPrimary: Bool
    let rooms: [HomeRoomInfo]

    var lights: [HomeLightInfo] { rooms.flatMap(\.lights) }
}

struct HomeSnapshot: Equatable, Sendable {
    var access: HomeAccessState
    var homes: [HomeInfo]

    static let unrequested = HomeSnapshot(access: .notRequested, homes: [])

    func home(id: String?) -> HomeInfo? {
        if let id, let match = homes.first(where: { $0.id == id }) { return match }
        return homes.first(where: \.isPrimary) ?? homes.first
    }
}
