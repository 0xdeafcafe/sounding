import Foundation
#if os(macOS)
@testable import SoundingTV_macOS
#else
@testable import SoundingTV
#endif

struct ComparisonRunInfo: Sendable {
    var root: String
    var pairs: Int
    var unreadable: Int
    var references: Int
    var musicRoots: [String]
    var audioFilesIndexed: Int
    var byPath: Int
    var byFileName: Int
    var ambiguous: Int
    var missingAudio: Int
    var analysed: Int
    var xmlPath: String?
    var xmlMatched: Int
    var concurrency: Int
    var wallSeconds: Double
    var producers: [String]
}

enum ComparisonReport {
    static let worstCount = 15

    // MARK: - Formatting

    static func number(_ value: Double?, _ digits: Int = 1) -> String {
        guard let value, value.isFinite else { return "–" }
        return String(format: "%.\(digits)f", value)
    }

    static func signed(_ value: Double?, _ digits: Int = 0) -> String {
        guard let value, value.isFinite else { return "–" }
        return String(format: "%+.\(digits)f", value)
    }

    static func share(_ hits: Int, _ total: Int) -> String {
        guard total > 0 else { return "–" }
        return String(format: "%.1f%% (%d/%d)", 100 * Double(hits) / Double(total), hits, total)
    }

