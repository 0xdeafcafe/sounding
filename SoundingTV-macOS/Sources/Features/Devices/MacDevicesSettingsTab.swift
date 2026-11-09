import SwiftUI
import Combine

struct MacDevicesSettingsTab: View {
    @EnvironmentObject private var credentials: SoundCloudCredentialSource
    @EnvironmentObject private var client: CompanionClient

    @ObservedObject private var linking = MacTVLinking.shared
    @StateObject private var linker = CompanionLinker()

    @State private var isAddingDevice = false
    @State private var forgetting: LinkedCompanionStore.LinkRecord?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            if let prompt = linking.prompt {
                Section {
                    MacSameAccountPromptRow(prompt: prompt) {
                        linking.performPrimary(from: .settings)
                    } onNotNow: {
                        linking.dismiss()
                    }
                }
            }
            Section {
                ForEach(client.links) { link in
                    MacLinkedDeviceRow(client: client, link: link) { forgetting = link }
                }
                Button("Add Apple TV…") { isAddingDevice = true }
            } header: {
                Text("Devices")
            } footer: {
                if client.links.isEmpty {
                    Text("Link an Apple TV to play music there and control it from this Mac.")
                }
            }
        }
        .formStyle(.grouped)
        .defaultScrollAnchor(.top, for: .alignment)
        .task {
            credentials.refreshFromStore()
            client.connect()
            client.refreshLinkStatuses()
            linking.nearby.startIfNeeded()
        }
        .onChange(of: client.links.map(\.sessionId)) { previous, current in
            if current.contains(where: { !previous.contains($0) }) { isAddingDevice = false }
        }
        .onChange(of: linker.state) { _, state in
            if case .failed(let message) = state { errorMessage = message }
        }
        .sheet(isPresented: $isAddingDevice) {
            MacAddDeviceSheet(
                nearby: linking.nearby,
                linker: linker,
                isSignedIn: !credentials.isSignedOut
            ) { sessionId, secret, name in
                authorize(sessionId: sessionId, secret: secret, tvName: name)
            }
            .frame(width: 440, height: 440)
        }
        .sheet(item: linking.confirmationBinding(for: .settings)) { confirmation in
            MacSameAccountLinkSheet(confirmation: confirmation, linking: linking, linker: linking.linker)
        }
        .alert("Couldn't Link", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            "Forget \(forgetting?.peerName ?? "")?",
            isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
            titleVisibility: .visible,
            presenting: forgetting
        ) { link in
            Button("Forget", role: .destructive) {
                client.forget(sessionId: link.sessionId)
                linker.reset()
            }
            Button("Cancel", role: .cancel) {}
        } message: { link in
            Text("\(link.peerName) forgets this Mac too. Link it again to play there or control it.")
        }
    }

    private func authorize(sessionId: String, secret: Data, tvName: String) {
        guard let session = DeviceSessionStore.load(), session.isUsable else {
            errorMessage = "Sign in to SoundCloud on this Mac first."
            return
        }
        Task {
            await linker.authorize(sessionId: sessionId, secret: secret, tvName: tvName, session: session)
        }
    }
}

private struct MacLinkedDeviceRow: View {
    @ObservedObject var client: CompanionClient
    let link: LinkedCompanionStore.LinkRecord
    let onForget: () -> Void

    private var status: LinkStatus { client.status(of: link.sessionId) }
    private var isActive: Bool { client.isActive(link.sessionId) }

