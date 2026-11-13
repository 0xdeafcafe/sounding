import Foundation
import Combine

#if canImport(UIKit)
import UIKit
#endif

#if os(macOS)
import IOKit.ps
#endif

enum AnalysisWorkPriority: Int, Sendable {
    case background = 0
    case interactive = 1
}

enum AnalysisWorkState: Equatable, Sendable {
    case notEligible(String)
    case queued(position: Int)
    case analysing
    case failed(String)
    case complete

    var label: String {
        switch self {
        case .notEligible(let reason): return reason
        case .queued(let position): return position == 1 ? "Queued next" : "Queued #\(position)"
        case .analysing: return "Analysing…"
        case .failed: return "Analysis failed"
        case .complete: return "Analysed"
        }
    }

    var isQueued: Bool {
        if case .queued = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

enum AnalysisTrigger: Sendable, Equatable {
    case played
    case downloaded
    case deckLoaded
    case requested

    var priority: AnalysisWorkPriority {
        switch self {
        case .played, .downloaded: return .background
        case .deckLoaded, .requested: return .interactive
        }
    }

    var enforcesDeviceEligibility: Bool { priority == .background }
    var ignoresSetting: Bool { self == .requested }
}

@MainActor
final class AutomaticAnalysisStatus: ObservableObject {
    static let shared = AutomaticAnalysisStatus()

    @Published private(set) var states: [String: AnalysisWorkState] = [:]
    @Published private(set) var backlog = HeavyWorkProgress()

    private init() {}

    var backlogText: String? { backlog.label(verb: "Analysing") }

    func setBacklog(_ progress: HeavyWorkProgress) {
        guard backlog != progress else { return }
        backlog = progress
    }

    func state(for trackId: String) -> AnalysisWorkState? { states[trackId] }
    func set(_ state: AnalysisWorkState, for trackId: String) {
        guard states[trackId] != state else { return }
        states[trackId] = state
    }

    func setQueuePositions(_ positions: [(String, Int)]) {
        var next = states
        for (trackId, position) in positions { next[trackId] = .queued(position: position) }
        guard next != states else { return }
        states = next
    }

    func clear(_ trackId: String) {
        guard states[trackId] != nil else { return }
        states[trackId] = nil
    }
}

@MainActor
enum AutomaticAnalysisEligibility {
    static let storageReserveBytes: Int64 = 300_000_000
    static let minimumBatteryLevel: Float = 0.30
    nonisolated static let longestBackgroundTrackSeconds: TimeInterval = 20 * 60

    static var isEnabled: Bool { SettingsStore.shared.analyseMusicOnDevice }

    static var isSuppressedForFixtures: Bool {
        #if DEBUG
        return VisualFixtures.isEnabled
        #else
        return false
        #endif
    }

    static func requiredFreeBytes(temporaryCopyBytes: Int64) -> Int64 {
        storageReserveBytes + max(0, temporaryCopyBytes)
    }

    static func blockedReason(freeBytes: Int64?, temporaryCopyBytes: Int64 = 0) -> String? {
        guard isEnabled else { return "Music analysis is off on this device" }
        guard DeviceClass.current.supports(.deepAnalysis) else {
            return "This device can’t run deep analysis"
        }
        if let free = freeBytes, free < requiredFreeBytes(temporaryCopyBytes: temporaryCopyBytes) {
            return "Waiting for free storage"
        }
        return nil
    }

    static func laneConditions() -> AnalysisLaneConditions {
        AnalysisLaneConditions(
            isOnPower: isOnExternalPower,
            isPlaying: isPlaybackActive,
            isScreenIdle: isScreenIdle,
            systemPause: systemPauseReason()
        )
    }

    static var isOnExternalPower: Bool {
        guard let battery = batteryStatus else { return true }
        return battery.isCharging
    }

    static var isScreenIdle: Bool {
        #if canImport(UIKit) && !os(tvOS) && !os(watchOS)
        return UIApplication.shared.applicationState != .active
        #else
        return false
        #endif
    }

    static var isPlaybackActive: Bool {
        PlayerService.shared.isPlaying || MixEngine.shared.decks.contains(where: \.isPlaying)
    }

    static var playbackNeedsNetwork: Bool {
        guard PlayerService.shared.isPlaying, let track = PlayerService.shared.currentTrack else { return false }
        if LocalMusicLibrary.readyFileURL(for: track) != nil { return false }
        return !DownloadManager.shared.isLocallyAvailable(track)
    }

    static func heavyWorkConditions(isOnCellular: Bool) -> HeavyWorkConditions {
        let process = ProcessInfo.processInfo
        return HeavyWorkConditions(
            isLowPowerMode: process.isLowPowerModeEnabled,
            isThermallyLimited: process.thermalState == .serious || process.thermalState == .critical,
            isOnBattery: !isOnExternalPower,
            isOnCellular: isOnCellular,
            playbackNeedsNetwork: playbackNeedsNetwork
        )
    }

    static func systemPauseReason() -> String? {
        let process = ProcessInfo.processInfo
        if process.isLowPowerModeEnabled { return AnalysisLanePolicy.lowPowerReason }
        if process.thermalState == .serious || process.thermalState == .critical {
            return AnalysisLanePolicy.thermalReason
        }
        if let battery = batteryStatus, !battery.isCharging, battery.level >= 0, battery.level < minimumBatteryLevel {
            return AnalysisLanePolicy.batteryReason
        }
        return nil
    }

    static var batteryStatus: (isCharging: Bool, level: Float)? {
        #if os(macOS)
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 0
            let onExternalPower = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            return (onExternalPower, maximum > 0 ? Float(current) / Float(maximum) : -1)
        }
        return nil
        #elseif canImport(UIKit) && !os(tvOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        let state = UIDevice.current.batteryState
        return (state == .charging || state == .full, UIDevice.current.batteryLevel)
        #else
        return nil
        #endif
    }

    static func deckFileURL(for track: Track) -> URL? {
        if let url = LocalMusicLibrary.readyFileURL(for: track) { return url }
        for deck in MixEngine.Deck.allCases where MixEngine.shared[deck].trackId == track.id {
            if let url = MixEngine.shared.localFileURL(for: deck) { return url }
        }
        return nil
    }

    static func localFileURL(for track: Track, materialise: Bool) async -> URL? {
        if let url = deckFileURL(for: track) { return url }
        guard materialise else { return nil }
        return await DownloadManager.shared.temporaryPlaintextFile(for: track)?.url
    }

    nonisolated static func freeBytes(near url: URL) -> Int64? {
        #if os(tvOS)
        return nil
        #else
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
        #endif
    }
}

struct AnalysisBacklogCandidate: Sendable {
    let track: Track
    let transcoding: Transcoding?
    var localFileURL: URL? = nil
}

actor AutomaticAnalysisScheduler {
    static let shared = AutomaticAnalysisScheduler(waitsForInitialSync: true, pacing: .analysis)

    typealias Completion = @MainActor @Sendable (AnalysisWorkState) -> Void
    typealias BacklogResolver = @Sendable (String) async -> AnalysisBacklogCandidate?

    private struct Job: Sendable {
        let id: UInt64
        let track: Track
        let transcoding: Transcoding?
        let localFileURL: URL?
        let localAudio: LocalAudioProvider?
        let priority: AnalysisWorkPriority
        let refresh: Bool
    }

    private struct Waiter {
        let minimumJobId: UInt64
        let resume: @Sendable (AnalysisWorkState) async -> Void
    }

    private struct LaneItem {
        let key: String
        var priority: AnalysisWorkPriority
        var pausesDuringPlayback: Bool
        let sequence: UInt64
        var analysisTrackId: String?
        var operation: @Sendable () async -> Void
    }

    typealias ConditionsProvider = @Sendable () async -> AnalysisLaneConditions

    private static let pausedPollInterval: Duration = .seconds(20)
    static let initialSyncWait: Duration = .seconds(60)

    private var nextJobId: UInt64 = 0
    private var pendingRefresh: Set<String> = []
    private var freeBytesCache: (value: Int64?, at: ContinuousClock.Instant)?
    private var waiters: [String: [Waiter]] = [:]
    private var lane: [LaneItem] = []
    private var running: [String: AnalysisWorkPriority] = [:]
    private var laneSequence: UInt64 = 0
    private var laneTask: Task<Void, Never>?
    private var laneWake: CheckedContinuation<Void, Never>?
    private var backlogIds: [String] = []
    private var backlogResolver: BacklogResolver?
    private var syncDeadline: ContinuousClock.Instant?
    private let backgroundPriority: TaskPriority
    private let conditions: ConditionsProvider
    private let pacing: HeavyWorkPolicy
    private var backlogTotal = 0
    private var backlogPopped = 0
    private var publishedBacklog = HeavyWorkProgress()

    init(
        backgroundPriority: TaskPriority = .background,
        waitsForInitialSync: Bool = false,
        pacing: HeavyWorkPolicy = .immediate,
        conditions: ConditionsProvider? = nil
    ) {
        self.backgroundPriority = backgroundPriority
        self.syncDeadline = waitsForInitialSync ? .now + Self.initialSyncWait : nil
        self.pacing = pacing
        self.conditions = conditions ?? { await MainActor.run { AutomaticAnalysisEligibility.laneConditions() } }
    }

    private func cachedFreeBytes(near url: URL) -> Int64? {
        let now = ContinuousClock.now
        if let cached = freeBytesCache, now - cached.at < .seconds(30) { return cached.value }
        let value = AutomaticAnalysisEligibility.freeBytes(near: url)
        freeBytesCache = (value, now)
        return value
    }

    nonisolated static var supportsAudioTier: Bool {
        #if os(tvOS)
        return false
        #else
        return true
        #endif
    }

    nonisolated static func supportsAudioTier(for trigger: AnalysisTrigger) -> Bool {
        supportsAudioTier || trigger.priority == .interactive
    }

    nonisolated static var interactiveTaskPriority: TaskPriority {
        #if os(tvOS)
        return .utility
        #else
        return .userInitiated
        #endif
    }

    nonisolated func schedule(
        _ track: Track,
        trigger: AnalysisTrigger,
        localFileURL: URL? = nil,
        localAudio: LocalAudioProvider? = nil,
        transcoding: Transcoding? = nil,
        onFinish: Completion? = nil
    ) {
        Task(priority: trigger.priority == .interactive ? .userInitiated : .utility) {
            let state = await self.admit(
                track, trigger: trigger, localFileURL: localFileURL, localAudio: localAudio,
                transcoding: transcoding, refresh: false
            )
            if let onFinish { await onFinish(state) }
        }
    }

    func analyseNow(_ track: Track, refresh: Bool) async -> AnalysisWorkState {
        await admit(track, trigger: .requested, localFileURL: nil, localAudio: nil, transcoding: nil, refresh: refresh)
    }

    nonisolated func enqueueBackground(
        key: String,
        pausesDuringPlayback: Bool,
        operation: @escaping @Sendable () async -> Void
    ) {
        Task(priority: .utility) {
            await self.enqueue(
                key: key, priority: .background, pausesDuringPlayback: pausesDuringPlayback,
                analysisTrackId: nil, operation: operation
            )
        }
    }

    nonisolated func enqueueDeckWork(key: String, operation: @escaping @Sendable () async -> Void) {
        Task(priority: .utility) {
            await self.enqueue(
                key: key, priority: .interactive, pausesDuringPlayback: false,
                analysisTrackId: nil, operation: operation
            )
        }
    }

    nonisolated func resumeBacklog(trackIds: [String], resolver: @escaping BacklogResolver) {
        Task(priority: .utility) { await self.installBacklog(trackIds, resolver: resolver) }
    }

    private func installBacklog(_ trackIds: [String], resolver: @escaping BacklogResolver) async {
        let suppressed = await MainActor.run { AutomaticAnalysisEligibility.isSuppressedForFixtures }
        guard !suppressed else { return }
        backlogIds = Array(trackIds.reversed())
        backlogResolver = backlogIds.isEmpty ? nil : resolver
        backlogTotal = backlogIds.count
        backlogPopped = 0
        startLaneIfNeeded()
    }

    private func admit(
        _ track: Track,
        trigger: AnalysisTrigger,
        localFileURL suppliedURL: URL?,
        localAudio suppliedAudio: LocalAudioProvider?,
        transcoding: Transcoding?,
        refresh: Bool
    ) async -> AnalysisWorkState {
        let (enabled, suppressed) = await MainActor.run {
            (AutomaticAnalysisEligibility.isEnabled, AutomaticAnalysisEligibility.isSuppressedForFixtures)
        }
        guard !suppressed, enabled || trigger.ignoresSetting else {
            return .notEligible("Music analysis is off on this device")
        }

        Task { await self.runMetadataTier(for: track, fetchWaveform: trigger == .played) }

        var localFileURL = suppliedURL
        var localAudio = suppliedAudio
        if localFileURL == nil, localAudio == nil, trigger == .played || trigger == .requested {
            localFileURL = await MainActor.run { AutomaticAnalysisEligibility.deckFileURL(for: track) }
            if localFileURL == nil, await DownloadManager.shared.isLocallyAvailable(track) {
                localAudio = DownloadManager.localAudioProvider(for: track.id)
            }
        }

        if trigger != .requested, DeckIdentityResolver.isLikelyMix(track) {
            if let localFileURL {
                await MainActor.run {
                    SetlistBackgroundWorkCoordinator.shared.enqueue(track: track, localFileURL: localFileURL)
                }
            } else if localAudio != nil {
                await DownloadManager.shared.scheduleSetlistScan(for: track, whilePlaying: trigger == .played)
            }
        }

        guard localFileURL != nil || localAudio != nil else {
            guard trigger == .requested else { return .complete }
            let state = AnalysisWorkState.notEligible(
                track.needsFairPlay
                    ? PlaybackSourceResolutionError.protectedAudioStatus
                    : "Download this track to analyse its tempo and key"
            )
            await publish(state, for: track.id)
            return state
        }
        guard Self.supportsAudioTier(for: trigger) else {
            guard trigger == .requested else { return .complete }
            let state = AnalysisWorkState.notEligible("This device can’t run deep analysis")
            await publish(state, for: track.id)
            return state
        }

        if trigger.enforcesDeviceEligibility {
            guard track.duration <= AutomaticAnalysisEligibility.longestBackgroundTrackSeconds else {
                return .complete
            }
            if localFileURL == nil, await Self.hasStoredMusicUnderstanding(track: track, transcoding: transcoding) {
                await publish(.complete, for: track.id)
                return .complete
            }
            if let reason = await deviceBlockedReason(trackId: track.id, localFileURL: localFileURL) {
                let state = AnalysisWorkState.notEligible(reason)
                await publish(state, for: track.id)
                return state
            }
        }

        if refresh { pendingRefresh.insert(track.id) }
        let job = makeJob(
            track: track, transcoding: transcoding, localFileURL: localFileURL,
            localAudio: localAudio, priority: trigger.priority, refresh: refresh
        )
        return await withCheckedContinuation { continuation in
            waiters[track.id, default: []].append(Waiter(minimumJobId: job.id) { state in
                continuation.resume(returning: state)
            })
            submit(job)
        }
    }

    private func admitBacklogCandidate(_ candidate: AnalysisBacklogCandidate) async {
        let track = candidate.track
        if DeckIdentityResolver.isLikelyMix(track) {
            enqueue(
                key: "setlist.\(track.id)",
                priority: .background,
                pausesDuringPlayback: true,
                analysisTrackId: nil,
                operation: DownloadManager.setlistScanOperation(for: track)
            )
        }
        guard Self.supportsAudioTier,
              track.duration <= AutomaticAnalysisEligibility.longestBackgroundTrackSeconds else { return }
        let alreadyAnalysed = await Self.hasStoredMusicUnderstanding(track: track, transcoding: candidate.transcoding)
        let needsAI = await Self.needsOnDeviceAI(track: track, transcoding: candidate.transcoding)
        guard !alreadyAnalysed || needsAI else { return }
        guard await deviceBlockedReason(trackId: track.id, localFileURL: candidate.localFileURL) == nil else { return }
        await runMetadataTier(for: track, fetchWaveform: false)
        submit(makeJob(
            track: track, transcoding: candidate.transcoding, localFileURL: candidate.localFileURL,
            localAudio: candidate.localFileURL == nil ? DownloadManager.localAudioProvider(for: track.id) : nil,
            priority: .background, refresh: false
        ))
    }

    private func deviceBlockedReason(trackId: String, localFileURL: URL?) async -> String? {
        let copyBytes = localFileURL == nil
            ? await DownloadManager.shared.temporaryPlaintextCopyBytes(trackID: trackId)
            : 0
        let free = cachedFreeBytes(near: localFileURL ?? FileManager.default.temporaryDirectory)
        return await MainActor.run {
            AutomaticAnalysisEligibility.blockedReason(freeBytes: free, temporaryCopyBytes: copyBytes)
        }
    }

    private func makeJob(
        track: Track,
        transcoding: Transcoding?,
        localFileURL: URL?,
        localAudio: LocalAudioProvider?,
        priority: AnalysisWorkPriority,
        refresh: Bool
    ) -> Job {
        nextJobId &+= 1
        return Job(
            id: nextJobId, track: track, transcoding: transcoding,
            localFileURL: localFileURL, localAudio: localAudio, priority: priority, refresh: refresh
        )
    }

    private func submit(_ job: Job) {
        enqueue(
            key: "analysis.\(job.track.id)",
            priority: job.priority,
            pausesDuringPlayback: true,
            analysisTrackId: job.track.id
        ) {
            await AutomaticAnalysisScheduler.shared.run(job)
        }
    }

    // MARK: - Lane

    private func enqueue(
        key: String,
        priority: AnalysisWorkPriority,
        pausesDuringPlayback: Bool,
        analysisTrackId: String?,
        operation: @escaping @Sendable () async -> Void
    ) {
        if let index = lane.firstIndex(where: { $0.key == key }) {
            lane[index].operation = operation
            lane[index].analysisTrackId = analysisTrackId
            lane[index].pausesDuringPlayback = lane[index].pausesDuringPlayback && pausesDuringPlayback
            if priority.rawValue > lane[index].priority.rawValue { lane[index].priority = priority }
        } else {
            laneSequence &+= 1
            lane.append(LaneItem(
                key: key, priority: priority, pausesDuringPlayback: pausesDuringPlayback,
                sequence: laneSequence, analysisTrackId: analysisTrackId, operation: operation
            ))
        }
        publishQueuePositions()
        wakeLane()
        startLaneIfNeeded()
    }

    private func startLaneIfNeeded() {
        guard laneTask == nil else { return }
        laneTask = Task.detached(priority: .utility) { [self] in
            await drainLane()
        }
    }

    nonisolated func noteAnalysisSyncSettled() {
        Task(priority: .utility) { await self.openSyncGate() }
    }

    private func openSyncGate() {
        guard syncDeadline != nil else { return }
        syncDeadline = nil
        wakeLane()
    }

    private var isWaitingForSync: Bool {
        guard let deadline = syncDeadline else { return false }
        if ContinuousClock.now >= deadline {
            syncDeadline = nil
            return false
        }
        return true
    }

    private func drainLane() async {
        while true {
            var current = await conditions()
            if !isWaitingForSync, AnalysisLanePolicy.allowsBacklog(current) {
                await refillFromBacklog()
                current = await conditions()
            }
            publishBacklog(current)
            guard !lane.isEmpty || !running.isEmpty || backlogResolver != nil else { break }
            var started = false
            while let index = nextRunnableIndex(current) {
                start(lane.remove(at: index))
                started = true
            }
            if started {
                publishQueuePositions()
                continue
            }
            await idle(for: idleInterval)
        }
        publishBacklog(nil)
        laneTask = nil
    }

    private func publishBacklog(_ conditions: AnalysisLaneConditions?) {
        let backgroundInFlight = lane.contains { $0.priority == .background && $0.analysisTrackId != nil }
            || running.values.contains(.background)
        var progress = HeavyWorkProgress()
        if backlogTotal > 0 {
            progress.total = backlogTotal
            progress.isRunning = backgroundInFlight
            progress.done = backlogResolver == nil && !backgroundInFlight
                ? backlogTotal
                : max(0, backlogPopped - (backgroundInFlight ? 1 : 0))
            progress.pause = conditions.flatMap(AnalysisLanePolicy.pause)
        }
        guard progress != publishedBacklog else { return }
        publishedBacklog = progress
        Task { @MainActor in AutomaticAnalysisStatus.shared.setBacklog(progress) }
    }

    private var idleInterval: Duration {
        guard let deadline = syncDeadline else { return Self.pausedPollInterval }
        return min(Self.pausedPollInterval, max(.milliseconds(10), deadline - .now))
    }

    private func nextRunnableIndex(_ conditions: AnalysisLaneConditions) -> Int? {
        let backgroundLimit = isWaitingForSync ? 0 : AnalysisLanePolicy.backgroundLanes(conditions)
        let interactiveRunning = running.values.contains(.interactive)
        let ordered = lane.indices.sorted {
            lane[$0].priority != lane[$1].priority
                ? lane[$0].priority.rawValue > lane[$1].priority.rawValue
                : lane[$0].sequence < lane[$1].sequence
        }
        return ordered.first { index in
            let item = lane[index]
            guard running[item.key] == nil else { return false }
            if item.priority == .interactive {
                return AnalysisLanePolicy.mayStartInteractive(
                    running: running.count, interactiveRunning: interactiveRunning, conditions
                )
            }
            guard running.count < backgroundLimit else { return false }
            return !(item.pausesDuringPlayback && conditions.isPlaying)
        }
    }

    private func start(_ item: LaneItem) {
        running[item.key] = item.priority
        let isInteractive = item.priority == .interactive
        let priority = isInteractive ? Self.interactiveTaskPriority : backgroundPriority
        let provider = self.conditions
        let stagger = Duration.milliseconds(Int(pacing.gap(random: Double.random(in: 0...1)) * 1000))
        Task.detached(priority: priority) { [self] in
            await item.operation()
            if !isInteractive {
                let rest = max(AnalysisLanePolicy.yield(await provider()), stagger)
                if rest > .zero { try? await Task.sleep(for: rest) }
            }
            await finishLaneItem(item.key)
        }
    }

    private func finishLaneItem(_ key: String) {
        running[key] = nil
        wakeLane()
    }

    private func refillFromBacklog() async {
        while !lane.contains(where: { $0.priority == .background }), let resolver = backlogResolver {
            guard let trackId = backlogIds.popLast() else {
                backlogResolver = nil
                break
            }
            backlogPopped += 1
            guard let candidate = await resolver(trackId) else { continue }
            await admitBacklogCandidate(candidate)
            await Task.yield()
        }
    }

    private func idle(for duration: Duration) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            laneWake?.resume()
            laneWake = continuation
            Task.detached(priority: backgroundPriority) { [self] in
                try? await Task.sleep(for: duration)
                await wakeLane()
            }
        }
    }

    private func wakeLane() {
        laneWake?.resume()
        laneWake = nil
    }

    private func publishQueuePositions() {
        let positions = lane.enumerated().compactMap { offset, item in
            item.analysisTrackId.map { ($0, offset + 1) }
        }
        guard !positions.isEmpty else { return }
        Task { @MainActor in AutomaticAnalysisStatus.shared.setQueuePositions(positions) }
    }

    private func run(_ job: Job) async {
        let coalescedRefresh = pendingRefresh.remove(job.track.id) != nil
        let refresh = job.refresh || coalescedRefresh
        var lease: TemporaryPlaintextFile?
        defer { lease?.release() }
        var localFileURL = job.localFileURL
        if localFileURL == nil, let provider = job.localAudio {
            let needsAI = await Self.needsOnDeviceAI(track: job.track, transcoding: job.transcoding)
            if !refresh, !needsAI, await Self.hasStoredMusicUnderstanding(track: job.track, transcoding: job.transcoding),
               await TimbreEmbeddingProducer.hasStored(track: job.track, transcoding: job.transcoding) {
                await finish(job, state: .complete)
                return
            }
            lease = await provider()
            guard let lease else {
                await finish(job, state: .failed("The download couldn’t be read"))
                return
            }
            localFileURL = lease.url
        }
        let registry = AnalysisProducerRegistry.audioTier
        let tracksBeatsOnly = registry.producers.allSatisfy { $0 is BeatTrackerProducer }
        if tracksBeatsOnly, !refresh,
           await Self.hasStoredMusicUnderstanding(track: job.track, transcoding: job.transcoding) {
            await finish(job, state: .complete)
            return
        }
        await publish(.analysing, for: job.track.id)
        let wantsTimbre = TimbreEmbeddingProducer.isSupportedOnThisPlatform && localFileURL != nil
        var wantsSharedTimbre = false
        if wantsTimbre {
            let stored = await TimbreEmbeddingProducer.hasStored(track: job.track, transcoding: job.transcoding)
            wantsSharedTimbre = refresh || !stored
        }
        let share = AnalysisDecodeShare(wantsTimbre: wantsSharedTimbre)
        let result = await AnalysisCoordinator.analyze(
            track: job.track,
            transcoding: job.transcoding,
            localFileURL: localFileURL,
            refresh: refresh,
            registry: registry,
            decodeShare: share,
            cache: .shared
        )
        let state = Self.state(for: result)
        let features = result.stored.values.first
        if wantsTimbre {
            _ = await AnalysisCoordinator.analyze(
                track: job.track,
                transcoding: job.transcoding,
                localFileURL: localFileURL,
                refresh: refresh,
                registry: AnalysisProducerRegistry([TimbreEmbeddingProducer()]),
                decodeShare: share,
                cache: .shared
            )
        }
        Log.analysis.info("Audio analysis for \(job.track.id, privacy: .public): \(state.label, privacy: .public) bpm=\(features?.bpm.map { String(format: "%.1f", $0) } ?? "–", privacy: .public) key=\(features?.key?.label ?? "–", privacy: .public) refresh=\(refresh, privacy: .public)")
        await finish(job, state: state)
    }

    private func finish(_ job: Job, state: AnalysisWorkState) async {
        await publish(state, for: job.track.id)
        let ready = (waiters[job.track.id] ?? []).filter { $0.minimumJobId <= job.id }
        let remaining = (waiters[job.track.id] ?? []).filter { $0.minimumJobId > job.id }
        waiters[job.track.id] = remaining.isEmpty ? nil : remaining
        for waiter in ready { await waiter.resume(state) }
    }

    private static func needsOnDeviceAI(track: Track, transcoding: Transcoding?) async -> Bool {
        #if canImport(MLX) && os(macOS)
        guard AIAudioSettings.isActive else { return false }
        let generation = AIAudioProducer().generation
        guard let transcoding = transcoding
                ?? track.transcodings.max(by: { $0.playbackRank < $1.playbackRank }),
              let key = AnalysisCacheKey(track: track, transcoding: transcoding, generation: generation) else { return false }
        return await AnalysisCache.shared.peek(AIAudioAnalysisResult.self, for: key) == nil
        #else
        return false
        #endif
    }

    private static func hasStoredMusicUnderstanding(track: Track, transcoding: Transcoding?) async -> Bool {
        guard #available(iOS 27.0, macOS 27.0, tvOS 27.0, *) else { return false }
        let generation = MusicUnderstandingProducer().generation
        guard let transcoding = transcoding
                ?? track.transcodings.max(by: { $0.playbackRank < $1.playbackRank }),
              let key = AnalysisCacheKey(
                track: track,
                transcoding: transcoding,
                engine: generation.engine,
                schemaVersion: generation.schemaVersion
              ) else { return false }
        return await AnalysisCache.shared.peek(MusicUnderstandingDistilledResult.self, for: key) != nil
    }

    static func state(for result: AnalysisCoordinator.RunResult) -> AnalysisWorkState {
        guard result.isEntitled else { return .notEligible("Analysis isn’t available") }
        func rank(_ outcome: AnalysisProducerOutcome) -> Int {
            if case .stored = outcome { return 0 }
            return 1
        }
        let ordered = result.outcomes.sorted { (rank($0.value), $0.key) < (rank($1.value), $1.key) }.map(\.value)
        for outcome in ordered {
            switch outcome {
            case .stored(let features):
                return features.bpm != nil || features.key != nil
                    ? .complete
                    : .failed("No tempo or key could be measured")
            case .failed(let reason):
                Log.analysis.error("audio analysis failed: \(reason, privacy: .public)")
                return .failed(reason)
            case .skipped(let reason):
                return .notEligible(reason)
            }
        }
        return .complete
    }

    private func publish(_ state: AnalysisWorkState, for trackId: String) async {
        await MainActor.run { AutomaticAnalysisStatus.shared.set(state, for: trackId) }
    }

    func clearAnalysisData() async {
        await AnalysisDataUsage.clearAnalysisData()
        await MainActor.run {
            for trackId in AutomaticAnalysisStatus.shared.states.keys {
                AutomaticAnalysisStatus.shared.clear(trackId)
            }
        }
    }

    private func runMetadataTier(for track: Track, fetchWaveform: Bool) async {
        var samples: [Float] = []
        if fetchWaveform {
            if case .success(let waveform) = await WaveformService.shared.waveform(for: track), !waveform.isEmpty {
                samples = waveform.resampled(to: 200)
            }
        } else if case .ready(let waveform) = await WaveformService.shared.state(for: track.id), !waveform.isEmpty {
            samples = waveform.resampled(to: 200)
        }
        var tags: [String] = []
        if let genre = track.genre, !genre.isEmpty { tags.append(genre) }
        tags.append(contentsOf: track.tags)
        tags.append(track.title)
        let result = await AnalysisCoordinator.analyze(
            track: track,
            genreField: track.genre,
            tags: tags,
            waveformSamples: samples,
            registry: .metadataOnly,
            cache: .shared
        )
        for (id, outcome) in result.outcomes {
            if case .failed(let reason) = outcome {
                Log.analysis.error("\(id, privacy: .public) failed for \(track.id, privacy: .public): \(reason, privacy: .public)")
            }
        }
    }
}

