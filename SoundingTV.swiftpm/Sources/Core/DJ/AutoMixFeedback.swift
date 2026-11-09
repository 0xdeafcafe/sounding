import Foundation
import Observation

extension AutoMixTransitionFeatures {
    init(plan: PhantomDJEngine.Plan, outgoing: TrackFeatures, incoming: TrackFeatures) {
        let bar = outgoing.beatGrid?.barDuration ?? 2
        let exit = plan.mixPointSeconds
        let entry = plan.entrySeconds
        let window = plan.transitionSeconds
        var energy: Double?
        if let a = outgoing.energyLevel, let b = incoming.energyLevel {
            energy = Double(b - a)
        }
        var bpm: Double?
        if let a = outgoing.beatGrid?.bpm, let b = incoming.beatGrid?.bpm, a > 0, b > 0 {
            let folded = [b, b * 2, b / 2].map { abs($0 / a - 1) }.min() ?? 0
            bpm = (folded * 1000).rounded() / 10
        }
        var overlap: Double?
        if outgoing.provenance.contains(.measuredVocals), incoming.provenance.contains(.measuredVocals), window > 0 {
            var total = 0.0
            for o in outgoing.vocalRanges {
                let lo = max(o.lowerBound, exit)
                let hi = min(o.upperBound, exit + window)
                guard hi > lo else { continue }
                for i in incoming.vocalRanges {
                    let iLo = i.lowerBound - entry + exit
                    let iHi = i.upperBound - entry + exit
                    total += max(0, min(hi, iHi) - max(lo, iLo))
                }
            }
            overlap = (total * 10).rounded() / 10
        }
        self.init(
            moveType: Self.moveType(templateId: plan.templateId, move: plan.move?.kind),
            blendBars: Self.blendBucket(window / max(0.1, bar)),
            energyDelta: energy,
            bpmDistancePercent: bpm,
            keyDistance: DJMoveSupport.keySteps(outgoing, at: exit, incoming, at: entry),
            outgoingSection: "\(outgoing.section(at: exit))",
            incomingSection: "\(incoming.section(at: entry))",
            vocalOverlapSeconds: overlap
        )
    }
}

struct AutoMixAnalysisProvenance: Codable, Equatable, Sendable {
    var beatTrackerVersion: Int
    var outgoing: FeatureProvenance?
    var incoming: FeatureProvenance?
    var appBuild: String?

    init(beatTrackerVersion: Int = BeatTracker.version, outgoing: FeatureProvenance? = nil, incoming: FeatureProvenance? = nil, appBuild: String? = AutoMixAnalysisProvenance.currentBuild) {
        self.beatTrackerVersion = beatTrackerVersion
        self.outgoing = outgoing
        self.incoming = incoming
        self.appBuild = appBuild
    }

    init(outgoing: TrackFeatures?, incoming: TrackFeatures?) {
        self.init(outgoing: outgoing?.provenance, incoming: incoming?.provenance)
    }

    nonisolated static var currentBuild: String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }
}

struct AutoMixRatedTrack: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var artist: String?
    var bpm: Double?
    var camelot: String?
    var energyLevel: Int?
}

struct AutoMixRatingContext: Codable, Equatable, Sendable {
    static let currentSchema = 1

    var schema = AutoMixRatingContext.currentSchema
    var historyEntryId: UUID?
    var sessionId: UUID?
    var outgoing: AutoMixRatedTrack?
    var incoming: AutoMixRatedTrack?
    var plan: MixPlanRecord?
    var execution: MixExecutionRecord?
    var performance: [MixPerformanceMove]?
    var analysis: AutoMixAnalysisProvenance?
}

struct AutoMixRatingRecord: Codable, Equatable, Sendable {
    let date: Date
    let liked: Bool
    let features: AutoMixTransitionFeatures
    var context: AutoMixRatingContext?

    init(_ rating: AutoMixRating, context: AutoMixRatingContext? = nil) {
        date = rating.date
        liked = rating.liked
        features = rating.features
        self.context = context
    }

    var rating: AutoMixRating { AutoMixRating(date: date, liked: liked, features: features) }
}

extension MixHistoryStore {
    func ratingContext(incomingTitle: String?, offeredAt: Date, analysis: AutoMixAnalysisProvenance?) -> AutoMixRatingContext? {
        let entry = entries.last { abs($0.date.timeIntervalSince(offeredAt)) < 600 && (incomingTitle == nil || $0.incoming.title == incomingTitle) }
        guard let entry else { return analysis.map { AutoMixRatingContext(analysis: $0) } }
        func track(_ snapshot: MixTrackSnapshot) -> AutoMixRatedTrack {
            AutoMixRatedTrack(id: snapshot.id, title: snapshot.title, artist: snapshot.artist, bpm: snapshot.bpm, camelot: snapshot.camelot, energyLevel: snapshot.energyLevel)
        }
        return AutoMixRatingContext(
            historyEntryId: entry.id,
            sessionId: entry.sessionID,
            outgoing: track(entry.outgoing),
            incoming: track(entry.incoming),
            plan: entry.plan,
            execution: entry.execution,
            performance: entry.performance,
            analysis: analysis
        )
    }
}

