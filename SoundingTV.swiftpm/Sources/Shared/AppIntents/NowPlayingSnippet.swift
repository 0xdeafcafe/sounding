import AppIntents
import Foundation
import SwiftUI

@MainActor
enum IntentNowPlaying {
    struct Item {
        let trackID: String
        let title: String
        let artist: String
        let artworkURL: URL?
        let outputName: String?
        let track: Track?

        var isSoundCloud: Bool { !LocalTrackFile.isLocalTrackID(trackID) && track?.isLocal != true }
    }

    static func current() -> Item? {
        let player = PlayerService.shared
        #if !os(tvOS)
        if let router = PartyScenes.outputRouter, router.isRemote {
            guard let playback = router.client.telemetry.playback, let id = playback.trackId else { return nil }
            let known = ([player.currentTrack].compactMap { $0 } + player.queue).first { $0.id == id }
            return Item(
                trackID: id,
                title: playback.title ?? known?.title ?? "Unknown Track",
                artist: playback.artist ?? known?.user.displayName ?? "",
                artworkURL: playback.artworkURL.flatMap(URL.init(string:)) ?? known?.artworkURL,
                outputName: router.current.name,
                track: known
            )
        }
        #endif
        guard let track = player.currentTrack else { return nil }
        return Item(
            trackID: track.id,
            title: track.title,
            artist: track.user.displayName,
            artworkURL: track.largeArtworkURL ?? track.artworkURL,
            outputName: nil,
            track: track
        )
    }

    static func isLiked(_ item: Item) async -> Bool {
        if let known = NowPlayingLikeModel.shared.liked[item.trackID] { return known }
        if item.track?.userFavorite == true { return true }
        return await LibraryCache.shared.containsLike(id: item.trackID)
    }

    static func artwork(for item: Item) async -> Image? {
        guard let url = item.artworkURL,
              let image = await ArtworkCache.shared.image(for: url, variant: .thumbnail) else { return nil }
        return SCPlatformImageBridge.image(image)
    }

    static func skip() async throws {
        #if !os(tvOS)
        if let router = PartyScenes.outputRouter, router.isRemote {
            router.next()
            return
        }
        #endif
        try await PlaybackControlBridge.skipToNext()
    }
}

struct NowPlayingSnippetIntent: SnippetIntent {
    static let title: LocalizedStringResource = "Now Playing"
    static let isDiscoverable = false

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetView {
        guard let item = IntentNowPlaying.current() else {
            return .result(view: NowPlayingSnippetView(content: nil))
        }
        let content = NowPlayingSnippetView.Content(
            trackID: item.trackID,
            title: item.title,
            artist: item.artist,
            outputName: item.outputName,
            artwork: await IntentNowPlaying.artwork(for: item),
            isLiked: await IntentNowPlaying.isLiked(item),
            canEdit: item.isSoundCloud
        )
        return .result(view: NowPlayingSnippetView(content: content))
    }
}

struct ShowNowPlayingIntent: AppIntent {
    static let title: LocalizedStringResource = "Now Playing"
    static let description = IntentDescription("Shows what's playing, with Like, Skip and Add to Playlist.")
    static let supportedModes: IntentModes = .background

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetIntent {
        .result(snippetIntent: NowPlayingSnippetIntent())
    }
}

struct LikeNowPlayingIntent: AppIntent {
    static let title: LocalizedStringResource = "Like"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Track")
    var trackID: String

    init() {}

    init(trackID: String) {
        self.trackID = trackID
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard IntentPlayback.source.isSignedIn else { throw PlaybackIntentError.signedOut }
        let current = IntentNowPlaying.current()
        let resolved = current?.trackID == trackID ? current?.track : nil
        let isLiked: Bool
        if let current, current.trackID == trackID {
            isLiked = await IntentNowPlaying.isLiked(current)
        } else {
            isLiked = await LibraryCache.shared.containsLike(id: trackID)
        }
        let likes = NowPlayingLikeModel.shared
        likes.setLiked(!isLiked, trackId: trackID, resolved: resolved, indexed: isLiked)
        await likes.waitUntilSettled(trackID)
        if let failure = likes.failure {
            likes.dismissFailure()
            throw PlaybackIntentError.refused(failure.message)
        }
        NowPlayingSnippetIntent.reload()
        return .result()
    }
}

struct SkipNowPlayingIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Skip"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .background

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        try await IntentNowPlaying.skip()
        NowPlayingSnippetIntent.reload()
        return .result()
    }
}

struct NowPlayingSnippetView: View {
    struct Content {
        let trackID: String
        let title: String
        let artist: String
        let outputName: String?
        let artwork: Image?
        let isLiked: Bool
        let canEdit: Bool
    }

    let content: Content?

    var body: some View {
        Group {
            if let content {
                VStack(alignment: .leading, spacing: 14) {
                    header(content)
                    actions(content)
                }
                .padding()
            } else {
                ContentUnavailableView("Not Playing", systemImage: "music.note")
            }
        }
        .tint(Color.scAccent)
    }

