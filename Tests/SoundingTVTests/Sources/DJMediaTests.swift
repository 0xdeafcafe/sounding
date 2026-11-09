import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

private struct FuzzGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class DJMediaTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appending(path: "DJMediaTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func fixture(_ name: String, _ ext: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: DJMediaTests.self).url(forResource: name, withExtension: ext), "missing fixture \(name).\(ext)")
        return try Data(contentsOf: url)
    }

    // MARK: - Strings and hashing

    func testDeviceSQLStringEncodingMatchesDocumentedLayouts() throws {
        XCTAssertEqual(try DeviceSQLString.encode(""), [0x03])
        XCTAssertEqual(try DeviceSQLString.encode("Pink"), [0x0B, 0x50, 0x69, 0x6E, 0x6B])
        let long = String(repeating: "a", count: 200)
        let longBytes = try DeviceSQLString.encode(long)
        XCTAssertEqual(Array(longBytes.prefix(4)), [0x40, 0xCC, 0x00, 0x00])
        XCTAssertEqual(try DeviceSQLString.encode("é"), [0x90, 0x06, 0x00, 0x00, 0xE9, 0x00])
        XCTAssertEqual(try DeviceSQLString.encodeISRC("GBABC2400001"), [0x90, 0x12, 0x00, 0x00, 0x03] + Array("GBABC2400001".utf8) + [0x00])

        for text in ["", "Pink", long, "Beyoncé", "Röyksopp — Ⅱ", "🎧 Set", String(repeating: "x", count: 126), String(repeating: "x", count: 127)] {
            let encoded = try DeviceSQLString.encode(text)
            XCTAssertEqual(try DeviceSQLString.decode(DJByteReader(encoded), at: 0), text)
        }
        let isrc = try DeviceSQLString.encodeISRC("USRC17607839")
        XCTAssertEqual(try DeviceSQLString.decode(DJByteReader(isrc), at: 0), "USRC17607839")
        XCTAssertThrowsError(try DeviceSQLString.decode(DJByteReader([0x90, 0xFF, 0x00, 0x00]), at: 0))
        XCTAssertThrowsError(try DeviceSQLString.decode(DJByteReader([0x42, 0x08, 0x00, 0x00, 1, 2, 3, 4]), at: 0))
    }

    func testAnalysisFolderHashMatchesRekordboxExport() {
        XCTAssertEqual(DJAnalysisPath.directory(for: "/Contents/Loopmasters/UnknownAlbum/Demo Track 1.mp3"), "/PIONEER/USBANLZ/P016/0000875E")
        XCTAssertEqual(DJAnalysisPath.directory(for: "/Contents/UnknownArtist/UnknownAlbum/SIREN.wav"), "/PIONEER/USBANLZ/P017/00009B77")
        XCTAssertEqual(DJAnalysisPath.directory(for: "/Contents/Loopmasters/UnknownAlbum/Demo Track 2.mp3"), "/PIONEER/USBANLZ/P053/0001D21F")
    }

    // MARK: - Reading a real export

    func testReadsRekordboxExportFixture() throws {
        let result = try PDBReader.read(try fixture("pyrekordbox-export", "pdb"))
        XCTAssertEqual(result.issues, [])
        let db = result.database
        XCTAssertEqual(db.pageSize, 4096)
        XCTAssertEqual(db.tables.count, 20)
        XCTAssertEqual(db.tracks.count, 6)
        XCTAssertEqual(db.colors.map(\.name), ["Pink", "Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple"])
        XCTAssertEqual(db.columns.count, 27)
        XCTAssertEqual(db.columns.first?.name, "\u{FFFA}GENRE\u{FFFB}")
        XCTAssertEqual(db.artists.map(\.name), ["Loopmasters"])
        XCTAssertEqual(db.labels.map(\.name), ["Loopmasters"])
        XCTAssertEqual(db.keys.map(\.name), ["Fm"])

        let demo = try XCTUnwrap(db.tracks.first { $0.title == "Demo Track 1" })
        XCTAssertEqual(demo.id, 1)
        XCTAssertEqual(demo.tempo, 12800)
        XCTAssertEqual(demo.duration, 172)
        XCTAssertEqual(demo.sampleRate, 44100)
        XCTAssertEqual(demo.bitrate, 320)
        XCTAssertEqual(demo.fileType, PDBFileType.mp3.rawValue)
        XCTAssertEqual(demo.artistId, 1)
        XCTAssertEqual(demo.filePath, "/Contents/Loopmasters/UnknownAlbum/Demo Track 1.mp3")
        XCTAssertEqual(demo.analyzePath, "/PIONEER/USBANLZ/P016/0000875E/ANLZ0000.DAT")
        XCTAssertEqual(demo[.comment], "Tracks by www.loopmasters.com")
        XCTAssertEqual(demo[.dateAdded], "2022-04-09")

        let folder = try XCTUnwrap(db.playlistTree.first { $0.name == "Folder" })
        XCTAssertTrue(folder.isFolder)
        let sub = try XCTUnwrap(db.playlistTree.first { $0.name == "Sub Playlist" })
        XCTAssertEqual(sub.parentId, folder.id)
        XCTAssertEqual(db.entries(ofPlaylist: sub.id).map(\.trackId), [1, 2])

        let report = DJMediaValidator.validate(pdb: try fixture("pyrekordbox-export", "pdb"), file: { _ in nil }, fileSize: { _ in nil })
        XCTAssertTrue(report.issues.filter { $0.message.contains("does not add up") || $0.message.contains("points at missing") }.isEmpty, "\(report.issues)")
    }

    func testReadsSecondRekordboxExport() throws {
        let data = try fixture("rekordbox-pdb-one-song-export", "pdb")
        let read = try PDBReader.read(data)
        XCTAssertEqual(read.issues, [])
        XCTAssertEqual(read.database.tracks.map(\.title), ["Super Smash Bros."])
        let track = try XCTUnwrap(read.database.tracks.first)
        XCTAssertEqual(track.sampleRate, 48000)
        XCTAssertEqual(track.analyzePath, "/.PIONEER/USBANLZ/P011/00005719/ANLZ0000.DAT")
        XCTAssertEqual(DJAnalysisPath.directory(for: track.filePath), "/PIONEER/USBANLZ/P011/00005719")
        XCTAssertEqual(read.database.artwork.map(\.path), ["/.PIONEER/Artwork/00001/a1.jpg"])
        XCTAssertEqual(read.database.albums.first?.name, "Baby Gravy 3")
        XCTAssertEqual(read.database.playlistTree.map(\.name), ["aac"])
        XCTAssertEqual(read.database.rawRows[PDBTableType.menuItems.rawValue], PDBDefaults.menuItemRows)
        XCTAssertEqual(read.database.rawRows[PDBTableType.unknown18.rawValue], PDBDefaults.table18Rows)
        XCTAssertEqual(read.database.columns, PDBDefaults.columns)
        XCTAssertEqual(read.database.colors, PDBDefaults.colors)
        let report = DJMediaValidator.validate(pdb: data, file: { _ in nil }, fileSize: { _ in nil })
        XCTAssertFalse(report.errors.contains { $0.message.contains("not where players look") }, "\(report.errors)")
        XCTAssertFalse(report.errors.contains { $0.message.contains("does not add up") }, "\(report.errors)")
    }

    func testReadsExportExtFixture() throws {
        let ext = try PDBReader.readExt(try fixture("pyrekordbox-exportExt", "pdb"))
        XCTAssertEqual(ext.issues, [])
        XCTAssertFalse(ext.database.tags.isEmpty)
        XCTAssertTrue(ext.database.tags.contains { $0.isCategory })
    }

    func testRealExportSurvivesReadWriteRead() throws {
        let original = try PDBReader.read(try fixture("pyrekordbox-export", "pdb")).database
        let rewritten = try PDBWriter.write(original)
        let again = try PDBReader.read(rewritten)
        XCTAssertEqual(again.issues, [])
        XCTAssertEqual(again.database.tracks, original.tracks)
        XCTAssertEqual(again.database.artists, original.artists)
        XCTAssertEqual(again.database.albums, original.albums)
        XCTAssertEqual(again.database.genres, original.genres)
        XCTAssertEqual(again.database.labels, original.labels)
        XCTAssertEqual(again.database.keys, original.keys)
        XCTAssertEqual(again.database.colors, original.colors)
        XCTAssertEqual(again.database.artwork, original.artwork)
        XCTAssertEqual(again.database.columns, original.columns)
        XCTAssertEqual(again.database.playlistTree, original.playlistTree)
        XCTAssertEqual(again.database.playlistEntries, original.playlistEntries)
        XCTAssertEqual(again.database.rawRows[PDBTableType.menuItems.rawValue], original.rawRows[PDBTableType.menuItems.rawValue])
    }

    // MARK: - Byte-for-byte goldens

    private func rawPage(_ data: Data, table: PDBTableType) throws -> (bytes: [UInt8], summary: PDBPageSummary) {
        let read = try PDBReader.read(data)
        let summary = try XCTUnwrap(read.pages[table.rawValue]?.first { !$0.isIndexPage })
        let start = Int(summary.index) * 4096
        return (Array(data[start ..< start + 4096]), summary)
    }

    func testDefaultTablesMatchRekordboxPagesByteForByte() throws {
        let fixtureData = try fixture("rekordbox-pdb-one-song-export", "pdb")
        let ours = try PDBWriter.write(PDBDatabase.exportDefaults())
        for table in [PDBTableType.colors, .columns, .menuItems, .unknown18] {
            let theirs = try rawPage(fixtureData, table: table)
            let mine = try rawPage(ours, table: table)
            XCTAssertEqual(Array(mine.bytes[0x18 ..< 0x20]), Array(theirs.bytes[0x18 ..< 0x20]), "\(table) counts, flags, free and used")
            XCTAssertEqual(Array(mine.bytes[0x28...]), Array(theirs.bytes[0x28...]), "\(table) heap and row directory")
        }
    }

    func testIndexPageMatchesDocumentedLayout() throws {
        let data = try PDBWriter.write(PDBDatabase.exportDefaults())
        let page = Array(data[4096 ..< 8192])
        var expected = DJByteWriter()
        expected.u32le(0); expected.u32le(1); expected.u32le(0); expected.u32le(2)
        expected.u32le(1); expected.u32le(0)
        expected.append([0, 0, 0, 0x64]); expected.u16le(0); expected.u16le(0)
        expected.u16le(0x1FFF); expected.u16le(0x1FFF); expected.u16le(0x03EC); expected.u16le(0)
        expected.u32le(1); expected.u32le(0x03FF_FFFF); expected.u32le(0x03FF_FFFF); expected.u32le(0)
        expected.u16le(0); expected.u16le(0x1FFF)
        for _ in 0 ..< 1004 { expected.u32le(0x1FFF_FFF8) }
        expected.pad(to: 4096)
        XCTAssertEqual(page, expected.bytes)

        let header = DJByteReader(data)
        XCTAssertEqual(try header.u32le(4), 4096)
        XCTAssertEqual(try header.u32le(8), 20)
        XCTAssertEqual(try header.u32le(0x1C + 6 * 16), PDBTableType.colors.rawValue)
        XCTAssertEqual(try header.u32le(0x1C + 6 * 16 + 8), 13)
        XCTAssertEqual(try header.u32le(0x1C + 6 * 16 + 12), 14)
        XCTAssertEqual(try header.u32le(0x1C + 0 * 16 + 4), 2)
        XCTAssertEqual(data.count % 4096, 0)
    }

    func testTrackArtistAndKeyRowsMatchRekordboxBytes() throws {
        let data = try fixture("pyrekordbox-export", "pdb")
        let read = try PDBReader.read(data)
        let trackPage = try XCTUnwrap(read.pages[PDBTableType.tracks.rawValue]?.first { !$0.isIndexPage })
        let pageStart = Int(trackPage.index) * 4096
        let page = DJByteReader(Array(data[pageStart ..< pageStart + 4096]))
        let offsets = trackPage.rowOffsets.sorted()
        for (n, offset) in offsets.enumerated() {
            let track = try PDBReader.decodeTrack(page, offset)
            let encoded = try PDBWriter.encodeTrack(track)
            let end = n + 1 < offsets.count ? offsets[n + 1] : 0x28 + trackPage.usedSize
            var theirs = try page.slice(offset, end - offset)
            theirs[2] = 0; theirs[3] = 0
            var mine = encoded.bytes + [UInt8](repeating: 0, count: encoded.allocation - encoded.bytes.count)
            mine[2] = 0; mine[3] = 0
            XCTAssertLessThanOrEqual(mine.count, theirs.count, "allocation for \(track.title)")
            XCTAssertEqual(Array(mine.prefix(encoded.bytes.count)), Array(theirs.prefix(encoded.bytes.count)), "row bytes for \(track.title)")
        }
        let artistPage = try rawPage(data, table: .artists)
        let artist = try PDBWriter.encodeArtist(PDBArtist(id: 1, name: "Loopmasters"))
        let at = artistPage.summary.rowOffsets[0]
        var theirArtist = Array(artistPage.bytes[at ..< at + artist.bytes.count])
        theirArtist[2] = 0; theirArtist[3] = 0
        XCTAssertEqual(artist.bytes, theirArtist)
        XCTAssertEqual(artist.allocation, 28)
    }

    func testANLZFixturesRoundTripByteForByte() throws {
        for ext in ["DAT", "EXT"] {
            let original = try fixture("pyrekordbox-P016-0000875E", ext)
            let read = try ANLZCodec.read(original)
            XCTAssertEqual(read.issues, [], ext)
            XCTAssertEqual(read.file.path, "/Contents/Loopmasters/UnknownAlbum/Demo Track 1.mp3")
            XCTAssertEqual(ANLZCodec.write(read.file), original, "\(ext) rewrite differs")
        }
        let dat = try ANLZCodec.read(try fixture("pyrekordbox-P016-0000875E", "DAT")).file
        let beats = try XCTUnwrap(dat.beatGrid)
        XCTAssertEqual(beats.count, 368)
        XCTAssertEqual(beats.first, ANLZBeat(beatNumber: 1, tempo: 12800, timeMillis: 25))
        if case .waveformPreview(let preview)? = dat.tag("PWAV") { XCTAssertEqual(preview.count, 400) } else { XCTFail("PWAV") }

        let ext = try ANLZCodec.read(try fixture("pyrekordbox-P016-0000875E", "EXT")).file
        let structure = try XCTUnwrap(ext.songStructure)
        XCTAssertTrue(structure.masked)
        XCTAssertEqual(structure.mood, ANLZMood.mid.rawValue)
        XCTAssertEqual(structure.phrases.count, 19)
        XCTAssertEqual(structure.endBeat, 353)
        XCTAssertEqual(structure.phrases.first?.beat, 1)
        XCTAssertEqual(structure.phrases.first?.kind, 9)
        if case .colorWaveformPreview(let preview)? = ext.tag("PWV4") { XCTAssertEqual(preview.count, 7200) } else { XCTFail("PWV4") }
        if case .colorWaveformDetail(let detail)? = ext.tag("PWV5") { XCTAssertEqual(detail.count, 25866) } else { XCTFail("PWV5") }
    }

    func testCueEntriesMatchDocumentedLayout() throws {
        var hot = ANLZCue(timeMillis: 1500)
        hot.hotCue = 2
        hot.comment = "Drop"
        hot.colorCode = 0x16
        hot.colorRed = 0x28; hot.colorGreen = 0xE2; hot.colorBlue = 0x14
        let file = ANLZFile(tags: [
            .cueList(ANLZCueList(kind: .hotCues, cues: [hot], memoryCount: 1)),
            .extendedCueList(ANLZCueList(kind: .hotCues, cues: [hot])),
        ])
        let bytes = [UInt8](ANLZCodec.write(file))
        let pcob = 0x1C
        XCTAssertEqual(Array(bytes[pcob ..< pcob + 24]), Array("PCOB".utf8) + [0, 0, 0, 0x18, 0, 0, 0, 0x50, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1])
        let pcpt = pcob + 24
        var expected = Array("PCPT".utf8) + [0, 0, 0, 0x1C, 0, 0, 0, 0x38, 0, 0, 0, 2, 0, 0, 0, 0, 0, 1, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 1, 0, 0x03, 0xE8]
        expected += [0, 0, 0x05, 0xDC, 0xFF, 0xFF, 0xFF, 0xFF] + [UInt8](repeating: 0, count: 16)
        XCTAssertEqual(Array(bytes[pcpt ..< pcpt + 0x38]), expected)

        let pco2 = pcpt + 0x38
        let pcp2 = pco2 + 20
        XCTAssertEqual(Array(bytes[pco2 ..< pco2 + 20]), Array("PCO2".utf8) + [0, 0, 0, 0x14, 0, 0, 0, 0x62, 0, 0, 0, 1, 0, 1, 0, 0])
        let comment: [UInt8] = [0, 0x44, 0, 0x72, 0, 0x6F, 0, 0x70, 0, 0]
        var entry = Array("PCP2".utf8) + [0, 0, 0, 0x10, 0, 0, 0, 0x4E, 0, 0, 0, 2, 1, 0, 0x03, 0xE8]
        entry += [0, 0, 0x05, 0xDC, 0xFF, 0xFF, 0xFF, 0xFF, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x0A]
        entry += comment + [0x16, 0x28, 0xE2, 0x14] + [UInt8](repeating: 0, count: 20)
        XCTAssertEqual(Array(bytes[pcp2...]), entry)

        let back = try ANLZCodec.read(Data(bytes))
        XCTAssertEqual(back.issues, [])
        XCTAssertEqual(back.file.cueList(.hotCues, extended: true)?.cues.first?.comment, "Drop")
        XCTAssertEqual(back.file.cueList(.hotCues, extended: false)?.cues.first?.timeMillis, 1500)
    }

    // MARK: - Writing an export

    private func sampleTracks(audio: [URL]? = nil) -> [DJExportTrackRecord] {
        let first = DJExportTrackRecord(
            exportID: "sc:1",
            audioFileURL: audio?[0] ?? URL(filePath: "/tmp/Warehouse Tool.mp3"),
            metadata: DJExportMetadata(
                title: "Warehouse Tool", artist: "Alex", album: "Tools", genre: "Techno", label: "Self",
                comment: "Peak", year: 2026, rating: 4, colorRGB: 0xF82020, durationSeconds: 30,
                bitrateKbps: 320, fileSize: 1_200_000
            ),
            beatGrid: DJExportBeatGrid(bpm: 128, firstBeatSeconds: 0.12, firstDownbeatOffset: 0),
            cues: [
                DJExportCue(role: .hotCue(slot: 0), startSeconds: 0.12, label: "Start", colorRGB: 0x28E214),
                DJExportCue(role: .hotCue(slot: 4), startSeconds: 15.12, endSeconds: 15.12 + 4 * 60 / 128.0, label: "Loop"),
                DJExportCue(role: .memory, startSeconds: 7.62),
                DJExportCue(role: .mixOut, startSeconds: 22.62),
            ],
            phrases: DJExportPhrases(mood: nil, phrases: [
                DJExportPhrase(startSeconds: 0.12, kind: .intro),
                DJExportPhrase(startSeconds: 7.62, kind: .up),
                DJExportPhrase(startSeconds: 15.12, kind: .chorus),
                DJExportPhrase(startSeconds: 22.62, kind: .outro),
            ], endSeconds: 29.5),
            waveform: DJExportWaveform(amplitude: (0 ..< 900).map { Float(abs(sin(Double($0) / 9))) }),
            key: DJExportKey(pitchClass: 9, isMinor: true)
        )
        let second = DJExportTrackRecord(
            exportID: "local:2",
            audioFileURL: audio?[1] ?? URL(filePath: "/tmp/Ünïcode: Track?.wav"),
            metadata: DJExportMetadata(title: "Ünïcode Track", artist: "Bjørk", durationSeconds: 20, sampleRate: 48000, bitDepth: 24, fileSize: 800_000),
            beatGrid: DJExportBeatGrid(bpm: 122.5, firstBeatSeconds: -0.2, firstDownbeatOffset: 1),
            key: DJExportKey(pitchClass: 0, isMinor: false)
        )
        return [first, second]
    }

    private func samplePlaylists() -> [DJExportPlaylist] {
        [
            DJExportPlaylist(name: "Warm-up", trackIDs: ["local:2", "sc:1"]),
            .folder("Gigs", [DJExportPlaylist(name: "Friday", trackIDs: ["sc:1", "missing"])]),
        ]
    }

    private func inMemoryExport(_ plan: DJExportPlan) throws -> (pdb: Data, files: [String: Data]) {
        var files: [String: Data] = [:]
        for a in plan.analysis {
            files[a.datPath] = ANLZCodec.write(a.dat)
            files[a.extPath] = ANLZCodec.write(a.ext)
            if let ex2 = a.ex2 { files[a.ex2Path] = ANLZCodec.write(ex2) }
        }
        return (try PDBWriter.write(plan.database), files)
    }

    func testPlanWritesAndReadsBack() throws {
        let plan = try DJExportPlanner.plan(tracks: sampleTracks(), playlists: samplePlaylists(), now: Date(timeIntervalSince1970: 1_793_000_000))
        XCTAssertEqual(plan.copies.map(\.devicePath), [
            "/Contents/Alex/Tools/Warehouse Tool.mp3",
            "/Contents/Bjørk/UnknownAlbum/Ünïcode_ Track_.wav",
        ])
        XCTAssertEqual(plan.warnings, ["playlist Friday: track missing not exported"])
        let (pdb, files) = try inMemoryExport(plan)
        let read = try PDBReader.read(pdb)
        XCTAssertEqual(read.issues, [])
        let db = read.database
        XCTAssertEqual(db.tracks, plan.database.tracks)
        XCTAssertEqual(db.tracks.map(\.tempo), [12800, 12250])
        XCTAssertEqual(db.tracks[0].colorId, 2)
        XCTAssertEqual(db.tracks[0].rating, 4)
        XCTAssertEqual(db.keys.map(\.name), ["Am", "C"])
        XCTAssertEqual(db.artists.map(\.name), ["Alex", "Bjørk"])
        XCTAssertEqual(db.tracks[1].fileType, PDBFileType.wav.rawValue)
        XCTAssertEqual(db.tracks[1].sampleDepth, 24)
        XCTAssertEqual(db.playlistTree.map(\.name), ["Warm-up", "Gigs", "Friday"])
        XCTAssertEqual(db.playlistTree.map(\.parentId), [0, 0, 2])
        XCTAssertEqual(db.entries(ofPlaylist: 1).map(\.trackId), [2, 1])
        XCTAssertEqual(db.entries(ofPlaylist: 3).map(\.trackId), [1])

        let ext = try ANLZCodec.read(try XCTUnwrap(files[plan.analysis[0].extPath])).file
        let hot = try XCTUnwrap(ext.cueList(.hotCues, extended: true))
        XCTAssertEqual(hot.cues.map(\.hotCue), [1, 5])
        XCTAssertEqual(hot.cues[1].isLoop, true)
        XCTAssertEqual(hot.cues[1].loopNumerator, 4)
        XCTAssertEqual(hot.cues[1].loopDenominator, 1)
        XCTAssertEqual(hot.cues[0].comment, "Start")
        XCTAssertEqual(hot.cues[0].colorCode, 0x16)
        let memory = try XCTUnwrap(ext.cueList(.memory, extended: true))
        XCTAssertEqual(memory.cues.map(\.timeMillis), [7620, 22620])
        XCTAssertEqual(memory.cues.map(\.comment), ["", "Mix Out"])
        let structure = try XCTUnwrap(ext.songStructure)
        XCTAssertEqual(structure.mood, ANLZMood.high.rawValue)
        XCTAssertEqual(structure.phrases.map(\.beat), [1, 17, 33, 49])
        XCTAssertEqual(structure.phrases.map(\.kind), [1, 2, 5, 6])

        let dat = try ANLZCodec.read(try XCTUnwrap(files[plan.analysis[0].datPath])).file
        let beats = try XCTUnwrap(dat.beatGrid)
        XCTAssertEqual(beats.first, ANLZBeat(beatNumber: 1, tempo: 12800, timeMillis: 120))
        XCTAssertEqual(beats[4].beatNumber, 1)
        XCTAssertEqual(beats[5].beatNumber, 2)
        XCTAssertEqual(dat.cueList(.hotCues, extended: false)?.cues.map(\.hotCue), [1])

        let second = try ANLZCodec.read(try XCTUnwrap(files[plan.analysis[1].datPath])).file
        let secondBeats = try XCTUnwrap(second.beatGrid)
        XCTAssertEqual(secondBeats.first?.beatNumber, 1)
        XCTAssertEqual(secondBeats.first.map { Int($0.timeMillis) }, Int(((-0.2 + 60 / 122.5) * 1000).rounded()))

        let report = DJMediaValidator.validate(pdb: pdb, file: { files[$0] }, fileSize: { path in
            plan.copies.first { $0.devicePath == path }.map { _ in path.hasSuffix(".mp3") ? 1_200_000 : 800_000 }
        })
        XCTAssertTrue(report.isValid, "\(report.errors)")
    }

    func testValidatorCatchesWhatPlayersWouldReject() throws {
        let plan = try DJExportPlanner.plan(tracks: sampleTracks(), playlists: samplePlaylists())
        var (pdb, files) = try inMemoryExport(plan)
        let size: (String) -> Int64? = { $0.hasSuffix(".mp3") ? 1_200_000 : 800_000 }

        var wrongPath = plan.analysis[0].ext
        wrongPath.tags[0] = .path("/Contents/elsewhere.mp3")
        files[plan.analysis[0].extPath] = ANLZCodec.write(wrongPath)
        files[plan.analysis[1].extPath] = nil
        let report = DJMediaValidator.validate(pdb: pdb, file: { files[$0] }, fileSize: size)
        XCTAssertTrue(report.errors.contains { $0.message.contains("belongs to /Contents/elsewhere.mp3") })
        XCTAssertTrue(report.errors.contains { $0.message.contains("is missing") && $0.message.hasSuffix(".EXT") })

        var broken = plan.database
        broken.tracks[0].artistId = 99
        broken.playlistEntries.append(PDBPlaylistEntry(entryIndex: 9, trackId: 42, playlistId: 2))
        broken.tracks[1][.analyzePath] = "/PIONEER/USBANLZ/P000/00000000/ANLZ0000.DAT"
        pdb = try PDBWriter.write(broken)
        let second = DJMediaValidator.validate(pdb: pdb, file: { files[$0] }, fileSize: size)
        XCTAssertTrue(second.errors.contains { $0.message.contains("missing artist 99") })
        XCTAssertTrue(second.errors.contains { $0.message.contains("missing track 42") })
        XCTAssertTrue(second.errors.contains { $0.message.contains("which is not a playlist") })
        XCTAssertTrue(second.errors.contains { $0.message.contains("not where players look") })

        var bytes = [UInt8](try PDBWriter.write(plan.database))
        let tracksFirstData = 2 * 4096
        bytes[tracksFirstData + 0x1C] ^= 0x10
        let third = DJMediaValidator.validate(pdb: Data(bytes), file: { files[$0] }, fileSize: size)
        XCTAssertTrue(third.errors.contains { $0.message.contains("does not add up") })
    }

    func testLargeLibrarySpansPageChains() throws {
        var tracks: [DJExportTrackRecord] = []
        for i in 0 ..< 700 {
            tracks.append(DJExportTrackRecord(
                exportID: "t\(i)",
                audioFileURL: URL(filePath: "/tmp/Track \(i).mp3"),
                metadata: DJExportMetadata(title: "Track number \(i) with a reasonably long title", artist: "Artist \(i % 40)", album: "Album \(i % 25)", genre: "Genre \(i % 7)", durationSeconds: 180),
                beatGrid: DJExportBeatGrid(bpm: 120 + Double(i % 20), firstBeatSeconds: 0.05)
            ))
        }
        let playlists = (0 ..< 6).map { p in DJExportPlaylist(name: "List \(p)", trackIDs: tracks.map(\.exportID)) }
        let plan = try DJExportPlanner.plan(tracks: tracks, playlists: playlists)
        let pdb = try PDBWriter.write(plan.database)
        let read = try PDBReader.read(pdb)
        XCTAssertEqual(read.issues, [])
        XCTAssertEqual(read.database.tracks, plan.database.tracks)
        XCTAssertEqual(read.database.playlistEntries.count, 4200)
        XCTAssertEqual(read.database.playlistEntries, plan.database.playlistEntries)
        let trackPages = try XCTUnwrap(read.pages[PDBTableType.tracks.rawValue])
        XCTAssertGreaterThan(trackPages.count, 10)
        let table = try XCTUnwrap(read.database.tables.first { $0.type == PDBTableType.tracks.rawValue })
        XCTAssertEqual(trackPages.last?.index, table.lastPage)
        XCTAssertEqual(trackPages.last?.nextPage, table.emptyCandidate)
        XCTAssertTrue(trackPages.dropFirst().allSatisfy { $0.slotCount <= 2047 && $0.freeSize >= 0 })
        let report = DJMediaValidator.validate(pdb: pdb, file: { _ in nil }, fileSize: { _ in nil })
        XCTAssertFalse(report.errors.contains { !$0.message.contains("missing") && !$0.message.contains("is missing") }, "\(report.errors.prefix(5))")
    }

    // MARK: - Mapping helpers

    func testKeysColoursLoopsAndGrid() {
        XCTAssertEqual(DJExportKey(pitchClass: 9, isMinor: true).name(.classic), "Am")
        XCTAssertEqual(DJExportKey(pitchClass: 9, isMinor: true).name(.camelot), "8A")
        XCTAssertEqual(DJExportKey(pitchClass: 0, isMinor: false).name(.camelot), "8B")
        XCTAssertEqual(DJExportKey.parse("8A"), DJExportKey(pitchClass: 9, isMinor: true))
        XCTAssertEqual(DJExportKey.parse("F#m"), DJExportKey(pitchClass: 6, isMinor: true))
        XCTAssertEqual(DJMediaColor.hotCueColor(0x28E214).code, 0x16)
        XCTAssertEqual(DJMediaColor.trackColorId(nil), 0)
        XCTAssertEqual(DJMediaColor.trackColorId(0x305AFF), 7)
        XCTAssertEqual(DJAnalysisMapping.quantisedLoop(beats: 4).0, 4)
        XCTAssertEqual(DJAnalysisMapping.quantisedLoop(beats: 0.5).1, 2)
        XCTAssertEqual(DJAnalysisMapping.quantisedLoop(beats: 3).0, 0)
        let beats = DJAnalysisMapping.beats(for: DJExportBeatGrid(bpm: 120, firstBeatSeconds: 1.25, firstDownbeatOffset: 2), duration: 4)
        XCTAssertEqual(beats.map(\.timeMillis), [250, 750, 1250, 1750, 2250, 2750, 3250, 3750])
        XCTAssertEqual(beats.map(\.beatNumber), [1, 2, 3, 4, 1, 2, 3, 4])
        let explicit = DJAnalysisMapping.beats(for: DJExportBeatGrid(bpm: 120, firstBeatSeconds: 0, beats: [0.1, 0.6, 1.1, 1.6, 2.1], downbeats: [0.6]), duration: 3)
        XCTAssertEqual(explicit.map(\.beatNumber), [4, 1, 2, 3, 4])
        XCTAssertEqual(DJDevicePath.component("AC/DC: Live?", fallback: "x"), "AC_DC_ Live_")
        XCTAssertEqual(DJDevicePath.component("...", fallback: "UnknownArtist"), "UnknownArtist")
    }

    func testWaveformRenderingSizesAndBits() {
        let rendered = DJWaveformSynth.render(DJExportWaveform(amplitude: (0 ..< 1800).map { Float($0 % 100) / 100 }), duration: 61.3)
        XCTAssertEqual(rendered.preview.count, 400)
        XCTAssertEqual(rendered.tinyPreview.count, 100)
        XCTAssertEqual(rendered.colorPreview.count, 7200)
        XCTAssertEqual(rendered.detail.count, 9195)
        XCTAssertEqual(rendered.colorDetail.count, 9195)
        XCTAssertTrue(rendered.tinyPreview.allSatisfy { $0 <= 15 })
        XCTAssertTrue(rendered.colorDetail.allSatisfy { $0 & 0x3 == 0 })
        XCTAssertEqual(rendered.preview.map { $0 & 0x1F }.max(), 31)
        let silent = DJWaveformSynth.render(DJExportWaveform(amplitude: []), duration: 10)
        XCTAssertEqual(silent.detail.count, 1500)
        XCTAssertTrue(silent.detail.allSatisfy { $0 == 0 })
    }

    // MARK: - Three-band waveforms (.2EX)

    private func bandedWaveform(count: Int = 900) -> DJExportWaveform {
        DJExportWaveform(
            amplitude: (0 ..< count).map { Float(abs(sin(Double($0) / 9))) },
            low: (0 ..< count).map { Float(abs(sin(Double($0) / 7))) },
            mid: (0 ..< count).map { Float(abs(cos(Double($0) / 11))) },
            high: (0 ..< count).map { Float(abs(sin(Double($0) / 3)) * 0.4) }
        )
    }

    func testThreeBandTagsMatchDocumentedLayoutsByteForByte() throws {
        var file = ANLZFile()
        file.tags = [.path("/Contents/a.mp3"), .threeBandPreview([1, 2, 3, 4, 5, 6]), .threeBandDetail([9, 8, 7, 6, 5, 4]), .threeBandScale(unknown: 0, values: [1, 2, 3])]
        let bytes = [UInt8](ANLZCodec.write(file))
        func tag(_ code: String) -> Int { bytes.indices.first { $0 + 4 <= bytes.count && Array(bytes[$0 ..< $0 + 4]) == Array(code.utf8) }! }
        func u32(_ o: Int) -> UInt32 { bytes[o ..< o + 4].reduce(0) { $0 << 8 | UInt32($1) } }

        let pwv6 = tag("PWV6")
        XCTAssertEqual(u32(pwv6 + 4), 0x14)
        XCTAssertEqual(u32(pwv6 + 8), 0x14 + 6)
        XCTAssertEqual(u32(pwv6 + 12), 3)
        XCTAssertEqual(u32(pwv6 + 16), 2)
        XCTAssertEqual(Array(bytes[pwv6 + 0x14 ..< pwv6 + 0x1A]), [1, 2, 3, 4, 5, 6])

        let pwv7 = tag("PWV7")
        XCTAssertEqual(u32(pwv7 + 4), 0x18)
        XCTAssertEqual(u32(pwv7 + 8), 0x18 + 6)
        XCTAssertEqual(u32(pwv7 + 12), 3)
        XCTAssertEqual(u32(pwv7 + 16), 2)
        XCTAssertEqual(u32(pwv7 + 20), 0x0096_0000)
        XCTAssertEqual(Array(bytes[pwv7 + 0x18 ..< pwv7 + 0x1E]), [9, 8, 7, 6, 5, 4])

        let pwvc = tag("PWVC")
        XCTAssertEqual(u32(pwvc + 4), 0x0E)
        XCTAssertEqual(u32(pwvc + 8), 0x14)
        XCTAssertEqual(Array(bytes[pwvc + 14 ..< pwvc + 20]), [0, 1, 0, 2, 0, 3])

        let back = try ANLZCodec.read(Data(bytes))
        XCTAssertEqual(back.issues, [])
        XCTAssertEqual(back.file, file)
        XCTAssertEqual(back.file.threeBandPreview, [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(back.file.threeBandDetail, [9, 8, 7, 6, 5, 4])
        XCTAssertEqual(ANLZCodec.write(back.file), Data(bytes))
    }

    func testThreeBandRoundTripAtFullSize() throws {
        let rendered = DJWaveformSynth.render(bandedWaveform(), duration: 61.3)
        XCTAssertEqual(rendered.threeBandPreview.count, 3600)
        XCTAssertEqual(rendered.threeBandDetail.count, 9195 * 3)
        XCTAssertEqual(rendered.threeBandPreview.enumerated().filter { $0.offset % 3 == 0 }.map(\.element).max(), 255)
        var file = ANLZFile()
        file.tags = [.path("/Contents/a.mp3"), .threeBandPreview(rendered.threeBandPreview), .threeBandDetail(rendered.threeBandDetail)]
        let back = try ANLZCodec.read(ANLZCodec.write(file))
        XCTAssertEqual(back.issues, [])
        XCTAssertEqual(back.file, file)
    }

    func testThreeBandTagsRejectWrongEntrySizes() throws {
        var file = ANLZFile()
        file.tags = [.path("/a.mp3"), .threeBandPreview([1, 2, 3])]
        var bytes = [UInt8](ANLZCodec.write(file))
        let at = bytes.indices.first { $0 + 4 <= bytes.count && Array(bytes[$0 ..< $0 + 4]) == Array("PWV6".utf8) }!
        bytes[at + 15] = 6
        let read = try ANLZCodec.read(Data(bytes))
        XCTAssertFalse(read.issues.isEmpty)
        XCTAssertEqual(read.file.tag("PWV6")?.fourCC, "PWV6")
        XCTAssertNil(read.file.threeBandPreview)
    }

    func testPlannerWritesTwoExOnlyWhenBandsAreReal() throws {
        var tracks = sampleTracks()
        tracks[1].waveform = bandedWaveform()
        let plan = try DJExportPlanner.plan(tracks: tracks, playlists: [])
        XCTAssertNil(plan.analysis[0].ex2)
        let ex2 = try XCTUnwrap(plan.analysis[1].ex2)
        XCTAssertEqual(ex2.tags.map(\.fourCC), ["PPTH", "PWV6", "PWV7"])
        XCTAssertEqual(ex2.path, plan.copies[1].devicePath)
        XCTAssertEqual(plan.analysis[1].ex2Path, plan.analysis[1].datPath.replacingOccurrences(of: ".DAT", with: ".2EX"))
        XCTAssertEqual(ex2.threeBandPreview?.count, 3600)
        XCTAssertEqual(ex2.threeBandDetail?.count, DJWaveformSynth.detailCount(duration: 20) * 3)

        let off = try DJExportPlanner.plan(tracks: tracks, playlists: [], options: DJExportOptions(writeThreeBandWaveform: false))
        XCTAssertTrue(off.analysis.allSatisfy { $0.ex2 == nil })
    }

    func testValidatorChecksTwoEx() throws {
        var tracks = sampleTracks()
        tracks[1].waveform = bandedWaveform()
        let plan = try DJExportPlanner.plan(tracks: tracks, playlists: [])
        var (pdb, files) = try inMemoryExport(plan)
        let ex2 = try XCTUnwrap(plan.analysis[1].ex2)
        let size: (String) -> Int64? = { $0.hasSuffix(".mp3") ? 1_200_000 : 800_000 }
        let clean = DJMediaValidator.validate(pdb: pdb, file: { files[$0] }, fileSize: size)
        XCTAssertTrue(clean.isValid, "\(clean.errors)")

        var short = ex2
        short.tags[1] = .threeBandPreview([UInt8](repeating: 7, count: 300))
        files[plan.analysis[1].ex2Path] = ANLZCodec.write(short)
        let shortReport = DJMediaValidator.validate(pdb: pdb, file: { files[$0] }, fileSize: size)
        XCTAssertTrue(shortReport.errors.contains { $0.message.contains("PWV6 has 300 bytes") })

        var missing = ex2
        missing.tags.removeLast()
        files[plan.analysis[1].ex2Path] = ANLZCodec.write(missing)
        let missingReport = DJMediaValidator.validate(pdb: pdb, file: { files[$0] }, fileSize: size)
        XCTAssertTrue(missingReport.errors.contains { $0.message.contains("has no PWV7 tag") })

        var wrongPath = ex2
        wrongPath.tags[0] = .path("/Contents/elsewhere.wav")
        files[plan.analysis[1].ex2Path] = ANLZCodec.write(wrongPath)
        let pathReport = DJMediaValidator.validate(pdb: pdb, file: { files[$0] }, fileSize: size)
        XCTAssertTrue(pathReport.errors.contains { $0.message.contains("belongs to /Contents/elsewhere.wav") })

        files[plan.analysis[1].ex2Path] = Data([0x50, 0x4D, 0x41, 0x49, 0, 0])
        let garbage = DJMediaValidator.validate(pdb: pdb, file: { files[$0] }, fileSize: size)
        XCTAssertTrue(garbage.errors.contains { $0.message.contains(".2EX cannot be read") })
    }

    func testExportWritesTwoExToTheStick() async throws {
        let volume = scratch.appending(path: "TWOEX", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        let report = try await DJMediaExporter().export(tracks: try diskTracks(), playlists: [], to: volume, options: DJExportOptions(destination: .volumeRoot))
        let validation = DJMediaValidator.validate(exportRoot: report.exportRoot)
        XCTAssertTrue(validation.isValid, "\(validation.errors)")
        let anlz = try XCTUnwrap(FileManager.default.enumerator(atPath: volume.appending(path: "PIONEER/USBANLZ").path)).compactMap { $0 as? String }
        let twoEx = anlz.filter { $0.hasSuffix(".2EX") }
        XCTAssertEqual(twoEx.count, 1)
        let data = try Data(contentsOf: volume.appending(path: "PIONEER/USBANLZ/\(twoEx[0])"))
        let file = try ANLZCodec.read(data).file
        XCTAssertEqual(file.threeBandPreview?.count, 3600)
        XCTAssertEqual(file.threeBandDetail?.count, DJWaveformSynth.detailCount(duration: 3) * 3)
        XCTAssertTrue(file.path?.hasPrefix("/Contents/Alex/Tools/") == true)
    }

    // MARK: - Removal safety

    private final class FaultyFileSystem: DJExportFileSystem, @unchecked Sendable {
        let base = DJPosixFileSystem()
        private let lock = NSLock()
        private var count = 0
        private let failAfter: Int?

        init(failAfter: Int? = nil) { self.failAfter = failAfter }

        var operations: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        private func step() -> (dead: Bool, dying: Bool) {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            guard let failAfter else { return (false, false) }
            return (count > failAfter, count == failAfter + 1)
        }

        private func eio(_ operation: String, _ url: URL) -> DJVolumeIOError {
            DJVolumeIOError(code: EIO, operation: operation, path: url.path)
        }

        func exists(_ url: URL) -> Bool { step().dead ? false : base.exists(url) }
        func isDirectory(_ url: URL) -> Bool { step().dead ? false : base.isDirectory(url) }
        func fileSize(_ url: URL) -> Int64? { step().dead ? nil : base.fileSize(url) }

        func list(_ url: URL) throws -> [String] {
            if step().dead { throw eio("list", url) }
            return try base.list(url)
        }

        func read(_ url: URL) throws -> Data {
            if step().dead { throw eio("read", url) }
            return try base.read(url)
        }

        func digest(_ url: URL) throws -> Data {
            if step().dead { throw eio("digest", url) }
            return try base.digest(url)
        }

        func createDirectory(_ url: URL) throws {
            if step().dead { throw eio("mkdir", url) }
            try base.createDirectory(url)
        }

        func write(_ data: Data, to url: URL) throws {
            let s = step()
            if s.dead {
                if s.dying { try? base.write(data.prefix(data.count / 2), to: url) }
                throw eio("write", url)
            }
            try base.write(data, to: url)
        }

        func copy(from source: URL, to destination: URL, verify: Bool, onChunk: () throws -> Void) throws -> Int64 {
            let s = step()
            if s.dead {
                if s.dying, let size = base.fileSize(source), (try? base.copy(from: source, to: destination, verify: false, onChunk: {})) != nil {
                    truncate(destination.path, off_t(size / 2))
                }
                throw eio("copy", destination)
            }
            return try base.copy(from: source, to: destination, verify: verify, onChunk: onChunk)
        }

        func rename(_ from: URL, to: URL) throws {
            if step().dead { throw eio("rename", from) }
            try base.rename(from, to: to)
        }

        func remove(_ url: URL) throws {
            if step().dead { throw eio("remove", url) }
            try base.remove(url)
        }

        func syncFile(_ url: URL) throws {
            if step().dead { throw eio("sync", url) }
            try base.syncFile(url)
        }

        func syncDirectory(_ url: URL) throws {
            if step().dead { throw eio("sync", url) }
            try base.syncDirectory(url)
        }
    }

    private static let bookkeeping: Set<String> = ["SOUNDING-EXPORT.json", ".SOUNDING-EXPORT.json.tmp", ".metadata_never_index", ".fseventsd", ".Trashes"]

    private func snapshot(_ root: URL) -> [String: String] {
        var out: [String: String] = [:]
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return out }
        for case let relative as String in walker {
            let first = relative.split(separator: "/").first.map(String.init) ?? relative
            if Self.bookkeeping.contains(first) { continue }
            let url = root.appending(path: relative)
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                out[relative] = "dir"
            } else {
                out[relative] = (try? DJPosixFileSystem().digest(url)).map { $0.map { String(format: "%02x", $0) }.joined() } ?? "unreadable"
            }
        }
        return out
    }

    private func makeStick(_ name: String, withLibrary: Bool) async throws -> URL {
        let volume = scratch.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        if withLibrary {
            var tracks = try diskTracks()
            tracks.removeLast()
            _ = try await DJMediaExporter().export(tracks: tracks, playlists: [], to: volume, options: DJExportOptions(destination: .volumeRoot), now: Date(timeIntervalSince1970: 1_700_000_000))
        }
        return volume
    }

    private func journalState(_ volume: URL) -> DJExportJournal.State? {
        DJExportJournal.read(volume: volume, fs: DJPosixFileSystem())?.state
    }

    private func yankEverywhere(_ destination: DJExportOptions.Destination, withLibrary: Bool, label: String) async throws {
        let tracks = try diskTracks()
        let playlists = samplePlaylists()
        let template = try await makeStick("TEMPLATE-\(label)", withLibrary: withLibrary)
        let before = snapshot(template)
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let options = DJExportOptions(destination: destination)

        func fresh(_ name: String) throws -> URL {
            let directory = scratch.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.copyItem(at: template, to: directory)
            return directory
        }

        let counting = FaultyFileSystem()
        let dry = try fresh("\(label)-dry")
        _ = try await DJMediaExporter(fileSystem: counting).export(tracks: tracks, playlists: playlists, to: dry, options: options, now: now)
        let total = counting.operations
        XCTAssertGreaterThan(total, 40)
        XCTAssertEqual(journalState(dry), .completed)
        XCTAssertEqual(DJExportRecovery.inspect(volume: dry).kind, .clean)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dry.appending(path: ".metadata_never_index").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dry.appending(path: ".fseventsd/no_log").path))

        var points = Set(stride(from: 0, to: total, by: max(1, total / 45)))
        points.formUnion(max(0, total - 45) ..< total)
        var completedAfterYank = 0
        for k in points.sorted() {
            let volume = try fresh("\(label)-\(k)")
            let faulty = FaultyFileSystem(failAfter: k)
            do {
                _ = try await DJMediaExporter(fileSystem: faulty).export(tracks: tracks, playlists: playlists, to: volume, options: options, now: now)
                XCTFail("\(label): the export survived a stick that died after \(k) of \(total) operations")
            } catch let error as DJMediaExportError {
                XCTAssertTrue(error == .volumeRemoved(volume.path) || error == .volumeNotFound(volume.path), "\(label) \(k): \(error)")
            }

            if case .newFolder = destination {
                let during = snapshot(volume)
                for (path, digest) in before { XCTAssertEqual(during[path], digest, "\(label) \(k): \(path) changed before any recovery") }
            }

            let healthy = DJPosixFileSystem()
            _ = try DJExportRecovery.recover(volume: volume, fs: healthy)
            XCTAssertEqual(DJExportRecovery.inspect(volume: volume, fs: healthy).kind, .clean, "\(label) \(k)")
            XCTAssertEqual(DJExportRecovery.orphanedIncoming(volume: volume, fs: healthy), [], "\(label) \(k)")
            XCTAssertTrue([nil, .rolledBack, .completed].contains(journalState(volume)), "\(label) \(k): \(String(describing: journalState(volume)))")

            let after = snapshot(volume)
            if after == before { continue }
            completedAfterYank += 1
            var replacing = false
            if case .replaceExistingLibrary = destination { replacing = true }
            for (path, digest) in before where !(replacing && path.hasPrefix("PIONEER")) {
                XCTAssertEqual(after[path], digest, "\(label) \(k): \(path) was lost")
            }
            switch destination {
            case .newFolder:
                let folder = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: volume.path).first { $0.hasPrefix("Sounding Export") }, "\(label) \(k)")
                let report = DJMediaValidator.validate(exportRoot: volume.appending(path: folder))
                XCTAssertTrue(report.isValid, "\(label) \(k): \(report.errors)")
            case .volumeRoot:
                let report = DJMediaValidator.validate(exportRoot: volume)
                XCTAssertTrue(report.isValid, "\(label) \(k): \(report.errors)")
            case .replaceExistingLibrary:
                let report = DJMediaValidator.validate(exportRoot: volume)
                XCTAssertTrue(report.isValid, "\(label) \(k): \(report.errors)")
                let stamp = DJMediaExporter.stamp(now)
                for (path, digest) in before where path.hasPrefix("PIONEER/") {
                    let moved = "PIONEER.before-sounding-\(stamp)" + path.dropFirst("PIONEER".count)
                    XCTAssertEqual(after[moved], digest, "\(label) \(k): the old \(path) isn't in the backup")
                }
            }
        }
        XCTAssertLessThan(completedAfterYank, points.count)
    }

    func testPullingTheStickAtAnyPointLeavesTheOldLibraryOrAValidNewOne() async throws {
        try await yankEverywhere(.newFolder(name: nil), withLibrary: true, label: "NEWFOLDER")
        try await yankEverywhere(.volumeRoot, withLibrary: false, label: "BLANK")
        try await yankEverywhere(.replaceExistingLibrary, withLibrary: true, label: "REPLACE")
    }

    func testExportWritesNothingAfterItFinishesAndLeavesAJournal() async throws {
        let volume = try await makeStick("QUIET", withLibrary: false)
        let report = try await DJMediaExporter().export(tracks: try diskTracks(), playlists: [], to: volume, options: DJExportOptions(destination: .volumeRoot))
        XCTAssertEqual(journalState(volume), .completed)
        XCTAssertEqual(DJExportRecovery.inspect(volume: volume).kind, .clean)
        XCTAssertEqual(DJExportRecovery.orphanedIncoming(volume: volume, fs: DJPosixFileSystem()), [])
        let first = snapshot(volume)
        let stamp = try FileManager.default.attributesOfItem(atPath: volume.path)[.modificationDate] as? Date
        _ = DJMediaValidator.validate(exportRoot: report.exportRoot)
        _ = DJExportRecovery.inspect(volume: volume)
        XCTAssertEqual(snapshot(volume), first)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: volume.path)[.modificationDate] as? Date, stamp)
    }

    func testInspectionAndValidationNeverWriteToTheStick() throws {
        let volume = scratch.appending(path: "READONLY", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: volume.appending(path: ".sounding-incoming-abc/PIONEER"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: volume.appending(path: ".sounding-incoming-abc/PIONEER/file"))
        func details() -> [String: String] {
            var out: [String: String] = [:]
            for case let path as String in FileManager.default.enumerator(atPath: volume.path)! {
                let attributes = try? FileManager.default.attributesOfItem(atPath: volume.appending(path: path).path)
                out[path] = "\(attributes?[.modificationDate] ?? "")\(attributes?[.size] ?? "")"
            }
            return out
        }
        let before = details()
        let findings = DJExportRecovery.inspect(volume: volume)
        _ = DJMediaValidator.validate(exportRoot: volume)
        XCTAssertEqual(findings.kind, .unfinished)
        XCTAssertEqual(details(), before)
    }

    func testRecoveryCleansLeftoversAndPutsABackupBack() throws {
        let fs = DJPosixFileSystem()
        let volume = scratch.appending(path: "LEFTOVER", directoryHint: .isDirectory)
        let fm = FileManager.default
        try fm.createDirectory(at: volume.appending(path: ".sounding-incoming-one/Contents"), withIntermediateDirectories: true)
        try fm.createDirectory(at: volume.appending(path: ".sounding-incoming-two"), withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: volume.appending(path: "notes.txt"))
        XCTAssertEqual(DJExportRecovery.inspect(volume: volume).kind, .unfinished)
        let cleaned = try DJExportRecovery.recover(volume: volume, fs: fs)
        XCTAssertEqual(cleaned.outcome, .cleanedUp)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: volume.path), ["notes.txt"])

        try fm.createDirectory(at: volume.appending(path: "PIONEER.before-sounding-20261106-203000/rekordbox"), withIntermediateDirectories: true)
        try Data("pdb".utf8).write(to: volume.appending(path: "PIONEER.before-sounding-20261106-203000/rekordbox/export.pdb"))
        XCTAssertEqual(DJExportRecovery.inspect(volume: volume).kind, .needsLook)
        let restored = try DJExportRecovery.recover(volume: volume, fs: fs)
        XCTAssertEqual(restored.outcome, .rolledBack)
        XCTAssertEqual(try Data(contentsOf: volume.appending(path: "PIONEER/rekordbox/export.pdb")), Data("pdb".utf8))
        XCTAssertEqual(DJExportRecovery.inspect(volume: volume).kind, .clean)
    }

    func testRecoveryRollsBackHalfDoneReplaceFromTheJournal() async throws {
        let volume = try await makeStick("HALFREPLACE", withLibrary: true)
        let fs = DJPosixFileSystem()
        let before = snapshot(volume)
        let fm = FileManager.default
        var journal = DJExportJournal(
            id: "x", state: .committing, destination: "replace", incoming: ".sounding-incoming-half",
            finalFolder: nil, backupStamp: "20261106-203000", addedToContents: ["New Artist/New Album/New.mp3"],
            rootHadLibrary: true, rootHadContents: true, startedAt: Date(), updatedAt: Date()
        )
        try journal.write(volume: volume, state: .committing, fs: fs)
        try fm.createDirectory(at: volume.appending(path: ".sounding-incoming-half"), withIntermediateDirectories: true)
        try fm.createDirectory(at: volume.appending(path: "Contents/New Artist/New Album"), withIntermediateDirectories: true)
        try Data("new".utf8).write(to: volume.appending(path: "Contents/New Artist/New Album/New.mp3"))
        try fm.moveItem(at: volume.appending(path: "PIONEER"), to: volume.appending(path: "PIONEER.before-sounding-20261106-203000"))

        XCTAssertEqual(DJExportRecovery.inspect(volume: volume).kind, .unfinished)
        let report = try DJExportRecovery.recover(volume: volume, fs: fs)
        XCTAssertEqual(report.outcome, .rolledBack)
        XCTAssertEqual(snapshot(volume), before)
        XCTAssertEqual(journalState(volume), .rolledBack)
    }

    func testScrubberRemovesAppleDoubleAndDSStoreFilesOnly() throws {
        let fs = DJPosixFileSystem()
        let root = scratch.appending(path: "SCRUB", directoryHint: .isDirectory)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appending(path: "PIONEER/rekordbox"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appending(path: "Contents/Artist/Album"), withIntermediateDirectories: true)
        for path in ["PIONEER/._export.pdb", "PIONEER/.DS_Store", "Contents/Artist/Album/._song.mp3", "Contents/.DS_Store"] {
            try Data("x".utf8).write(to: root.appending(path: path))
        }
        try Data("keep".utf8).write(to: root.appending(path: "Contents/Artist/Album/song.mp3"))
        try Data("keep".utf8).write(to: root.appending(path: "PIONEER/rekordbox/export.pdb"))
        let roots = [root.appending(path: "PIONEER"), root.appending(path: "Contents")]
        XCTAssertEqual(DJExportScrubber.strays(roots, fs: fs).count, 4)
        let removed = try DJExportScrubber.scrub(roots, fs: fs)
        XCTAssertEqual(removed.count, 4)
        XCTAssertEqual(DJExportScrubber.strays(roots, fs: fs), [])
        XCTAssertTrue(fm.fileExists(atPath: root.appending(path: "Contents/Artist/Album/song.mp3").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appending(path: "PIONEER/rekordbox/export.pdb").path))
    }

    func testReplaceScrubsStrayFilesFinderLeftInContents() async throws {
        let volume = try await makeStick("STRAYS", withLibrary: true)
        let contents = volume.appending(path: "Contents")
        try Data("x".utf8).write(to: contents.appending(path: ".DS_Store"))
        try Data("x".utf8).write(to: contents.appending(path: "._junk"))
        _ = try await DJMediaExporter().export(tracks: try diskTracks(), playlists: [], to: volume, options: DJExportOptions(destination: .replaceExistingLibrary))
        XCTAssertEqual(DJExportScrubber.strays([volume.appending(path: "PIONEER"), contents], fs: DJPosixFileSystem()), [])
    }

    func testExportRefusesWhenThereIsNotEnoughSpaceAndBeatsWhileCopying() async throws {
        let volume = try await makeStick("FULL", withLibrary: false)
        let tracks = try diskTracks()
        do {
            _ = try await DJMediaExporter(spaceMargin: Int64.max / 4).export(tracks: tracks, playlists: [], to: volume, options: DJExportOptions(destination: .volumeRoot))
            XCTFail("expected a space refusal")
        } catch let error as DJMediaExportError {
            guard case .notEnoughSpace = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: volume.path), [])

        final class Beats: @unchecked Sendable { var count = 0 }
        let beats = Beats()
        _ = try await DJMediaExporter(heartbeat: { beats.count += 1 }).export(tracks: tracks, playlists: [], to: volume, options: DJExportOptions(destination: .volumeRoot))
        XCTAssertGreaterThan(beats.count, 4)
    }

    func testVolumeInfoReportsAFilesystem() {
        let info = DJVolumeInfo.inspect(scratch)
        XCTAssertNotNil(info)
        XCTAssertGreaterThan(info?.totalBytes ?? 0, 0)
        XCTAssertEqual(info?.isDJPlayerFormat, info?.kind == .fat || info?.kind == .exfat)
    }

    // MARK: - Fuzzing

    private func fuzz(_ seed: Data, rounds: Int, seedValue: UInt64, decode: (Data) -> Void) {
        var rng = FuzzGenerator(state: seedValue)
        let original = [UInt8](seed)
        for round in 0 ..< rounds {
            var bytes = original
            switch round % 4 {
            case 0:
                bytes = Array(bytes.prefix(Int.random(in: 0 ... bytes.count, using: &rng)))
            case 1:
                for _ in 0 ..< Int.random(in: 1 ... 64, using: &rng) where !bytes.isEmpty {
                    bytes[Int.random(in: 0 ..< bytes.count, using: &rng)] = UInt8.random(in: 0 ... 255, using: &rng)
                }
            case 2:
                for _ in 0 ..< 8 where bytes.count > 4 {
                    let at = Int.random(in: 0 ..< bytes.count - 4, using: &rng)
                    let value: [UInt8] = [[0xFF, 0xFF, 0xFF, 0xFF], [0, 0, 0, 0], [0x7F, 0xFF, 0xFF, 0xFF], [0, 0, 0x10, 0]][Int.random(in: 0 ..< 4, using: &rng)]
                    bytes.replaceSubrange(at ..< at + 4, with: value)
                }
            default:
                let cut = Int.random(in: 0 ... bytes.count, using: &rng)
                bytes = Array(bytes.prefix(cut)) + (0 ..< Int.random(in: 0 ... 512, using: &rng)).map { _ in UInt8.random(in: 0 ... 255, using: &rng) }
            }
            decode(Data(bytes))
        }
    }

    func testReadersNeverCrashOnCorruptInput() throws {
        var fuzzTracks = sampleTracks()
        fuzzTracks[1].waveform = bandedWaveform()
        let plan = try DJExportPlanner.plan(tracks: fuzzTracks, playlists: samplePlaylists())
        let (generated, files) = try inMemoryExport(plan)
        XCTAssertTrue(files.keys.contains { $0.hasSuffix(".2EX") })
        let pdbSeeds = [try fixture("pyrekordbox-export", "pdb"), try fixture("pyrekordbox-exportExt", "pdb"), generated]
        for (i, seed) in pdbSeeds.enumerated() {
            fuzz(seed, rounds: 160, seedValue: UInt64(1000 + i)) { data in
                _ = try? PDBReader.read(data)
                _ = try? PDBReader.readExt(data)
                _ = DJMediaValidator.validate(pdb: data, file: { files[$0] }, fileSize: { _ in 1 })
            }
        }
        let anlzSeeds = [try fixture("pyrekordbox-P016-0000875E", "DAT"), try fixture("pyrekordbox-P016-0000875E", "EXT")] + files.values.sorted { $0.count < $1.count }
        for (i, seed) in anlzSeeds.enumerated() {
            fuzz(seed, rounds: 240, seedValue: UInt64(2000 + i)) { data in
                if let read = try? ANLZCodec.read(data) {
                    _ = ANLZCodec.write(read.file)
                }
            }
        }
        XCTAssertThrowsError(try PDBReader.read(Data()))
        XCTAssertThrowsError(try ANLZCodec.read(Data("PMAI".utf8)))
    }

    // MARK: - Files on disk

    private func writeTone(_ name: String, frequency: Double, seconds: Double, rate: Double = 44100) throws -> URL {
        let url = scratch.appending(path: name)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for c in 0 ..< 2 {
            let channel = try XCTUnwrap(buffer.floatChannelData)[c]
            for i in 0 ..< Int(frames) {
                let envelope = Float(i % 22050) / 22050
                channel[i] = Float(sin(2 * Double.pi * frequency * Double(i) / rate)) * 0.8 * envelope
            }
        }
        try file.write(from: buffer)
        return url
    }

    func testAudioAnalysisProducesDetailRateWaveformAndBands() throws {
        let bass = try writeTone("bass.wav", frequency: 60, seconds: 2)
        let hats = try writeTone("hats.wav", frequency: 8000, seconds: 2)
        let info = try DJAudioAnalysis.info(bass)
        XCTAssertEqual(info.durationSeconds, 2, accuracy: 0.01)
        XCTAssertEqual(info.sampleRate, 44100)
        let low = try DJAudioAnalysis.waveform(bass)
        let high = try DJAudioAnalysis.waveform(hats)
        XCTAssertEqual(Double(low.amplitude.count), 300, accuracy: 2)
        XCTAssertTrue(low.hasBands)
        let lowSum = try XCTUnwrap(low.low).reduce(0, +), lowHigh = try XCTUnwrap(low.high).reduce(0, +)
        let highSum = try XCTUnwrap(high.low).reduce(0, +), highHigh = try XCTUnwrap(high.high).reduce(0, +)
        XCTAssertGreaterThan(lowSum, lowHigh * 4)
        XCTAssertGreaterThan(highHigh, highSum * 4)
    }

    private func makeJPEG(side: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: 1, green: 0.42, blue: 0.1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let image = try XCTUnwrap(context.makeImage())
        let out = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return out as Data
    }

    private func pixelWidth(_ url: URL) throws -> Int {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
    }

    private func diskTracks() throws -> [DJExportTrackRecord] {
        let a = try writeTone("Warehouse Tool.mp3.wav", frequency: 110, seconds: 3)
        let b = try writeTone("Second.wav", frequency: 440, seconds: 2)
        var tracks = sampleTracks(audio: [a, b])
        tracks[0].metadata.durationSeconds = 3
        tracks[0].cues = tracks[0].cues.filter { $0.startSeconds < 3 }
        tracks[0].phrases = nil
        tracks[0].waveform = try DJAudioAnalysis.waveform(a)
        tracks[1].metadata.durationSeconds = 2
        return tracks
    }

    func testExportToNewFolderLeavesExistingStickUntouched() async throws {
        let volume = scratch.appending(path: "STICK", directoryHint: .isDirectory)
        let existing = volume.appending(path: "PIONEER/rekordbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let fixtureData = try fixture("pyrekordbox-export", "pdb")
        try fixtureData.write(to: existing.appending(path: "export.pdb"))

        let report = try await DJMediaExporter().export(tracks: try diskTracks(), playlists: samplePlaylists(), to: volume, now: Date(timeIntervalSince1970: 1_793_000_000))
        XCTAssertEqual(report.exportedTrackCount, 2)
        XCTAssertEqual(report.exportRoot.deletingLastPathComponent().standardizedFileURL.path, volume.standardizedFileURL.path)
        XCTAssertTrue(report.exportRoot.lastPathComponent.hasPrefix("Sounding Export "))
        XCTAssertEqual(try Data(contentsOf: existing.appending(path: "export.pdb")), fixtureData)
        let validation = DJMediaValidator.validate(exportRoot: report.exportRoot)
        XCTAssertTrue(validation.isValid, "\(validation.errors)")
        XCTAssertEqual(validation.database?.tracks.count, 2)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: volume.path).filter { $0.hasPrefix(".sounding-incoming") }
        XCTAssertEqual(leftovers, [])

        do {
            _ = try await DJMediaExporter().export(tracks: try diskTracks(), playlists: [], to: volume, options: DJExportOptions(destination: .volumeRoot))
            XCTFail("volume root must refuse a stick that already has a library")
        } catch let error as DJMediaExportError {
            XCTAssertEqual(error, .existingLibrary(volume.path))
        }
        XCTAssertEqual(try Data(contentsOf: existing.appending(path: "export.pdb")), fixtureData)
    }

    func testExportToEmptyVolumeRootAndExplicitReplace() async throws {
        let volume = scratch.appending(path: "BLANK", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        var tracks = try diskTracks()
        tracks[0].metadata.artworkJPEG = try makeJPEG(side: 600)
        let report = try await DJMediaExporter().export(tracks: tracks, playlists: samplePlaylists(), to: volume, options: DJExportOptions(destination: .volumeRoot))
        XCTAssertEqual(report.exportRoot.standardizedFileURL.path, volume.standardizedFileURL.path)
        let first = DJMediaValidator.validate(exportRoot: volume)
        XCTAssertTrue(first.isValid, "\(first.errors)")
        XCTAssertEqual(first.database?.artwork.map(\.path), ["/PIONEER/Artwork/00001/a1.jpg"])
        XCTAssertEqual(first.database?.tracks.first?.artworkId, 1)
        XCTAssertEqual(try pixelWidth(volume.appending(path: "PIONEER/Artwork/00001/a1.jpg")), 80)
        XCTAssertEqual(try pixelWidth(volume.appending(path: "PIONEER/Artwork/00001/a1_m.jpg")), 240)

        let replaced = try await DJMediaExporter().export(tracks: try diskTracks(), playlists: [], to: volume, options: DJExportOptions(destination: .replaceExistingLibrary))
        XCTAssertEqual(replaced.exportedTrackCount, 2)
        let names = try FileManager.default.contentsOfDirectory(atPath: volume.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("PIONEER.before-sounding-") })
        let after = DJMediaValidator.validate(exportRoot: volume)
        XCTAssertTrue(after.isValid, "\(after.errors)")
        XCTAssertEqual(after.database?.playlistTree.count, 0)
    }

    func testCancelledExportWritesNothing() async throws {
        let volume = scratch.appending(path: "CANCEL", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        let tracks = try diskTracks()
        let task = Task {
            try await DJMediaExporter().export(tracks: tracks, playlists: [], to: volume, options: DJExportOptions(destination: .volumeRoot))
        }
        task.cancel()
        _ = try? await task.value
        let names = try FileManager.default.contentsOfDirectory(atPath: volume.path)
        let visible = names.filter { !Self.bookkeeping.contains($0) }
        XCTAssertTrue(visible.isEmpty || DJMediaValidator.validate(exportRoot: volume).isValid, "\(names)")
        XCTAssertFalse(names.contains { $0.hasPrefix(".sounding-incoming") })
    }
}
