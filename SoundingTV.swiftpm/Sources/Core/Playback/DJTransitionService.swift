import Foundation
import Combine
import Observation

@MainActor
final class DJTransitionService: ObservableObject {
    static let shared = DJTransitionService(sourceResolver: .shared)

    weak var delegate: DJTransitionServiceDelegate?

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

    nonisolated static var fetchesRemoteAudio: Bool {
        #if os(tvOS)
        return false
        #else
        return true
        #endif
    }

    private let cacheURL: URL
    private let sourceResolver: PlaybackSourceResolver
    private var pendingAnalysisTasks: [String: Task<Void, Never>] = [:]
    private var refreshTasks: [String: Task<Void, Never>] = [:]
    private var tracks: [String: Track] = [:]
    private var measurements: [String: TrackAnalysis] = [:]
    private var analysisObserver: NSObjectProtocol?
    private var saveTask: Task<Void, Never>?
    private var savedData: Data?
    private static let saveDelay: Duration = .seconds(2)

    private init(sourceResolver: PlaybackSourceResolver) {
        self.sourceResolver = sourceResolver
        cacheURL = AppDataDirectory.file("dj-cache-v3.json")
        for legacy in ["dj-cache.json", "dj-cache-v2.json"] {
            try? FileManager.default.removeItem(at: AppDataDirectory.file(legacy))
        }
        loadCache()
        analysisObserver = NotificationCenter.default.addObserver(
            forName: .analysisDataDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let trackIds = note.userInfo?[AnalysisDataChange.trackIdsKey] as? [String]
            MainActor.assumeIsolated { self?.analysisDataDidChange(trackIds) }
        }
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

    func analyzeDeck(_ track: Track, localFileURL: URL) {
        tracks[track.id] = track
        guard measurements[track.id]?.energy == nil else {
            refresh(track.id)
            return
        }
        pendingAnalysisTasks[track.id]?.cancel()
        start(track, localFileURL: localFileURL)
    }

    private func primeFromCurrentPlayer() {
        guard let delegate else { return }
        analyzeUpcoming(in: delegate.queue, from: delegate.currentIndex)
    }

    private func scheduleAnalysis(of track: Track) {
        let isNew = tracks.updateValue(track, forKey: track.id) == nil
        guard pendingAnalysisTasks[track.id] == nil else { return }
        switch states[track.id] {
        case .analyzed, .failed:
            if isNew { refresh(track.id) }
            return
        case .pending, .analyzing, nil: break
        }
        start(track, localFileURL: nil)
    }

    private func start(_ track: Track, localFileURL: URL?) {
        if !Self.isMeasured(states[track.id]) { states[track.id] = .analyzing }
        pendingAnalysisTasks[track.id] = Task { [weak self] in
            guard let self else { return }
            let measured = await self.measure(track, localFileURL: localFileURL)
            guard !Task.isCancelled else { return }
            self.pendingAnalysisTasks[track.id] = nil
            if let measured {
                self.measurements[track.id] = measured
                Log.analysis.notice("Deck analysis for \(track.id, privacy: .public): bpm=\(measured.bpm.map { String(format: "%.1f", $0) } ?? "–", privacy: .public) key=\(measured.key ?? "–", privacy: .public) energy=\(measured.energy.map { String(format: "%.2f", $0) } ?? "–", privacy: .public)")
            }
            await self.publish(track)
        }
    }

    private func measure(_ track: Track, localFileURL: URL?) async -> TrackAnalysis? {
        if let fileURL = localFileURL ?? AutomaticAnalysisEligibility.deckFileURL(for: track) {
            guard AutomaticAnalysisEligibility.isEnabled else { return nil }
            return await Self.measureInLane(track, fileURL: fileURL)
        }
        guard Self.fetchesRemoteAudio, !track.needsFairPlay else { return nil }
        let summary = await AnalysisSummaryStore.summaries(for: [track])[track.id]
        if summary?.bpmIsMeasured == true, summary?.keyIsMeasured == true { return nil }
        do {
            let url = try await sourceResolver.decodedAudioURL(for: track, collectionID: nil)
            defer { TemporaryPlaintextFile(url: url).release() }
            return try await AudioAnalyzer.analyze(streamURL: url, duration: track.duration, trackId: track.id)
        } catch {
            return nil
        }
    }

    nonisolated private static func measureInLane(_ track: Track, fileURL: URL) async -> TrackAnalysis? {
        await withCheckedContinuation { continuation in
            AutomaticAnalysisScheduler.shared.enqueueDeckWork(key: "deckMeasure.\(track.id).\(UUID().uuidString)") {
                await AnalysisPlaybackGuard.waitWhilePlaybackCritical()
                do {
                    let result = try await AudioAnalyzer.analyze(
                        streamURL: fileURL,
                        duration: track.duration,
                        trackId: track.id
                    )
                    continuation.resume(returning: result)
                } catch {
                    Log.analysis.error("Deck analysis for \(track.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func publish(_ track: Track) async {
        let summary = await AnalysisSummaryStore.summaries(for: [track])[track.id]
        guard pendingAnalysisTasks[track.id] == nil else { return }
        let next: AnalysisState = Self.merge(
            trackId: track.id,
            duration: track.duration,
            summary: summary,
            measured: measurements[track.id]
        ).map { .analyzed($0) } ?? .failed
        if states[track.id] != next { states[track.id] = next }
        saveCache()
    }

    private func analysisDataDidChange(_ trackIds: [String]?) {
        let ids = trackIds ?? Array(tracks.keys)
        for id in ids { refresh(id) }
    }

    private func refresh(_ trackId: String) {
        guard let track = tracks[trackId], pendingAnalysisTasks[trackId] == nil, refreshTasks[trackId] == nil else { return }
        refreshTasks[trackId] = Task { [weak self] in
            await self?.publish(track)
            self?.refreshTasks[trackId] = nil
        }
    }

    nonisolated static func isMeasured(_ state: AnalysisState?) -> Bool {
        guard case .analyzed(let analysis) = state else { return false }
        return !analysis.isEstimated
    }

    nonisolated static func merge(
        trackId: String,
        duration: TimeInterval,
        summary: AnalysisFeatureSummary?,
        measured: TrackAnalysis?
    ) -> TrackAnalysis? {
        let bpm = (summary?.bpmIsMeasured == true ? summary?.bpm : nil) ?? measured?.bpm
        let key = (summary?.keyIsMeasured == true ? summary?.key?.label : nil) ?? measured?.key
        let energy = measured?.energy
        guard bpm != nil || key != nil || energy != nil else { return nil }
        return TrackAnalysis(
            trackId: trackId,
            bpm: bpm,
            key: key,
            energy: energy,
            intro: measured?.intro ?? 0,
            outro: measured?.outro ?? max(0, duration - 16),
            isEstimated: false
        )
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode(CachePayload.self, from: data) else { return }
        savedData = data
        for analysis in decoded.analyses where !analysis.isEstimated {
            measurements[analysis.trackId] = analysis
            states[analysis.trackId] = .analyzed(analysis)
        }
    }

    private func saveCache() {
        guard saveTask == nil else { return }
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard let self else { return }
            self.saveTask = nil
            self.writeCache()
        }
    }

    private func writeCache() {
        let analyses = measurements.values.filter { !$0.isEstimated }.sorted { $0.trackId < $1.trackId }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(CachePayload(analyses: analyses)), data != savedData else { return }
        savedData = data
        let url = cacheURL
        Task.detached(priority: .utility) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private struct CachePayload: Codable {
        let analyses: [TrackAnalysis]
    }
}