    static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }

    static func row(_ cells: [String]) -> String {
        "| " + cells.map(cell).joined(separator: " | ") + " |"
    }

    static func table(_ header: [String], _ rows: [[String]]) -> [String] {
        [row(header), "|" + header.map { _ in " --- |" }.joined()] + rows.map(row)
    }

    static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    static func trackName(_ t: TrackComparison) -> String {
        let name = t.artist.isEmpty ? t.title : "\(t.artist) – \(t.title)"
        return name.count > 70 ? String(name.prefix(69)) + "…" : name
    }

    static func keyLabel(_ key: CamelotKey?) -> String { key?.label ?? "–" }

    // MARK: - Aggregates

    static func engine(_ t: TrackComparison, _ index: Int) -> EngineComparison? {
        index < t.engines.count ? t.engines[index] : nil
    }

    static func summaryRows(_ rows: [TrackComparison], engineCount: Int) -> [[String]] {
        func engines(_ i: Int) -> [EngineComparison] { rows.compactMap { engine($0, i) } }
        var out: [[String]] = []
        func add(_ label: String, _ make: ([EngineComparison]) -> String) {
            out.append([label] + (0 ..< engineCount).map { make(engines($0)) })
        }
        func bpmShare(_ e: [EngineComparison], _ classes: Set<BPMClass>) -> String {
            let graded = e.compactMap(\.bpmClass)
            return share(graded.filter { classes.contains($0) }.count, graded.count)
        }
        add("Tracks with a tempo") { e in share(e.filter { $0.observation.bpm != nil }.count, e.count) }
        add("BPM exact (±0.05)") { bpmShare($0, [.exact]) }
        add("BPM within ±0.5") { bpmShare($0, [.exact, .close]) }
        add("BPM half-time") { bpmShare($0, [.halfTime]) }
        add("BPM double-time") { bpmShare($0, [.doubleTime]) }
        add("BPM other error") { bpmShare($0, [.other]) }
        add("BPM missing") { bpmShare($0, [.missing]) }
        add("Beat offset, median |ms| (median of tracks)") { e in number(ComparisonMetrics.median(e.compactMap { $0.beat?.medianAbsMs })) }
        add("Beat offset, p90 |ms| (median of tracks)") { e in number(ComparisonMetrics.median(e.compactMap { $0.beat?.p90AbsMs })) }
        add("Systematic offset, ms (median signed)") { e in signed(ComparisonMetrics.median(e.compactMap { $0.beat?.medianSignedMs }), 1) }
        add("Beat F-measure ±70 ms (mean)") { e in number(mean(e.compactMap { $0.beat?.fMeasure70 }), 3) }
        add("Drift start→end, |ms| (median)") { e in number(ComparisonMetrics.median(e.compactMap { $0.beat.map { abs($0.driftMs) } })) }
        add("Tracks drifting > 20 ms") { e in
            let aligned = e.compactMap(\.beat)
            return share(aligned.filter { abs($0.driftMs) > 20 }.count, aligned.count)
        }
        add("First downbeat within 70 ms") { e in
            let d = e.compactMap(\.downbeat)
            return share(d.filter(\.firstAgrees).count, d.count)
        }
        add("Bar phase agrees") { e in
            let d = e.compactMap(\.downbeat)
            return share(d.filter { $0.barPhaseShift == 0 }.count, d.count)
        }
        add("Downbeats on rekordbox's bar 1 (mean)") { e in number(mean(e.compactMap { $0.downbeat?.barPhaseAgreement }), 3) }
        add("rekordbox variable-tempo tracks") { e in "\(e.filter(\.referenceVariable).count)" }
        add("Variable tempo followed (80% of checkpoints within 1%)") { e in
            let v = e.filter(\.referenceVariable).compactMap(\.tempo)
            return share(v.filter { $0.followFraction >= 0.8 }.count, v.count)
        }
        add("Constant-tempo tracks kept constant") { e in
            let v = e.filter { !$0.referenceVariable }.compactMap(\.tempo)
            return share(v.filter { !$0.oursVariable }.count, v.count)
        }
        add("Phrase boundary F ±1 beat (mean)") { e in number(mean(e.compactMap { $0.phraseBeat?.f }), 3) }
        add("Phrase boundary F ±1 bar (mean)") { e in number(mean(e.compactMap { $0.phraseBar?.f }), 3) }
        add("Section boundary F ±1 bar (mean)") { e in number(mean(e.compactMap { $0.sectionBar?.f }), 3) }
        add("Intro length within ±1 bar") { e in
            let v = e.compactMap(\.introErrorBars)
            return share(v.filter { abs($0) <= 1 }.count, v.count)
        }
        add("Intro length within ±4 bars") { e in
            let v = e.compactMap(\.introErrorBars)
            return share(v.filter { abs($0) <= 4 }.count, v.count)
        }
        add("Outro length within ±1 bar") { e in
            let v = e.compactMap(\.outroErrorBars)
            return share(v.filter { abs($0) <= 1 }.count, v.count)
        }
        add("Outro length within ±4 bars") { e in
            let v = e.compactMap(\.outroErrorBars)
            return share(v.filter { abs($0) <= 4 }.count, v.count)
        }
        if rows.contains(where: { $0.referenceKey != nil }) {
            for keyClass in KeyClass.allCases {
                add("Key \(keyClass.rawValue)") { e in
                    let k = e.compactMap(\.keyClass)
                    return share(k.filter { $0 == keyClass }.count, k.count)
                }
            }
        }
        add("Analysis time per track, median s") { e in number(ComparisonMetrics.median(e.map(\.observation.seconds)), 2) }
        add("Analysis time per track, p90 s") { e in number(ComparisonMetrics.percentile(e.map(\.observation.seconds), 0.9), 2) }
        add("Analysis time, total min") { e in number(e.map(\.observation.seconds).reduce(0, +) / 60, 1) }
        add("Cue suggestions per track (mean)") { e in number(mean(e.map { Double($0.observation.cueSuggestions.count) }), 2) }
        add("rekordbox cues on our phrase boundary ±1 bar (mean)") { e in number(mean(e.compactMap(\.cueOnPhrase)), 3) }
        add("rekordbox cues on our cue suggestion ±1 bar (mean)") { e in number(mean(e.compactMap(\.cueOnSuggestion)), 3) }
        return out
    }

    static func speedRows(_ rows: [TrackComparison], engineCount: Int) -> [[String]] {
        (0 ..< engineCount).map { i in
            let e = rows.compactMap { t in engine(t, i).map { (t, $0) } }
            let factors = e.compactMap { t, c in c.observation.seconds > 0 ? t.duration / c.observation.seconds : nil }
            return [
                e.first?.1.observation.name ?? "–",
                number(ComparisonMetrics.median(factors), 1) + "×",
                number(ComparisonMetrics.median(e.map { $0.1.observation.seconds }), 2),
                number(e.map { $0.1.observation.seconds }.max(), 2),
            ]
        }
    }

    static func groupRows(_ groups: [(String, [TrackComparison])]) -> [[String]] {
        groups.map { name, tracks in
            let e = tracks.compactMap { engine($0, 0) }
            let graded = e.filter { $0.bpmClass != nil }
            let keyed = e.compactMap(\.keyClass)
            let downbeats = e.compactMap(\.downbeat)
            return [
                name,
                "\(tracks.count)",
                share(graded.filter { $0.bpmClass == .exact }.count, graded.count),
                share(graded.filter { $0.isWithinHalfBPM }.count, graded.count),
                share(graded.filter { $0.isOctaveError }.count, graded.count),
                number(ComparisonMetrics.median(e.compactMap { $0.beat?.medianAbsMs })),
                share(downbeats.filter { $0.barPhaseShift == 0 }.count, downbeats.count),
                number(mean(e.compactMap { $0.phraseBar?.f }), 2),
                keyed.isEmpty ? "–" : share(keyed.filter { $0 == .exact }.count, keyed.count),
            ]
        }
    }

    static let groupHeader = ["Group", "Tracks", "BPM exact", "BPM ±0.5", "Octave errors", "Beat median ms", "Bar phase", "Phrase F (bar)", "Key exact"]

    static func genreGroups(_ rows: [TrackComparison]) -> [(String, [TrackComparison])] {
        var groups = Dictionary(grouping: rows) { $0.genre.isEmpty ? "Untagged" : $0.genre }
        let small = groups.filter { $0.value.count < 3 }
        for name in small.keys { groups[name] = nil }
        var ordered = groups.sorted { $0.value.count > $1.value.count || ($0.value.count == $1.value.count && $0.key < $1.key) }.map { ($0.key, $0.value) }
        let rest = small.values.flatMap { $0 }
        if !rest.isEmpty { ordered.append(("Other genres (< 3 tracks each)", rest)) }
        return ordered
    }

    static func bpmGroups(_ rows: [TrackComparison]) -> [(String, [TrackComparison])] {
        let order = ["< 100", "100–115", "115–125", "125–135", "135–150", "150+", "no grid"]
        let groups = Dictionary(grouping: rows, by: \.bpmRange)
        return order.compactMap { name in groups[name].map { (name, $0) } }
    }

    // MARK: - Likely reasons

    static func bpmReason(_ t: TrackComparison, _ e: EngineComparison) -> String {
        guard let ref = t.referenceBPM else { return "rekordbox has no grid" }
        guard let ours = e.observation.bpm else {
            return e.observation.failure.map { "no tempo: \($0)" } ?? "no reliable tempo measured"
        }
        let ratio = ours / ref
        let variable = t.reference.tempoSegments.filter { $0.beats >= 4 }.map(\.bpm)
        switch e.bpmClass ?? .missing {
        case .halfTime: return "half-time: counted every other beat"
        case .doubleTime: return "double-time: counted off-beats as beats"
        case .close:
            let msPerMinute = 60_000 * abs(ours - ref) / ref
            if t.reference.hasVariableTempo, let low = variable.min(), let high = variable.max() {
                return String(format: "rekordbox grid changes tempo (%.2f–%.2f); ours is one tempo", low, high)
            }
            return String(format: "small tempo error %+.2f BPM, grid slips ~%.0f ms per minute", ours - ref, msPerMinute)
        default:
            if abs(ratio - 1.5) < 0.03 { return "3:2 ratio: triplet or swing feel read as the beat" }
            if abs(ratio - 2.0 / 3.0) < 0.03 { return "2:3 ratio: dotted feel read as the beat" }
            if abs(ratio - 0.75) < 0.02 || abs(ratio - 4.0 / 3.0) < 0.03 { return String(format: "%.2f ratio: wrong metrical level", ratio) }
            if t.reference.hasVariableTempo, let low = variable.min(), let high = variable.max() {
                return String(format: "rekordbox follows tempo changes (%.1f–%.1f BPM)", low, high)
            }
            return String(format: "tempo mis-detected (ratio %.3f)", ratio)
        }
    }

    static func beatReason(_ t: TrackComparison, _ e: EngineComparison) -> String {
        guard let beat = e.beat else { return "no beats to compare" }
        if e.isOctaveError { return "octave error; matched on the sparser grid" }
        if !e.observation.measuredBeats { return "tempo-only grid: beats not measured, anchored at 0 s" }
        let periodMs = t.reference.medianBeatPeriod * 1000
        if abs(beat.driftMs) > max(30, beat.medianAbsMs) {
            return String(format: "grid drifts %+.0f ms from start to end (tempo off %+.3f BPM)", beat.driftMs, e.bpmError ?? 0)
        }
        if abs(beat.medianAbsMs - periodMs / 2) < periodMs * 0.15 { return "off-beat: grid sits half a beat out" }
        if abs(beat.medianSignedMs) > 0.7 * beat.medianAbsMs, beat.medianAbsMs > 15 {
            return String(format: "constant offset %+.0f ms (decoder delay or onset latency)", beat.medianSignedMs)
        }
        if t.reference.hasVariableTempo { return "rekordbox grid is variable; ours wanders around it" }
        return "beats wander (low tracking confidence)"
    }

    static func driftReason(_ t: TrackComparison, _ e: EngineComparison) -> String {
        if t.reference.hasVariableTempo { return "rekordbox grid changes tempo; ours holds one" }
        if let error = e.bpmError, abs(error) > 0.005 { return String(format: "BPM differs by %+.3f", error) }
        return "local beat placement varies"
    }

    static func downbeatReason(_ t: TrackComparison, _ e: EngineComparison) -> String {
        guard let d = e.downbeat else { return "no downbeats to compare" }
        if e.isOctaveError { return "octave error moves every bar" }
        if !e.observation.measuredDownbeats { return "bar phase guessed, no measured downbeats" }
        if let shift = d.barPhaseShift, shift != 0 {
            return "our bar 1 sits \(shift) beat\(shift == 1 ? "" : "s") before rekordbox's"
        }
        return String(format: "bar phase flips during the track (%.0f%% agree)", d.barPhaseAgreement * 100)
    }

    static func tempoReason(_ t: TrackComparison, _ e: EngineComparison) -> String {
        let variable = t.reference.tempoSegments.filter { $0.beats >= 4 }.map(\.bpm)
        let span = String(format: "%.2f–%.2f", variable.min() ?? 0, variable.max() ?? 0)
        guard let tempo = e.tempo else { return "no beats to compare" }
        if !tempo.oursVariable { return "ours holds one tempo; rekordbox moves \(span)" }
        return String(format: "follows some changes: %.0f%% of checkpoints within 1%%", tempo.followFraction * 100)
    }

    static func phraseReason(_ t: TrackComparison, _ e: EngineComparison) -> String {
        let ours = e.observation.phraseStarts.count
        let theirs = t.reference.phrases.count
        if ours == 0 { return e.observation.sections.isEmpty ? "no phrases or sections detected" : "no phrase boundaries, only sections" }
        if let shift = e.downbeat?.barPhaseShift, shift != 0 { return "bar phase off by \(shift) beat\(shift == 1 ? "" : "s") moves every boundary" }
        let ratio = Double(ours) / Double(max(1, theirs))
        if ratio > 1.5 { return "ours finer: \(ours) boundaries vs \(theirs)" }
        if ratio < 0.67 { return "ours coarser: \(ours) boundaries vs \(theirs)" }
        return "different boundary choices (\(ours) vs \(theirs))"
    }

    static func introReason(_ t: TrackComparison, _ e: EngineComparison) -> String {
        if e.observation.sections.isEmpty { return "no sections detected" }
        return "rekordbox \(number(t.referenceIntroBars, 0)) bars, ours \(number(e.oursIntroBars, 0)) bars"
    }

    static func outroReason(_ t: TrackComparison, _ e: EngineComparison) -> String {
        if e.observation.sections.isEmpty { return "no sections detected" }
        return "rekordbox \(number(t.referenceOutroBars, 0)) bars, ours \(number(e.oursOutroBars, 0)) bars"
    }

    static func keyReason(_ t: TrackComparison, _ e: EngineComparison) -> String {
        switch e.keyClass ?? .missing {
        case .relative: return "relative major/minor confusion"
        case .adjacent: return "neighbour on the wheel (fifth apart)"
        case .missing: return "no key measured"
        case .other:
            guard let ours = e.observation.key, let ref = t.referenceKey else { return "different key" }
            if ours.wheelSteps(to: ref) == 1 { return "fifth apart and mode differs" }
            if ours.wheelSteps(to: ref) == 3, ours.mode != ref.mode { return "parallel major/minor" }
            if ours.wheelSteps(to: ref) == 7 || ours.wheelSteps(to: ref) == 5 { return "a semitone apart (tuning or modulation)" }
            return "different key (\(ours.wheelSteps(to: ref)) steps)"
        default: return ""
        }
    }

    static func speedReason(_ t: TrackComparison, _ e: EngineComparison) -> String {
        let parts = e.observation.producerSeconds.sorted { $0.value > $1.value }.map { "\($0.key) " + String(format: "%.1f s", $0.value) }
        let factor = e.observation.seconds > 0 ? t.duration / e.observation.seconds : 0
        return String(format: "%.1f min track, %.0f× realtime; ", t.duration / 60, factor) + parts.joined(separator: ", ")
    }

    // MARK: - Worst lists

    static func worst(
        _ title: String,
        _ rows: [TrackComparison],
        header: [String],
        include: (TrackComparison, EngineComparison) -> Bool,
        badness: (TrackComparison, EngineComparison) -> Double,
        cells: (TrackComparison, EngineComparison) -> [String]
    ) -> [String] {
        let picked = rows.compactMap { t in engine(t, 0).map { (t, $0) } }
            .filter { include($0.0, $0.1) }
            .sorted { badness($0.0, $0.1) > badness($1.0, $1.1) }
            .prefix(worstCount)
        guard !picked.isEmpty else { return ["### \(title)", "", "Nothing to list.", ""] }
        return ["### \(title)", ""] + table(["Track"] + header + ["Likely reason"], picked.map { t, e in [trackName(t)] + cells(t, e) }) + [""]
    }

    static func worstSections(_ rows: [TrackComparison]) -> [String] {
        var out: [String] = []
        out += worst("BPM", rows, header: ["rekordbox", "Sounding", "Class"],
                     include: { _, e in e.bpmClass != nil && e.bpmClass != .exact },
                     badness: { _, e in e.bpmError.map { abs($0) } ?? .infinity },
                     cells: { t, e in [number(t.referenceBPM, 2), number(e.observation.bpm, 2), e.bpmClass?.rawValue ?? "–", bpmReason(t, e)] })
        out += worst("Beat offset", rows, header: ["Median ms", "p90 ms", "Signed ms"],
                     include: { _, e in e.beat != nil },
                     badness: { _, e in e.beat?.medianAbsMs ?? 0 },
                     cells: { t, e in [number(e.beat?.medianAbsMs), number(e.beat?.p90AbsMs), signed(e.beat?.medianSignedMs), beatReason(t, e)] })
        out += worst("Drift (start vs end)", rows, header: ["Start ms", "End ms", "Drift ms"],
                     include: { _, e in e.beat != nil && !e.isOctaveError },
                     badness: { _, e in abs(e.beat?.driftMs ?? 0) },
                     cells: { t, e in [signed(e.beat?.startOffsetMs), signed(e.beat?.endOffsetMs), signed(e.beat?.driftMs), driftReason(t, e)] })
        out += worst("Downbeats and bar phase", rows, header: ["First downbeat ms", "Shift (beats)", "On bar 1"],
                     include: { _, e in e.downbeat != nil && (e.downbeat?.barPhaseShift != 0 || !(e.downbeat?.firstAgrees ?? false)) },
                     badness: { _, e in 1 - (e.downbeat?.barPhaseAgreement ?? 0) + (e.downbeat?.firstAgrees == true ? 0 : 0.001) },
                     cells: { t, e in [signed(e.downbeat?.firstDownbeatDeltaMs), e.downbeat?.barPhaseShift.map(String.init) ?? "–", number((e.downbeat?.barPhaseAgreement ?? 0) * 100, 0) + "%", downbeatReason(t, e)] })
        out += worst("Variable tempo", rows, header: ["rekordbox segments", "Followed"],
                     include: { t, e in t.reference.hasVariableTempo && e.tempo != nil },
                     badness: { _, e in 1 - (e.tempo?.followFraction ?? 0) },
                     cells: { t, e in ["\(t.reference.tempoSegments.filter { $0.beats >= 4 }.count)", number((e.tempo?.followFraction ?? 0) * 100, 0) + "%", tempoReason(t, e)] })
        out += worst("Phrases (±1 bar)", rows, header: ["F", "Precision", "Recall"],
                     include: { _, e in e.phraseBar != nil },
                     badness: { _, e in 1 - (e.phraseBar?.f ?? 0) },
                     cells: { t, e in [number(e.phraseBar?.f, 2), number(e.phraseBar?.precision, 2), number(e.phraseBar?.recall, 2), phraseReason(t, e)] })
        out += worst("Intro length", rows, header: ["rekordbox bars", "Sounding bars", "Error bars"],
                     include: { _, e in e.introErrorBars != nil },
                     badness: { _, e in abs(e.introErrorBars ?? 0) },
                     cells: { t, e in [number(t.referenceIntroBars, 0), number(e.oursIntroBars, 0), signed(e.introErrorBars, 1), introReason(t, e)] })
        out += worst("Outro length", rows, header: ["rekordbox bars", "Sounding bars", "Error bars"],
                     include: { _, e in e.outroErrorBars != nil },
                     badness: { _, e in abs(e.outroErrorBars ?? 0) },
                     cells: { t, e in [number(t.referenceOutroBars, 0), number(e.oursOutroBars, 0), signed(e.outroErrorBars, 1), outroReason(t, e)] })
        if rows.contains(where: { $0.referenceKey != nil }) {
            let severity: [KeyClass: Double] = [.missing: 4, .other: 3, .relative: 2, .adjacent: 1, .exact: 0]
            out += worst("Key", rows, header: ["rekordbox", "Sounding", "Class"],
                         include: { _, e in e.keyClass != nil && e.keyClass != .exact },
                         badness: { _, e in severity[e.keyClass ?? .missing] ?? 0 },
                         cells: { t, e in [keyLabel(t.referenceKey), keyLabel(e.observation.key), e.keyClass?.rawValue ?? "–", keyReason(t, e)] })
        }
        out += worst("Speed", rows, header: ["Seconds", "Track min"],
                     include: { _, _ in true },
                     badness: { _, e in e.observation.seconds },
                     cells: { t, e in [number(e.observation.seconds, 2), number(t.duration / 60, 1), speedReason(t, e)] })
        return out
    }

    // MARK: - Documents

    static func markdown(_ rows: [TrackComparison], info: ComparisonRunInfo) -> String {
        let engineCount = rows.map(\.engines.count).max() ?? 0
        let engineNames = (0 ..< engineCount).map { i in rows.lazy.compactMap { engine($0, i)?.observation.name }.first ?? "Engine \(i + 1)" }
        var lines: [String] = []
        lines.append("# Sounding vs rekordbox analysis")
        lines.append("")
        lines.append("Generated \(ISO8601DateFormatter().string(from: Date())) from `\(info.root)`.")
        lines.append("")
        lines += table(["Input", "Count"], [
            ["ANLZ pairs found", "\(info.pairs)"],
            ["Unreadable ANLZ", "\(info.unreadable)"],
            ["Tracks in ANLZ", "\(info.references)"],
            ["Audio files indexed", "\(info.audioFilesIndexed) under " + info.musicRoots.map { "`\($0)`" }.joined(separator: ", ") + " and XML locations"],
            ["Matched by full path", "\(info.byPath)"],
            ["Matched by file name", "\(info.byFileName)"],
            ["Ambiguous file name (skipped)", "\(info.ambiguous)"],
            ["Audio file missing (skipped)", "\(info.missingAudio)"],
            ["Analysed", "\(info.analysed)"],
            ["rekordbox.xml", info.xmlPath.map { "`\($0)`, \(info.xmlMatched) matched" } ?? "not given, key skipped"],
            ["Production producers", info.producers.joined(separator: ", ")],
            ["Concurrency", "\(info.concurrency)"],
            ["Wall time", String(format: "%.1f min", info.wallSeconds / 60)],
        ])
        lines.append("")
        lines.append("`\(SoundingComparisonRunner.primaryEngine)` is what the DJ engine uses on this Mac: the production audio tier, assembled by `DJSessionDirector.assembleFeatures`. `\(SoundingComparisonRunner.beatTrackerEngine)` is the path without MusicUnderstanding (Apple TV, older systems). Local files have no SoundCloud waveform, so the envelope is empty, as in the app.")
        lines.append("")
        lines.append("## Summary")
        lines.append("")
        lines += table(["Metric"] + engineNames, summaryRows(rows, engineCount: engineCount))
        lines.append("")
        lines.append("## Speed")
        lines.append("")
        lines += table(["Engine", "Realtime factor (median)", "Median s", "Max s"], speedRows(rows, engineCount: engineCount))
        lines.append("")
        lines.append("## By genre (\(engineNames.first ?? "Sounding"))")
        lines.append("")
        lines += table(groupHeader, groupRows(genreGroups(rows)))
        lines.append("")
        lines.append("## By BPM range (\(engineNames.first ?? "Sounding"))")
        lines.append("")
        lines += table(groupHeader, groupRows(bpmGroups(rows)))
        lines.append("")
        lines.append("## Worst \(worstCount) per metric (\(engineNames.first ?? "Sounding"))")
        lines.append("")
        lines += worstSections(rows)
        let failed = rows.filter { $0.failure != nil || $0.engines.contains { $0.observation.failure != nil } }
        if !failed.isEmpty {
            lines.append("## Producer notes")
            lines.append("")
            lines += table(["Track", "Note"], failed.prefix(50).map { t in
                [trackName(t), ([t.failure] + t.engines.map(\.observation.failure)).compactMap { $0 }.joined(separator: "; ")]
            })
            lines.append("")
        }
        lines.append("## Method")
        lines.append("")
        lines.append("- rekordbox BPM is the time-weighted dominant tempo of the PQTZ grid. Classes: exact ±0.05, within ±0.5, half-time and double-time within ±1 BPM of 2×, anything else is other.")
        lines.append("- Beat offsets pair every beat of the sparser grid with the nearest beat of the other, over the span both cover. Drift is the median offset of the last 32 pairs minus the first 32. Beat F-measure uses ±70 ms.")
        lines.append("- Bar phase reads our beat-in-bar at each rekordbox downbeat (PQTZ beat 1). Shift is the most common position; 0 means bars agree.")
        lines.append("- A rekordbox grid is variable when at least two tempos each last 4+ beats and differ by 0.3+ BPM. We follow it when 80% of checkpoints (every 16 beats) are within 1% after octave folding.")
        lines.append("- Phrase boundaries come from PSSI (unmasked as pyrekordbox documents), mapped through the PQTZ grid. The first boundary and anything past the PSSI end are dropped from both sides. Matching is one-to-one, ±1 beat or ±1 bar of the rekordbox grid.")
        lines.append("- Intro is the leading run of Intro phrases; outro the trailing run of Outro phrases, to the PSSI end beat. Ours uses intro/ambient intro and outro/ambient outro sections.")
        lines.append("- Audio files are found with the import's own `RekordboxShareMatcher`: full path, then the XML location, then file name and duration (rekordbox writes `?/<file>` in PPTH locally). Ambiguous names are skipped.")
        lines.append("- Cues are ANLZ memory and hot cues plus XML POSITION_MARK. A cue counts as on a boundary within ±1 bar.")
        lines.append("- Key compares rekordbox.xml Tonality to the longest key region. Relative is the same Camelot number in the other mode; ±1 is a neighbour in the same mode.")
        lines.append("- Time is wall clock per producer while \(info.concurrency) tracks ran at once, so it overstates single-track latency.")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func csvNumber(_ value: Double?, _ digits: Int = 3) -> String {
        guard let value, value.isFinite else { return "" }
        return String(format: "%.\(digits)f", value)
    }

    static func engineColumns(_ prefix: String) -> [String] {
        ["bpm", "bpm_class", "bpm_error", "beat_median_ms", "beat_p90_ms", "beat_signed_ms", "beat_f70", "drift_ms",
         "first_downbeat_ms", "first_downbeat_agrees", "bar_phase_shift", "bar_phase_agreement", "measured_beats", "measured_downbeats",
         "tempo_follow", "ours_variable", "phrase_count", "phrase_f_beat", "phrase_f_bar", "section_count", "section_f_bar",
         "intro_bars", "intro_error_bars", "outro_bars", "outro_error_bars", "key", "key_class", "energy", "cue_suggestions",
         "cue_on_phrase", "cue_on_suggestion", "seconds", "producer_seconds", "note"].map { prefix + "_" + $0 }
    }

    static func engineValues(_ e: EngineComparison?) -> [String] {
        guard let e else { return engineColumns("x").map { _ in "" } }
        let o = e.observation
        return [
            csvNumber(o.bpm), e.bpmClass?.rawValue ?? "", csvNumber(e.bpmError),
            csvNumber(e.beat?.medianAbsMs, 1), csvNumber(e.beat?.p90AbsMs, 1), csvNumber(e.beat?.medianSignedMs, 1),
            csvNumber(e.beat?.fMeasure70), csvNumber(e.beat?.driftMs, 1),
            csvNumber(e.downbeat?.firstDownbeatDeltaMs, 1), e.downbeat.map { $0.firstAgrees ? "1" : "0" } ?? "",
            e.downbeat?.barPhaseShift.map(String.init) ?? "", csvNumber(e.downbeat?.barPhaseAgreement),
            o.measuredBeats ? "1" : "0", o.measuredDownbeats ? "1" : "0",
            csvNumber(e.tempo?.followFraction), e.tempo.map { $0.oursVariable ? "1" : "0" } ?? "",
            "\(o.phraseStarts.count)", csvNumber(e.phraseBeat?.f), csvNumber(e.phraseBar?.f),
            "\(o.sections.count)", csvNumber(e.sectionBar?.f),
            csvNumber(e.oursIntroBars, 1), csvNumber(e.introErrorBars, 1), csvNumber(e.oursOutroBars, 1), csvNumber(e.outroErrorBars, 1),
            o.key?.label ?? "", e.keyClass?.rawValue ?? "", o.energy.map(String.init) ?? "", "\(o.cueSuggestions.count)",
            csvNumber(e.cueOnPhrase), csvNumber(e.cueOnSuggestion), csvNumber(o.seconds, 3),
            o.producerSeconds.sorted { $0.key < $1.key }.map { "\($0.key)=\(String(format: "%.3f", $0.value))" }.joined(separator: " "),
            o.failure ?? "",
        ]
    }

    static func csvPrefix(_ name: String) -> String {
        String(name.lowercased().filter { $0.isLetter || $0 == " " }.split(separator: " ").first ?? "engine")
    }

    static func csv(_ rows: [TrackComparison]) -> String {
        let engineCount = rows.map(\.engines.count).max() ?? 0
        let prefixes = (0 ..< engineCount).map { i in csvPrefix(rows.lazy.compactMap { engine($0, i)?.observation.name }.first ?? "engine\(i)") }
        let header = ["anlz", "rb_path", "audio_path", "match", "artist", "title", "genre", "duration_s", "bpm_range", "xml_matched",
                      "rb_bpm", "rb_variable", "rb_tempo_segments", "rb_beats", "rb_mood", "rb_phrases", "rb_phrase_labels",
                      "rb_intro_bars", "rb_outro_bars", "rb_key", "xml_bpm", "rb_cues", "failure"]
            + prefixes.flatMap(engineColumns)
        var lines = [header.joined(separator: ",")]
        for t in rows {
            let base: [String] = [
                t.reference.anlzID, t.reference.devicePath, t.reference.audioPath ?? "", t.reference.match, t.artist, t.title, t.genre, csvNumber(t.duration, 2), t.bpmRange,
                t.reference.xml == nil ? "0" : "1",
                csvNumber(t.referenceBPM, 2), t.reference.hasVariableTempo ? "1" : "0",
                "\(t.reference.tempoSegments.filter { $0.beats >= 4 }.count)", "\(t.reference.beats.count)",
                t.reference.mood.map(String.init) ?? "", "\(t.reference.phrases.count)", t.reference.phraseLabels.joined(separator: " "),
                csvNumber(t.referenceIntroBars, 1), csvNumber(t.referenceOutroBars, 1), keyLabel(t.referenceKey) == "–" ? "" : keyLabel(t.referenceKey),
                csvNumber(t.reference.xml?.averageBpm, 2), "\(t.reference.allCueSeconds.count)", t.failure ?? "",
            ]
            let engines = (0 ..< engineCount).flatMap { engineValues(engine(t, $0)) }
            lines.append((base + engines).map(csvField).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
