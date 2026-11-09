import SwiftUI
import Combine

extension User {
    var followerCountText: String {
        followersCount == 1 ? "1 follower" : "\(formattedFollowers) followers"
    }

    var trackCountText: String {
        trackCount == 1 ? "1 track" : "\(formattedTracks) tracks"
    }

    func countsLine(postsMusic: Bool = false) -> String {
        var parts: [String] = []
        if !isArtist, !postsMusic { parts.append(kindLabel) }
        if followersCount > 0 { parts.append(followerCountText) }
        if trackCount > 0 { parts.append(trackCountText) }
        return parts.joined(separator: " · ")
    }

    var locationText: String? {
        let parts = [city, country]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    var isVerified: Bool { verified == true }
}

extension Playlist {
    var releaseTypeWord: String {
        switch setType?.lowercased() {
        case "ep": "EP"
        case "single": "Single"
        case "compilation": "Compilation"
        case "album": "Album"
        default: CollectionPageKind(playlist: self).label
        }
    }

    var displayGenre: String? {
        genre.map(GenrePresentation.displayName(for:))
    }

    var displayTags: [String] {
        var seen = Set<String>()
        if let genre { seen.insert(genre.lowercased()) }
        return tags.filter { seen.insert($0.lowercased()).inserted }
    }

    var updatedText: String? {
        guard let lastModified, lastModified.timeIntervalSince(createdAt) > 60 else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Updated \(formatter.localizedString(for: lastModified, relativeTo: Date()))"
    }
}

extension CollectionRelatedModel {
    static func moreTitle(for user: User) -> String {
        user.isArtist ? "More by \(user.displayName)" : "More from \(user.displayName)"
    }
}

// MARK: - Text and tags

struct SoundCloudStatsText {
    static func text(_ base: String?, likes: Int, reposts: Int, isPrivate: Bool = false) -> Text? {
        var pieces: [Text] = []
        if let base, !base.isEmpty { pieces.append(Text(verbatim: base)) }
        if likes > 0 {
            pieces.append(Text("\(Image(systemName: "heart")) \(Text(verbatim: CompactCount.string(likes)))"))
        }
        if reposts > 0 {
            pieces.append(Text("\(Image(systemName: "arrow.2.squarepath")) \(Text(verbatim: CompactCount.string(reposts)))"))
        }
        guard var result = pieces.first else { return nil }
        for piece in pieces.dropFirst() {
            result = Text("\(result) · \(piece)")
        }
        return isPrivate ? Text("\(Image(systemName: "lock.fill")) \(result)") : result
    }

    static func accessibilityLabel(_ base: String?, likes: Int, reposts: Int, isPrivate: Bool = false) -> String {
        var parts: [String] = isPrivate ? ["Private"] : []
        if let base, !base.isEmpty { parts.append(base) }
        if likes > 0 { parts.append(likes == 1 ? "1 like" : "\(CompactCount.string(likes)) likes") }
        if reposts > 0 { parts.append(reposts == 1 ? "1 repost" : "\(CompactCount.string(reposts)) reposts") }
        return parts.joined(separator: ", ")
    }
}

struct SoundCloudExpandableText: View {
    let text: String
    var font: Font = .subheadline
    var lineLimit: Int = 3
    var alignment: TextAlignment = .leading

    @State private var isExpanded = false
    @State private var isTruncated = false

    init(_ text: String, font: Font = .subheadline, lineLimit: Int = 3, alignment: TextAlignment = .leading) {
        self.text = text
        self.font = font
        self.lineLimit = lineLimit
        self.alignment = alignment
    }

    private var horizontal: HorizontalAlignment {
        switch alignment {
        case .center: .center
        case .trailing: .trailing
        default: .leading
        }
    }

