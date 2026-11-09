import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

struct AmbientScreenView: View {
    var onDismiss: () -> Void = {}

    var mixOverride: AmbientMixSnapshot?

    @ObservedObject private var player = PlayerService.shared
    @ObservedObject private var clock = PlayerService.shared.clock
    @ObservedObject private var artworkColors = ArtworkColors.shared
    @ObservedObject private var waveforms = WaveformService.shared
    @ObservedObject private var setlistStore = SetlistIntelligenceStore.shared

    @State private var driftX: CGFloat = -1
    @State private var driftY: CGFloat = -1
    @State private var kenBurns: CGFloat = 1.0
    @State private var breathe: CGFloat = 1.0
    @State private var lanePhase: CGFloat = -1
    @State private var revealed = false

    @State private var primaryBars: [Float] = []
    @State private var secondaryBars: [Float] = []
    @State private var barCount = AmbientWaveLane.barCounts[0]
    @State private var barCountIndex = 0
    @State private var laneFade: Double = 1

    @FocusState private var absorbingInput: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private let artworkSize: CGFloat = 560
    private let laneWidth: CGFloat = 900

    private var accessibilitySummary: String {
        var parts: [String] = []
        if let mix, mix.isActive {
            parts.append(mix.eyebrowText)
            if let outgoing = mix.outgoing { parts.append("\(outgoing.title) by \(outgoing.user.displayName)") }
            parts.append(mix.countdownText(at: clock.currentTime))
            if let next = mix.nextText { parts.append(next) }
        } else {
            parts.append("Now Playing")
            if let track = player.currentTrack { parts.append("\(track.title) by \(track.user.displayName)") }
        }
        parts.append("\(AmbientClock.string(clock.currentTime)) of \(AmbientClock.string(clock.duration))")
        return parts.joined(separator: ", ")
    }

    private var mix: AmbientMixSnapshot? {
        if let mixOverride { return mixOverride }
        #if DEBUG
        if ProcessInfo.processInfo.environment["SOUNDING_TV_AMBIENT_DJ"] == "1" {
            return AmbientMixSnapshot.debugSynthetic(from: player)
        }
        #endif
        return AmbientMixSnapshot.resolve(from: player)
    }

    private var primaryTrack: Track? { mix?.outgoing ?? player.currentTrack }
    private var secondaryTrack: Track? { mix?.incoming }

    private var setlistContext: AmbientSetlistContext? {
        guard let track = primaryTrack,
              let setlist = setlistStore.setlist(for: track.id),
              let segment = setlist.segment(at: clock.currentTime) else { return nil }
        let segments = setlist.activeSegments
        guard let index = segments.firstIndex(where: { $0.id == segment.id }) else { return nil }
        return AmbientSetlistContext(
            itemNumber: index + 1,
            itemCount: segments.count,
            label: segment.displayLabel
        )
    }

    var body: some View {
        composition
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(backdrop)
            .opacity(revealed ? 1 : 0)
            .focusable()
            .focused($absorbingInput)
            .focusEffectDisabled()
            .defaultFocus($absorbingInput, true)
            .onTapGesture(perform: onDismiss)
            .onMoveCommand { _ in onDismiss() }
            .onExitCommand(perform: onDismiss)
            .onPlayPauseCommand(perform: onDismiss)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityHint("Press any button to return to the app")
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityIdentifier("ambient.screen")
            .onAppear(perform: startMotion)
            .task(id: primaryTrack?.id) {
                if let primaryTrack { waveforms.load(primaryTrack) }
            }
            .task(id: secondaryTrack?.id) {
                if let secondaryTrack { waveforms.load(secondaryTrack) }
            }
            .task(id: barsKey) { recomputeBars() }
            .task { await rotateBarCount() }
    }

