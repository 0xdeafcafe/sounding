import SwiftUI

struct MacDJAnalysingView: View {
    let progress: Double
    let fallbackTitle: String?
    let usesCanvas: Bool
    let deck: MacDJDeckState

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MacDJPlaceholderWave()
                .frame(height: 150)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(MacDJPalette.well))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Analysing beat grid and key")
                    Spacer()
                    Text("\(Int((progress * 100).rounded()))%").monospacedDigit().foregroundStyle(contrast.djInk(0.66))
                }
                .font(.system(size: 13))
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.white)
            }
            HStack(spacing: 10) {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(Capsule().fill(.white.opacity(0.05)))
                    .foregroundStyle(.white.opacity(0.35))
                Text("Available when the grid is ready")
                    .font(.system(size: 12))
                    .foregroundStyle(contrast.djInk(0.66))
                Spacer()
                Button("Cancel") { MacDJPerformModel.shared.cancelLoad(deck.deck) }
                    .buttonStyle(MacDJControlButtonStyle(height: 26))
            }
            if let fallbackTitle {
                Label("Auto Mix will use \(fallbackTitle) instead if this isn\u{2019}t ready in 2:00.", systemImage: "sparkle")
                    .font(.system(size: 12))
                    .foregroundStyle(contrast.djInk(0.85))
                    .labelStyle(MacDJAutoLabelStyle())
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct MacDJAutoLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.foregroundStyle(MacDJPalette.auto)
            configuration.title
        }
    }
}

struct MacDJPlaceholderWave: View {
    var body: some View {
        Canvas { context, size in
            var x: CGFloat = 20
            var i = 0.0
            while x < size.width - 20 {
                let h = CGFloat(0.25 + 0.45 * abs(sin(i * 0.9) * cos(i * 0.31))) * size.height
                context.fill(Path(roundedRect: CGRect(x: x, y: (size.height - h) / 2, width: 3, height: h), cornerRadius: 1.5), with: .color(.white.opacity(0.2)))
                x += 8
                i += 1
            }
        }
        .accessibilityHidden(true)
    }
}

struct MacDJNoGridControls: View {
    let deck: MixEngine.Deck

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(Capsule().fill(.white.opacity(0.05)))
                    .foregroundStyle(.white.opacity(0.35))
                    .accessibilityLabel("Sync, unavailable without a grid")
                Group {
                    Button("Tap Tempo") { MacDeckPrepActions.tap(deck, undoManager: undoManager) }
                        .help("Tap the beat four times to set the tempo")
                        .disabled(!MacDeckPrepActions.canEdit(deck))
                    Button("Set Downbeat") { MacDeckPrepActions.setDownbeat(deck, undoManager: undoManager) }
                        .help("Set the downbeat at the playhead")
                        .disabled(!MacDeckPrepActions.canEdit(deck))
                    Button("Add Cue") { MacDeckPrepActions.addCue(deck) }
                        .help("Add a hot cue at the playhead")
                        .disabled(!MacDeckPrepActions.canEdit(deck))
                    Button("Edit in Prep") { MacDeckPrepActions.openPrep(deck) }
                }
                .buttonStyle(MacDJControlButtonStyle(height: 26))
                .fixedSize()
            }
            Label("Phase: unknown", systemImage: "waveform")
                .font(.system(size: 13))
                .foregroundStyle(contrast.djInk(0.9))
            Label("Auto Mix: cut on the bar, no blend", systemImage: "sparkle")
                .font(.system(size: 13))
                .labelStyle(MacDJAutoLabelStyle())
        }
    }
}

struct MacDeckPrepMenuItems: View {
    let deck: MixEngine.Deck

    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Group {
            Button("Set Downbeat") { MacDeckPrepActions.setDownbeat(deck, undoManager: undoManager) }
            Button("Tap Tempo") { MacDeckPrepActions.tap(deck, undoManager: undoManager) }
            Button("Add Cue") { MacDeckPrepActions.addCue(deck) }
        }
        .disabled(!MacDeckPrepActions.canEdit(deck))
        Button("Edit in Prep") { MacDeckPrepActions.openPrep(deck) }
            .disabled(MacDeckTrackRegistry.shared.track(for: deck) == nil)
    }
}

@MainActor
enum MacDeckPrepActions {
    private static var taps: [MixEngine.Deck: [Date]] = [:]

