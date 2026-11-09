import Foundation

enum AutoMixMove: String, Codable, CaseIterable, Identifiable, Sendable {
    case loopMix
    case longBlend
    case filterFade
    case dropIn
    case quickCut
    case echoOut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .loopMix: return "Loop Mix"
        case .longBlend: return "Long Blend"
        case .filterFade: return "Filter Fade"
        case .dropIn: return "Drop-In"
        case .quickCut: return "Quick Cut"
        case .echoOut: return "Echo Out"
        }
    }

    var detail: String {
        switch self {
        case .loopMix: return "Loops both tracks, then lets go"
        case .longBlend: return "Bass swapped on the phrase"
        case .filterFade: return "Filters one out as the next opens"
        case .dropIn: return "Lands the next track on its drop"
        case .quickCut: return "Straight in on the one"
        case .echoOut: return "An echo on the last beat, then in"
        }
    }

    var plural: String {
        switch self {
        case .loopMix: return "loop mixes"
        case .longBlend: return "long blends"
        case .filterFade: return "filter fades"
        case .dropIn: return "drop-ins"
        case .quickCut: return "quick cuts"
        case .echoOut: return "echo outs"
        }
    }

    var defaultLean: AutoMixLean {
        switch self {
        case .longBlend: return .favourite
        case .loopMix, .filterFade, .dropIn: return .sometimes
        case .quickCut, .echoOut: return .rarely
        }
    }

    static func of(moveType: String) -> AutoMixMove? {
        switch moveType {
        case "loopMix", "move.loopMix":
            return .loopMix
        case "blend", "bridge", "tempoRamp", "bassSwapBlend", "halfTimeBlend", "tempoRampBlend",
             "move.blend", "move.bridge", "move.tempoRamp":
            return .longBlend
        case "breakdownExit", "fxBuild", "filterFadeOut", "filterBloomIn", "highPassThinOut",
             "move.breakdownExit", "move.filterBuild", "move.reverbWash":
            return .filterFade
        case "dropIn", "dropOnTheOne", "loopRoll", "loopRollDown", "doubleDrop",
             "move.dropIn", "move.dropOnTheOne", "move.loopRoll":
            return .dropIn
        case "cut", "cutOnTheOne", "move.cut":
            return .quickCut
        case "echoOut", "move.echoOut", "move.echoBuild":
            return .echoOut
        default:
            return nil
        }
    }

    static func moveTypes(for move: AutoMixMove) -> Set<String> {
        let all = ["loopMix", "blend", "bridge", "tempoRamp", "bassSwapBlend", "halfTimeBlend", "tempoRampBlend",
                   "breakdownExit", "fxBuild", "filterFadeOut", "filterBloomIn", "highPassThinOut",
                   "dropIn", "dropOnTheOne", "loopRoll", "loopRollDown", "doubleDrop",
                   "cut", "cutOnTheOne", "echoOut"]
        return Set(all.filter { of(moveType: $0) == move })
    }
}

enum AutoMixLean: String, Codable, CaseIterable, Identifiable, Sendable {
    case favourite
    case sometimes
    case rarely

    var id: String { rawValue }

    var title: String {
        switch self {
        case .favourite: return "Favourite"
        case .sometimes: return "Sometimes"
        case .rarely: return "Rarely"
        }
    }

    var step: Int {
        switch self {
        case .favourite: return 1
        case .sometimes: return 0
        case .rarely: return -1
        }
    }

    var share: Double {
        switch self {
        case .favourite: return 4
        case .sometimes: return 1.5
        case .rarely: return 0.5
        }
    }
}

struct AutoMixNudges: Codable, Equatable, Sendable {
    var move: AutoMixMove?
    var moveMixes = 0
    var blendBars: Int?
    var blendMixes = 0
    var keySteps: Int?
    var keyMixes = 0

    var isEmpty: Bool { move == nil && blendBars == nil && keySteps == nil }

    mutating func learn(move newMove: AutoMixMove?, blendBars bars: Int?, keySteps steps: Int?) {
        if let newMove {
            moveMixes = newMove == move ? moveMixes + 1 : 1
            move = newMove
        }
        if let bars, bars > 0 {
            blendMixes = bars == blendBars ? blendMixes + 1 : 1
            blendBars = bars
        }
        if let steps {
            let level = min(steps, 1)
            keyMixes = level == keySteps ? keyMixes + 1 : 1
            keySteps = level
        }
    }
}

struct AutoMixStyle: Codable, Equatable, Sendable {
    var leans: [String: AutoMixLean] = [:]
    var blockedMidTrackMoves: [String] = []
    var nudges = AutoMixNudges()

    static let standard = AutoMixStyle()

