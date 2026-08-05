import Foundation
import Darwin

enum SecTaskEntitlementBridge {
    private typealias CreateFromSelfFn = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias CopyValueForEntitlementFn = @convention(c) (
        CFTypeRef, CFString, UnsafeMutablePointer<Unmanaged<CFError>?>?
    ) -> Unmanaged<CFTypeRef>?

    static func stringArrayValue(forEntitlement entitlement: String) -> [String]? {
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
        let value = valueUnmanaged.takeRetainedValue()
        return value as? [String]
    }
}
