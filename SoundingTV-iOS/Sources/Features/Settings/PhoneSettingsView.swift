import SwiftUI
import UIKit

enum PhoneChrome {
    static let floatingClearance: CGFloat = 60
}

struct PhoneSettingsView: View {
    @EnvironmentObject private var client: CompanionClient
    @EnvironmentObject private var polyphony: PolyphonyController
    @EnvironmentObject private var linkOffers: LinkOfferBrowser
    @EnvironmentObject private var cloudOffers: CloudPairingOfferMonitor
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var subscription = SubscriptionService.shared
    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var player = PlayerService.shared
    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @ObservedObject private var activityPoller = SoundCloudActivityPoller.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var debugDeepLink: SettingsDeepLink? = SettingsDeepLink.fromEnvironment
    @State private var intelligenceSummary = "–"

    var body: some View {
        List {
            Section {
                CategoryLink(
                    icon: "person.crop.circle.fill", tint: SettingsGlyph.account,
                    title: "Account", summary: accountSummary,
                    isUrgent: accountIsUrgent
                ) { AccountSettingsDetail() }

                if !credentials.needsSignIn {
                    CategoryLink(
                        icon: "star.fill", tint: SettingsGlyph.subscription,
                        title: "Subscription", summary: subscriptionSummary,
                        isUrgent: subscriptionIsUrgent
                    ) { SubscriptionSettingsDetail() }

                    CategoryLink(
                        icon: activityPoller.unreadCount > 0 ? "bell.badge.fill" : "bell.fill",
                        tint: SettingsGlyph.activity,
                        title: "Activity",
                        summary: activitySummary
                    ) { PhoneActivityInboxView() }

                    CategoryLink(
                        icon: "bubble.left.and.bubble.right.fill", tint: SettingsGlyph.activity,
                        title: "Messages", summary: "SoundCloud inbox"
                    ) { PhoneMessagesView() }
                }
            } footer: {
                Text(credentials.needsSignIn
                     ? "Sign in to access account settings."
                     : subscriptionFooter)
            }
            .listRowBackground(Color.scBgOverlay)

            Section {
                CategoryLink(
                    icon: "appletv.fill", tint: SettingsGlyph.devices,
                    title: "Companion", summary: appleTVSummary,
                    isUrgent: appleTVIsUrgent
                ) { CompanionRootView() }

                CategoryLink(
                    icon: "play.fill", tint: SettingsGlyph.playback,
                    title: "Playback", summary: playbackSummary
                ) { PlaybackSettingsDetail() }

                if !credentials.needsSignIn {
                    CategoryLink(
                        icon: "point.3.connected.trianglepath.dotted", tint: SettingsGlyph.polyphony,
                        title: "Polyphony", summary: polyphonySummary
                    ) { PolyphonyView() }

                    CategoryLink(
                        icon: "arrow.down", tint: SettingsGlyph.downloads,
                        title: "Downloads", summary: downloadsSummary
                    ) { DownloadsSettingsDetail() }

                    CategoryLink(
                        icon: "waveform", tint: SettingsGlyph.intelligence,
                        title: "Music Intelligence", summary: intelligenceSummary
                    ) { MusicIntelligenceSettingsDetail() }
                }
            }
            .listRowBackground(Color.scBgOverlay)

            Section {
                CategoryLink(
                    icon: "gearshape.fill", tint: SettingsGlyph.about,
                    title: "About & Advanced",
                    summary: "\(currentAppVersion()) (\(currentAppBuild()))"
                ) { AboutAdvancedSettingsDetail() }
            }
            .listRowBackground(Color.scBgOverlay)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.scBgBase.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: PhoneChrome.floatingClearance) }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(item: $debugDeepLink) { link in
            switch link {
            case .account:      AccountSettingsDetail()
            case .subscription: SubscriptionSettingsDetail()
            case .activity:     PhoneActivityInboxView()
            case .messages:     PhoneMessagesView()
            case .playback:     PlaybackSettingsDetail()
            case .downloads:    DownloadsSettingsDetail()
            case .intelligence: MusicIntelligenceSettingsDetail()
            case .devices:      CompanionRootView()
            case .about:        AboutAdvancedSettingsDetail()
            }
        }
        .task {
            credentials.refreshFromStore()
            let snapshot = await AnalysisDataUsage.snapshot()
            intelligenceSummary = snapshot.analysedTrackCount == 0
                ? "None"
                : (snapshot.analysedTrackCount == 1 ? "1 track" : "\(snapshot.analysedTrackCount) tracks")
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            credentials.refreshFromStore()
        }
    }

    private var accountSummary: String {
        switch credentials.sessionHealth {
        case .rejected:
            return "Needs Sign-In"
        case .signedOut:
            return "Please Sign In"
        case .healthy, .unverified:
            if let user = credentials.currentUser { return "@\(user.username)" }
            return "Signed In"
        }
    }

    private var accountIsUrgent: Bool { credentials.isSessionRejected }

    private var subscriptionSummary: String {
        guard !credentials.isSignedOut, !credentials.isSessionRejected else { return "Sign In Required" }
        guard subscription.authenticatedAccountID != nil else { return "Checking…" }
        if downloads.scheduledDeletionDate != nil { return "Downloads at risk" }
        return tierDisplayName(subscription.tier)
    }

    private var subscriptionFooter: String {
        guard !credentials.isSignedOut, !credentials.isSessionRejected else {
            return "Sign in to check your plan. Existing downloads stay on this iPhone."
        }
        return subscription.statusDescription
    }

    private var subscriptionIsUrgent: Bool {
        if downloads.scheduledDeletionDate != nil { return true }
        if case .verifiedNotSubscribed = subscription.verification { return true }
        return false
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

    private var appleTVSummary: String {
        if !client.isLinked, linkOffers.offer != nil || cloudOffers.hasOffer {
            return "Wants to Sign In"
        }
        return tvStatusText(client.state)
    }

    private var appleTVIsUrgent: Bool {
        if case .failed = client.state { return true }
        return false
    }

    private var polyphonySummary: String {
        switch polyphony.mode {
        case .leading: return polyphony.speakerCount == 1 ? "Leading · 1 good boy" : "Leading · \(polyphony.speakerCount) good boys"
        case .startingLeader: return "Starting…"
        case .connecting(let leaderName): return "Joining \(leaderName)…"
        case .speaker(let leaderName): return "Following \(leaderName)"
        case .failed: return "Needs Attention"
        case .idle: return "Play Together"
        }
    }
}

