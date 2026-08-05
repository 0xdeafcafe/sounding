import Foundation

enum GenreConfidence: String, Codable, Sendable, Comparable {
    case none
    case low
    case medium
    case high

    init(_ value: Double) {
        switch value {
        case ..<0.15: self = .none
        case ..<0.45: self = .low
        case ..<0.72: self = .medium
        default: self = .high
        }
    }

    private var order: Int {
        switch self {
        case .none: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        }
    }

    static func < (a: GenreConfidence, b: GenreConfidence) -> Bool { a.order < b.order }
}

enum GenreEvidenceSource: String, Codable, Sendable {
    case genreField
    case tags
    case joinedTags
    case audioFeatures
    case bpmOnly
    case none
}

struct GenreResolution: Sendable, Equatable {
    let genre: MusicGenre
    let family: GenreFamily
    let confidenceValue: Double
    let source: GenreEvidenceSource
    let evidence: [String]
    let alternatives: [MusicGenre]
    let bpmHint: Double?

    var confidence: GenreConfidence { GenreConfidence(confidenceValue) }

    static let unresolved = GenreResolution(
        genre: .unknown, family: .unknown, confidenceValue: 0,
        source: .none, evidence: ["no usable genre metadata"],
        alternatives: [], bpmHint: nil
    )
}

enum GenreTagNormalizer {

    static func squash(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var out = ""
        out.reserveCapacity(folded.count)
        var index = folded.startIndex
        while index < folded.endIndex {
            let character = folded[index]
            if character == "&" || character == "+" {
                out += "and"
            } else if character.isLetter || character.isNumber {
                out.append(Character(character.lowercased()))
            }
            index = folded.index(after: index)
        }
        return out
    }

    static func splitCandidates(_ raw: String) -> [String] {
        var parts = [raw]
        for separator in [",", "|", "/", "\\", ";", " - ", " – ", " — "] {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func tokens(_ raw: String) -> [String] {
        raw.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
    }

    static func isMachineTag(_ raw: String) -> Bool {
        guard let colon = raw.firstIndex(of: ":") else { return false }
        return raw[colon...].contains("=")
    }

    static func isJunk(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if isMachineTag(trimmed) { return true }
        let lower = trimmed.lowercased()
        if lower.contains("http") || lower.contains("www.") || lower.contains(".com") { return true }
        let key = squash(trimmed)
        if key.count <= 2 { return true }
        if noise.contains(key) { return true }
        if let n = Int(key), n >= 1900, n <= 2099 { return true }
        if key.count >= 20 && !key.contains(where: { $0.isLetter == false }) == false {
            if key.count >= 24 && key.contains(where: { $0.isNumber }) { return true }
        }
        return false
    }

    static func bpmHint(_ raw: String) -> Double? {
        let key = squash(raw)
        var digits = key
        if key.hasSuffix("bpm") { digits = String(key.dropLast(3)) }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isNumber }), let value = Double(digits) else { return nil }
        guard value >= 60, value <= 220 else { return nil }
        return value
    }

    struct Match: Sendable, Equatable {
        let genre: MusicGenre
        let family: GenreFamily
        let strength: Double
        let route: String
    }

