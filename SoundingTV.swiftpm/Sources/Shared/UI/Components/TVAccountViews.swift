import SwiftUI
import Combine

// MARK: - Sign-in prompt

enum PeerSignInPrompt: Equatable {
    case linked(name: String)
    case nearby(name: String)

    var name: String {
        switch self {
        case .linked(let name), .nearby(let name): return name
        }
    }

    static func resolve(
        state: CompanionClient.State,
        name: String,
        peerNeedsSignIn: Bool,
        nearbyNames: [String],
        includesUnlinked: Bool = false
    ) -> PeerSignInPrompt? {
        switch state {
        case .unlinked:
            guard includesUnlinked, let nearby = nearbyNames.first else { return nil }
            return .nearby(name: nearby)
        case .connected:
            return peerNeedsSignIn ? .linked(name: name) : nil
        default:
            let isWaiting = nearbyNames.contains { $0.localizedCaseInsensitiveCompare(name) == .orderedSame }
            return isWaiting ? .nearby(name: name) : nil
        }
    }

    @MainActor
    static func resolve(
        client: CompanionClient,
        offers: [LinkOfferBrowser.Offer],
        includesUnlinked: Bool = false
    ) -> PeerSignInPrompt? {
        resolve(
            state: client.state,
            name: client.linkedName,
            peerNeedsSignIn: client.peerNeedsSignIn,
            nearbyNames: offers.filter { $0.kind == .tv && !$0.isSignedIn }.map(\.claimedName),
            includesUnlinked: includesUnlinked
        )
    }

    @MainActor
    func copy(client: CompanionClient) -> TVAccountCopy.NeedsSignIn? {
        guard case .linked = self, let mine = CompanionClient.myAccount else { return nil }
        let last: PeerAccount?
        if let sessionId = client.activeSessionId, case .needsSignIn(let previous) = client.tvAccount(for: sessionId) {
            last = previous
        } else {
            last = nil
        }
        return TVAccountCopy.needsSignIn(tv: name, last: last, mine: mine)
    }

    @MainActor
    func start(client: CompanionClient, signInNearby: () -> Void) {
        switch self {
        case .linked: client.requestPeerSignIn()
        case .nearby: signInNearby()
        }
    }
}

// MARK: - Auto-link

@MainActor
final class TVAutoLinker: ObservableObject {
    @Published private(set) var linkedName: String?
    @Published private(set) var isAttempting = false

    private var attempted: Set<String> = []
    private var handshake: LinkConfirmationHandshake?
    private var watch: AnyCancellable?
    private var deadline: Task<Void, Never>?
    private let linker = CompanionLinker()

    var isRunning: Bool { handshake != nil }

    func consider(
        _ offers: [LinkOfferBrowser.Offer],
        isForeground: Bool,
        showingOtherSheet: Bool,
        dismissed: (LinkOfferBrowser.Offer) -> Bool
    ) {
        guard handshake == nil, let accountId = SameAccountLinkModel.accountId, !accountId.isEmpty else { return }
        let ledger = KnownLinkLedger.load()
        let linked = SameAccountLinkModel.linkedIdentities()
        let holdsKey = !LinkOwnerKeyStore.usableKeys().isEmpty
        let deviceId = LinkPeerIdentity.localDeviceId(defaults: .sounding)
        for offer in offers where offer.kind == .tv {
            let identity = KnownLinkLedger.identity(name: offer.claimedName, kind: offer.kind)
            let input = AutoLinkPolicy.Input(
                isSignedIn: true,
                isForeground: isForeground,
                holdsLinkKey: holdsKey,
                hintMatches: offer.accountHint?.matches(accountId: accountId) == true,
                listedAsLinked: offer.accountHint?.isLinked(toDeviceId: deviceId) == true,
                alreadyLinked: linked.contains(SameAccountLinkOffer.identity(name: offer.claimedName, kind: offer.kind)),
                dismissed: dismissed(offer),
                showingOtherSheet: showingOtherSheet,
                attemptedThisLaunch: attempted.contains(identity),
                knownLink: ledger.status(of: identity, accountTag: PeerAccount.tag(userId: accountId))
            )
            guard AutoLinkPolicy.shouldAttempt(input) else { continue }
            attempted.insert(identity)
            run(offer)
            return
        }
    }

