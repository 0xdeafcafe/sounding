import Foundation
import CryptoKit
import Network
import Security
import Dispatch
import os

// MARK: - Auth handoff request

/// Parameters for an auth handoff to a dependent device (e.g. Apple TV or Apple Watch).
struct AuthHandoffRequest: Identifiable, Equatable {
    let id = UUID()
    let sessionId: String
    let secret: Data
    let peerName: String?
    let peerClass: DeviceClass
}

// MARK: - Local-network protocol taxonomy
//
// Remote control (queue, playback, DJ state, and auth handoff requests):
//   CompanionServer / CompanionClient over Bonjour `_soundingtv._tcp`.
//
// Initial dependent-device sign-in from a phone/Mac camera QR code:
//   LinkServer / LinkClient / CompanionLinker, also `_soundingtv._tcp`,
//   bootstrapped by a one-time numeric-comparison or QR-code handshake.
//
// Companion-brokered auth handoff:
//   Reuses the remote-control CompanionServer/CompanionClient channel.
//   The peer asks; the companion runs a fresh sign-in and returns a brand-new
//   token pair that belongs to the peer, not to the companion.

enum BonjourConstants {
    static let serviceType = "_soundingtv._tcp"
    static let serviceDomain = "local."
    static let serviceName = "SoundingTV-Link"

    static let companionServiceName = "SoundingTV-Companion"

    static let contentServiceName = "SoundingTV-Content"

    static let linkOfferServiceName = "SoundingTV-LinkOffer"

    static let nearbyServiceName = "SoundingTV-Nearby"

    static let fixtureLinkToken = "sounding-fixture-link-token"

    static func linkServiceName(sessionId: String) -> String {
        "\(serviceName)-\(sessionId.prefix(8))"
    }

    static func linkOfferServiceName(sessionId: String) -> String {
        "\(linkOfferServiceName)-\(sessionId.prefix(8))"
    }

    static let sessionTimeout: TimeInterval = 300

    static let linkApprovalTimeout: TimeInterval = 90

    static let commandFreshnessWindow: TimeInterval = 120
}

enum MessageType: String, Codable {
    case tokenTransfer = "token_transfer"
    case acknowledgment = "ack"
    case error = "error"
    case tokenRejected = "token_rejected"

    case queueRequest = "queue_request"
    case queueReorder = "queue_reorder"
    case queueRemove = "queue_remove"
    case queueJump = "queue_jump"
    case queueAdd = "queue_add"
    case queueReplace = "queue_replace"
    case queueLoad = "queue_load"

    case queueState = "queue_state"

    case transportPlay     = "transport_play"
    case transportPause    = "transport_pause"
    case transportNext     = "transport_next"
    case transportPrevious = "transport_previous"
    case transportSeek     = "transport_seek"
    case transportShuffle  = "transport_shuffle"
    case transportRepeat   = "transport_repeat"
    case transportVolume   = "transport_volume"
    case transportSleepTimer = "transport_sleep_timer"

    case djEnable    = "dj_enable"
    case djDisable   = "dj_disable"
    case djAutoEnable  = "dj_auto_enable"
    case djAutoDisable = "dj_auto_disable"
    case djProfile     = "dj_profile"
    case djMixNow    = "dj_mix_now"
    case djExtend    = "dj_extend"
    case djEnergy    = "dj_energy"
    case djLoopSet   = "dj_loop_set"
    case djLoopClear = "dj_loop_clear"
    case djCue       = "dj_cue"
    case djHotCueSet = "dj_hot_cue_set"
    case djDeckPlayPause = "dj_deck_play_pause"
    case djSync      = "dj_sync"

    case djCrossfader = "dj_crossfader"
    case djEQ         = "dj_eq"
    case djFilter     = "dj_filter"
    case djRate       = "dj_rate"
    case djJog        = "dj_jog"
    case djRemoteAttach = "dj_remote_attach"
    case djHandBack   = "dj_hand_back"

    case sceneParty    = "scene_party"
    case sceneWindDown = "scene_wind_down"

    case cueSync = "cue_sync"
    case likesSync = "likes_sync"
    case localMusicOffer = "local_music_offer"
    case localMusicRequest = "local_music_request"
    case continueSession = "continue_session"

    case playbackState = "playback_state"
    case djState       = "dj_state"

    case sessionRequest = "session_request"
    case sessionOffer = "session_offer"
    case sessionUnavailable = "session_unavailable"

    case authHandoffSessionRequest = "companion_session_request"
    case authHandoffSessionOffer = "companion_session_offer"

    case numericComparisonHello = "numeric_hello"
    case numericComparisonHelloAck = "numeric_hello_ack"
    case numericComparisonConfirm = "numeric_confirm"
    case numericComparisonCredentials = "numeric_credentials"
    case numericComparisonDeclined = "numeric_declined"

    case chimeHello = "chime_hello"
    case chimeHelloAck = "chime_hello_ack"
    case chimeConfirm = "chime_confirm"
    case chimeCredentials = "chime_credentials"
    case chimePlayRequest = "chime_play_request"
    case chimePlaying = "chime_playing"

    case deviceStatus = "device_status"

    case linkRevoke = "link_revoke"
    case sessionRevoke = "session_revoke"

    var isQueueCommand: Bool {
        switch self {
        case .queueRequest, .queueReorder, .queueRemove, .queueJump, .queueAdd, .queueReplace, .queueLoad:
            return true
        default:
            return false
        }
    }

    var isControlCommand: Bool {
        switch self {
        case .transportPlay, .transportPause, .transportNext,
             .transportPrevious, .transportSeek, .transportShuffle, .transportRepeat, .transportVolume,
             .transportSleepTimer,
             .djEnable, .djDisable, .djAutoEnable, .djAutoDisable, .djProfile,
             .djMixNow, .djExtend, .djEnergy, .djLoopSet, .djLoopClear, .djCue, .djHotCueSet, .djDeckPlayPause, .djSync,
             .djCrossfader, .djEQ, .djFilter, .djRate, .djJog,
             .djRemoteAttach, .djHandBack,
             .sceneParty, .sceneWindDown:
            return true
        default:
            return false
        }
    }

    var isContinuousControl: Bool {
        switch self {
        case .djCrossfader, .djEQ, .djFilter, .djRate, .djJog, .transportVolume:
            return true
        default:
            return false
        }
    }
}

enum HandoffActivityType {
    static let link = "red.forbes.sounding.pairing"
    static let nowPlaying = "red.forbes.sounding.nowplaying"
    static let playing = "red.forbes.sounding.playing"
}

enum CanonicalForm {
    private static let separator = "\u{1F}" // ASCII unit separator

    static func bytes(_ fields: [String]) -> Data {
        fields
            .map {
                $0.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: separator, with: "\\u")
            }
            .joined(separator: separator)
            .data(using: .utf8) ?? Data()
    }

    static func sign(_ fields: [String], secret: Data) -> String {
        let key = SymmetricKey(data: secret)
        let code = HMAC<SHA256>.authenticationCode(for: bytes(fields), using: key)
        return Data(code).base64EncodedString()
    }

    static func verify(_ signature: String, fields: [String], secret: Data) -> Bool {
        guard let provided = Data(base64Encoded: signature) else { return false }
        let key = SymmetricKey(data: secret)
        return HMAC<SHA256>.isValidAuthenticationCode(
            provided,
            authenticating: bytes(fields),
            using: key
        )
    }

    static func digest<T: Encodable>(of value: T?) -> String {
        guard let value else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "" }
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }
}

enum SoundCloudTokenRefresh {

    typealias RequestTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Thread-safe holder so the refresh network path does not have to wait
    /// for the MainActor just to read the installed transport.
    private final class TransportHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var transport: RequestTransport?

        func get() -> RequestTransport? {
            lock.lock()
            defer { lock.unlock() }
            return transport
        }

        func set(_ transport: @escaping RequestTransport) {
            lock.lock()
            self.transport = transport
            lock.unlock()
        }

        func clear() {
            lock.lock()
            self.transport = nil
            lock.unlock()
        }
    }

    private static let transportHolder = TransportHolder()

    /// Application hosts install the SoundCloud gateway here. Lightweight
    /// extensions compile this shared auth model but never initiate refresh;
    /// the URLSession fallback keeps that model independently reusable.
    nonisolated static var requestTransport: RequestTransport? {
        get { transportHolder.get() }
        set {
            if let newValue {
                transportHolder.set(newValue)
            } else {
                transportHolder.clear()
            }
        }
    }

    struct Credentials: Equatable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
        var issuedAt: Date? = nil
        var generation: Int? = nil
    }

    enum Outcome: Equatable {
        case succeeded(Credentials)
        case unrecoverable
        case transient
    }

    private static let tokenEndpoint = "https://secure.soundcloud.com/oauth/token"

    static func perform(refreshToken: String, clientId: String) async -> Outcome {
        guard let url = URL(string: tokenEndpoint) else { return .unrecoverable }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Accept")
        request.httpBody = [
            "grant_type": "refresh_token",
            "client_id": clientId,
            "refresh_token": refreshToken,
        ]
        .map { "\($0.key)=\(formEscape($0.value))" }
        .joined(separator: "&")
        .data(using: .utf8)

        let data: Data
        let http: HTTPURLResponse
        do {
            if let installedTransport = requestTransport {
                (data, http) = try await installedTransport(request)
            } else {
                let (body, response) = try await URLSession.shared.data(for: request)
                guard let asHTTP = response as? HTTPURLResponse else { return .transient }
                data = body
                http = asHTTP
            }
        } catch {
            Log.link.error("[TokenRefresh] request did not complete: \(error.localizedDescription, privacy: .public)")
            return .transient
        }

        guard (200..<300).contains(http.statusCode) else {
            let outcome = failureOutcome(statusCode: http.statusCode, data: data)
            switch outcome {
            case .unrecoverable:
                Log.link.error("[TokenRefresh] credentials rejected: HTTP \(http.statusCode, privacy: .public) \(errorCode(in: data), privacy: .public)")
            case .transient:
                Log.link.error("[TokenRefresh] inconclusive: HTTP \(http.statusCode, privacy: .public) \(errorCode(in: data), privacy: .public)")
            case .succeeded:
                break
            }
            return outcome
        }

        struct RefreshResponse: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double?
        }
        guard let parsed = try? JSONDecoder().decode(RefreshResponse.self, from: data),
              !parsed.access_token.isEmpty else {
            Log.link.error("[TokenRefresh] could not parse a 2xx refresh response")
            return .transient
        }

        return .succeeded(Credentials(
            accessToken: parsed.access_token,
            refreshToken: parsed.refresh_token.flatMap { $0.isEmpty ? nil : $0 },
            expiresAt: parsed.expires_in.map { Date(timeIntervalSinceNow: $0) },
            issuedAt: Date()
        ))
    }

    /// HTTP status alone is not proof that the user's refresh credential is
    /// gone. In particular, 401/403 can also be produced by infrastructure,
    /// policy, or bot-challenge layers and 400 can describe a malformed
    /// request. Only an explicit OAuth credential rejection makes the local
    /// session unrecoverable; everything else keeps the session for a later
    /// retry.
    static func failureOutcome(statusCode: Int, data: Data) -> Outcome {
        // Rate limits, policy/challenge responses, and server failures are
        // always retryable regardless of an incidental body string. OAuth
        // credential errors are defined on the 400/401 token response path.
        guard statusCode == 400 || statusCode == 401 else { return .transient }
        guard let code = oauthErrorCode(in: data) else { return .transient }
        switch code {
        case "invalid_grant", "invalid_token", "expired_token", "revoked_token",
             "invalid_client", "unauthorized_client":
            return .unrecoverable
        default:
            return .transient
        }
    }

    static func oauthErrorCode(in data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["error"] as? String else { return nil }
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func errorCode(in data: Data) -> String {
        guard let code = oauthErrorCode(in: data) else { return "" }
        return "(\(code))"
    }

    private static func formEscape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

@MainActor
final class TokenRefreshCoordinator {

    static let verdictLifetime: TimeInterval = 10
    static let transientVerdictLifetime: TimeInterval = 60

    private struct CacheKey: Equatable {
        let refreshToken: String
        let clientId: String
    }

    private var inFlight: Task<SoundCloudTokenRefresh.Outcome, Never>?
    private var inFlightKey: CacheKey?
    private var lastVerdict: (key: CacheKey, outcome: SoundCloudTokenRefresh.Outcome, wasLocalGuard: Bool, at: Date)?

    private var generation: UInt64 = 0

    var recentOutcome: SoundCloudTokenRefresh.Outcome? {
        guard let lastVerdict,
              lastVerdict.key == currentKey(),
              Date().timeIntervalSince(lastVerdict.at) < lifetime(for: lastVerdict.outcome) else { return nil }
        return lastVerdict.outcome
    }

    var recentOutcomeWasLocalGuard: Bool {
        guard let lastVerdict,
              lastVerdict.key == currentKey(),
              Date().timeIntervalSince(lastVerdict.at) < lifetime(for: lastVerdict.outcome) else { return false }
        return lastVerdict.wasLocalGuard
    }

    private func currentKey() -> CacheKey? {
        guard let session = DeviceSessionStore.load(), session.isUsable else { return nil }
        guard let refreshToken = session.refreshToken, !refreshToken.isEmpty,
              let clientId = session.clientId, !clientId.isEmpty else { return nil }
        return CacheKey(refreshToken: refreshToken, clientId: clientId)
    }

    private func lifetime(for outcome: SoundCloudTokenRefresh.Outcome) -> TimeInterval {
        outcome == .transient ? Self.transientVerdictLifetime : Self.verdictLifetime
    }

    func reset() {
        inFlight = nil
        inFlightKey = nil
        lastVerdict = nil
        generation &+= 1
    }

    func refresh(refreshToken: String?, clientId: String?) async -> SoundCloudTokenRefresh.Outcome {
        let key = CacheKey(refreshToken: refreshToken ?? "", clientId: clientId ?? "")

        if let recentOutcome, lastVerdict?.key == key { return recentOutcome }
        if let inFlight, inFlightKey == key { return await inFlight.value }

        guard let refreshToken, !refreshToken.isEmpty,
              let clientId, !clientId.isEmpty else {
            Log.link.error("[TokenRefresh] no refresh material held")
            let outcome = SoundCloudTokenRefresh.Outcome.unrecoverable
            lastVerdict = (key, outcome, true, Date())
            return outcome
        }

        let startedAt = generation
        let task = Task<SoundCloudTokenRefresh.Outcome, Never> {
            await SoundCloudTokenRefresh.perform(refreshToken: refreshToken, clientId: clientId)
        }
        inFlight = task
        inFlightKey = key
        let outcome = await task.value

        guard generation == startedAt else {
            // Generation changed while the refresh was in flight; do not leave
            // a stale task reference behind for the next caller.
            inFlight = nil
            inFlightKey = nil
            return outcome
        }
        inFlight = nil
        inFlightKey = nil
        lastVerdict = (key, outcome, false, Date())
        return outcome
    }
}

enum LinkTLS {
    static let pskInfo = Data("SoundingTV-Link-TLS-PSK-v1".utf8)

    static let contentPSKInfo = Data("SoundingTV-Content-TLS-PSK-v1".utf8)

    static let companionPSKInfo = Data("SoundingTV-Companion-TLS-PSK-v1".utf8)

    private static let pskCiphersuite: UInt16 = 0xCCAC

    private static func derivePSK(secret: Data, sessionId: String, info: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: Data(sessionId.utf8),
            info: info,
            outputByteCount: 32
        )
    }

    static func configure(_ options: sec_protocol_options_t, sessionId: String, secret: Data, info: Data = pskInfo) {
        let pskKey = derivePSK(secret: secret, sessionId: sessionId, info: info)
        let pskData = pskKey.withUnsafeBytes { Data($0) }
        let identityData = Data(sessionId.utf8)

        let pskDispatchData = pskData.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityDispatchData = identityData.withUnsafeBytes { DispatchData(bytes: $0) }

        sec_protocol_options_add_pre_shared_key(
            options,
            pskDispatchData as __DispatchData,
            identityDispatchData as __DispatchData
        )
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: pskCiphersuite)!)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
    }

    static func makeParameters(sessionId: String, secret: Data, info: Data = pskInfo) -> NWParameters {
        let tlsOptions = NWProtocolTLS.Options()
        configure(tlsOptions.securityProtocolOptions, sessionId: sessionId, secret: secret, info: info)

        let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        // Bonjour link should continue to work when the two devices can see
        // each other over AWDL but multicast discovery on the access point is
        // unavailable or filtered.
        parameters.includePeerToPeer = true
        return parameters
    }
}

