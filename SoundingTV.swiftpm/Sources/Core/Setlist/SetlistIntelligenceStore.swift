import Foundation
import AVFoundation
import Combine
import ShazamKit

struct SetlistScanProgress: Equatable {
    let completed: Int
    let total: Int
    let positionSeconds: TimeInterval?

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

@MainActor
final class SetlistIntelligenceStore: ObservableObject {
    static let shared = SetlistIntelligenceStore()

    @Published private(set) var setlists: [String: GeneratedSetlist] = [:]
    @Published private(set) var scanningTrackIds: Set<String> = []
    @Published private(set) var scanErrors: [String: String] = [:]
    @Published private(set) var scanProgress: [String: SetlistScanProgress] = [:]

    private static let defaultsKey = "red.forbes.sounding.generatedSetlists.v1"
    private let scanner = SetlistShazamScanner()
    private let persistenceWriter = SetlistPersistenceWriter()
    private var persistenceGeneration: UInt64 = 0
    private var semanticCommentTasks: [String: Task<Void, Never>] = [:]
    private var semanticCommentSignatures: [String: Int] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: GeneratedSetlist].self, from: data) {
            setlists = decoded
        }
    }

    func setlist(for trackId: String?) -> GeneratedSetlist? {
        trackId.flatMap { setlists[$0] }
    }

    func snapshotsForSync() -> [GeneratedSetlist] {
        Array(setlists.values)
    }

    var savedSetlists: [GeneratedSetlist] {
        setlists.values.filter(\.isSaved).sorted { $0.updatedAt > $1.updatedAt }
    }

    func exportText(for setlist: GeneratedSetlist) -> String {
        let rows = setlist.segments
            .filter { !$0.isDeleted }
            .sorted { $0.startSeconds < $1.startSeconds }
            .map { "\(Self.exportTime($0.startSeconds))  \($0.displayLabel)" }
        return ([setlist.trackTitle, ""] + rows).joined(separator: "\n")
    }

    func adoptSynced(_ incoming: [GeneratedSetlist]) {
        guard !incoming.isEmpty else { return }
        var changed = false
        for remote in incoming {
            guard !remote.trackId.isEmpty else { continue }
            guard var local = setlists[remote.trackId] else {
                setlists[remote.trackId] = normalized(remote)
                changed = true
                continue
            }
            let original = local
            let remoteIsNewer = remote.updatedAt > local.updatedAt
            if remoteIsNewer {
                local.trackTitle = remote.trackTitle
                local.duration = remote.duration
            }
            let localSavedRevision = local.savedUpdatedAt ?? local.updatedAt
            let remoteSavedRevision = remote.savedUpdatedAt ?? remote.updatedAt
            if remoteSavedRevision > localSavedRevision {
                local.isSaved = remote.isSaved
                local.savedUpdatedAt = remoteSavedRevision
            }
            for segment in remote.segments {
                merge(
                    segment,
                    into: &local,
                    incomingFallback: remote.updatedAt,
                    currentFallback: local.updatedAt
                )
            }
            var probes = local.probes ?? []
            for probe in remote.probes ?? [] {
                if let index = probes.firstIndex(where: {
                    abs($0.positionSeconds - probe.positionSeconds) < 5
                }) {
                    let current = probes[index]
                    let outcomeRank: (SetlistScanOutcome) -> Int = {
                        switch $0 {
                        case .matched: return 2
                        case .noMatch: return 1
                        case .failed: return 0
                        }
                    }
                    if outcomeRank(probe.outcome) > outcomeRank(current.outcome)
                        || (probe.outcome == current.outcome && probe.attemptedAt > current.attemptedAt) {
                        probes[index] = probe
                    }
                } else {
                    probes.append(probe)
                }
            }
            local.probes = probes.sorted { $0.positionSeconds < $1.positionSeconds }
            local.updatedAt = max(local.updatedAt, remote.updatedAt)
            local = normalized(local)
            if local != original {
                setlists[remote.trackId] = local
                changed = true
            }
        }
        if changed { persist(requestSync: false) }
    }

    func seed(track: Track, comments: [Comment]) {
        guard DeckIdentityResolver.isLikelyMix(track) else { return }
        var setlist = setlists[track.id] ?? GeneratedSetlist(
            trackId: track.id,
            trackTitle: track.title,
            duration: track.duration,
            segments: [],
            isSaved: false,
            updatedAt: Date()
        )
        setlist.trackTitle = track.title
        setlist.duration = track.duration

        for identity in DeckIdentityResolver.descriptionIdentities(for: track) {
            guard let start = identity.startsAt else { continue }
            let parts = Self.splitLabel(identity.label)
            merge(
                SetlistSegment(
                    id: "description#\(Int(start * 1000))",
                    startSeconds: start,
                    observedAtSeconds: start,
                    artist: parts.artist,
                    title: parts.title,
                    version: parts.version,
                    source: .uploaderTracklist,
                    confidence: identity.confidence,
                    evidence: identity.evidence,
                    shazamId: nil,
                    soundCloudTrackId: nil,
                    isUserEdited: false,
                    updatedAt: Date()
                ),
                into: &setlist
            )
        }

        for identity in DeckIdentityResolver.commentIdentities(comments: comments) {
            guard let time = identity.startsAt else { continue }
            let parts = Self.splitLabel(identity.label)
            merge(
                SetlistSegment(
                    id: "comment#\(identity.commentID ?? String(Int(time * 1000)))",
                    startSeconds: time,
                    observedAtSeconds: time,
                    artist: parts.artist,
                    title: parts.title,
                    version: parts.version,
                    source: .listenerComment,
                    confidence: identity.confidence,
                    evidence: identity.evidence,
                    shazamId: nil,
                    soundCloudTrackId: nil,
                    isUserEdited: false,
                    updatedAt: Date()
                ),
                into: &setlist
            )
        }
        setlist.updatedAt = Date()
        setlists[track.id] = normalized(setlist)
        persist()
        scheduleSemanticCommentEnrichment(track: track, comments: comments)
    }

    private func scheduleSemanticCommentEnrichment(track: Track, comments: [Comment]) {
        guard !comments.isEmpty else { return }
        let signature = comments.map { "\($0.id)#\($0.body)" }.joined(separator: "|").hashValue
        guard semanticCommentSignatures[track.id] != signature else { return }
        semanticCommentSignatures[track.id] = signature
        semanticCommentTasks[track.id]?.cancel()
        semanticCommentTasks[track.id] = Task { @MainActor [weak self] in
            let identities = await DeckIdentityResolver.semanticCommentIdentities(comments: comments)
            guard !Task.isCancelled, let self else { return }
            self.mergeSemanticCommentIdentities(identities, into: track)
            self.semanticCommentTasks[track.id] = nil
        }
    }

    private func mergeSemanticCommentIdentities(_ identities: [DeckIdentity], into track: Track) {
        guard !identities.isEmpty else { return }
        var setlist = setlists[track.id] ?? GeneratedSetlist(
            trackId: track.id,
            trackTitle: track.title,
            duration: track.duration,
            segments: [],
            isSaved: false,
            updatedAt: Date()
        )
        for identity in identities {
            guard let time = identity.startsAt else { continue }
            let parts = Self.splitLabel(identity.label)
            merge(
                SetlistSegment(
                    id: "comment#\(identity.commentID ?? String(Int(time * 1000)))",
                    startSeconds: time,
                    observedAtSeconds: time,
                    artist: parts.artist,
                    title: parts.title,
                    version: parts.version,
                    source: .listenerComment,
                    confidence: identity.confidence,
                    evidence: identity.evidence,
                    shazamId: nil,
                    soundCloudTrackId: nil,
                    isUserEdited: false,
                    updatedAt: Date()
                ),
                into: &setlist
            )
        }
        setlist.updatedAt = Date()
        setlists[track.id] = normalized(setlist)
        persist()
    }

    func analyze(track: Track, localFileURL: URL?, comments suppliedComments: [Comment]? = nil) async {
        guard DeckIdentityResolver.isLikelyMix(track) else { return }
        let comments: [Comment]
        if let suppliedComments {
            comments = suppliedComments
        } else {
            comments = await loadCommentEvidence(trackId: track.id)
        }
        seed(track: track, comments: comments)
        guard let localFileURL else { return }
        let priorityPositions = DeckIdentityResolver.identificationRequestPositions(comments: comments)
        #if os(macOS)
        await scan(
            track: track, localFileURL: localFileURL, unknownOnly: false,
            worker: .primary, priorityPositions: priorityPositions
        )
        #elseif os(tvOS)
        await scan(
            track: track, localFileURL: localFileURL, unknownOnly: false,
            worker: .secondary, priorityPositions: priorityPositions
        )
        #else
        // iPhone and iPad consume the Mac/TV result by default. This avoids a
        // long online scan on battery; an explicit retry still works below.
        SetlistSyncTarget.requestSync?()
        #endif
    }

    func retryUnknowns(track: Track, localFileURL: URL, comments: [Comment] = []) async {
        await scan(
            track: track, localFileURL: localFileURL, unknownOnly: true,
            worker: .explicit,
            priorityPositions: DeckIdentityResolver.identificationRequestPositions(comments: comments)
        )
    }

    func setSaved(_ saved: Bool, trackId: String) {
        guard var setlist = setlists[trackId] else { return }
        let now = Date()
        setlist.isSaved = saved
        setlist.savedUpdatedAt = now
        setlist.updatedAt = now
        setlists[trackId] = setlist
        persist()
    }

    func update(_ segment: SetlistSegment, trackId: String) {
        guard var setlist = setlists[trackId],
              let index = setlist.segments.firstIndex(where: { $0.id == segment.id }) else { return }
        var edited = segment
        edited.source = .user
        edited.confidence = 1
        edited.isUserEdited = true
        edited.updatedAt = Date()
        edited.deletedAt = nil
        setlist.segments[index] = edited
        setlist.updatedAt = Date()
        setlists[trackId] = normalized(setlist)
        persist()
    }

    func remove(segmentId: String, trackId: String) {
        guard var setlist = setlists[trackId],
              let index = setlist.segments.firstIndex(where: { $0.id == segmentId }) else { return }
        let now = Date()
        setlist.segments[index].deletedAt = now
        setlist.segments[index].updatedAt = now
        setlist.updatedAt = now
        setlists[trackId] = normalized(setlist)
        persist()
    }

    func link(_ soundCloudTrack: Track, to segmentId: String, trackId: String) {
        guard var setlist = setlists[trackId],
              let index = setlist.segments.firstIndex(where: { $0.id == segmentId }) else { return }
        var segment = setlist.segments[index]
        segment.artist = soundCloudTrack.user.displayName
        segment.title = soundCloudTrack.title
        segment.soundCloudTrackId = soundCloudTrack.id
        segment.source = .user
        segment.confidence = 1
        segment.evidence = "Linked to SoundCloud"
        segment.isUserEdited = true
        segment.updatedAt = Date()
        segment.deletedAt = nil
        setlist.segments[index] = segment
        setlist.updatedAt = Date()
        setlists[trackId] = normalized(setlist)
        persist()
    }

    private enum ScanWorker {
        case primary
        case secondary
        case explicit
    }

    private func scan(
        track: Track,
        localFileURL: URL,
        unknownOnly: Bool,
        worker: ScanWorker,
        priorityPositions: [TimeInterval]
    ) async {
        guard !scanningTrackIds.contains(track.id) else { return }
        scanningTrackIds.insert(track.id)
        scanErrors[track.id] = nil
        defer {
            scanningTrackIds.remove(track.id)
            scanProgress[track.id] = nil
        }

        let existingSetlist = setlists[track.id]
        let existing = (existingSetlist?.segments ?? []).filter { !$0.isDeleted }
        let positions = Self.scanPositions(
            duration: track.duration,
            existing: existing,
            probes: existingSetlist?.probes ?? [],
            unknownOnly: unknownOnly,
            worker: worker,
            priorityPositions: priorityPositions
        )
        guard !positions.isEmpty else { return }
        scanProgress[track.id] = SetlistScanProgress(
            completed: 0,
            total: positions.count,
            positionSeconds: positions.first
        )

        do {
            var consecutiveServiceFailures = 0
            var probesSinceSync = 0
            for (index, position) in positions.enumerated() {
                try Task.checkCancellation()
                do {
                    let match = try await scanner.match(
                        fileURL: localFileURL,
                        at: position,
                        retryNoMatch: unknownOnly
                    )
                    consecutiveServiceFailures = 0
                    var setlist = setlists[track.id] ?? GeneratedSetlist(
                        trackId: track.id, trackTitle: track.title, duration: track.duration,
                        segments: [], isSaved: false, updatedAt: Date()
                    )
                    recordProbe(
                        at: position,
                        outcome: match == nil ? .noMatch : .matched,
                        shazamId: match?.shazamId,
                        in: &setlist
                    )
                    if let match {
                        let start = max(0, match.queryStartSeconds - match.matchOffset)
                        merge(
                            SetlistSegment(
                                id: "shazam#\(match.shazamId ?? UUID().uuidString)#\(Int(start.rounded()))",
                                startSeconds: start,
                                observedAtSeconds: match.queryStartSeconds,
                                artist: match.artist,
                                title: match.title,
                                version: nil,
                                source: .shazam,
                                confidence: match.confidence,
                                evidence: "Matched around \(Self.time(match.queryStartSeconds))",
                                shazamId: match.shazamId,
                                soundCloudTrackId: nil,
                                isUserEdited: false,
                                updatedAt: Date()
                            ),
                            into: &setlist
                        )
                    }
                    setlist.updatedAt = Date()
                    setlists[track.id] = normalized(setlist)
                    probesSinceSync += 1
                    persist(requestSync: probesSinceSync % 8 == 0)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    consecutiveServiceFailures += 1
                    var setlist = setlists[track.id] ?? GeneratedSetlist(
                        trackId: track.id, trackTitle: track.title, duration: track.duration,
                        segments: [], isSaved: false, updatedAt: Date()
                    )
                    recordProbe(at: position, outcome: .failed, shazamId: nil, in: &setlist)
                    setlist.updatedAt = Date()
                    setlists[track.id] = setlist
                    probesSinceSync += 1
                    persist(requestSync: probesSinceSync % 8 == 0)
                    // A single flaky request must not lose a five-hour scan.
                    // Three consecutive exhausted retries indicates the service
                    // or network is unavailable, so preserve progress and pause.
                    if consecutiveServiceFailures >= 3 { throw error }
                }
                scanProgress[track.id] = SetlistScanProgress(
                    completed: index + 1,
                    total: positions.count,
                    positionSeconds: index + 1 < positions.count ? positions[index + 1] : nil
                )
            }
        } catch is CancellationError {
        } catch {
            scanErrors[track.id] = error.localizedDescription
        }
        SetlistSyncTarget.requestSync?()
    }

    private func loadCommentEvidence(trackId: String) async -> [Comment] {
        do {
            var page = try await SoundCloudAPI.shared.getComments(trackId: trackId, limit: 200)
            var comments = page.collection
            var pagesLoaded = 1
            while comments.count < 1_000, pagesLoaded < 5, page.nextHref != nil {
                page = try await SoundCloudAPI.shared.getNextPage(page)
                comments.append(contentsOf: page.collection)
                pagesLoaded += 1
            }
            return Array(comments.prefix(1_000))
        } catch {
            return []
        }
    }

    private func merge(
        _ incoming: SetlistSegment,
        into setlist: inout GeneratedSetlist,
        incomingFallback: Date = .distantPast,
        currentFallback: Date = .distantPast
    ) {
        if let index = setlist.segments.firstIndex(where: { $0.id == incoming.id }) {
            let current = setlist.segments[index]
            let incomingRevision = revision(of: incoming, fallback: incomingFallback)
            let currentRevision = revision(of: current, fallback: currentFallback)
            guard incomingRevision > currentRevision
                    || (incomingRevision == currentRevision && incoming.deletedAt != nil && current.deletedAt == nil)
            else { return }
            if current.isUserEdited, !incoming.isUserEdited, incoming.deletedAt == nil { return }
            setlist.segments[index] = incoming
            return
        }

        if let shazamId = incoming.shazamId,
           let index = setlist.segments.firstIndex(where: {
               $0.shazamId == shazamId && abs($0.startSeconds - incoming.startSeconds) < 35
           }) {
            let current = setlist.segments[index]
            let incomingRevision = revision(of: incoming, fallback: incomingFallback)
            let currentRevision = revision(of: current, fallback: currentFallback)
            if current.isDeleted {
                if incomingRevision > currentRevision { setlist.segments[index] = incoming }
                return
            }
            if !current.isUserEdited,
               incomingRevision >= currentRevision,
               incoming.confidence >= current.confidence {
                var merged = incoming
                merged.id = current.id
                merged.startSeconds = min(current.startSeconds, incoming.startSeconds)
                setlist.segments[index] = merged
            }
            return
        }
        setlist.segments.append(incoming)
    }

    private func revision(of segment: SetlistSegment, fallback: Date) -> Date {
        segment.deletedAt ?? segment.updatedAt ?? fallback
    }

    private func recordProbe(
        at position: TimeInterval,
        outcome: SetlistScanOutcome,
        shazamId: String?,
        in setlist: inout GeneratedSetlist
    ) {
        var probes = setlist.probes ?? []
        let probe = SetlistScanProbe(
            positionSeconds: position,
            outcome: outcome,
            shazamId: shazamId,
            attemptedAt: Date()
        )
        if let index = probes.firstIndex(where: { abs($0.positionSeconds - position) < 5 }) {
            probes[index] = probe
        } else {
            probes.append(probe)
        }
        setlist.probes = probes.sorted { $0.positionSeconds < $1.positionSeconds }
    }

    private func normalized(_ setlist: GeneratedSetlist) -> GeneratedSetlist {
        var copy = setlist
        var byId: [String: SetlistSegment] = [:]
        for segment in copy.segments {
            guard let current = byId[segment.id] else {
                byId[segment.id] = segment
                continue
            }
            let incomingRevision = revision(of: segment, fallback: copy.updatedAt)
            let currentRevision = revision(of: current, fallback: copy.updatedAt)
            if incomingRevision > currentRevision
                || (incomingRevision == currentRevision && segment.isDeleted && !current.isDeleted) {
                byId[segment.id] = segment
            }
        }
        let tombstones = byId.values.filter(\.isDeleted)
        var active = byId.values.filter { !$0.isDeleted }
        active.sort {
            if abs($0.startSeconds - $1.startSeconds) < 1 { return $0.confidence > $1.confidence }
            return $0.startSeconds < $1.startSeconds
        }
        var result: [SetlistSegment] = []
        for segment in active {
            if let last = result.last, abs(last.startSeconds - segment.startSeconds) < 8 {
                if segment.confidence > last.confidence, !last.isUserEdited { result[result.count - 1] = segment }
            } else {
                result.append(segment)
            }
        }
        copy.segments = (result + tombstones).sorted { $0.startSeconds < $1.startSeconds }
        return copy
    }

    private static func scanPositions(
        duration: TimeInterval,
        existing: [SetlistSegment],
        probes: [SetlistScanProbe],
        unknownOnly: Bool,
        worker: ScanWorker,
        priorityPositions: [TimeInterval]
    ) -> [TimeInterval] {
        guard duration >= 30 else { return [] }
        let spacing: TimeInterval
        switch duration {
        case ..<7_200: spacing = 60       // up to 2 hours
        case ..<10_800: spacing = 75      // 2–3 hours
        default: spacing = 90             // 3–5+ hours
        }
        let end = max(8, duration - 12)
        let workerSpacing = worker == .secondary ? spacing * 2 : spacing
        let base = Swift.stride(from: min(8, duration / 3), through: end, by: workerSpacing).map { $0 }
        let wasProbed: (TimeInterval) -> Bool = { position in
            probes.contains { abs($0.positionSeconds - position) < 5 }
        }
        let requested = priorityPositions
            .map { min(end, max(0, $0 - 2)) }
            .filter { !wasProbed($0) }

        if !unknownOnly {
            // Interleave quarters of the set so a useful rough tracklist appears
            // early, then fill it to full cadence. Every completed probe is
            // durable, so re-entering analysis resumes instead of restarting.
            let remaining = base.enumerated().filter { !wasProbed($0.element) }
            let progressive = [0, 2, 1, 3].flatMap { phase in
                remaining.compactMap { index, position in index % 4 == phase ? position : nil }
            }
            var ordered: [TimeInterval] = []
            for position in requested + progressive {
                if !ordered.contains(where: { abs($0 - position) < 10 }) { ordered.append(position) }
            }
            return Array(ordered.prefix(worker == .secondary ? 120 : 240))
        }

        var candidates: [TimeInterval] = requested + probes
            .filter { $0.outcome != .matched }
            .sorted { $0.attemptedAt < $1.attemptedAt }
            .map(\.positionSeconds)

        // Fill any wide hole between recognized observations. This catches
        // short tracks that fell between coarse probes without rescanning the
        // already-understood parts of a long set.
        let anchors = ([0.0] + existing.map(\.observedAtSeconds) + [end]).sorted()
        for pair in zip(anchors, anchors.dropFirst()) where pair.1 - pair.0 > workerSpacing * 1.65 {
            candidates.append(contentsOf: Swift.stride(
                from: pair.0 + workerSpacing,
                to: pair.1,
                by: workerSpacing
            ))
        }
        candidates.append(contentsOf: base.filter { !wasProbed($0) })

        var seen: [TimeInterval] = []
        for position in candidates where position >= 0 && position <= end {
            if !seen.contains(where: { abs($0 - position) < 10 }) { seen.append(position) }
        }
        return Array(seen.prefix(120))
    }

    private static func splitLabel(_ label: String) -> (artist: String?, title: String, version: String?) {
        let cleaned = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = cleaned.components(separatedBy: " – ")
        let hyphenPieces = pieces.count > 1 ? pieces : cleaned.components(separatedBy: " - ")
        let artist = hyphenPieces.count > 1 ? hyphenPieces[0].trimmingCharacters(in: .whitespaces) : nil
        var title = hyphenPieces.count > 1
            ? hyphenPieces.dropFirst().joined(separator: " – ").trimmingCharacters(in: .whitespaces)
            : cleaned
        var version: String?
        if let range = title.range(of: #"\s*[\[(]([^\])]+(?:remix|edit|bootleg|vip|dub|rework))[])]\s*$"#, options: [.regularExpression, .caseInsensitive]) {
            version = String(title[range]).trimmingCharacters(in: CharacterSet(charactersIn: " []()"))
            title.removeSubrange(range)
            title = title.trimmingCharacters(in: .whitespaces)
        }
        return (artist, title, version)
    }

    private static func time(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    private static func exportTime(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded()))
        let hours = value / 3600
        let minutes = (value % 3600) / 60
        let seconds = value % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    private func persist(requestSync: Bool = true) {
        persistenceGeneration &+= 1
        let generation = persistenceGeneration
        let snapshot = setlists
        Task {
            await persistenceWriter.write(
                snapshot,
                generation: generation,
                defaultsKey: Self.defaultsKey
            )
        }
        if requestSync { SetlistSyncTarget.requestSync?() }
    }
}

