import Foundation
import TVServices

enum DefaultShelf {

    static func content(for reason: TopShelfFallback) -> TVTopShelfContent {
        let item = TVTopShelfCarouselItem(identifier: "default-shelf.\(identifierSuffix(for: reason))")
        item.contextTitle = "Sounding"
        item.title = title(for: reason)
        item.summary = summary(for: reason)

        item.setImageURL(artworkURL1x, for: .screenScale1x)
        item.setImageURL(artworkURL2x ?? artworkURL1x, for: .screenScale2x)

        let action = TVTopShelfAction(url: destinationURL(for: reason))
        item.playAction = action
        item.displayAction = action

        return TVTopShelfCarouselContent(style: .details, items: [item])
    }

    private static func title(for reason: TopShelfFallback) -> String {
        switch reason {
        case .signedOut:    return String(localized: "Sign In")
        case .noSnapshot:   return String(localized: "Open Sounding")
        case .emptyLibrary: return String(localized: "Nothing Here Yet")
        }
    }

    private static func summary(for reason: TopShelfFallback) -> String {
        switch reason {
        case .signedOut:
            return String(localized: "Open Sounding on this Apple TV, then scan the sign-in code with your iPhone.")
        case .noSnapshot:
            return String(localized: "Your recently played music, likes and mixes appear here.")
        case .emptyLibrary:
            return String(localized: "Play or like something and it appears here.")
        }
    }

    private static func identifierSuffix(for reason: TopShelfFallback) -> String {
        switch reason {
        case .signedOut:    return "signed-out"
        case .noSnapshot:   return "no-snapshot"
        case .emptyLibrary: return "empty-library"
        }
    }

    private static func destinationURL(for reason: TopShelfFallback) -> URL {
        switch reason {
        case .signedOut:
            return TopShelfStore.signInURL()
        case .noSnapshot, .emptyLibrary:
            return TopShelfStore.homeURL()
        }
    }

    private static let artworkURL1x = Bundle.main.url(forResource: "DefaultShelfArt", withExtension: "png")
    private static let artworkURL2x = Bundle.main.url(forResource: "DefaultShelfArt@2x", withExtension: "png")
}
