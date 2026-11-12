import Foundation
import Observation
import SwiftUI

struct DJPlanLive: Equatable, Sendable {
    struct Deck: Equatable, Sendable {
        var deck: MixEngine.Deck
        var title: String
        var remaining: TimeInterval?
    }

    var from: Deck
    var to: Deck?
    var step: String?
    var nextStartsIn: TimeInterval?
}

protocol DJPlanPlanning: Sendable {
    func plan(from outgoing: DJPlanTrack, to incoming: DJPlanTrack, move: MixMove.Kind?) async -> MixPlanRecord?
}

@MainActor
protocol DJPlanHeadphonePreview: AnyObject {
    var isAvailable: Bool { get }
    var isPreviewing: Bool { get }
    func preview(_ plan: MixPlanRecord, outgoing: DJPlanTrack, incoming: DJPlanTrack)
    func stopPreview()
}

@MainActor
final class DJPlanNoHeadphones: DJPlanHeadphonePreview {
    var isAvailable: Bool { false }
    var isPreviewing: Bool { false }
    func preview(_ plan: MixPlanRecord, outgoing: DJPlanTrack, incoming: DJPlanTrack) {}
    func stopPreview() {}
}

@MainActor
struct DJPlanActions {
    var extend: (() -> Void)?
    var mixNow: (() -> Void)?
    var takeOverAll: (() -> Void)?
    var skip: ((DJPlanTrack) -> Void)?
    var reorder: (([DJPlanTrack]) -> Void)?
    var force: (String, MixPlanRecord?) -> Void = { outgoingId, plan in
        PlayerService.shared.djDirector.forcedPlans[outgoingId] = plan?.phantomPlan
    }
}

struct DJPlanDirectorPlanner: DJPlanPlanning {
    let tracks: [String: Track]

    func plan(from outgoing: DJPlanTrack, to incoming: DJPlanTrack, move: MixMove.Kind?) async -> MixPlanRecord? {
        guard let a = tracks[outgoing.id], let b = tracks[incoming.id] else { return nil }
        let profile = await MainActor.run { PlayerService.shared.djProfile } ?? .automaticDJ
        guard let plan = await DJSessionDirector.computePhantomPlan(
            for: a, candidates: [b], profile: profile, history: .empty, legacyAnalyses: [:], userCues: [:]
        ) else { return nil }
        var record = MixPlanRecord(plan)
        record.incomingTrackId = b.id
        record.incomingTitle = b.title
        guard let move else { return record }
        return DJPlanMoves.reshape(record, to: move) ?? record
    }

    static func describe(_ track: Track) async -> DJPlanTrack {
        var described = DJPlanTrack(features: await DJSessionDirector.planningFeatures(for: track))
        described.title = track.title
        described.artist = track.user.displayName
        return described
    }
}

#if DEBUG
struct DJPlanFixturePlanner: DJPlanPlanning {
    func plan(from outgoing: DJPlanTrack, to incoming: DJPlanTrack, move: MixMove.Kind?) async -> MixPlanRecord? {
        let record = DJPlanFixture.plan(from: outgoing, to: incoming)
        guard let move else { return record }
        return DJPlanMoves.reshape(record, to: move)
    }
}
#endif

@MainActor
@Observable
final class DJPlanModel {
    var crate: DJPlanCrate
    var live: DJPlanLive?
    var selectedKey: DJPlanTransitionKey?
    var decks: [String: MixEngine.Deck]
    var played: [String: Date]
    private(set) var plans: [String: MixPlanRecord] = [:]
    private(set) var replans: Set<DJPlanTransitionKey> = []
    private(set) var snapNote: (key: DJPlanTransitionKey, note: DJPlanSnapNote)?
    var refusal: String?
    var waveforms: [String: [Float]] = [:]