    private var composition: some View {
        Group {
            if let mix {
                AmbientMixComposition(
                    mix: mix,
                    palette: artworkColors.current,
                    currentTime: clock.currentTime,
                    duration: max(mix.outgoing?.duration ?? clock.duration, clock.duration),
                    setlist: setlistContext,
                    artworkSize: artworkSize,
                    laneWidth: laneWidth,
                    lane: laneModel(for: mix),
                    laneFade: laneFade,
                    lanePhase: lanePhase,
                    kenBurns: kenBurns
                )
            } else {
                AmbientNowPlayingComposition(
                    track: player.currentTrack,
                    palette: artworkColors.current,
                    currentTime: clock.currentTime,
                    duration: clock.duration,
                    setlist: setlistContext,
                    artworkSize: artworkSize,
                    laneWidth: laneWidth,
                    lane: laneModel(for: nil),
                    laneFade: laneFade,
                    lanePhase: lanePhase,
                    kenBurns: kenBurns
                )
            }
        }
        .padding(.leading, Space.page + 56)
        .padding(.trailing, Space.page)
        .offset(x: -driftX * 44, y: -36 - driftY * 28)
        .opacity(breathe)
    }

    private var backdrop: some View {
        let palette = artworkColors.current
        return ZStack {
            NPBackdrop(
                artworkURL: primaryTrack?.artworkURL,
                palette: palette,
                isAnimating: revealed && !reduceMotion && scenePhase == .active
            )
            NPLegibilityScrim(palette: palette)
            RadialGradient(
                colors: [Color.clear, Color.black.opacity(0.55)],
                center: UnitPoint(x: 0.34, y: 0.44),
                startRadius: 320,
                endRadius: 1500
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func laneModel(for mix: AmbientMixSnapshot?) -> AmbientWaveLane.Model {
        let duration = max(primaryTrack?.duration ?? clock.duration, 1)
        var lanes: [AmbientWaveLane.Lane] = [
            AmbientWaveLane.Lane(
                bars: primaryBars,
                start: 0,
                duration: duration,
                topFraction: 0,
                heightFraction: mix?.isActive == true ? 0.66 : 1
            )
        ]

        var band: ClosedRange<TimeInterval>?
        if let mix, let point = mix.mixPointSeconds {
            let end = min(duration, point + (mix.transitionSeconds ?? 0))
            if end > point { band = point...end }

            if let incoming = mix.incoming, !secondaryBars.isEmpty {
                lanes.append(
                    AmbientWaveLane.Lane(
                        bars: secondaryBars,
                        start: point,
                        duration: max(1, incoming.duration - mix.entrySeconds),
                        topFraction: 0.70,
                        heightFraction: 0.30,
                        emphasis: 0.62
                    )
                )
            }
        }

        return AmbientWaveLane.Model(
            lanes: lanes,
            total: duration,
            playhead: clock.currentTime,
            band: band,
            bandTint: artworkColors.current.accent
        )
    }

    private struct BarsKey: Equatable {
        let primaryId: String?
        let secondaryId: String?
        let primarySamples: Int
        let secondarySamples: Int
        let barCount: Int
    }

    private var barsKey: BarsKey {
        BarsKey(
            primaryId: primaryTrack?.id,
            secondaryId: secondaryTrack?.id,
            primarySamples: primaryTrack.flatMap { waveforms.state(for: $0.id).waveform?.samples.count } ?? 0,
            secondarySamples: secondaryTrack.flatMap { waveforms.state(for: $0.id).waveform?.samples.count } ?? 0,
            barCount: barCount
        )
    }

    private func recomputeBars() {
        primaryBars = bars(for: primaryTrack, count: barCount)

        guard let cued = secondaryTrack else {
            secondaryBars = []
            return
        }
        let total = max(primaryTrack?.duration ?? clock.duration, 1)
        let entry = mix?.entrySeconds ?? 0
        let audible = max(1, cued.duration - entry)
        let share = min(barCount * 2, max(8, Int(Double(barCount) * (audible / total))))
        let full = bars(for: cued, count: max(share, Int(Double(share) * cued.duration / audible)))
        let dropped = Int(Double(full.count) * (entry / max(cued.duration, 1)))
        secondaryBars = Array(full.dropFirst(min(dropped, max(0, full.count - 8))))
    }

    private func bars(for track: Track?, count: Int) -> [Float] {
        guard let track, let waveform = waveforms.state(for: track.id).waveform, !waveform.isEmpty else {
            return []
        }
        return waveform.displayBars(count: count)
    }

    private func rotateBarCount() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(AmbientWaveLane.barRotationSeconds))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: AmbientWaveLane.barCrossfadeSeconds)) { laneFade = 0 }
            try? await Task.sleep(for: .seconds(AmbientWaveLane.barCrossfadeSeconds))
            guard !Task.isCancelled else { return }
            barCountIndex = (barCountIndex + 1) % AmbientWaveLane.barCounts.count
            barCount = AmbientWaveLane.barCounts[barCountIndex]
            withAnimation(reduceMotion ? nil : .easeInOut(duration: AmbientWaveLane.barCrossfadeSeconds)) { laneFade = 1 }
        }
    }

    private func startMotion() {
        withAnimation(reduceMotion ? nil : Motion.settle) { revealed = true }
        guard !reduceMotion else {
            driftX = 0
            driftY = 0
            return
        }
        withAnimation(.easeInOut(duration: 61).repeatForever(autoreverses: true)) { driftX = 1 }
        withAnimation(.easeInOut(duration: 43).repeatForever(autoreverses: true)) { driftY = 1 }
        withAnimation(.easeInOut(duration: 97).repeatForever(autoreverses: true)) { kenBurns = 1.06 }
        withAnimation(.easeInOut(duration: 37).repeatForever(autoreverses: true)) { breathe = 0.88 }
        withAnimation(.easeInOut(duration: 29).repeatForever(autoreverses: true)) { lanePhase = 1 }
    }
}

