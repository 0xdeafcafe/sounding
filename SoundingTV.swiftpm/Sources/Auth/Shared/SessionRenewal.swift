import Foundation
import Synchronization

@MainActor
struct SoundCloudSessionRenewal {
    enum Phase: Equatable, Sendable {
        case beforeRefresh
        case afterFailure
    }

    enum SourceKind: String, Equatable, Sendable {
        case synced
        case linkedPeer
        case silentWeb
    }

    struct Candidate {
        var session: StoredSession
        var commit: @MainActor () -> Void = {}
    }

    struct Source {
        var kind: SourceKind
        var fetch: @MainActor (Phase) async -> Candidate?
    }

    enum Outcome: Equatable, Sendable {
        case refreshed
        case adopted(SourceKind)
        case temporarilyUnavailable
        case exhausted

        var renewed: Bool {
            switch self {
            case .refreshed, .adopted: return true
            case .temporarilyUnavailable, .exhausted: return false
            }
        }
    }

    struct Environment {
        var load: @MainActor () -> StoredSession?
        var save: @MainActor (StoredSession) -> Void
        var refresh: @MainActor (StoredSession) async -> SoundCloudTokenRefresh.Outcome
        var validate: @MainActor (String) async -> SoundCloudTokenValidation
        var isTrafficStopped: @MainActor () -> Bool
        var isRejectedLineage: @MainActor (StoredSession) -> Bool = { _ in false }
    }

    private enum Attempt {
        case accepted
        case unavailable
        case rejected
    }

    let environment: Environment
    let sources: [Source]

    static func digest(of session: StoredSession) -> String {
        SessionSyncBookkeeping.digest(
            oauthToken: session.oauthToken,
            refreshToken: session.refreshToken,
            clientId: session.clientId,
            expiresAtMillis: session.expiresAt.map { Int64($0.timeIntervalSince1970 * 1000) }
        )
    }

    func renew() async -> Outcome {
        guard !environment.isTrafficStopped() else { return .temporarilyUnavailable }
        guard let local = environment.load() else { return .exhausted }
        let localDigest = Self.digest(of: local)

        if let adopted = await adoptNewer(than: local) { return adopted }

        if local.canSelfRefresh, !environment.isRejectedLineage(local) {
            switch await environment.refresh(local) {
            case .succeeded(let credentials):
                environment.save(local.applying(credentials))
                return .refreshed
            case .transient:
                return .temporarilyUnavailable
            case .unrecoverable:
                if let rotated = environment.load(), rotated.canSelfRefresh, Self.digest(of: rotated) != localDigest {
                    return .refreshed
                }
            }
        }

        return await recover(restoring: environment.load() ?? local)
    }

    func recover() async -> Outcome {
        guard !environment.isTrafficStopped() else { return .temporarilyUnavailable }
        return await recover(restoring: environment.load())
    }

    func adoptNewer() async -> Outcome {
        guard !environment.isTrafficStopped() else { return .temporarilyUnavailable }
        guard let local = environment.load() else { return .exhausted }
        return await adoptNewer(than: local) ?? .temporarilyUnavailable
    }

    private func adoptNewer(than local: StoredSession) async -> Outcome? {
        let localDigest = Self.digest(of: local)
        for source in sources {
            guard let candidate = await source.fetch(.beforeRefresh),
                  !candidate.session.oauthToken.isEmpty,
                  !environment.isRejectedLineage(candidate.session),
                  Self.digest(of: candidate.session) != localDigest,
                  !candidate.session.isExpired || candidate.session.canSelfRefresh else { continue }
            if case .accepted = await attempt(candidate, restoring: local, keepWhenUnavailable: false) {
                return .adopted(source.kind)
            }
        }
        return nil
    }

    private func recover(restoring original: StoredSession?) async -> Outcome {
        var tried = Set<String>()
        if let original { tried.insert(Self.digest(of: original)) }

        for source in sources {
            if environment.isTrafficStopped() { return .temporarilyUnavailable }
            guard let candidate = await source.fetch(.afterFailure),
                  !candidate.session.oauthToken.isEmpty,
                  !environment.isRejectedLineage(candidate.session),
                  tried.insert(Self.digest(of: candidate.session)).inserted else { continue }
            switch await attempt(candidate, restoring: original, keepWhenUnavailable: true) {
            case .accepted:
                return .adopted(source.kind)
            case .unavailable:
                return .temporarilyUnavailable
            case .rejected:
                continue
            }
        }
        return environment.isTrafficStopped() ? .temporarilyUnavailable : .exhausted
    }

