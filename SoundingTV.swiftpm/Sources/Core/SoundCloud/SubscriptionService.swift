import Foundation
import Combine
import os

@MainActor
final class SubscriptionService: ObservableObject {
    static let shared = SubscriptionService()

    enum Tier: String, Codable, Equatable {
        case free
        case go
        case goPlus
        case creatorPro
        case unknown
    }

    enum VerificationStatus: Equatable {
        case verified
        case unverifiable(withinGrace: Bool)
        case verifiedNotSubscribed
    }

    enum UnknownReason: Equatable {
        case neverChecked
        case checkFailed
        case unrecognisedProductIDs([String])
        case payloadUnreadable
    }

    enum AttemptOutcome: Equatable {
        case notYetAttempted
        case succeeded(Tier)
        case failed
    }

    @Published private(set) var tier: Tier = .unknown
    @Published private(set) var verification: VerificationStatus = .unverifiable(withinGrace: false)

    @Published private(set) var notSubscribedSince: Date?

    @Published private(set) var unknownReason: UnknownReason?

    @Published private(set) var lastRawSubscriptionDescription: String?
    @Published private(set) var authenticatedAccountID: String?

    var hasAuthenticatedSession: Bool {
        SoundCloudAPI.credentials?.accessToken != nil
    }

    var statusDescription: String {
        guard hasAuthenticatedSession else {
            return "Sign in to check your SoundCloud plan. Existing downloads remain stored but unavailable."
        }
        guard authenticatedAccountID != nil else { return "Checking your SoundCloud plan…" }
        switch (tier, unknownReason) {
        case (.unknown, .neverChecked):
            return "Not checked yet."
        case (.unknown, .checkFailed):
            return "Couldn't reach SoundCloud, so your plan is unconfirmed."
        case (.unknown, .unrecognisedProductIDs(let ids)):
            let list = ids.joined(separator: ", ")
            return "SoundCloud reported a plan this app doesn't recognise (\(list))."
        case (.unknown, .payloadUnreadable):
            return "SoundCloud didn't return any readable plan information."
        case (.unknown, nil):
            return "Your plan is unconfirmed."
        case (.free, _):
            return "SoundCloud says this account has no paid subscription."
        case (.go, _):
            return "SoundCloud Go. Offline downloads need Go+."
        case (.goPlus, _):
            switch verification {
            case .verified:
                return "SoundCloud Go+."
            case .unverifiable(let withinGrace):
                return withinGrace
                    ? "SoundCloud Go+, unconfirmed recently. Downloads still play."
                    : "SoundCloud Go+, but it hasn't been confirmed in a while."
            case .verifiedNotSubscribed:
                return "SoundCloud Go+."
            }
        case (.creatorPro, _):
            return "A SoundCloud creator plan (Next Pro / Artist Pro). "
                + "Creator plans don't include Go+ offline downloads."
        }
    }

    var canDownload: Bool {
        hasAuthenticatedSession && authenticatedAccountID != nil
            && tier == .goPlus && verification == .verified
    }

    var canPlayOffline: Bool {
        guard hasAuthenticatedSession, authenticatedAccountID != nil else { return false }
        switch verification {
        case .verified:
            return tier == .goPlus
        case .unverifiable(let withinGrace):
            return withinGrace && tier == .goPlus
        case .verifiedNotSubscribed:
            return false
        }
    }

    static let gracePeriod: TimeInterval = 10 * 24 * 3600

    static let deletionDelay: TimeInterval = 7 * 24 * 3600

    private static let reverifyInterval: TimeInterval = 6 * 3600

    private enum DefaultsKey {
        static let lastVerifiedTier = "red.forbes.sounding.subscription.lastVerifiedTier"
        static let lastVerifiedAt = "red.forbes.sounding.subscription.lastVerifiedAt"
        static let notSubscribedSince = "red.forbes.sounding.subscription.notSubscribedSince"
    }

