import CloudKit
import Foundation
import Network
import UIKit
import os

@MainActor
final class SignInRequestPublisher {
    enum Phase: Equatable {
        case idle
        case saving
        case sent
        case withdrawn
    }

    private(set) var phase: Phase = .idle
    private(set) var request: SignInRequest?
    let rendezvous: String?
    var onSent: (() -> Void)?

    private let database: CKDatabase?
    private let ledger: SignInRequestLedger
    private var saveTask: Task<Void, Never>?

    init(enabled: Bool = SignInRequestPublisher.isEnabled, ledger: SignInRequestLedger = SignInRequestLedger()) {
        rendezvous = SignInRequest.makeRendezvous()
        database = enabled ? CKContainer(identifier: CloudSyncContainer.identifier).privateCloudDatabase : nil
        self.ledger = ledger
    }

    static func sweepLeftovers(ledger: SignInRequestLedger = SignInRequestLedger()) {
        let names = ledger.recordNames
        guard isEnabled, !names.isEmpty else { return }
        let container = CKContainer(identifier: CloudSyncContainer.identifier)
        Task.detached(priority: .utility) {
            guard (try? await container.accountStatus()) == .available else { return }
            let ids = names.map { CKRecord.ID(recordName: $0) }
            guard let results = try? await container.privateCloudDatabase.modifyRecords(saving: [], deleting: ids, atomically: false).deleteResults else { return }
            var outcomes: [String: Error?] = [:]
            for (id, result) in results {
                switch result {
                case .success: outcomes[id.recordName] = .some(nil)
                case .failure(let error): outcomes[id.recordName] = error
                }
            }
            let settled = SignInRequestLedger.settled(outcomes)
            ledger.remove(settled)
            Log.link.info("[SignInRequest] cleared \(settled.count, privacy: .public) left over from an earlier launch")
        }
    }

    static var isEnabled: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SOUNDING_TV_UI_FIXTURE"] == "1" { return false }
        if ProcessInfo.processInfo.environment["SOUNDING_TV_SIGNIN_STORY"] != nil { return false }
        #endif
        return CloudSyncEngineController.containerIdentifierIsEntitled(CloudSyncContainer.identifier)
    }

    func publish(tvName: String = UIDevice.current.name) {
        guard phase == .idle, let database, let rendezvous,
              let request = SignInRequest(rendezvous: rendezvous, tvName: tvName, tvKind: .current, createdAt: .now) else { return }
        phase = .saving
        self.request = request
        ledger.add(request.recordName)
        let record = request.record()
        saveTask = Task { [weak self] in
            do {
                guard try await CKContainer(identifier: CloudSyncContainer.identifier).accountStatus() == .available else {
                    self?.phase = .withdrawn
                    return
                }
                _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys, atomically: false)
                guard let self, !Task.isCancelled, self.phase == .saving else { return }
                self.phase = .sent
                Log.link.info("[SignInRequest] asked this account's iPhones to sign in")
                self.onSent?()
            } catch {
                Log.link.info("[SignInRequest] not sent: \(error.localizedDescription, privacy: .public)")
                self?.phase = .withdrawn
            }
        }
    }

    func withdraw() {
        let wasSaving = phase == .saving || phase == .sent
        phase = .withdrawn
        guard wasSaving, let database, let request else { return }
        let pending = saveTask
        let ledger = ledger
        let recordName = request.recordName
        let recordID = CKRecord.ID(recordName: recordName)
        Task.detached {
            await pending?.value
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
}

@MainActor
final class DevicePickerInviter {
    enum Outcome: Equatable {
        case sent
        case failed
    }

    private var connection: NWConnection?
    private var timeout: Task<Void, Never>?

    static let descriptor = NWBrowser.Descriptor.applicationService(name: DevicePickerSignIn.serviceName)

    static var parameters: NWParameters { .applicationService }

    func send(to endpoint: NWEndpoint, credentials: SessionCredentials, tvName: String = UIDevice.current.name, completion: @escaping (Outcome) -> Void) {
        cancel()
        let invitation = DevicePickerSignIn.Invitation(
            version: DevicePickerSignIn.wireVersion,
            sessionId: credentials.sessionId,
            secretBase64: credentials.secret.base64EncodedString(),
            createdAt: credentials.createdAt,
            tvName: String(tvName.prefix(SignInRequest.maximumNameLength)),
            tvKind: DeviceClass.current.rawValue
        )
        guard let payload = try? DevicePickerSignIn.encode(invitation) else {
            completion(.failed)
            return
        }
        let connection = NWConnection(to: endpoint, using: Self.parameters)
        self.connection = connection
        var finished = false
        let finish: @MainActor (Outcome) -> Void = { [weak self] outcome in
            guard !finished else { return }
            finished = true
            self?.timeout?.cancel()
            completion(outcome)
        }
        connection.stateUpdateHandler = { state in
            Task { @MainActor in
                switch state {
                case .ready:
                    connection.send(content: payload, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
                        Task { @MainActor in
                            finish(error == nil ? .sent : .failed)
                        }
                    })
                case .failed, .cancelled:
                    finish(.failed)
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            finish(.failed)
            self?.cancel()
        }
    }

    func cancel() {
        timeout?.cancel()
        timeout = nil
        connection?.cancel()
        connection = nil
    }
}
