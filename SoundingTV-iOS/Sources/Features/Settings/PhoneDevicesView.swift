import SwiftUI
import VisionKit

enum AppleTVDebugStory {
    private static let story: String? = {
        #if DEBUG
        ProcessInfo.processInfo.environment["SOUNDING_TV_TV_STORY"]
        #else
        nil
        #endif
    }()

    static let forcedState: CompanionClient.State? = {
        #if DEBUG
        switch story {
        case "neverPaired", "nearbyUnlinked": return .unlinked
        case "looking":                       return .searching
        case "unreachable", "waitingNearby":  return .failed(.notFound)
        case "connected", "needsSignIn":      return .connected
        default:                              return VisualFixtures.isEnabled ? .connected : nil
        }
        #else
        return nil
        #endif
    }()

    static var forcedName: String? { forcedState == nil ? nil : "Living Room" }

    static var forcedPeerNeedsSignIn: Bool? { forcedState == nil ? nil : story == "needsSignIn" }

    static let detailSessionId = "fixture"

    static var opensForget: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["SOUNDING_TV_TV_STORY_FORGET"] == "1"
        #else
        false
        #endif
    }

    @MainActor
    static func links(client: CompanionClient) -> [LinkedCompanionStore.LinkRecord] {
        guard let forcedState, client.links.isEmpty else { return client.links }
        guard forcedState != .unlinked else { return [] }
        return [LinkedCompanionStore.LinkRecord(
            sessionId: detailSessionId,
            secretBase64: Data(repeating: 7, count: 32).base64EncodedString(),
            pairedAt: .now,
            deviceClass: .tv,
            displayName: "Living Room"
        )]
    }

    @MainActor
    static func status(
        of record: LinkedCompanionStore.LinkRecord,
        client: CompanionClient,
        offers: [LinkOfferBrowser.Offer]
    ) -> LinkStatus {
        let isActive = client.isActive(record.sessionId) || (forcedState != nil && client.links.isEmpty)
        guard isActive else { return client.status(of: record.sessionId) }
        if PeerSignInPrompt.resolveOnPhone(client: client, offers: offers) != nil { return .needsSignIn }
        guard let forcedState else { return client.status(of: record.sessionId) }
        switch forcedState {
        case .connected: return .connected
        case .searching, .connecting: return .connecting
        case .failed(let failure): return .unreachable(failure)
        case .idle, .unlinked: return .unreachable(.notFound)
        }
    }

    static var forcedNearbyNames: [String]? {
        guard forcedState != nil else { return nil }
        return story == "waitingNearby" || story == "nearbyUnlinked" ? ["Living Room"] : []
    }

    static var opensDetail: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["SOUNDING_TV_TV_STORY_DETAIL"] == "1"
        #else
        false
        #endif
    }
}

extension PeerSignInPrompt {
    @MainActor
    static func resolveOnPhone(
        client: CompanionClient,
        offers: [LinkOfferBrowser.Offer],
        includesUnlinked: Bool = false
    ) -> PeerSignInPrompt? {
        resolve(
            state: AppleTVDebugStory.forcedState ?? client.state,
            name: AppleTVDebugStory.forcedName ?? client.linkedName,
            peerNeedsSignIn: AppleTVDebugStory.forcedPeerNeedsSignIn ?? client.peerNeedsSignIn,
            nearbyNames: AppleTVDebugStory.forcedNearbyNames
                ?? offers.filter { $0.kind == .tv && !$0.isSignedIn }.map(\.claimedName),
            includesUnlinked: includesUnlinked
        )
    }

    @MainActor
    func start(client: CompanionClient, pairing: DevicePairingFlow) {
        start(client: client) { pairing.signInNearbyTV() }
    }
}

// MARK: - Pairing flow

@MainActor
final class DevicePairingFlow: ObservableObject {
    enum Method: Equatable {
        case listen
        case scan
        case picked(DevicePickerSignIn.Invitation)
    }

    let nearby = LinkOfferBrowser(allowsRelinking: true)
    let listening: NearbyTVSignIn
    let sameAccount: SameAccountLinkModel
    let card: NearbyDeviceCardModel

