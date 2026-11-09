import Foundation
import XCTest
@testable import SoundingTV

private final class PathRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func record(_ path: String) {
        lock.lock()
        stored.append(path)
        lock.unlock()
    }
}

final class RekordboxFolderImportTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "RekordboxFolder-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url)
        return url
    }

    private func write(_ relative: String, _ contents: String, in root: URL) throws {
        let url = root.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    private func makeStore() -> CueStore {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "RekordboxFolderStore-\(UUID().uuidString)", directoryHint: .isDirectory)
        directories.append(directory)
        return CueStore(directory: directory, writerId: "mac")
    }

    private func isEncrypted(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".db") || lower.hasSuffix(".edb")
    }

    // MARK: - Classification

    func testClassifiesExportsMusicAndTheRekordboxFolder() throws {
        let root = try folder()
        try write("Exports/rekordbox.xml", RekordboxFixtures.rekordbox6, in: root)
        try write("Exports/notes.xml", "<plist></plist>", in: root)
        try write("Music/Mara Lune - Wavelength.mp3", "x", in: root)
        try write("Music/._Mara Lune - Wavelength.mp3", "x", in: root)
        try write("Library/Pioneer/rekordbox/master.db", "x", in: root)
        try write("Library/Pioneer/rekordbox/master.backup.db", "x", in: root)
        try write("Library/Pioneer/rekordbox/datafile.edb", "x", in: root)
        try write("Library/Pioneer/rekordbox/masterPlaylists6.xml", "<MASTER_PLAYLIST/>", in: root)
        try write("Library/Pioneer/rekordbox/share/PIONEER/USBANLZ/P000/00000001/ANLZ0000.DAT", "x", in: root)
        try write("USB/PIONEER/rekordbox/export.pdb", "x", in: root)
        try write("USB/PIONEER/USBANLZ/P001/00000001/ANLZ0000.DAT", "x", in: root)
        try write("USB/Contents/Artist/Track.mp3", "x", in: root)

        var sniffed: [String] = []
        let base = root.path
        let found = RekordboxFolderClassifier.classify(root: base, sniff: { path in
            sniffed.append(path)
            return RekordboxFolderLayout.looksLikeRekordboxXML(path)
        })

        XCTAssertEqual(found.xmlFiles, [base + "/Exports/rekordbox.xml"])
        XCTAssertEqual(found.stickRoots, [base + "/USB"])
        XCTAssertEqual(found.analysisRoots, [base + "/Library/Pioneer/rekordbox/share/PIONEER/USBANLZ"])
        XCTAssertEqual(found.appDataRoots, [base + "/Library/Pioneer/rekordbox"])
        XCTAssertEqual(found.encryptedDatabases, 3)
        XCTAssertEqual(found.audioFiles, [base + "/Music/Mara Lune - Wavelength.mp3", base + "/USB/Contents/Artist/Track.mp3"])
        XCTAssertFalse(found.needsExport)
        XCTAssertFalse(sniffed.contains(where: isEncrypted))
    }

    func testOnlyEncryptedDatabasesAskForAnExportAndAreNeverRead() throws {
        let root = try folder()
        for name in ["master.db", "master.backup2.db", "datafile.edb", "networkAnalyze6.db"] {
            try write(name, "SQLite format 3", in: root)
        }
        var sniffed: [String] = []
        let found = RekordboxFolderClassifier.classify(root: root.path, sniff: { path in
            sniffed.append(path)
            return false
        })
        XCTAssertTrue(found.needsExport)
        XCTAssertEqual(found.encryptedDatabases, 4)
        XCTAssertTrue(found.xmlFiles.isEmpty)
        XCTAssertTrue(sniffed.isEmpty)

        let reads = PathRecorder()
        let readers = RekordboxFolderReaders(
            xml: { path in reads.record(path); return nil },
            stick: { path in reads.record(path); return nil },
            analysis: { path in reads.record(path); return RekordboxFolderAnalysis() }
        )
        let scan = RekordboxFolderScanner.scan(found, readers: readers)
        XCTAssertTrue(scan.tracks.isEmpty)
        XCTAssertTrue(reads.paths.isEmpty)
    }

    func testChoosingTheStickPioneerFolderFindsTheWholeStick() throws {
        let root = try folder()
        try write("STICK/PIONEER/rekordbox/export.pdb", "x", in: root)
        let found = RekordboxFolderClassifier.classify(root: root.path + "/STICK/PIONEER")
        XCTAssertEqual(found.stickRoots, [root.path + "/STICK"])
        XCTAssertTrue(found.stickOutsideSelection)
        XCTAssertTrue(found.analysisRoots.isEmpty)
    }

    // MARK: - XML and loose files

    private func xmlFolder() throws -> URL {
        let root = try folder()
        try write("Music/Mara Lune - Wavelength.mp3", "x", in: root)
        try write("Music/Late Night Drive.wav", "x", in: root)
        try write("Music/Low Sun - Somebody Else & Me.mp3", "x", in: root)
        let music = RekordboxXML.location(for: root.appending(path: "Music", directoryHint: .isDirectory))
        let xml = RekordboxFixtures.rekordbox6.replacingOccurrences(
            of: "file://localhost/Users/dj/Music/DJ/",
            with: music.hasSuffix("/") ? music : music + "/"
        )
        try write("rekordbox.xml", xml, in: root)
        return root
    }

    private func matches(in root: URL) -> (scan: RekordboxFolderScan, matches: [RekordboxFolderMatch]) {
        let found = RekordboxFolderClassifier.classify(root: root.path)
        let scan = RekordboxFolderScanner.scan(found, readers: .xmlOnly)
        let files = RekordboxFolderFiles.localFiles(found.audioFiles, roots: [RekordboxFolderRoot(folderID: "folder", path: root.path)])
        let matched = RekordboxFolderMatcher.match(scan.tracks, files: files, local: RekordboxFolderFiles.candidates(files))
        return (scan, matched)
    }

    func testXMLTracksMatchFilesByPathThenTitle() throws {
        let root = try xmlFolder()
        let result = matches(in: root)
        XCTAssertEqual(result.scan.tracks.count, 3)
        XCTAssertEqual(result.scan.playlists.map(\.fullPath), ["Warm-up", "Gigs/Friday"])

        let byName = Dictionary(uniqueKeysWithValues: result.matches.map { ($0.item.track.name, $0.outcome) })
        let mara = LocalMusicScanner.trackID(folderID: "folder", relativePath: "Music/Mara Lune - Wavelength.mp3")
        XCTAssertEqual(byName["Wavelength"], .path(mara))
        if case .path = byName["Late Night Drive (Original Mix)"] {} else { XCTFail("expected a path match") }
        let lowSun = LocalMusicScanner.trackID(folderID: "folder", relativePath: "Music/Low Sun - Somebody Else & Me.mp3")
        XCTAssertEqual(byName["Somebody Else & Me"], .title(lowSun))

        let summary = RekordboxFolderMatcher.summary(result.scan, matches: result.matches, newAudioFiles: 3)
        XCTAssertEqual(summary.byFile, 2)
        XCTAssertEqual(summary.byTitle, 1)
        XCTAssertEqual(summary.notFound, 0)
    }

    func testFileNameMatchesWhenRekordboxPointsElsewhere() throws {
        let root = try folder()
        try write("Crate/Mara Lune - Wavelength.mp3", "x", in: root)
        try write("rekordbox.xml", RekordboxFixtures.rekordbox6, in: root)
        let result = matches(in: root)
        let mara = LocalMusicScanner.trackID(folderID: "folder", relativePath: "Crate/Mara Lune - Wavelength.mp3")
        XCTAssertEqual(result.matches.first { $0.item.track.name == "Wavelength" }?.outcome, .fileName(mara))
        XCTAssertEqual(result.matches.filter { $0.outcome == .missing }.count, 2)
    }

    func testImportingTheSameFolderTwiceUpdatesAndNeverDuplicates() async throws {
        let root = try xmlFolder()
        let store = makeStore()

        func importOnce() async -> RekordboxFolderResult {
            let result = matches(in: root)
            let plan = await RekordboxFolderImporter.plan(result.matches, store: store)
            return await RekordboxFolderImporter.apply(plan, choices: [:], matches: result.matches, playlists: result.scan.playlists, store: store)
        }

        let first = await importOnce()
        XCTAssertEqual(first.tracks, 3)
        XCTAssertEqual(first.cues, 5)
        XCTAssertEqual(first.playlists, 2)

        let mara = LocalMusicScanner.trackID(folderID: "folder", relativePath: "Music/Mara Lune - Wavelength.mp3")
        let afterFirst = await store.cues(forTrack: mara).filter { !$0.isDeleted }
        XCTAssertEqual(afterFirst.count, 4)
        let firstPlaylists = await store.rekordboxPlaylists()
        XCTAssertEqual(firstPlaylists.map(\.name), ["Warm-up", "Friday"])
        XCTAssertEqual(firstPlaylists.last?.path, ["Gigs"])
        let link = await store.link(forTrack: mara)
        XCTAssertEqual(link?.rekordboxTrackId, "91234567")
        let prep = await store.prep(forTrack: mara)
        XCTAssertEqual(prep?.key?.value.camelot, "8A")

        let second = await importOnce()
        XCTAssertEqual(second.cues, 0)
        XCTAssertEqual(second.playlists, 2)
        let afterSecond = await store.cues(forTrack: mara).filter { !$0.isDeleted }
        XCTAssertEqual(afterSecond.count, 4)
        let secondPlaylists = await store.rekordboxPlaylists()
        XCTAssertEqual(secondPlaylists.count, 2)
        XCTAssertEqual(secondPlaylists.first?.trackIds.count, 2)
    }

    func testPlaylistMergeReplacesByPathAndKeepsOthers() {
        let existing = [
            RekordboxPlaylistRecord(id: "0#Old", name: "Old", path: [], trackIds: ["a"]),
            RekordboxPlaylistRecord(id: "1#Warm-up", name: "Warm-up", path: [], trackIds: ["x"]),
        ]
        let incoming = [
            RekordboxPlaylistRecord(id: "rekordbox#Warm-up", name: "Warm-up", path: [], trackIds: ["y"]),
            RekordboxPlaylistRecord(id: "rekordbox#Gigs/Friday", name: "Friday", path: ["Gigs"], trackIds: ["z"]),
        ]
        let merged = RekordboxFolderImporter.merged(existing: existing, incoming: incoming)
        XCTAssertEqual(merged.map(\.name), ["Old", "Warm-up", "Friday"])
        XCTAssertEqual(merged[1].trackIds, ["y"])
        XCTAssertEqual(RekordboxFolderImporter.merged(existing: merged, incoming: incoming), merged)
    }

    // MARK: - USB export and analysis

    func testStickTracksCarryTheirPrepAndFileOnTheDrive() async throws {
        let stick = RekordboxFolderStick(
            tracks: [RekordboxFolderStickTrack(
                id: 7,
                title: "Wavelength",
                artist: "Mara Lune",
                durationSeconds: 287,
                bpm: 124,
                keyName: "8A",
                colourId: 1,
                rating: 4,
                filePath: "/Contents/Mara Lune/Wavelength.mp3",
                tempos: [RekordboxTempo(inizio: 0.112, bpm: 124, metro: "4/4", battito: 1)],
                marks: [RekordboxMark(name: "Drop", type: 0, start: 62.048, end: nil, num: 0, red: 40, green: 226, blue: 20)]
            )],
            playlists: [RekordboxFolderPlaylist(path: ["Gigs"], name: "Friday", trackKeys: ["7"])]
        )
        let classification = RekordboxFolderClassification(root: "/Volumes/STICK", stickRoots: ["/Volumes/STICK"])
        let readers = RekordboxFolderReaders(xml: { _ in nil }, stick: { _ in stick }, analysis: { _ in RekordboxFolderAnalysis() })
        let scan = RekordboxFolderScanner.scan(classification, readers: readers)

        let item = try XCTUnwrap(scan.tracks.first)
        XCTAssertEqual(item.filePath, "/Volumes/STICK/Contents/Mara Lune/Wavelength.mp3")
        XCTAssertEqual(item.track.attributes["Colour"], "0xFF007F")
        XCTAssertEqual(item.track.attributes["Rating"], "204")
        XCTAssertNil(item.rekordboxId)
        XCTAssertEqual(scan.playlists.first?.trackKeys, ["usb:0:7"])

        let files = [RekordboxShareLocalFile(trackId: "-42", path: "/Volumes/STICK/Contents/Mara Lune/Wavelength.mp3", durationSeconds: nil)]
        let matched = RekordboxFolderMatcher.match(scan.tracks, files: files)
        XCTAssertEqual(matched.first?.outcome, .path("-42"))

        let store = makeStore()
        let plan = await RekordboxFolderImporter.plan(matched, store: store)
        let result = await RekordboxFolderImporter.apply(plan, choices: [:], matches: matched, playlists: scan.playlists, store: store)
        XCTAssertEqual(result.cues, 1)
        let cue = await store.cues(forTrack: "-42").first { $0.kind == .hotCue }
        XCTAssertEqual(cue?.label, "Drop")
        let prep = await store.prep(forTrack: "-42")
        XCTAssertEqual(prep?.colour?.value, 0xFF007F)
        XCTAssertEqual(prep?.key?.value.camelot, "8A")
        let playlists = await store.rekordboxPlaylists()
        XCTAssertEqual(playlists.first?.trackIds, ["-42"])
    }

    func testExportPDBFixtureFeedsTheScanner() throws {
        let root = try DJStickFixture.makeStick()
        defer { DJStickFixture.remove(root) }
        let classification = RekordboxFolderClassifier.classify(root: root.path)
        XCTAssertEqual(classification.stickRoots, [root.path])
        XCTAssertTrue(classification.analysisRoots.isEmpty)

        let readers = RekordboxFolderReaders(
            xml: { _ in nil },
            stick: { path in
                guard let library = try? DJStickLoader.load(root: path).library else { return nil }
                let tracks = library.tracks.map { track in
                    let analysis = DJStickLoader.analysis(for: track, root: path)
                    return RekordboxFolderStickTrack(
                        id: track.id,
                        title: track.title,
                        artist: track.artist,
                        durationSeconds: track.durationSeconds,
                        bpm: track.bpm,
                        keyName: track.keyName,
                        colourId: track.colourId,
                        rating: track.rating,
                        filePath: track.filePath,
                        tempos: (analysis?.tempos ?? []).map { RekordboxTempo(inizio: $0.startSeconds, bpm: $0.bpm, metro: "4/4", battito: $0.beatInBar) }
                    )
                }
                let playlists = library.playlists.map {
                    RekordboxFolderPlaylist(path: $0.path, name: $0.name, trackKeys: $0.trackIds.map { String($0) })
                }
                return RekordboxFolderStick(tracks: tracks, playlists: playlists)
            },
            analysis: { _ in RekordboxFolderAnalysis() }
        )
        let scan = RekordboxFolderScanner.scan(classification, readers: readers)
        XCTAssertFalse(scan.tracks.isEmpty)
        let demo = try XCTUnwrap(scan.tracks.first { $0.id == "usb:0:1" })
        XCTAssertEqual(demo.track.name, "Demo Track 1")
        XCTAssertEqual(demo.track.artist, "Loopmasters")
        XCTAssertEqual(try XCTUnwrap(demo.track.tempos.first?.bpm), 128, accuracy: 0.001)
        XCTAssertEqual(demo.filePath?.hasPrefix(root.path + "/"), true)
        let sub = try XCTUnwrap(scan.playlists.first { $0.name == "Sub Playlist" })
        XCTAssertEqual(sub.path, ["Folder"])
        XCTAssertEqual(sub.trackKeys.first, "usb:0:1")
    }

    func testAnalysisFillsTheGridAndPhrasesOfAnXMLTrackWithTheSameFile() throws {
        let classification = RekordboxFolderClassification(root: "/x", xmlFiles: ["/x/rekordbox.xml"], analysisRoots: ["/x/USBANLZ"])
        let bare = RekordboxXML.write(RekordboxLibrary(tracks: [RekordboxTrack(
            trackId: "5",
            attributes: ["Name": "Wavelength", "Artist": "Mara Lune", "TotalTime": "287", "Location": "file://localhost/Users/dj/Music/Mara%20Lune%20-%20Wavelength.mp3"],
            tempos: [],
            marks: []
        )]))
        let entry = RekordboxFolderAnalysisEntry(
            id: "P000/00000001/ANLZ0000",
            devicePath: "?/Mara Lune - Wavelength.mp3",
            fileName: "Mara Lune - Wavelength.mp3",
            track: RekordboxTrack(
                trackId: "anlz:P000",
                attributes: ["Name": "Mara Lune - Wavelength", "TotalTime": "287"],
                tempos: [RekordboxTempo(inizio: 0.112, bpm: 124, metro: "4/4", battito: 1)],
                marks: []
            ),
            phrases: [
                PrepPhrase(startMillis: 112, kind: .intro, mood: nil),
                PrepPhrase(startMillis: 31_080, kind: .drop, mood: nil),
            ],
            hasWaveform: true
        )
        let orphan = RekordboxFolderAnalysisEntry(
            id: "P000/00000002/ANLZ0000",
            devicePath: "/Users/dj/Music/Unknown.mp3",
            fileName: "Unknown.mp3",
            track: RekordboxTrack(trackId: "anlz:P001", attributes: ["Name": "Unknown", "TotalTime": "200"], tempos: [], marks: []),
            phrases: [],
            hasWaveform: false
        )
        let readers = RekordboxFolderReaders(
            xml: { _ in bare },
            stick: { _ in nil },
            analysis: { _ in RekordboxFolderAnalysis(entries: [entry, orphan], unreadable: 0) }
        )
        let scan = RekordboxFolderScanner.scan(classification, readers: readers)
        XCTAssertEqual(scan.tracks.count, 2)
        let merged = try XCTUnwrap(scan.tracks.first { $0.origin == .xml })
        XCTAssertEqual(merged.track.name, "Wavelength")
        XCTAssertEqual(merged.track.tempos.first?.bpm, 124)
        XCTAssertEqual(merged.phrases.count, 2)
        XCTAssertTrue(merged.hasWaveform)
        XCTAssertEqual(merged.rekordboxId, "5")
        let alone = try XCTUnwrap(scan.tracks.first { $0.origin == .analysis })
        XCTAssertEqual(alone.filePath, "/Users/dj/Music/Unknown.mp3")
        XCTAssertFalse(scan.isAnalysisOnly)
    }
}
