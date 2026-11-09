import Foundation

@MainActor
final class MacDeckControlSurface: DeckControlSurface {
    static let shared = MacDeckControlSurface()

    private var engine: MixEngine { MixEngine.shared }
    private var console: MacConsoleController { MacConsoleController.shared }

    private var jogBaseRate: [Int: Double] = [:]
    private var jogDecayTask: [Int: Task<Void, Never>] = [:]
    private var pendingLoopIn: [Int: Double] = [:]

    private init() {}

    func start() {
        DJControllerHub.shared.attach(
            surface: self,
            access: { Self.access },
            content: { deck in ControllerDeckContent(source: MacDeckTrackRegistry.shared.track(for: deck)?.source) }
        )
        DJControllerHub.shared.start()
    }

    static var access: ControllerDeckAccess {
        ControllerDeckAccess(allowsStreaming: djDenial(.controllers, isSoundCloudTrack: true) == nil)
    }

    static func djDenial(_ feature: DJGearFeature, source: TrackSource?) -> SoundCloudEntitlementError? {
        guard case .soundCloud? = source else { return nil }
        return djDenial(feature, isSoundCloudTrack: true)
    }

    static func djDenial(_ feature: DJGearFeature, isSoundCloudTrack: Bool) -> SoundCloudEntitlementError? {
        #if SOUNDING_PERSONAL
        let unlocked = PersonalCodeLock.live().isUnlocked
        #else
        let unlocked = false
        #endif
        return SubscriptionService.shared.djGearDenial(feature, isSoundCloudTrack: isSoundCloudTrack, personalUnlocked: unlocked)
    }

    // MARK: DeckControlSurface

    func value(of address: DeckControlAddress) -> Double? {
        guard let deck = address.group.deck else {
            switch address.control {
            case .crossfader: return engine.crossfade
            case .masterLevel: return DJMixerUnits.levelKnob(gain: engine.masterVolume)
            case .cueMix: return engine.mixer.cueMix
            case .phonesLevel: return DJMixerUnits.levelKnob(gain: engine.mixer.phonesLevel)
            default: return nil
            }
        }
        let state = engine[deck]
        switch address.control {
        case .play: return state.isPlaying ? 1 : 0
        case .loopToggle: return state.loopStartSeconds != nil ? 1 : 0
        case .cue: return console.cuePreviewing[deck.rawValue] == true ? 1 : 0
        case .hotCue:
            return console.hotCues[deck.rawValue]?.contains { $0.hotCueIndex == address.index } == true ? 1 : 0
        case .eqLow: return DJMixerUnits.eqKnob(decibels: state.low)
        case .eqMid: return DJMixerUnits.eqKnob(decibels: state.mid)
        case .eqHigh: return DJMixerUnits.eqKnob(decibels: state.high)
        case .filter: return DJMixerUnits.bipolarFilterKnob(lowPass: state.filterCutoff, highPass: state.highPassCutoff)
        case .volume: return engine.mixer.faderCurve.position(gain: state.gain)
        case .trim: return DJMixerUnits.trimKnob(decibels: state.inputGain)
        case .headphoneCue: return engine.mixer.cue(deck) ? 1 : 0
        case .fxToggle: return engine.mixer.fx(deck).isOn ? 1 : 0
        case .fxAmount: return engine.mixer.fx(deck).amount
        case .tempo: return DJMixerUnits.tempoKnob(rate: state.rate)
        case .echo: return state.delayWet > 0.02 ? 1 : 0
        case .sync, .jog, .jogTouch, .loopIn, .loopOut, .loopHalve, .loopDouble, .crossfader,
             .masterLevel, .cueMix, .phonesLevel:
            return nil
        }
    }

    func setValue(_ value: Double, for address: DeckControlAddress) {
        if let control = address.mixControl { MacDJPerformModel.shared.grab(control) }
        engine.asUser { apply(value, for: address) }
    }