    @ObservationIgnored let planner: DJPlanPlanning
    @ObservationIgnored let store: DJPlanEditStore
    @ObservationIgnored let headphones: DJPlanHeadphonePreview
    @ObservationIgnored var actions: DJPlanActions

    init(
        crate: DJPlanCrate,
        live: DJPlanLive? = nil,
        decks: [String: MixEngine.Deck] = [:],
        played: [String: Date] = [:],
        planner: DJPlanPlanning,
        store: DJPlanEditStore = .shared,
        headphones: DJPlanHeadphonePreview = DJPlanNoHeadphones(),
        actions: DJPlanActions = DJPlanActions()
    ) {
        self.crate = crate
        self.live = live
        self.decks = decks
        self.played = played
        self.planner = planner
        self.store = store
        self.headphones = headphones
        self.actions = actions
        selectedKey = crate.joins.indices.contains(max(0, crate.lockedCount - 1)) ? crate.joins[max(0, crate.lockedCount - 1)] : crate.joins.first
    }

    // MARK: Crate

    var liveJoinIndex: Int? { crate.lockedCount >= 2 ? crate.lockedCount - 2 : nil }

    func joinState(_ index: Int) -> JoinState {
        guard let live = liveJoinIndex else { return .upcoming }
        if index < live { return .played }
        if index == live { return .live }
        return .upcoming
    }

    enum JoinState {
        case played
        case live
        case upcoming
    }

    func track(_ id: String) -> DJPlanTrack? {
        crate.tracks.first { $0.id == id }
    }

    func status(for index: Int) -> String {
        let track = crate.tracks[index]
        if let progress = track.analysisProgress { return "Analysing · \(Int((progress * 100).rounded()))%" }
        if let date = played[track.id], index < crate.lockedCount - 2 {
            return "Played \(date.formatted(date: .omitted, time: .shortened))"
        }
        if index == crate.lockedCount - 2 { return "On air" }
        if index == crate.lockedCount - 1 { return "Mixing in" }
        if index == crate.lockedCount, let deck = decks[track.id] { return "Loads on \(deck.label)" }
        return track.artist
    }

    func load() async {
        for key in crate.joins where plans[key.id] == nil {
            await replan(key)
        }
        reconcileSelected()
    }

    private func replan(_ key: DJPlanTransitionKey) async {
        guard let outgoing = track(key.outgoingId), let incoming = track(key.incomingId) else { return }
        let move = store.record(for: key).edit.moveKind
        if let plan = await planner.plan(from: outgoing, to: incoming, move: move) {
            plans[key.id] = plan
        }
        pushForcedPlan(key)
    }

    func move(from source: Int, to destination: Int) {
        switch crate.move(from: source, to: destination) {
        case .success(let joins):
            replans = joins
            refusal = nil
            actions.reorder?(crate.tracks)
            Task {
                for key in joins { plans[key.id] = nil; await replan(key) }
            }
        case .failure(let reason):
            refusal = reason.message
        }
    }

    // MARK: Selection

    func timeline(for key: DJPlanTransitionKey) -> DJPlanTimeline? {
        guard let outgoing = track(key.outgoingId), let incoming = track(key.incomingId), let plan = plans[key.id] else { return nil }
        return DJPlanTimeline(outgoing: outgoing, incoming: incoming, auto: plan, edit: store.record(for: key).edit)
    }

    var selectedTimeline: DJPlanTimeline? {
        selectedKey.flatMap(timeline(for:))
    }

    var selectedRecord: DJPlanEditRecord {
        selectedKey.map(store.record(for:)) ?? DJPlanEditRecord()
    }

    var selectedIsEditable: Bool {
        guard let key = selectedKey, let index = crate.joins.firstIndex(of: key) else { return false }
        return joinState(index) == .upcoming
    }

    func select(_ key: DJPlanTransitionKey) {
        selectedKey = key
        refusal = nil
        reconcileSelected()
    }

