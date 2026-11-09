import Foundation
import XCTest
@testable import SoundingTV

private func makeStore(_ writer: String = "device-a") -> CueStore {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DJGearTests-\(UUID().uuidString)", isDirectory: true)
    return CueStore(directory: directory, writerId: writer)
}

final class TrackMatcherTests: XCTestCase {
    private let library = [
        MatchCandidate(trackId: "1", title: "Wavelength", artist: "Mara Lune", durationSeconds: 287.4),
        MatchCandidate(trackId: "2", title: "Theo Moss - Late Night Drive", artist: "Copper Tapes", durationSeconds: 340.2),
        MatchCandidate(trackId: "3", title: "Intro", artist: "Low Sun", durationSeconds: 60),
        MatchCandidate(trackId: "4", title: "Intro", artist: "Low Sun", durationSeconds: 61),
        MatchCandidate(trackId: "5", title: "Signal Fires", artist: "Juno Vale", durationSeconds: 300, isrc: "GB-ABC-26-00001"),
    ]

    func testISRCWinsOverEverything() {
        let outcome = TrackMatcher.match(
            MatchQuery(title: "Completely Different", artist: "Nobody", durationSeconds: 10, isrc: "gbabc2600001"),
            candidates: library
        )
        XCTAssertEqual(outcome, .matched("5"))
    }

    func testTitleArtistAndDurationWithinTwoSeconds() {
        XCTAssertEqual(
            TrackMatcher.match(MatchQuery(title: "Wavelength (Original Mix)", artist: "Mara Lune", durationSeconds: 287, isrc: nil), candidates: library),
            .matched("1")
        )
        XCTAssertEqual(
            TrackMatcher.match(MatchQuery(title: "Wavelength", artist: "Mara Lune", durationSeconds: 290, isrc: nil), candidates: library),
            .missing
        )
    }

    func testUploaderTitlesSplitIntoArtistAndTitle() {
        XCTAssertEqual(
            TrackMatcher.match(MatchQuery(title: "Late Night Drive", artist: "Theo Moss feat. Juno Vale", durationSeconds: 341, isrc: nil), candidates: library),
            .matched("2")
        )
    }

    func testSeveralPassingCandidatesAreAmbiguous() {
        XCTAssertEqual(
            TrackMatcher.match(MatchQuery(title: "Intro", artist: "Low Sun", durationSeconds: 60.5, isrc: nil), candidates: library),
            .ambiguous(["3", "4"])
        )
    }

    func testNormalisationFoldsCaseDiacriticsAndPunctuation() {
        XCTAssertEqual(TrackMatcher.normalise("Café  Del Mar!! (Original Mix)"), "cafe del mar")
        XCTAssertEqual(TrackMatcher.normalise("Somebody Else & Me"), "somebody else and me")
    }
}

final class PrepConflictTests: XCTestCase {
    private func grid(_ bpm: Double, locked: Bool = false) -> PrepGrid {
        PrepGrid(segments: [PrepTempoSegment(startMillis: 100, bpm: bpm)], locked: locked)
    }

    func testUserGridIsNeverOverwrittenByImportOrAnalysis() {
        var local = TrackPrep(trackId: "t")
        local.grid = PrepField(grid(124), source: .user, updatedAtMillis: 10, writerId: "a")
        var imported = TrackPrep(trackId: "t")
        imported.grid = PrepField(grid(126), source: .rekordbox, updatedAtMillis: 99, writerId: "b")
        XCTAssertEqual(TrackPrepPolicy.merge(local: local, incoming: imported).grid?.value.bpm, 124)
        XCTAssertEqual(TrackPrepPolicy.blockedItems(local: local, incoming: imported), [.grid])
    }

    func testLockedGridIsNeverOverwrittenByAnalysis() {
        var local = TrackPrep(trackId: "t")
        local.grid = PrepField(grid(124, locked: true), source: .rekordbox, updatedAtMillis: 10, writerId: "a")
        var analysed = TrackPrep(trackId: "t")
        analysed.grid = PrepField(grid(62), source: .sounding, updatedAtMillis: 50, writerId: "a")
        var reimport = TrackPrep(trackId: "t")
        reimport.grid = PrepField(grid(125), source: .rekordbox, updatedAtMillis: 60, writerId: "a")
        XCTAssertEqual(TrackPrepPolicy.merge(local: local, incoming: analysed).grid?.value.bpm, 124)
        XCTAssertEqual(TrackPrepPolicy.merge(local: local, incoming: reimport).grid?.value.bpm, 124)
    }

