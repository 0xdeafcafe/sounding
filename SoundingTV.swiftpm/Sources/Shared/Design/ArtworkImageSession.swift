import Foundation
import SwiftUI

@MainActor
enum ArtworkImageSession {
    static let memoryBytes = 20 * 1024 * 1024
    static let diskBytes = 200 * 1024 * 1024

    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.default
        let cache = URLCache(memoryCapacity: memoryBytes, diskCapacity: diskBytes)
        configuration.urlCache = cache
        MemoryRelief.addHandler { _ in
            cache.memoryCapacity = 0
            cache.memoryCapacity = memoryBytes
        }
        return URLSession(
            configuration: configuration,
            delegate: NetworkActivityTaskObserver(feature: .artwork),
            delegateQueue: nil
        )
    }()

    static func clear() {
        shared.configuration.urlCache?.removeAllCachedResponses()
    }
}

extension View {
    @ViewBuilder
    func artworkImageCaching() -> some View {
        if #available(iOS 27.0, macOS 27.0, *) {
            asyncImageURLSession(ArtworkImageSession.shared)
        } else {
            self
        }
    }
}
