import ActivityKit
import AlarmKit
import AppIntents
import Combine
import SwiftUI

struct WakeTarget: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case likes
        case track
        case playlist
        case station
    }

    var kind: Kind
    var id: String
    var title: String

    static let likes = WakeTarget(kind: .likes, id: MediaTarget.likesID, title: "Likes")

    var summary: String {
        switch kind {
        case .likes: return "Shuffle Likes"
        case .track: return title
        case .playlist: return title
        case .station: return "\(title) Station"
        }
    }
}

struct WakeAlarm: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var hour: Int
    var minute: Int
    var weekdays: [Locale.Weekday]
    var target: WakeTarget
    var isEnabled: Bool

    var time: DateComponents { DateComponents(hour: hour, minute: minute) }

    var repeatSummary: String {
        guard !weekdays.isEmpty else { return "Once" }
        if Set(weekdays) == Set(Locale.Weekday.allWeek) { return "Every Day" }
        if Set(weekdays) == Set(Locale.Weekday.weekdays) { return "Weekdays" }
        if Set(weekdays) == Set([Locale.Weekday.saturday, .sunday]) { return "Weekends" }
        let symbols = Calendar.current.shortWeekdaySymbols
        return Locale.Weekday.allWeek.filter(weekdays.contains).map { symbols[$0.calendarIndex] }.joined(separator: " ")
    }
}

extension Locale.Weekday {
    static let allWeek: [Locale.Weekday] = [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]
    static let weekdays: [Locale.Weekday] = [.monday, .tuesday, .wednesday, .thursday, .friday]

    var calendarIndex: Int {
        switch self {
        case .sunday: return 0
        case .monday: return 1
        case .tuesday: return 2
        case .wednesday: return 3
        case .thursday: return 4
        case .friday: return 5
        default: return 6
        }
    }
}

nonisolated struct WakeAlarmMetadata: AlarmMetadata {
    var target: WakeTarget
}

@MainActor
final class WakeAlarmStore: ObservableObject {
    static let shared = WakeAlarmStore()
    private static let defaultsKey = "red.forbes.sounding.wakeAlarms.v1"

    @Published private(set) var alarms: [WakeAlarm] = []
    @Published private(set) var authorization: AlarmManager.AuthorizationState = .notDetermined
    @Published var lastError: String?

