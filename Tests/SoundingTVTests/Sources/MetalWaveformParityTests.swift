import AVFoundation
import Metal
import XCTest

final class MetalWaveformParityTests: XCTestCase {
    private func generated(seconds: Double, rate: Double = 44100) -> [Float] {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        return (0 ..< Int(seconds * rate)).map { i in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = Float(Int64(bitPattern: seed >> 11) % 2000) / 2000 - 0.5
            let t = Double(i) / rate
            let gate: Double = t.truncatingRemainder(dividingBy: 0.5) < 0.1 ? 1 : 0
            return Float(0.5 * sin(2 * .pi * 55 * t) + 0.2 * sin(2 * .pi * 6000 * t) * gate) + noise * 0.15
        }
    }

    private func assertClose(_ a: [Float], _ b: [Float], relative: Float = 1e-4, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, file: file, line: line)
        for i in 0 ..< min(a.count, b.count) {
            let tolerance = max(abs(b[i]) * relative, 1e-6)
            if abs(a[i] - b[i]) > tolerance {
                XCTFail("index \(i): \(a[i]) vs \(b[i])", file: file, line: line)
                return
            }
        }
    }

    private func assertClose(_ a: WaveformBandFrames, _ b: WaveformBandFrames, file: StaticString = #filePath, line: UInt = #line) {
        assertClose(a.amplitude, b.amplitude, file: file, line: line)
        assertClose(a.low, b.low, file: file, line: line)
        assertClose(a.mid, b.mid, file: file, line: line)
        assertClose(a.high, b.high, file: file, line: line)
    }

    func testParallelCPUMatchesSerialReference() {
        let x = generated(seconds: 12)
        let filter = WaveformBandFilter(sampleRate: 44100, entriesPerSecond: 150)
        let serial = x.withUnsafeBufferPointer { WaveformBandsCPU.serial($0, filter: filter) }
        let parallel = x.withUnsafeBufferPointer { WaveformBandsCPU.parallel($0, filter: filter, windowsPerTask: 64) }
        assertClose(parallel, serial)
    }

    func testStreamMatchesSerialAcrossSegmentBoundaries() {
        let x = generated(seconds: 9)
        let filter = WaveformBandFilter(sampleRate: 44100, entriesPerSecond: 150)
        let serial = x.withUnsafeBufferPointer { WaveformBandsCPU.serial($0, filter: filter) }
        var stream = WaveformBandStream(filter: filter, segmentWindows: 97) { x, filter, prefix in
            WaveformBandsCPU.parallel(x, filter: filter, prefix: prefix, windowsPerTask: 16)
        }
        x.withUnsafeBufferPointer { all in
            var i = 0
            while i < all.count {
                let n = min(5000, all.count - i)
                stream.append(UnsafeBufferPointer(rebasing: all[i ..< i + n]))
                i += n
            }
        }
        assertClose(stream.finish(), serial)
    }

    func testGPUBandsMatchCPUReference() throws {
        let context = try XCTUnwrap(MetalWaveformContext.shared)
        let x = generated(seconds: 12)
        let filter = WaveformBandFilter(sampleRate: 44100, entriesPerSecond: 150)
        let serial = x.withUnsafeBufferPointer { WaveformBandsCPU.serial($0, filter: filter) }
        let gpu = try XCTUnwrap(x.withUnsafeBufferPointer { WaveformBandsGPU.compute($0, filter: filter, context: context) })
        assertClose(gpu, serial)
        var stream = WaveformBandStream.best(filter: filter)
        x.withUnsafeBufferPointer { stream.append($0) }
        assertClose(stream.finish(), serial)
    }

    func testGPUPyramidMatchesCPUPyramidBitForBit() throws {
        let context = try XCTUnwrap(MetalWaveformContext.shared)
        let x = generated(seconds: 30)
        let filter = WaveformBandFilter(sampleRate: 44100, entriesPerSecond: 150)
        let base = WaveformPyramid.baseBins(bands: x.withUnsafeBufferPointer { WaveformBandsCPU.serial($0, filter: filter) })
        let cpu = WaveformPyramid.buildLevels(base: base)
        let gpu = try XCTUnwrap(WaveformPyramidGPU.buildLevels(base: base, context: context))
        XCTAssertEqual(gpu.offsets, cpu.offsets)
        let bins = Array(UnsafeBufferPointer(start: gpu.buffer.contents().assumingMemoryBound(to: SIMD2<UInt32>.self), count: cpu.bins.count))
        XCTAssertEqual(bins, cpu.bins)
        XCTAssertEqual(cpu.counts.last, 1)
    }

    func testPyramidReductionKeepsExtremes() {
        let base = [
            WaveformPyramid.pack(min: -0.2, max: 0.9, rms: 0.4, low: 0.1, mid: 0.8, high: 0.2),
            WaveformPyramid.pack(min: -0.7, max: 0.3, rms: 0.6, low: 0.9, mid: 0.1, high: 0.3),
            WaveformPyramid.pack(min: -0.1, max: 0.1, rms: 0.1, low: 0.0, mid: 0.0, high: 1.0),
        ]
        let built = WaveformPyramid.buildLevels(base: base)
        let top = WaveformPyramid.unpack(built.bins[built.offsets.last!])
        XCTAssertEqual(top.min, -0.7, accuracy: 0.01)
        XCTAssertEqual(top.max, 0.9, accuracy: 0.01)
        XCTAssertEqual(top.bands.y, 0.9, accuracy: 0.01)
        XCTAssertEqual(top.bands.w, 1.0, accuracy: 0.01)
    }

    func testAudioAnalysisGPUAndCPUPathsAgreeOnFixtureAudio() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("metal-parity-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeFixture(to: url, samples: generated(seconds: 6))
        let gpu = try DJAudioAnalysis.waveform(url, useGPU: true)
        let cpu = try DJAudioAnalysis.waveform(url, useGPU: false)
        XCTAssertEqual(gpu.amplitude.count, 900)
        assertClose(gpu.amplitude, cpu.amplitude)
        assertClose(try XCTUnwrap(gpu.low), try XCTUnwrap(cpu.low))
        assertClose(try XCTUnwrap(gpu.high), try XCTUnwrap(cpu.high))
    }

    private func writeFixture(to url: URL, samples: [Float]) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for i in samples.indices {
            channels[0][i] = samples[i]
            channels[1][i] = samples[i] * 0.5
        }
        try file.write(from: buffer)
    }

    func testRendererDrawsAtEveryZoomWithoutMainThreadData() throws {
        let renderer = try XCTUnwrap(MetalWaveformRenderer())
        let x = generated(seconds: 20)
        let pyramid = x.withUnsafeBufferPointer { WaveformPyramid(mono: $0, sampleRate: 44100) }
        let source = try XCTUnwrap(MetalWaveformSource(id: "fixture", pyramid: pyramid))
        let ranges: [ClosedRange<TimeInterval>] = [0 ... 20, 4 ... 6, 5 ... 5.01]
        var levels: [Int] = []
        for range in ranges {
            let result = try XCTUnwrap(renderer.snapshot(
                source: source,
                timeline: .range(range, playhead: range.lowerBound + (range.upperBound - range.lowerBound) / 2),
                grid: MetalWaveformBeatGrid(bpm: 128),
                overlays: [MetalWaveformOverlay(id: "cue", kind: .cue(5), color: SIMD4(1, 0, 0, 1))],
                style: .threeBand,
                size: CGSize(width: 400, height: 80),
                scale: 2
            ))
            XCTAssertNotNil(result.image)
            levels.append(result.stats.level)
        }
        XCTAssertGreaterThan(levels[0], levels[1])
        XCTAssertEqual(levels[2], 0)
    }
}
