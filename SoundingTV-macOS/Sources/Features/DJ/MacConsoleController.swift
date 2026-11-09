import SwiftUI
import Combine
import os
#if DEBUG
import AppKit
#endif

@MainActor
final class MacConsoleController: ObservableObject {
    static let shared = MacConsoleController()

    @Published var cueAnchor: [Int: TimeInterval] = [:]
    @Published var cuePreviewing: [Int: Bool] = [:]
    @Published var keyLocked: [Int: Bool] = [MixEngine.Deck.a.rawValue: true, MixEngine.Deck.b.rawValue: true]
    @Published var loopSeconds: [Int: Double] = [MixEngine.Deck.a.rawValue: 4, MixEngine.Deck.b.rawValue: 4]
    @Published var hotCues: [Int: [CuePoint]] = [:]
    @Published var focusedDeck: MixEngine.Deck = .a

    @Published var isConsoleActive = false

    @Published var loadTarget: MixEngine.Deck?

    @Published var showKeyboardShortcuts = false

    @Published var showingAutoDJStartConfiguration = false

    @Published private(set) var queuedPlayDecks: Set<Int> = []
    private var cancellables = Set<AnyCancellable>()

    @Published private(set) var isMasterMuted = false
    private var masterRestoreVolume = 1.0

    @Published var analysisByDeck: [Int: TrackAnalysisSummary] = [:]

    func setAnalysis(_ summary: TrackAnalysisSummary?, for deck: MixEngine.Deck) {
        analysisByDeck[deck.rawValue] = summary
    }

    @Published var nudgeFeedback: [Int: String] = [:]
    private var nudgeFeedbackTokens: [Int: UUID] = [:]

    @Published var syncFeedback: [Int: String] = [:]
    private var syncFeedbackTokens: [Int: UUID] = [:]

    private init() {
        Publishers.CombineLatest(MixEngine.shared.$decks, MacDeckTrackRegistry.shared.$autoManagedDecks)
            .sink { [weak self] decks, autoManagedDecks in
                guard let self else { return }
                for deck in MixEngine.Deck.allCases where self.queuedPlayDecks.contains(deck.rawValue) {
                    if autoManagedDecks.contains(deck.rawValue) {
                        self.queuedPlayDecks.remove(deck.rawValue)
                        continue
                    }
                    if decks[deck.rawValue].status.isReady
                        && decks[deck.rawValue].trackId == MacDeckTrackRegistry.shared.track(for: deck)?.id {
                        self.queuedPlayDecks.remove(deck.rawValue)
                        MixEngine.shared.play(deck: deck)
                    }
                }
            }
            .store(in: &cancellables)
    }

    private var engine: MixEngine { MixEngine.shared }

    func togglePlayPause(_ deck: MixEngine.Deck) {
        cuePreviewing[deck.rawValue] = false
        guard isDeckReady(deck) else {
            if queuedPlayDecks.contains(deck.rawValue) {
                queuedPlayDecks.remove(deck.rawValue)
            } else {
                queuedPlayDecks.insert(deck.rawValue)
            }
            return
        }
        queuedPlayDecks.remove(deck.rawValue)
        engine.togglePlayPause(deck: deck)
    }

    func isPlayRequested(_ deck: MixEngine.Deck) -> Bool {
        queuedPlayDecks.contains(deck.rawValue) || (isDeckReady(deck) && engine[deck].isPlaying)
    }

    func isDeckReady(_ deck: MixEngine.Deck) -> Bool {
        engine[deck].status.isReady
            && engine[deck].trackId == MacDeckTrackRegistry.shared.track(for: deck)?.id
    }

    func cueDown(_ deck: MixEngine.Deck) {
        guard engine[deck].status.isReady else { return }
        if engine[deck].isPlaying {
            let anchor = cueAnchor[deck.rawValue] ?? 0
            engine.pause(deck: deck)
            engine.seek(deck: deck, to: anchor)
        } else {
            cueAnchor[deck.rawValue] = engine[deck].position
            cuePreviewing[deck.rawValue] = true
            engine.play(deck: deck)
        }
    }

    func cueUp(_ deck: MixEngine.Deck) {
        guard cuePreviewing[deck.rawValue] == true else { return }
        cuePreviewing[deck.rawValue] = false
        let anchor = cueAnchor[deck.rawValue] ?? 0
        engine.pause(deck: deck)
        engine.seek(deck: deck, to: anchor)
    }

