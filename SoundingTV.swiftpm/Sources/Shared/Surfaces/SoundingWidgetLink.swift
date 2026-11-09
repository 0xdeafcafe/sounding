import Foundation

enum SoundingWidgetLink: Equatable {
    enum Placement: String, Equatable, Sendable {
        case now
        case next
        case last
    }

    case nowPlaying
    case play(kind: SoundingSnapshot.ItemKind, id: String, position: TimeInterval)
    case open(source: URL, placement: Placement)

    static let scheme = "soundingtv"
    static let host = "widget"

    static func link(for item: SoundingSnapshot.Item, position: TimeInterval = 0) -> SoundingWidgetLink {
        .play(kind: item.kind, id: item.id, position: position)
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        switch self {
        case .nowPlaying:
            components.path = "/now-playing"
        case .play(let kind, let id, let position):
            components.path = "/play"
            var items = [
                URLQueryItem(name: "kind", value: kind.rawValue),
                URLQueryItem(name: "id", value: id)
            ]
            if position >= 1 {
                items.append(URLQueryItem(name: "position", value: String(Int(position))))
            }
            components.queryItems = items
        case .open(let source, let placement):
            components.path = "/open"
            components.queryItems = [
                URLQueryItem(name: "url", value: source.absoluteString),
                URLQueryItem(name: "at", value: placement.rawValue)
            ]
        }
        return components.url ?? URL(fileURLWithPath: "/")
    }

    static let universalHost = "sounding.forbes.red"

    private static func isRecognised(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        if scheme == Self.scheme { return url.host == Self.host }
        if scheme == "https" { return url.host?.lowercased() == Self.universalHost }
        return false
    }

    init?(url: URL) {
        guard Self.isRecognised(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let query = Dictionary(
            (components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        switch components.path {
        case "/now-playing":
            self = .nowPlaying
        case "/play":
            guard let id = query["id"], !id.isEmpty else { return nil }
            let kind = query["kind"].flatMap(SoundingSnapshot.ItemKind.init(rawValue:)) ?? .track
            let position = query["position"].flatMap { Double($0) } ?? 0
            self = .play(kind: kind, id: id, position: position.isFinite ? max(0, position) : 0)
        case "/open":
            guard let source = query["url"].flatMap(URL.init(string:)),
                  let scheme = source.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
            let placement = query["at"].flatMap(Placement.init(rawValue:)) ?? .now
            self = .open(source: source, placement: placement)
        default:
            return nil
        }
    }
}
