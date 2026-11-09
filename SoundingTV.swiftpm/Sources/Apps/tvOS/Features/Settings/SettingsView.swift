import SwiftUI

private enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case subscription, playback, downloads, analysis, musicFolders, devices, homeLighting, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .subscription: return "Subscription"
        case .playback: return "Playback"
        case .downloads: return "Downloads"
        case .analysis: return "Music Analysis"
        case .musicFolders: return "Music Folders"
        case .devices: return "Remotes & Devices"
        case .homeLighting: return "Home Lighting"
        case .about: return "About & Advanced"
        }
    }

    var description: String {
        switch self {
        case .subscription: return "SoundCloud plan and access"
        case .playback: return "Streaming, DJ and audio output"
        case .downloads: return "Offline music and storage"
        case .analysis: return "Tempo, key and genre"
        case .musicFolders: return "Your own music from your Mac, iPhone, iPad and iCloud"
        case .devices: return "iPhones and Macs linked to this Apple TV"
        case .homeLighting: return "Lights that follow the music"
        case .about: return "Version, screensaver, and reset"
        }
    }

    var icon: SettingsIcon {
        switch self {
        case .subscription: return .subscription
        case .playback: return .playback
        case .downloads: return .downloads
        case .analysis: return .analysis
        case .musicFolders: return .musicFolders
        case .devices: return .devices
        case .homeLighting: return .homeLighting
        case .about: return .about
        }
    }
}

struct SettingsView: View {
    @FocusState private var focus: SettingsCategory?
    @State private var path: NavigationPath = {
        var path = NavigationPath()
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["SOUNDING_TV_TV_SETTINGS"],
           let category = SettingsCategory(rawValue: raw) {
            path.append(category)
        }
        #endif
        return path
    }()

    var body: some View {
        NavigationStack(path: $path) {
            HStack(alignment: .center, spacing: 96) {
                SettingsContext(title: "Sounding", description: "Version \(appVersion)")
                .frame(width: 560)

                categoryList
                    .frame(maxWidth: 920)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 96)
            .padding(.top, 40)
            .padding(.bottom, 24)
            .background { BrowseBackdrop() }
            .navigationTitle("")
            .toolbarVisibility(.visible, for: .tabBar)
            .navigationDestination(for: SettingsCategory.self) { category in
                SettingsDetailPage(category: category, onBack: popSettingsPage) {
                    detail(for: category)
                }
            }
            .navigationDestination(for: DownloadsSettingsRoute.self) { route in
                switch route {
                case .downloadedMusic:
                    SettingsDetailPage(
                        title: "Downloaded Music",
                        description: "Playlists, Likes and tracks on this Apple TV.",
                        identifier: "downloadedMusic",
                        onBack: popSettingsPage
                    ) {
                        DownloadedMusicView()
                    }
                }
            }
            .navigationDestination(for: DownloadedCollectionRoute.self) { route in
                SettingsDetailPage(
                    title: route.title,
                    description: "Downloaded tracks in this collection.",
                    identifier: "downloadedCollection",
                    onBack: popSettingsPage
                ) {
                    DownloadedCollectionView(collectionID: route.id, title: route.title)
                }
            }
            .defaultFocus($focus, .subscription)
            .onAppear {
                guard path.isEmpty else { return }
                DispatchQueue.main.async { focus = .subscription }
            }
        }
    }

