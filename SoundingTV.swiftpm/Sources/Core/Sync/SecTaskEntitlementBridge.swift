import Foundation
import Darwin

enum SecTaskEntitlementBridge {
    private typealias CreateFromSelfFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias CopyValueForEntitlementFn = @convention(c) (
        CFTypeRef, CFString, UnsafeMutablePointer<Unmanaged<CFError>?>?
    ) -> Unmanaged<CFTypeRef>?

    static func stringArrayValue(forEntitlement entitlement: String) -> [String]? {
        value(forEntitlement: entitlement) as? [String]
    }

    static func stringValue(forEntitlement entitlement: String) -> String? {
        value(forEntitlement: entitlement) as? String
    }

    static func value(forEntitlement entitlement: String) -> Any? {
        guard let handle = dlopen(nil, RTLD_NOW) else { return nil }
        defer { dlclose(handle) }

        guard
            let createSymbol = dlsym(handle, "SecTaskCreateFromSelf"),
            let copySymbol = dlsym(handle, "SecTaskCopyValueForEntitlement")
        else { return nil }

        let createFromSelf = unsafeBitCast(createSymbol, to: CreateFromSelfFn.self)
        let copyValueForEntitlement = unsafeBitCast(copySymbol, to: CopyValueForEntitlementFn.self)

        guard let taskUnmanaged = createFromSelf(nil) else { return nil }
        let task = taskUnmanaged.takeRetainedValue()

        guard let valueUnmanaged = copyValueForEntitlement(task, entitlement as CFString, nil) else {
            return nil
        }
        return valueUnmanaged.takeRetainedValue()
    }
}

struct CloudKitEntitlements: Sendable {
    let containerIdentifiers: Set<String>
    let hasCloudKitService: Bool
    let hasApplicationIdentifier: Bool

    static let current = CloudKitEntitlements(
        containerIdentifiers: Set(
            SecTaskEntitlementBridge.stringArrayValue(forEntitlement: "com.apple.developer.icloud-container-identifiers") ?? []
        ),
        services: SecTaskEntitlementBridge.value(forEntitlement: "com.apple.developer.icloud-services"),
        applicationIdentifier: SecTaskEntitlementBridge.stringValue(forEntitlement: "application-identifier")
            ?? SecTaskEntitlementBridge.stringValue(forEntitlement: "com.apple.application-identifier")
    )

    init(containerIdentifiers: Set<String>, services: Any?, applicationIdentifier: String?) {
        self.containerIdentifiers = containerIdentifiers
        switch services {
        case let list as [String]:
            hasCloudKitService = list.contains { $0 == "CloudKit" || $0 == "CloudKit-Anonymous" || $0 == "*" }
        case let single as String:
            hasCloudKitService = single == "*" || single == "CloudKit"
        default:
            hasCloudKitService = false
        }
        hasApplicationIdentifier = applicationIdentifier?.contains(".") == true
    }

    func allows(containerIdentifier: String) -> Bool {
        hasCloudKitService && hasApplicationIdentifier && containerIdentifiers.contains(containerIdentifier)
    }
}
