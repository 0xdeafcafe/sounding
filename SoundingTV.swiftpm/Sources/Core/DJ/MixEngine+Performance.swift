import Foundation

extension MixPerformanceTrack {
    init(features: TrackFeatures) {
        let grid = features.beatGrid
        let downbeats = features.barStarts.isEmpty ? (grid?.downbeats ?? []) : features.barStarts
        let profile = features.barProfile.flatMap { $0.level.count == downbeats.count ? $0 : nil }
        self.init(
            trackId: features.trackId,
            duration: features.duration,
            downbeats: downbeats,
            barsPerPhrase: grid?.barsPerPhrase ?? 8,
            phraseOffsetBars: grid?.firstPhraseBar ?? 0,
            vocals: features.provenance.contains(.measuredVocals) ? features.vocalRanges : nil,
            barLevel: profile?.level,
            barDensity: profile?.density,
            barLoop: profile?.loop4,
            sections: features.sections.map { Section(role: Role($0.kind), start: $0.start, end: $0.end) }
        )
    }
}

extension MixPerformanceTrack.Role {
    init(_ kind: SectionKind) {
        switch kind {
        case .ambientIntro, .intro: self = .intro
        case .buildup, .build: self = .build
        case .drop: self = .drop
        case .breakdown, .bridge, .cooldown: self = .breakdown
        case .outro, .ambientOutro: self = .outro
        case .unknown: self = .other
        }
    }
}

extension MixEngine {
    static func planPerformance(
        for features: TrackFeatures,
        level: MixPerformanceLevel,
        playable: ClosedRange<TimeInterval>,
        avoiding: [ClosedRange<TimeInterval>] = [],
        allowed: Set<MixPerformanceMove.Kind> = Set(MixPerformanceMove.Kind.allCases)
    ) -> [MixPerformanceMove] {
        MixPerformancePlanner.plan(.init(
            track: MixPerformanceTrack(features: features),
            level: level,
            playable: playable,
            avoiding: avoiding,
            allowed: allowed
        ))
    }

    @discardableResult
    func schedulePerformance(_ moves: [MixPerformanceMove], track: MixPerformanceTrack, on deck: Deck) -> MixPerformanceSchedule {
        cancelPerformance(on: deck)
        let rate = self[deck].rate
        let position = livePosition(of: deck)
        let pending = moves.filter { $0.startSeconds > position + 0.05 }
        var plan = MixPerformanceSchedule(trackId: track.trackId, moves: pending)
        for move in pending {
            let group = makeGroup()
            schedule(MixTimeline.performance(move, deck: deck.rawValue, track: track, sampleRate: sampleRate, rate: rate), group: group)
            plan.groups.append(group)
        }
        performanceSchedules[deck] = plan
        return plan
    }

    func cancelPerformance(on deck: Deck) {
        guard let existing = performanceSchedules[deck] else { return }
        for group in existing.groups { restoreTimeline(group: group) }
        performanceSchedules[deck] = nil
    }

    func cancelPerformance(on deck: Deck, overlapping span: ClosedRange<TimeInterval>) {
        guard var existing = performanceSchedules[deck] else { return }
        var keptMoves: [MixPerformanceMove] = []
        var keptGroups: [Int32] = []
        for (move, group) in zip(existing.moves, existing.groups) {
            if move.span.overlaps(span) {
                restoreTimeline(group: group)
            } else {
                keptMoves.append(move)
                keptGroups.append(group)
            }
        }
        existing.moves = keptMoves
        existing.groups = keptGroups
        performanceSchedules[deck] = existing
    }

    func upcomingPerformance(on deck: Deck) -> (move: MixPerformanceMove, bars: Int)? {
        guard let schedule = performanceSchedules[deck] else { return nil }
        let position = livePosition(of: deck)
        guard let move = schedule.upcoming(after: position) else { return nil }
        return (move, schedule.barsUntil(move, from: position))
    }
}