    static func canEdit(_ deck: MixEngine.Deck) -> Bool {
        guard let track = MacDeckTrackRegistry.shared.track(for: deck) else { return false }
        return MacDeckControlSurface.djDenial(.prep, source: track.source) == nil
    }

    static func openPrep(_ deck: MixEngine.Deck) {
        if let track = MacDeckTrackRegistry.shared.track(for: deck) { MacPrepRoute.shared.inspect(track) }
    }

    static func setDownbeat(_ deck: MixEngine.Deck, undoManager: UndoManager?) {
        let millis = CueTime.millis(fromSeconds: MixEngine.shared.livePosition(of: deck))
        edit(deck, action: "Set Downbeat", undoManager: undoManager) { grid in
            PrepGridEditor.setDownbeat(grid ?? PrepGrid(segments: [PrepTempoSegment(startMillis: millis, bpm: 120)]), atMillis: millis)
        }
    }

    static func tap(_ deck: MixEngine.Deck, undoManager: UndoManager?, now: Date = Date()) {
        var times = taps[deck] ?? []
        if let last = times.last, now.timeIntervalSince(last) > 2 { times.removeAll() }
        times.append(now)
        if times.count > 8 { times.removeFirst(times.count - 8) }
        taps[deck] = times
        guard times.count >= 4, let first = times.first, let last = times.last else { return }
        let interval = last.timeIntervalSince(first) / Double(times.count - 1)
        guard interval > 0 else { return }
        let bpm = (60 / interval * 100).rounded() / 100
        let millis = CueTime.millis(fromSeconds: MixEngine.shared.livePosition(of: deck))
        edit(deck, action: "Tap Tempo", undoManager: undoManager) { grid in
            guard let grid else { return PrepGrid(segments: [PrepTempoSegment(startMillis: millis, bpm: bpm)]) }
            return PrepGridEditor.setBPM(grid, bpm: bpm)
        }
    }

    static func addCue(_ deck: MixEngine.Deck) {
        guard canEdit(deck), let track = MacDeckTrackRegistry.shared.track(for: deck) else { return }
        let console = MacConsoleController.shared
        let taken = Set((console.hotCues[deck.rawValue] ?? []).compactMap(\.hotCueIndex))
        if let slot = (0..<CuePoint.hotCueSlotCount).first(where: { !taken.contains($0) }) {
            console.hotCue(deck, index: slot)
            return
        }
        let millis = CueTime.millis(fromSeconds: MixEngine.shared.livePosition(of: deck))
        Task { _ = await CueStore.shared.addMemoryCue(trackId: track.id, positionMillis: millis) }
    }

    private static func edit(_ deck: MixEngine.Deck, action: String, undoManager: UndoManager?, change: @escaping (PrepGrid?) -> PrepGrid) {
        guard canEdit(deck), let track = MacDeckTrackRegistry.shared.track(for: deck) else { return }
        let store = CueStore.shared
        let duration = MixEngine.shared[deck].duration > 0 ? MixEngine.shared[deck].duration : track.duration
        Task {
            let prep = await store.prep(forTrack: track.id)
            let previous = prep?.grid
            let grid = change(previous?.value)
            await store.setUserGrid(trackId: track.id, grid)
            apply(grid, to: deck, trackId: track.id, duration: duration)
            undoManager?.registerUndo(withTarget: store) { _ in
                MainActor.assumeIsolated { restore(previous, deck: deck, trackId: track.id, duration: duration) }
            }
            undoManager?.setActionName(action)
        }
    }

    private static func restore(_ field: PrepField<PrepGrid>?, deck: MixEngine.Deck, trackId: String, duration: TimeInterval) {
        let store = CueStore.shared
        Task {
            var prep = await store.prep(forTrack: trackId) ?? TrackPrep(trackId: trackId)
            prep.grid = field.map { PrepField($0.value, source: $0.source, updatedAtMillis: CueTime.nowMillis(), writerId: store.writerId) }
            await store.savePrep(prep)
            apply(field?.value, to: deck, trackId: trackId, duration: duration)
        }
    }

    private static func apply(_ grid: PrepGrid?, to deck: MixEngine.Deck, trackId: String, duration: TimeInterval) {
        guard MixEngine.shared[deck].trackId == trackId || MacDeckTrackRegistry.shared.track(for: deck)?.id == trackId else { return }
        MixEngine.shared.setBeatGrid(grid?.beatGrid(durationSeconds: duration, confidence: 0.9), for: deck)
    }
}

