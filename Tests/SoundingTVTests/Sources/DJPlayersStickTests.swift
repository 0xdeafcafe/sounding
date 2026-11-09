import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import SoundingTV

enum DJStickFixture {
    static let anlzFolder = "PIONEER/USBANLZ/P016/0000875E"

    static func data(_ name: String, _ ext: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: DJStickTestAnchor.self).url(forResource: name, withExtension: ext), "missing fixture \(name).\(ext)")
        return try Data(contentsOf: url)
    }

    static func makeStick(named name: String = "STICK", pdb: String = "pyrekordbox-export", withAnalysis: Bool = true) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "DJStick-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: name, directoryHint: .isDirectory)
        let rekordbox = root.appending(path: "PIONEER/rekordbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: rekordbox, withIntermediateDirectories: true)
        try data(pdb, "pdb").write(to: rekordbox.appending(path: "export.pdb"))
        if withAnalysis {
            let folder = root.appending(path: anlzFolder, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data("pyrekordbox-P016-0000875E", "DAT").write(to: folder.appending(path: "ANLZ0000.DAT"))
            try data("pyrekordbox-P016-0000875E", "EXT").write(to: folder.appending(path: "ANLZ0000.EXT"))
        }
        return root
    }

    static func remove(_ root: URL) {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    static func lockDown(_ root: URL) throws {
        let manager = FileManager.default
        let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        var directories: [URL] = [root]
        while let url = enumerator?.nextObject() as? URL {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory { directories.append(url) } else { try manager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path) }
        }
        for directory in directories.reversed() { try manager.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path) }
    }

    static func unlock(_ root: URL) {
        let manager = FileManager.default
        try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])
        while let url = enumerator?.nextObject() as? URL {
            try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    static func fingerprint(_ root: URL) throws -> [String: String] {
        var out: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
            let relative = String(url.path.dropFirst(root.path.count))
            let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            if values.isDirectory == true {
                out[relative] = "dir|\(mtime)"
            } else {
                let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
                out[relative] = "\(values.fileSize ?? 0)|\(mtime)|\(digest)"
            }
        }
        return out
    }
}

final class DJStickTestAnchor {}

struct FixtureStickCatalog: DJPlayersStickCatalog {
    var roots: [(id: String, path: String)]
    var cache: DJStickLibraryCache
    var generationValue = 1

    func generation() async -> Int { generationValue }

    func candidates(rekordboxId: UInt32) async -> [DJPlayersStickCandidate] {
        var found: [DJPlayersStickCandidate] = []
        for root in roots {
            guard let library = await cache.library(volumeKey: root.id, root: root.path), let track = library.track(id: rekordboxId) else { continue }
            found.append(DJPlayersStickCandidate(
                volume: root.id,
                title: track.title,
                artist: track.artist.isEmpty ? nil : track.artist,
                durationSeconds: track.durationSeconds,
                bpm: track.bpm,
                isrc: track.isrc
            ))
        }
        return found
    }
}

actor CountingCollection: DJPlayersCollectionCatalog {
    private(set) var lookupCount = 0
    private let infos: [String: DJPlayersTrackInfo]

    init(_ infos: [String: DJPlayersTrackInfo]) { self.infos = infos }

    func generation() async -> Int { 1 }

    func track(rekordboxId: String) async -> DJPlayersTrackInfo? {
        lookupCount += 1
        return infos[rekordboxId]
    }
}

final class DJStickLookupTests: XCTestCase {
    private var sticks: [URL] = []

    override func tearDown() {
        for stick in sticks {
            DJStickFixture.unlock(stick)
            DJStickFixture.remove(stick)
        }
        sticks = []
        super.tearDown()
    }

    private func stick(_ name: String = "STICK", pdb: String = "pyrekordbox-export", withAnalysis: Bool = true) throws -> URL {
        let url = try DJStickFixture.makeStick(named: name, pdb: pdb, withAnalysis: withAnalysis)
        sticks.append(url)
        return url
    }

    private func key(_ id: UInt32, slot: DJPlayerMediaSlot = .usb, type: UInt8 = 1, player: Int = 1) -> DJPlayerTrackKey {
        DJPlayerTrackKey(sourcePlayer: player, slot: slot, trackType: type, rekordboxId: id)
    }

