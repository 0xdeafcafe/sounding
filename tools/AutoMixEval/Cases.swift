import Foundation

typealias Plan = PhantomDJEngine.Plan

struct Mods {
    var noPhaseLock = false
    var killBassSwap = false
    var incomingGain = 1.0
}

struct EvalCase {
    var outgoing: String
    var incoming: String
    var plan: Plan
    var source: String
    var intended: String
    var fault: String?
    var faultDetail: String?
    var mods = Mods()
    var plannerScore: Double?
    var plannerFires: Bool?

    var move: String {
        if let move = plan.move { return move.kind.rawValue }
        return plan.templateId?.rawValue ?? "blend"
    }

    var key: String {
        String(format: "%@>%@|%@|%.2f|%.2f|%.2f|%@|%@", outgoing, incoming, move, plan.mixPointSeconds, plan.entrySeconds, plan.transitionSeconds, fault ?? "-", faultDetail ?? "-")
    }
}

struct Track {
    var id: String
    var url: URL
    var audio: (left: [Float], right: [Float])
    var result: BeatTrackerResult
    var features: TrackFeatures
    var mono: [Float]
}

func nearestIndex(_ xs: [Double], _ t: Double) -> Int {
    var best = 0
    var d = Double.infinity
    for (k, x) in xs.enumerated() where abs(x - t) < d { d = abs(x - t); best = k }
    return best
}

func barAt(_ track: Track, _ seconds: Double) -> Int { nearestIndex(track.result.downbeats, seconds) }

func downbeat(_ track: Track, _ bar: Int) -> Double {
    let d = track.result.downbeats
    return d[max(0, min(d.count - 1, bar))]
}

func phraseBars(_ track: Track) -> [Int] {
    track.result.phraseStarts.map { barAt(track, $0) }
}

func blend(_ o: Track, _ i: Track, mix: Double, entry: Double, bars: Int, rate: Double, template: TransitionTemplateID = DJTemplates.bassSwapBlend, stages: [TransitionStage] = [], swapAt: Double? = nil) -> Plan {
    let bar = o.features.beatGrid?.barDuration ?? 2
    let window = Double(bars) * bar
    return Plan(
        mixPointSeconds: mix, transitionSeconds: window, outroShape: .unknown, accent: nil, reasoning: "eval",
        entrySeconds: entry, bassSwapAtSeconds: swapAt.map { $0 * window }, incomingRateRatio: rate, incomingTrackId: i.id,
        templateId: template, stages: stages, outgoingBeatGrid: o.features.beatGrid, incomingBeatGrid: i.features.beatGrid
    )
}

func cut(_ o: Track, _ i: Track, mix: Double, entry: Double, rate: Double) -> Plan {
    let stages = [
        TransitionStage(at: 0, on: .outgoing, .hardCut(fadeSeconds: 0.01), snap: .free),
        TransitionStage(at: 0, on: .incoming, .crossfadeTo(position: 1, over: 0.01), snap: .free)
    ]
    return Plan(
        mixPointSeconds: mix, transitionSeconds: 0.15, outroShape: .hardStop, accent: nil, reasoning: "eval",
        entrySeconds: entry, incomingRateRatio: rate, incomingTrackId: i.id, templateId: DJTemplates.cutOnTheOne,
        stages: stages, outgoingBeatGrid: o.features.beatGrid, incomingBeatGrid: i.features.beatGrid
    )
}

func plannerTop(_ o: Track, _ i: Track, earliestExit: Double) -> Plan? {
    DJSessionDirector.decidePlan(outgoing: o.features, candidates: [i.features], profile: .automaticDJ, history: .empty, userTransitionSeconds: nil, earliestExit: earliestExit)
}

func plannerRanked(_ o: Track, _ i: Track, earliestExit: Double) -> [(Plan, Bool, Double)] {
    let ov = o.features.planningView(earliestExit: earliestExit, playable: 0...o.features.duration)
    let iv = i.features.entryView(playable: 0...i.features.duration)
    let inputs = PhantomDJEngine.PlanningInputs(outgoing: ov, candidates: [iv], profile: .automaticDJ, seedComponents: ["eval", o.id, i.id])
    let (_, result) = PhantomDJEngine.plan(inputs)
    return result.ranked.map { (Plan($0, outroShape: .unknown).withBeatGrids(outgoing: ov.beatGrid, incoming: iv.beatGrid), $0.fires, $0.score) }
}

