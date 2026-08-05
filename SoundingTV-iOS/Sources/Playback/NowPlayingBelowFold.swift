import SwiftUI
import UIKit

// Below-fold sections of the phone Now Playing sheet (ios-design-spec §3.8,
// §4.1, §4.2). Order in the scrolled page: Comments → Behind This Track →
// Up Next. All content here is flat — glass is chrome only, and none of this
// is chrome.

// Scroll anchors for the Now Playing sheet's below-fold sections. The utility
// row buttons and comment-row taps scroll to these.
enum NowPlayingSection: Hashable {
    case player
    case comments
    case behind
    case upNext
}

enum NowPlayingLowerPanel: String, CaseIterable, Identifiable {
    case comments = "Comments"
    case upNext = "Up Next"

    var id: Self { self }
}

// MARK: - Comments (§4.1 — the feed below the fold, no longer a modal sheet)

struct NowPlayingCommentsSection: View {
    @ObservedObject var store: PhoneWaveformStore
    let accent: Color
    let trackId: String?
    /// Seek + scroll back to the player.
    let onSeek: (TimeInterval) -> Void

    @Environment(\.openURL) private var openURL
    @State private var isShowingSignIn = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            SCEyebrow("COMMENTS", tint: accent, style: .phone)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $isShowingSignIn) {
            NavigationStack {
                SoundCloudLoginView.standalone {
                    isShowingSignIn = false
                    SoundCloudCredentialSource.shared.refreshFromStore()
                    store.retry(trackId: trackId)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch store.commentsState {
        case .idle, .loading:
            HStack(spacing: Space.tight) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.7))
                Text("Loading comments…")
                    .font(.scSubhead)
                    .foregroundStyle(.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, Space.roomy)
        case .signedOut:
            ContentUnavailableView {
                Label("Sign In Required", systemImage: "person.crop.circle.badge.questionmark")
            } description: {
                Text("Comments use this iPhone's own SoundCloud sign-in, separate from your Apple TV Link.")
            } actions: {
                Button("Sign In to SoundCloud") { isShowingSignIn = true }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)
            }
        case .failed:
            ContentUnavailableView(
                "Couldn't Load Comments",
                systemImage: "wifi.slash",
                description: Text("Check your connection and try again.")
            )
        case .loaded where store.comments.isEmpty:
            ContentUnavailableView(
                "No Comments Yet",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Nobody has commented on this track.")
            )
        case .loaded:
            commentList
        }
    }

    private var commentList: some View {
        let threadSet = CommentThreadBuilder.build(store.comments)
        return LazyVStack(alignment: .leading, spacing: 0) {
            if !threadSet.timed.isEmpty {
                subsectionHeader("On This Track")
                ForEach(threadSet.timed) { thread in
                    threadRows(thread)
                }
            }
            if !threadSet.untimed.isEmpty {
                subsectionHeader("General")
                ForEach(threadSet.untimed) { thread in
                    threadRows(thread)
                }
            }
        }
    }

    private func subsectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .bold))
            .kerning(1.1)
            .foregroundStyle(.white.opacity(0.45))
            .padding(.top, Space.tight)
            .padding(.bottom, Space.hair)
    }

    @ViewBuilder
    private func threadRows(_ thread: CommentThread) -> some View {
        commentRow(thread.root, isReply: false)
        ForEach(thread.replies) { reply in
            commentRow(reply, isReply: true)
        }
    }

    private func commentRow(_ comment: Comment, isReply: Bool) -> some View {
        NowPlayingCommentRow(
            comment: comment,
            isReply: isReply,
            accent: accent,
            trackURL: store.resolvedTrack?.permalinkURL,
            onSearch: searchAction(for: comment),
            onSeek: comment.timeInTrack.map { time in { onSeek(time) } }
        )
    }

    private func searchAction(for comment: Comment) -> (() -> Void)? {
        guard let query = comment.searchQuery,
              let url = Self.soundCloudSearchURL(for: query) else { return nil }
        return { openURL(url) }
    }

    static func soundCloudSearchURL(for query: String) -> URL? {
        var components = URLComponents(string: "https://soundcloud.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }
}

// §4.1 feed row: 36pt avatar, name 14/semibold, timestamp badge in the palette
// accent 12/semibold, body 15/regular white 0.85. Tap seeks and scrolls back to
// the player; the context menu carries the phone-only copy/share affordances.
private struct NowPlayingCommentRow: View {
    let comment: Comment
    var isReply: Bool = false
    let accent: Color
    let trackURL: URL?
    let onSearch: (() -> Void)?
    let onSeek: (() -> Void)?

    private var avatarSize: CGFloat { isReply ? 28 : 36 }

    var body: some View {
        HStack(alignment: .top, spacing: Space.snug) {
            if isReply {
                Capsule(style: .continuous)
                    .fill(Color.scSeparator)
                    .frame(width: 2, height: avatarSize)
                    .padding(.leading, 17)
                    .padding(.trailing, -Space.snug + 2)
            }

            SCArtworkResolver(url: comment.user.avatarURL) { image in
                SCArtwork(
                    image: image,
                    identity: comment.user.username,
                    style: .phone,
                    cornerRadius: avatarSize / 2
                )
            }
            .frame(width: avatarSize, height: avatarSize)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Space.tight) {
                    Text(comment.user.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    if let time = comment.timeInTrack {
                        Text(CommentFormat.clock(time))
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(accent.opacity(0.16), in: Capsule(style: .continuous))
                    }

                    if let age = CommentFormat.age(of: comment.createdAt) {
                        Text(age)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(.white.opacity(0.46))
                    }
                }

                Text(comment.body)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture { onSeek?() }
        .contextMenu {
            if let onSearch {
                Button(action: onSearch) {
                    Label("Search for This", systemImage: "magnifyingglass")
                }
            }
            Button {
                UIPasteboard.general.string = comment.body
            } label: {
                Label("Copy Comment", systemImage: "doc.on.doc")
            }
            if let trackURL {
                ShareLink(item: trackURL) {
                    Label("Share Track", systemImage: "square.and.arrow.up")
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint(onSeek != nil ? "Seeks to this moment" : "")
    }

    private var accessibilitySummary: String {
        var parts = [comment.user.displayName]
        if isReply { parts.append("reply") }
        if let time = comment.timeInTrack { parts.append("at \(CommentFormat.clock(time))") }
        parts.append(comment.body)
        return parts.joined(separator: ", ")
    }
}

// MARK: - Behind This Track (§4.2 — flat content card, never glass)

struct NowPlayingBehindTrackCard: View {
    let track: Track
    let accent: Color

    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDescriptionExpanded = false

    private var model: SCBehindTrackModel { SCBehindTrackModel(track: track) }

    private var style: SCContentStyle {
        var style = SCContentStyle.phone
        style.accent = accent
        return style
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            SCEyebrow("BEHIND THIS TRACK", tint: accent, style: .phone)

            // An absence rendered as an absence: no description, no placeholder.
            if let description = model.description, !description.isEmpty {
                descriptionBlock(description)
            }

            SCStatsStrip(model: model, style: style)

            artistRow

            if model.genre != nil || model.label != nil || !model.tags.isEmpty {
                SCChipRow(model: model, style: style) { chip in
                    if let url = NowPlayingCommentsSection.soundCloudSearchURL(for: chip) {
                        openURL(url)
                    }
                }
            }

            HStack(alignment: .firstTextBaseline) {
                Text("Uploaded \(model.relativeUploadDate)")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.white.opacity(0.5))
                Spacer(minLength: Space.tight)
                Link(destination: model.permalinkURL) {
                    Text("Open on SoundCloud")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accent)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .scCard()
        .onChange(of: track.id) { _, _ in isDescriptionExpanded = false }
    }

    private func descriptionBlock(_ description: String) -> some View {
        VStack(alignment: .leading, spacing: Space.hair) {
            Text(description)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.white.opacity(0.94))
                .lineLimit(isDescriptionExpanded ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                withAnimation(.scMotion(SCContentMotion.gentle, reduceMotion: reduceMotion)) {
                    isDescriptionExpanded.toggle()
                }
            } label: {
                Text(isDescriptionExpanded ? "Less" : "More")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .buttonStyle(.plain)
        }
    }

    // 44pt avatar, name 16/semibold, follower count 13 white 0.55. The row is a
    // link to the artist's SoundCloud page; there is no follow endpoint in the
    // app, so no Follow affordance is rendered rather than a fake one.
    private var artistRow: some View {
        Link(destination: track.user.permalinkURL) {
            HStack(spacing: Space.snug) {
                SCArtworkResolver(url: model.uploaderAvatarURL) { image in
                    SCArtwork(
                        image: image,
                        identity: model.uploaderName,
                        style: style,
                        cornerRadius: 22
                    )
                }
                .frame(width: 44, height: 44)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.uploaderName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("\(track.user.formattedFollowers) followers")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }

                Spacer(minLength: Space.tight)

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Up Next (§3.8 — read-only render of the active queue)

struct NowPlayingUpNextSection: View {
    let entries: [PhonePlaybackCoordinator.UpNextEntry]
    let accent: Color

    private static let visibleCount = 10

    var body: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            SCEyebrow("UP NEXT", tint: accent, style: .phone)

            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(entries.prefix(Self.visibleCount)) { entry in
                    row(entry)
                }
            }

            if entries.count > Self.visibleCount {
                Text("+\(entries.count - Self.visibleCount) more")
                    .font(.scSubhead)
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.top, Space.hair)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ entry: PhonePlaybackCoordinator.UpNextEntry) -> some View {
        HStack(spacing: Space.snug) {
            AsyncImage(url: entry.artworkURL.flatMap { URL(string: $0) }?.soundCloudArtworkVariant("t200x200")) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    ZStack {
                        Color.white.opacity(0.08)
                        Image(systemName: "music.note")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: Corner.thumb, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.scBody.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(entry.artist)
                    .font(.scSubhead)
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(1)
            }

            Spacer(minLength: Space.tight)

            Text(entry.formattedDuration)
                .font(.scNumeric.monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}
