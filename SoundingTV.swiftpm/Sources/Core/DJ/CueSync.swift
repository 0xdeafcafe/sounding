import Foundation

struct CueSyncRecord: Codable, Sendable, Equatable {
    let cueId: String
    let trackId: String
    let kind: CueKind

    let positionMillis: Int64
    let endMillis: Int64?
    let hotCueIndex: Int?
    let label: String
    let colorRGB: UInt32
    let isDeleted: Bool
    let promotedFromName: String?
    let promotedFromVersion: Int?
    let origin: CueOrigin?

    let createdAtMillis: Int64
    let updatedAtMillis: Int64
    let writerId: String

    init(_ cue: CuePoint) {
        cueId = cue.id
        trackId = cue.trackId
        kind = cue.kind
        positionMillis = cue.positionMillis
        endMillis = cue.endMillis
        hotCueIndex = cue.hotCueIndex
        label = cue.label
        colorRGB = cue.color.rgb
        isDeleted = cue.isDeleted
        promotedFromName = cue.promotedFrom?.name
        promotedFromVersion = cue.promotedFrom?.version
        origin = cue.origin == .user ? nil : cue.origin
        createdAtMillis = cue.createdAtMillis
        updatedAtMillis = cue.updatedAtMillis
        writerId = cue.writerId
    }

    var cuePoint: CuePoint {
        CuePoint(
            id: cueId,
            trackId: trackId,
            kind: kind,
            positionMillis: positionMillis,
            endMillis: endMillis,
            hotCueIndex: hotCueIndex,
            label: label,
            color: CueColor(rgb: colorRGB),
            createdAtMillis: createdAtMillis,
            updatedAtMillis: updatedAtMillis,
            isDeleted: isDeleted,
            promotedFrom: promotedFromName.flatMap { name in
                promotedFromVersion.map { CueSuggesterIdentity(name: name, version: $0) }
            },
            writerId: writerId,
            origin: origin ?? .user
        )
    }
}

enum CueSyncPolicy {
    static func remoteWins(local: CuePoint?, remote: CueSyncRecord) -> Bool {
        guard let local else { return true }
        if CueSyncRecord(local) == remote { return false }
        if remote.updatedAtMillis != local.updatedAtMillis {
            return remote.updatedAtMillis > local.updatedAtMillis
        }
        return remote.writerId > local.writerId
    }
}

struct CueSyncCursor: Codable, Sendable, Equatable {
    let bytes: Data
    init(bytes: Data) { self.bytes = bytes }
}

private struct CueSyncRelayState: Codable, Sendable, Equatable {
    var pull: CueSyncCursor?
    var pushedThroughMillis: Int64 = 0

    static func decode(_ cursor: CueSyncCursor?) -> CueSyncRelayState {
        guard let cursor, let decoded = try? JSONDecoder().decode(CueSyncRelayState.self, from: cursor.bytes) else {
            return CueSyncRelayState()
        }
        return decoded
    }

    var encoded: CueSyncCursor? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return CueSyncCursor(bytes: data)
    }
}

protocol CueSyncTransport: Sendable {
    var transportId: String { get }
    func isReady() async -> Bool
    func offer(cues: [CueSyncRecord], dismissals: [CueDismissal]) async throws
    func fetch(since cursor: CueSyncCursor?) async throws -> (cues: [CueSyncRecord], dismissals: [CueDismissal], cursor: CueSyncCursor?)
}

protocol CueSyncStore: Sendable {
    func pendingChanges(since cursorMillis: Int64, limit: Int) async -> (cues: [CueSyncRecord], dismissals: [CueDismissal])
    @discardableResult
    func adopt(_ records: [CueSyncRecord]) async -> Int
    @discardableResult
    func adoptDismissals(_ dismissals: [CueDismissal]) async -> Int
}

struct CueSyncBody: Codable, Sendable, Equatable {
    let cues: [CueSyncRecord]
    let dismissals: [CueDismissal]

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try? encoder.encode(self)
    }

    static func decode(_ data: Data) -> CueSyncBody? {
        try? JSONDecoder().decode(CueSyncBody.self, from: data)
    }
}

struct CueSyncRelay: Sendable {
    let store: any CueSyncStore
    let transport: any CueSyncTransport
    let exportLimit: Int

    init(store: any CueSyncStore, transport: any CueSyncTransport, exportLimit: Int = 5_000) {
        self.store = store
        self.transport = transport
        self.exportLimit = exportLimit
    }

    struct RoundResult: Sendable, Equatable {
        var fetchedCues = 0
        var fetchedDismissals = 0
        var adoptedCues = 0
        var adoptedDismissals = 0
        var offeredCues = 0
        var offeredDismissals = 0
        var cursor: CueSyncCursor?
        var skippedNotReady = false
    }

    func runOnce(since cursor: CueSyncCursor?) async throws -> RoundResult {
        var result = RoundResult()
        guard await transport.isReady() else {
            result.skippedNotReady = true
            return result
        }

        let state = CueSyncRelayState.decode(cursor)

        let (incomingCues, incomingDismissals, nextPull) = try await transport.fetch(since: state.pull)
        result.fetchedCues = incomingCues.count
        result.fetchedDismissals = incomingDismissals.count
        result.adoptedCues = incomingCues.isEmpty ? 0 : await store.adopt(incomingCues)
        result.adoptedDismissals = incomingDismissals.isEmpty ? 0 : await store.adoptDismissals(incomingDismissals)

        let incomingCuesById = Dictionary(uniqueKeysWithValues: incomingCues.map { ($0.cueId, $0) })
        let incomingDismissalIds = Set(incomingDismissals.map(\.id))

        let (pendingCues, pendingDismissals) = await store.pendingChanges(since: state.pushedThroughMillis, limit: exportLimit)
        let outgoingCues = pendingCues.filter { incomingCuesById[$0.cueId] != $0 }
        let outgoingDismissals = pendingDismissals.filter { !incomingDismissalIds.contains($0.id) }
        if !outgoingCues.isEmpty || !outgoingDismissals.isEmpty {
            try await transport.offer(cues: outgoingCues, dismissals: outgoingDismissals)
        }
        result.offeredCues = outgoingCues.count
        result.offeredDismissals = outgoingDismissals.count

        let newPushedThrough = [
            state.pushedThroughMillis,
            outgoingCues.map(\.updatedAtMillis).max() ?? 0,
            outgoingDismissals.map(\.dismissedAtMillis).max() ?? 0,
            incomingCues.map(\.updatedAtMillis).max() ?? 0,
            incomingDismissals.map(\.dismissedAtMillis).max() ?? 0,
        ].max() ?? state.pushedThroughMillis

        result.cursor = CueSyncRelayState(pull: nextPull, pushedThroughMillis: newPushedThrough).encoded
        return result
    }
}
