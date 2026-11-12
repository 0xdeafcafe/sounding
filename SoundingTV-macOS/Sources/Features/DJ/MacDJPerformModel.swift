import Combine
import SwiftUI

enum MacDJUnits {
    static func eqValue(_ decibels: Double) -> Double {
        guard decibels.isFinite else { return 0 }
        return DJMixerUnits.eqKnob(decibels: decibels)
    }

    static func eqDecibels(_ value: Double) -> Double {
        DJMixerUnits.eqDecibels(knob: value)
    }

    static func filterValue(lowPass: Double, highPass: Double) -> Double {
        DJMixerUnits.bipolarFilterKnob(lowPass: lowPass, highPass: highPass)
    }

    static func filterHertz(_ value: Double) -> (lowPass: Double, highPass: Double) {
        DJMixerUnits.bipolarFilter(knob: value)
    }

    static func trimValue(_ decibels: Double) -> Double { DJMixerUnits.trimKnob(decibels: decibels) }
    static func trimDecibels(_ value: Double) -> Double { DJMixerUnits.trimDecibels(knob: value) }

    @MainActor static func volumeValue(gain: Double) -> Double { MixEngine.shared.mixer.faderCurve.position(gain: gain) }
    @MainActor static func volumeGain(_ value: Double) -> Double { MixEngine.shared.mixer.faderCurve.gain(position: value) }

    static func tempoValue(rate: Double) -> Double { DJMixerUnits.tempoKnob(rate: rate) }

    static func bars(_ value: Double) -> String {
        let n = Int(value.rounded(.up))
        return n == 1 ? "1 bar" : "\(n) bars"
    }

    static func time(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    static func loopText(_ bars: Double) -> String {
        if bars >= 1 { return bars == 1 ? "1 Bar" : "\(Int(bars)) Bars" }
        let beats = bars * 4
        return beats == 1 ? "1 Beat" : beats == 0.5 ? "1/2 Beat" : "\(beats.formatted()) Beats"
    }
}

@MainActor
final class MacDJPerformModel: ObservableObject {
    static let shared = MacDJPerformModel()

    @Published var isPlanPresented = false
    @Published var panelTab: MacDJPanelTab = .autoMix
    @Published var isPanelOpen = true
    @Published var padModes: [MixEngine.Deck: MacDJPadMode] = [.a: .hotCue, .b: .loop]
    @Published var zoomBars: Double = 22
    @Published var layout: MacDJPerformLayout = .full
    @Published var refusal: String?
    @Published var fixture: MacDJPerformState?
    @Published private(set) var analysis: [MixEngine.Deck: TrackAnalysisSummary] = [:]
    @Published private(set) var loadedTrackIds: [MixEngine.Deck: String] = [:]

    private var cancellables = Set<AnyCancellable>()
    private var engine: MixEngine { .shared }
    private var console: MacConsoleController { .shared }

    @Published private(set) var tick = 0

    private init() {
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["SOUNDING_TV_DJ_FIXTURE"] {
            fixture = MacDJFixtures.state(named: name)
            isPanelOpen = !name.hasPrefix("collapsed")
        }
        switch ProcessInfo.processInfo.environment["SOUNDING_TV_MAC_DJ_PANEL"]?.lowercased() {
        case "library": panelTab = .library
        case "closed": isPanelOpen = false
        default: break
        }
        #endif
        Publishers.Merge4(
            MixEngine.shared.$decks.map { _ in () }.eraseToAnyPublisher(),
            MixEngine.shared.$ownedControls.map { _ in () }.eraseToAnyPublisher(),
            MixEngine.shared.$crossfade.map { _ in () }.eraseToAnyPublisher(),
            PlayerService.shared.djDirector.$snapshot.map { _ in () }.eraseToAnyPublisher()
        )
        .throttle(for: .milliseconds(33), scheduler: RunLoop.main, latest: true)
        .sink { [weak self] in
            guard let self, self.fixture == nil else { return }
            self.tick &+= 1
        }
        .store(in: &cancellables)
        MacDeckTrackRegistry.shared.$tracks
            .receive(on: RunLoop.main)
            .sink { [weak self] tracks in self?.trackDecksChanged(tracks) }
            .store(in: &cancellables)
    }

    var isFixture: Bool { fixture != nil }

