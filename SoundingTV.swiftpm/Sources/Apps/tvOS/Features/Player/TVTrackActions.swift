import SwiftUI
import UIKit

extension EnvironmentValues {
    @Entry var presentTrackTrim: @MainActor (Track) -> Void = { _ in }
}

extension View {
    func tvTrackActionsHost() -> some View { modifier(TVTrackActionsHost()) }
}

private struct TVTrackActionsHost: ViewModifier {
    @State private var playlistTrack: PlaylistTrackRef?
    @State private var trimTrack: Track?
    @State private var confirmation: String?
    @State private var clearTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .environment(\.presentAddToPlaylist) { playlistTrack = $0 }
            .environment(\.presentTrackTrim) { trimTrack = $0 }
            .fullScreenCover(item: $playlistTrack) { track in
                TVAddToPlaylistView(track: track) { playlist in
                    confirm("Added to \(playlist.title)")
                }
            }
            .fullScreenCover(item: $trimTrack) { track in
                TVTrackTrimEditor(track: track)
            }
            .overlay(alignment: .top) {
                if let confirmation {
                    Label(confirmation, systemImage: "checkmark.circle.fill")
                        .font(.tvBodyEmph)
                        .foregroundStyle(Color.scTextPrimary)
                        .padding(.horizontal, Space.base)
                        .padding(.vertical, Space.snug)
                        .glassEffect(.regular, in: Capsule())
                        .padding(.top, Space.base)
                        .allowsHitTesting(false)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                        .accessibilityAddTraits(.isStaticText)
                }
            }
            .animation(reduceMotion ? nil : .smooth, value: confirmation)
    }

    private func confirm(_ message: String) {
        confirmation = message
        UIAccessibility.post(notification: .announcement, argument: message)
        clearTask?.cancel()
        clearTask = Task {
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            confirmation = nil
        }
    }
}

struct TVTrackMenuItems: View {
    let track: Track

    @Environment(\.presentAddToPlaylist) private var presentAddToPlaylist
    @Environment(\.presentTrackTrim) private var presentTrackTrim

    var body: some View {
        if track.supportsSoundCloudActions {
            Button {
                presentAddToPlaylist(PlaylistTrackRef(track: track))
            } label: {
                Label("Add to Playlist…", systemImage: "text.badge.plus")
            }
        }
        if track.duration > TrackTrim.minimumLength {
            Button {
                presentTrackTrim(track)
            } label: {
                Label("Edit Start & End…", systemImage: "timeline.selection")
            }
        }
    }
}

// MARK: - Add to Playlist

