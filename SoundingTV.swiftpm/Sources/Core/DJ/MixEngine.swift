import Foundation
import AVFoundation
import Accelerate
import Combine
import CryptoKit
import AudioToolbox

#if DEBUG
private final class DebugTapBlockBox: @unchecked Sendable {
    let block: AVAudioNodeTapBlock
    init(_ block: @escaping AVAudioNodeTapBlock) { self.block = block }
}

@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, *)
private func makeDebugCopyingTap(_ box: DebugTapBlockBox) -> @Sendable (AVReadOnlyAudioPCMBuffer, AVAudioTime) -> Void {
    { buffer, time in
        box.block(AVAudioPCMBuffer(copying: buffer), time)
    }
}
#endif

private func makeSourceRenderBlock(_ core: MixRenderCore) -> AVAudioSourceNodeRenderBlock {
    { isSilence, _, frameCount, data in
        let list = UnsafeMutableAudioBufferListPointer(data)
        guard list.count >= 2,
              let left = list[0].mData?.assumingMemoryBound(to: Float.self),
              let right = list[1].mData?.assumingMemoryBound(to: Float.self) else {
            return kAudioUnitErr_InvalidParameter
        }
        core.render(frames: Int(frameCount), left: left, right: right)
        isSilence.pointee = false
        return noErr
    }
}

@MainActor
final class MixEngine: ObservableObject {

    static let shared = MixEngine()

    enum Deck: Int, CaseIterable, Hashable, Identifiable, Sendable {
        case a = 0
        case b = 1

        var id: Int { rawValue }
        var other: Deck { self == .a ? .b : .a }
        var label: String { self == .a ? "A" : "B" }
    }

    enum EQBand: Int, CaseIterable, Hashable {
        case low = 0
        case mid = 1
        case high = 2

        var label: String {
            switch self {
            case .low:  return "Low"
            case .mid:  return "Mid"
            case .high: return "High"
            }
        }
    }

    enum FadeCurve {
        case linear
        case smooth
        case logarithmic

        var timeline: MixCurve {
            switch self {
            case .linear: return .linear
            case .smooth: return .smooth
            case .logarithmic: return .logarithmic
            }
        }
    }

    enum LoadStatus: Equatable {
        case empty
        case loading(Double)
        case ready
        case failed(String)

        var isLoading: Bool { if case .loading = self { return true }; return false }
        var isReady: Bool { self == .ready }
    }

    enum EffectSlot: Hashable, Sendable {
        case deck(Deck)
        case send

        var coreSlot: Int {
            switch self {
            case .deck(let deck): return deck.rawValue
            case .send: return 2
            }
        }
    }

    struct LoadedEffect: Equatable {
        let name: String
        let manufacturer: String
        let componentType: OSType
        let componentSubType: OSType
        let componentManufacturer: OSType
        var isBypassed: Bool
        var latencySeconds: TimeInterval

        var componentDescription: AudioComponentDescription {
            AudioComponentDescription(
                componentType: componentType,
                componentSubType: componentSubType,
                componentManufacturer: componentManufacturer,
                componentFlags: 0,
                componentFlagsMask: 0
            )
        }
    }

    struct DeckState: Equatable {
        var status: LoadStatus = .empty
        var isPlaying: Bool = false
        var position: TimeInterval = 0
        var duration: TimeInterval = 0
        var sourceURL: URL?
        var trackId: String?

        var gain: Double = 1.0
        var inputGain: Double = 0
        var holdsTail = false

        var low: Double = 0
        var mid: Double = 0
        var high: Double = 0

        var filterCutoff: Double = MixEngine.filterCutoffRange.upperBound
        var highPassCutoff: Double = MixEngine.filterCutoffRange.lowerBound
        var filterResonance: Double = 0
        var delayWet: Double = 0
        var reverbSend: Double = 0
        var effectSend: Double = 0

        var rate: Double = 1.0
        var pitch: Double = 0

        var loopStartSeconds: Double?
        var loopLengthSeconds: Double?

        var level: Float = 0
        var peak: Float = 0

        var progress: Double {
            guard duration > 0 else { return 0 }
            return min(1, max(0, position / duration))
        }
    }

    nonisolated static let eqGainRange: ClosedRange<Double> = -60...12
    nonisolated static let filterCutoffRange: ClosedRange<Double> = 30...20_000
    nonisolated static let filterOpenHertz: Double = 19_000
    nonisolated static let rateRange: ClosedRange<Double> = 0.5...2.0
    nonisolated static let pitchCentsRange: ClosedRange<Double> = -2400...2400
    nonisolated static let gainRange: ClosedRange<Double> = 0...2

    nonisolated static let lowShelfHertz: Double = MixIsolator.lowCrossoverHertz
    nonisolated static let bassKillDecibels: Double = -60

    @Published private(set) var decks: [DeckState] = [DeckState(), DeckState()]
    @Published private(set) var ownedControls: Set<MixControl> = []

    @Published var crossfade: Double = 0 {
        didSet {
            let clamped = min(1, max(0, crossfade))
            if clamped != crossfade { crossfade = clamped; return }
            guard !applyingSnapshot else { return }
            post(.ramp(.crossfade, to: clamped, frames: 0, curve: .linear), mirror: .crossfade)
        }
    }

    @Published var masterVolume: Double = 1.0 {
        didSet {
            let clamped = min(1, max(0, masterVolume))
            if clamped != masterVolume { masterVolume = clamped; return }
            guard !applyingSnapshot else { return }
            post(.ramp(.master, to: clamped, frames: 0, curve: .linear), mirror: .master)
        }
    }

    @Published private(set) var isRunning = false

    @Published private(set) var lastError: MixEngineError?

    @Published private(set) var effects: [EffectSlot: LoadedEffect] = [:]

    @Published private(set) var outputLatencySeconds: TimeInterval = 0

    @Published var performanceSchedules: [Deck: MixPerformanceSchedule] = [:]

    @Published var mixer = MixerState()
    var liveRamps: [Int: AutomationTarget] = [:]
    var scheduledTimelines: [Int32: MixTimeline] = [:]
    #if os(macOS)
    lazy var phonesOutput = MixPhonesOutput(core: core)
    #endif

    private var graphIsUsable = true

    #if DEBUG
    static let debugForceGraphBuildFailure =
        ProcessInfo.processInfo.environment["SOUNDING_TV_MIX_FORCE_GRAPH_FAILURE"] == "1"

    nonisolated(unsafe) static var debugForcePlaybackFailureArmed =
        ProcessInfo.processInfo.environment["SOUNDING_TV_MIX_FORCE_PLAYBACK_FAILURE"] == "1"
    #endif

    subscript(deck: Deck) -> DeckState {
        decks[deck.rawValue]
    }

    func localFileURL(for deck: Deck) -> URL? {
        sources[deck.rawValue]?.localURL
    }

    func setBeatGrid(_ grid: BeatGrid?, for deck: Deck) {
        beatGrids[deck.rawValue] = grid
        let table = grid.flatMap { MixBeatTable(grid: $0, sampleRate: sampleRate) }
        if let previous = beatTables[deck.rawValue] { retire(previous) }
        beatTables[deck.rawValue] = table
        send(.beats(seq: nextSequence(), deck: deck.rawValue, table: table.map { Unmanaged.passUnretained($0) }))
    }

    func beatGrid(for deck: Deck) -> BeatGrid? {
        beatGrids[deck.rawValue]
    }

    func currentPlayhead(for deck: Deck) -> TimeInterval {
        playheadPosition(for: deck) ?? decks[deck.rawValue].position
    }

    let core: MixRenderCore
    private let engine = AVAudioEngine()
    private var outputVolume: Double = PlayerService.storedVolume()
    private let sourceNode: AVAudioSourceNode
    var sampleRate: Double { core.sampleRate }

    private final class DeckSource {
        let source: MixSource
        let localURL: URL
        let sourceURL: URL
        var duration: TimeInterval { source.duration }

        init(source: MixSource, localURL: URL, sourceURL: URL) {
            self.source = source
            self.localURL = localURL
            self.sourceURL = sourceURL
        }
    }

    enum MirrorKey: Hashable {
        case parameter(Int)
        case playing(Int)
        case position(Int)
        case loop(Int)
        case crossfade
        case master
    }