    private var categoryList: some View {
        List {
            Section {
                categoryLink(.subscription)
            } header: {
                SettingsSectionTitle("Account")
            }

            Section {
                categoryLink(.playback)
                categoryLink(.downloads)
                categoryLink(.analysis)
                categoryLink(.musicFolders)
            } header: {
                SettingsSectionTitle("Listening")
            }

            Section {
                categoryLink(.devices)
                categoryLink(.homeLighting)
            } header: {
                SettingsSectionTitle("Devices")
            }

            Section {
                categoryLink(.about)
            } header: {
                SettingsSectionTitle("App")
            }
        }
        .listStyle(.grouped)
        .environment(\.defaultMinListRowHeight, 64)
        .scrollClipDisabled()
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func detail(for category: SettingsCategory) -> some View {
        switch category {
        case .subscription: SubscriptionSettings()
        case .playback: PlaybackSettings()
        case .downloads: DownloadsSettings()
        case .analysis: MusicAnalysisSettings()
        case .musicFolders: MusicFoldersSettings()
        case .devices: DevicesSettings()
        case .homeLighting: HomeLightingSettingsView()
        case .about: AboutSettings()
        }
    }

    private func categoryLink(_ category: SettingsCategory) -> some View {
        NavigationLink(value: category) {
            Label {
                Text(category.title)
            } icon: {
                Image(systemName: category.icon.symbol)
                    .frame(width: 44)
            }
        }
        .focused($focus, equals: category)
        .accessibilityIdentifier("settings.section.\(category.rawValue)")
    }

    private func popSettingsPage() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }
}

private struct SettingsContext: View {
    let title: String
    let description: String
    var symbol: String?

    var body: some View {
        VStack(spacing: Space.roomy) {
            Group {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 220, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.scTextPrimary)
                        .accessibilityHidden(true)
                } else {
                    SettingsBrandArtwork()
                }
            }
            .frame(width: 400, height: 400)

            VStack(spacing: Space.tight) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Color.scTextPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(description)
                    .font(.callout)
                    .foregroundStyle(Color.scTextSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 520)
            }
        }
    }
}

private struct SettingsBrandArtwork: View {
    var body: some View {
        Image("SettingsBrandIcon")
            .resizable()
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 68, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 68, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.13), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.35), radius: 48, y: 24)
            .accessibilityHidden(true)
    }
}

private struct SettingsDetailPage<Content: View>: View {
    let title: String
    let description: String
    let identifier: String
    let symbol: String?
    let onBack: () -> Void
    @ViewBuilder let content: () -> Content

    init(category: SettingsCategory, onBack: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.init(
            title: category.title,
            description: category.description,
            identifier: category.rawValue,
            symbol: category.icon.symbol,
            onBack: onBack,
            content: content
        )
    }

    init(
        title: String,
        description: String,
        identifier: String,
        symbol: String? = "arrow.down.circle.fill",
        onBack: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.description = description
        self.identifier = identifier
        self.symbol = symbol
        self.onBack = onBack
        self.content = content
    }

    var body: some View {
        HStack(alignment: .center, spacing: 96) {
            SettingsContext(title: title, description: description, symbol: symbol)
                .frame(width: 560)

            content()
                .id(identifier)
                .tint(nil as Color?)
                .listStyle(.grouped)
                .environment(\.defaultMinListRowHeight, 68)
                .scrollClipDisabled()
                .scrollIndicators(.hidden)
                .frame(maxWidth: 920)
                .focusSection()
                .accessibilityIdentifier("settings.detail.\(identifier)")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 96)
        .padding(.vertical, 64)
        .background { BrowseBackdrop() }
        .navigationTitle("")
        .navigationBarBackButtonHidden(true)
        .toolbarVisibility(.hidden, for: .tabBar)
        .onExitCommand(perform: onBack)
    }
}

private struct SubscriptionSettings: View {
    @ObservedObject private var subscription = SubscriptionService.shared
    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @State private var isChecking = false
    @EnvironmentObject private var navigationState: NavigationState

    private var isSignedOut: Bool {
        credentials.sessionHealth.needsSignIn
    }

    private var hasAccountContext: Bool {
        !isSignedOut && subscription.authenticatedAccountID != nil
    }

    private var planDisplay: String {
        if isSignedOut { return "Unavailable" }
        guard hasAccountContext else { return "Checking…" }
        return subscription.tier.planName ?? tierDisplayName(subscription.tier)
    }