struct TokenPayload: Codable {
    let oauthToken: String
    let refreshToken: String?
    let clientId: String?
    let expiresAt: Date?
    let signature: String

    static func create(
        token: String,
        refreshToken: String?,
        clientId: String?,
        expiresAt: Date?,
        sessionId: String,
        secret: Data
    ) -> TokenPayload {
        let signature = CanonicalForm.sign(
            fields(token: token, refreshToken: refreshToken, clientId: clientId, sessionId: sessionId),
            secret: secret
        )
        return TokenPayload(
            oauthToken: token,
            refreshToken: refreshToken,
            clientId: clientId,
            expiresAt: expiresAt,
            signature: signature
        )
    }

    func verify(sessionId: String, secret: Data) -> Bool {
        CanonicalForm.verify(
            signature,
            fields: Self.fields(token: oauthToken, refreshToken: refreshToken, clientId: clientId, sessionId: sessionId),
            secret: secret
        )
    }

    private static func fields(
        token: String,
        refreshToken: String?,
        clientId: String?,
        sessionId: String
    ) -> [String] {
        [sessionId, MessageType.tokenTransfer.rawValue, token, refreshToken ?? "", clientId ?? ""]
    }
}

struct SessionRequestPayload: Codable, Equatable {
    let issuedAtMillis: Int64
    let nonce: String
    let signature: String

    static func create(sessionId: String, secret: Data) -> SessionRequestPayload {
        let issuedAtMillis = Int64(Date().timeIntervalSince1970 * 1000)
        let nonce = UUID().uuidString
        let signature = CanonicalForm.sign(
            fields(issuedAtMillis: issuedAtMillis, nonce: nonce, sessionId: sessionId),
            secret: secret
        )
        return SessionRequestPayload(
            issuedAtMillis: issuedAtMillis,
            nonce: nonce,
            signature: signature
        )
    }

    func verify(sessionId: String, secret: Data) -> Bool {
        CanonicalForm.verify(
            signature,
            fields: Self.fields(issuedAtMillis: issuedAtMillis, nonce: nonce, sessionId: sessionId),
            secret: secret
        )
    }

    func isFresh(now: Date = Date()) -> Bool {
        let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
        return abs(TimeInterval(nowMillis - issuedAtMillis) / 1000) <= BonjourConstants.commandFreshnessWindow
    }

    private static func fields(issuedAtMillis: Int64, nonce: String, sessionId: String) -> [String] {
        [sessionId, MessageType.sessionRequest.rawValue, String(issuedAtMillis), nonce]
    }
}

struct SessionOfferPayload: Codable, Equatable {
    let oauthToken: String
    let refreshToken: String?
    let clientId: String?
    let expiresAt: Date?
    let issuedAtMillis: Int64
    let requestNonce: String
    let signature: String

    static func create(
        token: String,
        refreshToken: String?,
        clientId: String?,
        expiresAt: Date?,
        requestNonce: String,
        sessionId: String,
        secret: Data
    ) -> SessionOfferPayload {
        let issuedAtMillis = Int64(Date().timeIntervalSince1970 * 1000)
        let signature = CanonicalForm.sign(
            fields(
                token: token, refreshToken: refreshToken, clientId: clientId,
                expiresAt: expiresAt, issuedAtMillis: issuedAtMillis,
                requestNonce: requestNonce, sessionId: sessionId
            ),
            secret: secret
        )
        return SessionOfferPayload(
            oauthToken: token,
            refreshToken: refreshToken,
            clientId: clientId,
            expiresAt: expiresAt,
            issuedAtMillis: issuedAtMillis,
            requestNonce: requestNonce,
            signature: signature
        )
    }

    func verify(sessionId: String, secret: Data) -> Bool {
        CanonicalForm.verify(
            signature,
            fields: Self.fields(
                token: oauthToken, refreshToken: refreshToken, clientId: clientId,
                expiresAt: expiresAt, issuedAtMillis: issuedAtMillis,
                requestNonce: requestNonce, sessionId: sessionId
            ),
            secret: secret
        )
    }

    func isFresh(now: Date = Date()) -> Bool {
        let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
        return abs(TimeInterval(nowMillis - issuedAtMillis) / 1000) <= BonjourConstants.commandFreshnessWindow
    }

    private static func fields(
        token: String,
        refreshToken: String?,
        clientId: String?,
        expiresAt: Date?,
        issuedAtMillis: Int64,
        requestNonce: String,
        sessionId: String
    ) -> [String] {
        [
            sessionId,
            MessageType.sessionOffer.rawValue,
            token,
            refreshToken ?? "",
            clientId ?? "",
            expiresAt.map { String(Int64($0.timeIntervalSince1970 * 1000)) } ?? "",
            String(issuedAtMillis),
            requestNonce,
        ]
    }
}

/// Companion-brokered auth handoff for a dependent device.
///
/// When a dependent device (Apple TV, Apple Watch, etc.) cannot refresh its own
/// SoundCloud session, it sends an `.authHandoffSessionRequest` over the existing
/// remote-control companion link. The paired phone or Mac then runs a fresh
/// sign-in flow and returns the newly captured token pair in this payload. The
/// peer stores it as its own session and refreshes it once immediately. The
/// companion's own token pair is never shared; phone, iPad and Mac keep their
/// own sessions forever.
struct AuthHandoffSessionOfferPayload: Codable, Equatable {
    let oauthToken: String
    let refreshToken: String?
    let clientId: String?
    let expiresAtMillis: Int64?
    let issuedAtMillis: Int64
    let signature: String

    static func create(
        token: String,
        refreshToken: String?,
        clientId: String?,
        expiresAt: Date?,
        sessionId: String,
        secret: Data
    ) -> AuthHandoffSessionOfferPayload {
        let issuedAtMillis = Int64(Date().timeIntervalSince1970 * 1000)
        let expiresAtMillis = expiresAt.map { Int64($0.timeIntervalSince1970 * 1000) }
        let signature = CanonicalForm.sign(
            fields(
                token: token,
                refreshToken: refreshToken,
                clientId: clientId,
                expiresAtMillis: expiresAtMillis,
                issuedAtMillis: issuedAtMillis,
                sessionId: sessionId
            ),
            secret: secret
        )
        return AuthHandoffSessionOfferPayload(
            oauthToken: token,
            refreshToken: refreshToken,
            clientId: clientId,
            expiresAtMillis: expiresAtMillis,
            issuedAtMillis: issuedAtMillis,
            signature: signature
        )
    }

    func verify(sessionId: String, secret: Data) -> Bool {
        CanonicalForm.verify(
            signature,
            fields: Self.fields(
                token: oauthToken,
                refreshToken: refreshToken,
                clientId: clientId,
                expiresAtMillis: expiresAtMillis,
                issuedAtMillis: issuedAtMillis,
                sessionId: sessionId
            ),
            secret: secret
        )
    }

    func isFresh(now: Date = Date()) -> Bool {
        let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
        return abs(TimeInterval(nowMillis - issuedAtMillis) / 1000) <= BonjourConstants.commandFreshnessWindow
    }

    private static func fields(
        token: String,
        refreshToken: String?,
        clientId: String?,
        expiresAtMillis: Int64?,
        issuedAtMillis: Int64,
        sessionId: String
    ) -> [String] {
        [
            sessionId,
            MessageType.authHandoffSessionOffer.rawValue,
            token,
            refreshToken ?? "",
            clientId ?? "",
            expiresAtMillis.map(String.init) ?? "",
            String(issuedAtMillis),
        ]
    }
}

struct LinkPeerIdentity: Codable, Equatable {
    static let maximumNameLength = 64
    private static let deviceIdDefaultsKey = "red.forbes.sounding.link.deviceId"

    let name: String
    let deviceClass: String
    let deviceId: String
    let signature: String

    var peerClass: DeviceClass? { DeviceClass(rawValue: deviceClass) }

    static func create(
        name: String,
        deviceClass: DeviceClass,
        deviceId: String,
        sessionId: String,
        secret: Data
    ) -> LinkPeerIdentity {
        let name = String(name.prefix(maximumNameLength))
        let signature = CanonicalForm.sign(
            fields(name: name, deviceClass: deviceClass.rawValue, deviceId: deviceId, sessionId: sessionId),
            secret: secret
        )
        return LinkPeerIdentity(
            name: name,
            deviceClass: deviceClass.rawValue,
            deviceId: deviceId,
            signature: signature
        )
    }

    static func local(sessionId: String, secret: Data, defaults: UserDefaults = .standard) -> LinkPeerIdentity {
        create(
            name: localName,
            deviceClass: .current,
            deviceId: localDeviceId(defaults: defaults),
            sessionId: sessionId,
            secret: secret
        )
    }

