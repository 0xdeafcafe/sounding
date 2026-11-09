import Foundation

extension CamelotKey {
    static let all: [CamelotKey] = (1...12).flatMap { position in
        [CamelotKey(wheelPosition: position, mode: .minor), CamelotKey(wheelPosition: position, mode: .major)]
    }

    private static let minorNames = ["A♭", "E♭", "B♭", "F", "C", "G", "D", "A", "E", "B", "F♯", "D♭"]
    private static let majorNames = ["B", "F♯", "D♭", "A♭", "E♭", "B♭", "F", "C", "G", "D", "A", "E"]

    var musicalName: String {
        let index = wheelPosition - 1
        return mode == .minor ? "\(Self.minorNames[index]) minor" : "\(Self.majorNames[index]) major"
    }

    var fullLabel: String { "\(label) · \(musicalName)" }
}

enum ManualTempoKey {
    static let bpmRange: ClosedRange<Double> = 40...250

    static func parseBPM(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty, let value = Double(trimmed), value.isFinite, bpmRange.contains(value) else { return nil }
        return (value * 100).rounded() / 100
    }

    static func isValidBPMText(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).isEmpty || parseBPM(text) != nil
    }

    static func format(_ bpm: Double) -> String {
        let rounded = (bpm * 100).rounded() / 100
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return rounded.formatted(.number.precision(.fractionLength(0...2)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }
}

struct ManualTempoKeyOverride: Sendable, Equatable {
    var bpm: Double?
    var key: CamelotKey?

    init(bpm: Double? = nil, key: CamelotKey? = nil) {
        self.bpm = bpm
        self.key = key
    }

    init?(_ payload: UserAnalysisCorrectionPayload?) {
        guard let payload else { return nil }
        let bpm = payload.bpm.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let key = payload.keyLabel.flatMap(CamelotKey.parse)
        guard bpm != nil || key != nil else { return nil }
        self.init(bpm: bpm, key: key)
    }

    var isEmpty: Bool { bpm == nil && key == nil }

    static func grid(_ bpm: Double, replacing grid: BeatGrid?) -> BeatGrid? {
        if let grid, grid.bpm > 0, abs(grid.bpm - bpm) / bpm < 0.002 { return grid }
        guard let base = BeatGrid.tempoOnly(bpm, barsPerPhrase: grid?.barsPerPhrase ?? 8) else { return grid }
        guard let grid else { return base }
        return BeatGrid(
            anchor: grid.firstDownbeat,
            beatPeriod: base.beatPeriod,
            barsPerPhrase: grid.barsPerPhrase,
            confidence: base.confidence
        )
    }
}

struct TapTempo: Sendable, Equatable {
    static let resetAfter: TimeInterval = 2
    static let minimumTaps = 4
    static let window = 8

    private(set) var taps: [TimeInterval] = []

    var count: Int { taps.count }

    var bpm: Double? {
        guard taps.count >= Self.minimumTaps, let first = taps.first, let last = taps.last else { return nil }
        let interval = (last - first) / Double(taps.count - 1)
        guard interval > 0 else { return nil }
        let value = (60 / interval * 10).rounded() / 10
        return ManualTempoKey.bpmRange.contains(value) ? value : nil
    }

    @discardableResult
    mutating func tap(at time: TimeInterval) -> Double? {
        if let last = taps.last, time - last > Self.resetAfter || time <= last { taps.removeAll() }
        taps.append(time)
        if taps.count > Self.window { taps.removeFirst(taps.count - Self.window) }
        return bpm
    }

    mutating func reset() { taps.removeAll() }
}

// MARK: - Gate

enum AnalysisGate: Equatable, Sendable {
    case ready
    case off
    case unsupported
    case lowPowerMode
    case tooWarm
    case lowBattery
    case needsPower
    case playing
}

struct AnalysisGateInputs: Equatable, Sendable {
    var device: DeviceClass
    var isEnabled: Bool = true
    var isLowPowerMode: Bool = false
    var isHot: Bool = false
    var batteryLevel: Float? = nil
    var isOnPower: Bool = true
    var isPlaying: Bool = false

    static let minimumBatteryLevel: Float = 0.30

    var gate: AnalysisGate {
        switch device {
        case .tv, .watch: return .unsupported
        case .phone, .pad, .mac: break
        }
        guard isEnabled else { return .off }
        if isLowPowerMode { return .lowPowerMode }
        if isHot { return .tooWarm }
        if !isOnPower, let batteryLevel, batteryLevel >= 0, batteryLevel < Self.minimumBatteryLevel { return .lowBattery }
        if device == .phone || device == .pad, !isOnPower { return .needsPower }
        if isPlaying { return .playing }
        return .ready
    }

    @MainActor
    static func current() -> AnalysisGateInputs {
        let process = ProcessInfo.processInfo
        let battery = AutomaticAnalysisEligibility.batteryStatus
        return AnalysisGateInputs(
            device: .current,
            isEnabled: AutomaticAnalysisEligibility.isEnabled,
            isLowPowerMode: process.isLowPowerModeEnabled,
            isHot: process.thermalState == .serious || process.thermalState == .critical,
            batteryLevel: battery?.level,
            isOnPower: battery?.isCharging ?? true,
            isPlaying: AutomaticAnalysisEligibility.isPlaybackActive
        )
    }
}

// MARK: - Words

struct AnalysisLibraryStatus: Equatable, Sendable {
    let message: String
    let detail: String?
}

enum AnalysisBatchPhase: Equatable, Sendable {
    case idle
    case running(done: Int, total: Int)
    case stoppedTooWarm
}

enum AnalysisStatusCopy {
    static func gate(_ gate: AnalysisGate, device: DeviceClass) -> String? {
        let name = device.displayName
        switch gate {
        case .ready: return nil
        case .off: return "Music Analysis is off on this \(name)."
        case .unsupported: return "BPM and key come from your iPhone, iPad or Mac."
        case .lowPowerMode: return "Paused: Low Power Mode is on."
        case .tooWarm: return "Paused: your \(name) is too warm."
        case .lowBattery: return "Paused until your \(name) is charging."
        case .needsPower: return "BPM and key are found when your \(name) is connected to power with Sounding open."
        case .playing: return "BPM and key are found when your \(name) isn’t playing music."
        }
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number)
    }

    static func tracks(_ value: Int) -> String {
        value == 1 ? "1 track" : "\(count(value)) tracks"
    }

    static func library(
        gate: AnalysisGate,
        device: DeviceClass,
        done: Int,
        total: Int,
        isAnalysing: Bool,
        batch: AnalysisBatchPhase
    ) -> AnalysisLibraryStatus {
        let progress = "\(count(min(done, total))) of \(tracks(total)) analysed"
        switch batch {
        case .running(let batchDone, let batchTotal):
            return AnalysisLibraryStatus(message: "Analysing… \(count(batchDone)) of \(tracks(batchTotal))", detail: nil)
        case .stoppedTooWarm:
            return AnalysisLibraryStatus(message: "Stopped: your \(device.displayName) is too warm.", detail: total > 0 ? progress : nil)
        case .idle:
            break
        }
        if gate == .off || gate == .unsupported {
            return AnalysisLibraryStatus(message: Self.gate(gate, device: device) ?? "", detail: nil)
        }
        guard total > 0 else {
            return AnalysisLibraryStatus(message: "Downloads and your own music are analysed here.", detail: nil)
        }
        if done >= total {
            return AnalysisLibraryStatus(message: total == 1 ? "1 track analysed." : "All \(tracks(total)) analysed.", detail: nil)
        }
        if isAnalysing {
            return AnalysisLibraryStatus(message: "Analysing… \(count(done)) of \(tracks(total))", detail: nil)
        }
        return AnalysisLibraryStatus(message: Self.gate(gate, device: device) ?? "Analysing soon.", detail: progress)
    }

    static func track(
        gate: AnalysisGate,
        device: DeviceClass,
        work: AnalysisWorkState?,
        isAnalysable: Bool,
        isLong: Bool
    ) -> String {
        switch work {
        case .analysing?:
            return "Analysing…"
        case .queued?:
            return Self.gate(gate, device: device) ?? "Waiting to analyse."
        case .failed?:
            return "Analysis didn’t finish. Choose Analyse Now to try again."
        case .complete?:
            return "No BPM or key found."
        case .notEligible(let reason)?:
            return reason.hasSuffix(".") ? reason : reason + "."
        case nil:
            break
        }
        if gate == .unsupported || gate == .off { return Self.gate(gate, device: device) ?? "" }
        guard isAnalysable else { return "BPM and key are found when this track is downloaded." }
        if isLong { return "Long mixes are analysed when you choose Analyse Now." }
        return Self.gate(gate, device: device) ?? "Waiting to analyse."
    }
}

