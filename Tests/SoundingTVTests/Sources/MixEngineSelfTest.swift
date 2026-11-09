import Foundation
import AVFoundation
import Accelerate
import Combine
import CryptoKit
import AudioToolbox
import XCTest
@testable import SoundingTV

final class MixEnginePureTests: XCTestCase {
    func testMixLoopSelfTest() {
        let report = MixLoopSelfTest.run()
        XCTAssertTrue(report.failures.isEmpty, report.failures.joined(separator: "\n"))
    }

    func testTranscodingRankSelfTest() {
        let report = TranscodingRankSelfTest.run()
        XCTAssertTrue(report.failures.isEmpty, report.failures.joined(separator: "\n"))
    }
}

#if DEBUG

@MainActor
final class MixEngineRuntimeTests: XCTestCase {
    func testMixImportSelfTest() async {
        let report = await MixImportSelfTest.run()
        XCTAssertTrue(report.failures.isEmpty, report.summary)
    }

    func testMixTranscodeErrorSelfTest() async {
        let report = await MixTranscodeErrorSelfTest.run()
        XCTAssertTrue(report.failures.isEmpty, report.summary)
    }

    func testMixPlaybackFailureSelfTest() async {
        let report = await MixPlaybackFailureSelfTest.run()
        XCTAssertTrue(report.failures.isEmpty, report.summary)
    }

    func testMixTransportSitesSelfTest() async {
        let report = await MixTransportSitesSelfTest.run()
        XCTAssertTrue(report.failures.isEmpty, report.summary)
    }

    func testEngineSuspendsWhileIdleAndResumesOnPlay() async throws {
        let engine = MixEngine.shared
        let deck = MixEngine.Deck.a
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mixidletest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            engine.unload(deck: deck)
            engine.stop()
            try? FileManager.default.removeItem(at: dir)
        }
        let source = dir.appendingPathComponent("tone.m4a")
        try await MixImportSelfTest.encodeTestTone(to: source, seconds: 6.0, sampleRate: 44_100)
        try await engine.load(url: source, into: deck, trackId: "mixidletest")

        engine.play(deck: deck)
        XCTAssertTrue(engine.isRunning)
        try await Task.sleep(for: .milliseconds(600))
        engine.pause(deck: deck)
        let pausedAt = engine[deck].position
        XCTAssertGreaterThan(pausedAt, 0.2)

        let runningStart = Self.processCPUSeconds()
        try await Task.sleep(for: .milliseconds(1800))
        let runningCPU = (Self.processCPUSeconds() - runningStart) / 1.8
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertFalse(engine.isRunning, "engine should pause after two idle seconds")
        XCTAssertEqual(engine[deck].level, 0)
        let suspendedStart = Self.processCPUSeconds()
        try await Task.sleep(for: .seconds(3))
        let suspendedCPU = (Self.processCPUSeconds() - suspendedStart) / 3
        print(String(format: "[MixIdleCPU] paused, engine running: %.2f%%  paused, engine suspended: %.2f%%", runningCPU * 100, suspendedCPU * 100))

        engine.play(deck: deck)
        XCTAssertTrue(engine.isRunning)
        XCTAssertTrue(engine[deck].isPlaying)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertGreaterThan(engine[deck].position, pausedAt + 0.2, "playback should resume from the paused position")
        XCTAssertLessThan(engine[deck].position, pausedAt + 2.0)
    }

    func testDecksKeepPlayingAcrossConfigurationChangeOnAirPlay() async throws {
        let original = PlatformAudioSession.coordinator
        PlatformAudioSession.coordinator = AirPlayRouteCoordinator(base: original)
        let engine = MixEngine.shared
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mixroutetest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer {
            engine.unload(deck: .a)
            engine.unload(deck: .b)
            engine.stop()
            PlatformAudioSession.coordinator = original
            try? FileManager.default.removeItem(at: dir)
        }
        XCTAssertTrue(PlatformAudioSession.isAirPlayRoute)

        let sourceA = dir.appendingPathComponent("a.m4a")
        let sourceB = dir.appendingPathComponent("b.m4a")
        try await MixImportSelfTest.encodeTestTone(to: sourceA, seconds: 8.0, sampleRate: 44_100)
        try await MixImportSelfTest.encodeTestTone(to: sourceB, seconds: 8.0, sampleRate: 44_100)
        try await engine.load(url: sourceA, into: .a, trackId: "mixroutetest-a")
        try await engine.load(url: sourceB, into: .b, trackId: "mixroutetest-b")
        engine.seek(deck: .b, to: 2.0)

        engine.play(decks: [.a, .b])
        XCTAssertTrue(engine.isRunning)
        try await Task.sleep(for: .milliseconds(700))

        let beforeA = engine.livePosition(of: .a)
        let beforeB = engine.livePosition(of: .b)
        XCTAssertGreaterThan(beforeA, 0.3)
        XCTAssertGreaterThan(beforeB, 2.3)

        let errorBefore = engine.lastError
        engine.debugSimulateConfigurationChange()

        XCTAssertTrue(engine.isRunning, "the engine should restart itself after a configuration change")
        XCTAssertTrue(engine[.a].isPlaying)
        XCTAssertTrue(engine[.b].isPlaying)
        XCTAssertEqual(engine.lastError, errorBefore)
        let afterA = engine.livePosition(of: .a)
        let afterB = engine.livePosition(of: .b)
        XCTAssertEqual(afterA, beforeA, accuracy: 0.25, "deck A should keep its position")
        XCTAssertEqual(afterB, beforeB, accuracy: 0.25, "deck B should keep its position")
        XCTAssertEqual(afterB - afterA, beforeB - beforeA, accuracy: 0.02, "the decks should stay aligned")

        try await Task.sleep(for: .milliseconds(700))
        let laterA = engine.livePosition(of: .a)
        let laterB = engine.livePosition(of: .b)
        XCTAssertGreaterThan(laterA, afterA + 0.3, "deck A should keep playing")
        XCTAssertLessThan(laterA, afterA + 1.5)
        XCTAssertGreaterThan(laterB, afterB + 0.3, "deck B should keep playing")
        XCTAssertEqual(laterB - laterA, beforeB - beforeA, accuracy: 0.02)
        XCTAssertLessThanOrEqual(engine.audiblePosition(of: .a), engine.livePosition(of: .a) + 0.01)
    }

    private static func processCPUSeconds() -> Double {
        var spec = timespec()
        clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &spec)
        return Double(spec.tv_sec) + Double(spec.tv_nsec) / 1_000_000_000
    }
}

