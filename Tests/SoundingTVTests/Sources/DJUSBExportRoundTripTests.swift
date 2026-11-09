import AVFoundation
import XCTest

final class DJUSBExportRoundTripTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appending(path: "DJUSBRoundTrip-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func tone(_ name: String, frequency: Double, seconds: Double) throws -> URL {
        let url = scratch.appending(path: name)
        let rate = 44100.0
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
                let envelope = Float(i % 11025) / 11025
                channel[i] = Float(sin(2 * Double.pi * frequency * Double(i) / rate)) * 0.7 * envelope
            }
        }
        try file.write(from: buffer)
        return url
    }

    private func library() throws -> (tracks: [DJExportTrackRecord], playlists: [DJExportPlaylist]) {
        let a = try tone("Warehouse Tool.wav", frequency: 110, seconds: 12)
        let b = try tone("Ünïcode Dub.wav", frequency: 330, seconds: 8)
        let c = try tone("Closer.wav", frequency: 880, seconds: 6)
        let beat = 60 / 128.0
        var first = DJExportTrackRecord(
            exportID: "local:warehouse",
            audioFileURL: a,
            metadata: DJExportMetadata(title: "Warehouse Tool", artist: "Alex", album: "Tools", comment: "Peak", colorRGB: 0xF82020, durationSeconds: 12),
            beatGrid: DJExportBeatGrid(bpm: 128, firstBeatSeconds: 0.25),
            cues: [
                DJExportCue(role: .hotCue(slot: 0), startSeconds: 0.25, label: "Start", colorRGB: 0x28E214),
                DJExportCue(role: .hotCue(slot: 2), startSeconds: 0.25 + 8 * beat, label: "Drop"),
                DJExportCue(role: .hotCue(slot: 7), startSeconds: 0.25 + 12 * beat, endSeconds: 0.25 + 16 * beat, label: "Hot Loop"),
                DJExportCue(role: .memory, startSeconds: 0.25 + 4 * beat, label: "Often replayed"),
                DJExportCue(role: .memory, startSeconds: 0.25 + 16 * beat, endSeconds: 0.25 + 20 * beat, label: "Outro Loop"),
            ],
            key: DJExportKey(pitchClass: 9, isMinor: true)
        )
        first.waveform = try DJAudioAnalysis.waveform(a)
        first.metadata.fileSize = try fileSize(a)
        var second = DJExportTrackRecord(
            exportID: "local:dub",
            audioFileURL: b,
            metadata: DJExportMetadata(title: "Ünïcode Dub", artist: "Bjørk", durationSeconds: 8),
            beatGrid: DJExportBeatGrid(bpm: 122.5, firstBeatSeconds: 0.1, firstDownbeatOffset: 1),
            cues: [DJExportCue(role: .hotCue(slot: 1), startSeconds: 2, label: "B")]
        )
        second.metadata.fileSize = try fileSize(b)
        var third = DJExportTrackRecord(
            exportID: "local:closer",
            audioFileURL: c,
            metadata: DJExportMetadata(title: "Closer", artist: "Alex", durationSeconds: 6)
        )
        third.metadata.fileSize = try fileSize(c)
        let playlists = [
            DJExportPlaylist(name: "Warm-up", trackIDs: ["local:dub", "local:warehouse"]),
            DJExportPlaylist(name: "Peak Time", trackIDs: ["local:warehouse", "local:closer", "local:dub"]),
            .folder("Setlists", [DJExportPlaylist(name: "Recorded at Friday", trackIDs: ["local:closer"])]),
        ]
        return ([first, second, third], playlists)
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func exportToBlankStick() async throws -> (root: URL, report: DJExportReport, tracks: [DJExportTrackRecord]) {
        let (tracks, playlists) = try library()
        let volume = scratch.appending(path: "STICK", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        let report = try await DJMediaExporter().export(
            tracks: tracks,
            playlists: playlists,
            to: volume,
            options: DJExportOptions(destination: .volumeRoot),
            now: Date(timeIntervalSince1970: 1_793_000_000)
        )
        return (report.exportRoot, report, tracks)
    }

    func testTracksAndPlaylistsSurviveTheStickReader() async throws {
        let (root, report, _) = try await exportToBlankStick()
        XCTAssertEqual(report.exportedTrackCount, 3)
        XCTAssertEqual(report.skipped.count, 0)
        XCTAssertTrue(DJMediaValidator.validate(exportRoot: root).isValid)

        let library = try DJStickLoader.load(root: root.path).library
        XCTAssertEqual(Set(library.tracks.map(\.title)), ["Warehouse Tool", "Ünïcode Dub", "Closer"])
        let warehouse = try XCTUnwrap(library.tracks.first { $0.title == "Warehouse Tool" })
        XCTAssertEqual(warehouse.artist, "Alex")
        XCTAssertEqual(warehouse.album, "Tools")
        XCTAssertEqual(warehouse.comment, "Peak")
        XCTAssertEqual(warehouse.durationSeconds, 12)
        XCTAssertEqual(try XCTUnwrap(warehouse.bpm), 128, accuracy: 0.01)
        XCTAssertEqual(warehouse.keyName, "Am")
        XCTAssertTrue(FileManager.default.fileExists(atPath: DJStickLayout.join(root.path, warehouse.filePath)))
        let dub = try XCTUnwrap(library.tracks.first { $0.artist == "Bjørk" })
        XCTAssertEqual(dub.title, "Ünïcode Dub")

        let byName = Dictionary(library.playlists.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(Set(byName.keys), ["Warm-up", "Peak Time", "Recorded at Friday"])
        XCTAssertEqual(library.tracks(in: try XCTUnwrap(byName["Warm-up"])).map(\.title), ["Ünïcode Dub", "Warehouse Tool"])
        XCTAssertEqual(library.tracks(in: try XCTUnwrap(byName["Peak Time"])).map(\.title), ["Warehouse Tool", "Closer", "Ünïcode Dub"])
        XCTAssertEqual(byName["Recorded at Friday"]?.path, ["Setlists"])
        XCTAssertEqual(library.tracks(in: try XCTUnwrap(byName["Recorded at Friday"])).map(\.title), ["Closer"])
    }

    func testGridCuesHotCuesAndLoopsSurviveTheStickReader() async throws {
        let (root, _, _) = try await exportToBlankStick()
        let library = try DJStickLoader.load(root: root.path).library
        let beat = 60 / 128.0
        let warehouse = try XCTUnwrap(library.tracks.first { $0.title == "Warehouse Tool" })
        let analysis = try XCTUnwrap(DJStickLoader.analysis(for: warehouse, root: root.path))

        let firstTempo = try XCTUnwrap(analysis.tempos.first)
        XCTAssertEqual(firstTempo.startSeconds, 0.25, accuracy: 0.002)
        XCTAssertEqual(firstTempo.bpm, 128, accuracy: 0.01)
        XCTAssertEqual(firstTempo.beatInBar, 1)
        XCTAssertEqual(Set(analysis.tempos.map(\.bpm)), [128])

        let hot = analysis.marks.filter { $0.kind == .hotCue }.sorted { ($0.slot ?? 0) < ($1.slot ?? 0) }
        XCTAssertEqual(hot.map(\.slot), [0, 2])
        XCTAssertEqual(hot.map(\.label), ["Start", "Drop"])
        XCTAssertEqual(hot[0].startSeconds, 0.25, accuracy: 0.002)
        XCTAssertEqual(hot[1].startSeconds, 0.25 + 8 * beat, accuracy: 0.002)
        XCTAssertNotNil(hot[0].rgb)

        let loops = analysis.marks.filter { $0.kind == .loop }.sorted { $0.startSeconds < $1.startSeconds }
        XCTAssertEqual(loops.count, 2)
        XCTAssertEqual(loops[0].slot, 7)
        XCTAssertEqual(loops[0].label, "Hot Loop")
        XCTAssertEqual(loops[0].startSeconds, 0.25 + 12 * beat, accuracy: 0.002)
        XCTAssertEqual(try XCTUnwrap(loops[0].endSeconds), 0.25 + 16 * beat, accuracy: 0.002)
        XCTAssertNil(loops[1].slot)
        XCTAssertEqual(loops[1].label, "Outro Loop")
        XCTAssertEqual(try XCTUnwrap(loops[1].endSeconds), 0.25 + 20 * beat, accuracy: 0.002)

        let memory = analysis.marks.filter { $0.kind == .memory }
        XCTAssertEqual(memory.map(\.label), ["Often replayed"])
        XCTAssertEqual(memory[0].startSeconds, 0.25 + 4 * beat, accuracy: 0.002)

        XCTAssertFalse(analysis.overview.isEmpty)
        XCTAssertTrue(analysis.overview.contains { $0 > 0 })

        let dub = try XCTUnwrap(library.tracks.first { $0.title == "Ünïcode Dub" })
        let dubAnalysis = try XCTUnwrap(DJStickLoader.analysis(for: dub, root: root.path))
        XCTAssertEqual(try XCTUnwrap(dubAnalysis.tempos.first).bpm, 122.5, accuracy: 0.01)
        XCTAssertEqual(dubAnalysis.marks.map(\.slot), [1])

        let closer = try XCTUnwrap(library.tracks.first { $0.title == "Closer" })
        let closerAnalysis = DJStickLoader.analysis(for: closer, root: root.path)
        XCTAssertEqual(closerAnalysis?.marks ?? [], [])
    }

    func testWaveformFilesCDJsNeedAreOnTheStick() async throws {
        let (root, _, _) = try await exportToBlankStick()
        let library = try DJStickLoader.load(root: root.path).library
        let warehouse = try XCTUnwrap(library.tracks.first { $0.title == "Warehouse Tool" })
        let datPath = DJStickLayout.join(root.path, warehouse.analyzePath)
        let base = String(datPath.dropLast(4))
        let dat = try ANLZCodec.read(Data(contentsOf: URL(fileURLWithPath: datPath))).file
        let ext = try ANLZCodec.read(Data(contentsOf: URL(fileURLWithPath: base + ".EXT"))).file
        let ex2 = try ANLZCodec.read(Data(contentsOf: URL(fileURLWithPath: base + ".2EX"))).file
        for tag in ["PPTH", "PVBR", "PQTZ", "PCOB", "PWAV", "PWV2"] { XCTAssertNotNil(dat.tag(tag), "DAT lacks \(tag)") }
        for tag in ["PPTH", "PCOB", "PCO2", "PWV3", "PWV4", "PWV5"] { XCTAssertNotNil(ext.tag(tag), "EXT lacks \(tag)") }
        for tag in ["PWV6", "PWV7"] { XCTAssertNotNil(ex2.tag(tag), "2EX lacks \(tag)") }

        let closer = try XCTUnwrap(library.tracks.first { $0.title == "Closer" })
        let closerBase = String(DJStickLayout.join(root.path, closer.analyzePath).dropLast(4))
        XCTAssertFalse(FileManager.default.fileExists(atPath: closerBase + ".2EX"))
    }

    func testANewFolderExportReadsBackTheSameAsARootExport() async throws {
        let (tracks, playlists) = try library()
        let volume = scratch.appending(path: "USED", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        let report = try await DJMediaExporter().export(tracks: tracks, playlists: playlists, to: volume)
        XCTAssertNotEqual(report.exportRoot.standardizedFileURL.path, volume.standardizedFileURL.path)
        let library = try DJStickLoader.load(root: report.exportRoot.path).library
        XCTAssertEqual(library.tracks.count, 3)
        XCTAssertEqual(library.playlists.count, 3)
        XCTAssertThrowsError(try DJStickLoader.load(root: volume.path))
    }

    func testTracksWithoutALocalFileAreReportedNotDropped() async throws {
        var (tracks, playlists) = try library()
        tracks.append(DJExportTrackRecord(
            exportID: "sc:42",
            audioFileURL: URL(string: "https://api.soundcloud.com/tracks/42/stream")!,
            metadata: DJExportMetadata(title: "Stream Only", durationSeconds: 200)
        ))
        playlists[0].trackIDs.append("sc:42")
        let volume = scratch.appending(path: "MIXED", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
        let report = try await DJMediaExporter().export(tracks: tracks, playlists: playlists, to: volume, options: DJExportOptions(destination: .volumeRoot))
        XCTAssertEqual(report.exportedTrackCount, 3)
        XCTAssertEqual(report.skipped.map(\.id), ["sc:42"])
        let library = try DJStickLoader.load(root: report.exportRoot.path).library
        XCTAssertFalse(library.tracks.contains { $0.title == "Stream Only" })
    }
}