    func nudge(_ deck: MixEngine.Deck, seconds: Double) {
        guard engine[deck].status.isReady else { return }
        engine.seek(deck: deck, byNudging: seconds)

        let index = deck.rawValue
        nudgeFeedback[index] = String(format: "%+.0fms", seconds * 1000)
        let token = UUID()
        nudgeFeedbackTokens[index] = token
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard let self, self.nudgeFeedbackTokens[index] == token else { return }
            self.nudgeFeedback[index] = nil
        }
    }

    func setKeyLocked(_ deck: MixEngine.Deck, _ locked: Bool) {
        keyLocked[deck.rawValue] = locked
        if locked { engine.setPitch(0, on: deck) }
    }

    func setTempo(_ deck: MixEngine.Deck, knobValue: Double) {
        applyRate(DJMixerUnits.tempoRate(knob: knobValue), on: deck)
    }

    func tempoStep(_ deck: MixEngine.Deck, up: Bool, fine: Bool) {
        let step = (fine ? 0.0005 : 0.005) * (up ? 1 : -1)
        applyRate(engine[deck].rate + step, on: deck)
    }

    func resetTempo(_ deck: MixEngine.Deck) {
        applyRate(1, on: deck)
    }

    func sync(_ deck: MixEngine.Deck) {
        let reference = deck.other
        guard engine[deck].status.isReady, engine[reference].status.isReady else {
            showSyncFeedback("LOAD BOTH", on: deck)
            return
        }

        if engine.sync(deck, to: reference) {
            showSyncFeedback("BEAT SYNC", on: deck)
            return
        }

        guard let sourceBPM = analysisByDeck[deck.rawValue]?.bpm,
              let referenceBPM = analysisByDeck[reference.rawValue]?.bpm,
              engine.matchTempo(
                on: deck,
                sourceBPM: sourceBPM,
                targetBPM: referenceBPM * engine[reference].rate,
                over: 0.08
              ) else {
            showSyncFeedback("GRID NEEDED", on: deck)
            return
        }
        showSyncFeedback("TEMPO SYNC", on: deck)
    }

    private func showSyncFeedback(_ message: String, on deck: MixEngine.Deck) {
        let index = deck.rawValue
        let token = UUID()
        syncFeedback[index] = message
        syncFeedbackTokens[index] = token
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self, self.syncFeedbackTokens[index] == token else { return }
            self.syncFeedback[index] = nil
        }
    }

    private func applyRate(_ rate: Double, on deck: MixEngine.Deck) {
        let clamped = rate.macClamped(to: MixEngine.rateRange)
        engine.setRate(clamped, on: deck)
        guard keyLocked[deck.rawValue] == false else { return }
        engine.setPitch(1200 * log2(clamped), on: deck)
    }

    func toggleLoop(_ deck: MixEngine.Deck) {
        guard engine[deck].status.isReady else { return }
        if engine[deck].loopStartSeconds != nil {
            engine.clearLoop(on: deck)
        } else {
            engine.setLoop(on: deck, startSeconds: engine[deck].position, lengthSeconds: loopSeconds[deck.rawValue] ?? 4)
        }
    }

    func halveLoop(_ deck: MixEngine.Deck) { adjustLoop(deck, factor: 0.5) }
    func doubleLoop(_ deck: MixEngine.Deck) { adjustLoop(deck, factor: 2) }

    private func adjustLoop(_ deck: MixEngine.Deck, factor: Double) {
        let newLength = ((loopSeconds[deck.rawValue] ?? 4) * factor).macClamped(to: 0.25...64)
        loopSeconds[deck.rawValue] = newLength
        if engine[deck].loopStartSeconds != nil {
            engine.setLoop(on: deck, startSeconds: engine[deck].position, lengthSeconds: newLength)
        }
    }

    func hotCue(_ deck: MixEngine.Deck, index: Int) {
        guard let trackId = engine[deck].trackId else { return }
        if let existing = hotCues[deck.rawValue]?.first(where: { $0.hotCueIndex == index }) {
            let seconds = Double(existing.positionMillis) / 1000
            engine.seek(deck: deck, to: seconds)
            if !engine[deck].isPlaying { engine.play(deck: deck) }
            return
        }
        let positionMillis = Int64(engine[deck].position * 1000)
        Task {
            _ = await CueStore.shared.setHotCue(trackId: trackId, index: index, positionMillis: positionMillis)
            await refreshHotCues(deck: deck, trackId: trackId)
        }
    }

    func refreshHotCues(deck: MixEngine.Deck, trackId: String) async {
        let cues = await CueStore.shared.cues(forTrack: trackId).filter { $0.kind == .hotCue }
        hotCues[deck.rawValue] = cues
    }

    func crossfaderPreset(_ target: Double) {
        engine.crossfade(to: target, over: 0.06)
    }

    func crossfaderStep(toward deck: MixEngine.Deck, fine: Bool) {
        let amount = fine ? 0.02 : 0.08
        let direction = deck == .a ? -1.0 : 1.0
        engine.crossfade(to: engine.crossfade + direction * amount, over: 0.04)
    }

    func toggleBothDecks() {
        let readyDecks = MixEngine.Deck.allCases.filter { engine[$0].status.isReady }
        guard !readyDecks.isEmpty else { return }
        let shouldPlay = readyDecks.contains { !engine[$0].isPlaying }
        for deck in readyDecks {
            shouldPlay ? engine.play(deck: deck) : engine.pause(deck: deck)
        }
    }

    private var isMixWindowActive: Bool {
        PlayerService.shared.djDirector.snapshot?.mixWindow != nil
    }

    func toggleMasterOutput() {
        if engine.masterVolume > 0.001 {
            guard !isMixWindowActive else { return }
            masterRestoreVolume = engine.masterVolume
            engine.setMasterVolume(0, over: 0.04)
            isMasterMuted = true
        } else {
            let restoreLevel = isMixWindowActive ? 1.0 : max(0.1, masterRestoreVolume)
            engine.setMasterVolume(restoreLevel, over: 0.04)
            isMasterMuted = false
        }
    }

    func filterStep(_ deck: MixEngine.Deck, opening: Bool, fine: Bool) {
        let lower = log(MixEngine.filterCutoffRange.lowerBound)
        let upper = log(MixEngine.filterCutoffRange.upperBound)
        let current = log(engine[deck].filterCutoff.macClamped(to: MixEngine.filterCutoffRange))
        let normalized = (current - lower) / (upper - lower)
        let amount = fine ? 0.025 : 0.10
        let next = (normalized + (opening ? amount : -amount)).macClamped(to: 0...1)
        engine.setFilterCutoff(exp(lower + next * (upper - lower)), on: deck, over: 0.04)
    }

    func toggleEcho(_ deck: MixEngine.Deck) {
        let enabled = engine[deck].delayWet > 0.02
        engine.setDelayWet(enabled ? 0 : 0.32, feedback: enabled ? 0 : 0.42, on: deck, over: 0.05)
    }

    func resetEffects(_ deck: MixEngine.Deck) {
        engine.openFilter(on: deck, over: 0.08)
        engine.setFilterResonance(0, on: deck, over: 0.08)
        engine.setHighPassCutoff(MixEngine.filterCutoffRange.lowerBound, on: deck, over: 0.08)
        engine.setDelayWet(0, feedback: 0, on: deck, over: 0.08)
        engine.setEQ(.low, on: deck, toDecibels: 0, over: 0.08)
        engine.setEQ(.mid, on: deck, toDecibels: 0, over: 0.08)
        engine.setEQ(.high, on: deck, toDecibels: 0, over: 0.08)
    }

    func resetEffectsOnBothDecks() {
        resetEffects(.a)
        resetEffects(.b)
    }
}

