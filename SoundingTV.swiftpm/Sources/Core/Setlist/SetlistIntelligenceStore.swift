import Foundation
import AVFoundation
import Combine
import ShazamKit

@MainActor
protocol SetlistSynchronizationReceiving: AnyObject, Sendable {
    func noteSetlistMutation()
}

struct SetlistScanProgress: Equatable {
    let completed: Int
    let total: Int
    let positionSeconds: TimeInterval?

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

enum SetlistIdentification: Equatable, Sendable {
    case matched(SetlistSegment)
    case noMatch
    case unavailable(String)
    case failed(String)
}

struct SetlistAudioWindow: Sendable {
    let fileURL: URL
    let startSeconds: TimeInterval
    let isTemporary: Bool
}

protocol SetlistAudioSource: Sendable {
    func window(startingAt seconds: TimeInterval, duration: TimeInterval) async throws -> SetlistAudioWindow
}

struct SetlistLocalAudioSource: SetlistAudioSource {
    let fileURL: URL

    func window(startingAt seconds: TimeInterval, duration: TimeInterval) async throws -> SetlistAudioWindow {
        SetlistAudioWindow(fileURL: fileURL, startSeconds: 0, isTemporary: false)
    }
}

@MainActor
final class SetlistIntelligenceStore: ObservableObject {
    static let shared = SetlistIntelligenceStore()

    @Published private(set) var setlists: [String: GeneratedSetlist] = [:]
    @Published private(set) var isLoaded = false
    @Published private(set) var scanningTrackIds: Set<String> = []
    @Published private(set) var identifyingTrackIds: Set<String> = []
    @Published private(set) var scanErrors: [String: String] = [:]
    @Published private(set) var scanProgress: [String: SetlistScanProgress] = [:]
    @Published private(set) var identifiedSongs: [String: IdentifiedSong] = [:]

    static let identifyLookbehindSeconds: TimeInterval = 8
    private static let persistDelay: Duration = .seconds(1)

    private let archive = SetlistArchive()
    private let scanner = SetlistShazamScanner()
    private var loadTask: Task<Void, Never>?
    private var dirtyTrackIds: Set<String> = []
    private var persistTask: Task<Void, Never>?
    private var semanticCommentTasks: [String: Task<Void, Never>] = [:]
    private var semanticCommentSignatures: [String: Int] = [:]
    private var hydratingMetadataTrackIds: Set<String> = []
    private var hydratedMetadataTrackIds: Set<String> = []
    private weak var synchronizationSink: (any SetlistSynchronizationReceiving)?

    private init() {
        let archive = archive
        loadTask = Task { [weak self] in
            let loaded = await archive.loadAll()
            self?.absorbLoaded(loaded)
        }
    }

    func waitUntilLoaded() async {
        await loadTask?.value
    }

    func setlist(for trackId: String?) -> GeneratedSetlist? {
        trackId.flatMap { setlists[$0] }
    }

    func tracklist(for trackId: String?) -> Tracklist? {
        setlist(for: trackId).map(\.tracklist)
    }

    func isMix(trackID: String?, title: String?, description: String? = nil, duration: TimeInterval) -> Bool {
        if !(tracklist(for: trackID)?.isEmpty ?? true) { return true }
        return DeckIdentityResolver.isLikelyMix(title: title ?? "", description: description, duration: duration)
    }

    func isMix(_ track: Track) -> Bool {
        isMix(trackID: track.id, title: track.title, description: track.description, duration: track.duration)
    }

    func snapshotsForSync() -> [GeneratedSetlist] {
        Array(setlists.values)
    }

    func connectSynchronization(to sink: any SetlistSynchronizationReceiving) {
        synchronizationSink = sink
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
        let incoming = incoming.filter { !$0.trackId.isEmpty }
        guard !incoming.isEmpty else { return }
        let base = setlists
        Task { [weak self] in
            let merged = await Task.detached(priority: .utility) {
                SetlistMerging.adopt(incoming, into: base)
            }.value
            self?.apply(merged, base: base, requestSync: false)
        }
    }

