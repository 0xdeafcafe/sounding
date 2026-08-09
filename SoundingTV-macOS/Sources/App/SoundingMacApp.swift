import SwiftUI
import AppKit
import os
import UserNotifications

@main
struct SoundingMacApp: App {
    @StateObject private var credentials = SoundCloudCredentialSource.shared
    @StateObject private var midi = MIDIControllerHub.shared
    @StateObject private var tvCompanion = CompanionClient()
    @StateObject private var polyphony = PolyphonyController.shared
    @State private var authHandoffRequest: AuthHandoffRequest?

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SOUNDING_TV_MAC_WINDOW_SIZE"] != nil {
            let defaults = UserDefaults.standard
            let staleKeys = defaults.dictionaryRepresentation().keys.filter {
                $0.hasPrefix("NSWindow Frame SwiftUI.WindowGroup")
                    || $0.hasPrefix("NSSplitView Subview Frames SwiftUI.WindowGroup")
            }
            for key in staleKeys { defaults.removeObject(forKey: key) }
        }
        #endif
        SoundCloudCredentialSource.install()
        SoundCloudCredentialSource.shared.sideEffects = .init(
            requestSessionSync: { CloudSyncCoordinator.shared.requestSessionSync() },
            wipeLocalIndexes: { accountID in
                LikesSyncEngine.shared.handleSignOut()
                await LibraryCache.shared.clearAll()
                if let accountID { AccountDataVault.forget(accountID: accountID) }
            },
            clearWebSession: {}
        )
        MacAudioSessionCoordinator.install()
        PlayerService.installNowPlaying(MediaSessionNowPlayingBridge())
        PlayerService.lifecycleObserver = PlayerLifecycleObserver.shared
        LikesSyncEngine.shared.activate()
        LikesSyncLifecycleCoordinator.shared.install()

        MacSyncCoordinator.install()
        MacSyncCoordinator.shared.start()
        MacSyncCoordinator.shared.startPeriodicSync()
        #if DEBUG
        if ProcessInfo.processInfo.environment["SOUNDING_TV_MIDITEST"] == "1" {
            let failures = DDJ400MappingSelfTest.run()
            if failures.isEmpty {
                Log.dj.info("MIDITEST DDJ400MappingSelfTest: all checks passed.")
            } else {
                Log.dj.error("MIDITEST DDJ400MappingSelfTest: \(failures.count, privacy: .public) failure(s):")
                for failure in failures { Log.dj.error("  - \(failure, privacy: .public)") }
            }
        }
        #endif
    }

    var body: some Scene {
        Window("SoundingCloud", id: "main") {
            MacRootView()
                .environmentObject(credentials)
                .environmentObject(midi)
                .environmentObject(tvCompanion)
                .environmentObject(polyphony)
                .frame(minWidth: 1040, idealWidth: 1360, minHeight: 640, idealHeight: 820)
                .background(MacWindowChrome(musicWindow: .main).frame(width: 0, height: 0))
                .background(MacMessageWindowBridge())
                .task {
                    MacMusicWindowCoordinator.shared.request(.main)
                    credentials.refreshFromStore()
                    if !credentials.isSignedOut { await credentials.revalidate() }
                    await credentials.purgeExpiredLockedDataIfNeeded()
                    midi.start()
                    MIDIMixerBridge.shared.start()
                    PlayerService.remoteOutput = tvCompanion
                    PlayerService.peerContentSource = tvCompanion
                    tvCompanion.connect()
                    #if DEBUG
                    if ProcessInfo.processInfo.environment["SOUNDING_TV_MIXAUDIOTEST"] == "1" {
                        await MacMixAudioSelfTest.run()
                    }
                    #endif
                }
                .task(id: credentials.currentUser?.id) {
                    guard let user = await credentials.waitForCurrentUser() else { return }
                    await MacActivityNotificationDelivery.prepare()
                    while !Task.isCancelled {
                        let events = await SoundCloudActivityPoller.shared.poll(accountID: user.id)
                        await MacActivityNotificationDelivery.deliver(events)
                        do {
                            try await Task.sleep(for: .seconds(5 * 60))
                        } catch {
                            return
                        }
                    }
                }
                .task {
                    for await notification in NotificationCenter.default.notifications(named: .companionClientAuthHandoffRequest, object: tvCompanion) {
                        guard let userInfo = notification.userInfo,
                              let sessionId = userInfo[CompanionClientAuthHandoffRequestSessionIdKey] as? String,
                              let secretBase64 = userInfo[CompanionClientAuthHandoffRequestSecretKey] as? String,
                              let secret = Data(base64Encoded: secretBase64) else { continue }
                        let peerClass = userInfo["peerClass"] as? DeviceClass ?? .tv
                        let peerName = userInfo["peerName"] as? String
                        authHandoffRequest = AuthHandoffRequest(
                            sessionId: sessionId,
                            secret: secret,
                            peerName: peerName,
                            peerClass: peerClass
                        )
                    }
                }
                .sheet(item: $authHandoffRequest) { request in
                    MacSoundCloudSignInView(
                        peerName: request.peerName ?? request.peerClass.displayName,
                        forHandoff: true
                    ) {
                        authHandoffRequest = nil
                    }
                    .frame(minWidth: 720, minHeight: 620)
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            SidebarCommands()
            SoundingViewCommands()
            LibraryCommands()
            TransportCommands()
            DecksCommands()
            MessagingCommands()
        }

        Window("Mini Player", id: "mini-player") {
            MacMiniPlayerView()
                .background(MacWindowChrome(musicWindow: .miniPlayer).frame(width: 0, height: 0))
                .onAppear { MacMusicWindowCoordinator.shared.request(.miniPlayer) }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 300, height: 168)
        .defaultPosition(.bottomTrailing)
        .commands {
            TransportCommands()
        }

        Window("Messages", id: "messages") {
            MacMessagesView()
                .environmentObject(credentials)
                .frame(minWidth: 860, idealWidth: 1040, minHeight: 560, idealHeight: 700)
        }
        .defaultSize(width: 1040, height: 700)

        Settings {
            MacSettingsView()
                .environmentObject(credentials)
                .environmentObject(midi)
                .environmentObject(tvCompanion)
                .environmentObject(polyphony)
                .tint(.scAccent)
        }
        .windowResizability(.contentSize)

        MenuBarExtra("SoundingCloud", systemImage: "waveform.circle.fill") {
            MacMenuBarPlayerView()
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
private enum MacActivityNotificationDelivery {
    private static let center = UNUserNotificationCenter.current()

    static func prepare() async {
        center.delegate = MacActivityNotificationDelegate.shared
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    static func deliver(_ events: [SoundCloudInboxEvent]) async {
        guard !events.isEmpty else { return }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else { return }

        for event in events {
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.body
            content.sound = .default
            content.userInfo = [
                "eventID": event.id,
                "destination": event.destination?.absoluteString ?? "",
            ]
            let request = UNNotificationRequest(
                identifier: "soundcloud.activity.\(event.id)",
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }
}

private final class MacActivityNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = MacActivityNotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let raw = response.notification.request.content.userInfo["destination"] as? String,
              let url = URL(string: raw), !raw.isEmpty else { return }
        _ = await MainActor.run { NSWorkspace.shared.open(url) }
    }
}

private struct MacMenuBarPlayerView: View {
    @ObservedObject private var player = PlayerService.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private var track: Track? { player.currentTrack }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let track {
                HStack(spacing: 10) {
                    ArtworkThumbnail(
                        url: track.artworkURL,
                        identity: track.title,
                        size: 44,
                        cornerRadius: 6,
                        isAvailable: track.streamURL != nil,
                        crownUser: track.user,
                        crownContext: track.title
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(track.user.displayName)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }

                ProgressView(value: player.duration > 0 ? player.currentTime / player.duration : 0)
                    .tint(.primary)

                HStack(spacing: 28) {
                    Spacer(minLength: 0)
                    Button {
                        Task { await InstantReplay.previous(player) }
                    } label: {
                        Image(systemName: "backward.fill")
                    }
                    Button {
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    Button {
                        Task { await player.playNext() }
                    } label: {
                        Image(systemName: "forward.fill")
                    }
                    Spacer(minLength: 0)
                }
                .buttonStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .padding(.vertical, 2)
            } else {
                HStack {
                    Spacer(minLength: 0)
                    VStack(spacing: 6) {
                        Image(systemName: "waveform.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.secondary)
                        Text("Nothing Playing")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    Spacer(minLength: 0)
                }
            }

            Divider()

            Button("Open SoundingCloud") {
                NSApp.activate(ignoringOtherApps: true)
                MacMusicWindowCoordinator.shared.request(.main)
                openWindow(id: "main")
                dismissWindow(id: "mini-player")
            }
            .buttonStyle(.plain)

            Button("Quit SoundingCloud") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 260)
    }
}

struct TransportCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some Commands {
        CommandMenu("Playback") {
            Button {
                let controller = MacConsoleController.shared
                if controller.isConsoleActive {
                    controller.togglePlayPause(controller.focusedDeck)
                } else {
                    PlayerService.shared.togglePlayPause()
                }
            } label: {
                Label("Play/Pause", systemImage: "playpause")
            }
            .keyboardShortcut(.space, modifiers: [])
            Button {
                guard !MacConsoleController.shared.isConsoleActive else { return }
                Task { await PlayerService.shared.playNext() }
            } label: {
                Label("Next Track", systemImage: "forward.fill")
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command])
            Button {
                guard !MacConsoleController.shared.isConsoleActive else { return }
                Task { await InstantReplay.previous(PlayerService.shared) }
            } label: {
                Label("Previous Track", systemImage: "backward.fill")
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command])
            Divider()
            Button {
                MacMusicWindowCoordinator.shared.request(.miniPlayer)
                openWindow(id: "mini-player")
                dismissWindow(id: "main")
            } label: {
                Label("Mini Player", systemImage: "pip")
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            Button {
                MacMusicWindowCoordinator.shared.request(.main)
                openWindow(id: "main")
                dismissWindow(id: "mini-player")
                MacNowPlayingPresentation.shared.present()
            } label: {
                Label("Now Playing", systemImage: "music.note.house")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button {
                MacRootSelection.shared.request(.console)
            } label: {
                Label("Open Decks", systemImage: "slider.horizontal.3")
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
        }
    }
}

struct SoundingViewCommands: Commands {
    @AppStorage("mac.library.showsArtwork") private var showsArtwork = true
    @AppStorage("mac.library.compactRows") private var usesCompactRows = true

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button {
                MacRootSelection.shared.toggleQueue()
            } label: {
                Label("Show or Hide Queue", systemImage: "music.note.list")
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])

            Toggle(isOn: $showsArtwork) {
                Label("Show Artwork in Track Lists", systemImage: "photo")
            }

            Toggle(isOn: $usesCompactRows) {
                Label("Use Compact Track Rows", systemImage: "rectangle.compress.vertical")
            }
            .disabled(showsArtwork)
        }
    }
}

struct LibraryCommands: Commands {
    var body: some Commands {
        CommandMenu("Library") {
            destination("Likes", systemImage: "heart", section: .likes, shortcut: "1")
            destination("Artists", systemImage: "person.2", section: .artists, shortcut: "2")
            destination("All Playlists", systemImage: "square.stack.3d.up", section: .playlists, shortcut: "3")
            Divider()
            destination("Music Intelligence", systemImage: "waveform.badge.magnifyingglass", section: .intelligence)
            destination("Search SoundCloud", systemImage: "magnifyingglass", section: .search, shortcut: "f")
        }
    }

    @ViewBuilder
    private func destination(
        _ title: String,
        systemImage: String,
        section: MacRootView.Section,
        shortcut: KeyEquivalent? = nil
    ) -> some View {
        if let shortcut {
            Button {
                MacRootSelection.shared.request(section)
            } label: {
                Label(title, systemImage: systemImage)
            }
            .keyboardShortcut(shortcut, modifiers: [.command, .option])
        } else {
            Button {
                MacRootSelection.shared.request(section)
            } label: {
                Label(title, systemImage: systemImage)
            }
        }
    }
}

// MARK: - SoundCloud messages

extension Notification.Name {
    static let presentSoundCloudMessages = Notification.Name("presentSoundCloudMessages")
}

@MainActor
final class MacMessageComposer: ObservableObject {
    static let shared = MacMessageComposer()

    @Published private(set) var revision = 0
    private(set) var sharedTrack: Track?
    private(set) var recipient: User?

    private init() {}

    func present(track: Track? = nil) {
        sharedTrack = track
        recipient = nil
        revision += 1
        NotificationCenter.default.post(name: .presentSoundCloudMessages, object: nil)
    }

    func present(user: User) {
        sharedTrack = nil
        recipient = user
        revision += 1
        NotificationCenter.default.post(name: .presentSoundCloudMessages, object: nil)
    }

    func consumeSharedTrack() -> Track? {
        defer { sharedTrack = nil }
        return sharedTrack
    }

    func consumeRecipient() -> User? {
        defer { recipient = nil }
        return recipient
    }
}

private struct MacMessageWindowBridge: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(NotificationCenter.default.publisher(for: .presentSoundCloudMessages)) { _ in
                openWindow(id: "messages")
                NSApp.activate(ignoringOtherApps: true)
            }
    }
}

struct MessagingCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Social") {
            Button {
                openWindow(id: "messages")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Messages", systemImage: "bubble.left.and.bubble.right")
            }
            .keyboardShortcut("m", modifiers: [.command, .option])
        }
    }
}

