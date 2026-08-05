import Foundation

enum TopShelfShape: String, Codable, Sendable {
    case square
    case poster
    case hdtv
}

struct TopShelfEntry: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let artworkURL: URL?
    let artworkURL2x: URL?
    var progress: Double
    let actionURL: URL?
    let shape: TopShelfShape

    init(
        id: String,
        title: String,
        subtitle: String,
        artworkURL: URL?,
        artworkURL2x: URL? = nil,
        progress: Double = 0,
        actionURL: URL? = nil,
        shape: TopShelfShape = .square
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.artworkURL2x = artworkURL2x
        self.progress = min(max(progress, 0), 1)
        self.actionURL = actionURL
        self.shape = shape
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        artworkURL = try c.decodeIfPresent(URL.self, forKey: .artworkURL)
        artworkURL2x = try c.decodeIfPresent(URL.self, forKey: .artworkURL2x)
        progress = min(max(try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0, 0), 1)
        actionURL = try c.decodeIfPresent(URL.self, forKey: .actionURL)
        shape = try c.decodeIfPresent(TopShelfShape.self, forKey: .shape) ?? .square
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

    func section(titled title: String) -> TopShelfSection? {
        sections.first { $0.title == title } ?? section(kind: title)
    }

    var itemCount: Int {
        sections.reduce(0) { $0 + $1.entries.count }
    }
}

enum TopShelfStore {
    static let appGroup = "group.red.forbes.sounding"
    static let urlScheme = "soundingtv"
    static let currentVersion = 2

    static let maxEntriesPerSection = 20

    static let maxSections = 5

    static let recentsKind = "recents"
    static let recentsTitle = "Continue Listening"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    static var fileURL: URL? {
        cachesURL?.appendingPathComponent("topshelf.json")
    }

    private static var cachesURL: URL? {
        containerURL?
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
    }

    static func load() -> TopShelfSnapshot? {
        guard let fileURL else {
            Log.topShelf.error("No App Group container for \(appGroup, privacy: .public) — check entitlements on BOTH the app and the extension")
            return nil
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            Log.topShelf.info("No snapshot at \(fileURL.path, privacy: .public) — nothing published yet")
            return nil
        }
        do {
            return try JSONDecoder().decode(TopShelfSnapshot.self, from: data)
        } catch {
            Log.topShelf.error("Snapshot at \(fileURL.path, privacy: .public) failed to decode: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    @discardableResult
    static func save(_ snapshot: TopShelfSnapshot) -> Bool {
        guard let fileURL else {
            Log.topShelf.error("No App Group container for \(appGroup, privacy: .public) — snapshot dropped")
            return false
        }
        do {
            if let cachesURL {
                try? FileManager.default.createDirectory(
                    at: cachesURL, withIntermediateDirectories: true
                )
            }
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
            Log.topShelf.info("Published \(snapshot.sections.count) shelves / \(snapshot.itemCount) items (\(data.count) bytes)")
            return true
        } catch {
            Log.topShelf.error("Snapshot write failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    enum ArtworkSize: String {
        case screen1x = "t500x500"
        case screen2x = "t1080x1080"
    }

    static func artwork(_ url: URL?, at size: ArtworkSize) -> URL? {
        guard let url else { return nil }
        guard url.host?.hasSuffix("sndcdn.com") == true else { return url }

        let string = url.absoluteString
        guard let dot = string.lastIndex(of: "."),
              let dash = string[..<dot].lastIndex(of: "-") else { return url }
        return URL(string: string.replacingCharacters(in: dash..<dot, with: "-\(size.rawValue)")) ?? url
    }

    static func playURL(trackId: String) -> URL {
        components(host: "play", items: [URLQueryItem(name: "track", value: trackId)])
    }

    static func playlistURL(id: String, firstTrackId: String? = nil) -> URL {
        var items = [URLQueryItem(name: "id", value: id)]
        if let firstTrackId {
            items.append(URLQueryItem(name: "track", value: firstTrackId))
        }
        return components(host: "playlist", items: items)
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

    enum Route: Equatable {
        case track(id: String)
        case playlist(id: String, firstTrackId: String?)
        case home
        case signIn
    }

    static func route(from url: URL) -> Route? {
        guard url.scheme == urlScheme else { return nil }

        switch url.host {
        case "home":   return .home
        case "signin": return .signIn
        default:       break
        }

        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }

        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }

        switch url.host {
        case "play":
            return value("track").map { .track(id: $0) }
        case "playlist":
            return value("id").map { .playlist(id: $0, firstTrackId: value("track")) }
        default:
            return nil
        }
    }
}
