import Foundation
import Observation

extension DJSessionDirector {
    func recordExecutedMix(
        _ plan: PhantomDJEngine.Plan?,
        into track: Track,
        outgoing: MixEngine.Deck,
        entrySeconds: TimeInterval,
        leadSeconds: TimeInterval,
        windowSeconds: TimeInterval,
        request: MixTransitionPerformer.Request
    ) {
        guard host.isAutoMixEnabled, let plan, plan.move?.kind != .jump,
              let from = host.currentTrack, from.id != track.id else { return }
        let engine = MixEngine.shared
        let incoming = outgoing.other
        let rate = max(0.01, engine[outgoing].rate)
        let start = engine.livePosition(of: outgoing) + leadSeconds * rate
        var feedback = plan.feedback
        feedback?.moveType = AutoMixTransitionFeatures.moveType(templateId: plan.templateId, move: plan.move?.kind)
        let execution = MixExecutionRecord(
            startSourceSeconds: start,
            windowSeconds: windowSeconds,
            entrySeconds: entrySeconds,
            outgoingRate: rate,
            incomingRate: engine[incoming].rate,
            startedAtPlannedBoundary: request.startAtPlannedBoundary,
            riserLevel: request.riserLevel,
            sampleRate: engine.sampleRate
        )
        let played = (engine.performanceSchedules[outgoing]?.moves ?? []).filter { $0.startSeconds < start }
        MixHistoryStore.shared.record(
            outgoing: MixTrackSnapshot(from, features: plan.outgoingFeatures, grid: plan.outgoingBeatGrid, at: plan.mixPointSeconds),
            incoming: MixTrackSnapshot(track, features: nil, grid: plan.incomingBeatGrid, at: entrySeconds),
            plan: MixPlanRecord(plan),
            execution: execution,
            performance: played,
            feedback: feedback
        )
        MixReplayController.shared.transitionDidStart(from: from.id, to: track.id)
    }
}

@MainActor
@Observable
final class MixReplayController {
    static let shared = MixReplayController()

    private(set) var activeID: UUID?
    private(set) var message: String?
    private(set) var isStarting = false

    @ObservationIgnored private var forcedTrackIds: [String] = []
    @ObservationIgnored private var remainingTransitions = 0

    func play(_ entry: MixHistoryEntry, player: PlayerService = .shared) async {
        await play(entries: [entry], id: entry.id, player: player)
    }

    func play(_ session: MixHistorySession, from index: Int = 0, player: PlayerService = .shared) async {
        let entries = Array(session.entries.dropFirst(max(0, min(index, session.entries.count - 1))))
        await play(entries: entries, id: session.id, player: player)
    }

    func dismissMessage() {
        message = nil
    }

    func stop(player: PlayerService = .shared) {
        for id in forcedTrackIds { player.djDirector.forcedPlans[id] = nil }
        forcedTrackIds = []
        remainingTransitions = 0
        activeID = nil
    }

    func transitionDidStart(from outgoingId: String, to incomingId: String) {
        guard activeID != nil, forcedTrackIds.contains(outgoingId) else { return }
        remainingTransitions -= 1
        if remainingTransitions <= 0 { stop() }
    }

    private func play(entries: [MixHistoryEntry], id: UUID, player: PlayerService) async {
        guard let first = entries.first else { return }
        stop(player: player)
        isStarting = true
        defer { isStarting = false }
        message = nil
        let tracks = [first.outgoing.track] + entries.map(\.incoming.track)
        if let missing = tracks.first(where: { $0.streamURL == nil && $0.transcodings.isEmpty && $0.localFile == nil }) {
            message = "\(missing.title) isn’t available to play any more."
            return
        }
        var notices: [String] = []
        var startSeconds: TimeInterval = 0
        for (index, entry) in entries.enumerated() {
            let outgoingGrid = await DJSessionDirector.currentBeatGrid(for: entry.outgoing.track)
            let incomingGrid = await DJSessionDirector.currentBeatGrid(for: entry.incoming.track)
            var recorded = entry.plan
            if abs(entry.execution.startSourceSeconds - recorded.mixPointSeconds) < recorded.barSeconds {
                recorded.mixPointSeconds = entry.execution.startSourceSeconds
            }
            let result = MixReplayPlanner.reconcile(recorded, currentOutgoingGrid: outgoingGrid, currentIncomingGrid: incomingGrid)
            if index == 0 { startSeconds = result.startSeconds }
            if let notice = result.notice, !notices.contains(notice) { notices.append(notice) }
            var plan = result.plan
            plan.incomingTrackId = entry.incoming.id
            plan.incomingTitle = entry.incoming.title
            player.djDirector.forcedPlans[entry.outgoing.id] = plan.phantomPlan
            forcedTrackIds.append(entry.outgoing.id)
        }
        remainingTransitions = entries.count
        activeID = id
        message = notices.first
        if !player.isAutoMixEnabled { player.setAutomaticMixEnabled(true) }
        await player.play(first.outgoing.track, in: tracks)
        player.seek(to: startSeconds)
    }
}
