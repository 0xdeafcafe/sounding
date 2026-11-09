import CloudKit
import Foundation
import UIKit
import os

@MainActor
final class NearbyLinkRequestPublisher {
    static let shared = NearbyLinkRequestPublisher()
    nonisolated static let ledgerKey = "nearbyLinkRequest.outstanding.v1"

    private static let lastPostedKey = "nearbyLinkRequest.lastPosted.v1"
    private static let absenceKey = "nearbyLinkRequest.absence.v1"
    private static let recheckSpacing: TimeInterval = 30 * 60

    struct Context: Equatable {
        var accountId: String?
        var isActive: Bool
        var isPairing: Bool
        var seesUnlinkedPhone: Bool
        var linkedDeviceIds: [String]
        var linkedDeviceCount: Int

        static let idle = Context(accountId: nil, isActive: false, isPairing: false, seesUnlinkedPhone: false, linkedDeviceIds: [], linkedDeviceCount: 0)
    }

    private struct Outstanding {
        let request: NearbyLinkRequest
        let linkedCount: Int
    }

    private var context = Context.idle
    private var outstanding: Outstanding?
    private var isChecking = false
    private var quietUntil: Date?
    private var expiry: Task<Void, Never>?
    private let ledger = SignInRequestLedger(storageKey: NearbyLinkRequestPublisher.ledgerKey)
    private let defaults = UserDefaults.standard

    static func sweepLeftovers() {
        SignInRequestPublisher.sweepLeftovers(ledger: SignInRequestLedger(storageKey: ledgerKey))
    }

    func update(_ next: Context) {
        let wasActive = context.isActive
        context = next
        if wasActive != next.isActive { trackAbsence(isActive: next.isActive) }
        reconcile()
    }

    private func reconcile(now: Date = .now) {
        if let outstanding {
            let withdrawal = NearbyLinkRequestPolicy.withdrawal(
                expiresAt: outstanding.request.expiresAt,
                now: now,
                isActive: context.isActive,
                isSignedIn: context.accountId != nil,
                linkedSincePosting: context.linkedDeviceCount > outstanding.linkedCount
            )
            if withdrawal != .keep { withdraw(withdrawal) }
            return
        }
        guard !isChecking, SignInRequestPublisher.isEnabled, let accountId = context.accountId, !accountId.isEmpty else { return }
        if let quietUntil, now < quietUntil { return }
        let accountTag = AccountSignIn.accountTag(userId: accountId)
        let lastPosted = lastPostedAt(accountTag: accountTag)
        guard decide(now: now, lastPosted: lastPosted, snoozedAt: nil) == .post else { return }
        isChecking = true
        Task { [weak self] in
            await self?.check(accountId: accountId, accountTag: accountTag, lastPosted: lastPosted)
            self?.isChecking = false
        }
    }

    private func decide(now: Date, lastPosted: Date?, snoozedAt: Date?) -> NearbyLinkRequestPolicy.Decision {
        NearbyLinkRequestPolicy.decide(
            now: now,
            hasReason: NearbyLinkRequestPolicy.hasReason(
                isSignedIn: context.accountId != nil,
                isActive: context.isActive,
                isPairing: context.isPairing,
                seesUnlinkedPhone: context.seesUnlinkedPhone,
                linkedDeviceCount: context.linkedDeviceCount
            ),
            lastPostedAt: lastPosted,
            snoozedAt: snoozedAt,
            lastAbsence: absence.lastAbsence
        )
    }

