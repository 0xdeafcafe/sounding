import Foundation

enum MissingAnalysis {
    static func isMissing(_ track: Track, summary: AnalysisFeatureSummary?, prep: TrackPrep?) -> Bool {
        let tempoMeasured = summary?.bpmIsMeasured == true
        let hasBPM = summary?.bpm != nil
        let hasKey = summary?.key != nil || prep?.key != nil
        let hasGrid = prep?.grid != nil || tempoMeasured
        let hasEnergy = prep?.energy != nil || tempoMeasured || summary?.keyIsMeasured == true
        return !(hasBPM && hasKey && hasGrid && hasEnergy)
    }

    @MainActor
    static func missingTracks(in tracks: [Track]) async -> [Track] {
        guard !tracks.isEmpty else { return [] }
        let unique = deduplicated(tracks)
        let summaries = await AnalysisSummaries.shared.summaries(for: unique)
        let preps = await CueStore.shared.preps(forTracks: unique.map(\.id))
        return unique.filter { isMissing($0, summary: summaries[$0.id], prep: preps[$0.id]) }
    }

    @MainActor
    static func isAnalysableHere(_ track: Track) -> Bool {
        guard !track.needsFairPlay else { return false }
        return track.isLocal || DownloadManager.shared.isLocallyAvailable(track)
    }

    static func deduplicated(_ tracks: [Track]) -> [Track] {
        var seen = Set<String>()
        return tracks.filter { seen.insert($0.id).inserted }
    }
}

struct MissingAnalysisCount: Equatable, Sendable {
    var missing: Int
    var analysable: Int
}

@MainActor
final class MissingAnalysisRun: ObservableObject {
    static let shared = MissingAnalysisRun()

    @Published private(set) var progress = HeavyWorkProgress()
    @Published private(set) var isPaused = false
    @Published private(set) var message: String?
    @Published private(set) var cannotAnalyse: Set<String> = []

    private var queue: [Track] = []
    private var queuedIds: Set<String> = []
    private var attempted: Set<String> = []
    private var runner: Task<Void, Never>?

    private init() {}

    var statusLine: String? {
        guard let base = progress.label(verb: "Analysing") else { return nil }
        return isPaused ? base + " · Paused" : base
    }

    var isActive: Bool { progress.isActive }

    func isSettled(_ trackId: String) -> Bool {
        cannotAnalyse.contains(trackId) || attempted.contains(trackId) || queuedIds.contains(trackId)
    }

    func count(in tracks: [Track]) -> MissingAnalysisCount? {
        let summaries = AnalysisSummaries.shared
        var count = MissingAnalysisCount(missing: 0, analysable: 0)
        var resolved = true
        for track in MissingAnalysis.deduplicated(tracks) where !isSettled(track.id) {
            let summary = summaries.summary(for: track)
            if !summaries.isResolved(track.id) { resolved = false }
            guard MissingAnalysis.isMissing(track, summary: summary, prep: nil) else { continue }
            count.missing += 1
            if MissingAnalysis.isAnalysableHere(track) { count.analysable += 1 }
        }
        return resolved ? count : nil
    }

    func start(_ tracks: [Track]) {
        guard admitsWork() else { return }
        message = nil
        let requested = MissingAnalysis.deduplicated(tracks)
        Task { [weak self] in
            let missing = await MissingAnalysis.missingTracks(in: requested)
            self?.enqueue(missing)
        }
    }

    func startLibrary() {
        guard admitsWork() else { return }
        message = nil
        Task { [weak self] in
            var tracks = AnalysisLibraryProgress.candidates()
            let likes = await LikesSyncEngine.shared.indexedLikes().tracks
            tracks += likes.filter { DownloadManager.shared.isLocallyAvailable($0) }
            let missing = await MissingAnalysis.missingTracks(in: tracks)
            self?.enqueue(missing)
        }
    }

    func pause() {
        guard progress.isActive, !isPaused else { return }
        isPaused = true
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false
        launchIfNeeded()
    }

    func stop() {
        finish(message: nil)
    }

    func dismissMessage() {
        message = nil
    }

    private func admitsWork() -> Bool {
        let gate = AnalysisGateInputs.current().gate
        guard gate == .off || gate == .unsupported else { return true }
        message = AnalysisStatusCopy.gate(gate, device: .current)
        return false
    }

    private func enqueue(_ missing: [Track]) {
        let protected = missing.filter(\.needsFairPlay).map(\.id)
        if !protected.isEmpty { cannotAnalyse.formUnion(protected) }
        let fresh = missing.filter { !isSettled($0.id) && !$0.needsFairPlay }
        let ready = fresh.filter(MissingAnalysis.isAnalysableHere)
        guard !ready.isEmpty else {
            if progress.isActive { return }
            if !fresh.isEmpty {
                message = "BPM and key are found when a track is downloaded."
            } else if !protected.isEmpty, protected.count == missing.count {
                message = PlaybackSourceResolutionError.protectedAudioStatus
            }
            return
        }
        if !progress.isActive { progress = HeavyWorkProgress() }
        queue += ready
        queuedIds.formUnion(ready.map(\.id))
        progress.total += ready.count
        launchIfNeeded()
    }

    private func launchIfNeeded() {
        guard runner == nil, !isPaused, !queue.isEmpty else { return }
        runner = Task { [weak self] in
            await self?.run()
        }
    }

    private func run() async {
        while !Task.isCancelled {
            if isPaused {
                progress.isRunning = false
                runner = nil
                return
            }
            guard !queue.isEmpty else {
                runner = nil
                finish(message: nil)
                return
            }
            if Self.isRateLimited {
                runner = nil
                finish(message: "Stopped: SoundCloud is limiting requests.")
                return
            }
            if AnalysisLibraryProgress.isTooWarm {
                runner = nil
                finish(message: "Stopped: your \(DeviceClass.current.displayName) is too warm.")
                return
            }
            let width = min(queue.count, AnalysisLibraryProgress.batchWidth)
            let chunk = Array(queue.prefix(width))
            queue.removeFirst(width)
            progress.isRunning = true
            let states = await AnalysisLibraryProgress.analyse(chunk)
            if Task.isCancelled { return }
            for track in chunk {
                queuedIds.remove(track.id)
                if case .notEligible(let reason) = states[track.id], reason == PlaybackSourceResolutionError.protectedAudioStatus {
                    cannotAnalyse.insert(track.id)
                } else {
                    attempted.insert(track.id)
                }
            }
            progress.done = min(progress.total, progress.done + chunk.count)
        }
    }

    private func finish(message: String?) {
        runner?.cancel()
        runner = nil
        queue.removeAll()
        queuedIds.removeAll()
        isPaused = false
        progress = HeavyWorkProgress()
        if let message { self.message = message }
    }

    private static var isRateLimited: Bool {
        if case .waiting = SoundCloudGateway.shared.trafficSafetyState() { return true }
        return false
    }
}
