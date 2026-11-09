import Foundation
import WebKit
import os

struct SoundCloudWebCapture {
    let accessToken: String
    let refreshToken: String
    let clientId: String
    let expiresAt: Date?

    var session: StoredSession {
        StoredSession(oauthToken: accessToken, refreshToken: refreshToken, clientId: clientId, expiresAt: expiresAt)
    }
}

enum SoundCloudWebSignInPage: String, CaseIterable, Identifiable {
    case signIn
    case createAccount

    var id: String { rawValue }
    var label: String { self == .signIn ? "Sign In" : "Create Account" }

    var url: URL? {
        #if DEBUG
        if self == .signIn,
           let raw = ProcessInfo.processInfo.environment["SOUNDING_TV_SIGNIN_URL"],
           let url = URL(string: raw) {
            return url
        }
        #endif
        return URL(string: self == .signIn ? "https://m.soundcloud.com/signin" : "https://m.soundcloud.com/signup")
    }
}

@MainActor
final class SoundCloudWebSignIn: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver, WKScriptMessageHandler {
    var onFormReady: () -> Void = {}
    var onLoadFailed: () -> Void = {}
    var onRefreshMaterial: (String?, String?) -> Void = { _, _ in }
    var onCapture: (SoundCloudWebCapture) -> Void = { _ in }
    var onOpenExternally: (URL) -> Void = { _ in }

    let webView: WKWebView
    let isolatedStoreIdentifier: UUID?
    private weak var popupWebView: WKWebView?
    private var hasCaptured = false
    private var formIsReady = false
    private var reachedSigninCallback = false
    private var accessToken: String?
    private var refreshToken: String?
    private var clientId: String?
    private var expiresAt: Date?
    private var revealFallback: Task<Void, Never>?
    #if DEBUG
    private var loadStartedAt = Date()
    #endif

    static let mobileUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"

    init(usesIsolatedStore: Bool) {
        let identifier = usesIsolatedStore ? UUID() : nil
        isolatedStoreIdentifier = identifier
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = identifier.map { WKWebsiteDataStore(forIdentifier: $0) } ?? .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        #if os(iOS)
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        #endif
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        let userContent = configuration.userContentController
        userContent.add(WeakScriptHandler(self), name: "scAuth")
        userContent.add(WeakScriptHandler(self), name: "scSignInForm")
        userContent.addUserScript(WKUserScript(source: Self.tokenCaptureScript(handler: "scAuth"), injectionTime: .atDocumentStart, forMainFrameOnly: false))
        userContent.addUserScript(WKUserScript(source: Self.formScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))

        Self.prepare(webView)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        configuration.websiteDataStore.httpCookieStore.add(self)
        #if DEBUG
        if #available(iOS 16.4, macOS 13.3, *) { webView.isInspectable = true }
        #endif
    }

    private static func prepare(_ webView: WKWebView) {
        webView.customUserAgent = mobileUserAgent
        #if os(iOS)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        #else
        webView.setValue(false, forKey: "drawsBackground")
        #endif
    }

    func load(_ page: SoundCloudWebSignInPage) {
        resetCapture()
        guard let url = page.url else { return }
        #if DEBUG
        loadStartedAt = Date()
        #endif
        webView.load(URLRequest(url: url))
    }

    var cookieStore: WKHTTPCookieStore { webView.configuration.websiteDataStore.httpCookieStore }

    func teardown() {
        revealFallback?.cancel()
        cookieStore.remove(self)
        popupWebView?.stopLoading()
        popupWebView?.navigationDelegate = nil
        popupWebView?.uiDelegate = nil
        popupWebView?.removeFromSuperview()
        popupWebView = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        removeIsolatedStore()
    }

    func removeIsolatedStore() {
        guard let isolatedStoreIdentifier else { return }
        Task { try? await WKWebsiteDataStore.remove(forIdentifier: isolatedStoreIdentifier) }
    }

    private func resetCapture() {
        hasCaptured = false
        formIsReady = false
        reachedSigninCallback = false
        accessToken = nil
        refreshToken = nil
        clientId = nil
        expiresAt = nil
        revealFallback?.cancel()
    }

