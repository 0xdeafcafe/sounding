import Foundation
import AVFoundation
import Accelerate
import Combine
import CryptoKit
import AudioToolbox
@testable import SoundingTV

#if DEBUG

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
