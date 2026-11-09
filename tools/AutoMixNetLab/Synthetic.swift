import AVFoundation
import Foundation

struct LabTrack {
    var id: String
    var url: URL
    var result: BeatTrackerResult
    var grid: BeatGrid
    var duration: Double
    var levels: [Float]
    var bars: [[Double]]
    var vocals: [ClosedRange<TimeInterval>]
}

struct SyntheticPair: Codable {
    var id: String
    var fault: String?
    var good: Bool
    var rating: Double
    var estimated: AutoMixNetObservation
    var measured: AutoMixNetObservation
}

enum Fault: String, CaseIterable {
    case phase, tempo, doubleBass, slam, cut, vocal
}

func loadTrack(_ id: String, audio: URL, analysis: URL) throws -> LabTrack {
    let result = try JSONDecoder().decode(BeatTrackerResult.self, from: Data(contentsOf: analysis.appendingPathComponent("analysis-\(id)-bands.json")))
    let url = audio.appendingPathComponent("\(id).wav")
    let file = try AVAudioFile(forReading: url)
    let duration = Double(file.length) / file.processingFormat.sampleRate
    return LabTrack(
        id: id, url: url, result: result, grid: result.beatGrid()!, duration: duration,
        levels: result.bars?.level ?? [], bars: AutoMixNetFeatures.barBands(result.bars), vocals: result.vocalSeconds ?? []
    )
}

func renderTransition(out a: LabTrack, in b: LabTrack, input: MixTransitionTimelineInput, killIncomingBass: Bool, lead: Double, tail: Double) throws -> (left: [Float], right: [Float]) {
    let sr = input.sampleRate
    let core = MixRenderCore(sampleRate: sr)
    let sa = try MixSource(url: a.url, synchronous: true)
    let sb = try MixSource(url: b.url, synchronous: true)
    var seq: Int64 = 0
    func push(_ make: (Int64) -> MixCommand) { seq += 1; _ = core.ring.push(make(seq)) }
    push { .load(seq: $0, deck: 0, source: Unmanaged.passUnretained(sa)) }
    push { .load(seq: $0, deck: 1, source: Unmanaged.passUnretained(sb)) }
    var tables: [MixBeatTable] = []
    for (deck, grid) in [(0, input.outgoingGrid), (1, input.incomingGrid)] {
        if let grid, let table = MixBeatTable(grid: grid, sampleRate: sr) {
            tables.append(table)
            push { .beats(seq: $0, deck: deck, table: Unmanaged.passUnretained(table)) }
        }
    }
    func now(_ action: MixTimelineAction) { push { .event(seq: $0, time: 0, immediate: true, group: 0, action: action) } }
    now(.ramp(.crossfade, to: 0, frames: 0, curve: .linear))
    if killIncomingBass { now(.ramp(.eqLow(1), to: MixEngine.bassKillDecibels, frames: 0, curve: .linear)) }
    now(.ramp(.rate(1), to: input.incomingRate, frames: 0, curve: .linear))
    now(.start(deck: 0, fromFrame: max(0, input.anchorSourceSeconds - lead) * sr))
    let timeline = MixTimeline.transition(input)
    for event in timeline.events { push { .event(seq: $0, time: event.offset, immediate: false, group: 7, action: event.action) } }
    push { .anchor(seq: $0, group: 7, anchor: timeline.anchor) }
    let total = Int((lead + Double(timeline.lengthFrames) / sr + tail) * sr)
    var left = [Float](repeating: 0, count: total), right = left
    let block = 512
    let l = UnsafeMutablePointer<Float>.allocate(capacity: block), r = UnsafeMutablePointer<Float>.allocate(capacity: block)
    defer { l.deallocate(); r.deallocate() }
    var done = 0
    while done < total {
        let n = min(block, total - done)
        core.render(frames: n, left: l, right: r)
        for k in 0..<n { left[done + k] = l[k]; right[done + k] = r[k] }
        done += n
    }
    withExtendedLifetime((sa, sb, tables)) {}
    return (left, right)
}

func phraseBars(_ t: LabTrack, in range: ClosedRange<Double>, minimumLevel: Float = -20) -> [Int] {
    let downbeats = t.result.downbeats
    let offset = t.result.phraseOffsetBars
    return downbeats.indices.filter { i in
        let f = downbeats[i] / t.duration
        return range.contains(f) && (i - offset) % 8 == 0 && i < t.levels.count && t.levels[i] > minimumLevel
    }
}

func spread(_ bars: [Int], _ n: Int) -> [Int] {
    guard bars.count > n else { return bars }
    return (0..<n).map { bars[$0 * (bars.count - 1) / max(1, n - 1)] }
}