    static func localDeviceId(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: deviceIdDefaultsKey), !existing.isEmpty { return existing }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: deviceIdDefaultsKey)
        return generated
    }

    static var localName: String {
        #if os(macOS)
        return Host.current().localizedName ?? DeviceClass.current.displayName
        #else
        return DeviceClass.current.displayName
        #endif
    }

    func verify(sessionId: String, secret: Data) -> Bool {
        guard name.count <= Self.maximumNameLength, !deviceId.isEmpty, peerClass != nil else { return false }
        return CanonicalForm.verify(
            signature,
            fields: Self.fields(name: name, deviceClass: deviceClass, deviceId: deviceId, sessionId: sessionId),
            secret: secret
        )
    }

    private static func fields(name: String, deviceClass: String, deviceId: String, sessionId: String) -> [String] {
        [sessionId, "peer_identity", name, deviceClass, deviceId]
    }
}

enum LinkOfferTXT {
    private static let nameKey = "name"
    private static let kindKey = "kind"
    private static let commitmentKey = "pkc"
    private static let rendezvousKey = "rv"

    static func dictionary(
        name: String,
        kind: DeviceClass,
        commitment: Data,
        rendezvous: String? = nil,
        accountHint: LinkAccountHint.Advert? = nil
    ) -> [String: String] {
        var entries = [nameKey: name, kindKey: kind.rawValue, commitmentKey: commitment.base64EncodedString()]
        if let rendezvous { entries[rendezvousKey] = rendezvous }
        if let accountHint { entries.merge(accountHint.entries) { _, new in new } }
        return entries
    }

    static func rendezvous(_ record: NWTXTRecord) -> String? {
        guard case .string(let value)? = record.getEntry(for: rendezvousKey), !value.isEmpty else { return nil }
        return value
    }

    static func decode(_ record: NWTXTRecord) -> (name: String, kind: DeviceClass, commitment: Data)? {
        guard case .string(let name)? = record.getEntry(for: nameKey), !name.isEmpty,
              case .string(let kindRaw)? = record.getEntry(for: kindKey),
              let kind = DeviceClass(rawValue: kindRaw),
              case .string(let commitBase64)? = record.getEntry(for: commitmentKey),
              let commitment = Data(base64Encoded: commitBase64),
              commitment.count == 32 else {
            return nil
        }
        return (name, kind, commitment)
    }
}

enum NearbyPresenceTXT {
    static let nameKey = "name"
    static let kindKey = "kind"

    static func entries(name: String, kind: DeviceClass) -> [String: String] {
        [nameKey: String(name.prefix(LinkPeerIdentity.maximumNameLength)), kindKey: kind.rawValue]
    }

    static func name(_ record: NWTXTRecord) -> String? {
        guard case .string(let raw)? = record.getEntry(for: nameKey) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(LinkPeerIdentity.maximumNameLength))
    }
}

enum LinkAccountHint {
    static let saltKey = "as"
    static let accountKey = "ah"
    static let linkedKey = "lp"
    static let saltLength = 8
    static let accountDigestLength = 12
    static let linkedDigestLength = 4
    static let maximumLinked = 8

    struct Advert: Equatable, Sendable {
        let salt: Data
        let accountDigest: Data
        let linkedDigests: [Data]

        var entries: [String: String] {
            var entries = [
                LinkAccountHint.saltKey: salt.base64EncodedString(),
                LinkAccountHint.accountKey: accountDigest.base64EncodedString(),
            ]
            if !linkedDigests.isEmpty {
                entries[LinkAccountHint.linkedKey] = linkedDigests.reduce(Data(), +).base64EncodedString()
            }
            return entries
        }

        func matches(accountId: String) -> Bool {
            guard !accountId.isEmpty else { return false }
            let mine = LinkAccountHint.accountDigest(accountId: accountId, salt: salt)
            return LinkAccountHint.constantTimeEqual(mine, accountDigest)
        }

        func isLinked(toDeviceId deviceId: String) -> Bool {
            guard !deviceId.isEmpty else { return false }
            let mine = LinkAccountHint.linkedDigest(deviceId: deviceId, salt: salt)
            return linkedDigests.contains { LinkAccountHint.constantTimeEqual($0, mine) }
        }
    }

    static func makeSalt() -> Data? {
        var bytes = [UInt8](repeating: 0, count: saltLength)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes)
    }

    static func advert(accountId: String, linkedDeviceIds: [String], salt: Data) -> Advert? {
        guard !accountId.isEmpty, salt.count == saltLength else { return nil }
        return Advert(
            salt: salt,
            accountDigest: accountDigest(accountId: accountId, salt: salt),
            linkedDigests: linkedDeviceIds.filter { !$0.isEmpty }.prefix(maximumLinked).map { linkedDigest(deviceId: $0, salt: salt) }
        )
    }

    static func accountDigest(accountId: String, salt: Data) -> Data {
        digest(label: "Sounding-LinkAccount-v1", value: accountId, salt: salt, length: accountDigestLength)
    }

    static func linkedDigest(deviceId: String, salt: Data) -> Data {
        digest(label: "Sounding-LinkedPeer-v1", value: deviceId.lowercased(), salt: salt, length: linkedDigestLength)
    }

    static func decode(_ entries: [String: String]) -> Advert? {
        guard let saltText = entries[saltKey], let salt = Data(base64Encoded: saltText), salt.count == saltLength,
              let accountText = entries[accountKey], let account = Data(base64Encoded: accountText),
              account.count == accountDigestLength else { return nil }
        var linked: [Data] = []
        if let linkedText = entries[linkedKey], let blob = Data(base64Encoded: linkedText),
           blob.count % linkedDigestLength == 0, blob.count <= linkedDigestLength * maximumLinked {
            linked = stride(from: 0, to: blob.count, by: linkedDigestLength).map {
                Data(blob[blob.startIndex + $0 ..< blob.startIndex + $0 + linkedDigestLength])
            }
        }
        return Advert(salt: salt, accountDigest: account, linkedDigests: linked)
    }

    static let nameKey = "name"

    static func decode(_ record: NWTXTRecord) -> Advert? {
        var entries: [String: String] = [:]
        for key in [saltKey, accountKey, linkedKey] {
            if case .string(let value)? = record.getEntry(for: key) { entries[key] = value }
        }
        return decode(entries)
    }

    private static func digest(label: String, value: String, salt: Data, length: Int) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data(label.utf8))
        hasher.update(data: salt)
        hasher.update(data: Data(value.utf8))
        return Data(hasher.finalize().prefix(length))
    }

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }
}

struct LinkConfirmationHelloPayload: Codable, Equatable {
    let ephemeralPublicKeyBase64: String
    var deviceName: String?
    var deviceClass: String?
    var ownerKeyTags: [String]?
}

struct LinkConfirmationHelloAckPayload: Codable, Equatable {
    let ephemeralPublicKeyBase64: String
    let commitNonceBase64: String
    var ownerKeyTag: String?
    var ownerProof: String?
}

struct LinkConfirmationConfirmPayload: Codable, Equatable {
    var ownerProof: String?
}

struct LinkConfirmationCredentialsPayload: Codable, Equatable {
    let sealedBase64: String
}

struct ChimeLinkPayload: Codable, Equatable {
    var version: Int?
    var nonceBase64: String?
    var sessionId: String?
    var tvName: String?
    var tvKind: String?
    var tvDeviceId: String?
    var confirmationBase64: String?
    var sealedBase64: String?
}

struct DeviceStatusPayload: Codable, Equatable {
    let needsSignIn: Bool
    let issuedAtMillis: Int64
    let signature: String

    static func create(needsSignIn: Bool, sessionId: String, secret: Data) -> DeviceStatusPayload {
        let issuedAtMillis = Int64(Date().timeIntervalSince1970 * 1000)
        return DeviceStatusPayload(
            needsSignIn: needsSignIn,
            issuedAtMillis: issuedAtMillis,
            signature: CanonicalForm.sign(
                fields(needsSignIn: needsSignIn, issuedAtMillis: issuedAtMillis, sessionId: sessionId),
                secret: secret
            )
        )
    }

    func verify(sessionId: String, secret: Data) -> Bool {
        CanonicalForm.verify(
            signature,
            fields: Self.fields(needsSignIn: needsSignIn, issuedAtMillis: issuedAtMillis, sessionId: sessionId),
            secret: secret
        )
    }

    func isFresh(now: Date = Date()) -> Bool {
        let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
        return abs(TimeInterval(nowMillis - issuedAtMillis) / 1000) <= BonjourConstants.commandFreshnessWindow
    }

    private static func fields(needsSignIn: Bool, issuedAtMillis: Int64, sessionId: String) -> [String] {
        [sessionId, MessageType.deviceStatus.rawValue, needsSignIn ? "1" : "0", String(issuedAtMillis)]
    }
}

struct LinkRevokePayload: Codable, Equatable {
    let accountId: String?
    let lineageDigest: String?
    let issuedAtMillis: Int64
    let nonce: String
    let signature: String

    static func create(
        _ type: MessageType,
        accountId: String? = nil,
        lineageDigest: String? = nil,
        sessionId: String,
        secret: Data,
        now: Date = Date()
    ) -> LinkRevokePayload {
        let issuedAtMillis = Int64(now.timeIntervalSince1970 * 1000)
        let nonce = UUID().uuidString
        return LinkRevokePayload(
            accountId: accountId,
            lineageDigest: lineageDigest,
            issuedAtMillis: issuedAtMillis,
            nonce: nonce,
            signature: CanonicalForm.sign(
                fields(type, accountId: accountId, lineageDigest: lineageDigest, issuedAtMillis: issuedAtMillis, nonce: nonce, sessionId: sessionId),
                secret: secret
            )
        )
    }

    func verify(_ type: MessageType, sessionId: String, secret: Data) -> Bool {
        guard type == .linkRevoke || type == .sessionRevoke else { return false }
        return CanonicalForm.verify(
            signature,
            fields: Self.fields(type, accountId: accountId, lineageDigest: lineageDigest, issuedAtMillis: issuedAtMillis, nonce: nonce, sessionId: sessionId),
            secret: secret
        )
    }

    func isFresh(now: Date = Date()) -> Bool {
        let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
        return abs(TimeInterval(nowMillis - issuedAtMillis) / 1000) <= BonjourConstants.commandFreshnessWindow
    }

    func matchesAccount(accountId localAccountId: String?, lineageDigest localLineage: String?) -> Bool {
        if let accountId, !accountId.isEmpty, accountId == localAccountId { return true }
        if let lineageDigest, !lineageDigest.isEmpty, lineageDigest == localLineage { return true }
        return false
    }

    private static func fields(
        _ type: MessageType,
        accountId: String?,
        lineageDigest: String?,
        issuedAtMillis: Int64,
        nonce: String,
        sessionId: String
    ) -> [String] {
        [sessionId, type.rawValue, accountId ?? "", lineageDigest ?? "", String(issuedAtMillis), nonce]
    }
}

enum LinkConfirmationCrypto {
    private static let codeInfo = Data("SoundingTV-LinkConfirmation-Code-v2".utf8)
    private static let transportInfo = Data("SoundingTV-LinkConfirmation-Transport-v2".utf8)

    private static func transcript(_ a: Data, _ b: Data) -> Data {
        let ordered = [a, b].sorted { $0.lexicographicallyPrecedes($1) }
        return ordered[0] + ordered[1]
    }

    static func commitment(nonce: Data, publicKey: Data) -> Data {
        Data(SHA256.hash(data: nonce + publicKey))
    }

    static func code(sharedSecret: SharedSecret, publicKeyA: Data, publicKeyB: Data, sessionId: String, peerName: String) -> String {
        let salt = Data(sessionId.utf8) + transcript(publicKeyA, publicKeyB)
        let key = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: codeInfo + Data(peerName.utf8),
            outputByteCount: 4
        )
        let bytes = key.withUnsafeBytes { Array($0) }
        let value = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        return String(format: "%06u", value % 1_000_000)
    }

    static func transportKey(sharedSecret: SharedSecret, publicKeyA: Data, publicKeyB: Data, sessionId: String, peerName: String) -> SymmetricKey {
        let salt = Data(sessionId.utf8) + transcript(publicKeyA, publicKeyB)
        return sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: transportInfo + Data(peerName.utf8),
            outputByteCount: 32
        )
    }

    static func seal(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        try ChaChaPoly.seal(plaintext, using: key).combined
    }

    static func open(_ combined: Data, key: SymmetricKey) throws -> Data {
        try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: combined), using: key)
    }
}

struct QueueTrack: Codable, Equatable, Hashable, Identifiable {
    let id: String
    let title: String
    let artist: String
    let artworkURL: URL?
    let duration: TimeInterval

