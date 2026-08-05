import Foundation

struct GenreAudioFeatures: Sendable, Equatable {
    var bpm: Double?
    var swingRatio: Double?
    var isFourFourKick: Bool?
    var percussiveDensity: Double?
    var bassActivityRatio: Double?
    var vocalActivityRatio: Double?
    var melodicActivityRatio: Double?
    var longestQuietBars: Double?
    var phraseRegularity: Double?
    var sectionCount: Int?
    var isMinorKey: Bool?

    init(
        bpm: Double? = nil, swingRatio: Double? = nil, isFourFourKick: Bool? = nil,
        percussiveDensity: Double? = nil, bassActivityRatio: Double? = nil,
        vocalActivityRatio: Double? = nil, melodicActivityRatio: Double? = nil,
        longestQuietBars: Double? = nil, phraseRegularity: Double? = nil,
        sectionCount: Int? = nil, isMinorKey: Bool? = nil
    ) {
        self.bpm = bpm
        self.swingRatio = swingRatio
        self.isFourFourKick = isFourFourKick
        self.percussiveDensity = percussiveDensity
        self.bassActivityRatio = bassActivityRatio
        self.vocalActivityRatio = vocalActivityRatio
        self.melodicActivityRatio = melodicActivityRatio
        self.longestQuietBars = longestQuietBars
        self.phraseRegularity = phraseRegularity
        self.sectionCount = sectionCount
        self.isMinorKey = isMinorKey
    }

    var completeness: Double {
        let present = [
            bpm != nil, swingRatio != nil, isFourFourKick != nil,
            percussiveDensity != nil, vocalActivityRatio != nil,
            melodicActivityRatio != nil, longestQuietBars != nil,
            phraseRegularity != nil
        ].filter { $0 }.count
        return Double(present) / 8.0
    }

    var isEmpty: Bool { completeness == 0 }
}

enum GenreAudioHeuristics {

    private static let axisWeights: [(String, Double)] = [
        ("bpm", 0.30), ("swing", 0.16), ("fourFour", 0.14), ("percussion", 0.12),
        ("vocal", 0.10), ("melodic", 0.10), ("breakdown", 0.05), ("phrase", 0.03)
    ]

    static func classify(_ features: GenreAudioFeatures) -> [(genre: MusicGenre, score: Double)] {
        guard !features.isEmpty else { return [] }

        var results: [(MusicGenre, Double)] = []
        for genre in MusicGenre.allCases {
            let profile = GenreProfile.of(genre)
            guard profile.isDJMaterial, genre != .unknown else { continue }

            var weighted = 0.0
            var used = 0.0

            func score(_ name: String, _ error: Double) {
                guard let weight = axisWeights.first(where: { $0.0 == name })?.1 else { return }
                weighted += weight * (1 - min(1, max(0, error)))
                used += weight
            }

            if let bpm = features.bpm, bpm > 20 {
                score("bpm", bpmError(bpm, profile))
            }
            if let swing = features.swingRatio {
                let observed = min(1, max(0, (swing - 0.5) / 0.12))
                score("swing", abs(observed - profile.swing))
            }
            if let fourFour = features.isFourFourKick {
                score("fourFour", abs((fourFour ? 1.0 : 0.0) - profile.fourFourness))
            }
            if let percussion = features.percussiveDensity {
                score("percussion", abs(percussion - profile.percussiveDensity))
            }
            if let vocal = features.vocalActivityRatio {
                score("vocal", abs(vocal - profile.vocalPresence))
            }
            if let melodic = features.melodicActivityRatio {
                score("melodic", abs(melodic - profile.melodicContent))
            }
            if let quiet = features.longestQuietBars {
                score("breakdown", abs(min(1, quiet / 64) - profile.breakdownLength))
            }
            if let phrase = features.phraseRegularity {
                score("phrase", abs(phrase - profile.phraseStrictness))
            }

            guard used > 0 else { continue }
            results.append((genre, weighted / used))
        }

        return results.sorted { $0.1 > $1.1 }.map { (genre: $0.0, score: $0.1) }
    }

