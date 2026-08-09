import SwiftUI

struct ArtistDetailView: View {
    let user: User
    @StateObject private var viewModel: ArtistDetailViewModel
    @State private var activitySection: ArtistDetailSection = .reposts

    init(user: User) {
        self.user = user
        _viewModel = StateObject(wrappedValue: ArtistDetailViewModel(user: user))
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: SCBrowseMetrics.shelfGap) {
                header
                primaryMusic
                soundCloudActivity
            }
            .padding(.top, SCBrowseMetrics.contentTopInset)
            .padding(.horizontal, SCBrowseMetrics.pageInset)
            .padding(.bottom, Space.page)
        }
        .background { BrowseBackdrop() }
        .scrollClipDisabled()
        .task { await viewModel.loadOverviewIfNeeded() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Space.roomy) {
            ArtworkImage(url: user.largeAvatarURL ?? user.avatarURL) {
                Circle().fill(Color.white.opacity(0.06))
            }
            .frame(width: 230, height: 230)
            .clipShape(Circle())
            .kyleCrowned(user: user, context: user.displayName)

            VStack(alignment: .leading, spacing: Space.tight) {
                Text("ARTIST")
                    .font(.tvEyebrow)
                    .foregroundStyle(Color.scAccent)

                Text(user.displayName)
                    .font(.tvDisplay)
                    .foregroundStyle(Color.scTextPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                    .frame(maxWidth: 1080, alignment: .leading)

                Text("\(user.formattedFollowers) followers  ·  \(user.formattedTracks) tracks")
                    .font(.tvBody)
                    .foregroundStyle(Color.scTextSecondary)
                    .monospacedDigit()

                if let description = user.description, !description.isEmpty {
                    Text(description)
                        .font(.tvCallout)
                        .foregroundStyle(Color.scTextTertiary)
                        .lineLimit(2)
                        .frame(maxWidth: 1000, alignment: .leading)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: Space.snug) {
                Button {
                    Task { await PlayActions.play(tracks: viewModel.tracks) }
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(.white)
                .foregroundStyle(.black)

                Button {
                    Task { await PlayActions.shufflePlay(tracks: viewModel.tracks) }
                } label: {
                    Image(systemName: "shuffle")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .tint(.white)
            }
            .disabled(viewModel.tracks.isEmpty)
            .focusSection()
        }
    }

    @ViewBuilder
    private var primaryMusic: some View {
        if viewModel.isLoading(.tracks), viewModel.tracks.isEmpty {
            TVDetailStatusRow(title: "Loading music…")
        } else if let error = viewModel.errorMessage(.tracks), viewModel.tracks.isEmpty {
            StatusPanel(
                kind: .error,
                title: "Couldn't load this artist",
                message: error,
                actionTitle: "Try Again",
                action: { Task { await viewModel.reload(section: .tracks) } },
                minHeight: 300
            )
        } else {
            if !viewModel.tracks.isEmpty {
                VStack(alignment: .leading, spacing: SCBrowseMetrics.headerGap) {
                    SCSectionHeader(title: "Top Tracks", style: SCBrowseMetrics.header)
                    TVDetailTrackList(
                        tracks: viewModel.tracks,
                        showArtist: false,
                        maximumCount: 6,
                        onNearEnd: nil
                    )
                }
            }

            let albums = viewModel.playlists.filter(\.isAlbum)
            if !albums.isEmpty {
                ArtistCollectionShelf(title: "Albums", playlists: albums)
            }

            let playlists = viewModel.playlists.filter { !$0.isAlbum }
            if !playlists.isEmpty {
                ArtistCollectionShelf(title: "Playlists", playlists: playlists)
            }
        }
    }

    private var soundCloudActivity: some View {
        VStack(alignment: .leading, spacing: SCBrowseMetrics.headerGap) {
            SCSectionHeader(title: "From SoundCloud", style: SCBrowseMetrics.header)

            HStack(spacing: Space.snug) {
                activityButton(.reposts, icon: "arrow.2.squarepath")
                activityButton(.likes, icon: "heart")
            }
            .focusSection()

            activityContent
        }
    }

    private func activityButton(_ section: ArtistDetailSection, icon: String) -> some View {
        Button {
            activitySection = section
            viewModel.selectedSection = section
            Task { await viewModel.loadIfNeeded() }
        } label: {
            Label(section.rawValue, systemImage: icon)
                .frame(minWidth: 180)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(activitySection == section ? .white : Color.scBgRaised)
        .foregroundStyle(activitySection == section ? Color.black : Color.white)
    }

    @ViewBuilder
    private var activityContent: some View {
        if viewModel.isLoading(activitySection) {
            TVDetailStatusRow(title: "Loading \(activitySection.rawValue.lowercased())…")
        } else if let error = viewModel.errorMessage(activitySection) {
            StatusPanel(
                kind: .error,
                title: "Couldn't load \(activitySection.rawValue.lowercased())",
                message: error,
                actionTitle: "Try Again",
                action: { Task { await viewModel.reload(section: activitySection) } },
                minHeight: 260
            )
        } else {
            switch activitySection {
            case .reposts:
                if viewModel.repostedTracks.isEmpty, viewModel.repostedPlaylists.isEmpty {
                    TVDetailStatusRow(title: "No public reposts", icon: "arrow.2.squarepath")
                } else {
                    if !viewModel.repostedPlaylists.isEmpty {
                        ArtistCollectionShelf(title: "Reposted Playlists", playlists: viewModel.repostedPlaylists)
                    }
                    if !viewModel.repostedTracks.isEmpty {
                        TVDetailTrackList(
                            tracks: viewModel.repostedTracks,
                            maximumCount: 8,
                            onNearEnd: { Task { await viewModel.loadMore(section: .reposts) } },
                            isLoadingMore: viewModel.loadingMore.contains(.reposts)
                        )
                    }
                }
            case .likes:
                if viewModel.likedTracks.isEmpty {
                    TVDetailStatusRow(title: "No public likes", icon: "heart")
                } else {
                    TVDetailTrackList(
                        tracks: viewModel.likedTracks,
                        maximumCount: 8,
                        onNearEnd: { Task { await viewModel.loadMore(section: .likes) } },
                        isLoadingMore: viewModel.loadingMore.contains(.likes)
                    )
                }
            case .tracks, .playlists:
                EmptyView()
            }
        }
    }
}

private struct ArtistCollectionShelf: View {
    let title: String
    let playlists: [Playlist]

    var body: some View {
        VStack(alignment: .leading, spacing: SCBrowseMetrics.headerGap) {
            SCSectionHeader(title: title, style: SCBrowseMetrics.header)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: SCBrowseMetrics.gutter) {
                    ForEach(playlists) { playlist in
                        NavigationLink {
                            PlaylistDetailView(playlist: playlist)
                        } label: {
                            SCArtworkResolver(url: playlist.largeDisplayArtworkURL) { image in
                                SCMediaCard(
                                    title: playlist.title,
                                    subtitle: playlist.isAlbum ? playlist.user.displayName : "Playlist",
                                    artworkImage: image,
                                    crownUser: playlist.user,
                                    crownContext: playlist.title,
                                    style: SCBrowseMetrics.tile
                                )
                            }
                            .frame(width: SCBrowseMetrics.tileEdge)
                        }
                    }
                }
            }
            .scrollClipDisabled()
            .buttonStyle(SCCardButtonStyle(cornerRadius: Corner.control, sizeClass: .tile))
            .focusEffectDisabled()
            .prefetchArtwork(playlists.compactMap(\.largeDisplayArtworkURL))
        }
    }
}
