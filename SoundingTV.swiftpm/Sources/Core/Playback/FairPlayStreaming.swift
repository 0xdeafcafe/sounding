import AVFoundation
import Foundation
import os

enum FairPlayDebugLog {
    static func note(_ message: @autoclosure () -> String) {
        #if DEBUG
        guard isEnabled else { return }
        NSLog("[FairPlay] %@", message())
        #endif
    }

    #if DEBUG
    private static let isEnabled = ProcessInfo.processInfo.environment["SOUNDING_TV_LOG_FAIRPLAY"] == "1"
    #endif
}

struct FairPlayLicence: Sendable {
    let token: String
    let trackID: String
}

enum FairPlayLicenceError: Error, LocalizedError, Equatable, Sendable {
    case missingLicenceToken
    case invalidKeyIdentifier
    case certificateUnavailable(status: Int)
    case licenceRefused(status: Int)
    case rateLimited
    case malformedLicence
    case unsupportedOnThisDevice

    var entitlementError: SoundCloudEntitlementError? {
        switch self {
        case .licenceRefused(let status) where status == 401 || status == 403:
            return .needsGoPlus(.goPlusTrack)
        default:
            return nil
        }
    }

    var errorDescription: String? {
        switch self {
        case .rateLimited:
            return "SoundCloud is busy. Try again in a minute."
        case .unsupportedOnThisDevice:
            return "Protected Go+ tracks can\u{2019}t play in the Simulator."
        case .licenceRefused(let status) where status == 401 || status == 403:
            return SoundCloudEntitlementError.needsGoPlus(.goPlusTrack).errorDescription
        default:
            return "SoundCloud couldn\u{2019}t unlock this Go+ track. Try again."
        }
    }
}

enum FairPlayLicenceRegistry {
    private struct State: Sendable {
        var licences: [URL: FairPlayLicence] = [:]
        var order: [URL] = []
        var failures: [String: FairPlayLicenceError] = [:]
    }

    private static let capacity = 24
    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func register(token: String, trackID: String, for url: URL) {
        state.withLock { state in
            if state.licences[url] == nil { state.order.append(url) }
            state.licences[url] = FairPlayLicence(token: token, trackID: trackID)
            state.failures[trackID] = nil
            while state.order.count > capacity {
                state.licences[state.order.removeFirst()] = nil
            }
        }
    }

    static func licence(for url: URL) -> FairPlayLicence? {
        state.withLock { $0.licences[url] }
    }

    static func recordFailure(_ error: FairPlayLicenceError, trackID: String) {
        state.withLock { $0.failures[trackID] = error }
    }

    static func failure(trackID: String) -> FairPlayLicenceError? {
        state.withLock { $0.failures[trackID] }
    }

    static func takeFailure(trackID: String) -> FairPlayLicenceError? {
        state.withLock { $0.failures.removeValue(forKey: trackID) }
    }
}

@MainActor
enum FairPlayLicenceServer {
    static let endpoint = URL(string: "https://license.media-streaming.soundcloud.cloud/playback/fairplay")!

    private static var certificate: Data?
    private static var certificateTask: Task<Data, Error>?

    private static var context: SoundCloudRequestContext {
        SoundCloudRequestContext(intent: .playback, lane: .media, allowsBackground: true, coalesces: false)
    }

    static func applicationCertificate() async throws -> Data {
        if let certificate { return certificate }
        if let certificateTask { return try await certificateTask.value }
        let task = Task { @MainActor in try await fetchCertificate() }
        certificateTask = task
        defer { certificateTask = nil }
        let data = try await task.value
        certificate = data
        return data
    }

    private static func fetchCertificate() async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        let (data, response) = try await SoundCloudGateway.shared.data(for: request, context: context)
        FairPlayDebugLog.note("certificate status=\(response.statusCode) bytes=\(data.count)")
        if response.statusCode == 429 { throw FairPlayLicenceError.rateLimited }
        guard response.statusCode == 200, let decoded = decodeCertificate(data) else {
            throw FairPlayLicenceError.certificateUnavailable(status: response.statusCode)
        }
        return decoded
    }

    static func decodeCertificate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        if data.first == 0x30 { return data }
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let decoded = Data(base64Encoded: text), !decoded.isEmpty else { return data }
        return decoded
    }

    static func contentKey(spc: Data, assetID: String, licenceToken: String) async throws -> Data {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.percentEncodedQuery = "license_token=" + formEncoded(licenceToken)
        guard let url = components?.url else { throw FairPlayLicenceError.missingLicenceToken }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("spc=\(spc.base64EncodedString())&assetId=\(assetID)".utf8)
        let (data, response) = try await SoundCloudGateway.shared.data(for: request, context: context)
        FairPlayDebugLog.note("licence status=\(response.statusCode) spc=\(spc.count) bytes response=\(data.count) bytes")
        if response.statusCode == 429 { throw FairPlayLicenceError.rateLimited }
        guard response.statusCode == 200 else {
            throw FairPlayLicenceError.licenceRefused(status: response.statusCode)
        }
        guard let ckc = decodeLicence(data) else { throw FairPlayLicenceError.malformedLicence }
        return ckc
    }

    static func decodeLicence(_ data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let decoded = Data(base64Encoded: text), !decoded.isEmpty else { return nil }
        return decoded
    }

    static func formEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

final class FairPlayKeyDelivery: NSObject, AVContentKeySessionDelegate, @unchecked Sendable {
    let licence: FairPlayLicence
    let session: AVContentKeySession
    private let queue = DispatchQueue(label: "red.forbes.sounding.fairplay")

