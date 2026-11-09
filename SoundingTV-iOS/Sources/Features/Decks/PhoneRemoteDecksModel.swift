import Combine
import SwiftUI

struct PhoneRemoteDeck: Equatable {
    var slot: MixEngine.Deck
    var engineDeck: MixEngine.Deck
    var trackId: String?
    var title = ""
    var artist = ""
    var artworkURL: URL?
    var position: Double = 0
    var duration: Double = 0
    var isPlaying = false
    var isLive = false
    var isLoaded = false
    var bpm: Double?
    var tempoPercent: Double = 0
    var cuePoint: Double?

    var isEmpty: Bool { trackId == nil }
    var remaining: Double { max(0, duration - position) }
}

struct PhoneRemoteDecksState {
    var decks: [MixEngine.Deck: PhoneRemoteDeck] = [:]
    var values: [MixControl: Double] = [:]
    var yours: Set<MixControl> = []
    var hasState = false
    var isEngineLive = false
    var isDecksOpen = false
    var isAutoMixOn = false
    var isMixing = false
    var canExtend = false
    var headline: String?

    func deck(_ slot: MixEngine.Deck) -> PhoneRemoteDeck {
        decks[slot] ?? PhoneRemoteDeck(slot: slot, engineDeck: slot)
    }

    func value(_ control: MixControl) -> Double {
        values[control] ?? 0.5
    }

    var canMixNow: Bool {
        isEngineLive && !isMixing && !deck(.a).isEmpty && !deck(.b).isEmpty
    }
}

@MainActor
final class PhoneRemoteDecksModel: ObservableObject {
    static let holdInterval: TimeInterval = 0.8
    static let playHoldInterval: TimeInterval = 1.5
    static let leaseInterval: Duration = .seconds(4)
    static let bands: [MixControl.Kind] = [.high, .mid, .low, .filter]

    @Published private(set) var revision = 0

    let client: CompanionClient
    private var overrides: [MixControl: (value: Double, until: Date)] = [:]
    private var playOverrides: [MixEngine.Deck: (isPlaying: Bool, until: Date)] = [:]
    private var cuePoints: [String: Double] = [:]
    private var yours: Set<MixControl> = []
    private var swapped = false
    private var leaseTask: Task<Void, Never>?

    init(client: CompanionClient) {
        self.client = client
    }

    // MARK: Lease