func quietestBodyPhrase(_ t: Track) -> Int? {
    guard let level = t.result.bars?.level else { return nil }
    let n = level.count
    let candidates = phraseBars(t).filter { $0 > n / 4 && $0 < n * 3 / 4 && $0 + 4 < n }
    return candidates.min { level[$0..<($0 + 4)].reduce(0, +) < level[$1..<($1 + 4)].reduce(0, +) }
}

func loudestBodyBar(_ t: Track) -> Int? {
    let runs = DJMoveRails.payoffRuns(t.features)
    if let run = runs.max(by: { $0.count < $1.count }) { return max(run.lowerBound, run.upperBound - 6) }
    guard let level = t.result.bars?.level else { return nil }
    return level.indices.dropFirst(level.count / 4).max { level[$0] < level[$1] }
}

func buildPool(_ tracks: [String: Track], ids: [String]) -> [EvalCase] {
    var pool: [EvalCase] = []
    var seen = Set<String>()
    func add(_ c: EvalCase) {
        guard c.plan.mixPointSeconds > 22, c.plan.entrySeconds >= 0, seen.insert(c.key).inserted else { return }
        pool.append(c)
    }
    var pairIndex = 0
    for a in ids {
        for b in ids where a != b {
            guard let o = tracks[a], let i = tracks[b] else { continue }
            defer { pairIndex += 1 }
            let d = o.features.duration
            guard let top = plannerTop(o, i, earliestExit: 0) else { print("NOPLAN \(a)->\(b)"); continue }
            let rate = top.incomingRateRatio
            add(EvalCase(outgoing: a, incoming: b, plan: top, source: "planner-top", intended: "good"))
            for fraction in [0.3, 0.5] {
                if let mid = plannerTop(o, i, earliestExit: d * fraction) {
                    add(EvalCase(outgoing: a, incoming: b, plan: mid, source: "planner-top-midtrack", intended: "good"))
                }
            }
            var templates = Set<String>([top.templateId?.rawValue ?? ""])
            for (plan, fires, score) in plannerRanked(o, i, earliestExit: 0) {
                let t = plan.templateId?.rawValue ?? ""
                guard templates.insert(t).inserted else { continue }
                add(EvalCase(outgoing: a, incoming: b, plan: plan, source: "planner-alternative", intended: fires ? "good" : "borderline", plannerScore: score, plannerFires: fires))
                if templates.count >= 4 { break }
            }
            let phrases = phraseBars(o)
            let topBar = barAt(o, top.mixPointSeconds)
            let phraseBlendBar = phrases.filter { $0 < topBar - 16 && $0 > phrases.count / 3 }.last
            let isCut = top.templateId == DJTemplates.cutOnTheOne
            let blendBar = isCut ? (phrases.min { abs($0 - (topBar - 16)) < abs($1 - (topBar - 16)) } ?? topBar - 16) : topBar
            let goodMix = isCut ? downbeat(o, blendBar) : top.mixPointSeconds
            if top.move != nil || isCut {
                add(EvalCase(outgoing: a, incoming: b, plan: blend(o, i, mix: goodMix, entry: top.entrySeconds, bars: 16, rate: rate), source: "forced-blend", intended: "good"))
            }
            add(EvalCase(outgoing: a, incoming: b, plan: blend(o, i, mix: goodMix, entry: top.entrySeconds, bars: 8, rate: rate), source: "forced-blend-8", intended: "good"))
            if isCut || top.move != nil {
                let longBar = phrases.min { abs($0 - (topBar - 32)) < abs($1 - (topBar - 32)) } ?? topBar - 32
                add(EvalCase(outgoing: a, incoming: b, plan: blend(o, i, mix: downbeat(o, longBar), entry: top.entrySeconds, bars: 32, rate: rate), source: "forced-blend-32", intended: "good"))
            }
            let window16 = 16 * (o.features.beatGrid?.barDuration ?? 2)
            let filterOut = Plan(mixPointSeconds: goodMix, transitionSeconds: window16, outroShape: .unknown, accent: .outgoingFilterClose, reasoning: "eval", entrySeconds: top.entrySeconds, incomingRateRatio: rate, incomingTrackId: b, templateId: DJTemplates.filterFadeOut, outgoingBeatGrid: o.features.beatGrid, incomingBeatGrid: i.features.beatGrid)
            add(EvalCase(outgoing: a, incoming: b, plan: filterOut, source: "forced-filter-fade", intended: "good"))
            let filterIn = Plan(mixPointSeconds: goodMix, transitionSeconds: window16, outroShape: .unknown, accent: .incomingFilterOpen, reasoning: "eval", entrySeconds: top.entrySeconds, incomingRateRatio: rate, incomingTrackId: b, templateId: DJTemplates.filterBloomIn, outgoingBeatGrid: o.features.beatGrid, incomingBeatGrid: i.features.beatGrid)
            add(EvalCase(outgoing: a, incoming: b, plan: filterIn, source: "forced-filter-bloom", intended: "good"))
            let barSeconds = o.features.beatGrid?.barDuration ?? 2
            let echoMix = isCut ? top.mixPointSeconds - barSeconds : downbeat(o, barAt(o, top.mixPointSeconds + top.transitionSeconds) - 1)
            let echoStages = [
                TransitionStage(at: 0, on: .outgoing, .delayWet(mix: 0.45, feedback: 0.55, over: barSeconds * 0.5), snap: .free),
                TransitionStage(at: barSeconds, on: .outgoing, .echoCut(feedback: 0.6, release: barSeconds * 4), snap: .free),
                TransitionStage(at: barSeconds, on: .incoming, .crossfadeTo(position: 1, over: 0.01), snap: .free)
            ]
            let echo = Plan(mixPointSeconds: echoMix, transitionSeconds: barSeconds * 2, outroShape: .unknown, accent: nil, reasoning: "eval", entrySeconds: max(0, top.entrySeconds - barSeconds * rate), incomingRateRatio: rate, incomingTrackId: b, templateId: DJTemplates.echoOut, stages: echoStages, outgoingBeatGrid: o.features.beatGrid, incomingBeatGrid: i.features.beatGrid)
            add(EvalCase(outgoing: a, incoming: b, plan: echo, source: "forced-echo-out", intended: "good"))
            if !isCut, let bar = phrases.min(by: { abs(downbeat(o, $0) - top.mixPointSeconds - top.transitionSeconds) < abs(downbeat(o, $1) - top.mixPointSeconds - top.transitionSeconds) }) {
                add(EvalCase(outgoing: a, incoming: b, plan: cut(o, i, mix: downbeat(o, bar), entry: top.entrySeconds, rate: rate), source: "forced-cut", intended: "good"))
            }

            let base = blend(o, i, mix: goodMix, entry: top.entrySeconds, bars: 16, rate: rate)

            let runs = DJMoveRails.payoffRuns(o.features)
            if !runs.isEmpty {
                let run = runs[pairIndex % runs.count]
                let start = max(8, run.lowerBound - 6)
                add(EvalCase(outgoing: a, incoming: b, plan: blend(o, i, mix: downbeat(o, start), entry: top.entrySeconds, bars: 16, rate: rate), source: "injected", intended: "bad", fault: "mix_across_drop", faultDetail: "16-bar blend starting 6 bars before an outgoing drop at bar \(run.lowerBound)"))
            }

            let outVocals = o.features.vocalRanges.filter { $0.upperBound - $0.lowerBound > 10 && $0.lowerBound > 30 && $0.upperBound < d - 30 }
            let inVocals = i.features.vocalRanges.filter { $0.upperBound - $0.lowerBound > 8 && $0.lowerBound > 10 }
            if !outVocals.isEmpty, let loud = loudestBodyBar(i) {
                for (n, ov) in outVocals.enumerated() where n % 3 == pairIndex % 3 {
                    add(EvalCase(outgoing: a, incoming: b, plan: blend(o, i, mix: downbeat(o, barAt(o, ov.lowerBound)), entry: downbeat(i, max(0, loud - 8)), bars: 16, rate: rate), source: "injected", intended: "bad", fault: "blend_over_vocals", faultDetail: String(format: "16-bar blend over the outgoing vocal from %.0f s into a dense incoming section", ov.lowerBound)))
                }
            }
            if !inVocals.isEmpty, let loud = loudestBodyBar(o) {
                for (n, iv) in inVocals.enumerated() where n % 3 == pairIndex % 3 {
                    add(EvalCase(outgoing: a, incoming: b, plan: blend(o, i, mix: downbeat(o, max(8, loud - 8)), entry: downbeat(i, max(0, barAt(i, iv.lowerBound) - 2)), bars: 16, rate: rate), source: "injected", intended: "bad", fault: "blend_over_vocals", faultDetail: String(format: "16-bar blend from a dense outgoing section into the incoming vocal at %.0f s", iv.lowerBound)))
                }
            }

            if top.entrySeconds > 6 || i.features.contentStart > 3 {
                add(EvalCase(outgoing: a, incoming: b, plan: blend(o, i, mix: top.mixPointSeconds, entry: 0, bars: 8, rate: rate), source: "injected", intended: "bad", fault: "enter_silence_or_beatless_intro", faultDetail: String(format: "incoming starts at 0 s; planner entry was %.1f s", top.entrySeconds)))
            }

            var bass = EvalCase(outgoing: a, incoming: b, plan: base, source: "injected", intended: "bad", fault: "double_bass_no_swap", faultDetail: "both low EQs open for the whole 16-bar blend")
            bass.mods.killBassSwap = true
            add(bass)

            let offsets = [0.030, -0.040, 0.050, -0.060, 0.035, -0.045, 0.055, -0.030, 0.040, -0.050, 0.045, -0.035]
            let delta = offsets[pairIndex % offsets.count]
            var phase = EvalCase(outgoing: a, incoming: b, plan: base.entering(at: top.entrySeconds - delta * rate), source: "injected", intended: "bad", fault: "phase_misalignment", faultDetail: String(format: "incoming %+.0f ms off the grid, phase lock off", delta * 1000))
            phase.mods.noPhaseLock = true
            add(phase)

            if let loud = loudestBodyBar(o), let quiet = quietestBodyPhrase(i) {
                add(EvalCase(outgoing: a, incoming: b, plan: blend(o, i, mix: downbeat(o, loud), entry: downbeat(i, quiet), bars: 2, rate: rate), source: "injected", intended: "bad", fault: "energy_cliff", faultDetail: "2-bar blend from the outgoing peak into the quietest incoming phrase"))
            }

            if let level = o.result.bars?.level {
                let body = phrases.filter { $0 > level.count / 3 && $0 < level.count * 2 / 3 }
                let bar = (body.isEmpty ? level.count / 2 : body[pairIndex % body.count]) + 3
                let beat = (o.features.beatGrid?.beatPeriod ?? 0.5)
                let entryBar = barAt(i, i.features.duration * 0.4) + 5
                let ib = (i.features.beatGrid?.beatPeriod ?? 0.5)
                add(EvalCase(outgoing: a, incoming: b, plan: cut(o, i, mix: downbeat(o, bar) + 2.5 * beat, entry: downbeat(i, entryBar) + 1.5 * ib, rate: rate), source: "injected", intended: "bad", fault: "hard_cut_mid_phrase", faultDetail: "cut 2.5 beats into bar 4 of a phrase, into the incoming mid-bar"))
            }

            let gain = pairIndex % 2 == 0 ? 2.8 : 0.25
            var jump = EvalCase(outgoing: a, incoming: b, plan: base, source: "injected", intended: "bad", fault: "level_jump", faultDetail: String(format: "incoming deck gain %+.0f dB", 20 * log10(gain)))
            jump.mods.incomingGain = gain
            add(jump)

            let mildDelta = [0.014, -0.016, 0.018, -0.012][pairIndex % 4]
            var mildPhase = EvalCase(outgoing: a, incoming: b, plan: base.entering(at: top.entrySeconds - mildDelta * rate), source: "injected-mild", intended: "borderline", fault: "phase_misalignment_mild", faultDetail: String(format: "incoming %+.0f ms off the grid, phase lock off", mildDelta * 1000))
            mildPhase.mods.noPhaseLock = true
            add(mildPhase)
            var mildGain = EvalCase(outgoing: a, incoming: b, plan: base, source: "injected-mild", intended: "borderline", fault: "level_jump_mild", faultDetail: pairIndex % 2 == 0 ? "incoming deck gain +4 dB" : "incoming deck gain -4 dB")
            mildGain.mods.incomingGain = pairIndex % 2 == 0 ? 1.58 : 0.63
            add(mildGain)
            add(EvalCase(outgoing: a, incoming: b, plan: blend(o, i, mix: top.mixPointSeconds, entry: top.entrySeconds, bars: 16, rate: rate, swapAt: 0.85), source: "injected-mild", intended: "borderline", fault: "late_bass_swap", faultDetail: "bass swap at 85% of the blend"))
            if let bar = phraseBlendBar {
                add(EvalCase(outgoing: a, incoming: b, plan: cut(o, i, mix: downbeat(o, bar + 4), entry: top.entrySeconds, rate: rate), source: "injected-mild", intended: "borderline", fault: "cut_mid_phrase_on_downbeat", faultDetail: "cut on a downbeat, 4 bars into a phrase"))
            }
        }
    }
    return pool
}
