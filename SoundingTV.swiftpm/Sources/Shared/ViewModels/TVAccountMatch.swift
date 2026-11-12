import Foundation

enum TVAccount: Equatable, Sendable {
    case signedOut
    case needsSignIn(last: PeerAccount?)
    case signedIn(PeerAccount)
    case signedInSame
    case signedInOther
    case unknown

    init(status: AccountStatusPayload?) {
        guard let status else {
            self = .unknown
            return
        }
        switch status.state {
        case .signedOut:
            self = .signedOut
        case .needsSignIn:
            self = .needsSignIn(last: PeerAccount.decode(status.last))
        case .signedIn:
            if let account = PeerAccount.decode(status.account) {
                self = .signedIn(account)
            } else {
                self = .unknown
            }
        }
    }

    var account: PeerAccount? {
        if case .signedIn(let account) = self { return account }
        return nil
    }
}

enum PhoneAccount: Equatable, Sendable {
    case signedOut
    case signedIn(PeerAccount)

    var account: PeerAccount? {
        if case .signedIn(let account) = self { return account }
        return nil
    }
}

enum TVLinkState: Equatable, Sendable {
    case unlinked
    case linked(reachable: Bool)

    var isLinked: Bool {
        if case .linked = self { return true }
        return false
    }
}

struct ICloudSessionOffer: Equatable, Sendable {
    let account: PeerAccount
    let writerName: String?
}

struct TVAccountEvidence: Equatable, Sendable {
    var ownerProvable: Bool
    var knownLink: KnownLinkLedger.Status
    var iCloudOffer: ICloudSessionOffer?

    init(ownerProvable: Bool = false, knownLink: KnownLinkLedger.Status = .never, iCloudOffer: ICloudSessionOffer? = nil) {
        self.ownerProvable = ownerProvable
        self.knownLink = knownLink
        self.iCloudOffer = iCloudOffer
    }

    static let none = TVAccountEvidence()
}

enum TVAccountRelation: Equatable, Sendable {
    case sameAccount(linked: Bool, autoLink: Bool)
    case tvSignedOut(linked: Bool)
    case tvNeedsSignIn(last: PeerAccount?, mine: PeerAccount)
    case phoneSignedOut(tv: PeerAccount?, offer: ICloudSessionOffer?)
    case differentAccounts(tv: PeerAccount?, mine: PeerAccount)
    case nothing
    case unknown

    static func resolve(tv: TVAccount, phone: PhoneAccount, link: TVLinkState, evidence: TVAccountEvidence = .none) -> TVAccountRelation {
        guard case .signedIn(let mine) = phone else {
            switch tv {
            case .signedOut, .needsSignIn:
                return .nothing
            case .signedIn(let theirs):
                return .phoneSignedOut(tv: theirs, offer: evidence.iCloudOffer)
            case .signedInSame, .signedInOther:
                return .phoneSignedOut(tv: nil, offer: evidence.iCloudOffer)
            case .unknown:
                return evidence.iCloudOffer.map { .phoneSignedOut(tv: nil, offer: $0) } ?? .unknown
            }
        }
        switch tv {
        case .signedOut:
            return .tvSignedOut(linked: link.isLinked)
        case .needsSignIn(let last):
            guard link.isLinked else { return .tvSignedOut(linked: false) }
            return .tvNeedsSignIn(last: last, mine: mine)
        case .signedIn(let theirs):
            guard theirs.isSameAccount(as: mine) else { return .differentAccounts(tv: theirs, mine: mine) }
            return .sameAccount(linked: link.isLinked, autoLink: autoLinks(link: link, evidence: evidence))
        case .signedInSame:
            return .sameAccount(linked: link.isLinked, autoLink: autoLinks(link: link, evidence: evidence))
        case .signedInOther:
            return .differentAccounts(tv: nil, mine: mine)
        case .unknown:
            return .unknown
        }
    }

    private static func autoLinks(link: TVLinkState, evidence: TVAccountEvidence) -> Bool {
        !link.isLinked && evidence.ownerProvable && evidence.knownLink == .linked
    }

    var isDifferentAccounts: Bool {
        if case .differentAccounts = self { return true }
        return false
    }

