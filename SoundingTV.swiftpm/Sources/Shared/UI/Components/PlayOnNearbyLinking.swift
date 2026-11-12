import SwiftUI
import Combine

@MainActor
final class PlayOnNearbyLinking: ObservableObject {
    enum RowState: Equatable {
        case ready
        case working
        case failed(String)
    }

    struct Row: Identifiable, Equatable {
        let id: String
        let name: String
        let kind: DeviceClass
        let detail: String
        let state: RowState
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var comparison: LinkConfirmationHandshake?
    @Published private(set) var otherAccount: (row: Row, alert: TVAccountCopy.Alert)?

    private struct Active {
        let id: String
        let name: String
        let kind: DeviceClass
        var handshake: LinkConfirmationHandshake?
        var sessionId: String?
        var failure: String?
    }

    private weak var browser: LinkOfferBrowser?
    private weak var router: OutputRouter?
    private let linker = CompanionLinker()
    private var active: Active?
    private var subscriptions: Set<AnyCancellable> = []
    private var flow: Set<AnyCancellable> = []
    private var work: Task<Void, Never>?

    var isBusy: Bool { active != nil && active?.failure == nil }

    func isEnabled(_ row: Row) -> Bool {
        row.state != .working && (!isBusy || active?.id == row.id)
    }

    func attach(browser: LinkOfferBrowser, router: OutputRouter) {
        browser.startIfNeeded()
        guard self.browser == nil else { return }
        self.browser = browser
        self.router = router
        browser.$offers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &subscriptions)
        router.$entries
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &subscriptions)
        SoundCloudCredentialSource.shared.$state
            .map(\.isSignedOut)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuild() }
            .store(in: &subscriptions)
        rebuild()
    }

    func select(_ row: Row) {
        if let current = active, current.id == row.id {
            guard current.failure != nil else { return }
            if let sessionId = current.sessionId {
                active?.failure = nil
                rebuild()
                adopt(sessionId: sessionId)
                return
            }
        }
        guard !isBusy, let offer = offer(for: row.id) else { return }
        if offer.isOtherAccount {
            otherAccount = (row, TVAccountCopy.linkOtherAccount(tv: offer.claimedName))
            return
        }
        begin(offer)
    }

    func answerOtherAccount(link: Bool) {
        guard let pending = otherAccount else { return }
        otherAccount = nil
        guard link, !isBusy, let offer = offer(for: pending.row.id) else { return }
        begin(offer)
    }

    func cancelComparison() {
        guard comparison != nil else { return }
        comparison = nil
        guard let handshake = active?.handshake else { return }
        switch handshake.state {
        case .succeeded: return
        default: break
        }
        handshake.stop()
        clear()
    }

    func closed() {
        guard work == nil else { return }
        cancelComparison()
        if active?.failure != nil { clear() }
    }

    // MARK: - Flow

    private func begin(_ offer: LinkOfferBrowser.Offer) {
        stopFlow()
        let handshake = LinkConfirmationHandshake(offer: offer)
        active = Active(
            id: Self.identity(offer.claimedName, offer.kind),
            name: offer.claimedName,
            kind: offer.kind,
            handshake: handshake
        )
        handshake.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak handshake] state in
                guard let self, let handshake, self.active?.handshake === handshake else { return }
                self.handshakeChanged(state, handshake: handshake)
            }
            .store(in: &flow)
        rebuild()
        handshake.start()
    }

    private func handshakeChanged(_ state: LinkConfirmationHandshake.State, handshake: LinkConfirmationHandshake) {
        switch state {
        case .idle, .connecting, .confirming:
            break
        case .awaitingComparison:
            if comparison !== handshake { comparison = handshake }
        case .succeeded(let sessionId, let secret, _):
            comparison = nil
            flow.removeAll()
            transfer(sessionId: sessionId, secret: secret, name: handshake.claimedName)
        case .failed(let message):
            comparison = nil
            fail(message)
        case .declined:
            comparison = nil
            clear()
        }
    }

    private func transfer(sessionId: String, secret: Data, name: String) {
        active?.handshake = nil
        guard let session = DeviceSessionStore.load(), session.isUsable else {
            fail("Sign in to SoundCloud on this \(DeviceClass.current.displayName) first.")
            return
        }
        linker.reset()
        work = Task { [weak self] in
            guard let self else { return }
            await self.linker.authorize(sessionId: sessionId, secret: secret, tvName: name, session: session)
            guard !Task.isCancelled else { return }
            switch self.linker.state {
            case .completed:
                self.work = nil
                self.active?.sessionId = sessionId
                self.adopt(sessionId: sessionId)
            case .failed(let message):
                self.work = nil
                self.fail(message)
            default:
                self.work = nil
                self.fail(Self.unreachable(name))
            }
        }
    }

    private func adopt(sessionId: String) {
        work?.cancel()
        work = Task { [weak self] in
            guard let self else { return }
            var device: OutputDevice?
            for _ in 0..<40 {
                device = self.router?.linkedDevices.first { $0.linkSessionId == sessionId }
                if device != nil || Task.isCancelled { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled else { return }
            guard let device, let router = self.router else {
                self.work = nil
                self.fail(Self.unreachable(self.active?.name ?? DeviceClass.tv.displayName))
                return
            }
            let message = await router.move(to: device)
            self.work = nil
            if let message { self.fail(message) } else { self.clear() }
        }
    }

    private func fail(_ message: String) {
        guard active != nil else { return }
        active?.handshake?.stop()
        active?.handshake = nil
        active?.failure = message
        flow.removeAll()
        rebuild()
    }

    private func clear() {
        stopFlow()
        active = nil
        rebuild()
    }

    private func stopFlow() {
        flow.removeAll()
        work?.cancel()
        work = nil
        active?.handshake?.stop()
        comparison = nil
    }

    // MARK: - Rows

    private func offer(for id: String) -> LinkOfferBrowser.Offer? {
        browser?.distinctOffers.first { $0.kind == .tv && Self.identity($0.claimedName, $0.kind) == id }
    }

    private func rebuild() {
        let next = makeRows()
        if next != rows { rows = next }
    }

    private func makeRows() -> [Row] {
        guard let browser, let router, !SoundCloudCredentialSource.shared.isSignedOut else { return activeRow.map { [$0] } ?? [] }
        let linked = Set(router.linkedDevices.map { Self.identity($0.name, $0.deviceClass) })
        let deviceId = LinkPeerIdentity.localDeviceId()
        var next: [Row] = browser.distinctOffers.compactMap { offer in
            guard offer.kind == .tv else { return nil }
            let id = Self.identity(offer.claimedName, offer.kind)
            if id != active?.id {
                guard !linked.contains(id), offer.accountHint?.isLinked(toDeviceId: deviceId) != true else { return nil }
            }
            return Row(id: id, name: offer.claimedName, kind: offer.kind, detail: offer.nearbyStatus, state: state(for: id))
        }
        next.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if let activeRow, !next.contains(where: { $0.id == activeRow.id }) {
            next.insert(activeRow, at: 0)
        }
        return next
    }

    private var activeRow: Row? {
        guard let active else { return nil }
        return Row(id: active.id, name: active.name, kind: active.kind, detail: active.kind.displayName, state: state(for: active.id))
    }

    private func state(for id: String) -> RowState {
        guard let active, active.id == id else { return .ready }
        if let failure = active.failure { return .failed(failure) }
        return .working
    }

    private static func identity(_ name: String, _ kind: DeviceClass) -> String {
        SameAccountLinkOffer.identity(name: name, kind: kind)
    }

    private static func unreachable(_ name: String) -> String {
        "Couldn't reach \(name). Make sure it's on and on the same Wi-Fi."
    }
}

// MARK: - Views

struct PlayOnNearbyRowLabel: View {
    let row: PlayOnNearbyLinking.Row

    #if os(macOS)
    private let iconWidth: CGFloat = 24
    #else
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 32
    #endif

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.kind.symbolName)
                .foregroundStyle(.primary)
                .frame(width: iconWidth)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    #if os(macOS)
                    .font(.caption)
                    #else
                    .font(.footnote)
                    #endif
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            trailing
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint(accessibilityHint)
    }

    @ViewBuilder
    private var trailing: some View {
        switch row.state {
        case .ready:
            Text("Link")
                .foregroundStyle(.tint)
        case .working:
            ProgressView()
                #if os(macOS)
                .controlSize(.small)
                #endif
        case .failed:
            Text("Try Again")
                .foregroundStyle(.tint)
        }
    }

    private var subtitle: String {
        switch row.state {
        case .ready: return row.detail
        case .working: return "Connecting…"
        case .failed: return "Couldn't Connect"
        }
    }

    private var accessibilityHint: String {
        if case .failed(let message) = row.state { return message }
        return ""
    }
}