    func testReadsTitlesByPDBRowID() throws {
        let root = try stick()
        let loaded = try DJStickLoader.load(root: root.path)
        let library = loaded.library
        XCTAssertEqual(library.tracks.count, 6)
        let demo = try XCTUnwrap(library.track(id: 1))
        XCTAssertEqual(demo.title, "Demo Track 1")
        XCTAssertEqual(demo.artist, "Loopmasters")
        XCTAssertEqual(demo.durationSeconds, 172)
        XCTAssertEqual(try XCTUnwrap(demo.bpm), 128, accuracy: 0.001)
        XCTAssertEqual(demo.analyzePath, "/PIONEER/USBANLZ/P016/0000875E/ANLZ0000.DAT")
        XCTAssertNil(library.track(id: 9999))
        let sub = try XCTUnwrap(library.playlists.first { $0.name == "Sub Playlist" })
        XCTAssertEqual(sub.path, ["Folder"])
        XCTAssertEqual(sub.trackIds, [1, 2])
        XCTAssertEqual(library.tracks(in: sub).map(\.title).first, "Demo Track 1")
    }

    func testHiddenPioneerFolderIsRecognised() throws {
        let root = try stick(pdb: "rekordbox-pdb-one-song-export", withAnalysis: false)
        let manager = FileManager.default
        try manager.moveItem(at: root.appending(path: "PIONEER"), to: root.appending(path: ".PIONEER"))
        XCTAssertTrue(DJStickLayout.isStick(root: root.path))
        let library = try DJStickLoader.load(root: root.path).library
        XCTAssertEqual(library.tracks.map(\.title), ["Super Smash Bros."])
    }