// MARK: - Setlist identification

@MainActor
final class SetlistBackgroundWorkCoordinator {
    static let shared = SetlistBackgroundWorkCoordinator()

    private init() {}

    func enqueue(track: Track, localFileURL: URL, comments: [Comment]? = nil) {
        guard DeckIdentityResolver.isLikelyMix(track) else { return }
        AutomaticAnalysisScheduler.shared.enqueueBackground(
            key: "setlist.\(track.id)",
            pausesDuringPlayback: false
        ) {
            await SetlistIntelligenceStore.shared.analyze(
                track: track,
                localFileURL: localFileURL,
                comments: comments
            )
        }
    }
}

struct StreamedSetlistAudioSource: SetlistAudioSource {
    let index: SourceImporter.HLSWindowIndex
    let directory: URL

    func window(startingAt seconds: TimeInterval, duration: TimeInterval) async throws -> SetlistAudioWindow {
        let window = try await SourceImporter.materialiseWindow(
            index, start: seconds, duration: duration, in: directory
        )
        return SetlistAudioWindow(fileURL: window.url, startSeconds: window.startSeconds, isTemporary: true)
    }
}

enum SetlistAudioSources {
    struct Unavailable: LocalizedError {
        let errorDescription: String?
    }

    static var windowDirectory: URL {
        let base = FileManager.default.soundingDirectory(.cachesDirectory)
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("SetlistWindows", isDirectory: true)
    }

