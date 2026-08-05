import Foundation

enum GenreFamily: String, Codable, CaseIterable, Sendable, Hashable {
    case house
    case techno
    case trance
    case hardDance
    case garage
    case bass
    case disco
    case urban
    case ambient
    case song
    case unknown
}

enum MusicGenre: String, Codable, CaseIterable, Sendable, Hashable {

    case deepHouse, classicHouse, techHouse, microHouse, progressiveHouse
    case afroHouse, futureHouse, bigRoom, frenchHouse, funkyHouse

    case techno, hardGroove, detroitTechno, melodicTechno, minimalTechno
    case hypnoticTechno, acidTechno, industrialTechno, hardTechno, schranz

    case trance, upliftingTrance, progressiveTrance, techTrance, psyTrance, hardTrance

    case eurodance, euroHouse, italoDance, handsUp, hardstyle, hardHouse, donk, hardDance

    case ukGarage, twoStep, speedGarage, bassline, ukFunky

    case drumAndBass, liquidDnB, neurofunk, jungle, dubstep, grime, breakbeat, footwork

    case disco, nuDisco, indieDance

    case hipHop, trap, rnb

    case pop, rock, ambient, downtempo
    case unknown

    var family: GenreFamily { GenreProfile.of(self).family }
}

/// Turns the stable values kept in analysis/cache records into copy that can be
/// shown to people. Storage and filtering should continue to use the raw value.
enum GenrePresentation {
    static func displayName(for rawValue: String) -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return value }

        if let genre = MusicGenre(rawValue: value) {
            return GenreProfile.of(genre).displayName
        }

        // Be defensive with older imported records that pre-date the taxonomy.
        // Only prettify identifier-like values; preserve genuine uploader copy.
        guard !value.contains(" ") else { return value }
        let separated = value
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(
                of: "([a-z0-9])([A-Z])",
                with: "$1 $2",
                options: .regularExpression
            )
        guard separated != value || value.contains("_") || value.contains("-") else {
            return value
        }
        return separated.capitalized
    }
}

enum GenreSourceQuality: String, Codable, Sendable {
    case verified
    case consensus
    case library
}

struct GenreProfile: Sendable, Equatable {
    let genre: MusicGenre
    let family: GenreFamily
    let displayName: String

    let bpmLow: Double
    let bpmHigh: Double
    let bpmCenter: Double
    let bpmSource: GenreSourceQuality

    let energy: Double
    let swing: Double
    let percussiveDensity: Double
    let melodicContent: Double
    let vocalPresence: Double
    let brightness: Double
    let fourFourness: Double
    let halfTimeFeel: Double
    let phraseStrictness: Double
    let breakdownLength: Double
    let halfTimeAffinity: Double

    let specificity: Double

    let isDJMaterial: Bool

    var bpmRange: ClosedRange<Double> { bpmLow...bpmHigh }
}

extension GenreProfile {

    static func of(_ genre: MusicGenre) -> GenreProfile {
        table[genre] ?? unknownProfile
    }

    static let unknownProfile = GenreProfile(
        genre: .unknown, family: .unknown, displayName: "Unknown",
        bpmLow: 60, bpmHigh: 200, bpmCenter: 126, bpmSource: .consensus,
        energy: 0.5, swing: 0.35, percussiveDensity: 0.5, melodicContent: 0.5,
        vocalPresence: 0.5, brightness: 0.5, fourFourness: 0.75, halfTimeFeel: 0.15,
        phraseStrictness: 0.6, breakdownLength: 0.3, halfTimeAffinity: 0.3,
        specificity: 0, isDJMaterial: true
    )