    init(id: String, title: String, artist: String, artworkURL: URL?, duration: TimeInterval) {
        self.id = id
        self.title = title
        self.artist = artist
        self.artworkURL = artworkURL
        self.duration = duration
    }

    var formattedDuration: String {
        let total = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    fileprivate var canonicalFields: [String] {
        [id, title, artist, artworkURL?.absoluteString ?? "", String(max(0, Int(duration.rounded())))]
    }
}

struct QueueStatePayload: Codable, Equatable {
    let tracks: [QueueTrack]
    let currentIndex: Int
    let isPlaying: Bool
    let revision: Int
    let issuedAtMillis: Int64
    let signature: String
    var sourceTitle: String? = nil
    var sourceKind: String? = nil
    var playingNextCount: Int? = nil

    static func create(
        tracks: [QueueTrack],
        currentIndex: Int,
        isPlaying: Bool,
        revision: Int,
        sourceTitle: String? = nil,
        sourceKind: String? = nil,
        playingNextCount: Int? = nil,
        sessionId: String,
        secret: Data
    ) -> QueueStatePayload {
        let issuedAtMillis = Int64(Date().timeIntervalSince1970 * 1000)
        let signature = CanonicalForm.sign(
            fields(
                tracks: tracks,
                currentIndex: currentIndex,
                isPlaying: isPlaying,
                revision: revision,
                issuedAtMillis: issuedAtMillis,
                sessionId: sessionId
            ),
            secret: secret
        )
        return QueueStatePayload(
            tracks: tracks,
            currentIndex: currentIndex,
            isPlaying: isPlaying,
            revision: revision,
            issuedAtMillis: issuedAtMillis,
            signature: signature,
            sourceTitle: sourceTitle?.isEmpty == false ? sourceTitle : nil,
            sourceKind: sourceTitle?.isEmpty == false ? sourceKind : nil,
            playingNextCount: playingNextCount.map { max(0, $0) }
        )
    }

    func verify(sessionId: String, secret: Data) -> Bool {
        CanonicalForm.verify(
            signature,
            fields: Self.fields(
                tracks: tracks,
                currentIndex: currentIndex,
                isPlaying: isPlaying,
                revision: revision,
                issuedAtMillis: issuedAtMillis,
                sessionId: sessionId
            ),
            secret: secret
        )
    }

    private static func fields(
        tracks: [QueueTrack],
        currentIndex: Int,
        isPlaying: Bool,
        revision: Int,
        issuedAtMillis: Int64,
        sessionId: String
    ) -> [String] {
        var out = [
            sessionId,
            MessageType.queueState.rawValue,
            String(revision),
            String(currentIndex),
            isPlaying ? "1" : "0",
            String(issuedAtMillis),
            String(tracks.count),
        ]
        for track in tracks {
            out.append(contentsOf: track.canonicalFields)
        }
        return out
    }
}

struct QueueCommandPayload: Codable, Equatable {
    let fromIndex: Int
    let toIndex: Int
    let trackId: String
    let revision: Int
    let issuedAtMillis: Int64
    let nonce: String
    let signature: String

    static func create(
        type: MessageType,
        fromIndex: Int,
        toIndex: Int,
        trackId: String,
        revision: Int,
        sessionId: String,
        secret: Data
    ) -> QueueCommandPayload {
        let issuedAtMillis = Int64(Date().timeIntervalSince1970 * 1000)
        let nonce = UUID().uuidString
        let signature = CanonicalForm.sign(
            fields(
                type: type,
                fromIndex: fromIndex,
                toIndex: toIndex,
                trackId: trackId,
                revision: revision,
                issuedAtMillis: issuedAtMillis,
                nonce: nonce,
                sessionId: sessionId
            ),
            secret: secret
        )
        return QueueCommandPayload(
            fromIndex: fromIndex,
            toIndex: toIndex,
            trackId: trackId,
            revision: revision,
            issuedAtMillis: issuedAtMillis,
            nonce: nonce,
            signature: signature
        )
    }

    func verify(type: MessageType, sessionId: String, secret: Data) -> Bool {
        CanonicalForm.verify(
            signature,
            fields: Self.fields(
                type: type,
                fromIndex: fromIndex,
                toIndex: toIndex,
                trackId: trackId,
                revision: revision,
                issuedAtMillis: issuedAtMillis,
                nonce: nonce,
                sessionId: sessionId
            ),
            secret: secret
        )
    }

    func isFresh(now: Date = Date()) -> Bool {
        let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
        let drift = abs(TimeInterval(nowMillis - issuedAtMillis) / 1000)
        return drift <= BonjourConstants.commandFreshnessWindow
    }

    private static func fields(
        type: MessageType,
        fromIndex: Int,
        toIndex: Int,
        trackId: String,
        revision: Int,
        issuedAtMillis: Int64,
        nonce: String,
        sessionId: String
    ) -> [String] {
        [
            sessionId,
            type.rawValue,
            String(fromIndex),
            String(toIndex),
            trackId,
            String(revision),
            String(issuedAtMillis),
            nonce,
        ]
    }
}

struct QueueLoadPayload: Codable, Equatable {
    static let maximumTrackCount = 300

    let trackIds: [String]
    let startIndex: Int
    let positionSeconds: Double
    let autoplay: Bool
    let issuedAtMillis: Int64
    let nonce: String
    let signature: String
    var sourceTitle: String? = nil
    var sourceKind: String? = nil

    static func create(
        trackIds: [String],
        startIndex: Int,
        positionSeconds: Double,
        autoplay: Bool,
        sourceTitle: String? = nil,
        sourceKind: String? = nil,
        sessionId: String,
        secret: Data
    ) -> QueueLoadPayload {
        let window = window(of: trackIds, around: startIndex)
        let issuedAtMillis = Int64(Date().timeIntervalSince1970 * 1000)
        let nonce = UUID().uuidString
        let signature = CanonicalForm.sign(
            fields(
                trackIds: window.ids, startIndex: window.index,
                positionSeconds: positionSeconds, autoplay: autoplay,
                issuedAtMillis: issuedAtMillis, nonce: nonce, sessionId: sessionId
            ),
            secret: secret
        )
        return QueueLoadPayload(
            trackIds: window.ids,
            startIndex: window.index,
            positionSeconds: positionSeconds,
            autoplay: autoplay,
            issuedAtMillis: issuedAtMillis,
            nonce: nonce,
            signature: signature,
            sourceTitle: sourceTitle?.isEmpty == false ? sourceTitle : nil,
            sourceKind: sourceTitle?.isEmpty == false ? sourceKind : nil
        )
    }

    static func window(of ids: [String], around index: Int) -> (ids: [String], index: Int) {
        guard ids.count > maximumTrackCount else { return (ids, index) }
        let clamped = max(0, min(index, ids.count - 1))
        let lead = min(clamped, maximumTrackCount / 6)
        let lower = clamped - lead
        let upper = min(ids.count, lower + maximumTrackCount)
        return (Array(ids[lower..<upper]), clamped - lower)
    }

    func verify(sessionId: String, secret: Data) -> Bool {
        CanonicalForm.verify(
            signature,
            fields: Self.fields(
                trackIds: trackIds, startIndex: startIndex,
                positionSeconds: positionSeconds, autoplay: autoplay,
                issuedAtMillis: issuedAtMillis, nonce: nonce, sessionId: sessionId
            ),
            secret: secret
        )
    }

    func isFresh(now: Date = Date()) -> Bool {
        let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
        return abs(TimeInterval(nowMillis - issuedAtMillis) / 1000)
            <= BonjourConstants.commandFreshnessWindow
    }

    private static func fields(
        trackIds: [String],
        startIndex: Int,
        positionSeconds: Double,
        autoplay: Bool,
        issuedAtMillis: Int64,
        nonce: String,
        sessionId: String
    ) -> [String] {
        [
            sessionId,
            MessageType.queueLoad.rawValue,
            String(trackIds.count),
        ] + trackIds + [
            String(startIndex),
            String(format: "%.3f", positionSeconds),
            autoplay ? "1" : "0",
            String(issuedAtMillis),
            nonce,
        ]
    }
}

enum CueSyncChunking {
    static let maxBatchSize = 400
}

struct CueSyncPayload: Codable, Equatable {
    let body: Data
    let cueCount: Int
    let dismissalCount: Int
    let issuedAtMillis: Int64
    let nonce: String
    let signature: String

    static func create(
        body: Data,
        cueCount: Int,
        dismissalCount: Int,
        sessionId: String,
        secret: Data
    ) -> CueSyncPayload {
        let issuedAtMillis = Int64(Date().timeIntervalSince1970 * 1000)
        let nonce = UUID().uuidString
        let signature = CanonicalForm.sign(
            fields(
                cueCount: cueCount, dismissalCount: dismissalCount, bodyDigest: Self.digest(body),
                nonce: nonce, issuedAtMillis: issuedAtMillis, sessionId: sessionId
            ),
            secret: secret
        )
        return CueSyncPayload(
            body: body, cueCount: cueCount, dismissalCount: dismissalCount,
            issuedAtMillis: issuedAtMillis, nonce: nonce, signature: signature
        )
    }

    func verify(sessionId: String, secret: Data) -> Bool {
        CanonicalForm.verify(
            signature,
            fields: Self.fields(
                cueCount: cueCount, dismissalCount: dismissalCount, bodyDigest: Self.digest(body),
                nonce: nonce, issuedAtMillis: issuedAtMillis, sessionId: sessionId
            ),
            secret: secret
        )
    }

    func isFresh(now: Date = Date()) -> Bool {
        let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
        return abs(TimeInterval(nowMillis - issuedAtMillis) / 1000) <= BonjourConstants.commandFreshnessWindow
    }

    private static func digest(_ body: Data) -> String {
        Data(SHA256.hash(data: body)).base64EncodedString()
    }

    private static func fields(
        cueCount: Int,
        dismissalCount: Int,
        bodyDigest: String,
        nonce: String,
        issuedAtMillis: Int64,
        sessionId: String
    ) -> [String] {
        [
            sessionId,
            MessageType.cueSync.rawValue,
            String(cueCount),
            String(dismissalCount),
            bodyDigest,
            nonce,
            String(issuedAtMillis),
        ]
    }
}

struct LikesSyncPayload: Codable, Equatable {
    let body: Data
    let accountId: String
    let recordCount: Int
    let isComplete: Bool
    let issuedAtMillis: Int64
    let nonce: String
    let signature: String

    static func create(
        body: Data,
        accountId: String,
        recordCount: Int,
        isComplete: Bool,
        sessionId: String,
        secret: Data
    ) -> LikesSyncPayload {
        let issuedAtMillis = Int64(Date().timeIntervalSince1970 * 1_000)
        let nonce = UUID().uuidString
        let fields = canonicalFields(
            body: body, accountId: accountId, recordCount: recordCount,
            isComplete: isComplete, issuedAtMillis: issuedAtMillis,
            nonce: nonce, sessionId: sessionId
        )
        return LikesSyncPayload(
            body: body,
            accountId: accountId,
            recordCount: recordCount,
            isComplete: isComplete,
            issuedAtMillis: issuedAtMillis,
            nonce: nonce,
            signature: CanonicalForm.sign(fields, secret: secret)
        )
    }

    func verify(sessionId: String, secret: Data) -> Bool {
        CanonicalForm.verify(
            signature,
            fields: Self.canonicalFields(
                body: body, accountId: accountId, recordCount: recordCount,
                isComplete: isComplete, issuedAtMillis: issuedAtMillis,
                nonce: nonce, sessionId: sessionId
            ),
            secret: secret
        )
    }

    func isFresh(now: Date = Date()) -> Bool {
        let nowMillis = Int64(now.timeIntervalSince1970 * 1_000)
        return abs(TimeInterval(nowMillis - issuedAtMillis) / 1_000)
            <= BonjourConstants.commandFreshnessWindow
    }

    private static func canonicalFields(
        body: Data,
        accountId: String,
        recordCount: Int,
        isComplete: Bool,
        issuedAtMillis: Int64,
        nonce: String,
        sessionId: String
    ) -> [String] {
        [
            sessionId, accountId, String(recordCount), isComplete ? "1" : "0",
            Data(SHA256.hash(data: body)).base64EncodedString(),
            String(issuedAtMillis), nonce,
        ]
    }
}

struct LocalMusicOfferPayload: Codable, Equatable {
    static let maximumBodyBytes = 16 * 1024

    let body: Data
    let issuedAtMillis: Int64
    let nonce: String
    let signature: String

    static func create(body: Data, sessionId: String, secret: Data, now: Date = Date()) -> LocalMusicOfferPayload {
        let issuedAtMillis = Int64(now.timeIntervalSince1970 * 1_000)
        let nonce = UUID().uuidString
        return LocalMusicOfferPayload(
            body: body,
            issuedAtMillis: issuedAtMillis,
            nonce: nonce,
            signature: CanonicalForm.sign(
                canonicalFields(body: body, issuedAtMillis: issuedAtMillis, nonce: nonce, sessionId: sessionId),
                secret: secret
            )
        )
    }

