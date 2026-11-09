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
    @State private var incompleteCaptureRetries = 0
    @State private var completionError: String?
    @State private var isVerifyingSession = false
    private static let maxIncompleteCaptureRetries = 1

    @State private var signinUiMounted = false
    @State private var signinStalled = false
    @State private var webAttempt = 0
    @State private var signinLivenessTask: Task<Void, Never>?
    @State private var lastWebLoadFinishedAt: Date?

    @State private var webLoginPresentedAt: Date?
    @State private var authHandoffState: AuthHandoffState = .idle
    @State private var usesWebFallback = !SoundCloudPKCESignIn.isEnabled
    @State private var isAuthenticating = false
    @State private var pkceError: String?

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
        .navigationTitle("Sign In to SoundCloud")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .presentationSizing(.form)
        .interactiveDismissDisabled()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { cancelSignIn() }
            }
        }
        .onAppear {
            if case .link = mode {
                box.client?.startDiscovery()
            }
            if case .authHandoff = mode {
                beginSignIn()
            } else if storedSession == nil, !forceWebLogin {
                if let saved = DeviceSessionStore.load() ?? LinkClient.fixtureSession, saved.isUsable {
                    guard saved.canSelfRefresh else {
                        Log.auth.error("[SignIn] Saved session is not refreshable; forcing re-authentication")
                        Task { await useDifferentAccount() }
                        return
                    }
                    storedSession = saved
                    switch mode {
                    case .link:
                        startTransfer(with: saved)
                    case .standalone:
                        finish()
                    case .authHandoff:
                        break
                    }
                } else {
                    beginSignIn()
                }
            }
        }
        .onDisappear {
            signinLivenessTask?.cancel()
        }
        .task(id: isTransferCompleted) {
            guard isTransferCompleted else { return }
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            finish()
        }
    }

    private func cancelSignIn() {
        signinLivenessTask?.cancel()
        finish()
    }

    private func finish() {
        if let onComplete {
            onComplete()
        } else {
            dismiss()
        }
    }

    @ViewBuilder
    private var webLogin: some View {
        if usesPKCE {
            pkceStatus
        } else {
            embeddedWebLogin
        }
    }

    private var embeddedWebLogin: some View {
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

            if let completionError {
                completionErrorOverlay(completionError)
            } else if isVerifyingSession {
                verifyingOverlay
            } else if signinStalled {
                signinStalledOverlay
            } else if isLoadingWeb {
                loadingOverlay
            }
        }
        .animation(.easeOut(duration: 0.2), value: isLoadingWeb)
        .onChange(of: isLoadingWeb) { _, loading in
            if !loading { lastWebLoadFinishedAt = Date() }
        }
    }

    private var loadingOverlay: some View {
        ProgressView()
            .controlSize(.large)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
            .transition(.opacity)
    }

    private var verifyingOverlay: some View {
        ProgressView("Checking your account…")
            .controlSize(.large)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial)
    }

    private func completionErrorOverlay(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't Finish Signing In", systemImage: "person.crop.circle.badge.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("Sign In Again") {
                completionError = nil
                retrySigninPage()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .background(.regularMaterial)
    }

    private var signinStalledOverlay: some View {
        ContentUnavailableView {
            Label("Sign In Didn't Load", systemImage: "exclamationmark.triangle")
        } description: {
            Text("Check your connection and try again.")
        } actions: {
            Button("Try Again") { retrySigninPage() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .background(.regularMaterial)
    }

    private var usesPKCE: Bool { !usesWebFallback }

    private var isAuthHandoff: Bool {
        if case .authHandoff = mode { return true }
        return false
    }

    private func beginSignIn() {
        webLoginPresentedAt = Date()
        if usesPKCE {
            startPKCE()
            return
        }
        startSigninLivenessClock()
        let clearsDefaultStore = !isAuthHandoff
        Task {
            if clearsDefaultStore { await AuthWebSession.clear() }
            webAttempt += 1
        }
    }

    private func startPKCE() {
        guard !isAuthenticating else { return }
        pkceError = nil
        isAuthenticating = true
        let ephemeral = isAuthHandoff
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            do {
                let session = try await SoundCloudPKCESignIn.signIn(ephemeral: ephemeral)
                isAuthenticating = false
                handleTokenReceived(
                    token: session.oauthToken,
                    refreshToken: session.refreshToken,
                    clientId: session.clientId,
                    expiry: session.expiresAt
                )
            } catch let failure as SoundCloudPKCESignIn.Failure {
                isAuthenticating = false
                if failure == .canceled {
                    finish()
                } else {
                    pkceError = SoundCloudPKCESignIn.message(for: failure)
                }
            } catch {
                isAuthenticating = false
                pkceError = SoundCloudPKCESignIn.message(for: .unavailable)
            }
        }
    }

    private func useWebsiteInstead() {
        pkceError = nil
        usesWebFallback = true
        isLoadingWeb = true
        beginSignIn()
    }

    @ViewBuilder
    private var pkceStatus: some View {
        if let message = pkceError ?? completionError {
            ContentUnavailableView {
                Label("Couldn’t Finish Signing In", systemImage: "person.crop.circle.badge.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") {
                    completionError = nil
                    startPKCE()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button("Use SoundCloud Website") { useWebsiteInstead() }
            }
        } else {
            ProgressView(isVerifyingSession ? "Checking your account…" : "")
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
        guard !usesPKCE else {
            completionError = nil
            isVerifyingSession = false
            incompleteCaptureRetries = 0
            startPKCE()
            return
        }
        signinLivenessTask?.cancel()
        signinStalled = false
        isLoadingWeb = true
        completionError = nil
        isVerifyingSession = false
        incompleteCaptureRetries = 0
        Task {
            await AuthWebSession.clear()
            webAttempt += 1
            lastWebLoadFinishedAt = nil
            webLoginPresentedAt = Date()
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
            statusScreen(
                symbol: "checkmark.circle.fill",
                tint: .green,
                title: "You're Signed In",
                message: nil
            ) {
                Button("Done") { finish() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
    }

    private func readyToSendView(_ session: StoredSession) -> some View {
        statusScreen(
            symbol: peerClass.symbolName,
            tint: .scAccent,
            title: "Sign In \(peerClass.displayName)",
            message: "Use the SoundCloud account on this \(DeviceClass.current.displayName)."
        ) {
            Button("Send to \(peerClass.displayName)") {
                startTransfer(with: session)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button("Use a Different Account") {
                Task { await useDifferentAccount() }
            }
        }
    }

    private var transferStatusView: some View {
        statusScreen(
            isWorking: isTransferWorking,
            symbol: transferSymbol,
            tint: transferTint,
            title: statusTitle,
            message: statusMessage
        ) {
            if case .rejected = transferState {
                Button("Sign In Again") {
                    Task { await useDifferentAccount() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Keep This \(DeviceClass.current.displayName) Signed In") {
                    cancelSignIn()
                }
            } else if case .failed = transferState {
                Button("Try Again") {
                    box.client?.startDiscovery()
                    if let session = pendingSession {
                        startTransfer(with: session)
                    } else {
                        isTransferring = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Sign In Again") {
                    Task { await useDifferentAccount() }
                }
            }
        }
    }

    private func statusScreen<Actions: View>(
        isWorking: Bool = false,
        symbol: String,
        tint: Color,
        title: String,
        message: String?,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        ContentUnavailableView {
            if isWorking {
                VStack(spacing: Spacing.md) {
                    ProgressView().controlSize(.large)
                    Text(title)
                        .font(.title2.weight(.semibold))
                }
            } else {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: symbol)
                        .foregroundStyle(tint)
                }
            }
        } description: {
            if let message, !message.isEmpty {
                Text(message)
            }
        } actions: {
            actions()
        }
    }

    private var isTransferCompleted: Bool {
        guard isTransferring, case .completed = transferState else { return false }
        return true
    }

    private var isTransferWorking: Bool {
        switch transferState {
        case .idle, .discovering, .connecting, .sending: return true
        case .completed, .failed, .rejected:             return false
        }
    }

    private var transferSymbol: String {
        switch transferState {
        case .completed: return "checkmark.circle.fill"
        case .failed:    return "exclamationmark.triangle.fill"
        case .rejected:  return "person.crop.circle.badge.exclamationmark"
        default:         return peerClass.symbolName
        }
    }

    private var transferTint: Color {
        switch transferState {
        case .completed: return .green
        case .failed:    return .red
        default:         return .scAccent
        }
    }

    private var statusTitle: String {
        switch transferState {
        case .idle, .discovering: return "Finding \(peerClass.displayName)…"
        case .connecting:         return "Connecting…"
        case .sending:            return "Signing In…"
        case .completed:          return "\(peerClass.displayName) Signed In"
        case .failed:             return "Couldn't Sign In"
        case .rejected:           return "\(peerClass.displayName) Couldn't Use This Login"
        }
    }

    private var statusMessage: String? {
        switch transferState {
        case .failed(let error), .rejected(let error): return error
        default:                                       return nil
        }
    }

    private var authHandoffStatusView: some View {
        statusScreen(
            isWorking: authHandoffIsWorking,
            symbol: authHandoffSymbol,
            tint: authHandoffTint,
            title: authHandoffStatusTitle,
            message: authHandoffStatusMessage
        ) {
            if case .failed = authHandoffState {
                Button("Try Again") {
                    authHandoffState = .idle
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private var authHandoffIsWorking: Bool {
        if case .sending = authHandoffState { return true }
        return false
    }

    private var authHandoffSymbol: String {
        if case .failed = authHandoffState { return "exclamationmark.triangle.fill" }
        return "checkmark.circle.fill"
    }

    private var authHandoffTint: Color {
        if case .failed = authHandoffState { return .red }
        return .green
    }

    private var authHandoffStatusTitle: String {
        switch authHandoffState {
        case .idle:      return ""
        case .sending:   return "Signing In \(peerClass.displayName)…"
        case .completed: return "\(peerClass.displayName) Signed In"
        case .failed:    return "Couldn't Sign In"
        }
    }

    private var authHandoffStatusMessage: String? {
        if case .failed(let error) = authHandoffState { return error }
        return nil
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
            authHandoffState = .sending
            companionClient?.sendAuthHandoffSession(session)
            finish()
            return
        case .link, .standalone:
            break
        }

        isVerifyingSession = true
        Task { await finishLocalSignIn(with: session) }
    }

    private func finishLocalSignIn(with session: StoredSession) async {
        DeviceSessionStore.save(session)
        SoundCloudCredentialSource.shared.didCompleteSignIn()
        DeviceSessionRefresher.shared.reset()

        let health = await SoundCloudCredentialSource.shared.revalidate()
        isVerifyingSession = false
        guard health == .healthy else {
            if case .waiting = SoundCloudAPI.shared.trafficSafetyState() {
                finish()
                return
            }
            completionError = health.needsSignIn
                ? "SoundCloud didn't accept the sign-in. Try again."
                : "Couldn't check your account. Check your connection and try again."
            return
        }

        #if DEBUG
        if ProcessInfo.processInfo.environment["SOUNDING_TV_PERSIST_DEV_CREDENTIAL"] == "1" {
            DevCredentialStore.save(DeviceSessionStore.load() ?? session)
        }
        #endif

        let verifiedSession = DeviceSessionStore.load() ?? session
        switch mode {
        case .link:
            startTransfer(with: verifiedSession)
        case .standalone:
            storedSession = verifiedSession
            finish()
        case .authHandoff:
            break
        }
    }

    private func startTransfer(with session: StoredSession) {
        pendingSession = session
        isTransferring = true
        Task.detached { [weak client = box.client, session] in
            waitForConnection: for _ in 0..<60 {
                let state = await MainActor.run { client?.state ?? .idle }
                switch state {
                case .failed, .rejected:
                    return
                case .connecting, .sending, .completed:
                    break waitForConnection
                case .idle, .discovering:
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }

            await MainActor.run { [session] in
                client?.sendToken(
                    session.oauthToken,
                    refreshToken: session.refreshToken,
                    clientId: session.clientId,
                    expiresAt: session.expiresAt
                )
            }
        }
    }

    private func useDifferentAccount() async {
        await SoundCloudCredentialSource.shared.signOut()
        pendingSession = nil
        storedSession = nil
        isTransferring = false
        forceWebLogin = true
        isLoadingWeb = true
        lastWebLoadFinishedAt = nil
        beginSignIn()
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
    @Environment(\.openURL) private var openURL

    func makeUIView(context: Context) -> WKWebView {
        let signIn = context.coordinator.signIn
        context.coordinator.parent = self
        context.coordinator.bind()
        let interaction = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.userInteracted))
        interaction.cancelsTouchesInView = false
        signIn.webView.addGestureRecognizer(interaction)
        context.coordinator.loadIfNeeded(attempt: attempt)
        return signIn.webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.loadIfNeeded(attempt: attempt)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.signIn.teardown()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self, signIn: SoundCloudWebSignIn(usesIsolatedStore: usesIsolatedDataStore))
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: OAuthWebView
        let signIn: SoundCloudWebSignIn
        private var loadedAttempt = 0

        init(parent: OAuthWebView, signIn: SoundCloudWebSignIn) {
            self.parent = parent
            self.signIn = signIn
        }

        func bind() {
            signIn.onFormReady = { [weak self] in
                self?.parent.isLoading = false
                self?.parent.onSigninUiMounted()
            }
            signIn.onLoadFailed = { [weak self] in
                self?.parent.isLoading = false
                self?.parent.onSigninUnavailable()
            }
            signIn.onRefreshMaterial = { [weak self] refresh, client in
                self?.parent.onRefreshMaterial(refresh, client)
            }
            signIn.onCapture = { [weak self] capture in
                self?.parent.onLogin(capture.accessToken, capture.refreshToken, capture.clientId, capture.expiresAt)
            }
            signIn.onOpenExternally = { [weak self] url in
                self?.parent.openURL(url)
            }
        }

        func loadIfNeeded(attempt: Int) {
            guard attempt > 0, attempt != loadedAttempt else { return }
            loadedAttempt = attempt
            signIn.load(.signIn)
        }

        @objc func userInteracted() {
            parent.onUserInteraction()
        }
    }
}