private struct CategoryLink<Destination: View>: View {
    let icon: String
    let tint: GlyphTint
    let title: String
    let summary: String
    var isUrgent: Bool = false
    @ViewBuilder let destination: () -> Destination

    var body: some View {
        NavigationLink {
            destination()
        } label: {
            LabeledContent {
                HStack(spacing: 4) {
                    if isUrgent {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(Color.scDestructive)
                    }
                    Text(summary)
                        .foregroundStyle(isUrgent ? Color.scDestructive : Color.scTextSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .layoutPriority(1)
                }
            } label: {
                SettingsLabel(title, systemImage: icon, tint: tint)
            }
        }
    }
}

private struct PhoneActivityInboxView: View {
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
                    message: "Followers, messages, and your SoundCloud stream are account-only.",
                    actionTitle: "Sign In",
                    action: { isShowingSignIn = true },
                    style: .phone
                )
                .phoneStateLayout()
            } else if poller.inbox.isEmpty {
                ContentUnavailableView(
                    "No New Activity",
                    systemImage: "bell",
                    description: Text("New followers, messages, and stream activity will appear here.")
                )
                .phoneStateLayout()
            } else {
                List {
                    ForEach(poller.inbox) { event in
                        Button {
                            poller.markRead(id: event.id)
                            if let destination = event.destination { openURL(destination) }
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: symbol(for: event.kind))
                                    .foregroundStyle(event.readAt == nil ? Color.scAccent : Color.scTextSecondary)
                                    .frame(width: 28, height: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(event.title)
                                        .font(.subheadline.weight(event.readAt == nil ? .bold : .semibold))
                                        .foregroundStyle(Color.scTextPrimary)
                                    Text(event.body)
                                        .font(.caption)
                                        .foregroundStyle(Color.scTextSecondary)
                                        .lineLimit(3)
                                    Text(event.date, style: .relative)
                                        .font(.caption2)
                                        .foregroundStyle(Color.scTextTertiary)
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Activity")
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
                    title: "Messages Need an Account",
                    message: "Sign in to read and reply to your SoundCloud messages.",
                    actionTitle: "Sign In",
                    action: { isShowingSignIn = true },
                    style: .phone
                )
                .phoneStateLayout()
            } else if model.isLoading, model.conversations.isEmpty {
                LoadingState(message: "Loading messages…")
            } else if model.conversations.isEmpty {
                ContentUnavailableView {
                    Label(model.errorMessage == nil ? "No Messages Yet" : "Messages Unavailable", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text(model.errorMessage ?? "Conversations from SoundCloud will appear here.")
                } actions: {
                    if model.errorMessage != nil {
                        Button("Try Again") { Task { await model.load() } }
                    }
                    Link("Open SoundCloud Inbox", destination: SoundCloudAPI.webInboxURL)
                }
                .phoneStateLayout()
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
        .scrollContentBackground(.hidden)
        .background(Color.scBgBase.ignoresSafeArea())
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
            AsyncImage(url: counterpart?.avatarURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "person.fill")
                    .foregroundStyle(Color.scTextSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.scBgRaised)
            }
            .frame(width: 46, height: 46)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(counterpart?.username ?? "Conversation")
                        .font(.subheadline.weight(conversation.unreadCount > 0 ? .bold : .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
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
                    .foregroundStyle(Color.scTextSecondary)
                    .lineLimit(2)
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
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Color.scWarning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.scWarning.opacity(0.10))
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message…", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.scBgRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                Button { Task { await send() } } label: {
                    if isSending {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 40, height: 40)
                .background(Color.scAccent, in: Circle())
                .disabled(isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || counterpart == nil)
            }
            .padding()
            .background(.regularMaterial)
        }
        .background(Color.scBgBase.ignoresSafeArea())
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
                    .foregroundStyle(outgoing ? .white : Color.scTextPrimary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(
                        outgoing ? Color.scAccent : Color.scBgRaised,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                if message.createdAt != .distantPast {
                    Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(Color.scTextTertiary)
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
            if conversation.messages.isEmpty { errorMessage = error.localizedDescription }
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
            errorMessage = error.localizedDescription
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
            errorMessage = error.localizedDescription
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

private struct SettingsLabel: View {
    let title: String
    let systemImage: String
    let tint: GlyphTint

    init(_ title: String, systemImage: String, tint: GlyphTint) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint.on)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tint.fill)
                )
        }
    }
}

