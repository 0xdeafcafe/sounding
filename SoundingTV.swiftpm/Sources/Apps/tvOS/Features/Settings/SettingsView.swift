import SwiftUI

private enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case subscription, playback, downloads, intelligence, devices, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .subscription: return "Subscription"
        case .playback: return "Playback"
        case .downloads: return "Downloads"
        case .intelligence: return "Music Intelligence"
        case .devices: return "iPhone & Sync"
        case .about: return "About & Advanced"
        }
    }

    var description: String {
        switch self {
        case .subscription: return "SoundCloud plan and access"
        case .playback: return "Streaming, DJ and audio output"
        case .downloads: return "Offline music and storage"
        case .intelligence: return "Tempo, key and waveform data"
        case .devices: return "Pairing and shared preferences"
        case .about: return "Version and diagnostics"
        }
    }

}

struct SettingsView: View {
    @FocusState private var focus: SettingsCategory?
    @State private var path: [SettingsCategory] = {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["SOUNDING_TV_TV_SETTINGS"],
           let category = SettingsCategory(rawValue: raw) {
            return [category]
        }
        #endif
        return []
    }()

    var body: some View {
        NavigationStack(path: $path) {
            HStack(alignment: .center, spacing: 96) {
                SettingsContext(
                    title: "SoundingCloud",
                    description: "Playback, downloads, devices, and everything else about this Apple TV."
                )
                .frame(width: 560)

                categoryList
                    .frame(maxWidth: 920)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 96)
            .padding(.vertical, 64)
            .background { BrowseBackdrop() }
            .navigationTitle("")
            .toolbarVisibility(.visible, for: .tabBar)
            .navigationDestination(for: SettingsCategory.self) { category in
                SettingsDetailPage(category: category, onBack: popSettingsPage) {
                    detail(for: category)
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
                categoryLink(.intelligence)
            } header: {
                SettingsSectionTitle("Listening")
            }

            Section {
                categoryLink(.devices)
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
        .environment(\.defaultMinListRowHeight, 68)
        .scrollClipDisabled()
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func detail(for category: SettingsCategory) -> some View {
        switch category {
        case .subscription: SubscriptionSettings()
        case .playback: PlaybackSettings()
        case .downloads: DownloadsSettings()
        case .intelligence: MusicIntelligenceSettings()
        case .devices: DeviceSettings()
        case .about: AboutSettings()
        }
    }

    private func categoryLink(_ category: SettingsCategory) -> some View {
        NavigationLink(value: category) {
            Text(category.title)
                .font(.body.weight(.semibold))
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

    var body: some View {
        VStack(spacing: Space.roomy) {
            SettingsBrandArtwork()
                .frame(width: 400, height: 400)

            VStack(spacing: Space.tight) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Color.scTextPrimary)
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
    private let barHeights: [CGFloat] = [84, 138, 210, 274, 210, 138, 84]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 68, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.34, green: 0.12, blue: 0.04),
                            Color(red: 0.12, green: 0.06, blue: 0.04),
                            Color(red: 0.05, green: 0.05, blue: 0.06),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Circle()
                .stroke(Color.scAccent.opacity(0.18), lineWidth: 3)
                .frame(width: 310, height: 310)
            Circle()
                .stroke(Color.scAccent.opacity(0.28), lineWidth: 2)
                .frame(width: 244, height: 244)

            HStack(spacing: 13) {
                ForEach(Array(barHeights.enumerated()), id: \.offset) { _, height in
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 1.0, green: 0.55, blue: 0.12), Color.scAccent],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 27, height: height)
                }
            }
            .shadow(color: Color.scAccent.opacity(0.35), radius: 28)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 68, style: .continuous)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
        }
        .shadow(color: Color.scAccent.opacity(0.14), radius: 70, y: 28)
        .accessibilityHidden(true)
    }
}

