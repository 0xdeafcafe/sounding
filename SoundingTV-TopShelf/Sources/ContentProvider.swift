@preconcurrency import TVServices

final class ContentProvider: TVTopShelfContentProvider {

    nonisolated(nonsending) override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        let plan = TopShelfLayout.plan(
            for: TopShelfStore.load(),
            placeholder: (Self.placeholder1x, Self.placeholder2x)
        )

        switch plan {
        case .fallback(let reason):
            Log.topShelf.info("Serving the default shelf (\(String(describing: reason), privacy: .public))")
            return DefaultShelf.content(for: reason)

        case .rows(let rows):
            let sections = rows.map { row -> TVTopShelfItemCollection<TVTopShelfSectionedItem> in
                let collection = TVTopShelfItemCollection(items: row.tiles.map(Self.item(for:)))
                collection.title = row.title
                return collection
            }
            Log.topShelf.info("Serving \(sections.count) shelves")
            return TVTopShelfSectionedContent(sections: sections)
        }
    }

    private static let placeholder1x = Bundle.main.url(forResource: "ShelfPlaceholder", withExtension: "png")
    private static let placeholder2x = Bundle.main.url(forResource: "ShelfPlaceholder@2x", withExtension: "png")

    private static func item(for tile: TopShelfTile) -> TVTopShelfSectionedItem {
        let item = TVTopShelfSectionedItem(identifier: tile.id)
        item.title = tile.title
        item.imageShape = shape(for: tile.shape)
        item.playbackProgress = tile.progress
        item.setImageURL(tile.imageURL, for: .screenScale1x)
        item.setImageURL(tile.imageURL2x, for: .screenScale2x)
        item.displayAction = TVTopShelfAction(url: tile.displayURL)
        item.playAction = TVTopShelfAction(url: tile.playURL)
        return item
    }

    private static func shape(for shape: TopShelfShape) -> TVTopShelfSectionedItem.ImageShape {
        switch shape {
        case .square: return .square
        case .poster: return .poster
        case .hdtv:   return .hdtv
        }
    }
}