struct PlayOnLinkCodeView: View {
    @ObservedObject var handshake: LinkConfirmationHandshake

    var body: some View {
        ContentUnavailableView {
            Label(handshake.claimedName, systemImage: handshake.kind.symbolName)
        } description: {
            Text(handshake.instruction)
        } actions: {
            switch handshake.state {
            case .awaitingComparison(let code):
                Text(LinkConfirmationHandshake.codeGroups(code).joined(separator: "  "))
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .accessibilityLabel("Code \(LinkConfirmationHandshake.codeGroups(code).joined(separator: ", "))")
                Button("It Matches") { handshake.confirm() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                Button("It Doesn't Match", role: .destructive) { handshake.decline() }
            default:
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PlayOnOtherAccountConfirmation: ViewModifier {
    @ObservedObject var linking: PlayOnNearbyLinking

    func body(content: Content) -> some View {
        content.alert(
            linking.otherAccount?.alert.title ?? "",
            isPresented: Binding(
                get: { linking.otherAccount != nil },
                set: { if !$0 { linking.answerOtherAccount(link: false) } }
            )
        ) {
            Button("Link") { linking.answerOtherAccount(link: true) }
            Button("Cancel", role: .cancel) { linking.answerOtherAccount(link: false) }
        } message: {
            Text(linking.otherAccount?.alert.message ?? "")
        }
    }
}