    static func resolve(_ raw: String) -> Match? {
        if isJunk(raw) { return nil }

        let whole = squash(raw)
        if let genre = aliases[whole] {
            return Match(genre: genre, family: GenreProfile.of(genre).family,
                         strength: 1.0, route: "exact")
        }
        if let family = familyAliases[whole] {
            return Match(genre: .unknown, family: family, strength: 0.30, route: "family only")
        }
        if umbrella.contains(whole) {
            return Match(genre: .unknown, family: .unknown, strength: 0.12, route: "umbrella")
        }

        let parts = splitCandidates(raw)
        if parts.count > 1 {
            var best: (match: Match, score: Double)?
            for part in parts {
                guard let match = resolve(part) else { continue }
                let score = partScore(match, tokenCount: tokens(part).count)
                if best == nil || score > best!.score {
                    best = (match, score)
                }
            }
            if let best {
                return Match(genre: best.match.genre, family: best.match.family,
                             strength: best.match.strength * 0.95, route: "split")
            }
        }

        let parts2 = tokens(raw)
        if parts2.count > 1 {
            for width in stride(from: min(3, parts2.count), through: 1, by: -1) {
                var start = 0
                while start + width <= parts2.count {
                    let key = squash(parts2[start..<(start + width)].joined())
                    if let genre = aliases[key] {
                        return Match(genre: genre, family: GenreProfile.of(genre).family,
                                     strength: width >= 2 ? 0.88 : 0.72, route: "tokens")
                    }
                    start += 1
                }
            }
            for token in parts2 {
                if let family = familyAliases[squash(token)] {
                    return Match(genre: .unknown, family: family, strength: 0.25, route: "family token")
                }
            }
        }

        if let match = containmentMatch(whole) { return match }

        return nil
    }

    private static func partScore(_ match: Match, tokenCount: Int) -> Double {
        guard match.genre != .unknown else {
            return match.family == .unknown ? 0.05 : 0.30
        }
        let specificity = GenreProfile.of(match.genre).specificity
        return match.strength * specificity * (1 + 0.10 * Double(max(0, tokenCount - 1)))
    }

    private static func containmentMatch(_ key: String) -> Match? {
        for context in containmentDenylist where key.contains(context) { return nil }
        var best: (stem: String, genre: MusicGenre)?
        for (stem, genre) in containmentStems where key.contains(stem) {
            if best == nil || stem.count > best!.stem.count { best = (stem, genre) }
        }
        guard let best else { return nil }
        return Match(genre: best.genre, family: GenreProfile.of(best.genre).family,
                     strength: 0.55, route: "contains '\(best.stem)'")
    }
}

extension GenreTagNormalizer {

