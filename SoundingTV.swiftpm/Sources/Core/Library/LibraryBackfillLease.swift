import Foundation

struct LibraryBackfillLease: Codable, Sendable, Equatable {
    var holderId: String
    var deviceClass: DeviceClass
    var rank: Int
    var renewedAtMillis: Int64
    var expiresAtMillis: Int64
    var pausedUntilMillis: Int64?

    var renewedAt: Date { LibraryBackfillElection.date(renewedAtMillis) }
    var expiresAt: Date { LibraryBackfillElection.date(expiresAtMillis) }
    var pausedUntil: Date? { pausedUntilMillis.map(LibraryBackfillElection.date) }

    func isValid(at now: Date) -> Bool { expiresAt > now }

    func isPaused(at now: Date) -> Bool { pausedUntil.map { $0 > now } ?? false }
}

struct LibraryBackfillCandidate: Sendable, Equatable {
    var id: String
    var deviceClass: DeviceClass
    var isOnPower: Bool
    var lastSeen: Date
    var contends = true

    var rank: Int { LibraryBackfillElection.rank(deviceClass, isOnPower: isOnPower) }
}

enum LibraryBackfillRole: String, Sendable, Equatable {
    case undecided
    case backfiller
    case follower
}

enum LibraryBackfillDecision: Sendable, Equatable {
    case claim
    case renew
    case hold
    case follow

    var role: LibraryBackfillRole {
        switch self {
        case .claim, .renew, .hold: return .backfiller
        case .follow: return .follower
        }
    }
}

struct LibraryBackfillPolicy: Sendable {
    var leaseDuration: TimeInterval = 10 * 60
    var renewInterval: TimeInterval = 3 * 60
    var aliveWindow: TimeInterval = 5 * 60
    var existenceWindow: TimeInterval = 14 * 24 * 60 * 60
    var takeoverStep: TimeInterval = 3 * 60
    var decisionDeadline: TimeInterval = 90
    var manifestRefreshInterval: TimeInterval = 6 * 60 * 60

    static let standard = LibraryBackfillPolicy()
}

enum LibraryBackfillElection {
    static let capableClasses: Set<DeviceClass> = [.mac, .pad, .phone]

    static func rank(_ deviceClass: DeviceClass, isOnPower: Bool) -> Int {
        switch deviceClass {
        case .mac: return isOnPower ? 0 : 2
        case .pad, .phone: return isOnPower ? 1 : 2
        case .tv: return 3
        case .watch: return 4
        }
    }

    static func precedes(_ lhs: LibraryBackfillCandidate, _ rhs: LibraryBackfillCandidate) -> Bool {
        if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
        return lhs.id < rhs.id
    }

    static func isExcluded(
        _ candidate: LibraryBackfillCandidate,
        among others: [LibraryBackfillCandidate],
        lease: LibraryBackfillLease?,
        now: Date,
        policy: LibraryBackfillPolicy = .standard
    ) -> Bool {
        guard !capableClasses.contains(candidate.deviceClass) else { return false }
        let capablePeer = others.contains { other in
            other.id != candidate.id
                && capableClasses.contains(other.deviceClass)
                && now.timeIntervalSince(other.lastSeen) <= policy.existenceWindow
        }
        if capablePeer { return true }
        guard let lease, lease.holderId != candidate.id, capableClasses.contains(lease.deviceClass) else { return false }
        return now.timeIntervalSince(lease.renewedAt) <= policy.existenceWindow
    }

    static func decide(
        me: LibraryBackfillCandidate,
        peers: [LibraryBackfillCandidate],
        lease: LibraryBackfillLease?,
        pausedUntil: Date? = nil,
        vacantSince: Date?,
        now: Date,
        policy: LibraryBackfillPolicy = .standard
    ) -> LibraryBackfillDecision {
        let others = peers.filter { $0.id != me.id }
        if isExcluded(me, among: others, lease: lease, now: now, policy: policy) { return .follow }
        if let lease, lease.isValid(at: now) {
            guard lease.holderId == me.id else { return .follow }
            let wantedPause = pausedUntil.flatMap { $0 > now ? millis($0) : nil }
            if now.timeIntervalSince(lease.renewedAt) >= policy.renewInterval { return .renew }
            if lease.pausedUntilMillis != wantedPause { return .renew }
            if lease.rank != me.rank || lease.deviceClass != me.deviceClass { return .renew }
            return .hold
        }
        let everyone = [me] + others
        let contenders = everyone
            .filter { candidate in
                candidate.id == me.id
                    || (candidate.contends && now.timeIntervalSince(candidate.lastSeen) <= policy.aliveWindow)
            }
            .filter { candidate in
                !isExcluded(candidate, among: everyone, lease: lease, now: now, policy: policy)
            }
            .sorted(by: precedes)
        guard let position = contenders.firstIndex(where: { $0.id == me.id }) else { return .follow }
        if position == 0 { return .claim }
        let waited = vacantSince.map { now.timeIntervalSince($0) } ?? 0
        return waited >= policy.takeoverStep * Double(position) ? .claim : .follow
    }

    static func lease(
        for me: LibraryBackfillCandidate,
        pausedUntil: Date?,
        now: Date,
        policy: LibraryBackfillPolicy = .standard
    ) -> LibraryBackfillLease {
        let base = max(now, pausedUntil ?? now)
        return LibraryBackfillLease(
            holderId: me.id,
            deviceClass: me.deviceClass,
            rank: me.rank,
            renewedAtMillis: millis(now),
            expiresAtMillis: millis(base.addingTimeInterval(policy.leaseDuration)),
            pausedUntilMillis: pausedUntil.flatMap { $0 > now ? millis($0) : nil }
        )
    }

    static func mayReplace(_ current: LibraryBackfillLease?, with proposal: LibraryBackfillLease, now: Date) -> Bool {
        guard let current else { return true }
        return current.holderId == proposal.holderId || !current.isValid(at: now)
    }

    static func newer(_ lhs: LibraryBackfillLease?, _ rhs: LibraryBackfillLease?) -> LibraryBackfillLease? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return rhs.renewedAtMillis > lhs.renewedAtMillis ? rhs : lhs
    }

    static func writerCandidate(writerId: String, seenAtMillis: Int64) -> LibraryBackfillCandidate? {
        guard let prefix = writerId.split(separator: ".", maxSplits: 1).first,
              let deviceClass = DeviceClass(rawValue: String(prefix)) else { return nil }
        return LibraryBackfillCandidate(
            id: writerId,
            deviceClass: deviceClass,
            isOnPower: false,
            lastSeen: date(seenAtMillis),
            contends: false
        )
    }

    static func millis(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

    static func date(_ millis: Int64) -> Date { Date(timeIntervalSince1970: Double(millis) / 1000) }
}

extension LibraryChunk {
    static let leaseCollection = "lease"

    var isLease: Bool { collection == Self.leaseCollection }

    var carriesRows: Bool { !isManifest && !isLease }

    static func leaseChunk(account: String, lease: LibraryBackfillLease) -> LibraryChunk {
        LibraryChunk(
            account: account,
            collection: leaseCollection,
            bucket: 0,
            bucketCount: 1,
            updatedAtMillis: lease.renewedAtMillis,
            writerId: lease.holderId,
            rows: [],
            manifest: nil,
            lease: lease
        )
    }
}
