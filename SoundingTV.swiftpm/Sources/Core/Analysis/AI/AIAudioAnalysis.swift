import Foundation
import CryptoKit

struct AIAudioAnalysisResult: Codable, Sendable, Equatable {
    struct Span: Codable, Sendable, Equatable {
        let start: Double
        let end: Double

        var seconds: ClosedRange<TimeInterval>? { end > start ? start...end : nil }
    }

    struct Stems: Codable, Sendable, Equatable {
        let vocals: [Span]
        let drumsOnly: [Span]
        let bass: [Span]
    }

    static let version = 2
    static let minimumGridConfidence = 0.8
    static let minimumDownbeatConfidence = 0.5

    let version: Int
    let grid: BeatTrackerResult?
    let gridConfidence: Double
    let downbeatConfidence: Double
    let beatsPerBar: Int?
    let stems: Stems?

    var isGridTrusted: Bool {
        Self.trusts(gridConfidence: gridConfidence, downbeatConfidence: downbeatConfidence, beatsPerBar: beatsPerBar)
            && (grid?.downbeats.count ?? 0) >= 2
    }

    var isBeatGridTrusted: Bool {
        gridConfidence >= Self.minimumGridConfidence && beatsPerBar == 4 && (grid?.beats.count ?? 0) >= 16
    }

    static func trusts(gridConfidence: Double, downbeatConfidence: Double, beatsPerBar: Int?) -> Bool {
        gridConfidence >= minimumGridConfidence && downbeatConfidence >= minimumDownbeatConfidence && beatsPerBar == 4
    }

    func plannerGrid(phaseFrom reference: BeatTrackerResult?) -> BeatTrackerResult? {
        guard isBeatGridTrusted, let grid else { return nil }
        if isGridTrusted { return grid }
        guard let reference else { return nil }
        return grid.rephased(beatConfidence: gridConfidence, downbeats: reference.downbeats, phraseStarts: reference.phraseStarts, sectionStarts: reference.sectionStarts, bars: reference.bars)
    }
}

extension BeatTrackerResult {
    static func barPhase(beats: [Double], downbeats: [Double], beatsPerBar: Int = 4) -> (phase: Int, agreement: Double, beats: [Double], slots: [Int])? {
        guard beats.count >= beatsPerBar * 2, beatsPerBar > 0 else { return nil }
        let grid = BeatTracker.beatSlots(beats)
        guard grid.period > 0 else { return nil }
        var segment = [Int](repeating: 0, count: grid.beats.count)
        for i in grid.beats.indices.dropFirst() {
            segment[i] = segment[i - 1] + (grid.slots[i] - grid.slots[i - 1] > 2 ? 1 : 0)
        }
        var votes = [[Double]](repeating: [Double](repeating: 0, count: beatsPerBar), count: segment[segment.count - 1] + 1)
        for d in downbeats {
            let i = nearestIndex(in: grid.beats, to: d)
            guard abs(grid.beats[i] - d) <= 0.2 * grid.period else { continue }
            votes[segment[i]][grid.slots[i] % beatsPerBar] += 1
        }
        let overall = (0..<beatsPerBar).map { k in votes.reduce(0) { $0 + $1[k] } }
        let total = overall.reduce(0, +)
        guard total > 0, let best = overall.indices.max(by: { overall[$0] < overall[$1] }) else { return nil }
        var agreeing = 0.0
        var shift = [Int](repeating: 0, count: votes.count)
        for (s, v) in votes.enumerated() where v.reduce(0, +) > 0 {
            let local = v.indices.max { v[$0] < v[$1] } ?? best
            agreeing += v[local]
            shift[s] = ((best - local) % beatsPerBar + beatsPerBar + 1) % beatsPerBar - 1
        }
        let slots = grid.slots.indices.map { grid.slots[$0] + shift[segment[$0]] }
        return (best, agreeing / total, grid.beats, slots)
    }

    static func nearestIndex(in sorted: [Double], to t: Double) -> Int {
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        if lo == sorted.count { return sorted.count - 1 }
        if lo > 0, t - sorted[lo - 1] < sorted[lo] - t { return lo - 1 }
        return lo
    }