    private func markFormReady(_ reason: String) {
        guard !formIsReady else { return }
        formIsReady = true
        revealFallback?.cancel()
        #if DEBUG
        let elapsed = String(format: "%.1f", Date().timeIntervalSince(loadStartedAt))
        Log.auth.info("[SignIn] form ready (\(reason, privacy: .public)) \(elapsed, privacy: .public)s after load")
        #endif
        onFormReady()
    }

    // MARK: Script messages

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard Self.isTrustedOrigin(message.frameInfo.securityOrigin),
              let payload = message.body as? [String: Any] else { return }
        if message.name == "scSignInForm" {
            #if DEBUG
            if let fields = payload["fields"] as? String {
                Log.auth.info("[SignIn] fields \(message.frameInfo.securityOrigin.host, privacy: .public): \(fields, privacy: .public)")
            }
            #endif
            markFormReady("form")
            return
        }
        guard message.name == "scAuth",
              let url = payload["url"] as? String,
              let body = payload["body"] as? String,
              Self.isSoundCloudURL(URL(string: url)),
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
        onRefreshMaterial(refreshToken, clientId)
        completeIfReady()
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .allow }
        captureClientId(from: url)
        if Self.isSigninCallback(url) { reachedSigninCallback = true }
        if webView === self.webView,
           navigationAction.targetFrame?.isMainFrame == true,
           navigationAction.navigationType == .linkActivated,
           !Self.isSignInURL(url) {
            if url.scheme == "http" || url.scheme == "https" { onOpenExternally(url) }
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        captureClientId(from: url)
        if Self.isSigninCallback(url) { reachedSigninCallback = true }
        if webView === self.webView, !formIsReady {
            revealFallback?.cancel()
            revealFallback = Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                self?.markFormReady("timeout")
            }
        }
        if reachedSigninCallback || isolatedStoreIdentifier != nil {
            inspectCookies(in: cookieStore)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(webView, error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(webView, error)
    }

    private func failed(_ webView: WKWebView, _ error: Error) {
        guard webView === self.webView, (error as NSError).code != NSURLErrorCancelled else { return }
        Log.auth.error("[SignIn] navigation failed: \(error.localizedDescription, privacy: .public)")
        onLoadFailed()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Log.auth.error("[SignIn] WebKit content process terminated")
        onLoadFailed()
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url,
           navigationAction.navigationType == .linkActivated,
           !Self.isSignInURL(url) {
            if url.scheme == "http" || url.scheme == "https" { onOpenExternally(url) }
            return nil
        }
        let popup = WKWebView(frame: webView.bounds, configuration: configuration)
        Self.prepare(popup)
        #if os(iOS)
        popup.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        #else
        popup.autoresizingMask = [.width, .height]
        #endif
        popup.navigationDelegate = self
        popup.uiDelegate = self
        webView.addSubview(popup)
        popupWebView = popup
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard webView === popupWebView else { return }
        webView.removeFromSuperview()
        popupWebView = nil
    }

    // MARK: Cookies

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in
            guard let self, self.reachedSigninCallback || self.isolatedStoreIdentifier != nil else { return }
            self.inspectCookies(in: self.cookieStore)
        }
    }

    private func inspectCookies(in store: WKHTTPCookieStore) {
        guard !hasCaptured else { return }
        Task { [weak self] in
            let cookies = await store.allCookies()
            guard let self, !self.hasCaptured else { return }
            let soundCloud = cookies.filter { $0.domain.lowercased().contains("soundcloud") && !$0.value.isEmpty }
            func value(named names: [String]) -> String? {
                soundCloud.first { cookie in
                    names.contains { $0.caseInsensitiveCompare(cookie.name) == .orderedSame }
                }?.value
            }
            if self.refreshToken == nil {
                self.refreshToken = value(named: ["oauth_refresh_token", "oauth-refresh-token", "sc-refresh-token"])
            }
            if self.accessToken == nil {
                self.accessToken = value(named: ["oauth_token", "OAuth-Token", "sc-token"])
            }
            self.completeIfReady()
        }
    }

    private func completeIfReady() {
        guard !hasCaptured,
              let accessToken, !accessToken.isEmpty,
              let refreshToken, !refreshToken.isEmpty,
              let clientId, !clientId.isEmpty else { return }
        hasCaptured = true
        onCapture(SoundCloudWebCapture(accessToken: accessToken, refreshToken: refreshToken, clientId: clientId, expiresAt: expiresAt))
    }

    private func captureClientId(from url: URL) {
        guard clientId == nil,
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "client_id" })?.value,
              !value.isEmpty else { return }
        clientId = value
        onRefreshMaterial(refreshToken, clientId)
    }

    // MARK: Rules

    static func isSoundCloudURL(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host == "soundcloud.com" || host.hasSuffix(".soundcloud.com")
    }

    private static func isTrustedOrigin(_ origin: WKSecurityOrigin) -> Bool {
        let host = origin.host.lowercased()
        return origin.protocol == "https" && (host == "soundcloud.com" || host.hasSuffix(".soundcloud.com"))
    }

    private static func isSigninCallback(_ url: URL) -> Bool {
        url.host?.lowercased() == "m.soundcloud.com" && url.path.hasPrefix("/signin/callback")
    }

    private static let signInPathPrefixes = [
        "/signin", "/signup", "/login", "/logout", "/connect", "/oauth", "/authorize", "/web-auth",
        "/password", "/reset", "/verify", "/challenge", "/captcha",
    ]

    private static let providerHostSuffixes = [
        "google.com", "gstatic.com", "googleapis.com", "recaptcha.net",
        "apple.com", "facebook.com", "fbcdn.net", "hcaptcha.com", "arkoselabs.com",
    ]

    static func isSignInURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return url.scheme == "about" || url.scheme == "blob" || url.scheme == "data"
        }
        let host = url.host?.lowercased() ?? ""
        if host == "soundcloud.com" || host == "m.soundcloud.com" || host == "www.soundcloud.com" {
            return signInPathPrefixes.contains { url.path.lowercased().hasPrefix($0) }
        }
        if host.hasSuffix(".soundcloud.com") {
            return host != "help.soundcloud.com" && host != "community.soundcloud.com"
        }
        return providerHostSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?

    init(_ target: any WKScriptMessageHandler) { self.target = target }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

