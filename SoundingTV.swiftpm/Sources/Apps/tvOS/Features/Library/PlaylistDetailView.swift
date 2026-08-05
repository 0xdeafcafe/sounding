import SwiftUI

struct PlaylistDetailView: View {
    @StateObject private var viewModel: PlaylistDetailViewModel
    @State private var isShowingCollectionPolicy = false

    init(playlist: Playlist) {
        _viewModel = StateObject(wrappedValue: PlaylistDetailViewModel(playlist: playlist))
    }

    var body: some View {
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 72) {
                artworkColumn
                    .frame(width: 610)

                contentColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, SCBrowseMetrics.contentTopInset)
            .padding(.horizontal, SCBrowseMetrics.pageInset)
            .padding(.bottom, Space.page)
        }
        .background { BrowseBackdrop() }
        .scrollClipDisabled()
        .task { await viewModel.loadIfNeeded() }
        .task(id: viewModel.tracks.map(\.id)) {
            DownloadManager.shared.applyCollectionPolicy(
                tracks: viewModel.tracks,
                collectionId: viewModel.playlist.id
            )
        }
        .sheet(isPresented: $isShowingCollectionPolicy) {
            CollectionPolicyEditor(
                collectionId: viewModel.playlist.id,
                collectionName: viewModel.playlist.title,
                collectionKind: CollectionKind.classify(playlist: viewModel.playlist),
                tracks: viewModel.tracks,
                applier: DownloadManager.shared
            )
        }
    }

    private var artworkColumn: some View {
        VStack(alignment: .leading, spacing: Space.base) {
            ArtworkImage(
                url: viewModel.playlist.largeArtworkURL ?? viewModel.playlist.artworkURL,
                variant: .hero,
                icon: viewModel.playlist.isAlbum ? "square.stack" : "music.note.list"
            )
            .frame(width: 610, height: 610)
            .clipShape(RoundedRectangle(cornerRadius: Corner.card, style: .continuous))
            .kyleCrowned(user: viewModel.playlist.user, context: viewModel.playlist.title)

            if let description = viewModel.playlist.description, !description.isEmpty {
                Text(description)
                    .font(.tvCallout)
                    .foregroundStyle(Color.scTextSecondary)
                    .lineLimit(5)
                    .frame(maxWidth: 580, alignment: .leading)
            }
        }
    }

    private var contentColumn: some View {
        VStack(alignment: .leading, spacing: Space.roomy) {
            metadata
            actionRow
                .focusSection()
            trackSection
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: Space.tight) {
            Text(viewModel.playlist.isAlbum ? "ALBUM" : "PLAYLIST")
                .font(.tvEyebrow)
                .foregroundStyle(Color.scAccent)

            Text(viewModel.playlist.title)
                .font(.tvLargeTitle)
                .foregroundStyle(Color.scTextPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: 940, alignment: .leading)

            Text(viewModel.playlist.user.displayName)
                .font(.tvHeadline)
                .foregroundStyle(Color.scTextSecondary)
                .lineLimit(1)

            Text(metadataLine)
                .font(.tvCallout)
                .foregroundStyle(Color.scTextTertiary)
                .monospacedDigit()
        }
    }

    private var metadataLine: String {
        let count = viewModel.playlist.totalTrackCount
        return "\(count) \(count == 1 ? "track" : "tracks")  ·  \(viewModel.playlist.formattedDuration)"
    }

    private var actionRow: some View {
        HStack(spacing: Space.snug) {
            Button {
                Task { await PlayActions.play(tracks: viewModel.tracks, collectionId: viewModel.playlist.id) }
            } label: {
                Label("Play", systemImage: "play.fill")
                    .frame(minWidth: 132)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(.white)
            .foregroundStyle(.black)

            Button {
                Task { await PlayActions.shufflePlay(tracks: viewModel.tracks, collectionId: viewModel.playlist.id) }
            } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .frame(minWidth: 150)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(.white)

            Button {
                isShowingCollectionPolicy = true
            } label: {
                Label("Collection Settings", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(.white)
        }
        .disabled(viewModel.tracks.isEmpty)
    }

    @ViewBuilder
    private var trackSection: some View {
        if viewModel.isLoading, viewModel.tracks.isEmpty {
            TVDetailStatusRow(title: "Loading tracks…")
        } else if let error = viewModel.errorMessage, viewModel.tracks.isEmpty {
            StatusPanel(
                kind: .error,
                title: "Couldn't load this \(viewModel.playlist.isAlbum ? "album" : "playlist")",
                message: error,
                actionTitle: "Try Again",
                action: { Task { await viewModel.load() } },
                minHeight: 300
            )
        } else if viewModel.tracks.isEmpty {
            TVDetailStatusRow(title: "No tracks", icon: "music.note.list")
        } else {
            TVDetailTrackList(
                tracks: viewModel.tracks,
                collectionId: viewModel.playlist.id,
                showArtist: !viewModel.playlist.isAlbum,
                onNearEnd: { Task { await viewModel.loadMore() } },
                isLoadingMore: viewModel.isLoadingMore
            )
        }
    }
}

struct TVDetailTrackList: View {
    let tracks: [Track]
    var collectionId: String? = nil
    var showArtist = true
    var maximumCount: Int?
    var onNearEnd: (() -> Void)?
    var isLoadingMore = false

    @EnvironmentObject private var playerService: PlayerService

    private var visibleTracks: [Track] {
        maximumCount.map { Array(tracks.prefix($0)) } ?? tracks
    }

    var body: some View {
        LazyVStack(spacing: Space.hair) {
            ForEach(Array(visibleTracks.enumerated()), id: \.element.id) { index, track in
                Button {
                    Task { await playerService.play(track, in: tracks, collectionId: collectionId) }
                } label: {
                    TVDetailTrackRow(track: track, number: index + 1, showArtist: showArtist)
                }
                .buttonStyle(SCPlainButtonStyle())
                .focusEffectDisabled()
                .disabled(track.streamURL == nil)
                .onAppear {
                    guard let onNearEnd, tracks.isNearEnd(track, lead: 6) else { return }
                    onNearEnd()
                }
            }

            if isLoadingMore {
                LoadingMoreRow()
                    .frame(maxWidth: .infinity)
            }
        }
        .focusSection()
    }
}

private struct TVDetailTrackRow: View {
    let track: Track
    let number: Int
    let showArtist: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        HStack(spacing: Space.snug) {
            Text("\(number)")
                .font(.tvCaption)
                .foregroundStyle(isFocused ? Color.black.opacity(0.55) : Color.scTextTertiary)
                .monospacedDigit()
                .frame(width: 42, alignment: .trailing)

            VStack(alignment: .leading, spacing: Space.hair) {
                Text(track.title)
                    .font(.tvBodyEmph)
                    .foregroundStyle(isFocused ? Color.black : Color.scTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if showArtist {
                    Text(track.user.displayName)
                        .font(.tvCaption)
                        .foregroundStyle(isFocused ? Color.black.opacity(0.62) : Color.scTextSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: Space.base)

            if track.streamURL == nil {
                Image(systemName: "lock.fill")
                    .font(.tvCaption)
                    .foregroundStyle(isFocused ? Color.black.opacity(0.55) : Color.scTextTertiary)
            } else {
                Text(track.formattedDuration)
                    .font(.tvCaption)
                    .foregroundStyle(isFocused ? Color.black.opacity(0.55) : Color.scTextTertiary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, Space.snug)
        .frame(height: showArtist ? 88 : 76)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isFocused ? Color.white : Color.white.opacity(number.isMultiple(of: 2) ? 0.035 : 0),
            in: RoundedRectangle(cornerRadius: Corner.control, style: .continuous)
        )
        .opacity(track.streamURL == nil ? 0.5 : 1)
        .animation(.quickSpring, value: isFocused)
    }
}

struct TVDetailStatusRow: View {
    let title: String
    var icon = "hourglass"

    var body: some View {
        HStack(spacing: Space.snug) {
            if icon == "hourglass" {
                ProgressView()
            } else {
                Image(systemName: icon)
            }
            Text(title)
                .font(.tvBody)
                .foregroundStyle(Color.scTextSecondary)
        }
        .padding(.vertical, Space.roomy)
    }
}
