import Foundation
import AVFoundation
import Accelerate
#if canImport(SoundAnalysis)
import SoundAnalysis
#endif

struct BeatTrackerResult: Codable, Sendable, Equatable {
    struct TempoSegment: Codable, Sendable, Equatable {
        let start: Double
        let bpm: Double
    }

    let version: Int
    let bpm: Double?
    let beats: [Double]
    let downbeats: [Double]
    let phraseOffsetBars: Int
    let phraseStarts: [Double]
    let sectionStarts: [Double]
    let tempoSegments: [TempoSegment]
    let confidence: Double
    let beatConfidence: Double
    let downbeatConfidence: Double
    let tempoClarity: Double
    let analysedSeconds: Double
    var vocalRanges: [VocalRange]? = nil
    var vocalCurve: [Float]? = nil
    var bars: BarProfile? = nil
    var parityConfidence: Double? = nil
    var parityEvidence: [Double]? = nil
    var phaseConfidence: Double? = nil
    var beatPhaseConfidence: Double? = nil
    var sectionStrengths: [Double]? = nil

    struct VocalRange: Codable, Sendable, Equatable {
        let start: Double
        let end: Double
    }

    var vocalSeconds: [ClosedRange<TimeInterval>]? {
        let ranges = vocalCurve.map(VocalClassifier.ranges) ?? vocalRanges
        return ranges?.compactMap { $0.end > $0.start ? $0.start...$0.end : nil }
    }

    var isPhaseReliable: Bool {
        confidence >= BeatTracker.minimumPhaseConfidence && downbeats.count >= 2 && bpm != nil
            && (beatPhaseConfidence ?? 1) >= BeatTracker.minimumBeatPhaseConfidence
    }

    var isParityReliable: Bool {
        isTempoReliable && (parityConfidence ?? 0) >= BeatTracker.minimumPhaseConfidence && downbeats.count >= 2
    }

    var isTempoReliable: Bool {
        beatConfidence >= BeatTracker.minimumTempoConfidence && bpm != nil
    }

    var isBeatReliable: Bool {
        isTempoReliable && beats.count >= 16 && (beatPhaseConfidence ?? 1) >= BeatTracker.minimumBeatPhaseConfidence
    }

    var isBarPhaseReliable: Bool {
        (phaseConfidence ?? downbeatConfidence) >= BeatTracker.minimumPhaseConfidence && downbeats.count >= 2
    }

    var strongestSectionStart: Double? {
        guard let sectionStrengths, sectionStrengths.count == sectionStarts.count,
              let best = sectionStrengths.indices.max(by: { sectionStrengths[$0] < sectionStrengths[$1] }) else { return sectionStarts.first }
        return sectionStarts[best]
    }

    var strongestSectionBar: Int? {
        guard let start = strongestSectionStart, !downbeats.isEmpty else { return nil }
        return downbeats.indices.min { abs(downbeats[$0] - start) < abs(downbeats[$1] - start) }
    }

    func beatOnlyGrid(barsPerPhrase: Int = 8, anchoredOnStrongestSection: Bool = false) -> BeatGrid? {
        guard let bpm, isBeatReliable else { return nil }
        let offset = anchoredOnStrongestSection ? strongestSectionBar.map { $0 % max(1, barsPerPhrase) } ?? phraseOffsetBars : phraseOffsetBars
        return BeatGrid.fromMeasuredBars(
            bpm: bpm,
            beats: beats,
            bars: downbeats,
            barsPerPhrase: barsPerPhrase,
            confidence: 0.92 * beatConfidence * (beatPhaseConfidence ?? 1),
            phraseOffsetBars: offset
        )
    }

    func beatGrid(barsPerPhrase: Int = 8) -> BeatGrid? {
        guard let bpm else { return nil }
        if isPhaseReliable {
            return BeatGrid.fromMeasuredBars(
                bpm: bpm,
                beats: beats,
                bars: downbeats,
                barsPerPhrase: barsPerPhrase,
                confidence: confidence,
                phraseOffsetBars: phraseOffsetBars
            )
        }
        return isTempoReliable ? BeatGrid.tempoOnly(bpm, barsPerPhrase: barsPerPhrase) : nil
    }

    static func empty(analysedSeconds: Double) -> BeatTrackerResult {
        BeatTrackerResult(
            version: BeatTracker.version, bpm: nil, beats: [], downbeats: [], phraseOffsetBars: 0,
            phraseStarts: [], sectionStarts: [], tempoSegments: [], confidence: 0,
            beatConfidence: 0, downbeatConfidence: 0, tempoClarity: 0, analysedSeconds: analysedSeconds
        )
    }
}

