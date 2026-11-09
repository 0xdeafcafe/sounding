import Foundation
import XCTest
#if os(macOS)
@testable import SoundingTV_macOS
#else
@testable import SoundingTV
#endif

final class RekordboxComparisonTests: XCTestCase {

    // MARK: - Owner run

    func testCompareAnalysisWithRekordbox() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["SOUNDING_COMPARE_REKORDBOX"] == "1", "Set SOUNDING_COMPARE_REKORDBOX=1 to compare Sounding's analysis with rekordbox")
        let root = env["REKORDBOX_ANLZ_ROOT"].flatMap { $0.isEmpty ? nil : $0 } ?? RekordboxReferenceLoader.defaultRoot()
        var scan = RekordboxReferenceLoader.scan(root: root)
        guard scan.pairs > 0 else {
            XCTFail("No ANLZ files under \(root). In a sandboxed host, build with SOUNDING_MAC_ENTITLEMENTS=Tests/SoundingTVTests/CompareHost.entitlements")
            return
        }

        var xml: RekordboxLibrary?
        let xmlPath = env["REKORDBOX_XML"].flatMap { $0.isEmpty ? nil : $0 }
        if let xmlPath { xml = try RekordboxReferenceLoader.xmlLibrary(path: xmlPath) }
        let musicRoots = env["COMPARE_MUSIC_DIRS"].map { $0.split(separator: ":").map(String.init) } ?? RekordboxReferenceLoader.defaultMusicRoots()
        RekordboxReferenceLoader.resolveAudio(&scan, xml: xml, musicRoots: musicRoots)
        let xmlMatched = scan.tracks.filter { $0.xml != nil }.count

        let present = scan.tracks.filter { track in track.audioPath.map { FileManager.default.isReadableFile(atPath: $0) } ?? false }
        let limit = env["COMPARE_LIMIT"].flatMap { Int($0) } ?? present.count
        let candidates = Array(present.prefix(max(0, limit)))
        let concurrency = env["COMPARE_CONCURRENCY"].flatMap { Int($0) }.map { max(1, $0) }
            ?? max(2, min(6, ProcessInfo.processInfo.activeProcessorCount / 2))
        let includeBeatTracker = env["COMPARE_BEATTRACKER"] != "0"
        let outDirectory = URL(fileURLWithPath: env["COMPARE_OUT"].flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("rekordbox-comparison").path)
        let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("rekordbox-comparison-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = AnalysisCache(directory: cacheDirectory, maxBytes: 4_000_000_000)

        print("[rekordbox-compare] \(scan.pairs) ANLZ pairs, \(scan.tracks.count) tracks, \(present.count) with audio, analysing \(candidates.count) at \(concurrency) at once")
        let clock = ContinuousClock()
        let started = clock.now
        let total = candidates.count
        let results = await withTaskGroup(of: TrackComparison.self, returning: [TrackComparison].self) { group in
            var queue = candidates.makeIterator()
            var out: [TrackComparison] = []
            for _ in 0 ..< concurrency {
                guard let next = queue.next() else { break }
                group.addTask { await SoundingComparisonRunner.analyse(reference: next, cache: cache, includeBeatTracker: includeBeatTracker) }
            }
            while let done = await group.next() {
                out.append(done)
                let primary = done.engines.first
                print("[rekordbox-compare] \(out.count)/\(total) \(done.fileName) rb=\(ComparisonReport.number(done.referenceBPM, 2)) ours=\(ComparisonReport.number(primary?.observation.bpm, 2)) \(primary?.bpmClass?.rawValue ?? "–") beat=\(ComparisonReport.number(primary?.beat?.medianAbsMs))ms \(ComparisonReport.number(primary?.observation.seconds, 1))s")
                if let next = queue.next() {
                    group.addTask { await SoundingComparisonRunner.analyse(reference: next, cache: cache, includeBeatTracker: includeBeatTracker) }
                }
            }
            return out
        }
        let rows = results.sorted { ($0.reference.audioPath ?? "") < ($1.reference.audioPath ?? "") }

        let info = ComparisonRunInfo(
            root: root,
            pairs: scan.pairs,
            unreadable: scan.unreadable.count,
            references: scan.tracks.count,
            musicRoots: musicRoots,
            audioFilesIndexed: scan.audioFilesIndexed,
            byPath: scan.tracks.filter { $0.match == "path" }.count,
            byFileName: scan.tracks.filter { $0.match == "file name" }.count,
            ambiguous: scan.tracks.filter { $0.match == "ambiguous" }.count,
            missingAudio: scan.tracks.count - present.count,
            analysed: rows.count,
            xmlPath: xmlPath,
            xmlMatched: xmlMatched,
            concurrency: concurrency,
            wallSeconds: SoundingComparisonRunner.seconds(started.duration(to: clock.now)),
            producers: AnalysisProducerRegistry.audioTier.producers.map { $0.id }
        )
        try FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true)
        let markdownURL = outDirectory.appendingPathComponent("rekordbox-comparison.md")
        let csvURL = outDirectory.appendingPathComponent("rekordbox-comparison.csv")
        try ComparisonReport.markdown(rows, info: info).write(to: markdownURL, atomically: true, encoding: .utf8)
        try ComparisonReport.csv(rows).write(to: csvURL, atomically: true, encoding: .utf8)
        print("[rekordbox-compare] report \(markdownURL.path)")
        print("[rekordbox-compare] csv \(csvURL.path)")
        XCTAssertFalse(rows.isEmpty, "No rekordbox track had a readable audio file")
    }

    // MARK: - Metrics

    private func grid(bpm: Double, count: Int, start: Double = 0.5, firstBeatNumber: Int = 1) -> [ANLZBeat] {
        (0 ..< count).map {
            ANLZBeat(
                beatNumber: UInt16(($0 + firstBeatNumber - 1) % 4 + 1),
                tempo: UInt16((bpm * 100).rounded()),
                timeMillis: UInt32(((start + Double($0) * 60 / bpm) * 1000).rounded())
            )
        }
    }

    func testBPMClasses() {
        XCTAssertEqual(ComparisonMetrics.classifyBPM(ours: 128.03, reference: 128), .exact)
        XCTAssertEqual(ComparisonMetrics.classifyBPM(ours: 127.6, reference: 128), .close)
        XCTAssertEqual(ComparisonMetrics.classifyBPM(ours: 64.1, reference: 128), .halfTime)
        XCTAssertEqual(ComparisonMetrics.classifyBPM(ours: 174.5, reference: 87), .doubleTime)
        XCTAssertEqual(ComparisonMetrics.classifyBPM(ours: 96, reference: 128), .other)
        XCTAssertEqual(ComparisonMetrics.classifyBPM(ours: nil, reference: 128), .missing)
    }

    func testKeyClasses() throws {
        let reference = try XCTUnwrap(CamelotKey.parse("8A"))
        XCTAssertEqual(ComparisonMetrics.classifyKey(ours: CamelotKey.parse("Am"), reference: reference), .exact)
        XCTAssertEqual(ComparisonMetrics.classifyKey(ours: CamelotKey.parse("8B"), reference: reference), .relative)
        XCTAssertEqual(ComparisonMetrics.classifyKey(ours: CamelotKey.parse("9A"), reference: reference), .adjacent)
        XCTAssertEqual(ComparisonMetrics.classifyKey(ours: CamelotKey.parse("3B"), reference: reference), .other)
        XCTAssertEqual(ComparisonMetrics.classifyKey(ours: nil, reference: reference), .missing)
    }

    func testBeatAlignmentFindsConstantOffset() throws {
        let reference = (0 ..< 200).map { 0.5 + Double($0) * 0.5 }
        let ours = reference.map { $0 + 0.010 }
        let aligned = try XCTUnwrap(ComparisonMetrics.alignBeats(reference: reference, ours: ours))
        XCTAssertEqual(aligned.medianAbsMs, 10, accuracy: 0.5)
        XCTAssertEqual(aligned.medianSignedMs, 10, accuracy: 0.5)
        XCTAssertEqual(aligned.fMeasure70, 1, accuracy: 1e-9)
        XCTAssertEqual(aligned.driftMs, 0, accuracy: 0.5)
    }

    func testBeatAlignmentFindsDrift() throws {
        let reference = (0 ..< 200).map { 0.5 + Double($0) * 0.5 }
        let ours = (0 ..< 200).map { 0.51 + Double($0) * 0.5005 }
        let aligned = try XCTUnwrap(ComparisonMetrics.alignBeats(reference: reference, ours: ours))
        XCTAssertGreaterThan(aligned.driftMs, 50)
        XCTAssertGreaterThan(aligned.endOffsetMs, aligned.startOffsetMs)
    }

    func testBeatAlignmentMatchesHalfTimeOnTheSparserGrid() throws {
        let reference = (0 ..< 200).map { 0.5 + Double($0) * 0.5 }
        let ours = stride(from: 0, to: 200, by: 2).map { reference[$0] }
        let aligned = try XCTUnwrap(ComparisonMetrics.alignBeats(reference: reference, ours: ours))
        XCTAssertEqual(aligned.medianAbsMs, 0, accuracy: 0.5)
    }

    func testBarPhaseShift() throws {
        let beats = grid(bpm: 120, count: 128)
        let reference = RekordboxReferenceTrack(anlzID: "a", devicePath: "/a.mp3", durationSeconds: nil, beats: beats, phrases: [], phraseEndSeconds: nil, mood: nil, cueSeconds: [])
        var ours = EngineObservation(name: "test")
        ours.beats = reference.beatTimes
        ours.downbeats = stride(from: 1, to: beats.count, by: 4).map { reference.beatTimes[$0] }
        let agreement = try XCTUnwrap(ComparisonMetrics.downbeats(reference: reference, ours: ours))
        XCTAssertEqual(agreement.barPhaseShift, 3)
        XCTAssertEqual(agreement.barPhaseAgreement, 0, accuracy: 1e-9)
        ours.downbeats = reference.downbeatTimes
        let aligned = try XCTUnwrap(ComparisonMetrics.downbeats(reference: reference, ours: ours))
        XCTAssertEqual(aligned.barPhaseShift, 0)
        XCTAssertTrue(aligned.firstAgrees)
    }

    func testBoundaryFMeasureIsOneToOne() throws {
        let score = try XCTUnwrap(ComparisonMetrics.boundaries(reference: [10, 20, 30, 40], estimate: [10.2, 10.3, 25, 39.9], tolerance: 0.5))
        XCTAssertEqual(score.precision, 0.5, accuracy: 1e-9)
        XCTAssertEqual(score.recall, 0.5, accuracy: 1e-9)
        XCTAssertEqual(score.f, 0.5, accuracy: 1e-9)
    }

    func testReferenceReadsMaskedPhrasesIntroAndOutro() throws {
        let beats = grid(bpm: 125, count: 512)
        let kinds: [UInt16] = [1, 2, 5, 3, 5, 6]
        let phrases = kinds.enumerated().map { ANLZPhrase(index: UInt16($0.offset + 1), beat: UInt16($0.offset * 64 + 1), kind: $0.element) }
        let dat = try ANLZCodec.read(ANLZCodec.write(ANLZFile(tags: [.path("/Music/a.mp3"), .beatGrid(beats)]))).file
        let ext = try ANLZCodec.read(ANLZCodec.write(ANLZFile(tags: [.path("/Music/a.mp3"), .songStructure(ANLZSongStructure(mood: 1, endBeat: 512, phrases: phrases))]))).file
        XCTAssertEqual(ext.songStructure?.masked, true)
        let reference = try XCTUnwrap(RekordboxReferenceLoader.reference(id: "x", dat: dat, ext: ext))
        XCTAssertEqual(reference.audioPath, "/Music/a.mp3")
        XCTAssertEqual(reference.phraseLabels, ["Intro", "Up", "Chorus", "Down", "Chorus", "Outro"])
        XCTAssertEqual(try XCTUnwrap(reference.dominantBPM), 125, accuracy: 0.001)
        XCTAssertFalse(reference.hasVariableTempo)
        XCTAssertEqual(try XCTUnwrap(reference.introEndSeconds), beats[64].seconds, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(reference.outroStartSeconds), beats[320].seconds, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(reference.phraseEndSeconds), beats[511].seconds, accuracy: 0.001)
    }

    func testAnonymisedPathResolvesByFileName() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rekordbox-compare-\(UUID().uuidString)/Crate")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let audio = folder.appendingPathComponent("Café Tune.mp3")
        try Data([0]).write(to: audio)
        let dat = try ANLZCodec.read(ANLZCodec.write(ANLZFile(tags: [.path("?/Café Tune.mp3"), .beatGrid(grid(bpm: 124, count: 64))]))).file
        var scan = RekordboxReferenceScan()
        scan.tracks = [try XCTUnwrap(RekordboxReferenceLoader.reference(id: "c", dat: dat, ext: nil))]
        XCTAssertNil(scan.tracks[0].audioPath)
        RekordboxReferenceLoader.resolveAudio(&scan, xml: nil, musicRoots: [folder.deletingLastPathComponent().path])
        XCTAssertEqual(scan.tracks[0].match, "file name")
        XCTAssertEqual(scan.tracks[0].audioPath.map { ($0 as NSString).lastPathComponent }, "Café Tune.mp3")
    }

    func testVariableTempoGrid() {
        let first = grid(bpm: 120, count: 200)
        let start = first.last!.seconds + 60 / 120
        let second = grid(bpm: 126, count: 200, start: start)
        let reference = RekordboxReferenceTrack(anlzID: "v", devicePath: "/v.mp3", durationSeconds: nil, beats: first + second, phrases: [], phraseEndSeconds: nil, mood: nil, cueSeconds: [])
        XCTAssertTrue(reference.hasVariableTempo)
        var steady = EngineObservation(name: "steady")
        steady.beats = (0 ..< 400).map { 0.5 + Double($0) * 60 / 123 }
        let follow = ComparisonMetrics.tempoFollow(reference: reference, ours: steady)
        XCTAssertEqual(follow?.oursVariable, false)
        XCTAssertLessThan(follow?.followFraction ?? 1, 0.2)
        var tracking = EngineObservation(name: "tracking")
        tracking.beats = reference.beatTimes
        XCTAssertGreaterThan(ComparisonMetrics.tempoFollow(reference: reference, ours: tracking)?.followFraction ?? 0, 0.9)
    }
}
