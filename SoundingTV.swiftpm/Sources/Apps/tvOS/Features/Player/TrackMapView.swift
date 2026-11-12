import SwiftUI

struct TrackMapView: View {
    @ObservedObject var model: TrackMapModel
    let palette: ArtworkColors.Palette
    var artworkURL: URL?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @FocusState private var timelineFocused: Bool
    @FocusState private var focusedRowId: String?
    @State private var highlightedId: String?
    @State private var scrubClearTask: Task<Void, Never>?
    @State private var panAnchor: TimeInterval?
    @State private var isPanning = false
    @State private var suppressMoves = false
    @State private var moveCooldownTask: Task<Void, Never>?

    private static let laneHeight: CGFloat = 150
    private static let contentTop: CGFloat = 96
    private static let scrubStep: TimeInterval = 2

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: Space.roomy) {
                header
                timeline
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Space.snug) {
                        TrackMapSections(model: model) { row in
                            TVTrackMapRow(model: model, row: row, focusedRowId: $focusedRowId)
                        } pads: {
                            TVTrackMapPads(model: model)
                        }
                    }
                    .padding(.top, Space.hair)
                    .padding(.bottom, Space.section)
                }
                .scrollClipDisabled()
                .scrollIndicators(.hidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .focusSection()
                footer
            }
        }
        .padding(.top, Self.contentTop)
        .padding(.horizontal, Space.page)
        .padding(.bottom, Space.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .background { NPCoverBackdrop(artworkURL: artworkURL, palette: palette) }
        .environment(\.colorScheme, .dark)
        .task {
            try? await Task.sleep(for: .milliseconds(80))
            guard focusedRowId == nil else { return }
            focusedRowId = model.cueRows.first?.id ?? TrackMapModel.MixRole.mixIn.rowId
        }
        .onChange(of: focusedRowId) { _, new in
            guard let new else { return }
            if let mix = model.mixRows.first(where: { $0.id == new }) {
                highlightedId = mix.cueId
            } else {
                highlightedId = new
            }
        }
        .onChange(of: model.jumpCount) { _, _ in dismiss() }
        .sheet(item: editingBinding) { item in
            if let cue = model.cue(item.id) {
                NavigationStack {
                    Form {
                        TrackMapCueEditor(model: model, cue: cue)
                    }
                    .navigationTitle(TrackMapCopy.editTitle)
                }
            }
        }
    }

    private struct EditingItem: Identifiable {
        let id: String
    }

    private var editingBinding: Binding<EditingItem?> {
        Binding(
            get: { model.editingCueId.map(EditingItem.init) },
            set: { model.editingCueId = $0?.id }
        )
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.base) {
            VStack(alignment: .leading, spacing: Space.hair) {
                Text(model.trackTitle.isEmpty ? TrackMapCopy.nothingPlaying : model.trackTitle)
                    .font(.callout)
                    .foregroundStyle(Color.white.opacity(0.66))
                    .lineLimit(1)
                Text(TrackMapCopy.title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("trackMap.header")
            Spacer(minLength: Space.base)
            if model.cueCount > 0 {
                Text(TrackMapCopy.count(model.cueCount))
                    .font(.callout)
                    .foregroundStyle(Color.white.opacity(0.66))
                    .lineLimit(1)
            }
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            TrackMapLane(model: model, height: Self.laneHeight, style: laneStyle, highlightedId: highlightedId)
                .padding(.top, Space.tight)
                .contentShape(RoundedRectangle(cornerRadius: Corner.control, style: .continuous))
                .focusable()
                .focused($timelineFocused)
                .focusEffectDisabled()
                .scFocus(timelineFocused, cornerRadius: Corner.control, reduceMotion: reduceMotion, sizeClass: .hero)
                .background(
                    RemoteScrubSurface(
                        isActive: timelineFocused && model.duration > 0,
                        capturesExit: false,
                        onBegan: beginPan,
                        onChanged: { model.preview(panTime(for: $0)) },
                        onEnded: endPan,
                        onCancelled: cancelPan,
                        onExit: {}
                    )
                    .allowsHitTesting(false)
                )
                .onMoveCommand { direction in
                    guard !suppressMoves else { return }
                    switch direction {
                    case .left: scrub(by: -Self.scrubStep)
                    case .right: scrub(by: Self.scrubStep)
                    default: break
                    }
                }
                .onTapGesture(perform: commitSeek)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(TrackMapCopy.timeline)
                .accessibilityValue(TrackMapCopy.timelineValue(model.markText, of: model.durationText))
                .accessibilityHint(TrackMapCopy.remoteHint)
                .accessibilityAdjustableAction { direction in
                    let step = max(5, model.duration / 50)
                    model.nudgePreview(by: direction == .increment ? step : -step)
                    scheduleMarkClear()
                }

            TrackMapReadout(
                model: model,
                hint: isPanning ? RemoteScrub.delta(model.markTime - model.livePosition()) : (timelineFocused || model.scrubPreview != nil ? TrackMapCopy.remoteHint : nil),
                showsPlayButton: false
            )
            .font(.callout)
        }
    }

    private var laneStyle: SCWaveformStyle {
        var style = SCWaveformStyle.tv
        style.playheadHaloColor = palette.accent
        return style
    }

    private var footer: some View {
        HStack(spacing: Space.snug) {
            TVCuePill(
                icon: "plus",
                title: TrackMapCopy.saveCuePoint,
                detail: model.markText,
                isProminent: true,
                accessibilityLabel: TrackMapCopy.save(at: model.markText)
            ) {
                model.saveCue()
            }
            TVCuePill(icon: "repeat", title: TrackMapCopy.addLoop) { model.addLoop() }
        }
        .disabled(model.trackId == nil)
        .focusSection()
    }

    private func scrub(by delta: TimeInterval) {
        model.nudgePreview(by: delta)
        scheduleMarkClear()
    }

    private func panTime(for translation: CGFloat) -> TimeInterval {
        RemoteScrub.time(from: panAnchor ?? model.livePosition(), translation: translation, duration: model.duration)
    }

    private func beginPan() {
        scrubClearTask?.cancel()
        moveCooldownTask?.cancel()
        panAnchor = model.markTime
        isPanning = true
        suppressMoves = true
    }

    private func endPan(_ translation: CGFloat) {
        model.preview(panTime(for: translation))
        panAnchor = nil
        isPanning = false
        scheduleMarkClear()
        releaseMoveSuppression()
    }

    private func cancelPan() {
        panAnchor = nil
        isPanning = false
        scheduleMarkClear()
        releaseMoveSuppression()
    }

    private func scheduleMarkClear() {
        scrubClearTask?.cancel()
        scrubClearTask = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            model.scrubPreview = nil
        }
    }

    private func releaseMoveSuppression() {
        moveCooldownTask?.cancel()
        moveCooldownTask = Task {
            try? await Task.sleep(for: RemoteScrub.moveCooldown)
            guard !Task.isCancelled else { return }
            suppressMoves = false
        }
    }

    private func commitSeek() {
        guard model.scrubPreview != nil else { return }
        scrubClearTask?.cancel()
        model.playFromMark()
    }
}

