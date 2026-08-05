import SwiftUI
import Combine

struct MacDeckPanel: View {
    let deck: MixEngine.Deck
    @ObservedObject var controller: MacConsoleController
    @ObservedObject var registry = MacDeckTrackRegistry.shared
    @ObservedObject var waveforms = WaveformService.shared
    @ObservedObject private var analysisWork = AutomaticAnalysisStatus.shared
    let tint: Color
    let onRequestLoad: () -> Void

    @State private var analysis: TrackAnalysisSummary?
    @State private var slowState: MixEngine.DeckState?
    @State private var isDropTarget = false

    private var engine: MixEngine { .shared }
    private var state: MixEngine.DeckState { slowState ?? Self.slowRead(MixEngine.shared.decks, deck) }
    private var track: Track? { registry.track(for: deck) }
    private var workState: AnalysisWorkState? { track.flatMap { analysisWork.state(for: $0.id) } }

    private static func slowRead(_ decks: [MixEngine.DeckState], _ deck: MixEngine.Deck) -> MixEngine.DeckState {
        var state = decks[deck.rawValue]
        state.position = 0
        state.level = 0
        state.peak = 0
        return state
    }
    private var isFocused: Bool { controller.focusedDeck == deck }

    private static let chassisFill = Color(red: 0.055, green: 0.058, blue: 0.066)
    private static let chipFill = Color.black.opacity(0.4)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            #if DEBUG
            let _ = MacBodyMeter.count("deck\(deck.label)")
            #endif
            header
            readoutRow
            overviewStrip
            jogAndTransport
            if controller.showKeyboardShortcuts { transportShortcutRow }
            hotCueRow
            if controller.showKeyboardShortcuts { hotCueShortcutRow }
            loopRow
            if controller.showKeyboardShortcuts { loopShortcutRow }
            Divider().overlay(Color.white.opacity(0.08))
            mixerRow
            if controller.showKeyboardShortcuts { mixerShortcutRow }
        }
        .padding(10)
        .background(
            VStack(spacing: 0) {
                Rectangle().fill(tint.opacity(state.status.isReady ? 0.9 : 0.25)).frame(height: 3)
                Rectangle().fill(Self.chassisFill)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    isDropTarget
                        ? tint
                        : (isFocused ? tint.opacity(0.85) : Color.white.opacity(state.status.isReady ? 0.14 : 0.06)),
                    lineWidth: isDropTarget ? 3 : (isFocused ? 2 : 1)
                )
        )
        .dropDestination(for: MacTrackDragPayload.self) { payloads, _ in
            guard let payload = payloads.first else { return false }
            controller.focusedDeck = deck
            Task { try? await MacMixLoader.load(payload.track, into: deck) }
            return true
        } isTargeted: { targeted in
            withAnimation(SCContentMotion.focus) { isDropTarget = targeted }
        }
        .simultaneousGesture(
            TapGesture().onEnded { controller.focusedDeck = deck }
        )
        .onReceive(
            MixEngine.shared.$decks
                .map { Self.slowRead($0, deck) }
                .removeDuplicates()
        ) { slowState = $0 }
        .task(id: track?.id) {
            analysis = nil
            controller.setAnalysis(nil, for: deck)
            guard let track else { return }
            waveforms.load(track)
            await controller.refreshHotCues(deck: deck, trackId: track.id)
            let summary = await AnalysisLookup.summaries(for: [track])[track.id]
            analysis = summary
            controller.setAnalysis(summary, for: deck)
        }
        .onChange(of: workState) { _, state in
            guard state == .complete, let track else { return }
            Task {
                let summary = await AnalysisLookup.summaries(for: [track])[track.id]
                analysis = summary
                controller.setAnalysis(summary, for: deck)
            }
        }
        .animation(SCContentMotion.focus, value: controller.showKeyboardShortcuts)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(deck.label)
                .font(.system(size: 14, weight: .black, design: .monospaced))
                .foregroundStyle(.black)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(tint))
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(Color.white.opacity(isFocused ? 0.9 : 0), lineWidth: 2)
                        .padding(-2)
                )

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(track?.title ?? "No track loaded")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if isFocused {
                        Text("FOCUSED")
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(tint))
                    }
                }
                Text(headerSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            MacConsoleButton(title: "LOAD", tint: tint, action: onRequestLoad)
        }
    }

    private var headerSubtitle: String {
        if case .loading(let fraction) = state.status {
            return "Loading… \(Int((fraction * 100).rounded()))%"
        }
        if case .failed(let reason) = state.status {
            return reason
        }
        return track?.user.displayName ?? " "
    }

    private var readoutRow: some View {
        HStack(spacing: 6) {
            readoutChip(label: "BPM", value: bpmValueText, sublabel: bpmSublabelText, known: analysis?.bpm != nil)
            readoutChip(label: "KEY", value: analysis?.key?.label ?? workMetricValue, sublabel: workMetricDetail, known: analysis?.key != nil || workState != nil)
            readoutChip(label: "TEMPO", value: String(format: "%+.1f%%", (state.rate - 1) * 100), sublabel: nil, known: true)
        }
    }

    private var bpmValueText: String {
        guard let bpm = analysis?.bpm else { return workMetricValue }
        return String(format: "%.1f", bpm * state.rate)
    }

    private var bpmSublabelText: String? {
        if let workMetricDetail { return workMetricDetail }
        guard let bpm = analysis?.bpm, abs(state.rate - 1) > 0.001 else { return nil }
        return "meas. " + String(format: "%.1f", bpm)
    }

    private var workMetricValue: String {
        guard let workState else { return "---.-" }
        switch workState {
        case .queued: return "QUEUED"
        case .analysing: return "ANALYSING"
        case .notEligible: return "PAUSED"
        case .failed: return "FAILED"
        case .complete: return "…"
        }
    }

    private var workMetricDetail: String? {
        guard analysis?.bpm == nil || analysis?.key == nil else { return nil }
        return workState?.label
    }

    private func readoutChip(label: String, value: String, sublabel: String?, known: Bool) -> some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .tracking(0.5)
            Text(value)
                .font(.system(size: 16, weight: .heavy, design: .monospaced))
                .foregroundStyle(known ? tint : .white.opacity(0.22))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(sublabel ?? " ")
                .font(.system(size: 7, design: .monospaced))
                .foregroundStyle(.white.opacity(0.32))
        }
        .frame(minWidth: 52)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Self.chipFill))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }

    private var overviewStrip: some View {
        let wf = track.map { waveforms.state(for: $0.id) } ?? .pending
        let cues = controller.hotCues[deck.rawValue] ?? []
        return MacDeckSlice(deck: deck, read: MacDeckPlayhead.init) { playhead in
            GeometryReader { geo in
                MacWaveformOverview(
                    state: wf, progress: playhead.progress, duration: playhead.duration,
                    trackId: track?.id, deck: deck,
                    markers: overviewMarkers(cues: cues, duration: playhead.duration)
                )
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { drag in
                            guard state.status.isReady, playhead.duration > 0, geo.size.width > 0 else { return }
                            let fraction = Double(drag.location.x / geo.size.width).clampedToUnit
                            engine.seek(deck: deck, to: fraction * playhead.duration)
                        }
                )
            }
        }
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.black.opacity(0.35)))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .help("Click to jump the deck to that point")
    }

    private func overviewMarkers(cues: [CuePoint], duration: TimeInterval) -> [SCWaveformMarker] {
        guard duration > 0 else { return [] }
        return cues.compactMap { cue in
            guard cue.hotCueIndex != nil else { return nil }
            return SCWaveformMarker(id: cue.id, position: cue.positionSeconds / duration, color: macCueColor(cue))
        }
    }

    private var jogAndTransport: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack(alignment: .bottom) {
                MacDeckSlice(deck: deck, read: MacDeckPlayhead.init) { playhead in
                    SCArtworkResolver(url: track?.artworkURL, variant: .standard) { image in
                        MacJogWheel(
                            positionSeconds: playhead.position,
                            isPlaying: playhead.isPlaying,
                            tint: tint,
                            artwork: image,
                            identity: track?.title ?? "Deck \(deck.label)",
                            diameter: 68
                        )
                    }
                }
                if let feedback = controller.nudgeFeedback[deck.rawValue] {
                    Text(feedback)
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(tint))
                        .offset(y: 10)
                        .transition(.opacity)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                transportRow
            }
        }
        .animation(SCContentMotion.press, value: controller.nudgeFeedback[deck.rawValue])
    }

    private var transportRow: some View {
        HStack(spacing: 8) {
            MacConsoleButton(
                systemImage: controller.isPlayRequested(deck) ? "pause.fill" : "play.fill",
                isActive: controller.isPlayRequested(deck),
                tint: tint,
                isEnabled: track != nil
            ) {
                controller.togglePlayPause(deck)
            }
            .help(controller.isDeckReady(deck) ? "Play or pause Deck \(deck.label)" : "Queue playback as soon as Deck \(deck.label) is ready")

            Text("CUE")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 34, height: 22)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(cuePressed ? tint : Color.gray.opacity(0.25)))
                .foregroundStyle(cuePressed ? .white : .white.opacity(0.85))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if !cuePressed { cuePressed = true; controller.cueDown(deck) }
                        }
                        .onEnded { _ in
                            cuePressed = false
                            controller.cueUp(deck)
                        }
                )
                .opacity(state.status.isReady ? 1 : 0.4)
                .allowsHitTesting(state.status.isReady)

            MacConsoleButton(systemImage: "stop.fill", isEnabled: state.status.isReady) {
                engine.stop(deck: deck)
            }

            Spacer(minLength: 4)

            MacConsoleButton(
                systemImage: (controller.keyLocked[deck.rawValue] ?? true) ? "lock.fill" : "lock.open.fill",
                isActive: controller.keyLocked[deck.rawValue] ?? true,
                tint: .blue
            ) {
                controller.setKeyLocked(deck, !(controller.keyLocked[deck.rawValue] ?? true))
            }
            .help("Key lock: keep pitch fixed while tempo changes")

            MacConsoleButton(
                title: controller.syncFeedback[deck.rawValue] ?? "SYNC",
                isActive: controller.syncFeedback[deck.rawValue]?.contains("SYNC") == true,
                tint: tint,
                isEnabled: state.status.isReady && engine[deck.other].status.isReady
            ) {
                controller.sync(deck)
            }
            .help("Match this deck to Deck \(deck.other.label). Uses phase when beat grids are available, otherwise tempo only.")

            tempoControl
        }
    }

    @State private var cuePressed = false

    private var tempoControl: some View {
        let signed = (state.rate - 1) / 0.16
        return HStack(spacing: 4) {
            Text("TEMPO").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
            MacHorizontalFader(
                value: Binding(
                    get: { (signed.macClamped(to: -1...1) + 1) / 2 },
                    set: { newValue in controller.setTempo(deck, knobValue: newValue) }
                ),
                tint: tint,
                knobDiameter: 14
            )
            .frame(width: 70)
            Text(String(format: "%+.1f%%", (state.rate - 1) * 100))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 40, alignment: .leading)

            if abs(state.rate - 1) > 0.0005 {
                Button {
                    controller.resetTempo(deck)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("Reset tempo to 0%")
            }
        }
    }

    private var hotCueRow: some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { index in
                let cue = controller.hotCues[deck.rawValue]?.first { $0.hotCueIndex == index }
                let color = hotCueColor(cue)
                Button {
                    controller.hotCue(deck, index: index)
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(color)
                            .frame(width: 7, height: 7)
                            .opacity(cue != nil ? 1 : 0.35)
                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(cue != nil ? color : .white.opacity(0.4))
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(cue != nil ? color.opacity(0.22) : Color.white.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(cue != nil ? color.opacity(0.8) : Color.white.opacity(0.10), lineWidth: 1.2))
                .disabled(!state.status.isReady)
                .help(cue != nil ? "Jump to hot cue \(index + 1)" : "Set hot cue \(index + 1) here")
            }
        }
    }

    private var transportShortcutRow: some View {
        HStack(spacing: 7) {
            MacInlineShortcutHint(deck == .a ? "W" : "O", detail: "play")
            MacInlineShortcutHint(deck == .a ? "Q" : "P", detail: "hold cue")
            MacInlineShortcutHint(deck == .a ? "Z / X" : ", / .", detail: "jog")
            Spacer(minLength: 4)
            MacInlineShortcutHint(deck == .a ? "F" : "H", detail: "key lock")
            MacInlineShortcutHint(deck == .a ? "G" : ";", detail: "sync")
            MacInlineShortcutHint(deck == .a ? "C / V" : "N / M", detail: "tempo")
        }
    }

    private var hotCueShortcutRow: some View {
        let keys = deck == .a ? ["1", "2", "3", "4"] : ["7", "8", "9", "0"]
        return HStack(spacing: 6) {
            ForEach(keys, id: \.self) { key in
                MacInlineShortcutHint(key)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var loopShortcutRow: some View {
        HStack(spacing: 7) {
            MacInlineShortcutHint("[", detail: "½ focused")
            MacInlineShortcutHint(deck == .a ? "E" : "I", detail: "loop")
            MacInlineShortcutHint("]", detail: "2× focused")
            MacInlineShortcutHint(deck == .a ? "D" : "J", detail: "echo")
            Spacer()
        }
    }

    private var mixerShortcutRow: some View {
        HStack(spacing: 7) {
            MacInlineShortcutHint(deck == .a ? "A / S" : "L / K", detail: "filter − / +")
            MacInlineShortcutHint("R", detail: "focused FX reset")
            MacInlineShortcutHint("⌥ DRAG", detail: "fine knobs")
            Spacer()
        }
    }

    private func hotCueColor(_ cue: CuePoint?) -> Color {
        guard let cue else { return .gray }
        return macCueColor(cue)
    }

    private var loopRow: some View {
        HStack(spacing: 6) {
            MacConsoleButton(title: "½", isEnabled: state.status.isReady) { controller.halveLoop(deck) }
            MacConsoleButton(
                title: state.loopStartSeconds != nil ? "LOOP ON" : "LOOP",
                isActive: state.loopStartSeconds != nil,
                tint: tint,
                isEnabled: state.status.isReady
            ) {
                controller.toggleLoop(deck)
            }
            MacConsoleButton(title: "2×", isEnabled: state.status.isReady) { controller.doubleLoop(deck) }
            MacConsoleButton(
                title: state.delayWet > 0.02 ? "ECHO ON" : "ECHO",
                isActive: state.delayWet > 0.02,
                tint: .cyan,
                isEnabled: state.status.isReady
            ) {
                controller.toggleEcho(deck)
            }
            Spacer()
            if let length = state.loopLengthSeconds {
                Text(String(format: "%.1fs", length))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private var mixerRow: some View {
        HStack(spacing: 14) {
            MacKnob(
                label: "Low",
                value: Binding(
                    get: { MacDeckUnits.eqKnob(fromDecibels: state.low) },
                    set: { engine.setEQ(.low, on: deck, toDecibels: MacDeckUnits.eqDecibels(fromKnob: $0)) }
                ),
                tint: tint, resetValue: 0.5, valueLabel: String(format: "%+.0f", state.low)
            )
            MacKnob(
                label: "Mid",
                value: Binding(
                    get: { MacDeckUnits.eqKnob(fromDecibels: state.mid) },
                    set: { engine.setEQ(.mid, on: deck, toDecibels: MacDeckUnits.eqDecibels(fromKnob: $0)) }
                ),
                tint: tint, resetValue: 0.5, valueLabel: String(format: "%+.0f", state.mid)
            )
            MacKnob(
                label: "High",
                value: Binding(
                    get: { MacDeckUnits.eqKnob(fromDecibels: state.high) },
                    set: { engine.setEQ(.high, on: deck, toDecibels: MacDeckUnits.eqDecibels(fromKnob: $0)) }
                ),
                tint: tint, resetValue: 0.5, valueLabel: String(format: "%+.0f", state.high)
            )
            MacKnob(
                label: "Filter",
                value: Binding(
                    get: { MacDeckUnits.filterKnob(fromHertz: state.filterCutoff) },
                    set: { engine.setFilterCutoff(MacDeckUnits.filterHertz(fromKnob: $0), on: deck) }
                ),
                bipolar: false, tint: .cyan, resetValue: 1.0,
                valueLabel: state.filterCutoff >= MixEngine.filterOpenHertz ? "OPEN" : "\(Int(state.filterCutoff))Hz"
            )
            MacKnob(
                label: "Trim",
                value: Binding(get: { state.gain }, set: { engine.setGain($0, on: deck) }),
                bipolar: false, tint: .orange, resetValue: 1.0,
                valueLabel: String(format: "%.0f%%", state.gain * 100)
            )

            Spacer(minLength: 8)

            MacDeckSlice(deck: deck, read: MacDeckLevels.init) { levels in
                MacLevelMeter(level: levels.level, peak: levels.peak, tint: tint)
            }
            .frame(width: 6, height: 46)
        }
    }
}
