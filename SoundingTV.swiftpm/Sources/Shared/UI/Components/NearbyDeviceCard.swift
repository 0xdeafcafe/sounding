import SwiftUI
import Combine
import Network
import os

struct NearbyCardDismissals: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var dismissedAt: Date
        var lastSeenAt: Date
        var returned = false
    }

    static let cooldown: TimeInterval = 12 * 3_600
    static let awayGap: TimeInterval = 30 * 60
    static let lifetime: TimeInterval = 60 * 86_400
    private static let defaultsKey = "red.forbes.sounding.nearbyCard.notNow"
    private static let saveSpacing: TimeInterval = 300

    private(set) var entries: [String: Entry] = [:]
    private var savedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case entries
    }

    func suppresses(_ key: String, at now: Date) -> Bool {
        guard let entry = entries[key] else { return false }
        return !(entry.returned && now.timeIntervalSince(entry.dismissedAt) >= Self.cooldown)
    }

    mutating func dismiss(_ key: String, at now: Date, persist: Bool = true) {
        entries[key] = Entry(dismissedAt: now, lastSeenAt: now)
        entries = entries.filter { now.timeIntervalSince($0.value.lastSeenAt) < Self.lifetime }
        if persist { save(at: now) }
    }

    mutating func seen(_ key: String, at now: Date, persist: Bool = true) {
        guard var entry = entries[key] else { return }
        var changed = savedAt.map { now.timeIntervalSince($0) >= Self.saveSpacing } ?? true
        if !entry.returned,
           now.timeIntervalSince(entry.lastSeenAt) >= Self.awayGap,
           now.timeIntervalSince(entry.dismissedAt) >= Self.cooldown {
            entry.returned = true
            changed = true
        }
        entry.lastSeenAt = max(entry.lastSeenAt, now)
        entries[key] = entry
        if changed, persist { save(at: now) }
    }

    static func load() -> NearbyCardDismissals {
        guard let data = UserDefaults.sounding.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(NearbyCardDismissals.self, from: data) else { return NearbyCardDismissals() }
        return decoded
    }

    private mutating func save(at now: Date) {
        savedAt = now
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.sounding.set(data, forKey: Self.defaultsKey)
    }
}

@MainActor
final class NearbyLinkInbox: ObservableObject {
    static let shared = NearbyLinkInbox()

    @Published var pending: NearbyLinkRequest?
    let dismissed = PassthroughSubject<NearbyLinkRequest.Notice, Never>()

    func link(_ request: NearbyLinkRequest) {
        pending = request
    }

    func notNow(_ notice: NearbyLinkRequest.Notice) {
        guard let name = notice.tvName else { return }
        NearbyDeviceCardModel.rememberNotNow(kind: notice.tvKind, name: name)
        dismissed.send(notice)
    }
}

@MainActor
final class NearbyDeviceCardModel: ObservableObject {
    enum Purpose: Equatable {
        case signIn
        case link
    }

    struct Candidate: Equatable, Identifiable {
        let sessionIdPrefix: String
        let name: String
        let kind: DeviceClass
        let purpose: Purpose

        var id: String { "\(purpose == .signIn ? "sign-in" : "link")|\(name.lowercased())" }
    }

    enum Phase: Equatable {
        case offering
        case listening
        case connecting
        case found(name: String)
        case signingIn
        case done
        case failed(String)

        var isWorking: Bool {
            switch self {
            case .listening, .connecting, .signingIn: return true
            case .offering, .found, .done, .failed: return false
            }
        }
    }

    enum Event {
        case began(Candidate)
        case failed
        case cancelled
        case linked(NearbyTVSignIn.Linked)
        case linkSameAccount
        case useCode(Candidate)
    }

    @Published private(set) var candidate: Candidate?
    @Published private(set) var phase: Phase = .offering

    var onEvent: ((Event) -> Void)?
    var holdsCardDuringTransfer = false