    func verify(sessionId: String, secret: Data) -> Bool {
        guard body.count <= Self.maximumBodyBytes else { return false }
        return CanonicalForm.verify(
            signature,
            fields: Self.canonicalFields(body: body, issuedAtMillis: issuedAtMillis, nonce: nonce, sessionId: sessionId),
            secret: secret
        )
    }

    func isFresh(now: Date = Date()) -> Bool {
        let nowMillis = Int64(now.timeIntervalSince1970 * 1_000)
        return abs(TimeInterval(nowMillis - issuedAtMillis) / 1_000)
            <= BonjourConstants.commandFreshnessWindow
    }

    private static func canonicalFields(body: Data, issuedAtMillis: Int64, nonce: String, sessionId: String) -> [String] {
        [
            sessionId, MessageType.localMusicOffer.rawValue,
            Data(SHA256.hash(data: body)).base64EncodedString(),
            String(issuedAtMillis), nonce,
        ]
    }
}

struct ContinueSessionPayload: Codable, Equatable {
    static let maximumBodyBytes = 32 * 1024

    let body: Data
    let issuedAtMillis: Int64
    let nonce: String
    let signature: String

    static func create(body: Data, sessionId: String, secret: Data, now: Date = Date()) -> ContinueSessionPayload {
        let issuedAtMillis = Int64(now.timeIntervalSince1970 * 1_000)
        let nonce = UUID().uuidString
        return ContinueSessionPayload(
            body: body,
            issuedAtMillis: issuedAtMillis,
            nonce: nonce,
            signature: CanonicalForm.sign(
                canonicalFields(body: body, issuedAtMillis: issuedAtMillis, nonce: nonce, sessionId: sessionId),
                secret: secret
            )
        )
    }

    func verify(sessionId: String, secret: Data) -> Bool {
        guard body.count <= Self.maximumBodyBytes else { return false }
        return CanonicalForm.verify(
            signature,
            fields: Self.canonicalFields(body: body, issuedAtMillis: issuedAtMillis, nonce: nonce, sessionId: sessionId),
            secret: secret
        )
    }

    func isFresh(now: Date = Date()) -> Bool {
        let nowMillis = Int64(now.timeIntervalSince1970 * 1_000)
        return abs(TimeInterval(nowMillis - issuedAtMillis) / 1_000)
            <= BonjourConstants.commandFreshnessWindow
    }

    private static func canonicalFields(body: Data, issuedAtMillis: Int64, nonce: String, sessionId: String) -> [String] {
        [
            sessionId, MessageType.continueSession.rawValue,
            Data(SHA256.hash(data: body)).base64EncodedString(),
            String(issuedAtMillis), nonce,
        ]
    }
}

enum ControlDeck: Int, Codable, Equatable {
    case none = -1
    case a = 0
    case b = 1
}

enum ControlParameter: String, Codable, Equatable {
    case none
    case position      // seconds, absolute
    case nudge         // seconds, relative — the scratch/skim primitive
    case crossfade     // 0…1, A→B
    case eqLow, eqMid, eqHigh   // decibels
    case filterCutoff  // Hz
    case filterResonance
    case rate          // multiplier, 1.0 = original tempo
    case loopStart, loopLength  // seconds
    case loopBeats     // quantized musical beats
    case profile       // DJProfile.all index
    case highPassCutoff
}

struct ControlCommandPayload: Codable, Equatable {
    let deck: ControlDeck
    let parameter: ControlParameter
    let value: Double
    let value2: Double
    let sequence: Int64
    let issuedAtMillis: Int64
    let nonce: String
    let signature: String

    static func create(
        type: MessageType,
        deck: ControlDeck = .none,
        parameter: ControlParameter = .none,
        value: Double = 0,
        value2: Double = 0,
        sequence: Int64 = 0,
        sessionId: String,
        secret: Data
    ) -> ControlCommandPayload {
        let issuedAtMillis = Int64(Date().timeIntervalSince1970 * 1000)
        let nonce = UUID().uuidString
        let signature = CanonicalForm.sign(
            fields(
                type: type, deck: deck, parameter: parameter,
                value: value, value2: value2, sequence: sequence,
                issuedAtMillis: issuedAtMillis, nonce: nonce, sessionId: sessionId
            ),
            secret: secret
        )
        return ControlCommandPayload(
            deck: deck, parameter: parameter, value: value, value2: value2,
            sequence: sequence, issuedAtMillis: issuedAtMillis,
            nonce: nonce, signature: signature
        )
    }

    func verify(type: MessageType, sessionId: String, secret: Data) -> Bool {
        CanonicalForm.verify(
            signature,
            fields: Self.fields(
                type: type, deck: deck, parameter: parameter,
                value: value, value2: value2, sequence: sequence,
                issuedAtMillis: issuedAtMillis, nonce: nonce, sessionId: sessionId
            ),
            secret: secret
        )
    }

    func isFresh(now: Date = Date()) -> Bool {
        let nowMillis = Int64(now.timeIntervalSince1970 * 1000)
        return abs(TimeInterval(nowMillis - issuedAtMillis) / 1000)
            <= BonjourConstants.commandFreshnessWindow
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    private static func fields(
        type: MessageType,
        deck: ControlDeck,
        parameter: ControlParameter,
        value: Double,
        value2: Double,
        sequence: Int64,
        issuedAtMillis: Int64,
        nonce: String,
        sessionId: String
    ) -> [String] {
        [
            sessionId,
            type.rawValue,
            String(deck.rawValue),
            parameter.rawValue,
            number(value),
            number(value2),
            String(sequence),
            String(issuedAtMillis),
            nonce,
        ]
    }
}

struct SequenceGate {
    private var last: [String: Int64] = [:]

    private static func key(_ type: MessageType, _ deck: ControlDeck) -> String {
        "\(type.rawValue)#\(deck.rawValue)"
    }

    mutating func admit(_ sequence: Int64, type: MessageType, deck: ControlDeck) -> Bool {
        let k = Self.key(type, deck)
        guard sequence > (last[k] ?? 0) else { return false }
        last[k] = sequence
        return true
    }

    mutating func reset() { last.removeAll() }
}

enum RemoteRepeatMode: String, CaseIterable, Equatable {
    case off
    case all
    case one

    var wireValue: Double {
        switch self {
        case .off: return 0
        case .all: return 1
        case .one: return 2
        }
    }

    init?(wireValue: Double) {
        guard let mode = Self.allCases.first(where: { $0.wireValue == wireValue.rounded() }) else { return nil }
        self = mode
    }
}

struct PlaybackModesPayload: Codable, Equatable {
    let isShuffleEnabled: Bool
    let repeatMode: String
    let signature: String

    var remoteRepeatMode: RemoteRepeatMode? { RemoteRepeatMode(rawValue: repeatMode) }

    static func create(
        isShuffleEnabled: Bool,
        repeatMode: RemoteRepeatMode,
        revision: Int,
        issuedAtMillis: Int64,
        sessionId: String,
        secret: Data
    ) -> PlaybackModesPayload {
        PlaybackModesPayload(
            isShuffleEnabled: isShuffleEnabled,
            repeatMode: repeatMode.rawValue,
            signature: CanonicalForm.sign(
                fields(
                    isShuffleEnabled: isShuffleEnabled, repeatMode: repeatMode.rawValue,
                    revision: revision, issuedAtMillis: issuedAtMillis, sessionId: sessionId
                ),
                secret: secret
            )
        )
    }

    func verify(revision: Int, issuedAtMillis: Int64, sessionId: String, secret: Data) -> Bool {
        CanonicalForm.verify(
            signature,
            fields: Self.fields(
                isShuffleEnabled: isShuffleEnabled, repeatMode: repeatMode,
                revision: revision, issuedAtMillis: issuedAtMillis, sessionId: sessionId
            ),
            secret: secret
        )
    }

    private static func fields(
        isShuffleEnabled: Bool,
        repeatMode: String,
        revision: Int,
        issuedAtMillis: Int64,
        sessionId: String
    ) -> [String] {
        [
            sessionId,
            "playback_modes",
            String(revision),
            String(issuedAtMillis),
            isShuffleEnabled ? "1" : "0",
            repeatMode,
        ]
    }
}

struct PlaybackStatePayload: Codable, Equatable {
    let isPlaying: Bool
    let positionSeconds: Double
    let durationSeconds: Double
    let trackId: String?
    let title: String?
    let artist: String?
    let artworkURL: String?
    let isDJEngineLive: Bool
    let revision: Int
    let issuedAtMillis: Int64
    let signature: String
    var rate: Double? = nil
    var modes: PlaybackModesPayload? = nil
    var volume: Double? = nil
    var sleepTimer: SleepTimerStatePayload? = nil

    var effectiveRate: Double { rate ?? 1 }

    var sleepTimerStatus: SleepTimerStatus? { sleepTimer?.status }

    var effectiveVolume: Double? {
        guard let volume, volume.isFinite else { return nil }
        return min(1, max(0, volume))
    }

    static func create(
        isPlaying: Bool,
        positionSeconds: Double,
        durationSeconds: Double,
        trackId: String?,
        title: String?,
        artist: String?,
        artworkURL: String?,
        isDJEngineLive: Bool,
        rate: Double = 1,
        isShuffleEnabled: Bool? = nil,
        repeatMode: RemoteRepeatMode? = nil,
        volume: Double? = nil,
        sleepTimer: SleepTimerStatus? = nil,
        revision: Int,
        sessionId: String,
        secret: Data
    ) -> PlaybackStatePayload {
        let issuedAtMillis = Int64(Date().timeIntervalSince1970 * 1000)
        let wireRate: Double? = abs(rate - 1) < 0.0005 ? nil : rate
        let signature = CanonicalForm.sign(
            fields(
                isPlaying: isPlaying, positionSeconds: positionSeconds,
                durationSeconds: durationSeconds, trackId: trackId,
                isDJEngineLive: isDJEngineLive, rate: wireRate, revision: revision,
                issuedAtMillis: issuedAtMillis, sessionId: sessionId
            ),
            secret: secret
        )
        return PlaybackStatePayload(
            isPlaying: isPlaying, positionSeconds: positionSeconds,
            durationSeconds: durationSeconds, trackId: trackId, title: title,
            artist: artist, artworkURL: artworkURL,
            isDJEngineLive: isDJEngineLive, revision: revision,
            issuedAtMillis: issuedAtMillis, signature: signature,
            rate: wireRate,
            modes: isShuffleEnabled.flatMap { shuffle in
                repeatMode.map { mode in
                    PlaybackModesPayload.create(
                        isShuffleEnabled: shuffle, repeatMode: mode, revision: revision,
                        issuedAtMillis: issuedAtMillis, sessionId: sessionId, secret: secret
                    )
                }
            },
            volume: volume.map { min(1, max(0, $0)) },
            sleepTimer: sleepTimer.map {
                SleepTimerStatePayload.create(
                    $0, revision: revision, issuedAtMillis: issuedAtMillis,
                    sessionId: sessionId, secret: secret
                )
            }
        )
    }

    func verify(sessionId: String, secret: Data) -> Bool {
        let base = CanonicalForm.verify(
            signature,
            fields: Self.fields(
                isPlaying: isPlaying, positionSeconds: positionSeconds,
                durationSeconds: durationSeconds, trackId: trackId,
                isDJEngineLive: isDJEngineLive, rate: rate, revision: revision,
                issuedAtMillis: issuedAtMillis, sessionId: sessionId
            ),
            secret: secret
        )
        guard base else { return false }
        if let modes, !modes.verify(revision: revision, issuedAtMillis: issuedAtMillis, sessionId: sessionId, secret: secret) {
            return false
        }
        if let sleepTimer, !sleepTimer.verify(revision: revision, issuedAtMillis: issuedAtMillis, sessionId: sessionId, secret: secret) {
            return false
        }
        return true
    }

    func estimatedPosition(elapsed: TimeInterval) -> Double {
        guard isPlaying else { return positionSeconds }
        let advanced = positionSeconds + max(0, elapsed) * effectiveRate
        return durationSeconds > 0 ? min(durationSeconds, advanced) : advanced
    }

