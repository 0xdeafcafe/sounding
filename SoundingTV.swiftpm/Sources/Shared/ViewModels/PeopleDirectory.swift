import Foundation
import Combine

enum PeopleSort: String, CaseIterable, Identifiable, Sendable {
    case recentlyFollowed
    case name
    case mostFollowers

    var id: Self { self }

    var title: String {
        switch self {
        case .recentlyFollowed: "Recently Followed"
        case .name: "Name"
        case .mostFollowers: "Most Followers"
        }
    }
}

struct PersonEntry: Identifiable, Hashable, Sendable {
    let user: User
    let followedAt: Date?

    var id: String { user.id }

    var followerCountLabel: String {
        user.followersCount == 1 ? "1 follower" : "\(user.formattedFollowers) followers"
    }

    var followedLabel: String? {
        guard let followedAt else { return nil }
        let sameYear = Calendar.current.isDate(followedAt, equalTo: Date(), toGranularity: .year)
        let month = sameYear
            ? followedAt.formatted(.dateTime.month(.wide))
            : followedAt.formatted(.dateTime.month(.wide).year())
        return "Followed in \(month)"
    }

    var detail: String {
        [followerCountLabel, followedLabel].compactMap { $0 }.joined(separator: " · ")
    }
}

extension LibraryDB {
    static func people(_ collection: LibraryCollection) async -> [PersonEntry] {
        let rows = await store.page(collection, offset: 0, limit: nil)
        return await Task.detached(priority: .userInitiated) {
            let decoder = LikesSyncEngine.makeDecoder()
            return rows.compactMap { row -> PersonEntry? in
                guard row.record.kind == .user,
                      let user = try? decoder.decode(User.self, from: row.record.payload) else { return nil }
                let followedAt = row.record.timestampMillis.map { Date(timeIntervalSince1970: Double($0) / 1000) }
                return PersonEntry(user: user, followedAt: followedAt)
            }
        }.value
    }

    static func followingIDs() async -> Set<String> {
        let keys = await store.keys(.followings, limit: nil)
        return Set(keys.compactMap { LibraryRecord.parse(key: $0) }.filter { $0.kind == .user }.map { $0.id })
    }
}

@MainActor
final class PeopleDirectoryModel: ObservableObject {
    let kind: ArtistConnectionKind

    @Published private(set) var entries: [PersonEntry] = []
    @Published private(set) var isLoading = true
    @Published private(set) var isSyncing = false
    @Published private var followingIDs: Set<String> = []
    @Published private var overrides: [String: Bool] = [:]
    @Published var actionFailure: String?
    @Published var sort: PeopleSort {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: Self.sortKey(kind)) }
    }

    private var pending: Set<String> = []
    private var generation = 0
    private var observers: [AnyCancellable] = []

    init(kind: ArtistConnectionKind) {
        self.kind = kind
        sort = UserDefaults.standard.string(forKey: Self.sortKey(kind)).flatMap(PeopleSort.init(rawValue:)) ?? .recentlyFollowed
        observeLibrary()
    }

    private static func sortKey(_ kind: ArtistConnectionKind) -> String {
        "peopleSort.\(kind.rawValue)"
    }

    private var collection: LibraryCollection {
        kind == .following ? .followings : .followers
    }

    var showsLoading: Bool { entries.isEmpty && (isLoading || isSyncing) }

    func load() async {
        await reload()
        isLoading = false
    }

    func visible(matching query: String) -> [PersonEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matched = needle.isEmpty ? entries : entries.filter {
            $0.user.displayName.localizedStandardContains(needle) || $0.user.username.localizedStandardContains(needle)
        }
        return Self.sorted(matched, by: sort)
    }

    func isFollowing(_ user: User) -> Bool {
        overrides[user.id] ?? followingIDs.contains(user.id)
    }

    func setFollowing(_ following: Bool, _ user: User) {
        guard !pending.contains(user.id), isFollowing(user) != following else { return }
        pending.insert(user.id)
        overrides[user.id] = following
        Task {
            defer { pending.remove(user.id) }
            do {
                try await SoundCloudAPI.shared.setFollowing(following, userId: user.id)
            } catch {
                overrides[user.id] = nil
                actionFailure = following
                    ? "Couldn\u{2019}t follow \(user.displayName)."
                    : "Couldn\u{2019}t unfollow \(user.displayName)."
            }
        }
    }

    private static func sorted(_ entries: [PersonEntry], by sort: PeopleSort) -> [PersonEntry] {
        switch sort {
        case .recentlyFollowed:
            let dated = entries.filter { $0.followedAt != nil }
                .sorted { ($0.followedAt ?? .distantPast) > ($1.followedAt ?? .distantPast) }
            return dated + entries.filter { $0.followedAt == nil }
        case .name:
            return entries.sorted { $0.user.displayName.localizedStandardCompare($1.user.displayName) == .orderedAscending }
        case .mostFollowers:
            return entries.sorted {
                if $0.user.followersCount != $1.user.followersCount { return $0.user.followersCount > $1.user.followersCount }
                return $0.user.displayName.localizedStandardCompare($1.user.displayName) == .orderedAscending
            }
        }
    }

    private func reload() async {
        generation += 1
        let token = generation
        #if DEBUG
        if VisualFixtures.isEnabled {
            let now = Date()
            entries = VisualFixtures.artists.enumerated().map { index, user in
                PersonEntry(user: user, followedAt: index < 3 ? now.addingTimeInterval(-Double(index + 1) * 86_400 * 20) : nil)
            }
            followingIDs = kind == .following ? Set(entries.map(\.id)) : []
            return
        }
        #endif
        let loaded = await LibraryDB.people(collection)
        let followed = await LibraryDB.followingIDs()
        guard token == generation else { return }
        entries = loaded
        followingIDs = followed
        overrides = overrides.filter { followed.contains($0.key) != $0.value }
    }

    private func observeLibrary() {
        let engine = LibrarySyncEngine.shared
        let watched: Set<LibraryCollection> = [collection, .followings]
        observers.append(
            engine.$revision
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard !engine.lastChanged.isDisjoint(with: watched) else { return }
                    Task { await self?.reload() }
                }
        )
        observers.append(
            engine.$progress
                .map(\.isBackfilling)
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] value in self?.isSyncing = value }
        )
    }
}