func makeSamples(tracks: [LabTrack], limit: Int?) throws -> [SyntheticPair] {
    let sr = 44_100.0
    var out: [SyntheticPair] = []
    var faultCursor = 0
    let faults: [Fault] = [.phase, .tempo, .doubleBass, .slam, .cut]
    let blends = [16, 8, 32, 16]
    for a in tracks {
        for b in tracks where a.id != b.id || !a.vocals.isEmpty {
            let exits = spread(phraseBars(a, in: 0.45...0.85), 3)
            let entries = spread(phraseBars(b, in: 0.0...0.3, minimumLevel: -40), 3)
            for (ei, exitBar) in exits.enumerated() {
                for (ni, entryBar) in entries.enumerated() {
                    let blend = blends[(ei + ni) % blends.count]
                    let variants: [Fault?] = a.id == b.id ? [nil, .vocal] : [nil, faults[faultCursor % faults.count]]
                    faultCursor += 1
                    for fault in variants {
                        if let limit, out.count >= limit { return out }
                        if let s = try sample(a, b, exitBar: exitBar, entryBar: entryBar, blend: blend, fault: fault, sr: sr) { out.append(s) }
                    }
                }
            }
        }
    }
    return out
}

func sample(_ a: LabTrack, _ b: LabTrack, exitBar requestedExit: Int, entryBar requestedEntry: Int, blend requestedBlend: Int, fault: Fault?, sr: Double) throws -> SyntheticPair? {
    var exitBar = requestedExit, entryBar = requestedEntry, blend = requestedBlend
    var rate = a.grid.bpm / max(1, b.grid.bpm)
    var killBass = true
    var swapFraction = 0.5
    var outGrid: BeatGrid? = a.grid, inGrid: BeatGrid? = b.grid
    var entryShiftBeats = 0.0
    var templateId: TransitionTemplateID = "longBlend"
    switch fault {
    case .phase?:
        entryShiftBeats = 0.3 + 0.2 * Double((requestedExit + requestedEntry) % 3) / 2
        inGrid = BeatGrid(anchor: b.grid.anchor, beatPeriod: b.grid.beatPeriod, confidence: b.grid.confidence)
        outGrid = BeatGrid(anchor: a.grid.anchor, beatPeriod: a.grid.beatPeriod, confidence: a.grid.confidence)
    case .tempo?:
        rate *= abs(rate - 1) < 0.015 ? 1.03 : 1 / rate
    case .doubleBass?:
        killBass = false
        swapFraction = 1
    case .slam?:
        blend = 2
        if let loud = b.levels.indices.filter({ $0 > 16 && $0 < b.levels.count - 40 && ($0 - b.result.phraseOffsetBars) % 8 == 0 }).max(by: { b.levels[$0] < b.levels[$1] }) { entryBar = loud }
    case .cut?:
        blend = 0
        templateId = "cut"
        exitBar += 3
        entryShiftBeats = 0
        if let loud = b.levels.indices.filter({ $0 > 16 && $0 < b.levels.count - 40 }).max(by: { b.levels[$0] < b.levels[$1] }) { entryBar = loud + 2 }
    case .vocal?:
        let inVocal = a.result.downbeats.indices.filter { i in
            i < a.levels.count - 40 && (i - a.result.phraseOffsetBars) % 8 == 0 && a.vocals.contains { $0.contains(a.result.downbeats[i]) && $0.upperBound - a.result.downbeats[i] > 30 }
        }
        guard inVocal.count >= 2 else { return nil }
        exitBar = inVocal[(requestedExit / 8) % inVocal.count]
        entryBar = inVocal[(requestedEntry / 8 + inVocal.count / 2) % inVocal.count]
        if abs(entryBar - exitBar) < 16 { entryBar = inVocal[(inVocal.firstIndex(of: entryBar)! + 3) % inVocal.count] }
    case nil:
        break
    }
    let downA = a.result.downbeats, downB = b.result.downbeats
    guard exitBar < downA.count, entryBar < downB.count else { return nil }
    let exit = downA[exitBar]
    let entry = downB[entryBar] + entryShiftBeats * b.grid.beatPeriod
    let window = blend == 0 ? 0.15 : Double(blend) * a.grid.barDuration
    guard exit + window + 10 < a.duration, entry + window * rate + 10 < b.duration else { return nil }
    let stages = blend == 0 ? [TransitionStage(at: 0, on: .incoming, .crossfadeTo(position: 1, over: 0.1))] : [TransitionStage(at: 0, on: .incoming, .crossfadeTo(position: 1, over: window))]
    let input = MixTransitionTimelineInput(
        outgoing: 0, incoming: 1, sampleRate: sr, anchorSourceSeconds: exit, window: max(0.15, window), entrySeconds: entry,
        outgoingRate: 1, incomingRate: rate, outgoingGrid: outGrid, incomingGrid: inGrid, stages: stages,
        bassSwapAtSeconds: window * swapFraction, bassSwapSeconds: 0.4, filterAccent: nil, defersIncomingStart: false,
        phaseLock: (outGrid?.isPhaseVerified ?? false) && (inGrid?.isPhaseVerified ?? false), move: nil, riserGain: 0, incomingMidCutDecibels: 0
    )
    let lead = 10.0, tail = 10.0
    let audio = try renderTransition(out: a, in: b, input: input, killIncomingBass: killBass, lead: lead, tail: tail)
    let measuredBands = AutoMixNetFeatures.measuredBands(left: audio.left, right: audio.right, sampleRate: sr, exitSeconds: lead, windowSeconds: max(0.15, window))
    let estimatedBands = AutoMixNetFeatures.estimatedBands(
        outgoingBars: a.bars, exitBar: exitBar, incomingBars: b.bars, entryBar: entryBar, blendBars: blend,
        bassSwapFraction: killBass ? swapFraction : 0, bassSwapBars: killBass ? 0.25 : Double(max(1, blend))
    )
    let vocal = DJMixRules.vocalOverlapSeconds(outgoing: a.vocals, from: exit, length: window, incoming: b.vocals, entry: entry)
    let phase = max(
        AutoMixNetFeatures.phaseErrorBeats(exit, downbeats: downA, beatPeriod: a.grid.beatPeriod) ?? 0,
        AutoMixNetFeatures.phaseErrorBeats(entry, downbeats: downB, beatPeriod: b.grid.beatPeriod) ?? 0
    )
    let peak = [AutoMixNetFeatures.peakProximity(levels: a.levels, from: exitBar), AutoMixNetFeatures.peakProximity(levels: b.levels, from: entryBar)].compactMap { $0 }.min()
    func section(_ t: LabTrack, _ bar: Int) -> String {
        guard bar < t.levels.count else { return "unknown" }
        let level = t.levels[bar]
        let previous = t.levels[max(0, bar - 8)..<bar].reduce(0, +) / Float(max(1, min(8, bar)))
        if Double(bar) < Double(t.levels.count) * 0.12 { return "intro" }
        if Double(bar) > Double(t.levels.count) * 0.88 { return "outro" }
        if level < -14 { return "breakdown" }
        if level - previous > 4 { return "drop" }
        return "unknown"
    }
    let base = AutoMixNetObservation(
        moveType: blend == 0 ? "cut" : "blend",
        blendBars: Double(blend),
        energyStep: AutoMixNetFeatures.energyStep(outgoingLevels: a.levels, exitBar: exitBar, incomingLevels: b.levels, entryBar: entryBar, blendBars: blend),
        vocalOverlapSeconds: vocal,
        phaseErrorBeats: phase,
        gridConfidence: min(a.result.beatConfidence, b.result.beatConfidence),
        keyDistance: nil,
        bpmDeltaPercent: AutoMixNetFeatures.residualTempoPercent(outgoingBPM: a.grid.bpm, incomingBPM: b.grid.bpm, rate: rate),
        exitSection: section(a, exitBar),
        entrySection: section(b, entryBar),
        peakProximityBars: peak
    )
    var estimated = base
    estimated.bands = estimatedBands
    var measured = base
    measured.bands = measuredBands
    var fault = fault
    if fault == nil, vocal > DJMixRules.keyClashOverlapBars * a.grid.barDuration { fault = .vocal }
    let rating: Double
    switch fault {
    case nil: rating = blend >= 16 && abs(base.energyStep ?? 0) < 3 ? 5 : 4
    case .tempo?, .doubleBass?: rating = 2
    default: rating = 1
    }
    let id = "\(a.id)-\(exitBar)-into-\(b.id)-\(entryBar)-\(blend)-\(fault?.rawValue ?? "good")"
    print(String(format: "SAMPLE|%@|jump %.1f flux %.2f lowOverlap %.2f phase %.2f tempo %.2f vocal %.1f", id,
                 measuredBands?.maxLevelJumpDecibels ?? -1, measuredBands?.spectralFlux ?? -1, measuredBands?.lowOverlap ?? -1, phase, base.bpmDeltaPercent ?? -1, vocal))
    return SyntheticPair(id: id, fault: fault?.rawValue, good: fault == nil, rating: rating, estimated: estimated, measured: measured)
}
