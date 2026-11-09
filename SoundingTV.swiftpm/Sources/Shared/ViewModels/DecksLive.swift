import Foundation
import Combine
import Observation
import QuartzCore

enum DeckSlot: String, Hashable, Sendable {
    case onAir
    case next
}

struct DeckAnchor: Equatable, Sendable {
    var position: TimeInterval
    var hostTime: CFTimeInterval
    var rate: Double

    static let zero = DeckAnchor(position: 0, hostTime: 0, rate: 0)

    func position(at host: CFTimeInterval) -> TimeInterval {
        position + max(0, host - hostTime) * rate
    }

    func settled(at measured: TimeInterval, rate: Double, host: CFTimeInterval, tolerance: TimeInterval) -> DeckAnchor {
        if abs(self.rate - rate) < 0.0005, abs(position(at: host) - measured) < tolerance { return self }
        return DeckAnchor(position: measured, hostTime: host, rate: rate)
    }

    func date(atPosition target: TimeInterval, now: Date, host: CFTimeInterval) -> Date? {
        guard rate > 0 else { return nil }
        return now.addingTimeInterval((target - position(at: host)) / rate)
    }
}

struct DeckBeatClock: Equatable, Sendable {
    struct Reading: Equatable, Sendable {
        var phrase: Int
        var barInPhrase: Int
        var beatInBar: Int
    }

    let firstDownbeat: TimeInterval
    let beatPeriod: Double
    let beatsPerBar: Int
    let barsPerPhrase: Int
    let firstPhraseBar: Int

    init?(_ grid: BeatGrid?) {
        guard let grid, grid.beatPeriod > 0.05, grid.beatPeriod < 3 else { return nil }
        firstDownbeat = grid.firstDownbeat
        beatPeriod = grid.beatPeriod
        beatsPerBar = 4
        barsPerPhrase = max(1, grid.barsPerPhrase)
        firstPhraseBar = grid.firstPhraseBar
    }

    var bpm: Double { 60 / beatPeriod }
    var barSeconds: Double { beatPeriod * Double(beatsPerBar) }
    var phraseStart: TimeInterval { firstDownbeat + Double(firstPhraseBar) * barSeconds }

    func reading(at seconds: TimeInterval) -> Reading? {
        guard seconds >= firstDownbeat - beatPeriod * 0.5 else { return nil }
        let beat = Int(((seconds - firstDownbeat) / beatPeriod + 0.0001).rounded(.down))
        let bar = Self.floorDiv(beat, beatsPerBar) - firstPhraseBar
        return Reading(
            phrase: Self.floorDiv(bar, barsPerPhrase) + 1,
            barInPhrase: Self.mod(bar, barsPerPhrase) + 1,
            beatInBar: Self.mod(beat, beatsPerBar) + 1
        )
    }

    func nextBeat(after seconds: TimeInterval) -> TimeInterval {
        let index = ((seconds - firstDownbeat) / beatPeriod).rounded(.down) + 1
        return firstDownbeat + index * beatPeriod
    }

    func snapped(_ seconds: TimeInterval) -> TimeInterval {
        firstDownbeat + ((seconds - firstDownbeat) / beatPeriod).rounded() * beatPeriod
    }

    private static func floorDiv(_ a: Int, _ b: Int) -> Int {
        a >= 0 ? a / b : -((-a + b - 1) / b)
    }

    private static func mod(_ a: Int, _ b: Int) -> Int {
        ((a % b) + b) % b
    }
}

struct DeckLiveSnapshot: Equatable {
    enum Role: Equatable {
        case empty
        case onAir
        case paused
        case upNext
        case mixingIn
        case loading(Double)
        case failed

        var title: String {
            switch self {
            case .empty: return "Empty"
            case .onAir: return "On Air"
            case .paused: return "Paused"
            case .upNext: return "Up Next"
            case .mixingIn: return "Mixing In"
            case .loading(let fraction): return "Loading \(Int((fraction * 100).rounded()))%"
            case .failed: return "Couldn't Load"
            }
        }
    }

    var track: Track?
    var engineDeck: MixEngine.Deck?
    var role: Role = .empty
    var isPlaying = false
    var anchor: DeckAnchor = .zero
    var duration: TimeInterval = 0
    var rate: Double = 1
    var beats: DeckBeatClock?
    var loop: ClosedRange<TimeInterval>?
    var filter: Double = 0
    var readout = DeckReadout(.pending)
    var tempo: Double?
    var owned: [MixControl] = []
    var isAutoMixOnly = false
    var hasWaveform = false
    var mixWindow: ClosedRange<TimeInterval>?
    var entry: TimeInterval?