    private func trackDecksChanged(_ tracks: [Int: Track]) {
        for deck in MixEngine.Deck.allCases {
            let id = tracks[deck.rawValue]?.id
            guard loadedTrackIds[deck] != id else { continue }
            loadedTrackIds[deck] = id
            analysis[deck] = nil
            guard let track = tracks[deck.rawValue] else { continue }
            WaveformService.shared.load(track)
            Task { [weak self] in
                await self?.console.refreshHotCues(deck: deck, trackId: track.id)
                let summary = await AnalysisLookup.summaries(for: [track])[track.id]
                guard let self, self.loadedTrackIds[deck] == track.id else { return }
                self.analysis[deck] = summary
                self.console.setAnalysis(summary, for: deck)
            }
        }
    }

    // MARK: Intents

    var isAutoMixDriving: Bool {
        if let fixture { return fixture.isAutoMixDriving }
        return PlayerService.shared.djDirector.snapshot?.isAutoMixEnabled ?? PlayerService.shared.isAutoMixEnabled
    }

    func grab(_ control: MixControl) {
        if fixture != nil {
            guard fixture?.ownership(control) == nil, fixture?.isAutoMixDriving == true else { return }
            fixture?.owned.append(MacDJOwnership(control: control, valueText: fixture!.valueText(control)))
            return
        }
        guard isAutoMixDriving else { return }
        handBacks.grab(control)
    }

    func set(_ control: MixControl, to value: Double) {
        if fixture != nil {
            fixture?.values[control] = value
            if let index = fixture?.owned.firstIndex(where: { $0.control == control }) {
                fixture?.owned[index].valueText = fixture!.valueText(control)
            }
            return
        }
        guard !isViewOnly(control.deck) else { return }
        engine.asUser {
            switch control.kind {
            case .trim: control.deck.map { engine.setInputGain(MacDJUnits.trimDecibels(value), on: $0, over: 0.03) }
            case .high: control.deck.map { engine.setEQ(.high, on: $0, toDecibels: MacDJUnits.eqDecibels(value), over: 0.03) }
            case .mid: control.deck.map { engine.setEQ(.mid, on: $0, toDecibels: MacDJUnits.eqDecibels(value), over: 0.03) }
            case .low: control.deck.map { engine.setEQ(.low, on: $0, toDecibels: MacDJUnits.eqDecibels(value), over: 0.03) }
            case .filter:
                guard let deck = control.deck else { return }
                let hertz = MacDJUnits.filterHertz(value)
                engine.setFilterCutoff(hertz.lowPass, on: deck, over: 0.03)
                engine.setHighPassCutoff(hertz.highPass, on: deck, over: 0.03)
            case .volume: control.deck.map { engine.setGain(MacDJUnits.volumeGain(value), on: $0, over: 0.02) }
            case .tempo: control.deck.map { console.setTempo($0, knobValue: value) }
            case .echo: control.deck.map { engine.setDelayWet(value * 0.6, feedback: value > 0 ? 0.42 : 0, on: $0, over: 0.03) }
            case .crossfader: engine.crossfade(to: value, over: 0.02)
            }
        }
    }

    func handBack(_ control: MixControl) {
        if fixture != nil {
            fixture?.owned.removeAll { $0.control == control }
            return
        }
        handBacks.handBack(control)
    }

    func handBackAll() {
        if fixture != nil {
            fixture?.owned.removeAll()
            return
        }
        handBacks.handBackAll()
    }

    private let handBacks = DeckHandBack()

    func takeOverAll() {
        if fixture != nil {
            fixture?.owned.removeAll()
            fixture?.isAutoMixDriving = false
            fixture?.targets = [:]
            fixture?.panel?.isAutoMixOn = false
            return
        }
        engine.handBackAll()
        PlayerService.shared.setAutomaticMixEnabled(false)
    }

    func setAutoMix(_ enabled: Bool) {
        if fixture != nil {
            fixture?.panel?.isAutoMixOn = enabled
            fixture?.isAutoMixDriving = enabled
            return
        }
        if !enabled { engine.handBackAll() }
        PlayerService.shared.setAutomaticMixEnabled(enabled)
    }

    func extend() {
        guard fixture == nil else { return }
        PlayerService.shared.extendMix()
    }

    func skipNext() {
        guard fixture == nil else { return }
        let player = PlayerService.shared
        guard let next = nextInPlan(after: player.upcomingTrack) else { return }
        player.promoteToUpcoming(trackId: next.id)
    }

    func requestLoad(_ trackId: String, onto deck: MixEngine.Deck, context: DJDeckContext) {
        guard case .refused(let message) = context.request(trackId, onto: deck) else { return }
        refusal = message
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if self?.refusal == message { self?.refusal = nil }
        }
    }