    func testNotAStick() throws {
        let empty = FileManager.default.temporaryDirectory.appending(path: "NotAStick-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        XCTAssertFalse(DJStickLayout.isStick(root: empty.path))
        XCTAssertThrowsError(try DJStickLoader.load(root: empty.path)) { XCTAssertEqual($0 as? DJStickError, .notAStick) }
    }

    func testResolverReadsUSBAndSDSlotsFromTheMountedStick() async throws {
        let root = try stick()
        let cache = DJStickLibraryCache()
        let resolver = DJPlayersTrackResolver(sticks: FixtureStickCatalog(roots: [("a", root.path)], cache: cache))
        let usb = await resolver.track(for: key(1), hint: DJPlayerTrackHint(lengthSeconds: 172, bpm: 128))
        XCTAssertEqual(usb?.title, "Demo Track 1")
        XCTAssertEqual(usb?.artist, "Loopmasters")
        let sd = await resolver.track(for: key(1, slot: .sd, player: 2), hint: nil)
        XCTAssertEqual(sd?.title, "Demo Track 1")
        let missing = await resolver.track(for: key(4242), hint: nil)
        XCTAssertNil(missing)
    }

    func testResolverFallsBackWhenTheStickIsNotOnThisMac() async throws {
        let resolver = DJPlayersTrackResolver()
        let result = await resolver.track(for: key(1), hint: nil)
        XCTAssertNil(result)
        let collection = await resolver.track(for: key(1, slot: .collection), hint: nil)
        XCTAssertNil(collection)
    }

    func testResolverRejectsATrackWhoseLengthDisagreesWithTheMountedStick() async throws {
        let root = try stick()
        let catalog = FixtureStickCatalog(roots: [("a", root.path)], cache: DJStickLibraryCache())
        let wrong = await DJPlayersTrackResolver(sticks: catalog).track(for: key(1), hint: DJPlayerTrackHint(lengthSeconds: 301, bpm: 128))
        XCTAssertNil(wrong)
        let close = await DJPlayersTrackResolver(sticks: catalog).track(for: key(1), hint: DJPlayerTrackHint(lengthSeconds: 173, bpm: nil))
        XCTAssertEqual(close?.title, "Demo Track 1")
    }

    func testResolverOnlyHandlesRekordboxTracksOnStickAndCollectionSlots() async throws {
        let root = try stick()
        let resolver = DJPlayersTrackResolver(sticks: FixtureStickCatalog(roots: [("a", root.path)], cache: DJStickLibraryCache()))
        let cd = await resolver.track(for: key(1, slot: .cd), hint: nil)
        XCTAssertNil(cd)
        let streaming = await resolver.track(for: key(1, slot: .streaming), hint: nil)
        XCTAssertNil(streaming)
        let unanalysed = await resolver.track(for: key(1, type: 0x05), hint: nil)
        XCTAssertNil(unanalysed)
    }

    func testTwoSticksSharingAnIDAreSplitByLength() async throws {
        let first = try stick("ONE")
        let second = try stick("TWO", pdb: "rekordbox-pdb-one-song-export", withAnalysis: false)
        let catalog = FixtureStickCatalog(roots: [("one", first.path), ("two", second.path)], cache: DJStickLibraryCache())
        let other = try XCTUnwrap(try DJStickLoader.load(root: second.path).library.tracks.first)
        let firstTrack = try XCTUnwrap(try DJStickLoader.load(root: first.path).library.track(id: other.id))
        let sharedKey = key(other.id)
        let ambiguous = await DJPlayersTrackResolver(sticks: catalog).track(for: sharedKey, hint: nil)
        XCTAssertNil(ambiguous)
        let split = await DJPlayersTrackResolver(sticks: catalog).track(for: sharedKey, hint: DJPlayerTrackHint(lengthSeconds: other.durationSeconds, bpm: nil))
        if abs(firstTrack.durationSeconds - other.durationSeconds) > 2 {
            XCTAssertEqual(split?.title, "Super Smash Bros.")
        }
    }

    func testStickCacheLoadsEachVolumeOnceAndReloadsWhenTheStickChanges() async throws {
        let root = try stick()
        let cache = DJStickLibraryCache()
        for _ in 0..<5 {
            let library = await cache.library(volumeKey: "v", root: root.path)
            XCTAssertEqual(library?.tracks.count, 6)
        }
        let loadsAfterReads = await cache.loadCount
        XCTAssertEqual(loadsAfterReads, 1)

        let pdb = root.appending(path: "PIONEER/rekordbox/export.pdb")
        try DJStickFixture.data("rekordbox-pdb-one-song-export", "pdb").write(to: pdb)
        let replaced = await cache.library(volumeKey: "v", root: root.path)
        XCTAssertEqual(replaced?.tracks.map(\.title), ["Super Smash Bros."])
        let loadsAfterReplace = await cache.loadCount
        XCTAssertEqual(loadsAfterReplace, 2)

        try? FileManager.default.removeItem(at: pdb)
        let gone = await cache.library(volumeKey: "v", root: root.path)
        XCTAssertNil(gone)
    }

    func testUnresolvedTracksAreNotRetriedUntilTheMountedSticksChange() async throws {
        let root = try stick()
        let cache = DJStickLibraryCache()
        let resolver = DJPlayersTrackResolver(sticks: FixtureStickCatalog(roots: [("a", root.path)], cache: cache))
        let miss = await resolver.track(for: key(777), hint: nil)
        XCTAssertNil(miss)
        let before = await cache.loadCount
        for _ in 0..<5 { _ = await resolver.track(for: key(777), hint: nil) }
        let after = await cache.loadCount
        XCTAssertEqual(before, after)
    }

    func testMatchesStickTracksToSoundCloudThroughTheMatcher() async throws {
        let root = try stick()
        let candidates = [
            MatchCandidate(trackId: "soundcloud:tracks:7", title: "Demo Track 1", artist: "Loopmasters", durationSeconds: 172.4),
            MatchCandidate(trackId: "soundcloud:tracks:8", title: "Something Else", artist: "Nobody", durationSeconds: 200),
        ]
        let resolver = DJPlayersTrackResolver(
            sticks: FixtureStickCatalog(roots: [("a", root.path)], cache: DJStickLibraryCache()),
            library: { candidates }
        )
        let hit = await resolver.track(for: key(1), hint: nil)
        XCTAssertEqual(hit?.soundCloudTrackId, "soundcloud:tracks:7")
        let plain = await resolver.track(for: key(2), hint: nil)
        XCTAssertNotNil(plain)
        XCTAssertNil(plain?.soundCloudTrackId)
    }

    func testAmbiguousSoundCloudMatchesAreLeftUnlinked() async throws {
        let root = try stick()
        let candidates = [
            MatchCandidate(trackId: "a", title: "Demo Track 1", artist: "Loopmasters", durationSeconds: 172),
            MatchCandidate(trackId: "b", title: "Demo Track 1", artist: "Loopmasters", durationSeconds: 173),
        ]
        let resolver = DJPlayersTrackResolver(
            sticks: FixtureStickCatalog(roots: [("a", root.path)], cache: DJStickLibraryCache()),
            library: { candidates }
        )
        let result = await resolver.track(for: key(1), hint: nil)
        XCTAssertEqual(result?.title, "Demo Track 1")
        XCTAssertNil(result?.soundCloudTrackId)
    }

    func testCollectionSlotUsesImportedXMLTrackIDs() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "DJStickLinks-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CueStore(directory: directory, writerId: "test")
        await store.saveLink(TrackLink(trackId: "soundcloud:tracks:42", title: "Glue", artist: "Bicep", durationMillis: 270_000, rekordboxTrackId: "3311"))
        await store.saveLink(TrackLink(trackId: "soundcloud:tracks:43", title: "Unlinked", artist: "", durationMillis: 100_000))
        let resolver = DJPlayersTrackResolver(collection: DJPlayersTrackLinkCollection(store: store))

        let glue = await resolver.track(for: key(3311, slot: .collection), hint: nil)
        XCTAssertEqual(glue, DJPlayersTrackInfo(title: "Glue", artist: "Bicep", soundCloudTrackId: "soundcloud:tracks:42"))
        let unknown = await resolver.track(for: key(99, slot: .collection), hint: nil)
        XCTAssertNil(unknown)
        let onStick = await resolver.track(for: key(3311, slot: .usb), hint: nil)
        XCTAssertNil(onStick)
    }

