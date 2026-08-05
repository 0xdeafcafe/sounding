import Foundation
import TVServices

enum DefaultShelf {

    enum Reason {
        case signedOut
        case noSnapshot
        case emptyLibrary
    }

    static func content(for reason: Reason) -> TVTopShelfContent {
        let item = TVTopShelfCarouselItem(identifier: "default-shelf.\(identifierSuffix(for: reason))")
        item.title = title(for: reason)
        item.summary = summary(for: reason)
        item.contextTitle = "SoundingCloud"

        let art = artwork(for: reason)
        item.setImageURL(art.oneX, for: .screenScale1x)
        item.setImageURL(art.twoX, for: .screenScale2x)

        let action = TVTopShelfAction(url: destinationURL(for: reason))
        item.playAction = action
        item.displayAction = action

        return TVTopShelfCarouselContent(style: .details, items: [item])
    }

    private static func title(for reason: Reason) -> String {
        switch reason {
        case .signedOut:    return "Sign in to start listening"
        case .noSnapshot:   return "Open SoundingCloud"
        case .emptyLibrary: return "Nothing to show yet"
        }
    }

    private static func summary(for reason: Reason) -> String {
        switch reason {
        case .signedOut:
            return "Signing in happens on your iPhone. Scan the code to get SoundingCloud for iPhone, then come back here and follow the sign-in screen."
        case .noSnapshot:
            return "Recently played tracks, likes and playlists show up here once you start listening."
        case .emptyLibrary:
            return "Play a track, like something, or follow a playlist and it'll show up here."
        }
    }

    private static func identifierSuffix(for reason: Reason) -> String {
        switch reason {
        case .signedOut:    return "signed-out"
        case .noSnapshot:   return "no-snapshot"
        case .emptyLibrary: return "empty-library"
        }
    }

    private static func destinationURL(for reason: Reason) -> URL {
        switch reason {
        case .signedOut:
            return TopShelfStore.signInURL()
        case .noSnapshot, .emptyLibrary:
            return TopShelfStore.homeURL()
        }
    }

    private static let artworkURL1x = Bundle.main.url(forResource: "DefaultShelfArt", withExtension: "png")
    private static let artworkURL2x = Bundle.main.url(forResource: "DefaultShelfArt@2x", withExtension: "png")

    private static let signInArtworkURL1x = Bundle.main.url(forResource: "SignInShelfArt", withExtension: "png")
    private static let signInArtworkURL2x = Bundle.main.url(forResource: "SignInShelfArt@2x", withExtension: "png")

    private static func artwork(for reason: Reason) -> (oneX: URL?, twoX: URL?) {
        switch reason {
        case .signedOut:
            return (signInArtworkURL1x ?? artworkURL1x, signInArtworkURL2x ?? artworkURL2x)
        case .noSnapshot, .emptyLibrary:
            return (artworkURL1x, artworkURL2x)
        }
    }
}
