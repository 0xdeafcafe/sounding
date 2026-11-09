import SwiftUI

#if DEBUG
enum MacDJFixtures {
    private static let bar = 60.0 / 124 * 4
    private typealias Cue = MacDJPalette.Cue

    static func state(named name: String) -> MacDJPerformState? {
        switch name {
        case "automix", "collapsed": return automix()
        case "takeover", "collapsed-takeover": return takeover()
        case "soundcloud": return soundcloud()
        case "states": return automix()
        default: return nil
        }
    }

    private static func phrases(_ sections: [(Double, Color)], total: Double) -> [MacDJPhraseBar] {
        sections.enumerated().map { index, section in
            let end = index + 1 < sections.count ? sections[index + 1].0 : total
            return MacDJPhraseBar(start: section.0 / total, end: end / total, color: section.1)
        }
    }

    private static var deckA: MacDJDeckState {
        var d = MacDJDeckState(deck: .a, trackId: "fixture.glass", title: "Glass District", artist: "Night Tapes")
        d.bpm = 124
        d.key = "8A"
        d.position = 101.5 * bar
        d.duration = 101.5 * bar + 21
        d.isPlaying = true
        d.role = .onAir
        d.isMaster = true
        d.barReadout = "101.2"
        d.jogAngle = 2.1
        d.loopBars = 4
        d.statusTitle = "On air"
        d.statusDetail = "Filter out in 7 bars"
        d.padNote = "F is the mix out"
        d.barSeconds = bar
        d.samples = [0.5]
        d.cues = [
            MacDJCue(index: 0, label: "Intro", seconds: 0, color: Cue.green),
            MacDJCue(index: 1, label: "Up", seconds: 31, color: Cue.pink),
            MacDJCue(index: 2, label: "Chorus", seconds: 62, color: Cue.red),
            MacDJCue(index: 3, label: "Down", seconds: 93, color: Cue.purple),
            MacDJCue(index: 4, label: "Chorus 2", seconds: 124, color: Cue.red),
            MacDJCue(index: 5, label: "Outro", seconds: 180, color: Cue.cyan)
        ]
        d.phrases = phrases([(0, Cue.blue), (16, Cue.pink), (32, Cue.red), (48, Cue.purple), (64, Cue.red), (93, Cue.mint)], total: 112)
        return d
    }

    private static var deckB: MacDJDeckState {
        var d = MacDJDeckState(deck: .b, trackId: "fixture.low", title: "Low Sun", artist: "Maya Sol")
        d.bpm = 123
        d.pitchPercent = 0.8
        d.key = "9A"
        d.keyColor = Color(red: 0.56, green: 0.89, blue: 0.66)
        d.position = 2.4 * bar
        d.duration = 2.4 * bar + 312
        d.isPlaying = true
        d.role = .mixingIn
        d.isSynced = true
        d.barReadout = "2.2"
        d.jogAngle = 4.4
        d.loopBars = 4
        d.isLooping = true
        d.tempo = -0.1
        d.statusTitle = "Mixing in"
        d.statusDetail = "Release in 3 bars"
        d.padNote = "Auto Mix is looping"
        d.barSeconds = bar
        d.samples = [0.5]
        d.cues = [
            MacDJCue(index: 0, label: "Intro", seconds: 0, color: Cue.green),
            MacDJCue(index: 1, label: "Up", seconds: 16 * bar, color: Cue.pink),
            MacDJCue(index: 2, label: "Build", seconds: 24 * bar, color: Cue.red),
            MacDJCue(index: 3, label: "Down", seconds: 56 * bar, color: Cue.purple),
            MacDJCue(index: 4, label: "Drop", seconds: 72 * bar, color: Cue.red),
            MacDJCue(index: 7, label: "Outro", seconds: 104 * bar, color: Cue.blue)
        ]
        d.phrases = phrases([(0, Cue.blue), (16, Cue.pink), (19, Cue.red), (56, Cue.purple), (72, Cue.red), (104, Cue.mint)], total: 164)
        return d
    }

