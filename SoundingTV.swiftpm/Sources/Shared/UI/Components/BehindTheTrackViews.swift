import SwiftUI

struct BehindTheTrackActions {
    var openUser: (User) -> Void
    var search: ((String) -> Void)? = nil
    var seek: ((TimeInterval) -> Void)? = nil
    var openTracklist: (() -> Void)? = nil
    var openAlbum: ((Playlist) -> Void)? = nil
}

struct BehindTheTrackContent<Insights: View>: View {
    @ObservedObject var model: BehindTheTrackModel
    let actions: BehindTheTrackActions
    var showsHeader = false
    var loadedCommentCount: Int? = nil
    @ViewBuilder var insights: () -> Insights

    @ObservedObject private var summaries = AnalysisSummaries.shared
    @ObservedObject private var setlists = SetlistIntelligenceStore.shared
    @ObservedObject private var recents = RecentlyPlayed.shared

    private var track: Track { model.track }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if showsHeader {
                header
            } else if track.supportsSoundCloudActions {
                uploader
            }

            people

            if track.supportsSoundCloudActions {
                stats
            }

            if let text = model.descriptionText {
                TrackDescriptionText(text: text, duration: track.duration, onSeek: actions.seek)
            }

            insights()

            if model.genre != nil || !model.tags.isEmpty {
                tags
            }

            details

            if track.supportsSoundCloudActions {
                links
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: track.id) { await model.load() }
        .task(id: track.id) { _ = summaries.summary(for: track) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            SCArtworkResolver(url: track.artworkURL, variant: .thumbnail) { image in
                SCArtwork(image: image, identity: track.id, cornerRadius: 10)
            }
            .frame(width: 96, height: 96)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.title3.weight(.bold))
                    .lineLimit(3)
                    .accessibilityAddTraits(.isHeader)
                if track.supportsSoundCloudActions {
                    Button { actions.openUser(track.user) } label: {
                        Text(track.user.displayName)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityHint("Opens their profile")
                } else {
                    Text(track.user.displayName)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var uploader: some View {
        SoundCloudUploaderRow(user: track.user, avatarSize: 44, spacing: 12, postsMusic: true) { actions.openUser(track.user) }
    }

    // MARK: - People

    @ViewBuilder
    private var people: some View {
        switch model.people {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("People You Follow")
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .accessibilityElement(children: .combine)
        case .loaded(let found) where found.isEmpty:
            Text("No one you follow has liked or reposted this yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .loaded(let found):
            VStack(alignment: .leading, spacing: 22) {
                if !found.likers.isEmpty {
                    FollowedPeopleGroup(title: "Liked by People You Follow", users: found.likers, openUser: actions.openUser)
                }
                if !found.reposters.isEmpty {
                    FollowedPeopleGroup(title: "Reposted by People You Follow", users: found.reposters, openUser: actions.openUser)
                }
            }
        case .unavailable:
            EmptyView()
        }
    }

    // MARK: - Stats

    private var stats: some View {
        HStack(alignment: .top, spacing: 8) {
            stat(track.playbackCount.map(BehindTheTrackFormat.compact) ?? "—", "Plays")
            stat(BehindTheTrackFormat.compact(track.likeCount), "Likes")
            stat(BehindTheTrackFormat.compact(track.repostCount), "Reposts")
            stat(model.commentCount(loaded: loadedCommentCount).map(BehindTheTrackFormat.compact) ?? "—", "Comments")
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Tags

    private var tags: some View {
        ChipFlowLayout(spacing: 6) {
            if let genre = model.genre {
                chip(genre, query: genre)
            }
            ForEach(model.tags, id: \.self) { tag in
                chip("#\(tag)", query: tag)
            }
        }
    }

    @ViewBuilder
    private func chip(_ title: String, query: String) -> some View {
        if let search = actions.search {
            Button(title) { search(query) }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .tint(.primary)
                .accessibilityHint("Searches for \(query)")
        } else {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.quaternary, in: Capsule())
        }
    }

    // MARK: - Details

    private var details: some View {
        let tracklistCount = setlists.tracklist(for: track.id)?.entries.count
        let summary = summaries.summary(for: track.id)
        let facts = model.facts(
            analysis: summary,
            pendingAnalysis: TrackTempoKey.pendingMessage(for: track),
            lastPlayed: recents.items.first { $0.track.id == track.id }?.playedAt,
            tracklistCount: tracklistCount
        )
        return VStack(spacing: 0) {
            Divider()
            ForEach(facts) { fact in
                factRow(fact)
                Divider()
            }
        }
    }

    private func action(for fact: BehindTheTrackFact) -> (action: () -> Void, hint: String)? {
        if fact.opensTracklist, let openTracklist = actions.openTracklist {
            return (openTracklist, "Shows the tracklist")
        }
        if fact.opensAlbum, let openAlbum = actions.openAlbum, let album = track.knownAlbum {
            return ({ openAlbum(album) }, "Opens the album")
        }
        return nil
    }

    @ViewBuilder
    private func factRow(_ fact: BehindTheTrackFact) -> some View {
        if let opens = action(for: fact) {
            Button(action: opens.action) {
                HStack {
                    Text(fact.label).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Text(fact.value).fontWeight(.medium).foregroundStyle(.primary)
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .font(.subheadline)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(opens.hint)
        } else {
            LabeledContent {
                Text(fact.value)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.trailing)
                    .modifier(SelectableFact(isOn: fact.isSelectable))
            } label: {
                Text(fact.label).foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .padding(.vertical, 11)
        }
    }

    // MARK: - Links

    private var links: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let url = model.about?.purchaseURL {
                Link(destination: url) {
                    Label(model.about?.purchaseTitle ?? "Buy", systemImage: "bag")
                }
            }
            if model.about?.isDownloadable == true {
                Link(destination: track.permalinkURL) {
                    Label("Free Download on SoundCloud", systemImage: "arrow.down.circle")
                }
            }
            Link(destination: track.permalinkURL) {
                Label("Open on SoundCloud", systemImage: "arrow.up.forward.app")
            }
        }
        .font(.subheadline.weight(.semibold))
    }

}

enum BehindTheTrackFormat {
    static func compact(_ value: Int) -> String {
        CompactCount.string(value)
    }

    static func followers(_ count: Int) -> String {
        count == 1 ? "1 follower" : "\(compact(count)) followers"
    }
}

extension BehindTheTrackContent where Insights == EmptyView {
    init(model: BehindTheTrackModel, actions: BehindTheTrackActions, showsHeader: Bool = false, loadedCommentCount: Int? = nil) {
        self.init(model: model, actions: actions, showsHeader: showsHeader, loadedCommentCount: loadedCommentCount) { EmptyView() }
    }
}

private struct SelectableFact: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content.textSelection(.enabled)
        } else {
            content
        }
    }
}

struct FollowedPeopleGroup: View {
    let title: String
    let users: [User]
    let openUser: (User) -> Void

