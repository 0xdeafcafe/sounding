import Foundation
@testable import SoundingTV

#if DEBUG

enum GenreSelfTest {
    static func run() -> MixImportSelfTest.Report {
        var report = MixImportSelfTest.Report()

        func expect(_ name: String, _ condition: @autoclosure () -> Bool) {
            if condition() {
                report.lines.append("\(name) → ok")
            } else {
                report.failures.append(name)
            }
        }

        let cases: [(input: String, expected: MusicGenre)] = [
            ("Techno", .techno),
            ("Trance", .trance),
            ("House", .classicHouse),
            ("Deep House", .deepHouse),
            ("Tech House", .techHouse),
            ("Drum & Bass", .drumAndBass),
            ("Dubstep", .dubstep),
            ("Melodic Techno", .melodicTechno),
            ("Afro House", .afroHouse),
            ("Hard Trance", .hardTrance),
            ("Minimal House", .microHouse),
            ("Bassline", .bassline),

            ("HARD DANCE", .hardDance),
            ("HARD HOUSE", .hardHouse),
            ("DONK", .donk),
            ("psytrance", .psyTrance),
            ("speed garage", .speedGarage),
            ("Speed Garage", .speedGarage),
            ("  Tech House  ", .techHouse),

            ("HARDDANCE", .hardDance),
            ("flipfloptechno", .techno),
            ("Hypertrance", .trance),
            ("Neotrance", .trance),
            ("Sensual Industrial Hardtechno", .hardTechno),

            ("Fusion Techno", .techno),
            ("Techno Edit", .techno),
            ("Phonk Trance", .trance),
            ("Hot House", .classicHouse),
            ("Love House", .classicHouse),
            ("Speedy Garage", .ukGarage),

            ("Dance | Big Room", .bigRoom),
            ("Dance - Techno", .techno),
            ("Dance - House", .classicHouse),
            ("Dance | Trance", .trance),
            ("Hip Hop/Rap", .hipHop),
            ("Eurodance/Trance", .eurodance),
            ("Trance, Progressive House", .progressiveHouse),
            ("Rap / Hip-Hop", .hipHop),
            ("Chill/funk House", .funkyHouse),

            ("#techhouse", .techHouse),
            ("#Techno", .techno),
            ("#Harddance", .hardDance),
            ("tech-house", .techHouse),
            ("tech_house", .techHouse),
            ("TechHouse", .techHouse),
            ("TECH HOUSE", .techHouse),
            ("tech.house", .techHouse),

            ("dnb", .drumAndBass),
            ("d&b", .drumAndBass),
            ("drum and bass", .drumAndBass),
            ("ukg", .ukGarage),
            ("2step", .twoStep),
            ("2-step", .twoStep),
            ("prog house", .progressiveHouse),
            ("hardgroove", .hardGroove),
            ("hard groove", .hardGroove),
            ("handsup", .handsUp),
            ("hands up", .handsUp),
            ("euro dance", .eurodance),
            ("eurohouse", .euroHouse),
            ("schranz", .schranz),
            ("bigroom", .bigRoom),

            ("Melodic House & Techno", .melodicTechno),
            ("Techno (Peak Time / Driving)", .techno),
            ("Techno (Raw / Deep / Hypnotic)", .hypnoticTechno),
            ("Minimal / Deep Tech", .microHouse),
            ("UK Garage / Bassline", .ukGarage),
            ("Nu Disco / Disco", .disco),
            ("Trance (Main Floor)", .trance)
        ]

        var normaliserFailures = 0
        for testCase in cases {
            let got = GenreTagNormalizer.resolve(testCase.input)?.genre ?? .unknown
            if got == testCase.expected {
                report.lines.append("normalise '\(testCase.input)' → \(got.rawValue)")
            } else {
                normaliserFailures += 1
                report.failures.append(
                    "normalise '\(testCase.input)': expected \(testCase.expected.rawValue), got \(got.rawValue)"
                )
            }
        }
        expect("normaliser: all \(cases.count) real-world strings resolved", normaliserFailures == 0)

        let noise = [
            "Loop Samples", "Refix", "Banger", "IHM", "+x", "hive", "Blood",
            "Klubbheads", "the cat empire", "TAFKAMP", "Timberlicious", "Klandestine",
            "Comedy", "Religion & Spirituality", "free download", "FREE DL",
            "premiere", "unreleased", "original mix", "bootleg", "#scfirst",
            "#Verknipt", "#SaraLandry", "#MORC", "2024", "geo:lat=43.555",
            "https://soundcloud.com/foo", "#0dBUAAs1xCGqbNQSJi5IAjARwQPpyK"
        ]
        var leaked: [String] = []
        for tag in noise where GenreTagNormalizer.resolve(tag)?.genre != nil
            && GenreTagNormalizer.resolve(tag)?.genre != .unknown {
            leaked.append(tag)
        }
        expect("noise rejected (\(noise.count) junk strings)", leaked.isEmpty)
        if !leaked.isEmpty { report.failures.append("noise leaked as genres: \(leaked)") }

        for label in ["Electronic", "Dance", "Dance & EDM", "Electronica"] {
            let match = GenreTagNormalizer.resolve(label)
            expect("'\(label)' is umbrella, not a genre", match?.genre ?? .unknown == .unknown)
        }

        var asymmetric: [String] = []
        var outOfRange: [String] = []
        let genres = MusicGenre.allCases
        for a in genres {
            for b in genres {
                let ab = GenreDistanceModel.distance(a, b).cost
                let ba = GenreDistanceModel.distance(b, a).cost
                if abs(ab - ba) > 1e-9 { asymmetric.append("\(a.rawValue)/\(b.rawValue)") }
                if ab < 0 || ab > 1 { outOfRange.append("\(a.rawValue)/\(b.rawValue)=\(ab)") }
            }
        }
        expect("distance is symmetric across all \(genres.count * genres.count) pairs", asymmetric.isEmpty)
        expect("distance stays in 0...1", outOfRange.isEmpty)
        if !asymmetric.isEmpty { report.failures.append("asymmetric pairs: \(asymmetric.prefix(5))") }
        if !outOfRange.isEmpty { report.failures.append("out-of-range: \(outOfRange.prefix(5))") }

        for genre in genres {
            expect("\(genre.rawValue) distance to itself is 0",
                   GenreDistanceModel.distance(genre, genre).cost == 0)
        }

        let hardGrooveTechHouse = GenreDistanceModel.distance(.hardGroove, .techHouse).cost
        let eurodanceHardGroove = GenreDistanceModel.distance(.eurodance, .hardGroove).cost
        let hardGrooveHardTechno = GenreDistanceModel.distance(.hardGroove, .hardTechno).cost

        expect("hard groove → tech house is a short hop (<0.25)", hardGrooveTechHouse < 0.25)
        expect("euro dance → hard groove is not a hop (>0.45)", eurodanceHardGroove > 0.45)
        expect("euro dance → hard groove is far further than tech house → hard groove",
               eurodanceHardGroove > hardGrooveTechHouse * 2)
        expect("hard groove is not adjacent to hard techno (>0.35)", hardGrooveHardTechno > 0.35)
        expect("hard groove sits closer to tech house than to hard techno",
               hardGrooveTechHouse < hardGrooveHardTechno)
        expect("euro dance and hard groove overlap in BPM despite being far apart",
               GenreProfile.of(.eurodance).bpmRange.overlaps(GenreProfile.of(.hardGroove).bpmRange))

        expect("euro dance and euro house are near-neighbours (<0.15)",
               GenreDistanceModel.distance(.eurodance, .euroHouse).cost < 0.15)
        expect("tech house → techno is a comfortable hop (<0.25)",
               GenreDistanceModel.distance(.techHouse, .techno).cost < 0.25)

        let up = GenreDistanceModel.mixCost(from: .techHouse, to: .techno, arc: .rising).cost
        let down = GenreDistanceModel.mixCost(from: .techno, to: .techHouse, arc: .rising).cost
        expect("rising into a harder genre is cheaper than dropping back", up < down)
        expect("mix cost is genuinely asymmetric", abs(up - down) > 0.01)
        let cooling = GenreDistanceModel.mixCost(from: .techno, to: .techHouse, arc: .cooling).cost
        expect("dropping energy is cheap during the come-down", cooling < down)
        expect("asymmetry stays bounded (never more than 0.30 either way)",
               abs(up - GenreDistanceModel.distance(.techHouse, .techno).cost) <= 0.30)

        let unknownCost = GenreDistanceModel.distance(.unknown, .techno).cost
        expect("unknown genre reads as neutral, not distant", unknownCost > 0.15 && unknownCost < 0.45)
        let term = GenreScoringTerm.evaluate(from: .unresolved, to: .unresolved)
        expect("unresolved pairing carries zero confidence", term.confidence == 0)
        expect("unresolved pairing still returns a finite cost", term.cost.isFinite && term.cost <= 0.45)
        expect("unresolved pairing says so in its reason", term.reason.contains("ignore this term"))

        let dnbToHipHop = GenreDistanceModel.tempoRelation(
            fromBPM: 174, toBPM: 87, from: .drumAndBass, to: .hipHop
        )
        expect("174 DnB ↔ 87 hip hop is recognised as a half/double-time fold",
               dnbToHipHop.fold != .direct)
        expect("174 DnB ↔ 87 hip hop is affordable (<0.35)", dnbToHipHop.cost < 0.35)
        expect("the fold lands hip hop in DnB's tempo domain", dnbToHipHop.foldedBPM == 174)
        expect("a naive BPM difference would have called this unmixable",
               GenreDistanceModel.stretchCost(abs(174 - 87) / 174 * 100) > 0.9)

        let dubstepToHipHop = GenreDistanceModel.tempoRelation(
            fromBPM: 140, toBPM: 70, from: .dubstep, to: .hipHop
        )
        expect("140 dubstep ↔ 70 hip hop folds cleanly", dubstepToHipHop.cost < 0.35)

        let garageFold = GenreDistanceModel.tempoRelation(
            fromBPM: 132, toBPM: 66, from: .ukGarage, to: .ukGarage
        )
        expect("UK garage is not granted a cheap half-time fold", garageFold.cost > dubstepToHipHop.cost)

        let withGrain = GenreDistanceModel.tempoRelation(
            fromBPM: 126, toBPM: 134, from: .techHouse, to: .techno
        )
        let againstGrain = GenreDistanceModel.tempoRelation(
            fromBPM: 126, toBPM: 134, from: .techHouse, to: .techHouse
        )
        expect("tech house → techno tempo rise moves with the grain", withGrain.cost < againstGrain.cost)
        expect("an 8 BPM rise across a genre change is nearly free", withGrain.cost < 0.10)

        let sixWithin = GenreDistanceModel.tempoRelation(
            fromBPM: 126, toBPM: 132, from: .techHouse, to: .techHouse
        )
        expect("6 BPM inside tech house is a small cost", sixWithin.cost < 0.20)

        let houseToDnB = GenreDistanceModel.tempoRelation(
            fromBPM: 128, toBPM: 174, from: .classicHouse, to: .drumAndBass
        )
        expect("house → DnB at face value stays expensive", houseToDnB.cost > 0.45)

        let tranceHint = GenreDistanceModel.transitionHint(from: .techTrance, to: .upliftingTrance)
        expect("trance gets strict 32-bar phrasing", tranceHint.phrasing == .strict32)
        expect("trance transitions land on the breakdown",
               tranceHint.preferred.contains(.breakdownDrop))
        expect("trance gets a long blend window", tranceHint.blendBars.upperBound >= 32)

        let techHouseHint = GenreDistanceModel.transitionHint(from: .techHouse, to: .techHouse)
        expect("tech house blends through the groove", techHouseHint.preferred.contains(.bassSwap))
        expect("tech house does not wait for a breakdown",
               !techHouseHint.preferred.contains(.breakdownDrop))

        let hardHint = GenreDistanceModel.transitionHint(from: .hardTechno, to: .schranz)
        expect("hard techno prefers a cut", hardHint.preferred.contains(.quickCut))
        expect("hard techno avoids a long blend", hardHint.avoid.contains(.longBlend))
        expect("hard techno gets a short blend window", hardHint.blendBars.upperBound <= 16)

        let euroHint = GenreDistanceModel.transitionHint(from: .eurodance, to: .eurodance)
        expect("pop-structured euro material gets loose phrasing", euroHint.phrasing == .loose)
        expect("euro material has no long outro to blend through",
               euroHint.avoid.contains(.longBlend))

        let crossHint = GenreDistanceModel.transitionHint(from: .techno, to: .drumAndBass)
        expect("crossing 4/4 → breakbeat is made a moment, not a fade",
               crossHint.preferred.contains(.doubleDrop) || crossHint.preferred.contains(.filterRoll))

        let realLibrarySample: [(title: String, genre: String?)] = [
            ("01-Sunset Regime - I've Got the Real Feel", "Rave"),
            ("Angel D'lite - Freaky Nostalgia", nil),
            ("Bicep x Nelly Furtado - Glue x Say It Right (Switch Disco Edit)", "Dance & EDM"),
            ("Chris Isaak - Wicked Game (Adriatique & Thyladomid Edit) - FREE DOWNLOAD", "Love House"),
            ("DJ Gigola - La Batteria (Extended Version)", "Techno"),
            ("Dimitri Vegas & Like Mike x Maddix x Da Hool ft. Kiki Solvej - Meet Her At The Love Parade", "Techno"),
            ("FOR MY PEOPLE", "IHM"),
            ("HMWL Premiere\u{FFFD} Helsloot - Let's Pretend (Tube & Berger Remix)", nil),
            ("J.K. Rollin - Lick It (Robbie Doherty Remix)", "House"),
            ("Kisloty People", "Dance - Techno"),
            ("Live And Direct (Extended Mix)", "Dance"),
            ("Maroon 5 & REMIND - One More Night X Look Around You (ACN\u{D8}R EDIT)", "Deep House"),
            ("Need In Me - Flashmob (Elliott Kay SQ\u{FFFD}Look Right Through Vocal Refix)", nil),
            ("Pegassi, Virtual Zone & Miss Jane - Virtual Day Yo (Justin Time Bootleg)", "Trance"),
            ("SB077 \u{FFFD} Victor Ruiz & D-Nox 'Arise' (Original Mix)", "Techno"),
            ("Sorrows Of The Moon", "Electronic"),
            ("TACZ - HERE WE GO", "Techno"),
            ("The Prodigy - Breathe (Mark Blair Remix)", nil),
            ("Voodoo (Francis Mercier Remix)", "Dance"),
            ("You And Me (Disclosure Live Raw Edit)", "Sensual Industrial Hardtechno"),
            ("Studio Killers - Ode To The Bouncer [VALL DU SON STARMIX]", "Fusion Techno")
        ]

        var titleOnlyResolvedCount = 0
        var titleOnlyConfidenceSum = 0.0
        var withGenreResolvedCount = 0
        var withGenreConfidenceSum = 0.0
        for row in realLibrarySample {
            let titleOnly = GenreDetector.resolve(genreField: nil, tags: [row.title])
            if titleOnly.genre != .unknown { titleOnlyResolvedCount += 1 }
            titleOnlyConfidenceSum += titleOnly.confidenceValue

            let withGenre = GenreDetector.resolve(genreField: row.genre, tags: [row.title])
            if withGenre.genre != .unknown { withGenreResolvedCount += 1 }
            withGenreConfidenceSum += withGenre.confidenceValue
        }
        let titleOnlyMean = titleOnlyConfidenceSum / Double(realLibrarySample.count)
        let withGenreMean = withGenreConfidenceSum / Double(realLibrarySample.count)
        report.lines.append("  title-only genre detection on \(realLibrarySample.count) real filenames: "
            + "\(titleOnlyResolvedCount) resolved to a concrete genre, mean confidence "
            + "\(String(format: "%.3f", titleOnlyMean)) (measured on the full 321-file "
            + "library: 41/321 resolved, mean 0.058)")
        report.lines.append("  with genre field wired up (current production): "
            + "\(withGenreResolvedCount) resolved to a concrete genre, mean confidence "
            + "\(String(format: "%.3f", withGenreMean)) (measured on the full 321-file "
            + "library, embedded ID3 genre as a proxy for TrackAbout.genre: "
            + "186/321 resolved, mean 0.493)")
        expect(
            "title-only genre confidence is far below the self-test's genreConfidence: 0.7 default",
            titleOnlyMean < 0.15
        )
        expect(
            "wiring up the genre field materially beats title-only on both axes",
            withGenreResolvedCount > titleOnlyResolvedCount && withGenreMean > titleOnlyMean * 2
        )
        expect(
            "with the genre field, real production confidence is still below the self-test's "
                + "genreConfidence: 0.7 default — GenreTerm is real but still starved relative "
                + "to how the term is unit-tested",
            withGenreMean < 0.7
        )

        let techHouseTrack = GenreDetector.resolve(
            genreField: "Tech House",
            tags: ["tech house", "groove", "free download", "2024", "126bpm"]
        )
        expect("detects tech house from metadata", techHouseTrack.genre == .techHouse)
        expect("tech house detection is confident", techHouseTrack.confidence >= .medium)
        expect("BPM hint parsed out of tags", techHouseTrack.bpmHint == 126)

        let split = GenreDetector.resolve(genreField: nil, tags: ["Hard", "Groove", "Ben Sims"])
        expect("rejoins tags SoundCloud split apart", split.genre == .hardGroove)

        let umbrellaOnly = GenreDetector.resolve(genreField: "Electronic", tags: ["premiere"])
        expect("umbrella-only metadata yields no genre", umbrellaOnly.genre == .unknown)
        expect("umbrella-only metadata yields low confidence", umbrellaOnly.confidence <= .low)

        let empty = GenreDetector.resolve(genreField: nil, tags: [])
        expect("no metadata yields unknown", empty.genre == .unknown)
        expect("no metadata yields zero confidence", empty.confidenceValue == 0)

        let conflicted = GenreDetector.resolve(genreField: nil, tags: ["techno", "drum & bass"])
        expect("cross-family tag conflict reduces confidence", conflicted.confidence <= .medium)

        let withoutAudio = GenreDetector.resolve(genreField: "Techno", tags: [])
        let withAudio = GenreDetector.resolve(
            genreField: "Techno", tags: [],
            features: GenreAudioFeatures(
                bpm: 134, swingRatio: 0.50, isFourFourKick: true,
                percussiveDensity: 0.55, vocalActivityRatio: 0.15,
                melodicActivityRatio: 0.20, longestQuietBars: 16, phraseRegularity: 0.80
            )
        )
        expect("audio features never lower a correct metadata match",
               withAudio.confidenceValue >= withoutAudio.confidenceValue)
        expect("metadata-only detection still works with no audio at all",
               withoutAudio.genre == .techno && withoutAudio.confidenceValue > 0)

        let audioOnly = GenreDetector.resolve(
            genreField: nil, tags: [],
            features: GenreAudioFeatures(
                bpm: 174, swingRatio: 0.55, isFourFourKick: false,
                percussiveDensity: 0.90, vocalActivityRatio: 0.35,
                melodicActivityRatio: 0.40, longestQuietBars: 20, phraseRegularity: 0.80
            )
        )
        expect("audio alone can place a track in the right family",
               GenreProfile.of(audioOnly.genre).family == .bass)
        expect("audio-only detection never claims high confidence",
               audioOnly.confidence < .high)

        let contradicted = GenreDetector.resolve(
            genreField: "Deep House", tags: ["174bpm"]
        )
        expect("a contradicting BPM tag is noticed",
               contradicted.evidence.contains { $0.contains("well outside") })

        return report
    }
}
#endif
