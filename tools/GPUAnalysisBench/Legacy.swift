import AVFoundation
import Foundation
#if canImport(SoundAnalysis)
import SoundAnalysis
#endif
#if canImport(CreateMLComponents)
import CreateMLComponents
#endif

final class LegacyVocalClassifier {
    private let analyzer: SNAudioStreamAnalyzer
    private let observer = VocalClassifier.Observer()
    private let format: AVAudioFormat
    private var position: AVAudioFramePosition = 0
    private let filters: [(Double, Double, Double, Double, Double)]
    private var states: [(Double, Double, Double, Double)]

    init?(sampleRate: Double) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { return nil }
        request.windowDuration = CMTime(seconds: 1, preferredTimescale: 1000)
        request.overlapFactor = 0.5
        let analyzer = SNAudioStreamAnalyzer(format: format)
        do { try analyzer.add(request, withObserver: observer) } catch { return nil }
        self.analyzer = analyzer
        self.format = format
        let hp = VocalClassifier.biquad(highPass: true, cutoff: 250, sampleRate: sampleRate)
        let lp = VocalClassifier.biquad(highPass: false, cutoff: 5_000, sampleRate: sampleRate)
        filters = [hp, hp, lp, lp]
        states = Array(repeating: (0, 0, 0, 0), count: 4)
    }

    static func prefilter(_ samples: UnsafeBufferPointer<Float>, filters: [(Double, Double, Double, Double, Double)], states: inout [(Double, Double, Double, Double)], into out: UnsafeMutablePointer<Float>) {
        for (i, sample) in samples.enumerated() {
            var x = Double(sample)
            for k in 0..<filters.count {
                let f = filters[k]
                let s = states[k]
                let y = f.0 * x + f.1 * s.0 + f.2 * s.1 - f.3 * s.2 - f.4 * s.3
                states[k] = (x, s.0, y, s.2)
                x = y
            }
            out[i] = Float(x)
        }
    }

    func consume(_ samples: UnsafeBufferPointer<Float>) {
        guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let out = buffer.floatChannelData?[0] else { return }
        Self.prefilter(samples, filters: filters, states: &states, into: out)
        buffer.frameLength = AVAudioFrameCount(samples.count)
        analyzer.analyze(buffer, atAudioFramePosition: position)
        position += AVAudioFramePosition(samples.count)
    }

    func finish() -> [Float] {
        analyzer.completeAnalysis()
        return observer.curve(hop: VocalClassifier.hopSeconds)
    }
}