private struct AmbientNowPlayingComposition: View {
    let track: Track?
    let palette: ArtworkColors.Palette
    let currentTime: TimeInterval
    let duration: TimeInterval
    let setlist: AmbientSetlistContext?
    let artworkSize: CGFloat
    let laneWidth: CGFloat
    let lane: AmbientWaveLane.Model
    let laneFade: Double
    let lanePhase: CGFloat
    let kenBurns: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: Space.section + Space.roomy) {
            AmbientArtwork(url: track?.artworkURL, identity: track?.id ?? "Sounding", size: artworkSize, palette: palette, kenBurns: kenBurns)
            details
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Space.base) {
            Eyebrow(text: "Now Playing", tint: .whiteInk(0.52))

            Text(track?.title ?? "")
                .font(.tvDisplay)
                .kerning(-2.0)
                .lineLimit(3)
                .minimumScaleFactor(0.55)
                .foregroundStyle(.whiteInk(0.90, increased: 1))
                .shadow(color: .black.opacity(0.45), radius: 26, y: 8)

            Text(track?.user.displayName ?? "")
                .font(.tvLargeTitle)
                .foregroundStyle(.whiteInk(0.64))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .shadow(color: .black.opacity(0.30), radius: 12, y: 4)

            elapsedIndicator
                .padding(.top, Space.snug)
        }
        .frame(width: laneWidth, alignment: .leading)
    }

    private var elapsedIndicator: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            AmbientWaveLane(model: lane, width: laneWidth, height: 96, fade: laneFade)

            AmbientPlaybackContext(
                currentTime: currentTime,
                duration: duration,
                setlist: setlist,
                width: laneWidth
            )
        }
        .offset(y: lanePhase * 4)
    }
}

private struct AmbientMixComposition: View {
    let mix: AmbientMixSnapshot
    let palette: ArtworkColors.Palette
    let currentTime: TimeInterval
    let duration: TimeInterval
    let setlist: AmbientSetlistContext?
    let artworkSize: CGFloat
    let laneWidth: CGFloat
    let lane: AmbientWaveLane.Model
    let laneFade: Double
    let lanePhase: CGFloat
    let kenBurns: CGFloat

