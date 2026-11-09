import Combine
import Foundation
import Observation

@MainActor
@Observable
final class DJPlanEditStore {
    static let shared = DJPlanEditStore()

    private(set) var library: DJPlanEditLibrary

    @ObservationIgnored private let persist: (DJPlanEditLibrary) -> Void
    @ObservationIgnored private var updates: AnyCancellable?

    init(
        library: DJPlanEditLibrary? = nil,
        persist: ((DJPlanEditLibrary) -> Void)? = nil,
        updates: AnyPublisher<DJPlanEditLibrary, Never>? = nil
    ) {
        let usesSettings = library == nil && persist == nil
        self.library = library ?? (usesSettings ? DJPlanEditLibrary(data: SettingsStore.shared.djPlanEdits) : DJPlanEditLibrary())
        self.persist = persist ?? (usesSettings ? { SettingsStore.shared.setDJPlanEdits($0.encoded) } : { _ in })
        let stream = updates ?? (usesSettings ? SettingsStore.shared.$djPlanEdits.map(DJPlanEditLibrary.init(data:)).eraseToAnyPublisher() : nil)
        self.updates = stream?
            .removeDuplicates()
            .sink { [weak self] value in
                MainActor.assumeIsolated {
                    guard let self, self.library != value else { return }
                    self.library = value
                }
            }
    }

    func record(for key: DJPlanTransitionKey) -> DJPlanEditRecord {
        library[key]
    }

    func update(_ key: DJPlanTransitionKey, _ change: (inout DJPlanEditRecord) -> Void) {
        var next = library
        var record = next[key]
        change(&record)
        next[key] = record
        guard next != library else { return }
        library = next
        persist(next)
    }
}