    @State private var showsAll = false

    static let previewCount = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 10) {
                BehindTheTrackAvatarStack(users: Array(users.prefix(5)), size: 30)
                Text(BehindTheTrackModel.peopleSummary(users))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .accessibilityElement(children: .combine)
            VStack(spacing: 0) {
                ForEach(showsAll ? users : Array(users.prefix(Self.previewCount)), id: \.id) { user in
                    Button { openUser(user) } label: {
                        HStack(spacing: 12) {
                            BehindTheTrackAvatar(user: user, size: 32)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(user.displayName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                if user.followersCount > 0 {
                                    Text(BehindTheTrackFormat.followers(user.followersCount))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.forward")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens their profile")
                }
            }
            if users.count > Self.previewCount {
                Button(showsAll ? "Show Less" : "Show All \(users.count)") {
                    withAnimation(.snappy) { showsAll.toggle() }
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderless)
            }
        }
    }
}

struct BehindTheTrackAvatar: View {
    let user: User
    let size: CGFloat

    var body: some View {
        SCArtworkResolver(url: user.avatarURL, variant: .thumbnail) { image in
            SCArtwork(image: image, identity: user.id, cornerRadius: 0, subject: .person)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

struct BehindTheTrackAvatarStack: View {
    let users: [User]
    let size: CGFloat

    var body: some View {
        HStack(spacing: -size * 0.32) {
            ForEach(Array(users.enumerated()), id: \.element.id) { index, user in
                BehindTheTrackAvatar(user: user, size: size)
                    .overlay { Circle().strokeBorder(.background, lineWidth: 2) }
                    .zIndex(Double(users.count - index))
            }
        }
        .accessibilityHidden(true)
    }
}

struct TrackDescriptionText: View {
    let text: String
    let onSeek: ((TimeInterval) -> Void)?
    private let attributed: AttributedString

    @State private var expanded = false

    static let collapsedLines = 6

    init(text: String, duration: TimeInterval, onSeek: ((TimeInterval) -> Void)?) {
        self.text = text
        self.onSeek = onSeek
        attributed = TrackDescriptionLinks.attributed(text, duration: duration, linksTimestamps: onSeek != nil)
    }

    private var isLong: Bool {
        text.count > 280 || text.filter(\.isNewline).count >= Self.collapsedLines
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(attributed)
                .font(.subheadline)
                .lineSpacing(3)
                .lineLimit(expanded ? nil : Self.collapsedLines)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.openURL, OpenURLAction { url in
                    guard let seconds = TrackDescriptionLinks.seconds(from: url) else { return .systemAction }
                    onSeek?(seconds)
                    return .handled
                })
            if isLong {
                Button(expanded ? "Less" : "More") {
                    withAnimation(.snappy) { expanded.toggle() }
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderless)
            }
        }
    }
}

struct BehindTheTrackMenuButton: View {
    let track: Track

    var body: some View {
        Button {
            BehindTheTrackPresenter.shared.present(track)
        } label: {
            Label("Behind the Track", systemImage: "info.circle")
        }
    }
}

extension View {
    func behindTheTrackHost<Sheet: View>(@ViewBuilder sheet: @escaping (Track) -> Sheet) -> some View {
        modifier(BehindTheTrackHost(sheet: sheet))
    }
}

private struct BehindTheTrackHost<Sheet: View>: ViewModifier {
    let sheet: (Track) -> Sheet

    @ObservedObject private var presenter = BehindTheTrackPresenter.shared
    @State private var id = UUID()

    init(sheet: @escaping (Track) -> Sheet) {
        self.sheet = sheet
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(
                get: { presenter.isActive(id) ? presenter.track : nil },
                set: { if presenter.isActive(id) { presenter.track = $0 } }
            )) { track in
                sheet(track)
            }
            .onAppear { presenter.register(id) }
            .onDisappear { presenter.unregister(id) }
    }
}

struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var line: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += line + spacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            line = max(line, size.height)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var line: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += line + spacing
                x = bounds.minX
                line = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