    private static func fields(
        isPlaying: Bool,
        positionSeconds: Double,
        durationSeconds: Double,
        trackId: String?,
        isDJEngineLive: Bool,
        rate: Double?,
        revision: Int,
        issuedAtMillis: Int64,
        sessionId: String
    ) -> [String] {
        var out = [
            sessionId,
            MessageType.playbackState.rawValue,
            isPlaying ? "1" : "0",
            String(format: "%.3f", positionSeconds),
            String(format: "%.3f", durationSeconds),
            trackId ?? "",
            isDJEngineLive ? "1" : "0",
            String(revision),
            String(issuedAtMillis),
        ]
        if let rate {
            out.append(String(format: "%.4f", rate))
        }
        return out
    }
}

enum SleepTimerMode: Equatable, Hashable, Sendable {
    case minutes(Int)
    case endOfTrack
    case endOfMix

    static let minuteChoices = [15, 30, 45, 60]

    var wireKind: Double {
        switch self {
        case .minutes: return 1
        case .endOfTrack: return 2
        case .endOfMix: return 3
        }
    }

    var wireMinutes: Double {
        if case .minutes(let minutes) = self { return Double(minutes) }
        return 0
    }

    init?(wireKind: Double, minutes: Double) {
        switch Int(wireKind.rounded()) {
        case 1:
            guard minutes.isFinite else { return nil }
            let value = Int(minutes.rounded())
            guard (1...720).contains(value) else { return nil }
            self = .minutes(value)
        case 2: self = .endOfTrack
        case 3: self = .endOfMix
        default: return nil
        }
    }
}

struct SleepTimerStatus: Equatable, Sendable {
    var mode: SleepTimerMode
    var endsAt: Date?
}

struct SleepTimerStatePayload: Codable, Equatable {
    let kind: Int
    let minutes: Int
    let endsAtMillis: Int64?
    let signature: String

    var status: SleepTimerStatus? {
        guard let mode = SleepTimerMode(wireKind: Double(kind), minutes: Double(minutes)) else { return nil }
        return SleepTimerStatus(
            mode: mode,
            endsAt: endsAtMillis.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
        )
    }

    static func create(
        _ status: SleepTimerStatus,
        revision: Int,
        issuedAtMillis: Int64,
        sessionId: String,
        secret: Data
    ) -> SleepTimerStatePayload {
        let kind = Int(status.mode.wireKind)
        let minutes = Int(status.mode.wireMinutes)
        let endsAtMillis = status.endsAt.map { Int64($0.timeIntervalSince1970 * 1000) }
        return SleepTimerStatePayload(
            kind: kind,
            minutes: minutes,
            endsAtMillis: endsAtMillis,
            signature: CanonicalForm.sign(
                fields(kind: kind, minutes: minutes, endsAtMillis: endsAtMillis,
                       revision: revision, issuedAtMillis: issuedAtMillis, sessionId: sessionId),
                secret: secret
            )
        )
    }

    func verify(revision: Int, issuedAtMillis: Int64, sessionId: String, secret: Data) -> Bool {
        CanonicalForm.verify(
            signature,
            fields: Self.fields(kind: kind, minutes: minutes, endsAtMillis: endsAtMillis,
                                revision: revision, issuedAtMillis: issuedAtMillis, sessionId: sessionId),
            secret: secret
        )
    }

    private static func fields(
        kind: Int,
        minutes: Int,
        endsAtMillis: Int64?,
        revision: Int,
        issuedAtMillis: Int64,
        sessionId: String
    ) -> [String] {
        [
            sessionId,
            "sleep_timer",
            String(revision),
            String(issuedAtMillis),
            String(kind),
            String(minutes),
            endsAtMillis.map(String.init) ?? "",
        ]
    }
}

enum DJDeckRole: String, Codable, Equatable {
    case live
    case incoming
    case idle
}

struct DJDeckStatePayload: Codable, Equatable {
    let trackId: String?
    let title: String?
    let artist: String?
    let positionSeconds: Double
    let durationSeconds: Double
    let isPlaying: Bool
    let eqLowDb: Double
    let eqMidDb: Double
    let eqHighDb: Double
    let filterCutoffHz: Double
    let filterResonance: Double
    let rate: Double
    let bpm: Double?
    let loopStartSeconds: Double?
    let loopLengthSeconds: Double?
    let role: DJDeckRole?
    let level: Double?
    let peak: Double?
    let isClipping: Bool?
    let phaseErrorSeconds: Double?
    let highPassCutoffHz: Double?
    let delayWetMix: Double?

    init(
        trackId: String?, title: String?, artist: String?,
        positionSeconds: Double, durationSeconds: Double, isPlaying: Bool,
        eqLowDb: Double, eqMidDb: Double, eqHighDb: Double,
        filterCutoffHz: Double, filterResonance: Double, rate: Double,
        bpm: Double?, loopStartSeconds: Double?, loopLengthSeconds: Double?,
        role: DJDeckRole? = nil, level: Double? = nil, peak: Double? = nil,
        isClipping: Bool? = nil, phaseErrorSeconds: Double? = nil,
        highPassCutoffHz: Double? = nil, delayWetMix: Double? = nil
    ) {
        self.trackId = trackId
        self.title = title
        self.artist = artist
        self.positionSeconds = positionSeconds
        self.durationSeconds = durationSeconds
        self.isPlaying = isPlaying
        self.eqLowDb = eqLowDb
        self.eqMidDb = eqMidDb
        self.eqHighDb = eqHighDb
        self.filterCutoffHz = filterCutoffHz
        self.filterResonance = filterResonance
        self.rate = rate
        self.bpm = bpm
        self.loopStartSeconds = loopStartSeconds
        self.loopLengthSeconds = loopLengthSeconds
        self.role = role
        self.level = level
        self.peak = peak
        self.isClipping = isClipping
        self.phaseErrorSeconds = phaseErrorSeconds
        self.highPassCutoffHz = highPassCutoffHz
        self.delayWetMix = delayWetMix
    }
}

/// The platform-neutral automatic-mix decision sent from the TV to companion
/// apps. It lives beside the wire payload so every target that decodes remote
/// state, including widgets, compiles the exact same model.
struct DJAutomaticMixDecision: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case off
        case planning
        case preparing
        case armed
        case mixing
        case cutting
        case waiting
        case unavailable
    }

    let phase: Phase
    let profileName: String?
    let templateName: String?
    let headline: String
    let reasoning: String?
    let incomingTrackId: String?
    let mixPointSeconds: TimeInterval?
    let transitionSeconds: TimeInterval?
    let entrySeconds: TimeInterval?
    let score: Double?
    let isFallback: Bool
    var canExtend: Bool? = nil
    var energyTarget: Int? = nil
    var selectionReason: String? = nil

    var statusLabel: String {
        switch phase {
        case .off:         return "Manual"
        case .planning:    return "Planning"
        case .preparing:   return "Preparing"
        case .armed:       return isFallback ? "Cut armed" : "Mix armed"
        case .mixing:      return "Mixing"
        case .cutting:     return "Clean cut"
        case .waiting:     return "Listening"
        case .unavailable: return "Unavailable"
        }
    }

    func countdownText(currentTime: TimeInterval) -> String? {
        guard phase == .armed, let mixPointSeconds else { return nil }
        let remaining = mixPointSeconds - currentTime
        guard remaining > 0 else { return "Now" }
        let total = max(0, Int(remaining.rounded()))
        return String(format: "in %d:%02d", total / 60, total % 60)
    }
}

/// A display-safe projection of one executor stage. The action is deliberately
/// sent as the same human-readable summary used by the local consoles: remote
/// companions should explain the TV's plan, not grow a second executor model.
struct DJPlanStagePayload: Codable, Equatable, Sendable, Identifiable {
    let atSeconds: TimeInterval
    let deck: String
    let action: String
    let snap: String
    let durationSeconds: TimeInterval?

    init(
        atSeconds: TimeInterval,
        deck: String,
        action: String,
        snap: String,
        durationSeconds: TimeInterval? = nil
    ) {
        self.atSeconds = atSeconds
        self.deck = deck
        self.action = action
        self.snap = snap
        self.durationSeconds = durationSeconds
    }

    var id: String {
        "\(atSeconds)|\(deck)|\(action)|\(snap)"
    }
}

/// The upcoming or executing automatic-mix plan transported to companion
/// consoles. Values are optional only where the planner itself has no richer
/// answer; an absent `DJStatePayload.plan` remains backwards-compatible with
/// cached state written by older builds.
struct DJPlanPayload: Codable, Equatable, Sendable {
    let templateName: String?
    let profileName: String?
    let mixPointSeconds: TimeInterval
    let transitionSeconds: TimeInterval
    let entrySeconds: TimeInterval
    let reasoning: String
    let score: Double?
    let stages: [DJPlanStagePayload]
}

struct DJStatePayload: Codable, Equatable {
    let isEnabled: Bool
    let isEngineLive: Bool
    let isAutoMixEnabled: Bool
    let crossfade: Double
    let deckA: DJDeckStatePayload
    let deckB: DJDeckStatePayload
    let automaticMix: DJAutomaticMixDecision?
    let plan: DJPlanPayload?
    let revision: Int
    let issuedAtMillis: Int64
    let signature: String
    var live: Data? = nil
    var liveSignature: String? = nil
    var decksOpen: Bool? = nil
    var decksOpenSignature: String? = nil

    static func create(
        isEnabled: Bool,
        isEngineLive: Bool,
        isAutoMixEnabled: Bool,
        crossfade: Double,
        deckA: DJDeckStatePayload,
        deckB: DJDeckStatePayload,
        automaticMix: DJAutomaticMixDecision?,
        plan: DJPlanPayload? = nil,
        live: Data? = nil,
        decksOpen: Bool? = nil,
        revision: Int,
        sessionId: String,
        secret: Data
    ) -> DJStatePayload {
        let issuedAtMillis = Int64(Date().timeIntervalSince1970 * 1000)
        let signature = CanonicalForm.sign(
            fields(
                isEnabled: isEnabled, isEngineLive: isEngineLive,
                isAutoMixEnabled: isAutoMixEnabled, crossfade: crossfade,
                deckA: deckA, deckB: deckB,
                automaticMix: automaticMix, plan: plan, revision: revision,
                issuedAtMillis: issuedAtMillis, sessionId: sessionId
            ),
            secret: secret
        )
        return DJStatePayload(
            isEnabled: isEnabled, isEngineLive: isEngineLive,
            isAutoMixEnabled: isAutoMixEnabled, crossfade: crossfade,
            deckA: deckA, deckB: deckB, automaticMix: automaticMix, plan: plan, revision: revision,
            issuedAtMillis: issuedAtMillis, signature: signature,
            live: live,
            liveSignature: live.map {
                CanonicalForm.sign(liveFields($0, revision: revision, issuedAtMillis: issuedAtMillis, sessionId: sessionId), secret: secret)
            },
            decksOpen: decksOpen,
            decksOpenSignature: decksOpen.map {
                CanonicalForm.sign(decksFields($0, revision: revision, issuedAtMillis: issuedAtMillis, sessionId: sessionId), secret: secret)
            }
        )
    }

    func verifiedDecksOpen(sessionId: String, secret: Data) -> Bool? {
        guard let decksOpen, let decksOpenSignature else { return nil }
        let fields = Self.decksFields(decksOpen, revision: revision, issuedAtMillis: issuedAtMillis, sessionId: sessionId)
        return CanonicalForm.verify(decksOpenSignature, fields: fields, secret: secret) ? decksOpen : nil
    }

    private static func decksFields(_ decksOpen: Bool, revision: Int, issuedAtMillis: Int64, sessionId: String) -> [String] {
        [sessionId, "dj_decks", String(revision), String(issuedAtMillis), decksOpen ? "1" : "0"]
    }

    func verifiedLive(sessionId: String, secret: Data) -> Data? {
        guard let live, let liveSignature else { return nil }
        let fields = Self.liveFields(live, revision: revision, issuedAtMillis: issuedAtMillis, sessionId: sessionId)
        return CanonicalForm.verify(liveSignature, fields: fields, secret: secret) ? live : nil
    }

    private static func liveFields(_ live: Data, revision: Int, issuedAtMillis: Int64, sessionId: String) -> [String] {
        [sessionId, "dj_live", String(revision), String(issuedAtMillis), live.base64EncodedString()]
    }

    func verify(sessionId: String, secret: Data) -> Bool {
        CanonicalForm.verify(
            signature,
            fields: Self.fields(
                isEnabled: isEnabled, isEngineLive: isEngineLive,
                isAutoMixEnabled: isAutoMixEnabled, crossfade: crossfade,
                deckA: deckA, deckB: deckB,
                automaticMix: automaticMix, plan: plan, revision: revision,
                issuedAtMillis: issuedAtMillis, sessionId: sessionId
            ),
            secret: secret
        )
    }

