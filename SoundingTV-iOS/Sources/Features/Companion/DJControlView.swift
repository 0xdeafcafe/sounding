import SwiftUI
import Foundation

struct DJControlView: View {
    @ObservedObject var client: CompanionClient
    @ObservedObject private var artworkColors = ArtworkColors.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.soundingReducedResourceUsage) private var reducedResourceUsage
    @State private var showingGuide = false
    @State private var showingStartConfiguration = false
    @State private var focusedDeck: ControlDeck = .a

    var body: some View {
        ZStack {
            AmbientArtworkBackdrop(
                seed: ambientSeed,
                isAnimated: !reduceMotion && !reducedResourceUsage,
                intensity: 0.55
            )
            .ignoresSafeArea()

            Color.black.opacity(0.26).ignoresSafeArea()

            #if DEBUG
            if Self.isDemoMode {
                console(Self.demoState)
            } else {
                realBody
            }
            #else
            realBody
            #endif
        }
        .navigationTitle("Decks")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showingStartConfiguration = true } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Configure Auto DJ session")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingGuide = true } label: {
                    Image(systemName: "questionmark.circle")
                }
                .accessibilityLabel("How Decks Works")
            }
        }
        .sheet(isPresented: $showingGuide) {
            DJModeGuideView()
        }
        .sheet(isPresented: $showingStartConfiguration) {
            AutoDJStartConfigurationView(configuration: SettingsStore.shared.djStartConfiguration) { configuration in
                SettingsStore.shared.setDJStartConfiguration(configuration)
                client.setAutoMixEnabled(true)
                client.setDJEnabled(true)
            }
        }
    }

    #if DEBUG
    private static var isDemoMode: Bool {
        ProcessInfo.processInfo.environment["SOUNDING_TV_DJ_DEMO"] == "1"
    }

    private static let demoState = DJStatePayload(
        isEnabled: true, isEngineLive: true, isAutoMixEnabled: false, crossfade: 0.42,
        deckA: DJDeckStatePayload(
            trackId: "demo-deck-a", title: "Midnight Run", artist: "Nocturn",
            positionSeconds: 64, durationSeconds: 214, isPlaying: true,
            eqLowDb: 2, eqMidDb: -3, eqHighDb: 4, filterCutoffHz: 20_000, filterResonance: 0.15,
            rate: 1.02, bpm: 124, loopStartSeconds: nil, loopLengthSeconds: nil
        ),
        deckB: DJDeckStatePayload(
            trackId: "demo-deck-b", title: "Afterglow (Extended Mix)", artist: "Kelis Vane",
            positionSeconds: 12, durationSeconds: 198, isPlaying: false,
            eqLowDb: 0, eqMidDb: 0, eqHighDb: 0, filterCutoffHz: 20_000, filterResonance: 0,
            rate: 0.98, bpm: 128, loopStartSeconds: nil, loopLengthSeconds: 4
        ),
        automaticMix: DJAutomaticMixDecision(
            phase: .armed,
            profileName: "Wedding DJ",
            templateName: "Bass swap",
            headline: "Bass swap into Afterglow at 2:58, 16s",
            reasoning: "The tempos are close and the outgoing track opens into a calm phrase.",
            incomingTrackId: "demo-deck-b",
            mixPointSeconds: 178,
            transitionSeconds: 16,
            entrySeconds: 0,
            score: 0.84,
            isFallback: false
        ),
        revision: 1, issuedAtMillis: 0, signature: "demo"
    )
    #endif

    @ViewBuilder
    private var realBody: some View {
        switch client.state {
            case .connected:
                if let dj = client.djState {
                    console(dj)
                } else {
                    transientStatusView(
                        title: "Waiting for the Mixer…",
                        message: "Your Apple TV is connected. The console appears as soon as it reports in."
                    )
                }
            case .unlinked:
                staticStatusView(
                    icon: "qrcode.viewfinder",
                    title: "No Apple TV Paired",
                    message: "Open SoundingCloud on your Apple TV and scan the on-screen QR code to pair, then come back here to mix."
                )
            case .failed(let message):
                failureView(message)
            case .idle, .searching, .connecting:
                transientStatusView(
                    title: searchingTitle,
                    message: "Make sure your Apple TV is awake and on the same Wi-Fi network."
                )
            }
    }

    private var searchingTitle: String {
        switch client.state {
        case .connecting: return "Connecting…"
        case .searching:  return "Looking for Your Apple TV…"
        default:          return "Reconnecting…"
        }
    }

    private func console(_ dj: DJStatePayload) -> some View {
        let isLive = client.isDJControlLive
        let activeArtworkURL = artworkURL(for: dj.crossfade < 0.5 ? dj.deckA : dj.deckB)

        return VStack(spacing: 12) {
            if !isLive {
                Label(
                    "The deck engine is waking up. Auto Mix keeps planning even if you leave this screen.",
                    systemImage: "waveform.slash"
                )
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Corner.card, style: .continuous))
            }

            if dj.isAutoMixEnabled, let decision = dj.automaticMix {
                AutomaticMixDirectorView(
                    decision: decision,
                    currentTime: dj.crossfade < 0.5
                        ? dj.deckA.positionSeconds
                        : dj.deckB.positionSeconds
                )
            }

            GeometryReader { proxy in
                if proxy.size.width >= 860 {
                    ScrollView(.horizontal) {
                        landscapeLayout(dj, isLive: isLive)
                            .frame(minWidth: 798)
                    }
                    .scrollIndicators(.hidden)
                } else {
                    compactLayout(dj, isLive: isLive)
                }
            }
        }
        .padding(14)
        .onAppear { artworkColors.update(for: activeArtworkURL) }
        .onChange(of: activeArtworkURL) { _, url in artworkColors.update(for: url) }
    }

    private func landscapeLayout(_ dj: DJStatePayload, isLive: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            DeckConsoleView(
                deck: .a, state: dj.deckA, isLive: isLive && !dj.isAutoMixEnabled,
                isAudible: isAudible(.a, crossfade: dj.crossfade),
                artworkURL: artworkURL(for: dj.deckA), client: client
            )
            .frame(width: 300)

            MixerConsoleView(dj: dj, isLive: isLive, client: client)
                .frame(width: 170)

            DeckConsoleView(
                deck: .b, state: dj.deckB, isLive: isLive && !dj.isAutoMixEnabled,
                isAudible: isAudible(.b, crossfade: dj.crossfade),
                artworkURL: artworkURL(for: dj.deckB), client: client
            )
            .frame(width: 300)
        }
    }

    private func compactLayout(_ dj: DJStatePayload, isLive: Bool) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                DeckFocusSwitcher(
                    focusedDeck: $focusedDeck,
                    deckA: dj.deckA,
                    deckB: dj.deckB,
                    crossfade: dj.crossfade
                )

                DeckConsoleView(
                    deck: focusedDeck,
                    state: focusedDeck == .a ? dj.deckA : dj.deckB,
                    isLive: isLive && !dj.isAutoMixEnabled,
                    isAudible: isAudible(focusedDeck, crossfade: dj.crossfade),
                    artworkURL: artworkURL(for: focusedDeck == .a ? dj.deckA : dj.deckB),
                    client: client
                )

                MixerConsoleView(dj: dj, isLive: isLive, client: client)
            }
            .padding(.bottom, 24)
        }
    }

    private func artworkURL(for deck: DJDeckStatePayload) -> URL? {
        guard let trackId = deck.trackId else { return nil }
        return client.tracks.first(where: { $0.id == trackId })?.artworkURL
    }

    private var ambientSeed: AmbientArtworkSeed {
        let palette = artworkColors.current
        return AmbientArtworkSeed(
            artwork: palette.artwork,
            colors: [palette.primary, palette.secondary, palette.average, palette.accent],
            accent: palette.accent,
            scrim: palette.backdropScrim(layerOpacity: 0.5, additiveHeadroom: 1.05)
        )
    }

    private func isAudible(_ deck: ControlDeck, crossfade: Double) -> Bool {
        switch deck {
        case .a: return (1 - crossfade) > 0.08
        case .b: return crossfade > 0.08
        case .none: return false
        }
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Color.scWarning)

            Text("Can't Reach Your Apple TV")
                .font(.system(size: 20, weight: .bold))

            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button { client.retry() } label: {
                Text("Try Again")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.scAccentOn)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 32)
                    .background(Color.scAccentGradient, in: Capsule())
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .scCard(cornerRadius: Corner.panel, padding: Space.roomy)
        .padding(.horizontal, Space.page)
    }

    private func staticStatusView(icon: String, title: String, message: String) -> some View {
        statusCard(icon: icon, iconTint: Color.scTextTertiary, title: title, message: message)
    }

    private func transientStatusView(title: String, message: String) -> some View {
        statusCard(icon: nil, iconTint: .white, title: title, message: message, showsProgress: true)
    }

    private func statusCard(
        icon: String?,
        iconTint: Color,
        title: String,
        message: String,
        showsProgress: Bool = false
    ) -> some View {
        VStack(spacing: 16) {
            if showsProgress {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.3)
                    .tint(iconTint)
                    .frame(height: 44)
            } else if let icon {
                Image(systemName: icon)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(iconTint)
                    .frame(height: 44)
            }

            Text(title)
                .font(.system(size: 20, weight: .bold))
                .multilineTextAlignment(.center)

            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .scCard(cornerRadius: Corner.panel, padding: Space.roomy)
        .padding(.horizontal, Space.page)
    }
}

