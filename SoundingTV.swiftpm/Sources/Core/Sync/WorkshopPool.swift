import Foundation
import Combine

enum WorkshopClaimState: String, Codable, Sendable {
    case claimed
    case running
    case completed
    case failed
}

struct WorkshopClaim: Sendable, Equatable, Codable {
    let jobId: String
    let job: WorkshopJob
    let subjectId: String
    let deviceId: String
    let deviceClass: DeviceClass
    let score: Int
    let claimedAtMillis: Int64
    var leaseExpiresAtMillis: Int64
    var state: WorkshopClaimState

    static func jobId(job: WorkshopJob, subjectId: String) -> String {
        "\(job.rawValue)#\(subjectId)"
    }
}

@MainActor
final class WorkshopPool: ObservableObject {
    static let shared = WorkshopPool()

    static let leaseDurationMillis: Int64 = 10 * 60 * 1000

    @Published private(set) var claims: [String: WorkshopClaim] = [:]

    var activeClaims: [WorkshopClaim] {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return claims.values
            .filter { $0.leaseExpiresAtMillis > now && $0.state != .completed && $0.state != .failed }
            .sorted { $0.claimedAtMillis < $1.claimedAtMillis }
    }

    private init() {}

    func proposeClaim(job: WorkshopJob, subjectId: String) -> WorkshopClaim? {
        let deviceClass = DeviceClass.current
        let conditions = DeviceConditions.unknown
        guard let score = WorkshopCapability.score(deviceClass: deviceClass, conditions: conditions, job: job) else {
            return nil
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let claim = WorkshopClaim(
            jobId: WorkshopClaim.jobId(job: job, subjectId: subjectId),
            job: job,
            subjectId: subjectId,
            deviceId: DownloadManifestDeviceIdentity.deviceId(),
            deviceClass: deviceClass,
            score: score,
            claimedAtMillis: now,
            leaseExpiresAtMillis: now + Self.leaseDurationMillis,
            state: .claimed
        )
        claims[claim.jobId] = claim
        return claim
    }

    func shouldYield(to other: WorkshopClaim, mine: WorkshopClaim) -> Bool {
        guard other.jobId == mine.jobId, other.deviceId != mine.deviceId else { return false }
        if other.score != mine.score {
            return other.score > mine.score
        }
        return other.deviceId > mine.deviceId
    }

    func renewLease(_ jobId: String) {
        guard var claim = claims[jobId] else { return }
        claim.leaseExpiresAtMillis = Int64(Date().timeIntervalSince1970 * 1000) + Self.leaseDurationMillis
        claim.state = .running
        claims[jobId] = claim
    }

    func complete(_ jobId: String) {
        guard var claim = claims[jobId] else { return }
        claim.state = .completed
        claims[jobId] = claim
    }

    func fail(_ jobId: String) {
        guard var claim = claims[jobId] else { return }
        claim.state = .failed
        claims[jobId] = claim
    }

    func adopt(_ incoming: [WorkshopClaim]) {
        guard !incoming.isEmpty else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for claim in incoming {
            if let existing = claims[claim.jobId], existing.claimedAtMillis > claim.claimedAtMillis {
                continue
            }
            claims[claim.jobId] = claim
        }
        claims = claims.filter { $0.value.leaseExpiresAtMillis > now || $0.value.state == .completed }
    }
}