    func rephased(beatConfidence: Double, downbeats reference: [Double], phraseStarts: [Double], sectionStarts: [Double], bars: BarProfile?) -> BeatTrackerResult? {
        guard let vote = Self.barPhase(beats: beats, downbeats: reference) else { return nil }
        let beats = vote.beats
        let downbeats = beats.indices.filter { vote.slots[$0] % 4 == vote.phase }.map { beats[$0] }
        guard downbeats.count >= 2 else { return nil }
        let bar = (downbeats[downbeats.count - 1] - downbeats[0]) / Double(downbeats.count - 1)
        func barIndices(_ times: [Double]) -> [Int] {
            Array(Set(times.compactMap { t -> Int? in
                let i = Self.nearestIndex(in: downbeats, to: t)
                return abs(downbeats[i] - t) <= bar / 2 ? i : nil
            })).sorted()
        }
        let phraseBars = barIndices(phraseStarts)
        var phase = [Int](repeating: 0, count: 8)
        for i in phraseBars { phase[i % 8] += 1 }
        let offset = phraseBars.isEmpty ? 0 : phase.indices.max { phase[$0] < phase[$1] } ?? 0
        func r(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
        let phaseConfidence = r(min(beatConfidence, vote.agreement))
        var result = BeatTrackerResult(
            version: version,
            bpm: bpm,
            beats: beats,
            downbeats: downbeats,
            phraseOffsetBars: offset,
            phraseStarts: phraseBars.map { downbeats[$0] },
            sectionStarts: barIndices(sectionStarts).map { downbeats[$0] },
            tempoSegments: tempoSegments,
            confidence: phaseConfidence,
            beatConfidence: beatConfidence,
            downbeatConfidence: phaseConfidence,
            tempoClarity: tempoClarity,
            analysedSeconds: analysedSeconds,
            vocalRanges: vocalRanges
        )
        result.vocalCurve = vocalCurve
        result.parityConfidence = phaseConfidence
        result.bars = bars.flatMap { $0.remapped(from: reference, to: downbeats) }
        return result
    }
}

extension BarProfile {
    func remapped(from source: [Double], to target: [Double]) -> BarProfile? {
        guard !source.isEmpty, source.count == level.count, target.count >= 9 else { return nil }
        let map = target.map { BeatTrackerResult.nearestIndex(in: source, to: $0) }
        func pick(_ values: [Float]) -> [Float] { map.map { values[$0] } }
        var out = BarProfile(level: pick(level), density: pick(density), loop4: pick(loop4), loop8: pick(loop8))
        if let bands, bands.count == source.count * 4 {
            out.bands = map.flatMap { bands[($0 * 4)..<($0 * 4 + 4)] }
        }
        if let tonality, tonality.count == source.count { out.tonality = pick(tonality) }
        if let beats, beats.count == source.count * BarProfile.beatsPerBar {
            out.beats = map.flatMap { beats[($0 * BarProfile.beatsPerBar)..<($0 * BarProfile.beatsPerBar + BarProfile.beatsPerBar)] }
        }
        return out
    }
}

extension AnalysisEngineIdentity {
    static func aiAudio(version: Int = AIAudioAnalysisResult.version) -> AnalysisEngineIdentity {
        .init(name: "sounding.aiAudio", version: version)
    }
}

extension BeatTracker {
    static func beatSlots(_ raw: [Double]) -> (beats: [Double], slots: [Int], period: Double) {
        guard raw.count >= 3 else { return (raw, Array(raw.indices), 0) }
        let intervals = zip(raw, raw.dropFirst()).map { $1 - $0 }
        let median = intervals.sorted()[intervals.count / 2]
        let single = intervals.filter { $0 > 0.75 * median && $0 < 1.25 * median }
        let period = single.isEmpty ? median : single.reduce(0, +) / Double(single.count)
        guard period > 0 else { return (raw, Array(raw.indices), 0) }
        var beats = [raw[0]], slots = [0]
        for b in raw.dropFirst() {
            let steps = Int(((b - beats[beats.count - 1]) / period).rounded())
            guard steps >= 1 else { continue }
            beats.append(b)
            slots.append(slots[slots.count - 1] + steps)
        }
        return (beats, slots, period)
    }

    static func smoothedBeats(_ beats: [Double], slots: [Int]? = nil, radius: Int = 8) -> [Double] {
        guard beats.count > 2 * radius + 1 else { return beats }
        let slot = slots ?? Array(beats.indices)
        return beats.indices.map { i in
            let lo = max(0, i - radius), hi = min(beats.count - 1, i + radius)
            let n = Double(hi - lo + 1)
            var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
            for j in lo...hi {
                let x = Double(slot[j] - slot[i])
                sx += x; sy += beats[j]; sxx += x * x; sxy += x * beats[j]
            }
            let slope = (n * sxy - sx * sy) / max(1e-12, n * sxx - sx * sx)
            return (sy - slope * sx) / n
        }
    }

