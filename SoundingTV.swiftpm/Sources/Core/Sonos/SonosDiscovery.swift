import Foundation
import Combine
import Network

struct SonosBonjourService: Hashable, Sendable {
    let name: String
    let rinconID: String
    let host: String?
    let port: Int

    static func rinconID(serviceName: String, txt: [String: String]) -> String? {
        if let uuid = txt["uuid"], uuid.hasPrefix("RINCON_") { return uuid }
        let prefix = serviceName.split(separator: "@", maxSplits: 1).first.map(String.init) ?? serviceName
        return prefix.hasPrefix("RINCON_") ? prefix : nil
    }

    static func make(serviceName: String, txt: [String: String]) -> SonosBonjourService? {
        guard let id = rinconID(serviceName: serviceName, txt: txt) else { return nil }
        if let location = txt["location"], let url = URL(string: location), let host = url.host {
            return SonosBonjourService(name: serviceName, rinconID: id, host: host, port: url.port ?? 1400)
        }
        return SonosBonjourService(name: serviceName, rinconID: id, host: nil, port: 1400)
    }
}

@MainActor
protocol SonosServiceBrowsing: AnyObject {
    var onChange: (([SonosBonjourService]) -> Void)? { get set }
    func start()
    func cancel()
}

@MainActor
final class SonosDiscovery: ObservableObject {
    @Published private(set) var groups: [SonosGroup] = []
    @Published private(set) var isBrowsing = false

    private let transport: SonosHTTPTransport
    private let browserFactory: @MainActor () -> SonosServiceBrowsing
    private let refreshDelay: Duration
    private var browser: SonosServiceBrowsing?
    private var services: [String: SonosBonjourService] = [:]
    private var preferredHost: String?
    private var refreshTask: Task<Void, Never>?
    private var refreshPending = false
    private var debounceTask: Task<Void, Never>?
    private var modelNames: [String: String] = [:]

    init(
        transport: SonosHTTPTransport = URLSessionSonosTransport(),
        browserFactory: (@MainActor () -> SonosServiceBrowsing)? = nil,
        refreshDelay: Duration = .milliseconds(300)
    ) {
        self.transport = transport
        self.browserFactory = browserFactory ?? { NWSonosServiceBrowser() }
        self.refreshDelay = refreshDelay
    }

    var discoveredServices: [SonosBonjourService] {
        services.values.sorted { $0.rinconID < $1.rinconID }
    }

    func start() {
        guard browser == nil else { return }
        let browser = browserFactory()
        browser.onChange = { [weak self] services in
            self?.servicesChanged(services)
        }
        self.browser = browser
        isBrowsing = true
        browser.start()
    }

    func stop() {
        browser?.onChange = nil
        browser?.cancel()
        browser = nil
        debounceTask?.cancel()
        debounceTask = nil
        services = [:]
        isBrowsing = false
        groups = []
    }

    func refreshTopology() async {
        if let running = refreshTask {
            refreshPending = true
            await running.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runRefreshLoop()
        }
        refreshTask = task
        await task.value
    }

