import Foundation

@MainActor
final class DJPlanCuePreview: DJPlanHeadphonePreview {
    typealias Resolver = @MainActor (DJPlanTrack) async -> URL?

    private let engine: MixEngine
    private let resolve: Resolver
    private var core: MixRenderCore?
    private var sources: [MixSource] = []
    private var tables: [MixBeatTable] = []
    private var task: Task<Void, Never>?
    private var pending = false

    init(engine: MixEngine = .shared, resolve: @escaping Resolver) {
        self.engine = engine
        self.resolve = resolve
    }

    convenience init(tracks: [String: Track], engine: MixEngine = .shared) {
        self.init(engine: engine) { planTrack in
            guard let track = tracks[planTrack.id] else { return nil }
            if MacDeckControlSurface.djDenial(.decks, source: track.source) != nil { return nil }
            return await AutomaticAnalysisEligibility.localFileURL(for: track, materialise: true)
        }
    }

    var isAvailable: Bool { engine.phonesOutput.isRunning }
    var isPreviewing: Bool { pending || core != nil }

    func preview(_ plan: MixPlanRecord, outgoing: DJPlanTrack, incoming: DJPlanTrack) {
        stopPreview()
        guard isAvailable else { return }
        pending = true
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pending = false }
            guard let outgoingURL = await self.resolve(outgoing),
                  let incomingURL = await self.resolve(incoming),
                  !Task.isCancelled else { return }
            let loaded = await Task.detached(priority: .userInitiated) { () -> (MixSource, MixSource)? in
                guard let a = try? MixSource(url: outgoingURL), let b = try? MixSource(url: incomingURL) else { return nil }
                return (a, b)
            }.value
            guard let loaded, !Task.isCancelled else { return }
            self.start(plan, outgoing: loaded.0, incoming: loaded.1, outgoingGrid: outgoing.grid, incomingGrid: incoming.grid)
            await self.run(until: plan)
        }
    }

    func stopPreview() {
        task?.cancel()
        task = nil
        pending = false
        engine.phonesOutput.previewSlot.attach(nil, level: 0, split: false)
        let retired: [AnyObject] = [core as AnyObject?].compactMap { $0 } + sources + tables
        core = nil
        sources = []
        tables = []
        guard !retired.isEmpty else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            withExtendedLifetime(retired) {}
        }
    }

    private func start(_ plan: MixPlanRecord, outgoing: MixSource, incoming: MixSource, outgoingGrid: BeatGrid?, incomingGrid: BeatGrid?) {
        let core = MixRenderCore()
        let sr = core.sampleRate
        var seq: Int64 = 0
        func push(_ make: (Int64) -> MixCommand) {
            seq += 1
            _ = core.ring.push(make(seq))
        }
        sources = [outgoing, incoming]
        for (index, source) in sources.enumerated() {
            push { .load(seq: $0, deck: index, source: Unmanaged.passUnretained(source)) }
        }
        for (index, grid) in [plan.outgoingBeatGrid ?? outgoingGrid, plan.incomingBeatGrid ?? incomingGrid].enumerated() {
            guard let grid, let table = MixBeatTable(grid: grid, sampleRate: sr) else { continue }
            tables.append(table)
            push { .beats(seq: $0, deck: index, table: Unmanaged.passUnretained(table)) }
        }
        func set(_ parameter: MixParameter, _ value: Double) {
            push { .event(seq: $0, time: 0, immediate: true, group: 0, action: .ramp(parameter, to: value, frames: 0, curve: .linear)) }
        }
        set(.crossfade, 0)
        set(.rate(1), plan.incomingRateRatio)
        let startSeconds = MixReplayPlanner.startSeconds(for: plan)
        push { .event(seq: $0, time: 0, immediate: true, group: 0, action: .start(deck: 0, fromFrame: startSeconds * sr)) }
        let execution = MixExecutionRecord(
            startSourceSeconds: plan.mixPointSeconds,
            windowSeconds: plan.transitionSeconds,
            entrySeconds: plan.entrySeconds,
            outgoingRate: 1,
            incomingRate: plan.incomingRateRatio,
            startedAtPlannedBoundary: true,
            riserLevel: 0,
            sampleRate: sr
        )
        let timeline = MixTimeline.transition(MixReplayPlanner.timelineInput(plan: plan, execution: execution, outgoing: 0, incoming: 1))
        for event in timeline.events {
            push { .event(seq: $0, time: event.offset, immediate: false, group: 1, action: event.action) }
        }
        push { .anchor(seq: $0, group: 1, anchor: timeline.anchor) }
        outgoing.prefetch(around: Int(startSeconds * sr))
        incoming.prefetch(around: Int(plan.entrySeconds * sr))
        self.core = core
        engine.phonesOutput.previewSlot.attach(core, level: Float(engine.mixer.phonesLevel), split: engine.mixer.splitCue)
    }

    private func run(until plan: MixPlanRecord) async {
        let seconds = plan.mixEndSeconds - MixReplayPlanner.startSeconds(for: plan) + 4 * plan.barSeconds
        let deadline = Date().addingTimeInterval(max(4, seconds))
        while !Task.isCancelled, Date() < deadline, core != nil {
            for source in sources { source.kick() }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if !Task.isCancelled { stopPreview() }
    }
}