    private func check(accountId: String, accountTag: String, lastPosted: Date?) async {
        let container = CKContainer(identifier: CloudSyncContainer.identifier)
        guard (try? await container.accountStatus()) == .available else {
            quietUntil = Date().addingTimeInterval(Self.recheckSpacing)
            return
        }
        let database = container.privateCloudDatabase
        let tvTag = NearbyLinkRequest.tvTag(deviceId: LinkPeerIdentity.localDeviceId())
        let snooze: NearbyLinkSnooze?
        do {
            snooze = NearbyLinkSnooze(record: try await database.record(for: NearbyLinkSnooze.recordID(tvTag: tvTag)))
        } catch let error as CKError where error.code == .unknownItem {
            snooze = nil
        } catch {
            Log.link.info("[NearbyLinkRequest] snooze unreadable: \(error.localizedDescription, privacy: .public)")
            quietUntil = Date().addingTimeInterval(Self.recheckSpacing)
            return
        }
        guard context.accountId == accountId, outstanding == nil else { return }
        let decision = decide(now: .now, lastPosted: lastPosted, snoozedAt: snooze?.snoozedAt)
        guard decision == .post else {
            if decision == .snoozed {
                quietUntil = Date().addingTimeInterval(Self.recheckSpacing)
                Log.link.info("[NearbyLinkRequest] not asking: Not Now on a phone")
            }
            return
        }
        guard let request = NearbyLinkRequest.make(
            tvName: UIDevice.current.name,
            tvDeviceId: LinkPeerIdentity.localDeviceId(),
            accountId: accountId,
            linkedDeviceIds: context.linkedDeviceIds
        ) else { return }
        ledger.add(request.recordName)
        do {
            _ = try await database.modifyRecords(saving: [request.record()], deleting: [], savePolicy: .allKeys, atomically: false)
            setLastPosted(request.createdAt, accountTag: accountTag)
            outstanding = Outstanding(request: request, linkedCount: context.linkedDeviceCount)
            scheduleExpiry(request.expiresAt)
            Log.link.info("[NearbyLinkRequest] asked this account's phones to link")
            reconcile()
        } catch {
            ledger.remove([request.recordName])
            quietUntil = Date().addingTimeInterval(Self.recheckSpacing)
            Log.link.info("[NearbyLinkRequest] not sent: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func withdraw(_ reason: NearbyLinkRequestPolicy.Withdrawal) {
        guard let outstanding else { return }
        self.outstanding = nil
        expiry?.cancel()
        expiry = nil
        let ledger = ledger
        let recordName = outstanding.request.recordName
        let recordID = CKRecord.ID(recordName: recordName)
        let database = CKContainer(identifier: CloudSyncContainer.identifier).privateCloudDatabase
        Log.link.info("[NearbyLinkRequest] withdrawn: \(String(describing: reason), privacy: .public)")
        Task.detached {
            let outcome: Error?
            do {
                let results = try await database.modifyRecords(saving: [], deleting: [recordID]).deleteResults
                if case .failure(let error) = results[recordID] { outcome = error } else { outcome = nil }
            } catch {
                outcome = error
            }
            guard !SignInRequestLedger.settled([recordName: outcome]).isEmpty else { return }
            ledger.remove([recordName])
        }
    }

    private func scheduleExpiry(_ date: Date) {
        expiry?.cancel()
        expiry = Task { [weak self] in
            let delay = max(1, date.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.reconcile()
        }
    }

    // MARK: - Memory

    private var absence: NearbyLinkAbsence {
        get {
            guard let data = defaults.data(forKey: Self.absenceKey),
                  let decoded = try? JSONDecoder().decode(NearbyLinkAbsence.self, from: data) else { return NearbyLinkAbsence() }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Self.absenceKey)
        }
    }

    private func trackAbsence(isActive: Bool) {
        var next = absence
        if isActive { next.cameBack(at: .now) } else { next.wentAway(at: .now) }
        absence = next
    }

    private func lastPostedAt(accountTag: String) -> Date? {
        let stored = defaults.dictionary(forKey: Self.lastPostedKey) as? [String: Double] ?? [:]
        return stored[accountTag].map(Date.init(timeIntervalSince1970:))
    }

    private func setLastPosted(_ date: Date, accountTag: String) {
        defaults.set([accountTag: date.timeIntervalSince1970], forKey: Self.lastPostedKey)
    }
}
