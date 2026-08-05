import Foundation
import os

enum SoundCloudSessionRejection: Equatable, Sendable {
    case accountRejected
    case noRefreshCapability
    case refreshUnreachable
}

enum SoundCloudSessionHealth: Equatable, Sendable {
    case signedOut
    case unverified
    case healthy
    case rejected(SoundCloudSessionRejection)

    var needsSignIn: Bool {
        switch self {
        case .signedOut: return true
        case .rejected(.accountRejected), .rejected(.noRefreshCapability): return true
        case .rejected(.refreshUnreachable), .unverified, .healthy: return false
        }
    }

    var canRetry: Bool { self == .rejected(.refreshUnreachable) }

    var isRejected: Bool {
        if case .rejected = self { return true }
        return false
    }

    var canMakeAuthenticatedRequests: Bool {
        switch self {
        case .healthy, .unverified, .rejected(.refreshUnreachable): return true
        case .signedOut, .rejected(.accountRejected), .rejected(.noRefreshCapability): return false
        }
    }
}

enum SoundCloudTokenValidation: Equatable, Sendable {
    case valid
    case rejected
    case unavailable(String)
}

enum SoundCloudTrafficSafetyState: Equatable, Sendable {
    case ready
    case waiting(statusCode: Int, until: Date)
}

/// First-party account pages for settings that SoundCloud must own.
///
/// Keep security, identity, privacy, and billing mutations on SoundCloud's
/// website instead of reproducing undocumented web endpoints in the app.
enum SoundCloudAccountPages {
    static let account = URL(string: "https://soundcloud.com/settings")!
    static let subscriptions = URL(string: "https://soundcloud.com/you/subscriptions")!
    static let notifications = URL(string: "https://soundcloud.com/settings/notifications")!
    static let privacy = URL(string: "https://soundcloud.com/settings/privacy")!
    static let communications = URL(string: "https://soundcloud.com/settings/communications")!
    static let analytics = URL(string: "https://soundcloud.com/settings/analytics")!
    static let advertising = URL(string: "https://soundcloud.com/settings/advertising")!
}

@MainActor
protocol SoundCloudCredentialSourcing: AnyObject {
    var accessToken: String? { get }
    var currentUser: User? { get }
    func waitForCurrentUser() async -> User?
    func refreshAccessToken() async -> Bool
    func handleUnauthorized() async

    func noteAuthenticatedRequestSucceeded()
}

extension SoundCloudCredentialSourcing {
    func noteAuthenticatedRequestSucceeded() {}
}

@MainActor
final class SoundCloudAPI {
    static let shared = SoundCloudAPI()

    static var credentials: (any SoundCloudCredentialSourcing)?

    private var credentials: (any SoundCloudCredentialSourcing)? { Self.credentials }

    private let baseURL = "https://api-v2.soundcloud.com"
    private let session = URLSession.shared
    private let decoder: JSONDecoder
    private var serverPlayResetAt: Date?

    private enum TrafficSafetyDefaults {
        static let blockedUntil = "red.forbes.sounding.soundcloud.trafficBlockedUntil"
        static let blockedStatus = "red.forbes.sounding.soundcloud.trafficBlockedStatus"
    }

