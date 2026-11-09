import Combine
import Foundation

@MainActor
final class PhonePlaybackCoordinator: ObservableObject {
    private let player = PlayerService.shared
    private let client: CompanionClient
    private let sonos = SonosOutputController.shared
    let output: OutputRouter
    let timeline: NowPlayingTimeline
    private var cancellables = Set<AnyCancellable>()
    private var presentationRefreshTask: Task<Void, Never>?
    private var lastPresentation: PresentationFingerprint?

    private struct PresentationFingerprint: Equatable {
        let output: OutputDevice
        let devices: [OutputDevice]
        let isMoving: Bool
        let trackID: String?
        let title: String?
        let artist: String?
        let artworkURL: String?
        let duration: TimeInterval
        let remoteAnchorPosition: TimeInterval?
        let remoteAnchorDate: Date?
        let isPlaying: Bool
        let isLoading: Bool
        let isAvailable: Bool
        let isDJEngineLive: Bool
        let isRemoteReachable: Bool
        let isRemoteUnreachable: Bool
        let playOnDevice: OutputDevice?
        let failureMessage: String?
        let isShuffleEnabled: Bool
        let repeatMode: RepeatMode
        let canChangePlaybackModes: Bool
        let upNextRevision: [String]
        let queueSource: PlaybackQueueSource?
        let volume: Int?
        let sleepTimer: SleepTimerStatus?
        let outputNotice: String?
    }

    init(client: CompanionClient) {
        self.client = client
        self.output = OutputRouter(client: client)
        self.timeline = NowPlayingTimeline(player: player, client: client, output: output)
        if let fake = Self.debugFakeNowPlayingSnapshot {
            timeline.adoptFixture(position: fake.position, duration: fake.duration, isPlaying: fake.isPlaying)
        }
        PhoneWorkoutEnergy.shared.attach(self)

        player.objectWillChange
            .sink { [weak self] _ in
                self?.schedulePresentationRefresh()
            }
            .store(in: &cancellables)
        player.clock.$duration
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.schedulePresentationRefresh()
            }
            .store(in: &cancellables)
        client.objectWillChange
            .sink { [weak self] _ in
                self?.schedulePresentationRefresh()
            }
            .store(in: &cancellables)
        client.telemetry.objectWillChange
            .sink { [weak self] _ in
                self?.schedulePresentationRefresh()
            }
            .store(in: &cancellables)
        output.objectWillChange
            .sink { [weak self] _ in
                self?.schedulePresentationRefresh()
            }
            .store(in: &cancellables)
        player.$currentTrack
            .map { $0?.id }
            .removeDuplicates()
            .dropFirst()
            .sink { id in
                if id != nil { SoundingTips.noteTrackStarted() }
            }
            .store(in: &cancellables)
        SleepTimer.shared.objectWillChange
            .sink { [weak self] _ in
                self?.schedulePresentationRefresh()
            }
            .store(in: &cancellables)
        sonos.objectWillChange
            .sink { [weak self] _ in
                self?.schedulePresentationRefresh()
            }
            .store(in: &cancellables)