enum BeatTracker {
    static let version = 3
    static let sampleRate: Double = 22_050
    static let frameSize = 1024
    static let chromaSize = 4096
    static let fluxLag = 2
    static let slowStrideHops = 8
    static let minBPM = 78.0
    static let maxBPM = 180.0
    static let minimumPhaseConfidence = 0.5
    static let minimumTempoConfidence = 0.6
    static let minimumBeatPhaseConfidence = 0.6
    static let longContentSeconds: TimeInterval = 20 * 60
    static let maxAnalysisSeconds: TimeInterval = 150 * 60
    static let onsetLatencySeconds = 0.0135

    enum TrackerError: Error {
        case noAudioTrack
        case readerFailed
    }

    struct Options: Sendable {
        var maxSeconds: TimeInterval = BeatTracker.maxAnalysisSeconds
        var tempoPrior: Double?
        var hop: Int?
        var makeExtractor: (@Sendable (Int, Double) -> any BeatTrackerFeatureExtracting)?

        init(maxSeconds: TimeInterval = BeatTracker.maxAnalysisSeconds, tempoPrior: Double? = nil, hop: Int? = nil) {
            self.maxSeconds = maxSeconds
            self.tempoPrior = tempoPrior
            self.hop = hop
        }
    }

    static func hop(forDuration duration: TimeInterval, options: Options) -> Int {
        options.hop ?? (duration > longContentSeconds ? 256 : 128)
    }

    static func analyze(
        fileURL: URL,
        options: Options = Options(),
        sinks: [any AnalysisPCMSink] = [],
        yield: (@Sendable () async throws -> Void)? = nil
    ) async throws -> BeatTrackerResult {
        let features = try await extractFeatures(fileURL: fileURL, options: options, sinks: sinks, yield: yield)
        return analyze(features, tempoPrior: options.tempoPrior)
    }

    static func extractFeatures(
        fileURL: URL,
        options: Options = Options(),
        sinks: [any AnalysisPCMSink] = [],
        yield: (@Sendable () async throws -> Void)? = nil
    ) async throws -> BeatTrackerFeatures {
        var extractor: (any BeatTrackerFeatureExtracting)?
        let voice = VocalClassifier(sampleRate: sampleRate)
        try await AnalysisPCMDecode.read(fileURL: fileURL, maxSeconds: options.maxSeconds, yield: yield) { duration in
            let hopSize = hop(forDuration: duration, options: options)
            extractor = options.makeExtractor?(hopSize, duration) ?? BeatTrackerFeatureExtractor(hop: hopSize, expectedSeconds: duration)
        } consume: { slice in
            extractor?.consume(slice)
            voice?.consume(slice)
            for sink in sinks { sink.consume(slice) }
        }
        guard let extractor else { throw TrackerError.readerFailed }
        var features = extractor.finish()
        if let curve = voice?.finish() {
            features.vocalCurve = curve
            features.vocalRanges = VocalClassifier.ranges(curve)
        }
        return features
    }

    static func analyze(samples: [Float], options: Options = Options()) -> BeatTrackerResult {
        let seconds = Double(samples.count) / sampleRate
        let extractor = BeatTrackerFeatureExtractor(hop: hop(forDuration: seconds, options: options), expectedSeconds: seconds)
        samples.withUnsafeBufferPointer { all in
            var offset = 0
            while offset < all.count {
                let end = min(all.count, offset + 8192)
                extractor.consume(UnsafeBufferPointer(rebasing: all[offset..<end]))
                offset = end
            }
        }
        return analyze(extractor.finish(), tempoPrior: options.tempoPrior)
    }
}

protocol AnalysisPCMSink: AnyObject, Sendable {
    func consume(_ samples: UnsafeBufferPointer<Float>)
}

