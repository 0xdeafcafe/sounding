import Foundation
import AVFoundation
import Accelerate
import Combine
import CryptoKit
import AudioToolbox

/// The audio render callback runs on Core Audio's realtime queue, never on
/// the main actor. This deliberately lives outside `MixEngine` so Swift 6
/// cannot inherit the engine's `@MainActor` isolation into the tap closure.
private final class MixLevelMeterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var rms: Float = 0
    private var peak: Float = 0

    func write(rms newRMS: Float, peak newPeak: Float) {
        lock.lock()
        rms = newRMS
        peak = max(peak, newPeak)
        lock.unlock()
    }

    func drain() -> (rms: Float, peak: Float) {
        lock.lock()
        let result = (rms, peak)
        peak = 0
        lock.unlock()
        return result
    }

    func reset() {
        lock.lock()
        rms = 0
        peak = 0
        lock.unlock()
    }
}

/// Keep the Core Audio tap closure entirely outside `MixEngine`'s main-actor
/// context. AVAudioEngine invokes it on `RealtimeMessenger.mServiceQueue`.
private func makeMixMeterTap(for box: MixLevelMeterBox) -> AVAudioNodeTapBlock {
    { buffer, _ in
        let frames = vDSP_Length(buffer.frameLength)
        guard frames > 0 else { return }

        var rmsAccumulator: Float = 0
        var peak: Float = 0
        let channelCount = Int(buffer.format.channelCount)
        let stride = vDSP_Stride(buffer.stride)

        guard buffer.format.commonFormat == .pcmFormatFloat32,
              let channelData = buffer.floatChannelData else { return }
        for channel in 0..<channelCount {
            let data = channelData[channel]
            var rms: Float = 0
            var channelPeak: Float = 0
            vDSP_rmsqv(data, stride, &rms, frames)
            vDSP_maxmgv(data, stride, &channelPeak, frames)
            rmsAccumulator += rms * rms
            peak = max(peak, channelPeak)
        }

        let mean = channelCount > 0 ? sqrt(rmsAccumulator / Float(channelCount)) : 0
        box.write(rms: min(1, mean), peak: min(1, peak))
    }
}

/// The macOS 27 tap API makes the render-thread contract explicit: its
/// provider is `@Sendable` and hands us a read-only buffer. Keeping this
/// factory global is important — a closure formed inside `MixEngine` would
/// otherwise inherit its main-actor isolation and trap on Core Audio's queue.
@available(iOS 27.0, macOS 27.0, tvOS 27.0, watchOS 27.0, *)
private func makeRealtimeMixMeterTap(for box: MixLevelMeterBox) -> @Sendable (AVReadOnlyAudioPCMBuffer, AVAudioTime) -> Void {
    { buffer, _ in
        let frames = vDSP_Length(buffer.frameLength)
        guard frames > 0 else { return }

        var rmsAccumulator: Float = 0
        var peak: Float = 0
        let channelCount = Int(buffer.format.channelCount)
        let stride = vDSP_Stride(buffer.stride)

        for channel in 0..<channelCount {
            guard case let .float(span) = buffer.channelData(channel) else { continue }
            var rms: Float = 0
            var channelPeak: Float = 0
            span.withUnsafeBufferPointer { pointer in
                guard let samples = pointer.baseAddress else { return }
                vDSP_rmsqv(samples, stride, &rms, frames)
                vDSP_maxmgv(samples, stride, &channelPeak, frames)
            }
            rmsAccumulator += rms * rms
            peak = max(peak, channelPeak)
        }

        let mean = channelCount > 0 ? sqrt(rmsAccumulator / Float(channelCount)) : 0
        box.write(rms: min(1, mean), peak: min(1, peak))
    }
}

@MainActor
final class MixEngine: ObservableObject {

    static let shared = MixEngine()

    enum Deck: Int, CaseIterable, Hashable, Identifiable {
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
    }

    enum LoadStatus: Equatable {
        case empty
        case loading(Double)
        case ready
        case failed(String)

        var isLoading: Bool { if case .loading = self { return true }; return false }
        var isReady: Bool { self == .ready }
    }

    struct DeckState: Equatable {
        var status: LoadStatus = .empty
        var isPlaying: Bool = false
        var position: TimeInterval = 0
        var duration: TimeInterval = 0
        var sourceURL: URL?
        var trackId: String?

        var gain: Double = 1.0

        var low: Double = 0
        var mid: Double = 0
        var high: Double = 0

        var filterCutoff: Double = MixEngine.filterCutoffRange.upperBound
        var highPassCutoff: Double = MixEngine.filterCutoffRange.lowerBound
        var filterResonance: Double = 0
        var delayWet: Double = 0

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

    nonisolated static let lowShelfHertz: Double = 200


    @Published private(set) var decks: [DeckState] = [DeckState(), DeckState()]

    @Published var crossfade: Double = 0 {
        didSet {
            let clamped = min(1, max(0, crossfade))
            if clamped != crossfade { crossfade = clamped; return }
            applyMixerGains()
        }
    }

    @Published var masterVolume: Double = 1.0 {
        didSet {
            let clamped = min(1, max(0, masterVolume))
            if clamped != masterVolume { masterVolume = clamped; return }
            applyMixerGains()
        }
    }

