import Foundation
import AVFoundation
#if os(iOS)
import UIKit
#endif
import Observation
import Combine
import Accelerate
import MusicUnderstanding
import os

@MainActor
protocol PlatformLifecycleObserver: AnyObject {
    func observeSessionCheckpoints(handler: @escaping @MainActor () -> Void) -> AnyCancellable
}


enum IncomingDeckState: Equatable {
    case idle
    case loading(Double)
    case ready
    case failed(String)

    var isReady: Bool { self == .ready }
}

/// A deliberately narrow, Observation-native projection for list rows and
/// cards. PlayerService also publishes elapsed time, so observing it directly
/// makes an otherwise static collection redraw twice a second during playback.
@MainActor
@Observable
final class PlaybackIndicatorStore {
    static let shared = PlaybackIndicatorStore()

    private(set) var trackID: String?
    private(set) var isPlaying = false
    private(set) var isLoading = false

    @ObservationIgnored private var cancellables = Set<AnyCancellable>()

    private init(player: PlayerService = .shared) {
        player.$currentTrack
            .map { $0?.id }
            .removeDuplicates()
            .sink { [weak self] in self?.trackID = $0 }
            .store(in: &cancellables)
        player.$isPlaying
            .removeDuplicates()
            .sink { [weak self] in self?.isPlaying = $0 }
            .store(in: &cancellables)
        player.$isLoading
            .removeDuplicates()
            .sink { [weak self] in self?.isLoading = $0 }
            .store(in: &cancellables)
    }

    func isCurrent(_ trackID: String) -> Bool { self.trackID == trackID }
}

/// Queue-only projection used by queue surfaces that do not display elapsed
/// time. Keeping it separate from PlaybackIndicatorStore also means a play /
/// pause transition does not rebuild every queue row.
@MainActor
@Observable
final class PlaybackQueueStore {
    static let shared = PlaybackQueueStore()

    private(set) var queue: [Track] = []
    private(set) var currentIndex = 0
    private(set) var currentArtworkURL: URL?

    @ObservationIgnored private var cancellables = Set<AnyCancellable>()