    private static func deckFields(_ deck: DJDeckStatePayload) -> [String] {
        [
            deck.trackId ?? "",
            String(format: "%.3f", deck.positionSeconds),
            deck.isPlaying ? "1" : "0",
            deck.loopStartSeconds.map { String(format: "%.3f", $0) } ?? "",
            deck.loopLengthSeconds.map { String(format: "%.3f", $0) } ?? "",
        ]
    }

    private static func fields(
        isEnabled: Bool,
        isEngineLive: Bool,
        isAutoMixEnabled: Bool,
        crossfade: Double,
        deckA: DJDeckStatePayload,
        deckB: DJDeckStatePayload,
        automaticMix: DJAutomaticMixDecision?,
        plan: DJPlanPayload?,
        revision: Int,
        issuedAtMillis: Int64,
        sessionId: String
    ) -> [String] {
        [
            sessionId,
            MessageType.djState.rawValue,
            isEnabled ? "1" : "0",
            isEngineLive ? "1" : "0",
            isAutoMixEnabled ? "1" : "0",
            String(format: "%.6f", crossfade),
        ]
        + deckFields(deckA)
        + deckFields(deckB)
        + [
            CanonicalForm.digest(of: automaticMix),
            CanonicalForm.digest(of: plan),
            String(revision),
            String(issuedAtMillis),
        ]
    }
}

struct ReplayGuard {
    private var seen: [String] = []
    private var index: Set<String> = []
    private let capacity: Int

    init(capacity: Int = 256) {
        self.capacity = capacity
    }

    mutating func admit(_ nonce: String) -> Bool {
        guard !index.contains(nonce) else { return false }
        seen.append(nonce)
        index.insert(nonce)
        while seen.count > capacity {
            index.remove(seen.removeFirst())
        }
        return true
    }
}

struct TokenTransferMessage: Codable {
    let type: MessageType
    let sessionId: String
    let payload: TokenPayload?
    let error: String?
    let queue: QueueStatePayload?
    let command: QueueCommandPayload?
    let queueLoad: QueueLoadPayload?
    let control: ControlCommandPayload?
    let playback: PlaybackStatePayload?
    let dj: DJStatePayload?
    let cueSync: CueSyncPayload?
    let likesSync: LikesSyncPayload?
    let localMusicOffer: LocalMusicOfferPayload?
    let continueSession: ContinueSessionPayload?
    let numericHello: LinkConfirmationHelloPayload?
    let numericHelloAck: LinkConfirmationHelloAckPayload?
    let numericCredentials: LinkConfirmationCredentialsPayload?
    let numericConfirm: LinkConfirmationConfirmPayload?
    let sessionRequest: SessionRequestPayload?
    let sessionOffer: SessionOfferPayload?
    let authHandoffSessionOffer: AuthHandoffSessionOfferPayload?
    let chime: ChimeLinkPayload?
    let deviceStatus: DeviceStatusPayload?
    let revoke: LinkRevokePayload?
    var peer: LinkPeerIdentity?

    init(
        type: MessageType,
        sessionId: String,
        payload: TokenPayload? = nil,
        error: String? = nil,
        queue: QueueStatePayload? = nil,
        command: QueueCommandPayload? = nil,
        queueLoad: QueueLoadPayload? = nil,
        control: ControlCommandPayload? = nil,
        playback: PlaybackStatePayload? = nil,
        dj: DJStatePayload? = nil,
        cueSync: CueSyncPayload? = nil,
        likesSync: LikesSyncPayload? = nil,
        localMusicOffer: LocalMusicOfferPayload? = nil,
        continueSession: ContinueSessionPayload? = nil,
        numericHello: LinkConfirmationHelloPayload? = nil,
        numericHelloAck: LinkConfirmationHelloAckPayload? = nil,
        numericCredentials: LinkConfirmationCredentialsPayload? = nil,
        numericConfirm: LinkConfirmationConfirmPayload? = nil,
        sessionRequest: SessionRequestPayload? = nil,
        sessionOffer: SessionOfferPayload? = nil,
        authHandoffSessionOffer: AuthHandoffSessionOfferPayload? = nil,
        chime: ChimeLinkPayload? = nil,
        deviceStatus: DeviceStatusPayload? = nil,
        revoke: LinkRevokePayload? = nil,
        peer: LinkPeerIdentity? = nil
    ) {
        self.type = type
        self.sessionId = sessionId
        self.payload = payload
        self.error = error
        self.queue = queue
        self.command = command
        self.queueLoad = queueLoad
        self.control = control
        self.playback = playback
        self.dj = dj
        self.cueSync = cueSync
        self.likesSync = likesSync
        self.localMusicOffer = localMusicOffer
        self.continueSession = continueSession
        self.numericHello = numericHello
        self.numericHelloAck = numericHelloAck
        self.numericCredentials = numericCredentials
        self.numericConfirm = numericConfirm
        self.sessionRequest = sessionRequest
        self.sessionOffer = sessionOffer
        self.authHandoffSessionOffer = authHandoffSessionOffer
        self.chime = chime
        self.deviceStatus = deviceStatus
        self.revoke = revoke
        self.peer = peer
    }

    static func tokenTransfer(sessionId: String, payload: TokenPayload, peer: LinkPeerIdentity? = nil) -> TokenTransferMessage {
        TokenTransferMessage(type: .tokenTransfer, sessionId: sessionId, payload: payload, peer: peer)
    }

    static func acknowledgment(sessionId: String, payload: TokenPayload? = nil) -> TokenTransferMessage {
        TokenTransferMessage(type: .acknowledgment, sessionId: sessionId, payload: payload)
    }

    static func error(sessionId: String, message: String) -> TokenTransferMessage {
        TokenTransferMessage(type: .error, sessionId: sessionId, error: message)
    }

    static func tokenRejected(sessionId: String, message: String) -> TokenTransferMessage {
        TokenTransferMessage(type: .tokenRejected, sessionId: sessionId, error: message)
    }

    static func numericComparisonHello(sessionId: String, payload: LinkConfirmationHelloPayload) -> TokenTransferMessage {
        TokenTransferMessage(type: .numericComparisonHello, sessionId: sessionId, numericHello: payload)
    }

    static func numericComparisonHelloAck(sessionId: String, payload: LinkConfirmationHelloAckPayload) -> TokenTransferMessage {
        TokenTransferMessage(type: .numericComparisonHelloAck, sessionId: sessionId, numericHelloAck: payload)
    }

    static func numericComparisonConfirm(sessionId: String, ownerProof: String? = nil) -> TokenTransferMessage {
        TokenTransferMessage(
            type: .numericComparisonConfirm,
            sessionId: sessionId,
            numericConfirm: ownerProof.map { LinkConfirmationConfirmPayload(ownerProof: $0) }
        )
    }

    static func numericComparisonCredentials(sessionId: String, payload: LinkConfirmationCredentialsPayload) -> TokenTransferMessage {
        TokenTransferMessage(type: .numericComparisonCredentials, sessionId: sessionId, numericCredentials: payload)
    }

    static func numericComparisonDeclined(sessionId: String) -> TokenTransferMessage {
        TokenTransferMessage(type: .numericComparisonDeclined, sessionId: sessionId)
    }

    static func chime(_ type: MessageType, sessionId: String, payload: ChimeLinkPayload) -> TokenTransferMessage {
        TokenTransferMessage(type: type, sessionId: sessionId, chime: payload)
    }

    static func deviceStatus(sessionId: String, status: DeviceStatusPayload) -> TokenTransferMessage {
        TokenTransferMessage(type: .deviceStatus, sessionId: sessionId, deviceStatus: status)
    }

    static func linkRevoke(sessionId: String, secret: Data) -> TokenTransferMessage {
        TokenTransferMessage(
            type: .linkRevoke,
            sessionId: sessionId,
            revoke: .create(.linkRevoke, sessionId: sessionId, secret: secret)
        )
    }

    static func sessionRevoke(sessionId: String, secret: Data, accountId: String?, lineageDigest: String?) -> TokenTransferMessage {
        TokenTransferMessage(
            type: .sessionRevoke,
            sessionId: sessionId,
            revoke: .create(.sessionRevoke, accountId: accountId, lineageDigest: lineageDigest, sessionId: sessionId, secret: secret)
        )
    }

    func verifiedRevoke(sessionId expected: String, secret: Data) -> LinkRevokePayload? {
        guard type == .linkRevoke || type == .sessionRevoke,
              sessionId == expected,
              let revoke,
              revoke.verify(type, sessionId: expected, secret: secret),
              revoke.isFresh() else { return nil }
        return revoke
    }

    static func queueState(sessionId: String, queue: QueueStatePayload) -> TokenTransferMessage {
        TokenTransferMessage(type: .queueState, sessionId: sessionId, queue: queue)
    }

    static func queueCommand(
        _ type: MessageType,
        sessionId: String,
        command: QueueCommandPayload
    ) -> TokenTransferMessage {
        TokenTransferMessage(type: type, sessionId: sessionId, command: command)
    }

    static func queueLoad(sessionId: String, load: QueueLoadPayload) -> TokenTransferMessage {
        TokenTransferMessage(type: .queueLoad, sessionId: sessionId, queueLoad: load)
    }

    static func controlCommand(
        _ type: MessageType,
        sessionId: String,
        control: ControlCommandPayload
    ) -> TokenTransferMessage {
        TokenTransferMessage(type: type, sessionId: sessionId, control: control)
    }

    static func playbackState(sessionId: String, playback: PlaybackStatePayload) -> TokenTransferMessage {
        TokenTransferMessage(type: .playbackState, sessionId: sessionId, playback: playback)
    }

    static func djState(sessionId: String, dj: DJStatePayload) -> TokenTransferMessage {
        TokenTransferMessage(type: .djState, sessionId: sessionId, dj: dj)
    }

    static func cueSync(sessionId: String, payload: CueSyncPayload) -> TokenTransferMessage {
        TokenTransferMessage(type: .cueSync, sessionId: sessionId, cueSync: payload)
    }

    static func likesSync(sessionId: String, payload: LikesSyncPayload) -> TokenTransferMessage {
        TokenTransferMessage(type: .likesSync, sessionId: sessionId, likesSync: payload)
    }

    static func localMusicOffer(sessionId: String, payload: LocalMusicOfferPayload) -> TokenTransferMessage {
        TokenTransferMessage(type: .localMusicOffer, sessionId: sessionId, localMusicOffer: payload)
    }

    static func continueSession(sessionId: String, payload: ContinueSessionPayload) -> TokenTransferMessage {
        TokenTransferMessage(type: .continueSession, sessionId: sessionId, continueSession: payload)
    }

    static func localMusicRequest(sessionId: String) -> TokenTransferMessage {
        TokenTransferMessage(type: .localMusicRequest, sessionId: sessionId)
    }

    static func sessionRequest(sessionId: String, request: SessionRequestPayload) -> TokenTransferMessage {
        TokenTransferMessage(type: .sessionRequest, sessionId: sessionId, sessionRequest: request)
    }

    static func sessionOffer(sessionId: String, offer: SessionOfferPayload) -> TokenTransferMessage {
        TokenTransferMessage(type: .sessionOffer, sessionId: sessionId, sessionOffer: offer)
    }

    static func sessionUnavailable(sessionId: String) -> TokenTransferMessage {
        TokenTransferMessage(type: .sessionUnavailable, sessionId: sessionId)
    }

    static func authHandoffSessionRequest(sessionId: String) -> TokenTransferMessage {
        TokenTransferMessage(type: .authHandoffSessionRequest, sessionId: sessionId)
    }

    static func authHandoffSessionOffer(sessionId: String, offer: AuthHandoffSessionOfferPayload) -> TokenTransferMessage {
        TokenTransferMessage(type: .authHandoffSessionOffer, sessionId: sessionId, authHandoffSessionOffer: offer)
    }

    func encode() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decode(from data: Data) throws -> TokenTransferMessage {
        try JSONDecoder().decode(TokenTransferMessage.self, from: data)
    }

    func framed() throws -> Data {
        MessageFraming.frame(try encode())
    }
}

enum MessageFraming {
    static let maxFrameBytes = 1 << 20

    static func frame(_ payload: Data) -> Data {
        let length = UInt32(payload.count)
        var out = Data(capacity: payload.count + 4)
        out.append(UInt8(truncatingIfNeeded: length >> 24))
        out.append(UInt8(truncatingIfNeeded: length >> 16))
        out.append(UInt8(truncatingIfNeeded: length >> 8))
        out.append(UInt8(truncatingIfNeeded: length))
        out.append(payload)
        return out
    }
}

struct MessageFramer {
    enum FramingError: Error {
        case oversizedFrame(Int)
    }

    private var buffer: [UInt8] = []

    mutating func append(_ data: Data) {
        buffer.append(contentsOf: data)
    }

