import Combine
import Foundation

struct TrackFollowedPeople: Equatable, Sendable {
    var likers: [User]
    var reposters: [User]

    var isEmpty: Bool { likers.isEmpty && reposters.isEmpty }
}

struct BehindTheTrackFact: Identifiable, Equatable {
    let label: String
    let value: String
    var isSelectable = false
    var opensTracklist = false
    var opensAlbum = false

    var id: String { label }
}

@MainActor
final class BehindTheTrackStore {
    static let shared = BehindTheTrackStore()

    static let lifetime: TimeInterval = 30 * 60
    static let capacity = 40
    static let pageSize = 100
    static let maxPages = 2
    static let defaultStop: TimeInterval = 2 * 60

    private struct Entry<Value> {
        let value: Value
        let storedAt: Date
    }

    private let api: SoundCloudAPI
    private let now: () -> Date
    private var abouts: [String: Entry<TrackAbout>] = [:]
    private var people: [String: Entry<TrackFollowedPeople>] = [:]
    private var aboutTasks: [String: Task<TrackAbout?, Never>] = [:]
    private var peopleTasks: [String: Task<TrackFollowedPeople?, Never>] = [:]
    private(set) var stoppedUntil: Date?
    private var forgetObserver: NSObjectProtocol?

    init(api: SoundCloudAPI = .shared, now: @escaping () -> Date = Date.init) {
        self.api = api
        self.now = now
        forgetObserver = NotificationCenter.default.addObserver(
            forName: AccountDataVault.didForgetAccountData,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.forget() }
        }
    }

    var isStopped: Bool {
        guard let stoppedUntil else { return false }
        return stoppedUntil > now()
    }

    func cachedAbout(for trackID: String) -> TrackAbout? {
        fresh(abouts[trackID])
    }

    func cachedPeople(for trackID: String) -> TrackFollowedPeople? {
        fresh(people[trackID])
    }

    func about(for track: Track) async -> TrackAbout? {
        guard track.supportsSoundCloudActions else { return nil }
        if let cached = cachedAbout(for: track.id) { return cached }
        if let running = aboutTasks[track.id] { return await running.value }
        guard !isStopped else { return nil }
        let id = track.id
        let task = Task<TrackAbout?, Never> { [api] in
            do {
                return try await api.getTrackAbout(trackId: id)
            } catch {
                self.noteFailure(error)
                return nil
            }
        }
        aboutTasks[id] = task
        let value = await task.value
        aboutTasks[id] = nil
        if let value { store(value, for: id, in: &abouts) }
        return value
    }

    func people(for track: Track) async -> TrackFollowedPeople? {
        guard track.supportsSoundCloudActions, api.hasCredentials else { return nil }
        if let cached = cachedPeople(for: track.id) { return cached }
        if let running = peopleTasks[track.id] { return await running.value }
        guard !isStopped else { return nil }
        let id = track.id
        let wantsLikers = track.likeCount > 0
        let wantsReposters = track.repostCount > 0
        let task = Task<TrackFollowedPeople?, Never> {
            guard await LibraryDB.count(.followings) > 0 else { return nil }
            var result = TrackFollowedPeople(likers: [], reposters: [])
            if wantsLikers {
                switch await self.followed({ try await self.api.getTrackLikers(trackId: id, limit: Self.pageSize) }) {
                case .some(let users): result.likers = users
                case .none: return nil
                }
            }
            if wantsReposters {
                switch await self.followed({ try await self.api.getTrackReposters(trackId: id, limit: Self.pageSize) }) {
                case .some(let users): result.reposters = users
                case .none: return nil
                }
            }
            return result
        }
        peopleTasks[id] = task
        let value = await task.value
        peopleTasks[id] = nil
        if let value { store(value, for: id, in: &people) }
        return value
    }

    private func followed(_ first: () async throws -> Page<TrackEngagedUser>) async -> [User]? {
        var users: [User] = []
        do {
            var page = try await first()
            users = page.collection.map(\.user)
            var pages = 1
            while pages < Self.maxPages, let next = page.nextHref, !Task.isCancelled, !isStopped {
                page = try await api.getPage(TrackEngagedUser.self, from: next)
                users += page.collection.map(\.user)
                pages += 1
            }
        } catch {
            noteFailure(error)
            if isStopped { return nil }
            if users.isEmpty { return Self.isMissing(error) ? [] : nil }
        }
        guard !users.isEmpty else { return [] }
        let keys = users.map { LibraryRecord.key(.user, $0.id) }
        let following = await LibraryDB.store.contains(.followings, keys: keys)
        var seen = Set<String>()
        return users.filter { following.contains(LibraryRecord.key(.user, $0.id)) && seen.insert($0.id).inserted }
    }

    private static func isMissing(_ error: Error) -> Bool {
        if case APIError.notFound = error { return true }
        return false
    }

    private func noteFailure(_ error: Error) {
        switch error {
        case APIError.rateLimited(let resetAt):
            stoppedUntil = max(resetAt ?? .distantPast, now().addingTimeInterval(Self.defaultStop))
        case APIError.temporarilyBlocked(let until, _):
            stoppedUntil = max(until, now().addingTimeInterval(Self.defaultStop))
        default:
            break
        }
    }

    private func fresh<Value>(_ entry: Entry<Value>?) -> Value? {
        guard let entry, now().timeIntervalSince(entry.storedAt) < Self.lifetime else { return nil }
        return entry.value
    }

    private func store<Value>(_ value: Value, for id: String, in cache: inout [String: Entry<Value>]) {
        cache[id] = Entry(value: value, storedAt: now())
        guard cache.count > Self.capacity else { return }
        let oldest = cache.sorted { $0.value.storedAt < $1.value.storedAt }.prefix(cache.count - Self.capacity)
        for (key, _) in oldest { cache[key] = nil }
    }

    private func forget() {
        abouts = [:]
        people = [:]
    }
}