    func attach() {
        guard leaseTask == nil else { return }
        leaseTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.client.attachDecks(true)
                try? await Task.sleep(for: Self.leaseInterval)
            }
        }
    }

    func detach() {
        leaseTask?.cancel()
        leaseTask = nil
        client.attachDecks(false)
    }

    // MARK: State

    func state(at date: Date) -> PhoneRemoteDecksState {
        overrides = overrides.filter { $0.value.until > date }
        playOverrides = playOverrides.filter { $0.value.until > date }
        var state = PhoneRemoteDecksState()
        let feed = client.decks
        state.isDecksOpen = feed.decksOpen == true
        guard let dj = feed.state else {
            state.decks = fallbackDecks(at: date)
            return state
        }
        state.hasState = true
        state.isEngineLive = dj.isEngineLive
        state.isAutoMixOn = dj.isAutoMixEnabled
        state.headline = dj.automaticMix?.headline
        state.canExtend = dj.automaticMix?.canExtend == true
        state.isMixing = dj.automaticMix.map { $0.phase == .mixing || $0.phase == .cutting } ?? false
        if !dj.isAutoMixEnabled { yours.removeAll() }

        if overrides.isEmpty {
            swapped = dj.deckB.role == .live && dj.deckA.role != .live
        }

        let fallback = fallbackDecks(at: date)
        for slot in MixEngine.Deck.allCases {
            let engine = engineDeck(for: slot)
            let payload = engine == .a ? dj.deckA : dj.deckB
            var deck = dj.isEngineLive && payload.trackId != nil
                ? liveDeck(slot: slot, engine: engine, payload: payload, receivedAt: feed.receivedAt, at: date)
                : fallback[slot] ?? PhoneRemoteDeck(slot: slot, engineDeck: engine)
            deck.engineDeck = engine
            if let hold = playOverrides[engine] { deck.isPlaying = hold.isPlaying }
            deck.cuePoint = deck.trackId.flatMap { cuePoints[$0] }
            state.decks[slot] = deck

            let knobs: [MixControl.Kind: Double] = [
                .high: DJMixerUnits.eqKnob(decibels: payload.eqHighDb),
                .mid: DJMixerUnits.eqKnob(decibels: payload.eqMidDb),
                .low: DJMixerUnits.eqKnob(decibels: payload.eqLowDb),
                .filter: DJMixerUnits.bipolarFilterKnob(
                    lowPass: payload.filterCutoffHz,
                    highPass: payload.highPassCutoffHz ?? MixEngine.filterCutoffRange.lowerBound
                ),
                .tempo: DJMixerUnits.tempoKnob(rate: payload.rate),
            ]
            for (kind, server) in knobs {
                let key = MixControl(kind, deck: engine)
                state.values[MixControl(kind, deck: slot)] = overrides[key]?.value ?? server
            }
        }
        if state.deck(.b).trackId == state.deck(.a).trackId {
            state.decks[.b] = PhoneRemoteDeck(slot: .b, engineDeck: engineDeck(for: .b))
        }

        let crossfade = overrides[.crossfader]?.value ?? dj.crossfade
        state.values[.crossfader] = swapped ? 1 - crossfade : crossfade
        state.yours = Set(yours.map(slotControl))
        return state
    }

    private func liveDeck(slot: MixEngine.Deck, engine: MixEngine.Deck, payload: DJDeckStatePayload, receivedAt: Date?, at date: Date) -> PhoneRemoteDeck {
        var deck = PhoneRemoteDeck(slot: slot, engineDeck: engine)
        let queued = payload.trackId.flatMap { id in client.tracks.first { $0.id == id } }
        let playback = client.telemetry.playback
        deck.trackId = payload.trackId
        deck.title = payload.title ?? queued?.title ?? ""
        deck.artist = payload.artist ?? queued?.artist ?? ""
        deck.artworkURL = queued?.artworkURL
            ?? (playback?.trackId == payload.trackId ? playback?.artworkURL.flatMap(URL.init(string:)) : nil)
        let elapsed = payload.isPlaying ? max(0, date.timeIntervalSince(receivedAt ?? date)) * payload.rate : 0
        let position = payload.positionSeconds + elapsed
        deck.position = payload.durationSeconds > 0 ? min(payload.durationSeconds, position) : position
        deck.duration = payload.durationSeconds
        deck.isPlaying = payload.isPlaying
        deck.isLive = payload.role.map { $0 == .live } ?? (slot == .a)
        deck.isLoaded = true
        deck.bpm = payload.bpm.map { $0 * payload.rate }
        deck.tempoPercent = (payload.rate - 1) * 100
        return deck
    }

    private func fallbackDecks(at date: Date) -> [MixEngine.Deck: PhoneRemoteDeck] {
        var a = PhoneRemoteDeck(slot: .a, engineDeck: engineDeck(for: .a))
        if let playback = client.telemetry.playback, let id = playback.trackId {
            a.trackId = id
            a.title = playback.title ?? ""
            a.artist = playback.artist ?? ""
            a.artworkURL = playback.artworkURL.flatMap(URL.init(string:))
            a.position = client.telemetry.estimatedPosition(at: date)
            a.duration = playback.durationSeconds
            a.isPlaying = client.telemetry.isPlaying
            a.isLive = true
        }
        var b = PhoneRemoteDeck(slot: .b, engineDeck: engineDeck(for: .b))
        if let next = client.upNext.first?.track, next.id != a.trackId {
            b.trackId = next.id
            b.title = next.title
            b.artist = next.artist
            b.artworkURL = next.artworkURL
            b.duration = next.duration
        }
        return [.a: a, .b: b]
    }

    private func engineDeck(for slot: MixEngine.Deck) -> MixEngine.Deck {
        swapped ? slot.other : slot
    }

    private func slotControl(_ engineControl: MixControl) -> MixControl {
        MixControl(engineControl.kind, deck: engineControl.deck.map(engineDeck(for:)))
    }

    private func engineControl(_ slotControl: MixControl) -> MixControl {
        MixControl(slotControl.kind, deck: slotControl.deck.map(engineDeck(for:)))
    }

    private static func wire(_ deck: MixEngine.Deck?) -> ControlDeck {
        switch deck {
        case .a: return .a
        case .b: return .b
        case nil: return .none
        }
    }

    private var isAutoMixOn: Bool { client.decks.state?.isAutoMixEnabled == true }

    // MARK: Mixer

    func grab(_ control: MixControl) {
        guard isAutoMixOn else { return }
        yours.insert(engineControl(control))
        revision &+= 1
    }

    func set(_ control: MixControl, to value: Double) {
        let key = engineControl(control)
        let until = Date().addingTimeInterval(Self.holdInterval)
        let deck = Self.wire(key.deck)
        if isAutoMixOn { yours.insert(key) }
        switch control.kind {
        case .crossfader:
            let engineValue = swapped ? 1 - value : value
            overrides[key] = (engineValue, until)
            client.setCrossfade(engineValue)
        case .high:
            overrides[key] = (value, until)
            client.setEQ(deck: deck, band: .eqHigh, decibels: DJMixerUnits.eqDecibels(knob: value))
        case .mid:
            overrides[key] = (value, until)
            client.setEQ(deck: deck, band: .eqMid, decibels: DJMixerUnits.eqDecibels(knob: value))
        case .low:
            overrides[key] = (value, until)
            client.setEQ(deck: deck, band: .eqLow, decibels: DJMixerUnits.eqDecibels(knob: value))
        case .filter:
            overrides[key] = (value, until)
            let filter = DJMixerUnits.bipolarFilter(knob: value)
            client.setFilterCutoff(deck: deck, hertz: filter.lowPass)
            client.setHighPassCutoff(deck: deck, hertz: filter.highPass)
        case .tempo:
            overrides[key] = (value, until)
            client.setRate(deck: deck, multiplier: DJMixerUnits.tempoRate(knob: value))
        case .trim, .volume, .echo:
            return
        }
        revision &+= 1
    }

    func handBack() {
        client.handBackDecks()
        yours.removeAll()
        revision &+= 1
    }

    // MARK: Transport

    func togglePlay(_ slot: MixEngine.Deck) {
        let state = state(at: Date())
        let deck = state.deck(slot)
        guard !deck.isEmpty else { return }
        if deck.isLive {
            client.togglePlayPause()
        } else if state.isEngineLive, deck.isLoaded {
            client.togglePlayPause(deck: Self.wire(deck.engineDeck))
        } else {
            return
        }
        playOverrides[deck.engineDeck] = (!deck.isPlaying, Date().addingTimeInterval(Self.playHoldInterval))
        revision &+= 1
    }

    func cue(_ slot: MixEngine.Deck) {
        let state = state(at: Date())
        let deck = state.deck(slot)
        guard let id = deck.trackId else { return }
        guard deck.isPlaying else {
            cuePoints[id] = deck.position
            revision &+= 1
            return
        }
        let point = cuePoints[id] ?? 0
        if state.isEngineLive, deck.isLoaded {
            client.cue(deck: Self.wire(deck.engineDeck), toSeconds: point)
        } else if deck.isLive {
            client.seek(toSeconds: point)
        } else {
            return
        }
        togglePlay(slot)
    }

    func sync(_ slot: MixEngine.Deck) {
        let deck = state(at: Date()).deck(slot)
        guard deck.isLoaded else { return }
        client.sync(deck: Self.wire(deck.engineDeck))
    }

    // MARK: Auto Mix

    func mixNow() { client.mixNow() }

    func extend() { client.extendMix() }

    func setAutoMix(_ enabled: Bool) {
        if !enabled { yours.removeAll() }
        client.setAutoMixEnabled(enabled)
        revision &+= 1
    }

    func loadNext(queueIndex index: Int) {
        client.playNext(queueIndex: index)
    }
}