    private func apply(_ value: Double, for address: DeckControlAddress) {
        guard let deck = address.group.deck else {
            switch address.control {
            case .crossfader:
                engine.clearAutomation(.crossfade)
                engine.crossfade = value
            case .masterLevel:
                engine.clearAutomation(.master)
                engine.masterVolume = DJMixerUnits.levelGain(knob: value)
            case .cueMix: engine.setCueMix(value)
            case .phonesLevel: engine.setPhonesLevel(DJMixerUnits.levelGain(knob: value))
            default: break
            }
            return
        }
        switch address.control {
        case .eqLow: engine.setEQ(.low, on: deck, toDecibels: DJMixerUnits.eqDecibels(knob: value))
        case .eqMid: engine.setEQ(.mid, on: deck, toDecibels: DJMixerUnits.eqDecibels(knob: value))
        case .eqHigh: engine.setEQ(.high, on: deck, toDecibels: DJMixerUnits.eqDecibels(knob: value))
        case .filter:
            let filter = DJMixerUnits.bipolarFilter(knob: value)
            engine.setFilterCutoff(filter.lowPass, on: deck)
            engine.setHighPassCutoff(filter.highPass, on: deck)
        case .tempo: console.setTempo(deck, knobValue: value)
        case .volume: engine.setGain(engine.mixer.faderCurve.gain(position: value), on: deck)
        case .trim: engine.setInputGain(DJMixerUnits.trimDecibels(knob: value), on: deck)
        case .fxAmount: engine.setDeckFXAmount(value, on: deck)
        default: break
        }
    }

    func press(_ address: DeckControlAddress, isDown: Bool) {
        guard let deck = address.group.deck else { return }
        switch address.control {
        case .play: if isDown { console.togglePlayPause(deck) }
        case .cue: isDown ? console.cueDown(deck) : console.cueUp(deck)
        case .sync: if isDown { console.sync(deck) }
        case .hotCue: if isDown { console.hotCue(deck, index: address.index) }
        case .loopToggle: if isDown { console.toggleLoop(deck) }
        case .loopHalve: if isDown { console.halveLoop(deck) }
        case .loopDouble: if isDown { console.doubleLoop(deck) }
        case .loopIn: if isDown { pendingLoopIn[deck.rawValue] = engine[deck].position }
        case .loopOut: if isDown { closeLoop(deck) }
        case .echo: if isDown { console.toggleEcho(deck) }
        case .headphoneCue: if isDown { engine.setCue(!engine.mixer.cue(deck), on: deck) }
        case .fxToggle: if isDown { engine.setDeckFXEnabled(!engine.mixer.fx(deck).isOn, on: deck) }
        case .jogTouch: if !isDown { scheduleJogDecay(deck) }
        default: break
        }
    }

    func jog(_ group: DeckGroup, ticks: Double) {
        guard let deck = group.deck else { return }
        let key = deck.rawValue
        jogDecayTask[key]?.cancel()
        jogDecayTask[key] = nil

        let base = jogBaseRate[key] ?? engine[deck].rate
        jogBaseRate[key] = base

        let bend = (ticks / Self.ticksForMaxBend).macClamped(to: -1...1) * Self.maxBendFraction
        engine.setRate((base * (1 + bend)).macClamped(to: MixEngine.rateRange), on: deck, over: 0)
        scheduleJogDecay(deck, afterIdle: true)
    }

    // MARK: Jog and loops

    private static let maxBendFraction = 0.08
    private static let ticksForMaxBend = 64.0
    private static let idleDecayNanoseconds: UInt64 = 120_000_000
    private static let decaySeconds = 0.25

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

    private func closeLoop(_ deck: MixEngine.Deck) {
        guard let start = pendingLoopIn[deck.rawValue] else { return }
        pendingLoopIn[deck.rawValue] = nil
        let length = engine[deck].position - start
        guard length > 0.05 else { return }
        engine.setLoop(on: deck, startSeconds: start, lengthSeconds: length)
    }
}
