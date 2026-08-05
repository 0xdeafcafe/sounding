import Foundation

@MainActor
private enum TrackActionsClient {
    static let baseURL = "https://api-v2.soundcloud.com"
    static let session = URLSession.shared

    static let decoder: JSONDecoder = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(formatter)
        return decoder
    }()

    static let userAgent: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(v.majorVersion)_\(v.minorVersion)"
        let shortVersion = "\(v.majorVersion).\(v.minorVersion)"
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(osVersion) like Mac OS X)"
            + " AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(shortVersion) Mobile/15E148 Safari/604.1"
    }()

    static func buildURL(_ path: String, queryItems: [URLQueryItem] = []) -> URL? {
        var components = URLComponents(string: "\(baseURL)/\(path)")
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        return components?.url.map(SoundCloudAPI.strippingCredentials(from:))
    }

    static func authorizedRequest(_ url: URL, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.addValue("https://soundcloud.com", forHTTPHeaderField: "Origin")
        request.addValue("https://soundcloud.com/", forHTTPHeaderField: "Referer")
        if let token = SoundCloudAPI.credentials?.accessToken {
            request.addValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try SoundCloudAPI.shared.enforceTrafficSafety()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.networkError(NSError(domain: "TrackActionsClient", code: 0))
        }
        if SoundCloudAPI.isBotChallenge(response: http, data: data) {
            let until = SoundCloudAPI.shared.recordTrafficBlock(statusCode: http.statusCode, response: http)
            throw APIError.temporarilyBlocked(until: until, statusCode: http.statusCode)
        }
        if http.statusCode == 403 || http.statusCode == 429 {
            let until = SoundCloudAPI.shared.recordTrafficBlock(statusCode: http.statusCode, response: http)
            throw APIError.temporarilyBlocked(until: until, statusCode: http.statusCode)
        }
        return (data, http)
    }

    static func get<T: Decodable>(_ url: URL, allowRefresh: Bool = true) async throws -> T {
        let (data, http) = try await send(authorizedRequest(url))
        switch http.statusCode {
        case 200..<300:
            do { return try decoder.decode(T.self, from: data) }
            catch { throw APIError.decodingError(error) }
        case 401:
            if allowRefresh, await SoundCloudAPI.credentials?.refreshAccessToken() == true {
                return try await get(url, allowRefresh: false)
            }
            await SoundCloudAPI.credentials?.handleUnauthorized()
            throw APIError.unauthorized
        case 404:
            throw APIError.notFound
        default:
            throw APIError.serverError(http.statusCode)
        }
    }
}

struct PlaylistSummary: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let artworkURL: URL?
    let trackCount: Int
    let permalinkURL: URL?
    let isAlbum: Bool

    enum CodingKeys: String, CodingKey {
        case id, title
        case artworkURL = "artwork_url"
        case trackCount = "track_count"
        case permalinkURL = "permalink_url"
        case isAlbum = "is_album"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if let numeric = try? container.decode(Int.self, forKey: .id) {
            id = String(numeric)
        } else {
            id = try container.decode(String.self, forKey: .id)
        }
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        artworkURL = (try? container.decodeIfPresent(URL.self, forKey: .artworkURL)) ?? nil
        trackCount = ((try? container.decodeIfPresent(Int.self, forKey: .trackCount)) ?? nil) ?? 0
        permalinkURL = (try? container.decodeIfPresent(URL.self, forKey: .permalinkURL)) ?? nil
        isAlbum = ((try? container.decodeIfPresent(Bool.self, forKey: .isAlbum)) ?? nil) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Int(id) ?? 0, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(artworkURL, forKey: .artworkURL)
        try container.encode(trackCount, forKey: .trackCount)
        try container.encodeIfPresent(permalinkURL, forKey: .permalinkURL)
        try container.encode(isAlbum, forKey: .isAlbum)
    }
}

extension SoundCloudAPI {

    func getRelatedTracks(trackId: String, limit: Int = 20) async throws -> Page<Track> {
        guard let url = TrackActionsClient.buildURL("tracks/\(trackId)/related", queryItems: [
            URLQueryItem(name: "limit", value: String(limit))
        ]) else {
            throw APIError.invalidURL
        }
        return try await TrackActionsClient.get(url)
    }

    func getTrackAbout(trackId: String) async throws -> TrackAbout {
        guard let url = TrackActionsClient.buildURL("tracks/\(trackId)") else {
            throw APIError.invalidURL
        }
        return try await TrackActionsClient.get(url)
    }

    func getPlaylistsContaining(trackId: String, limit: Int = 20) async throws -> Page<PlaylistSummary> {
        guard let url = TrackActionsClient.buildURL("tracks/\(trackId)/playlists", queryItems: [
            URLQueryItem(name: "limit", value: String(limit))
        ]) else {
            throw APIError.invalidURL
        }
        return try await TrackActionsClient.get(url)
    }

    func getMyPlaylists(limit: Int = 50) async throws -> Page<PlaylistSummary> {
        guard let user = await SoundCloudAPI.credentials?.waitForCurrentUser() else {
            throw APIError.unauthorized
        }
        guard let url = TrackActionsClient.buildURL("users/\(user.id)/playlists", queryItems: [
            URLQueryItem(name: "limit", value: String(limit))
        ]) else {
            throw APIError.invalidURL
        }
        return try await TrackActionsClient.get(url)
    }

    func addTrack(_ trackId: String, toPlaylist playlistId: String) async throws {
        guard let getURL = TrackActionsClient.buildURL("playlists/\(playlistId)") else {
            throw APIError.invalidURL
        }
        let existing: PlaylistTrackIDs = try await TrackActionsClient.get(getURL)

        guard !existing.trackIDs.contains(trackId) else { return }

        guard let patchURL = TrackActionsClient.buildURL("playlists/\(playlistId)") else {
            throw APIError.invalidURL
        }
        var request = TrackActionsClient.authorizedRequest(patchURL, method: "PATCH")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let newTrackIDs = existing.trackIDs + [trackId]
        let body: [String: Any] = [
            "tracks": newTrackIDs.compactMap { Int($0) }.map { ["id": $0] }
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, http) = try await TrackActionsClient.send(request)
        switch http.statusCode {
        case 200..<300:
            return
        case 401:
            throw APIError.unauthorized
        case 404:
            throw APIError.notFound
        default:
            throw APIError.serverError(http.statusCode)
        }
    }

    func setPlaylistSharing(_ sharing: String, playlistId: String) async throws -> Playlist {
        guard sharing == "public" || sharing == "private",
              let url = TrackActionsClient.buildURL("playlists/\(playlistId)") else {
            throw APIError.invalidURL
        }
        var request = TrackActionsClient.authorizedRequest(url, method: "PUT")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "playlist": ["sharing": sharing]
        ])

        let (data, http) = try await TrackActionsClient.send(request)
        switch http.statusCode {
        case 200..<300:
            do { return try TrackActionsClient.decoder.decode(Playlist.self, from: data) }
            catch { throw APIError.decodingError(error) }
        case 401: throw APIError.unauthorized
        case 404: throw APIError.notFound
        default: throw APIError.serverError(http.statusCode)
        }
    }
}

extension Track {

    var shareText: String {
        "\(title) by \(user.displayName)\n\(permalinkURL.absoluteString)"
    }
}