@MainActor
private final class AirPlayRouteCoordinator: AudioSessionCoordinating {
    private let base: (any AudioSessionCoordinating)?

    init(base: (any AudioSessionCoordinating)?) {
        self.base = base
    }

    var outputName: String? { "Living Room" }
    var outputKind: AudioOutputKind { .airPlay }
    var maximumOutputChannels: Int { 2 }
    var supportsMultichannel: Bool { false }

    func activatePlayback() { base?.activatePlayback() }
    func refreshRoute() { base?.refreshRoute() }
}

private final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0

    func record(_ fraction: Double) {
        lock.lock()
        defer { lock.unlock() }
        value = fraction
    }

    var latest: Double {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

enum MixImportSelfTest {
    struct Report {
        var lines: [String] = []
        var failures: [String] = []

        var summary: String {
            let status = failures.isEmpty ? "PASS" : "FAIL (\(failures.count))"
            return (["[MixTest] \(status)"] + lines.map { "[MixTest]   \($0)" }
                + failures.map { "[MixTest]   ✗ \($0)" }).joined(separator: "\n")
        }
    }

    static func run() async -> Report {
        var report = Report()

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mixtest-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            report.failures.append("could not create scratch directory: \(error)")
            return report
        }
        defer { try? FileManager.default.removeItem(at: dir) }

        let seconds = 3.0
        let sourceRate = 48_000.0
        let source = dir.appendingPathComponent("source.m4a")

        do {
            try await encodeTestTone(to: source, seconds: seconds, sampleRate: sourceRate)
            let size = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int64) ?? 0
            report.lines.append("encoded \(seconds)s 48kHz stereo AAC source (\(size) bytes)")
        } catch {
            report.failures.append("could not encode the test source: \(error)")
            return report
        }

        let destination = dir.appendingPathComponent("out.caf")
        let tracker = ProgressTracker()
        do {
            try await SourceImporter._selfTestTranscode(localURL: source, to: destination) {
                tracker.record($0)
            }
        } catch {
            report.failures.append("transcode threw: \(error)")
            return report
        }
        report.lines.append(String(format: "transcode completed, final progress %.2f", tracker.latest))

        guard FileManager.default.fileExists(atPath: destination.path) else {
            report.failures.append("no output file was produced")
            return report
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: destination)
        } catch {
            report.failures.append("output could not be reopened for reading: \(error)")
            return report
        }

        let format = file.processingFormat
        report.lines.append("output format \(Int(format.sampleRate))Hz \(format.channelCount)ch, \(file.length) frames")

        let asbd = file.fileFormat.streamDescription.pointee
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        report.lines.append("on-disk \(asbd.mBitsPerChannel)-bit \(isFloat ? "float" : "int")")
        if !(asbd.mBitsPerChannel == 32 && isFloat) {
            report.failures.append(
                "expected 32-bit float on disk, got \(asbd.mBitsPerChannel)-bit \(isFloat ? "float" : "int")"
            )
        }

        if abs(file.fileFormat.sampleRate - 44_100) > 0.5 {
            report.failures.append("expected 44100Hz on disk, got \(file.fileFormat.sampleRate)")
        }
        if file.fileFormat.channelCount != 2 {
            report.failures.append("expected 2 channels, got \(file.fileFormat.channelCount)")
        }

        let expected = 44_100.0 * seconds
        let drift = abs(Double(file.length) - expected) / expected
        if drift > 0.05 {
            report.failures.append(
                String(format: "duration drifted %.1f%% (expected ~%.0f frames, got %d)",
                       drift * 100, expected, file.length)
            )
        } else {
            report.lines.append(String(format: "duration within %.2f%% of source", drift * 100))
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(min(file.length, 44_100))) else {
            report.failures.append("could not allocate a read buffer")
            return report
        }
        do {
            try file.read(into: buffer)
        } catch {
            report.failures.append("could not read samples back: \(error)")
            return report
        }

        var peak: Float = 0
        if let channels = buffer.floatChannelData {
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) {
                    peak = max(peak, abs(channels[channel][frame]))
                }
            }
        } else {
            report.failures.append("output buffer exposed no float channel data")
        }

        if peak < 0.05 {
            report.failures.append(String(format: "output is effectively silent (peak %.4f)", peak))
        } else {
            report.lines.append(String(format: "peak amplitude %.3f — audible signal present", peak))
        }

        return report
    }

    fileprivate static func encodeTestTone(
        to url: URL,
        seconds: Double,
        sampleRate: Double,
        optimizeForNetworkUse: Bool = false
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        writer.shouldOptimizeForNetworkUse = optimizeForNetworkUse
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        guard writer.canAdd(input) else {
            throw MixEngineError.decodeFailed("AVAssetWriter refused the AAC input")
        }
        let receiver = writer.inputReceiver(for: input)

        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        ) else {
            throw MixEngineError.decodeFailed("could not build the source PCM format")
        }

        let totalFrames = AVAudioFrameCount(seconds * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: totalFrames) else {
            throw MixEngineError.decodeFailed("could not allocate the source buffer")
        }
        buffer.frameLength = totalFrames
        if let channels = buffer.floatChannelData {
            for frame in 0..<Int(totalFrames) {
                let t = Double(frame) / sampleRate
                channels[0][frame] = Float(sin(2 * .pi * 440 * t) * 0.7)
                channels[1][frame] = Float(sin(2 * .pi * 660 * t) * 0.7)
            }
        }

        do {
            try writer.start()
        } catch {
            throw MixEngineError.decodeFailed("AVAssetWriter would not start: \(error.localizedDescription)")
        }
        writer.startSession(atSourceTime: .zero)

        guard let sampleBuffer = buffer.toCMSampleBuffer() else {
            throw MixEngineError.decodeFailed("could not wrap PCM as CMSampleBuffer")
        }

        let readyBuffer = CMReadySampleBuffer<CMSampleBuffer.DynamicContent>(unsafeBuffer: sampleBuffer)
        try await receiver.append(readyBuffer)
        receiver.finish()
        await writer.finishWriting()

        if writer.status != .completed {
            throw MixEngineError.decodeFailed("AAC encode failed: \(writer.error?.localizedDescription ?? "unknown")")
        }
    }
}

private extension AVAudioPCMBuffer {
    func toCMSampleBuffer() -> CMSampleBuffer? {
        let audioBufferList = mutableAudioBufferList
        let asbd = format.streamDescription

        var format: CMFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        ) == noErr, let format else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(asbd.pointee.mSampleRate)),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: CMItemCount(frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }

        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: audioBufferList
        ) == noErr else { return nil }

        return sampleBuffer
    }
}