    func testCollectionLookupsAreCached() async throws {
        let collection = CountingCollection(["5": DJPlayersTrackInfo(title: "Five", artist: nil)])
        let resolver = DJPlayersTrackResolver(collection: collection)
        for _ in 0..<4 {
            let info = await resolver.track(for: key(5, slot: .collection), hint: nil)
            XCTAssertEqual(info?.title, "Five")
        }
        for _ in 0..<4 { _ = await resolver.track(for: key(6, slot: .collection), hint: nil) }
        let lookups = await collection.lookupCount
        XCTAssertEqual(lookups, 2)
    }

    func testRecordedSetlistGetsTitlesOnceTheStickAppears() throws {
        let start = Date(timeIntervalSince1970: 1_793_998_800)
        var builder = DJPlayersSetlistBuilder(startedAt: start)
        let unknownKey = key(1)
        let play = DJPlayersRecordedPlay(playerNumber: 1, playerName: "CDJ-3000", track: unknownKey, startedAt: start.addingTimeInterval(10))
        let first = builder.append(play, info: nil, now: start.addingTimeInterval(40))
        XCTAssertEqual(first.activeSegments.map(\.displayLabel), ["Unknown Track"])
        XCTAssertNil(builder.fillTitles(from: [:], now: start.addingTimeInterval(41)))
        let info = DJPlayersTrackInfo(title: "Demo Track 1", artist: "Loopmasters", soundCloudTrackId: "soundcloud:tracks:7")
        let filled = try XCTUnwrap(builder.fillTitles(from: [unknownKey: info], now: start.addingTimeInterval(50)))
        XCTAssertEqual(filled.activeSegments.map(\.displayLabel), ["Loopmasters – Demo Track 1"])
        XCTAssertEqual(filled.activeSegments.first?.soundCloudTrackId, "soundcloud:tracks:7")
        XCTAssertNil(builder.fillTitles(from: [unknownKey: info], now: start.addingTimeInterval(60)))
    }

    // MARK: - Read-only