    static let aliases: [String: MusicGenre] = {
        var out: [String: MusicGenre] = [:]
        func add(_ genre: MusicGenre, _ spellings: [String]) {
            for spelling in spellings { out[squash(spelling)] = genre }
        }

        add(.techHouse, ["tech house", "techhouse", "latin tech", "tech-house"])
        add(.deepHouse, ["deep house", "deephouse"])
        add(.classicHouse, ["house", "classic house", "chicago house", "acid house",
                            "soulful house", "jackin house", "jackin' house", "vocal house",
                            "club house", "latin house", "hot house", "love house"])
        add(.microHouse, ["microhouse", "micro house", "minimal house", "minimal / deep tech",
                          "minimal deep tech", "deep tech", "minimal"])
        add(.progressiveHouse, ["progressive house", "prog house", "proghouse", "progressive"])
        add(.afroHouse, ["afro house", "afrohouse", "afro tech", "afro melodic",
                         "afro/latin", "amapiano", "3step"])
        add(.futureHouse, ["future house", "futurehouse", "bass house", "speed house"])
        add(.bigRoom, ["big room", "bigroom", "big room house", "mainstage", "main stage",
                       "electro house", "future rave"])
        add(.frenchHouse, ["french house", "filter house"])
        add(.funkyHouse, ["funky house", "funkyhouse", "funk house", "funkhouse",
                          "organic house", "org house", "disco house"])

        add(.techno, ["techno", "peak time", "peaktime", "peak time / driving",
                      "techno (peak time / driving)", "driving techno", "peak time techno"])
        add(.hardGroove, ["hard groove", "hardgroove", "hardgroove techno",
                          "hard groove techno", "groove techno", "tribal techno"])
        add(.detroitTechno, ["detroit techno", "detroit"])
        add(.melodicTechno, ["melodic techno", "melodic house & techno", "melodic house and techno",
                             "melodic house", "melo techno", "melotech", "melodictechno"])
        add(.minimalTechno, ["minimal techno", "minimaltechno"])
        add(.hypnoticTechno, ["hypnotic techno", "raw techno", "deep techno", "dub techno",
                              "techno (raw / deep / hypnotic)", "raw / deep / hypnotic",
                              "hypnotic", "raw"])
        add(.acidTechno, ["acid techno", "acid"])
        add(.industrialTechno, ["industrial techno", "industrial", "ebm"])
        add(.hardTechno, ["hard techno", "hardtechno", "hardtekno", "hardtek",
                          "sensual industrial hardtechno"])
        add(.schranz, ["schranz"])

        add(.trance, ["trance", "trance (main floor)", "main floor", "mainfloor",
                      "vocal trance", "neotrance", "neo trance", "hypertrance", "hyper trance",
                      "phonk trance"])
        add(.upliftingTrance, ["uplifting trance", "uplifting"])
        add(.progressiveTrance, ["progressive trance", "prog trance"])
        add(.techTrance, ["tech trance"])
        add(.psyTrance, ["psytrance", "psy trance", "psy", "goa", "goa trance",
                         "full-on", "full on", "progressive psy", "psychedelic",
                         "dark & forest", "psycore", "psy-techno"])
        add(.hardTrance, ["hard trance", "hardtrance"])

        add(.eurodance, ["eurodance", "euro dance", "euro-dance", "euro"])
        add(.euroHouse, ["euro house", "eurohouse"])
        add(.italoDance, ["italo dance", "italodance", "italo"])
        add(.handsUp, ["hands up", "handsup", "handzup", "euro trance", "eurotrance"])
        add(.hardstyle, ["hardstyle", "reverse bass", "reversebass", "rawstyle",
                         "euphoric hardstyle", "jumpstyle"])
        add(.hardHouse, ["hard house", "hardhouse"])
        add(.donk, ["donk", "bounce", "uk bounce", "scouse house"])
        add(.hardDance, ["hard dance", "harddance", "hard dance / hardcore / neo rave",
                         "neo rave", "neorave", "hardcore", "gabber", "frenchcore",
                         "uptempo", "terror", "happy hardcore", "uk hardcore", "ukhardcore"])

        add(.ukGarage, ["uk garage", "ukgarage", "ukg", "garage", "uk garage / bassline",
                        "speedy garage"])
        add(.twoStep, ["2 step", "2step", "two step", "twostep"])
        add(.speedGarage, ["speed garage", "speedgarage"])
        add(.bassline, ["bassline", "bassline house", "niche"])
        add(.ukFunky, ["uk funky", "ukfunky"])

        add(.drumAndBass, ["drum & bass", "drum and bass", "drum n bass", "drum'n'bass",
                           "dnb", "d&b", "d n b", "drumbass", "drumandbass", "jump up",
                           "jumpup", "drum & bass (deep)"])
        add(.liquidDnB, ["liquid", "liquid funk", "liquid dnb", "liquiddnb"])
        add(.neurofunk, ["neurofunk", "neuro", "techstep"])
        add(.jungle, ["jungle", "ragga jungle", "raggajungle"])
        add(.dubstep, ["dubstep", "brostep", "melodic dubstep", "riddim", "deep dubstep",
                       "140", "140 / deep dubstep / grime", "midtempo"])
        add(.grime, ["grime"])
        add(.breakbeat, ["breakbeat", "breaks", "breakbeat / uk bass", "glitch hop",
                         "nu breaks", "breaks / breakbeat / uk bass"])
        add(.footwork, ["footwork", "juke", "juke/footwork", "juke footwork"])

        add(.disco, ["disco", "nu disco / disco", "funk/soul", "funk soul", "funk"])
        add(.nuDisco, ["nu disco", "nudisco", "nu-disco", "italo disco", "italodisco",
                       "dark disco"])
        add(.indieDance, ["indie dance", "indiedance"])

        add(.hipHop, ["hip hop", "hiphop", "hip-hop", "rap", "hip hop/rap", "hip-hop & rap",
                      "hip hop & rap", "rap / hip-hop", "boom bap", "boombap"])
        add(.trap, ["trap", "trap / future bass", "future bass", "futurebass", "phonk"])
        add(.rnb, ["r&b", "rnb", "r&b & soul", "r&b/soul", "soul", "slowjam", "slow jam"])

        add(.pop, ["pop", "dance / pop", "dance pop", "afro pop", "country & folk",
                   "country", "folk", "folk & singer-songwriter", "latin", "reggaeton",
                   "reggae", "dancehall", "world"])
        add(.rock, ["rock", "indie", "alternative rock", "alternativerock", "indie rock",
                    "metal", "punk", "funk rock", "rock / indie", "jazz & blues", "blues",
                    "jazz"])
        add(.ambient, ["ambient", "ambient / experimental", "experimental", "classical",
                       "piano", "soundtrack", "electronic film music"])
        add(.downtempo, ["downtempo", "trip hop", "triphop", "chillout", "chill out",
                         "chill", "lofi", "lo fi", "lo-fi"])

        return out
    }()

