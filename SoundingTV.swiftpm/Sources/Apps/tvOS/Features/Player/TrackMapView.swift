import SwiftUI

struct TrackMapView: View {
    let track: Track?
    @ObservedObject var board: CueBoard
    let currentTime: TimeInterval
    let duration: TimeInterval
    let envelope: [Float]
    let palette: ArtworkColors.Palette
    let onSeek: (TimeInterval) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @FocusState private var timelineFocused: Bool
    @FocusState private var focusedRowId: String?
    @State private var highlightedId: String?
    @State private var scrubPreview: TimeInterval?
    @State private var scrubClearTask: Task<Void, Never>?
    @State private var panAnchor: TimeInterval?
    @State private var isPanning = false
    @State private var suppressMoves = false
    @State private var moveCooldownTask: Task<Void, Never>?
    @State private var renamingCue: CuePoint?
    @State private var renameText = ""

    private static let laneHeight: CGFloat = 120
    private static let scrubStep: TimeInterval = 2

    var body: some View {
        VStack(alignment: .leading, spacing: Space.base) {
            header
            timeline
            mapList
            footer
        }
        .padding(.horizontal, Space.page)
        .padding(.vertical, Space.roomy)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.scBackground.ignoresSafeArea())
        .task {
            try? await Task.sleep(for: .milliseconds(80))
            guard focusedRowId == nil else { return }
            focusedRowId = defaultRowId
        }
        .onChange(of: focusedRowId) { _, new in
            if let new { highlightedId = new }
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

    private var renamingBinding: Binding<Bool> {
        Binding(get: { renamingCue != nil }, set: { if !$0 { renamingCue = nil } })
    }

    private var markTime: TimeInterval { scrubPreview ?? currentTime }

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, markTime / duration))
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: Space.tight) {
                Eyebrow(text: "Cue Points")
                Text(track?.title ?? "Nothing Playing")
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
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .topLeading) {
                    SCWaveformRenderer(
                        envelope: envelope,
                        duration: duration,
                        progress: progress,
                        placeholder: .unavailable,
                        identity: track?.id,
                        motionSuppressed: reduceMotion,
                        style: laneStyle
                    )
                    .frame(width: width, height: Self.laneHeight)

                    markerOverlay(width: width)
                }
                .frame(width: width, height: Self.laneHeight)
            }
            .frame(height: Self.laneHeight)
            .contentShape(RoundedRectangle(cornerRadius: Corner.control, style: .continuous))
            .focusable()
            .focused($timelineFocused)
            .focusEffectDisabled()
            .scFocus(timelineFocused, cornerRadius: Corner.control, reduceMotion: reduceMotion, sizeClass: .hero)
            .background(
                RemoteScrubSurface(
                    isActive: timelineFocused && duration > 0,
                    capturesExit: false,
                    onBegan: beginPan,
                    onChanged: { scrubPreview = panTime(for: $0) },
                    onEnded: endPan,
                    onCancelled: cancelPan,
                    onExit: {}
                )
                .allowsHitTesting(false)
            )
            .onMoveCommand { direction in
                guard !suppressMoves else { return }
                switch direction {
                case .left:  scrub(by: -Self.scrubStep)
                case .right: scrub(by: Self.scrubStep)
                default: break
                }
            }
            .onTapGesture(perform: commitSeek)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Track timeline")
            .accessibilityValue("\(DJFormat.time(markTime)) of \(DJFormat.time(duration))")
            .accessibilityHint("Slide to move along the track, then click to seek.")
            .accessibilityAdjustableAction { direction in
                let step = max(5, duration / 50)
                let base = scrubPreview ?? currentTime
                switch direction {
                case .increment: scrubPreview = min(max(duration, 0), base + step)
                case .decrement: scrubPreview = max(0, base - step)
                @unknown default: return
                }
                scheduleMarkClear()
            }

            readout
        }
    }

    private var readout: some View {
        HStack(spacing: Space.snug) {
            Text(DJFormat.time(markTime))
                .foregroundStyle(scrubPreview == nil ? Color.scTextSecondary : .white)

            if isPanning {
                Text(RemoteScrub.delta(markTime - currentTime))
                    .foregroundStyle(Color.scTextSecondary)
            } else if scrubPreview != nil {
                Text("Click to seek here")
                    .foregroundStyle(Color.scTextSecondary)
            } else if timelineFocused {
                Text("Slide to move, click to seek")
                    .foregroundStyle(Color.scTextTertiary)
            }

            Spacer(minLength: 0)

            Text(DJFormat.time(duration))
                .foregroundStyle(Color.scTextTertiary)
        }
        .font(.tvCalloutEmph)
        .monospacedDigit()
    }

    @ViewBuilder
    private func markerOverlay(width: CGFloat) -> some View {
        ForEach(board.sheet.entries) { entry in
            let isLead = entry.id == highlightedId
            let x = CGFloat(duration > 0 ? min(1, max(0, entry.positionSeconds / duration)) : 0) * width
            Capsule()
                .fill(entry.color.color.opacity(entry.isSuggestion && !isLead ? 0.45 : 0.95))
                .frame(width: isLead ? 6 : 3, height: isLead ? Self.laneHeight : 26)
                .offset(x: x - (isLead ? 3 : 1.5))
                .shadow(color: isLead ? entry.color.color.opacity(0.7) : .clear, radius: isLead ? 12 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .scMotion(Motion.focus, reduceMotion: reduceMotion, value: highlightedId)
    }

    private var laneStyle: SCWaveformStyle {
        var style = SCWaveformStyle.tv
        style.playheadHaloColor = palette.accent
        return style
    }

    private func scrub(by delta: TimeInterval) {
        let base = scrubPreview ?? currentTime
        scrubPreview = min(max(0, base + delta), max(duration, 0))
        scheduleMarkClear()
    }

    private func panTime(for translation: CGFloat) -> TimeInterval {
        RemoteScrub.time(from: panAnchor ?? currentTime, translation: translation, duration: duration)
    }

    private func beginPan() {
        scrubClearTask?.cancel()
        moveCooldownTask?.cancel()
        panAnchor = scrubPreview ?? currentTime
        isPanning = true
        suppressMoves = true
    }

    private func endPan(_ translation: CGFloat) {
        scrubPreview = panTime(for: translation)
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
            scrubPreview = nil
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
        guard let target = scrubPreview else { return }
        onSeek(target)
        scrubPreview = nil
        scrubClearTask?.cancel()
    }

    private var mapList: some View {
        VStack(spacing: Spacing.sm) {
            mixPointRow(.inPoint)

            ScrollView {
                LazyVStack(spacing: Spacing.sm) {
                    if moments.isEmpty {
                        emptyMoments
                    } else {
                        ForEach(moments) { entry in
                            switch entry {
                            case .moment(let cue):   momentRow(cue)
                            case .suggestion(let s): suggestionRow(s)
                            }
                        }
                    }
                }
                .padding(.vertical, Space.hair)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            mixPointRow(.outPoint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusSection()
    }

    private var defaultRowId: String? {
        moments.first?.id ?? MixRole.inPoint.rowId
    }

    private var emptyMoments: some View {
        VStack(alignment: .leading, spacing: Space.hair) {
            Text("Nothing marked in this track yet")
                .font(.tvBodyEmph)
                .foregroundStyle(Color.scTextSecondary)
            Text("Move along the timeline above, then save the moment.")
                .font(.tvCaption)
                .foregroundStyle(Color.scTextTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.snug)
        .accessibilityElement(children: .combine)
    }

    private var moments: [MapEntry] {
        board.sheet.entries.compactMap { entry in
            guard entry.kind != .mixIn, entry.kind != .mixOut else { return nil }
            if let cue = entry.userCue { return .moment(cue) }
            if let suggestion = entry.suggestion { return .suggestion(suggestion) }
            return nil
        }
    }

    @ViewBuilder
    private func mixPointRow(_ role: MixRole) -> some View {
        let state = mixState(role)

        TrackMapRow(
            glyph: TrackMapGlyph(shape: .diamond, style: state.glyphStyle, color: role.color),
            title: role.title,
            caption: caption(for: state, role: role),
            time: state.positionSeconds.map(DJFormat.time),
            isMuted: state.isMuted,
            rowId: role.rowId,
            focusedRowId: $focusedRowId,
            reduceMotion: reduceMotion,
            onSelect: state.positionSeconds.map { seconds in { jump(to: seconds) } }
        ) {
            switch state {
            case .set(let cue):
                UtilityActionButton(icon: "arrow.down.to.line", accessibilityLabel: "Move \(role.title) to \(DJFormat.time(markTime))") {
                    setMixPoint(role)
                }
                UtilityActionButton(icon: "xmark", accessibilityLabel: "Clear \(role.title)") {
                    Task { await board.delete(cue) }
                }
            case .suggested(let suggestion):
                UtilityActionButton(icon: "plus", accessibilityLabel: "Keep suggested \(role.title)") {
                    Task { await board.promote(suggestion) }
                }
                UtilityActionButton(icon: "arrow.down.to.line", accessibilityLabel: "Set \(role.title) to \(DJFormat.time(markTime))") {
                    setMixPoint(role)
                }
            case .unset:
                UtilityActionButton(icon: "arrow.down.to.line", accessibilityLabel: "Set \(role.title) to \(DJFormat.time(markTime))") {
                    setMixPoint(role)
                }
            }
        }
    }

    private func momentRow(_ cue: CuePoint) -> some View {
        TrackMapRow(
            glyph: TrackMapGlyph(shape: .circle, style: .solid, color: cue.color.color),
            title: cue.label.isEmpty ? "Moment" : cue.label,
            caption: momentCaption(cue),
            time: DJFormat.time(cue.positionSeconds),
            isMuted: false,
            rowId: cue.id,
            focusedRowId: $focusedRowId,
            reduceMotion: reduceMotion,
            onSelect: { jump(to: cue.positionSeconds) }
        ) {
            UtilityActionButton(icon: "pencil", accessibilityLabel: "Rename") {
                renameText = cue.label
                renamingCue = cue
            }
            DestructiveActionButton(accessibilityLabel: "Delete moment") {
                Task { await board.delete(cue) }
            }
        }
    }

    private func suggestionRow(_ suggestion: CueSuggestion) -> some View {
        TrackMapRow(
            glyph: TrackMapGlyph(shape: .circle, style: .hollow, color: suggestion.color.color),
            title: suggestion.label.isEmpty ? suggestion.kind.displayName.capitalized : suggestion.label,
            caption: suggestion.reasoning.isEmpty ? "Found automatically" : suggestion.reasoning,
            time: DJFormat.time(suggestion.positionSeconds),
            isMuted: true,
            rowId: suggestion.id,
            focusedRowId: $focusedRowId,
            reduceMotion: reduceMotion,
            onSelect: { jump(to: suggestion.positionSeconds) }
        ) {
            UtilityActionButton(icon: "plus", accessibilityLabel: "Keep this moment") {
                Task { await board.promote(suggestion) }
            }
            UtilityActionButton(icon: "xmark", accessibilityLabel: "Hide this suggestion") {
                Task { await board.dismiss(suggestion) }
            }
        }
    }

    private var footer: some View {
        TrackMapPrimaryButton(
            icon: "plus.circle.fill",
            title: "Save This Moment",
            detail: DJFormat.time(markTime),
            accent: palette.accent,
            reduceMotion: reduceMotion
        ) {
            guard let track else { return }
            Task {
                await board.addMemoryCue(
                    trackId: track.id,
                    positionMillis: CueTime.millis(fromSeconds: markTime)
                )
            }
        }
        .disabled(track == nil)
        .focusSection()
    }

    private func jump(to seconds: TimeInterval) {
        onSeek(seconds)
        dismiss()
    }

    private func setMixPoint(_ role: MixRole) {
        guard let track else { return }
        let millis = CueTime.millis(fromSeconds: markTime)
        Task {
            switch role {
            case .inPoint:  await board.setMixIn(trackId: track.id, positionMillis: millis)
            case .outPoint: await board.setMixOut(trackId: track.id, positionMillis: millis)
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

// MARK: - Model

private enum MixRole: Equatable {
    case inPoint
    case outPoint

    var title: String { self == .inPoint ? "Mix In" : "Mix Out" }
    var rowId: String { self == .inPoint ? "trackmap.mixin" : "trackmap.mixout" }
    var color: Color { (self == .inPoint ? CueColor.mixIn : CueColor.mixOut).color }

    var setCaption: String {
        self == .inPoint ? "The DJ starts this track here" : "The DJ leaves this track here"
    }

    var unsetCaption: String {
        self == .inPoint
            ? "Not set, the DJ picks where to come in"
            : "Not set, the DJ picks where to leave"
    }
}

private enum MixState {
    case set(CuePoint)
    case suggested(CueSuggestion)
    case unset

    var positionSeconds: TimeInterval? {
        switch self {
        case .set(let cue):             return cue.positionSeconds
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
        case .moment(let cue):           return cue.id
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

    private var side: CGFloat { shape == .diamond ? 20 : 18 }

    var body: some View {
        Group {
            switch style {
            case .solid:
                base.fill(color)
            case .hollow:
                base.strokeBorder(color.opacity(0.85), lineWidth: 3)
            case .dashed:
                base.strokeBorder(
                    color.opacity(0.55),
                    style: StrokeStyle(lineWidth: 3, dash: [4, 4])
                )
            }
        }
        .frame(width: side, height: side)
        .rotationEffect(.degrees(shape == .diamond ? 45 : 0))
        .frame(width: 44)
    }

    private var base: some InsettableShape {
        RoundedRectangle(cornerRadius: shape == .diamond ? 4 : side / 2, style: .continuous)
    }
}

private struct TrackMapRow<Actions: View>: View {
    let glyph: TrackMapGlyph
    let title: String
    let caption: String
    let time: String?
    let isMuted: Bool
    let rowId: String
    @FocusState.Binding var focusedRowId: String?
    let reduceMotion: Bool
    let onSelect: (() -> Void)?
    @ViewBuilder let actions: () -> Actions

    private var isFocused: Bool { focusedRowId == rowId }

    private var primaryColor: Color {
        if isFocused { return Color.scChromeFocusOn }
        return isMuted ? Color.scTextSecondary : .white
    }

    var body: some View {
        HStack(spacing: Space.snug) {
            Button { onSelect?() } label: {
                HStack(spacing: Space.snug) {
                    glyph

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.tvBodyEmph)
                            .foregroundStyle(primaryColor)
                            .lineLimit(1)

                        Text(caption)
                            .font(.tvCaption)
                            .foregroundStyle(isFocused ? Color.scChromeFocusOn.opacity(0.65) : Color.scTextTertiary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: Space.snug)

                    if let time {
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
            .disabled(onSelect == nil)
            .focused($focusedRowId, equals: rowId)

            actions()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        [title, time, caption].compactMap { $0 }.joined(separator: ", ")
    }
}

private struct DestructiveActionButton: View {
    let accessibilityLabel: String
    let action: () -> Void

    @State private var confirming = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        UtilityActionButton(
            icon: confirming ? "exclamationmark.triangle.fill" : "trash.fill",
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
    let reduceMotion: Bool
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
            .background(
                Capsule().fill(focused ? Color.scChromeFocus : Color.white.opacity(0.08))
            )
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
        }
        .buttonStyle(SCShapeButtonStyle(shape: Capsule(), sizeClass: .hero))
        .focused($focused)
        .accessibilityLabel("\(title) at \(detail)")
    }
}

#if DEBUG

enum TrackMapDemo {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["SOUNDING_TV_TRACKMAP_DEMO"] == "1"
    }

    static let duration: TimeInterval = 214

    static func makeStore() -> CueStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TrackMapDemo-\(UUID().uuidString)", isDirectory: true)
        return CueStore(directory: directory)
    }

    static func track() -> Track? {
        let json = """
        {"id": 900001, "title": "Sunset Drive (Extended Mix)",
         "permalink_url": "https://soundcloud.com/glassdistrict/sunset-drive",
         "created_at": "2025-06-01T09:00:00Z",
         "artwork_url": null,
         "playback_count": 128000, "likes_count": 9400, "reposts_count": 310,
         "genre": "Melodic House",
         "user": {"id": 700, "username": "glassdistrict", "permalink": "glassdistrict",
                  "permalink_url": "https://soundcloud.com/glassdistrict",
                  "avatar_url": null,
                  "full_name": "Glass District", "track_count": 42, "playlist_count": 3,
                  "followers_count": 88000, "followings_count": 120}}
        """
        let decoder = JSONDecoder()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        decoder.dateDecodingStrategy = .formatted(formatter)
        guard let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(Track.self, from: data)
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

struct TrackMapDemoView: View {
    @StateObject private var board = CueBoard(store: TrackMapDemo.makeStore())
    @State private var seeded = false

    private let track = TrackMapDemo.track()
    private let envelope = TrackMapDemo.envelope()

    var body: some View {
        TrackMapView(
            track: track,
            board: board,
            currentTime: 164,
            duration: TrackMapDemo.duration,
            envelope: envelope,
            palette: ArtworkColors.shared.current,
            onSeek: { _ in }
        )
        .task {
            guard !seeded, let track else { return }
            seeded = true
            board.ensureLoaded(
                trackId: track.id,
                duration: TrackMapDemo.duration,
                waveform: Waveform(samples: envelope)
            )
            try? await Task.sleep(for: .milliseconds(500))
            await board.setMixIn(trackId: track.id, positionMillis: 18_000)
            await board.addMemoryCue(trackId: track.id, positionMillis: 108_000, label: "Vocal comes back")
        }
    }
}

#endif