// MARK: - Tracks

@MainActor
enum TrackTempoKey {
    static func isAnalysable(_ track: Track) -> Bool {
        guard DeviceClass.current != .tv, DeviceClass.current != .watch else { return false }
        return track.isLocal || DownloadManager.shared.isLocallyAvailable(track)
    }

    static func isLong(_ track: Track) -> Bool {
        track.duration > AutomaticAnalysisEligibility.longestBackgroundTrackSeconds
    }

    static func pendingMessage(for track: Track) -> String {
        AnalysisStatusCopy.track(
            gate: AnalysisLibraryProgress.shared.currentGate(),
            device: .current,
            work: AutomaticAnalysisStatus.shared.state(for: track.id),
            isAnalysable: isAnalysable(track),
            isLong: isLong(track)
        )
    }

    static func analyseNow(_ track: Track) {
        AutomaticAnalysisStatus.shared.set(.queued(position: 1), for: track.id)
        Task { _ = await AutomaticAnalysisScheduler.shared.analyseNow(track, refresh: false) }
    }

    static func save(_ track: Track, bpm: Double?, key: CamelotKey?, genre: String?) async {
        await AnalysisCache.shared.storeUserCorrection(for: track, bpm: bpm, key: key, genre: genre)
    }

    static func resetToAnalysed(_ track: Track) async {
        let genre = await AnalysisCache.shared.userCorrection(for: track)?.genre
        await AnalysisCache.shared.storeUserCorrection(for: track, bpm: nil, key: nil, genre: genre)
    }