private struct DeckFocusSwitcher: View {
    @Binding var focusedDeck: ControlDeck
    let deckA: DJDeckStatePayload
    let deckB: DJDeckStatePayload
    let crossfade: Double

    var body: some View {
        HStack(spacing: 8) {
            deckButton(.a, state: deckA, isAudible: crossfade < 0.92)
            deckButton(.b, state: deckB, isAudible: crossfade > 0.08)
        }
        .padding(5)
        .background(.black.opacity(0.24), in: RoundedRectangle(cornerRadius: Corner.control, style: .continuous))
        .overlay(alignment: .bottom) {
            Text("One deck at a time here · the mixer still controls both")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .offset(y: 15)
        }
        .padding(.bottom, 12)
    }

    private func deckButton(_ deck: ControlDeck, state: DJDeckStatePayload, isAudible: Bool) -> some View {
        Button { focusedDeck = deck } label: {
            HStack(spacing: 8) {
                Text(deck.shortLabel)
                    .font(.system(size: 14, weight: .black, design: .rounded))
                    .foregroundStyle(focusedDeck == deck ? .black : deck.themeColor)
                    .frame(width: 28, height: 28)
                    .background(focusedDeck == deck ? deck.themeColor : deck.themeColor.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 1) {
                    Text(state.title ?? "Empty deck")
                        .font(.system(size: 11, weight: .bold))
                        .lineLimit(1)
                    Text(isAudible ? "On master" : "Off master")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(isAudible ? AnyShapeStyle(deck.themeColor) : AnyShapeStyle(.tertiary))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(
                focusedDeck == deck ? Color.white.opacity(0.10) : Color.clear,
                in: RoundedRectangle(cornerRadius: Corner.control - 3, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show deck \(deck.shortLabel), \(state.title ?? "empty")")
        .accessibilityAddTraits(focusedDeck == deck ? .isSelected : [])
    }
}

struct DeckConsoleView: View {
    let deck: ControlDeck
    let state: DJDeckStatePayload
    let isLive: Bool
    let isAudible: Bool
    let artworkURL: URL?
    let client: CompanionClient

    @State private var anchorPosition: Double = 0
    @State private var anchorDate: Date = .now

    @StateObject private var cueBoard = CueBoard()

    private static let eqRange: ClosedRange<Double> = -60...12
    private static let filterCutoffRange: ClosedRange<Double> = 30...20_000
    private static let rateRange: ClosedRange<Double> = 0.92...1.08

    private func estimatedPosition() -> Double {
        guard state.isPlaying else { return anchorPosition }
        return anchorPosition + Date.now.timeIntervalSince(anchorDate) * state.rate
    }

    var body: some View {
        VStack(spacing: 8) {
            header

            DeckSeekBarView(
                anchorPosition: anchorPosition,
                anchorDate: anchorDate,
                rate: state.rate,
                isPlaying: state.isPlaying,
                durationSeconds: state.durationSeconds,
                deck: deck,
                isAudible: isAudible,
                isEnabled: isLive,
                onCommit: { client.seek(deck: deck, toSeconds: $0) }
            )

            HStack(alignment: .top, spacing: 12) {
                JogWheelView(
                    deck: deck,
                    title: state.title,
                    artworkURL: artworkURL,
                    anchorPosition: anchorPosition,
                    anchorDate: anchorDate,
                    rate: state.rate,
                    isPlaying: state.isPlaying,
                    isEnabled: isLive,
                    isAudible: isAudible,
                    onScrub: { client.jog(deck: deck, bySeconds: $0) }
                )

                Spacer(minLength: 0)

                PitchFaderView(
                    liveValue: state.rate,
                    range: Self.rateRange,
                    isEnabled: isLive,
                    height: 128,
                    onChange: { client.setRate(deck: deck, multiplier: $0) }
                )
            }

            knobRow

            hotCueGrid

            Text("Drag the track bar to seek · turn the platter to nudge · hold a cue pad to save")
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer(minLength: 0)
                LoopControlView(
                    loopLengthSeconds: state.loopLengthSeconds,
                    bpm: state.bpm.map { $0 * state.rate },
                    isEnabled: isLive,
                    onArm: { beats in client.setLoop(deck: deck, beats: beats) },
                    onClear: { client.clearLoop(deck: deck) }
                )
            }
        }
        .padding(12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Corner.panel, style: .continuous))
        .onAppear { resync(); loadCueBoard() }
        .onChange(of: state) { _, _ in resync(); loadCueBoard() }
    }

    private func resync() {
        anchorPosition = state.positionSeconds
        anchorDate = .now
    }

    private func loadCueBoard() {
        cueBoard.ensureLoaded(trackId: state.trackId, duration: state.durationSeconds, waveform: nil)
    }

    private var hotCueGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 4)
        return LazyVGrid(columns: columns, spacing: 4) {
            ForEach(0..<CuePoint.hotCueSlotCount, id: \.self) { index in
                HotCuePadButton(
                    index: index,
                    occupant: cueBoard.sheet.hotCue(at: index)?.userCue,
                    isEnabled: isLive,
                    onJump: { position in client.seek(deck: deck, toSeconds: position) },
                    onSetCue: {
                        guard let trackId = state.trackId else { return }
                        let position = estimatedPosition()
                        Task {
                            await cueBoard.setHotCue(
                                trackId: trackId, index: index,
                                positionMillis: CueTime.millis(fromSeconds: position)
                            )
                        }
                        client.setHotCue(deck: deck, index: index, atSeconds: position)
                    }
                )
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isAudible && state.isPlaying ? Color.scAccent : Color.secondary.opacity(0.35))
                    .frame(width: 6, height: 6)
                    .shadow(color: isAudible && state.isPlaying ? Color.scAccent.opacity(0.8) : .clear, radius: 3)
                Text("\((state.role ?? .idle).displayLabel) · DECK \(deck.shortLabel)")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button {
                    client.togglePlayPause(deck: deck)
                } label: {
                    Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 26, height: 24)
                        .foregroundStyle(isLive ? deck.themeColor : .secondary)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(!isLive || state.trackId == nil)
                Button {
                    client.sync(deck: deck)
                } label: {
                    Text("SYNC")
                        .font(.system(size: 8, weight: .heavy))
                        .frame(width: 34, height: 24)
                        .foregroundStyle(abs(state.phaseErrorSeconds ?? 1) < 0.025 ? Color.scSuccess : deck.themeColor)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .disabled(!isLive || state.bpm == nil)
                if let bpm = state.bpm, bpm.isFinite {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(DJFormat.bpm(bpm))
                            .font(.system(size: 15, weight: .heavy).monospacedDigit())
                            .foregroundStyle(isAudible ? deck.themeColor : .secondary)
                        Text("BPM")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            HStack(spacing: 4) {
                Text(state.title ?? "No Track")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                if let artist = state.artist, !artist.isEmpty {
                    Text("· \(artist)")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            DeckLevelMeter(
                level: state.level ?? 0,
                peak: state.peak ?? 0,
                isClipping: state.isClipping == true,
                phaseErrorSeconds: state.phaseErrorSeconds
            )
        }
    }

    private var knobRow: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                KnobControl(
                    label: "HI", liveValue: state.eqHighDb, range: Self.eqRange, isEnabled: isLive,
                    resetValue: 0,
                    valueText: Self.dbText, onChange: { client.setEQ(deck: deck, band: .eqHigh, decibels: $0) }
                )
                KnobControl(
                    label: "MID", liveValue: state.eqMidDb, range: Self.eqRange, isEnabled: isLive,
                    resetValue: 0,
                    valueText: Self.dbText, onChange: { client.setEQ(deck: deck, band: .eqMid, decibels: $0) }
                )
                KnobControl(
                    label: "LOW", liveValue: state.eqLowDb, range: Self.eqRange, isEnabled: isLive,
                    resetValue: 0,
                    valueText: Self.dbText, onChange: { client.setEQ(deck: deck, band: .eqLow, decibels: $0) }
                )
            }

            HStack(spacing: 6) {
                KnobControl(
                    label: "CUTOFF", liveValue: state.filterCutoffHz, range: Self.filterCutoffRange,
                    isLogarithmic: true, isEnabled: isLive,
                    resetValue: Self.filterCutoffRange.upperBound,
                    valueText: Self.hzText, onChange: { client.setFilterCutoff(deck: deck, hertz: $0) }
                )
                KnobControl(
                    label: "RESO", liveValue: state.filterResonance, range: 0...1, isEnabled: isLive,
                    resetValue: 0,
                    valueText: { "\(Int($0 * 100))%" }, onChange: { client.setFilterResonance(deck: deck, value: $0) }
                )
            }
        }
    }

    private static func dbText(_ value: Double) -> String { String(format: "%+.0f", value) }

    private static func hzText(_ value: Double) -> String {
        value >= 1000 ? String(format: "%.1fk", value / 1000) : String(format: "%.0f", value)
    }
}

private extension DJDeckRole {
    var displayLabel: String {
        switch self {
        case .live:     return "LIVE"
        case .incoming: return "INCOMING"
        case .idle:     return "IDLE"
        }
    }
}

private struct DeckLevelMeter: View {
    let level: Double
    let peak: Double
    let isClipping: Bool
    let phaseErrorSeconds: Double?

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { proxy in
                let width = max(1, proxy.size.width)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(isClipping ? Color.red : Color.scSuccess)
                        .frame(width: width * CGFloat(min(1, max(0, level))))
                    Rectangle()
                        .fill(peak >= 0.985 ? Color.red : Color.white.opacity(0.8))
                        .frame(width: 2)
                        .offset(x: max(0, width * CGFloat(min(1, max(0, peak))) - 1))
                }
            }
            .frame(height: 4)

            if let phaseErrorSeconds {
                Text(String(format: "PHASE %+.0fms", phaseErrorSeconds * 1000))
                    .font(.system(size: 7, weight: .bold).monospacedDigit())
                    .foregroundStyle(abs(phaseErrorSeconds) < 0.025 ? Color.scSuccess : Color.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isClipping ? "Deck output clipping" : "Deck output level \(Int(level * 100)) percent")
    }
}

struct JogWheelView: View {
    let deck: ControlDeck
    let title: String?
    let artworkURL: URL?
    let anchorPosition: Double
    let anchorDate: Date
    let rate: Double
    let isPlaying: Bool
    let isEnabled: Bool
    let isAudible: Bool
    let onScrub: (Double) -> Void