    private func servicesChanged(_ list: [SonosBonjourService]) {
        var next: [String: SonosBonjourService] = [:]
        for service in list {
            if let existing = next[service.rinconID], existing.host != nil, service.host == nil { continue }
            next[service.rinconID] = service
        }
        guard next != services else { return }
        services = next
        if next.isEmpty {
            groups = []
            return
        }
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        debounceTask?.cancel()
        let delay = refreshDelay
        debounceTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            await self?.refreshTopology()
        }
    }

    private func runRefreshLoop() async {
        repeat {
            refreshPending = false
            await fetchTopologyOnce()
        } while refreshPending
        refreshTask = nil
    }

    private func candidateEndpoints() -> [(String, Int)] {
        var seen = Set<String>()
        var result: [(String, Int)] = []
        func add(_ host: String?, _ port: Int) {
            guard let host, seen.insert("\(host):\(port)").inserted else { return }
            result.append((host, port))
        }
        if let preferredHost {
            let port = services.values.first { $0.host == preferredHost }?.port
                ?? groups.flatMap(\.allPlayers).first { $0.host == preferredHost }?.port
                ?? 1400
            add(preferredHost, port)
        }
        for service in discoveredServices { add(service.host, service.port) }
        for group in groups {
            add(group.coordinator.host, group.coordinator.port)
            for member in group.members { add(member.host, member.port) }
        }
        return result
    }

    private func fetchTopologyOnce() async {
        for (host, port) in candidateEndpoints() {
            let client = SonosClient(host: host, port: port, transport: transport)
            guard let fetched = try? await client.zoneGroupState() else { continue }
            preferredHost = host
            groups = applyingModelNames(fetched)
            await loadModelNames(for: fetched)
            return
        }
        if services.isEmpty { groups = [] }
    }

    private func loadModelNames(for fetched: [SonosGroup]) async {
        let missing = fetched.flatMap(\.members).filter { modelNames[$0.id] == nil }
        guard !missing.isEmpty else { return }
        let transport = self.transport
        let loaded = await withTaskGroup(of: (String, String?).self) { group in
            for player in missing {
                group.addTask {
                    let client = SonosClient(player: player, transport: transport)
                    let name = try? await client.modelName()
                    return (player.id, name ?? nil)
                }
            }
            var result: [String: String] = [:]
            for await (id, name) in group {
                if let name { result[id] = name }
            }
            return result
        }
        guard !loaded.isEmpty else { return }
        modelNames.merge(loaded) { _, new in new }
        groups = applyingModelNames(groups)
    }

    private func applyingModelNames(_ groups: [SonosGroup]) -> [SonosGroup] {
        let names = modelNames
        return groups.map { group in
            func named(_ player: SonosPlayer) -> SonosPlayer {
                player.withModelName(names[player.id] ?? player.modelName)
            }
            var updated = SonosGroup(
                id: group.id,
                coordinator: named(group.coordinator),
                members: group.members.map(named),
                displayName: group.displayName
            )
            updated.satellites = group.satellites
            return updated
        }
    }
}

@MainActor
final class NWSonosServiceBrowser: SonosServiceBrowsing {
    var onChange: (([SonosBonjourService]) -> Void)?
    private var browser: NWBrowser?
    private var latest: [String: SonosBonjourService] = [:]
    private var resolved: [String: String] = [:]
    private var resolving: [String: NWConnection] = [:]

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_sonos._tcp", domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                self?.handle(results)
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            guard case .failed = state else { return }
            MainActor.assumeIsolated {
                self?.restart()
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    func cancel() {
        browser?.cancel()
        browser = nil
        for connection in resolving.values { connection.cancel() }
        resolving = [:]
        latest = [:]
    }

    private func restart() {
        browser?.cancel()
        browser = nil
        start()
    }

    private func handle(_ results: Set<NWBrowser.Result>) {
        var next: [String: SonosBonjourService] = [:]
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            var txt: [String: String] = [:]
            if case let .bonjour(record) = result.metadata {
                txt = record.dictionary
            }
            guard var service = SonosBonjourService.make(serviceName: name, txt: txt) else { continue }
            if service.host == nil {
                if let host = resolved[service.rinconID] {
                    service = SonosBonjourService(name: name, rinconID: service.rinconID, host: host, port: 1400)
                } else {
                    resolve(result.endpoint, id: service.rinconID)
                }
            }
            if let existing = next[service.rinconID], existing.host != nil, service.host == nil { continue }
            next[service.rinconID] = service
        }
        latest = next
        onChange?(Array(next.values))
    }

    private func resolve(_ endpoint: NWEndpoint, id: String) {
        guard resolving[id] == nil else { return }
        let connection = NWConnection(to: endpoint, using: .tcp)
        resolving[id] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .ready:
                let remote = connection?.currentPath?.remoteEndpoint
                MainActor.assumeIsolated {
                    self?.finishResolving(id: id, remote: remote)
                }
            case .failed, .cancelled:
                MainActor.assumeIsolated {
                    self?.finishResolving(id: id, remote: nil)
                }
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    private func finishResolving(id: String, remote: NWEndpoint?) {
        guard let connection = resolving.removeValue(forKey: id) else { return }
        connection.cancel()
        guard case let .hostPort(host, _) = remote, let address = Self.address(host) else { return }
        resolved[id] = address
        guard let service = latest[id], service.host == nil else { return }
        latest[id] = SonosBonjourService(name: service.name, rinconID: id, host: address, port: 1400)
        onChange?(Array(latest.values))
    }

    private static func address(_ host: NWEndpoint.Host) -> String? {
        switch host {
        case let .ipv4(address):
            return "\(address)".split(separator: "%").first.map(String.init)
        case let .ipv6(address):
            return "\(address)"
        case let .name(name, _):
            return name
        @unknown default:
            return nil
        }
    }
}
