import Foundation
import SwiftUI

struct Waveform: Equatable, Sendable {
    let samples: [Float]
    let originalSampleCount: Int

    var isEmpty: Bool { samples.isEmpty }

    init(samples: [Float], originalSampleCount: Int? = nil) {
        self.samples = samples
        self.originalSampleCount = originalSampleCount ?? samples.count
    }

    init(rawSamples: [Int], height: Int?) {
        let peak = rawSamples.max() ?? 0
        let scale = Float(max(height ?? 0, peak, 1))
        self.samples = rawSamples.map { min(1, max(0, Float($0) / scale)) }
        self.originalSampleCount = rawSamples.count
    }

    var rmsLevel: Float {
        guard !samples.isEmpty else { return 0 }
        var sumOfSquares: Float = 0
        for sample in samples { sumOfSquares += sample * sample }
        return sqrtf(sumOfSquares / Float(samples.count))
    }

    func resampled(to count: Int) -> [Float] {
        guard count > 0 else { return [] }
        guard !samples.isEmpty else { return Array(repeating: 0, count: count) }

        let n = samples.count
        return (0..<count).map { i in
            let start = i * n / count
            let end = min(max(start + 1, (i + 1) * n / count), n)
            var peak: Float = 0
            var sum: Float = 0
            for j in start..<end {
                let sample = samples[j]
                sum += sample
                if sample > peak { peak = sample }
            }
            let mean = sum / Float(end - start)
            return peak * 0.7 + mean * 0.3
        }
    }

    func displayBars(count: Int, contrast: Float = 0.55) -> [Float] {
        let bars = resampled(to: count)
        guard contrast > 0, bars.count > 2 else { return bars }

        let order = bars.indices.sorted { bars[$0] < bars[$1] }
        var ranks = [Float](repeating: 0, count: bars.count)
        let denominator = Float(bars.count - 1)
        var i = 0
        while i < order.count {
            var j = i
            while j + 1 < order.count, bars[order[j + 1]] == bars[order[i]] { j += 1 }
            let shared = Float(i + j) / 2 / denominator
            for k in i...j { ranks[order[k]] = shared }
            i = j + 1
        }

        return zip(bars, ranks).map { bar, rank in
            min(1, max(0, bar * (1 - contrast) + rank * contrast))
        }
    }
}

enum WaveformError: Error, LocalizedError, Equatable, Sendable {
    case noWaveformURL
    case imageOnly(URL)
    case notFound(URL)
    case serverError(Int)
    case network(String)
    case malformedDocument

    var errorDescription: String? {
        switch self {
        case .noWaveformURL:      return "This track has no waveform"
        case .imageOnly:          return "Waveform is only available as an image"
        case .notFound:           return "Waveform not found"
        case .serverError(let c): return "Waveform server error: \(c)"
        case .network(let m):     return "Network error: \(m)"
        case .malformedDocument:  return "Waveform data could not be read"
        }
    }

    var isRateLimited: Bool {
        if case .serverError(429) = self { return true }
        return false
    }

    var isPermanent: Bool {
        switch self {
        case .noWaveformURL, .imageOnly, .notFound, .malformedDocument: return true
        case .serverError, .network: return false
        }
    }
}

enum WaveformState: Equatable, Sendable {
    case pending
    case loading
    case ready(Waveform)
    case failed(WaveformError)

    var waveform: Waveform? {
        if case .ready(let waveform) = self { return waveform }
        return nil
    }
}

private final class WaveformEntry {
    let result: Result<Waveform, WaveformError>

    init(_ result: Result<Waveform, WaveformError>) {
        self.result = result
    }

    var state: WaveformState {
        switch result {
        case .success(let waveform): return .ready(waveform)
        case .failure(let error):    return .failed(error)
        }
    }
}

@MainActor
final class WaveformService: ObservableObject {
    static let shared = WaveformService()

    @Published private(set) var states: [String: WaveformState] = [:]

    private let cache = NSCache<NSString, WaveformEntry>()
    private var recentReady: [String: Waveform] = [:]
    private var recentReadyOrder: [String] = []
    private static let recentReadyLimit = 8
    private var inFlight: [String: Task<Result<Waveform, WaveformError>, Never>] = [:]

