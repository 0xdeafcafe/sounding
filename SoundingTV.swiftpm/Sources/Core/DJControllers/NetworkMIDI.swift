#if os(macOS) || os(iOS)
import Combine
import CoreMIDI
import Foundation
import Network

struct NetworkMIDIHost: Identifiable, Hashable, Sendable {
    var name: String
    var domain: String
    var isConnected = false

    var id: String { name }
}

@MainActor
final class NetworkMIDI: ObservableObject {
    static let shared = NetworkMIDI()
    static let enabledKey = "djControllers.networkMIDI"
    static let serviceType = "_apple-midi._udp"

    #if os(iOS)
    static let managesSession = true
    #else
    static let managesSession = false
    #endif

    @Published private(set) var isEnabled = false
    @Published private(set) var hosts: [NetworkMIDIHost] = []
    @Published private(set) var connectedNames: [String] = []

    private var browser: NWBrowser?
    private var discovered: [String: String] = [:]
    private var sessionObserver: NSObjectProtocol?

    private init() {}

    func restore() {
        guard Self.managesSession, UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
        setEnabled(true)
    }

    func setEnabled(_ enabled: Bool) {
        guard Self.managesSession else { return }
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        let session = MIDINetworkSession.default()
        if enabled {
            session.isEnabled = true
            session.connectionPolicy = .anyone
            observeSession()
            startBrowsing()
        } else {
            for connection in session.connections() {
                session.removeConnection(connection)
            }
            session.isEnabled = false
            stopBrowsing()
            if let sessionObserver { NotificationCenter.default.removeObserver(sessionObserver) }
            sessionObserver = nil
        }
        isEnabled = enabled
        refresh()
    }

    func connect(_ host: NetworkMIDIHost) {
        guard Self.managesSession, isEnabled else { return }
        let session = MIDINetworkSession.default()
        guard !session.connections().contains(where: { $0.host.name == host.name }) else { return }
        let target = MIDINetworkHost(name: host.name, netServiceName: host.name, netServiceDomain: host.domain)
        _ = session.addConnection(MIDINetworkConnection(host: target))
        refresh()
    }

    func disconnect(_ host: NetworkMIDIHost) {
        guard Self.managesSession else { return }
        let session = MIDINetworkSession.default()
        for connection in session.connections() where connection.host.name == host.name {
            session.removeConnection(connection)
        }
        refresh()
    }

    func isSessionEndpoint(_ endpoint: MIDIEndpointRef) -> Bool {
        guard Self.managesSession, isEnabled else { return false }
        let session = MIDINetworkSession.default()
        return endpoint == session.sourceEndpoint() || endpoint == session.destinationEndpoint()
    }

    nonisolated static func isNetworkEndpoint(_ endpoint: MIDIEndpointRef) -> Bool {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDriverOwner, &value) == noErr, let value else { return false }
        let owner = value.takeRetainedValue() as String
        return owner.localizedCaseInsensitiveContains("RTP") || owner.localizedCaseInsensitiveContains("Network")
    }

    // MARK: Browsing

    private func startBrowsing() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: NWParameters())
        browser.browseResultsChangedHandler = Self.makeResultsHandler()
        browser.start(queue: .global(qos: .utility))
        self.browser = browser
    }

    private func stopBrowsing() {
        browser?.cancel()
        browser = nil
        discovered = [:]
    }

    private nonisolated static func makeResultsHandler() -> @Sendable (Set<NWBrowser.Result>, Set<NWBrowser.Result.Change>) -> Void {
        { results, _ in
            var found: [String: String] = [:]
            for result in results {
                if case .service(let name, _, let domain, _) = result.endpoint {
                    found[name] = domain
                }
            }
            Task { @MainActor in
                NetworkMIDI.shared.update(found)
            }
        }
    }

    private nonisolated static func makeSessionObserver() -> @Sendable (Notification) -> Void {
        { _ in
            Task { @MainActor in
                NetworkMIDI.shared.refresh()
            }
        }
    }

    private func observeSession() {
        guard sessionObserver == nil else { return }
        sessionObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(MIDINetworkNotificationSessionDidChange),
            object: nil,
            queue: nil,
            using: Self.makeSessionObserver()
        )
    }

    private func update(_ found: [String: String]) {
        guard isEnabled else { return }
        discovered = found
        refresh()
    }

    private func refresh() {
        guard Self.managesSession, isEnabled else {
            hosts = []
            connectedNames = []
            return
        }
        let session = MIDINetworkSession.default()
        let own = [session.networkName, session.localName]
        let connected = session.connections().map(\.host.name)
        var next: [String: NetworkMIDIHost] = [:]
        for (name, domain) in discovered where !own.contains(name) {
            next[name] = NetworkMIDIHost(name: name, domain: domain, isConnected: connected.contains(name))
        }
        for name in connected where next[name] == nil {
            next[name] = NetworkMIDIHost(name: name, domain: "local.", isConnected: true)
        }
        let sorted = next.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if sorted != hosts { hosts = sorted }
        let names = connected.sorted()
        if names != connectedNames { connectedNames = names }
    }
}
#endif
