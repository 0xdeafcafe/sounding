import Foundation

@MainActor
struct MixTransitionPerformer {
    let engine: MixEngine

    struct Request {
        var outgoing: MixEngine.Deck
        var incoming: MixEngine.Deck
        var window: TimeInterval
        var entrySeconds: TimeInterval
        var plan: PhantomDJEngine.Plan?
        var filterAccent: PhantomDJEngine.Accent?
        var announceAsMix: Bool
        var startAtPlannedBoundary: Bool
        var outgoingGridFallback: BeatGrid?
        var rateBudgetPercent: Double
        var legacyTempoMatch: (sourceBPM: Double, targetBPM: Double)?
        var resetsIncoming: Bool
        var startsPaused: Bool
        var riserLevel: Double = 0
        var loopsOnDeadline = true
    }

    enum Outcome {
        case started(leadSeconds: TimeInterval, windowSeconds: TimeInterval)
        case failed(reason: String)
    }

    func begin(
        _ request: Request,
        actions: MixActionGroup,
        onFinished: @escaping @MainActor () -> Void
    ) -> Outcome {
        let outgoing = request.outgoing
        let incoming = request.incoming
        let plan = request.plan
        let window = max(0.15, request.window)
        let defersIncomingStart = plan?.templateId == DJTemplates.loopRollDown

        guard engine[incoming].status.isReady else { return .failed(reason: "deck \(incoming.label) is not ready") }
        guard engine.start() else { return .failed(reason: "audio engine would not start") }

        if let grid = plan?.outgoingBeatGrid { engine.setBeatGrid(grid, for: outgoing) }
        if let grid = plan?.incomingBeatGrid { engine.setBeatGrid(grid, for: incoming) }

        if request.resetsIncoming {
            let normalisedGain = engine[incoming].gain
            engine.resetProcessing(on: incoming, killLows: true)
            engine.setGain(normalisedGain, on: incoming)
        }

        let grid = plan?.outgoingBeatGrid ?? request.outgoingGridFallback
        let plannedSourceTime = request.startAtPlannedBoundary ? plan?.mixPointSeconds : nil
        let currentSourceTime = engine.livePosition(of: outgoing)
        let outgoingRate = max(0.01, engine[outgoing].rate)
        engine.setRate(engine[outgoing].rate, on: outgoing)
        applyBeatMatch(request)
        engine.pause(deck: incoming)
        engine.seek(deck: incoming, to: request.entrySeconds)
        engine.setEQ(.low, on: incoming, toDecibels: MixEngine.bassKillDecibels)
        if request.filterAccent == .incomingFilterOpen {
            engine.setFilterCutoff(DJEngineConstants.accentClosedFilterHz, on: incoming, over: 0)
        }

        let aligned: Bool
        var anchorSource: TimeInterval
        let loopStart = engine[outgoing].loopStartSeconds
        let loopLength = engine[outgoing].loopLengthSeconds ?? 0
        if let planned = plannedSourceTime, let loopStart, loopLength > 0,
           planned >= loopStart - 0.002, planned < loopStart + loopLength, planned <= currentSourceTime + 0.06 {
            anchorSource = planned
            aligned = true
        } else if let planned = plannedSourceTime, planned > currentSourceTime + 0.06 {
            anchorSource = planned
            aligned = true
        } else if let grid, let next = engine.alignmentSourceSeconds(
            on: outgoing,
            referenceBeatPeriod: grid.beatPeriod,
            referenceGridAnchor: grid.firstDownbeat,
            requested: plannedSourceTime,
            beatsPerAlignment: 4,
            minimumLead: 0.08
        ) {
            anchorSource = next
            aligned = true
        } else {
            anchorSource = currentSourceTime + 0.08 * outgoingRate
            aligned = false
        }

        let incomingRate = engine[incoming].rate
        if request.loopsOnDeadline, let loop = deadlineLoop(request, grid: grid, anchorSource: anchorSource, currentSource: currentSourceTime, rate: outgoingRate) {
            engine.setLoop(on: outgoing, startSeconds: loop.startSeconds, lengthSeconds: loop.lengthSeconds)
            if anchorSource >= loop.endSeconds - 0.002 { anchorSource = loop.startSeconds }
        }
        let phaseLock = (plan?.outgoingBeatGrid?.isPhaseVerified ?? false)
            && (plan?.incomingBeatGrid?.isPhaseVerified ?? false)
            && plan?.templateId != DJTemplates.cutOnTheOne
        let input = MixTransitionTimelineInput(
            outgoing: outgoing.rawValue,
            incoming: incoming.rawValue,
            sampleRate: engine.sampleRate,
            anchorSourceSeconds: anchorSource,
            window: window,
            entrySeconds: request.entrySeconds,
            outgoingRate: outgoingRate,
            incomingRate: incomingRate,
            outgoingGrid: grid,
            incomingGrid: plan?.incomingBeatGrid ?? engine.beatGrid(for: incoming),
            stages: plan?.stages ?? [],
            bassSwapAtSeconds: plan?.bassSwapAtSeconds,
            bassSwapSeconds: plan?.bassSwapSeconds,
            filterAccent: request.filterAccent,
            defersIncomingStart: defersIncomingStart,
            phaseLock: phaseLock,
            move: plan?.move,
            riserGain: min(1, max(0, request.riserLevel)) * MixRiser.fullScale,
            incomingMidCutDecibels: plan?.incomingMidCutDecibels ?? 0,
            level: engine.transitionLevel(
                outgoing: outgoing,
                incoming: incoming,
                anchorSeconds: anchorSource,
                entrySeconds: request.entrySeconds,
                outgoingGrid: grid,
                incomingGrid: plan?.incomingBeatGrid ?? engine.beatGrid(for: incoming)
            )
        )
        let timeline = MixTimeline.transition(input)
        let effectiveWindow = plan?.move == nil ? window : max(0.15, Double(timeline.lengthFrames) / engine.sampleRate)
        let group = engine.makeGroup()
        let engine = self.engine
        actions.outgoing = outgoing
        actions.incoming = incoming
        actions.window = effectiveWindow
        actions.entrySeconds = request.entrySeconds
        actions.finish = onFinished
        actions.timeline = timeline
        actions.timelineGroup = group
        actions.cancelTimeline = { engine.cancelTimeline(group: $0) }
        actions.resolveBlendStart = { engine.anchorClockSeconds(for: $0) }
        engine.schedule(timeline, group: group)
        actions.add(engine.after(anchor: group, plus: effectiveWindow) { onFinished() })
        var sourceLead = anchorSource - currentSourceTime
        if sourceLead < 0, let loop = engine[outgoing].loopLengthSeconds, loop > 0 { sourceLead += loop }
        let lead = max(0, sourceLead / outgoingRate)
        return .started(leadSeconds: aligned ? lead : 0, windowSeconds: effectiveWindow)
    }

