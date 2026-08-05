import Foundation
import AVFoundation
import Accelerate

// Standalone extraction of the app's existing AudioAnalyzer
// (SoundingTV.swiftpm/Sources/Services/PlayerService.swift, lines ~2751-3113),
// verbatim DSP logic, for a direct side-by-side comparison against
// MusicUnderstanding on the same inputs. Only the outer plumbing (Track /
// TrackAnalysis / async network fetch) is stripped since this harness reads
// local files directly.

let analysisSampleRate: Double = 22_050
let maxAnalysisSeconds: TimeInterval = 60
let bpmFrameSize = 1024
let bpmHopSize = 512
let keyFrameSize = 4096
let keyHopSize = 2048

enum AnalyzerError: Error { case noAudioTrack, readerFailed, notEnoughSamples }

func readPCM(from asset: AVURLAsset, maxSeconds: TimeInterval) async throws -> [Float] {
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
    output.alwaysCopiesSampleData = false
    reader.add(output)
    reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: maxSeconds, preferredTimescale: 1000))

    guard reader.startReading() else { throw reader.error ?? AnalyzerError.readerFailed }

    let cap = Int(analysisSampleRate * maxSeconds)
    var samples: [Float] = []
    samples.reserveCapacity(cap)

    while reader.status == .reading, let buffer = output.copyNextSampleBuffer() {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
        let length = CMBlockBufferGetDataLength(block)
        let floatCount = length / MemoryLayout<Float>.size
        var chunk = [Float](repeating: 0, count: floatCount)
        chunk.withUnsafeMutableBytes { rawBuf in
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: rawBuf.baseAddress!)
        }
        samples.append(contentsOf: chunk)
        if samples.count >= cap { break }
    }
    if reader.status == .failed { throw reader.error ?? AnalyzerError.readerFailed }
    reader.cancelReading()
    return samples
}

func magnitudeSpectrum(of frame: [Float], log2n: vDSP_Length, setup: FFTSetup) -> [Float] {
    let frameSize = frame.count
    let halfSize = frameSize / 2
    var realp = [Float](repeating: 0, count: halfSize)
    var imagp = [Float](repeating: 0, count: halfSize)
    var mag = [Float](repeating: 0, count: halfSize)
    frame.withUnsafeBufferPointer { frameBuf in
        frameBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { cmplxPtr in
            realp.withUnsafeMutableBufferPointer { rBuf in
                imagp.withUnsafeMutableBufferPointer { iBuf in
                    var split = DSPSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                    vDSP_ctoz(cmplxPtr, 2, &split, 1, vDSP_Length(halfSize))
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    mag.withUnsafeMutableBufferPointer { magBuf in
                        vDSP_zvabs(&split, 1, magBuf.baseAddress!, 1, vDSP_Length(halfSize))
                    }
                }
            }
        }
    }
    return mag
}

func computeBPM(samples: [Float], sampleRate: Double) -> Double? {
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
    for f in 0..<frameCount {
        let start = f * hopSize
        samples.withUnsafeBufferPointer { src in
            window.withUnsafeBufferPointer { win in
                frame.withUnsafeMutableBufferPointer { dst in
                    vDSP_vmul(src.baseAddress!.advanced(by: start), 1, win.baseAddress!, 1, dst.baseAddress!, 1, vDSP_Length(frameSize))
                }
            }
        }
        let mag = magnitudeSpectrum(of: frame, log2n: log2n, setup: setup)
        var diff = [Float](repeating: 0, count: halfSize)
        vDSP_vsub(prevMag, 1, mag, 1, &diff, 1, vDSP_Length(halfSize))
        var zero: Float = 0
        vDSP_vthr(diff, 1, &zero, &diff, 1, vDSP_Length(halfSize))
        var sum: Float = 0
        vDSP_sve(diff, 1, &sum, vDSP_Length(halfSize))
        flux[f] = sum
        prevMag = mag
    }
    var smoothed = flux
    for i in 1..<(flux.count - 1) { smoothed[i] = (flux[i - 1] + flux[i] + flux[i + 1]) / 3 }
    var mean: Float = 0
    vDSP_meanv(smoothed, 1, &mean, vDSP_Length(smoothed.count))
    var negMean = -mean
    vDSP_vsadd(smoothed, 1, &negMean, &smoothed, 1, vDSP_Length(smoothed.count))
    let frameRate = sampleRate / Double(hopSize)
    let minLag = max(1, Int((60.0 * frameRate / 180.0).rounded()))
    let maxLag = min(smoothed.count - 1, Int((60.0 * frameRate / 60.0).rounded()))
    guard maxLag > minLag else { return nil }
    var bestLag = 0
    var bestVal: Float = -.infinity
    smoothed.withUnsafeBufferPointer { buf in
        for lag in minLag...maxLag {
            let n = smoothed.count - lag
            if n <= 0 { continue }
            var dot: Float = 0
            vDSP_dotpr(buf.baseAddress!, 1, buf.baseAddress!.advanced(by: lag), 1, &dot, vDSP_Length(n))
            if dot > bestVal { bestVal = dot; bestLag = lag }
        }
    }
    guard bestLag > 0 else { return nil }
    return 60.0 * frameRate / Double(bestLag)
}

func pearson(_ a: [Float], _ b: [Float]) -> Float {
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

func computeKey(samples: [Float], sampleRate: Double) -> String? {
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
        let pc = (Int(pitch.rounded()) % 12 + 12) % 12
        binToClass[k] = (pc + 3) % 12
    }
    var chroma = [Float](repeating: 0, count: 12)
    var frame = [Float](repeating: 0, count: frameSize)
    for f in 0..<frameCount {
        let start = f * hopSize
        samples.withUnsafeBufferPointer { src in
            window.withUnsafeBufferPointer { win in
                frame.withUnsafeMutableBufferPointer { dst in
                    vDSP_vmul(src.baseAddress!.advanced(by: start), 1, win.baseAddress!, 1, dst.baseAddress!, 1, vDSP_Length(frameSize))
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

// MARK: - main

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: legacy_analyzer <path>"); exit(1) }
let url = URL(fileURLWithPath: args[1])
let asset = AVURLAsset(url: url)

let t0 = Date()
do {
    let samples = try await readPCM(from: asset, maxSeconds: maxAnalysisSeconds)
    guard samples.count >= Int(analysisSampleRate * 5) else {
        print("STATUS=FAILED"); print("ERROR=notEnoughSamples"); exit(1)
    }
    let bpm = computeBPM(samples: samples, sampleRate: analysisSampleRate)
    let key = computeKey(samples: samples, sampleRate: analysisSampleRate)
    let elapsed = Date().timeIntervalSince(t0)
    print("STATUS=OK")
    print("LEGACY_BPM=\(String(describing: bpm))")
    print("LEGACY_KEY=\(String(describing: key))")
    print("LEGACY_ELAPSED_MS=\(Int(elapsed * 1000))")
} catch {
    print("STATUS=FAILED")
    print("ERROR=\(error)")
}
