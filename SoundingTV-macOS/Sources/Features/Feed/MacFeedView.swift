import SwiftUI
import AppKit

struct MacFeedView: View {
    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    @ObservedObject private var model: FeedViewModel
    @ObservedObject private var player = PlayerService.shared
    private let showsHeader: Bool

    init(model: FeedViewModel, showsHeader: Bool = true) {
        self.model = model
        self.showsHeader = showsHeader
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader { header }
            content
        }
        .background(Color.black.opacity(0.001))
        .task { await loadFeedIfNeeded() }
    }

    private enum MacFeedState: Equatable {
        case loading, loaded, empty
        case error(String)
    }

    private var feedState: MacFeedState {
        if !model.loadedOnce || (model.isLoading && model.items.isEmpty) {
            return .loading
        }
        if model.error != nil, model.items.isEmpty {
            return .error("Couldn't reach SoundCloud. Check your connection and try again.")
        }
        if model.items.isEmpty {
            return .empty
        }
        return .loaded
    }

    private func loadFeedIfNeeded() async {
        guard !credentials.isSignedOut else { return }
        await model.loadContentIfNeeded()
    }

    private func loadFeed() async {
        guard !credentials.isSignedOut else { return }
        await model.loadContent()
    }

    private var header: some View {
        MacPaneHeader(title: "Stream", subtitle: headerSubtitle)
    }

    private var headerSubtitle: String? {
        guard case .loaded = feedState else { return nil }
        let count = model.items.count
        return "\(count) update\(count == 1 ? "" : "s") from people you follow"
    }

    @ViewBuilder
    private var content: some View {
        if credentials.isSignedOut {
            signedOutState
        } else {
            switch feedState {
            case .loading:
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .error(let message):
                SCEmptyState(
                    kind: .error,
                    title: "Couldn't Load Stream",
                    message: message,
                    actionTitle: "Try Again",
                    action: { Task { await loadFeed() } },
                    style: .mac
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .empty:
                SCEmptyState(
                    icon: "dot.radiowaves.up.forward",
                    title: "Nothing Here Yet",
                    message: "Follow artists on SoundCloud and their uploads, playlists and reposts will show up here.",
                    actionTitle: "Search SoundCloud",
                    action: { MacRootSelection.shared.request(.search) },
                    style: .mac
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                list
            }
        }
    }

    private static let artworkLookahead = 10

    private var list: some View {
        List {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, activity in
                FeedActivityRow(activity: activity, context: { model.items.compactMap(\.track) }, player: player)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(
                        top: SCContentStyle.mac.spaceHair,
                        leading: SCContentStyle.mac.spaceGutter,
                        bottom: SCContentStyle.mac.spaceHair,
                        trailing: SCContentStyle.mac.spaceGutter
                    ))
                    .onAppear {
                        guard model.items.isNearEnd(activity, lead: 8) else { return }
                        Task { await model.loadMore() }
                    }
                    .onAppear {
                        let items = model.items
                        let lookahead = items[index..<min(index + Self.artworkLookahead, items.count)]
                        ArtworkCache.shared.prefetch(lookahead.compactMap { $0.track?.artworkURL ?? $0.playlist?.artworkURL })
                    }
            }
            if model.isLoadingMore {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, 8)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
    }

    private var signedOutState: some View {
        MacSignedOutEmptyState(
            title: "Stream Needs an Account",
            message: "Sign in to see what the people you follow are posting. Home and Search work without an account.",
            browsableRoute: .home
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FeedActivityRow: View {
    let activity: FeedActivity
    let context: () -> [Track]
    @ObservedObject var player: PlayerService
    @State private var artwork: NSImage?
    @State private var isHovering = false

    private let style = SCContentStyle.mac
    private static let artworkSize: CGFloat = 56

    private var isPlaylist: Bool { activity.playlist != nil }
    private var isPlayableTrack: Bool { activity.track == nil || activity.track?.streamURL != nil }

    private var isCurrent: Bool {
        guard let track = activity.track else { return false }
        return player.currentTrack?.id == track.id
    }

    private var title: String { activity.track?.title ?? activity.playlist?.title ?? "" }

    private var subtitle: String {
        if let playlist = activity.playlist {
            let count = playlist.trackCount
            return "\(count) track\(count == 1 ? "" : "s") · \(playlist.user.displayName)"
        }
        return activity.track?.user.displayName ?? ""
    }

    var body: some View {
        HStack(alignment: .center, spacing: style.spaceBase) {
            artworkView

            VStack(alignment: .leading, spacing: style.spaceHair) {
                if activity.isRepost {
                    Label("Reposted by \(activity.actor.displayName)", systemImage: "arrow.2.squarepath")
                        .font(style.fontCaptionEmphasis)
                        .foregroundStyle(style.textSecondary)
                }

                Text(title)
                    .font(style.fontHeadline)
                    .foregroundStyle(isPlayableTrack ? style.textPrimary : style.textTertiary)
                    .lineLimit(1)

                HStack(spacing: style.spaceHair) {
                    if isPlaylist {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    Text(subtitle)
                        .lineLimit(1)
                }
                .font(isPlaylist ? style.fontCaptionEmphasis : style.fontSubheadline)
                .foregroundStyle(style.textSecondary)
            }

            Spacer(minLength: style.spaceTight)

            trailing
        }
        .padding(.vertical, style.spaceSnug)
        .padding(.horizontal, style.spaceSnug)
        .opacity(isPlayableTrack ? 1 : 0.72)
        .contentShape(Rectangle())
        .macHoverRowHighlight(cornerRadius: style.cornerCard)
        .onHover { isHovering = $0 }
        .onTapGesture(perform: primaryAction)
        .contextMenu { contextMenuItems }
        .task(id: artworkURL) { await loadArtwork() }
        .help(isPlayableTrack ? "" : "No playable source for this track on this account.")
    }

    @ViewBuilder
    private var artworkView: some View {
        SCArtwork(image: artwork.map { Image(nsImage: $0) }, identity: title, isAvailable: isPlayableTrack, style: style, cornerRadius: style.cornerControl)
            .frame(width: Self.artworkSize, height: Self.artworkSize)
            .kyleCrowned(user: activity.track?.user ?? activity.playlist?.user, context: title)
            .overlay {
                if isHovering, activity.track != nil, isPlayableTrack, !(isCurrent && player.isPlaying) {
                    ZStack {
                        Color.black.opacity(0.4)
                        Image(systemName: "play.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: style.cornerControl, style: .continuous))
                }
            }
    }

    private var artworkURL: URL? { activity.track?.artworkURL ?? activity.playlist?.artworkURL }

    private func loadArtwork() async {
        for url in MacCollectionCover.artworkURLs(for: activity).prefix(1) {
            if let image = await ArtworkCache.shared.image(for: url, variant: .standard) {
                artwork = image
                return
            }
        }
        artwork = nil
    }

    @ViewBuilder
    private var trailing: some View {
        if isPlaylist {
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(style.textTertiary)
        } else if let track = activity.track {
            if isCurrent, player.isLoading {
                ProgressView().controlSize(.small)
            } else if isCurrent, player.isPlaying {
                Image(systemName: "waveform")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(style.spaceTight)
                    .background(.black.opacity(0.45), in: Circle())
            } else if track.streamURL != nil {
                HStack(spacing: style.spaceHair) {
                    Image(systemName: "waveform")
                        .font(.system(size: 10))
                        .foregroundStyle(style.textTertiary)
                    Text(track.formattedDuration)
                        .font(style.fontCaptionEmphasis)
                        .monospacedDigit()
                        .foregroundStyle(style.textSecondary)
                }
            } else {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(style.textTertiary)
            }
        }
    }

    private func primaryAction() {
        if let track = activity.track {
            guard track.streamURL != nil else { return }
            Task { await player.play(track, in: context()) }
        } else if let playlist = activity.playlist {
            MacRootSelection.shared.request(playlist: playlist)
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        if let track = activity.track {
            MacTrackContextMenu(track: track, context: context())
        } else if let playlist = activity.playlist {
            Button("Open on SoundCloud") { NSWorkspace.shared.open(playlist.permalinkURL) }
            Button("Copy SoundCloud Link") { copyToPasteboard(playlist.permalinkURL) }
        }
    }
}

private func copyToPasteboard(_ url: URL) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url.absoluteString, forType: .string)
}
