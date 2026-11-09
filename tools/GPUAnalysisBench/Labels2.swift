#if AFTER
import AVFoundation
import Foundation
import SoundAnalysis

final class SoundClassSink: AnalysisPCMSink, @unchecked Sendable {
    final class Observer: NSObject, SNResultsObserving, @unchecked Sendable {
        let index: [String: Int]
        let vocal: [Int]
        private let lock = NSLock()
        private(set) var points: [(Double, [Float])] = []

        init(identifiers: [String]) {
            index = Dictionary(uniqueKeysWithValues: identifiers.enumerated().map { ($1, $0) })
            vocal = identifiers.enumerated().filter { VocalClassifier.labels.contains($0.element) }.map(\.offset)
        }

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            var vector = [Float](repeating: 0, count: index.count)
            for item in result.classifications {
                if let i = index[item.identifier] { vector[i] = Float(item.confidence) }
            }
            let centre = result.timeRange.start.seconds + result.timeRange.duration.seconds / 2
            lock.lock()
            points.append((centre, vector))
            lock.unlock()
        }

        func sorted() -> [(Double, [Float])] {
            lock.lock()
            defer { lock.unlock() }
            return points.sorted { $0.0 < $1.0 }
        }
    }

    let identifiers: [String]
    private let analyzer: SNAudioStreamAnalyzer
    private let observer: Observer
    private let format: AVAudioFormat
    private var position: AVAudioFramePosition = 0
    private let prefilter: DoubleBiquadCascade

    init?(sampleRate: Double = BeatTracker.sampleRate) {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { return nil }
        request.windowDuration = CMTime(seconds: 1, preferredTimescale: 1000)
        request.overlapFactor = VocalClassifier.overlapFactor
        identifiers = request.knownClassifications.sorted()
        observer = Observer(identifiers: identifiers)
        let analyzer = SNAudioStreamAnalyzer(format: format)
        do { try analyzer.add(request, withObserver: observer) } catch { return nil }
        self.analyzer = analyzer
        self.format = format
        let hp = VocalClassifier.biquad(highPass: true, cutoff: 250, sampleRate: sampleRate)
        let lp = VocalClassifier.biquad(highPass: false, cutoff: 5_000, sampleRate: sampleRate)
        guard let prefilter = DoubleBiquadCascade([hp, hp, lp, lp]) else { return nil }
        self.prefilter = prefilter
    }

    func consume(_ samples: UnsafeBufferPointer<Float>) {
        guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let out = buffer.floatChannelData?[0] else { return }
        prefilter.run(samples.baseAddress!, into: out, count: samples.count)
        buffer.frameLength = AVAudioFrameCount(samples.count)
        analyzer.analyze(buffer, atAudioFramePosition: position)
        position += AVAudioFramePosition(samples.count)
    }

    func finish() -> (curve: [Float], windows: [[Float]]) {
        analyzer.completeAnalysis()
        let all = observer.sorted()
        let hop = VocalClassifier.hopSeconds
        guard let last = all.last else { return ([], []) }
        var out = [Float](repeating: 0, count: Int(last.0 / hop) + 1)
        var filled = [Bool](repeating: false, count: out.count)
        for (t, v) in all {
            let best = observer.vocal.reduce(Float(0)) { max($0, v[$1]) }
            let i = min(out.count - 1, max(0, Int(t / hop)))
            out[i] = max(out[i], best)
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
        return (out.map { ($0 * 1000).rounded() / 1000 }, all.map(\.1))
    }
}

enum Labels2 {
    struct Labelled {
        var features: BeatTrackerFeatures
        var curve: [Float]
        var classes: [[Float]]
        var identifiers: [String]
        var mel: AnalysisMelFrames
        var timbre: [[Float]]
    }

    static func label(_ url: URL, maxSeconds: Double) async throws -> Labelled? {
        var options = AnalysisFeatureBackend.options(BeatTracker.Options(), backend: .gpu)
        options.maxSeconds = maxSeconds
        guard let mel = GPUMelSink(), let classes = SoundClassSink() else { return nil }
        let timbre = TimbreFramesSink()
        var extractor: (any BeatTrackerFeatureExtracting)?
        try await AnalysisPCMDecode.read(fileURL: url, maxSeconds: options.maxSeconds, yield: nil) { duration in
            let hop = BeatTracker.hop(forDuration: duration, options: options)
            extractor = options.makeExtractor?(hop, duration) ?? BeatTrackerFeatureExtractor(hop: hop, expectedSeconds: duration)
        } consume: { slice in
            extractor?.consume(slice)
            classes.consume(slice)
            mel.consume(slice)
            timbre.consume(slice)
        }
        guard let extractor, let melFrames = mel.finish() else { return nil }
        var features = extractor.finish()
        let (curve, windows) = classes.finish()
        features.vocalCurve = curve
        features.vocalRanges = VocalClassifier.ranges(curve)
        let frames = try await timbre.finish()
        return Labelled(features: features, curve: curve, classes: windows, identifiers: classes.identifiers, mel: melFrames, timbre: frames)
    }

