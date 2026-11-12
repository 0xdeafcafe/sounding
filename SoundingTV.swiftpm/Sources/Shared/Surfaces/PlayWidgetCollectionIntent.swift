import AppIntents
import Foundation

struct PlayWidgetCollectionIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Collection"
    static let description = IntentDescription("Plays a playlist, setlist or station chosen in a Sounding widget.")
    static let supportedModes: IntentModes = .background
    static let isDiscoverable = false

    @available(iOS 27.0, macOS 27.0, watchOS 27.0, tvOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Kind")
    var kind: String

    @Parameter(title: "Identifier")
    var collectionID: String

    @Parameter(title: "Shuffle", default: false)
    var shuffle: Bool

    init() {}

    init(_ collection: WidgetCollection, shuffle: Bool = false) {
        kind = collection.kind.rawValue
        collectionID = collection.itemID
        self.shuffle = shuffle
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await WidgetCollectionBridge.play(kind: kind, id: collectionID, shuffle: shuffle)
        return .result()
    }
}
