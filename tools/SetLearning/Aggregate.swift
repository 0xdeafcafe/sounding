import Foundation

struct SetLearningAggregate {
    var reports: [SetLearningReport]
    var transitions: [(report: SetLearningReport, t: SetLearningTransition)]

    init(reports: [SetLearningReport]) {
        self.reports = reports
        transitions = reports.flatMap { r in r.transitions.filter { Self.kept($0, in: r) }.map { (r, $0) } }
    }

    static func kept(_ t: SetLearningTransition, in r: SetLearningReport) -> Bool {
        guard t.blendStartSeconds >= 60, t.blendEndSeconds <= r.analysedSeconds - 60 else { return false }
        return t.confidence >= 0.2 || t.detection == "tracklist"
    }

    static func distribution(_ values: [Double], bucket: ((Double) -> String)? = nil) -> LearnedSetPriors.Distribution {
        let s = values.filter(\.isFinite).sorted()
        func p(_ q: Double) -> Double { s.isEmpty ? 0 : SetLearning.round1(s[min(s.count - 1, Int(Double(s.count - 1) * q))]) }
        var buckets: [String: Double] = [:]
        if let bucket { for v in s { buckets[bucket(v), default: 0] += 1 } }
        return .init(p10: p(0.1), p25: p(0.25), p50: p(0.5), p75: p(0.75), p90: p(0.9), buckets: buckets.mapValues { SetLearning.round3($0 / Double(max(1, s.count))) })
    }

    static func shares(_ values: [String]) -> [String: Double] {
        var c: [String: Double] = [:]
        for v in values { c[v, default: 0] += 1 }
        return c.mapValues { SetLearning.round3($0 / Double(max(1, values.count))) }
    }

    static func genreFamily(_ raw: String?, bpm: Double?) -> String {
        let g = (raw ?? "").lowercased()
        if g.contains("hard") || g.contains("gabber") || g.contains("rave") { return "hard / rave" }
        if g.contains("techno") { return "techno" }
        if g.contains("trance") { return "trance" }
        if g.contains("disco") || g.contains("funk") { return "disco" }
        if g.contains("house") || g.contains("deep") { return "house" }
        if g.contains("edm") || g.contains("bounce") || g.contains("dance") { return "edm" }
        guard let bpm, bpm > 0 else { return "unknown" }
        if bpm < 126 { return "house (by tempo)" }
        if bpm < 150 { return "techno (by tempo)" }
        return "hard / rave (by tempo)"
    }

    static func family(_ r: SetLearningReport) -> String { genreFamily(r.source.genre, bpm: r.bpmMedian) }

    static func tempoBand(_ bpm: Double?) -> String {
        guard let bpm, bpm > 0 else { return "unknown" }
        if bpm < 120 { return "<120" }
        if bpm < 124 { return "120-124" }
        if bpm < 128 { return "124-128" }
        if bpm < 132 { return "128-132" }
        return "132+"
    }

