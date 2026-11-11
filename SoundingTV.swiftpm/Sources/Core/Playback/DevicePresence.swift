import Foundation

enum DevicePresenceSource: Int, Codable, Sendable, Comparable {
    case cloud
    case link
    case companion

    static func < (lhs: DevicePresenceSource, rhs: DevicePresenceSource) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum DevicePresenceFreshness: Int, Codable, Sendable, Comparable {
    case live
    case paused
    case stale

    static func < (lhs: DevicePresenceFreshness, rhs: DevicePresenceFreshness) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct DevicePresenceEntry: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var deviceName: String
    var deviceClass: DeviceClass
    var trackID: String
    var title: String
    var artist: String
    var artworkURL: URL?
    var isPlaying: Bool
    var position: TimeInterval
    var duration: TimeInterval
    var updatedAt: Date
    var startedAt: Date
    var source: DevicePresenceSource
    var freshness: DevicePresenceFreshness
    var outputID: String?
    var isOutput: Bool

    var displayName: String {
        let trimmed = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? deviceClass.displayName : trimmed
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "a track" : trimmed
    }

    var isLive: Bool { freshness == .live }

    func age(at now: Date) -> TimeInterval { max(0, now.timeIntervalSince(updatedAt)) }

    func sentence(at now: Date) -> String {
        switch freshness {
        case .live:
            return "\(displayName) is playing \(displayTitle)"
        case .paused:
            let age = self.age(at: now)
            guard source != .companion, age >= DevicePresence.quietAge else { return "\(displayName) paused \(displayTitle)" }
            return "\(displayName) paused \(displayTitle) \u{00B7} \(DevicePresence.ago(age))"
        case .stale:
            return "\(displayName) was playing \(displayTitle) \u{00B7} \(DevicePresence.ago(age(at: now)))"
        }
    }

    func caption(at now: Date) -> String {
        switch freshness {
        case .live:
            return "Playing on \(displayName)"
        case .paused:
            let age = self.age(at: now)
            guard source != .companion, age >= DevicePresence.quietAge else { return "Paused on \(displayName)" }
            return "Paused on \(displayName) \u{00B7} \(DevicePresence.ago(age))"
        case .stale:
            return "\(displayName) \u{00B7} \(DevicePresence.ago(age(at: now)))"
        }
    }

    func evaluated(at now: Date, trustsLive: Bool = true) -> DevicePresenceEntry? {
        var copy = self
        if source == .companion, trustsLive { return copy }
        guard let next = DevicePresence.freshness(
            isPlaying: isPlaying,
            source: source == .companion ? .link : source,
            age: now.timeIntervalSince(updatedAt)
        ) else { return nil }
        copy.freshness = next
        return copy
    }
}

struct DevicePresenceLiveReport: Equatable, Sendable {
    var outputID: String
    var deviceName: String
    var deviceClass: DeviceClass
    var trackID: String?
    var title: String
    var artist: String
    var artworkURL: URL?
    var isPlaying: Bool
    var position: TimeInterval
    var duration: TimeInterval
    var receivedAt: Date
    var startedAt: Date
}

struct DevicePresenceOutput: Equatable, Sendable {
    var id: String
    var name: String
    var deviceClass: DeviceClass
}

struct DevicePresenceRecord: Equatable, Sendable {
    var session: ContinueSession
    var source: DevicePresenceSource
}

enum DevicePresence {
    static let liveWindow: TimeInterval = 90
    static let staleWindow: TimeInterval = 30 * 60
    static let pausedWindow: TimeInterval = 30 * 60
    static let futureSkew: TimeInterval = 5 * 60
    static let quietAge: TimeInterval = 120

    static func freshness(isPlaying: Bool, source: DevicePresenceSource, age: TimeInterval) -> DevicePresenceFreshness? {
        guard age >= -futureSkew else { return nil }
        if source == .companion { return isPlaying ? .live : .paused }
        if isPlaying {
            if age <= liveWindow { return .live }
            return age <= staleWindow ? .stale : nil
        }
        return age <= pausedWindow ? .paused : nil
    }