    static func imposing(
        beats rawBeats: [Double],
        downbeats rawDownbeats: [Double],
        beatConfidence: Double,
        downbeatConfidence: Double,
        on features: BeatTrackerFeatures,
        base: BeatTrackerResult
    ) -> BeatTrackerResult? {
        let grid = beatSlots(rawBeats)
        let indices = rawDownbeats.compactMap { d in grid.beats.firstIndex { abs($0 - d) < 0.001 } }
        guard grid.beats.count >= 16, indices.count >= 2 else { return nil }
        let slots = grid.slots
        let beats = smoothedBeats(grid.beats, slots: slots).map(round4)
        let downbeats = indices.map { beats[$0] }
        let phrase = estimatePhrases(beats: beats, downbeatIndices: indices, features: features, high: normalisedByMean(features.high))
        let phraseStarts = phrase.phraseBarIndices.compactMap { $0 < downbeats.count ? downbeats[$0] : nil }
        let sectionStarts = phrase.sectionBarIndices.compactMap { $0 < downbeats.count ? downbeats[$0] : nil }
        var segments: [BeatTrackerResult.TempoSegment] = []
        var index = 0
        while let next = beats.indices.first(where: { $0 > index && slots[$0] - slots[index] >= 32 }) {
            let span = beats[next] - beats[index]
            if span > 0 { segments.append(.init(start: beats[index], bpm: (60 * Double(slots[next] - slots[index]) / span * 100).rounded() / 100)) }
            index = next
        }
        let span = beats[beats.count - 1] - beats[0]
        let bpm = span > 0 ? (60 * Double(slots[slots.count - 1] - slots[0]) / span * 100).rounded() / 100 : nil
        func r(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
        var result = BeatTrackerResult(
            version: BeatTracker.version,
            bpm: bpm,
            beats: beats,
            downbeats: downbeats,
            phraseOffsetBars: phrase.offset,
            phraseStarts: phraseStarts,
            sectionStarts: sectionStarts,
            tempoSegments: segments,
            confidence: r(min(beatConfidence, downbeatConfidence)),
            beatConfidence: r(beatConfidence),
            downbeatConfidence: r(downbeatConfidence),
            tempoClarity: base.tempoClarity,
            analysedSeconds: features.analysedSeconds,
            vocalRanges: base.vocalRanges
        )
        result.vocalCurve = base.vocalCurve
        result.parityConfidence = r(downbeatConfidence)
        result.bars = BarProfile.measure(features, downbeats: downbeats)
        return result
    }
}

// MARK: - Settings

enum AIAudioSettings {
    static let enabledKey = "red.forbes.sounding.aiAudioAnalysis.enabled"

    static var isSupported: Bool {
        #if canImport(MLX) && os(macOS)
        return true
        #else
        return false
        #endif
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static var isActive: Bool {
        isSupported && isEnabled && AIModelStore.isInstalled(.beatThis)
    }

    static var stemsActive: Bool {
        isActive && AIModelStore.isInstalled(.openUnmix)
    }
}

// MARK: - Model store

enum AIModelPack: String, CaseIterable, Sendable {
    case beatThis = "beat-this-final0"
    case openUnmix = "openunmix-hq"

    struct File: Sendable {
        let name: String
        let url: URL
        let bytes: Int64
        let sha256: String
    }

    var files: [File] {
        switch self {
        case .beatThis:
            return [
                File(
                    name: "model.safetensors",
                    url: URL(string: "https://huggingface.co/safe-models/beat-this-final0/resolve/39ec64821baf38aa16fafa500a91379c16db0062/model.safetensors")!,
                    bytes: 81_029_488,
                    sha256: "f758c77ba5d862cad3718a95705964e9af55298b1fb3544c62c9d79184ea0f2e"
                )
            ]
        case .openUnmix:
            let revision = "1e9976cf6447377821e4293841124eedcc9b9823"
            let hashes = [
                "vocals": "886759bc2071cdc04904a512ace4a569797727e87d95dad621ddd43c593ef94e",
                "drums": "3bb9b60b5e0ede6afb8491fd4130e1695d5d1705eb531a6a6aedf7139629d516",
                "bass": "cc051f71388629422fdbd4aae6ecc0b9ee8d9d37f510ea5b58c5d3eef38390a7",
                "other": "7fcaea35d455d5bcf2a93a717d9a32546af81bc62e99a0e68d99747b503846ff"
            ]
            return ["vocals", "drums", "bass", "other"].map { stem in
                File(
                    name: "\(stem).safetensors",
                    url: URL(string: "https://huggingface.co/aufklarer/OpenUnmix-HQ-MLX/resolve/\(revision)/\(stem).safetensors")!,
                    bytes: 35_618_264,
                    sha256: hashes[stem]!
                )
            }
        }
    }