@MainActor
final class BehindTheTrackModel: ObservableObject {
    enum PeopleState: Equatable {
        case idle
        case loading
        case loaded(TrackFollowedPeople)
        case unavailable
    }

    static let settle: Duration = .milliseconds(450)

    @Published private(set) var track: Track
    @Published private(set) var about: TrackAbout?
    @Published private(set) var people: PeopleState

    private let store: BehindTheTrackStore

    init(track: Track, store: BehindTheTrackStore = .shared) {
        self.track = track
        self.store = store
        about = store.cachedAbout(for: track.id)
        people = Self.initialPeople(for: track, store: store)
    }

    func show(_ next: Track) {
        guard next.id != track.id else {
            track = next
            return
        }
        track = next
        about = store.cachedAbout(for: next.id)
        people = Self.initialPeople(for: next, store: store)
    }

    func load() async {
        guard track.supportsSoundCloudActions else { return }
        let id = track.id
        let needsAbout = about == nil
        let needsPeople: Bool = {
            if case .idle = people { return true }
            return false
        }()
        guard needsAbout || needsPeople else { return }
        try? await Task.sleep(for: Self.settle)
        guard !Task.isCancelled, id == track.id else { return }
        if needsPeople { people = .loading }
        let current = track
        async let fetchedAbout = fetchAbout(needsAbout, current)
        async let fetchedPeople = fetchPeople(needsPeople, current)
        let (aboutResult, peopleResult) = await (fetchedAbout, fetchedPeople)
        guard id == track.id else { return }
        if needsAbout, let aboutResult { about = aboutResult }
        if needsPeople { people = peopleResult.map(PeopleState.loaded) ?? .unavailable }
    }

    private func fetchAbout(_ needed: Bool, _ track: Track) async -> TrackAbout? {
        guard needed else { return nil }
        return await store.about(for: track)
    }

    private func fetchPeople(_ needed: Bool, _ track: Track) async -> TrackFollowedPeople? {
        guard needed else { return nil }
        return await store.people(for: track)
    }