    private var trafficBlockedUntil: Date? {
        get {
            let value = UserDefaults.standard.double(forKey: TrafficSafetyDefaults.blockedUntil)
            return value > 0 ? Date(timeIntervalSince1970: value) : nil
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: TrafficSafetyDefaults.blockedUntil)
            } else {
                UserDefaults.standard.removeObject(forKey: TrafficSafetyDefaults.blockedUntil)
                UserDefaults.standard.removeObject(forKey: TrafficSafetyDefaults.blockedStatus)
            }
        }
    }

    private static let userAgent: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(v.majorVersion)_\(v.minorVersion)"
        let shortVersion = "\(v.majorVersion).\(v.minorVersion)"
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(osVersion) like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(shortVersion) Mobile/15E148 Safari/604.1"
    }()

    private var accessToken: String? {
        credentials?.accessToken
    }

    private init() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(formatter)
    }

    static let forbiddenQueryNames: Set<String> = ["oauth_token", "access_token", "refresh_token", "client_secret"]

    static func strippingCredentials(from url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return url }
        let cleaned = items.filter { !forbiddenQueryNames.contains($0.name.lowercased()) }
        guard cleaned.count != items.count else { return url }
        components.queryItems = cleaned.isEmpty ? nil : cleaned
        return components.url ?? url
    }

    private static let anonymousClientID = "sUn5toeW5d8MC2jOLpE2yAibTG7RRYsA"

    static func sanitized(_ url: URL, isAuthenticated: Bool) -> URL {
        let stripped = strippingCredentials(from: url)
        guard var components = URLComponents(url: stripped, resolvingAgainstBaseURL: false) else {
            return stripped
        }
        var items = components.queryItems ?? []
        let clientIDValue = isAuthenticated ? "" : anonymousClientID

        if let index = items.firstIndex(where: { $0.name.lowercased() == "client_id" }) {
            items[index] = URLQueryItem(name: "client_id", value: clientIDValue)
        } else if !isAuthenticated {
            items.append(URLQueryItem(name: "client_id", value: clientIDValue))
        }

        components.queryItems = items.isEmpty ? nil : items
        return components.url ?? stripped
    }

    func buildURL(_ path: String, queryItems: [URLQueryItem] = []) -> URL? {
        var components = URLComponents(string: "\(baseURL)/\(path)")
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        return components?.url.map { Self.sanitized($0, isAuthenticated: accessToken != nil) }
    }

    private func request<T: Decodable>(_ url: URL, allowRefresh: Bool = true) async throws -> T {
        try enforceTrafficSafety()
#if DEBUG
        if allowRefresh { Self.noteRequestForStats(url) }
        #endif
        let wasAuthenticated = accessToken != nil
        let (data, httpResponse) = try await rawGet(url)

        switch httpResponse.statusCode {
        case 200..<300:
            if wasAuthenticated { credentials?.noteAuthenticatedRequestSucceeded() }
            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                throw APIError.decodingError(error)
            }
        case 401:
            if allowRefresh, await credentials?.refreshAccessToken() == true {
                return try await request(url, allowRefresh: false)
            }
            await credentials?.handleUnauthorized()
            throw APIError.unauthorized
        case 404:
            throw APIError.notFound
        case 429:
            let resetAt = Self.rateLimitResetDate(from: data)
            serverPlayResetAt = resetAt ?? Date(timeIntervalSinceNow: 60 * 60)
            recordTrafficBlock(statusCode: 429, response: httpResponse, preferredUntil: resetAt)
            throw APIError.rateLimited(resetAt: resetAt)
        case 403:
            let until = recordTrafficBlock(statusCode: 403, response: httpResponse)
            throw APIError.temporarilyBlocked(until: until, statusCode: 403)
        default:
            throw APIError.serverError(httpResponse.statusCode)
        }
    }

    private func rawGet(_ url: URL, tokenOverride: String? = nil) async throws -> (Data, HTTPURLResponse) {
        try enforceTrafficSafety()
        let request = authorizedRequest(url, tokenOverride: tokenOverride)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.networkError(NSError(domain: "Invalid response", code: 0))
        }
        if Self.isBotChallenge(response: http, data: data) {
            let until = recordTrafficBlock(statusCode: http.statusCode, response: http)
            throw APIError.temporarilyBlocked(until: until, statusCode: http.statusCode)
        }
        if http.statusCode == 403 {
            recordTrafficBlock(statusCode: 403, response: http)
        } else if http.statusCode == 429 {
            recordTrafficBlock(statusCode: 429, response: http, preferredUntil: Self.rateLimitResetDate(from: data))
        }
        return (data, http)
    }

    /// SoundCloud/DataDome challenges and temporary blocks are a hard stop.
    /// The lock is persisted so relaunching cannot turn a block into an
    /// identity rotation or an aggressive retry loop.
    func enforceTrafficSafety(now: Date = Date()) throws {
        guard let until = trafficBlockedUntil else { return }
        if now < until {
            let status = UserDefaults.standard.integer(forKey: TrafficSafetyDefaults.blockedStatus)
            throw APIError.temporarilyBlocked(until: until, statusCode: status == 0 ? 403 : status)
        }
        trafficBlockedUntil = nil
        NotificationCenter.default.post(name: .soundCloudTrafficSafetyChanged, object: self)
    }

    func trafficSafetyState(now: Date = Date()) -> SoundCloudTrafficSafetyState {
        guard let until = trafficBlockedUntil, now < until else { return .ready }
        let status = UserDefaults.standard.integer(forKey: TrafficSafetyDefaults.blockedStatus)
        return .waiting(statusCode: status == 0 ? 403 : status, until: until)
    }

    @discardableResult
    func recordTrafficBlock(
        statusCode: Int,
        response: HTTPURLResponse,
        preferredUntil: Date? = nil,
        now: Date = Date()
    ) -> Date {
        let until = preferredUntil
            ?? Self.retryAfterDate(from: response, now: now)
            ?? now.addingTimeInterval(60 * 60)
        let existing = trafficBlockedUntil ?? now
        let effective = max(existing, until)
        UserDefaults.standard.set(effective.timeIntervalSince1970, forKey: TrafficSafetyDefaults.blockedUntil)
        UserDefaults.standard.set(statusCode, forKey: TrafficSafetyDefaults.blockedStatus)
        NotificationCenter.default.post(
            name: .soundCloudTrafficSafetyChanged,
            object: self,
            userInfo: [
                Self.trafficSafetyStatusKey: statusCode,
                Self.trafficSafetyUntilKey: effective,
            ]
        )
        Log.api.error("SoundCloud traffic stop engaged for HTTP \(statusCode); polling and retries are suspended until \(effective)")
        return effective
    }

    private static func retryAfterDate(from response: HTTPURLResponse, now: Date) -> Date? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return now.addingTimeInterval(max(0, seconds))
        }
        return Self.httpDateFormatter.date(from: value)
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    static func isBotChallenge(response: HTTPURLResponse, data: Data) -> Bool {
        if response.value(forHTTPHeaderField: "X-DataDome") != nil {
            return true
        }

        // A challenge may be served as HTTP 200 with an HTML interstitial.
        // Only inspect bounded HTML responses so ordinary JSON payloads that
        // happen to mention a vendor cannot trip the circuit breaker.
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased()
            ?? response.mimeType?.lowercased()
            ?? ""
        guard contentType.contains("text/html"), !data.isEmpty else { return false }
        let prefix = data.prefix(256 * 1024)
        guard let html = String(data: prefix, encoding: .utf8)?.lowercased() else { return false }
        return html.contains("datadome")
            || html.contains("captcha-delivery.com")
            || html.contains("geo.captcha-delivery.com")
            || html.contains("please enable javascript and disable any ad blocker")
    }

    func authorizedRequest(
        _ url: URL,
        method: String = "GET",
        tokenOverride: String? = nil
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.addValue("https://soundcloud.com", forHTTPHeaderField: "Origin")
        request.addValue("https://soundcloud.com/", forHTTPHeaderField: "Referer")
        if let token = tokenOverride ?? accessToken {
            request.addValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    func getCurrentUser() async throws -> User {
        guard let url = buildURL("me") else {
            throw APIError.invalidURL
        }
        return try await request(url)
    }

    func validateToken(_ token: String) async -> SoundCloudTokenValidation {
        guard let url = URL(string: "\(baseURL)/me") else {
            return .unavailable("SoundCloud's account endpoint could not be created.")
        }

        do {
            let (_, http) = try await rawGet(url, tokenOverride: token)
            switch http.statusCode {
            case 200..<300:
                return .valid
            case 401, 403:
                Log.api.error("[Auth] token probe rejected by SoundCloud (401)")
                return .rejected
            default:
                return .unavailable("SoundCloud returned HTTP \(http.statusCode).")
            }
        } catch {
            return .rejected
        }
    }

    func getUser(id: String) async throws -> User {
        guard let url = buildURL("users/\(id)") else {
            throw APIError.invalidURL
        }
        return try await request(url)
    }

    func getComments(trackId: String, limit: Int = 100) async throws -> Page<Comment> {
        guard let url = buildURL("tracks/\(trackId)/comments",
                                 queryItems: Self.commentsQueryItems(limit: limit)) else {
            throw APIError.invalidURL
        }
        return try await request(url)
    }

    static func commentsQueryItems(limit: Int) -> [URLQueryItem] {
        [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "threaded", value: "0"),
            URLQueryItem(name: "client_id", value: ""),
        ]
    }

    enum ResolvedItem {
        case track(Track)
        case playlist(Playlist)
        case user(User)
    }

    func resolve(url permalink: URL, allowRefresh: Bool = true) async throws -> ResolvedItem {
        guard let url = buildURL("resolve", queryItems: [
            URLQueryItem(name: "url", value: permalink.absoluteString)
        ]) else {
            throw APIError.invalidURL
        }

        let wasAuthenticated = accessToken != nil
        let (data, http) = try await rawGet(url)
        switch http.statusCode {
        case 200..<300:
            if wasAuthenticated { credentials?.noteAuthenticatedRequestSucceeded() }
        case 401:
            if allowRefresh, await credentials?.refreshAccessToken() == true {
                return try await resolve(url: permalink, allowRefresh: false)
            }
            await credentials?.handleUnauthorized()
            throw APIError.unauthorized
        case 404:
            throw APIError.notFound
        case 403:
            let until = trafficBlockedUntil ?? Date(timeIntervalSinceNow: 60 * 60)
            throw APIError.temporarilyBlocked(until: until, statusCode: 403)
        case 429:
            throw APIError.rateLimited(resetAt: trafficBlockedUntil)
        default:
            throw APIError.serverError(http.statusCode)
        }

        struct Kind: Decodable { let kind: String }
        let kind = (try? decoder.decode(Kind.self, from: data))?.kind

        switch kind {
        case "track":
            return .track(try decode(Track.self, from: data))
        case "playlist", "system-playlist":
            return .playlist(try decode(Playlist.self, from: data))
        case "user":
            return .user(try decode(User.self, from: data))
        default:
            throw APIError.notFound
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try decoder.decode(type, from: data) }
        catch { throw APIError.decodingError(error) }
    }

    func getTrack(id: String) async throws -> Track {
        guard let url = buildURL("tracks/\(id)") else {
            throw APIError.invalidURL
        }
        return try await request(url)
    }

    func getTracks(ids: [String]) async throws -> [Track] {
        guard let url = buildURL("tracks", queryItems: [
            URLQueryItem(name: "ids", value: ids.joined(separator: ","))
        ]) else {
            throw APIError.invalidURL
        }
        return try await request(url)
    }

    func getStreamURL(for track: Track, transcoding: Transcoding? = nil) async throws -> URL {
        guard let streamURL = transcoding?.url ?? track.streamURL else {
            throw APIError.noStreamURL
        }

        // Transcoding endpoints require either OAuth or the public web client
        // identifier. Search already adds the anonymous identifier, but this
        // second-stage stream request used to strip credentials without adding
        // it back, which made public tracks silently fail while signed out.
        let url = Self.sanitized(streamURL, isAuthenticated: accessToken != nil)

        struct StreamResponse: Codable {
            let url: String
        }

        try reservePlayRequest()
        let response: StreamResponse = try await request(url)

        guard let finalURL = URL(string: response.url) else {
            throw APIError.noStreamURL
        }

        return finalURL
    }

    private func reservePlayRequest(now: Date = Date()) throws {
        if let serverPlayResetAt, now < serverPlayResetAt {
            throw APIError.rateLimited(resetAt: serverPlayResetAt)
        }
        if let serverPlayResetAt, now >= serverPlayResetAt { self.serverPlayResetAt = nil }

        // Do not impose an artificial client-side quota. SoundCloud owns the
        // shared client budget; only a real 429 response may pause resolution.
    }

    private static func rateLimitResetDate(from data: Data) -> Date? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let errors = root["errors"] as? [[String: Any]] else { return nil }
        let raw = errors.lazy.compactMap { error -> String? in
            guard let meta = error["meta"] as? [String: Any] else { return nil }
            return meta["reset_time"] as? String
        }.first
        guard let raw else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss Z"
        return formatter.date(from: raw)
    }

    func searchTracks(query: String, limit: Int = 50) async throws -> Page<Track> {
        guard let url = buildURL("search/tracks", queryItems: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit))
        ]) else {
            throw APIError.invalidURL
        }
        return try await request(url)
    }

    func searchUsers(query: String, limit: Int = 20) async throws -> Page<User> {
        guard let url = buildURL("search/users", queryItems: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit))
        ]) else {
            throw APIError.invalidURL
        }
        return try await request(url)
    }

    func searchPlaylists(query: String, limit: Int = 20) async throws -> Page<Playlist> {
        guard let url = buildURL("search/playlists", queryItems: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit))
        ]) else {
            throw APIError.invalidURL
        }
        return try await request(url)
    }

    func getLikedTracks(limit: Int = 50) async throws -> Page<Like<Track>> {
        guard let user = await credentials?.waitForCurrentUser(),
              let url = buildURL("users/\(user.id)/track_likes", queryItems: [
                  URLQueryItem(name: "limit", value: String(limit))
              ]) else {
            throw APIError.invalidURL
        }
        return try await request(url)
    }

    func getLikesPage(from url: URL) async throws -> Page<Like<Track>> {
        try await request(Self.strippingCredentials(from: url))
    }

    var hasCredentials: Bool { accessToken != nil }

    #if DEBUG
    private static var requestStatsCount = 0

    private static func noteRequestForStats(_ url: URL) {
        guard ProcessInfo.processInfo.environment["SOUNDING_TV_API_STATS"] == "1" else { return }
        requestStatsCount += 1
        let elapsed = ProcessInfo.processInfo.systemUptime
        print(String(format: "[APIStats] #%d @%.3fs %@", requestStatsCount, elapsed, url.path))
    }
    #endif


    func getStream(limit: Int = 50) async throws -> Page<StreamItem> {
        guard let url = buildURL("stream", queryItems: [
            URLQueryItem(name: "limit", value: String(limit))
        ]) else {
            throw APIError.invalidURL
        }
        return try await request(url)
    }

    func getFeed(limit: Int = 20) async throws -> Page<FeedActivity> {
        guard let url = buildURL("stream", queryItems: [
            URLQueryItem(name: "limit", value: String(limit))
        ]) else {
            throw APIError.invalidURL
        }
        return try await request(url)
    }

    func getLibrary(limit: Int = 50) async throws -> Page<LibraryItem> {
        guard let url = buildURL("me/library/all", queryItems: [
            URLQueryItem(name: "limit", value: String(limit))
        ]) else {
            throw APIError.invalidURL
        }
        return try await request(url)
    }

    func getUserTracks(userId: String, limit: Int = 50) async throws -> Page<Track> {
        guard let url = buildURL("users/\(userId)/tracks", queryItems: [
            URLQueryItem(name: "limit", value: String(limit))
        ]) else {
            throw APIError.invalidURL
        }
        return try await request(url)
    }

    func getUserPlaylists(userId: String, limit: Int = 50) async throws -> Page<Playlist> {
        guard let url = buildURL("users/\(userId)/playlists", queryItems: [
            URLQueryItem(name: "limit", value: String(limit))
        ]) else {
            throw APIError.invalidURL
        }
        return try await request(url)
    }

    func getUserFollowings(userId: String, limit: Int = 50) async throws -> Page<User> {
        guard let url = buildURL("users/\(userId)/followings", queryItems: [
            URLQueryItem(name: "limit", value: String(limit))
        ]) else {
            throw APIError.invalidURL
        }
        return try await request(url)
    }

    func getUserFollowers(userId: String, limit: Int = 50) async throws -> Page<User> {
        guard let url = buildURL("users/\(userId)/followers", queryItems: [
            URLQueryItem(name: "limit", value: String(limit))
        ]) else {
            throw APIError.invalidURL
        }
        return try await request(url)
    }

    func isFollowing(userId: String) async throws -> Bool {
        guard let currentUser = credentials?.currentUser,
              let url = buildURL("users/\(currentUser.id)/followings/\(userId)") else {
            throw APIError.unauthorized
        }
        let (_, response) = try await rawGet(url)
        switch response.statusCode {
        case 200..<300: return true
        case 404: return false
        case 401: throw APIError.unauthorized
        default: throw APIError.serverError(response.statusCode)
        }
    }

    func setFollowing(_ following: Bool, userId: String) async throws {
        guard let currentUser = credentials?.currentUser,
              let url = buildURL("users/\(currentUser.id)/followings/\(userId)") else {
            throw APIError.unauthorized
        }
        try await performFollowingRequest(url: url, following: following, allowRefresh: true)
    }

    private func performFollowingRequest(url: URL, following: Bool, allowRefresh: Bool) async throws {
        try enforceTrafficSafety()
        let (data, response) = try await session.data(for: authorizedRequest(url, method: following ? "PUT" : "DELETE"))
        guard let http = response as? HTTPURLResponse else { throw APIError.serverError(0) }
        if Self.isBotChallenge(response: http, data: data) {
            let until = recordTrafficBlock(statusCode: http.statusCode, response: http)
            throw APIError.temporarilyBlocked(until: until, statusCode: http.statusCode)
        }
        if http.statusCode == 403 || http.statusCode == 429 {
            let until = recordTrafficBlock(statusCode: http.statusCode, response: http)
            throw APIError.temporarilyBlocked(until: until, statusCode: http.statusCode)
        }
        if http.statusCode == 401 {
            if allowRefresh, await credentials?.refreshAccessToken() == true {
                return try await performFollowingRequest(url: url, following: following, allowRefresh: false)
            }
            await credentials?.handleUnauthorized()
            throw APIError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else { throw APIError.serverError(http.statusCode) }
    }

    func getUserLikes(userId: String, limit: Int = 50) async throws -> Page<Like<Track>> {
        guard let url = buildURL("users/\(userId)/track_likes", queryItems: [
            URLQueryItem(name: "limit", value: String(limit))
        ]) else {
            throw APIError.invalidURL
        }
        return try await request(url)
    }

    func getLikedPlaylists(limit: Int = 50) async throws -> Page<Playlist> {
        guard let user = await credentials?.waitForCurrentUser(),
              let url = buildURL("users/\(user.id)/playlist_likes", queryItems: [
                  URLQueryItem(name: "limit", value: String(limit))
              ]) else {
            throw APIError.invalidURL
        }
        let page: Page<Like<Playlist>> = try await request(url)
        return page.map(\.item)
    }

    func getUserReposts(userId: String, limit: Int = 50) async throws -> Page<StreamItem> {
        guard let url = buildURL("stream/users/\(userId)/reposts", queryItems: [
            URLQueryItem(name: "limit", value: String(limit))
        ]) else {
            throw APIError.invalidURL
        }
        return try await request(url)
    }

    func getPlaylist(id: String) async throws -> Playlist {
        guard let url = buildURL("playlists/\(id)") else {
            throw APIError.invalidURL
        }
        return try await request(url)
    }

    func getPlaylistTracks(_ playlist: Playlist, ids: [String]) async throws -> [Track] {
        guard !ids.isEmpty else { return [] }

        var byID = Dictionary(
            playlist.loadedTracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )

        let missing = ids.filter { byID[$0] == nil }
        for batch in stride(from: 0, to: missing.count, by: PlaylistTrackCursor.batchSize) {
            let window = Array(missing[batch..<Swift.min(batch + PlaylistTrackCursor.batchSize, missing.count)])
            for track in try await fetchTracks(ids: window) {
                byID[track.id] = track
            }
        }

        return ids.compactMap { byID[$0] }
    }

    private func fetchTracks(ids: [String]) async throws -> [Track] {
        guard let url = buildURL("tracks", queryItems: [
            URLQueryItem(name: "ids", value: ids.joined(separator: ","))
        ]) else {
            throw APIError.invalidURL
        }
        let response: ResilientArray<Track> = try await request(url)
        return response.elements
    }

    func getMixedSelections(limit: Int? = nil, country: String? = nil) async throws -> Page<Selection> {
        var items: [URLQueryItem] = []
        if let limit { items.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let country { items.append(URLQueryItem(name: "country", value: country)) }
        guard let url = buildURL("mixed-selections", queryItems: items) else {
            throw APIError.invalidURL
        }
        return try await request(url)
    }

    func getChartSelections() async throws -> Page<Selection> {
        guard let url = buildURL("charts/selections") else {
            throw APIError.invalidURL
        }
        return try await request(url)
    }

    func getCharts(
        kind: ChartKind = .trending,
        genreURN: String = ChartGenre.allMusic,
        limit: Int = 20
    ) async throws -> Page<ChartEntry> {
        guard let url = buildURL("charts", queryItems: [
            URLQueryItem(name: "kind", value: kind.rawValue),
            URLQueryItem(name: "genre", value: genreURN),
            URLQueryItem(name: "limit", value: String(limit)),
        ]) else {
            throw APIError.invalidURL
        }
        return try await request(url)
    }

    func getRelatedTracks(trackID: String, limit: Int = 20) async throws -> Page<Track> {
        guard let url = buildURL("tracks/\(trackID)/related", queryItems: [
            URLQueryItem(name: "limit", value: String(limit))
        ]) else {
            throw APIError.invalidURL
        }
        return try await request(url)
    }

    func getPlayHistory(limit: Int = 25) async throws -> Page<PlayHistoryItem> {
        guard let url = buildURL("me/play-history/tracks", queryItems: [
            URLQueryItem(name: "limit", value: String(limit))
        ]) else {
            throw APIError.invalidURL
        }
        return try await request(url)
    }

    func getSystemPlaylist(urn: String) async throws -> SystemPlaylist {
        let encoded = urn.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? urn
        guard let url = buildURL("system-playlists/\(encoded)") else {
            throw APIError.invalidURL
        }
        return try await request(url)
    }

    func getSystemPlaylistTracks(_ playlist: SystemPlaylist, limit: Int = 50) async throws -> [Track] {
        let wanted = Array(playlist.trackIDs.prefix(max(0, limit)))
        guard !wanted.isEmpty else { return [] }

        var byID: [String: Track] = [:]
        for batch in stride(from: 0, to: wanted.count, by: PlaylistTrackCursor.batchSize) {
            let window = Array(wanted[batch..<Swift.min(batch + PlaylistTrackCursor.batchSize, wanted.count)])
            for track in try await fetchTracks(ids: window) {
                byID[track.id] = track
            }
        }
        return wanted.compactMap { byID[$0] }
    }

    func likeTrack(_ track: Track) async throws {
        try await setLike(track, liked: true)
    }

    func unlikeTrack(_ track: Track) async throws {
        try await setLike(track, liked: false)
    }

    func setTrackReposted(_ reposted: Bool, track: Track) async throws {
        let data = try await performSocialRequest(
            path: "reposts/tracks/\(track.urn)",
            method: reposted ? "POST" : "DELETE"
        )
        _ = data
    }

    func setPlaylistLiked(_ liked: Bool, playlist: Playlist) async throws {
        let data = try await performSocialRequest(
            path: "likes/playlists/\(playlist.urn)",
            method: liked ? "POST" : "DELETE"
        )
        _ = data
    }

    func setPlaylistReposted(_ reposted: Bool, playlist: Playlist) async throws {
        let data = try await performSocialRequest(
            path: "reposts/playlists/\(playlist.urn)",
            method: reposted ? "POST" : "DELETE"
        )
        _ = data
    }

    func postComment(trackId: String, body: String, timestampMillis: Int? = nil) async throws -> Comment {
        var comment: [String: Any] = ["body": body]
        if let timestampMillis { comment["timestamp"] = timestampMillis }
        let payload = try JSONSerialization.data(withJSONObject: ["comment": comment])
        let data = try await performSocialRequest(
            path: "tracks/soundcloud:tracks:\(trackId)/comments",
            method: "POST",
            body: payload
        )
        do { return try decoder.decode(Comment.self, from: data) }
        catch { throw APIError.decodingError(error) }
    }

    private func performSocialRequest(
        path: String,
        method: String,
        body: Data? = nil,
        allowRefresh: Bool = true
    ) async throws -> Data {
        try enforceTrafficSafety()
        guard let url = URL(string: "https://api.soundcloud.com/\(path)") else {
            throw APIError.invalidURL
        }
        var request = authorizedRequest(url, method: method)
        request.httpBody = body
        if body != nil {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.serverError(0) }
        if Self.isBotChallenge(response: http, data: data) {
            let until = recordTrafficBlock(statusCode: http.statusCode, response: http)
            throw APIError.temporarilyBlocked(until: until, statusCode: http.statusCode)
        }
        if http.statusCode == 429 {
            let until = recordTrafficBlock(statusCode: http.statusCode, response: http)
            throw APIError.temporarilyBlocked(until: until, statusCode: http.statusCode)
        }
        if http.statusCode == 401 {
            if allowRefresh, await credentials?.refreshAccessToken() == true {
                return try await performSocialRequest(
                    path: path, method: method, body: body, allowRefresh: false
                )
            }
            await credentials?.handleUnauthorized()
            throw APIError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else { throw APIError.serverError(http.statusCode) }
        credentials?.noteAuthenticatedRequestSucceeded()
        return data
    }

    private func setLike(_ track: Track, liked: Bool) async throws {
        guard let user = credentials?.currentUser,
              let url = buildURL("users/\(user.id)/track_likes/\(track.id)") else {
            throw APIError.invalidURL
        }

        try await performLikeRequest(url: url, track: track, liked: liked, allowRefresh: true)
    }

    private func performLikeRequest(url: URL, track: Track, liked: Bool, allowRefresh: Bool) async throws {
        try enforceTrafficSafety()
        let request = authorizedRequest(url, method: liked ? "PUT" : "DELETE")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.serverError(0)
        }
        if Self.isBotChallenge(response: httpResponse, data: data) {
            let until = recordTrafficBlock(statusCode: httpResponse.statusCode, response: httpResponse)
            throw APIError.temporarilyBlocked(until: until, statusCode: httpResponse.statusCode)
        }
        if httpResponse.statusCode == 403 || httpResponse.statusCode == 429 {
            let until = recordTrafficBlock(statusCode: httpResponse.statusCode, response: httpResponse)
            throw APIError.temporarilyBlocked(until: until, statusCode: httpResponse.statusCode)
        }
        if httpResponse.statusCode == 401 {
            if allowRefresh, await credentials?.refreshAccessToken() == true {
                return try await performLikeRequest(url: url, track: track, liked: liked, allowRefresh: false)
            }
            await credentials?.handleUnauthorized()
            throw APIError.unauthorized
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw APIError.serverError(httpResponse.statusCode)
        }

        NotificationCenter.default.post(
            name: .trackLikeChanged,
            object: nil,
            userInfo: [Self.likeNotificationTrackKey: track, Self.likeNotificationLikedKey: liked]
        )
    }

    func getNextPage<T: Decodable>(_ page: Page<T>) async throws -> Page<T> {
        guard let nextURL = page.nextHref else {
            throw APIError.notFound
        }

        return try await request(Self.strippingCredentials(from: nextURL))
    }
}

struct StreamItem: Codable, Sendable {
    let createdAt: Date
    let track: Track?
    let playlist: Playlist?

    enum CodingKeys: String, CodingKey {
        case createdAt = "created_at"
        case track, playlist
    }
}

struct LibraryItem: Codable {
    let createdAt: Date
    let track: Track?
    let playlist: Playlist?

    let systemPlaylist: SystemPlaylist?

    enum CodingKeys: String, CodingKey {
        case createdAt = "created_at"
        case track, playlist
        case systemPlaylist = "system_playlist"
    }
}

extension Notification.Name {

    static let sessionExpired = Notification.Name("sessionExpired")

    static let soundCloudAuthenticationChanged = Notification.Name("soundCloudAuthenticationChanged")

    static let trackLikeChanged = Notification.Name("trackLikeChanged")

    static let soundCloudTrafficSafetyChanged = Notification.Name("soundCloudTrafficSafetyChanged")
}

extension SoundCloudAPI {
    nonisolated static let likeNotificationTrackKey = "track"
    nonisolated static let likeNotificationLikedKey = "liked"
    nonisolated static let trafficSafetyStatusKey = "statusCode"
    nonisolated static let trafficSafetyUntilKey = "until"
}

// MARK: - Direct messages

/// SoundCloud still exposes conversations to its own clients, but does not
/// include them in the public API contract. Keep this model deliberately small
/// and tolerant so a harmless payload addition cannot take down the inbox.
struct SoundCloudMessageParticipant: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let username: String
    let permalink: String?
    let avatarURL: URL?

    var profileURL: URL? {
        if let permalink, !permalink.isEmpty {
            return URL(string: "https://soundcloud.com/\(permalink)")
        }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case id, username, permalink
        case avatarURL = "avatar_url"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let string = try? values.decode(String.self, forKey: .id) {
            id = string
        } else if let integer = try? values.decode(Int64.self, forKey: .id) {
            id = String(integer)
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.id,
                .init(codingPath: decoder.codingPath, debugDescription: "Message participant has no id")
            )
        }
        username = (try? values.decode(String.self, forKey: .username)) ?? "SoundCloud user"
        permalink = try? values.decodeIfPresent(String.self, forKey: .permalink)
        avatarURL = try? values.decodeIfPresent(URL.self, forKey: .avatarURL)
    }
}

