import Combine
import CoreGraphics
import Foundation

enum HomeLightingLeadership: Equatable {
    case thisDevice
    case elsewhere(String)
}

enum LightingAnalysisSource {
    @MainActor
    static func load(_ track: Track) async -> LightingAnalysis {
        var envelope: [Float] = []
        if case .success(let waveform) = await WaveformService.shared.waveform(for: track), !waveform.isEmpty {
            envelope = waveform.resampled(to: min(2048, max(64, Int(track.duration.rounded()))))
        }

        var phraseStarts: [TimeInterval] = []
        var bpm: Double?
        if #available(iOS 27.0, tvOS 27.0, *) {
            let transcoding = track.transcodings.max { $0.playbackRank < $1.playbackRank }
            if let key = AnalysisCacheKey(
                track: track,
                transcoding: transcoding,
                generation: MusicUnderstandingProducer().generation
            ), let result = await AnalysisCache.shared.peek(MusicUnderstandingDistilledResult.self, for: key) {
                phraseStarts = result.phraseStartSeconds
                bpm = result.beatsPerMinute
            }
        }
        if bpm == nil {
            bpm = await AnalysisLookup.summaries(for: [track])[track.id]?.bpm
        }

        var palette: [LightColor] = []
        if let url = track.artworkURL, let image = await SCArtworkStore.shared.cgImage(for: url, variant: .standard) {
            palette = await Task.detached(priority: .utility) { LightPalette.colors(from: image) }.value
        }

        return LightingAnalysis(
            trackID: track.id,
            duration: track.duration,
            envelope: envelope,
            phraseStarts: phraseStarts,
            bpm: bpm,
            palette: palette
        )
    }
}

@MainActor
final class HomeLightingDirector: ObservableObject {
    static let shared = HomeLightingDirector()

    static let playingTick: TimeInterval = 0.5
    static let idleTick: TimeInterval = 2
    static let prefetchWindow: TimeInterval = 45

    @Published private(set) var snapshot: HomeSnapshot = .unrequested
    @Published private(set) var leadership: HomeLightingLeadership = .thisDevice
    @Published private(set) var isWindingDown = false

    let settings: HomeLightingSettings
    private(set) var backend: HomeLightingBackend
    private(set) var scheduler: LightWriteScheduler
    private let player: PlayerService

    private var leadershipProvider: @MainActor () -> HomeLightingLeadership = { .thisDevice }
    private var started = false
    private var loop: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var analyses: [String: LightingAnalysis] = [:]
    private var loading: Set<String> = []
    private var cursor: LightingCueCursor?
    private var lastState: LightState?
    private var wasPlaying = false
    private var restoreStates: [String: LightState] = [:]
    private var windDown: (start: TimeInterval, duration: TimeInterval, from: LightState)?

    init(settings: HomeLightingSettings = .shared, backend: HomeLightingBackend? = nil, player: PlayerService = .shared) {
        self.settings = settings
        self.player = player
        let resolved = backend ?? Self.makeBackend()
        self.backend = resolved
        self.scheduler = LightWriteScheduler(backend: resolved)
        resolved.onChange = { [weak self] in self?.backendChanged() }
        snapshot = resolved.snapshot
    }

    private static func makeBackend() -> HomeLightingBackend {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["SOUNDING_TV_HOME_STORY"],
           let story = FakeHomeLightingBackend.Story(rawValue: raw) {
            return FakeHomeLightingBackend(story: story)
        }
        #endif
        return HomeKitLightingBackend()
    }

