import Foundation

// Minimal stand-ins for the app-only seams `SubscriptionService.swift`
// references, so the real file compiles in a plain macOS executable.
//
// Only the *shape* is reproduced — enough to satisfy the compiler and let the
// pure resolution functions be called. Nothing here talks to the network, and
// nothing here holds a credential. `SubscriptionService`'s tier logic
// (`resolve`, `classify`, the product-id catalogue) is the genuine article,
// compiled from the same file the apps build.
//
// If the real `SoundCloudAPI` seam changes shape, this stops compiling — which
// is the intended failure mode. A silently-diverging stub would be worse than
// no CLI at all.

protocol SoundCloudCredentialSource: AnyObject {
    var accessToken: String? { get }
    var currentUser: User? { get }
    func waitForCurrentUser() async -> User?
    func refreshAccessToken() async -> Bool
    func handleUnauthorized() async
}

@MainActor
final class SoundCloudAPI {
    static let shared = SoundCloudAPI()

    /// Left nil in the CLI. `SubscriptionService.verifyNow()` bails out early
    /// on a nil token, so the singleton never attempts a network call — which
    /// is exactly what we want from a test harness.
    static var credentials: (any SoundCloudCredentialSource)?

    struct NotAvailable: Error {}

    func getCurrentUser() async throws -> User {
        throw NotAvailable()
    }
}

extension Notification.Name {
    static let sessionExpired = Notification.Name("sessionExpired")
}