    private var sources: [DeckSource?] = [nil, nil]
    private var beatTables: [MixBeatTable?] = [nil, nil]
    private var effectHosts: [EffectSlot: MixAudioUnitHost] = [:]
    private var retired: [(object: AnyObject, sequence: Int64)] = []
    private var loadTasks: [Task<Void, Never>?] = [nil, nil]
    private var loadGenerations: [Int] = [0, 0]
    private var deckCacheKeys: [String?] = [nil, nil]
    private var sequence: Int64 = 0
    private var groupCounter: Int32 = 0
    private var pendingMirror: [MirrorKey: Int64] = [:]
    private var applyingSnapshot = false
    private var ownedMask: UInt64 = 0
    private var userWriteDepth = 0
    private var lastSnapshot = MixCoreSnapshot()
    private var lastSnapshotWall = Date()

    private var tickTask: Task<Void, Never>?
    private var jogRestoreTasks: [Deck: Task<Void, Never>] = [:]
    private var idleTicks = 0
    private static let idleTicksBeforeSuspend = 20
    private var jogBaseRates: [Deck: Double] = [:]
    private var beatGrids: [BeatGrid?] = [nil, nil]

    private let cacheDirectory: URL
    let automationClock: MixAutomationClock
    var isOffline: Bool { automationClock.isOffline }

    private struct OfflineTimer {
        let due: TimeInterval?
        let anchorGroup: Int32?
        let anchorOffset: TimeInterval
        let sequence: Int
        let token: MixScheduledAction
        let action: @MainActor () -> Void
    }

    private var offlineTimers: [OfflineTimer] = []
    private var offlineTimerSequence = 0
    private var bassSwapToken: [Deck: MixScheduledAction] = [:]
    private var pausedAt: [Deck: Date] = [:]
    private var routeObserver: AnyCancellable?
    #if DEBUG
    var offlineSoloDeck: Deck? {
        didSet { send(.solo(seq: nextSequence(), deck: offlineSoloDeck?.rawValue ?? -1)) }
    }
    var offlineSoloRiser = false {
        didSet { send(.solo(seq: nextSequence(), deck: offlineSoloRiser ? 2 : -1)) }
    }
    #endif

    init(offline: Bool = false) {
        automationClock = MixAutomationClock(offline: offline)
        let core = MixRenderCore()
        self.core = core
        sourceNode = AVAudioSourceNode(format: MixEngine.canonicalFormat, renderBlock: makeSourceRenderBlock(core))
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        cacheDirectory = base.appendingPathComponent("MixEngine", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        if offline {
            do {
                try engine.enableManualRenderingMode(
                    .offline,
                    format: MixEngine.canonicalFormat,
                    maximumFrameCount: 4096
                )
            } catch {
                graphIsUsable = false
                lastError = .graphBuildFailed(error.localizedDescription)
            }
        }

        automationClock.attach(
            now: { [unowned self] in self.clockSeconds },
            freeze: { [unowned self] frozen in self.send(.freeze(seq: self.nextSequence(), frozen: frozen)) },
            jump: { [unowned self] seconds in
                self.send(.jumpClock(seq: self.nextSequence(), frames: Int64((seconds * self.sampleRate).rounded())))
            }
        )

        buildGraph()
        guard !offline else { return }
        observeConfigurationChanges()
        routeObserver = PlatformAudioSession.routeChanges
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshOutputLatency() }
            }

