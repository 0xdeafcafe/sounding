import Combine
import Foundation

@MainActor
final class DevicePresenceModel: ObservableObject {
    static let shared = DevicePresenceModel()

    enum Action: String, Hashable, Identifiable, CaseIterable {
        case control
        case playOn
        case playHere

        var id: String { rawValue }
    }

    @Published private(set) var entries: [DevicePresenceEntry] = []
    @Published private(set) var busyEntryID: String?
    @Published var failure: String?

    private let settings: SettingsStore
    private let continueFrom: ContinueFrom
    private let player: PlayerService
    private let now: () -> Date
    private var cancellables = Set<AnyCancellable>()
    private var routerCancellables = Set<AnyCancellable>()
    private var sessions: [String: ContinueSession] = [:]
    private var liveStart: (key: String, at: Date)?
    private var refreshScheduled = false
    private var wakeTask: Task<Void, Never>?
    #if !os(tvOS)
    private weak var router: OutputRouter?
    #endif

    init(
        settings: SettingsStore = .shared,
        continueFrom: ContinueFrom = .shared,
        player: PlayerService = .shared,
        now: @escaping () -> Date = { Date() }
    ) {
        self.settings = settings
        self.continueFrom = continueFrom
        self.player = player
        self.now = now
        settings.$continueSessions
            .removeDuplicates()
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        continueFrom.nearbyDidChange
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        player.$currentTrack
            .map { $0?.id }
            .removeDuplicates()
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: AccountDataVault.didForgetAccountData)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        scheduleRefresh()
    }

    #if !os(tvOS)
    func attach(router: OutputRouter) {
        guard self.router !== router else { return }
        self.router = router
        routerCancellables.removeAll()
        router.client.objectWillChange
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &routerCancellables)
        router.client.telemetry.objectWillChange
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &routerCancellables)
        router.$current
            .removeDuplicates()
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &routerCancellables)
        scheduleRefresh()
    }
    #endif

    // MARK: - Reading

    var primary: DevicePresenceEntry? { entries.first }

    func others(excludingOutput: Bool) -> [DevicePresenceEntry] {
        DevicePresence.others(entries, excludingOutput: excludingOutput)
    }

    func summary(localTitle: String?, others: [DevicePresenceEntry]) -> String {
        DevicePresence.summary(localTitle: localTitle, others: others, now: now())
    }

    // MARK: - Refresh

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    private func refresh() {
        let moment = now()
        guard let account = continueFrom.accountKey else {
            sessions = [:]
            if !entries.isEmpty { entries = [] }
            return
        }
        var records = settings.continueSessions.map { DevicePresenceRecord(session: $0, source: .cloud) }
        records += continueFrom.nearbySessions.map { DevicePresenceRecord(session: $0, source: .link) }

        let live = liveReports(at: moment)
        let next = DevicePresence.entries(
            records: records,
            live: live.reports,
            outputs: live.outputs,
            currentOutputID: live.currentOutputID,
            ownDeviceID: continueFrom.ownDeviceID,
            account: account,
            localTrackID: localTrackID,
            now: moment
        )

        var byEntry: [String: ContinueSession] = [:]
        for record in records {
            let id = "device:\(record.session.deviceID)"
            guard next.contains(where: { $0.id == id }) else { continue }
            if let existing = byEntry[id], !record.session.isNewer(than: existing) { continue }
            byEntry[id] = record.session
        }
        sessions = byEntry

        if Self.signature(next) != Self.signature(entries) { entries = next }
        scheduleWake(after: moment)
    }

    private struct Signature: Equatable {
        let id: String
        let trackID: String
        let title: String
        let artist: String
        let artworkURL: URL?
        let isPlaying: Bool
        let freshness: DevicePresenceFreshness
        let source: DevicePresenceSource
        let outputID: String?
        let isOutput: Bool
        let updatedAt: Date?
    }

    private static func signature(_ entries: [DevicePresenceEntry]) -> [Signature] {
        entries.map {
            Signature(
                id: $0.id, trackID: $0.trackID, title: $0.title, artist: $0.artist, artworkURL: $0.artworkURL,
                isPlaying: $0.isPlaying, freshness: $0.freshness, source: $0.source, outputID: $0.outputID,
                isOutput: $0.isOutput, updatedAt: $0.source == .companion ? nil : $0.updatedAt
            )
        }
    }

    private func scheduleWake(after moment: Date) {
        wakeTask?.cancel()
        wakeTask = nil
        guard let wake = DevicePresence.nextChange(for: entries, after: moment) else { return }
        let delay = max(1, wake.timeIntervalSince(moment) + 0.5)
        wakeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private var localTrackID: String? {
        #if !os(tvOS)
        if let router, !router.current.isLocal { return router.client.telemetry.playback?.trackId }
        #endif
        return player.currentTrack?.id
    }

    private func liveReports(at moment: Date) -> (reports: [DevicePresenceLiveReport], outputs: [DevicePresenceOutput], currentOutputID: String?) {
        #if os(tvOS)
        return ([], [], nil)
        #else
        guard let router else { return ([], [], nil) }
        let outputs = router.linkedDevices.map {
            DevicePresenceOutput(id: $0.id, name: $0.name, deviceClass: $0.deviceClass)
        }
        let currentOutputID = router.current.isLocal ? nil : router.current.id
        let client = router.client
        guard client.isReachable, client.telemetry.isLive, let device = client.linkedOutputDevice,
              PresenceAccountFilter.keeps(
                isOutput: device.id == currentOutputID,
                tv: device.linkSessionId.map(client.tvAccount(for:)) ?? .unknown,
                mine: CompanionClient.myAccount
              ) else {
            liveStart = nil
            return ([], outputs, currentOutputID)
        }
        let playback = client.telemetry.playback
        let trackID = playback?.trackId
        let key = "\(device.id)|\(trackID ?? "")"
        if playback?.isPlaying == true {
            if liveStart?.key != key { liveStart = (key, moment) }
        } else if liveStart?.key != key {
            liveStart = nil
        }
        let report = DevicePresenceLiveReport(
            outputID: device.id,
            deviceName: device.name,
            deviceClass: device.deviceClass,
            trackID: trackID,
            title: playback?.title ?? "",
            artist: playback?.artist ?? "",
            artworkURL: playback?.artworkURL.flatMap(URL.init(string:)),
            isPlaying: playback?.isPlaying == true,
            position: client.telemetry.estimatedPosition(at: moment),
            duration: playback?.durationSeconds ?? 0,
            receivedAt: client.telemetry.anchorDate ?? moment,
            startedAt: liveStart?.at ?? moment
        )
        return ([report], outputs, currentOutputID)
        #endif
    }

    // MARK: - Actions

    func actions(for entry: DevicePresenceEntry) -> [Action] {
        var actions: [Action] = []
        #if !os(tvOS)
        if let router, let outputID = entry.outputID, !entry.isOutput,
           let device = router.linkedDevices.first(where: { $0.id == outputID }),
           router.isReachable(device) {
            actions.append(.control)
            if router.current.isLocal, let track = player.currentTrack, !track.isLocal {
                actions.append(.playOn)
            }
        }
        #endif
        if canPlayHere(entry) { actions.append(.playHere) }
        return actions
    }

    private func canPlayHere(_ entry: DevicePresenceEntry) -> Bool {
        guard !entry.trackID.isEmpty else { return false }
        if entry.isOutput { return true }
        if sessions[entry.id] != nil { return true }
        #if !os(tvOS)
        return entry.source == .companion
        #else
        return false
        #endif
    }

    func title(for action: Action, entry: DevicePresenceEntry) -> String {
        switch action {
        case .control: return "Control \(entry.displayName)"
        case .playOn: return "Play on \(entry.displayName)"
        case .playHere: return "Play Here"
        }
    }

    func symbol(for action: Action, entry: DevicePresenceEntry) -> String {
        switch action {
        case .control: return "av.remote"
        case .playOn: return "airplay.audio"
        case .playHere: return DeviceClass.current.symbolName
        }
    }

    func perform(_ action: Action, on entry: DevicePresenceEntry) {
        guard busyEntryID == nil else { return }
        busyEntryID = entry.id
        Task { @MainActor [weak self] in
            guard let self else { return }
            let problem = await self.run(action, on: entry)
            self.busyEntryID = nil
            if let problem { self.failure = problem }
            self.scheduleRefresh()
        }
    }

    private func run(_ action: Action, on entry: DevicePresenceEntry) async -> String? {
        switch action {
        case .control:
            #if os(tvOS)
            return nil
            #else
            guard let device = outputDevice(for: entry) else { return "\(entry.displayName) isn\u{2019}t linked to this \(DeviceClass.current.displayName)." }
            return await router?.control(device)
            #endif
        case .playOn:
            #if os(tvOS)
            return nil
            #else
            guard let device = outputDevice(for: entry) else { return "\(entry.displayName) isn\u{2019}t linked to this \(DeviceClass.current.displayName)." }
            return await router?.send(to: device)
            #endif
        case .playHere:
            return await playHere(entry)
        }
    }

    #if !os(tvOS)
    private func outputDevice(for entry: DevicePresenceEntry) -> OutputDevice? {
        guard let router, let outputID = entry.outputID else { return nil }
        return router.linkedDevices.first { $0.id == outputID }
    }
    #endif

    private func playHere(_ entry: DevicePresenceEntry) async -> String? {
        let moment = now()
        #if !os(tvOS)
        if let router {
            if entry.isOutput, !router.current.isLocal {
                return await router.move(to: .thisDevice)
            }
            if entry.source == .companion, entry.outputID == router.client.linkedOutputDevice?.id,
               let session = liveSession(for: entry, client: router.client, at: moment) {
                let position = router.client.telemetry.estimatedPosition(at: moment)
                if router.client.telemetry.isPlaying { router.client.pause() }
                continueFrom.load(session, position: position, play: true)
                return nil
            }
        }
        #endif
        guard let session = sessions[entry.id] else { return nil }
        continueFrom.load(session, position: session.position(at: moment), play: true)
        return nil
    }

    #if !os(tvOS)
    private func liveSession(for entry: DevicePresenceEntry, client: CompanionClient, at moment: Date) -> ContinueSession? {
        if let session = sessions[entry.id], session.trackID == entry.trackID { return session }
        let ids = client.tracks.map(\.id)
        let index = ids.firstIndex(of: entry.trackID) ?? 0
        let source = client.queueSource
        return ContinueSession(
            deviceID: entry.id,
            deviceName: entry.deviceName,
            deviceClass: entry.deviceClass,
            account: continueFrom.accountKey ?? "",
            sessionID: UUID().uuidString,
            trackID: entry.trackID,
            title: entry.title,
            artist: entry.artist,
            artworkURL: entry.artworkURL,
            duration: entry.duration,
            position: entry.position,
            queueTrackIDs: ids.isEmpty ? [entry.trackID] : ids,
            queueIndex: index,
            sourceID: source?.id,
            sourceKind: source?.kind.rawValue,
            sourceTitle: source?.title,
            isPlaying: entry.isPlaying,
            updatedAt: moment
        )
    }
    #endif
}