    static func freshness(of session: ContinueSession, at now: Date) -> DevicePresenceFreshness? {
        let playing = session.isPlaying && !session.isFinished(at: now)
        return freshness(isPlaying: playing, source: .link, age: now.timeIntervalSince(session.updatedAt))
    }

    // MARK: - Merge

    static func entries(
        records: [DevicePresenceRecord],
        live: [DevicePresenceLiveReport] = [],
        outputs: [DevicePresenceOutput] = [],
        currentOutputID: String? = nil,
        ownDeviceID: String,
        account: String?,
        localTrackID: String? = nil,
        now: Date
    ) -> [DevicePresenceEntry] {
        var byDevice: [String: DevicePresenceRecord] = [:]
        for record in records {
            let session = record.session
            guard !session.deviceID.isEmpty, !session.trackID.isEmpty, session.deviceID != ownDeviceID else { continue }
            if let account, !account.isEmpty, !session.account.isEmpty, session.account != account { continue }
            if let existing = byDevice[session.deviceID], !prefers(record, over: existing) { continue }
            byDevice[session.deviceID] = record
        }

        var byIdentity: [String: DevicePresenceRecord] = [:]
        for record in byDevice.values {
            let key = identity(name: record.session.deviceName, deviceClass: record.session.deviceClass)
            if let existing = byIdentity[key], !prefers(record, over: existing) { continue }
            byIdentity[key] = record
        }

        var entries: [DevicePresenceEntry] = byIdentity.values.compactMap { record in
            entry(from: record, outputs: outputs, currentOutputID: currentOutputID, now: now)
        }

        for report in live {
            let matched = entries.firstIndex { matches($0, report) }
            guard let trackID = report.trackID, !trackID.isEmpty else {
                if let matched { entries.remove(at: matched) }
                continue
            }
            let liveEntry = DevicePresenceEntry(
                id: matched.map { entries[$0].id } ?? "output:\(report.outputID)",
                deviceName: report.deviceName,
                deviceClass: report.deviceClass,
                trackID: trackID,
                title: report.title,
                artist: report.artist,
                artworkURL: report.artworkURL,
                isPlaying: report.isPlaying,
                position: report.position,
                duration: report.duration,
                updatedAt: report.receivedAt,
                startedAt: report.startedAt,
                source: .companion,
                freshness: report.isPlaying ? .live : .paused,
                outputID: report.outputID,
                isOutput: report.outputID == currentOutputID
            )
            if let matched {
                entries[matched] = liveEntry
            } else {
                entries.append(liveEntry)
            }
        }

        if let localTrackID, !localTrackID.isEmpty {
            entries.removeAll { !$0.isLive && !$0.isOutput && $0.trackID == localTrackID }
        }
        return ordered(entries)
    }

    private static func prefers(_ candidate: DevicePresenceRecord, over existing: DevicePresenceRecord) -> Bool {
        if candidate.session.updatedAtMillis != existing.session.updatedAtMillis {
            return candidate.session.updatedAtMillis > existing.session.updatedAtMillis
        }
        if candidate.source != existing.source { return candidate.source > existing.source }
        return candidate.session.isNewer(than: existing.session)
    }

    private static func entry(
        from record: DevicePresenceRecord,
        outputs: [DevicePresenceOutput],
        currentOutputID: String?,
        now: Date
    ) -> DevicePresenceEntry? {
        let session = record.session
        let playing = session.isPlaying && !session.isFinished(at: now)
        guard let freshness = freshness(isPlaying: playing, source: record.source, age: now.timeIntervalSince(session.updatedAt)) else {
            return nil
        }
        let key = identity(name: session.deviceName, deviceClass: session.deviceClass)
        let output = outputs.first { identity(name: $0.name, deviceClass: $0.deviceClass) == key }
        return DevicePresenceEntry(
            id: "device:\(session.deviceID)",
            deviceName: session.deviceName,
            deviceClass: session.deviceClass,
            trackID: session.trackID,
            title: session.title,
            artist: session.artist,
            artworkURL: session.artworkURL,
            isPlaying: playing,
            position: session.position,
            duration: session.duration,
            updatedAt: session.updatedAt,
            startedAt: session.startedAt ?? session.updatedAt,
            source: record.source,
            freshness: freshness,
            outputID: output?.id,
            isOutput: output != nil && output?.id == currentOutputID
        )
    }