    var diameter: CGFloat = 160

    @State private var isDragging = false
    @State private var frozenBaseAngle: Double = 0
    @State private var dragVisualAngle: Double = 0
    @State private var lastTouchAngle: Double?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !isPlaying || isDragging)) { context in
            let baseAngle = isDragging
                ? frozenBaseAngle
                : Self.angle(atPosition: estimatedPosition(at: context.date))
            let totalRotation = baseAngle + (isDragging ? dragVisualAngle : 0)

            ZStack {
                rim
                platter(rotation: totalRotation)
                referenceMarker
                spindle
            }
        }
        .frame(width: diameter, height: diameter)
        .opacity(isEnabled ? 1 : 0.4)
        .allowsHitTesting(isEnabled)
        .contentShape(Circle())
        .gesture(dragGesture)
    }

    private func estimatedPosition(at date: Date) -> Double {
        let base = anchorPosition.isFinite ? anchorPosition : 0
        guard isPlaying else { return base }
        let r = rate.isFinite ? rate : 1
        let estimate = base + date.timeIntervalSince(anchorDate) * r
        return estimate.isFinite ? estimate : base
    }

    private var rim: some View {
        Circle()
            .fill(WheelMetal.rim)
            .overlay(
                Circle()
                    .stroke(
                        isAudible ? Color.scAccent.opacity(0.9) : .white.opacity(0.12),
                        lineWidth: isAudible ? 2 : 1
                    )
                    .shadow(color: isAudible ? Color.scAccent.opacity(0.8) : .clear, radius: 8)
            )
            .shadow(color: .black.opacity(0.6), radius: 10, y: 6)
    }

    private func platter(rotation: Double) -> some View {
        ZStack {
            Circle().fill(WheelMetal.platterTexture)
            positionMarkers
            label
        }
        .frame(width: diameter * 0.8, height: diameter * 0.8)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
        .rotationEffect(.degrees(rotation))
    }

    private var positionMarkers: some View {
        ForEach(0..<8, id: \.self) { i in
            Capsule()
                .fill(.white.opacity(i % 2 == 0 ? 0.55 : 0.22))
                .frame(width: 2, height: i % 2 == 0 ? diameter * 0.05 : diameter * 0.03)
                .offset(y: -(diameter * 0.8) / 2 + diameter * 0.035)
                .rotationEffect(.degrees(Double(i) / 8 * 360))
        }
    }

    private var label: some View {
        ZStack {
            SCArtworkResolver(url: artworkURL, variant: .standard) { image in
                SCArtwork(
                    image: image,
                    identity: title ?? "Deck \(deck.shortLabel)",
                    style: .phone,
                    cornerRadius: diameter * 0.2
                )
            }
            Color.black.opacity(0.14)
            Circle()
                .trim(from: 0.55, to: 0.9)
                .stroke(.white.opacity(0.22), lineWidth: diameter * 0.03)
                .blur(radius: 2)
        }
        .frame(width: diameter * 0.4, height: diameter * 0.4)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.2), lineWidth: 1))
    }

    private var referenceMarker: some View {
        Circle()
            .fill(Color.scAccent)
            .frame(width: 5, height: 5)
            .shadow(color: Color.scAccent.opacity(0.9), radius: 3)
            .offset(y: -(diameter * 0.8) / 2 - 3)
    }

    private var spindle: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [.white.opacity(0.55), .black.opacity(0.65)],
                    center: .topLeading, startRadius: 0, endRadius: 8
                )
            )
            .frame(width: diameter * 0.09, height: diameter * 0.09)
            .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let center = CGPoint(x: diameter / 2, y: diameter / 2)
                let currentAngle = Self.angleDegrees(from: center, to: value.location)

                guard isDragging else {
                    isDragging = true
                    frozenBaseAngle = Self.angle(atPosition: estimatedPosition(at: .now))
                    lastTouchAngle = currentAngle
                    return
                }
                guard let previous = lastTouchAngle else {
                    lastTouchAngle = currentAngle
                    return
                }

                let delta = Self.shortestDelta(from: previous, to: currentAngle)
                lastTouchAngle = currentAngle
                dragVisualAngle += delta

                let distance = hypot(value.location.x - center.x, value.location.y - center.y)
                let isOuterRing = distance > diameter * 0.38
                let secondsPerRevolution = isOuterRing
                    ? JogTuning.coarseSecondsPerRevolution
                    : JogTuning.fineSecondsPerRevolution
                let incremental = delta / 360 * secondsPerRevolution
                if abs(incremental) > 0.0001 { onScrub(incremental) }
            }
            .onEnded { _ in
                isDragging = false
                dragVisualAngle = 0
                lastTouchAngle = nil
            }
    }

    private static func angleDegrees(from center: CGPoint, to point: CGPoint) -> Double {
        atan2(Double(point.y - center.y), Double(point.x - center.x)) * 180 / .pi
    }

    private static func shortestDelta(from: Double, to: Double) -> Double {
        var delta = to - from
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }
        return delta
    }

    private static func angle(atPosition position: Double) -> Double {
        guard position.isFinite else { return 0 }
        let revolutions = position / JogTuning.fineSecondsPerRevolution
        let angle = (revolutions * 360).truncatingRemainder(dividingBy: 360)
        return angle.isFinite ? angle : 0
    }
}