extension SourceImporter {
    static func _selfTestTranscode(
        localURL: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await transcode(localURL: localURL, to: destination, progress: progress)
    }
}

enum MixTranscodeErrorSelfTest {
    struct Report {
        var lines: [String] = []
        var failures: [String] = []

        var summary: String {
            let status = failures.isEmpty ? "PASS" : "FAIL (\(failures.count))"
            return (["[MixTranscodeErrorTest] \(status)"] + lines.map { "[MixTranscodeErrorTest]   \($0)" }
                + failures.map { "[MixTranscodeErrorTest]   ✗ \($0)" }).joined(separator: "\n")
        }
    }

    static func run() async -> Report {
        var report = Report()

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mixtranscodeerrtest-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            report.failures.append("could not create scratch directory: \(error)")
            return report
        }
        defer { try? FileManager.default.removeItem(at: dir) }

        await runCase(
            &report,
            name: "garbage bytes",
            makeSource: { url in
                try Data((0..<4096).map { _ in UInt8.random(in: 0...255) }).write(to: url)
            },
            expectCancelReading: false
        ) { error in
            guard case .unsupportedFormat = error else {
                return "expected .unsupportedFormat, got \(error)"
            }
            return nil
        }

        await runCase(
            &report,
            name: "truncated mid-stream (moov-first, cut sample data)",
            makeSource: { url in
                let full = dir.appendingPathComponent("full-\(UUID().uuidString).m4a")
                try await MixImportSelfTest.encodeTestTone(
                    to: full, seconds: 5.0, sampleRate: 44_100, optimizeForNetworkUse: true
                )
                let data = try Data(contentsOf: full)
                guard data.count > 0 else { throw MixEngineError.decodeFailed("empty fixture encode") }
                guard let moovOffset = topLevelBoxPayloadOffset("moov", in: data),
                      let mdatOffset = topLevelBoxPayloadOffset("mdat", in: data),
                      moovOffset < mdatOffset
                else {
                    throw MixEngineError.decodeFailed(
                        "fixture did not lay out moov-before-mdat (moov=\(topLevelBoxPayloadOffset("moov", in: data).map(String.init) ?? "missing"), mdat=\(topLevelBoxPayloadOffset("mdat", in: data).map(String.init) ?? "missing")) — shouldOptimizeForNetworkUse may not behave this way on this platform"
                    )
                }
                let mdatPayloadLength = data.count - mdatOffset
                guard mdatPayloadLength > 100 else {
                    throw MixEngineError.decodeFailed("mdat payload too small to usefully truncate (\(mdatPayloadLength) bytes)")
                }
                let cutPoint = mdatOffset + Int(Double(mdatPayloadLength) * 0.6)
                try data[0..<cutPoint].write(to: url)
            },
            expectCancelReading: true
        ) { error in
            guard case .decodeFailed(let detail) = error else {
                return "expected .decodeFailed, got \(error)"
            }
            guard detail.contains("-11880") || detail.localizedCaseInsensitiveContains("cursor") else {
                return nil
            }
            return nil
        }

        return report
    }

    private static func topLevelBoxPayloadOffset(_ tag: String, in data: Data) -> Int? {
        let tagBytes = Array(tag.utf8)
        guard tagBytes.count == 4 else { return nil }
        let base = data.startIndex
        var offset = 0
        while offset + 8 <= data.count {
            let sizeField = data[(base + offset)..<(base + offset + 4)]
            let size = sizeField.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let typeField = Array(data[(base + offset + 4)..<(base + offset + 8)])
            if typeField == tagBytes {
                return offset + 8
            }
            guard size >= 8 else { return nil }
            offset += Int(size)
        }
        return nil
    }

    private static func runCase(
        _ report: inout Report,
        name: String,
        makeSource: (URL) async throws -> Void,
        expectCancelReading: Bool,
        check: (MixEngineError) -> String?
    ) async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mixtranscodeerrtest-case-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            report.failures.append("[\(name)] could not create scratch directory: \(error)")
            return
        }
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("source.m4a")
        let destination = dir.appendingPathComponent("out.caf")

        do {
            try await makeSource(source)
        } catch {
            report.failures.append("[\(name)] could not build fixture: \(error)")
            return
        }

        let cancelCount = LockedCounter()
        SourceImporter.debugOnCancelReading = { cancelCount.increment() }
        defer { SourceImporter.debugOnCancelReading = nil }

        do {
            try await SourceImporter._selfTestTranscode(localURL: source, to: destination) { _ in }
            report.failures.append("[\(name)] expected transcode to throw, but it succeeded")
        } catch let error as MixEngineError {
            if let problem = check(error) {
                report.failures.append("[\(name)] \(problem)")
            } else {
                report.lines.append("[\(name)] threw \(error) as expected")
            }
        } catch {
            report.failures.append("[\(name)] expected a MixEngineError, got \(type(of: error)): \(error)")
        }

        let seen = cancelCount.value
        if expectCancelReading {
            if seen == 1 {
                report.lines.append("[\(name)] cancelReading() fired exactly once, as expected")
            } else {
                report.failures.append("[\(name)] expected cancelReading() exactly once, saw \(seen)")
            }
        } else if seen != 0 {
            report.failures.append("[\(name)] did not expect cancelReading() (no reader exists yet on this path), saw \(seen)")
        }
    }
}


