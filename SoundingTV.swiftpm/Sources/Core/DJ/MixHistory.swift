import Combine
import Foundation
import Observation

struct MixTrackSnapshot: Codable, Equatable, Sendable {
    var track: Track
    var bpm: Double?
    var camelot: String?
    var energyLevel: Int?

    var id: String { track.id }
    var title: String { track.title }
    var artist: String { track.user.displayName }

    static func camelot(_ key: CamelotKey?) -> String? {
        key.map { "\($0.wheelPosition)\($0.mode == .minor ? "A" : "B")" }
    }
}

struct MixHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var date: Date
    var sessionID: UUID
    var outgoing: MixTrackSnapshot
    var incoming: MixTrackSnapshot
    var plan: MixPlanRecord
    var execution: MixExecutionRecord
    var performance: [MixPerformanceMove]
    var feedback: AutoMixTransitionFeatures?
    var liked: Bool?

    var title: String { "\(outgoing.title) → \(incoming.title)" }
    var moveName: String { plan.moveName }

    var ratingLabel: String? {
        guard let liked else { return nil }
        return liked ? "Nice" : "Not Great"
    }

    var symbolName: String {
        switch plan.moveKind {
        case "loopRoll", "loopMix": return "repeat"
        case "cut", "dropOnTheOne", "cutOnTheOne": return "scissors"
        case "echoOut": return "dot.radiowaves.right"
        case "dropIn": return "arrow.down.to.line"
        case "fxBuild", "breakdownExit": return "camera.filters"
        case "tempoRamp": return "speedometer"
        case "jump": return "arrow.uturn.forward"
        default: return "arrow.triangle.merge"
        }
    }
}

struct SavedMix: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var savedAt: Date
    var entry: MixHistoryEntry
}

struct SavedSet: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var savedAt: Date
    var entries: [MixHistoryEntry]

    var session: MixHistorySession { MixHistorySession(id: id, entries: entries) }
}

struct SavedMixLibrary: Codable, Equatable, Sendable {
    var mixes: [SavedMix] = []
    var sets: [SavedSet] = []

    static let limit = 100

    init(mixes: [SavedMix] = [], sets: [SavedSet] = []) {
        self.mixes = mixes
        self.sets = sets
    }

    init(data: Data) {
        self = (try? JSONDecoder().decode(SavedMixLibrary.self, from: data)) ?? SavedMixLibrary()
    }

    var encoded: Data {
        guard !mixes.isEmpty || !sets.isEmpty else { return Data() }
        return (try? JSONEncoder().encode(self)) ?? Data()
    }
}

struct MixHistorySession: Equatable, Identifiable, Sendable {
    var id: UUID
    var entries: [MixHistoryEntry]

    var date: Date { entries.first?.date ?? .distantPast }

    var tracks: [MixTrackSnapshot] {
        guard let first = entries.first else { return [] }
        return [first.outgoing] + entries.map(\.incoming)
    }

    var defaultName: String {
        let names = tracks.map(\.title)
        guard let first = names.first, let last = names.last else { return "Set" }
        return names.count > 2 ? "\(first) → … → \(last)" : "\(first) → \(last)"
    }

    var title: String {
        let count = tracks.count
        return count == 1 ? "1 track" : "\(count) tracks"
    }
}

struct MixShelfItem: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case mix(MixHistoryEntry)
        case set(MixHistorySession)
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let outgoing: Track
    let incoming: Track
    let isSaved: Bool

    init(saved: SavedMix) {
        id = "mix-\(saved.id)"
        kind = .mix(saved.entry)
        title = saved.name
        detail = saved.entry.moveName
        outgoing = saved.entry.outgoing.track
        incoming = saved.entry.incoming.track
        isSaved = true
    }

    init(recent entry: MixHistoryEntry) {
        id = "entry-\(entry.id)"
        kind = .mix(entry)
        title = entry.title
        detail = entry.moveName
        outgoing = entry.outgoing.track
        incoming = entry.incoming.track
        isSaved = false
    }

    init?(set saved: SavedSet) {
        let session = saved.session
        guard let first = session.tracks.first, let last = session.tracks.last else { return nil }
        id = "set-\(saved.id)"
        kind = .set(session)
        title = saved.name
        detail = "Set · \(session.title)"
        outgoing = first.track
        incoming = last.track
        isSaved = true
    }
}

// MARK: - Overview layout

struct MixSetLayout: Equatable, Sendable {
    struct Segment: Equatable, Sendable, Identifiable {
        var index: Int
        var track: MixTrackSnapshot
        var setStart: TimeInterval
        var setEnd: TimeInterval
        var sourceStart: TimeInterval
        var sourceEnd: TimeInterval

