import SwiftUI
import AppKit

enum MacPlaylistScope: Equatable {
    case all
    case mine
    case liked

    var title: String {
        switch self {
        case .all: "All Playlists"
        case .mine: "My Playlists"
        case .liked: "Liked Playlists"
        }
    }
}

struct MacPlaylistsView: View {
    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    @ObservedObject private var model: MacPlaylistsModel
    let scope: MacPlaylistScope
    @FocusState private var searchFocused: Bool

    init(model: MacPlaylistsModel, scope: MacPlaylistScope = .all) {
        self.model = model
        self.scope = scope
    }

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, SCContentStyle.mac.spaceGutter)
                .padding(.top, SCContentStyle.mac.spaceBase)
                .padding(.bottom, 32)
        }
        .background(Color.black.opacity(0.001))
        .navigationTitle(scope.title)
        .toolbar {
            ToolbarItem(id: "playlist-kind-filter", placement: .primaryAction) {
                kindFilter
            }
        }
        .searchable(
            text: $model.searchText,
            placement: .toolbar,
            prompt: "Find in \(scope.title)"
        )
        .background {
            Group {
                Button("") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                Button("") { searchFocused = true }
                    .keyboardShortcut("k", modifiers: .command)
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
        .task {
            if model.liked.isEmpty, model.mine.isEmpty {
                model.load(currentUserId: credentials.currentUser?.id, isSignedOut: credentials.isSignedOut)
            }
        }
    }

    private var kindFilter: some View {
        Menu {
            Button {
                model.kindFilter = nil
            } label: {
                Label("All Collections", systemImage: model.kindFilter == nil ? "checkmark" : "square.stack.3d.up")
            }
            Button {
                model.kindFilter = .playlist
            } label: {
                Label("Playlists", systemImage: model.kindFilter == .playlist ? "checkmark" : "music.note.list")
            }
            Button {
                model.kindFilter = .album
            } label: {
                Label("Albums", systemImage: model.kindFilter == .album ? "checkmark" : "square.stack")
            }
        } label: {
            Image(systemName: model.kindFilter == nil
                ? "line.3.horizontal.decrease"
                : "line.3.horizontal.decrease.circle.fill")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(model.kindFilter == nil ? Color.primary.opacity(0.85) : Color.accentColor)
            .frame(width: 30, height: 30)
            .background(Color.primary.opacity(model.kindFilter == nil ? 0.08 : 0.13), in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(model.kindFilter.map { "Showing \($0.noun)s only" } ?? "Filter by kind")
        .accessibilityLabel("Collection filter: \(filterLabel)")
    }

    private var filterLabel: String {
        switch model.kindFilter {
        case .playlist: "Playlists"
        case .album: "Albums"
        case nil: "All"
        }
    }

    private var searchField: some View {
        HStack(spacing: SCContentStyle.mac.spaceTight) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
            TextField("Find in \(scope.title)", text: $model.searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.08), in: Capsule())
        .frame(minWidth: 180, idealWidth: 280, maxWidth: 360)
    }

    @ViewBuilder
    private var content: some View {
        if credentials.isSignedOut {
            MacSignedOutEmptyState(
                title: "Playlists Need an Account",
                message: "Sign in to see the playlists you've made and liked. Search works without an account.",
                browsableRoute: .search
            )
            .frame(maxWidth: .infinity, minHeight: 300)
        } else if model.isLoading, model.liked.isEmpty, model.mine.isEmpty {
            HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 80)
        } else if let error = model.errorMessage, model.liked.isEmpty, model.mine.isEmpty {
            SCEmptyState(
                kind: .error,
                title: "Couldn\u{2019}t Load Playlists",
                message: error,
                actionTitle: "Try Again",
                action: { model.load(currentUserId: credentials.currentUser?.id, isSignedOut: credentials.isSignedOut) },
                style: .mac
            )
            .frame(maxWidth: .infinity, minHeight: 300)
        } else if scopedLiked.isEmpty, scopedMine.isEmpty {
            SCEmptyState(
                icon: "music.note.list",
                title: model.searchText.isEmpty ? "No Playlists" : "No Results",
                message: model.searchText.isEmpty ? "Playlists you make or like on SoundCloud show up here." : "Nothing matched \u{201C}\(model.searchText)\u{201D}.",
                actionTitle: model.searchText.isEmpty ? nil : "Clear Search",
                action: model.searchText.isEmpty ? nil : { model.searchText = "" },
                style: .mac
            )
            .frame(maxWidth: .infinity, minHeight: 300)
        } else {
            VStack(alignment: .leading, spacing: SCContentStyle.mac.spaceSection) {
                if !scopedMine.isEmpty {
                    section(title: scope == .all ? "My Playlists" : nil, playlists: scopedMine)
                }
                if !scopedLiked.isEmpty {
                    section(title: scope == .all ? "Liked Playlists" : nil, playlists: scopedLiked)
                }
            }
        }
    }

    private var scopedMine: [Playlist] {
        scope == .liked ? [] : model.filteredMine
    }

    private var scopedLiked: [Playlist] {
        scope == .mine ? [] : model.filteredLiked
    }

    private func section(title: String?, playlists: [Playlist]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                SCSectionHeader(title: title, style: .mac)
            }

            let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 20)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                ForEach(playlists) { playlist in
                    NavigationLink(value: playlist) {
                        MacPlaylistCard(playlist: playlist)
                    }
                    .buttonStyle(.plain)
                    .macHoverLift()
                    .contextMenu {
                        MacPlaylistContextMenu(
                            playlist: playlist,
                            canChangePrivacy: credentials.currentUser?.id == playlist.user.id,
                            isUpdatingPrivacy: model.updatingPlaylistIDs.contains(playlist.id),
                            onTogglePrivacy: { model.togglePrivacy(playlist) }
                        )
                    }
                }
            }
        }
    }
}

