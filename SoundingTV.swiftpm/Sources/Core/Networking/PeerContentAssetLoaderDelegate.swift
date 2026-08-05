import Foundation
import AVFoundation

final class PeerContentAssetLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "soundingtv-peer"

    private let client: PeerContentClient
    private let trackId: String
    private let contentType: String
    let queue = DispatchQueue(label: "red.forbes.sounding.peercontent.loader")

    private var totalLength: Int64?
    private var pendingInfoRequests: [AVAssetResourceLoadingRequest] = []
    private var cancelledRequests = Set<ObjectIdentifier>()

    init(client: PeerContentClient, trackId: String, contentType: String) {
        self.client = client
        self.trackId = trackId
        self.contentType = contentType
    }

    static func assetURL(trackId: String) -> URL {
        URL(string: "\(scheme)://\(trackId)")!
    }

    static func contentType(forFileExtension ext: String) -> String {
        switch ext {
        case "mp3": return "public.mp3"
        case "m4a": return "public.mpeg-4-audio"
        case "flac": return "org.xiph.flac"
        default: return "public.audio"
        }
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        queue.async { [weak self] in
            self?.fulfill(loadingRequest)
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let id = ObjectIdentifier(loadingRequest)
            self.cancelledRequests.insert(id)
            self.pendingInfoRequests.removeAll { $0 === loadingRequest }
        }
    }

    private func fulfill(_ loadingRequest: AVAssetResourceLoadingRequest) {
        guard let dataRequest = loadingRequest.dataRequest else {
            if let totalLength {
                applyContentInformation(loadingRequest, totalLength: totalLength)
                loadingRequest.finishLoading()
            } else {
                pendingInfoRequests.append(loadingRequest)
                fetchLength()
            }
            return
        }

        let offset = Int64(dataRequest.currentOffset)
        let length: Int64 = dataRequest.requestsAllDataToEndOfResource
            ? -1
            : Int64(dataRequest.requestedLength) - Int64(dataRequest.currentOffset - dataRequest.requestedOffset)

        client.fetchRange(trackId: trackId, offset: offset, length: length) { [weak self] result in
            guard let self else { return }
            self.queue.async { [self] in
                handleFetchResult(result, for: loadingRequest, dataRequest: dataRequest)
            }
        }
    }

    private func handleFetchResult(
        _ result: Result<(data: Data, totalLength: Int64), PeerContentError>,
        for loadingRequest: AVAssetResourceLoadingRequest,
        dataRequest: AVAssetResourceLoadingDataRequest
    ) {
        let id = ObjectIdentifier(loadingRequest)
        guard !cancelledRequests.contains(id) else {
            cancelledRequests.remove(id)
            return
        }

        switch result {
        case .success(let fetched):
            recordLength(fetched.totalLength)
            if loadingRequest.contentInformationRequest != nil {
                applyContentInformation(loadingRequest, totalLength: fetched.totalLength)
            }
            dataRequest.respond(with: fetched.data)
            loadingRequest.finishLoading()
        case .failure(let error):
            loadingRequest.finishLoading(with: Self.nsError(for: error))
        }
    }

    private func fetchLength() {
        guard totalLength == nil else { return }
        client.fetchRange(trackId: trackId, offset: 0, length: 0) { [weak self] result in
            guard let self else { return }
            self.queue.async { [self] in
                switch result {
                case .success(let fetched):
                    self.recordLength(fetched.totalLength)
                    let pending = self.pendingInfoRequests
                    self.pendingInfoRequests.removeAll()
                    for request in pending {
                        let id = ObjectIdentifier(request)
                        guard !self.cancelledRequests.contains(id) else {
                            self.cancelledRequests.remove(id)
                            continue
                        }
                        self.applyContentInformation(request, totalLength: fetched.totalLength)
                        request.finishLoading()
                    }
                case .failure(let error):
                    let pending = self.pendingInfoRequests
                    self.pendingInfoRequests.removeAll()
                    for request in pending {
                        request.finishLoading(with: Self.nsError(for: error))
                    }
                }
            }
        }
    }

    private func recordLength(_ total: Int64) {
        guard totalLength == nil else { return }
        totalLength = total
    }

    private func applyContentInformation(_ loadingRequest: AVAssetResourceLoadingRequest, totalLength: Int64) {
        guard let info = loadingRequest.contentInformationRequest else { return }
        info.contentType = contentType
        info.contentLength = totalLength
        info.isByteRangeAccessSupported = true
    }

    private static func nsError(for error: PeerContentError) -> NSError {
        NSError(
            domain: "red.forbes.sounding.peercontent",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: String(describing: error)]
        )
    }
}