    private var lastVerifiedTier: Tier? {
        get { (UserDefaults.standard.string(forKey: DefaultsKey.lastVerifiedTier)).flatMap(Tier.init(rawValue:)) }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: DefaultsKey.lastVerifiedTier) }
    }

    private var lastVerifiedAt: Date? {
        get {
            let value = UserDefaults.standard.double(forKey: DefaultsKey.lastVerifiedAt)
            return value > 0 ? Date(timeIntervalSince1970: value) : nil
        }
        set { UserDefaults.standard.set(newValue?.timeIntervalSince1970, forKey: DefaultsKey.lastVerifiedAt) }
    }

    private var persistedNotSubscribedSince: Date? {
        get {
            let value = UserDefaults.standard.double(forKey: DefaultsKey.notSubscribedSince)
            return value > 0 ? Date(timeIntervalSince1970: value) : nil
        }
        set { UserDefaults.standard.set(newValue?.timeIntervalSince1970, forKey: DefaultsKey.notSubscribedSince) }
    }

    private var cancellables = Set<AnyCancellable>()
    private nonisolated(unsafe) var reverifyTask: Task<Void, Never>?

    private init() {
        applyClassification(latestAttempt: .notYetAttempted, reason: .neverChecked)

        NotificationCenter.default.publisher(for: .sessionExpired)
            .sink { [weak self] _ in
                Task { @MainActor in self?.handleSessionEnded() }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .soundCloudAuthenticationChanged)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if self.hasAuthenticatedSession {
                        await self.verifyNow()
                    } else {
                        self.handleSessionEnded()
                    }
                }
            }
            .store(in: &cancellables)

        reverifyTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.reverifyInterval))
                guard !Task.isCancelled else { return }
                await self?.verifyNow()
            }
        }

        if SoundCloudAPI.credentials?.accessToken != nil {
            Task { [weak self] in await self?.verifyNow() }
        }
    }

    deinit {
        reverifyTask?.cancel()
    }

    func verifyNow() async {
        guard SoundCloudAPI.credentials?.accessToken != nil else { return }
        do {
            let user = try await SoundCloudAPI.shared.getCurrentUser()
            authenticatedAccountID = user.id
            let resolution = Self.resolve(from: user)
            let raw = Self.rawSubscriptionDescription(for: user)
            lastRawSubscriptionDescription = raw
            Self.log(resolution: resolution, raw: raw)
            applyClassification(
                latestAttempt: .succeeded(resolution.tier),
                reason: resolution.unknownReason
            )
        } catch {
            Self.logger.notice("Subscription check failed; tier left unconfirmed.")
            applyClassification(latestAttempt: .failed, reason: .checkFailed)
        }
    }

    func handleSessionEnded() {
        // Keep the last verified entitlement as private cached state so a
        // sign-out never destroys downloads or their ownership metadata.
        // Access stays closed through hasAuthenticatedSession until sign-in.
        persistedNotSubscribedSince = nil
        authenticatedAccountID = nil
        applyClassification(latestAttempt: .notYetAttempted, reason: .neverChecked)
    }

    private static let logger = Logger(
        subsystem: "red.forbes.sounding",
        category: "subscription"
    )

    private static func log(resolution: Resolution, raw: String?) {
        let payload = raw ?? "(none)"
        switch resolution.unknownReason {
        case .unrecognisedProductIDs(let ids):
            logger.error(
                """
                Unrecognised SoundCloud plan. ids=[\(ids.joined(separator: ", "), privacy: .public)] \
                raw:
                \(payload, privacy: .public)
                """
            )
        case .payloadUnreadable:
            logger.error(
                """
                /me carried no readable subscription info — wire shape may have changed. raw:
                \(payload, privacy: .public)
                """
            )
        case .neverChecked, .checkFailed, .none:
            logger.info(
                """
                Subscription resolved to \(resolution.tier.rawValue, privacy: .public). raw:
                \(payload, privacy: .public)
                """
            )
        }
    }

    private func applyClassification(latestAttempt: AttemptOutcome, reason: UnknownReason?) {
        let now = Date()

        if case .succeeded(let freshTier) = latestAttempt, freshTier != .unknown {
            lastVerifiedTier = freshTier
            lastVerifiedAt = now
            if freshTier == .goPlus {
                persistedNotSubscribedSince = nil
            } else if persistedNotSubscribedSince == nil {
                persistedNotSubscribedSince = now
            }
        }

        let (resolvedTier, resolvedVerification) = Self.classify(
            lastTier: lastVerifiedTier,
            lastVerifiedAt: lastVerifiedAt,
            latestAttempt: latestAttempt,
            now: now,
            gracePeriod: Self.gracePeriod
        )
        tier = resolvedTier
        verification = resolvedVerification
        notSubscribedSince = (resolvedVerification == .verifiedNotSubscribed) ? persistedNotSubscribedSince : nil
        unknownReason = (resolvedTier == .unknown) ? reason : nil
    }

    nonisolated static func classify(
        lastTier: Tier?,
        lastVerifiedAt: Date?,
        latestAttempt: AttemptOutcome,
        now: Date,
        gracePeriod: TimeInterval
    ) -> (tier: Tier, verification: VerificationStatus) {
        if case .succeeded(let freshTier) = latestAttempt, freshTier != .unknown {
            return freshTier == .goPlus
                ? (.goPlus, .verified)
                : (freshTier, .verifiedNotSubscribed)
        }

        guard let lastTier, let lastVerifiedAt else {
            return (.unknown, .unverifiable(withinGrace: false))
        }

        if lastTier == .goPlus {
            let withinGrace = now.timeIntervalSince(lastVerifiedAt) <= gracePeriod
            return (.goPlus, .unverifiable(withinGrace: withinGrace))
        }

        return (lastTier, .verifiedNotSubscribed)
    }

    nonisolated static let goPlusProductIDs: Set<String> = ["consumer-high-tier"]

    nonisolated static let goProductIDs: Set<String> = ["consumer-mid-tier"]

    nonisolated static let freeProductIDs: Set<String> = ["free"]

    nonisolated static let creatorProductIDPrefix = "creator-"

    struct Resolution: Equatable {
        var tier: Tier
        var unknownReason: UnknownReason?

        init(_ tier: Tier, _ unknownReason: UnknownReason? = nil) {
            self.tier = tier
            self.unknownReason = unknownReason
        }
    }

    nonisolated static func resolve(
        consumerRows: [ConsumerSubscription]?,
        consumerSingle: ConsumerSubscription? = nil,
        creatorRows: [CreatorSubscription]? = nil,
        creatorSingle: CreatorSubscription? = nil
    ) -> Resolution {
        let consumerIDs = Set(
            ((consumerRows ?? []) + [consumerSingle].compactMap { $0 })
                .compactMap { $0.product?.id }
        )
        let creatorIDs = Set(
            ((creatorRows ?? []) + [creatorSingle].compactMap { $0 })
                .compactMap { $0.product?.id }
        )

        if !consumerIDs.isDisjoint(with: goPlusProductIDs) { return Resolution(.goPlus) }
        if !consumerIDs.isDisjoint(with: goProductIDs) { return Resolution(.go) }

        let allIDs = consumerIDs.union(creatorIDs)
        if allIDs.contains(where: { $0.hasPrefix(creatorProductIDPrefix) }) {
            return Resolution(.creatorPro)
        }

        if !consumerIDs.isDisjoint(with: freeProductIDs) { return Resolution(.free) }

        if !allIDs.isEmpty {
            return Resolution(.unknown, .unrecognisedProductIDs(allIDs.sorted()))
        }

        let consumerArrayIsExplicitlyEmpty = consumerRows?.isEmpty == true
        let nothingElsePresent = consumerSingle == nil && creatorSingle == nil
            && (creatorRows?.isEmpty ?? true)
        if consumerArrayIsExplicitlyEmpty && nothingElsePresent {
            return Resolution(.free)
        }

        return Resolution(.unknown, .payloadUnreadable)
    }

    nonisolated static func resolve(from user: User?) -> Resolution {
        resolve(
            consumerRows: user?.consumerSubscriptions,
            consumerSingle: user?.consumerSubscription,
            creatorRows: user?.creatorSubscriptions,
            creatorSingle: user?.creatorSubscription
        )
    }

    nonisolated static func resolveTier(from subscriptions: [ConsumerSubscription]?) -> Tier {
        resolve(consumerRows: subscriptions).tier
    }

    nonisolated static func resolveTier(from user: User?) -> Tier {
        resolve(from: user).tier
    }

    nonisolated static func rawSubscriptionDescription(for user: User?) -> String? {
        guard let raw = user?.rawSubscriptionPayload, !raw.isEmpty else {
            return "no subscription keys present on /me"
        }
        return raw.keys.sorted()
            .map { "\($0) = \(raw[$0]?.diagnosticDescription ?? "null")" }
            .joined(separator: "\n")
    }
}
