import Foundation
import Combine

@MainActor
final class AutoMixEnergy: ObservableObject {
    static let shared = AutoMixEnergy()

    enum Source: String, Equatable, Sendable {
        case workout
        case remote
        case night
        case manual
    }

    struct Reading: Equatable, Sendable {
        let level: Int
        let source: Source
        let heartRate: Double?
    }

    static let heartRateFreshness: TimeInterval = 30
    static let remoteFreshness: TimeInterval = 90

    @Published private(set) var heartRate: (bpm: Double, at: Date)?
    @Published private(set) var remote: (level: Int, heartRate: Double?, at: Date)?

    private let settings: SettingsStore

    init(settings: SettingsStore = .shared) {
        self.settings = settings
    }

    func noteHeartRate(_ bpm: Double, at date: Date = Date()) {
        guard bpm.isFinite, bpm > 30, bpm < 240 else { return }
        heartRate = (bpm, date)
    }

    func receiveRemote(level: Int, heartRate: Double?, at date: Date = Date()) {
        guard (1...10).contains(level) else {
            remote = nil
            return
        }
        remote = (level, heartRate.flatMap { $0 > 0 ? $0 : nil }, date)
    }

    func reading(now: Date = Date(), calendar: Calendar = .current) -> Reading {
        if settings.djMatchWorkout, let heartRate, now.timeIntervalSince(heartRate.at) <= Self.heartRateFreshness {
            return Reading(level: Self.level(heartRate: heartRate.bpm), source: .workout, heartRate: heartRate.bpm)
        }
        if let remote, now.timeIntervalSince(remote.at) <= Self.remoteFreshness {
            return Reading(level: remote.level, source: .remote, heartRate: remote.heartRate)
        }
        if settings.djEnergyFollowsNight {
            return Reading(level: Self.nightLevel(at: now, calendar: calendar), source: .night, heartRate: nil)
        }
        return Reading(level: Self.level(slider: settings.djEnergyLevel), source: .manual, heartRate: nil)
    }

    var target: Int { reading().level }

    nonisolated static func level(slider: Double) -> Int {
        min(10, max(1, Int((1 + min(1, max(0, slider)) * 9).rounded())))
    }

    nonisolated static func level(heartRate bpm: Double) -> Int {
        switch bpm {
        case ..<90: return 3
        case ..<105: return 4
        case ..<120: return 5
        case ..<135: return 6
        case ..<150: return 7
        case ..<162: return 8
        case ..<175: return 9
        default: return 10
        }
    }

    nonisolated static func nightLevel(at date: Date, calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour = Double(parts.hour ?? 20) + Double(parts.minute ?? 0) / 60
        let arc: [(hour: Double, level: Double)] = [
            (0, 8.5), (2, 7.5), (4, 5), (6, 3), (11, 4), (17, 5), (20, 6), (22, 7.5), (24, 8.5)
        ]
        for index in 1..<arc.count where hour <= arc[index].hour {
            let a = arc[index - 1]
            let b = arc[index]
            let t = (hour - a.hour) / max(0.01, b.hour - a.hour)
            return Int((a.level + (b.level - a.level) * t).rounded())
        }
        return 6
    }
}
