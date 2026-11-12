import Foundation
import Security
import XCTest
@testable import SoundingTV

final class BuildFlavorTests: XCTestCase {
    private let keychainServices = [
        "red.forbes.sounding.keychain",
        "red.forbes.sounding.phone",
        "red.forbes.sounding.devcredential",
        "red.forbes.sounding.account-data-vault",
        "red.forbes.sounding.download-vault",
        "red.forbes.sounding.pairing-offer",
    ]

    func testDebugBuildsResolveToDebugFlavor() {
        XCTAssertEqual(BuildFlavor.current, .debug)
        XCTAssertTrue(UserDefaults.sounding !== UserDefaults.standard)
    }

    func testReleaseKeepsTodaysKeychainNames() {
        for service in keychainServices {
            XCTAssertEqual(BuildFlavor.release.keychainService(service), service)
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: "account",
            ]
            let rewritten = BuildFlavor.release.keychainQuery(query)
            XCTAssertEqual(rewritten[kSecAttrService as String] as? String, service)
            XCTAssertEqual(rewritten.count, query.count)
        }
    }

    func testDebugKeychainNamesDifferAndNeverSync() {
        for service in keychainServices {
            let debug = BuildFlavor.debug.keychainService(service)
            XCTAssertNotEqual(debug, service)
            XCTAssertFalse(keychainServices.contains(debug))
            let query: [String: Any] = [
                kSecAttrService as String: service,
                kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
            ]
            let rewritten = BuildFlavor.debug.keychainQuery(query)
            XCTAssertEqual(rewritten[kSecAttrService as String] as? String, debug)
            XCTAssertNil(rewritten[kSecAttrSynchronizable as String])
        }
    }

    func testReleaseKeepsTodaysDefaultsAndFiles() {
        XCTAssertNil(BuildFlavor.release.defaultsSuiteName)
        XCTAssertNil(BuildFlavor.release.directoryName)
        let base = URL(fileURLWithPath: "/tmp/Application Support", isDirectory: true)
        XCTAssertEqual(BuildFlavor.release.directory(in: base), base)
    }

    func testDebugDefaultsAndFilesAreSeparate() throws {
        let suite = try XCTUnwrap(BuildFlavor.debug.defaultsSuiteName)
        XCTAssertNotEqual(suite, Bundle.main.bundleIdentifier)
        XCTAssertFalse(suite.hasPrefix("group."))
        let base = URL(fileURLWithPath: "/tmp/Application Support", isDirectory: true)
        XCTAssertNotEqual(BuildFlavor.debug.directory(in: base), base)
        XCTAssertEqual(BuildFlavor.debug.directory(in: base).deletingLastPathComponent().standardizedFileURL, base.standardizedFileURL)
    }

    func testReleaseKeepsTodaysNetworkAndSystemIdentifiers() {
        XCTAssertEqual(BuildFlavor.release.bonjourServiceType, "_soundingtv._tcp")
        XCTAssertEqual(BuildFlavor.release.bonjourServiceType, BonjourConstants.serviceType)
        XCTAssertEqual(BuildFlavor.release.identifier("red.forbes.sounding.downloads"), "red.forbes.sounding.downloads")
        XCTAssertEqual(SoundingAppGroup.identifier, "group.red.forbes.sounding")
    }

    func testDebugNetworkAndSystemIdentifiersDiffer() {
        XCTAssertNotEqual(BuildFlavor.debug.bonjourServiceType, BuildFlavor.release.bonjourServiceType)
        XCTAssertTrue(BuildFlavor.debug.bonjourServiceType.hasSuffix("._tcp"))
        let name = BuildFlavor.debug.bonjourServiceType.dropFirst().split(separator: ".").first ?? ""
        XCTAssertLessThanOrEqual(name.count, 15)
        XCTAssertNotEqual(BuildFlavor.debug.identifier("red.forbes.sounding.downloads"), "red.forbes.sounding.downloads")
        XCTAssertEqual(DownloadManager.backgroundSessionIdentifier, BuildFlavor.current.identifier("red.forbes.sounding.downloads"))
    }

    func testDevelopmentProfilesAreDetected() {
        XCTAssertTrue(BuildFlavor.isDevelopmentProfile(profile(["get-task-allow": true])))
        XCTAssertFalse(BuildFlavor.isDevelopmentProfile(profile(["get-task-allow": false])))
        XCTAssertFalse(BuildFlavor.isDevelopmentProfile(profile(["com.apple.developer.icloud-container-environment": "Production"])))
        XCTAssertTrue(BuildFlavor.isDevelopmentProfile(profile(["com.apple.developer.icloud-container-environment": "Development", "get-task-allow": false])))
        XCTAssertFalse(BuildFlavor.isDevelopmentProfile(Data()))
    }

    private func profile(_ entitlements: [String: Any]) -> Data {
        let plist = try? PropertyListSerialization.data(
            fromPropertyList: ["Entitlements": entitlements], format: .xml, options: 0
        )
        var data = Data([0x30, 0x80, 0x06, 0x09])
        data.append(plist ?? Data())
        data.append(contentsOf: [0x00, 0x00])
        return data
    }
}