    func testUserEditsFromAnotherDeviceFollowLastWriteWins() {
        var local = TrackPrep(trackId: "t")
        local.grid = PrepField(grid(124, locked: true), source: .user, updatedAtMillis: 10, writerId: "a")
        var remote = TrackPrep(trackId: "t")
        remote.grid = PrepField(grid(124, locked: false), source: .user, updatedAtMillis: 20, writerId: "b")
        XCTAssertEqual(TrackPrepPolicy.merge(local: local, incoming: remote).grid?.value.locked, false)
        var older = remote
        older.grid?.updatedAtMillis = 5
        XCTAssertEqual(TrackPrepPolicy.merge(local: local, incoming: older).grid?.value.locked, true)
    }

    func testHigherSourceWinsOverUnprotectedValues() {
        var local = TrackPrep(trackId: "t")
        local.key = PrepField(PrepKey(camelot: "8A", original: "8A"), source: .sounding, updatedAtMillis: 50, writerId: "a")
        var imported = TrackPrep(trackId: "t")
        imported.key = PrepField(PrepKey(camelot: "9A", original: "Em"), source: .rekordbox, updatedAtMillis: 10, writerId: "b")
        XCTAssertEqual(TrackPrepPolicy.merge(local: local, incoming: imported).key?.value.camelot, "9A")
        var analysis = TrackPrep(trackId: "t")
        analysis.key = PrepField(PrepKey(camelot: "1A", original: "1A"), source: .sounding, updatedAtMillis: 99, writerId: "a")
        let merged = TrackPrepPolicy.merge(local: TrackPrepPolicy.merge(local: local, incoming: imported), incoming: analysis)
        XCTAssertEqual(merged.key?.value.camelot, "9A")
    }

    func testCueSyncStaysLastWriteWinsPerCue() {
        let local = CuePoint(trackId: "t", kind: .hotCue, positionMillis: 1_000, hotCueIndex: 0, updatedAtMillis: 10, writerId: "a")
        let newer = CuePoint(trackId: "t", kind: .hotCue, positionMillis: 2_000, hotCueIndex: 0, updatedAtMillis: 20, writerId: "b", origin: .imported)
        XCTAssertTrue(CueSyncPolicy.remoteWins(local: local, remote: CueSyncRecord(newer)))
        XCTAssertEqual(CueSyncRecord(newer).cuePoint.origin, .imported)
        XCTAssertFalse(CueSyncPolicy.remoteWins(local: newer, remote: CueSyncRecord(local)))
    }

    func testHotLoopSharesTheHotSlot() {
        let loop = CuePoint(trackId: "t", kind: .loop, positionMillis: 1_000, endMillis: 3_000, hotCueIndex: 2)
        let cue = CuePoint(trackId: "t", kind: .hotCue, positionMillis: 5_000, hotCueIndex: 2)
        XCTAssertEqual(loop.id, cue.id)
        XCTAssertTrue(loop.isHotLoop)
        XCTAssertNil(CuePoint(trackId: "t", kind: .memory, positionMillis: 1, hotCueIndex: 3).hotCueIndex)
    }

    func testStoreKeepsOriginAndHotLoopsAcrossReopen() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DJGearReopen-\(UUID().uuidString)")
        let store = CueStore(directory: directory, writerId: "a")
        await store.upsert(CuePoint(trackId: "t", kind: .loop, positionMillis: 1_000, endMillis: 2_000, hotCueIndex: 4, origin: .imported))
        let reopened = CueStore(directory: directory, writerId: "a")
        let cues = await reopened.cues(forTrack: "t")
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues.first?.origin, .imported)
        XCTAssertEqual(cues.first?.hotCueIndex, 4)
        XCTAssertEqual(cues.first?.endMillis, 2_000)
    }
}

final class RekordboxXMLTests: XCTestCase {