    private let browser: LinkOfferBrowser
    private let sameAccount: SameAccountLinkModel
    private let listener: NearbyTVSignIn
    private let chimeRequest = ChimePlayRequest()
    private var closed: Set<String> = []
    private var shown: Set<String> = []
    private var dismissals = NearbyCardDismissals.load()
    private var requestedChime = false
    private var isForeground = false
    let autoLinker = TVAutoLinker()
    private var subscriptions: Set<AnyCancellable> = []
    private var flow: Set<AnyCancellable> = []
    private var presence: NWListener?
    private var finishTask: Task<Void, Never>?
    private var pendingLink: (key: String, until: Date)?

    init(browser: LinkOfferBrowser, sameAccount: SameAccountLinkModel) {
        self.browser = browser
        self.sameAccount = sameAccount
        listener = NearbyTVSignIn(browser: browser)
        browser.$offers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
        sameAccount.$offer
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
        SoundCloudCredentialSource.shared.$state
            .map(\.isSignedOut)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
        NearbyLinkInbox.shared.dismissed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] request in self?.dismissedOutside(request) }
            .store(in: &subscriptions)
        autoLinker.$linkedName
            .combineLatest(autoLinker.$isAttempting)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
    }

    static func rememberNotNow(kind: DeviceClass, name: String, at now: Date = Date()) {
        var stored = NearbyCardDismissals.load()
        stored.dismiss(deviceKey(kind, name), at: now)
    }

    func linkWhenSeen(name: String, kind: DeviceClass, within window: TimeInterval) {
        pendingLink = (Self.deviceKey(kind, name), Date().addingTimeInterval(window))
        refresh()
    }

    func isWaitingToLink(name: String, kind: DeviceClass) -> Bool {
        pendingLink?.key == Self.deviceKey(kind, name)
    }

    func cancelPendingLink() {
        pendingLink = nil
    }

    private func dismissedOutside(_ notice: NearbyLinkRequest.Notice) {
        dismissals = NearbyCardDismissals.load()
        if let candidate, candidate.purpose == .link, let name = notice.tvName, Self.ignoreKey(candidate) == Self.deviceKey(notice.tvKind, name), phase == .offering {
            close(candidate)
        } else {
            refresh()
        }
    }

    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        if foreground { LinkOwnerKeyCloud.shared.refreshIfNeeded() }
        updatePresence()
    }

    func didShow(_ shownCandidate: Candidate) {
        shown.insert(shownCandidate.id)
    }

    func primary() {
        guard let candidate else { return }
        switch (candidate.purpose, phase) {
        case (.link, _):
            close(candidate)
            onEvent?(.linkSameAccount)
        case (.signIn, .offering), (.signIn, .failed):
            beginSignIn(candidate)
        case (.signIn, .found):
            listener.signIn()
        case (.signIn, _):
            break
        }
    }

    func notNow() {
        guard let candidate else { return }
        let wasWorking = phase.isWorking || isFound
        stopFlow()
        if candidate.purpose == .link { sameAccount.dismiss() }
        dismissals.dismiss(Self.ignoreKey(candidate), at: Date())
        close(candidate)
        if wasWorking { onEvent?(.cancelled) }
    }

    func ignoreDevice() {
        guard let candidate else { return }
        var ignored = UserDefaults.sounding.dictionary(forKey: Self.ignoredKey) as? [String: Double] ?? [:]
        ignored[Self.ignoreKey(candidate)] = Date().addingTimeInterval(Self.ignoreDuration).timeIntervalSince1970
        UserDefaults.sounding.set(ignored, forKey: Self.ignoredKey)
        notNow()
    }

    private static let ignoredKey = "red.forbes.sounding.nearbyCard.ignored"
    private static let ignoreDuration: TimeInterval = 30 * 86_400

    private static func ignoreKey(_ candidate: Candidate) -> String {
        deviceKey(candidate.kind, candidate.name)
    }

    private static func deviceKey(_ kind: DeviceClass, _ name: String) -> String {
        "\(kind)|\(name.lowercased())"
    }

    private static func isIgnored(_ candidate: Candidate) -> Bool {
        let ignored = UserDefaults.sounding.dictionary(forKey: ignoredKey) as? [String: Double] ?? [:]
        guard let until = ignored[ignoreKey(candidate)] else { return false }
        return until > Date().timeIntervalSince1970
    }

    func useCode() {
        guard let candidate else { return }
        stopFlow()
        close(candidate)
        onEvent?(.useCode(candidate))
    }

    func transferFinished(error: String?) {
        guard holdsCardDuringTransfer, phase == .signingIn, candidate != nil else { return }
        if let error {
            phase = .failed(error)
            return
        }
        phase = .done
        finishTask?.cancel()
        finishTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self, self.phase == .done, let candidate = self.candidate else { return }
            self.close(candidate)
        }
    }

    private var isFound: Bool {
        if case .found = phase { return true }
        return false
    }

    private func close(_ closing: Candidate) {
        finishTask?.cancel()
        finishTask = nil
        closed.insert(closing.id)
        candidate = nil
        phase = .offering
        refresh()
    }

    private func refresh() {
        defer { updatePresence() }
        let now = Date()
        for offer in browser.offers where offer.kind == .tv {
            dismissals.seen(Self.deviceKey(offer.kind, offer.claimedName), at: now)
        }
        if isForeground, !SoundCloudCredentialSource.shared.isSignedOut {
            autoLinker.consider(browser.offers, isForeground: isForeground, showingOtherSheet: phase != .offering) { offer in
                let key = Self.deviceKey(offer.kind, offer.claimedName)
                return self.dismissals.suppresses(key, at: now)
            }
        }
        guard phase == .offering else { return }
        let next = nextCandidate(now: now)
        if let current = candidate, current.id != next?.id, shown.contains(current.id) {
            closed.insert(current.id)
        }
        if candidate != next { candidate = next }
        if let next, next.purpose == .link, let pendingLink, pendingLink.key == Self.ignoreKey(next) {
            self.pendingLink = nil
            guard pendingLink.until > now else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.candidate == next, self.phase == .offering else { return }
                self.primary()
            }
        }
    }

    private func nextCandidate(now: Date) -> Candidate? {
        if let suggestion = sameAccount.offer.suggestion, !autoLinker.isAttempting {
            let linkCandidate = Candidate(
                sessionIdPrefix: suggestion.sessionIdPrefix,
                name: suggestion.name,
                kind: suggestion.kind,
                purpose: .link
            )
            if isOffered(linkCandidate, now: now) { return linkCandidate }
        }
        guard !SoundCloudCredentialSource.shared.isSignedOut else { return nil }
        let signedIn = Set(browser.offers.filter(\.isSignedIn).map { Self.deviceKey($0.kind, $0.claimedName) })
        for offer in browser.distinctOffers where offer.kind == .tv && !offer.isSignedIn {
            let signInCandidate = Candidate(
                sessionIdPrefix: offer.sessionIdPrefix,
                name: offer.claimedName,
                kind: offer.kind,
                purpose: .signIn
            )
            guard !signedIn.contains(Self.ignoreKey(signInCandidate)) else { continue }
            if isOffered(signInCandidate, now: now) { return signInCandidate }
        }
        return nil
    }

    private func isOffered(_ candidate: Candidate, now: Date) -> Bool {
        if candidate.purpose == .link, let pendingLink, pendingLink.until > now, pendingLink.key == Self.ignoreKey(candidate) {
            return true
        }
        return !closed.contains(candidate.id)
            && !Self.isIgnored(candidate)
            && !dismissals.suppresses(Self.ignoreKey(candidate), at: now)
    }

    // MARK: - Sign in by sound

    private func beginSignIn(_ signing: Candidate) {
        stopFlow()
        shown.insert(signing.id)
        requestedChime = false
        phase = .listening
        onEvent?(.began(signing))
        listener.preferredSessionIdPrefix = signing.sessionIdPrefix
        listener.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] next in self?.listenerChanged(next) }
            .store(in: &flow)
        listener.$linked
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] linked in self?.didLink(linked) }
            .store(in: &flow)
        listener.$isHearingNothing
            .filter { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.couldNotHear() }
            .store(in: &flow)
        listener.start()
        if listener.phase == .needsPermission { listener.continueAfterPriming() }
    }

    private func listenerChanged(_ next: NearbyTVSignIn.Phase) {
        guard let candidate, phase != .offering, phase != .done else { return }
        if case .failed = phase { return }
        switch next {
        case .idle, .needsPermission:
            break
        case .permissionDenied:
            fail("Sounding needs the microphone to hear \(candidate.name). Turn it on in Settings, or use the code instead.")
        case .listening:
            phase = .listening
            requestChime(for: candidate)
        case .checking:
            phase = .connecting
        case .found(let name, _):
            if name.localizedCaseInsensitiveCompare(candidate.name) == .orderedSame {
                listener.signIn()
            } else {
                phase = .found(name: name)
            }
        case .signingIn:
            phase = .signingIn
        case .failed(let message):
            fail(message)
        }
    }

    private func requestChime(for target: Candidate) {
        guard !requestedChime else { return }
        requestedChime = true
        let offer = browser.offers.first { $0.sessionIdPrefix == target.sessionIdPrefix }
            ?? browser.offers.first { $0.kind == .tv && !$0.isSignedIn && $0.claimedName == target.name }
        guard let offer else {
            fail("Couldn't find \(target.name). Make sure it's showing its sign-in screen, then try again.")
            return
        }
        chimeRequest.send(to: offer) { [weak self] played in
            guard let self, !played, self.phase == .listening else { return }
            Log.link.info("[NearbyDeviceCard] the Apple TV didn't play its sound on request")
            self.fail("Couldn't reach \(target.name). Make sure it's showing its sign-in screen, then try again.")
        }
    }

    private func couldNotHear() {
        guard let candidate, phase == .listening || phase == .connecting else { return }
        fail("Couldn't hear \(candidate.name). Turn its volume up and try again, or use the code instead.")
    }

    private func didLink(_ linked: NearbyTVSignIn.Linked) {
        guard let candidate else { return }
        flow.removeAll()
        chimeRequest.cancel()
        listener.stop()
        if holdsCardDuringTransfer {
            phase = .signingIn
        } else {
            close(candidate)
        }
        onEvent?(.linked(linked))
    }

    private func fail(_ message: String) {
        stopFlow()
        phase = .failed(message)
        onEvent?(.failed)
    }

    private func stopFlow() {
        flow.removeAll()
        chimeRequest.cancel()
        listener.stop()
    }

    // MARK: - Presence

    private func updatePresence() {
        let wanted = isForeground && candidate?.purpose == .signIn
        guard wanted != (presence != nil) else { return }
        presence?.cancel()
        presence = nil
        guard wanted else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        guard let newListener = try? NWListener(using: parameters) else { return }
        let suffix = String(format: "%08x", UInt32.random(in: .min ... .max))
        newListener.service = NWListener.Service(
            name: "\(BonjourConstants.nearbyServiceName)-\(suffix)",
            type: BuildFlavor.current.bonjourServiceType,
            txtRecord: NWTXTRecord(NearbyPresenceTXT.entries(name: LinkPeerIdentity.localName, kind: .current))
        )
        newListener.newConnectionHandler = { $0.cancel() }
        newListener.start(queue: .main)
        presence = newListener
    }
}