    static let leanWeight = 0.04
    static let lengthWeight = 0.02
    static let nudgeWeight = 0.02
    static let harmonyWeight = 0.015
    static let maximumAdjustment = 0.08
    static let maximumPersonalAdjustment = 0.12

    func lean(_ move: AutoMixMove) -> AutoMixLean {
        leans[move.rawValue] ?? move.defaultLean
    }

    func isChosen(_ move: AutoMixMove) -> Bool {
        leans[move.rawValue] != nil
    }

    mutating func setLean(_ lean: AutoMixLean, for move: AutoMixMove) {
        leans[move.rawValue] = lean
    }

    var favourites: [AutoMixMove] { AutoMixMove.allCases.filter { lean($0) == .favourite } }

    func isYourMove(_ move: AutoMixMove?) -> Bool {
        guard let move else { return false }
        return isChosen(move) && lean(move) == .favourite
    }

    func adjustment(move: AutoMixMove?, blendBars: Int, keySteps: Int?) -> Double {
        var raw = 0.0
        if let move {
            raw += Self.leanWeight * Double(lean(move).step - move.defaultLean.step)
            if nudges.move == move { raw += Self.nudgeWeight * min(2, Double(nudges.moveMixes)) / 2 + Self.nudgeWeight / 2 }
        }
        if blendBars > 0 {
            let longStep = Double(lean(.longBlend).step - AutoMixMove.longBlend.defaultLean.step)
            if blendBars >= 16 { raw += Self.lengthWeight * longStep }
            else if blendBars <= 4 { raw -= Self.lengthWeight * longStep }
            if let target = nudges.blendBars, target > 0 {
                let distance = abs(log2(Double(blendBars) / Double(target)))
                raw += Self.lengthWeight * (distance < 0.5 ? 1 : distance < 1.5 ? 0 : -1)
            }
        }
        if let target = nudges.keySteps, let keySteps {
            raw += Self.harmonyWeight * (keySteps <= target ? 1 : -1)
        }
        return min(Self.maximumAdjustment, max(-Self.maximumAdjustment, raw))
    }

    static func personalAdjustment(learned: Double, style: Double) -> Double {
        min(maximumPersonalAdjustment, max(-maximumPersonalAdjustment, learned + style))
    }

    func hour(count: Int) -> [AutoMixMove] {
        let moves = AutoMixMove.allCases
        let total = moves.reduce(0) { $0 + lean($1).share + (nudges.move == $1 ? 1 : 0) }
        var quota: [AutoMixMove: Double] = [:]
        for move in moves {
            quota[move] = Double(count) * (lean(move).share + (nudges.move == move ? 1 : 0)) / total
        }
        var counts = quota.mapValues { Int($0) }
        var remaining = count - counts.values.reduce(0, +)
        let byRemainder = moves.sorted { (quota[$0]! - Double(counts[$0]!)) > (quota[$1]! - Double(counts[$1]!)) }
        for move in byRemainder where remaining > 0 {
            counts[move, default: 0] += 1
            remaining -= 1
        }
        var out: [AutoMixMove] = []
        var placed: [AutoMixMove: Int] = [:]
        for slot in 0..<count {
            let next = moves
                .filter { (placed[$0] ?? 0) < (counts[$0] ?? 0) }
                .max { a, b in
                    let da = Double(counts[a]!) * Double(slot + 1) / Double(count) - Double(placed[a] ?? 0)
                    let db = Double(counts[b]!) * Double(slot + 1) / Double(count) - Double(placed[b] ?? 0)
                    return da == db ? (counts[a]! < counts[b]!) : da < db
                }
            guard let next else { break }
            out.append(next)
            placed[next, default: 0] += 1
        }
        return out
    }

    var hourSummary: String {
        let favourites = AutoMixMove.allCases.filter { lean($0) == .favourite }.map(\.plural)
        let sometimes = AutoMixMove.allCases.filter { lean($0) == .sometimes }.map(\.plural)
        func list(_ items: [String], _ joiner: String) -> String {
            guard items.count > 1 else { return items.first ?? "" }
            return items.dropLast().joined(separator: ", ") + " \(joiner) " + items.last!
        }
        if favourites.isEmpty, sometimes.isEmpty {
            return "Mostly the move that suits the two tracks."
        }
        if favourites.isEmpty {
            return "A mix of " + list(sometimes, "and") + "."
        }
        var text = "Mostly " + list(favourites, "and")
        if !sometimes.isEmpty {
            text += ", with the odd " + list(AutoMixMove.allCases.filter { lean($0) == .sometimes }.map { $0.title.lowercased() }, "or")
        }
        return text + "."
    }
}