    private static var mix: MacDJMixState {
        var mix = MacDJMixState(
            leaving: .a,
            steps: [
                MacDJStep(label: "Match & loop", fromBar: 1, toBar: 5),
                MacDJStep(label: "Fade in", fromBar: 5, toBar: 9),
                MacDJStep(label: "Release & bass swap", fromBar: 9, toBar: 13),
                MacDJStep(label: "Filter out", fromBar: 13, toBar: 17)
            ],
            nowBar: 6.45,
            totalBars: 16,
            enteringNote: "Cued at A \u{00B7} Intro"
        )
        mix.loops = [MacDJLaneLoop(fromBar: 1, toBar: 5, label: "Loop 4 bars"), MacDJLaneLoop(fromBar: 5, toBar: 9, label: "Repeat 2")]
        mix.leavingLabel = "Outro \u{00B7} no vocals"
        mix.leavingLabelBar = -1.65
        mix.enteringLabel = "Intro \u{00B7} no vocals"
        mix.enteringLabelBar = 9.1
        mix.mixOutCue = ("F Outro", -2, Cue.cyan)
        mix.mixOutMarkerBar = 1
        mix.fadeOutFromBar = 13
        mix.phase = MacDJPhase(text: "In phase \u{00B7} 0 ms", isKnown: true, beat: 1)
        return mix
    }

    private static func control(_ kind: MixControl.Kind, _ deck: MixEngine.Deck) -> MixControl { MixControl(kind, deck: deck) }

    static func automix() -> MacDJPerformState {
        var state = MacDJPerformState(decks: [deckA, deckB])
        state.mix = mix
        state.isAutoMixDriving = true
        state.mixerLabel = "Auto Mix \u{00B7} moving controls"
        state.values = [
            control(.trim, .a): 0.5, control(.trim, .b): 0.54,
            control(.high, .a): 0.5, control(.high, .b): 0.38,
            control(.mid, .a): 0.5, control(.mid, .b): 0.5,
            control(.low, .a): 0.5, control(.low, .b): 0.05,
            control(.filter, .a): 0.5, control(.filter, .b): 0.63,
            control(.volume, .a): 1, control(.volume, .b): 0.62,
            control(.tempo, .a): 0.5, control(.tempo, .b): 0.45,
            .crossfader: 0.5
        ]
        state.targets = [
            control(.high, .b): MacDJTarget(value: 0.5, label: "0 dB in 3 bars"),
            control(.low, .a): MacDJTarget(value: 0.04, label: "Cut in 6 bars"),
            control(.low, .b): MacDJTarget(value: 0.5, label: "In in 6 bars"),
            control(.filter, .a): MacDJTarget(value: 0.8, label: "HPF in 7 bars"),
            control(.filter, .b): MacDJTarget(value: 0.5, label: "Off in 3 bars"),
            control(.volume, .b): MacDJTarget(value: 1, label: nil),
            .crossfader: MacDJTarget(value: 0.62, label: nil)
        ]
        state.levels = [.a: 0.72, .b: 0.5]
        state.masterLevel = 0.7
        state.panel = MacDJPanelState(
            isAutoMixOn: true,
            stageChip: "Mixing \u{00B7} bar 6 of 16",
            timeLeft: "0:19 left",
            headline: "Bringing in Low Sun",
            subline: "Fade in \u{00B7} releases in 3 bars (0:06)",
            from: MacDJPlanRow(deck: .a, title: "Glass District", section: "outro", detail: "Bar 96 \u{00B7} memory cue Mix Out"),
            enter: MacDJPlanRow(deck: .b, title: "Low Sun", section: "intro", detail: "Cue A \u{00B7} 4-bar loop"),
            move: "Loop B, fade it in, release, swap the bass, filter A out.",
            why: [
                MacDJWhy(title: "Adjacent key \u{00B7} 8A \u{2192} 9A", detail: "123 \u{2192} 124 BPM \u{00B7} key lock on"),
                MacDJWhy(title: "Space for the blend", detail: "Both sides sparse \u{00B7} no vocals"),
                MacDJWhy(title: "A small lift \u{00B7} energy 6 \u{2192} 7", detail: "After Glass District\u{2019}s last chorus")
            ],
            next: MacDJNext(title: "Soft Static", detail: "Juno Vale \u{00B7} 9A \u{00B7} 125 \u{00B7} loads on A", artworkURL: nil, identity: "fixture.soft"),
            footer: "Club \u{00B7} Normal blend",
            canExtend: true
        )
        return state
    }