struct MacDJDeckProblemView: View {
    let problem: MacDJDeckProblem
    let deck: MixEngine.Deck

    var body: some View {
        switch problem {
        case .fileMissing(let title, let other):
            ContentUnavailableView {
                Label("Can\u{2019}t Play \(title)", systemImage: "doc")
            } description: {
                Text("The file was moved or renamed. Deck \(deck.label) is empty; Deck \(other.label) keeps playing.")
            } actions: {
                HStack {
                    Button("Relink\u{2026}") { MacConsoleController.shared.loadTarget = deck }
                        .buttonStyle(.borderedProminent)
                    Button("Choose Another Track") { MacConsoleController.shared.loadTarget = deck }
                        .buttonStyle(.bordered)
                }
            }
        case .failed(let title, let message):
            ContentUnavailableView {
                Label(title, systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Choose Another Track") { MacConsoleController.shared.loadTarget = deck }
                    .buttonStyle(.bordered)
            }
        }
    }
}

struct MacDJBannerView: View {
    let banner: MacDJBanner
    var onAction: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "airplayaudio")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.85))
            (Text(banner.title).fontWeight(.semibold) + Text(" ") + Text(banner.detail))
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(banner.action, action: onAction)
                .buttonStyle(MacDJControlButtonStyle(height: 26))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color(white: 0.11))
    }
}

#if DEBUG
struct MacDJStatesGallery: View {
    var body: some View {
        let fixtures = MacDJFixtures.states()
        HStack(alignment: .top, spacing: 28) {
            column(title: "Loading and analysing", detail: "The deck plays as soon as the audio is in. Sync and Auto Mix wait for the grid.") {
                MacDJDeckView(deck: .b, state: fixtures.analysing, usesCanvas: true, model: .shared)
                    .padding(24)
            }
            column(title: "No beat grid", detail: "Never shows \u{201C}In phase\u{201D} without evidence. Auto Mix cuts on a phrase instead of blending.") {
                VStack(spacing: 0) {
                    MacDJDeckView(deck: .a, state: fixtures.noGrid, usesCanvas: true, model: .shared)
                        .frame(height: 140)
                    MacDJNoGridLane(deck: fixtures.noGrid.deck(.a))
                        .frame(height: 150)
                        .padding(.top, -66)
                    MacDJNoGridControls(deck: .a)
                        .padding(.top, 14)
                    Spacer(minLength: 0)
                }
                .padding(24)
            }
            column(title: "Errors", detail: "Playback carries on where it can. The failed thing is named, with one recovery action.") {
                VStack(spacing: 0) {
                    MacDJBannerView(banner: MacDJBanner(title: "USB audio interface disconnected.", detail: "Playing on MacBook Pro Speakers.", action: "Reconnect"))
                    MacDJDeckProblemView(problem: .fileMissing(title: "Halflight", otherDeck: .a), deck: .b)
                        .frame(maxHeight: .infinity)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(white: 0.06))
        .environment(\.colorScheme, .dark)
    }

    private func column<Content: View>(title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(detail).font(.system(size: 14)).foregroundStyle(.white.opacity(0.66)).fixedSize(horizontal: false, vertical: true)
            content()
                .frame(maxWidth: .infinity, minHeight: 470, maxHeight: 470, alignment: .top)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(white: 0.085)))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.top, 14)
        }
        .frame(maxWidth: .infinity)
    }
}
#endif

struct MacDJNoGridLane: View {
    let deck: MacDJDeckState

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                for column in 0..<Int(size.width) {
                    let x = CGFloat(column)
                    let t = Double(x)
                    let pulse = max(0, 1 - (t / 17.3).truncatingRemainder(dividingBy: 1) * 3)
                    let amp = CGFloat(0.25 + pulse * 0.65) * size.height / 2
                    context.fill(Path(CGRect(x: x, y: size.height / 2 - amp, width: 0.85, height: amp * 2)), with: .color(Color(red: 0.18, green: 0.42, blue: 1.0)))
                    context.fill(Path(CGRect(x: x, y: size.height / 2 - amp * 0.2, width: 0.85, height: amp * 0.4)), with: .color(.white.opacity(0.9)))
                }
            }
            if case .noGrid(let range) = deck.analysis {
                Text("No grid \u{00B7} \(range)")
                    .font(.system(size: 13, weight: .semibold))
                    .shadow(color: .black, radius: 3)
                    .padding(12)
            }
        }
        .background(MacDJPalette.well)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
