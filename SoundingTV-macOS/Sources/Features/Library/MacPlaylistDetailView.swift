import SwiftUI
import AppKit

enum MacCollectionKind: Equatable {
    case playlist
    case album

    var noun: String { self == .playlist ? "Playlist" : "Album" }
}

struct MacPlaylistDetailView: View {
    let playlist: Playlist

    var body: some View {
        MacCollectionDetailView(playlist: playlist, kind: .playlist)
    }
}

struct MacCollectionDetailView: View {
    let kind: MacCollectionKind

    @StateObject private var viewModel: PlaylistDetailViewModel
    @StateObject private var suggestions = MacSuggestedTracksModel()
    @EnvironmentObject private var credentials: SoundCloudCredentialSource

    @State private var isDescriptionExpanded = false
    @State private var filterText = ""
    @State private var isShowingCollectionPolicy = false

    init(playlist: Playlist, kind: MacCollectionKind) {
        self.kind = kind
        _viewModel = StateObject(wrappedValue: PlaylistDetailViewModel(playlist: playlist))
    }

    private var playlist: Playlist { viewModel.playlist }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                    .padding(.horizontal, SCContentStyle.mac.spaceGutter)
                    .padding(.top, SCContentStyle.mac.spaceGutter)
                    .padding(.bottom, SCContentStyle.mac.spaceRoomy)