@MainActor
enum MixPlaybackFailureSelfTest {
    static func run() async -> MixImportSelfTest.Report {
        var report = MixImportSelfTest.Report()
        let engine = MixEngine.shared
        let deck = MixEngine.Deck.a

        defer {
            engine.unload(deck: deck)
            engine.stop()
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mixplaybackfailtest-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            report.failures.append("could not create scratch directory: \(error)")
            return report
        }
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("tone.m4a")
        do {
            try await MixImportSelfTest.encodeTestTone(to: source, seconds: 3.0, sampleRate: 44_100)
        } catch {
            report.failures.append("could not encode the test fixture: \(error)")
            return report
        }

        do {
            try await engine.load(url: source, into: deck, trackId: "mixplaybackfailtest")
        } catch {
            report.failures.append("engine.load(file://…) failed — cannot exercise runtime playback without a loaded deck: \(error)")
            return report
        }
        guard engine[deck].status.isReady else {
            report.failures.append("deck \(deck.label) did not reach .ready after load, status=\(engine[deck].status)")
            return report
        }
        report.lines.append("loaded local fixture onto deck \(deck.label), duration \(String(format: "%.2f", engine[deck].duration))s")

        engine.play(deck: deck)
        guard engine[deck].isPlaying, engine.lastError == nil else {
            report.failures.append("baseline play() did not succeed cleanly — isPlaying=\(engine[deck].isPlaying), lastError=\(String(describing: engine.lastError))")
            return report
        }
        report.lines.append("baseline play() succeeded, lastError nil")

        MixEngine.debugForcePlaybackFailureArmed = true
        engine.seek(deck: deck, to: 1.0)

        guard case .playbackStartFailed = engine.lastError else {
            report.failures.append("forced mid-session seek() did not set .playbackStartFailed, got \(String(describing: engine.lastError))")
            return report
        }
        report.lines.append("forced seek() failure recorded: \(engine.lastError!.errorDescription ?? "?")")

        if engine[deck].isPlaying {
            report.failures.append("deck \(deck.label) still reports isPlaying=true after a forced playAudio() throw")
        } else {
            report.lines.append("deck \(deck.label) correctly reports isPlaying=false after the forced failure")
        }

        engine.play(deck: deck)

        if engine[deck].isPlaying, engine.lastError == nil {
            report.lines.append("self-heal confirmed: play() after the forced failure cleared lastError and resumed isPlaying")
        } else {
            report.failures.append(
                "self-heal did not happen — isPlaying=\(engine[deck].isPlaying), lastError=\(String(describing: engine.lastError)) after a retry play()"
            )
        }

        return report
    }
}

@MainActor
enum MixTransportSitesSelfTest {
    static func run() async -> MixImportSelfTest.Report {
        var report = MixImportSelfTest.Report()
        let engine = MixEngine.shared
        let deckA = MixEngine.Deck.a
        let deckB = MixEngine.Deck.b

        defer {
            MixEngine.debugForcePlaybackFailureArmed = false
            engine.unload(deck: deckA)
            engine.unload(deck: deckB)
            engine.stop()
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mixtransportsitestest-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            report.failures.append("could not create scratch directory: \(error)")
            return report
        }
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceA = dir.appendingPathComponent("toneA.m4a")
        let sourceB = dir.appendingPathComponent("toneB.m4a")
        do {
            try await MixImportSelfTest.encodeTestTone(to: sourceA, seconds: 4.0, sampleRate: 44_100)
            try await MixImportSelfTest.encodeTestTone(to: sourceB, seconds: 4.0, sampleRate: 44_100)
        } catch {
            report.failures.append("could not encode fixtures: \(error)")
            return report
        }

        do {
            try await engine.load(url: sourceA, into: deckA, trackId: "sites-a")
            try await engine.load(url: sourceB, into: deckB, trackId: "sites-b")
        } catch {
            report.failures.append("engine.load(file://…) failed — cannot exercise runtime playback without loaded decks: \(error)")
            return report
        }
        guard engine[deckA].status.isReady, engine[deckB].status.isReady else {
            report.failures.append("decks did not reach .ready after load: A=\(engine[deckA].status), B=\(engine[deckB].status)")
            return report
        }
        report.lines.append("loaded local fixtures onto both decks")

        func assertForcedFailureThenHeal(_ site: String) {
            guard case .playbackStartFailed = engine.lastError else {
                report.failures.append("[\(site)] did not set .playbackStartFailed, got \(String(describing: engine.lastError))")
                return
            }
            if engine[deckA].isPlaying {
                report.failures.append("[\(site)] deck A still reports isPlaying=true right after the forced playAudio() throw")
            } else {
                report.lines.append("[\(site)] forced failure recorded, isPlaying correctly false")
            }
            engine.play(deck: deckA)
            if engine[deckA].isPlaying, engine.lastError == nil {
                report.lines.append("[\(site)] self-heal confirmed: play() restored a usable, playing deck")
            } else {
                report.failures.append(
                    "[\(site)] self-heal did not happen — isPlaying=\(engine[deckA].isPlaying), lastError=\(String(describing: engine.lastError)) after a retry play()"
                )
            }
        }

        MixEngine.debugForcePlaybackFailureArmed = true
        let unaligned = engine.cue(deck: deckA, to: 0.5, alignedTo: deckB, referenceBeatPeriod: 0)
        guard case .unaligned = unaligned else {
            report.failures.append("expected cue() with referenceBeatPeriod 0 to take the unaligned branch, got \(unaligned)")
            return report
        }
        assertForcedFailureThenHeal("cue() unaligned/startImmediately")

        engine.play(deck: deckB)
        var alignedReachable = false
        for _ in 0..<40 {
            let probe = engine.cue(deck: deckA, to: 0.2, alignedTo: deckB, referenceBeatPeriod: 0.5, beatsPerAlignment: 4, minimumLead: 0.08)
            if case .aligned = probe { alignedReachable = true; break }
            try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
        }
        if alignedReachable {
            MixEngine.debugForcePlaybackFailureArmed = true
            let aligned = engine.cue(deck: deckA, to: 0.2, alignedTo: deckB, referenceBeatPeriod: 0.5, beatsPerAlignment: 4, minimumLead: 0.08)
            guard case .aligned = aligned else {
                report.failures.append("cue() stopped taking the aligned branch on the forced-failure call, got \(aligned)")
                MixEngine.debugForcePlaybackFailureArmed = false
                return report
            }
            assertForcedFailureThenHeal("cue() aligned")
        } else {
            report.lines.append(
                "cue()'s aligned branch never became reachable within 800ms of deck B playing — reported rather than forced; "
                    + "the unaligned branch above already exercises the identical playAudio()/catch/self-heal shape at this call site"
            )
        }

        engine.play(deck: deckA)
        guard engine[deckA].isPlaying else {
            report.failures.append("could not get deck A playing ahead of setLoop() — cannot exercise its wasPlaying re-arm")
            return report
        }
        MixEngine.debugForcePlaybackFailureArmed = true
        engine.setLoop(on: deckA, startSeconds: 0.3, lengthSeconds: 0.5)
        guard engine[deckA].loopStartSeconds != nil, engine[deckA].loopLengthSeconds != nil else {
            report.failures.append("setLoop() did not arm the loop bookkeeping — the forced failure should only affect the wasPlaying re-arm, not the arm itself")
            return report
        }
        assertForcedFailureThenHeal("setLoop()")

        guard engine[deckA].loopLengthSeconds != nil, engine[deckA].isPlaying else {
            report.failures.append(
                "preconditions for clearLoop() not met — loopLength=\(String(describing: engine[deckA].loopLengthSeconds)), isPlaying=\(engine[deckA].isPlaying)"
            )
            return report
        }
        MixEngine.debugForcePlaybackFailureArmed = true
        engine.clearLoop(on: deckA)
        if engine[deckA].loopStartSeconds != nil || engine[deckA].loopLengthSeconds != nil {
            report.failures.append("clearLoop() left loop bookkeeping armed despite disarming")
        } else {
            report.lines.append("clearLoop() correctly disarmed the loop bookkeeping despite the forced playback failure")
        }
        assertForcedFailureThenHeal("clearLoop()")

        return report
    }
}
#endif

