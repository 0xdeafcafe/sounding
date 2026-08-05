import SwiftUI

struct DJModeView: View {
    @EnvironmentObject var playerService: PlayerService
    @ObservedObject private var dj = DJTransitionService.shared
    @ObservedObject private var waveforms = WaveformService.shared
    @ObservedObject private var artworkColors = ArtworkColors.shared
    @Environment(\.dismiss) private var dismiss

    @FocusState private var focus: DJControl?
    @State private var showingGuide = false
    @State private var showingStartConfiguration = false

    var body: some View {
        #if DEBUG
        let _ = CrashRecorder.note(
            "DJModeView.body deckA=\(playerService.currentTrack?.id ?? "nil") "
            + "engineLive=\(playerService.isMixEngineLive) "
            + "djEnabled=\(dj.isEnabled)"
        )
        #endif
        console
            .frame(width: DJLayout.width, height: DJLayout.height, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                CinematicBackdrop(
                    artworkURL: playerService.currentTrack?.largeArtworkURL,
                    palette: artworkColors.current
                )
            )
            .ignoresSafeArea()
        .onExitCommand { dismiss() }
        .onPlayPauseCommand { playerService.togglePlayPause() }
        .defaultFocus($focus, playerService.canStartMix ? DJControl.mixNow : DJControl.close)
        .onReceive(NotificationCenter.default.publisher(for: .sessionExpired)) { _ in
            dismiss()
        }
        .onAppear {
            dj.isEnabled = true
            playerService.armMixSessionIfNeeded()
            prime()
        }
        .onChange(of: playerService.queue) { _, _ in prime() }
        .onChange(of: playerService.currentIndex) { _, _ in prime() }
        .fullScreenCover(isPresented: $showingGuide) {
            DJModeGuideView()
        }
        .sheet(isPresented: $showingStartConfiguration) {
            AutoDJStartConfigurationView(configuration: SettingsStore.shared.djStartConfiguration) { configuration in
                playerService.startDJSession(configuration: configuration, reconfigure: true)
            }
        }
    }

    private var console: some View {
        ZStack(alignment: .topLeading) {
            header
                .focusSection()
                .frame(width: DJLayout.contentWidth, height: 64)
                .position(x: DJLayout.width / 2, y: 52)

            DJDeckColumn(
                deck: .a,
                track: deckATrack,
                readout: readoutA,
                progress: playerService.progress,
                isPlaying: playerService.isPlaying,
                emphasis: 1.0,
                emptyMessage: "Nothing playing"
            )
            .frame(width: DJLayout.deckColumnWidth, height: DJLayout.deckColumnHeight, alignment: .top)
            .position(x: DJLayout.deckACenter.x, y: DJLayout.deckColumnCenterY)

            DJDeckColumn(
                deck: .b,
                track: deckBTrack,
                readout: readoutB,
                progress: incomingDeckProgress,
                isPlaying: incomingDeckIsPlaying,
                emphasis: 0.42 + 0.58 * mixProgress,
                emptyMessage: "Queue is empty"
            )
            .frame(width: DJLayout.deckColumnWidth, height: DJLayout.deckColumnHeight, alignment: .top)
            .position(x: DJLayout.deckBCenter.x, y: DJLayout.deckColumnCenterY)

            DJMixerPanel(
                plan: plan,
                decision: playerService.automaticMixDecision,
                currentTime: playerService.currentTime,
                automation: automation,
                barsLabel: barsLabel,
                isEstimated: readoutA.isEstimated || readoutB.isEstimated,
                hasNext: deckBTrack != nil,
                status: mixStatus,
                isMeasured: playerService.isMixEngineLive
            )
            .frame(width: DJLayout.mixer.width, height: DJLayout.mixer.height)
            .position(x: DJLayout.mixer.midX, y: DJLayout.mixer.midY)

            DJWaveformPanel(timeline: timeline)
                .frame(width: DJLayout.waveform.width, height: DJLayout.waveform.height)
                .position(x: DJLayout.waveform.midX, y: DJLayout.waveform.midY)

            transportRow
                .focusSection()
                .frame(width: DJLayout.contentWidth, height: 64)
                .position(x: DJLayout.width / 2, y: 972)
        }
        .frame(width: DJLayout.width, height: DJLayout.height, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: Space.snug) {
            Eyebrow(text: "Decks", tint: Color.scAccent.opacity(0.95))
            DJModePill(mode: mode)
            Menu {
                ForEach(DJProfile.all) { profile in
                    Button {
                        playerService.setDJProfile(profile.id)
                    } label: {
                        Label(
                            profile.displayName,
                            systemImage: playerService.djProfile?.id == profile.id ? "checkmark" : "circle"
                        )
                    }
                }
            } label: {
                Label(playerService.djProfile?.displayName ?? "Auto DJ", systemImage: "slider.horizontal.3")
                    .font(.tvCalloutEmph)
            }
            DJPathPill(isEngineLive: playerService.isMixEngineLive)
            Spacer(minLength: 0)
            Button { showingStartConfiguration = true } label: {
                Label("Session", systemImage: "slider.horizontal.3")
                    .font(.tvCalloutEmph)
            }
            Button { showingGuide = true } label: {
                Label("How it works", systemImage: "questionmark.circle")
                    .font(.tvCalloutEmph)
            }
            DJCloseButton(focus: $focus) { dismiss() }
        }
    }

