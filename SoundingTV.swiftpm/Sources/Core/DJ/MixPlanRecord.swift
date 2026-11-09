import Foundation

struct MixPlanRecord: Codable, Equatable, Sendable {
    var mixPointSeconds: TimeInterval
    var transitionSeconds: TimeInterval
    var outroShape: String
    var accent: TransitionAccent?
    var reasoning: String
    var entrySeconds: TimeInterval
    var bassSwapAtSeconds: TimeInterval
    var bassSwapSeconds: TimeInterval
    var incomingRateRatio: Double
    var incomingTrackId: String?
    var profileId: DJProfileID?
    var templateId: TransitionTemplateID?
    var stages: [TransitionStage]
    var outgoingBeatGrid: BeatGrid?
    var incomingBeatGrid: BeatGrid?
    var move: MixMove?
    var incomingTitle: String?
    var incomingMidCutDecibels: Double

    var mixEndSeconds: TimeInterval { mixPointSeconds + transitionSeconds }

    var barSeconds: TimeInterval {
        let bar = outgoingBeatGrid?.barDuration ?? 0
        return bar > 0.2 ? bar : 2
    }

    var exitBar: Int? {
        guard let grid = outgoingBeatGrid, grid.barDuration > 0 else { return nil }
        return Self.bar(of: mixPointSeconds, in: grid)
    }

    var entryBar: Int? {
        guard let grid = incomingBeatGrid, grid.barDuration > 0 else { return nil }
        return Self.bar(of: entrySeconds, in: grid)
    }

    var lengthBars: Int {
        if let move { return max(1, move.totalBars) }
        return max(1, Int((transitionSeconds / barSeconds).rounded()))
    }

    var moveKind: String {
        move?.kind.rawValue ?? templateId?.rawValue ?? "cut"
    }

    var moveName: String {
        if let move { return move.displayName }
        guard let templateId else { return "Cut" }
        if templateId.rawValue.localizedCaseInsensitiveContains("cut") { return "Cut" }
        return "Blend"
    }

    var loopRegions: [ClosedRange<TimeInterval>] {
        var regions: [ClosedRange<TimeInterval>] = []
        for stage in stages where stage.deck == .outgoing {
            if case .loop(let bars) = stage.action, bars > 0 {
                let start = mixPointSeconds + stage.atSeconds
                regions.append(start...(start + bars * barSeconds))
            }
        }
        if let move, move.outLoopBars > 0 {
            let start = mixPointSeconds
            regions.append(start...(start + Double(move.outLoopBars) * barSeconds))
        }
        return regions
    }

    static func bar(of seconds: TimeInterval, in grid: BeatGrid) -> Int {
        if let downbeats = grid.downbeats, !downbeats.isEmpty {
            let index = downbeats.lastIndex { $0 <= seconds + 0.01 } ?? 0
            return index + 1
        }
        return max(1, Int(((seconds - grid.firstDownbeat) / grid.barDuration).rounded(.down)) + 1)
    }
}

struct MixExecutionRecord: Codable, Equatable, Sendable {
    var startSourceSeconds: TimeInterval
    var windowSeconds: TimeInterval
    var entrySeconds: TimeInterval
    var outgoingRate: Double
    var incomingRate: Double
    var startedAtPlannedBoundary: Bool
    var riserLevel: Double
    var sampleRate: Double
}

enum MixReplayPlanner {
    static let leadInBars = 8
    static let tempoTolerance = 0.002
    static let phaseTolerance: TimeInterval = 0.02

    struct Result: Equatable, Sendable {
        var plan: MixPlanRecord
        var startSeconds: TimeInterval
        var resnapped: Bool
        var usedRecordedGrid: Bool
        var notice: String?
    }

    static func gridMatches(_ recorded: BeatGrid?, _ current: BeatGrid?, near seconds: TimeInterval) -> Bool {
        guard let recorded, let current else { return true }
        guard recorded.bpm > 0, current.bpm > 0 else { return true }
        if abs(recorded.bpm - current.bpm) / recorded.bpm > tempoTolerance { return false }
        let a = recorded.nearestDownbeat(to: seconds)
        let b = current.nearestDownbeat(to: seconds)
        return abs(a - b) <= phaseTolerance
    }

    static func reconcile(
        _ recorded: MixPlanRecord,
        currentOutgoingGrid: BeatGrid?,
        currentIncomingGrid: BeatGrid?
    ) -> Result {
        let outgoingOK = gridMatches(recorded.outgoingBeatGrid, currentOutgoingGrid, near: recorded.mixPointSeconds)
        let incomingOK = gridMatches(recorded.incomingBeatGrid, currentIncomingGrid, near: recorded.entrySeconds)
        var plan = recorded
        var notice: String?
        var resnapped = false
        if !outgoingOK || !incomingOK {
            resnapped = true
            if !outgoingOK, let grid = currentOutgoingGrid {
                plan.mixPointSeconds = grid.nearestDownbeat(to: recorded.mixPointSeconds)
                plan.outgoingBeatGrid = grid
            }
            if !incomingOK, let grid = currentIncomingGrid {
                plan.entrySeconds = max(0, grid.nearestDownbeat(to: recorded.entrySeconds))
                plan.incomingBeatGrid = grid
            }
            notice = "The beat grid has changed since this mix, so it starts on the nearest bar."
        }
        let usedRecorded = currentOutgoingGrid == nil || currentIncomingGrid == nil
        if usedRecorded, notice == nil, recorded.outgoingBeatGrid != nil {
            notice = "Analysis isn’t ready yet, so this mix uses its recorded beat grid."
        }
        return Result(
            plan: plan,
            startSeconds: startSeconds(for: plan),
            resnapped: resnapped,
            usedRecordedGrid: usedRecorded,
            notice: notice
        )
    }

    static func startSeconds(for plan: MixPlanRecord) -> TimeInterval {
        max(0, plan.mixPointSeconds - Double(leadInBars) * plan.barSeconds)
    }

    static func timelineInput(
        plan: MixPlanRecord,
        execution: MixExecutionRecord,
        outgoing: Int,
        incoming: Int,
        riserGain: Double = 0
    ) -> MixTransitionTimelineInput {
        let phaseLock = (plan.outgoingBeatGrid?.isPhaseVerified ?? false)
            && (plan.incomingBeatGrid?.isPhaseVerified ?? false)
            && plan.templateId != "cutOnTheOne"
        return MixTransitionTimelineInput(
            outgoing: outgoing,
            incoming: incoming,
            sampleRate: execution.sampleRate,
            anchorSourceSeconds: execution.startSourceSeconds,
            window: max(0.15, execution.windowSeconds),
            entrySeconds: execution.entrySeconds,
            outgoingRate: execution.outgoingRate,
            incomingRate: execution.incomingRate,
            outgoingGrid: plan.outgoingBeatGrid,
            incomingGrid: plan.incomingBeatGrid,
            stages: plan.stages,
            bassSwapAtSeconds: plan.bassSwapAtSeconds,
            bassSwapSeconds: plan.bassSwapSeconds,
            filterAccent: plan.accent,
            defersIncomingStart: plan.templateId == "loopRollDown",
            phaseLock: phaseLock,
            move: plan.move,
            riserGain: riserGain,
            incomingMidCutDecibels: plan.incomingMidCutDecibels
        )
    }
}