@MainActor
private final class MacMessagesModel: ObservableObject {
    @Published private(set) var conversations: [SoundCloudConversation] = []
    @Published var selectedID: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isSending = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var requiresWebInbox = false
    @Published private(set) var userResults: [User] = []
    @Published private(set) var isSearchingUsers = false

    private let api = SoundCloudAPI.shared
    private var searchTask: Task<Void, Never>?
    private var cacheAccountID: String?

    var selectedConversation: SoundCloudConversation? {
        conversations.first(where: { $0.id == selectedID })
    }

    func restoreCached(accountID: String) async {
        cacheAccountID = accountID
        guard conversations.isEmpty,
              let cached = await MacMessageCache.shared.load(accountID: accountID) else { return }
        conversations = cached.sorted(by: Self.isNewer)
        if selectedID == nil { selectedID = conversations.first?.id }
    }

    func load(accountID: String? = nil) async {
        guard !isLoading else { return }
        if let accountID { await restoreCached(accountID: accountID) }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let page = try await api.getConversations(limit: 50)
            conversations = page.collection.sorted(by: Self.isNewer)
            await persistCache()
            requiresWebInbox = false
            if selectedID == nil { selectedID = conversations.first?.id }
            if let selectedID { await loadConversation(selectedID) }
        } catch SoundCloudMessagingError.unavailable {
            requiresWebInbox = true
            errorMessage = SoundCloudMessagingError.unavailable.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadConversation(_ id: String) async {
        do {
            let loaded = try await api.getConversation(id: id)
            replace(loaded)
            await persistCache()
        } catch SoundCloudMessagingError.unavailable {
            requiresWebInbox = true
        } catch {
            // The list response from some SoundCloud deployments already
            // contains the entire thread. Preserve it if the detail route is
            // not separately available.
            if selectedConversation?.messages.isEmpty != false {
                errorMessage = error.localizedDescription
            }
        }
    }

    func send(_ draft: String, to recipient: SoundCloudMessageParticipant) async -> Bool {
        await send(draft, recipientID: recipient.id, conversationID: selectedID)
    }

    func startConversation(_ draft: String, with user: User) async -> Bool {
        let sent = await send(draft, recipientID: user.id, conversationID: nil)
        if sent { await load() }
        return sent
    }

    private func send(_ draft: String, recipientID: String, conversationID: String?) async -> Bool {
        guard !isSending else { return false }
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            if let updated = try await api.sendDirectMessage(
                draft,
                to: recipientID,
                conversationID: conversationID
            ) {
                replace(updated)
                selectedID = updated.id
                await persistCache()
            } else if let conversationID {
                await loadConversation(conversationID)
            }
            requiresWebInbox = false
            return true
        } catch SoundCloudMessagingError.unavailable {
            requiresWebInbox = true
            errorMessage = SoundCloudMessagingError.unavailable.localizedDescription
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func searchUsers(_ query: String) {
        searchTask?.cancel()
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 2 else {
            userResults = []
            isSearchingUsers = false
            return
        }
        isSearchingUsers = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do {
                userResults = try await api.searchUsers(query: clean, limit: 20).collection
            } catch {
                if !Task.isCancelled { userResults = [] }
            }
            isSearchingUsers = false
        }
    }

    func clearError() { errorMessage = nil }

    private func replace(_ conversation: SoundCloudConversation) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
        } else {
            conversations.insert(conversation, at: 0)
        }
        conversations.sort(by: Self.isNewer)
    }

    private func persistCache() async {
        guard let cacheAccountID else { return }
        await MacMessageCache.shared.save(conversations, accountID: cacheAccountID)
    }

    private static func isNewer(_ lhs: SoundCloudConversation, _ rhs: SoundCloudConversation) -> Bool {
        (lhs.latestMessage?.createdAt ?? lhs.lastUpdatedAt ?? .distantPast)
            > (rhs.latestMessage?.createdAt ?? rhs.lastUpdatedAt ?? .distantPast)
    }
}

