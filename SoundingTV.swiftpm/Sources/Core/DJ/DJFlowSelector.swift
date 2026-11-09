import Foundation

struct DJFlowChoice: Equatable, Sendable {
    let trackId: String
    let why: String
    let cost: Double
    let queueIndex: Int
    let path: [String]

    var isReordered: Bool { queueIndex > 0 }
}

enum DJFlowSelector {

    static let maxCandidates = 12
    static let beamWidth = 4
    static let depth = 3
    static let maxCamelotDistance = 2
    static let maxTempoPercent = 6.0
    static let trackCooldown = 30
    static let artistCooldown = 2

    struct StepCost: Equatable, Sendable {
        let total: Double
        let vetoReason: String?
    }

    static func mayReorder(keepQueueOrder: Bool, explicitOrders: [DJQueueOrderPolicy?]) -> Bool {
        guard !keepQueueOrder else { return false }
        return !explicitOrders.contains { $0 == .preserve || $0 == .random }
    }

    static func choose(
        outgoing: TrackFeatures,
        candidates: [TrackFeatures],
        history: SetHistory,
        profile: DJProfile,
        keepQueueOrder: Bool
    ) -> DJFlowChoice? {
        let pool = Array(candidates.filter { $0.trackId != outgoing.trackId }.prefix(maxCandidates))
        guard let first = pool.first else { return nil }
        let start = energy(outgoing)
        let goals = arc(from: start, target: history.energyTarget, steps: depth, stepLimit: max(1, profile.energyStepLimit))

        if keepQueueOrder || pool.count == 1 {
            let goal = goal(step: 0, minute: history.setMinute, goals: goals, history: history)
            let cost = stepCost(from: outgoing, to: first, queueIndex: 0, energyGoal: goal, history: history, recentInPath: [], atMinute: history.setMinute)
            return DJFlowChoice(
                trackId: first.trackId,
                why: why(from: outgoing, to: first, energyGoal: goal),
                cost: cost.total,
                queueIndex: 0,
                path: [first.trackId]
            )
        }

        guard let best = search(outgoing: outgoing, pool: pool, history: history, goals: goals, depth: depth, width: beamWidth),
              let index = best.path.first else {
            return DJFlowChoice(
                trackId: first.trackId,
                why: "Next in the queue",
                cost: 1,
                queueIndex: 0,
                path: [first.trackId]
            )
        }
        let chosen = pool[index]
        let goal = goal(step: 0, minute: history.setMinute, goals: goals, history: history)
        let firstStep = stepCost(from: outgoing, to: chosen, queueIndex: index, energyGoal: goal, history: history, recentInPath: [outgoing.artist], atMinute: history.setMinute)
        return DJFlowChoice(
            trackId: chosen.trackId,
            why: why(from: outgoing, to: chosen, energyGoal: goal),
            cost: firstStep.total,
            queueIndex: index,
            path: best.path.map { pool[$0].trackId }
        )
    }

    struct Beam {
        var path: [Int]
        var cost: Double
        var minute: Double
    }

    static let playedShare = 0.7

    static func goal(step: Int, minute: Double, goals: [Int?], history: SetHistory) -> Int? {
        if let intent = history.intent { return intent.targetEnergy(atMinute: minute) }
        return goals.isEmpty ? nil : goals[min(step, goals.count - 1)]
    }

    static func search(
        outgoing: TrackFeatures,
        pool: [TrackFeatures],
        history: SetHistory,
        goals: [Int?],
        depth: Int,
        width: Int,
        discount: Double = 0.7
    ) -> Beam? {
        var beams = [Beam(path: [], cost: 0, minute: history.setMinute + outgoing.duration / 60 * playedShare)]
        var finished: [Beam] = []
        for step in 0..<min(depth, pool.count) {
            var expanded: [Beam] = []
            for beam in beams {
                let previous = beam.path.last.map { pool[$0] } ?? outgoing
                let artists = beam.path.map { pool[$0].artist } + [outgoing.artist]
                var grew = false
                for index in pool.indices where !beam.path.contains(index) {
                    let cost = stepCost(
                        from: previous, to: pool[index], queueIndex: index,
                        energyGoal: goal(step: step, minute: beam.minute, goals: goals, history: history),
                        history: history, recentInPath: artists, atMinute: beam.minute
                    )
                    guard cost.vetoReason == nil else { continue }
                    grew = true
                    expanded.append(Beam(
                        path: beam.path + [index],
                        cost: beam.cost + cost.total * pow(discount, Double(step)),
                        minute: beam.minute + pool[index].duration / 60 * playedShare
                    ))
                }
                if !grew, !beam.path.isEmpty { finished.append(beam) }
            }
            guard !expanded.isEmpty else { break }
            expanded.sort {
                if $0.cost != $1.cost { return $0.cost < $1.cost }
                return $0.path.lexicographicallyPrecedes($1.path)
            }
            beams = Array(expanded.prefix(width))
        }
        finished.append(contentsOf: beams.filter { !$0.path.isEmpty })

        return finished.min(by: { lhs, rhs in
            let l = lhs.cost / Double(lhs.path.count) - Double(lhs.path.count) * 0.001
            let r = rhs.cost / Double(rhs.path.count) - Double(rhs.path.count) * 0.001
            if l != r { return l < r }
            return lhs.path.lexicographicallyPrecedes(rhs.path)
        })
    }