    private static func matches(_ entry: DevicePresenceEntry, _ report: DevicePresenceLiveReport) -> Bool {
        if entry.outputID == report.outputID { return true }
        guard entry.deviceClass == report.deviceClass else { return false }
        if identity(name: entry.deviceName, deviceClass: entry.deviceClass)
            == identity(name: report.deviceName, deviceClass: report.deviceClass) { return true }
        guard let trackID = report.trackID else { return false }
        return entry.isLive && report.isPlaying && entry.trackID == trackID
    }

    static func identity(name: String, deviceClass: DeviceClass) -> String {
        let folded = name
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return "\(deviceClass.rawValue)|\(folded)"
    }

    // MARK: - Selection

    static func ordered(_ entries: [DevicePresenceEntry]) -> [DevicePresenceEntry] {
        entries.sorted { lhs, rhs in
            if lhs.isOutput != rhs.isOutput { return lhs.isOutput }
            if lhs.freshness != rhs.freshness { return lhs.freshness < rhs.freshness }
            let lhsMoment = lhs.isLive ? lhs.startedAt : lhs.updatedAt
            let rhsMoment = rhs.isLive ? rhs.startedAt : rhs.updatedAt
            if lhsMoment != rhsMoment { return lhsMoment > rhsMoment }
            let byName = lhs.displayName.localizedStandardCompare(rhs.displayName)
            if byName != .orderedSame { return byName == .orderedAscending }
            return lhs.id < rhs.id
        }
    }

    static func primary(in entries: [DevicePresenceEntry]) -> DevicePresenceEntry? {
        ordered(entries).first
    }

    static func others(_ entries: [DevicePresenceEntry], excludingOutput: Bool) -> [DevicePresenceEntry] {
        ordered(excludingOutput ? entries.filter { !$0.isOutput } : entries)
    }

    static func moreLabel(count: Int) -> String? {
        count > 1 ? "+\(count - 1)" : nil
    }

    static func nextChange(for entries: [DevicePresenceEntry], after now: Date) -> Date? {
        entries.compactMap { entry -> Date? in
            guard entry.source != .companion else { return nil }
            let candidates: [Date]
            switch entry.freshness {
            case .live:
                candidates = [entry.updatedAt.addingTimeInterval(liveWindow)]
            case .paused:
                candidates = [
                    entry.updatedAt.addingTimeInterval(quietAge),
                    entry.updatedAt.addingTimeInterval(pausedWindow),
                ]
            case .stale:
                candidates = [entry.updatedAt.addingTimeInterval(staleWindow)]
            }
            return candidates.filter { $0 > now }.min()
        }
        .min()
    }

    // MARK: - Words

    static func ago(_ age: TimeInterval) -> String {
        let seconds = max(0, age)
        if seconds < 60 { return "just now" }
        if seconds < 5 * 60 { return "a few minutes ago" }
        if seconds < 60 * 60 { return "\(Int(seconds / 60)) min ago" }
        let hours = Int(seconds / 3600)
        return hours == 1 ? "1 hr ago" : "\(hours) hr ago"
    }

    static func summary(localTitle: String?, others: [DevicePresenceEntry], now: Date) -> String {
        var parts: [String] = []
        if let localTitle {
            let trimmed = localTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            parts.append("You\u{2019}re playing \(trimmed.isEmpty ? "a track" : trimmed)")
        }
        parts += ordered(others).map { $0.sentence(at: now) }
        guard !parts.isEmpty else { return "" }
        return parts.joined(separator: ". ") + "."
    }
}
