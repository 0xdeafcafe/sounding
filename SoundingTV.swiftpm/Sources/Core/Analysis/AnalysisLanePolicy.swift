import Foundation

struct AnalysisLaneConditions: Sendable, Equatable {
    var device: DeviceClass
    var performanceCores: Int
    var isOnPower: Bool
    var isPlaying: Bool
    var isScreenIdle: Bool
    var systemPause: String?

    init(
        device: DeviceClass = .current,
        performanceCores: Int = AnalysisLanePolicy.performanceCoreCount,
        isOnPower: Bool,
        isPlaying: Bool,
        isScreenIdle: Bool = false,
        systemPause: String? = nil
    ) {
        self.device = device
        self.performanceCores = performanceCores
        self.isOnPower = isOnPower
        self.isPlaying = isPlaying
        self.isScreenIdle = isScreenIdle
        self.systemPause = systemPause
    }
}

enum AnalysisLanePolicy {
    static let restingYield: Duration = .seconds(2)

    static let lowPowerReason = "Waiting for Low Power Mode to end"
    static let thermalReason = "Waiting for the device to cool down"
    static let batteryReason = "Waiting for battery to charge"

    static func backgroundLanes(_ conditions: AnalysisLaneConditions) -> Int {
        guard conditions.systemPause == nil else { return 0 }
        return conditions.device == .watch ? 0 : 1
    }

    static func pause(_ conditions: AnalysisLaneConditions) -> HeavyWorkPause? {
        if let reason = conditions.systemPause {
            if reason == lowPowerReason { return .lowPower }
            if reason == thermalReason { return .thermal }
            return .battery
        }
        if !allowsBacklog(conditions) { return conditions.device == .watch ? nil : .battery }
        if conditions.isPlaying { return .listening }
        return nil
    }

    static func allowsBacklog(_ conditions: AnalysisLaneConditions) -> Bool {
        switch conditions.device {
        case .pad, .phone: return conditions.isOnPower
        case .mac, .tv: return true
        case .watch: return false
        }
    }

    static func capacity(_ conditions: AnalysisLaneConditions) -> Int {
        max(1, backgroundLanes(conditions))
    }

    static func mayStartInteractive(running: Int, interactiveRunning: Bool, _ conditions: AnalysisLaneConditions) -> Bool {
        if conditions.device == .tv { return running == 0 }
        return running < capacity(conditions) || !interactiveRunning
    }

    static func isUnthrottled(_ conditions: AnalysisLaneConditions) -> Bool {
        conditions.isOnPower && !conditions.isPlaying && conditions.systemPause == nil
    }

    static func yield(_ conditions: AnalysisLaneConditions) -> Duration {
        isUnthrottled(conditions) ? .zero : restingYield
    }

    static let performanceCoreCount: Int = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &value, &size, nil, 0) == 0, value > 0 {
            return Int(value)
        }
        return max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
    }()
}