    var body: some View {
        LabeledContent {
            HStack(spacing: 12) {
                Text(status.title)
                    .foregroundStyle(status.isHealthy ? Color.green : Color.secondary)
                if case .unreachable = status {
                    Button("Try Again") { client.select(sessionId: link.sessionId) }
                }
                Button("Forget…", role: .destructive, action: onForget)
            }
        } label: {
            Label(link.peerName, systemImage: link.peerClass.symbolName)
            if case .unreachable(let failure) = status, isActive {
                Text(failure.message())
            }
        }
        if status == .needsSignIn {
            LabeledContent("\(link.peerName) is waiting to sign in.") {
                HStack(spacing: 8) {
                    if client.isRequestingPeerSignIn, isActive {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button("Sign In This \(link.peerClass.displayName)") { signIn() }
                        .disabled(client.isRequestingPeerSignIn && isActive)
                }
            }
        }
    }

    private func signIn() {
        guard !isActive else {
            client.requestPeerSignIn()
            return
        }
        client.select(sessionId: link.sessionId)
        Task {
            if await client.waitUntilReachable(timeout: .seconds(8)) { client.requestPeerSignIn() }
        }
    }
}

private struct MacAddDeviceSheet: View {
    @ObservedObject var nearby: LinkOfferBrowser
    @ObservedObject var linker: CompanionLinker
    let isSignedIn: Bool
    let onConfirmed: (String, Data, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var handshake: LinkConfirmationHandshake?
    @State private var listensForChime = true
    @StateObject private var listening: NearbyTVSignIn

    init(
        nearby: LinkOfferBrowser,
        linker: CompanionLinker,
        isSignedIn: Bool,
        onConfirmed: @escaping (String, Data, String) -> Void
    ) {
        self.nearby = nearby
        self.linker = linker
        self.isSignedIn = isSignedIn
        self.onConfirmed = onConfirmed
        _listening = StateObject(wrappedValue: NearbyTVSignIn(browser: nearby))
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Add Apple TV")
                .font(.title2.weight(.semibold))
                .padding(.top, 24)

            Group {
                if let handshake {
                    MacCodeComparisonContent(handshake: handshake) { sessionId, secret in
                        self.handshake = nil
                        onConfirmed(sessionId, secret, handshake.claimedName)
                    } onDecline: {
                        self.handshake = nil
                    }
                } else if listensForChime, isSignedIn, !linker.state.isWorking {
                    MacNearbyTVSignInContent(model: listening, nearby: nearby) {
                        listening.stop()
                        listensForChime = false
                    } onCancel: {
                        dismiss()
                    } onLinked: { linked in
                        listensForChime = false
                        onConfirmed(linked.sessionId, linked.secret, linked.name)
                    } onPick: { offer in
                        listening.stop()
                        handshake = LinkConfirmationHandshake(offer: offer)
                    }
                } else {
                    waitingContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)

            HStack {
                Spacer()
                Button(linker.state.isWorking ? "Close" : "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .onChange(of: linker.state) { _, state in
            if case .completed = state { dismiss() }
        }
    }

    @ViewBuilder
    private var waitingContent: some View {
        if isSignedIn, linker.state == .idle {
            MacNearbyList(nearby: nearby) { offer in
                handshake = LinkConfirmationHandshake(offer: offer)
            } footer: {
                Button("Listen for Apple TV") { listensForChime = true }
                    .buttonStyle(.link)
            }
        } else {
            waitingStatus
        }
    }

    private var waitingStatus: some View {
        VStack(spacing: 20) {
            Text(instruction)
                .foregroundStyle(MacSecondaryStyle())
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if linker.state.isWorking {
                ProgressView()
                    .controlSize(.large)
            } else {
                Image(systemName: DeviceClass.tv.symbolName)
                    .font(.largeTitle)
                    .foregroundStyle(MacSecondaryStyle())
                    .accessibilityHidden(true)
            }

            if !isSignedIn {
                EmptyView()
            } else if let offer = nearby.offer {
                Button("Confirm Code") { handshake = LinkConfirmationHandshake(offer: offer) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(linker.state.isWorking)
            } else if !linker.state.isWorking {
                ProgressView()
                    .controlSize(.small)
            }

            if isSignedIn, !linker.state.isWorking {
                Button("Listen for Apple TV") { listensForChime = true }
                    .buttonStyle(.link)
            }
        }
    }

    private var instruction: String {
        if !isSignedIn { return "Sign in to SoundCloud on this Mac first." }
        switch linker.state {
        case .findingTV:   return "Finding your Apple TV…"
        case .connecting:  return "Connecting…"
        case .transferring: return "Linking…"
        case .completed(let name): return "\(name) is linked."
        case .failed(let message): return message
        case .idle: break
        }
        if let offer = nearby.offer { return "\(offer.displayIdentity) is ready to link." }
        return "Open Sounding on your Apple TV. It appears here when it's ready."
    }
}

private struct MacNearbyTVSignInContent: View {
    @ObservedObject var model: NearbyTVSignIn
    @ObservedObject var nearby: LinkOfferBrowser
    let onUseCode: () -> Void
    let onCancel: () -> Void
    let onLinked: (NearbyTVSignIn.Linked) -> Void
    let onPick: (LinkOfferBrowser.Offer) -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let microphoneSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { model.start() }
            .onDisappear { model.stop() }
            .onChange(of: model.linked) { _, linked in
                if let linked { onLinked(linked) }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .listening:
            MacNearbyList(nearby: nearby, hint: hint, onPick: onPick) {
                codeButton
                    .buttonStyle(.link)
            }

        case .needsPermission:
            ContentUnavailableView {
                Label("Listen for Your Apple TV", systemImage: "ear")
            } description: {
                Text("Your Apple TV plays a short chime. Sounding listens for it to find the TV, only while this window is open. Nothing is recorded or sent anywhere.")
            } actions: {
                Button("Continue") { model.continueAfterPriming() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                codeButton
            }

        case .permissionDenied:
            ContentUnavailableView {
                Label("Microphone Access Is Off", systemImage: "mic.slash")
            } description: {
                Text("To find your Apple TV by its chime, turn on Microphone for Sounding in System Settings.")
            } actions: {
                Button("Open System Settings") {
                    if let url = Self.microphoneSettings { openURL(url) }
                }
                .buttonStyle(.borderedProminent)
                codeButton
            }

        case .checking:
            ProgressView("Connecting…")
                .controlSize(.large)

        case .found(let name, let kind):
            ContentUnavailableView {
                Label(name, systemImage: kind.symbolName)
            } description: {
                Text("Sign in to Sounding on this \(kind.displayName)?")
            } actions: {
                Button("Sign In") { model.signIn() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Button("Not Now", action: onCancel)
            }

        case .signingIn(let name):
            ProgressView("Signing in \(name)…")
                .controlSize(.large)

        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Sign In", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { model.retry() }
                    .buttonStyle(.borderedProminent)
                codeButton
            }
        }
    }

    private var codeButton: some View {
        Button("Use a Code Instead", action: onUseCode)
    }

    private var hint: String? {
        guard model.isHearingNothing else { return nil }
        return "Open Sounding on your Apple TV, choose Add a Device and turn the volume up."
    }
}

private struct MacNearbyList<Footer: View>: View {
    @ObservedObject var nearby: LinkOfferBrowser
    var hint: String?
    let onPick: (LinkOfferBrowser.Offer) -> Void
    @ViewBuilder let footer: () -> Footer

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsGuidance = false

    private var offers: [LinkOfferBrowser.Offer] {
        nearby.distinctOffers.filter { $0.kind == .tv }
    }

    private var guidance: String? {
        if let hint { return hint }
        guard showsGuidance, offers.isEmpty else { return nil }
        return "Open Sounding on your Apple TV and keep this Mac nearby."
    }

    var body: some View {
        VStack(spacing: 12) {
            NearbySearchHeader(guidance: guidance)
            if offers.isEmpty {
                Spacer(minLength: 0)
            } else {
                Form {
                    Section("Nearby") {
                        ForEach(offers, id: \.sessionIdPrefix) { offer in
                            NearbyDeviceRow(offer: offer) { onPick(offer) }
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }
            footer()
        }
        .animation(reduceMotion ? nil : .smooth, value: offers.map(\.sessionIdPrefix))
        .animation(reduceMotion ? nil : .smooth, value: guidance)
        .task {
            try? await Task.sleep(for: .seconds(4))
            showsGuidance = true
        }
    }
}

@MainActor
final class MacTVLinking: ObservableObject {
    static let shared = MacTVLinking()

    enum Origin: Equatable {
        case window
        case settings
    }

    struct Confirmation: Identifiable {
        let id = UUID()
        let handshake: LinkConfirmationHandshake
        let origin: Origin
    }

    let nearby = LinkOfferBrowser(allowsRelinking: true)
    let linker = CompanionLinker()
    let sameAccount: SameAccountLinkModel
    let card: NearbyDeviceCardModel

    @Published private(set) var confirmation: Confirmation?
    @Published private(set) var isTransferring = false

    private var subscriptions: Set<AnyCancellable> = []
    private var isCardTransfer = false

    private init() {
        sameAccount = SameAccountLinkModel(browser: nearby)
        card = NearbyDeviceCardModel(browser: nearby, sameAccount: sameAccount)
        card.holdsCardDuringTransfer = true
        sameAccount.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        linker.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.observe(state) }
            .store(in: &subscriptions)
        card.onEvent = { [weak self] event in self?.handleCard(event) }
    }

    var prompt: SameAccountLinkPrompt? {
        #if DEBUG
        if let forced = Self.debugPrompt { return forced }
        #endif
        return SameAccountLinkPrompt(sameAccount.offer.phase)
    }

    func setForeground(_ foreground: Bool) {
        #if DEBUG
        if VisualFixtures.isEnabled { return }
        #endif
        sameAccount.setForeground(foreground)
        card.setForeground(foreground)
        if foreground { nearby.startIfNeeded() } else { nearby.stop() }
    }

    func performPrimary(from origin: Origin) {
        switch prompt {
        case .suggestion: link(from: origin)
        case .failed: sameAccount.retry()
        case nil: break
        }
    }

    func link(from origin: Origin) {
        guard confirmation == nil, let offer = sameAccount.accept() else { return }
        linker.reset()
        confirmation = Confirmation(handshake: LinkConfirmationHandshake(offer: offer), origin: origin)
    }

    func dismiss() {
        sameAccount.dismiss()
    }

    func confirmed(sessionId: String, secret: Data, name: String) {
        guard let session = DeviceSessionStore.load(), session.isUsable else {
            sameAccount.transferFailed(message: "Sign in to SoundCloud on this Mac first.")
            close()
            return
        }
        isTransferring = true
        Task { await linker.authorize(sessionId: sessionId, secret: secret, tvName: name, session: session) }
    }

    func cancel() {
        guard confirmation != nil else { return }
        if !isTransferring { sameAccount.handshakeEnded(succeeded: false) }
        close()
    }

    func confirmationBinding(for origin: Origin) -> Binding<Confirmation?> {
        Binding(
            get: { [weak self] in
                guard let confirmation = self?.confirmation, confirmation.origin == origin else { return nil }
                return confirmation
            },
            set: { [weak self] value in
                if value == nil { self?.cancel() }
            }
        )
    }

    private func observe(_ state: CompanionLinker.State) {
        if isCardTransfer {
            switch state {
            case .completed:
                isCardTransfer = false
                card.transferFinished(error: nil)
            case .failed(let message):
                isCardTransfer = false
                card.transferFinished(error: message)
            default:
                break
            }
            return
        }
        guard isTransferring else { return }
        switch state {
        case .completed:
            isTransferring = false
            close()
        case .failed(let message):
            isTransferring = false
            sameAccount.transferFailed(message: message)
            close()
        default:
            break
        }
    }

    private func handleCard(_ event: NearbyDeviceCardModel.Event) {
        switch event {
        case .began, .failed, .cancelled:
            break
        case .linked(let linked):
            guard let session = DeviceSessionStore.load(), session.isUsable else {
                card.transferFinished(error: "Sign in to SoundCloud on this Mac first.")
                return
            }
            isCardTransfer = true
            Task { await linker.authorize(sessionId: linked.sessionId, secret: linked.secret, tvName: linked.name, session: session) }
        case .linkSameAccount:
            afterCardCloses { $0.link(from: .window) }
        case .useCode(let candidate):
            guard let offer = nearby.offers.first(where: { $0.sessionIdPrefix == candidate.sessionIdPrefix }) else { return }
            afterCardCloses { $0.confirmCode(with: offer) }
        }
    }

    private func confirmCode(with offer: LinkOfferBrowser.Offer) {
        guard confirmation == nil else { return }
        linker.reset()
        confirmation = Confirmation(handshake: LinkConfirmationHandshake(offer: offer), origin: .window)
    }

    private func afterCardCloses(_ action: @escaping (MacTVLinking) -> Void) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self else { return }
            action(self)
        }
    }

    private func close() {
        confirmation?.handshake.stop()
        confirmation = nil
    }

    #if DEBUG
    private static var debugPrompt: SameAccountLinkPrompt? {
        switch ProcessInfo.processInfo.environment["SOUNDING_TV_MAC_SAME_ACCOUNT"] {
        case "suggested": return .suggestion(name: "Living Room")
        case "failed": return .failed(name: "Living Room", message: "Living Room didn't finish linking. Try again from Devices.")
        default: return nil
        }
    }
    #endif
}

struct MacSameAccountPromptRow: View {
    let prompt: SameAccountLinkPrompt
    let onPrimary: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Button("Not Now", action: onNotNow)
                Button(prompt.primaryAction, action: onPrimary)
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("\(prompt.primaryAction), \(prompt.name)")
            }
        } label: {
            Label(prompt.title, systemImage: DeviceClass.tv.symbolName)
            if let message = prompt.message {
                Text(message)
            }
        }
    }
}

struct MacSameAccountLinkSheet: View {
    let confirmation: MacTVLinking.Confirmation
    @ObservedObject var linking: MacTVLinking
    @ObservedObject var linker: CompanionLinker