    private var transportRow: some View {
        HStack(spacing: Space.snug) {
            DJPillButton(
                control: .mixNow,
                focus: $focus,
                title: mixInProgress ? (isMixLive ? "Mixing…" : "Cutting…") : "Mix Now",
                icon: "arrow.triangle.merge",
                isEnabled: playerService.canStartMix,
                isActive: mixInProgress
            ) {
                playerService.startMix()
            }

            DJPillButton(
                control: .seekBackward,
                focus: $focus,
                title: "30s",
                icon: "gobackward.30",
                isEnabled: playerService.currentTrack != nil,
                isActive: false
            ) {
                playerService.seekBackward(30)
            }

            DJPillButton(
                control: .seekForward,
                focus: $focus,
                title: "30s",
                icon: "goforward.30",
                isEnabled: playerService.currentTrack != nil,
                isActive: false
            ) {
                playerService.seekForward(30)
            }

            DJPillButton(
                control: .skip,
                focus: $focus,
                title: "Skip",
                icon: "forward.fill",
                isEnabled: deckBTrack != nil,
                isActive: false
            ) {
                Task { await playerService.playNext() }
            }

            DJPillButton(
                control: .manual,
                focus: $focus,
                title: mode == .auto ? "Manual" : "Auto",
                icon: mode == .auto ? "hand.raised.fill" : "wand.and.stars",
                isEnabled: true,
                isActive: mode == .manual
            ) {
                playerService.setAutomaticMixEnabled(!playerService.isAutoMixEnabled)
            }

            DJPillButton(
                control: .turnOff,
                focus: $focus,
                title: "Turn Off",
                icon: "power",
                isEnabled: true,
                isActive: false
            ) {
                playerService.setAutomaticMixEnabled(false)
                dj.isEnabled = false
                dismiss()
            }

            Spacer(minLength: 0)

            tempoReadout
        }
    }

