#if DEBUG
import Foundation

enum VisualFixtures {
    static let environmentKey = "SOUNDING_TV_UI_FIXTURE"

    static let isEnabled: Bool = {
        let raw = ProcessInfo.processInfo.environment[environmentKey]?.lowercased()
        #if os(macOS)
        return raw == "1" || raw == "loaded" || raw == "true"
            || ProcessInfo.processInfo.arguments.contains("--ui-fixture")
        #else
        return raw == "1" || raw == "loaded" || raw == "true"
            || ProcessInfo.processInfo.arguments.contains("--ui-fixture")
            || UserDefaults.sounding.bool(forKey: environmentKey)
        #endif
    }()

    static var destination: String? {
        guard isEnabled else { return nil }
        if let environment = ProcessInfo.processInfo.environment["SOUNDING_TV_UI_DESTINATION"] {
            return environment
        }
        if let argument = ProcessInfo.processInfo.arguments
            .first(where: { $0.hasPrefix("--ui-destination=") })?
            .replacingOccurrences(of: "--ui-destination=", with: "") {
            return argument
        }
        return UserDefaults.sounding.string(forKey: "SOUNDING_TV_UI_DESTINATION")
    }

    private static let decoder: JSONDecoder = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(formatter)
        return decoder
    }()

    static let currentUser = user(id: 900, name: "Sounding Listener", followers: 12_480, tracks: 86)

    static let artists: [User] = [
        user(id: 101, name: "Night Tapes", followers: 184_200, tracks: 72),
        user(id: 102, name: "Maya Sol", followers: 82_400, tracks: 41),
        user(id: 103, name: "Glass District", followers: 316_900, tracks: 128),
        user(id: 105, name: "Low Sun", followers: 140_700, tracks: 63),
        user(id: 106, name: "Soft Static", followers: 96_300, tracks: 49),
        user(id: 107, name: "Juno Vale", followers: 224_800, tracks: 91),
    ]

    static let tracks: [Track] = {
        let titles = [
            "Wavelength", "Late Night Drive", "Close to the Sun", "Orange Rooms",
            "Nothing Stays Still", "Half Light", "Paper Satellites", "Soft Focus",
            "Between Stations", "Quietly Electric", "Slow Bloom", "After the Rain",
            "Parallel Lines", "Somewhere Between the Last Train and the First Light",
            "Signal Fires", "Warm Current", "City Without Sleep", "Glass Horizon",
        ]
        return titles.enumerated().map { index, title in
            track(id: 1_000 + index, title: title, user: artists[index % artists.count], seconds: 176 + index * 11)
        }
    }()

    static let longSetEnabled = ProcessInfo.processInfo.environment["SOUNDING_TV_FIXTURE_SET"] == "2h"

    static let longSetTracklist: [(start: Int, artist: String, title: String)] = [
        (0, "Night Tapes", "Glasshouse (Intro)"), (220, "Low Sun", "First Light"), (475, "Maya Sol", "Neon Weather"),
        (730, "Glass District", "After Hours"), (990, "Juno Vale", "Parallel Lines"), (1245, "Soft Static", "Home Signal"),
        (1460, "Night Tapes", "Open Water"), (1690, "Low Sun", "Harbour Lights"), (1925, "Glass District", "Salt & Static"),
        (2190, "Night Tapes", "Tidewater"), (2418, "Maya Sol", "Lanterns (Dub)"), (2682, "Low Sun", "Long Exposure"),
        (2960, "Low Sun", "Halyard"), (3233, "Glass District", "Copperline"), (3526, "Maya Sol", "Sodium Lights"),
        (3828, "ID", "Unidentified"), (4086, "Night Tapes", "Northbound"), (4395, "Glass District", "Small Hours"),
        (4670, "Low Sun", "Ember"), (4960, "Maya Sol", "Coastline"), (5267, "Night Tapes", "Last Orders"),
        (5600, "Glass District", "Daybreak"), (5857, "Low Sun", "Glass Rain"), (6193, "Night Tapes", "Opening Hours"),
        (6520, "ID", "Unidentified"), (6842, "Juno Vale", "Last Light"),
    ]

    static let longSetComments: [(time: Int, body: String)] = [
        (95, "here we go"), (480, "Neon Weather into this, wow"), (1010, "the vocal on this one"),
        (1480, "proper sunrise energy"), (1930, "Salt & Static!!"), (2420, "this dub is unreal"),
        (2700, "slow burner"), (3000, "Halyard gets me every time"), (3240, "the bassline at 54:00"),
        (3530, "Sodium Lights 🔥"), (3640, "this blend is unreal"), (3700, "turn it up"), (3760, "ID anyone?"),
        (3835, "need this ID"), (3905, "that filter sweep"), (4100, "Northbound, finally"), (4420, "goosebumps"),
        (4980, "the strings here"), (5300, "last orders indeed"), (5620, "perfect blend"), (5900, "rain sounds"),
        (6200, "the build"), (6530, "another ID 👀"), (6900, "what a closer"), (7100, "sending this to everyone"),
    ]

    static func longSetWaveform(samplesPerSecond: Double = 2) -> [Float] {
        let duration = 7_200.0
        let count = Int(duration * samplesPerSecond)
        let starts = longSetTracklist.map { Double($0.start) }
        var seed: UInt64 = 0x5EED
        var level: Float = 0.6
        return (0..<count).map { index in
            let time = Double(index) / samplesPerSecond
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = Float(seed >> 40) / Float(1 << 24)
            level = level * 0.55 + noise * 0.45
            let entry = starts.last(where: { $0 <= time }) ?? 0
            let next = starts.first(where: { $0 > time }) ?? duration
            let into = (time - entry) / max(1, next - entry)
            let breakdown: Float = into > 0.55 && into < 0.68 ? 0.32 : 1
            let blend: Float = time - entry < 12 || next - time < 12 ? 0.82 : 1
            let phrase = Float(0.82 + 0.18 * sin(time / 16 * .pi))
            return max(0.08, min(1, (0.35 + level * 0.65) * breakdown * blend * phrase))
        }
    }

    static let nowPlayingMix: Track = longSetEnabled ? longSet : shortMix

    static let longSet: Track = {
        let lines = longSetTracklist.map { entry in
            let hours = entry.start / 3600
            let minutes = (entry.start % 3600) / 60
            let seconds = entry.start % 60
            let stamp = hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%02d:%02d", minutes, seconds)
            return "\(stamp) \(entry.artist) — \(entry.title)"
        }
        let description = (["Tracklist:"] + lines).joined(separator: "\\n")
        return decode(Track.self, from: """
        {
          "id": 1998, "title": "Night Tapes 014 — Glasshouse Session",
          "description": "\(description)",
          "artwork_url": null,
          "waveform_url": null,
          "permalink_url": "https://soundcloud.com/fixture/night-tapes-014",
          "playback_count": 412880, "likes_count": 23110, "reposts_count": 3104,
          "created_at": "2026-10-24T12:00:00Z", "genre": "Electronic",
          "tag_list": "electronic dj set house mix",
          "user": \(encodedJSON(artists[0])),
          "media": { "transcodings": [{
            "url": "https://example.invalid/night-tapes-014.mp3", "preset": "mp3_1_0",
            "duration": 7200000, "quality": "sq", "snipped": false,
            "format": { "protocol": "progressive", "mime_type": "audio/mpeg" }
          }] }
        }
        """)
    }()

    static func longSetCommentList() -> [Comment] {
        longSetComments.enumerated().compactMap { index, item in
            let user = artists[index % artists.count]
            let json = "{\"id\": \(8_000 + index), \"body\": \"\(item.body)\", \"timestamp\": \(item.time * 1000), \"user\": \(encodedJSON(user))}"
            return try? JSONDecoder().decode(Comment.self, from: Data(json.utf8))
        }
    }

    static let shortMix: Track = decode(Track.self, from: """
        {
          "id": 1999, "title": "Summer Night DJ Set",
          "description": "Tracklist:\\n00:00 Low Sun — First Light\\n01:04 Maya Sol — Neon Weather\\n03:15 Glass District — After Hours\\n18:42 Low Sun — Open Water\\n37:08 Juno Vale — Parallel Lines\\n52:36 Soft Static — Home Signal",
          "artwork_url": null,
          "waveform_url": null,
          "permalink_url": "https://soundcloud.com/fixture/summer-night-set-set",
          "playback_count": 284192, "likes_count": 18420, "reposts_count": 2118,
          "created_at": "2026-07-24T12:00:00Z", "genre": "Electronic",
          "tag_list": "electronic dj set house independent",
          "user": \(encodedJSON(artists[0])),
          "media": { "transcodings": [{
            "url": "https://example.invalid/summer-night-set.mp3", "preset": "mp3_1_0",
            "duration": 3843000, "quality": "sq", "snipped": false,
            "format": { "protocol": "progressive", "mime_type": "audio/mpeg" }
          }] }
        }
        """)

    static let albums: [Playlist] = [
        playlist(id: 2_001, title: "Wavelength", user: artists[0], isAlbum: true, tracks: Array(tracks[0..<8])),
        playlist(id: 2_002, title: "Soft Focus", user: artists[5], isAlbum: true, tracks: Array(tracks[5..<13])),
        playlist(id: 2_003, title: "Glass Horizon", user: artists[2], isAlbum: true, tracks: Array(tracks[8..<16])),
        playlist(id: 2_004, title: "Half Light", user: artists[3], isAlbum: true, tracks: Array(tracks[2..<10])),
        playlist(id: 2_005, title: "Slow Bloom", user: artists[4], isAlbum: true, tracks: Array(tracks[4..<12])),
        playlist(id: 2_006, title: "Between Stations", user: artists[1], isAlbum: true, tracks: Array(tracks[7..<15])),
    ]

    static let playlists: [Playlist] = [
        playlist(id: 3_001, title: "Made for Late Nights", user: currentUser, isAlbum: false, tracks: Array(tracks[0..<10])),
        playlist(id: 3_002, title: "Fresh Finds", user: currentUser, isAlbum: false, tracks: Array(tracks[3..<13])),
        playlist(id: 3_003, title: "Quiet Energy", user: currentUser, isAlbum: false, tracks: Array(tracks[6..<16])),
        playlist(id: 3_004, title: "Reposted Gems", user: currentUser, isAlbum: false, tracks: Array(tracks[1..<11])),
        playlist(id: 3_005, title: "Weekend Selects", user: currentUser, isAlbum: false, tracks: Array(tracks[8..<18])),
        playlist(id: 3_006, title: "Sunday Headphones", user: currentUser, isAlbum: false, tracks: Array(tracks[2..<12])),
    ]

    static var discoveryShelves: [DiscoveryShelf] {
        [
            DiscoveryShelf(
                id: "fixture.fresh", title: "Fresh for You",
                subtitle: "Independent sounds picked for today", kind: .editorial,
                content: .tracks(Array(tracks.prefix(10)))
            ),
            DiscoveryShelf(
                id: "fixture.playlists", title: "Made for Late Nights",
                subtitle: "Long listens with room to breathe", kind: .related,
                content: .playlists(Array(playlists.prefix(6)))
            ),
            DiscoveryShelf(
                id: "fixture.artists", title: "Artists to Follow",
                subtitle: "Creators moving through your orbit", kind: .station,
                content: .users(artists)
            ),
            DiscoveryShelf(
                id: "fixture.albums", title: "New Albums",
                subtitle: nil, kind: .chartCollections,
                content: .playlists(albums)
            ),
            DiscoveryShelf(
                id: "fixture.trending", title: "Trending Now",
                subtitle: "What the community is playing", kind: .trending,
                content: .tracks(Array(tracks.dropFirst(5).prefix(12)))
            ),
            DiscoveryShelf(
                id: "fixture.likedBy", title: "Liked By",
                subtitle: "Picks from people you follow", kind: .editorial,
                content: .stations(likedByPicks)
            ),
        ]
    }

    static var likedByPicks: [SystemPlaylist] {
        ["Juno Vale", "Glass District", "Maya Sol"].enumerated().compactMap { index, name in
            let json: [String: Any] = [
                "urn": "soundcloud:system-playlists:liked-by:fixture-\(index)",
                "title": "\(name)'s Picks",
                "short_title": "\(name)'s Picks",
                "short_description": "Liked by \(name)",
                "playlist_type": "PLAYLIST",
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
            return try? JSONDecoder().decode(SystemPlaylist.self, from: data)
        }
    }

    static var libraryItems: [LibraryItem] {
        let trackItems = tracks.prefix(6).enumerated().map { offset, track in
            LibraryItem(createdAt: Date().addingTimeInterval(Double(-offset * 900)), track: track, playlist: nil, systemPlaylist: nil)
        }
        let collectionItems = (Array(albums.prefix(3)) + Array(playlists.prefix(3))).enumerated().map { offset, playlist in
            LibraryItem(createdAt: Date().addingTimeInterval(Double(-(offset + 6) * 900)), track: nil, playlist: playlist, systemPlaylist: nil)
        }
        return trackItems + collectionItems
    }

    static var feed: [FeedActivity] {
        let date = Date()
        var result: [FeedActivity] = [
            FeedActivity(kind: .playlist, createdAt: date, actor: albums[0].user, uuid: "hero-album", caption: nil, track: nil, playlist: albums[0]),
            FeedActivity(kind: .playlistRepost, createdAt: date.addingTimeInterval(-60), actor: artists[5], uuid: "hero-playlist", caption: nil, track: nil, playlist: playlists[0]),
        ]
        result += tracks.prefix(10).enumerated().map { index, track in
            FeedActivity(
                kind: index.isMultiple(of: 3) ? .trackRepost : .track,
                createdAt: date.addingTimeInterval(Double(-(index + 2) * 120)),
                actor: index.isMultiple(of: 3) ? artists[(index + 2) % artists.count] : track.user,
                uuid: "feed-track-\(index)", caption: nil, track: track, playlist: nil
            )
        }
        let collections = Array(albums.dropFirst().prefix(4)) + Array(playlists.dropFirst().prefix(4))
        result += collections.enumerated().map { index, playlist in
            FeedActivity(
                kind: index.isMultiple(of: 2) ? .playlistRepost : .playlist,
                createdAt: date.addingTimeInterval(Double(-(index + 20) * 120)),
                actor: index.isMultiple(of: 2) ? artists[(index + 3) % artists.count] : playlist.user,
                uuid: "feed-playlist-\(index)", caption: nil, track: nil, playlist: playlist
            )
        }
        return result
    }

    private static func user(id: Int, name: String, followers: Int, tracks: Int) -> User {
        let avatar = ProcessInfo.processInfo.environment["SOUNDING_TV_FIXTURE_AVATAR"].map { "\"avatar_url\": \"\($0)\"," } ?? ""
        return decode(User.self, from: """
        {
          \(avatar)
          "id": \(id), "username": "\(name)", "permalink": "fixture-\(id)",
          "permalink_url": "https://soundcloud.com/fixture-\(id)",
          "full_name": "\(name)", "description": "Independent music, made at home and played out loud.",
          "track_count": \(tracks), "playlist_count": 12,
          "followers_count": \(followers), "followings_count": 240
        }
        """)
    }

    private static func track(id: Int, title: String, user: User, seconds: Int) -> Track {
        let userJSON = encodedJSON(user)
        return decode(Track.self, from: """
        {
          "id": \(id), "title": "\(title)",
          "description": "A fixture track used only to review layout, focus, and typography.",
          "artwork_url": null, "waveform_url": null,
          "permalink_url": "https://soundcloud.com/fixture/\(id)",
          "playback_count": \(180000 + id * 9), "likes_count": \(12000 + id),
          "reposts_count": \(900 + id % 500), "created_at": "2026-07-24T12:00:00Z",
          "genre": "Electronic", "tag_list": "electronic ambient independent",
          "user": \(userJSON),
          "media": { "transcodings": [{
            "url": "https://example.invalid/audio-\(id).mp3", "preset": "mp3_1_0",
            "duration": \(seconds * 1000), "quality": "sq", "snipped": false,
            "format": { "protocol": "progressive", "mime_type": "audio/mpeg" }
          }] }
        }
        """)
    }

    private static func playlist(id: Int, title: String, user: User, isAlbum: Bool, tracks: [Track]) -> Playlist {
        let duration = Int(tracks.reduce(0) { $0 + $1.duration } * 1000)
        let tracksJSON = tracks.map(encodedJSON).joined(separator: ",")
        return decode(Playlist.self, from: """
        {
          "id": \(id), "title": "\(title)",
          "description": "A carefully selected set with room to breathe.",
          "artwork_url": null, "permalink_url": "https://soundcloud.com/fixture/sets/\(id)",
          "duration": \(duration), "track_count": \(tracks.count),
          "likes_count": \(24000 + id), "reposts_count": \(1200 + id % 400),
          "created_at": "2026-07-18T12:00:00Z", "is_album": \(isAlbum),
          "user": \(encodedJSON(user)), "tracks": [\(tracksJSON)]
        }
        """)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from json: String) -> T {
        do { return try decoder.decode(type, from: Data(json.utf8)) }
        catch { fatalError("Invalid visual fixture \(T.self): \(error)") }
    }

    private static func encodedJSON<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .formatted({
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
            formatter.timeZone = TimeZone(identifier: "UTC")
            return formatter
        }())
        guard let data = try? encoder.encode(value),
              let json = String(data: data, encoding: .utf8) else {
            fatalError("Failed to encode visual fixture \(T.self)")
        }
        return json
    }
}
#endif