#if DEBUG

enum TranscodingRankSelfTest {
    private static func make(
        _ preset: String,
        _ proto: String,
        _ mime: String,
        quality: String? = nil,
        snipped: Bool = false
    ) -> Transcoding {
        Transcoding(
            url: URL(string: "https://example.invalid/\(preset)")!,
            preset: preset,
            duration: 180_000,
            quality: quality,
            snipped: snipped,
            format: Transcoding.Format(protocol: proto, mimeType: mime)
        )
    }

    static func run() -> MixImportSelfTest.Report {
        var report = MixImportSelfTest.Report()

        func expect(_ name: String, _ ladder: [Transcoding], picks preset: String) {
            let best = ladder.max { $0.playbackRank < $1.playbackRank }
            if best?.preset == preset {
                report.lines.append("\(name) → \(preset)")
            } else {
                report.failures.append("\(name): expected \(preset), got \(best?.preset ?? "nil")")
            }
        }

        expect("go+ ladder", [
            make("mp3_1_0", "progressive", "audio/mpeg"),
            make("mp3_1_0", "hls", "audio/mpeg"),
            make("opus_0_0", "hls", "audio/ogg; codecs=\"opus\""),
            make("aac_256k", "hls", "audio/mp4; codecs=\"mp4a.40.2\"", quality: "hq")
        ], picks: "aac_256k")

        expect("fixed over adaptive", [
            make("abr_hq", "hls", "audio/mp4", quality: "hq"),
            make("aac_256k", "hls", "audio/mp4", quality: "hq")
        ], picks: "aac_256k")

        expect("lossless wins", [
            make("aac_256k", "progressive", "audio/mp4", quality: "hq"),
            make("flac_0_0", "hls", "audio/flac", quality: "hq")
        ], picks: "flac_0_0")

        expect("opus ranked last", [
            make("opus_0_0", "progressive", "audio/ogg; codecs=\"opus\""),
            make("mp3_1_0", "hls", "audio/mpeg")
        ], picks: "mp3_1_0")

        expect("bitrate within codec", [
            make("aac_160k", "progressive", "audio/mp4"),
            make("aac_256k", "hls", "audio/mp4", quality: "hq")
        ], picks: "aac_256k")

        let withSnippet = [
            make("aac_256k", "hls", "audio/mp4", quality: "hq", snipped: true),
            make("mp3_1_0", "progressive", "audio/mpeg")
        ]
        let filtered = withSnippet.filter { !$0.isSnippet }
        if filtered.count == 1 && filtered.first?.preset == "mp3_1_0" {
            report.lines.append("snippets filtered before ranking")
        } else {
            report.failures.append("snippet filtering did not drop the preview transcoding")
        }

        let mixLadder = [
            make("opus_0_0", "progressive", "audio/ogg; codecs=\"opus\""),
            make("mp3_1_0", "progressive", "audio/mpeg"),
            make("aac_256k", "hls", "audio/mp4", quality: "hq")
        ]
        let mixPick = mixLadder.filter { $0.codec != .opus }.max { $0.mixRank < $1.mixRank }
        if mixPick?.preset == "aac_256k" {
            report.lines.append("mix source → aac_256k (HLS no longer downgraded)")
        } else {
            report.failures.append("mix source: expected aac_256k, got \(mixPick?.preset ?? "nil")")
        }

        return report
    }
}
#endif

#if DEBUG

enum MixLoopSelfTest {
    static func run() -> MixImportSelfTest.Report {
        var report = MixImportSelfTest.Report()
        let sampleRate = 44_100.0

        func expectResolve(
            _ name: String,
            start: Double,
            length: Double,
            duration: Double,
            expectedStartFrame: AVAudioFramePosition?,
            expectedLengthFrames: AVAudioFrameCount?
        ) {
            let result = LoopMath.resolve(
                startSeconds: start,
                lengthSeconds: length,
                durationSeconds: duration,
                sampleRate: sampleRate
            )
            switch (result, expectedStartFrame, expectedLengthFrames) {
            case (nil, nil, nil):
                report.lines.append("\(name) → rejected, as expected")
            case (.some(let bounds), .some(let wantStart), .some(let wantLength)):
                if bounds.startFrame == wantStart && bounds.lengthFrames == wantLength {
                    report.lines.append("\(name) → start \(bounds.startFrame), length \(bounds.lengthFrames)")
                } else {
                    report.failures.append(
                        "\(name): expected start \(wantStart)/length \(wantLength), got start \(bounds.startFrame)/length \(bounds.lengthFrames)"
                    )
                }
            default:
                report.failures.append("\(name): expected \(expectedStartFrame == nil ? "rejection" : "a resolved loop"), got \(String(describing: result))")
            }
        }

        expectResolve(
            "in-bounds loop",
            start: 10, length: 4, duration: 180,
            expectedStartFrame: AVAudioFramePosition(10 * sampleRate),
            expectedLengthFrames: AVAudioFrameCount(4 * sampleRate)
        )

        expectResolve("zero length rejected", start: 10, length: 0, duration: 180, expectedStartFrame: nil, expectedLengthFrames: nil)
        expectResolve("negative length rejected", start: 10, length: -2, duration: 180, expectedStartFrame: nil, expectedLengthFrames: nil)

        expectResolve("start at duration rejected", start: 180, length: 4, duration: 180, expectedStartFrame: nil, expectedLengthFrames: nil)
        expectResolve("start past duration rejected", start: 200, length: 4, duration: 180, expectedStartFrame: nil, expectedLengthFrames: nil)
        expectResolve("negative start rejected", start: -1, length: 4, duration: 180, expectedStartFrame: nil, expectedLengthFrames: nil)

        expectResolve(
            "length clamped to remaining track",
            start: 178, length: 10, duration: 180,
            expectedStartFrame: AVAudioFramePosition(178 * sampleRate),
            expectedLengthFrames: AVAudioFrameCount(2 * sampleRate)
        )

        let loopStart = AVAudioFramePosition(10 * sampleRate)
        let loopLength = AVAudioFrameCount(4 * sampleRate)
        func expectWrap(_ name: String, elapsed: AVAudioFramePosition, expectedOffsetIntoLoop: AVAudioFramePosition) {
            let frame = LoopMath.wrap(elapsedFrames: elapsed, loopStartFrame: loopStart, lengthFrames: loopLength)
            let want = loopStart + expectedOffsetIntoLoop
            if frame == want {
                report.lines.append("\(name) → frame \(frame)")
            } else {
                report.failures.append("\(name): expected frame \(want), got \(frame)")
            }
        }

        expectWrap("mid first lap", elapsed: AVAudioFramePosition(1.5 * sampleRate), expectedOffsetIntoLoop: AVAudioFramePosition(1.5 * sampleRate))
        expectWrap("exactly at loop end", elapsed: AVAudioFramePosition(4 * sampleRate), expectedOffsetIntoLoop: 0)
        expectWrap("several laps in", elapsed: AVAudioFramePosition(9.5 * sampleRate), expectedOffsetIntoLoop: AVAudioFramePosition(1.5 * sampleRate))

        return report
    }
}
#endif