    var priors: LearnedSetPriors {
        let ts = transitions.map(\.t)
        let blends = ts.map { Double($0.blendBars) }
        let bucket: (Double) -> String = { "\(LearnedSetPriors.bucket($0))" }
        var byGenre: [String: [Double]] = [:]
        var byTempo: [String: [Double]] = [:]
        for (r, t) in transitions {
            byGenre[Self.family(r), default: []].append(Double(t.blendBars))
            byTempo[Self.tempoBand(t.bpmOut), default: []].append(Double(t.blendBars))
        }
        let swaps = ts.filter { $0.bassSwapBar != nil && $0.blendBars > 0 }
        let spacing = reports.flatMap { r in zip(r.transitions, r.transitions.dropFirst()).map { $1.boundarySeconds - $0.boundarySeconds } }
        return LearnedSetPriors(
            version: 1, sets: reports.count, transitions: ts.count,
            moveGroups: Self.shares(ts.map { AutoMixNetFeatures.moveGroup($0.move) }),
            moves: Self.shares(ts.map(\.move)),
            blendBars: Self.distribution(blends, bucket: bucket),
            blendBarsByGenre: byGenre.mapValues { Self.distribution($0, bucket: bucket) },
            blendBarsByTempo: byTempo.mapValues { Self.distribution($0, bucket: bucket) },
            bassSwapMethods: Self.shares(ts.map(\.bassSwapMethod)),
            bassSwapFractionOfBlend: Self.distribution(swaps.map { $0.bassSwapBar! / Double($0.blendBars) }),
            bassSwapPhrasePosition: Self.shares(swaps.compactMap { $0.bassSwapPhrasePosition.map { "\($0)" } }),
            doubleBassShare: SetLearning.round3(Double(ts.filter { $0.doubleBassBars >= 2 }.count) / Double(max(1, ts.count))),
            filterShare: Self.shares(ts.map(\.filter)),
            loopShare: SetLearning.round3(Double(ts.filter { $0.loopBars >= 8 }.count) / Double(max(1, ts.count))),
            phraseStartShare: SetLearning.round3(Double(ts.filter { $0.startPhrasePosition == 0 }.count) / Double(max(1, ts.count))),
            phraseGridsAlignedShare: SetLearning.round3(Double(ts.filter(\.phraseGridsAligned).count) / Double(max(1, ts.count))),
            exitSections: Self.shares(ts.map { AutoMixNetFeatures.sectionGroup($0.exitSection) }),
            entrySections: Self.shares(ts.map { AutoMixNetFeatures.sectionGroup($0.entrySection) }),
            energyStepDecibels: Self.distribution(ts.compactMap(\.energyStepDecibels)),
            keyDistance: Self.shares(ts.compactMap { $0.keyDistance.map { "\($0)" } }),
            tempoRampShare: SetLearning.round3(Double(ts.filter(\.tempoRamp).count) / Double(max(1, ts.count))),
            spacingSeconds: Self.distribution(spacing)
        )
    }

