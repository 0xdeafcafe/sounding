import Foundation
import Observation

@MainActor
@Observable
final class AutoMixLive {
    static let shared = AutoMixLive()

    private(set) var state: AutoMixLiveState?

    @ObservationIgnored private var mixKey: String?
    @ObservationIgnored private var mixStartedAt: Date?
    @ObservationIgnored private var lastMixing: AutoMixLiveState?
    @ObservationIgnored private var recapTask: Task<Void, Never>?
    @ObservationIgnored private var fixtureTask: Task<Void, Never>?
    @ObservationIgnored private(set) var isFixture = false

    static let recapSeconds: TimeInterval = 6

    private init() {
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["SOUNDING_TV_AUTOMIX_FIXTURE"] {
            startFixture(name)
        }
        #endif
    }

    func publish(_ next: AutoMixLiveState?) {
        guard !isFixture else { return }
        guard var next else {
            finishIfNeeded()
            return
        }
        recapTask?.cancel()
        recapTask = nil
        if next.stage == .mixing {
            let key = "\(next.incomingTrackId ?? "-")#\(next.moveKind)"
            if key != mixKey {
                mixKey = key
                mixStartedAt = next.startsAt
            }
            if let started = mixStartedAt { next.startsAt = started }
            lastMixing = next
        } else {
            if mixKey != nil, let last = lastMixing, next.incomingTrackId != last.incomingTrackId {
                showRecap(for: last)
                return
            }
            mixKey = nil
            mixStartedAt = nil
            if let current = state, current.stage == .upcoming,
               abs(current.startsAt.timeIntervalSince(next.startsAt)) < 0.03 {
                next.startsAt = current.startsAt
                next.anchoredAt = current.anchoredAt
                next.outgoing = current.outgoing
                next.incoming = current.incoming
            }
        }
        if next != state { state = next }
    }

    private func finishIfNeeded() {
        guard mixKey != nil, let last = lastMixing else {
            if recapTask == nil, state != nil { state = nil }
            return
        }
        showRecap(for: last)
    }

