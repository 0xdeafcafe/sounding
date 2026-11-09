import Foundation

struct SetJourneyStep: Sendable, Equatable {
    let trackId: String
    let atMinute: Double
    let targetEnergy: Int?
    let energy: Int?
    let reasons: [PickReason]
}

struct SetJourney: Sendable, Equatable {
    let steps: [SetJourneyStep]
    let cost: Double

    static let width = 8

    static func plan(
        from seed: TrackFeatures,
        pool candidates: [TrackFeatures],
        history: SetHistory,
        energyStepLimit: Int = 2,
        length: Int? = nil
    ) -> SetJourney? {
        let pool = candidates.filter { $0.trackId != seed.trackId }
        guard !pool.isEmpty else { return nil }
        let depth = min(pool.count, length ?? pool.count)
        let goals = DJFlowSelector.arc(
            from: DJFlowSelector.energy(seed), target: history.energyTarget,
            steps: depth, stepLimit: max(1, energyStepLimit)
        )
        guard let best = DJFlowSelector.search(
            outgoing: seed, pool: pool, history: history, goals: goals,
            depth: depth, width: width, discount: 1
        ) else { return nil }

        var steps: [SetJourneyStep] = []
        var previous = seed
        var minute = history.setMinute + seed.duration / 60 * DJFlowSelector.playedShare
        for (step, index) in best.path.enumerated() {
            let track = pool[index]
            let goal = DJFlowSelector.goal(step: step, minute: minute, goals: goals, history: history)
            var reasons = DJFlowSelector.reasons(from: previous, to: track, energyGoal: goal)
            if let goal, history.intent != nil, let level = DJFlowSelector.energy(track), abs(level - goal) <= 1 {
                reasons.append(PickReason(kind: .journey, text: "on the way to energy \(goal)"))
            }
            if let intent = history.intent, !intent.allowsVocals(atMinute: minute), track.vocalRanges.isEmpty {
                reasons.append(PickReason(kind: .vocals, text: "no vocals yet"))
            }
            steps.append(SetJourneyStep(
                trackId: track.trackId, atMinute: minute, targetEnergy: goal,
                energy: DJFlowSelector.energy(track), reasons: reasons
            ))
            minute += track.duration / 60 * DJFlowSelector.playedShare
            previous = track
        }
        return SetJourney(steps: steps, cost: best.cost)
    }

    static func greedy(
        from seed: TrackFeatures,
        pool candidates: [TrackFeatures],
        history: SetHistory,
        length: Int? = nil
    ) -> [String] {
        var remaining = candidates.filter { $0.trackId != seed.trackId }
        var path: [String] = []
        var previous = seed
        var minute = history.setMinute + seed.duration / 60 * DJFlowSelector.playedShare
        let depth = min(remaining.count, length ?? remaining.count)
        while path.count < depth {
            let goal = history.intent?.targetEnergy(atMinute: minute) ?? history.energyTarget
            let scored = remaining.enumerated().map { offset, track in
                (offset, DJFlowSelector.stepCost(from: previous, to: track, queueIndex: 0, energyGoal: goal, history: history, recentInPath: [], atMinute: minute).total)
            }
            guard let best = scored.filter({ $0.1.isFinite }).min(by: { $0.1 < $1.1 }) else { break }
            let track = remaining.remove(at: best.0)
            path.append(track.trackId)
            minute += track.duration / 60 * DJFlowSelector.playedShare
            previous = track
        }
        return path
    }
}
