import Foundation
import Combine

@MainActor
final class AutoMixIntentStore: ObservableObject {
    static let shared = AutoMixIntentStore()

    struct Active: Codable, Equatable, Sendable {
        let intent: SetIntent
        let startedAt: Date

        func isExpired(now: Date) -> Bool {
            let lifetime = (intent.durationMinutes ?? AutoMixIntentStore.defaultLifetimeMinutes) * 60
            return now.timeIntervalSince(startedAt) > lifetime
        }
    }

    enum Outcome: Equatable {
        case understood(SetIntent)
        case notUnderstood
    }

    nonisolated static let defaultLifetimeMinutes = 6.0 * 60
    private static let defaultsKey = "red.forbes.sounding.autoMixIntent.v1"

    @Published private(set) var active: Active?
    @Published private(set) var isWorking = false

    private let defaults: UserDefaults
    private let language: AutoMixLanguage

    init(defaults: UserDefaults = .standard, language: AutoMixLanguage = AutoMixLanguage()) {
        self.defaults = defaults
        self.language = language
        if let data = defaults.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode(Active.self, from: data),
           !stored.isExpired(now: Date()) {
            active = stored
        }
    }

    var current: Active? {
        guard let active, !active.isExpired(now: Date()) else { return nil }
        return active
    }

    @discardableResult
    func submit(_ text: String, now: Date = Date()) async -> Outcome {
        isWorking = true
        defer { isWorking = false }
        guard let intent = await language.intent(for: text, now: now) else { return .notUnderstood }
        set(Active(intent: intent, startedAt: now))
        return .understood(intent)
    }

    func clear() {
        set(nil)
    }

    private func set(_ value: Active?) {
        active = value
        if let value, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: Self.defaultsKey)
        } else {
            defaults.removeObject(forKey: Self.defaultsKey)
        }
    }
}