        let directory = cacheDirectory
        Task.detached(priority: .background) {
            SourceImporter.pruneCache(in: directory)
        }
    }

    deinit {
    }

    private func buildGraph() {
        engine.attach(sourceNode)
        #if DEBUG
        if MixEngine.debugForceGraphBuildFailure, !isOffline {
            graphIsUsable = false
            lastError = .graphBuildFailed("forced graph failure")
            return
        }
        #endif
        do {
            try connectNodeThrowing(sourceNode, to: engine.mainMixerNode, format: MixEngine.canonicalFormat)
        } catch {
            graphIsUsable = false
            lastError = .graphBuildFailed(error.localizedDescription)
            return
        }
        engine.prepare()
    }

    fileprivate static var canonicalFormat: AVAudioFormat {
        AVAudioFormat(
            standardFormatWithSampleRate: DJEngineConstants.canonicalSampleRate,
            channels: DJEngineConstants.canonicalChannels
        )!
    }

    // MARK: - Commands

    private func nextSequence() -> Int64 {
        sequence += 1
        return sequence
    }

    private func send(_ command: MixCommand) {
        if !core.ring.push(command) {
            drainWhileIdle()
            _ = core.ring.push(command)
        }
        if !isRenderingLive { drainWhileIdle() }
    }

    private var isRenderingLive: Bool { !isOffline && engine.isRunning }

    private func drainWhileIdle() {
        guard !isRenderingLive else { return }
        core.render(frames: 0, left: scratch, right: scratch)
        refreshFromCore()
    }

    private let scratch: UnsafeMutablePointer<Float> = {
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: 16)
        pointer.initialize(repeating: 0, count: 16)
        return pointer
    }()

    func post(_ action: MixTimelineAction, at clock: Int64? = nil, group: Int32 = 0, mirror key: MirrorKey? = nil) {
        let seq = nextSequence()
        if let key { pendingMirror[key] = seq }
        send(.event(seq: seq, time: clock ?? 0, immediate: clock == nil, group: group, action: action))
    }

    private func retire(_ object: AnyObject) {
        retired.append((object, sequence + 1))
    }

    func makeGroup() -> Int32 {
        groupCounter &+= 1
        if groupCounter == 0 { groupCounter = 1 }
        return groupCounter
    }

    func schedule(_ timeline: MixTimeline, group: Int32) {
        scheduledTimelines[group] = timeline
        for event in timeline.events {
            send(.event(seq: nextSequence(), time: event.offset, immediate: false, group: group, action: event.action))
        }
        send(.anchor(seq: nextSequence(), group: group, anchor: timeline.anchor))
    }

    func cancelTimeline(group: Int32) {
        scheduledTimelines[group] = nil
        send(.cancelGroup(seq: nextSequence(), group: group))
    }

    func restoreTimeline(group: Int32) {
        scheduledTimelines[group] = nil
        send(.restoreGroup(seq: nextSequence(), group: group))
    }

    func mixSource(for deck: Deck) -> MixSource? {
        sources[deck.rawValue]?.source
    }

    func anchorClockSeconds(for group: Int32) -> TimeInterval? {
        refreshFromCoreIfOffline()
        return lastSnapshot.anchorClock(for: group).map { Double($0) / sampleRate }
    }

    var coreSnapshot: MixCoreSnapshot {
        refreshFromCoreIfOffline()
        return lastSnapshot
    }

    private func refreshFromCoreIfOffline() {
        if isOffline || !isRenderingLive { lastSnapshot = core.snapshot() }
    }

    var clockSeconds: TimeInterval {
        let snapshot = core.snapshot()
        var seconds = Double(snapshot.clock) / sampleRate
        if isRenderingLive, !snapshot.frozen, snapshot.hostTime > 0 {
            seconds += min(0.1, hostSecondsSince(snapshot.hostTime))
        }
        return seconds
    }

    private func hostSecondsSince(_ hostTime: UInt64) -> TimeInterval {
        let now = mach_absolute_time()
        guard now > hostTime else { return 0 }
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(now - hostTime) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }

    // MARK: - Lifecycle

    private func observeConfigurationChanges() {
        guard !configObserverStorage.isRegistered else { return }
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleConfigurationChange()
            }
        }
        configObserverStorage.set(observer)
    }

    @discardableResult
    func start() -> Bool {
        guard graphIsUsable else {
            isRunning = false
            return false
        }

        idleTicks = 0
        if isOffline {
            guard !engine.isRunning else { return true }
            do {
                try engine.start()
                isRunning = true
                return true
            } catch {
                lastError = .engineStartFailed(error.localizedDescription)
                return false
            }
        }
        guard !engine.isRunning else {
            isRunning = true
            startTicking()
            return true
        }

        do {
            PlatformAudioSession.activatePlayback()
            observeConfigurationChanges()
            engine.mainMixerNode.outputVolume = effectiveOutputVolume
            engine.prepare()
            try engine.start()
            isRunning = true
            if case .engineStartFailed = lastError { lastError = nil }
            refreshOutputLatency()
            startTicking()
            return true
        } catch {
            isRunning = false
            lastError = .engineStartFailed(error.localizedDescription)
            return false
        }
    }

    func stop() {
        if automationClock.isPaused { automationClock.resume() }
        for deck in Deck.allCases {
            loadTasks[deck.rawValue]?.cancel()
            loadTasks[deck.rawValue] = nil
        }
        for task in jogRestoreTasks.values { task.cancel() }
        jogRestoreTasks.removeAll()
        for token in bassSwapToken.values { token.cancel() }
        bassSwapToken.removeAll()
        tickTask?.cancel()
        tickTask = nil
        offlineTimers.removeAll()

        teardownAudioResources()

        for deck in Deck.allCases {
            if let source = sources[deck.rawValue] {
                source.source.close()
                retire(source)
            }
            if let table = beatTables[deck.rawValue] { retire(table) }
            send(.load(seq: nextSequence(), deck: deck.rawValue, source: nil))
            send(.beats(seq: nextSequence(), deck: deck.rawValue, table: nil))
        }
        post(.resetParameters)
        post(.clearFX)
        sources = [nil, nil]
        beatTables = [nil, nil]
        beatGrids = [nil, nil]
        applyingSnapshot = true
        decks = [DeckState(), DeckState()]
        crossfade = 0
        masterVolume = 1
        applyingSnapshot = false
        pendingMirror.removeAll()
        drainWhileIdle()
        releaseRetired()
        isRunning = false
    }

    func teardownAudioResources() {
        if let observer = configObserverStorage.take() {
            NotificationCenter.default.removeObserver(observer)
        }
        engine.stop()
    }

    private func suspendIfIdle() {
        let snapshot = lastSnapshot
        let busy = snapshot.a.playing || snapshot.b.playing || !jogRestoreTasks.isEmpty
            || decks.contains(where: \.isPlaying)
        guard !busy else {
            idleTicks = 0
            return
        }
        idleTicks += 1
        guard idleTicks >= Self.idleTicksBeforeSuspend else { return }
        idleTicks = 0
        tickTask?.cancel()
        tickTask = nil
        for index in decks.indices where decks[index].level != 0 || decks[index].peak != 0 {
            decks[index].level = 0
            decks[index].peak = 0
        }
        engine.pause()
        isRunning = false
    }

    @MainActor
    func shutdown() {
        teardownAudioResources()
    }

    // MARK: - Stream tap

    func installStreamTap(ring: SonosAudioRingBuffer) {
        streamTapRing = ring
        guard !isOffline else { return }
        sourceNode.removeTap(onBus: 0)
        SonosStreamTap.install(on: sourceNode, ring: ring)
    }

    func removeStreamTap() {
        guard streamTapRing != nil else { return }
        streamTapRing = nil
        guard !isOffline else { return }
        sourceNode.removeTap(onBus: 0)
    }

    var hasStreamTap: Bool { streamTapRing != nil }

    var mutesLocalOutput = false {
        didSet {
            guard mutesLocalOutput != oldValue, !isOffline else { return }
            engine.mainMixerNode.outputVolume = effectiveOutputVolume
        }
    }

    var additionalOutputLatency: TimeInterval = 0 {
        didSet {
            guard additionalOutputLatency != oldValue else { return }
            refreshOutputLatency()
        }
    }

    private var streamTapRing: SonosAudioRingBuffer?

    #if DEBUG
    // MARK: - Test-only mixer tap
    func debugInstallMainMixerTap(bufferSize: AVAudioFrameCount, block: @escaping AVAudioNodeTapBlock) {
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, *) {
            try? engine.mainMixerNode.installAudioTap(
                onBus: 0,
                bufferSize: bufferSize,
                format: nil,
                tapProvider: makeDebugCopyingTap(DebugTapBlockBox(block))
            )
        } else {
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: bufferSize, format: nil, block: block)
        }
    }

    func debugRemoveMainMixerTap() {
        engine.mainMixerNode.removeTap(onBus: 0)
    }

    func debugSimulateConfigurationChange() {
        handleConfigurationChange()
    }
    #endif

    private let configObserverStorage = ObserverBox()

    fileprivate final class ObserverBox: @unchecked Sendable {
        private let lock = NSLock()
        private var observer: NSObjectProtocol?

        func set(_ value: NSObjectProtocol?) {
            lock.lock()
            observer = value
            lock.unlock()
        }

        func take() -> NSObjectProtocol? {
            lock.lock()
            let value = observer
            observer = nil
            lock.unlock()
            return value
        }

        var isRegistered: Bool {
            lock.lock()
            defer { lock.unlock() }
            return observer != nil
        }
    }

    private func handleConfigurationChange() {
        let wasPlaying = decks.contains(where: \.isPlaying) || lastSnapshot.a.playing || lastSnapshot.b.playing
        if isOffline {
            engine.stop()
            _ = start()
            return
        }
        engine.stop()
        isRunning = false
        do {
            try connectNodeThrowing(sourceNode, to: engine.mainMixerNode, format: MixEngine.canonicalFormat)
        } catch {
            graphIsUsable = false
            lastError = .graphBuildFailed(error.localizedDescription)
            return
        }
        if let streamTapRing {
            sourceNode.removeTap(onBus: 0)
            SonosStreamTap.install(on: sourceNode, ring: streamTapRing)
        }
        engine.mainMixerNode.outputVolume = effectiveOutputVolume
        PlatformAudioSession.refreshRoute()
        guard wasPlaying || sources.contains(where: { $0 != nil }) else { return }
        _ = start()
    }

    private func refreshOutputLatency() {
        var latency = engine.outputNode.presentationLatency
        #if os(iOS) || os(tvOS)
        let session = AVAudioSession.sharedInstance()
        latency += session.outputLatency + session.ioBufferDuration
        #endif
        latency += Double(MixLimiter.lookahead) / sampleRate
        latency += max(0, additionalOutputLatency.isFinite ? additionalOutputLatency : 0)
        outputLatencySeconds = max(0, latency.isFinite ? latency : 0)
    }

    func audiblePosition(of deck: Deck) -> TimeInterval {
        let position = livePosition(of: deck)
        guard !isOffline else { return position }
        let rate = decks[deck.rawValue].rate
        if decks[deck.rawValue].isPlaying {
            return max(0, position - outputLatencySeconds * rate)
        }
        guard let pausedAt = pausedAt[deck] else { return position }
        let draining = max(0, outputLatencySeconds - Date().timeIntervalSince(pausedAt))
        return max(0, position - draining * rate)
    }

    // MARK: - Loading

    func load(url: URL, into deck: Deck, trackId: String? = nil, cacheKey: String? = nil) async throws {
        let index = deck.rawValue

        loadGenerations[index] &+= 1
        let generation = loadGenerations[index]

        clearDeckPlayback(deck: deck)
        decks[index].sourceURL = url
        decks[index].trackId = trackId
        decks[index].status = .loading(0)

        let directory = cacheDirectory
        let key = cacheKey ?? MixEngine.defaultCacheKey(for: url)

        if let previousKey = deckCacheKeys[index], previousKey != key {
            SourceImporter.unprotect(cacheKey: previousKey, in: directory)
        }
        SourceImporter.protect(cacheKey: key, in: directory)
        deckCacheKeys[index] = key

        let progressGate = LoadProgressGate()
        do {
            let localURL = try await Self.materialiseWithRetry(
                remoteURL: url,
                cacheKey: key,
                in: directory
            ) { [weak self] fraction in
                guard progressGate.admits(fraction) else { return }
                Task { @MainActor in
                    guard let self, self.loadGenerations[index] == generation else { return }
                    self.decks[index].status = .loading(fraction * 0.98)
                }
            }

            guard loadGenerations[index] == generation else { throw MixEngineError.cancelled }
            try Task.checkCancellation()

            let source = try await Task.detached(priority: .userInitiated) {
                try MixSource(url: localURL)
            }.value
            guard loadGenerations[index] == generation else { throw MixEngineError.cancelled }
            source.prefetch(around: 0)
            _ = await source.waitUntilLoaded(frame: 0, timeout: 3)
            guard loadGenerations[index] == generation else { throw MixEngineError.cancelled }

            install(DeckSource(source: source, localURL: localURL, sourceURL: url), on: deck)

            if sources[deck.other.rawValue] == nil {
                crossfade = deck == .a ? 0 : 1
            }

            guard start() else {
                throw lastError ?? MixEngineError.engineStartFailed("the audio engine could not start")
            }
        } catch {
            let mixError: MixEngineError
            if error is CancellationError {
                mixError = .cancelled
            } else if let known = error as? MixEngineError {
                mixError = known
            } else {
                mixError = .decodeFailed(error.localizedDescription)
            }

            if loadGenerations[index] == generation {
                if case .cancelled = mixError {
                    decks[index].status = .empty
                } else {
                    Log.dj.error("[Mix] deck \(index, privacy: .public) load failed: \(mixError.errorDescription ?? "", privacy: .public)")
                    decks[index].status = .failed(mixError.displayMessage)
                    lastError = mixError
                }
            }
            throw mixError
        }
    }

    private func install(_ source: DeckSource, on deck: Deck) {
        let index = deck.rawValue
        if let previous = sources[index] {
            previous.source.close()
            retire(previous)
        }
        sources[index] = source
        send(.load(seq: nextSequence(), deck: index, source: Unmanaged.passUnretained(source.source)))
        if let table = beatTables[index] {
            send(.beats(seq: nextSequence(), deck: index, table: Unmanaged.passUnretained(table)))
        }
        decks[index].duration = source.duration
        decks[index].position = 0
        decks[index].isPlaying = false
        decks[index].status = .ready
        pendingMirror[.position(index)] = sequence
        pendingMirror[.playing(index)] = sequence
    }

    private static func materialiseWithRetry(
        remoteURL: URL,
        cacheKey: String,
        in directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        do {
            return try await SourceImporter.materialise(
                remoteURL: remoteURL, cacheKey: cacheKey, in: directory, progress: progress
            )
        } catch {
            guard isTransientNetworkFailure(error), !Task.isCancelled else { throw error }
            try? await Task.sleep(nanoseconds: 500_000_000)
            return try await SourceImporter.materialise(
                remoteURL: remoteURL, cacheKey: cacheKey, in: directory, progress: progress
            )
        }
    }

    private static func isTransientNetworkFailure(_ error: Error) -> Bool {
        guard let mixError = error as? MixEngineError else { return false }
        switch mixError {
        case .networkFailure, .httpStatus: return true
        default: return false
        }
    }

    func hasCachedSource(cacheKey: String) -> Bool {
        SourceImporter.hasCachedSource(cacheKey: cacheKey, in: cacheDirectory)
    }

    func warmCache(remoteURL: URL, cacheKey: String) async {
        _ = try? await SourceImporter.materialise(
            remoteURL: remoteURL, cacheKey: cacheKey, in: cacheDirectory
        ) { _ in }
    }

    func unload(deck: Deck) {
        let index = deck.rawValue
        loadTasks[index]?.cancel()
        loadTasks[index] = nil
        loadGenerations[index] &+= 1
        clearDeckPlayback(deck: deck)
    }

    private func clearDeckPlayback(deck: Deck) {
        let index = deck.rawValue
        cancelPerformance(on: deck)
        if let key = deckCacheKeys[index] {
            SourceImporter.unprotect(cacheKey: key, in: cacheDirectory)
            deckCacheKeys[index] = nil
        }
        if let previous = sources[index] {
            previous.source.close()
            retire(previous)
        }
        sources[index] = nil
        if let table = beatTables[index] { retire(table) }
        beatTables[index] = nil
        beatGrids[index] = nil
        send(.load(seq: nextSequence(), deck: index, source: nil))
        send(.beats(seq: nextSequence(), deck: index, table: nil))

        var state = decks[index]
        state.status = .empty
        state.isPlaying = false
        state.position = 0
        state.duration = 0
        state.sourceURL = nil
        state.trackId = nil
        state.level = 0
        state.peak = 0
        state.loopStartSeconds = nil
        state.loopLengthSeconds = nil
        decks[index] = state
        pendingMirror[.position(index)] = sequence
        pendingMirror[.playing(index)] = sequence
        pendingMirror[.loop(index)] = sequence
    }

    private static func defaultCacheKey(for url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return (components?.host ?? "") + (components?.path ?? url.absoluteString)
    }

    private func clearPlaybackFailure() {
        if case .playbackStartFailed = lastError { lastError = nil }
    }

    // MARK: - Transport

    private func playbackCanStart(_ deck: Deck) -> Bool {
        #if DEBUG
        if MixEngine.debugForcePlaybackFailureArmed {
            MixEngine.debugForcePlaybackFailureArmed = false
            post(.stop(deck: deck.rawValue), mirror: .playing(deck.rawValue))
            decks[deck.rawValue].isPlaying = false
            lastError = .playbackStartFailed("forced playback failure")
            return false
        }
        #endif
        return true
    }

    private func markPlaying(_ deck: Deck) {
        decks[deck.rawValue].isPlaying = true
        pendingMirror[.playing(deck.rawValue)] = sequence
        clearPlaybackFailure()
    }

    func play(deck: Deck) {
        let index = deck.rawValue
        guard sources[index] != nil else { return }
        guard start() else { return }
        if automationClock.isPaused, !decks.contains(where: \.isPlaying) { automationClock.resume() }
        guard playbackCanStart(deck) else { return }
        post(.start(deck: index, fromFrame: nil))
        markPlaying(deck)
    }

    func pause(deck: Deck) {
        let index = deck.rawValue
        guard sources[index] != nil else { return }
        post(.stop(deck: index))
        if decks[index].isPlaying { pausedAt[deck] = Date() }
        decks[index].isPlaying = false
        pendingMirror[.playing(index)] = sequence
    }

    func togglePlayPause(deck: Deck) {
        decks[deck.rawValue].isPlaying ? pause(deck: deck) : play(deck: deck)
    }

    func stop(deck: Deck) {
        let index = deck.rawValue
        guard sources[index] != nil else { return }
        post(.clearLoop(deck: index))
        post(.stop(deck: index))
        post(.seek(deck: index, frame: 0))
        decks[index].isPlaying = false
        decks[index].position = 0
        decks[index].loopStartSeconds = nil
        decks[index].loopLengthSeconds = nil
        pendingMirror[.playing(index)] = sequence
        pendingMirror[.position(index)] = sequence
        pendingMirror[.loop(index)] = sequence
    }

    func seek(deck: Deck, to time: TimeInterval) {
        let index = deck.rawValue
        guard let source = sources[index] else { return }
        let target = min(max(0, time), source.duration)
        cancelPerformance(on: deck)
        source.source.pin(frame: Int(target * sampleRate))
        post(.clearLoop(deck: index))
        post(.seek(deck: index, frame: target * sampleRate))
        decks[index].position = target
        decks[index].loopStartSeconds = nil
        decks[index].loopLengthSeconds = nil
        pendingMirror[.position(index)] = sequence
        pendingMirror[.loop(index)] = sequence
        if decks[index].isPlaying {
            guard start(), playbackCanStart(deck) else { return }
            markPlaying(deck)
        }
    }

    func play(decks requested: [Deck], lead: TimeInterval = 0.05) {
        let ready = requested.filter { sources[$0.rawValue] != nil }
        guard !ready.isEmpty, start() else { return }
        for deck in ready {
            guard playbackCanStart(deck) else { continue }
            post(.start(deck: deck.rawValue, fromFrame: nil))
            markPlaying(deck)
        }
    }

    func seek(_ targets: [(deck: Deck, seconds: TimeInterval)], lead: TimeInterval = 0.05) {
        let valid = targets.filter { sources[$0.deck.rawValue] != nil }
        guard !valid.isEmpty else { return }
        for target in valid {
            let index = target.deck.rawValue
            guard let source = sources[index] else { continue }
            let bounded = min(max(0, target.seconds), source.duration)
            cancelPerformance(on: target.deck)
            source.source.pin(frame: Int(bounded * sampleRate))
            post(.clearLoop(deck: index))
            post(.seek(deck: index, frame: bounded * sampleRate))
            decks[index].position = bounded
            decks[index].loopStartSeconds = nil
            decks[index].loopLengthSeconds = nil
            pendingMirror[.position(index)] = sequence
            pendingMirror[.loop(index)] = sequence
        }
    }

    func seekLinked(lead: Deck, to seconds: TimeInterval, follower: Deck, movesClock: Bool) {
        guard let source = sources[lead.rawValue], sources[follower.rawValue] != nil else { return }
        let bounded = min(max(0, seconds), source.duration)
        cancelPerformance(on: lead)
        cancelPerformance(on: follower)
        source.source.pin(frame: Int(bounded * sampleRate))
        post(.seekLinked(lead: lead.rawValue, frame: bounded * sampleRate, follower: follower.rawValue, movesClock: movesClock))
        decks[lead.rawValue].position = bounded
        pendingMirror[.position(lead.rawValue)] = sequence
        pendingMirror[.position(follower.rawValue)] = sequence
    }

    func seek(deck: Deck, byNudging seconds: TimeInterval) {
        seek(deck: deck, to: decks[deck.rawValue].position + seconds)
    }

    func nudge(deck: Deck, amount: Double, releaseSeconds: TimeInterval = 0.16) {
        guard decks[deck.rawValue].isPlaying else { return }
        let base = jogBaseRates[deck] ?? decks[deck.rawValue].rate
        jogBaseRates[deck] = base
        jogRestoreTasks[deck]?.cancel()

        let bend = min(0.08, max(-0.08, amount))
        applyRate(base * (1 + bend), on: deck, over: 0.025)

        jogRestoreTasks[deck] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0.08, releaseSeconds)))
            guard !Task.isCancelled, let self else { return }
            self.applyRate(base, on: deck, over: 0.10)
            self.jogBaseRates[deck] = nil
            self.jogRestoreTasks[deck] = nil
        }
    }

    func phaseErrorSeconds(_ deck: Deck, relativeTo reference: Deck) -> Double? {
        guard let grid = beatGrids[deck.rawValue], let referenceGrid = beatGrids[reference.rawValue],
              grid.beatPeriod > 0, referenceGrid.beatPeriod > 0 else { return nil }
        let deckPosition = livePosition(of: deck)
        let referencePosition = livePosition(of: reference)
        let deckPhase = beatPhase(position: deckPosition, grid: grid)
        let referencePhase = beatPhase(position: referencePosition, grid: referenceGrid)
        var difference = deckPhase - referencePhase
        if difference > 0.5 { difference -= 1 }
        if difference < -0.5 { difference += 1 }
        return difference * referenceGrid.beatPeriod / max(0.01, decks[reference.rawValue].rate)
    }

    @discardableResult
    func sync(_ deck: Deck, to reference: Deck, maxPercent: Double = MixEngine.maxTempoMatchPercent) -> Bool {
        guard let sourceGrid = beatGrids[deck.rawValue], let referenceGrid = beatGrids[reference.rawValue],
              sourceGrid.beatPeriod > 0, referenceGrid.beatPeriod > 0 else { return false }
        let ratio = sourceGrid.beatPeriod / referenceGrid.beatPeriod * decks[reference.rawValue].rate
        setRateRatio(ratio, on: deck, maxPercent: maxPercent)
        if beatTables[deck.rawValue] != nil, beatTables[reference.rawValue] != nil {
            post(.phaseLock(deck: deck.rawValue, reference: reference.rawValue))
        } else if let error = phaseErrorSeconds(deck, relativeTo: reference), abs(error) > 0.004 {
            nudge(deck: deck, amount: -error / referenceGrid.beatPeriod * 8, releaseSeconds: 0.28)
        }
        return true
    }

    func unsync(_ deck: Deck) {
        post(.phaseUnlock(deck: deck.rawValue))
    }

    private func beatPhase(position: TimeInterval, grid: BeatGrid) -> Double {
        let beats = (position - grid.anchor) / grid.beatPeriod
        let fraction = beats - floor(beats)
        return fraction < 0 ? fraction + 1 : fraction
    }

    enum CueResult: Equatable {
        case aligned(leadSeconds: TimeInterval)
        case unaligned(reason: String)
        case failed(reason: String)
    }

    func wallLeadSeconds(
        on reference: Deck,
        to referenceSourceSeconds: TimeInterval,
        minimumLead: TimeInterval = 0.08
    ) -> TimeInterval? {
        guard referenceSourceSeconds.isFinite,
              let referencePosition = playheadPosition(for: reference) else { return nil }
        let referenceRate = max(0.01, decks[reference.rawValue].rate)
        let lead = (referenceSourceSeconds - referencePosition) / referenceRate
        guard lead.isFinite, lead >= minimumLead, lead < 30 else { return nil }
        return lead
    }

    func alignmentSourceSeconds(
        on reference: Deck,
        referenceBeatPeriod: Double,
        referenceGridAnchor: TimeInterval,
        requested: TimeInterval?,
        beatsPerAlignment: Int,
        minimumLead: TimeInterval
    ) -> TimeInterval? {
        guard let referencePosition = playheadPosition(for: reference), decks[reference.rawValue].isPlaying else { return nil }
        let referenceRate = max(0.01, decks[reference.rawValue].rate)
        let earliest = referencePosition + minimumLead * referenceRate
        if let requested, requested.isFinite, requested >= earliest { return requested }
        guard referenceBeatPeriod.isFinite, referenceBeatPeriod > 0.05 else { return nil }
        let alignment = referenceBeatPeriod * Double(max(1, beatsPerAlignment))
        let steps = ((earliest - referenceGridAnchor) / alignment).rounded(.up)
        let next = referenceGridAnchor + steps * alignment
        let lead = (next - referencePosition) / referenceRate
        guard lead.isFinite, lead > 0, lead < 30 else { return nil }
        return next
    }

    @discardableResult
    func cue(
        deck: Deck,
        to sourceSeconds: TimeInterval,
        alignedTo reference: Deck,
        referenceBeatPeriod: Double,
        referenceGridAnchor: TimeInterval = 0,
        referenceSourceSeconds: TimeInterval? = nil,
        beatsPerAlignment: Int = 4,
        minimumLead: TimeInterval = 0.08
    ) -> CueResult {
        let index = deck.rawValue
        guard let source = sources[index] else { return .failed(reason: "deck \(deck.label) is empty") }
        guard start() else { return .failed(reason: "audio engine would not start") }
        let target = min(max(0, sourceSeconds), source.duration)
        source.source.pin(frame: Int(target * sampleRate))

        func startImmediately(_ reason: String) -> CueResult {
            post(.clearLoop(deck: index))
            post(.seek(deck: index, frame: target * sampleRate))
            decks[index].position = target
            pendingMirror[.position(index)] = sequence
            if playbackCanStart(deck) {
                post(.start(deck: index, fromFrame: nil))
                markPlaying(deck)
            }
            return .unaligned(reason: reason)
        }

        guard decks[reference.rawValue].isPlaying, sources[reference.rawValue] != nil else {
            return startImmediately("outgoing deck has no render clock yet")
        }
        guard let alignment = alignmentSourceSeconds(
            on: reference,
            referenceBeatPeriod: referenceBeatPeriod,
            referenceGridAnchor: referenceGridAnchor,
            requested: referenceSourceSeconds,
            beatsPerAlignment: beatsPerAlignment,
            minimumLead: minimumLead
        ), let lead = wallLeadSeconds(on: reference, to: alignment, minimumLead: 0) else {
            return startImmediately(referenceBeatPeriod > 0.05 ? "next downbeat is not within a sane lead time" : "no measured tempo on the outgoing track")
        }

        post(.clearLoop(deck: index))
        post(.seek(deck: index, frame: target * sampleRate))
        decks[index].position = target
        pendingMirror[.position(index)] = sequence
        guard playbackCanStart(deck) else { return .aligned(leadSeconds: lead) }
        var timeline = MixTimeline(anchor: .deckPosition(deck: reference.rawValue, frame: alignment * sampleRate))
        timeline.events = [.init(offset: 0, action: .start(deck: index, fromFrame: target * sampleRate))]
        schedule(timeline, group: makeGroup())
        markPlaying(deck)
        return .aligned(leadSeconds: lead)
    }

    // MARK: - Loops

    func setLoop(on deck: Deck, startSeconds: Double, lengthSeconds: Double) {
        let index = deck.rawValue
        guard let source = sources[index] else { return }
        guard let bounds = LoopMath.resolve(
            startSeconds: startSeconds,
            lengthSeconds: lengthSeconds,
            durationSeconds: source.duration,
            sampleRate: sampleRate
        ) else { return }
        post(.loop(deck: index, startFrame: Double(bounds.startFrame), lengthFrames: Double(bounds.lengthFrames)))
        decks[index].loopStartSeconds = Double(bounds.startFrame) / sampleRate
        decks[index].loopLengthSeconds = Double(bounds.lengthFrames) / sampleRate
        pendingMirror[.loop(index)] = sequence
        if decks[index].isPlaying, start(), playbackCanStart(deck) {
            markPlaying(deck)
        }
    }

    func setQuantizedLoop(on deck: Deck, near seconds: Double, beats: Double) {
        guard beats.isFinite, beats > 0, let grid = beatGrid(for: deck), grid.beatPeriod > 0 else {
            return
        }
        let start = MixTimeline.loopStart(near: seconds, grid: grid)
        setLoop(on: deck, startSeconds: start, lengthSeconds: beats * grid.localBeatPeriod(at: start))
    }

    func forceClearLoop(on deck: Deck) {
        let index = deck.rawValue
        guard sources[index] != nil else { return }
        post(.clearLoop(deck: index))
        decks[index].loopStartSeconds = nil
        decks[index].loopLengthSeconds = nil
        pendingMirror[.loop(index)] = sequence
    }

    func clearLoop(on deck: Deck) {
        let index = deck.rawValue
        guard sources[index] != nil, decks[index].loopLengthSeconds != nil else { return }
        post(.clearLoop(deck: index))
        decks[index].loopStartSeconds = nil
        decks[index].loopLengthSeconds = nil
        pendingMirror[.loop(index)] = sequence
        if decks[index].isPlaying, start(), playbackCanStart(deck) {
            markPlaying(deck)
        }
    }

    func deckStatePayload(
        _ deck: Deck,
        title: String? = nil,
        artist: String? = nil,
        bpm: Double? = nil,
        role: DJDeckRole? = nil,
        phaseErrorSeconds: Double? = nil
    ) -> DJDeckStatePayload {
        let state = decks[deck.rawValue]
        func finite(_ value: Double, _ fallback: Double = 0) -> Double {
            value.isFinite ? value : fallback
        }
        let position = max(0.0, finite(state.position))
        let duration = max(0.0, finite(state.duration))
        let loopStart = state.loopStartSeconds.map { max(0.0, finite($0)) }
        let loopLength = state.loopLengthSeconds.map { max(0.0, finite($0)) }
        return DJDeckStatePayload(
            trackId: state.trackId,
            title: title,
            artist: artist,
            positionSeconds: position,
            durationSeconds: duration,
            isPlaying: state.isPlaying,
            eqLowDb: finite(state.low),
            eqMidDb: finite(state.mid),
            eqHighDb: finite(state.high),
            filterCutoffHz: finite(state.filterCutoff, 20_000),
            filterResonance: finite(state.filterResonance),
            rate: finite(state.rate, 1),
            bpm: bpm,
            loopStartSeconds: loopStart,
            loopLengthSeconds: loopLength,
            role: role,
            level: Double(state.level),
            peak: Double(state.peak),
            isClipping: state.peak >= 0.985,
            phaseErrorSeconds: phaseErrorSeconds
        )
    }

    // MARK: - Parameters

    private func frames(_ seconds: TimeInterval) -> Int64 {
        Int64((max(0, seconds.isFinite ? seconds : 0) * sampleRate).rounded())
    }

    func ramp(_ parameter: MixParameter, to value: Double, over duration: TimeInterval, curve: MixCurve = .linear) {
        guard !isAutomationBlocked(parameter) else { return }
        let immediate = duration <= 0.01
        recordLiveRamp(parameter, to: value, over: duration)
        post(.ramp(parameter, to: value, frames: immediate ? 0 : frames(duration), curve: curve), mirror: .parameter(parameter.raw))
        if immediate {
            applyMirror(parameter, value)
        } else {
            pendingMirror[.parameter(parameter.raw)] = nil
            if !isRenderingLive { refreshFromCore() }
        }
    }

    private func applyMirror(_ parameter: MixParameter, _ value: Double) {
        applyingSnapshot = true
        defer { applyingSnapshot = false }
        if parameter == .crossfade { crossfade = value; return }
        if parameter == .master { masterVolume = value; return }
        guard let d = parameter.deck else { return }
        var state = decks[d]
        switch parameter.slot {
        case 0: state.gain = value
        case 1: state.inputGain = value
        case 2: state.low = value
        case 3: state.mid = value
        case 4: state.high = value
        case 5: state.filterCutoff = value
        case 6: state.highPassCutoff = value
        case 7: state.filterResonance = value
        case 8: state.delayWet = value
        case 9: state.reverbSend = value
        case 10: state.effectSend = value
        case 11: state.rate = value
        case 12: state.pitch = value
        case 13: state.holdsTail = value > 0.5
        default: break
        }
        if state != decks[d] { decks[d] = state }
    }

    func crossfade(to value: Double, over duration: TimeInterval, curve: FadeCurve = .linear) {
        ramp(.crossfade, to: min(1, max(0, value)), over: duration, curve: curve.timeline)
    }

    func crossfade(to deck: Deck, over duration: TimeInterval, curve: FadeCurve = .linear) {
        crossfade(to: deck == .a ? 0 : 1, over: duration, curve: curve)
    }

    func setOutputVolume(_ volume: Double) {
        outputVolume = min(1, max(0, volume))
        guard !isOffline else { return }
        engine.mainMixerNode.outputVolume = effectiveOutputVolume
    }

    private var effectiveOutputVolume: Float {
        mutesLocalOutput ? 0 : Float(outputVolume)
    }

    func setGain(_ gain: Double, on deck: Deck, over duration: TimeInterval = 0) {
        ramp(.gain(deck.rawValue), to: gain.clamped(to: MixEngine.gainRange), over: duration)
    }

    func setEQ(_ band: EQBand, on deck: Deck, toDecibels decibels: Double, over duration: TimeInterval = 0) {
        let parameter: MixParameter
        switch band {
        case .low: parameter = .eqLow(deck.rawValue)
        case .mid: parameter = .eqMid(deck.rawValue)
        case .high: parameter = .eqHigh(deck.rawValue)
        }
        ramp(parameter, to: decibels.clamped(to: MixEngine.eqGainRange), over: duration)
    }

    func eqValue(_ band: EQBand, on deck: Deck) -> Double {
        let state = decks[deck.rawValue]
        switch band {
        case .low:  return state.low
        case .mid:  return state.mid
        case .high: return state.high
        }
    }

    func swapBass(
        from outgoing: Deck,
        to incoming: Deck,
        after delay: TimeInterval = 0,
        over duration: TimeInterval
    ) {
        let kill = MixEngine.bassKillDecibels
        bassSwapToken[outgoing]?.cancel()
        bassSwapToken[outgoing] = nil
        guard delay > 0.01 else {
            setEQ(.low, on: outgoing, toDecibels: kill, over: duration)
            setEQ(.low, on: incoming, toDecibels: 0, over: duration)
            return
        }
        let at = lastSnapshot.clock + frames(delay)
        if !isAutomationBlocked(.eqLow(outgoing.rawValue)) {
            post(.ramp(.eqLow(outgoing.rawValue), to: kill, frames: frames(duration), curve: .power), at: at)
        }
        if !isAutomationBlocked(.eqLow(incoming.rawValue)) {
            post(.ramp(.eqLow(incoming.rawValue), to: 0, frames: frames(duration), curve: .power), at: at)
        }
    }

    // MARK: - Ownership

    func takeOver(_ control: MixControl) {
        guard !ownedControls.contains(control) else { return }
        ownedControls.insert(control)
        syncOwnership()
    }

    func handBack(_ control: MixControl) {
        guard ownedControls.remove(control) != nil else { return }
        syncOwnership()
    }

    func handBackAll() {
        guard !ownedControls.isEmpty else { return }
        ownedControls.removeAll()
        syncOwnership()
    }

    func asUser(_ body: () -> Void) {
        userWriteDepth += 1
        defer { userWriteDepth -= 1 }
        body()
    }

    func isOwned(_ parameter: MixParameter) -> Bool {
        ownedMask & (UInt64(1) << UInt64(parameter.raw)) != 0
    }

    private func isAutomationBlocked(_ parameter: MixParameter) -> Bool {
        userWriteDepth == 0 && isOwned(parameter)
    }

    private func syncOwnership() {
        ownedMask = ownedControls.reduce(UInt64(0)) { mask, control in
            control.parameters.reduce(mask) { $0 | (UInt64(1) << UInt64($1.raw)) }
        }
        send(.own(seq: nextSequence(), mask: ownedMask))
    }

    func setMasterVolume(_ value: Double, over duration: TimeInterval = 0) {
        ramp(.master, to: min(1, max(0, value)), over: duration)
    }

    func resetEQ(on deck: Deck, over duration: TimeInterval = 0) {
        for band in EQBand.allCases {
            setEQ(band, on: deck, toDecibels: 0, over: duration)
        }
    }

    func setInputGain(_ decibels: Double, on deck: Deck, over duration: TimeInterval = 0) {
        ramp(.inputGain(deck.rawValue), to: decibels.clamped(to: -96...12), over: duration)
    }

    func setHoldsTail(_ holds: Bool, on deck: Deck) {
        guard decks[deck.rawValue].holdsTail != holds else { return }
        ramp(.holdTail(deck.rawValue), to: holds ? 1 : 0, over: 0)
    }

    func resetProcessing(on deck: Deck, killLows: Bool = false) {
        if decks[deck.rawValue].loopLengthSeconds != nil { clearLoop(on: deck) }
        setHoldsTail(false, on: deck)
        setInputGain(0, on: deck)
        setGain(1, on: deck)
        resetEQ(on: deck)
        if killLows { setEQ(.low, on: deck, toDecibels: MixEngine.bassKillDecibels) }
        openFilter(on: deck)
        setHighPassCutoff(MixEngine.filterCutoffRange.lowerBound, on: deck)
        setDelayWet(0, feedback: 0, on: deck)
        setReverbSend(0, on: deck)
        setRate(1, on: deck)
        setPitch(0, on: deck)
        post(.phaseUnlock(deck: deck.rawValue))
    }

    func setFilterCutoff(_ hertz: Double, on deck: Deck, over duration: TimeInterval = 0, curve: FadeCurve = .logarithmic) {
        ramp(.lowPass(deck.rawValue), to: hertz.clamped(to: MixEngine.filterCutoffRange), over: duration, curve: curve.timeline)
    }

    func setFilterResonance(_ resonance: Double, on deck: Deck, over duration: TimeInterval = 0) {
        ramp(.resonance(deck.rawValue), to: min(1, max(0, resonance)), over: duration)
    }

    func openFilter(on deck: Deck, over duration: TimeInterval = 0) {
        setFilterCutoff(MixEngine.filterCutoffRange.upperBound, on: deck, over: duration)
    }

    func setHighPassCutoff(
        _ hertz: Double,
        on deck: Deck,
        over duration: TimeInterval = 0,
        curve: FadeCurve = .logarithmic
    ) {
        ramp(.highPass(deck.rawValue), to: hertz.clamped(to: MixEngine.filterCutoffRange), over: duration, curve: curve.timeline)
    }

    func setDelayWet(
        _ mix: Double,
        feedback: Double,
        beatSeconds: TimeInterval? = nil,
        on deck: Deck,
        over duration: TimeInterval = 0
    ) {
        if let beatSeconds, beatSeconds.isFinite, beatSeconds > 0 {
            post(.echoTime(seconds: min(2, beatSeconds / max(0.01, decks[deck.rawValue].rate))))
        }
        if mix > 0 || feedback > 0 {
            ramp(.echoFeedback, to: min(0.85, max(0, feedback)), over: 0)
        }
        ramp(.echoSend(deck.rawValue), to: min(1, max(0, mix)), over: duration)
    }

    func setReverbSend(_ level: Double, on deck: Deck, over duration: TimeInterval = 0) {
        ramp(.reverbSend(deck.rawValue), to: min(1, max(0, level)), over: duration)
    }

    func setEffectSend(_ level: Double, on deck: Deck, over duration: TimeInterval = 0) {
        ramp(.auxSend(deck.rawValue), to: min(1, max(0, level)), over: duration)
    }

    func setRate(_ rate: Double, on deck: Deck, over duration: TimeInterval = 0) {
        jogRestoreTasks[deck]?.cancel()
        jogRestoreTasks[deck] = nil
        jogBaseRates[deck] = nil
        applyRate(rate, on: deck, over: duration)
    }

    private func applyRate(_ rate: Double, on deck: Deck, over duration: TimeInterval) {
        ramp(.rate(deck.rawValue), to: rate.clamped(to: MixEngine.rateRange), over: duration)
    }

    nonisolated static let maxTempoMatchPercent: Double = 16

    @discardableResult
    func matchTempo(
        on deck: Deck,
        sourceBPM: Double,
        targetBPM: Double,
        maxPercent: Double = MixEngine.maxTempoMatchPercent,
        over duration: TimeInterval = 0
    ) -> Bool {
        guard sourceBPM > 0, targetBPM > 0 else { return false }
        let ratio = targetBPM / sourceBPM
        let limit = min(MixEngine.maxTempoMatchPercent, max(0, maxPercent)) / 100
        guard ((1 - limit)...(1 + limit)).contains(ratio) else { return false }
        setRate(ratio, on: deck, over: duration)
        return true
    }

    @discardableResult
    func setRateRatio(
        _ ratio: Double,
        on deck: Deck,
        maxPercent: Double,
        over duration: TimeInterval = 0
    ) -> Bool {
        guard ratio.isFinite, ratio > 0 else { return false }
        let limit = min(MixEngine.maxTempoMatchPercent, max(0, maxPercent)) / 100
        guard ((1 - limit)...(1 + limit)).contains(ratio) else {
            setRate(1, on: deck)
            return false
        }
        setRate(ratio, on: deck, over: duration)
        return true
    }

    func setPitch(_ cents: Double, on deck: Deck, over duration: TimeInterval = 0) {
        ramp(.pitch(deck.rawValue), to: cents.clamped(to: MixEngine.pitchCentsRange), over: duration)
    }

    func cancelAllRamps() {
        post(.holdParameters)
        for token in bassSwapToken.values { token.cancel() }
        bassSwapToken.removeAll()
    }

    // MARK: - Effects

    func loadEffect(
        _ description: AudioComponentDescription,
        name: String,
        manufacturer: String,
        into slot: EffectSlot
    ) async throws {
        let host = try await MixAudioUnitHost.instantiate(description, name: name, manufacturer: manufacturer)
        installEffect(host, in: slot)
    }

    func installEffect(_ host: MixAudioUnitHost, in slot: EffectSlot) {
        if let previous = effectHosts[slot] { retire(previous) }
        effectHosts[slot] = host
        send(.insert(seq: nextSequence(), slot: slot.coreSlot, host: Unmanaged.passUnretained(host)))
        let description = host.componentDescription
        effects[slot] = LoadedEffect(
            name: host.name,
            manufacturer: host.manufacturer,
            componentType: description.componentType,
            componentSubType: description.componentSubType,
            componentManufacturer: description.componentManufacturer,
            isBypassed: false,
            latencySeconds: host.latencySeconds
        )
        setEffectBypassed(false, in: slot)
        if case .send = slot {
            for deck in Deck.allCases where decks[deck.rawValue].effectSend == 0 {
                setEffectSend(0.5, on: deck)
            }
        }
        if !isOffline { _ = start() }
    }

    func removeEffect(from slot: EffectSlot) {
        guard let host = effectHosts.removeValue(forKey: slot) else { return }
        send(.insert(seq: nextSequence(), slot: slot.coreSlot, host: nil))
        retire(host)
        effects[slot] = nil
    }

    func setEffectBypassed(_ bypassed: Bool, in slot: EffectSlot) {
        switch slot {
        case .deck(let deck):
            ramp(.insertMix(deck.rawValue), to: bypassed ? 0 : 1, over: 0)
        case .send:
            ramp(.auxReturn, to: bypassed ? 0 : 1, over: 0)
        }
        effects[slot]?.isBypassed = bypassed
    }

    func effectAudioUnit(in slot: EffectSlot) -> AUAudioUnit? {
        effectHosts[slot]?.audioUnit
    }

    // MARK: - Automation clock

    @discardableResult
    func after(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> MixScheduledAction {
        schedule(due: automationClock.now + max(0, delay.isFinite ? delay : 0), anchorGroup: nil, offset: 0, action)
    }

    @discardableResult
    func after(anchor group: Int32, plus seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) -> MixScheduledAction {
        schedule(due: nil, anchorGroup: group, offset: seconds, action)
    }

    private func schedule(
        due: TimeInterval?,
        anchorGroup: Int32?,
        offset: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> MixScheduledAction {
        let token = MixScheduledAction()
        if isOffline {
            offlineTimerSequence += 1
            offlineTimers.append(OfflineTimer(
                due: due, anchorGroup: anchorGroup, anchorOffset: offset,
                sequence: offlineTimerSequence, token: token, action: action
            ))
            return token
        }
        let clock = automationClock
        token.task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                var target = due
                if target == nil, let group = anchorGroup, let anchor = self?.anchorClockSeconds(for: group) {
                    target = anchor + offset
                }
                if let target {
                    let remaining = target - clock.now
                    if remaining <= 0 { break }
                    try? await Task.sleep(for: .seconds(min(remaining, 0.1)))
                } else {
                    try? await Task.sleep(for: .milliseconds(20))
                }
            }
            guard !Task.isCancelled, !token.isCancelled else { return }
            token.markFired()
            action()
        }
        return token
    }

    func pauseAutomation() {
        automationClock.pause()
    }

    func resumeAutomation() {
        automationClock.resume()
    }

    func jumpAutomation(by seconds: TimeInterval) {
        automationClock.jump(by: seconds)
    }

    func livePosition(of deck: Deck) -> TimeInterval {
        playheadPosition(for: deck) ?? decks[deck.rawValue].position
    }

    // MARK: - Snapshot mirror

    private func startTicking() {
        guard tickTask == nil else { return }
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func tick() {
        refreshFromCore()
        for source in sources.compactMap({ $0 }) { source.source.kick() }
        suspendIfIdle()
    }

    private func refreshFromCore() {
        let snapshot = core.snapshot()
        lastSnapshot = snapshot
        lastSnapshotWall = Date()
        let applied = snapshot.appliedSequence
        pendingMirror = pendingMirror.filter { $0.value > applied }

        applyingSnapshot = true
        if pendingMirror[.crossfade] == nil, pendingMirror[.parameter(MixParameter.crossfade.raw)] == nil,
           abs(crossfade - snapshot.crossfade) > 1e-6 {
            crossfade = snapshot.crossfade
        }
        if pendingMirror[.master] == nil, pendingMirror[.parameter(MixParameter.master.raw)] == nil,
           abs(masterVolume - snapshot.master) > 1e-6 {
            masterVolume = snapshot.master
        }
        applyingSnapshot = false

        var updated = decks
        for deck in Deck.allCases {
            let index = deck.rawValue
            let s = snapshot.deck(index)
            var state = updated[index]
            let ours = sources[index].map { Int(bitPattern: Unmanaged.passUnretained($0.source).toOpaque()) } ?? 0
            let current = s.sourceID == ours
            func take(_ parameter: MixParameter, _ apply: (inout DeckState) -> Void) {
                guard pendingMirror[.parameter(parameter.raw)] == nil else { return }
                apply(&state)
            }
            take(.gain(index)) { $0.gain = s.gain }
            take(.inputGain(index)) { $0.inputGain = s.inputGain }
            take(.eqLow(index)) { $0.low = s.low }
            take(.eqMid(index)) { $0.mid = s.mid }
            take(.eqHigh(index)) { $0.high = s.high }
            take(.lowPass(index)) { $0.filterCutoff = s.lowPass }
            take(.highPass(index)) { $0.highPassCutoff = s.highPass }
            take(.resonance(index)) { $0.filterResonance = s.resonance }
            take(.echoSend(index)) { $0.delayWet = s.echoSend }
            take(.reverbSend(index)) { $0.reverbSend = s.reverbSend }
            take(.auxSend(index)) { $0.effectSend = s.auxSend }
            take(.rate(index)) { $0.rate = s.rate }
            take(.pitch(index)) { $0.pitch = s.pitch }
            take(.holdTail(index)) { $0.holdsTail = s.holdTail }
            if current, sources[index] != nil {
                if pendingMirror[.playing(index)] == nil {
                    state.isPlaying = s.playing
                }
                if pendingMirror[.position(index)] == nil {
                    state.position = s.ended ? state.duration : min(state.duration, s.position / sampleRate)
                }
                if pendingMirror[.loop(index)] == nil {
                    state.loopStartSeconds = s.loopLength > 0 ? s.loopStart / sampleRate : nil
                    state.loopLengthSeconds = s.loopLength > 0 ? s.loopLength / sampleRate : nil
                }
                state.level = s.rms > state.level ? s.rms : state.level * 0.75 + s.rms * 0.25
                state.peak = max(s.peak, state.peak * 0.9)
                if state.level < 0.0005 { state.level = 0 }
                if state.peak < 0.0005 { state.peak = 0 }
            }
            updated[index] = state
        }
        if updated != decks { decks = updated }
        releaseRetired()
    }

    private func releaseRetired() {
        let applied = lastSnapshot.appliedSequence
        guard !retired.isEmpty else { return }
        let inUse: Set<Int> = [
            lastSnapshot.a.sourceID, lastSnapshot.b.sourceID,
            lastSnapshot.a.beatsID, lastSnapshot.b.beatsID,
            lastSnapshot.a.insertID, lastSnapshot.b.insertID, lastSnapshot.auxID
        ]
        retired.removeAll { entry in
            let id = Int(bitPattern: Unmanaged.passUnretained(entry.object).toOpaque())
            let sourceID = (entry.object as? DeckSource).map { Int(bitPattern: Unmanaged.passUnretained($0.source).toOpaque()) }
            let identifier = sourceID ?? id
            return applied >= entry.sequence && !inUse.contains(identifier)
        }
    }

    private func playheadPosition(for deck: Deck) -> TimeInterval? {
        let index = deck.rawValue
        guard let source = sources[index] else { return nil }
        if isOffline || !isRenderingLive { lastSnapshot = core.snapshot() }
        let s = lastSnapshot.deck(index)
        let ours = Int(bitPattern: Unmanaged.passUnretained(source.source).toOpaque())
        guard s.sourceID == ours else { return nil }
        if let pending = pendingMirror[.position(index)], pending > lastSnapshot.appliedSequence {
            return decks[index].position
        }
        var seconds = s.position / sampleRate
        if isRenderingLive, s.playing {
            let fresh = core.snapshot()
            lastSnapshot = fresh
            let current = fresh.deck(index)
            seconds = current.position / sampleRate + min(0.1, hostSecondsSince(fresh.hostTime)) * current.rate
        }
        return min(source.duration, max(0, seconds))
    }

    func clearCache() {
        let directory = cacheDirectory
        Task.detached(priority: .utility) {
            SourceImporter.clearCache(in: directory)
        }
    }

    #if DEBUG
    // MARK: - Offline rendering

    func loadForOfflineRendering(fileURL: URL, into deck: Deck, trackId: String) throws {
        let index = deck.rawValue
        loadGenerations[index] &+= 1
        clearDeckPlayback(deck: deck)
        let source = try MixSource(url: fileURL, synchronous: true)
        decks[index].sourceURL = fileURL
        decks[index].trackId = trackId
        install(DeckSource(source: source, localURL: fileURL, sourceURL: fileURL), on: deck)
        guard start() else {
            throw lastError ?? MixEngineError.engineStartFailed("offline engine would not start")
        }
    }

    func renderOffline(
        frames: AVAudioFrameCount,
        blockFrames: AVAudioFrameCount = 128,
        into sink: (AVAudioPCMBuffer) -> Void
    ) throws {
        guard isOffline else { return }
        guard start() else { throw lastError ?? MixEngineError.engineStartFailed("offline engine would not start") }
        let format = engine.manualRenderingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames) else {
            throw MixEngineError.engineStartFailed("could not allocate the render buffer")
        }
        var remaining = frames
        while remaining > 0 {
            refreshFromCore()
            fireDueOfflineTimers()
            let count = min(blockFrames, remaining)
            let status = try engine.renderOffline(count, to: buffer)
            guard status == .success else {
                throw MixEngineError.engineStartFailed("offline render returned \(status.rawValue)")
            }
            refreshFromCore()
            sink(buffer)
            remaining -= count
        }
    }

    private func fireDueOfflineTimers() {
        while true {
            let now = Double(core.snapshot().clock) / sampleRate
            var chosen: Int?
            var chosenDue = 0.0
            for (index, timer) in offlineTimers.enumerated() {
                var due = timer.due
                if due == nil, let group = timer.anchorGroup, let anchor = core.snapshot().anchorClock(for: group) {
                    due = Double(anchor) / sampleRate + timer.anchorOffset
                }
                guard let due, due <= now + 1e-9 else { continue }
                if let current = chosen {
                    if due < chosenDue || (due == chosenDue && timer.sequence < offlineTimers[current].sequence) {
                        chosen = index
                        chosenDue = due
                    }
                } else {
                    chosen = index
                    chosenDue = due
                }
            }
            guard let index = chosen else { return }
            let timer = offlineTimers.remove(at: index)
            guard !timer.token.isCancelled else { continue }
            timer.token.markFired()
            timer.action()
        }
    }
    #endif

    // MARK: - Version shims

    private func connectNodeThrowing(
        _ source: AVAudioNode,
        to dest: AVAudioNode,
        format: AVAudioFormat?
    ) throws {
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, *) {
            try engine.connectNode(source, to: dest, format: format)
        } else {
            engine.connect(source, to: dest, format: format)
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}

final class LoadProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lastStep = -1

    func admits(_ fraction: Double) -> Bool {
        let step = Int((min(1, max(0, fraction)) * 50).rounded(.down))
        lock.lock()
        defer { lock.unlock() }
        guard step > lastStep else { return false }
        lastStep = step
        return true
    }
}