    private func run(_ offer: LinkOfferBrowser.Offer) {
        Log.link.info("[AutoLink] re-linking \(offer.claimedName, privacy: .public) without asking")
        let handshake = LinkConfirmationHandshake(offer: offer)
        self.handshake = handshake
        isAttempting = true
        watch = handshake.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.handshakeChanged(state) }
        handshake.start()
        deadline = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(AutoLinkPolicy.timeout))
            guard !Task.isCancelled else { return }
            self?.finish(linked: nil)
        }
    }

    private func handshakeChanged(_ state: LinkConfirmationHandshake.State) {
        guard let handshake else { return }
        switch state {
        case .awaitingComparison where !handshake.isOwnerVerified:
            handshake.decline()
            finish(linked: nil)
        case .succeeded(let sessionId, let secret, let tvName):
            guard let session = DeviceSessionStore.load(), session.isUsable else {
                finish(linked: nil)
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.linker.authorize(sessionId: sessionId, secret: secret, tvName: tvName, session: session)
                if case .completed(let name) = self.linker.state {
                    self.finish(linked: name)
                } else {
                    self.finish(linked: nil)
                }
            }
        case .failed, .declined:
            finish(linked: nil)
        default:
            break
        }
    }

    private func finish(linked name: String?) {
        deadline?.cancel()
        deadline = nil
        watch = nil
        if name == nil { handshake?.stop() }
        handshake = nil
        isAttempting = false
        guard let name else { return }
        linkedName = name
        AccessibilityNotification.Announcement(TVAccountCopy.linkedCapsule(tv: name)).post()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if self?.linkedName == name { self?.linkedName = nil }
        }
    }
}

struct LinkedCapsule: ViewModifier {
    @ObservedObject var autoLinker: TVAutoLinker

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let name = autoLinker.linkedName {
                    Label(TVAccountCopy.linkedCapsule(tv: name), systemImage: DeviceClass.tv.symbolName)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: Capsule())
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.smooth, value: autoLinker.linkedName)
    }
}

// MARK: - Choice, refusal and switch prompts

struct TVAccountPrompts: ViewModifier {
    @ObservedObject var router: OutputRouter
    @ObservedObject var client: CompanionClient
    var isEnabled = true

    private var confirmingSwitch: Bool { isEnabled && client.accountSwitch.phase == .confirming }

    private var switchTVName: String {
        client.links.first { $0.sessionId == client.accountSwitchSessionId }?.peerName ?? DeviceClass.tv.displayName
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                router.accountChoice?.choice.title ?? "",
                isPresented: Binding(
                    get: { isEnabled && router.accountChoice != nil },
                    set: { if !$0 { router.answerAccountChoice(.cancel) } }
                ),
                titleVisibility: .visible,
                presenting: router.accountChoice
            ) { request in
                Button(request.choice.proceed) { router.answerAccountChoice(.proceed) }
                if request.canSwitch {
                    Button(request.choice.switchAction) { router.answerAccountChoice(.switchAccount) }
                }
                Button("Cancel", role: .cancel) { router.answerAccountChoice(.cancel) }
            } message: { request in
                Text(request.choice.message)
            }
            .alert(
                router.accountRefusal?.alert.title ?? "",
                isPresented: Binding(
                    get: { isEnabled && router.accountRefusal != nil },
                    set: { if !$0 { router.accountRefusal = nil } }
                ),
                presenting: router.accountRefusal
            ) { refusal in
                if let action = refusal.switchAction {
                    Button(action) { client.beginAccountSwitch(sessionId: refusal.sessionId) }
                }
                Button("OK", role: .cancel) {}
            } message: { refusal in
                Text(refusal.alert.message)
            }
            .alert(
                switchConfirmation?.title ?? "",
                isPresented: Binding(
                    get: { confirmingSwitch },
                    set: { if !$0, confirmingSwitch { client.cancelAccountSwitch() } }
                ),
                presenting: switchConfirmation
            ) { _ in
                Button("Switch") { Task { await client.confirmAccountSwitch() } }
                Button("Cancel", role: .cancel) { client.cancelAccountSwitch() }
            } message: { confirmation in
                Text(confirmation.message)
            }
    }

    private var switchConfirmation: TVAccountCopy.Alert? {
        guard confirmingSwitch, let sessionId = client.accountSwitchSessionId, let mine = CompanionClient.myAccount else { return nil }
        return TVAccountCopy.confirmSwitch(tv: switchTVName, theirs: client.tvAccount(for: sessionId).account, mine: mine)
    }
}

extension View {
    func tvAccountPrompts(router: OutputRouter, isEnabled: Bool = true) -> some View {
        modifier(TVAccountPrompts(router: router, client: router.client, isEnabled: isEnabled))
    }

    func linkedCapsule(_ autoLinker: TVAutoLinker) -> some View {
        modifier(LinkedCapsule(autoLinker: autoLinker))
    }
}

// MARK: - Devices

struct TVAccountSwitchStatus: View {
    @ObservedObject var client: CompanionClient
    let sessionId: String
    let tvName: String

