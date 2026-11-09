import SwiftUI

struct LibraryCollectionTVGrid: View {
    let items: [LibraryGridItem]
    var columns: Int = LibraryPageMetrics.embeddedColumns
    var emptyIcon = "square.stack"
    var emptyTitle = "Nothing here yet"

    var body: some View {
        if items.isEmpty {
            StatusPanel(kind: .empty, icon: emptyIcon, title: emptyTitle, minHeight: 320)
        } else {
            LazyVGrid(columns: LibraryPageMetrics.grid(columns), alignment: .leading, spacing: Space.section) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    LibraryCollectionCardLink(item: item)
                        .accessibilityIdentifier("library.collection.card.\(index)")
                }
            }
            .focusEffectDisabled()
            .prefetchArtwork(items.prefix(columns * 3).compactMap(\.artworkURL))
        }
    }
}

private struct LibraryCollectionCardLink: View {
    let item: LibraryGridItem

    var body: some View {
        if item.isCircular {
            link.buttonStyle(SCArtistCardButtonStyle())
        } else {
            link.buttonStyle(SCCardButtonStyle(cornerRadius: Corner.control, sizeClass: .tile))
        }
    }

    private var link: some View {
        NavigationLink {
            LibraryCollectionDestination(route: item.route)
        } label: {
            SCArtworkResolver(url: item.artworkURL) { image in
                if item.isCircular {
                    SCArtistCard(
                        name: item.title,
                        subtitle: item.subtitle,
                        avatarImage: image,
                        identity: item.id,
                        diameter: SCBrowseMetrics.tileEdge,
                        style: SCBrowseMetrics.tile
                    )
                    .frame(maxWidth: .infinity)
                } else {
                    SCMediaCard(
                        title: item.title,
                        subtitle: item.subtitle,
                        artworkImage: image,
                        artIdentity: item.id,
                        artSubject: .collection,
                        style: SCBrowseMetrics.tile
                    )
                }
            }
        }
        .accessibilityLabel("\(item.title), \(item.subtitle)")
    }
}

struct LibraryCollectionDestination: View {
    let route: LibraryCollectionRoute

    var body: some View {
        switch route {
        case .playlist(let playlist):
            PlaylistDetailView(playlist: playlist)
        case .local(let collection):
            TVLocalCollectionView(collection: collection)
        }
    }
}

struct TVLocalCollectionView: View {
    let collection: LocalCollection

    @ObservedObject private var remoteMusic = RemoteLocalMusic.shared
    @EnvironmentObject var playerService: PlayerService
    @StateObject private var analysis = TrackAnalysisStore()
    @FocusState private var focus: LocalFocus?

    private enum LocalFocus: Hashable {
        case play
    }

    private var playable: [Track] { collection.tracks.filter(remoteMusic.isAvailable) }
    private var isAlbum: Bool { collection.kind == .album }

    private var heroContent: CollectionHeroContent {
        CollectionHeroContent(
            id: collection.id,
            title: collection.title,
            subtitle: isAlbum ? collection.subtitle : nil,
            metadata: collection.metadataLine,
            artworkURL: collection.artworkURL
        )
    }

    var body: some View {
        ScrollView(.vertical) {
            CollectionColumnPage(content: heroContent, metrics: .tv, actions: { actionRow }) {
                ForEach(Array(collection.tracks.enumerated()), id: \.element.id) { index, track in
                    row(track, index: index)
                }
            } shelves: {
                if isAlbum {
                    CollectionReleaseFooter(
                        info: CollectionReleaseInfo(local: collection),
                        font: .tvCaption,
                        spacing: Space.hair
                    )
                    .padding(.horizontal, CollectionHeroMetrics.tv.horizontalInset)
                }
            }
        }
        .scrollClipDisabled()
        .ignoresSafeArea(edges: [.top, .horizontal])
        .foregroundStyle(Color.scTextPrimary)
        .collectionPageMesh(url: collection.artworkURL)
        .collectionAccent(from: collection.artworkURL)
        .defaultFocus($focus, .play)
        .onAppear { remoteMusic.refreshIfNeeded() }
        .task(id: collection.tracks.count) { await analysis.load(for: collection.tracks) }
    }

    private var actionRow: some View {
        HStack(spacing: Space.snug) {
            Button {
                Task { await PlayActions.play(tracks: playable) }
            } label: {
                TVGlassPillLabel(title: "Play", systemImage: "play.fill")
            }
            .buttonStyle(TVGlassPillStyle(isProminent: true))
            .focused($focus, equals: .play)
            .accessibilityIdentifier("library.local.play")

            Button {
                Task { await PlayActions.shufflePlay(tracks: playable) }
            } label: {
                TVGlassPillLabel(title: "Shuffle", systemImage: "shuffle")
            }
            .buttonStyle(TVGlassPillStyle())
            .accessibilityIdentifier("library.local.shuffle")
        }
        .padding(.top, Space.tight)
        .focusSection()
    }

    private func row(_ track: Track, index: Int) -> some View {
        var item = SCTrackListItem(
            track: track,
            number: index + 1,
            showsArtist: !isAlbum || track.user.displayName != collection.subtitle,
            analysis: analysis.summaries[track.id]
        )
        let available = remoteMusic.isAvailable(track)
        item.isPlayable = available
        return Button {
            guard available else { return }
            Task { await playerService.play(track, in: playable) }
        } label: {
            SCTrackListRow(
                item: item,
                leading: isAlbum ? .number : .artwork,
                activity: activity(for: track),
                metrics: .tv,
                crownUser: track.user
            )
        }
        .buttonStyle(TVCollectionRowStyle())
        .accessibilityLabel(item.accessibilityLabel)
        .accessibilityIdentifier("library.local.track.\(index)")
    }

    private func activity(for track: Track) -> SCTrackActivity {
        guard playerService.currentTrack?.id == track.id else { return .none }
        return playerService.isPlaying ? .playing : .paused
    }
}
