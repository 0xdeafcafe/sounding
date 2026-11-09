import Foundation

enum ArtworkVariant: Hashable, Sendable, CaseIterable {
    case thumbnail
    case standard
    case hero
    case signed

    var maxPixelSize: Int {
        #if os(watchOS)
        switch self {
        case .thumbnail: return 120
        case .standard: return 240
        case .hero, .signed: return 400
        }
        #elseif os(tvOS)
        switch self {
        case .thumbnail: return 300
        case .standard: return 500
        case .hero, .signed: return 1800
        }
        #elseif os(macOS)
        switch self {
        case .thumbnail: return 200
        case .standard: return 500
        case .hero, .signed: return 1600
        }
        #else
        switch self {
        case .thumbnail: return 240
        case .standard: return 500
        case .hero, .signed: return 1200
        }
        #endif
    }

    var candidates: [String] {
        switch self {
        case .signed:
            return []
        case .hero:
            return ["original", "t500x500", "large"]
        case .thumbnail, .standard:
            let pixels = maxPixelSize
            if pixels <= 200 { return ["t200x200", "t300x300", "t500x500", "large"] }
            if pixels <= 300 { return ["t300x300", "t500x500", "large"] }
            return ["t500x500", "large"]
        }
    }

    var derivationSources: [ArtworkVariant] {
        switch self {
        case .thumbnail: return [.standard, .hero]
        case .standard: return [.hero]
        case .hero, .signed: return []
        }
    }

    var displayFallbacks: [ArtworkVariant] {
        switch self {
        case .thumbnail: return [.standard, .hero]
        case .standard: return [.hero, .thumbnail]
        case .hero: return [.standard, .thumbnail]
        case .signed: return []
        }
    }

    var diskTag: String {
        switch self {
        case .thumbnail: return "thumbnail"
        case .standard: return "standard"
        case .hero: return "hero"
        case .signed: return "signed"
        }
    }

    func requestURLs(for url: URL) -> [URL] {
        switch self {
        case .signed:
            return [url]
        case .thumbnail, .standard, .hero:
            return candidates.map { url.soundCloudArtworkVariant($0) }
        }
    }
}

extension URL {
    var soundCloudArtworkIdentity: String {
        let string = absoluteString
        guard query == nil, host?.contains("sndcdn") == true,
              let dot = string.lastIndex(of: "."),
              let dash = string[..<dot].lastIndex(of: "-") else { return string }
        return String(string[..<dash]) + "-t500x500" + String(string[dot...])
    }

    func soundCloudArtworkVariant(_ variant: String) -> URL {
        guard host?.contains("sndcdn") == true, query == nil else { return self }

        let string = absoluteString
        guard let dot = string.lastIndex(of: "."),
              let dash = string[..<dot].lastIndex(of: "-") else { return self }

        let rebuilt = String(string[..<dash]) + "-" + variant + String(string[dot...])
        return URL(string: rebuilt) ?? self
    }
}
