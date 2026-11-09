import SwiftUI

struct PlaylistDetailView: View {
    @StateObject private var model: CollectionPageModel
    @StateObject private var related = CollectionRelatedModel()
    @EnvironmentObject private var playerService: PlayerService
    @EnvironmentObject private var authService: AuthenticationService
    @EnvironmentObject private var navigationState: NavigationState
    @State private var isShowingCollectionPolicy = false
    @State private var openedPlaylist: Playlist?
    @State private var isShowingArtist = false
    @FocusState private var focus: CollectionFocus?

    private enum CollectionFocus: Hashable {
        case play
        case shuffle
    }

    init(playlist: Playlist) {
        _model = StateObject(wrappedValue: CollectionPageModel(playlist: playlist))
    }

    private var isOwnFiles: Bool { model.playlist.permalinkURL.isFileURL }

    private var artist: User { related.artist ?? model.artist }

    var body: some View {
        CollectionHeroPage(
            model: model,
            metrics: .tv,
            onSubtitle: isOwnFiles ? nil : { openArtist() },
            actions: { actionRow },
            row: { track, row in trackButton(track, row) },
            status: { status },
            footer: { footer },
            shelves: { shelves }
        )
        .scrollClipDisabled()
        .ignoresSafeArea(edges: [.top, .horizontal])
        .foregroundStyle(Color.scTextPrimary)
        .collectionPageMesh(url: model.artworkURL)
        .defaultFocus($focus, .play)
        .navigationDestination(item: $openedPlaylist) { PlaylistDetailView(playlist: $0) }
        .navigationDestination(isPresented: $isShowingArtist) {
            ArtistDetailView(user: artist)
        }
        .task(id: model.tracks.map(\.id)) {
            DownloadManager.shared.applyCollectionPolicy(tracks: model.tracks, collectionId: model.id)
        }
        .sheet(isPresented: $isShowingCollectionPolicy) {
            CollectionPolicyEditor(
                collectionId: model.id,
                collectionName: model.title,
                collectionKind: CollectionKind.classify(playlist: model.playlist),
                tracks: model.tracks,
                applier: DownloadManager.shared
            )
        }
    }

    private func openArtist() {
        if artist.id == authService.currentUser?.id {
            navigationState.showProfile()
        } else {
            isShowingArtist = true
        }
    }

    private var actionRow: some View {
        HStack(spacing: Space.snug) {
            Button {
                Task { await model.play() }
            } label: {
                TVGlassPillLabel(title: "Play", systemImage: "play.fill")
            }
            .buttonStyle(TVGlassPillStyle(isProminent: true))
            .focused($focus, equals: .play)
            .accessibilityIdentifier("collection.play")

            Button {
                Task { await model.shuffle() }
            } label: {
                TVGlassPillLabel(title: "Shuffle", systemImage: "shuffle")
            }
            .buttonStyle(TVGlassPillStyle())
            .focused($focus, equals: .shuffle)
            .accessibilityIdentifier("collection.shuffle")

            TVCollectionMoreMenu(
                playlist: model.playlist,
                settingsTitle: "\(model.kind.label) Settings",
                tracks: { model.tracks },
                showSettings: { isShowingCollectionPolicy = true }
            )
        }
        .padding(.top, Space.tight)
        .focusSection()
    }

    private func trackButton(_ track: Track, _ row: CollectionTrackRow) -> some View {
        Button {
            Task { await model.play(track) }
        } label: {
            SCTrackListRow(
                item: row,
                leading: .number,
                activity: activity(for: track),
                metrics: .tv
            )
        }
        .buttonStyle(TVCollectionRowStyle())
        .contextMenu { TVTrackMenuItems(track: track) }
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityIdentifier("collection.track.\(row.number - 1)")
        .prewarmPlaybackOnFocus(row.isPlayable ? track : nil)
    }

    private func activity(for track: Track) -> SCTrackActivity {
        guard playerService.currentTrack?.id == track.id else { return .none }
        return playerService.isPlaying ? .playing : .paused
    }