    @ViewBuilder
    private var tempoReadout: some View {
        if let from = readoutA.bpm, let to = readoutB.bpm, from > 0 {
            let drift = (to / from - 1) * 100
            let tilde = (readoutA.isEstimated || readoutB.isEstimated) ? "~" : ""

            HStack(spacing: Space.tight) {
                Text("\(tilde)\(String(format: "%.1f", from))")
                Image(systemName: "arrow.right")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(.white.opacity(0.35))
                Text("\(tilde)\(String(format: "%.1f", to)) BPM")
                Text("·").foregroundStyle(.white.opacity(0.25))
                Text(String(format: "%+.1f%%", drift))
                    .foregroundStyle(abs(drift) <= 6 ? Color.scAccent : Color.scError.opacity(0.9))
            }
            .font(.system(size: 22, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.80))
        } else {
            Text(deckBTrack == nil ? "End of queue" : "Tempo unknown")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    private var mode: DJRunMode { playerService.isAutoMixEnabled ? .auto : .manual }

    /// PlayerService publishes coalesced 20 Hz telemetry. Reading the engine
    /// from those updates avoids rebuilding this 1080p console for every
    /// individual 60 Hz EQ/filter automation write.
    private var mixEngine: MixEngine { .shared }

    private var deckATrack: Track? { playerService.currentTrack }

    private var deckBTrack: Track? { playerService.upcomingTrack }

    private var readoutA: DeckReadout {
        DeckReadout(deckATrack.map { dj.state(for: $0.id) } ?? .pending)
    }

    private var readoutB: DeckReadout {
        DeckReadout(deckBTrack.map { dj.state(for: $0.id) } ?? .pending)
    }

    private var plan: TransitionPlan? {
        guard let a = deckATrack, let b = deckBTrack else { return nil }
        return dj.transition(from: a, to: b)
    }

    private func prime() {
        dj.analyzeUpcoming(in: playerService.queue, from: playerService.currentIndex)
        if let a = deckATrack { waveforms.load(a) }
        if let b = deckBTrack { waveforms.load(b) }
    }

    private var mixSeconds: TimeInterval? { playerService.plannedMixSeconds() }

    private var mix: MixSpan? {
        if let running = playerService.mixWindow {
            return MixSpan(
                start: running.start,
                end: running.end,
                progress: running.progress,
                isLive: running.isLive
            )
        }
        guard let seconds = mixSeconds, mode == .auto else { return nil }
        let duration = max(playerService.duration, 1)
        let start = playerService.plannedMixPointSeconds() ?? max(0, duration - seconds)
        return MixSpan(
            start: start,
            end: duration,
            progress: ((playerService.currentTime - start) / max(0.01, seconds)).clampedToUnit,
            isLive: false
        )
    }

    private var mixProgress: Double { mix?.progress ?? 0 }

    private var mixInProgress: Bool { playerService.mixWindow != nil }

    private var isMixLive: Bool { playerService.mixWindow?.isLive == true }

    private var mixStatus: DJMixStatus {
        if let window = playerService.mixWindow {
            return window.isLive ? .mixingLive : .cutting
        }
        switch playerService.mixEngineState {
        case .off:
            return .planPreview(nil)
        case .unavailable(let reason):
            return .planPreview(reason)
        case .preparing(let fraction):
            return .preparingDeck(fraction)
        case .live:
            guard deckBTrack != nil else { return .liveNoNext }
            if mode == .auto, playerService.adaptiveMixPlan == nil { return .thinking }
            switch playerService.incomingDeck {
            case .ready:
                return playerService.adaptiveMixPlan?.templateId == DJTemplates.cutOnTheOne
                    ? .cleanCutArmed
                    : .armed
            case .loading(let f):   return .arming(f)
            case .failed(let why):  return .cutNext(why)
            case .idle:             return .arming(0)
            }
        }
    }

    private var incomingDeckProgress: Double {
        guard playerService.isMixEngineLive else { return mixProgress }
        let deck = mixEngine[playerService.liveDeck.other]
        guard deck.isPlaying || deck.position > 0 else { return 0 }
        return deck.progress
    }

    private var incomingDeckIsPlaying: Bool {
        if playerService.isMixEngineLive {
            return mixEngine[playerService.liveDeck.other].isPlaying
        }
        return playerService.isPlaying && mixProgress > 0
    }

    private var automation: MixerAutomation {
        if playerService.isMixEngineLive {
            let engineFade = mixEngine.crossfade
            return MixerAutomation.measured(
                outgoing: mixEngine[playerService.liveDeck],
                incoming: mixEngine[playerService.liveDeck.other],
                crossfade: playerService.liveDeck == .a ? engineFade : 1 - engineFade
            )
        }
        return MixerAutomation.evaluate(plan: plan, progress: mixProgress)
    }

    private var barsLabel: String? {
        if let adaptive = playerService.adaptiveMixPlan {
            if adaptive.templateId == DJTemplates.cutOnTheOne {
                return "On the one · \(Self.clock(adaptive.mixPointSeconds))"
            }
            return "\(Int(adaptive.transitionSeconds.rounded()))s · starts \(Self.clock(adaptive.mixPointSeconds))"
        }
        guard let plan else { return nil }
        guard plan.totalBars > 0 else { return "Hard cut" }
        guard let seconds = mixSeconds else { return "\(plan.totalBars) bars" }
        let tilde = readoutA.isEstimated ? "~" : ""
        return "\(plan.totalBars) bars · \(tilde)\(Self.clock(seconds))"
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    private var timeline: DJTimeline {
        let durationA = max(playerService.duration, deckATrack?.duration ?? 0)
        let laneA = DJWaveformLane(
            tint: DJPalette.deckA,
            state: deckATrack.map { waveforms.state(for: $0.id) } ?? .pending,
            start: 0,
            duration: max(durationA, 1),
            bpm: readoutA.bpm,
            trackId: deckATrack?.id
        )

        guard let deckBTrack else {
            return DJTimeline(
                total: max(durationA, 1),
                lanes: [laneA],
                playhead: playerService.currentTime,
                overlap: nil
            )
        }

        let durationB = max(deckBTrack.duration, 1)
        let bStart = mix?.start ?? durationA
        let laneB = DJWaveformLane(
            tint: DJPalette.deckB,
            state: waveforms.state(for: deckBTrack.id),
            start: bStart,
            duration: durationB,
            bpm: readoutB.bpm,
            trackId: deckBTrack.id
        )

        let overlap: ClosedRange<TimeInterval>? = mix.map { window in
            window.start...max(window.start + 0.5, min(window.end, durationA))
        }

        return DJTimeline(
            total: max(bStart + durationB, 1),
            lanes: [laneA, laneB],
            playhead: playerService.currentTime,
            overlap: overlap
        )
    }

}

private enum DJRunMode {
    case auto
    case manual

    var label: String {
        switch self {
        case .auto:   return "Auto"
        case .manual: return "Manual"
        }
    }
}

private enum DJControl: Hashable {
    case close
    case mixNow
    case seekBackward
    case seekForward
    case skip
    case manual
    case turnOff
}

private enum DJDeck {
    case a
    case b

    var tag: String {
        switch self {
        case .a: return "Now Playing"
        case .b: return "Up Next"
        }
    }

    var letter: String {
        switch self {
        case .a: return "A"
        case .b: return "B"
        }
    }

    var tint: Color {
        switch self {
        case .a: return DJPalette.deckA
        case .b: return DJPalette.deckB
        }
    }
}

private enum DJPalette {
    static let deckA = Color(red: 1.00, green: 0.478, blue: 0.157)   // 255,122,40
    static let deckB = Color(red: 0.486, green: 0.455, blue: 1.00)   // 124,116,255
}

private enum DJLayout {
    static let width: CGFloat = 1920
    static let height: CGFloat = 1080
    static let margin: CGFloat = 80
    static var contentWidth: CGFloat { width - margin * 2 }

    static let wheelDiameter: CGFloat = 320
    static let deckACenter = CGPoint(x: 350, y: 300)
    static let deckBCenter = CGPoint(x: 1570, y: 300)
    static let deckColumnWidth: CGFloat = 500
    static let deckColumnHeight: CGFloat = 540
    static var deckColumnCenterY: CGFloat {
        deckACenter.y - wheelDiameter / 2 + deckColumnHeight / 2
    }

    static let mixer = CGRect(x: 700, y: 150, width: 520, height: 500)
    static let waveform = CGRect(x: 80, y: 700, width: 1760, height: 210)
}

private struct MixSpan {
    let start: TimeInterval
    let end: TimeInterval
    let progress: Double
    let isLive: Bool

    var duration: TimeInterval { max(0.01, end - start) }
}

private enum DJMixStatus {
    case planPreview(String?)
    case preparingDeck(Double)
    case arming(Double)
    case thinking
    case armed
    case cleanCutArmed
    case liveNoNext
    case cutNext(String)
    case mixingLive
    case cutting

    var label: String {
        switch self {
        case .planPreview:              return "PLAN PREVIEW"
        case .preparingDeck(let f):     return "PREPARING \(Int((f * 100).rounded()))%"
        case .arming(let f):            return "ARMING \(Int((f * 100).rounded()))%"
        case .thinking:                 return "THINKING"
        case .armed:                    return "MIX ARMED"
        case .cleanCutArmed:            return "CUT ARMED"
        case .liveNoNext:               return "LIVE ENGINE"
        case .cutNext:                  return "NEXT: CUT"
        case .mixingLive:               return "MIXING LIVE"
        case .cutting:                  return "CUTTING"
        }
    }

    var note: String? {
        switch self {
        case .planPreview(let reason):
            let head = "Knobs are a drawing. Audio hard-cuts."
            guard let reason, !reason.isEmpty else { return head }
            return head + " " + reason
        case .preparingDeck:
            return "Decoding this track for the mixer. Still on the plain player."
        case .arming:
            return "Loading the incoming deck. Hard cut if it isn't ready in time."
        case .thinking:
            return "Listening to both tracks, ranking only the moves this engine can play."
        case .armed:
            return "Crossfader and EQ will drive real audio."
        case .cleanCutArmed:
            return "A blend was too risky, so the handoff will land cleanly on the one."
        case .liveNoNext:
            return "Mixer has the audio. Nothing queued to mix into."
        case .cutNext(let reason):
            return "Mixer has the audio, but the incoming track can't be decoded, so "
                + "this transition cuts. " + reason
        case .mixingLive:
            return "Both decks playing. This fader is the audio."
        case .cutting:
            return "Incoming deck isn't mixable, or wasn't ready. This ends in a cut."
        }
    }

    var willMix: Bool {
        switch self {
        case .planPreview, .preparingDeck, .thinking, .cutNext, .cutting, .liveNoNext: return false
        case .arming, .armed, .cleanCutArmed, .mixingLive: return true
        }
    }

    var tint: Color {
        switch self {
        case .planPreview, .cutting:    return .white.opacity(0.40)
        case .preparingDeck, .arming, .thinking: return Color.scAccent.opacity(0.70)
        case .cutNext:                  return Color.scError.opacity(0.85)
        case .armed, .cleanCutArmed, .liveNoNext: return Color.scAccent
        case .mixingLive:               return Color(red: 0.29, green: 0.93, blue: 0.51)
        }
    }
}

private struct DeckReadout {
    var bpm: Double?
    var key: String?
    var energy: Double?
    var isEstimated = false
    var isAnalyzing = false
    var hasAnalysis = false

    init(_ state: AnalysisState) {
        switch state {
        case .pending, .analyzing:
            isAnalyzing = true
        case .analyzed(let analysis):
            bpm = analysis.bpm
            key = analysis.key
            energy = analysis.energy
            isEstimated = analysis.isEstimated
            hasAnalysis = true
        case .failed:
            break
        }
    }
}

private struct MixerAutomation {
    var aLow: Double = 0
    var aMid: Double = 0
    var aHigh: Double = 0
    var bLow: Double = -1      // incoming lows start closed; that's the swap
    var bMid: Double = 0
    var bHigh: Double = 0
    var crossfade: Double = 0  // 0 = deck A, 1 = deck B

    static func measured(
        outgoing: MixEngine.DeckState,
        incoming: MixEngine.DeckState,
        crossfade: Double
    ) -> MixerAutomation {
        MixerAutomation(
            aLow: knobPosition(outgoing.low),
            aMid: knobPosition(outgoing.mid),
            aHigh: knobPosition(outgoing.high),
            bLow: knobPosition(incoming.low),
            bMid: knobPosition(incoming.mid),
            bHigh: knobPosition(incoming.high),
            crossfade: crossfade.clampedToUnit
        )
    }

    private static func knobPosition(_ decibels: Double) -> Double {
        decibels >= 0
            ? Swift.min(1, decibels / 12)
            : Swift.max(-1, decibels / 24)
    }

    static func evaluate(plan: TransitionPlan?, progress: Double) -> MixerAutomation {
        var value = MixerAutomation()
        guard let plan, !plan.steps.isEmpty else { return value }

        let weights = plan.steps.map { Double(max($0.bars, 1)) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return value }

        let shares = plan.steps.map { fadeShare(of: $0.technique) }
        let shareTotal = max(0.001, shares.reduce(0, +))

        let p = progress.clampedToUnit
        var elapsed: Double = 0
        var fader: Double = 0

        for (index, step) in plan.steps.enumerated() {
            let span = weights[index] / total
            let stepStart = elapsed
            elapsed += span

            var target = value
            apply(step.technique, to: &target)
            if index == plan.steps.count - 1 {
                target.bLow = 0
                target.bMid = 0
                target.bHigh = 0
            }
            target.crossfade = min(1, fader + shares[index] / shareTotal)

            if p <= elapsed || index == plan.steps.count - 1 {
                let local = span > 0 ? ((p - stepStart) / span).clampedToUnit : 1
                return value.blended(towards: target, t: local)
            }

            value = target
            fader = target.crossfade
        }

        return value
    }

    private static func apply(_ technique: TransitionTechnique, to value: inout MixerAutomation) {
        switch technique {
        case .phraseAlign, .beatMatch:
            break                                   // alignment only — no EQ move
        case .bassSwap:
            value.aLow = -1
            value.bLow = 0
        case .lowpassSweep:
            value.aHigh = -1
            value.aMid = -0.6
        case .highpassSweep:
            value.aLow = -1
            value.aMid = -0.3
        case .loopOut:
            break                                   // a loop is transport, not EQ
        case .echoOut:
            value.aMid = -0.4
            value.aHigh = -0.5
        case .quickCut:
            value.aLow = -1
            value.aMid = -1
            value.aHigh = -1
            value.bLow = 0
            value.bMid = 0
            value.bHigh = 0
        }
    }

    private static func fadeShare(of technique: TransitionTechnique) -> Double {
        switch technique {
        case .phraseAlign:   return 0.02
        case .beatMatch:     return 0.15
        case .bassSwap:      return 0.50
        case .lowpassSweep:  return 0.25
        case .highpassSweep: return 0.25
        case .loopOut:       return 0.10
        case .echoOut:       return 0.20
        case .quickCut:      return 1.00
        }
    }

    private func blended(towards other: MixerAutomation, t: Double) -> MixerAutomation {
        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        return MixerAutomation(
            aLow: lerp(aLow, other.aLow),
            aMid: lerp(aMid, other.aMid),
            aHigh: lerp(aHigh, other.aHigh),
            bLow: lerp(bLow, other.bLow),
            bMid: lerp(bMid, other.bMid),
            bHigh: lerp(bHigh, other.bHigh),
            crossfade: lerp(crossfade, other.crossfade)
        )
    }
}

private struct DJDeckColumn: View {
    let deck: DJDeck
    let track: Track?
    let readout: DeckReadout
    let progress: Double
    let isPlaying: Bool
    let emphasis: Double
    let emptyMessage: String

    var body: some View {
        VStack(spacing: 0) {
            DJJogWheel(
                artworkURL: track?.artworkURL,
                identity: track?.title ?? "Deck \(deck.letter)",
                tint: deck.tint,
                progress: progress,
                bpm: readout.bpm,
                isSpinning: isPlaying && track != nil,
                letter: deck.letter
            )

            Spacer().frame(height: Space.base)

            Eyebrow(text: deck.tag, tint: deck.tint.opacity(0.95))

            Text(track?.title ?? emptyMessage)
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(track == nil ? .white.opacity(0.35) : .white)
                .kerning(-0.5)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.top, Space.tight)
                .shadow(color: .black.opacity(0.45), radius: 10, y: 4)

            Text(track?.user.displayName ?? " ")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white.opacity(0.50))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.top, 2)

            chips
                .padding(.top, Spacing.sm)

            if readout.isEstimated {
                Text("~ estimated, not measured")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.32))
                    .padding(.top, 6)
            }
        }
        .frame(width: DJLayout.deckColumnWidth)
        .opacity(emphasis)
        .animation(Motion.ambient, value: emphasis)
    }

    @ViewBuilder
    private var chips: some View {
        if track == nil {
            EmptyView()
        } else if readout.hasAnalysis {
            HStack(spacing: Space.tight) {
                DJChip(
                    label: "BPM",
                    value: readout.bpm.map { String(format: "%.0f", $0) } ?? "—",
                    tint: deck.tint,
                    isEstimated: readout.isEstimated && readout.bpm != nil
                )
                DJChip(
                    label: "Key",
                    value: readout.key ?? "—",
                    tint: deck.tint,
                    isEstimated: readout.isEstimated && readout.key != nil
                )
                DJChip(
                    label: "Energy",
                    value: readout.energy.map { "\(Int(($0 * 100).rounded()))%" } ?? "—",
                    tint: deck.tint,
                    isEstimated: readout.isEstimated
                )
            }
        } else if readout.isAnalyzing {
            HStack(spacing: Space.tight) {
                ProgressView().tint(.white.opacity(0.6))
                Text("Analysing…")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .frame(height: 44)
        } else {
            Text("No analysis")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
                .frame(height: 44)
        }
    }
}

