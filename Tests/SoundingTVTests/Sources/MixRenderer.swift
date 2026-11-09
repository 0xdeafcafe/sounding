#if DEBUG
import Foundation
import AVFoundation
@testable import SoundingTV

@MainActor
final class MixRenderer {

    enum AnalysisMode {
        case measured
        case gridOnly
        case bpmOnly
        case legacy(TrackAnalysis)
        case tracked(BeatTrackerResult, legacy: TrackAnalysis?)
        case none
    }

    enum Event {
        case pause(atTransitionFraction: Double, seconds: TimeInterval)
        case seek(atTransitionFraction: Double, bySeconds: TimeInterval)
    }

    struct Scenario {
        let name: String
        let outgoing: MixFixture
        let incoming: MixFixture
        var outgoingAnalysis: AnalysisMode = .measured
        var incomingAnalysis: AnalysisMode = .measured
        var profile: DJProfile = .automaticDJ
        var template: TransitionTemplateID?
        var outgoingCues: [CuePoint] = []
        var incomingCues: [CuePoint] = []
        var events: [Event] = []
        var userTransitionSeconds: Double? = 8
        var preRoll: TimeInterval = 16
        var postRoll: TimeInterval = 30
        var outgoingPrep: TrackPrep?
        var incomingPrep: TrackPrep?
        var outgoingBoundaries: [TimeInterval] = []
        var customPlan: (@MainActor (TrackFeatures, TrackFeatures) -> PhantomDJEngine.Plan?)?
        var riserLevel: Double = 0
        var loopsOnDeadline = true
        var preLoop: (start: TimeInterval, length: TimeInterval, playFrom: TimeInterval)?
        var rendersStems = true
        var beginAfterSeconds: TimeInterval = 0
    }

    struct LogEntry {
        let time: TimeInterval
        let positionA: TimeInterval
        let positionB: TimeInterval
        let rateA: Double
        let rateB: Double
        let crossfade: Double
        let master: Double
        let playingA: Bool
        let playingB: Bool
        var lowA = 0.0
        var lowB = 0.0
        var highPassA = 30.0
        var highPassB = 30.0
    }

    struct EventRecord {
        let label: String
        let time: TimeInterval
    }

    struct Pass {
        var left: [Float] = []
        var right: [Float] = []
        var log: [LogEntry] = []
        var events: [EventRecord] = []
        var beginTime: TimeInterval?
        var leadSeconds: TimeInterval = 0
        var finishTime: TimeInterval?
        var startSourceA: TimeInterval = 0
        var timeline: MixTimeline?
        var incomingRate: Double = 1
        var gainA: Double = 1
        var gainB: Double = 1
        var renderNanos: UInt64 = 0
        var renderedFrames: Int64 = 0
        var maxQuantumNanos: UInt64 = 0
        var quanta: Int64 = 0
        var splicesA = 0
        var splicesB = 0
        var lockCorrections = 0
        var missedAnchors = 0
        var beatOffsetMaxMs = 0.0
        var beatOffsetMeanMs = 0.0
        var deadlineLoopStart: TimeInterval?
        var deadlineLoopLength: TimeInterval?
        var stopTimeA: TimeInterval?
    }

    struct Result {
        let scenario: Scenario
        let plan: PhantomDJEngine.Plan
        let outgoingFeatures: TrackFeatures
        let incomingFeatures: TrackFeatures
        let mix: Pass
        let stemA: [Float]
        let stemB: [Float]
        var stemRiser: [Float] = []
        let sampleRate: Double
        let entrySeconds: TimeInterval
    }

    static let sampleRate = DJEngineConstants.canonicalSampleRate
    static let chunkFrames: AVAudioFrameCount = 512