    private func header(_ content: Content) -> some View {
        HStack(spacing: 12) {
            artwork(content.artwork)
            VStack(alignment: .leading, spacing: 2) {
                Text(content.title)
                    .font(.headline)
                    .lineLimit(2)
                if !content.artist.isEmpty {
                    Text(content.artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let outputName = content.outputName {
                    Label("Playing on \(outputName)", systemImage: "airplayaudio")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func artwork(_ image: Image?) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.quaternary)
            .frame(width: 64, height: 64)
            .overlay {
                if let image {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: "music.note")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
    }

    private func actions(_ content: Content) -> some View {
        HStack(spacing: 10) {
            if content.canEdit {
                Button(intent: LikeNowPlayingIntent(trackID: content.trackID)) {
                    Label(content.isLiked ? "Liked" : "Like", systemImage: content.isLiked ? "heart.fill" : "heart")
                        .frame(maxWidth: .infinity)
                }
                .accessibilityLabel(content.isLiked ? "Remove from Likes" : "Add to Likes")
            }
            Button(intent: SkipNowPlayingIntent()) {
                Label("Skip", systemImage: "forward.fill")
                    .frame(maxWidth: .infinity)
            }
            if content.canEdit {
                Button(intent: AddNowPlayingToPlaylistIntent(trackID: content.trackID)) {
                    Label("Add to Playlist", systemImage: "text.badge.plus")
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

// MARK: - Add to Playlist

@MainActor
enum IntentPlaylistChoices {
    struct Choice: Identifiable, Equatable {
        let id: String
        let title: String
        let trackCount: Int
    }

    static let limit = 8
    private static let freshness: TimeInterval = 300
    private static var cached: (choices: [Choice], at: Date)?
    private static var selections: [String: String] = [:]

    static func load() async -> [Choice] {
        if let cached, Date().timeIntervalSince(cached.at) < freshness { return cached.choices }
        let me = SoundCloudAPI.credentials?.currentUser?.id
        var choices = await DeviceLocalCatalog().cachedPlaylists()
            .filter { !$0.isAlbum && (me == nil || $0.user.id == me) }
            .map { Choice(id: $0.id, title: $0.title, trackCount: $0.totalTrackCount) }
        if choices.isEmpty, let mine = try? await PlaylistWriter.myPlaylists() {
            choices = mine.filter { !$0.isAlbum }.map { Choice(id: $0.id, title: $0.title, trackCount: $0.trackCount) }
        }
        let trimmed = Array(choices.prefix(limit))
        if !trimmed.isEmpty { cached = (trimmed, Date()) }
        return trimmed
    }

    static func begin(_ trackID: String) {
        selections[trackID] = nil
    }

    static func select(_ playlistID: String, for trackID: String) {
        selections[trackID] = playlistID
    }

    static func selection(for trackID: String) -> String? {
        selections[trackID]
    }

    static func choice(id: String) -> Choice? {
        cached?.choices.first { $0.id == id }
    }
}

struct AddNowPlayingToPlaylistIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Playlist"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Track")
    var trackID: String

    init() {}

    init(trackID: String) {
        self.trackID = trackID
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard IntentPlayback.source.isSignedIn else { throw PlaybackIntentError.signedOut }
        IntentPlaylistChoices.begin(trackID)
        let chosen: String = try await requestConfirmation(
            actionName: .add,
            dialog: "Add to which playlist?",
            snippetIntent: PlaylistChoiceSnippetIntent(trackID: trackID)
        )
        guard !chosen.isEmpty, let playlist = IntentPlaylistChoices.choice(id: chosen) else {
            return .result(dialog: "Nothing was added.")
        }
        do {
            try await SoundCloudAPI.shared.addTrack(trackID, toPlaylist: playlist.id)
        } catch {
            throw PlaybackIntentError.refused(PlaylistEditFailure.message(for: error, action: "add the track"))
        }
        NowPlayingSnippetIntent.reload()
        return .result(dialog: "Added to \(playlist.title).")
    }
}

struct PlaylistChoiceSnippetIntent: SnippetIntent {
    static let title: LocalizedStringResource = "Choose Playlist"
    static let isDiscoverable = false

    @Parameter(title: "Track")
    var trackID: String

    init() {}

    init(trackID: String) {
        self.trackID = trackID
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ShowsSnippetView {
        let choices = await IntentPlaylistChoices.load()
        let selected = IntentPlaylistChoices.selection(for: trackID)
        return .result(
            value: selected ?? "",
            view: PlaylistChoiceSnippetView(trackID: trackID, choices: choices, selected: selected)
        )
    }
}

struct ChoosePlaylistIntent: AppIntent {
    static let title: LocalizedStringResource = "Choose Playlist"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Track")
    var trackID: String

    @Parameter(title: "Playlist")
    var playlistID: String

    init() {}

    init(trackID: String, playlistID: String) {
        self.trackID = trackID
        self.playlistID = playlistID
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentPlaylistChoices.select(playlistID, for: trackID)
        PlaylistChoiceSnippetIntent.reload()
        return .result()
    }
}

struct PlaylistChoiceSnippetView: View {
    let trackID: String
    let choices: [IntentPlaylistChoices.Choice]
    let selected: String?

    var body: some View {
        Group {
            if choices.isEmpty {
                ContentUnavailableView("No Playlists", systemImage: "music.note.list")
            } else {
                VStack(spacing: 0) {
                    ForEach(choices) { choice in
                        Button(intent: ChoosePlaylistIntent(trackID: trackID, playlistID: choice.id)) {
                            row(choice)
                        }
                        .buttonStyle(.plain)
                        if choice.id != choices.last?.id {
                            Divider()
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
        .tint(Color.scAccent)
    }

    private func row(_ choice: IntentPlaylistChoices.Choice) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(choice.title)
                    .lineLimit(1)
                Text(choice.trackCount == 1 ? "1 track" : "\(choice.trackCount) tracks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if choice.id == selected {
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.scAccent)
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(choice.id == selected ? .isSelected : [])
    }
}
