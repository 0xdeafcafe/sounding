import Foundation
import Combine
import Observation

@MainActor
final class DJTransitionService: ObservableObject {
    static let shared = DJTransitionService()

    weak var delegate: DJTransitionServiceDelegate?

    @Published var isEnabled: Bool = false {
        didSet {
            guard isEnabled != oldValue else { return }
            delegate?.djTransitionServiceDidChangeEnabled(isEnabled)
            if isEnabled { primeFromCurrentPlayer() }
        }
    }
    @Published private(set) var states: [String: AnalysisState] = [:]
    @Published private(set) var transitions: [TransitionKey: TransitionPlan] = [:]

    private let cacheURL: URL
    private var pendingAnalysisTasks: [String: Task<Void, Never>] = [:]
    private var pendingTransitionTasks: [TransitionKey: Task<Void, Never>] = [:]

    private init() {
        let dir = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        cacheURL = dir.appendingPathComponent("dj-cache.json")
        loadCache()
    }

    func toggle() { isEnabled.toggle() }

    func state(for trackId: String) -> AnalysisState {
        states[trackId] ?? .pending
    }

    func transition(from: Track, to: Track) -> TransitionPlan? {
        transitions[TransitionKey(fromId: from.id, toId: to.id)]
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
        for i in start..<(end - 1) {
            scheduleTransition(from: queue[i], to: queue[i + 1])
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
            let analysis = await Self.runAnalysis(for: track)
            guard let self, !Task.isCancelled else { return }
            self.states[track.id] = .analyzed(analysis)
            self.pendingAnalysisTasks[track.id] = nil
            self.saveCache()
        }
        pendingAnalysisTasks[track.id] = task
    }

    private static func runAnalysis(for track: Track) async -> TrackAnalysis {
        do {
            let url = try await SoundCloudAPI.shared.getStreamURL(for: track)
            return try await AudioAnalyzer.analyze(
                streamURL: url,
                duration: track.duration,
                trackId: track.id
            )
        } catch {
            return synthesizeAnalysis(for: track)
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

    private func scheduleTransition(from a: Track, to b: Track) {
        let key = TransitionKey(fromId: a.id, toId: b.id)
        if transitions[key] != nil { return }
        if pendingTransitionTasks[key] != nil { return }

        let task = Task { [weak self] in
            while !Task.isCancelled {
                if let self,
                   case .analyzed(let aA) = self.states[a.id],
                   case .analyzed(let bA) = self.states[b.id] {
                    let plan = Self.computeTransition(from: aA, to: bA)
                    self.transitions[key] = plan
                    self.pendingTransitionTasks[key] = nil
                    self.saveCache()
                    return
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        pendingTransitionTasks[key] = task
    }

    private static func computeTransition(from a: TrackAnalysis, to b: TrackAnalysis) -> TransitionPlan {
        let bpmA = a.bpm ?? 0
        let bpmB = b.bpm ?? 0
        let bpmDelta = abs(bpmA - bpmB)
        let energyDelta = a.energy - b.energy           // signed: + means cool-down
        let energyDeltaAbs = abs(energyDelta)
        let keysCompatible = areKeysCompatible(a.key, b.key)

        var steps: [TransitionStep] = []
        var primary: TransitionTechnique = .quickCut
        var confidence: Double = 0.5

        if bpmDelta < 4, energyDeltaAbs < 0.20, keysCompatible {
            steps = [
                TransitionStep(technique: .phraseAlign, bars: 0),
                TransitionStep(technique: .beatMatch,   bars: 4),
                TransitionStep(technique: .bassSwap,    bars: 4),
            ]
            primary = .beatMatch
            confidence = 0.95
        } else if bpmDelta < 6, energyDeltaAbs < 0.35 {
            let sweep: TransitionTechnique = a.energy >= b.energy ? .lowpassSweep : .highpassSweep
            steps = [
                TransitionStep(technique: .beatMatch, bars: 4),
                TransitionStep(technique: sweep,      bars: 4),
                TransitionStep(technique: .bassSwap,  bars: 2),
            ]
            primary = sweep
            confidence = 0.82 - Double(bpmDelta) * 0.02 - energyDeltaAbs * 0.1
        } else if energyDelta < -0.30, bpmDelta < 8 {
            steps = [
                TransitionStep(technique: .beatMatch,     bars: 2),
                TransitionStep(technique: .highpassSweep, bars: 2),
                TransitionStep(technique: .quickCut,      bars: 0),
            ]
            primary = .highpassSweep
            confidence = 0.72
        } else if energyDelta > 0.30, bpmDelta < 8 {
            steps = [
                TransitionStep(technique: .loopOut,      bars: 2),
                TransitionStep(technique: .echoOut,      bars: 2),
                TransitionStep(technique: .lowpassSweep, bars: 2),
            ]
            primary = .echoOut
            confidence = 0.66
        } else if bpmDelta >= 8, bpmDelta < 16 {
            steps = [
                TransitionStep(technique: .beatMatch,    bars: 2),
                TransitionStep(technique: .lowpassSweep, bars: 4),
                TransitionStep(technique: .loopOut,      bars: 2),
            ]
            primary = .lowpassSweep
            confidence = 0.55
        } else if bpmDelta >= 16 {
            steps = [
                TransitionStep(technique: .loopOut,  bars: 4),
                TransitionStep(technique: .echoOut,  bars: 2),
                TransitionStep(technique: .quickCut, bars: 0),
            ]
            primary = .loopOut
            confidence = 0.50
        } else {
            steps = [
                TransitionStep(technique: .lowpassSweep, bars: 2),
                TransitionStep(technique: .quickCut,     bars: 0),
            ]
            primary = .quickCut
            confidence = 0.38
        }

        if !keysCompatible { confidence -= 0.10 }
        confidence = max(0.20, min(0.99, confidence))

        let totalBars = steps.reduce(0) { $0 + $1.bars }
        return TransitionPlan(
            fromTrackId: a.trackId,
            toTrackId: b.trackId,
            primaryTechnique: primary,
            confidence: confidence,
            totalBars: totalBars,
            steps: steps
        )
    }

    private static func areKeysCompatible(_ keyA: String?, _ keyB: String?) -> Bool {
        guard let keyA, let keyB else { return true }
        if keyA == keyB { return true }

        let names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
        func parse(_ k: String) -> (root: Int, minor: Bool)? {
            let isMinor = k.hasSuffix("m")
            let root = isMinor ? String(k.dropLast()) : k
            guard let idx = names.firstIndex(of: root) else { return nil }
            return (idx, isMinor)
        }
        guard let pa = parse(keyA), let pb = parse(keyB) else { return false }

        let interval = (pa.root - pb.root + 12) % 12
        if [0, 5, 7].contains(interval) { return true }
        if interval == 3, pa.minor != pb.minor { return true }
        if interval == 9, pa.minor != pb.minor { return true }
        return false
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode(CachePayload.self, from: data) else { return }
        for analysis in decoded.analyses {
            states[analysis.trackId] = .analyzed(analysis)
        }
        for plan in decoded.transitions {
            transitions[TransitionKey(fromId: plan.fromTrackId, toId: plan.toTrackId)] = plan
        }
    }

    private func saveCache() {
        let analyses: [TrackAnalysis] = states.values.compactMap {
            if case .analyzed(let a) = $0 { return a } else { return nil }
        }
        let payload = CachePayload(
            analyses: analyses,
            transitions: Array(transitions.values)
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    private struct CachePayload: Codable {
        let analyses: [TrackAnalysis]
        let transitions: [TransitionPlan]
    }
}