@MainActor
@Observable
final class AutoMixFeedbackStore {
    static let shared = AutoMixFeedbackStore()

    struct Pending: Equatable, Identifiable {
        let id: UUID
        let features: AutoMixTransitionFeatures
        let incomingTitle: String?
        let expiresAt: Date
        var offeredAt: Date = Date()
        var analysis: AutoMixAnalysisProvenance?
    }

    static let offerSeconds: TimeInterval = 20
    static let storedLimit = 500

    private(set) var pending: Pending?
    private(set) var records: [AutoMixRatingRecord] = []
    private(set) var ratings: [AutoMixRating] = []
    private(set) var priors: DJLearnedPriors = .neutral

    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let journal: SoundingDataJournal<AutoMixRatingRecord>?
    @ObservationIgnored private var journalObservers: [NSObjectProtocol] = []

    init(fileURL: URL? = AutoMixFeedbackStore.defaultFileURL) {
        self.fileURL = fileURL
        if let fileURL, fileURL == Self.defaultFileURL {
            journal = SoundingDataJournal(area: .autoMixRatings)
        } else {
            journal = fileURL.map { SoundingDataJournal(directory: $0.deletingPathExtension().appendingPathExtension("journal")) }
        }
        load()
        journalObservers = journal?.observeChanges { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.reloadFromJournal() }
        } ?? []
    }

    nonisolated static func journalId(_ record: AutoMixRatingRecord) -> String {
        "\(Int64((record.date.timeIntervalSince1970 * 1000).rounded()))-\(record.liked ? 1 : 0)"
    }

    nonisolated static var defaultFileURL: URL? {
        AppDataDirectory.folder("AutoMix").appendingPathComponent("transition-ratings.json")
    }

    func offer(_ features: AutoMixTransitionFeatures, incomingTitle: String?, analysis: AutoMixAnalysisProvenance? = nil, now: Date = Date()) {
        let next = Pending(id: UUID(), features: features, incomingTitle: incomingTitle, expiresAt: now.addingTimeInterval(Self.offerSeconds), offeredAt: now, analysis: analysis ?? AutoMixAnalysisProvenance())
        pending = next
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.offerSeconds))
            guard !Task.isCancelled, let self, self.pending?.id == next.id else { return }
            self.pending = nil
        }
    }

    func dismiss() {
        expiryTask?.cancel()
        expiryTask = nil
        pending = nil
    }

    func rate(liked: Bool, now: Date = Date()) {
        guard let pending else { return }
        let context = MixHistoryStore.shared.ratingContext(incomingTitle: pending.incomingTitle, offeredAt: pending.offeredAt, analysis: pending.analysis)
        record(AutoMixRating(date: now, liked: liked, features: pending.features), context: context)
        MixHistoryStore.shared.rateLatest(liked: liked)
        dismiss()
    }

    func record(_ rating: AutoMixRating, context: AutoMixRatingContext? = nil) {
        let record = AutoMixRatingRecord(rating, context: context)
        records.append(record)
        journal?.put(Self.journalId(record), record)
        if records.count > Self.storedLimit {
            let dropped = records.prefix(records.count - Self.storedLimit)
            for old in dropped { journal?.remove(Self.journalId(old)) }
            records.removeFirst(dropped.count)
        }
        refresh()
    }

    func forget(where matches: (AutoMixRating) -> Bool) {
        let removed = records.filter { matches($0.rating) }
        guard !removed.isEmpty else { return }
        records.removeAll { matches($0.rating) }
        for old in removed { journal?.remove(Self.journalId(old)) }
        refresh()
    }

    private func refresh() {
        ratings = records.map(\.rating)
        priors = DJLearnedPriors(ratings: ratings)
    }

    #if DEBUG
    func installFixture(_ fixture: [AutoMixRating]) {
        records = fixture.map { AutoMixRatingRecord($0) }
        refresh()
    }
    #endif

    func reset() {
        records = []
        ratings = []
        priors = .neutral
        dismiss()
        journal?.clearAll()
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }

    var hasLearned: Bool { !ratings.isEmpty }

    private func load() {
        guard let journal else { return }
        if let fileURL {
            journal.migrateLegacy(file: fileURL) { data in
                ((try? JSONDecoder().decode([AutoMixRatingRecord].self, from: data)) ?? []).map { (Self.journalId($0), $0) }
            }
        }
        records = Self.ordered(journal.load())
        refresh()
    }

    private func reloadFromJournal() {
        guard let journal else { return }
        let before = records
        Task.detached(priority: .utility) { [weak self] in
            let merged = journal.load()
            await self?.applyJournal(merged, ifStill: before)
        }
    }

    private func applyJournal(_ merged: [String: AutoMixRatingRecord], ifStill before: [AutoMixRatingRecord]) {
        guard records == before else { return }
        let next = Self.ordered(merged)
        guard next != records else { return }
        records = next
        refresh()
    }

    private static func ordered(_ merged: [String: AutoMixRatingRecord]) -> [AutoMixRatingRecord] {
        Array(merged.sorted { ($0.value.date, $0.key) < ($1.value.date, $1.key) }.map(\.value).suffix(storedLimit))
    }
}