                mainContent(for: state)
                    .padding(.horizontal, SCContentStyle.mac.spaceGutter)
                    .padding(.bottom, 32)
            }
        }
        .background(alignment: .topLeading) {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.075), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(height: 300)
            .allowsHitTesting(false)
        }
        .navigationTitle(playlist.title)
        .searchable(
            text: $filterText,
            placement: .toolbar,
            prompt: "Find in \(kind.noun)"
        )
        .task {
            await viewModel.loadIfNeeded()
        }
        .task(id: viewModel.playlist.id) {
            await suggestions.load(excluding: playlist, currentUserId: credentials.currentUser?.id, isSignedOut: credentials.isSignedOut)
        }
        .task(id: viewModel.tracks.map(\.id)) {
            DownloadManager.shared.applyCollectionPolicy(
                tracks: viewModel.tracks,
                collectionId: playlist.id
            )
        }
        .sheet(isPresented: $isShowingCollectionPolicy) {
            CollectionPolicyEditor(
                collectionId: playlist.id,
                collectionName: playlist.title,
                collectionKind: CollectionKind.classify(playlist: playlist),
                tracks: viewModel.tracks,
                applier: DownloadManager.shared
            )
        }
    }

    private enum State { case loading, error(String), empty, loaded }

    private var state: State {
        if viewModel.isLoading, viewModel.tracks.isEmpty { return .loading }
        if let error = viewModel.errorMessage, viewModel.tracks.isEmpty { return .error(error) }
        if viewModel.tracks.isEmpty { return .empty }
        return .loaded
    }

    @ViewBuilder
    private func mainContent(for state: State) -> some View {
        switch state {
        case .loading:
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding(.vertical, 60)
        case .error(let message):
            SCEmptyState(
                kind: .error,
                title: "Couldn\u{2019}t Load \(kind.noun)",
                message: message,
                actionTitle: "Try Again",
                action: { Task { await viewModel.load() } },
                style: .mac
            )
            .padding(.vertical, 40)
        case .empty:
            emptyState
        case .loaded:
            trackTable
        }
    }

    private var hero: some View {
        HStack(alignment: .bottom, spacing: SCContentStyle.mac.spaceRoomy) {
            heroArtwork

            VStack(alignment: .leading, spacing: SCContentStyle.mac.spaceTight) {
                Text(kind == .album ? "ALBUM" : "PLAYLIST")
                    .font(.caption2.weight(.bold))
                    .kerning(0.8)
                    .foregroundStyle(.secondary)

                Text(playlist.title)
                    .font(.system(size: 34, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)

                Button {
                    MacRootSelection.shared.request(artist: playlist.user)
                } label: {
                    HStack(spacing: 5) {
                        ArtworkThumbnail(
                            url: playlist.user.avatarURL,
                            identity: playlist.user.displayName,
                            size: 22,
                            cornerRadius: 11
                        )
                        Text(playlist.user.displayName)
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .help("View \(playlist.user.displayName)")

                Text(collectionDetailsLine)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                if let description = playlist.description, !description.isEmpty {
                    TruncatedText(description, isExpanded: $isDescriptionExpanded)
                        .padding(.top, 2)
                }

                actionRow
                    .padding(.top, SCContentStyle.mac.spaceSnug)
            }

            Spacer(minLength: 0)
        }
    }

    private var heroArtwork: some View {
        ArtworkThumbnail(
            candidates: MacCollectionCover.artworkURLs(for: playlist),
            identity: playlist.title,
            size: 190,
            cornerRadius: SCContentStyle.mac.cornerCard,
            crownUser: playlist.user,
            crownContext: playlist.title
        )
            .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
    }

    private var addedLine: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: playlist.createdAt, relativeTo: Date())
        return "\(playlist.totalTrackCount) track\(playlist.totalTrackCount == 1 ? "" : "s") \u{00B7} Added \(relative)"
    }

    private var collectionDetailsLine: String {
        var parts = [
            "\(playlist.totalTrackCount) track\(playlist.totalTrackCount == 1 ? "" : "s")",
            playlist.formattedDuration
        ]
        if playlist.likeCount > 0 {
            parts.append("\(playlist.likeCount.formatted(.number.notation(.compactName))) likes")
        }
        parts.append(addedLine.replacingOccurrences(
            of: "\(playlist.totalTrackCount) track\(playlist.totalTrackCount == 1 ? "" : "s") \u{00B7} ",
            with: ""
        ))
        return parts.joined(separator: " \u{00B7} ")
    }

    private var actionRow: some View {
        HStack(spacing: SCContentStyle.mac.spaceSnug) {
            Button {
                play()
            } label: {
                Label("Play", systemImage: "play.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 18)
                    .frame(height: 34)
            }
            .buttonStyle(.plain)
            .glassEffect(
                .regular.tint(SCContentStyle.mac.accent.opacity(0.30)),
                in: Capsule(style: .continuous)
            )
            .disabled(!hasPlayableTrack)

            Button {
                shufflePlay()
            } label: {
                Image(systemName: "shuffle")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: Circle())
            .disabled(!hasPlayableTrack)
            .help("Shuffle")

            Button {
                downloadAll()
            } label: {
                Image(systemName: "arrow.down.circle")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: Circle())
            .disabled(!hasPlayableTrack)
            .help("Download every track loaded here")

            Menu {
                collectionMenu
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular, in: Circle())
            .menuIndicator(.hidden)
            .help("More")
        }
        .controlSize(.regular)
    }

    @ViewBuilder
    private var collectionMenu: some View {
        Button {
            playNext()
        } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        .disabled(!hasPlayableTrack)

        Button {
            playLast()
        } label: {
            Label("Add to Up Next", systemImage: "text.badge.plus")
        }
        .disabled(!hasPlayableTrack)

        Divider()

        Button {
            isShowingCollectionPolicy = true
        } label: {
            Label("Collection Settings", systemImage: "slider.horizontal.3")
        }

        Divider()

        Button {
            NSWorkspace.shared.open(playlist.permalinkURL)
        } label: {
            Label("Open on SoundCloud", systemImage: "safari")
        }

        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(playlist.permalinkURL.absoluteString, forType: .string)
        } label: {
            Label("Copy SoundCloud Link", systemImage: "link")
        }

        ShareLink(item: playlist.permalinkURL, subject: Text(playlist.title)) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }

    private var hasPlayableTrack: Bool {
        viewModel.tracks.contains { $0.streamURL != nil }
    }

    private var emptyState: some View {
        VStack(spacing: SCContentStyle.mac.spaceRoomy) {
            SCEmptyState(
                icon: "music.note.list",
                title: "No Songs",
                message: "Songs you add will appear here.",
                style: .mac
            )

            suggestedSongsCard
        }
    }

    private var suggestedSongsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Suggested Songs")
                        .font(.system(size: 15, weight: .semibold))
                    Text("From your Liked Tracks. Preview, then add to the playlist.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await suggestions.reload(excluding: playlist, currentUserId: credentials.currentUser?.id, isSignedOut: credentials.isSignedOut) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(suggestions.isLoading)
            }

            suggestedSongsBody
        }
        .padding(SCContentStyle.mac.spaceGutter)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: SCContentStyle.mac.cornerCard, style: .continuous))
    }

    @ViewBuilder
    private var suggestedSongsBody: some View {
        if credentials.isSignedOut {
            Text("Pair this Mac with your iPhone to see suggestions from your Liked Tracks.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else if suggestions.isLoading, suggestions.tracks.isEmpty {
            HStack {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
            .padding(.vertical, 12)
        } else if let error = suggestions.errorMessage, suggestions.tracks.isEmpty {
            SCEmptyState(
                kind: .error,
                title: "Couldn\u{2019}t Load Suggestions",
                message: error,
                actionTitle: "Try Again",
                action: {
                    Task {
                        await suggestions.reload(excluding: playlist, currentUserId: credentials.currentUser?.id, isSignedOut: credentials.isSignedOut)
                    }
                },
                style: .mac
            )
        } else if suggestions.tracks.isEmpty {
            Text("Like a few tracks on SoundCloud and they\u{2019}ll show up here.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else {
            let columns = [GridItem(.flexible(), spacing: 20), GridItem(.flexible(), spacing: 20)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: SCContentStyle.mac.spaceSnug) {
                ForEach(suggestions.tracks) { track in
                    SuggestedTrackRow(track: track, isAdding: suggestions.isAdding(track)) {
                        Task { await suggestions.add(track, to: playlist) { added in
                            viewModel.acceptSuggestedTrack(added)
                        } }
                    }
                }
            }
        }
    }

    private var visibleTracks: [Track] {
        let needle = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return viewModel.tracks }
        return viewModel.tracks.filter {
            $0.title.localizedCaseInsensitiveContains(needle) || $0.user.displayName.localizedCaseInsensitiveContains(needle)
        }
    }

    private var trackTable: some View {
        VStack(spacing: 0) {
            MacCollectionTrackTable(
                tracks: visibleTracks,
                contextPlaylist: playlist,
                onPlay: { track in Task { await PlayerService.shared.play(track, in: viewModel.tracks) } }
            )
            .frame(minHeight: CGFloat(visibleTracks.count) * 42 + 30)

            if viewModel.isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .padding(SCContentStyle.mac.spaceSnug)
            }

            if filterText.isEmpty, viewModel.tracks.count < playlist.totalTrackCount {
                Color.clear
                    .frame(height: 1)
                    .onAppear { Task { await viewModel.loadMore() } }
            }
        }
    }

    private func play() {
        guard let first = viewModel.tracks.first(where: { $0.streamURL != nil }) else { return }
        Task { await PlayActions.play(tracks: viewModel.tracks, startingAt: first, collectionId: playlist.id) }
    }

    private func shufflePlay() {
        guard let start = viewModel.tracks.filter({ $0.streamURL != nil }).randomElement() else { return }
        PlayerService.shared.isShuffleEnabled = true
        Task { await PlayActions.play(tracks: viewModel.tracks, startingAt: start, collectionId: playlist.id) }
    }

    private func downloadAll() {
        CollectionQualityOverrideStore.shared.updatePolicy(for: playlist.id) {
            $0.automaticDownloads = true
        }
        DownloadManager.shared.applyCollectionPolicy(tracks: viewModel.tracks, collectionId: playlist.id)
    }

    private func playNext() {
        let tracks = viewModel.tracks.filter { $0.streamURL != nil }
        let insertionIndex = PlayerService.shared.currentIndex + 1
        for track in tracks.reversed() {
            PlayerService.shared.insertIntoQueue(track, at: insertionIndex)
        }
    }

    private func playLast() {
        for track in viewModel.tracks where track.streamURL != nil {
            PlayerService.shared.addToQueue(track)
        }
    }
}