extension SoundCloudWebSignIn {
    static let formScript = """
    (function() {
      if (window.__soundingSignInForm) return;
      window.__soundingSignInForm = true;
      var announced = false;
      function visible(el) {
        var r = el.getBoundingClientRect();
        return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility !== 'hidden';
      }
      function hints(el) {
        return [el.name, el.id, el.getAttribute('placeholder'), el.getAttribute('aria-label'), el.getAttribute('autocomplete')]
          .join(' ').toLowerCase();
      }
      function mark(input) {
        var type = (input.getAttribute('type') || 'text').toLowerCase();
        var current = (input.getAttribute('autocomplete') || '').toLowerCase();
        if (type === 'password') {
          if (current.indexOf('new-password') < 0 && current.indexOf('current-password') < 0) {
            input.setAttribute('autocomplete', 'current-password');
          }
          return true;
        }
        if (type === 'email' || ((type === 'text' || type === '') && /(email|e-mail|username|user name|login|profile url)/.test(hints(input)))) {
          if (current.indexOf('username') < 0) input.setAttribute('autocomplete', 'username');
          input.setAttribute('autocapitalize', 'none');
          input.setAttribute('autocorrect', 'off');
          input.setAttribute('spellcheck', 'false');
          if (type !== 'email') input.setAttribute('inputmode', 'email');
          return true;
        }
        return false;
      }
      function describe(inputs) {
        var out = [];
        for (var i = 0; i < inputs.length; i++) {
          var el = inputs[i];
          out.push((el.getAttribute('type') || 'text') + ':' + (el.getAttribute('autocomplete') || '-') + (visible(el) ? '' : '(hidden)'));
        }
        return out.join(', ');
      }
      function scan() {
        var inputs = document.querySelectorAll('input');
        var ready = false;
        for (var i = 0; i < inputs.length; i++) {
          if (mark(inputs[i]) && visible(inputs[i])) ready = true;
        }
        if (!ready) {
          var buttons = document.querySelectorAll('button');
          var shown = 0;
          for (var j = 0; j < buttons.length; j++) if (visible(buttons[j]) && buttons[j].textContent.trim()) shown++;
          ready = shown >= 2 && /signin|signup|web-auth|connect/.test(location.pathname);
        }
        if (ready && !announced) {
          announced = true;
          try { window.webkit.messageHandlers.scSignInForm.postMessage({ fields: describe(inputs) }); } catch (_) {}
        }
      }
      var pending = false;
      function schedule() {
        if (pending) return;
        pending = true;
        requestAnimationFrame(function() { pending = false; scan(); });
      }
      new MutationObserver(schedule).observe(document, { childList: true, subtree: true, attributes: true, attributeFilter: ['type', 'autocomplete', 'style', 'class'] });
      document.addEventListener('focusin', function(e) { if (e.target && e.target.tagName === 'INPUT') mark(e.target); }, true);
      document.addEventListener('DOMContentLoaded', schedule);
    })();
    """

