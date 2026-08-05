import Foundation
#if canImport(WebKit)
import WebKit
#endif

@MainActor
enum AuthWebSession {
    static func clear() async {
        #if canImport(WebKit)
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        let soundcloud = records.filter {
            $0.displayName.localizedCaseInsensitiveContains("soundcloud")
        }
        await store.removeData(ofTypes: types, for: soundcloud)
        #endif
    }
}