private struct GlyphTint {
    let fill: Color
    let on: Color
}

private enum SettingsGlyph {
    static let account = GlyphTint(fill: .scAccent, on: .scAccentOn)
    static let subscription = GlyphTint(fill: .scWarning, on: .scWarningOn)
    static let activity = GlyphTint(fill: .scAccent.opacity(0.82), on: .scAccentOn)
    static let playback = GlyphTint(
        fill: Color(red: 0.30, green: 0.64, blue: 1.00),
        on: Color(red: 0.00, green: 0.06, blue: 0.10)
    )
    static let downloads = GlyphTint(fill: .scSuccess, on: .scSuccessOn)
    static let polyphony = GlyphTint(
        fill: Color(red: 0.65, green: 0.25, blue: 0.92),
        on: .white
    )
    static let intelligence = GlyphTint(
        fill: Color(red: 0.36, green: 0.80, blue: 0.89),
        on: Color(red: 0.02, green: 0.09, blue: 0.11)
    )
    static let devices = GlyphTint(
        fill: Color(red: 0.66, green: 0.55, blue: 1.00),
        on: Color(red: 0.05, green: 0.04, blue: 0.10)
    )
    static let about = GlyphTint(
        fill: Color(white: 0.69),
        on: Color(white: 0.08)
    )
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
    case .unverifiable: return "Unverified"
    case .verifiedNotSubscribed: return "Not Subscribed"
    }
}

private func verificationTint(_ verification: SubscriptionService.VerificationStatus) -> Color {
    switch verification {
    case .verified: return .scSuccess
    case .unverifiable(let withinGrace): return withinGrace ? .scWarning : .scTextTertiary
    case .verifiedNotSubscribed: return .scDestructive
    }
}

