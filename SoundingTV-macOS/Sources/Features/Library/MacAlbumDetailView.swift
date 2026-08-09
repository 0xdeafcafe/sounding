import SwiftUI

struct MacAlbumDetailView: View {
    let album: Playlist

    var body: some View {
        MacCollectionDetailView(playlist: album, kind: .album)
    }
}

struct MacAlbumsPane: View {
    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    @ObservedObject private var model: MacAlbumsPaneModel

    init(model: MacAlbumsPaneModel) {
        self.model = model
    }

    var body: some View {
        Group {
            if credentials.isSignedOut {
                MacSignedOutEmptyState(
                    icon: "person.crop.circle.badge.questionmark",
                    title: "Albums Need an Account",
                    message: "Albums you\u{2019}ve liked need an account. Search works without one.",
                    browsableRoute: .search
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.isLoading && model.albums.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.errorMessage, model.albums.isEmpty {
                SCEmptyState(
                    kind: .error,
                    title: model.availability == .subscriptionRequired ? "Albums Need a SoundCloud Plan" : "Albums Unavailable",
                    message: error,
                    actionTitle: "Try Again",
                    action: {
                        let credentials = credentials
                        Task { await model.load(credentials: credentials, force: true) }
                    },
                    style: .mac
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.albums.isEmpty {
                SCEmptyState(
                    icon: "square.stack",
                    title: "No Albums Yet",
                    message: "Like an album on SoundCloud and it\u{2019}ll appear here.",
                    actionTitle: "Find Albums",
                    action: { MacRootSelection.shared.request(.search) },
                    style: .mac
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        MacPaneHeader(
                            title: "Albums",
                            subtitle: "\(model.albums.count) album\(model.albums.count == 1 ? "" : "s")"
                        )
                        grid
                            .padding(.horizontal, SCContentStyle.mac.spaceGutter)
                            .padding(.bottom, 32)
                    }
                }
            }
        }
        .task { await model.load(credentials: credentials) }
        .onChange(of: credentials.isSignedOut) { _, isSignedOut in
            guard !isSignedOut else { return }
            let credentials = credentials
            Task { await model.load(credentials: credentials, force: true) }
        }
    }

    private var grid: some View {
        let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: SCContentStyle.mac.spaceRoomy)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            ForEach(model.albums) { album in
                NavigationLink(value: album) {
                    SCCollectionArtworkResolver(
                        artworkURL: album.displayArtworkURL,
                        trackArtworkURLs: (album.tracks ?? []).compactMap(\.artworkURL)
                    ) { image in
                        SCMediaCard(
                            title: album.title,
                            subtitle: album.user.displayName,
                            artworkImage: image,
                            crownUser: album.user,
                            crownContext: album.title,
                            style: .mac
                        )
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .macHoverLift()
            }
        }
    }
}

@MainActor
final class MacAlbumsPaneModel: ObservableObject {
    enum Availability: Equatable {
        case loading
        case available
        case empty
        case subscriptionRequired
        case unavailable
    }

    @Published private(set) var albums: [Playlist] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var availability: Availability = .loading

    private var hasLoaded = false
    private let cache = LibraryCache.shared

    func load(credentials: SoundCloudCredentialSource, force: Bool = false) async {
        if hasLoaded, !force { return }
        guard !credentials.isSignedOut else { return }
        isLoading = true
        errorMessage = nil
        availability = .loading
        defer { isLoading = false }

        // The metadata index survives launches and is more representative than
        // the first page of SoundCloud's generic, recency-sorted library feed.
        // Showing it immediately also avoids a false empty state while online
        // refreshes are still in flight.
        let cached = await cachedAlbums()
        merge(cached)

        guard let user = await credentials.waitForCurrentUser() else {
            if albums.isEmpty {
                availability = .unavailable
                errorMessage = "Your SoundCloud account details are not available yet. Try syncing, then try again."
            } else {
                availability = .available
            }
            return
        }
        // Albums are represented by SoundCloud as playlists with
        // `is_album == true`. Playlist likes are the authoritative source;
        // the library feed and the user's collections fill in saved/owned
        // albums without inventing album groupings from track metadata.
        var completedSourceCount = 0
        var remoteAlbums: [Playlist] = []
        var errors: [Error] = []

        do {
            let liked = try await collectPages(
                first: { try await SoundCloudAPI.shared.getLikedPlaylists(limit: 100) }
            )
            let albums = liked.filter(\.isAlbum)
            remoteAlbums += albums
            await persistAlbums(albums, section: "LikedAlbums")
            completedSourceCount += 1
        } catch {
            errors.append(error)
        }

        do {
            let saved = try await collectPages(
                first: { try await SoundCloudAPI.shared.getLibrary(limit: 100) }
            )
            let savedAlbums = saved.compactMap(\.playlist).filter(\.isAlbum)
            remoteAlbums += savedAlbums
            await persistAlbums(savedAlbums, section: "LibraryAlbums")
            completedSourceCount += 1
        } catch {
            errors.append(error)
        }

        do {
            let owned = try await collectPages(
                first: { try await SoundCloudAPI.shared.getUserPlaylists(userId: user.id, limit: 100) }
            )
            let albums = owned.filter(\.isAlbum)
            remoteAlbums += albums
            await persistAlbums(albums, section: "OwnedAlbums")
            completedSourceCount += 1
        } catch {
            errors.append(error)
        }

        // Cached albums remain useful offline; only replace the page with an
        // error when no source could provide a meaningful snapshot.
        if completedSourceCount == 3 {
            // Only a complete snapshot is allowed to replace cache data. This
            // is what makes an empty state trustworthy rather than a transient
            // result from a partially unavailable SoundCloud response.
            albums = deduplicated(remoteAlbums)
            hasLoaded = true
            availability = albums.isEmpty ? .empty : .available
        } else if !albums.isEmpty {
            hasLoaded = true
            availability = .available // cached metadata remains browsable offline
        } else if errors.contains(where: Self.isSubscriptionError) {
            hasLoaded = false
            availability = .subscriptionRequired
            errorMessage = "SoundCloud did not make album metadata available for this account. Check your SoundCloud plan, then try again."
        } else if completedSourceCount > 0 {
            hasLoaded = false
            availability = .unavailable
            errorMessage = "SoundCloud only returned part of your album metadata. Try again when all library sources are available."
        } else {
            hasLoaded = false
            availability = .unavailable
            errorMessage = errors.last?.localizedDescription
                ?? "SoundCloud could not provide your album metadata."
        }
    }

    private func cachedAlbums() async -> [Playlist] {
        let decoder = LikesSyncEngine.makeDecoder()
        var cached: [Playlist] = []

        for section in ["LikedAlbums", "LibraryAlbums", "OwnedAlbums", "Playlists"] {
            let rows = await cache.loadSection(section)
            cached += rows.compactMap { try? decoder.decode(Playlist.self, from: $0.payload) }
        }

        let recentRows = await cache.loadSection("RecentlyAdded")
        let recentItems = recentRows.compactMap { try? decoder.decode(LibraryItem.self, from: $0.payload) }
        cached += recentItems.compactMap(\.playlist)
        return cached.filter(\.isAlbum)
    }

    private func collectPages<T: Codable>(
        first: () async throws -> Page<T>
    ) async throws -> [T] {
        var page = try await first()
        var values = page.collection
        while page.nextHref != nil, !Task.isCancelled {
            page = try await SoundCloudAPI.shared.getNextPage(page)
            values.append(contentsOf: page.collection)
        }
        return values
    }

    private func merge(_ incoming: [Playlist]) {
        albums = deduplicated(albums + incoming)
    }

    private func deduplicated(_ values: [Playlist]) -> [Playlist] {
        var seen = Set<String>()
        return values.filter(\.isAlbum).filter { seen.insert($0.id).inserted }
    }

    private func persistAlbums(_ values: [Playlist], section: String) async {
        let encoder = LikesSyncEngine.makeEncoder()
        let rows = values.compactMap { album -> LibraryCache.WriteRow? in
            guard let payload = try? encoder.encode(album) else { return nil }
            return LibraryCache.WriteRow(id: album.id, payload: payload)
        }
        await cache.replaceSection(section, rows: rows)
    }

    private static func isSubscriptionError(_ error: Error) -> Bool {
        if case APIError.unauthorized = error { return true }
        if case APIError.serverError(let status) = error, status == 401 || status == 403 { return true }
        let message = error.localizedDescription.lowercased()
        return message.contains("subscription") || message.contains("soundcloud go") || message.contains("forbidden")
    }
}

/// A metadata-only lens over liked tracks. Sets are deliberately generated
/// locally rather than represented as fabricated SoundCloud playlists.
struct MacSetsPane: View {
    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    @ObservedObject private var model: MacLibraryModel
    @ObservedObject private var settings = SettingsStore.shared

    init(model: MacLibraryModel) {
        self.model = model
    }

    private var setTracks: [Track] {
        GeneratedLibraryCollections.sets(
            from: model.tracks,
            minimumDuration: settings.setMinimumDurationSeconds
        )
    }

    private var rows: [LibraryRow] {
        setTracks.map { LibraryRow(track: $0, analysis: model.analysis[$0.id]) }
    }

    var body: some View {
        Group {
            if credentials.isSignedOut {
                MacSignedOutEmptyState(
                    icon: "clock.arrow.2.circlepath",
                    title: "Sets Need an Account",
                    message: "Long-form tracks from your likes appear here after you sign in.",
                    browsableRoute: .search
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.isLoading && model.tracks.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.errorMessage, model.tracks.isEmpty {
                SCEmptyState(
                    kind: .error,
                    title: "Sets Unavailable",
                    message: error,
                    actionTitle: "Try Again",
                    action: { model.load(currentUserId: credentials.currentUser?.id, isSignedOut: credentials.isSignedOut) },
                    style: .mac
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                SCEmptyState(
                    icon: "clock.arrow.2.circlepath",
                    title: "No Sets Yet",
                    message: "Sets are saved tracks lasting \(GeneratedLibraryCollections.durationLabel(settings.setMinimumDurationSeconds)) or more.",
                    style: .mac
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MacLibraryTable(
                    rows: rows,
                    showsArtwork: true,
                    usesCompactRows: false,
                    onLoad: { track, deck in
                        Task { try? await MacMixLoader.load(track, into: deck) }
                    },
                    onDoubleClick: { track in
                        Task { try? await MacMixLoader.load(track, into: MacDeckTrackRegistry.shared.nextAvailableDeck()) }
                    },
                    onAnalysisChanged: { Task { await model.refreshAnalysis(rereadStore: false) } }
                )
            }
        }
        .navigationTitle("Sets")
        .task {
            if model.tracks.isEmpty {
                model.load(currentUserId: credentials.currentUser?.id, isSignedOut: credentials.isSignedOut)
            }
        }
    }
}