    var body: some View {
        if client.accountSwitchSessionId == sessionId {
            switch client.accountSwitch.phase {
            case .waiting, .sending, .validating:
                HStack(spacing: 10) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(TVAccountCopy.waiting(tv: tvName))
                        Text(TVAccountCopy.waitingFooter(tv: tvName))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            case .failed(let failure):
                VStack(alignment: .leading, spacing: 6) {
                    Text(TVAccountCopy.switchOutcome(failure, tv: tvName, theirs: client.tvAccount(for: sessionId).account))
                    if failure == .timedOut || failure == .unavailable || failure == .dropped {
                        Button("Try Again") { client.beginAccountSwitch(sessionId: sessionId) }
                    }
                }
            case .done:
                if let mine = CompanionClient.myAccount {
                    Text(TVAccountCopy.switched(tv: tvName, mine: mine))
                }
            case .idle, .confirming:
                EmptyView()
            }
        }
    }
}

struct LinkedDeviceAccountSection: View {
    @ObservedObject var client: CompanionClient
    let record: LinkedCompanionStore.LinkRecord

    private var relation: TVAccountRelation { client.relation(for: record.sessionId) }

    var body: some View {
        if case .differentAccounts(let theirs, let mine) = relation {
            Section {
                LabeledContent(TVAccountCopy.accountSectionLabel, value: theirs?.displayName ?? TVAccountCopy.anotherAccountStatus)
                if client.canSwitchAccount(of: record.sessionId), !client.accountSwitch.isBusy {
                    Button(TVAccountCopy.switchAction(tv: record.peerName, mine: mine)) {
                        client.beginAccountSwitch(sessionId: record.sessionId)
                    }
                }
                TVAccountSwitchStatus(client: client, sessionId: record.sessionId, tvName: record.peerName)
            } header: {
                Text("Account")
            } footer: {
                Text(TVAccountCopy.accountSectionFooter(mine: mine))
            }
        } else if client.accountSwitchSessionId == record.sessionId, client.accountSwitch.phase != .idle {
            Section {
                TVAccountSwitchStatus(client: client, sessionId: record.sessionId, tvName: record.peerName)
            }
        }
    }
}

extension LinkedCompanionStore.LinkRecord {
    @MainActor
    func accountLine(client: CompanionClient) -> String? {
        TVAccountCopy.playOnSubtitle(client.relation(for: sessionId))
    }
}

// MARK: - Continue as

@MainActor
final class ContinueAsOffer: ObservableObject {
    enum Phase: Equatable {
        case idle
        case working
        case failed(String)
    }

    @Published private(set) var offer: SessionContinueOffer? = SessionContinueOffer.load()
    @Published private(set) var phase: Phase = .idle

    func refresh(isSignedOut: Bool) {
        let stored = isSignedOut ? SessionContinueOffer.load() : nil
        if offer != stored { offer = stored }
    }

    func accept(source: SoundCloudCredentialSource = .shared) async {
        guard let offer, phase != .working else { return }
        phase = .working
        let remote = await SoundCloudSessionRenewalTimeout.value(within: .seconds(15)) {
            await SynchronizationCoordinator.shared.latestSyncedSession()
        }
        guard let remote, remote.accountTag == offer.accountTag else {
            phase = .failed(TVAccountCopy.continueUnreachable)
            return
        }
        switch await SoundCloudAPI.shared.validateToken(remote.oauthToken) {
        case .valid:
            SessionSyncBookkeeping.clearLocalSignOut()
            await source.adoptSyncedSession(remote)
            phase = .idle
            self.offer = nil
        case .rejected:
            SessionContinueOffer.save(nil)
            phase = .failed(TVAccountCopy.continueExpired(offer.account))
            self.offer = nil
        case .unavailable:
            phase = .failed(TVAccountCopy.continueUnreachable)
        }
    }
}

struct ContinueAsOfferView: View {
    @ObservedObject var model: ContinueAsOffer

    var body: some View {
        if model.offer == nil, case .failed(let message) = model.phase {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } else if let offer = model.offer {
            VStack(spacing: 12) {
                VStack(spacing: 4) {
                    Label(offer.account.displayName, systemImage: "person.crop.circle.fill")
                        .font(.headline)
                    if let writer = offer.writerName {
                        Text(TVAccountCopy.signedInOn(writer))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    Task { await model.accept() }
                } label: {
                    HStack(spacing: 8) {
                        if model.phase == .working { ProgressView() }
                        Text(TVAccountCopy.continueAs(offer.account))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(model.phase == .working)
                if case .failed(let message) = model.phase {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }
}

enum LinkedTVAccounts {
    static func welcomeLine() -> String? {
        let records = TVAccountRecord.loadAll()
        for link in LinkedCompanionStore.loadAll() where link.peerClass == .tv {
            guard let record = records[link.sessionId], record.state == .signedIn, let account = record.account else { continue }
            return TVAccountCopy.welcomeLine(tv: link.peerName, account: account)
        }
        return nil
    }
}
