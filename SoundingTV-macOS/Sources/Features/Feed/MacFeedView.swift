import SwiftUI
import AppKit

struct MacFeedView: View {
    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    @ObservedObject private var model: FeedViewModel
    private let showsHeader: Bool

    init(model: FeedViewModel, showsHeader: Bool = true) {
        self.model = model
        self.showsHeader = showsHeader
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.001))
            .task { await loadFeedIfNeeded() }
    }

    private enum MacFeedState: Equatable {
        case loading, loaded, empty
        case error(String)
    }

    private var feedState: MacFeedState {
        if !model.items.isEmpty { return .loaded }
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

    @ViewBuilder
    private var content: some View {
        if credentials.isSignedOut {
            signedOutState
        } else {
            switch feedState {
            case .loading:
                MacLoadingView()
            case .error(let message):
                ContentUnavailableView {
                    Label("Couldn’t Load Following", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { Task { await loadFeed() } }
                }
                .macFillsPane()
            case .empty:
                ContentUnavailableView {
                    Label("Nothing Here Yet", systemImage: "dot.radiowaves.up.forward")
                } description: {
                    Text("Follow artists on SoundCloud and their uploads, playlists and reposts will show up here.")
                } actions: {
                    Button("Search SoundCloud") { MacRootSelection.shared.request(.search) }
                }
                .macFillsPane()
            case .loaded:
                list
            }
        }
    }

    private static let artworkLookahead = 10

    private var list: some View {
        List {
            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, activity in
                FeedActivityRow(activity: activity, context: { model.items.compactMap(\.track) })
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(
                        top: SCContentStyle.mac.spaceHair,
                        leading: SCContentStyle.mac.spaceGutter,
                        bottom: SCContentStyle.mac.spaceHair,
                        trailing: SCContentStyle.mac.spaceGutter
                    ))
                    .onAppear { model.pager.loadMoreIfNeeded(after: activity, lead: 12) }
                    .onAppear {
                        let items = model.items
                        let lookahead = items[index..<min(index + Self.artworkLookahead, items.count)]
                        ArtworkCache.shared.prefetch(lookahead.compactMap { $0.track?.artworkURL ?? $0.playlist?.displayArtworkURL })
                    }
            }
            MacPagedFooter(pager: model.pager, isInLazyContainer: true)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
    }

    private var signedOutState: some View {
        MacSignedOutEmptyState(
            title: "Following Needs an Account",
            message: "Sign in to see what the people you follow are posting. Home and Search work without an account.",
            browsableRoute: .home
        )
    }
}

private struct FeedActivityRow: View {
    let activity: FeedActivity
    let context: () -> [Track]
    private let player = PlayerService.shared
    private let playback = PlaybackIndicatorStore.shared
    @State private var isHovering = false

    private let style = SCContentStyle.mac
    private static let artworkSize: CGFloat = 56

    private var isPlaylist: Bool { activity.playlist != nil }
    private var isPlayableTrack: Bool { activity.track == nil || activity.track?.streamURL != nil }

    private var isCurrent: Bool {
        guard let track = activity.track else { return false }
        return playback.isCurrent(track.id)
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
        Button(action: primaryAction) {
            HStack(alignment: .center, spacing: style.spaceBase) {
                artworkView

                VStack(alignment: .leading, spacing: style.spaceHair) {
                    if let promotedLabel = activity.promotedLabel {
                        Text(promotedLabel)
                            .font(style.fontCaptionEmphasis)
                            .foregroundStyle(style.textSecondary)
                    } else if activity.isRepost {
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
                                .font(.caption2.weight(.semibold))
                                .accessibilityHidden(true)
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
        }
        .buttonStyle(.plain)
        .macHoverRowHighlight(cornerRadius: style.cornerCard)
        .onHover { isHovering = $0 }
        .contextMenu { contextMenuItems }
        .promotedImpression(activity)
        .help(isPlayableTrack ? "" : "No playable source for this track on this account.")
        .accessibilityLabel(accessibilitySummary)
        .modifier(FeedTrackAccessibility(track: activity.track, context: context, isCurrent: isCurrent))
    }

    private var accessibilitySummary: String {
        var parts: [String] = []
        if let promotedLabel = activity.promotedLabel {
            parts.append(promotedLabel)
        } else if activity.isRepost {
            parts.append("Reposted by \(activity.actor.displayName)")
        }
        if let track = activity.track {
            parts.append(macTrackAccessibilityLabel(track, isCurrent: isCurrent))
        } else {
            parts.append("\(title), playlist, \(subtitle)")
        }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var artworkView: some View {
        SCArtworkResolver(url: MacCollectionCover.artworkURLs(for: activity).first, variant: .standard) { artwork in
            SCArtwork(image: artwork, identity: activity.track?.id ?? activity.playlist?.id ?? title, isAvailable: isPlayableTrack, style: style, cornerRadius: style.cornerControl)
        }
            .frame(width: Self.artworkSize, height: Self.artworkSize)
            .kyleCrowned(user: activity.track?.user ?? activity.playlist?.user, context: title)
            .overlay {
                if isHovering, activity.track != nil, isPlayableTrack, !(isCurrent && playback.isPlaying) {
                    ZStack {
                        Color.black.opacity(0.4)
                        Image(systemName: "play.fill")
                            .font(.body.weight(.bold))
                            .foregroundStyle(.white)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: style.cornerControl, style: .continuous))
                }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var trailing: some View {
        Group {
            if isPlaylist {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(style.textTertiary)
            } else if let track = activity.track {
                if isCurrent, playback.isLoading {
                    ProgressView().controlSize(.small)
                } else if isCurrent, playback.isPlaying {
                    Image(systemName: "waveform")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(style.spaceTight)
                        .background(.black.opacity(0.45), in: Circle())
                } else if track.streamURL != nil {
                    HStack(spacing: style.spaceHair) {
                        Image(systemName: "waveform")
                            .font(.caption2)
                            .foregroundStyle(style.textTertiary)
                        Text(SubscriptionService.shared.displayedDuration(for: track))
                            .font(style.fontCaptionEmphasis)
                            .monospacedDigit()
                            .foregroundStyle(style.textSecondary)
                    }
                } else {
                    Image(systemName: "lock.fill")
                        .font(.subheadline)
                        .foregroundStyle(style.textTertiary)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func primaryAction() {
        if let track = activity.track {
            guard track.streamURL != nil else { return }
            PromotedTracking.shared.record(.play, for: activity)
            Task { await MacPlayback.play(track, in: context()) }
        } else if let playlist = activity.playlist {
            PromotedTracking.shared.record(.click, for: activity)
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

private struct FeedTrackAccessibility: ViewModifier {
    let track: Track?
    let context: () -> [Track]
    let isCurrent: Bool

    func body(content: Content) -> some View {
        if let track {
            content.macTrackAccessibility(track: track, context: context(), isCurrent: isCurrent)
        } else {
            content
        }
    }
}

private func copyToPasteboard(_ url: URL) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url.absoluteString, forType: .string)
}
