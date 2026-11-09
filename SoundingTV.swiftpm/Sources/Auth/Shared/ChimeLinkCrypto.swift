import Foundation
import CryptoKit
import Security

enum ChimeLinkCrypto {
    static let protocolVersion = 2
    static let nonceLength = 32
    static let maximumNameLength = 64

    private static let transcriptLabel = Data("Sounding-Chime-Link-v2".utf8)
    private static let sessionLabel = Data("Sounding-Chime-v2 session".utf8)
    private static let transportLabel = Data("Sounding-Chime-v2 transport".utf8)

    enum Role: String {
        case tv
        case phone
    }

    struct Transcript: Equatable {
        let version: Int
        let sessionId: String
        let tvDeviceId: String
        let tvName: String
        let tvKind: String
        let phoneNonce: Data
        let tvNonce: Data

        var isWellFormed: Bool {
            version == ChimeLinkCrypto.protocolVersion
                && UUID(uuidString: sessionId) != nil
                && !tvDeviceId.isEmpty && tvDeviceId.utf8.count <= 64
                && !tvName.isEmpty && tvName.count <= ChimeLinkCrypto.maximumNameLength
                && !tvKind.isEmpty && tvKind.utf8.count <= 32
                && phoneNonce.count == ChimeLinkCrypto.nonceLength
                && tvNonce.count == ChimeLinkCrypto.nonceLength
                && phoneNonce != tvNonce
        }

        var encoded: Data {
            [
                transcriptLabel,
                Data(String(version).utf8),
                Data(sessionId.utf8),
                Data(tvDeviceId.utf8),
                Data(tvName.utf8),
                Data(tvKind.utf8),
                phoneNonce,
                tvNonce,
            ].reduce(into: Data()) { $0 += lengthPrefixed($1) }
        }

        var digest: Data { Data(SHA256.hash(data: encoded)) }
    }

    struct Session {
        let transcript: Transcript
        fileprivate let key: SymmetricKey
    }

    static func makeNonce() -> Data? {
        var bytes = [UInt8](repeating: 0, count: nonceLength)
        guard SecRandomCopyBytes(kSecRandomDefault, nonceLength, &bytes) == errSecSuccess else { return nil }
        return Data(bytes)
    }

    static func transcript(from payload: ChimeLinkPayload?, phoneNonce: Data, sessionIdPrefix: String) -> Transcript? {
        guard let payload,
              let version = payload.version,
              let sessionId = payload.sessionId,
              sessionId.hasPrefix(sessionIdPrefix),
              let tvDeviceId = payload.tvDeviceId,
              let tvName = payload.tvName,
              let tvKind = payload.tvKind,
              DeviceClass(rawValue: tvKind) != nil,
              let tvNonce = payload.nonceBase64.flatMap({ Data(base64Encoded: $0) }) else { return nil }
        let transcript = Transcript(
            version: version,
            sessionId: sessionId,
            tvDeviceId: tvDeviceId,
            tvName: tvName,
            tvKind: tvKind,
            phoneNonce: phoneNonce,
            tvNonce: tvNonce
        )
        return transcript.isWellFormed ? transcript : nil
    }