private struct TruncatedText: View {
    let text: String
    @Binding var isExpanded: Bool

    init(_ text: String, isExpanded: Binding<Bool>) {
        self.text = text
        self._isExpanded = isExpanded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(isExpanded ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)

            if !isExpanded {
                Button("MORE") { isExpanded = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(maxWidth: 460, alignment: .leading)
    }
}

struct MacCollectionTrackTable: View {
    let tracks: [Track]
    var contextPlaylist: Playlist? = nil
    let onPlay: (Track) -> Void

    @State private var selectedTrackID: Track.ID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Song")
                    .padding(.leading, 50)
                Spacer()
                Text("Time")
                    .frame(width: 58, alignment: .trailing)
                Color.clear.frame(width: 34, height: 1)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(height: 30)

            Divider()

            LazyVStack(spacing: 2) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    MacCollectionTrackRow(
                        track: track,
                        contextPlaylist: contextPlaylist,
                        usesAlternateBackground: index.isMultiple(of: 2),
                        isSelected: selectedTrackID == track.id,
                        onSelect: { selectedTrackID = track.id },
                        onPlay: { onPlay(track) }
                    )
                }
            }
            .padding(.top, 2)
        }
    }
}

private struct MacCollectionTrackRow: View {
    let track: Track
    var contextPlaylist: Playlist? = nil
    var usesAlternateBackground = false
    let isSelected: Bool
    let onSelect: () -> Void
    let onPlay: () -> Void

    @ObservedObject private var player = PlayerService.shared
    @State private var isHovering = false

    private var isPlayable: Bool { track.streamURL != nil }
    private var isCurrentTrack: Bool { player.currentTrack?.id == track.id }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                ArtworkThumbnail(
                    url: track.artworkURL,
                    identity: track.title,
                    size: 38,
                    cornerRadius: 5,
                    isAvailable: isPlayable,
                    crownUser: track.user,
                    crownContext: track.title
                )

