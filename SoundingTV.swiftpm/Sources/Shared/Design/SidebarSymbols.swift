import SwiftUI
#if os(iOS)
import UIKit
#endif

enum SidebarSymbol {
    static let home = "house"
    static let search = "magnifyingglass"
    static let decks = "dial.medium"
    static let stations = "dot.radiowaves.left.and.right"
    static let hardware = "slider.vertical.3"
    static let recentlyAdded = "clock"
    static let tracks = "music.note"
    static let albums = "square.stack"
    static let artists = "music.microphone"
    static let sets = "headphones"
    static let setlists = "list.number"
    static let downloads = "arrow.down.circle"
    static let history = "clock.arrow.circlepath"
    static let mixes = "waveform.path"
    static let allPlaylists = "music.note.list"
    static let likes = "heart"
    static let folder = "folder"
    static let pinnedPlaylist = "play.square.stack"
    static let privateShares = "lock"
    static let yourMusic = "music.note.house"
    static let following = "person.2"
}

struct SidebarGlyph: View {
    let systemName: String

    init(_ systemName: String) {
        self.systemName = systemName
    }

    var body: some View {
        Image(systemName: systemName)
            .symbolVariant(.none)
            .fontWeight(.regular)
            .foregroundStyle(Color.scAccent)
    }
}

#if os(iOS)
@MainActor
enum SidebarTabIcon {
    private static var cache: [String: Image] = [:]

    static func image(_ systemName: String) -> Image {
        if let cached = cache[systemName] { return cached }
        let configuration = UIImage.SymbolConfiguration(weight: .regular)
        let image: Image
        if let base = UIImage(systemName: systemName, withConfiguration: configuration) {
            image = Image(uiImage: base.withTintColor(UIColor(Color.scAccent), renderingMode: .alwaysOriginal))
        } else {
            image = Image(systemName: systemName)
        }
        cache[systemName] = image
        return image
    }
}
#endif
