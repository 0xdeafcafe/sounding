#if DEBUG || DJ_PLAN_HARNESS
import Foundation

enum DJPlanFixture {
    static func grid(bpm: Double, anchor: TimeInterval, duration: TimeInterval) -> BeatGrid {
        let beat = 60 / bpm
        let beats = stride(from: anchor, to: duration, by: beat).map { $0 }
        let downbeats = stride(from: 0, to: beats.count, by: 4).map { beats[$0] }
        return BeatGrid(anchor: anchor, beatPeriod: beat, confidence: 0.92, beats: beats, downbeats: downbeats, phraseOffsetBars: 0)
    }

    static let outgoingGrid = grid(bpm: 124, anchor: 0.21, duration: 420)
    static let incomingGrid = grid(bpm: 125, anchor: 0.08, duration: 420)
    static var mixPoint: TimeInterval { outgoingGrid.downbeats![104] }
    static var entry: TimeInterval { incomingGrid.downbeats![0] }

    static var lowSun: DJPlanTrack {
        let bar = outgoingGrid.barDuration
        return DJPlanTrack(
            id: "fixture-low-sun", title: "Low Sun", artist: "Low Sun",
            duration: mixPoint + 24 * bar + 0.4,
            grid: outgoingGrid,
            key: CamelotKey(wheelPosition: 9, mode: .minor),
            sections: [
                TrackSection(kind: .drop, start: mixPoint - 32 * bar, end: mixPoint),
                TrackSection(kind: .outro, start: mixPoint, end: mixPoint + 24 * bar)
            ],
            vocalRanges: [(mixPoint - 30 * bar)...(mixPoint - 0.3)],
            vocalsMeasured: true,
            loudnessDecibels: -9
        )
    }

    static var softStatic: DJPlanTrack {
        let bar = incomingGrid.barDuration
        return DJPlanTrack(
            id: "fixture-soft-static", title: "Soft Static", artist: "Soft Static",
            duration: 372,
            grid: incomingGrid,
            key: CamelotKey(wheelPosition: 9, mode: .minor),
            sections: [
                TrackSection(kind: .intro, start: 0, end: 40 * bar),
                TrackSection(kind: .drop, start: 40 * bar, end: 72 * bar)
            ],
            vocalRanges: [(42 * bar)...(70 * bar)],
            vocalsMeasured: true,
            loudnessDecibels: -9.5
        )
    }

    static var reanalysedSoftStatic: DJPlanTrack {
        var track = softStatic
        track.grid = grid(bpm: 125 * 15.9 / 16, anchor: 0.08, duration: 420)
        return track
    }

    static func record(move: MixMove, from outgoing: DJPlanTrack, to incoming: DJPlanTrack, mixPoint: TimeInterval, entry: TimeInterval) -> MixPlanRecord {
        let bar = outgoing.grid?.barDuration ?? 2
        return MixPlanRecord(
            mixPointSeconds: mixPoint,
            transitionSeconds: Double(move.totalBars) * bar,
            outroShape: "breakdown",
            accent: nil,
            reasoning: "\(move.displayName) into \(incoming.title)",
            entrySeconds: entry,
            bassSwapAtSeconds: Double(move.bassSwapBar ?? move.leadBars) * bar,
            bassSwapSeconds: outgoing.grid?.beatPeriod ?? 0.5,
            incomingRateRatio: (outgoing.bpm ?? 124) / (incoming.bpm ?? 124),
            incomingTrackId: incoming.id,
            profileId: nil,
            templateId: nil,
            stages: [],
            outgoingBeatGrid: outgoing.grid,
            incomingBeatGrid: incoming.grid,
            move: move,
            incomingTitle: incoming.title,
            incomingMidCutDecibels: 0
        )
    }

    static var loopMix: MixMove {
        var move = MixMove.loopMix(outLoop: 4, inLoop: 4, fadeIn: 8, fadeOut: 16)
        move.bassSwapBar = 12
        return move
    }

    static var autoPlan: MixPlanRecord {
        record(move: loopMix, from: lowSun, to: softStatic, mixPoint: mixPoint, entry: entry)
    }

    static var autoTimeline: DJPlanTimeline {
        DJPlanTimeline(outgoing: lowSun, incoming: softStatic, auto: autoPlan)
    }

    static var editedTimeline: DJPlanTimeline {
        autoTimeline.applying(.bassSwap, bar: 17).applying(.fadeOutStart, bar: 17)
    }

    static func crateTrack(_ id: String, _ title: String, artist: String, key: Int, mode: CamelotKey.CamelotMode = .minor, bpm: Double = 124, analysing: Double? = nil) -> DJPlanTrack {
        DJPlanTrack(
            id: id, title: title, artist: artist, duration: 360,
            grid: analysing == nil ? grid(bpm: bpm, anchor: 0.1, duration: 360) : nil,
            key: analysing == nil ? CamelotKey(wheelPosition: key, mode: mode) : nil,
            analysisProgress: analysing
        )
    }

    static var crate: DJPlanCrate {
        DJPlanCrate(
            name: "Friday Warm-Up",
            tracks: [
                crateTrack("fixture-night-tapes", "Night Tapes", artist: "Night Tapes", key: 8),
                crateTrack("fixture-glass-district", "Glass District", artist: "Glass District", key: 9),
                lowSun,
                softStatic,
                crateTrack("fixture-copper-line", "Copper Line", artist: "Low Sun", key: 10),
                crateTrack("fixture-tidal-rooms", "Tidal Rooms", artist: "Maya Sol", key: 1),
                crateTrack("fixture-halflight", "Halflight", artist: "Juno Vale", key: 2, analysing: 0.4),
                crateTrack("fixture-velvet-hour", "Velvet Hour", artist: "Night Tapes", key: 10, bpm: 122)
            ],
            lockedCount: 3
        )
    }

    static func autoMove(for key: DJPlanTransitionKey) -> MixMove {
        switch (key.outgoingId, key.incomingId) {
        case ("fixture-night-tapes", "fixture-glass-district"): return .blend(bars: 16, swapAt: 8)
        case ("fixture-glass-district", "fixture-low-sun"): return .loopMix(outLoop: 4, inLoop: 4, fadeIn: 8, fadeOut: 8)
        case ("fixture-low-sun", "fixture-soft-static"): return loopMix
        case ("fixture-copper-line", "fixture-tidal-rooms"): return .dropOnTheOne(echo: false)
        case ("fixture-velvet-hour", "fixture-copper-line"): return .echoOut
        default: return .blend(bars: 16, swapAt: 8)
        }
    }

    static func plan(from outgoing: DJPlanTrack, to incoming: DJPlanTrack) -> MixPlanRecord {
        if outgoing.id == lowSun.id, incoming.id == softStatic.id { return autoPlan }
        let move = autoMove(for: DJPlanTransitionKey(outgoingId: outgoing.id, incomingId: incoming.id))
        let grid = outgoing.grid ?? self.grid(bpm: 124, anchor: 0.1, duration: outgoing.duration)
        let bar = grid.barDuration
        let exit = grid.nearestDownbeat(to: outgoing.duration - Double(move.totalBars + 8) * bar)
        return record(move: move, from: outgoing, to: incoming, mixPoint: exit, entry: incoming.grid?.firstDownbeat ?? 0)
    }
}
#endif
