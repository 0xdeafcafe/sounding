import SwiftUI
import WebKit

@MainActor
enum MacSoundCloudWebsiteData {
    static func clear() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        // WebKit data is sandboxed to Sounding, and SoundCloud may authenticate
        // through related hosts whose display name does not contain its brand.
        // A full local logout should therefore clear the app's whole web jar.
        await store.removeData(ofTypes: types, for: records)
        if let cachedPersistentStore {
            let soundCloudRecords = await cachedPersistentStore.dataRecords(ofTypes: types)
            await cachedPersistentStore.removeData(ofTypes: types, for: soundCloudRecords)
        }
        cachedPersistentStore = nil
        try? await WKWebsiteDataStore.remove(forIdentifier: persistentStoreIdentifier)
    }

    private static let persistentStoreIdentifierKey = "red.forbes.sounding.mac.soundcloudWebStoreID"

    private static var persistentStoreIdentifier: UUID {
        let defaults = UserDefaults.sounding
        if let raw = defaults.string(forKey: persistentStoreIdentifierKey), let id = UUID(uuidString: raw) {
            return id
        }
        let id = UUID()
        defaults.set(id.uuidString, forKey: persistentStoreIdentifierKey)
        return id
    }

    private static var cachedPersistentStore: WKWebsiteDataStore?

    static var persistentStore: WKWebsiteDataStore {
        if let cachedPersistentStore { return cachedPersistentStore }
        let store = WKWebsiteDataStore(forIdentifier: persistentStoreIdentifier)
        cachedPersistentStore = store
        return store
    }

    static func retainSoundCloudCookies(from source: WKHTTPCookieStore) async {
        let target = persistentStore.httpCookieStore
        for cookie in await target.allCookies()
        where SilentWebReauthorizationPolicy.isSoundCloudCookieDomain(cookie.domain) {
            await target.deleteCookie(cookie)
        }
        for cookie in await source.allCookies()
        where SilentWebReauthorizationPolicy.isSoundCloudCookieDomain(cookie.domain) {
            await target.setCookie(cookie)
        }
    }
}