private actor MacMessageCache {
    static let shared = MacMessageCache()
    private let ttl: TimeInterval = 24 * 60 * 60

    private struct Snapshot: Codable {
        let savedAt: Date
        let conversations: [SoundCloudConversation]
    }

    func load(accountID: String) -> [SoundCloudConversation]? {
        let key = storageKey(accountID)
        guard let sealed = UserDefaults.standard.data(forKey: key),
              let data = AccountDataVault.open(sealed, accountID: accountID, purpose: key),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              Date().timeIntervalSince(snapshot.savedAt) <= ttl else { return nil }
        return snapshot.conversations
    }

    func save(_ conversations: [SoundCloudConversation], accountID: String) {
        let key = storageKey(accountID)
        guard let data = try? JSONEncoder().encode(Snapshot(savedAt: Date(), conversations: conversations)),
              let sealed = AccountDataVault.seal(data, accountID: accountID, purpose: key) else { return }
        UserDefaults.standard.set(sealed, forKey: key)
    }

    private func storageKey(_ accountID: String) -> String {
        "red.forbes.sounding.messages.v1.\(AccountDataVault.storageSuffix(for: accountID))"
    }
}

struct MacMessagesView: View {
    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    @Environment(\.openSettings) private var openSettings
    @StateObject private var model = MacMessagesModel()
    @ObservedObject private var composer = MacMessageComposer.shared
    @State private var draft = ""
    @State private var showsNewMessage = false
    @State private var showsAuthentication = false
    @State private var isReauthentication = false
    @State private var initialRecipient: User?