    @Published var isPresented = false
    @Published var method: Method = .listen
    @Published private(set) var handshake: LinkConfirmationHandshake?
    @Published var request: LinkRequest?

    private(set) var peerName: String?
    private(set) var peerClass: DeviceClass = .tv

    init() {
        listening = NearbyTVSignIn(browser: nearby, forcedPhase: NearbyTVDebugStory.forcedPhase)
        sameAccount = SameAccountLinkModel(browser: nearby)
        card = NearbyDeviceCardModel(browser: nearby, sameAccount: sameAccount)
        card.onEvent = { [weak self] event in self?.handleCard(event) }
        #if DEBUG
        if NearbyTVDebugStory.forcedPhase != nil { isPresented = true }
        #endif
    }

    func addDevice() {
        method = .listen
        isPresented = true
    }

    func signInNearbyTV() {
        method = .listen
        isPresented = true
    }

    var isInvited: Bool {
        if case .picked = method { return true }
        return listening.invitedName != nil
    }

    func accept(_ invitation: TVSignInInvitation) {
        handshake?.stop()
        handshake = nil
        listening.stop()
        switch invitation {
        case .nearby(let request):
            listening.invitedName = request.tvName
            listening.preferredRendezvous = request.rendezvous
            method = .listen
        case .picked(let picked):
            listening.invitedName = nil
            listening.preferredRendezvous = nil
            method = .picked(picked)
        }
        TVSignInLiveActivityController.shared.begin(tvName: invitation.tvName, kind: invitation.kind)
        isPresented = true
    }

    func confirm(_ offer: LinkOfferBrowser.Offer) {
        handshake?.stop()
        handshake = LinkConfirmationHandshake(offer: offer)
        isPresented = true
    }

    func linkSameAccountTV() {
        guard let offer = sameAccount.accept() else { return }
        confirm(offer)
    }

    func link(_ request: NearbyLinkRequest) {
        guard !isPresented, self.request == nil else { return }
        card.linkWhenSeen(name: request.tvName, kind: request.tvKind, within: Self.notificationLinkWindow)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.notificationLinkWindow))
            guard let self, self.card.isWaitingToLink(name: request.tvName, kind: request.tvKind) else { return }
            self.card.cancelPendingLink()
            guard !self.isPresented, self.request == nil else { return }
            self.addDevice()
        }
    }

    private static let notificationLinkWindow: TimeInterval = 15

    var showsNearbyCard: Bool { !isPresented && request == nil }

    private func handleCard(_ event: NearbyDeviceCardModel.Event) {
        switch event {
        case .began(let candidate):
            TVSignInLiveActivityController.shared.begin(tvName: candidate.name, kind: candidate.kind)
        case .failed:
            TVSignInLiveActivityController.shared.abandon()
        case .cancelled:
            TVSignInLiveActivityController.shared.cancel()
        case .linked(let linked):
            link(sessionId: linked.sessionId, secret: linked.secret, peerName: linked.name, peerClass: linked.kind)
        case .linkSameAccount:
            linkSameAccountTV()
        case .useCode:
            TVSignInLiveActivityController.shared.cancel()
            listening.stop()
            method = .scan
            isPresented = true
        }
    }

    private var isHandingOff = false

    func dismiss() {
        if !isHandingOff { sameAccount.handshakeEnded(succeeded: false) }
        isHandingOff = false
        handshake?.stop()
        handshake = nil
        listening.stop()
        listening.invitedName = nil
        listening.preferredRendezvous = nil
        if case .picked = method { method = .listen }
        isPresented = false
        TVSignInLiveActivityController.shared.cancel()
    }

    func link(sessionId: String, secret: Data, peerName: String? = nil, peerClass: DeviceClass = .tv) {
        self.peerName = peerName
        self.peerClass = peerClass
        TVSignInLiveActivityController.shared.track(sessionId: sessionId)
        isHandingOff = true
        dismiss()
        DispatchQueue.main.async {
            self.request = LinkRequest(sessionId: sessionId, secret: secret)
        }
    }

    @discardableResult
    func link(url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return "That link isn't valid. Scan the code on your Apple TV again."
        }
        guard let session = queryItems.first(where: { $0.name == "session" })?.value,
              let secretBase64 = queryItems.first(where: { $0.name == "secret" })?.value,
              let secret = SessionCredentials.decodeSecret(secretBase64) else {
            return "That link is missing its session details. Scan the code on your Apple TV again."
        }
        link(sessionId: session, secret: secret)
        return nil
    }
}

