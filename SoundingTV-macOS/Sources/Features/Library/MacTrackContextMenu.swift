import SwiftUI
import AppKit

extension View {
    @ViewBuilder
    func macTrackContextMenu(track: Track) -> some View {
        self.contextMenu {
            MacTrackContextMenu(track: track)
        }
    }

    func macTrackAccessibility(
        track: Track,
        context: [Track] = [],
        bpm: Double? = nil,
        isCurrent: Bool = false,
        includesPlay: Bool = true
    ) -> some View {
        modifier(MacTrackAccessibility(
            track: track,
            context: context,
            bpm: bpm,
            isCurrent: isCurrent,
            includesPlay: includesPlay
        ))
    }
}

@MainActor
func macTrackAccessibilityLabel(_ track: Track, bpm: Double? = nil, isCurrent: Bool = false) -> String {
    var parts = [track.title, track.user.displayName, track.formattedDuration]
    if isCurrent { parts.append("Now Playing") }
    if track.streamURL == nil { parts.append("not playable") }
    if track.isPrivate { parts.append("private") }
    if case .downloaded = DownloadManager.shared.state(for: track.id) { parts.append("downloaded") }
    if let bpm, bpm > 0 { parts.append("\(Int(bpm.rounded())) BPM") }
    return parts.joined(separator: ", ")
}

private struct MacTrackAccessibility: ViewModifier {
    let track: Track
    let context: [Track]
    let bpm: Double?
    let isCurrent: Bool
    let includesPlay: Bool

    @ObservedObject private var engagement = MacTrackEngagement.shared
    @ObservedObject private var downloads = DownloadManager.shared
    @Environment(\.downloadPrompter) private var prompter

    private var isPlayable: Bool { track.streamURL != nil }

    func body(content: Content) -> some View {
        content
            .accessibilityLabel(macTrackAccessibilityLabel(track, bpm: bpm, isCurrent: isCurrent))
            .accessibilityActions {
                if isPlayable {
                    if includesPlay {
                        Button("Play") {
                            let queue = context.contains(where: { $0.id == track.id }) ? context : [track]
                            Task { await MacPlayback.play(track, in: queue) }
                        }
                    }
                    Button("Play Next") { MacPlayback.playNext([track]) }
                    Button("Add to Up Next") { MacPlayback.playLast([track]) }
                }
                Button(engagement.isLiked(track) ? "Unlike" : "Like") {
                    Task { await engagement.toggleLike(track) }
                }
                if isPlayable {
                    if case .downloaded = downloads.state(for: track.id) {
                        Button("Remove Download") { downloads.removeDownload(.track(track.id)) }
                    } else if downloads.downloadRefusalReason(for: track) == nil {
                        Button("Download") {
                            prompter.request { confirmed in
                                downloads.download(track: track, confirmed: confirmed)
                            }
                        }
                    }
                }
                Button("Go to Artist") { MacRootSelection.shared.request(artist: track.user) }
                Button("Behind the Track") { BehindTheTrackPresenter.shared.present(track) }
            }
    }
}

struct MacTrackContextMenu: View {
    let track: Track
    var contextPlaylist: Playlist? = nil
    var context: [Track] = []
    var presentsTempoKey: (@MainActor (Track) -> Void)? = nil
    var analysisTracks: [Track]? = nil

    @ObservedObject private var engagement = MacTrackEngagement.shared
    @ObservedObject private var downloads = DownloadManager.shared
    @Environment(\.downloadPrompter) private var prompter
    @ObservedObject private var setlists = SetlistIntelligenceStore.shared

    private var isPlayable: Bool { track.streamURL != nil }