    static func manual(for track: Track) async -> UserAnalysisCorrectionPayload? {
        await AnalysisCache.shared.userCorrection(for: track)
    }

    static func analysed(for track: Track) async -> AnalysisFeatureSummary? {
        let live = AnalysisSummaryStore.liveGenerations.filter { $0.generation.engine != .userCorrection() }
        let engines = Array(Set(live.map(\.generation.engine)))
        let rows = await AnalysisCache.shared.recallRows(forTrackIds: [track.id], scope: .engines(engines))[track.id] ?? []
        return AnalysisSummaryStore.summarise(
            rows,
            expectedDurationMillis: Int((track.duration * 1000).rounded()),
            preferred: AnalysisSummaryStore.preferredFingerprint(for: track),
            live: live
        )
    }
}

// MARK: - Library progress and Analyse All Now

@MainActor
final class AnalysisLibraryProgress: ObservableObject {
    static let shared = AnalysisLibraryProgress()

    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published private(set) var gate: AnalysisGate = .ready
    @Published private(set) var batch: AnalysisBatchPhase = .idle

    private var pending: [Track] = []
    private var cachedGate: (gate: AnalysisGate, at: Date)?
    private var observer: NSObjectProtocol?
    private var refreshTask: Task<Void, Never>?
    private var batchTask: Task<Void, Never>?
    private var watchers = 0

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: .analysisDataDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRefresh() }
        }
    }

    var isRunningAll: Bool {
        if case .running = batch { return true }
        return false
    }

    var canAnalyseAll: Bool {
        gate != .off && gate != .unsupported && total > done && !isRunningAll
    }

    func currentGate() -> AnalysisGate {
        if let cachedGate, Date().timeIntervalSince(cachedGate.at) < 15 { return cachedGate.gate }
        let value = AnalysisGateInputs.current().gate
        cachedGate = (value, Date())
        return value
    }

    func refresh() async {
        let inputs = AnalysisGateInputs.current()
        cachedGate = (inputs.gate, Date())
        if gate != inputs.gate { gate = inputs.gate }
        let tracks = Self.candidates()
        let summaries = await AnalysisSummaryStore.summaries(for: tracks)
        let missing = tracks.filter { track in
            guard let summary = summaries[track.id] else { return true }
            return summary.bpm == nil && summary.key == nil
        }
        pending = missing
        if total != tracks.count { total = tracks.count }
        let analysed = tracks.count - missing.count
        if done != analysed { done = analysed }
    }

    func analyseAll() {
        guard batchTask == nil else { return }
        batchTask = Task { [weak self] in
            await self?.runAll()
        }
    }

    func stop() {
        batchTask?.cancel()
        batchTask = nil
        batch = .idle
    }

    private func runAll() async {
        await refresh()
        let queue = pending
        guard !queue.isEmpty else {
            batchTask = nil
            return
        }
        batch = .running(done: 0, total: queue.count)
        let width = Self.batchWidth
        var finished = 0
        var index = 0
        while index < queue.count {
            if Task.isCancelled { return }
            if Self.isTooWarm {
                batch = .stoppedTooWarm
                batchTask = nil
                return
            }
            let chunk = Array(queue[index..<min(queue.count, index + width)])
            for track in chunk where AutomaticAnalysisStatus.shared.state(for: track.id) == nil {
                AutomaticAnalysisStatus.shared.set(.queued(position: 1), for: track.id)
            }
            await withTaskGroup(of: Void.self) { group in
                for track in chunk {
                    group.addTask {
                        _ = await AutomaticAnalysisScheduler.shared.analyseNow(track, refresh: false)
                    }
                }
            }
            if Task.isCancelled { return }
            index += chunk.count
            finished += chunk.count
            batch = .running(done: finished, total: queue.count)
        }
        batch = .idle
        batchTask = nil
        await refresh()
    }

    func watch() async {
        watchers += 1
        defer { watchers -= 1 }
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(10))
        }
    }

    private func scheduleRefresh() {
        guard watchers > 0 || batchTask != nil else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    private static var isTooWarm: Bool {
        let state = ProcessInfo.processInfo.thermalState
        return state == .serious || state == .critical
    }

    private static var batchWidth: Int {
        DeviceClass.current == .mac ? max(1, min(4, AnalysisLanePolicy.performanceCoreCount / 2)) : 1
    }

    static func candidates() -> [Track] {
        guard DeviceClass.current != .tv, DeviceClass.current != .watch else { return [] }
        var seen = Set<String>()
        var tracks: [Track] = []
        let downloads = DownloadManager.shared
        for entry in downloads.entries.values where entry.isDownloaded && downloads.isLocallyAvailable(trackId: entry.track.id) {
            if seen.insert(entry.track.id).inserted { tracks.append(entry.track) }
        }
        for track in LocalMusicLibrary.shared.allTracks where seen.insert(track.id).inserted {
            tracks.append(track)
        }
        return tracks
    }
}
