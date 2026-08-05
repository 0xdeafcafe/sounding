import CryptoKit
import Foundation

/// A short-lived local-network companion link derived from the signed-in
/// SoundCloud session. It is used only for remote-control pairing (queue,
/// playback, DJ state). It must never be used to share the credential itself:
/// phone, iPad and Mac keep their own token pairs, and dependent devices get
/// their own token pairs brokered by a companion through the explicit auth
/// handoff flow.
///
/// This link is deliberately not persisted in the keychain: both devices must
/// still have a usable account session, and a sign out immediately removes the
/// ability to reconnect.
enum SharedSessionCompanionLink {
    struct Credentials: Sendable, Equatable {
        let sessionId: String
        let secret: Data
    }

    static func current() -> Credentials? {
        guard let session = DeviceSessionStore.load(), session.isUsable else { return nil }

        // Refresh tokens remain stable across access-token refreshes, so use
        // one when available. The access token is only a fallback for legacy
        // sessions which cannot refresh themselves.
        let seed = session.refreshToken?.isEmpty == false ? session.refreshToken! : session.oauthToken
        let digest = SHA256.hash(data: Data("sounding.shared-companion.v1:\(seed)".utf8))
        let bytes = Array(digest)
        let sessionId = bytes.prefix(12).map { String(format: "%02x", $0) }.joined()
        return Credentials(sessionId: sessionId, secret: Data(bytes))
    }
}
