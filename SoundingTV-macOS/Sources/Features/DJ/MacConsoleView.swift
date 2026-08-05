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
        MixEngine.shared.$decks
            .sink { [weak self] decks in
                guard let self else { return }
                for deck in MixEngine.Deck.allCases
                where self.queuedPlayDecks.contains(deck.rawValue)
                    && decks[deck.rawValue].status.isReady
                    && decks[deck.rawValue].trackId == MacDeckTrackRegistry.shared.track(for: deck)?.id {
                    self.queuedPlayDecks.remove(deck.rawValue)
                    MixEngine.shared.play(deck: deck)
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
        let signed = knobValue.macClamped(to: 0...1) * 2 - 1
        applyRate(1 + signed * 0.16, on: deck)
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

    func toggleMasterOutput() {
        if engine.masterVolume > 0.001 {
            masterRestoreVolume = engine.masterVolume
            engine.setMasterVolume(0, over: 0.04)
            isMasterMuted = true
        } else {
            engine.setMasterVolume(max(0.1, masterRestoreVolume), over: 0.04)
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
    }

    func resetEffectsOnBothDecks() {
        resetEffects(.a)
        resetEffects(.b)
    }
}

struct MacConsoleView: View {
    @ObservedObject private var controller = MacConsoleController.shared
    @ObservedObject private var registry = MacDeckTrackRegistry.shared
    @FocusState private var isFocused: Bool
    @State private var showingGuide = false

    // Keep both decks visible in the app's standard 1040-point window. The
    // previous 1120-point canvas quietly clipped Deck B behind a hidden
    // horizontal scroller, which made the console look single-deck.
    private static let deckPanelMinWidth: CGFloat = 400
    private static let centerStackWidth: CGFloat = 120
    private static let deckRowSpacing: CGFloat = 10
    private static let consoleMinHeight: CGFloat = 520
    private static var deckRowMinWidth: CGFloat {
        deckPanelMinWidth * 2 + centerStackWidth + deckRowSpacing * 2
    }

    private let deckAColor = Color(red: 1.00, green: 0.478, blue: 0.157)
    private let deckBColor = Color(red: 0.486, green: 0.455, blue: 1.00)

    private static let chassisBackground = Color(red: 0.03, green: 0.032, blue: 0.036)

    var body: some View {
        GeometryReader { proxy in
            let needsScrolling = proxy.size.width < Self.deckRowMinWidth + 24
                || proxy.size.height < Self.consoleMinHeight + 24
            ZStack {
                MacDecksArtworkBackdrop(
                    artworkURL: focusedTrack?.artworkURL,
                    deckTint: controller.focusedDeck == .a ? deckAColor : deckBColor
                )

                if needsScrolling {
                    ScrollView([.horizontal, .vertical]) {
                        consoleCanvas(
                            width: max(proxy.size.width - 24, Self.deckRowMinWidth),
                            height: max(proxy.size.height - 24, Self.consoleMinHeight)
                        )
                        .padding(12)
                    }
                    .scrollIndicators(.hidden)
                } else {
                    consoleCanvas(
                        width: proxy.size.width - 24,
                        height: proxy.size.height - 24
                    )
                    .padding(12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Self.chassisBackground)
        .environment(\.colorScheme, .dark)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear {
            isFocused = true
            PlayerService.shared.beginExternalManualDeckControl()
        }
        .onDisappear {
            PlayerService.shared.endExternalManualDeckControl()
        }
        .onKeyPress(keys: Self.consoleKeys, phases: [.down, .up, .repeat]) { press in
            handle(press)
        }
        #if DEBUG
        .task {
            if let path = ProcessInfo.processInfo.environment["SOUNDING_TV_MAC_CONSOLE_SNAPSHOT"] {
                await Self.loadMockServerDecks()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await Self.snapshotConsole(to: path)
            }
        }
        #endif
        .sheet(item: $controller.loadTarget) { _ in
            MacLibraryBrowserView { track, target in
                Task {
                    do {
                        try await MacMixLoader.load(track, into: target)
                    } catch {
                    }
                    controller.loadTarget = nil
                }
            }
        }
        .sheet(isPresented: $showingGuide) {
            DJModeGuideView()
                .frame(minWidth: 680, minHeight: 620)
        }
    }

    private var focusedTrack: Track? { registry.track(for: controller.focusedDeck) }

    private func consoleCanvas(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 10) {
            #if DEBUG
            let _ = MacBodyMeter.count("console")
            #endif
            HStack(spacing: 8) {
                Label("Manual Decks · you own both decks and the mixer", systemImage: "hand.raised.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))
                Text("⌥ drag fine · double-click knobs to reset · Tab switches focus")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.34))
                Spacer()
                Button { controller.showKeyboardShortcuts.toggle() } label: {
                    Label(controller.showKeyboardShortcuts ? "Hide shortcuts  ?" : "Show shortcuts  ?", systemImage: "keyboard")
                }
                .buttonStyle(.plain)
                .foregroundStyle(controller.showKeyboardShortcuts ? deckAColor : .white.opacity(0.72))
                Button { showingGuide = true } label: {
                    Label("How it works", systemImage: "questionmark.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.72))
            }
            .padding(.horizontal, 4)

            if controller.showKeyboardShortcuts {
                HStack(spacing: 8) {
                    MacInlineShortcutHint("SPACE", detail: "focused play/pause")
                    MacInlineShortcutHint("⇧ SPACE", detail: "both decks")
                    MacInlineShortcutHint("TAB", detail: "switch focus")
                    MacInlineShortcutHint("R / ⇧R", detail: "reset FX / both")
                    Spacer()
                }
                .padding(.horizontal, 4)
            }

            MacMixLaneStack(controller: controller, deckATint: deckAColor, deckBTint: deckBColor)
                .frame(minHeight: 150, maxHeight: 600)
            deckRow
        }
        .frame(width: width, height: height, alignment: .top)
    }

    private var deckRow: some View {
        HStack(alignment: .top, spacing: Self.deckRowSpacing) {
            MacDeckPanel(deck: .a, controller: controller, tint: deckAColor) { controller.loadTarget = .a }
                .frame(minWidth: Self.deckPanelMinWidth, alignment: .top)
            centerStack
            MacDeckPanel(deck: .b, controller: controller, tint: deckBColor) { controller.loadTarget = .b }
                .frame(minWidth: Self.deckPanelMinWidth, alignment: .top)
        }
        .frame(minWidth: Self.deckRowMinWidth, maxWidth: .infinity, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var centerStack: some View {
        VStack(spacing: 12) {
            Text("MIXER")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .tracking(1.5)

            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Text("A").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(deckAColor)
                    MacEngineFader(
                        value: { MixEngine.shared.crossfade },
                        setValue: { MixEngine.shared.crossfade = $0 },
                        publisher: MixEngine.shared.$crossfade.removeDuplicates().eraseToAnyPublisher(),
                        tint: .white
                    )
                    Text("B").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(deckBColor)
                }
                HStack(spacing: 6) {
                    crossfaderPresetButton("A", value: 0, tint: deckAColor)
                    crossfaderPresetButton("MID", value: 0.5, tint: .white.opacity(0.75))
                    crossfaderPresetButton("B", value: 1, tint: deckBColor)
                }
                if controller.showKeyboardShortcuts {
                    MacInlineShortcutHint("←   ↓   →", detail: "⇧ snaps")
                }
            }

            Divider().overlay(Color.white.opacity(0.1)).frame(width: 100)

            VStack(spacing: 4) {
                Text("MASTER")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .tracking(1)
                MacEngineFader(
                    value: { MixEngine.shared.masterVolume },
                    setValue: { MixEngine.shared.masterVolume = $0 },
                    publisher: MixEngine.shared.$masterVolume.removeDuplicates().eraseToAnyPublisher(),
                    tint: .white
                )
                .frame(width: 100)
                Button {
                    controller.toggleMasterOutput()
                } label: {
                    Label(controller.isMasterMuted ? "RESTORE" : "MUTE", systemImage: controller.isMasterMuted ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(controller.isMasterMuted ? deckAColor : .white.opacity(0.68))
                        .frame(width: 100, height: 20)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.white.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Return toggles the master output instantly")
                if controller.showKeyboardShortcuts {
                    MacInlineShortcutHint("RETURN")
                }
            }

            MacDeckSlice(read: { DeckRates(a: $0[MixEngine.Deck.a.rawValue].rate, b: $0[MixEngine.Deck.b.rawValue].rate) }) { rates in
                compatibilityChip(rates: rates)
            }

            MacEngineErrorText()

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                Text("FOCUS")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.30))
                Text(controller.focusedDeck.label)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(controller.focusedDeck == .a ? deckAColor : deckBColor)
                Text("· TAB")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.30))
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .frame(width: Self.centerStackWidth)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }

    private func crossfaderPresetButton(_ label: String, value: Double, tint: Color) -> some View {
        Button {
            controller.crossfaderPreset(value)
        } label: {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(tint)
                .frame(width: 36, height: 18)
                .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color.white.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private struct DeckRates: Equatable {
        let a: Double
        let b: Double
    }

    private struct DeckCompatibility {
        enum KeyRelation: Equatable {
            case same
            case compatible
            case clash(steps: Int)
            case unknown
        }

        let bpmDeltaPercent: Double
        let keyRelation: KeyRelation
    }

    private func compatibility(rates: DeckRates) -> DeckCompatibility? {
        guard let a = controller.analysisByDeck[MixEngine.Deck.a.rawValue],
              let b = controller.analysisByDeck[MixEngine.Deck.b.rawValue],
              let bpmA = a.bpm, let bpmB = b.bpm
        else { return nil }

        let effectiveA = bpmA * rates.a
        let effectiveB = bpmB * rates.b
        let delta = effectiveA > 0 ? abs(effectiveB - effectiveA) / effectiveA * 100 : 0

        let relation: DeckCompatibility.KeyRelation
        if let keyA = a.key, let keyB = b.key {
            if keyA == keyB {
                relation = .same
            } else if keyA.harmonicallyCompatible.contains(keyB) {
                relation = .compatible
            } else {
                relation = .clash(steps: keyA.wheelSteps(to: keyB))
            }
        } else {
            relation = .unknown
        }

        return DeckCompatibility(bpmDeltaPercent: delta, keyRelation: relation)
    }

    @ViewBuilder
    private func compatibilityChip(rates: DeckRates) -> some View {
        VStack(spacing: 3) {
            Text("MATCH")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
                .tracking(1)
            if let compatibility = compatibility(rates: rates) {
                Text(Self.keyRelationLabel(compatibility.keyRelation))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Self.chipColor(compatibility))
                    .multilineTextAlignment(.center)
                Text(String(format: "Δ%.1f%% BPM", compatibility.bpmDeltaPercent))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                Text("Load + analyse both decks")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.32))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .frame(width: 128)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.black.opacity(0.25)))
    }

    private static func keyRelationLabel(_ relation: DeckCompatibility.KeyRelation) -> String {
        switch relation {
        case .same: return "SAME KEY"
        case .compatible: return "COMPATIBLE"
        case .clash(let steps): return "\(steps) STEP\(steps == 1 ? "" : "S") OFF"
        case .unknown: return "KEY UNKNOWN"
        }
    }

    private static func chipColor(_ c: DeckCompatibility) -> Color {
        switch c.keyRelation {
        case .unknown:
            return .white.opacity(0.4)
        case .same, .compatible:
            return c.bpmDeltaPercent <= 6 ? .green : .yellow
        case .clash:
            return c.bpmDeltaPercent <= 3 ? .yellow : .red
        }
    }

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

        .init(group: .navigation, keyLabel: "Tab", keyEquivalent: .tab,
              action: "Switch focused deck", note: "Focus controls Space, R and [ / ]"),
        .init(group: .navigation, keyLabel: "?", keyEquivalent: "?", action: "Show this shortcuts sheet", note: nil),
    ]

    private static let extraConsoleKeys: Set<KeyEquivalent> = [
        "p", "o", "i", "]", "{", "}", "2", "3", "4", "8", "9", "0",
        "l", "k", "j", "x", ",", ".", "v", "n", "m", "h", "y", ";", .rightArrow
    ]

    private static let consoleKeys: Set<KeyEquivalent> = Set(keyMap.map(\.keyEquivalent)).union(extraConsoleKeys)

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        let fine = press.modifiers.contains(.shift)
        let firing = press.phase == .down || press.phase == .repeat
        let character = press.characters.lowercased()

        switch press.key {
        case .space:
            if press.phase == .down {
                fine ? controller.toggleBothDecks() : controller.togglePlayPause(controller.focusedDeck)
            }
            return .handled
        case .tab:
            if press.phase == .down { controller.focusedDeck = controller.focusedDeck.other }
            return .handled
        case .return:
            if press.phase == .down { controller.toggleMasterOutput() }
            return .handled
        case .leftArrow:
            if fine {
                if press.phase == .down { controller.crossfaderPreset(0) }
            } else if firing {
                controller.crossfaderStep(toward: .a, fine: false)
            }
            return .handled
        case .rightArrow:
            if fine {
                if press.phase == .down { controller.crossfaderPreset(1) }
            } else if firing {
                controller.crossfaderStep(toward: .b, fine: false)
            }
            return .handled
        case .downArrow:
            if press.phase == .down { controller.crossfaderPreset(0.5) }
            return .handled
        default:
            break
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
        case "?":
            if press.phase == .down { controller.showKeyboardShortcuts.toggle() }
        default:
            return .ignored
        }
        return .handled
    }
}

private struct MacDecksArtworkBackdrop: View {
    let artworkURL: URL?
    let deckTint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SCArtworkResolver(url: artworkURL, variant: .hero) { image in
            AmbientArtworkBackdrop(
                seed: AmbientArtworkSeed(
                    artwork: image,
                    colors: [deckTint.opacity(0.30), Color.black, deckTint.opacity(0.12), Color.black],
                    accent: deckTint,
                    scrim: 0.62
                ),
                isAnimated: !reduceMotion,
                intensity: 0.42
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

private struct MacEngineErrorText: View {
    @State private var error: MixEngineError?

    var body: some View {
        VStack(spacing: 0) {
            if let error {
                Text(error.errorDescription ?? "Mix engine error")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(width: 128)
            }
        }
        .onReceive(MixEngine.shared.$lastError) { error = $0 }
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

extension MacConsoleView {
    @MainActor
    fileprivate static func loadMockServerDecks() async {
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

    @MainActor
    fileprivate static func snapshotConsole(to path: String) async {
        let env = ProcessInfo.processInfo.environment
        let width = env["SOUNDING_TV_MAC_CONSOLE_SNAPSHOT_WIDTH"].flatMap(Double.init) ?? 1360
        let height = env["SOUNDING_TV_MAC_CONSOLE_SNAPSHOT_HEIGHT"].flatMap(Double.init) ?? 780
        let renderer = ImageRenderer(content: MacConsoleView().frame(width: width, height: height).preferredColorScheme(.dark))
        renderer.scale = 2
        for _ in 0..<6 {
            _ = renderer.nsImage
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            Log.dj.error("CONSOLE_SNAPSHOT FAIL: could not rasterise view")
            return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            Log.dj.info("CONSOLE_SNAPSHOT wrote \(path, privacy: .public)")
        } catch {
            Log.dj.error("CONSOLE_SNAPSHOT FAIL writing file: \(error.localizedDescription, privacy: .public)")
        }
    }

}

@_cdecl("soundingtv_mac_console_snapshot_bootstrap")
private func soundingtv_mac_console_snapshot_bootstrap() {
    let env = ProcessInfo.processInfo.environment

    if env["SOUNDING_TV_MAC_CONSOLE_MOCKDECKS"] == "1" {
        DispatchQueue.main.async {
            Task { @MainActor in
                await MacConsoleView.loadMockServerDecks()
                MixEngine.shared.masterVolume = 0
            }
        }
    }

    guard let path = env["SOUNDING_TV_MAC_CONSOLE_SNAPSHOT"] else { return }
    DispatchQueue.main.async {
        Task { @MainActor in
            await MacConsoleView.loadMockServerDecks()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MacConsoleView.snapshotConsole(to: path)
        }
    }
}

@section("__DATA,__mod_init_func")
@used
private let soundingtv_mac_console_snapshot_bootstrap_ptr: @convention(c) () -> Void = soundingtv_mac_console_snapshot_bootstrap
#endif