@MainActor
enum MacDJKeyboard {
    enum ConsoleKeyGroup: String, CaseIterable, Identifiable, Hashable {
        case transport = "Transport"
        case hotCues = "Hot Cues"
        case effects = "Effects"
        case loop = "Loops"
        case tempo = "Tempo & Key Lock"
        case mixer = "Crossfader & Master"
        case navigation = "Navigation"

        var id: String { rawValue }
    }

    struct ConsoleKeyBinding: Identifiable {
        let id = UUID()
        let group: ConsoleKeyGroup
        let keyLabel: String
        let keyEquivalent: KeyEquivalent
        let action: String
        let note: String?
    }

    static let keyMap: [ConsoleKeyBinding] = [
        .init(group: .transport, keyLabel: "Space", keyEquivalent: .space,
              action: "Play / Pause the focused deck", note: "⇧ Space controls both decks together"),
        .init(group: .transport, keyLabel: "Q  ↔  P", keyEquivalent: "q",
              action: "Hold cue: Deck A  ↔  Deck B", note: "Release to return to the cue point"),
        .init(group: .transport, keyLabel: "W  ↔  O", keyEquivalent: "w",
              action: "Play / Pause: Deck A  ↔  Deck B", note: nil),

        .init(group: .loop, keyLabel: "E  ↔  I", keyEquivalent: "e",
              action: "Toggle loop: Deck A  ↔  Deck B", note: nil),
        .init(group: .loop, keyLabel: "[  /  ]", keyEquivalent: "[",
              action: "Halve / double the focused loop", note: "Hold ⇧ to resize both loops"),

        .init(group: .hotCues, keyLabel: "1  2  3  4", keyEquivalent: "1", action: "Deck A hot cues 1–4", note: nil),
        .init(group: .hotCues, keyLabel: "7  8  9  0", keyEquivalent: "7", action: "Deck B hot cues 1–4", note: nil),

        .init(group: .effects, keyLabel: "A  ↔  L", keyEquivalent: "a",
              action: "Close filter: Deck A  ↔  Deck B", note: "Hold ⇧ for fine steps"),
        .init(group: .effects, keyLabel: "S  ↔  K", keyEquivalent: "s",
              action: "Open filter: Deck A  ↔  Deck B", note: "Hold ⇧ for fine steps"),
        .init(group: .effects, keyLabel: "D  ↔  J", keyEquivalent: "d",
              action: "Toggle echo: Deck A  ↔  Deck B", note: nil),
        .init(group: .effects, keyLabel: "R", keyEquivalent: "r",
              action: "Reset focused deck effects", note: "⇧ R resets both decks"),

        .init(group: .tempo, keyLabel: "Z / X  ↔  , / .", keyEquivalent: "z",
              action: "Nudge earlier / later: Deck A  ↔  Deck B", note: "Hold ⇧ for a coarse jump"),
        .init(group: .tempo, keyLabel: "C / V  ↔  N / M", keyEquivalent: "c",
              action: "Tempo down / up: Deck A  ↔  Deck B", note: "Hold ⇧ for fine steps"),
        .init(group: .tempo, keyLabel: "F  ↔  H", keyEquivalent: "f",
              action: "Key lock: Deck A  ↔  Deck B", note: nil),
        .init(group: .tempo, keyLabel: "T  ↔  Y", keyEquivalent: "t",
              action: "Reset tempo: Deck A  ↔  Deck B", note: nil),
        .init(group: .tempo, keyLabel: "G  ↔  ;", keyEquivalent: "g",
              action: "Sync tempo/phase: Deck A to B  ↔  Deck B to A", note: "Uses full beat sync when grids exist; otherwise matches measured tempo"),

        .init(group: .mixer, keyLabel: "←  /  →", keyEquivalent: .leftArrow,
              action: "Move crossfader toward A / B", note: "Hold to sweep; ⇧ snaps to that deck"),
        .init(group: .mixer, keyLabel: "↓", keyEquivalent: .downArrow,
              action: "Centre the crossfader", note: nil),
        .init(group: .mixer, keyLabel: "Return", keyEquivalent: .return,
              action: "Mute / restore master output", note: "Restores the previous master level"),

        .init(group: .navigation, keyLabel: "`", keyEquivalent: "`",
              action: "Switch focused deck", note: "Focus controls Space, R and [ / ]. Tab moves between controls"),
        .init(group: .navigation, keyLabel: "?", keyEquivalent: "?", action: "Show this shortcuts sheet", note: nil),
    ]

