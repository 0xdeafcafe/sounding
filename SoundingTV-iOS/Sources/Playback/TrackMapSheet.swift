import SwiftUI

struct TrackMapSheet: View {
    let trackTitle: String
    let trackId: String
    let fallbackPosition: TimeInterval
    @ObservedObject var playbackClock: PlaybackClock
    let usesLiveClock: Bool
    let isPlaying: Bool
    let duration: TimeInterval
    let envelope: [Float]
    @ObservedObject var board: CueBoard
    let accent: Color
    let onSeek: (TimeInterval) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var scrubPreview: TimeInterval?
    @State private var renamingCue: CuePoint?
    @State private var renameText = ""

    @ScaledMetric(relativeTo: .body) private var laneHeight: CGFloat = 72

    var body: some View {
        NavigationStack {
            List {
                Section {
                    timeline
                        .listRowInsets(EdgeInsets(top: Space.tight, leading: Space.base, bottom: Space.tight, trailing: Space.base))
                        .listRowBackground(Color.clear)
                } header: {
                    Text(trackTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .textCase(nil)
                        .lineLimit(2)
                }

                Section("Mix Points") {
                    mixPointRow(.inPoint)
                    mixPointRow(.outPoint)
                }

                Section("Cue Points") {
                    if cuePoints.isEmpty {
                        ContentUnavailableView(
                            "No Cue Points",
                            systemImage: "bookmark",
                            description: Text("Drag the waveform to a moment, then save it.")
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(cuePoints) { entry in
                            switch entry {
                            case .cue(let cue):              cueRow(cue)
                            case .suggestion(let suggestion): suggestionRow(suggestion)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .safeAreaBar(edge: .bottom) { footer }
            .navigationTitle("Cue Points")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
            .alert("Rename Cue Point", isPresented: renamingBinding) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    if let cue = renamingCue {
                        Task { await board.rename(cue, to: renameText) }
                    }
                    renamingCue = nil
                }
                Button("Cancel", role: .cancel) { renamingCue = nil }
            }
        }
    }

    private var renamingBinding: Binding<Bool> {
        Binding(get: { renamingCue != nil }, set: { if !$0 { renamingCue = nil } })
    }

    private var currentPosition: TimeInterval {
        guard usesLiveClock else { return fallbackPosition }
        let base = playbackClock.currentTime
        guard isPlaying else { return base }
        let ceiling = duration > 0 ? duration : .infinity
        return min(ceiling, base + max(0, Date().timeIntervalSince(playbackClock.updatedAt)))
    }

    private var markTime: TimeInterval { scrubPreview ?? currentPosition }

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, markTime / duration))
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .topLeading) {
                    SCWaveformRenderer(
                        envelope: envelope,
                        duration: duration,
                        progress: progress,
                        placeholder: .unavailable,
                        identity: trackId,
                        style: laneStyle
                    )
                    .frame(width: width, height: laneHeight)

                    markerOverlay(width: width)
                }
                .frame(width: width, height: laneHeight)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0, width > 0 else { return }
                            let fraction = min(1, max(0, value.location.x / width))
                            scrubPreview = Double(fraction) * duration
                        }
                )
            }
            .frame(height: laneHeight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Timeline")
            .accessibilityValue("\(DJFormat.time(markTime)) of \(DJFormat.time(duration))")
            .accessibilityHint("Adjust to pick a moment")
            .accessibilityAdjustableAction { direction in
                let delta: TimeInterval = direction == .increment ? 10 : -10
                scrubPreview = min(duration, max(0, markTime + delta))
            }

            readout
        }
    }

    private var readout: some View {
        HStack(spacing: Space.snug) {
            Text(DJFormat.time(markTime))
                .foregroundStyle(scrubPreview == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))

            if scrubPreview != nil {
                Button("Seek Here") {
                    onSeek(markTime)
                    scrubPreview = nil
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            }

            Spacer(minLength: 0)

            Text(DJFormat.time(duration))
                .foregroundStyle(.secondary)
        }
        .font(.subheadline.monospacedDigit())
    }

    @ViewBuilder
    private func markerOverlay(width: CGFloat) -> some View {
        ForEach(board.sheet.entries) { entry in
            let x = CGFloat(duration > 0 ? min(1, max(0, entry.positionSeconds / duration)) : 0) * width
            Capsule()
                .fill(entry.color.color.opacity(entry.isSuggestion ? 0.45 : 0.95))
                .frame(width: 2, height: 16)
                .offset(x: x - 1)
                .allowsHitTesting(false)
        }
    }

    private var laneStyle: SCWaveformStyle {
        var style = SCWaveformStyle.phone
        style.playedShellColors = [accent]
        style.glowColor = accent
        return style
    }

    private var cuePoints: [MapEntry] {
        board.sheet.entries.compactMap { entry in
            guard entry.kind != .mixIn, entry.kind != .mixOut else { return nil }
            if let cue = entry.userCue { return .cue(cue) }
            if let suggestion = entry.suggestion { return .suggestion(suggestion) }
            return nil
        }
    }

    @ViewBuilder
    private func mixPointRow(_ role: MixRole) -> some View {
        let state = mixState(role)

        HStack(spacing: Space.snug) {
            seekButton(
                time: state.positionSeconds,
                label: {
                    TrackMapRowLabel(
                        glyph: TrackMapGlyph(shape: .diamond, style: state.glyphStyle, color: role.color),
                        title: role.title,
                        caption: caption(for: state, role: role),
                        time: state.positionSeconds.map(DJFormat.time),
                        isMuted: state.isMuted
                    )
                }
            )

            switch state {
            case .set(let cue):
                Menu {
                    Button("Move to \(DJFormat.time(markTime))", systemImage: "arrow.right.to.line") { setMixPoint(role) }
                    Button("Clear", systemImage: "xmark", role: .destructive) { Task { await board.delete(cue) } }
                } label: {
                    Label("Options", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(role.title) options")
            case .suggested(let suggestion):
                Menu {
                    Button("Keep Suggestion", systemImage: "checkmark") { Task { await board.promote(suggestion) } }
                    Button("Set to \(DJFormat.time(markTime))", systemImage: "arrow.right.to.line") { setMixPoint(role) }
                } label: {
                    Label("Options", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(role.title) options")
            case .unset:
                Button("Set") { setMixPoint(role) }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .accessibilityLabel("Set \(role.title) to \(DJFormat.time(markTime))")
            }
        }
    }

    private func cueRow(_ cue: CuePoint) -> some View {
        seekButton(time: cue.positionSeconds) {
            TrackMapRowLabel(
                glyph: TrackMapGlyph(shape: .circle, style: .solid, color: cue.color.color),
                title: cue.label.isEmpty ? "Cue Point" : cue.label,
                caption: cueCaption(cue),
                time: DJFormat.time(cue.positionSeconds),
                isMuted: false
            )
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task { await board.delete(cue) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                renameText = cue.label
                renamingCue = cue
            } label: {
                Label("Rename", systemImage: "pencil")
            }
        }
        .contextMenu {
            Button("Rename", systemImage: "pencil") {
                renameText = cue.label
                renamingCue = cue
            }
            Button("Move to \(DJFormat.time(markTime))", systemImage: "arrow.right.to.line") {
                Task { await board.reposition(cue, toMillis: CueTime.millis(fromSeconds: markTime)) }
            }
            slotMenu(for: cue)
            Button("Delete", systemImage: "trash", role: .destructive) {
                Task { await board.delete(cue) }
            }
        }
    }

    @ViewBuilder
    private func slotMenu(for cue: CuePoint) -> some View {
        if cue.kind == .hotCue || cue.kind == .memory || cue.kind == .loop {
            let taken = Set(board.sheet.userCues.compactMap(\.hotCueIndex))
            Menu("Hot Cue", systemImage: "square.grid.2x2") {
                ForEach(0..<CuePoint.hotCueSlotCount, id: \.self) { slot in
                    Button {
                        Task { await board.assignHotSlot(cue, slot: slot) }
                    } label: {
                        if cue.hotCueIndex == slot {
                            Label(CuePoint.slotLetter(slot), systemImage: "checkmark")
                        } else {
                            Text(CuePoint.slotLetter(slot))
                        }
                    }
                    .disabled(taken.contains(slot) && cue.hotCueIndex != slot)
                }
            }
        }
    }

    private func suggestionRow(_ suggestion: CueSuggestion) -> some View {
        HStack(spacing: Space.snug) {
            seekButton(time: suggestion.positionSeconds) {
                TrackMapRowLabel(
                    glyph: TrackMapGlyph(shape: .circle, style: .hollow, color: suggestion.color.color),
                    title: suggestion.label.isEmpty ? suggestion.kind.displayName.capitalized : suggestion.label,
                    caption: suggestion.reasoning.isEmpty ? "Suggested" : "Suggested · \(suggestion.reasoning)",
                    time: DJFormat.time(suggestion.positionSeconds),
                    isMuted: true
                )
            }

            Button("Accept") {
                Task { await board.promote(suggestion) }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .accessibilityLabel("Accept suggested cue point")

            Button {
                Task { await board.dismiss(suggestion) }
            } label: {
                Label("Dismiss", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss suggested cue point")
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task { await board.dismiss(suggestion) }
            } label: {
                Label("Dismiss", systemImage: "xmark")
            }
        }
        .contextMenu {
            Button("Accept", systemImage: "checkmark") { Task { await board.promote(suggestion) } }
            if board.freeHotSlot() != nil {
                Button("Accept as Hot Cue \(CuePoint.slotLetter(board.freeHotSlot() ?? 0))", systemImage: "square.grid.2x2") {
                    Task { await board.acceptAsHotCue(suggestion) }
                }
            }
            Button("Dismiss", systemImage: "xmark", role: .destructive) { Task { await board.dismiss(suggestion) } }
        }
    }

    private func seekButton<Label: View>(time: TimeInterval?, @ViewBuilder label: () -> Label) -> some View {
        Button {
            if let time { jump(to: time) }
        } label: {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(time == nil)
        .accessibilityHint(time == nil ? "" : "Plays from here")
    }

    private var footer: some View {
        Button {
            Task {
                await board.addMemoryCue(
                    trackId: trackId,
                    positionMillis: CueTime.millis(fromSeconds: markTime)
                )
            }
        } label: {
            Label("Save Cue Point at \(DJFormat.time(markTime))", systemImage: "plus")
                .font(.headline)
                .monospacedDigit()
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .padding(.horizontal, Space.base)
        .padding(.vertical, Space.tight)
        .sensoryFeedback(.selection, trigger: board.sheet.entries.count)
    }

    private func jump(to seconds: TimeInterval) {
        onSeek(seconds)
        dismiss()
    }

    private func setMixPoint(_ role: MixRole) {
        let millis = CueTime.millis(fromSeconds: markTime)
        Task {
            switch role {
            case .inPoint:  await board.setMixIn(trackId: trackId, positionMillis: millis)
            case .outPoint: await board.setMixOut(trackId: trackId, positionMillis: millis)
            }
        }
    }

    private func mixState(_ role: MixRole) -> MixState {
        let resolved = role == .inPoint ? board.sheet.mixIn : board.sheet.mixOut
        guard let resolved else { return .unset }
        if let cue = resolved.userCue { return .set(cue) }
        if let suggestion = resolved.suggestion { return .suggested(suggestion) }
        return .unset
    }

    private func caption(for state: MixState, role: MixRole) -> String? {
        switch state {
        case .set:
            return role.setCaption
        case .suggested(let suggestion):
            return suggestion.reasoning.isEmpty ? "Suggested" : "Suggested · \(suggestion.reasoning)"
        case .unset:
            return "Not set"
        }
    }

    private func cueCaption(_ cue: CuePoint) -> String? {
        var parts: [String] = []
        if let index = cue.hotCueIndex {
            parts.append(cue.kind == .loop ? "Hot Loop \(CuePoint.slotLetter(index))" : "Hot Cue \(CuePoint.slotLetter(index))")
        }
        if let end = cue.endSeconds { parts.append("to \(DJFormat.time(end))") }
        if cue.origin == .imported { parts.append("From rekordbox") } else if cue.promotedFrom != nil { parts.append("From a suggestion") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private enum MixRole: Equatable {
    case inPoint
    case outPoint

    var title: String { self == .inPoint ? "Mix In" : "Mix Out" }
    var color: Color { (self == .inPoint ? CueColor.mixIn : CueColor.mixOut).color }

    var setCaption: String {
        self == .inPoint ? "The mix starts this track here" : "The mix leaves this track here"
    }
}

private enum MixState {
    case set(CuePoint)
    case suggested(CueSuggestion)
    case unset

    var positionSeconds: TimeInterval? {
        switch self {
        case .set(let cue):              return cue.positionSeconds
        case .suggested(let suggestion): return suggestion.positionSeconds
        case .unset:                     return nil
        }
    }

    var glyphStyle: TrackMapGlyph.Style {
        switch self {
        case .set:       return .solid
        case .suggested: return .hollow
        case .unset:     return .dashed
        }
    }

    var isMuted: Bool {
        if case .set = self { return false }
        return true
    }
}

private enum MapEntry: Identifiable {
    case cue(CuePoint)
    case suggestion(CueSuggestion)

    var id: String {
        switch self {
        case .cue(let cue):               return cue.id
        case .suggestion(let suggestion): return suggestion.id
        }
    }
}

// MARK: - Components

private struct TrackMapGlyph: View {
    enum Shape { case diamond, circle }
    enum Style { case solid, hollow, dashed }

    let shape: Shape
    let style: Style
    let color: Color

    @ScaledMetric(relativeTo: .body) private var diamondSide: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var circleSide: CGFloat = 11

    private var side: CGFloat { shape == .diamond ? diamondSide : circleSide }

    var body: some View {
        Group {
            switch style {
            case .solid:
                base.fill(color)
            case .hollow:
                base.strokeBorder(color.opacity(0.85), lineWidth: 2)
            case .dashed:
                base.strokeBorder(color.opacity(0.55), style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
            }
        }
        .frame(width: side, height: side)
        .rotationEffect(.degrees(shape == .diamond ? 45 : 0))
        .frame(width: 22)
        .accessibilityHidden(true)
    }

    private var base: some InsettableShape {
        RoundedRectangle(cornerRadius: shape == .diamond ? 2.5 : side / 2, style: .continuous)
    }
}

private struct TrackMapRowLabel: View {
    let glyph: TrackMapGlyph
    let title: String
    let caption: String?
    let time: String?
    let isMuted: Bool

    var body: some View {
        LabeledContent {
            if let time {
                Text(time)
                    .monospacedDigit()
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(isMuted ? .secondary : .primary)
                    if let caption, !caption.isEmpty {
                        Text(caption)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                glyph
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG

enum TrackMapSheetDemo {
    static let duration: TimeInterval = 214
    static let store = makeStore()

    static func makeStore() -> CueStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrackMapSheetDemo-\(UUID().uuidString)", isDirectory: true)
        return CueStore(directory: directory)
    }

    static func envelope() -> [Float] {
        let count = 1200
        return (0..<count).map { index in
            let seconds = Double(index) / Double(count) * duration
            let base: Double
            switch seconds {
            case ..<18:  base = 0.10
            case ..<96:  base = 0.32
            case ..<132: base = 0.95
            case ..<162: base = 0.12
            case ..<200: base = 0.92
            default:     base = 0.30
            }
            return Float(max(0, min(1, base + 0.05 * sin(Double(index) * 0.7))))
        }
    }
}

struct TrackMapSheetDemoView: View {
    @StateObject private var board = CueBoard(store: TrackMapSheetDemo.store)
    @State private var seeded = false

    private let envelope = TrackMapSheetDemo.envelope()

    var body: some View {
        TrackMapSheet(
            trackTitle: "Sunset Drive (Extended Mix)",
            trackId: "demo-track",
            fallbackPosition: 164,
            playbackClock: PlaybackClock(),
            usesLiveClock: false,
            isPlaying: false,
            duration: TrackMapSheetDemo.duration,
            envelope: envelope,
            board: board,
            accent: .scAccent,
            onSeek: { _ in }
        )
        .task {
            guard !seeded else { return }
            seeded = true
            board.ensureLoaded(
                trackId: "demo-track",
                duration: TrackMapSheetDemo.duration,
                waveform: Waveform(samples: envelope)
            )
            try? await Task.sleep(for: .milliseconds(500))
            await board.setMixIn(trackId: "demo-track", positionMillis: 18_000)
            await board.addMemoryCue(trackId: "demo-track", positionMillis: 108_000, label: "Vocal comes back")
            await board.setHotCue(trackId: "demo-track", index: 0, positionMillis: 96_000, label: "Drop")
            for suggestion in board.sheet.suggestions where suggestion.kind == .memory {
                await board.dismiss(suggestion)
            }
            await TrackMapSheetDemo.store.setHotLoop(trackId: "demo-track", index: 2, startMillis: 132_000, endMillis: 139_500, label: "Roll")
            for session in ["s1", "s1", "s2"] {
                await TrackMapSheetDemo.store.recordListening(trackId: "demo-track", positionMillis: 162_000, sessionId: session)
            }
            await board.refresh()
        }
    }
}

#endif
