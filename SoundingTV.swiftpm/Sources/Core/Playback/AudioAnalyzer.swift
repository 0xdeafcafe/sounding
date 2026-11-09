import Foundation
import AVFoundation
import Accelerate

enum AudioAnalyzer {
    static let analysisSampleRate: Double = 22_050
    static let maxAnalysisSeconds: TimeInterval = 240
    static let bpmFrameSize = 1024
    static let bpmHopSize = 256
    static let minBPM: Double = 55
    static let maxBPM: Double = 200
    static let foldedMinBPM: Double = 78
    static let foldedMaxBPM: Double = 180
    static let keyFrameSize = 4096
    static let keyHopSize = 2048

    enum AnalyzerError: Error {
        case noAudioTrack
        case readerFailed
        case notEnoughSamples
    }

    static func analyze(streamURL: URL, duration: TimeInterval, trackId: String) async throws -> TrackAnalysis {
        let asset = AVURLAsset(url: streamURL)
        let samples = try await readPCM(from: asset, maxSeconds: maxAnalysisSeconds)

        guard samples.count >= Int(analysisSampleRate * 5) else {
            throw AnalyzerError.notEnoughSamples
        }

        let bpm = computeBPM(samples: samples, sampleRate: analysisSampleRate)
        let key = computeKey(samples: samples, sampleRate: analysisSampleRate)
        let energy = computeEnergy(samples: samples)
        let intro = computeIntro(samples: samples, sampleRate: analysisSampleRate)
        let outro = max(0, duration - 16)

        return TrackAnalysis(
            trackId: trackId,
            bpm: bpm,
            key: key,
            energy: energy,
            intro: intro,
            outro: outro,
            isEstimated: false
        )
    }