/// A direct, full-track seek control. Dragging only previews locally; one
/// absolute seek is sent on release so remote audio never receives a backlog
/// of stale stop/reschedule commands.
struct DeckSeekBarView: View {
    let anchorPosition: Double
    let anchorDate: Date
    let rate: Double
    let isPlaying: Bool
    let durationSeconds: Double
    let deck: ControlDeck
    let isAudible: Bool
    let isEnabled: Bool
    let onCommit: (Double) -> Void

    @State private var previewSeconds: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let position = previewSeconds ?? estimatedPosition(at: context.date)
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    Text("SEEK")
                    Spacer()
                    Text("\(DJFormat.time(position)) / \(DJFormat.time(durationSeconds))")
                }
                .font(.system(size: 8.5, weight: .bold).monospacedDigit())
                .foregroundStyle(.secondary)

                GeometryReader { proxy in
                    let width = max(proxy.size.width, 1)
                    let progress = durationSeconds > 0
                        ? min(1, max(0, position / durationSeconds))
                        : 0
                    let progressWidth = width * CGFloat(progress)

                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.10))
                        Capsule()
                            .fill((isAudible ? deck.themeColor : Color.secondary).opacity(0.75))
                            .frame(width: max(3, progressWidth))
                        Circle()
                            .fill(isAudible ? deck.themeColor : .white.opacity(0.8))
                            .frame(width: 12, height: 12)
                            .offset(x: min(width - 12, max(0, progressWidth - 6)))
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                previewSeconds = target(for: value.location.x, width: width)
                            }
                            .onEnded { value in
                                let target = target(for: value.location.x, width: width)
                                previewSeconds = nil
                                onCommit(target)
                            }
                    )
                }
                .frame(height: 18)
            }
        }
        .frame(height: 34)
        .opacity(isEnabled ? 1 : 0.4)
        .allowsHitTesting(isEnabled)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Seek deck \(deck.shortLabel)")
        .accessibilityValue(DJFormat.time(previewSeconds ?? anchorPosition))
    }

    private func target(for x: CGFloat, width: CGFloat) -> Double {
        guard durationSeconds.isFinite, durationSeconds > 0 else { return 0 }
        return min(durationSeconds, max(0, Double(x / max(width, 1)) * durationSeconds))
    }

    private func estimatedPosition(at date: Date) -> Double {
        let base = anchorPosition.isFinite ? anchorPosition : 0
        guard isPlaying else { return min(max(0, base), max(0, durationSeconds)) }
        let safeRate = rate.isFinite ? rate : 1
        return min(max(0, base + date.timeIntervalSince(anchorDate) * safeRate), max(0, durationSeconds))
    }
}