enum AnalysisPCMDecode {
    static func read(
        fileURL: URL,
        maxSeconds: TimeInterval,
        yield: (@Sendable () async throws -> Void)?,
        begin: (TimeInterval) -> Void,
        consume: (UnsafeBufferPointer<Float>) -> Void
    ) async throws {
        let sampleRate = BeatTracker.sampleRate
        let asset = AVURLAsset(url: fileURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw BeatTracker.TrackerError.noAudioTrack }
        let assetDuration = (try? await asset.load(.duration).seconds) ?? 0
        let duration = min(maxSeconds, assetDuration.isFinite && assetDuration > 0 ? assetDuration : maxSeconds)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        let provider = reader.outputProvider(for: output)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 1000))
        try reader.start()
        defer { reader.cancelReading() }

        begin(duration)
        let cap = Int(sampleRate * duration)
        var consumed = 0
        var scratch = [Float]()
        var yieldedAt = 0
        while reader.status == .reading, let ready = try await provider.next() {
            ready.withUnsafeSampleBuffer { buffer in
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { return }
                let length = CMBlockBufferGetDataLength(block)
                let count = length / MemoryLayout<Float>.size
                guard count > 0 else { return }
                if scratch.count < count { scratch = [Float](repeating: 0, count: count) }
                scratch.withUnsafeMutableBytes { raw in
                    _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: raw.baseAddress!)
                }
                let usable = min(count, max(0, cap - consumed))
                scratch.withUnsafeBufferPointer {
                    consume(UnsafeBufferPointer(rebasing: $0[0..<usable]))
                }
                consumed += usable
            }
            if consumed >= cap { break }
            if consumed - yieldedAt >= Int(sampleRate * 15) {
                yieldedAt = consumed
                try Task.checkCancellation()
                try await yield?()
            }
        }
        if reader.status == .failed { throw reader.error ?? BeatTracker.TrackerError.readerFailed }
        scratch = []
        try Task.checkCancellation()
        try await yield?()
    }
}

struct BeatTrackerFeatures {
    let hop: Int
    let sampleRate: Double
    let slowStride: Int
    var low: [Float]
    var lowMid: [Float]
    var mid: [Float]
    var high: [Float]
    var chroma: [Float]
    var bandEnergy: [Float]
    let analysedSeconds: Double
    var vocalRanges: [BeatTrackerResult.VocalRange]? = nil
    var vocalCurve: [Float]? = nil
    var level: [Float] = []

    var frameCount: Int { low.count }
    var slowCount: Int { bandEnergy.count / 4 }
    var frameRate: Double { sampleRate / Double(hop) }

    func time(ofFrame frame: Double) -> Double {
        ((frame + 1) * Double(hop) - Double(BeatTracker.frameSize) / 2 - Double(BeatTracker.fluxLag * hop) / 2) / sampleRate
            + BeatTracker.onsetLatencySeconds
    }

    func frame(ofTime seconds: Double) -> Double {
        ((seconds - BeatTracker.onsetLatencySeconds) * sampleRate + Double(BeatTracker.frameSize) / 2
            + Double(BeatTracker.fluxLag * hop) / 2) / Double(hop) - 1
    }

    func slowIndex(ofTime seconds: Double) -> Double {
        (seconds * sampleRate + Double(BeatTracker.chromaSize) / 2) / Double(slowStride * hop) - 1
    }
}

protocol BeatTrackerFeatureExtracting: AnyObject {
    var consumedSamples: Int { get }
    func consume(_ samples: UnsafeBufferPointer<Float>)
    func finish() -> BeatTrackerFeatures
}

final class BeatTrackerFeatureExtractor: BeatTrackerFeatureExtracting {
    private let hop: Int
    private let frameSize = BeatTracker.frameSize
    private let chromaSize = BeatTracker.chromaSize
    private let half: Int
    private let chromaHalf: Int
    private var window: [Float]
    private var hopBuffer: [Float]
    private var hopFill = 0
    private var hopIndex = 0
    private(set) var consumedSamples = 0

    private let setup: FFTSetup
    private let log2Small: vDSP_Length
    private let log2Large: vDSP_Length
    private let hann: [Float]
    private let hannLarge: [Float]
    private var frame: [Float]
    private var frameLarge: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var magnitude: [Float]
    private var magnitudeLarge: [Float]
    private var logMagnitude: [Float]
    private var history: [[Float]]
    private var historyCursor = 0
    private var difference: [Float]

    private let bandRanges: [Range<Int>]
    private let largeBandRanges: [Range<Int>]
    private let chromaClass: [Int]

    private var low: [Float] = []
    private var lowMid: [Float] = []
    private var mid: [Float] = []
    private var high: [Float] = []
    private var chroma: [Float] = []
    private var bandEnergy: [Float] = []
    private var level: [Float] = []