    @ViewBuilder
    private var shelves: some View {
        if !model.tracks.isEmpty, !model.pager.hasMore {
            collectionFooter
                .onAppear {
                    loadRelated(.artist)
                    loadRelated(.moreByArtist)
                }

            if !related.moreByArtist.isEmpty {
                CollectionShelf(
                    title: CollectionRelatedModel.moreTitle(for: artist),
                    items: related.moreByArtist,
                    style: SCBrowseMetrics.header,
                    tileWidth: SCBrowseMetrics.tileEdge,
                    spacing: SCBrowseMetrics.gutter,
                    inset: CollectionHeroMetrics.tv.horizontalInset,
                    headerAction: openArtist
                ) { playlist in
                    Button {
                        openedPlaylist = playlist
                    } label: {
                        ArtworkShelfCard(playlist: playlist, style: SCBrowseMetrics.tile)
                    }
                    .buttonStyle(SCCardButtonStyle(cornerRadius: Corner.control, sizeClass: .tile))
                    .focusEffectDisabled()
                }
                .prefetchArtwork(related.moreByArtist.compactMap(\.largeDisplayArtworkURL))
                .padding(.top, SCBrowseMetrics.shelfGap)
            }

            if !related.similar.isEmpty {
                CollectionShelf(
                    title: "You Might Also Like",
                    items: related.similar,
                    style: SCBrowseMetrics.header,
                    tileWidth: SCBrowseMetrics.tileEdge,
                    spacing: SCBrowseMetrics.gutter,
                    inset: CollectionHeroMetrics.tv.horizontalInset
                ) { track in
                    Button {
                        guard track.streamURL != nil else { return }
                        Task { await playerService.play(track, in: related.similar.filter { $0.streamURL != nil }) }
                    } label: {
                        ArtworkShelfCard(track: track, style: SCBrowseMetrics.tile)
                    }
                    .buttonStyle(SCCardButtonStyle(cornerRadius: Corner.control, sizeClass: .tile))
                    .focusEffectDisabled()
                    .prewarmPlaybackOnFocus(track.streamURL != nil ? track : nil)
                }
                .padding(.top, SCBrowseMetrics.shelfGap)
            } else if !related.hasFinished(.similar) {
                CollectionRelatedTrigger { loadRelated(.similar) }
            }
        }
    }

    private var collectionFooter: some View {
        VStack(alignment: .leading, spacing: Space.roomy) {
            CollectionReleaseFooter(
                info: CollectionReleaseInfo(playlist: model.playlist, tracks: model.tracks),
                font: .tvCaption,
                spacing: Space.hair
            )
            .padding(.horizontal, Space.base)

            if !isOwnFiles {
                Button(action: openArtist) {
                    TVCollectionArtistRow(user: artist)
                }
                .buttonStyle(TVCollectionRowStyle())
                .focusSection()
            }
            if !isOwnFiles {
                CollectionEngagementSection(playlist: model.playlist, destination: { ArtistDetailView(user: $0) })
            }
        }
        .padding(.horizontal, CollectionHeroMetrics.tv.horizontalInset - Space.base)
    }

    private func loadRelated(_ part: CollectionRelatedModel.Part) {
        let playlist = model.playlist
        let tracks = model.tracks
        Task { await related.load(part, for: playlist, tracks: tracks) }
    }

    @ViewBuilder
    private var status: some View {
        if model.isLoading {
            LoadingPlaceholder(.trackList(.tv), count: 8, insets: false)
                .frame(minHeight: 520, alignment: .top)
        } else if let error = model.errorMessage {
            StatusPanel(
                kind: .error,
                title: "Couldn\u{2019}t Load This \(model.kind.label)",
                message: error,
                actionTitle: "Try Again",
                action: { Task { await model.reload() } },
                minHeight: 520
            )
        } else {
            StatusPanel(kind: .empty, icon: model.kind.fallbackSymbol, title: "No Tracks", minHeight: 520)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let paging = TVPaging(model.pager) {
            TVPagedFooter(paging: paging)
        }
    }
}

private struct TVCollectionMoreMenu: View {
    let playlist: Playlist
    let settingsTitle: String
    let tracks: () -> [Track]
    let showSettings: () -> Void

    @ObservedObject private var downloads = DownloadManager.shared
    @Environment(\.downloadPrompter) private var prompter