    @Published private(set) var isRunning = false

    @Published private(set) var lastError: MixEngineError?

    private var graphIsUsable = true

    #if DEBUG
    static let debugForceGraphBuildFailure =
        ProcessInfo.processInfo.environment["SOUNDING_TV_MIX_FORCE_GRAPH_FAILURE"] == "1"

    nonisolated(unsafe) static var debugForcePlaybackFailureArmed =
        ProcessInfo.processInfo.environment["SOUNDING_TV_MIX_FORCE_PLAYBACK_FAILURE"] == "1"

    private func debugConsumeForcedPlaybackFailureIfArmed() {
        guard MixEngine.debugForcePlaybackFailureArmed else { return }
        MixEngine.debugForcePlaybackFailureArmed = false
        engine.stop()
    }
    #endif

    subscript(deck: Deck) -> DeckState {
        decks[deck.rawValue]
    }

    func localFileURL(for deck: Deck) -> URL? {
        sources[deck.rawValue]?.localURL
    }

    func setBeatGrid(_ grid: BeatGrid?, for deck: Deck) {
        beatGrids[deck.rawValue] = grid
    }

    func beatGrid(for deck: Deck) -> BeatGrid? {
        beatGrids[deck.rawValue]
    }

    func quantizedPosition(
        _ seconds: TimeInterval,
        on deck: Deck,
        snap: StageSnap = .beat
    ) -> TimeInterval {
        guard let grid = beatGrid(for: deck) else { return max(0, seconds) }
        switch snap {
        case .beat: return max(0, grid.nearestBeat(to: seconds))
        case .bar, .phrase: return max(0, grid.nearestBar(to: seconds))
        case .free: return max(0, seconds)
        }
    }

    private let engine = AVAudioEngine()
    private let nodes: [DeckNodes] = [DeckNodes(), DeckNodes()]
    private let meters: [MixLevelMeterBox] = [MixLevelMeterBox(), MixLevelMeterBox()]
    private var tapsInstalled = false

    fileprivate final class DeckNodes: @unchecked Sendable {
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        let eq = AVAudioUnitEQ(numberOfBands: 3)
        let filter = AVAudioUnitEQ(numberOfBands: 2)
        let delay = AVAudioUnitDelay()
        let mixer = AVAudioMixerNode()
    }

    private final class DeckSource {
        let file: AVAudioFile
        let localURL: URL
        let sourceURL: URL
        let duration: TimeInterval
        var startFrame: AVAudioFramePosition = 0
        var generation: Int = 0

        var loopStartFrame: AVAudioFramePosition?
        var loopLengthFrames: AVAudioFrameCount?

        init(file: AVAudioFile, localURL: URL, sourceURL: URL) {
            self.file = file
            self.localURL = localURL
            self.sourceURL = sourceURL
            let sampleRate = file.processingFormat.sampleRate
            self.duration = sampleRate > 0 ? Double(file.length) / sampleRate : 0
        }
    }

    private var sources: [DeckSource?] = [nil, nil]
    private var loadTasks: [Task<Void, Never>?] = [nil, nil]
    private var loadGenerations: [Int] = [0, 0]

    private var tickTask: Task<Void, Never>?
    private var ramps: [RampKey: Task<Void, Never>] = [:]
    private var jogRestoreTasks: [Deck: Task<Void, Never>] = [:]
    private var jogBaseRates: [Deck: Double] = [:]
    private var beatGrids: [BeatGrid?] = [nil, nil]