    var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
}

enum AIModelStoreError: Error, Equatable {
    case badResponse(Int)
    case hashMismatch(String)
    case sizeMismatch(String)
}

enum AIModelStore {
    static var root: URL {
        AppDataDirectory.folder("AIModels")
    }

    static func directory(_ pack: AIModelPack) -> URL {
        root.appendingPathComponent(pack.rawValue, isDirectory: true)
    }

    static func isInstalled(_ pack: AIModelPack) -> Bool {
        pack.files.allSatisfy { file in
            let url = directory(pack).appendingPathComponent(file.name)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            return size == file.bytes
        }
    }

    static var installedBytes: Int64 {
        AIModelPack.allCases.filter(isInstalled).reduce(0) { $0 + $1.bytes }
    }

    static var totalBytes: Int64 {
        AIModelPack.allCases.reduce(0) { $0 + $1.bytes }
    }

    static func remove() throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 22), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func install(_ pack: AIModelPack, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let folder = directory(pack)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var done: Int64 = 0
        for file in pack.files {
            let destination = folder.appendingPathComponent(file.name)
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value
            if size == file.bytes, (try? sha256(of: destination)) == file.sha256 {
                done += file.bytes
                progress(done)
                continue
            }
            let base = done
            let delegate = AIModelDownloadProgress { progress(base + $0) }
            let (temporary, response) = try await URLSession.shared.download(from: file.url, delegate: delegate)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw AIModelStoreError.badResponse(status) }
            let downloaded = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value
            guard downloaded == file.bytes else { throw AIModelStoreError.sizeMismatch(file.name) }
            guard try sha256(of: temporary) == file.sha256 else { throw AIModelStoreError.hashMismatch(file.name) }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
            done += file.bytes
            progress(done)
        }
    }
}

private final class AIModelDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let report: @Sendable (Int64) -> Void

    init(_ report: @escaping @Sendable (Int64) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        report(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

@MainActor
final class AIModelInstaller: ObservableObject {
    static let shared = AIModelInstaller()

    enum State: Equatable {
        case idle
        case downloading(Double)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var installedBytes: Int64 = AIModelStore.installedBytes
    private var task: Task<Void, Never>?

    var isInstalled: Bool { installedBytes >= AIModelStore.totalBytes }

    func installIfNeeded() {
        guard AIAudioSettings.isSupported, task == nil, !isInstalled else { return }
        let total = Double(AIModelStore.totalBytes)
        state = .downloading(0)
        task = Task { [weak self] in
            var base: Int64 = 0
            do {
                for pack in AIModelPack.allCases {
                    let offset = base
                    try await AIModelStore.install(pack) { written in
                        Task { @MainActor in self?.state = .downloading(Double(offset + written) / total) }
                    }
                    base += pack.bytes
                    await MainActor.run { self?.installedBytes = AIModelStore.installedBytes }
                    NotificationCenter.default.post(name: .aiAudioModelsDidChange, object: nil)
                }
                self?.state = .idle
            } catch is CancellationError {
                self?.state = .idle
            } catch {
                self?.state = .failed(Self.message(for: error))
            }
            self?.installedBytes = AIModelStore.installedBytes
            self?.task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }

    func delete() {
        cancel()
        try? AIModelStore.remove()
        installedBytes = AIModelStore.installedBytes
        NotificationCenter.default.post(name: .aiAudioModelsDidChange, object: nil)
    }

    private static func message(for error: Error) -> String {
        switch error {
        case AIModelStoreError.hashMismatch, AIModelStoreError.sizeMismatch:
            return "The download didn’t match the expected file."
        case AIModelStoreError.badResponse:
            return "The models couldn’t be downloaded."
        default:
            return error.localizedDescription
        }
    }
}

extension Notification.Name {
    static let aiAudioModelsDidChange = Notification.Name("red.forbes.sounding.aiAudioModelsDidChange")
}