private struct DJJogWheel: View {
    let artworkURL: URL?
    let identity: String
    let tint: Color
    let progress: Double
    let bpm: Double?
    let isSpinning: Bool
    let letter: String

    @State private var spin: Double = 0
    @State private var beatPhase: Double = 0

    private var barSeconds: Double? {
        guard let bpm, bpm > 20 else { return nil }
        return 240.0 / bpm
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.04))
                .liquidGlass(in: Circle())

            Circle()
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.32), .white.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.5
                )

            beatRing
            progressArc

            artwork
                .frame(width: DJLayout.wheelDiameter * 0.58, height: DJLayout.wheelDiameter * 0.58)
                .clipShape(Circle())
                .overlay(Circle().stroke(.white.opacity(0.14), lineWidth: 1))
                .rotationEffect(.degrees(spin))
                .shadow(color: .black.opacity(0.55), radius: 24, y: 12)

            Circle()
                .fill(.black.opacity(0.85))
                .frame(width: 22, height: 22)
                .overlay(Circle().stroke(.white.opacity(0.30), lineWidth: 1))

            positionMarker

            Text(letter)
                .font(.system(size: 22, weight: .black, design: .rounded))
                .foregroundStyle(tint)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background(Capsule().fill(.black.opacity(0.45)))
                .overlay(Capsule().stroke(tint.opacity(0.45), lineWidth: 1))
                .offset(y: DJLayout.wheelDiameter / 2 - 18)
        }
        .frame(width: DJLayout.wheelDiameter, height: DJLayout.wheelDiameter)
        .shadow(color: .black.opacity(0.45), radius: 40, y: 22)
        .onAppear { restartAnimations() }
        .onChange(of: isSpinning) { _, _ in restartAnimations() }
        .onChange(of: bpm) { _, _ in restartAnimations() }
    }

    private var beatRing: some View {
        ZStack {
            ForEach(0..<48, id: \.self) { index in
                let fraction = Double(index) / 48.0
                Capsule()
                    .fill(.white.opacity(fraction <= progress ? 0.55 : 0.16))
                    .frame(width: 2, height: index % 4 == 0 ? 14 : 8)
                    .offset(y: -DJLayout.wheelDiameter / 2 + 16)
                    .rotationEffect(.degrees(fraction * 360))
            }

            if barSeconds != nil {
                Capsule()
                    .fill(tint)
                    .frame(width: 3, height: 16)
                    .offset(y: -DJLayout.wheelDiameter / 2 + 16)
                    .shadow(color: tint.opacity(0.8), radius: 8)
                    .rotationEffect(.degrees(beatPhase))
                    .opacity(isSpinning ? 1 : 0.35)
            }
        }
    }

    private var progressArc: some View {
        Circle()
            .trim(from: 0, to: max(0.001, progress.clampedToUnit))
            .stroke(
                AngularGradient(
                    colors: [tint.opacity(0.35), tint],
                    center: .center,
                    startAngle: .degrees(-90),
                    endAngle: .degrees(270)
                ),
                style: StrokeStyle(lineWidth: 6, lineCap: .round)
            )
            .rotationEffect(.degrees(-90))
            .padding(5)
            .shadow(color: tint.opacity(0.55), radius: 12)
    }

    private var positionMarker: some View {
        Circle()
            .fill(tint)
            .frame(width: 12, height: 12)
            .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1.5))
            .shadow(color: tint.opacity(0.9), radius: 10)
            .offset(y: -DJLayout.wheelDiameter / 2 + 8)
            .rotationEffect(.degrees(progress.clampedToUnit * 360))
            .animation(.linear(duration: 0.5), value: progress)
    }

    @ViewBuilder
    private var artwork: some View {
        ArtworkImage(url: artworkURL, variant: .hero) {
            GeneratedArtworkCard(
                identity: identity,
                mode: .blob,
                style: .tv,
                glyphOverride: .waveform
            )
        }
    }

    private func restartAnimations() {
        withAnimation(nil) { spin = 0 }
        if isSpinning {
            withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) {
                spin = 360
            }
        }

        withAnimation(nil) { beatPhase = 0 }
        if let barSeconds, isSpinning {
            withAnimation(.linear(duration: barSeconds).repeatForever(autoreverses: false)) {
                beatPhase = 360
            }
        }
    }
}