    mutating func next() throws -> TokenTransferMessage? {
        if buffer.first == UInt8(ascii: "{") {
            guard let message = try? TokenTransferMessage.decode(from: Data(buffer)) else {
                return nil
            }
            buffer.removeAll(keepingCapacity: true)
            return message
        }

        guard buffer.count >= 4 else { return nil }
        let length = (Int(buffer[0]) << 24) | (Int(buffer[1]) << 16)
            | (Int(buffer[2]) << 8) | Int(buffer[3])
        guard length > 0, length <= MessageFraming.maxFrameBytes else {
            throw FramingError.oversizedFrame(length)
        }
        guard buffer.count >= 4 + length else { return nil }

        let body = Data(buffer[4..<(4 + length)])
        buffer.removeFirst(4 + length)
        return try TokenTransferMessage.decode(from: body)
    }
}

// MARK: - Companion channel

enum CompanionEndpoint {
    static func serviceName(sessionId: String) -> String {
        "\(BonjourConstants.companionServiceName)-\(sessionId.prefix(8))"
    }

    static func isCompanionService(_ name: String, sessionId: String) -> Bool {
        name.hasPrefix(BonjourConstants.companionServiceName) && name.contains(sessionId.prefix(8))
    }

    static func makeBrowser() -> NWBrowser {
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        return NWBrowser(
            for: .bonjour(type: BonjourConstants.serviceType, domain: BonjourConstants.serviceDomain),
            using: parameters
        )
    }

    static func listenerParameters(sessionId: String, secret: Data) -> NWParameters {
        let parameters = baseParameters(sessionId: sessionId, secret: secret)
        detectDeadPeers(parameters)
        return parameters
    }

    static func clientParameters(sessionId: String, secret: Data, keepalive: Bool = true) -> NWParameters {
        let parameters = baseParameters(sessionId: sessionId, secret: secret)
        if keepalive { detectDeadPeers(parameters) }
        return parameters
    }

    private static func baseParameters(sessionId: String, secret: Data) -> NWParameters {
        let parameters = LinkTLS.makeParameters(sessionId: sessionId, secret: secret, info: LinkTLS.companionPSKInfo)
        parameters.includePeerToPeer = false
        return parameters
    }

    private static func detectDeadPeers(_ parameters: NWParameters) {
        guard let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options else { return }
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 3
        tcp.keepaliveCount = 3
        tcp.connectionDropTime = 15
    }
}

struct CompanionCommandSigner {
    let sessionId: String
    let secret: Data

    func queue(
        _ type: MessageType,
        fromIndex: Int = -1,
        toIndex: Int = -1,
        trackId: String = "",
        revision: Int
    ) -> TokenTransferMessage {
        let command = QueueCommandPayload.create(
            type: type, fromIndex: fromIndex, toIndex: toIndex, trackId: trackId,
            revision: max(0, revision), sessionId: sessionId, secret: secret
        )
        return .queueCommand(type, sessionId: sessionId, command: command)
    }

    func load(
        trackIds: [String],
        startIndex: Int,
        positionSeconds: Double,
        autoplay: Bool,
        sourceTitle: String? = nil,
        sourceKind: String? = nil
    ) -> TokenTransferMessage {
        let load = QueueLoadPayload.create(
            trackIds: trackIds, startIndex: startIndex, positionSeconds: positionSeconds,
            autoplay: autoplay, sourceTitle: sourceTitle, sourceKind: sourceKind,
            sessionId: sessionId, secret: secret
        )
        return .queueLoad(sessionId: sessionId, load: load)
    }

    func control(
        _ type: MessageType,
        deck: ControlDeck = .none,
        parameter: ControlParameter = .none,
        value: Double = 0,
        value2: Double = 0,
        sequence: Int64 = 0
    ) -> TokenTransferMessage {
        let control = ControlCommandPayload.create(
            type: type, deck: deck, parameter: parameter, value: value, value2: value2,
            sequence: sequence, sessionId: sessionId, secret: secret
        )
        return .controlCommand(type, sessionId: sessionId, control: control)
    }
}

@MainActor
final class CompanionChannel {
    enum Event {
        case ready
        case waiting(String)
        case failed(String)
        case closed
    }

    let connection: NWConnection
    private(set) var lastError: NWError?
    private var framer = MessageFramer()
    private var onEvent: (Event) -> Void = { _ in }
    private var onMessage: (TokenTransferMessage) async -> Void = { _ in }
    private var isFinished = false

    init(to endpoint: NWEndpoint, sessionId: String, secret: Data, keepalive: Bool = true) {
        connection = NWConnection(
            to: endpoint,
            using: CompanionEndpoint.clientParameters(sessionId: sessionId, secret: secret, keepalive: keepalive)
        )
    }

    func start(
        onEvent: @escaping (Event) -> Void,
        onMessage: @escaping (TokenTransferMessage) async -> Void
    ) {
        self.onEvent = onEvent
        self.onMessage = onMessage
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handle(state) }
        }
        connection.start(queue: .main)
        receive()
    }

    func cancel() {
        isFinished = true
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    func send(_ message: TokenTransferMessage, completion: (@MainActor @Sendable (NWError?) -> Void)? = nil) {
        guard !isFinished, let data = try? message.framed() else { return }
        connection.send(content: data, completion: .contentProcessed { error in
            guard let completion else { return }
            Task { @MainActor in completion(error) }
        })
    }

    private func handle(_ state: NWConnection.State) {
        guard !isFinished else { return }
        switch state {
        case .ready:
            onEvent(.ready)
        case .waiting(let error):
            lastError = error
            onEvent(.waiting(error.localizedDescription))
        case .failed(let error):
            lastError = error
            finish(.failed(error.localizedDescription))
        case .cancelled:
            finish(.closed)
        default:
            break
        }
    }

    private func finish(_ event: Event) {
        guard !isFinished else { return }
        isFinished = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        onEvent(event)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, !self.isFinished else { return }
                if let error {
                    self.lastError = error
                    self.finish(.failed(error.localizedDescription))
                    return
                }
                if let data, !data.isEmpty {
                    self.framer.append(data)
                    while !self.isFinished {
                        do {
                            guard let message = try self.framer.next() else { break }
                            await self.onMessage(message)
                        } catch is MessageFramer.FramingError {
                            self.finish(.failed("Malformed frame"))
                            return
                        } catch {
                            continue
                        }
                    }
                }
                if isComplete {
                    self.finish(.closed)
                } else if !self.isFinished {
                    self.receive()
                }
            }
        }
    }
}

struct LinkOffer: Codable, Equatable {
    let sessionId: String
    let secretBase64: String
    let createdAt: Date
    let tvName: String

    var secret: Data? { Data(base64Encoded: secretBase64) }

    var isExpired: Bool {
        Date().timeIntervalSince(createdAt) > BonjourConstants.sessionTimeout
    }
}

struct SessionCredentials {
    let sessionId: String
    let secret: Data
    let createdAt: Date

    var isExpired: Bool {
        Date().timeIntervalSince(createdAt) > BonjourConstants.sessionTimeout
    }

    static func generate() -> SessionCredentials? {
        let sessionId = UUID().uuidString
        var secretBytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, secretBytes.count, &secretBytes)
        guard result == errSecSuccess else { return nil }
        let secret = Data(secretBytes)
        return SessionCredentials(sessionId: sessionId, secret: secret, createdAt: Date())
    }

    var secretBase64URL: String {
        secret.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodeSecret(_ base64url: String) -> Data? {
        var base64 = base64url
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        while base64.count % 4 != 0 {
            base64 += "="
        }

        return Data(base64Encoded: base64)
    }
}

struct LinkRetryPolicy: Equatable {
    static let maximumAttempts = 3
    static let delays: [Double] = [1, 2, 4]

    private(set) var attempts = 0

    mutating func nextDelay() -> Double? {
        guard attempts < Self.maximumAttempts - 1 else { return nil }
        let delay = Self.delays[min(attempts, Self.delays.count - 1)]
        attempts += 1
        return delay
    }
}

enum LinkStep: CaseIterable {
    case findingTV
    case securing
    case waitingForTV
    case comparingCode

    var timeout: Double {
        switch self {
        case .findingTV: return 30
        case .securing: return 15
        case .waitingForTV: return 15
        case .comparingCode: return BonjourConstants.linkApprovalTimeout
        }
    }

    func timedOutMessage(peer: String) -> String {
        switch self {
        case .findingTV:
            return "Couldn't find your \(peer). Check that it's on the same Wi-Fi network and still showing Sounding, then try again."
        case .securing:
            return "Couldn't verify this \(peer). Open Sounding on it, choose Add a Device again, then try again."
        case .waitingForTV:
            return "Your \(peer) didn't answer. Keep it on and try again."
        case .comparingCode:
            return "The code expired. On your \(peer), choose Allow sooner, or try again."
        }
    }
}

struct SameAccountLinkOffer: Equatable {
    struct Candidate: Equatable {
        let sessionIdPrefix: String
        let name: String
        let kind: DeviceClass
    }

    enum Phase: Equatable {
        case hidden
        case suggested(Candidate)
        case linking(Candidate, since: Date)
        case failed(Candidate, message: String)
    }

    static let linkingTimeout: TimeInterval = 150

    private(set) var phase: Phase = .hidden
    private(set) var dismissed: Set<String> = []
    private(set) var linkedNames: Set<String> = []

    struct Advertised: Equatable {
        let sessionIdPrefix: String
        let name: String
        let kind: DeviceClass
        let accountHint: LinkAccountHint.Advert?
    }

    static func candidates(
        from offers: [Advertised],
        accountId: String?,
        deviceId: String,
        linked: Set<String> = []
    ) -> [Candidate] {
        guard let accountId, !accountId.isEmpty else { return [] }
        return offers.compactMap { offer in
            guard offer.kind == .tv,
                  let hint = offer.accountHint,
                  hint.matches(accountId: accountId),
                  !hint.isLinked(toDeviceId: deviceId),
                  !linked.contains(identity(name: offer.name, kind: offer.kind)) else { return nil }
            return Candidate(sessionIdPrefix: offer.sessionIdPrefix, name: offer.name, kind: offer.kind)
        }
    }

    static func identity(name: String, kind: DeviceClass) -> String {
        "\(kind.rawValue)|\(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    var suggestion: Candidate? {
        if case .suggested(let candidate) = phase { return candidate }
        return nil
    }

    mutating func observe(_ candidates: [Candidate], now: Date) {
        switch phase {
        case .linking(let candidate, let since):
            if now.timeIntervalSince(since) > Self.linkingTimeout {
                phase = .failed(candidate, message: "\(candidate.name) didn't finish linking. Try again from Devices.")
            }
            return
        case .failed:
            return
        case .hidden, .suggested:
            let fresh = candidates.first { !Self.isMember($0.name, of: dismissed) && !Self.isMember($0.name, of: linkedNames) }
            phase = fresh.map(Phase.suggested) ?? .hidden
        }
    }

    mutating func accept(now: Date) -> Candidate? {
        guard case .suggested(let candidate) = phase else { return nil }
        phase = .linking(candidate, since: now)
        return candidate
    }

    mutating func finish(succeeded: Bool, message: String? = nil) {
        guard case .linking(let candidate, _) = phase else { return }
        if succeeded {
            linkedNames.insert(candidate.name.lowercased())
            phase = .hidden
        } else {
            phase = .failed(candidate, message: message ?? "Couldn't link \(candidate.name). Try again.")
        }
    }

    mutating func dismiss() {
        switch phase {
        case .suggested(let candidate), .failed(let candidate, _):
            dismissed.insert(candidate.name.lowercased())
        case .linking, .hidden:
            break
        }
        phase = .hidden
    }

    mutating func retry() {
        guard case .failed(let candidate, _) = phase else { return }
        phase = .suggested(candidate)
    }

    private static func isMember(_ name: String, of set: Set<String>) -> Bool {
        set.contains(name.lowercased())
    }
}

enum SameAccountLinkPrompt: Equatable {
    case suggestion(name: String)
    case failed(name: String, message: String)

    init?(_ phase: SameAccountLinkOffer.Phase) {
        switch phase {
        case .suggested(let candidate): self = .suggestion(name: candidate.name)
        case .failed(let candidate, let message): self = .failed(name: candidate.name, message: message)
        case .hidden, .linking: return nil
        }
    }

    var name: String {
        switch self {
        case .suggestion(let name), .failed(let name, _): return name
        }
    }

    var title: String {
        switch self {
        case .suggestion(let name): return "\(name) is signed in to your account. Link it?"
        case .failed(let name, _): return "Couldn't Link \(name)"
        }
    }

    var message: String? {
        if case .failed(_, let message) = self { return message }
        return nil
    }

    var primaryAction: String {
        switch self {
        case .suggestion: return "Link"
        case .failed: return "Try Again"
        }
    }
}