    static func bpmError(_ bpm: Double, _ profile: GenreProfile) -> Double {
        func raw(_ value: Double) -> Double {
            if profile.bpmRange.contains(value) { return 0 }
            let distance = value < profile.bpmLow
                ? profile.bpmLow - value
                : value - profile.bpmHigh
            return min(1, distance / 25)
        }
        let direct = raw(bpm)
        guard profile.halfTimeAffinity >= 0.5 else { return direct }
        let folded = min(raw(bpm * 2), raw(bpm / 2))
        return min(direct, folded + 0.25)
    }
}

enum GenreDetector {

    static func resolve(
        genreField: String?,
        tags: [String] = [],
        features: GenreAudioFeatures? = nil
    ) -> GenreResolution {

        var evidence: [String] = []
        var scores: [MusicGenre: Double] = [:]
        var familyScores: [GenreFamily: Double] = [:]
        var bpmHint: Double?
        var bestSource: GenreEvidenceSource = .none
        var sawUmbrella = false

        func credit(_ match: GenreTagNormalizer.Match, weight: Double, label: String,
                    source: GenreEvidenceSource) {
            if match.genre != .unknown {
                let profile = GenreProfile.of(match.genre)
                let value = weight * match.strength * profile.specificity
                scores[match.genre, default: 0] += value
                familyScores[match.family, default: 0] += value
                if bestSource == .none { bestSource = source }
                evidence.append("\(label) → \(profile.displayName) (\(match.route))")
            } else if match.family != .unknown {
                familyScores[match.family, default: 0] += weight * match.strength
                evidence.append("\(label) → \(match.family.rawValue) family only")
            } else {
                sawUmbrella = true
                evidence.append("\(label) → too broad to place")
            }
        }

        if let genreField, !genreField.trimmingCharacters(in: .whitespaces).isEmpty {
            if let match = GenreTagNormalizer.resolve(genreField) {
                credit(match, weight: 3.0, label: "genre '\(genreField)'", source: .genreField)
            } else {
                evidence.append("genre '\(genreField)' → not a genre we know")
            }
        }

        for (index, tag) in tags.enumerated() {
            if let hint = GenreTagNormalizer.bpmHint(tag) {
                bpmHint = bpmHint ?? hint
                evidence.append("tag '\(tag)' → \(Int(hint)) BPM hint")
                continue
            }
            guard let match = GenreTagNormalizer.resolve(tag) else { continue }
            let positional = max(0.6, 1.0 - Double(index) * 0.05)
            credit(match, weight: 1.0 * positional, label: "tag '\(tag)'", source: .tags)
        }

        if tags.count >= 2 {
            for index in 0..<(tags.count - 1) {
                let joined = tags[index] + tags[index + 1]
                let key = GenreTagNormalizer.squash(joined)
                if let genre = GenreTagNormalizer.aliases[key] {
                    let profile = GenreProfile.of(genre)
                    scores[genre, default: 0] += 1.2 * profile.specificity
                    familyScores[profile.family, default: 0] += 1.2
                    if bestSource == .none || bestSource == .tags { bestSource = .joinedTags }
                    evidence.append(
                        "tags '\(tags[index])' + '\(tags[index + 1])' → \(profile.displayName) "
                        + "(rejoined; SoundCloud splits unquoted multi-word tags)"
                    )
                }
            }
        }

        let measuredBPM = features?.bpm ?? bpmHint
        if let measuredBPM, let leader = scores.max(by: { $0.value < $1.value })?.key {
            let profile = GenreProfile.of(leader)
            let error = GenreAudioHeuristics.bpmError(measuredBPM, profile)
            if error > 0.6 {
                scores[leader] = (scores[leader] ?? 0) * 0.5
                evidence.append(
                    "\(Int(measuredBPM)) BPM is well outside \(profile.displayName)'s "
                    + "\(Int(profile.bpmLow))–\(Int(profile.bpmHigh)) range — label downweighted"
                )
            }
        }

        var audioLeader: (genre: MusicGenre, score: Double)?
        if let features, !features.isEmpty {
            let ranked = GenreAudioHeuristics.classify(features)
            audioLeader = ranked.first
            let cap = 1.4 * features.completeness
            for (genre, score) in ranked.prefix(4) where score > 0.55 {
                scores[genre, default: 0] += cap * (score - 0.55) / 0.45
                familyScores[GenreProfile.of(genre).family, default: 0] += cap * 0.5 * (score - 0.55) / 0.45
            }
            if let leader = ranked.first {
                evidence.append(
                    "audio → \(GenreProfile.of(leader.genre).displayName) "
                    + "(fit \(String(format: "%.2f", leader.score)), "
                    + "\(Int(features.completeness * 100))% of features present)"
                )
            }
        }

        let ranked = scores.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key.rawValue < rhs.key.rawValue : lhs.value > rhs.value
        }

