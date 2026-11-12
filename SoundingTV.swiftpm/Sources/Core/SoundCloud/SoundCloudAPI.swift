import Foundation
import Combine
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

enum SoundCloudUnauthorizedDisposition: Equatable, Sendable {
    case credentialRejected
    case endpointRejected
    case temporarilyUnavailable
}

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
    func handleUnauthorized() async -> SoundCloudUnauthorizedDisposition

    func noteAuthenticatedRequestSucceeded()

    var holdsAuthenticatedRequests: Bool { get }
    func waitForRenewal() async
}

extension SoundCloudCredentialSourcing {
    func noteAuthenticatedRequestSucceeded() {}
    var holdsAuthenticatedRequests: Bool { false }
    func waitForRenewal() async {}
}

enum SoundCloudAuthHold: Error, Equatable, Sendable {
    case sessionNeedsRecovery
}

enum SoundCloudUnauthorizedRetryPolicy {
    enum Decision: Equatable, Sendable {
        case retryWithCurrentPair
        case recover
    }

    static func decision(sentToken: String?, currentToken: String?) -> Decision {
        if let currentToken, currentToken != sentToken { return .retryWithCurrentPair }
        return .recover
    }

    static func shouldRetryAfterRecovery(recovered: Bool, sentToken: String?, currentToken: String?) -> Bool {
        guard recovered, let currentToken else { return false }
        return currentToken != sentToken
    }
}

@MainActor
final class SoundCloudCredentialRefreshBarrier {
    private var inFlight: Task<Bool, Never>?

    var isRefreshing: Bool { inFlight != nil }

    func waitForIdle() async {
        guard let inFlight else { return }
        _ = await inFlight.value
    }

    func refresh(using operation: @escaping @MainActor () async -> Bool) async -> Bool {
        if let inFlight { return await inFlight.value }

        let task = Task { @MainActor in await operation() }
        inFlight = task
        let succeeded = await task.value
        inFlight = nil
        return succeeded
    }
}

enum SoundCloudLibraryAction: Sendable {
    case trackLike(Track, Bool)
    case follow(userID: String, Bool)
    case playlistLike(Playlist, Bool)
    case trackRepost(Track, Bool)
    case playlistRepost(Playlist, Bool)
    case createPlaylist(Playlist)
    case updatePlaylist(Playlist, trackIDs: [String]?)
    case deletePlaylist(Playlist)
}

@MainActor
protocol SoundCloudLibraryActionHook: AnyObject {
    func begin(_ action: SoundCloudLibraryAction) -> UUID
    func finish(_ id: UUID, succeeded: Bool)
}

struct SoundCloudLikeChange {
    let track: Track
    let isLiked: Bool
    let revision: Int
}

@MainActor
final class SoundCloudAPI: ObservableObject {
    static let shared = SoundCloudAPI()

    static var credentials: (any SoundCloudCredentialSourcing)?
    static weak var libraryActionHook: (any SoundCloudLibraryActionHook)?

    private var credentials: (any SoundCloudCredentialSourcing)? { Self.credentials }

    private let baseURL = "https://api-v2.soundcloud.com"
    private let decoder: JSONDecoder
    private let credentialRefreshBarrier = SoundCloudCredentialRefreshBarrier()
    @Published private(set) var latestLikeChange: SoundCloudLikeChange?
    private var likeRevision = 0

