import Foundation

extension MixEngine {
    struct DeckFX: Equatable, Sendable {
        var kind: MixFXKind = .echo
        var beats: Double = 0.5
        var amount: Double = 0.5
        var isOn = false

        static let beatChoices: [Double] = [0.25, 0.5, 0.75, 1, 2, 4]
    }

    struct MixerState: Equatable, Sendable {
        var cue: [Bool] = [false, false]
        var cueMix: Double = 0
        var phonesLevel: Double = 0.5
        var splitCue = false
        var crossfaderCurve: DJCrossfaderCurve = .smooth
        var faderCurve: DJChannelFaderCurve = .linear
        var fx: [DeckFX] = [DeckFX(), DeckFX(kind: .reverb, beats: 1)]

        func cue(_ deck: Deck) -> Bool { cue[deck.rawValue] }
        func fx(_ deck: Deck) -> DeckFX { fx[deck.rawValue] }
    }

    struct AutomationTarget: Equatable, Sendable {
        var value: Double
        var startsAt: TimeInterval
        var endsAt: TimeInterval
    }

    struct Meters: Equatable, Sendable {
        var a = MixMeterReading()
        var b = MixMeterReading()
        var master = MixMeterReading()
        var masterLeft = MixMeterReading()
        var masterRight = MixMeterReading()
        var phones = MixMeterReading()

        func deck(_ deck: Deck) -> MixMeterReading { deck == .a ? a : b }
    }

    // MARK: - Cue and phones

    func setCue(_ isOn: Bool, on deck: Deck) {
        mixer.cue[deck.rawValue] = isOn
        ramp(.cue(deck.rawValue), to: isOn ? 1 : 0, over: 0)
    }

    func setCueMix(_ value: Double) {
        mixer.cueMix = min(1, max(0, value))
        ramp(.cueMix, to: mixer.cueMix, over: 0)
    }

    func setPhonesLevel(_ value: Double) {
        mixer.phonesLevel = min(1, max(0, value))
        ramp(.phonesLevel, to: mixer.phonesLevel, over: 0)
    }

    func setSplitCue(_ isOn: Bool) {
        mixer.splitCue = isOn
        ramp(.splitCue, to: isOn ? 1 : 0, over: 0.02)
    }

    func setCrossfaderCurve(_ curve: DJCrossfaderCurve) {
        mixer.crossfaderCurve = curve
        ramp(.crossfaderShape, to: curve.shape, over: 0)
    }

    func setChannelFaderCurve(_ curve: DJChannelFaderCurve) {
        mixer.faderCurve = curve
    }

    // MARK: - Deck FX

    func setDeckFX(_ kind: MixFXKind, beats: Double, on deck: Deck) {
        var fx = mixer.fx[deck.rawValue]
        fx.kind = kind
        fx.beats = beats
        mixer.fx[deck.rawValue] = fx
        applyDeckFX(on: deck)
    }

    func setDeckFXAmount(_ amount: Double, on deck: Deck) {
        mixer.fx[deck.rawValue].amount = min(1, max(0, amount))
        applyDeckFXLevels(on: deck)
    }

    func setDeckFXEnabled(_ isOn: Bool, on deck: Deck) {
        mixer.fx[deck.rawValue].isOn = isOn
        applyDeckFXLevels(on: deck)
    }

    func deckFXPeriodSeconds(beats: Double, on deck: Deck) -> TimeInterval {
        let beat = beatGrid(for: deck)?.beatPeriod ?? 0.5
        return max(0.02, beats * beat / max(0.05, decks[deck.rawValue].rate))
    }

    func refreshDeckFXTiming(on deck: Deck) {
        let fx = mixer.fx[deck.rawValue]
        guard fx.kind.isBuiltIn else { return }
        post(.deckFX(
            deck: deck.rawValue,
            kind: fx.kind.rawValue,
            periodSeconds: deckFXPeriodSeconds(beats: fx.beats, on: deck),
            feedback: 0.5
        ))
    }

    private func applyDeckFX(on deck: Deck) {
        let fx = mixer.fx[deck.rawValue]
        post(.deckFX(
            deck: deck.rawValue,
            kind: fx.kind.isBuiltIn ? fx.kind.rawValue : 0,
            periodSeconds: deckFXPeriodSeconds(beats: fx.beats, on: deck),
            feedback: 0.5
        ))
        applyDeckFXLevels(on: deck)
    }

    private func applyDeckFXLevels(on deck: Deck) {
        let fx = mixer.fx[deck.rawValue]
        let d = deck.rawValue
        if fx.kind.isBuiltIn {
            ramp(.fxWet(d), to: fx.amount, over: 0)
            ramp(.fxSend(d), to: fx.isOn ? 1 : 0, over: 0)
        } else {
            ramp(.fxSend(d), to: 0, over: 0)
            if effects[.deck(deck)] != nil {
                ramp(.insertMix(d), to: fx.isOn ? fx.amount : 0, over: 0)
            }
        }
    }

    // MARK: - Meters

    func takeMeters() -> Meters {
        Meters(
            a: core.meters.take(.deckA),
            b: core.meters.take(.deckB),
            master: core.meters.take(.master),
            masterLeft: core.meters.take(.masterLeft),
            masterRight: core.meters.take(.masterRight),
            phones: core.meters.take(.phones)
        )
    }

    // MARK: - Automation

    func recordLiveRamp(_ parameter: MixParameter, to value: Double, over duration: TimeInterval) {
        guard duration > 0.01 else {
            liveRamps[parameter.raw] = nil
            return
        }
        let now = clockSeconds
        liveRamps[parameter.raw] = AutomationTarget(value: value, startsAt: now, endsAt: now + duration)
    }

    func clearAutomation(_ parameter: MixParameter) {
        liveRamps[parameter.raw] = nil
    }

    func automationTarget(for parameter: MixParameter) -> AutomationTarget? {
        let now = clockSeconds
        var best: AutomationTarget?
        func consider(_ target: AutomationTarget) {
            guard target.endsAt > now else { return }
            if let current = best, current.startsAt <= target.startsAt { return }
            best = target
        }
        if let live = liveRamps[parameter.raw] {
            if live.endsAt > now { consider(live) } else { liveRamps[parameter.raw] = nil }
        }
        for (group, timeline) in scheduledTimelines {
            guard let anchor = anchorClockSeconds(for: group) ?? estimatedAnchor(timeline.anchor, now: now) else { continue }
            if anchor + Double(timeline.lengthFrames) / sampleRate + 1 < now {
                scheduledTimelines[group] = nil
                continue
            }
            for event in timeline.events {
                guard case .ramp(let target, let value, let frames, _) = event.action, target == parameter else { continue }
                let start = anchor + Double(event.offset) / sampleRate
                consider(AutomationTarget(value: value, startsAt: start, endsAt: start + Double(max(frames, 1)) / sampleRate))
            }
        }
        return best
    }

    private func estimatedAnchor(_ anchor: MixTimelineAnchor, now: TimeInterval) -> TimeInterval? {
        switch anchor {
        case .now:
            return nil
        case .clock(let frames):
            return Double(frames) / sampleRate
        case .deckPosition(let index, let frame):
            guard let deck = Deck(rawValue: index), decks[index].isPlaying else { return nil }
            let rate = max(0.05, decks[index].rate)
            return now + (frame / sampleRate - livePosition(of: deck)) / rate
        }
    }
}