struct MacPlaylistCard: View {
    let playlist: Playlist

    var body: some View {
        SCCollectionArtworkResolver(
            artworkURL: playlist.artworkURL,
            trackArtworkURLs: (playlist.tracks ?? []).compactMap(\.artworkURL)
        ) { image in
            SCMediaCard(
                title: playlist.title,
                subtitle: playlist.user.displayName,
                artworkImage: image,
                crownUser: playlist.user,
                crownContext: playlist.title,
                style: .mac
            )
        }
    }
}

/// Consistent whole-card actions for playlist grids, search results and
/// profile pages. Keeping navigation in the menu is useful when a card is
/// partially obscured or the user is working primarily with right-click.
struct MacPlaylistContextMenu: View {
    let playlist: Playlist
    var canChangePrivacy = false
    var isUpdatingPrivacy = false
    var onTogglePrivacy: (() -> Void)?

    var body: some View {
        Button {
            MacRootSelection.shared.request(playlist: playlist)
        } label: {
            Label(playlist.isAlbum ? "Go to Album" : "Go to Playlist", systemImage: "arrow.right.circle")
        }

        Divider()

        Button {
            NSWorkspace.shared.open(playlist.permalinkURL)
        } label: {
            Label("Open on SoundCloud", systemImage: "safari")
        }

        Button {
            macCopySoundCloudLink(playlist.permalinkURL)
        } label: {
            Label("Copy SoundCloud Link", systemImage: "link")
        }

        ShareLink(item: playlist.permalinkURL, subject: Text(playlist.title)) {
            Label("Share", systemImage: "square.and.arrow.up")
        }

        if canChangePrivacy, let onTogglePrivacy {
            Divider()
            Button(action: onTogglePrivacy) {
                Label(
                    playlist.sharing == "private" ? "Make Public" : "Make Private",
                    systemImage: playlist.sharing == "private" ? "globe" : "lock"
                )
            }
            .disabled(isUpdatingPrivacy)
        }
    }
}

struct MacArtistContextMenu: View {
    let artist: User

    var body: some View {
        Button {
            MacRootSelection.shared.request(artist: artist)
        } label: {
            Label("Go to Profile", systemImage: "person.crop.circle")
        }

        Divider()

        Button {
            MacMessageComposer.shared.present(user: artist)
        } label: {
            Label("Message", systemImage: "envelope")
        }

        Button {
            NSWorkspace.shared.open(artist.permalinkURL)
        } label: {
            Label("Open on SoundCloud", systemImage: "safari")
        }

        Button {
            macCopySoundCloudLink(artist.permalinkURL)
        } label: {
            Label("Copy SoundCloud Link", systemImage: "link")
        }

        ShareLink(item: artist.permalinkURL, subject: Text(artist.displayName)) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }
}

