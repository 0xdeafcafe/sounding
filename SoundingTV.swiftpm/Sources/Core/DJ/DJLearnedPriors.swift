import Foundation

struct AutoMixTransitionFeatures: Codable, Equatable, Sendable {
    var moveType: String
    var blendBars: Int
    var energyDelta: Double?
    var bpmDistancePercent: Double?
    var keyDistance: Int?
    var outgoingSection: String
    var incomingSection: String
    var vocalOverlapSeconds: Double?

    static let blendBuckets = [0, 4, 8, 16, 32, 64]

    static func moveType(templateId: TransitionTemplateID?, move: MixMove.Kind?) -> String {
        move?.rawValue ?? templateId?.rawValue ?? "cut"
    }

    static func blendBucket(_ bars: Double) -> Int {
        guard bars.isFinite, bars > 0.5 else { return 0 }
        return blendBuckets.min { abs(Double($0) - bars) < abs(Double($1) - bars) } ?? 0
    }

    init(
        moveType: String,
        blendBars: Int,
        energyDelta: Double? = nil,
        bpmDistancePercent: Double? = nil,
        keyDistance: Int? = nil,
        outgoingSection: String = "unknown",
        incomingSection: String = "unknown",
        vocalOverlapSeconds: Double? = nil
    ) {
        self.moveType = moveType
        self.blendBars = blendBars
        self.energyDelta = energyDelta
        self.bpmDistancePercent = bpmDistancePercent
        self.keyDistance = keyDistance
        self.outgoingSection = outgoingSection
        self.incomingSection = incomingSection
        self.vocalOverlapSeconds = vocalOverlapSeconds
    }
}

struct AutoMixRating: Codable, Equatable, Sendable {
    let date: Date
    let liked: Bool
    let features: AutoMixTransitionFeatures
}

struct DJLearnedPriors: Sendable, Equatable {
    struct Tally: Sendable, Equatable {
        var up = 0
        var down = 0
        var count: Int { up + down }
    }

    var moves: [String: Tally] = [:]
    var lengths: [Int: Tally] = [:]

    static let neutral = DJLearnedPriors()
    static let shrinkage = 4.0
    static let moveWeight = 0.04
    static let lengthWeight = 0.03
    static let maximumAdjustment = 0.06
    static let avoidSignal = -0.5
    static let window = 200

    init() {}

    init(ratings: [AutoMixRating]) {
        for rating in ratings.suffix(Self.window) {
            let f = rating.features
            moves[f.moveType, default: Tally()].add(rating.liked)
            lengths[f.blendBars, default: Tally()].add(rating.liked)
        }
    }

    var isEmpty: Bool { moves.isEmpty && lengths.isEmpty }

    static func signal(_ tally: Tally?) -> Double {
        guard let tally, tally.count > 0 else { return 0 }
        return Double(tally.up - tally.down) / (Double(tally.count) + shrinkage)
    }

    func adjustment(moveType: String, blendBars: Int) -> Double {
        let raw = Self.moveWeight * Self.signal(moves[moveType]) + Self.lengthWeight * Self.signal(lengths[blendBars])
        return min(Self.maximumAdjustment, max(-Self.maximumAdjustment, raw))
    }

    func adjustment(for plan: DJTransitionPlan, barSeconds: TimeInterval?) -> Double {
        guard !isEmpty else { return 0 }
        let bars = plan.overlapSeconds / max(0.1, barSeconds ?? 2)
        return adjustment(
            moveType: AutoMixTransitionFeatures.moveType(templateId: plan.templateId, move: plan.move?.kind),
            blendBars: AutoMixTransitionFeatures.blendBucket(bars)
        )
    }

    func avoids(moveType: String) -> Bool {
        Self.signal(moves[moveType]) <= Self.avoidSignal
    }
}

private extension DJLearnedPriors.Tally {
    mutating func add(_ liked: Bool) {
        if liked { up += 1 } else { down += 1 }
    }
}