struct SoundCloudDirectMessage: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let body: String
    let createdAt: Date
    let sender: SoundCloudMessageParticipant?

    enum CodingKeys: String, CodingKey {
        case id, body, sender, user
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let string = try? values.decode(String.self, forKey: .id) {
            id = string
        } else if let integer = try? values.decode(Int64.self, forKey: .id) {
            id = String(integer)
        } else {
            id = UUID().uuidString
        }
        body = (try? values.decode(String.self, forKey: .body)) ?? ""
        sender = (try? values.decodeIfPresent(SoundCloudMessageParticipant.self, forKey: .sender))
            ?? (try? values.decodeIfPresent(SoundCloudMessageParticipant.self, forKey: .user))
        createdAt = Self.decodeDate(values, key: .createdAt) ?? .distantPast
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(body, forKey: .body)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encodeIfPresent(sender, forKey: .sender)
    }

    private static func decodeDate(
        _ values: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Date? {
        if let date = try? values.decode(Date.self, forKey: key) { return date }
        guard let raw = try? values.decode(String.self, forKey: key) else { return nil }
        return ISO8601DateFormatter().date(from: raw)
            ?? ISO8601DateFormatter.withFractionalSeconds.date(from: raw)
    }
}

private extension ISO8601DateFormatter {
    nonisolated(unsafe) static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

struct SoundCloudConversation: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let participants: [SoundCloudMessageParticipant]
    let messages: [SoundCloudDirectMessage]
    let unreadCount: Int
    let lastUpdatedAt: Date?