    func testOpensWithReadOnlyFlagsAndNothingElse() {
        let flags = DJStickPOSIXIO.openFlags
        XCTAssertEqual(flags & O_ACCMODE, O_RDONLY)
        for forbidden in [O_WRONLY, O_RDWR, O_CREAT, O_TRUNC, O_APPEND, O_EXCL, O_EXLOCK, O_SHLOCK] where forbidden != O_RDONLY {
            XCTAssertEqual(flags & forbidden, 0, "flag \(forbidden)")
        }
        XCTAssertNotEqual(flags & O_CLOEXEC, 0)
    }

    func testReadingNeverWritesAnythingToTheStick() throws {
        let root = try stick()
        let before = try DJStickFixture.fingerprint(root)
        XCTAssertFalse(before.isEmpty)
        let loaded = try DJStickLoader.load(root: root.path)
        let track = try XCTUnwrap(loaded.library.track(id: 1))
        XCTAssertNotNil(DJStickLoader.analysis(for: track, root: root.path))
        _ = DJStickLayout.isStick(root: root.path)
        XCTAssertEqual(try DJStickFixture.fingerprint(root), before)
    }

    func testReadingWorksOnAStickThatCannotBeWrittenTo() async throws {
        let root = try stick()
        try DJStickFixture.lockDown(root)
        XCTAssertFalse(FileManager.default.isWritableFile(atPath: root.appending(path: "PIONEER/rekordbox/export.pdb").path))
        let loaded = try DJStickLoader.load(root: root.path)
        let track = try XCTUnwrap(loaded.library.track(id: 1))
        XCTAssertNotNil(DJStickLoader.analysis(for: track, root: root.path))
        let cache = DJStickLibraryCache()
        let cached = await cache.library(volumeKey: "ro", root: root.path)
        XCTAssertEqual(cached?.tracks.count, 6)
    }

    func testReaderRefusesPathsThatEscapeTheStick() throws {
        XCTAssertNil(DJStickLayout.safeDevicePath("/PIONEER/../../etc/passwd"))
        XCTAssertNil(DJStickLayout.safeDevicePath(""))
        XCTAssertNil(DJStickLayout.safeDevicePath("/a\0b"))
        XCTAssertEqual(DJStickLayout.safeDevicePath("//PIONEER//USBANLZ/x.DAT"), "/PIONEER/USBANLZ/x.DAT")
        let root = try stick()
        var evil = try XCTUnwrap(try DJStickLoader.load(root: root.path).library.track(id: 1))
        evil.analyzePath = "/PIONEER/../../../../etc/hosts"
        XCTAssertNil(DJStickLoader.analysis(for: evil, root: root.path))
    }

    func testOnlyReadOperationsReachTheIO() throws {
        let root = try stick()
        let recorder = RecordingIO(base: DJStickPOSIXIO())
        let loaded = try DJStickLoader.load(root: root.path, io: recorder)
        let track = try XCTUnwrap(loaded.library.track(id: 1))
        _ = DJStickLoader.analysis(for: track, root: root.path, io: recorder)
        XCTAssertFalse(recorder.operations.isEmpty)
        XCTAssertTrue(recorder.operations.allSatisfy { $0.hasPrefix("read ") || $0.hasPrefix("stat ") }, "\(recorder.operations)")
    }

    func testOversizedFilesAreRefused() throws {
        let root = try stick()
        let pdb = root.appending(path: "PIONEER/rekordbox/export.pdb").path
        XCTAssertThrowsError(try DJStickPOSIXIO().readFile(atPath: pdb, maxBytes: 100)) {
            XCTAssertEqual($0 as? DJStickError, .tooLarge(pdb))
        }
        XCTAssertThrowsError(try DJStickPOSIXIO().readFile(atPath: root.path, maxBytes: 1 << 20))
    }

    // MARK: - ANLZ

    func testAnalysisReadsTheGridAndCuesFromANLZ() throws {
        let root = try stick()
        let track = try XCTUnwrap(try DJStickLoader.load(root: root.path).library.track(id: 1))
        let analysis = try XCTUnwrap(DJStickLoader.analysis(for: track, root: root.path))
        let first = try XCTUnwrap(analysis.tempos.first)
        XCTAssertEqual(first.bpm, 128, accuracy: 0.001)
        XCTAssertEqual(first.startSeconds, 0.025, accuracy: 0.0005)
        XCTAssertEqual(first.beatInBar, 1)
        XCTAssertEqual(analysis.tempos.count, 1)
    }