    static let familyAliases: [String: GenreFamily] = {
        var out: [String: GenreFamily] = [:]
        func add(_ family: GenreFamily, _ spellings: [String]) {
            for spelling in spellings { out[squash(spelling)] = family }
        }
        add(.techno, ["electro", "classic electro", "detroit electro", "modern electro"])
        add(.bass, ["bass", "bass / club", "bass club", "uk bass", "club"])
        add(.hardDance, ["hard dance / hardcore", "hardcore techno"])
        add(.house, ["house music"])
        return out
    }()

    static let umbrella: Set<String> = Set([
        "electronic", "dance", "danceandedm", "dance and edm", "edm", "electronica",
        "dancemusic", "music", "rave", "club music", "electronic music", "future",
        "banger", "groove", "hifi", "indie dance / dark disco"
    ].map { squash($0) })

    static let noise: Set<String> = Set([
        "free download", "freedownload", "free dl", "freedl", "free", "download",
        "premiere", "exclusive", "world premiere", "unreleased", "id", "unknown",
        "untitled", "edit", "bootleg", "mashup", "remix", "original mix",
        "extended mix", "radio edit", "vip", "vip mix", "rework", "flip", "refix",
        "dj set", "djset", "dj mix", "live set", "live", "podcast", "radio show",
        "mix", "set", "vinyl", "promo", "out now", "outnow", "new music", "newmusic",
        "new release", "follow me", "followme", "repost", "support",
        "support real music", "supportrealmusic", "link in bio", "linkinbio", "buy",
        "stream", "spotify", "bandcamp", "soundcloud", "youtube", "instagram",
        "loop samples", "loops", "acapella", "acapellas", "battle tools", "dj tools",
        "tool", "tools", "sample", "samples", "wip", "demo", "master", "remaster",
        "scfirst", "insight", "blood", "hive", "comedy", "religion & spirituality",
        "other", "misc", "various", "ihm", "tafkamp", "klandestine", "klubbheads",
        "timberlicious", "the cat empire", "chiptune", "show love spread love",
        "music for dreams", "verknipt", "mozart", "morc", "acor"
    ].map { squash($0) })

    static let containmentStems: [(String, MusicGenre)] = [
        ("hardtechno", .hardTechno),      // 'Sensual Industrial Hardtechno'
        ("hardgroove", .hardGroove),
        ("melodictechno", .melodicTechno),
        ("minimaltechno", .minimalTechno),
        ("techhouse", .techHouse),
        ("deephouse", .deepHouse),
        ("progressive", .progressiveHouse),
        ("psytrance", .psyTrance),
        ("hardtrance", .hardTrance),
        ("eurodance", .eurodance),
        ("hardstyle", .hardstyle),
        ("harddance", .hardDance),        // 'HARDDANCE'
        ("drumandbass", .drumAndBass),
        ("breakbeat", .breakbeat),
        ("dubstep", .dubstep),
        ("schranz", .schranz),
        ("garage", .ukGarage),
        ("techno", .techno),              // 'flipfloptechno', 'Fusion Techno'
        ("trance", .trance)               // 'Hypertrance', 'Neotrance'
    ]

    static let containmentDenylist: [String] = [
        "technolog",   // "technology" contains "techno"
        "entrance",    // contains "trance"
        "transe",
        "garageband"
    ]
}