    func seed(track: Track, comments: [Comment]) {
        guard DeckIdentityResolver.isLikelyMix(track) else { return }
        Task { await seedNow(track: track, comments: comments) }
    }

    private func seedNow(track: Track, comments: [Comment]) async {
        let base = setlists[track.id]
        let seeded = await Task.detached(priority: .utility) {
            SetlistMerging.seeded(base, track: track, comments: comments)
        }.value
        apply([track.id: seeded], base: base.map { [track.id: $0] } ?? [:], requestSync: true)
        scheduleSemanticCommentEnrichment(track: track, comments: comments)
    }

    func hydrateMetadataIfNeeded(for track: Track) async {
        guard !hydratedMetadataTrackIds.contains(track.id),
              hydratingMetadataTrackIds.insert(track.id).inserted else { return }
        defer { hydratingMetadataTrackIds.remove(track.id) }
        let comments = await loadCommentEvidence(trackId: track.id)
        guard !Task.isCancelled else { return }
        hydratedMetadataTrackIds.insert(track.id)
        guard DeckIdentityResolver.isLikelyMix(track) else { return }
        await seedNow(track: track, comments: comments)
    }

    private func scheduleSemanticCommentEnrichment(track: Track, comments: [Comment]) {
        guard !comments.isEmpty else { return }
        let signature = comments.map { "\($0.id)#\($0.body)" }.joined(separator: "|").hashValue
        guard semanticCommentSignatures[track.id] != signature else { return }
        semanticCommentSignatures[track.id] = signature
        semanticCommentTasks[track.id]?.cancel()
        semanticCommentTasks[track.id] = Task { @MainActor [weak self] in
            let identities = await DeckIdentityResolver.semanticCommentIdentities(comments: comments)
            guard !Task.isCancelled, let self, !identities.isEmpty else { return }
            let base = self.setlists[track.id]
            let merged = await Task.detached(priority: .utility) {
                SetlistMerging.merging(identities, source: .listenerComment, into: base, track: track)
            }.value
            self.apply([track.id: merged], base: base.map { [track.id: $0] } ?? [:], requestSync: true)
            self.semanticCommentTasks[track.id] = nil
        }
    }

    func analyze(track: Track, localFileURL: URL?, comments suppliedComments: [Comment]? = nil) async {
        guard DeckIdentityResolver.isLikelyMix(track) else { return }
        let comments: [Comment]
        if let suppliedComments {
            comments = suppliedComments
        } else {
            comments = await loadCommentEvidence(trackId: track.id)
        }
        await seedNow(track: track, comments: comments)
        guard let localFileURL else { return }
        let priorityPositions = DeckIdentityResolver.candidateIdentityPositions(track: track, comments: comments)
        #if os(macOS)
        await scan(
            track: track, source: SetlistLocalAudioSource(fileURL: localFileURL), unknownOnly: false,
            worker: .primary, priorityPositions: priorityPositions
        )
        #elseif os(tvOS)
        await scan(
            track: track, source: SetlistLocalAudioSource(fileURL: localFileURL), unknownOnly: false,
            worker: .secondary, priorityPositions: priorityPositions
        )
        #else
        synchronizationSink?.noteSetlistMutation()
        #endif
    }

    func hasPendingBackgroundScan(for track: Track) async -> Bool {
        guard DeckIdentityResolver.isLikelyMix(track) else { return false }
        await waitUntilLoaded()
        let existing = setlists[track.id]
        #if os(tvOS)
        let worker = ScanWorker.secondary
        #else
        let worker = ScanWorker.primary
        #endif
        return !Self.scanPositions(
            duration: track.duration,
            existing: (existing?.segments ?? []).filter { !$0.isDeleted },
            probes: existing?.probes ?? [],
            unknownOnly: false,
            worker: worker,
            priorityPositions: []
        ).isEmpty
    }

    func retryUnknowns(track: Track, localFileURL: URL, comments: [Comment] = []) async {
        await retryUnknowns(track: track, source: SetlistLocalAudioSource(fileURL: localFileURL), comments: comments)
    }