private func macCopySoundCloudLink(_ url: URL) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url.absoluteString, forType: .string)
}

enum MacCoverArt {
    static func load(_ candidates: [URL]) async -> NSImage? {
        for url in candidates.prefix(4) {
            if let image = await ArtworkCache.shared.image(for: url, variant: .standard) {
                return image
            }
        }
        return nil
    }
}

enum MacPlaylistKind: Equatable {
    case playlist
    case album

    var noun: String { self == .playlist ? "Playlist" : "Album" }
}

@MainActor
final class MacPlaylistsModel: ObservableObject {
    @Published private(set) var liked: [Playlist] = []
    @Published private(set) var mine: [Playlist] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published var searchText = ""
    @Published var kindFilter: MacPlaylistKind?
    @Published private(set) var updatingPlaylistIDs: Set<String> = []

    private var loadTask: Task<Void, Never>?
    private let cache = LibraryCache.shared

    var filteredLiked: [Playlist] { filter(liked) }
    var filteredMine: [Playlist] { filter(mine) }

    private func filter(_ playlists: [Playlist]) -> [Playlist] {
        var result = playlists
        if let kindFilter {
            result = result.filter { ($0.isAlbum ? MacPlaylistKind.album : .playlist) == kindFilter }
        }
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return result }
        return result.filter { $0.title.localizedCaseInsensitiveContains(needle) }
    }

    func load(currentUserId: String?, isSignedOut: Bool) {
        loadTask?.cancel()
        guard !isSignedOut else {
            liked = []
            mine = []
            errorMessage = nil
            return
        }
        loadTask = Task {
            isLoading = true
            defer { isLoading = false }
            // Keep the last complete local snapshot on screen while the
            // account endpoints refresh their first page.
            let cachedLiked = await cachedPlaylists(in: "LikedPlaylists")
            let cachedMine = await cachedPlaylists(in: "OwnedPlaylists")
            if !cachedLiked.isEmpty { liked = cachedLiked }
            if !cachedMine.isEmpty { mine = cachedMine }
            do {
                let likedResult = try await SoundCloudAPI.shared.getLikedPlaylists(limit: 50)
                guard !Task.isCancelled else { return }
                liked = (likedResult.collection + liked).deduplicatedByID()
                errorMessage = nil
                if let currentUserId {
                    let mineResult = try await SoundCloudAPI.shared.getUserPlaylists(userId: currentUserId, limit: 50)
                    guard !Task.isCancelled else { return }
                    var mineCursor = mineResult
                    var pageCount = 1
                    mine = (mineResult.collection + mine).deduplicatedByID()
                    while mineCursor.nextHref != nil, !Task.isCancelled, pageCount < 50 {
                        try? await Task.sleep(for: .milliseconds(300))
                        mineCursor = try await SoundCloudAPI.shared.getNextPage(mineCursor)
                        mine.appendUnique(contentsOf: mineCursor.collection)
                        pageCount += 1
                    }
                }

                var likedCursor = likedResult
                var pageCount = 1
                while likedCursor.nextHref != nil, !Task.isCancelled, pageCount < 50 {
                    try? await Task.sleep(for: .milliseconds(300))
                    likedCursor = try await SoundCloudAPI.shared.getNextPage(likedCursor)
                    liked.appendUnique(contentsOf: likedCursor.collection)
                    pageCount += 1
                }
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func togglePrivacy(_ playlist: Playlist) {
        guard !updatingPlaylistIDs.contains(playlist.id) else { return }
        updatingPlaylistIDs.insert(playlist.id)
        Task {
            defer { updatingPlaylistIDs.remove(playlist.id) }
            do {
                let updated = try await SoundCloudAPI.shared.setPlaylistSharing(
                    playlist.sharing == "private" ? "public" : "private",
                    playlistId: playlist.id
                )
                mine = mine.map { $0.id == updated.id ? updated : $0 }
                liked = liked.map { $0.id == updated.id ? updated : $0 }
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func cachedPlaylists(in section: String) async -> [Playlist] {
        let rows = await cache.loadSection(section)
        let decoder = LikesSyncEngine.makeDecoder()
        return rows.compactMap { try? decoder.decode(Playlist.self, from: $0.payload) }
    }

}
