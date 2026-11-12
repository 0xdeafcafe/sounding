import SwiftUI

struct TrackMapGlyphView: View {
    let glyph: TrackMapModel.Glyph

    #if os(tvOS)
    private let diamondSide: CGFloat = 20
    private let circleSide: CGFloat = 18
    private let lineWidth: CGFloat = 3
    private let slot: CGFloat = 44
    #else
    @ScaledMetric(relativeTo: .body) private var diamondSide: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var circleSide: CGFloat = 11
    private let lineWidth: CGFloat = 2
    private let slot: CGFloat = 22
    #endif

    private var side: CGFloat { glyph.shape == .diamond ? diamondSide : circleSide }

    private var cornerRadius: CGFloat {
        switch glyph.shape {
        case .diamond: return side * 0.2
        case .circle: return side / 2
        case .square: return side * 0.22
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let color = glyph.color.color
        Group {
            switch glyph.fill {
            case .solid:
                shape.fill(color)
            case .hollow:
                shape.strokeBorder(color.opacity(0.85), lineWidth: lineWidth)
            case .dashed:
                shape.strokeBorder(color.opacity(0.55), style: StrokeStyle(lineWidth: lineWidth, dash: [lineWidth * 1.5, lineWidth * 1.5]))
            }
        }
        .frame(width: side, height: side)
        .rotationEffect(.degrees(glyph.shape == .diamond ? 45 : 0))
        .frame(width: slot)
        .accessibilityHidden(true)
    }
}

struct TrackMapLane: View {
    @ObservedObject var model: TrackMapModel
    let height: CGFloat
    var style: SCWaveformStyle = .phone
    var highlightedId: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    #if os(tvOS)
    private let markerWidth: CGFloat = 4
    private let markerHeight: CGFloat = 44
    private let markerCap: CGFloat = 16
    private let phraseHeight: CGFloat = 8
    #else
    private let markerWidth: CGFloat = 2
    private let markerHeight: CGFloat = 16
    private let markerCap: CGFloat = 0
    private let phraseHeight: CGFloat = 4
    #endif

    var body: some View {
        VStack(spacing: phraseHeight) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .topLeading) {
                    SCWaveformRenderer(
                        envelope: model.envelope,
                        duration: model.duration,
                        progress: model.progress,
                        placeholder: .unavailable,
                        identity: model.trackId,
                        motionSuppressed: reduceMotion,
                        style: style
                    )
                    .frame(width: width, height: height)

                    ForEach(model.markers) { marker in
                        markerView(marker, width: width)
                    }
                }
                .frame(width: width, height: height)
            }
            .frame(height: height)

            if !model.phrases.isEmpty {
                phraseStrip
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: highlightedId)
    }

    @ViewBuilder
    private func markerView(_ marker: TrackMapModel.Marker, width: CGFloat) -> some View {
        let isLead = marker.id == highlightedId
        let x = CGFloat(marker.fraction) * width
        let color = marker.color.color
        ZStack(alignment: .topLeading) {
            if let end = marker.endFraction, end > marker.fraction {
                Rectangle()
                    .fill(color.opacity(marker.isSuggestion ? 0.12 : 0.22))
                    .frame(width: max(markerWidth, CGFloat(end - marker.fraction) * width), height: height)
                    .offset(x: x)
            }
            Capsule()
                .fill(color.opacity(marker.isSuggestion && !isLead ? 0.45 : 0.95))
                .frame(width: isLead ? markerWidth * 2 : markerWidth, height: isLead ? height : markerHeight)
                .offset(x: x - (isLead ? markerWidth : markerWidth / 2))
                .shadow(color: isLead ? color.opacity(0.7) : .clear, radius: isLead ? 12 : 0)
            if markerCap > 0 {
                Circle()
                    .fill(color.opacity(marker.isSuggestion && !isLead ? 0.55 : 1))
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 1))
                    .frame(width: markerCap, height: markerCap)
                    .offset(x: x - markerCap / 2, y: -markerCap / 2)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var phraseStrip: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                ForEach(model.phrases) { span in
                    Capsule()
                        .fill(Self.color(for: span.kind))
                        .frame(width: max(1, CGFloat(span.end - span.start) * width - 2), height: phraseHeight)
                        .offset(x: CGFloat(span.start) * width)
                }
            }
        }
        .frame(height: phraseHeight)
        .accessibilityHidden(true)
    }

    static func color(for kind: SectionKind) -> Color {
        switch kind {
        case .drop: return Color.scAccent
        case .buildup, .build: return Color.scAccent.opacity(0.55)
        case .breakdown, .bridge: return Color.white.opacity(0.35)
        case .intro, .outro: return Color.white.opacity(0.22)
        case .ambientIntro, .ambientOutro, .cooldown: return Color.white.opacity(0.14)
        case .unknown: return Color.white.opacity(0.1)
        }
    }
}