    func testParsesRekordbox6() throws {
        let library = try RekordboxXML.parse(Data(RekordboxFixtures.rekordbox6.utf8))
        XCTAssertEqual(library.productVersion, "6.8.5")
        XCTAssertEqual(library.tracks.count, 3)
        let first = library.tracks[0]
        XCTAssertEqual(first.name, "Wavelength")
        XCTAssertEqual(first.tonality, "8A")
        XCTAssertEqual(first.colour, 0xFF007F)
        XCTAssertEqual(first.fileURL?.path, "/Users/dj/Music/DJ/Mara Lune - Wavelength.mp3")
        XCTAssertEqual(first.tempos, [RekordboxTempo(inizio: 0.112, bpm: 124, metro: "4/4", battito: 1)])
        XCTAssertEqual(first.marks.count, 5)
        XCTAssertEqual(library.tracks[2].name, "Somebody Else & Me")
        let playlists = library.flattenedPlaylists()
        XCTAssertEqual(playlists.map(\.name), ["Warm-up", "Friday"])
        XCTAssertEqual(playlists[1].path, ["Gigs"])
        XCTAssertEqual(playlists[0].trackIds, ["91234567", "91234568"])
    }

    func testLocationKeyedPlaylistsResolveToTrackIds() throws {
        let library = try RekordboxXML.parse(Data(RekordboxFixtures.rekordbox7.utf8))
        XCTAssertEqual(library.flattenedPlaylists().first?.trackIds, ["204001"])
    }

    func testWriteThenParseIsLossless() throws {
        for fixture in [RekordboxFixtures.rekordbox6, RekordboxFixtures.rekordbox7] {
            let parsed = try RekordboxXML.parse(Data(fixture.utf8))
            let written = RekordboxXML.write(parsed)
            let reparsed = try RekordboxXML.parse(written)
            XCTAssertEqual(reparsed, parsed)
            XCTAssertEqual(RekordboxXML.write(reparsed), written)
        }
    }

    func testRejectsNonRekordboxAndOversizedFiles() {
        XCTAssertThrowsError(try RekordboxXML.parse(Data("<?xml version=\"1.0\"?><plist/>".utf8)))
        XCTAssertThrowsError(try RekordboxXML.parse(Data(count: RekordboxXML.maximumBytes + 1)))
    }

    func testMapsMarksToCuePoints() throws {
        let library = try RekordboxXML.parse(Data(RekordboxFixtures.rekordbox7.utf8))
        let mapped = RekordboxMapping.cues(from: library.tracks[0], trackId: "sc", now: 1, writerId: "a")
        let cues = mapped.cues
        XCTAssertEqual(cues.first { $0.kind == .mixIn }?.positionMillis, 15_618)
        XCTAssertEqual(cues.first { $0.kind == .mixOut }?.positionMillis, 366_094)
        let drop = cues.first { $0.kind == .hotCue }
        XCTAssertEqual(drop?.hotCueIndex, 0)
        XCTAssertEqual(drop?.color, CueColor(red: 224, green: 100, blue: 27))
        let hotLoop = cues.first { $0.isHotLoop }
        XCTAssertEqual(hotLoop?.hotCueIndex, 2)
        XCTAssertEqual(hotLoop?.endMillis, 124_190)
        XCTAssertEqual(cues.filter { $0.kind == .loop && $0.hotCueIndex == nil }.count, 1)
        XCTAssertTrue(cues.allSatisfy { $0.origin == .imported })

        let six = try RekordboxXML.parse(Data(RekordboxFixtures.rekordbox6.utf8))
        XCTAssertEqual(RekordboxMapping.cues(from: six.tracks[0], trackId: "sc", now: 1, writerId: "a").unsupported, 1)
    }

    func testMapsTempoKeyColourAndComment() throws {
        let library = try RekordboxXML.parse(Data(RekordboxFixtures.rekordbox6.utf8))
        let prep = RekordboxMapping.prep(from: library.tracks[0], trackId: "sc", now: 1, writerId: "a")
        XCTAssertEqual(prep.grid?.source, .rekordbox)
        XCTAssertEqual(prep.grid?.value.segments, [PrepTempoSegment(startMillis: 112, bpm: 124, beatsPerBar: 4, beatInBar: 1)])
        XCTAssertEqual(prep.key?.value.camelot, "8A")
        XCTAssertEqual(prep.colour?.value, 0xFF007F)
        XCTAssertEqual(prep.comment?.value, "Warm-up opener")
        let variable = RekordboxMapping.prep(from: library.tracks[1], trackId: "sc2", now: 1, writerId: "a")
        XCTAssertEqual(variable.grid?.value.segments.count, 2)
        XCTAssertEqual(variable.key?.value.camelot, "8A")
    }