    private var downloadedItem: DownloadedCollectionItem? {
        guard downloads.isCollectionDownloaded(playlist.id) else { return nil }
        return downloads.library.playlists.first { $0.id == playlist.id }
    }

    var body: some View {
        Menu {
            if downloads.isCollectionDownloaded(playlist.id) {
                if let item = downloadedItem {
                    Text(DownloadsFormat.collectionDetail(item, waitingReason: downloads.waitingReason))
                }
                Button("Remove Download", systemImage: "trash", role: .destructive) {
                    downloads.removeDownload(.collection(playlist.id))
                }
            } else {
                Button("Download", systemImage: "arrow.down.circle", action: download)
                    .disabled(!tracks().contains { downloads.downloadRefusalReason(for: $0) == nil })
            }
            Button(settingsTitle, systemImage: "gearshape", action: showSettings)
        } label: {
            Image(systemName: "ellipsis")
                .font(.tvBodyEmph)
        }
        .buttonStyle(TVGlassPillStyle(diameter: 76))
        .accessibilityLabel("More")
        .accessibilityIdentifier("collection.more")
    }

    private func download() {
        let allTracks = tracks()
        let descriptor = DownloadCollectionDescriptor(playlist: playlist)
        prompter.request { confirmed in
            await DownloadManager.shared.download(collection: descriptor, tracks: allTracks, confirmed: confirmed)
        }
    }
}

struct TVCollectionLinkStyle: ButtonStyle {
    var cornerRadius: CGFloat = 999
    var horizontalPadding: CGFloat = Space.snug
    var verticalPadding: CGFloat = Space.hair

    func makeBody(configuration: Configuration) -> some View {
        Styled(
            configuration: configuration,
            cornerRadius: cornerRadius,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding
        )
    }

    private struct Styled: View {
        let configuration: Configuration
        let cornerRadius: CGFloat
        let horizontalPadding: CGFloat
        let verticalPadding: CGFloat
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            configuration.label
                .foregroundStyle(isFocused ? Color.scChromeFocusOn : Color.scTextPrimary)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .background {
                    shape.fill(isFocused ? Color.scChromeFocus : Color.clear)
                }
                .contentShape(shape)
                .scaleEffect(isFocused ? 1.05 : 1, anchor: .leading)
                .shadow(color: isFocused ? Color.scFocusShadow : .clear, radius: 14, y: 8)
                .padding(.horizontal, -horizontalPadding)
                .padding(.vertical, -verticalPadding)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .focusEffectDisabled()
                .animation(reduceMotion ? nil : Motion.focus, value: isFocused)
        }
    }
}

struct TVShelfHeaderLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: Space.tight) {
            Text(title)
                .font(.tvHeadline)
                .lineLimit(1)
            Image(systemName: "chevron.right")
                .font(.tvHeadline)
                .imageScale(.small)
                .foregroundStyle(.secondary)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

extension CollectionHeroMetrics {
    static let tv = CollectionHeroMetrics(
        layout: .column,
        backdrop: .artwork,
        artworkSide: 480,
        artworkCorner: Corner.card,
        backdropHeight: 820,
        backdropBlur: 60,
        backdropFade: 360,
        backdropPadsFade: false,
        horizontalInset: 80,
        topInset: 96,
        heroSpacing: 64,
        textSpacing: Space.tight,
        rowSpacing: Space.hair,
        listTopSpacing: SCBrowseMetrics.shelfGap,
        bottomInset: Space.page,
        titleFont: .tvTitle,
        artistFont: .tvSubheadline,
        metadataFont: .tvCallout,
        descriptionFont: .tvCallout,
        titleLines: 2,
        descriptionLines: 2,
        textMaxWidth: 540
    )
}

extension SCTrackListMetrics {
    static let tv = SCTrackListMetrics(
        artworkSize: 64,
        artworkCorner: 8,
        numberWidth: 56,
        minHeight: 80,
        spacing: Space.base,
        verticalPadding: 8,
        horizontalPadding: Space.base,
        titleFont: .tvBodyEmph,
        subtitleFont: .tvCaption,
        detailFont: .tvCaption,
        numberFont: .tvCaption,
        indicatorFont: .tvCalloutEmph,
        durationMinWidth: 110,
        invertsOnFocus: true,
        primary: .scTextPrimary,
        secondary: .scTextSecondary,
        tertiary: .scTextTertiary,
        focusedPrimary: .scChromeFocusOn,
        focusedSecondary: Color.scChromeFocusOn.opacity(0.7)
    )
}

struct TVCollectionPillStyle: ButtonStyle {
    var isProminent = false
    var diameter: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, isProminent: isProminent, diameter: diameter)
    }

    private struct Styled: View {
        let configuration: Configuration
        let isProminent: Bool
        let diameter: CGFloat?
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.collectionAccent) private var accent

        private var restingFill: Color {
            if isProminent, let accent { return accent.wash(for: .dark) }
            return Color.white.opacity(isProminent ? 0.24 : 0.14)
        }

        var body: some View {
            configuration.label
                .frame(width: diameter, height: diameter)
                .foregroundStyle(isFocused ? Color.scChromeFocusOn : Color.scTextPrimary)
                .background {
                    Capsule().fill(isFocused ? Color.scChromeFocus : restingFill)
                }
                .contentShape(Capsule())
                .scaleEffect(isFocused ? 1.08 : 1)
                .shadow(color: isFocused ? Color.scFocusShadow : .clear, radius: 18, y: 10)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .focusEffectDisabled()
                .animation(reduceMotion ? nil : Motion.focus, value: isFocused)
        }
    }
}