    static let empty = DeckLiveSnapshot()

    var isEmpty: Bool { track == nil }
    var trackId: String? { track?.id }

    var filterLabel: String? { DecksFilterSweep.label(for: filter) }
}

struct DecksRemoteState: Equatable, Sendable {
    var name: String
    var touchedAt: Date?

    func isMixing(at date: Date, owns: Bool) -> Bool {
        if owns { return true }
        guard let touchedAt else { return false }
        return date.timeIntervalSince(touchedAt) < DecksLiveModel.remoteActiveSeconds
    }
}

struct DecksEnergy: Equatable {
    struct Point: Equatable, Identifiable {
        var offset: Int
        var energy: Double?
        var id: Int { offset }
    }

    var level: Int = 5
    var source: AutoMixEnergy.Source = .manual
    var curve: [Point] = []

    var canAdjust: Bool { source == .manual || source == .night }

    var sourceText: String? {
        switch source {
        case .workout: return "Following your workout"
        case .remote: return "Set from iPhone"
        case .night: return "Following the night"
        case .manual: return nil
        }
    }
}

enum DecksFilterSweep {
    static let lowestLowPass: Double = 140
    static let highestHighPass: Double = 5_000

    static func label(for amount: Double) -> String? {
        guard abs(amount) >= 0.05 else { return nil }
        let cutoff = hertz(for: amount)
        let value = cutoff >= 1_000 ? String(format: "%.1f kHz", cutoff / 1_000) : "\(Int(cutoff.rounded())) Hz"
        return amount < 0 ? "Low-pass \(value)" : "High-pass \(value)"
    }

    static func hertz(for amount: Double) -> Double {
        let a = min(1, max(-1, amount))
        if a < 0 {
            return MixEngine.filterCutoffRange.upperBound * pow(lowestLowPass / MixEngine.filterCutoffRange.upperBound, -a)
        }
        return MixEngine.filterCutoffRange.lowerBound * pow(highestHighPass / MixEngine.filterCutoffRange.lowerBound, a)
    }

    static func amount(lowPass: Double, highPass: Double) -> Double {
        if highPass > 60 {
            return min(1, log(highPass / MixEngine.filterCutoffRange.lowerBound) / log(highestHighPass / MixEngine.filterCutoffRange.lowerBound))
        }
        if lowPass < 16_000 {
            return -min(1, log(MixEngine.filterCutoffRange.upperBound / max(lowPass, 30)) / log(MixEngine.filterCutoffRange.upperBound / lowestLowPass))
        }
        return 0
    }
}

@MainActor
@Observable
final class DecksLiveModel {
    nonisolated static let remoteActiveSeconds: TimeInterval = 10

    private(set) var onAir = DeckLiveSnapshot.empty
    private(set) var next = DeckLiveSnapshot.empty
    private(set) var crossfade: Double = 0
    private(set) var blend: Double = 0
    private(set) var status: DeckMixStatus = .off
    private(set) var isAutoMixOn = false
    private(set) var styleName: String?
    private(set) var styleId: DJProfileID?
    private(set) var canMixNow = false
    private(set) var canExtend = false
    private(set) var canChooseMove = false
    private(set) var move: MixMove.Kind?
    private(set) var isMoveChosen = false
    private(set) var isMixing = false
    private(set) var isPlaying = false
    private(set) var isEngineLive = false
    private(set) var owned: [MixControl] = []
    private(set) var remote: DecksRemoteState?
    private(set) var isRemoteMixing = false
    private(set) var energy = DecksEnergy()
    private(set) var problem: String?
    private(set) var hasTrack = false
    private(set) var hasNext = false
    private(set) var onAirArtwork: URL?
    private(set) var nextArtwork: URL?

    @ObservationIgnored private let player: PlayerService
    @ObservationIgnored private let engine: MixEngine
    @ObservationIgnored private let analysis: DJTransitionService
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []
    @ObservationIgnored private var refreshQueued = false
    @ObservationIgnored private var remoteTimer: Task<Void, Never>?
    @ObservationIgnored private var sweeps: [MixEngine.Deck: Task<Void, Never>] = [:]
    @ObservationIgnored private var sweptControls: Set<MixControl> = []
    @ObservationIgnored private var swappedControls: Set<MixControl> = []
    @ObservationIgnored private var chosenMoves: [String: MixMove.Kind] = [:]
    @ObservationIgnored private var primedIds: Set<String> = []