private func tvStatusText(_ state: CompanionClient.State) -> String {
    switch state {
    case .unlinked: return "Not Paired"
    case .idle: return "Idle"
    case .searching: return "Searching…"
    case .connecting: return "Connecting…"
    case .connected: return "Connected"
    case .failed: return "Unreachable"
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

private func cacheByteString(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
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
            .scrollContentBackground(.hidden)
            .background(Color.scBgBase.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { Color.clear.frame(height: PhoneChrome.floatingClearance) }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

enum SettingsDeepLink: String, Identifiable, Hashable {
    case account, subscription, activity, messages, playback, downloads, intelligence, devices, about

    var id: String { rawValue }

    static var fromEnvironment: SettingsDeepLink? {
        #if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["SOUNDING_TV_PHONE_SETTINGS"] else {
            return nil
        }
        return SettingsDeepLink(rawValue: raw)
        #else
        return nil
        #endif
    }
}

private struct AccountSettingsDetail: View {
    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var isSigningOut = false
    @State private var isRetrying = false
    @State private var showingSignOutConfirmation = false
    @State private var isShowingSignIn = false

    var body: some View {
        List {
            switch credentials.sessionHealth {
            case .healthy, .unverified:
                profileSection
                signOutSection
            case .rejected(let kind):
                rejectedSection(kind)
                signOutSection
            case .signedOut:
                signInSection
            }
            soundCloudManagementSection
        }
        .sheet(isPresented: $isShowingSignIn) { signInSheet }
        .settingsDetailChrome("Account")
        .task {
            credentials.refreshFromStore()
            await credentials.revalidate()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            credentials.refreshFromStore()
            Task { await credentials.revalidate() }
        }
        .confirmationDialog("Sign Out of SoundCloud", isPresented: $showingSignOutConfirmation) {
            Button("Sign Out", role: .destructive) { signOut() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your account content is removed from this iPhone. Public browsing and playback stay available, and your other devices remain signed in.")
        }
    }

    private var profileSection: some View {
        Section {
            if let user = credentials.currentUser {
                HStack(spacing: 12) {
                    AsyncImage(url: user.avatarURL) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFill()
                        } else {
                            Circle().fill(Color.scBgRaised)
                        }
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(user.displayName).font(.headline)
                        Text("@\(user.username)")
                            .font(.subheadline)
                            .foregroundStyle(Color.scTextSecondary)
                    }
                }
                .padding(.vertical, 4)

                NavigationLink("View Profile") { ProfileView() }
            } else {
                LabeledContent("SoundCloud", value: statusText)
            }
        } footer: {
            if credentials.sessionHealth == .unverified {
                Text("Checking this sign-in with SoundCloud…")
            }
        }
        .listRowBackground(Color.scBgOverlay)
    }

    private var statusText: String {
        switch credentials.sessionHealth {
        case .healthy: return "Signed In"
        case .unverified: return "Signed In"
        case .rejected: return "Not Working"
        case .signedOut: return "Please Sign In"
        }
    }

    private var signOutSection: some View {
        Section {
            Button("Sign Out", role: .destructive) {
                showingSignOutConfirmation = true
            }
            .disabled(isSigningOut)
        } footer: {
            Text("Clears this iPhone's authentication and cached account content. Your Apple TV and other devices stay signed in.")
        }
        .listRowBackground(Color.scBgOverlay)
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
            Text("Opens SoundCloud's own website for sensitive account changes. SoundingCloud never handles passwords, authenticator secrets, backup codes, or billing details.")
        }
        .listRowBackground(Color.scBgOverlay)
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
                    .foregroundStyle(Color.scTextSecondary)
            }
        }
    }

    private func rejectedSection(_ kind: SoundCloudCredentialSource.RejectionKind) -> some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sign-In Not Working").font(.headline)
                    Text(rejectionExplanation(kind))
                        .font(.footnote)
                        .foregroundStyle(Color.scTextSecondary)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.scWarning)
            }

            Button("Reauthenticate") { isShowingSignIn = true }
        }
        .listRowBackground(Color.scBgOverlay)
    }

    private func rejectionExplanation(_ kind: SoundCloudCredentialSource.RejectionKind) -> String {
        switch kind {
        case .accountRejected:
            return "SoundCloud rejected this iPhone's access. Sign in again to reconnect your account."
        case .noRefreshCapability:
            return "This iPhone's sign-in couldn't renew itself. Sign in again - it won't happen every time."
        case .refreshUnreachable:
            return "SoundCloud couldn't be reached to renew this sign-in. It may recover on its own, or try again now."
        }
    }

    private var signInSection: some View {
        Section {
            Button("Sign In to SoundCloud") { isShowingSignIn = true }
        } footer: {
            Text(signInFooter)
        }
        .listRowBackground(Color.scBgOverlay)
    }

    private var signInFooter: String {
        switch credentials.lastSignOutReason {
        case .accountRejected:
            return "SoundCloud rejected this iPhone's access. Sign in again to reconnect your account."
        case .noRefreshCapability:
            return "This iPhone's sign-in couldn't renew itself. Sign in again - it won't happen every time."
        case nil:
            return "Home, Search, and public pages work in guest mode. Please sign in to save, follow, message, or download."
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
            await credentials.signOut()
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
    @State private var didCopy = false

    var body: some View {
        List {
            Section {
                LabeledContent("Plan", value: planDisplay)
                LabeledContent {
                    Text(statusDisplay)
                        .foregroundStyle(hasAccountContext
                            ? verificationTint(subscription.verification)
                            : Color.scTextSecondary)
                } label: {
                    Text("Status")
                }
            } header: {
                Text("Plan")
            } footer: {
                Text(isSignedOut
                     ? "Sign in to check your plan. Existing downloads stay on this iPhone but are unavailable until then."
                     : subscription.statusDescription)
            }
            .listRowBackground(Color.scBgOverlay)

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
                            .foregroundStyle(Color.scTextSecondary)
                    }
                }
            } footer: {
                Text("Check Again reads the current plan. Billing, upgrades, and cancellation stay on SoundCloud's website.")
            }
            .listRowBackground(Color.scBgOverlay)

            if let deletionDate = downloads.scheduledDeletionDate {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Downloads Will Be Removed").font(.headline)
                            Text("Deleted on \(deletionDate.formatted(date: .abbreviated, time: .shortened)) unless the subscription is renewed.")
                                .font(.footnote)
                                .foregroundStyle(Color.scTextSecondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.scDestructive)
                    }
                } footer: {
                    Text("SoundCloud couldn't verify the account plan; existing encrypted downloads remain account-bound.")
                }
                .listRowBackground(Color.scBgOverlay)
            }

            if hasAccountContext {
                Section {
                    if let raw = subscription.lastRawSubscriptionDescription {
                        Text(raw)
                            .font(.footnote.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            UIPasteboard.general.string = raw
                            didCopy = true
                        } label: {
                            Label(didCopy ? "Copied" : "Copy Plan Details", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                        }
                    } else {
                        Text("Not checked yet.").foregroundStyle(Color.scTextSecondary)
                    }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("Exactly what SoundCloud reported about this account's plan. If the plan above reads as Unknown, copy this - the product id identifies a plan the app hasn't seen before.")
                }
                .listRowBackground(Color.scBgOverlay)
            }
        }
        .settingsDetailChrome("Subscription")
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, !isSignedOut else { return }
            Task { await subscription.verifyNow() }
        }
    }

    private var isSignedOut: Bool {
        credentials.isSignedOut || credentials.isSessionRejected
    }

    private var hasAccountContext: Bool {
        !isSignedOut && subscription.authenticatedAccountID != nil
    }

    private var planDisplay: String {
        if isSignedOut { return "Unavailable" }
        guard hasAccountContext else { return "Checking…" }
        return tierDisplayName(subscription.tier)
    }

    private var statusDisplay: String {
        if isSignedOut { return "Sign In Required" }
        guard hasAccountContext else { return "Checking…" }
        return verificationDisplay(subscription.verification)
    }

    private func check() {
        guard !isChecking else { return }
        isChecking = true
        didCopy = false
        Task {
            await subscription.verifyNow()
            isChecking = false
        }
    }
}