    private static let extraConsoleKeys: Set<KeyEquivalent> = [
        "p", "o", "i", "]", "{", "}", "2", "3", "4", "8", "9", "0",
        "l", "k", "j", "x", ",", ".", "v", "n", "m", "h", "y", ";", .rightArrow
    ]

    static let consoleKeys: Set<KeyEquivalent> = Set(keyMap.map(\.keyEquivalent)).union(extraConsoleKeys)

    private static let autoModeAllowedCharacters: Set<String> = [
        "q", "p", "w", "o", "1", "2", "3", "4", "7", "8", "9", "0", "?", "`"
    ]

    static func handle(_ press: KeyPress) -> KeyPress.Result {
        let controller = MacConsoleController.shared
        let isAutoMixEnabled = PlayerService.shared.djDirector.snapshot?.isAutoMixEnabled ?? PlayerService.shared.isAutoMixEnabled
        let fine = press.modifiers.contains(.shift)
        let firing = press.phase == .down || press.phase == .repeat
        let character = press.characters.lowercased()
        let mixerLocked = isAutoMixEnabled

        switch press.key {
        case .space:
            if press.phase == .down {
                fine ? controller.toggleBothDecks() : controller.togglePlayPause(controller.focusedDeck)
            }
            return .handled
        case .return:
            if press.phase == .down { controller.toggleMasterOutput() }
            return .handled
        case .leftArrow:
            guard !mixerLocked else { return .handled }
            if fine {
                if press.phase == .down { controller.crossfaderPreset(0) }
            } else if firing {
                controller.crossfaderStep(toward: .a, fine: false)
            }
            return .handled
        case .rightArrow:
            guard !mixerLocked else { return .handled }
            if fine {
                if press.phase == .down { controller.crossfaderPreset(1) }
            } else if firing {
                controller.crossfaderStep(toward: .b, fine: false)
            }
            return .handled
        case .downArrow:
            guard !mixerLocked else { return .handled }
            if press.phase == .down { controller.crossfaderPreset(0.5) }
            return .handled
        default:
            break
        }

        if mixerLocked && !Self.autoModeAllowedCharacters.contains(character) {
            return .handled
        }

        switch character {
        case "q":
            if press.phase == .down { controller.cueDown(.a) }
            if press.phase == .up { controller.cueUp(.a) }
        case "p":
            if press.phase == .down { controller.cueDown(.b) }
            if press.phase == .up { controller.cueUp(.b) }
        case "w":
            if press.phase == .down { controller.togglePlayPause(.a) }
        case "o":
            if press.phase == .down { controller.togglePlayPause(.b) }
        case "1", "2", "3", "4":
            if press.phase == .down, let n = Int(character) { controller.hotCue(.a, index: n - 1) }
        case "7", "8", "9", "0":
            if press.phase == .down {
                let index = character == "0" ? 3 : (Int(character) ?? 7) - 7
                controller.hotCue(.b, index: index)
            }
        case "e":
            if press.phase == .down { controller.toggleLoop(.a) }
        case "i":
            if press.phase == .down { controller.toggleLoop(.b) }
        case "[", "{":
            if press.phase == .down {
                if fine { MixEngine.Deck.allCases.forEach(controller.halveLoop) }
                else { controller.halveLoop(controller.focusedDeck) }
            }
        case "]", "}":
            if press.phase == .down {
                if fine { MixEngine.Deck.allCases.forEach(controller.doubleLoop) }
                else { controller.doubleLoop(controller.focusedDeck) }
            }
        case "a":
            if firing { controller.filterStep(.a, opening: false, fine: fine) }
        case "l":
            if firing { controller.filterStep(.b, opening: false, fine: fine) }
        case "s":
            if firing { controller.filterStep(.a, opening: true, fine: fine) }
        case "k":
            if firing { controller.filterStep(.b, opening: true, fine: fine) }
        case "d":
            if press.phase == .down { controller.toggleEcho(.a) }
        case "j":
            if press.phase == .down { controller.toggleEcho(.b) }
        case "r":
            if press.phase == .down {
                fine ? controller.resetEffectsOnBothDecks() : controller.resetEffects(controller.focusedDeck)
            }
        case "z":
            if firing { controller.nudge(.a, seconds: fine ? -0.5 : -5.0 / 1000) }
        case "x":
            if firing { controller.nudge(.a, seconds: fine ? 0.5 : 5.0 / 1000) }
        case "c":
            if firing { controller.tempoStep(.a, up: false, fine: fine) }
        case "v":
            if firing { controller.tempoStep(.a, up: true, fine: fine) }
        case ",":
            if firing { controller.nudge(.b, seconds: fine ? -0.5 : -5.0 / 1000) }
        case ".":
            if firing { controller.nudge(.b, seconds: fine ? 0.5 : 5.0 / 1000) }
        case "n":
            if firing { controller.tempoStep(.b, up: false, fine: fine) }
        case "m":
            if firing { controller.tempoStep(.b, up: true, fine: fine) }
        case "f", "h":
            if press.phase == .down {
                let deck: MixEngine.Deck = character == "f" ? .a : .b
                controller.setKeyLocked(deck, !(controller.keyLocked[deck.rawValue] ?? true))
            }
        case "t":
            if press.phase == .down { controller.resetTempo(.a) }
        case "y":
            if press.phase == .down { controller.resetTempo(.b) }
        case "g":
            if press.phase == .down { controller.sync(.a) }
        case ";":
            if press.phase == .down { controller.sync(.b) }
        case "`":
            if press.phase == .down { controller.focusedDeck = controller.focusedDeck.other }
        case "?":
            if press.phase == .down { controller.showKeyboardShortcuts.toggle() }
        default:
            return .ignored
        }
        return .handled
    }
}