enum Legacy {
    static func extractFeatures(fileURL: URL, options: BeatTracker.Options) async throws -> BeatTrackerFeatures {
        let sampleRate = BeatTracker.sampleRate
        let asset = AVURLAsset(url: fileURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw BeatTracker.TrackerError.noAudioTrack }
        let assetDuration = (try? await asset.load(.duration).seconds) ?? 0
        let duration = min(options.maxSeconds, assetDuration.isFinite && assetDuration > 0 ? assetDuration : options.maxSeconds)
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
        let hopSize = BeatTracker.hop(forDuration: duration, options: options)
        let extractor: any BeatTrackerFeatureExtracting = options.makeExtractor?(hopSize, duration)
            ?? BeatTrackerFeatureExtractor(hop: hopSize, expectedSeconds: duration)
        let voice = LegacyVocalClassifier(sampleRate: sampleRate)
        let cap = Int(sampleRate * duration)
        var scratch = [Float]()
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
                let usable = min(count, max(0, cap - extractor.consumedSamples))
                scratch.withUnsafeBufferPointer {
                    let slice = UnsafeBufferPointer(rebasing: $0[0..<usable])
                    extractor.consume(slice)
                    voice?.consume(slice)
                }
            }
            if extractor.consumedSamples >= cap { break }
        }
        if reader.status == .failed { throw reader.error ?? BeatTracker.TrackerError.readerFailed }
        var features = extractor.finish()
        if let curve = voice?.finish() {
            features.vocalCurve = curve
            features.vocalRanges = VocalClassifier.ranges(curve)
        }
        return features
    }

    static func timbre(url: URL) async throws -> TimbreEmbedding? {
        #if canImport(CreateMLComponents)
        let buffers = try AudioReader.read(contentsOf: url)
        let printer = AudioFeaturePrint(windowDuration: 0.975, overlapFactor: 0)
        var frames: [[Float]] = []
        for try await frame in try printer.applied(to: buffers) {
            frames.append(frame.feature.scalars)
        }
        return TimbreEmbedding(frames: frames)
        #else
        return nil
        #endif
    }

    struct Meter {
        var shelfL: KWeightedMeter.Biquad
        var shelfR: KWeightedMeter.Biquad
        var rumbleL: KWeightedMeter.Biquad
        var rumbleR: KWeightedMeter.Biquad
        var low: KWeightedMeter.Biquad
        var high: KWeightedMeter.Biquad
        var sum = 0.0, lowSum = 0.0, highSum = 0.0, monoSum = 0.0
        var peak: Float = 0
        var count = 0

        init(sampleRate: Double) {
            let f0 = 1_681.974450955533
            let gain = 3.999843853973347
            let q = 0.7071752369554196
            let k = tan(.pi * f0 / sampleRate)
            let vh = pow(10, gain / 20)
            let vb = pow(vh, 0.4996667741545416)
            let a0 = 1 + k / q + k * k
            let shelf = KWeightedMeter.Biquad(
                b0: (vh + vb * k / q + k * k) / a0, b1: 2 * (k * k - vh) / a0, b2: (vh - vb * k / q + k * k) / a0,
                a1: 2 * (k * k - 1) / a0, a2: (1 - k / q + k * k) / a0
            )
            let f1 = 38.13547087602444
            let q1 = 0.5003270373238773
            let k1 = tan(.pi * f1 / sampleRate)
            let d1 = 1 + k1 / q1 + k1 * k1
            let rumble = KWeightedMeter.Biquad(b0: 1, b1: -2, b2: 1, a1: 2 * (k1 * k1 - 1) / d1, a2: (1 - k1 / q1 + k1 * k1) / d1)
            shelfL = shelf; shelfR = shelf; rumbleL = rumble; rumbleR = rumble
            low = .lowPass(LocalLoudness.lowCrossoverHertz, sampleRate: sampleRate)
            high = .highPass(LocalLoudness.highCrossoverHertz, sampleRate: sampleRate)
        }

        mutating func reset() { shelfL.clear(); shelfR.clear(); rumbleL.clear(); rumbleR.clear(); low.clear(); high.clear() }
        mutating func begin() { sum = 0; lowSum = 0; highSum = 0; monoSum = 0; peak = 0; count = 0 }

        mutating func process(_ interleaved: UnsafePointer<Float>, frames: Int) {
            for n in 0..<frames {
                let l = interleaved[2 * n]
                let r = interleaved[2 * n + 1]
                peak = max(peak, abs(l), abs(r))
                let kl = rumbleL.run(shelfL.run(Double(l)))
                let kr = rumbleR.run(shelfR.run(Double(r)))
                sum += kl * kl + kr * kr
                let mono = 0.5 * (kl + kr)
                let lo = low.run(mono)
                let hi = high.run(mono)
                monoSum += mono * mono
                lowSum += lo * lo
                highSum += hi * hi
            }
            count += frames
        }

        func bar() -> LocalLoudness.Bar {
            let power = count > 0 ? sum / Double(count) : 0
            let mono = max(1e-15, monoSum)
            let lowShare = min(1, lowSum / mono)
            let highShare = min(1 - lowShare, highSum / mono)
            return LocalLoudness.Bar(power: power, low: lowShare, mid: max(0, 1 - lowShare - highShare), high: highShare, peak: Double(peak))
        }
    }

    static func loudness(source: MixSource, barStarts: [TimeInterval]) -> [Int: LocalLoudness.Bar] {
        var bars: [Int: LocalLoudness.Bar] = [:]
        let sr = source.sampleRate
        guard barStarts.count > 0, sr > 0 else { return bars }
        let typicalBar = barStarts.count > 1 ? (barStarts[barStarts.count - 1] - barStarts[0]) / Double(barStarts.count - 1) : 2
        var meter = Meter(sampleRate: sr)
        var primed = false
        for index in barStarts.indices {
            let start = Int((barStarts[index] * sr).rounded())
            let end = index + 1 < barStarts.count ? Int((barStarts[index + 1] * sr).rounded()) : start + Int(typicalBar * sr)
            let first = max(0, start)
            let last = min(source.frameCount, end)
            guard last - first > Int(sr * 0.2) else { primed = false; continue }
            if !primed { meter.reset() }
            meter.begin()
            var frame = first
            var complete = true
            while frame < last {
                let chunkIndex = frame >> MixSource.chunkShift
                guard let pointer = source.chunk(chunkIndex) else { complete = false; break }
                let chunkEnd = min(last, (chunkIndex + 1) << MixSource.chunkShift)
                let offset = frame & MixSource.chunkMask
                meter.process(pointer + offset * 2, frames: chunkEnd - frame)
                frame = chunkEnd
            }
            guard complete else { primed = false; continue }
            primed = true
            bars[index] = meter.bar()
        }
        return bars
    }
}