private struct PlaybackSettingsDetail: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var player = PlayerService.shared

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
                Picker(selection: store.downloadQualityCeilingBinding) {
                    ForEach(QualityCeiling.allCases) { level in
                        Text(qualityRowLabel(level)).tag(level)
                    }
                } label: {
                    Text("Download Quality")
                }
            } header: {
                Text("Quality")
            } footer: {
                Text("Caps the bitrate used while listening live and the bitrate saved for offline playback. "
                     + QualitySizeEstimator.summaryLine() + " - approximate, based on SoundCloud's own preset bitrates."
                     + pinnedNote(for: [("Streaming", SettingKeys.StreamingQualityCeiling.self.isPinned(store)),
                                        ("Download", SettingKeys.DownloadQualityCeiling.self.isPinned(store))]))
            }
            .listRowBackground(Color.scBgOverlay)

            CollectionQualityOverridesSection()

            Section {
                Toggle("Auto-Mix", isOn: store.djAutoMixEnabledBinding)
                if store.djAutoMixEnabled {
                    Picker("Personality", selection: store.djDefaultProfileIdBinding) {
                        ForEach(DJProfile.all) { profile in
                            Text(profile.displayName).tag(profile.id)
                        }
                    }
                    LabeledContent("Status", value: autoMixStatusText)
                }
            } header: {
                Text("DJ")
            } footer: {
                Text("Auto-Mix keeps the next deck ready in the background, picks a bass swap, filter move, "
                     + "half-time blend or clean cut from the analysis it trusts, then acts at the chosen moment. "
                     + (DJProfile.profile(id: store.djDefaultProfileId)?.blurb ?? "") + " "
                     + "Switch it off for manual decks: seeking moves playback, and only Cue or a hot-cue action creates a cue point. "
                     + "Unavailable while streaming to AirPlay speakers, since beat-matching needs a local output with predictable latency."
                     + pinnedNote(for: [("Auto-Mix", SettingKeys.DJAutoMixEnabled.self.isPinned(store))]))
            }
            .listRowBackground(Color.scBgOverlay)

            Section {
                Picker("Minimum Set Length", selection: store.setMinimumDurationSecondsBinding) {
                    ForEach(GeneratedLibraryCollections.setDurationPresets, id: \.self) { duration in
                        Text(GeneratedLibraryCollections.durationLabel(duration)).tag(duration)
                    }
                }
            } header: {
                Text("Library")
            } footer: {
                Text("Sets are generated from duration metadata in your liked tracks. No track audio is downloaded."
                    + pinnedNote(for: [("Set length", SettingKeys.SetMinimumDurationSeconds.self.isPinned(store))]))
            }
            .listRowBackground(Color.scBgOverlay)

            SyncScopeSection(store: store, pinnedNoun: "this iPhone")

            Section {
                Toggle("Allow Cellular Streaming", isOn: store.cellularStreamingAllowedBinding)
            } header: {
                Text("Cellular")
            } footer: {
                Text("Off means playback only starts on Wi-Fi. This setting always stays on this iPhone.")
            }
            .listRowBackground(Color.scBgOverlay)

            Section {
                LabeledContent("Output", value: player.outputRoute.outputName ?? "Unavailable")
                LabeledContent("Channels", value: channelDescription)
                LabeledContent("Spatial Audio", value: "Stereo widened")
            } header: {
                Text("Audio")
            } footer: {
                Text("Stereo is widened to whatever the current output can render. Not Dolby Atmos - SoundCloud serves no Atmos masters.")
            }
            .listRowBackground(Color.scBgOverlay)
        }
        .settingsDetailChrome("Playback")
    }

    private var channelDescription: String {
        player.outputRoute.supportsMultichannel
            ? "\(player.outputRoute.maximumOutputChannels)-channel"
            : "Stereo"
    }

    private func qualityRowLabel(_ level: QualityCeiling) -> String {
        if let mb = QualitySizeEstimator.approximateMBPerHour(for: level) {
            return "\(level.displayName) (~\(Int(mb.rounded())) MB/hr)"
        }
        return "\(level.displayName) (varies, no cap)"
    }

    private var autoMixStatusText: String {
        let decision = player.automaticMixDecision
        if let countdown = decision.countdownText(currentTime: player.currentTime) {
            return "\(decision.statusLabel) \(countdown)"
        }
        return decision.statusLabel
    }

    private func pinnedNote(for entries: [(String, Bool)]) -> String {
        let pinned = entries.filter(\.1).map(\.0)
        guard !pinned.isEmpty else { return "" }
        return " " + pinned.joined(separator: " and ")
            + (pinned.count == 1 ? " is" : " are")
            + " kept on this iPhone rather than synced."
    }
}

private struct CollectionQualityOverridesSection: View {
    @ObservedObject private var credentials = SoundCloudCredentialSource.shared
    @ObservedObject private var overrideStore = CollectionQualityOverrideStore.shared

    private enum LoadState {
        case idle, loading, loaded([Playlist]), failed
    }

    @State private var state: LoadState = .idle

