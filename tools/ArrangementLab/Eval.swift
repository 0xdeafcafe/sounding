import Foundation

struct Annotation: Codable {
    let estimate: Bool
    let note: String?
    let segments: [String]

    var intervals: [(bars: Range<Int>, role: TrackArrangement.Role)] {
        segments.compactMap { s in
            let parts = s.split(separator: " ")
            guard parts.count == 2, let role = TrackArrangement.Role(rawValue: String(parts[1])) else { return nil }
            let r = parts[0].split(separator: "-").compactMap { Int($0) }
            guard r.count == 2, r[1] > r[0] else { return nil }
            return (r[0]..<r[1], role)
        }
    }

    func roles(count: Int) -> [TrackArrangement.Role?] {
        var out = [TrackArrangement.Role?](repeating: nil, count: count)
        for i in intervals { for b in i.bars where b < count { out[b] = i.role } }
        return out
    }
}

enum Coarse: String, CaseIterable { case intro, body, lull, peak, outro }

func coarse(_ role: TrackArrangement.Role) -> Coarse {
    switch role {
    case .introDrums, .introQuiet: return .intro
    case .groove, .dropGroove: return .body
    case .breakdown, .build: return .lull
    case .dropOpening, .vocalHook: return .peak
    case .outroUsable, .outroDead: return .outro
    }
}

func isSafe(_ role: TrackArrangement.Role) -> Bool {
    role == .introDrums || role == .groove || role == .dropGroove || role == .outroUsable
}

func legacyRoles(_ track: LabTrack) -> [TrackArrangement.Role?] {
    let r = track.result
    guard let profile = r.bars else { return [] }
    let count = profile.level.count
    let duration = r.analysedSeconds
    let starts = r.phraseStarts + [duration]
    let ranges = zip(starts, starts.dropFirst()).compactMap { $1 > $0 ? $0...$1 : nil }
    let amp = profile.level.map { $0 > -89 ? pow(10, Double($0) / 20) : 0 }
    let median = amp.sorted()[amp.count / 2]
    func level(_ range: ClosedRange<Double>) -> Double? {
        let bars = (0..<count).filter { r.downbeats[$0] >= range.lowerBound - 0.05 && r.downbeats[$0] < range.upperBound - 0.05 }
        guard !bars.isEmpty else { return nil }
        return bars.reduce(0) { $0 + amp[$1] } / Double(bars.count)
    }
    var out = [TrackArrangement.Role?](repeating: nil, count: count)
    for (index, range) in ranges.enumerated() {
        let center = (range.lowerBound + range.upperBound) / 2
        let normalized = center / duration
        let relative = median > 0 ? (level(range) ?? median) / median : 1
        let role: TrackArrangement.Role
        if index == 0 || normalized < 0.12 {
            role = relative < 0.45 ? .introQuiet : .introDrums
        } else if index == ranges.count - 1 || normalized > 0.88 {
            role = relative < 0.45 ? .outroDead : .outroUsable
        } else if relative < 0.65 {
            role = .breakdown
        } else if relative > 1.18 {
            role = .dropOpening
        } else if index + 1 < ranges.count, let next = level(ranges[index + 1]), next / median > relative + 0.2 {
            role = .build
        } else {
            role = .groove
        }
        for b in 0..<count where r.downbeats[b] >= range.lowerBound - 0.05 && r.downbeats[b] < range.upperBound - 0.05 { out[b] = role }
    }
    if let first = out.firstIndex(where: { $0 != nil }) { for b in 0..<first { out[b] = out[first] } }
    return out
}

