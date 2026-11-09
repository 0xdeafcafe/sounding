import Foundation

struct DJIntro: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case plain
        case silence
        case beatOnly
        case beatless
        case vocal
        case quietBuild
        case long
    }

    let kind: Kind
    let contentStart: TimeInterval
    let earliestEntry: TimeInterval
    let alternatives: [TimeInterval]
    let mainSeconds: TimeInterval?

    static let grooveDensity: Float = 0.15
    static let grooveFloorDecibels: Float = 15
    static let grooveBars = 4
    static let mainDensity: Float = 0.45
    static let mainWithinDecibels: Float = 3
    static let quietDecibels: Float = 9
    static let mixInBars = 32
    static let shortMixInBars = 16
    static let longIntroBars = 48
    static let minimumSkipSeconds: TimeInterval = 8

    var skipsIntro: Bool { earliestEntry - contentStart >= Self.minimumSkipSeconds }

    func note(entry: TimeInterval) -> String? {
        guard entry >= 2 else { return nil }
        let seconds = Int(entry.rounded())
        if entry - contentStart >= Self.minimumSkipSeconds {
            switch kind {
            case .beatless: return "Skipping the \(seconds) s ambient intro"
            case .vocal: return "Skipping the \(seconds) s spoken intro"
            case .quietBuild: return "Skipping the \(seconds) s build"
            case .long: return "Skipping \(seconds) s of a long intro"
            default: break
            }
        }
        return contentStart >= 2 ? "Skipping \(Int(contentStart.rounded())) s of silence" : nil
    }

    static func analyse(_ track: TrackFeatures, contentStart: TimeInterval) -> DJIntro {
        let plain = DJIntro(kind: contentStart >= 2 ? .silence : .plain, contentStart: contentStart, earliestEntry: contentStart, alternatives: [], mainSeconds: nil)
        guard let grid = track.beatGrid, grid.barDuration > 0,
              let profile = track.barProfile, track.barStarts.count == profile.level.count,
              profile.level.count >= 16 else { return plain }
        let starts = track.barStarts
        let measured = profile.level.filter { $0 > -89 }.sorted()
        guard measured.count >= 8 else { return plain }
        let body = measured[min(measured.count - 1, Int(Double(measured.count) * 0.75))]
        guard let b0 = starts.firstIndex(where: { $0 >= contentStart - 0.05 }) else { return plain }
        let count = starts.count
        func run(_ from: Int, _ test: (Int) -> Bool) -> Int? {
            var b = from
            while b + grooveBars <= count {
                if (b..<(b + grooveBars)).allSatisfy(test) { return b }
                b += 1
            }
            return nil
        }
        guard let groove = run(b0, { profile.density[$0] >= grooveDensity && profile.level[$0] >= body - grooveFloorDecibels }) else { return plain }
        let main = run(groove) { profile.density[$0] >= mainDensity && profile.level[$0] >= body - mainWithinDecibels }
        let mainSeconds = main.map { starts[$0] }
        func phrase(atOrAfter seconds: TimeInterval) -> TimeInterval {
            if let line = grid.phraseStarts(from: seconds - 0.05, through: seconds + grid.phraseDuration).first { return line }
            return starts.first { $0 >= seconds - 0.05 } ?? seconds
        }
        func bars(_ n: Int, before index: Int) -> TimeInterval? {
            let target = index - n
            guard target >= groove else { return nil }
            return phrase(atOrAfter: starts[target])
        }
        let grooveSeconds = starts[groove]
        if groove - b0 >= grooveBars {
            let vocal = track.provenance.contains(.measuredVocals)
                && track.vocalRanges.contains { $0.lowerBound < grooveSeconds && $0.upperBound > contentStart }
            return DJIntro(
                kind: vocal ? .vocal : .beatless, contentStart: contentStart,
                earliestEntry: phrase(atOrAfter: grooveSeconds),
                alternatives: main.flatMap { bars(mixInBars, before: $0) }.map { [$0] } ?? [],
                mainSeconds: mainSeconds
            )
        }
        guard let main else {
            return plain
        }
        let introBars = main - groove
        let quietBars = (groove..<main).filter { profile.level[$0] <= body - quietDecibels }.count
        if introBars > mixInBars, quietBars * 2 > introBars, let entry = bars(mixInBars, before: main) {
            return DJIntro(kind: .quietBuild, contentStart: contentStart, earliestEntry: entry,
                           alternatives: bars(shortMixInBars, before: main).map { [$0] } ?? [], mainSeconds: mainSeconds)
        }
        if introBars > longIntroBars, let entry = bars(mixInBars, before: main) {
            return DJIntro(kind: .long, contentStart: contentStart, earliestEntry: entry,
                           alternatives: bars(shortMixInBars, before: main).map { [$0] } ?? [], mainSeconds: mainSeconds)
        }
        return DJIntro(kind: introBars >= 8 ? .beatOnly : plain.kind, contentStart: contentStart, earliestEntry: contentStart,
                       alternatives: [], mainSeconds: mainSeconds)
    }

    static let cutEntryWithinDecibels: Float = 6
    static let cutEntrySearchBars = 2

    static func cutEntry(_ track: TrackFeatures, from entry: TimeInterval) -> TimeInterval {
        guard let profile = track.barProfile, track.barStarts.count == profile.level.count, profile.level.count >= 8 else { return entry }
        let levels = profile.level.filter { $0 > -89 }.sorted()
        guard levels.count >= 8 else { return entry }
        let body = levels[min(levels.count - 1, Int(Double(levels.count) * 0.75))]
        guard let first = track.barStarts.firstIndex(where: { $0 >= entry - 0.05 }) else { return entry }
        if profile.level[first] >= body - cutEntryWithinDecibels { return entry }
        for index in first..<min(track.barStarts.count, first + cutEntrySearchBars + 1) where profile.level[index] >= body - cutEntryWithinDecibels {
            return track.barStarts[index]
        }
        guard let grid = track.beatGrid, grid.barDuration > 0 else { return entry }
        let horizon = entry + Double(mixInBars) * grid.barDuration
        for line in grid.phraseStarts(from: entry + 0.05, through: horizon) {
            guard let index = track.barStarts.firstIndex(where: { abs($0 - line) < grid.beatPeriod }) else { continue }
            if profile.level[index] >= body - cutEntryWithinDecibels { return track.barStarts[index] }
        }
        return entry
    }

    static func levelDecibels(_ track: TrackFeatures, at seconds: TimeInterval) -> Double? {
        guard let level = DJContentBounds.level(track, at: seconds) else { return nil }
        let body = track.contentFloor > 0 ? track.contentFloor / DJContentBounds.envelopeFloorRatio : track.contentBounds.body
        guard body > 0 else { return nil }
        return 20 * log10(max(1e-4, level) / body)
    }

    static let energyToleranceDecibels = 6.0
    static let energyPenaltyPerDecibel = 0.01
    static let maximumEnergyPenalty = 0.08

    static func energyAdjustment(outgoing: TrackFeatures, exit: TimeInterval, incoming: TrackFeatures, entry: TimeInterval) -> Double {
        guard let a = levelDecibels(outgoing, at: exit), let b = levelDecibels(incoming, at: entry) else { return 0 }
        let excess = abs(a - b) - energyToleranceDecibels
        guard excess > 0 else { return 0 }
        return -min(maximumEnergyPenalty, excess * energyPenaltyPerDecibel)
    }
}