    func testSemanticRoundTripThroughSounding() throws {
        for fixture in [RekordboxFixtures.rekordbox6, RekordboxFixtures.rekordbox7] {
            let library = try RekordboxXML.parse(Data(fixture.utf8))
            var items: [RekordboxExportItem] = []
            for (index, track) in library.tracks.enumerated() {
                let trackId = "sc\(index)"
                let prep = RekordboxMapping.prep(from: track, trackId: trackId, now: 1, writerId: "a")
                let cues = RekordboxMapping.cues(from: track, trackId: trackId, now: 1, writerId: "a").cues
                let link = TrackLink(trackId: trackId, title: track.name, artist: track.artist, durationMillis: CueTime.millis(fromSeconds: track.totalTime), rekordboxTrackId: track.trackId)
                items.append(RekordboxExportItem(link: link, fileURL: track.fileURL!, prep: prep, cues: cues, pendingSuggestions: 0))
            }
            let exported = try RekordboxXML.parse(RekordboxXML.write(RekordboxExport.library(items)))
            XCTAssertEqual(exported.tracks.count, library.tracks.count)
            for (original, roundTripped) in zip(library.tracks, exported.tracks) {
                XCTAssertEqual(roundTripped.trackId, original.trackId)
                XCTAssertEqual(roundTripped.location, original.location)
                XCTAssertEqual(roundTripped.tempos.map(\.bpm), original.tempos.map(\.bpm))
                XCTAssertEqual(roundTripped.tempos.map(\.battito), original.tempos.map(\.battito))
                for (a, b) in zip(roundTripped.tempos, original.tempos) { XCTAssertEqual(a.inizio, b.inizio, accuracy: 0.0011) }
                XCTAssertEqual(CamelotKey.parse(roundTripped.tonality ?? "")?.label, CamelotKey.parse(original.tonality ?? "")?.label)
                XCTAssertEqual(roundTripped.colour, original.colour)
                XCTAssertEqual(roundTripped.comments, original.comments)
                let supported = original.marks.filter { $0.type != 3 }
                XCTAssertEqual(roundTripped.marks.count, supported.count)
                let a = roundTripped.marks.sorted { ($0.start, $0.num) < ($1.start, $1.num) }
                let b = supported.sorted { ($0.start, $0.num) < ($1.start, $1.num) }
                for (lhs, rhs) in zip(a, b) {
                    XCTAssertEqual(lhs.start, rhs.start, accuracy: 0.0011)
                    XCTAssertEqual(lhs.num, rhs.num)
                    XCTAssertEqual(lhs.type, rhs.type)
                    XCTAssertEqual(lhs.end.map { ($0 * 1000).rounded() }, rhs.end.map { ($0 * 1000).rounded() })
                    if rhs.num >= 0 { XCTAssertEqual(lhs.rgb, rhs.rgb) }
                }
            }
        }
    }

    func testExportedLocationIsPercentEncodedFileURL() {
        XCTAssertEqual(
            RekordboxXML.location(for: URL(fileURLWithPath: "/Users/dj/Music/A & B (Edit).mp3")),
            "file://localhost/Users/dj/Music/A%20%26%20B%20%28Edit%29.mp3"
        )
    }
}

final class RekordboxImportTests: XCTestCase {