    static func takeover() -> MacDJPerformState {
        var state = automix()
        let filterB = control(.filter, .b)
        state.values[filterB] = 0.327
        state.targets[filterB] = nil
        state.owned = [MacDJOwnership(control: filterB, valueText: "LPF 2.1 kHz")]
        return state
    }

    static func soundcloud() -> MacDJPerformState {
        var state = automix()
        var b = deckB
        b.title = "Tidal Rooms"
        b.trackId = "fixture.tidal"
        b.isSoundCloud = true
        b.isViewOnly = true
        b.isSynced = false
        b.viewOnlyNote = "SoundCloud tracks play in Auto Mix. Go+ unlocks decks."
        b.sections = [
            MacDJDeckSection(name: "Intro", color: Cue.blue, firstBar: 1, lastBar: 32, hasVocals: false, isCurrent: true, isPast: false),
            MacDJDeckSection(name: "Up", color: Cue.pink, firstBar: 33, lastBar: 48, hasVocals: false, isCurrent: false, isPast: false),
            MacDJDeckSection(name: "Chorus", color: Cue.red, firstBar: 49, lastBar: 80, hasVocals: true, isCurrent: false, isPast: false),
            MacDJDeckSection(name: "Down", color: Cue.purple, firstBar: 81, lastBar: 96, hasVocals: true, isCurrent: false, isPast: false),
            MacDJDeckSection(name: "Outro", color: Cue.mint, firstBar: 97, lastBar: 128, hasVocals: false, isCurrent: false, isPast: false)
        ]
        b.phrases = phrases([(0, Cue.blue), (32, Cue.pink), (48, Cue.red), (80, Cue.purple), (96, Cue.mint)], total: 128)
        b.cues = []
        state.decks = [deckA, b]
        state.mixerLabel = "Auto Mix \u{00B7} B is Auto Mix only"
        state.mix?.enteringNote = "Starts at bar 1"
        for kind in MixControl.Kind.allCases { state.targets[control(kind, .b)] = nil }
        state.panel?.playsBothDecksNote = "SoundCloud in Auto Mix \u{00B7} Go+ unlocks decks"
        state.panel?.headline = "Bringing in Tidal Rooms"
        state.panel?.enter = MacDJPlanRow(deck: .b, title: "Tidal Rooms", section: "intro", detail: "Bar 1 \u{00B7} 4-bar loop")
        state.panel?.footer = "Playing from SoundCloud"
        return state
    }

    static func states() -> (analysing: MacDJPerformState, noGrid: MacDJPerformState) {
        var analysing = MacDJDeckState(deck: .b, trackId: "fixture.halflight", title: "Halflight", artist: "Juno Vale")
        analysing.analysis = .analysing(progress: 0.62, fallbackTitle: "Soft Static")
        analysing.duration = 300
        var noGrid = MacDJDeckState(deck: .a, trackId: "fixture.live", title: "Live Take 04", artist: "Night Tapes", source: "Music Folder")
        noGrid.analysis = .noGrid(tempoRange: "tempo varies 118\u{2013}124")
        noGrid.duration = 300
        noGrid.samples = [0.5]
        return (MacDJPerformState(decks: [analysing]), MacDJPerformState(decks: [noGrid]))
    }
}
#endif
