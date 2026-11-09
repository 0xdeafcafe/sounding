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
        case dj
        case creatorPro
        case unknown

        nonisolated var isAdFree: Bool { self == .go || self == .goPlus || self == .dj }

        nonisolated var displayName: String {
            switch self {
            case .free: return "Free"
            case .go: return "Go"
            case .goPlus: return "Go+"
            case .dj: return "DJ"
            case .creatorPro: return "Artist"
            case .unknown: return "Unknown"
            }
        }

        nonisolated var planName: String? {
            switch self {
            case .free: "SoundCloud Free"
            case .go: "SoundCloud Go"
            case .goPlus: "SoundCloud Go+"
            case .dj: "SoundCloud DJ"
            case .creatorPro: "SoundCloud Artist"
            case .unknown: nil
            }
        }
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
        guard hasAuthenticatedSession || authenticatedAccountID != nil else {
            return "Sign in to check your SoundCloud plan. Existing downloads stay stored but unavailable."
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
            return "SoundCloud Free. Go+ tracks play as previews."
        case (.go, _), (.goPlus, _), (.dj, _):
            let name = tier == .goPlus ? "SoundCloud Go+" : (tier == .dj ? "SoundCloud DJ" : "SoundCloud Go")
            let suffix = tier == .go ? " Go+ tracks need Go+." : ""
            switch verification {
            case .verified, .verifiedNotSubscribed:
                return name + "." + suffix
            case .unverifiable(let withinGrace):
                return withinGrace
                    ? "\(name), unconfirmed recently. Tracks still play."
                    : "\(name), but it hasn't been confirmed in a while."
            }
        case (.creatorPro, _):
            return "A SoundCloud artist plan. Go+ tracks play as previews."
        }
    }

    nonisolated static let gracePeriod: TimeInterval = 10 * 24 * 3600

    nonisolated static let deletionDelay: TimeInterval = 7 * 24 * 3600

    nonisolated static let offlineReconfirmLimit: TimeInterval = 30 * 24 * 3600

    var lastConfirmedAt: Date? { lastVerifiedAt }

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
    private let scheduler = WorkScheduler.shared

    private init() {
        applyClassification(latestAttempt: .notYetAttempted, reason: .neverChecked)

        SoundCloudCredentialSource.shared.$state
            .map(\.sessionHealth)
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    #if DEBUG
                    if let user = SoundCloudCredentialSource.visualFixtureUser {
                        self.applyVisualFixture(user)
                        return
                    }
                    #endif
                    if self.hasAuthenticatedSession {
                        await self.verifyNow()
                    } else {
                        self.handleSessionEnded()
                    }
                }
            }
            .store(in: &cancellables)

        scheduler.registerPeriodic(
            id: "account.subscription.reverify",
            scope: "account",
            initialDelay: .seconds(Self.reverifyInterval),
            interval: .seconds(Self.reverifyInterval),
            condition: {
                SoundCloudGateway.shared.isApplicationForeground
            }
        ) { [weak self] in
            guard let self else { return }
            await SoundCloudRequestEnvironment.autonomous(lane: .metadata) {
                await self.verifyNow()
            }
        }

        if SoundCloudAPI.credentials?.accessToken != nil {
            Task { [weak self] in await self?.verifyNow() }
        }
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

    #if DEBUG
    nonisolated static var fixtureTierOverride: String? {
        ProcessInfo.processInfo.environment["SOUNDING_TV_FIXTURE_TIER"]
    }

    private func applyVisualFixture(_ user: User) {
        switch Self.fixtureTierOverride {
        case "signedOut":
            authenticatedAccountID = nil
            tier = .unknown
            verification = .unverifiable(withinGrace: false)
            unknownReason = .neverChecked
        case let raw?:
            authenticatedAccountID = user.id
            let fixtureTier = Tier(rawValue: raw) ?? .goPlus
            tier = fixtureTier
            verification = fixtureTier.isAdFree ? .verified : .verifiedNotSubscribed
            unknownReason = nil
        case nil:
            authenticatedAccountID = user.id
            applyClassification(latestAttempt: .succeeded(.goPlus), reason: nil)
        }
    }
    #endif

    func handleSessionEnded() {
        #if DEBUG
        if let user = SoundCloudCredentialSource.visualFixtureUser {
            applyVisualFixture(user)
            return
        }
        #endif
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
            if freshTier.isAdFree {
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
            return freshTier.isAdFree
                ? (freshTier, .verified)
                : (freshTier, .verifiedNotSubscribed)
        }

        guard let lastTier, let lastVerifiedAt else {
            return (.unknown, .unverifiable(withinGrace: false))
        }

        if lastTier.isAdFree {
            let withinGrace = now.timeIntervalSince(lastVerifiedAt) <= gracePeriod
            return (lastTier, .unverifiable(withinGrace: withinGrace))
        }

        return (lastTier, .verifiedNotSubscribed)
    }

    nonisolated static let goPlusProductIDs: Set<String> = ["consumer-high-tier"]

    nonisolated static let goProductIDs: Set<String> = ["consumer-mid-tier"]

    nonisolated static let freeProductIDs: Set<String> = ["free"]

    nonisolated static let creatorProductIDPrefix = "creator-"

    nonisolated static let djProductIDs: Set<String> = ["consumer-dj", "consumer-dj-tier"]

    nonisolated static func isDJProductID(_ id: String) -> Bool {
        djProductIDs.contains(id)
    }

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

        if consumerIDs.contains(where: isDJProductID) { return Resolution(.dj) }
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