    func retryUnknowns(track: Track, source: any SetlistAudioSource, comments: [Comment] = []) async {
        await scan(
            track: track, source: source, unknownOnly: true,
            worker: .explicit,
            priorityPositions: DeckIdentityResolver.candidateIdentityPositions(track: track, comments: comments)
        )
    }

    func requestTracklist(track: Track, source: any SetlistAudioSource, comments suppliedComments: [Comment]? = nil) async {
        let comments: [Comment]
        if let suppliedComments {
            comments = suppliedComments
        } else {
            comments = await loadCommentEvidence(trackId: track.id)
        }
        await seedNow(track: track, comments: comments)
        await scan(
            track: track, source: source, unknownOnly: false,
            worker: .explicit,
            priorityPositions: DeckIdentityResolver.candidateIdentityPositions(track: track, comments: comments)
        )
    }

    func identify(track: Track, at position: TimeInterval, source: any SetlistAudioSource) async -> SetlistIdentification {
        guard identifyingTrackIds.insert(track.id).inserted else { return .unavailable("Already identifying") }
        defer { identifyingTrackIds.remove(track.id) }
        let probeStart = max(0, position - Self.identifyLookbehindSeconds)
        do {
            let match = try await scanner.match(source: source, at: probeStart, retryNoMatch: true)
            var setlist = setlists[track.id] ?? Self.emptySetlist(for: track)
            SetlistMerging.recordProbe(
                at: probeStart,
                outcome: match == nil ? .noMatch : .matched,
                shazamId: match?.shazamId,
                in: &setlist
            )
            var candidate: SetlistSegment?
            if let match {
                let segment = Self.segment(for: match)
                SetlistMerging.merge(segment, into: &setlist)
                candidate = segment
            }
            setlist.updatedAt = Date()
            let normalized = SetlistMerging.normalized(setlist)
            commit(normalized)
            guard let match, let candidate else { return .noMatch }
            let song = IdentifiedSong(match: match, mix: track, at: position)
            identifiedSongs[track.id] = song
            IdentifiedSongHistory.shared.record(song)
            let resolved = normalized.activeSegments.first {
                $0.shazamId == match.shazamId && abs($0.observedAtSeconds - match.queryStartSeconds) < 150
            } ?? normalized.segment(at: position) ?? candidate
            return .matched(resolved)
        } catch is CancellationError {
            return .failed("Cancelled")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    func recordExternalSetlist(_ setlist: GeneratedSetlist) {
        commit(SetlistMerging.normalized(setlist))
    }

    func setSaved(_ saved: Bool, trackId: String) {
        guard var setlist = setlists[trackId] else { return }
        let now = Date()
        setlist.isSaved = saved
        setlist.savedUpdatedAt = now
        setlist.updatedAt = now
        commit(setlist)
    }

    func update(_ segment: SetlistSegment, trackId: String) {
        guard var setlist = setlists[trackId] else { return }
        var edited = segment
        edited.source = .user
        edited.confidence = 1
        edited.isUserEdited = true
        edited.updatedAt = Date()
        edited.deletedAt = nil
        if let index = setlist.segments.firstIndex(where: { $0.id == segment.id }) {
            setlist.segments[index] = edited
        } else {
            setlist.segments.append(edited)
        }
        setlist.updatedAt = Date()
        commit(SetlistMerging.normalized(setlist))
    }

    func remove(segmentId: String, trackId: String) {
        guard var setlist = setlists[trackId],
              let index = setlist.segments.firstIndex(where: { $0.id == segmentId }) else { return }
        let now = Date()
        setlist.segments[index].deletedAt = now
        setlist.segments[index].updatedAt = now
        setlist.updatedAt = now
        commit(SetlistMerging.normalized(setlist))
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
        commit(SetlistMerging.normalized(setlist))
    }

    enum ScanWorker {
        case primary
        case secondary
        case explicit
    }

    func scan(
        track: Track,
        source: any SetlistAudioSource,
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
                        source: source,
                        at: position,
                        retryNoMatch: unknownOnly
                    )
                    consecutiveServiceFailures = 0
                    var setlist = setlists[track.id] ?? Self.emptySetlist(for: track)
                    SetlistMerging.recordProbe(
                        at: position,
                        outcome: match == nil ? .noMatch : .matched,
                        shazamId: match?.shazamId,
                        in: &setlist
                    )
                    if let match {
                        SetlistMerging.merge(Self.segment(for: match), into: &setlist)
                    }
                    setlist.updatedAt = Date()
                    probesSinceSync += 1
                    commit(SetlistMerging.normalized(setlist), requestSync: probesSinceSync % 8 == 0)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    consecutiveServiceFailures += 1
                    var setlist = setlists[track.id] ?? Self.emptySetlist(for: track)
                    SetlistMerging.recordProbe(at: position, outcome: .failed, shazamId: nil, in: &setlist)
                    setlist.updatedAt = Date()
                    probesSinceSync += 1
                    commit(setlist, requestSync: probesSinceSync % 8 == 0)
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
        synchronizationSink?.noteSetlistMutation()
    }

    func reportScanError(_ message: String?, for trackId: String) {
        scanErrors[trackId] = message
    }

    private static func emptySetlist(for track: Track) -> GeneratedSetlist {
        GeneratedSetlist(
            trackId: track.id, trackTitle: track.title, duration: track.duration,
            segments: [], isSaved: false, updatedAt: Date()
        )
    }

    private static func segment(for match: SetlistShazamScanner.Match) -> SetlistSegment {
        let start = max(0, match.queryStartSeconds - match.matchOffset)
        return SetlistSegment(
            id: "shazam#\(match.shazamId ?? UUID().uuidString)#\(Int(start.rounded()))",
            startSeconds: start,
            observedAtSeconds: match.queryStartSeconds,
            artist: match.artist,
            title: match.title,
            version: nil,
            source: .shazam,
            confidence: match.confidence,
            evidence: "Matched around \(time(match.queryStartSeconds))",
            shazamId: match.shazamId,
            soundCloudTrackId: nil,
            isUserEdited: false,
            updatedAt: Date()
        )
    }

    private func loadCommentEvidence(trackId: String) async -> [Comment] {
        await SoundCloudRequestEnvironment.autonomous(lane: .metadata) {
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
    }

    // MARK: - Persistence

    private func absorbLoaded(_ loaded: [String: GeneratedSetlist]) {
        var next = setlists
        for (trackId, stored) in loaded {
            if let current = next[trackId] {
                let merged = SetlistMerging.merge(remote: stored, into: current)
                next[trackId] = merged
                if merged != stored { dirtyTrackIds.insert(trackId) }
            } else {
                next[trackId] = stored
            }
        }
        setlists = next
        isLoaded = true
        if !dirtyTrackIds.isEmpty { schedulePersist() }
    }

    private func apply(
        _ merged: [String: GeneratedSetlist],
        base: [String: GeneratedSetlist],
        requestSync: Bool
    ) {
        var next = setlists
        var changed = false
        for (trackId, value) in merged {
            let current = next[trackId]
            let resolved: GeneratedSetlist
            if current == base[trackId] {
                resolved = value
            } else if let current {
                resolved = SetlistMerging.merge(remote: value, into: current)
            } else {
                resolved = value
            }
            guard resolved != current else { continue }
            next[trackId] = resolved
            dirtyTrackIds.insert(trackId)
            changed = true
        }
        guard changed else { return }
        setlists = next
        schedulePersist()
        if requestSync { synchronizationSink?.noteSetlistMutation() }
    }

    private func commit(_ setlist: GeneratedSetlist, requestSync: Bool = true) {
        setlists[setlist.trackId] = setlist
        dirtyTrackIds.insert(setlist.trackId)
        schedulePersist()
        if requestSync { synchronizationSink?.noteSetlistMutation() }
    }

    private func schedulePersist() {
        guard persistTask == nil else { return }
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: Self.persistDelay)
            await self?.flush()
        }
    }

