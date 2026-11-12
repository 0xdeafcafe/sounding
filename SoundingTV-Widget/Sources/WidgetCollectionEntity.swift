import AppIntents
import Foundation

struct WidgetCollectionEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Collection")
    }

    static let defaultQuery = WidgetCollectionQuery()

    let id: String
    let title: String
    let detail: String
    let symbol: String

    init(_ collection: WidgetCollection) {
        id = collection.id
        title = collection.title
        detail = collection.detail
        symbol = collection.fallbackSymbol
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(detail)", image: .init(systemName: symbol))
    }
}

struct WidgetCollectionQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [WidgetCollectionEntity] {
        let found = Dictionary(
            WidgetCollectionStore.load().map { ($0.id, WidgetCollectionEntity($0)) },
            uniquingKeysWith: { first, _ in first }
        )
        return identifiers.compactMap { found[$0] }
    }

    func entities(matching string: String) async throws -> [WidgetCollectionEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return try await suggestedEntities() }
        return WidgetCollectionStore.load()
            .filter { $0.title.localizedCaseInsensitiveContains(query) }
            .map(WidgetCollectionEntity.init)
    }

    func suggestedEntities() async throws -> [WidgetCollectionEntity] {
        WidgetCollectionStore.load().map(WidgetCollectionEntity.init)
    }
}

struct CollectionWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Play"
    static let description = IntentDescription("Choose a playlist, setlist or station to start from the widget.")

    @Parameter(title: "Collection")
    var collection: WidgetCollectionEntity?

    init() {}
}
