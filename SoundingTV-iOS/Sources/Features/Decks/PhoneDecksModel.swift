import Combine
import SwiftUI

@MainActor
final class PhoneDecksModel: ObservableObject {
    static let shared = PhoneDecksModel()
    static let zoomSteps: [Double] = [4, 8, 16, 32, 64]
    private static let zoomKey = "decks.zoomBars"
    private static let bandKey = "decks.eqBand"

    @Published var fixture: MacDJPerformState?
    @Published var eqBand: MixControl.Kind = PhoneDecksModel.storedBand {
        didSet { UserDefaults.standard.set(eqBand.rawValue, forKey: Self.bandKey) }
    }
    @Published var zoomBars: Double = PhoneDecksModel.storedZoom {
        didSet { UserDefaults.standard.set(zoomBars, forKey: Self.zoomKey) }
    }
    @Published private(set) var tracks: [MixEngine.Deck: Track] = [:]
    @Published private(set) var loading: Set<MixEngine.Deck> = []
    @Published private(set) var loadErrors: [MixEngine.Deck: String] = [:]
    @Published private(set) var hotCues: [MixEngine.Deck: [CuePoint]] = [:]
    @Published private(set) var analysis: [MixEngine.Deck: TrackAnalysisSummary] = [:]
    @Published private(set) var checked: Set<MixEngine.Deck> = []
    @Published private(set) var synced: Set<MixEngine.Deck> = []
    @Published private(set) var tick = 0

    let surface = PhoneDeckControlSurface()
    private var cancellables = Set<AnyCancellable>()
    private let handBacks = DeckHandBack()
    private var scrubTargets: [MixEngine.Deck: Double] = [:]
    private var scrubBeats: [MixEngine.Deck: Int] = [:]
    private var engine: MixEngine { .shared }