struct MacSettingsAccountTab: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    @EnvironmentObject private var companionClient: CompanionClient
    @ObservedObject private var sync = MacSyncCoordinator.shared
    @ObservedObject private var settingsStore = SettingsStore.shared
    @ObservedObject private var subscription = SubscriptionService.shared
    @ObservedObject private var downloads = DownloadManager.shared

    @State private var isSyncing = false
    @State private var isCheckingPlan = false
    @State private var isShowingWebSignIn = false
    @State private var isReauthentication = false
    @State private var isConfirmingForget = MacAccountDebug.opensSignOut == "here"
    @State private var isConfirmingSignOutEverywhere = MacAccountDebug.opensSignOut == "everywhere"
    @State private var isForgetting = false
    @State private var validationFailed = false

    var body: some View {
        Form {
            if credentials.isSignedOut {
                onboardingSection
            } else if credentials.isSessionRejected {
                recoverySection
            } else if credentials.hasConfirmedAccount {
                identitySection
                planSection
                soundCloudManagementSection
            } else {
                validationSection
            }
            syncSection
            if !credentials.isSignedOut {
                forgetSection
            }
        }
        .formStyle(.grouped)
        .defaultScrollAnchor(.top, for: .alignment)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            credentials.refreshFromStore()
            Task {
                await credentials.revalidate()
                if credentials.hasConfirmedAccount { await subscription.verifyNow() }
            }
        }
        .sheet(isPresented: $isShowingWebSignIn) {
            MacSoundCloudSignInView(peerName: nil, forHandoff: false, isReauthentication: isReauthentication) {
                isShowingWebSignIn = false
            }
        }
        .confirmationDialog(
            "Log out and forget this Mac?",
            isPresented: $isConfirmingForget,
            titleVisibility: .visible
        ) {
            Button("Log Out and Forget This Mac", role: .destructive) {
                forgetThisMac()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(forgetMessage)
        }
        .confirmationDialog(
            "Sign Out of All Devices?",
            isPresented: $isConfirmingSignOutEverywhere,
            titleVisibility: .visible
        ) {
            Button("Sign Out of All Devices", role: .destructive) {
                signOutEverywhere()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(AccountSignOut.everywhereMessage(client: companionClient))
        }
    }

    private var forgetMessage: String {
        let base = "Your sign-in, queue, history and downloads are removed from this Mac, and linked Apple TVs forget it."
        guard let staying = AccountSignOut.stayingSignedInMessage(client: companionClient) else { return base }
        return "\(base) \(staying)"
    }

    private var identitySection: some View {
        Section {
            HStack(spacing: SCContentStyle.mac.spaceBase) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    Text(identityTitle)
                        .font(.headline)
                    Text(identitySubtitle)
                        .foregroundStyle(MacSecondaryStyle())
                }
            }
        }
    }

    private var planSection: some View {
        Section {
            LabeledContent("Plan") {
                Text(subscription.tier.displayName).foregroundStyle(MacSecondaryStyle())
            }
            LabeledContent("Verification") {
                Text(planVerification).foregroundStyle(planVerificationColor)
            }
            if let deletionDate = downloads.scheduledDeletionDate {
                LabeledContent("Go+ Downloads Removed") {
                    Text(deletionDate, format: .dateTime.day().month().year())
                        .foregroundStyle(.orange)
                }
            }
            MacWebLinkRow("Manage Subscription", destination: SoundCloudAccountPages.subscriptions)
            Button(isCheckingPlan ? "Checking Plan…" : "Check Plan Now") {
                guard !isCheckingPlan else { return }
                isCheckingPlan = true
                Task {
                    await subscription.verifyNow()
                    isCheckingPlan = false
                }
            }
            .disabled(isCheckingPlan)
        } header: {
            Text("SoundCloud Plan")
        } footer: {
            if let planFooter {
                Text(planFooter)
            }
        }
    }

    private var planFooter: String? {
        let description = subscription.statusDescription
        return description == "SoundCloud \(subscription.tier.displayName)." ? nil : description
    }

    private var soundCloudManagementSection: some View {
        Section("SoundCloud Account") {
            MacWebLinkRow("Security and Sign-In", destination: SoundCloudAccountPages.account)
            MacWebLinkRow("Notifications", destination: SoundCloudAccountPages.notifications)
            MacWebLinkRow("Privacy", destination: SoundCloudAccountPages.privacy)
            MacWebLinkRow("Communications", destination: SoundCloudAccountPages.communications)
            MacWebLinkRow("Analytics", destination: SoundCloudAccountPages.analytics)
            MacWebLinkRow("Advertising", destination: SoundCloudAccountPages.advertising)
        }
    }

    private var planVerification: String {
        switch subscription.verification {
        case .verified: return "Verified"
        case .unverifiable: return "Unavailable"
        case .verifiedNotSubscribed: return "Not subscribed"
        }
    }

    private var planVerificationColor: Color {
        switch subscription.verification {
        case .verified: return .green
        case .unverifiable: return .secondary
        case .verifiedNotSubscribed: return .red
        }
    }

    private var onboardingSection: some View {
        Section {
            Text("Sign in to SoundCloud to see your likes, playlists and following.")
            Button("Sign In…") {
                isReauthentication = false
                isShowingWebSignIn = true
            }
        }
    }

    private var recoverySection: some View {
        Section {
            Label(
                credentials.sessionRecoveryTitle ?? "SoundCloud Sign-In Unavailable",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
            Text(credentials.sessionRecoveryMessage ?? "Reconnect SoundCloud to continue.")
                .foregroundStyle(MacSecondaryStyle())
            Button(credentials.sessionRecoveryActionTitle ?? "Reconnect") {
                if credentials.canRetrySession {
                    Task { await credentials.revalidate() }
                } else {
                    isReauthentication = true
                    isShowingWebSignIn = true
                }
            }
        }
    }

    private var validationSection: some View {
        Section {
            if validationFailed || credentials.canRetrySession {
                LabeledContent("SoundCloud") {
                    Button("Check Again") { runValidation() }
                }
            } else {
                HStack(spacing: SCContentStyle.mac.spaceTight) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking SoundCloud sign-in…")
                    Spacer(minLength: 0)
                }
                .task { await validate() }
            }
        }
    }

    private func runValidation() {
        validationFailed = false
        Task { await validate() }
    }

    private func validate() async {
        await credentials.revalidate()
        if !credentials.hasConfirmedAccount { validationFailed = true }
    }

    private var identityTitle: String {
        if credentials.isSignedOut { return "Please Sign In" }
        if credentials.isSessionRejected { return credentials.sessionRecoveryTitle ?? "Reconnect SoundCloud" }
        return credentials.currentUser?.username ?? "SoundCloud"
    }

    private var identitySubtitle: String {
        if credentials.isSignedOut {
            return "Guest mode · sign in to access account content."
        }
        if credentials.isSessionRejected {
            return "Reconnect SoundCloud to restore account content."
        }
        guard let user = credentials.currentUser else {
            return "Signed in, loading profile…"
        }
        var parts = ["\(user.followersCount) \(user.followersCount == 1 ? "follower" : "followers")"]
        if user.trackCount > 0 {
            parts.append("\(user.trackCount) \(user.trackCount == 1 ? "track" : "tracks")")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var avatar: some View {
        let size: CGFloat = 44
        Group {
            if !credentials.needsSignIn, let url = credentials.currentUser?.avatarURL {
                SCArtworkResolver(url: url, variant: .thumbnail) { image in
                    if let image {
                        image.resizable().scaledToFill()
                    } else {
                        Circle().fill(.quaternary)
                    }
                }
                .frame(width: size, height: size)
                .clipShape(Circle())
            } else {
                Circle()
                    .fill(.quaternary)
                    .frame(width: size, height: size)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(MacSecondaryStyle())
                    )
            }
        }
        .accessibilityHidden(true)
    }

    private var syncSection: some View {
        Section {
            Toggle("Sync Settings with iCloud", isOn: settingsStore.syncSettingsWithICloudBinding)
            LabeledContent("Last Sync") {
                if let lastRunAt = sync.lastSuccessfulRunAt {
                    Text(lastRunAt, style: .relative).foregroundStyle(MacSecondaryStyle())
                } else {
                    Text("Not yet").foregroundStyle(MacSecondaryStyle())
                }
            }
            if let failureMessage = sync.failureMessage {
                Label(failureMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Button(isSyncing ? "Syncing…" : "Sync Now") {
                runSyncNow()
            }
            .disabled(isSyncing)
        } header: {
            Text("iCloud")
        } footer: {
            Text("Settings follow your Apple ID to your other devices. Recent searches and other SoundCloud account settings are cleared from this device when you sign out of SoundCloud.")
        }
    }

    private func runSyncNow() {
        guard !isSyncing else { return }
        isSyncing = true
        Task {
            await sync.runOnce()
            credentials.refreshFromStore()
            isSyncing = false
        }
    }

    private var forgetSection: some View {
        Section {
            Button(isForgetting ? "Forgetting This Mac…" : "Log Out and Forget This Mac…", role: .destructive) {
                isConfirmingForget = true
            }
            .disabled(isForgetting)
            Button("Sign Out of All Devices…", role: .destructive) {
                isConfirmingSignOutEverywhere = true
            }
            .disabled(isForgetting)
        }
    }

    private func forgetThisMac() {
        guard !isForgetting else { return }
        isForgetting = true
        Task {
            // Clear live state first so playback and peer connections cannot
            // rewrite account-owned state while credential deletion runs.
            PlayerService.shared.purgeLocalPlaybackState()
            let shared = await AccountSignOut.tokenIsShared(client: companionClient)
            companionClient.forgetAllLinks()
            CompanionRegistry.shared.forgetAll()
            await credentials.signOutThisDevice(tokenIsShared: shared)
            isForgetting = false
        }
    }

    private func signOutEverywhere() {
        guard !isForgetting else { return }
        isForgetting = true
        Task {
            await AccountSignOut.signOutEverywhere(client: companionClient, credentials: credentials)
            isForgetting = false
        }
    }
}

struct MacWebLinkRow: View {
    let title: LocalizedStringKey
    let destination: URL

    init(_ title: LocalizedStringKey, destination: URL) {
        self.title = title
        self.destination = destination
    }

    var body: some View {
        Link(destination: destination) {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(MacSecondaryStyle())
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

enum MacAccountDebug {
    static var opensSignOut: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["SOUNDING_TV_OPEN_SIGN_OUT"]
        #else
        nil
        #endif
    }
}

struct MacSoundCloudSignInView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var companionClient: CompanionClient
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var startView: SoundCloudWebSignInPage = .signIn
    let peerName: String?
    let forHandoff: Bool
    var isReauthentication = false
    let onComplete: () -> Void

    private var title: String {
        if forHandoff { return "Sign in for \(peerName ?? "device")" }
        return isReauthentication ? "Reauthenticate with SoundCloud" : "Sign in to SoundCloud"
    }

    private var subtitle: String {
        forHandoff
            ? "This SoundCloud authentication will be sent to your \(peerName ?? "device") and used only there."
            : "The page below is provided by SoundCloud."
    }

    var body: some View {
        NavigationStack {
            ZStack {
                MacSoundCloudOAuthWebView(
                    isLoading: $isLoading,
                    usesIsolatedDataStore: true,
                    retainsWebSession: !forHandoff,
                    startView: startView
                ) { session in
                    if forHandoff {
                        companionClient.sendAuthHandoffSession(session)
                        onComplete()
                    } else {
                        isLoading = true
                        Task {
                            DeviceSessionStore.save(session)
                            SoundCloudCredentialSource.shared.didCompleteSignIn()
                            let health = await SoundCloudCredentialSource.shared.revalidate()
                            isLoading = false
                            guard health == .healthy else {
                                if case .waiting = SoundCloudAPI.shared.trafficSafetyState() {
                                    onComplete()
                                    return
                                }
                                errorMessage = health.needsSignIn
                                    ? "SoundCloud rejected the resulting authentication. Please sign in again."
                                    : "The account could not be verified. Check your connection and try again."
                                return
                            }
                            onComplete()
                        }
                    }
                } onError: { message in
                    errorMessage = message
                }

                if isLoading {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.background)
                }

                if let errorMessage {
                    ContentUnavailableView {
                        Label("Sign-In Couldn’t Finish", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Close") { dismiss() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.regularMaterial)
                }
            }
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    MacGlassTabs(
                        "Account flow",
                        selection: $startView,
                        options: Array(SoundCloudWebSignInPage.allCases),
                        compact: true,
                        title: \.label
                    )
                    .controlSize(.small)
                }
            }
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 600, idealHeight: 720)
    }
}

private struct MacSoundCloudOAuthWebView: NSViewRepresentable {
    @Binding var isLoading: Bool
    let usesIsolatedDataStore: Bool
    let retainsWebSession: Bool
    let startView: SoundCloudWebSignInPage
    let onSession: (StoredSession) -> Void
    let onError: (String) -> Void
    @Environment(\.openURL) private var openURL

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self, signIn: SoundCloudWebSignIn(usesIsolatedStore: usesIsolatedDataStore))
    }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.parent = self
        context.coordinator.bind()
        context.coordinator.load(startView)
        return context.coordinator.signIn.webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.load(startView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.signIn.teardown()
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: MacSoundCloudOAuthWebView
        let signIn: SoundCloudWebSignIn
        private var loadedPage: SoundCloudWebSignInPage?

        init(parent: MacSoundCloudOAuthWebView, signIn: SoundCloudWebSignIn) {
            self.parent = parent
            self.signIn = signIn
        }

        func load(_ page: SoundCloudWebSignInPage) {
            guard loadedPage != page else { return }
            loadedPage = page
            #if DEBUG
            if ProcessInfo.processInfo.environment["SOUNDING_TV_MAC_SIGNIN_STUB"] == "1" {
                DispatchQueue.main.async { self.parent.isLoading = false }
                return
            }
            #endif
            DispatchQueue.main.async { self.parent.isLoading = true }
            signIn.load(page)
        }

        func bind() {
            signIn.onFormReady = { [weak self] in self?.parent.isLoading = false }
            signIn.onLoadFailed = { [weak self] in
                self?.parent.isLoading = false
                self?.parent.onError("SoundCloud’s sign-in page didn’t load. Check your connection and try again.")
            }
            signIn.onOpenExternally = { [weak self] url in self?.parent.openURL(url) }
            signIn.onCapture = { [weak self] capture in
                guard let self else { return }
                let session = capture.session
                guard self.parent.retainsWebSession else {
                    self.signIn.removeIsolatedStore()
                    self.parent.onSession(session)
                    return
                }
                Task { @MainActor in
                    await MacSoundCloudWebsiteData.retainSoundCloudCookies(from: self.signIn.cookieStore)
                    self.signIn.removeIsolatedStore()
                    self.parent.onSession(session)
                }
            }
        }
    }
}