    private init() {
        cache.countLimit = 200
    }

    func state(for trackId: String) -> WaveformState {
        if let waveform = recentReady[trackId] {
            return .ready(waveform)
        }
        if let entry = cache.object(forKey: trackId as NSString) {
            if case .success(let waveform) = entry.result {
                retainRecentlyReady(waveform, for: trackId)
            }
            return entry.state
        }
        return states[trackId] ?? .pending
    }

    func cached(for track: Track) -> Waveform? {
        state(for: track.id).waveform
    }

    func load(_ track: Track) {
        switch state(for: track.id) {
        case .pending:
            break
        case .loading, .ready:
            return
        case .failed(let error):
            guard !error.isPermanent else { return }
        }
        Task { [weak self] in
            _ = await self?.waveform(for: track)
        }
    }

    @discardableResult
    func waveform(for track: Track) async -> Result<Waveform, WaveformError> {
        let key = track.id

        if let waveform = recentReady[key] {
            retainRecentlyReady(waveform, for: key)
            return .success(waveform)
        }
        if let entry = cache.object(forKey: key as NSString) {
            if case .success(let waveform) = entry.result {
                retainRecentlyReady(waveform, for: key)
            }
            return entry.result
        }
        if let running = inFlight[key] {
            return await running.value
        }

        guard let url = track.waveformURL else {
            return finish(key, .failure(.noWaveformURL))
        }
        if Self.isImageWaveform(url) {
            return finish(key, .failure(.imageOnly(url)))
        }

        states[key] = .loading
        let task = Task<Result<Waveform, WaveformError>, Never> {
            await Self.fetchWithRetry(url)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil

        return finish(key, result)
    }

    #if DEBUG
    func installFixture(_ waveform: Waveform, for trackId: String) {
        finish(trackId, .success(waveform))
    }
    #endif

    func invalidate(trackId: String) {
        cache.removeObject(forKey: trackId as NSString)
        recentReady[trackId] = nil
        recentReadyOrder.removeAll { $0 == trackId }
        states[trackId] = nil
    }

    @discardableResult
    private func finish(
        _ key: String,
        _ result: Result<Waveform, WaveformError>
    ) -> Result<Waveform, WaveformError> {
        switch result {
        case .success(let waveform):
            cache.setObject(WaveformEntry(result), forKey: key as NSString)
            retainRecentlyReady(waveform, for: key)
            states[key] = nil
        case .failure(let error):
            if error.isPermanent {
                cache.setObject(WaveformEntry(result), forKey: key as NSString)
            }
            states[key] = .failed(error)
        }
        return result
    }

    private func retainRecentlyReady(_ waveform: Waveform, for key: String) {
        recentReady[key] = waveform
        recentReadyOrder.removeAll { $0 == key }
        recentReadyOrder.append(key)
        while recentReadyOrder.count > Self.recentReadyLimit {
            let evicted = recentReadyOrder.removeFirst()
            recentReady[evicted] = nil
        }
    }

    private static func isImageWaveform(_ url: URL) -> Bool {
        ["png", "jpg", "jpeg", "gif"].contains(url.pathExtension.lowercased())
    }

    private nonisolated static func fetchWithRetry(_ url: URL) async -> Result<Waveform, WaveformError> {
        var lastResult: Result<Waveform, WaveformError> = .failure(.network("Waveform request did not start"))
        let backoff = SoundCloudBackoff(base: 0.4, cap: 4)
        let retries = 2

        for attempt in 0...retries {
            let result = await fetch(url)
            lastResult = result
            switch result {
            case .success:
                return result
            case .failure(let error):
                guard !error.isPermanent, !error.isRateLimited, attempt < retries, !Task.isCancelled else {
                    return result
                }
                do {
                    try await Task.sleep(for: backoff.duration(attempt: attempt))
                } catch {
                    return result
                }
            }
        }
        return lastResult
    }

    private nonisolated static func fetch(_ url: URL) async -> Result<Waveform, WaveformError> {
        var request = URLRequest(url: url)
        request.addValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await SoundCloudGateway.shared.data(
                for: request,
                context: .init(
                    intent: .playback,
                    lane: .waveform,
                    allowsBackground: true
                )
            )
        } catch {
            return .failure(.network(error.localizedDescription))
        }

        switch response.statusCode {
        case 200..<300: break
        case 404:       return .failure(.notFound(url))
        default:        return .failure(.serverError(response.statusCode))
        }
        if let mime = response.mimeType, mime.hasPrefix("image/") {
            return .failure(.imageOnly(url))
        }

        guard let document = try? JSONDecoder().decode(WaveformDocument.self, from: data),
              !document.samples.isEmpty else {
            return .failure(.malformedDocument)
        }
        return .success(Waveform(rawSamples: document.samples, height: document.height))
    }

