import Foundation
import AVFoundation
import Observation
import Combine
import Accelerate
import MusicUnderstanding
import Network
import os

@MainActor
protocol PlatformLifecycleObserver: AnyObject {
    func observeWillResignActive(handler: @escaping @MainActor () -> Void) -> AnyCancellable
}


enum IncomingDeckState: Equatable {
    case idle
    case loading(Double)
    case ready
    case failed(String)

    var isReady: Bool { self == .ready }
}

/// A tiny cache of already-resolved CDN endpoints. It deliberately lives
/// outside DownloadManager: an exhausted offline-download allowance must not
/// turn a normal stream into a fresh API round-trip every time the app opens.
/// The audio itself remains AVFoundation-managed and is never counted against
/// the user's offline-download budget.
private enum StreamResolutionDiskCache {
    private struct Entry: Codable {
        let url: URL
        let fetchedAt: Date
    }

    private static let defaultsKey = "red.forbes.sounding.streaming.resolvedURLs.v1"
    private static let maximumEntries = 24
    private static let ttl: TimeInterval = 240

    static func url(for key: String) -> URL? {
        var entries = load()
        let now = Date()
        entries = entries.filter { now.timeIntervalSince($0.value.fetchedAt) < ttl }
        persist(entries)
        return entries[key]?.url
    }

    static func store(_ url: URL, for key: String) {
        var entries = load()
        entries[key] = Entry(url: url, fetchedAt: Date())
        if entries.count > maximumEntries {
            for key in entries.sorted(by: { $0.value.fetchedAt < $1.value.fetchedAt })
                .prefix(entries.count - maximumEntries).map(\.key) {
                entries[key] = nil
            }
        }
        persist(entries)
    }