    static func session(code: ChimeCode, transcript: Transcript) -> Session? {
        guard transcript.isWellFormed else { return nil }
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: code.bytes),
            salt: transcript.digest,
            info: sessionLabel,
            outputByteCount: 32
        )
        return Session(transcript: transcript, key: key)
    }

    static func confirmation(_ session: Session, role: Role) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: confirmationMessage(session, role: role), using: confirmationKey(session, role: role)))
    }

    static func verifyConfirmation(_ provided: Data, session: Session, role: Role) -> Bool {
        guard provided.count == SHA256.byteCount else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            provided,
            authenticating: confirmationMessage(session, role: role),
            using: confirmationKey(session, role: role)
        )
    }

    static func seal(_ plaintext: Data, session: Session) throws -> Data {
        try ChaChaPoly.seal(plaintext, using: transportKey(session), authenticating: session.transcript.digest).combined
    }

    static func open(_ combined: Data, session: Session) throws -> Data {
        try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: combined), using: transportKey(session), authenticating: session.transcript.digest)
    }

    private static func confirmationKey(_ session: Session, role: Role) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: session.key,
            info: Data("Sounding-Chime-v2 confirm \(role.rawValue)".utf8),
            outputByteCount: 32
        )
    }

    private static func confirmationMessage(_ session: Session, role: Role) -> Data {
        lengthPrefixed(Data(role.rawValue.utf8)) + session.transcript.encoded
    }

    private static func transportKey(_ session: Session) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: session.key, info: transportLabel, outputByteCount: 32)
    }

    private static func lengthPrefixed(_ data: Data) -> Data {
        var length = UInt16(clamping: data.count).bigEndian
        return Data(bytes: &length, count: 2) + data
    }
}

struct ChimeCodeLedger {
    static let lifetime: Duration = .seconds(120)
    static let pendingLifetime: Duration = .seconds(60)
    static let failuresPerCode = 3
    static let hellosPerMinute = 12

    struct Live: Equatable {
        let code: ChimeCode
        let generation: UInt64
        let deadline: ContinuousClock.Instant
    }

    struct Pending {
        let session: ChimeLinkCrypto.Session
        let generation: UInt64
        let deadline: ContinuousClock.Instant
    }

    private(set) var generation: UInt64 = 0
    private var live: Live?
    private var failures = 0
    private var hellos: [ContinuousClock.Instant] = []

    mutating func rotate(to code: ChimeCode, at now: ContinuousClock.Instant) {
        generation &+= 1
        live = Live(code: code, generation: generation, deadline: now.advanced(by: Self.lifetime))
        failures = 0
    }

    mutating func retire() {
        generation &+= 1
        live = nil
        failures = 0
    }

    func live(at now: ContinuousClock.Instant) -> Live? {
        guard let live, live.generation == generation, now < live.deadline else { return nil }
        return live
    }

    mutating func admitHello(at now: ContinuousClock.Instant) -> Bool {
        hellos.removeAll { $0.duration(to: now) >= .seconds(60) }
        guard hellos.count < Self.hellosPerMinute else { return false }
        hellos.append(now)
        return true
    }

    func pending(_ session: ChimeLinkCrypto.Session, at now: ContinuousClock.Instant) -> Pending? {
        guard let live = live(at: now) else { return nil }
        return Pending(session: session, generation: live.generation, deadline: min(live.deadline, now.advanced(by: Self.pendingLifetime)))
    }

    func isRedeemable(_ pending: Pending, at now: ContinuousClock.Instant) -> Bool {
        guard let live = live(at: now) else { return false }
        return pending.generation == live.generation && now < pending.deadline
    }

    mutating func recordFailure() -> Bool {
        failures += 1
        return failures >= Self.failuresPerCode
    }

    mutating func redeem(_ pending: Pending, at now: ContinuousClock.Instant) -> Bool {
        guard isRedeemable(pending, at: now) else { return false }
        retire()
        return true
    }
}

struct ChimeAttemptBudget {
    static let attemptsPerCode = 6
    static let attemptsPerMinute = 20
    static let concurrentAttempts = 4

    private var perCode: [ChimeCode: Int] = [:]
    private var recent: [ContinuousClock.Instant] = []

    mutating func admit(_ code: ChimeCode, active: Int, at now: ContinuousClock.Instant) -> Bool {
        recent.removeAll { $0.duration(to: now) >= .seconds(60) }
        guard active < Self.concurrentAttempts,
              recent.count < Self.attemptsPerMinute,
              perCode[code, default: 0] < Self.attemptsPerCode else { return false }
        perCode[code, default: 0] += 1
        recent.append(now)
        return true
    }

    mutating func reset() {
        perCode = [:]
        recent = []
    }
}