    var body: some View {
        header

        Divider()

        BehindTheTrackMenuButton(track: track)

        LibraryTrackLinkMenuItems(track: track)

        Divider()

        if isPlayable {
            Button("Play") {
                let queue = context.contains(where: { $0.id == track.id }) ? context : [track]
                Task {
                    await MacPlayback.play(
                        track,
                        in: queue,
                        collectionId: contextPlaylist?.id,
                        source: contextPlaylist.map(PlaybackQueueSource.init(playlist:))
                    )
                }
            }
            if let router = MacPlaybackTarget.router {
                ForEach(router.playOnDevices) { device in
                    Button("Play on \(device.name)") {
                        let queue = context.contains(where: { $0.id == track.id }) ? context : [track]
                        Task { await router.play(track, in: queue, on: device) }
                    }
                }
            }
            Button("Play Next") { MacPlayback.playNext([track]) }
            Button("Play Last") { MacPlayback.playLast([track]) }
            Divider()
        }

        likeButton

        MacAddToPlaylistMenuButton(track: track)
        RemoveFromPlaylistMenuItem(track: track)

        StartStationMenuButton(track: track)

        if isPlayable {
            downloadButton
        }

        if DeckIdentityResolver.isLikelyMix(track) || setlists.setlist(for: track.id) != nil {
            Divider()
            Button {
                MacRootSelection.shared.request(setlist: track)
            } label: {
                Label("View Setlist…", systemImage: "list.number")
            }
            if let setlist = setlists.setlist(for: track.id), setlist.segments.contains(where: { $0.soundCloudTrackId != nil }) {
                Button {
                    MacRootSelection.shared.request(usbExport: .setlist(setlist, title: track.title))
                } label: {
                    Label("Export Setlist to USB…", systemImage: "externaldrive.badge.plus")
                }
            }
        }

        if track.mixSource != nil {
            Divider()
            Button {
                Task { try? await MacMixLoader.load(track, into: .a) }
            } label: {
                Label("Load to Deck A", systemImage: "a.square")
            }
            Button {
                Task { try? await MacMixLoader.load(track, into: .b) }
            } label: {
                Label("Load to Deck B", systemImage: "b.square")
            }
        }

        Divider()

        Button {
            MacPrepRoute.shared.inspect(track)
        } label: {
            Label("Prep", systemImage: "waveform.path.badge.plus")
        }
        .disabled(!isPlayable)

        Button {
            MacTrackTrimPresenter.shared.present(track)
        } label: {
            Label("Edit Start & End…", systemImage: "timeline.selection")
        }
        .disabled(!isPlayable)

        TrackTempoKeyMenuItems(track: track, present: presentsTempoKey ?? { TrackTempoKeyPresenter.shared.present($0) })

        Menu {
            Button {
                Task { await MacAnalysisRunner.analyse(track, force: true) }
            } label: {
                Label("Analyse Again", systemImage: "arrow.clockwise")
            }
            .disabled(track.streamURL == nil)

            AnalyseMissingMenuItems(tracks: analysisTracks ?? [track])

            Button {
                Task { await MacAnalysisIndex.shared.forgetAnalysis(forTrackId: track.id) }
            } label: {
                Label("Forget Analysis", systemImage: "trash")
            }
        } label: {
            Label("Analysis", systemImage: "waveform.badge.magnifyingglass")
        }

        Divider()

        Button {
            MacRootSelection.shared.request(artist: track.user)
        } label: {
            Label("Go to Artist", systemImage: "person.crop.circle")
        }
        MacGoToAlbumMenuItem(track: track, contextPlaylist: contextPlaylist)

        Divider()

        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(track.permalinkURL.absoluteString, forType: .string)
        } label: {
            Label("Copy SoundCloud Link", systemImage: "link")
        }

        ShareLink(item: track.permalinkURL, subject: Text(track.title), preview: SharePreview(track.title)) {
            Label("Share", systemImage: "square.and.arrow.up")
        }

        Button {
            MacMessageComposer.shared.present(track: track)
        } label: {
            Label("Send in SoundCloud Message", systemImage: "bubble.left.and.bubble.right")
        }
    }

    @ViewBuilder
    private var downloadButton: some View {
        if case .downloaded = downloads.state(for: track.id) {
            Button {
                downloads.removeDownload(.track(track.id))
            } label: {
                Label("Remove Download", systemImage: "xmark.circle")
            }
        } else {
            Button {
                prompter.request { confirmed in
                    downloads.download(track: track, confirmed: confirmed)
                }
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .disabled(downloads.downloadRefusalReason(for: track) != nil)
        }
    }

    private var header: some View {
        Button(action: {}) {
            HStack(spacing: 8) {
                ArtworkThumbnail(
                    url: track.artworkURL,
                    identity: track.id,
                    size: 30,
                    cornerRadius: 4,
                    isAvailable: track.streamURL != nil,
                    crownUser: track.user,
                    crownContext: track.title
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .font(.subheadline.weight(.semibold))
                    Text(track.user.displayName)
                        .font(.caption)
                        .foregroundStyle(MacSecondaryStyle())
                }
            }
        }
        .disabled(true)
    }

    private var likeButton: some View {
        Button {
            Task { await engagement.toggleLike(track) }
        } label: {
            Label(
                engagement.isLiked(track) ? "Unlike" : "Like",
                systemImage: engagement.isLiked(track) ? "heart.fill" : "heart"
            )
        }
    }
}

@MainActor
final class MacTrackTrimPresenter: ObservableObject {
    static let shared = MacTrackTrimPresenter()

    @Published var track: Track?

    func present(_ track: Track) {
        self.track = track
    }
}

extension View {
    func macTrackTrimSheet() -> some View {
        modifier(MacTrackTrimSheet())
    }
}

private struct MacTrackTrimSheet: ViewModifier {
    @ObservedObject private var presenter = MacTrackTrimPresenter.shared

