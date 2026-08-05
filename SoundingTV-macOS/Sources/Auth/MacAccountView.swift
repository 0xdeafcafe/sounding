import SwiftUI
import WebKit

struct MacSettingsAccountTab: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    @ObservedObject private var sync = MacSyncCoordinator.shared
    @ObservedObject private var subscription = SubscriptionService.shared
    @ObservedObject private var downloads = DownloadManager.shared

    @State private var isSyncing = false
    @State private var isCheckingPlan = false
    @State private var signedOutLocallyAt: Date?
    @State private var isShowingWebSignIn = false
    @State private var isReauthentication = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if credentials.isSignedOut {
                    onboardingCard
                } else if credentials.isSessionRejected {
                    recoveryCard
                }
                identityCard
                planCard
                soundCloudManagementCard
                syncCard
            }
            .frame(maxWidth: 560)
            .padding(24)
        }
        .task { refreshLocalSignOut() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            credentials.refreshFromStore()
            Task {
                await credentials.revalidate()
                if !credentials.isSignedOut { await subscription.verifyNow() }
            }
        }
        .sheet(isPresented: $isShowingWebSignIn) {
            MacSoundCloudSignInView(peerName: nil, forHandoff: false, isReauthentication: isReauthentication) {
                credentials.didCompleteSignIn()
                refreshLocalSignOut()
                isShowingWebSignIn = false
            }
            .frame(minWidth: 720, minHeight: 620)
        }
    }

    private func refreshLocalSignOut() {
        signedOutLocallyAt = SessionSyncBookkeeping.localSignOutMillis()
            .map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    private var isSyncPausedBySignOut: Bool {
        credentials.isSignedOut && signedOutLocallyAt != nil
    }

    private var identityCard: some View {
        MacInsetCard {
            HStack(spacing: SCContentStyle.mac.spaceBase) {
                avatar
                VStack(alignment: .leading, spacing: 3) {
                    Text(identityTitle)
                        .font(.system(size: 15, weight: .semibold))
                    Text(identitySubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(SCContentStyle.mac.spaceGutter)

            if !credentials.isSignedOut {
                MacInsetActionRow(title: "Sign Out on This Mac", role: .destructive, isLast: true) {
                    Task {
                        await credentials.signOut()
                        refreshLocalSignOut()
                    }
                }
            }
        }
    }

    private var planCard: some View {
        VStack(alignment: .leading, spacing: SCContentStyle.mac.spaceTight) {
            MacInsetCard {
                MacInsetRow(title: "SoundCloud plan", isLast: false) {
                    Text(planName).foregroundStyle(.secondary)
                }
                MacInsetRow(title: "Verification", isLast: false) {
                    Text(planVerification).foregroundStyle(planVerificationColor)
                }
                MacInsetRow(title: "Offline downloads", isLast: downloads.scheduledDeletionDate == nil) {
                    Text("Based on track availability")
                        .foregroundStyle(.secondary)
                }
                if let deletionDate = downloads.scheduledDeletionDate {
                    MacInsetRow(title: "Downloads removed", isLast: false) {
                        Text(deletionDate, format: .dateTime.day().month().year())
                            .foregroundStyle(.orange)
                    }
                }
                MacInsetActionRow(title: "Manage Subscription on SoundCloud", isLast: false) {
                    openURL(SoundCloudAccountPages.subscriptions)
                }
                MacInsetActionRow(title: isCheckingPlan ? "Checking Plan…" : "Check Plan Now", isLast: true) {
                    guard !isCheckingPlan else { return }
                    isCheckingPlan = true
                    Task {
                        await subscription.verifyNow()
                        isCheckingPlan = false
                    }
                }
                .rowDisabled(isCheckingPlan)
            }

            Text(subscription.statusDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, SCContentStyle.mac.spaceHair)
        }
    }

    private var soundCloudManagementCard: some View {
        VStack(alignment: .leading, spacing: SCContentStyle.mac.spaceTight) {
            MacInsetCard {
                soundCloudManagementRow(
                    "Security, 2FA & Access",
                    destination: SoundCloudAccountPages.account,
                    isLast: false
                )
                soundCloudManagementRow(
                    "Notifications",
                    destination: SoundCloudAccountPages.notifications,
                    isLast: false
                )
                soundCloudManagementRow(
                    "Privacy",
                    destination: SoundCloudAccountPages.privacy,
                    isLast: false
                )
                soundCloudManagementRow(
                    "Communications",
                    destination: SoundCloudAccountPages.communications,
                    isLast: false
                )
                soundCloudManagementRow(
                    "Analytics Preferences",
                    destination: SoundCloudAccountPages.analytics,
                    isLast: false
                )
                soundCloudManagementRow(
                    "Advertising Preferences",
                    destination: SoundCloudAccountPages.advertising,
                    isLast: true
                )
            }

            Text("Sensitive account changes open on SoundCloud's website. SoundingCloud never handles passwords, authenticator secrets, backup codes, or billing details.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, SCContentStyle.mac.spaceHair)
        }
    }

    private func soundCloudManagementRow(
        _ title: String,
        destination: URL,
        isLast: Bool
    ) -> some View {
        MacInsetActionRow(title: title, isLast: isLast) {
            openURL(destination)
        }
    }

    private var planName: String {
        switch subscription.tier {
        case .free: return "Free"
        case .go: return "Go"
        case .goPlus: return "Go+"
        case .creatorPro: return "Creator"
        case .unknown: return "Unknown"
        }
    }

    private var planVerification: String {
        switch subscription.verification {
        case .verified: return "Verified"
        case .unverifiable(let withinGrace): return withinGrace ? "Grace period" : "Unavailable"
        case .verifiedNotSubscribed: return "Not subscribed"
        }
    }

    private var planVerificationColor: Color {
        switch subscription.verification {
        case .verified: return .green
        case .unverifiable(let withinGrace): return withinGrace ? .orange : .secondary
        case .verifiedNotSubscribed: return .red
        }
    }

    private var onboardingCard: some View {
        MacInsetCard {
            VStack(alignment: .leading, spacing: SCContentStyle.mac.spaceTight) {
                Label("Sign in to SoundCloud", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.headline)
                Text("Sign in securely in the SoundCloud web view on this Mac. Your session is stored in Keychain and can sync to your other SoundingCloud devices.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let deletionDate = credentials.lockedDataDeletionDate {
                    Label(
                        "Guest mode is available. Saved account data will be cleared \(deletionDate.formatted(date: .abbreviated, time: .shortened)) unless you sign in again.",
                        systemImage: "clock.badge.exclamationmark"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }

                HStack(spacing: SCContentStyle.mac.spaceSnug) {
                    Button("Sign in on This Mac") {
                        isReauthentication = false
                        isShowingWebSignIn = true
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Sync Existing Session") {
                        runSyncNow()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isSyncing)
                }
            }
            .padding(SCContentStyle.mac.spaceGutter)
        }
    }

    private var recoveryCard: some View {
        MacInsetCard {
            VStack(alignment: .leading, spacing: SCContentStyle.mac.spaceTight) {
                Label("SoundCloud Session Expired", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(credentials.sessionRecoveryMessage ?? "Reauthenticate to continue.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Reauthenticate") {
                    isReauthentication = true
                    isShowingWebSignIn = true
                }
                    .buttonStyle(.borderedProminent)
            }
            .padding(SCContentStyle.mac.spaceGutter)
        }
    }

    private var identityTitle: String {
        if credentials.isSignedOut { return "Please Sign In" }
        if credentials.isSessionRejected { return "Session Expired" }
        return credentials.currentUser?.username ?? "SoundCloud"
    }

    private var identitySubtitle: String {
        if credentials.isSignedOut {
            if let date = credentials.lockedDataDeletionDate {
                return "Guest mode · saved data clears \(date.formatted(date: .abbreviated, time: .shortened))"
            }
            return "Guest mode · sign in to save, follow, message, or download."
        }
        if credentials.isSessionRejected {
            return "Please reauthenticate. Cached data is preserved."
        }
        guard let user = credentials.currentUser else {
            return "Session found, loading profile…"
        }
        return "\(user.followersCount) followers · \(user.trackCount) tracks"
    }

    @ViewBuilder
    private var avatar: some View {
        let size: CGFloat = 44
        if let url = credentials.currentUser?.avatarURL {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Circle().fill(Color.accentColor.opacity(0.25))
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else {
            Circle()
                .fill(Color.accentColor.opacity(0.25))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "person.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(Color.accentColor)
                )
        }
    }

    private var syncCard: some View {
        VStack(alignment: .leading, spacing: SCContentStyle.mac.spaceTight) {
            MacInsetCard {
                MacInsetRow(title: "Session sync", isLast: false) {
                    Text(isSyncPausedBySignOut ? "Paused - you signed out on this Mac" : "CloudKit, every 5 min")
                        .foregroundStyle(.secondary)
                }
                if isSyncPausedBySignOut, let signedOutLocallyAt {
                    MacInsetRow(title: "Signed out here", isLast: false) {
                        Text(signedOutLocallyAt, format: .dateTime.day().month().year().hour().minute())
                            .foregroundStyle(.secondary)
                    }
                }
                MacInsetRow(title: "Last successful sync", isLast: false) {
                    if let lastRunAt = sync.lastSuccessfulRunAt {
                        Text(lastRunAt, style: .relative)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Not yet").foregroundStyle(.secondary)
                    }
                }
                MacInsetRow(title: "Last attempt", isLast: sync.failureMessage == nil) {
                    if let lastAttemptAt = sync.lastAttemptAt {
                        Text(lastAttemptAt, style: .relative)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Not yet").foregroundStyle(.secondary)
                    }
                }
                if let failureMessage = sync.failureMessage {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("Sync needs attention", systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                        Text(failureMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(SCContentStyle.mac.spaceGutter)
                    .accessibilityElement(children: .combine)
                }
                if isSyncPausedBySignOut {
                    MacInsetActionRow(title: "Resume Session Sync", isLast: false) {
                        SessionSyncBookkeeping.clearLocalSignOut()
                        refreshLocalSignOut()
                        runSyncNow()
                    }
                    .rowDisabled(isSyncing)
                }
                MacInsetActionRow(title: isSyncing ? "Syncing…" : "Sync Now", isLast: true) {
                    runSyncNow()
                }
                .rowDisabled(isSyncing)
            }

            Text(syncFootnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, SCContentStyle.mac.spaceHair)
        }
    }

    private func runSyncNow() {
        guard !isSyncing else { return }
        isSyncing = true
        Task {
            await sync.runOnce()
            credentials.refreshFromStore()
            refreshLocalSignOut()
            isSyncing = false
        }
    }

    private var syncFootnote: String {
        if isSyncPausedBySignOut {
            return "This Mac is signed out. Resume Session Sync to pick up the account from your other signed-in devices again."
        }
        if credentials.isSignedOut {
            return "Sign in on iPhone or Apple TV first. This Mac picks that session up through iCloud. Sync Now checks straight away."
        }
        return "This Mac's SoundCloud session came from another signed-in device."
    }

    private var dangerCard: some View {
        VStack(alignment: .leading, spacing: SCContentStyle.mac.spaceTight) {
            MacInsetCard {
                MacInsetActionRow(title: "Forget This Account", role: .destructive, isLast: true) {
                    DeviceSessionStore.forget()
                    credentials.refreshFromStore()
                    refreshLocalSignOut()
                }
            }

            Text("Signs out on this Mac only. Your iPhone and Apple TV keep their sign-in, and session sync stops pulling their account onto this Mac until you choose Resume Session Sync.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, SCContentStyle.mac.spaceHair)
        }
    }
}

struct MacSoundCloudSignInView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var companionClient: CompanionClient
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var startView: MacSoundCloudAuthStartView = .signIn
    let peerName: String?
    let forHandoff: Bool
    var isReauthentication = false
    let onComplete: () -> Void

    private var title: String {
        if forHandoff { return "Sign in for \(peerName ?? "device")" }
        return isReauthentication ? "Reauthenticate with SoundCloud" : "Sign in to SoundCloud"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(forHandoff
                         ? "This SoundCloud session will be sent to your \(peerName ?? "device") and used only there."
                         : "The page below is provided by SoundCloud.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Account flow", selection: $startView) {
                    ForEach(MacSoundCloudAuthStartView.allCases) { view in
                        Text(view.label).tag(view)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 190)
                Button("Cancel") { dismiss() }
            }
            .padding(16)

            Divider()

            ZStack {
                MacSoundCloudOAuthWebView(
                    isLoading: $isLoading,
                    usesIsolatedDataStore: forHandoff,
                    startView: startView
                ) { session in
                    if forHandoff {
                        companionClient.sendAuthHandoffSession(session)
                    } else {
                        DeviceSessionStore.save(session)
                    }
                    onComplete()
                } onError: { message in
                    errorMessage = message
                }

                if isLoading {
                    ProgressView("Loading SoundCloud…")
                        .padding(22)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }

                if let errorMessage {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title)
                            .foregroundStyle(.orange)
                        Text("Sign-In Couldn’t Finish").font(.headline)
                        Text(errorMessage)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Close") { dismiss() }
                    }
                    .padding(24)
                    .frame(maxWidth: 360)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
        }
    }
}

private enum MacSoundCloudAuthStartView: String, CaseIterable, Identifiable {
    case signIn = "sign_in"
    case createAccount = "create_account"

    var id: String { rawValue }
    var label: String { self == .signIn ? "Sign In" : "Create Account" }
}

private struct MacSoundCloudOAuthWebView: NSViewRepresentable {
    @Binding var isLoading: Bool
    let usesIsolatedDataStore: Bool
    let startView: MacSoundCloudAuthStartView
    let onSession: (StoredSession) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self, isolatedStoreIdentifier: usesIsolatedDataStore ? UUID() : nil)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        if let storeID = context.coordinator.isolatedStoreIdentifier {
            configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: storeID)
        } else {
            configuration.websiteDataStore = .default()
        }
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.observe(configuration.websiteDataStore.httpCookieStore)
        context.coordinator.lastStartView = startView
        if let url = Self.authURL(startView: startView) {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.lastStartView != startView,
           let url = Self.authURL(startView: startView) {
            context.coordinator.lastStartView = startView
            webView.load(URLRequest(url: url))
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.teardown(webView: webView)
    }

    private static func authURL(startView: MacSoundCloudAuthStartView) -> URL? {
        URL(string: startView == .signIn
            ? "https://m.soundcloud.com/signin"
            : "https://m.soundcloud.com/signup")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
        var parent: MacSoundCloudOAuthWebView
        let isolatedStoreIdentifier: UUID?
        private var completed = false
        private var reachedSigninCallback = false
        private var capturedClientID: String?
        private weak var cookieStore: WKHTTPCookieStore?
        var lastStartView: MacSoundCloudAuthStartView?

        init(parent: MacSoundCloudOAuthWebView, isolatedStoreIdentifier: UUID?) {
            self.parent = parent
            self.isolatedStoreIdentifier = isolatedStoreIdentifier
        }

        func observe(_ store: WKHTTPCookieStore) {
            cookieStore?.remove(self)
            cookieStore = store
            store.add(self)
        }

        func teardown(webView: WKWebView) {
            cookieStore?.remove(self)
            cookieStore = nil
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
            if let url = webView.url {
                captureClientID(from: url)
                if Self.isSigninCallback(url) { reachedSigninCallback = true }
            }
            if reachedSigninCallback {
                inspectCookies(in: webView.configuration.websiteDataStore.httpCookieStore)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            if let url = navigationAction.request.url {
                captureClientID(from: url)
                if Self.isSigninCallback(url) { reachedSigninCallback = true }
            }
            return .allow
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            parent.isLoading = false
            parent.onError(error.localizedDescription)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
            return nil
        }

        private func inspectCookies(in store: WKHTTPCookieStore) {
            store.getAllCookies { [weak self] cookies in
                guard let self, !self.completed, self.reachedSigninCallback else { return }
                let tokenNames = ["oauth_token", "OAuth-Token", "sc-token"]
                guard let token = cookies.first(where: { cookie in
                    cookie.domain.lowercased().contains("soundcloud")
                        && tokenNames.contains(where: { $0.caseInsensitiveCompare(cookie.name) == .orderedSame })
                        && !cookie.value.isEmpty
                })?.value else { return }
                let refreshNames = ["oauth_refresh_token", "oauth-refresh-token", "sc-refresh-token"]
                guard let refresh = cookies.first(where: { cookie in
                    refreshNames.contains(where: { $0.caseInsensitiveCompare(cookie.name) == .orderedSame })
                        && !cookie.value.isEmpty
                })?.value,
                      let clientID = self.capturedClientID,
                      !clientID.isEmpty else { return }
                self.complete(StoredSession(
                    oauthToken: token,
                    refreshToken: refresh,
                    clientId: clientID,
                    expiresAt: nil
                ))
            }
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            guard reachedSigninCallback else { return }
            inspectCookies(in: cookieStore)
        }

        private func captureClientID(from url: URL) {
            guard capturedClientID == nil else { return }
            capturedClientID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "client_id" })?
                .value
        }

        private static func isSigninCallback(_ url: URL) -> Bool {
            (url.host ?? "").lowercased() == "m.soundcloud.com"
                && url.path.hasPrefix("/signin/callback")
        }

        private func complete(_ session: StoredSession) {
            guard !completed else { return }
            completed = true
            removeIsolatedStoreIfNeeded()
            DispatchQueue.main.async { self.parent.onSession(session) }
        }

        private func removeIsolatedStoreIfNeeded() {
            guard let isolatedStoreIdentifier else { return }
            Task {
                try? await WKWebsiteDataStore.remove(forIdentifier: isolatedStoreIdentifier)
            }
        }

    }
}

struct MacSettingsAudioTab: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var player = PlayerService.shared

    var body: some View {
        Form {
            Section("Quality") {
                Picker("Streaming quality", selection: store.streamingQualityCeilingBinding) {
                    ForEach(QualityCeiling.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                Picker("Download quality", selection: store.downloadQualityCeilingBinding) {
                    ForEach(QualityCeiling.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                Text(QualitySizeEstimator.summaryLine() + ". SoundCloud's available source still sets the upper limit.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            MacCollectionQualityOverridesSection()

            Section("Auto-Mix") {
                Toggle("Enable Auto-Mix", isOn: store.djAutoMixEnabledBinding)
                Picker("Personality", selection: store.djDefaultProfileIdBinding) {
                    ForEach(DJProfile.all) { profile in
                        Text(profile.displayName).tag(profile.id)
                    }
                }
                .disabled(!store.djAutoMixEnabled)
                Stepper(
                    value: store.djTransitionLengthSecondsBinding,
                    in: SettingsStore.djTransitionLengthRange,
                    step: 1
                ) {
                    LabeledContent("Default transition") {
                        Text("\(Int(store.djTransitionLengthSeconds)) sec")
                            .monospacedDigit()
                    }
                }
                .disabled(!store.djAutoMixEnabled)
            }

            Section("Library") {
                Picker("Treat tracks as sets at", selection: store.setMinimumDurationSecondsBinding) {
                    ForEach(GeneratedLibraryCollections.setDurationPresets, id: \.self) { duration in
                        Text(GeneratedLibraryCollections.durationLabel(duration)).tag(duration)
                    }
                }
                Text("Sets are generated from duration metadata in your saved tracks. Changing this never downloads audio.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Sync") {
                syncToggle("Streaming quality", SettingKeys.StreamingQualityCeiling.self)
                syncToggle("Download quality", SettingKeys.DownloadQualityCeiling.self)
                syncToggle("Auto-Mix", SettingKeys.DJAutoMixEnabled.self)
                syncToggle("DJ personality", SettingKeys.DJDefaultProfileId.self)
                syncToggle("Transition length", SettingKeys.DJTransitionLengthSeconds.self)
                syncToggle("Set length", SettingKeys.SetMinimumDurationSeconds.self)
                syncToggle("Collection policies", SettingKeys.CollectionPolicies.self)
                Text("Turn a switch off to keep this Mac's own value instead of sharing it with your other devices.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Audio Output") {
                LabeledContent("Device", value: PlatformAudioSession.outputName ?? "None")
                LabeledContent("Transport", value: PlatformAudioSession.outputKind.rawValue)
                LabeledContent("Output channels", value: "\(PlatformAudioSession.maximumOutputChannels)")
                LabeledContent(
                    "Separate cue bus",
                    value: PlatformAudioSession.supportsSeparateCueBus ? "Available" : "Requires 4+ outputs"
                )
                LabeledContent("Playback status", value: player.isPlaying ? "Playing" : "Idle")
            }
        }
        .formStyle(.grouped)
    }

    private func syncToggle<K: SettingDefinition>(_ title: String, _ key: K.Type) -> some View {
        Toggle(title, isOn: Binding(
            get: { store.effectiveScope(key) == .synced },
            set: { store.setForceDeviceLocal(key, !$0) }
        ))
    }
}

private struct MacCollectionQualityOverridesSection: View {
    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @ObservedObject private var overrides = CollectionQualityOverrideStore.shared
    @State private var playlists: [Playlist] = []
    @State private var isLoading = false
    @State private var failed = false
    @State private var isManaging = false

    var body: some View {
        Section("Quality by Collection") {
            if isLoading && playlists.isEmpty {
                HStack {
                    Text("Loading playlists…")
                        .foregroundStyle(.secondary)
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                }
            } else if failed && playlists.isEmpty {
                HStack {
                    Text("Playlists couldn't be loaded.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry") { Task { await load() } }
                }
            } else if playlists.isEmpty {
                Text("No playlists yet.")
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("Custom overrides", value: "\(overrideCount)")
                Button("Manage Collection Quality…") { isManaging = true }
            }

            Text("A collection override applies to streaming and downloads for that playlist or set. Audio is still downloaded only when you ask for it or enable an offline policy.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .task { await load() }
        .sheet(isPresented: $isManaging) {
            MacCollectionQualityManager(playlists: playlists)
        }
    }

    private func binding(for playlistID: String) -> Binding<QualityCeiling?> {
        Binding(
            get: { overrides.override(for: playlistID) },
            set: { overrides.setOverride($0, for: playlistID) }
        )
    }

    private var overrideCount: Int {
        playlists.lazy.filter { overrides.override(for: $0.id) != nil }.count
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        failed = false
        defer { isLoading = false }

        let user: User?
        if let currentUser = credentials.currentUser {
            user = currentUser
        } else {
            user = await credentials.waitForCurrentUser()
        }
        guard let user else {
            failed = true
            return
        }
        do {
            let page = try await SoundCloudAPI.shared.getUserPlaylists(userId: user.id, limit: 50)
            playlists = page.collection
            failed = false
        } catch {
            failed = true
        }
    }
}

private struct MacCollectionQualityManager: View {
    let playlists: [Playlist]
    @ObservedObject private var overrides = CollectionQualityOverrideStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Collection Quality").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            List(filteredPlaylists) { playlist in
                Picker(selection: binding(for: playlist.id)) {
                    Text("Use Default").tag(QualityCeiling?.none)
                    ForEach(QualityCeiling.allCases) { quality in
                        Text(quality.displayName).tag(QualityCeiling?.some(quality))
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playlist.title).lineLimit(1)
                        Text(CollectionKind.classify(playlist: playlist).displayName)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .pickerStyle(.menu)
            }
            .searchable(text: $searchText, prompt: "Search collections")
        }
        .frame(minWidth: 620, minHeight: 500)
    }

    private var filteredPlaylists: [Playlist] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return playlists }
        return playlists.filter { $0.title.localizedCaseInsensitiveContains(needle) }
    }

    private func binding(for id: String) -> Binding<QualityCeiling?> {
        Binding(get: { overrides.override(for: id) }, set: { overrides.setOverride($0, for: id) })
    }
}

struct MacSettingsDownloadsTab: View {
    @EnvironmentObject private var companionClient: CompanionClient
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var subscription = SubscriptionService.shared
    @State private var showingRemoveAllConfirmation = false
    @State private var isManagingDownloads = false
    @State private var remoteDownloads: [String: [DownloadManifestSyncRecord]] = [:]
    @State private var transferringDeviceIDs: Set<String> = []

    var body: some View {
        Form {
            Section("Storage") {
                LabeledContent("Used") {
                    Text("\(byteString(downloads.usedBytes)) of \(byteString(store.downloadStorageCapBytes))")
                }
                ProgressView(value: storageFraction)
                Picker("Storage limit", selection: store.downloadStorageCapBytesBinding) {
                    ForEach(Self.storageLimits, id: \.self) { bytes in
                        Text(byteString(bytes)).tag(bytes)
                    }
                }
                .pickerStyle(.menu)
                Picker("Download quality", selection: store.downloadQualityCeilingBinding) {
                    ForEach(QualityCeiling.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                .pickerStyle(.menu)
            }

            Section("Downloads") {
                LabeledContent("Download access", value: "Based on track availability")
                LabeledContent("Network", value: networkDescription)
                if let deletionDate = downloads.scheduledDeletionDate {
                    Label(
                        "Offline files will be removed \(deletionDate.formatted(date: .abbreviated, time: .shortened)) unless the subscription is renewed.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
            }

            if !activeEntries.isEmpty {
                Section("In Progress") {
                    ForEach(activeEntries, id: \.track.id) { entry in
                        MacDownloadSettingsRow(entry: entry, state: downloads.state(for: entry.track.id))
                    }
                }
            }

            Section("Downloaded Audio") {
                if downloadedEntries.isEmpty {
                    Text("No audio downloaded to this Mac yet.")
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("Available offline", value: "\(downloadedEntries.count)")
                    LabeledContent("Storage used", value: byteString(downloads.usedBytes))
                    Button("Manage Downloaded Audio…") { isManagingDownloads = true }
                }
            }

            Section("Other Devices") {
                if remoteDownloads.isEmpty {
                    Text("No download availability has synced from another device yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(remoteDownloads.keys.sorted(), id: \.self) { deviceID in
                        if let records = remoteDownloads[deviceID], let first = records.first {
                            LabeledContent(first.deviceLabel) {
                                Button(transferringDeviceIDs.contains(deviceID) ? "Copying…" : "Copy \(records.count)") {
                                    Task { await copy(records, from: deviceID) }
                                }
                                .disabled(transferringDeviceIDs.contains(deviceID))
                            }
                        }
                    }
                }
                Text("When the source device is awake on your local network, Copy transfers its existing audio over the authenticated companion link and encrypts it for this Mac.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !downloads.entries.isEmpty {
                Section {
                    Button("Remove All Downloads…", role: .destructive) {
                        showingRemoveAllConfirmation = true
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            remoteDownloads = await RemoteDownloadManifestStore.shared.manifestsByDevice(
                excluding: DownloadManifestDeviceIdentity.deviceId()
            )
        }
        .confirmationDialog("Remove All Downloads", isPresented: $showingRemoveAllConfirmation) {
            Button("Remove All Downloads", role: .destructive) { removeAllDownloads() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Downloaded audio will be deleted from this Mac. Library metadata and analysis remain available.")
        }
        .sheet(isPresented: $isManagingDownloads) {
            MacDownloadedAudioManager()
        }
    }

    private func copy(_ records: [DownloadManifestSyncRecord], from deviceID: String) async {
        transferringDeviceIDs.insert(deviceID)
        defer { transferringDeviceIDs.remove(deviceID) }
        for record in records where !Task.isCancelled {
            _ = await downloads.downloadFromPeer(
                trackId: record.trackId,
                sourceDeviceId: deviceID,
                provider: companionClient,
                pinned: record.isPinned
            )
        }
    }

    private var sortedEntries: [DownloadEntry] {
        downloads.entries.values.sorted { $0.addedAt > $1.addedAt }
    }

    private var activeEntries: [DownloadEntry] { sortedEntries.filter { !$0.isDownloaded } }
    private var downloadedEntries: [DownloadEntry] { sortedEntries.filter(\.isDownloaded) }

    private var storageFraction: Double {
        guard store.downloadStorageCapBytes > 0 else { return 0 }
        return min(1, Double(downloads.usedBytes) / Double(store.downloadStorageCapBytes))
    }

    private var networkDescription: String {
        if !downloads.hasConnectivity { return "Offline" }
        return downloads.isOnUnmeteredNetwork ? "Connected" : "Limited network"
    }

    private static let storageLimits: [Int64] = [
        500_000_000,
        1_000_000_000,
        2_000_000_000,
        5_000_000_000,
        10_000_000_000,
        20_000_000_000,
    ]

    private func removeAllDownloads() {
        for trackID in Array(downloads.entries.keys) {
            downloads.cancel(trackId: trackID)
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        Self.byteFormatter.string(fromByteCount: bytes)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}

private struct MacDownloadedAudioManager: View {
    @ObservedObject private var downloads = DownloadManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var showingRemoveAllConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Downloaded Audio").font(.title2.bold())
                    Text("\(entries.count) tracks · \(byteString(downloads.usedBytes))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()

            if entries.isEmpty {
                ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredEntries, id: \.track.id) { entry in
                    MacDownloadSettingsRow(entry: entry, state: .downloaded)
                }
                .searchable(text: $searchText, prompt: "Search downloads")
            }

            Divider()
            HStack {
                Button("Remove All…", role: .destructive) { showingRemoveAllConfirmation = true }
                Spacer()
            }
            .padding(12)
        }
        .frame(minWidth: 680, minHeight: 520)
        .confirmationDialog("Remove All Downloads", isPresented: $showingRemoveAllConfirmation) {
            Button("Remove All Downloads", role: .destructive) {
                for id in Array(downloads.entries.keys) { downloads.cancel(trackId: id) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var entries: [DownloadEntry] {
        downloads.entries.values.filter(\.isDownloaded).sorted { $0.addedAt > $1.addedAt }
    }

    private var filteredEntries: [DownloadEntry] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return entries }
        return entries.filter {
            $0.track.title.localizedCaseInsensitiveContains(needle)
                || $0.track.user.displayName.localizedCaseInsensitiveContains(needle)
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct MacDownloadSettingsRow: View {
    let entry: DownloadEntry
    let state: DownloadState

    var body: some View {
        HStack(spacing: 10) {
            AsyncImage(url: entry.track.artworkURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 5).fill(.quaternary)
                }
            }
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.track.title).lineLimit(1)
                Text(entry.track.user.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(stateLabel)
                .font(.caption)
                .foregroundStyle(stateTint)
                .monospacedDigit()
            stateButton
            Button("Remove", systemImage: "trash", role: .destructive) {
                DownloadManager.shared.cancel(trackId: entry.track.id)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
    }

    private var stateLabel: String {
        switch state {
        case .notDownloaded: return "Waiting"
        case .queued: return "Queued"
        case .downloading(let progress): return "\(Int(progress * 100))%"
        case .paused: return "Paused"
        case .downloaded: return entry.fileSize > 0 ? byteString(entry.fileSize) : "Downloaded"
        case .failed: return "Failed"
        }
    }

    private var stateTint: Color {
        if case .failed = state { return .red }
        return .secondary
    }

    @ViewBuilder
    private var stateButton: some View {
        switch state {
        case .queued, .downloading:
            Button("Pause", systemImage: "pause.fill") { DownloadManager.shared.pause(trackId: entry.track.id) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        case .paused, .failed, .notDownloaded:
            Button("Resume", systemImage: "arrow.clockwise") { DownloadManager.shared.resume(trackId: entry.track.id) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        case .downloaded:
            Image(systemName: entry.isEffectivelyPinned ? "pin.fill" : "checkmark.circle.fill")
                .foregroundStyle(entry.isEffectivelyPinned ? Color.accentColor : Color.secondary)
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct MacSettingsStorageTab: View {
    @State private var snapshot: AnalysisDataSnapshot?
    @State private var showingClearAnalysis = false
    @State private var showingClearLibrary = false

    var body: some View {
        Form {
            Section("Analysis") {
                LabeledContent("Tracks analysed", value: count(\.analysedTrackCount))
                LabeledContent("Results stored", value: count(\.resultCount))
                LabeledContent("From other devices", value: count(\.syncedResultCount))
                LabeledContent("Analysis data", value: usageText)
                LabeledContent("Tempo and key", value: count(\.tempoKeyCount))
                LabeledContent("Genres", value: count(\.genreCount))
                LabeledContent("Waveforms", value: count(\.waveformCount))
            }

            Section("Library Metadata") {
                LabeledContent("Offline library cache", value: libraryText)
                Text("Saved tracks, playlists and stations are indexed in the background. Audio is downloaded only when requested or allowed by a collection policy.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Open Music Intelligence…") { MacRootSelection.shared.request(.intelligence) }
                Button("Clear Analysis Data…", role: .destructive) { showingClearAnalysis = true }
                Button("Clear Library Cache…", role: .destructive) { showingClearLibrary = true }
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
        .confirmationDialog("Clear Analysis Data", isPresented: $showingClearAnalysis) {
            Button("Clear Analysis Data", role: .destructive) {
                Task { await AnalysisDataUsage.clearAnalysisData(); await refresh() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Clear Library Cache", isPresented: $showingClearLibrary) {
            Button("Clear Library Cache", role: .destructive) {
                Task { await AnalysisDataUsage.clearLibraryCache(); await refresh() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func refresh() async { snapshot = await AnalysisDataUsage.snapshot() }
    private func count(_ keyPath: KeyPath<AnalysisDataSnapshot, Int>) -> String {
        guard let snapshot else { return "–" }
        let value = snapshot[keyPath: keyPath]
        return snapshot.isTruncated ? "\(value)+" : "\(value)"
    }
    private var usageText: String {
        guard let snapshot else { return "–" }
        return "\(byteString(snapshot.usedBytes)) of \(byteString(snapshot.maxBytes))"
    }
    private var libraryText: String { snapshot.map { byteString($0.libraryDiskBytes) } ?? "–" }
    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct MacSettingsAdvancedTab: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var player = PlayerService.shared
    @State private var showingReset = false

    var body: some View {
        Form {
            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                Link("Source Code", destination: URL(string: "https://github.com/0xdeafcafe/sounding-tv")!)
            }
            Section("Diagnostics") {
                LabeledContent("Playback stalls", value: "\(player.observedStalls)")
                LabeledContent("Settings writer", value: store.writerIdForSync)
                    .textSelection(.enabled)
            }
            Section {
                Button("Reset All Settings…", role: .destructive) { showingReset = true }
                Text("Resets quality, downloads, Auto-Mix defaults, and per-device sync overrides. Your library and downloaded audio are not removed.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset All Settings", isPresented: $showingReset) {
            Button("Reset All Settings", role: .destructive) { resetAllSettings() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func resetAllSettings() {
        store.setStreamingQualityCeiling(SettingKeys.StreamingQualityCeiling.defaultValue)
        store.setDownloadQualityCeiling(SettingKeys.DownloadQualityCeiling.defaultValue)
        store.setDownloadStorageCapBytes(SettingKeys.DownloadStorageCapBytes.defaultValue)
        store.setDJAutoMixEnabled(SettingKeys.DJAutoMixEnabled.defaultValue)
        store.setDJDefaultProfileId(SettingKeys.DJDefaultProfileId.defaultValue)
        store.setDJTransitionLengthSeconds(SettingKeys.DJTransitionLengthSeconds.defaultValue)
        store.setForceDeviceLocal(SettingKeys.StreamingQualityCeiling.self, false)
        store.setForceDeviceLocal(SettingKeys.DownloadQualityCeiling.self, false)
        store.setForceDeviceLocal(SettingKeys.DJAutoMixEnabled.self, false)
        store.setForceDeviceLocal(SettingKeys.DJDefaultProfileId.self, false)
        store.setForceDeviceLocal(SettingKeys.DJTransitionLengthSeconds.self, false)
        store.setForceDeviceLocal(SettingKeys.CollectionPolicies.self, false)
    }
}

@MainActor
final class MacIntelligenceModel: ObservableObject {
    struct ProducerStat: Identifiable {
        let engine: MacAnalysisEngineKind
        var rows = 0
        var tracks = 0
        var withBPM = 0
        var withKey = 0
        var withGenre = 0
        var bytes = 0
        var id: String { engine.displayName }
    }

    struct TrackLine: Identifiable {
        let trackId: String
        let track: Track?
        let records: [MacAnalysisRecord]
        let result: MacAnalysisResult?
        let correction: MacAnalysisCorrection?
        let cueCount: Int
        let workState: AnalysisWorkState?

        var id: String { trackId }
        var titleKey: String { track?.title ?? trackId }
        var artistKey: String { track?.user.displayName ?? "" }
        var bytes: Int { records.reduce(0) { $0 + $1.byteSize } }
        var analysedAt: Date { records.map(\.producedAt).max() ?? .distantPast }
        var isCorrected: Bool { correction?.isEmpty == false }
    }

    @Published private(set) var lines: [TrackLine] = []
    @Published private(set) var producerStats: [ProducerStat] = []
    @Published private(set) var totalCueCount = 0
    @Published private(set) var tracksWithCues = 0
    @Published private(set) var isLoading = false
    @Published private(set) var libraryError: String?

    private var knownTracks: [String: Track] = [:]

    func load(isSignedOut: Bool) async {
        isLoading = true
        defer { isLoading = false }

        await MacAnalysisIndex.shared.refresh()
        await loadCues()
        if !isSignedOut, knownTracks.isEmpty {
            await loadTitles()
        }
        rebuild()
    }

    func rebuild() {
        let index = MacAnalysisIndex.shared
        let corrections = MacAnalysisCorrectionStore.shared

        var stats: [String: ProducerStat] = [:]
        var out: [TrackLine] = []
        var trackIds = Set(index.recordsByTrack.keys)
        trackIds.formUnion(corrections.corrections.keys)
        trackIds.formUnion(DownloadManager.shared.entries.keys)

        for trackId in trackIds {
            let records = index.records(for: trackId)
            for record in records {
                var stat = stats[record.engine.displayName] ?? ProducerStat(engine: record.engine)
                stat.rows += 1
                stat.bytes += record.byteSize
                if record.bpm != nil { stat.withBPM += 1 }
                if record.key != nil { stat.withKey += 1 }
                if record.genre != nil { stat.withGenre += 1 }
                stats[record.engine.displayName] = stat
            }
            out.append(
                TrackLine(
                    trackId: trackId,
                    track: knownTracks[trackId] ?? DownloadManager.shared.cachedTrack(forTrackId: trackId),
                    records: records,
                    result: index.result(forTrackId: trackId),
                    correction: corrections.correction(for: trackId),
                    cueCount: cueCountsByTrack[trackId] ?? 0,
                    workState: AutomaticAnalysisStatus.shared.state(for: trackId)
                )
            )
        }

        for (trackId, records) in index.recordsByTrack {
            _ = trackId
            for engine in Set(records.map(\.engine.displayName)) {
                stats[engine]?.tracks += 1
            }
        }

        producerStats = stats.values.sorted { $0.rows > $1.rows }
        lines = out.sorted { $0.analysedAt > $1.analysedAt }
    }

    private var cueCountsByTrack: [String: Int] = [:]

    private func loadCues() async {
        let records = await CueStore.shared.syncRecords(changedSince: 0, limit: 20_000)
        var counts: [String: Int] = [:]
        for record in records where !record.isDeleted {
            counts[record.trackId, default: 0] += 1
        }
        cueCountsByTrack = counts
        totalCueCount = counts.values.reduce(0, +)
        tracksWithCues = counts.count
    }

    private static let cacheDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private static let cacheDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(cacheDateFormatter)
        return decoder
    }()

    private func loadTitles() async {
        var map: [String: Track] = [:]
        for section in ["liked", "mine"] {
            let rows = await LibraryCache.shared.loadSection(section)
            for row in rows {
                guard let track = try? Self.cacheDecoder.decode(Track.self, from: row.payload) else { continue }
                map[track.id] = track
            }
        }
        do {
            let page = try await SoundCloudAPI.shared.getLikedTracks(limit: 200)
            for like in page.collection { map[like.item.id] = like.item }
            libraryError = nil
        } catch {
            if map.isEmpty {
                libraryError = "Couldn't load your liked tracks, so some rows show a track id instead of a title."
            }
        }
        knownTracks = map
    }

    func deleteCues(forTrackId trackId: String) async {
        await CueStore.shared.deleteAll(forTrack: trackId)
        await loadCues()
        rebuild()
    }
}

struct MacIntelligenceView: View {
    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    @ObservedObject private var model: MacIntelligenceModel
    @ObservedObject private var index = MacAnalysisIndex.shared
    @ObservedObject private var corrections = MacAnalysisCorrectionStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var workStatus = AutomaticAnalysisStatus.shared

    @State private var selection = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\MacIntelligenceModel.TrackLine.analysedAt, order: .reverse)]
    @State private var editingTrackId: String?
    @State private var isConfirmingWipe = false
    @State private var busyMessage: String?
    @State private var isShowingHonestyDetail = false
    @State private var isStorageExpanded = false
    @State private var isSourcesExpanded = false
    @State private var isTracksExpanded = false

    init(model: MacIntelligenceModel) {
        self.model = model
    }

    private var sortedLines: [MacIntelligenceModel.TrackLine] { model.lines.sorted(using: sortOrder) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SCContentStyle.mac.spaceBase) {
                overviewCard
                automaticAnalysisCard
                storageCard
                if !model.producerStats.isEmpty { coverageCard }
                tracksSection
            }
            .padding(.horizontal, 20)
            .padding(.top, SCContentStyle.mac.spaceBase)
            .padding(.bottom, SCContentStyle.mac.spaceSection)
        }
        .background(Color.black.opacity(0.001))
        .task { await model.load(isSignedOut: credentials.isSignedOut) }
        .onReceive(workStatus.$states) { _ in model.rebuild() }
        .sheet(item: Binding(get: { editingTrackId.map(IdentifiedString.init) }, set: { editingTrackId = $0?.value })) { wrapped in
            MacAnalysisCorrectionSheet(
                trackId: wrapped.value,
                title: model.lines.first { $0.trackId == wrapped.value }?.titleKey ?? wrapped.value,
                current: corrections.correction(for: wrapped.value)
            ) { updated in
                corrections.set(updated, for: wrapped.value)
                model.rebuild()
            }
        }
        .confirmationDialog(
            "Delete every analysis result?",
            isPresented: $isConfirmingWipe,
            titleVisibility: .visible
        ) {
            Button("Delete All Analysis", role: .destructive) {
                Task {
                    busyMessage = "Deleting…"
                    await index.forgetEverything()
                    model.rebuild()
                    busyMessage = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes every cached tempo, key, loudness, structure and genre result on this Mac. Your cue points and your own corrections are kept, nothing on your SoundCloud account is touched, and analysis re-runs the next time a track is played or analysed.")
        }
    }

    private var headerSubtitle: String {
        let tracks = index.analysedTrackCount
        let used = Self.byteFormatter.string(fromByteCount: index.usedBytes)
        return "\(tracks) track\(tracks == 1 ? "" : "s") analysed · \(used) used"
    }

    private var overviewCard: some View {
        GroupBox {
            HStack(spacing: 0) {
                intelligenceSummary(
                    title: "Analysed",
                    value: "\(index.analysedTrackCount)",
                    symbol: "waveform.badge.magnifyingglass"
                )
                Divider().frame(height: 42)
                intelligenceSummary(
                    title: "Results",
                    value: index.isTruncated ? "\(index.rowCount)+" : "\(index.rowCount)",
                    symbol: "chart.bar.doc.horizontal"
                )
                Divider().frame(height: 42)
                intelligenceSummary(
                    title: "Cue points",
                    value: "\(model.totalCueCount)",
                    symbol: "mappin.and.ellipse"
                )
                Divider().frame(height: 42)
                intelligenceSummary(
                    title: "Corrections",
                    value: "\(corrections.corrections.count)",
                    symbol: "slider.horizontal.3"
                )
            }
            .frame(maxWidth: .infinity)
        } label: {
            HStack(spacing: 6) {
                Label("Overview", systemImage: "waveform.path.ecg")
                Button {
                    isShowingHonestyDetail = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("How Music Intelligence estimates its results")
                .popover(isPresented: $isShowingHonestyDetail, arrowEdge: .bottom) {
                    Text(Self.honestyBody)
                        .font(.callout)
                        .frame(width: 360, alignment: .leading)
                        .padding(SCContentStyle.mac.spaceBase)
                }
            }
        }
    }

    private var automaticAnalysisCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: SCContentStyle.mac.spaceTight) {
                Toggle("Analyse tracks I like", isOn: automaticRuleBinding(\.likedTracks))
                Toggle("Analyse tracks in my playlists", isOn: automaticRuleBinding(\.yourPlaylists))
                Picker("This Mac", selection: settings.automaticAnalysisExecutionPolicyBinding) {
                    ForEach(AutomaticAnalysisExecutionPolicy.allCases) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                Text("The selection above syncs to your other devices. This Mac’s execution preference stays here. Analysis only uses audio that is already downloaded—no stream is requested.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack {
                    Text(headerSubtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(model.isLoading || index.isRefreshing ? "Refreshing…" : "Refresh Analysis Store", systemImage: "arrow.clockwise") {
                        Task { await model.load(isSignedOut: credentials.isSignedOut) }
                    }
                    .disabled(model.isLoading || index.isRefreshing)
                }
            }
            .padding(.top, SCContentStyle.mac.spaceHair)
        } label: {
            Label("Automatic Analysis", systemImage: "waveform.badge.magnifyingglass")
        }
    }

    private func automaticRuleBinding(_ keyPath: WritableKeyPath<AutomaticAnalysisRules, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings.automaticAnalysisPolicy[keyPath: keyPath] },
            set: { value in
                var rules = settings.automaticAnalysisPolicy
                rules[keyPath: keyPath] = value
                settings.setAutomaticAnalysisPolicy(rules)
            }
        )
    }

    private func intelligenceSummary(title: String, value: String, symbol: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
    }

    private static let honestyBody = """
    Tempo and key come either from Apple's on-device analysis (the strongest \
    reading this app can produce) or from a live FFT estimate taken during \
    playback, which is weaker. Genre isn't measured from audio at all. It's \
    matched from text, and on a real 321-track library about one track in \
    eight resolves to anything, at low confidence. Beat grids are spaced from \
    the tempo but aren't aligned to a real first beat, because nothing here \
    tracks downbeats yet. Every value below says which of those produced it. \
    A dimmed value is a guess, a full-strength one is a reading.
    """

    private var storageCard: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $isStorageExpanded) {
                VStack(alignment: .leading, spacing: SCContentStyle.mac.spaceBase) {
                    ProgressView(value: budgetFraction)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)

                    HStack {
                        Text("Storage limit")
                        Spacer()
                        Picker("Storage limit", selection: budgetBinding) {
                            ForEach(Self.budgetOptions, id: \.self) { bytes in
                                Text(Self.byteFormatter.string(fromByteCount: bytes)).tag(bytes)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 120)
                        .help("Least-recently-used results are discarded to stay inside this limit. Analysis is regenerated automatically when needed again.")
                    }

                    Divider()

                    HStack(spacing: SCContentStyle.mac.spaceBase) {
                        Button("Show in Finder", systemImage: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([AnalysisCache.defaultDirectory()])
                        }
                        Spacer(minLength: 8)
                        Button(busyMessage ?? "Delete Analysis…", systemImage: "trash", role: .destructive) {
                            isConfirmingWipe = true
                        }
                        .disabled(busyMessage != nil)
                    }

                    Text(Self.storageBody)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, SCContentStyle.mac.spaceTight)
            } label: {
                HStack {
                    Label("Storage", systemImage: "internaldrive")
                    Spacer(minLength: 8)
                    Text("\(Self.byteFormatter.string(fromByteCount: index.usedBytes)) of \(Self.byteFormatter.string(fromByteCount: index.maxBytes))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private static let storageBody = "This Mac is sandboxed, so the store lives inside the app's own container rather than in your visible Library folder. It's derived data, excluded from backup, and safe to delete. Everything here can be produced again from the audio."

    private var budgetFraction: Double {
        guard index.maxBytes > 0 else { return 0 }
        return min(1, Double(index.usedBytes) / Double(index.maxBytes))
    }

    private static let budgetOptions: [Int64] = [
        50_000_000, 100_000_000, 250_000_000, 500_000_000, 1_000_000_000, 2_000_000_000,
    ]

    private var budgetBinding: Binding<Int64> {
        Binding(
            get: {
                Self.budgetOptions.min { abs($0 - index.maxBytes) < abs($1 - index.maxBytes) }
                    ?? AnalysisCache.defaultMaxBytes
            },
            set: { newValue in Task { await index.setBudget(newValue) } }
        )
    }

    private var coverageCard: some View {
        GroupBox {
            DisclosureGroup(isExpanded: $isSourcesExpanded) {
                VStack(spacing: 0) {
                    ForEach(Array(model.producerStats.enumerated()), id: \.element.id) { pair in
                        let stat = pair.element
                        VStack(alignment: .leading, spacing: SCContentStyle.mac.spaceHair) {
                            HStack(spacing: 8) {
                                Image(systemName: stat.engine.symbolName)
                                    .foregroundStyle(stat.engine.tempoAndKeyAreMeasured ? Color.accentColor : Color.secondary)
                                    .frame(width: 18)
                                Text(stat.engine.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                Spacer(minLength: 8)
                                Text("\(stat.tracks) tracks · \(Self.byteFormatter.string(fromByteCount: Int64(stat.bytes)))")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Text(stat.engine.explanation)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Tempo \(stat.withBPM) · Key \(stat.withKey) · Genre \(stat.withGenre)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                        .padding(.vertical, SCContentStyle.mac.spaceSnug)

                        if pair.offset < model.producerStats.count - 1 { Divider() }
                    }
                }
                .padding(.top, SCContentStyle.mac.spaceTight)
            } label: {
                HStack {
                    Label("Analysis Sources", systemImage: "cpu")
                    Spacer(minLength: 8)
                    Text("\(model.producerStats.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    @ViewBuilder
    private var tracksSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { isTracksExpanded.toggle() }
                } label: {
                    HStack {
                        Image(systemName: isTracksExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .frame(width: 12)
                        Label("Analysed Tracks", systemImage: "music.note.list")
                        Spacer(minLength: 8)
                        Text("\(model.lines.count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isTracksExpanded {
                VStack(alignment: .leading, spacing: SCContentStyle.mac.spaceTight) {
                    if let libraryError = model.libraryError {
                        Text(libraryError)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if model.lines.isEmpty {
                        SCEmptyState(
                            icon: "waveform.badge.magnifyingglass",
                            title: "Nothing Analysed Yet",
                            message: "Tempo, key and structure are worked out on this Mac the first time a track is loaded onto a deck or played.",
                            actionTitle: "Open Library",
                            action: { MacRootSelection.shared.request(.library) },
                            style: .mac
                        )
                        .frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        tracksTable
                    }
                }
                .padding(.top, SCContentStyle.mac.spaceTight)
                }
            }
        }
    }

    @ViewBuilder
    private func analysisCell<Badge: View>(
        value: String?,
        state: AnalysisWorkState?,
        badge: Badge
    ) -> some View {
        if value == nil, let state {
            Text(state.label)
                .font(.caption)
                .foregroundStyle(state == .analysing ? Color.accentColor : Color.secondary)
                .lineLimit(1)
                .help(state.label)
        } else {
            badge
        }
    }

    private var tracksTable: some View {
        Table(sortedLines, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Track", sortUsing: KeyPathComparator(\.titleKey)) { line in
                VStack(alignment: .leading, spacing: 1) {
                    Text(line.track != nil ? line.titleKey : "Unknown Track")
                        .lineLimit(1)
                    if !line.artistKey.isEmpty {
                        Text(line.artistKey)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if line.track == nil {
                        Text(line.trackId)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .contextMenu { rowMenu(line) }
            }
            .width(min: 180, ideal: 280, max: .infinity)

            TableColumn("Tempo") { line in
                analysisCell(
                    value: line.result?.bpm.map { String(format: "%.0f", $0) },
                    state: line.workState,
                    badge: SCAnalysisBadge(
                        kind: .bpm,
                        value: line.result?.bpm.map { String(format: "%.0f", $0) },
                        provenance: line.result?.bpmProvenance ?? .unavailable,
                        style: .mac
                    )
                )
            }
            .width(min: 56, ideal: 72, max: 96)

            TableColumn("Key") { line in
                analysisCell(
                    value: line.result?.key?.label,
                    state: line.workState,
                    badge: SCAnalysisBadge(
                        kind: .key,
                        value: line.result?.key?.label,
                        provenance: line.result?.keyProvenance ?? .unavailable,
                        style: .mac
                    )
                )
            }
            .width(min: 52, ideal: 68, max: 90)

            TableColumn("Genre") { line in
                analysisCell(
                    value: line.result?.genre,
                    state: line.workState,
                    badge: SCAnalysisBadge(
                        kind: .genre,
                        value: line.result?.genre,
                        provenance: line.result?.genreProvenance ?? .unavailable,
                        style: .mac
                    )
                )
            }
            .width(min: 100, ideal: 150, max: 220)

            TableColumn("") { line in
                if line.result?.isEmpty != false {
                    Button("Analyse Now") { DownloadManager.shared.forceAnalyseNow(trackId: line.trackId) }
                        .controlSize(.small)
                }
            }
            .width(min: 86, ideal: 94, max: 110)

            TableColumn("Sources") { line in
                HStack(spacing: SCContentStyle.mac.spaceHair) {
                    ForEach(Array(Set(line.records.map(\.engine.displayName))).sorted(), id: \.self) { name in
                        if let engine = line.records.first(where: { $0.engine.displayName == name })?.engine {
                            Image(systemName: engine.symbolName)
                                .foregroundStyle(engine.tempoAndKeyAreMeasured ? Color.accentColor : Color.secondary)
                                .help(engine.explanation)
                        }
                    }
                }
            }
            .width(min: 50, ideal: 70, max: 110)

            TableColumn("Cues") { line in
                Text(line.cueCount == 0 ? "—" : "\(line.cueCount)")
                    .foregroundStyle(line.cueCount == 0 ? .tertiary : .primary)
                    .monospacedDigit()
            }
            .width(min: 36, ideal: 46, max: 60)

            TableColumn("Size") { line in
                Text(Self.byteFormatter.string(fromByteCount: Int64(line.bytes)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 56, ideal: 70, max: 90)

            TableColumn("Analysed", sortUsing: KeyPathComparator(\.analysedAt)) { line in
                if line.analysedAt == .distantPast {
                    Text("—").foregroundStyle(.tertiary)
                } else {
                    Text(line.analysedAt, style: .date)
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 84, ideal: 96, max: 130)
        }
        .frame(height: 340)
    }

    @ViewBuilder
    private func rowMenu(_ line: MacIntelligenceModel.TrackLine) -> some View {
        Button("Correct Tempo, Key or Genre…") { editingTrackId = line.trackId }

        if let track = line.track {
            Button("Analyse Again") {
                Task {
                    busyMessage = "Analysing…"
                    await MacAnalysisRunner.analyse(track, force: true)
                    model.rebuild()
                    busyMessage = nil
                }
            }
        }

        Divider()

        Button("Forget Analysis for This Track", role: .destructive) {
            Task {
                await MacAnalysisIndex.shared.forgetAnalysis(forTrackId: line.trackId)
                model.rebuild()
            }
        }
        if line.cueCount > 0 {
            Button("Delete \(line.cueCount) Cue Point\(line.cueCount == 1 ? "" : "s")", role: .destructive) {
                Task { await model.deleteCues(forTrackId: line.trackId) }
            }
        }
        if line.isCorrected {
            Button("Remove My Correction", role: .destructive) {
                MacAnalysisCorrectionStore.shared.set(nil, for: line.trackId)
                model.rebuild()
            }
        }
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}

struct IdentifiedString: Identifiable {
    let value: String
    var id: String { value }
    init(_ value: String) { self.value = value }
}

struct MacAnalysisCorrectionSheet: View {
    let trackId: String
    let title: String
    let current: MacAnalysisCorrection?
    let onSave: (MacAnalysisCorrection?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var bpmText = ""
    @State private var keyText = ""
    @State private var genreText = ""

    private var keyIsValid: Bool {
        let trimmed = keyText.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || CamelotKey.parse(trimmed) != nil
    }

    private var bpmIsValid: Bool {
        let trimmed = bpmText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return true }
        guard let value = Double(trimmed) else { return false }
        return value > 20 && value < 300
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SCContentStyle.mac.spaceBase) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Correct Analysis").font(.headline)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Form {
                TextField("Tempo (BPM)", text: $bpmText, prompt: Text("Leave empty to keep the analysed value"))
                    .foregroundStyle(bpmIsValid ? Color.primary : Color.red)
                TextField("Key (Camelot, e.g. 8A)", text: $keyText, prompt: Text("Leave empty to keep the analysed value"))
                    .foregroundStyle(keyIsValid ? Color.primary : Color.red)
                TextField("Genre", text: $genreText, prompt: Text("Leave empty to keep the analysed value"))
            }
            .formStyle(.grouped)

            Text("Corrections are yours, not analysis output. They survive clearing the analysis cache and the storage limit evicting old results, and they override every analyser for this track.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if current?.isEmpty == false {
                    Button("Remove Correction", role: .destructive) {
                        onSave(nil)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(
                        MacAnalysisCorrection(
                            bpm: Double(bpmText.trimmingCharacters(in: .whitespaces)),
                            keyLabel: keyText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : keyText.trimmingCharacters(in: .whitespaces).uppercased(),
                            genre: genreText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : genreText.trimmingCharacters(in: .whitespaces)
                        )
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!bpmIsValid || !keyIsValid)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            bpmText = current?.bpm.map { String(format: "%.0f", $0) } ?? ""
            keyText = current?.keyLabel ?? ""
            genreText = current?.genre ?? ""
        }
    }
}

private struct MacInsetCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background(
            RoundedRectangle(cornerRadius: SCContentStyle.mac.cornerCard, style: .continuous)
                .fill(.quaternary.opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SCContentStyle.mac.cornerCard, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        )
    }
}

private struct MacInsetRow<Trailing: View>: View {
    let title: String
    var isLast: Bool
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                Spacer(minLength: 12)
                trailing()
            }
            .padding(.horizontal, SCContentStyle.mac.spaceBase)
            .padding(.vertical, SCContentStyle.mac.spaceSnug)

            if !isLast {
                Divider().padding(.leading, SCContentStyle.mac.spaceBase)
            }
        }
    }
}

private struct MacInsetActionRow: View {
    let title: String
    var role: ButtonRole?
    var isLast: Bool
    let action: () -> Void

    init(title: String, role: ButtonRole? = nil, isLast: Bool, action: @escaping () -> Void) {
        self.title = title
        self.role = role
        self.isLast = isLast
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(role: role, action: action) {
                HStack {
                    Text(title)
                        .foregroundStyle(role == .destructive ? Color.red : Color.accentColor)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, SCContentStyle.mac.spaceBase)
                .padding(.vertical, SCContentStyle.mac.spaceSnug)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isLast {
                Divider().padding(.leading, SCContentStyle.mac.spaceBase)
            }
        }
    }

    func rowDisabled(_ condition: Bool) -> some View {
        self.opacity(condition ? 0.5 : 1).allowsHitTesting(!condition)
    }
}
