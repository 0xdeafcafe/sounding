import Foundation
import Security

enum BuildFlavor: String, CaseIterable, Sendable {
    case debug
    case release

    static let current: BuildFlavor = detect()

    var isDebug: Bool { self == .debug }

    var keychainServiceSuffix: String {
        isDebug ? ".debug" : ""
    }

    func keychainService(_ service: String) -> String {
        service + keychainServiceSuffix
    }

    func keychainQuery(_ query: [String: Any]) -> [String: Any] {
        guard isDebug else { return query }
        var query = query
        if let service = query[kSecAttrService as String] as? String {
            query[kSecAttrService as String] = keychainService(service)
        }
        query.removeValue(forKey: kSecAttrSynchronizable as String)
        return query
    }

    var defaultsSuiteName: String? {
        isDebug ? "red.forbes.sounding.debug" : nil
    }

    var directoryName: String? {
        isDebug ? "Debug" : nil
    }

    func directory(in base: URL) -> URL {
        guard let directoryName else { return base }
        return base.appendingPathComponent(directoryName, isDirectory: true)
    }

    var bonjourServiceType: String {
        isDebug ? "_soundingtv-dev._tcp" : "_soundingtv._tcp"
    }

    func identifier(_ identifier: String) -> String {
        isDebug ? identifier + ".debug" : identifier
    }

    // MARK: - Detection

    static func detect(bundle: Bundle = .main) -> BuildFlavor {
        #if DEBUG
        return .debug
        #else
        return usesDevelopmentCloudKit(bundle: bundle) ? .debug : .release
        #endif
    }

    static let cloudKitEnvironmentEntitlement = "com.apple.developer.icloud-container-environment"

    static func usesDevelopmentCloudKit(bundle: Bundle) -> Bool {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        if let environment = SecTaskCopyValueForEntitlement(task, cloudKitEnvironmentEntitlement as CFString, nil) as? String {
            return environment == "Development"
        }
        return SecTaskCopyValueForEntitlement(task, "get-task-allow" as CFString, nil) as? Bool ?? false
        #else
        guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else { return false }
        return isDevelopmentProfile(data)
        #endif
    }

    static func isDevelopmentProfile(_ data: Data) -> Bool {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil
              ) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return false }
        if let environment = entitlements[cloudKitEnvironmentEntitlement] as? String {
            return environment == "Development"
        }
        return entitlements["get-task-allow"] as? Bool ?? false
    }
}

extension UserDefaults {
    nonisolated(unsafe) static let sounding: UserDefaults = BuildFlavor.current.defaultsSuiteName
        .flatMap(UserDefaults.init(suiteName:)) ?? .standard
}

extension FileManager {
    func soundingDirectory(_ directory: SearchPathDirectory) -> URL? {
        guard let base = urls(for: directory, in: .userDomainMask).first else { return nil }
        let scoped = BuildFlavor.current.directory(in: base)
        if scoped != base, !fileExists(atPath: scoped.path) {
            try? createDirectory(at: scoped, withIntermediateDirectories: true)
        }
        return scoped
    }
}
