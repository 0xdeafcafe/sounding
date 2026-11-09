#if os(iOS) || os(macOS)
import SwiftUI

struct LibrarySourceMarks: View {
    let sources: LibrarySources

    var body: some View {
        if !sources.isEmpty {
            HStack(spacing: 3) {
                ForEach(sources.symbols, id: \.self) { symbol in
                    Image(systemName: symbol)
                }
            }
            .font(.caption)
            .imageScale(.small)
            .help(sources.label)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(sources.label)
        }
    }
}

struct LibraryAvatar: View {
    let url: URL?
    let identity: String
    let size: CGFloat

    var body: some View {
        #if os(macOS)
        ArtworkThumbnail(url: url, identity: identity, size: size, cornerRadius: size / 2)
        #else
        ArtworkThumbnail(url: url, systemImage: "person.fill", isCircle: true, size: size, identity: identity)
        #endif
    }
}

struct LibraryArtistAvatar: View {
    let artist: LibraryArtist
    let size: CGFloat

    var body: some View {
        LibraryAvatar(url: size > 64 ? artist.artworkURL : artist.thumbnailURL, identity: "library.\(artist.id)", size: size)
    }
}

struct LibraryArtistRow: View {
    let artist: LibraryArtist
    var isSelected = false

    #if os(macOS)
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 44
    #else
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 56
    #endif

    var body: some View {
        HStack(spacing: 12) {
            LibraryArtistAvatar(artist: artist, size: 40)
            Text(artist.name)
                .lineLimit(1)
            Spacer(minLength: 4)
            LibrarySourceMarks(sources: artist.sources)
                .foregroundStyle(isSelected ? AnyShapeStyle(selectedInk.opacity(0.8)) : AnyShapeStyle(.tertiary))
        }
        .foregroundStyle(isSelected ? selectedInk : Color.primary)
        .frame(minHeight: rowHeight)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var selectedInk: Color { .scAccentOn }
}

struct LibraryArtistMenuItems: View {
    let artist: LibraryArtist
    var play: ((LibraryArtist, Bool) -> Void)?
    let link: (LibraryArtist) -> Void

    var body: some View {
        if let play {
            Button("Play", systemImage: "play") { play(artist, false) }
            Button("Shuffle", systemImage: "shuffle") { play(artist, true) }
        }
        if artist.canLink {
            Section {
                Button(artist.isLinked ? "Link to Another SoundCloud Artist…" : "Link to SoundCloud Artist…", systemImage: "link") {
                    link(artist)
                }
                if artist.isLinked {
                    Button("Unlink", systemImage: "minus.circle") {
                        LibraryIdentity.shared.unlink(artist)
                    }
                }
            }
        }
    }
}

struct LibraryArtistList<Destination: View>: View {
    let artists: [LibraryArtist]
    var selectedID: String?
    var select: ((LibraryArtist) -> Void)?
    var play: ((LibraryArtist, Bool) -> Void)?
    @ViewBuilder var destination: (LibraryArtist) -> Destination

    @State private var linking: LibraryArtist?

    var body: some View {
        list
            .sheet(item: $linking) { artist in
                LibraryArtistLinkSheet(artist: artist)
            }
    }

    @ViewBuilder
    private var list: some View {
        #if os(macOS)
        List(artists) { artist in
            LibraryArtistRow(artist: artist, isSelected: artist.id == selectedID)
                .macSelectableRow(artist.id, selection: selectionBinding, style: .sidebar)
                .contextMenu { menu(artist) }
        }
        .listStyle(.plain)
        .macListKeyboardSelection(ids: artists.map(\.id), selection: selectionBinding)
        #else
        List(artists) { artist in
            if let select {
                let isSelected = artist.id == selectedID
                Button {
                    select(artist)
                } label: {
                    LibraryArtistRow(artist: artist, isSelected: isSelected)
                        .padding(.horizontal, 12)
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                .listRowBackground(rowBackground(isSelected))
                .listRowSeparator(.hidden)
                .contextMenu { menu(artist) }
            } else {
                NavigationLink(value: artist) {
                    LibraryArtistRow(artist: artist)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 16))
                .alignmentGuide(.listRowSeparatorLeading) { _ in 52 }
                .contextMenu { menu(artist) }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 44)
        .navigationDestination(for: LibraryArtist.self) { destination($0) }
        #endif
    }

    private func menu(_ artist: LibraryArtist) -> some View {
        LibraryArtistMenuItems(artist: artist, play: play) { linking = $0 }
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { selectedID },
            set: { id in
                guard let id, let artist = artists.first(where: { $0.id == id }) else { return }
                select?(artist)
            }
        )
    }