private actor SetlistPersistenceWriter {
    private var writtenGeneration: UInt64 = 0

    func write(
        _ setlists: [String: GeneratedSetlist],
        generation: UInt64,
        defaultsKey: String
    ) {
        guard generation > writtenGeneration,
              let data = try? JSONEncoder().encode(setlists) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
        writtenGeneration = generation
    }
}

/// Serialises automatic long-set work across downloads and deck loads. A
/// single Mac remains the dense worker, Apple TV remains the sparse fallback,
/// and explicit user retries can still run immediately.
@MainActor
final class SetlistBackgroundWorkCoordinator {
    static let shared = SetlistBackgroundWorkCoordinator()

    private struct Job {
        let track: Track
        let localFileURL: URL
        let comments: [Comment]?
    }

    private var jobs: [Job] = []
    private var queuedTrackIds: Set<String> = []
    private var runner: Task<Void, Never>?

    private init() {}

    func enqueue(track: Track, localFileURL: URL, comments: [Comment]? = nil) {
        guard DeckIdentityResolver.isLikelyMix(track),
              queuedTrackIds.insert(track.id).inserted else { return }
        jobs.append(Job(track: track, localFileURL: localFileURL, comments: comments))
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard runner == nil else { return }
        runner = Task { @MainActor [weak self] in
            guard let self else { return }
            while !self.jobs.isEmpty, !Task.isCancelled {
                let job = self.jobs.removeFirst()
                await SetlistIntelligenceStore.shared.analyze(
                    track: job.track,
                    localFileURL: job.localFileURL,
                    comments: job.comments
                )
                self.queuedTrackIds.remove(job.track.id)
                try? await Task.sleep(for: .seconds(1))
            }
            self.runner = nil
        }
    }
}