    var latestMessage: SoundCloudDirectMessage? {
        messages.max(by: { $0.createdAt < $1.createdAt })
    }

    enum CodingKeys: String, CodingKey {
        case id, participants, users, messages
        case unreadCount = "unread_count"
        case lastUpdatedAt = "last_updated_at"
        case lastMessage = "last_message"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let string = try? values.decode(String.self, forKey: .id) {
            id = string
        } else if let integer = try? values.decode(Int64.self, forKey: .id) {
            id = String(integer)
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.id,
                .init(codingPath: decoder.codingPath, debugDescription: "Conversation has no id")
            )
        }
        participants = (try? values.decode([SoundCloudMessageParticipant].self, forKey: .participants))
            ?? (try? values.decode([SoundCloudMessageParticipant].self, forKey: .users))
            ?? []
        var decoded = (try? values.decode([SoundCloudDirectMessage].self, forKey: .messages)) ?? []
        if decoded.isEmpty,
           let latest = try? values.decodeIfPresent(SoundCloudDirectMessage.self, forKey: .lastMessage) {
            decoded = [latest]
        }
        messages = decoded.sorted(by: { $0.createdAt < $1.createdAt })
        unreadCount = (try? values.decode(Int.self, forKey: .unreadCount)) ?? 0
        if let date = try? values.decodeIfPresent(Date.self, forKey: .lastUpdatedAt) {
            lastUpdatedAt = date
        } else if let raw = try? values.decodeIfPresent(String.self, forKey: .lastUpdatedAt) {
            let parsedDate: Date? = ISO8601DateFormatter().date(from: raw)
            lastUpdatedAt = parsedDate
        } else {
            lastUpdatedAt = messages.max(by: { $0.createdAt < $1.createdAt })?.createdAt
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(participants, forKey: .participants)
        try values.encode(messages, forKey: .messages)
        try values.encode(unreadCount, forKey: .unreadCount)
        try values.encodeIfPresent(lastUpdatedAt, forKey: .lastUpdatedAt)
    }
}