    private func reconcileSelected() {
        guard let key = selectedKey, let timeline = timeline(for: key) else { return }
        let result = timeline.reconciling(timeline.edit)
        guard !result.notes.isEmpty else { return }
        store.update(key) { $0.apply(result.edit) }
        snapNote = result.notes.first.map { (key, $0) }
        pushForcedPlan(key)
    }

    // MARK: Editing

    func propose(_ id: DJPlanPointID, to bar: Double, free: Bool) -> DJPlanDecision {
        guard selectedIsEditable, let timeline = selectedTimeline else { return .refused("Already playing") }
        return timeline.propose(id, to: bar, free: free)
    }

    func commit(_ id: DJPlanPointID, to bar: Double, free: Bool) {
        guard let key = selectedKey, let timeline = selectedTimeline else { return }
        switch propose(id, to: bar, free: free) {
        case .accepted(let snapped, let note):
            let next = timeline.applying(id, bar: snapped).edit
            store.update(key) { $0.apply(next) }
            refusal = note
            pushForcedPlan(key)
        case .refused(let reason):
            refusal = reason
        }
    }

    func choose(move kind: MixMove.Kind) {
        guard let key = selectedKey, selectedIsEditable, let timeline = selectedTimeline else { return }
        let autoKind = store.record(for: key).edit.moveKind == nil ? timeline.moveKind : nil
        var next = DJPlanEdit()
        next.moveKind = kind == autoKind ? nil : kind
        store.update(key) { $0.apply(next) }
        plans[key.id] = nil
        Task { await replan(key) }
    }

    func undo() {
        guard let key = selectedKey else { return }
        let before = store.record(for: key).edit.moveKind
        store.update(key) { $0.undoLast() }
        afterHistoryChange(key, movedFrom: before)
    }

    func redo() {
        guard let key = selectedKey else { return }
        let before = store.record(for: key).edit.moveKind
        store.update(key) { $0.redoLast() }
        afterHistoryChange(key, movedFrom: before)
    }

    func revert() {
        guard let key = selectedKey else { return }
        let before = store.record(for: key).edit.moveKind
        store.update(key) { $0.revert() }
        afterHistoryChange(key, movedFrom: before)
    }

    func undoSnap() {
        guard let snap = snapNote else { return }
        store.update(snap.key) { $0.undoLast() }
        snapNote = nil
        pushForcedPlan(snap.key)
    }

    func dismissSnap() {
        snapNote = nil
    }

    private func afterHistoryChange(_ key: DJPlanTransitionKey, movedFrom before: MixMove.Kind?) {
        refusal = nil
        snapNote = nil
        if store.record(for: key).edit.moveKind != before {
            plans[key.id] = nil
            Task { await replan(key) }
        } else {
            pushForcedPlan(key)
        }
    }

    private func pushForcedPlan(_ key: DJPlanTransitionKey) {
        guard let timeline = timeline(for: key) else { return }
        actions.force(key.outgoingId, timeline.edit.isEmpty ? nil : timeline.forcedPlan)
    }

    func skip() {
        guard let key = selectedKey, let incoming = track(key.incomingId) else { return }
        actions.skip?(incoming)
    }

    func togglePreview() {
        guard let timeline = selectedTimeline else { return }
        if headphones.isPreviewing {
            headphones.stopPreview()
        } else {
            headphones.preview(timeline.forcedPlan, outgoing: timeline.outgoing, incoming: timeline.incoming)
        }
    }

    // MARK: Copy

    func deck(for id: String) -> MixEngine.Deck? {
        decks[id]
    }