    func render(_ scenario: Scenario) throws -> Result {
        let outgoingTrack = Self.track(for: scenario.outgoing)
        let incomingTrack = Self.track(for: scenario.incoming)
        let outgoingFeatures = Self.features(
            track: outgoingTrack, fixture: scenario.outgoing, mode: scenario.outgoingAnalysis, cues: scenario.outgoingCues,
            prep: scenario.outgoingPrep, boundaries: scenario.outgoingBoundaries
        )
        let incomingFeatures = Self.features(
            track: incomingTrack, fixture: scenario.incoming, mode: scenario.incomingAnalysis, cues: scenario.incomingCues,
            prep: scenario.incomingPrep
        )
        guard let plan = Self.plan(scenario: scenario, outgoing: outgoingFeatures, incoming: incomingFeatures) else {
            throw MixEngineError.decodeFailed("planner produced no plan for \(scenario.name)")
        }
        let entry = PlaybackTimelinePolicy.transitionStartPosition(
            plan.entrySeconds,
            duration: scenario.incoming.spec.duration,
            transitionSeconds: max(0.15, plan.transitionSeconds)
        )

        let mix = try renderPass(scenario, plan: plan, entry: entry, solo: nil, logging: true)
        let a = scenario.rendersStems ? try renderPass(scenario, plan: plan, entry: entry, solo: .a, logging: false) : Pass()
        let b = scenario.rendersStems ? try renderPass(scenario, plan: plan, entry: entry, solo: .b, logging: false) : Pass()
        let riser = scenario.rendersStems && scenario.riserLevel > 0 ? try renderPass(scenario, plan: plan, entry: entry, solo: nil, riserOnly: true, logging: false) : nil
        func mono(_ pass: Pass) -> [Float] {
            var out = [Float](repeating: 0, count: pass.left.count)
            for i in out.indices { out[i] = (pass.left[i] + pass.right[i]) * 0.5 }
            return out
        }
        return Result(
            scenario: scenario,
            plan: plan,
            outgoingFeatures: outgoingFeatures,
            incomingFeatures: incomingFeatures,
            mix: mix,
            stemA: mono(a),
            stemB: mono(b),
            stemRiser: riser.map(mono) ?? [],
            sampleRate: Self.sampleRate,
            entrySeconds: entry
        )
    }

    static func plan(scenario: Scenario, outgoing: TrackFeatures, incoming: TrackFeatures) -> PhantomDJEngine.Plan? {
        if let custom = scenario.customPlan {
            return custom(outgoing, incoming)
        }
        if let template = scenario.template {
            let inputs = PhantomDJEngine.PlanningInputs(
                outgoing: outgoing,
                candidates: [incoming],
                profile: scenario.profile,
                seedComponents: [scenario.profile.id.rawValue, outgoing.trackId, "1"],
                userTransitionSeconds: scenario.userTransitionSeconds
            )
            let result = PhantomDJEngine.rank(inputs)
            guard let scored = result.ranked.first(where: { $0.plan.templateId == template }) else { return nil }
            return PhantomDJEngine.Plan(scored, outroShape: PhantomDJEngine.outroShape(for: scored.plan.exit.kind))
                .withBeatGrids(outgoing: outgoing.beatGrid, incoming: incoming.beatGrid)
        }
        if !(ProcessInfo.processInfo.environment["AUTOMIX_PLAN_DEBUG"] ?? "").isEmpty {
            let inputs = PhantomDJEngine.PlanningInputs(
                outgoing: outgoing,
                candidates: [incoming],
                profile: scenario.profile,
                seedComponents: [scenario.profile.id.rawValue, outgoing.trackId, "1"],
                userTransitionSeconds: scenario.userTransitionSeconds
            )
            let result = PhantomDJEngine.rank(inputs)
            let bar = outgoing.beatGrid?.barDuration ?? 2
            func bars(_ s: TimeInterval) -> String { String(format: "%.1f", s / bar) }
            print("PLANDEBUG \(scenario.name) vocals \(outgoing.vocalRanges.map { "\(bars($0.lowerBound))-\(bars($0.upperBound))" }) sections \(outgoing.sections.map { "\($0.kind.rawValue)@\(bars($0.start))-\(bars($0.end))" }) duration \(bars(outgoing.duration))")
            print("PLANDEBUG \(scenario.name) incoming vocals \(incoming.vocalRanges.map { "\(bars($0.lowerBound))-\(bars($0.upperBound))" }) measured \(outgoing.provenance.contains(.measuredVocals))/\(incoming.provenance.contains(.measuredVocals))")
            for scored in result.ranked.filter({ $0.plan.move == nil }).prefix(16) + result.ranked.filter({ $0.plan.move != nil }).prefix(8) {
                print("PLANDEBUG \(scenario.name) \(scored.plan.templateId.rawValue) exit \(bars(scored.plan.exit.seconds)) \(scored.plan.exit.kind.rawValue) overlap \(bars(scored.plan.overlapSeconds)) score \(String(format: "%.2f", scored.score)) \(scored.rationale.headline) entry \(scored.plan.entry.kind.rawValue)@\(String(format: "%.1f", scored.plan.entry.seconds)) terms \(scored.rationale.contributions.map { "\($0.termId.rawValue)=\(String(format: "%.3f", $0.weightedCost))" }.joined(separator: ","))")
            }
        }
        return DJSessionDirector.decidePlan(
            outgoing: outgoing,
            candidates: [incoming],
            profile: scenario.profile,
            history: .empty,
            userTransitionSeconds: scenario.userTransitionSeconds
        )
    }