    @ViewBuilder
    private func rowBackground(_ isSelected: Bool) -> some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.scAccent)
                .padding(.horizontal, 8)
                .padding(.vertical, 1)
        } else {
            Color.clear
        }
    }
}

struct LibraryArtistSortMenu: View {
    @Binding var sort: LibraryArtistSort

    var body: some View {
        Menu {
            Picker("Sort By", selection: $sort) {
                ForEach(LibraryArtistSort.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
        } label: {
            Label("Sort", systemImage: "line.3.horizontal.decrease")
        }
        .accessibilityLabel("Sort Artists")
    }
}

struct LibraryArtistLinkSheet: View {
    let artist: LibraryArtist

    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [User] = []
    @State private var isLoaded = false
    @State private var searchText = ""

    private var filtered: [User] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return Array(candidates.prefix(300)) }
        return Array(candidates.filter {
            LibraryNames.matches($0.displayName, query: needle) || LibraryNames.matches($0.username, query: needle)
        }.prefix(300))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Link \(artist.name)")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .searchable(text: $searchText, prompt: "Search SoundCloud Artists")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 480, minHeight: 520, idealHeight: 600)
        #endif
        .task {
            candidates = LibraryIdentity.shared.linkCandidates(for: artist)
            isLoaded = true
        }
    }