    func testImportNeverDeletesAndAsksBeforeReplacingUserValues() async throws {
        let store = makeStore()
        let library = try RekordboxXML.parse(Data(RekordboxFixtures.rekordbox6.utf8))
        let track = library.tracks[0]

        await store.upsert(CuePoint(trackId: "sc", kind: .hotCue, positionMillis: 60_000, hotCueIndex: 0, label: "Mine"))
        await store.addMemoryCue(trackId: "sc", positionMillis: 200_000, label: "Keep me")
        await store.setUserGrid(trackId: "sc", PrepGrid(segments: [PrepTempoSegment(startMillis: 90, bpm: 124)]))

        let plan = RekordboxImport.plan(
            pairs: [(track, "sc", track.name)],
            localPreps: await store.preps(forTracks: ["sc"]),
            localCues: await store.cues(forTracks: ["sc"]),
            writerId: "device-a"
        )
        XCTAssertEqual(Set(plan.conflicts.map(\.itemName)), ["Beat Grid", "Hot Cue A"])

        _ = await RekordboxImport.apply(plan, choices: [:], store: store)
        var cues = await store.cues(forTrack: "sc")
        XCTAssertTrue(cues.contains { $0.label == "Keep me" })
        XCTAssertEqual(cues.first { $0.hotCueIndex == 0 }?.label, "Mine")
        XCTAssertEqual(cues.first { $0.hotCueIndex == 1 }?.label, "Break")
        var prep = await store.prep(forTrack: "sc")
        XCTAssertEqual(prep?.grid?.source, .user)
        XCTAssertEqual(prep?.key?.value.camelot, "8A")

        let choices = Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, ImportChoice.useImported) })
        _ = await RekordboxImport.apply(plan, choices: choices, store: store)
        cues = await store.cues(forTrack: "sc")
        XCTAssertEqual(cues.first { $0.hotCueIndex == 0 }?.label, "Drop")
        XCTAssertTrue(cues.contains { $0.label == "Keep me" })
        prep = await store.prep(forTrack: "sc")
        XCTAssertEqual(prep?.grid?.source, .rekordbox)
        XCTAssertEqual(prep?.grid?.value.segments.first?.startMillis, 112)
    }

    func testReimportIsIdempotentAndReplacesUneditedImports() async throws {
        let store = makeStore()
        let library = try RekordboxXML.parse(Data(RekordboxFixtures.rekordbox7.utf8))
        let track = library.tracks[0]
        for _ in 0..<2 {
            let plan = RekordboxImport.plan(
                pairs: [(track, "sc", track.name)],
                localPreps: await store.preps(forTracks: ["sc"]),
                localCues: await store.cues(forTracks: ["sc"]),
                writerId: "device-a"
            )
            XCTAssertTrue(plan.conflicts.isEmpty)
            _ = await RekordboxImport.apply(plan, choices: [:], store: store)
        }
        let cues = await store.cues(forTrack: "sc")
        XCTAssertEqual(cues.count, 5)

        var moved = track
        moved.marks[1].start = 62.0
        let plan = RekordboxImport.plan(
            pairs: [(moved, "sc", moved.name)],
            localPreps: await store.preps(forTracks: ["sc"]),
            localCues: await store.cues(forTracks: ["sc"]),
            writerId: "device-a"
        )
        XCTAssertTrue(plan.conflicts.isEmpty)
        XCTAssertEqual(plan.cueCount, 1)
    }

    func testPreviewSortsMatchedAmbiguousAndMissing() throws {
        let library = try RekordboxXML.parse(Data(RekordboxFixtures.rekordbox6.utf8))
        let preview = RekordboxImport.preview(library, candidates: [
            MatchCandidate(trackId: "1", title: "Wavelength", artist: "Mara Lune", durationSeconds: 287),
            MatchCandidate(trackId: "2", title: "Late Night Drive", artist: "Theo Moss", durationSeconds: 341),
            MatchCandidate(trackId: "3", title: "Late Night Drive", artist: "Theo Moss", durationSeconds: 340),
        ])
        XCTAssertEqual(preview.matched.map(\.id), ["91234567"])
        XCTAssertEqual(preview.ambiguous.map(\.id), ["91234568"])
        XCTAssertEqual(preview.missing.map(\.id), ["91234569"])
        let playlists = RekordboxImport.playlists(from: library, trackIdByRekordboxId: ["91234567": "1"])
        XCTAssertEqual(playlists.map(\.name), ["Warm-up"])
        XCTAssertEqual(playlists.first?.trackIds, ["1"])
    }
}

final class ListeningSuggestionTests: XCTestCase {
    private let grid = BeatGrid(anchor: 0, beatPeriod: 0.5, confidence: 0.9)

    private func tally(_ device: String, _ hits: [(Int64, String)]) -> ListeningTally {
        var tally = ListeningTally(trackId: "t", deviceId: device)
        for (position, session) in hits { tally.record(positionMillis: position, sessionId: session) }
        return tally
    }