    var otherAccount: PeerAccount? {
        switch self {
        case .differentAccounts(let tv, _): return tv
        case .phoneSignedOut(let tv, _): return tv
        default: return nil
        }
    }
}

// MARK: - Copy

enum TVAccountCopy {
    static func possessive(_ name: String) -> String {
        "\(name)'s"
    }

    static func signedInAs(_ account: PeerAccount) -> String {
        "Signed in as \(account.displayName)"
    }

    static let anotherAccountStatus = "Signed in to another account"

    static func playOnSubtitle(_ relation: TVAccountRelation) -> String? {
        switch relation {
        case .differentAccounts(let tv?, _): return signedInAs(tv)
        case .differentAccounts(nil, _): return anotherAccountStatus
        case .phoneSignedOut(let tv?, _): return signedInAs(tv)
        default: return nil
        }
    }

    static func linkedCapsule(tv: String) -> String {
        "Linked to \(tv)"
    }

    static func cardSignInMessage(mine: PeerAccount?) -> String {
        guard let mine else { return "Sign it in to Sounding with your SoundCloud account." }
        return "Sign it in to Sounding as \(mine.displayName)."
    }

    static func cardLinkSubtitle(mine: PeerAccount?) -> String {
        guard let mine else { return "Apple TV" }
        return "Apple TV · \(signedInAs(mine))"
    }

    struct NeedsSignIn: Equatable, Sendable {
        let title: String
        let footer: String
        let action: String
    }

    static func needsSignIn(tv: String, last: PeerAccount?, mine: PeerAccount, device: String = DeviceClass.current.displayName) -> NeedsSignIn {
        if let last, !last.isSameAccount(as: mine) {
            return NeedsSignIn(
                title: "\(tv) was signed in as \(last.displayName).",
                footer: "Sign it in as \(mine.displayName), or sign \(last.displayName) in on \(tv).",
                action: "Sign In as \(mine.displayName)"
            )
        }
        return NeedsSignIn(
            title: "\(tv) is waiting to sign in.",
            footer: "It'll use the SoundCloud account on this \(device).",
            action: "Sign In This Apple TV"
        )
    }

    static func needsSignInTimedOut(tv: String) -> String {
        "\(tv) didn't answer. Keep it on and try again."
    }

    static func welcomeLine(tv: String, account: PeerAccount) -> String {
        "\(tv) is signed in as \(account.displayName)."
    }

    static func continueAs(_ account: PeerAccount) -> String {
        "Continue as \(account.displayName)"
    }

    static func signedInOn(_ writer: String) -> String {
        "Signed in on \(writer)"
    }

    static func continueExpired(_ account: PeerAccount) -> String {
        "\(possessive(account.displayName)) sign-in has expired. Sign in with SoundCloud instead."
    }

    static let continueUnreachable = "Couldn't reach SoundCloud. Try again."

    struct Choice: Equatable, Sendable {
        let title: String
        let message: String
        let proceed: String
        let switchAction: String
    }

    static func choice(tv: String, theirs: PeerAccount?, mine: PeerAccount, controlling: Bool) -> Choice {
        let theirName = theirs?.displayName
        let title = theirName.map { "\(tv) is signed in as \($0)" } ?? "\(tv) is signed in to another SoundCloud account"
        let source = theirName.map { "\(possessive($0)) SoundCloud" } ?? "another SoundCloud account"
        return Choice(
            title: title,
            message: "You're signed in as \(mine.displayName). \(tv) plays from \(source), so tracks only \(mine.displayName) can play won't play there.",
            proceed: controlling ? "Control \(tv)" : "Play on \(tv)",
            switchAction: switchAction(tv: tv, mine: mine)
        )
    }

    static func switchAction(tv: String, mine: PeerAccount) -> String {
        "Switch \(tv) to \(mine.displayName)…"
    }

    static let accountSectionLabel = "Signed In As"

    static func accountSectionFooter(mine: PeerAccount) -> String {
        "You're signed in as \(mine.displayName). Your likes and library stay with \(mine.displayName)."
    }

    struct Alert: Equatable, Sendable {
        let title: String
        let message: String
    }

    static func trackUnavailable(tv: String, theirs: PeerAccount?) -> Alert {
        Alert(
            title: "Couldn't Play on \(tv)",
            message: theirs.map { "It's signed in as \($0.displayName), who can't play this." } ?? "It's signed in to another SoundCloud account, which can't play this."
        )
    }