private struct DJChip: View {
    let label: String
    let value: String
    let tint: Color
    let isEstimated: Bool

    var body: some View {
        VStack(spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 13, weight: .heavy))
                .kerning(1.4)
                .foregroundStyle(tint.opacity(isEstimated ? 0.55 : 0.95))
            Text(isEstimated ? "~\(value)" : value)
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(isEstimated ? 0.62 : 0.95))
        }
        .frame(minWidth: 92)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 6)
        .background(Capsule().fill(.ultraThinMaterial).opacity(0.55))
        .overlay(Capsule().stroke(.white.opacity(0.10), lineWidth: 1))
    }
}

private struct DJMixerPanel: View {
    let plan: TransitionPlan?
    let decision: DJAutomaticMixDecision
    let currentTime: TimeInterval
    let automation: MixerAutomation
    let barsLabel: String?
    let isEstimated: Bool
    let hasNext: Bool
    let status: DJMixStatus
    let isMeasured: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Eyebrow(text: "Transition")
                Spacer(minLength: 0)
                statusChip
            }

            Text(headline)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, Spacing.sm)

            Text(subhead)
                .font(.system(size: 19, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(subheadTint)
                .padding(.top, 2)

            if let note = decisionNote {
                Text(note)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.38))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }

            Spacer(minLength: Space.tight)

            knobRow(deck: .a, values: (automation.aLow, automation.aMid, automation.aHigh))

            Spacer(minLength: Space.tight)

            knobRow(deck: .b, values: (automation.bLow, automation.bMid, automation.bHigh))

            Spacer(minLength: Spacing.sm)

            DJCrossfader(
                position: automation.crossfade,
                isLive: isMeasured && hasNext,
                isMeasured: isMeasured
            )
        }
        .padding(Space.base)
        .frame(width: DJLayout.mixer.width, height: DJLayout.mixer.height, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
        .liquidGlass(in: RoundedRectangle(cornerRadius: 34, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 44, y: 22)
    }

    private var statusChip: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.tint)
                .frame(width: 7, height: 7)
                .opacity(status.willMix ? 1 : 0.45)
            Text(status.label)
                .font(.system(size: 12, weight: .heavy))
                .kerning(1.4)
                .monospacedDigit()
                .foregroundStyle(status.tint)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .overlay(Capsule().stroke(status.tint.opacity(0.45), lineWidth: 1))
    }

    private var headline: String {
        guard hasNext else { return "End of queue" }
        if let templateName = decision.templateName { return templateName }
        guard let plan else { return "Planning…" }
        return plan.primaryTechnique.label
    }

    private var subhead: String {
        guard hasNext else { return "Nothing to mix into" }
        let parts = [barsLabel, decision.countdownText(currentTime: currentTime)].compactMap { $0 }
        return parts.isEmpty ? "Listening and planning" : parts.joined(separator: " · ")
    }

    private var decisionNote: String? {
        if decision.phase != .off, let reasoning = decision.reasoning, !reasoning.isEmpty {
            return reasoning
        }
        return status.note
    }

    private var subheadTint: Color {
        guard hasNext, barsLabel != nil else { return .white.opacity(0.30) }
        return Color.scAccent.opacity(isEstimated ? 0.65 : 1)
    }

    private func knobRow(deck: DJDeck, values: (Double, Double, Double)) -> some View {
        HStack(spacing: Space.tight) {
            Text(deck.letter)
                .font(.system(size: 18, weight: .black, design: .rounded))
                .foregroundStyle(deck.tint)
                .frame(width: 20)

            DJKnob(label: "Low", value: values.0, tint: deck.tint, isMeasured: isMeasured)
            DJKnob(label: "Mid", value: values.1, tint: deck.tint, isMeasured: isMeasured)
            DJKnob(label: "High", value: values.2, tint: deck.tint, isMeasured: isMeasured)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct DJKnob: View {
    let label: String
    let value: Double
    let tint: Color
    let isMeasured: Bool

    private let diameter: CGFloat = 72
    private let sweep: Double = 135

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(.black.opacity(0.28))
                    .overlay(Circle().stroke(.white.opacity(0.10), lineWidth: 1))

                arc(from: -sweep, to: sweep)
                    .stroke(.white.opacity(0.12), style: StrokeStyle(lineWidth: 5, lineCap: .round))

                arc(from: min(0, angle), to: max(0, angle))
                    .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .shadow(color: tint.opacity(0.6), radius: 6)

                Capsule()
                    .fill(.white.opacity(0.22))
                    .frame(width: 2, height: 6)
                    .offset(y: -diameter / 2 + 1)

                Capsule()
                    .fill(.white.opacity(0.92))
                    .frame(width: 3, height: 18)
                    .offset(y: -diameter / 4 - 2)
                    .rotationEffect(.degrees(angle))
            }
            .frame(width: diameter, height: diameter)
            .animation(isMeasured ? nil : Motion.settle, value: value)

            Text(label.uppercased())
                .font(.system(size: 13, weight: .heavy))
                .kerning(1.2)
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
    }

    private var angle: Double { value.clamped(to: -1...1) * sweep }

    private func arc(from start: Double, to end: Double) -> Path {
        Path { path in
            path.addArc(
                center: CGPoint(x: diameter / 2, y: diameter / 2),
                radius: diameter / 2 - 3,
                startAngle: .degrees(start - 90),
                endAngle: .degrees(end - 90),
                clockwise: false
            )
        }
    }
}

