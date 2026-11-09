import Foundation
import Combine
import Observation

/// Analysis-only remains of the original transition service: it measures BPM,
/// key, and energy for upcoming queue tracks and caches the results. The
/// parallel bars/techniques planner it used to run is gone — the single plan
/// currency is PhantomDJEngine.Plan, produced by DJSessionDirector.
///
/// `transition(from:to:)` survives only as a compatibility projection for the
/// tvOS readouts that still speak the old vocabulary; PlayerService installs
/// a provider that derives the answer from the adaptive plan.
@MainActor
final class DJTransitionService: ObservableObject {
    static let shared = DJTransitionService(sourceResolver: .shared)

    weak var delegate: DJTransitionServiceDelegate?

    /// Projects the single plan model into the legacy readout vocabulary.
    var planProvider: ((Track, Track) -> TransitionPlan?)?

    @Published var isEnabled: Bool = false {
        didSet {
            guard isEnabled != oldValue else { return }
            guard !isSyncingFromCanonicalState else { return }
            delegate?.djTransitionServiceDidChangeEnabled(isEnabled)
            if isEnabled { primeFromCurrentPlayer() }
        }
    }
    private var isSyncingFromCanonicalState = false
    @Published private(set) var states: [String: AnalysisState] = [:]

    func syncEnabledFromCanonicalState(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isSyncingFromCanonicalState = true
        isEnabled = enabled
        isSyncingFromCanonicalState = false
    }

    private let cacheURL: URL
    private let sourceResolver: PlaybackSourceResolver
    private var pendingAnalysisTasks: [String: Task<Void, Never>] = [:]

    private init(sourceResolver: PlaybackSourceResolver) {
        self.sourceResolver = sourceResolver
        cacheURL = AppDataDirectory.file("dj-cache-v2.json")
        try? FileManager.default.removeItem(at: AppDataDirectory.file("dj-cache.json"))
        loadCache()
    }

    func toggle() { isEnabled.toggle() }

    func state(for trackId: String) -> AnalysisState {
        states[trackId] ?? .pending
    }

    func transition(from: Track, to: Track) -> TransitionPlan? {
        planProvider?(from, to)
    }

    func analyzeUpcoming(in queue: [Track], from currentIndex: Int) {
        guard isEnabled || SettingsStore.shared.djAutoMixEnabled else { return }
        let lookahead = 5
        let start = max(0, currentIndex)
        let end   = min(queue.count, currentIndex + lookahead + 1)
        guard start < end else { return }

        for i in start..<end {
            scheduleAnalysis(of: queue[i])
        }
    }

    private func primeFromCurrentPlayer() {
        guard let delegate else { return }
        analyzeUpcoming(in: delegate.queue, from: delegate.currentIndex)
    }

    private func scheduleAnalysis(of track: Track) {
        if case .analyzed = states[track.id] { return }
        if pendingAnalysisTasks[track.id] != nil { return }

        states[track.id] = .analyzing
        let task = Task { [weak self] in
            guard let self else { return }
            let analysis = await self.runAnalysis(for: track)
            guard !Task.isCancelled else { return }
            self.states[track.id] = .analyzed(analysis)
            self.pendingAnalysisTasks[track.id] = nil
            self.saveCache()
        }
        pendingAnalysisTasks[track.id] = task
    }

    private func runAnalysis(for track: Track) async -> TrackAnalysis {
        // The shared analysis database is synced through CloudKit, so a result
        // measured earlier by this TV, an iPhone, or a Mac should win over
        // fetching and decoding the first minute again.
        if let cached = await AnalysisSummaryStore.summaries(for: [track])[track.id],
           cached.bpm != nil || cached.key != nil {
            return TrackAnalysis(
                trackId: track.id,
                bpm: cached.bpm,
                key: cached.key?.label,
                energy: 0.5,
                intro: 0,
                outro: max(0, track.duration - 16),
                isEstimated: false
            )
        }
        do {
            let url = try await sourceResolver.decodedAudioURL(
                for: track,
                collectionID: nil
            )
            defer { TemporaryPlaintextFile(url: url).release() }
            return try await AudioAnalyzer.analyze(
                streamURL: url,
                duration: track.duration,
                trackId: track.id
            )
        } catch {
            return Self.synthesizeAnalysis(for: track)
        }
    }

    private static func synthesizeAnalysis(for track: Track) -> TrackAnalysis {
        // Failure means unknown. Plausible-looking values derived from an ID
        // teach both the planner and the person at the controls to trust data
        // that was never heard in the audio.
        return TrackAnalysis(
            trackId: track.id,
            bpm: nil,
            key: nil,
            energy: 0.5,
            intro: 0,
            outro: track.duration,
            isEstimated: true
        )
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode(CachePayload.self, from: data) else { return }
        for analysis in decoded.analyses {
            states[analysis.trackId] = .analyzed(analysis)
        }
    }

    private func saveCache() {
        let analyses: [TrackAnalysis] = states.values.compactMap {
            if case .analyzed(let a) = $0 { return a } else { return nil }
        }
        let payload = CachePayload(analyses: analyses)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private struct CachePayload: Codable {
        let analyses: [TrackAnalysis]
    }
}
