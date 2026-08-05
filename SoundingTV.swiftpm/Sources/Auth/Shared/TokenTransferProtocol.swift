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
//
// Synchronized multi-device listening room:
//   PolyphonyController over Bonjour `_polyphony._tcp`. Does not carry auth.

enum BonjourConstants {
    static let serviceType = "_soundingtv._tcp"
    static let serviceDomain = "local."
    static let serviceName = "SoundingTV-Link"

    static let companionServiceName = "SoundingTV-Companion"

    static let contentServiceName = "SoundingTV-Content"

    static let linkOfferServiceName = "SoundingTV-LinkOffer"

    static let sessionTimeout: TimeInterval = 300

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

    case queueState = "queue_state"

    case transportPlay     = "transport_play"
    case transportPause    = "transport_pause"
    case transportNext     = "transport_next"
    case transportPrevious = "transport_previous"
    case transportSeek     = "transport_seek"

    case djEnable    = "dj_enable"
    case djDisable   = "dj_disable"
    case djAutoEnable  = "dj_auto_enable"
    case djAutoDisable = "dj_auto_disable"
    case djProfile     = "dj_profile"
    case djMixNow    = "dj_mix_now"
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

    case cueSync = "cue_sync"
    case likesSync = "likes_sync"

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

    var isQueueCommand: Bool {
        switch self {
        case .queueRequest, .queueReorder, .queueRemove, .queueJump, .queueAdd, .queueReplace:
            return true
        default:
            return false
        }
    }

    var isControlCommand: Bool {
        switch self {
        case .transportPlay, .transportPause, .transportNext,
             .transportPrevious, .transportSeek,
             .djEnable, .djDisable, .djAutoEnable, .djAutoDisable, .djProfile,
             .djMixNow, .djLoopSet, .djLoopClear, .djCue, .djHotCueSet, .djDeckPlayPause, .djSync,
             .djCrossfader, .djEQ, .djFilter, .djRate, .djJog:
            return true
        default:
            return false
        }
    }

    var isContinuousControl: Bool {
        switch self {
        case .djCrossfader, .djEQ, .djFilter, .djRate, .djJog:
            return true
        default:
            return false
        }
    }
}

enum HandoffActivityType {
    static let link = "red.forbes.sounding.pairing"
    static let nowPlaying = "red.forbes.sounding.nowplaying"
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
}

enum SoundCloudTokenRefresh {

    struct Credentials: Equatable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Date?
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
            let (body, response) = try await URLSession.shared.data(for: request)
            guard let asHTTP = response as? HTTPURLResponse else { return .transient }
            data = body
            http = asHTTP
        } catch {
            Log.link.error("[TokenRefresh] request did not complete: \(error.localizedDescription, privacy: .public)")
            return .transient
        }

        switch http.statusCode {
        case 200..<300:
            break
        case 400, 401, 403:
            Log.link.error("[TokenRefresh] rejected: HTTP \(http.statusCode, privacy: .public) \(errorCode(in: data), privacy: .public)")
            return .unrecoverable
        default:
            Log.link.error("[TokenRefresh] inconclusive: HTTP \(http.statusCode, privacy: .public)")
            return .transient
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
            expiresAt: parsed.expires_in.map { Date(timeIntervalSinceNow: $0) }
        ))
    }

    private static func errorCode(in data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = json["error"] as? String else { return "" }
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

    private var inFlight: Task<SoundCloudTokenRefresh.Outcome, Never>?
    private var lastVerdict: (outcome: SoundCloudTokenRefresh.Outcome, wasLocalGuard: Bool, at: Date)?

    private var generation: UInt64 = 0

    var recentOutcome: SoundCloudTokenRefresh.Outcome? {
        guard let lastVerdict,
              Date().timeIntervalSince(lastVerdict.at) < Self.verdictLifetime else { return nil }
        return lastVerdict.outcome
    }

    var recentOutcomeWasLocalGuard: Bool {
        guard let lastVerdict,
              Date().timeIntervalSince(lastVerdict.at) < Self.verdictLifetime else { return false }
        return lastVerdict.wasLocalGuard
    }

    func reset() {
        inFlight?.cancel()
        inFlight = nil
        lastVerdict = nil
        generation &+= 1
    }

    func refresh(refreshToken: String?, clientId: String?) async -> SoundCloudTokenRefresh.Outcome {
        if let recentOutcome { return recentOutcome }
        if let inFlight { return await inFlight.value }

        guard let refreshToken, !refreshToken.isEmpty,
              let clientId, !clientId.isEmpty else {
            Log.link.error("[TokenRefresh] no refresh material held")
            let outcome = SoundCloudTokenRefresh.Outcome.unrecoverable
            lastVerdict = (outcome, true, Date())
            return outcome
        }

        let startedAt = generation
        let task = Task<SoundCloudTokenRefresh.Outcome, Never> {
            await SoundCloudTokenRefresh.perform(refreshToken: refreshToken, clientId: clientId)
        }
        inFlight = task
        let outcome = await task.value

        guard generation == startedAt else { return outcome }
        inFlight = nil
        lastVerdict = (outcome, false, Date())
        return outcome
    }
}