    var body: some View {
        Group {
            if !credentials.hasConfirmedAccount {
                messagesGate
            } else {
                HSplitView {
                    conversationList
                        // Messages is also hosted in the main window, where
                        // the detail column can be substantially narrower
                        // than the standalone Messages window. Keep the
                        // list flexible so it cannot force the detail pane
                        // underneath the parent's clipping boundary.
                        .frame(minWidth: 190, idealWidth: 260, maxWidth: 300)
                    conversationDetail
                        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: credentials.accessToken) {
            let accountID = credentials.currentUser?.id ?? SubscriptionService.shared.authenticatedAccountID
            if let accountID { await model.restoreCached(accountID: accountID) }
            guard credentials.accessToken != nil else { return }
            await model.load(accountID: accountID)
            consumeSharedTrack()
        }
        .onChange(of: model.selectedID) { _, id in
            guard let id else { return }
            Task { await model.loadConversation(id) }
        }
        .onChange(of: composer.revision) { _, _ in consumeSharedTrack() }
        .sheet(isPresented: $showsNewMessage) {
            MacNewMessageSheet(
                model: model,
                initialDraft: draft,
                initialRecipient: initialRecipient
            ) {
                showsNewMessage = false
                draft = ""
                initialRecipient = nil
            }
        }
        .sheet(isPresented: $showsAuthentication) {
            MacSoundCloudSignInView(
                peerName: nil,
                forHandoff: false,
                isReauthentication: isReauthentication
            ) {
                showsAuthentication = false
                isReauthentication = false
                Task { await model.load() }
            }
            .frame(minWidth: 720, minHeight: 620)
        }
    }

    @ViewBuilder
    private var messagesGate: some View {
        VStack(spacing: 0) {
            MacPaneHeader(title: "Messages")
            if credentials.isSessionRejected {
                SCEmptyState(
                    kind: .error,
                    title: "Sign-In Expired",
                    message: "Sign in again with SoundCloud to access messages.",
                    actionTitle: "Reauthenticate",
                    action: {
                        isReauthentication = true
                        showsAuthentication = true
                    },
                    style: .mac
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else if credentials.isSignedOut {
                MacSignedOutEmptyState(
                    icon: "bubble.left.and.bubble.right",
                    title: "Messages Need an Account",
                    message: "Sign in on this Mac to view SoundCloud messages. Home and Search still work in guest mode.",
                    browsableRoute: .home
                )
            } else {
                ProgressView("Checking sign-in…")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 48)
            }
            Spacer(minLength: 0)
        }
    }

    private var conversationList: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Messages").font(.title2.bold())
                    Text("SoundCloud direct messages")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { showsNewMessage = true } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.borderless)
                .help("New message")
                .disabled(!credentials.canPerformAccountMutations)
                Button { Task { await model.load() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh messages")
            }
            .padding(16)

            Divider()

            if model.isLoading && model.conversations.isEmpty {
                Spacer()
                ProgressView("Loading messages…")
                Spacer()
            } else if model.conversations.isEmpty {
                Spacer()
                ContentUnavailableView(
                    model.requiresWebInbox
                        ? "Continue on SoundCloud"
                        : (model.errorMessage == nil ? "No messages yet" : "Messages unavailable"),
                    systemImage: model.requiresWebInbox ? "safari" : "bubble.left",
                    description: Text(model.errorMessage ?? "Start a conversation with an artist or listener.")
                )
                if model.requiresWebInbox {
                    Button("Open web inbox") { openWebInbox() }
                        .buttonStyle(.borderedProminent)
                } else if model.errorMessage != nil {
                    HStack(spacing: 10) {
                        Button("Try again") { Task { await model.load() } }
                            .buttonStyle(.borderedProminent)
                        Button("Open Account Settings") { openSettings() }
                            .buttonStyle(.bordered)
                    }
                }
                Spacer()
            } else {
                List(model.conversations, selection: $model.selectedID) { conversation in
                    MacConversationRow(
                        conversation: conversation,
                        currentUserID: credentials.currentUser?.id
                    )
                    .tag(conversation.id)
                }
                .listStyle(.sidebar)
            }
        }
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var conversationDetail: some View {
        if let conversation = model.selectedConversation {
            MacConversationDetail(
                conversation: conversation,
                currentUserID: credentials.currentUser?.id,
                draft: $draft,
                isSending: model.isSending,
                errorMessage: model.errorMessage,
                requiresWebInbox: model.requiresWebInbox,
                allowsSending: credentials.canPerformAccountMutations,
                onSend: { recipient in
                    let outgoing = draft
                    if await model.send(outgoing, to: recipient) { draft = "" }
                },
                onOpenWeb: openWebInbox
            )
        } else {
            ContentUnavailableView {
                Label("Choose a conversation", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Your recent SoundCloud conversations appear here.")
            } actions: {
                Button("New Message") { showsNewMessage = true }
                if model.requiresWebInbox { Button("Open web inbox") { openWebInbox() } }
            }
        }
    }

    private func consumeSharedTrack() {
        if let recipient = composer.consumeRecipient() {
            initialRecipient = recipient
            showsNewMessage = true
        }
        guard let track = composer.consumeSharedTrack() else { return }
        let link = track.permalinkURL.absoluteString
        if !draft.isEmpty, !draft.hasSuffix("\n") { draft += "\n" }
        draft += link
        if model.selectedConversation == nil { showsNewMessage = true }
    }

    private func openWebInbox() {
        NSWorkspace.shared.open(SoundCloudAPI.webInboxURL)
    }
}

private struct MacConversationRow: View {
    let conversation: SoundCloudConversation
    let currentUserID: String?

    private var counterpart: SoundCloudMessageParticipant? {
        conversation.participants.first(where: { $0.id != currentUserID })
            ?? conversation.participants.first
    }

    var body: some View {
        HStack(spacing: 10) {
            MacMessageAvatar(user: counterpart, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(counterpart?.username ?? "Conversation")
                        .font(.system(size: 13, weight: conversation.unreadCount > 0 ? .bold : .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if conversation.unreadCount > 0 {
                        Text("\(conversation.unreadCount)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.scAccent, in: Capsule())
                    }
                }
                Text(conversation.latestMessage?.body ?? "No preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct MacConversationDetail: View {
    let conversation: SoundCloudConversation
    let currentUserID: String?
    @Binding var draft: String
    let isSending: Bool
    let errorMessage: String?
    let requiresWebInbox: Bool
    let allowsSending: Bool
    let onSend: (SoundCloudMessageParticipant) async -> Void
    let onOpenWeb: () -> Void

    private var counterpart: SoundCloudMessageParticipant? {
        conversation.participants.first(where: { $0.id != currentUserID })
            ?? conversation.participants.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                MacMessageAvatar(user: counterpart, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(counterpart?.username ?? "Conversation").font(.headline)
                    if let profileURL = counterpart?.profileURL {
                        Link("View profile on SoundCloud", destination: profileURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Open web inbox", action: onOpenWeb)
                    .buttonStyle(.borderless)
            }
            .padding(14)
            .background(.thinMaterial)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(conversation.messages) { message in
                            MacMessageBubble(
                                message: message,
                                isOutgoing: message.sender?.id == currentUserID
                            )
                            .id(message.id)
                        }
                    }
                    .padding(18)
                }
                .onAppear {
                    if let last = conversation.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: conversation.messages.count) { _, _ in
                    if let last = conversation.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            if let errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(errorMessage)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer()
                    if requiresWebInbox { Button("Continue on web", action: onOpenWeb) }
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.08))
            }

            Divider()

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .onSubmit { send() }
                    .disabled(!allowsSending)
                Button(action: send) {
                    if isSending {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .frame(width: 34, height: 34)
                .background(Color.scAccent, in: Circle())
                .disabled(!allowsSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending || counterpart == nil)
            }
            .padding(14)
            .background(.ultraThinMaterial)
        }
    }

    private func send() {
        guard let counterpart else { return }
        Task { await onSend(counterpart) }
    }
}

private struct MacMessageBubble: View {
    let message: SoundCloudDirectMessage
    let isOutgoing: Bool

    var body: some View {
        HStack {
            if isOutgoing { Spacer(minLength: 24) }
            VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 4) {
                Text(message.body)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .foregroundStyle(isOutgoing ? .white : .primary)
                    .background(
                        isOutgoing ? Color.scAccent : Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                    )
                if message.createdAt != .distantPast {
                    Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if !isOutgoing { Spacer(minLength: 24) }
        }
    }
}

private struct MacMessageAvatar: View {
    let user: SoundCloudMessageParticipant?
    let size: CGFloat

    var body: some View {
        AsyncImage(url: user?.avatarURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "person.fill")
                .resizable()
                .scaledToFit()
                .padding(size * 0.24)
                .foregroundStyle(.secondary)
                .background(Color.secondary.opacity(0.12))
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

private struct MacNewMessageSheet: View {
    @ObservedObject var model: MacMessagesModel
    let initialDraft: String
    let initialRecipient: User?
    let onDone: () -> Void

    @State private var query = ""
    @State private var recipient: User?
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("New Message").font(.title2.bold())
                Spacer()
                Button("Cancel", action: onDone).buttonStyle(.borderless)
            }

            if let recipient {
                HStack(spacing: 10) {
                    ArtworkThumbnail(
                        url: recipient.avatarURL,
                        identity: recipient.username,
                        size: 38,
                        cornerRadius: 19,
                        isAvailable: true,
                        crownUser: recipient,
                        crownContext: recipient.username
                    )
                    Text(recipient.username).font(.headline)
                    Spacer()
                    Button("Change") { self.recipient = nil }
                        .buttonStyle(.borderless)
                }
            } else {
                TextField("Find an artist or listener", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: query) { _, value in model.searchUsers(value) }

                if model.isSearchingUsers { ProgressView().controlSize(.small) }

                List(model.userResults) { user in
                    Button {
                        recipient = user
                    } label: {
                        HStack(spacing: 10) {
                            ArtworkThumbnail(
                                url: user.avatarURL,
                                identity: user.username,
                                size: 34,
                                cornerRadius: 17,
                                isAvailable: true,
                                crownUser: user,
                                crownContext: user.username
                            )
                            VStack(alignment: .leading, spacing: 1) {
                                Text(user.username).foregroundStyle(.primary)
                                Text("@\(user.permalink)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }

            TextField("Message…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(4...10)

            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange)
            }

            HStack {
                if model.requiresWebInbox {
                    Button("Continue on SoundCloud") {
                        NSWorkspace.shared.open(SoundCloudAPI.webInboxURL)
                    }
                }
                Spacer()
                Button("Send") {
                    guard let recipient else { return }
                    Task {
                        if await model.startConversation(draft, with: recipient) { onDone() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(recipient == nil || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSending)
            }
        }
        .padding(20)
        .frame(width: 520, height: 560)
        .onAppear {
            draft = initialDraft
            recipient = initialRecipient
        }
    }
}
