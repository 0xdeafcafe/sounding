import CloudKit
import UIKit
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        SignInRequestAlert.apply(to: content, now: .now)
        LinkRequestAlert.apply(to: content, now: .now)
        AccountSignInAlert.apply(to: content)
        contentHandler(content)
    }
}

enum SignInRequestAlert {
    static let subscriptionIDs: Set<String> = ["signin-requests-v2", "signin-requests-v1"]
    static let category = "SIGN_IN_REQUEST"
    static let maximumNameLength = 64

    static func apply(to content: UNMutableNotificationContent, now: Date) {
        let notification = CKNotification(fromRemoteNotificationDictionary: content.userInfo)
        guard content.categoryIdentifier == category || notification?.subscriptionID.map({ subscriptionIDs.contains($0) }) == true else { return }
        let fields = (notification as? CKQueryNotification)?.recordFields ?? [:]
        let name = (fields["tvName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)) ?? ""
        if !name.isEmpty {
            let shortName = String(name.prefix(maximumNameLength))
            content.title = String(localized: "\(shortName) wants to sign in")
            content.body = String(localized: "Tap to sign it in to Sounding from here.")
        }
        content.threadIdentifier = "sign-in-requests"
        DeviceArtwork.attach(kind: fields["tvKind"] as? String, to: content)
        if let expiresAt = fields["expiresAt"] as? Date, expiresAt <= now {
            content.interruptionLevel = .passive
            content.relevanceScore = 0
        } else {
            content.interruptionLevel = .timeSensitive
            content.relevanceScore = 1
        }
    }
}

enum LinkRequestAlert {
    static let subscriptionID = "nearby-link-requests-v1"
    static let category = "LINK_REQUEST"
    static let maximumNameLength = 64

    static func apply(to content: UNMutableNotificationContent, now: Date) {
        let notification = CKNotification(fromRemoteNotificationDictionary: content.userInfo)
        guard content.categoryIdentifier == category || notification?.subscriptionID == subscriptionID else { return }
        let fields = (notification as? CKQueryNotification)?.recordFields ?? [:]
        let name = (fields["tvName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)) ?? ""
        if !name.isEmpty {
            let shortName = String(name.prefix(maximumNameLength))
            content.title = String(localized: "\(shortName) is nearby")
            content.body = String(localized: "Link it to control playback and share settings.")
        }
        content.threadIdentifier = "link-requests"
        DeviceArtwork.attach(kind: fields["tvKind"] as? String, to: content)
        if let expiresAt = fields["expiresAt"] as? Date, expiresAt <= now {
            content.interruptionLevel = .passive
            content.relevanceScore = 0
        } else {
            content.interruptionLevel = .active
            content.relevanceScore = 0.9
        }
    }
}

enum AccountSignInAlert {
    static let subscriptionIDs: Set<String> = ["account-signins-v2", "account-signins-v1"]
    static let category = "ACCOUNT_SIGN_IN"
    static let maximumNameLength = 64

    static func apply(to content: UNMutableNotificationContent) {
        let notification = CKNotification(fromRemoteNotificationDictionary: content.userInfo)
        guard content.categoryIdentifier == category || notification?.subscriptionID.map({ subscriptionIDs.contains($0) }) == true else { return }
        let fields = (notification as? CKQueryNotification)?.recordFields ?? [:]
        let name = (fields["deviceName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)) ?? ""
        if !name.isEmpty {
            let shortName = String(name.prefix(maximumNameLength))
            content.title = String(localized: "New Sign-In")
            content.body = String(localized: "Your SoundCloud account is now signed in on \(shortName).")
        }
        content.threadIdentifier = "account-sign-ins"
        content.interruptionLevel = .timeSensitive
        content.relevanceScore = 0.8
    }
}

enum DeviceArtwork {
    static let side: CGFloat = 240
    static let brand = UIColor(red: 1.00, green: 0.42, blue: 0.10, alpha: 1)

    static func symbolName(kind: String?) -> String {
        switch kind {
        case "phone": return "iphone"
        case "pad": return "ipad"
        case "mac": return "desktopcomputer"
        case "watch": return "applewatch"
        default: return "appletv.fill"
        }
    }

    static func attach(kind: String?, to content: UNMutableNotificationContent) {
        guard content.attachments.isEmpty, let url = render(symbol: symbolName(kind: kind)),
              let attachment = try? UNNotificationAttachment(identifier: "device", url: url, options: nil) else { return }
        content.attachments = [attachment]
    }

    static func render(symbol: String) -> URL? {
        let configuration = UIImage.SymbolConfiguration(pointSize: side * 0.42, weight: .semibold)
        guard let glyph = UIImage(systemName: symbol, withConfiguration: configuration)?
            .withTintColor(.white, renderingMode: .alwaysOriginal) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let size = CGSize(width: side, height: side)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            brand.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let glyphSize = glyph.size
            let origin = CGPoint(x: (side - glyphSize.width) / 2, y: (side - glyphSize.height) / 2)
            glyph.draw(in: CGRect(origin: origin, size: glyphSize))
        }
        guard let data = image.pngData() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("device-\(UUID().uuidString).png")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