    private static func row(
        _ genre: MusicGenre, _ family: GenreFamily, _ name: String,
        bpm: ClosedRange<Double>, center: Double? = nil, src: GenreSourceQuality,
        energy: Double, swing: Double, perc: Double, melodic: Double,
        vocal: Double, bright: Double, fourFour: Double = 1.0,
        halfTime: Double = 0.0, phrase: Double, breakdown: Double,
        htAffinity: Double = 0.15, specificity: Double = 1.0, dj: Bool = true
    ) -> GenreProfile {
        GenreProfile(
            genre: genre, family: family, displayName: name,
            bpmLow: bpm.lowerBound, bpmHigh: bpm.upperBound,
            bpmCenter: center ?? (bpm.lowerBound + bpm.upperBound) / 2,
            bpmSource: src,
            energy: energy, swing: swing, percussiveDensity: perc,
            melodicContent: melodic, vocalPresence: vocal, brightness: bright,
            fourFourness: fourFour, halfTimeFeel: halfTime,
            phraseStrictness: phrase, breakdownLength: breakdown,
            halfTimeAffinity: htAffinity, specificity: specificity,
            isDJMaterial: dj
        )
    }

    static let table: [MusicGenre: GenreProfile] = {
        let rows: [GenreProfile] = [

            row(.deepHouse, .house, "Deep House", bpm: 110...125, center: 122, src: .verified,
                energy: 0.35, swing: 0.35, perc: 0.35, melodic: 0.55, vocal: 0.60,
                bright: 0.60, phrase: 0.60, breakdown: 0.25),
            row(.classicHouse, .house, "House", bpm: 118...128, center: 124, src: .consensus,
                energy: 0.45, swing: 0.45, perc: 0.45, melodic: 0.50, vocal: 0.60,
                bright: 0.65, phrase: 0.60, breakdown: 0.20, specificity: 0.85),
            row(.techHouse, .house, "Tech House", bpm: 124...128, center: 126, src: .verified,
                energy: 0.60, swing: 0.55, perc: 0.55, melodic: 0.30, vocal: 0.35,
                bright: 0.40, phrase: 0.75, breakdown: 0.15),
            row(.microHouse, .house, "Microhouse", bpm: 115...130, center: 121, src: .consensus,
                energy: 0.42, swing: 0.50, perc: 0.40, melodic: 0.30, vocal: 0.25,
                bright: 0.45, phrase: 0.70, breakdown: 0.15),
            row(.progressiveHouse, .house, "Progressive House", bpm: 126...132, center: 128, src: .verified,
                energy: 0.60, swing: 0.25, perc: 0.35, melodic: 0.70, vocal: 0.45,
                bright: 0.60, phrase: 0.85, breakdown: 0.60),
            row(.afroHouse, .house, "Afro House", bpm: 118...126, center: 122, src: .consensus,
                energy: 0.55, swing: 0.60, perc: 0.85, melodic: 0.50, vocal: 0.55,
                bright: 0.55, phrase: 0.70, breakdown: 0.25),
            row(.futureHouse, .house, "Future House", bpm: 120...130, center: 126, src: .verified,
                energy: 0.72, swing: 0.40, perc: 0.40, melodic: 0.60, vocal: 0.50,
                bright: 0.70, phrase: 0.80, breakdown: 0.35),
            row(.bigRoom, .house, "Big Room", bpm: 126...132, center: 128, src: .verified,
                energy: 0.90, swing: 0.10, perc: 0.25, melodic: 0.70, vocal: 0.50,
                bright: 0.80, phrase: 0.85, breakdown: 0.50),
            row(.frenchHouse, .house, "French House", bpm: 110...130, center: 122, src: .verified,
                energy: 0.50, swing: 0.50, perc: 0.40, melodic: 0.65, vocal: 0.55,
                bright: 0.75, phrase: 0.60, breakdown: 0.20),
            row(.funkyHouse, .house, "Funky House", bpm: 118...128, center: 124, src: .consensus,
                energy: 0.50, swing: 0.55, perc: 0.50, melodic: 0.65, vocal: 0.70,
                bright: 0.75, phrase: 0.55, breakdown: 0.20),

            row(.techno, .techno, "Techno", bpm: 128...140, center: 134, src: .verified,
                energy: 0.80, swing: 0.15, perc: 0.55, melodic: 0.20, vocal: 0.15,
                bright: 0.25, phrase: 0.80, breakdown: 0.25, specificity: 0.85),
            row(.hardGroove, .techno, "Hard Groove", bpm: 130...140, center: 135, src: .verified,
                energy: 0.70, swing: 0.75, perc: 0.90, melodic: 0.25, vocal: 0.30,
                bright: 0.35, phrase: 0.65, breakdown: 0.10),
            row(.detroitTechno, .techno, "Detroit Techno", bpm: 120...135, center: 126, src: .consensus,
                energy: 0.50, swing: 0.45, perc: 0.50, melodic: 0.60, vocal: 0.20,
                bright: 0.50, phrase: 0.70, breakdown: 0.30),
            row(.melodicTechno, .techno, "Melodic Techno", bpm: 120...128, center: 123, src: .verified,
                energy: 0.65, swing: 0.20, perc: 0.35, melodic: 0.85, vocal: 0.35,
                bright: 0.45, phrase: 0.85, breakdown: 0.65),
            row(.minimalTechno, .techno, "Minimal Techno", bpm: 125...130, center: 128, src: .verified,
                energy: 0.50, swing: 0.30, perc: 0.40, melodic: 0.20, vocal: 0.10,
                bright: 0.35, phrase: 0.80, breakdown: 0.10),
            row(.hypnoticTechno, .techno, "Hypnotic Techno", bpm: 128...136, center: 132, src: .consensus,
                energy: 0.65, swing: 0.25, perc: 0.50, melodic: 0.25, vocal: 0.10,
                bright: 0.20, phrase: 0.75, breakdown: 0.15),
            row(.acidTechno, .techno, "Acid Techno", bpm: 130...145, center: 136, src: .consensus,
                energy: 0.78, swing: 0.25, perc: 0.50, melodic: 0.40, vocal: 0.10,
                bright: 0.30, phrase: 0.70, breakdown: 0.15),
            row(.industrialTechno, .techno, "Industrial Techno", bpm: 130...145, center: 138, src: .consensus,
                energy: 0.85, swing: 0.15, perc: 0.65, melodic: 0.15, vocal: 0.15,
                bright: 0.10, phrase: 0.70, breakdown: 0.15),
            row(.hardTechno, .techno, "Hard Techno", bpm: 143...160, center: 150, src: .consensus,
                energy: 0.93, swing: 0.12, perc: 0.50, melodic: 0.20, vocal: 0.20,
                bright: 0.15, phrase: 0.70, breakdown: 0.10),
            row(.schranz, .techno, "Schranz", bpm: 155...175, center: 162, src: .consensus,
                energy: 0.97, swing: 0.10, perc: 0.55, melodic: 0.10, vocal: 0.15,
                bright: 0.10, phrase: 0.65, breakdown: 0.05),

            row(.trance, .trance, "Trance", bpm: 132...142, center: 138, src: .verified,
                energy: 0.78, swing: 0.10, perc: 0.30, melodic: 0.85, vocal: 0.45,
                bright: 0.75, phrase: 0.95, breakdown: 0.80, specificity: 0.85),
            row(.upliftingTrance, .trance, "Uplifting Trance", bpm: 136...142, center: 138, src: .verified,
                energy: 0.85, swing: 0.08, perc: 0.28, melodic: 0.95, vocal: 0.45,
                bright: 0.90, phrase: 0.95, breakdown: 0.90),
            row(.progressiveTrance, .trance, "Progressive Trance", bpm: 128...136, center: 132, src: .consensus,
                energy: 0.60, swing: 0.15, perc: 0.30, melodic: 0.75, vocal: 0.40,
                bright: 0.60, phrase: 0.90, breakdown: 0.70),
            row(.techTrance, .trance, "Tech Trance", bpm: 136...145, center: 140, src: .consensus,
                energy: 0.80, swing: 0.12, perc: 0.45, melodic: 0.60, vocal: 0.20,
                bright: 0.45, phrase: 0.90, breakdown: 0.55),
            row(.psyTrance, .trance, "Psytrance", bpm: 138...150, center: 145, src: .verified,
                energy: 0.82, swing: 0.05, perc: 0.50, melodic: 0.60, vocal: 0.15,
                bright: 0.40, phrase: 0.75, breakdown: 0.45),
            row(.hardTrance, .trance, "Hard Trance", bpm: 140...152, center: 145, src: .consensus,
                energy: 0.88, swing: 0.10, perc: 0.35, melodic: 0.70, vocal: 0.35,
                bright: 0.60, phrase: 0.85, breakdown: 0.60),

            row(.eurodance, .hardDance, "Eurodance", bpm: 130...150, center: 140, src: .verified,
                energy: 0.62, swing: 0.10, perc: 0.30, melodic: 0.75, vocal: 1.00,
                bright: 0.90, phrase: 0.45, breakdown: 0.30),
            row(.euroHouse, .hardDance, "Euro House", bpm: 125...140, center: 132, src: .consensus,
                energy: 0.58, swing: 0.20, perc: 0.30, melodic: 0.70, vocal: 0.90,
                bright: 0.85, phrase: 0.50, breakdown: 0.30),
            row(.italoDance, .hardDance, "Italo Dance", bpm: 135...145, center: 140, src: .consensus,
                energy: 0.60, swing: 0.10, perc: 0.28, melodic: 0.80, vocal: 0.85,
                bright: 0.90, phrase: 0.45, breakdown: 0.30),
            row(.handsUp, .hardDance, "Hands Up", bpm: 138...155, center: 145, src: .verified,
                energy: 0.75, swing: 0.08, perc: 0.25, melodic: 0.85, vocal: 0.80,
                bright: 0.90, phrase: 0.55, breakdown: 0.40),
            row(.hardstyle, .hardDance, "Hardstyle", bpm: 145...160, center: 152, src: .verified,
                energy: 0.88, swing: 0.05, perc: 0.30, melodic: 0.60, vocal: 0.50,
                bright: 0.50, phrase: 0.70, breakdown: 0.45),
            row(.hardHouse, .hardDance, "Hard House", bpm: 140...155, center: 148, src: .consensus,
                energy: 0.85, swing: 0.20, perc: 0.45, melodic: 0.50, vocal: 0.40,
                bright: 0.55, phrase: 0.70, breakdown: 0.30),
            row(.donk, .hardDance, "Donk", bpm: 140...155, center: 145, src: .library,
                energy: 0.80, swing: 0.15, perc: 0.35, melodic: 0.65, vocal: 0.60,
                bright: 0.85, phrase: 0.50, breakdown: 0.25),
            row(.hardDance, .hardDance, "Hard Dance", bpm: 140...155, center: 147, src: .library,
                energy: 0.83, swing: 0.15, perc: 0.38, melodic: 0.60, vocal: 0.50,
                bright: 0.65, phrase: 0.62, breakdown: 0.33, specificity: 0.70),

            row(.ukGarage, .garage, "UK Garage", bpm: 128...136, center: 132, src: .verified,
                energy: 0.65, swing: 0.85, perc: 0.60, melodic: 0.45, vocal: 0.70,
                bright: 0.60, fourFour: 0.60, phrase: 0.60, breakdown: 0.20,
                htAffinity: 0.10),
            row(.twoStep, .garage, "2-Step", bpm: 130...138, center: 134, src: .verified,
                energy: 0.60, swing: 0.90, perc: 0.65, melodic: 0.45, vocal: 0.75,
                bright: 0.60, fourFour: 0.25, phrase: 0.55, breakdown: 0.20,
                htAffinity: 0.05),
            row(.speedGarage, .garage, "Speed Garage", bpm: 130...138, center: 134, src: .verified,
                energy: 0.75, swing: 0.70, perc: 0.60, melodic: 0.45, vocal: 0.50,
                bright: 0.50, fourFour: 0.85, phrase: 0.60, breakdown: 0.20,
                htAffinity: 0.10),
            row(.bassline, .garage, "Bassline", bpm: 130...142, center: 136, src: .consensus,
                energy: 0.78, swing: 0.65, perc: 0.55, melodic: 0.50, vocal: 0.55,
                bright: 0.55, fourFour: 0.90, phrase: 0.60, breakdown: 0.20,
                htAffinity: 0.10),
            row(.ukFunky, .garage, "UK Funky", bpm: 126...134, center: 130, src: .verified,
                energy: 0.60, swing: 0.70, perc: 0.85, melodic: 0.45, vocal: 0.60,
                bright: 0.60, fourFour: 0.75, phrase: 0.55, breakdown: 0.15,
                htAffinity: 0.15),

            row(.drumAndBass, .bass, "Drum & Bass", bpm: 168...178, center: 174, src: .verified,
                energy: 0.80, swing: 0.35, perc: 0.90, melodic: 0.40, vocal: 0.35,
                bright: 0.40, fourFour: 0.05, halfTime: 0.30, phrase: 0.80,
                breakdown: 0.35, htAffinity: 0.80),
            row(.liquidDnB, .bass, "Liquid DnB", bpm: 170...176, center: 174, src: .verified,
                energy: 0.62, swing: 0.35, perc: 0.75, melodic: 0.70, vocal: 0.70,
                bright: 0.65, fourFour: 0.10, halfTime: 0.30, phrase: 0.80,
                breakdown: 0.40, htAffinity: 0.85),
            row(.neurofunk, .bass, "Neurofunk", bpm: 172...178, center: 175, src: .verified,
                energy: 0.90, swing: 0.30, perc: 0.95, melodic: 0.20, vocal: 0.15,
                bright: 0.10, fourFour: 0.05, halfTime: 0.30, phrase: 0.80,
                breakdown: 0.25, htAffinity: 0.30),
            row(.jungle, .bass, "Jungle", bpm: 160...180, center: 170, src: .consensus,
                energy: 0.78, swing: 0.45, perc: 1.00, melodic: 0.35, vocal: 0.40,
                bright: 0.40, fourFour: 0.02, halfTime: 0.20, phrase: 0.65,
                breakdown: 0.20, htAffinity: 0.25),
            row(.dubstep, .bass, "Dubstep", bpm: 136...144, center: 140, src: .verified,
                energy: 0.85, swing: 0.20, perc: 0.50, melodic: 0.25, vocal: 0.30,
                bright: 0.20, fourFour: 0.30, halfTime: 1.00, phrase: 0.85,
                breakdown: 0.30, htAffinity: 1.00),
            row(.grime, .bass, "Grime", bpm: 136...144, center: 140, src: .verified,
                energy: 0.75, swing: 0.35, perc: 0.60, melodic: 0.30, vocal: 0.90,
                bright: 0.25, fourFour: 0.35, halfTime: 0.80, phrase: 0.70,
                breakdown: 0.20, htAffinity: 0.35),
            row(.breakbeat, .bass, "Breakbeat", bpm: 125...140, center: 132, src: .consensus,
                energy: 0.65, swing: 0.50, perc: 0.80, melodic: 0.45, vocal: 0.40,
                bright: 0.50, fourFour: 0.15, halfTime: 0.15, phrase: 0.60,
                breakdown: 0.25, htAffinity: 0.45),
            row(.footwork, .bass, "Footwork", bpm: 155...165, center: 160, src: .verified,
                energy: 0.75, swing: 0.55, perc: 0.90, melodic: 0.30, vocal: 0.50,
                bright: 0.40, fourFour: 0.20, halfTime: 0.60, phrase: 0.55,
                breakdown: 0.15, htAffinity: 0.90),

            row(.disco, .disco, "Disco", bpm: 110...130, center: 120, src: .consensus,
                energy: 0.45, swing: 0.50, perc: 0.50, melodic: 0.80, vocal: 0.90,
                bright: 0.85, phrase: 0.40, breakdown: 0.20),
            row(.nuDisco, .disco, "Nu-Disco", bpm: 110...125, center: 118, src: .consensus,
                energy: 0.40, swing: 0.50, perc: 0.45, melodic: 0.80, vocal: 0.80,
                bright: 0.80, phrase: 0.45, breakdown: 0.20),
            row(.indieDance, .disco, "Indie Dance", bpm: 112...126, center: 120, src: .consensus,
                energy: 0.50, swing: 0.40, perc: 0.45, melodic: 0.70, vocal: 0.70,
                bright: 0.60, phrase: 0.50, breakdown: 0.25),

            row(.hipHop, .urban, "Hip Hop", bpm: 80...100, center: 90, src: .consensus,
                energy: 0.50, swing: 0.55, perc: 0.55, melodic: 0.40, vocal: 1.00,
                bright: 0.40, fourFour: 0.40, halfTime: 0.60, phrase: 0.50,
                breakdown: 0.15, htAffinity: 0.95),
            row(.trap, .urban, "Trap", bpm: 130...150, center: 140, src: .consensus,
                energy: 0.60, swing: 0.30, perc: 0.60, melodic: 0.40, vocal: 0.90,
                bright: 0.35, fourFour: 0.30, halfTime: 1.00, phrase: 0.65,
                breakdown: 0.20, htAffinity: 1.00),
            row(.rnb, .urban, "R&B", bpm: 70...100, center: 90, src: .consensus,
                energy: 0.30, swing: 0.55, perc: 0.40, melodic: 0.70, vocal: 1.00,
                bright: 0.55, fourFour: 0.45, halfTime: 0.50, phrase: 0.40,
                breakdown: 0.15, htAffinity: 0.85),

            row(.pop, .song, "Pop", bpm: 100...130, center: 120, src: .consensus,
                energy: 0.45, swing: 0.30, perc: 0.35, melodic: 0.85, vocal: 1.00,
                bright: 0.80, fourFour: 0.70, phrase: 0.30, breakdown: 0.20,
                htAffinity: 0.25, specificity: 0.60, dj: false),
            row(.rock, .song, "Rock", bpm: 90...140, center: 120, src: .consensus,
                energy: 0.55, swing: 0.30, perc: 0.50, melodic: 0.80, vocal: 0.95,
                bright: 0.55, fourFour: 0.45, phrase: 0.25, breakdown: 0.15,
                htAffinity: 0.20, specificity: 0.60, dj: false),
            row(.ambient, .ambient, "Ambient", bpm: 60...100, center: 80, src: .consensus,
                energy: 0.10, swing: 0.20, perc: 0.10, melodic: 0.70, vocal: 0.20,
                bright: 0.50, fourFour: 0.10, phrase: 0.20, breakdown: 0.50,
                htAffinity: 0.40, dj: false),
            row(.downtempo, .ambient, "Downtempo", bpm: 80...110, center: 95, src: .consensus,
                energy: 0.25, swing: 0.45, perc: 0.40, melodic: 0.65, vocal: 0.45,
                bright: 0.50, fourFour: 0.55, halfTime: 0.40, phrase: 0.45,
                breakdown: 0.30, htAffinity: 0.70)
        ]
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.genre, $0) })
    }()
}