struct TVAddToPlaylistView: View {
    let onAdded: (PlaylistSummary) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: AddToPlaylistModel
    @State private var newTitle = ""
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case close
        case newTitle
        case create
        case playlist(String)
    }

    init(track: PlaylistTrackRef, onAdded: @escaping (PlaylistSummary) -> Void) {
        self.onAdded = onAdded
        _model = StateObject(wrappedValue: AddToPlaylistModel(track: track))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.base) {
            HStack {
                VStack(alignment: .leading, spacing: Space.tight) {
                    Eyebrow(text: "Add to Playlist")
                    Text(model.track.title)
                        .font(.tvTitle)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                Spacer()
                PanelCloseButton { dismiss() }
                    .focused($focus, equals: .close)
            }

            newPlaylistRow
                .focusSection()

            Group {
                switch model.state {
                case .loading:
                    StatusPanel(kind: .loading, title: "Loading Playlists…")
                case .failed:
                    StatusPanel(
                        kind: .error,
                        title: "Couldn’t Load Playlists",
                        message: "Check this Apple TV’s network connection.",
                        actionTitle: "Try Again",
                        action: { Task { await model.load() } }
                    )
                case .loaded(let playlists) where playlists.isEmpty:
                    StatusPanel(
                        kind: .empty,
                        icon: "music.note.list",
                        title: "No Playlists Yet",
                        message: "Name a new playlist above."
                    )
                case .loaded(let playlists):
                    list(playlists)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(Space.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.scBackground.ignoresSafeArea())
        .defaultFocus($focus, defaultField)
        .alert("Couldn’t Add to Playlist", isPresented: Binding(
            get: { model.failure != nil },
            set: { if !$0 { model.failure = nil } }
        )) {
            Button("Try Again") { model.retryLastAdd() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.failure ?? "")
        }
        .task { await model.load() }
    }

    private var defaultField: Field {
        if case .loaded(let playlists) = model.state, let first = playlists.first {
            return .playlist(first.id)
        }
        return .newTitle
    }

    private var trimmedTitle: String { newTitle.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var newPlaylistRow: some View {
        HStack(spacing: Space.base) {
            TextField("New Playlist", text: $newTitle)
                .font(.tvBody)
                .submitLabel(.done)
                .onSubmit(create)
                .focused($focus, equals: .newTitle)
                .frame(maxWidth: 900)
                .accessibilityIdentifier("addToPlaylist.newTitle")
            Button(action: create) {
                if model.pendingID == AddToPlaylistModel.newPlaylistID {
                    ProgressView()
                        .padding(.horizontal, 44)
                        .padding(.vertical, 18)
                } else {
                    TVGlassPillLabel(title: "Create and Add", systemImage: "plus")
                }
            }
            .buttonStyle(TVGlassPillStyle(isProminent: !trimmedTitle.isEmpty))
            .focused($focus, equals: .create)
            .accessibilityIdentifier("addToPlaylist.create")
        }
    }

    private func list(_ playlists: [PlaylistSummary]) -> some View {
        ScrollView {
            LazyVStack(spacing: Spacing.sm) {
                ForEach(playlists) { playlist in
                    TVPlaylistPickRow(
                        playlist: playlist,
                        isPending: model.pendingID == playlist.id,
                        isFocused: focus == .playlist(playlist.id)
                    ) {
                        model.add(to: playlist) { finish($0) }
                    }
                    .focused($focus, equals: .playlist(playlist.id))
                }
            }
            .padding(.vertical, Space.tight)
        }
        .scrollClipDisabled()
        .focusSection()
    }

    private func create() {
        guard !trimmedTitle.isEmpty else {
            focus = .newTitle
            return
        }
        model.create(title: trimmedTitle) { finish($0) }
    }

    private func finish(_ playlist: PlaylistSummary) {
        onAdded(playlist)
        dismiss()
    }
}

private struct TVPlaylistPickRow: View {
    let playlist: PlaylistSummary
    let isPending: Bool
    let isFocused: Bool
    let action: () -> Void

    private var focused: Bool { isFocused }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.snug) {
                ArtworkImage(
                    url: playlist.artworkURL ?? SoundCloudCredentialSource.shared.currentUser?.avatarURL,
                    icon: "music.note.list",
                    identity: playlist.id
                )
                .aspectRatio(1, contentMode: .fill)
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.title)
                        .font(.tvBodyEmph)
                        .foregroundStyle(focused ? Color.scChromeFocusOn : .white)
                        .lineLimit(1)
                    Text(playlist.trackCount == 1 ? "1 track" : "\(playlist.trackCount) tracks")
                        .font(.tvCaption)
                        .foregroundStyle(focused ? Color.scChromeFocusOn.opacity(0.65) : Color.scTextSecondary)
                }

                Spacer(minLength: 0)

                if isPending {
                    ProgressView()
                        .tint(focused ? Color.scChromeFocusOn : .white)
                }
            }
            .padding(Space.snug)
            .background(
                RoundedRectangle(cornerRadius: Corner.card, style: .continuous)
                    .fill(focused ? Color.scChromeFocus : Color.white.opacity(0.06))
            )
            .contentShape(RoundedRectangle(cornerRadius: Corner.card, style: .continuous))
        }
        .buttonStyle(SCCardButtonStyle(cornerRadius: Corner.card))
        .focusEffectDisabled()
        .accessibilityLabel("\(playlist.title), \(playlist.trackCount) tracks")
        .accessibilityValue(isPending ? "Adding" : "")
    }
}

// MARK: - Start & End

struct TVTrackTrimEditor: View {
    let track: Track

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var waveforms = WaveformService.shared
    @State private var start: TimeInterval
    @State private var end: TimeInterval
    @State private var editing: Marker?
    @State private var panAnchor: TimeInterval?
    @FocusState private var focus: Field?