    private func showRecap(for last: AutoMixLiveState) {
        mixKey = nil
        mixStartedAt = nil
        lastMixing = nil
        var done = last
        done.stage = .finished
        done.recap = "\(last.moveName) into \(last.incomingTitle)"
        done.isPlaying = false
        state = done
        recapTask?.cancel()
        recapTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.recapSeconds))
            guard !Task.isCancelled, let self else { return }
            self.recapTask = nil
            if self.state?.stage == .finished { self.state = nil }
        }
    }

    // MARK: - Phases

    static func phases(for move: MixMove?, lengthBars: Int, bassSwapBar: Double?) -> (phases: [AutoMixLiveState.Phase], riserStart: Double?) {
        typealias Phase = AutoMixLiveState.Phase
        guard let move else {
            let total = Double(max(1, lengthBars))
            let swap = bassSwapBar.map { min(max(1, $0), total - 1) } ?? (total * 0.55).rounded()
            return ([
                Phase(name: "Blend in", startBar: 0, bars: swap),
                Phase(name: "Bass swap", startBar: swap, bars: 1),
                Phase(name: "Blend out", startBar: swap + 1, bars: max(0, total - swap - 1))
            ].filter { $0.bars > 0 }, nil)
        }
        var phases: [Phase] = []
        var bar = 0.0
        func add(_ name: String, _ bars: Double) {
            guard bars > 0 else { return }
            phases.append(Phase(name: name, startBar: bar, bars: bars))
            bar += bars
        }
        let outName = move.filterShape == .filterOut ? "Filter out" : "Blend out"
        switch move.kind {
        case .loopRoll:
            for rung in move.ladder {
                for _ in 0..<max(1, rung.passes) {
                    add(rung.bars == 1 ? "Loop 1 bar" : "Loop \(rung.bars) bars", Double(rung.bars))
                }
            }
            add("Drop", Double(max(1, move.tailBars)))
        case .dropIn:
            add("Build", Double(move.incomingLeadBars))
            add("Drop", Double(max(1, move.blendBars)))
        case .fxBuild:
            add(move.displayName, Double(move.leadBars))
            add("Cut", Double(max(1, move.tailBars)))
        case .echoOut:
            add("Echo throw", Double(max(1, move.leadBars)))
            add("Tail", Double(max(1, move.tailBars)))
        case .cut:
            add("Cut", 1)
        case .dropOnTheOne:
            if move.leadBars > 0 { add("Echo throw", Double(move.leadBars)) }
            add("Drop", Double(max(1, move.tailBars)))
        case .tempoRamp:
            add("Tempo ramp", Double(move.leadBars))
            let swap = Double(move.bassSwapBar ?? move.blendBars / 2)
            add("Blend in", swap)
            add("Bass swap", 1)
            add("Blend out", Double(move.blendBars) - swap - 1)
        case .breakdownExit:
            let swap = Double(move.bassSwapBar ?? move.blendBars / 2)
            add(move.filterShape == .filterOut ? "Filter out" : "Blend in", swap)
            add("Bass swap", 1)
            add("Blend out", Double(move.blendBars) - swap - 1)
        case .loopMix:
            add("Loop in", Double(max(1, move.leadBars)))
            add(outName, Double(max(1, move.blendBars)))
        case .blend, .bridge, .jump:
            let total = Double(max(2, move.blendBars))
            let swap = Double(move.bassSwapBar ?? Int(total / 2))
            add(move.kind == .jump ? "Jump in" : "Blend in", min(swap, total - 1))
            add("Bass swap", 1)
            add(outName, total - min(swap, total - 1) - 1)
        }
        var riser: Double?
        if move.usesRiser {
            let landing = Double(move.landingBar)
            let bars = min(Double(MixMoveBuilder.riserMaximumBars), landing)
            if bars >= Double(MixMoveBuilder.riserMinimumBars) { riser = landing - bars }
        }
        return (phases, riser)
    }

    // MARK: - Why

    static func why(for plan: PhantomDJEngine.Plan) -> String? {
        var parts: [String] = plan.entryNote.map { [$0] } ?? []
        if let harmonic = plan.rationale?.contributions.first(where: { $0.termId == .harmonic })?.explanation
            ?? plan.rationale?.concerns.first(where: { $0.termId == .harmonic })?.explanation,
           let note = harmonic.split(separator: ",", maxSplits: 1).last {
            let trimmed = note.trimmingCharacters(in: .whitespaces)
            if trimmed.count <= 24 { parts.append(trimmed.prefix(1).uppercased() + trimmed.dropFirst()) }
        }
        if let from = plan.outgoingBeatGrid?.bpm, let to = plan.incomingBeatGrid?.bpm, from > 0, to > 0 {
            let a = Int(from.rounded()), b = Int(to.rounded())
            parts.append(a == b ? "\(a) BPM" : "\(a) → \(b) BPM")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Director feed

extension DJSessionDirector {
    func autoMixLiveState(now: Date = Date()) -> AutoMixLiveState? {
        guard host.djSessionEnabled, host.isAutoMixEnabled, host.isMixEngineLive else { return nil }
        guard let plan = upcomingMovePlan else { return nil }
        let engine = MixEngine.shared
        let outgoingDeck = host.liveDeck
        let incomingDeck = outgoingDeck.other
        let outgoing = engine[outgoingDeck]
        let grid = plan.outgoingBeatGrid ?? engine.beatGrid(for: outgoingDeck)
        let barSeconds = grid?.barDuration ?? 2
        let rate = max(0.25, outgoing.rate)
        let window = host.mixWindow
        let mixing = isCrossfading && window != nil
        let startSeconds = window?.start ?? plan.mixPointSeconds
        let startsAt = now.addingTimeInterval((startSeconds - outgoing.position) / rate)
        let move = plan.move
        let lengthBars = move.map { max(1, $0.totalBars) } ?? max(1, Int((plan.transitionSeconds / max(0.1, barSeconds)).rounded()))
        let swapBar = move == nil ? plan.bassSwapAtSeconds / max(0.1, barSeconds) : nil
        let shape = AutoMixLive.phases(for: move, lengthBars: lengthBars, bassSwapBar: swapBar)
        let incomingTrack = host.upcomingMixTrack.flatMap { $0.id == plan.incomingTrackId || plan.incomingTrackId == nil ? $0 : nil }
        let title = plan.incomingTitle ?? incomingTrack?.title ?? "the next track"
        let name = move?.displayName ?? (plan.templateId == DJTemplates.cutOnTheOne ? "Cut" : "Blend")
        let isJump = move?.kind == .jump

        func deck(_ which: MixEngine.Deck, title: String) -> AutoMixLiveState.Deck {
            let state = engine[which]
            let grid = engine.beatGrid(for: which)
            return AutoMixLiveState.Deck(
                trackId: state.trackId,
                title: title,
                positionSeconds: state.position,
                durationSeconds: state.duration,
                rate: state.rate,
                isPlaying: state.isPlaying,
                beatSeconds: grid?.beatPeriod,
                downbeatSeconds: grid?.firstDownbeat,
                lowDb: state.low, midDb: state.mid, highDb: state.high,
                lowPassHz: state.filterCutoff, highPassHz: state.highPassCutoff,
                gain: state.gain,
                loopStartSeconds: state.loopStartSeconds,
                loopLengthSeconds: state.loopLengthSeconds
            )
        }

        let currentTitle = host.currentTrack?.title ?? "Now playing"
        return AutoMixLiveState(
            stage: mixing ? .mixing : .upcoming,
            moveKind: move?.kind.rawValue ?? (plan.templateId == DJTemplates.cutOnTheOne ? "cut" : "blend"),
            moveName: name,
            headline: plan.moveHeadline ?? "\(name) into \(title)",
            incomingTitle: isJump ? currentTitle : title,
            incomingArtist: isJump ? host.currentTrack?.user.displayName : incomingTrack?.user.displayName,
            incomingTrackId: isJump ? host.currentTrack?.id : (plan.incomingTrackId ?? incomingTrack?.id),
            why: AutoMixLive.why(for: plan),
            startsAt: startsAt,
            barSeconds: barSeconds / rate,
            landingBar: move?.landingBar ?? 0,
            lengthBars: lengthBars,
            phases: shape.phases,
            riserStartBar: shape.riserStart,
            crossfade: outgoingDeck == .a ? engine.crossfade : 1 - engine.crossfade,
            outgoing: mixing ? deck(outgoingDeck, title: currentTitle) : nil,
            incoming: mixing ? deck(incomingDeck, title: isJump ? currentTitle : title) : nil,
            anchoredAt: now,
            isPlaying: outgoing.isPlaying,
            canMixNow: canStartMix,
            canExtend: canExtendMix,
            outgoingTitle: currentTitle,
            yourMove: SettingsStore.shared.djMoveStyle.isYourMove(AutoMixMove.of(templateId: plan.templateId, move: move)) ? true : nil
        )
    }
}

#if DEBUG
// MARK: - Fixtures

extension AutoMixLive {
    func startFixture(_ name: String) {
        isFixture = true
        fixtureTask?.cancel()
        let now = Date()
        state = Self.fixture(name, now: now)
    }

    static func fixture(_ name: String, now: Date = Date()) -> AutoMixLiveState? {
        let bar = 60.0 / 124 * 4
        func make(_ move: MixMove, title: String, artist: String, barInMove: Double, stage: AutoMixLiveState.Stage, why: String) -> AutoMixLiveState {
            let shape = phases(for: move, lengthBars: move.totalBars, bassSwapBar: nil)
            let startsAt = now.addingTimeInterval(-barInMove * bar)
            let loop = shape.phases.last { barInMove >= $0.startBar && $0.name.hasPrefix("Loop") }
            let progress = barInMove / Double(max(1, move.totalBars))
            let outPosition = 301.4 + barInMove * bar
            let loopStart = loop.map { 301.4 + $0.startBar * bar }
            let swapped = progress > 0.55
            var outgoing = AutoMixLiveState.Deck(
                trackId: "fixture.out", title: "Midnight Drive", positionSeconds: loop == nil ? outPosition : (loopStart ?? outPosition) + 0.4,
                durationSeconds: 372, rate: 1, isPlaying: true, beatSeconds: 60.0 / 124, downbeatSeconds: 0.12,
                lowDb: swapped ? -26 : 0, midDb: 0, highDb: 0, gain: 1,
                loopStartSeconds: loopStart, loopLengthSeconds: loop.map { $0.bars * bar }
            )
            var incoming = AutoMixLiveState.Deck(
                trackId: "fixture.in", title: title, positionSeconds: 12 + max(0, barInMove - Double(move.landingBar)) * bar,
                durationSeconds: 341, rate: 124.0 / 126, isPlaying: barInMove >= Double(move.landingBar) || move.hasOverlap,
                beatSeconds: 60.0 / 126, downbeatSeconds: 0.05,
                lowDb: swapped ? 0 : -26, midDb: progress < 0.3 ? -8 : 0, highDb: 0, gain: 1
            )
            switch move.kind {
            case .loopRoll:
                outgoing.highPassHz = 30 + 1_370 * min(1, progress * 1.2)
                incoming.gain = barInMove >= Double(move.landingBar) ? 1 : 0
                incoming.isPlaying = barInMove >= Double(move.landingBar)
            case .dropIn:
                outgoing.highPassHz = 30 + 190 * min(1, progress * 1.4)
                outgoing.lowDb = barInMove >= Double(move.landingBar) ? -26 : 0
                incoming.lowDb = barInMove >= Double(move.landingBar) ? 0 : -26
            default:
                break
            }
            let extras = ProcessInfo.processInfo.environment["SOUNDING_TV_AUTOMIX_FIXTURE_EXTRAS"] == "1"
            return AutoMixLiveState(
                stage: stage,
                moveKind: move.kind.rawValue,
                moveName: move.displayName,
                headline: move.headline(into: title),
                incomingTitle: title,
                incomingArtist: artist,
                incomingTrackId: "fixture.in",
                why: why,
                startsAt: startsAt,
                barSeconds: bar,
                landingBar: move.landingBar,
                lengthBars: move.totalBars,
                phases: shape.phases,
                riserStartBar: shape.riserStart,
                crossfade: move.kind == .loopRoll ? (barInMove >= Double(move.landingBar) ? 1 : 0) : min(1, progress * 1.1),
                outgoing: stage == .upcoming ? nil : outgoing,
                incoming: stage == .upcoming ? nil : incoming,
                anchoredAt: now,
                isPlaying: ProcessInfo.processInfo.environment["SOUNDING_TV_AUTOMIX_FIXTURE_LIVE"] == "1",
                recap: stage == .finished ? "\(move.displayName) into \(title)" : nil,
                canMixNow: stage == .upcoming,
                canExtend: stage == .upcoming,
                outgoingTitle: "Midnight Drive",
                rating: extras && stage == .finished ? AutoMixLiveState.Rating(score: 0.9, label: "Smooth") : nil,
                moveCue: extras && stage == .upcoming ? AutoMixLiveState.MoveCue(title: "Loop roll", startsAt: now.addingTimeInterval(8 * bar), symbolName: "repeat") : nil,
                yourMove: ProcessInfo.processInfo.environment["SOUNDING_TV_AUTOMIX_YOUR_MOVE"] == "1" && stage == .upcoming ? true : nil
            )
        }
        let loop = MixMove.loopRoll(MixMove.standardLadder)
        switch name {
        case "upcoming":
            return make(loop, title: "Harbour Lights", artist: "Low Sun", barInMove: -16, stage: .upcoming, why: "Same key · 124 → 126 BPM")
        case "loop":
            return make(loop, title: "Harbour Lights", artist: "Low Sun", barInMove: 9.3, stage: .mixing, why: "Same key · 124 → 126 BPM")
        case "blend":
            return make(.blend(bars: 16, swapAt: 8), title: "Lanterns", artist: "Maya Sol", barInMove: 8.4, stage: .mixing, why: "Relative minor · 124 BPM")
        case "riser", "dropin":
            return make(.dropIn(buildBars: 8, outBars: 2), title: "Copperline", artist: "Glass District", barInMove: 6.2, stage: .mixing, why: "One step round the wheel · 124 → 122 BPM")
        case "loopmix-upcoming":
            return make(.loopMix(outLoop: 4, inLoop: 4, fadeIn: 8, fadeOut: 4), title: "Harbour Lights", artist: "Low Sun", barInMove: -6, stage: .upcoming, why: "Same key · 124 → 126 BPM")
        case "loopmix":
            return make(.loopMix(outLoop: 4, inLoop: 4, fadeIn: 8, fadeOut: 4), title: "Harbour Lights", artist: "Low Sun", barInMove: 5.2, stage: .mixing, why: "Same key · 124 → 126 BPM")
        case "loopmix-out":
            return make(.loopMix(outLoop: 4, inLoop: 4, fadeIn: 8, fadeOut: 4), title: "Harbour Lights", artist: "Low Sun", barInMove: 9.6, stage: .mixing, why: "Same key · 124 → 126 BPM")
        case "finished":
            return make(loop, title: "Harbour Lights", artist: "Low Sun", barInMove: 18, stage: .finished, why: "Same key · 124 → 126 BPM")
        default:
            return nil
        }
    }
}
#endif