private struct DJCrossfader: View {
    let position: Double
    let isLive: Bool
    let isMeasured: Bool

    private let trackHeight: CGFloat = 22
    private let width: CGFloat = DJLayout.mixer.width - Space.base * 2

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.black.opacity(0.32))
                    .frame(width: width, height: trackHeight)
                    .overlay(Capsule().stroke(.white.opacity(0.10), lineWidth: 1))

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [DJPalette.deckA, DJPalette.deckB],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: width, height: trackHeight)
                    .opacity(isLive ? 0.85 : 0.20)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: max(6, width * clamped))
                    }

                cap
                    .offset(x: max(0, min(width - 26, width * clamped - 13)))
            }
            .frame(width: width, height: trackHeight)

            HStack {
                Text("A")
                    .foregroundStyle(DJPalette.deckA.opacity(isLive ? 0.9 : 0.35))
                Spacer()
                Text("CROSSFADER")
                    .kerning(1.6)
                    .foregroundStyle(.white.opacity(0.28))
                Spacer()
                Text("B")
                    .foregroundStyle(DJPalette.deckB.opacity(isLive ? 0.9 : 0.35))
            }
            .font(.system(size: 13, weight: .heavy))
            .frame(width: width)
        }
        .animation(isMeasured ? nil : Motion.settle, value: position)
    }

    private var clamped: Double { position.clampedToUnit }

    private var cap: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(.white)
            .frame(width: 26, height: trackHeight + 14)
            .shadow(color: .black.opacity(0.5), radius: 8, y: 3)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(.black.opacity(0.20), lineWidth: 1)
            )
    }
}

