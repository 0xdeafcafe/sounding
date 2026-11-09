import Foundation
import XCTest
@testable import SoundingTV

final class RekordboxShareTests: XCTestCase {

    private func beats(bpm: Double = 125, count: Int = 512, anchor: Double = 0.1) -> [ANLZBeat] {
        (0 ..< count).map { ANLZBeat(beatNumber: UInt16($0 % 4 + 1), tempo: UInt16(bpm * 100), timeMillis: UInt32(((anchor + Double($0) * 60 / bpm) * 1000).rounded())) }
    }

    private func makeShare(_ tracks: [(name: String, seconds: Double, phrases: Bool, cues: Bool)]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "RekordboxShare-\(UUID().uuidString)/USBANLZ", directoryHint: .isDirectory)
        for (index, track) in tracks.enumerated() {
            let folder = root.appending(path: String(format: "%03x/%08x-aaaa-4bbb-8ccc-%012x", index, index, index), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let grid = beats()
            var hot = ANLZCue(hotCue: 1, timeMillis: grid[32].timeMillis)
            hot.comment = "Drop"
            hot.colorRed = 0x28
            hot.colorGreen = 0xE2
            hot.colorBlue = 0x14
            var loop = ANLZCue(isLoop: true, timeMillis: grid[64].timeMillis, loopTimeMillis: grid[96].timeMillis)
            loop.comment = "Out loop"
            let memory = ANLZCue(timeMillis: grid[16].timeMillis)
            var extTags: [ANLZTag] = [.path("?/\(track.name)"), .waveformDetail([UInt8](repeating: 0x20, count: Int(track.seconds * 150)))]
            if track.cues {
                extTags.append(.extendedCueList(ANLZCueList(kind: .memory, cues: [memory, loop])))
                extTags.append(.extendedCueList(ANLZCueList(kind: .hotCues, cues: [hot])))
            }
            if track.phrases {
                let kinds: [UInt16] = [1, 2, 5, 3, 5, 6]
                let phrases = kinds.enumerated().map { ANLZPhrase(index: UInt16($0.offset + 1), beat: UInt16($0.offset * 64 + 1), kind: $0.element) }
                extTags.append(.songStructure(ANLZSongStructure(mood: 1, endBeat: 512, phrases: phrases)))
            }
            try ANLZCodec.write(ANLZFile(tags: [.path("?/\(track.name)"), .beatGrid(grid)])).write(to: folder.appending(path: "ANLZ0000.DAT"))
            try ANLZCodec.write(ANLZFile(tags: extTags)).write(to: folder.appending(path: "ANLZ0000.EXT"))
            try ANLZCodec.write(ANLZFile(tags: [.path("?/\(track.name)"), .threeBandPreview([UInt8](repeating: 9, count: 3600))])).write(to: folder.appending(path: "ANLZ0000.2EX"))
            try Data([0x81, 0xA9]).write(to: folder.appending(path: "ANLZ0000.3EX"))
        }
        return root
    }

    // MARK: - Scanning

    func testScanReadsGridCuesPhrasesAndFileName() throws {
        let root = try makeShare([("Shake - Mainphase.m4a", 245, true, true), ("Café Tune.mp3", 300, false, false)])
        let scan = RekordboxShareScanner.scan(root: root.path)
        XCTAssertEqual(scan.entries.count, 2)
        XCTAssertEqual(scan.unreadable, 0)
        let first = try XCTUnwrap(scan.entries.first { $0.fileName == "Shake - Mainphase.m4a" })
        XCTAssertEqual(first.stem, "Shake - Mainphase")
        XCTAssertEqual(try XCTUnwrap(first.durationSeconds), 245, accuracy: 0.01)
        XCTAssertEqual(first.analysis.tempos.count, 1)
        XCTAssertEqual(first.analysis.tempos[0].bpm, 125, accuracy: 0.001)
        XCTAssertEqual(first.hotCueCount, 1)
        XCTAssertEqual(first.loopCount, 1)
        XCTAssertEqual(first.phrases.map(\.kind), [1, 2, 5, 3, 5, 6])
        XCTAssertEqual(first.phrases.map { RekordboxPhraseCode(mood: $0.mood, kind: $0.kind).label }, ["Intro", "Up", "Chorus", "Down", "Chorus", "Outro"])
        XCTAssertEqual(first.phrases[1].startMillis, Int64(beats()[64].timeMillis))
        XCTAssertTrue(first.hasThreeBandWaveform)
        XCTAssertEqual(scan.withPhrases, 1)
        XCTAssertEqual(scan.withCues, 1)
        XCTAssertTrue(scan.entries.contains { $0.fileName == "Café Tune.mp3".precomposedStringWithCanonicalMapping })
    }

