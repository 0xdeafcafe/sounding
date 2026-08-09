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
    case details
    case comments
    case behind
    case upNext
}

enum NowPlayingLowerPanel: String, CaseIterable, Identifiable {
    case comments = "Comments"
    case upNext = "Up Next"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .comments: return "bubble.left.and.bubble.right"
        case .upNext: return "text.line.last.and.arrowtriangle.forward"
        }
    }
}

private enum NowPlayingCommentSort: String, CaseIterable, Identifiable {
    case trackTime = "Track time"
    case newest = "Newest"
    case oldest = "Oldest"

    var id: Self { self }

    var systemImage: String {
        switch self {
        case .trackTime: return "clock"
        case .newest: return "arrow.down"
        case .oldest: return "arrow.up"
        }
    }
}

// MARK: - Comments (§4.1 — the feed below the fold, no longer a modal sheet)

struct NowPlayingCommentsSection: View {
    @ObservedObject var store: PhoneWaveformStore
    let accent: Color
    let trackId: String?
    let playbackAnchorPosition: TimeInterval
    let playbackAnchorDate: Date
    let isPlaying: Bool
    let duration: TimeInterval
    let viewportHeight: CGFloat
    let onSeek: (TimeInterval) -> Void

    @Environment(\.openURL) private var openURL
    @State private var isShowingSignIn = false
    @State private var sort: NowPlayingCommentSort = .trackTime
    @State private var activeCommentIDs: Set<String> = []
    @State private var playbackCommentID: String?
    @State private var commentContentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            HStack(alignment: .center, spacing: Space.tight) {
                SCEyebrow("COMMENTS", tint: accent, style: .phone)
                Spacer(minLength: Space.tight)
                if store.commentsState == .loaded, !store.comments.isEmpty {
                    sortMenu
                }
            }
            content
                .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: Corner.card, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: Corner.card, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: playbackTaskID) {
            await followPlayback()
        }
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
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: Space.tight) {
                    ForEach(sortedThreads) { thread in
                        VStack(alignment: .leading, spacing: Space.hair) {
                            commentRow(thread.root)
                                .id(thread.root.id)

                            ForEach(thread.replies) { reply in
                                commentRow(reply, isReply: true)
                                    .id(reply.id)
                            }
                        }
                    }
                }
                .padding(.vertical, Space.tight)
                .padding(.leading, Space.tight)
                .padding(.trailing, sort == .trackTime ? Space.snug : Space.tight)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    commentContentHeight = height
                }
            }
            .scrollDisabled(commentContentHeight <= viewportHeight + 1)
            .scrollIndicators(commentContentHeight > viewportHeight + 1 ? .visible : .hidden)
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(viewportHeight, max(1, commentContentHeight)), alignment: .top)
            .onChange(of: playbackCommentID) { _, commentID in
                guard sort == .trackTime,
                      commentContentHeight > viewportHeight + 1,
                      let commentID else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(commentID, anchor: .center)
                }
            }
            .overlay(alignment: .trailing) {
                if sort == .trackTime,
                   duration > 0,
                   commentContentHeight > viewportHeight + 1 {
                    CommentPlaybackPositionIndicator(
                        anchorPosition: playbackAnchorPosition,
                        anchorDate: playbackAnchorDate,
                        isPlaying: isPlaying,
                        duration: duration,
                        accent: accent
                    )
                    .frame(width: 6)
                    .padding(.vertical, Space.tight)
                }
            }
        }
    }

    private func commentRow(_ comment: Comment, isReply: Bool = false) -> some View {
        NowPlayingCommentRow(
            comment: comment,
            isReply: isReply,
            isActive: activeCommentIDs.contains(comment.id),
            accent: accent,
            trackURL: store.resolvedTrack?.permalinkURL,
            onSearch: searchAction(for: comment),
            onSeek: comment.timeInTrack.map { time in { onSeek(time) } }
        )
    }

    private var sortMenu: some View {
        Menu {
            Picker("Comment order", selection: $sort) {
                ForEach(NowPlayingCommentSort.allCases) { option in
                    Label(option.rawValue, systemImage: option.systemImage)
                        .tag(option)
                }
            }
        } label: {
            Label(sort.rawValue, systemImage: "arrow.up.arrow.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.78))
                .padding(.horizontal, Space.tight)
                .frame(height: 32)
                .background(.white.opacity(0.08), in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sort comments, \(sort.rawValue)")
    }

    private var sortedThreads: [CommentThread] {
        let built = CommentThreadBuilder.build(store.comments)
        let threads = built.timed + built.untimed
        return threads.sorted { lhs, rhs in
            switch sort {
            case .trackTime:
                switch (lhs.root.timeInTrack, rhs.root.timeInTrack) {
                case let (left?, right?) where left != right: return left < right
                case (.some, nil): return true
                case (nil, .some): return false
                default: return commentDate(lhs.root) > commentDate(rhs.root)
                }
            case .newest:
                let left = commentDate(lhs.root)
                let right = commentDate(rhs.root)
                return left == right ? lhs.id > rhs.id : left > right
            case .oldest:
                let left = commentDate(lhs.root)
                let right = commentDate(rhs.root)
                return left == right ? lhs.id < rhs.id : left < right
            }
        }
    }

    private func commentDate(_ comment: Comment) -> Date {
        comment.createdAt ?? .distantPast
    }

    private var playbackTaskID: String {
        let anchorMillis = Int((playbackAnchorPosition * 1_000).rounded())
        return "\(trackId ?? "-")#\(anchorMillis)#\(isPlaying)#\(store.comments.count)"
    }

    private func followPlayback() async {
        while !Task.isCancelled {
            let position = estimatedPlaybackPosition(at: .now)
            let active = Set(store.comments.compactMap { comment -> String? in
                guard let time = comment.timeInTrack,
                      position >= time - SCCommentTimeline.leadSeconds,
                      position <= time + SCCommentTimeline.lingerSeconds else { return nil }
                return comment.id
            })
            if active != activeCommentIDs { activeCommentIDs = active }

            let current = store.comments
                .compactMap { comment -> (String, TimeInterval)? in
                    guard let time = comment.timeInTrack,
                          time <= position + SCCommentTimeline.leadSeconds else { return nil }
                    return (comment.id, time)
                }
                .max(by: { $0.1 < $1.1 })?
                .0
            if current != playbackCommentID { playbackCommentID = current }
            guard isPlaying else { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private func estimatedPlaybackPosition(at date: Date) -> TimeInterval {
        guard isPlaying else { return min(duration, max(0, playbackAnchorPosition)) }
        return min(duration, max(0, playbackAnchorPosition + date.timeIntervalSince(playbackAnchorDate)))
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

// A flat comment feed: comments are intentionally not nested. Only the time
// badge seeks, so browsing and sorting the feed never moves the page.
private struct NowPlayingCommentRow: View {
    let comment: Comment
    let isReply: Bool
    let isActive: Bool
    let accent: Color
    let trackURL: URL?
    let onSearch: (() -> Void)?
    let onSeek: (() -> Void)?

    private var avatarSize: CGFloat { isReply ? 30 : 36 }

    var body: some View {
        HStack(alignment: .top, spacing: Space.snug) {
            if isReply {
                Capsule(style: .continuous)
                    .fill(.white.opacity(0.16))
                    .frame(width: 2, height: avatarSize)
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
                        Button { onSeek?() } label: {
                            Label(CommentFormat.clock(time), systemImage: "play.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(isActive ? .white : accent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    isActive ? accent.opacity(0.72) : accent.opacity(0.16),
                                    in: Capsule(style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Play from \(CommentFormat.clock(time))")
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
        .padding(.horizontal, Space.snug)
        .padding(.vertical, Space.tight)
        .padding(.leading, isReply ? Space.roomy : 0)
        .background(
            RoundedRectangle(cornerRadius: Corner.card, style: .continuous)
                .fill(isActive ? accent.opacity(0.18) : .white.opacity(isReply ? 0.035 : 0.055))
        )
        .overlay(alignment: .leading) {
            if isActive {
                Capsule(style: .continuous)
                    .fill(accent)
                    .frame(width: 3)
                    .padding(.vertical, Space.tight)
            }
        }
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityValue(isActive ? "Playing now" : "")
    }

    private var accessibilitySummary: String {
        var parts = [comment.user.displayName]
        if isReply { parts.append("reply") }
        if let time = comment.timeInTrack { parts.append("at \(CommentFormat.clock(time))") }
        parts.append(comment.body)
        return parts.joined(separator: ", ")
    }
}

private struct CommentPlaybackPositionIndicator: View {
    let anchorPosition: TimeInterval
    let anchorDate: Date
    let isPlaying: Bool
    let duration: TimeInterval
    let accent: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            GeometryReader { proxy in
                let fraction = playbackFraction(at: context.date)
                ZStack(alignment: .top) {
                    Capsule(style: .continuous)
                        .fill(.white.opacity(0.10))
                        .frame(width: 2)

                    Capsule(style: .continuous)
                        .fill(accent)
                        .frame(width: 4, height: 22)
                        .shadow(color: accent.opacity(0.45), radius: 4)
                        .offset(y: max(0, (proxy.size.height - 22) * fraction))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func playbackFraction(at date: Date) -> CGFloat {
        guard duration > 0 else { return 0 }
        let elapsed = isPlaying ? date.timeIntervalSince(anchorDate) : 0
        return CGFloat(min(1, max(0, (anchorPosition + elapsed) / duration)))
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
            HStack(alignment: .firstTextBaseline) {
                SCEyebrow("UP NEXT", tint: accent, style: .phone)
                Spacer()
                Text("\(entries.count) queued")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
            }

            LazyVStack(alignment: .leading, spacing: Space.tight) {
                ForEach(Array(entries.prefix(Self.visibleCount).enumerated()), id: \.element.id) { index, entry in
                    row(entry, position: index + 1)
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

    private func row(_ entry: PhonePlaybackCoordinator.UpNextEntry, position: Int) -> some View {
        HStack(spacing: Space.snug) {
            Text("\(position)")
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundStyle(accent)
                .frame(width: 18)

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
        .padding(Space.tight)
        .background(
            RoundedRectangle(cornerRadius: Corner.card, style: .continuous)
                .fill(.white.opacity(0.055))
        )
        .accessibilityElement(children: .combine)
    }
}
