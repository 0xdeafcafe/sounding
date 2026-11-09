import AppIntents
import Combine
import Foundation

struct IdentifySongIntent: AppIntent {
    static let title: LocalizedStringResource = "Identify Song"
    static let description = IntentDescription("Listens and names the song playing around you.")
    static let supportedModes: IntentModes = .foreground

    @available(iOS 27.0, macOS 27.0, watchOS 27.0, tvOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        IdentifySongRequests.shared.requestListen()
        return .result()
    }
}

@MainActor
final class IdentifySongRequests: ObservableObject {
    static let shared = IdentifySongRequests()

    @Published private(set) var pendingListen = false

    private init() {}

    func requestListen() {
        pendingListen = true
    }

    func consume() -> Bool {
        guard pendingListen else { return false }
        pendingListen = false
        return true
    }
}
