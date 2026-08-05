import Foundation
import UIKit

@MainActor
final class LegacyArtworkCache {
    static let shared = LegacyArtworkCache()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private init() {
        cache.countLimit = 120
    }

    func image(for url: URL, variant: ArtworkVariant) async -> UIImage? {
        let key = "\(url.absoluteString)#\(variant)"

        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        if let running = inFlight[key] {
            return await running.value
        }

        let task = Task<UIImage?, Never> { [attempts = variant.requestURLs(for: url)] in
            for candidate in attempts {
                guard let (data, response) = try? await URLSession.shared.data(from: candidate) else {
                    continue
                }
                if let http = response as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    continue
                }
                if let image = UIImage(data: data) {
                    return image
                }
            }
            return nil
        }

        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil

        if let image {
            cache.setObject(image, forKey: key as NSString)
        }
        return image
    }
}