private enum JogTuning {
    static let fineSecondsPerRevolution: Double = 1.8
    static let coarseSecondsPerRevolution: Double = 12
}

private enum WheelMetal {
    static let rim = RadialGradient(
        colors: [Color(white: 0.24), Color(white: 0.08)],
        center: UnitPoint(x: 0.4, y: 0.35), startRadius: 4, endRadius: 110
    )
    static let platterTexture = AngularGradient(
        colors: [
            Color(white: 0.20), Color(white: 0.28), Color(white: 0.16),
            Color(white: 0.26), Color(white: 0.20),
        ],
        center: .center
    )

    static func label(for deck: ControlDeck) -> RadialGradient {
        RadialGradient(
            colors: [deck.themeColor.opacity(0.55), Color.black.opacity(0.85)],
            center: .topLeading, startRadius: 2, endRadius: 60
        )
    }
}

extension ControlDeck {
    fileprivate var shortLabel: String {
        switch self {
        case .a: return "A"
        case .b: return "B"
        case .none: return "–"
        }
    }

    fileprivate var themeColor: Color {
        switch self {
        case .a: return Color.scAccent
        case .b: return Color(red: 0.25, green: 0.45, blue: 0.95)
        case .none: return .secondary
        }
    }
}

struct PositionRulerView: View {
    let anchorPosition: Double
    let anchorDate: Date
    let rate: Double
    let isPlaying: Bool
    let durationSeconds: Double
    let bpm: Double?
    let deck: ControlDeck
    let isAudible: Bool

    private static let pixelsPerSecond: Double = 30
    private static let barBeatStride = 4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !isPlaying)) { context in
            Canvas { ctx, size in
                draw(in: &ctx, size: size, position: estimatedPosition(at: context.date))
            }
        }
        .frame(height: 26)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.08), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func estimatedPosition(at date: Date) -> Double {
        let base = anchorPosition.isFinite ? anchorPosition : 0
        guard isPlaying else { return base }
        let r = rate.isFinite ? rate : 1
        let estimate = base + date.timeIntervalSince(anchorDate) * r
        return estimate.isFinite ? estimate : base
    }

    private func draw(in ctx: inout GraphicsContext, size: CGSize, position: Double) {
        let center = size.width / 2
        let pxPerSec = Self.pixelsPerSecond
        let duration = durationSeconds.isFinite && durationSeconds > 0 ? durationSeconds : .infinity

        let windowSeconds = size.width / pxPerSec
        let visibleStart = max(0, position - windowSeconds / 2)
        let visibleEnd = min(duration, position + windowSeconds / 2)

        if let bpm, bpm.isFinite, bpm >= 20, bpm <= 300 {
            let secondsPerBeat = 60.0 / bpm
            let firstBeat = Int((visibleStart / secondsPerBeat).rounded(.down))
            let lastBeat = Int((visibleEnd / secondsPerBeat).rounded(.up))
            if firstBeat <= lastBeat {
                for i in firstBeat...lastBeat {
                    let t = Double(i) * secondsPerBeat
                    guard t >= 0, t <= duration else { continue }
                    let isBar = i % Self.barBeatStride == 0
                    drawTick(in: &ctx, size: size, center: center, pxPerSec: pxPerSec, t: t, position: position, tall: isBar, emphasised: isBar)
                }
            }
        } else {
            let firstSecond = Int(visibleStart.rounded(.down))
            let lastSecond = Int(visibleEnd.rounded(.up))
            if firstSecond <= lastSecond {
                for s in firstSecond...lastSecond {
                    guard s >= 0, Double(s) <= duration else { continue }
                    let isFive = s % 5 == 0
                    drawTick(in: &ctx, size: size, center: center, pxPerSec: pxPerSec, t: Double(s), position: position, tall: isFive, emphasised: false)
                }
            }
        }

        for edge in [0, duration] where edge.isFinite {
            let x = center + (edge - position) * pxPerSec
            guard x >= -1, x <= size.width + 1 else { continue }
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(path, with: .color(.white.opacity(0.5)), lineWidth: 1.5)
        }

        var playhead = Path()
        playhead.move(to: CGPoint(x: center, y: 0))
        playhead.addLine(to: CGPoint(x: center, y: size.height))
        ctx.stroke(playhead, with: .color(isAudible ? deck.themeColor : .white.opacity(0.7)), lineWidth: 2)
    }

    private func drawTick(
        in ctx: inout GraphicsContext, size: CGSize, center: Double, pxPerSec: Double,
        t: Double, position: Double, tall: Bool, emphasised: Bool
    ) {
        let x = center + (t - position) * pxPerSec
        guard x >= -2, x <= size.width + 2 else { return }
        let h = tall ? size.height * 0.8 : size.height * 0.4
        var tick = Path()
        tick.move(to: CGPoint(x: x, y: (size.height - h) / 2))
        tick.addLine(to: CGPoint(x: x, y: (size.height + h) / 2))

        let isPast = t <= position
        let color: Color = isPast
            ? .white.opacity(emphasised ? 0.3 : 0.15)
            : deck.themeColor.opacity(emphasised ? 0.9 : 0.45)
        ctx.stroke(tick, with: .color(color), lineWidth: emphasised ? 2 : 1)
    }
}