    func start(leadership: @escaping @MainActor () -> HomeLightingLeadership = { .thisDevice }) {
        leadershipProvider = leadership
        guard !started else { return }
        started = true
        if settings.hasRequestedAccess { backend.requestAccess() }

        settings.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.settingsChanged() }
            }
            .store(in: &cancellables)
        player.$currentTrack
            .removeDuplicates { $0?.id == $1?.id }
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.trackChanged() }
            }
            .store(in: &cancellables)
        player.$isPlaying
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshLoop() }
            }
            .store(in: &cancellables)
        refreshLoop()
    }

    func requestAccess() {
        settings.hasRequestedAccess = true
        backend.requestAccess()
    }

    var selectedLights: [HomeLightInfo] { settings.selectedLights(in: snapshot) }

    private var isEnabled: Bool {
        settings.intensity != .off && !selectedLights.isEmpty && snapshot.access == .ready
    }

    // MARK: - Scenes

    func applyParty(_ intensity: LightingIntensity) {
        isWindingDown = false
        windDown = nil
        settings.intensity = intensity
        cursor = nil
        refreshLoop()
    }

    func beginWindDown(over duration: TimeInterval) {
        guard isEnabled else { return }
        let from = lastState ?? LightState(color: .warmGlow, brightness: settings.intensity.brightnessRange.upperBound * 0.6)
        windDown = (ProcessInfo.processInfo.systemUptime, max(1, duration), from)
        isWindingDown = true
        refreshLoop()
    }

    func endWindDown() {
        windDown = nil
        isWindingDown = false
    }

    // MARK: - Loop

    private func backendChanged() {
        snapshot = backend.snapshot
        scheduler.setCapabilities(Dictionary(
            snapshot.homes.flatMap(\.lights).map { ($0.id, $0.capabilities) },
            uniquingKeysWith: { first, _ in first }
        ))
        refreshLoop()
    }

    private var lastSelection: Set<String> = []
    private var lastIntensity: LightingIntensity = .off

    private func settingsChanged() {
        let selection = Set(selectedLights.map(\.id))
        let removed = lastSelection.subtracting(selection)
        if settings.intensity == .off, lastIntensity != .off {
            restore(Array(lastSelection))
        } else if !removed.isEmpty {
            restore(Array(removed))
        }
        if settings.intensity != lastIntensity { cursor = nil }
        lastSelection = selection
        lastIntensity = settings.intensity
        refreshLoop()
    }

    private func trackChanged() {
        cursor = nil
        if let track = player.currentTrack { prepare(track) }
    }

    private func refreshLoop() {
        leadership = leadershipProvider()
        let shouldRun = started && isEnabled
        if shouldRun, loop == nil {
            lastSelection = Set(selectedLights.map(\.id))
            lastIntensity = settings.intensity
            loop = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let interval = self.tick()
                    try? await Task.sleep(for: .seconds(interval))
                }
            }
        } else if !shouldRun, let running = loop {
            running.cancel()
            loop = nil
            cursor = nil
        }
    }

    private func tick() -> TimeInterval {
        leadership = leadershipProvider()
        let lights = selectedLights
        guard isEnabled, leadership == .thisDevice else {
            wasPlaying = false
            return Self.idleTick
        }
        captureRestoreStates(for: lights)
        let ids = lights.map(\.id)

        if let windDown {
            let progress = (ProcessInfo.processInfo.systemUptime - windDown.start) / windDown.duration
            let state = LightingPlanner.windDown(from: windDown.from, progress: progress)
            submit(state, to: ids)
            if progress >= 1 {
                self.windDown = nil
                isWindingDown = false
            }
            return 1
        }

        guard player.isPlaying, let track = player.currentTrack else {
            if wasPlaying, let lastState {
                submit(LightingPlanner.resting(from: lastState, intensity: settings.intensity), to: ids)
            }
            wasPlaying = false
            cursor = nil
            return Self.idleTick
        }
        wasPlaying = true

        guard let analysis = analyses[track.id] else {
            prepare(track)
            return Self.playingTick
        }
        if cursor?.plan.trackID != track.id {
            let plan = LightingPlanner.plan(
                analysis,
                intensity: settings.intensity,
                minimumCueSpacing: scheduler.policy.minimumInterval
            )
            cursor = LightingCueCursor(plan: plan, lead: 0)
        }
        cursor?.lead = scheduler.latency + Self.playingTick / 2
        let position = player.currentTime
        if let cue = cursor?.advance(to: position) {
            submit(cue.state, to: ids)
        }
        if track.duration - position < Self.prefetchWindow, let next = player.upcomingTrack {
            prepare(next)
        }
        return Self.playingTick
    }

    private func submit(_ state: LightState, to ids: [String]) {
        lastState = state
        scheduler.submit(state, to: ids)
    }

    private func prepare(_ track: Track) {
        guard analyses[track.id] == nil, !loading.contains(track.id) else { return }
        loading.insert(track.id)
        Task { @MainActor [weak self] in
            let analysis = await LightingAnalysisSource.load(track)
            guard let self else { return }
            self.loading.remove(track.id)
            self.analyses[track.id] = analysis
            if self.analyses.count > 6 {
                let keep = Set([self.player.currentTrack?.id, self.player.upcomingTrack?.id].compactMap { $0 })
                for key in self.analyses.keys where !keep.contains(key) && key != track.id {
                    self.analyses[key] = nil
                }
            }
        }
    }

    private func captureRestoreStates(for lights: [HomeLightInfo]) {
        for light in lights where restoreStates[light.id] == nil {
            if let state = backend.currentState(of: light.id) { restoreStates[light.id] = state }
        }
    }

    private func restore(_ ids: [String]) {
        for id in ids {
            guard let state = restoreStates.removeValue(forKey: id) else { continue }
            scheduler.submit(state, to: [id])
        }
    }
}