    private static func readPCM(from asset: AVURLAsset, maxSeconds: TimeInterval) async throws -> [Float] {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw AnalyzerError.noAudioTrack }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: analysisSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        let provider = reader.outputProvider(for: output)
        reader.timeRange = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: maxSeconds, preferredTimescale: 1000)
        )

        try reader.start()

        let cap = Int(analysisSampleRate * maxSeconds)
        var samples: [Float] = []
        samples.reserveCapacity(cap)

        while reader.status == .reading, let readyBuffer = try await provider.next() {
            readyBuffer.withUnsafeSampleBuffer { buffer in
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { return }
                let length = CMBlockBufferGetDataLength(block)
                let floatCount = length / MemoryLayout<Float>.size
                var chunk = [Float](repeating: 0, count: floatCount)
                chunk.withUnsafeMutableBytes { rawBuf in
                    _ = CMBlockBufferCopyDataBytes(
                        block,
                        atOffset: 0,
                        dataLength: length,
                        destination: rawBuf.baseAddress!
                    )
                }
                samples.append(contentsOf: chunk)
            }
            if samples.count >= cap { break }
        }

        if reader.status == .failed {
            throw reader.error ?? AnalyzerError.readerFailed
        }
        reader.cancelReading()
        return samples
    }

    private static func computeBPM(samples: [Float], sampleRate: Double) -> Double? {
        let frameSize = bpmFrameSize
        let hopSize = bpmHopSize
        let halfSize = frameSize / 2

        let log2n = vDSP_Length(log2(Double(frameSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: frameSize)
        vDSP_hann_window(&window, vDSP_Length(frameSize), Int32(vDSP_HANN_NORM))

        let frameCount = max(0, (samples.count - frameSize) / hopSize + 1)
        guard frameCount > 8 else { return nil }

        var prevMag = [Float](repeating: 0, count: halfSize)
        var flux = [Float](repeating: 0, count: frameCount)
        var frame = [Float](repeating: 0, count: frameSize)
        var diff = [Float](repeating: 0, count: halfSize)

        for f in 0..<frameCount {
            let start = f * hopSize
            samples.withUnsafeBufferPointer { src in
                window.withUnsafeBufferPointer { win in
                    frame.withUnsafeMutableBufferPointer { dst in
                        guard let srcBase = src.baseAddress,
                              let winBase = win.baseAddress,
                              let dstBase = dst.baseAddress else { return }
                        vDSP_vmul(
                            srcBase.advanced(by: start), 1,
                            winBase, 1,
                            dstBase, 1,
                            vDSP_Length(frameSize)
                        )
                    }
                }
            }
            let mag = magnitudeSpectrum(of: frame, log2n: log2n, setup: setup)
            vDSP_vsub(prevMag, 1, mag, 1, &diff, 1, vDSP_Length(halfSize))
            var zero: Float = 0
            vDSP_vthr(diff, 1, &zero, &diff, 1, vDSP_Length(halfSize))
            var sum: Float = 0
            vDSP_sve(diff, 1, &sum, vDSP_Length(halfSize))
            flux[f] = sum
            prevMag = mag
        }

        var smoothed = flux
        for i in 1..<(flux.count - 1) {
            smoothed[i] = (flux[i - 1] + flux[i] + flux[i + 1]) / 3
        }
        var mean: Float = 0
        vDSP_meanv(smoothed, 1, &mean, vDSP_Length(smoothed.count))
        var negMean = -mean
        vDSP_vsadd(smoothed, 1, &negMean, &smoothed, 1, vDSP_Length(smoothed.count))

        let frameRate = sampleRate / Double(hopSize)
        let count = smoothed.count
        func autocorrelation(_ lag: Int) -> Double {
            guard lag > 0, lag < count else { return 0 }
            var dot: Float = 0
            smoothed.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                vDSP_dotpr(base, 1, base.advanced(by: lag), 1, &dot, vDSP_Length(count - lag))
            }
            return Double(dot) / Double(count - lag)
        }

        let minLag = max(2, Int((60.0 * frameRate / maxBPM).rounded(.down)))
        let maxLag = min(count / 4, Int((60.0 * frameRate / minBPM).rounded(.up)))
        guard maxLag > minLag + 2 else { return nil }

        var acf = [Double](repeating: 0, count: maxLag * 4 + 3)
        for lag in 1..<min(acf.count, count) { acf[lag] = autocorrelation(lag) }

        var bestLag = 0
        var bestScore = -Double.infinity
        for lag in minLag...maxLag {
            var score = acf[lag]
            if 2 * lag < acf.count { score += 0.5 * acf[2 * lag] }
            if 4 * lag < acf.count { score += 0.25 * acf[4 * lag] }
            if score > bestScore {
                bestScore = score
                bestLag = lag
            }
        }
        guard bestLag > 0 else { return nil }

        var period = Double(bestLag)
        var multiple = 1
        while multiple <= 32 {
            let center = Int((period * Double(multiple)).rounded())
            guard center + 2 < count / 2 else { break }
            var peakLag = center
            var peakValue = autocorrelation(center)
            for lag in (center - 2)...(center + 2) where lag > 1 {
                let value = autocorrelation(lag)
                if value > peakValue {
                    peakValue = value
                    peakLag = lag
                }
            }
            let left = autocorrelation(peakLag - 1)
            let right = autocorrelation(peakLag + 1)
            let curvature = left - 2 * peakValue + right
            let offset = curvature < 0 ? 0.5 * (left - right) / curvature : 0
            guard abs(offset) <= 1 else { break }
            period = (Double(peakLag) + offset) / Double(multiple)
            multiple *= 2
        }

        guard period > 0 else { return nil }
        var bpm = 60.0 * frameRate / period
        while bpm < foldedMinBPM { bpm *= 2 }
        while bpm >= foldedMaxBPM { bpm /= 2 }
        return (bpm * 100).rounded() / 100
    }
    private static func computeKey(samples: [Float], sampleRate: Double) -> String? {
        let frameSize = keyFrameSize
        let hopSize = keyHopSize
        let halfSize = frameSize / 2

        let log2n = vDSP_Length(log2(Double(frameSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: frameSize)
        vDSP_hann_window(&window, vDSP_Length(frameSize), Int32(vDSP_HANN_NORM))

        let frameCount = max(0, (samples.count - frameSize) / hopSize + 1)
        guard frameCount > 0 else { return nil }

        let binStep = sampleRate / Double(frameSize)
        var binToClass = [Int](repeating: -1, count: halfSize)
        for k in 1..<halfSize {
            let freq = Double(k) * binStep
            if freq < 80 || freq > 5000 { continue }
            let pitch = 12.0 * log2(freq / 440.0) + 69.0
            binToClass[k] = (Int(pitch.rounded()) % 12 + 12) % 12
        }

        var chroma = [Float](repeating: 0, count: 12)
        var frame = [Float](repeating: 0, count: frameSize)

        for f in 0..<frameCount {
            let start = f * hopSize
            samples.withUnsafeBufferPointer { src in
                window.withUnsafeBufferPointer { win in
                    frame.withUnsafeMutableBufferPointer { dst in
                        guard let srcBase = src.baseAddress,
                              let winBase = win.baseAddress,
                              let dstBase = dst.baseAddress else { return }
                        vDSP_vmul(
                            srcBase.advanced(by: start), 1,
                            winBase, 1,
                            dstBase, 1,
                            vDSP_Length(frameSize)
                        )
                    }
                }
            }
            let mag = magnitudeSpectrum(of: frame, log2n: log2n, setup: setup)
            for k in 1..<halfSize {
                let cls = binToClass[k]
                if cls >= 0 { chroma[cls] += mag[k] }
            }
        }

        var maxChroma: Float = 0
        vDSP_maxv(chroma, 1, &maxChroma, vDSP_Length(12))
        guard maxChroma > 0 else { return nil }
        var inv = 1.0 / maxChroma
        vDSP_vsmul(chroma, 1, &inv, &chroma, 1, vDSP_Length(12))

        let major: [Float] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
        let minor: [Float] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]
        let names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]

        var bestScore: Float = -.infinity
        var bestName = "C"
        var bestMode = ""

        for tonic in 0..<12 {
            var tplMaj = [Float](repeating: 0, count: 12)
            var tplMin = [Float](repeating: 0, count: 12)
            for i in 0..<12 {
                tplMaj[i] = major[(i - tonic + 12) % 12]
                tplMin[i] = minor[(i - tonic + 12) % 12]
            }
            let scoreMaj = pearson(chroma, tplMaj)
            let scoreMin = pearson(chroma, tplMin)
            if scoreMaj > bestScore { bestScore = scoreMaj; bestName = names[tonic]; bestMode = "" }
            if scoreMin > bestScore { bestScore = scoreMin; bestName = names[tonic]; bestMode = "m" }
        }

        return bestName + bestMode
    }

    private static func computeEnergy(samples: [Float]) -> Double {
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        return max(0, min(1, (Double(rms) - 0.05) / 0.55))
    }

    private static func computeIntro(samples: [Float], sampleRate: Double) -> TimeInterval {
        let windowSize = Int(sampleRate * 1.0)
        guard samples.count >= windowSize * 2 else { return 0 }

        let windows = samples.count / windowSize
        var rmsByWindow = [Float](repeating: 0, count: windows)
        guard let base = samples.withUnsafeBufferPointer({ $0.baseAddress }) else { return 0 }
        for w in 0..<windows {
            var rms: Float = 0
            vDSP_rmsqv(
                base.advanced(by: w * windowSize), 1,
                &rms, vDSP_Length(windowSize)
            )
            rmsByWindow[w] = rms
        }

        var avg: Float = 0
        vDSP_meanv(rmsByWindow, 1, &avg, vDSP_Length(rmsByWindow.count))
        let threshold = avg * 0.45

        var firstLoud = 0
        for (idx, v) in rmsByWindow.enumerated() where v >= threshold {
            firstLoud = idx
            break
        }
        return TimeInterval(firstLoud)
    }

    private static func magnitudeSpectrum(of frame: [Float], log2n: vDSP_Length, setup: FFTSetup) -> [Float] {
        let frameSize = frame.count
        let halfSize = frameSize / 2
        var realp = [Float](repeating: 0, count: halfSize)
        var imagp = [Float](repeating: 0, count: halfSize)
        var mag = [Float](repeating: 0, count: halfSize)

        guard let frameBase = frame.withUnsafeBufferPointer({ $0.baseAddress }) else { return mag }
        frameBase.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { cmplxPtr in
            realp.withUnsafeMutableBufferPointer { rBuf in
                imagp.withUnsafeMutableBufferPointer { iBuf in
                    guard let rBase = rBuf.baseAddress, let iBase = iBuf.baseAddress else { return }
                    var split = DSPSplitComplex(realp: rBase, imagp: iBase)
                    vDSP_ctoz(cmplxPtr, 2, &split, 1, vDSP_Length(halfSize))
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    mag.withUnsafeMutableBufferPointer { magBuf in
                        guard let magBase = magBuf.baseAddress else { return }
                        vDSP_zvabs(&split, 1, magBase, 1, vDSP_Length(halfSize))
                    }
                }
            }
        }
        return mag
    }

    private static func pearson(_ a: [Float], _ b: [Float]) -> Float {
        let n = vDSP_Length(a.count)
        var meanA: Float = 0
        var meanB: Float = 0
        vDSP_meanv(a, 1, &meanA, n)
        vDSP_meanv(b, 1, &meanB, n)
        var negA = -meanA
        var negB = -meanB
        var dA = [Float](repeating: 0, count: a.count)
        var dB = [Float](repeating: 0, count: b.count)
        vDSP_vsadd(a, 1, &negA, &dA, 1, n)
        vDSP_vsadd(b, 1, &negB, &dB, 1, n)
        var num: Float = 0
        vDSP_dotpr(dA, 1, dB, 1, &num, n)
        var sqA: Float = 0
        var sqB: Float = 0
        vDSP_svesq(dA, 1, &sqA, n)
        vDSP_svesq(dB, 1, &sqB, n)
        let denom = sqrt(sqA * sqB)
        return denom > 0 ? num / denom : 0
    }
}
