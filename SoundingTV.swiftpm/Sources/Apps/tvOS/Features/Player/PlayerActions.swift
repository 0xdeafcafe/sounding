import SwiftUI

struct UtilityActionButton: View {
    let icon: String
    var label: String? = nil
    var isActive: Bool = false
    var isBusy: Bool = false
    var accessibilityLabel: String? = nil
    let action: () -> Void

    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var artworkColors = ArtworkColors.shared
    @State private var didActivate = false

    var body: some View {
        HStack(spacing: 6) {
            if isBusy {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(0.7)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .semibold))
                    .symbolEffect(.bounce, value: reduceMotion ? false : didActivate)
            }
            if let label {
                Text(label)
                    .font(.tvBodyEmph)
            }
        }
        .foregroundStyle(isActive || focused ? Color.scTextPrimary : Color.scTextSecondary)
        .padding(.horizontal, label == nil ? Spacing.sm + 2 : Space.snug)
        .padding(.vertical, Space.tight)
        .frame(minWidth: label == nil ? Control.circle : nil, minHeight: Control.circle)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .scSelected(isActive, in: Capsule())
        .scFocus(focused, in: Capsule(), reduceMotion: reduceMotion)
        .contentShape(Capsule())
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onTapGesture {
            didActivate.toggle()
            action()
        }
        .accessibilityLabel(accessibilityLabel ?? label ?? icon)
    }
}

@MainActor
final class TrackEngagementStore: ObservableObject {
    @Published private(set) var likedOverrides: [String: Bool] = [:]
    @Published private(set) var pendingTrackIds: Set<String> = []

    func isLiked(_ track: Track) -> Bool {
        likedOverrides[track.id] ?? false
    }

    func isPending(_ track: Track) -> Bool {
        pendingTrackIds.contains(track.id)
    }

    func toggleLike(_ track: Track) async {
        guard !pendingTrackIds.contains(track.id) else { return }
        let next = !isLiked(track)
        likedOverrides[track.id] = next
        pendingTrackIds.insert(track.id)
        defer { pendingTrackIds.remove(track.id) }

        do {
            if next {
                try await SoundCloudAPI.shared.likeTrack(track)
            } else {
                try await SoundCloudAPI.shared.unlikeTrack(track)
            }
        } catch {
            likedOverrides[track.id] = !next
        }
    }
}

struct LikeActionButton: View {
    let track: Track
    @ObservedObject var engagement: TrackEngagementStore

    var body: some View {
        UtilityActionButton(
            icon: engagement.isLiked(track) ? "heart.fill" : "heart",
            isActive: engagement.isLiked(track),
            isBusy: engagement.isPending(track),
            accessibilityLabel: engagement.isLiked(track) ? "Unlike" : "Like"
        ) {
            Task { await engagement.toggleLike(track) }
        }
    }
}

struct QueueActionButton: View {
    let track: Track

    @State private var justAdded = false
    @State private var clearTask: Task<Void, Never>?

    var body: some View {
        UtilityActionButton(
            icon: justAdded ? "checkmark" : "text.badge.plus",
            accessibilityLabel: "Add to Up Next"
        ) {
            PlayerService.shared.addToQueue(track)
            justAdded = true
            clearTask?.cancel()
            clearTask = Task {
                try? await Task.sleep(for: .seconds(1.6))
                guard !Task.isCancelled else { return }
                justAdded = false
            }
        }
    }
}

struct AddToPlaylistActionButton: View {
    let track: Track

    @State private var showingSheet = false

    var body: some View {
        UtilityActionButton(icon: "plus.square.on.square", accessibilityLabel: "Add to Playlist") {
            showingSheet = true
        }
        .fullScreenCover(isPresented: $showingSheet) {
            AddToPlaylistView(track: track)
        }
    }
}

private struct AddToPlaylistView: View {
    let track: Track