// MARK: - Entitlements

enum SoundCloudFeature: Sendable, Equatable {
    case playback
    case monetizedTrack
    case goPlusTrack
    case downloads
    case djGear
}

enum DJGearFeature: Sendable, CaseIterable {
    case decks
    case controllers
    case prep
    case usbExport
}

enum SoundCloudEntitlementError: LocalizedError, Equatable {
    case signedOut(SoundCloudFeature)
    case planUnconfirmed
    case needsGo(SoundCloudFeature)
    case needsGoPlus(SoundCloudFeature)
    case ownMusicOnly
    case previewOnly(needsGoPlus: Bool)

    var errorDescription: String? {
        switch self {
        case .signedOut(.downloads): return "Sign in to SoundCloud to download."
        case .signedOut: return "Sign in to SoundCloud to play tracks."
        case .planUnconfirmed: return "Couldn\u{2019}t confirm your SoundCloud plan."
        case .needsGo(.downloads): return "Downloads need SoundCloud Go or Go+."
        case .needsGo: return "Playback needs SoundCloud Go or Go+."
        case .needsGoPlus(.downloads): return "Downloading this track needs SoundCloud Go+."
        case .needsGoPlus(.djGear): return "DJ decks need SoundCloud Go+ for SoundCloud tracks."
        case .needsGoPlus: return "This track needs SoundCloud Go+."
        case .ownMusicOnly: return "Export to USB works with your own music."
        case .previewOnly(needsGoPlus: true): return "Full track needs SoundCloud Go+."
        case .previewOnly(needsGoPlus: false): return "Full track needs SoundCloud Go or Go+."
        }
    }

    var offersSubscription: Bool {
        switch self {
        case .needsGo, .needsGoPlus, .previewOnly: return true
        case .signedOut, .planUnconfirmed, .ownMusicOnly: return false
        }
    }
}

enum SoundCloudPlaybackGrant: Sendable, Equatable {
    case full
    case preview
    case denied(SoundCloudEntitlementError)
}

enum SoundCloudEntitlements {
    static let subscribeURL = URL(string: "https://soundcloud.com/go")!

    nonisolated static let monetizedTracksOpen = true

    nonisolated static let requiresSignInForPlayback = true

    nonisolated static func isOpenToEverySignedInAccount(_ feature: SoundCloudFeature) -> Bool {
        switch feature {
        case .playback, .downloads: return true
        case .monetizedTrack: return monetizedTracksOpen
        case .goPlusTrack, .djGear: return false
        }
    }