private struct DJWaveformLane {
    let tint: Color
    let state: WaveformState
    let start: TimeInterval
    let duration: TimeInterval
    let bpm: Double?
    let trackId: String?
}

private struct DJTimeline {
    let total: TimeInterval
    let lanes: [DJWaveformLane]
    let playhead: TimeInterval
    let overlap: ClosedRange<TimeInterval>?
}

private struct DJWaveformPanel: View {
    let timeline: DJTimeline

    private let inset: CGFloat = Space.base
    private let laneGap: CGFloat = 10

    private var contentWidth: CGFloat { DJLayout.waveform.width - inset * 2 }
    private var contentHeight: CGFloat { DJLayout.waveform.height - inset * 2 }
    private var laneHeight: CGFloat { (contentHeight - laneGap) / 2 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            overlapBand
            lanes
            laneNotices
            playhead
        }
        .frame(width: contentWidth, height: contentHeight, alignment: .topLeading)
        .padding(inset)
        .frame(width: DJLayout.waveform.width, height: DJLayout.waveform.height)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.xl, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
        .liquidGlass(in: RoundedRectangle(cornerRadius: CornerRadius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.xl, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.40), radius: 36, y: 18)
    }

    private static let laneBarPitch: CGFloat = 3
    private static let laneBarGap: CGFloat = 2

    private var lanes: some View {
        ForEach(Array(timeline.lanes.enumerated()), id: \.offset) { index, lane in
            let x0 = xFor(lane.start)
            let width = max(1, xFor(lane.start + lane.duration) - x0)
            SCWaveformRenderer(
                envelope: Self.envelope(for: lane, width: width),
                duration: lane.duration,
                progress: progress(for: lane),
                showsPlayhead: false,
                beatGrid: lane.bpm.flatMap { $0 > 20 ? SCBeatGrid(bpm: $0) : nil },
                placeholder: Self.placeholder(for: lane.state),
                identity: lane.trackId,
                style: Self.laneStyle(tint: lane.tint)
            )
            .frame(width: width, height: laneHeight)
            .offset(x: x0, y: CGFloat(index) * (laneHeight + laneGap))
        }
    }

    private func progress(for lane: DJWaveformLane) -> Double {
        guard lane.duration > 0 else { return 0 }
        return ((timeline.playhead - lane.start) / lane.duration).clampedToUnit
    }

    private static func envelope(for lane: DJWaveformLane, width: CGFloat) -> [Float] {
        guard let waveform = lane.state.waveform, !waveform.isEmpty else { return [] }
        let count = max(1, Int(width / (laneBarPitch + laneBarGap)))
        return waveform.resampled(to: count)
    }

    private static func placeholder(for state: WaveformState) -> SCWaveformPlaceholder {
        switch state {
        case .pending, .loading:   return .loading
        case .ready(let waveform): return waveform.isEmpty ? .unavailable : .loading
        case .failed:              return .unavailable
        }
    }

    private static func laneStyle(tint: Color) -> SCWaveformStyle {
        var style = SCWaveformStyle.derived(from: .decksConsole, dense: true)
        style.barPitch = laneBarPitch
        style.barGap = laneBarGap
        style.barCornerRadius = 1
        style.unplayedShellColors = [tint.opacity(0.28)]
        style.playedShellColors = [tint.opacity(0.95)]
        style.showAxis = true
        style.axisColor = tint.opacity(0.30)
        style.beatPhraseColor = .white.opacity(0.10)
        style.beatBarColor = .white.opacity(0.06)
        style.beatBeatColor = .white.opacity(0.04)
        return style
    }

    @ViewBuilder
    private var overlapBand: some View {
        if let overlap = timeline.overlap {
            let x0 = xFor(overlap.lowerBound)
            let bandWidth = max(4, xFor(overlap.upperBound) - x0)

            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.scAccent.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.scAccent.opacity(0.40), lineWidth: 1)
                    )
                    .frame(width: bandWidth, height: contentHeight)

                Text("MIX")
                    .font(.system(size: 13, weight: .heavy))
                    .kerning(1.6)
                    .foregroundStyle(Color.scAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .fixedSize()
            }
            .frame(width: bandWidth, height: contentHeight, alignment: .top)
            .offset(x: x0)
        }
    }

    private var laneNotices: some View {
        ForEach(Array(timeline.lanes.enumerated()), id: \.offset) { index, lane in
            if let notice = Self.notice(for: lane.state) {
                let x0 = xFor(lane.start)
                Text(notice)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(lane.tint.opacity(0.55))
                    .frame(
                        width: max(80, xFor(lane.start + lane.duration) - x0),
                        height: laneHeight
                    )
                    .offset(x: x0, y: CGFloat(index) * (laneHeight + laneGap))
            }
        }
    }

    private static func notice(for state: WaveformState) -> String? {
        switch state {
        case .ready(let waveform):
            return waveform.isEmpty ? "Waveform is empty" : nil
        case .pending, .loading:
            return nil
        case .failed(let error):
            switch error {
            case .noWaveformURL:         return "No waveform for this track"
            case .imageOnly:             return "Waveform is image-only"
            case .notFound:              return "Waveform not found"
            case .malformedDocument:     return "Waveform couldn't be read"
            case .serverError, .network: return "Waveform unavailable"
            }
        }
    }

    private var playhead: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(.white)
                .frame(width: 2, height: contentHeight)
                .shadow(color: .white.opacity(0.75), radius: 6)

            Triangle()
                .fill(.white)
                .frame(width: 12, height: 7)
        }
        .frame(width: 12, height: contentHeight, alignment: .top)
        .offset(x: xFor(timeline.playhead) - 6)
        .animation(.linear(duration: 0.5), value: timeline.playhead)
    }

    private func xFor(_ time: TimeInterval) -> CGFloat {
        let total = max(timeline.total, 0.001)
        return CGFloat((time / total).clampedToUnit) * contentWidth
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.closeSubpath()
        }
    }
}