    func testScanOnlyReadsAndNeverOpensEmbeddings() throws {
        let root = try makeShare([("One.mp3", 200, true, true)])
        let recorder = RecordingIO(base: DJStickPOSIXIO())
        _ = RekordboxShareScanner.scan(root: root.path, io: recorder)
        XCTAssertFalse(recorder.operations.isEmpty)
        XCTAssertTrue(recorder.operations.allSatisfy { $0.hasPrefix("read ") || $0.hasPrefix("stat ") }, "\(recorder.operations)")
        XCTAssertFalse(recorder.operations.contains { $0.uppercased().hasSuffix(".3EX") })
    }

    func testCorruptFilesAreCountedNotFatal() throws {
        let root = try makeShare([("Good.mp3", 200, false, false)])
        let bad = root.appending(path: "fff/bad", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("not anlz".utf8).write(to: bad.appending(path: "ANLZ0000.DAT"))
        let scan = RekordboxShareScanner.scan(root: root.path)
        XCTAssertEqual(scan.entries.count, 1)
        XCTAssertEqual(scan.unreadable, 1)
    }

    func testAnalysisRootIsFoundFromAnyParent() {
        let existing: Set<String> = ["/Users/dj/Library/Pioneer/rekordbox/share/PIONEER/USBANLZ"]
        let exists: (String) -> Bool = { existing.contains($0) }
        XCTAssertEqual(RekordboxShareLayout.analysisRoot(within: "/Users/dj/Library/Pioneer/rekordbox", exists: exists), existing.first)
        XCTAssertEqual(RekordboxShareLayout.analysisRoot(within: "/Users/dj/Library/Pioneer", exists: exists), existing.first)
        XCTAssertEqual(RekordboxShareLayout.analysisRoot(within: "/Users/dj/Library/Pioneer/rekordbox/share/PIONEER/USBANLZ/", exists: exists), existing.first)
        XCTAssertNil(RekordboxShareLayout.analysisRoot(within: "/Users/dj/Music", exists: exists))
        XCTAssertEqual(RekordboxShareLayout.defaultRoot(home: "/Users/dj/"), existing.first)
    }

    // MARK: - Matching

    private func key(_ name: String, seconds: Double?, id: String? = nil, richness: Int = 1) -> RekordboxShareKey {
        RekordboxShareKey(id: id ?? name, fileName: name, devicePath: "?/\(name)", durationSeconds: seconds, richness: richness)
    }

    func testMatchesByFileNameAndDuration() {
        let files = [
            RekordboxShareLocalFile(trackId: "-1", path: "/Users/dj/Music/SoundCloud/Shake - Mainphase.m4a", durationSeconds: 245),
            RekordboxShareLocalFile(trackId: "-2", path: "/Users/dj/Music/A/Dup.mp3", durationSeconds: 200),
            RekordboxShareLocalFile(trackId: "-3", path: "/Users/dj/Music/B/Dup.mp3", durationSeconds: 320),
            RekordboxShareLocalFile(trackId: "-4", path: "/Users/dj/Music/C/Same.mp3", durationSeconds: nil),
            RekordboxShareLocalFile(trackId: "-5", path: "/Users/dj/Music/D/Same.mp3", durationSeconds: nil),
        ]
        let candidates = [MatchCandidate(trackId: "sc-1", title: "Glue", artist: "Bicep", durationSeconds: 269)]
        let matches = RekordboxShareMatcher.match(
            [key("SHAKE - MAINPHASE.m4a", seconds: 244), key("Dup.mp3", seconds: 321), key("Same.mp3", seconds: 200), key("Bicep - Glue.wav", seconds: 268.5), key("Nobody.mp3", seconds: 100)],
            files: files,
            candidates: candidates
        )
        XCTAssertEqual(matches.map(\.outcome), [.fileName("-1"), .fileName("-3"), .ambiguous, .title("sc-1"), .missing])
        let summary = RekordboxShareMatcher.summary(matches)
        XCTAssertEqual(summary.matched, 3)
        XCTAssertEqual(summary.ambiguous, 1)
        XCTAssertEqual(summary.missing, 1)
    }

    func testWrongDurationIsNotAFileMatch() {
        let files = [RekordboxShareLocalFile(trackId: "-1", path: "/m/Track.mp3", durationSeconds: 200)]
        XCTAssertEqual(RekordboxShareMatcher.match([key("Track.mp3", seconds: 260)], files: files)[0].outcome, .missing)
    }

    func testXMLLocationGivesAFullPathMatch() {
        let files = [
            RekordboxShareLocalFile(trackId: "-1", path: "/Users/dj/Music/A/Tune.mp3", durationSeconds: 200),
            RekordboxShareLocalFile(trackId: "-2", path: "/Users/dj/Music/B/Tune.mp3", durationSeconds: 200),
        ]
        let xml = RekordboxLibrary(tracks: [
            RekordboxTrack(trackId: "77", attributes: ["Name": "Tune", "Artist": "Someone", "TotalTime": "200", "Location": "file://localhost/Users/dj/Music/B/Tune.mp3", "Tonality": "Am"], tempos: [], marks: []),
        ])
        let matches = RekordboxShareMatcher.match([key("Tune.mp3", seconds: 200)], files: files, xml: xml)
        XCTAssertEqual(matches[0].outcome, .path("-2"))
        XCTAssertEqual(matches[0].xml?.tonality, "Am")
    }

    func testDuplicateEntriesForOneFileKeepTheRichest() {
        let files = [RekordboxShareLocalFile(trackId: "-9", path: "/m/Need In Me.m4a", durationSeconds: 300)]
        let matches = RekordboxShareMatcher.match([key("Need In Me.m4a", seconds: 300, id: "a", richness: 1), key("Need In Me.m4a", seconds: 300, id: "b", richness: 9)], files: files)
        XCTAssertEqual(matches.first { $0.key.id == "b" }?.outcome, .fileName("-9"))
        XCTAssertEqual(matches.first { $0.key.id == "a" }?.outcome, .ambiguous)
    }

    // MARK: - Phrases

    func testPhraseCodesMapToSectionsAndLabels() {
        let high = [1, 2, 3, 5, 6].map { RekordboxPhraseCode(mood: 1, kind: $0) }
        XCTAssertEqual(high.map(\.label), ["Intro", "Up", "Down", "Chorus", "Outro"])
        XCTAssertEqual(high.map(\.sectionKind), [.intro, .buildup, .breakdown, .drop, .outro])
        let low = [1, 3, 6, 8, 9, 10].map { RekordboxPhraseCode(mood: 3, kind: $0) }
        XCTAssertEqual(low.map(\.label), ["Intro", "Verse 1", "Verse 2", "Bridge", "Chorus", "Outro"])
        XCTAssertEqual(low.map(\.sectionKind), [.intro, .bridge, .bridge, .breakdown, .drop, .outro])
    }

    func testRekordboxPhrasesExportBackToTheSameKinds() {
        for (mood, kinds) in [(1, [1, 2, 5, 3, 6]), (2, [1, 3, 9, 8, 10]), (3, [1, 2, 5, 8, 9, 10])] {
            let phrases = kinds.enumerated().map { RekordboxSharePhrase(startMillis: Int64(100 + $0.offset * 30_720), mood: mood, kind: $0.element) }
            let exported = DJExportPhrases(rekordbox: phrases, durationSeconds: 245)
            XCTAssertEqual(exported?.mood?.rawValue, UInt16(mood))
            guard let exported else { continue }
            let structure = DJAnalysisMapping.songStructure(exported, beats: beats(), duration: 245)
            XCTAssertEqual(structure?.phrases.map { Int($0.kind) }, kinds, "mood \(mood)")
            XCTAssertEqual(structure.map { Int($0.mood) }, mood)
        }
    }

    func testMixedMoodsAreNotExportedAsRekordboxPhrases() {
        let phrases = [RekordboxSharePhrase(startMillis: 0, mood: 1, kind: 1), RekordboxSharePhrase(startMillis: 30_000, mood: 2, kind: 9)]
        XCTAssertNil(DJExportPhrases(rekordbox: phrases, durationSeconds: 200))
    }

    func testOldPrepPhrasesStillDecode() throws {
        let json = #"{"startMillis":100,"kind":"drop","mood":"vocal"}"#
        let phrase = try JSONDecoder().decode(PrepPhrase.self, from: Data(json.utf8))
        XCTAssertNil(phrase.rekordbox)
        XCTAssertEqual(phrase.kind, .drop)
        let coded = PrepPhrase(startMillis: 5, kind: .drop, mood: nil, rekordbox: RekordboxPhraseCode(mood: 1, kind: 5))
        XCTAssertEqual(try JSONDecoder().decode(PrepPhrase.self, from: JSONEncoder().encode(coded)), coded)
    }

    func testImportedPhrasesLandWithRekordboxSourceAndUserEditsWin() async throws {
        let store = CueStore(directory: FileManager.default.temporaryDirectory.appending(path: "ShareStore-\(UUID().uuidString)"), writerId: "test")
        let code = RekordboxPhraseCode(mood: 1, kind: 2)
        var incoming = TrackPrep(trackId: "-42")
        incoming.phrases = PrepField([PrepPhrase(startMillis: 0, kind: .intro, mood: nil, rekordbox: RekordboxPhraseCode(mood: 1, kind: 1)), PrepPhrase(startMillis: 30_000, kind: code.sectionKind, mood: nil, rekordbox: code)], source: .rekordbox, updatedAtMillis: 5, writerId: "test")
        await store.applyCandidatePrep(incoming)
        let stored = await store.prep(forTrack: "-42")
        let prep = try XCTUnwrap(stored)
        XCTAssertEqual(prep.phrases?.source, .rekordbox)
        XCTAssertEqual(prep.phrases?.value.last?.rekordbox, code)

        var user = prep
        user.phrases = PrepField([PrepPhrase(startMillis: 0, kind: .drop, mood: nil)], source: .user, updatedAtMillis: 6, writerId: "test")
        await store.savePrep(user)
        let blocked = await store.applyCandidatePrep(incoming).blocked
        XCTAssertEqual(blocked, [.phrases])
        let after = await store.prep(forTrack: "-42")
        XCTAssertEqual(after?.phrases?.source, .user)
    }

    // MARK: - Keys

    func testKeyAgreement() {
        XCTAssertEqual(RekordboxKeyAgreement.relation(ours: "8A", theirs: "Am"), .exact)
        XCTAssertEqual(RekordboxKeyAgreement.relation(ours: "8B", theirs: "Am"), .relative)
        XCTAssertEqual(RekordboxKeyAgreement.relation(ours: "9A", theirs: "Am"), .neighbour)
        XCTAssertEqual(RekordboxKeyAgreement.relation(ours: "12A", theirs: "1A"), .neighbour)
        XCTAssertEqual(RekordboxKeyAgreement.relation(ours: "3B", theirs: "Am"), .other)
        XCTAssertNil(RekordboxKeyAgreement.relation(ours: "", theirs: "Am"))
        var agreement = RekordboxKeyAgreement()
        agreement.add(ours: "8A", theirs: "Am")
        agreement.add(ours: "8B", theirs: "Am")
        agreement.add(ours: "3B", theirs: "Am")
        agreement.add(ours: "8A", theirs: "nonsense")
        XCTAssertEqual(agreement.compared, 3)
        XCTAssertEqual(agreement.exactRate, 1.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(agreement.closeRate, 2.0 / 3, accuracy: 0.0001)
    }
}
