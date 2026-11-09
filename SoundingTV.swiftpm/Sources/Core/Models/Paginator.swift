import Foundation
import Combine
import SwiftUI

enum PagedCursor: Sendable, Equatable {
    case start
    case offset(Int)
    case url(URL)
}

struct PagedChunk<Item> {
    var items: [Item]
    var next: PagedCursor?
    var total: Int?

    init(items: [Item], next: PagedCursor? = nil, total: Int? = nil) {
        self.items = items
        self.next = next
        self.total = total
    }
}

struct PagedSource<Item> {
    var first: @MainActor () async throws -> PagedChunk<Item>
    var next: @MainActor (PagedCursor) async throws -> PagedChunk<Item>
    var fillsEagerly: Bool

    init(
        first: @escaping @MainActor () async throws -> PagedChunk<Item>,
        next: @escaping @MainActor (PagedCursor) async throws -> PagedChunk<Item>,
        fillsEagerly: Bool = false
    ) {
        self.first = first
        self.next = next
        self.fillsEagerly = fillsEagerly
    }
}

@MainActor
final class Paginator<Item: Identifiable>: ObservableObject {
    @Published private(set) var items: [Item] = [] {
        didSet { revision &+= 1 }
    }
    private(set) var revision = 0
    @Published private(set) var isLoadingFirst = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var firstError: Error?
    @Published private(set) var loadMoreError: Error?
    @Published private(set) var pausedUntil: Date?
    @Published private(set) var total: Int?
    @Published private(set) var hasLoadedFirst = false
    @Published private(set) var cursor: PagedCursor?
    @Published private(set) var awaitsUser = false

    private var source: PagedSource<Item>
    private let gate: @MainActor () -> Date?
    private let gateApplies: @MainActor (PagedCursor?) -> Bool
    private let blockedUntil: (Error) -> Date?
    private let now: () -> Date
    private let sleep: @MainActor (TimeInterval) async -> Void
    private let maxConsecutiveEmptyChunks: Int
    private let maxUnattendedPages: Int
    private let resumeJitter: () -> TimeInterval
    private var unattendedPages = 0
    private var generation = 0
    private var resume: Resume?
    private var resumeTask: Task<Void, Never>?
    private var requestCount = 0

    private enum Resume { case first, more }

    var onAppend: (([Item]) -> Void)?

    init(
        source: PagedSource<Item>,
        gate: @escaping @MainActor () -> Date? = { nil },
        gateApplies: @escaping @MainActor (PagedCursor?) -> Bool = { _ in true },
        blockedUntil: @escaping (Error) -> Date? = { _ in nil },
        now: @escaping () -> Date = Date.init,
        sleep: @escaping @MainActor (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        },
        maxConsecutiveEmptyChunks: Int = 12,
        maxUnattendedPages: Int = 10,
        resumeJitter: @escaping () -> TimeInterval = { Double.random(in: 0...20) }
    ) {
        self.source = source
        self.gate = gate
        self.gateApplies = gateApplies
        self.blockedUntil = blockedUntil
        self.now = now
        self.sleep = sleep
        self.maxConsecutiveEmptyChunks = maxConsecutiveEmptyChunks
        self.maxUnattendedPages = maxUnattendedPages
        self.resumeJitter = resumeJitter
    }

    var hasMore: Bool { cursor != nil }
    var isLoading: Bool { isLoadingFirst || isLoadingMore }
    var isComplete: Bool { hasLoadedFirst && cursor == nil }
    var didFailLoadingMore: Bool { loadMoreError != nil }
    var isPaused: Bool { pausedUntil != nil }
    var fetchCount: Int { requestCount }

    func countText(singular: String, plural: String) -> String {
        let loaded = items.count
        let count = isComplete ? loaded : max(loaded, total ?? loaded)
        let noun = count == 1 ? singular : plural
        if total == nil, hasMore { return "\(count)+ \(noun)" }
        return "\(count) \(noun)"
    }

    func setSource(_ newSource: PagedSource<Item>) {
        source = newSource
    }

    func prime(items newItems: [Item], cursor newCursor: PagedCursor?, total newTotal: Int? = nil) {
        generation += 1
        items = deduplicated(newItems)
        cursor = newCursor
        if let newTotal { total = newTotal }
        hasLoadedFirst = true
        firstError = nil
        loadMoreError = nil
        isLoadingFirst = false
        isLoadingMore = false
        fillRestIfEager()
    }

    private func fillRestIfEager() {
        guard source.fillsEagerly, cursor != nil else { return }
        let token = generation
        Task { [weak self] in
            guard let self, token == self.generation else { return }
            await self.loadMore()
        }
    }

    func reset() {
        generation += 1
        resumeTask?.cancel()
        resumeTask = nil
        resume = nil
        items = []
        cursor = nil
        total = nil
        hasLoadedFirst = false
        firstError = nil
        loadMoreError = nil
        pausedUntil = nil
        isLoadingFirst = false
        isLoadingMore = false
        unattendedPages = 0
        awaitsUser = false
    }

    func reload() async {
        generation += 1
        let token = generation
        loadMoreError = nil
        unattendedPages = 0
        awaitsUser = false
        isLoadingMore = false
        if gateApplies(nil), let until = gate() {
            pause(until: until, resume: .first)
            return
        }
        isLoadingFirst = true
        defer { if token == generation { isLoadingFirst = false } }
        requestCount += 1
        do {
            let chunk = try await source.first()
            guard token == generation else { return }
            items = deduplicated(chunk.items)
            cursor = chunk.next
            if let total = chunk.total { self.total = total }
            hasLoadedFirst = true
            firstError = nil
            pausedUntil = nil
            if !items.isEmpty { onAppend?(items) }
            fillRestIfEager()
        } catch {
            guard token == generation, !isCancellation(error) else { return }
            if let until = blockedUntil(error) {
                pause(until: until, resume: .first)
                return
            }
            firstError = error
        }
    }