    private func deadlineLoop(
        _ request: Request,
        grid: BeatGrid?,
        anchorSource: TimeInterval,
        currentSource: TimeInterval,
        rate: Double
    ) -> MixDeadlineLoop? {
        guard let plan = request.plan, let downbeats = grid?.downbeats, !downbeats.isEmpty else { return nil }
        if let kind = plan.move?.kind, kind == .loopRoll || kind == .jump { return nil }
        let duration = engine[request.outgoing].duration
        guard duration > 0 else { return nil }
        if let start = engine[request.outgoing].loopStartSeconds, let length = engine[request.outgoing].loopLengthSeconds, length > 0 {
            return MixDeadlineLoop(startSeconds: start, lengthSeconds: length, bars: max(1, Int((length / max(0.01, grid?.barDuration ?? length)).rounded())))
        }
        let probe = MixTransitionTimelineInput(
            outgoing: request.outgoing.rawValue, incoming: request.incoming.rawValue, sampleRate: engine.sampleRate,
            anchorSourceSeconds: anchorSource, window: max(0.15, request.window), entrySeconds: request.entrySeconds,
            outgoingRate: rate, incomingRate: engine[request.incoming].rate, outgoingGrid: grid, incomingGrid: plan.incomingBeatGrid,
            stages: plan.stages, bassSwapAtSeconds: plan.bassSwapAtSeconds, bassSwapSeconds: plan.bassSwapSeconds,
            filterAccent: request.filterAccent, defersIncomingStart: false, phaseLock: false, move: plan.move
        )
        let length = plan.move == nil ? max(0.15, request.window) : Double(MixTimeline.transition(probe).lengthFrames) / engine.sampleRate
        let fastest = max(rate, plan.move?.outgoingRateTarget ?? rate)
        let needed = anchorSource + length * fastest
        guard MixDeadlineLoop.runsOut(neededSourceSeconds: needed, duration: duration) else { return nil }
        return MixDeadlineLoop.lastCleanPhrase(
            downbeats: downbeats, duration: duration, playhead: currentSource,
            vocals: MixVocalMap.shared.vocals(for: engine[request.outgoing].trackId),
            levels: MixVocalMap.shared.levels(for: engine[request.outgoing].trackId)
        )
    }