    @Published private(set) var manualMaster: MixEngine.Deck?

    func makeMaster(_ deck: MixEngine.Deck) {
        if fixture != nil {
            for index in fixture!.decks.indices { fixture!.decks[index].isMaster = fixture!.decks[index].deck == deck }
            return
        }
        manualMaster = deck
    }

    func cancelLoad(_ deck: MixEngine.Deck) {
        guard fixture == nil else { return }
        engine.unload(deck: deck)
    }

    func changeNext() {
        panelTab = .library
        isPanelOpen = true
    }

    func isViewOnly(_ deck: MixEngine.Deck?) -> Bool {
        guard let deck else { return false }
        if let fixture { return fixture.deck(deck).isViewOnly }
        let track = MacDeckTrackRegistry.shared.track(for: deck)
        return MacDeckControlSurface.djDenial(.decks, source: track?.source) != nil
    }

    private func nextInPlan(after track: Track?) -> Track? {
        let player = PlayerService.shared
        guard let track, let index = player.queue.firstIndex(where: { $0.id == track.id }), index + 1 < player.queue.count else { return nil }
        return player.queue[index + 1]
    }

    // MARK: State

    func state(at date: Date) -> MacDJPerformState {
        var state = fixture ?? liveState(at: date)
        if !layout.showsControlTargets { state.targets = [:] }
        return state
    }

    private func liveState(at date: Date) -> MacDJPerformState {
        let player = PlayerService.shared
        let snapshot = player.djDirector.snapshot
        let live = AutoMixLive.shared.state
        let driving = isAutoMixDriving
        let liveDeck = snapshot?.liveDeck ?? .a
        var state = MacDJPerformState(decks: MixEngine.Deck.allCases.map { deckState($0, liveDeck: liveDeck, live: live, driving: driving) })
        state.isAutoMixDriving = driving
        state.zoomBars = zoomBars
        for deck in MixEngine.Deck.allCases {
            let s = engine[deck]
            state.values[MixControl(.trim, deck: deck)] = MacDJUnits.trimValue(s.inputGain)
            state.values[MixControl(.high, deck: deck)] = MacDJUnits.eqValue(s.high)
            state.values[MixControl(.mid, deck: deck)] = MacDJUnits.eqValue(s.mid)
            state.values[MixControl(.low, deck: deck)] = MacDJUnits.eqValue(s.low)
            state.values[MixControl(.filter, deck: deck)] = MacDJUnits.filterValue(lowPass: s.filterCutoff, highPass: s.highPassCutoff)
            state.values[MixControl(.volume, deck: deck)] = MacDJUnits.volumeValue(gain: s.gain)
            state.values[MixControl(.tempo, deck: deck)] = MacDJUnits.tempoValue(rate: s.rate)
            state.levels[deck] = Double(min(1, s.level * 1.4))
        }
        state.values[.crossfader] = engine.crossfade
        state.masterLevel = state.levels.values.max() ?? 0
        state.owned = engine.ownedControls.sorted { $0.id < $1.id }.map { MacDJOwnership(control: $0, valueText: state.valueText($0)) }
        if driving, let live {
            state.mixerLabel = "Auto Mix \u{00B7} moving controls"
            state.mix = MacDJMixState(live: live, at: date, leaving: liveDeck)
            state.targets = targets(live, at: date, liveDeck: liveDeck)
        } else if driving {
            state.mixerLabel = "Auto Mix \u{00B7} moving controls"
        }
        if MixEngine.Deck.allCases.contains(where: { state.deck($0).isViewOnly && !state.deck($0).isEmpty }) {
            let viewOnly = MixEngine.Deck.allCases.first { state.deck($0).isViewOnly }!
            state.mixerLabel = "Auto Mix \u{00B7} \(viewOnly.label) is Auto Mix only"
        }
        state.panel = panelState(live, snapshot: snapshot, at: date, driving: driving, state: state)
        return state
    }