private struct TVCollectionArtistRow: View {
    let user: User

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        CollectionArtistLabel(
            user: user,
            avatarSize: 96,
            spacing: Space.base,
            nameFont: .tvBodyEmph,
            detailFont: .tvCaption
        )
        .foregroundStyle(isFocused ? Color.scChromeFocusOn : Color.scTextPrimary)
        .padding(Space.base)
        .frame(maxWidth: 1100, alignment: .leading)
    }
}

struct TVCollectionRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration)
    }

    private struct Styled: View {
        let configuration: Configuration
        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Corner.control, style: .continuous)
            configuration.label
                .background { shape.fill(isFocused ? Color.scChromeFocus : Color.clear) }
                .contentShape(shape)
                .scaleEffect(isFocused ? 1.02 : 1)
                .shadow(color: isFocused ? Color.scFocusShadow : .clear, radius: 18, y: 10)
                .opacity(configuration.isPressed ? 0.85 : 1)
                .focusEffectDisabled()
                .animation(reduceMotion ? nil : Motion.focus, value: isFocused)
        }
    }
}

struct TVDetailTrackList: View {
    let tracks: [Track]
    var collectionId: String? = nil
    var showArtist = true
    var maximumCount: Int?
    var paging: TVPaging?

    @EnvironmentObject private var playerService: PlayerService

    private var visibleTracks: [Track] {
        maximumCount.map { Array(tracks.prefix($0)) } ?? tracks
    }

    private func activity(for track: Track) -> SCTrackActivity {
        guard playerService.currentTrack?.id == track.id else { return .none }
        return playerService.isPlaying ? .playing : .paused
    }

    var body: some View {
        LazyVStack(spacing: Space.hair) {
            ForEach(Array(visibleTracks.enumerated()), id: \.element.id) { index, track in
                let item = SCTrackListItem(track: track, number: index + 1, showsArtist: showArtist)
                Button {
                    guard track.streamURL != nil else { return }
                    Task { await playerService.play(track, in: tracks, collectionId: collectionId) }
                } label: {
                    SCTrackListRow(
                        item: item,
                        leading: .artwork,
                        activity: activity(for: track),
                        metrics: .tv,
                        crownUser: track.user
                    )
                }
                .buttonStyle(TVCollectionRowStyle())
                .contextMenu { TVTrackMenuItems(track: track) }
                .accessibilityLabel(item.accessibilityLabel)
                .prewarmPlaybackOnFocus(track)
                .onAppear {
                    guard maximumCount == nil, tracks.isNearEnd(track, lead: 10) else { return }
                    paging?.loadMore()
                }
            }

            if maximumCount == nil, let paging {
                TVPagedFooter(paging: paging)
            }
        }
        .focusSection()
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
        .accessibilityElement(children: .combine)
    }
}
