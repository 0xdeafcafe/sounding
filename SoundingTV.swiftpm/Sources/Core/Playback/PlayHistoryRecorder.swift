import Combine
import Foundation

@MainActor
final class PlayHistoryRecorder {
    static let shared = PlayHistoryRecorder()

    private struct Session {
        let track: Track
        var listened: TimeInterval = 0
        var audibleSince: Date?
        var isCounted = false

        mutating func accumulate(until now: Date) {
            guard let since = audibleSince else { return }
            listened += max(0, now.timeIntervalSince(since))
            audibleSince = now
        }
    }

    private weak var player: PlayerService?
    private var cancellables = Set<AnyCancellable>()
    private var session: Session?
    private var isAudible = false
    private var check: Task<Void, Never>?
    private var lastCounted: [String: Date] = [:]

    func attach(to player: PlayerService) {
        guard self.player !== player else { return }
        self.player = player
        cancellables.removeAll()
        player.$isPlaying
            .combineLatest(player.$isLoading)
            .map { $0 && !$1 }
            .removeDuplicates()
            .sink { [weak self] audible in self?.setAudible(audible) }
            .store(in: &cancellables)
        player.$currentTrack
            .removeDuplicates { $0?.id == $1?.id }
            .sink { [weak self] track in self?.begin(track) }
            .store(in: &cancellables)
        PlayHistoryReporter.shared.start()
        PlayHistorySurfaces.shared.start()
        ContinueFrom.shared.attach(to: player)
    }

    private func begin(_ track: Track?) {
        close()
        guard let track else {
            session = nil
            return
        }
        session = Session(track: track, audibleSince: isAudible ? Date() : nil)
        scheduleCheck()
    }

    private func close() {
        check?.cancel()
        check = nil
        guard var current = session else { return }
        current.accumulate(until: Date())
        current.audibleSince = nil
        session = current
        evaluate()
    }

    private func setAudible(_ audible: Bool) {
        isAudible = audible
        guard var current = session else { return }
        let now = Date()
        if audible {
            if current.audibleSince == nil { current.audibleSince = now }
        } else {
            current.accumulate(until: now)
            current.audibleSince = nil
        }
        session = current
        if audible {
            scheduleCheck()
        } else {
            check?.cancel()
            check = nil
            evaluate()
        }
    }

    private func threshold(for track: Track) -> TimeInterval {
        let duration = track.duration > 0 ? track.duration : (player?.duration ?? 0)
        return PlayQualification.threshold(duration: duration)
    }

    private func scheduleCheck() {
        check?.cancel()
        check = nil
        guard let current = session, !current.isCounted, let since = current.audibleSince else { return }
        let heard = current.listened + max(0, Date().timeIntervalSince(since))
        let wait = max(0.5, threshold(for: current.track) - heard)
        check = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.tick()
        }
    }

    private func tick() {
        guard var current = session else { return }
        current.accumulate(until: Date())
        session = current
        evaluate()
        if session?.isCounted == false { scheduleCheck() }
    }

    private func evaluate() {
        guard var current = session, !current.isCounted,
              current.listened >= threshold(for: current.track) else { return }
        current.isCounted = true
        session = current
        count(current.track)
    }

    private func count(_ track: Track) {
        guard let player else { return }
        #if DEBUG
        if VisualFixtures.isEnabled { return }
        #endif
        guard !player.isPlayingSoundCloudPreview, !track.isPreviewOnly else { return }
        let now = Date()
        lastCounted = lastCounted.filter { now.timeIntervalSince($0.value) < 60 * 60 }
        guard !PlayQualification.isRepeat(of: lastCounted[track.id], at: now, duration: track.duration) else { return }
        lastCounted[track.id] = now
        RecentlyPlayed.shared.record(track, at: now)
        if !track.isLocal, !LocalTrackFile.isLocalTrackID(track.id) {
            PlayHistoryReporter.shared.enqueue(trackID: track.id, playedAt: now)
        }
    }
}

@MainActor
final class PlayHistoryReporter {
    static let shared = PlayHistoryReporter()

    private enum Disposition {
        case later
        case laterCounting
        case drop
        case disable
    }

    private static let spacing: Duration = .seconds(2)
    private static let interval: Duration = .seconds(10 * 60)

    private let api: SoundCloudAPI
    private let defaults: UserDefaults
    private var sender: Task<Void, Never>?
    private var isDisabled = false
    private var isStarted = false

