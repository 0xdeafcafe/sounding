import Combine
import SwiftUI
import TipKit
import UIKit

enum PhoneChrome {
    static let floatingClearance: CGFloat = 60
}

struct PhoneSettingsView: View {
    @EnvironmentObject private var client: CompanionClient
    @EnvironmentObject private var linkOffers: LinkOfferBrowser
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var subscription = SubscriptionService.shared
    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var localMusic = LocalMusicLibrary.shared
    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @ObservedObject private var activityPoller = SoundCloudActivityPoller.shared
    @ObservedObject private var scout = ScoutMonitor.shared
    @ObservedObject private var homeLighting = HomeLightingDirector.shared
    @ObservedObject private var wakeAlarms = WakeAlarmStore.shared
    @Environment(\.scenePhase) private var scenePhase

    var selection: Binding<SettingsDeepLink?>?

    @State private var debugDeepLink: SettingsDeepLink? = SettingsDeepLink.fromEnvironment

    init(selection: Binding<SettingsDeepLink?>? = nil) {
        self.selection = selection
        if selection != nil {
            _debugDeepLink = State(initialValue: nil)
        }
    }

    var body: some View {
        categoryList
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(selection == nil ? .large : .inline)
            .navigationDestination(item: $debugDeepLink) { link in
                SettingsDeepLink.destination(for: link)
            }
            .task {
                await credentials.prepareStoreAtLaunch()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                credentials.refreshFromStore()
            }
    }

    @ViewBuilder
    private var categoryList: some View {
        if let selection {
            List {
                Section {
                    SettingsSidebarAccountRow(selection: selection, isUrgent: accountIsUrgent)
                }
                categories
            }
            .listStyle(.sidebar)
            .environment(\.settingsCategorySelection, selection)
        } else {
            List { categories }
                .listStyle(.insetGrouped)
        }
    }

    @ViewBuilder
    private var categories: some View {
        Section {
            if selection == nil {
                CategoryLink(
                    link: .account,
                    icon: .account,
                    title: "Account", summary: accountSummary,
                    isUrgent: accountIsUrgent
                ) { AccountSettingsDetail() }
            }

            CategoryLink(
                link: .subscription,
                icon: .subscription,
                title: "Subscription", summary: subscriptionSummary,
                isUrgent: subscriptionIsUrgent
            ) { SubscriptionSettingsDetail() }

            CategoryLink(
                link: .activity,
                icon: .activity,
                title: "Activity",
                summary: activitySummary
            ) { PhoneActivityInboxView() }

            CategoryLink(
                link: .scout,
                icon: .scout,
                title: "Scout", summary: scoutSummary
            ) { ScoutSettingsView() }

            CategoryLink(
                link: .messages,
                icon: .messages,
                title: "Messages", summary: "SoundCloud inbox"
            ) { PhoneMessagesView() }
        } footer: {
            if credentials.needsSignIn, selection == nil {
                Text("Sign in to access account settings.")
            }
        }

        Section {
            CategoryLink(
                link: .playback,
                icon: .playback,
                title: "Playback", summary: playbackSummary
            ) { PlaybackSettingsDetail() }

            CategoryLink(
                link: .alarms,
                icon: .alarms,
                title: "Alarms", summary: wakeAlarms.summary
            ) { WakeAlarmsView() }

            CategoryLink(
                link: .analysis,
                icon: .analysis,
                title: "Music Analysis", summary: store.analyseMusicOnDevice ? "On" : "Off"
            ) { MusicAnalysisSettingsDetail() }
        }

        Section {
            CategoryLink(
                link: .devices,
                icon: .devices,
                title: "Devices", summary: devicesSummary
            ) { PhoneDevicesView() }
            .popoverTip(client.state == .unlinked ? LinkAppleTVTip() : nil, arrowEdge: .top)

            CategoryLink(
                link: .homeLighting,
                icon: .homeLighting,
                title: "Home Lighting", summary: homeLighting.summary
            ) { HomeLightingSettingsView().settingsDetailChrome("Home Lighting") }
        }

        Section {
            CategoryLink(
                link: .downloads,
                icon: .downloads,
                title: "Downloads", summary: downloadsSummary
            ) { DownloadsSettingsDetail() }

            CategoryLink(
                link: .musicFolders,
                icon: .musicFolders,
                title: "Music Folders", summary: LocalMusicFormat.folderSummary(localMusic)
            ) { MusicFoldersSettingsView() }

            CategoryLink(
                link: .library,
                icon: .library,
                title: "Library", summary: ""
            ) { LibrarySettingsDetail() }

            CategoryLink(
                link: .about,
                icon: .about,
                title: "About & Advanced",
                summary: "\(currentAppVersion()) (\(currentAppBuild()))"
            ) { AboutAdvancedSettingsDetail() }
        }
    }

    private var scoutSummary: String {
        guard scout.isEnabled else { return "Off" }
        let count = scout.artists.filter(\.isEnabled).count
        return count == 0 ? "On" : "\(count) \(count == 1 ? "artist" : "artists")"
    }

    private var accountSummary: String {
        switch credentials.accountStatus {
        case .needsReconnect:
            return "Needs Sign-In"
        case .signedOut:
            return "Please Sign In"
        case .signedIn:
            if let user = credentials.currentUser { return "@\(user.username)" }
            return "Signed In"
        }
    }

    private var accountIsUrgent: Bool { credentials.isSessionRejected }

    private var subscriptionSummary: String {
        guard !credentials.sessionHealth.needsSignIn else { return "Sign In Required" }
        guard subscription.authenticatedAccountID != nil else { return "Checking…" }
        if downloads.scheduledDeletionDate != nil { return "Downloads at risk" }
        return subscription.tier.displayName
    }