    var descriptionText: String? {
        let text = track.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    var genre: String? {
        (about?.genre ?? track.genre).map(GenrePresentation.displayName(for:))
    }

    var tags: [String] {
        let source = (about?.tags).flatMap { $0.isEmpty ? nil : $0 } ?? track.tags
        var seen = Set<String>()
        return source.filter { seen.insert($0.lowercased()).inserted && $0.lowercased() != track.genre?.lowercased() }
    }

    func commentCount(loaded: Int?) -> Int? {
        if let loaded, loaded > 0 { return loaded }
        return about?.commentCount ?? loaded
    }

    func facts(analysis: AnalysisFeatureSummary?, pendingAnalysis: String?, lastPlayed: Date?, tracklistCount: Int?) -> [BehindTheTrackFact] {
        var rows: [BehindTheTrackFact] = []
        if let bpm = analysis?.bpm, bpm > 0 { rows.append(.init(label: "BPM", value: ManualTempoKey.format(bpm))) }
        if let key = analysis?.key { rows.append(.init(label: "Key", value: key.fullLabel)) }
        if analysis?.bpm == nil, analysis?.key == nil, let pendingAnalysis { rows.append(.init(label: "BPM and Key", value: pendingAnalysis)) }
        if let genre { rows.append(.init(label: "Genre", value: genre)) }
        if let tracklistCount, tracklistCount > 0 {
            rows.append(.init(label: "Tracklist", value: tracklistCount == 1 ? "1 track" : "\(tracklistCount) tracks", opensTracklist: true))
        }
        let album = track.knownAlbum
        let albumTitle = track.albumName ?? album?.title
        if let albumTitle { rows.append(.init(label: "Album", value: albumTitle, opensAlbum: album != nil)) }
        if let release = about?.releaseTitle, release.caseInsensitiveCompare(albumTitle ?? "") != .orderedSame {
            rows.append(.init(label: "Release", value: release))
        }
        if let released = about?.releaseDate {
            rows.append(.init(label: "Released", value: released.formatted(date: .long, time: .omitted)))
        }
        rows.append(.init(label: "Posted", value: track.createdAt.formatted(date: .long, time: .omitted)))
        if let label = about?.labelName { rows.append(.init(label: "Label", value: label)) }
        if let publisher = about?.publisherName, publisher != about?.labelName { rows.append(.init(label: "Publisher", value: publisher)) }
        if let isrc = about?.isrc { rows.append(.init(label: "ISRC", value: isrc, isSelectable: true)) }
        if let licence = about?.license.flatMap(Self.licenceName) { rows.append(.init(label: "Licence", value: licence)) }
        if about?.isExplicit == true { rows.append(.init(label: "Content", value: "Explicit")) }
        if !track.isAwaitingLocalMetadata { rows.append(.init(label: "Length", value: track.formattedDuration)) }
        if let availability = Self.availability(of: track) { rows.append(.init(label: "Availability", value: availability)) }
        if let lastPlayed { rows.append(.init(label: "You Last Played It", value: lastPlayed.formatted(.relative(presentation: .named)))) }
        return rows
    }

    static func availability(of track: Track) -> String? {
        guard !track.isLocal else { return nil }
        let subscription = SubscriptionService.shared
        var parts: [String] = []
        if track.requiresGoPlus { parts.append("SoundCloud Go+") }
        if subscription.playsAsPreview(track) { parts.append(subscription.displayedDuration(for: track)) }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    static func licenceName(_ raw: String) -> String? {
        switch raw.lowercased() {
        case "all-rights-reserved": return "All Rights Reserved"
        case "no-rights-reserved": return "No Rights Reserved"
        case "cc-by": return "Creative Commons Attribution"
        case "cc-by-sa": return "Creative Commons Attribution-ShareAlike"
        case "cc-by-nd": return "Creative Commons Attribution-NoDerivs"
        case "cc-by-nc": return "Creative Commons Attribution-NonCommercial"
        case "cc-by-nc-sa": return "Creative Commons Attribution-NonCommercial-ShareAlike"
        case "cc-by-nc-nd": return "Creative Commons Attribution-NonCommercial-NoDerivs"
        default: return nil
        }
    }

    static func peopleSummary(_ users: [User]) -> String {
        let names = users.prefix(2).map(\.displayName)
        switch users.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        case 3: return "\(names[0]), \(names[1]) and 1 other"
        default: return "\(names[0]), \(names[1]) and \(users.count - 2) others"
        }
    }

    private static func initialPeople(for track: Track, store: BehindTheTrackStore) -> PeopleState {
        guard track.supportsSoundCloudActions, SoundCloudAPI.shared.hasCredentials else { return .unavailable }
        return store.cachedPeople(for: track.id).map(PeopleState.loaded) ?? .idle
    }
}

enum TrackDescriptionLinks {
    static let seekScheme = "sounding-seek"