        lastPresentation = presentationFingerprint()
    }

    // MARK: - Output

    var currentOutput: OutputDevice {
        if let forced = Self.debugFakeNowPlayingSource { return forced }
        return output.current
    }

    var outputs: [OutputDevice] {
        #if DEBUG
        if Self.debugFakeNowPlayingSource != nil, ProcessInfo.processInfo.environment["SOUNDING_TV_FAKE_OUTPUTS"] == "1" {
            return [
                .thisDevice,
                .linked(sessionId: "fixture", name: "Living Room", deviceClass: .tv),
                .linked(sessionId: "fixture.mac", name: "MacBook Pro", deviceClass: .mac),
            ]
        }
        #endif
        return output.devices
    }

    var isMovingOutput: Bool { output.isMoving }

    var isRemoteOutput: Bool { !currentOutput.isLocal }

    var linkedOutput: OutputDevice? { output.linkedDevice }

    func isReachable(_ device: OutputDevice) -> Bool {
        #if DEBUG
        if Self.debugFakeNowPlayingSource != nil, ProcessInfo.processInfo.environment["SOUNDING_TV_FAKE_OUTPUTS"] == "1" {
            return true
        }
        #endif
        return output.isReachable(device)
    }

    func availability(of device: OutputDevice) -> OutputAvailability? {
        #if DEBUG
        if Self.debugFakeNowPlayingSource != nil, ProcessInfo.processInfo.environment["SOUNDING_TV_FAKE_OUTPUTS"] == "1" {
            return .available
        }
        #endif
        return output.availability(of: device)
    }

    @discardableResult
    func move(to device: OutputDevice) async -> String? {
        return await output.move(to: device)
    }

    var activeSource: OutputDevice { currentOutput }

    var queueSource: PlaybackQueueSource? {
        #if DEBUG
        if Self.debugFakeNowPlayingSource != nil, VisualFixtures.isEnabled {
            return PlaybackQueueSource(id: nil, kind: .playlist, title: "Late Night Drive")
        }
        #endif
        return currentOutput.isLocal ? player.queueSource : client.queueSource
    }

    var volume: Double? {
        switch volumeRoute {
        case .system: player.volume
        case .linked: client.volume
        case .sonos: sonos.volume
        }
    }

    func setVolume(_ value: Double) {
        switch volumeRoute {
        case .system: player.setVolume(value)
        case .linked: client.setVolume(value)
        case .sonos: sonos.setVolume(value)
        }
    }

    // MARK: - Output volume

    var volumeRoute: OutputVolumeRoute {
        .resolve(sonosActive: sonos.isActive, remoteOutput: isRemoteOutput)
    }

    var remoteVolume: Double? {
        switch volumeRoute {
        case .system: nil
        case .linked: client.volume
        case .sonos: sonos.volume
        }
    }

    var remoteVolumeName: String {
        sonos.activeGroup?.displayName ?? currentOutput.name
    }

    var remoteVolumeSymbol: String {
        if let group = sonos.activeGroup { return group.members.count > 1 ? "hifispeaker.2.fill" : "hifispeaker.fill" }
        return currentOutput.symbolName
    }

    func setRemoteVolume(_ value: Double) {
        switch volumeRoute {
        case .system: break
        case .linked: client.setVolume(value)
        case .sonos: sonos.setVolume(value)
        }
    }

    func beginRemoteVolumeChange() {
        switch volumeRoute {
        case .system: break
        case .linked: client.beginVolumeChange()
        case .sonos: sonos.beginVolumeChange()
        }
    }

    func endRemoteVolumeChange() {
        switch volumeRoute {
        case .system: break
        case .linked: client.endVolumeChange()
        case .sonos: sonos.endVolumeChange()
        }
    }

    func stepRemoteVolume(_ steps: Int) {
        switch volumeRoute {
        case .system: break
        case .linked: client.stepVolume(steps)
        case .sonos: sonos.stepVolume(steps)
        }
    }

    var sleepTimer: SleepTimerStatus? {
        currentOutput.isLocal ? SleepTimer.shared.status : client.sleepTimer
    }

    var offersEndOfMix: Bool {
        SleepTimer.offersEndOfMix(trackID: nowPlaying?.trackId)
    }

    func setSleepTimer(_ mode: SleepTimerMode?) {
        if currentOutput.isLocal {
            if let mode { SleepTimer.shared.start(mode) } else { SleepTimer.shared.cancel() }
        } else {
            client.setSleepTimer(mode)
        }
    }

    var isRemoteUnreachable: Bool {
        guard !currentOutput.isLocal, !output.isRestoring, Self.debugFakeNowPlayingSource == nil else { return false }
        guard case .failed = client.state else { return false }
        return output.availability(of: currentOutput) != .available
    }

    var playOnDevice: OutputDevice? {
        return output.playOnDevice
    }

    var playOnDevices: [OutputDevice] {
        return output.playOnDevices
    }

    func retryRemote() {
        client.retry()
    }

    @discardableResult
    func play(_ track: Track, in context: [Track], on device: OutputDevice) async -> String? {
        return await output.play(track, in: context, on: device)
    }

    // MARK: - Now Playing

    var localNowPlaying: NowPlayingSnapshot? {
        guard let track = player.currentTrack else { return nil }
        return NowPlayingSnapshot(
            source: .thisDevice,
            trackId: track.id,
            title: track.title,
            artist: track.user.displayName,
            artworkURL: track.artworkURL?.absoluteString,
            position: player.currentTime,
            positionDate: player.clock.updatedAt,
            duration: player.duration > 0 ? player.duration : track.duration,
            isPlaying: player.isPlaying,
            isLoading: player.loadingState != .playing && player.loadingState != .idle,
            isDJEngineLive: player.isMixEngineLive,
            failureMessage: player.playbackErrorMessage
        )
    }

    var remoteNowPlaying: NowPlayingSnapshot? {
        guard let playback = client.telemetry.playback, playback.trackId != nil else { return nil }
        let isLive = client.telemetry.isLive
        return NowPlayingSnapshot(
            source: linkedOutput ?? currentOutput,
            trackId: playback.trackId,
            title: playback.title,
            artist: playback.artist,
            artworkURL: playback.artworkURL,
            position: playback.positionSeconds,
            positionDate: client.telemetry.anchorDate ?? .now,
            duration: playback.durationSeconds,
            isPlaying: isLive && playback.isPlaying,
            isLoading: false,
            isDJEngineLive: isLive && playback.isDJEngineLive,
            failureMessage: isLive || !isRemoteUnreachable ? nil : "\(currentOutput.name) isn't reachable",
            isAvailable: isLive
        )
    }

    var currentTrack: Track? {
        #if DEBUG
        if Self.debugFakeNowPlayingSource != nil { return Self.debugFakeTrack(at: Self.debugFakeIndex) }
        #endif
        return currentOutput.isLocal ? player.currentTrack : nil
    }

    var nowPlaying: NowPlayingSnapshot? {
        if let fake = Self.debugFakeNowPlayingSnapshot { return fake }
        return currentOutput.isLocal ? localNowPlaying : remoteNowPlaying
    }

    func continueOffer(from model: ContinueFrom) -> (offer: ContinueFrom.Offer, isLoading: Bool)? {
        guard nowPlaying == nil, currentOutput.isLocal else { return nil }
        if let loading = model.loading { return (offer: loading, isLoading: true) }
        return model.offer.map { (offer: $0, isLoading: false) }
    }

    private func schedulePresentationRefresh() {
        guard presentationRefreshTask == nil else { return }
        presentationRefreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.presentationRefreshTask = nil
            let next = self.presentationFingerprint()
            guard next != self.lastPresentation else { return }
            self.lastPresentation = next
            self.objectWillChange.send()
        }
    }

    private var debugFixtureRevision: [String] {
        #if DEBUG
        if Self.debugFakeNowPlayingSource != nil { return Self.debugFakeQueue.map(\.id) }
        #endif
        return []
    }

    private func presentationFingerprint() -> PresentationFingerprint {
        let snapshot = nowPlaying
        let remote = !currentOutput.isLocal
        return PresentationFingerprint(
            output: currentOutput,
            devices: outputs,
            isMoving: output.isMoving,
            trackID: snapshot?.trackId,
            title: snapshot?.title,
            artist: snapshot?.artist,
            artworkURL: snapshot?.artworkURL,
            duration: snapshot?.duration ?? 0,
            remoteAnchorPosition: remote ? snapshot?.position : nil,
            remoteAnchorDate: remote ? snapshot?.positionDate : nil,
            isPlaying: snapshot?.isPlaying ?? false,
            isLoading: snapshot?.isLoading ?? false,
            isAvailable: snapshot?.isAvailable ?? true,
            isDJEngineLive: snapshot?.isDJEngineLive ?? false,
            isRemoteReachable: client.isReachable,
            isRemoteUnreachable: isRemoteUnreachable,
            playOnDevice: playOnDevice,
            failureMessage: snapshot?.failureMessage,
            isShuffleEnabled: isShuffleEnabled,
            repeatMode: repeatMode,
            canChangePlaybackModes: canChangePlaybackModes,
            upNextRevision: remote ? client.tracks.map(\.id) + [String(client.currentIndex), String(client.playingNextCount)] : debugFixtureRevision,
            queueSource: queueSource,
            volume: volume.map { Int(($0 * 100).rounded()) },
            sleepTimer: sleepTimer,
            outputNotice: output.notice
        )
    }

    // MARK: - Transport

    func play() {
        output.play()
    }

    func pause() {
        output.pause()
    }

    func togglePlayPause() {
        #if DEBUG
        if Self.debugFakeNowPlayingSource != nil {
            Self.debugFakePlaying.toggle()
            advanceFixture(by: 0)
            return
        }
        #endif
        if isRemoteOutput, player.isPlaying {
            pause()
            return
        }
        guard let snapshot = nowPlaying else { return }
        snapshot.showsPauseGlyph ? pause() : play()
    }

    func next() {
        #if DEBUG
        if Self.debugFakeNowPlayingSource != nil {
            advanceFixture(by: 1)
            return
        }
        #endif
        output.next()
    }

    func previous() {
        #if DEBUG
        if Self.debugFakeNowPlayingSource != nil {
            advanceFixture(by: -1)
            return
        }
        #endif
        output.previous()
    }

    var upcomingTrack: Track? { player.upcomingTrack }

    func seek(to seconds: TimeInterval) {
        timeline.noteSeek(to: seconds)
        output.seek(to: seconds)
        #if DEBUG
        NowPlayingSeekProbe.shared.begin(target: seconds, timeline: timeline, player: player)
        #endif
    }

    var isShuffleEnabled: Bool { output.isShuffleEnabled }
    var repeatMode: RepeatMode { output.repeatMode }
    var canChangePlaybackModes: Bool {
        currentOutput == output.current && output.canChangePlaybackModes
    }

    func toggleShuffle() {
        guard canChangePlaybackModes else { return }
        output.toggleShuffle()
    }

    func cycleRepeatMode() {
        guard canChangePlaybackModes else { return }
        output.cycleRepeatMode()
    }

    // MARK: - Queue

    @discardableResult
    func play(_ track: Track, in context: [Track], collectionId: String? = nil) async -> String? {
        return await output.play(track, in: context, collectionId: collectionId)
    }

    @discardableResult
    func play(shuffled tracks: [Track], collectionId: String? = nil) async -> String? {
        return await output.play(shuffled: tracks, collectionId: collectionId)
    }

    func playNext(_ track: Track) {
        output.playNext(track)
    }

    func addToQueue(_ track: Track) {
        output.addToQueue(track)
    }

    func insertIntoQueue(_ tracks: [Track], at index: Int) {
        output.insertIntoQueue(tracks, at: index)
    }

    func moveQueueItem(from source: Int, to destination: Int) {
        #if DEBUG
        if Self.debugFakeNowPlayingSource != nil {
            Self.debugFakeMove(from: source, to: destination)
            schedulePresentationRefresh()
            return
        }
        #endif
        output.moveQueueItem(from: source, to: destination)
    }

    func applyUpNextMove(_ move: QueueReorder.Move, in entries: [UpNextEntry]) {
        guard let base = entries.first?.queueIndex else { return }
        moveQueueItem(from: base + move.from, to: base + move.to)
    }

    func moveUpNextEntry(_ entry: UpNextEntry, up: Bool) {
        let entries = upNextEntries
        guard let offset = entries.firstIndex(where: { $0.id == entry.id }),
              let move = QueueReorder.moveByOne(source: offset, up: up, within: entries.indices) else { return }
        applyUpNextMove(move, in: entries)
    }

    func removeQueueItem(at index: Int) {
        #if DEBUG
        if Self.debugFakeNowPlayingSource != nil {
            Self.debugFakeRemove(at: index)
            schedulePresentationRefresh()
            return
        }
        #endif
        output.removeQueueItem(at: index)
    }

    func playQueueItem(at index: Int) {
        #if DEBUG
        if Self.debugFakeNowPlayingSource != nil { return }
        #endif
        output.jump(to: index)
    }

    struct SkipPreview: Equatable {
        let title: String
        let artist: String
        let artworkURL: String?
        var trackID: String? = nil
    }

    var nextSkipPreview: SkipPreview? {
        #if DEBUG
        if Self.debugFakeNowPlayingSource != nil {
            return Self.debugFakeTrack(at: Self.debugFakeIndex + 1).map(SkipPreview.init(track:))
        }
        #endif
        if currentOutput.isLocal {
            guard !player.queue.isEmpty else { return nil }
            if player.currentIndex < player.queue.count - 1 {
                return SkipPreview(track: player.queue[player.currentIndex + 1])
            }
            if player.repeatMode == .all, let first = player.queue.first {
                return SkipPreview(track: first)
            }
            return nil
        }
        guard client.hasSnapshot,
              client.tracks.indices.contains(client.currentIndex + 1) else { return nil }
        return SkipPreview(track: client.tracks[client.currentIndex + 1])
    }

    var previousSkipPreview: SkipPreview? {
        #if DEBUG
        if Self.debugFakeNowPlayingSource != nil {
            return Self.debugFakeTrack(at: Self.debugFakeIndex - 1).map(SkipPreview.init(track:))
        }
        #endif
        if currentOutput.isLocal {
            guard player.currentTrack != nil, !player.queue.isEmpty else { return nil }
            if player.currentTime > 3 { return currentAsPreview }
            if player.currentIndex > 0 {
                return SkipPreview(track: player.queue[player.currentIndex - 1])
            }
            if player.repeatMode == .all, let last = player.queue.last {
                return SkipPreview(track: last)
            }
            return currentAsPreview
        }
        guard client.hasSnapshot else { return nil }
        if client.telemetry.estimatedPosition() > 3 { return currentAsPreview }
        guard client.tracks.indices.contains(client.currentIndex - 1) else { return currentAsPreview }
        return SkipPreview(track: client.tracks[client.currentIndex - 1])
    }

    private var currentAsPreview: SkipPreview? {
        guard let snapshot = nowPlaying else { return nil }
        return SkipPreview(
            title: snapshot.displayTitle,
            artist: snapshot.displayArtist,
            artworkURL: snapshot.artworkURL,
            trackID: snapshot.trackId
        )
    }

    struct UpNextEntry: Equatable, Identifiable {
        let trackID: String
        let title: String
        let artist: String
        let artworkURL: String?
        let duration: TimeInterval
        var queueIndex: Int? = nil

        var id: String { "\(queueIndex ?? -1)#\(trackID)" }

        var formattedDuration: String {
            let total = max(0, Int(duration.rounded()))
            return String(format: "%d:%02d", total / 60, total % 60)
        }
    }

    var upNextEntries: [UpNextEntry] {
        #if DEBUG
        if Self.debugFakeNowPlayingSource != nil, VisualFixtures.isEnabled {
            return Self.debugFakeQueue.enumerated().map { index, track in
                UpNextEntry(
                    trackID: track.id,
                    title: track.title,
                    artist: track.user.displayName,
                    artworkURL: track.artworkURL?.absoluteString,
                    duration: track.duration,
                    queueIndex: index
                )
            }
        }
        #endif

        if currentOutput.isLocal {
            guard !player.queue.isEmpty else { return [] }
            return player.queue.enumerated().compactMap { index, track in
                guard index > player.currentIndex else { return nil }
                return UpNextEntry(
                    trackID: track.id,
                    title: track.title,
                    artist: track.user.displayName,
                    artworkURL: track.artworkURL?.absoluteString,
                    duration: track.duration,
                    queueIndex: index
                )
            }
        }
        guard client.hasSnapshot else { return [] }
        return client.tracks.enumerated().compactMap { index, track in
            guard index > client.currentIndex else { return nil }
            return UpNextEntry(
                trackID: track.id,
                title: track.title,
                artist: track.artist,
                artworkURL: track.artworkURL?.absoluteString,
                duration: track.duration,
                queueIndex: index
            )
        }
    }

    var upNextPlayingNextCount: Int {
        #if DEBUG
        if Self.debugFakeNowPlayingSource != nil, VisualFixtures.isEnabled {
            return ProcessInfo.processInfo.environment["SOUNDING_TV_FIXTURE_PLAYING_NEXT"].flatMap(Int.init) ?? 0
        }
        #endif
        return currentOutput.isLocal ? player.playingNextCount : client.playingNextCount
    }

    func upNextLayout(count: Int) -> UpNextLayout {
        UpNextLayout.make(
            upcomingCount: count,
            playingNextCount: upNextPlayingNextCount,
            autoMixOn: autoMixLive != nil || djSnapshot.isAutoEnabled
        )
    }

    func autoMixReason(for entry: UpNextEntry) -> String? {
        guard let live = autoMixLive else { return nil }
        guard live.incomingTrackId == entry.trackID || AutoMixLive.shared.isFixture else { return nil }
        return live.why
    }

    func moveUpNextEntryToPlayingNext(_ entry: UpNextEntry) {
        guard let index = entry.queueIndex else { return }
        #if DEBUG
        if Self.debugFakeNowPlayingSource != nil {
            Self.debugFakeMove(from: index, to: 0)
            schedulePresentationRefresh()
            return
        }
        #endif
        if currentOutput.isLocal {
            player.moveToPlayingNext(at: index)
        } else {
            output.moveQueueItem(from: index, to: client.currentIndex + 1)
        }
    }

    // MARK: - DJ

    func setDJEnabled(_ enabled: Bool) {
        if currentOutput.isLocal { player.setDJSessionEnabled(enabled) } else { client.setDJEnabled(enabled) }
    }

    func startDJSession(configuration: DJStartConfiguration, reconfigure: Bool = false) {
        SettingsStore.shared.setDJStartConfiguration(configuration)
        if currentOutput.isLocal {
            player.startDJSession(configuration: configuration, reconfigure: reconfigure)
        } else {
            client.setAutoMixEnabled(true)
            client.setDJEnabled(true)
        }
    }

    func setAutoMixEnabled(_ enabled: Bool) {
        if currentOutput.isLocal { player.setAutomaticMixEnabled(enabled) } else { client.setAutoMixEnabled(enabled) }
    }

    func mixNow() {
        if currentOutput.isLocal { player.startMix() } else { client.mixNow() }
    }

    func extendMix() {
        if currentOutput.isLocal { player.extendMix() } else { client.extendMix() }
    }

    var canExtendMix: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SOUNDING_TV_FAKE_MOVE"] == "1" { return true }
        #endif
        return currentOutput.isLocal ? player.canExtendMix : (client.telemetry.djState?.automaticMix?.canExtend ?? false)
    }

    var canMixNow: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SOUNDING_TV_FAKE_MOVE"] == "1" { return true }
        #endif
        return currentOutput.isLocal ? player.canStartMix : client.telemetry.isDJControlLive
    }

    var nextMoveLine: String? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SOUNDING_TV_FAKE_MOVE"] == "1" { return "Loop build into Glue, 16 bars" }
        #endif
        let decision = currentOutput.isLocal ? player.automaticMixDecision : client.telemetry.djState?.automaticMix
        guard let decision, decision.phase != .off, decision.phase != .unavailable else { return nil }
        return decision.headline
    }

    var autoMixLive: AutoMixLiveState? {
        let live = AutoMixLive.shared
        if live.isFixture || currentOutput.isLocal { return live.state }
        return client.telemetry.autoMixLive
    }

    func skipUpcomingMix(_ state: AutoMixLiveState) {
        guard let id = state.incomingTrackId,
              let index = upNextEntries.first(where: { $0.trackID == id })?.queueIndex else { return }
        removeQueueItem(at: index)
    }

    func sendEnergyTarget(level: Int, heartRate: Double?) {
        guard !currentOutput.isLocal else { return }
        client.sendEnergyTarget(level: level, heartRate: heartRate)
    }

    var djSnapshot: DJSnapshot {
        if currentOutput.isLocal {
            let plan = player.adaptiveMixPlan
            return DJSnapshot(
                isEngineLive: player.isMixEngineLive,
                isAutoEnabled: player.isAutoMixEnabled,
                nextTitle: player.upcomingTrack?.title,
                nextArtist: player.upcomingTrack?.user.displayName,
                nextArtworkURL: player.upcomingTrack?.artworkURL?.absoluteString,
                mixInSeconds: player.plannedMixPointSeconds().map { max(0, $0 - player.currentTime) },
                reasoning: plan == nil ? nil : player.automaticMixDecision.headline
            )
        }
        let decision = client.telemetry.djState?.automaticMix
        let position = client.telemetry.estimatedPosition()
        let mixIn = decision?.mixPointSeconds.map { max(0, $0 - position) }
        return DJSnapshot(
            isEngineLive: client.telemetry.isDJControlLive,
            isAutoEnabled: client.telemetry.djState?.isAutoMixEnabled ?? false,
            nextTitle: nextSkipPreview?.title,
            nextArtist: nextSkipPreview?.artist,
            nextArtworkURL: nextSkipPreview?.artworkURL,
            mixInSeconds: mixIn,
            reasoning: decision?.headline
        )
    }

    struct DJSnapshot: Equatable {
        let isEngineLive: Bool
        let isAutoEnabled: Bool
        let nextTitle: String?
        let nextArtist: String?
        let nextArtworkURL: String?
        let mixInSeconds: TimeInterval?
        let reasoning: String?
    }

    // MARK: - Debug fixtures

    private static let debugFakeNowPlayingSource: OutputDevice? = {
        #if DEBUG
        if RemoteFixture.current != nil, ProcessInfo.processInfo.environment["SOUNDING_TV_REMOTE_OUTPUT"] == "1" {
            return nil
        }
        switch ProcessInfo.processInfo.environment["SOUNDING_TV_FAKE_NOWPLAYING"] {
        case "1":       return .thisDevice
        case "appletv": return .linked(sessionId: "fixture", name: "Living Room", deviceClass: .tv)
        default:        return VisualFixtures.isEnabled ? .thisDevice : nil
        }
        #else
        return nil
        #endif
    }()

    #if DEBUG
    private static let debugFakePosition = ProcessInfo.processInfo.environment["SOUNDING_TV_FAKE_POSITION"].flatMap(Double.init)
    private static let debugFakeHidesArtwork = ProcessInfo.processInfo.environment["SOUNDING_TV_FAKE_ARTWORK"] == "none"
    private static var debugFakeQueue = Array(VisualFixtures.tracks.prefix(8))

    private static func debugFakeMove(from source: Int, to destination: Int) {
        guard debugFakeQueue.indices.contains(source) else { return }
        let target = max(0, min(destination, debugFakeQueue.count - 1))
        debugFakeQueue.insert(debugFakeQueue.remove(at: source), at: target)
    }

    private static func debugFakeRemove(at index: Int) {
        guard debugFakeQueue.indices.contains(index) else { return }
        debugFakeQueue.remove(at: index)
    }

    private static var debugFakeIndex = ProcessInfo.processInfo.environment["SOUNDING_TV_FAKE_INDEX"].flatMap(Int.init) ?? 0
    private static var debugFakePlaying = ProcessInfo.processInfo.environment["SOUNDING_TV_FAKE_PAUSED"] != "1"

    private static func debugFakeTrack(at index: Int) -> Track? {
        if ProcessInfo.processInfo.environment["SOUNDING_TV_FAKE_DEVICE_TRACK"] == "1",
           let local = LocalMusicLibrary.shared.allTracks.first {
            return local
        }
        let tracks = [VisualFixtures.nowPlayingMix] + VisualFixtures.tracks
        guard tracks.indices.contains(index) else { return nil }
        return tracks[index]
    }

    private func advanceFixture(by delta: Int) {
        guard let track = Self.debugFakeTrack(at: Self.debugFakeIndex + delta) else { return }
        let position = delta == 0 ? timeline.anchor.position(at: .now) : 0
        Self.debugFakeIndex += delta
        timeline.adoptFixture(position: position, duration: track.duration, isPlaying: Self.debugFakePlaying)
        schedulePresentationRefresh()
    }
    #endif

    private static var debugFakeNowPlayingSnapshot: NowPlayingSnapshot? {
        guard let source = debugFakeNowPlayingSource else { return nil }
        #if DEBUG
        let track = debugFakeTrack(at: debugFakeIndex) ?? VisualFixtures.nowPlayingMix
        let position = debugFakePosition ?? (debugFakeIndex == 0 ? 97 : 0)
        return NowPlayingSnapshot(
            source: source,
            trackId: track.id,
            title: track.title,
            artist: track.user.displayName,
            artworkURL: debugFakeHidesArtwork ? nil : track.artworkURL?.absoluteString,
            position: position,
            duration: track.duration,
            isPlaying: debugFakePlaying,
            isLoading: false,
            isDJEngineLive: false
        )
        #else
        return nil
        #endif
    }
}