    private enum Marker: Hashable {
        case start
        case end
    }

    private enum Field: Hashable {
        case close
        case marker(Marker)
        case previewStart
        case previewEnd
        case suggest
        case reset
        case save
    }

    private static let waveWidth: CGFloat = 1600
    private static let waveHeight: CGFloat = 220

    init(track: Track) {
        self.track = track
        let range = TrackTrimStore.shared.effectiveRange(for: track)
        _start = State(initialValue: range.lowerBound)
        _end = State(initialValue: track.duration > 0 ? range.upperBound : 0)
    }

    private var duration: TimeInterval { max(track.duration, 0) }
    private var waveform: Waveform? { waveforms.state(for: track.id).waveform }
    private var draft: TrackTrim { TrackTrim(start: start, end: end) }
    private var isUntrimmed: Bool { draft.normalised(duration: duration) == nil }
    private var step: TimeInterval { duration > 600 ? 5 : 0.5 }
    private var isEditing: Bool { editing != nil }

    private var isWaveformFailed: Bool {
        if case .failed = waveforms.state(for: track.id) { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.section) {
            HStack {
                VStack(alignment: .leading, spacing: Space.tight) {
                    Eyebrow(text: "Start & End")
                    Text(track.title)
                        .font(.tvTitle)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                Spacer()
                PanelCloseButton { dismiss() }
                    .focused($focus, equals: .close)
                    .disabled(isEditing)
            }

            VStack(spacing: Space.base) {
                wave
                Text(summary)
                    .font(.tvBody)
                    .monospacedDigit()
                    .foregroundStyle(Color.scTextSecondary)
                    .frame(maxWidth: .infinity)
            }

            HStack(spacing: Space.base) {
                markerButton(.start)
                markerButton(.end)
            }
            .frame(maxWidth: .infinity)
            .focusSection()

            HStack(spacing: Space.base) {
                actionButton("Preview Start", icon: "play", field: .previewStart) { preview(at: start) }
                actionButton("Preview End", icon: "play", field: .previewEnd) { preview(at: max(start, end - 5)) }
                if waveform != nil {
                    actionButton("Suggest", icon: "wand.and.stars", field: .suggest, action: suggest)
                }
                if !isUntrimmed {
                    actionButton("Reset", icon: "arrow.counterclockwise", field: .reset, action: reset)
                }
                actionButton("Save", icon: "checkmark", field: .save, isProminent: true) {
                    save()
                    dismiss()
                }
            }
            .frame(maxWidth: .infinity)
            .focusSection()

            Spacer(minLength: 0)
        }
        .padding(Space.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.scBackground.ignoresSafeArea())
        .defaultFocus($focus, .marker(.start))
        .onAppear { waveforms.load(track) }
    }

    private var summary: String {
        if isEditing { return "Swipe or press \u{25C0} \u{25B6} to move. Click when done." }
        return "Plays \(TrackTrimFormat.string(max(0, end - start))) of \(track.formattedDuration)"
    }

    private var wave: some View {
        ZStack(alignment: .topLeading) {
            SCWaveformRenderer(
                envelope: waveform?.samples ?? [],
                duration: duration,
                progress: 1,
                showsPlayhead: false,
                placeholder: isWaveformFailed ? .unavailable : .loading,
                identity: track.id,
                motionSuppressed: reduceMotion,
                style: .tv
            )
            .frame(width: Self.waveWidth, height: Self.waveHeight)

            Rectangle()
                .fill(Color.black.opacity(0.6))
                .frame(width: x(start), height: Self.waveHeight)
            Rectangle()
                .fill(Color.black.opacity(0.6))
                .frame(width: max(0, Self.waveWidth - x(end)), height: Self.waveHeight)
                .offset(x: x(end))

            handle(.start)
            handle(.end)
        }
        .frame(width: Self.waveWidth, height: Self.waveHeight + 56, alignment: .topLeading)
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : Motion.focus, value: editing)
        .accessibilityHidden(true)
    }