    func joinLabel(_ index: Int) -> (text: String, warning: Bool) {
        let key = crate.joins[index]
        let edited = !store.record(for: key).edit.isEmpty
        if replans.contains(key) {
            return ("Replans · \(track(key.outgoingId)?.title ?? "") → \(track(key.incomingId)?.title ?? "")", false)
        }
        guard let plan = plans[key.id] else { return ("Planning…", false) }
        if let incoming = track(key.incomingId), incoming.isAnalysing { return ("Still analysing", true) }
        let name = plan.moveName
        switch joinState(index) {
        case .played: return ("\(name) · \(plan.lengthBars) bars · played", false)
        case .live: return ("\(name) · \(plan.lengthBars) · live", false)
        case .upcoming:
            if let warning = warning(for: key) { return ("\(warning) · \(name.lowercased())", true) }
            var parts = ["\(name) · \(timeline(for: key)?.lengthBars ?? plan.lengthBars)"]
            if index == crate.lockedCount - 1, let starts = live?.nextStartsIn { parts.append("in \(DJPlanFormat.time(starts))") }
            if edited { parts.append("edited") }
            return (parts.joined(separator: " · "), false)
        }
    }

    func warning(for key: DJPlanTransitionKey) -> String? {
        guard let timeline = timeline(for: key) else { return nil }
        if let steps = timeline.keySteps, steps > timeline.maxCamelotSteps { return "Keys \(steps) apart" }
        if let failed = timeline.checks.first(where: { !$0.passed }) { return failed.title }
        return nil
    }

    func editSummary(_ timeline: DJPlanTimeline) -> String {
        var parts = ["\(timeline.auto.moveName) · \(timeline.lengthBars) bars"]
        if let a = timeline.outgoing.key, let b = timeline.incoming.key {
            parts.append(a == b ? "Same key \(a.label)" : "\(a.label) → \(b.label)")
        }
        if let a = timeline.outgoing.bpm, let b = timeline.incoming.bpm {
            parts.append("\(Int(a.rounded())) → \(Int(b.rounded())) BPM")
        }
        if timeline.outgoing.vocalsMeasured && timeline.incoming.vocalsMeasured {
            parts.append(timeline.vocalOverlapBeats <= 1 ? "No vocals in the overlap" : "Vocals overlap")
        }
        return parts.joined(separator: " · ")
    }
}

extension DJPlanModel {
    func install(plan: MixPlanRecord, for key: DJPlanTransitionKey) {
        plans[key.id] = plan
    }

    func markReplanning(_ keys: Set<DJPlanTransitionKey>) {
        replans = keys
    }

    func reconcile() {
        reconcileSelected()
    }

    static let liveHorizon = 10

    static func live(player: PlayerService = .shared, headphones: DJPlanHeadphonePreview = DJPlanNoHeadphones(), actions: DJPlanActions = DJPlanActions()) async -> DJPlanModel {
        let queue = player.queue
        let current = min(max(0, player.currentIndex), max(0, queue.count - 1))
        let start = max(0, current - 1)
        let window = Array(queue.dropFirst(start).prefix(liveHorizon + 2))
        let described = await withTaskGroup(of: (Int, DJPlanTrack, [Float]?).self) { group in
            for (offset, track) in window.enumerated() {
                group.addTask {
                    let plan = await DJPlanDirectorPlanner.describe(track)
                    var samples: [Float]?
                    if case .success(let waveform) = await WaveformService.shared.waveform(for: track) { samples = waveform.samples }
                    return (offset, plan, samples)
                }
            }
            var results: [(Int, DJPlanTrack, [Float]?)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }
        }
        let tracks = described.map(\.1)
        var samples: [String: [Float]] = [:]
        for (_, track, waveform) in described { if let waveform { samples[track.id] = waveform } }
        let locked = current > 0 ? 2 : 1
        let model = DJPlanModel(
            crate: DJPlanCrate(name: "Up Next", tracks: tracks, lockedCount: min(locked, tracks.count)),
            planner: DJPlanDirectorPlanner(tracks: Dictionary(queue.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })),
            headphones: headphones,
            actions: actions
        )
        model.waveforms = samples
        return model
    }
}