    var body: some View {
        HStack(alignment: .center, spacing: Space.section + Space.roomy) {
            AmbientArtwork(
                url: mix.outgoing?.artworkURL,
                identity: mix.outgoing?.id ?? "Sounding",
                size: artworkSize,
                palette: palette,
                kenBurns: kenBurns
            )
            details
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Space.base) {
            HStack(spacing: Space.tight) {
                Circle()
                    .fill(palette.accent.opacity(0.85))
                    .frame(width: 14, height: 14)
                Eyebrow(text: mix.eyebrowText, tint: .whiteInk(0.52))
            }

            Text(mix.outgoing?.title ?? "")
                .font(.tvDisplay)
                .kerning(-2.0)
                .lineLimit(2)
                .minimumScaleFactor(0.55)
                .foregroundStyle(.whiteInk(0.90, increased: 1))
                .shadow(color: .black.opacity(0.45), radius: 26, y: 8)

            Text(mix.outgoing?.user.displayName ?? "")
                .font(.tvLargeTitle)
                .foregroundStyle(.whiteInk(0.64))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .shadow(color: .black.opacity(0.30), radius: 12, y: 4)

            mixIndicator
                .padding(.top, Space.snug)
        }
        .frame(width: laneWidth, alignment: .leading)
    }

    private var mixIndicator: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            AmbientWaveLane(model: lane, width: laneWidth, height: 110, fade: laneFade)

            HStack(alignment: .firstTextBaseline, spacing: Space.roomy) {
                Text(mix.countdownText(at: currentTime))
                    .font(.tvSection)
                    .monospacedDigit()
                    .foregroundStyle(.whiteInk(0.78))
                Spacer(minLength: Space.snug)
                if let nextText = mix.nextText {
                    Text(nextText)
                        .font(.tvCaptionEmph)
                        .foregroundStyle(.whiteInk(0.56))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(width: laneWidth)

            AmbientPlaybackContext(
                currentTime: currentTime,
                duration: duration,
                setlist: setlist,
                width: laneWidth
            )

            if !mix.reasoning.isEmpty {
                Text(mix.reasoning)
                    .font(.tvCallout)
                    .foregroundStyle(.whiteInk(0.58))
                    .lineLimit(2)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: laneWidth, alignment: .leading)
                    .padding(.top, Space.hair)
            }
        }
        .offset(y: lanePhase * 4)
    }
}

private struct AmbientSetlistContext: Equatable {
    let itemNumber: Int
    let itemCount: Int
    let label: String
}

private struct AmbientPlaybackContext: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let setlist: AmbientSetlistContext?
    let width: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.base) {
            if let setlist {
                Image(systemName: "music.note.list")
                    .foregroundStyle(.whiteInk(0.50))
                Text("Set \(setlist.itemNumber) of \(setlist.itemCount) · \(setlist.label)")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.whiteInk(0.62))
            } else {
                Text("Set progress")
                    .foregroundStyle(.whiteInk(0.50))
            }

            Spacer(minLength: Space.snug)

            Text("\(AmbientClock.string(currentTime)) / \(AmbientClock.string(duration))")
                .monospacedDigit()
                .foregroundStyle(.whiteInk(0.62))
        }
        .font(.tvCaptionEmph)
        .frame(width: width, alignment: .leading)
        .transaction { $0.animation = nil }
    }
}

private struct AmbientArtwork: View {
    let url: URL?
    let identity: String
    let size: CGFloat
    let palette: ArtworkColors.Palette
    let kenBurns: CGFloat

    var body: some View {
        ArtworkImage(url: url, variant: .hero) {
            SoundingArtworkView(identity: identity, colorScheme: .dark)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Corner.hero, style: .continuous))
        .shadow(color: palette.primary.opacity(0.45), radius: 130, y: 70)
        .shadow(color: .black.opacity(0.50), radius: 70, y: 40)
        .scaleEffect(kenBurns)
        .accessibilityHidden(true)
    }
}