    struct Timestamp: Equatable {
        let range: NSRange
        let seconds: TimeInterval
    }

    private static let timestampExpression = try? NSRegularExpression(
        pattern: #"(?<![\d:.])(?:(\d{1,2}):)?(\d{1,2}):(\d{2})(?![\d:])"#
    )

    private static let mentionExpression = try? NSRegularExpression(
        pattern: #"(?<![\w@./])@([A-Za-z0-9][A-Za-z0-9_-]{1,})"#
    )

    static func timestamps(in text: String, duration: TimeInterval?) -> [Timestamp] {
        guard let timestampExpression else { return [] }
        let source = text as NSString
        let matches = timestampExpression.matches(in: text, range: NSRange(location: 0, length: source.length))
        return matches.compactMap { match in
            func number(_ index: Int) -> Int? {
                let range = match.range(at: index)
                guard range.location != NSNotFound else { return nil }
                return Int(source.substring(with: range))
            }
            guard let minutes = number(2), let seconds = number(3), seconds < 60 else { return nil }
            let hours = number(1)
            if hours != nil, minutes >= 60 { return nil }
            let total = TimeInterval((hours ?? 0) * 3600 + minutes * 60 + seconds)
            if let duration, duration > 0, total > duration { return nil }
            return Timestamp(range: match.range, seconds: total)
        }
    }

    static func attributed(_ text: String, duration: TimeInterval?, linksTimestamps: Bool) -> AttributedString {
        var result = AttributedString(text)
        let source = text as NSString
        let full = NSRange(location: 0, length: source.length)
        var taken: [NSRange] = []

        func claim(_ range: NSRange, _ url: URL) {
            guard !taken.contains(where: { NSIntersectionRange($0, range).length > 0 }),
                  let span = Range(range, in: result) else { return }
            result[span].link = url
            taken.append(range)
        }

        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: text, range: full) {
                guard let url = match.url else { continue }
                claim(match.range, url)
            }
        }
        if let mentionExpression {
            for match in mentionExpression.matches(in: text, range: full) {
                let name = source.substring(with: match.range(at: 1))
                guard let url = URL(string: "https://soundcloud.com/\(name)") else { continue }
                claim(match.range, url)
            }
        }
        if linksTimestamps {
            for stamp in timestamps(in: text, duration: duration) {
                guard let url = seekURL(stamp.seconds) else { continue }
                claim(stamp.range, url)
            }
        }
        return result
    }

    static func seekURL(_ seconds: TimeInterval) -> URL? {
        var components = URLComponents()
        components.scheme = seekScheme
        components.host = String(Int(seconds))
        return components.url
    }

    static func seconds(from url: URL) -> TimeInterval? {
        guard url.scheme == seekScheme, let host = url.host, let value = Int(host) else { return nil }
        return TimeInterval(value)
    }
}

@MainActor
final class BehindTheTrackPresenter: ObservableObject {
    static let shared = BehindTheTrackPresenter()

    @Published var track: Track?
    @Published private(set) var hosts: [UUID] = []

    func present(_ track: Track) { self.track = track }

    func register(_ host: UUID) {
        hosts.removeAll { $0 == host }
        hosts.append(host)
    }

    func unregister(_ host: UUID) {
        hosts.removeAll { $0 == host }
    }

    func isActive(_ host: UUID) -> Bool { hosts.last == host }
}

@MainActor
final class SearchRequestRouter: ObservableObject {
    static let shared = SearchRequestRouter()

    @Published private(set) var pendingQuery: String?

    func search(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingQuery = trimmed
    }

    func consume() -> String? {
        defer { pendingQuery = nil }
        return pendingQuery
    }

    func handled(_ query: String) {
        Task { @MainActor in
            if pendingQuery == query { pendingQuery = nil }
        }
    }
}
