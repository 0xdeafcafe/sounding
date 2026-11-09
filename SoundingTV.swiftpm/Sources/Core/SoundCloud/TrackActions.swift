import Foundation

@MainActor
private enum TrackActionsClient {
    static let baseURL = "https://api-v2.soundcloud.com"

    static let decoder: JSONDecoder = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(formatter)
        return decoder
    }()

    static func buildURL(_ path: String, queryItems: [URLQueryItem] = []) -> URL? {
        var components = URLComponents(string: "\(baseURL)/\(path)")
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        return components?.url.map(SoundCloudAPI.strippingCredentials(from:))
    }

    static func authorizedRequest(_ url: URL, method: String = "GET") -> URLRequest {
        SoundCloudAPI.shared.authorizedRequest(url, method: method)
    }

    static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if let url = request.url {
            try await SoundCloudAPI.shared.admitAuthenticatedRequest(url, method: request.httpMethod ?? "GET")
        }
        let (data, http) = try await SoundCloudGateway.shared.data(
            for: request,
            context: .init(lane: .metadata, coalesces: request.httpMethod == "GET")
        )
        if SoundCloudAPI.isBotChallenge(response: http, data: data) {
            try SoundCloudAPI.shared.enforceTrafficSafety()
        }
        if http.statusCode == 403 { throw APIError.forbidden }
        if http.statusCode == 429 { throw APIError.rateLimited(resetAt: SoundCloudAPI.rateLimitResetDate(from: data)) }
        return (data, http)
    }

    static func get<T: Decodable>(_ url: URL, allowRefresh: Bool = true) async throws -> T {
        #if DEBUG
        if SoundCloudRequestEnvironment.debugCaller == nil, SoundCloudRequestLedger.shared.isEnabled {
            return try await SoundCloudRequestEnvironment.$debugCaller.withValue(SoundCloudRequestLedger.caller()) {
                try await get(url, allowRefresh: allowRefresh)
            }
        }
        #endif
        try await SoundCloudAPI.shared.admitAuthenticatedRequest(url)
        let sentToken = SoundCloudAPI.credentials?.accessToken
        let (data, http) = try await send(authorizedRequest(url))
        switch http.statusCode {
        case 200..<300:
            do { return try decoder.decode(T.self, from: data) }
            catch { throw APIError.decodingError(error) }
        case 401:
            if allowRefresh, await SoundCloudAPI.shared.refreshCredentialsAfterUnauthorized(sentWith: sentToken) {
                return try await get(url, allowRefresh: false)
            }
            throw await SoundCloudAPI.unauthorizedError()
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
        try await addTracks([trackId], toPlaylist: playlistId)
    }

    func addTracks(_ trackIds: [String], toPlaylist playlistId: String) async throws {
        guard let getURL = TrackActionsClient.buildURL("playlists/\(playlistId)") else {
            throw APIError.invalidURL
        }
        let existing: PlaylistTrackIDs = try await TrackActionsClient.get(getURL)

        var seen = Set(existing.trackIDs)
        let additions = trackIds.filter { seen.insert($0).inserted }
        guard !additions.isEmpty else { return }

        guard let patchURL = TrackActionsClient.buildURL("playlists/\(playlistId)") else {
            throw APIError.invalidURL
        }
        var request = TrackActionsClient.authorizedRequest(patchURL, method: "PATCH")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let newTrackIDs = existing.trackIDs + additions
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

extension SoundCloudAPI {
    func createPlaylist(title: String, description: String? = nil, sharing: String = "private", trackIds: [String]) async throws -> PlaylistSummary {
        guard sharing == "public" || sharing == "private",
              let url = TrackActionsClient.buildURL("playlists") else {
            throw APIError.invalidURL
        }
        var request = TrackActionsClient.authorizedRequest(url, method: "POST")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        var playlist: [String: Any] = [
            "title": title,
            "sharing": sharing,
            "tracks": trackIds.compactMap { Int($0) }.map { ["id": $0] },
        ]
        if let description, !description.isEmpty { playlist["description"] = description }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["playlist": playlist])

        let (data, http) = try await TrackActionsClient.send(request)
        switch http.statusCode {
        case 200..<300:
            do { return try TrackActionsClient.decoder.decode(PlaylistSummary.self, from: data) }
            catch { throw APIError.decodingError(error) }
        case 401: throw APIError.unauthorized
        case 404: throw APIError.notFound
        default: throw APIError.serverError(http.statusCode)
        }
    }
}

extension SoundCloudAPI {
    func updatePlaylist(
        id playlistId: String,
        title: String? = nil,
        description: String? = nil,
        sharing: String? = nil,
        trackIDs: [String]? = nil
    ) async throws -> Playlist? {
        if let sharing, sharing != "public", sharing != "private" { throw APIError.invalidURL }
        guard let url = TrackActionsClient.buildURL("playlists/\(playlistId)") else {
            throw APIError.invalidURL
        }
        var fields: [String: Any] = [:]
        if let title { fields["title"] = title }
        if let description { fields["description"] = description }
        if let sharing { fields["sharing"] = sharing }
        if let trackIDs { fields["tracks"] = trackIDs.compactMap { Int($0) }.map { ["id": $0] } }
        guard !fields.isEmpty else { return nil }
        var request = TrackActionsClient.authorizedRequest(url, method: "PUT")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["playlist": fields])

        let (data, http) = try await TrackActionsClient.send(request)
        switch http.statusCode {
        case 200..<300: return try? TrackActionsClient.decoder.decode(Playlist.self, from: data)
        case 401: throw APIError.unauthorized
        case 404: throw APIError.notFound
        default: throw APIError.serverError(http.statusCode)
        }
    }

    func deletePlaylist(id playlistId: String) async throws {
        guard let url = TrackActionsClient.buildURL("playlists/\(playlistId)") else {
            throw APIError.invalidURL
        }
        let request = TrackActionsClient.authorizedRequest(url, method: "DELETE")
        let (_, http) = try await TrackActionsClient.send(request)
        switch http.statusCode {
        case 200..<300, 404: return
        case 401: throw APIError.unauthorized
        default: throw APIError.serverError(http.statusCode)
        }
    }
}

