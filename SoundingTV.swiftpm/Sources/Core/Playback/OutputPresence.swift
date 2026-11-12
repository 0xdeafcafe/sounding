import Foundation

enum OutputAvailability: Equatable, Sendable {
    case available
    case connecting
    case notResponding

    var isSelectable: Bool { self == .available }

    var label: String? {
        switch self {
        case .available: return nil
        case .connecting: return "Connecting…"
        case .notResponding: return "Not Responding"
        }
    }
}

struct OutputListEntry: Identifiable, Equatable, Sendable {
    let device: OutputDevice
    let availability: OutputAvailability

    var id: String { device.id }
}

// MARK: - Presence

struct OutputPresence: Equatable, Sendable {
    static let settle: TimeInterval = 10
    static let grace: TimeInterval = 45

    let settle: TimeInterval
    let grace: TimeInterval
    private(set) var known: Set<String> = []
    private(set) var missingSince: [String: Date] = [:]

    init(settle: TimeInterval = OutputPresence.settle, grace: TimeInterval = OutputPresence.grace) {
        self.settle = settle
        self.grace = max(grace, settle)
    }

    mutating func observe(live: Set<String>, at now: Date) {
        for id in live {
            known.insert(id)
            missingSince[id] = nil
        }
        for id in known where !live.contains(id) && missingSince[id] == nil {
            missingSince[id] = now
        }
    }

    mutating func retain(only ids: Set<String>) {
        known.formIntersection(ids)
        missingSince = missingSince.filter { ids.contains($0.key) }
    }

    func availability(of id: String, at now: Date) -> OutputAvailability? {
        guard known.contains(id) else { return nil }
        guard let since = missingSince[id] else { return .available }
        let missing = now.timeIntervalSince(since)
        if missing < settle { return .available }
        if missing < grace { return .notResponding }
        return nil
    }

    func nextChange(after now: Date) -> Date? {
        missingSince.values
            .flatMap { [$0.addingTimeInterval(settle), $0.addingTimeInterval(grace)] }
            .filter { $0 > now }
            .min()
    }
}

// MARK: - List

enum OutputList {
    static func entries(
        local: OutputDevice,
        linked: [OutputDevice],
        current: OutputDevice,
        preferredID: String? = nil,
        presence: OutputPresence,
        at now: Date
    ) -> [OutputListEntry] {
        var seen: Set<String> = []
        var remote: [OutputListEntry] = []
        for device in linked where !device.isLocal {
            guard seen.insert(device.id).inserted else { continue }
            let isCurrent = device.id == current.id
            let availability = presence.availability(of: device.id, at: now)
            if let availability {
                remote.append(OutputListEntry(device: isCurrent ? current : device, availability: availability))
            } else if isCurrent {
                remote.append(OutputListEntry(device: current, availability: presence.known.contains(device.id) ? .notResponding : .connecting))
            }
        }
        if !current.isLocal, !seen.contains(current.id) {
            remote.append(OutputListEntry(device: current, availability: .connecting))
        }
        remote = deduplicated(remote, currentID: current.id, preferredID: preferredID)

        let localEntry = OutputListEntry(device: local, availability: .available)
        let all = [localEntry] + remote
        return all.sorted { order($0, $1, currentID: current.id, localID: local.id) }
    }

    private static func deduplicated(_ entries: [OutputListEntry], currentID: String, preferredID: String?) -> [OutputListEntry] {
        var groups: [String: [OutputListEntry]] = [:]
        for entry in entries {
            groups["\(entry.device.deviceClass.rawValue)|\(entry.device.name.lowercased())", default: []].append(entry)
        }
        var kept: [OutputListEntry] = []
        for group in groups.values {
            if group.filter({ $0.availability == .available }).count > 1 {
                kept += group.filter { $0.availability == .available || $0.id == currentID }
            } else if let best = group.min(by: { rank($0, currentID: currentID, preferredID: preferredID) < rank($1, currentID: currentID, preferredID: preferredID) }) {
                kept.append(best)
            }
        }
        return kept
    }

    private static func rank(_ entry: OutputListEntry, currentID: String, preferredID: String?) -> (Int, Int, Int, String) {
        let availability: Int
        switch entry.availability {
        case .available: availability = 0
        case .connecting: availability = 1
        case .notResponding: availability = 2
        }
        return (
            entry.id == currentID ? 0 : 1,
            entry.id == preferredID ? 0 : 1,
            availability,
            entry.id
        )
    }

    private static func order(_ lhs: OutputListEntry, _ rhs: OutputListEntry, currentID: String, localID: String) -> Bool {
        if (lhs.id == currentID) != (rhs.id == currentID) { return lhs.id == currentID }
        if (lhs.id == localID) != (rhs.id == localID) { return lhs.id == localID }
        let byName = lhs.device.name.localizedStandardCompare(rhs.device.name)
        if byName != .orderedSame { return byName == .orderedAscending }
        return lhs.id < rhs.id
    }
}

// MARK: - Restore

struct OutputRestore: Equatable, Sendable {
    static let window: TimeInterval = 25

    enum Decision: Equatable, Sendable {
        case wait
        case restored
        case fallBack
    }

    let savedID: String
    let startedAt: Date
    let window: TimeInterval

    init(savedID: String, startedAt: Date, window: TimeInterval = OutputRestore.window) {
        self.savedID = savedID
        self.startedAt = startedAt
        self.window = window
    }

    var deadline: Date { startedAt.addingTimeInterval(window) }

    func decide(linkedIDs: Set<String>, liveIDs: Set<String>, at now: Date) -> Decision {
        if savedID == OutputDevice.localID { return .restored }
        guard linkedIDs.contains(savedID) else { return .fallBack }
        if liveIDs.contains(savedID) { return .restored }
        return now >= deadline ? .fallBack : .wait
    }
}

// MARK: - Preference

struct OutputPreference {
    static let key = "red.forbes.sounding.output.v1"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .sounding) {
        self.defaults = defaults
    }

    var savedID: String? {
        defaults.string(forKey: Self.key)
    }

    func remember(_ device: OutputDevice) {
        defaults.set(device.id, forKey: Self.key)
    }

    func forget() {
        defaults.removeObject(forKey: Self.key)
    }
}

// MARK: - Who plays where

enum OutputHandover: Equatable, Sendable {
    case sendThisDevice
    case controlRemote

    static func plan(localIsPlaying: Bool, localHasTrack: Bool, remoteIsPlaying: Bool, remoteHasTrack: Bool) -> OutputHandover {
        if localIsPlaying, localHasTrack { return .sendThisDevice }
        if remoteIsPlaying, remoteHasTrack { return .controlRemote }
        return localHasTrack ? .sendThisDevice : .controlRemote
    }
}

enum OutputFollow {
    static let localQuietPeriod: TimeInterval = 600

    static func shouldFollow(
        currentIsLocal: Bool,
        isMoving: Bool,
        localIsPlaying: Bool,
        localLastPlayedAt: Date?,
        remoteIsAudible: Bool,
        remoteWasAudible: Bool,
        now: Date
    ) -> Bool {
        guard remoteIsAudible, !remoteWasAudible, currentIsLocal, !isMoving, !localIsPlaying else { return false }
        guard let localLastPlayedAt else { return true }
        return now.timeIntervalSince(localLastPlayedAt) >= localQuietPeriod
    }
}