    static func timelineInput(
        for request: Request,
        anchorSourceSeconds: TimeInterval,
        outgoingRate: Double,
        incomingRate: Double,
        sampleRate: Double
    ) -> MixTransitionTimelineInput {
        let plan = request.plan
        return MixTransitionTimelineInput(
            outgoing: request.outgoing.rawValue,
            incoming: request.incoming.rawValue,
            sampleRate: sampleRate,
            anchorSourceSeconds: anchorSourceSeconds,
            window: max(0.15, request.window),
            entrySeconds: request.entrySeconds,
            outgoingRate: outgoingRate,
            incomingRate: incomingRate,
            outgoingGrid: plan?.outgoingBeatGrid ?? request.outgoingGridFallback,
            incomingGrid: plan?.incomingBeatGrid,
            stages: plan?.stages ?? [],
            bassSwapAtSeconds: plan?.bassSwapAtSeconds,
            bassSwapSeconds: plan?.bassSwapSeconds,
            filterAccent: request.filterAccent,
            defersIncomingStart: plan?.templateId == DJTemplates.loopRollDown,
            phaseLock: (plan?.outgoingBeatGrid?.isPhaseVerified ?? false)
                && (plan?.incomingBeatGrid?.isPhaseVerified ?? false)
                && plan?.templateId != DJTemplates.cutOnTheOne,
            move: plan?.move,
            incomingMidCutDecibels: plan?.incomingMidCutDecibels ?? 0
        )
    }

    private func applyBeatMatch(_ request: Request) {
        let incoming = request.incoming
        let budget = request.rateBudgetPercent
        let outgoingRate = engine[request.outgoing].rate
        if let plan = request.plan {
            let target = plan.incomingRateRatio * outgoingRate
            if abs(target - 1) > 0.0005 {
                engine.setRateRatio(target, on: incoming, maxPercent: budget + abs(outgoingRate - 1) * 100)
            } else {
                engine.setRate(1, on: incoming)
            }
            return
        }
        guard let match = request.legacyTempoMatch else {
            engine.setRate(1, on: incoming)
            return
        }
        engine.matchTempo(on: incoming, sourceBPM: match.sourceBPM, targetBPM: match.targetBPM, maxPercent: budget)
    }

    nonisolated static func quantizedSourceSeconds(
        nominal: TimeInterval,
        snap: StageSnap,
        grid: BeatGrid?
    ) -> TimeInterval {
        guard let grid, grid.beatPeriod > 0 else { return nominal }
        let unit: TimeInterval
        switch snap {
        case .beat: unit = grid.beatPeriod
        case .bar: unit = grid.barDuration > 0 ? grid.barDuration : grid.beatPeriod
        case .phrase: unit = grid.phraseDuration > 0 ? grid.phraseDuration : grid.beatPeriod
        case .free: return nominal
        }
        guard unit > 0 else { return nominal }
        let origin = grid.firstDownbeat
        let offset = nominal - origin
        let steps = (offset / unit - 1e-9).rounded(.up)
        return max(nominal, origin + steps * unit)
    }

    @discardableResult
    func finish(outgoing: MixEngine.Deck, incoming: MixEngine.Deck) -> MixScheduledAction? {
        engine.crossfade(to: incoming, over: 0)
        if engine.masterVolume < 0.999 {
            engine.setMasterVolume(1, over: 2)
        }
        engine.pause(deck: outgoing)
        engine.unload(deck: outgoing)
        engine.resetProcessing(on: outgoing)
        if engine[incoming].loopLengthSeconds != nil { engine.clearLoop(on: incoming) }
        engine.resetEQ(on: incoming)
        engine.openFilter(on: incoming)
        engine.setHighPassCutoff(MixEngine.filterCutoffRange.lowerBound, on: incoming)
        engine.setDelayWet(0, feedback: 0, on: incoming)
        engine.unsync(incoming)
        return scheduleTempoReturn(on: incoming)
    }