    var body: some View {
        VStack(spacing: 0) {
            Text("Link \(confirmation.handshake.claimedName)")
                .font(.title2.weight(.semibold))
                .padding(.top, 24)

            Group {
                if linking.isTransferring {
                    ProgressView("Linking…")
                        .controlSize(.large)
                } else {
                    MacCodeComparisonContent(handshake: confirmation.handshake) { sessionId, secret in
                        linking.confirmed(sessionId: sessionId, secret: secret, name: confirmation.handshake.claimedName)
                    } onDecline: {
                        linking.cancel()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)

            HStack {
                Spacer()
                Button(linking.isTransferring ? "Close" : "Cancel") { linking.cancel() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 440, height: 320)
    }
}

private struct MacCodeComparisonContent: View {
    @ObservedObject var handshake: LinkConfirmationHandshake
    let onLinked: (String, Data) -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text(handshake.instruction)
                .foregroundStyle(MacSecondaryStyle())
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            switch handshake.state {
            case .awaitingComparison(let code):
                Text(LinkConfirmationHandshake.codeGroups(code).joined(separator: "  "))
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                HStack {
                    Button("It Doesn't Match", role: .destructive) {
                        handshake.decline()
                        onDecline()
                    }
                    Button("It Matches") { handshake.confirm() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            case .failed:
                Button("Try Again") { handshake.start() }
                    .buttonStyle(.borderedProminent)
            default:
                ProgressView()
                    .controlSize(.large)
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