    private func flush() async {
        await loadTask?.value
        persistTask = nil
        let snapshot = dirtyTrackIds.compactMap { setlists[$0] }
        dirtyTrackIds.removeAll()
        guard !snapshot.isEmpty else { return }
        await archive.write(snapshot)
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
        case ..<7_200: spacing = 60
        case ..<10_800: spacing = 75
        default: spacing = 90
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

}

enum SetlistMerging {
    static func adopt(
        _ incoming: [GeneratedSetlist],
        into base: [String: GeneratedSetlist]
    ) -> [String: GeneratedSetlist] {
        var changed: [String: GeneratedSetlist] = [:]
        for remote in incoming where !remote.trackId.isEmpty {
            let current = changed[remote.trackId] ?? base[remote.trackId]
            let merged = current.map { merge(remote: remote, into: $0) } ?? normalized(remote)
            if merged != base[remote.trackId] { changed[remote.trackId] = merged }
        }
        return changed
    }

    static func merge(remote: GeneratedSetlist, into current: GeneratedSetlist) -> GeneratedSetlist {
        var local = current
        if remote.updatedAt > local.updatedAt {
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
            if let index = probes.firstIndex(where: { abs($0.positionSeconds - probe.positionSeconds) < 5 }) {
                let existing = probes[index]
                if outcomeRank(probe.outcome) > outcomeRank(existing.outcome)
                    || (probe.outcome == existing.outcome && probe.attemptedAt > existing.attemptedAt) {
                    probes[index] = probe
                }
            } else {
                probes.append(probe)
            }
        }
        if local.probes != nil || !probes.isEmpty {
            local.probes = probes.sorted { $0.positionSeconds < $1.positionSeconds }
        }
        local.updatedAt = max(local.updatedAt, remote.updatedAt)
        let result = normalized(local)
        return result == normalized(current) ? current : result
    }