#if DEBUG
@MainActor
enum MacBodyMeter {
    static let enabled = ProcessInfo.processInfo.environment["SOUNDING_TV_MAC_BODY_METER"] == "1"
    private static var counts: [String: Int] = [:]
    private static var reporter: Task<Void, Never>?

    static func count(_ name: String) {
        guard enabled else { return }
        counts[name, default: 0] += 1
        guard reporter == nil else { return }
        reporter = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let line = counts
                    .sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: " ")
                counts.removeAll()
                Log.dj.debug("BODY_METER \(line, privacy: .public)")
            }
        }
    }
}


@MainActor
enum MacDJDebugDecks {
    @MainActor
    static func loadMockServerDecks() async {
        let base = ProcessInfo.processInfo.environment["SOUNDING_TV_STREAM_HOST"] ?? "http://127.0.0.1:8787"
        do {
            guard let catalogURL = URL(string: "\(base)/catalog") else { return }
            let (catalogData, _) = try await URLSession.shared.data(from: catalogURL)
            struct CatalogEntry: Decodable { let id: Int }
            let ids = try JSONDecoder().decode([CatalogEntry].self, from: catalogData).map { String($0.id) }
            guard ids.count >= 2 else {
                Log.dj.error("CONSOLE_SNAPSHOT mock server returned \(ids.count, privacy: .public) track(s); need at least 2 — is it running?")
                return
            }

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
            formatter.timeZone = TimeZone(identifier: "UTC")
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .formatted(formatter)

            func fetchTrack(_ id: String) async throws -> Track {
                guard let url = URL(string: "\(base)/tracks/\(id)") else { throw URLError(.badURL) }
                let (data, _) = try await URLSession.shared.data(from: url)
                return try decoder.decode(Track.self, from: data)
            }

            let trackA = try await fetchTrack(ids[0])
            let trackB = try await fetchTrack(ids[1])

            try await MacMixLoader.load(trackA, into: .a)
            try await MacMixLoader.load(trackB, into: .b)

            let engine = MixEngine.shared
            engine.play(deck: .a)
            engine.play(deck: .b)
            engine.crossfade = 0.5
            engine.setEQ(.low, on: .b, toDecibels: -8)

            Log.dj.info("CONSOLE_SNAPSHOT loaded '\(trackA.title, privacy: .public)' (A, analysed) and '\(trackB.title, privacy: .public)' (B, unanalysed); both playing.")
        } catch {
            Log.dj.error("CONSOLE_SNAPSHOT FAIL: \(error.localizedDescription, privacy: .public)")
        }
    }

}

@_cdecl("soundingtv_mac_console_mockdecks_bootstrap")
private func soundingtv_mac_console_mockdecks_bootstrap() {
    guard ProcessInfo.processInfo.environment["SOUNDING_TV_MAC_CONSOLE_MOCKDECKS"] == "1" else { return }
    DispatchQueue.main.async {
        Task { @MainActor in
            await MacDJDebugDecks.loadMockServerDecks()
            MixEngine.shared.masterVolume = 0
        }
    }
}

@section("__DATA,__mod_init_func")
@used
private let soundingtv_mac_console_mockdecks_bootstrap_ptr: @convention(c) () -> Void = soundingtv_mac_console_mockdecks_bootstrap
#endif