    static func commandRefused(tv: String) -> String {
        "\(tv) couldn't do that."
    }

    static func linkOtherAccount(tv: String, device: String = DeviceClass.current.displayName) -> Alert {
        Alert(
            title: "\(tv) is signed in to another SoundCloud account",
            message: "Link it to control it from this \(device). You can switch it to your account afterwards."
        )
    }

    static func confirmSwitch(tv: String, theirs: PeerAccount?, mine: PeerAccount) -> Alert {
        let name = theirs?.displayName
        return Alert(
            title: "Switch \(tv) to \(mine.displayName)?",
            message: name.map { "\($0) will be signed out on \(tv). \(possessive($0)) downloads and recent plays on it are removed." }
                ?? "The account on \(tv) will be signed out. Its downloads and recent plays on it are removed."
        )
    }

    static func waiting(tv: String) -> String {
        "Waiting for \(tv)…"
    }

    static func waitingFooter(tv: String) -> String {
        "Choose Switch on \(tv)."
    }

    static func switchOutcome(_ failure: AccountSwitchHandshake.Failure, tv: String, theirs: PeerAccount?, device: String = DeviceClass.current.displayName) -> String {
        switch failure {
        case .declined:
            return theirs.map { "\(tv) kept \(possessive($0.displayName)) account." } ?? "\(tv) kept its account."
        case .timedOut:
            return "\(tv) didn't answer. Its account hasn't changed."
        case .unavailable:
            return "\(tv) couldn't reach SoundCloud. Its account hasn't changed."
        case .refused:
            return "Your sign-in on this \(device) needs renewing. Try again in a moment."
        case .dropped:
            return "\(tv) isn't reachable. Its account hasn't changed."
        }
    }

    static func switched(tv: String, mine: PeerAccount) -> String {
        "\(tv) is signed in as \(mine.displayName)."
    }

    static func tvAllowMessage(device: String, sameAccount: Bool) -> String {
        sameAccount
            ? "It's signed in to the same SoundCloud account. Only allow it if \(device) shows this code."
            : "It's signed in to a different SoundCloud account. Only allow it if \(device) shows this code."
    }

    static func tvAllowTitle(device: String) -> String {
        "Allow “\(device)” to control this Apple TV?"
    }

    static func tvSwitchTitle(mine: PeerAccount) -> String {
        "Switch to \(possessive(mine.displayName)) SoundCloud?"
    }

    static func tvSwitchMessage(device: String, mine: PeerAccount, theirs: PeerAccount?) -> String {
        let leaving = theirs.map { "\($0.displayName) will be signed out here." } ?? "The current account will be signed out here."
        return "\(device) wants to sign this Apple TV in as \(mine.displayName). \(leaving)"
    }

    static func tvKeep(_ theirs: PeerAccount?) -> String {
        theirs.map { "Keep \($0.displayName)" } ?? "Cancel"
    }

    static func tvSwitching(to mine: PeerAccount) -> String {
        "Switching to \(mine.displayName)…"
    }

    static func tvConnectedCapsule(device: String, controller: PeerAccount) -> String {
        "\(device) is connected · \(controller.displayName)"
    }

    static func tvLinkedCapsule(device: String) -> String {
        "\(device) is linked"
    }

    static func tvSignedInSubtitle(_ account: PeerAccount?) -> String {
        guard let account else { return "Enjoy your music." }
        return "Signed in as \(account.displayName)."
    }
}

// MARK: - Auto-link

enum AutoLinkPolicy {
    struct Input: Equatable, Sendable {
        var isSignedIn: Bool
        var isForeground: Bool
        var holdsLinkKey: Bool
        var hintMatches: Bool
        var listedAsLinked: Bool
        var alreadyLinked: Bool
        var dismissed: Bool
        var showingOtherSheet: Bool
        var attemptedThisLaunch: Bool
        var knownLink: KnownLinkLedger.Status
    }

    static let timeout: TimeInterval = 15

    static func shouldAttempt(_ input: Input) -> Bool {
        input.isSignedIn
            && input.isForeground
            && input.holdsLinkKey
            && input.hintMatches
            && !input.listedAsLinked
            && !input.alreadyLinked
            && !input.dismissed
            && !input.showingOtherSheet
            && !input.attemptedThisLaunch
            && input.knownLink == .linked
    }

