import SwiftUI

struct TrackMapView: View {
    @ObservedObject var model: TrackMapModel
    let palette: ArtworkColors.Palette

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

    private static let laneHeight: CGFloat = 120
    private static let scrubStep: TimeInterval = 2

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: Space.base) {
                header
                timeline
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.sm) {
                        TrackMapSections(model: model) { row in
                            TVTrackMapRow(model: model, row: row, focusedRowId: $focusedRowId, reduceMotion: reduceMotion)
                        } pads: {
                            TVTrackMapPads(model: model)
                        }
                    }
                    .padding(.vertical, Space.hair)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .focusSection()
                footer
            }
        }
        .padding(.horizontal, Space.page)
        .padding(.vertical, Space.roomy)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.scBackground.ignoresSafeArea())
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
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Space.tight) {
                Eyebrow(text: TrackMapCopy.title)
                Text(model.trackTitle.isEmpty ? TrackMapCopy.nothingPlaying : model.trackTitle)
                    .font(.tvTitle)
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Space.base)
            PanelCloseButton { dismiss() }
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            TrackMapLane(model: model, height: Self.laneHeight, style: laneStyle, highlightedId: highlightedId)
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
            .font(.tvCalloutEmph)
        }
    }

    private var laneStyle: SCWaveformStyle {
        var style = SCWaveformStyle.tv
        style.playheadHaloColor = palette.accent
        return style
    }

    private var footer: some View {
        HStack(spacing: Space.snug) {
            TrackMapPrimaryButton(
                icon: "plus.circle.fill",
                title: TrackMapCopy.saveCuePoint,
                detail: model.markText,
                accent: palette.accent
            ) {
                model.saveCue()
            }
            UtilityActionButton(icon: "repeat", label: TrackMapCopy.addLoop) { model.addLoop() }
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
    let reduceMotion: Bool

    private var isFocused: Bool { focusedRowId == row.id }

    private var primaryColor: Color {
        if isFocused { return Color.scChromeFocusOn }
        return row.isMuted ? Color.scTextSecondary : .white
    }

    var body: some View {
        HStack(spacing: Space.snug) {
            Button { model.jump(row) } label: {
                HStack(spacing: Space.snug) {
                    TrackMapGlyphView(glyph: row.glyph)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                            .font(.tvBodyEmph)
                            .foregroundStyle(primaryColor)
                            .lineLimit(1)
                        if let caption = row.caption {
                            Text(caption)
                                .font(.tvCaption)
                                .foregroundStyle(isFocused ? Color.scChromeFocusOn.opacity(0.65) : Color.scTextTertiary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: Space.snug)

                    if let time = row.time {
                        Text(time)
                            .font(.tvBodyEmph)
                            .monospacedDigit()
                            .foregroundStyle(primaryColor)
                    }
                }
                .padding(.horizontal, Space.snug)
                .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Corner.control, style: .continuous)
                        .fill(isFocused ? Color.scChromeFocus : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: Corner.control, style: .continuous))
            }
            .buttonStyle(SCCardButtonStyle(cornerRadius: Corner.control, sizeClass: .hero))
            .disabled(row.seekSeconds == nil)
            .focused($focusedRowId, equals: row.id)
            .accessibilityLabel(row.accessibilityLabel)
            .accessibilityHint(row.seekSeconds == nil ? "" : TrackMapCopy.playsFromHere)

            ForEach(row.actions) { action in
                if action.isDestructive {
                    DestructiveActionButton(icon: action.systemImage, accessibilityLabel: action.title, action: action.perform)
                } else {
                    UtilityActionButton(icon: action.systemImage, accessibilityLabel: action.title, action: action.perform)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct TVTrackMapPads: View {
    @ObservedObject var model: TrackMapModel

    var body: some View {
        HStack(spacing: Spacing.sm) {
            ForEach(model.pads) { pad in
                TVTrackMapPad(pad: pad)
            }
        }
        .focusSection()
    }
}

private struct TVTrackMapPad: View {
    let pad: TrackMapModel.Pad

    @FocusState private var focused: Bool

    var body: some View {
        Button(action: pad.perform) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(pad.letter).fontWeight(.bold)
                    Spacer(minLength: 0)
                    if let time = pad.time { Text(time).monospacedDigit() }
                }
                .font(.tvCaption)
                .foregroundStyle(focused ? Color.scChromeFocusOn : (pad.color?.color ?? Color.scTextTertiary))
                Text(pad.title ?? (pad.isSet ? TrackMapCopy.cueKind : "+"))
                    .font(.tvBodyEmph)
                    .foregroundStyle(focused ? Color.scChromeFocusOn : (pad.isSet ? .white : Color.scTextSecondary))
                    .lineLimit(1)
            }
            .padding(.horizontal, Space.snug)
            .padding(.vertical, Space.tight)
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Corner.control, style: .continuous)
                    .fill(focused ? Color.scChromeFocus : (pad.color?.color ?? .white).opacity(0.12))
            )
            .contentShape(RoundedRectangle(cornerRadius: Corner.control, style: .continuous))
        }
        .buttonStyle(SCCardButtonStyle(cornerRadius: Corner.control, sizeClass: .card))
        .focused($focused)
        .accessibilityLabel(pad.accessibilityLabel)
    }
}

private struct DestructiveActionButton: View {
    let icon: String
    let accessibilityLabel: String
    let action: () -> Void

    @State private var confirming = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        UtilityActionButton(
            icon: confirming ? "exclamationmark.triangle.fill" : icon,
            accessibilityLabel: confirming ? "Click again to confirm" : accessibilityLabel
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

private struct TrackMapPrimaryButton: View {
    let icon: String
    let title: String
    let detail: String
    let accent: Color
    let action: () -> Void

    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.snug) {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(focused ? Color.scChromeFocusOn : .white)
                Text(title)
                    .font(.tvBodyEmph)
                    .foregroundStyle(focused ? Color.scChromeFocusOn : .white)
                Spacer(minLength: Space.snug)
                Text(detail)
                    .font(.tvBodyEmph)
                    .monospacedDigit()
                    .foregroundStyle(focused ? Color.scChromeFocusOn.opacity(0.7) : Color.scTextSecondary)
            }
            .padding(.horizontal, Space.base)
            .frame(maxWidth: .infinity, minHeight: Control.circle + Space.tight)
            .background(Capsule().fill(focused ? Color.scChromeFocus : Color.white.opacity(0.08)))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
        }
        .buttonStyle(SCShapeButtonStyle(shape: Capsule(), sizeClass: .hero))
        .focused($focused)
        .accessibilityLabel(TrackMapCopy.save(at: detail))
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