    init(api: SoundCloudAPI = .shared, defaults: UserDefaults = .standard) {
        self.api = api
        self.defaults = defaults
    }

    private var accountID: String? { SoundCloudAPI.credentials?.currentUser?.id }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        WorkScheduler.shared.registerPeriodic(
            id: "playHistory.report",
            scope: "playHistory",
            initialDelay: .seconds(30),
            interval: Self.interval,
            constraints: [.network],
            condition: { SoundCloudGateway.shared.isApplicationForeground }
        ) { [weak self] in
            self?.drain()
        }
    }

    func enqueue(trackID: String, playedAt: Date) {
        guard !isDisabled, let accountID else { return }
        let report = PendingPlayReport(trackID: trackID, playedAt: playedAt)
        save(PlayReportOutbox.enqueue(report, into: load(accountID), now: Date()), accountID: accountID)
        drain()
    }

    func drain() {
        guard sender == nil, !isDisabled, let accountID, api.hasCredentials,
              !load(accountID).isEmpty else { return }
        sender = Task { @MainActor [weak self] in
            await self?.send(accountID: accountID)
            self?.sender = nil
        }
    }

    private func send(accountID: String) async {
        while !Task.isCancelled, !isDisabled, self.accountID == accountID {
            let queue = PlayReportOutbox.pruned(load(accountID), now: Date())
            save(queue, accountID: accountID)
            guard let next = queue.first else { return }
            do {
                try await api.reportPlay(trackID: next.trackID)
                remove(next.id, accountID: accountID)
            } catch {
                switch Self.disposition(of: error) {
                case .later:
                    return
                case .laterCounting:
                    update(accountID: accountID) { queue in
                        guard let index = queue.firstIndex(where: { $0.id == next.id }) else { return }
                        queue[index].attempts += 1
                    }
                    return
                case .drop:
                    remove(next.id, accountID: accountID)
                case .disable:
                    isDisabled = true
                    save([], accountID: accountID)
                    Log.api.notice("SoundCloud play history refused plays; reporting is off until next launch")
                    return
                }
            }
            try? await Task.sleep(for: Self.spacing)
        }
    }

    private static func disposition(of error: Error) -> Disposition {
        switch error {
        case let api as APIError:
            switch api {
            case .rateLimited, .temporarilyBlocked, .networkError:
                return .later
            case .unauthorized:
                return .laterCounting
            case .forbidden, .notFound:
                return .disable
            case .serverError(let status):
                return status >= 500 ? .laterCounting : .disable
            case .invalidURL, .noStreamURL, .decodingError:
                return .drop
            }
        case is SoundCloudGatewayError, is URLError, is CancellationError:
            return .later
        default:
            return .laterCounting
        }
    }

    private func key(_ accountID: String) -> String {
        "red.forbes.sounding.playHistory.outbox.\(AccountDataVault.storageSuffix(for: accountID))"
    }

    private func load(_ accountID: String) -> [PendingPlayReport] {
        guard let data = defaults.data(forKey: key(accountID)) else { return [] }
        return (try? JSONDecoder().decode([PendingPlayReport].self, from: data)) ?? []
    }

    private func save(_ queue: [PendingPlayReport], accountID: String) {
        if queue.isEmpty {
            defaults.removeObject(forKey: key(accountID))
        } else if let data = try? JSONEncoder().encode(queue) {
            defaults.set(data, forKey: key(accountID))
        }
    }

    private func remove(_ id: String, accountID: String) {
        update(accountID: accountID) { $0.removeAll { $0.id == id } }
    }

    private func update(accountID: String, _ change: (inout [PendingPlayReport]) -> Void) {
        var queue = load(accountID)
        change(&queue)
        save(queue, accountID: accountID)
    }
}

@MainActor
final class PlayHistorySurfaces {
    static let shared = PlayHistorySurfaces()

    private var observation: AnyCancellable?

    func start() {
        guard observation == nil else { return }
        observation = RecentlyPlayed.shared.$items
            .map { $0.map(\.track) }
            .removeDuplicates()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { tracks in
                Task { @MainActor in PlayHistorySurfaces.publish(tracks) }
            }
    }

    private static func publish(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        SoundingSnapshotPublisher.shared.adoptRecents(tracks.map { SoundingSnapshotPublisher.item(for: $0) })
        #if os(tvOS)
        TopShelfPublisher.publish(recents: tracks)
        #endif
    }
}