    private var subscriptionIsUrgent: Bool {
        downloads.scheduledDeletionDate != nil
    }

    private var playbackSummary: String { store.streamingQualityCeiling.displayName }

    private var activitySummary: String {
        if credentials.isSignedOut || credentials.isSessionRejected { return "Sign In Required" }
        return activityPoller.unreadCount == 0 ? "No unread" : "\(activityPoller.unreadCount) unread"
    }

    private var downloadsSummary: String {
        downloads.entries.isEmpty
            ? "None"
            : byteString(downloads.usedBytes)
    }

    private var devicesSummary: String {
        let state = AppleTVDebugStory.forcedState ?? client.state
        if state == .unlinked {
            return linkOffers.offer != nil ? "Apple TV Found" : "None"
        }
        let needsSignIn = PeerSignInPrompt.resolveOnPhone(client: client, offers: linkOffers.offers) != nil
        if client.links.count > 1, !needsSignIn {
            return "\(client.links.count) Apple TVs"
        }
        return deviceStatusText(state, needsSignIn: needsSignIn)
    }
}

private struct SettingsCategorySelectionKey: EnvironmentKey {
    static let defaultValue: Binding<SettingsDeepLink?>? = nil
}

private extension EnvironmentValues {
    var settingsCategorySelection: Binding<SettingsDeepLink?>? {
        get { self[SettingsCategorySelectionKey.self] }
        set { self[SettingsCategorySelectionKey.self] = newValue }
    }
}

struct PadSettingsSplitView: View {
    let nowPlaying: PadNowPlaying

    @State private var selection: SettingsDeepLink? = SettingsDeepLink.fromEnvironment ?? .account
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if horizontalSizeClass == .compact {
            NavigationStack { PhoneSettingsView() }
        } else {
            NavigationSplitView {
                PhoneSettingsView(selection: $selection)
                    .toolbar(removing: .sidebarToggle)
                    .navigationSplitViewColumnWidth(
                        min: dynamicTypeSize.isAccessibilitySize ? 400 : 300,
                        ideal: dynamicTypeSize.isAccessibilitySize ? 480 : 340,
                        max: dynamicTypeSize.isAccessibilitySize ? 560 : 420
                    )
            } detail: {
                NavigationStack {
                    if let selection {
                        SettingsDeepLink.destination(for: selection)
                            .id(selection)
                    } else {
                        ContentUnavailableView("Settings", systemImage: "gearshape")
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { miniPlayer }
            }
            .ignoresSafeArea(.container, edges: .top)
        }
    }
}

private extension PadSettingsSplitView {
    @ViewBuilder
    var miniPlayer: some View {
        if nowPlaying.isVisible {
            TransportBarView(
                isExpanded: nowPlaying.isExpanded,
                heroID: nowPlaying.heroID,
                heroNamespace: nowPlaying.namespace
            )
            .upNextTrackDropTarget()
            .glassEffect(.regular, in: .capsule)
            .padding(.horizontal, Space.tight)
            .padding(.bottom, Space.tight)
        }
    }
}

private struct SettingsSidebarLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.icon
            configuration.title
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

private struct SettingsSidebarRowModifier: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 2)
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            .listRowSeparator(.hidden)
            .listRowBackground(
                Capsule()
                    .fill(isSelected ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.clear))
                    .padding(.horizontal, 4)
            )
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private extension View {
    func settingsSidebarRow(isSelected: Bool) -> some View {
        modifier(SettingsSidebarRowModifier(isSelected: isSelected))
    }
}

private struct SettingsSidebarAccountRow: View {
    let selection: Binding<SettingsDeepLink?>
    let isUrgent: Bool

    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @ObservedObject private var subscription = SubscriptionService.shared

    private var isSelected: Bool { selection.wrappedValue == .account }

    private var user: User? {
        #if DEBUG
        if VisualFixtures.isEnabled { return VisualFixtures.currentUser }
        #endif
        return credentials.isSignedOut ? nil : credentials.currentUser
    }