    static func tokenCaptureScript(handler: String) -> String { """
    (function() {
      if (window.__soundingCapture_\(handler)) return;
      window.__soundingCapture_\(handler) = true;
      function report(url, body, clientId) {
        try {
          var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handler);
          var absoluteURL = new URL(String(url || ''), location.href).href;
          if (handler && absoluteURL && body) handler.postMessage({
            url: absoluteURL, body: String(body), clientId: clientId ? String(clientId) : ''
          });
        } catch (_) {}
      }
      function isTrustedURL(url) {
        try { var h = new URL(String(url || ''), location.href).hostname.toLowerCase();
          return h === 'soundcloud.com' || h.endsWith('.soundcloud.com'); } catch (_) { return false; }
      }
      function tokenPayload(body) {
        try {
          function find(value, depth) {
            if (!value || typeof value !== 'object' || depth > 5) return null;
            if (typeof value.access_token === 'string' && value.access_token) return value;
            for (var key in value) { var hit = find(value[key], depth + 1); if (hit) return hit; }
            return null;
          }
          var hit = find(JSON.parse(body), 0);
          return hit ? JSON.stringify(hit) : '';
        } catch (_) { return ''; }
      }
      function clientIdFrom(body) {
        try {
          if (!body) return '';
          if (typeof body === 'string') return new URLSearchParams(body).get('client_id') || '';
          if (body instanceof URLSearchParams || body instanceof FormData) return body.get('client_id') || '';
        } catch (_) {}
        return '';
      }
      function clientIdFromURL(url) {
        try { return new URL(String(url || ''), location.href).searchParams.get('client_id') || ''; }
        catch (_) { return ''; }
      }
      if (window.fetch) {
        var fetch = window.fetch;
        window.fetch = function(input, init) {
          var url = typeof input === 'string' ? input : (input && input.url) || '';
          var clientId = clientIdFrom(init && init.body) || clientIdFromURL(url);
          var promise = fetch.apply(this, arguments);
          if (clientId) report(url, '{}', clientId);
          if (isTrustedURL(url)) promise.then(function(response) {
            try { response.clone().text().then(function(body) {
              var payload = tokenPayload(body); if (payload) report(url, payload, clientId);
            }); } catch (_) {}
          });
          return promise;
        };
      }
      var OriginalXHR = window.XMLHttpRequest;
      if (OriginalXHR) {
        window.XMLHttpRequest = function() {
          var xhr = new OriginalXHR(), url = '', open = xhr.open, send = xhr.send;
          xhr.open = function(method, requestURL) { url = requestURL || ''; return open.apply(xhr, arguments); };
          xhr.send = function(body) {
            xhr.__soundingClientId = clientIdFrom(body) || clientIdFromURL(url);
            if (xhr.__soundingClientId) report(url, '{}', xhr.__soundingClientId);
            return send.apply(xhr, arguments);
          };
          xhr.addEventListener('load', function() {
            if (isTrustedURL(url) && xhr.status >= 200 && xhr.status < 300) {
              var payload = tokenPayload(xhr.responseText);
              if (payload) report(url, payload, xhr.__soundingClientId || '');
            }
          });
          return xhr;
        };
        window.XMLHttpRequest.prototype = OriginalXHR.prototype;
      }
    })();
    """ }
}