    static func stepCost(
        from: TrackFeatures,
        to: TrackFeatures,
        queueIndex: Int,
        energyGoal: Int?,
        history: SetHistory,
        recentInPath: [String],
        atMinute: Double? = nil
    ) -> StepCost {
        if history.recentTrackIds.prefix(trackCooldown).contains(to.trackId) {
            return StepCost(total: .infinity, vetoReason: "played recently")
        }
        let beatless = isBeatless(from) || isBeatless(to)

        var total = 0.0
        if let distance = camelotDistance(from, to) {
            if distance > maxCamelotDistance, !beatless {
                return StepCost(total: .infinity, vetoReason: "\(distance) steps round the wheel")
            }
            total += [0.0, 0.15, 0.4][min(distance, 2)] * 1.0
        } else {
            total += 0.2
        }

        if !beatless, let percent = tempoPercent(from, to) {
            if percent > maxTempoPercent {
                return StepCost(total: .infinity, vetoReason: "tempo \(Int(percent.rounded()))% apart")
            }
            total += percent / maxTempoPercent * 0.9
        } else if !beatless {
            total += 0.2
        }

        if let goal = energyGoal, let level = energy(to) {
            total += Double(abs(level - goal)) / 9 * 1.2
        } else {
            total += 0.15
        }

        if let a = from.genre?.family, let b = to.genre?.family, a != .unknown, b != .unknown {
            total += min(1, GenreFamilyGraph.distance(a, b) * 3) * 0.6
        } else {
            total += 0.1
        }

        let artist = to.artist.lowercased()
        if !artist.isEmpty {
            let recentArtists = (recentInPath + history.recentArtists.prefix(artistCooldown)).map { $0.lowercased() }
            if recentArtists.contains(artist) { total += 0.8 }
        }

        total += TimbreScoring.cost(from: from.timbre, to: to.timbre)
        total += TimbreScoring.trajectoryCost(from: EnergyTrajectory(envelope: from.envelope), to: EnergyTrajectory(envelope: to.envelope))

        if let intent = history.intent {
            let minute = atMinute ?? history.setMinute
            if !intent.allowsVocals(atMinute: minute), !to.vocalRanges.isEmpty {
                total += 1.5
            }
            let outside = intent.bpmOutsideRange(bpm(to))
            if outside > 0 { total += min(1.2, outside / 4 * 0.6) }
        }

        total += seamCost(from: from, to: to)
        total += Double(queueIndex) * 0.04
        return StepCost(total: total, vetoReason: nil)
    }

    static func seamCost(from: TrackFeatures, to: TrackFeatures) -> Double {
        switch DJHandover.feasibleBars(outgoing: from, incoming: to) {
        case 32...: return 0
        case 16..<32: return 0.15
        case 8..<16: return 0.3
        default: return 0.5
        }
    }

    static func arc(from start: Int?, target: Int?, steps: Int, stepLimit: Int) -> [Int?] {
        guard let start else { return Array(repeating: target, count: max(1, steps)) }
        guard let target else { return Array(repeating: start, count: max(1, steps)) }
        return (1...max(1, steps)).map { step in
            let reach = stepLimit * step
            return start + max(-reach, min(reach, target - start))
        }
    }

    static func energy(_ features: TrackFeatures) -> Int? {
        EnergyTerm.level(from: features)?.level
    }

    static func bpm(_ features: TrackFeatures) -> Double? {
        if let grid = features.beatGrid, grid.bpm > 0 { return grid.bpm }
        return features.genre?.bpmHint
    }

    static func tempoPercent(_ a: TrackFeatures, _ b: TrackFeatures) -> Double? {
        guard let from = bpm(a), let to = bpm(b), from > 0, to > 0 else { return nil }
        let folded = [to, to * 2, to / 2].min { abs($0 - from) < abs($1 - from) } ?? to
        return abs(folded - from) / from * 100
    }

    static func camelotDistance(_ a: TrackFeatures, _ b: TrackFeatures) -> Int? {
        guard let from = a.key(at: a.duration), let to = b.key(at: 0) else { return nil }
        return from.wheelSteps(to: to) + (from.mode == to.mode ? 0 : 1)
    }

    static func isBeatless(_ features: TrackFeatures) -> Bool {
        if features.genre?.genre == .ambient || features.genre?.family == .ambient { return true }
        let beatlessKinds: Set<SectionKind> = [.ambientIntro, .ambientOutro]
        return !features.sections.isEmpty && features.sections.allSatisfy { beatlessKinds.contains($0.kind) }
    }

    static func why(from: TrackFeatures, to: TrackFeatures, energyGoal: Int?) -> String {
        PickReason.deterministicLine(reasons(from: from, to: to, energyGoal: energyGoal))
    }

    static func reasons(from: TrackFeatures, to: TrackFeatures, energyGoal: Int?) -> [PickReason] {
        var parts: [PickReason] = []
        if let a = from.key(at: from.duration), let b = to.key(at: 0) {
            let steps = a.wheelSteps(to: b)
            let text: String
            switch (steps, a.mode == b.mode) {
            case (0, true): text = "Same key"
            case (0, false): text = "Relative key"
            case (1, true): text = "Next key"
            default: text = "\(a.label) → \(b.label)"
            }
            parts.append(PickReason(kind: .key, text: text))
        }
        if let a = bpm(from), let b = bpm(to) {
            let from = Int(a.rounded()), to = Int(b.rounded())
            parts.append(PickReason(kind: .tempo, text: from == to ? "\(from) BPM" : "\(from) → \(to) BPM"))
        }
        if let a = energy(from), let b = energy(to) {
            parts.append(PickReason(kind: .energy, text: b > a ? "energy up" : b < a ? "energy down" : "energy holds"))
        }
        if let a = from.timbre, let b = to.timbre, let similarity = a.similarity(to: b) {
            if similarity >= TimbreScoring.similarCosine {
                parts.append(PickReason(kind: .sound, text: "sounds alike"))
            } else if let seam = a.seam(into: b), seam >= TimbreScoring.similarCosine {
                parts.append(PickReason(kind: .sound, text: "smooth handover"))
            }
        }
        return parts
    }
}