// MARK: - Components

private struct TVTrackMapRow: View {
    @ObservedObject var model: TrackMapModel
    let row: TrackMapModel.Row
    @FocusState.Binding var focusedRowId: String?

    var body: some View {
        HStack(alignment: .center, spacing: Space.snug) {
            Button { model.jump(row) } label: {
                HStack(alignment: .center, spacing: Space.base) {
                    TrackMapGlyphView(glyph: row.glyph)
                    VStack(alignment: .leading, spacing: Space.hair) {
                        Text(row.title)
                            .font(.headline)
                            .npInk(row.isMuted ? .secondary : .primary)
                            .lineLimit(1)
                        if let caption = row.caption, !caption.isEmpty {
                            Text(caption)
                                .font(.body)
                                .npInk(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: Space.base)
                    if let time = row.time {
                        Text(time)
                            .font(.headline)
                            .monospacedDigit()
                            .npInk(row.isMuted ? .secondary : .primary)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, Space.snug)
                .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
            }
            .buttonStyle(NPRowStyle(corner: Corner.card, scale: 1.02))
            .disabled(row.seekSeconds == nil)
            .focused($focusedRowId, equals: row.id)
            .accessibilityLabel(row.accessibilityLabel)
            .accessibilityHint(row.seekSeconds == nil ? "" : TrackMapCopy.playsFromHere)

            ForEach(row.actions) { action in
                if action.isDestructive {
                    TVConfirmingPill(icon: action.systemImage, title: action.title, action: action.perform)
                } else {
                    TVCuePill(icon: action.systemImage, title: action.title, action: action.perform)
                }
            }
        }
        .padding(.leading, -22)
        .accessibilityElement(children: .contain)
    }
}

private struct TVTrackMapPads: View {
    @ObservedObject var model: TrackMapModel

    var body: some View {
        HStack(spacing: Space.snug) {
            ForEach(model.pads) { pad in
                TVTrackMapPad(pad: pad, markText: model.markText)
            }
        }
        .padding(.vertical, Space.tight)
        .focusSection()
    }
}

private struct TVTrackMapPad: View {
    let pad: TrackMapModel.Pad
    let markText: String

    @FocusState private var focused: Bool

    private var tint: Color { pad.color?.color ?? .white }

    var body: some View {
        Button(action: pad.perform) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    Text(pad.letter)
                        .font(.callout.weight(.bold))
                        .foregroundStyle(letterColor)
                    Spacer(minLength: 0)
                    if pad.isSet {
                        Circle()
                            .fill(tint)
                            .frame(width: 18, height: 18)
                            .offset(y: 2)
                    }
                }
                Spacer(minLength: Space.tight)
                if pad.isSet {
                    if let title = pad.title {
                        Text(title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(focused ? Color.scChromeFocusOn : .white)
                            .lineLimit(1)
                    }
                    Text(pad.time ?? "")
                        .font(pad.title == nil ? .headline : .callout)
                        .monospacedDigit()
                        .foregroundStyle(focused ? Color.scChromeFocusOn.opacity(0.7) : Color.white.opacity(pad.title == nil ? 1 : 0.66))
                        .lineLimit(1)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: Space.tight) {
                        Image(systemName: "plus")
                            .font(.system(size: 30, weight: .semibold))
                        Text(focused ? markText : "")
                            .font(.callout)
                            .monospacedDigit()
                    }
                    .foregroundStyle(focused ? Color.scChromeFocusOn : Color.white.opacity(0.5))
                }
            }
            .padding(Space.base)
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: Corner.card, style: .continuous)
                    .fill(fill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Corner.card, style: .continuous)
                    .strokeBorder(focused ? Color.clear : tint.opacity(pad.isSet ? 0.4 : 0.1), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: Corner.card, style: .continuous))
        }
        .buttonStyle(SCCardButtonStyle(cornerRadius: Corner.card, sizeClass: .card))
        .focused($focused)
        .accessibilityLabel(pad.accessibilityLabel)
    }

    private var fill: Color {
        if focused { return Color.scChromeFocus }
        return pad.isSet ? tint.opacity(0.22) : Color.white.opacity(0.14)
    }

    private var letterColor: Color {
        if pad.isSet { return focused ? Color.scChromeFocusOn : tint }
        return focused ? Color.scChromeFocusOn.opacity(0.7) : Color.white.opacity(0.5)
    }
}

