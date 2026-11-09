import Foundation

enum WidgetArtworkStore {
    static let directoryName = "WidgetArtwork"
    static let pixelSize = 240

    static var directory: URL? {
        SoundingAppGroup.writableURL?.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func fileName(for item: SoundingSnapshot.Item) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let id = String(item.id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.prefix(96))
        return "\(item.kind.rawValue)-\(id).jpg"
    }

    static func url(for item: SoundingSnapshot.Item) -> URL? {
        directory?.appendingPathComponent(fileName(for: item))
    }

    static func exists(for item: SoundingSnapshot.Item) -> Bool {
        guard let url = url(for: item) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    @discardableResult
    static func write(_ data: Data, for item: SoundingSnapshot.Item) -> Bool {
        guard let directory else { return false }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try data.write(
                to: directory.appendingPathComponent(fileName(for: item)),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            return true
        } catch {
            return false
        }
    }

    static func prune(keeping names: Set<String>) {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for file in files where !names.contains(file) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }

    static func removeAll() {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
