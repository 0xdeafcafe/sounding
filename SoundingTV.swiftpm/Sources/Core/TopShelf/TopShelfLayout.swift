import Foundation

struct TopShelfTile: Equatable, Sendable {
    let id: String
    let title: String
    let shape: TopShelfShape
    let progress: Double
    let imageURL: URL?
    let imageURL2x: URL?
    let displayURL: URL
    let playURL: URL
}

struct TopShelfRow: Equatable, Sendable {
    let kind: String
    let title: String
    let tiles: [TopShelfTile]
}

enum TopShelfFallback: Equatable, Sendable {
    case signedOut
    case noSnapshot
    case emptyLibrary
}

enum TopShelfContentPlan: Equatable, Sendable {
    case rows([TopShelfRow])
    case fallback(TopShelfFallback)
}

enum TopShelfLayout {
    static let continueLimit = 6
    static let continueProgress: ClosedRange<Double> = 0.02...0.95
    static let continueWindow: TimeInterval = 14 * 24 * 60 * 60
    static let minimumResumableDuration: TimeInterval = 10 * 60
    static let setDuration: TimeInterval = 20 * 60

    static let rowOrder = [
        TopShelfStore.continueKind,
        TopShelfStore.recentsKind,
        TopShelfStore.likesKind,
        TopShelfStore.mixesKind,
    ]

    static func plan(
        for snapshot: TopShelfSnapshot?,
        now: Date = Date(),
        placeholder: (URL?, URL?) = (nil, nil),
        locale: Locale = .autoupdatingCurrent
    ) -> TopShelfContentPlan {
        guard let snapshot else { return .fallback(.noSnapshot) }
        guard snapshot.isSignedIn else { return .fallback(.signedOut) }

        let recents = snapshot.section(kind: TopShelfStore.recentsKind)?.entries ?? []
        let resumable = recents.filter { isResumable($0, now: now) }.prefix(continueLimit)
        let resumableIDs = Set(resumable.map(\.trackID))

        var candidates: [(kind: String, fallbackTitle: String, tiles: [TopShelfTile])] = []
        if !resumable.isEmpty {
            candidates.append((
                TopShelfStore.continueKind,
                "Continue Listening",
                resumable.map { resumeTile(for: $0, placeholder: placeholder, locale: locale) }
            ))
        }

        let ordered = snapshot.sections.enumerated().sorted { lhs, rhs in
            let left = rowOrder.firstIndex(of: lhs.element.kind) ?? rowOrder.count + lhs.offset
            let right = rowOrder.firstIndex(of: rhs.element.kind) ?? rowOrder.count + rhs.offset
            return left < right
        }.map(\.element)

        for section in ordered where section.kind != TopShelfStore.continueKind {
            var entries = section.entries
            if section.kind == TopShelfStore.recentsKind {
                entries.removeAll { resumableIDs.contains($0.trackID) }
            }
            let tiles = entries.map { tile(for: $0, shelf: section.kind, placeholder: placeholder, locale: locale) }
            candidates.append((section.kind, section.title, tiles))
        }

        var seen = Set<String>()
        var rows: [TopShelfRow] = []
        for candidate in candidates {
            var tiles: [TopShelfTile] = []
            for tile in candidate.tiles where tiles.count < TopShelfStore.maxEntriesPerSection {
                guard seen.insert(tile.id).inserted else { continue }
                tiles.append(tile)
            }
            guard !tiles.isEmpty else { continue }
            rows.append(TopShelfRow(
                kind: candidate.kind,
                title: rowTitle(kind: candidate.kind, fallback: candidate.fallbackTitle),
                tiles: tiles
            ))
            if rows.count == TopShelfStore.maxSections { break }
        }

        return rows.isEmpty ? .fallback(.emptyLibrary) : .rows(rows)
    }

    static func isResumable(_ entry: TopShelfEntry, now: Date) -> Bool {
        guard entry.kind == .track,
              let duration = entry.duration, duration >= minimumResumableDuration,
              continueProgress.contains(entry.progress) else { return false }
        if let playedAt = entry.playedAt, now.timeIntervalSince(playedAt) > continueWindow { return false }
        return true
    }

    static func rowTitle(kind: String, fallback: String) -> String {
        switch kind {
        case TopShelfStore.continueKind: return String(localized: "Continue Listening")
        case TopShelfStore.recentsKind:  return String(localized: "Recently Played")
        case TopShelfStore.likesKind:    return String(localized: "Your Likes")
        case TopShelfStore.mixesKind:    return String(localized: "Mixes For You")
        default:                         return fallback
        }
    }

    static func tile(
        for entry: TopShelfEntry,
        shelf: String,
        placeholder: (URL?, URL?),
        locale: Locale = .autoupdatingCurrent
    ) -> TopShelfTile {
        let play = entry.playActionURL ?? entry.actionURL ?? TopShelfStore.homeURL()
        let display = play
        return TopShelfTile(
            id: entry.id,
            title: title(for: entry, locale: locale),
            shape: entry.shape,
            progress: shelf == TopShelfStore.recentsKind && entry.progress < continueProgress.upperBound ? entry.progress : 0,
            imageURL: entry.artworkURL ?? placeholder.0,
            imageURL2x: entry.artworkURL2x ?? entry.artworkURL ?? placeholder.1 ?? placeholder.0,
            displayURL: display,
            playURL: play
        )
    }

    static func resumeTile(
        for entry: TopShelfEntry,
        placeholder: (URL?, URL?),
        locale: Locale = .autoupdatingCurrent
    ) -> TopShelfTile {
        let position = (entry.duration ?? 0) * entry.progress
        let url = TopShelfStore.playURL(trackId: entry.trackID, shelf: TopShelfStore.recentsKind, at: position)
        return TopShelfTile(
            id: "\(TopShelfStore.continueKind):\(entry.trackID)",
            title: resumeTitle(for: entry, locale: locale),
            shape: entry.shape,
            progress: entry.progress,
            imageURL: entry.artworkURL ?? placeholder.0,
            imageURL2x: entry.artworkURL2x ?? entry.artworkURL ?? placeholder.1 ?? placeholder.0,
            displayURL: url,
            playURL: url
        )
    }

    static func title(for entry: TopShelfEntry, locale: Locale = .autoupdatingCurrent) -> String {
        var parts = [baseTitle(entry)]
        let subtitle = entry.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !subtitle.isEmpty, subtitle != parts[0] {
            parts.append(subtitle)
        }
        if entry.kind == .track, let duration = entry.duration, duration >= setDuration,
           let text = durationText(duration, locale: locale) {
            parts.append(text)
        }
        return parts.joined(separator: " · ")
    }

    static func resumeTitle(for entry: TopShelfEntry, locale: Locale = .autoupdatingCurrent) -> String {
        let base = baseTitle(entry)
        guard let duration = entry.duration else { return base }
        let remaining = max(60, duration * (1 - entry.progress))
        guard let text = durationText(remaining, locale: locale) else { return base }
        return String(localized: "\(base) · \(text) left")
    }

    static func durationText(_ seconds: TimeInterval, locale: Locale = .autoupdatingCurrent) -> String? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.unitsStyle = .short
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        formatter.zeroFormattingBehavior = .dropAll
        let rounded = (seconds / 60).rounded() * 60
        return formatter.string(from: max(60, rounded))
    }

    private static func baseTitle(_ entry: TopShelfEntry) -> String {
        let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? String(localized: "Untitled") : title
    }
}
