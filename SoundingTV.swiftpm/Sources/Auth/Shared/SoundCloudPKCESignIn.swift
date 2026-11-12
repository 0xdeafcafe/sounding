import Foundation
import CryptoKit
import AuthenticationServices
import SwiftUI
import os

struct SoundCloudPKCESignIn {
    enum Failure: Error, Equatable {
        case canceled
        case stateMismatch
        case denied
        case missingCode
        case rejected
        case unavailable
    }

    static let clientId = "oDuGHdoKZgaZtpROWLLAJpikJUoEV2dr"
    static let appId = "124"
    static let callbackScheme = "soundcloud"
    static let redirectURI = "soundcloud://auth"
    private static let authorizeEndpoint = "https://secure.soundcloud.com/web-auth"
    private static let tokenEndpoint = "https://secure.soundcloud.com/oauth/token"
    private static let deviceIdKey = "red.forbes.sounding.pkce.deviceId"
    private static let anonymousIdKey = "red.forbes.sounding.pkce.anonymousId"

    static let enabledKey = "red.forbes.sounding.signin.pkce"

    static var isEnabled: Bool {
        #if DEBUG
        if let forced = ProcessInfo.processInfo.environment["SOUNDING_TV_SIGNIN_PKCE"] { return forced == "1" }
        #endif
        return UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    let verifier: String
    let state: String

    init() {
        verifier = Self.randomURLSafe(bytes: 48)
        state = Self.randomURLSafe(bytes: 24)
    }

    var challenge: String {
        Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    func authorizeURL(page: SoundCloudWebSignInPage = .signIn) -> URL? {
        var components = URLComponents(string: Self.authorizeEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "app_id", value: Self.appId),
            URLQueryItem(name: "client_id", value: Self.clientId),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "device_id", value: Self.installIdentifier(Self.deviceIdKey)),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "start_view", value: page == .signIn ? "sign_in" : "sign_up"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "theme", value: "dark"),
            URLQueryItem(name: "ui_evo", value: "true"),
            URLQueryItem(name: "stand_alone", value: "true"),
            URLQueryItem(name: "tracking", value: "local"),
            URLQueryItem(name: "provider_redirect", value: "true"),
            URLQueryItem(name: "locale", value: Locale.current.language.languageCode?.identifier ?? "en"),
            URLQueryItem(name: "sc_tracking_anonymous_id", value: Self.installIdentifier(Self.anonymousIdKey)),
        ]
        return components?.url
    }

    func code(from callback: URL) throws(Failure) -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("error") == nil else { throw .denied }
        guard value("state") == state else { throw .stateMismatch }
        guard let code = value("code"), !code.isEmpty else { throw .missingCode }
        return code
    }

    func exchange(code: String) async throws(Failure) -> StoredSession {
        guard let url = URL(string: Self.tokenEndpoint) else { throw .unavailable }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Accept")
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "client_id", value: Self.clientId),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: verifier),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
        ]
        request.httpBody = form.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
            .data(using: .utf8)

        let data: Data
        let response: HTTPURLResponse
        do {
            if let transport = SoundCloudTokenRefresh.requestTransport {
                (data, response) = try await transport(request)
            } else {
                let (body, raw) = try await URLSession.shared.data(for: request)
                guard let http = raw as? HTTPURLResponse else { throw Failure.unavailable }
                (data, response) = (body, http)
            }
        } catch {
            Log.auth.error("[PKCE] token exchange did not complete: \(error.localizedDescription, privacy: .public)")
            throw .unavailable
        }
        guard (200..<300).contains(response.statusCode) else {
            Log.auth.error("[PKCE] token exchange failed: HTTP \(response.statusCode, privacy: .public)")
            throw response.statusCode == 400 || response.statusCode == 401 ? .rejected : .unavailable
        }

        struct TokenResponse: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double?
        }
        guard let token = try? JSONDecoder().decode(TokenResponse.self, from: data),
              !token.access_token.isEmpty,
              let refresh = token.refresh_token, !refresh.isEmpty else { throw .rejected }
        return StoredSession(
            oauthToken: token.access_token,
            refreshToken: refresh,
            clientId: Self.clientId,
            expiresAt: token.expires_in.map { Date(timeIntervalSinceNow: $0) }
        )
    }

    @MainActor
    static func signIn(
        page: SoundCloudWebSignInPage = .signIn,
        ephemeral: Bool
    ) async throws(Failure) -> StoredSession {
        let flow = SoundCloudPKCESignIn()
        guard let url = flow.authorizeURL(page: page) else { throw .unavailable }
        let callback: URL
        do {
            callback = try await PKCEPresenter.authenticate(url: url, scheme: callbackScheme, ephemeral: ephemeral)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            throw .canceled
        } catch {
            Log.auth.error("[PKCE] web authentication failed: \(error.localizedDescription, privacy: .public)")
            throw .unavailable
        }
        return try await flow.exchange(code: try flow.code(from: callback))
    }

    static func message(for failure: Failure) -> String {
        switch failure {
        case .canceled, .denied:
            return "Sign-in was cancelled."
        case .rejected, .stateMismatch, .missingCode:
            return "SoundCloud didn’t accept the sign-in. Try again."
        case .unavailable:
            return "Couldn’t reach SoundCloud. Check your connection and try again."
        }
    }

    private static func installIdentifier(_ key: String) -> String {
        let defaults = UserDefaults.standard
        if let value = defaults.string(forKey: key), !value.isEmpty { return value }
        let value = UUID().uuidString.lowercased()
        defaults.set(value, forKey: key)
        return value
    }

    private static func randomURLSafe(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

@MainActor
private final class PKCEPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private static var active: PKCEPresenter?

    static func authenticate(url: URL, scheme: String, ephemeral: Bool) async throws -> URL {
        var anchor = currentAnchor()
        var waited = 0
        while anchor == nil && waited < 20 {
            try? await Task.sleep(for: .milliseconds(100))
            anchor = currentAnchor()
            waited += 1
        }
        guard let anchor else { throw ASWebAuthenticationSessionError(.presentationContextNotProvided) }
        active?.session?.cancel()
        let presenter = PKCEPresenter(anchor: anchor)
        active = presenter
        defer { if active === presenter { active = nil } }
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme)) { callback, error in
                if let callback {
                    once.resume(.success(callback))
                } else {
                    once.resume(.failure(error ?? ASWebAuthenticationSessionError(.canceledLogin)))
                }
            }
            session.presentationContextProvider = presenter
            session.prefersEphemeralWebBrowserSession = ephemeral
            presenter.session = session
            if !session.start() {
                presenter.session = nil
                once.resume(.failure(ASWebAuthenticationSessionError(.presentationContextInvalid)))
            }
        }
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<URL, Error>?

        init(_ continuation: CheckedContinuation<URL, Error>) {
            self.continuation = continuation
        }

        func resume(_ result: Result<URL, Error>) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(with: result)
        }
    }

    private let anchor: ASPresentationAnchor

    private init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { anchor }
    }

    private static func currentAnchor() -> ASPresentationAnchor? {
        #if os(macOS)
        return NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible }
        #else
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.filter { $0.activationState == .foregroundActive }
        let windows = (active.isEmpty ? scenes : active).flatMap(\.windows)
        return windows.first { $0.isKeyWindow } ?? windows.first { !$0.isHidden }
        #endif
    }
}