struct DevicePairingPresenter: ViewModifier {
    @ObservedObject var flow: DevicePairingFlow
    var enabled = true

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(
                get: { enabled && flow.isPresented },
                set: { if enabled { flow.isPresented = $0 } }
            ), onDismiss: { flow.dismiss() }) {
                AddDeviceSheet(flow: flow)
            }
            .sheet(item: Binding(
                get: { enabled ? flow.request : nil },
                set: { if enabled { flow.request = $0 } }
            )) { request in
                NavigationStack {
                    SoundCloudLoginView(
                        sessionId: request.sessionId,
                        sessionSecret: request.secret,
                        peerName: flow.peerName,
                        peerClass: flow.peerClass,
                        onComplete: {
                            flow.request = nil
                            TVSignInLiveActivityController.shared.abandon()
                        }
                    )
                }
            }
    }
}

extension View {
    func devicePairing(_ flow: DevicePairingFlow, enabled: Bool = true) -> some View {
        modifier(DevicePairingPresenter(flow: flow, enabled: enabled))
    }
}

// MARK: - Devices

struct PhoneDevicesView: View {
    @EnvironmentObject private var client: CompanionClient
    @EnvironmentObject private var pairing: DevicePairingFlow
    @EnvironmentObject private var nearby: LinkOfferBrowser
    @ObservedObject private var notifications = TVSignInNotifications.shared

    @State private var forgetting: LinkedCompanionStore.LinkRecord?
    @State private var showsRemote = PhoneDevicesView.debugOpensRemote
    @State private var detail: String? = AppleTVDebugStory.opensDetail ? AppleTVDebugStory.detailSessionId : nil

    private static var debugOpensRemote: Bool {
        #if DEBUG
        return RemoteFixture.current != nil && ProcessInfo.processInfo.environment["SOUNDING_TV_REMOTE_OPEN"] == "1"
        #else
        return false
        #endif
    }

    private var rows: [LinkedCompanionStore.LinkRecord] { AppleTVDebugStory.links(client: client) }

    @EnvironmentObject private var sameAccount: SameAccountLinkModel