                if isCurrentTrack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(.black.opacity(0.44))
                    if player.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                } else if isHovering, isPlayable {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(.black.opacity(0.40))
                    Button {
                        onSelect()
                        onPlay()
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Play")
                }
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(track.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isSelected ? Color.white : (isPlayable ? Color.primary : Color.secondary))
                        .lineLimit(1)

                    if track.isPrivate {
                        Label("Private", systemImage: "lock.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.white.opacity(0.86) : Color.orange)
                            .labelStyle(.titleAndIcon)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                (isSelected ? Color.white.opacity(0.12) : Color.orange.opacity(0.12)),
                                in: Capsule(style: .continuous)
                            )
                            .help("Private track")
                    }
                }

                Button {
                    MacRootSelection.shared.request(artist: track.user)
                } label: {
                    Text(track.user.displayName)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.78) : Color.secondary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 12)

            Text(track.formattedDuration)
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? Color.white.opacity(0.78) : Color.secondary)
                .monospacedDigit()
                .frame(width: 58, alignment: .trailing)

            TrackRowMenu(
                track: track,
                contextPlaylist: contextPlaylist,
                foreground: isSelected ? .white : .secondary
            )
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard isPlayable else { return }
            onSelect()
            onPlay()
        }
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
        .contextMenu {
            MacTrackContextMenu(track: track, contextPlaylist: contextPlaylist)
        }
    }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.34) }
        if isHovering { return Color.primary.opacity(0.06) }
        if track.isPrivate { return Color.orange.opacity(0.045) }
        if usesAlternateBackground { return Color.primary.opacity(0.022) }
        return .clear
    }
}

private struct TrackRowMenu: View {
    let track: Track
    var contextPlaylist: Playlist? = nil
    var foreground: Color = .secondary

    var body: some View {
        Menu {
            MacTrackContextMenu(track: track, contextPlaylist: contextPlaylist)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 34, height: 34)
    }
}

@MainActor
final class MacSuggestedTracksModel: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var addingTrackIDs: Set<String> = []

    private var loadTask: Task<Void, Never>?

    func isAdding(_ track: Track) -> Bool { addingTrackIDs.contains(track.id) }

    func load(excluding playlist: Playlist, currentUserId: String?, isSignedOut: Bool) async {
        guard tracks.isEmpty, !isSignedOut else { return }
        await fetch(excluding: playlist)
    }

    func reload(excluding playlist: Playlist, currentUserId: String?, isSignedOut: Bool) async {
        guard !isSignedOut else { return }
        await fetch(excluding: playlist)
    }

    private func fetch(excluding playlist: Playlist) async {
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let page = try await SoundCloudAPI.shared.getLikedTracks(limit: 50)
            guard !Task.isCancelled else { return }
            let existing = Set(playlist.trackIDs ?? playlist.loadedTracks.map(\.id))
            let candidates = page.collection.map(\.item).filter { !existing.contains($0.id) }
            tracks = Array(candidates.shuffled().prefix(6))
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "Couldn\u{2019}t load your Liked Tracks to suggest from."
        }
    }

    func add(_ track: Track, to playlist: Playlist, onAdded: @escaping (Track) -> Void) async {
        guard !addingTrackIDs.contains(track.id) else { return }
        addingTrackIDs.insert(track.id)
        defer { addingTrackIDs.remove(track.id) }

        do {
            try await SoundCloudAPI.shared.addTrack(track.id, toPlaylist: playlist.id)
            tracks.removeAll { $0.id == track.id }
            onAdded(track)
        } catch {
            errorMessage = "Couldn\u{2019}t add \u{201C}\(track.title)\u{201D}. Check your connection and try again."
        }
    }
}

private struct SuggestedTrackRow: View {
    let track: Track
    let isAdding: Bool
    let onAdd: () -> Void

    @State private var artwork: NSImage?

    var body: some View {
        SCTrackRow(
            title: track.title,
            subtitle: track.user.displayName,
            artworkImage: artwork.map { Image(nsImage: $0) },
            isAvailable: track.streamURL != nil,
            crownUser: track.user,
            crownContext: track.title,
            style: .mac
        ) {
            Button(action: onAdd) {
                if isAdding {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .buttonStyle(.plain)
            .disabled(isAdding)
            .help("Add to this playlist")
        }
        .task(id: track.artworkURL) {
            artwork = nil
            guard let url = track.artworkURL else { return }
            artwork = await ArtworkCache.shared.image(for: url, variant: .standard)
        }
    }
}

extension PlaylistDetailViewModel {
    @MainActor
    func acceptSuggestedTrack(_ track: Track) {
        tracks.appendUnique(contentsOf: [track])
    }
}