    static func sendsOwnerTags(knownLink: KnownLinkLedger.Status, hintMatches: Bool) -> Bool {
        hintMatches && knownLink == .linked
    }
}

// MARK: - Cross-account choice

struct CrossAccountChoice: Codable, Equatable, Sendable {
    static let defaultsKey = "red.forbes.sounding.crossAccountChoice.v1"

    private(set) var remembered: Set<String> = []

    static func key(link: String, tv: PeerAccount, mine: PeerAccount) -> String {
        "\(link)|\(tv.tag)|\(mine.tag)"
    }

    func isRemembered(link: String, tv: PeerAccount?, mine: PeerAccount) -> Bool {
        guard let tv else { return false }
        return remembered.contains(Self.key(link: link, tv: tv, mine: mine))
    }

    mutating func remember(link: String, tv: PeerAccount, mine: PeerAccount) {
        forget(link: link)
        remembered.insert(Self.key(link: link, tv: tv, mine: mine))
    }

    mutating func forget(link: String) {
        remembered = remembered.filter { !$0.hasPrefix("\(link)|") }
    }

    static func needsChoice(_ relation: TVAccountRelation, link: String, choice: CrossAccountChoice) -> Bool {
        guard case .differentAccounts(let tv, let mine) = relation else { return false }
        return !choice.isRemembered(link: link, tv: tv, mine: mine)
    }

    static func load(defaults: UserDefaults = .standard) -> CrossAccountChoice {
        guard let data = defaults.data(forKey: defaultsKey),
              let choice = try? JSONDecoder().decode(CrossAccountChoice.self, from: data) else { return CrossAccountChoice() }
        return choice
    }