    private static func load() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        return entries
    }

    private static func persist(_ entries: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

struct MixWindow: Equatable {
    var start: TimeInterval
    var seconds: TimeInterval
    var isLive: Bool
    var progress: Double = 0

    var end: TimeInterval { start + seconds }
}


struct AudioOutputRoute: Equatable {
    var outputName: String? = nil
    var outputKind: AudioOutputKind = .unknown
    var supportsMultichannel: Bool = false
    var maximumOutputChannels: Int = 2

    static let unknown = AudioOutputRoute()
}


@MainActor
final class PlayerService: ObservableObject, DJTransitionServiceDelegate {
    static let shared = PlayerService()

    static var remoteOutput: (any CompanionOutputTarget)?

    static var peerContentSource: (any PeerContentSessionProvider)?

    static private(set) var nowPlaying: any SystemNowPlayingBridge = MediaPlayerNowPlayingBridge()

    private static weak var activeInstance: PlayerService?

    static weak var lifecycleObserver: (any PlatformLifecycleObserver)? {
        didSet { activeInstance?.observeAppLifecycle() }
    }

    static func installNowPlaying(_ bridge: any SystemNowPlayingBridge) {
        guard bridge !== nowPlaying else { return }
        nowPlaying.deactivate()
        nowPlaying = bridge
        activeInstance?.activateNowPlayingBridge()
    }

    @Published private(set) var currentTrack: Track?
    @Published private(set) var queue: [Track] = [] {
        didSet {
            refreshStreamPrefetch()
            notifyDownloadManagerOfQueueChange()
            persistSessionState(force: true)
        }
    }
    @Published private(set) var currentIndex: Int = 0 {
        didSet {
            refreshStreamPrefetch()
            notifyDownloadManagerOfQueueChange()
            persistSessionState(force: true)
        }
    }
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isLoading = false
    @Published private(set) var loadingState: PlaybackLoadingState = .idle
    /// Increments only for a user-selected track, never for automatic queue
    /// advancement. Shells use this to present Now Playing at the right time.
    @Published private(set) var explicitPlayRequest: UInt64 = 0
    @Published var isShuffleEnabled = false {
        didSet { persistSessionState(force: true) }
    }
    @Published var repeatMode: RepeatMode = .off {
        didSet {
            refreshStreamPrefetch()
            notifyDownloadManagerOfQueueChange()
            persistSessionState(force: true)
        }
    }
    @Published private(set) var outputTarget: PlaybackOutput = .thisDevice
    @Published private(set) var outputRoute: AudioOutputRoute = .unknown
    @Published private(set) var activeCollectionId: String?

    @Published private(set) var mixEngineState: MixEngineState = .off
    @Published private(set) var incomingDeck: IncomingDeckState = .idle
    @Published private(set) var mixWindow: MixWindow?
    @Published private(set) var isAutoMixEnabled = true
    @Published private(set) var isExternalManualDeckControlActive = false

    @Published var djProfile: DJProfile? {
        didSet {
            guard djProfile != oldValue else { return }
            for task in phantomPlanTasks.values { task.cancel() }
            phantomPlanTasks.removeAll()
            phantomPlanCache.removeAll()
            if djProfile != nil {
                refreshPhantomPlan()
            } else {
                phantomActivity = .idle
            }
        }
    }

    var isPhantomEnabled: Bool {
        get { djProfile != nil }
        set { djProfile = newValue ? (djProfile ?? defaultDJProfile) : nil }
    }
    @Published private(set) var phantomActivity: PhantomActivity = .idle

    @Published private(set) var liveDeck: MixEngine.Deck = .a

    var isMixEngineLive: Bool { mixEngineState == .live }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }

    func localAudioURL(for track: Track) -> URL? {
        if let downloaded = DownloadManager.shared.localFileURL(for: track) { return downloaded }
        for deck in MixEngine.Deck.allCases where MixEngine.shared[deck].trackId == track.id {
            if let url = MixEngine.shared.localFileURL(for: deck) { return url }
        }
        return nil
    }

    private var externalManualResume: (track: Track, position: TimeInterval, wasPlaying: Bool)?

    /// Gives a full manual console exclusive ownership of the audio engine.
    /// This prevents the background director and a human from writing the
    /// same fader/EQ graph at once, without changing the user's synced Auto
    /// Mix preference.
    func beginExternalManualDeckControl() {
        guard !isExternalManualDeckControlActive else { return }
        if let currentTrack {
            externalManualResume = (currentTrack, currentTime, isPlaying)
        }
        isExternalManualDeckControlActive = true
        isAutoMixEnabled = false
        endMixSession()
        teardownAVPlayer()
        isPlaying = false
        isLoading = false
        loadingState = .idle
    }

    /// Restores the ordinary queue after the manual console releases the
    /// engine. Auto Mix resumes only if its existing setting or collection
    /// policy calls for it.
    func endExternalManualDeckControl() {
        guard isExternalManualDeckControlActive else { return }
        let resume = externalManualResume
        externalManualResume = nil
        isExternalManualDeckControlActive = false
        MixEngine.shared.stop()
        syncIsAutoMixEnabledFromSetting(autoMixSettingEnabled)

        guard let resume else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadAndPlay(track: resume.track)
            self.seek(to: resume.position)
            if !resume.wasPlaying { self.pause() }
        }
    }

    private var player: AVPlayer?
    private var synchronizationRateTask: Task<Void, Never>?

    @Published private(set) var observedStalls = 0
    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()
    private var originalQueue: [Track] = []
    private var activeDJStartConfiguration: DJStartConfiguration?
    private var goodMatchDiscoveryTask: Task<Void, Never>?

    private var loadGeneration = 0

    private var peerContentClient: PeerContentClient?
    private var peerContentDelegate: PeerContentAssetLoaderDelegate?

    private var prefetchedStreams: [String: (url: URL, fetchedAt: Date)] = [:]
    private var prefetchingTrackIds: Set<String> = []
    private var prefetchTasks: [String: Task<Void, Never>] = [:]
    private static let prefetchTTLSeconds: TimeInterval = 300
    private static let prefetchLookahead = 2

    /// Warm standby items for the next upcoming tracks. Each sits paused in
    /// its own player so AVFoundation opens the CDN connection and buffers a
    /// little before the track is ever played.
    private struct StandbyItem {
        let asset: AVURLAsset
        let item: AVPlayerItem
        let player: AVPlayer
    }
    private var standbyItems: [String: StandbyItem] = [:]
    private static let standbyLimit = 2

    /// Whether the current network path is good enough for speculative work
    /// (WiFi/Ethernet, or cellular without Low Data Mode). `isExpensive` is
    /// deliberately ignored so good cellular still counts. Warm-up is assumed
    /// fine until the first path update says otherwise.
    private var isOnGoodNetwork = true
    private nonisolated(unsafe) var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "red.forbes.sounding.playerservice.path")
    private var warmDebounceTask: Task<Void, Never>?

    /// Stall circuit breaker: after a playback stall, aggressive warm-up
    /// (standby players, start-on-first-buffer) is suspended until this
    /// timestamp. Pure timestamp comparison — it resets itself.
    private var stallCircuitOpenUntil: Date?

    /// Whether speculative byte-buffering work is allowed right now: the
    /// network path is good and no recent stall has tripped the breaker.
    private var canWarmAggressively: Bool {
        isOnGoodNetwork && stallCircuitOpenUntil.map { Date() < $0 } != true
    }

    private var djModeRequested = false
    private var autoMixSettingEnabled = false
    private var collectionAutoMixRequested = false
    private var activeCollectionPolicy: CollectionPolicy?
    private var djSessionEnabled: Bool { djModeRequested || autoMixSettingEnabled || collectionAutoMixRequested }
    private var mixEngineTouched = false
    private var armedTrackId: String?
    private var armingTrackId: String?
    private var incomingTrackId: String?
    private var armTask: Task<Void, Never>?
    private var incomingTask: Task<Void, Never>?
    private var mixTask: Task<Void, Never>?
    private var transitionStageTasks: [Task<Void, Never>] = []
    private var mixEngineObserver: AnyCancellable?
    private var mixEngineErrorObserver: AnyCancellable?
    private var isCrossfading = false
    private var deckEndHandled = false
    private var lastNowPlayingSecond = -1
    private var lastMixEngineTransportUpdate = Date.distantPast
    private static let mixEngineTransportUpdateInterval: TimeInterval = 0.5

    private var sessionCancellables = Set<AnyCancellable>()
    private var lifecycleCancellable: AnyCancellable?
    private var wasPlayingBeforeInterruption = false

    private var phantomPlanCache: [String: PhantomDJEngine.Plan] = [:]
    private var phantomPlanTasks: [String: Task<Void, Never>] = [:]
    private var phantomCutAnnounced = false
    private var recentTemplates: [TransitionTemplateID] = []
    private var lastPlannerAnalysisStates: [String: AnalysisState] = [:]
    private static let transitionSchedulingLead: TimeInterval = 0.8

    private var isRestoringSession = false
    private var lastPersistedAt: Date = .distantPast
    private var pendingRestore: (track: Track, position: TimeInterval)?
    private var restoreTask: Task<Void, Never>?
    private var defaultDJSourceTask: Task<Void, Never>?

    private init() {
        #if DEBUG
        setvbuf(stdout, nil, _IONBF, 0)
        #endif
        DJTransitionService.shared.delegate = self
        setupAudioSession()
        Self.activeInstance = self
        activateNowPlayingBridge()
        observeAudioSessionNotifications()
        observeAppLifecycle()
        observeAuthenticatedAccount()
        observeAutoMixSetting()
        observeDJAnalysisForPlanning()
        startPathMonitor()
        #if DEBUG
        installAutoplayDebugHook()
        #endif
    }

    deinit {
        pathMonitor?.cancel()
    }

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let isGood = path.status == .satisfied && !path.isConstrained
            Task { @MainActor in
                guard let self else { return }
                let wasGood = self.isOnGoodNetwork
                self.isOnGoodNetwork = isGood
                if wasGood, !isGood {
                    // Standby players hold buffered bytes and CDN connections
                    // we no longer want on a constrained path.
                    self.standbyItems.removeAll()
                }
            }
        }
        pathMonitor = monitor
        monitor.start(queue: pathMonitorQueue)
    }

    private func setupAudioSession() {
        PlatformAudioSession.activatePlayback()
        refreshOutputRoute()
    }

    private func refreshOutputRoute() {
        PlatformAudioSession.refreshRoute()
        outputRoute = AudioOutputRoute(
            outputName: PlatformAudioSession.outputName,
            outputKind: PlatformAudioSession.outputKind,
            supportsMultichannel: PlatformAudioSession.supportsMultichannel,
            maximumOutputChannels: PlatformAudioSession.maximumOutputChannels
        )
    }

    private func observeAudioSessionNotifications() {
        #if canImport(UIKit)
        if #available(iOS 27.0, tvOS 27.0, *) {
            NotificationCenter.default.publisher(for: AVAudioSession.didBecomeInactiveNotification)
                .sink { [weak self] note in self?.handleSessionDidBecomeInactive(note) }
                .store(in: &sessionCancellables)
            NotificationCenter.default.publisher(for: AVAudioSession.resumptionRecommendationNotification)
                .sink { [weak self] note in self?.handleResumptionRecommendation(note) }
                .store(in: &sessionCancellables)
        } else {
            NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)
                .sink { [weak self] note in self?.handleLegacyInterruption(note) }
                .store(in: &sessionCancellables)
        }
        #endif

        NotificationCenter.default.publisher(for: .audioOutputRouteDidChange)
            .sink { [weak self] note in self?.handleRouteChange(note) }
            .store(in: &sessionCancellables)
    }

    #if canImport(UIKit)
    @available(iOS 27.0, tvOS 27.0, *)
    private func handleSessionDidBecomeInactive(_ note: Notification) {
        guard let context = note.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext,
              context.source == .system else { return }
        wasPlayingBeforeInterruption = isPlaying
        pause()
    }

    @available(iOS 27.0, tvOS 27.0, *)
    private func handleResumptionRecommendation(_ note: Notification) {
        let shouldResume = wasPlayingBeforeInterruption
        wasPlayingBeforeInterruption = false
        guard shouldResume else { return }
        guard let context = note.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext,
              context.recommendation == .shouldResume else { return }
        PlatformAudioSession.activatePlayback()
        play()
    }

    private func handleLegacyInterruption(_ note: Notification) {
        guard let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            pause()
        case .ended:
            let shouldResume = wasPlayingBeforeInterruption
            wasPlayingBeforeInterruption = false
            guard shouldResume else { return }
            let options: AVAudioSession.InterruptionOptions = {
                if let raw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt {
                    return AVAudioSession.InterruptionOptions(rawValue: raw)
                }
                return []
            }()
            guard options.contains(.shouldResume) else { return }
            PlatformAudioSession.activatePlayback()
            play()
        @unknown default:
            break
        }
    }
    #endif

    private func handleRouteChange(_ note: Notification) {
        refreshOutputRoute()

        #if canImport(UIKit)
        guard let info = (note.object as? Notification)?.userInfo ?? note.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        guard reason == .oldDeviceUnavailable else { return }
        pause()
        #else
        #endif
    }

    private func observeAppLifecycle() {
        lifecycleCancellable?.cancel()
        lifecycleCancellable = nil
        guard let observer = Self.lifecycleObserver else { return }
        lifecycleCancellable = observer.observeWillResignActive { [weak self] in
            self?.persistSessionState(force: true)
        }
    }

    private func activateNowPlayingBridge() {
        #if DEBUG
        print("[NowPlaying] activating bridge: \(type(of: Self.nowPlaying))")
        #endif
        Self.nowPlaying.activate(handlers: SystemTransportHandlers(
            play: { [weak self] in self?.play() },
            pause: { [weak self] in self?.pause() },
            togglePlayPause: { [weak self] in self?.togglePlayPause() },
            next: { [weak self] in await self?.playNext() },
            previous: { [weak self] in await self?.playPrevious() },
            seek: { [weak self] time in self?.seek(to: time) }
        ))
        updateNowPlayingMetadata()
    }

    private func updateNowPlayingMetadata() {
        guard let track = currentTrack else {
            Self.nowPlaying.publishNowPlaying(nil)
            return
        }

        let hasQueuePosition = currentIndex >= 0 && currentIndex < queue.count
        Self.nowPlaying.publishNowPlaying(SystemNowPlayingItem(
            trackId: track.id,
            title: track.title,
            artist: track.user.displayName,
            artworkURL: track.artworkURL,
            queueIndex: hasQueuePosition ? currentIndex : nil,
            queueCount: hasQueuePosition ? queue.count : nil
        ))
        updateNowPlayingProgress()
    }

    private func updateNowPlayingProgress() {
        Self.nowPlaying.publishPlayback(SystemPlaybackStatus(
            elapsed: currentTime,
            duration: duration,
            isPlaying: isPlaying
        ))
    }

    #if DEBUG
    private func installAutoplayDebugHook() {
        let env = ProcessInfo.processInfo.environment
        guard env["SOUNDING_TV_AUTOPLAY"] == "1",
              let host = env["SOUNDING_TV_STREAM_HOST"],
              let catalogURL = URL(string: "\(host)/catalog") else { return }
        print("[Autoplay] fetching mock catalog from \(host)")
        Task { @MainActor [weak self] in
            do {
                let (data, _) = try await URLSession.shared.data(from: catalogURL)
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
                formatter.timeZone = TimeZone(identifier: "UTC")
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .formatted(formatter)
                let tracks = try decoder.decode([Track].self, from: data)
                guard let self, let first = tracks.first else { return }
                await self.play(first, in: tracks)
                guard let raw = env["SOUNDING_TV_AUTOCLEAR"], let seconds = TimeInterval(raw) else { return }
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                self.clearQueue()
            } catch {
                print("[Autoplay] mock catalog fetch failed: \(error)")
            }
        }
    }
    #endif

    func play(_ track: Track, in context: [Track], collectionId: String? = nil) async {
        explicitPlayRequest &+= 1
        applyCollectionPolicyForPlayback(collectionId: collectionId, tracks: context)

        var tracks = filteredDJContext(context, preserving: track)
        let index: Int
        if let existing = tracks.firstIndex(of: track) {
            index = existing
        } else {
            tracks.insert(track, at: 0)
            index = 0
        }

        originalQueue = tracks

        if isShuffleEnabled {
            var shuffled = tracks
            shuffled.remove(at: index)
            shuffled.shuffle()
            shuffled.insert(track, at: 0)
            queue = shuffled
            currentIndex = 0
        } else {
            queue = tracks
            currentIndex = index
        }

        await loadAndPlay(track: track)
        if activeDJStartConfiguration?.sourceStrategy == .goodMatches, djSessionEnabled {
            discoverGoodMatchesIfNeeded()
        }
    }

    private func applyCollectionPolicyForPlayback(collectionId: String?, tracks: [Track]) {
        let wasEnabled = djSessionEnabled
        activeCollectionId = collectionId
        activeCollectionPolicy = collectionId.map { CollectionQualityOverrideStore.shared.policy(for: $0) }
        let policy = activeCollectionPolicy ?? .standard

        collectionAutoMixRequested = policy.djMode != .normal
        if collectionAutoMixRequested {
            let base = DJProfile.profile(id: policy.djProfileId) ?? .automaticDJ
            djProfile = base.applying(collectionPolicy: policy)
            isAutoMixEnabled = true
        } else {
            syncIsAutoMixEnabledFromSetting(autoMixSettingEnabled)
            if !djModeRequested, !autoMixSettingEnabled { djProfile = nil }
        }

        applySessionEnabledTransition(from: wasEnabled, primeAnalysis: collectionAutoMixRequested)
        if let collectionId {
            DownloadManager.shared.applyCollectionPolicy(tracks: tracks, collectionId: collectionId)
        }
    }

    private func filteredDJContext(_ context: [Track], preserving selected: Track) -> [Track] {
        let setHandling: DJSetHandling?
        if let configuration = activeDJStartConfiguration {
            setHandling = configuration.setHandling
        } else if collectionAutoMixRequested, let policy = activeCollectionPolicy {
            setHandling = policy.setHandling
        } else {
            setHandling = nil
        }
        guard let setHandling else { return context }
        let eligible: (Track) -> Bool = { track in
            let isSet = CollectionKind.classify(trackDurationSeconds: track.duration) == .set
            switch setHandling {
            case .include:  return true
            case .skip:     return !isSet
            case .onlySets: return isSet
            }
        }
        var filtered = context.filter(eligible)
        if !filtered.contains(selected) { filtered.insert(selected, at: 0) }
        return filtered
    }

    private func loadAndPlay(track: Track, startPosition: TimeInterval = 0) async {
        endMixSession()

        // If a pending restore exists for the same track, use its latest
        // position (which may have been updated by seek(to:) after play() was
        // called) and then consume it.
        let resolvedStartPosition = if let pending = pendingRestore, pending.track.id == track.id {
            pending.position
        } else {
            startPosition
        }
        pendingRestore = nil

        loadGeneration &+= 1
        let issued = loadGeneration

        isLoading = true
        currentTrack = track
        duration = track.duration

        if activeCollectionPolicy?.resolvedIntelligence != .off {
            Self.scheduleTier1Analysis(for: track)
        }
        applyLoudnessNormalization(for: track)
        DownloadManager.shared.markPlayed(trackId: track.id)

        teardownPeerContent()

        // A completed local download starts instantly and needs no stream
        // resolution, so prefer it over peer content and network streaming.
        if let localURL = DownloadManager.shared.localFileURL(for: track) {
            await playStream(asset: AVURLAsset(url: localURL), startPosition: resolvedStartPosition)
            return
        }

        if let peer = await tryPeerContent(for: track) {
            guard issued == loadGeneration else {
                teardownPeerContent()
                return
            }
            peerContentClient = peer.client
            peerContentDelegate = peer.delegate
            await playStream(asset: peer.asset, startPosition: resolvedStartPosition)
            return
        }

        do {
            let prefetched = consumePrefetchedStreamURL(for: track)
            let streamURL: URL
            if let prefetched {
                streamURL = prefetched
            } else {
                loadingState = .resolvingStream
                streamURL = try await Self.resolveStreamURL(for: track, collectionId: activeCollectionId)
            }
            guard issued == loadGeneration else { return }
            // Only reuse a standby warmed from the URL we will actually play;
            // a standby built from a stale URL is worse than a fresh asset.
            let standby = consumeStandbyItem(for: track, matching: streamURL)
            if let standby {
                await playStream(asset: standby.asset, startPosition: resolvedStartPosition, preparedItem: standby.item)
            } else {
                await playStream(asset: AVURLAsset(url: streamURL), startPosition: resolvedStartPosition)
            }
        } catch {
            guard issued == loadGeneration else { return }
            if !Self.isCancellation(error) {
                Log.player.error("Failed to get stream URL: \(error.localizedDescription, privacy: .public)")
            }
            teardownAVPlayer()
            teardownPeerContent()
            isLoading = false
            loadingState = .idle
        }
    }

    static func resolveStreamURL(for track: Track, collectionId: String? = nil) async throws -> URL {
        let transcoding = streamingTranscoding(for: track, collectionId: collectionId)
        let cacheKey = "\(track.id)|\(transcoding?.url.absoluteString ?? track.streamURL?.absoluteString ?? "default")"
        if let cached = StreamResolutionDiskCache.url(for: cacheKey) { return cached }

        let resolved = try await SoundCloudAPI.shared.getStreamURL(for: track, transcoding: transcoding)
        StreamResolutionDiskCache.store(resolved, for: cacheKey)
        return resolved
    }

    static func streamingTranscoding(for track: Track, collectionId: String? = nil) -> Transcoding? {
        let ceiling = CollectionQualityOverrideStore.shared.effectiveCeiling(
            for: collectionId ?? track.id,
            default: SettingsStore.shared.streamingQualityCeiling
        )
        return ceiling.bestTranscoding(among: track.transcodings)
    }

    private func tryPeerContent(
        for track: Track
    ) async -> (asset: AVURLAsset, client: PeerContentClient, delegate: PeerContentAssetLoaderDelegate)? {
        guard let provider = Self.peerContentSource,
              let (endpoint, sessionId, secret) = provider.peerContentEndpoint else { return nil }
        guard let source = DownloadSourceSelection.choose(from: track.transcodings) else { return nil }

        let client = PeerContentClient()

        let connected = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            // Remote-library playback is an opportunistic fast path. It must
            // never make the normal streaming path feel broken when a paired
            // device has gone to sleep or moved off the local network.
            client.connect(to: endpoint, sessionId: sessionId, secret: secret, timeout: 0.45) { result in
                continuation.resume(returning: (try? result.get()) != nil)
            }
        }
        guard connected else { return nil }

        let probe = await withCheckedContinuation {
            (continuation: CheckedContinuation<Result<(data: Data, totalLength: Int64), PeerContentError>, Never>) in
            client.fetchRange(trackId: track.id, offset: 0, length: 0, timeout: 0.35) { result in
                continuation.resume(returning: result)
            }
        }
        guard case .success = probe else {
            client.disconnect()
            return nil
        }

        let contentType = PeerContentAssetLoaderDelegate.contentType(
            forFileExtension: DownloadSourceSelection.fileExtension(for: source.transcoding)
        )
        let delegate = PeerContentAssetLoaderDelegate(client: client, trackId: track.id, contentType: contentType)
        let asset = AVURLAsset(url: PeerContentAssetLoaderDelegate.assetURL(trackId: track.id))
        asset.resourceLoader.setDelegate(delegate, queue: delegate.queue)
        return (asset, client, delegate)
    }

    private func teardownPeerContent() {
        peerContentClient?.disconnect()
        peerContentClient = nil
        peerContentDelegate = nil
    }

    private func refreshStreamPrefetch() {
        let desired = upcomingTracksForPredictiveDownload(limit: Self.prefetchLookahead)
        var keepIds = Set(desired.map(\.id))
        if queue.indices.contains(currentIndex) { keepIds.insert(queue[currentIndex].id) }

        // Cancel in-flight prefetches that no longer match the upcoming queue.
        let cancelledIds = prefetchTasks.keys.filter { !keepIds.contains($0) }
        for trackId in cancelledIds {
            prefetchTasks[trackId]?.cancel()
            prefetchTasks[trackId] = nil
            prefetchingTrackIds.remove(trackId)
        }

        if queue.isEmpty {
            prefetchedStreams.removeAll()
        } else {
            // Expire stale entries; fresh ones stay so a just-started track can
            // still consume the URL that was prefetched while it was upcoming.
            let now = Date()
            prefetchedStreams = prefetchedStreams.filter {
                now.timeIntervalSince($0.value.fetchedAt) < Self.prefetchTTLSeconds
            }
        }

        for track in desired {
            startStreamPrefetch(for: track)
        }

        refreshStandbyItems()
    }

    /// Starts a stream URL resolve for a track unless a fresh URL is already
    /// cached or a resolve is already in flight.
    private func startStreamPrefetch(for track: Track) {
        if let cached = prefetchedStreams[track.id],
           Date().timeIntervalSince(cached.fetchedAt) < Self.prefetchTTLSeconds { return }
        guard prefetchingTrackIds.insert(track.id).inserted else { return }

        prefetchTasks[track.id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.prefetchingTrackIds.remove(track.id)
                self.prefetchTasks[track.id] = nil
            }
            do {
                let url = try await Self.resolveStreamURL(for: track, collectionId: activeCollectionId)
                try Task.checkCancellation()
                self.prefetchedStreams[track.id] = (url, Date())
                self.refreshStandbyItems()
            } catch {}
        }
    }

    /// Warms the resolved stream URL for a track the user is likely to play
    /// (e.g. focused in a list), so a subsequent tap skips the blocking
    /// resolve. Fire-and-forget, deduped, non-blocking. Debounced so rapid
    /// focus-scrubbing only warms the row the user settles on. A URL resolve
    /// is a cheap API call, so it stays ungated by network quality.
    func warmStreamURL(for track: Track) {
        warmDebounceTask?.cancel()
        warmDebounceTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            guard !Task.isCancelled, let self else { return }
            guard track.streamURL != nil else { return }
            guard DownloadManager.shared.localFileURL(for: track) == nil else { return }
            self.startStreamPrefetch(for: track)
        }
    }

    /// Keeps a paused AVPlayerItem warm for the next upcoming tracks so the
    /// CDN connection and first buffer are ready before they are played.
    private func refreshStandbyItems() {
        let desired = upcomingTracksForPredictiveDownload(limit: Self.standbyLimit)
        var keepIds = Set(desired.map(\.id))
        // Keep the current index too: playNext sets currentIndex before
        // loadAndPlay consumes the standby, so it is no longer "upcoming".
        if queue.indices.contains(currentIndex) { keepIds.insert(queue[currentIndex].id) }

        // Tear down standby items that no longer match the upcoming queue, or
        // whose source URL left the prefetch cache (expired or consumed).
        let staleIds = standbyItems.keys.filter { !keepIds.contains($0) || prefetchedStreams[$0] == nil }
        for trackId in staleIds {
            standbyItems[trackId] = nil
        }

        // Peer-served playback resolves through its own loader; don't double-warm.
        guard Self.peerContentSource?.peerContentEndpoint == nil else { return }

        // Standby players download real bytes; skip on constrained networks
        // and while the stall circuit breaker is open (URL prefetching above
        // is a cheap API call and stays ungated).
        guard canWarmAggressively else { return }

        for track in desired {
            guard standbyItems[track.id] == nil else { continue }
            // A completed local download starts instantly and needs no warm-up.
            guard DownloadManager.shared.localFileURL(for: track) == nil else { continue }
            guard let cached = prefetchedStreams[track.id],
                  Date().timeIntervalSince(cached.fetchedAt) < Self.prefetchTTLSeconds else { continue }

            let asset = AVURLAsset(url: cached.url)
            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 0
            let player = AVPlayer(playerItem: item)
            player.pause()
            standbyItems[track.id] = StandbyItem(asset: asset, item: item, player: player)
        }
    }

    /// Removes and returns the standby item for a track, but only if it was
    /// warmed from the given stream URL; a standby built from a stale URL is
    /// torn down and discarded.
    private func consumeStandbyItem(for track: Track, matching url: URL) -> StandbyItem? {
        guard let standby = standbyItems.removeValue(forKey: track.id) else { return nil }
        standby.player.replaceCurrentItem(with: nil)
        guard standby.asset.url == url else { return nil }
        return standby
    }

    private func upcomingTracksForPredictiveDownload(limit: Int) -> [Track] {
        guard !queue.isEmpty, limit > 0 else { return [] }
        var result: [Track] = []
        var index = currentIndex + 1
        while result.count < limit {
            if index >= queue.count {
                guard repeatMode == .all, queue.count > 1 else { break }
                index = 0
            }
            guard index != currentIndex else { break } // wrapped all the way around
            result.append(queue[index])
            index += 1
        }
        return result
    }

    private func notifyDownloadManagerOfQueueChange() {
        let upcoming = upcomingTracksForPredictiveDownload(limit: 5)
        DownloadManager.shared.queueDidChange(upcoming: upcoming, isLocalPlaybackTarget: outputTarget == .thisDevice)
    }

    private func consumePrefetchedStreamURL(for track: Track) -> URL? {
        guard let cached = prefetchedStreams.removeValue(forKey: track.id) else { return nil }
        guard Date().timeIntervalSince(cached.fetchedAt) < Self.prefetchTTLSeconds else { return nil }
        return cached.url
    }

    private func playStream(
        asset: AVURLAsset,
        startPosition: TimeInterval = 0,
        preparedItem: AVPlayerItem? = nil
    ) async {
        if let observer = timeObserver, let player = player {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }

        cancellables.removeAll()

        let playerItem = preparedItem ?? AVPlayerItem(asset: asset)
        loadingState = .buffering

        playerItem.allowedAudioSpatializationFormats = .monoStereoAndMultichannel

        playerItem.preferredForwardBufferDuration = 0

        playerItem.publisher(for: \.isPlaybackLikelyToKeepUp)
            .filter { $0 }
            .first()
            .sink { [weak playerItem] _ in
                playerItem?.preferredForwardBufferDuration = 60
            }
            .store(in: &cancellables)

        playerItem.publisher(for: \.isPlaybackLikelyToKeepUp)
            .sink { [weak self, weak playerItem] keepingUp in
                Task { @MainActor in
                    guard let self, let playerItem, self.player?.currentItem === playerItem else { return }
                    self.loadingState = keepingUp ? .playing : .buffering
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AVPlayerItem.playbackStalledNotification, object: playerItem)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.observedStalls += 1
                    Log.player.error("[Player] stall #\(self.observedStalls, privacy: .public)")
                    // Trip the stall circuit breaker: suspend standby warm-up
                    // and aggressive start for 60s, and drop any warm players
                    // already holding buffered bytes.
                    self.stallCircuitOpenUntil = Date().addingTimeInterval(60)
                    self.standbyItems.removeAll()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: playerItem)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.handlePlaybackEnded()
                }
            }
            .store(in: &cancellables)

        if player == nil {
            player = AVPlayer(playerItem: playerItem)
            // While aggressive warm-up is allowed (good network, no recent
            // stall tripping the circuit breaker), start on the first
            // buffered bytes instead of waiting for the buffer to fill;
            // otherwise fall back to the default wait-to-minimize-stalling
            // behavior. The isPlaybackLikelyToKeepUp observer above still
            // raises preferredForwardBufferDuration once keeping up.
            player?.automaticallyWaitsToMinimizeStalling = !canWarmAggressively
        } else {
            player?.replaceCurrentItem(with: playerItem)
        }
        #if !os(macOS)
        if #available(iOS 27.0, tvOS 27.0, *) {
            player?.setDisconnectedFromSystemAudio(false)
        }
        #endif

        if startPosition > 0 {
            _ = await player?.seek(to: CMTime(seconds: startPosition, preferredTimescale: 600))
            currentTime = startPosition
        }

        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                self?.currentTime = time.seconds
                self?.updateNowPlayingProgress()
                self?.persistSessionState()
            }
        }

        player?.play()
        isPlaying = true
        isLoading = false
        updateNowPlayingMetadata()

        armMixSession()
    }

    private func handlePlaybackEnded() async {
        switch repeatMode {
        case .one:
            if isMixEngineLive {
                seek(to: 0)
            } else {
                let cmTime = CMTime(seconds: 0, preferredTimescale: 600)
                _ = await player?.seek(to: cmTime)
                currentTime = 0
                updateNowPlayingProgress()
            }
            play()
        case .all:
            await playNext()
        case .off:
            if currentIndex < queue.count - 1 {
                await playNext()
            } else {
                isPlaying = false
            }
        }
    }

    func play() {
        PlatformAudioSession.activatePlayback()

        if let pending = pendingRestore {
            // Let loadAndPlay read the latest pending position (which seek(to:)
            // may have updated since this Task was scheduled) and clear it.
            Task { @MainActor [weak self] in
                await self?.loadAndPlay(track: pending.track)
            }
            return
        }
        if isMixEngineLive {
            MixEngine.shared.play(deck: liveDeck)
            if isCrossfading { MixEngine.shared.play(deck: liveDeck.other) }
            isPlaying = true
            updateNowPlayingProgress()
            return
        }
        player?.play()
        isPlaying = true
        updateNowPlayingProgress()
    }

    func pause() {
        persistSessionState(force: true)
        if isMixEngineLive {
            MixEngine.shared.pause(deck: liveDeck)
            if isCrossfading { MixEngine.shared.pause(deck: liveDeck.other) }
            isPlaying = false
            updateNowPlayingProgress()
            return
        }
        player?.pause()
        isPlaying = false
        updateNowPlayingProgress()
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    /// Brief, bounded rate correction used by authenticated nearby playback.
    /// This deliberately avoids changing a live DJ deck's musical tempo.
    func nudgeSynchronizationRate(_ requestedRate: Double, for seconds: TimeInterval) {
        guard !isMixEngineLive, isPlaying, let player else { return }
        let rate = Float(min(1.02, max(0.98, requestedRate)))
        synchronizationRateTask?.cancel()
        player.rate = rate
        synchronizationRateTask = Task { @MainActor [weak self, weak player] in
            try? await Task.sleep(for: .seconds(max(0.1, seconds)))
            guard !Task.isCancelled, let self, let current = self.player,
                  current === player, self.isPlaying else { return }
            player?.rate = 1
        }
    }

    func resetSynchronizationRate() {
        synchronizationRateTask?.cancel()
        synchronizationRateTask = nil
        guard !isMixEngineLive, isPlaying else { return }
        player?.rate = 1
    }

    func seek(to time: TimeInterval) {
        if isMixEngineLive {
            MixEngine.shared.seek(deck: liveDeck, to: time)
            currentTime = time
            deckEndHandled = false
            updateNowPlayingProgress()
            return
        }
        if pendingRestore != nil {
            pendingRestore?.position = time
            currentTime = time
            updateNowPlayingProgress()
            return
        }
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player?.seek(to: cmTime)
        currentTime = time
        updateNowPlayingProgress()
    }

    func seekForward(_ seconds: TimeInterval = 15) {
        seek(to: min(currentTime + seconds, duration))
    }

    func seekBackward(_ seconds: TimeInterval = 15) {
        seek(to: max(currentTime - seconds, 0))
    }

    func playNext() async {
        guard let nextIndex = nextQueueIndex() else { return }

        if isMixEngineLive,
           !isCrossfading,
           incomingDeck.isReady,
           incomingTrackId == queue[nextIndex].id {
            performLiveTransition(to: queue[nextIndex], at: nextIndex, over: 0.25, announceAsMix: false)
            return
        }

        currentIndex = nextIndex
        await loadAndPlay(track: queue[nextIndex])
    }

    func playPrevious() async {
        guard !queue.isEmpty else { return }

        if currentTime > 3 {
            seek(to: 0)
            return
        }

        let prevIndex: Int
        if currentIndex > 0 {
            prevIndex = currentIndex - 1
        } else if repeatMode == .all {
            prevIndex = queue.count - 1
        } else {
            seek(to: 0)
            return
        }

        currentIndex = prevIndex
        await loadAndPlay(track: queue[prevIndex])
    }

    func playTrackAt(index: Int) async {
        guard index >= 0 && index < queue.count else { return }
        currentIndex = index
        await loadAndPlay(track: queue[index])
    }

    func toggleShuffle() {
        isShuffleEnabled.toggle()

        if isShuffleEnabled {
            var remainingTracks = Array(queue[(currentIndex + 1)...])
            remainingTracks.shuffle()
            queue = Array(queue[0...currentIndex]) + remainingTracks
        } else {
            if let currentTrack = currentTrack,
               let newIndex = originalQueue.firstIndex(of: currentTrack) {
                queue = originalQueue
                currentIndex = newIndex
            }
        }

        prepareIncomingDeck()
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    func addToQueue(_ track: Track) {
        queue.append(track)
        originalQueue.append(track)
        prepareIncomingDeck()
    }

    func insertIntoQueue(_ track: Track, at index: Int) {
        let target = max(0, min(index, queue.count))
        queue.insert(track, at: target)
        originalQueue.append(track)

        if target <= currentIndex {
            currentIndex += 1
        }

        prepareIncomingDeck()
    }

    func moveQueueItem(from source: Int, to destination: Int) {
        guard source >= 0, source < queue.count else { return }
        let target = max(0, min(destination, queue.count - 1))
        guard target != source else { return }

        let track = queue.remove(at: source)
        queue.insert(track, at: target)

        if let currentTrack, let index = queue.firstIndex(of: currentTrack) {
            currentIndex = index
        }

        if !isShuffleEnabled {
            originalQueue = queue
        }

        prepareIncomingDeck()
    }

    func removeFromQueue(at index: Int) async {
        guard index >= 0, index < queue.count else { return }

        let removed = queue.remove(at: index)
        if let originalIndex = originalQueue.firstIndex(of: removed) {
            originalQueue.remove(at: originalIndex)
        }

        guard !queue.isEmpty else {
            clearQueue()
            return
        }

        let wasPlayingTrack = index == currentIndex
        if wasPlayingTrack {
            currentIndex = min(index, queue.count - 1)
            await loadAndPlay(track: queue[currentIndex])
        } else if let currentTrack, let newIndex = queue.firstIndex(of: currentTrack) {
            currentIndex = newIndex
            prepareIncomingDeck()
        }
    }

    func clearQueue() {
        pause()
        endMixSession()
        teardownPeerContent()

        loadGeneration &+= 1

        if let observer = timeObserver, let player {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil
        cancellables.removeAll()

        player?.replaceCurrentItem(with: nil)
        queue = []
        originalQueue = []
        currentTrack = nil
        currentIndex = 0
        currentTime = 0
        duration = 0
        loadingState = .idle
        Self.nowPlaying.publishNowPlaying(nil)
    }

    func clearPlaybackHistory() {
        guard currentIndex > 0, currentIndex < queue.count else { return }
        let played = Array(queue.prefix(currentIndex))
        let remaining = Array(queue.dropFirst(currentIndex))

        if isShuffleEnabled {
            var restored = originalQueue
            for track in played {
                if let index = restored.firstIndex(of: track) {
                    restored.remove(at: index)
                }
            }
            originalQueue = restored
        } else {
            originalQueue = remaining
        }

        currentIndex = 0
        queue = remaining
    }

    var canSwitchToAppleTV: Bool {
        Self.remoteOutput?.isReachable == true
    }

    func switchOutputTarget(to target: PlaybackOutput) {
        guard target != outputTarget else { return }

        switch target {
        case .companion(let deviceClass):
            guard let remote = Self.remoteOutput, remote.isReachable else { return }
            if let track = currentTrack {
                remote.sendPlayback(track: track, queue: queue, index: currentIndex, position: currentTime, isPlaying: isPlaying)
            }
            pause()
            outputTarget = .companion(deviceClass)
        case .thisDevice:
            Self.remoteOutput?.pausePlayback()
            outputTarget = .thisDevice
        }
    }

    func adoptHandoff(track: Track, queue context: [Track], index: Int, position: TimeInterval, autoplay: Bool) async {
        Self.remoteOutput?.pausePlayback()
        outputTarget = .thisDevice

        var tracks = context
        let resolvedIndex: Int
        if tracks.indices.contains(index), tracks[index] == track {
            resolvedIndex = index
        } else if let existing = tracks.firstIndex(of: track) {
            resolvedIndex = existing
        } else {
            tracks.insert(track, at: 0)
            resolvedIndex = 0
        }

        originalQueue = tracks
        queue = tracks
        currentIndex = resolvedIndex

        await loadAndPlay(track: track, startPosition: position)
        if !autoplay { pause() }
    }

    private static let positionPersistInterval: TimeInterval = 5

    private func restoreLastSessionIfAvailable() {
        guard let accountID = SubscriptionService.shared.authenticatedAccountID,
              let snapshot = PlaybackStateStore.load(accountID: accountID),
              !snapshot.trackIds.isEmpty else { return }
        restoreTask?.cancel()
        restoreTask = Task { @MainActor [weak self] in
            await self?.performRestore(snapshot)
        }
    }

    private func performRestore(_ snapshot: PlaybackStateStore.Snapshot) async {
        let savedTrackId = snapshot.trackIds.indices.contains(snapshot.currentIndex)
            ? snapshot.trackIds[snapshot.currentIndex]
            : nil
        guard let savedTrackId else { return }

        var byId: [String: Track] = Dictionary(
            snapshot.trackIds.compactMap { id in
                DownloadManager.shared.cachedTrack(forTrackId: id).map { (id, $0) }
            },
            uniquingKeysWith: { cached, _ in cached }
        )

        // Restore downloaded content immediately. Network enrichment continues
        // below, but an offline launch still gets its previous Now Playing row,
        // queue position, and playable local audio.
        if byId[savedTrackId] != nil {
            applyRestoredSnapshot(snapshot, tracksById: byId)
        }

        var retryDelay: TimeInterval = 1
        while !Task.isCancelled {
            let missing = snapshot.trackIds.filter { byId[$0] == nil }
            if missing.isEmpty { return }
            guard currentTrack == nil || (currentTrack?.id == savedTrackId && pendingRestore != nil) else { return }

            guard SoundCloudAPI.credentials != nil else {
                try? await Task.sleep(for: .seconds(retryDelay))
                retryDelay = min(30, retryDelay * 2)
                continue
            }

            do {
                let countBeforeFetch = byId.count
                let fetched = try await SoundCloudAPI.shared.getTracks(ids: missing)
                for track in fetched { byId[track.id] = track }
                if byId[savedTrackId] != nil {
                    applyRestoredSnapshot(snapshot, tracksById: byId)
                }
                if snapshot.trackIds.allSatisfy({ byId[$0] != nil }) { return }
                // A successful but partial/empty response is still a retry.
                // Back off so a deleted or unavailable queue item cannot spin
                // continuously and hammer the API after launch.
                if byId.count == countBeforeFetch {
                    try await Task.sleep(for: .seconds(retryDelay))
                    retryDelay = min(30, retryDelay * 2)
                } else {
                    retryDelay = 1
                }
            } catch is CancellationError {
                return
            } catch {
                try? await Task.sleep(for: .seconds(retryDelay))
                retryDelay = min(30, retryDelay * 2)
            }
        }
    }

    private func applyRestoredSnapshot(
        _ snapshot: PlaybackStateStore.Snapshot,
        tracksById: [String: Track]
    ) {
        let restoredQueue = snapshot.trackIds.compactMap { tracksById[$0] }.filter { track in
            track.streamURL != nil || DownloadManager.shared.localFileURL(for: track) != nil
        }
        guard !restoredQueue.isEmpty else { return }
        let savedTrackId = snapshot.trackIds.indices.contains(snapshot.currentIndex)
            ? snapshot.trackIds[snapshot.currentIndex]
            : nil
        guard let savedTrackId,
              let resumeIndex = restoredQueue.firstIndex(where: { $0.id == savedTrackId }) else { return }
        let resumeTrack = restoredQueue[resumeIndex]

        activeCollectionId = snapshot.collectionId
        activeCollectionPolicy = snapshot.collectionId.map {
            CollectionQualityOverrideStore.shared.policy(for: $0)
        }
        collectionAutoMixRequested = snapshot.collectionAutoMixWasActive == true
        if collectionAutoMixRequested {
            let base = snapshot.djProfileId.flatMap(DJProfile.profile(id:))
                ?? activeCollectionPolicy.flatMap { DJProfile.profile(id: $0.djProfileId) }
                ?? defaultDJProfile
            djProfile = activeCollectionPolicy.map { base.applying(collectionPolicy: $0) } ?? base
            isAutoMixEnabled = true
        }
        let resumePosition = pendingRestore?.track.id == resumeTrack.id
            ? max(0, pendingRestore?.position ?? snapshot.positionSeconds)
            : max(0, snapshot.positionSeconds)

        isRestoringSession = true
        originalQueue = restoredQueue
        queue = restoredQueue
        currentIndex = resumeIndex
        currentTrack = resumeTrack
        isShuffleEnabled = snapshot.isShuffleEnabled
        repeatMode = snapshot.repeatMode
        duration = resumeTrack.duration
        currentTime = resumeTrack.duration > 0 ? min(resumePosition, resumeTrack.duration) : resumePosition
        isPlaying = false
        isLoading = false
        loadingState = .idle
        pendingRestore = (track: resumeTrack, position: currentTime)
        isRestoringSession = false

        updateNowPlayingMetadata()
    }

    private func persistSessionState(force: Bool = false) {
        guard !isRestoringSession else { return }
        guard let accountID = SubscriptionService.shared.authenticatedAccountID else { return }
        guard force || Date().timeIntervalSince(lastPersistedAt) >= Self.positionPersistInterval else { return }
        lastPersistedAt = Date()

        guard !queue.isEmpty, currentTrack != nil else {
            PlaybackStateStore.clear(accountID: accountID)
            return
        }
        let position = currentTime.isFinite ? max(0, currentTime) : 0
        PlaybackStateStore.save(PlaybackStateStore.Snapshot(
            trackIds: queue.map(\.id),
            currentIndex: currentIndex,
            positionSeconds: position,
            isShuffleEnabled: isShuffleEnabled,
            repeatMode: repeatMode,
            collectionId: activeCollectionId,
            djProfileId: djProfile?.id,
            collectionAutoMixWasActive: collectionAutoMixRequested,
            savedAt: Date()
        ), accountID: accountID)
    }

    private func observeAuthenticatedAccount() {
        SubscriptionService.shared.$authenticatedAccountID
            .removeDuplicates()
            .sink { [weak self] accountID in
                guard let self else { return }
                self.restoreTask?.cancel()
                self.restoreTask = nil
                if accountID == nil {
                    self.clearQueue()
                } else {
                    self.restoreLastSessionIfAvailable()
                }
            }
            .store(in: &sessionCancellables)
    }

    func setDJSessionEnabled(_ enabled: Bool) {
        guard djModeRequested != enabled || (!enabled && collectionAutoMixRequested) else { return }
        // Remote, watch, and hardware commands intentionally have no UI. If
        // this person has already chosen a start preset, honour it there too;
        // a collection marked DJ Only still keeps its more specific policy.
        if enabled,
           activeDJStartConfiguration == nil,
           !collectionAutoMixRequested,
           SettingsStore.shared.hasStoredValue(SettingKeys.DJStartOptions.self) {
            let configuration = SettingsStore.shared.djStartConfiguration
            activeDJStartConfiguration = configuration
            let base = DJProfile.profile(id: SettingsStore.shared.djDefaultProfileId) ?? .automaticDJ
            djProfile = base.applying(queueOrder: configuration.queueOrder)
            applyDJQueueOrder(configuration.queueOrder)
        }
        let before = djSessionEnabled
        djModeRequested = enabled
        if !enabled {
            collectionAutoMixRequested = false
            activeDJStartConfiguration = nil
            goodMatchDiscoveryTask?.cancel()
            goodMatchDiscoveryTask = nil
        }
        if enabled, djProfile == nil {
            djProfile = defaultDJProfile
        } else if !enabled, !autoMixSettingEnabled {
            djProfile = nil
        }
        applySessionEnabledTransition(from: before, primeAnalysis: enabled)
        if enabled, queue.isEmpty { startDefaultDJSourceIfNeeded() }
        if !enabled {
            defaultDJSourceTask?.cancel()
            defaultDJSourceTask = nil
        }
        if enabled, activeDJStartConfiguration?.sourceStrategy == .goodMatches {
            discoverGoodMatchesIfNeeded()
        }
    }

    var isDJSessionEnabled: Bool { djSessionEnabled }

    /// Starts (or explicitly reconfigures) an Auto DJ session. The UI holds
    /// this behind its configuration sheet, so cancelling never enables the
    /// audio graph or changes the running session.
    func startDJSession(
        configuration: DJStartConfiguration,
        reconfigure: Bool = false
    ) {
        guard reconfigure || !djModeRequested else { return }
        SettingsStore.shared.setDJStartConfiguration(configuration)
        activeDJStartConfiguration = configuration

        let base = DJProfile.profile(id: SettingsStore.shared.djDefaultProfileId) ?? .automaticDJ
        let collectionAdjusted = activeCollectionPolicy.map { base.applying(collectionPolicy: $0) } ?? base
        djProfile = collectionAdjusted.applying(queueOrder: configuration.queueOrder)
        applyDJQueueOrder(configuration.queueOrder)
        setAutomaticMixEnabled(true)
        DJTransitionService.shared.isEnabled = true
        setDJSessionEnabled(true)

        if configuration.sourceStrategy == .goodMatches {
            discoverGoodMatchesIfNeeded()
        }
        if djSessionEnabled {
            DJTransitionService.shared.analyzeUpcoming(in: queue, from: currentIndex)
            refreshPhantomPlan()
        }
    }

    private func applyDJQueueOrder(_ order: DJQueueOrderPolicy) {
        guard order == .random, currentIndex + 1 < queue.count else { return }
        var remaining = Array(queue[(currentIndex + 1)...])
        remaining.shuffle()
        queue = Array(queue[...currentIndex]) + remaining
        prepareIncomingDeck()
    }

    private func discoverGoodMatchesIfNeeded() {
        guard goodMatchDiscoveryTask == nil, let seed = currentTrack else { return }
        let configuration = activeDJStartConfiguration
        goodMatchDiscoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.goodMatchDiscoveryTask = nil }
            do {
                let related = try await SoundCloudAPI.shared.getRelatedTracks(trackID: seed.id, limit: 30).collection
                guard !Task.isCancelled,
                      self.activeDJStartConfiguration?.sourceStrategy == .goodMatches else { return }
                let known = Set(self.queue.map(\.id))
                let matches = related.filter { track in
                    guard !known.contains(track.id) else { return false }
                    guard let configuration else { return true }
                    let isSet = CollectionKind.classify(trackDurationSeconds: track.duration) == .set
                    switch configuration.setHandling {
                    case .include: return true
                    case .skip: return !isSet
                    case .onlySets: return isSet
                    }
                }
                guard !matches.isEmpty else { return }
                self.queue.append(contentsOf: matches)
                self.originalQueue.append(contentsOf: matches)
                if configuration?.queueOrder == .random { self.applyDJQueueOrder(.random) }
                self.prepareIncomingDeck()
                self.refreshPhantomPlan()
            } catch is CancellationError {
                return
            } catch {
                Log.player.debug("Auto DJ good-match discovery failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - DJTransitionServiceDelegate

    func djTransitionServiceDidChangeEnabled(_ enabled: Bool) {
        setDJSessionEnabled(enabled)
    }

    /// A collection marked Default DJ Source becomes the zero-configuration
    /// queue when Decks is enabled from an empty player.
    private func startDefaultDJSourceIfNeeded() {
        guard defaultDJSourceTask == nil,
              let collectionId = CollectionQualityOverrideStore.shared.defaultDJCollectionId else { return }
        defaultDJSourceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.defaultDJSourceTask = nil }
            do {
                let tracks = try await self.defaultDJTracks(collectionId: collectionId)
                guard !Task.isCancelled, self.djSessionEnabled, self.queue.isEmpty,
                      let first = tracks.first else { return }
                await self.play(first, in: tracks, collectionId: collectionId)
            } catch {
                Log.player.error("Could not start default DJ source: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func defaultDJTracks(collectionId: String) async throws -> [Track] {
        let cached = DownloadManager.shared.cachedTracks(forCollectionId: collectionId)
        if !cached.isEmpty { return cached }

        if collectionId == CollectionPolicyID.likedTracks {
            return try await SoundCloudAPI.shared.getLikedTracks(limit: 200).collection.map(\.item)
        }

        let playlist = try await SoundCloudAPI.shared.getPlaylist(id: collectionId)
        let ids = playlist.trackIDs ?? playlist.loadedTracks.map(\.id)
        return try await SoundCloudAPI.shared.getPlaylistTracks(playlist, ids: ids)
    }

    /// Changes the Decks run mode and keeps the normal playback setting in
    /// sync. This is the single entry point used by the TV console and the
    /// phone remote; merely moving an EQ or fader never silently changes it.
    func setAutomaticMixEnabled(_ enabled: Bool) {
        if !enabled, activeCollectionPolicy?.djMode == .djOnly {
            // "DJ Only" is a collection contract. The explicit Turn Off DJ
            // command can still end the session; the Auto switch cannot leave
            // a half-live deck graph behind.
            isAutoMixEnabled = true
            return
        }
        if enabled, djProfile == nil { djProfile = defaultDJProfile }
        isAutoMixEnabled = enabled
        SettingsStore.shared.setDJAutoMixEnabled(enabled)
        if enabled {
            armMixSession()
            if isMixEngineLive {
                let engine = MixEngine.shared
                engine.resetProcessing(on: liveDeck)
                if engine[liveDeck.other].status.isReady {
                    engine.resetProcessing(on: liveDeck.other, killLows: true)
                }
                if let currentTrack { applyLoudnessNormalization(for: currentTrack, deck: liveDeck) }
                if let upcomingTrack { applyLoudnessNormalization(for: upcomingTrack, deck: liveDeck.other) }
            }
            refreshPhantomPlan()
        }
    }

    private func observeAutoMixSetting() {
        let store = SettingsStore.shared
        applyAutoMixSettingEnabled(store.djAutoMixEnabled, initial: true)

        store.$djAutoMixEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.applyAutoMixSettingEnabled(enabled, initial: false)
            }
            .store(in: &sessionCancellables)

        store.$djDefaultProfileId
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] profileId in
                self?.applyDefaultDJProfile(profileId)
            }
            .store(in: &sessionCancellables)
    }

    private func observeDJAnalysisForPlanning() {
        DJTransitionService.shared.$states
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] states in
                guard let self else { return }
                let relevantIds = Set([self.currentTrack?.id, self.upcomingTrack?.id].compactMap { $0 })
                let relevant = states.filter { relevantIds.contains($0.key) }
                guard relevant != self.lastPlannerAnalysisStates else { return }
                self.lastPlannerAnalysisStates = relevant
                let gainedMeasuredAnalysis = relevant.values.contains {
                    if case .analyzed(let analysis) = $0 { return !analysis.isEstimated }
                    return false
                }
                if gainedMeasuredAnalysis { self.reconsiderCurrentPlanIfUseful() }
            }
            .store(in: &sessionCancellables)
    }

    private func applyAutoMixSettingEnabled(_ enabled: Bool, initial: Bool) {
        guard initial || autoMixSettingEnabled != enabled else { return }
        let before = djSessionEnabled
        autoMixSettingEnabled = enabled
        syncIsAutoMixEnabledFromSetting(enabled)
        if enabled, djProfile == nil {
            djProfile = defaultDJProfile
        } else if !enabled, !djModeRequested {
            djProfile = nil
        }
        applySessionEnabledTransition(from: before, primeAnalysis: enabled)
    }

    private func applySessionEnabledTransition(from before: Bool, primeAnalysis: Bool) {
        let after = djSessionEnabled
        guard after != before else { return }

        if after {
            armMixSession()
            if primeAnalysis {
                DJTransitionService.shared.analyzeUpcoming(in: queue, from: currentIndex)
            }
        } else {
            handBackToAVPlayer()
        }
    }

    private func syncIsAutoMixEnabledFromSetting(_ enabled: Bool) {
        isAutoMixEnabled = enabled || collectionAutoMixRequested
    }

    private var defaultDJProfile: DJProfile {
        DJProfile.profile(id: SettingsStore.shared.djDefaultProfileId) ?? .automaticDJ
    }

    /// Selects the automatic director's personality immediately and stores it
    /// as the synced default. Collection rules can still tighten its order,
    /// set handling, vocal-overlap and transition-length constraints.
    func setDJProfile(_ profileId: DJProfileID) {
        guard let base = DJProfile.profile(id: profileId) else { return }
        SettingsStore.shared.setDJDefaultProfileId(profileId)
        djProfile = activeCollectionPolicy.map { base.applying(collectionPolicy: $0) } ?? base
        if djSessionEnabled { armMixSession() }
        refreshPhantomPlan()
    }

    private func applyDefaultDJProfile(_ profileId: DJProfileID) {
        guard activeCollectionPolicy == nil, djSessionEnabled,
              let profile = DJProfile.profile(id: profileId) else { return }
        djProfile = profile
        refreshPhantomPlan()
    }

    func armMixSessionIfNeeded() {
        armMixSession()
    }

    var upcomingTrack: Track? {
        nextQueueIndex().map { queue[$0] }
    }

    private func nextQueueIndex() -> Int? {
        guard !queue.isEmpty else { return nil }
        if repeatMode == .all, currentIndex >= queue.count - 1 { return 0 }
        if currentIndex < queue.count - 1 { return currentIndex + 1 }
        return nil
    }

    func plannedMixSeconds() -> TimeInterval? {
        if let plan = adaptiveMixPlan { return plan.transitionSeconds }
        if isPhantomEnabled, let track = currentTrack {
            return automaticCleanCutFallback(for: track)?.transitionSeconds
        }
        guard let from = currentTrack, let to = upcomingTrack else { return nil }
        let dj = DJTransitionService.shared
        guard let plan = dj.transition(from: from, to: to) else { return nil }
        guard case .analyzed(let analysis) = dj.state(for: from.id),
              let bpm = analysis.bpm, bpm > 20 else { return nil }
        guard plan.totalBars > 0 else { return 2 }
        return min(90, max(2, Double(plan.totalBars) * 240.0 / bpm))
    }

    func plannedMixPointSeconds() -> TimeInterval? {
        if let plan = adaptiveMixPlan { return plan.mixPointSeconds }
        guard isPhantomEnabled, let track = currentTrack,
              let fallback = automaticCleanCutFallback(for: track) else {
            return nil
        }
        return fallback.mixPointSeconds
    }

    var adaptiveMixPlan: PhantomDJEngine.Plan? {
        guard let track = currentTrack, let plan = phantomPlanCache[track.id] else { return nil }
        guard let next = upcomingTrack else { return nil }
        guard plan.incomingTrackId == nil || plan.incomingTrackId == next.id else { return nil }
        return plan
    }

    var automaticMixDecision: DJAutomaticMixDecision {
        let profileName = djProfile?.displayName
        let plan = adaptiveMixPlan
        let isFallback = plan?.templateId == DJTemplates.cutOnTheOne
        let templateName = plan?.rationale?.templateName
            ?? plan?.templateId.map { DJTemplates.displayName(for: $0) }
        let headline = plan?.rationale?.headline
            ?? plan.map { isFallback ? "Clean cut at \(DJFormat.time($0.mixPointSeconds))" : $0.reasoning }

        let phase: DJAutomaticMixDecision.Phase
        if !isAutoMixEnabled {
            phase = .off
        } else if case .unavailable = mixEngineState {
            phase = .unavailable
        } else if mixWindow != nil {
            phase = isFallback ? .cutting : .mixing
        } else if upcomingTrack == nil {
            phase = .waiting
        } else if plan == nil {
            phase = isMixEngineLive ? .planning : .preparing
        } else if incomingDeck.isReady {
            phase = .armed
        } else {
            phase = .preparing
        }

        let unavailableReason: String?
        if case .unavailable(let reason) = mixEngineState { unavailableReason = reason }
        else { unavailableReason = nil }

        return DJAutomaticMixDecision(
            phase: phase,
            profileName: profileName,
            templateName: templateName,
            headline: unavailableReason
                ?? headline
                ?? (upcomingTrack == nil ? "Nothing queued after this track" : "Listening for a clean transition point"),
            reasoning: unavailableReason ?? plan?.reasoning,
            incomingTrackId: plan?.incomingTrackId ?? upcomingTrack?.id,
            mixPointSeconds: plan?.mixPointSeconds,
            transitionSeconds: plan?.transitionSeconds,
            entrySeconds: plan?.entrySeconds,
            score: plan?.rationale?.score,
            isFallback: isFallback
        )
    }

    var canStartMix: Bool {
        guard mixWindow == nil, !isCrossfading, upcomingTrack != nil else { return false }
        if isPhantomEnabled {
            return currentTrack.flatMap(phantomPlanOrFallback) != nil
        }
        return plannedMixSeconds() != nil
    }

    func startMix() {
        guard canStartMix, let next = upcomingTrack, let index = nextQueueIndex() else { return }

        if isPhantomEnabled, let track = currentTrack, let plan = phantomPlanOrFallback(for: track) {
            if isMixEngineLive, incomingDeck.isReady, incomingTrackId == next.id {
                phantomActivity = .mixing(plan)
                performLiveTransition(
                    to: next, at: index, over: plan.transitionSeconds,
                    announceAsMix: true, filterAccent: plan.accent, plan: plan
                )
            } else {
                phantomActivity = .cutting(reason: "Incoming deck wasn't ready — playing out, then cutting.")
                scheduleWindowThenCut(seconds: plan.transitionSeconds)
            }
            return
        }

        guard let seconds = plannedMixSeconds() else { return }
        if isMixEngineLive, incomingDeck.isReady, incomingTrackId == next.id {
            performLiveTransition(to: next, at: index, over: seconds, announceAsMix: true)
            return
        }

        scheduleWindowThenCut(seconds: seconds)
    }

    private func scheduleWindowThenCut(seconds: TimeInterval) {
        // "Mix Now" is an immediate command. If the second deck missed its
        // preload deadline, use a short safe cut instead of displaying a fake
        // mix window for the full planned blend and cutting much later.
        let cutSeconds = min(0.25, max(0.08, seconds))
        mixWindow = MixWindow(start: currentTime, seconds: cutSeconds, isLive: false)
        mixTask?.cancel()
        mixTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(cutSeconds))
            guard !Task.isCancelled, let self else { return }
            self.mixWindow = nil
            await self.playNext()
        }
    }

    private func armMixSession() {
        guard djSessionEnabled else { return }
        guard let track = currentTrack else {
            mixEngineState = .off
            return
        }
        if isMixEngineLive, armedTrackId == track.id {
            prepareIncomingDeck()
            return
        }
        guard armingTrackId != track.id else { return }

        guard !PlatformAudioSession.isAirPlayRoute else {
            mixEngineState = .unavailable(
                MixEngineError.airPlayRouteActive.errorDescription
                    ?? "DJ mode isn't available over AirPlay."
            )
            return
        }

        observeMixEngine()

        armTask?.cancel()
        armingTrackId = track.id
        mixEngineState = .preparing(0)

        let deck = MixEngine.Deck.a
        armTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let url = try await Self.resolveMixURL(for: track, collectionId: activeCollectionId)
                try Task.checkCancellation()
                guard self.djSessionEnabled, self.currentTrack?.id == track.id else {
                    self.armingTrackId = nil
                    self.mixEngineState = .off
                    return
                }

                let engine = MixEngine.shared
                self.incomingTask?.cancel()
                self.incomingTask = nil
                engine.unload(deck: deck.other)
                self.incomingTrackId = nil
                self.incomingDeck = .idle

                try await engine.load(
                    url: url,
                    into: deck,
                    trackId: track.id,
                    cacheKey: Self.mixCacheKey(for: track, collectionId: activeCollectionId)
                )
                if let localURL = engine.localFileURL(for: deck) {
                    scheduleMixAnalysis(track: track, transcoding: track.mixSource, localFileURL: localURL)
                }

                self.armingTrackId = nil
                guard self.djSessionEnabled, self.currentTrack?.id == track.id else {
                    engine.unload(deck: deck)
                    self.mixEngineState = .off
                    return
                }
                self.takeOverFromAVPlayer(on: deck, track: track)
            } catch {
                self.armingTrackId = nil
                if Self.isCancellation(error) { return }
                guard self.djSessionEnabled, self.currentTrack?.id == track.id else {
                    self.mixEngineState = .off
                    return
                }
                self.mixEngineState = .unavailable(Self.describeMixFailure(error))
            }
        }
    }

    private func takeOverFromAVPlayer(on deck: MixEngine.Deck, track: Track) {
        let engine = MixEngine.shared
        let resumeAt = currentTime
        let wasPlaying = isPlaying

        liveDeck = deck
        armedTrackId = track.id
        deckEndHandled = false
        isCrossfading = false

        engine.cancelAllRamps()
        engine.masterVolume = 1
        engine.crossfade = deck == .a ? 0 : 1
        engine.setGain(1, on: deck)
        applyLoudnessNormalization(for: track, deck: deck)
        engine.resetEQ(on: deck)
        engine.openFilter(on: deck)
        engine.setRate(1, on: deck)
        engine.setPitch(0, on: deck)
        engine.seek(deck: deck, to: resumeAt)

        // Do not tear down the AVPlayer until the engine deck has actually
        // started. If startup fails, fall back to the existing player so the
        // track does not end up in a silent half-state.
        if wasPlaying {
            player?.pause()
            engine.play(deck: deck)
        }

        guard engine[deck].status.isReady, engine[deck].isPlaying || !wasPlaying else {
            if wasPlaying { player?.play() }
            mixEngineState = .unavailable(
                Self.describeMixFailure(engine.lastError ?? MixEngineError.engineStartFailed("deck did not start"))
            )
            return
        }

        teardownAVPlayer()

        mixEngineState = .live
        isLoading = false
        loadingState = .playing
        if engine[deck].duration > 0 { duration = engine[deck].duration }
        currentTime = resumeAt

        isPlaying = wasPlaying

        updateNowPlayingProgress()
        prepareIncomingDeck()
        refreshPhantomPlan()
    }

    private func prepareIncomingDeck() {
        guard djSessionEnabled, isMixEngineLive, !isCrossfading else { return }

        guard let next = upcomingTrack else {
            incomingTask?.cancel()
            incomingTask = nil
            if incomingTrackId != nil {
                MixEngine.shared.unload(deck: liveDeck.other)
                incomingTrackId = nil
            }
            incomingDeck = .idle
            return
        }
        if let currentId = currentTrack?.id,
           let cached = phantomPlanCache[currentId],
           cached.incomingTrackId != nil,
           cached.incomingTrackId != next.id {
            invalidatePhantomPlan(for: currentId)
        } else if let previous = incomingTrackId, previous != next.id,
                  let currentId = currentTrack?.id {
            invalidatePhantomPlan(for: currentId)
        }
        if incomingTrackId == next.id {
            if isAutoMixEnabled, MixEngine.shared[liveDeck.other].status.isReady {
                MixEngine.shared.resetProcessing(on: liveDeck.other, killLows: true)
                applyLoudnessNormalization(for: next, deck: liveDeck.other)
            }
            if let grid = adaptiveMixPlan?.incomingBeatGrid {
                MixEngine.shared.setBeatGrid(grid, for: liveDeck.other)
            }
            return
        }

        incomingTask?.cancel()
        incomingTrackId = next.id
        incomingDeck = .loading(0)

        let deck = liveDeck.other
        incomingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let url = try await Self.resolveMixURL(for: next, collectionId: activeCollectionId)
                try Task.checkCancellation()
                guard self.incomingTrackId == next.id else { return }

                let engine = MixEngine.shared
                try await engine.load(
                    url: url,
                    into: deck,
                    trackId: next.id,
                    cacheKey: Self.mixCacheKey(for: next, collectionId: activeCollectionId)
                )
                guard self.incomingTrackId == next.id else {
                    engine.unload(deck: deck)
                    return
                }
                if let localURL = engine.localFileURL(for: deck) {
                    scheduleMixAnalysis(track: next, transcoding: next.mixSource, localFileURL: localURL)
                }

                engine.resetProcessing(on: deck, killLows: true)
                self.applyLoudnessNormalization(for: next, deck: deck)
                engine.seek(deck: deck, to: 0)
                self.incomingDeck = .ready
                self.precomputePhantomPlanIfNeeded(for: next)
                self.reconsiderCurrentPlanIfUseful()
            } catch {
                if Self.isCancellation(error) { return }
                guard self.incomingTrackId == next.id else { return }
                self.incomingDeck = .failed(Self.describeMixFailure(error))
            }
        }
    }

    private func scheduleMixAnalysis(track: Track, transcoding: Transcoding?, localFileURL: URL) {
        if DeckIdentityResolver.isLikelyMix(track) {
            SetlistBackgroundWorkCoordinator.shared.enqueue(
                track: track,
                localFileURL: localFileURL
            )
        }
        #if os(tvOS)
        return
        #else
        guard #available(iOS 27.0, macOS 27.0, *) else { return }
        Task.detached(priority: .utility) { [weak self] in
            let result = await AnalysisCoordinator.analyze(
                track: track,
                transcoding: transcoding,
                localFileURL: localFileURL,
                registry: AnalysisProducerRegistry([MusicUnderstandingProducer()]),
                cache: .shared
            )
            guard !Task.isCancelled else { return }
            let learnedSomething = result.outcomes.values.contains {
                if case .stored = $0 { return true }
                return false
            }
            if learnedSomething {
                await MainActor.run { self?.reconsiderCurrentPlanIfUseful() }
            }
        }
        #endif
    }

    private func refreshPhantomPlan() {
        phantomCutAnnounced = false
        guard isPhantomEnabled, isMixEngineLive, let track = currentTrack else {
            phantomActivity = .idle
            return
        }
        if let cached = phantomPlanCache[track.id] {
            phantomActivity = .armed(cached)
            return
        }
        phantomActivity = .idle
        precomputePhantomPlanIfNeeded(for: track, thenArmIfLive: true)
    }

    private func invalidatePhantomPlan(for trackId: String) {
        phantomPlanTasks[trackId]?.cancel()
        phantomPlanTasks[trackId] = nil
        phantomPlanCache[trackId] = nil
        if currentTrack?.id == trackId {
            phantomActivity = .idle
            refreshPhantomPlan()
        }
    }

    /// Analysis can improve after the first envelope-only decision. Keep
    /// reconsidering while the transition is still far enough away, then
    /// commit so the loaded deck and UI cannot churn at the last moment.
    private func reconsiderCurrentPlanIfUseful() {
        guard isAutoMixEnabled, let track = currentTrack, mixWindow == nil, !isCrossfading else { return }
        if let plan = adaptiveMixPlan,
           currentTime >= max(0, plan.mixPointSeconds - 45) {
            return
        }
        invalidatePhantomPlan(for: track.id)
    }

    private func precomputePhantomPlanIfNeeded(for track: Track, thenArmIfLive: Bool = false) {
        guard let profile = djProfile, phantomPlanCache[track.id] == nil else { return }
        guard phantomPlanTasks[track.id] == nil else { return }

        let trackId = track.id
        let candidates = candidateTracks(after: track, limit: profile.lookaheadCandidates)
        let history = currentSetHistory()

        phantomPlanTasks[trackId] = Task { @MainActor [weak self] in
            guard let self else { return }
            let plan = await Self.computePhantomPlan(
                for: track, candidates: candidates, profile: profile, history: history
            )
            self.phantomPlanTasks[trackId] = nil
            guard !Task.isCancelled, self.djProfile == profile,
                  self.phantomPlanCache[trackId] == nil, let plan else { return }
            if profile.mayReorderQueue == false,
               plan.incomingTrackId != nil,
               plan.incomingTrackId != self.upcomingTrack?.id {
                return
            }
            if profile.mayReorderQueue,
               let incomingTrackId = plan.incomingTrackId,
               incomingTrackId != self.upcomingTrack?.id {
                self.promoteToUpcoming(trackId: incomingTrackId)
            }
            self.phantomPlanCache[trackId] = plan
            if self.currentTrack?.id == trackId, self.isMixEngineLive {
                MixEngine.shared.setBeatGrid(plan.outgoingBeatGrid, for: self.liveDeck)
                if plan.incomingTrackId == self.incomingTrackId {
                    MixEngine.shared.setBeatGrid(plan.incomingBeatGrid, for: self.liveDeck.other)
                }
            }
            if thenArmIfLive, self.armedTrackId == trackId {
                self.phantomActivity = .armed(plan)
            }
        }
    }

    private func promoteToUpcoming(trackId: String) {
        guard currentIndex + 1 < queue.count,
              let sourceIndex = queue[(currentIndex + 1)...].firstIndex(where: { $0.id == trackId }),
              sourceIndex != currentIndex + 1 else { return }
        let selected = queue.remove(at: sourceIndex)
        queue.insert(selected, at: currentIndex + 1)
        originalQueue.removeAll { $0.id == trackId }
        let originalInsertion = min(currentIndex + 1, originalQueue.count)
        originalQueue.insert(selected, at: originalInsertion)
    }

    private func candidateTracks(after track: Track, limit: Int) -> [Track] {
        guard let index = queue.firstIndex(of: track) else { return upcomingTrack.map { [$0] } ?? [] }
        var out: [Track] = []
        var cursor = index + 1
        while out.count < max(1, limit), cursor < queue.count {
            out.append(queue[cursor])
            cursor += 1
        }
        if out.isEmpty, repeatMode == .all, !queue.isEmpty, queue[0].id != track.id {
            out.append(queue[0])
        }
        return out
    }

    private func currentSetHistory() -> SetHistory {
        let played = (0..<currentIndex).reversed().prefix(6).map { queue[$0] }
        return SetHistory(
            recentTemplates: recentTemplates,
            recentArtists: played.map(\.user.username),
            recentTrackIds: played.map(\.id)
        )
    }

    private nonisolated static func computePhantomPlan(
        for track: Track,
        candidates: [Track],
        profile: DJProfile,
        history: SetHistory
    ) async -> PhantomDJEngine.Plan? {
        let outgoing = await features(for: track)

        guard !candidates.isEmpty else {
            return envelopeOnlyPlan(outgoing)
        }
        var candidateFeatures: [TrackFeatures] = []
        for candidate in candidates {
            candidateFeatures.append(await features(for: candidate))
        }

        let inputs = PhantomDJEngine.PlanningInputs(
            outgoing: outgoing,
            candidates: candidateFeatures,
            profile: profile,
            history: history,
            capabilities: .fullMixEngine,
            seedComponents: [profile.id.rawValue, track.id, String(candidates.count)]
        )
        let (plan, result) = PhantomDJEngine.plan(inputs)
        if let plan { return plan }

        return PhantomDJEngine.cleanCutFallbackPlan(
            outgoingDuration: outgoing.duration,
            incomingTrackId: candidates.first?.id,
            profileId: profile.id,
            reasoning: PhantomDJEngine.refusalReasoning(result, profile: profile),
        )
    }

    private nonisolated static func envelopeOnlyPlan(_ features: TrackFeatures) -> PhantomDJEngine.Plan? {
        guard !features.envelope.isEmpty else {
            return PhantomDJEngine.fallbackPlan(outgoingDuration: features.duration)
        }
        return PhantomDJEngine.plan(outgoingDuration: features.duration, envelope: features.envelope)
            ?? PhantomDJEngine.fallbackPlan(outgoingDuration: features.duration)
    }

    private static func scheduleTier1Analysis(for track: Track) {
        Task.detached(priority: .utility) {
            var samples: [Float] = []
            if case .success(let waveform) = await WaveformService.shared.waveform(for: track), !waveform.isEmpty {
                samples = waveform.resampled(to: 200)
            }
            var tags: [String] = []
            if let genre = track.genre, !genre.isEmpty { tags.append(genre) }
            tags.append(contentsOf: track.tags)
            tags.append(track.title)
            _ = await AnalysisCoordinator.analyze(
                track: track,
                genreField: track.genre,
                tags: tags,
                waveformSamples: samples,
                registry: .metadataOnly,
                cache: .shared
            )
        }
    }

    private nonisolated static func features(for track: Track) async -> TrackFeatures {
        var envelope: [Float] = []
        if case .success(let waveform) = await WaveformService.shared.waveform(for: track), !waveform.isEmpty {
            let bucketCount = max(8, Int((track.duration / DJEngineConstants.bucketSeconds).rounded()))
            envelope = waveform.resampled(to: bucketCount)
        }

        var grid: BeatGrid?
        var keyRegions: [KeyRegion] = []
        var energyLevel: Int?
        var sections: [TrackSection] = []
        var provenance: FeatureProvenance = envelope.isEmpty ? .metadataOnly : .envelopeOnly

        var vocalRanges: [ClosedRange<TimeInterval>] = []
        var bassRanges: [ClosedRange<TimeInterval>] = []
        var phraseBoundaries: [TimeInterval] = []

        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, *) {
            if let cached = await cachedAnalysisFeatures(for: track) {
                if let bpm = cached.features.bpm,
               cached.barSeconds.count >= 2,
               let measured = BeatGrid.fromMeasuredBars(
                   bpm: bpm, beats: cached.beatSeconds, bars: cached.barSeconds, confidence: 0.85
               ) {
                grid = measured
                provenance.insert([.measuredTempo, .measuredBeatGrid, .measuredDownbeats])
            } else if let bpm = cached.features.bpm, let measured = BeatGrid.fromDisplayBPM(bpm, confidence: 0.85) {
                grid = measured
                provenance.insert([.measuredTempo, .measuredBeatGrid])
            }
            if !cached.keyRegions.isEmpty {
                keyRegions = cached.keyRegions
                provenance.insert(.measuredKey)
            } else if let key = cached.features.key {
                keyRegions = [KeyRegion(key: key, start: 0, end: track.duration)]
                provenance.insert(.measuredKey)
            }
            if let measuredVocalRanges = cached.vocalRanges {
                vocalRanges = measuredVocalRanges
                provenance.insert(.measuredVocals)
            }
            if let measuredBassRanges = cached.bassRanges {
                bassRanges = measuredBassRanges
                provenance.insert(.measuredBass)
            }
            if !cached.structureRanges.isEmpty {
                sections = classifyStructure(
                    cached.structureRanges,
                    duration: track.duration,
                    envelope: envelope
                )
                phraseBoundaries = cached.phraseBoundaries
                provenance.insert(.measuredStructure)
            }
            if let lufs = cached.integratedLUFS, lufs.isFinite {
                // Typical mastered music falls roughly between -24 and -6
                // LUFS. This is a stable whole-track energy prior, unlike the
                // legacy analyzer's first-minute snapshot.
                energyLevel = min(10, max(1, Int(((Double(lufs) + 24) / 2).rounded()) + 1))
            }
            }
        }

        let legacyAnalysis: TrackAnalysis? = await MainActor.run {
            if case .analyzed(let analysis) = DJTransitionService.shared.state(for: track.id) {
                return analysis
            }
            return nil
        }
        if let analysis = legacyAnalysis, !analysis.isEstimated {
            if grid == nil,
               let bpm = analysis.bpm,
               let measured = BeatGrid.fromDisplayBPM(bpm, confidence: 0.7) {
                grid = measured
                provenance.insert([.measuredTempo, .measuredBeatGrid])
            }
            if keyRegions.isEmpty, let key = analysis.key, let camelot = CamelotKey.parse(key) {
                keyRegions = [KeyRegion(key: camelot, start: 0, end: track.duration)]
                provenance.insert(.measuredKey)
            }
            if energyLevel == nil {
                energyLevel = min(10, max(1, Int((analysis.energy * 10).rounded())))
            }
            if sections.isEmpty, analysis.intro > 1, analysis.intro < track.duration * 0.5 {
                sections = [TrackSection(kind: .intro, start: 0, end: analysis.intro)]
            }
        }

        let userCues = await CueStore.shared.cues(forTrack: track.id)
        let preferredEntry = userCues.first { $0.kind == .mixIn }?.positionSeconds
        let preferredExit = userCues.first { $0.kind == .mixOut }?.positionSeconds

        let genre = GenreDetector.resolve(genreField: track.genre, tags: track.tags + [track.title])

        return TrackFeatures(
            trackId: track.id,
            title: track.title,
            artist: track.user.username,
            duration: track.duration,
            beatGrid: grid,
            swingRatio: nil,
            keyRegions: keyRegions,
            sections: sections,
            phraseBoundaries: phraseBoundaries,
            energyLevel: energyLevel,
            envelope: envelope,
            genre: genre,
            vocalRanges: vocalRanges,
            bassRanges: bassRanges,
            preferredEntrySeconds: preferredEntry,
            preferredExitSeconds: preferredExit,
            provenance: provenance
        )
    }

    private nonisolated static func classifyStructure(
        _ ranges: [ClosedRange<TimeInterval>],
        duration: TimeInterval,
        envelope: [Float]
    ) -> [TrackSection] {
        let valid = ranges
            .filter { $0.lowerBound.isFinite && $0.upperBound.isFinite && $0.upperBound > $0.lowerBound }
            .sorted { $0.lowerBound < $1.lowerBound }
        guard !valid.isEmpty else { return [] }

        let median = DJPointFinder.envelopeMedian(envelope)
        func level(in range: ClosedRange<TimeInterval>) -> Double? {
            guard !envelope.isEmpty, duration > 0 else { return nil }
            let lower = max(0, min(envelope.count - 1, Int(range.lowerBound / duration * Double(envelope.count))))
            let upper = max(lower + 1, min(envelope.count, Int(range.upperBound / duration * Double(envelope.count))))
            guard lower < upper else { return nil }
            return envelope[lower..<upper].map(Double.init).reduce(0, +) / Double(upper - lower)
        }

        return valid.enumerated().map { index, range in
            let center = (range.lowerBound + range.upperBound) / 2
            let normalized = duration > 0 ? center / duration : 0
            let relative = median > 0 ? (level(in: range) ?? median) / median : 1
            let kind: SectionKind
            if index == 0 || normalized < 0.12 {
                kind = relative < 0.45 ? .ambientIntro : .intro
            } else if index == valid.count - 1 || normalized > 0.88 {
                kind = relative < 0.45 ? .ambientOutro : .outro
            } else if relative < 0.65 {
                kind = normalized > 0.70 ? .cooldown : .breakdown
            } else if relative > 1.18 {
                kind = .drop
            } else if index + 1 < valid.count,
                      let next = level(in: valid[index + 1]), median > 0, next / median > relative + 0.2 {
                kind = .buildup
            } else {
                kind = .bridge
            }
            return TrackSection(kind: kind, start: range.lowerBound, end: range.upperBound)
        }
    }

    private struct CachedMusicUnderstanding: Sendable {
        let features: AnalysisFeatures
        let beatSeconds: [TimeInterval]
        let barSeconds: [TimeInterval]
        let structureRanges: [ClosedRange<TimeInterval>]
        let phraseBoundaries: [TimeInterval]
        let keyRegions: [KeyRegion]
        let vocalRanges: [ClosedRange<TimeInterval>]?
        let bassRanges: [ClosedRange<TimeInterval>]?
        let integratedLUFS: Float?
    }

    @available(iOS 27.0, macOS 27.0, tvOS 27.0, *)
    private nonisolated static func cachedAnalysisFeatures(for track: Track) async -> CachedMusicUnderstanding? {
        let transcoding = track.transcodings.max { $0.playbackRank < $1.playbackRank }
        guard let key = AnalysisCacheKey(
            track: track,
            transcoding: transcoding,
            generation: MusicUnderstandingProducer().generation
        ) else { return nil }

        guard let result = await AnalysisCache.shared.peek(
            MusicUnderstandingSession.SessionResult.self,
            for: key
        ) else { return nil }

        let beatSeconds = (result.rhythm?.beats ?? []).map(\.seconds).filter { $0.isFinite }
        let barSeconds = (result.rhythm?.bars ?? []).map(\.seconds).filter { $0.isFinite }

        func validRange(_ range: CMTimeRange) -> ClosedRange<TimeInterval>? {
            let lower = range.start.seconds
            let upper = range.end.seconds
            guard lower.isFinite, upper.isFinite, upper > lower else { return nil }
            return lower...upper
        }
        let structureRanges = (result.structure?.sections ?? []).compactMap(validRange)
        let phraseBoundaries = (result.structure?.phrases ?? [])
            .map(\.start.seconds)
            .filter { $0.isFinite && $0 >= 0 }
        let keyRegions: [KeyRegion] = (result.key?.ranges ?? []).compactMap { ranged in
            guard let range = validRange(ranged.range),
                  let key = MusicUnderstandingProducer.camelotKey(for: ranged.value) else { return nil }
            return KeyRegion(key: key, start: range.lowerBound, end: range.upperBound)
        }

        func ranges(for instrument: InstrumentActivityResult.Instrument) -> [ClosedRange<TimeInterval>]? {
            result.instrumentActivity.map { activity in
                (activity.ranges[instrument] ?? []).compactMap { range -> ClosedRange<TimeInterval>? in
                    let lower = range.start.seconds
                    let upper = range.end.seconds
                    guard lower.isFinite, upper.isFinite, upper >= lower else { return nil }
                    return lower...upper
                }
            }
        }
        let vocalRanges = ranges(for: .vocal)
        let bassRanges = ranges(for: .bass)

        let integratedLUFS = result.loudness?.integrated.value

        return CachedMusicUnderstanding(
            features: MusicUnderstandingProducer.projectFeatures(result),
            beatSeconds: beatSeconds,
            barSeconds: barSeconds,
            structureRanges: structureRanges,
            phraseBoundaries: phraseBoundaries,
            keyRegions: keyRegions,
            vocalRanges: vocalRanges,
            bassRanges: bassRanges,
            integratedLUFS: integratedLUFS
        )
    }

    private static func loudnessAttenuation(for track: Track) async -> Double {
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, *) {
            if let cached = await cachedAnalysisFeatures(for: track), let lufs = cached.integratedLUFS {
                return LoudnessNormalization.attenuation(measuredLUFS: lufs)
            }
        }
        if case .success(let waveform) = await WaveformService.shared.waveform(for: track), !waveform.isEmpty {
            return LoudnessNormalization.attenuation(waveformRMS: waveform.rmsLevel)
        }
        return 1
    }

    private func applyLoudnessNormalization(for track: Track, deck: MixEngine.Deck? = nil) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let gain = await Self.loudnessAttenuation(for: track)
            guard !Task.isCancelled else { return }
            if let deck {
                guard MixEngine.shared[deck].trackId == track.id else { return }
                MixEngine.shared.setGain(gain, on: deck, over: 0.5)
            } else {
                guard self.currentTrack?.id == track.id, !self.isMixEngineLive else { return }
                self.player?.volume = Float(gain)
            }
        }
    }

    private func phantomPlanOrFallback(for track: Track) -> PhantomDJEngine.Plan? {
        if let cached = phantomPlanCache[track.id],
           cached.incomingTrackId == nil || cached.incomingTrackId == upcomingTrack?.id {
            return cached
        }
        return automaticCleanCutFallback(for: track)
    }

    private func automaticCleanCutFallback(for track: Track) -> PhantomDJEngine.Plan? {
        PhantomDJEngine.cleanCutFallbackPlan(
            outgoingDuration: track.duration,
            incomingTrackId: upcomingTrack?.id,
            profileId: djProfile?.id
        )
    }

    private func updatePhantomTick(live: MixEngine.DeckState) {
        guard isAutoMixEnabled, isMixEngineLive, !isCrossfading, mixWindow == nil else { return }
        guard let track = currentTrack, let plan = phantomPlanOrFallback(for: track) else { return }
        guard live.position >= max(0, plan.mixPointSeconds - Self.transitionSchedulingLead) else { return }

        if incomingDeck.isReady, let next = upcomingTrack, incomingTrackId == next.id {
            Task { @MainActor [weak self] in self?.startPhantomMixIfStillDue() }
        } else if !phantomCutAnnounced {
            phantomCutAnnounced = true
            let reason: String
            if case .failed(let message) = incomingDeck {
                reason = "Next track couldn't be prepared: \(message)"
            } else if upcomingTrack == nil {
                reason = "No next track queued — playing out."
            } else {
                reason = "Next track wasn't ready in time — playing out to a hard cut."
            }
            phantomActivity = .cutting(reason: reason)
        }
    }

    private func startPhantomMixIfStillDue() {
        guard isAutoMixEnabled, isPhantomEnabled, isMixEngineLive, !isCrossfading, mixWindow == nil else { return }
        guard let track = currentTrack, let plan = phantomPlanOrFallback(for: track) else { return }
        guard MixEngine.shared[liveDeck].position >= max(0, plan.mixPointSeconds - Self.transitionSchedulingLead) else { return }
        guard incomingDeck.isReady, let next = upcomingTrack, let index = nextQueueIndex(),
              incomingTrackId == next.id else { return }

        phantomActivity = .mixing(plan)
        performLiveTransition(
            to: next, at: index, over: plan.transitionSeconds,
            announceAsMix: true, filterAccent: plan.accent, plan: plan,
            startAtPlannedBoundary: true
        )
    }

    private func performLiveTransition(
        to track: Track,
        at index: Int,
        over seconds: TimeInterval,
        announceAsMix: Bool,
        filterAccent: PhantomDJEngine.Accent? = nil,
        plan: PhantomDJEngine.Plan? = nil,
        startAtPlannedBoundary: Bool = false
    ) {
        let engine = MixEngine.shared
        let outgoing = liveDeck
        let incoming = liveDeck.other
        let window = max(0.15, seconds)
        let defersIncomingStart = plan?.templateId == DJTemplates.loopRollDown

        isCrossfading = true
        deckEndHandled = false
        let entrySeconds = plan?.entrySeconds ?? 0

        if let grid = plan?.outgoingBeatGrid { engine.setBeatGrid(grid, for: outgoing) }
        if let grid = plan?.incomingBeatGrid { engine.setBeatGrid(grid, for: incoming) }

        // A manually touched preloaded deck is never trusted as an automatic
        // input. Reset it on every takeover, not only on first load.
        if isAutoMixEnabled { engine.resetProcessing(on: incoming, killLows: true) }

        let grid = plan?.outgoingBeatGrid ?? outgoingBeatGrid()
        let plannedSourceTime = startAtPlannedBoundary ? plan?.mixPointSeconds : nil
        let currentSourceTime = engine[outgoing].position
        applyBeatMatch(outgoing: outgoing, incoming: incoming, to: track, plan: plan)

        let cueResult: MixEngine.CueResult
        if defersIncomingStart {
            // A roll-down keeps the next record silent until the final cut. The
            // old executor started it here, so a 32-bar ladder could reveal the
            // incoming track a minute past its selected entry cue.
            engine.seek(deck: incoming, to: entrySeconds)
            if let plannedSourceTime,
               let lead = engine.wallLeadSeconds(on: outgoing, to: plannedSourceTime) {
                cueResult = .aligned(leadSeconds: lead)
            } else {
                cueResult = .unaligned(reason: "roll-down starts immediately")
            }
        } else if plannedSourceTime.map({ $0 > currentSourceTime + 0.06 }) == true || grid != nil {
            cueResult = engine.cue(
                deck: incoming,
                to: entrySeconds,
                alignedTo: outgoing,
                referenceBeatPeriod: grid?.beatPeriod ?? 1,
                referenceGridAnchor: grid?.firstDownbeat ?? 0,
                referenceSourceSeconds: plannedSourceTime,
                beatsPerAlignment: 4
            )
        } else {
            engine.seek(deck: incoming, to: entrySeconds)
            engine.play(deck: incoming)
            cueResult = .unaligned(reason: "no measured grid — starting the safe transition immediately")
        }
        if !isPlaying { engine.pause(deck: incoming) }

        let leadSeconds: TimeInterval
        switch cueResult {
        case .aligned(let lead):
            leadSeconds = max(0, lead)
        case .unaligned:
            leadSeconds = 0
        case .failed(let reason):
            isCrossfading = false
            phantomActivity = .cutting(reason: "Incoming deck could not start: \(reason)")
            return
        }

        if announceAsMix {
            let sourceLead = leadSeconds * max(0.01, engine[outgoing].rate)
            mixWindow = MixWindow(start: currentTime + sourceLead, seconds: window, isLive: true)
        }

        engine.setEQ(.low, on: incoming, toDecibels: MixEngine.eqGainRange.lowerBound)
        if filterAccent == .incomingFilterOpen {
            engine.setFilterCutoff(DJEngineConstants.accentClosedFilterHz, on: incoming, over: 0)
        }

        mixTask?.cancel()
        for task in transitionStageTasks { task.cancel() }
        transitionStageTasks.removeAll()
        mixTask = Task { @MainActor [weak self] in
            if leadSeconds > 0 {
                try? await Task.sleep(for: .seconds(leadSeconds))
            }
            guard !Task.isCancelled, let self else { return }

            if let plan, !plan.stages.isEmpty {
                // A hidden incoming deck adds no level. Preserve loudness during
                // the roll and rely on the limiter for the final 50 ms cut.
                let needsOverlapHeadroom = announceAsMix && window > 1 && !defersIncomingStart
                MixEngine.shared.setMasterVolume(needsOverlapHeadroom ? 0.707 : 1, over: min(1, window * 0.1))
                self.executeStages(plan.stages, outgoing: outgoing, incoming: incoming)
            } else {
                self.beginDefaultTransition(
                    outgoing: outgoing,
                    incoming: incoming,
                    window: window,
                    announceAsMix: announceAsMix,
                    filterAccent: filterAccent,
                    plan: plan
                )
            }

            let started = Date()
            while !Task.isCancelled {
                let t = min(1, Date().timeIntervalSince(started) / window)
                if announceAsMix { self.mixWindow?.progress = t }
                if t >= 1 { break }
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
            guard !Task.isCancelled else { return }
            self.finishLiveTransition(outgoing: outgoing, incoming: incoming, track: track, index: index)
        }
    }

    private func beginDefaultTransition(
        outgoing: MixEngine.Deck,
        incoming: MixEngine.Deck,
        window: TimeInterval,
        announceAsMix: Bool,
        filterAccent: PhantomDJEngine.Accent?,
        plan: PhantomDJEngine.Plan?
    ) {
        let engine = MixEngine.shared
        engine.setMasterVolume(announceAsMix && window > 1 ? 0.707 : 1, over: min(1, window * 0.1))
        engine.crossfade(to: incoming, over: window)

        let swapAt = plan?.bassSwapAtSeconds ?? (window * 0.55)
        let swapOver = plan?.bassSwapSeconds ?? min(0.5, window * 0.2)
        engine.swapBass(
            from: outgoing,
            to: incoming,
            after: min(max(0, swapAt), max(0, window - swapOver)),
            over: swapOver
        )

        switch filterAccent {
        case .outgoingFilterClose:
            engine.setFilterCutoff(DJEngineConstants.accentClosedFilterHz, on: outgoing, over: window)
        case .incomingFilterOpen:
            engine.setFilterCutoff(MixEngine.filterCutoffRange.upperBound, on: incoming, over: window)
        case nil:
            break
        }
    }

    private func executeStages(
        _ stages: [TransitionStage],
        outgoing: MixEngine.Deck,
        incoming: MixEngine.Deck
    ) {
        for stage in stages.sorted(by: { $0.atSeconds < $1.atSeconds }) {
            let task = Task { @MainActor [weak self] in
                if stage.atSeconds > 0 { try? await Task.sleep(for: .seconds(stage.atSeconds)) }
                guard !Task.isCancelled, self != nil else { return }
                let deck = stage.deck == .outgoing ? outgoing : incoming
                let engine = MixEngine.shared
                switch stage.action {
                case .loop(let bars):
                    engine.setQuantizedLoop(
                        on: deck,
                        near: engine[deck].position,
                        beats: max(1, bars * 4)
                    )
                case .clearLoop:
                    engine.clearLoop(on: deck)
                case .lowPassTo(let hertz, let duration):
                    engine.setFilterCutoff(hertz, on: deck, over: duration)
                case .highPassTo(let hertz, let duration):
                    engine.setHighPassCutoff(hertz, on: deck, over: duration)
                case .eqLow(let decibels, let duration):
                    engine.setEQ(.low, on: deck, toDecibels: decibels, over: duration)
                case .delayWet(let mix, let feedback, let duration):
                    engine.setDelayWet(
                        mix,
                        feedback: feedback,
                        beatSeconds: engine.beatGrid(for: deck)?.beatPeriod,
                        on: deck,
                        over: duration
                    )
                case .crossfadeTo(let position, let duration):
                    if stage.deck == .incoming, !engine[incoming].isPlaying {
                        engine.play(deck: incoming)
                    }
                    engine.crossfade(to: position, over: duration)
                case .rateRatio(let ratio, let duration):
                    engine.setRate(ratio, on: deck, over: duration)
                case .hardCut(let fade):
                    if !engine[incoming].isPlaying { engine.play(deck: incoming) }
                    engine.crossfade(to: incoming, over: fade)
                }
            }
            transitionStageTasks.append(task)
        }
    }

    private func outgoingBeatGrid() -> BeatGrid? {
        if let grid = MixEngine.shared.beatGrid(for: liveDeck) { return grid }
        if let grid = adaptiveMixPlan?.outgoingBeatGrid { return grid }
        guard let track = currentTrack else { return nil }
        guard case .analyzed(let analysis) = DJTransitionService.shared.state(for: track.id),
              !analysis.isEstimated, let bpm = analysis.bpm else { return nil }
        return BeatGrid.fromDisplayBPM(bpm, confidence: 0.7)
    }

    private func applyBeatMatch(
        outgoing: MixEngine.Deck,
        incoming: MixEngine.Deck,
        to track: Track,
        plan: PhantomDJEngine.Plan? = nil
    ) {
        let engine = MixEngine.shared
        let budget = djProfile?.maxAbsRatePercent ?? MixEngine.maxTempoMatchPercent

        if let ratio = plan?.incomingRateRatio, abs(ratio - 1) > 0.0005 {
            engine.setRateRatio(ratio, on: incoming, maxPercent: budget)
            return
        }
        if plan != nil {
            engine.setRate(1, on: incoming)
            return
        }

        guard let from = currentTrack else { return }
        let dj = DJTransitionService.shared
        guard case .analyzed(let a) = dj.state(for: from.id),
              case .analyzed(let b) = dj.state(for: track.id),
              !a.isEstimated, !b.isEstimated,
              let sourceBPM = b.bpm, let targetBPM = a.bpm
        else {
            engine.setRate(1, on: incoming)
            return
        }
        engine.matchTempo(on: incoming, sourceBPM: sourceBPM, targetBPM: targetBPM, maxPercent: budget)
    }

    private func finishLiveTransition(
        outgoing: MixEngine.Deck,
        incoming: MixEngine.Deck,
        track: Track,
        index: Int
    ) {
        let engine = MixEngine.shared

        if let outgoingId = currentTrack?.id, let used = phantomPlanCache[outgoingId]?.templateId {
            recentTemplates.insert(used, at: 0)
            if recentTemplates.count > 8 { recentTemplates.removeLast() }
        }

        engine.crossfade(to: incoming, over: 0)
        if engine.masterVolume < 0.999 {
            engine.setMasterVolume(1, over: 2)
        }
        engine.pause(deck: outgoing)
        engine.unload(deck: outgoing)
        engine.resetProcessing(on: outgoing)
        if engine[incoming].loopLengthSeconds != nil { engine.clearLoop(on: incoming) }
        engine.resetEQ(on: incoming)
        engine.openFilter(on: incoming)
        engine.setHighPassCutoff(MixEngine.filterCutoffRange.lowerBound, on: incoming)
        engine.setDelayWet(0, feedback: 0, on: incoming)
        if abs(engine[incoming].rate - 1) > 0.001 {
            engine.setRate(1, on: incoming, over: 8)
        }

        for task in transitionStageTasks { task.cancel() }
        transitionStageTasks.removeAll()

        liveDeck = incoming
        armedTrackId = track.id
        incomingTrackId = nil
        incomingDeck = .idle
        isCrossfading = false
        mixWindow = nil
        deckEndHandled = false

        currentIndex = queue.firstIndex(of: track) ?? min(max(0, index), max(0, queue.count - 1))
        currentTrack = track
        duration = engine[incoming].duration > 0 ? engine[incoming].duration : track.duration
        currentTime = engine[incoming].position
        isPlaying = engine[incoming].isPlaying
        isLoading = false
        DownloadManager.shared.markPlayed(trackId: track.id)

        updateNowPlayingMetadata()
        DJTransitionService.shared.analyzeUpcoming(in: queue, from: currentIndex)
        prepareIncomingDeck()
        refreshPhantomPlan()
    }

    private func observeMixEngine() {
        guard mixEngineObserver == nil else { return }
        mixEngineTouched = true
        mixEngineObserver = MixEngine.shared.$decks
            // Audio-unit automation can write several parameters at 60 Hz.
            // The renderer needs that resolution; transport/UI telemetry does
            // not. Coalescing here prevents hundreds of main-view invalidations
            // per second during a multi-stage transition.
            .throttle(for: .milliseconds(50), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] decks in
                self?.mixEngineDidTick(decks)
            }
        mixEngineErrorObserver = MixEngine.shared.$lastError
            .sink { [weak self] error in
                self?.mixEngineErrorDidChange(error)
            }
    }

    private func mixEngineErrorDidChange(_ error: MixEngineError?) {
        guard let error, djSessionEnabled else { return }
        guard mixEngineState != .off else { return }
        mixEngineState = .unavailable(Self.describeMixFailure(error))
    }

    private func mixEngineDidTick(_ deckStates: [MixEngine.DeckState]) {
        guard deckStates.count == MixEngine.Deck.allCases.count else { return }

        if case .preparing = mixEngineState {
            let armingDeck = deckStates[MixEngine.Deck.a.rawValue]
            if armingDeck.trackId == armingTrackId, case .loading(let fraction) = armingDeck.status {
                let nextState = MixEngineState.preparing(fraction)
                if mixEngineState != nextState { mixEngineState = nextState }
            }
        }

        let other = deckStates[liveDeck.other.rawValue]
        if let wanted = incomingTrackId, other.trackId == wanted {
            switch other.status {
            case .loading(let fraction):
                let nextState = IncomingDeckState.loading(fraction)
                if incomingDeck != nextState { incomingDeck = nextState }
            case .ready:
                if incomingDeck != .ready { incomingDeck = .ready }
            case .failed(let message):
                let nextState = IncomingDeckState.failed(message)
                if incomingDeck != nextState { incomingDeck = nextState }
            case .empty:                 break
            }
        }

        guard isMixEngineLive else { return }

        let live = deckStates[liveDeck.rawValue]
        if live.duration > 0, duration != live.duration { duration = live.duration }
        // Deck metering changes at 20 Hz. Publishing that rate through the
        // app-wide player object redraws every observer, even while the user
        // is browsing another tab. Transport controls interpolate locally, so
        // match the normal AVPlayer cadence instead.
        let now = Date()
        if now.timeIntervalSince(lastMixEngineTransportUpdate) >= Self.mixEngineTransportUpdateInterval {
            lastMixEngineTransportUpdate = now
            currentTime = live.position
        }
        let playing = live.isPlaying || isCrossfading
        if isPlaying != playing { isPlaying = playing }
        persistSessionState()
        let whole = Int(live.position)
        if whole != lastNowPlayingSecond {
            lastNowPlayingSecond = whole
            updateNowPlayingProgress()
        }

        if isPhantomEnabled {
            updatePhantomTick(live: live)
        } else if isAutoMixDue(live: live) {
            Task { @MainActor [weak self] in self?.startAutoMixIfStillDue() }
        }

        if !isCrossfading,
           !deckEndHandled,
           !live.isPlaying,
           live.status == .ready,
           live.duration > 0,
           live.position >= live.duration - 0.35 {
            deckEndHandled = true
            Task { @MainActor [weak self] in
                await self?.handlePlaybackEnded()
            }
        }
    }

    private func isAutoMixDue(live: MixEngine.DeckState) -> Bool {
        guard djSessionEnabled, isAutoMixEnabled else { return false }
        guard !isCrossfading, mixWindow == nil else { return false }
        guard isMixEngineLive, incomingDeck.isReady else { return false }
        guard let next = upcomingTrack, incomingTrackId == next.id else { return false }
        guard let seconds = effectiveMixSeconds() else { return false }
        let total = live.duration > 0 ? live.duration : duration
        guard total > 0 else { return false }
        return live.position >= max(0, total - seconds)
    }

    private func effectiveMixSeconds() -> TimeInterval? {
        if let seconds = plannedMixSeconds() { return seconds }
        guard autoMixSettingEnabled, upcomingTrack != nil else { return nil }
        return SettingsStore.shared.djTransitionLengthSeconds
    }

    private func startAutoMixIfStillDue() {
        guard isMixEngineLive, !isCrossfading, mixWindow == nil else { return }
        guard isAutoMixDue(live: MixEngine.shared[liveDeck]) else { return }
        guard let next = upcomingTrack, let index = nextQueueIndex() else { return }
        guard let seconds = effectiveMixSeconds() else { return }

        performLiveTransition(to: next, at: index, over: seconds, announceAsMix: true)
    }

    private func handBackToAVPlayer() {
        guard isMixEngineLive, let track = currentTrack else {
            endMixSession()
            return
        }
        let resumeAt = currentTime
        endMixSession()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadAndPlay(track: track)
            self.seek(to: resumeAt)
        }
    }

    private func endMixSession() {
        armTask?.cancel();      armTask = nil
        incomingTask?.cancel(); incomingTask = nil
        mixTask?.cancel();      mixTask = nil
        for task in transitionStageTasks { task.cancel() }
        transitionStageTasks.removeAll()

        armingTrackId = nil
        armedTrackId = nil
        incomingTrackId = nil
        incomingDeck = .idle
        isCrossfading = false
        deckEndHandled = false
        mixWindow = nil
        liveDeck = .a

        for task in phantomPlanTasks.values { task.cancel() }
        phantomPlanTasks.removeAll()
        phantomPlanCache.removeAll()
        phantomCutAnnounced = false
        recentTemplates.removeAll()
        phantomActivity = .idle

        mixEngineState = .off
        if mixEngineTouched {
            MixEngine.shared.stop()
        }
    }

    private func teardownAVPlayer() {
        #if !os(macOS)
        if #available(iOS 27.0, tvOS 27.0, *) {
            player?.setDisconnectedFromSystemAudio(true)
        }
        #endif

        if let observer = timeObserver, let player {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil
        cancellables.removeAll()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        standbyItems.removeAll()
        loadGeneration &+= 1
    }

    private static func resolveMixURL(for track: Track, collectionId: String?) async throws -> URL {
        guard let source = mixSource(for: track, collectionId: collectionId) else {
            throw MixEngineError.unsupportedFormat(
                "SoundCloud only offers Opus for this track, and AVFoundation has no Opus decoder"
            )
        }

        let token = SoundCloudAPI.credentials?.accessToken
        let url = SoundCloudAPI.sanitized(source.url, isAuthenticated: token != nil)

        var request = URLRequest(url: url)
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.addValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            throw MixEngineError.cancelled
        } catch {
            throw MixEngineError.networkFailure(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MixEngineError.httpStatus(http.statusCode)
        }

        struct StreamResponse: Decodable { let url: String }
        guard let decoded = try? JSONDecoder().decode(StreamResponse.self, from: data),
              let resolved = URL(string: decoded.url) else {
            throw MixEngineError.networkFailure("SoundCloud returned no stream URL for the mix source.")
        }
        return resolved
    }

    private static func mixSource(for track: Track, collectionId: String?) -> Transcoding? {
        let decodable = track.transcodings.filter { $0.codec != .opus }
        let ceiling = CollectionQualityOverrideStore.shared.effectiveCeiling(
            for: collectionId ?? track.id,
            default: SettingsStore.shared.streamingQualityCeiling
        )
        return ceiling.bestTranscoding(among: decodable)
    }

    private static func mixCacheKey(for track: Track, collectionId: String?) -> String {
        "track-\(track.id)-\(mixSource(for: track, collectionId: collectionId)?.preset ?? "default")"
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let mixError = error as? MixEngineError, mixError == .cancelled { return true }
        return false
    }

    private static func describeMixFailure(_ error: Error) -> String {
        if let mixError = error as? MixEngineError {
            return mixError.errorDescription ?? "Audio could not be prepared for mixing."
        }
        if error is CancellationError { return "Preparation was cancelled." }
        if let api = error as? APIError { return api.errorDescription ?? error.localizedDescription }
        return error.localizedDescription
    }

}