    static func seeded(_ base: GeneratedSetlist?, track: Track, comments: [Comment]) -> GeneratedSetlist {
        var setlist = base ?? GeneratedSetlist(
            trackId: track.id,
            trackTitle: track.title,
            duration: track.duration,
            segments: [],
            isSaved: false,
            updatedAt: Date()
        )
        setlist.trackTitle = track.title
        setlist.duration = track.duration
        let description = DeckIdentityResolver.descriptionIdentities(for: track)
        let listener = DeckIdentityResolver.commentIdentities(comments: comments)
        setlist = merging(description, source: .uploaderTracklist, into: setlist, track: track, stamp: false)
        setlist = merging(listener, source: .listenerComment, into: setlist, track: track, stamp: false)
        if let base, normalized(base) == setlist { return base }
        setlist.updatedAt = Date()
        return setlist
    }

    static func merging(
        _ identities: [DeckIdentity],
        source: SetlistSegmentSource,
        into base: GeneratedSetlist?,
        track: Track,
        stamp: Bool = true
    ) -> GeneratedSetlist {
        var setlist = base ?? GeneratedSetlist(
            trackId: track.id,
            trackTitle: track.title,
            duration: track.duration,
            segments: [],
            isSaved: false,
            updatedAt: Date()
        )
        for identity in identities {
            guard let start = identity.startsAt else { continue }
            let parts = splitLabel(identity.label)
            let id = source == .listenerComment
                ? "comment#\(identity.commentID ?? String(Int(start * 1000)))"
                : "description#\(Int(start * 1000))"
            if let existing = setlist.segments.first(where: { $0.id == id }),
               existing.startSeconds == start,
               existing.artist == parts.artist,
               existing.title == parts.title,
               existing.version == parts.version {
                continue
            }
            merge(
                SetlistSegment(
                    id: id,
                    startSeconds: start,
                    observedAtSeconds: start,
                    artist: parts.artist,
                    title: parts.title,
                    version: parts.version,
                    source: source,
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
        if stamp { setlist.updatedAt = Date() }
        return normalized(setlist)
    }

    static func recordProbe(
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

    private static func outcomeRank(_ outcome: SetlistScanOutcome) -> Int {
        switch outcome {
        case .matched: return 2
        case .noMatch: return 1
        case .failed: return 0
        }
    }

    static func merge(
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
               $0.shazamId == shazamId
                   && (abs($0.startSeconds - incoming.startSeconds) < 35
                       || abs($0.observedAtSeconds - incoming.observedAtSeconds) < 150)
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




        if incoming.source == .shazam,
           let index = setlist.segments.firstIndex(where: {
               !$0.isDeleted
                   && ($0.source == .uploaderTracklist || $0.source == .listenerComment)
                   && abs($0.startSeconds - incoming.startSeconds) < 12
                   && labelsLikelyMatch($0.displayLabel, incoming.displayLabel)
           }) {
            var corroborated = setlist.segments[index]
            corroborated.shazamId = incoming.shazamId
            corroborated.observedAtSeconds = incoming.observedAtSeconds
            corroborated.confidence = max(corroborated.confidence, incoming.confidence)
            corroborated.evidence = [corroborated.evidence, "Confirmed by Shazam as \(incoming.displayLabel)"]
                .compactMap { $0 }
                .joined(separator: " · ")
            corroborated.updatedAt = max(
                corroborated.updatedAt ?? .distantPast,
                incoming.updatedAt ?? .distantPast
            )
            setlist.segments[index] = corroborated
            return
        }
        setlist.segments.append(incoming)
    }

    static func labelsLikelyMatch(_ lhs: String, _ rhs: String) -> Bool {
        let tokens: (String) -> Set<String> = { label in
            Set(label.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 1 && !["the", "and", "feat", "remix", "edit"].contains($0) })
        }
        let left = tokens(lhs)
        let right = tokens(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        let overlap = left.intersection(right).count
        return overlap >= 2 || Double(overlap) / Double(min(left.count, right.count)) >= 0.75
    }

    static func prefers(_ candidate: SetlistSegment, over current: SetlistSegment) -> Bool {
        if candidate.isUserEdited != current.isUserEdited { return candidate.isUserEdited }
        let sourceRank: (SetlistSegmentSource) -> Int = { source in
            switch source {
            case .user: return 4
            case .shazam: return 3
            case .uploaderTracklist: return 2
            case .listenerComment: return 1
            }
        }
        let candidateRank = sourceRank(candidate.source)
        let currentRank = sourceRank(current.source)
        if candidateRank != currentRank { return candidateRank > currentRank }
        return candidate.confidence > current.confidence
    }

    static func revision(of segment: SetlistSegment, fallback: Date) -> Date {
        segment.deletedAt ?? segment.updatedAt ?? fallback
    }

    static func normalized(_ setlist: GeneratedSetlist) -> GeneratedSetlist {
        var copy = setlist
        var byId: [String: SetlistSegment] = [:]
        for rawSegment in copy.segments {
            var segment = rawSegment
            segment.artist = SetlistText.normalized(segment.artist)
            segment.title = SetlistText.normalized(segment.title)
            segment.version = SetlistText.normalized(segment.version)
            if segment.source == .listenerComment,
               !segment.isUserEdited,
               !DeckIdentityResolver.looksLikeIdentificationAnswer(segment.displayLabel) {
                let deletionRevision = max(
                    segment.updatedAt ?? copy.updatedAt,
                    copy.updatedAt
                )
                segment.updatedAt = deletionRevision
                segment.deletedAt = deletionRevision
            }
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
            if let last = result.last,
               let shazamId = segment.shazamId,
               last.shazamId == shazamId,
               abs(last.observedAtSeconds - segment.observedAtSeconds) < 150 {
                var coalesced = prefers(segment, over: last) ? segment : last
                coalesced.startSeconds = min(last.startSeconds, segment.startSeconds)
                coalesced.observedAtSeconds = min(last.observedAtSeconds, segment.observedAtSeconds)
                result[result.count - 1] = coalesced
                continue
            }
            if let last = result.last, abs(last.startSeconds - segment.startSeconds) < 8 {
                if prefers(segment, over: last) { result[result.count - 1] = segment }
            } else {
                result.append(segment)
            }
        }
        copy.segments = (result + tombstones).sorted { $0.startSeconds < $1.startSeconds }
        return copy
    }

    static func splitLabel(_ label: String) -> (artist: String?, title: String, version: String?) {
        let cleaned = SetlistText.normalized(label)
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

}

private actor SetlistArchive {
    private static let legacyDefaultsKey = "red.forbes.sounding.generatedSetlists.v1"

    static let fileExtension = "snds"

    private let legacyDirectory: URL

    init() {
        legacyDirectory = AppDataDirectory.root.appendingPathComponent("Setlists", isDirectory: true)
    }

    private var directory: URL {
        SoundingDataLocation.shared.directory(.setlists)
    }

    func loadAll() -> [String: GeneratedSetlist] {
        let decoder = JSONDecoder()
        var result: [String: GeneratedSetlist] = [:]
        let entries = SoundingDataFiles.resolveConflicts(
            in: SoundingDataFiles.files(in: directory, extension: Self.fileExtension),
            merge: Self.merge
        )
        for entry in entries where entry.isDownloaded {
            guard case .data(let data) = SoundingDataFiles.read(entry.url),
                  let setlist = try? SoundingDataFormat.decode(GeneratedSetlist.self, from: data, kind: .setlist) else { continue }
            result[setlist.trackId] = SetlistMerging.normalized(setlist)
        }

        let legacyFiles = (try? FileManager.default.contentsOfDirectory(
            at: legacyDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        var migrated: [GeneratedSetlist] = []
        for file in legacyFiles where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let setlist = try? decoder.decode(GeneratedSetlist.self, from: data) else { continue }
            let normalized = SetlistMerging.normalized(setlist)
            let merged = result[setlist.trackId].map { SetlistMerging.merge(remote: normalized, into: $0) } ?? normalized
            result[setlist.trackId] = merged
            migrated.append(merged)
        }
        if !migrated.isEmpty {
            write(migrated)
            for file in legacyFiles where file.pathExtension == "json" {
                try? FileManager.default.moveItem(at: file, to: file.appendingPathExtension("migrated"))
            }
        }

        if let legacy = UserDefaults.standard.data(forKey: Self.legacyDefaultsKey) {
            if let decoded = try? decoder.decode([String: GeneratedSetlist].self, from: legacy) {
                for (trackId, setlist) in decoded {
                    let normalized = SetlistMerging.normalized(setlist)
                    result[trackId] = result[trackId].map { SetlistMerging.merge(remote: normalized, into: $0) } ?? normalized
                }
                write(Array(result.values))
                UserDefaults.standard.removeObject(forKey: Self.legacyDefaultsKey)
            } else {
                Log.analysis.error("Legacy setlist archive could not be decoded; leaving it in place")
            }
        }
        return result
    }

    func write(_ setlists: [GeneratedSetlist]) {
        let root = directory
        for setlist in setlists {
            guard let data = try? SoundingDataFormat.encode(setlist, kind: .setlist) else { continue }
            let url = Self.fileURL(for: setlist.trackId, in: root)
            if case .data(let existing) = SoundingDataFiles.read(url),
               let merged = Self.merge(existing, data) {
                _ = try? SoundingDataFiles.write(merged, to: url)
            } else {
                _ = try? SoundingDataFiles.write(data, to: url)
            }
        }
    }

    static func fileURL(for trackId: String, in root: URL) -> URL {
        let safe = trackId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? trackId
        return SoundingDataFiles.shardedDirectory(in: root, for: SoundingDataFiles.hashName(trackId))
            .appendingPathComponent(safe)
            .appendingPathExtension(fileExtension)
    }

    static func merge(_ current: Data, _ other: Data) -> Data? {
        guard let incoming = try? SoundingDataFormat.decode(GeneratedSetlist.self, from: other, kind: .setlist) else { return nil }
        guard let existing = try? SoundingDataFormat.decode(GeneratedSetlist.self, from: current, kind: .setlist) else { return other }
        let merged = SetlistMerging.merge(remote: SetlistMerging.normalized(incoming), into: SetlistMerging.normalized(existing))
        return try? SoundingDataFormat.encode(merged, kind: .setlist)
    }
}