    @Environment(\.dismiss) private var dismiss
    @State private var playlists: [PlaylistSummary] = []
    @State private var state: CommentsLoadState = .loading
    @State private var addedPlaylistId: String?
    @FocusState private var closeFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.base) {
            HStack {
                VStack(alignment: .leading, spacing: Space.tight) {
                    Eyebrow(text: "Add to Playlist")
                    Text(track.title)
                        .font(.tvTitle)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                Spacer()
                PanelCloseButton { dismiss() }
                    .focused($closeFocused)
            }

            Group {
                switch state {
                case .idle, .loading:
                    StatusPanel(kind: .loading, title: "Loading Playlists…")
                case .failed:
                    StatusPanel(
                        kind: .error,
                        title: "Couldn't Load Playlists",
                        message: "Check this Apple TV's network connection.",
                        actionTitle: "Try Again",
                        action: { Task { await load() } }
                    )
                case .loaded where playlists.isEmpty:
                    StatusPanel(
                        kind: .empty,
                        icon: "music.note.list",
                        title: "No Playlists Yet",
                        message: "Create a playlist in the SoundCloud app first."
                    )
                case .loaded:
                    playlistList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(Space.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.scBackground.ignoresSafeArea())
        .defaultFocus($closeFocused, true)
        .task { await load() }
    }

    private var playlistList: some View {
        ScrollView {
            VStack(spacing: Spacing.sm) {
                ForEach(playlists) { playlist in
                    PlaylistPickRow(
                        playlist: playlist,
                        isAdded: addedPlaylistId == playlist.id
                    ) {
                        Task { await add(to: playlist) }
                    }
                }
            }
        }
        .focusSection()
    }

    private func load() async {
        state = .loading
        do {
            let page = try await SoundCloudAPI.shared.getMyPlaylists()
            playlists = page.collection
            state = .loaded
        } catch {
            state = .failed
        }
    }

    private func add(to playlist: PlaylistSummary) async {
        guard addedPlaylistId == nil else { return }
        do {
            try await SoundCloudAPI.shared.addTrack(track.id, toPlaylist: playlist.id)
            addedPlaylistId = playlist.id
            try? await Task.sleep(for: .milliseconds(700))
            dismiss()
        } catch {
        }
    }
}

private struct PlaylistPickRow: View {
    let playlist: PlaylistSummary
    let isAdded: Bool
    let action: () -> Void

    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Space.snug) {
            ArtworkImage(
                url: playlist.artworkURL ?? SoundCloudCredentialSource.shared.currentUser?.avatarURL,
                icon: "music.note.list"
            )
                .aspectRatio(1, contentMode: .fill)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: CornerRadius.sm, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.title)
                    .font(.tvBodyEmph)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(playlist.trackCount) tracks")
                    .font(.tvCaption)
                    .foregroundStyle(Color.scTextSecondary)
            }

            Spacer(minLength: 0)

            if isAdded {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.scSuccess)
            }
        }
        .padding(Space.snug)
        .background(
            RoundedRectangle(cornerRadius: Corner.card, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .scFocus(focused, cornerRadius: Corner.card, reduceMotion: reduceMotion)
        .contentShape(RoundedRectangle(cornerRadius: Corner.card, style: .continuous))
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onTapGesture(perform: action)
    }
}

struct TrackMapButton: View {
    @ObservedObject var board: CueBoard
    let action: () -> Void

    var body: some View {
        UtilityActionButton(
            icon: "bookmark",
            label: markedCount == 0 ? nil : "\(markedCount)",
            accessibilityLabel: accessibilityLabel
        ) {
            action()
        }
    }

    private var markedCount: Int { board.sheet.userCues.count }

    private var accessibilityLabel: String {
        guard markedCount > 0 else { return "Cue Points" }
        return markedCount == 1 ? "Cue Points, 1 marked" : "Cue Points, \(markedCount) marked"
    }
}

struct ShareActionButton: View {
    let track: Track

    @State private var showingShare = false

    var body: some View {
        UtilityActionButton(icon: "qrcode", accessibilityLabel: "Share") {
            showingShare = true
        }
        .fullScreenCover(isPresented: $showingShare) {
            ShareTrackView(track: track)
        }
    }
}

struct ShareTrackView: View {
    let track: Track

    @Environment(\.dismiss) private var dismiss
    @State private var matrix: QRMatrix?
    @FocusState private var closeFocused: Bool
    @ObservedObject private var artworkColors = ArtworkColors.shared

    var body: some View {
        VStack(spacing: Space.roomy) {
            HStack {
                VStack(alignment: .leading, spacing: Space.tight) {
                    Eyebrow(text: "Share")
                    Text(track.title)
                        .font(.tvTitle)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                }
                Spacer()
                PanelCloseButton { dismiss() }
                    .focused($closeFocused)
            }

            Spacer()

            VStack(spacing: Space.base) {
                ZStack {
                    RoundedRectangle(cornerRadius: CornerRadius.xl, style: .continuous)
                        .fill(artworkColors.current.primary.opacity(0.30))
                        .frame(width: 400, height: 400)
                        .blur(radius: 50)

                    RoundedRectangle(cornerRadius: CornerRadius.xl, style: .continuous)
                        .fill(.white)
                        .frame(width: 380, height: 380)
                        .shadow(color: .black.opacity(0.5), radius: 40, y: 16)
                        .overlay {
                            if let matrix {
                                QRCodeView(matrix: matrix, markColor: artworkColors.current.primary)
                                    .frame(width: 340, height: 340)
                            } else {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .scaleEffect(1.5)
                                    .tint(.black.opacity(0.4))
                            }
                        }
                }
                Text("Scan to open “\(track.title)” on your phone")
                    .font(.tvBody)
                    .foregroundStyle(Color.scTextSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 700)
            }
            .frame(maxWidth: .infinity)

            Spacer()
        }
        .padding(Space.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.scBackground.ignoresSafeArea())
        .defaultFocus($closeFocused, true)
        .task {
            matrix = QRCodeGenerator.matrix(for: track.permalinkURL.absoluteString)
        }
    }
}

struct PanelCloseButton: View {
    let action: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: Control.circleIcon, weight: .bold))
            .foregroundStyle(Color.scTextPrimary)
            .frame(width: Control.circle, height: Control.circle)
            .liquidGlass(in: Circle(), interactive: true)
            .scFocus(focused, in: Circle(), reduceMotion: reduceMotion)
            .contentShape(Circle())
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onTapGesture(perform: action)
    }
}