enum GenreFamilyGraph {

    static let edges: [FamilyPair: Double] = {
        let raw: [(GenreFamily, GenreFamily, Double)] = [
            (.house, .techno, 0.04),
            (.house, .disco, 0.03),
            (.house, .garage, 0.06),
            (.house, .trance, 0.08),
            (.house, .hardDance, 0.10),
            (.techno, .trance, 0.08),
            (.techno, .hardDance, 0.09),
            (.techno, .garage, 0.10),
            (.techno, .bass, 0.12),
            (.trance, .hardDance, 0.05),
            (.trance, .bass, 0.13),
            (.garage, .bass, 0.04),
            (.garage, .urban, 0.08),
            (.bass, .urban, 0.06),
            (.disco, .urban, 0.08),
            (.disco, .garage, 0.07),
            (.ambient, .house, 0.10),
            (.ambient, .urban, 0.09)
        ]
        var out: [FamilyPair: Double] = [:]
        for (a, b, w) in raw { out[FamilyPair(a, b)] = w }
        return out
    }()

    static func distance(_ a: GenreFamily, _ b: GenreFamily) -> Double {
        if a == b { return 0 }
        if let w = edges[FamilyPair(a, b)] { return w }
        if a == .song || b == .song { return 0.18 }
        if a == .unknown || b == .unknown { return 0.08 }
        return 0.12
    }

    struct FamilyPair: Hashable, Sendable {
        let low: String
        let high: String
        init(_ a: GenreFamily, _ b: GenreFamily) {
            if a.rawValue <= b.rawValue {
                low = a.rawValue; high = b.rawValue
            } else {
                low = b.rawValue; high = a.rawValue
            }
        }
    }
}