struct KnobControl: View {
    let label: String
    let liveValue: Double
    let range: ClosedRange<Double>
    var isLogarithmic: Bool = false
    let isEnabled: Bool
    var resetValue: Double? = nil
    var size: CGFloat = 42
    let valueText: (Double) -> String
    let onChange: (Double) -> Void

    @State private var localValue: Double?
    @State private var lastDragTranslation: CGFloat = 0
    @State private var isFineAdjusting = false

    private var displayValue: Double { localValue ?? liveValue }
    private var normalized: Double { Self.normalize(displayValue, in: range, logarithmic: isLogarithmic) }
    private var pointerAngle: Angle { .degrees(-135 + normalized * 270) }

    var body: some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.secondary)
                .kerning(0.3)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: size + 12)

            ZStack {
                Circle()
                    .fill(KnobMetal.body)
                    .overlay(Circle().stroke(.white.opacity(0.15), lineWidth: 1))
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 2)

                ticks

                Capsule()
                    .fill(isEnabled ? Color.scAccent : Color.secondary)
                    .frame(width: 2.5, height: size * 0.26)
                    .offset(y: -size * 0.32)
                    .rotationEffect(pointerAngle)
                    .shadow(color: isEnabled ? Color.scAccent.opacity(0.8) : .clear, radius: 3)

                Circle()
                    .fill(.black.opacity(0.4))
                    .frame(width: size * 0.16, height: size * 0.16)
            }
            .frame(width: size, height: size)

            Text(valueText(displayValue))
                .font(.system(size: 8.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(isFineAdjusting ? AnyShapeStyle(Color.scAccent) : AnyShapeStyle(.tertiary))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: size + 12)
        }
        .opacity(isEnabled ? 1 : 0.35)
        .contentShape(Rectangle())
        .allowsHitTesting(isEnabled)
        .gesture(dragGesture)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                guard isEnabled, let resetValue else { return }
                localValue = resetValue
                onChange(resetValue)
            }
        )
        .accessibilityHint("Drag up or down. Move sideways while dragging for fine adjustment. Double tap to reset.")
    }

    private var ticks: some View {
        ForEach(0..<11, id: \.self) { i in
            let t = Double(i) / 10
            Capsule()
                .fill(.white.opacity(0.22))
                .frame(width: 1, height: i % 5 == 0 ? size * 0.1 : size * 0.05)
                .offset(y: -size * 0.44)
                .rotationEffect(.degrees(-135 + t * 270))
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let deltaY = value.translation.height - lastDragTranslation
                lastDragTranslation = value.translation.height

                isFineAdjusting = abs(value.translation.width) > 40
                let sensitivity = KnobMetal.pixelsForFullSweep * (isFineAdjusting ? 10 : 1)
                let deltaNormalized = Double(-deltaY / sensitivity)
                let newNormalized = min(1, max(0, normalized + deltaNormalized))
                let newValue = Self.denormalize(newNormalized, in: range, logarithmic: isLogarithmic)
                localValue = newValue
                onChange(newValue)
            }
            .onEnded { _ in
                lastDragTranslation = 0
                localValue = nil
                isFineAdjusting = false
            }
    }

    private static func normalize(_ value: Double, in range: ClosedRange<Double>, logarithmic: Bool) -> Double {
        let clamped = min(range.upperBound, max(range.lowerBound, value))
        guard logarithmic else {
            return (clamped - range.lowerBound) / (range.upperBound - range.lowerBound)
        }
        let lo = log(max(range.lowerBound, 0.0001))
        let hi = log(max(range.upperBound, 0.0001))
        return (log(max(clamped, 0.0001)) - lo) / (hi - lo)
    }

    private static func denormalize(_ t: Double, in range: ClosedRange<Double>, logarithmic: Bool) -> Double {
        let clampedT = min(1, max(0, t))
        guard logarithmic else {
            return range.lowerBound + (range.upperBound - range.lowerBound) * clampedT
        }
        let lo = log(max(range.lowerBound, 0.0001))
        let hi = log(max(range.upperBound, 0.0001))
        return exp(lo + (hi - lo) * clampedT)
    }
}

private enum KnobMetal {
    static let pixelsForFullSweep: CGFloat = 130
    static let body = RadialGradient(
        colors: [Color(white: 0.34), Color(white: 0.15)],
        center: UnitPoint(x: 0.35, y: 0.3), startRadius: 1, endRadius: 30
    )
}

struct PitchFaderView: View {
    let liveValue: Double
    let range: ClosedRange<Double>
    let isEnabled: Bool
    var height: CGFloat = 150
    let onChange: (Double) -> Void

    @State private var localValue: Double?
    @State private var lastDragTranslation: CGFloat = 0
    @State private var centerHaptic = 0
    @State private var isFineAdjusting = false

    private var displayValue: Double { localValue ?? liveValue }
    private var normalized: Double {
        (displayValue - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    var body: some View {
        VStack(spacing: 4) {
            Text("TEMPO")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.secondary)
                .kerning(0.3)

            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(FaderMetal.slot)
                    .frame(width: 6)
                    .overlay(alignment: .center) {
                        Rectangle()
                            .fill(.white.opacity(0.35))
                            .frame(width: 16, height: 1.5)
                    }

                capsuleCap
                    .offset(y: -normalized * (height - FaderMetal.capHeight))
            }
            .frame(width: 34, height: height)
            .contentShape(Rectangle())
            .allowsHitTesting(isEnabled)
            .gesture(dragGesture)

            Text(String(format: "%+.0f%%", (displayValue - 1) * 100))
                .font(.system(size: 8.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(isFineAdjusting ? AnyShapeStyle(Color.scAccent) : AnyShapeStyle(.tertiary))
        }
        .opacity(isEnabled ? 1 : 0.35)
        .sensoryFeedback(.selection, trigger: centerHaptic)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                guard isEnabled else { return }
                localValue = 1
                onChange(1)
                centerHaptic += 1
            }
        )
        .accessibilityHint("Drag vertically. Move sideways while dragging for fine adjustment. Double tap to reset tempo.")
    }