    init(player: PlayerService = .shared, engine: MixEngine = .shared, analysis: DJTransitionService = .shared) {
        self.player = player
        self.engine = engine
        self.analysis = analysis
    }

    var remoteOwnsControls: Bool { isRemoteMixing && !owned.isEmpty }

    func start(remote: AnyPublisher<DecksRemoteState?, Never>? = nil) {
        guard cancellables.isEmpty else { return }
        let poke: () -> Void = { [weak self] in self?.scheduleRefresh() }
        player.objectWillChange.sink { _ in poke() }.store(in: &cancellables)
        player.clock.$currentTime.sink { _ in poke() }.store(in: &cancellables)
        engine.$decks.sink { _ in poke() }.store(in: &cancellables)
        engine.$crossfade.sink { _ in poke() }.store(in: &cancellables)
        engine.$ownedControls.sink { _ in poke() }.store(in: &cancellables)
        analysis.$states.sink { _ in poke() }.store(in: &cancellables)
        WaveformService.shared.$states.sink { _ in poke() }.store(in: &cancellables)
        AutoMixEnergy.shared.objectWillChange.sink { _ in poke() }.store(in: &cancellables)
        SettingsStore.shared.$djEnergyLevel.sink { _ in poke() }.store(in: &cancellables)
        SettingsStore.shared.$djEnergyFollowsNight.sink { _ in poke() }.store(in: &cancellables)
        remote?.removeDuplicates().sink { [weak self] value in
            self?.adoptRemote(value)
        }.store(in: &cancellables)
        refresh()
    }

    func stop() {
        cancellables.removeAll()
        remoteTimer?.cancel()
        remoteTimer = nil
        for task in sweeps.values { task.cancel() }
        sweeps.removeAll()
        releaseSweptControls()
    }

    // MARK: Refresh