    var body: some View {
        VStack(alignment: horizontal, spacing: 4) {
            Text(TrackDescriptionLinks.attributed(text, duration: nil, linksTimestamps: false))
                .font(font)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(alignment)
                .lineLimit(isExpanded ? nil : lineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    if !isExpanded {
                        ViewThatFits(in: .vertical) {
                            Text(text)
                                .font(font)
                                .fixedSize(horizontal: false, vertical: true)
                                .hidden()
                                .onAppear { isTruncated = false }
                            Color.clear
                                .onAppear { isTruncated = true }
                        }
                        .accessibilityHidden(true)
                    }
                }
            #if !os(tvOS)
            if isTruncated || isExpanded {
                Button(isExpanded ? "Less" : "More") {
                    withAnimation(.snappy) { isExpanded.toggle() }
                }
                .font(font.weight(.semibold))
                .foregroundStyle(.primary)
                .buttonStyle(.plain)
                .accessibilityHint(isExpanded ? "Shows less of the description" : "Shows the whole description")
            }
            #endif
        }
    }
}

struct SoundCloudTagPills: View {
    let tags: [String]
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        if !tags.isEmpty {
            SoundCloudFlowLayout(spacing: 6, alignment: alignment) {
                ForEach(tags, id: \.self) { tag in
                    pill(tag)
                }
            }
        }
    }

    @ViewBuilder
    private func pill(_ tag: String) -> some View {
        #if os(tvOS)
        Text(verbatim: "#\(tag)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.quaternary, in: Capsule())
        #else
        Button {
            SearchRequestRouter.shared.search(tag)
        } label: {
            Text(verbatim: "#\(tag)")
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(.primary)
        .accessibilityLabel(tag)
        .accessibilityHint("Searches for \(tag)")
        #endif
    }
}

struct SoundCloudFlowLayout: Layout {
    var spacing: CGFloat = 6
    var alignment: HorizontalAlignment = .leading

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[(index: Int, size: CGSize)]] {
        var rows: [[(index: Int, size: CGSize)]] = [[]]
        var x: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append((index, size))
            x += size.width + spacing
        }
        return rows.filter { !$0.isEmpty }
    }

    private func rowWidth(_ row: [(index: Int, size: CGSize)]) -> CGFloat {
        row.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(max(row.count - 1, 0))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = rows(subviews, width: width)
        let widest = rows.map(rowWidth).max() ?? 0
        let height = rows.reduce(0) { $0 + ($1.map(\.size.height).max() ?? 0) } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: alignment == .leading ? min(widest, width) : (width.isFinite ? width : widest), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            let free = max(bounds.width - rowWidth(row), 0)
            var x = bounds.minX + (alignment == .center ? free / 2 : alignment == .trailing ? free : 0)
            let height = row.map(\.size.height).max() ?? 0
            for item in row {
                subviews[item.index].place(at: CGPoint(x: x, y: y + (height - item.size.height) / 2), proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += height + spacing
        }
    }
}

// MARK: - Play counts on track rows

extension EnvironmentValues {
    @Entry var showsTrackPlayCounts: Bool = false
}

struct TrackPlayCountLabel: View {
    let track: Track
    var isEnabled = true
    var font: Font = .footnote

    @Environment(\.showsTrackPlayCounts) private var onCollectionPage
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    private var hasRoom: Bool {
        guard !dynamicTypeSize.isAccessibilitySize else { return false }
        #if os(iOS)
        return horizontalSizeClass == .regular || onCollectionPage
        #else
        return true
        #endif
    }

    var body: some View {
        if isEnabled, hasRoom, !track.isLocal, let plays = track.playbackCount, plays > 0 {
            Text("\(Image(systemName: "play.fill")) \(Text(verbatim: CompactCount.string(plays)))")
                .font(font)
                .imageScale(.small)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .accessibilityLabel(plays == 1 ? "1 play" : "\(CompactCount.string(plays)) plays")
        }
    }
}

// MARK: - Follow

@MainActor
final class SoundCloudFollowStore: ObservableObject {
    static let shared = SoundCloudFollowStore()

    static let refreshInterval: TimeInterval = 60