    func testCuesAreMappedFromLegacyAndExtendedLists() {
        var hot = ANLZCue(timeMillis: 31_500)
        hot.hotCue = 2
        hot.comment = "Drop"
        hot.colorRed = 0x28; hot.colorGreen = 0xE2; hot.colorBlue = 0x14
        var memory = ANLZCue(timeMillis: 500)
        memory.comment = "Intro"
        var loop = ANLZCue(timeMillis: 64_000)
        loop.isLoop = true
        loop.loopTimeMillis = 72_000
        var hotLoop = ANLZCue(timeMillis: 80_000)
        hotLoop.isLoop = true
        hotLoop.hotCue = 5
        hotLoop.loopTimeMillis = 82_000
        var beats: [ANLZBeat] = []
        for index in 0..<8 {
            beats.append(ANLZBeat(beatNumber: UInt16(index % 4 + 1), tempo: 12_800, timeMillis: UInt32(25 + index * 469)))
        }
        beats.append(ANLZBeat(beatNumber: 1, tempo: 13_000, timeMillis: 4_000))
        let file = ANLZFile(tags: [
            .beatGrid(beats),
            .extendedCueList(ANLZCueList(kind: .memory, cues: [memory, loop])),
            .extendedCueList(ANLZCueList(kind: .hotCues, cues: [hot, hotLoop])),
        ])
        let analysis = DJStickAnalysis.summarise(dat: file, ext: nil)
        XCTAssertEqual(analysis.tempos.map(\.bpm), [128, 130])
        XCTAssertEqual(analysis.tempos.map(\.beatInBar), [1, 1])
        XCTAssertEqual(analysis.marks.map(\.kind), [.memory, .hotCue, .loop, .loop])
        XCTAssertEqual(analysis.marks.map(\.slot), [nil, 1, nil, 4])
        XCTAssertEqual(analysis.marks[1].label, "Drop")
        XCTAssertEqual(analysis.marks[1].rgb, 0x28E214)
        XCTAssertEqual(analysis.marks[2].endSeconds, 72)
        XCTAssertEqual(analysis.marks[3].xmlType, 4)
        XCTAssertEqual(analysis.marks[3].xmlNum, 4)
        XCTAssertEqual(analysis.marks[0].xmlNum, -1)
        XCTAssertEqual(analysis.marks[1].red, 0x28)

        let legacy = ANLZFile(tags: [
            .cueList(ANLZCueList(kind: .hotCues, cues: [hot], memoryCount: 0)),
            .cueList(ANLZCueList(kind: .memory, cues: [memory], memoryCount: 1)),
        ])
        let fromLegacy = DJStickAnalysis.summarise(dat: legacy, ext: nil)
        XCTAssertEqual(fromLegacy.marks.map(\.kind), [.memory, .hotCue])
    }
}

final class RecordingIO: DJStickIO, @unchecked Sendable {
    private let base: DJStickIO
    private let lock = NSLock()
    private var recorded: [String] = []

    init(base: DJStickIO) { self.base = base }

    var operations: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func readFile(atPath path: String, maxBytes: Int) throws -> Data {
        lock.lock()
        recorded.append("read \(path)")
        lock.unlock()
        return try base.readFile(atPath: path, maxBytes: maxBytes)
    }

    func stamp(atPath path: String) -> DJStickFileStamp? {
        lock.lock()
        recorded.append("stat \(path)")
        lock.unlock()
        return base.stamp(atPath: path)
    }
}

final class DJPlayersTempoReferenceTests: XCTestCase {
    private func reference(bpm: Double, lastBeatAt: TimeInterval? = 100, running: Bool = true) -> DJPlayersTempoReference {
        DJPlayersTempoReference(masterNumber: 2, bpm: bpm, lastBeatAt: lastBeatAt, beatWithinBar: 1, isRunning: running)
    }