    var body: some View {
        Section {
            switch state {
            case .idle, .loading:
                HStack {
                    Text("Loading Playlists…").foregroundStyle(Color.scTextSecondary)
                    Spacer()
                    ProgressView()
                }
            case .failed:
                Text("Couldn't load playlists.").foregroundStyle(Color.scTextSecondary)
            case .loaded(let playlists) where playlists.isEmpty:
                Text("No playlists yet.").foregroundStyle(Color.scTextSecondary)
            case .loaded(let playlists):
                ForEach(playlists) { playlist in
                    playlistRow(playlist)
                }
            }
        } header: {
            Text("Quality by Collection")
        } footer: {
            Text("Overrides the streaming and download quality above, for one playlist only. "
                 + "Sets and long-form uploads are labelled, so it's easy to drop a tier "
                 + "where the loss matters least.")
        }
        .listRowBackground(Color.scBgOverlay)
        .task { await load() }
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        let kind = CollectionKind.classify(playlist: playlist)
        let binding = Binding<QualityCeiling?>(
            get: { overrideStore.override(for: playlist.id) },
            set: { overrideStore.setOverride($0, for: playlist.id) }
        )
        return VStack(alignment: .leading, spacing: 4) {
            Picker(selection: binding) {
                Text("Use Default").tag(QualityCeiling?.none)
                ForEach(QualityCeiling.allCases) { level in
                    Text(qualityRowLabel(level)).tag(QualityCeiling?.some(level))
                }
            } label: {
                Text(playlist.title)
            }
            HStack(spacing: 4) {
                Text(kind.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(kind == .set ? Color.scAccent : Color.scTextTertiary)
                Text("· ~\(byteString(estimatedSize(for: playlist, override: binding.wrappedValue)))")
                    .font(.caption2)
                    .foregroundStyle(Color.scTextTertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func estimatedSize(for playlist: Playlist, override: QualityCeiling?) -> Int64 {
        QualitySizeEstimator.estimatedBytes(for: playlist, ceiling: override ?? SettingsStore.shared.downloadQualityCeiling)
    }

    private func qualityRowLabel(_ level: QualityCeiling) -> String {
        if let mb = QualitySizeEstimator.approximateMBPerHour(for: level) {
            return "\(level.displayName) (~\(Int(mb.rounded())) MB/hr)"
        }
        return "\(level.displayName) (varies, no cap)"
    }

    private func load() async {
        guard case .idle = state else { return }
        state = .loading
        guard let user = await credentials.waitForCurrentUser() else {
            state = .failed
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

private extension SettingDefinition {
    @MainActor
    static func isPinned(_ store: SettingsStore) -> Bool {
        store.effectiveScope(Self.self) == .deviceLocal
    }
}

private struct SyncScopeSection: View {
    @ObservedObject var store: SettingsStore
    let pinnedNoun: String

    var body: some View {
        Section {
            row("Streaming Quality", SettingKeys.StreamingQualityCeiling.self)
            row("Download Quality", SettingKeys.DownloadQualityCeiling.self)
            row("DJ Auto-Mix", SettingKeys.DJAutoMixEnabled.self)
            row("DJ Personality", SettingKeys.DJDefaultProfileId.self)
            row("Set Length", SettingKeys.SetMinimumDurationSeconds.self)
        } header: {
            Text("Sync")
        } footer: {
            Text("These settings are shared with your paired device. Turn one off to keep \(pinnedNoun)'s own value.")
        }
        .listRowBackground(Color.scBgOverlay)
    }

    private func row<K: SettingDefinition>(_ title: String, _ key: K.Type) -> some View {
        Toggle(title, isOn: Binding(
            get: { store.effectiveScope(key) == .synced },
            set: { store.setForceDeviceLocal(key, !$0) }
        ))
    }
}

private struct MusicIntelligenceSettingsDetail: View {
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
                Text("Analysis")
            } footer: {
                Text("Tempo, key, genre and waveform results measured from your music. Tempo and key are measured on this iPhone once a track is downloaded, then synced to your Apple TV, which can't measure them itself. The least-recently-used results are dropped automatically to stay inside the budget.")
            }
            .listRowBackground(Color.scBgOverlay)

            Section {
                LabeledContent("Tempo & Key", value: count(\.tempoKeyCount))
                LabeledContent("Genre", value: count(\.genreCount))
                LabeledContent("Waveforms", value: count(\.waveformCount))
            } header: {
                Text("Results by Kind")
            }
            .listRowBackground(Color.scBgOverlay)

            Section {
                LabeledContent("Library Cache", value: libraryText)
            } footer: {
                Text("An offline copy of your library so it opens instantly. Clearing it re-downloads the listings next time you open the library. The space the file reserved is reused, not returned.")
            }
            .listRowBackground(Color.scBgOverlay)

            Section {
                Button("Clear Analysis Data", role: .destructive) {
                    showingClearAnalysisConfirmation = true
                }
                Button("Clear Library Cache", role: .destructive) {
                    showingClearLibraryConfirmation = true
                }
            } footer: {
                Text("Clearing never interrupts playback. Analysis is rebuilt the next time it's needed.")
            }
            .listRowBackground(Color.scBgOverlay)
        }
        .settingsDetailChrome("Music Intelligence")
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
            Text("Removes every stored tempo, key, genre and waveform result on this iPhone, including ones synced from other devices. Playback keeps going, and analysis is rebuilt when it's needed again.")
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
            Text("Empties the offline copy of your library on this iPhone. It re-downloads next time you open the library.")
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

private struct DownloadsSettingsDetail: View {
    @EnvironmentObject private var companionClient: CompanionClient
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var subscription = SubscriptionService.shared
    @ObservedObject private var downloads = DownloadManager.shared
    @ObservedObject private var credentials = SoundCloudCredentialSource.shared

    @State private var showingRemoveDownloadsConfirmation = false
    @State private var remoteDownloads: [String: [DownloadManifestSyncRecord]] = [:]
    @State private var transferringDeviceIDs: Set<String> = []

    private static let cellularSectionID = "downloads-cellular-section"

    var body: some View {
        ScrollViewReader { proxy in
            list
                #if DEBUG
                .task {
                    guard ProcessInfo.processInfo.environment["SOUNDING_TV_PHONE_SCROLL_BOTTOM"] == "1" else { return }
                    try? await Task.sleep(for: .milliseconds(300))
                    withAnimation(nil) {
                        proxy.scrollTo(Self.cellularSectionID, anchor: .bottom)
                    }
                }
                #endif
        }
    }

    private var list: some View {
        List {
            Section {
                LabeledContent("Available Offline", value: "\(downloadedEntries.count) tracks")
                if !inProgressEntries.isEmpty {
                    LabeledContent("In Progress", value: "\(inProgressEntries.count)")
                }
                LabeledContent("Network", value: networkDescription)
                LabeledContent(
                    "SoundCloud Plan",
                    value: credentials.isSignedOut || credentials.isSessionRejected
                        ? "Sign In Required"
                        : (subscription.authenticatedAccountID == nil
                            ? "Checking…"
                            : "Track availability")
                )
                if let deletionDate = downloads.scheduledDeletionDate {
                    Label {
                        Text("Downloads are deleted on \(deletionDate.formatted(date: .abbreviated, time: .shortened)) unless the subscription is renewed.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.scDestructive)
                    }
                }
            } header: {
                Text("Status")
            }
            .listRowBackground(Color.scBgOverlay)

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Storage Used",
                                   value: "\(byteString(downloads.usedBytes)) of \(byteString(store.downloadStorageCapBytes))")
                    ProgressView(value: storageFraction)
                        .tint(storageFraction > 0.92 ? Color.scWarning : Color.scAccent)
                }
                .padding(.vertical, 2)

                Stepper(value: Binding(get: { Double(store.downloadStorageCapBytes) },
                                       set: { store.setDownloadStorageCapBytes(Int64($0)) }),
                        in: Double(Self.storageFloor)...Double(Self.storageCeiling),
                        step: Double(Self.storageStep)) {
                    LabeledContent("Storage Limit", value: byteString(store.downloadStorageCapBytes))
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Downloads made ahead of you are removed oldest-first once this limit is reached. Tracks you've kept never are.")
            }
            .listRowBackground(Color.scBgOverlay)

            if !inProgressEntries.isEmpty {
                Section {
                    ForEach(inProgressEntries, id: \.track.id) { entry in
                        downloadRow(for: entry)
                    }
                } header: {
                    Text("In Progress")
                } footer: {
                    Text(transferFooter)
                }
                .listRowBackground(Color.scBgOverlay)
            }

            if !keptDownloadedEntries.isEmpty {
                Section {
                    ForEach(keptDownloadedEntries, id: \.track.id) { entry in
                        downloadRow(for: entry)
                    }
                } header: {
                    Text("Kept Offline")
                } footer: {
                    Text("These stay on this iPhone until you remove them, or remove the collection keeping them downloaded.")
                }
                .listRowBackground(Color.scBgOverlay)
            }

            if !predictiveDownloadedEntries.isEmpty {
                Section {
                    ForEach(predictiveDownloadedEntries, id: \.track.id) { entry in
                        downloadRow(for: entry)
                    }
                } header: {
                    Text("Ready for You")
                } footer: {
                    Text("Downloaded ahead from your queue and recent listening. These go automatically when space is needed. Swipe right to keep one.")
                }
                .listRowBackground(Color.scBgOverlay)
            }

            if downloads.entries.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No Downloads", systemImage: "arrow.down.circle")
                    } description: {
                        Text("Choose Download on a track or keep a playlist offline when a usable source is available.")
                    }
                }
                .listRowBackground(Color.scBgOverlay)
            }

            Section {
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
            } header: {
                Text("Other Devices")
            } footer: {
                Text("When the source device is awake on your local network, Copy transfers its existing audio over the authenticated companion link and encrypts it for this iPhone.")
            }
            .listRowBackground(Color.scBgOverlay)

            Section {
                Picker("Download Quality", selection: store.downloadQualityCeilingBinding) {
                    ForEach(QualityCeiling.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                Toggle("Allow Cellular Downloads", isOn: store.cellularDownloadsAllowedBinding)
            } header: {
                Text("Download Policy")
            } footer: {
                Text("Cellular permission always stays on this iPhone. Quality can sync with your other devices from Playback settings.")
            }
            .listRowBackground(Color.scBgOverlay)
            .id(Self.cellularSectionID)

            if !downloads.entries.isEmpty {
                Section {
                    Button("Remove All Downloads", role: .destructive) {
                        showingRemoveDownloadsConfirmation = true
                    }
                } footer: {
                    Text("Removes audio only. Your likes, playlists, library cache and music-intelligence results remain.")
                }
                .listRowBackground(Color.scBgOverlay)
            }
        }
        .settingsDetailChrome("Downloads")
        .task {
            remoteDownloads = await RemoteDownloadManifestStore.shared.manifestsByDevice(
                excluding: DownloadManifestDeviceIdentity.deviceId()
            )
        }
        .confirmationDialog("Remove All Downloads", isPresented: $showingRemoveDownloadsConfirmation) {
            Button("Remove All Downloads", role: .destructive) { removeAllDownloads() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every downloaded track will be deleted from this iPhone. This can't be undone.")
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

    private var storageFraction: Double {
        let cap = store.downloadStorageCapBytes
        guard cap > 0 else { return 0 }
        return min(1, Double(downloads.usedBytes) / Double(cap))
    }

    private var sortedDownloadEntries: [DownloadEntry] {
        downloads.entries.values.sorted { $0.addedAt > $1.addedAt }
    }

    private var inProgressEntries: [DownloadEntry] {
        sortedDownloadEntries.filter { !$0.isDownloaded }
    }

    private var downloadedEntries: [DownloadEntry] {
        sortedDownloadEntries.filter(\.isDownloaded)
    }

    private var keptDownloadedEntries: [DownloadEntry] {
        downloadedEntries.filter(\.isEffectivelyPinned)
    }

    private var predictiveDownloadedEntries: [DownloadEntry] {
        downloadedEntries.filter { !$0.isEffectivelyPinned }
    }

    private var networkDescription: String {
        if !downloads.hasConnectivity { return "Offline" }
        if downloads.isOnUnmeteredNetwork { return "Wi-Fi or Ethernet" }
        return store.cellularDownloadsAllowed ? "Cellular Allowed" : "Waiting for Wi-Fi"
    }

    private var transferFooter: String {
        if !downloads.hasConnectivity { return "Downloads are paused while this iPhone is offline." }
        if !downloads.isOnUnmeteredNetwork, !store.cellularDownloadsAllowed {
            return "Downloads are waiting for Wi-Fi."
        }
        return "Up to three tracks download at once. Pause or retry a track from its row."
    }

    private func downloadRow(for entry: DownloadEntry) -> some View {
        DownloadRow(
            entry: entry,
            state: downloads.state(for: entry.track.id),
            onPause: { downloads.pause(trackId: entry.track.id) },
            onResume: { downloads.resume(trackId: entry.track.id) }
        )
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                downloads.cancel(trackId: entry.track.id)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            Button {
                if entry.isPinned {
                    downloads.unpin(trackId: entry.track.id)
                } else {
                    downloads.pin(trackId: entry.track.id)
                }
            } label: {
                Label(
                    entry.isPinned ? "Automatic" : "Keep",
                    systemImage: entry.isPinned ? "wand.and.stars" : "pin"
                )
            }
        }
    }

    private static let storageStep: Int64 = 500_000_000
    private static let storageFloor: Int64 = 500_000_000
    private static let storageCeiling: Int64 = 20_000_000_000

    private func removeAllDownloads() {
        for trackId in downloads.entries.keys {
            downloads.cancel(trackId: trackId)
        }
    }
}

private struct DownloadRow: View {
    let entry: DownloadEntry
    let state: DownloadState
    let onPause: () -> Void
    let onResume: () -> Void

    var body: some View {
        LabeledContent {
            trailing
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.track.title).lineLimit(1)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(subtitleTint)
                        .lineLimit(2)
                }
            } icon: {
                Image(systemName: entry.isEffectivelyPinned ? "pin.fill" : "sparkles")
                    .foregroundStyle(entry.isEffectivelyPinned ? Color.scAccent : Color.scTextTertiary)
            }
        }
        .accessibilityValue(accessibilityValueSuffix)
    }

    private var subtitle: String {
        if case .failed(let reason) = state { return reason }
        return entry.track.user.displayName
    }

    private var subtitleTint: Color {
        if case .failed = state { return Color.scDestructive }
        return Color.scTextSecondary
    }

    private var accessibilityValueSuffix: String {
        switch state {
        case .failed(let reason): return "Failed: \(reason)"
        case .downloading(let progress): return "\(Int(progress * 100)) percent downloaded"
        case .paused: return "Paused"
        case .queued: return "Waiting to download"
        case .downloaded: return "Downloaded, \(byteString(entry.fileSize))"
        case .notDownloaded: return ""
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .notDownloaded:
            EmptyView()
        case .queued:
            HStack(spacing: 8) {
                Text("Waiting…").foregroundStyle(Color.scTextSecondary)
                Button("Pause", systemImage: "pause.fill", action: onPause)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
        case .downloading(let progress):
            HStack(spacing: 8) {
                Text("\(Int(progress * 100))%").monospacedDigit().foregroundStyle(Color.scAccent)
                Button("Pause", systemImage: "pause.fill", action: onPause)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
        case .paused:
            Button("Resume", systemImage: "arrow.clockwise", action: onResume)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        case .downloaded:
            if entry.fileSize > 0 {
                Text(byteString(entry.fileSize)).foregroundStyle(Color.scTextSecondary)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.scSuccess)
            }
        case .failed:
            Button("Retry", systemImage: "arrow.clockwise.circle.fill", action: onResume)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .tint(Color.scDestructive)
        }
    }
}

private struct AboutAdvancedSettingsDetail: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var player = PlayerService.shared

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
            .listRowBackground(Color.scBgOverlay)

            Section {
                LabeledContent("Playback Stalls", value: "\(player.observedStalls)")
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Stalls counted since launch. A rising number usually means the network, not the app.")
            }
            .listRowBackground(Color.scBgOverlay)

            Section {
                Button("Reset All Settings", role: .destructive) {
                    showingResetConfirmation = true
                }
            } footer: {
                Text("Streaming and download quality, cellular policy, DJ defaults and the set-length threshold reset on this iPhone. Anything pinned to this iPhone is unpinned too.")
            }
            .listRowBackground(Color.scBgOverlay)

        }
        .settingsDetailChrome("About & Advanced")
        .confirmationDialog("Reset All Settings", isPresented: $showingResetConfirmation) {
            Button("Reset All Settings", role: .destructive) { resetAllSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Streaming and download quality, cellular policy, DJ defaults and the set-length threshold reset on this iPhone. Synced settings pinned to this iPhone are unpinned too. Other devices are untouched.")
        }
    }

    private func resetAllSettings() {
        store.setStreamingQualityCeiling(SettingKeys.StreamingQualityCeiling.defaultValue)
        store.setDownloadQualityCeiling(SettingKeys.DownloadQualityCeiling.defaultValue)
        store.setCellularStreamingAllowed(SettingKeys.CellularStreamingAllowed.defaultValue)
        store.setCellularDownloadsAllowed(SettingKeys.CellularDownloadsAllowed.defaultValue)
        store.setDownloadStorageCapBytes(SettingKeys.DownloadStorageCapBytes.defaultValue)
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