    init(hop: Int, expectedSeconds: Double) {
        self.hop = hop
        half = frameSize / 2
        chromaHalf = chromaSize / 2
        window = [Float](repeating: 0, count: chromaSize)
        hopBuffer = [Float](repeating: 0, count: hop)
        log2Small = vDSP_Length(log2(Double(frameSize)))
        log2Large = vDSP_Length(log2(Double(chromaSize)))
        setup = vDSP_create_fftsetup(log2Large, FFTRadix(kFFTRadix2))!
        var w = [Float](repeating: 0, count: frameSize)
        vDSP_hann_window(&w, vDSP_Length(frameSize), Int32(vDSP_HANN_NORM))
        hann = w
        var wl = [Float](repeating: 0, count: chromaSize)
        vDSP_hann_window(&wl, vDSP_Length(chromaSize), Int32(vDSP_HANN_NORM))
        hannLarge = wl
        frame = [Float](repeating: 0, count: frameSize)
        frameLarge = [Float](repeating: 0, count: chromaSize)
        real = [Float](repeating: 0, count: chromaSize / 2)
        imag = [Float](repeating: 0, count: chromaSize / 2)
        magnitude = [Float](repeating: 0, count: frameSize / 2)
        magnitudeLarge = [Float](repeating: 0, count: chromaSize / 2)
        logMagnitude = [Float](repeating: 0, count: frameSize / 2)
        history = Array(repeating: [Float](repeating: 0, count: frameSize / 2), count: BeatTracker.fluxLag)
        difference = [Float](repeating: 0, count: frameSize / 2)

        let sr = BeatTracker.sampleRate
        func bins(_ lower: Double, _ upper: Double, size: Int) -> Range<Int> {
            let step = sr / Double(size)
            let a = max(1, Int((lower / step).rounded()))
            let b = min(size / 2, max(a + 1, Int((upper / step).rounded())))
            return a..<b
        }
        let edges: [(Double, Double)] = [(30, 150), (150, 1000), (1000, 5000), (5000, 11_000)]
        bandRanges = edges.map { bins($0.0, $0.1, size: BeatTracker.frameSize) }
        largeBandRanges = edges.map { bins($0.0, $0.1, size: BeatTracker.chromaSize) }
        var classes = [Int](repeating: -1, count: chromaSize / 2)
        let step = sr / Double(chromaSize)
        for k in 1..<(chromaSize / 2) {
            let f = Double(k) * step
            guard f >= 80, f <= 5000 else { continue }
            let pitch = 12 * log2(f / 440) + 69
            classes[k] = (Int(pitch.rounded()) % 12 + 12) % 12
        }
        chromaClass = classes

        let frames = Int(expectedSeconds * BeatTracker.sampleRate / Double(hop)) + 64
        let slow = frames / BeatTracker.slowStrideHops + 8
        low.reserveCapacity(frames)
        lowMid.reserveCapacity(frames)
        mid.reserveCapacity(frames)
        high.reserveCapacity(frames)
        chroma.reserveCapacity(slow * 12)
        bandEnergy.reserveCapacity(slow * 4)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    func consume(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress else { return }
        var offset = 0
        let count = samples.count
        while offset < count {
            let take = min(hop - hopFill, count - offset)
            hopBuffer.withUnsafeMutableBufferPointer { dst in
                (dst.baseAddress! + hopFill).update(from: base + offset, count: take)
            }
            hopFill += take
            offset += take
            if hopFill == hop {
                processHop()
                hopFill = 0
            }
        }
        consumedSamples += count
    }

    func finish() -> BeatTrackerFeatures {
        BeatTrackerFeatures(
            hop: hop,
            sampleRate: BeatTracker.sampleRate,
            slowStride: BeatTracker.slowStrideHops,
            low: low, lowMid: lowMid, mid: mid, high: high,
            chroma: chroma, bandEnergy: bandEnergy,
            analysedSeconds: Double(consumedSamples) / BeatTracker.sampleRate,
            level: level
        )
    }

    private func processHop() {
        var meanSquare: Float = 0
        vDSP_measqv(hopBuffer, 1, &meanSquare, vDSP_Length(hop))
        level.append(meanSquare)
        window.withUnsafeMutableBufferPointer { w in
            let base = w.baseAddress!
            base.update(from: base + hop, count: chromaSize - hop)
            hopBuffer.withUnsafeBufferPointer { src in
                (base + chromaSize - hop).update(from: src.baseAddress!, count: hop)
            }
        }
        spectrum(size: frameSize, log2n: log2Small, offset: chromaSize - frameSize, window: hann, into: &magnitude)

        var scale = Float(1000) / Float(frameSize)
        vDSP_vsmul(magnitude, 1, &scale, &logMagnitude, 1, vDSP_Length(half))
        var count = Int32(half)
        logMagnitude.withUnsafeMutableBufferPointer { buf in
            vvlog1pf(buf.baseAddress!, buf.baseAddress!, &count)
        }
        let previous = history[historyCursor]
        vDSP_vsub(previous, 1, logMagnitude, 1, &difference, 1, vDSP_Length(half))
        var zero: Float = 0
        vDSP_vthres(difference, 1, &zero, &difference, 1, vDSP_Length(half))
        var sums = [Float](repeating: 0, count: 4)
        difference.withUnsafeBufferPointer { d in
            for (i, range) in bandRanges.enumerated() {
                var s: Float = 0
                vDSP_meanv(d.baseAddress! + range.lowerBound, 1, &s, vDSP_Length(range.count))
                sums[i] = s
            }
        }
        history[historyCursor] = logMagnitude
        historyCursor = (historyCursor + 1) % history.count
        low.append(sums[0])
        lowMid.append(sums[1])
        mid.append(sums[2])
        high.append(sums[3])

        hopIndex += 1
        if hopIndex % BeatTracker.slowStrideHops == 0 {
            spectrum(size: chromaSize, log2n: log2Large, offset: 0, window: hannLarge, into: &magnitudeLarge)
            var bins = [Float](repeating: 0, count: 12)
            var total: Float = 0
            for k in 1..<chromaHalf {
                let cls = chromaClass[k]
                guard cls >= 0 else { continue }
                bins[cls] += magnitudeLarge[k]
                total += magnitudeLarge[k]
            }
            let inv: Float = total > 1e-9 ? 1 / total : 0
            for i in 0..<12 { chroma.append(bins[i] * inv) }
            magnitudeLarge.withUnsafeBufferPointer { m in
                for range in largeBandRanges {
                    var s: Float = 0
                    vDSP_meanv(m.baseAddress! + range.lowerBound, 1, &s, vDSP_Length(range.count))
                    bandEnergy.append(log1p(s * 1000 / Float(chromaSize)))
                }
            }
        }
    }

    private func spectrum(size: Int, log2n: vDSP_Length, offset: Int, window weights: [Float], into output: inout [Float]) {
        let halfSize = size / 2
        let isLarge = size == chromaSize
        if isLarge {
            vDSP_vmul(window, 1, weights, 1, &frameLarge, 1, vDSP_Length(size))
        } else {
            window.withUnsafeBufferPointer { w in
                vDSP_vmul(w.baseAddress! + offset, 1, weights, 1, &frame, 1, vDSP_Length(size))
            }
        }
        let source = isLarge ? frameLarge : frame
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                source.withUnsafeBufferPointer { s in
                    s.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { c in
                        vDSP_ctoz(c, 2, &split, 1, vDSP_Length(halfSize))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                split.imagp[0] = 0
                output.withUnsafeMutableBufferPointer { o in
                    vDSP_zvabs(&split, 1, o.baseAddress!, 1, vDSP_Length(halfSize))
                }
            }
        }
    }
}

final class VocalClassifier {
    static let labels: Set<String> = ["singing", "speech", "choir_singing", "rapping", "humming", "yodeling"]
    static let hopSeconds = 0.5
    static let overlapFactor = 0.5
    static let enter: Float = 0.4
    static let leave: Float = 0.22
    static let bridgeSeconds = 2.0
    static let minimumRunSeconds = 1.0
    static let padSeconds = 0.5
    static let sustainedWindowSeconds = 8.0
    static let sustainedFloor: Float = 0.12
    static let sustainedOverBaseline: Float = 3
    static let baselinePercentile = 0.2
    static let sustainedMinimumSeconds = 16.0