    @MainActor
    static func resolve(for track: Track) async throws -> any SetlistAudioSource {
        if let local = await AutomaticAnalysisEligibility.localFileURL(for: track, materialise: true) {
            return SetlistLocalAudioSource(fileURL: local)
        }
        let remote: URL
        do {
            remote = try await PlayerService.shared.audioURLForAnalysis(of: track)
        } catch {
            throw Unavailable(errorDescription: message(for: error))
        }
        if remote.isFileURL { return SetlistLocalAudioSource(fileURL: remote) }
        do {
            guard let index = try await SourceImporter.hlsWindowIndex(remoteURL: remote) else {
                throw Unavailable(errorDescription: "Download this mix to identify its tracks")
            }
            return StreamedSetlistAudioSource(index: index, directory: windowDirectory)
        } catch let error as Unavailable {
            throw error
        } catch {
            throw Unavailable(errorDescription: message(for: error))
        }
    }

    static func release(_ source: any SetlistAudioSource) {
        guard let local = source as? SetlistLocalAudioSource else { return }
        TemporaryPlaintextFile(url: local.fileURL).release()
    }

    static func message(for error: Error) -> String {
        if let unavailable = error as? Unavailable, let description = unavailable.errorDescription {
            return description
        }
        if let mixError = error as? MixEngineError {
            switch mixError {
            case .encryptedStream: return "This stream is protected. Download the mix to identify its tracks"
            case .protectedTrack: return PlaybackSourceResolutionError.protectedAudioStatus
            case .unsupportedFormat: return "This stream can’t be identified. Download the mix to identify its tracks"
            default: break
            }
        }
        return error.localizedDescription
    }
}

extension SetlistIntelligenceStore {

    func identify(at position: TimeInterval) async -> SetlistIdentification {
        guard let track = PlayerService.shared.currentTrack else { return .unavailable("Nothing is playing") }
        return await identify(track, at: position)
    }

    func identify(_ track: Track, at position: TimeInterval) async -> SetlistIdentification {
        do {
            let source = try await SetlistAudioSources.resolve(for: track)
            defer { SetlistAudioSources.release(source) }
            return await identify(track: track, at: position, source: source)
        } catch {
            return .unavailable(SetlistAudioSources.message(for: error))
        }
    }

    func requestTracklist(for track: Track) async {
        do {
            let source = try await SetlistAudioSources.resolve(for: track)
            await requestTracklist(track: track, source: source)
            SetlistAudioSources.release(source)
        } catch {
            reportScanError(SetlistAudioSources.message(for: error), for: track.id)
        }
    }
}