    func testPlaybackRatioMatchesTheMasterWithinTheBudget() throws {
        let tempo = reference(bpm: 128)
        XCTAssertEqual(try XCTUnwrap(tempo.playbackRatio(forTrackBPM: 126, maxPercent: 8)), 128.0 / 126, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(tempo.playbackRatio(forTrackBPM: 128, maxPercent: 8)), 1, accuracy: 1e-9)
        XCTAssertNil(tempo.playbackRatio(forTrackBPM: 110, maxPercent: 8))
        XCTAssertNil(tempo.playbackRatio(forTrackBPM: 0, maxPercent: 8))
        XCTAssertNil(reference(bpm: 0).playbackRatio(forTrackBPM: 128, maxPercent: 8))
    }

    func testPhaseDifferenceIsSignedAndWrapped() throws {
        let tempo = reference(bpm: 120, lastBeatAt: 100)
        XCTAssertEqual(try XCTUnwrap(tempo.beatPhaseDifference(ofDeck: 0.30, at: 100.1)), 0.10, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(tempo.beatPhaseDifference(ofDeck: 0.10, at: 100.1)), -0.10, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(tempo.beatPhaseDifference(ofDeck: 0.95, at: 100.1)), -0.25, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(tempo.beatPhaseDifference(ofDeck: 0.05, at: 100.4)), 0.25, accuracy: 1e-9)
    }

    func testPhaseDifferenceNeedsARunningMasterWithABeat() {
        XCTAssertNil(reference(bpm: 120, running: false).beatPhaseDifference(ofDeck: 0.2, at: 100.1))
        XCTAssertNil(reference(bpm: 120, lastBeatAt: nil).beatPhaseDifference(ofDeck: 0.2, at: 100.1))
    }
}