    #if canImport(SoundAnalysis)
    private let analyzer: SNAudioStreamAnalyzer
    private let observer = Observer()
    private let format: AVAudioFormat
    private var position: AVAudioFramePosition = 0
    private let prefilter: DoubleBiquadCascade
    #endif

    init?(sampleRate: Double, overlapFactor: Double = VocalClassifier.overlapFactor) {
        #if canImport(SoundAnalysis)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { return nil }
        request.windowDuration = CMTime(seconds: 1, preferredTimescale: 1000)
        request.overlapFactor = overlapFactor
        let analyzer = SNAudioStreamAnalyzer(format: format)
        do { try analyzer.add(request, withObserver: observer) } catch { return nil }
        self.analyzer = analyzer
        self.format = format
        let hp = Self.biquad(highPass: true, cutoff: 250, sampleRate: sampleRate)
        let lp = Self.biquad(highPass: false, cutoff: 5_000, sampleRate: sampleRate)
        guard let prefilter = DoubleBiquadCascade([hp, hp, lp, lp]) else { return nil }
        self.prefilter = prefilter
        #else
        return nil
        #endif
    }

    static func biquad(highPass: Bool, cutoff: Double, sampleRate: Double) -> (Double, Double, Double, Double, Double) {
        let w = 2 * Double.pi * cutoff / sampleRate
        let alpha = sin(w) / (2 * 0.7071)
        let c = cos(w)
        let a0 = 1 + alpha
        let b0 = highPass ? (1 + c) / 2 : (1 - c) / 2
        let b1 = highPass ? -(1 + c) : 1 - c
        return (b0 / a0, b1 / a0, b0 / a0, -2 * c / a0, (1 - alpha) / a0)
    }