    @Published private var known: [String: Bool] = [:]
    @Published private(set) var pending: Set<String> = []
    @Published var failure: String?

    private var library: Set<String> = []
    private var loadedAt: Date?

    func canFollow(_ user: User) -> Bool {
        guard SoundCloudAPI.shared.hasCredentials else { return false }
        return SoundCloudAPI.credentials?.currentUser?.id != user.id
    }

    func isFollowing(_ user: User) -> Bool? {
        if let value = known[user.id] { return value }
        guard loadedAt != nil else { return nil }
        return library.contains(user.id)
    }

    func prepare() async {
        if let loadedAt, Date().timeIntervalSince(loadedAt) < Self.refreshInterval { return }
        loadedAt = Date()
        library = await LibraryDB.followingIDs()
        objectWillChange.send()
    }

    func setFollowing(_ following: Bool, _ user: User) {
        guard !pending.contains(user.id), isFollowing(user) != following else { return }
        pending.insert(user.id)
        let previous = known[user.id]
        known[user.id] = following
        Task {
            defer { pending.remove(user.id) }
            do {
                try await SoundCloudAPI.shared.setFollowing(following, userId: user.id)
                if following { library.insert(user.id) } else { library.remove(user.id) }
            } catch {
                known[user.id] = previous
                failure = following
                    ? "Couldn\u{2019}t follow \(user.displayName)."
                    : "Couldn\u{2019}t unfollow \(user.displayName)."
            }
        }
    }
}

struct SoundCloudFollowButton: View {
    let user: User

    @ObservedObject private var store = SoundCloudFollowStore.shared
    @State private var confirmsUnfollow = false

