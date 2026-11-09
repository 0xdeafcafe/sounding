import Foundation

enum AppDataDirectory {
    static var root: URL {
        #if os(tvOS)
        return caches
        #else
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? caches
        #endif
    }

    static var caches: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? temporary
    }

    private static var temporary: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    static func folder(_ name: String) -> URL {
        let preferred = root.appendingPathComponent(name, isDirectory: true)
        if prepare(preferred) { return preferred }
        let fallback = caches.appendingPathComponent(name, isDirectory: true)
        if fallback != preferred, prepare(fallback) { return fallback }
        let last = temporary.appendingPathComponent(name, isDirectory: true)
        prepare(last)
        return last
    }

    static func file(_ name: String) -> URL {
        if prepare(root) { return root.appendingPathComponent(name) }
        return caches.appendingPathComponent(name)
    }

    @discardableResult
    static func prepare(_ directory: URL) -> Bool {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return true
        } catch {
            Log.library.error("Could not create \(directory.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