        var id: Int { index }
        var length: TimeInterval { setEnd - setStart }
    }

    struct Blend: Equatable, Sendable, Identifiable {
        var index: Int
        var entry: MixHistoryEntry
        var setStart: TimeInterval
        var setEnd: TimeInterval

        var id: UUID { entry.id }
    }

    struct Marker: Equatable, Sendable, Identifiable {
        var segment: Int
        var move: MixPerformanceMove
        var setTime: TimeInterval

        var id: String { "\(segment)-\(move.id)" }
    }

    var segments: [Segment]
    var blends: [Blend]
    var markers: [Marker]
    var duration: TimeInterval

    init(session: MixHistorySession) {
        var segments: [Segment] = []
        var blends: [Blend] = []
        var markers: [Marker] = []
        var cursor: TimeInterval = 0
        let entries = session.entries
        let tracks = session.tracks
        for (index, track) in tracks.enumerated() {
            let sourceStart = index == 0 ? 0 : entries[index - 1].execution.entrySeconds
            let setStart = cursor
            let sourceEnd: TimeInterval
            if index < entries.count {
                let entry = entries[index]
                let exit = max(sourceStart, entry.execution.startSourceSeconds)
                let window = max(0, entry.execution.windowSeconds)
                let blendStart = setStart + (exit - sourceStart)
                blends.append(Blend(index: index, entry: entry, setStart: blendStart, setEnd: blendStart + window))
                for move in entry.performance where move.startSeconds >= sourceStart && move.startSeconds <= exit {
                    markers.append(Marker(segment: index, move: move, setTime: setStart + move.startSeconds - sourceStart))
                }
                sourceEnd = exit + window
                cursor = blendStart
            } else {
                sourceEnd = max(sourceStart, track.track.duration)
            }
            segments.append(Segment(
                index: index,
                track: track,
                setStart: setStart,
                setEnd: setStart + (sourceEnd - sourceStart),
                sourceStart: sourceStart,
                sourceEnd: sourceEnd
            ))
        }
        self.segments = segments
        self.blends = blends
        self.markers = markers
        self.duration = segments.map(\.setEnd).max() ?? 0
    }

    func segment(at time: TimeInterval) -> Segment? {
        segments.last { $0.setStart <= time } ?? segments.first
    }