    func consume(_ samples: UnsafeBufferPointer<Float>) {
        #if canImport(SoundAnalysis)
        guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let out = buffer.floatChannelData?[0] else { return }
        prefilter.run(samples.baseAddress!, into: out, count: samples.count)
        buffer.frameLength = AVAudioFrameCount(samples.count)
        analyzer.analyze(buffer, atAudioFramePosition: position)
        position += AVAudioFramePosition(samples.count)
        #endif
    }

    func finish() -> [Float]? {
        #if canImport(SoundAnalysis)
        analyzer.completeAnalysis()
        return observer.curve(hop: Self.hopSeconds)
        #else
        return nil
        #endif
    }

    static func smoothed(_ curve: [Float]) -> [Float] {
        guard curve.count > 2 else { return curve }
        return curve.indices.map { i in
            let window = [curve[max(0, i - 1)], curve[i], curve[min(curve.count - 1, i + 1)]].sorted()
            return window[1]
        }
    }

    static func ranges(_ curve: [Float]) -> [BeatTrackerResult.VocalRange] {
        let smooth = smoothed(curve)
        var runs: [(Double, Double)] = []
        var start: Int?
        for (i, value) in smooth.enumerated() {
            if start == nil {
                if value >= enter { start = i }
            } else if value < leave, let s = start {
                runs.append((Double(s) * hopSeconds, Double(i) * hopSeconds))
                start = nil
            }
        }
        if let s = start { runs.append((Double(s) * hopSeconds, Double(smooth.count) * hopSeconds)) }
        let strong = bridged(runs).filter { $0.1 - $0.0 >= minimumRunSeconds }.map { (max(0, $0.0 - padSeconds), $0.1 + padSeconds) }
        let all = bridged((strong + sustainedRuns(curve)).sorted { $0.0 < $1.0 })
        return all.map {
            BeatTrackerResult.VocalRange(start: ($0.0 * 100).rounded() / 100, end: ($0.1 * 100).rounded() / 100)
        }
    }

    static func bridged(_ runs: [(Double, Double)]) -> [(Double, Double)] {
        var merged: [(Double, Double)] = []
        for run in runs {
            if let last = merged.last, run.0 - last.1 < bridgeSeconds {
                merged[merged.count - 1].1 = max(last.1, run.1)
            } else {
                merged.append(run)
            }
        }
        return merged
    }

    static func sustainedRuns(_ curve: [Float]) -> [(Double, Double)] {
        let count = curve.count
        guard count > 2 else { return [] }
        let sorted = curve.sorted()
        let baseline = sorted[Int(baselinePercentile * Double(count - 1))]
        let threshold = max(sustainedFloor, sustainedOverBaseline * baseline)
        let half = Int(sustainedWindowSeconds / hopSeconds) / 2
        var prefix = [Double](repeating: 0, count: count + 1)
        for i in 0..<count { prefix[i + 1] = prefix[i] + Double(curve[i]) }
        var runs: [(Double, Double)] = []
        var start: Int?
        for i in 0...count {
            var on = false
            if i < count {
                let lo = max(0, i - half)
                let hi = min(count, i + half)
                on = (prefix[hi] - prefix[lo]) / Double(hi - lo) >= Double(threshold)
            }
            if on, start == nil { start = i }
            if !on, let s = start {
                if let first = (s..<i).first(where: { curve[$0] >= threshold }),
                   let last = (s..<i).last(where: { curve[$0] >= threshold }) {
                    runs.append((Double(max(0, first - 1)) * hopSeconds, Double(last + 1) * hopSeconds))
                }
                start = nil
            }
        }
        return bridged(runs).filter { $0.1 - $0.0 >= sustainedMinimumSeconds }
    }

    #if canImport(SoundAnalysis)
    final class Observer: NSObject, SNResultsObserving, @unchecked Sendable {
        private let lock = NSLock()
        private var points: [(Double, Float)] = []

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            var best: Float = 0
            for item in result.classifications where VocalClassifier.labels.contains(item.identifier) {
                best = max(best, Float(item.confidence))
            }
            let centre = result.timeRange.start.seconds + result.timeRange.duration.seconds / 2
            lock.lock()
            points.append((centre, best))
            lock.unlock()
        }