final class DJStickCueImportTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []
        super.tearDown()
    }

    private func store() -> CueStore {
        let directory = FileManager.default.temporaryDirectory.appending(path: "DJStickImport-\(UUID().uuidString)", directoryHint: .isDirectory)
        directories.append(directory)
        return CueStore(directory: directory, writerId: "mac")
    }

    private func stickTrack(_ analysis: DJStickAnalysis) -> RekordboxTrack {
        RekordboxTrack(
            trackId: "1",
            attributes: ["Name": "Demo Track 1", "Artist": "Loopmasters", "TotalTime": "172", "Tonality": "Am"],
            tempos: analysis.tempos.map { RekordboxTempo(inizio: $0.startSeconds, bpm: $0.bpm, metro: "4/4", battito: $0.beatInBar) },
            marks: analysis.marks.map {
                RekordboxMark(name: $0.label, type: $0.xmlType, start: $0.startSeconds, end: $0.endSeconds, num: $0.xmlNum, red: $0.red, green: $0.green, blue: $0.blue)
            }
        )
    }

    private var analysis: DJStickAnalysis {
        DJStickAnalysis(
            tempos: [DJStickAnalysis.Tempo(startSeconds: 0.025, bpm: 128, beatInBar: 1)],
            marks: [
                DJStickAnalysis.Mark(kind: .hotCue, slot: 0, startSeconds: 20, endSeconds: nil, label: "Drop", rgb: 0x28E214),
                DJStickAnalysis.Mark(kind: .hotCue, slot: 1, startSeconds: 40, endSeconds: nil, label: "Break", rgb: 0xFFA000),
                DJStickAnalysis.Mark(kind: .memory, slot: nil, startSeconds: 5, endSeconds: nil, label: "Intro", rgb: nil),
                DJStickAnalysis.Mark(kind: .loop, slot: nil, startSeconds: 60, endSeconds: 68, label: "", rgb: nil),
            ]
        )
    }

    func testImportAddsStickCuesAndGridToAMatchedTrack() async throws {
        let store = store()
        let id = "soundcloud:tracks:7"
        let result = await RekordboxImport.importMerging(stickTrack(analysis), trackId: id, title: "Demo Track 1", store: store)
        XCTAssertEqual(result.cues, 4)
        XCTAssertEqual(result.keptYours, 0)
        let cues = await store.cues(forTrack: id)
        XCTAssertEqual(cues.filter { $0.kind == .hotCue }.compactMap(\.hotCueIndex).sorted(), [0, 1])
        XCTAssertTrue(cues.allSatisfy { $0.origin == .imported })
        XCTAssertEqual(cues.first { $0.hotCueIndex == 0 }?.label, "Drop")
        XCTAssertEqual(cues.first { $0.kind == .loop }?.endMillis, 68_000)
        let stored = await store.prep(forTrack: id)
        let prep = try XCTUnwrap(stored)
        XCTAssertEqual(try XCTUnwrap(prep.grid?.value.bpm), 128, accuracy: 0.001)
        XCTAssertEqual(prep.grid?.source, .rekordbox)
        XCTAssertEqual(prep.key?.value.camelot, "8A")
    }

    func testUserCuesAndGridsWinOverTheStick() async throws {
        let store = store()
        let id = "soundcloud:tracks:7"
        await store.upsert(CuePoint(trackId: id, kind: .hotCue, positionMillis: 21_500, hotCueIndex: 0, label: "My drop"))
        var prep = TrackPrep(trackId: id)
        prep.grid = PrepField(PrepGrid(segments: [PrepTempoSegment(startMillis: 90, bpm: 127.5)], locked: true), source: .user, updatedAtMillis: 5, writerId: "mac")
        await store.savePrep(prep)

        let result = await RekordboxImport.importMerging(stickTrack(analysis), trackId: id, title: "Demo Track 1", store: store)
        XCTAssertEqual(result.keptYours, 2)
        XCTAssertEqual(result.cues, 3)

        let cues = await store.cues(forTrack: id)
        let mine = try XCTUnwrap(cues.first { $0.hotCueIndex == 0 })
        XCTAssertEqual(mine.label, "My drop")
        XCTAssertEqual(mine.positionMillis, 21_500)
        XCTAssertEqual(mine.origin, .user)
        XCTAssertEqual(cues.first { $0.hotCueIndex == 1 }?.label, "Break")
        let storedAfter = await store.prep(forTrack: id)
        let kept = try XCTUnwrap(storedAfter)
        XCTAssertEqual(try XCTUnwrap(kept.grid?.value.bpm), 127.5, accuracy: 0.001)
        XCTAssertEqual(kept.grid?.source, .user)
        XCTAssertEqual(kept.grid?.value.locked, true)
    }

    func testImportNeverDeletesAndIsIdempotent() async throws {
        let store = store()
        let id = "soundcloud:tracks:7"
        await store.upsert(CuePoint(trackId: id, kind: .memory, positionMillis: 99_000, label: "Only in Sounding"))
        await store.upsert(CuePoint(trackId: id, kind: .hotCue, positionMillis: 12_000, hotCueIndex: 6, label: "Slot G"))

        let first = await RekordboxImport.importMerging(stickTrack(analysis), trackId: id, title: "Demo Track 1", store: store)
        XCTAssertEqual(first.cues, 4)
        let afterFirst = await store.cues(forTrack: id)
        XCTAssertEqual(afterFirst.count, 6)
        XCTAssertNotNil(afterFirst.first { $0.label == "Only in Sounding" })
        XCTAssertNotNil(afterFirst.first { $0.hotCueIndex == 6 })

        let second = await RekordboxImport.importMerging(stickTrack(analysis), trackId: id, title: "Demo Track 1", store: store)
        XCTAssertEqual(second.cues, 0)
        let afterSecond = await store.cues(forTrack: id)
        XCTAssertEqual(afterSecond.count, 6)

        var thinner = analysis
        thinner.marks.removeAll { $0.slot == 1 }
        let third = await RekordboxImport.importMerging(stickTrack(thinner), trackId: id, title: "Demo Track 1", store: store)
        XCTAssertEqual(third.cues, 0)
        let afterThird = await store.cues(forTrack: id)
        XCTAssertEqual(afterThird.count, 6)
    }

    func testStickMemoryCueNearAUserMemoryCueIsNotDuplicated() async throws {
        let store = store()
        let id = "soundcloud:tracks:7"
        await store.upsert(CuePoint(trackId: id, kind: .memory, positionMillis: 5_002, label: "Mine"))
        _ = await RekordboxImport.importMerging(stickTrack(analysis), trackId: id, title: "Demo Track 1", store: store)
        let memories = await store.cues(forTrack: id).filter { $0.kind == .memory }
        XCTAssertEqual(memories.count, 1)
        XCTAssertEqual(memories.first?.label, "Mine")
    }
}