    private func handle(_ marker: Marker) -> some View {
        let value = marker == .start ? start : end
        let active = editing == marker
        return VStack(spacing: Space.tight) {
            Capsule()
                .fill(active ? Color.white : Color.scAccent)
                .frame(width: active ? 8 : 5, height: Self.waveHeight)
                .shadow(color: active ? Color.scFocusShadow : .clear, radius: 12, y: 6)
            Text(TrackTrimFormat.string(value))
                .font(.tvCaption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(active ? Color.white : Color.scTextSecondary)
                .fixedSize()
        }
        .frame(width: 160)
        .offset(x: x(value) - 80)
    }

    private func x(_ time: TimeInterval) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(1, max(0, time / duration))) * Self.waveWidth
    }

    private func markerButton(_ marker: Marker) -> some View {
        let title = marker == .start ? "Start" : "End"
        let value = marker == .start ? start : end
        let active = editing == marker
        let isFocused = focus == .marker(marker)
        return Button {
            editing = active ? nil : marker
        } label: {
            HStack(spacing: Space.snug) {
                if active {
                    Image(systemName: "chevron.left")
                }
                Text(title)
                Text(TrackTrimFormat.string(value))
                    .monospacedDigit()
                if active {
                    Image(systemName: "chevron.right")
                }
            }
            .font(.tvBodyEmph)
            .padding(.horizontal, 44)
            .padding(.vertical, 18)
        }
        .buttonStyle(TVGlassPillStyle(isProminent: active))
        .focused($focus, equals: .marker(marker))
        .disabled(isEditing && !active)
        .background(
            RemoteScrubSurface(
                isActive: active && isFocused && duration > 0,
                capturesExit: active,
                onBegan: { panAnchor = value },
                onChanged: { move(marker, to: panTime($0)) },
                onEnded: {
                    move(marker, to: panTime($0))
                    panAnchor = nil
                },
                onCancelled: { panAnchor = nil },
                onExit: stopEditing
            )
            .allowsHitTesting(false)
        )
        .onMoveCommand { direction in
            guard active else { return }
            switch direction {
            case .left: move(marker, to: value - step)
            case .right: move(marker, to: value + step)
            default: break
            }
        }
        .onExitCommand(perform: active ? { stopEditing() } : nil)
        .accessibilityLabel(title)
        .accessibilityValue(TrackTrimFormat.string(value))
        .accessibilityHint(active ? "Swipe or press left or right to move. Click when done." : "Click to move the \(title.lowercased()) marker.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: move(marker, to: value + 1)
            case .decrement: move(marker, to: value - 1)
            @unknown default: break
            }
        }
    }

    private func actionButton(
        _ title: String,
        icon: String,
        field: Field,
        isProminent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            TVGlassPillLabel(title: title, systemImage: icon)
        }
        .buttonStyle(TVGlassPillStyle(isProminent: isProminent))
        .focused($focus, equals: field)
        .disabled(isEditing)
    }

    private func stopEditing() {
        editing = nil
    }

    private func panTime(_ translation: CGFloat) -> TimeInterval {
        RemoteScrub.time(
            from: panAnchor ?? 0,
            translation: translation,
            duration: duration,
            span: max(10, duration / 4)
        )
    }

    private func move(_ marker: Marker, to candidate: TimeInterval) {
        switch marker {
        case .start:
            start = min(max(0, candidate), max(0, end - TrackTrim.minimumLength))
        case .end:
            end = max(min(duration, candidate), min(duration, start + TrackTrim.minimumLength))
        }
    }

    private func save() {
        TrackTrimStore.shared.setTrim(draft, for: track.id, duration: duration)
    }

    private func reset() {
        start = 0
        end = duration
        TrackTrimStore.shared.reset(track.id)
        focus = .save
    }

    private func preview(at position: TimeInterval) {
        save()
        Task { await PlayerService.shared.beginPreviewPlayback(of: track, at: position) }
    }

    private func suggest() {
        guard let waveform else { return }
        let range = TrackTrimStore.range(
            TrackTrimSuggestion.silence(in: waveform.samples, duration: duration),
            duration: duration
        )
        start = range.lowerBound
        end = range.upperBound
    }
}
