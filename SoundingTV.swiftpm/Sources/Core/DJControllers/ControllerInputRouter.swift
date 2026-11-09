import Foundation

@MainActor
final class ControllerInputRouter {
    enum Outcome: Equatable {
        case performed(DeckControlAction)
        case blocked(DeckControlAction)
        case unmapped
    }

    let profile: ControllerProfile
    private let resolver: ControllerMappingResolver
    private weak var surface: (any DeckControlSurface)?
    private let access: () -> ControllerDeckAccess
    private let content: (MixEngine.Deck) -> ControllerDeckContent

    init(
        profile: ControllerProfile,
        surface: any DeckControlSurface,
        access: @escaping () -> ControllerDeckAccess,
        content: @escaping (MixEngine.Deck) -> ControllerDeckContent
    ) {
        self.profile = profile
        self.resolver = ControllerMappingResolver(profile.mapping)
        self.surface = surface
        self.access = access
        self.content = content
    }

    @discardableResult
    func handle(_ message: ControllerMIDIMessage) -> Outcome {
        guard let action = resolver.resolve(message) else { return .unmapped }
        guard access().permits(action, content: content) else { return .blocked(action) }
        surface?.perform(action)
        return .performed(action)
    }
}