    func testThreeHitsAcrossTwoSessionsSuggestAMemoryCue() {
        let suggestions = ListeningSuggester.suggest(
            trackId: "t",
            tallies: [tally("a", [(64_000, "s1"), (64_000, "s1"), (64_000, "s2")])],
            grid: grid,
            duration: 300
        )
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.kind, .memory)
        XCTAssertEqual(suggestions.first?.positionMillis, 64_000)
        XCTAssertEqual(suggestions.first?.suggester, ListeningSuggester.identity)
        XCTAssertNil(suggestions.first?.promoted(writerId: "a").hotCueIndex)
    }

    func testBelowThresholdsSuggestsNothing() {
        XCTAssertTrue(ListeningSuggester.suggest(trackId: "t", tallies: [tally("a", [(64_000, "s1"), (64_000, "s1"), (64_000, "s1")])], grid: grid, duration: 300).isEmpty)
        XCTAssertTrue(ListeningSuggester.suggest(trackId: "t", tallies: [tally("a", [(64_000, "s1"), (64_000, "s2")])], grid: grid, duration: 300).isEmpty)
    }

    func testHitsWithinOneBarClusterAndSnapToTheDownbeat() {
        let suggestions = ListeningSuggester.suggest(
            trackId: "t",
            tallies: [tally("a", [(64_000, "s1"), (65_500, "s2")]), tally("b", [(63_000, "x1")])],
            grid: grid,
            duration: 300
        )
        XCTAssertEqual(suggestions.map(\.positionMillis), [64_000])
        XCTAssertTrue(ListeningSuggester.suggest(
            trackId: "t",
            tallies: [tally("a", [(64_000, "s1"), (70_000, "s2"), (76_000, "s3")])],
            grid: grid,
            duration: 300
        ).isEmpty)
    }

    func testDismissalsAndNearbyCuesSuppressWithinABar() {
        let tallies = [tally("a", [(64_000, "s1"), (64_000, "s2"), (64_000, "s3")])]
        let suggestion = ListeningSuggester.suggest(trackId: "t", tallies: tallies, grid: grid, duration: 300)[0]
        var moved = tallies
        moved[0].record(positionMillis: 66_000, sessionId: "s4")
        moved[0].record(positionMillis: 66_000, sessionId: "s5")
        let dismissal = CueDismissal(suggestion: suggestion, writerId: "a")
        let afterDismiss = ListeningSuggester.suggest(trackId: "t", tallies: moved, grid: grid, duration: 300, dismissals: [dismissal])
        XCTAssertTrue(afterDismiss.allSatisfy { abs($0.positionMillis - 64_000) > 2_000 })
        let cue = CuePoint(trackId: "t", kind: .hotCue, positionMillis: 64_500, hotCueIndex: 0)
        XCTAssertTrue(ListeningSuggester.suggest(trackId: "t", tallies: tallies, grid: grid, duration: 300, userCues: [cue]).isEmpty)
    }

    func testDevicesWriteOwnRowsAndReadersSumThem() async {
        let a = makeStore("device-a")
        await a.recordListening(trackId: "t", positionMillis: 64_000, sessionId: "s1")
        await a.recordListening(trackId: "t", positionMillis: 64_000, sessionId: "s2")
        let b = makeStore("device-b")
        await b.recordListening(trackId: "t", positionMillis: 64_000, sessionId: "x1")
        let fromB = await b.prepSyncRecords(changedSince: 0)
        XCTAssertEqual(fromB.map(\.kind), [.tally])
        let adopted = await a.adoptPrepRecords(fromB)
        XCTAssertEqual(adopted, 1)
        let fromA = await a.prepSyncRecords(changedSince: 0)
        let echoed = await b.adoptPrepRecords(fromA.filter { $0.recordName.hasSuffix("device-b") })
        XCTAssertEqual(echoed, 0)
        let tallies = await a.tallies(forTrack: "t")
        XCTAssertEqual(Set(tallies.map(\.deviceId)), ["device-a", "device-b"])
        let suggestions = await a.listeningSuggestions(forTrack: "t", grid: grid, duration: 300)
        XCTAssertEqual(suggestions.count, 1)
        let sheet = await a.sheet(for: CueSuggester.Input(trackId: "t", duration: 300, envelope: [], beatGrid: grid))
        XCTAssertEqual(sheet.suggestions.count, 1)
        XCTAssertTrue(sheet.hotSlotsAreUserOnly)
    }

    func testPrepSyncAdoptsRemoteGridButNotOverLock() async {
        let a = makeStore("device-a")
        let b = makeStore("device-b")
        await a.setUserGrid(trackId: "t", PrepGrid(segments: [PrepTempoSegment(startMillis: 0, bpm: 128)], locked: true))
        var analysis = TrackPrep(trackId: "t")
        analysis.grid = PrepField(PrepGrid(segments: [PrepTempoSegment(startMillis: 10, bpm: 64)]), source: .sounding, updatedAtMillis: CueTime.nowMillis() + 10_000, writerId: "device-b")
        await b.savePrep(analysis)
        _ = await a.adoptPrepRecords(await b.prepSyncRecords(changedSince: 0))
        let kept = await a.prep(forTrack: "t")
        XCTAssertEqual(kept?.grid?.value.bpm, 128)
        _ = await b.adoptPrepRecords(await a.prepSyncRecords(changedSince: 0))
        let adopted = await b.prep(forTrack: "t")
        XCTAssertEqual(adopted?.grid?.value.bpm, 128)
        XCTAssertEqual(adopted?.grid?.value.locked, true)
    }
}

