import Foundation

@MainActor
final class PhoneDeckControlSurface: DeckControlSurface {
    weak var model: PhoneDecksModel?

    private var engine: MixEngine { MixEngine.shared }
    private var cueAnchor: [MixEngine.Deck: Double] = [:]
    private(set) var cuePreviewing: Set<MixEngine.Deck> = []
    var loopBars: [MixEngine.Deck: Double] = [.a: 4, .b: 4]

    func value(of address: DeckControlAddress) -> Double? {
        guard let deck = address.group.deck else {
            return address.control == .crossfader ? engine.crossfade : nil
        }
        let state = engine[deck]
        switch address.control {
        case .play: return state.isPlaying ? 1 : 0
        case .cue: return cuePreviewing.contains(deck) ? 1 : 0
        case .loopToggle: return state.loopStartSeconds != nil ? 1 : 0
        case .hotCue: return model?.hotCue(address.index, on: deck) != nil ? 1 : 0
        case .eqLow: return DJMixerUnits.eqKnob(decibels: state.low)
        case .eqMid: return DJMixerUnits.eqKnob(decibels: state.mid)
        case .eqHigh: return DJMixerUnits.eqKnob(decibels: state.high)
        case .filter: return DJMixerUnits.bipolarFilterKnob(lowPass: state.filterCutoff, highPass: state.highPassCutoff)
        case .volume: return engine.mixer.faderCurve.position(gain: state.gain)
        case .trim: return DJMixerUnits.trimKnob(decibels: state.inputGain)
        case .tempo: return DJMixerUnits.tempoKnob(rate: state.rate)
        default: return nil
        }
    }

    func setValue(_ value: Double, for address: DeckControlAddress) {
        if let deck = address.group.deck, model?.isViewOnly(deck) == true { return }
        if let control = address.mixControl { model?.grab(control) }
        engine.asUser {
            guard let deck = address.group.deck else {
                if address.control == .crossfader {
                    engine.clearAutomation(.crossfade)
                    engine.crossfade = value
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
            case .volume: engine.setGain(engine.mixer.faderCurve.gain(position: value), on: deck)
            case .trim: engine.setInputGain(DJMixerUnits.trimDecibels(knob: value), on: deck)
            case .tempo: engine.setRate(DJMixerUnits.tempoRate(knob: value), on: deck)
            default: break
            }
        }
    }

    func press(_ address: DeckControlAddress, isDown: Bool) {
        guard let deck = address.group.deck, model?.isViewOnly(deck) != true else { return }
        let ready = engine[deck].status.isReady
        switch address.control {
        case .play:
            guard isDown, ready else { return }
            cuePreviewing.remove(deck)
            engine.togglePlayPause(deck: deck)
        case .cue:
            guard ready else { return }
            isDown ? cueDown(deck) : cueUp(deck)
        case .sync: if isDown { _ = sync(deck) }
        case .hotCue: if isDown { hotCue(deck, index: address.index) }
        case .loopToggle: if isDown { toggleLoop(deck) }
        case .loopHalve: if isDown { setLoopBars((loopBars[deck] ?? 4) / 2, on: deck) }
        case .loopDouble: if isDown { setLoopBars((loopBars[deck] ?? 4) * 2, on: deck) }
        default: break
        }
    }

    func jog(_ group: DeckGroup, ticks: Double) {}

    // MARK: Transport

    private func cueDown(_ deck: MixEngine.Deck) {
        if engine[deck].isPlaying {
            engine.pause(deck: deck)
            engine.seek(deck: deck, to: cueAnchor[deck] ?? 0)
        } else {
            cueAnchor[deck] = engine[deck].position
            cuePreviewing.insert(deck)
            engine.play(deck: deck)
        }
    }

    private func cueUp(_ deck: MixEngine.Deck) {
        guard cuePreviewing.remove(deck) != nil else { return }
        engine.pause(deck: deck)
        engine.seek(deck: deck, to: cueAnchor[deck] ?? 0)
    }

    func sync(_ deck: MixEngine.Deck) -> Bool {
        let reference = deck.other
        guard model?.isViewOnly(deck) != true, engine[deck].status.isReady, engine[reference].status.isReady else { return false }
        if engine.sync(deck, to: reference) { return true }
        guard let source = model?.bpm(deck), let target = model?.bpm(reference) else { return false }
        return engine.matchTempo(on: deck, sourceBPM: source, targetBPM: target * engine[reference].rate, over: 0.08)
    }

    private func hotCue(_ deck: MixEngine.Deck, index: Int) {
        guard let trackId = engine[deck].trackId else { return }
        if let cue = model?.hotCue(index, on: deck) {
            engine.seek(deck: deck, to: cue.positionSeconds)
            if !engine[deck].isPlaying { engine.play(deck: deck) }
            return
        }
        let millis = Int64(engine[deck].position * 1000)
        Task { [weak model] in
            _ = await CueStore.shared.setHotCue(trackId: trackId, index: index, positionMillis: millis)
            await model?.refreshHotCues(deck)
        }
    }

    private func barSeconds(_ deck: MixEngine.Deck) -> Double {
        engine.beatGrid(for: deck)?.barDuration ?? model?.bpm(deck).map { 240 / $0 } ?? 2
    }

    private func toggleLoop(_ deck: MixEngine.Deck) {
        guard engine[deck].status.isReady else { return }
        if engine[deck].loopStartSeconds != nil {
            engine.clearLoop(on: deck)
        } else {
            startLoop(deck, bars: loopBars[deck] ?? 4)
        }
    }

    func setLoopBars(_ bars: Double, on deck: MixEngine.Deck) {
        let clamped = min(32, max(0.25, bars))
        loopBars[deck] = clamped
        guard engine[deck].status.isReady else { return }
        if let start = engine[deck].loopStartSeconds {
            engine.setLoop(on: deck, startSeconds: start, lengthSeconds: clamped * barSeconds(deck))
        } else {
            startLoop(deck, bars: clamped)
        }
    }

    private func startLoop(_ deck: MixEngine.Deck, bars: Double) {
        if let grid = engine.beatGrid(for: deck), grid.beatPeriod > 0 {
            engine.setQuantizedLoop(on: deck, near: engine[deck].position, beats: bars * 4)
        } else {
            engine.setLoop(on: deck, startSeconds: engine[deck].position, lengthSeconds: bars * barSeconds(deck))
        }
    }
}