    func transitionIndex(at time: TimeInterval) -> Int? {
        guard !blends.isEmpty else { return nil }
        if let blend = blends.last(where: { $0.setStart <= time + 1 }) { return blend.index }
        return 0
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Store

@MainActor
@Observable
final class MixHistoryStore {
    static let shared = MixHistoryStore()

    static let storedLimit = 500
    static let sessionGap: TimeInterval = 30 * 60

    private(set) var entries: [MixHistoryEntry] = []
    private(set) var library: SavedMixLibrary

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let journal: SoundingDataJournal<MixHistoryEntry>?
    @ObservationIgnored private var journalObservers: [NSObjectProtocol] = []
    @ObservationIgnored private let persistLibrary: (SavedMixLibrary) -> Void
    @ObservationIgnored private var libraryUpdates: AnyCancellable?

    init(
        fileURL: URL? = MixHistoryStore.defaultFileURL,
        library: SavedMixLibrary? = nil,
        persistLibrary: ((SavedMixLibrary) -> Void)? = nil,
        libraryUpdates: AnyPublisher<SavedMixLibrary, Never>? = nil
    ) {
        self.fileURL = fileURL
        if let fileURL, fileURL == Self.defaultFileURL {
            journal = SoundingDataJournal(area: .mixHistory)
        } else {
            journal = fileURL.map { SoundingDataJournal(directory: $0.deletingPathExtension().appendingPathExtension("journal")) }
        }
        let usesSettings = library == nil && persistLibrary == nil
        self.library = library ?? (usesSettings ? SavedMixLibrary(data: SettingsStore.shared.savedMixLibrary) : SavedMixLibrary())
        self.persistLibrary = persistLibrary ?? (usesSettings ? { SettingsStore.shared.setSavedMixLibrary($0.encoded) } : { _ in })
        let updates = libraryUpdates ?? (usesSettings ? SettingsStore.shared.$savedMixLibrary.map(SavedMixLibrary.init(data:)).eraseToAnyPublisher() : nil)
        self.libraryUpdates = updates?
            .removeDuplicates()
            .sink { [weak self] value in
                MainActor.assumeIsolated {
                    guard let self, self.library != value else { return }
                    self.library = value
                }
            }
        load()
        journalObservers = journal?.observeChanges { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.reloadFromJournal() }
        } ?? []
        #if DEBUG
        if fileURL == Self.defaultFileURL, ProcessInfo.processInfo.environment["SOUNDING_TV_MIX_HISTORY_FIXTURE"] != nil {
            installFixture()
        }
        #endif
    }

    nonisolated static var defaultFileURL: URL? {
        AppDataDirectory.folder("AutoMix").appendingPathComponent("mix-history.json")
    }

    var latest: MixHistoryEntry? { entries.last }

    var recent: [MixHistoryEntry] { entries.reversed() }

    var sessions: [MixHistorySession] {
        var order: [UUID] = []
        var grouped: [UUID: [MixHistoryEntry]] = [:]
        for entry in entries {
            if grouped[entry.sessionID] == nil { order.append(entry.sessionID) }
            grouped[entry.sessionID, default: []].append(entry)
        }
        return order.reversed().map { MixHistorySession(id: $0, entries: grouped[$0] ?? []) }
    }

    func session(for id: UUID) -> MixHistorySession? {
        sessions.first { $0.id == id }
    }

    var isEmpty: Bool { entries.isEmpty && library.mixes.isEmpty && library.sets.isEmpty }

    var collectedCount: Int { library.sets.count + library.mixes.count + entries.filter { !isSaved($0) }.count }

    func shelfItems(limit: Int) -> [MixShelfItem] {
        var items = library.sets.compactMap { MixShelfItem(set: $0) }
        items += library.mixes.map(MixShelfItem.init(saved:))
        if items.count < limit {
            let saved = Set(library.mixes.map(\.entry.id))
            items += recent.lazy.filter { !saved.contains($0.id) }.prefix(limit - items.count).map(MixShelfItem.init(recent:))
        }
        return Array(items.prefix(limit))
    }

    func sessionID(continuing outgoingId: String, at date: Date) -> UUID {
        guard let last = entries.last,
              last.incoming.id == outgoingId,
              date.timeIntervalSince(last.date) < Self.sessionGap + last.incoming.track.duration else { return UUID() }
        return last.sessionID
    }

    @discardableResult
    func record(
        outgoing: MixTrackSnapshot,
        incoming: MixTrackSnapshot,
        plan: MixPlanRecord,
        execution: MixExecutionRecord,
        performance: [MixPerformanceMove] = [],
        feedback: AutoMixTransitionFeatures? = nil,
        date: Date = Date()
    ) -> MixHistoryEntry {
        var outgoing = outgoing
        if let last = entries.last, last.incoming.id == outgoing.id {
            outgoing.bpm = outgoing.bpm ?? last.incoming.bpm
            outgoing.camelot = outgoing.camelot ?? last.incoming.camelot
            outgoing.energyLevel = outgoing.energyLevel ?? last.incoming.energyLevel
        }
        let entry = MixHistoryEntry(
            id: UUID(),
            date: date,
            sessionID: sessionID(continuing: outgoing.id, at: date),
            outgoing: outgoing,
            incoming: incoming,
            plan: plan,
            execution: execution,
            performance: performance,
            feedback: feedback,
            liked: nil
        )
        entries.append(entry)
        journal?.put(entry.id.uuidString, entry)
        if entries.count > Self.storedLimit {
            let dropped = entries.prefix(entries.count - Self.storedLimit)
            for old in dropped { journal?.remove(old.id.uuidString) }
            entries.removeFirst(dropped.count)
        }
        return entry
    }

    func rateLatest(liked: Bool) {
        guard let index = entries.indices.last else { return }
        entries[index].liked = liked
        journal?.put(entries[index].id.uuidString, entries[index])
    }

    func entry(for id: UUID) -> MixHistoryEntry? {
        entries.first { $0.id == id }
            ?? library.mixes.first { $0.entry.id == id }?.entry
            ?? library.sets.lazy.flatMap(\.entries).first { $0.id == id }
    }

    func isSaved(_ entry: MixHistoryEntry) -> Bool {
        library.mixes.contains { $0.entry.id == entry.id }
    }

    func isSaved(session: MixHistorySession) -> Bool {
        library.sets.contains { $0.id == session.id }
    }

    @discardableResult
    func save(_ entry: MixHistoryEntry, name: String? = nil, now: Date = Date()) -> SavedMix {
        if let existing = library.mixes.first(where: { $0.entry.id == entry.id }) { return existing }
        let mix = SavedMix(id: UUID(), name: Self.clean(name) ?? entry.title, savedAt: now, entry: entry)
        var next = library
        next.mixes.insert(mix, at: 0)
        if next.mixes.count > SavedMixLibrary.limit { next.mixes.removeLast(next.mixes.count - SavedMixLibrary.limit) }
        adopt(next)
        return mix
    }

    @discardableResult
    func saveLatest() -> SavedMix? {
        guard let latest else { return nil }
        return save(latest)
    }

    @discardableResult
    func save(session: MixHistorySession, name: String? = nil, now: Date = Date()) -> SavedSet {
        if let existing = library.sets.first(where: { $0.id == session.id }) { return existing }
        let set = SavedSet(id: session.id, name: Self.clean(name) ?? session.defaultName, savedAt: now, entries: session.entries)
        var next = library
        next.sets.insert(set, at: 0)
        if next.sets.count > SavedMixLibrary.limit { next.sets.removeLast(next.sets.count - SavedMixLibrary.limit) }
        adopt(next)
        return set
    }

    func rename(mix id: UUID, to name: String) {
        guard let index = library.mixes.firstIndex(where: { $0.id == id }), let name = Self.clean(name) else { return }
        var next = library
        next.mixes[index].name = name
        adopt(next)
    }

    func rename(set id: UUID, to name: String) {
        guard let index = library.sets.firstIndex(where: { $0.id == id }), let name = Self.clean(name) else { return }
        var next = library
        next.sets[index].name = name
        adopt(next)
    }

    func delete(mix id: UUID) {
        var next = library
        next.mixes.removeAll { $0.id == id }
        adopt(next)
    }

    func delete(set id: UUID) {
        var next = library
        next.sets.removeAll { $0.id == id }
        adopt(next)
    }

    func clearHistory() {
        entries = []
        journal?.clearAll()
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func adopt(_ next: SavedMixLibrary) {
        guard next != library else { return }
        library = next
        persistLibrary(next)
    }

    private static func clean(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func load() {
        guard let journal else { return }
        if let fileURL {
            journal.migrateLegacy(file: fileURL) { data in
                ((try? JSONDecoder().decode([MixHistoryEntry].self, from: data)) ?? []).map { ($0.id.uuidString, $0) }
            }
        }
        entries = Self.ordered(journal.load())
    }

    private func reloadFromJournal() {
        guard let journal else { return }
        let before = entries
        Task.detached(priority: .utility) { [weak self] in
            let merged = journal.load()
            await self?.applyJournal(merged, ifStill: before)
        }
    }

    private func applyJournal(_ merged: [String: MixHistoryEntry], ifStill before: [MixHistoryEntry]) {
        guard entries == before else { return }
        let next = Self.ordered(merged)
        if next != entries { entries = next }
    }

    static func ordered(_ merged: [String: MixHistoryEntry]) -> [MixHistoryEntry] {
        Array(merged.values.sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }.suffix(storedLimit))
    }

    #if DEBUG
    func installFixture() {
        entries = Self.fixtureEntries()
        if ProcessInfo.processInfo.environment["SOUNDING_TV_MIX_HISTORY_FIXTURE"] == "saved", let first = entries.first {
            library = SavedMixLibrary(
                mixes: [SavedMix(id: UUID(), name: first.title, savedAt: first.date, entry: first)],
                sets: [SavedSet(id: first.sessionID, name: "Friday warm-up", savedAt: first.date, entries: entries)]
            )
        }
    }
    #endif
}

// MARK: - Plan conversion

extension MixPlanRecord {
    init(_ plan: PhantomDJEngine.Plan) {
        self.init(
            mixPointSeconds: plan.mixPointSeconds,
            transitionSeconds: plan.transitionSeconds,
            outroShape: Self.name(of: plan.outroShape),
            accent: plan.accent,
            reasoning: plan.reasoning,
            entrySeconds: plan.entrySeconds,
            bassSwapAtSeconds: plan.bassSwapAtSeconds,
            bassSwapSeconds: plan.bassSwapSeconds,
            incomingRateRatio: plan.incomingRateRatio,
            incomingTrackId: plan.incomingTrackId,
            profileId: plan.profileId,
            templateId: plan.templateId,
            stages: plan.stages,
            outgoingBeatGrid: plan.outgoingBeatGrid,
            incomingBeatGrid: plan.incomingBeatGrid,
            move: plan.move,
            incomingTitle: plan.incomingTitle,
            incomingMidCutDecibels: plan.incomingMidCutDecibels
        )
    }

    var phantomPlan: PhantomDJEngine.Plan {
        var plan = PhantomDJEngine.Plan(
            mixPointSeconds: mixPointSeconds,
            transitionSeconds: transitionSeconds,
            outroShape: Self.shape(named: outroShape),
            accent: accent,
            reasoning: reasoning,
            entrySeconds: entrySeconds,
            bassSwapAtSeconds: bassSwapAtSeconds,
            bassSwapSeconds: bassSwapSeconds,
            incomingRateRatio: incomingRateRatio,
            incomingTrackId: incomingTrackId,
            profileId: profileId,
            templateId: templateId,
            stages: stages,
            outgoingBeatGrid: outgoingBeatGrid,
            incomingBeatGrid: incomingBeatGrid,
            move: move,
            incomingTitle: incomingTitle
        )
        plan.incomingMidCutDecibels = incomingMidCutDecibels
        return plan
    }

    private static func name(of shape: PhantomDJEngine.OutroShape) -> String {
        switch shape {
        case .breakdown: return "breakdown"
        case .fadeToSilence: return "fadeToSilence"
        case .hardStop: return "hardStop"
        case .unknown: return "unknown"
        }
    }

    private static func shape(named name: String) -> PhantomDJEngine.OutroShape {
        switch name {
        case "breakdown": return .breakdown
        case "fadeToSilence": return .fadeToSilence
        case "hardStop": return .hardStop
        default: return .unknown
        }
    }
}

extension MixTrackSnapshot {
    init(_ track: Track, features: TrackFeatures?, grid: BeatGrid?, at seconds: TimeInterval) {
        self.init(
            track: track,
            bpm: (grid ?? features?.beatGrid).map(\.bpm).flatMap { $0 > 0 ? $0 : nil },
            camelot: Self.camelot(features?.key(at: seconds)),
            energyLevel: features?.energyLevel
        )
    }
}

// MARK: - Live view model

extension MixHistoryEntry {
    @MainActor
    func liveState(now: Date = Date()) -> AutoMixLiveState {
        let bar = plan.barSeconds
        let move = plan.move
        let lengthBars = plan.lengthBars
        let swapBar = move == nil ? plan.bassSwapAtSeconds / max(0.1, bar) : nil
        let shape = AutoMixLive.phases(for: move, lengthBars: lengthBars, bassSwapBar: swapBar)
        let loop = plan.loopRegions.first
        let mid = Double(lengthBars) / 2
        let outGrid = plan.outgoingBeatGrid
        let inGrid = plan.incomingBeatGrid
        let outgoingDeck = AutoMixLiveState.Deck(
            trackId: outgoing.id,
            title: outgoing.title,
            positionSeconds: execution.startSourceSeconds + mid * bar,
            durationSeconds: outgoing.track.duration,
            rate: execution.outgoingRate,
            isPlaying: false,
            beatSeconds: outGrid?.beatPeriod,
            downbeatSeconds: outGrid?.firstDownbeat,
            loopStartSeconds: loop?.lowerBound,
            loopLengthSeconds: loop.map { $0.upperBound - $0.lowerBound }
        )
        let incomingDeck = AutoMixLiveState.Deck(
            trackId: incoming.id,
            title: incoming.title,
            positionSeconds: execution.entrySeconds + mid * (inGrid?.barDuration ?? bar),
            durationSeconds: incoming.track.duration,
            rate: execution.incomingRate,
            isPlaying: false,
            beatSeconds: inGrid?.beatPeriod,
            downbeatSeconds: inGrid?.firstDownbeat
        )
        return AutoMixLiveState(
            stage: .finished,
            moveKind: move?.kind.rawValue ?? plan.moveKind,
            moveName: plan.moveName,
            headline: move?.headline(into: incoming.title) ?? "\(plan.moveName) into \(incoming.title)",
            incomingTitle: incoming.title,
            incomingArtist: incoming.artist,
            incomingTrackId: incoming.id,
            why: nil,
            startsAt: now.addingTimeInterval(-Double(lengthBars) * bar),
            barSeconds: bar,
            landingBar: move?.landingBar ?? 0,
            lengthBars: lengthBars,
            phases: shape.phases,
            riserStartBar: shape.riserStart,
            crossfade: 0.5,
            outgoing: outgoingDeck,
            incoming: incomingDeck,
            anchoredAt: now,
            isPlaying: false,
            recap: nil,
            outgoingTitle: outgoing.title,
            rating: ratingLabel.map { AutoMixLiveState.Rating(score: liked == true ? 1 : 0, label: $0) }
        )
    }
}