    func body(content: Content) -> some View {
        content.sheet(item: $presenter.track) { track in
            TrackTrimEditor(track: track)
        }
    }
}

struct MacAddToPlaylistMenuButton: View {
    let track: Track

    var body: some View {
        Button {
            MacRootSelection.shared.requestAddToPlaylist(PlaylistTrackRef(track: track))
        } label: {
            Label("Add to Playlist…", systemImage: "text.badge.plus")
        }
        .disabled(track.isLocal)
    }
}

struct MacAddToPlaylistSheet: View {
    let onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: AddToPlaylistModel
    @State private var isNaming = false

    init(track: PlaylistTrackRef, onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
        _model = StateObject(wrappedValue: AddToPlaylistModel(track: track))
    }

    private var track: PlaylistTrackRef { model.track }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Add to Playlist")
                .navigationSubtitle(track.title)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) { dismiss() }
                            .disabled(model.isAdding)
                    }
                }
                .searchable(text: $model.query, prompt: "Search Playlists")
        }
        .frame(minWidth: 420, idealWidth: 460, minHeight: 460, idealHeight: 520)
        .interactiveDismissDisabled(model.isAdding)
        .sheet(isPresented: $isNaming) {
            NewPlaylistSheet(trackIDs: [track.id]) { _ in
                finish()
            }
        }
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

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView {
                Label("Couldn’t Load Playlists", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try Again") { Task { await model.load() } }
            }
        case .loaded(let playlists):
            list(playlists)
        }
    }

    private func list(_ playlists: [PlaylistSummary]) -> some View {
        let shown = model.playlists(from: playlists)
        return List {
            if model.query.isEmpty {
                Section {
                    Button {
                        isNaming = true
                    } label: {
                        Label("New Playlist…", systemImage: "plus")
                    }
                    .disabled(model.isAdding)
                }
            }
            if shown.isEmpty {
                if playlists.isEmpty {
                    ContentUnavailableView("No Playlists Yet", systemImage: "music.note.list")
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                } else {
                    ContentUnavailableView.search(text: model.query)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            } else {
                Section(model.query.isEmpty ? "Your Playlists" : "") {
                    ForEach(shown) { playlist in
                        row(playlist)
                    }
                }
            }
        }
    }

    private func row(_ playlist: PlaylistSummary) -> some View {
        Button {
            model.add(to: playlist) { _ in finish() }
        } label: {
            HStack(spacing: 10) {
                ArtworkThumbnail(url: playlist.artworkURL, identity: playlist.id, size: 36, cornerRadius: 4)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(playlist.title)
                        .foregroundStyle(.primary)
                    Text(playlist.trackCount == 1 ? "1 track" : "\(playlist.trackCount) tracks")
                        .font(.subheadline)
                        .foregroundStyle(MacSecondaryStyle())
                }
                Spacer(minLength: 0)
                if model.pendingID == playlist.id {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isAdding)
        .accessibilityLabel(playlist.title)
        .accessibilityHint("Adds \(track.title)")
    }

    private func finish() {
        onFinished()
        dismiss()
    }
}

private struct MacGoToAlbumMenuItem: View {
    let track: Track
    var contextPlaylist: Playlist? = nil

    @State private var albumPlaylist: PlaylistSummary?
    @State private var checked = false

    var body: some View {
        Group {
            if let known = track.knownAlbum {
                if known.id != contextPlaylist?.id {
                    Button {
                        MacRootSelection.shared.request(playlist: known)
                    } label: {
                        Label("Go to Album", systemImage: "square.stack")
                    }
                }
            } else if checked, let albumPlaylist, let url = albumPlaylist.permalinkURL, albumPlaylist.id != contextPlaylist?.id {
                Button {
                    Task { await openAlbum(at: url) }
                } label: {
                    Label("Go to Album", systemImage: "square.stack")
                }
            }
        }
        .task(id: track.id) {
            guard track.knownAlbum == nil else { return }
            if let cached = MacAlbumLookupCache.cache[track.id] {
                albumPlaylist = cached
                checked = true
                return
            }
            let page = try? await SoundCloudAPI.shared.getPlaylistsContaining(trackId: track.id)
            let found = page?.collection.first { $0.isAlbum }
            MacAlbumLookupCache.cache[track.id] = found
            albumPlaylist = found
            checked = true
        }
    }

    private func openAlbum(at url: URL) async {
        if let resolved = try? await SoundCloudAPI.shared.resolve(url: url), case .playlist(let playlist) = resolved {
            MacRootSelection.shared.request(playlist: playlist)
            return
        }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
private enum MacAlbumLookupCache {
    static var cache: [String: PlaylistSummary?] = [:]
}