    private var capsuleCap: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(FaderMetal.cap)
            .frame(width: 30, height: FaderMetal.capHeight)
            .overlay(
                VStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { _ in
                        Rectangle().fill(.black.opacity(0.4)).frame(height: 1)
                    }
                }
                .padding(.horizontal, 6)
            )
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.25), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.5), radius: 3, y: 2)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let deltaY = value.translation.height - lastDragTranslation
                lastDragTranslation = value.translation.height

                let wasNearCenter = abs(displayValue - 1) < 0.01
                isFineAdjusting = abs(value.translation.width) > 40
                let sensitivity = (height - FaderMetal.capHeight) * (isFineAdjusting ? 10 : 1)
                let deltaNormalized = Double(-deltaY / sensitivity)
                let newNormalized = min(1, max(0, normalized + deltaNormalized))
                var newValue = range.lowerBound + (range.upperBound - range.lowerBound) * newNormalized
                if abs(newValue - 1) < 0.012 { newValue = 1 }

                localValue = newValue
                onChange(newValue)

                let isNearCenter = newValue == 1
                if isNearCenter && !wasNearCenter { centerHaptic += 1 }
            }
            .onEnded { _ in
                lastDragTranslation = 0
                localValue = nil
                isFineAdjusting = false
            }
    }
}

private enum FaderMetal {
    static let capHeight: CGFloat = 26
    static let slot = LinearGradient(
        colors: [Color(white: 0.08), Color(white: 0.2), Color(white: 0.08)],
        startPoint: .leading, endPoint: .trailing
    )
    static let cap = LinearGradient(
        colors: [Color(white: 0.75), Color(white: 0.45)],
        startPoint: .top, endPoint: .bottom
    )
}

struct CrossfaderView: View {
    let liveValue: Double
    let isEnabled: Bool
    let onChange: (Double) -> Void

    @State private var localValue: Double?
    @State private var isAtEndpoint = false
    @State private var endpointHaptic = 0

    private var displayValue: Double { localValue ?? liveValue }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("A").foregroundStyle(displayValue < 0.5 ? Color.scAccent : .secondary)
                Spacer()
                Text("B").foregroundStyle(displayValue > 0.5 ? Color.scAccent : .secondary)
            }
            .font(.system(size: 12, weight: .heavy))

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let handleX = CrossfaderMetal.handleWidth / 2
                    + CGFloat(displayValue) * (width - CrossfaderMetal.handleWidth)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(CrossfaderMetal.rail)
                        .frame(height: 10)
                        .overlay(Capsule().stroke(.white.opacity(0.15), lineWidth: 1))

                    Rectangle()
                        .fill(.white.opacity(0.35))
                        .frame(width: 2, height: 16)
                        .position(x: width / 2, y: 5)

                    handle
                        .position(x: handleX, y: 5)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let t = min(1, max(0, Double(value.location.x / width)))
                            localValue = t
                            onChange(t)

                            let atEndpoint = t <= 0.02 || t >= 0.98
                            if atEndpoint && !isAtEndpoint { endpointHaptic += 1 }
                            isAtEndpoint = atEndpoint
                        }
                        .onEnded { _ in
                            localValue = nil
                            isAtEndpoint = false
                        }
                )
            }
            .frame(height: 34)
        }
        .opacity(isEnabled ? 1 : 0.35)
        .allowsHitTesting(isEnabled)
        .sensoryFeedback(.impact(weight: .heavy), trigger: endpointHaptic)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                guard isEnabled else { return }
                localValue = 0.5
                onChange(0.5)
            }
        )
        .accessibilityHint("Drag between decks. Double tap to centre.")
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(CrossfaderMetal.handle)
            .frame(width: CrossfaderMetal.handleWidth, height: 34)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.3), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.55), radius: 4, y: 2)
    }
}

private enum CrossfaderMetal {
    static let handleWidth: CGFloat = 30
    static let rail = LinearGradient(
        colors: [Color(white: 0.1), Color(white: 0.25), Color(white: 0.1)],
        startPoint: .leading, endPoint: .trailing
    )
    static let handle = LinearGradient(
        colors: [Color(white: 0.8), Color(white: 0.5)],
        startPoint: .top, endPoint: .bottom
    )
}

struct HotCuePadButton: View {
    let index: Int
    let occupant: CuePoint?
    let isEnabled: Bool
    let onJump: (Double) -> Void
    let onSetCue: () -> Void

    @State private var haptic = 0

    private var letter: String {
        guard let scalar = UnicodeScalar(65 + index) else { return "\(index + 1)" }
        return String(Character(scalar))
    }