enum LinkTLS {
    static let pskInfo = Data("SoundingTV-Link-TLS-PSK-v1".utf8)

    static let contentPSKInfo = Data("SoundingTV-Content-TLS-PSK-v1".utf8)

    static let companionPSKInfo = Data("SoundingTV-Companion-TLS-PSK-v1".utf8)

    static let polyphonyPSKInfo = Data("Sounding-Polyphony-TLS-PSK-v1".utf8)

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

enum LinkOfferTXT {
    private static let nameKey = "name"
    private static let kindKey = "kind"
    private static let commitmentKey = "pkc"

    static func dictionary(name: String, kind: DeviceClass, commitment: Data) -> [String: String] {
        [nameKey: name, kindKey: kind.rawValue, commitmentKey: commitment.base64EncodedString()]
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

struct LinkConfirmationHelloPayload: Codable, Equatable {
    let ephemeralPublicKeyBase64: String
}

struct LinkConfirmationHelloAckPayload: Codable, Equatable {
    let ephemeralPublicKeyBase64: String
    let commitNonceBase64: String
}

struct LinkConfirmationCredentialsPayload: Codable, Equatable {
    let sealedBase64: String
}

enum LinkConfirmationCrypto {
    private static let codeInfo = Data("SoundingTV-LinkConfirmation-Code-v1".utf8)
    private static let transportInfo = Data("SoundingTV-LinkConfirmation-Transport-v1".utf8)

    private static func transcript(_ a: Data, _ b: Data) -> Data {
        let ordered = [a, b].sorted { $0.lexicographicallyPrecedes($1) }
        return ordered[0] + ordered[1]
    }

    static func commitment(nonce: Data, publicKey: Data) -> Data {
        Data(SHA256.hash(data: nonce + publicKey))
    }

    static func code(sharedSecret: SharedSecret, publicKeyA: Data, publicKeyB: Data, sessionId: String) -> String {
        let salt = Data(sessionId.utf8) + transcript(publicKeyA, publicKeyB)
        let key = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: codeInfo,
            outputByteCount: 4
        )
        let bytes = key.withUnsafeBytes { Array($0) }
        let value = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        return String(format: "%06u", value % 1_000_000)
    }

    static func transportKey(sharedSecret: SharedSecret, publicKeyA: Data, publicKeyB: Data, sessionId: String) -> SymmetricKey {
        let salt = Data(sessionId.utf8) + transcript(publicKeyA, publicKeyB)
        return sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: transportInfo,
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

    static func create(
        tracks: [QueueTrack],
        currentIndex: Int,
        isPlaying: Bool,
        revision: Int,
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
            signature: signature
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

    static func create(
        isPlaying: Bool,
        positionSeconds: Double,
        durationSeconds: Double,
        trackId: String?,
        title: String?,
        artist: String?,
        artworkURL: String?,
        isDJEngineLive: Bool,
        revision: Int,
        sessionId: String,
        secret: Data
    ) -> PlaybackStatePayload {
        let issuedAtMillis = Int64(Date().timeIntervalSince1970 * 1000)
        let signature = CanonicalForm.sign(
            fields(
                isPlaying: isPlaying, positionSeconds: positionSeconds,
                durationSeconds: durationSeconds, trackId: trackId,
                isDJEngineLive: isDJEngineLive, revision: revision,
                issuedAtMillis: issuedAtMillis, sessionId: sessionId
            ),
            secret: secret
        )
        return PlaybackStatePayload(
            isPlaying: isPlaying, positionSeconds: positionSeconds,
            durationSeconds: durationSeconds, trackId: trackId, title: title,
            artist: artist, artworkURL: artworkURL,
            isDJEngineLive: isDJEngineLive, revision: revision,
            issuedAtMillis: issuedAtMillis, signature: signature
        )
    }

    func verify(sessionId: String, secret: Data) -> Bool {
        CanonicalForm.verify(
            signature,
            fields: Self.fields(
                isPlaying: isPlaying, positionSeconds: positionSeconds,
                durationSeconds: durationSeconds, trackId: trackId,
                isDJEngineLive: isDJEngineLive, revision: revision,
                issuedAtMillis: issuedAtMillis, sessionId: sessionId
            ),
            secret: secret
        )
    }

    private static func fields(
        isPlaying: Bool,
        positionSeconds: Double,
        durationSeconds: Double,
        trackId: String?,
        isDJEngineLive: Bool,
        revision: Int,
        issuedAtMillis: Int64,
        sessionId: String
    ) -> [String] {
        [
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

    init(
        trackId: String?, title: String?, artist: String?,
        positionSeconds: Double, durationSeconds: Double, isPlaying: Bool,
        eqLowDb: Double, eqMidDb: Double, eqHighDb: Double,
        filterCutoffHz: Double, filterResonance: Double, rate: Double,
        bpm: Double?, loopStartSeconds: Double?, loopLengthSeconds: Double?,
        role: DJDeckRole? = nil, level: Double? = nil, peak: Double? = nil,
        isClipping: Bool? = nil, phaseErrorSeconds: Double? = nil
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

struct DJStatePayload: Codable, Equatable {
    let isEnabled: Bool
    let isEngineLive: Bool
    let isAutoMixEnabled: Bool
    let crossfade: Double
    let deckA: DJDeckStatePayload
    let deckB: DJDeckStatePayload
    let automaticMix: DJAutomaticMixDecision?
    let revision: Int
    let issuedAtMillis: Int64
    let signature: String

    static func create(
        isEnabled: Bool,
        isEngineLive: Bool,
        isAutoMixEnabled: Bool,
        crossfade: Double,
        deckA: DJDeckStatePayload,
        deckB: DJDeckStatePayload,
        automaticMix: DJAutomaticMixDecision?,
        revision: Int,
        sessionId: String,
        secret: Data
    ) -> DJStatePayload {
        let issuedAtMillis = Int64(Date().timeIntervalSince1970 * 1000)
        let signature = CanonicalForm.sign(
            fields(
                isEnabled: isEnabled, isEngineLive: isEngineLive,
                isAutoMixEnabled: isAutoMixEnabled, crossfade: crossfade,
                deckA: deckA, deckB: deckB, revision: revision,
                issuedAtMillis: issuedAtMillis, sessionId: sessionId
            ),
            secret: secret
        )
        return DJStatePayload(
            isEnabled: isEnabled, isEngineLive: isEngineLive,
            isAutoMixEnabled: isAutoMixEnabled, crossfade: crossfade,
            deckA: deckA, deckB: deckB, automaticMix: automaticMix, revision: revision,
            issuedAtMillis: issuedAtMillis, signature: signature
        )
    }

    func verify(sessionId: String, secret: Data) -> Bool {
        CanonicalForm.verify(
            signature,
            fields: Self.fields(
                isEnabled: isEnabled, isEngineLive: isEngineLive,
                isAutoMixEnabled: isAutoMixEnabled, crossfade: crossfade,
                deckA: deckA, deckB: deckB, revision: revision,
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
        + [String(revision), String(issuedAtMillis)]
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
    let control: ControlCommandPayload?
    let playback: PlaybackStatePayload?
    let dj: DJStatePayload?
    let cueSync: CueSyncPayload?
    let likesSync: LikesSyncPayload?
    let numericHello: LinkConfirmationHelloPayload?
    let numericHelloAck: LinkConfirmationHelloAckPayload?
    let numericCredentials: LinkConfirmationCredentialsPayload?
    let sessionRequest: SessionRequestPayload?
    let sessionOffer: SessionOfferPayload?
    let authHandoffSessionOffer: AuthHandoffSessionOfferPayload?

    init(
        type: MessageType,
        sessionId: String,
        payload: TokenPayload? = nil,
        error: String? = nil,
        queue: QueueStatePayload? = nil,
        command: QueueCommandPayload? = nil,
        control: ControlCommandPayload? = nil,
        playback: PlaybackStatePayload? = nil,
        dj: DJStatePayload? = nil,
        cueSync: CueSyncPayload? = nil,
        likesSync: LikesSyncPayload? = nil,
        numericHello: LinkConfirmationHelloPayload? = nil,
        numericHelloAck: LinkConfirmationHelloAckPayload? = nil,
        numericCredentials: LinkConfirmationCredentialsPayload? = nil,
        sessionRequest: SessionRequestPayload? = nil,
        sessionOffer: SessionOfferPayload? = nil,
        authHandoffSessionOffer: AuthHandoffSessionOfferPayload? = nil
    ) {
        self.type = type
        self.sessionId = sessionId
        self.payload = payload
        self.error = error
        self.queue = queue
        self.command = command
        self.control = control
        self.playback = playback
        self.dj = dj
        self.cueSync = cueSync
        self.likesSync = likesSync
        self.numericHello = numericHello
        self.numericHelloAck = numericHelloAck
        self.numericCredentials = numericCredentials
        self.sessionRequest = sessionRequest
        self.sessionOffer = sessionOffer
        self.authHandoffSessionOffer = authHandoffSessionOffer
    }

    static func tokenTransfer(sessionId: String, payload: TokenPayload) -> TokenTransferMessage {
        TokenTransferMessage(type: .tokenTransfer, sessionId: sessionId, payload: payload)
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

    static func numericComparisonConfirm(sessionId: String) -> TokenTransferMessage {
        TokenTransferMessage(type: .numericComparisonConfirm, sessionId: sessionId)
    }

    static func numericComparisonCredentials(sessionId: String, payload: LinkConfirmationCredentialsPayload) -> TokenTransferMessage {
        TokenTransferMessage(type: .numericComparisonCredentials, sessionId: sessionId, numericCredentials: payload)
    }

    static func numericComparisonDeclined(sessionId: String) -> TokenTransferMessage {
        TokenTransferMessage(type: .numericComparisonDeclined, sessionId: sessionId)
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