        func curve(hop: Double) -> [Float] {
            lock.lock()
            let all = points.sorted { $0.0 < $1.0 }
            lock.unlock()
            guard let last = all.last else { return [] }
            var out = [Float](repeating: 0, count: Int(last.0 / hop) + 1)
            var filled = [Bool](repeating: false, count: out.count)
            for (t, v) in all {
                let i = min(out.count - 1, max(0, Int(t / hop)))
                out[i] = max(out[i], v)
                filled[i] = true
            }
            if let first = filled.firstIndex(of: true) {
                var previous = first
                for i in (first + 1)..<out.count where filled[i] {
                    if i - previous > 1 {
                        for j in (previous + 1)..<i {
                            let w = Float(j - previous) / Float(i - previous)
                            out[j] = out[previous] + (out[i] - out[previous]) * w
                        }
                    }
                    previous = i
                }
            }
            return out.map { ($0 * 1000).rounded() / 1000 }
        }
    }
    #endif
}

struct BarProfile: Codable, Sendable, Equatable {
    let level: [Float]
    let density: [Float]
    let loop4: [Float]
    let loop8: [Float]
    var bands: [Float]? = nil
    var tonality: [Float]? = nil
    var beats: [Float]? = nil

    static let sparseDensity: Float = 0.5
    static let beatsPerBar = 4

    func beatLevel(bar: Int, beat: Int) -> Float? {
        guard let beats, bar * Self.beatsPerBar + beat < beats.count, beat >= 0, beat < Self.beatsPerBar else { return nil }
        return beats[bar * Self.beatsPerBar + beat]
    }

    func band(_ k: Int, bar: Int) -> Float? {
        guard let bands, bar * 4 + k < bands.count else { return nil }
        return bands[bar * 4 + k]
    }
    static let loopable: Float = 0.8