private struct DJModePill: View {
    let mode: DJRunMode

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(mode == .auto ? Color.scAccent : .white.opacity(0.55))
                .frame(width: 8, height: 8)
            Text(mode.label.uppercased())
                .font(.system(size: 14, weight: .heavy))
                .kerning(1.6)
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 6)
        .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 1))
        .liquidGlass(in: Capsule())
    }
}

private struct DJPathPill: View {
    let isEngineLive: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isEngineLive ? "slider.horizontal.3" : "play.circle")
                .font(.system(size: 13, weight: .heavy))
            Text(isEngineLive ? "MIXER" : "PLAYER")
                .font(.system(size: 14, weight: .heavy))
                .kerning(1.6)
        }
        .foregroundStyle(isEngineLive ? Color.scAccent : .white.opacity(0.55))
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 6)
        .overlay(
            Capsule().stroke(
                (isEngineLive ? Color.scAccent : Color.white).opacity(0.22),
                lineWidth: 1
            )
        )
        .liquidGlass(in: Capsule())
    }
}

private struct DJCloseButton: View {
    @FocusState.Binding var focus: DJControl?
    let action: () -> Void

    private var focused: Bool { focus == .close }

    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 24, weight: .heavy))
            .foregroundStyle(focused ? Color.scChromeFocusOn : .white.opacity(0.70))
            .frame(width: 64, height: 64)
            .background(
                Circle().fill(focused ? Color.scChromeFocus : .clear)
            )
            .overlay(
                Circle().stroke(focused ? .clear : .white.opacity(0.14), lineWidth: 1)
            )
            .liquidGlass(in: Circle())
            .scaleEffect(focused ? Focus.scale : 1.0)
            .shadow(
                color: focused ? Color.scFocusShadow : .clear,
                radius: focused ? Focus.shadowRadius : 0,
                y: focused ? Focus.shadowY : 0
            )
            .animation(Motion.focus, value: focused)
            .contentShape(Circle())
            .focusable()
            .focused($focus, equals: .close)
            .focusEffectDisabled()
            .onTapGesture(perform: action)
    }
}

private struct DJPillButton: View {
    let control: DJControl
    @FocusState.Binding var focus: DJControl?
    let title: String
    let icon: String
    let isEnabled: Bool
    let isActive: Bool
    let action: () -> Void

    private var focused: Bool { focus == control }

    var body: some View {
        HStack(spacing: Space.tight) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .heavy))
            Text(title)
                .font(.system(size: 24, weight: .semibold))
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, Space.base)
        .padding(.vertical, Spacing.sm)
        .background(
            Capsule().fill(focused ? Color.scChromeFocus : .clear)
        )
        .overlay(
            Capsule().stroke(focused ? .clear : .white.opacity(0.12), lineWidth: 1)
        )
        .liquidGlass(in: Capsule(), tint: isActive && !focused ? Color.scAccent.opacity(0.22) : nil)
        .scaleEffect(focused ? Focus.scale : 1.0)
        .shadow(
            color: focused ? Color.scFocusShadow : .clear,
            radius: focused ? Focus.shadowRadius : 0,
            y: focused ? Focus.shadowY : 0
        )
        .animation(Motion.focus, value: focused)
        .contentShape(Capsule())
        .focusable()
        .focused($focus, equals: control)
        .focusEffectDisabled()
        .onTapGesture {
            guard isEnabled else { return }
            action()
        }
    }

    private var foreground: Color {
        if focused { return Color.scChromeFocusOn }
        if !isEnabled { return .white.opacity(0.28) }
        return isActive ? .white : .white.opacity(0.82)
    }
}

private struct CinematicBackdrop: View {
    let artworkURL: URL?
    let palette: ArtworkColors.Palette

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.soundingReducedResourceUsage) private var reducedResourceUsage

    var body: some View {
        ZStack {
            AmbientArtworkBackdrop(
                seed: AmbientArtworkSeed(
                    artwork: palette.artwork,
                    colors: [palette.primary, palette.secondary, palette.average, palette.accent],
                    accent: palette.accent,
                    scrim: palette.backdropScrim(layerOpacity: 0.52, additiveHeadroom: 1.1)
                ),
                isAnimated: !reduceMotion && !reducedResourceUsage,
                intensity: 0.78
            )

            LinearGradient(
                colors: [
                    Color.black.opacity(0.55),
                    Color.black.opacity(0.20),
                    Color.black.opacity(0.35),
                    Color.black.opacity(0.88)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .animation(SCContentMotion.ambient, value: palette)
    }
}

private extension Double {
    var clampedToUnit: Double { Swift.min(1, Swift.max(0, self)) }

    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}