    private init(player: PlayerService = .shared) {
        player.$queue
            .removeDuplicates { $0.map(\.id) == $1.map(\.id) }
            .sink { [weak self] in self?.queue = $0 }
            .store(in: &cancellables)
        player.$currentIndex
            .removeDuplicates()
            .sink { [weak self] in self?.currentIndex = $0 }
            .store(in: &cancellables)
        player.$currentTrack
            .map { $0?.artworkURL }
            .removeDuplicates()
            .sink { [weak self] in self?.currentArtworkURL = $0 }
            .store(in: &cancellables)
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

enum DJTransitionPlanningPolicy {
    static func shouldPlan(
        isEnabled: Bool,
        sessionIsEnabled: Bool,
        hasCurrentTrack: Bool,
        hasUpcomingTrack: Bool
    ) -> Bool {
        isEnabled && sessionIsEnabled && hasCurrentTrack && hasUpcomingTrack
    }

    static func startsInMixEngine(
        sessionIsEnabled: Bool,
        exclusiveElsewhere: Bool,
        trackDuration: TimeInterval,
        isLoadedOnDeck: Bool,
        fellBackToAVPlayer: Bool
    ) -> Bool {
        guard sessionIsEnabled, !exclusiveElsewhere, !fellBackToAVPlayer else { return false }
        return isLoadedOnDeck || CollectionKind.classify(trackDurationSeconds: trackDuration) != .set
    }
}


@MainActor
final class PlayerService: ObservableObject, DJTransitionServiceDelegate {
    static let shared = PlayerService(
        sourceResolver: .shared,
        transitionService: .shared,
        downloads: .shared,
        api: .shared,
        cues: .shared
    )

    let sourceResolver: PlaybackSourceResolver
    let transitionService: DJTransitionService
    let downloads: DownloadManager
    private let api: SoundCloudAPI
    let cues: CueStore

    private(set) var peerContentSource: (any PeerContentSessionProvider)?
    private(set) var nowPlaying: any SystemNowPlayingBridge = MediaPlayerNowPlayingBridge()
    private var systemRemoteHandlers: SystemTransportHandlers?
    private weak var lifecycleObserver: (any PlatformLifecycleObserver)?

    /// Platform integrations enter playback once, through the process runtime.
    /// Features can no longer replace global static hooks while audio is live.
    func configurePlatform(
        nowPlaying bridge: (any SystemNowPlayingBridge)? = nil,
        lifecycleObserver: (any PlatformLifecycleObserver)? = nil
    ) {
        if let bridge, bridge !== nowPlaying {
            nowPlaying.deactivate()
            nowPlaying = bridge
            if let systemRemoteHandlers {
                nowPlaying.activate(handlers: systemRemoteHandlers)
            } else {
                activateNowPlayingBridge()
            }
        }
        self.lifecycleObserver = lifecycleObserver
        observeAppLifecycle()
    }

    func connectNearbyPlayback(peerContentSource: (any PeerContentSessionProvider)?) {
        self.peerContentSource = peerContentSource
    }

    @Published private(set) var currentTrack: Track? {
        didSet {
            PlayHistoryRecorder.shared.attach(to: self)
            if oldValue?.id != currentTrack?.id {
                ListeningRecorder.shared.noteTrackStarted(currentTrack?.id)
                if let id = currentTrack?.id { PlayedTrackLog.shared.note(id) }
                playingNext.prune(queue: queue.map(\.id), currentIndex: currentIndex)
                persistSessionState(force: true)
            }
        }
    }
    @Published private(set) var playingNext = PlayingNextQueue()
    @Published private(set) var queue: [Track] = [] {
        didSet { queueStateDidChange() }
    }
    @Published private(set) var currentIndex: Int = 0 {
        didSet { queueStateDidChange() }
    }
    @Published private(set) var isPlaying = false
    /// Per-tick playback position/duration live here so observing PlayerService
    /// does not invalidate every view twice a second. Progress UI observes the
    /// clock; imperative readers use the computed properties below.
    let clock = PlaybackClock()
    var currentTime: TimeInterval { clock.currentTime }
    var duration: TimeInterval { clock.duration }
    @Published private(set) var isLoading = false
    @Published private(set) var loadingState: PlaybackLoadingState = .idle
    @Published private(set) var mediaOrigin: PlaybackMediaOrigin?
    @Published private(set) var playbackErrorMessage: String?
    @Published private(set) var hasResolvedLaunchRestore = false
    @Published var entitlementPrompt: SoundCloudEntitlementError?
    @Published private(set) var isPlayingSoundCloudPreview = false
    private var hasShownPreviewEndedPrompt = false
    /// Increments only for a user-selected track, never for automatic queue
    /// advancement. Shells use this to present Now Playing at the right time.
    @Published private(set) var explicitPlayRequest: UInt64 = 0
    @Published var isShuffleEnabled = false {
        didSet { persistSessionState(force: true) }
    }
    @Published var repeatMode: RepeatMode = .off {
        didSet { queueStateDidChange() }
    }
    @Published private(set) var outputRoute: AudioOutputRoute = .unknown
    @Published private(set) var activeCollectionId: String?
    @Published private(set) var queueSource: PlaybackQueueSource?
    @Published private(set) var volume: Double = PlayerService.storedVolume()
    private var loudnessGain: Double = 1
    var streamLoudnessGain: Double { loudnessGain }
    private var sleepFadeGain: Double = 1

    // The Decks session state below is driven by DJSessionDirector; the
    // published properties stay here so existing observers see the exact
    // same values at the same times.
    @Published var mixEngineState: MixEngineState = .off
    @Published var incomingDeck: IncomingDeckState = .idle
    @Published var mixWindow: MixWindow?
    @Published var isAutoMixEnabled = false
    @Published private(set) var isExternalManualDeckControlActive = false

    @Published var djProfile: DJProfile? {
        didSet {
            guard djProfile != oldValue else { return }
            djDirector.profileDidChange()
        }
    }

    var isPhantomEnabled: Bool {
        get { djProfile != nil }
        set { djProfile = newValue ? (djProfile ?? defaultDJProfile) : nil }
    }
    @Published var phantomActivity: PhantomActivity = .idle

    @Published var liveDeck: MixEngine.Deck = .a

    /// The single value-type read model for the Decks session, mirrored from
    /// the director so consoles can observe it through the player they
    /// already know. See DJSessionSnapshot.swift.
    @Published private(set) var djSessionSnapshot: DJSessionSnapshot?

    /// Owns the Decks session: lifecycle, deck arming/preload, plan cache,
    /// adaptive replanning, stage scheduling, mix-window and fallback policy.
    /// PlayerService keeps the playback plumbing and forwards its public DJ
    /// API to the director with unchanged signatures.
    lazy var djDirector: DJSessionDirector = DJSessionDirector(host: self)

    var isMixEngineLive: Bool { mixEngineState == .live }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }

    func localAudioURL(for track: Track) -> URL? {
        for deck in MixEngine.Deck.allCases where MixEngine.shared[deck].trackId == track.id {
            if let url = MixEngine.shared.localFileURL(for: deck) { return url }
        }
        return nil
    }

    func preparedLocalAudioURL(for track: Track) async -> URL? {
        for deck in MixEngine.Deck.allCases where MixEngine.shared[deck].trackId == track.id {
            if let url = MixEngine.shared.localFileURL(for: deck) { return url }
        }
        return nil
    }

    private var externalManualResume: (track: Track, position: TimeInterval, wasPlaying: Bool)?
    private var parkedPlayback: (trackID: String, player: AVPlayer, origin: PlaybackMediaOrigin)?

    private struct PreviewSession {
        let track: Track?
        let position: TimeInterval
        let wasPlaying: Bool
        let queue: [Track]
        let originalQueue: [Track]
        let currentIndex: Int
    }
    private var previewSession: PreviewSession?

    /// Auditions audio through the same transport, source resolver, cache, and
    /// AVPlayer as ordinary playback. The original queue session is restored
    /// by `endPreviewPlayback`; callers never create a second audio renderer.
    func beginPreviewPlayback(of track: Track, at position: TimeInterval = 0) async {
        if previewSession == nil {
            previewSession = PreviewSession(
                track: currentTrack,
                position: currentTime,
                wasPlaying: playbackRequested || isPlaying,
                queue: queue,
                originalQueue: originalQueue,
                currentIndex: currentIndex
            )
        }
        await loadAndPlay(track: track, startPosition: max(0, position))
    }

    func endPreviewPlayback(resumeOriginal: Bool = true) async {
        guard let preview = previewSession else { return }

        // Keep persistence suppressed until the original queue and selection
        // are coherent again. loadAndPlay will publish the restored snapshot.
        originalQueue = preview.originalQueue
        queue = preview.queue
        currentIndex = preview.currentIndex
        previewSession = nil

        guard let track = preview.track else {
            clearQueue()
            return
        }
        await loadAndPlay(
            track: track,
            startPosition: preview.position,
            transportIntent: resumeOriginal && preview.wasPlaying ? .play : .pause
        )
    }

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
        djDirector.endMixSession()
        teardownAVPlayer()
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
            await self.loadAndPlay(
                track: resume.track,
                startPosition: resume.position,
                transportIntent: resume.wasPlaying ? .play : .pause
            )
        }
    }

    private var player: AVPlayer? {
        didSet { if player !== oldValue { avPlayerDidChange.send(player) } }
    }
    let avPlayerDidChange = PassthroughSubject<AVPlayer?, Never>()
    let seekEvents = PassthroughSubject<TimeInterval, Never>()
    /// The director reads the live playhead and pauses/resumes the AVPlayer
    /// during deck takeover; ownership of the player itself stays here.
    var avPlayer: AVPlayer? { player }
    private var playbackPipeline = PlaybackPipeline()
    var playbackRequested: Bool { playbackPipeline.wantsPlayback }
    private var playbackLoadTiming: (token: PlaybackPipeline.Token, startedAt: Date)?
    private var bufferingWatchdogTask: Task<Void, Never>?
    private var recoveringToken: PlaybackPipeline.Token?
    private var cacheableStream: (trackID: String, url: URL, transcoding: Transcoding?)?

    @Published private(set) var observedStalls = 0
    private var timeObserver: Any?
    /// Fires once, at a small time offset, to move the pipeline from buffering
    /// to playing as soon as the playhead actually advances. This prevents the
    /// UI from starting its wall-clock animation before audio is audible.
    private var playbackStartObserver: Any?
    /// Set for the duration of an AVPlayer seek so the periodic time observer
    /// does not clamp the published position back up to the pre-seek playhead.
    private var seekInFlight = false
    private var seekGeneration: UInt64 = 0
    private var queuedSeekTarget: TimeInterval?
    private var seekStartedAt: Date?
    private var cancellables = Set<AnyCancellable>()
    private var originalQueue: [Track] = []
    private var activeDJStartConfiguration: DJStartConfiguration?
    private var goodMatchDiscoveryTask: Task<Void, Never>?

    enum LoadTransportIntent {
        case play
        case pause
        case preserve
    }

    private static let maximumMediaRecoveryAttempts = 1

    enum MixTransportPhase {
        case buffering
        case playing
        case paused
    }

    func publishMixEngineTransport(_ phase: MixTransportPhase, trackID: String) {
        let target: PlaybackPipeline.Phase
        switch phase {
        case .buffering: target = .buffering(trackID: trackID)
        case .playing: target = .playing(trackID: trackID)
        case .paused: target = .paused(trackID: trackID)
        }
        guard playbackPipeline.phase != target else { return }
        playbackPipeline.transitionCurrent(to: target)
        syncPublishedPlaybackState()
    }

    var currentTrackBelongsInMixEngine: Bool {
        currentTrack.map(startsInMixEngine) ?? false
    }

    private func startsInMixEngine(_ track: Track) -> Bool {
        guard !playsAsSoundCloudPreview(track) else { return false }
        return djDirector.ownsTrackStart(
            track,
            exclusiveElsewhere: previewSession != nil || isExternalManualDeckControlActive
        )
    }

    /// The deck handoff commits the queue position and current track together,
    /// like an automatic queue advance.
    func adoptIncomingTrack(_ track: Track, at index: Int) {
        if parkedPlayback?.trackID != track.id { discardParkedPlayback() }
        currentIndex = queue.firstIndex(of: track) ?? min(max(0, index), max(0, queue.count - 1))
        currentTrack = track
    }

    private func syncPublishedPlaybackState() {
        isPlaying = playbackPipeline.isPlaying
        isLoading = playbackPipeline.isLoading
        loadingState = playbackPipeline.loadingState
        if isPlaying || !playbackPipeline.wantsPlayback { endTrackChangeBackgroundTask() }
    }

    #if os(iOS)
    private var trackChangeBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    private func beginTrackChangeBackgroundTask() {
        guard trackChangeBackgroundTask == .invalid,
              UIApplication.shared.applicationState != .active else { return }
        trackChangeBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "track-change") { [weak self] in
            self?.endTrackChangeBackgroundTask()
        }
    }

    private func endTrackChangeBackgroundTask() {
        guard trackChangeBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(trackChangeBackgroundTask)
        trackChangeBackgroundTask = .invalid
    }
    #else
    private func beginTrackChangeBackgroundTask() {}
    private func endTrackChangeBackgroundTask() {}
    #endif

    @discardableResult
    private func transitionPlayback(
        to phase: PlaybackPipeline.Phase,
        for token: PlaybackPipeline.Token
    ) -> Bool {
        guard playbackPipeline.transition(phase, for: token) else { return false }
        syncPublishedPlaybackState()
        return true
    }

    private func transitionToPlayingIfBuffering(trackID: String, token: PlaybackPipeline.Token) {
        guard case .buffering = playbackPipeline.phase else { return }
        syncClockFromPlayer()
        _ = transitionPlayback(to: .playing(trackID: trackID), for: token)
        removePlaybackStartObserver()
        if let seekStartedAt, Date().timeIntervalSince(seekStartedAt) < 15 {
            Log.player.notice(
                "[Player] playing again \(Int(Date().timeIntervalSince(seekStartedAt) * 1_000), privacy: .public) ms after a seek"
            )
        }
        seekStartedAt = nil
    }

    private func installPlaybackStartObserver(
        player: AVPlayer,
        playerItem: AVPlayerItem,
        track: Track,
        token: PlaybackPipeline.Token
    ) {
        guard case .buffering = playbackPipeline.phase else { return }
        removePlaybackStartObserver()
        let current = player.currentTime().seconds
        let start = current.isFinite ? max(0, current) : 0
        let threshold = CMTime(seconds: start + 0.05, preferredTimescale: 600)
        playbackStartObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: threshold)],
            queue: .main
        ) { [weak self] in
            Task { @MainActor in
                guard let self,
                      self.playbackPipeline.accepts(token),
                      self.player?.currentItem === playerItem else { return }
                self.transitionToPlayingIfBuffering(trackID: track.id, token: token)
            }
        }
    }

    private func removePlaybackStartObserver() {
        if let observer = playbackStartObserver, let player {
            player.removeTimeObserver(observer)
        }
        playbackStartObserver = nil
    }

    private var peerContentClient: PeerContentClient?
    private var peerContentDelegate: PeerContentAssetLoaderDelegate?

    private var warmDebounceTask: Task<Void, Never>?
    private var queueSideEffectsSuspended = false
    private var pendingCollectionPolicy: (tracks: [Track], collectionId: String)?
    private var persistFlushTask: Task<Void, Never>?

    /// One resolved, validated player item is kept for the focused or next
    /// track. Do not call `AVPlayer.preroll` for speculative playback: the
    /// 27.0 AVFoundation runtimes can raise an Objective-C exception from that
    /// API, which Swift cannot catch, and cancelling rapid hover/focus prerolls
    /// has also produced invalid-object crashes on macOS. Loading the asset and
    /// constructing its item still moves authentication, manifest inspection,
    /// and item setup ahead of the play press without creating a second player.
    private struct PreparedPlayback {
        let trackID: String
        let url: URL
        let item: AVPlayerItem
        let preparedAt: Date
    }

    private var preparedPlayback: PreparedPlayback?
    private var preparedPlaybackTask: Task<Void, Never>?
    private var preparedPlaybackGeneration: UInt64 = 0
    private var nextPrewarmRefreshTrackID: String?

    private var djModeRequested = false
    var autoMixSettingEnabled = false
    private var collectionAutoMixRequested = false
    private var activeCollectionPolicy: CollectionPolicy?

    var autoMixExplicitQueueOrders: [DJQueueOrderPolicy?] {
        [activeCollectionPolicy?.queueOrder, activeDJStartConfiguration?.queueOrder]
    }
    var djSessionEnabled: Bool {
        (djModeRequested || autoMixSettingEnabled || collectionAutoMixRequested) && !isMixingSuspendedForGroupSession
    }
    private(set) var isMixingSuspendedForGroupSession = false

    func setMixingSuspendedForGroupSession(_ suspended: Bool) {
        guard suspended != isMixingSuspendedForGroupSession else { return }
        let before = djSessionEnabled
        isMixingSuspendedForGroupSession = suspended
        applySessionEnabledTransition(from: before, primeAnalysis: !suspended)
        objectWillChange.send()
    }
    @Published private(set) var requiresMixEngineOutput = false

    func setRequiresMixEngineOutput(_ required: Bool) async {
        guard required != requiresMixEngineOutput else { return }
        requiresMixEngineOutput = required
        player?.volume = required ? 0 : Float(loudnessGain * volume * sleepFadeGain)
        guard required, let track = currentTrack, !isMixEngineLive else { return }
        await loadAndPlay(track: track, startPosition: currentTime, transportIntent: playbackRequested ? .play : .pause)
    }
    private var sessionCancellables = Set<AnyCancellable>()
    private var lifecycleCancellable: AnyCancellable?
    private var wasPlayingBeforeInterruption = false

    private var isRestoringSession = false
    private var lastPersistedAt: Date = .distantPast
    private var pendingRestore: (track: Track, position: TimeInterval)?
    private var restoreTask: Task<Void, Never>?
    private var sessionAccountID: String?
    private var restoreLedger: PlaybackRestoreLedger?
    private var restoredOriginalIds: [String]?
    private var defaultDJSourceTask: Task<Void, Never>?

    init(
        sourceResolver: PlaybackSourceResolver,
        transitionService: DJTransitionService,
        downloads: DownloadManager,
        api: SoundCloudAPI,
        cues: CueStore
    ) {
        self.sourceResolver = sourceResolver
        self.transitionService = transitionService
        self.downloads = downloads
        self.api = api
        self.cues = cues
        #if DEBUG
        setvbuf(stdout, nil, _IONBF, 0)
        #endif
        transitionService.delegate = self
        // Force the lazy director into existence before the settings observer
        // can assign djProfile (its didSet forwards to the director), and give
        // the legacy readouts their plan projection from the single plan model.
        _ = djDirector
        transitionService.planProvider = { [weak self] from, to in
            self?.djDirector.legacyTransitionProjection(from: from, to: to)
        }
        djDirector.$snapshot
            .removeDuplicates()
            .assign(to: &$djSessionSnapshot)
        setupAudioSession()
        activateNowPlayingBridge()
        observeAudioSessionNotifications()
        observeAppLifecycle()
        observeAuthenticatedAccount()
        observeAutoMixSetting()
        observeTrackTrims()
        #if DEBUG
        installAutoplayDebugHook()
        #endif
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

        PlatformAudioSession.routeChanges
            .sink { [weak self] change in self?.handleRouteChange(change) }
            .store(in: &sessionCancellables)
    }

    #if canImport(UIKit)
    @available(iOS 27.0, tvOS 27.0, *)
    private func handleSessionDidBecomeInactive(_ note: Notification) {
        guard let context = note.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext,
              context.source == .system else { return }
        wasPlayingBeforeInterruption = wasPlayingBeforeInterruption || playbackRequested || isPlaying
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
        // The enum wrappers are deprecated in SDK 27 even though iOS 26.5
        // still needs the legacy notification. Read the stable notification
        // payload values directly so the current SDK path remains warning-free.
        guard let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
        switch rawType {
        case 1: // AVAudioSessionInterruptionTypeBegan
            wasPlayingBeforeInterruption = wasPlayingBeforeInterruption || playbackRequested || isPlaying
            pause()
        case 0: // AVAudioSessionInterruptionTypeEnded
            let shouldResume = wasPlayingBeforeInterruption
            wasPlayingBeforeInterruption = false
            guard shouldResume else { return }
            let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            guard rawOptions & 1 != 0 else { return } // AVAudioSessionInterruptionOptionShouldResume
            PlatformAudioSession.activatePlayback()
            play()
        default:
            break
        }
    }
    #endif

    private func handleRouteChange(_ change: AudioOutputRouteChange) {
        refreshOutputRoute()
        if change.shouldPausePlayback { pause() }
    }

    private func observeAppLifecycle() {
        lifecycleCancellable?.cancel()
        lifecycleCancellable = nil
        guard let observer = lifecycleObserver else { return }
        lifecycleCancellable = observer.observeSessionCheckpoints { [weak self] in
            self?.syncClockFromPlayer()
            self?.writeSessionState()
        }
    }

    private func activateNowPlayingBridge() {
        #if DEBUG
        print("[NowPlaying] activating bridge: \(type(of: nowPlaying))")
        #endif
        nowPlaying.activate(handlers: SystemTransportHandlers(
            play: { [weak self] in self?.play() },
            pause: { [weak self] in self?.pause() },
            togglePlayPause: { [weak self] in self?.togglePlayPause() },
            next: { [weak self] in await self?.playNext() },
            previous: { [weak self] in await self?.playPrevious() },
            seek: { [weak self] time in
                guard let self else { return }
                let timeline = self.trimTimeline
                self.seek(to: timeline.isTrimmed ? timeline.position(atElapsed: time) : time)
            }
        ))
        updateNowPlayingMetadata()
    }

    private func refreshRemoteTransportAvailability() {
        guard systemRemoteHandlers == nil else { return }
        nowPlaying.publishTransportAvailability(hasNext: nextQueueIndex() != nil)
    }

    var isSystemNowPlayingRouted: Bool { systemRemoteHandlers != nil }

    func routeSystemNowPlaying(to handlers: SystemTransportHandlers?) {
        let wasRouted = systemRemoteHandlers != nil
        systemRemoteHandlers = handlers
        if let handlers {
            nowPlaying.activate(handlers: handlers)
        } else if wasRouted {
            activateNowPlayingBridge()
        }
    }

    func publishRoutedNowPlaying(_ item: SystemNowPlayingItem?) {
        guard systemRemoteHandlers != nil else { return }
        nowPlaying.publishNowPlaying(item)
    }

    func publishRoutedPlayback(_ playback: SystemPlaybackStatus, hasNext: Bool) {
        guard systemRemoteHandlers != nil else { return }
        nowPlaying.publishTransportAvailability(hasNext: hasNext)
        nowPlaying.publishPlayback(playback)
    }

    func updateNowPlayingMetadata() {
        guard systemRemoteHandlers == nil else { return }
        guard let track = currentTrack else {
            nowPlaying.publishNowPlaying(nil)
            return
        }
        refreshRemoteTransportAvailability()

        let hasQueuePosition = currentIndex >= 0 && currentIndex < queue.count
        nowPlaying.publishNowPlaying(SystemNowPlayingItem(
            trackId: track.id,
            title: track.title,
            artist: track.user.displayName,
            artworkURL: track.artworkURL,
            queueIndex: hasQueuePosition ? currentIndex : nil,
            queueCount: hasQueuePosition ? queue.count : nil
        ))
        updateNowPlayingProgress()
    }

    func updateNowPlayingProgress() {
        guard systemRemoteHandlers == nil else { return }
        let timeline = trimTimeline
        nowPlaying.publishPlayback(SystemPlaybackStatus(
            elapsed: timeline.isTrimmed ? timeline.elapsed(at: currentTime) : currentTime,
            duration: timeline.isTrimmed ? timeline.length : duration,
            isPlaying: isPlaying
        ))
    }

    // MARK: - Start and end times

    var trimTimeline: TrackTrimTimeline {
        TrackTrimTimeline(
            range: TrackTrimStore.shared.effectiveRange(for: currentTrack?.id ?? "", duration: duration),
            duration: duration
        )
    }

    private func observeTrackTrims() {
        TrackTrimStore.shared.$trims
            .map { [weak self] trims in self?.currentTrack.flatMap { trims[$0.id] } }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.applyTrimToCurrentPlayback() }
            }
            .store(in: &sessionCancellables)
    }

    private func applyTrimToCurrentPlayback() {
        guard let track = currentTrack else { return }
        if let item = player?.currentItem {
            applyTrim(to: item, track: track)
        }
        let timeline = trimTimeline
        if timeline.isTrimmed, !timeline.range.contains(currentTime) {
            seek(to: timeline.clamped(currentTime), expectedTrackID: track.id, intent: .user)
        }
        updateNowPlayingProgress()
    }

    private func applyTrim(to item: AVPlayerItem, track: Track) {
        let range = TrackTrimStore.shared.effectiveRange(for: track)
        if track.duration > 0, range.upperBound < track.duration - 0.05 {
            item.forwardPlaybackEndTime = CMTime(seconds: range.upperBound, preferredTimescale: 600)
        } else {
            item.forwardPlaybackEndTime = .invalid
        }
    }

    #if DEBUG
    private var isVisualFixtureInstalled = false

    /// Installs deterministic UI-only playback state without resolving or
    /// starting audio. Screenshot and resize checks can therefore exercise the
    /// real Now Playing hierarchy while remaining offline and side-effect free.
    func installVisualFixture(track: Track, queue fixtureQueue: [Track], position: TimeInterval, playingNextCount: Int = 0) {
        isVisualFixtureInstalled = true
        player?.pause()
        player = nil
        originalQueue = fixtureQueue
        queue = fixtureQueue
        currentIndex = fixtureQueue.firstIndex(of: track) ?? 0
        currentTrack = track
        playingNext = PlayingNextQueue(leading: playingNextCount, in: fixtureQueue.map(\.id), currentIndex: currentIndex)
        clock.duration = max(track.duration, 0)
        clock.currentTime = min(max(0, position), clock.duration)
        playbackPipeline.begin(trackID: track.id, intent: .pause)
        syncPublishedPlaybackState()
        playbackErrorMessage = nil
    }

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

    func play(_ track: Track, in context: [Track], collectionId: String? = nil, source: PlaybackQueueSource? = nil) async {
        explicitPlayRequest &+= 1
        playbackErrorMessage = nil
        restoreTask?.cancel()
        restoreTask = nil
        restoreLedger = nil
        restoredOriginalIds = nil
        if let source { PlaybackQueueSourceDirectory.note(source) }
        queueSource = source ?? PlaybackQueueSourceDirectory.source(for: collectionId)
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
        playingNext.removeAll()

        queueSideEffectsSuspended = true
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
        queueSideEffectsSuspended = false

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
            pendingCollectionPolicy = (tracks, collectionId)
        } else {
            pendingCollectionPolicy = nil
        }
    }

    private func queueStateDidChange() {
        guard !queueSideEffectsSuspended else { return }
        refreshRemoteTransportAvailability()
        prunePlaybackPreparation()
        persistSessionState(force: true)
    }

    private func djContextEligibility() -> ((Track) -> Bool)? {
        let setHandling: DJSetHandling?
        if let configuration = activeDJStartConfiguration {
            setHandling = configuration.setHandling
        } else if collectionAutoMixRequested, let policy = activeCollectionPolicy {
            setHandling = policy.setHandling
        } else {
            setHandling = nil
        }
        guard let setHandling else { return nil }
        return { track in
            let isSet = CollectionKind.classify(trackDurationSeconds: track.duration) == .set
            switch setHandling {
            case .include:  return true
            case .skip:     return !isSet
            case .onlySets: return isSet
            }
        }
    }

    private func filteredDJContext(_ context: [Track], preserving selected: Track) -> [Track] {
        guard let eligible = djContextEligibility() else { return context }
        var filtered = context.filter(eligible)
        if !filtered.contains(selected) { filtered.insert(selected, at: 0) }
        return filtered
    }

    func loadAndPlay(
        track: Track,
        startPosition: TimeInterval = 0,
        transportIntent: LoadTransportIntent = .play,
        skipLocalFile: Bool = false,
        bypassStreamCache: Bool = false,
        mediaRecoveryAttempt: Int = 0
    ) async {
        djDirector.noteTrackStart(track)
        let ownedByEngine = mediaRecoveryAttempt == 0 && !skipLocalFile && startsInMixEngine(track)
        let streamsFirst = ownedByEngine && djDirector.startsOnStreamFirst(track)
        let startsInEngine = ownedByEngine && !streamsFirst
        if ownedByEngine {
            djDirector.resetForEngineStart(keeping: track)
            if streamsFirst { djDirector.beginStreamingStart(track) }
        } else {
            djDirector.endMixSession()
            if let reason = djDirector.fallbackReason(for: track) {
                mixEngineState = .unavailable(reason)
            }
        }
        let intent: PlaybackPipeline.Intent
        switch transportIntent {
        case .play: intent = .play
        case .pause: intent = .pause
        case .preserve:
            guard playbackRequested else { return }
            intent = playbackPipeline.intent
        }
        let token = playbackPipeline.begin(trackID: track.id, intent: intent)
        playbackLoadTiming = intent == .play ? (token, Date()) : nil
        syncPublishedPlaybackState()
        if intent == .play { beginTrackChangeBackgroundTask() }
        mediaOrigin = nil
        PlatformAudioSession.activatePlayback()

        // A newly selected track must not inherit the previous player's live
        // UI clock while its stream is still being resolved and buffered.
        bufferingWatchdogTask?.cancel()
        bufferingWatchdogTask = nil
        nextPrewarmRefreshTrackID = nil
        if let observer = timeObserver, let player {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
        removePlaybackStartObserver()
        cancellables.removeAll()
        if startsInEngine, currentTrack?.id == track.id {
            parkAVPlayer(trackID: track.id)
        } else if parkedPlayback?.trackID != track.id {
            discardParkedPlayback()
        }
        player?.pause()
        player?.replaceCurrentItem(with: nil)

        // If a pending restore exists for the same track, use its latest
        // position (which may have been updated by seek(to:) after play() was
        // called) and then consume it.
        let requestedStartPosition = if let pending = pendingRestore, pending.track.id == track.id {
            pending.position
        } else {
            startPosition
        }
        let resolvedStartPosition = TrackTrimTimeline(
            range: TrackTrimStore.shared.effectiveRange(for: track),
            duration: track.duration
        ).clamped(PlaybackTimelinePolicy.clampedPosition(requestedStartPosition, duration: track.duration))
        pendingRestore = nil

        playbackErrorMessage = nil
        currentTrack = track
        let playsPreview = playsAsSoundCloudPreview(track)
        isPlayingSoundCloudPreview = playsPreview
        clock.duration = playsPreview && track.previewDuration > 0 ? track.previewDuration : track.duration
        clock.currentTime = max(0, resolvedStartPosition)

        teardownPeerContent()

        Task { @MainActor [weak self] in
            guard let self, self.playbackPipeline.accepts(token) else { return }
            self.queueStateDidChange()
            if let policy = self.pendingCollectionPolicy {
                self.pendingCollectionPolicy = nil
                self.downloads.applyCollectionPolicy(tracks: policy.tracks, collectionId: policy.collectionId)
            }
            if self.previewSession == nil {
                AutomaticAnalysisScheduler.shared.schedule(track, trigger: .played)
            }
            self.applyLoudnessNormalization(for: track)
            if self.previewSession == nil {
                self.downloads.markPlayed(trackId: track.id)
            }
        }

        if startsInEngine {
            teardownAVPlayer(invalidatePipeline: false, keepingParked: true)
            _ = transitionPlayback(
                to: playbackRequested ? .buffering(trackID: track.id) : .paused(trackID: track.id),
                for: token
            )
            updateNowPlayingMetadata()
            djDirector.startTrackInEngine(track, at: resolvedStartPosition) { [weak self] in
                self?.playbackPipeline.accepts(token) ?? false
            }
            return
        }

        if mediaRecoveryAttempt == 0, !skipLocalFile, !bypassStreamCache,
           let parked = await unparkAVPlayer(trackID: track.id) {
            guard playbackPipeline.accepts(token) else { return }
            await playStream(
                asset: parked.asset,
                track: track,
                startPosition: resolvedStartPosition,
                token: token,
                source: parked.origin,
                mediaRecoveryAttempt: mediaRecoveryAttempt,
                preparedItem: parked.item
            )
            return
        }
        discardParkedPlayback()

        do {
            let resolutionStartedAt = Date()
            let prepared = bypassStreamCache ? nil : consumePreparedPlayback(for: track)
            let prefetched = bypassStreamCache ? nil : prepared?.url
            let resolved = try await sourceResolver.playbackSource(
                for: track,
                collectionID: activeCollectionId,
                skipLocalFile: skipLocalFile,
                prefetchedNetworkURL: prefetched,
                useResolutionCache: !bypassStreamCache,
                allowsPreview: allowsSoundCloudPreviews
            )
            guard playbackPipeline.accepts(token) else { return }
            cacheableStream = resolved.origin == .networkStream
                ? (
                    track.id,
                    resolved.url,
                    sourceResolver.transcoding(for: track, collectionID: activeCollectionId, purpose: .streaming)
                )
                : nil
            let resolutionMilliseconds = Int(Date().timeIntervalSince(resolutionStartedAt) * 1_000)
            Log.player.notice(
                "[Player] source resolved for \(track.id, privacy: .public) in \(resolutionMilliseconds, privacy: .public) ms"
            )
            await playStream(
                asset: resolved.makeAsset(),
                track: track,
                startPosition: resolvedStartPosition,
                token: token,
                source: resolved.origin,
                mediaRecoveryAttempt: mediaRecoveryAttempt,
                preparedItem: resolved.origin == .networkStream ? prepared?.item : nil
            )
        } catch {
            guard playbackPipeline.accepts(token) else { return }
            // Paired-device content is the resilience path, not a toll on
            // every tap. Try it only when ordinary stream resolution fails so
            // a sleeping companion can never add its connect/probe timeout to
            // healthy SoundCloud playback.
            if !Self.isCancellation(error), !(error is SoundCloudEntitlementError),
               let peer = await tryPeerContent(for: track) {
                guard playbackPipeline.accepts(token) else {
                    peer.client.disconnect()
                    return
                }
                peerContentClient = peer.client
                peerContentDelegate = peer.delegate
                await playStream(
                    asset: peer.asset,
                    track: track,
                    startPosition: resolvedStartPosition,
                    token: token,
                    source: .peerStream,
                    mediaRecoveryAttempt: mediaRecoveryAttempt
                )
                return
            }
            guard playbackPipeline.accepts(token) else { return }
            if !Self.isCancellation(error) {
                Log.player.error("Failed to get stream URL: \(error.localizedDescription, privacy: .public)")
            }
            finishPlaybackFailure(error, token: token)
            teardownPeerContent()
        }
    }

    private static func describePlaybackFailure(_ error: Error) -> String {
        let offline = "No connection. Downloaded tracks still play offline."
        let generic = "This track couldn't be played."
        func describe(_ urlError: URLError) -> String {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return offline
            case .timedOut:
                return "The stream didn't start in time. Tap play to try again."
            default:
                return generic
            }
        }
        if let urlError = error as? URLError { return describe(urlError) }
        if let apiError = error as? APIError {
            switch apiError {
            case .noStreamURL:
                return "This track is a preview or isn't available to stream. Full playback may need SoundCloud Go+."
            case .unauthorized:
                return "SoundCloud needs you to sign in again before this can play."
            case .forbidden:
                return "SoundCloud won't play this track here. It may be region-locked or need Go+."
            case .notFound:
                return "This track is no longer available."
            case .networkError(let underlying):
                if let urlError = underlying as? URLError { return describe(urlError) }
                return generic
            case .serverError, .decodingError, .invalidURL:
                return generic
            case .rateLimited, .temporarilyBlocked:
                return apiError.errorDescription ?? generic
            }
        }
        if let known = error as? LocalizedError, let description = known.errorDescription, !description.isEmpty {
            return description
        }
        return generic
    }

    private func resolveStreamURL(
        for track: Track,
        collectionId: String? = nil,
        useCache: Bool = true
    ) async throws -> URL {
        try await sourceResolver.networkURL(
            for: track,
            collectionID: collectionId,
            purpose: .streaming,
            useResolutionCache: useCache
        )
    }

    private func tryPeerContent(
        for track: Track
    ) async -> (asset: AVURLAsset, client: PeerContentClient, delegate: PeerContentAssetLoaderDelegate)? {
        guard let provider = peerContentSource,
              let (endpoint, sessionId, secret) = provider.peerContentEndpoint else { return nil }
        guard let source = DownloadSourceSelection.choose(from: track.transcodings) else { return nil }
        guard let accountCredential = PeerContentAccountCredential.current() else { return nil }

        let client = PeerContentClient(accountCredential: accountCredential)

        let connected = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
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

    private func prunePlaybackPreparation() {
        guard let preparedPlayback else { return }
        let remainsRelevant = queue.contains(where: { $0.id == preparedPlayback.trackID })
            || currentTrack?.id == preparedPlayback.trackID
        if !remainsRelevant { discardPreparedPlayback() }
    }

    private func prefetchNextStreamAfterPlaybackStarts() {
        guard let next = upcomingTracksForPredictiveDownload(limit: 1).first,
              next.id != currentTrack?.id,
              next.streamURL != nil,
              !downloads.isLocallyAvailable(next),
              !PlayedAudioCache.shared.contains(next) else { return }
        startPlaybackPrewarm(for: next)
    }

    private func refreshNextStreamPrewarmNearEnd(at position: TimeInterval, trackID: String) {
        guard previewSession == nil,
              nextPrewarmRefreshTrackID != trackID,
              duration > 0,
              trimTimeline.range.upperBound - position <= PlaybackPrewarmingPolicy.nextTrackRefreshLead else { return }
        nextPrewarmRefreshTrackID = trackID
        prefetchNextStreamAfterPlaybackStarts()
    }

    /// Prepares a track the user is likely to play (for example one focused in
    /// a list). Resolution, asset validation, and AVPlayerItem creation all
    /// stay transport-owned; views only report intent. The debounce keeps fast
    /// pointer/focus navigation from opening speculative streams.
    func preparePlayback(for track: Track, immediate: Bool = false) {
        warmDebounceTask?.cancel()
        warmDebounceTask = Task { @MainActor [weak self] in
            if !immediate {
                #if os(tvOS)
                do { try await Task.sleep(nanoseconds: 120_000_000) } catch { return }
                #else
                do { try await Task.sleep(nanoseconds: 180_000_000) } catch { return }
                #endif
            }
            guard !Task.isCancelled, let self else { return }
            guard track.streamURL != nil else { return }
            guard !self.downloads.isLocallyAvailable(track), !PlayedAudioCache.shared.contains(track) else { return }
            if !immediate {
                let now = Date()
                if let last = self.lastSpeculativePrewarmAt,
                   now.timeIntervalSince(last) < PlaybackPrewarmingPolicy.speculativeSpacing { return }
                self.lastSpeculativePrewarmAt = now
            }
            self.startPlaybackPrewarm(for: track)
        }
    }

    private var lastSpeculativePrewarmAt: Date?

    private func startPlaybackPrewarm(for track: Track) {
        guard !startsInMixEngine(track) || djDirector.startsOnStreamFirst(track) else { return }
        if let preparedPlayback,
           PlaybackPrewarmingPolicy.isFresh(
               preparedTrackID: preparedPlayback.trackID,
               expectedTrackID: track.id,
               preparedAt: preparedPlayback.preparedAt
           ) {
            return
        }

        discardPreparedPlayback()
        let generation = preparedPlaybackGeneration
        preparedPlaybackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.preparedPlaybackGeneration == generation {
                    self.preparedPlaybackTask = nil
                }
            }

            do {
                let startedAt = Date()
                let url = try await self.resolveStreamURL(
                    for: track,
                    collectionId: self.activeCollectionId
                )
                try Task.checkCancellation()
                guard self.preparedPlaybackGeneration == generation else { return }

                let asset = AVURLAsset(url: url)
                let isPlayable = try await asset.load(.isPlayable)
                try Task.checkCancellation()
                guard isPlayable,
                      self.preparedPlaybackGeneration == generation else { return }

                let item = AVPlayerItem(asset: asset)
                item.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
                item.preferredForwardBufferDuration = PlaybackPrewarmingPolicy.preferredForwardBufferDuration

                self.preparedPlayback = PreparedPlayback(
                    trackID: track.id,
                    url: url,
                    item: item,
                    preparedAt: Date()
                )
                let preparationMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
                Log.player.notice(
                    "[Player] prewarm prepared \(track.id, privacy: .public) in \(preparationMilliseconds, privacy: .public) ms"
                )
            } catch {
                guard !Task.isCancelled, self.preparedPlaybackGeneration == generation else { return }
                Log.player.debug(
                    "[Player] prewarm skipped \(track.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func consumePreparedPlayback(for track: Track) -> PreparedPlayback? {
        guard let prepared = preparedPlayback,
              PlaybackPrewarmingPolicy.isFresh(
                  preparedTrackID: prepared.trackID,
                  expectedTrackID: track.id,
                  preparedAt: prepared.preparedAt
              ) else {
            if preparedPlayback != nil { discardPreparedPlayback() }
            return nil
        }

        preparedPlaybackGeneration &+= 1
        preparedPlaybackTask?.cancel()
        preparedPlaybackTask = nil
        preparedPlayback = nil
        return prepared
    }

    private func discardPreparedPlayback() {
        preparedPlaybackGeneration &+= 1
        preparedPlaybackTask?.cancel()
        preparedPlaybackTask = nil
        preparedPlayback = nil
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

    private func playStream(
        asset: AVURLAsset,
        track: Track,
        startPosition: TimeInterval = 0,
        token: PlaybackPipeline.Token,
        source: PlaybackMediaOrigin,
        mediaRecoveryAttempt: Int,
        preparedItem: AVPlayerItem? = nil
    ) async {
        guard playbackPipeline.accepts(token) else { return }
        mediaOrigin = source
        let previousPlayer = player
        if let observer = timeObserver, let previousPlayer {
            previousPlayer.removeTimeObserver(observer)
            timeObserver = nil
        }
        removePlaybackStartObserver()
        cancelSeeks()

        cancellables.removeAll()

        let playerItem = preparedItem ?? AVPlayerItem(asset: asset)
        _ = transitionPlayback(
            to: playbackRequested ? .buffering(trackID: track.id) : .paused(trackID: track.id),
            for: token
        )

        playerItem.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        applyTrim(to: playerItem, track: track)
        // Zero delegates buffering policy to AVFoundation. Forcing a 60-second
        // buffer after startup and bypassing stall minimization caused the
        // exact start/stop behaviour this player is meant to avoid.
        playerItem.preferredForwardBufferDuration = source == .networkStream
            ? InstantPlayTuning.networkStartupForwardBuffer
            : 0

        playerItem.publisher(for: \.status, options: [.initial, .new])
            .removeDuplicates()
            .sink { [weak self, weak playerItem] status in
                guard status == .failed else { return }
                Task { @MainActor in
                    guard let self, let playerItem else { return }
                    self.recoverMediaPlayback(
                        track: track,
                        item: playerItem,
                        token: token,
                        source: source,
                        attempt: mediaRecoveryAttempt,
                        error: playerItem.error
                    )
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AVPlayerItem.playbackStalledNotification, object: playerItem)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.observedStalls += 1
                    Log.player.error("[Player] stall #\(self.observedStalls, privacy: .public)")
                    self.scheduleBufferingWatchdog(
                        track: track,
                        item: playerItem,
                        token: token,
                        source: source,
                        attempt: mediaRecoveryAttempt
                    )
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(
            for: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: playerItem
        )
        .sink { [weak self, weak playerItem] note in
            Task { @MainActor in
                guard let self, let playerItem else { return }
                self.recoverMediaPlayback(
                    track: track,
                    item: playerItem,
                    token: token,
                    source: source,
                    attempt: mediaRecoveryAttempt,
                    error: note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                )
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

        if let previousPlayer {
            if previousPlayer.currentItem !== playerItem { previousPlayer.replaceCurrentItem(with: playerItem) }
            player = previousPlayer
        } else {
            player = AVPlayer(playerItem: playerItem)
        }
        player?.volume = Float(loudnessGain * volume * sleepFadeGain)

        if let activePlayer = player {
            activePlayer.publisher(for: \.timeControlStatus)
                .removeDuplicates()
                .sink { [weak self, weak activePlayer] status in
                    Task { @MainActor in
                        guard let self, let activePlayer,
                              self.player === activePlayer,
                              self.playbackPipeline.accepts(token),
                              activePlayer.currentItem === playerItem,
                              activePlayer.timeControlStatus == status else { return }
                        switch status {
                        case .playing:
                            self.bufferingWatchdogTask?.cancel()
                            self.bufferingWatchdogTask = nil
                            activePlayer.automaticallyWaitsToMinimizeStalling = true
                            // Do not declare the track "playing" the moment
                            // timeControlStatus flips; audio output can still be
                            // ramping, route-switching, or waiting on the audio
                            // session. Stay in .buffering until the playhead
                            // actually advances, then transition in the
                            // playbackStartObserver or periodic time observer.
                            self.installPlaybackStartObserver(
                                player: activePlayer,
                                playerItem: playerItem,
                                track: track,
                                token: token
                            )
                            if self.playbackLoadTiming?.token == token,
                               let startedAt = self.playbackLoadTiming?.startedAt {
                                let startupMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
                                Log.player.notice(
                                    "[Player] playback ready for \(track.id, privacy: .public) in \(startupMilliseconds, privacy: .public) ms"
                                )
                                self.playbackLoadTiming = nil
                            }
                            playerItem.preferredForwardBufferDuration = 0
                            if self.previewSession == nil {
                                self.prefetchNextStreamAfterPlaybackStarts()
                                self.djDirector.armMixSession()
                                if source == .networkStream,
                                   let stream = self.cacheableStream, stream.trackID == track.id {
                                    PlayedAudioCache.shared.noteAudibleStart(
                                        of: track,
                                        streamURL: stream.url,
                                        transcoding: stream.transcoding
                                    )
                                }
                            }
                        case .waitingToPlayAtSpecifiedRate:
                            if self.playbackRequested {
                                _ = self.transitionPlayback(to: .buffering(trackID: track.id), for: token)
                                self.scheduleBufferingWatchdog(
                                    track: track,
                                    item: playerItem,
                                    token: token,
                                    source: source,
                                    attempt: mediaRecoveryAttempt
                                )
                            }
                        case .paused:
                            if !self.playbackRequested {
                                _ = self.transitionPlayback(to: .paused(trackID: track.id), for: token)
                            }
                        @unknown default:
                            break
                        }
                        #if DEBUG
                        if ProcessInfo.processInfo.environment["SOUNDING_TV_LOG_PLAYBACK_CLOCK"] == "1" {
                            print("[PlaybackClock] \(Date()) AVPlayer=\(String(describing: status)) waveformPlaying=\(self.isPlaying) time=\(self.currentTime)")
                        }
                        #endif
                        self.updateNowPlayingProgress()
                    }
                }
                .store(in: &cancellables)
        }
        // Start with AVFoundation's stall protection. The staged watchdog
        // relaxes it only if this particular item has made no progress.
        player?.automaticallyWaitsToMinimizeStalling = true
        player?.isMuted = false
        #if !os(macOS)
        if #available(iOS 27.0, tvOS 27.0, *) {
            player?.setDisconnectedFromSystemAudio(false)
        }
        #endif

        if startPosition > 0, let activePlayer = player {
            _ = await activePlayer.seek(to: CMTime(seconds: startPosition, preferredTimescale: 600))
            guard playbackPipeline.accepts(token),
                  player === activePlayer,
                  activePlayer.currentItem === playerItem else { return }
            clock.currentTime = startPosition
        }

        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self,
                      self.playbackPipeline.accepts(token),
                      self.player?.currentItem === playerItem,
                      time.seconds.isFinite,
                      !self.seekInFlight else { return }
                // The first periodic-time tick where the playhead has moved is
                // the earliest reliable signal that audio has actually started.
                // Transition from buffering to playing here if the dedicated
                // start observer has not already done so.
                self.transitionToPlayingIfBuffering(trackID: track.id, token: token)
                // While playing, never let the published position move
                // backwards: tolerance seeks and HLS re-tuning can report a
                // slightly earlier playhead, which visibly rewinds the
                // progress UI and re-anchors wall-clock extrapolation.
                // Explicit seeks and track changes set currentTime directly.
                if case .playing = self.playbackPipeline.phase {
                    self.clock.currentTime = max(self.clock.currentTime, time.seconds)
                } else {
                    self.clock.currentTime = time.seconds
                }
                self.updateNowPlayingProgress()
                self.persistSessionState()
                self.refreshNextStreamPrewarmNearEnd(at: self.clock.currentTime, trackID: track.id)
            }
        }

        #if DEBUG
        if ProcessInfo.processInfo.environment["SOUNDING_TV_LOG_PLAYBACK_CLOCK"] == "1" {
            print("[PlaybackClock] \(Date()) play requested; waveform remains stopped")
        }
        #endif
        if playbackRequested {
            if let activePlayer = player,
               InstantPlayTuning.startsImmediately(origin: source, itemIsPrepared: playerItem.isPlaybackLikelyToKeepUp) {
                activePlayer.automaticallyWaitsToMinimizeStalling = InstantPlayTuning.waitsToMinimizeStalling(origin: source)
                activePlayer.playImmediately(atRate: activePlayer.defaultRate > 0 ? activePlayer.defaultRate : 1)
            } else {
                player?.play()
            }
            scheduleBufferingWatchdog(
                track: track,
                item: playerItem,
                token: token,
                source: source,
                attempt: mediaRecoveryAttempt
            )
        } else {
            player?.pause()
            _ = transitionPlayback(to: .paused(trackID: track.id), for: token)
        }
        updateNowPlayingMetadata()
    }

    private func scheduleBufferingWatchdog(
        track: Track,
        item: AVPlayerItem,
        token: PlaybackPipeline.Token,
        source: PlaybackMediaOrigin,
        attempt: Int
    ) {
        bufferingWatchdogTask?.cancel()
        let startingTime = currentTime
        bufferingWatchdogTask = Task { @MainActor [weak self, weak item] in
            do { try await Task.sleep(for: PlaybackBufferingPolicy.initialKickDelay) } catch { return }
            guard let self, let item, let activePlayer = self.player,
                  self.playbackRequested,
                  self.playbackPipeline.accepts(token),
                  activePlayer.currentItem === item,
                  activePlayer.timeControlStatus != .playing,
                  PlaybackBufferingPolicy.hasNotAdvanced(
                    currentTime: self.currentTime,
                    from: startingTime
                  ) else { return }

            // This is intentionally a kick on the existing resolved item, not
            // a second URL request. AVFoundation remains the source of truth:
            // the UI does not publish playing until timeControlStatus does.
            Log.player.notice(
                "[Player] kicking unresponsive item for \(track.id, privacy: .public)"
            )
            activePlayer.automaticallyWaitsToMinimizeStalling = false
            activePlayer.playImmediately(atRate: 1)

            do { try await Task.sleep(for: PlaybackBufferingPolicy.recoveryDelayAfterKick) } catch { return }
            guard self.playbackRequested,
                  self.playbackPipeline.accepts(token),
                  self.player === activePlayer,
                  activePlayer.currentItem === item,
                  activePlayer.timeControlStatus != .playing,
                  PlaybackBufferingPolicy.hasNotAdvanced(
                    currentTime: self.currentTime,
                    from: startingTime
                  ) else { return }
            self.recoverMediaPlayback(
                track: track,
                item: item,
                token: token,
                source: source,
                attempt: attempt,
                error: URLError(.timedOut)
            )
        }
    }

    private func recoverMediaPlayback(
        track: Track,
        item: AVPlayerItem,
        token: PlaybackPipeline.Token,
        source: PlaybackMediaOrigin,
        attempt: Int,
        error: Error?
    ) {
        guard playbackPipeline.accepts(token), player?.currentItem === item else { return }
        guard recoveringToken != token else { return }
        bufferingWatchdogTask?.cancel()
        bufferingWatchdogTask = nil

        let failure = error ?? NSError(
            domain: "red.forbes.sounding.playback",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "The audio stream stopped responding."]
        )
        guard playbackRequested, attempt < Self.maximumMediaRecoveryAttempts else {
            finishPlaybackFailure(failure, token: token)
            return
        }

        Log.player.notice(
            "[Player] retrying track \(track.id, privacy: .public) after \(failure.localizedDescription, privacy: .public)"
        )
        recoveringToken = token
        if source == .localCache, !downloads.isLocallyAvailable(track) {
            PlayedAudioCache.shared.remove(trackID: track.id)
        }
        let resumeAt = currentTime.isFinite ? max(0, currentTime) : 0
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadAndPlay(
                track: track,
                startPosition: resumeAt,
                transportIntent: .preserve,
                skipLocalFile: source == .localCache,
                bypassStreamCache: true,
                mediaRecoveryAttempt: attempt + 1
            )
            if self.recoveringToken == token { self.recoveringToken = nil }
        }
    }

    private func finishPlaybackFailure(_ error: Error, token: PlaybackPipeline.Token) {
        guard playbackPipeline.accepts(token) else { return }
        if playbackLoadTiming?.token == token { playbackLoadTiming = nil }
        Log.player.error("[Player] playback failed: \(error.localizedDescription, privacy: .public)")
        teardownAVPlayer(invalidatePipeline: false)
        playbackPipeline.requestPause(trackID: token.trackID)
        playbackPipeline.transitionCurrent(
            to: .failed(trackID: token.trackID, message: Self.describePlaybackFailure(error))
        )
        syncPublishedPlaybackState()
        playbackErrorMessage = Self.describePlaybackFailure(error)
        if let denial = error as? SoundCloudEntitlementError { entitlementPrompt = denial }
        updateNowPlayingProgress()
    }

    func handlePlaybackEnded() async {
        if previewSession != nil {
            playbackPipeline.requestPause(trackID: currentTrack?.id)
            syncPublishedPlaybackState()
            updateNowPlayingProgress()
            return
        }
        if isPlayingSoundCloudPreview, let track = currentTrack {
            notePreviewEnded(track)
        }
        switch repeatMode {
        case .one:
            let restart = trimTimeline.range.lowerBound
            if isMixEngineLive {
                seek(to: restart)
            } else {
                let cmTime = CMTime(seconds: restart, preferredTimescale: 600)
                _ = await player?.seek(to: cmTime)
                clock.currentTime = restart
                updateNowPlayingProgress()
            }
            play()
        case .all:
            await playNext()
        case .off:
            if currentIndex < queue.count - 1 {
                await playNext()
            } else {
                playbackPipeline.requestPause(trackID: currentTrack?.id)
                syncPublishedPlaybackState()
                let restart = trimTimeline.range.lowerBound
                if isMixEngineLive {
                    seek(to: restart)
                } else {
                    clock.currentTime = restart
                    issueSeek(to: restart)
                }
                updateNowPlayingProgress()
            }
        }
    }

    func play() {
        PlatformAudioSession.activatePlayback()
        playbackPipeline.requestPlay(trackID: currentTrack?.id)
        syncPublishedPlaybackState()

        if let pending = pendingRestore {
            // Let loadAndPlay read the latest pending position (which seek(to:)
            // may have updated since this Task was scheduled) and clear it.
            Task { @MainActor [weak self] in
                await self?.loadAndPlay(track: pending.track)
            }
            return
        }
        // A paused resolve remains valid and will inspect the new transport
        // intent before starting audio. Avoid a duplicate URL request here.
        if case .resolving = playbackPipeline.phase { return }
        if isMixEngineLive {
            djDirector.resumeMixDecks()
            updateNowPlayingProgress()
            return
        }
        if djDirector.isStartingInEngine(currentTrack?.id) {
            updateNowPlayingProgress()
            return
        }
        guard let player, player.currentItem != nil else {
            guard let currentTrack else {
                playbackPipeline.invalidate()
                syncPublishedPlaybackState()
                return
            }
            Task { @MainActor [weak self] in
                await self?.loadAndPlay(
                    track: currentTrack,
                    startPosition: self?.currentTime ?? 0,
                    bypassStreamCache: true
                )
            }
            return
        }
        player.automaticallyWaitsToMinimizeStalling = true
        player.play()
        updateNowPlayingProgress()
    }

    private func syncClockFromPlayer() {
        guard !seekInFlight, !isMixEngineLive,
              let seconds = player?.currentTime().seconds,
              seconds.isFinite, seconds >= 0 else { return }
        clock.currentTime = max(clock.currentTime, min(seconds, duration > 0 ? duration : seconds))
    }

    func pause() {
        syncClockFromPlayer()
        persistSessionState(force: true)
        playbackLoadTiming = nil
        playbackPipeline.requestPause(trackID: currentTrack?.id)
        syncPublishedPlaybackState()
        bufferingWatchdogTask?.cancel()
        bufferingWatchdogTask = nil
        removePlaybackStartObserver()
        player?.automaticallyWaitsToMinimizeStalling = true
        if isMixEngineLive {
            djDirector.pauseMixDecks()
            clock.currentTime = PlaybackTimelinePolicy.clampedPosition(
                MixEngine.shared.livePosition(of: liveDeck),
                duration: duration
            )
            updateNowPlayingProgress()
            return
        }
        player?.pause()
        updateNowPlayingProgress()
    }

    func togglePlayPause() {
        if playbackRequested || isPlaying {
            pause()
        } else {
            play()
        }
    }

    func seek(to time: TimeInterval) {
        seek(to: time, expectedTrackID: nil)
    }

    func seek(to time: TimeInterval, expectedTrackID: String?, intent: SeekIntent = .user) {
        guard PlaybackTimelinePolicy.accepts(
            expectedTrackID: expectedTrackID,
            activeTrackID: currentTrack?.id
        ) else { return }
        let boundedTime = trimTimeline.clamped(PlaybackTimelinePolicy.clampedPosition(time, duration: duration))
        seekEvents.send(boundedTime)
        if isMixEngineLive {
            clock.currentTime = PlaybackTimelinePolicy.clampedPosition(
                djDirector.seekMixDecks(to: boundedTime),
                duration: duration
            )
            djDirector.deckEndHandled = false
            updateNowPlayingProgress()
            return
        }
        if djDirector.isStartingInEngine(currentTrack?.id) {
            djDirector.updatePendingStart(boundedTime)
            clock.currentTime = boundedTime
            updateNowPlayingProgress()
            return
        }
        if pendingRestore != nil {
            pendingRestore?.position = boundedTime
            clock.currentTime = boundedTime
            updateNowPlayingProgress()
            return
        }
        clock.currentTime = boundedTime
        seekStartedAt = Date()
        ListeningRecorder.shared.noteSeek(
            trackId: currentTrack?.id,
            toSeconds: boundedTime,
            duration: duration,
            intent: intent,
            decksLive: isMixEngineLive
        ) { [weak self] in
            ListeningRecorder.PlaybackProbe(
                trackId: self?.currentTrack?.id,
                positionSeconds: self?.currentTime ?? 0,
                isPlaying: self?.isPlaying ?? false
            )
        }
        issueSeek(to: boundedTime)
    }

    private func issueSeek(to target: TimeInterval) {
        guard let player else { return }
        if seekInFlight {
            queuedSeekTarget = target
            return
        }
        seekInFlight = true
        seekGeneration &+= 1
        let generation = seekGeneration
        let item = player.currentItem
        let issuedAt = Date()
        let tolerance = target > 0 ? CMTime(seconds: 0.75, preferredTimescale: 600) : .zero
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        ) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.seekGeneration == generation else { return }
                self.seekInFlight = false
                guard let player = self.player, player.currentItem === item else { return }
                if let next = self.queuedSeekTarget {
                    self.queuedSeekTarget = nil
                    self.issueSeek(to: next)
                    return
                }
                guard finished else { return }
                let seconds = player.currentTime().seconds
                self.clock.currentTime = seconds.isFinite ? seconds : target
                self.updateNowPlayingProgress()
                Log.player.notice(
                    "[Player] seek to \(target, privacy: .public) s landed in \(Int(Date().timeIntervalSince(issuedAt) * 1_000), privacy: .public) ms"
                )
            }
        }
    }

    #if DEBUG
    var debugMediaPosition: (seconds: TimeInterval, isRunning: Bool)? {
        if isMixEngineLive {
            let engine = MixEngine.shared
            return (engine.audiblePosition(of: liveDeck), engine[liveDeck].isPlaying)
        }
        guard let player, player.currentItem != nil else { return nil }
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return nil }
        return (seconds, player.timeControlStatus == .playing && !seekInFlight)
    }
    #endif

    private func cancelSeeks() {
        seekGeneration &+= 1
        seekInFlight = false
        queuedSeekTarget = nil
    }

    func seekForward(_ seconds: TimeInterval = 15) {
        seek(to: min(currentTime + seconds, duration))
    }

    func seekBackward(_ seconds: TimeInterval = 15) {
        seek(to: max(currentTime - seconds, trimTimeline.range.lowerBound))
    }

    func playNext() async {
        guard let nextIndex = nextQueueIndex() else { return }

        if djDirector.isCrossfading, djDirector.completeMoveForSkip() { return }

        if isMixEngineLive,
           !djDirector.isCrossfading,
           incomingDeck.isReady,
           djDirector.incomingTrackId == queue[nextIndex].id {
            djDirector.performLiveTransition(to: queue[nextIndex], at: nextIndex, over: 0.25, announceAsMix: false)
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

        if isShuffleEnabled, !queue.isEmpty, currentIndex < queue.count {
            let kept = currentIndex + playingNextCount
            var remainingTracks = Array(queue[(kept + 1)...])
            remainingTracks.shuffle()
            queue = Array(queue[0...kept]) + remainingTracks
        } else {
            if let currentTrack = currentTrack,
               let newIndex = originalQueue.firstIndex(of: currentTrack) {
                queue = originalQueue
                currentIndex = newIndex
            }
        }

        djDirector.refreshMixSessionForQueue()
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    var playingNextCount: Int {
        playingNext.count(in: queue.map(\.id), currentIndex: currentIndex)
    }

    func addToQueue(_ track: Track) {
        guard !queue.isEmpty else {
            queue.append(track)
            originalQueue.append(track)
            djDirector.refreshMixSessionForQueue()
            return
        }
        insertIntoQueue(track, at: playingNext.addToQueueIndex(in: queue.map(\.id), currentIndex: currentIndex))
    }

    var currentPlayRequest: UInt64 { explicitPlayRequest }

    func appendCollectionTracks(_ tracks: [Track], collectionId: String, playRequest: UInt64) {
        guard activeCollectionId == collectionId,
              explicitPlayRequest == playRequest,
              !queue.isEmpty else { return }
        let eligible = djContextEligibility()
        let incomingIDs = Set(CollectionStartPlanner.appended(queue.map(\.id), with: tracks.map(\.id)).dropFirst(queue.count))
        var seen = Set<String>()
        var incoming = tracks.filter {
            incomingIDs.contains($0.id) && (eligible?($0) ?? true) && seen.insert($0.id).inserted
        }
        guard !incoming.isEmpty else { return }
        originalQueue.append(contentsOf: incoming)
        if isShuffleEnabled { incoming.shuffle() }
        queue.append(contentsOf: incoming)
        djDirector.refreshMixSessionForQueue()
    }

    func moveToPlayingNext(at index: Int) {
        guard index > currentIndex, index < queue.count else { return }
        let wasQueued = playingNext.contains(offset: index, in: queue.map(\.id), currentIndex: currentIndex)
        let track = queue.remove(at: index)
        queue.insert(track, at: currentIndex + 1)
        if !isShuffleEnabled { originalQueue = queue }
        playingNext.noteRemoved(track.id, wasQueued: wasQueued)
        playingNext.noteJoined(track.id)
        djDirector.refreshMixSessionForQueue()
    }

    func insertIntoQueue(_ track: Track, at index: Int) {
        let target = max(0, min(index, queue.count))
        playingNext.noteInserted(track.id, at: target, before: queue.map(\.id), currentIndex: currentIndex)
        queue.insert(track, at: target)
        originalQueue.append(track)

        if target <= currentIndex {
            currentIndex += 1
        }

        djDirector.refreshMixSessionForQueue()
    }

    func moveQueueItem(from source: Int, to destination: Int) {
        guard source >= 0, source < queue.count else { return }
        let target = max(0, min(destination, queue.count - 1))
        guard target != source else { return }

        let wasQueued = playingNext.contains(offset: source, in: queue.map(\.id), currentIndex: currentIndex)
        let track = queue.remove(at: source)
        queue.insert(track, at: target)

        if let currentTrack, let index = queue.firstIndex(of: currentTrack) {
            currentIndex = index
        }
        playingNext.noteMoved(track.id, wasQueued: wasQueued, to: target, after: queue.map(\.id), currentIndex: currentIndex)

        if !isShuffleEnabled {
            originalQueue = queue
        }

        djDirector.refreshMixSessionForQueue()
    }

    func removeFromQueue(at index: Int) async {
        guard index >= 0, index < queue.count else { return }

        let wasQueued = playingNext.contains(offset: index, in: queue.map(\.id), currentIndex: currentIndex)
        let removed = queue.remove(at: index)
        playingNext.noteRemoved(removed.id, wasQueued: wasQueued)
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
            await loadAndPlay(
                track: queue[currentIndex],
                transportIntent: playbackRequested ? .play : .pause
            )
        } else if let currentTrack, let newIndex = queue.firstIndex(of: currentTrack) {
            currentIndex = newIndex
            djDirector.refreshMixSessionForQueue()
        }
    }

    func clearQueue(forgetSavedSession: Bool = true) {
        if forgetSavedSession, let accountID = sessionAccountID ?? playbackPersistenceID {
            PlaybackStateStore.clear(accountID: accountID)
        }
        restoreTask?.cancel()
        restoreTask = nil
        pendingRestore = nil
        restoreLedger = nil
        restoredOriginalIds = nil
        pause()
        djDirector.endMixSession()
        warmDebounceTask?.cancel()
        warmDebounceTask = nil
        discardPreparedPlayback()
        teardownPeerContent()
        teardownAVPlayer()
        queue = []
        originalQueue = []
        playingNext.removeAll()
        queueSource = nil
        currentTrack = nil
        currentIndex = 0
        clock.currentTime = 0
        clock.duration = 0
        playbackPipeline.invalidate()
        syncPublishedPlaybackState()
        if systemRemoteHandlers == nil { nowPlaying.publishNowPlaying(nil) }
    }

    /// Explicit logout is stronger than an ordinary queue clear: it also
    /// forgets short-lived resolved stream endpoints saved by this app.
    func purgeLocalPlaybackState() {
        clearQueue()
        sourceResolver.clearResolutionCache()
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

    func adoptOutputSession(track: Track, queue context: [Track], index: Int, position: TimeInterval, autoplay: Bool) async {
        restoreTask?.cancel()
        pendingRestore = nil
        restoreLedger = nil
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
        playingNext.removeAll()
        queueSideEffectsSuspended = true
        queue = tracks
        currentIndex = resolvedIndex
        queueSideEffectsSuspended = false

        await loadAndPlay(
            track: track,
            startPosition: position,
            transportIntent: autoplay ? .play : .pause
        )
    }

    private static let positionPersistInterval: TimeInterval = 10

    private struct PlaybackAccountInputs: Equatable {
        var authenticatedAccountID: String?
        var currentUserID: String?
        var isSignedOut: Bool
    }

    private var playbackPersistenceID: String? {
        PlaybackPersistenceAccountPolicy.accountID(
            authenticatedAccountID: SubscriptionService.shared.authenticatedAccountID,
            currentUserID: SoundCloudCredentialSource.shared.currentUser?.id,
            rememberedAccountID: PlaybackStateStore.rememberedAccountID,
            isSignedOut: SoundCloudCredentialSource.shared.isSignedOut
        )
    }

    private func reconcilePlaybackAccount(_ inputs: PlaybackAccountInputs) {
        #if DEBUG
        guard !isVisualFixtureInstalled, SoundCloudCredentialSource.visualFixtureUser == nil else { return }
        #endif
        if inputs.isSignedOut {
            resolveLaunchRestore()
            PlaybackStateStore.forgetRememberedAccount()
            if let previous = sessionAccountID, previous != PlaybackPersistenceAccountPolicy.guestAccountID {
                Log.playback.info("signed out; closing the account's playback session")
                clearQueue(forgetSavedSession: false)
                sessionAccountID = nil
            }
        }
        let accountID = PlaybackPersistenceAccountPolicy.accountID(
            authenticatedAccountID: inputs.authenticatedAccountID,
            currentUserID: inputs.currentUserID,
            rememberedAccountID: PlaybackStateStore.rememberedAccountID,
            isSignedOut: inputs.isSignedOut
        )
        let transition = PlaybackAccountTransitionPolicy.transition(
            from: sessionAccountID,
            to: accountID,
            hasLiveSession: currentTrack != nil || !queue.isEmpty
        )
        switch transition {
        case .keep:
            if accountID == nil, sessionAccountID == nil, currentTrack == nil {
                Log.playback.info("restore skipped: account not known yet")
            }
        case .adopt(let id):
            sessionAccountID = id
        case .restore(let id):
            sessionAccountID = id
            restoreLastSession(accountID: id)
        case .replace(let id):
            Log.playback.info("account changed; closing the previous account's playback session")
            clearQueue(forgetSavedSession: false)
            sessionAccountID = id
            restoreLastSession(accountID: id)
        }
    }

    private func restoreLastSession(accountID: String) {
        restoreTask?.cancel()
        restoreTask = nil
        guard let snapshot = PlaybackStateStore.load(accountID: accountID) else {
            Log.playback.info("restore skipped: no saved snapshot")
            resolveLaunchRestore()
            return
        }
        guard let savedTrackId = snapshot.currentTrackId else {
            Log.playback.info("restore skipped: saved snapshot has no current track")
            resolveLaunchRestore()
            return
        }
        Log.playback.info("restoring snapshot (\(snapshot.trackIds.count, privacy: .public) tracks, index \(snapshot.currentIndex, privacy: .public), track \(savedTrackId, privacy: .public), mix \(snapshot.wantsMix, privacy: .public))…")
        let cached = immediatelyAvailableTracks(for: snapshot)
        if cached[savedTrackId] != nil, applyRestoredSnapshot(snapshot, tracksById: cached) {
            resolveLaunchRestore()
        }
        restoreTask = Task { @MainActor [weak self] in
            await self?.performRestore(snapshot, cached: cached)
            self?.resolveLaunchRestore()
        }
    }

    private func resolveLaunchRestore() {
        if !hasResolvedLaunchRestore { hasResolvedLaunchRestore = true }
    }

    private func immediatelyAvailableTracks(for snapshot: PlaybackStateStore.Snapshot) -> [String: Track] {
        var byId: [String: Track] = [:]
        for id in snapshot.trackIds where byId[id] == nil {
            if let track = downloads.cachedTrack(forTrackId: id) { byId[id] = track }
        }
        let localIds = Set(snapshot.trackIds.filter(LocalTrackFile.isLocalTrackID))
        if !localIds.isEmpty, LocalMusicLibrary.isSupported {
            for track in LocalMusicLibrary.shared.allTracks where localIds.contains(track.id) && byId[track.id] == nil {
                byId[track.id] = track
            }
        }
        if let id = snapshot.currentTrackId, byId[id] == nil,
           let payload = snapshot.currentTrackPayload,
           let track = PlaybackStateStore.decodeTrack(payload), track.id == id {
            byId[id] = track
        }
        return byId
    }

    private func performRestore(_ snapshot: PlaybackStateStore.Snapshot, cached: [String: Track]) async {
        guard let savedTrackId = snapshot.currentTrackId else { return }
        var byId = cached

        let uncached = snapshot.trackIds.filter { byId[$0] == nil && !LocalTrackFile.isLocalTrackID($0) }
        if !uncached.isEmpty {
            let library = await LibraryDB.cachedTracks(ids: uncached)
            guard !Task.isCancelled else { return }
            byId.merge(library) { current, _ in current }
            if !library.isEmpty { applyOrEnrichRestore(snapshot, tracksById: byId) }
        }

        let backoff = SoundCloudBackoff(base: 2, cap: 120)
        var attempt = 0
        while !Task.isCancelled {
            let missing = snapshot.trackIds.filter { byId[$0] == nil && !LocalTrackFile.isLocalTrackID($0) }
            guard !missing.isEmpty else { break }
            guard currentTrack == nil || restoreLedger != nil else { return }
            guard attempt < Self.maximumRestoreAttempts else {
                let unresolved = missing.count
                let attempts = attempt
                Log.playback.info("restore skipped: \(unresolved, privacy: .public) tracks still unresolved after \(attempts, privacy: .public) attempts")
                break
            }
            guard SoundCloudAPI.credentials != nil else {
                try? await Task.sleep(for: backoff.duration(attempt: attempt))
                attempt += 1
                continue
            }
            do {
                let fetched = try await api.getTracks(ids: missing)
                guard !Task.isCancelled else { return }
                for track in fetched { byId[track.id] = track }
                applyOrEnrichRestore(snapshot, tracksById: byId)
                break
            } catch is CancellationError {
                return
            } catch {
                let attemptNumber = attempt + 1
                let failure = String(describing: type(of: error))
                Log.playback.info("restore fetch failed (attempt \(attemptNumber, privacy: .public)): \(failure, privacy: .public)")
                try? await Task.sleep(for: backoff.duration(attempt: attempt))
                attempt += 1
            }
        }
        guard !Task.isCancelled else { return }
        if currentTrack?.id == savedTrackId {
            Log.playback.info("restore finished (\(self.queue.count, privacy: .public) of \(snapshot.trackIds.count, privacy: .public) tracks, index \(self.currentIndex, privacy: .public), auto mix \(self.isAutoMixEnabled, privacy: .public))")
        } else if currentTrack == nil {
            Log.playback.info("restore skipped: the saved track \(savedTrackId, privacy: .public) is not available")
        }
    }

    private static let maximumRestoreAttempts = 4

    private func restorablePlaybackIDs(in tracksById: [String: Track]) -> Set<String> {
        Set(tracksById.values.filter { track in
            track.streamURL != nil || track.isLocal || downloads.isLocallyAvailable(track)
        }.map(\.id))
    }

    private func applyOrEnrichRestore(
        _ snapshot: PlaybackStateStore.Snapshot,
        tracksById: [String: Track]
    ) {
        if currentTrack == nil, queue.isEmpty {
            applyRestoredSnapshot(snapshot, tracksById: tracksById)
        } else {
            enrichRestoredQueue(snapshot, tracksById: tracksById)
        }
    }

    private func restoredOriginalQueue(
        _ snapshot: PlaybackStateStore.Snapshot,
        tracksById: [String: Track],
        playable: Set<String>,
        fallback: [Track]
    ) -> [Track] {
        guard snapshot.isShuffleEnabled, let original = snapshot.originalTrackIds, !original.isEmpty else {
            return fallback
        }
        let tracks = original.filter(playable.contains).compactMap { tracksById[$0] }
        return tracks.isEmpty ? fallback : tracks
    }

    @discardableResult
    private func applyRestoredSnapshot(
        _ snapshot: PlaybackStateStore.Snapshot,
        tracksById: [String: Track]
    ) -> Bool {
        guard currentTrack == nil, queue.isEmpty,
              let savedTrackId = snapshot.currentTrackId else { return false }
        let playable = restorablePlaybackIDs(in: tracksById)
        guard playable.contains(savedTrackId) else { return false }
        let ledger = PlaybackRestoreLedger(snapshotIds: snapshot.trackIds, resolvedIds: playable)
        let restoredQueue = ledger.keptIds.compactMap { tracksById[$0] }
        let resumeIndex = snapshot.trackIds[..<snapshot.currentIndex].filter(playable.contains).count
        guard restoredQueue.indices.contains(resumeIndex),
              restoredQueue[resumeIndex].id == savedTrackId else { return false }
        let resumeTrack = restoredQueue[resumeIndex]

        restoreLedger = ledger.isComplete ? nil : ledger
        restoredOriginalIds = snapshot.originalTrackIds
        let wasEnabled = djSessionEnabled
        activeCollectionId = snapshot.collectionId
        queueSource = snapshot.queueSource ?? PlaybackQueueSourceDirectory.source(for: snapshot.collectionId)
        activeCollectionPolicy = snapshot.collectionId.map {
            CollectionQualityOverrideStore.shared.policy(for: $0)
        }
        collectionAutoMixRequested = snapshot.collectionAutoMixWasActive == true
        if snapshot.djSessionWasRequested == true {
            djModeRequested = true
        }
        if snapshot.autoMixWasActive == true, !collectionAutoMixRequested {
            autoMixSettingEnabled = true
        }
        if snapshot.wantsMix {
            let base = snapshot.djProfileId.flatMap(DJProfile.profile(id:))
                ?? activeCollectionPolicy.flatMap { DJProfile.profile(id: $0.djProfileId) }
                ?? defaultDJProfile
            djProfile = activeCollectionPolicy.map { base.applying(collectionPolicy: $0) } ?? base
            if snapshot.autoMixWasActive == true || collectionAutoMixRequested {
                isAutoMixEnabled = true
            }
        }
        let resumePosition = max(0, snapshot.positionSeconds)

        isRestoringSession = true
        originalQueue = restoredOriginalQueue(snapshot, tracksById: tracksById, playable: playable, fallback: restoredQueue)
        queue = restoredQueue
        currentIndex = resumeIndex
        currentTrack = resumeTrack
        isShuffleEnabled = snapshot.isShuffleEnabled
        repeatMode = snapshot.repeatMode
        clock.duration = resumeTrack.duration
        clock.currentTime = resumeTrack.duration > 0 ? min(resumePosition, resumeTrack.duration) : resumePosition
        playbackPipeline.begin(trackID: resumeTrack.id, intent: .pause)
        syncPublishedPlaybackState()
        pendingRestore = (track: resumeTrack, position: currentTime)
        isRestoringSession = false

        applySessionEnabledTransition(from: wasEnabled, primeAnalysis: false)
        if !downloads.isLocallyAvailable(resumeTrack) {
            startPlaybackPrewarm(for: resumeTrack)
        }
        updateNowPlayingMetadata()
        Log.playback.info("restored (\(restoredQueue.count, privacy: .public) of \(snapshot.trackIds.count, privacy: .public) tracks, index \(resumeIndex, privacy: .public), auto mix \(self.isAutoMixEnabled, privacy: .public)), paused")
        return true
    }

    private func enrichRestoredQueue(
        _ snapshot: PlaybackStateStore.Snapshot,
        tracksById: [String: Track]
    ) {
        guard let ledger = restoreLedger, ledger.snapshotIds == snapshot.trackIds else { return }
        let playable = restorablePlaybackIDs(in: tracksById)
        let newlyResolved = playable.subtracting(ledger.resolvedIds)
        guard !newlyResolved.isEmpty else { return }
        guard let enrichment = ledger.enriched(
            with: newlyResolved,
            liveIds: queue.map(\.id),
            liveIndex: currentIndex
        ) else {
            restoreLedger = nil
            return
        }
        let tracks = enrichment.ledger.keptIds.compactMap { tracksById[$0] }
        guard tracks.count == enrichment.ledger.keptIds.count,
              tracks.indices.contains(enrichment.index) else { return }

        restoreLedger = enrichment.ledger.isComplete ? nil : enrichment.ledger
        queueSideEffectsSuspended = true
        originalQueue = restoredOriginalQueue(
            snapshot,
            tracksById: tracksById,
            playable: enrichment.ledger.resolvedIds,
            fallback: tracks
        )
        queue = tracks
        currentIndex = enrichment.index
        queueSideEffectsSuspended = false
        queueStateDidChange()
        djDirector.refreshMixSessionForQueue()
        Log.playback.info("restored queue grew to \(tracks.count, privacy: .public) of \(snapshot.trackIds.count, privacy: .public) tracks")
    }

    func persistSessionState(force: Bool = false) {
        #if DEBUG
        guard !isVisualFixtureInstalled else { return }
        #endif
        guard !isRestoringSession, previewSession == nil else { return }
        guard (sessionAccountID ?? playbackPersistenceID) != nil else { return }
        if force {
            guard persistFlushTask == nil else { return }
            persistFlushTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                self.persistFlushTask = nil
                self.writeSessionState()
            }
            return
        }
        guard Date().timeIntervalSince(lastPersistedAt) >= Self.positionPersistInterval else { return }
        writeSessionState()
    }

    private func writeSessionState() {
        #if DEBUG
        guard !isVisualFixtureInstalled else { return }
        #endif
        guard !isRestoringSession, previewSession == nil else { return }
        guard let accountID = sessionAccountID ?? playbackPersistenceID else { return }
        guard !queue.isEmpty, let currentTrack else { return }
        lastPersistedAt = Date()

        let liveIds = queue.map(\.id)
        var trackIds = liveIds
        var index = currentIndex
        var originalIds: [String]? = isShuffleEnabled ? originalQueue.map(\.id) : nil
        if let ledger = restoreLedger {
            if let merged = ledger.persistedOrder(liveIds: liveIds, liveIndex: currentIndex) {
                trackIds = merged.ids
                index = merged.index
                originalIds = isShuffleEnabled ? (restoredOriginalIds ?? originalIds) : nil
            } else {
                restoreLedger = nil
            }
        }
        let position = currentTime.isFinite ? max(0, currentTime) : 0
        let snapshot = PlaybackStateStore.Snapshot(
            trackIds: trackIds,
            currentIndex: index,
            positionSeconds: position,
            isShuffleEnabled: isShuffleEnabled,
            repeatMode: repeatMode,
            collectionId: activeCollectionId,
            queueSource: queueSource,
            djProfileId: djProfile?.id,
            collectionAutoMixWasActive: collectionAutoMixRequested,
            autoMixWasActive: isAutoMixEnabled,
            djSessionWasRequested: djModeRequested,
            originalTrackIds: originalIds,
            currentTrackPayload: PlaybackStateStore.encodeTrack(currentTrack),
            savedAt: Date()
        )
        PlaybackStateStore.save(snapshot, accountID: accountID)
        let savedCount = trackIds.count
        let savedIndex = index
        Log.playback.info("saved snapshot (\(savedCount, privacy: .public) tracks, index \(savedIndex, privacy: .public))")
    }

    private func observeAuthenticatedAccount() {
        Task { @MainActor [weak self] in
            self?.subscribeToPlaybackAccount()
        }
    }

    private func subscribeToPlaybackAccount() {
        Publishers.CombineLatest(
            SubscriptionService.shared.$authenticatedAccountID,
            SoundCloudCredentialSource.shared.$state
        )
        .map { accountID, state in
            PlaybackAccountInputs(
                authenticatedAccountID: accountID,
                currentUserID: state.currentUser?.id,
                isSignedOut: state.isSignedOut
            )
        }
        .removeDuplicates()
        .sink { [weak self] inputs in
            self?.reconcilePlaybackAccount(inputs)
        }
        .store(in: &sessionCancellables)
    }

    func setDJSessionEnabled(_ enabled: Bool) {
        if enabled, isMixingSuspendedForGroupSession { return }
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

    func endDJSession() {
        setAutomaticMixEnabled(false)
        setDJSessionEnabled(false)
    }

    /// Starts (or explicitly reconfigures) an Auto DJ session. The UI holds
    /// this behind its configuration sheet, so cancelling never enables the
    /// audio graph or changes the running session.
    func startDJSession(
        configuration: DJStartConfiguration,
        reconfigure: Bool = false
    ) {
        guard reconfigure || !djModeRequested, !isMixingSuspendedForGroupSession else { return }
        SettingsStore.shared.setDJStartConfiguration(configuration)
        activeDJStartConfiguration = configuration

        let base = DJProfile.profile(id: SettingsStore.shared.djDefaultProfileId) ?? .automaticDJ
        let collectionAdjusted = activeCollectionPolicy.map { base.applying(collectionPolicy: $0) } ?? base
        djProfile = collectionAdjusted.applying(queueOrder: configuration.queueOrder)
        applyDJQueueOrder(configuration.queueOrder)
        setAutomaticMixEnabled(true)
        transitionService.isEnabled = true
        setDJSessionEnabled(true)

        if configuration.sourceStrategy == .goodMatches {
            discoverGoodMatchesIfNeeded()
        }
        if djSessionEnabled {
            transitionService.analyzeUpcoming(in: queue, from: currentIndex)
            djDirector.refreshPhantomPlan()
        }
    }

    private func applyDJQueueOrder(_ order: DJQueueOrderPolicy) {
        guard order == .random, currentIndex + 1 < queue.count else { return }
        var remaining = Array(queue[(currentIndex + 1)...])
        remaining.shuffle()
        queue = Array(queue[...currentIndex]) + remaining
        djDirector.prepareIncomingDeck()
    }

    private func discoverGoodMatchesIfNeeded() {
        guard goodMatchDiscoveryTask == nil, let seed = currentTrack else { return }
        let configuration = activeDJStartConfiguration
        goodMatchDiscoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.goodMatchDiscoveryTask = nil }
            do {
                let related = try await SoundCloudRequestEnvironment.$intent.withValue(.playback) {
                    try await api.getRelatedTracks(trackID: seed.id, limit: 30).collection
                }
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
                self.djDirector.refreshMixSessionForQueue()
                self.djDirector.refreshPhantomPlan()
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
        let cached = downloads.cachedTracks(forCollectionId: collectionId)
        if !cached.isEmpty { return cached }

        if collectionId == CollectionPolicyID.likedTracks {
            return try await api.getLikedTracks(limit: 200).collection.map(\.item)
        }

        let playlist = try await api.getPlaylist(id: collectionId)
        let ids = playlist.trackIDs ?? playlist.loadedTracks.map(\.id)
        return try await api.getPlaylistTracks(playlist, ids: ids)
    }

    /// Changes the Decks run mode and keeps the normal playback setting in
    /// sync. This is the single entry point used by the TV console and the
    /// phone remote; merely moving an EQ or fader never silently changes it.
    func setAutomaticMixEnabled(_ enabled: Bool) {
        if enabled, isMixingSuspendedForGroupSession { return }
        if !enabled, activeCollectionPolicy?.djMode == .djOnly {
            // "DJ Only" is a collection contract. The explicit Turn Off DJ
            // command can still end the session; the Auto switch cannot leave
            // a half-live deck graph behind.
            isAutoMixEnabled = true
            return
        }
        if enabled, djProfile == nil { djProfile = defaultDJProfile }
        let wasEnabled = isAutoMixEnabled
        isAutoMixEnabled = enabled
        SettingsStore.shared.setDJAutoMixEnabled(enabled)
        if autoMixSettingEnabled != enabled {
            applyAutoMixSettingEnabled(enabled, initial: false)
        }
        if !enabled, wasEnabled { djDirector.autoMixDidTurnOff() }
        if enabled {
            djDirector.armMixSession()
            if isMixEngineLive {
                let engine = MixEngine.shared
                engine.resetProcessing(on: liveDeck)
                if engine[liveDeck.other].status.isReady {
                    engine.resetProcessing(on: liveDeck.other, killLows: true)
                }
                if let currentTrack { applyLoudnessNormalization(for: currentTrack, deck: liveDeck) }
                if let upcomingTrack { applyLoudnessNormalization(for: upcomingTrack, deck: liveDeck.other) }
            }
            djDirector.refreshPhantomPlan()
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
        transitionService.syncEnabledFromCanonicalState(after)
        guard after != before else { return }

        if after {
            djDirector.armMixSession()
            if primeAnalysis {
                transitionService.analyzeUpcoming(in: queue, from: currentIndex)
            }
        } else {
            djDirector.handBackToAVPlayer()
        }
    }

    private func syncIsAutoMixEnabledFromSetting(_ enabled: Bool) {
        let wasEnabled = isAutoMixEnabled
        isAutoMixEnabled = enabled || collectionAutoMixRequested
        if wasEnabled, !isAutoMixEnabled { djDirector.autoMixDidTurnOff() }
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
        if djSessionEnabled { djDirector.armMixSession() }
        djDirector.refreshPhantomPlan()
    }

    private func applyDefaultDJProfile(_ profileId: DJProfileID) {
        guard activeCollectionPolicy == nil, djSessionEnabled,
              let profile = DJProfile.profile(id: profileId) else { return }
        djProfile = profile
        djDirector.refreshPhantomPlan()
    }

    func armMixSessionIfNeeded() {
        djDirector.armMixSession()
    }

    var upcomingTrack: Track? {
        nextQueueIndex().map { queue[$0] }
    }

    var upcomingMixTrack: Track? {
        guard !isPlayingSoundCloudPreview else { return nil }
        let subscription = SubscriptionService.shared
        return SoundCloudEntitlements.blendableNext(after: currentTrack, next: upcomingTrack) {
            subscription.playbackGrant(for: $0)
        }
    }

    func playsAsSoundCloudPreview(_ track: Track) -> Bool {
        SubscriptionService.shared.playsAsPreview(track)
    }

    var allowsSoundCloudPreviews: Bool {
        !requiresMixEngineOutput && !isMixingSuspendedForGroupSession
    }

    private func notePreviewEnded(_ track: Track) {
        guard !hasShownPreviewEndedPrompt else { return }
        hasShownPreviewEndedPrompt = true
        entitlementPrompt = SubscriptionService.shared.previewDenial(for: track)
    }

    func nextQueueIndex() -> Int? {
        guard !queue.isEmpty else { return nil }
        if repeatMode == .all, currentIndex >= queue.count - 1 { return 0 }
        if currentIndex < queue.count - 1 { return currentIndex + 1 }
        return nil
    }

    func plannedMixSeconds() -> TimeInterval? {
        djDirector.plannedMixSeconds()
    }

    func plannedMixPointSeconds() -> TimeInterval? {
        djDirector.plannedMixPointSeconds()
    }

    var adaptiveMixPlan: PhantomDJEngine.Plan? {
        djDirector.adaptiveMixPlan
    }

    var automaticMixDecision: DJAutomaticMixDecision {
        djDirector.automaticMixDecision
    }

    var canStartMix: Bool {
        djDirector.canStartMix
    }

    func startMix() {
        djDirector.startMix()
    }

    var canExtendMix: Bool {
        djDirector.canExtendMix
    }

    func extendMix() {
        djDirector.extendMix()
    }

    /// Deck arming, preload, plan caching, adaptive replanning, stage
    /// scheduling, and mix-session handoff now live in DJSessionDirector
    /// (Core/DJ/DJSessionDirector.swift). The public DJ API above forwards.

    func promoteToUpcoming(trackId: String) {
        guard playingNextCount == 0, currentIndex + 1 < queue.count,
              let sourceIndex = queue[(currentIndex + 1)...].firstIndex(where: { $0.id == trackId }),
              sourceIndex != currentIndex + 1 else { return }
        let selected = queue.remove(at: sourceIndex)
        queue.insert(selected, at: currentIndex + 1)
        originalQueue.removeAll { $0.id == trackId }
        let originalInsertion = min(currentIndex + 1, originalQueue.count)
        originalQueue.insert(selected, at: originalInsertion)
    }

    // MARK: - App volume

    static let volumeDefaultsKey = "playback.appVolume"

    static func storedVolume(_ defaults: UserDefaults = .standard) -> Double {
        guard defaults.object(forKey: volumeDefaultsKey) != nil else { return 1 }
        return clampedVolume(defaults.double(forKey: volumeDefaultsKey))
    }

    nonisolated static func clampedVolume(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(1, max(0, value))
    }

    func setVolume(_ value: Double) {
        let clamped = Self.clampedVolume(value)
        guard abs(clamped - volume) > 0.0001 else { return }
        volume = clamped
        UserDefaults.standard.set(clamped, forKey: Self.volumeDefaultsKey)
        player?.volume = Float(loudnessGain * clamped * sleepFadeGain)
        MixEngine.shared.setOutputVolume(clamped * sleepFadeGain)
    }

    func setSleepFadeGain(_ gain: Double) {
        let clamped = Self.clampedVolume(gain)
        guard abs(clamped - sleepFadeGain) > 0.0001 else { return }
        sleepFadeGain = clamped
        player?.volume = Float(loudnessGain * volume * clamped)
        MixEngine.shared.setOutputVolume(volume * clamped)
    }

    func setQueueSource(_ source: PlaybackQueueSource?) {
        if let source { PlaybackQueueSourceDirectory.note(source) }
        queueSource = source
    }

    func applyLoudnessNormalization(for track: Track, deck: MixEngine.Deck? = nil) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let gain = await DJSessionDirector.loudnessAttenuation(for: track)
            guard !Task.isCancelled else { return }
            if let deck {
                guard MixEngine.shared[deck].trackId == track.id else { return }
                MixEngine.shared.setGain(gain, on: deck, over: 0.5)
            } else {
                guard self.currentTrack?.id == track.id, !self.isMixEngineLive else { return }
                self.loudnessGain = gain
                self.player?.volume = Float(gain * self.volume * self.sleepFadeGain)
            }
        }
    }

    private func parkAVPlayer(trackID: String) {
        #if !os(macOS)
        if #available(iOS 27.0, tvOS 27.0, *), let player, player.currentItem != nil,
           player.currentItem?.status != .failed, let origin = mediaOrigin, origin != .peerStream {
            discardParkedPlayback()
            player.pause()
            player.setDisconnectedFromSystemAudio(true)
            parkedPlayback = (trackID, player, origin)
            self.player = nil
            mediaOrigin = nil
            return
        }
        #endif
        discardParkedPlayback()
    }

    private func unparkAVPlayer(trackID: String) async -> (asset: AVURLAsset, item: AVPlayerItem, origin: PlaybackMediaOrigin)? {
        #if !os(macOS)
        guard #available(iOS 27.0, tvOS 27.0, *), let parked = parkedPlayback, parked.trackID == trackID,
              player == nil, !isMixEngineLive,
              let item = parked.player.currentItem, item.status != .failed,
              let asset = item.asset as? AVURLAsset else { return nil }
        parkedPlayback = nil
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            parked.player.setDisconnectedFromSystemAudio(false) { continuation.resume() }
        }
        guard player == nil, !isMixEngineLive, parked.player.currentItem === item else {
            parked.player.replaceCurrentItem(with: nil)
            return nil
        }
        player = parked.player
        return (asset, item, parked.origin)
        #else
        return nil
        #endif
    }

    private func discardParkedPlayback() {
        guard let parked = parkedPlayback else { return }
        parkedPlayback = nil
        parked.player.pause()
        parked.player.replaceCurrentItem(with: nil)
    }

    func teardownAVPlayer(invalidatePipeline: Bool = true, keepingParked: Bool = false) {
        if !keepingParked { discardParkedPlayback() }
        bufferingWatchdogTask?.cancel()
        bufferingWatchdogTask = nil
        recoveringToken = nil
        #if !os(macOS)
        if #available(iOS 27.0, tvOS 27.0, *) {
            player?.setDisconnectedFromSystemAudio(true)
        }
        #endif

        if let observer = timeObserver, let player {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil
        removePlaybackStartObserver()
        cancellables.removeAll()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        mediaOrigin = nil
        if invalidatePipeline {
            playbackPipeline.invalidate(keeping: currentTrack?.id)
            syncPublishedPlaybackState()
        }
    }

    /// The manual DJ surface still renders through MixEngine, but source and
    /// cache ownership stays here with every other audio load.
    func loadManualDeck(_ track: Track, into deck: MixEngine.Deck) async throws {
        let url = try await resolveMixURL(for: track, collectionId: activeCollectionId)
        defer { TemporaryPlaintextFile(url: url).release() }
        try await MixEngine.shared.load(
            url: url,
            into: deck,
            trackId: track.id,
            cacheKey: mixCacheKey(for: track, collectionId: activeCollectionId)
        )
    }

    /// Analysis is a consumer of audio, not a second resolver. This gives it
    /// the exact same local-first and quality-aware source policy as playback.
    func audioURLForAnalysis(of track: Track) async throws -> URL {
        try await resolveMixURL(for: track, collectionId: activeCollectionId)
    }

    func resolveMixURL(for track: Track, collectionId: String?) async throws -> URL {
        do {
            return try await sourceResolver.decodedAudioURL(
                for: track,
                collectionID: collectionId
            )
        } catch is CancellationError {
            throw MixEngineError.cancelled
        } catch let denial as SoundCloudEntitlementError {
            throw denial
        } catch PlaybackSourceResolutionError.unsupportedFormat {
            throw MixEngineError.unsupportedFormat(
                "SoundCloud only offers Opus for this track, and AVFoundation has no Opus decoder"
            )
        } catch {
            throw MixEngineError.networkFailure(error.localizedDescription)
        }
    }

    private func mixSource(for track: Track, collectionId: String?) -> Transcoding? {
        sourceResolver.transcoding(
            for: track,
            collectionID: collectionId,
            purpose: .decodedAudio
        )
    }

    func mixCacheKey(for track: Track, collectionId: String?) -> String {
        "track-\(track.id)-\(mixSource(for: track, collectionId: collectionId)?.preset ?? "default")"
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let mixError = error as? MixEngineError, mixError == .cancelled { return true }
        return false
    }

    static func describeMixFailure(_ error: Error) -> String {
        if error is CancellationError { return MixEngineError.cancelled.displayMessage }
        Log.dj.error("[Mix] \(String(describing: error), privacy: .public)")
        if let mixError = error as? MixEngineError { return mixError.displayMessage }
        if error is APIError || error is URLError { return MixEngineError.networkFailure("").displayMessage }
        return MixEngineError.engineStartFailed("").displayMessage
    }

}

@MainActor
final class PlayedTrackLog {
    static let shared = PlayedTrackLog()

    private static let storageKey = "playedTrackLog.v1"
    private static let limit = 5_000
    private let defaults: UserDefaults
    private var order: [String]
    private(set) var ids: Set<String>

    private var forgetObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        order = defaults.stringArray(forKey: Self.storageKey) ?? []
        ids = Set(order)
        forgetObserver = NotificationCenter.default.addObserver(
            forName: AccountDataVault.didForgetAccountData,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.forget() }
        }
    }

    func hasPlayed(_ id: String) -> Bool { ids.contains(id) }

    func forget() {
        order = []
        ids = []
        defaults.removeObject(forKey: Self.storageKey)
    }

    func note(_ id: String) {
        guard !ids.contains(id) else { return }
        order.append(id)
        ids.insert(id)
        if order.count > Self.limit {
            let dropped = order.prefix(order.count - Self.limit)
            order.removeFirst(dropped.count)
            ids.subtract(dropped)
        }
        defaults.set(order, forKey: Self.storageKey)
    }
}