@MainActor
enum PlaylistCreation {
    static func create(title: String, description: String?, isPrivate: Bool, trackIds: [String] = []) async throws -> Playlist {
        guard let owner = await SoundCloudAPI.credentials?.waitForCurrentUser() else {
            throw APIError.unauthorized
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sharing = isPrivate ? "private" : "public"
        let hook = SoundCloudAPI.libraryActionHook
        let placeholder = Playlist.local(
            id: String(-Int(Date().timeIntervalSince1970)),
            title: trimmedTitle,
            description: trimmedDescription,
            sharing: sharing,
            trackCount: trackIds.count,
            owner: owner
        )
        let pendingToken = placeholder.flatMap { hook?.begin(.createPlaylist($0)) }
        let summary: PlaylistSummary
        do {
            summary = try await SoundCloudAPI.shared.createPlaylist(
                title: trimmedTitle,
                description: trimmedDescription,
                sharing: sharing,
                trackIds: trackIds
            )
        } catch {
            if let pendingToken { hook?.finish(pendingToken, succeeded: false) }
            throw error
        }
        if let pendingToken { hook?.finish(pendingToken, succeeded: false) }
        let created = (try? await SoundCloudAPI.shared.getPlaylist(id: summary.id))
            ?? Playlist.local(
                id: summary.id,
                title: summary.title,
                description: trimmedDescription,
                sharing: sharing,
                trackCount: summary.trackCount,
                owner: owner,
                permalinkURL: summary.permalinkURL
            )
        guard let created else { throw APIError.notFound }
        if let token = hook?.begin(.createPlaylist(created)) {
            hook?.finish(token, succeeded: true)
        }
        return created
    }
}

extension PlaylistSummary {
    init(_ playlist: Playlist) {
        id = playlist.id
        title = playlist.title
        artworkURL = playlist.artworkURL
        trackCount = playlist.trackCount
        permalinkURL = playlist.permalinkURL
        isAlbum = playlist.isAlbum
    }
}

@MainActor
enum PlaylistWriter {
    static func myPlaylists() async throws -> [PlaylistSummary] {
        #if DEBUG
        if fixtureSeed != nil {
            try await Task.sleep(for: .milliseconds(250))
            return fixturePlaylists
        }
        #endif
        return try await SoundCloudAPI.shared.getMyPlaylists().collection
    }

    static func add(_ trackId: String, to playlist: PlaylistSummary) async throws {
        #if DEBUG
        if fixtureSeed != nil {
            try await fakeWrite()
            return
        }
        #endif
        try await SoundCloudAPI.shared.addTrack(trackId, toPlaylist: playlist.id)
    }

    static func create(title: String, containing trackId: String) async throws -> PlaylistSummary {
        #if DEBUG
        if fixtureSeed != nil {
            try await fakeWrite()
            let made = fixturePlaylist(id: 9_000 + fixtureCreated.count, title: title, count: 1)
            fixtureCreated.insert(made, at: 0)
            return made
        }
        #endif
        return try await SoundCloudAPI.shared.createPlaylist(title: title, trackIds: [trackId])
    }

    #if DEBUG
    static var fixtureSeed: [(id: Int, title: String, count: Int)]?
    private static var fixtureCreated: [PlaylistSummary] = []

    private static var fixturePlaylists: [PlaylistSummary] {
        fixtureCreated + (fixtureSeed ?? []).map { fixturePlaylist(id: $0.id, title: $0.title, count: $0.count) }
    }

    private static func fixturePlaylist(id: Int, title: String, count: Int) -> PlaylistSummary {
        let json = try? JSONSerialization.data(withJSONObject: ["id": id, "title": title, "track_count": count])
        return try! JSONDecoder().decode(PlaylistSummary.self, from: json ?? Data())
    }

    private static func fakeWrite() async throws {
        try await Task.sleep(for: .milliseconds(700))
        if ProcessInfo.processInfo.environment["SOUNDING_TV_PLAYLIST_WRITE_FAIL"] == "1" {
            throw APIError.serverError(500)
        }
    }
    #endif
}

extension Playlist {
    static func local(
        id: String,
        title: String,
        description: String?,
        sharing: String,
        trackCount: Int,
        owner: User,
        permalinkURL: URL? = nil
    ) -> Playlist? {
        guard let numericID = Int(id),
              let ownerData = try? Playlist.localEncoder().encode(owner),
              let ownerJSON = try? JSONSerialization.jsonObject(with: ownerData),
              let createdData = try? Playlist.localEncoder().encode([Date()]),
              let createdJSON = (try? JSONSerialization.jsonObject(with: createdData)) as? [Any],
              let createdAt = createdJSON.first else { return nil }
        var json: [String: Any] = [
            "id": numericID,
            "title": title,
            "permalink_url": (permalinkURL ?? owner.permalinkURL).absoluteString,
            "track_count": trackCount,
            "created_at": createdAt,
            "sharing": sharing,
            "is_album": false,
            "user": ownerJSON,
            "tracks": [Any](),
        ]
        if let description, !description.isEmpty { json["description"] = description }
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return try? Playlist.localDecoder().decode(Playlist.self, from: data)
    }

    private static func localFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }

    private static func localEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .formatted(localFormatter())
        return encoder
    }

    private static func localDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(localFormatter())
        return decoder
    }
}