    private var statusDisplay: String {
        if isSignedOut { return "Sign In Required" }
        guard hasAccountContext else { return "Checking…" }
        return verificationDisplay(subscription.verification)
    }

    var body: some View {
        List {
            Section {
                SettingsReadOnlyRow("Plan", value: planDisplay)
                SettingsReadOnlyRow("Status", value: statusDisplay)
                if isSignedOut {
                    Button("Sign In to SoundCloud") { navigationState.isSigningIn = true }
                }
                Button(isChecking ? "Checking…" : "Check Again") { check() }
                    .disabled(isChecking || isSignedOut)
            } header: {
                SettingsSectionTitle("Plan")
            } footer: {
                Text(isSignedOut ? "Sign in to check your plan." : subscription.statusDescription)
                    .settingsFooterStyle()
            }

            if let deletionDate = downloads.scheduledDeletionDate {
                Section {
                    Label {
                        Text("Go+ downloads will be removed on \(deletionDate.formatted(date: .abbreviated, time: .shortened)) unless your plan is renewed.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.scDestructive)
                    }
                } header: {
                    SettingsSectionTitle("Downloads At Risk")
                }
            }

            #if DEBUG
            if let raw = subscription.lastRawSubscriptionDescription {
                Section {
                    SettingsReadOnlyRow("SoundCloud Product", value: raw)
                } header: {
                    SettingsSectionTitle("SoundCloud Details")
                }
            }
            #endif
        }
        .settingsScreen(
            "Subscription",
            subtitle: "Your SoundCloud plan and offline access."
        )
    }

    private func check() {
        guard !isChecking else { return }
        isChecking = true
        Task {
            await subscription.verifyNow()
            isChecking = false
        }
    }
}

private struct PlaybackSettings: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var player = PlayerService.shared

    static let energyPresets: [(name: String, value: Double)] = [
        ("Chill", 0.15), ("Warm", 0.4), ("Lively", 0.65), ("Peak", 0.95)
    ]

    static let riserPresets: [(name: String, value: Double)] = [
        ("Off", 0), ("Soft", 0.3), ("Medium", 0.5), ("Loud", 0.8)
    ]

    private var riserChoice: Binding<Double> {
        Binding(
            get: { Self.riserPresets.min { abs($0.value - store.djRiserLevel) < abs($1.value - store.djRiserLevel) }?.value ?? 0.5 },
            set: { store.setDJRiserLevel($0) }
        )
    }

    private var energyChoice: Binding<Double> {
        Binding(
            get: {
                guard !store.djEnergyFollowsNight else { return -1 }
                return Self.energyPresets.min { abs($0.value - store.djEnergyLevel) < abs($1.value - store.djEnergyLevel) }?.value ?? 0.65
            },
            set: { value in
                if value < 0 {
                    store.setDJEnergyFollowsNight(true)
                } else {
                    store.setDJEnergyFollowsNight(false)
                    store.setDJEnergyLevel(value)
                }
            }
        )
    }

