import SwiftUI
import WebKit
import Combine
import os
struct SoundCloudLoginView: View {
    private enum Mode {
        case link(sessionId: String, sessionSecret: Data, peerName: String?, peerClass: DeviceClass)
        case authHandoff(sessionId: String, sessionSecret: Data, peerName: String?, peerClass: DeviceClass)
        case standalone
    }

    private enum AuthHandoffState {
        case idle
        case sending
        case completed
        case failed(String)

        var isSendingOrFinished: Bool {
            switch self {
            case .idle: return false
            case .sending, .completed, .failed: return true
            }
        }
    }

    private let mode: Mode
    private let companionClient: CompanionClient?
    var onComplete: (() -> Void)?

    @MainActor
    private final class BonjourClientBox: ObservableObject {
        let client: LinkClient?
        private var forwarder: AnyCancellable?

        init(client: LinkClient?) {
            self.client = client
            forwarder = client?.objectWillChange.sink { [weak self] in
                Task { @MainActor in
                    self?.objectWillChange.send()
                }
            }
        }
    }

    @StateObject private var box: BonjourClientBox
    @Environment(\.dismiss) private var dismiss
    @State private var isLoadingWeb = true
    @State private var isTransferring = false
    @State private var storedSession: StoredSession?
    @State private var forceWebLogin = false
    @State private var pendingSession: StoredSession?
    @State private var capturedRefreshToken: String?
    @State private var capturedClientId: String?
    @State private var completionTask: Task<Void, Never>?
    @State private var incompleteCaptureRetries = 0
    private static let maxIncompleteCaptureRetries = 1

    @State private var signinUiMounted = false
    @State private var signinStalled = false
    @State private var webAttempt = 0
    @State private var signinLivenessTask: Task<Void, Never>?
    @State private var lastWebLoadFinishedAt: Date?
    private static let signinMountBudget: TimeInterval = 15
    private static let signinPostLoadGrace: TimeInterval = 8

    @State private var webLoginPresentedAt: Date?
    @State private var signedInWithoutInteraction = false
    @State private var authHandoffState: AuthHandoffState = .idle
    private static let noInteractionThreshold: TimeInterval = 3

    init(
        sessionId: String,
        sessionSecret: Data,
        peerName: String? = nil,
        peerClass: DeviceClass = .tv,
        onComplete: (() -> Void)? = nil
    ) {
        self.init(
            mode: .link(sessionId: sessionId, sessionSecret: sessionSecret, peerName: peerName, peerClass: peerClass),
            companionClient: nil,
            onComplete: onComplete
        )
    }

    init(
        authHandoff sessionId: String,
        sessionSecret: Data,
        peerName: String? = nil,
        peerClass: DeviceClass = .tv,
        client: CompanionClient,
        onComplete: (() -> Void)? = nil
    ) {
        self.init(
            mode: .authHandoff(sessionId: sessionId, sessionSecret: sessionSecret, peerName: peerName, peerClass: peerClass),
            companionClient: client,
            onComplete: onComplete
        )
    }

    private init(mode: Mode, companionClient: CompanionClient?, onComplete: (() -> Void)?) {
        self.mode = mode
        self.companionClient = companionClient
        self.onComplete = onComplete
        switch mode {
        case .link(let sessionId, let sessionSecret, let peerName, let peerClass):
            self._box = StateObject(wrappedValue: BonjourClientBox(
                client: LinkClient(sessionId: sessionId, sessionSecret: sessionSecret, peerName: peerName, peerClass: peerClass)
            ))
        case .authHandoff, .standalone:
            self._box = StateObject(wrappedValue: BonjourClientBox(client: nil))
        }
    }

    private var peerClass: DeviceClass {
        switch mode {
        case .link(_, _, _, let peerClass), .authHandoff(_, _, _, let peerClass):
            return peerClass
        case .standalone:
            return .tv
        }
    }

    private var transferState: LinkClient.State {
        box.client?.state ?? .idle
    }

