import Combine
import Foundation
import Observation

@MainActor
@Observable
final class NowPlayingTimeline {
    private(set) var anchor: PlaybackAnchor = .idle
    var scrubPreview: TimeInterval?

    @ObservationIgnored private let player: PlayerService
    @ObservationIgnored private let client: CompanionClient
    @ObservationIgnored private let output: OutputRouter
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var fixture: PlaybackAnchor?
    @ObservationIgnored private var pendingSeek: PendingRemoteSeek?
    @ObservationIgnored private var localSeek: PendingLocalSeek?
    @ObservationIgnored private var seekSettleTask: Task<Void, Never>?

    init(player: PlayerService, client: CompanionClient, output: OutputRouter) {
        self.player = player
        self.client = client
        self.output = output

        player.clock.$currentTime
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        player.clock.$duration
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        player.$isPlaying
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        player.$currentTrack
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        output.$current
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        client.telemetry.objectWillChange
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        client.objectWillChange
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)

        refresh()
    }

    func noteSeek(to position: TimeInterval) {
        let now = Date()
        let next = anchor.seeking(to: position, at: now)
        let bounded = next.position
        publish(next)
        if let current = fixture {
            fixture = PlaybackAnchor(position: bounded, date: now, rate: current.rate, duration: current.duration)
            clearPendingSeek()
            return
        }
        guard !output.current.isLocal else {
            clearPendingSeek()
            localSeek = PendingLocalSeek(target: bounded, issuedAt: now, trackID: player.currentTrack?.id)
            seekSettleTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(PendingLocalSeek.deadline + 0.05))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
            return
        }
        localSeek = nil
        pendingSeek = PendingRemoteSeek(
            target: bounded,
            rate: anchor.rate,
            issuedAt: now,
            baselineRevision: client.telemetry.playback?.revision ?? 0
        )
        seekSettleTask?.cancel()
        seekSettleTask = Task { @MainActor [weak self] in
            for delay in [PendingRemoteSeek.grace, PendingRemoteSeek.deadline - PendingRemoteSeek.grace + 0.05] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    private func clearPendingSeek() {
        pendingSeek = nil
        seekSettleTask?.cancel()
        seekSettleTask = nil
    }

    func adoptFixture(position: TimeInterval, duration: TimeInterval, isPlaying: Bool) {
        let fixed = PlaybackAnchor(position: position, date: .now, rate: isPlaying ? 1 : 0, duration: duration)
        fixture = fixed
        publish(fixed)
    }

    private func scheduleRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.refreshTask = nil
            self.refresh()
        }
    }

    private func refresh() {
        if let fixture {
            if fixture != anchor { publish(fixture) }
            return
        }
        if output.current.isLocal {
            if pendingSeek != nil { clearPendingSeek() }
            let clock = player.clock
            let duration = clock.duration > 0 ? clock.duration : (player.currentTrack?.duration ?? 0)
            guard player.currentTrack != nil else {
                localSeek = nil
                if anchor != .idle { publish(.idle) }
                return
            }
            let now = Date()
            if let seek = localSeek {
                if seek.isExpired(at: now, trackID: player.currentTrack?.id) {
                    localSeek = nil
                } else if !seek.accepts(clock.currentTime, at: now) {
                    reconcile(
                        position: anchor.position(at: now),
                        observedAt: now,
                        rate: player.isPlaying ? 1 : 0,
                        duration: duration
                    )
                    return
                }
            }
            reconcile(
                position: clock.currentTime,
                observedAt: clock.updatedAt,
                rate: player.isPlaying ? 1 : 0,
                duration: duration
            )
        } else {
            localSeek = nil
            guard let playback = client.telemetry.playback else {
                if anchor != .idle { publish(.idle) }
                return
            }
            let live = client.telemetry.isLive
            let now = Date()
            if let pendingSeek {
                let resolution = pendingSeek.resolution(
                    revision: playback.revision,
                    position: live ? client.telemetry.estimatedPosition(at: now) : nil,
                    at: now
                )
                guard resolution == .settle else { return }
                clearPendingSeek()
            }
            reconcile(
                position: client.telemetry.estimatedPosition(at: now),
                observedAt: now,
                rate: live && playback.isPlaying ? playback.effectiveRate : 0,
                duration: playback.durationSeconds
            )
        }
    }

    private func reconcile(position: TimeInterval, observedAt: Date, rate: Double, duration: TimeInterval) {
        guard let next = anchor.reconciled(position: position, observedAt: observedAt, rate: rate, duration: duration) else { return }
        publish(next)
    }

    private func publish(_ next: PlaybackAnchor) {
        anchor = next
        MusicPulse.shared.anchor(position: next.position(at: .now), isPlaying: next.isAdvancing)
    }
}