    nonisolated static func allowedTiers(for feature: SoundCloudFeature) -> Set<SubscriptionService.Tier> {
        switch feature {
        case .playback, .monetizedTrack, .downloads: return [.go, .goPlus, .dj]
        case .goPlusTrack, .djGear: return [.goPlus, .dj]
        }
    }

    nonisolated static func evaluate(
        _ feature: SoundCloudFeature,
        signedIn: Bool,
        tier: SubscriptionService.Tier,
        verification: SubscriptionService.VerificationStatus,
        requiresSignIn: Bool = requiresSignInForPlayback
    ) -> SoundCloudEntitlementError? {
        if !requiresSignIn {
            switch feature {
            case .playback:
                return nil
            case .goPlusTrack:
                guard signedIn, tier != .unknown, !allowedTiers(for: feature).contains(tier) else { return nil }
                return .needsGoPlus(feature)
            case .downloads, .monetizedTrack, .djGear:
                break
            }
        }
        guard signedIn else { return .signedOut(feature) }
        if isOpenToEverySignedInAccount(feature) { return nil }
        guard tier != .unknown else { return .planUnconfirmed }
        guard allowedTiers(for: feature).contains(tier) else {
            return allowedTiers(for: feature).contains(.go) ? .needsGo(feature) : .needsGoPlus(feature)
        }
        if case .unverifiable(withinGrace: false) = verification { return .planUnconfirmed }
        return nil
    }

    nonisolated static func isGoRestricted(_ track: Track) -> Bool {
        guard !track.isLocal else { return false }
        if track.requiresGoPlus || track.isSnipPolicy || track.isPreviewOnly { return true }
        return track.isMonetized && !monetizedTracksOpen
    }

    nonisolated static func trackDenial(
        for track: Track,
        feature: SoundCloudFeature,
        signedIn: Bool,
        tier: SubscriptionService.Tier,
        verification: SubscriptionService.VerificationStatus,
        requiresSignIn: Bool = requiresSignInForPlayback
    ) -> SoundCloudEntitlementError? {
        guard !track.isLocal else { return nil }
        return features(for: track, base: feature).lazy.compactMap {
            evaluate($0, signedIn: signedIn, tier: tier, verification: verification, requiresSignIn: requiresSignIn)
        }.first
    }

    nonisolated static func canDownload(
        _ track: Track,
        signedIn: Bool,
        tier: SubscriptionService.Tier,
        verification: SubscriptionService.VerificationStatus
    ) -> Bool {
        guard !track.isLocal, track.hasFullAudio else { return false }
        return trackDenial(for: track, feature: .downloads, signedIn: signedIn, tier: tier, verification: verification) == nil
    }

    nonisolated static func djGearDenial(
        _ feature: DJGearFeature,
        isSoundCloudTrack: Bool,
        signedIn: Bool,
        tier: SubscriptionService.Tier,
        verification: SubscriptionService.VerificationStatus,
        personalUnlocked: Bool
    ) -> SoundCloudEntitlementError? {
        guard isSoundCloudTrack, !personalUnlocked else { return nil }
        if feature == .usbExport { return .ownMusicOnly }
        return evaluate(.djGear, signedIn: signedIn, tier: tier, verification: verification)
    }

    nonisolated static func playbackGrant(
        for track: Track,
        signedIn: Bool,
        tier: SubscriptionService.Tier,
        verification: SubscriptionService.VerificationStatus,
        requiresSignIn: Bool = requiresSignInForPlayback
    ) -> SoundCloudPlaybackGrant {
        guard !track.isLocal else { return .full }
        let fullDenial = trackDenial(
            for: track, feature: .playback, signedIn: signedIn, tier: tier,
            verification: verification, requiresSignIn: requiresSignIn
        )
        if let fullDenial {
            return track.hasPreview ? .preview : .denied(fullDenial)
        }
        return track.isPreviewOnly ? .preview : .full
    }