        guard let winner = ranked.first, winner.value > 0 else {
            let family = familyScores.max(by: { $0.value < $1.value })?.key ?? .unknown
            if let features, !features.isEmpty, let leader = audioLeader, leader.score > 0.6 {
                let value = min(0.5, 0.28 + 0.3 * features.completeness)
                return GenreResolution(
                    genre: leader.genre, family: GenreProfile.of(leader.genre).family,
                    confidenceValue: value, source: .audioFeatures,
                    evidence: evidence + ["no usable metadata — classified from audio alone"],
                    alternatives: [], bpmHint: bpmHint
                )
            }
            if bpmHint != nil {
                return GenreResolution(
                    genre: .unknown, family: family, confidenceValue: 0.10,
                    source: .bpmOnly, evidence: evidence, alternatives: [], bpmHint: bpmHint
                )
            }
            return GenreResolution(
                genre: .unknown, family: family,
                confidenceValue: sawUmbrella || family != .unknown ? 0.12 : 0,
                source: family == .unknown ? .none : .tags,
                evidence: evidence.isEmpty ? ["no usable genre metadata"] : evidence,
                alternatives: [], bpmHint: bpmHint
            )
        }

        var confidence = min(0.92, 0.32 + 0.20 * winner.value)

        if ranked.count > 1 {
            let runnerUp = ranked[1]
            let margin = (winner.value - runnerUp.value) / winner.value
            if margin < 0.35 {
                let sameFamily = GenreProfile.of(winner.key).family == GenreProfile.of(runnerUp.key).family
                confidence *= sameFamily ? 0.90 : 0.68
                evidence.append(
                    "conflicting labels: \(GenreProfile.of(winner.key).displayName) vs "
                    + "\(GenreProfile.of(runnerUp.key).displayName)"
                    + (sameFamily ? " (same family)" : " (different families)")
                )
            }
        }

        if let audioLeader, audioLeader.score > 0.6 {
            if audioLeader.genre == winner.key {
                confidence = min(0.95, confidence * 1.12)
                evidence.append("audio agrees with the metadata")
            } else if GenreProfile.of(audioLeader.genre).family != GenreProfile.of(winner.key).family {
                confidence *= 0.85
                evidence.append(
                    "audio suggests \(GenreProfile.of(audioLeader.genre).displayName) instead — "
                    + "metadata kept, confidence reduced"
                )
            }
        }

        let alternatives = ranked.dropFirst().prefix(3).map { $0.key }
        let family = GenreProfile.of(winner.key).family

        return GenreResolution(
            genre: winner.key,
            family: family,
            confidenceValue: min(0.95, max(0.05, confidence)),
            source: bestSource == .none ? .audioFeatures : bestSource,
            evidence: evidence,
            alternatives: Array(alternatives),
            bpmHint: bpmHint
        )
    }
}

struct GenreTermResult: Sendable, Equatable {
    let cost: Double
    let confidence: Double
    let reason: String
}

enum GenreScoringTerm {

    static let identifier = "genre"

    static func evaluate(
        from: GenreResolution,
        to: GenreResolution,
        arc: SetArc = .rising
    ) -> GenreTermResult {
        let cost = GenreDistanceModel.mixCost(from: from.genre, to: to.genre, arc: arc)
        let confidence = from.confidenceValue * to.confidenceValue
        let qualifier: String
        switch GenreConfidence(confidence) {
        case .high: qualifier = ""
        case .medium: qualifier = " (genre fairly confident)"
        case .low: qualifier = " (genre uncertain — weigh lightly)"
        case .none: qualifier = " (genre unknown — ignore this term)"
        }
        return GenreTermResult(cost: cost.cost, confidence: confidence, reason: cost.reason + qualifier)
    }

}