    private func renderPass(
        _ scenario: Scenario,
        plan: PhantomDJEngine.Plan,
        entry: TimeInterval,
        solo: MixEngine.Deck?,
        riserOnly: Bool = false,
        logging: Bool
    ) throws -> Pass {
        let engine = MixEngine(offline: true)
        defer { engine.stop() }
        engine.offlineSoloDeck = solo
        if riserOnly { engine.offlineSoloRiser = true }
        try engine.loadForOfflineRendering(fileURL: scenario.outgoing.url, into: .a, trackId: scenario.outgoing.spec.id)
        try engine.loadForOfflineRendering(fileURL: scenario.incoming.url, into: .b, trackId: scenario.incoming.spec.id)

        let gainA = LoudnessNormalization.attenuation(measuredLUFS: Float(scenario.outgoing.integratedLUFS))
        let gainB = LoudnessNormalization.attenuation(measuredLUFS: Float(scenario.incoming.integratedLUFS))

        engine.cancelAllRamps()
        engine.masterVolume = 1
        engine.crossfade = 0
        engine.setGain(1, on: .a)
        engine.setGain(gainA, on: .a)
        engine.resetEQ(on: .a)
        engine.openFilter(on: .a)
        engine.setRate(1, on: .a)
        engine.setPitch(0, on: .a)

        engine.resetProcessing(on: .b, killLows: true)
        engine.setGain(gainB, on: .b)
        engine.seek(deck: .b, to: entry)
        engine.setBeatGrid(plan.outgoingBeatGrid, for: .a)
        engine.setBeatGrid(plan.incomingBeatGrid, for: .b)

        var pass = Pass()
        pass.gainA = gainA
        pass.gainB = gainB
        pass.startSourceA = scenario.preLoop?.playFrom ?? max(0, plan.mixPointSeconds - scenario.preRoll)
        engine.seek(deck: .a, to: pass.startSourceA)
        if let loop = scenario.preLoop {
            engine.setLoop(on: .a, startSeconds: loop.start, lengthSeconds: loop.length)
        }
        engine.play(deck: .a)

        let performer = MixTransitionPerformer(engine: engine)
        let actions = MixActionGroup()
        var outputTime: TimeInterval = 0
        var started = false
        var finished = false
        var pendingEvents = scenario.events
        var resumeAt: TimeInterval?
        let window = max(0.15, plan.transitionSeconds)
        let maxSeconds = scenario.preRoll + window + scenario.postRoll + 60
        let chunkSeconds = Double(Self.chunkFrames) / Self.sampleRate

        while outputTime < maxSeconds {
            if !started, outputTime >= scenario.beginAfterSeconds, engine.livePosition(of: .a) >= max(0, plan.mixPointSeconds - 0.8) {
                started = true
                pass.beginTime = outputTime
                let request = MixTransitionPerformer.Request(
                    outgoing: .a,
                    incoming: .b,
                    window: window,
                    entrySeconds: entry,
                    plan: plan,
                    filterAccent: plan.accent,
                    announceAsMix: true,
                    startAtPlannedBoundary: true,
                    outgoingGridFallback: engine.beatGrid(for: .a),
                    rateBudgetPercent: scenario.profile.maxAbsRatePercent,
                    legacyTempoMatch: nil,
                    resetsIncoming: true,
                    startsPaused: false,
                    riserLevel: scenario.riserLevel,
                    loopsOnDeadline: scenario.loopsOnDeadline
                )
                let outcome = performer.begin(request, actions: actions) {
                    performer.finish(outgoing: .a, incoming: .b)
                    actions.cancel()
                    finished = true
                    pass.finishTime = outputTime
                }
                switch outcome {
                case .started(let lead, _): pass.leadSeconds = lead
                case .failed(let reason): throw MixEngineError.playbackStartFailed(reason)
                }
                pass.timeline = actions.timeline
                pass.incomingRate = engine[.b].rate
                pass.deadlineLoopStart = engine[.a].loopStartSeconds
                pass.deadlineLoopLength = engine[.a].loopLengthSeconds
            }

            if let begin = pass.beginTime, let event = pendingEvents.first {
                switch event {
                case .pause(let fraction, let seconds):
                    if outputTime >= begin + pass.leadSeconds + fraction * window {
                        pendingEvents.removeFirst()
                        performer.pause(live: .a, isCrossfading: !finished)
                        pass.events.append(EventRecord(label: "pause", time: outputTime))
                        resumeAt = outputTime + seconds
                    }
                case .seek(let fraction, let delta):
                    if outputTime >= begin + pass.leadSeconds + fraction * window {
                        pendingEvents.removeFirst()
                        performer.seek(
                            live: .a,
                            to: engine.livePosition(of: .a) + delta,
                            transition: finished ? nil : actions
                        )
                        pass.events.append(EventRecord(label: "seek", time: outputTime))
                    }
                }
            }
            if let resume = resumeAt, outputTime >= resume {
                resumeAt = nil
                performer.resume(live: finished ? .b : .a, isCrossfading: !finished)
                pass.events.append(EventRecord(label: "resume", time: outputTime))
            }

            try engine.renderOffline(frames: Self.chunkFrames) { buffer in
                guard let channels = buffer.floatChannelData else { return }
                let count = Int(buffer.frameLength)
                pass.left.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: count))
                pass.right.append(contentsOf: UnsafeBufferPointer(start: channels[1], count: count))
            }
            outputTime += chunkSeconds

