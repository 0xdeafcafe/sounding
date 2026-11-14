import AppIntents
import Combine
import Foundation

struct OpenRemoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Remote"
    static let description = IntentDescription("Opens the Remote for your Apple TV.")
    static let supportedModes: IntentModes = .foreground

    @available(iOS 27.0, macOS 27.0, watchOS 27.0, tvOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        RemoteRequest.shared.open()
        return .result()
    }
}

@MainActor
final class RemoteRequest: ObservableObject {
    static let shared = RemoteRequest()
    nonisolated static let tabSymbol = "appletvremote.gen4"

    @Published private(set) var request: UUID?
    private var claimed: UUID?

    func open() {
        request = UUID()
    }

    func claim(_ id: UUID) -> Bool {
        guard claimed != id else { return false }
        claimed = id
        return true
    }
}
