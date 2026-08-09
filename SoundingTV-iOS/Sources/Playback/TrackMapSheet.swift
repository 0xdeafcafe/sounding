import SwiftUI

struct TrackMapSheet: View {
    let trackTitle: String
    let trackId: String
    let currentPosition: TimeInterval
    let duration: TimeInterval
    let envelope: [Float]
    @ObservedObject var board: CueBoard
    let accent: Color
    let onSeek: (TimeInterval) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var scrubPreview: TimeInterval?
    @State private var renamingCue: CuePoint?
    @State private var renameText = ""

    private static let laneHeight: CGFloat = 72

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                timeline
                mapList
                footer
            }
            .background(Color.scBgBase.ignoresSafeArea())
            .navigationTitle("Cue Points")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .alert("Rename Moment", isPresented: renamingBinding) {
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

    private var markTime: TimeInterval { scrubPreview ?? currentPosition }

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, markTime / duration))
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            Text(trackTitle)
                .font(.scHeadline)
                .foregroundStyle(.white)
                .lineLimit(1)

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
                    .frame(width: width, height: Self.laneHeight)

                    markerOverlay(width: width)
                }
                .frame(width: width, height: Self.laneHeight)
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
            .frame(height: Self.laneHeight)

            readout
        }
        .padding(.horizontal, Space.page)
        .padding(.bottom, Space.base)
    }

    private var readout: some View {
        HStack(spacing: Space.tight) {
            Text(DJFormat.time(markTime))
                .foregroundStyle(scrubPreview == nil ? Color.scTextSecondary : accent)

            if scrubPreview != nil {
                Button("Seek Here") {
                    onSeek(markTime)
                    scrubPreview = nil
                }
                .font(.scCaption)
                .buttonStyle(.borderless)
                .tint(accent)
            }

            Spacer(minLength: 0)

            Text(DJFormat.time(duration))
                .foregroundStyle(Color.scTextTertiary)
        }
        .font(.scNumeric)
        .monospacedDigit()
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

    private var mapList: some View {
        List {
            mixPointRow(.inPoint)

            if moments.isEmpty {
                emptyMoments
            } else {
                ForEach(moments) { entry in
                    switch entry {
                    case .moment(let cue):       momentRow(cue)
                    case .suggestion(let s):     suggestionRow(s)
                    }
                }
            }

            mixPointRow(.outPoint)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
    }

    private var moments: [MapEntry] {
        board.sheet.entries.compactMap { entry in
            guard entry.kind != .mixIn, entry.kind != .mixOut else { return nil }
            if let cue = entry.userCue { return .moment(cue) }
            if let suggestion = entry.suggestion { return .suggestion(suggestion) }
            return nil
        }
    }

    private var emptyMoments: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Nothing marked in this track yet")
                .font(.scSubhead)
                .foregroundStyle(Color.scTextSecondary)
            Text("Drag the timeline above, then save the moment below.")
                .font(.scCaption)
                .foregroundStyle(Color.scTextTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .rowChrome()
    }

    @ViewBuilder
    private func mixPointRow(_ role: MixRole) -> some View {
        let state = mixState(role)

        TrackMapRow(
            glyph: TrackMapGlyph(shape: .diamond, style: state.glyphStyle, color: role.color),
            title: role.title,
            isTitleUppercased: true,
            caption: caption(for: state, role: role),
            time: state.positionSeconds.map(DJFormat.time),
            isMuted: state.isMuted
        ) {
            switch state {
            case .set(let cue):
                Menu {
                    Button("Move to \(DJFormat.time(markTime))") { setMixPoint(role) }
                    Button("Clear", role: .destructive) { Task { await board.delete(cue) } }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .tint(accent)
            case .suggested(let suggestion):
                Menu {
                    Button("Keep Suggestion") { Task { await board.promote(suggestion) } }
                    Button("Set to \(DJFormat.time(markTime))") { setMixPoint(role) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .tint(accent)
            case .unset:
                Button("Set \(DJFormat.time(markTime))") { setMixPoint(role) }
                    .font(.scCaption)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(accent)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let seconds = state.positionSeconds { jump(to: seconds) }
        }
        .rowChrome()
    }

    private func momentRow(_ cue: CuePoint) -> some View {
        TrackMapRow(
            glyph: TrackMapGlyph(shape: .circle, style: .solid, color: cue.color.color),
            title: cue.label.isEmpty ? "Moment" : cue.label,
            isTitleUppercased: false,
            caption: momentCaption(cue),
            time: DJFormat.time(cue.positionSeconds),
            isMuted: false
        ) {
            EmptyView()
        }
        .contentShape(Rectangle())
        .onTapGesture { jump(to: cue.positionSeconds) }
        .rowChrome()
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
    }

    private func suggestionRow(_ suggestion: CueSuggestion) -> some View {
        TrackMapRow(
            glyph: TrackMapGlyph(shape: .circle, style: .hollow, color: suggestion.color.color),
            title: suggestion.label.isEmpty ? suggestion.kind.displayName.capitalized : suggestion.label,
            isTitleUppercased: false,
            caption: suggestion.reasoning.isEmpty ? "Found automatically" : suggestion.reasoning,
            time: DJFormat.time(suggestion.positionSeconds),
            isMuted: true
        ) {
            Button {
                Task { await board.promote(suggestion) }
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .tint(accent)
        }
        .contentShape(Rectangle())
        .onTapGesture { jump(to: suggestion.positionSeconds) }
        .rowChrome()
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task { await board.dismiss(suggestion) }
            } label: {
                Label("Hide", systemImage: "xmark")
            }
        }
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
            HStack(spacing: Space.tight) {
                Image(systemName: "plus.circle.fill")
                Text("Save This Moment")
                Spacer(minLength: Space.tight)
                Text(DJFormat.time(markTime))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
            }
            .font(.scHeadline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.snug)
            .padding(.horizontal, Space.base)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(accent)
        .padding(.horizontal, Space.page)
        .padding(.top, Space.snug)
        .padding(.bottom, Space.base)
        .background(Color.scBgBase)
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

    private func caption(for state: MixState, role: MixRole) -> String {
        switch state {
        case .set:
            return role.setCaption
        case .suggested(let suggestion):
            return suggestion.reasoning.isEmpty ? "Suggested. Keep it to lock it in" : "Suggested · \(suggestion.reasoning)"
        case .unset:
            return role.unsetCaption
        }
    }

    private func momentCaption(_ cue: CuePoint) -> String {
        if let from = cue.promotedFrom { return "Kept from a \(from.name) suggestion" }
        if let index = cue.hotCueIndex, let scalar = UnicodeScalar(65 + index) {
            return "Saved by you · Pad \(Character(scalar))"
        }
        if let end = cue.endSeconds { return "Saved by you · runs to \(DJFormat.time(end))" }
        return "Saved by you"
    }
}

private enum MixRole: Equatable {
    case inPoint
    case outPoint

    var title: String { self == .inPoint ? "Mix In" : "Mix Out" }
    var color: Color { (self == .inPoint ? CueColor.mixIn : CueColor.mixOut).color }

    var setCaption: String {
        self == .inPoint ? "The DJ starts this track here" : "The DJ leaves this track here"
    }

    var unsetCaption: String {
        self == .inPoint
            ? "Not set. The DJ picks where to come in"
            : "Not set. The DJ picks where to leave"
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
    case moment(CuePoint)
    case suggestion(CueSuggestion)

    var id: String {
        switch self {
        case .moment(let cue):            return cue.id
        case .suggestion(let suggestion): return suggestion.id
        }
    }
}

// MARK: - Components

private extension View {
    func rowChrome() -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: Space.page, bottom: 4, trailing: Space.page))
    }
}

private struct TrackMapGlyph: View {
    enum Shape { case diamond, circle }
    enum Style { case solid, hollow, dashed }

    let shape: Shape
    let style: Style
    let color: Color

    private var side: CGFloat { shape == .diamond ? 13 : 11 }

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
    }

    private var base: some InsettableShape {
        RoundedRectangle(cornerRadius: shape == .diamond ? 2.5 : side / 2, style: .continuous)
    }
}

private struct TrackMapRow<Accessory: View>: View {
    let glyph: TrackMapGlyph
    let title: String
    let isTitleUppercased: Bool
    let caption: String
    let time: String?
    let isMuted: Bool
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(spacing: Space.snug) {
            glyph

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.scSubhead)
                    .kerning(isTitleUppercased ? 0.8 : 0)
                    .textCase(isTitleUppercased ? .uppercase : nil)
                    .foregroundStyle(isMuted ? Color.scTextSecondary : .white)
                    .lineLimit(1)

                Text(caption)
                    .font(.scCaption)
                    .foregroundStyle(Color.scTextTertiary)
                    .lineLimit(2)
            }

            Spacer(minLength: Space.tight)

            if let time {
                Text(time)
                    .font(.scSubhead)
                    .monospacedDigit()
                    .foregroundStyle(isMuted ? Color.scTextSecondary : .white)
            }

            accessory()
        }
        .padding(.vertical, Space.snug)
        .padding(.horizontal, Space.base)
        .background(
            RoundedRectangle(cornerRadius: Corner.card, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG

enum TrackMapSheetDemo {
    static let duration: TimeInterval = 214

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
    @StateObject private var board = CueBoard(store: TrackMapSheetDemo.makeStore())
    @State private var seeded = false

    private let envelope = TrackMapSheetDemo.envelope()

    var body: some View {
        TrackMapSheet(
            trackTitle: "Sunset Drive (Extended Mix)",
            trackId: "demo-track",
            currentPosition: 164,
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
        }
    }
}

#endif