    private func scheduleRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refreshQueued = false
            self.refresh()
        }
    }

    private func refresh() {
        let host = CACurrentMediaTime()
        let now = Date()
        let live = player.isMixEngineLive
        let liveDeck = player.liveDeck
        let current = player.currentTrack
        let upcoming = player.upcomingTrack
        let autoMix = player.isAutoMixEnabled

        assign(\.isEngineLive, live)
        assign(\.isPlaying, player.isPlaying)
        assign(\.isAutoMixOn, autoMix)
        assign(\.styleName, autoMix ? (player.djProfile?.styleName ?? "Club") : nil)
        assign(\.styleId, player.djProfile?.id)
        assign(\.status, DeckMixStatus.current(player))
        assign(\.isMixing, player.mixWindow != nil)
        assign(\.canMixNow, player.canStartMix)
        assign(\.canExtend, player.canExtendMix)
        assign(\.canChooseMove, player.djDirector.canChooseMove && upcoming != nil)
        assign(\.problem, problemText)

        let plan = player.adaptiveMixPlan
        assign(\.move, plan?.move?.kind)
        let chosen = current.flatMap { chosenMoves[$0.id] }
        assign(\.isMoveChosen, chosen != nil && plan?.move?.kind == chosen)

        let orientedFade = liveDeck == .a ? engine.crossfade : 1 - engine.crossfade
        assign(\.crossfade, Self.quantised(live ? orientedFade : 0, step: 0.02))

        var onAirDeck = deckSnapshot(slot: .onAir, track: current, engineDeck: live ? liveDeck : nil, previous: onAir, host: host)
        var nextDeck = deckSnapshot(slot: .next, track: upcoming, engineDeck: live ? liveDeck.other : nil, previous: next, host: host)
        if let plan, autoMix, current != nil {
            let start = plan.mixPointSeconds
            onAirDeck.mixWindow = start...(start + max(0.5, plan.transitionSeconds))
            if plan.incomingTrackId == nil || plan.incomingTrackId == upcoming?.id {
                nextDeck.entry = plan.entrySeconds
            }
        } else if let window = player.mixWindow {
            onAirDeck.mixWindow = window.start...window.end
        }
        assign(\.onAir, onAirDeck)
        assign(\.next, nextDeck)
        assign(\.hasTrack, current != nil)
        assign(\.hasNext, upcoming != nil)
        assign(\.onAirArtwork, current.flatMap { $0.largeArtworkURL ?? $0.artworkURL })
        assign(\.nextArtwork, upcoming.flatMap { $0.largeArtworkURL ?? $0.artworkURL })

        let mixProgress: Double = {
            guard let state = AutoMixLive.shared.state, state.stage != .upcoming else { return 0 }
            return state.clock(at: now).progress
        }()
        let target = isMixing ? max(crossfade, mixProgress) : (live ? crossfade : 0)
        assign(\.blend, Self.quantised(target, step: 0.04))

        let ownedNow = engine.ownedControls.sorted { $0.id < $1.id }
        assign(\.owned, ownedNow)
        if player.mixWindow == nil, !swappedControls.isEmpty { handBackSwap() }
        assign(\.isRemoteMixing, remote?.isMixing(at: now, owns: !ownedNow.isEmpty && sweptControls.isEmpty) ?? false)

        assign(\.energy, energyReading())
        prime(current: current, upcoming: upcoming)
    }

    private func deckSnapshot(
        slot: DeckSlot,
        track: Track?,
        engineDeck: MixEngine.Deck?,
        previous: DeckLiveSnapshot,
        host: CFTimeInterval
    ) -> DeckLiveSnapshot {
        guard let track else { return .empty }
        var deck = DeckLiveSnapshot()
        deck.track = track
        deck.readout = DeckReadout(analysis.state(for: track.id))
        deck.hasWaveform = WaveformService.shared.state(for: track.id).waveform != nil
        deck.isAutoMixOnly = Self.isAutoMixOnly(track)
        deck.duration = track.duration

        let state = engineDeck.map { engine[$0] }
        let loaded = state.map { $0.trackId == track.id && $0.status.isReady } ?? false
        let sameTrack = previous.track?.id == track.id
        var measured: TimeInterval = 0
        var rate = 0.0

        if loaded, let engineDeck, let state {
            deck.engineDeck = engineDeck
            deck.isPlaying = state.isPlaying
            deck.duration = state.duration > 0 ? state.duration : track.duration
            deck.rate = state.rate
            deck.beats = DeckBeatClock(engine.beatGrid(for: engineDeck))
            if let start = state.loopStartSeconds, let length = state.loopLengthSeconds, length > 0.01 {
                deck.loop = start...(start + length)
            }
            deck.filter = Self.quantised(DecksFilterSweep.amount(lowPass: state.filterCutoff, highPass: state.highPassCutoff), step: 0.05)
            deck.owned = engine.ownedControls.filter { $0.deck == engineDeck }.sorted { $0.id < $1.id }
            measured = engine.audiblePosition(of: engineDeck)
            rate = state.isPlaying ? state.rate : 0
        } else if slot == .onAir {
            deck.isPlaying = player.isPlaying
            deck.duration = max(player.clock.duration, track.duration)
            measured = player.clock.currentTime
            rate = player.isPlaying ? 1 : 0
        } else if let entry = player.adaptiveMixPlan?.entrySeconds {
            measured = entry
        }

        if let bpm = deck.beats?.bpm ?? deck.readout.bpm {
            deck.tempo = bpm * (loaded ? deck.rate : 1)
        }

        let tolerance = rate > 0 ? 0.06 : 0.005
        deck.anchor = sameTrack
            ? previous.anchor.settled(at: measured, rate: rate, host: host, tolerance: tolerance)
            : DeckAnchor(position: measured, hostTime: host, rate: rate)

        switch slot {
        case .onAir:
            deck.role = deck.isPlaying ? .onAir : .paused
        case .next:
            if player.mixWindow != nil {
                deck.role = .mixingIn
            } else {
                switch player.incomingDeck {
                case .loading(let fraction) where player.isMixEngineLive: deck.role = .loading(fraction)
                case .failed: deck.role = .failed
                default: deck.role = .upNext
                }
            }
        }
        return deck
    }

    private var problemText: String? {
        if case .unavailable = player.mixEngineState { return "Tracks will play one after another." }
        if engine.lastError != nil, player.isAutoMixEnabled, !player.isMixEngineLive { return "Tracks will play one after another." }
        return nil
    }

    private func energyReading() -> DecksEnergy {
        let reading = AutoMixEnergy.shared.reading()
        var energy = DecksEnergy(level: reading.level, source: reading.source)
        let queue = player.queue
        let index = player.currentIndex
        guard !queue.isEmpty, queue.indices.contains(index) else { return energy }
        let lower = max(0, index - 6)
        let upper = min(queue.count - 1, index + 6)
        energy.curve = (lower...upper).map { position in
            let value: Double?
            if case .analyzed(let result) = analysis.state(for: queue[position].id) {
                value = result.energy
            } else {
                value = nil
            }
            return DecksEnergy.Point(offset: position - index, energy: value.map { Self.quantised($0, step: 0.02) })
        }
        return energy
    }

    private func prime(current: Track?, upcoming: Track?) {
        let ids = Set([current?.id, upcoming?.id].compactMap { $0 })
        guard ids != primedIds else { return }
        primedIds = ids
        analysis.analyzeUpcoming(in: player.queue, from: player.currentIndex)
        if let current { WaveformService.shared.load(current) }
        if let upcoming { WaveformService.shared.load(upcoming) }
    }

    private func adoptRemote(_ value: DecksRemoteState?) {
        assign(\.remote, value)
        remoteTimer?.cancel()
        remoteTimer = nil
        if value != nil {
            remoteTimer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self else { return }
                    self.scheduleRefresh()
                }
            }
        }
        scheduleRefresh()
    }

    private func assign<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<DecksLiveModel, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    static func quantised(_ value: Double, step: Double) -> Double {
        guard value.isFinite else { return 0 }
        return (value / step).rounded() * step
    }

    static func isAutoMixOnly(_ track: Track) -> Bool {
        guard case .soundCloud = track.source else { return false }
        return SubscriptionService.shared.djGearDenial(.decks, isSoundCloudTrack: true, personalUnlocked: false) != nil
    }

    func deck(_ slot: DeckSlot) -> DeckLiveSnapshot {
        slot == .onAir ? onAir : next
    }

    // MARK: Actions

    func togglePlayPause() {
        player.togglePlayPause()
    }

    func mixNow() {
        guard player.canStartMix else { return }
        player.startMix()
    }

    func extend() {
        guard player.canExtendMix else { return }
        player.extendMix()
    }

    func skip() {
        Task { await player.playNext() }
    }

    func setAutoMix(_ enabled: Bool) {
        player.setAutomaticMixEnabled(enabled)
    }

    func setStyle(_ id: DJProfileID) {
        player.setDJProfile(id)
    }

    func nudgeEnergy(by step: Int) {
        let reading = AutoMixEnergy.shared.reading()
        guard reading.source == .manual || reading.source == .night else { return }
        let level = min(10, max(1, reading.level + step))
        let settings = SettingsStore.shared
        if settings.djEnergyFollowsNight { settings.setDJEnergyFollowsNight(false) }
        settings.setDJEnergyLevel(Double(level - 1) / 9)
    }

    func chooseMove(_ kind: MixMove.Kind?) {
        guard let current = player.currentTrack, player.djDirector.canChooseMove else { return }
        guard let kind else {
            chosenMoves[current.id] = nil
            player.djDirector.chooseMove(nil, forTrackId: current.id)
            return
        }
        guard let plan = player.adaptiveMixPlan,
              let reshaped = DJPlanMoves.reshape(MixPlanRecord(plan), to: kind) else { return }
        chosenMoves[current.id] = kind
        player.djDirector.chooseMove(reshaped.phantomPlan, forTrackId: current.id)
        scheduleRefresh()
    }

    func loop(beats: Double) {
        guard let deckId = onAir.engineDeck, !onAir.isAutoMixOnly else { return }
        engine.setQuantizedLoop(on: deckId, near: engine.livePosition(of: deckId), beats: beats)
    }

    func exitLoop() {
        guard let deckId = onAir.engineDeck else { return }
        engine.clearLoop(on: deckId)
    }

    var canSwapBass: Bool {
        player.mixWindow?.isLive == true && onAir.engineDeck != nil && next.engineDeck != nil
    }

    func swapBassNow() {
        guard canSwapBass, let outgoing = onAir.engineDeck, let incoming = next.engineDeck else { return }
        let controls: Set<MixControl> = [MixControl(.low, deck: outgoing), MixControl(.low, deck: incoming)]
        for control in controls where !engine.ownedControls.contains(control) {
            engine.takeOver(control)
            swappedControls.insert(control)
        }
        let beat = onAir.beats?.beatPeriod ?? 0.47
        engine.asUser {
            engine.swapBass(from: outgoing, to: incoming, over: beat)
        }
    }

    private func handBackSwap() {
        for control in swappedControls { engine.handBack(control) }
        swappedControls.removeAll()
    }

    func canPerform(on slot: DeckSlot) -> Bool {
        let deck = deck(slot)
        return deck.engineDeck != nil && !deck.isAutoMixOnly
    }

    func sweepFilter(_ slot: DeckSlot, to amount: Double) {
        let deck = deck(slot)
        guard let deckId = deck.engineDeck, !deck.isAutoMixOnly else { return }
        sweeps[deckId]?.cancel()
        sweeps[deckId] = nil
        let control = MixControl(.filter, deck: deckId)
        if player.isAutoMixEnabled, !engine.ownedControls.contains(control) {
            engine.takeOver(control)
            sweptControls.insert(control)
        }
        let hertz = DecksFilterSweep.hertz(for: amount)
        engine.asUser {
            if amount < 0 {
                engine.setHighPassCutoff(MixEngine.filterCutoffRange.lowerBound, on: deckId)
                engine.setFilterCutoff(hertz, on: deckId, over: 0.03)
            } else {
                engine.setFilterCutoff(MixEngine.filterCutoffRange.upperBound, on: deckId)
                engine.setHighPassCutoff(hertz, on: deckId, over: 0.03)
            }
        }
    }

    func releaseFilter(_ slot: DeckSlot) {
        guard let deckId = deck(slot).engineDeck else { return }
        let glide: TimeInterval = 0.45
        engine.asUser {
            engine.setFilterCutoff(MixEngine.filterCutoffRange.upperBound, on: deckId, over: glide)
            engine.setHighPassCutoff(MixEngine.filterCutoffRange.lowerBound, on: deckId, over: glide)
        }
        let control = MixControl(.filter, deck: deckId)
        sweeps[deckId]?.cancel()
        sweeps[deckId] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(glide + 0.1))
            guard !Task.isCancelled, let self else { return }
            self.sweeps[deckId] = nil
            if self.sweptControls.remove(control) != nil { self.engine.handBack(control) }
        }
    }

    private func releaseSweptControls() {
        for control in sweptControls {
            if let deckId = control.deck {
                engine.asUser {
                    engine.setFilterCutoff(MixEngine.filterCutoffRange.upperBound, on: deckId, over: 0.2)
                    engine.setHighPassCutoff(MixEngine.filterCutoffRange.lowerBound, on: deckId, over: 0.2)
                }
            }
            engine.handBack(control)
        }
        sweptControls.removeAll()
        handBackSwap()
    }

    func canJog(_ slot: DeckSlot) -> Bool {
        slot == .onAir && !onAir.isEmpty && !onAir.isPlaying && !onAir.isAutoMixOnly
    }

    func jog(from position: TimeInterval, beats: Double) {
        guard canJog(.onAir) else { return }
        let period = onAir.beats?.beatPeriod ?? 0.5
        var target = position + beats * period
        if let clock = onAir.beats { target = clock.snapped(target) }
        player.seek(to: min(max(0, target), max(0, onAir.duration - 1)))
    }

    func handBack() {
        engine.handBackAll()
        sweptControls.removeAll()
        swappedControls.removeAll()
    }

    func setNext(_ track: Track) {
        guard track.id != player.currentTrack?.id else { return }
        if player.queue.isEmpty {
            Task { await player.play(track, in: [track]) }
            return
        }
        let start = player.currentIndex + 1
        if start < player.queue.count, let index = player.queue[start...].firstIndex(where: { $0.id == track.id }) {
            if index != start || player.playingNextCount == 0 { player.moveToPlayingNext(at: index) }
        } else {
            player.insertIntoQueue(track, at: start)
        }
        scheduleRefresh()
    }

    func play(_ track: Track) {
        Task { await player.play(track, in: [track]) }
    }

    func startAutoMix(_ configuration: DJStartConfiguration) async -> Bool {
        player.startDJSession(configuration: configuration, reconfigure: true)
        guard player.currentTrack == nil else { return true }
        let count = await LibraryDB.count(.likes)
        guard count > 0 else { return false }
        let tracks = await LibraryDB.tracks(.likes, offset: 0, limit: min(count, 200)).tracks.shuffled()
        guard let first = tracks.first, player.currentTrack == nil else { return player.currentTrack != nil }
        await player.play(first, in: tracks, collectionId: CollectionPolicyID.likedTracks)
        return true
    }
}