private enum AmbientClock {
    static func string(_ time: TimeInterval) -> String {
        guard time.isFinite, !time.isNaN else { return "0:00" }
        let total = max(0, Int(time))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct AmbientWaveLane: View {
    struct Lane: Equatable {
        let bars: [Float]
        let start: TimeInterval
        let duration: TimeInterval
        let topFraction: CGFloat
        let heightFraction: CGFloat
        var emphasis: Double = 1
    }

    struct Model: Equatable {
        let lanes: [Lane]
        let total: TimeInterval
        let playhead: TimeInterval
        let band: ClosedRange<TimeInterval>?
        let bandTint: Color
    }

    let model: Model
    let width: CGFloat
    let height: CGFloat
    var fade: Double = 1

    static let barCounts = [89, 97, 79, 107, 83]
    static let barRotationSeconds: TimeInterval = 45
    static let barCrossfadeSeconds: TimeInterval = 1.4

    private let reflection: CGFloat = 0.38
    private let playedWhite: Double = 0.46
    private let unplayedWhite: Double = 0.12

    var body: some View {
        ZStack(alignment: .topLeading) {
            band
            Canvas { context, size in
                for lane in model.lanes {
                    draw(lane: lane, in: context, size: size)
                }
            }
            .frame(width: width, height: height)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipped()
        .opacity(fade)
        .accessibilityHidden(true)
    }

    private func draw(lane: Lane, in context: GraphicsContext, size: CGSize) {
        let total = max(model.total, 0.001)
        let x0 = CGFloat(lane.start / total) * size.width
        let x1 = CGFloat((lane.start + lane.duration) / total) * size.width
        let laneWidth = max(1, min(size.width, x1) - x0)
        guard laneWidth > 1 else { return }

        let top = lane.topFraction * size.height
        let laneHeight = lane.heightFraction * size.height
        let axisY = top + laneHeight * (1 / (1 + reflection))
        let upMax = max(2, axisY - top - 1)

        guard !lane.bars.isEmpty else {
            drawEmpty(lane: lane, in: context, x0: x0, x1: min(size.width, x1), axisY: axisY)
            return
        }

        let pitch = laneWidth / CGFloat(lane.bars.count)
        let barWidth = max(2, pitch * 0.5)
        let corner = barWidth / 2

        var played = Path()
        var unplayed = Path()
        var blend = Path()

        for (index, sample) in lane.bars.enumerated() {
            let x = x0 + CGFloat(index) * pitch
            guard x < size.width else { break }

            let barTime = lane.start + (Double(index) + 0.5) / Double(lane.bars.count) * lane.duration
            let up = max(2, CGFloat(sample) * upMax)
            let rect = CGRect(
                x: x,
                y: axisY - up,
                width: barWidth,
                height: up * (1 + reflection)
            )
            let rounded = CGSize(width: corner, height: corner)
            if let band = model.band, band.contains(barTime) {
                blend.addRoundedRect(in: rect, cornerSize: rounded)
            } else if barTime <= model.playhead {
                played.addRoundedRect(in: rect, cornerSize: rounded)
            } else {
                unplayed.addRoundedRect(in: rect, cornerSize: rounded)
            }
        }

        var axis = Path()
        axis.addRect(CGRect(x: x0, y: axisY - 0.5, width: laneWidth, height: 1))
        context.fill(axis, with: .color(.white.opacity(0.07)))

        context.fill(unplayed, with: .color(.white.opacity(unplayedWhite * lane.emphasis)))
        context.fill(played, with: .color(.white.opacity(playedWhite * lane.emphasis)))
        context.fill(blend, with: .color(model.bandTint.opacity(0.72 * lane.emphasis)))
    }

    private func drawEmpty(
        lane: Lane,
        in context: GraphicsContext,
        x0: CGFloat,
        x1: CGFloat,
        axisY: CGFloat
    ) {
        let total = max(model.total, 0.001)
        let playedX = min(x1, max(x0, CGFloat(model.playhead / total) * width))

        var rest = Path()
        rest.move(to: CGPoint(x: playedX, y: axisY))
        rest.addLine(to: CGPoint(x: x1, y: axisY))
        context.stroke(
            rest,
            with: .color(.white.opacity(unplayedWhite + 0.04)),
            style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [7, 9])
        )

        if playedX > x0 + 1 {
            var done = Path()
            done.move(to: CGPoint(x: x0, y: axisY))
            done.addLine(to: CGPoint(x: playedX, y: axisY))
            context.stroke(
                done,
                with: .color(.white.opacity(playedWhite)),
                style: StrokeStyle(lineWidth: 3, lineCap: .round)
            )
        }
    }

    @ViewBuilder
    private var band: some View {
        if let band = model.band {
            let total = max(model.total, 0.001)
            let x0 = CGFloat(min(1, max(0, band.lowerBound / total))) * width

            Rectangle()
                .fill(model.bandTint.opacity(0.45))
                .frame(width: 2, height: height)
                .offset(x: x0)
        }
    }
}

struct AmbientMixSnapshot: Equatable {
    enum Phase: Equatable {
        case waiting
        case armed
        case mixing
        case cutting
    }

    var phase: Phase
    var isActive: Bool = true
    var profileName: String?
    var liveDeckLabel: String
    var cuedDeckLabel: String
    var outgoing: Track?
    var incoming: Track?
    var mixPointSeconds: TimeInterval?
    var transitionSeconds: TimeInterval?
    var entrySeconds: TimeInterval = 0
    var reasoning: String
    var mixProgress: Double?
    var cuedStatus: String
    var cuedIsReady: Bool

    var eyebrowText: String {
        guard isActive else { return "Now Playing" }
        guard let profileName, profileName != "Auto Mix" else { return "Auto Mix" }
        return "\(profileName) · Auto Mix"
    }

    var nextText: String? {
        guard isActive else { return nil }
        guard let incoming else { return nil }
        return "Up next · \(incoming.title)"
    }

    func countdownText(at currentTime: TimeInterval) -> String {
        guard isActive else { return "Playing it straight" }
        switch phase {
        case .mixing:
            if let seconds = transitionSeconds, let progress = mixProgress {
                let left = max(0, seconds * (1 - progress))
                return "Mixing · \(Int(left.rounded()))s left"
            }
            return "Mixing"
        case .cutting:
            return "Cutting"
        case .armed:
            guard let point = mixPointSeconds else { return "Listening" }
            let remaining = point - currentTime
            if remaining <= 0 { return "Mixing now" }
            return "Mix in \(AmbientClock.string(remaining))"
        case .waiting:
            return "Listening"
        }
    }

    @MainActor
    static func resolve(from player: PlayerService) -> AmbientMixSnapshot? {
        guard let outgoing = player.currentTrack else { return nil }

        let activity = player.phantomActivity
        let window = player.mixWindow
        let profileName = player.djProfile?.displayName

        let sessionIsLive = player.isDJSessionEnabled
            || player.isMixEngineLive
            || window != nil
            || activity != .idle

        // Auto DJ is on by default, but it has no useful deck information to
        // show until there is an incoming track or a transition in progress.
        // In that common single-track state, use the cleaner Now Playing
        // composition instead of announcing empty decks.
        let hasMixContext = player.upcomingTrack != nil
            || player.isMixEngineLive
            || window != nil
            || activity != .idle

        guard sessionIsLive, hasMixContext else { return nil }

        var phase: Phase = .waiting
        var reasoning = ""
        var mixPoint: TimeInterval?
        var transition: TimeInterval?
        var entry: TimeInterval = 0

        switch activity {
        case .idle:
            break
        case .armed(let plan):
            phase = .armed
            reasoning = plan.reasoning
            mixPoint = plan.mixPointSeconds
            transition = plan.transitionSeconds
            entry = plan.entrySeconds
        case .mixing(let plan):
            phase = .mixing
            reasoning = plan.reasoning
            mixPoint = plan.mixPointSeconds
            transition = plan.transitionSeconds
            entry = plan.entrySeconds
        case .cutting(let reason):
            phase = .cutting
            reasoning = reason
        }

        if let window {
            if window.isLive, phase != .cutting { phase = .mixing }
            if mixPoint == nil {
                mixPoint = window.start
                transition = window.seconds
            }
        }

        if reasoning.isEmpty {
            reasoning = fallbackReasoning(player: player, hasProfile: profileName != nil)
        }

        return AmbientMixSnapshot(
            phase: phase,
            profileName: profileName,
            liveDeckLabel: player.liveDeck.label,
            cuedDeckLabel: player.liveDeck.other.label,
            outgoing: outgoing,
            incoming: player.upcomingTrack,
            mixPointSeconds: mixPoint,
            transitionSeconds: transition,
            entrySeconds: entry,
            reasoning: reasoning,
            mixProgress: window?.progress,
            cuedStatus: cuedStatus(player.incomingDeck),
            cuedIsReady: player.incomingDeck.isReady
        )
    }

    private static func cuedStatus(_ deck: IncomingDeckState) -> String {
        switch deck {
        case .idle:               return "Nothing cued"
        case .loading(let value): return "Loading \(Int((value * 100).rounded()))%"
        case .ready:              return "Cued"
        case .failed:             return "Can't be mixed"
        }
    }

    @MainActor
    private static func fallbackReasoning(player: PlayerService, hasProfile: Bool) -> String {
        switch player.mixEngineState {
        case .preparing(let progress):
            return "Getting this track onto a deck, \(Int((progress * 100).rounded()))%."
        case .unavailable(let reason):
            #if DEBUG
            if ProcessInfo.processInfo.environment["SOUNDING_TV_LOG_MIX_IMPORT"] == "1" {
                return reason
            }
            #endif
            return "Auto Mix couldn't prepare a clean transition. Playback will continue normally."
        case .off:
            return hasProfile
                ? "Auto Mix starts with the next track."
                : "Auto Mix is on. No transition planned for this track yet."
        case .live:
            if player.upcomingTrack == nil {
                return "Nothing queued after this. It plays out to the end."
            }
            return "Looking for a mix point in this track."
        }
    }
}

#if DEBUG
extension AmbientMixSnapshot {
    @MainActor
    static func debugSynthetic(from player: PlayerService) -> AmbientMixSnapshot {
        let duration = max(player.duration, 200)
        let point = max(player.currentTime + 84, duration * 0.78)
        return AmbientMixSnapshot(
            phase: .armed,
            profileName: "Smooth",
            liveDeckLabel: "A",
            cuedDeckLabel: "B",
            outgoing: player.currentTrack,
            incoming: player.upcomingTrack,
            mixPointSeconds: point,
            transitionSeconds: 14,
            entrySeconds: 0,
            reasoning: "Breakdown found at \(AmbientClock.string(point)) - 14s blend with a bass swap, "
                + "filtering the outgoing deck down.",
            mixProgress: nil,
            cuedStatus: "Cued",
            cuedIsReady: true
        )
    }
}
#endif

@MainActor
enum NowPlayingIdleHold {
    static var isActive = false
}

@MainActor
final class AmbientIdleMonitor: ObservableObject {
    nonisolated static let idleTimeout: TimeInterval = 90

    @Published var isShowingAmbient = false

    private var timeout: TimeInterval = AmbientIdleMonitor.idleTimeout
    private var lastInputAt = Date.now
    private var holdingIdleTimer = false
    private var spy: InputSpyRecognizer?
    private var observers: [NSObjectProtocol] = []

    nonisolated(unsafe) private var tickTask: Task<Void, Never>?

    deinit {
        tickTask?.cancel()
    }

    func start(timeout: TimeInterval = AmbientIdleMonitor.idleTimeout) {
        guard tickTask == nil else { return }
        self.timeout = timeout
        lastInputAt = .now
        attachInputSpy()
        observeLifecycle()

        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    func update(timeout: TimeInterval) {
        guard timeout != self.timeout else { return }
        self.timeout = timeout
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
        detachInputSpy()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        setIdleTimer(disabled: false)
        if isShowingAmbient { isShowingAmbient = false }
    }

    func noteInput() {
        lastInputAt = .now
        if isShowingAmbient { isShowingAmbient = false }
    }

    private func tick() {
        if spy == nil { attachInputSpy() }

        let player = PlayerService.shared

        guard player.isPlaying, player.currentTrack != nil, !TVDecksPresence.isOnScreen else {
            setIdleTimer(disabled: player.isPlaying && TVDecksPresence.isOnScreen)
            if isShowingAmbient { isShowingAmbient = false }
            lastInputAt = .now
            return
        }

        setIdleTimer(disabled: true)

        if NowPlayingIdleHold.isActive, !isShowingAmbient {
            lastInputAt = .now
            return
        }

        if !isShowingAmbient, Date.now.timeIntervalSince(lastInputAt) >= timeout {
            isShowingAmbient = true
        }
    }

    private func setIdleTimer(disabled: Bool) {
        guard holdingIdleTimer != disabled else { return }
        holdingIdleTimer = disabled
        UIApplication.shared.isIdleTimerDisabled = disabled
    }

    private func attachInputSpy() {
        guard spy == nil, let window = Self.keyWindow else { return }
        let recognizer = InputSpyRecognizer()
        recognizer.onInput = { [weak self] in self?.noteInput() }
        window.addGestureRecognizer(recognizer)
        spy = recognizer
    }

    private func detachInputSpy() {
        if let spy { spy.view?.removeGestureRecognizer(spy) }
        spy = nil
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }

    private func observeLifecycle() {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.setIdleTimer(disabled: false)
                    if self?.isShowingAmbient == true { self?.isShowingAmbient = false }
                }
            }
        )
        observers.append(
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.noteInput() }
            }
        )
    }
}