    private struct WaveformDocument: Decodable {
        let height: Int?
        let samples: [Int]
    }
}

struct Pulse: Equatable, Sendable {
    let position: TimeInterval
    let energy: Float
    let impact: Float
    let beatPhase: Float?

    static let idle = Pulse(position: 0, energy: 0, impact: 0, beatPhase: nil)
}

struct MusicPulseAnalysis: Equatable, Sendable {
    struct LoudnessPoint: Equatable, Sendable {
        let time: TimeInterval
        let lufs: Float
        init(time: TimeInterval, lufs: Float) {
            self.time = time
            self.lufs = lufs
        }
    }

    var beats: [TimeInterval] = []
    var bars: [TimeInterval] = []
    var sectionStarts: [TimeInterval] = []
    var beatsPerMinute: Double?
    var shortTermLoudness: [LoudnessPoint] = []

    init(
        beats: [TimeInterval] = [],
        bars: [TimeInterval] = [],
        sectionStarts: [TimeInterval] = [],
        beatsPerMinute: Double? = nil,
        shortTermLoudness: [LoudnessPoint] = []
    ) {
        self.beats = beats.sorted()
        self.bars = bars.sorted()
        self.sectionStarts = sectionStarts.sorted()
        self.beatsPerMinute = beatsPerMinute
        self.shortTermLoudness = shortTermLoudness.sorted { $0.time < $1.time }
    }

    var isEmpty: Bool {
        beats.isEmpty && bars.isEmpty && sectionStarts.isEmpty && shortTermLoudness.isEmpty
    }
}

@MainActor
final class MusicPulse {
    static let shared = MusicPulse()

    private init() {}

    private var trackId: String?
    private var envelope: [Float] = []
    private var duration: TimeInterval = 0
    private var samplesPerSecond: Double = 0
    private var quietLevel: Float = 0
    private var loudLevel: Float = 1
    private var contrastScale: Float = 0.05

    private var anchorPosition: TimeInterval = 0
    private var anchorDate: Date = .distantPast
    private var isPlaying = false

    private var analysis: MusicPulseAnalysis?

    func ingest(trackId: String?, samples: [Float], duration: TimeInterval) {
        guard self.trackId != trackId || envelope.count != samples.count else { return }

        self.trackId = trackId
        self.duration = max(0, duration)
        self.analysis = nil

        guard !samples.isEmpty, duration > 0 else {
            envelope = []
            samplesPerSecond = 0
            quietLevel = 0
            loudLevel = 1
            contrastScale = 0.05
            return
        }

        envelope = samples
        samplesPerSecond = Double(samples.count) / duration

        let sorted = samples.sorted()
        quietLevel = sorted[Int(Double(sorted.count - 1) * 0.10)]
        loudLevel = sorted[Int(Double(sorted.count - 1) * 0.90)]
        if loudLevel - quietLevel < 0.02 {
            quietLevel = max(0, loudLevel - 0.02)
        }

        let radius = max(1, Int(samplesPerSecond * 3.5))
        var runningSum: Float = 0
        var prefix = [Float](repeating: 0, count: samples.count + 1)
        for (i, s) in samples.enumerated() {
            runningSum += s
            prefix[i + 1] = runningSum
        }
        var deviationSquared: Float = 0
        for i in samples.indices {
            let lo = max(0, i - radius)
            let hi = min(samples.count, i + radius + 1)
            let mean = (prefix[hi] - prefix[lo]) / Float(hi - lo)
            let d = samples[i] - mean
            deviationSquared += d * d
        }
        contrastScale = max(0.018, sqrtf(deviationSquared / Float(samples.count)))
    }