    private func deckState(_ deck: MixEngine.Deck, liveDeck: MixEngine.Deck, live: AutoMixLiveState?, driving: Bool) -> MacDJDeckState {
        let s = engine[deck]
        let track = MacDeckTrackRegistry.shared.track(for: deck)
        var d = MacDJDeckState(deck: deck, title: track?.title ?? "", artist: track?.user.displayName ?? "")
        guard let track else {
            if case .failed(let message) = s.status {
                d.problem = .failed(title: "Can\u{2019}t Load Deck \(deck.label)", message: message)
            }
            return d
        }
        d.trackId = track.id
        d.artworkURL = track.artworkURL
        if case .soundCloud = track.source { d.isSoundCloud = true }
        d.isViewOnly = MacDeckControlSurface.djDenial(.decks, source: track.source) != nil
        if d.isViewOnly { d.viewOnlyNote = "SoundCloud tracks play in Auto Mix. Go+ unlocks decks." }
        d.position = s.position
        d.duration = s.duration
        d.isPlaying = s.isPlaying
        d.pitchPercent = (s.rate - 1) * 100
        d.tempo = min(1, max(-1, (s.rate - 1) / DJMixerUnits.tempoRange))
        d.isLooping = s.loopLengthSeconds != nil
        let summary = analysis[deck]
        d.bpm = summary?.bpm
        d.key = summary?.key?.label
        let grid = engine.beatGrid(for: deck)
        d.barSeconds = grid?.barDuration ?? summary?.bpm.map { 240 / $0 }
        if let bar = d.barSeconds, bar > 0 {
            let first = grid?.firstDownbeat ?? 0
            let beats = max(0, (s.position - first) / (bar / 4))
            d.barReadout = "\(Int(beats / 4) + 1).\(Int(beats.truncatingRemainder(dividingBy: 4)) + 1)"
            d.jogAngle = (beats / 4).truncatingRemainder(dividingBy: 1) * 2 * .pi
            if let length = s.loopLengthSeconds { d.loopBars = max(0.25, (length / bar * 4).rounded() / 4) }
        } else {
            d.barReadout = MacDJUnits.time(s.position)
            d.analysis = summary == nil ? .analysing(progress: 0, fallbackTitle: nil) : .noGrid(tempoRange: "tempo unknown")
        }
        if grid == nil, summary?.bpm != nil { d.analysis = .ready }
        if case .loading(let fraction) = s.status { d.analysis = .analysing(progress: fraction, fallbackTitle: nil) }
        if case .failed(let message) = s.status { d.problem = .failed(title: "Can\u{2019}t Play \(track.title)", message: message) }
        if driving, s.isPlaying {
            d.role = deck == liveDeck ? .onAir : (live?.stage == .mixing ? .mixingIn : .idle)
        } else if s.isPlaying {
            d.role = engine.crossfade < 0.5 ? (deck == .a ? .onAir : .idle) : (deck == .b ? .onAir : .idle)
        }
        d.isMaster = driving ? deck == liveDeck : deck == (manualMaster ?? .a)
        d.isSynced = driving && deck != liveDeck && live?.stage == .mixing
        if case .waveform(let samples)? = waveformSamples(track.id) { d.samples = samples }
        d.cues = (console.hotCues[deck.rawValue] ?? []).compactMap { cue in
            guard let index = cue.hotCueIndex else { return nil }
            return MacDJCue(index: index, label: cue.label, seconds: cue.positionSeconds, color: macCueColor(cue))
        }
        .sorted { $0.index < $1.index }
        if driving, let live {
            let incoming = deck != liveDeck
            let clock = live.clock(at: Date())
            if incoming {
                d.statusTitle = live.stage == .mixing ? "Mixing in" : "Up next"
            } else {
                d.statusTitle = "On air"
            }
            if let phase = clock.phase {
                d.statusDetail = live.caption(for: phase)
            }
            if incoming, d.isLooping { d.padNote = "Auto Mix is looping" }
        }
        return d
    }

    private enum Samples {
        case waveform([Float])
    }

    private func waveformSamples(_ id: String) -> Samples? {
        guard case .ready(let waveform) = WaveformService.shared.state(for: id) else { return nil }
        return .waveform(waveform.samples)
    }

