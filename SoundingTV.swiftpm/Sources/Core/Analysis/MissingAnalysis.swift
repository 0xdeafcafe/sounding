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
    @Published private(set) var isPreparing = false
    @Published private(set) var message: String?
    @Published private(set) var cannotAnalyse: Set<String> = []

    private struct Outcome {
        var analysed = 0
        var failed = 0
        var notDownloaded = 0
    }

    private var queue: [Track] = []
    private var queuedIds: Set<String> = []
    private var attempted: Set<String> = []
    private var runner: Task<Void, Never>?
    private var outcome = Outcome()
    private var preparations = 0

    private init() {}

    var statusLine: String? {
        guard let base = progress.label(verb: "Analysing") else {
            return isPreparing ? "Finding tracks to analyse…" : nil
        }
        return isPaused ? base + " · Paused" : base
    }

    var isActive: Bool { progress.isActive }

    var hasStatus: Bool { statusLine != nil || message != nil }

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
        let requested = MissingAnalysis.deduplicated(tracks)
        prepare {
            await MissingAnalysis.missingTracks(in: requested)
        }
    }

    func startLibrary() {
        guard admitsWork() else { return }
        prepare {
            var tracks = AnalysisLibraryProgress.candidates()
            tracks += await LikesSyncEngine.shared.indexedLikes().tracks
            return await MissingAnalysis.missingTracks(in: tracks)
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
        message = nil
        let gate = AnalysisGateInputs.current().gate
        guard gate == .off || gate == .unsupported else { return true }
        message = AnalysisStatusCopy.gate(gate, device: .current)
            ?? "BPM and key come from your iPhone, iPad or Mac."
        return false
    }

    private func prepare(_ find: @escaping @MainActor () async -> [Track]) {
        preparations += 1
        isPreparing = true
        Task { [weak self] in
            let missing = await find()
            guard let self else { return }
            self.preparations -= 1
            self.isPreparing = self.preparations > 0
            self.enqueue(missing)
        }
    }

    private func enqueue(_ missing: [Track]) {
        let protected = missing.filter(\.needsFairPlay).map(\.id)
        if !protected.isEmpty { cannotAnalyse.formUnion(protected) }
        let fresh = missing.filter { !isSettled($0.id) && !$0.needsFairPlay }
        let ready = fresh.filter(MissingAnalysis.isAnalysableHere)
        let notDownloaded = fresh.count - ready.count
        if !progress.isActive { outcome = Outcome() }
        guard !ready.isEmpty else {
            if progress.isActive {
                outcome.notDownloaded += notDownloaded
                return
            }
            message = Self.idleMessage(missing: missing.count, protected: protected.count, notDownloaded: notDownloaded)
            return
        }
        outcome.notDownloaded += notDownloaded
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
                finish(message: completionMessage)
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
                switch states[track.id] {
                case .complete?:
                    outcome.analysed += 1
                    attempted.insert(track.id)
                case .notEligible(let reason)? where reason == PlaybackSourceResolutionError.protectedAudioStatus:
                    outcome.failed += 1
                    cannotAnalyse.insert(track.id)
                default:
                    outcome.failed += 1
                    attempted.insert(track.id)
                }
            }
            progress.done = min(progress.total, progress.done + chunk.count)
        }
    }

    private var completionMessage: String {
        var parts: [String] = []
        if outcome.analysed > 0 {
            parts.append("Analysed \(AnalysisStatusCopy.tracks(outcome.analysed)).")
        }
        if outcome.failed > 0 {
            parts.append(outcome.analysed > 0
                ? "\(AnalysisStatusCopy.tracks(outcome.failed)) couldn’t be analysed."
                : "Couldn’t analyse \(AnalysisStatusCopy.tracks(outcome.failed)).")
        }
        if outcome.notDownloaded > 0 {
            parts.append(Self.notDownloadedLine(outcome.notDownloaded))
        }
        return parts.isEmpty ? "All tracks are analysed." : parts.joined(separator: " ")
    }

    private static func idleMessage(missing: Int, protected: Int, notDownloaded: Int) -> String {
        if missing == 0 { return "All tracks are analysed." }
        if notDownloaded > 0 {
            return notDownloadedLine(notDownloaded) + " BPM and key are found when a track is downloaded."
        }
        if protected > 0, protected == missing { return PlaybackSourceResolutionError.protectedAudioStatus }
        return "Nothing new to analyse."
    }

    private static func notDownloadedLine(_ count: Int) -> String {
        count == 1
            ? "1 track isn’t downloaded yet."
            : "\(AnalysisStatusCopy.tracks(count)) aren’t downloaded yet."
    }

    private func finish(message: String?) {
        runner?.cancel()
        runner = nil
        queue.removeAll()
        queuedIds.removeAll()
        isPaused = false
        progress = HeavyWorkProgress()
        outcome = Outcome()
        if let message { self.message = message }
    }

    private static var isRateLimited: Bool {
        if case .waiting = SoundCloudGateway.shared.trafficSafetyState() { return true }
        return false
    }
}