    var body: some View {
        List {
            if let candidate = sameAccount.offer.suggestion {
                Section {
                    SameAccountLinkRow(name: candidate.name) { pairing.linkSameAccountTV() }
                        .swipeActions(edge: .trailing) {
                            Button("Not Now") { sameAccount.dismiss() }
                        }
                }
            } else if case .failed(let candidate, let message) = sameAccount.offer.phase {
                Section {
                    ContentUnavailableView {
                        Label("Couldn't Link \(candidate.name)", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") { sameAccount.retry() }
                        Button("Not Now") { sameAccount.dismiss() }
                    }
                }
            }
            Section {
                ForEach(rows) { record in
                    NavigationLink(value: record.sessionId) {
                        DeviceStatusRow(
                            name: record.peerName,
                            symbolName: record.peerClass.symbolName,
                            status: AppleTVDebugStory.status(of: record, client: client, offers: nearby.offers),
                            accountLine: record.accountLine(client: client)
                        )
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Forget", role: .destructive) { forgetting = record }
                    }
                }
                Button("Add Apple TV…") { pairing.addDevice() }
            } header: {
                Text("Devices")
            } footer: {
                if rows.isEmpty {
                    Text("Link an Apple TV to play music there and control it from this \(DeviceClass.current.displayName).")
                }
            }
            if notifications.needsPriming {
                Section {
                    Button("Turn On Sign-In Requests…") { notifications.isPriming = true }
                } footer: {
                    Text("Get a notification when an Apple TV on your iCloud account needs signing in.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: PhoneChrome.floatingClearance) }
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: String.self) { sessionId in
            PhoneDeviceDetailView(sessionId: sessionId)
        }
        .navigationDestination(item: $detail) { sessionId in
            PhoneDeviceDetailView(sessionId: sessionId)
        }
        .forgetDeviceDialog($forgetting) { record in client.forget(sessionId: record.sessionId) }
        .task {
            client.connect()
            client.refreshLinkStatuses()
        }
        .navigationDestination(isPresented: $showsRemote) {
            RemoteControlView(client: client) { pairing.addDevice() }
        }
    }
}

private struct PhoneDeviceDetailView: View {
    let sessionId: String

    @EnvironmentObject private var client: CompanionClient
    @EnvironmentObject private var pairing: DevicePairingFlow
    @EnvironmentObject private var nearby: LinkOfferBrowser
    @Environment(\.dismiss) private var dismiss

    @State private var forgetting: LinkedCompanionStore.LinkRecord?

    private var record: LinkedCompanionStore.LinkRecord? {
        AppleTVDebugStory.links(client: client).first { $0.sessionId == sessionId }
    }
    private var isActive: Bool { client.isActive(sessionId) || (AppleTVDebugStory.forcedState != nil && client.links.isEmpty) }
    private var status: LinkStatus? {
        record.map { AppleTVDebugStory.status(of: $0, client: client, offers: nearby.offers) }
    }
    private var signInPrompt: PeerSignInPrompt? {
        guard isActive else {
            guard let record, status == .needsSignIn else { return nil }
            return .linked(name: record.peerName)
        }
        return AppleTVDebugStory.forcedState == nil
            ? PeerSignInPrompt.resolveOnPhone(client: client, offers: nearby.offers)
            : (AppleTVDebugStory.forcedPeerNeedsSignIn == true ? .linked(name: record?.peerName ?? "") : nil)
    }

    var body: some View {
        Group {
            if let record {
                form(record)
            } else {
                ContentUnavailableView("Not Linked", systemImage: DeviceClass.tv.symbolName)
            }
        }
        .navigationTitle(record?.peerName ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard AppleTVDebugStory.opensForget else { return }
            try? await Task.sleep(for: .milliseconds(600))
            forgetting = record
        }
    }

    private func form(_ record: LinkedCompanionStore.LinkRecord) -> some View {
        List {
            Section {
                NavigationLink {
                    RemoteControlView(client: client, sessionId: record.sessionId)
                } label: {
                    Label("Remote", systemImage: "appletvremote.gen4.fill")
                }
            }

            Section {
                LabeledContent("Name", value: record.peerName)
                LabeledContent("Type", value: record.peerClass.displayName)
                LabeledContent("Status") {
                    Text(status?.title ?? "")
                        .foregroundStyle(status?.isHealthy == true ? Color.green : Color.secondary)
                }
            }

            LinkedDeviceAccountSection(client: client, record: record)

            if let signInPrompt {
                Section {
                    Button {
                        if isActive {
                            signInPrompt.start(client: client, pairing: pairing)
                        } else {
                            client.select(sessionId: record.sessionId)
                            Task {
                                if await client.waitUntilReachable(timeout: .seconds(8)) { client.requestPeerSignIn() }
                            }
                        }
                    } label: {
                        HStack {
                            Text(signInPrompt.copy(client: client)?.action ?? "Sign In This \(record.peerClass.displayName)")
                            Spacer(minLength: 0)
                            if client.isRequestingPeerSignIn, isActive { ProgressView() }
                        }
                    }
                    .disabled(client.isRequestingPeerSignIn && isActive)
                } footer: {
                    switch signInPrompt {
                    case .linked:
                        if let copy = signInPrompt.copy(client: client) {
                            Text("\(copy.title) \(copy.footer)")
                        } else {
                            Text("\(record.peerName) is waiting to sign in. It'll use the SoundCloud account on this \(DeviceClass.current.displayName).")
                        }
                    case .nearby:
                        Text("\(record.peerName) is waiting to sign in. Keep this \(DeviceClass.current.displayName) close to it.")
                    }
                }
            } else if case .unreachable(let failure) = status {
                Section {
                    Button("Try Again") { client.select(sessionId: record.sessionId) }
                } footer: {
                    Text(failure.message())
                }
            }

            Section {
                Button("Forget This \(record.peerClass.displayName)", role: .destructive) {
                    forgetting = record
                }
                .forgetDeviceDialog($forgetting) { record in
                    client.forget(sessionId: record.sessionId)
                    dismiss()
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: PhoneChrome.floatingClearance) }
    }
}

private struct DeviceStatusRow: View {
    let name: String
    let symbolName: String
    let status: LinkStatus
    var accountLine: String? = nil

    var body: some View {
        LabeledContent {
            Text(status.title)
                .foregroundStyle(status.isHealthy ? Color.green : Color.secondary)
        } label: {
            Label {
                Text(name)
                if let accountLine { Text(accountLine) }
            } icon: {
                Image(systemName: symbolName)
            }
        }
    }
}

private extension View {
    func forgetDeviceDialog(
        _ record: Binding<LinkedCompanionStore.LinkRecord?>,
        onForget: @escaping (LinkedCompanionStore.LinkRecord) -> Void
    ) -> some View {
        confirmationDialog(
            "Forget \(record.wrappedValue?.peerName ?? "")?",
            isPresented: Binding(get: { record.wrappedValue != nil }, set: { if !$0 { record.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: record.wrappedValue
        ) { linked in
            Button("Forget", role: .destructive) { onForget(linked) }
            Button("Cancel", role: .cancel) {}
        } message: { linked in
            Text("\(linked.peerName) forgets this \(DeviceClass.current.displayName) too. Link it again to play there or control it.")
        }
    }
}

func deviceStatusText(_ state: CompanionClient.State, needsSignIn: Bool = false) -> String {
    if needsSignIn, state != .unlinked { return LinkStatus.needsSignIn.title }
    switch state {
    case .unlinked:               return "None"
    case .idle:                   return "Not Connected"
    case .searching, .connecting: return LinkStatus.connecting.title
    case .connected:              return LinkStatus.connected.title
    case .failed(let failure):    return LinkStatus.unreachable(failure).title
    }
}

struct SameAccountLinkRow: View {
    let name: String
    let onLink: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label {
                Text("\(name) is signed in to your account. Link it?")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: DeviceClass.tv.symbolName)
            }
            Spacer(minLength: 8)
            Button("Link", action: onLink)
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Link \(name)")
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Link \(name)", onLink)
    }
}

// MARK: - Add Apple TV

private struct AddDeviceSheet: View {
    @ObservedObject var flow: DevicePairingFlow
    @ObservedObject private var nearby: LinkOfferBrowser
    @Environment(\.dismiss) private var dismiss

    @State private var scanError: String?

    init(flow: DevicePairingFlow) {
        self.flow = flow
        _nearby = ObservedObject(wrappedValue: flow.nearby)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let handshake = flow.handshake {
                    CodeComparisonContent(handshake: handshake) { sessionId, secret in
                        flow.link(sessionId: sessionId, secret: secret, peerName: handshake.claimedName, peerClass: handshake.kind)
                    } onDecline: {
                        dismiss()
                    }
                    .padding(24)
                } else if case .picked(let invitation) = flow.method {
                    PickedTVConfirmation(invitation: invitation) {
                        guard let secret = invitation.secret else { return }
                        flow.link(sessionId: invitation.sessionId, secret: secret, peerName: invitation.tvName, peerClass: invitation.kind)
                    } onCancel: {
                        dismiss()
                    }
                } else if flow.method == .listen {
                    NearbyTVSignInView(model: flow.listening, nearby: flow.nearby) {
                        flow.listening.stop()
                        flow.method = .scan
                    } onCancel: {
                        dismiss()
                    } onLinked: { linked in
                        flow.link(sessionId: linked.sessionId, secret: linked.secret, peerName: linked.name, peerClass: linked.kind)
                    } onUseCode: { offer in
                        flow.confirm(offer)
                    }
                } else {
                    scanContent
                        .padding(24)
                }
            }
            .navigationTitle(flow.isInvited ? "Sign In Apple TV" : "Add Apple TV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    private var scanContent: some View {
        PairingSheetLayout(instruction: instruction) {
            if nearby.offer != nil {
                Image(systemName: DeviceClass.tv.symbolName)
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            } else if DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
                PairingCodeScanner { url in
                    if let message = flow.link(url: url) { scanError = message }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                Image(systemName: "qrcode.viewfinder")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        } action: {
            if let offer = nearby.offer {
                PairingActionButton("Confirm Code") { flow.confirm(offer) }
            } else if !(DataScannerViewController.isSupported && DataScannerViewController.isAvailable) {
                Text("Use the Camera app to scan the code, then tap the Sounding link.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Listen for Apple TV") { flow.method = .listen }
        }
    }

    private var instruction: String {
        if let offer = nearby.offer {
            return "\(offer.displayIdentity) is ready to link."
        }
        if let scanError { return scanError }
        return "Open Sounding on your Apple TV and scan its code."
    }
}

struct SignInRequestsPrimingView: View {
    @ObservedObject var notifications: TVSignInNotifications
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Sign In Apple TVs from Here", systemImage: "bell.badge")
            } description: {
                Text("When an Apple TV on your iCloud account needs signing in, or is on and not linked to this \(DeviceClass.current.displayName) yet, you get a notification. Tap it to sign in or link. It also tells you when your SoundCloud account signs in on a new device.")
            } actions: {
                Button("Continue") {
                    Task { await notifications.requestAuthorization() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button("Not Now") { dismiss() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }
}

private struct PickedTVConfirmation: View {
    let invitation: DevicePickerSignIn.Invitation
    let onSignIn: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(invitation.tvName, systemImage: invitation.kind.symbolName)
        } description: {
            Text("Sign in to Sounding on this \(invitation.kind.displayName)?")
        } actions: {
            Button("Sign In", action: onSignIn)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Button("Not Now", action: onCancel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CodeComparisonContent: View {
    @ObservedObject var handshake: LinkConfirmationHandshake
    let onLinked: (String, Data) -> Void
    let onDecline: () -> Void

    var body: some View {
        PairingSheetLayout(instruction: handshake.instruction) {
            switch handshake.state {
            case .awaitingComparison(let code):
                Text(LinkConfirmationHandshake.codeGroups(code).joined(separator: "  "))
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .accessibilityLabel("Code \(LinkConfirmationHandshake.codeGroups(code).joined(separator: ", "))")
            case .failed:
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            default:
                ProgressView()
                    .controlSize(.large)
            }
        } action: {
            switch handshake.state {
            case .awaitingComparison:
                PairingActionButton("It Matches") { handshake.confirm() }
                Button("It Doesn't Match", role: .destructive) {
                    handshake.decline()
                    onDecline()
                }
            case .failed:
                PairingActionButton("Try Again") { handshake.start() }
            default:
                EmptyView()
            }
        }
        .onAppear { handshake.start() }
        .onChange(of: handshake.state) { _, state in
            if case .succeeded(let sessionId, let secret, _) = state {
                onLinked(sessionId, secret)
            }
        }
    }
}

private struct PairingSheetLayout<Middle: View, Action: View>: View {
    let instruction: String
    @ViewBuilder let middle: () -> Middle
    @ViewBuilder let action: () -> Action

    var body: some View {
        VStack(spacing: 28) {
            Text(instruction)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            middle()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            action()
        }
    }
}

private struct PairingActionButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}

private struct PairingCodeScanner: UIViewControllerRepresentable {
    let onURL: (URL) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onURL: onURL) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onURL: (URL) -> Void
        private var delivered = false

        init(onURL: @escaping (URL) -> Void) {
            self.onURL = onURL
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !delivered else { return }
            for item in addedItems {
                guard case .barcode(let barcode) = item,
                      let payload = barcode.payloadStringValue,
                      let url = URL(string: payload) else { continue }
                delivered = true
                dataScanner.stopScanning()
                onURL(url)
                return
            }
        }
    }
}
