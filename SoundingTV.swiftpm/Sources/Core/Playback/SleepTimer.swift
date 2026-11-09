import Combine
import Foundation

@MainActor
final class SleepTimer: ObservableObject {
    static let shared = SleepTimer()
    nonisolated static let fadeDuration: TimeInterval = 30

    @Published private(set) var status: SleepTimerStatus?

    private let player: PlayerService
    private var deadline: Date?
    private var trackID: String?
    private var targetPosition: TimeInterval?
    private var task: Task<Void, Never>?
    private var trackObservation: AnyCancellable?

    init(player: PlayerService = .shared) {
        self.player = player
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["SOUNDING_TV_SLEEP_TIMER"], let minutes = Int(raw) {
            Task { @MainActor [weak self] in self?.start(.minutes(minutes)) }
        }
        #endif
    }

    var isActive: Bool { status != nil }

    static func offersEndOfMix(trackID: String?) -> Bool {
        guard let list = SetlistIntelligenceStore.shared.tracklist(for: trackID) else { return false }
        return list.entries.count > 1
    }

    static func label(for mode: SleepTimerMode) -> String {
        switch mode {
        case .minutes(let minutes): return "\(minutes) Minutes"
        case .endOfTrack: return "End of Track"
        case .endOfMix: return "End of Mix"
        }
    }

    nonisolated static func gain(remaining: TimeInterval) -> Double {
        guard remaining.isFinite else { return 1 }
        if remaining <= 0 { return 0 }
        if remaining >= fadeDuration { return 1 }
        let progress = 1 - remaining / fadeDuration
        return 0.5 + 0.5 * cos(.pi * progress)
    }

    nonisolated static func endOfTrackTarget(position: TimeInterval, duration: TimeInterval, tracklist: Tracklist?) -> TimeInterval {
        guard let tracklist, tracklist.entries.count > 1,
              let index = tracklist.currentIndex(at: position),
              index < tracklist.entries.count - 1 else { return duration }
        return min(duration, tracklist.entries[index].endSeconds)
    }

    func start(_ mode: SleepTimerMode) {
        stopTicking()
        player.setSleepFadeGain(1)
        let now = Date()
        switch mode {
        case .minutes(let minutes):
            deadline = now.addingTimeInterval(TimeInterval(max(1, minutes)) * 60)
            trackID = nil
            targetPosition = nil
        case .endOfTrack, .endOfMix:
            guard let track = player.currentTrack else {
                cancel()
                return
            }
            deadline = nil
            trackID = track.id
            let duration = player.duration
            if mode == .endOfMix {
                targetPosition = duration > 0 ? duration : nil
            } else {
                targetPosition = Self.endOfTrackTarget(
                    position: player.currentTime,
                    duration: duration,
                    tracklist: SetlistIntelligenceStore.shared.tracklist(for: track.id)
                )
            }
            trackObservation = player.$currentTrack
                .dropFirst()
                .sink { [weak self] next in
                    guard let self, next?.id != self.trackID else { return }
                    Task { @MainActor [weak self] in self?.finish() }
                }
        }
        status = SleepTimerStatus(mode: mode, endsAt: projectedEnd(at: now))
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = self.tick()
                guard let delay else { return }
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    func cancel() {
        stopTicking()
        deadline = nil
        trackID = nil
        targetPosition = nil
        player.setSleepFadeGain(1)
        if status != nil { status = nil }
    }

    func remaining(at now: Date = Date()) -> TimeInterval? {
        guard status != nil else { return nil }
        if let deadline { return deadline.timeIntervalSince(now) }
        guard let targetPosition, player.currentTrack?.id == trackID else { return 0 }
        if targetPosition <= 0 {
            let duration = player.duration
            guard duration > 0 else { return nil }
            self.targetPosition = duration
            return duration - player.currentTime
        }
        return targetPosition - player.currentTime
    }

    private func projectedEnd(at now: Date) -> Date? {
        if let deadline { return deadline }
        guard let left = remaining(at: now), player.isPlaying else { return nil }
        return now.addingTimeInterval(max(0, left))
    }

    private func tick() -> TimeInterval? {
        let now = Date()
        guard let left = remaining(at: now) else {
            refreshEndDate(now)
            return 1
        }
        if left <= 0 {
            finish()
            return nil
        }
        player.setSleepFadeGain(Self.gain(remaining: left))
        refreshEndDate(now)
        return left <= Self.fadeDuration + 1 ? 0.25 : 1
    }

    private func refreshEndDate(_ now: Date) {
        guard var current = status else { return }
        let projected = projectedEnd(at: now)
        switch (current.endsAt, projected) {
        case (nil, nil): return
        case let (old?, new?) where abs(old.timeIntervalSince(new)) < 2: return
        default: break
        }
        current.endsAt = projected
        status = current
    }

    private func finish() {
        guard status != nil else { return }
        stopTicking()
        player.pause()
        cancel()
    }

    private func stopTicking() {
        task?.cancel()
        task = nil
        trackObservation = nil
    }
}