    static func run(entries: [Entry], output: URL) async throws {
        let env = ProcessInfo.processInfo.environment
        let maxSeconds = Double(env["LABEL_MAX_SECONDS"] ?? "") ?? BeatTracker.maxAnalysisSeconds
        let deleteAfter = env["LABEL_DELETE_AUDIO"] == "1"
        let base = Int(env["LABEL_INDEX_BASE"] ?? "0") ?? 0
        var wroteIdentifiers = FileManager.default.fileExists(atPath: output.appendingPathComponent("classes.txt").path)
        for (offset, entry) in entries.enumerated() {
            let index = base + offset
            let file = output.appendingPathComponent(String(format: "%04d.lb2", index))
            let url = URL(fileURLWithPath: entry.path)
            defer { if deleteAfter { try? FileManager.default.removeItem(at: url) } }
            if FileManager.default.fileExists(atPath: file.path) { continue }
            let t0 = now()
            guard let l = try? await label(url, maxSeconds: maxSeconds) else { print("skip \(index) \(entry.path)"); continue }
            let result = BeatTracker.analyze(l.features, tempoPrior: nil)
            if !wroteIdentifiers {
                try l.identifiers.joined(separator: "\n").write(to: output.appendingPathComponent("classes.txt"), atomically: true, encoding: .utf8)
                wroteIdentifiers = true
            }
            let dim = l.timbre.first?.count ?? 0
            var data = Data()
            func put<T>(_ v: T) { withUnsafeBytes(of: v) { data.append(contentsOf: $0) } }
            func putArray<T>(_ v: [T]) { v.withUnsafeBytes { data.append(contentsOf: $0) } }
            func half(_ v: [Float]) -> [UInt16] { v.map { Float16($0).bitPattern } }
            data.append(contentsOf: Array("SLB2".utf8))
            put(Int32(l.mel.frames)); put(Int32(AnalysisMel.bands)); put(Int32(l.curve.count)); put(Int32(l.timbre.count)); put(Int32(dim))
            put(Int32(result.downbeats.count)); put(Int32(l.classes.count)); put(Int32(l.identifiers.count))
            put(Int64(l.mel.sampleCount)); put(l.features.analysedSeconds)
            putArray(l.mel.values)
            putArray(l.curve)
            putArray(half(l.timbre.flatMap { $0 }))
            putArray(result.downbeats)
            putArray(half(l.classes.flatMap { $0 }))
            try data.write(to: file)
            print("\(index) \(String(format: "%.1f", l.features.analysedSeconds))s curve \(l.curve.count) windows \(l.classes.count) timbre \(l.timbre.count) bars \(result.downbeats.count) \(String(format: "%.1f", now() - t0))s \(url.lastPathComponent)")
        }
    }

    static func check(entries: [Entry], limit: Int) async throws {
        let options = AnalysisFeatureBackend.options(BeatTracker.Options(), backend: .gpu)
        var same = 0, total = 0
        for entry in entries.prefix(limit) {
            let url = URL(fileURLWithPath: entry.path)
            let production = try await BeatTracker.extractFeatures(fileURL: url, options: options)
            guard let ours = try await label(url, maxSeconds: BeatTracker.maxAnalysisSeconds) else { continue }
            let a = BeatTracker.analyze(production, tempoPrior: nil), b = BeatTracker.analyze(ours.features, tempoPrior: nil)
            let equal = production.vocalCurve == ours.curve && a.downbeats == b.downbeats && a.vocalSeconds == b.vocalSeconds
            total += 1
            if equal { same += 1 }
            print("\(equal ? "same" : "DIFF") curve \(production.vocalCurve?.count ?? 0)/\(ours.curve.count) windows \(ours.classes.count) classes \(ours.identifiers.count) \(url.lastPathComponent)")
        }
        print("label check: \(same)/\(total) identical to production")
    }
}
#endif
