import Foundation

extension AutoMixMove {
    static func of(templateId: TransitionTemplateID?, move: MixMove?) -> AutoMixMove? {
        if let move {
            if move.kind == .fxBuild, move.effect == .echo { return .echoOut }
            return of(moveType: move.kind.rawValue)
        }
        return templateId.flatMap { of(moveType: $0.rawValue) }
    }
}

extension AutoMixStyle {
    func allows(_ kind: MixPerformanceMove.Kind) -> Bool {
        !blockedMidTrackMoves.contains(kind.rawValue)
    }

    mutating func setAllowed(_ allowed: Bool, _ kind: MixPerformanceMove.Kind) {
        blockedMidTrackMoves.removeAll { $0 == kind.rawValue }
        if !allowed { blockedMidTrackMoves.append(kind.rawValue) }
        blockedMidTrackMoves.sort()
    }

    var allowedMidTrackMoves: Set<MixPerformanceMove.Kind> {
        Set(MixPerformanceMove.Kind.allCases.filter(allows))
    }
}

struct AutoMixFlairLine: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case liked
        case disliked
        case saved
    }

    enum Source: Equatable, Sendable {
        case moves(Set<String>)
        case lengths(ClosedRange<Int>)
        case nudgedMove
        case nudgedLength
        case nudgedKey
    }

    var id: String
    var kind: Kind
    var text: String
    var evidence: String
    var source: Source

    var symbolName: String {
        switch kind {
        case .liked: return "hand.thumbsup"
        case .disliked: return "hand.thumbsdown"
        case .saved: return "bookmark.fill"
        }
    }
}

struct AutoMixSavedMixTraits: Equatable, Sendable {
    var move: AutoMixMove?
    var blendBars: Int?
    var keySteps: Int?
}

enum AutoMixFlair {
    static let minimumRatings = 4
    static let minimumOneSide = 3
    static let minimumSignal = 0.3
    static let longBars = 16...64
    static let shortBars = 1...8

    static func lines(ratings: [AutoMixRating], nudges: AutoMixNudges) -> [AutoMixFlairLine] {
        let recent = Array(ratings.suffix(DJLearnedPriors.window))
        var out: [AutoMixFlairLine] = []
        for move in AutoMixMove.allCases {
            let types = AutoMixMove.moveTypes(for: move)
            let mine = recent.filter { types.contains($0.features.moveType) }
            guard let line = verdict(mine, id: "move.\(move.rawValue)", source: .moves(types), liked: { long in
                "You like \(long && move != .longBlend ? "long " : "")\(move.plural)"
            }, disliked: {
                "\(capitalised(move.plural)) aren’t for you"
            }) else { continue }
            out.append(line)
        }
        var covered = Set<String>()
        for line in out {
            if case .moves(let types) = line.source { covered.formUnion(types) }
        }
        func uncovered(_ range: ClosedRange<Int>) -> [AutoMixRating]? {
            let mine = recent.filter { range.contains($0.features.blendBars) }
            let spoken = mine.filter { covered.contains($0.features.moveType) }.count
            return spoken * 3 >= mine.count * 2 ? nil : mine
        }
        if let long = uncovered(longBars), let line = verdict(long, id: "length.long", source: .lengths(longBars),
                                                              liked: { _ in "You like long mixes" }, disliked: { "Long mixes aren’t for you" }) {
            out.append(line)
        }
        if let short = uncovered(shortBars), let line = verdict(short, id: "length.short", source: .lengths(shortBars),
                                                                liked: { _ in "You like short mixes" }, disliked: { "Short mixes aren’t for you" }) {
            out.append(line)
        }
        if let move = nudges.move {
            out.append(AutoMixFlairLine(id: "nudge.move", kind: .saved, text: "More \(move.plural)", evidence: savedEvidence(nudges.moveMixes), source: .nudgedMove))
        }
        if let bars = nudges.blendBars {
            out.append(AutoMixFlairLine(id: "nudge.length", kind: .saved, text: "Blends around \(bars) bars", evidence: savedEvidence(nudges.blendMixes), source: .nudgedLength))
        }
        if let steps = nudges.keySteps {
            out.append(AutoMixFlairLine(id: "nudge.key", kind: .saved, text: steps == 0 ? "You keep it in key" : "You stay close in key", evidence: savedEvidence(nudges.keyMixes), source: .nudgedKey))
        }
        return out
    }