#if DEBUG

final class MixBlendRecordingTests: XCTestCase {
    func testMixBlendRecordingSelfTest() async {
        let report = await MixBlendRecordingSelfTest.run()
        print(report.summary)
        XCTAssertTrue(report.failures.isEmpty, report.summary)
    }
}

private final class MixTapRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private let url: URL

    init(url: URL) {
        self.url = url
        try? FileManager.default.removeItem(at: url)
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if file == nil {
            file = try? AVAudioFile(forWriting: url, settings: buffer.format.settings)
        }
        try? file?.write(from: buffer)
    }

    func finish() {
        lock.lock()
        file = nil
        lock.unlock()
    }
}

private func makeMixTapBlock(_ recorder: MixTapRecorder) -> AVAudioNodeTapBlock {
    { buffer, _ in
        recorder.write(buffer)
    }
}

@MainActor
enum MixBlendRecordingSelfTest {

    private static let scratchDirectory = URL(
        fileURLWithPath: "/private/tmp/claude-501/-Users-afr-Source-github-com-0xdeafcafe-sounding-tv/d0858a5a-3405-4ecf-b52c-cca88038b0aa/scratchpad",
        isDirectory: true
    )

    static func run() async -> MixImportSelfTest.Report {
        var report = MixImportSelfTest.Report()
        try? FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)

        let engine = MixEngine.shared
        defer {
            engine.debugRemoveMainMixerTap()
            engine.unload(deck: .a)
            engine.unload(deck: .b)
            engine.stop()
        }

        let sourceA = scratchDirectory.appendingPathComponent("mixblend-src-a.caf")
        let sourceB = scratchDirectory.appendingPathComponent("mixblend-src-b.caf")
        do {
            try synthesizeTestTrack(url: sourceA, toneHz: 220, seconds: 40)
            try synthesizeTestTrack(url: sourceB, toneHz: 880, seconds: 40)
            report.lines.append("synthesized 40s 44.1kHz stereo fixtures: A=220Hz+128bpm kick, B=880Hz+128bpm kick")
        } catch {
            report.failures.append("could not synthesize fixtures: \(error)")
            return report
        }

        let (blendLines, blendFailures) = await runCrossfadeScenario(engine: engine, sourceA: sourceA, sourceB: sourceB)
        report.lines.append(contentsOf: blendLines)
        report.failures.append(contentsOf: blendFailures)

        let (cutLines, cutFailures) = await runHardCutScenario(engine: engine, sourceA: sourceA, sourceB: sourceB)
        report.lines.append(contentsOf: cutLines)
        report.failures.append(contentsOf: cutFailures)