private extension CueSheet {
    var hotSlotsAreUserOnly: Bool {
        entries.allSatisfy { $0.hotCueIndex == nil || !$0.isSuggestion }
    }
}

final class PrepGridEditTests: XCTestCase {
    private let base = PrepGrid(segments: [PrepTempoSegment(startMillis: 100, bpm: 120)])

    func testSetDownbeatAlignsTheNearestBeatAndMakesItBeatOne() {
        let edited = PrepGridEditor.setDownbeat(base, atMillis: 10_130)
        XCTAssertEqual(edited.segments.first?.startMillis, 130)
        XCTAssertTrue(edited.downbeatMillis(throughMillis: 20_000).contains(10_130))
        let grid = edited.beatGrid(durationSeconds: 60, confidence: 0.9)
        XCTAssertEqual(grid?.nearestBeat(to: 10.14) ?? 0, 10.13, accuracy: 0.001)
        XCTAssertEqual((grid?.firstDownbeat ?? 0).truncatingRemainder(dividingBy: 2), 0.13, accuracy: 0.001)
    }

    func testSetDownbeatOffTheBarShiftsThePhase() {
        let edited = PrepGridEditor.setDownbeat(base, atMillis: 1_100)
        XCTAssertTrue(edited.downbeatMillis(throughMillis: 5_000).contains(1_100))
        XCTAssertFalse(edited.downbeatMillis(throughMillis: 5_000).contains(100))
    }

    func testNudgeHalveDoubleAndLock() {
        XCTAssertEqual(PrepGridEditor.nudge(base, byMillis: -10).segments.first?.startMillis, 90)
        XCTAssertEqual(PrepGridEditor.halve(base).bpm, 60)
        XCTAssertEqual(PrepGridEditor.double(base).bpm, 240)
        XCTAssertEqual(PrepGridEditor.double(PrepGridEditor.double(base)).bpm, 240)
        let locked = PrepGridEditor.setLocked(base, true)
        XCTAssertTrue(PrepGridEditor.nudge(locked, byMillis: 5).locked)
        XCTAssertTrue(PrepGridEditor.halve(locked).locked)
    }

    func testVariableGridProducesBeatsAcrossSegments() {
        let grid = PrepGrid(segments: [
            PrepTempoSegment(startMillis: 0, bpm: 120),
            PrepTempoSegment(startMillis: 4_000, bpm: 60),
        ])
        let beats = grid.beats(throughMillis: 8_000).map(\.millis)
        XCTAssertEqual(beats, [0, 500, 1_000, 1_500, 2_000, 2_500, 3_000, 3_500, 4_000, 5_000, 6_000, 7_000])
        let beatGrid = grid.beatGrid(durationSeconds: 8, confidence: 0.9)
        XCTAssertEqual(beatGrid?.beats?.count, 12)
    }

    func testBeatGridRoundTripsThroughPrepGrid() {
        let measured = BeatGrid(anchor: 0.25, beatPeriod: 0.5, downbeatOffset: 2, confidence: 0.8)
        let prep = PrepGrid.from(measured)
        XCTAssertEqual(prep?.segments.first?.startMillis, 1_250)
        let back = prep?.beatGrid(durationSeconds: 60, confidence: 0.9)
        XCTAssertEqual(back?.firstDownbeat ?? 0, 1.25, accuracy: 0.001)
        XCTAssertEqual(back?.anchor ?? 0, 0.25, accuracy: 0.001)
    }
}