    private let masterBus = AVAudioMixerNode()
    private let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0,
        componentFlagsMask: 0
    ))

    private enum RampKey: Hashable {
        case crossfade
        case masterVolume
        case gain(Deck)
        case eq(Deck, EQBand)
        case filterCutoff(Deck)
        case filterResonance(Deck)
        case highPassCutoff(Deck)
        case delayWet(Deck)
        case rate(Deck)
        case pitch(Deck)
        case bassSwap
    }

    private let cacheDirectory: URL

    init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        cacheDirectory = base.appendingPathComponent("MixEngine", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        buildGraph()
        observeConfigurationChanges()
        applyMixerGains()

        let directory = cacheDirectory
        Task.detached(priority: .background) {
            SourceImporter.pruneCache(in: directory)
        }
    }

    deinit {
    }

    private func buildGraph() {
        let main = engine.mainMixerNode
        engine.attach(masterBus)
        engine.attach(limiter)

        for deck in Deck.allCases {
            let n = nodes[deck.rawValue]
            engine.attach(n.player)
            engine.attach(n.timePitch)
            engine.attach(n.eq)
            engine.attach(n.filter)
            engine.attach(n.delay)
            engine.attach(n.mixer)

            #if DEBUG
            if MixEngine.debugForceGraphBuildFailure && deck == .a {
                engine.detach(n.player)
            }
            #endif

            configureEQ(n.eq)
            configureFilter(n.filter)
            configureDelay(n.delay)

            let format = MixEngine.canonicalFormat
            do {
                try connectNodeThrowing(n.player, to: n.timePitch, format: format)
                try connectNodeThrowing(n.timePitch, to: n.eq, format: format)
                try connectNodeThrowing(n.eq, to: n.filter, format: format)
                try connectNodeThrowing(n.filter, to: n.delay, format: format)
                try connectNodeThrowing(n.delay, to: n.mixer, format: format)
                try connectNodeThrowing(n.mixer, to: masterBus, fromBus: 0, toBus: AVAudioNodeBus(deck.rawValue), format: format)
            } catch {
                graphIsUsable = false
                lastError = .graphBuildFailed(error.localizedDescription)
                return
            }
        }

        do {
            let format = MixEngine.canonicalFormat
            try connectNodeThrowing(masterBus, to: limiter, format: format)
            try connectNodeThrowing(limiter, to: main, format: format)
        } catch {
            graphIsUsable = false
            lastError = .graphBuildFailed(error.localizedDescription)
            return
        }

        installMeterTaps()
        engine.prepare()
    }

    fileprivate static var canonicalFormat: AVAudioFormat {
        AVAudioFormat(
            standardFormatWithSampleRate: DJEngineConstants.canonicalSampleRate,
            channels: DJEngineConstants.canonicalChannels
        )!
    }

    private func configureEQ(_ eq: AVAudioUnitEQ) {
        let low = eq.bands[0]
        low.filterType = .lowShelf
        low.frequency = Float(MixEngine.lowShelfHertz)
        low.gain = 0
        low.bypass = false

        let mid = eq.bands[1]
        mid.filterType = .parametric
        mid.frequency = 1_000
        mid.bandwidth = 1.2
        mid.gain = 0
        mid.bypass = false

        let high = eq.bands[2]
        high.filterType = .highShelf
        high.frequency = 6_000
        high.gain = 0
        high.bypass = false
    }

    private func configureFilter(_ filter: AVAudioUnitEQ) {
        let lowPass = filter.bands[0]
        lowPass.filterType = .resonantLowPass
        lowPass.frequency = Float(MixEngine.filterCutoffRange.upperBound)
        lowPass.bandwidth = 2.0
        lowPass.bypass = true

        let highPass = filter.bands[1]
        highPass.filterType = .resonantHighPass
        highPass.frequency = Float(MixEngine.filterCutoffRange.lowerBound)
        highPass.bandwidth = 2.0
        highPass.bypass = true
    }

    private func configureDelay(_ delay: AVAudioUnitDelay) {
        delay.wetDryMix = 0
        delay.feedback = 32
        delay.delayTime = 0.375
        delay.lowPassCutoff = 12_000
    }

    private func installMeterTaps() {
        guard !tapsInstalled else { return }
        for deck in Deck.allCases {
            let box = meters[deck.rawValue]
            if #available(iOS 27.0, macOS 27.0, tvOS 27.0, *) {
                do {
                    try nodes[deck.rawValue].delay.installAudioTap(
                        onBus: 0,
                        bufferSize: 1024,
                        format: nil,
                        tapProvider: makeRealtimeMixMeterTap(for: box)
                    )
                } catch {
                    graphIsUsable = false
                    lastError = .graphBuildFailed(error.localizedDescription)
                    return
                }
            } else {
                nodes[deck.rawValue].delay.installTap(
                    onBus: 0,
                    bufferSize: 1024,
                    format: nil,
                    block: makeMixMeterTap(for: box)
                )
            }
        }
        tapsInstalled = true
    }

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

        guard !engine.isRunning else {
            isRunning = true
            startTicking()
            return true
        }

        guard !PlatformAudioSession.isAirPlayRoute else {
            isRunning = false
            lastError = .airPlayRouteActive
            return false
        }

        do {
            PlatformAudioSession.activatePlayback()

            installMeterTaps()
            observeConfigurationChanges()
            engine.prepare()
            try engine.start()
            isRunning = true
            lastError = nil
            startTicking()
            return true
        } catch {
            isRunning = false
            lastError = .engineStartFailed(error.localizedDescription)
            return false
        }
    }

    func stop() {
        masterVolume = 1
        for deck in Deck.allCases {
            loadTasks[deck.rawValue]?.cancel()
            loadTasks[deck.rawValue] = nil
        }
        cancelAllRamps()
        for task in jogRestoreTasks.values { task.cancel() }
        jogRestoreTasks.removeAll()
        tickTask?.cancel()
        tickTask = nil

        teardownAudioResources()

        sources = [nil, nil]
        beatGrids = [nil, nil]
        decks = [DeckState(), DeckState()]
        for deck in Deck.allCases {
            let n = nodes[deck.rawValue]
            configureEQ(n.eq)
            configureFilter(n.filter)
            configureDelay(n.delay)
            n.timePitch.rate = 1
            n.timePitch.pitch = 0
        }
        crossfade = 0
        applyMixerGains()
        isRunning = false
    }

    func teardownAudioResources() {
        if let observer = configObserverStorage.take() {
            NotificationCenter.default.removeObserver(observer)
        }
        for node in nodes {
            node.player.stop()
        }
        if tapsInstalled {
            for node in nodes {
                node.delay.removeTap(onBus: 0)
            }
            tapsInstalled = false
        }
        for meter in meters {
            meter.reset()
        }
        engine.stop()
    }

    /// Explicitly tears down the audio graph and metering resources.
    /// Must be called on the main actor.
    @MainActor
    func shutdown() {
        teardownAudioResources()
    }

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
        let snapshot = Deck.allCases.map { deck in
            (
                deck: deck,
                position: decks[deck.rawValue].position,
                playing: decks[deck.rawValue].isPlaying,
                loop: decks[deck.rawValue].loopStartSeconds.flatMap { start in
                    decks[deck.rawValue].loopLengthSeconds.map { (start: start, length: $0) }
                }
            )
        }

        engine.stop()
        let main = engine.mainMixerNode
        let format = MixEngine.canonicalFormat
        for deck in Deck.allCases {
            do {
                try connectNodeThrowing(
                    nodes[deck.rawValue].mixer,
                    to: masterBus,
                    fromBus: 0,
                    toBus: AVAudioNodeBus(deck.rawValue),
                    format: format
                )
            } catch {
                graphIsUsable = false
                lastError = .graphBuildFailed(error.localizedDescription)
                return
            }
        }
        do {
            try connectNodeThrowing(masterBus, to: limiter, format: format)
            try connectNodeThrowing(limiter, to: main, format: format)
        } catch {
            graphIsUsable = false
            lastError = .graphBuildFailed(error.localizedDescription)
            return
        }
        applyMixerGains()

        guard start() else { return }

        for entry in snapshot where sources[entry.deck.rawValue] != nil {
            if let loop = entry.loop {
                setLoop(on: entry.deck, startSeconds: loop.start, lengthSeconds: loop.length)
            } else {
                seek(deck: entry.deck, to: entry.position)
            }
            if entry.playing { play(deck: entry.deck) }
        }
    }

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

        do {
            let localURL = try await SourceImporter.materialise(
                remoteURL: url,
                cacheKey: key,
                in: directory
            ) { [weak self] fraction in
                Task { @MainActor in
                    guard let self, self.loadGenerations[index] == generation else { return }
                    self.decks[index].status = .loading(fraction)
                }
            }

            guard loadGenerations[index] == generation else { throw MixEngineError.cancelled }
            try Task.checkCancellation()

            let file = try AVAudioFile(forReading: localURL)
            let source = DeckSource(file: file, localURL: localURL, sourceURL: url)
            sources[index] = source
            decks[index].duration = source.duration
            decks[index].position = 0
            decks[index].status = .ready

            if sources[deck.other.rawValue] == nil {
                crossfade = deck == .a ? 0 : 1
            }

            guard start() else {
                throw lastError ?? MixEngineError.engineStartFailed("the audio engine could not start")
            }
            schedule(deck: deck, fromFrame: 0)
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
                    decks[index].status = .failed(mixError.errorDescription ?? "Load failed")
                    lastError = mixError
                }
            }
            throw mixError
        }
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
        nodes[index].player.stop()
        sources[index] = nil
        beatGrids[index] = nil
        meters[index].reset()

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
    }

    private static func defaultCacheKey(for url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return (components?.host ?? "") + (components?.path ?? url.absoluteString)
    }

    private func clearPlaybackFailure() {
        if case .playbackStartFailed = lastError { lastError = nil }
    }

    func play(deck: Deck) {
        let index = deck.rawValue
        guard sources[index] != nil else { return }
        guard start() else { return }
        #if DEBUG
        debugConsumeForcedPlaybackFailureIfArmed()
        #endif
        do {
            try playAudioThrowing(nodes[index].player)
            decks[index].isPlaying = true
            clearPlaybackFailure()
        } catch {
            decks[index].isPlaying = false
            lastError = .playbackStartFailed(error.localizedDescription)
        }
    }

    func pause(deck: Deck) {
        let index = deck.rawValue
        guard sources[index] != nil else { return }
        nodes[index].player.pause()
        decks[index].isPlaying = false
    }

    func togglePlayPause(deck: Deck) {
        decks[deck.rawValue].isPlaying ? pause(deck: deck) : play(deck: deck)
    }

    func stop(deck: Deck) {
        let index = deck.rawValue
        guard sources[index] != nil else { return }
        clearLoopBookkeeping(on: deck)
        nodes[index].player.stop()
        decks[index].isPlaying = false
        decks[index].position = 0
        schedule(deck: deck, fromFrame: 0)
    }

    func seek(deck: Deck, to time: TimeInterval) {
        let index = deck.rawValue
        guard let source = sources[index] else { return }

        clearLoopBookkeeping(on: deck)

        let wasPlaying = decks[index].isPlaying
        let sampleRate = source.file.processingFormat.sampleRate
        let target = min(max(0, time), source.duration)
        let frame = AVAudioFramePosition((target * sampleRate).rounded())

        nodes[index].player.stop()
        decks[index].position = target
        schedule(deck: deck, fromFrame: frame)

        if wasPlaying, start() {
            #if DEBUG
            debugConsumeForcedPlaybackFailureIfArmed()
            #endif
            do {
                try playAudioThrowing(nodes[index].player)
                decks[index].isPlaying = true
                clearPlaybackFailure()
            } catch {
                decks[index].isPlaying = false
                lastError = .playbackStartFailed(error.localizedDescription)
            }
        }
    }

    func seek(deck: Deck, byNudging seconds: TimeInterval) {
        seek(deck: deck, to: decks[deck.rawValue].position + seconds)
    }

    /// A platter jog is a short tempo bend. It never stops or reschedules the
    /// player node, so nudging a kick into phase cannot click or drop audio.
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
        let deckPosition = decks[deck.rawValue].position
        let referencePosition = decks[reference.rawValue].position
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
        let ratio = sourceGrid.beatPeriod / referenceGrid.beatPeriod
        setRateRatio(ratio, on: deck, maxPercent: maxPercent)
        if let error = phaseErrorSeconds(deck, relativeTo: reference), abs(error) > 0.004 {
            // A short pitch bend closes phase without stopping/rescheduling the
            // player node. The sign is inverted because a late deck speeds up.
            nudge(deck: deck, amount: -error / referenceGrid.beatPeriod * 8, releaseSeconds: 0.28)
        }
        return true
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

    /// Converts an exact source position on a running reference deck into wall
    /// clock lead time. Staged transitions use this to begin their effects at a
    /// measured boundary without prematurely starting a still-hidden deck.
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

        let sampleRate = source.file.processingFormat.sampleRate
        let target = min(max(0, sourceSeconds), source.duration)
        let frame = AVAudioFramePosition((target * sampleRate).rounded())

        func startImmediately(_ reason: String) -> CueResult {
            clearLoopBookkeeping(on: deck)
            nodes[index].player.stop()
            decks[index].position = target
            schedule(deck: deck, fromFrame: frame)
            #if DEBUG
            debugConsumeForcedPlaybackFailureIfArmed()
            #endif
            do {
                try playAudioThrowing(nodes[index].player)
                decks[index].isPlaying = true
                clearPlaybackFailure()
            } catch {
                decks[index].isPlaying = false
                lastError = .playbackStartFailed(error.localizedDescription)
            }
            return .unaligned(reason: reason)
        }

        guard let clock = renderClock(for: reference) else {
            return startImmediately("outgoing deck has no render clock yet")
        }
        guard let referencePosition = playheadPosition(for: reference) else {
            return startImmediately("outgoing deck playhead unavailable")
        }

        let referenceRate = max(0.01, decks[reference.rawValue].rate)
        let earliestSource = referencePosition + minimumLead * referenceRate
        let requested = referenceSourceSeconds.flatMap { $0.isFinite ? $0 : nil }
        let nextAlignment: TimeInterval
        if let requested, requested >= earliestSource {
            // Automatic plans already chose a measured musical boundary. Use
            // that exact source position instead of silently choosing the next
            // generic bar and making the executor disagree with the planner.
            nextAlignment = requested
        } else {
            guard referenceBeatPeriod.isFinite, referenceBeatPeriod > 0.05 else {
                return startImmediately("no measured tempo on the outgoing track")
            }
            let alignmentSeconds = referenceBeatPeriod * Double(max(1, beatsPerAlignment))
            let sinceAnchor = earliestSource - referenceGridAnchor
            let stepsAhead = (sinceAnchor / alignmentSeconds).rounded(.up)
            nextAlignment = referenceGridAnchor + stepsAhead * alignmentSeconds
        }
        let leadWallSeconds = (nextAlignment - referencePosition) / referenceRate
        guard leadWallSeconds.isFinite, leadWallSeconds > 0, leadWallSeconds < 30 else {
            return startImmediately("next downbeat is not within a sane lead time")
        }

        let renderRate = clock.nodeTime.sampleRate > 0 ? clock.nodeTime.sampleRate : sampleRate
        let startSample = clock.nodeTime.sampleTime
            + AVAudioFramePosition((leadWallSeconds * renderRate).rounded())
        let startTime = AVAudioTime(sampleTime: startSample, atRate: renderRate)

        clearLoopBookkeeping(on: deck)
        nodes[index].player.stop()
        decks[index].position = target
        schedule(deck: deck, fromFrame: frame, at: startTime)
        #if DEBUG
        debugConsumeForcedPlaybackFailureIfArmed()
        #endif
        do {
            try playAudioThrowing(nodes[index].player, at: startTime)
            decks[index].isPlaying = true
            clearPlaybackFailure()
        } catch {
            decks[index].isPlaying = false
            lastError = .playbackStartFailed(error.localizedDescription)
        }
        return .aligned(leadSeconds: leadWallSeconds)
    }

    func setLoop(on deck: Deck, startSeconds: Double, lengthSeconds: Double) {
        let index = deck.rawValue
        guard let source = sources[index] else { return }
        let sampleRate = source.file.processingFormat.sampleRate
        guard let bounds = LoopMath.resolve(
            startSeconds: startSeconds,
            lengthSeconds: lengthSeconds,
            durationSeconds: source.duration,
            sampleRate: sampleRate
        ) else { return }

        source.file.framePosition = bounds.startFrame
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: source.file.processingFormat,
            frameCapacity: bounds.lengthFrames
        ) else { return }
        do {
            try source.file.read(into: buffer, frameCount: bounds.lengthFrames)
        } catch {
            return
        }

        let wasPlaying = decks[index].isPlaying
        source.generation &+= 1
        nodes[index].player.stop()

        source.loopStartFrame = bounds.startFrame
        source.loopLengthFrames = bounds.lengthFrames
        source.startFrame = bounds.startFrame

        nodes[index].player.scheduleBuffer(buffer, at: nil, options: [.loops])

        decks[index].position = Double(bounds.startFrame) / sampleRate
        decks[index].loopStartSeconds = Double(bounds.startFrame) / sampleRate
        decks[index].loopLengthSeconds = Double(bounds.lengthFrames) / sampleRate

        if wasPlaying, start() {
            #if DEBUG
            debugConsumeForcedPlaybackFailureIfArmed()
            #endif
            do {
                try playAudioThrowing(nodes[index].player)
                decks[index].isPlaying = true
                clearPlaybackFailure()
            } catch {
                decks[index].isPlaying = false
                lastError = .playbackStartFailed(error.localizedDescription)
            }
        }
    }

    func setQuantizedLoop(on deck: Deck, near seconds: Double, beats: Double) {
        guard beats.isFinite, beats > 0, let grid = beatGrid(for: deck), grid.beatPeriod > 0 else {
            return
        }
        let start = max(0, grid.nearestBeat(to: seconds))
        setLoop(on: deck, startSeconds: start, lengthSeconds: beats * grid.beatPeriod)
    }

    func clearLoop(on deck: Deck) {
        let index = deck.rawValue
        guard let source = sources[index], source.loopLengthFrames != nil else { return }

        let sampleRate = source.file.processingFormat.sampleRate
        let resumeFrame: AVAudioFramePosition
        if sampleRate > 0, let position = playheadPosition(for: deck) {
            resumeFrame = AVAudioFramePosition((position * sampleRate).rounded())
        } else {
            resumeFrame = source.loopStartFrame ?? source.startFrame
        }

        let wasPlaying = decks[index].isPlaying
        clearLoopBookkeeping(on: deck)

        nodes[index].player.stop()
        schedule(deck: deck, fromFrame: resumeFrame)
        if sampleRate > 0 {
            decks[index].position = min(source.duration, max(0, Double(resumeFrame) / sampleRate))
        }

        if wasPlaying, start() {
            #if DEBUG
            debugConsumeForcedPlaybackFailureIfArmed()
            #endif
            do {
                try playAudioThrowing(nodes[index].player)
                decks[index].isPlaying = true
                clearPlaybackFailure()
            } catch {
                decks[index].isPlaying = false
                lastError = .playbackStartFailed(error.localizedDescription)
            }
        }
    }

    private func clearLoopBookkeeping(on deck: Deck) {
        let index = deck.rawValue
        guard sources[index]?.loopLengthFrames != nil else { return }
        sources[index]?.loopStartFrame = nil
        sources[index]?.loopLengthFrames = nil
        decks[index].loopStartSeconds = nil
        decks[index].loopLengthSeconds = nil
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

    private func schedule(deck: Deck, fromFrame frame: AVAudioFramePosition, at when: AVAudioTime? = nil) {
        let index = deck.rawValue
        guard let source = sources[index] else { return }

        let total = source.file.length
        let start = max(0, min(frame, total))
        let remaining = total - start
        guard remaining > 0 else {
            source.startFrame = total
            decks[index].isPlaying = false
            return
        }

        source.generation &+= 1
        source.startFrame = start
        let generation = source.generation

        nodes[index].player.scheduleSegment(
            source.file,
            startingFrame: start,
            frameCount: AVAudioFrameCount(remaining),
            at: when,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleSegmentFinished(deck: deck, generation: generation)
            }
        }
    }

    private func handleSegmentFinished(deck: Deck, generation: Int) {
        let index = deck.rawValue
        guard let source = sources[index], source.generation == generation else { return }
        decks[index].isPlaying = false
        nodes[index].player.stop()
        schedule(deck: deck, fromFrame: 0)
        decks[index].position = source.duration
    }

    func crossfade(to value: Double, over duration: TimeInterval, curve: FadeCurve = .linear) {
        let from = crossfade
        let to = min(1, max(0, value))
        ramp(.crossfade, duration: duration) { [weak self] t in
            guard let self else { return }
            self.crossfade = MixEngine.interpolate(from: from, to: to, t: t, curve: curve)
        }
    }

    func crossfade(to deck: Deck, over duration: TimeInterval, curve: FadeCurve = .linear) {
        crossfade(to: deck == .a ? 0 : 1, over: duration, curve: curve)
    }

    func setGain(_ gain: Double, on deck: Deck, over duration: TimeInterval = 0) {
        let index = deck.rawValue
        let from = decks[index].gain
        let to = min(1, max(0, gain))
        ramp(.gain(deck), duration: duration) { [weak self] t in
            guard let self else { return }
            self.decks[index].gain = from + (to - from) * t
            self.applyMixerGains()
        }
    }

    private func applyMixerGains() {
        let x = min(1, max(0, crossfade))
        let a = Float(cos(x * .pi / 2))
        let b = Float(sin(x * .pi / 2))
        let master = Float(min(1, max(0, masterVolume)))

        nodes[Deck.a.rawValue].mixer.outputVolume = a * master * Float(decks[Deck.a.rawValue].gain)
        nodes[Deck.b.rawValue].mixer.outputVolume = b * master * Float(decks[Deck.b.rawValue].gain)
    }

    func setEQ(_ band: EQBand, on deck: Deck, toDecibels decibels: Double, over duration: TimeInterval = 0) {
        let index = deck.rawValue
        let from = eqValue(band, on: deck)
        let to = decibels.clamped(to: MixEngine.eqGainRange)

        ramp(.eq(deck, band), duration: duration) { [weak self] t in
            guard let self else { return }
            let value = from + (to - from) * t
            switch band {
            case .low:  self.decks[index].low = value
            case .mid:  self.decks[index].mid = value
            case .high: self.decks[index].high = value
            }
            self.nodes[index].eq.bands[band.rawValue].gain = Float(value)
        }
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
        let kill = MixEngine.eqGainRange.lowerBound

        guard delay > 0.01 else {
            setEQ(.low, on: outgoing, toDecibels: kill, over: duration)
            setEQ(.low, on: incoming, toDecibels: 0, over: duration)
            return
        }

        ramps[.bassSwap]?.cancel()
        ramps[.bassSwap] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.setEQ(.low, on: outgoing, toDecibels: kill, over: duration)
            self.setEQ(.low, on: incoming, toDecibels: 0, over: duration)
            self.ramps[.bassSwap] = nil
        }
    }

    func setMasterVolume(_ value: Double, over duration: TimeInterval = 0) {
        let from = masterVolume
        let to = min(1, max(0, value))
        ramp(.masterVolume, duration: duration) { [weak self] t in
            self?.masterVolume = from + (to - from) * t
        }
    }

    func resetEQ(on deck: Deck, over duration: TimeInterval = 0) {
        for band in EQBand.allCases {
            setEQ(band, on: deck, toDecibels: 0, over: duration)
        }
    }

    /// Establishes the neutral state Auto DJ is allowed to assume. This is
    /// intentionally idempotent and is called even when a preloaded deck is
    /// reused after manual operation.
    func resetProcessing(on deck: Deck, killLows: Bool = false) {
        if decks[deck.rawValue].loopLengthSeconds != nil { clearLoop(on: deck) }
        setGain(1, on: deck)
        resetEQ(on: deck)
        if killLows { setEQ(.low, on: deck, toDecibels: MixEngine.eqGainRange.lowerBound) }
        openFilter(on: deck)
        setHighPassCutoff(MixEngine.filterCutoffRange.lowerBound, on: deck)
        setDelayWet(0, feedback: 0, on: deck)
        setRate(1, on: deck)
        setPitch(0, on: deck)
    }

    func setFilterCutoff(_ hertz: Double, on deck: Deck, over duration: TimeInterval = 0, curve: FadeCurve = .logarithmic) {
        let index = deck.rawValue
        let from = decks[index].filterCutoff
        let to = hertz.clamped(to: MixEngine.filterCutoffRange)

        ramp(.filterCutoff(deck), duration: duration) { [weak self] t in
            guard let self else { return }
            let value = MixEngine.interpolate(from: from, to: to, t: t, curve: curve)
            self.decks[index].filterCutoff = value
            let band = self.nodes[index].filter.bands[0]
            band.frequency = Float(value.clamped(to: MixEngine.filterCutoffRange))
            band.bypass = value >= MixEngine.filterOpenHertz
        }
    }

    func setFilterResonance(_ resonance: Double, on deck: Deck, over duration: TimeInterval = 0) {
        let index = deck.rawValue
        let from = decks[index].filterResonance
        let to = min(1, max(0, resonance))

        ramp(.filterResonance(deck), duration: duration) { [weak self] t in
            guard let self else { return }
            let value = from + (to - from) * t
            self.decks[index].filterResonance = value
            self.nodes[index].filter.bands[0].bandwidth = Float(2.0 - value * 1.9)
        }
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
        let index = deck.rawValue
        let from = decks[index].highPassCutoff
        let to = hertz.clamped(to: MixEngine.filterCutoffRange)
        ramp(.highPassCutoff(deck), duration: duration) { [weak self] t in
            guard let self else { return }
            let value = MixEngine.interpolate(from: from, to: to, t: t, curve: curve)
            self.decks[index].highPassCutoff = value
            let band = self.nodes[index].filter.bands[1]
            band.frequency = Float(value.clamped(to: MixEngine.filterCutoffRange))
            band.bypass = value <= MixEngine.filterCutoffRange.lowerBound + 5
        }
    }

    func setDelayWet(
        _ mix: Double,
        feedback: Double,
        beatSeconds: TimeInterval? = nil,
        on deck: Deck,
        over duration: TimeInterval = 0
    ) {
        let index = deck.rawValue
        let from = decks[index].delayWet
        let to = min(1, max(0, mix))
        let delay = nodes[index].delay
        delay.feedback = Float(min(85, max(0, feedback * 100)))
        if let beatSeconds, beatSeconds.isFinite {
            delay.delayTime = min(2, max(0, beatSeconds))
        }
        ramp(.delayWet(deck), duration: duration) { [weak self] t in
            guard let self else { return }
            let value = from + (to - from) * t
            self.decks[index].delayWet = value
            self.nodes[index].delay.wetDryMix = Float(value * 100)
        }
    }

    func setRate(_ rate: Double, on deck: Deck, over duration: TimeInterval = 0) {
        jogRestoreTasks[deck]?.cancel()
        jogRestoreTasks[deck] = nil
        jogBaseRates[deck] = nil
        applyRate(rate, on: deck, over: duration)
    }

    private func applyRate(_ rate: Double, on deck: Deck, over duration: TimeInterval) {
        let index = deck.rawValue
        let from = decks[index].rate
        let to = rate.clamped(to: MixEngine.rateRange)

        ramp(.rate(deck), duration: duration) { [weak self] t in
            guard let self else { return }
            let value = from + (to - from) * t
            self.decks[index].rate = value
            self.nodes[index].timePitch.rate = Float(value)
        }
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
        let index = deck.rawValue
        let from = decks[index].pitch
        let to = cents.clamped(to: MixEngine.pitchCentsRange)

        ramp(.pitch(deck), duration: duration) { [weak self] t in
            guard let self else { return }
            let value = from + (to - from) * t
            self.decks[index].pitch = value
            self.nodes[index].timePitch.pitch = Float(value)
        }
    }

    private func ramp(_ key: RampKey, duration: TimeInterval, apply: @escaping @MainActor (Double) -> Void) {
        ramps[key]?.cancel()
        ramps[key] = nil

        guard duration > 0.01 else {
            apply(1)
            return
        }

        let started = Date()
        ramps[key] = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(started)
                let t = min(1, elapsed / duration)
                apply(t)
                if t >= 1 { break }
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            self?.ramps[key] = nil
        }
    }

    func cancelAllRamps() {
        for task in ramps.values { task.cancel() }
        ramps.removeAll()
    }

    private static func interpolate(from: Double, to: Double, t: Double, curve: FadeCurve) -> Double {
        let clamped = min(1, max(0, t))
        switch curve {
        case .linear:
            return from + (to - from) * clamped
        case .smooth:
            let shaped = (1 - cos(clamped * .pi)) / 2
            return from + (to - from) * shaped
        case .logarithmic:
            let lo = max(1e-3, from)
            let hi = max(1e-3, to)
            return exp(log(lo) + (log(hi) - log(lo)) * clamped)
        }
    }

    private func startTicking() {
        guard tickTask == nil else { return }
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: 50_000_000) // 20 Hz
            }
        }
    }

    private func tick() {
        for deck in Deck.allCases {
            let index = deck.rawValue
            var state = decks[index]

            if let position = playheadPosition(for: deck) {
                state.position = position
            }

            let (rms, peak) = meters[index].drain()
            state.level = rms > state.level ? rms : state.level * 0.75 + rms * 0.25
            state.peak = max(peak, state.peak * 0.90)
            if state.level < 0.0005 { state.level = 0 }
            if state.peak < 0.0005 { state.peak = 0 }

            if state != decks[index] {
                decks[index] = state
            }
        }
    }

    private func renderClock(for deck: Deck) -> (nodeTime: AVAudioTime, playerTime: AVAudioTime)? {
        let player = nodes[deck.rawValue].player
        guard let nodeTime = player.lastRenderTime,
              nodeTime.isSampleTimeValid || nodeTime.isHostTimeValid,
              let playerTime = player.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else { return nil }
        return (nodeTime, playerTime)
    }

    private func playheadPosition(for deck: Deck) -> TimeInterval? {
        let index = deck.rawValue
        guard let source = sources[index] else { return nil }
        guard let clock = renderClock(for: deck) else { return nil }
        let playerTime = clock.playerTime

        let sampleRate = source.file.processingFormat.sampleRate
        guard sampleRate > 0 else { return 0 }

        if let loopStart = source.loopStartFrame, let loopLength = source.loopLengthFrames {
            let frame = LoopMath.wrap(
                elapsedFrames: playerTime.sampleTime,
                loopStartFrame: loopStart,
                lengthFrames: loopLength
            )
            return min(source.duration, max(0, Double(frame) / sampleRate))
        }

        let offset = Double(source.startFrame) / sampleRate
        let elapsed = Double(playerTime.sampleTime) / playerTime.sampleRate
        return min(source.duration, max(0, offset + elapsed))
    }

    func clearCache() {
        let directory = cacheDirectory
        Task.detached(priority: .utility) {
            SourceImporter.clearCache(in: directory)
        }
    }

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

    private func connectNodeThrowing(
        _ source: AVAudioNode,
        to dest: AVAudioNode,
        fromBus: AVAudioNodeBus,
        toBus: AVAudioNodeBus,
        format: AVAudioFormat?
    ) throws {
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, *) {
            try engine.connectNode(source, to: dest, fromBus: fromBus, toBus: toBus, format: format)
        } else {
            engine.connect(source, to: dest, fromBus: fromBus, toBus: toBus, format: format)
        }
    }

    private func playAudioThrowing(_ player: AVAudioPlayerNode) throws {
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, *) {
            try player.playAudio()
        } else {
            player.play()
        }
    }

    private func playAudioThrowing(_ player: AVAudioPlayerNode, at time: AVAudioTime?) throws {
        if #available(iOS 27.0, macOS 27.0, tvOS 27.0, *) {
            try player.playAudio(at: time)
        } else {
            player.play(at: time)
        }
    }

}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