    @ViewBuilder
    private var content: some View {
        if !isLoaded {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if candidates.isEmpty {
            ContentUnavailableView(
                "No SoundCloud Artists",
                systemImage: "person.crop.circle.badge.questionmark",
                description: Text("Artists you follow, or whose tracks and albums you like, appear here.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty {
            ContentUnavailableView.search(text: searchText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(filtered) { user in
                Button {
                    LibraryIdentity.shared.link(artist, to: user)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        LibraryAvatar(url: User.customAvatar(user.avatarURL), identity: "user.\(user.id)", size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.displayName)
                                .lineLimit(1)
                            Text(user.followersCount == 1 ? "1 follower" : "\(user.formattedFollowers) followers")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if user.id == artist.user?.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                                .accessibilityLabel("Linked")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }
}

struct LibraryAlbumCounterpartLink: View {
    let route: LibraryCollectionRoute

    @ObservedObject private var identity = LibraryIdentity.shared

    private var target: (route: LibraryCollectionRoute, title: String, symbol: String)? {
        switch route {
        case .local(let album):
            guard album.kind == .album, let playlist = identity.index.soundCloudAlbum(forLocalAlbumID: album.id) else { return nil }
            return (.playlist(playlist), "Also on SoundCloud", "cloud")
        case .playlist(let playlist):
            guard let album = identity.index.localAlbum(forPlaylistID: playlist.id) else { return nil }
            return (.local(album), "In Your Files", "folder")
        }
    }

    var body: some View {
        if let target {
            NavigationLink(value: target.route) {
                Label(target.title, systemImage: target.symbol)
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
    }
}

private enum LibraryArtistPageMetrics {
    #if os(macOS)
    static var margin: CGFloat { SCContentStyle.mac.spaceGutter }
    static var style: SCContentStyle { .mac }
    static var trackMetrics: SCTrackListMetrics { .mac }
    #else
    static var margin: CGFloat { 20 }
    static var style: SCContentStyle { .phone }
    static var trackMetrics: SCTrackListMetrics {
        var metrics = SCTrackListMetrics.phoneRoomy
        metrics.artworkSize = 40
        metrics.minHeight = 52
        metrics.verticalPadding = 3
        return metrics
    }
    #endif
}

struct LibraryArtistOverview<TrackMenu: View>: View {
    let artist: LibraryArtist
    let play: (_ tracks: [Track], _ start: Track?, _ shuffled: Bool) -> Void
    var openProfile: ((User) -> Void)?
    var activity: (Track) -> SCTrackActivity
    @ViewBuilder var trackMenu: (Track, [Track]) -> TrackMenu

    @ObservedObject private var identity = LibraryIdentity.shared
    @ObservedObject private var settings = SettingsStore.shared
    @State private var showsAllTracks = false
    @ScaledMetric(relativeTo: .body) private var tileMinimum: CGFloat = 150
    @ScaledMetric(relativeTo: .body) private var shelfTile: CGFloat = 160
    @ScaledMetric(relativeTo: .body) private var trackColumn: CGFloat = 320

    private static var collapsedTrackCount: Int { 8 }

    init(
        artist: LibraryArtist,
        play: @escaping (_ tracks: [Track], _ start: Track?, _ shuffled: Bool) -> Void,
        openProfile: ((User) -> Void)? = nil,
        activity: @escaping (Track) -> SCTrackActivity = { _ in .none },
        @ViewBuilder trackMenu: @escaping (Track, [Track]) -> TrackMenu
    ) {
        self.artist = artist
        self.play = play
        self.openProfile = openProfile
        self.activity = activity
        self.trackMenu = trackMenu
    }

    private var current: LibraryArtist {
        identity.index.artist(id: artist.id) ?? artist
    }

    var body: some View {
        let artist = current
        let releases = identity.index.releases(for: artist, setMinimumDuration: settings.setMinimumDurationSeconds)
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header(artist, releases: releases)
                    .padding(.horizontal, LibraryArtistPageMetrics.margin)
                albums(releases)
                tracks(releases)
                sets(releases)
                appearsOn(releases)
            }
            .padding(.top, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background { CollectionPageMesh(url: artist.artworkURL) }
        .collectionAccent(from: artist.artworkURL)
        .prefetchArtwork(releases.albums.prefix(12).compactMap(\.artworkURL))
    }

    private func header(_ artist: LibraryArtist, releases: LibraryArtistReleases) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 24) {
                LibraryArtistAvatar(artist: artist, size: 168)
                headerText(artist, releases: releases)
            }
            VStack(alignment: .leading, spacing: 16) {
                LibraryArtistAvatar(artist: artist, size: 128)
                headerText(artist, releases: releases)
            }
        }
    }

    private func headerText(_ artist: LibraryArtist, releases: LibraryArtistReleases) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            nameLink(artist)
            HStack(spacing: 6) {
                LibrarySourceMarks(sources: artist.sources)
                Text(summary(releases))
                    .monospacedDigit()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            CollectionHeroPlayButtons(
                isEnabled: !releases.playable.isEmpty,
                fills: false,
                isCompact: true,
                onPlay: { play(releases.playable, releases.playable.first, false) },
                onShuffle: { play(releases.playable, nil, true) }
            )
            .padding(.top, 4)
            if let user = artist.user {
                viewOnSoundCloud(user)
            }
        }
    }

    @ViewBuilder
    private func nameLink(_ artist: LibraryArtist) -> some View {
        let label = HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(artist.name)
                .font(.largeTitle.bold())
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Image(systemName: "chevron.right")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
        if let local = artist.local {
            NavigationLink(value: LibraryCollectionRoute.local(local)) { label }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the artist page")
        } else if let user = artist.user {
            profileLink(user) { label }
                .accessibilityHint("Opens the SoundCloud profile")
        } else {
            Text(artist.name)
                .font(.largeTitle.bold())
                .lineLimit(2)
        }
    }

    private func viewOnSoundCloud(_ user: User) -> some View {
        profileLink(user) {
            Label("View on SoundCloud", systemImage: "arrow.up.right")
                .font(.subheadline.weight(.medium))
                .labelStyle(.titleAndIcon)
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func profileLink<Content: View>(_ user: User, @ViewBuilder label: () -> Content) -> some View {
        if let openProfile {
            Button { openProfile(user) } label: { label() }
                .buttonStyle(.plain)
        } else {
            NavigationLink(value: user) { label() }
                .buttonStyle(.plain)
        }
    }

    private func summary(_ releases: LibraryArtistReleases) -> String {
        var parts: [String] = []
        let trackCount = releases.tracks.count + releases.sets.count
        if trackCount > 0 { parts.append(trackCount == 1 ? "1 track" : "\(trackCount.formatted()) tracks") }
        if !releases.albums.isEmpty { parts.append(releases.albums.count == 1 ? "1 album" : "\(releases.albums.count) albums") }
        if parts.isEmpty { parts.append(current.sources.label) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func albums(_ releases: LibraryArtistReleases) -> some View {
        if !releases.albums.isEmpty {
            VStack(alignment: .leading, spacing: LibraryArtistPageMetrics.style.spaceSnug) {
                SCSectionHeader(title: "Albums", style: LibraryArtistPageMetrics.style)
                LibraryCollectionGrid(items: releases.albums, minimumTile: tileMinimum, play: playAlbum) { item in
                    albumMenu(item)
                }
            }
            .padding(.horizontal, LibraryArtistPageMetrics.margin)
        }
    }

    @ViewBuilder
    private func albumMenu(_ item: LibraryGridItem) -> some View {
        if case .local(let album) = item.route, !album.tracks.isEmpty {
            Button("Play", systemImage: "play") { play(album.tracks, album.tracks.first, false) }
            Button("Shuffle", systemImage: "shuffle") { play(album.tracks, nil, true) }
        } else if case .playlist(let playlist) = item.route, let tracks = playlist.tracks, !tracks.isEmpty {
            let preferred = identity.index.preferringLocalCopies(tracks)
            Button("Play", systemImage: "play") { play(preferred, preferred.first, false) }
            Button("Shuffle", systemImage: "shuffle") { play(preferred, nil, true) }
        }
    }

    private func playAlbum(_ item: LibraryGridItem) {
        switch item.route {
        case .local(let album):
            play(album.tracks, album.tracks.first, false)
        case .playlist(let playlist):
            let tracks = identity.index.preferringLocalCopies(playlist.tracks ?? [])
            if !tracks.isEmpty { play(tracks, tracks.first, false) }
        }
    }

    @ViewBuilder
    private func tracks(_ releases: LibraryArtistReleases) -> some View {
        if !releases.tracks.isEmpty {
            let all = releases.tracks
            let collapsible = all.count > Self.collapsedTrackCount
            let shown = showsAllTracks || !collapsible ? all : Array(all.prefix(Self.collapsedTrackCount))
            VStack(alignment: .leading, spacing: LibraryArtistPageMetrics.style.spaceSnug) {
                HStack(alignment: .firstTextBaseline) {
                    SCSectionHeader(title: "Tracks", style: LibraryArtistPageMetrics.style)
                    Spacer(minLength: 8)
                    if collapsible {
                        Button(showsAllTracks ? "Show Less" : "Show All \(all.count.formatted())") {
                            showsAllTracks.toggle()
                        }
                        .buttonStyle(.plain)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    }
                }
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: trackColumn), spacing: 24, alignment: .top)],
                    alignment: .leading,
                    spacing: 0
                ) {
                    ForEach(shown) { track in
                        trackRow(track, queue: all)
                    }
                }
            }
            .padding(.horizontal, LibraryArtistPageMetrics.margin)
        }
    }

    private func trackRow(_ track: Track, queue: [Track]) -> some View {
        Button {
            play(queue, track, false)
        } label: {
            SCTrackListRow(
                item: SCTrackListItem(track: track, showsArtist: track.user.displayName != current.name),
                leading: .artwork,
                activity: activity(track),
                metrics: LibraryArtistPageMetrics.trackMetrics,
                crownUser: track.user
            ) {
                LibrarySourceMarks(sources: identity.index.sources(of: track))
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
        .contextMenu { trackMenu(track, queue) }
    }

    @ViewBuilder
    private func sets(_ releases: LibraryArtistReleases) -> some View {
        if !releases.sets.isEmpty {
            CollectionShelf(
                title: "Sets & Mixes",
                items: releases.sets,
                style: LibraryArtistPageMetrics.style,
                tileWidth: shelfTile,
                spacing: 16,
                inset: LibraryArtistPageMetrics.margin
            ) { track in
                Button {
                    play(releases.sets, track, false)
                } label: {
                    ArtworkShelfCard(track: track, style: LibraryArtistPageMetrics.style)
                }
                .buttonStyle(.plain)
                .contextMenu { trackMenu(track, releases.sets) }
            }
        }
    }

    @ViewBuilder
    private func appearsOn(_ releases: LibraryArtistReleases) -> some View {
        if !releases.appearsOn.isEmpty {
            CollectionShelf(
                title: "Appears On",
                items: releases.appearsOn,
                style: LibraryArtistPageMetrics.style,
                tileWidth: shelfTile,
                spacing: 16,
                inset: LibraryArtistPageMetrics.margin
            ) { item in
                NavigationLink(value: item.route) {
                    LibraryCollectionTile(item: item)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct LibraryArtistsSplit<Detail: View>: View {
    let artists: [LibraryArtist]
    let searchText: String
    @Binding var selectedID: String?
    var play: ((LibraryArtist, Bool) -> Void)?
    var listHeader: AnyView?
    @ViewBuilder var detail: (LibraryArtist) -> Detail

    private var selected: LibraryArtist? {
        artists.first { $0.id == selectedID } ?? artists.first
    }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    if let listHeader { listHeader }
                    if artists.isEmpty {
                        ContentUnavailableView.search(text: searchText)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        LibraryArtistList(
                            artists: artists,
                            selectedID: selected?.id,
                            select: { selectedID = $0.id },
                            play: play
                        ) { _ in
                            EmptyView()
                        }
                        .scrollContentBackground(.hidden)
                    }
                }
                .frame(width: min(max(proxy.size.width * 0.34, 260), 380))
                .frame(maxHeight: .infinity, alignment: .top)

                Divider()

                if let selected {
                    detail(selected)
                        .id(selected.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
#endif