final class InputSpyRecognizer: UIGestureRecognizer {
    var onInput: (() -> Void)?

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onInput?()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        onInput?()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        onInput?()
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        onInput?()
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        state = .failed
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        state = .failed
    }
}

extension View {
    func ambientScreen(isEnabled: Bool = true, after timeout: TimeInterval? = nil) -> some View {
        modifier(AmbientScreenPresenter(isEnabled: isEnabled, timeout: timeout))
    }
}

private struct AmbientScreenPresenter: ViewModifier {
    let isEnabled: Bool
    let timeout: TimeInterval?

    @StateObject private var monitor = AmbientIdleMonitor()
    @ObservedObject private var settings = SettingsStore.shared

    private var resolvedTimeout: TimeInterval {
        if let timeout { return timeout }
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["SOUNDING_TV_AMBIENT"],
           let seconds = Double(raw), seconds > 0 {
            return seconds
        }
        #endif
        return settings.ambientScreensaverTimeoutSeconds
    }

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $monitor.isShowingAmbient) {
                AmbientScreenView(onDismiss: monitor.noteInput)
            }
            .onAppear {
                if isEnabled {
                    monitor.start(timeout: resolvedTimeout)
                } else {
                    monitor.stop()
                }
            }
            .onDisappear { monitor.stop() }
            .onChange(of: resolvedTimeout) { _, seconds in monitor.update(timeout: seconds) }
            .onChange(of: isEnabled) { _, enabled in
                if enabled {
                    monitor.start(timeout: resolvedTimeout)
                } else {
                    monitor.stop()
                }
            }
    }
}

#Preview("Ambient") {
    AmbientScreenView()
}

#Preview("Ambient · DJ") {
    AmbientScreenView(
        mixOverride: AmbientMixSnapshot(
            phase: .armed,
            profileName: "Smooth",
            liveDeckLabel: "A",
            cuedDeckLabel: "B",
            outgoing: nil,
            incoming: nil,
            mixPointSeconds: 214,
            transitionSeconds: 14,
            entrySeconds: 0,
            reasoning: "Breakdown found at 3:34 - 14s blend with a bass swap, filtering the outgoing deck down.",
            mixProgress: nil,
            cuedStatus: "Cued",
            cuedIsReady: true
        )
    )
}