    static func verdict(
        _ ratings: [AutoMixRating],
        id: String,
        source: AutoMixFlairLine.Source,
        liked: (Bool) -> String,
        disliked: () -> String
    ) -> AutoMixFlairLine? {
        let up = ratings.filter(\.liked)
        let downCount = ratings.count - up.count
        guard ratings.count >= minimumRatings else { return nil }
        let signal = Double(up.count - downCount) / (Double(ratings.count) + DJLearnedPriors.shrinkage)
        if up.count >= minimumOneSide, signal >= minimumSignal {
            let long = up.filter { longBars.contains($0.features.blendBars) }.count * 3 >= up.count * 2
            return AutoMixFlairLine(id: id, kind: .liked, text: liked(long), evidence: "\(up.count) Nice", source: source)
        }
        if downCount >= minimumOneSide, signal <= -minimumSignal {
            return AutoMixFlairLine(id: id, kind: .disliked, text: disliked(), evidence: "\(downCount) Not Great", source: source)
        }
        return nil
    }

    static func matches(_ rating: AutoMixRating, _ source: AutoMixFlairLine.Source) -> Bool {
        switch source {
        case .moves(let types): return types.contains(rating.features.moveType)
        case .lengths(let range): return range.contains(rating.features.blendBars)
        case .nudgedMove, .nudgedLength, .nudgedKey: return false
        }
    }

    static func forgetting(_ source: AutoMixFlairLine.Source, in nudges: AutoMixNudges) -> AutoMixNudges {
        var next = nudges
        switch source {
        case .nudgedMove:
            next.move = nil
            next.moveMixes = 0
        case .nudgedLength:
            next.blendBars = nil
            next.blendMixes = 0
        case .nudgedKey:
            next.keySteps = nil
            next.keyMixes = 0
        case .moves, .lengths:
            break
        }
        return next
    }

    static func traits(of entry: MixHistoryEntry) -> AutoMixSavedMixTraits {
        let move = AutoMixMove.of(templateId: entry.plan.templateId, move: entry.plan.move)
            ?? entry.feedback.flatMap { AutoMixMove.of(moveType: $0.moveType) }
        var bars = entry.feedback?.blendBars
        if bars == nil, let move = entry.plan.move {
            bars = AutoMixTransitionFeatures.blendBucket(Double(move.totalBars))
        } else if bars == nil, entry.plan.barSeconds > 0 {
            bars = AutoMixTransitionFeatures.blendBucket(entry.plan.transitionSeconds / entry.plan.barSeconds)
        }
        var steps = entry.feedback?.keyDistance
        if steps == nil, let a = entry.outgoing.camelot.flatMap(CamelotKey.parse), let b = entry.incoming.camelot.flatMap(CamelotKey.parse) {
            let wheel = a.wheelSteps(to: b)
            steps = a.mode == b.mode || wheel == 0 ? wheel : wheel + 1
        }
        return AutoMixSavedMixTraits(move: move, blendBars: bars.flatMap { $0 > 0 ? $0 : nil }, keySteps: steps)
    }

    static func savedEvidence(_ count: Int) -> String {
        count == 1 ? "1 Saved Mix" : "\(max(1, count)) Saved Mixes"
    }

    static func capitalised(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    #if DEBUG
    static func fixtureRatings() -> [AutoMixRating] {
        func rating(_ move: String, _ bars: Int, _ liked: Bool) -> AutoMixRating {
            AutoMixRating(date: Date(timeIntervalSince1970: 0), liked: liked, features: AutoMixTransitionFeatures(moveType: move, blendBars: bars))
        }
        return (0..<9).map { _ in rating("loopMix", 16, true) }
            + (0..<4).map { _ in rating("echoOut", 0, false) }
            + [rating("blend", 16, true), rating("blend", 32, false), rating("cut", 0, true)]
    }

    static let fixtureNudges = AutoMixNudges(move: nil, moveMixes: 0, blendBars: nil, blendMixes: 0, keySteps: 0, keyMixes: 2)
    #endif
}