            if logging {
                let core = engine.coreSnapshot
                pass.log.append(LogEntry(
                    time: outputTime,
                    positionA: engine.livePosition(of: .a),
                    positionB: engine.livePosition(of: .b),
                    rateA: engine[.a].rate,
                    rateB: engine[.b].rate,
                    crossfade: engine.crossfade,
                    master: engine.masterVolume,
                    playingA: engine[.a].isPlaying,
                    playingB: engine[.b].isPlaying,
                    lowA: core.a.low,
                    lowB: core.b.low,
                    highPassA: core.a.highPass,
                    highPassB: core.b.highPass
                ))
            }

            if started, pass.stopTimeA == nil, !engine[.a].isPlaying { pass.stopTimeA = outputTime }
            if let finish = pass.finishTime, outputTime >= finish + scenario.postRoll { break }
        }
        let snapshot = engine.coreSnapshot
        pass.renderNanos = snapshot.renderNanos
        pass.renderedFrames = snapshot.renderedFrames
        pass.maxQuantumNanos = snapshot.maxQuantumNanos
        pass.quanta = snapshot.quanta
        pass.splicesA = snapshot.a.splices
        pass.splicesB = snapshot.b.splices
        pass.lockCorrections = snapshot.b.lockCorrections
        pass.missedAnchors = snapshot.missedAnchors
        pass.beatOffsetMaxMs = snapshot.b.beatOffsetMax / Self.sampleRate * 1000
        pass.beatOffsetMeanMs = snapshot.b.beatOffsetCount > 0 ? snapshot.b.beatOffsetSum / Double(snapshot.b.beatOffsetCount) / Self.sampleRate * 1000 : 0
        return pass
    }

    // MARK: - Timeline replay

    static func replay(
        _ result: Result,
        blockSize: Int,
        seconds: TimeInterval
    ) throws -> (left: [Float], right: [Float]) {
        let scenario = result.scenario
        let plan = result.plan
        let pass = result.mix
        guard let timeline = pass.timeline else { throw MixEngineError.deckEmpty }
        let sr = sampleRate
        let core = MixRenderCore(sampleRate: sr)
        let sourceA = try MixSource(url: scenario.outgoing.url, synchronous: true)
        let sourceB = try MixSource(url: scenario.incoming.url, synchronous: true)
        let tableA = plan.outgoingBeatGrid.flatMap { MixBeatTable(grid: $0, sampleRate: sr) }
        let tableB = plan.incomingBeatGrid.flatMap { MixBeatTable(grid: $0, sampleRate: sr) }
        var sequence: Int64 = 0
        func push(_ command: MixCommand) { _ = core.ring.push(command) }
        func now(_ action: MixTimelineAction) {
            sequence += 1
            push(.event(seq: sequence, time: 0, immediate: true, group: 0, action: action))
        }
        sequence += 1
        push(.load(seq: sequence, deck: 0, source: Unmanaged.passUnretained(sourceA)))
        push(.load(seq: sequence, deck: 1, source: Unmanaged.passUnretained(sourceB)))
        push(.beats(seq: sequence, deck: 0, table: tableA.map { Unmanaged.passUnretained($0) }))
        push(.beats(seq: sequence, deck: 1, table: tableB.map { Unmanaged.passUnretained($0) }))
        now(.ramp(.gain(0), to: pass.gainA, frames: 0, curve: .linear))
        now(.ramp(.gain(1), to: pass.gainB, frames: 0, curve: .linear))
        now(.ramp(.eqLow(1), to: MixEngine.bassKillDecibels, frames: 0, curve: .linear))
        if plan.accent == .incomingFilterOpen {
            now(.ramp(.lowPass(1), to: DJEngineConstants.accentClosedFilterHz, frames: 0, curve: .logarithmic))
        }
        now(.ramp(.rate(1), to: pass.incomingRate, frames: 0, curve: .linear))
        now(.seek(deck: 0, frame: pass.startSourceA * sr))
        now(.start(deck: 0, fromFrame: nil))
        now(.seek(deck: 1, frame: result.entrySeconds * sr))
        for event in timeline.events {
            sequence += 1
            push(.event(seq: sequence, time: event.offset, immediate: false, group: 7, action: event.action))
        }
        sequence += 1
        push(.anchor(seq: sequence, group: 7, anchor: timeline.anchor))

        let total = Int(seconds * sr)
        var left = [Float](repeating: 0, count: total)
        var right = [Float](repeating: 0, count: total)
        var offset = 0
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                while offset < total {
                    let count = min(blockSize, total - offset)
                    core.render(frames: count, left: l.baseAddress! + offset, right: r.baseAddress! + offset)
                    offset += count
                }
            }
        }
        withExtendedLifetime((sourceA, sourceB, tableA, tableB)) {}
        return (left, right)
    }

    // MARK: - Inputs

    static func track(for fixture: MixFixture) -> Track {
        let numericId = Int(MixFixtureFactory.stableHash(fixture.spec.id) % 1_000_000_000)
        let json = """
        {
            "id": \(numericId),
            "title": "\(fixture.spec.id)",
            "description": null,
            "artwork_url": null,
            "waveform_url": null,
            "permalink_url": "https://soundcloud.com/fixture/\(numericId)",
            "playback_count": 0,
            "likes_count": 0,
            "reposts_count": 0,
            "created_at": "2024-09-01T12:00:00Z",
            "genre": "House",
            "user": {
                "id": 1,
                "username": "fixture",
                "permalink": "fixture",
                "permalink_url": "https://soundcloud.com/fixture"
            },
            "media": {
                "transcodings": [
                    {
                        "url": "https://api-v2.soundcloud.com/media/fixture/\(numericId)/stream",
                        "duration": \(Int(fixture.spec.duration * 1000)),
                        "quality": "hq",
                        "format": { "protocol": "progressive", "mime_type": "audio/mp4" },
                        "preset": "aac_256k"
                    }
                ]
            }
        }
        """
        let decoder = JSONDecoder()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        decoder.dateDecodingStrategy = .formatted(formatter)
        return try! decoder.decode(Track.self, from: Data(json.utf8))
    }

    static func features(
        track: Track,
        fixture: MixFixture,
        mode: AnalysisMode,
        cues: [CuePoint],
        prep: TrackPrep? = nil,
        boundaries: [TimeInterval] = []
    ) -> TrackFeatures {
        let bucketCount = max(8, Int((track.duration / DJEngineConstants.bucketSeconds).rounded()))
        let envelope = Waveform(samples: fixture.waveform).resampled(to: bucketCount)
        let truth = fixture.truth
        var cached: DJSessionDirector.CachedMusicUnderstanding?
        var legacy: TrackAnalysis?
        var tracked: BeatTrackerResult?
        switch mode {
        case .measured:
            var phrases: [TimeInterval] = []
            var index = 0
            while index < truth.downbeats.count {
                phrases.append(truth.downbeats[index])
                index += 8
            }
            var structure: [ClosedRange<TimeInterval>] = []
            for (i, start) in phrases.enumerated() {
                let end = i + 1 < phrases.count ? phrases[i + 1] : fixture.spec.duration
                if end > start { structure.append(start...end) }
            }
            cached = DJSessionDirector.CachedMusicUnderstanding(
                features: AnalysisFeatures(bpm: fixture.spec.meanBPM, key: fixture.spec.camelot),
                beatSeconds: truth.beats,
                barSeconds: truth.downbeats,
                structureRanges: structure,
                phraseBoundaries: phrases,
                keyRegions: [KeyRegion(key: fixture.spec.camelot, start: 0, end: fixture.spec.duration)],
                vocalRanges: truth.vocalRanges,
                bassRanges: truth.bassRanges,
                integratedLUFS: Float(fixture.integratedLUFS)
            )
        case .gridOnly:
            cached = DJSessionDirector.CachedMusicUnderstanding(
                features: AnalysisFeatures(bpm: fixture.spec.meanBPM, key: fixture.spec.camelot),
                beatSeconds: truth.beats,
                barSeconds: truth.downbeats,
                structureRanges: [],
                phraseBoundaries: [],
                keyRegions: [KeyRegion(key: fixture.spec.camelot, start: 0, end: fixture.spec.duration)],
                vocalRanges: truth.vocalRanges,
                bassRanges: truth.bassRanges,
                integratedLUFS: Float(fixture.integratedLUFS)
            )
        case .bpmOnly:
            cached = DJSessionDirector.CachedMusicUnderstanding(
                features: AnalysisFeatures(bpm: fixture.spec.meanBPM, key: fixture.spec.camelot),
                beatSeconds: [],
                barSeconds: [],
                structureRanges: [],
                phraseBoundaries: [],
                keyRegions: [],
                vocalRanges: nil,
                bassRanges: nil,
                integratedLUFS: Float(fixture.integratedLUFS)
            )
        case .legacy(let analysis):
            legacy = analysis
        case .tracked(let result, let analysis):
            tracked = result
            legacy = analysis
        case .none:
            break
        }
        return DJSessionDirector.assembleFeatures(
            for: track,
            envelope: envelope,
            cachedAnalysis: cached,
            legacyAnalysis: legacy,
            userCues: cues,
            prep: prep,
            boundaries: boundaries,
            trackedBeats: tracked
        )
    }
}
#endif