    private static let userAgent: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "Sounding/\(version) (Apple; \(v.majorVersion).\(v.minorVersion).\(v.patchVersion))"
    }()

    private var accessToken: String? {
        credentials?.accessToken
    }

    static func unauthorizedError() async -> APIError {
        switch await credentials?.handleUnauthorized() {
        case .endpointRejected:
            return .forbidden
        case .credentialRejected, .temporarilyUnavailable, nil:
            return .unauthorized
        }
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

    private func request<T: Decodable>(
        _ url: URL,
        allowRefresh: Bool = true,
        lane: SoundCloudRequestLane? = nil
    ) async throws -> T {
        #if DEBUG
        if SoundCloudRequestEnvironment.debugCaller == nil, SoundCloudRequestLedger.shared.isEnabled {
            return try await SoundCloudRequestEnvironment.$debugCaller.withValue(SoundCloudRequestLedger.caller()) {
                try await request(url, allowRefresh: allowRefresh, lane: lane)
            }
        }
        #endif
        try await admitAuthenticatedRequest(url)
        let sentToken = accessToken
        let wasAuthenticated = sentToken != nil
        let (data, httpResponse) = try await rawGet(url, lane: lane)

        switch httpResponse.statusCode {
        case 200..<300:
            if wasAuthenticated { credentials?.noteAuthenticatedRequestSucceeded() }
            do {
                return try await Self.decodeOffMain(T.self, from: data, using: decoder).value
            } catch {
                throw APIError.decodingError(error)
            }
        case 401:
            if allowRefresh, await refreshCredentialsAfterUnauthorized(sentWith: sentToken) {
                return try await request(url, allowRefresh: false, lane: lane)
            }
            throw await Self.unauthorizedError()
        case 404:
            throw APIError.notFound
        case 429:
            throw APIError.rateLimited(
                resetAt: SoundCloudGateway.shared.playbackResolutionPausedUntil
                    ?? SoundCloudGateway.shared.backgroundWorkPausedUntil
                    ?? Self.rateLimitResetDate(from: data)
            )
        case 403:
            throw APIError.forbidden
        default:
            throw APIError.serverError(httpResponse.statusCode)
        }
    }

    private func rawGet(
        _ url: URL,
        tokenOverride: String? = nil,
        lane: SoundCloudRequestLane? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        #if DEBUG
        if SoundCloudRequestEnvironment.debugCaller == nil, SoundCloudRequestLedger.shared.isEnabled {
            return try await SoundCloudRequestEnvironment.$debugCaller.withValue(SoundCloudRequestLedger.caller()) {
                try await rawGet(url, tokenOverride: tokenOverride, lane: lane)
            }
        }
        #endif
        if tokenOverride == nil { try await admitAuthenticatedRequest(url) }
        let request = authorizedRequest(url, tokenOverride: tokenOverride)
        let (data, http) = try await SoundCloudGateway.shared.data(
            for: request,
            context: .current(lane: lane)
        )
        if Self.isBotChallenge(response: http, data: data) {
            try enforceTrafficSafety()
        }
        return (data, http)
    }

    func admitAuthenticatedRequest(_ url: URL, method: String = "GET") async throws {
        await credentialRefreshBarrier.waitForIdle()
        guard let credentials else { return }
        await credentials.waitForRenewal()
        guard credentials.holdsAuthenticatedRequests else { return }
        NetworkActivityLog.shared.record(NetworkRequestRecord(
            feature: NetworkActivityLog.feature ?? NetworkFeature.soundCloud(path: url.path, lane: SoundCloudRequestEnvironment.lane.rawValue),
            method: method,
            url: url,
            lane: SoundCloudRequestEnvironment.lane.rawValue,
            intent: SoundCloudRequestEnvironment.intent.rawValue,
            source: .held,
            error: SoundCloudAuthHold.sessionNeedsRecovery,
            detail: "held until the SoundCloud session recovers"
        ))
        throw APIError.unauthorized
    }

    func refreshCredentialsAfterUnauthorized(sentWith sentToken: String?) async -> Bool {
        guard let credentials else { return false }
        if SoundCloudUnauthorizedRetryPolicy.decision(sentToken: sentToken, currentToken: accessToken) == .retryWithCurrentPair {
            Log.auth.notice("401 for a pair that has since been replaced, retrying once with the current pair")
            return true
        }
        let recovered = await credentialRefreshBarrier.refresh {
            await credentials.refreshAccessToken()
        }
        return SoundCloudUnauthorizedRetryPolicy.shouldRetryAfterRecovery(
            recovered: recovered, sentToken: sentToken, currentToken: accessToken
        )
    }

    func enforceTrafficSafety(now: Date = Date()) throws {
        try SoundCloudGateway.shared.enforceTrafficSafety(now: now)
    }

    func trafficSafetyState(now: Date = Date()) -> SoundCloudTrafficSafetyState {
        SoundCloudGateway.shared.trafficSafetyState(now: now)
    }

    static func isBotChallenge(response: HTTPURLResponse, data: Data) -> Bool {
        SoundCloudGateway.isBotChallenge(response: response, data: data)
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
        if SoundCloudHostPolicy.mayReceiveOAuth(url), let token = tokenOverride ?? accessToken {
            request.addValue("OAuth \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    func getCurrentUser() async throws -> User {
        guard accessToken != nil else { throw APIError.unauthorized }
        guard let url = buildURL("me") else {
            throw APIError.invalidURL
        }
        return try await request(url)
    }

    func getCurrentUserResponse() async throws -> SoundCloudCurrentUserResponse {
        guard accessToken != nil else { throw APIError.unauthorized }
        guard let url = buildURL("me") else {
            throw APIError.invalidURL
        }
        return try await request(url)
    }

    func getOfficialSubscriptionCapture() async throws -> SoundCloudSubscriptionCapture {
        guard accessToken != nil else { throw APIError.unauthorized }
        guard let url = URL(string: "https://api.soundcloud.com/me") else {
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
            case 401:
                Log.api.error("[Auth] token probe rejected by SoundCloud (401)")
                return .rejected
            case 403, 429:
                if case .waiting(_, let until) = trafficSafetyState() {
                    return .unavailable(
                        "SoundCloud is temporarily limiting account checks until \(until.formatted(date: .abbreviated, time: .shortened))."
                    )
                }
                return .unavailable("SoundCloud temporarily refused the account check (HTTP \(http.statusCode)).")
            default:
                return .unavailable("SoundCloud returned HTTP \(http.statusCode).")
            }
        } catch let error as APIError {
            return .unavailable(error.localizedDescription)
        } catch {
            return .unavailable("Couldn’t reach SoundCloud to verify the account. \(error.localizedDescription)")
        }
    }

    func getUser(id: String) async throws -> User {
        guard !LocalTrackFile.isLocalTrackID(id) else { throw APIError.notFound }
        guard let url = buildURL("users/\(id)") else {
            throw APIError.invalidURL
        }
        return try await request(url)
    }

    func getComments(trackId: String, limit: Int = 100) async throws -> Page<Comment> {
        guard !LocalTrackFile.isLocalTrackID(trackId) else { throw APIError.notFound }
        guard let url = buildURL("tracks/\(trackId)/comments",
                                 queryItems: Self.commentsQueryItems(limit: limit)) else {
            throw APIError.invalidURL
        }
        return try await request(url)
    }

    static func commentsQueryItems(limit: Int) -> [URLQueryItem] {
        [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "threaded", value: "1"),
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

        try await admitAuthenticatedRequest(url)
        let sentToken = accessToken
        let wasAuthenticated = sentToken != nil
        let (data, http) = try await rawGet(url)
        switch http.statusCode {
        case 200..<300:
            if wasAuthenticated { credentials?.noteAuthenticatedRequestSucceeded() }
        case 401:
            if allowRefresh, await refreshCredentialsAfterUnauthorized(sentWith: sentToken) {
                return try await resolve(url: permalink, allowRefresh: false)
            }
            throw await Self.unauthorizedError()
        case 404:
            throw APIError.notFound
        case 403:
            throw APIError.forbidden
        case 429:
            throw APIError.rateLimited(resetAt: Self.rateLimitResetDate(from: data))
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

    private struct DecodedValue<Value>: @unchecked Sendable {
        let value: Value
    }

    @concurrent
    nonisolated private static func decodeOffMain<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        using decoder: JSONDecoder
    ) async throws -> DecodedValue<T> {
        DecodedValue(value: try decoder.decode(type, from: data))
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try decoder.decode(type, from: data) }
        catch { throw APIError.decodingError(error) }
    }

    func getTrack(id: String) async throws -> Track {
        guard !LocalTrackFile.isLocalTrackID(id) else { throw APIError.notFound }
        guard let url = buildURL("tracks/\(id)") else {
            throw APIError.invalidURL
        }
        return try await request(url)
    }

    func getTracks(ids: [String]) async throws -> [Track] {
        let ids = ids.filter { !LocalTrackFile.isLocalTrackID($0) }
        guard !ids.isEmpty else { return [] }

        var seen = Set<String>()
        let wanted = ids.filter { seen.insert($0).inserted }
        var byID: [String: Track] = [:]
        for batch in stride(from: 0, to: wanted.count, by: PlaylistTrackCursor.batchSize) {
            let end = Swift.min(batch + PlaylistTrackCursor.batchSize, wanted.count)
            for track in try await fetchTracks(ids: Array(wanted[batch..<end])) {
                byID[track.id] = track
            }
        }
        return wanted.compactMap { byID[$0] }
    }

    func getStreamURL(for track: Track, transcoding: Transcoding? = nil) async throws -> URL {
        guard let streamURL = transcoding?.url ?? track.streamURL else {
            throw APIError.noStreamURL
        }

        return try await getStreamURL(forTranscodingURL: streamURL)
    }

    func getStreamURL(forTranscodingURL streamURL: URL) async throws -> URL {

        let url = Self.sanitized(streamURL, isAuthenticated: accessToken != nil)

        struct StreamResponse: Codable {
            let url: String
        }

        let response: StreamResponse = try await request(url, lane: .streamResolution)

        guard let finalURL = URL(string: response.url) else {
            throw APIError.noStreamURL
        }

        try SoundCloudGateway.shared.admitMediaURL(finalURL)

        return finalURL
    }

    static func rateLimitResetDate(from data: Data) -> Date? {
        SoundCloudRateLimitPayload.resetDate(from: data)
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
        guard let user = await credentials?.waitForCurrentUser() else {
            throw APIError.unauthorized
        }
        guard let url = buildURL("users/\(user.id)/track_likes", queryItems: [
            URLQueryItem(name: "limit", value: String(limit))
        ]) else { throw APIError.invalidURL }
        return try await request(url)
    }

    func getLikesPage(from url: URL) async throws -> Page<Like<Track>> {
        try await request(Self.strippingCredentials(from: url))
    }

    func getPage<T: Decodable>(_ type: T.Type, from url: URL) async throws -> Page<T> {
        try await request(Self.strippingCredentials(from: url))
    }

    var hasCredentials: Bool { accessToken != nil }


    func getStream(limit: Int = 50) async throws -> Page<StreamItem> {
        guard let url = buildURL("stream", queryItems: [
            URLQueryItem(name: "limit", value: String(limit))
        ]) else {
            throw APIError.invalidURL
        }
        return try await request(url, lane: .feed)
    }

    func getFeed(limit: Int = 20) async throws -> Page<FeedActivity> {
        guard let url = buildURL("stream", queryItems: [
            URLQueryItem(name: "limit", value: String(limit))
        ]) else {
            throw APIError.invalidURL
        }
        return try await request(url, lane: .feed)
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

    func getUserTopTracks(userId: String, limit: Int = 10) async throws -> Page<Track> {
        guard let url = buildURL("users/\(userId)/toptracks", queryItems: [
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

    func getUserRelatedArtists(userId: String, limit: Int = 12) async throws -> Page<User> {
        guard let url = buildURL("users/\(userId)/relatedartists", queryItems: [
            URLQueryItem(name: "creators_only", value: "true"),
            URLQueryItem(name: "page_items", value: String(limit)),
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
        return try await request(url, lane: .followers)
    }

    func getTrackLikers(trackId: String, limit: Int = 100) async throws -> Page<TrackEngagedUser> {
        guard let url = buildURL("tracks/\(trackId)/likers", queryItems: [
            URLQueryItem(name: "limit", value: String(limit))
        ]) else {
            throw APIError.invalidURL
        }
        do {
            return try await request(url)
        } catch APIError.notFound {
            guard let fallback = buildURL("tracks/\(trackId)/favoriters", queryItems: [
                URLQueryItem(name: "limit", value: String(limit))
            ]) else {
                throw APIError.invalidURL
            }
            return try await request(fallback)
        }
    }

    func getTrackReposters(trackId: String, limit: Int = 100) async throws -> Page<TrackEngagedUser> {
        guard let url = buildURL("tracks/\(trackId)/reposters", queryItems: [
            URLQueryItem(name: "limit", value: String(limit))
        ]) else {
            throw APIError.invalidURL
        }
        return try await request(url)
    }

    func getPlaylistLikers(playlistId: String, limit: Int = 100) async throws -> Page<TrackEngagedUser> {
        guard let url = buildURL("playlists/\(playlistId)/likers", queryItems: [
            URLQueryItem(name: "limit", value: String(limit))
        ]) else {
            throw APIError.invalidURL
        }
        return try await request(url)
    }

    func getPlaylistReposters(playlistId: String, limit: Int = 100) async throws -> Page<TrackEngagedUser> {
        guard let url = buildURL("playlists/\(playlistId)/reposters", queryItems: [
            URLQueryItem(name: "limit", value: String(limit))
        ]) else {
            throw APIError.invalidURL
        }
        return try await request(url)
    }

    func getUserWebProfiles(userId: String) async throws -> [SoundCloudWebProfile] {
        guard let url = buildURL("users/soundcloud:users:\(userId)/web-profiles") else {
            throw APIError.invalidURL
        }
        let list: SoundCloudWebProfiles = try await request(url)
        return list.profiles
    }

    func isFollowing(userId: String, allowRefresh: Bool = true) async throws -> Bool {
        guard let currentUser = credentials?.currentUser,
              let url = buildURL("users/\(currentUser.id)/followings/\(userId)") else {
            throw APIError.unauthorized
        }
        try await admitAuthenticatedRequest(url)
        let sentToken = accessToken
        let (_, response) = try await rawGet(url)
        switch response.statusCode {
        case 200..<300: return true
        case 404: return false
        case 401:
            if allowRefresh, await refreshCredentialsAfterUnauthorized(sentWith: sentToken) {
                return try await isFollowing(userId: userId, allowRefresh: false)
            }
            throw await Self.unauthorizedError()
        default: throw APIError.serverError(response.statusCode)
        }
    }

    func setFollowing(_ following: Bool, userId: String) async throws {
        guard let currentUser = credentials?.currentUser,
              let url = buildURL("users/\(currentUser.id)/followings/\(userId)") else {
            throw APIError.unauthorized
        }
        try await tracked(.follow(userID: userId, following)) {
            try await performFollowingRequest(url: url, following: following, allowRefresh: true)
        }
    }

    private func tracked<T>(_ action: SoundCloudLibraryAction, _ body: () async throws -> T) async throws -> T {
        let token = Self.libraryActionHook?.begin(action)
        do {
            let value = try await body()
            if let token { Self.libraryActionHook?.finish(token, succeeded: true) }
            return value
        } catch {
            if let token { Self.libraryActionHook?.finish(token, succeeded: false) }
            throw error
        }
    }

    func getPlaylistLikes(limit: Int = 100) async throws -> Page<Like<Playlist>> {
        guard let user = await credentials?.waitForCurrentUser(),
              let url = buildURL("users/\(user.id)/playlist_likes", queryItems: [
                  URLQueryItem(name: "limit", value: String(limit))
              ]) else {
            throw APIError.invalidURL
        }
        return try await request(url)
    }

    private func performFollowingRequest(url: URL, following: Bool, allowRefresh: Bool) async throws {
        try await admitAuthenticatedRequest(url, method: following ? "PUT" : "DELETE")
        let sentToken = accessToken
        let (data, http) = try await SoundCloudGateway.shared.data(
            for: authorizedRequest(url, method: following ? "PUT" : "DELETE"),
            context: .init(lane: .social, coalesces: false)
        )
        if Self.isBotChallenge(response: http, data: data) {
            try enforceTrafficSafety()
        }
        if http.statusCode == 403 { throw APIError.forbidden }
        if http.statusCode == 429 { throw APIError.rateLimited(resetAt: Self.rateLimitResetDate(from: data)) }
        if http.statusCode == 401 {
            if allowRefresh, await refreshCredentialsAfterUnauthorized(sentWith: sentToken) {
                return try await performFollowingRequest(url: url, following: following, allowRefresh: false)
            }
            throw await Self.unauthorizedError()
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
        guard !LocalTrackFile.isLocalTrackID(trackID) else { throw APIError.notFound }
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

    func getPlayHistoryContexts(limit: Int = 20) async throws -> Page<PlayHistoryContext> {
        guard let url = buildURL("me/play-history/contexts", queryItems: [
            URLQueryItem(name: "limit", value: String(limit))
        ]) else {
            throw APIError.invalidURL
        }
        return try await request(url)
    }

    func getRecentlyPlayedTracks() async throws -> [Track] {
        guard accessToken != nil else { throw APIError.unauthorized }
        guard let url = URL(string: "https://api.soundcloud.com/me/recently-played/tracks") else {
            throw APIError.invalidURL
        }
        let refs: SoundCloudTrackReferences = try await request(url)
        guard !refs.ids.isEmpty else { return [] }
        let tracks = try await getTracks(ids: refs.ids)
        let byID = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return refs.ids.compactMap { byID[$0] }
    }

    func reportPlay(trackID: String) async throws {
        guard !LocalTrackFile.isLocalTrackID(trackID) else { throw APIError.notFound }
        guard accessToken != nil else { throw APIError.unauthorized }
        guard let url = buildURL("me/play-history") else { throw APIError.invalidURL }
        try await admitAuthenticatedRequest(url, method: "POST")
        var outgoing = authorizedRequest(url, method: "POST")
        outgoing.httpBody = try JSONSerialization.data(withJSONObject: ["track_urn": "soundcloud:tracks:\(trackID)"])
        outgoing.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let (data, http) = try await SoundCloudGateway.shared.data(
            for: outgoing,
            context: .init(intent: .autonomous, lane: .social, allowsBackground: true, coalesces: false)
        )
        if Self.isBotChallenge(response: http, data: data) {
            try enforceTrafficSafety()
        }
        switch http.statusCode {
        case 200..<300:
            credentials?.noteAuthenticatedRequestSucceeded()
        case 401:
            throw APIError.unauthorized
        case 403:
            throw APIError.forbidden
        case 404, 405, 410:
            throw APIError.notFound
        case 429:
            throw APIError.rateLimited(resetAt: SoundCloudGateway.shared.backgroundWorkPausedUntil ?? Self.rateLimitResetDate(from: data))
        default:
            throw APIError.serverError(http.statusCode)
        }
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
        guard !LocalTrackFile.isLocalTrackID(track.id) else { throw APIError.notFound }
        let data = try await tracked(.trackRepost(track, reposted)) { try await performSocialRequest(
            path: "reposts/tracks/\(track.urn)",
            method: reposted ? "POST" : "DELETE"
        ) }
        _ = data
    }

    func setPlaylistLiked(_ liked: Bool, playlist: Playlist) async throws {
        let data = try await tracked(.playlistLike(playlist, liked)) { try await performSocialRequest(
            path: "likes/playlists/\(playlist.urn)",
            method: liked ? "POST" : "DELETE"
        ) }
        _ = data
    }

    func setPlaylistReposted(_ reposted: Bool, playlist: Playlist) async throws {
        let data = try await tracked(.playlistRepost(playlist, reposted)) { try await performSocialRequest(
            path: "reposts/playlists/\(playlist.urn)",
            method: reposted ? "POST" : "DELETE"
        ) }
        _ = data
    }

    func postComment(trackId: String, body: String, timestampMillis: Int? = nil) async throws -> Comment {
        guard !LocalTrackFile.isLocalTrackID(trackId) else { throw APIError.notFound }
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
        guard let url = URL(string: "https://api.soundcloud.com/\(path)") else {
            throw APIError.invalidURL
        }
        try await admitAuthenticatedRequest(url, method: method)
        let sentToken = accessToken
        var request = authorizedRequest(url, method: method)
        request.httpBody = body
        if body != nil {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        let (data, http) = try await SoundCloudGateway.shared.data(
            for: request,
            context: .init(lane: .social, coalesces: false)
        )
        if Self.isBotChallenge(response: http, data: data) {
            try enforceTrafficSafety()
        }
        if http.statusCode == 429 {
            throw APIError.rateLimited(resetAt: Self.rateLimitResetDate(from: data))
        }
        if http.statusCode == 403 { throw APIError.forbidden }
        if http.statusCode == 401 {
            if allowRefresh, await refreshCredentialsAfterUnauthorized(sentWith: sentToken) {
                return try await performSocialRequest(
                    path: path, method: method, body: body, allowRefresh: false
                )
            }
            throw await Self.unauthorizedError()
        }
        guard (200..<300).contains(http.statusCode) else { throw APIError.serverError(http.statusCode) }
        credentials?.noteAuthenticatedRequestSucceeded()
        return data
    }

    private func setLike(_ track: Track, liked: Bool) async throws {
        guard !LocalTrackFile.isLocalTrackID(track.id) else { throw APIError.notFound }
        guard let user = await credentials?.waitForCurrentUser() else { throw APIError.unauthorized }
        guard let url = buildURL("users/\(user.id)/track_likes/\(track.id)") else {
            throw APIError.invalidURL
        }

        try await tracked(.trackLike(track, liked)) {
            try await performLikeRequest(url: url, track: track, liked: liked, allowRefresh: true)
        }
    }

    private func performLikeRequest(url: URL, track: Track, liked: Bool, allowRefresh: Bool) async throws {
        try await admitAuthenticatedRequest(url, method: liked ? "PUT" : "DELETE")
        let sentToken = accessToken
        let request = authorizedRequest(url, method: liked ? "PUT" : "DELETE")
        let (data, httpResponse) = try await SoundCloudGateway.shared.data(
            for: request,
            context: .init(lane: .social, coalesces: false)
        )
        if Self.isBotChallenge(response: httpResponse, data: data) {
            try enforceTrafficSafety()
        }
        if httpResponse.statusCode == 403 { throw APIError.forbidden }
        if httpResponse.statusCode == 429 { throw APIError.rateLimited(resetAt: Self.rateLimitResetDate(from: data)) }
        if httpResponse.statusCode == 401 {
            if allowRefresh, await refreshCredentialsAfterUnauthorized(sentWith: sentToken) {
                return try await performLikeRequest(url: url, track: track, liked: liked, allowRefresh: false)
            }
            throw await Self.unauthorizedError()
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw APIError.serverError(httpResponse.statusCode)
        }

        likeRevision &+= 1
        latestLikeChange = SoundCloudLikeChange(track: track, isLiked: liked, revision: likeRevision)
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
    var type: String? = nil
    var promoted: PromotedContent? = nil

    var isPromoted: Bool { promoted != nil || type?.hasSuffix("-promoted") == true }

    enum CodingKeys: String, CodingKey {
        case createdAt = "created_at"
        case track, playlist, type, promoted
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

// MARK: - Direct messages

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
        if let first = candidates.first { try await admitAuthenticatedRequest(first, method: method) }
        let sentToken = accessToken
        for (index, url) in candidates.enumerated() {
            var outgoing = authorizedRequest(url, method: method)
            outgoing.httpBody = body
            if let contentType { outgoing.setValue(contentType, forHTTPHeaderField: "Content-Type") }
            let (data, http) = try await SoundCloudGateway.shared.data(
                for: outgoing,
                context: .init(lane: .messaging, coalesces: method == "GET")
            )
            if Self.isBotChallenge(response: http, data: data) {
                try enforceTrafficSafety()
            }
            if http.statusCode == 403 { throw SoundCloudMessagingError.unavailable }
            switch http.statusCode {
            case 200..<300:
                credentials?.noteAuthenticatedRequestSucceeded()
                return data
            case 401:
                if allowRefresh, await refreshCredentialsAfterUnauthorized(sentWith: sentToken) {
                    return try await messagingRequest(
                        candidates: candidates,
                        method: method,
                        body: body,
                        contentType: contentType,
                        allowRefresh: false
                    )
                }
                throw await Self.unauthorizedError()
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

// MARK: - Stations

extension SoundCloudAPI {
    private static let officialBase = "https://api.soundcloud.com"

    private func officialURL(_ path: String, queryItems: [URLQueryItem] = []) -> URL? {
        var components = URLComponents(string: "\(Self.officialBase)/\(path)")
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        return components?.url
    }

    private static func pathURN(_ urn: String) -> String {
        urn.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? urn
    }

    func getLikedStations(limit: Int = 50) async throws -> [OfficialStation] {
        guard accessToken != nil else { throw APIError.unauthorized }
        guard let url = officialURL("me/likes/system-playlists", queryItems: [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "linked_partitioning", value: "true"),
        ]) else {
            throw APIError.invalidURL
        }
        let list: OfficialStationList = try await request(url)
        return list.stations
    }

    func getOfficialStation(urn: String) async throws -> OfficialStation {
        guard accessToken != nil else { throw APIError.unauthorized }
        guard let url = officialURL("system-playlists/\(Self.pathURN(urn))") else {
            throw APIError.invalidURL
        }
        return try await request(url)
    }

    func getRelatedArtists(userID: String, limit: Int = 12) async throws -> [User] {
        guard accessToken != nil else { throw APIError.unauthorized }
        guard let url = officialURL("users/\(Self.pathURN("soundcloud:users:\(userID)"))/related", queryItems: [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "linked_partitioning", value: "true"),
        ]) else {
            throw APIError.invalidURL
        }
        let list: OfficialUserList = try await request(url)
        return list.users
    }

    func getTracks(ids: [String], limit: Int = 50) async throws -> [Track] {
        let wanted = Array(ids.prefix(max(0, limit)))
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
}

struct OfficialStation: Decodable, Sendable {
    let station: SystemPlaylist
    let trackIDs: [String]
    let leadArtworkURL: URL?

    private enum CodingKeys: String, CodingKey { case tracks }

    init(from decoder: Decoder) throws {
        station = try SystemPlaylist(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stubs = ((try? container.decodeIfPresent([StationTrackStub].self, forKey: .tracks)) ?? nil) ?? []
        let stubIDs = stubs.compactMap(\.id)
        trackIDs = station.trackIDs.isEmpty ? stubIDs : station.trackIDs
        leadArtworkURL = stubs.lazy.compactMap(\.artworkURL).first
    }
}

private struct StationTrackStub: Decodable {
    let id: String?
    let artworkURL: URL?

    private enum CodingKeys: String, CodingKey {
        case id, urn
        case artworkURL = "artwork_url"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let numeric = try? container.decode(Int64.self, forKey: .id) {
            id = String(numeric)
        } else if let text = try? container.decode(String.self, forKey: .id) {
            id = text
        } else if let urn = try? container.decode(String.self, forKey: .urn) {
            id = urn.split(separator: ":").last.map(String.init)
        } else {
            id = nil
        }
        artworkURL = (try? container.decodeIfPresent(URL.self, forKey: .artworkURL)) ?? nil
    }
}

private struct SkippedElement: Decodable {
    init(from decoder: Decoder) throws {}
}

private enum OfficialCollectionKeys: String, CodingKey { case collection }

private func officialElements(_ decoder: Decoder) throws -> UnkeyedDecodingContainer {
    if let array = try? decoder.unkeyedContainer() { return array }
    let container = try decoder.container(keyedBy: OfficialCollectionKeys.self)
    return try container.nestedUnkeyedContainer(forKey: .collection)
}

private struct OfficialStationList: Decodable {
    let stations: [OfficialStation]

    init(from decoder: Decoder) throws {
        var elements = try officialElements(decoder)
        var stations: [OfficialStation] = []
        while !elements.isAtEnd {
            if let station = try? elements.decode(OfficialStation.self) {
                stations.append(station)
            } else {
                _ = try elements.decode(SkippedElement.self)
            }
        }
        self.stations = stations
    }
}

private struct OfficialUserList: Decodable {
    let users: [User]

    init(from decoder: Decoder) throws {
        var elements = try officialElements(decoder)
        var users: [User] = []
        while !elements.isAtEnd {
            if let entry = try? elements.decode(OfficialUser.self), let user = entry.user {
                users.append(user)
            } else {
                _ = try elements.decode(SkippedElement.self)
            }
        }
        self.users = users
    }
}

private struct OfficialUser: Decodable {
    let user: User?

    private enum CodingKeys: String, CodingKey {
        case id, urn, username, permalink, city, country, description
        case permalinkURL = "permalink_url"
        case avatarURL = "avatar_url"
        case fullName = "full_name"
        case followersCount = "followers_count"
        case followingsCount = "followings_count"
        case trackCount = "track_count"
        case playlistCount = "playlist_count"
    }

    init(from decoder: Decoder) throws {
        if let user = try? User(from: decoder) {
            self.user = user
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id: String?
        if let numeric = try? container.decode(Int64.self, forKey: .id) {
            id = String(numeric)
        } else if let urn = try? container.decode(String.self, forKey: .urn) {
            id = urn.split(separator: ":").last.map(String.init)
        } else {
            id = nil
        }
        guard let id, Int(id) != nil,
              let username = try? container.decode(String.self, forKey: .username),
              let permalinkURL = try? container.decode(URL.self, forKey: .permalinkURL) else {
            user = nil
            return
        }
        func text(_ key: CodingKeys) -> String? { (try? container.decodeIfPresent(String.self, forKey: key)) ?? nil }
        func count(_ key: CodingKeys) -> Int { ((try? container.decodeIfPresent(Int.self, forKey: key)) ?? nil) ?? 0 }
        user = User(
            id: id,
            username: username,
            permalink: text(.permalink) ?? permalinkURL.lastPathComponent,
            permalinkURL: permalinkURL,
            avatarURL: User.customAvatar((try? container.decodeIfPresent(URL.self, forKey: .avatarURL)) ?? nil),
            city: text(.city),
            country: text(.country),
            fullName: text(.fullName),
            description: text(.description),
            trackCount: count(.trackCount),
            playlistCount: count(.playlistCount),
            followersCount: count(.followersCount),
            followingsCount: count(.followingsCount)
        )
    }
}