    nonisolated static func blendableNext(
        after current: Track?,
        next: Track?,
        grant: (Track) -> SoundCloudPlaybackGrant
    ) -> Track? {
        guard let next, grant(next) != .preview else { return nil }
        if let current, grant(current) == .preview { return nil }
        return next
    }

    nonisolated static func previewDenial(for track: Track, tier: SubscriptionService.Tier) -> SoundCloudEntitlementError {
        let goUnlocksIt = track.isMonetized && !monetizedTracksOpen
            && !track.requiresGoPlus && !track.isSnipPolicy && !tier.isAdFree
        return .previewOnly(needsGoPlus: !goUnlocksIt)
    }

    nonisolated static func features(for track: Track, base: SoundCloudFeature) -> [SoundCloudFeature] {
        var features = [base]
        if base == .playback || base == .downloads, track.isMonetized { features.append(.monetizedTrack) }
        if track.requiresGoPlus || track.isSnipPolicy { features.append(.goPlusTrack) }
        return features
    }
}

extension SubscriptionService {
    var isSignedInForEntitlements: Bool {
        authenticatedAccountID != nil
    }

    func denial(for feature: SoundCloudFeature) -> SoundCloudEntitlementError? {
        SoundCloudEntitlements.evaluate(
            feature,
            signedIn: isSignedInForEntitlements || hasAuthenticatedSession,
            tier: tier,
            verification: verification
        )
    }

    func denial(for track: Track, feature: SoundCloudFeature) -> SoundCloudEntitlementError? {
        guard !track.isLocal else { return nil }
        for each in SoundCloudEntitlements.features(for: track, base: feature) {
            if let denial = denial(for: each) { return denial }
        }
        return nil
    }

    func djGearDenial(_ feature: DJGearFeature, isSoundCloudTrack: Bool, personalUnlocked: Bool) -> SoundCloudEntitlementError? {
        SoundCloudEntitlements.djGearDenial(
            feature,
            isSoundCloudTrack: isSoundCloudTrack,
            signedIn: isSignedInForEntitlements || hasAuthenticatedSession,
            tier: tier,
            verification: verification,
            personalUnlocked: personalUnlocked
        )
    }

    func requireEntitlement(for track: Track, feature: SoundCloudFeature) async throws {
        guard !track.isLocal else { return }
        await verifyIfNeverChecked()
        if let denial = denial(for: track, feature: feature) { throw denial }
    }

    func playbackGrant(for track: Track) -> SoundCloudPlaybackGrant {
        SoundCloudEntitlements.playbackGrant(
            for: track,
            signedIn: isSignedInForEntitlements || hasAuthenticatedSession,
            tier: tier,
            verification: verification
        )
    }

    func playsAsPreview(_ track: Track) -> Bool {
        playbackGrant(for: track) == .preview
    }

    func previewDenial(for track: Track) -> SoundCloudEntitlementError {
        SoundCloudEntitlements.previewDenial(for: track, tier: tier)
    }

    func requirePlaybackGrant(for track: Track, allowsPreview: Bool) async throws -> SoundCloudPlaybackGrant {
        guard !track.isLocal else { return .full }
        await verifyIfNeverChecked()
        switch playbackGrant(for: track) {
        case .full:
            return .full
        case .preview:
            guard allowsPreview else {
                throw denial(for: track, feature: .playback) ?? previewDenial(for: track)
            }
            return .preview
        case .denied(let denial):
            throw denial
        }
    }

    func displayedDuration(for track: Track) -> String {
        guard playsAsPreview(track) else { return track.formattedDuration }
        let seconds = Int(track.previewDuration > 0 ? track.previewDuration : track.duration)
        return String(format: "Preview \u{00B7} %d:%02d", seconds / 60, seconds % 60)
    }

    private func verifyIfNeverChecked() async {
        if tier == .unknown, hasAuthenticatedSession, unknownReason == .neverChecked || authenticatedAccountID == nil {
            await verifyNow()
        }
    }
}
