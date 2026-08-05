import Foundation

enum ArtworkVariant: Hashable {
    case standard
    case hero
    case signed

    var candidates: [String] {
        switch self {
        case .standard: return ["t500x500", "large"]
        case .hero:     return ["original", "t500x500", "large"]
        case .signed:   return []
        }
    }

    func requestURLs(for url: URL) -> [URL] {
        switch self {
        case .signed:
            return [url]
        case .standard, .hero:
            return candidates.map { url.soundCloudArtworkVariant($0) }
        }
    }
}

extension URL {
    var soundCloudArtworkIdentity: String {
        soundCloudArtworkVariant("t500x500").absoluteString
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