#if DEBUG
extension DJPlanModel {
    static func fixture(at date: Date = Date(timeIntervalSinceReferenceDate: 815_000_000)) -> DJPlanModel {
        var crate = DJPlanFixture.crate
        if let index = crate.tracks.firstIndex(where: { $0.id == DJPlanFixture.softStatic.id }) {
            crate.tracks[index] = DJPlanFixture.reanalysedSoftStatic
        }
        let key = DJPlanTransitionKey(outgoingId: DJPlanFixture.lowSun.id, incomingId: DJPlanFixture.softStatic.id)
        var library = DJPlanEditLibrary()
        library[key].apply(DJPlanFixture.autoTimeline.applying(.bassSwap, bar: 17).edit, at: date)
        library[key].apply(DJPlanFixture.editedTimeline.edit, at: date)
        let model = DJPlanModel(
            crate: crate,
            live: DJPlanLive(
                from: .init(deck: .a, title: "Glass District", remaining: 21),
                to: .init(deck: .b, title: "Low Sun"),
                step: "Fade in · bar 6 of 16",
                nextStartsIn: 280
            ),
            decks: [
                "fixture-glass-district": .a,
                DJPlanFixture.lowSun.id: .b,
                DJPlanFixture.softStatic.id: .a
            ],
            played: ["fixture-night-tapes": date.addingTimeInterval(-1_500)],
            planner: DJPlanFixturePlanner(),
            store: DJPlanEditStore(library: library, persist: { _ in }),
            actions: DJPlanActions(extend: {}, mixNow: {}, takeOverAll: {}, skip: { _ in }, force: { _, _ in })
        )
        if let velvet = model.crate.tracks.firstIndex(where: { $0.title == "Velvet Hour" }) {
            if case .success(let joins) = model.crate.move(from: velvet, to: 4) { model.markReplanning(joins) }
        }
        for join in model.crate.joins {
            guard let a = model.track(join.outgoingId), let b = model.track(join.incomingId) else { continue }
            let plan = join == key
                ? DJPlanFixture.record(move: DJPlanFixture.loopMix, from: DJPlanFixture.lowSun, to: DJPlanFixture.reanalysedSoftStatic, mixPoint: DJPlanFixture.mixPoint, entry: DJPlanFixture.entry)
                : DJPlanFixture.plan(from: a, to: b)
            model.install(plan: plan, for: join)
        }
        model.waveforms = Dictionary(uniqueKeysWithValues: model.crate.tracks.map { ($0.id, fixtureEnvelope(for: $0)) })
        model.selectedKey = key
        model.reconcile()
        return model
    }

    private static func fixtureEnvelope(for track: DJPlanTrack) -> [Float] {
        let count = max(64, Int(track.duration * 20))
        let bar = track.grid?.barDuration ?? 2
        return (0..<count).map { index in
            let t = Double(index) / 20
            let beat = (t / (bar / 4)).truncatingRemainder(dividingBy: 1)
            let pulse = Float(exp(-beat * 6))
            let vocal: Float = track.vocals(at: t) ? 0.25 : 0
            let wobble = Float(0.5 + 0.5 * sin(Double(index) * 0.37) * sin(Double(index) * 0.011))
            return min(1, 0.25 + 0.55 * pulse + 0.15 * wobble + vocal)
        }
    }
}

struct DJPlanFixtureScreen: View {
    @State private var model = DJPlanModel.fixture()

    var body: some View {
        DJPlanScreen(model: model) {
            HStack(spacing: 0) {
                ForEach(["Perform", "Prep", "Plan"], id: \.self) { mode in
                    Text(mode)
                        .font(.body.weight(.medium))
                        .foregroundStyle(mode == "Plan" ? Color.black : Color.white.opacity(0.92))
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background(mode == "Plan" ? Color.white : Color.clear, in: .capsule)
                }
            }
            .padding(3)
            .glassEffect(.regular, in: .capsule)
        }
        .background(Color(white: 0.043))
        .environment(\.colorScheme, .dark)
    }
}
#endif
