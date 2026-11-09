import Foundation
import WebKit
import os
#if os(iOS)
import UIKit
#endif

@MainActor
final class SilentWebReauthorizer: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private static var inFlight: Task<StoredSession?, Never>?

    static func authorize(using store: WKWebsiteDataStore) async -> StoredSession? {
        if let inFlight { return await inFlight.value }
        let task = Task { @MainActor in
            let reauthorizer = SilentWebReauthorizer()
            return await reauthorizer.run(store: store)
        }
        inFlight = task
        let session = await task.value
        inFlight = nil
        Log.auth.info("[SilentWebReauth] finished (renewed=\(session != nil, privacy: .public))")
        return session
    }

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<StoredSession?, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var accessToken: String?
    private var refreshToken: String?
    private var clientId: String?
    private var expiresAt: Date?
    private var reachedCallback = false

    private func run(store: WKWebsiteDataStore) async -> StoredSession? {
        await Self.removeAppTokenCookies(from: store)
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            start(store: store)
        }
    }

    private static func removeAppTokenCookies(from store: WKWebsiteDataStore) async {
        let cookieStore = store.httpCookieStore
        let cookies = await cookieStore.allCookies()
        for cookie in cookies
        where SilentWebReauthorizationPolicy.isSoundCloudCookieDomain(cookie.domain)
            && SilentWebReauthorizationPolicy.appTokenCookieNames.contains(cookie.name.lowercased()) {
            await cookieStore.deleteCookie(cookie)
        }
    }

    private func start(store: WKWebsiteDataStore) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let content = WKUserContentController()
        content.add(self, name: "scSilentAuth")
        content.addUserScript(WKUserScript(
            source: SoundCloudWebSignIn.tokenCaptureScript(handler: "scSilentAuth"),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        configuration.userContentController = content

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        webView.customUserAgent = SoundCloudWebSignIn.mobileUserAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self
        #if os(iOS)
        webView.alpha = 0
        webView.isUserInteractionEnabled = false
        webView.accessibilityElementsHidden = true
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        window?.insertSubview(webView, at: 0)
        #endif
        self.webView = webView

        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: SilentWebReauthorizationPolicy.timeout)
            guard !Task.isCancelled else { return }
            Log.auth.info("[SilentWebReauth] timed out without a token exchange")
            self?.finish(nil)
        }
        webView.load(URLRequest(url: SilentWebReauthorizationPolicy.startURL))
    }

    private func finish(_ session: StoredSession?) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        if let webView {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "scSilentAuth")
            webView.removeFromSuperview()
        }
        webView = nil
        continuation.resume(returning: session)
    }

    private func completeIfPossible() {
        guard let session = SilentWebReauthorizationPolicy.session(
            accessToken: accessToken,
            refreshToken: refreshToken,
            clientId: clientId,
            expiresAt: expiresAt
        ) else { return }
        finish(session)
    }

    private func captureClientId(from url: URL) {
        guard clientId == nil,
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "client_id" })?
                .value,
              !value.isEmpty else { return }
        clientId = value
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let origin = message.frameInfo.securityOrigin
        guard message.name == "scSilentAuth",
              SilentWebReauthorizationPolicy.isTrustedMessageOrigin(scheme: origin.protocol, host: origin.host),
              let payload = message.body as? [String: Any],
              let url = payload["url"] as? String,
              let body = payload["body"] as? String,
              SilentWebReauthorizationPolicy.isTrustedTokenURL(url),
              let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        if let value = payload["clientId"] as? String, !value.isEmpty { clientId = value }
        if let value = json["client_id"] as? String, !value.isEmpty { clientId = value }
        if let value = json["access_token"] as? String, !value.isEmpty { accessToken = value }
        if let value = json["refresh_token"] as? String, !value.isEmpty { refreshToken = value }
        if let seconds = json["expires_in"] as? Double {
            expiresAt = Date(timeIntervalSinceNow: seconds)
        } else if let seconds = json["expires_in"] as? Int {
            expiresAt = Date(timeIntervalSinceNow: TimeInterval(seconds))
        }
        completeIfPossible()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let url = navigationAction.request.url
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        guard SilentWebReauthorizationPolicy.allowsNavigation(to: url, isMainFrame: isMainFrame) else {
            Log.auth.info("[SilentWebReauth] cancelled navigation to \(url?.host ?? "(none)", privacy: .public)")
            if isMainFrame { finish(nil) }
            return .cancel
        }
        if let url {
            captureClientId(from: url)
            if SilentWebReauthorizationPolicy.isSigninCallback(url) { reachedCallback = true }
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url {
            captureClientId(from: url)
            if SilentWebReauthorizationPolicy.isSigninCallback(url) { reachedCallback = true }
        }
        guard reachedCallback else { return }
        Task { @MainActor [weak self] in
            await self?.captureFromCookies(webView.configuration.websiteDataStore.httpCookieStore)
        }
    }

    private func captureFromCookies(_ store: WKHTTPCookieStore) async {
        guard continuation != nil else { return }
        let cookies = await store.allCookies().filter {
            SilentWebReauthorizationPolicy.isSoundCloudCookieDomain($0.domain) && !$0.value.isEmpty
        }
        if accessToken == nil,
           let access = cookies.first(where: { SilentWebReauthorizationPolicy.accessCookieNames.contains($0.name.lowercased()) }) {
            accessToken = access.value
        }
        if refreshToken == nil,
           let refresh = cookies.first(where: { SilentWebReauthorizationPolicy.refreshCookieNames.contains($0.name.lowercased()) }) {
            refreshToken = refresh.value
        }
        completeIfPossible()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return }
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        finish(nil)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(nil)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }
}

extension SoundCloudSessionRenewal.Source {
    static func silentWeb(store: @escaping @MainActor () -> WKWebsiteDataStore) -> Self {
        Self(kind: .silentWeb) { phase in
            guard phase == .afterFailure,
                  let session = await SilentWebReauthorizer.authorize(using: store()) else { return nil }
            return SoundCloudSessionRenewal.Candidate(session: session)
        }
    }
}
