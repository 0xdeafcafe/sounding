#if DEBUG
import Foundation

enum VisualFixtures {
    static let environmentKey = "SOUNDING_TV_UI_FIXTURE"

    static var isEnabled: Bool {
        let raw = ProcessInfo.processInfo.environment[environmentKey]?.lowercased()
        return raw == "1" || raw == "loaded" || raw == "true"
            || ProcessInfo.processInfo.arguments.contains("--ui-fixture")
            || UserDefaults.standard.bool(forKey: environmentKey)
    }

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
        return UserDefaults.standard.string(forKey: "SOUNDING_TV_UI_DESTINATION")
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
        user(id: 104, name: "Theo Moss", followers: 54_100, tracks: 36),
        user(id: 105, name: "Low Sun", followers: 140_700, tracks: 63),
        user(id: 106, name: "Soft Static", followers: 96_300, tracks: 49),
        user(id: 107, name: "Juno Vale", followers: 224_800, tracks: 91),
        user(id: 108, name: "After Images", followers: 68_500, tracks: 31),
    ]

    static let tracks: [Track] = {
        let titles = [
            "Wavelength", "Late Night Drive", "Close to the Sun", "Orange Rooms",
            "Nothing Stays Still", "Half Light", "Paper Satellites", "Soft Focus",
            "Between Stations", "Quietly Electric", "Slow Bloom", "After the Rain",
            "Parallel Lines", "A Very Long SoundCloud Track Title That Still Has to Fit",
            "Signal Fires", "Warm Current", "City Without Sleep", "Glass Horizon",
        ]
        return titles.enumerated().map { index, title in
            track(id: 1_000 + index, title: title, user: artists[index % artists.count], seconds: 176 + index * 11)
        }
    }()

    static let albums: [Playlist] = [
        playlist(id: 2_001, title: "Wavelength", user: artists[0], isAlbum: true, tracks: Array(tracks[0..<8])),
        playlist(id: 2_002, title: "Soft Focus", user: artists[5], isAlbum: true, tracks: Array(tracks[5..<13])),
        playlist(id: 2_003, title: "Glass Horizon", user: artists[2], isAlbum: true, tracks: Array(tracks[8..<16])),
        playlist(id: 2_004, title: "Half Light", user: artists[3], isAlbum: true, tracks: Array(tracks[2..<10])),
        playlist(id: 2_005, title: "Slow Bloom", user: artists[6], isAlbum: true, tracks: Array(tracks[4..<12])),
        playlist(id: 2_006, title: "Between Stations", user: artists[7], isAlbum: true, tracks: Array(tracks[7..<15])),
    ]

    static let playlists: [Playlist] = [
        playlist(id: 3_001, title: "Made for Late Nights", user: currentUser, isAlbum: false, tracks: Array(tracks[0..<10])),
        playlist(id: 3_002, title: "Fresh Finds", user: currentUser, isAlbum: false, tracks: Array(tracks[3..<13])),
        playlist(id: 3_003, title: "Quiet Energy", user: currentUser, isAlbum: false, tracks: Array(tracks[6..<16])),
        playlist(id: 3_004, title: "Reposted Gems", user: currentUser, isAlbum: false, tracks: Array(tracks[1..<11])),
        playlist(id: 3_005, title: "SoundCloud Selects", user: currentUser, isAlbum: false, tracks: Array(tracks[8..<18])),
        playlist(id: 3_006, title: "Sunday Headphones", user: currentUser, isAlbum: false, tracks: Array(tracks[2..<12])),
    ]

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
            FeedActivity(kind: .playlistRepost, createdAt: date.addingTimeInterval(-60), actor: artists[6], uuid: "hero-playlist", caption: nil, track: nil, playlist: playlists[0]),
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
        decode(User.self, from: """
        {
          "id": \(id), "username": "\(name)", "permalink": "fixture-\(id)",
          "permalink_url": "https://soundcloud.com/fixture-\(id)",
          "full_name": "\(name)", "description": "Independent music from the SoundCloud community.",
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
          "description": "A carefully selected set with SoundCloud character and room to breathe.",
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
        return String(data: try! encoder.encode(value), encoding: .utf8)!
    }
}
#endif