struct SoundCloudConversationPage: Decodable, Sendable {
    let collection: [SoundCloudConversation]
    let nextHref: URL?

    enum CodingKeys: String, CodingKey {
        case collection, conversations
        case nextHref = "next_href"
    }

    init(from decoder: Decoder) throws {
        if var list = try? decoder.unkeyedContainer() {
            var rows: [SoundCloudConversation] = []
            while !list.isAtEnd { rows.append(try list.decode(SoundCloudConversation.self)) }
            collection = rows
            nextHref = nil
            return
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        collection = (try? values.decode([SoundCloudConversation].self, forKey: .collection))
            ?? (try? values.decode([SoundCloudConversation].self, forKey: .conversations))
            ?? []
        nextHref = try? values.decodeIfPresent(URL.self, forKey: .nextHref)
    }
}

enum SoundCloudMessagingError: Error, LocalizedError, Sendable {
    case unavailable
    case emptyMessage

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "SoundCloud messaging is only available in the SoundCloud web inbox for this session."
        case .emptyMessage:
            return "Write a message before sending."
        }
    }
}

extension SoundCloudAPI {
    static let webInboxURL = URL(string: "https://soundcloud.com/messages")!

    func getConversations(limit: Int = 50) async throws -> SoundCloudConversationPage {
        guard accessToken != nil else { throw APIError.unauthorized }
        let candidates = messagingURLs(path: "me/conversations", query: [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "linked_partitioning", value: "1"),
        ])
        let data = try await messagingRequest(candidates: candidates, method: "GET")
        do { return try decoder.decode(SoundCloudConversationPage.self, from: data) }
        catch { throw APIError.decodingError(error) }
    }

    func getConversation(id: String) async throws -> SoundCloudConversation {
        guard accessToken != nil else { throw APIError.unauthorized }
        let data = try await messagingRequest(
            candidates: messagingURLs(path: "me/conversations/\(id)"),
            method: "GET"
        )
        if let conversation = try? decoder.decode(SoundCloudConversation.self, from: data) {
            return conversation
        }
        struct Envelope: Decodable { let conversation: SoundCloudConversation }
        do { return try decoder.decode(Envelope.self, from: data).conversation }
        catch { throw APIError.decodingError(error) }
    }

    @discardableResult
    func sendDirectMessage(
        _ body: String,
        to recipientID: String,
        conversationID: String? = nil
    ) async throws -> SoundCloudConversation? {
        let clean = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw SoundCloudMessagingError.emptyMessage }
        guard accessToken != nil else { throw APIError.unauthorized }

        let path = conversationID.map { "me/conversations/\($0)" } ?? "me/conversations"
        var form = [URLQueryItem(name: "message[body]", value: clean)]
        if conversationID == nil {
            form.append(URLQueryItem(name: "message[recipient_ids][]", value: recipientID))
        }
        var components = URLComponents()
        components.queryItems = form
        let payload = Data((components.percentEncodedQuery ?? "").utf8)
        let data = try await messagingRequest(
            candidates: messagingURLs(path: path),
            method: "POST",
            body: payload,
            contentType: "application/x-www-form-urlencoded; charset=utf-8"
        )
        guard !data.isEmpty else { return nil }
        return try? decoder.decode(SoundCloudConversation.self, from: data)
    }

    private func messagingURLs(path: String, query: [URLQueryItem] = []) -> [URL] {
        ["https://api.soundcloud.com", baseURL].compactMap { base in
            var components = URLComponents(string: "\(base)/\(path)")
            components?.queryItems = query.isEmpty ? nil : query
            return components?.url
        }
    }

    private func messagingRequest(
        candidates: [URL],
        method: String,
        body: Data? = nil,
        contentType: String? = nil,
        allowRefresh: Bool = true
    ) async throws -> Data {
        try enforceTrafficSafety()
        for (index, url) in candidates.enumerated() {
            var outgoing = authorizedRequest(url, method: method)
            outgoing.httpBody = body
            if let contentType { outgoing.setValue(contentType, forHTTPHeaderField: "Content-Type") }
            let (data, response) = try await session.data(for: outgoing)
            guard let http = response as? HTTPURLResponse else { throw APIError.serverError(0) }
            if Self.isBotChallenge(response: http, data: data) {
                let until = recordTrafficBlock(statusCode: http.statusCode, response: http)
                throw APIError.temporarilyBlocked(until: until, statusCode: http.statusCode)
            }
            if http.statusCode == 403 || http.statusCode == 429 {
                let until = recordTrafficBlock(statusCode: http.statusCode, response: http)
                throw APIError.temporarilyBlocked(until: until, statusCode: http.statusCode)
            }
            switch http.statusCode {
            case 200..<300:
                credentials?.noteAuthenticatedRequestSucceeded()
                return data
            case 401:
                if allowRefresh, await credentials?.refreshAccessToken() == true {
                    return try await messagingRequest(
                        candidates: candidates,
                        method: method,
                        body: body,
                        contentType: contentType,
                        allowRefresh: false
                    )
                }
                await credentials?.handleUnauthorized()
                throw APIError.unauthorized
            case 404, 405, 410:
                if index < candidates.count - 1 { continue }
                throw SoundCloudMessagingError.unavailable
            case 429:
                throw APIError.rateLimited(resetAt: Self.rateLimitResetDate(from: data))
            default:
                throw APIError.serverError(http.statusCode)
            }
        }
        throw SoundCloudMessagingError.unavailable
    }
}
