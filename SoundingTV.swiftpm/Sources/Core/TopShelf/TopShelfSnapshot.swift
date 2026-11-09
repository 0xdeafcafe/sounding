import Foundation

enum TopShelfShape: String, Codable, Sendable {
    case square
    case poster
    case hdtv
}

enum TopShelfEntryKind: String, Codable, Sendable {
    case track
    case playlist
    case station
}

struct TopShelfEntry: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    var artworkURL: URL?
    var artworkURL2x: URL?
    var progress: Double
    let actionURL: URL?
    let playActionURL: URL?
    let shape: TopShelfShape
    let kind: TopShelfEntryKind
    let duration: TimeInterval?
    let playedAt: Date?

    var trackID: String {
        id.split(separator: ":").last.map(String.init) ?? id
    }

    init(
        id: String,
        title: String,
        subtitle: String,
        artworkURL: URL?,
        artworkURL2x: URL? = nil,
        progress: Double = 0,
        actionURL: URL? = nil,
        playActionURL: URL? = nil,
        shape: TopShelfShape = .square,
        kind: TopShelfEntryKind = .track,
        duration: TimeInterval? = nil,
        playedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.artworkURL2x = artworkURL2x
        self.progress = Self.clamp(progress)
        self.actionURL = actionURL
        self.playActionURL = playActionURL
        self.shape = shape
        self.kind = kind
        self.duration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        self.playedAt = playedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        artworkURL = try c.decodeIfPresent(URL.self, forKey: .artworkURL)
        artworkURL2x = try c.decodeIfPresent(URL.self, forKey: .artworkURL2x)
        progress = Self.clamp(try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0)
        actionURL = try c.decodeIfPresent(URL.self, forKey: .actionURL)
        playActionURL = try c.decodeIfPresent(URL.self, forKey: .playActionURL)
        shape = (try? c.decodeIfPresent(TopShelfShape.self, forKey: .shape)) ?? .square
        kind = (try? c.decodeIfPresent(TopShelfEntryKind.self, forKey: .kind)) ?? .track
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        playedAt = try c.decodeIfPresent(Date.self, forKey: .playedAt)
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

struct TopShelfSection: Codable, Equatable, Sendable {
    let kind: String
    let title: String
    let entries: [TopShelfEntry]

    init(kind: String, title: String, entries: [TopShelfEntry]) {
        self.kind = kind
        self.title = title
        self.entries = entries
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? title
        entries = try c.decode([TopShelfEntry].self, forKey: .entries)
    }
}

struct TopShelfSnapshot: Codable, Equatable, Sendable {
    var sections: [TopShelfSection]
    var generatedAt: Date
    var version: Int
    var isSignedIn: Bool

    init(
        sections: [TopShelfSection],
        generatedAt: Date,
        isSignedIn: Bool = true,
        version: Int = TopShelfStore.currentVersion
    ) {
        self.sections = sections
        self.generatedAt = generatedAt
        self.version = version
        self.isSignedIn = isSignedIn
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sections = try c.decode([TopShelfSection].self, forKey: .sections)
        generatedAt = try c.decodeIfPresent(Date.self, forKey: .generatedAt) ?? .distantPast
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        isSignedIn = try c.decodeIfPresent(Bool.self, forKey: .isSignedIn) ?? true
    }

    func section(kind: String) -> TopShelfSection? {
        sections.first { $0.kind == kind }
    }

    func hasSameContent(as other: TopShelfSnapshot) -> Bool {
        sections == other.sections && isSignedIn == other.isSignedIn && version == other.version
    }

    var itemCount: Int {
        sections.reduce(0) { $0 + $1.entries.count }
    }
}

enum TopShelfStore {
    static let appGroup = SoundingAppGroup.identifier
    static let urlScheme = "soundingtv"
    static let currentVersion = 3

    static let maxEntriesPerSection = 20

    static let maxSections = 5

    static let continueKind = "continue"
    static let recentsKind = "recents"
    static let recentsTitle = "Recently Played"
    static let likesKind = "likes"
    static let likesTitle = "Your Likes"
    static let mixesKind = "mixes"
    static let mixesTitle = "Mixes For You"
    static let recentsTrackCacheSection = "topshelf.recents.tracks"
    static let artworkDirectoryName = "TopShelfArt"

    static let snapshotDidChangeNotification = Notification.Name(
        "red.forbes.sounding.topShelfSnapshotDidChange"
    )

    static var containerURL: URL? {
        SoundingAppGroup.containerURL
    }

    static var writableURL: URL? {
        SoundingAppGroup.writableURL
    }

    static var fileURL: URL? {
        writableURL?.appendingPathComponent("topshelf.json")
    }

    static var artworkDirectoryURL: URL? {
        writableURL?.appendingPathComponent(artworkDirectoryName, isDirectory: true)
    }

    private static var legacyFileURL: URL? {
        let candidates = [
            containerURL?.appendingPathComponent("topshelf.json"),
            containerURL?
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Caches", isDirectory: true)
                .appendingPathComponent("topshelf.json"),
        ]
        return candidates.compactMap { $0 }.first { $0 != fileURL && FileManager.default.fileExists(atPath: $0.path) }
    }

    static func load() -> TopShelfSnapshot? {
        guard fileURL != nil else {
            Log.topShelf.error("No App Group container for \(appGroup, privacy: .public) — check entitlements on BOTH the app and the extension")
            return nil
        }

        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            if let snapshot = decode(data) { return snapshot }
            Log.topShelf.error("Snapshot at \(fileURL.path, privacy: .public) failed to decode")
        }

        if let legacyFileURL, let data = try? Data(contentsOf: legacyFileURL) {
            if let snapshot = decode(data) {
                if let fileURL {
                    try? data.write(to: fileURL, options: .atomic)
                }
                return snapshot
            }
            Log.topShelf.error("Snapshot at \(legacyFileURL.path, privacy: .public) failed to decode")
        }
        Log.topShelf.info("No shared Top Shelf snapshot — nothing published yet")
        return nil
    }

    static func decode(_ data: Data) -> TopShelfSnapshot? {
        try? JSONDecoder().decode(TopShelfSnapshot.self, from: data)
    }

    static func encode(_ snapshot: TopShelfSnapshot) -> Data? {
        try? JSONEncoder().encode(snapshot)
    }

    @discardableResult
    static func save(_ snapshot: TopShelfSnapshot) -> Bool {
        guard let fileURL else {
            Log.topShelf.error("No App Group container for \(appGroup, privacy: .public) — snapshot dropped")
            return false
        }
        if let existing = (try? Data(contentsOf: fileURL)).flatMap(decode), existing.hasSameContent(as: snapshot) {
            return false
        }
        guard let data = encode(snapshot) else { return false }
        do {
            try data.write(to: fileURL, options: .atomic)
            Log.topShelf.info("Published \(snapshot.sections.count) shelves / \(snapshot.itemCount) items (\(data.count) bytes)")
            return true
        } catch {
            Log.topShelf.error("Snapshot write failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    static let remoteArtworkVariant = "t500x500"

    static func artwork(_ url: URL?) -> URL? {
        guard let url else { return nil }
        guard url.host?.hasSuffix("sndcdn.com") == true, url.query == nil else { return url }

        let string = url.absoluteString
        guard let dot = string.lastIndex(of: "."),
              let dash = string[..<dot].lastIndex(of: "-") else { return url }
        return URL(string: string.replacingCharacters(in: dash..<dot, with: "-\(remoteArtworkVariant)")) ?? url
    }

    static func playURL(trackId: String, shelf: String? = nil, at position: TimeInterval? = nil) -> URL {
        var items = [URLQueryItem(name: "track", value: trackId)]
        if let shelf, !shelf.isEmpty {
            items.append(URLQueryItem(name: "from", value: shelf))
        }
        if let position, position.isFinite, position >= 1 {
            items.append(URLQueryItem(name: "at", value: String(Int(position.rounded(.down)))))
        }
        return components(host: "play", items: items)
    }

    static func trackURL(trackId: String) -> URL {
        components(host: "track", items: [URLQueryItem(name: "id", value: trackId)])
    }

    static func playlistURL(id: String, play: Bool = false) -> URL {
        var items = [URLQueryItem(name: "id", value: id)]
        if play {
            items.append(URLQueryItem(name: "play", value: "1"))
        }
        return components(host: "playlist", items: items)
    }

    static func mixURL(urn: String) -> URL {
        components(host: "mix", items: [URLQueryItem(name: "id", value: urn)])
    }

    static func homeURL() -> URL {
        components(host: "home", items: [])
    }

    static func signInURL() -> URL {
        components(host: "signin", items: [])
    }

    private static func components(host: String, items: [URLQueryItem]) -> URL {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = host
        if !items.isEmpty {
            components.queryItems = items
        }
        return components.url ?? URL(string: "\(urlScheme)://\(host)")!
    }

    enum Route: Equatable, Sendable {
        case track(id: String, shelf: String?, position: TimeInterval?)
        case trackDetails(id: String)
        case playlist(id: String, play: Bool)
        case mix(urn: String)
        case home
        case signIn

        var needsAccount: Bool {
            switch self {
            case .home, .signIn: return false
            case .track, .trackDetails, .playlist, .mix: return true
            }
        }
    }

    static func route(from url: URL) -> Route? {
        guard url.scheme?.lowercased() == urlScheme else { return nil }

        switch url.host?.lowercased() {
        case "home":   return .home
        case "signin": return .signIn
        default:       break
        }

        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }

        func value(_ name: String) -> String? {
            guard let raw = items.first(where: { $0.name == name })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            return raw
        }

        switch url.host?.lowercased() {
        case "play":
            guard let id = value("track") else { return nil }
            let position = value("at").flatMap(TimeInterval.init).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            return .track(id: id, shelf: value("from"), position: position)
        case "track":
            return value("id").map { .trackDetails(id: $0) }
        case "playlist":
            return value("id").map { .playlist(id: $0, play: value("play") == "1") }
        case "mix":
            return value("id").map { .mix(urn: $0) }
        default:
            return nil
        }
    }
}