func currentPeakRule(_ track: LabTrack) -> [Bool] {
    let r = track.result
    guard let profile = r.bars, let bands = profile.bands else { return [] }
    let count = profile.level.count
    let measured = profile.level.filter { $0 > -89 }
    let body = TrackArrangement.percentile(measured, 0.75)
    let values = (0..<count).map { bands[$0 * 4] * 4.343 }
    let loud = (0..<count).filter { profile.level[$0] >= body - 3 }.map { values[$0] }
    let lowTypical = TrackArrangement.percentile(loud.isEmpty ? values : loud, 0.5)
    let dips = (0..<count).map { profile.level[$0] <= body - 6 || values[$0] <= lowTypical - 6 }
    var drop = [Bool](repeating: false, count: count)
    var run = 0
    var b = 0
    while b < count {
        if dips[b] { run += 1; b += 1; continue }
        if run >= 4 {
            var loudRun = 0
            while b + loudRun < count, !dips[b + loudRun] { loudRun += 1 }
            if loudRun >= 4 { for k in b..<min(count, b + 16, b + loudRun) { drop[k] = true } }
        }
        run = 0
        b += 1
    }
    let spans = r.vocalSeconds ?? []
    return (0..<count).map { b in
        let lo = r.downbeats[b], hi = b + 1 < count ? r.downbeats[b + 1] : lo + 2
        let v = spans.reduce(0.0) { $0 + max(0, min($1.upperBound, hi) - max($1.lowerBound, lo)) }
        return drop[b] || (v >= (hi - lo) * 0.25 && !dips[b])
    }
}

struct Tally {
    var bars = 0, exact = 0, coarseHits = 0
    var unsafeBars = 0, unsafeHit = 0, unsafeWindows = 0, unsafeWindowsMissed = 0
    var safeBars = 0, safeRefused = 0, safeUnknown = 0, safeWindows = 0, safeWindowsRefused = 0
    var trueBoundaries = 0, predictedBoundaries = 0, matchedTrue = 0, matchedPredicted = 0
    var introError = 0, outroError = 0, introCount = 0, outroCount = 0
    var missed: [String] = []
    var refused: [String] = []

    mutating func add(id: String, truth: [TrackArrangement.Role?], roles: [TrackArrangement.Role?]?, unsafe: [Bool?]) {
        let count = truth.count
        if let roles {
            for b in 0..<count {
                guard let t = truth[b] else { continue }
                bars += 1
                if roles[b] == t { exact += 1 }
                if let p = roles[b], coarse(p) == coarse(t) { coarseHits += 1 }
            }
            let ts = Set((1..<count).filter { truth[$0] != truth[$0 - 1] })
            let ps = Set((1..<count).filter { roles[$0] != roles[$0 - 1] })
            trueBoundaries += ts.count
            predictedBoundaries += ps.count
            matchedTrue += ts.filter { t in ps.contains { abs($0 - t) <= 2 } }.count
            matchedPredicted += ps.filter { p in ts.contains { abs($0 - p) <= 2 } }.count
            if let ti = truth.firstIndex(where: { $0.map { coarse($0) != .intro } ?? false }),
               let pi = roles.firstIndex(where: { $0.map { coarse($0) != .intro } ?? false }) {
                introError += abs(ti - pi); introCount += 1
            }
            if let to = truth.firstIndex(where: { $0.map { coarse($0) == .outro } ?? false }) {
                let po = roles.firstIndex(where: { $0.map { coarse($0) == .outro } ?? false }) ?? count
                outroError += abs(to - po); outroCount += 1
            }
        }
        var b = 0
        while b < count {
            guard let t = truth[b] else { b += 1; continue }
            var e = b + 1
            while e < count, truth[e] == t { e += 1 }
            if t.isPeak {
                unsafeWindows += 1
                let hits = (b..<e).filter { unsafe[$0] == true }.count
                unsafeBars += e - b
                unsafeHit += hits
                if hits * 2 < e - b { unsafeWindowsMissed += 1; missed.append("\(id) \(b)-\(e) \(t.rawValue)") }
            } else if isSafe(t) {
                let refusedBars = (b..<e).filter { unsafe[$0] == true }.count
                safeBars += e - b
                safeRefused += refusedBars
                safeUnknown += (b..<e).filter { unsafe[$0] == nil }.count
                if e - b >= 8 {
                    safeWindows += 1
                    if refusedBars * 2 >= e - b { safeWindowsRefused += 1; refused.append("\(id) \(b)-\(e) \(t.rawValue)") }
                }
            }
            b = e
        }
    }