    func save(defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

// MARK: - Link establishment

enum LinkEstablishPolicy {
    enum OfferHint: Equatable, Sendable {
        case signedOut
        case sameAccount
        case otherAccount
        case notSeen
    }

    enum Opening: Equatable, Sendable {
        case tokenTransfer
        case linkEstablish
    }

    static func hint(for advert: LinkAccountHint.Advert?, offerSeen: Bool, accountId: String?) -> OfferHint {
        guard offerSeen else { return .notSeen }
        guard let advert else { return .signedOut }
        guard let accountId, advert.matches(accountId: accountId) else { return .otherAccount }
        return .sameAccount
    }

    static func opening(for hint: OfferHint) -> Opening {
        hint == .signedOut ? .tokenTransfer : .linkEstablish
    }

    static func sendsCredentials(_ established: LinkEstablishedPayload) -> Bool {
        established.needsCredentials
    }

    static func fallsBackToTokenTransfer(_ hint: OfferHint) -> Bool {
        switch hint {
        case .notSeen, .sameAccount, .signedOut: return true
        case .otherAccount: return false
        }
    }

    static func isSameAccountApproval(digest: String?, salt: Data?, accountId: String?) -> Bool {
        guard let digest, let mine = Data(base64Encoded: digest), let salt,
              let accountId, !accountId.isEmpty else { return false }
        return LinkAccountHint.constantTimeEqual(mine, LinkAccountHint.accountDigest(accountId: accountId, salt: salt))
    }

    static func helloDigest(accountId: String?, salt: Data?) -> String? {
        guard let accountId, !accountId.isEmpty, let salt, salt.count == LinkAccountHint.saltLength else { return nil }
        return LinkAccountHint.accountDigest(accountId: accountId, salt: salt).base64EncodedString()
    }
}

// MARK: - Rejections

enum CompanionRejection: Equatable, Sendable {
    case trackUnavailable
    case queueUnavailable
    case syncRefused
    case notExpected
    case other

    static func classify(code: String?, message: String?) -> CompanionRejection {
        switch code ?? "" {
        case CompanionErrorCode.trackUnavailable: return .trackUnavailable
        case CompanionErrorCode.queueUnavailable: return .queueUnavailable
        case CompanionErrorCode.syncRefused: return .syncRefused
        case CompanionErrorCode.notExpected: return .notExpected
        default: break
        }
        let text = (message ?? "").lowercased()
        if text.contains("sync rejected") || text.contains("offer rejected") || text.contains("session rejected") {
            return .syncRefused
        }
        if text.contains("could not load the queue") { return .queueUnavailable }
        return .other
    }

    var answersPlayback: Bool {
        switch self {
        case .trackUnavailable, .queueUnavailable, .other: return true
        case .syncRefused, .notExpected: return false
        }
    }
}

// MARK: - Account switch

struct AccountSwitchHandshake: Equatable, Sendable {
    enum Failure: Equatable, Sendable {
        case declined
        case timedOut
        case unavailable
        case refused
        case dropped
    }

    enum Phase: Equatable, Sendable {
        case idle
        case confirming
        case waiting(nonce: String, since: Date)
        case sending(nonce: String, since: Date)
        case validating(nonce: String, since: Date)
        case done
        case failed(Failure)
    }

    enum Action: Equatable, Sendable {
        case none
        case sendCredentials(nonce: String)
    }

    private(set) var phase: Phase = .idle
    private var spent: Set<String> = []

    var nonce: String? {
        switch phase {
        case .waiting(let nonce, _), .sending(let nonce, _), .validating(let nonce, _): return nonce
        default: return nil
        }
    }

    var isBusy: Bool { nonce != nil }

    var mayReleaseCredentials: Bool {
        if case .sending = phase { return true }
        return false
    }

    mutating func begin() {
        guard !isBusy else { return }
        phase = .confirming
    }

    mutating func cancel() {
        guard phase == .confirming else { return }
        phase = .idle
    }

    @discardableResult
    mutating func confirm(nonce: String, at now: Date) -> Bool {
        guard phase == .confirming, !nonce.isEmpty, !spent.contains(nonce) else { return false }
        spent.insert(nonce)
        phase = .waiting(nonce: nonce, since: now)
        return true
    }

    mutating func receive(_ answer: AccountSwitchPayload.Answer, nonce: String, at now: Date) -> Action {
        guard let current = self.nonce, current == nonce else { return .none }
        switch (phase, answer) {
        case (.waiting, .accepted):
            phase = .sending(nonce: nonce, since: now)
            return .sendCredentials(nonce: nonce)
        case (.waiting, .declined):
            phase = .failed(.declined)
        case (.sending, .switched), (.validating, .switched):
            phase = .done
        case (_, .unavailable):
            phase = .failed(.unavailable)
        case (_, .refused):
            phase = .failed(.refused)
        default:
            break
        }
        return .none
    }

    mutating func credentialsSent(at now: Date) {
        guard case .sending(let nonce, _) = phase else { return }
        phase = .validating(nonce: nonce, since: now)
    }

    mutating func tick(at now: Date) {
        switch phase {
        case .waiting(_, let since) where now.timeIntervalSince(since) >= AccountSwitchPayload.answerTimeout:
            phase = .failed(.timedOut)
        case .sending(_, let since) where now.timeIntervalSince(since) >= AccountSwitchPayload.credentialsTimeout,
             .validating(_, let since) where now.timeIntervalSince(since) >= AccountSwitchPayload.credentialsTimeout:
            phase = .failed(.dropped)
        default:
            break
        }
    }

    mutating func linkDropped() {
        guard isBusy else { return }
        phase = .failed(.dropped)
    }

    mutating func reset() {
        guard !isBusy else { return }
        phase = .idle
    }
}

struct TVAccountSwitchGate: Equatable, Sendable {
    struct Request: Equatable, Sendable {
        let nonce: String
        let sessionId: String
        let account: PeerAccount
        let deviceName: String
        var since: Date
        var accepted: Bool
    }

    private(set) var request: Request?
    private var spent: Set<String> = []

    var asking: Request? {
        guard let request, !request.accepted else { return nil }
        return request
    }

    mutating func receive(nonce: String, sessionId: String, account: PeerAccount, deviceName: String, at now: Date) -> Bool {
        guard request == nil, !nonce.isEmpty, !spent.contains(nonce) else { return false }
        spent.insert(nonce)
        request = Request(nonce: nonce, sessionId: sessionId, account: account, deviceName: deviceName, since: now, accepted: false)
        return true
    }

    mutating func accept(at now: Date) -> Request? {
        guard var pending = request, !pending.accepted else { return nil }
        pending.accepted = true
        pending.since = now
        request = pending
        return pending
    }

    mutating func decline() -> Request? {
        guard let pending = request, !pending.accepted else { return nil }
        request = nil
        return pending
    }

    mutating func credentials(nonce: String, sessionId: String, at now: Date) -> Request? {
        guard let pending = request, pending.accepted, pending.nonce == nonce, pending.sessionId == sessionId,
              now.timeIntervalSince(pending.since) < AccountSwitchPayload.credentialsTimeout else { return nil }
        request = nil
        return pending
    }

    mutating func expire(at now: Date) -> Request? {
        guard let pending = request else { return nil }
        let limit = pending.accepted ? AccountSwitchPayload.credentialsTimeout : AccountSwitchPayload.answerTimeout
        guard now.timeIntervalSince(pending.since) >= limit else { return nil }
        request = nil
        return pending
    }

    mutating func drop(sessionId: String) -> Request? {
        guard let pending = request, pending.sessionId == sessionId else { return nil }
        request = nil
        return pending
    }
}

// MARK: - TV side

enum TVControllerAccount {
    static func differs(controller: PeerAccount?, tv: PeerAccount?) -> Bool {
        guard let controller, let tv else { return false }
        return !controller.isSameAccount(as: tv)
    }

    static func settingsLine(controller: PeerAccount?, tv: PeerAccount?) -> String? {
        guard differs(controller: controller, tv: tv), let controller else { return nil }
        return TVAccountCopy.signedInAs(controller)
    }

    static func connectedCapsule(device: String, controller: PeerAccount?, tv: PeerAccount?) -> String? {
        guard differs(controller: controller, tv: tv), let controller else { return nil }
        return TVAccountCopy.tvConnectedCapsule(device: device, controller: controller)
    }

    static func acceptsAuthHandoff(needsSignIn: Bool, requestOutstanding: Bool) -> Bool {
        needsSignIn && requestOutstanding
    }
}

enum PresenceAccountFilter {
    static func keeps(isOutput: Bool, tv: TVAccount, mine: PeerAccount?) -> Bool {
        if isOutput { return true }
        guard let mine, case .signedIn(let theirs) = tv else { return true }
        return theirs.isSameAccount(as: mine)
    }
}

extension PeerAccount {
    init(user: User) {
        self.init(userId: user.id, name: user.displayName, username: user.username, avatarURL: user.avatarURL?.absoluteString)
    }
}

struct TVAccountRecord: Codable, Equatable, Sendable {
    static let defaultsKey = "red.forbes.sounding.tvAccounts.v1"

    var state: AccountStatusPayload.State
    var account: PeerAccount?
    var last: PeerAccount?
    var capabilities: [String]

    init(state: AccountStatusPayload.State, account: PeerAccount?, last: PeerAccount?, capabilities: [String]) {
        self.state = state
        self.account = account
        self.last = last
        self.capabilities = capabilities
    }

    init(status: AccountStatusPayload) {
        self.init(
            state: status.state,
            account: PeerAccount.decode(status.account),
            last: PeerAccount.decode(status.last),
            capabilities: status.capabilities
        )
    }

    var tvAccount: TVAccount {
        switch state {
        case .signedOut: return .signedOut
        case .needsSignIn: return .needsSignIn(last: last)
        case .signedIn: return account.map(TVAccount.signedIn) ?? .unknown
        }
    }

    func supports(_ capability: String) -> Bool { capabilities.contains(capability) }

    static func loadAll(defaults: UserDefaults = .standard) -> [String: TVAccountRecord] {
        guard let data = defaults.data(forKey: defaultsKey),
              let records = try? JSONDecoder().decode([String: TVAccountRecord].self, from: data) else { return [:] }
        return records
    }

    static func saveAll(_ records: [String: TVAccountRecord], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}

enum AccountChoiceAnswer: Equatable, Sendable {
    case proceed
    case switchAccount
    case cancel
}

struct AccountChoiceRequest: Identifiable {
    let id = UUID()
    let sessionId: String
    let tvName: String
    let choice: TVAccountCopy.Choice
    let canSwitch: Bool
    let resume: (AccountChoiceAnswer) -> Void
}

struct AccountRefusalAlert: Identifiable, Equatable {
    let id = UUID()
    let sessionId: String
    let alert: TVAccountCopy.Alert
    let switchAction: String?
}