struct NearbyDeviceCard: View {
    @ObservedObject var model: NearbyDeviceCardModel
    let candidate: NearbyDeviceCardModel.Candidate

    @ObservedObject private var credentials = SoundCloudCredentialSource.shared

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: candidate.kind.symbolName)
                .font(.system(size: 92, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.primary)
                .frame(height: 132)
                .accessibilityHidden(true)
                .padding(.bottom, 14)

            VStack(spacing: 4) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
            }
            .padding(.bottom, 12)

            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 44, alignment: .top)
                .padding(.bottom, 20)

            actions
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(maxWidth: 440)
        .tint(Color.scAccent)
        .contextMenu {
            if canIgnore { ignoreButton }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private var deviceName: String { candidate.kind.displayName }

    private var title: String {
        let trimmed = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? deviceName : trimmed
    }

    private var accountName: String? {
        guard !credentials.isSignedOut, let name = credentials.currentUser?.displayName, !name.isEmpty else { return nil }
        return name
    }

    private var subtitle: String {
        guard model.phase == .offering else { return deviceName }
        switch candidate.purpose {
        case .signIn:
            return "\(deviceName) · Not signed in"
        case .link:
            guard let accountName else { return deviceName }
            return "\(deviceName) · Signed in as \(accountName)"
        }
    }

    private var message: String {
        switch model.phase {
        case .offering:
            switch candidate.purpose {
            case .signIn:
                return TVAccountCopy.cardSignInMessage(mine: credentials.isSignedOut ? nil : credentials.accountUser.map(PeerAccount.init(user:)))
            case .link:
                return "Link it to control playback from this \(DeviceClass.current.displayName)."
            }
        case .listening:
            return "Listening for \(title)… Keep this \(DeviceClass.current.displayName) near it."
        case .connecting:
            return "Connecting…"
        case .found(let name):
            return "Heard \(name). Sign in to Sounding on it?"
        case .signingIn:
            return "Signing in…"
        case .done:
            return "Signed in."
        case .failed(let message):
            return message
        }
    }

    private var canIgnore: Bool {
        switch model.phase {
        case .offering, .found, .failed: return true
        case .listening, .connecting, .signingIn, .done: return false
        }
    }

    private var ignoreButton: some View {
        Button("Don't Ask for This \(deviceName)") { model.ignoreDevice() }
    }

    private var primaryTitle: String {
        switch candidate.purpose {
        case .signIn: return "Sign In"
        case .link: return "Link"
        }
    }

    private static var codeTitle: String {
        #if os(macOS)
        "Use a Code Instead"
        #else
        "Use QR Code Instead"
        #endif
    }

    // MARK: - Actions

    #if os(macOS)
    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 10) {
            switch model.phase {
            case .offering, .found:
                ignoreMenu
                Spacer(minLength: 0)
                Button("Not Now") { model.notNow() }
                    .keyboardShortcut(.cancelAction)
                Button(primaryTitle) { model.primary() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case .listening, .connecting, .signingIn:
                ProgressView()
                    .controlSize(.small)
                Spacer(minLength: 0)
                Button("Cancel") { model.notNow() }
                    .keyboardShortcut(.cancelAction)
            case .done:
                Color.clear
                    .frame(height: 32)
                    .accessibilityHidden(true)
            case .failed:
                Button(Self.codeTitle) { model.useCode() }
                    .buttonStyle(.link)
                Spacer(minLength: 0)
                Button("Not Now") { model.notNow() }
                    .keyboardShortcut(.cancelAction)
                Button("Try Again") { model.primary() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
    }

    private var ignoreMenu: some View {
        Menu {
            ignoreButton
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More Options")
    }
    #else
    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 6) {
            switch model.phase {
            case .offering, .found:
                prominent(primaryTitle) { model.primary() }
                plain("Not Now") { model.notNow() }
                    .keyboardShortcut(.cancelAction)
            case .listening, .connecting, .signingIn:
                ProgressView()
                    .controlSize(.large)
                    .frame(minHeight: 50)
                plain("Cancel") { model.notNow() }
                    .keyboardShortcut(.cancelAction)
            case .done:
                Color.clear
                    .frame(height: 50)
                    .accessibilityHidden(true)
            case .failed:
                prominent("Try Again") { model.primary() }
                plain(Self.codeTitle) { model.useCode() }
                plain("Not Now") { model.notNow() }
            }
        }
    }

    private func plain(_ title: String, action: @escaping () -> Void) -> some View {
        BottomCardPlainButton(title: title, action: action)
    }

    private func prominent(_ title: String, action: @escaping () -> Void) -> some View {
        BottomCardProminentButton(title: title, action: action)
    }
    #endif
}

private struct NearbyDeviceCardHost: ViewModifier {
    @ObservedObject var model: NearbyDeviceCardModel
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content.bottomCard(
            item: isEnabled ? model.candidate : nil,
            isDismissible: !model.phase.isWorking,
            phase: model.phase,
            onDismiss: { model.notNow() },
            onAppear: { model.didShow($0) }
        ) { candidate in
            NearbyDeviceCard(model: model, candidate: candidate)
        }
    }
}

extension View {
    func nearbyDeviceCard(_ model: NearbyDeviceCardModel, isEnabled: Bool) -> some View {
        modifier(NearbyDeviceCardHost(model: model, isEnabled: isEnabled))
    }
}