final class PrepMixHintTests: XCTestCase {
    private let grid = BeatGrid(anchor: 0, beatPeriod: 0.5, confidence: 0.7)

    func testCuesBecomeAutoMixHints() {
        let cues = [
            CuePoint(trackId: "t", kind: .memory, positionMillis: 128_000),
            CuePoint(trackId: "t", kind: .memory, positionMillis: 129_250),
            CuePoint(trackId: "t", kind: .hotCue, positionMillis: 32_000, hotCueIndex: 0, label: "Drop"),
            CuePoint(trackId: "t", kind: .hotCue, positionMillis: 48_000, hotCueIndex: 1, label: "Vocal"),
            CuePoint(trackId: "t", kind: .loop, positionMillis: 240_000, endMillis: 248_000),
        ]
        let hints = PrepMixHints.derive(cues: cues, suggestions: [], prep: nil, measuredGrid: grid, phraseBoundaries: [], duration: 300)
        XCTAssertEqual(hints.hints.filter { $0.role == .exit }.map(\.seconds), [128, 240])
        XCTAssertEqual(hints.hints.filter { $0.role == .entry }.map(\.seconds), [32])
        XCTAssertEqual(hints.extensionLoop, 240...248)
        XCTAssertNil(hints.grid)
    }

    func testSuggestionsCountHalf() {
        let suggestion = CueSuggestion(
            trackId: "t", kind: .memory, positionMillis: 64_000, endMillis: nil,
            suggester: ListeningSuggester.identity, confidence: 0.6, reasoning: "", snappedToGrid: true,
            label: "Often replayed", color: .memory
        )
        let hints = PrepMixHints.derive(cues: [], suggestions: [suggestion], prep: nil, measuredGrid: grid, phraseBoundaries: [], duration: 300)
        XCTAssertEqual(hints.hints.first?.confidence ?? 0, PrepMixHints.cueConfidence / 2, accuracy: 0.0001)
    }

    func testLockedGridRaisesConfidenceAndFeedsThePointFinder() {
        var prep = TrackPrep(trackId: "t")
        prep.grid = PrepField(PrepGrid(segments: [PrepTempoSegment(startMillis: 0, bpm: 120)], locked: true), source: .rekordbox)
        let hints = PrepMixHints.derive(cues: [], suggestions: [], prep: prep, measuredGrid: nil, phraseBoundaries: [], duration: 300)
        XCTAssertEqual(hints.grid?.confidence, PrepMixHints.trustedGridConfidence)
        var unlocked = prep
        unlocked.grid?.value.locked = false
        XCTAssertNil(PrepMixHints.derive(cues: [], suggestions: [], prep: unlocked, measuredGrid: nil, phraseBoundaries: [], duration: 300).grid)

        let features = TrackFeatures(
            trackId: "t", duration: 300, beatGrid: hints.grid, provenance: [.measuredBeatGrid, .measuredTempo],
            cueHints: [CueHint(seconds: 256, role: .exit, confidence: 0.9), CueHint(seconds: 16, role: .entry, confidence: 0.9)]
        )
        let profile = DJProfile.automaticDJ
        XCTAssertTrue(DJPointFinder.exitCandidates(in: features, profile: profile).contains { abs($0.seconds - 256) < 0.01 })
        XCTAssertTrue(DJPointFinder.entryCandidates(in: features, profile: profile).contains { abs($0.seconds - 16) < 0.01 })
    }
}

#if DEBUG
final class CueSelfTestSuite: XCTestCase {
    func testCueModel() async {
        let report = await CueSelfTest.run()
        XCTAssertTrue(report.failures.isEmpty, report.summary)
    }

    func testCueSync() async {
        let report = await CueSyncSelfTest.run()
        XCTAssertTrue(report.failures.isEmpty, report.summary)
    }

    @MainActor
    func testCueBoard() async {
        let report = await CueBoardSelfTest.run()
        XCTAssertTrue(report.failures.isEmpty, report.summary)
    }
}
#endif