    static func measure(_ features: BeatTrackerFeatures, downbeats: [Double]) -> BarProfile? {
        let count = downbeats.count
        guard count >= 9, features.frameCount > 0 else { return nil }
        var level = [Float](repeating: -90, count: count)
        var flux = [Float](repeating: 0, count: count)
        var vectors = [[Float]](repeating: [], count: count)
        var barBands = [Float](repeating: 0, count: count * 4)
        var barTonality = [Float](repeating: 0, count: count)
        var beatLevels = [Float](repeating: -90, count: count * beatsPerBar)
        let slowCount = features.slowCount
        for b in 0..<count {
            let start = downbeats[b]
            let end = b + 1 < count ? downbeats[b + 1] : start + (downbeats[b] - downbeats[b - 1])
            let f0 = max(0, Int(features.frame(ofTime: start).rounded()))
            let f1 = min(features.frameCount, max(f0 + 1, Int(features.frame(ofTime: end).rounded())))
            guard f1 > f0 + 16 else { continue }
            var pattern = [Float](repeating: 0, count: 32)
            var total: Float = 0
            for f in f0..<f1 {
                let step = min(15, (f - f0) * 16 / (f1 - f0))
                pattern[step] += features.low[f]
                let upper = features.lowMid[f] + features.mid[f] + features.high[f]
                pattern[16 + step] += upper
                total += features.low[f] + upper
            }
            flux[b] = total / Float(f1 - f0)
            if !features.level.isEmpty {
                let lo = min(features.level.count - 1, f0)
                let hi = min(features.level.count, f1)
                var sum: Float = 0
                for f in lo..<hi { sum += features.level[f] }
                level[b] = 10 * log10(max(1e-10, sum / Float(max(1, hi - lo))))
                let span = Float(hi - lo) / Float(beatsPerBar)
                for k in 0..<beatsPerBar {
                    let q0 = lo + Int(Float(k) * span)
                    let q1 = max(q0 + 1, min(hi, lo + Int(Float(k + 1) * span)))
                    guard q1 <= features.level.count else { continue }
                    var part: Float = 0
                    for f in q0..<q1 { part += features.level[f] }
                    beatLevels[b * beatsPerBar + k] = 10 * log10(max(1e-10, part / Float(q1 - q0)))
                }
            }
            let s0 = max(0, Int(features.slowIndex(ofTime: start).rounded()))
            let s1 = min(slowCount, max(s0 + 1, Int(features.slowIndex(ofTime: end).rounded())))
            var chroma = [Float](repeating: 0, count: 12)
            var bands = [Float](repeating: 0, count: 4)
            if s1 > s0 {
                for s in s0..<s1 {
                    for k in 0..<12 { chroma[k] += features.chroma[s * 12 + k] }
                    for k in 0..<4 { bands[k] += features.bandEnergy[s * 4 + k] }
                }
                for k in 0..<4 { bands[k] /= Float(s1 - s0) }
            }
            vectors[b] = unit(chroma) + unit(Array(pattern[0..<16])) + unit(Array(pattern[16..<32])) + bands
            for k in 0..<4 { barBands[b * 4 + k] = bands[k] }
            let chromaTotal = chroma.reduce(0, +)
            barTonality[b] = chromaTotal > 1e-9 ? (chroma.max() ?? 0) / chromaTotal * 12 : 0
        }
        func similarity(_ a: Int, _ b: Int) -> Float {
            guard a >= 0, b >= 0, a < count, b < count, vectors[a].count == 48, vectors[b].count == 48 else { return 0 }
            let x = vectors[a]
            let y = vectors[b]
            var chroma: Float = 0
            var low: Float = 0
            var high: Float = 0
            for k in 0..<12 { chroma += x[k] * y[k] }
            for k in 12..<28 { low += x[k] * y[k] }
            for k in 28..<44 { high += x[k] * y[k] }
            var band: Float = 0
            for k in 44..<48 { band += abs(x[k] - y[k]) }
            let bandScore = max(0, 1 - band / 2)
            return 0.3 * chroma + 0.25 * low + 0.25 * high + 0.2 * bandScore
        }
        func loopability(_ start: Int, _ length: Int) -> Float {
            guard start + length <= count else { return 0 }
            let forward = start + 2 * length <= count
            let backward = start - length >= 0
            guard forward || backward else { return 0 }
            func score(_ offset: Int) -> Float {
                var sum: Float = 0
                for k in 0..<length { sum += similarity(start + k, start + k + offset) }
                let seam = start + length < count ? similarity(start, start + length) : sum / Float(length)
                let wrap = start >= 1 ? similarity(start + length - 1, start - 1) : sum / Float(length)
                return 0.6 * sum / Float(length) + 0.25 * seam + 0.15 * wrap
            }
            return max(forward ? score(length) : 0, backward ? score(-length) : 0)
        }
        func ranks(_ values: [Float]) -> [Float] {
            let order = values.indices.sorted { values[$0] < values[$1] }
            var out = [Float](repeating: 0, count: values.count)
            for (r, i) in order.enumerated() { out[i] = Float(r) / Float(max(1, values.count - 1)) }
            return out
        }
        let loudRank = ranks(level)
        let fluxRank = ranks(flux)
        func round3(_ x: Float) -> Float { (x * 1000).rounded() / 1000 }
        return BarProfile(
            level: level.map { ($0 * 10).rounded() / 10 },
            density: (0..<count).map { round3(0.5 * loudRank[$0] + 0.5 * fluxRank[$0]) },
            loop4: (0..<count).map { round3(loopability($0, 4)) },
            loop8: (0..<count).map { round3(loopability($0, 8)) },
            bands: barBands.map(round3),
            tonality: barTonality.map(round3),
            beats: beatLevels.map { ($0 * 10).rounded() / 10 }
        )
    }

    private static func unit(_ v: [Float]) -> [Float] {
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return n > 1e-9 ? v.map { $0 / n } : v
    }
}

final class DoubleBiquadCascade: @unchecked Sendable {
    private let setup: vDSP_biquad_SetupD
    private var delay: [Double]
    private var wide = [Double]()
    private var filtered = [Double]()

    init?(_ sections: [(Double, Double, Double, Double, Double)]) {
        let flat = sections.flatMap { [$0.0, $0.1, $0.2, $0.3, $0.4] }
        guard !sections.isEmpty, let setup = vDSP_biquad_CreateSetupD(flat, vDSP_Length(sections.count)) else { return nil }
        self.setup = setup
        delay = [Double](repeating: 0, count: 2 * sections.count + 2)
    }

    deinit { vDSP_biquad_DestroySetupD(setup) }

    func run(_ input: UnsafePointer<Float>, into output: UnsafeMutablePointer<Float>, count: Int) {
        guard count > 0 else { return }
        if wide.count < count {
            wide = [Double](repeating: 0, count: count)
            filtered = wide
        }
        let n = vDSP_Length(count)
        wide.withUnsafeMutableBufferPointer { w in
            filtered.withUnsafeMutableBufferPointer { f in
                delay.withUnsafeMutableBufferPointer { d in
                    vDSP_vspdp(input, 1, w.baseAddress!, 1, n)
                    vDSP_biquadD(setup, d.baseAddress!, w.baseAddress!, 1, f.baseAddress!, 1, n)
                    vDSP_vdpsp(f.baseAddress!, 1, output, 1, n)
                }
            }
        }
    }
}