struct MacSettingsAudioTab: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var player = PlayerService.shared

    var body: some View {
        Form {
            Section {
                Picker("Streaming Quality", selection: store.streamingQualityCeilingBinding) {
                    ForEach(QualityCeiling.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
            } header: {
                Text("Quality")
            } footer: {
                Text(QualitySizeEstimator.summaryLine() + ".")
            }

            DJMixerCurvesSection()
            DJHeadphoneSettingsSection()
            if AIAudioSettings.isSupported {
                MacAIAnalysisSettingsSection()
            }

            Section {
                Picker("Treat Tracks as Sets at", selection: store.setMinimumDurationSecondsBinding) {
                    ForEach(GeneratedLibraryCollections.setDurationPresets, id: \.self) { duration in
                        Text(GeneratedLibraryCollections.durationLabel(duration)).tag(duration)
                    }
                }
                LibrarySyncStatusRow()
            } header: {
                Text("Library")
            }

            Section {
                Toggle("Share Sounding Links", isOn: store.shareSoundingLinksBinding)
            } header: {
                Text("Sharing")
            } footer: {
                Text("Friends without Sounding get the SoundCloud link.")
            }

            Section {
                Toggle("Lyrics from LRCLIB", isOn: store.lyricsEnabledBinding)
            } header: {
                Text("Lyrics")
            } footer: {
                Text("Sends the track's title, artist and length to lrclib.net to find lyrics.")
            }

            Section {
                syncToggle("Streaming quality", SettingKeys.StreamingQualityCeiling.self)
                syncToggle("Download quality", SettingKeys.DownloadQualityCeiling.self)
                syncToggle("Auto Mix", SettingKeys.DJAutoMixEnabled.self)
                syncToggle("Personality", SettingKeys.DJDefaultProfileId.self)
                syncToggle("Transition length", SettingKeys.DJTransitionLengthSeconds.self)
                syncToggle("Energy", SettingKeys.DJEnergyLevel.self)
                syncToggle("Set length", SettingKeys.SetMinimumDurationSeconds.self)
                syncToggle("Collection policies", SettingKeys.CollectionPolicies.self)
            } header: {
                Text("Sync Across Devices")
            } footer: {
                Text("Turn a setting off to keep this Mac’s value to itself.")
            }

            Section("Audio Output") {
                LabeledContent("Device", value: PlatformAudioSession.outputName ?? "None")
                LabeledContent("Connection", value: PlatformAudioSession.outputKind.displayName)
                LabeledContent("Channels", value: "\(PlatformAudioSession.maximumOutputChannels)")
                LabeledContent(
                    "Separate Cue Output",
                    value: PlatformAudioSession.supportsSeparateCueBus ? "Available" : "Needs 4+ outputs"
                )
            }
        }
        .formStyle(.grouped)
    }

    private func syncToggle<K: SettingDefinition>(_ title: String, _ key: K.Type) -> some View {
        Toggle(title, isOn: Binding(
            get: { store.effectiveScope(key).syncsWithICloud },
            set: { store.setForceDeviceLocal(key, !$0) }
        ))
    }
}

struct MacSettingsDownloadsTab: View {
    @ObservedObject private var downloads = DownloadManager.shared

    @StateObject private var cache = CacheUsageModel()
    @State private var showingRedownloadConfirmation = false
    @State private var showingRemoveAllConfirmation = false

    var body: some View {
        NavigationStack {
            form
                .navigationDestination(for: DownloadsSettingsRoute.self) { route in
                    switch route {
                    case .downloadedMusic:
                        DownloadedMusicView()
                            .formStyle(.grouped)
                    }
                }
        }
    }

    private var form: some View {
        let redownload = downloads.redownloadEstimate()
        return Form {
            Section {
                Gauge(value: Double(downloads.storageUsed), in: 0...Double(max(DownloadsFormat.deviceCapacityBytes, 1))) {
                    Text("\(DownloadsFormat.bytes(downloads.storageUsed)) used by downloads")
                }
                NavigationLink(value: DownloadsSettingsRoute.downloadedMusic) {
                    LabeledContent("Downloaded Music", value: downloads.downloadedSummary)
                }
            } header: {
                Text("Storage")
            } footer: {
                if let deletionDate = downloads.scheduledDeletionDate {
                    Text("Go+ downloads are removed on \(deletionDate.formatted(date: .abbreviated, time: .omitted)) unless your subscription is renewed.")
                }
            }

            Section {
                Toggle("Optimise Storage", isOn: Binding(
                    get: { downloads.optimiseStorage },
                    set: { downloads.setOptimiseStorage($0) }
                ))
                Picker("Minimum Storage", selection: Binding(
                    get: { downloads.optimiseStorageMinimumBytes },
                    set: { downloads.setOptimiseStorageMinimumBytes($0) }
                )) {
                    ForEach(OptimiseStoragePolicy.minimumChoices, id: \.self) { bytes in
                        Text(DownloadsFormat.minimumStorage(bytes)).tag(bytes)
                    }
                }
                .disabled(!downloads.optimiseStorage)
            } footer: {
                Text("When storage is low, downloads you haven't played recently are removed.")
            }

            Section {
                Picker("Download Quality", selection: Binding(
                    get: { downloads.quality },
                    set: { downloads.setQuality($0) }
                )) {
                    ForEach(QualityCeiling.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                if redownload.trackCount > 0 {
                    Button("Re-download at New Quality (≈ \(redownload.sizeLabel))…") {
                        showingRedownloadConfirmation = true
                    }
                }
            } footer: {
                Text("Applies to new downloads.")
            }

            SoundingDataSettingsSection()

            Section {
                LabeledContent("Artwork", value: cache.usage.map { DownloadsFormat.bytes($0.artworkBytes) } ?? "–")
                Button("Clear Artwork") { cache.clearArtwork() }
                    .disabled(cache.isClearing || (cache.usage?.artworkBytes ?? 0) == 0)
            }

            Section {
                LabeledContent("Cache", value: cache.usage.map { DownloadsFormat.bytes($0.totalBytes) } ?? "–")
                Button("Clear Cache") { cache.clearCaches() }
                    .disabled(cache.isClearing || (cache.usage?.totalBytes ?? 0) == 0)
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
        .task { await cache.refresh() }
        .confirmationDialog("Re-download at New Quality", isPresented: $showingRedownloadConfirmation) {
            Button("Re-download \(DownloadsFormat.trackCount(redownload.trackCount))") {
                downloads.redownloadAtCurrentQuality(confirmed: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("About \(redownload.sizeLabel) will download again at \(downloads.quality.displayName) quality.")
        }
        .confirmationDialog("Remove All Downloads", isPresented: $showingRemoveAllConfirmation) {
            Button("Remove All Downloads", role: .destructive) { downloads.removeAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every download is deleted from this Mac.")
        }
    }
}

private enum DownloadsSettingsRoute: Hashable {
    case downloadedMusic
}

struct MacSettingsAnalysisTab: View {
    @ObservedObject private var store = SettingsStore.shared
    @AppStorage(GeneratedInsightsService.visibilityKey, store: .sounding) private var showsGeneratedInsights = true
    @State private var storageUsedBytes: Int64?
    @State private var showingClearConfirmation = false

    var body: some View {
        Form {
            Section {
                Toggle("Analyse Music on This Device", isOn: store.analyseMusicOnDeviceBinding)
            } footer: {
                Text("Finds tempo, key and genre for music you play or download.")
            }

            AnalysisLibraryStatusSection()

            if GeneratedInsightsService.shared.isAvailable {
                Section {
                    Toggle("Generated Tags and Summaries", isOn: $showsGeneratedInsights)
                } footer: {
                    Text("Mood tags and summaries are generated on this \(DeviceClass.current.displayName). Nothing leaves it.")
                }
            }

            Section {
                LabeledContent("Storage Used", value: storageUsedText)
                Button("Clear Analysis Data…", role: .destructive) { showingClearConfirmation = true }
                    .disabled(storageUsedBytes == 0)
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
        .confirmationDialog("Clear Analysis Data", isPresented: $showingClearConfirmation) {
            Button("Clear Analysis Data", role: .destructive) {
                Task {
                    await AutomaticAnalysisScheduler.shared.clearAnalysisData()
                    await MacAnalysisIndex.shared.refresh()
                    await refresh()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Tempo, key and genre results on this Mac are removed. Your corrections are kept.")
        }
    }

    private var storageUsedText: String {
        guard let storageUsedBytes else { return "–" }
        return ByteCountFormatter.string(fromByteCount: storageUsedBytes, countStyle: .file)
    }

    private func refresh() async {
        storageUsedBytes = await AnalysisDataUsage.storageUsedBytes()
    }
}

struct MacSettingsAdvancedTab: View {
    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    @ObservedObject private var sync = MacSyncCoordinator.shared
    @ObservedObject private var activityPoller = SoundCloudActivityPoller.shared
    @ObservedObject private var gateway = SoundCloudGateway.shared
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var player = PlayerService.shared
    @State private var showingReset = false
    @State private var showingNetworkActivity = false

    var body: some View {
        Form {
            Section("About") {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                #if SOUNDING_PERSONAL
                    .personalUnlockTrigger()
                #endif
                LabeledContent("Build", value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                MacWebLinkRow("Source Code", destination: URL(string: "https://github.com/0xdeafcafe/sounding-tv")!)
            }
            Section("Account") {
                LabeledContent("SoundCloud") {
                    if credentials.isSessionRejected {
                        Text("Reconnect SoundCloud to restore account access").foregroundStyle(.orange)
                    } else if credentials.isSignedOut {
                        Text("Please Sign In").foregroundStyle(MacSecondaryStyle())
                    } else if let user = credentials.currentUser {
                        Text(user.username)
                    } else if gateway.trafficSafety != .ready || credentials.canRetrySession {
                        Text("Unavailable").foregroundStyle(MacSecondaryStyle())
                    } else {
                        Text("Loading profile…").foregroundStyle(MacSecondaryStyle())
                    }
                }
            }
            Section("Audio Output") {
                LabeledContent("Device", value: PlatformAudioSession.outputName ?? "None")
                LabeledContent("Connection", value: PlatformAudioSession.outputKind.displayName)
                LabeledContent("Channels", value: "\(PlatformAudioSession.maximumOutputChannels)")
                LabeledContent("Separate Cue Output") {
                    Text(PlatformAudioSession.supportsSeparateCueBus ? "Available" : "Needs 4+ outputs")
                        .foregroundStyle(PlatformAudioSession.supportsSeparateCueBus ? .primary : .secondary)
                }
            }
            Section("iCloud Sync") {
                LabeledContent(
                    "iCloud",
                    value: CloudSyncEngineController.containerIdentifierIsEntitled(CloudSyncContainer.identifier)
                        ? "Available"
                        : "Unavailable"
                )
                LabeledContent("Last Attempt") {
                    if let date = sync.lastAttemptAt { Text(date, style: .relative) }
                    else { Text("Not yet").foregroundStyle(MacSecondaryStyle()) }
                }
                LabeledContent("Last Sync") {
                    if let date = sync.lastSuccessfulRunAt { Text(date, style: .relative) }
                    else { Text("Not yet").foregroundStyle(MacSecondaryStyle()) }
                }
                if let failure = sync.failureMessage {
                    Text(failure).font(.footnote).foregroundStyle(.orange)
                }
                Button("Sync Now") { Task { await sync.runOnce() } }
            }
            Section("SoundCloud Activity") {
                LabeledContent("Unread", value: "\(activityPoller.unreadCount)")
                LabeledContent("Last Checked") {
                    if let date = activityPoller.lastSuccessfulPoll { Text(date, style: .relative) }
                    else { Text("Not yet").foregroundStyle(MacSecondaryStyle()) }
                }
                LabeledContent("Notifications") {
                    if let date = activityPoller.circuitOpenUntil, date > Date() {
                        Text("Paused until \(date.formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(.orange)
                    } else {
                        Text("On")
                    }
                }
            }
            Section("Diagnostics") {
                LabeledContent("Playback stalls", value: "\(player.observedStalls)")
                if NetworkActivityLog.isVisible {
                    Button("Network Activity…") { showingNetworkActivity = true }
                }
            }
            Section {
                Button("Reset All Settings…", role: .destructive) { showingReset = true }
            } footer: {
                Text("Your library and downloads aren’t affected.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset All Settings", isPresented: $showingReset) {
            Button("Reset All Settings", role: .destructive) { resetAllSettings() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingNetworkActivity) {
            MacNetworkActivitySheet()
        }
    }

    private func resetAllSettings() {
        store.setStreamingQualityCeiling(SettingKeys.StreamingQualityCeiling.defaultValue)
        store.setDownloadQualityCeiling(SettingKeys.DownloadQualityCeiling.defaultValue)
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

struct MacNetworkActivitySheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            NetworkActivityView()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
        }
        .frame(minWidth: 760, minHeight: 520)
    }
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
                    .foregroundStyle(MacSecondaryStyle())
                    .lineLimit(1)
            }

            Form {
                TextField("Tempo (BPM)", text: $bpmText, prompt: Text("Analysed"))
                    .foregroundStyle(bpmIsValid ? Color.primary : Color.red)
                    .accessibilityValue(bpmIsValid ? bpmText : "\(bpmText), invalid")
                if !bpmIsValid {
                    Text("Enter a tempo between 20 and 300.")
                        .font(.caption)
                        .foregroundStyle(MacSecondaryStyle())
                }
                TextField("Key (Camelot, e.g. 8A)", text: $keyText, prompt: Text("Analysed"))
                    .foregroundStyle(keyIsValid ? Color.primary : Color.red)
                    .accessibilityValue(keyIsValid ? keyText : "\(keyText), invalid")
                if !keyIsValid {
                    Text("Use Camelot notation, for example 8A.")
                        .font(.caption)
                        .foregroundStyle(MacSecondaryStyle())
                }
                TextField("Genre", text: $genreText, prompt: Text("Analysed"))
            }
            .formStyle(.grouped)

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

extension AudioOutputKind {
    var displayName: String {
        switch self {
        case .builtIn: return "Built-in"
        case .headphones: return "Headphones"
        case .bluetooth: return "Bluetooth"
        case .airPlay: return "AirPlay"
        case .hdmi: return "HDMI"
        case .usb: return "USB"
        case .unknown: return "Unknown"
        }
    }
}