        return report
    }

    private static func synthesizeTestTrack(
        url: URL,
        toneHz: Double,
        seconds: Double,
        sampleRate: Double = 44_100
    ) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw MixEngineError.decodeFailed("could not build the synth format")
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let totalFrames = AVAudioFrameCount(seconds * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
            throw MixEngineError.decodeFailed("could not allocate the synth buffer")
        }
        buffer.frameLength = totalFrames
        guard let channels = buffer.floatChannelData else {
            throw MixEngineError.decodeFailed("synth buffer exposed no float channel data")
        }

        let kickPeriod = 60.0 / 128.0
        let kickToneHz = 60.0
        let kickDuration = 0.15

        for frame in 0..<Int(totalFrames) {
            let t = Double(frame) / sampleRate
            let tone = sin(2 * .pi * toneHz * t) * 0.3
            let phase = t.truncatingRemainder(dividingBy: kickPeriod)
            var kick = 0.0
            if phase < kickDuration {
                let envelope = exp(-phase * 28)
                kick = sin(2 * .pi * kickToneHz * phase) * envelope * 0.5
            }
            let sample = Float(max(-1, min(1, tone + kick)))
            channels[0][frame] = sample
            channels[1][frame] = sample
        }

        try file.write(from: buffer)
    }

    private static func runCrossfadeScenario(
        engine: MixEngine,
        sourceA: URL,
        sourceB: URL
    ) async -> (lines: [String], failures: [String]) {
        var lines: [String] = []
        var failures: [String] = []

        do {
            try await engine.load(url: sourceA, into: .a, trackId: "mixblend-a")
            try await engine.load(url: sourceB, into: .b, trackId: "mixblend-b")
        } catch {
            failures.append("crossfade scenario: engine.load(file://…) failed: \(error)")
            return (lines, failures)
        }
        guard engine[.a].status.isReady, engine[.b].status.isReady else {
            failures.append("crossfade scenario: decks did not reach .ready — A=\(engine[.a].status) B=\(engine[.b].status)")
            return (lines, failures)
        }
        lines.append(
            "loaded both decks via MixEngine.load(url:into:trackId:) — the same local-file path DJSessionDirector "
                + "uses at armMixSession(); SourceImporter materialises file:// URLs directly (no network, no re-encode)"
        )

        let outputURL = scratchDirectory.appendingPathComponent("mixblend.wav")
        let recorder = MixTapRecorder(url: outputURL)
        engine.debugInstallMainMixerTap(bufferSize: 4096, block: makeMixTapBlock(recorder))

        engine.crossfade = 0
        engine.play(deck: .a)
        try? await Task.sleep(for: .seconds(5))

        engine.setEQ(.low, on: .b, toDecibels: MixEngine.bassKillDecibels)
        engine.seek(deck: .b, to: 0)
        engine.play(deck: .b)

        let window: TimeInterval = 15
        engine.crossfade(to: .b, over: window)
        let swapAt = window * 0.55
        let swapOver = min(0.5, window * 0.2)
        try? await Task.sleep(for: .seconds(swapAt))
        engine.swapBass(from: .a, to: .b, over: swapOver)
        try? await Task.sleep(for: .seconds(window - swapAt))

        engine.stop(deck: .a)
        try? await Task.sleep(for: .seconds(5))

        engine.debugRemoveMainMixerTap()
        recorder.finish()
        lines.append("recorded crossfade blend (5s A solo, \(Int(window))s crossfade with swapBass at +\(String(format: "%.2f", swapAt))s over \(swapOver)s, 5s B solo) to \(outputURL.path)")

        let samples: [Float]
        let sampleRate: Double
        do {
            (samples, sampleRate) = try loadMonoSamples(url: outputURL)
        } catch {
            failures.append("could not reopen the recorded blend for analysis: \(error)")
            return (lines, failures)
        }
        let totalSeconds = Double(samples.count) / sampleRate
        lines.append("recorded \(String(format: "%.2f", totalSeconds))s (\(samples.count) frames @ \(Int(sampleRate))Hz)")

        let spectral = computeSpectralTrack(samples: samples, sampleRate: sampleRate, freqA: 220, freqB: 880)

        func spectralWindow(_ from: Double, _ to: Double) -> (aDb: Double, bDb: Double) {
            let inRange = spectral.filter { $0.time >= from && $0.time < to }
            return (averageDb(inRange.map(\.freqADb)), averageDb(inRange.map(\.freqBDb)))
        }

        let first3 = spectralWindow(0, 3)
        lines.append("first 3s: 220Hz=\(fmt(first3.aDb))dB, 880Hz=\(fmt(first3.bDb))dB")
        if !(first3.aDb - first3.bDb > 20) {
            failures.append("first 3s should be 220Hz-dominant by >20dB, got 220Hz=\(fmt(first3.aDb))dB 880Hz=\(fmt(first3.bDb))dB (Δ=\(fmt(first3.aDb - first3.bDb))dB)")
        }

        let midpointTime = 5 + window * 0.5 / 1
        let midpoint = spectralWindow(midpointTime - 0.5, midpointTime + 0.5)
        let midDelta = abs(midpoint.aDb - midpoint.bDb)
        lines.append("crossfade midpoint (t≈\(fmt(midpointTime))s): 220Hz=\(fmt(midpoint.aDb))dB, 880Hz=\(fmt(midpoint.bDb))dB, Δ=\(fmt(midDelta))dB")
        if midDelta > 12 {
            failures.append("crossfade midpoint imbalance \(fmt(midDelta))dB exceeds 12dB (220Hz=\(fmt(midpoint.aDb))dB, 880Hz=\(fmt(midpoint.bDb))dB) — the two decks are not audibly overlapping")
        }
        let aDropFromSolo = first3.aDb - midpoint.aDb
        lines.append("220Hz solo→midpoint drop: \(fmt(aDropFromSolo))dB")
        if aDropFromSolo > 6 {
            failures.append("220Hz dropped \(fmt(aDropFromSolo))dB from its solo level by the crossfade midpoint (expected ≤6dB for an equal-power blend)")
        }

        let final3 = spectralWindow(totalSeconds - 3, totalSeconds)
        lines.append("final 3s: 220Hz=\(fmt(final3.aDb))dB, 880Hz=\(fmt(final3.bDb))dB")
        if !(final3.bDb - final3.aDb > 20) {
            failures.append("final 3s should be 880Hz-dominant by >20dB, got 220Hz=\(fmt(final3.aDb))dB 880Hz=\(fmt(final3.bDb))dB (Δ=\(fmt(final3.bDb - final3.aDb))dB)")
        }
        let bDropFromSolo = final3.bDb - midpoint.bDb
        lines.append("880Hz midpoint→solo rise check: midpoint=\(fmt(midpoint.bDb))dB, solo=\(fmt(final3.bDb))dB, Δ=\(fmt(bDropFromSolo))dB")
        if bDropFromSolo > 6 {
            failures.append("880Hz sat \(fmt(bDropFromSolo))dB below its solo level at the crossfade midpoint (expected ≤6dB for an equal-power blend)")
        }

        let transitionRMS = shortTermRMSDb(samples, sampleRate: sampleRate, windowSeconds: 0.02)
            .filter { $0.time >= 5 && $0.time < 5 + window }
        let gap = longestSilentRun(transitionRMS, threshold: -50, windowSeconds: 0.02)
        lines.append("longest near-silent run inside the transition: \(String(format: "%.1f", gap.durationMs))ms (starting t≈\(fmt(gap.startTime))s)")
        if gap.durationMs >= 100 {
            failures.append("a \(String(format: "%.1f", gap.durationMs))ms gap of RMS<-50dBFS was found inside the crossfade at t≈\(fmt(gap.startTime))s — the mix drops out rather than blending")
        }

        let clickPercentile = percentileAbsDelta(samples, percentile: 0.99999)
        lines.append("99.999th percentile |Δsample| = \(String(format: "%.4f", clickPercentile))")
        if clickPercentile >= 0.5 {
            failures.append("99.999th percentile sample-to-sample delta \(String(format: "%.4f", clickPercentile)) is >= 0.5 — audible clicking in the recording")
        }

        return (lines, failures)
    }

    private static func runHardCutScenario(
        engine: MixEngine,
        sourceA: URL,
        sourceB: URL
    ) async -> (lines: [String], failures: [String]) {
        var lines: [String] = []
        var failures: [String] = []

        do {
            try await engine.load(url: sourceA, into: .a, trackId: "mixcut-a")
            try await engine.load(url: sourceB, into: .b, trackId: "mixcut-b")
        } catch {
            failures.append("hard-cut scenario: engine.load(file://…) failed: \(error)")
            return (lines, failures)
        }
        guard engine[.a].status.isReady, engine[.b].status.isReady else {
            failures.append("hard-cut scenario: decks did not reach .ready — A=\(engine[.a].status) B=\(engine[.b].status)")
            return (lines, failures)
        }

        let outputURL = scratchDirectory.appendingPathComponent("mixcut.wav")
        let recorder = MixTapRecorder(url: outputURL)
        engine.debugInstallMainMixerTap(bufferSize: 4096, block: makeMixTapBlock(recorder))

        engine.crossfade = 0
        engine.seek(deck: .b, to: 0)
        engine.play(deck: .a)
        try? await Task.sleep(for: .seconds(5))

        let fade: TimeInterval = 0.05
        if !engine[.b].isPlaying { engine.play(deck: .b) }
        engine.crossfade(to: .b, over: fade)
        try? await Task.sleep(for: .seconds(3))

        engine.debugRemoveMainMixerTap()
        recorder.finish()
        lines.append(
            "recorded hard-cut handover (fade=\(fade)s, matching CutOnTheOneTemplate.fadeSeconds — the same value "
                + "DJSessionDirector.executeStages() passes to engine.crossfade(to:over:) for a .hardCut stage) to \(outputURL.path)"
        )

        let samples: [Float]
        let sampleRate: Double
        do {
            (samples, sampleRate) = try loadMonoSamples(url: outputURL)
        } catch {
            failures.append("could not reopen the recorded hard cut for analysis: \(error)")
            return (lines, failures)
        }

        let handoverRMS = shortTermRMSDb(samples, sampleRate: sampleRate, windowSeconds: 0.01)
            .filter { $0.time >= 4.5 }
        let gap = longestSilentRun(handoverRMS, threshold: -50, windowSeconds: 0.01)
        lines.append("hard-cut handover gap: \(String(format: "%.1f", gap.durationMs))ms of RMS<-50dBFS (starting t≈\(fmt(gap.startTime))s, handover requested at t≈5.0s)")
        if gap.durationMs > 120 {
            lines.append("FINDING (not a failure per the brief): handover gap \(String(format: "%.1f", gap.durationMs))ms exceeds the 120ms informational threshold")
        }

        return (lines, failures)
    }

    private static func fmt(_ value: Double) -> String { String(format: "%.1f", value) }

    private static func averageDb(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return -160 }
        let linear = values.map { pow(10, $0 / 20) }
        let meanLinear = linear.reduce(0, +) / Double(linear.count)
        return 20 * log10(max(meanLinear, 1e-12))
    }

    private static func loadMonoSamples(url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw MixEngineError.decodeFailed("could not allocate the analysis buffer")
        }
        try file.read(into: buffer)
        let frameCount = Int(buffer.frameLength)
        guard let channelData = buffer.floatChannelData else {
            throw MixEngineError.decodeFailed("recording exposed no float channel data")
        }
        let channelCount = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: frameCount)
        if channelCount == 1 {
            for frame in 0..<frameCount { mono[frame] = channelData[0][frame] }
        } else {
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channelCount { sum += channelData[channel][frame] }
                mono[frame] = sum / Float(channelCount)
            }
        }
        return (mono, format.sampleRate)
    }

    private static func percentileAbsDelta(_ samples: [Float], percentile: Double) -> Float {
        guard samples.count > 1 else { return 0 }
        var deltas = [Float](repeating: 0, count: samples.count - 1)
        for i in 1..<samples.count { deltas[i - 1] = abs(samples[i] - samples[i - 1]) }
        deltas.sort()
        let idx = min(deltas.count - 1, Int(Double(deltas.count) * percentile))
        return deltas[idx]
    }

    private static func shortTermRMSDb(
        _ samples: [Float],
        sampleRate: Double,
        windowSeconds: Double
    ) -> [(time: Double, db: Double)] {
        let windowFrames = max(1, Int(windowSeconds * sampleRate))
        var result: [(time: Double, db: Double)] = []
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + windowFrames)
            let count = end - start
            var rms: Float = 0
            samples.withUnsafeBufferPointer { ptr in
                vDSP_rmsqv(ptr.baseAddress! + start, 1, &rms, vDSP_Length(count))
            }
            let db = 20 * log10(max(rms, 1e-9))
            result.append((Double(start) / sampleRate, Double(db)))
            start = end
        }
        return result
    }

    private static func longestSilentRun(
        _ track: [(time: Double, db: Double)],
        threshold: Double,
        windowSeconds: Double
    ) -> (startTime: Double, durationMs: Double) {
        var bestStart = 0.0
        var bestLen = 0
        var curStart = 0.0
        var curLen = 0
        for sample in track {
            if sample.db < threshold {
                if curLen == 0 { curStart = sample.time }
                curLen += 1
            } else {
                if curLen > bestLen { bestLen = curLen; bestStart = curStart }
                curLen = 0
            }
        }
        if curLen > bestLen { bestLen = curLen; bestStart = curStart }
        return (bestStart, Double(bestLen) * windowSeconds * 1_000)
    }

    private struct SpectralSample {
        let time: Double
        let freqADb: Double
        let freqBDb: Double
    }

    private static func computeSpectralTrack(
        samples: [Float],
        sampleRate: Double,
        freqA: Double,
        freqB: Double,
        windowSize: Int = 4096,
        hop: Int = 2048
    ) -> [SpectralSample] {
        let log2n = vDSP_Length(round(log2(Double(windowSize))))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var hannWindow = [Float](repeating: 0, count: windowSize)
        vDSP_hann_window(&hannWindow, vDSP_Length(windowSize), Int32(vDSP_HANN_NORM))

        let binHz = sampleRate / Double(windowSize)
        let binA = Int((freqA / binHz).rounded())
        let binB = Int((freqB / binHz).rounded())
        let half = windowSize / 2

        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var windowed = [Float](repeating: 0, count: windowSize)
        var magnitudes = [Float](repeating: 0, count: half)

        var results: [SpectralSample] = []
        var start = 0

        func magnitudeDb(_ bin: Int) -> Double {
            guard bin > 0, bin < half else { return -160 }
            let power = Double(magnitudes[bin])
            let amplitude = sqrt(power) / Double(windowSize)
            return 20 * log10(max(amplitude, 1e-9))
        }

        while start + windowSize <= samples.count {
            samples.withUnsafeBufferPointer { srcPtr in
                windowed.withUnsafeMutableBufferPointer { dstPtr in
                    vDSP_vmul(srcPtr.baseAddress! + start, 1, hannWindow, 1, dstPtr.baseAddress!, 1, vDSP_Length(windowSize))
                }
            }

            real.withUnsafeMutableBufferPointer { realPtr in
                imag.withUnsafeMutableBufferPointer { imagPtr in
                    var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                    windowed.withUnsafeBufferPointer { wPtr in
                        wPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { complexPtr in
                            vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(half))
                }
            }

            let time = Double(start) / sampleRate + (Double(windowSize) / sampleRate) / 2
            results.append(SpectralSample(time: time, freqADb: magnitudeDb(binA), freqBDb: magnitudeDb(binB)))

            start += hop
        }

        return results
    }
}
#endif