    private var updatesTask: Task<Void, Never>?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([WakeAlarm].self, from: data) {
            alarms = saved.sorted(by: Self.order)
        }
        #if DEBUG
        if VisualFixtures.isEnabled {
            authorization = .authorized
            if alarms.isEmpty, ProcessInfo.processInfo.environment["SOUNDING_TV_WAKE_ALARMS"] == "1" {
                alarms = Self.fixtureAlarms
            }
            return
        }
        #endif
        authorization = AlarmManager.shared.authorizationState
        observe()
    }

    func target(for alarmID: UUID) -> WakeTarget? {
        alarms.first { $0.id == alarmID }?.target
    }

    func requestAuthorization() async -> Bool {
        #if DEBUG
        if VisualFixtures.isEnabled { return true }
        #endif
        let state = (try? await AlarmManager.shared.requestAuthorization()) ?? AlarmManager.shared.authorizationState
        authorization = state
        return state == .authorized
    }

    func save(_ alarm: WakeAlarm) async {
        lastError = nil
        var alarm = alarm
        if alarm.isEnabled {
            guard await requestAuthorization() else {
                alarm.isEnabled = false
                upsert(alarm)
                return
            }
            do {
                try await schedule(alarm)
            } catch AlarmManager.AlarmError.maximumLimitReached {
                alarm.isEnabled = false
                lastError = "You have too many alarms. Delete one and try again."
            } catch {
                alarm.isEnabled = false
                lastError = "The alarm couldn’t be set. Try again."
            }
        } else {
            unschedule(alarm.id)
        }
        upsert(alarm)
    }

    func setEnabled(_ enabled: Bool, for alarm: WakeAlarm) async {
        var updated = alarm
        updated.isEnabled = enabled
        await save(updated)
    }

    func delete(_ alarm: WakeAlarm) {
        unschedule(alarm.id)
        alarms.removeAll { $0.id == alarm.id }
        persist()
    }

    private func upsert(_ alarm: WakeAlarm) {
        if let index = alarms.firstIndex(where: { $0.id == alarm.id }) {
            alarms[index] = alarm
        } else {
            alarms.append(alarm)
        }
        alarms.sort(by: Self.order)
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(alarms) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private static func order(_ a: WakeAlarm, _ b: WakeAlarm) -> Bool {
        (a.hour, a.minute) < (b.hour, b.minute)
    }

    private func schedule(_ alarm: WakeAlarm) async throws {
        #if DEBUG
        if VisualFixtures.isEnabled { return }
        #endif
        unschedule(alarm.id)
        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: alarm.target.summary),
            stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.fill"),
            secondaryButton: AlarmButton(text: "Play", textColor: .black, systemImageName: "play.fill"),
            secondaryButtonBehavior: .custom
        )
        let attributes = AlarmAttributes<WakeAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert),
            metadata: WakeAlarmMetadata(target: alarm.target),
            tintColor: .white
        )
        let schedule = Alarm.Schedule.relative(Alarm.Schedule.Relative(
            time: Alarm.Schedule.Relative.Time(hour: alarm.hour, minute: alarm.minute),
            repeats: alarm.weekdays.isEmpty ? .never : .weekly(alarm.weekdays)
        ))
        let id = alarm.id.uuidString
        let configuration = AlarmManager.AlarmConfiguration<WakeAlarmMetadata>.alarm(
            schedule: schedule,
            attributes: attributes,
            stopIntent: StopWakeAlarmIntent(alarmID: id),
            secondaryIntent: PlayWakeAlarmIntent(alarmID: id),
            sound: .default
        )
        _ = try await AlarmManager.shared.schedule(id: alarm.id, configuration: configuration)
    }

    private func unschedule(_ id: UUID) {
        #if DEBUG
        if VisualFixtures.isEnabled { return }
        #endif
        try? AlarmManager.shared.cancel(id: id)
    }

    private func observe() {
        updatesTask = Task { [weak self] in
            for await live in AlarmManager.shared.alarmUpdates {
                self?.reconcile(liveIDs: Set(live.map(\.id)))
            }
        }
        Task { [weak self] in
            for await state in AlarmManager.shared.authorizationUpdates {
                self?.authorization = state
            }
        }
    }

    private func reconcile(liveIDs: Set<UUID>) {
        var changed = false
        for index in alarms.indices where alarms[index].isEnabled && !liveIDs.contains(alarms[index].id) {
            alarms[index].isEnabled = false
            changed = true
        }
        if changed { persist() }
    }

    #if DEBUG
    private static var fixtureAlarms: [WakeAlarm] {
        [
            WakeAlarm(id: UUID(), hour: 7, minute: 0, weekdays: Locale.Weekday.weekdays,
                      target: WakeTarget(kind: .playlist, id: "fixture.playlist", title: "Slow Mornings"), isEnabled: true),
            WakeAlarm(id: UUID(), hour: 9, minute: 30, weekdays: [.saturday, .sunday],
                      target: WakeTarget(kind: .station, id: "fixture.track", title: "Late Night Drive"), isEnabled: false),
        ]
    }
    #endif
}

@MainActor
enum WakePlayback {
    static let rampDuration: TimeInterval = 60
    private static var rampTask: Task<Void, Never>?

    static func start(_ target: WakeTarget) async throws {
        let player = PlayerService.shared
        SleepTimer.shared.cancel()
        rampTask?.cancel()
        player.setSleepFadeGain(0.03)
        do {
            switch target.kind {
            case .likes: try await IntentPlayback.playLikes(shuffle: true)
            case .track: try await IntentPlayback.playTrack(id: target.id)
            case .playlist: try await IntentPlayback.playPlaylist(id: target.id)
            case .station: try await IntentPlayback.playStation(seedTrackID: target.id)
            }
        } catch {
            player.setSleepFadeGain(1)
            throw error
        }
        let started = Date()
        rampTask = Task { @MainActor in
            while !Task.isCancelled {
                let progress = min(1, Date().timeIntervalSince(started) / rampDuration)
                player.setSleepFadeGain(0.03 + 0.97 * (0.5 - 0.5 * cos(.pi * progress)))
                if progress >= 1 { return }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }
}

struct PlayWakeAlarmIntent: LiveActivityIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Wake-Up Music"
    static let isDiscoverable = false

    @Parameter(title: "Alarm")
    var alarmID: String

    init() {}

    init(alarmID: String) {
        self.alarmID = alarmID
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: alarmID) else { return .result() }
        try? AlarmManager.shared.stop(id: id)
        try await WakePlayback.start(WakeAlarmStore.shared.target(for: id) ?? .likes)
        return .result()
    }
}

struct StopWakeAlarmIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Alarm"
    static let isDiscoverable = false

    @Parameter(title: "Alarm")
    var alarmID: String

    init() {}

    init(alarmID: String) {
        self.alarmID = alarmID
    }

    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: alarmID) {
            try? AlarmManager.shared.stop(id: id)
        }
        return .result()
    }
}