    var body: some View {
        Button {
            selection.wrappedValue = .account
        } label: {
            HStack(spacing: 12) {
                avatar
                VStack(alignment: .leading, spacing: 2) {
                    Text(user?.displayName ?? (credentials.isSignedOut ? "Sign In" : "SoundCloud"))
                        .font(.headline)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .foregroundStyle(isSelected ? Color.scAccent : Color.primary)
                Spacer(minLength: 0)
                if isUrgent {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .accessibilityLabel("Needs attention")
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .settingsSidebarRow(isSelected: isSelected)
    }

    private var subtitle: String {
        if credentials.isSessionRejected { return "Needs Sign-In" }
        if let user {
            guard subscription.authenticatedAccountID != nil, let plan = subscription.tier.planName else { return "@\(user.username)" }
            return "@\(user.username) \u{00B7} \(plan)"
        }
        return credentials.isSignedOut ? "SoundCloud Account" : "Signed In"
    }

    @ViewBuilder
    private var avatar: some View {
        if let user {
            ArtworkThumbnail(
                url: user.avatarURL,
                systemImage: "person.fill",
                isCircle: true,
                size: 48,
                identity: user.id
            )
            .accessibilityHidden(true)
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
        }
    }
}

private struct CategoryLink<Destination: View>: View {
    let link: SettingsDeepLink
    let icon: SettingsIcon
    let title: String
    let summary: String
    var isUrgent: Bool = false
    @ViewBuilder let destination: () -> Destination

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.settingsCategorySelection) private var selection

    private var usesSelection: Bool { selection != nil }
    private var isSelected: Bool { selection?.wrappedValue == link }

    var body: some View {
        if let selection {
            Button {
                selection.wrappedValue = link
            } label: {
                label
                    .foregroundStyle(isSelected ? Color.scAccent : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .settingsSidebarRow(isSelected: isSelected)
        } else {
            NavigationLink {
                destination()
            } label: {
                label
            }
        }
    }

    @ViewBuilder
    private var label: some View {
        if usesSelection {
            HStack(spacing: 8) {
                SettingsIconLabel(title, icon: icon)
                    .labelStyle(SettingsSidebarLabelStyle())
                Spacer(minLength: 0)
                if isUrgent {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .accessibilityLabel("Needs attention")
                }
            }
        } else if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                SettingsIconLabel(title, icon: icon)
                summaryView
            }
        } else {
            LabeledContent {
                summaryView
            } label: {
                SettingsIconLabel(title, icon: icon)
            }
        }
    }

    private var summaryView: some View {
        HStack(spacing: 4) {
            if isUrgent {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Needs attention")
            }
            Text(summary)
                .foregroundStyle(isUrgent ? .red : .secondary)
                .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
        }
    }
}

struct PhoneActivityInboxView: View {
    @ObservedObject private var poller = SoundCloudActivityPoller.shared
    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @Environment(\.openURL) private var openURL
    @State private var isShowingSignIn = false

    var body: some View {
        Group {
            if credentials.isSignedOut || credentials.isSessionRejected {
                SCEmptyState(
                    icon: "person.crop.circle.badge.exclamationmark",
                    title: "Sign In to See Activity",
                    message: "Sign in to see new followers, messages and Following activity.",
                    actionTitle: "Sign In",
                    action: { isShowingSignIn = true },
                    style: .phone
                )
            } else if poller.inbox.isEmpty {
                ContentUnavailableView(
                    "No New Activity",
                    systemImage: "bell",
                    description: Text("New followers, messages and Following activity appear here.")
                )
            } else {
                List {
                    ForEach(poller.inbox) { event in
                        Button {
                            poller.markRead(id: event.id)
                            if let destination = event.destination { openURL(destination) }
                        } label: {
                            activityRow(event)
                        }
                        .foregroundStyle(.primary)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isShowingSignIn) {
            NavigationStack {
                SoundCloudLoginView.standalone {
                    isShowingSignIn = false
                    credentials.refreshFromStore()
                }
            }
        }
        .toolbar {
            if poller.unreadCount > 0 {
                Button("Mark All Read") { poller.markAllRead() }
            }
        }
    }

    private func activityRow(_ event: SoundCloudInboxEvent) -> some View {
        let isUnread = event.readAt == nil
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol(for: event.kind))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if isUnread {
                        Circle()
                            .fill(.tint)
                            .frame(width: 8, height: 8)
                    }
                    Text(event.title)
                        .font(.subheadline.weight(isUnread ? .bold : .regular))
                }
                Text(event.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Text(event.date, style: .relative)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isUnread ? "Unread" : "Read")
    }

    private func symbol(for kind: SoundCloudInboxEvent.Kind) -> String {
        switch kind {
        case .feed: return "waveform"
        case .follower: return "person.badge.plus"
        case .message: return "envelope"
        }
    }
}

private struct PhoneMessagesView: View {
    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @StateObject private var model = PhoneMessagesModel()
    @State private var isShowingSignIn = false

    var body: some View {
        Group {
            if needsSignIn {
                SCEmptyState(
                    icon: "bubble.left.and.bubble.right",
                    title: "Sign In to See Messages",
                    message: "Sign in to read and reply to your SoundCloud messages.",
                    actionTitle: "Sign In",
                    action: { isShowingSignIn = true },
                    style: .phone
                )
            } else if model.isLoading, model.conversations.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.conversations.isEmpty {
                ContentUnavailableView {
                    Label(model.errorMessage == nil ? "No Messages Yet" : "Messages Unavailable", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text(model.errorMessage ?? "Conversations from SoundCloud appear here.")
                } actions: {
                    if model.errorMessage != nil {
                        Button("Try Again") { Task { await model.load() } }
                            .buttonStyle(.bordered)
                    }
                    Link("Open SoundCloud Inbox", destination: SoundCloudAPI.webInboxURL)
                }
            } else {
                List(model.conversations) { conversation in
                    NavigationLink {
                        PhoneConversationView(
                            initialConversation: conversation,
                            currentUserID: currentUserID
                        )
                    } label: {
                        PhoneConversationRow(
                            conversation: conversation,
                            currentUserID: currentUserID
                        )
                    }
                }
                .listStyle(.plain)
                .refreshable { await model.load() }
            }
        }
        .navigationTitle("Messages")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: credentials.currentUser?.id) { await model.load() }
        .sheet(isPresented: $isShowingSignIn) {
            NavigationStack {
                SoundCloudLoginView.standalone {
                    isShowingSignIn = false
                    credentials.refreshFromStore()
                    Task { await model.load() }
                }
            }
        }
    }

    private var currentUserID: String? {
        #if DEBUG
        if VisualFixtures.isEnabled { return VisualFixtures.currentUser.id }
        #endif
        return credentials.currentUser?.id
    }

    private var needsSignIn: Bool {
        #if DEBUG
        if VisualFixtures.isEnabled { return false }
        #endif
        return credentials.isSignedOut || credentials.isSessionRejected
    }
}

private struct PhoneConversationRow: View {
    let conversation: SoundCloudConversation
    let currentUserID: String?

    private var counterpart: SoundCloudMessageParticipant? {
        conversation.participants.first(where: { $0.id != currentUserID })
            ?? conversation.participants.first
    }

    var body: some View {
        HStack(spacing: 12) {
            ArtworkThumbnail(
                url: counterpart?.avatarURL,
                systemImage: "person.fill",
                isCircle: true,
                size: 46,
                identity: counterpart?.id
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(counterpart?.username ?? "Conversation")
                    .font(.body.weight(conversation.unreadCount > 0 ? .semibold : .regular))
                    .lineLimit(1)
                Text(conversation.latestMessage?.body ?? "No preview")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if conversation.unreadCount > 0 {
                Text("\(conversation.unreadCount)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.tint, in: Capsule())
                    .accessibilityLabel("\(conversation.unreadCount) unread")
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PhoneConversationView: View {
    @State private var conversation: SoundCloudConversation
    let currentUserID: String?

    @State private var draft = ""
    @State private var isLoading = false
    @State private var isSending = false
    @State private var errorMessage: String?

    init(initialConversation: SoundCloudConversation, currentUserID: String?) {
        _conversation = State(initialValue: initialConversation)
        self.currentUserID = currentUserID
    }

    private var counterpart: SoundCloudMessageParticipant? {
        conversation.participants.first(where: { $0.id != currentUserID })
            ?? conversation.participants.first
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(conversation.messages) { message in
                            messageBubble(message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onAppear { scrollToBottom(proxy) }
                .onChange(of: conversation.messages.count) { _, _ in
                    withAnimation { scrollToBottom(proxy) }
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                Button { Task { await send() } } label: {
                    if isSending {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.body.weight(.semibold))
                    }
                }
                .frame(width: 44, height: 44)
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Send")
                .disabled(isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || counterpart == nil)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .navigationTitle(counterpart?.username ?? "Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if isLoading { ProgressView().controlSize(.large) }
        }
        .task { await loadThread() }
        .toolbar {
            if let profileURL = counterpart?.profileURL {
                Link(destination: profileURL) { Image(systemName: "person.crop.circle") }
                    .accessibilityLabel("View profile on SoundCloud")
            }
        }
    }

    @ViewBuilder
    private func messageBubble(_ message: SoundCloudDirectMessage) -> some View {
        let outgoing = message.sender?.id == currentUserID
        HStack {
            if outgoing { Spacer(minLength: 44) }
            VStack(alignment: outgoing ? .trailing : .leading, spacing: 4) {
                Text(message.body)
                    .font(.body)
                    .foregroundStyle(outgoing ? .white : .primary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(
                        outgoing ? Color.scAccent : Color(uiColor: .secondarySystemFill),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                if message.createdAt != .distantPast {
                    Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if !outgoing { Spacer(minLength: 44) }
        }
    }

    private func loadThread() async {
        #if DEBUG
        if VisualFixtures.isEnabled { return }
        #endif
        isLoading = conversation.messages.count <= 1
        defer { isLoading = false }
        do {
            conversation = try await SoundCloudAPI.shared.getConversation(id: conversation.id)
            errorMessage = nil
        } catch SoundCloudMessagingError.unavailable {
            errorMessage = SoundCloudMessagingError.unavailable.localizedDescription
        } catch {
            if conversation.messages.isEmpty { errorMessage = LoadFailure.classify(error).message(subject: "this conversation") }
        }
    }

    private func send() async {
        guard let counterpart else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do {
            if let updated = try await SoundCloudAPI.shared.sendDirectMessage(
                text,
                to: counterpart.id,
                conversationID: conversation.id
            ) {
                conversation = updated
            } else {
                conversation = try await SoundCloudAPI.shared.getConversation(id: conversation.id)
            }
            draft = ""
        } catch {
            errorMessage = LoadFailure.classify(error).title
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard let last = conversation.messages.last else { return }
        proxy.scrollTo(last.id, anchor: .bottom)
    }
}

@MainActor
private final class PhoneMessagesModel: ObservableObject {
    @Published private(set) var conversations: [SoundCloudConversation] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    func load() async {
        #if DEBUG
        if VisualFixtures.isEnabled {
            conversations = Self.fixtureConversations
            errorMessage = nil
            return
        }
        #endif
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            conversations = try await SoundCloudAPI.shared.getConversations(limit: 50).collection.sorted {
                ($0.latestMessage?.createdAt ?? $0.lastUpdatedAt ?? .distantPast)
                    > ($1.latestMessage?.createdAt ?? $1.lastUpdatedAt ?? .distantPast)
            }
        } catch {
            errorMessage = LoadFailure.classify(error).message(subject: "your messages")
        }
    }

    #if DEBUG
    private static let fixtureConversations: [SoundCloudConversation] = {
        let data = Data("""
        [{
          "id":"fixture-thread-1",
          "participants":[
            {"id":"900","username":"Sounding Listener","permalink":"sounding-listener"},
            {"id":"102","username":"Maya Sol","permalink":"maya-sol"}
          ],
          "messages":[
            {"id":"m1","body":"Loved the cue you saved in Neon Weather.","created_at":"2026-08-09T11:12:00Z","sender":{"id":"102","username":"Maya Sol"}},
            {"id":"m2","body":"Thank you — that transition is brilliant.","created_at":"2026-08-09T11:18:00Z","sender":{"id":"900","username":"Sounding Listener"}}
          ],
          "unread_count":1,
          "last_updated_at":"2026-08-09T11:18:00Z"
        }]
        """.utf8)
        return (try? JSONDecoder().decode([SoundCloudConversation].self, from: data)) ?? []
    }()
    #endif
}

private func verificationDisplay(_ verification: SubscriptionService.VerificationStatus) -> String {
    switch verification {
    case .verified: return "Verified"
    case .unverifiable: return "Unverified"
    case .verifiedNotSubscribed: return "Not Subscribed"
    }
}

private func verificationTint(_ verification: SubscriptionService.VerificationStatus) -> Color {
    switch verification {
    case .verified: return .green
    case .unverifiable(let withinGrace): return withinGrace ? .orange : .secondary
    case .verifiedNotSubscribed: return .red
    }
}

private func currentAppVersion() -> String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
}

private func currentAppBuild() -> String {
    Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
}

private func byteString(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useGB, .useMB]
    return formatter.string(fromByteCount: bytes)
}

private func formatSeconds(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let minutes = total / 60
    let remainder = total % 60
    if minutes == 0 { return "\(remainder)s" }
    if remainder == 0 { return "\(minutes)m" }
    return "\(minutes)m \(remainder)s"
}

private extension View {
    func settingsDetailChrome(_ title: String) -> some View {
        self
            .listStyle(.insetGrouped)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

enum SettingsDebugFlags {
    static var opensSignOut: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["SOUNDING_TV_OPEN_SIGN_OUT"]
        #else
        nil
        #endif
    }
}

enum SettingsDeepLink: String, Identifiable, Hashable {
    case account, subscription, activity, scout, messages, playback, alarms, downloads, musicFolders, library, analysis, devices, homeLighting, about, yourMoves, networkActivity

    var id: String { rawValue }

    @MainActor @ViewBuilder
    static func destination(for link: SettingsDeepLink) -> some View {
        switch link {
        case .account:      AccountSettingsDetail()
        case .subscription: SubscriptionSettingsDetail()
        case .activity:     PhoneActivityInboxView()
        case .scout:        ScoutSettingsView()
        case .messages:     PhoneMessagesView()
        case .playback:     PlaybackSettingsDetail()
        case .alarms:       WakeAlarmsView()
        case .downloads:    DownloadsSettingsDetail()
        case .musicFolders: MusicFoldersSettingsView()
        case .library:      LibrarySettingsDetail()
        case .analysis:     MusicAnalysisSettingsDetail()
        case .devices:      PhoneDevicesView()
        case .homeLighting: HomeLightingSettingsView().settingsDetailChrome("Home Lighting")
        case .about:        AboutAdvancedSettingsDetail()
        case .yourMoves:    AutoMixMovesView().settingsDetailChrome("Your Moves")
        case .networkActivity: NetworkActivityView()
        }
    }

    static var fromEnvironment: SettingsDeepLink? {
        #if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["SOUNDING_TV_PHONE_SETTINGS"] else {
            return nil
        }
        if raw == "networkActivity", NetworkActivityFixture.isRequested { NetworkActivityFixture.seed() }
        return SettingsDeepLink(rawValue: raw)
        #else
        return nil
        #endif
    }
}

struct AccountSettingsDetail: View {
    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @ObservedObject private var subscription = SubscriptionService.shared
    @EnvironmentObject private var client: CompanionClient
    @Environment(\.scenePhase) private var scenePhase

    @State private var isSigningOut = false
    @State private var isRetrying = false
    @State private var showingSignOutConfirmation = SettingsDebugFlags.opensSignOut == "here"
    @State private var showingSignOutEverywhereConfirmation = SettingsDebugFlags.opensSignOut == "everywhere"
    @State private var isShowingSignIn = false

    var body: some View {
        List {
            switch credentials.accountStatus {
            case .signedIn:
                profileSection
                signOutSection
            case .needsReconnect:
                rejectedSection(rejectionKind)
                signOutSection
            case .signedOut:
                signInSection
            }
            soundCloudManagementSection
        }
        .sheet(isPresented: $isShowingSignIn) { signInSheet }
        .settingsDetailChrome("Account")
        .task {
            await credentials.prepareStoreAtLaunch()
            await credentials.revalidate()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            credentials.refreshFromStore()
            Task { await credentials.revalidate() }
        }

    }

    private func profileSubtitle(_ user: User) -> String {
        guard subscription.authenticatedAccountID != nil, let plan = subscription.tier.planName else { return "@\(user.username)" }
        return "@\(user.username) \u{00B7} \(plan)"
    }

    private var profileSection: some View {
        Section {
            if let user = credentials.currentUser {
                NavigationLink {
                    ProfileView()
                } label: {
                    HStack(spacing: 12) {
                        ArtworkThumbnail(
                            url: user.avatarURL,
                            systemImage: "person.fill",
                            isCircle: true,
                            size: 56,
                            identity: user.id,
                            crownUser: user,
                            crownContext: user.displayName
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.displayName).font(.headline)
                            Text(profileSubtitle(user))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .accessibilityHint("Shows your profile")
            } else {
                LabeledContent("SoundCloud", value: statusText)
            }
        }
    }

    private var rejectionKind: SoundCloudCredentialSource.RejectionKind {
        if case .rejected(let kind) = credentials.sessionHealth { return kind }
        return .accountRejected
    }

    private var statusText: String {
        switch credentials.accountStatus {
        case .signedIn: return "Signed In"
        case .needsReconnect: return "Not Working"
        case .signedOut: return "Please Sign In"
        }
    }

    private var signOutSection: some View {
        Section {
            Button("Sign Out", role: .destructive) {
                showingSignOutConfirmation = true
            }
            .disabled(isSigningOut)
            .confirmationDialog("Sign Out of SoundCloud?", isPresented: $showingSignOutConfirmation, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) { signOut() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(AccountSignOut.stayingSignedInMessage(client: client) ?? "Only this \(DeviceClass.current.displayName) signs out.")
            }
            Button("Sign Out of All Devices", role: .destructive) {
                showingSignOutEverywhereConfirmation = true
            }
            .disabled(isSigningOut)
            .confirmationDialog("Sign Out of All Devices?", isPresented: $showingSignOutEverywhereConfirmation, titleVisibility: .visible) {
                Button("Sign Out of All Devices", role: .destructive) { signOutEverywhere() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(AccountSignOut.everywhereMessage(client: client))
            }
        }
    }

    private var soundCloudManagementSection: some View {
        Section {
            soundCloudSettingsLink(
                "Security, 2FA & Access",
                systemImage: "lock.shield",
                destination: SoundCloudAccountPages.account
            )
            soundCloudSettingsLink(
                "Notifications",
                systemImage: "bell",
                destination: SoundCloudAccountPages.notifications
            )
            soundCloudSettingsLink(
                "Privacy",
                systemImage: "hand.raised",
                destination: SoundCloudAccountPages.privacy
            )
            soundCloudSettingsLink(
                "Communications",
                systemImage: "envelope",
                destination: SoundCloudAccountPages.communications
            )
            soundCloudSettingsLink(
                "Analytics Preferences",
                systemImage: "chart.bar",
                destination: SoundCloudAccountPages.analytics
            )
            soundCloudSettingsLink(
                "Advertising Preferences",
                systemImage: "rectangle.and.hand.point.up.left",
                destination: SoundCloudAccountPages.advertising
            )
        } header: {
            Text("SoundCloud Account")
        } footer: {
            Text("Opens soundcloud.com.")
        }
    }

    private func soundCloudSettingsLink(
        _ title: String,
        systemImage: String,
        destination: URL
    ) -> some View {
        Link(destination: destination) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func rejectedSection(_ kind: SoundCloudCredentialSource.RejectionKind) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Label("Sign-In Not Working", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .symbolRenderingMode(.multicolor)
                Text(rejectionExplanation(kind))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)

            if kind == .refreshUnreachable {
                Button(isRetrying ? "Trying Again…" : "Try Again") { retry() }
                    .disabled(isRetrying)
            } else {
                Button("Reconnect SoundCloud") { isShowingSignIn = true }
            }
        }
    }

    private func rejectionExplanation(_ kind: SoundCloudCredentialSource.RejectionKind) -> String {
        switch kind {
        case .accountRejected:
            return "Sign in again to reconnect your account."
        case .noRefreshCapability:
            return "Sign in again to keep using your account."
        case .refreshUnreachable:
            return "SoundCloud couldn't be reached. Try again."
        }
    }

    private var signInSection: some View {
        Section {
            Button("Sign In to SoundCloud") { isShowingSignIn = true }
        } footer: {
            Text(signInFooter)
        }
    }

    private var signInFooter: String {
        switch credentials.lastSignOutReason {
        case .accountRejected, .noRefreshCapability:
            return "Sign in again to reconnect your account."
        case nil:
            return "Sign in to save, follow, message and download."
        }
    }

    private var signInSheet: some View {
        NavigationStack {
            SoundCloudLoginView.standalone {
                isShowingSignIn = false
            }
        }
    }

    private func signOut() {
        guard !isSigningOut else { return }
        isSigningOut = true
        Task {
            await AccountSignOut.signOutThisDevice(client: client, credentials: credentials)
            isSigningOut = false
        }
    }

    private func signOutEverywhere() {
        guard !isSigningOut else { return }
        isSigningOut = true
        Task {
            await AccountSignOut.signOutEverywhere(client: client, credentials: credentials)
            isSigningOut = false
        }
    }

    private func retry() {
        guard !isRetrying else { return }
        isRetrying = true
        Task {
            await credentials.revalidate()
            isRetrying = false
        }
    }
}

private struct SubscriptionSettingsDetail: View {
    @ObservedObject private var subscription = SubscriptionService.shared
    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var isChecking = false

    var body: some View {
        List {
            Section {
                LabeledContent("Plan", value: planDisplay)
                LabeledContent {
                    Text(statusDisplay)
                        .foregroundStyle(hasAccountContext
                            ? verificationTint(subscription.verification)
                            : .secondary)
                } label: {
                    Text("Status")
                }
            } footer: {
                Text(isSignedOut ? "Sign in to check your plan." : subscription.statusDescription)
            }

            Section {
                Button {
                    check()
                } label: {
                    HStack {
                        Text(isChecking ? "Checking…" : "Check Again")
                        if isChecking {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isChecking || isSignedOut)

                Link(destination: SoundCloudAccountPages.subscriptions) {
                    HStack {
                        Label("Manage on SoundCloud", systemImage: "safari")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Billing and cancellation are managed on SoundCloud.")
            }

            if let deletionDate = downloads.scheduledDeletionDate {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Go+ Downloads Will Be Removed").font(.headline)
                            Text("Deleted on \(deletionDate.formatted(date: .abbreviated, time: .shortened)) unless the subscription is renewed.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }

        }
        .settingsDetailChrome("Subscription")
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, !isSignedOut else { return }
            Task { await subscription.verifyNow() }
        }
    }

    private var isSignedOut: Bool {
        credentials.sessionHealth.needsSignIn
    }

    private var hasAccountContext: Bool {
        !isSignedOut && subscription.authenticatedAccountID != nil
    }

    private var planDisplay: String {
        if isSignedOut { return "Unavailable" }
        guard hasAccountContext else { return "Checking…" }
        return subscription.tier.planName ?? subscription.tier.displayName
    }

    private var statusDisplay: String {
        if isSignedOut { return "Sign In Required" }
        guard hasAccountContext else { return "Checking…" }
        return verificationDisplay(subscription.verification)
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

@MainActor
final class PublisherFeed<Value>: ObservableObject {
    @Published private(set) var value: Value
    private var cancellable: AnyCancellable?

    init<P: Publisher>(
        initial: Value,
        publisher: P,
        isDuplicate: @escaping (Value, Value) -> Bool
    ) where P.Output == Value, P.Failure == Never {
        value = initial
        cancellable = publisher
            .removeDuplicates(by: isDuplicate)
            .sink { [weak self] next in self?.value = next }
    }
}

private struct AutoMixStatusRow: View {
    @ObservedObject private var player = PlayerService.shared

    var body: some View {
        let decision = player.automaticMixDecision
        let text: String = {
            if let countdown = decision.countdownText(currentTime: player.currentTime) {
                return "\(decision.statusLabel) \(countdown)"
            }
            return decision.statusLabel
        }()
        LabeledContent("Status", value: text)
    }
}

private struct PlaybackSettingsDetail: View {
    @ObservedObject private var store = SettingsStore.shared

    private var personalityFooter: String {
        DJProfile.profile(id: store.djDefaultProfileId)?.adventureSummary ?? "Blends one track into the next."
    }
    @StateObject private var route = PublisherFeed(
        initial: PlayerService.shared.outputRoute,
        publisher: PlayerService.shared.$outputRoute,
        isDuplicate: ==
    )

    var body: some View {
        List {
            Section {
                Picker(selection: store.streamingQualityCeilingBinding) {
                    ForEach(QualityCeiling.allCases) { level in
                        Text(qualityRowLabel(level)).tag(level)
                    }
                } label: {
                    Text("Streaming Quality")
                }
                Toggle("Allow Cellular Streaming", isOn: store.cellularStreamingAllowedBinding)
            } header: {
                Text("Streaming")
            } footer: {
                Text("Higher quality uses more data.")
            }

            Section {
                Toggle("Auto Mix", isOn: store.djAutoMixEnabledBinding)
                if store.djAutoMixEnabled {
                    Picker("Style", selection: store.djDefaultProfileIdBinding) {
                        ForEach(DJProfile.all) { profile in
                            Text(profile.styleName).tag(profile.id)
                        }
                    }
                    Picker("Blend", selection: store.djBlendBinding) {
                        ForEach(DJBlendLength.allCases) { blend in
                            Text(blend.displayName).tag(blend)
                        }
                    }
                    Toggle("Keep Queue Order", isOn: store.djKeepQueueOrderBinding)
                    NavigationLink("Your Moves") {
                        AutoMixMovesView().settingsDetailChrome("Your Moves")
                    }
                    AutoMixStatusRow()
                }
            } header: {
                Text("DJ")
            } footer: {
                Text(store.djAutoMixEnabled ? personalityFooter : "Blends one track into the next.")
            }

            if store.djAutoMixEnabled {
                AutoMixEnergySection()
            }

            Section {
                Picker("Minimum Set Length", selection: store.setMinimumDurationSecondsBinding) {
                    ForEach(GeneratedLibraryCollections.setDurationPresets, id: \.self) { duration in
                        Text(GeneratedLibraryCollections.durationLabel(duration)).tag(duration)
                    }
                }
                LibrarySyncStatusRow()
            } header: {
                Text("Library")
            } footer: {
                Text("Liked tracks at least this long appear in Sets.")
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
                Toggle("Live Activity", isOn: store.liveActivitiesEnabledBinding)
            } header: {
                Text("Lock Screen")
            } footer: {
                Text("Appears on the Lock Screen and in the Dynamic Island during Auto Mix, a mix with a tracklist or a Sleep Timer.")
            }

            Section {
                LabeledContent("Output", value: route.value.outputName ?? "Unavailable")
                LabeledContent("Channels", value: channelDescription)
                LabeledContent("Spatial Audio", value: "Stereo widened")
            } header: {
                Text("Audio")
            }
        }
        .settingsDetailChrome("Playback")
    }

    private var channelDescription: String {
        route.value.supportsMultichannel
            ? "\(route.value.maximumOutputChannels)-channel"
            : "Stereo"
    }

    private func qualityRowLabel(_ level: QualityCeiling) -> String {
        if let mb = QualitySizeEstimator.approximateMBPerHour(for: level) {
            return "\(level.displayName) (~\(Int(mb.rounded())) MB/hr)"
        }
        return level.displayName
    }
}

private struct LibrarySettingsDetail: View {
    @AppStorage(TrackColumnLayout.storageKey) private var layout = TrackColumnLayout.standard

    var body: some View {
        List {
            Section {
                NavigationLink {
                    TrackColumnsSettingsView()
                } label: {
                    LabeledContent("Columns", value: "\(layout.enabled.count) Shown")
                }
            }
        }
        .settingsDetailChrome("Library")
    }
}

private struct DownloadsSettingsDetail: View {
    @ObservedObject private var downloads = DownloadManager.shared

    @StateObject private var cache = CacheUsageModel()
    @State private var showingRedownloadConfirmation = false
    @State private var showingRemoveAllConfirmation = false

    private static let lastSectionID = "downloads-last-section"

    var body: some View {
        ScrollViewReader { proxy in
            list
                #if DEBUG
                .task {
                    guard ProcessInfo.processInfo.environment["SOUNDING_TV_PHONE_SCROLL_BOTTOM"] == "1" else { return }
                    try? await Task.sleep(for: .milliseconds(300))
                    withAnimation(nil) {
                        proxy.scrollTo(Self.lastSectionID, anchor: .bottom)
                    }
                }
                #endif
        }
    }

    private var list: some View {
        let redownload = downloads.redownloadEstimate()
        return List {
            Section {
                Gauge(value: Double(downloads.storageUsed), in: 0...Double(max(DownloadsFormat.deviceCapacityBytes, 1))) {
                    Text("\(DownloadsFormat.bytes(downloads.storageUsed)) used by downloads")
                }
                .gaugeStyle(.accessoryLinearCapacity)
                NavigationLink {
                    PhoneDownloadedMusicView()
                        .settingsDetailChrome("Downloaded Music")
                } label: {
                    LabeledContent("Downloaded Music", value: downloads.downloadedSummary)
                }
            } header: {
                Text("Storage")
            } footer: {
                if let deletionDate = downloads.scheduledDeletionDate {
                    Text("Go+ downloads are removed on \(deletionDate.formatted(date: .abbreviated, time: .omitted)) unless your subscription is renewed.")
                }
            }

            AppleWatchDownloadsSection()

            Section {
                Toggle("Download over Cellular", isOn: Binding(
                    get: { downloads.downloadOverCellular },
                    set: { downloads.setDownloadOverCellular($0) }
                ))
                Toggle("Optimise Storage", isOn: Binding(
                    get: { downloads.optimiseStorage },
                    set: { downloads.setOptimiseStorage($0) }
                ))
                if downloads.optimiseStorage {
                    Picker("Minimum Storage", selection: Binding(
                        get: { downloads.optimiseStorageMinimumBytes },
                        set: { downloads.setOptimiseStorageMinimumBytes($0) }
                    )) {
                        ForEach(OptimiseStoragePolicy.minimumChoices, id: \.self) { bytes in
                            Text(DownloadsFormat.minimumStorage(bytes)).tag(bytes)
                        }
                    }
                }
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
                    Button("Re-download at New Quality (≈ \(redownload.sizeLabel))") {
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
                    Button("Remove All Downloads", role: .destructive) {
                        showingRemoveAllConfirmation = true
                    }
                }
                .id(Self.lastSectionID)
            }
        }
        .settingsDetailChrome("Downloads")
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
            Text("Every download is deleted from this \(DeviceClass.current.displayName).")
        }
    }
}

private struct MusicAnalysisSettingsDetail: View {
    @ObservedObject private var store = SettingsStore.shared
    @AppStorage(GeneratedInsightsService.visibilityKey) private var showsGeneratedInsights = true

    @State private var storageUsedBytes: Int64?
    @State private var showingClearConfirmation = false

    var body: some View {
        List {
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
            }

            Section {
                Button("Clear Analysis Data", role: .destructive) {
                    showingClearConfirmation = true
                }
                .disabled(storageUsedBytes == 0)
            }
        }
        .settingsDetailChrome("Music Analysis")
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
            Text("Tempo, key and genre results on this \(DeviceClass.current.displayName) are removed. Your corrections are kept.")
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

private struct AboutAdvancedSettingsDetail: View {
    @ObservedObject private var store = SettingsStore.shared

    @State private var showingResetConfirmation = false

    var body: some View {
        List {
            Section("About") {
                LabeledContent("Version", value: currentAppVersion())
                LabeledContent("Build", value: currentAppBuild())
                Link(destination: URL(string: "https://github.com/0xdeafcafe/sounding-tv")!) {
                    LabeledContent {
                        Image(systemName: "arrow.up.right.square")
                    } label: {
                        Text("Source Code")
                    }
                }
            }

            Section {
                Toggle("Sync Settings with iCloud", isOn: store.syncSettingsWithICloudBinding)
            } header: {
                Text("iCloud")
            } footer: {
                Text("Settings follow your Apple ID to your other devices. Recent searches and other SoundCloud account settings are cleared from this device when you sign out of SoundCloud.")
            }

            if NetworkActivityLog.isVisible {
                Section {
                    NavigationLink("Network Activity") { NetworkActivityView() }
                }
            }

            Section {
                Button("Reset All Settings", role: .destructive) {
                    showingResetConfirmation = true
                }
            } footer: {
                Text("Restores the default playback and download settings on this \(DeviceClass.current.displayName).")
            }

        }
        .settingsDetailChrome("About & Advanced")
        .confirmationDialog("Reset All Settings", isPresented: $showingResetConfirmation) {
            Button("Reset All Settings", role: .destructive) { resetAllSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Playback and download settings on this \(DeviceClass.current.displayName) return to their defaults.")
        }
    }

    private func resetAllSettings() {
        store.setStreamingQualityCeiling(SettingKeys.StreamingQualityCeiling.defaultValue)
        store.setDownloadQualityCeiling(SettingKeys.DownloadQualityCeiling.defaultValue)
        store.setCellularStreamingAllowed(SettingKeys.CellularStreamingAllowed.defaultValue)
        store.setLiveActivitiesEnabled(SettingKeys.LiveActivitiesEnabled.defaultValue)
        store.setCellularDownloadsAllowed(SettingKeys.CellularDownloadsAllowed.defaultValue)
        store.setDJAutoMixEnabled(SettingKeys.DJAutoMixEnabled.defaultValue)
        store.setDJDefaultProfileId(SettingKeys.DJDefaultProfileId.defaultValue)
        store.setDJTransitionLengthSeconds(SettingKeys.DJTransitionLengthSeconds.defaultValue)
        store.setSetMinimumDurationSeconds(SettingKeys.SetMinimumDurationSeconds.defaultValue)
        store.setForceDeviceLocal(SettingKeys.StreamingQualityCeiling.self, false)
        store.setForceDeviceLocal(SettingKeys.DownloadQualityCeiling.self, false)
        store.setForceDeviceLocal(SettingKeys.DJAutoMixEnabled.self, false)
        store.setForceDeviceLocal(SettingKeys.DJDefaultProfileId.self, false)
        store.setForceDeviceLocal(SettingKeys.DJTransitionLengthSeconds.self, false)
        store.setForceDeviceLocal(SettingKeys.SetMinimumDurationSeconds.self, false)
    }

}

private struct PhoneDownloadedMusicView: View {
    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator

    var body: some View {
        DownloadedMusicView()
            .environment(\.downloadedTrackPlayer) { track, context in
                Task { await coordinator.play(track, in: context) }
            }
    }
}