    var body: some View {
        if store.canFollow(user) {
            let following = store.isFollowing(user) == true
            Button {
                if following {
                    confirmsUnfollow = true
                } else {
                    store.setFollowing(true, user)
                }
            } label: {
                Text(following ? "Following" : "Follow")
                    .lineLimit(1)
            }
            .buttonStyle(.bordered)
            #if !os(tvOS)
            .controlSize(.small)
            #endif
            .fixedSize()
            .disabled(store.isFollowing(user) == nil || store.pending.contains(user.id))
            .task(id: user.id) { await store.prepare() }
            .confirmationDialog("Unfollow \(user.displayName)?", isPresented: $confirmsUnfollow, titleVisibility: .visible) {
                Button("Unfollow", role: .destructive) { store.setFollowing(false, user) }
            }
            .alert("Couldn\u{2019}t Update Follow", isPresented: Binding(
                get: { store.failure != nil },
                set: { if !$0 { store.failure = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(store.failure ?? "")
            }
            .accessibilityLabel(following ? "Unfollow \(user.displayName)" : "Follow \(user.displayName)")
            .accessibilityValue(following ? "Following" : "Not following")
        }
    }
}

// MARK: - Uploader

struct SoundCloudAvatar: View {
    let user: User
    let size: CGFloat

    var body: some View {
        SCArtworkResolver(url: User.customAvatar(user.avatarURL), variant: size > 80 ? .standard : .thumbnail) { image in
            if let image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                SoundingArtworkView(identity: user.id, subject: .person)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

struct SoundCloudAvatarStack: View {
    let users: [User]
    var size: CGFloat = 30

    var body: some View {
        HStack(spacing: -size * 0.32) {
            ForEach(Array(users.enumerated()), id: \.element.id) { index, user in
                SoundCloudAvatar(user: user, size: size)
                    .overlay { Circle().strokeBorder(.background, lineWidth: 2) }
                    .zIndex(Double(users.count - index))
            }
        }
        .accessibilityHidden(true)
    }
}

struct SoundCloudUploaderRow: View {
    let user: User
    var avatarSize: CGFloat = 60
    var spacing: CGFloat = 14
    var nameFont: Font = .headline
    var detailFont: Font = .subheadline
    var postsMusic = false
    var open: (() -> Void)?

    @ObservedObject private var follows = SoundCloudFollowStore.shared

    var body: some View {
        let followable = follows.canFollow(user)
        HStack(spacing: spacing) {
            Button {
                open?()
            } label: {
                CollectionArtistLabel(
                    user: user,
                    avatarSize: avatarSize,
                    spacing: spacing,
                    nameFont: nameFont,
                    detailFont: detailFont,
                    showsChevron: !followable && open != nil,
                    postsMusic: postsMusic
                )
            }
            .buttonStyle(.plain)
            .disabled(open == nil)
            SoundCloudFollowButton(user: user)
        }
    }
}

// MARK: - Liked by and reposted by

struct CollectionEngagedPeople: Equatable, Sendable {
    var likers: [User]
    var reposters: [User]
    var friendIDs: Set<String>
}

@MainActor
final class CollectionPeopleStore {
    static let shared = CollectionPeopleStore()

    static let lifetime: TimeInterval = 30 * 60
    static let capacity = 40
    static let pageSize = 100
    static let defaultStop: TimeInterval = 2 * 60

    private struct Entry {
        let value: CollectionEngagedPeople
        let storedAt: Date
    }

    private let api: SoundCloudAPI
    private var entries: [String: Entry] = [:]
    private var tasks: [String: Task<CollectionEngagedPeople?, Never>] = [:]
    private var incomplete: Set<String> = []
    private var stoppedUntil: Date?
    private var forgetObserver: NSObjectProtocol?

    init(api: SoundCloudAPI = .shared) {
        self.api = api
        forgetObserver = NotificationCenter.default.addObserver(
            forName: AccountDataVault.didForgetAccountData,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.entries = [:] }
        }
    }

    private var isStopped: Bool {
        guard let stoppedUntil else { return false }
        return stoppedUntil > Date()
    }

    func cached(_ playlistID: String) -> CollectionEngagedPeople? {
        guard let entry = entries[playlistID], Date().timeIntervalSince(entry.storedAt) < Self.lifetime else { return nil }
        return entry.value
    }

    func people(for playlist: Playlist) async -> CollectionEngagedPeople? {
        guard !playlist.permalinkURL.isFileURL, playlist.likeCount > 0 || playlist.repostCount > 0 else { return nil }
        if let cached = cached(playlist.id) { return cached }
        if let running = tasks[playlist.id] { return await running.value }
        guard !isStopped else { return nil }
        let id = playlist.id
        let wantsLikers = playlist.likeCount > 0
        let wantsReposters = playlist.repostCount > 0
        let task = Task<CollectionEngagedPeople?, Never> {
            var likers: [User]? = []
            var reposters: [User]? = []
            if wantsLikers {
                likers = await self.page({ try await self.api.getPlaylistLikers(playlistId: id, limit: Self.pageSize) })
            }
            if wantsReposters, !self.isStopped {
                reposters = await self.page({ try await self.api.getPlaylistReposters(playlistId: id, limit: Self.pageSize) })
            }
            guard !self.isStopped else { return nil }
            if likers == nil || reposters == nil { self.incomplete.insert(id) }
            let everyone = (likers ?? []) + (reposters ?? [])
            guard !everyone.isEmpty else { return CollectionEngagedPeople(likers: [], reposters: [], friendIDs: []) }
            let keys = everyone.map { LibraryRecord.key(.user, $0.id) }
            let following = await LibraryDB.store.contains(.followings, keys: keys)
            let friends = Set(everyone.map(\.id).filter { following.contains(LibraryRecord.key(.user, $0)) })
            return CollectionEngagedPeople(
                likers: Self.friendsFirst(likers ?? [], friends),
                reposters: Self.friendsFirst(reposters ?? [], friends),
                friendIDs: friends
            )
        }
        tasks[id] = task
        let value = await task.value
        tasks[id] = nil
        if let value, incomplete.remove(id) == nil { store(value, for: id) }
        return value
    }

    private func page(_ fetch: () async throws -> Page<TrackEngagedUser>) async -> [User]? {
        do {
            var seen = Set<String>()
            return try await fetch().collection.map(\.user).filter { seen.insert($0.id).inserted }
        } catch APIError.notFound {
            return []
        } catch APIError.rateLimited(let resetAt) {
            stoppedUntil = max(resetAt ?? .distantPast, Date().addingTimeInterval(Self.defaultStop))
            return nil
        } catch APIError.temporarilyBlocked(let until, _) {
            stoppedUntil = max(until, Date().addingTimeInterval(Self.defaultStop))
            return nil
        } catch {
            return nil
        }
    }

    private static func friendsFirst(_ users: [User], _ friends: Set<String>) -> [User] {
        users.filter { friends.contains($0.id) } + users.filter { !friends.contains($0.id) }
    }

    private func store(_ value: CollectionEngagedPeople, for id: String) {
        entries[id] = Entry(value: value, storedAt: Date())
        guard entries.count > Self.capacity else { return }
        let oldest = entries.sorted { $0.value.storedAt < $1.value.storedAt }.prefix(entries.count - Self.capacity)
        for (key, _) in oldest { entries[key] = nil }
    }
}

@MainActor
final class CollectionEngagementModel: ObservableObject {
    @Published private(set) var people: CollectionEngagedPeople?
    @Published private(set) var isFinished = false

    private var playlistID: String?

    func load(_ playlist: Playlist) async {
        if playlistID != playlist.id {
            playlistID = playlist.id
            people = CollectionPeopleStore.shared.cached(playlist.id)
            isFinished = people != nil
        }
        guard !isFinished else { return }
        #if DEBUG
        if VisualFixtures.isEnabled {
            isFinished = true
            return
        }
        #endif
        let found = await CollectionPeopleStore.shared.people(for: playlist)
        guard playlistID == playlist.id else { return }
        people = found
        isFinished = true
    }
}

enum CollectionEngagementKind: String, Identifiable {
    case likes
    case reposts

    var id: String { rawValue }

    var title: String { self == .likes ? "Likes" : "Reposts" }

    var symbol: String { self == .likes ? "heart" : "arrow.2.squarepath" }

    func summary(users: [User], friendIDs: Set<String>, total: Int) -> String {
        let verb = self == .likes ? "Liked by" : "Reposted by"
        let friends = users.filter { friendIDs.contains($0.id) }.prefix(2).map(\.displayName)
        let count = max(total, users.count)
        guard !friends.isEmpty else {
            return count == 1 ? "\(verb) 1 person" : "\(verb) \(CompactCount.string(count)) people"
        }
        let others = count - friends.count
        let named = friends.joined(separator: friends.count == 2 && others > 0 ? ", " : " and ")
        switch others {
        case ..<1: return "\(verb) \(named)"
        case 1: return "\(verb) \(named) and 1 other"
        default: return "\(verb) \(named) and \(CompactCount.string(others)) others"
        }
    }
}

struct CollectionEngagementSection: View {
    let playlist: Playlist
    private let openUser: ((User) -> Void)?
    private let destination: ((User) -> AnyView)?

    @StateObject private var model = CollectionEngagementModel()
    @State private var presented: CollectionEngagementKind?

    init(playlist: Playlist, openUser: ((User) -> Void)?) {
        self.playlist = playlist
        self.openUser = openUser
        destination = nil
    }

    init<Destination: View>(playlist: Playlist, @ViewBuilder destination: @escaping (User) -> Destination) {
        self.playlist = playlist
        openUser = nil
        self.destination = { AnyView(destination($0)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let people = model.people {
                if playlist.likeCount > 0 {
                    row(.likes, users: people.likers, friendIDs: people.friendIDs, total: playlist.likeCount)
                }
                if playlist.repostCount > 0 {
                    row(.reposts, users: people.reposters, friendIDs: people.friendIDs, total: playlist.repostCount)
                }
            } else if !model.isFinished {
                Color.clear
                    .frame(height: 1)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: playlist.id) { await model.load(playlist) }
        #if os(tvOS)
        .focusSection()
        #else
        .sheet(item: $presented) { kind in
            NavigationStack {
                list(kind)
            }
            #if os(macOS)
            .frame(minWidth: 380, idealWidth: 420, minHeight: 460, idealHeight: 560)
            #endif
        }
        #endif
    }

    private func users(_ kind: CollectionEngagementKind) -> [User] {
        kind == .likes ? (model.people?.likers ?? []) : (model.people?.reposters ?? [])
    }

    private func list(_ kind: CollectionEngagementKind) -> SoundCloudPeopleList {
        SoundCloudPeopleList(
            title: kind.title,
            users: users(kind),
            friendIDs: model.people?.friendIDs ?? [],
            total: kind == .likes ? playlist.likeCount : playlist.repostCount,
            moreURL: playlist.permalinkURL,
            openUser: openUser.map { (open) -> (User) -> Void in
                { (user: User) in
                    presented = nil
                    open(user)
                }
            },
            destination: destination,
            dismiss: { presented = nil }
        )
    }

    @ViewBuilder
    private func row(_ kind: CollectionEngagementKind, users: [User], friendIDs: Set<String>, total: Int) -> some View {
        let summary = kind.summary(users: users, friendIDs: friendIDs, total: total)
        let label = HStack(spacing: 12) {
            if users.isEmpty {
                Image(systemName: kind.symbol)
                    .font(rowFont)
                    .foregroundStyle(.secondary)
                    .frame(width: rowAvatarSize, height: rowAvatarSize)
                    .accessibilityHidden(true)
            } else {
                SoundCloudAvatarStack(users: Array(users.prefix(5)), size: rowAvatarSize)
            }
            Text(summary)
                .font(rowFont)
                .foregroundStyle(users.isEmpty ? .secondary : .primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            if !users.isEmpty {
                Image(systemName: "chevron.forward")
                    .font(rowFont.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())

        if users.isEmpty {
            label
                #if os(tvOS)
                .padding(.horizontal, 16)
                #endif
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(summary)
        } else {
            linkedRow(kind, summary: summary, label: label)
        }
    }

    @ViewBuilder
    private func linkedRow(_ kind: CollectionEngagementKind, summary: String, label: some View) -> some View {
        #if os(tvOS)
        NavigationLink {
            list(kind)
        } label: {
            TVFocusInvertingLabel {
                label
                    .padding(16)
                    .frame(maxWidth: 1100, alignment: .leading)
            }
        }
        .buttonStyle(TVCollectionRowStyle())
        .accessibilityLabel(summary)
        #else
        Button {
            presented = kind
        } label: {
            label
        }
        .buttonStyle(.plain)
        .accessibilityLabel(summary)
        .accessibilityHint("Shows everyone")
        #endif
    }

    private var rowAvatarSize: CGFloat {
        #if os(tvOS)
        56
        #else
        30
        #endif
    }

    private var rowFont: Font {
        #if os(tvOS)
        .callout
        #else
        .subheadline
        #endif
    }
}

#if os(tvOS)
private struct TVFocusInvertingLabel<Content: View>: View {
    @ViewBuilder var content: () -> Content

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        content()
            .foregroundStyle(isFocused ? Color.scChromeFocusOn : Color.scTextPrimary)
    }
}
#endif

struct SoundCloudPeopleList: View {
    let title: String
    let users: [User]
    var friendIDs: Set<String> = []
    var total: Int = 0
    var moreURL: URL?
    var openUser: ((User) -> Void)?
    var destination: ((User) -> AnyView)?
    var dismiss: (() -> Void)?

    var body: some View {
        List {
            Section {
                ForEach(users, id: \.id) { user in
                    row(user)
                }
            } footer: {
                #if !os(tvOS)
                if total > users.count, let moreURL {
                    Link("See All \(CompactCount.string(total)) on SoundCloud", destination: moreURL)
                }
                #endif
            }
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if !os(tvOS)
        .toolbar {
            if let dismiss {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss)
                }
            }
        }
        #endif
    }

    @ViewBuilder
    private func row(_ user: User) -> some View {
        let label = HStack(spacing: 12) {
            SoundCloudAvatar(user: user, size: avatarSize)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(user.displayName)
                        .lineLimit(1)
                    if user.isVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.tint)
                            .imageScale(.small)
                            .accessibilityLabel("Verified")
                    }
                }
                .font(.body.weight(.semibold))
                let detail = [friendIDs.contains(user.id) ? "Following" : nil, user.followersCount > 0 ? user.followerCountText : nil]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())

        if let destination {
            NavigationLink {
                destination(user)
            } label: {
                label
            }
        } else if let openUser {
            Button {
                openUser(user)
            } label: {
                label
            }
            .buttonStyle(.plain)
        } else {
            label
        }
    }

    private var avatarSize: CGFloat {
        #if os(tvOS)
        64
        #else
        36
        #endif
    }
}

// MARK: - Profiles

struct SoundCloudProfileLink: Identifiable, Hashable {
    let url: URL
    let preferredTitle: String?

    var id: String { url.absoluteString }

    var title: String {
        if let preferredTitle, !preferredTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return preferredTitle
        }
        let host = url.host?.lowercased() ?? ""
        if host.contains("instagram.com") { return "Instagram" }
        if host.contains("twitter.com") || host == "x.com" || host.hasSuffix(".x.com") { return "X" }
        if host.contains("facebook.com") { return "Facebook" }
        if host.contains("tiktok.com") { return "TikTok" }
        if host.contains("youtube.com") || host.contains("youtu.be") { return "YouTube" }
        if host.contains("bandcamp.com") { return "Bandcamp" }
        if host.contains("spotify.com") { return "Spotify" }
        if host.contains("music.apple.com") { return "Apple Music" }
        if host.contains("beatport.com") { return "Beatport" }
        return url.host?.replacingOccurrences(of: "www.", with: "") ?? "Website"
    }

    var symbol: String {
        let host = url.host?.lowercased() ?? ""
        if host.contains("youtube") || host.contains("youtu.be") { return "play.rectangle" }
        if host.contains("instagram") || host.contains("tiktok") { return "camera" }
        return "globe"
    }

    static func links(for user: User, webProfiles: [SoundCloudWebProfile] = [], limit: Int = 8) -> [SoundCloudProfileLink] {
        var titles: [URL: String] = [:]
        for profile in webProfiles {
            if let title = profile.title, !title.isEmpty { titles[profile.url] = title }
        }
        if let website = user.website, let title = user.websiteTitle { titles[website] = title }
        var urls: [URL] = webProfiles.map(\.url)
        if let website = user.website { urls.append(website) }
        if let description = user.description,
           let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(description.startIndex..<description.endIndex, in: description)
            urls.append(contentsOf: detector.matches(in: description, range: range).compactMap(\.url))
        }
        var seen = Set<String>()
        let links = urls.compactMap { url -> SoundCloudProfileLink? in
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
            let key = url.absoluteString.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard url != user.permalinkURL, url.host?.lowercased().contains("soundcloud.com") != true,
                  seen.insert(key).inserted else { return nil }
            return SoundCloudProfileLink(url: url, preferredTitle: titles[url])
        }
        return Array(links.prefix(limit))
    }
}

@MainActor
final class SoundCloudWebProfileStore: ObservableObject {
    static let shared = SoundCloudWebProfileStore()

    static let lifetime: TimeInterval = 30 * 60
    static let capacity = 60
    static let defaultStop: TimeInterval = 2 * 60

    private struct Entry {
        let profiles: [SoundCloudWebProfile]
        let storedAt: Date
    }

    @Published private var entries: [String: Entry] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var stoppedUntil: Date?

    func profiles(for user: User) -> [SoundCloudWebProfile] {
        guard let entry = entries[user.id], Date().timeIntervalSince(entry.storedAt) < Self.lifetime else { return [] }
        return entry.profiles
    }

    func load(_ user: User) async {
        if let entry = entries[user.id], Date().timeIntervalSince(entry.storedAt) < Self.lifetime { return }
        if let running = tasks[user.id] { return await running.value }
        if let stoppedUntil, stoppedUntil > Date() { return }
        guard !LocalTrackFile.isLocalTrackID(user.id), !user.permalinkURL.isFileURL else { return }
        #if DEBUG
        if VisualFixtures.isEnabled { return }
        #endif
        let id = user.id
        let task = Task {
            do {
                let found = try await SoundCloudAPI.shared.getUserWebProfiles(userId: id)
                self.store(found, for: id)
            } catch APIError.notFound {
                self.store([], for: id)
            } catch APIError.rateLimited(let resetAt) {
                self.stoppedUntil = max(resetAt ?? .distantPast, Date().addingTimeInterval(Self.defaultStop))
            } catch APIError.temporarilyBlocked(let until, _) {
                self.stoppedUntil = max(until, Date().addingTimeInterval(Self.defaultStop))
            } catch {}
        }
        tasks[id] = task
        await task.value
        tasks[id] = nil
    }

    private func store(_ profiles: [SoundCloudWebProfile], for id: String) {
        entries[id] = Entry(profiles: profiles, storedAt: Date())
        guard entries.count > Self.capacity else { return }
        let oldest = entries.sorted { $0.value.storedAt < $1.value.storedAt }.prefix(entries.count - Self.capacity)
        for (key, _) in oldest { entries[key] = nil }
    }
}

struct SoundCloudProfileCounts: View {
    let user: User
    var valueFont: Font = .body.bold()
    var labelFont: Font = .caption
    var spacing: CGFloat = 24

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            count(user.formattedFollowers, user.followersCount == 1 ? "Follower" : "Followers")
            count(CompactCount.string(user.followingsCount), "Following")
            if user.isArtist {
                count(user.formattedTracks, user.trackCount == 1 ? "Track" : "Tracks")
            }
        }
    }

    private func count(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(valueFont)
                .monospacedDigit()
            Text(label)
                .font(labelFont)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct SoundCloudProfileFacts: View {
    let user: User
    var font: Font = .subheadline

    @ObservedObject private var webProfiles = SoundCloudWebProfileStore.shared

    var body: some View {
        content
            .task(id: user.id) { await webProfiles.load(user) }
    }

    @ViewBuilder
    private var content: some View {
        let links = SoundCloudProfileLink.links(for: user, webProfiles: webProfiles.profiles(for: user))
        if user.locationText != nil || !links.isEmpty {
            SoundCloudFlowLayout(spacing: 14) {
                if let location = user.locationText {
                    Label(location, systemImage: "mappin.and.ellipse")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                ForEach(links) { link in
                    #if os(tvOS)
                    Label(link.title, systemImage: link.symbol)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    #else
                    Link(destination: link.url) {
                        Label(link.title, systemImage: link.symbol)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.primary)
                    #endif
                }
            }
            .font(font)
        } else {
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}

struct SoundCloudProfileHeader: View {
    let user: User
    var includesCounts = true
    var includesBio = true
    var spacing: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if includesCounts {
                #if os(tvOS)
                SoundCloudProfileCounts(user: user, valueFont: .title3.bold(), labelFont: .callout, spacing: 48)
                #else
                SoundCloudProfileCounts(user: user)
                #endif
            }
            if includesBio, let bio = user.description?.trimmingCharacters(in: .whitespacesAndNewlines), !bio.isEmpty {
                SoundCloudExpandableText(bio)
            }
            #if os(tvOS)
            SoundCloudProfileFacts(user: user, font: .callout)
            #else
            SoundCloudProfileFacts(user: user)
            #endif
        }
        .frame(maxWidth: maxWidth, alignment: .leading)
    }

    private var maxWidth: CGFloat {
        #if os(tvOS)
        1400
        #else
        640
        #endif
    }
}
