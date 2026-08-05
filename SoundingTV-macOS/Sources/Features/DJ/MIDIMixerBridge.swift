import Combine
import Foundation

@MainActor
final class MIDIMixerBridge {
    static let shared = MIDIMixerBridge()

    private var subscription: AnyCancellable?

    private var jogBaseRate: [Int: Double] = [:]
    private var jogDecayTask: [Int: Task<Void, Never>] = [:]

    private var pendingLoopIn: [Int: Double] = [:]

    private init() {}

    func start() {
        guard subscription == nil else { return }
        subscription = MIDIControllerHub.shared.events.sink { [weak self] event in
            self?.handle(event)
        }
    }

    private var engine: MixEngine { MixEngine.shared }
    private var console: MacConsoleController { MacConsoleController.shared }

    private func handle(_ event: ControlEvent) {
        switch event {
        case .absolute(let id, let value): handleAbsolute(id, value)
        case .relative(let id, let ticks): handleRelative(id, ticks)
        case .button(let id, let isDown, _): handleButton(id, isDown: isDown)
        case .touch(let id, let isTouching): handleTouch(id, isTouching: isTouching)
        }
    }

    private func handleAbsolute(_ id: ControlID, _ value: Double) {
        guard let deck = id.deck else {
            if id.surface == .crossfader { engine.crossfade = value }
            return
        }
        switch id.surface {
        case .eqLow:  engine.setEQ(.low,  on: deck, toDecibels: MacDeckUnits.eqDecibels(fromKnob: value))
        case .eqMid:  engine.setEQ(.mid,  on: deck, toDecibels: MacDeckUnits.eqDecibels(fromKnob: value))
        case .eqHigh: engine.setEQ(.high, on: deck, toDecibels: MacDeckUnits.eqDecibels(fromKnob: value))
        case .filter: engine.setFilterCutoff(MacDeckUnits.filterHertz(fromKnob: value), on: deck)
        case .tempo:  console.setTempo(deck, knobValue: value)
        case .lineFader:
            engine.setGain(value, on: deck)
        case .trim, .crossfader, .jog, .play, .cue, .sync, .hotCue, .loopIn, .loopOut, .loopToggle, .browse, .load:
            break
        }
    }

    private func handleRelative(_ id: ControlID, _ ticks: Double) {
        guard id.surface == .jog, let deck = id.deck else { return }
        applyJogBend(deck, ticks: ticks)
    }

    private func handleTouch(_ id: ControlID, isTouching: Bool) {
        guard id.surface == .jog, let deck = id.deck else { return }
        if !isTouching { scheduleJogDecay(deck) }
    }

    private static let maxBendFraction = 0.08
    private static let ticksForMaxBend = 64.0
    private static let idleDecayNanoseconds: UInt64 = 120_000_000
    private static let decaySeconds = 0.25

    private func applyJogBend(_ deck: MixEngine.Deck, ticks: Double) {
        let key = deck.rawValue
        jogDecayTask[key]?.cancel()
        jogDecayTask[key] = nil

        let base = jogBaseRate[key] ?? engine[deck].rate
        jogBaseRate[key] = base

        let bend = (ticks / Self.ticksForMaxBend).macClamped(to: -1...1) * Self.maxBendFraction
        let bent = (base * (1 + bend)).macClamped(to: MixEngine.rateRange)
        engine.setRate(bent, on: deck, over: 0)

        scheduleJogDecay(deck, afterIdle: true)
    }

    private func scheduleJogDecay(_ deck: MixEngine.Deck, afterIdle: Bool = false) {
        let key = deck.rawValue
        jogDecayTask[key]?.cancel()
        jogDecayTask[key] = Task { @MainActor [weak self] in
            guard let self else { return }
            if afterIdle {
                try? await Task.sleep(nanoseconds: Self.idleDecayNanoseconds)
                guard !Task.isCancelled else { return }
            }
            guard let base = self.jogBaseRate[key] else { return }
            self.engine.setRate(base, on: deck, over: Self.decaySeconds)
            self.jogBaseRate[key] = nil
            self.jogDecayTask[key] = nil
        }
    }

    private func handleButton(_ id: ControlID, isDown: Bool) {
        if id.surface == .hotCue, let deck = id.deck {
            if isDown { console.hotCue(deck, index: id.index) }
            return
        }
        guard let deck = id.deck else { return }
        switch id.surface {
        case .play:
            if isDown { console.togglePlayPause(deck) }
        case .cue:
            isDown ? console.cueDown(deck) : console.cueUp(deck)
        case .loopToggle:
            if isDown { console.toggleLoop(deck) }
        case .loopIn:
            if isDown { pendingLoopIn[deck.rawValue] = engine[deck].position }
        case .loopOut:
            if isDown { closeLoop(deck) }
        default:
            break
        }
    }

    private func closeLoop(_ deck: MixEngine.Deck) {
        guard let start = pendingLoopIn[deck.rawValue] else { return }
        pendingLoopIn[deck.rawValue] = nil
        let length = engine[deck].position - start
        guard length > 0.05 else { return }
        engine.setLoop(on: deck, startSeconds: start, lengthSeconds: length)
    }
}