struct NowPlayingSnapshot: Equatable {
    let source: OutputDevice
    let trackId: String?
    let title: String?
    let artist: String?
    let artworkURL: String?
    let position: TimeInterval
    var positionDate: Date = .distantPast
    let duration: TimeInterval
    let isPlaying: Bool
    let isLoading: Bool
    let isDJEngineLive: Bool
    var failureMessage: String? = nil
    var isAvailable: Bool = true

    var showsPauseGlyph: Bool { isPlaying || isLoading }

    var isDeviceTrack: Bool { trackId.map(LocalTrackFile.isLocalTrackID) ?? false }

    var displayTitle: String { title ?? "Unknown Track" }
    var displayArtist: String { artist ?? "Unknown Artist" }

    func estimatedPosition(at date: Date = .now) -> TimeInterval {
        guard isPlaying, positionDate != .distantPast else { return position }
        let advanced = position + max(0, date.timeIntervalSince(positionDate))
        return duration > 0 ? min(duration, advanced) : advanced
    }
}

extension PhonePlaybackCoordinator.SkipPreview {
    init(track: Track) {
        self.init(
            title: track.title,
            artist: track.user.displayName,
            artworkURL: track.artworkURL?.absoluteString,
            trackID: track.id
        )
    }

    init(track: QueueTrack) {
        self.init(
            title: track.title,
            artist: track.artist,
            artworkURL: track.artworkURL?.absoluteString,
            trackID: track.id
        )
    }
}

extension PhonePlaybackCoordinator: IntentPlaybackSink {}