    init(licence: FairPlayLicence) {
        self.licence = licence
        session = AVContentKeySession(keySystem: .fairPlayStreaming)
        super.init()
        session.setDelegate(self, queue: queue)
    }

    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
        respond(to: keyRequest)
    }

    func contentKeySession(_ session: AVContentKeySession, didProvideRenewingContentKeyRequest keyRequest: AVContentKeyRequest) {
        respond(to: keyRequest)
    }

    func contentKeySession(_ session: AVContentKeySession, contentKeyRequest keyRequest: AVContentKeyRequest, didFailWithError err: any Error) {
        let error = err as NSError
        FairPlayDebugLog.note("key request failed track=\(licence.trackID) domain=\(error.domain) code=\(error.code)")
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        shouldRetry keyRequest: AVContentKeyRequest,
        reason retryReason: AVContentKeyRequest.RetryReason
    ) -> Bool {
        retryReason == .timedOut
            || retryReason == .receivedResponseWithExpiredLease
            || retryReason == .receivedObsoleteContentKey
    }

    static func assetID(fromKeyIdentifier identifier: Any?) -> String? {
        guard let raw = identifier as? String else { return nil }
        let id = raw.hasPrefix("skd://") ? String(raw.dropFirst("skd://".count)) : raw
        return id.isEmpty ? nil : id
    }

    private func respond(to keyRequest: AVContentKeyRequest) {
        let licence = licence
        let box = KeyRequestBox(keyRequest)
        guard let assetID = Self.assetID(fromKeyIdentifier: keyRequest.identifier) else {
            FairPlayDebugLog.note("key request track=\(licence.trackID) has no skd identifier")
            fail(box, with: .invalidKeyIdentifier, trackID: licence.trackID)
            return
        }
        FairPlayDebugLog.note("key request track=\(licence.trackID)")
        Task { @MainActor in
            do {
                let certificate = try await FairPlayLicenceServer.applicationCertificate()
                let spc = try await Self.serverPlaybackContext(box, certificate: certificate, assetID: assetID)
                FairPlayDebugLog.note("spc track=\(licence.trackID) bytes=\(spc.count)")
                let ckc = try await FairPlayLicenceServer.contentKey(spc: spc, assetID: assetID, licenceToken: licence.token)
                box.request.processContentKeyResponse(AVContentKeyResponse(fairPlayStreamingKeyResponseData: ckc))
                FairPlayDebugLog.note("key delivered track=\(licence.trackID) ckc=\(ckc.count) bytes")
            } catch let error as FairPlayLicenceError {
                FairPlayDebugLog.note("key failed track=\(licence.trackID) \(String(describing: error))")
                self.fail(box, with: error, trackID: licence.trackID)
            } catch {
                let nsError = error as NSError
                FairPlayDebugLog.note("key failed track=\(licence.trackID) domain=\(nsError.domain) code=\(nsError.code)")
                if Self.isTrafficStop(error) {
                    FairPlayLicenceRegistry.recordFailure(.rateLimited, trackID: licence.trackID)
                }
                box.request.processContentKeyResponseError(error)
            }
        }
    }

    static func isTrafficStop(_ error: Error) -> Bool {
        if let apiError = error as? APIError {
            switch apiError {
            case .rateLimited, .temporarilyBlocked: return true
            default: return false
            }
        }
        if let gatewayError = error as? SoundCloudGatewayError {
            switch gatewayError {
            case .endpointCoolingDown, .backgroundPaused: return true
            default: return false
            }
        }
        return false
    }

    private func fail(_ box: KeyRequestBox, with error: FairPlayLicenceError, trackID: String) {
        FairPlayLicenceRegistry.recordFailure(error, trackID: trackID)
        box.request.processContentKeyResponseError(error)
    }

    private static func serverPlaybackContext(_ box: KeyRequestBox, certificate: Data, assetID: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            box.request.makeStreamingContentKeyRequestData(
                forApp: certificate,
                contentIdentifier: Data(assetID.utf8),
                options: [AVContentKeyRequestProtocolVersionsKey: [1]]
            ) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? FairPlayLicenceError.malformedLicence)
                }
            }
        }
    }
}

private final class KeyRequestBox: @unchecked Sendable {
    let request: AVContentKeyRequest

    init(_ request: AVContentKeyRequest) {
        self.request = request
    }
}

enum FairPlayStreaming {
    static var isSupported: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return true
        #endif
    }

    nonisolated(unsafe) private static var associationKey: UInt8 = 0

    static func makeAsset(url: URL) -> AVURLAsset {
        let asset = AVURLAsset(url: url)
        attachIfNeeded(to: asset)
        return asset
    }

    static func attachIfNeeded(to asset: AVURLAsset) {
        guard isSupported, let licence = FairPlayLicenceRegistry.licence(for: asset.url) else { return }
        guard objc_getAssociatedObject(asset, &associationKey) == nil else { return }
        let delivery = FairPlayKeyDelivery(licence: licence)
        delivery.session.addContentKeyRecipient(asset)
        objc_setAssociatedObject(asset, &associationKey, delivery, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        FairPlayDebugLog.note("key session attached track=\(licence.trackID)")
    }

    static func playbackFailure(for trackID: String, replacing error: Error) -> Error {
        guard let failure = FairPlayLicenceRegistry.takeFailure(trackID: trackID) else { return error }
        return failure.entitlementError ?? failure
    }
}
