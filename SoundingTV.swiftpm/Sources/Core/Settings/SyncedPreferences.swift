import Foundation

struct SyncedPreferenceRules: Sendable {
    let exactKeys: Set<String>
    let prefixes: [String]

    func syncs(_ key: String) -> Bool {
        exactKeys.contains(key) || prefixes.contains { key.hasPrefix($0) }
    }

    static let appleID = SyncedPreferenceRules(
        exactKeys: [
            "library.likes.query",
            "library.sets.query",
            "library.songs.query",
            "playlist.query",
            "mac.library.showsArtwork",
            "mac.library.compactRows",
            "mac.trackTable.hiddenColumns",
            "mac.songs.source",
            "dj.mixer.crossfaderCurve",
            "dj.mixer.faderCurve",
            "red.forbes.sounding.generatedInsights.visible",
        ],
        prefixes: [
            "trackList.",
            "trackTable.",
            "mac.table.",
            "mac.library.filters.",
            "red.forbes.sounding.synced.",
        ]
    )
}

@MainActor
final class SyncedPreferences {
    static let idPrefix = "defaults:"

    var onLocalChange: (@MainActor () -> Void)?

    private let defaults: UserDefaults
    private let rules: SyncedPreferenceRules
    private let writerId: String
    private let now: () -> Date
    private var revisions: [String: SettingRevision]
    private var values: [String: Data]
    private var hasBaseline: Bool
    private var observer: NSObjectProtocol?
    private var pendingScan: Task<Void, Never>?

    private enum StorageKey {
        static let revisions = "red.forbes.sounding.settings.preferences.v1.revisions"
        static let values = "red.forbes.sounding.settings.preferences.v1.values"
    }

    init(defaults: UserDefaults, rules: SyncedPreferenceRules, writerId: String, now: @escaping () -> Date) {
        self.defaults = defaults
        self.rules = rules
        self.writerId = writerId
        self.now = now
        let storedRevisions = defaults.data(forKey: StorageKey.revisions)
            .flatMap { try? JSONDecoder().decode([String: SettingRevision].self, from: $0) }
        let storedValues = defaults.data(forKey: StorageKey.values)
            .flatMap { try? JSONDecoder().decode([String: Data].self, from: $0) }
        revisions = storedRevisions ?? [:]
        values = storedValues ?? [:]
        hasBaseline = storedValues != nil
    }

    func startObserving() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleScan() }
        }
        scheduleScan()
    }

    private func scheduleScan() {
        pendingScan?.cancel()
        pendingScan = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.scan()
        }
    }

    @discardableResult
    func scan() -> Bool {
        let current = currentValues()
        let wasBaselined = hasBaseline
        var nextRevisions = revisions
        var changed = false
        for (key, data) in current where !Self.isSameValue(values[key], data) {
            if wasBaselined {
                nextRevisions[key] = SettingsMerge.nextRevision(
                    after: revisions[key],
                    nowMillis: Int64(now().timeIntervalSince1970 * 1000),
                    writerId: writerId
                )
            } else if nextRevisions[key] == nil {
                nextRevisions[key] = SettingRevision(revision: 1, updatedAtMillis: 1, writerId: writerId)
            }
            changed = true
        }
        let removed = Set(values.keys).subtracting(current.keys)
        guard changed || !removed.isEmpty || !wasBaselined else { return false }
        values = current
        revisions = nextRevisions
        hasBaseline = true
        persist()
        if changed && wasBaselined { onLocalChange?() }
        return changed
    }

    func entries() -> [SettingsSyncPayload.Entry] {
        values.compactMap { key, data in
            guard rules.syncs(key), let revision = revisions[key] else { return nil }
            return SettingsSyncPayload.Entry(
                id: Self.idPrefix + key,
                valueJSON: data,
                revision: revision.revision,
                updatedAtMillis: revision.updatedAtMillis,
                writerId: revision.writerId
            )
        }
        .sorted { $0.id < $1.id }
    }

    func knows(_ id: String) -> Bool {
        guard let key = Self.key(fromId: id) else { return false }
        return rules.syncs(key)
    }

    func revision(for id: String) -> SettingRevision? {
        Self.key(fromId: id).flatMap { revisions[$0] }
    }

    func apply(_ entry: SettingsSyncPayload.Entry) -> Bool {
        guard let key = Self.key(fromId: entry.id), rules.syncs(key),
              let value = Self.decode(entry.valueJSON) else { return false }
        values[key] = entry.valueJSON
        revisions[key] = SettingRevision(
            revision: entry.revision,
            updatedAtMillis: entry.updatedAtMillis,
            writerId: entry.writerId
        )
        hasBaseline = true
        persist()
        defaults.set(value, forKey: key)
        return true
    }

    private func currentValues() -> [String: Data] {
        var result: [String: Data] = [:]
        for (key, value) in defaults.dictionaryRepresentation() where rules.syncs(key) {
            if let data = Self.encode(value) { result[key] = data }
        }
        return result
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(revisions) {
            defaults.set(data, forKey: StorageKey.revisions)
        }
        if let data = try? JSONEncoder().encode(values) {
            defaults.set(data, forKey: StorageKey.values)
        }
    }

    private static func key(fromId id: String) -> String? {
        guard id.hasPrefix(idPrefix) else { return nil }
        return String(id.dropFirst(idPrefix.count))
    }

    static func encode(_ value: Any) -> Data? {
        try? PropertyListSerialization.data(fromPropertyList: [value], format: .binary, options: 0)
    }

    static func decode(_ data: Data) -> Any? {
        let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return (object as? [Any])?.first
    }

    private static func isSameValue(_ stored: Data?, _ current: Data) -> Bool {
        guard let stored else { return false }
        if stored == current { return true }
        guard let lhs = decode(stored) as? NSObject, let rhs = decode(current) as? NSObject else { return false }
        return lhs.isEqual(rhs)
    }
}
