import Foundation

nonisolated struct LearnedSetPriors: Codable, Equatable, Sendable {
    struct Distribution: Codable, Equatable, Sendable {
        var p10: Double
        var p25: Double
        var p50: Double
        var p75: Double
        var p90: Double
        var buckets: [String: Double]
    }

    var version: Int
    var sets: Int
    var transitions: Int
    var moveGroups: [String: Double]
    var moves: [String: Double]
    var blendBars: Distribution
    var blendBarsByGenre: [String: Distribution]
    var blendBarsByTempo: [String: Distribution]
    var bassSwapMethods: [String: Double]
    var bassSwapFractionOfBlend: Distribution
    var bassSwapPhrasePosition: [String: Double]
    var doubleBassShare: Double
    var filterShare: [String: Double]
    var loopShare: Double
    var phraseStartShare: Double
    var phraseGridsAlignedShare: Double
    var exitSections: [String: Double]
    var entrySections: [String: Double]
    var energyStepDecibels: Distribution
    var keyDistance: [String: Double]
    var tempoRampShare: Double
    var spacingSeconds: Distribution

    static let defaultsKey = "AutoMixLearnedSetPriors"
    static let pathKey = "AutoMixLearnedSetPriorsPath"
    static let maximumAdjustment = 0.03
    static let weight = 0.012

    static func bucket(_ bars: Double) -> Int {
        AutoMixTransitionFeatures.blendBucket(bars)
    }

    static func load(from url: URL) -> LearnedSetPriors? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LearnedSetPriors.self, from: data)
    }

    static func enabled(defaults: UserDefaults = .standard, bundle: Bundle = .main) -> LearnedSetPriors? {
        guard defaults.bool(forKey: defaultsKey) else { return nil }
        let url = defaults.string(forKey: pathKey).map { URL(fileURLWithPath: $0) }
            ?? bundle.url(forResource: "LearnedSetPriors", withExtension: "json")
        return url.flatMap(load(from:))
    }

    static let pseudoCount = 12.0

    func logLift(_ share: Double?, uniform: Double) -> Double {
        guard uniform > 0 else { return 0 }
        let n = Double(transitions)
        let smoothed = ((share ?? 0) * n + Self.pseudoCount * uniform) / (n + Self.pseudoCount)
        return log(max(0.02, smoothed) / uniform)
    }

    func adjustment(moveType: String, bars: Double, exitSection: String, entrySection: String) -> Double {
        let group = AutoMixNetFeatures.moveGroup(moveType)
        let sections = Double(AutoMixNetFeatures.sectionGroups.count)
        let move = logLift(moveGroups[group], uniform: 1 / Double(AutoMixNetFeatures.moveGroups.count))
        let length = logLift(blendBars.buckets["\(Self.bucket(bars))"], uniform: 1 / Double(AutoMixTransitionFeatures.blendBuckets.count))
        let exit = logLift(exitSections[AutoMixNetFeatures.sectionGroup(exitSection)], uniform: 1 / sections)
        let entry = logLift(entrySections[AutoMixNetFeatures.sectionGroup(entrySection)], uniform: 1 / sections)
        let raw = Self.weight * (move + length + 0.5 * exit + 0.5 * entry)
        return min(Self.maximumAdjustment, max(-Self.maximumAdjustment, raw))
    }

    func adjustment(for plan: DJTransitionPlan, barSeconds: TimeInterval?) -> Double {
        adjustment(
            moveType: AutoMixTransitionFeatures.moveType(templateId: plan.templateId, move: plan.move?.kind),
            bars: plan.overlapSeconds / max(0.1, barSeconds ?? 2),
            exitSection: plan.exit.kind.rawValue,
            entrySection: plan.entry.kind.rawValue
        )
    }
}