    func report(_ name: String) {
        func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "-" : String(format: "%.0f%%", Double(a) / Double(b) * 100) }
        print("== \(name)")
        if bars > 0 {
            print("  role accuracy: exact \(pct(exact, bars)), coarse \(pct(coarseHits, bars)) over \(bars) bars")
            let p = predictedBoundaries == 0 ? 0 : Double(matchedPredicted) / Double(predictedBoundaries)
            let r = trueBoundaries == 0 ? 0 : Double(matchedTrue) / Double(trueBoundaries)
            print(String(format: "  section boundaries ±2 bars: precision %.0f%% recall %.0f%% (truth %d, predicted %d)", p * 100, r * 100, trueBoundaries, predictedBoundaries))
            print(String(format: "  intro end error %.1f bars mean, outro start error %.1f bars mean", Double(introError) / Double(max(1, introCount)), Double(outroError) / Double(max(1, outroCount))))
        }
        print("  UNSAFE false negatives: \(unsafeWindowsMissed)/\(unsafeWindows) peak/hook windows missed (bar recall \(pct(unsafeHit, unsafeBars)))")
        print("  unnecessary refusals: \(safeRefused)/\(safeBars) safe bars refused (\(pct(safeRefused, safeBars))), \(safeWindowsRefused)/\(safeWindows) safe windows (>=8 bars) mostly refused, \(safeUnknown) safe bars unknown")
        if !missed.isEmpty { print("  missed: " + missed.joined(separator: "; ")) }
        if !refused.isEmpty { print("  refused: " + refused.joined(separator: "; ")) }
    }
}

func evaluate(_ tracks: [LabTrack], annotations: [String: Annotation], useAI: Bool) {
    var new = Tally(), legacy = Tally(), rule = Tally(), ai = Tally(), aiBase = Tally()
    var annotated = 0
    for track in tracks {
        guard let annotation = annotations[track.id], let profile = track.result.bars else { continue }
        annotated += 1
        let count = profile.level.count
        let truth = annotation.roles(count: count)
        if annotation.intervals.count != annotation.segments.count || truth.contains(where: { $0 == nil }) {
            print("warning: \(track.id) annotation leaves \(truth.filter { $0 == nil }.count) of \(count) bars unlabelled or has unparsed segments")
        }
        if let a = TrackArrangement.build(track.result, evidence: TrackArrangement.Evidence()) {
            new.add(id: track.id, truth: truth, roles: (0..<count).map { a.role(atBar: $0) }, unsafe: (0..<count).map { a.isPeak(bars: $0..<($0 + 1)) })
        }
        if track.ai != nil, let a = TrackArrangement.build(track.result, evidence: evidence(track, useAI: true)) {
            ai.add(id: track.id, truth: truth, roles: (0..<count).map { a.role(atBar: $0) }, unsafe: (0..<count).map { a.isPeak(bars: $0..<($0 + 1)) })
            if let b = TrackArrangement.build(track.result, evidence: TrackArrangement.Evidence()) {
                aiBase.add(id: track.id, truth: truth, roles: (0..<count).map { b.role(atBar: $0) }, unsafe: (0..<count).map { b.isPeak(bars: $0..<($0 + 1)) })
            }
        }
        let legacyRoles = legacyRoles(track)
        if legacyRoles.count == count {
            legacy.add(id: track.id, truth: truth, roles: legacyRoles, unsafe: legacyRoles.map { $0.map { $0 == .dropOpening } })
        }
        let peaks = currentPeakRule(track)
        if peaks.count == count {
            rule.add(id: track.id, truth: truth, roles: nil, unsafe: peaks.map { $0 })
        }
    }
    print("annotated tracks: \(annotated)")
    new.report("TrackArrangement v\(TrackArrangement.version) (cheap evidence: bars, bands, density, repetition, sectionStarts, SoundAnalysis vocals)")
    if ai.bars > 0 {
        aiBase.report("same tracks, cheap evidence only")
        ai.report("same tracks with Open-Unmix stems")
    }
    legacy.report("legacy classifyStructure (phrase ranges, first/last 12% intro/outro, loud = drop)")
    rule.report("current barCharacters peak rule (DJMoveTemplates.meatyBars)")
}