private actor SetlistShazamScanner {
    struct Match: Sendable {
        let title: String
        let artist: String?
        let shazamId: String?
        let queryStartSeconds: TimeInterval
        let matchOffset: TimeInterval
        let confidence: Double
    }

    private struct Query {
        let signature: SHSignature
        let startSeconds: TimeInterval
    }

    func match(fileURL: URL, at position: TimeInterval, retryNoMatch: Bool) async throws -> Match? {
        // ShazamIO centers a bounded fingerprint inside long audio. For unknown
        // sections, try neighboring windows too; ShazamKit remains the native
        // recognizer and transport on iOS, macOS, and tvOS.
        let requestedStarts = retryNoMatch
            ? [position, max(0, position - 6), position + 6]
            : [position]
        var attemptedStarts: Set<Int64> = []
        let session = SHSession()

        for requestedStart in requestedStarts {
            let key = Int64((requestedStart * 1000).rounded())
            guard attemptedStarts.insert(key).inserted,
                  let query = try makeQuery(fileURL: fileURL, at: requestedStart) else { continue }

            // Retry transient service failures with the same non-invertible
            // signature. A genuine no-match advances to the shifted window.
            for attempt in 0..<3 {
                try Task.checkCancellation()
                switch await session.result(from: query.signature) {
                case .match(let shazamMatch):
                    guard let item = shazamMatch.mediaItems.first,
                          let title = item.title, !title.isEmpty else { break }
                    let confidence: Double
                    if #available(macOS 15.4, iOS 18.4, tvOS 18.4, *) {
                        confidence = Double(item.confidence)
                    } else {
                        confidence = 0.82
                    }
                    return Match(
                        title: title,
                        artist: item.artist,
                        shazamId: item.shazamID,
                        queryStartSeconds: query.startSeconds,
                        matchOffset: item.matchOffset,
                        confidence: confidence
                    )
                case .noMatch:
                    break
                case .error(let error, _):
                    guard attempt < 2 else { throw error }
                    try await Task.sleep(for: .milliseconds(attempt == 0 ? 350 : 900))
                    continue
                }
                break
            }
        }
        return nil
    }

    private func makeQuery(fileURL: URL, at position: TimeInterval) throws -> Query? {
        let file = try AVAudioFile(forReading: fileURL)
        let inputFormat = file.processingFormat
        let sampleRate = inputFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        let startFrame = AVAudioFramePosition(max(0, position) * sampleRate)
        guard startFrame < file.length else { return nil }
        file.framePosition = startFrame
        let requested = min(file.length - startFrame, AVAudioFramePosition(sampleRate * 12))
        guard requested > 0,
              let inputBuffer = AVAudioPCMBuffer(
                  pcmFormat: inputFormat,
                  frameCapacity: AVAudioFrameCount(min(requested, AVAudioFramePosition(UInt32.max)))
              ) else { return nil }
        try file.read(into: inputBuffer, frameCount: inputBuffer.frameCapacity)
        guard inputBuffer.frameLength > 0,
              let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return nil }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio)) + 32
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputCapacity
        ) else { return nil }

        var suppliedInput = false
        var conversionError: NSError?
        let conversionStatus = converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if suppliedInput {
                status.pointee = .endOfStream
                return nil
            }
            suppliedInput = true
            status.pointee = .haveData
            return inputBuffer
        }
        if let conversionError { throw conversionError }
        guard conversionStatus != .error, outputBuffer.frameLength > 0 else { return nil }

        let generator = SHSignatureGenerator()
        try generator.append(
            outputBuffer,
            at: AVAudioTime(sampleTime: 0, atRate: outputFormat.sampleRate)
        )
        return Query(
            signature: generator.signature(),
            startSeconds: Double(startFrame) / sampleRate
        )
    }
}