    private func attempt(
        _ candidate: Candidate,
        restoring original: StoredSession?,
        keepWhenUnavailable: Bool
    ) async -> Attempt {
        var session = candidate.session
        var didRefresh = false
        environment.save(session)

        let saved = Self.digest(of: candidate.session)
        func restore() {
            guard let original else { return }
            let current = environment.load().map(Self.digest(of:))
            guard current == saved || current == Self.digest(of: session) else { return }
            environment.save(original)
        }

        func unavailable() -> Attempt {
            if keepWhenUnavailable || didRefresh {
                candidate.commit()
            } else {
                restore()
            }
            return .unavailable
        }

        func validated() async -> Attempt? {
            switch await environment.validate(session.oauthToken) {
            case .valid:
                candidate.commit()
                return .accepted
            case .unavailable:
                return unavailable()
            case .rejected:
                return nil
            }
        }

        func refreshCandidate() async -> Attempt? {
            guard session.canSelfRefresh else {
                restore()
                return .rejected
            }
            switch await environment.refresh(session) {
            case .succeeded(let credentials):
                session = session.applying(credentials)
                environment.save(session)
                didRefresh = true
                return nil
            case .transient:
                return unavailable()
            case .unrecoverable:
                restore()
                return .rejected
            }
        }

        if session.isExpired, let verdict = await refreshCandidate() { return verdict }
        if let verdict = await validated() { return verdict }
        guard !didRefresh else {
            restore()
            return .rejected
        }
        if let verdict = await refreshCandidate() { return verdict }
        if let verdict = await validated() { return verdict }
        restore()
        return .rejected
    }
}

enum SoundCloudSessionRenewalTimeout {
    private final class Gate<T: Sendable>: Sendable {
        private let continuation = Mutex<CheckedContinuation<T?, Never>?>(nil)

        func install(_ value: CheckedContinuation<T?, Never>) {
            continuation.withLock { $0 = value }
        }

        func resume(_ value: T?) {
            let pending = continuation.withLock { current -> CheckedContinuation<T?, Never>? in
                defer { current = nil }
                return current
            }
            pending?.resume(returning: value)
        }
    }

    static func value<T: Sendable>(
        within duration: Duration,
        _ operation: @escaping @MainActor @Sendable () async -> T?
    ) async -> T? {
        let gate = Gate<T>()
        return await withCheckedContinuation { continuation in
            gate.install(continuation)
            let work = Task { @MainActor in gate.resume(await operation()) }
            Task {
                try? await Task.sleep(for: duration)
                work.cancel()
                gate.resume(nil)
            }
        }
    }
}

enum SilentWebReauthorizationPolicy {
    static let timeout: Duration = .seconds(15)
    static let startURL = URL(string: "https://m.soundcloud.com/signin")!
    static let navigationHosts: Set<String> = ["m.soundcloud.com", "secure.soundcloud.com"]
    static let appTokenCookieNames: Set<String> = [
        "oauth_token", "sc-token", "oauth_refresh_token", "oauth-refresh-token", "sc-refresh-token",
    ]
    static let accessCookieNames: Set<String> = ["oauth_token", "sc-token"]
    static let refreshCookieNames: Set<String> = ["oauth_refresh_token", "oauth-refresh-token", "sc-refresh-token"]

    static func allowsNavigation(to url: URL?, isMainFrame: Bool) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased() else { return false }
        if !isMainFrame, scheme == "about" { return true }
        guard scheme == "https", let host = url.host?.lowercased() else { return false }
        return navigationHosts.contains(host)
    }

    static func isTrustedMessageOrigin(scheme: String, host: String) -> Bool {
        let host = host.lowercased()
        return scheme.lowercased() == "https" && (host == "soundcloud.com" || host.hasSuffix(".soundcloud.com"))
    }

    static func isTrustedTokenURL(_ value: String) -> Bool {
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return false }
        return host == "soundcloud.com" || host.hasSuffix(".soundcloud.com")
    }

    static func isSigninCallback(_ url: URL) -> Bool {
        url.host?.lowercased() == "m.soundcloud.com" && url.path.hasPrefix("/signin/callback")
    }

    static func isSoundCloudCookieDomain(_ domain: String) -> Bool {
        let domain = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return domain == "soundcloud.com" || domain.hasSuffix(".soundcloud.com")
    }

    static func session(accessToken: String?, refreshToken: String?, clientId: String?, expiresAt: Date?) -> StoredSession? {
        guard let accessToken, !accessToken.isEmpty,
              let refreshToken, !refreshToken.isEmpty,
              let clientId, !clientId.isEmpty else { return nil }
        return StoredSession(oauthToken: accessToken, refreshToken: refreshToken, clientId: clientId, expiresAt: expiresAt)
    }
}
