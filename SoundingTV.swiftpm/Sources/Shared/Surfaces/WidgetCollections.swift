import Foundation

struct WidgetCollection: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case playlist
        case setlist
        case station

        var label: String {
            switch self {
            case .playlist: "Playlist"
            case .setlist: "Setlist"
            case .station: "Station"
            }
        }
    }

    var kind: Kind
    var itemID: String
    var title: String
    var subtitle: String
    var artworkURL: URL?
    var symbol: String?

    var id: String { "\(kind.rawValue):\(itemID)" }

    var canShuffle: Bool { kind == .playlist }

    var detail: String {
        subtitle.isEmpty ? kind.label : "\(kind.label) · \(subtitle)"
    }

    var fallbackSymbol: String {
        if let symbol { return symbol }
        switch kind {
        case .playlist: return "music.note.list"
        case .setlist: return "waveform"
        case .station: return "dot.radiowaves.left.and.right"
        }
    }

    var artworkItem: SoundingSnapshot.Item {
        SoundingSnapshot.Item(
            kind: kind == .setlist ? .setlist : .playlist,
            id: kind == .station ? "station-\(itemID)" : itemID,
            title: title,
            subtitle: subtitle,
            artworkURL: artworkURL
        )
    }

    func isPlaying(in nowPlaying: SoundingSnapshot.NowPlaying?, at date: Date) -> Bool {
        guard let nowPlaying, nowPlaying.isRunning(at: date) else { return false }
        if nowPlaying.collectionID == itemID { return true }
        return kind == .setlist && nowPlaying.item.id == itemID
    }
}

enum WidgetCollectionStore {
    static let fileName = "sounding-widget-collections.json"
    static let limit = 24

    static var defaultFileURL: URL? {
        SoundingAppGroup.writableURL?.appendingPathComponent(fileName)
    }

    static func load(from fileURL: URL? = defaultFileURL) -> [WidgetCollection] {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let collections = try? JSONDecoder().decode([WidgetCollection].self, from: data) else { return [] }
        return collections
    }

    @discardableResult
    static func save(_ collections: [WidgetCollection], to fileURL: URL? = defaultFileURL) -> Bool {
        guard let fileURL else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Array(collections.prefix(limit))) else { return false }
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