    var markdown: String {
        let p = priors
        func pct(_ x: Double) -> String { String(format: "%.0f %%", x * 100) }
        func table(_ d: [String: Double]) -> String {
            d.sorted { $0.value > $1.value }.map { "| \($0.key) | \(pct($0.value)) |" }.joined(separator: "\n")
        }
        func dist(_ d: LearnedSetPriors.Distribution) -> String {
            "p10 \(d.p10), p25 \(d.p25), median \(d.p50), p75 \(d.p75), p90 \(d.p90)"
        }
        var lines: [String] = []
        lines.append("## Sets")
        lines.append("")
        lines.append("| set | origin | genre | minutes | transitions | detection | median BPM | BPM drift | median spacing |")
        lines.append("|---|---|---|---|---|---|---|---|---|")
        for r in reports {
            let detection = r.source.cues.count >= 2 ? "tracklist" : "audio"
            lines.append("| \(r.source.artist.isEmpty ? "" : r.source.artist + " – ")\(r.source.title) | \(r.source.origin.hasPrefix("local") ? "local" : (r.source.origin.hasPrefix("download") ? "SoundCloud download" : "SoundCloud stream")) | \(Self.family(r)) | \(Int(r.analysedSeconds / 60)) | \(r.transitions.count) | \(detection) | \(r.bpmMedian ?? 0) | \(r.bpmDriftPercent ?? 0) % | \(Int(r.spacingSecondsMedian ?? 0)) s |")
        }
        lines.append("")
        lines.append("Transitions kept for statistics (confidence ≥ 0.2 or tracklist-anchored): \(p.transitions).")
        lines.append("")
        lines.append("## Blend length (bars)")
        lines.append("")
        lines.append("All: \(dist(p.blendBars)).")
        lines.append("")
        lines.append("| bucket | share |")
        lines.append("|---|---|")
        lines.append(table(p.blendBars.buckets))
        lines.append("")
        lines.append("| genre | n | median | p25–p75 |")
        lines.append("|---|---|---|---|")
        for (g, d) in p.blendBarsByGenre.sorted(by: { $0.key < $1.key }) {
            let n = transitions.filter { Self.family($0.report) == g }.count
            lines.append("| \(g) | \(n) | \(d.p50) | \(d.p25)–\(d.p75) |")
        }
        lines.append("")
        lines.append("| tempo | n | median | p25–p75 |")
        lines.append("|---|---|---|---|")
        for (g, d) in p.blendBarsByTempo.sorted(by: { $0.key < $1.key }) {
            let n = transitions.filter { Self.tempoBand($0.t.bpmOut) == g }.count
            lines.append("| \(g) | \(n) | \(d.p50) | \(d.p25)–\(d.p75) |")
        }
        lines.append("")
        lines.append("## Moves")
        lines.append("")
        lines.append("| move | share |")
        lines.append("|---|---|")
        lines.append(table(p.moves))
        lines.append("")
        lines.append("## Bass handover")
        lines.append("")
        lines.append("| method | share |")
        lines.append("|---|---|")
        lines.append(table(p.bassSwapMethods))
        lines.append("")
        lines.append("Swap point as a fraction of the blend: \(dist(p.bassSwapFractionOfBlend)). Double bass (2+ bars): \(pct(p.doubleBassShare)).")
        lines.append("")
        lines.append("| swap bar mod 8 (incoming phrase) | share |")
        lines.append("|---|---|")
        lines.append(table(p.bassSwapPhrasePosition))
        lines.append("")
        lines.append("## Filters, loops, phrasing, tempo")
        lines.append("")
        lines.append("| filter | share |")
        lines.append("|---|---|")
        lines.append(table(p.filterShare))
        lines.append("")
        let all = transitions.map(\.t)
        let anchored = all.filter { $0.detection == "tracklist" }
        func share(_ ts: [SetLearningTransition], _ f: (SetLearningTransition) -> Bool) -> String { pct(Double(ts.filter(f).count) / Double(max(1, ts.count))) }
        lines.append("Echo outs: \(share(all) { $0.echoOut }) (tracklist-anchored \(share(anchored) { $0.echoOut })). Loops: \(share(all) { $0.loopBars >= 8 }) (tracklist-anchored \(share(anchored) { $0.loopBars >= 8 }), \(anchored.count) anchored). Cuts: \(share(all) { $0.cut }).")
        lines.append("")
        lines.append("Loop on the outgoing (8+ bars of near-identical repeats): \(pct(p.loopShare)). Blend starts on an outgoing 8-bar phrase line: \(pct(p.phraseStartShare)). Outgoing and incoming phrase grids line up: \(pct(p.phraseGridsAlignedShare)). Tempo ramps: \(pct(p.tempoRampShare)).")
        lines.append("")
        lines.append("## Sections")
        lines.append("")
        lines.append("| outgoing exits from | share |")
        lines.append("|---|---|")
        lines.append(table(p.exitSections))
        lines.append("")
        lines.append("| incoming enters as | share |")
        lines.append("|---|---|")
        lines.append(table(p.entrySections))
        lines.append("")
        lines.append("## Energy, key, spacing")
        lines.append("")
        lines.append("Energy step (dB, 8 bars after vs 8 bars before): \(dist(p.energyStepDecibels)).")
        lines.append("")
        lines.append("| Camelot distance | share |")
        lines.append("|---|---|")
        lines.append(table(p.keyDistance))
        lines.append("")
        lines.append("Transition spacing (s): \(dist(p.spacingSeconds)).")
        lines.append("")
        lines.append("## Energy arcs (dB vs set median, tenths of the set)")
        lines.append("")
        for r in reports {
            lines.append("- \(r.source.title): \(r.energyArcDecibels.map { String(format: "%+.1f", $0) }.joined(separator: " ")); BPM \(r.bpmArc.map { String(format: "%.0f", $0) }.joined(separator: " "))")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