    var body: some View {
        ZStack {
            if isTransferring {
                transferStatusView
            } else if authHandoffState.isSendingOrFinished {
                authHandoffStatusView
            } else if let session = storedSession, !forceWebLogin {
                readyView(for: session)
            } else {
                webLogin
            }
        }
        .navigationTitle("Sign in to SoundCloud")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { cancelSignIn() }
            }
        }
        .onChange(of: transferState) { _, newState in
            switch newState {
            case .completed:
                scheduleCompletionIfNeeded()
            default:
                break
            }
        }
        .onAppear {
            if case .link = mode {
                box.client?.startDiscovery()
            }
            if case .authHandoff = mode {
                // An auth handoff must always capture a fresh token pair for the
                // peer. Never reuse this phone's saved session.
                webLoginPresentedAt = Date()
                startSigninLivenessClock()
                Task {
                    await AuthWebSession.clear()
                    webAttempt += 1
                }
            } else if storedSession == nil, !forceWebLogin {
                if let saved = DeviceSessionStore.load(), saved.isUsable {
                    guard saved.canSelfRefresh else {
                        Log.auth.error("[SignIn] Saved session is not refreshable; forcing re-authentication")
                        Task { await useDifferentAccount() }
                        return
                    }
                    storedSession = saved
                    switch mode {
                    case .link:
                        // Matching the six-digit code is the user's consent to
                        // share this already-saved session with that television.
                        startTransfer(with: saved)
                    case .standalone:
                        signedInWithoutInteraction = true
                        scheduleCompletionIfNeeded()
                    case .authHandoff:
                        break
                    }
                } else {
                    webLoginPresentedAt = Date()
                    startSigninLivenessClock()
                    Task {
                        await AuthWebSession.clear()
                        webAttempt += 1
                    }
                }
            }
        }
        .onDisappear {
            signinLivenessTask?.cancel()
        }
    }

    private func cancelSignIn() {
        completionTask?.cancel()
        signinLivenessTask?.cancel()
        if let onComplete {
            onComplete()
        } else {
            dismiss()
        }
    }

    private var webLogin: some View {
        ZStack {
            let isAuthHandoff = if case .authHandoff = mode { true } else { false }
            OAuthWebView(
                isLoading: $isLoadingWeb,
                attempt: webAttempt,
                usesIsolatedDataStore: isAuthHandoff,
                onLogin: { token, refreshToken, clientId, expiry in
                    handleTokenReceived(
                        token: token,
                        refreshToken: refreshToken ?? capturedRefreshToken,
                        clientId: clientId ?? capturedClientId,
                        expiry: expiry
                    )
                },
                onRefreshMaterial: { refreshToken, clientId in
                    if let refreshToken { capturedRefreshToken = refreshToken }
                    if let clientId { capturedClientId = clientId }

                    if let existing = DeviceSessionStore.load(),
                       existing.refreshToken == nil || existing.clientId == nil,
                       refreshToken != nil || clientId != nil {
                        let patched = StoredSession(
                            oauthToken: existing.oauthToken,
                            refreshToken: refreshToken ?? existing.refreshToken,
                            clientId: clientId ?? existing.clientId,
                            expiresAt: existing.expiresAt
                        )
                        DeviceSessionStore.save(patched)
                        SoundCloudCredentialSource.shared.didCompleteSignIn()
                        #if DEBUG
                        if ProcessInfo.processInfo.environment["SOUNDING_TV_PERSIST_DEV_CREDENTIAL"] == "1" {
                            DevCredentialStore.save(patched)
                        }
                        #endif
                    }
                },
                onSigninUiMounted: {
                    #if DEBUG
                    if let webLoginPresentedAt {
                        let elapsed = Date().timeIntervalSince(webLoginPresentedAt)
                        let elapsedDescription = String(format: "%.1f", elapsed)
                        Log.link.debug("[SignIn] form mounted \(elapsedDescription, privacy: .public)s after presentation")
                    }
                    #endif
                    signinUiMounted = true
                    signinStalled = false
                },
                onUserInteraction: {
                    signinLivenessTask?.cancel()
                },
                onSigninUnavailable: {
                    guard !signinUiMounted else { return }
                    isLoadingWeb = false
                    signinLivenessTask?.cancel()
                    signinStalled = true
                }
            )
            .ignoresSafeArea(edges: .bottom)

            if signinStalled {
                signinStalledOverlay
            } else if isLoadingWeb {
                loadingOverlay
            }
        }
        .onChange(of: isLoadingWeb) { _, loading in
            if !loading { lastWebLoadFinishedAt = Date() }
        }
    }

    private var loadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)

            VStack(spacing: 16) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.3)
                    .tint(.white)

                Text("Loading SoundCloud…")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.white)
            }
            .padding(28)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .ignoresSafeArea()
    }

    private var signinStalledOverlay: some View {
        ZStack {
            Color.black.opacity(0.6)

            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(Color.scAccent.gradient)

                Text("Sign-In Isn't Loading")
                    .font(.system(size: 22, weight: .heavy))
                    .multilineTextAlignment(.center)

                Text("SoundCloud loaded its app-promotion page, but its sign-in form did not start. Retry opens a clean SoundCloud web session.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                primaryButton("Try Again") {
                    retrySigninPage()
                }
                .padding(.top, 4)
            }
            .padding(28)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, 20)
        }
        .ignoresSafeArea()
    }

    private func startSigninLivenessClock() {
        signinLivenessTask?.cancel()
        signinStalled = false
        signinUiMounted = false
        signinLivenessTask = Task {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            guard !signinUiMounted, !isTransferring,
                  storedSession == nil || forceWebLogin else { return }
            signinStalled = true
        }
    }

    private func retrySigninPage() {
        signinLivenessTask?.cancel()
        signinStalled = false
        isLoadingWeb = true
        incompleteCaptureRetries = 0
        Task {
            await AuthWebSession.clear()
            webAttempt += 1
            lastWebLoadFinishedAt = nil
            webLoginPresentedAt = Date()
            signedInWithoutInteraction = false
            startSigninLivenessClock()
        }
    }

    @ViewBuilder
    private func readyView(for session: StoredSession) -> some View {
        switch mode {
        case .link:
            readyToSendView(session)
        case .authHandoff:
            authHandoffStatusView
        case .standalone:
            standaloneReadyView
        }
    }

    private var standaloneReadyView: some View {
        ZStack {
            Color.scBackgroundGradient.ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 84, weight: .heavy))
                    .foregroundStyle(Color.green.gradient)

                VStack(spacing: 8) {
                    Text("You're Signed In")
                        .font(.system(size: 28, weight: .heavy))
                        .kerning(-0.5)

                    if signedInWithoutInteraction {
                        Text("SoundCloud remembered you were already signed in on this iPhone. Nothing else to do.")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                }
            }
        }
    }

    private func readyToSendView(_ session: StoredSession) -> some View {
        ZStack {
            Color.scBackgroundGradient.ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                Image(systemName: peerClass.symbolName)
                    .font(.system(size: 84, weight: .heavy))
                    .foregroundStyle(Color.scAccent.gradient)

                VStack(spacing: 8) {
                    Text("Ready to Sign In")
                        .font(.system(size: 32, weight: .heavy))
                        .kerning(-0.5)

                    Text("You're already signed in to SoundCloud on this iPhone.")
                        .font(.system(size: 17))
                        .foregroundStyle(Color.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                primaryButton("Send to \(peerClass.displayName)") {
                    startTransfer(with: session)
                }

                Button("Use a Different Account") {
                    Task { await useDifferentAccount() }
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.secondary)

                Spacer()
            }
            .padding()
        }
    }

    private var transferStatusView: some View {
        ZStack {
            Color.scBackgroundGradient.ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                statusIcon
                    .font(.system(size: 96, weight: .heavy))

                VStack(spacing: 8) {
                    Text(statusTitle)
                        .font(.system(size: 32, weight: .heavy))
                        .kerning(-0.5)
                        .multilineTextAlignment(.center)

                    Text(statusMessage)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(Color.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                if case .rejected = transferState {
                    primaryButton("Sign In Again") {
                        Task { await useDifferentAccount() }
                    }

                    Button("Keep My iPhone Signed In") {
                        cancelSignIn()
                    }
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.secondary)
                } else if case .failed = transferState {
                    primaryButton("Try Again") {
                        box.client?.startDiscovery()
                        if let session = pendingSession {
                            Task { await sendWhenReady(session) }
                        } else {
                            isTransferring = false
                        }
                    }

                    Button("Sign In Again") {
                        Task { await useDifferentAccount() }
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                }

                Spacer()
            }
            .padding()
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.scAccentGradient, in: Capsule(style: .continuous))
                .shadow(color: Color.scAccent.opacity(0.4), radius: 16, y: 8)
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 32)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch transferState {
        case .idle, .discovering:
            Image(systemName: "wifi")
                .foregroundStyle(Color.scAccent.gradient)
                .symbolEffect(.pulse)
        case .connecting:
            Image(systemName: "cable.connector")
                .foregroundStyle(Color.scAccent.gradient)
                .symbolEffect(.pulse)
        case .sending:
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(2)
                .tint(.scAccent)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.green.gradient)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.red.gradient)
        case .rejected:
            Image(systemName: "person.crop.circle.badge.exclamationmark.fill")
                .foregroundStyle(Color.scAccent.gradient)
        }
    }

    private var statusTitle: String {
        switch transferState {
        case .idle, .discovering: return "Finding \(peerClass.displayName)…"
        case .connecting:         return "Connecting…"
        case .sending:            return "Transferring…"
        case .completed:          return "\(peerClass.displayName) Signed In"
        case .failed:             return "Transfer Failed"
        case .rejected:           return "\(peerClass.displayName) Couldn't Use This Login"
        }
    }

    private var statusMessage: String {
        switch transferState {
        case .idle, .discovering: return "Looking for your \(peerClass.displayName) on this network"
        case .connecting:         return "Opening a secure connection"
        case .sending:            return "Sending your sign-in securely"
        case .completed:
            return "Taking you to your remote…"
        case .failed(let error):   return error
        case .rejected(let error): return error
        }
    }

    private var authHandoffStatusView: some View {
        ZStack {
            Color.scBackgroundGradient.ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                authHandoffStatusIcon
                    .font(.system(size: 96, weight: .heavy))

                VStack(spacing: 8) {
                    Text(authHandoffStatusTitle)
                        .font(.system(size: 32, weight: .heavy))
                        .kerning(-0.5)
                        .multilineTextAlignment(.center)

                    Text(authHandoffStatusMessage)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(Color.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                if case .failed = authHandoffState {
                    primaryButton("Try Again") {
                        authHandoffState = .idle
                    }
                }

                Spacer()
            }
            .padding()
        }
    }

    @ViewBuilder
    private var authHandoffStatusIcon: some View {
        switch authHandoffState {
        case .idle:
            EmptyView()
        case .sending:
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(2)
                .tint(.scAccent)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.green.gradient)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.red.gradient)
        }
    }

    private var authHandoffStatusTitle: String {
        switch authHandoffState {
        case .idle:      return ""
        case .sending:   return "Sending to \(peerClass.displayName)…"
        case .completed: return "\(peerClass.displayName) Signed In"
        case .failed:    return "Couldn't Send Sign-In"
        }
    }

    private var authHandoffStatusMessage: String {
        switch authHandoffState {
        case .idle:      return ""
        case .sending:   return "Your sign-in is being sent securely to your \(peerClass.displayName)."
        case .completed: return "Your \(peerClass.displayName) can now use its own SoundCloud session."
        case .failed(let error): return error
        }
    }

    private func handleTokenReceived(token: String, refreshToken: String?, clientId: String?, expiry: Date?) {
        signinLivenessTask?.cancel()
        signinStalled = false

        let hasRefreshMaterial = (refreshToken?.isEmpty == false) && (clientId?.isEmpty == false)
        guard hasRefreshMaterial else {
            Log.auth.error("[SignIn] Incomplete token capture (no refresh material); forcing fresh sign-in")
            guard incompleteCaptureRetries < Self.maxIncompleteCaptureRetries else {
                Log.auth.error("[SignIn] Exhausted retries for full-token capture")
                signinStalled = true
                return
            }
            incompleteCaptureRetries += 1
            Task {
                await AuthWebSession.clear()
                retrySigninPage()
            }
            return
        }
        incompleteCaptureRetries = 0

        let session = StoredSession(
            oauthToken: token,
            refreshToken: refreshToken,
            clientId: clientId,
            expiresAt: expiry
        )

        switch mode {
        case .authHandoff:
            // This token pair is for the peer, not this phone. Send it over the
            // existing companion link without touching this device's session.
            authHandoffState = .sending
            companionClient?.sendAuthHandoffSession(session)
            scheduleCompletionIfNeeded()
            return
        case .link, .standalone:
            break
        }

        DeviceSessionStore.save(session)
        SoundCloudCredentialSource.shared.didCompleteSignIn()

        DeviceSessionRefresher.shared.reset()

        #if DEBUG
        if ProcessInfo.processInfo.environment["SOUNDING_TV_PERSIST_DEV_CREDENTIAL"] == "1" {
            DevCredentialStore.save(session)
        }
        #endif

        if let webLoginPresentedAt, Date().timeIntervalSince(webLoginPresentedAt) < Self.noInteractionThreshold {
            signedInWithoutInteraction = true
        }

        switch mode {
        case .link:
            startTransfer(with: session)
        case .standalone:
            storedSession = session
            scheduleCompletionIfNeeded()
        case .authHandoff:
            break
        }
    }

    private func startTransfer(with session: StoredSession) {
        pendingSession = session
        isTransferring = true
        Task { await sendWhenReady(session) }
    }

    private func sendWhenReady(_ session: StoredSession) async {
        waitForConnection: for _ in 0..<60 {
            switch transferState {
            case .failed, .rejected:
                return
            case .connecting, .sending, .completed:
                break waitForConnection
            case .idle, .discovering:
                try? await Task.sleep(for: .milliseconds(500))
            }
        }

        box.client?.sendToken(
            session.oauthToken,
            refreshToken: session.refreshToken,
            clientId: session.clientId,
            expiresAt: session.expiresAt
        )
    }

    private func useDifferentAccount() async {
        // Only an explicit tap reaches this destructive account-reset path.
        // A TV rejecting a transfer must never sign the phone out by itself.
        DeviceSessionStore.forget()
        CloudSyncCoordinator.shared.requestSessionSync()
        await AuthWebSession.clear()
        pendingSession = nil
        storedSession = nil
        isTransferring = false
        forceWebLogin = true
        webLoginPresentedAt = Date()
        signedInWithoutInteraction = false
        lastWebLoadFinishedAt = nil
        startSigninLivenessClock()
    }

    private func scheduleCompletionIfNeeded() {
        guard let onComplete else { return }
        completionTask?.cancel()
        completionTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            onComplete()
        }
    }
}

