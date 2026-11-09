import Foundation

enum PhoneAppState: Equatable {
    case unconfigured

    case remoteOnly

    case ready
}

extension PhoneAppState {
    static func resolve(
        session: StoredSession?,
        isLinked: Bool,
        lastRefreshOutcome: SoundCloudTokenRefresh.Outcome?
    ) -> PhoneAppState {
        if hasUsableAccount(session: session, lastRefreshOutcome: lastRefreshOutcome) {
            return .ready
        }
        return isLinked ? .remoteOnly : .unconfigured
    }

    private static func hasUsableAccount(
        session: StoredSession?,
        lastRefreshOutcome: SoundCloudTokenRefresh.Outcome?
    ) -> Bool {
        guard let session else { return false }

        if session.isUsable { return true }

        if session.canSelfRefresh {
            return lastRefreshOutcome != .unrecoverable
        }

        return false
    }
}

struct LinkRequest: Identifiable, Equatable {
    let id = UUID()
    let sessionId: String
    let secret: Data

    static func == (lhs: LinkRequest, rhs: LinkRequest) -> Bool {
        lhs.sessionId == rhs.sessionId && lhs.secret == rhs.secret
    }
}

enum LoadFailure: Equatable {
    case notSignedIn

    case sessionRejected

    case cannotRenewSession

    case cannotReachRefresh

    case offline

    case server(Int)

    case rateLimited(until: Date?)

    case unreadableResponse

    case unknown(String)

    var isFault: Bool { self != .notSignedIn }

    enum Recovery: Equatable { case signIn, retry }

    var recovery: Recovery {
        switch self {
        case .notSignedIn, .sessionRejected, .cannotRenewSession: return .signIn
        case .cannotReachRefresh, .offline, .server, .rateLimited, .unreadableResponse, .unknown:
            return .retry
        }
    }

    var actionTitle: String {
        recovery == .signIn ? "Sign In" : "Try Again"
    }

    var icon: String {
        switch self {
        case .notSignedIn: return "person.crop.circle.badge.exclamationmark"
        default:           return "exclamationmark.triangle"
        }
    }

    var title: String {
        switch self {
        case .notSignedIn:        return "Not Signed In"
        case .sessionRejected:    return "Reconnect SoundCloud"
        case .cannotRenewSession: return "Reconnect SoundCloud"
        case .cannotReachRefresh: return "Couldn't Renew Sign-In"
        case .offline:            return "No Connection"
        case .server:             return "SoundCloud Is Having Trouble"
        case .rateLimited:        return "SoundCloud Is Limiting Requests"
        case .unreadableResponse: return "Unexpected Response"
        case .unknown:            return "Couldn't Load"
        }
    }

    func message(subject: String) -> String {
        switch self {
        case .notSignedIn:
            return "Sign in with your SoundCloud account to see \(subject)."
        case .sessionRejected:
            return "SoundCloud rejected this device's sign-in, so \(subject) can't load. Sign in again to continue."
        case .cannotRenewSession:
            return "This device can't renew its SoundCloud sign-in on its own. Signing in again fixes it."
        case .cannotReachRefresh:
            return "SoundCloud couldn't renew your sign-in right now. Your account is still saved; try again later."
        case .offline:
            return "Couldn't reach SoundCloud to load \(subject). Check your connection and try again."
        case .server(let code):
            return "SoundCloud couldn't serve \(subject) right now (error \(code)). This is usually temporary."
        case .rateLimited(let until):
            guard let until, until > .now else {
                return "Your sign-in is saved. \(subject.prefix(1).uppercased() + subject.dropFirst()) will load again in a little while."
            }
            return "Your sign-in is saved. \(subject.prefix(1).uppercased() + subject.dropFirst()) will load again after \(until.formatted(date: .omitted, time: .shortened))."
        case .unreadableResponse:
            return "SoundCloud sent something this version of the app couldn't read. Try again. If it keeps happening, the app needs an update."
        case .unknown(let description):
            return "Couldn't load \(subject). (\(description))"
        }
    }
}

extension LoadFailure {
    @MainActor
    static func classify(_ error: Error) -> LoadFailure {
        if let apiError = error as? APIError {
            switch apiError {
            case .unauthorized:
                return credentialFailure()
            case .networkError(let underlying):
                return classifyTransport(underlying)
            case .decodingError:
                return .unreadableResponse
            case .notFound:
                return .server(404)
            case .forbidden:
                return .server(403)
            case .serverError(let code):
                return code == 401 ? credentialFailure() : .server(code)
            case .rateLimited(let resetAt):
                return .rateLimited(until: resetAt)
            case .temporarilyBlocked(let until, _):
                return .rateLimited(until: until)
            case .invalidURL, .noStreamURL:
                return .unknown(apiError.errorDescription ?? "\(apiError)")
            }
        }
        return classifyTransport(error)
    }

    @MainActor
    static func credentialFailure() -> LoadFailure {
        switch SoundCloudCredentialSource.shared.sessionHealth {
        case .signedOut:
            return .notSignedIn
        case .rejected(.accountRejected):
            return .sessionRejected
        case .rejected(.noRefreshCapability):
            return .cannotRenewSession
        case .rejected(.refreshUnreachable):
            return .cannotReachRefresh
        case .healthy, .unverified:
            return .server(401)
        }
    }

    private static func classifyTransport(_ error: Error) -> LoadFailure {
        guard let urlError = error as? URLError else {
            return .unknown(String(describing: error))
        }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
             .cannotConnectToHost, .dnsLookupFailed, .timedOut,
             .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed:
            return .offline
        case .badServerResponse, .cannotParseResponse, .zeroByteResource:
            return .unreadableResponse
        default:
            return .unknown(urlError.localizedDescription)
        }
    }
}

extension Error {
    var isTaskCancellation: Bool {
        if self is CancellationError { return true }
        if let urlError = self as? URLError, urlError.code == .cancelled { return true }
        if let apiError = self as? APIError, case .networkError(let underlying) = apiError {
            return underlying.isTaskCancellation
        }
        return false
    }
}
