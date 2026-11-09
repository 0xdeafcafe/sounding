import Foundation
import SwiftUI

struct PromotedContent: Codable, Hashable, Sendable {
    enum Event: String, CaseIterable, Sendable {
        case impression
        case play
        case click
    }

    let adURN: String?
    let promoter: User?
    let tracking: [Event: [URL]]

    init(adURN: String?, promoter: User?, tracking: [Event: [URL]]) {
        self.adURN = adURN
        self.promoter = promoter
        self.tracking = tracking
    }

    func urls(for event: Event) -> [URL] { tracking[event] ?? [] }

    nonisolated static func event(forKey key: String) -> Event? {
        let lowered = key.lowercased()
        if lowered.contains("impression") { return .impression }
        if lowered.contains("play") { return .play }
        if lowered.contains("click") { return .click }
        return nil
    }

    struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        adURN = (try? container.decodeIfPresent(String.self, forKey: AnyKey("ad_urn")))
            ?? (try? container.decodeIfPresent(String.self, forKey: AnyKey("urn")))
            ?? nil
        promoter = (try? container.decodeIfPresent(User.self, forKey: AnyKey("promoter"))) ?? nil
        var collected: [Event: [URL]] = [:]
        func collect(_ urls: [URL], for key: String) {
            guard let event = Self.event(forKey: key) else { return }
            for url in urls where url.scheme?.lowercased() == "https" && !(collected[event]?.contains(url) ?? false) {
                collected[event, default: []].append(url)
            }
        }
        func urls(in container: KeyedDecodingContainer<AnyKey>, key: AnyKey) -> [URL] {
            if let list = try? container.decode([String].self, forKey: key) { return list.compactMap(URL.init(string:)) }
            if let single = try? container.decode(String.self, forKey: key) { return URL(string: single).map { [$0] } ?? [] }
            return []
        }
        if let nested = try? container.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("tracking")) {
            for key in nested.allKeys { collect(urls(in: nested, key: key), for: key.stringValue) }
        }
        for key in container.allKeys where key.stringValue.hasPrefix("tracking_") {
            collect(urls(in: container, key: key), for: key.stringValue)
        }
        tracking = collected
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        try container.encodeIfPresent(adURN, forKey: AnyKey("ad_urn"))
        try container.encodeIfPresent(promoter, forKey: AnyKey("promoter"))
        var nested = container.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("tracking"))
        for event in Event.allCases {
            let urls = urls(for: event)
            if !urls.isEmpty { try nested.encode(urls.map(\.absoluteString), forKey: AnyKey(event.rawValue)) }
        }
    }
}

extension PromotedContent.Event {
    var networkFeature: NetworkFeature {
        switch self {
        case .impression: return .promotedImpression
        case .play: return .promotedPlay
        case .click: return .promotedClick
        }
    }
}

protocol PromotedTrackingTransport: Sendable {
    func send(_ url: URL, event: PromotedContent.Event) async
}

struct LivePromotedTrackingTransport: PromotedTrackingTransport {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    func send(_ url: URL, event: PromotedContent.Event) async {
        _ = try? await Self.session.loggedData(from: url, feature: event.networkFeature)
    }
}

@MainActor
final class PromotedTracking {
    static let shared = PromotedTracking(
        transport: LivePromotedTrackingTransport(),
        isSuppressed: { PromotedTracking.isSuppressedEnvironment },
        trafficAllowed: { (try? SoundCloudAPI.shared.enforceTrafficSafety()) != nil }
    )

    static let maximumPerMinute = 30

    private let transport: any PromotedTrackingTransport
    private let isSuppressed: @MainActor () -> Bool
    private let trafficAllowed: @MainActor () -> Bool
    private var fired: Set<String> = []
    private var recentSends: [Date] = []

    init(
        transport: any PromotedTrackingTransport,
        isSuppressed: @escaping @MainActor () -> Bool,
        trafficAllowed: @escaping @MainActor () -> Bool
    ) {
        self.transport = transport
        self.isSuppressed = isSuppressed
        self.trafficAllowed = trafficAllowed
    }

    static var isSuppressedEnvironment: Bool {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["SOUNDING_TV_UI_FIXTURE"] != nil
            || environment["XCTestConfigurationFilePath"] != nil
            || environment.keys.contains(where: { $0.contains("SNAPSHOT") })
            || SoundCloudMockService.isEnabled {
            return true
        }
        #endif
        return !SoundCloudGateway.shared.isApplicationForeground
    }

    @discardableResult
    func record(_ event: PromotedContent.Event, for activity: FeedActivity, now: Date = Date()) -> [URL] {
        guard let promoted = activity.promoted else { return [] }
        let urls = promoted.urls(for: event)
        guard !urls.isEmpty, !isSuppressed(), trafficAllowed() else { return [] }
        let key = "\(event.rawValue)|\(activity.id)"
        guard !fired.contains(key) else { return [] }
        recentSends.removeAll { now.timeIntervalSince($0) >= 60 }
        guard recentSends.count + urls.count <= Self.maximumPerMinute else { return [] }
        fired.insert(key)
        recentSends.append(contentsOf: Array(repeating: now, count: urls.count))
        let transport = transport
        for url in urls {
            Task.detached(priority: .utility) { await transport.send(url, event: event) }
        }
        return urls
    }
}

private struct PromotedImpressionModifier: ViewModifier {
    let activity: FeedActivity
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onScrollVisibilityChange(threshold: 0.5) { isVisible in
                pending?.cancel()
                pending = nil
                guard isVisible else { return }
                pending = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    PromotedTracking.shared.record(.impression, for: activity)
                }
            }
            .onDisappear {
                pending?.cancel()
                pending = nil
            }
    }
}

extension View {
    @ViewBuilder
    func promotedImpression(_ activity: FeedActivity) -> some View {
        if activity.promoted != nil {
            modifier(PromotedImpressionModifier(activity: activity))
        } else {
            self
        }
    }
}

extension FeedActivity {
    var promotedLabel: String? {
        guard isPromoted else { return nil }
        if let name = promoted?.promoter?.displayName, !name.isEmpty { return "Promoted by \(name)" }
        return "Promoted"
    }
}