    static let tempoHoldBars: Double = 32
    static let tempoReturnBars: Double = 32

    private func scheduleTempoReturn(on deck: MixEngine.Deck) -> MixScheduledAction? {
        let rate = engine[deck].rate
        guard abs(rate - 1) > 0.001, let grid = engine.beatGrid(for: deck), grid.barDuration > 0 else { return nil }
        let position = engine.livePosition(of: deck)
        let duration = engine[deck].duration
        let holdUntil = position + Self.tempoHoldBars * grid.barDuration
        guard let start = grid.phraseStarts(from: holdUntil, through: duration).first else { return nil }
        let rampSource = Self.tempoReturnBars * grid.barDuration
        guard start + rampSource < duration - 30 else { return nil }
        let delay = (start - position) / rate
        let rampWall = rampSource / ((rate + 1) / 2)
        let engine = self.engine
        return engine.after(delay) {
            engine.setRate(1, on: deck, over: rampWall)
        }
    }

    // MARK: - Transport

    enum SeekOutcome: Equatable {
        case live
        case both
        case aborted
        case completed
    }

    func pause(live: MixEngine.Deck, isCrossfading: Bool) {
        engine.pauseAutomation()
        engine.pause(deck: live)
        if isCrossfading { engine.pause(deck: live.other) }
    }

    func resume(live: MixEngine.Deck, isCrossfading: Bool) {
        if isCrossfading {
            engine.play(decks: [live, live.other])
        } else {
            engine.play(deck: live)
        }
        engine.resumeAutomation()
    }

    @discardableResult
    func seek(live: MixEngine.Deck, to seconds: TimeInterval, transition: MixActionGroup?) -> SeekOutcome {
        guard let transition, !transition.isFinished else {
            engine.seek(deck: live, to: seconds)
            return .live
        }
        let outgoing = transition.outgoing
        let incoming = transition.incoming
        let loops = transition.timeline?.events.contains { event in
            if case .loop = event.action { return true }
            return false
        } ?? false
        if loops {
            abort(transition)
            engine.forceClearLoop(on: outgoing)
            engine.seek(deck: outgoing, to: seconds)
            return .aborted
        }
        let outgoingRate = max(0.01, engine[outgoing].rate)
        let incomingRate = max(0.01, engine[incoming].rate)
        let wallDelta = (seconds - engine.livePosition(of: outgoing)) / outgoingRate

        guard let blendStart = transition.blendStart(), wallDelta >= 0 else {
            abort(transition)
            engine.seek(deck: outgoing, to: seconds)
            return .aborted
        }

        let incomingTarget = engine.livePosition(of: incoming) + wallDelta * incomingRate
        let elapsed = engine.automationClock.now - blendStart
        if elapsed + wallDelta >= transition.window {
            transition.isFinished = true
            transition.finish?()
            engine.seek(deck: incoming, to: incomingTarget)
            return .completed
        }

        engine.seekLinked(lead: outgoing, to: seconds, follower: incoming, movesClock: true)
        return .both
    }

    private func abort(_ transition: MixActionGroup) {
        transition.cancelTimelineEvents()
        transition.cancel()
        transition.isFinished = true
        let outgoing = transition.outgoing
        let incoming = transition.incoming
        let outgoingGain = engine[outgoing].gain
        let outgoingRate = engine[outgoing].rate
        let incomingGain = engine[incoming].gain
        engine.cancelAllRamps()
        engine.crossfade(to: outgoing, over: 0)
        engine.resetProcessing(on: outgoing)
        engine.setGain(outgoingGain, on: outgoing)
        engine.setRate(outgoingRate, on: outgoing)
        engine.pause(deck: incoming)
        engine.resetProcessing(on: incoming, killLows: true)
        engine.setGain(incomingGain, on: incoming)
        engine.seek(deck: incoming, to: transition.entrySeconds)
    }
}