    func anchor(position: TimeInterval, isPlaying: Bool) {
        anchorPosition = max(0, position)
        anchorDate = .now
        self.isPlaying = isPlaying
    }

    func attach(_ analysis: MusicPulseAnalysis?, for trackId: String) {
        guard self.trackId == trackId else { return }
        self.analysis = (analysis?.isEmpty ?? true) ? nil : analysis
    }

    var resting: Pulse {
        Pulse(position: anchorPosition, energy: 0, impact: 0, beatPhase: nil)
    }

    func sample(at date: Date) -> Pulse {
        let t = position(at: date)
        guard duration > 0, envelope.count >= 8 else {
            return Pulse(position: t, energy: 0, impact: 0, beatPhase: nil)
        }

        let fast = smoothed(at: t, span: 1.2, steps: 10)
        let long = smoothed(at: t, span: 7.0, steps: 12)
        let level = smoothed(at: t, span: 2.5, steps: 12)

        var energy = normalised(level)
        var impact = clamp(tanhf((fast - long) / (contrastScale * 2.5)))

        var beatPhase: Float?
        if let analysis {
            if let lufs = interpolatedLoudness(analysis.shortTermLoudness, at: t) {
                energy = clamp((lufs + 26) / 18)
            }
            if let phase = phase(inBeats: analysis.beats, at: t) {
                beatPhase = phase
                let kick = powf(1 - phase, 3)
                impact = clamp(impact * 0.55 + kick * 0.45)
            }
        }

        return Pulse(position: t, energy: clamp(energy), impact: clamp(impact), beatPhase: beatPhase)
    }

    private func position(at date: Date) -> TimeInterval {
        guard isPlaying else { return anchorPosition }
        let elapsed = max(0, date.timeIntervalSince(anchorDate))
        return min(duration, anchorPosition + elapsed)
    }

    private func interpolated(at seconds: TimeInterval) -> Float {
        let x = seconds * samplesPerSecond
        guard x > 0 else { return envelope.first ?? 0 }
        let i = Int(x)
        guard i + 1 < envelope.count else { return envelope.last ?? 0 }
        let f = Float(x - Double(i))
        return envelope[i] * (1 - f) + envelope[i + 1] * f
    }

    private func smoothed(at t: TimeInterval, span: TimeInterval, steps: Int) -> Float {
        var total: Float = 0
        var weight: Float = 0
        let divisor = Double(max(steps - 1, 1))
        for k in 0..<steps {
            let back = Double(k) / divisor
            let w = expf(-Float(back) * 3)
            total += interpolated(at: t - back * span) * w
            weight += w
        }
        return weight > 0 ? total / weight : 0
    }

    private func normalised(_ value: Float) -> Float {
        (value - quietLevel) / max(loudLevel - quietLevel, 0.02)
    }

    private func clamp(_ value: Float) -> Float { min(1, max(0, value)) }

    private func phase(inBeats beats: [TimeInterval], at t: TimeInterval) -> Float? {
        guard beats.count >= 2, t >= beats[0] else { return nil }
        var lo = 0, hi = beats.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if beats[mid] <= t { lo = mid } else { hi = mid - 1 }
        }
        guard lo + 1 < beats.count else { return nil }
        let span = beats[lo + 1] - beats[lo]
        guard span > 0.05 else { return nil }
        return Float(min(1, max(0, (t - beats[lo]) / span)))
    }

    private func interpolatedLoudness(
        _ points: [MusicPulseAnalysis.LoudnessPoint], at t: TimeInterval
    ) -> Float? {
        guard points.count >= 2, t >= points[0].time else { return nil }
        var lo = 0, hi = points.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if points[mid].time <= t { lo = mid } else { hi = mid - 1 }
        }
        guard lo + 1 < points.count else { return points[lo].lufs }
        let a = points[lo], b = points[lo + 1]
        let span = b.time - a.time
        guard span > 0 else { return a.lufs }
        let f = Float((t - a.time) / span)
        return a.lufs + (b.lufs - a.lufs) * f
    }
}
