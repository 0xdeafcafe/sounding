#if DEBUG
import Foundation

enum SoundCloudMockService {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["SOUNDING_TV_SC_MOCK"] == "1"
    }

    static let meID = 900

    private static var environment: [String: String] { ProcessInfo.processInfo.environment }
    private static var likesTotal: Int { environment["SOUNDING_TV_SC_MOCK_LIKES"].flatMap(Int.init) ?? 2500 }
    private static var latency: Double { (environment["SOUNDING_TV_SC_MOCK_LATENCY_MS"].flatMap(Double.init) ?? 120) / 1000 }
    private static var mediaHost: String? { environment["SOUNDING_TV_STREAM_HOST"] }

    static func transport() -> SoundCloudHTTPTransport {
        SoundCloudHTTPTransport { request in
            let delay = latency * Double.random(in: 0.6...1.4)
            try await Task.sleep(for: .seconds(delay))
            return respond(to: request)
        }
    }

    static func respond(to request: URLRequest) -> (Data, URLResponse) {
        guard let url = request.url else {
            return reply(URL(string: "https://api-v2.soundcloud.com")!, status: 400, json: [:])
        }
        let method = request.httpMethod?.uppercased() ?? "GET"
        let host = url.host?.lowercased() ?? ""
        if host.hasSuffix("sndcdn.com") {
            if url.pathExtension == "json" {
                return reply(url, json: waveform(seed: url.lastPathComponent.hashValue))
            }
            return reply(url, status: 200, json: [:])
        }
        if host == "secure.soundcloud.com" {
            return reply(url, json: [
                "access_token": "mock-access", "refresh_token": "mock-refresh",
                "expires_in": 3600, "token_type": "bearer", "scope": "",
            ])
        }
        guard method == "GET" else { return reply(url, json: [:]) }
        let path = url.path.split(separator: "/").map(String.init)
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        let limit = query["limit"].flatMap(Int.init) ?? 50
        let offset = query["offset"].flatMap(Int.init) ?? 0
        guard let json = route(path: path, query: query, url: url, limit: limit, offset: offset) else {
            return reply(url, status: 404, json: ["error": "not found"])
        }
        return reply(url, json: json)
    }

    private static func route(path: [String], query: [String: String], url: URL, limit: Int, offset: Int) -> Any? {
        switch path.count {
        case 1:
            switch path[0] {
            case "me": return user(meID)
            case "stream": return page(url, total: 100, limit: limit, offset: offset) { feedActivity($0) }
            case "tracks":
                let ids = (query["ids"] ?? "").split(separator: ",").compactMap { Int($0) }
                return ids.map(track)
            case "mixed-selections":
                return ["collection": (0..<6).map(selection), "next_href": NSNull()]
            case "charts":
                return page(url, total: 50, limit: limit, offset: offset) { ["score": Double(1000 - $0), "track": track(300_000 + $0)] }
            case "resolve": return track(400_000)
            default: return nil
            }
        case 2:
            switch (path[0], path[1]) {
            case ("users", let id): return Int(id).map(user)
            case ("tracks", let id): return Int(id).map(track)
            case ("playlists", let id): return Int(id).map { playlist($0, embedded: 5, total: 40) }
            case ("system-playlists", let urn): return systemPlaylist(urn)
            case ("charts", "selections"): return ["collection": (0..<3).map(selection), "next_href": NSNull()]
            case ("search", "tracks"): return page(url, total: 200, limit: limit, offset: offset) { track(500_000 + $0) }
            case ("search", "users"): return page(url, total: 60, limit: limit, offset: offset) { user(2_000 + $0) }
            case ("search", "playlists"): return page(url, total: 60, limit: limit, offset: offset) { playlist(600_000 + $0, embedded: 0, total: 12) }
            case ("me", "conversations"): return ["collection": [], "next_href": NSNull()]
            default: return nil
            }
        case 3:
            switch (path[0], path[1], path[2]) {
            case ("users", let id, "track_likes"):
                let owner = Int(id) ?? meID
                let total = owner == meID ? likesTotal : 120
                return page(url, total: total, limit: limit, offset: offset) { index in
                    ["created_at": date(minutesAgo: index * 37), "kind": "like", "track": track(owner == meID ? 100_000 + index : 700_000 + owner * 1_000 + index)]
                }
            case ("users", _, "playlist_likes"):
                return page(url, total: 40, limit: limit, offset: offset) { ["created_at": date(minutesAgo: $0 * 600), "playlist": playlist(800_000 + $0, embedded: 0, total: 30)] }
            case ("users", let id, "playlists"):
                let owner = Int(id) ?? meID
                return page(url, total: owner == meID ? 25 : 8, limit: limit, offset: offset) { playlist(810_000 + owner * 100 + $0, embedded: 0, total: 20) }
            case ("users", let id, "tracks"):
                let owner = Int(id) ?? 101
                return page(url, total: 60, limit: limit, offset: offset) { track(900_000 + owner * 100 + $0) }
            case ("users", _, "followings"):
                return page(url, total: 150, limit: limit, offset: offset) { user(101 + $0) }
            case ("users", _, "followers"):
                return page(url, total: 200, limit: limit, offset: offset) { user(3_000 + $0) }
            case ("me", "library", "all"):
                return page(url, total: 160, limit: limit, offset: offset) { libraryItem($0) }
            case ("me", "play-history", "tracks"):
                return page(url, total: 50, limit: limit, offset: offset) { index in
                    ["played_at": Int64(Date().addingTimeInterval(Double(-index * 900)).timeIntervalSince1970 * 1000),
                     "track_id": 100_000 + index * 3, "track": track(100_000 + index * 3)]
                }
            case ("tracks", let id, "comments"):
                let trackID = Int(id) ?? 1
                return page(url, total: trackID % 10 == 0 ? 240 : 45, limit: limit, offset: offset) { comment(trackID: trackID, index: $0) }
            case ("tracks", let id, "related"):
                let trackID = Int(id) ?? 1
                return page(url, total: 20, limit: limit, offset: offset) { track(1_000_000 + (trackID % 5_000) * 20 + $0) }
            case ("tracks", _, "playlists"):
                return page(url, total: 6, limit: limit, offset: offset) { playlist(820_000 + $0, embedded: 0, total: 10) }
            default:
                if path[0] == "media" { return ["url": streamURL(for: path)] }
                return nil
            }
        default:
            if path.first == "media" { return ["url": streamURL(for: path)] }
            if path.count == 4, path[0] == "users", path[2] == "followings" {
                return Int(path[3]).map { $0 % 2 == 0 ? user($0) : nil } ?? nil
            }
            if path.count == 4, path[0] == "stream", path[1] == "users", path[3] == "reposts" {
                return page(url, total: 30, limit: limit, offset: offset) { feedActivity($0 + 500) }
            }
            return nil
        }
    }

    private static func streamURL(for path: [String]) -> String {
        let id = path.first { $0.hasPrefix("soundcloud:tracks:") }?.split(separator: ":").last.map(String.init) ?? "0"
        if let mediaHost { return "\(mediaHost)/audio.m4a?track=\(id)" }
        return "https://cf-media.sndcdn.com/mock-\(id).mp3"
    }

    private static func page(
        _ url: URL,
        total: Int,
        limit: Int,
        offset: Int,
        item: (Int) -> Any
    ) -> [String: Any] {
        let end = min(total, offset + max(1, limit))
        let collection = offset < end ? (offset..<end).map(item) : []
        var next: Any = NSNull()
        if end < total, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            var items = (components.queryItems ?? []).filter { $0.name != "offset" && $0.name != "limit" }
            items.append(URLQueryItem(name: "offset", value: String(end)))
            items.append(URLQueryItem(name: "limit", value: String(limit)))
            components.queryItems = items
            next = components.url?.absoluteString ?? NSNull()
        }
        return ["collection": collection, "next_href": next]
    }

    private static func date(minutesAgo: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date(timeIntervalSince1970: 1_790_000_000).addingTimeInterval(Double(-minutesAgo * 60)))
    }

    static func user(_ id: Int) -> [String: Any] {
        [
            "id": id, "kind": "user", "urn": "soundcloud:users:\(id)",
            "username": id == meID ? "mock-listener" : "mock-artist-\(id)",
            "full_name": id == meID ? "Mock Listener" : "Mock Artist \(id)",
            "permalink": "mock-artist-\(id)",
            "permalink_url": "https://soundcloud.com/mock-artist-\(id)",
            "avatar_url": NSNull(),
            "followers_count": 1_000 + id * 7, "followings_count": 150,
            "track_count": 60, "playlist_count": 8,
            "description": "A mock profile used for traffic measurement.",
            "city": "London", "country_code": "GB",
        ]
    }

    static func track(_ id: Int) -> [String: Any] {
        let artist = 101 + id % 40
        let isMix = id % 10 == 0
        let duration = isMix ? 3_600_000 : 180_000 + (id % 7) * 20_000
        let description = isMix
            ? "Tracklist:\n00:00 Mock Artist 101 - Opening\n05:30 Mock Artist 102 - Second\n12:10 Mock Artist 103 - Third\n25:00 Mock Artist 104 - Fourth\n40:45 Mock Artist 105 - Fifth"
            : "A mock track used for traffic measurement."
        return [
            "id": id, "kind": "track", "urn": "soundcloud:tracks:\(id)",
            "title": isMix ? "Mock Mix \(id)" : "Mock Track \(id)",
            "description": description,
            "artwork_url": NSNull(),
            "waveform_url": "https://wave.sndcdn.com/mock\(id)_m.json",
            "permalink_url": "https://soundcloud.com/mock-artist-\(artist)/track-\(id)",
            "playback_count": 10_000 + id % 9_000, "likes_count": 400 + id % 300,
            "reposts_count": 20 + id % 50, "comment_count": isMix ? 240 : 45,
            "created_at": date(minutesAgo: id % 100_000), "genre": isMix ? "House" : "Electronic",
            "tag_list": "electronic mock", "duration": duration, "full_duration": duration,
            "streamable": true, "policy": "ALLOW", "sharing": "public",
            "user": user(artist),
            "media": ["transcodings": [[
                "url": "https://api-v2.soundcloud.com/media/soundcloud:tracks:\(id)/mock/stream/progressive",
                "preset": "aac_160k", "duration": duration, "snipped": false, "quality": "sq",
                "format": ["protocol": "progressive", "mime_type": "audio/mp4"],
            ]]],
        ]
    }

    private static func playlist(_ id: Int, embedded: Int, total: Int) -> [String: Any] {
        let owner = 101 + id % 40
        let ids = (0..<total).map { 1_200_000 + (id % 1_000) * 50 + $0 }
        let tracks: [[String: Any]] = ids.enumerated().map { index, trackID in
            index < embedded ? track(trackID) : ["id": trackID, "kind": "track"]
        }
        return [
            "id": id, "kind": "playlist", "urn": "soundcloud:playlists:\(id)",
            "title": "Mock Playlist \(id)", "description": "Mock playlist",
            "artwork_url": NSNull(),
            "permalink_url": "https://soundcloud.com/mock-artist-\(owner)/sets/\(id)",
            "duration": total * 200_000, "track_count": total,
            "likes_count": 100, "reposts_count": 10, "is_album": id % 5 == 0,
            "created_at": date(minutesAgo: id % 50_000),
            "user": user(owner), "tracks": tracks,
        ]
    }

    private static func systemPlaylist(_ urn: String) -> [String: Any] {
        let decoded = urn.removingPercentEncoding ?? urn
        let seed = abs(decoded.hashValue % 10_000)
        return [
            "urn": decoded, "id": decoded, "kind": "system-playlist",
            "title": "Mock Station \(seed)", "short_title": "Station",
            "description": "Mock station", "playlist_type": "TRACK_STATION",
            "permalink_url": "https://soundcloud.com/discover/sets/mock-\(seed)",
            "artwork_url": NSNull(),
            "user": user(101), "likes_count": 0, "is_public": true,
            "tracks": (0..<50).map { ["id": 1_500_000 + seed * 50 + $0, "kind": "track"] },
        ]
    }

    private static func selection(_ index: Int) -> [String: Any] {
        let items: [[String: Any]] = (0..<8).map { item in
            if index % 2 == 0 {
                var station = systemPlaylist("soundcloud:system-playlists:mock-\(index)-\(item)")
                station["kind"] = "system-playlist"
                return station
            }
            var set = playlist(830_000 + index * 10 + item, embedded: 0, total: 15)
            set["kind"] = "playlist"
            return set
        }
        return [
            "id": "mock-selection-\(index)", "title": "Mock Selection \(index)",
            "description": "Mock", "tracking_feature_name": "mock",
            "items": ["collection": items, "next_href": NSNull()],
        ]
    }

    private static func libraryItem(_ index: Int) -> [String: Any] {
        var item: [String: Any] = ["created_at": date(minutesAgo: index * 120)]
        switch index % 4 {
        case 0: item["playlist"] = playlist(840_000 + index, embedded: 0, total: 25)
        case 1:
            var station = systemPlaylist("soundcloud:system-playlists:library-\(index)")
            station.removeValue(forKey: "tracks")
            item["system_playlist"] = station
        default: item["track"] = track(100_000 + index)
        }
        return item
    }

    private static func feedActivity(_ index: Int) -> [String: Any] {
        var item: [String: Any] = [
            "created_at": date(minutesAgo: index * 45),
            "uuid": "mock-feed-\(index)",
            "user": user(101 + index % 40),
        ]
        if index % 5 == 4 {
            item["type"] = "playlist"
            item["playlist"] = playlist(850_000 + index, embedded: 0, total: 12)
        } else {
            item["type"] = index % 3 == 0 ? "track-repost" : "track"
            item["track"] = track(1_100_000 + index)
        }
        return item
    }

    private static func comment(trackID: Int, index: Int) -> [String: Any] {
        [
            "id": trackID * 1_000 + index, "kind": "comment",
            "body": index % 7 == 0 ? "ID? 12:10" : "Mock comment \(index)",
            "timestamp": 20_000 + (index * 37_000) % 160_000,
            "created_at": date(minutesAgo: index * 13),
            "user": user(3_000 + index % 50),
        ]
    }

    private static func waveform(seed: Int) -> [String: Any] {
        var generator = SystemRandomNumberGenerator()
        _ = seed
        return ["width": 1800, "height": 140, "samples": (0..<1800).map { _ in Int.random(in: 20...140, using: &generator) }]
    }

    private static func reply(_ url: URL, status: Int = 200, json: Any) -> (Data, URLResponse) {
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json; charset=utf-8"]
        )!
        return (data, response)
    }
}
#endif
