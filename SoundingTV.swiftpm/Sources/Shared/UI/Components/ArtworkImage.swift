import SwiftUI
import UIKit

struct ArtworkImage<Placeholder: View>: View {
    let url: URL?
    var variant: ArtworkVariant = .standard
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var loaded: SCResolvedArtwork?
    @State private var failedURL: URL?

    var body: some View {
        let displayed = SCResolvedArtwork.display(url: url, variant: variant, loaded: loaded)
        Group {
            if let displayed {
                Image(uiImage: displayed)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder()
                    .environment(\.soundingArtworkPending, url != nil && failedURL != url)
            }
        }
        .accessibilityHidden(true)
        .task(id: SCArtworkRequest(url: url, variant: variant)) {
            await SCResolvedArtwork.load(url: url, variant: variant, loaded: $loaded, failedURL: $failedURL)
        }
    }
}

extension ArtworkImage where Placeholder == ArtworkPlaceholder {
    init(url: URL?, variant: ArtworkVariant = .standard, icon: String = "music.note", identity: String? = nil) {
        self.init(url: url, variant: variant) { ArtworkPlaceholder(icon: icon, identity: identity) }
    }
}

struct ArtworkPlaceholder: View {
    var icon: String = "music.note"
    var identity: String?
    var subject: SoundingArtSubject?

    var body: some View {
        SoundingArtworkView(identity: identity ?? icon, subject: subject ?? Self.subject(for: icon))
    }

    static func subject(for icon: String) -> SoundingArtSubject {
        if icon.hasPrefix("person") { return .person }
        if icon.contains("list") || icon.contains("square.stack") || icon.contains("rectangle.stack") { return .collection }
        if icon.contains("radio") || icon.contains("antenna") { return .station }
        return .track
    }
}