    var body: some View {
        List {
            Section {
                Picker("Streaming Quality", selection: store.streamingQualityCeilingBinding) {
                    ForEach(QualityCeiling.allCases) { quality in
                        Text(qualityRowLabel(quality)).tag(quality)
                    }
                }
                .pickerStyle(.navigationLink)
            } header: {
                SettingsSectionTitle("Quality")
            } footer: {
                Text("Higher quality uses more data and storage.")
                    .settingsFooterStyle()
            }

            Section {
                Toggle("Auto Mix", isOn: store.djAutoMixEnabledBinding)
                if store.djAutoMixEnabled {
                    Picker("Style", selection: store.djDefaultProfileIdBinding) {
                        ForEach(DJProfile.all) { profile in
                            Text(profile.styleName).tag(profile.id)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    Picker("Blend", selection: store.djBlendBinding) {
                        ForEach(DJBlendLength.allCases) { blend in
                            Text(blend.displayName).tag(blend)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    Toggle("Keep Queue Order", isOn: store.djKeepQueueOrderBinding)
                    Picker("Energy", selection: energyChoice) {
                        Text("Follow the Night").tag(-1.0)
                        ForEach(Self.energyPresets.indices, id: \.self) { index in
                            Text(Self.energyPresets[index].name).tag(Self.energyPresets[index].value)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    Picker("Riser", selection: riserChoice) {
                        ForEach(Self.riserPresets.indices, id: \.self) { index in
                            Text(Self.riserPresets[index].name).tag(Self.riserPresets[index].value)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    .disabled(store.djDefaultProfileId == .wedding)
                    NavigationLink {
                        AutoMixMovesView().navigationTitle("Your Moves")
                    } label: {
                        Text("Your Moves")
                    }
                }
            } header: {
                SettingsSectionTitle("DJ")
            } footer: {
                if store.djAutoMixEnabled, let profile = DJProfile.profile(id: store.djDefaultProfileId) {
                    Text(profile.adventureSummary)
                        .settingsFooterStyle()
                }
            }

            Section {
                Picker("Minimum Set Length", selection: store.setMinimumDurationSecondsBinding) {
                    ForEach(GeneratedLibraryCollections.setDurationPresets, id: \.self) { duration in
                        Text(GeneratedLibraryCollections.durationLabel(duration)).tag(duration)
                    }
                }
                .pickerStyle(.navigationLink)
                LibrarySyncStatusRow()
            } header: {
                SettingsSectionTitle("Library")
            }

            Section {
                Toggle("Lyrics from LRCLIB", isOn: store.lyricsEnabledBinding)
            } header: {
                SettingsSectionTitle("Lyrics")
            } footer: {
                Text("Sends the track's title, artist and length to lrclib.net to find lyrics.")
            }

            Section {
                SettingsReadOnlyRow("Output", value: player.outputRoute.outputName ?? "Unavailable")
                SettingsReadOnlyRow("Channels", value: channelDescription)
                SettingsReadOnlyRow("Spatial Audio", value: "Stereo widened")
            } header: {
                SettingsSectionTitle("Audio Output")
            }

        }
        .settingsScreen(
            "Playback",
            subtitle: "Quality, Auto Mix, and audio output."
        )
    }

    private var channelDescription: String {
        player.outputRoute.supportsMultichannel
            ? "\(player.outputRoute.maximumOutputChannels)-channel"
            : "Stereo"
    }
}

private struct SettingsReadOnlyRow: View {
    let title: String
    let value: String

    init(_ title: String, value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        Button(action: {}) {
            LabeledContent(title) {
                Text(value)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityRemoveTraits(.isButton)
        .accessibilityAddTraits(.isStaticText)
    }
}

/// The value column shared by rows that need a custom label.
private struct SettingsChoiceRow: View {
    let title: String
    let value: String

    init(_ title: String, value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        LabeledContent(title) {
            Text(value)
        }
    }
}

private struct MusicFoldersSettings: View {
    @ObservedObject private var music = RemoteLocalMusic.shared

    var body: some View {
        List {
            Section {
                if music.devices.isEmpty {
                    SettingsReadOnlyRow("Sources", value: "None")
                } else {
                    ForEach(music.devices) { device in
                        SettingsReadOnlyRow(device.isCloud ? "iCloud" : device.name, value: LocalMusicFormatTV.trackCount(device.catalog?.tracks.count ?? 0))
                    }
                }
            } footer: {
                Text("Apple TV plays music from the folders on your Mac, iPhone or iPad over your home network while Sounding is open there, and from iCloud when Upload to iCloud is on. Choose folders in Sounding on those devices, in Settings › Music Folders.")
                    .settingsFooterStyle()
            }
        }
        .settingsScreen("Music Folders", subtitle: "Your own music.")
    }
}

private enum LocalMusicFormatTV {
    static func trackCount(_ count: Int) -> String {
        count == 1 ? "1 track" : "\(count) tracks"
    }
}

private struct MusicAnalysisSettings: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var storageUsedBytes: Int64?
    @State private var showingClearConfirmation = false

    var body: some View {
        List {
            Section {
                Toggle("Analyse Music on This Device", isOn: store.analyseMusicOnDeviceBinding)
            } footer: {
                Text("Finds tempo, key and genre for music you play or download.")
                    .settingsFooterStyle()
            }

            AnalysisLibraryStatusSection()

            Section {
                SettingsReadOnlyRow("Storage Used", value: storageUsedText)
            }

            Section {
                Button("Clear Analysis Data", role: .destructive) {
                    showingClearConfirmation = true
                }
                .disabled(storageUsedBytes == 0)
            }
        }
        .settingsScreen("Music Analysis", subtitle: "Tempo, key and genre.")
        .task { await refresh() }
        .confirmationDialog("Clear Analysis Data", isPresented: $showingClearConfirmation) {
            Button("Clear Analysis Data", role: .destructive) {
                Task {
                    await AutomaticAnalysisScheduler.shared.clearAnalysisData()
                    await refresh()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Tempo, key and genre results on this Apple TV are removed. Your corrections are kept.")
        }
    }

    private var storageUsedText: String {
        guard let storageUsedBytes else { return "–" }
        return cacheByteString(storageUsedBytes)
    }

    private func refresh() async {
        storageUsedBytes = await AnalysisDataUsage.storageUsedBytes()
    }
}

private struct DownloadsSettings: View {
    @ObservedObject private var downloads = DownloadManager.shared

    @State private var cacheUsage: CacheUsage?
    @State private var isClearingCache = false
    @State private var showingRedownloadConfirmation = false
    @State private var showingRemoveAllConfirmation = false

    var body: some View {
        let redownload = downloads.redownloadEstimate()
        List {
            Section {
                SettingsReadOnlyRow("Storage", value: "\(DownloadsFormat.bytes(downloads.storageUsed)) used by downloads")
                NavigationLink(value: DownloadsSettingsRoute.downloadedMusic) {
                    SettingsChoiceRow("Downloaded Music", value: downloadedSummary)
                }
            } header: {
                SettingsSectionTitle("Storage")
            }

            Section {
                SettingsReadOnlyRow("Optimise Storage", value: "Always On")
                Picker("Minimum Storage", selection: Binding(
                    get: { downloads.optimiseStorageMinimumBytes },
                    set: { downloads.setOptimiseStorageMinimumBytes($0) }
                )) {
                    ForEach(OptimiseStoragePolicy.minimumChoices, id: \.self) { bytes in
                        Text(DownloadsFormat.minimumStorage(bytes)).tag(bytes)
                    }
                }
                .pickerStyle(.navigationLink)
            } footer: {
                Text("When storage is low, downloads you haven't played recently are removed.")
                    .settingsFooterStyle()
            }

            Section {
                Picker("Download Quality", selection: Binding(
                    get: { downloads.quality },
                    set: { downloads.setQuality($0) }
                )) {
                    ForEach(QualityCeiling.allCases) { quality in
                        Text(qualityRowLabel(quality)).tag(quality)
                    }
                }
                .pickerStyle(.navigationLink)
                if redownload.trackCount > 0 {
                    Button("Re-download at New Quality (≈ \(redownload.sizeLabel))") {
                        showingRedownloadConfirmation = true
                    }
                }
            } footer: {
                Text("Applies to new downloads.")
                    .settingsFooterStyle()
            }

            Section {
                SettingsReadOnlyRow("Artwork", value: cacheUsage.map { DownloadsFormat.bytes($0.artworkBytes) } ?? "–")
                Button("Clear Artwork") { clearArtwork() }
                    .disabled(isClearingCache || (cacheUsage?.artworkBytes ?? 0) == 0)
            }

            Section {
                SettingsReadOnlyRow("Cache", value: cacheUsage.map { DownloadsFormat.bytes($0.totalBytes) } ?? "–")
                Button("Clear Cache") { clearCache() }
                    .disabled(isClearingCache || (cacheUsage?.totalBytes ?? 0) == 0)
            }

            if !downloads.entries.isEmpty {
                Section {
                    Button("Remove All Downloads", role: .destructive) {
                        showingRemoveAllConfirmation = true
                    }
                }
            }
        }
        .settingsScreen(
            "Downloads",
            subtitle: "Offline music and storage on this Apple TV."
        )
        .task { await refreshCache() }
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
            Text("Every download is deleted from this Apple TV.")
        }
    }

    private var downloadedSummary: String {
        let count = downloads.entries.values.filter(\.isDownloaded).count
        return count == 0 ? "None" : DownloadsFormat.trackCount(count)
    }

    private func refreshCache() async {
        cacheUsage = await CacheUsage.measure()
    }

    private func clearArtwork() {
        isClearingCache = true
        Task {
            await CacheUsage.clearArtwork()
            await refreshCache()
            isClearingCache = false
        }
    }

    private func clearCache() {
        isClearingCache = true
        Task {
            await CacheUsage.clearCaches()
            await refreshCache()
            isClearingCache = false
        }
    }
}

private enum DownloadsSettingsRoute: Hashable {
    case downloadedMusic
}

private struct DevicesSettings: View {
    @ObservedObject private var server = CompanionServer.shared

    @State private var isAddingDevice = Self.debugStartsAddingDevice
    @State private var deviceToForget: LinkedDevice?
    @State private var isConfirmingForgetAll = false

    var body: some View {
        content
            .settingsScreen(
                "Remotes & Devices",
                subtitle: "iPhones and Macs linked to this Apple TV."
            )
            .fullScreenCover(isPresented: $isAddingDevice) {
                QRCodeLoginView(onClose: { isAddingDevice = false }, purpose: .companion)
            }
            .confirmationDialog(
                deviceToForget.map { "Forget \($0.displayName)?" } ?? "Forget Device?",
                isPresented: Binding(
                    get: { deviceToForget != nil },
                    set: { if !$0 { deviceToForget = nil } }
                ),
                presenting: deviceToForget
            ) { device in
                Button("Forget Device", role: .destructive) { server.forget(device) }
                Button("Cancel", role: .cancel) {}
            } message: { device in
                Text("\(device.displayName) can't control this Apple TV until it's added again.")
            }
            .confirmationDialog("Forget All Devices", isPresented: $isConfirmingForgetAll) {
                Button("Forget All Devices", role: .destructive) { server.unpair() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Linked iPhones and Macs lose access to this Apple TV until they're added again.")
            }
    }

    @ViewBuilder
    private var content: some View {
        List {
            Section {
                ForEach(server.devices) { device in
                    Button {
                        deviceToForget = device
                    } label: {
                        LabeledContent(device.displayName) {
                            Text(server.connectedSessionIds.contains(device.sessionId) ? "Connected" : "Not Connected")
                        }
                    }
                    .accessibilityHint("Forget this device")
                }
                Button {
                    isAddingDevice = true
                } label: {
                    SettingsChoiceRow("Add Device…", value: "")
                }
                .accessibilityIdentifier("settings.devices.add")
            } header: {
                SettingsSectionTitle("Devices")
            } footer: {
                Text(server.devices.isEmpty ? "Link an iPhone or Mac to play music on this Apple TV and control it." : "Linked iPhones and Macs can play music on this Apple TV and control it.")
                    .settingsFooterStyle()
            }

            if server.devices.count > 1 {
                Section {
                    Button("Forget All Devices", role: .destructive) {
                        isConfirmingForgetAll = true
                    }
                }
            }
        }
    }

    private static var debugStartsAddingDevice: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["SOUNDING_TV_TV_PAIRING"] == "1"
        #else
        return false
        #endif
    }
}

private struct AboutSettings: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var player = PlayerService.shared

    @State private var showingResetConfirmation = false
    @State private var showingSource = false

    var body: some View {
        List {
            Section {
                Picker("Screensaver Timeout", selection: store.ambientScreensaverTimeoutSecondsBinding) {
                    ForEach(timeoutChoices, id: \.self) { Text(formatSeconds($0)).tag($0) }
                }
                .pickerStyle(.navigationLink)
                Toggle("Sync Settings with iCloud", isOn: store.syncSettingsWithICloudBinding)
            } header: {
                SettingsSectionTitle("General")
            } footer: {
                Text("Settings follow your Apple ID to your other devices. Recent searches and other SoundCloud account settings are cleared from this device when you sign out of SoundCloud.")
                    .settingsFooterStyle()
            }

            Section {
                SettingsReadOnlyRow("Version", value: appVersion)
                SettingsReadOnlyRow("Build", value: appBuild)
                #if DEBUG
                Button {
                    showingSource = true
                } label: {
                    SettingsChoiceRow("Source", value: "GitHub")
                }
                .accessibilityHint("Shows a scannable link to the source repository")
                #endif
            } header: {
                SettingsSectionTitle("About")
            }

            if NetworkActivityLog.isVisible {
                Section {
                    NavigationLink("Network Activity") { NetworkActivityView() }
                } header: {
                    SettingsSectionTitle("Advanced")
                }
            }

            #if DEBUG
            Section {
                SettingsReadOnlyRow("Playback Stalls", value: "\(player.observedStalls)")
                SettingsReadOnlyRow("Mix Engine", value: mixEngineDisplay)
            } header: {
                SettingsSectionTitle("Diagnostics")
            }
            #endif

            Section {
                Button("Reset All Settings", role: .destructive) {
                    showingResetConfirmation = true
                }
            }

        }
        .settingsScreen(
            "About & Advanced",
            subtitle: "Version, screensaver, and reset."
        )
        .sheet(isPresented: $showingSource) {
            SourceRepositoryView()
        }
        .confirmationDialog("Reset All Settings", isPresented: $showingResetConfirmation) {
            Button("Reset All Settings", role: .destructive) { resetAllSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Quality, Auto Mix and screensaver settings return to their defaults.")
        }
    }

    private var timeoutChoices: [Double] {
        stride(from: SettingsStore.ambientScreensaverTimeoutRange.lowerBound,
               through: SettingsStore.ambientScreensaverTimeoutRange.upperBound,
               by: 15).map { $0 }
    }

    #if DEBUG
    private var mixEngineDisplay: String {
        switch player.mixEngineState {
        case .off: return "Off"
        case .preparing: return "Preparing"
        case .live: return "Live"
        case .unavailable(let reason): return "Unavailable · \(reason)"
        }
    }
    #endif

    private func resetAllSettings() {
        store.setStreamingQualityCeiling(SettingKeys.StreamingQualityCeiling.defaultValue)
        store.setDownloadQualityCeiling(SettingKeys.DownloadQualityCeiling.defaultValue)
        store.setDJAutoMixEnabled(SettingKeys.DJAutoMixEnabled.defaultValue)
        store.setDJDefaultProfileId(SettingKeys.DJDefaultProfileId.defaultValue)
        store.setDJTransitionLengthSeconds(SettingKeys.DJTransitionLengthSeconds.defaultValue)
        store.setAmbientScreensaverTimeoutSeconds(SettingKeys.AmbientScreensaverTimeoutSeconds.defaultValue)
        store.setForceDeviceLocal(SettingKeys.StreamingQualityCeiling.self, false)
        store.setForceDeviceLocal(SettingKeys.DownloadQualityCeiling.self, false)
        store.setForceDeviceLocal(SettingKeys.DJAutoMixEnabled.self, false)
        store.setForceDeviceLocal(SettingKeys.DJDefaultProfileId.self, false)
        store.setForceDeviceLocal(SettingKeys.DJTransitionLengthSeconds.self, false)
    }

}

private struct SourceRepositoryView: View {
    private static let repository = "https://github.com/0xdeafcafe/sounding-tv"

    @Environment(\.dismiss) private var dismiss
    @FocusState private var closeFocused: Bool
    @State private var matrix: QRMatrix?

    var body: some View {
        VStack(spacing: Space.roomy) {
            HStack {
                VStack(alignment: .leading, spacing: Space.tight) {
                    Text("Open Source")
                        .font(.tvTitle)
                        .foregroundStyle(Color.scTextPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text("Scan with your phone to visit Sounding on GitHub.")
                        .font(.tvBody)
                        .foregroundStyle(Color.scTextSecondary)
                }
                Spacer()
                PanelCloseButton { dismiss() }
                    .focused($closeFocused)
            }

            Spacer()

            RoundedRectangle(cornerRadius: CornerRadius.xl, style: .continuous)
                .fill(Color.white)
                .frame(width: 430, height: 430)
                .shadow(color: Color.black.opacity(0.48), radius: 42, y: 18)
                .overlay {
                    if let matrix {
                        QRCodeView(matrix: matrix, markColor: Color(white: 0.22))
                            .frame(width: 390, height: 390)
                    } else {
                        ProgressView()
                            .tint(Color.black.opacity(0.45))
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(matrix == nil ? "Preparing QR code" : "QR code linking to \(Self.repository)")

            Text(Self.repository)
                .font(.tvSubheadline)
                .foregroundStyle(Color.scTextSecondary)

            Spacer()
        }
        .padding(Space.page)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.scBackground.ignoresSafeArea())
        .defaultFocus($closeFocused, true)
        .onExitCommand { dismiss() }
        .task {
            matrix = QRCodeGenerator.matrix(for: Self.repository)
        }
    }
}

struct SettingsSectionTitle: View {
    private let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
            .accessibilityAddTraits(.isHeader)
    }
}

private extension View {
    func settingsScreen(_ title: String, subtitle: String) -> some View {
        self
            .contentMargins(.vertical, Space.base, for: .scrollContent)
            .scrollIndicators(.hidden)
    }

    func settingsFooterStyle() -> some View {
        font(.caption)
            .foregroundStyle(.secondary)
    }
}

private func tierDisplayName(_ tier: SubscriptionService.Tier) -> String {
    switch tier {
    case .free: return "Free"
    case .go: return "Go"
    case .goPlus: return "Go+"
    case .dj: return "DJ"
    case .creatorPro: return "Artist"
    case .unknown: return "Unknown"
    }
}

private func verificationDisplay(_ verification: SubscriptionService.VerificationStatus) -> String {
    switch verification {
    case .verified: return "Verified"
    case .unverifiable: return "Unverified"
    case .verifiedNotSubscribed: return "Not Subscribed"
    }
}

private var appVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
}

private var appBuild: String {
    Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
}

private func cacheByteString(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    return formatter.string(fromByteCount: bytes)
}

private func qualityRowLabel(_ level: QualityCeiling) -> String {
    if let mb = QualitySizeEstimator.approximateMBPerHour(for: level) {
        return "\(level.displayName) (~\(Int(mb.rounded())) MB/hr)"
    }
    return "\(level.displayName) (varies, no cap)"
}

private func formatSeconds(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let minutes = total / 60
    let remainder = total % 60
    if minutes == 0 { return "\(remainder)s" }
    if remainder == 0 { return "\(minutes)m" }
    return "\(minutes)m \(remainder)s"
}
