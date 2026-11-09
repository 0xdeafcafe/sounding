@MainActor
final class MixEngine {
    enum Deck: Int, CaseIterable, Hashable, Identifiable, Sendable {
        case a = 0
        case b = 1

        var id: Int { rawValue }
    }
}