    func loadMore() async {
        guard cursor != nil, hasLoadedFirst, !isLoadingMore, !isLoadingFirst, loadMoreError == nil, pausedUntil == nil else { return }
        await fetchMore()
    }

    func retry() async {
        if hasLoadedFirst {
            loadMoreError = nil
            await loadMore()
        } else {
            await reload()
        }
    }

    func loadMoreIfNeeded(after item: Item, lead: Int = 8) {
        guard cursor != nil, items.suffix(max(1, lead)).contains(where: { $0.id == item.id }) else { return }
        attend()
        Task { await loadMore() }
    }

    func requestMore() {
        guard cursor != nil, !isLoadingMore, !isLoadingFirst, pausedUntil == nil, loadMoreError == nil else { return }
        guard unattendedPages < maxUnattendedPages else {
            awaitsUser = true
            return
        }
        unattendedPages += 1
        Task { await loadMore() }
    }

    func attend() {
        unattendedPages = 0
        if awaitsUser { awaitsUser = false }
    }

    func continueLoading() {
        attend()
        requestMore()
    }

    private func fetchMore() async {
        generation += 1
        let token = generation
        isLoadingMore = true
        defer { if token == generation { isLoadingMore = false } }
        var empties = 0
        while let current = cursor, token == generation {
            if gateApplies(current), let until = gate() {
                pause(until: until, resume: .more)
                return
            }
            requestCount += 1
            do {
                let chunk = try await source.next(current)
                guard token == generation else { return }
                let added = append(chunk.items)
                cursor = chunk.next
                if let total = chunk.total { self.total = total }
                pausedUntil = nil
                if added > 0 || chunk.next == nil { return }
                empties += 1
                if empties >= maxConsecutiveEmptyChunks { return }
            } catch {
                guard token == generation, !isCancellation(error) else { return }
                if let until = blockedUntil(error) {
                    pause(until: until, resume: .more)
                    return
                }
                loadMoreError = error
                return
            }
        }
    }

    private func pause(until: Date, resume newResume: Resume) {
        pausedUntil = until
        resume = newResume
        guard resumeTask == nil else { return }
        let sleep = self.sleep
        let delay = max(1, until.timeIntervalSince(now()) + 1) + max(0, resumeJitter())
        resumeTask = Task { [weak self] in
            await sleep(delay)
            guard !Task.isCancelled, let self else { return }
            self.resumeTask = nil
            self.pausedUntil = nil
            let pending = self.resume
            self.resume = nil
            if pending == .first { await self.reload() }
        }
    }

    private func append(_ newItems: [Item]) -> Int {
        var seen = Set(items.map(\.id))
        let fresh = newItems.filter { seen.insert($0.id).inserted }
        guard !fresh.isEmpty else { return 0 }
        onAppend?(fresh)
        items.append(contentsOf: fresh)
        return fresh.count
    }

    private func deduplicated(_ list: [Item]) -> [Item] {
        var seen = Set<Item.ID>()
        return list.filter { seen.insert($0.id).inserted }
    }

    private func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}

extension Paginator {
    convenience init(soundCloudSource source: PagedSource<Item>) {
        self.init(
            source: source,
            gate: {
                if case .waiting(_, let until) = SoundCloudGateway.shared.trafficSafetyState() { return until }
                return nil
            },
            gateApplies: { cursor in
                if case .offset? = cursor { return false }
                return true
            },
            blockedUntil: { error in
                if case APIError.temporarilyBlocked(let until, _) = error { return until }
                return nil
            }
        )
    }
}

struct PagedFooter: View {
    let isLoading: Bool
    let failed: Bool
    let isPaused: Bool
    var resumesAt: Date? = nil
    var awaitsUser = false
    let retry: () -> Void
    let reachedEnd: () -> Void
    var appeared: () -> Void = {}
    var continueLoading: () -> Void = {}

    private var pausedMessage: String {
        let base = "SoundCloud is limiting requests. Your sign-in is saved."
        guard let resumesAt else { return "\(base) More loads automatically." }
        return "\(base) More loads automatically at \(resumesAt.formatted(date: .omitted, time: .shortened))."
    }

    var body: some View {
        VStack(spacing: 0) {
            if failed {
                VStack(spacing: 6) {
                    Text("Couldn’t load more.")
                        .foregroundStyle(.secondary)
                    Button("Try Again", action: retry)
                }
            } else if isPaused {
                Text(pausedMessage)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if awaitsUser, !isLoading {
                Button("Load More", action: continueLoading)
            } else if isLoading {
                ProgressView()
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .onAppear(perform: appeared)
        .task(id: "\(isLoading)|\(failed)|\(isPaused)") {
            guard !isLoading, !failed, !awaitsUser else { return }
            reachedEnd()
        }
    }
}

extension PagedFooter {
    @MainActor
    init<Item: Identifiable>(pager: Paginator<Item>) {
        self.init(
            isLoading: pager.isLoadingMore,
            failed: pager.didFailLoadingMore,
            isPaused: pager.isPaused,
            resumesAt: pager.pausedUntil,
            awaitsUser: pager.awaitsUser,
            retry: { Task { await pager.retry() } },
            reachedEnd: { pager.requestMore() },
            appeared: { pager.attend() },
            continueLoading: { pager.continueLoading() }
        )
    }
}