private struct TVCuePill: View {
    let icon: String
    let title: String
    var detail: String? = nil
    var isProminent = false
    var accessibilityLabel: String? = nil
    let action: () -> Void

    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.snug) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .semibold))
                Text(title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                if let detail {
                    Spacer(minLength: Space.base)
                    Text(detail)
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                        .opacity(0.7)
                }
            }
            .foregroundStyle(focused ? Color.scChromeFocusOn : .white)
            .padding(.horizontal, Space.base)
            .frame(maxWidth: isProminent ? .infinity : nil, minHeight: 72)
            .background(Capsule().fill(focused ? Color.scChromeFocus : Color.white.opacity(0.14)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(focused ? 0 : 0.1), lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
        }
        .buttonStyle(SCShapeButtonStyle(shape: Capsule(), sizeClass: isProminent ? .hero : .card))
        .focused($focused)
        .accessibilityLabel(accessibilityLabel ?? title)
    }
}

private struct TVConfirmingPill: View {
    let icon: String
    let title: String
    let action: () -> Void

    @State private var confirming = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        TVCuePill(
            icon: confirming ? "exclamationmark.triangle.fill" : icon,
            title: confirming ? TrackMapCopy.clickAgain : title,
            accessibilityLabel: confirming ? "\(TrackMapCopy.clickAgain), \(title)" : title
        ) {
            if confirming {
                resetTask?.cancel()
                confirming = false
                action()
            } else {
                confirming = true
                resetTask?.cancel()
                resetTask = Task {
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    confirming = false
                }
            }
        }
    }
}

#if DEBUG
struct TrackMapDemoView: View {
    @StateObject private var model = TrackMapDemo.makeModel()

    var body: some View {
        TrackMapView(model: model, palette: ArtworkColors.shared.current)
            .task { await TrackMapDemo.seed(model) }
    }
}
#endif