struct TrackMapReadout: View {
    @ObservedObject var model: TrackMapModel
    var hint: String?
    var showsPlayButton = true

    var body: some View {
        HStack(spacing: 12) {
            Text(model.markText)
                .foregroundStyle(model.scrubPreview == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            if model.scrubPreview != nil, showsPlayButton {
                Button(TrackMapCopy.playFromHere) { model.playFromMark() }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            } else if let hint {
                Text(hint)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(model.durationText)
                .foregroundStyle(.secondary)
        }
        .monospacedDigit()
    }
}

struct TrackMapRowLabel: View {
    let row: TrackMapModel.Row

    var body: some View {
        LabeledContent {
            if let time = row.time {
                Text(time)
                    .monospacedDigit()
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .foregroundStyle(row.isMuted ? .secondary : .primary)
                        .lineLimit(1)
                    if let caption = row.caption, !caption.isEmpty {
                        Text(caption)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            } icon: {
                TrackMapGlyphView(glyph: row.glyph)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#if !os(tvOS)
struct TrackMapStandardRow: View {
    @ObservedObject var model: TrackMapModel
    let row: TrackMapModel.Row

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.jump(row)
            } label: {
                TrackMapRowLabel(row: row)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(row.seekSeconds == nil)
            .accessibilityHint(row.seekSeconds == nil ? "" : TrackMapCopy.playsFromHere)

            if let primary = row.primary {
                Button(primary.title, action: primary.perform)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .accessibilityLabel("\(primary.title), \(row.title)")
            }

            if !row.actions.isEmpty {
                Menu {
                    actionButtons
                } label: {
                    Label(TrackMapCopy.options, systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 32, minHeight: 32)
                }
                .menuIndicator(.hidden)
                .buttonStyle(.borderless)
                .fixedSize()
                .accessibilityLabel("\(row.title), \(TrackMapCopy.options)")
            }
        }
        .contextMenu { actionButtons }
        .swipeActions(edge: .trailing) {
            ForEach(row.actions.filter(\.isDestructive)) { action in
                Button(role: .destructive, action: action.perform) {
                    Label(action.title, systemImage: action.systemImage)
                }
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            ForEach(row.actions.filter { !$0.isDestructive }.prefix(1)) { action in
                Button(action: action.perform) {
                    Label(action.title, systemImage: action.systemImage)
                }
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        ForEach(row.actions) { action in
            Button(role: action.isDestructive ? .destructive : nil, action: action.perform) {
                Label(action.title, systemImage: action.systemImage)
            }
        }
    }
}

struct TrackMapPadGrid: View {
    @ObservedObject var model: TrackMapModel
    var columns = 4

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
            ForEach(model.pads) { pad in
                let isSelected = pad.cueId != nil && pad.cueId == model.selectedCueId
                Button(action: pad.perform) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(pad.letter).fontWeight(.bold)
                            Spacer(minLength: 0)
                            if let time = pad.time {
                                Text(time).monospacedDigit()
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(pad.color.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.secondary))
                        Text(pad.title ?? (pad.isSet ? TrackMapCopy.cueKind : "+"))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(pad.isSet ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .tint(pad.color?.color ?? .secondary)
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(pad.color?.color ?? .primary, lineWidth: 2)
                    }
                }
                .accessibilityLabel(pad.accessibilityLabel)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .help(pad.accessibilityLabel)
                .contextMenu {
                    if let cue = model.cue(pad.cueId) {
                        Button(TrackMapCopy.edit, systemImage: "pencil") { model.editingCueId = cue.id }
                        Button(TrackMapCopy.moveTo(model.markText), systemImage: "arrow.right.to.line") { model.move(cue) }
                        Button(TrackMapCopy.delete, systemImage: "trash", role: .destructive) { model.delete(cue) }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
#endif

struct TrackMapSectionHeader: View {
    let title: String

    var body: some View {
        #if os(tvOS)
        Text(title)
            .font(.headline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 24)
            .padding(.bottom, 8)
            .accessibilityAddTraits(.isHeader)
        #else
        Text(title)
        #endif
    }
}

struct TrackMapSections<RowView: View, PadsView: View>: View {
    @ObservedObject var model: TrackMapModel
    var showsMixPoints = true
    var showsPads = true
    var showsAnalysis = true
    @ViewBuilder let row: (TrackMapModel.Row) -> RowView
    @ViewBuilder let pads: () -> PadsView

    var body: some View {
        if showsMixPoints {
            Section {
                ForEach(model.mixRows) { row($0) }
            } header: {
                TrackMapSectionHeader(title: TrackMapCopy.mixPoints)
            }
        }

        if showsPads {
            Section {
                pads()
            } header: {
                TrackMapSectionHeader(title: TrackMapCopy.hotCues)
            }
        }

        Section {
            let rows = model.cueRows
            if rows.isEmpty {
                ContentUnavailableView(
                    TrackMapCopy.emptyTitle,
                    systemImage: "bookmark",
                    description: Text(TrackMapCopy.emptyDescription)
                )
                .frame(maxWidth: .infinity)
            } else {
                ForEach(rows) { row($0) }
            }
        } header: {
            TrackMapSectionHeader(title: TrackMapCopy.cuePoints)
        }

        if showsAnalysis {
            let facts = model.facts
            if !facts.isEmpty {
                Section {
                    ForEach(facts) { fact in
                        LabeledContent(fact.title, value: fact.value)
                            .monospacedDigit()
                    }
                } header: {
                    TrackMapSectionHeader(title: TrackMapCopy.analysis)
                }
            }
        }
    }
}

struct TrackMapCueEditor: View {
    @ObservedObject var model: TrackMapModel
    let cue: CuePoint

    @State private var name = ""

    private var isMix: Bool { cue.kind == .mixIn || cue.kind == .mixOut }

    var body: some View {
        Section {
            if !isMix {
                TextField(TrackMapCopy.name, text: $name)
                    .onSubmit { model.rename(cue, to: name) }
            }
            LabeledContent(TrackMapCopy.position, value: model.preciseTime(cue.positionSeconds))
                .monospacedDigit()
            if !isMix, cue.hotCueIndex != nil || cue.kind == .loop {
                Picker(TrackMapCopy.colour, selection: Binding(get: { cue.color }, set: { model.recolour(cue, to: $0) })) {
                    if !CueColor.hotCuePalette.contains(cue.color) {
                        Text(TrackMapModel.kindTitle(cue)).tag(cue.color)
                    }
                    ForEach(Array(CueColor.hotCuePalette.enumerated()), id: \.offset) { index, color in
                        Label {
                            Text(TrackMapCopy.colourNames[index])
                        } icon: {
                            Image(systemName: "circle.fill").foregroundStyle(color.color)
                        }
                        .tag(color)
                    }
                }
            }
            if !isMix {
                Picker(TrackMapCopy.type, selection: Binding(
                    get: { cue.hotCueIndex ?? -1 },
                    set: { model.assign(cue, toSlot: $0 < 0 ? nil : $0) }
                )) {
                    Text(cue.kind == .loop ? TrackMapCopy.loopKind : TrackMapCopy.cueKind).tag(-1)
                    ForEach(0..<CuePoint.hotCueSlotCount, id: \.self) { slot in
                        if slot == cue.hotCueIndex || !model.takenSlots.contains(slot) {
                            Text(cue.kind == .loop ? TrackMapCopy.hotLoop(slot) : TrackMapCopy.hotCue(slot)).tag(slot)
                        }
                    }
                }
            }
        } header: {
            TrackMapSectionHeader(title: TrackMapModel.title(for: cue))
        }
        .onAppear { name = cue.label }
        .onChange(of: cue.id) { _, _ in name = cue.label }
        .onChange(of: cue.label) { _, label in name = label }
        .onDisappear { model.rename(cue, to: name) }

        Section {
            Button(TrackMapCopy.moveTo(model.markText), systemImage: "arrow.right.to.line") { model.move(cue) }
            Button(isMix ? TrackMapCopy.clear : TrackMapCopy.delete, systemImage: isMix ? "xmark" : "trash", role: .destructive) {
                model.delete(cue)
            }
        }
    }
}

#if DEBUG
@MainActor
enum TrackMapDemo {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["SOUNDING_TV_TRACKMAP_DEMO"] == "1"
    }

    static let trackId = "demo-track"
    static let duration: TimeInterval = 214

    static func makeModel() -> TrackMapModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrackMapDemo-\(UUID().uuidString)", isDirectory: true)
        let model = TrackMapModel(board: CueBoard(store: CueStore(directory: directory)))
        model.livePosition = { 164 }
        return model
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

    static func seed(_ model: TrackMapModel) async {
        let board = model.board
        let store = board.store
        model.load(trackId: trackId, title: "Sunset Drive (Extended Mix)", duration: duration, envelope: envelope())
        try? await Task.sleep(for: .milliseconds(500))
        await board.setMixIn(trackId: trackId, positionMillis: 18_000)
        await board.addMemoryCue(trackId: trackId, positionMillis: 108_000, label: "Vocal comes back")
        await board.setHotCue(trackId: trackId, index: 0, positionMillis: 96_000, label: "Drop")
        for suggestion in board.sheet.suggestions where suggestion.kind == .memory {
            await board.dismiss(suggestion)
        }
        await store.setHotLoop(trackId: trackId, index: 2, startMillis: 132_000, endMillis: 139_500, label: "Roll")
        for session in ["s1", "s1", "s2"] {
            await store.recordListening(trackId: trackId, positionMillis: 162_000, sessionId: session)
        }
        await board.refresh()
    }
}
#endif