private struct SettingsDetailPage<Content: View>: View {
    let category: SettingsCategory
    let onBack: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .center, spacing: 96) {
            SettingsContext(title: category.title, description: category.description)
                .frame(width: 560)

            content()
                .id(category)
                .listStyle(.grouped)
                .environment(\.defaultMinListRowHeight, 68)
                .scrollClipDisabled()
                .scrollIndicators(.hidden)
                .frame(maxWidth: 920)
                .accessibilityIdentifier("settings.detail.\(category.rawValue)")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 96)
        .padding(.vertical, 64)
        .background { BrowseBackdrop() }
        .navigationTitle(category.title)
        .navigationBarBackButtonHidden(true)
        .toolbarVisibility(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onBack) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 24, weight: .bold))
                        .frame(width: 64, height: 64)
                        .contentShape(Circle())
                }
                .accessibilityLabel("Back to Settings")
                .accessibilityIdentifier("settings.back")
            }
        }
        .onExitCommand(perform: onBack)
    }
}

private struct SubscriptionSettings: View {
    @ObservedObject private var subscription = SubscriptionService.shared
    @ObservedObject private var downloads = DownloadManager.shared
    @State private var isChecking = false

    var body: some View {
        List {
            Section {
                LabeledContent("Plan", value: tierDisplayName(subscription.tier))
                LabeledContent("Status", value: verificationDisplay(subscription.verification))
                Button(isChecking ? "Checking…" : "Check Again") { check() }
                    .disabled(isChecking)
            } header: {
                SettingsSectionTitle("Plan")
            } footer: {
                Text(subscription.statusDescription)
                    .settingsFooterStyle()
            }

            if let deletionDate = downloads.scheduledDeletionDate {
                Section {
                    Label {
                        Text("Downloads will be deleted on \(deletionDate.formatted(date: .abbreviated, time: .shortened)) unless the subscription is renewed.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.scDestructive)
                    }
                } header: {
                    SettingsSectionTitle("Downloads At Risk")
                }
            }

            if let raw = subscription.lastRawSubscriptionDescription {
                Section {
                    LabeledContent("SoundCloud Product", value: raw)
                        .lineLimit(2)
                } header: {
                    SettingsSectionTitle("SoundCloud Details")
                } footer: {
                    Text("Useful when SoundCloud doesn't hand back a readable plan name.")
                        .settingsFooterStyle()
                }
            }
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

    var body: some View {
        List {
            Section {
                Menu {
                    ForEach(QualityCeiling.allCases) { quality in
                        Button(qualityRowLabel(quality)) {
                            store.setStreamingQualityCeiling(quality)
                        }
                    }
                } label: {
                    SettingsChoiceRow(
                        "Streaming Quality",
                        value: qualityRowLabel(store.streamingQualityCeiling)
                    )
                }

                Menu {
                    ForEach(QualityCeiling.allCases) { quality in
                        Button(qualityRowLabel(quality)) {
                            store.setDownloadQualityCeiling(quality)
                        }
                    }
                } label: {
                    SettingsChoiceRow(
                        "Download Quality",
                        value: qualityRowLabel(store.downloadQualityCeiling)
                    )
                }
            } header: {
                SettingsSectionTitle("Quality")
            } footer: {
                Text("Higher quality uses more data while streaming and more storage when downloaded.")
                    .settingsFooterStyle()
            }

            CollectionQualitySection()

            Section {
                Button {
                    store.setDJAutoMixEnabled(!store.djAutoMixEnabled)
                } label: {
                    SettingsChoiceRow(
                        "DJ Auto-Mix",
                        value: store.djAutoMixEnabled ? "On" : "Off",
                        showsDisclosure: false
                    )
                }
                if store.djAutoMixEnabled {
                    Menu {
                        ForEach(DJProfile.all) { profile in
                            Button(profile.displayName) {
                                store.setDJDefaultProfileId(profile.id)
                            }
                        }
                    } label: {
                        SettingsChoiceRow(
                            "DJ Personality",
                            value: DJProfile.profile(id: store.djDefaultProfileId)?.displayName ?? "Automatic"
                        )
                    }
                }
            } header: {
                SettingsSectionTitle("DJ")
            } footer: {
                Text("Auto-Mix builds transitions from whatever track analysis it has.")
                    .settingsFooterStyle()
            }

            Section {
                Menu {
                    ForEach(GeneratedLibraryCollections.setDurationPresets, id: \.self) { duration in
                        Button(GeneratedLibraryCollections.durationLabel(duration)) {
                            store.setSetMinimumDurationSeconds(duration)
                        }
                    }
                } label: {
                    SettingsChoiceRow(
                        "Minimum Set Length",
                        value: GeneratedLibraryCollections.durationLabel(store.setMinimumDurationSeconds)
                    )
                }
            } header: {
                SettingsSectionTitle("Library")
            } footer: {
                Text("Sets use duration metadata from saved tracks. Adjusting this never downloads audio.")
                    .settingsFooterStyle()
            }

            Section {
                SettingsReadOnlyRow("Output", value: player.outputRoute.outputName ?? "Unavailable")
                SettingsReadOnlyRow("Channels", value: channelDescription)
                SettingsReadOnlyRow("Spatial Audio", value: "Stereo widened")
            } header: {
                SettingsSectionTitle("Audio Output")
            } footer: {
                Text("Stereo is adapted to the current output. SoundCloud doesn't provide Dolby Atmos masters.")
                    .settingsFooterStyle()
            }

        }
        .settingsScreen(
            "Playback",
            subtitle: "Quality, Auto-Mix, and audio output."
        )
    }

    private var channelDescription: String {
        player.outputRoute.supportsMultichannel
            ? "\(player.outputRoute.maximumOutputChannels)-channel"
            : "Stereo"
    }
}

/// A read-only setting still needs to participate in the tvOS focus engine so
/// users can continue through a section with the remote.
private struct SettingsReadOnlyRow: View {
    let title: String
    let value: String

    init(_ title: String, value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        SettingsChoiceRow(title, value: value, showsDisclosure: false)
            .focusable()
            .accessibilityElement(children: .combine)
    }
}

/// tvOS's stock Toggle and navigation-link Picker reserve different trailing
/// space. Keeping their value column in one row component makes a Settings
/// section scan as a clean table rather than a collection of unrelated cards.
private struct SettingsChoiceRow: View {
    let title: String
    let value: String
    var showsDisclosure = true

    init(_ title: String, value: String, showsDisclosure: Bool = true) {
        self.title = title
        self.value = value
        self.showsDisclosure = showsDisclosure
    }

    var body: some View {
        HStack(spacing: Space.tight) {
            Text(title)
                .lineLimit(1)
            Spacer(minLength: Space.tight)
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 240, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .opacity(showsDisclosure ? 1 : 0)
                .frame(width: 18)
        }
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct CollectionQualitySection: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var overrideStore = CollectionQualityOverrideStore.shared

    private enum LoadState {
        case idle, loading, signedOut, failed, loaded([Playlist])
    }

    @State private var state: LoadState = .idle

    @ViewBuilder
    var body: some View {
        Group {
            if case .loaded(let playlists) = state, !playlists.isEmpty {
                Section {
                ForEach(playlists) { playlist in
                    row(playlist)
                }
                } header: {
                    SettingsSectionTitle("Quality by Collection")
                } footer: {
                    Text("Overrides the default quality for individual playlists.")
                        .settingsFooterStyle()
                }
            }
        }
        .task { await load() }
    }

    private func row(_ playlist: Playlist) -> some View {
        let kind = CollectionKind.classify(playlist: playlist)
        let selection = Binding<QualityCeiling?>(
            get: { overrideStore.override(for: playlist.id) },
            set: { overrideStore.setOverride($0, for: playlist.id) }
        )
        let effective = selection.wrappedValue ?? store.downloadQualityCeiling
        return Picker(selection: selection) {
            Text("Use Default").tag(QualityCeiling?.none)
            ForEach(QualityCeiling.allCases) { level in
                Text(qualityRowLabel(level)).tag(QualityCeiling?.some(level))
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.title).lineLimit(1)
                Text("\(kind.displayName) · ~\(byteString(QualitySizeEstimator.estimatedBytes(for: playlist, ceiling: effective)))")
                    .font(.tvCaption)
                    .foregroundStyle(.secondary)
            }
        }
        .pickerStyle(.navigationLink)
    }

    private func load() async {
        guard case .idle = state else { return }
        state = .loading
        guard let user = AuthenticationService.shared.currentUser else {
            state = .signedOut
            return
        }
        do {
            let page = try await SoundCloudAPI.shared.getUserPlaylists(userId: user.id, limit: 50)
            state = .loaded(page.collection)
        } catch {
            state = .failed
        }
    }
}

private struct MusicIntelligenceSettings: View {
    @State private var snapshot: AnalysisDataSnapshot?
    @State private var showingClearAnalysisConfirmation = false
    @State private var showingClearLibraryConfirmation = false

    var body: some View {
        List {
            Section {
                LabeledContent("Tracks Analysed", value: count(\.analysedTrackCount))
                LabeledContent("Results Stored", value: count(\.resultCount))
                LabeledContent("From Other Devices", value: count(\.syncedResultCount))
                LabeledContent("Analysis Data", value: usageText)
            } header: {
                SettingsSectionTitle("Analysis")
            } footer: {
                Text("Genre and waveforms are worked out here. Tempo and key arrive from a synced iPhone or Mac. Old results are dropped automatically when space runs short.")
                    .settingsFooterStyle()
            }

            Section {
                LabeledContent("Tempo & Key", value: count(\.tempoKeyCount))
                LabeledContent("Genre", value: count(\.genreCount))
                LabeledContent("Waveforms", value: count(\.waveformCount))
            } header: {
                SettingsSectionTitle("Results by Kind")
            }

            Section {
                LabeledContent("Library Cache", value: libraryText)
            } footer: {
                Text("An offline copy of your library so it opens instantly. Clearing it re-downloads the listings next time. The space the file reserved gets reused, not handed back.")
                    .settingsFooterStyle()
            }

            Section {
                Button("Clear Analysis Data", role: .destructive) {
                    showingClearAnalysisConfirmation = true
                }
                Button("Clear Library Cache", role: .destructive) {
                    showingClearLibraryConfirmation = true
                }
            } footer: {
                Text("Clearing never interrupts playback. Analysis is rebuilt automatically the next time it's needed.")
                    .settingsFooterStyle()
            }
        }
        .settingsScreen(
            "Music Intelligence",
            subtitle: "Stored tempo, key, genre, and waveform data."
        )
        .task { await refresh() }
        .confirmationDialog("Clear Analysis Data", isPresented: $showingClearAnalysisConfirmation) {
            Button("Clear Analysis Data", role: .destructive) {
                Task {
                    await AnalysisDataUsage.clearAnalysisData()
                    await refresh()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every stored tempo, key, genre and waveform result on this Apple TV goes, including anything synced from other devices. Playback keeps going. Analysis is rebuilt when it's needed.")
        }
        .confirmationDialog("Clear Library Cache", isPresented: $showingClearLibraryConfirmation) {
            Button("Clear Library Cache", role: .destructive) {
                Task {
                    await AnalysisDataUsage.clearLibraryCache()
                    await refresh()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The offline copy of your library is emptied, then re-downloads the next time the library opens.")
        }
    }

    private func refresh() async {
        snapshot = await AnalysisDataUsage.snapshot()
    }

    private func count(_ keyPath: KeyPath<AnalysisDataSnapshot, Int>) -> String {
        guard let snapshot else { return "–" }
        let value = snapshot[keyPath: keyPath]
        return snapshot.isTruncated ? "\(value)+" : "\(value)"
    }

    private var usageText: String {
        guard let snapshot else { return "–" }
        return "\(cacheByteString(snapshot.usedBytes)) of \(cacheByteString(snapshot.maxBytes))"
    }

    private var libraryText: String {
        guard let snapshot else { return "–" }
        return cacheByteString(snapshot.libraryDiskBytes)
    }
}

private struct DownloadsSettings: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var subscription = SubscriptionService.shared
    @ObservedObject private var downloads = DownloadManager.shared

    @State private var showingRemoveAllConfirmation = false
    @State private var remoteDownloads: [String: [DownloadManifestSyncRecord]] = [:]
    @State private var transferringDeviceIDs: Set<String> = []

    var body: some View {
        List {
            Section {
                LabeledContent("Storage Used",
                               value: "\(byteString(downloads.usedBytes)) of \(byteString(store.downloadStorageCapBytes))")
                if downloads.usedBytes > 0 {
                    ProgressView(value: storageFraction)
                        .tint(storageFraction > 0.92 ? Color.scWarning : Color.scAccent)
                }
                Picker("Storage Limit", selection: store.downloadStorageCapBytesBinding) {
                    ForEach(Self.capChoices, id: \.self) { Text(byteString($0)).tag($0) }
                }
                .pickerStyle(.navigationLink)
            } header: {
                SettingsSectionTitle("Storage")
            } footer: {
                Text("Once you hit this limit, predictive downloads go oldest-first. Pinned tracks never go. The limit stays on this Apple TV.")
                    .settingsFooterStyle()
            }

            Section {
                if remoteDownloads.isEmpty {
                    Text("No downloads have synced from another device yet.")
                } else {
                    ForEach(remoteDownloads.keys.sorted(), id: \.self) { deviceID in
                        if let records = remoteDownloads[deviceID], let first = records.first {
                            Button {
                                Task { await copy(records, from: deviceID) }
                            } label: {
                                LabeledContent(
                                    first.deviceLabel,
                                    value: transferringDeviceIDs.contains(deviceID)
                                        ? "Copying…"
                                        : "Copy \(records.count)"
                                )
                            }
                            .disabled(transferringDeviceIDs.contains(deviceID))
                        }
                    }
                }
            } header: {
                SettingsSectionTitle("Other Devices")
            } footer: {
                Text("Copy uses the authenticated local companion link while the source device is awake, then encrypts the audio for this Apple TV.")
                    .settingsFooterStyle()
            }

            if downloads.entries.isEmpty {
                Section {
                    LabeledContent("Offline Downloads", value: "Track availability")
                } footer: {
                    Text("Downloads are available when a track exposes a usable source.")
                        .settingsFooterStyle()
                }
            }

            Section {
                if downloads.entries.isEmpty {
                    Text("No downloads on this Apple TV yet.")
                } else {
                    ForEach(sortedEntries, id: \.track.id) { entry in
                        DownloadEntryRow(
                            entry: entry,
                            state: downloads.state(for: entry.track.id),
                            onPause: { downloads.pause(trackId: entry.track.id) },
                            onResume: { downloads.resume(trackId: entry.track.id) },
                            onCancel: { downloads.cancel(trackId: entry.track.id) }
                        )
                    }
                }
            } header: {
                SettingsSectionTitle("Downloaded")
            } footer: {
                if !downloads.entries.isEmpty {
                    Text("A pin means you asked for it. A sparkle means it came down ahead of you.")
                        .settingsFooterStyle()
                }
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
        .task {
            remoteDownloads = await RemoteDownloadManifestStore.shared.manifestsByDevice(
                excluding: DownloadManifestDeviceIdentity.deviceId()
            )
        }
        .confirmationDialog("Remove All Downloads", isPresented: $showingRemoveAllConfirmation) {
            Button("Remove All Downloads", role: .destructive) { removeAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every downloaded track goes from this Apple TV. This can't be undone.")
        }
    }

    private var storageFraction: Double {
        let cap = store.downloadStorageCapBytes
        guard cap > 0 else { return 0 }
        return min(1, Double(downloads.usedBytes) / Double(cap))
    }

    private var sortedEntries: [DownloadEntry] {
        downloads.entries.values.sorted { $0.addedAt > $1.addedAt }
    }

    private static let capChoices: [Int64] = (1...100).map { Int64($0) * 1_000_000_000 }

    private func removeAll() {
        for trackId in downloads.entries.keys {
            downloads.cancel(trackId: trackId)
        }
    }

    private func copy(_ records: [DownloadManifestSyncRecord], from deviceID: String) async {
        transferringDeviceIDs.insert(deviceID)
        defer { transferringDeviceIDs.remove(deviceID) }
        for record in records where !Task.isCancelled {
            _ = await downloads.downloadFromPeer(
                trackId: record.trackId,
                sourceDeviceId: deviceID,
                provider: CompanionServer.shared,
                pinned: record.isPinned
            )
        }
    }
}

private struct DownloadEntryRow: View {
    let entry: DownloadEntry
    let state: DownloadState
    let onPause: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void

    var body: some View {
        Button(action: primaryAction) {
            LabeledContent {
                Text(stateText)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.track.title).lineLimit(1)
                        Text(entry.track.user.displayName)
                            .font(.tvCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } icon: {
                    Image(systemName: entry.isEffectivelyPinned ? "pin.fill" : "sparkles")
                }
            }
        }
    }

    private func primaryAction() {
        switch state {
        case .downloading, .queued: onPause()
        case .paused, .failed: onResume()
        case .downloaded, .notDownloaded: onCancel()
        }
    }

    private var stateText: String {
        switch state {
        case .notDownloaded: return "Remove"
        case .queued: return "Queued"
        case .downloading(let progress): return "\(Int(progress * 100))%"
        case .paused: return "Paused · Resume"
        case .downloaded: return "Downloaded · Remove"
        case .failed: return "Failed · Retry"
        }
    }
}

private struct DeviceSettings: View {
    @EnvironmentObject private var navigationState: NavigationState
    @ObservedObject private var remote = CompanionServer.shared
    @ObservedObject private var store = SettingsStore.shared
    @State private var showingUnpairConfirmation = false
    @State private var showingHelp = false

    var body: some View {
        List {
            Section {
                syncedRow("Streaming Quality", value: store.streamingQualityCeiling.displayName, key: SettingKeys.StreamingQualityCeiling.self)
                syncedRow("Download Quality", value: store.downloadQualityCeiling.displayName, key: SettingKeys.DownloadQualityCeiling.self)
                syncedRow("DJ Auto-Mix", value: store.djAutoMixEnabled ? "On" : "Off", key: SettingKeys.DJAutoMixEnabled.self)
                syncedRow(
                    "DJ Personality",
                    value: DJProfile.profile(id: store.djDefaultProfileId)?.displayName ?? "Automatic",
                    key: SettingKeys.DJDefaultProfileId.self
                )
                syncedRow(
                    "Transition Length",
                    value: formatSeconds(store.djTransitionLengthSeconds),
                    key: SettingKeys.DJTransitionLengthSeconds.self
                )
            } header: {
                SettingsSectionTitle("Shared Settings")
            } footer: {
                Text("Shared preferences are changed in SoundingCloud Settings on your iPhone. What's in force shows here.")
                    .settingsFooterStyle()
            }

            Section {
                LabeledContent("Queue Control", value: pairingStatus(remote))
                if let error = remote.lastError {
                    LabeledContent("Last Error", value: error)
                }
            } header: {
                SettingsSectionTitle("Companion Connection")
            }

            Section {
                Button("Open Companion Pairing") {
                    navigationState.selectedTab = .companion
                }
                Button(showingHelp ? "Hide Pairing Steps" : "Show Pairing Steps") {
                    showingHelp.toggle()
                }
                if showingHelp {
                    Text("""
                    1. Open SoundingCloud on a nearby companion device.
                    2. Choose this Apple TV, or scan the code on the Companion screen.
                    3. Compare the six-digit code on both screens.
                    4. A paired companion reconnects on its own on the same network.
                    """)
                }
            }

            if remote.isLinked {
                Section {
                    Button("Forget Companion", role: .destructive) {
                        showingUnpairConfirmation = true
                    }
                } footer: {
                    Text("That companion won't be able to control this Apple TV any more.")
                        .settingsFooterStyle()
                }
            }
        }
        .settingsScreen(
            "Devices & Sync",
            subtitle: "Pair a controller, manage queue control, and review shared preferences."
        )
        .confirmationDialog("Forget Companion", isPresented: $showingUnpairConfirmation) {
            Button("Forget Companion", role: .destructive) { remote.unpair() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This companion won't be able to control the queue any more. You can pair again from the Companion screen.")
        }
    }

    private func syncedRow<K: SettingDefinition>(_ title: String, value: String, key: K.Type) -> some View {
        LabeledContent(title, value: "\(value) · \(store.effectiveScope(key) == .synced ? "iPhone" : "This TV")")
    }
}

private struct AboutSettings: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var player = PlayerService.shared

    @State private var showingResetConfirmation = false
    #if DEBUG
    #endif

    var body: some View {
        List {
            Section {
                Picker("Screensaver Timeout", selection: store.ambientScreensaverTimeoutSecondsBinding) {
                    ForEach(timeoutChoices, id: \.self) { Text(formatSeconds($0)).tag($0) }
                }
                .pickerStyle(.navigationLink)
            } header: {
                SettingsSectionTitle("General")
            } footer: {
                Text("How long this Apple TV sits idle before ambient mode takes over. Stays on this Apple TV.")
                    .settingsFooterStyle()
            }

            Section {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Build", value: appBuild)
                LabeledContent("Source", value: "github.com/0xdeafcafe/sounding-tv")
            } header: {
                SettingsSectionTitle("About")
            }

            Section {
                LabeledContent("Playback Stalls", value: "\(player.observedStalls)")
                LabeledContent("Mix Engine", value: mixEngineDisplay)
            } header: {
                SettingsSectionTitle("Diagnostics")
            } footer: {
                Text("Stalls counted since launch. A rising number usually means the network, not the app.")
                    .settingsFooterStyle()
            }

            Section {
                Button("Reset All Settings", role: .destructive) {
                    showingResetConfirmation = true
                }
            } footer: {
                Text("Quality, DJ defaults and the screensaver timeout go back to how they started. Anything pinned to this Apple TV is unpinned too.")
                    .settingsFooterStyle()
            }

        }
        .settingsScreen(
            "About & Advanced",
            subtitle: "Version, diagnostics, and device-only options."
        )
        .confirmationDialog("Reset All Settings", isPresented: $showingResetConfirmation) {
            Button("Reset All Settings", role: .destructive) { resetAllSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Streaming and download quality, DJ defaults, and the screensaver timeout go back to how they started on this Apple TV. Synced settings pinned to this TV are unpinned too.")
        }
    }

    private var timeoutChoices: [Double] {
        stride(from: SettingsStore.ambientScreensaverTimeoutRange.lowerBound,
               through: SettingsStore.ambientScreensaverTimeoutRange.upperBound,
               by: 15).map { $0 }
    }

    private var mixEngineDisplay: String {
        switch player.mixEngineState {
        case .off: return "Off"
        case .preparing: return "Preparing"
        case .live: return "Live"
        case .unavailable(let reason): return "Unavailable · \(reason)"
        }
    }

    private func resetAllSettings() {
        store.setStreamingQualityCeiling(SettingKeys.StreamingQualityCeiling.defaultValue)
        store.setDownloadQualityCeiling(SettingKeys.DownloadQualityCeiling.defaultValue)
        store.setDownloadStorageCapBytes(SettingKeys.DownloadStorageCapBytes.defaultValue)
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

private struct SettingsSectionTitle: View {
    private let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 22, weight: .semibold))
            // List headers apply their own secondary emphasis on tvOS.
            .foregroundStyle(Color.scTextPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, Space.tight)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.white.opacity(0.16))
                    .frame(height: 1)
            }
            .textCase(nil)
            .padding(.top, Space.tight)
    }
}

private extension View {
    func settingsScreen(_ title: String, subtitle: String) -> some View {
        self
            .contentMargins(.vertical, Space.base, for: .scrollContent)
            .scrollIndicators(.hidden)
    }

    func settingsFooterStyle() -> some View {
        font(.system(size: 21, weight: .regular))
            .foregroundStyle(Color.scTextTertiary)
            .lineSpacing(3)
    }
}

private func tierDisplayName(_ tier: SubscriptionService.Tier) -> String {
    switch tier {
    case .free: return "Free"
    case .go: return "Go"
    case .goPlus: return "Go+"
    case .creatorPro: return "Creator"
    case .unknown: return "Unknown"
    }
}

private func verificationDisplay(_ verification: SubscriptionService.VerificationStatus) -> String {
    switch verification {
    case .verified: return "Verified"
    case .unverifiable(let withinGrace): return withinGrace ? "Unverified · Grace Period" : "Unverified"
    case .verifiedNotSubscribed: return "Not Subscribed"
    }
}

@MainActor
private func pairingStatus(_ remote: CompanionServer) -> String {
    guard remote.isLinked else { return "No companion paired" }
    return remote.isPhoneConnected ? "Paired · Connected" : "Paired · Not connected"
}

private var appVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
}

private var appBuild: String {
    Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
}

private func byteString(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useGB, .useMB]
    return formatter.string(fromByteCount: bytes)
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
