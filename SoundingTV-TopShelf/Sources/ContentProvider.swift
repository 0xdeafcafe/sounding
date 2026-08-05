import TVServices

final class ContentProvider: TVTopShelfContentProvider {

    override func loadTopShelfContent(completionHandler: @escaping (TVTopShelfContent?) -> Void) {
        guard let snapshot = TopShelfStore.load() else {
            completionHandler(DefaultShelf.content(for: .noSnapshot))
            return
        }

        var seen = Set<String>()
        var sections: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] = []
        var dropped = 0

        for section in snapshot.sections {
            var items: [TVTopShelfSectionedItem] = []
            for entry in section.entries {
                guard seen.insert(entry.id).inserted else {
                    dropped += 1
                    continue
                }
                items.append(item(for: entry))
            }
            guard !items.isEmpty else { continue }

            let collection = TVTopShelfItemCollection(items: items)
            collection.title = section.title
            sections.append(collection)
        }

        if dropped > 0 {
            Log.topShelf.info("Dropped \(dropped) duplicate item identifiers")
        }

        guard !sections.isEmpty else {
            let reason: DefaultShelf.Reason = snapshot.isSignedIn ? .emptyLibrary : .signedOut
            Log.topShelf.info("Snapshot from \(snapshot.generatedAt, privacy: .public) has no renderable shelves (isSignedIn=\(snapshot.isSignedIn, privacy: .public)) — serving the default state")
            completionHandler(DefaultShelf.content(for: reason))
            return
        }

        Log.topShelf.info("Serving \(sections.count) shelves / \(seen.count) items from a snapshot generated \(snapshot.generatedAt, privacy: .public)")
        completionHandler(TVTopShelfSectionedContent(sections: sections))
    }

    private func item(for entry: TopShelfEntry) -> TVTopShelfSectionedItem {
        let item = TVTopShelfSectionedItem(identifier: entry.id)

        item.title = entry.subtitle.isEmpty ? entry.title : "\(entry.title) · \(entry.subtitle)"
        item.imageShape = shape(for: entry.shape)
        item.playbackProgress = entry.progress

        item.setImageURL(entry.artworkURL, for: .screenScale1x)
        item.setImageURL(entry.artworkURL2x ?? entry.artworkURL, for: .screenScale2x)

        if let url = entry.actionURL {
            let action = TVTopShelfAction(url: url)
            item.playAction = action
            item.displayAction = action
        }
        return item
    }

    private func shape(for shape: TopShelfShape) -> TVTopShelfSectionedItem.ImageShape {
        switch shape {
        case .square: return .square
        case .poster: return .poster
        case .hdtv:   return .hdtv
        }
    }
}