    private init() {
        surface.model = self
        surface.attachControllers()
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["SOUNDING_TV_DJ_FIXTURE"] {
            fixture = Self.fixture(named: name)
        }
        #endif
        Publishers.Merge4(
            MixEngine.shared.$decks.map { _ in () }.eraseToAnyPublisher(),
            MixEngine.shared.$ownedControls.map { _ in () }.eraseToAnyPublisher(),
            MixEngine.shared.$crossfade.map { _ in () }.eraseToAnyPublisher(),
            PlayerService.shared.djDirector.$snapshot.map { _ in () }.eraseToAnyPublisher()
        )
        .throttle(for: .milliseconds(50), scheduler: RunLoop.main, latest: true)
        .sink { [weak self] in
            guard let self, self.fixture == nil else { return }
            self.reconcileAutoMix()
            self.tick &+= 1
        }
        .store(in: &cancellables)
        AnalysisSummaries.shared.$byTrackId
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.refreshMissingAnalysis() }
            .store(in: &cancellables)
    }

    private static var storedZoom: Double {
        let value = UserDefaults.standard.double(forKey: zoomKey)
        return zoomSteps.contains(value) ? value : 16
    }

    private static var storedBand: MixControl.Kind {
        let stored = UserDefaults.standard.string(forKey: bandKey).flatMap(MixControl.Kind.init(rawValue:))
        return [.high, .mid, .low].contains(stored) ? stored ?? .low : .low
    }

    var isFixture: Bool { fixture != nil }

    #if DEBUG
    static func fixture(named name: String) -> MacDJPerformState? {
        switch name {
        case "empty":
            var state = MacDJPerformState(decks: [])
            state.panel = MacDJPanelState(isAutoMixOn: false, headline: "Auto Mix is off", footer: "")
            return state
        case "loaded":
            var state = MacDJFixtures.automix()
            state.mix = nil
            state.targets = [:]
            state.isAutoMixDriving = false
            state.mixerLabel = nil
            state.panel = MacDJPanelState(isAutoMixOn: false, headline: "Auto Mix is off", footer: "")
            for index in state.decks.indices {
                state.decks[index].role = state.decks[index].deck == .a ? .onAir : .idle
                state.decks[index].isLooping = false
                state.decks[index].isSynced = false
            }
            return state
        default:
            return MacDJFixtures.state(named: name)
        }
    }
    #endif

    // MARK: Library

    static func deckNote(for track: Track) -> String? {
        denial(.decks, for: track) == nil ? nil : "Auto Mix only"
    }

    static func denial(_ feature: DJGearFeature, for track: Track?) -> SoundCloudEntitlementError? {
        guard let track, case .soundCloud = track.source else { return nil }
        return SubscriptionService.shared.djGearDenial(feature, isSoundCloudTrack: true, personalUnlocked: false)
    }

    func load(_ track: Track, onto deck: MixEngine.Deck) {
        guard fixture == nil else {
            loadFixture(track, onto: deck)
            return
        }
        if let denial = Self.denial(.decks, for: track) {
            PlayerService.shared.entitlementPrompt = denial
            return
        }
        tracks[deck] = track
        loading.insert(deck)
        loadErrors[deck] = nil
        hotCues[deck] = nil
        analysis[deck] = nil
        checked.remove(deck)
        synced.remove(deck)
        WaveformService.shared.load(track)
        DeckHaptics.press()
        Task { [weak self] in
            do {
                try await PlayerService.shared.loadManualDeck(track, into: deck)
                self?.loading.remove(deck)
            } catch let denial as SoundCloudEntitlementError {
                self?.fail(deck, denial.errorDescription ?? "Couldn\u{2019}t load the track.")
                PlayerService.shared.entitlementPrompt = denial
            } catch {
                self?.fail(deck, "Couldn\u{2019}t load the track.")
            }
            await self?.refreshDeckDetails(deck, track: track)
        }
    }

    func eject(_ deck: MixEngine.Deck) {
        if fixture != nil {
            fixture?.decks.removeAll { $0.deck == deck }
            return
        }
        guard !engine[deck].isPlaying else { return }
        engine.unload(deck: deck)
        tracks[deck] = nil
        loading.remove(deck)
        loadErrors[deck] = nil
        hotCues[deck] = nil
        analysis[deck] = nil
        checked.remove(deck)
        synced.remove(deck)
        tick &+= 1
    }

    func canEject(_ deck: MixEngine.Deck) -> Bool {
        if let fixture { return !fixture.deck(deck).isEmpty && !fixture.deck(deck).isPlaying }
        return tracks[deck] != nil && !engine[deck].isPlaying
    }

    func track(on deck: MixEngine.Deck) -> Track? { tracks[deck] }

    private func fail(_ deck: MixEngine.Deck, _ message: String) {
        loading.remove(deck)
        loadErrors[deck] = message
        DeckHaptics.warning()
    }

    private func loadFixture(_ track: Track, onto deck: MixEngine.Deck) {
        var d = MacDJDeckState(deck: deck, trackId: track.id, title: track.title, artist: track.user.displayName)
        d.duration = 300
        d.barReadout = "1.1"
        fixture?.decks.removeAll { $0.deck == deck }
        fixture?.decks.append(d)
        fixture?.decks.sort { $0.deck.rawValue < $1.deck.rawValue }
    }

    private func refreshDeckDetails(_ deck: MixEngine.Deck, track: Track) async {
        await refreshHotCues(deck)
        await refreshAnalysis(deck, track: track)
    }

    func refreshAnalysis(_ deck: MixEngine.Deck) {
        guard let track = tracks[deck] else { return }
        Task { await refreshAnalysis(deck, track: track) }
    }

    private func refreshAnalysis(_ deck: MixEngine.Deck, track: Track) async {
        let summary = await AnalysisLookup.summaries(for: [track])[track.id]
        guard tracks[deck]?.id == track.id else { return }
        analysis[deck] = summary
        checked.insert(deck)
        if engine.beatGrid(for: deck) == nil, let bpm = summary?.bpm, let grid = BeatGrid.tempoOnly(bpm) {
            engine.setBeatGrid(grid, for: deck)
        }
    }

    private func refreshMissingAnalysis() {
        guard fixture == nil else { return }
        for deck in MixEngine.Deck.allCases where tracks[deck] != nil && analysis[deck]?.bpm == nil {
            refreshAnalysis(deck)
        }
    }

    func refreshHotCues(_ deck: MixEngine.Deck) async {
        guard let id = engine[deck].trackId ?? tracks[deck]?.id else { return }
        hotCues[deck] = await CueStore.shared.cues(forTrack: id).filter { $0.kind == .hotCue }
    }

    func hotCue(_ index: Int, on deck: MixEngine.Deck) -> CuePoint? {
        hotCues[deck]?.first { $0.hotCueIndex == index }
    }

    func deleteHotCue(_ index: Int, on deck: MixEngine.Deck) {
        guard fixture == nil, let cue = hotCue(index, on: deck) else { return }
        DeckHaptics.press()
        Task { [weak self] in
            await CueStore.shared.delete(cueId: cue.id)
            await self?.refreshHotCues(deck)
        }
    }

    func bpm(_ deck: MixEngine.Deck) -> Double? {
        engine.beatGrid(for: deck).map(\.bpm) ?? analysis[deck]?.bpm
    }

    func reference(for deck: MixEngine.Deck) -> PhoneDeckReference {
        let other = deck.other
        var excluded = Set(tracks.values.map(\.id))
        if let fixture {
            excluded.formUnion(fixture.decks.compactMap(\.trackId))
            let d = fixture.deck(other)
            return PhoneDeckReference(bpm: d.bpm.map { $0 * (1 + d.pitchPercent / 100) }, key: nil, title: d.title, excluded: excluded)
        }
        if tracks[other] != nil {
            let rate = engine[other].rate
            return PhoneDeckReference(bpm: bpm(other).map { $0 * rate }, key: analysis[other]?.key, title: tracks[other]?.title, excluded: excluded)
        }
        let player = PlayerService.shared
        if let current = player.currentTrack {
            excluded.insert(current.id)
            let summary = AnalysisSummaries.shared.byTrackId[current.id]
            return PhoneDeckReference(bpm: summary?.bpm, key: summary?.key, title: current.title, excluded: excluded)
        }
        return PhoneDeckReference(bpm: nil, key: nil, title: nil, excluded: excluded)
    }

    var nextReference: PhoneDeckReference {
        let player = PlayerService.shared
        var excluded = Set(tracks.values.map(\.id))
        if let current = player.currentTrack { excluded.insert(current.id) }
        let onAir = MixEngine.Deck.allCases.first { tracks[$0] != nil && engine[$0].isPlaying && (engine.crossfade < 0.5) == ($0 == .a) }
        if let onAir {
            return PhoneDeckReference(bpm: bpm(onAir).map { $0 * engine[onAir].rate }, key: analysis[onAir]?.key, title: tracks[onAir]?.title, excluded: excluded)
        }
        let summary = player.currentTrack.flatMap { AnalysisSummaries.shared.byTrackId[$0.id] }
        return PhoneDeckReference(bpm: summary?.bpm, key: summary?.key, title: player.currentTrack?.title, excluded: excluded)
    }

    var backdropArtwork: URL? {
        if let fixture {
            return (fixture.decks.first { $0.role == .onAir } ?? fixture.decks.first)?.artworkURL
        }
        let side: MixEngine.Deck = engine.crossfade < 0.5 ? .a : .b
        let order = engine[side].isPlaying || !engine[side.other].isPlaying ? [side, side.other] : [side.other, side]
        return order.lazy.compactMap { self.tracks[$0]?.artworkURL }.first
    }

    private func reconcileAutoMix() {
        guard let snapshot = PlayerService.shared.djDirector.snapshot, snapshot.isAutoMixEnabled else { return }
        let player = PlayerService.shared
        for deck in MixEngine.Deck.allCases {
            guard let id = engine[deck].trackId, tracks[deck]?.id != id else { continue }
            let resolved = [player.currentTrack, player.upcomingTrack].compactMap { $0 }.first { $0.id == id }
                ?? player.queue.first { $0.id == id }
            guard let resolved else { continue }
            tracks[deck] = resolved
            loading.remove(deck)
            checked.remove(deck)
            synced.remove(deck)
            WaveformService.shared.load(resolved)
            Task { await refreshDeckDetails(deck, track: resolved) }
        }
    }

    // MARK: Intents

    func isViewOnly(_ deck: MixEngine.Deck) -> Bool {
        if let fixture { return fixture.deck(deck).isViewOnly }
        return Self.denial(.decks, for: tracks[deck]) != nil
    }

    var isAutoMixDriving: Bool {
        if let fixture { return fixture.isAutoMixDriving }
        return PlayerService.shared.djDirector.snapshot?.isAutoMixEnabled ?? PlayerService.shared.isAutoMixEnabled
    }

    func press(_ control: DeckControl, on deck: MixEngine.Deck, index: Int = 0, isDown: Bool = true) {
        guard !isViewOnly(deck) else { return }
        if isDown, control == .hotCue || control == .loopToggle { DeckHaptics.press() }
        if fixture != nil {
            pressFixture(control, on: deck, isDown: isDown)
            return
        }
        surface.press(DeckControlAddress(group: .deck(deck), control: control, index: index), isDown: isDown)
        tick &+= 1
    }

    func toggleSync(_ deck: MixEngine.Deck) {
        guard !isViewOnly(deck) else { return }
        if let index = fixture?.decks.firstIndex(where: { $0.deck == deck }) {
            fixture?.decks[index].isSynced.toggle()
            DeckHaptics.success()
            return
        }
        if synced.contains(deck) {
            engine.unsync(deck)
            synced.remove(deck)
            DeckHaptics.press()
        } else if surface.sync(deck) {
            synced.insert(deck)
            DeckHaptics.success()
        } else {
            DeckHaptics.warning()
        }
        tick &+= 1
    }

    private func releaseSync(_ deck: MixEngine.Deck) {
        guard synced.contains(deck) else { return }
        engine.unsync(deck)
        synced.remove(deck)
    }

    private func pressFixture(_ control: DeckControl, on deck: MixEngine.Deck, isDown: Bool) {
        guard isDown, let index = fixture?.decks.firstIndex(where: { $0.deck == deck }) else { return }
        switch control {
        case .play: fixture?.decks[index].isPlaying.toggle()
        case .loopToggle: fixture?.decks[index].isLooping.toggle()
        case .sync: fixture?.decks[index].isSynced = true
        default: break
        }
    }

    func setLoopBars(_ bars: Double, on deck: MixEngine.Deck) {
        guard !isViewOnly(deck) else { return }
        DeckHaptics.press()
        if let index = fixture?.decks.firstIndex(where: { $0.deck == deck }) {
            fixture?.decks[index].loopBars = bars
            fixture?.decks[index].isLooping = true
            return
        }
        surface.setLoopBars(bars, on: deck)
    }

    func set(_ control: MixControl, to value: Double) {
        if fixture != nil {
            grab(control)
            fixture?.values[control] = value
            if let index = fixture?.owned.firstIndex(where: { $0.control == control }) {
                fixture?.owned[index].valueText = fixture!.valueText(control)
            }
            return
        }
        if control.kind == .tempo, let deck = control.deck { releaseSync(deck) }
        guard let address = Self.address(for: control) else { return }
        surface.setValue(value, for: address)
    }

    static func address(for control: MixControl) -> DeckControlAddress? {
        let group: DeckGroup = control.deck.map { .deck($0) } ?? .mixer
        switch control.kind {
        case .crossfader: return DeckControlAddress(group: .mixer, control: .crossfader)
        case .high: return DeckControlAddress(group: group, control: .eqHigh)
        case .mid: return DeckControlAddress(group: group, control: .eqMid)
        case .low: return DeckControlAddress(group: group, control: .eqLow)
        case .filter: return DeckControlAddress(group: group, control: .filter)
        case .volume: return DeckControlAddress(group: group, control: .volume)
        case .trim: return DeckControlAddress(group: group, control: .trim)
        case .tempo: return DeckControlAddress(group: group, control: .tempo)
        case .echo: return nil
        }
    }

    func grab(_ control: MixControl) {
        if fixture != nil {
            guard fixture?.ownership(control) == nil, fixture?.isAutoMixDriving == true else { return }
            fixture?.owned.append(MacDJOwnership(control: control, valueText: fixture!.valueText(control)))
            fixture?.targets[control] = nil
            return
        }
        guard isAutoMixDriving else { return }
        handBacks.grab(control)
    }

    func handBack(_ control: MixControl) {
        DeckHaptics.press()
        if fixture != nil {
            fixture?.owned.removeAll { $0.control == control }
            return
        }
        handBacks.handBack(control)
    }

    func handBackAll() {
        DeckHaptics.press()
        if fixture != nil {
            fixture?.owned.removeAll()
            return
        }
        handBacks.handBackAll()
    }

    func takeOverAll() {
        if fixture != nil {
            fixture?.owned.removeAll()
            fixture?.isAutoMixDriving = false
            fixture?.targets = [:]
            fixture?.mix = nil
            fixture?.mixerLabel = nil
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

    var canMixNow: Bool {
        guard fixture == nil else { return fixture?.isAutoMixDriving == true && fixture?.mix == nil }
        return isAutoMixDriving && PlayerService.shared.canStartMix
    }

    func mixNow() {
        guard fixture == nil else { return }
        DeckHaptics.press()
        PlayerService.shared.startMix()
    }

    var canExtend: Bool {
        guard fixture == nil else { return fixture?.panel?.canExtend == true }
        return PlayerService.shared.canExtendMix
    }

    func extend() {
        guard fixture == nil else { return }
        DeckHaptics.press()
        PlayerService.shared.extendMix()
    }

    func skip() {
        guard fixture == nil else { return }
        let player = PlayerService.shared
        guard let upcoming = player.upcomingTrack,
              let index = player.queue.firstIndex(where: { $0.id == upcoming.id }),
              index + 1 < player.queue.count else { return }
        player.promoteToUpcoming(trackId: player.queue[index + 1].id)
    }

    func chooseNext(_ track: Track, otherwise insert: (Track) -> Void) {
        guard fixture == nil else { return }
        let player = PlayerService.shared
        let later = player.queue.dropFirst(player.currentIndex + 1)
        if later.contains(where: { $0.id == track.id }) {
            player.promoteToUpcoming(trackId: track.id)
        }
        if player.upcomingTrack?.id != track.id { insert(track) }
        DeckHaptics.success()
    }

    var savableSet: MixHistorySession? {
        guard fixture == nil else { return nil }
        let store = MixHistoryStore.shared
        guard let session = store.sessions.last, let last = session.entries.last,
              Date().timeIntervalSince(last.date) < MixHistoryStore.sessionGap else { return nil }
        return session
    }

    // MARK: Waveform touch

    func setZoom(from start: Double, magnification: CGFloat) {
        let raw = start / Double(max(0.1, magnification))
        guard raw.isFinite, raw > 0 else { return }
        let step = Self.zoomSteps.min { abs(log($0 / raw)) < abs(log($1 / raw)) } ?? 16
        guard step != zoomBars else { return }
        zoomBars = step
        DeckHaptics.beat()
    }

    func beginTouch(_ deck: MixEngine.Deck) {
        scrubTargets[deck] = nil
        scrubBeats[deck] = nil
        guard fixture == nil, !isViewOnly(deck), engine[deck].status.isReady else { return }
        if engine[deck].isPlaying {
            releaseSync(deck)
            grab(MixControl(.tempo, deck: deck))
        }
    }

    func drag(_ deck: MixEngine.Deck, by dx: CGFloat, laneWidth: CGFloat) {
        guard fixture == nil, dx != 0, !isViewOnly(deck), engine[deck].status.isReady else { return }
        let s = engine[deck]
        if s.isPlaying {
            engine.nudge(deck: deck, amount: Double(-dx) * 0.004, releaseSeconds: 0.12)
            return
        }
        let bar = engine.beatGrid(for: deck)?.barDuration ?? bpm(deck).map { 240 / $0 } ?? 2
        let secondsPerPoint = zoomBars * bar / Double(max(1, laneWidth))
        let target = min(s.duration, max(0, (scrubTargets[deck] ?? s.position) - Double(dx) * secondsPerPoint))
        scrubTargets[deck] = target
        if let grid = engine.beatGrid(for: deck), grid.beatPeriod > 0 {
            let beat = Int(((target - grid.anchor) / grid.beatPeriod).rounded())
            guard beat != scrubBeats[deck] else { return }
            scrubBeats[deck] = beat
            engine.seek(deck: deck, to: max(0, grid.anchor + Double(beat) * grid.beatPeriod))
            DeckHaptics.beat()
        } else if abs(target - s.position) > 0.04 {
            engine.seek(deck: deck, to: target)
        }
        tick &+= 1
    }

    func endTouch(_ deck: MixEngine.Deck) {
        scrubTargets[deck] = nil
        scrubBeats[deck] = nil
    }

    // MARK: Values

    func valueText(_ control: MixControl, in state: MacDJPerformState) -> String {
        Self.valueText(control.kind, value: state.value(control))
    }

    static func valueText(_ kind: MixControl.Kind, value: Double) -> String {
        switch kind {
        case .filter:
            if abs(value - 0.5) < 0.005 { return "Off" }
            let hertz = DJMixerUnits.bipolarFilter(knob: value)
            return DJMixerUnits.filterLabel(lowPass: hertz.lowPass, highPass: hertz.highPass)
        case .high, .mid, .low: return DJMixerUnits.decibelLabel(DJMixerUnits.eqDecibels(knob: value))
        case .trim: return DJMixerUnits.decibelLabel(DJMixerUnits.trimDecibels(knob: value))
        case .crossfader: return PhoneDeckCrossfader.text(value)
        case .volume, .echo: return "\(Int((value * 100).rounded()))%"
        case .tempo: return String(format: "%+.1f%%", (value * 2 - 1) * DJMixerUnits.tempoRange * 100)
        }
    }

    // MARK: State

    func state(at date: Date) -> MacDJPerformState {
        if var fixture {
            fixture.zoomBars = zoomBars
            return fixture
        }
        return liveState(at: date)
    }

    private func liveState(at date: Date) -> MacDJPerformState {
        let snapshot = PlayerService.shared.djDirector.snapshot
        let live = AutoMixLive.shared.state
        let driving = isAutoMixDriving
        let liveDeck = snapshot?.liveDeck ?? .a
        var state = MacDJPerformState(decks: MixEngine.Deck.allCases.compactMap { deckState($0, liveDeck: liveDeck, live: live, driving: driving) })
        state.isAutoMixDriving = driving
        state.zoomBars = zoomBars
        for deck in MixEngine.Deck.allCases {
            let s = engine[deck]
            state.values[MixControl(.trim, deck: deck)] = DJMixerUnits.trimKnob(decibels: s.inputGain)
            state.values[MixControl(.high, deck: deck)] = DJMixerUnits.eqKnob(decibels: s.high)
            state.values[MixControl(.mid, deck: deck)] = DJMixerUnits.eqKnob(decibels: s.mid)
            state.values[MixControl(.low, deck: deck)] = DJMixerUnits.eqKnob(decibels: s.low)
            state.values[MixControl(.filter, deck: deck)] = DJMixerUnits.bipolarFilterKnob(lowPass: s.filterCutoff, highPass: s.highPassCutoff)
            state.values[MixControl(.volume, deck: deck)] = engine.mixer.faderCurve.position(gain: s.gain)
            state.values[MixControl(.tempo, deck: deck)] = DJMixerUnits.tempoKnob(rate: s.rate)
            state.levels[deck] = Double(min(1, s.level * 1.4))
        }
        state.values[.crossfader] = engine.crossfade
        state.owned = engine.ownedControls.sorted { $0.id < $1.id }.map { MacDJOwnership(control: $0, valueText: state.valueText($0)) }
        var panel = MacDJPanelState(isAutoMixOn: driving, headline: driving ? "Auto Mix" : "Auto Mix is off", footer: "")
        if driving {
            state.mixerLabel = "Auto Mix \u{00B7} moving controls"
            if let live {
                state.mix = MacDJMixState(live: live, at: date, leaving: liveDeck)
                state.targets = targets(live, at: date, liveDeck: liveDeck)
                panel.headline = live.stage == .mixing ? "Bringing in \(live.incomingTitle)" : "Mix into \(live.incomingTitle)"
                panel.subline = live.moveSummary
                panel.canExtend = live.canExtend
            } else {
                panel.headline = PlayerService.shared.upcomingTrack.map { "Next: \($0.title)" } ?? "Waiting for the next track"
            }
        }
        if let viewOnly = MixEngine.Deck.allCases.first(where: { state.deck($0).isViewOnly && !state.deck($0).isEmpty }) {
            state.mixerLabel = "Auto Mix \u{00B7} \(viewOnly.label) is Auto Mix only"
            panel.playsBothDecksNote = "Go+ unlocks decks"
        }
        state.panel = panel
        return state
    }

    private func deckState(_ deck: MixEngine.Deck, liveDeck: MixEngine.Deck, live: AutoMixLiveState?, driving: Bool) -> MacDJDeckState? {
        let s = engine[deck]
        guard let track = tracks[deck] else {
            if case .failed(let message) = s.status {
                var d = MacDJDeckState(deck: deck, title: "", artist: "")
                d.problem = .failed(title: "Can\u{2019}t Load Deck \(deck.label)", message: message)
                return d
            }
            return nil
        }
        var d = MacDJDeckState(deck: deck, trackId: track.id, title: track.title, artist: track.user.displayName)
        d.artworkURL = track.artworkURL
        if case .soundCloud = track.source { d.isSoundCloud = true }
        d.isViewOnly = Self.denial(.decks, for: track) != nil
        if d.isViewOnly { d.viewOnlyNote = "Go+ unlocks decks" }
        d.position = s.position
        d.duration = s.duration
        d.isPlaying = s.isPlaying
        d.pitchPercent = (s.rate - 1) * 100
        d.isLooping = s.loopLengthSeconds != nil
        d.bpm = bpm(deck)
        d.key = analysis[deck]?.key?.label
        let grid = engine.beatGrid(for: deck)
        d.barSeconds = grid?.barDuration ?? d.bpm.map { 240 / $0 }
        d.loopBars = surface.loopBars[deck] ?? 4
        if let bar = d.barSeconds, bar > 0 {
            let beats = max(0, (s.position - (grid?.firstDownbeat ?? 0)) / (bar / 4))
            d.barReadout = "\(Int(beats / 4) + 1).\(Int(beats.truncatingRemainder(dividingBy: 4)) + 1)"
            if let length = s.loopLengthSeconds { d.loopBars = max(0.25, (length / bar * 4).rounded() / 4) }
        } else {
            d.analysis = checked.contains(deck) ? .noGrid(tempoRange: "tempo unknown") : .analysing(progress: 0, fallbackTitle: nil)
        }
        if case .loading(let fraction) = s.status {
            d.analysis = .analysing(progress: fraction, fallbackTitle: nil)
            d.statusTitle = fraction > 0 ? "Loading \(Int((fraction * 100).rounded()))%" : "Loading\u{2026}"
        } else if loading.contains(deck), s.trackId != track.id {
            d.analysis = .analysing(progress: 0, fallbackTitle: nil)
            d.statusTitle = "Loading\u{2026}"
        } else if d.bpm == nil {
            d.statusTitle = checked.contains(deck) ? "No BPM" : "Finding BPM\u{2026}"
        }
        if case .failed(let message) = s.status { d.problem = .failed(title: "Can\u{2019}t Play \(track.title)", message: message) }
        if let error = loadErrors[deck] { d.problem = .failed(title: "Can\u{2019}t Load \(track.title)", message: error) }
        if driving, s.isPlaying {
            d.role = deck == liveDeck ? .onAir : (live?.stage == .mixing ? .mixingIn : .idle)
        } else if s.isPlaying {
            d.role = (engine.crossfade < 0.5) == (deck == .a) ? .onAir : .idle
        }
        d.isSynced = synced.contains(deck) || (driving && deck != liveDeck && live?.stage == .mixing)
        if case .ready(let waveform) = WaveformService.shared.state(for: track.id) { d.samples = waveform.samples }
        d.cues = (hotCues[deck] ?? []).compactMap { cue in
            guard let index = cue.hotCueIndex else { return nil }
            return MacDJCue(index: index, label: cue.label, seconds: cue.positionSeconds, color: Color(red: Double(cue.color.red) / 255, green: Double(cue.color.green) / 255, blue: Double(cue.color.blue) / 255))
        }
        .sorted { $0.index < $1.index }
        return d
    }

    private func targets(_ live: AutoMixLiveState, at date: Date, liveDeck: MixEngine.Deck) -> [MixControl: MacDJTarget] {
        let now = live.stage == .upcoming ? live.barsFromStart(at: date) : live.clock(at: date).barInMove
        let incoming = liveDeck.other
        var result: [MixControl: MacDJTarget] = [:]
        if let release = live.releaseBar, release > now {
            result[MixControl(.low, deck: liveDeck)] = MacDJTarget(value: 0.02, label: nil)
            result[MixControl(.low, deck: incoming)] = MacDJTarget(value: 0.5, label: nil)
        }
        if let fadeIn = live.sections.first(where: { $0.role == .fadeIn }), fadeIn.endBar > now {
            result[MixControl(.volume, deck: incoming)] = MacDJTarget(value: 1, label: nil)
            result[.crossfader] = MacDJTarget(value: liveDeck == .a ? 0.62 : 0.38, label: nil)
        }
        if let out = live.sections.last(where: { $0.role == .fadeOut }), out.startBar > now {
            if out.label == "Filter out" {
                result[MixControl(.filter, deck: liveDeck)] = MacDJTarget(value: 0.8, label: nil)
            } else {
                result[MixControl(.volume, deck: liveDeck)] = MacDJTarget(value: 0, label: nil)
            }
        }
        return result
    }
}

struct PhoneDeckReference: Equatable {
    var bpm: Double?
    var key: CamelotKey?
    var title: String?
    var excluded: Set<String>
}