    var body: some View {
        VStack(spacing: 1) {
            Text(letter)
                .font(.system(size: 10, weight: .heavy))
            Text(occupant.map { DJFormat.time($0.positionSeconds) } ?? "—")
                .font(.system(size: 7, weight: .semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, minHeight: 26)
        .foregroundStyle(occupant != nil ? .black.opacity(0.82) : Color.scTextSecondary)
        .background(
            occupant?.color.color ?? Color.white.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(.white.opacity(occupant != nil ? 0.25 : 0.12), lineWidth: 1)
        )
        .shadow(color: (occupant?.color.color ?? .clear).opacity(0.5), radius: 3)
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .opacity(isEnabled ? 1 : 0.35)
        .allowsHitTesting(isEnabled)
        .gesture(
            LongPressGesture(minimumDuration: 0.5)
                .exclusively(before: TapGesture())
                .onEnded { result in
                    switch result {
                    case .first:
                        onSetCue()
                        haptic += 1
                    case .second:
                        if let occupant {
                            onJump(occupant.positionSeconds)
                            haptic += 1
                        }
                    }
                }
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(
            occupant.map { "Hot cue \(letter), \(DJFormat.time($0.positionSeconds))" }
                ?? "Set hot cue \(letter)"
        )
        .accessibilityAction {
            if let occupant {
                onJump(occupant.positionSeconds)
            } else {
                onSetCue()
            }
        }
        .sensoryFeedback(.selection, trigger: haptic)
    }
}

struct LoopControlView: View {
    let loopLengthSeconds: Double?
    let bpm: Double?
    let isEnabled: Bool
    let onArm: (Int) -> Void
    let onClear: () -> Void

    @State private var haptic = 0

    private static let presets: [Int] = [1, 2, 4, 8, 16]
    private var isArmed: Bool { loopLengthSeconds != nil }

    var body: some View {
        HStack(spacing: 5) {
            Text("BEATS")
                .font(.system(size: 7, weight: .heavy))
                .foregroundStyle(.secondary)
            ForEach(Self.presets, id: \.self) { beats in
                Button {
                    onArm(beats)
                    haptic += 1
                } label: {
                    Text("\(beats)")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 24)
                        .foregroundStyle(isActive(beats) ? Color.scAccentOn : Color.scTextSecondary)
                        .background(isActive(beats) ? Color.scAccent : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                        .shadow(color: isActive(beats) ? Color.scAccent.opacity(0.7) : .clear, radius: 4)
                }
                .buttonStyle(.plain)
            }

            Button {
                onClear()
                haptic += 1
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 24)
                    .foregroundStyle(isArmed ? Color.scAccent : Color.secondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(!isArmed)
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .animation(.easeInOut(duration: 0.15), value: loopLengthSeconds)
        .sensoryFeedback(.impact(weight: .medium), trigger: haptic)
    }

    private func isActive(_ beats: Int) -> Bool {
        guard let loopLengthSeconds, let bpm, bpm > 0 else { return false }
        let expected = Double(beats) * 60 / bpm
        return abs(loopLengthSeconds - expected) < 0.08
    }
}

struct MixerConsoleView: View {
    let dj: DJStatePayload
    let isLive: Bool
    let client: CompanionClient

    @State private var mixHaptic = 0

    var body: some View {
        VStack(spacing: 16) {
            engineBadge

            if let tempoDeltaText {
                Text(tempoDeltaText)
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            CrossfaderView(
                liveValue: dj.crossfade,
                isEnabled: isLive && !dj.isAutoMixEnabled,
                onChange: { client.setCrossfade($0) }
            )

            HStack(spacing: 6) {
                crossfaderPreset("A", value: 0, tint: .scAccent)
                crossfaderPreset("MID", value: 0.5, tint: .white)
                crossfaderPreset("B", value: 1, tint: ControlDeck.b.themeColor)
            }

            Button {
                client.mixNow()
                mixHaptic += 1
            } label: {
                Label("Mix Now", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.scAccentOn)
            .background(Color.scAccentGradient, in: RoundedRectangle(cornerRadius: Corner.control, style: .continuous))
            .disabled(!isLive)
            .opacity(isLive ? 1 : 0.4)
            .sensoryFeedback(.impact(weight: .heavy), trigger: mixHaptic)

            Toggle(isOn: Binding(get: { dj.isAutoMixEnabled }, set: { enabled in
                if enabled {
                    client.setDJEnabled(true)
                    client.setAutoMixEnabled(true)
                } else {
                    client.setAutoMixEnabled(false)
                }
            })) {
                Text("Auto Mix")
                    .font(.system(size: 12, weight: .semibold))
            }
            .toggleStyle(.switch)
            .tint(.scAccent)

            if dj.isAutoMixEnabled {
                Menu {
                    ForEach(DJProfile.all) { profile in
                        Button {
                            client.setDJProfile(profile.id)
                        } label: {
                            Label(
                                profile.displayName,
                                systemImage: selectedProfileId == profile.id ? "checkmark" : "circle"
                            )
                        }
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(selectedProfile?.displayName ?? "Auto DJ")
                                .font(.system(size: 11, weight: .bold))
                            Text(selectedProfile?.blurb ?? "Choose how Auto Mix makes decisions")
                                .font(.system(size: 8.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .menuStyle(.button)
            }

            if dj.isAutoMixEnabled, let decision = dj.automaticMix {
                Label(decision.statusLabel, systemImage: decision.isFallback ? "arrow.right" : "wand.and.stars")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Button(role: .destructive) {
                client.setDJEnabled(false)
            } label: {
                Label("Turn Off Decks", systemImage: "power")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Corner.panel, style: .continuous))
    }

    private var tempoDeltaText: String? {
        guard let aBpm = dj.deckA.bpm, aBpm.isFinite, let bBpm = dj.deckB.bpm, bBpm.isFinite else { return nil }
        let effectiveA = aBpm * dj.deckA.rate
        let effectiveB = bBpm * dj.deckB.rate
        guard effectiveA.isFinite, effectiveB.isFinite else { return nil }
        return "A \(DJFormat.bpm(effectiveA)) · B \(DJFormat.bpm(effectiveB)) · Δ\(String(format: "%+.1f", effectiveB - effectiveA))"
    }

    private var selectedProfile: DJProfile? {
        guard let name = dj.automaticMix?.profileName else {
            return DJProfile.profile(id: SettingsStore.shared.djDefaultProfileId)
        }
        return DJProfile.all.first { $0.displayName == name }
    }

    private var selectedProfileId: DJProfileID? { selectedProfile?.id }

    private func crossfaderPreset(_ label: String, value: Double, tint: Color) -> some View {
        Button { client.setCrossfade(value) } label: {
            Text(label)
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isLive || dj.isAutoMixEnabled)
        .accessibilityLabel("Set crossfader to \(label == "MID" ? "centre" : "deck \(label)")")
    }

    private var engineBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isLive ? Color.scSuccess : Color.scWarning)
                .frame(width: 7, height: 7)
                .shadow(color: (isLive ? Color.scSuccess : Color.scWarning).opacity(0.8), radius: 4)
            Text(isLive ? "Mixer Live" : "Mixer Idle")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
        }
    }
}

private struct AutomaticMixDirectorView: View {
    let decision: DJAutomaticMixDecision
    let currentTime: TimeInterval

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: decision.isFallback ? "arrow.right.circle.fill" : "wand.and.stars.inverse")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(decision.isFallback ? Color.scWarning : Color.scAccent)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(decision.statusLabel.uppercased())
                    if let countdown = decision.countdownText(currentTime: currentTime) {
                        Text("· \(countdown)")
                    }
                    if let score = decision.score {
                        Text("· \(Int((score * 100).rounded()))%")
                    }
                }
                .font(.system(size: 10, weight: .heavy).monospacedDigit())
                .foregroundStyle(decision.isFallback ? Color.scWarning : Color.scAccent)

                Text(decision.headline)
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(1)

                if let reasoning = decision.reasoning, reasoning != decision.headline {
                    Text(reasoning)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Corner.card, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Auto Mix, \(decision.statusLabel), \(decision.headline)")
    }
}

#Preview {
    DJControlView(client: CompanionClient())
        .preferredColorScheme(.dark)
}