    private func targets(_ live: AutoMixLiveState, at date: Date, liveDeck: MixEngine.Deck) -> [MixControl: MacDJTarget] {
        let sections = live.sections
        let now = live.stage == .upcoming ? live.barsFromStart(at: date) : live.clock(at: date).barInMove
        let incoming = liveDeck.other
        var result: [MixControl: MacDJTarget] = [:]
        func label(_ verb: String, at bar: Double) -> String? {
            let ahead = bar - now
            guard ahead > 0 else { return nil }
            return "\(verb) in \(MacDJUnits.bars(ahead))"
        }
        if let release = live.releaseBar, release > now {
            result[MixControl(.low, deck: liveDeck)] = MacDJTarget(value: 0.02, label: label("Cut", at: release))
            result[MixControl(.low, deck: incoming)] = MacDJTarget(value: 0.5, label: label("In", at: release))
            if engine[incoming].high < -0.5 {
                result[MixControl(.high, deck: incoming)] = MacDJTarget(value: 0.5, label: label("0 dB", at: release))
            }
            if engine[incoming].filterCutoff < 16_000 || engine[incoming].highPassCutoff > 60 {
                result[MixControl(.filter, deck: incoming)] = MacDJTarget(value: 0.5, label: label("Off", at: release))
            }
        }
        if let fadeIn = sections.first(where: { $0.role == .fadeIn }), fadeIn.endBar > now {
            result[MixControl(.volume, deck: incoming)] = MacDJTarget(value: 1, label: nil)
            result[.crossfader] = MacDJTarget(value: liveDeck == .a ? 0.62 : 0.38, label: nil)
        }
        if let out = sections.last(where: { $0.role == .fadeOut }), out.startBar > now {
            let filtering = out.label == "Filter out"
            if filtering {
                result[MixControl(.filter, deck: liveDeck)] = MacDJTarget(value: 0.8, label: label("HPF", at: out.startBar))
            } else {
                result[MixControl(.volume, deck: liveDeck)] = MacDJTarget(value: 0, label: nil)
            }
        }
        return result
    }

    private func panelState(_ live: AutoMixLiveState?, snapshot: DJSessionSnapshot?, at date: Date, driving: Bool, state: MacDJPerformState) -> MacDJPanelState {
        let player = PlayerService.shared
        var panel = MacDJPanelState(
            isAutoMixOn: driving,
            headline: "Auto Mix is off",
            footer: snapshot?.profile?.displayName ?? "Auto Mix"
        )
        if state.decks.contains(where: { $0.isViewOnly && !$0.isEmpty }) {
            panel.playsBothDecksNote = "SoundCloud in Auto Mix \u{00B7} Go+ unlocks decks"
            panel.footer = "Playing from SoundCloud"
        }
        guard driving else {
            panel.subline = "Turn it on to let Auto Mix play the decks."
            return panel
        }
        guard let live else {
            panel.headline = player.upcomingTrack.map { "Next: \($0.title)" } ?? "Waiting for the next track"
            return panel
        }
        let clock = live.clock(at: date)
        let liveDeck = snapshot?.liveDeck ?? .a
        let barSeconds = max(0.1, live.barSeconds)
        if live.stage == .mixing {
            let bar = Int(clock.barInMove) + 1
            panel.stageChip = "Mixing \u{00B7} bar \(bar) of \(live.lengthBars)"
            panel.timeLeft = "\(MacDJUnits.time((Double(live.lengthBars) - clock.barInMove) * barSeconds)) left"
            panel.headline = "Bringing in \(live.incomingTitle)"
            let phaseLabel = clock.phase.map { MacDJMixState.stepLabel(AutoMixLiveState.Section(role: live.role(of: $0), label: $0.name, startBar: $0.startBar, endBar: $0.endBar), index: 1, all: live.sections) }
            if let release = live.releaseBar, release > clock.barInMove {
                let ahead = release - clock.barInMove
                panel.subline = [phaseLabel, "releases in \(MacDJUnits.bars(ahead)) (\(MacDJUnits.time(ahead * barSeconds)))"].compactMap { $0 }.joined(separator: " \u{00B7} ")
            } else {
                panel.subline = phaseLabel
            }
        } else {
            panel.stageChip = "Next mix \u{00B7} \(clock.countdownText)"
            panel.headline = live.headline
            panel.subline = live.moveName
        }
        let outgoingTitle = live.outgoingTitle ?? MacDeckTrackRegistry.shared.track(for: liveDeck)?.title ?? ""
        let outgoingBar = state.deck(liveDeck).barReadout.split(separator: ".").first.map(String.init)
        panel.from = MacDJPlanRow(deck: liveDeck, title: outgoingTitle, section: nil, detail: outgoingBar.map { "Bar \($0)" })
        panel.enter = MacDJPlanRow(deck: liveDeck.other, title: live.incomingTitle, section: nil, detail: live.incomingArtist)
        panel.move = live.headline
        panel.why = (live.why ?? "").components(separatedBy: " \u{00B7} ").filter { !$0.isEmpty }.map { MacDJWhy(title: $0, detail: nil) }
        if let next = nextInPlan(after: player.upcomingTrack) {
            panel.next = MacDJNext(title: next.title, detail: next.user.displayName, artworkURL: next.artworkURL, identity: next.id)
        }
        panel.canExtend = live.canExtend
        return panel
    }
}
