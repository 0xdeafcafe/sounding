import SwiftUI

@MainActor
final class DeckHandBack {
    private var pending: [MixControl?: Task<Void, Never>] = [:]
    private var engine: MixEngine { .shared }

    var liveDeck: MixEngine.Deck {
        PlayerService.shared.djDirector.snapshot?.liveDeck ?? (engine.crossfade < 0.5 ? .a : .b)
    }

    func grab(_ control: MixControl) {
        for key in [control, nil] as [MixControl?] {
            pending.removeValue(forKey: key)?.cancel()
        }
        engine.takeOver(control)
    }

    func handBack(_ control: MixControl) {
        onNextBeat(of: control.deck ?? liveDeck, key: control) { [engine] in engine.handBack(control) }
    }

    func handBackAll() {
        onNextBeat(of: liveDeck, key: nil) { [engine] in engine.handBackAll() }
    }

    nonisolated static func secondsToNextBeat(grid: BeatGrid?, position: Double, rate: Double, isPlaying: Bool) -> TimeInterval? {
        guard isPlaying, let grid, grid.beatPeriod > 0, rate > 0 else { return nil }
        let beats = (position - grid.anchor) / grid.beatPeriod
        let next = grid.anchor + (beats + 0.02).rounded(.up) * grid.beatPeriod
        let delay = (next - position) / rate
        return delay.isFinite && delay >= 0 ? delay : nil
    }

    private func onNextBeat(of deck: MixEngine.Deck, key: MixControl?, _ action: @escaping @MainActor () -> Void) {
        let s = engine[deck]
        guard let delay = Self.secondsToNextBeat(grid: engine.beatGrid(for: deck), position: s.position, rate: s.rate, isPlaying: s.isPlaying) else {
            action()
            return
        }
        pending[key]?.cancel()
        pending[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.pending[key] = nil
            action()
        }
    }
}

extension DeckControlAddress {
    var mixControl: MixControl? {
        let deck = group.deck
        switch control {
        case .crossfader: return .crossfader
        case .eqLow: return MixControl(.low, deck: deck)
        case .eqMid: return MixControl(.mid, deck: deck)
        case .eqHigh: return MixControl(.high, deck: deck)
        case .filter: return MixControl(.filter, deck: deck)
        case .volume: return MixControl(.volume, deck: deck)
        case .tempo: return MixControl(.tempo, deck: deck)
        case .trim: return MixControl(.trim, deck: deck)
        default: return nil
        }
    }
}

extension MacDJPerformState {
    func valueText(_ control: MixControl) -> String {
        let knob = self.value(control)
        switch control.kind {
        case .filter:
            let hertz = DJMixerUnits.bipolarFilter(knob: knob)
            return DJMixerUnits.filterLabel(lowPass: hertz.lowPass, highPass: hertz.highPass)
        case .high, .mid, .low: return DJMixerUnits.decibelLabel(DJMixerUnits.eqDecibels(knob: knob))
        case .trim: return DJMixerUnits.decibelLabel(DJMixerUnits.trimDecibels(knob: knob))
        case .volume, .crossfader, .echo: return "\(Int((knob * 100).rounded()))%"
        case .tempo: return String(format: "%+.1f%%", (knob * 2 - 1) * DJMixerUnits.tempoRange * 100)
        }
    }
}

extension MacDJMixState {
    init(live: AutoMixLiveState, at date: Date, leaving liveDeck: MixEngine.Deck) {
        let sections = live.sections
        let clock = live.clock(at: date)
        self.init(
            leaving: liveDeck,
            steps: sections.enumerated().map { index, section in
                MacDJStep(label: Self.stepLabel(section, index: index, all: sections), fromBar: section.startBar + 1, toBar: section.endBar + 1)
            },
            nowBar: live.stage == .upcoming ? live.barsFromStart(at: date) + 1 : clock.barInMove + 1,
            totalBars: Double(max(1, live.lengthBars)),
            enteringNote: "Cued \u{00B7} \(live.incomingTitle)"
        )
        loops = sections.filter { $0.role == .loop }.map {
            let bars = Int(($0.endBar - $0.startBar).rounded(.up))
            return MacDJLaneLoop(fromBar: $0.startBar + 1, toBar: $0.endBar + 1, label: "Loop \(bars == 1 ? "1 bar" : "\(bars) bars")")
        }
        fadeOutFromBar = sections.last { $0.role == .fadeOut }.map { $0.startBar + 1 }
        if let out = live.outgoing, let inn = live.incoming, let beat = out.beatSeconds, let inBeat = inn.beatSeconds, beat > 0, inBeat > 0 {
            let a = (out.positionSeconds - (out.downbeatSeconds ?? 0)) / beat
            let b = (inn.positionSeconds - (inn.downbeatSeconds ?? 0)) / inBeat
            let error = (a - b - (a - b).rounded()) * beat * 1000
            let ms = Int(abs(error).rounded())
            phase = MacDJPhase(text: ms <= 5 ? "In phase \u{00B7} \(ms) ms" : "\(ms) ms \(error > 0 ? "ahead" : "behind")", isKnown: true, beat: Int(a.rounded(.down)) % 4)
        } else {
            phase = MacDJPhase(text: "Phase: unknown", isKnown: false, beat: 0)
        }
        if live.stage == .upcoming { countdown = clock.countdownText }
    }

    static func stepLabel(_ section: AutoMixLiveState.Section, index: Int, all: [AutoMixLiveState.Section]) -> String {
        switch section.role {
        case .loop: return index == 0 ? "Match & loop" : section.label
        case .release:
            let hasSwap = all.contains { $0.label == "Swap" }
            return hasSwap && section.label != "Swap" ? "Release & bass swap" : (section.label == "Swap" ? "Bass swap" : "Release")
        default: return section.label
        }
    }
}