extension SoundCloudLoginView {
    static func standalone(onComplete: @escaping () -> Void) -> SoundCloudLoginView {
        SoundCloudLoginView(mode: .standalone, companionClient: nil, onComplete: onComplete)
    }

    static func authHandoff(
        sessionId: String,
        sessionSecret: Data,
        peerName: String? = nil,
        peerClass: DeviceClass = .tv,
        client: CompanionClient,
        onComplete: @escaping () -> Void
    ) -> SoundCloudLoginView {
        SoundCloudLoginView(
            authHandoff: sessionId,
            sessionSecret: sessionSecret,
            peerName: peerName,
            peerClass: peerClass,
            client: client,
            onComplete: onComplete
        )
    }
}

struct OAuthWebView: UIViewRepresentable {
    @Binding var isLoading: Bool
    let attempt: Int
    let usesIsolatedDataStore: Bool
    let onLogin: (String, String?, String?, Date?) -> Void
    let onRefreshMaterial: (String?, String?) -> Void
    let onSigninUiMounted: () -> Void
    let onUserInteraction: () -> Void
    let onSigninUnavailable: () -> Void

    static var signinURL: URL? {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["SOUNDING_TV_SIGNIN_URL"],
           let url = URL(string: raw) {
            return url
        }
        #endif
        return URL(string: "https://m.soundcloud.com/signin")
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        if let storeID = context.coordinator.isolatedStoreIdentifier {
            config.websiteDataStore = WKWebsiteDataStore(forIdentifier: storeID)
        } else {
            config.websiteDataStore = .default()
        }

        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground

        webView.configuration.websiteDataStore.httpCookieStore.add(context.coordinator)
        let interaction = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.userInteracted)
        )
        interaction.cancelsTouchesInView = false
        webView.addGestureRecognizer(interaction)

        context.coordinator.resetCapture()
        context.coordinator.lastLoadedAttempt = attempt
        if let url = Self.signinURL {
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastLoadedAttempt != attempt {
            context.coordinator.resetCapture()
            context.coordinator.lastLoadedAttempt = attempt
            if let url = Self.signinURL {
                webView.load(URLRequest(url: url))
            }
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.teardown(webView: webView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            parent: self,
            isolatedStoreIdentifier: usesIsolatedDataStore ? UUID() : nil
        )
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {

        let parent: OAuthWebView
        var lastLoadedAttempt = 0
        let isolatedStoreIdentifier: UUID?
        private var hasLoggedIn = false
        private var capturedAccessToken: String?
        private var capturedRefreshToken: String?
        private var capturedClientId: String?
        private var capturedExpiresAt: Date?
        private weak var popupWebView: WKWebView?
        private var signinCheckTask: Task<Void, Never>?
        private var signinMounted = false
        private var reachedSigninCallback = false

        init(parent: OAuthWebView, isolatedStoreIdentifier: UUID?) {
            self.parent = parent
            self.isolatedStoreIdentifier = isolatedStoreIdentifier
        }

        @objc func userInteracted() {
            signinMounted = true
            signinCheckTask?.cancel()
            parent.onUserInteraction()
        }

        deinit { signinCheckTask?.cancel() }

        func teardown(webView: WKWebView) {
            signinCheckTask?.cancel()
            webView.configuration.websiteDataStore.httpCookieStore.remove(self)
            popupWebView?.stopLoading()
            popupWebView?.navigationDelegate = nil
            popupWebView?.uiDelegate = nil
            popupWebView?.removeFromSuperview()
            popupWebView = nil
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
        }

        func resetCapture() {
            hasLoggedIn = false
            capturedAccessToken = nil
            capturedRefreshToken = nil
            capturedClientId = nil
            capturedExpiresAt = nil
            reachedSigninCallback = false
        }

        func scheduleSigninCheck(for webView: WKWebView) {
            signinCheckTask?.cancel()
            signinMounted = false
            signinCheckTask = Task { @MainActor [weak self, weak webView] in
                try? await Task.sleep(for: .seconds(12))
                guard let self, let webView, !Task.isCancelled else { return }
                guard !self.signinMounted else { return }
                let script = """
                (function() {
                  var selector = 'input[type="email"],input[type="password"],input[autocomplete="username"],input[autocomplete="email"]';
                  var mounted = Array.prototype.some.call(document.querySelectorAll(selector), function(el) {
                    var r = el.getBoundingClientRect(); var s = window.getComputedStyle(el);
                    return r.width >= 40 && r.height >= 20 && r.bottom > 0 && r.top < window.innerHeight &&
                      r.right > 0 && r.left < window.innerWidth && s.display !== 'none' &&
                      s.visibility !== 'hidden' && parseFloat(s.opacity || '1') > 0.05;
                  });
                  return mounted ? 'mounted' : 'missing';
                })()
                """
                let result = (try? await webView.evaluateJavaScript(script)) as? String
                guard result != "mounted" else { return }
                Log.link.error("[SignIn] SoundCloud shell loaded without a visible sign-in form")
                self.parent.onSigninUnavailable()
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            if let url = webView.url {
                captureClientId(from: url)
                if Self.isSigninCallback(url) { reachedSigninCallback = true }
                if Self.isSoundCloudSignInPage(url), !signinMounted {
                    signinMounted = true
                    signinCheckTask?.cancel()
                    parent.onSigninUiMounted()
                }
            }
            if reachedSigninCallback {
                checkForToken(in: webView.configuration.websiteDataStore.httpCookieStore)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            Log.link.error("[SignIn] navigation failed: \(error.localizedDescription, privacy: .public)")
            parent.onSigninUnavailable()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            Log.link.error("[SignIn] provisional navigation failed: \(error.localizedDescription, privacy: .public)")
            parent.onSigninUnavailable()
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            parent.isLoading = false
            Log.link.error("[SignIn] WebKit content process terminated")
            parent.onSigninUnavailable()
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            let popup = WKWebView(frame: webView.bounds, configuration: configuration)
            popup.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            popup.navigationDelegate = self
            popup.uiDelegate = self
            webView.addSubview(popup)
            popupWebView = popup
            return popup
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            if let url = navigationAction.request.url {
                captureClientId(from: url)
                if Self.isSigninCallback(url) { reachedSigninCallback = true }
            }
            return .allow
        }

        func webViewDidClose(_ webView: WKWebView) {
            guard webView === popupWebView else { return }
            webView.removeFromSuperview()
            popupWebView = nil
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            checkForToken(in: cookieStore)
        }

        private func checkForToken(in cookieStore: WKHTTPCookieStore) {
            guard !hasLoggedIn, reachedSigninCallback else { return }
            cookieStore.getAllCookies { [weak self] cookies in
                guard let self else { return }

                let isSC: (HTTPCookie) -> Bool = { $0.domain.lowercased().contains("soundcloud") }

                let tokenNames: Set<String> = ["oauth_token", "OAuth-Token", "sc-token"]
                let tokenCookie = cookies.first { c in
                    isSC(c)
                        && tokenNames.contains(where: { $0.caseInsensitiveCompare(c.name) == .orderedSame })
                        && !c.value.isEmpty
                }

                let refreshNames: Set<String> = ["oauth_refresh_token", "oauth-refresh-token", "sc-refresh-token"]
                let refreshCookie = cookies.first { c in
                    isSC(c)
                        && refreshNames.contains(where: { $0.caseInsensitiveCompare(c.name) == .orderedSame })
                        && !c.value.isEmpty
                }

                if let refreshCookie, self.capturedRefreshToken == nil {
                    self.capturedRefreshToken = refreshCookie.value
                }

                guard let tokenCookie else { return }

                if self.capturedAccessToken == nil {
                    self.capturedAccessToken = tokenCookie.value
                }
                DispatchQueue.main.async {
                    self.tryFireLogin()
                }
            }
        }

        private func tryFireLogin() {
            guard !hasLoggedIn,
                  capturedAccessToken?.isEmpty == false,
                  capturedRefreshToken?.isEmpty == false,
                  capturedClientId?.isEmpty == false else { return }
            fireLogin()
        }

        private func fireLogin() {
            guard !hasLoggedIn, let token = capturedAccessToken else { return }
            hasLoggedIn = true
            parent.onLogin(token, capturedRefreshToken, capturedClientId, capturedExpiresAt)
            removeIsolatedStoreIfNeeded()
        }

        private func removeIsolatedStoreIfNeeded() {
            guard let isolatedStoreIdentifier else { return }
            Task {
                try? await WKWebsiteDataStore.remove(forIdentifier: isolatedStoreIdentifier)
            }
        }

        private static func extractClientId(from url: String) -> String? {
            guard let comps = URLComponents(string: url) else { return nil }
            return comps.queryItems?.first(where: { $0.name == "client_id" })?.value
        }

        private func captureClientId(from url: URL) {
            guard capturedClientId == nil,
                  let clientID = Self.extractClientId(from: url.absoluteString),
                  !clientID.isEmpty else { return }
            capturedClientId = clientID
            parent.onRefreshMaterial(capturedRefreshToken, capturedClientId)
        }

        private static func isSigninCallback(_ url: URL) -> Bool {
            (url.host ?? "").lowercased() == "m.soundcloud.com"
                && url.path.hasPrefix("/signin/callback")
        }

        private static func isSoundCloudSignInPage(_ url: URL) -> Bool {
            let host = (url.host ?? "").lowercased()
            return host == "m.soundcloud.com" || host == "secure.soundcloud.com"
        }

    }
}
