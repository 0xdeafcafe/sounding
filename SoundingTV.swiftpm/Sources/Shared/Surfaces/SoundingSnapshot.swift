import Foundation
#if os(macOS)
import Security
#endif

enum SoundingAppGroup {
    static let identifier = "group.red.forbes.sounding"

    static var containerURL: URL? {
        #if os(macOS)
        guard isEntitled else { return nil }
        #endif
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static var writableURL: URL? {
        guard let root = containerURL else { return nil }
        #if os(tvOS)
        let caches = root
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        return caches
        #else
        return root
        #endif
    }
    #if os(macOS)
    static let isEntitled: Bool = {
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil) as? [String] else {
            return false
        }
        return groups.contains(identifier)
    }()
    #endif
}

enum SoundingSurfaceKind {
    static let nowPlayingWidget = "red.forbes.sounding.widget.now-playing"
    static let watchNowPlayingWidget = "red.forbes.sounding.widget.watch-now-playing"
    static let watchListeningWidget = "red.forbes.sounding.widget.watch-listening"
    static let collectionWidget = "red.forbes.sounding.widget.collection"
    static let playPauseControl = "red.forbes.sounding.control.play-pause"
    static let resumeControl = "red.forbes.sounding.control.resume"
    static let skipControl = "red.forbes.sounding.control.skip"
    static let identifySongControl = "red.forbes.sounding.control.identify-song"
    static let recentlyPlayedWidget = "red.forbes.sounding.widget.recently-played"
}

struct SoundingSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let recentsLimit = 12

    enum ItemKind: String, Codable, Sendable {
        case track
        case playlist
        case artist
        case setlist
    }

    struct Item: Codable, Equatable, Sendable, Identifiable {
        var kind: ItemKind
        var id: String
        var title: String
        var subtitle: String
        var artworkURL: URL?
        var duration: TimeInterval?
        var isMix: Bool

        init(
            kind: ItemKind,
            id: String,
            title: String,
            subtitle: String = "",
            artworkURL: URL? = nil,
            duration: TimeInterval? = nil,
            isMix: Bool = false
        ) {
            self.kind = kind
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.artworkURL = artworkURL
            self.duration = duration
            self.isMix = isMix
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = (try? c.decode(ItemKind.self, forKey: .kind)) ?? .track
            id = try c.decode(String.self, forKey: .id)
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
            artworkURL = try? c.decodeIfPresent(URL.self, forKey: .artworkURL)
            duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration)
            isMix = try c.decodeIfPresent(Bool.self, forKey: .isMix) ?? false
        }
    }

    struct PositionAnchor: Codable, Equatable, Sendable {
        var position: TimeInterval
        var anchoredAt: Date
        var rate: Double

        init(position: TimeInterval, anchoredAt: Date, rate: Double) {
            self.position = position.isFinite ? max(0, position) : 0
            self.anchoredAt = anchoredAt
            self.rate = rate.isFinite ? max(0, rate) : 0
        }

        func position(at date: Date, duration: TimeInterval?) -> TimeInterval {
            let elapsed = max(0, date.timeIntervalSince(anchoredAt)) * rate
            let value = position + elapsed
            guard let duration, duration > 0 else { return value }
            return min(value, duration)
        }

        var startDate: Date {
            anchoredAt.addingTimeInterval(-position)
        }
    }

    struct NowPlaying: Codable, Equatable, Sendable {
        var item: Item
        var anchor: PositionAnchor
        var isPlaying: Bool
        var collectionID: String?
        var queueIndex: Int?
        var queueCount: Int?

        var duration: TimeInterval? { item.duration }

        func position(at date: Date) -> TimeInterval {
            anchor.position(at: date, duration: duration)
        }

        func progress(at date: Date) -> Double {
            guard let duration, duration > 0 else { return 0 }
            return min(max(position(at: date) / duration, 0), 1)
        }

        func isRunning(at date: Date) -> Bool {
            guard isPlaying else { return false }
            guard let duration, duration > 0 else { return true }
            return position(at: date) < duration
        }

        func ended(at date: Date) -> NowPlaying {
            var copy = self
            copy.isPlaying = false
            copy.anchor = PositionAnchor(position: duration ?? position(at: date), anchoredAt: date, rate: 0)
            return copy
        }
    }

    struct Resume: Codable, Equatable, Sendable {
        var item: Item
        var position: TimeInterval
        var collectionID: String?
        var savedAt: Date
    }

    var version: Int
    var generatedAt: Date
    var nowPlaying: NowPlaying?
    var lastMix: Resume?
    var recents: [Item]

    init(
        generatedAt: Date = Date(),
        nowPlaying: NowPlaying? = nil,
        lastMix: Resume? = nil,
        recents: [Item] = [],
        version: Int = SoundingSnapshot.currentVersion
    ) {
        self.version = version
        self.generatedAt = generatedAt
        self.nowPlaying = nowPlaying
        self.lastMix = lastMix
        self.recents = recents
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        generatedAt = try c.decodeIfPresent(Date.self, forKey: .generatedAt) ?? .distantPast
        nowPlaying = try? c.decodeIfPresent(NowPlaying.self, forKey: .nowPlaying)
        lastMix = try? c.decodeIfPresent(Resume.self, forKey: .lastMix)
        recents = (try? c.decodeIfPresent([LossyItem].self, forKey: .recents))?.compactMap(\.item) ?? []
    }

    static let empty = SoundingSnapshot(generatedAt: .distantPast)

    var isEmpty: Bool {
        nowPlaying == nil && lastMix == nil && recents.isEmpty
    }

    var resumeTarget: Resume? {
        if let nowPlaying {
            return Resume(
                item: nowPlaying.item,
                position: nowPlaying.position(at: generatedAt),
                collectionID: nowPlaying.collectionID,
                savedAt: generatedAt
            )
        }
        return lastMix
    }

    func recording(_ item: Item) -> SoundingSnapshot {
        var copy = self
        copy.recents.removeAll { $0.kind == item.kind && $0.id == item.id }
        copy.recents.insert(item, at: 0)
        if copy.recents.count > Self.recentsLimit {
            copy.recents.removeLast(copy.recents.count - Self.recentsLimit)
        }
        return copy
    }

    private struct LossyItem: Decodable {
        let item: Item?

        init(from decoder: Decoder) throws {
            item = try? Item(from: decoder)
        }
    }
}

enum SoundingSnapshotStore {
    static let fileName = "sounding-snapshot.json"

    static var defaultFileURL: URL? {
        SoundingAppGroup.writableURL?.appendingPathComponent(fileName)
    }

    static func encode(_ snapshot: SoundingSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }

    static func decode(_ data: Data) throws -> SoundingSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(SoundingSnapshot.self, from: data)
    }

    static func load(from fileURL: URL? = defaultFileURL) -> SoundingSnapshot? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decode(data)
    }

    @discardableResult
    static func save(_ snapshot: SoundingSnapshot, to fileURL: URL? = defaultFileURL) -> Bool {
        guard let fileURL, let data = try? encode(snapshot) else { return false }
        do {
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            return false
        }
    }

    static func remove(at fileURL: URL? = defaultFileURL) {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
