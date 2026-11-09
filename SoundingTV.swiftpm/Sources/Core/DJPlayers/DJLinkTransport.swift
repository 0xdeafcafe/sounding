#if os(macOS) || DEBUG
import Foundation
import Darwin
#if os(macOS)
import SystemConfiguration
#endif

struct DJLinkInterface: Hashable, Identifiable, Sendable {
    var bsdName: String
    var displayName: String
    var index: UInt32
    var ip: DJLinkIPv4
    var netmask: DJLinkIPv4
    var broadcast: DJLinkIPv4
    var mac: DJLinkMAC

    var id: String { bsdName }
    var isLinkLocal: Bool { ip.isLinkLocal }
    var isWireless: Bool { displayName.localizedCaseInsensitiveContains("Wi-Fi") }

    static func available() -> [DJLinkInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var macs: [String: DJLinkMAC] = [:]
        var found: [DJLinkInterface] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            let flags = Int32(entry.pointee.ifa_flags)
            if Int32(address.pointee.sa_family) == AF_LINK {
                macs[name] = linkAddress(address)
                continue
            }
            guard Int32(address.pointee.sa_family) == AF_INET,
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                  flags & IFF_LOOPBACK == 0, flags & IFF_BROADCAST != 0 else { continue }
            let ip = ipv4(address)
            let mask = entry.pointee.ifa_netmask.map(ipv4) ?? DJLinkIPv4(255, 255, 0, 0)
            let broadcast = entry.pointee.ifa_dstaddr.map(ipv4) ?? DJLinkIPv4(raw: ip.raw | ~mask.raw)
            found.append(DJLinkInterface(
                bsdName: name,
                displayName: name,
                index: if_nametoindex(entry.pointee.ifa_name),
                ip: ip,
                netmask: mask,
                broadcast: broadcast == .zero ? DJLinkIPv4(raw: ip.raw | ~mask.raw) : broadcast,
                mac: .zero
            ))
        }

        let names = displayNames()
        return found.map { interface in
            var copy = interface
            copy.mac = macs[interface.bsdName] ?? .zero
            copy.displayName = names[interface.bsdName] ?? interface.bsdName
            return copy
        }
        .sorted { lhs, rhs in
            if lhs.isLinkLocal != rhs.isLinkLocal { return lhs.isLinkLocal }
            if lhs.isWireless != rhs.isWireless { return !lhs.isWireless }
            return lhs.bsdName.localizedStandardCompare(rhs.bsdName) == .orderedAscending
        }
    }

    static func preferred(from interfaces: [DJLinkInterface]) -> DJLinkInterface? {
        interfaces.first
    }

    private static func ipv4(_ address: UnsafeMutablePointer<sockaddr>) -> DJLinkIPv4 {
        address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            DJLinkIPv4(raw: UInt32(bigEndian: $0.pointee.sin_addr.s_addr))
        }
    }

    private static func linkAddress(_ address: UnsafeMutablePointer<sockaddr>) -> DJLinkMAC? {
        address.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { pointer -> DJLinkMAC? in
            let length = Int(pointer.pointee.sdl_alen)
            guard length == 6, let dataOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data) else { return nil }
            let start = dataOffset + Int(pointer.pointee.sdl_nlen)
            let raw = UnsafeRawPointer(pointer)
            let bytes = (0..<length).map { raw.load(fromByteOffset: start + $0, as: UInt8.self) }
            return DJLinkMAC(bytes)
        }
    }

    private static func displayNames() -> [String: String] {
        #if os(macOS)
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var names: [String: String] = [:]
        for interface in all {
            guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let display = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? else { continue }
            names[bsd] = display
        }
        return names
        #else
        return [:]
        #endif
    }
}

struct DJLinkPortMap: Sendable {
    var local: [UInt16: UInt16]
    var remote: [UInt16: UInt16]

    static let logicalPorts: [UInt16] = [DJLinkPort.announce, DJLinkPort.beat, DJLinkPort.status]

    static let standard = DJLinkPortMap(
        local: Dictionary(uniqueKeysWithValues: logicalPorts.map { ($0, $0) }),
        remote: Dictionary(uniqueKeysWithValues: logicalPorts.map { ($0, $0) })
    )

    static func offset(local localBase: UInt16, remote remoteBase: UInt16) -> DJLinkPortMap {
        DJLinkPortMap(
            local: Dictionary(uniqueKeysWithValues: logicalPorts.enumerated().map { ($0.element, localBase + UInt16($0.offset)) }),
            remote: Dictionary(uniqueKeysWithValues: logicalPorts.enumerated().map { ($0.element, remoteBase + UInt16($0.offset)) })
        )
    }
}

enum DJLinkTransportError: Error, Equatable {
    case socket(Int32)
    case bind(port: UInt16, code: Int32)
}

protocol DJLinkTransport: AnyObject, Sendable {
    func open(on queue: DispatchQueue, receive: @escaping @Sendable (Data, DJLinkIPv4, UInt16) -> Void) throws
    func send(_ data: Data, to destination: DJLinkDestination) -> Int32
    func close()
}

final class DJLinkSocketTransport: DJLinkTransport, @unchecked Sendable {
    let interfaceIndex: UInt32?
    let broadcastAddress: DJLinkIPv4
    let ports: DJLinkPortMap
    private var sockets: [UInt16: Int32] = [:]
    private var sources: [DispatchSourceRead] = []

    init(interfaceIndex: UInt32?, broadcastAddress: DJLinkIPv4, ports: DJLinkPortMap = .standard) {
        self.interfaceIndex = interfaceIndex
        self.broadcastAddress = broadcastAddress
        self.ports = ports
    }

    convenience init(interface: DJLinkInterface) {
        self.init(interfaceIndex: interface.index, broadcastAddress: interface.broadcast)
    }

    deinit {
        for source in sources { source.cancel() }
    }

    func open(on queue: DispatchQueue, receive: @escaping @Sendable (Data, DJLinkIPv4, UInt16) -> Void) throws {
        close()
        do {
            for logical in DJLinkPortMap.logicalPorts {
                let bindPort = ports.local[logical] ?? logical
                let fd = try Self.makeSocket(port: bindPort, interfaceIndex: interfaceIndex, reusable: true)
                sockets[logical] = fd
                let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                source.setEventHandler {
                    Self.drain(fd: fd, logicalPort: logical, receive: receive)
                }
                source.setCancelHandler {
                    Darwin.close(fd)
                }
                sources.append(source)
                source.resume()
            }
        } catch {
            close()
            throw error
        }
    }

    func send(_ data: Data, to destination: DJLinkDestination) -> Int32 {
        let logical = destination.port
        guard let fd = sockets[logical] ?? sockets.values.first else { return EBADF }
        let target: DJLinkIPv4
        switch destination {
        case .broadcast: target = broadcastAddress
        case .unicast(let ip, _): target = ip
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = (ports.remote[logical] ?? logical).bigEndian
        address.sin_addr = in_addr(s_addr: target.raw.bigEndian)
        let sent = data.withUnsafeBytes { buffer in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent < 0 ? errno : 0
    }

    func close() {
        for source in sources { source.cancel() }
        sources.removeAll()
        sockets.removeAll()
    }

    static func conflictingPorts(_ ports: [UInt16] = DJLinkPortMap.logicalPorts) -> [UInt16] {
        ports.filter { port in
            do {
                let fd = try makeSocket(port: port, interfaceIndex: nil, reusable: false)
                Darwin.close(fd)
                return false
            } catch DJLinkTransportError.bind(_, let code) {
                return code == EADDRINUSE
            } catch {
                return false
            }
        }
    }

    private static func makeSocket(port: UInt16, interfaceIndex: UInt32?, reusable: Bool) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw DJLinkTransportError.socket(errno) }
        var on: Int32 = 1
        let size = socklen_t(MemoryLayout<Int32>.size)
        if reusable {
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, size)
            setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, size)
        }
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, size)
        if var index = interfaceIndex, index != 0 {
            setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw DJLinkTransportError.bind(port: port, code: code)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }

    private static func drain(fd: Int32, logicalPort: UInt16, receive: (Data, DJLinkIPv4, UInt16) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 2048)
        for _ in 0..<64 {
            var source = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &source) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, bytes.baseAddress, bytes.count, 0, $0, &length)
                    }
                }
            }
            guard count > 0 else { return }
            let sender = DJLinkIPv4(raw: UInt32(bigEndian: source.sin_addr.s_addr))
            receive(Data(buffer[0..<count]), sender, logicalPort)
        }
    }
}

final class DJLinkRuntime: @unchecked Sendable {
    let queue: DispatchQueue
    private let transport: any DJLinkTransport
    private let engine: DJLinkEngine
    private let clock: @Sendable () -> TimeInterval
    private let publishInterval: TimeInterval
    private var timer: DispatchSourceTimer?
    private var running = false
    private var lastPublished: DJPlayersSnapshot?
    private var lastPublishAt: TimeInterval = -.infinity
    private var reportedFailure: Int32?

    var onSnapshot: (@Sendable (DJPlayersSnapshot) -> Void)?
    var onEvent: (@Sendable (DJLinkEngineEvent) -> Void)?
    var onSendResult: (@Sendable (Int32) -> Void)?

    init(
        transport: any DJLinkTransport,
        engine: DJLinkEngine,
        queue: DispatchQueue = DispatchQueue(label: "red.forbes.sounding.djplayers", qos: .userInitiated),
        publishInterval: TimeInterval = 0.25,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.transport = transport
        self.engine = engine
        self.queue = queue
        self.publishInterval = publishInterval
        self.clock = clock
    }

    func start() throws {
        try queue.sync {
            try transport.open(on: queue) { [weak self] data, address, port in
                guard let self else { return }
                let now = self.clock()
                self.engine.receive(data, from: address, port: port, now: now)
                self.pump(now: now)
            }
            running = true
            reportedFailure = nil
            engine.start(now: clock())
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.pump(now: self.clock())
            }
            self.timer = timer
            timer.resume()
            pump(now: clock())
        }
    }

    func stop() {
        queue.sync {
            running = false
            timer?.cancel()
            timer = nil
            engine.stop()
            transport.close()
            lastPublished = nil
        }
        queue.sync {}
    }

    func setDeck(_ snapshot: DJVirtualDeckSnapshot) {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            let now = self.clock()
            self.engine.setDeck(snapshot, now: now)
            self.pump(now: now)
        }
    }

    func requestMaster() {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            let now = self.clock()
            self.engine.requestMaster(now: now)
            self.pump(now: now)
        }
    }

    func setSynced(_ synced: Bool) {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.engine.setSynced(synced)
            self.pump(now: self.clock())
        }
    }

    private func pump(now: TimeInterval) {
        guard running else { return }
        engine.tick(now: now)
        for outbound in engine.drainOutbox() {
            let result = transport.send(outbound.packet.encode(), to: outbound.destination)
            if result != reportedFailure {
                reportedFailure = result
                onSendResult?(result)
            }
        }
        for event in engine.drainEvents() { onEvent?(event) }

        let snapshot = engine.snapshot(now: now)
        var deadline = engine.nextDeadline(after: now) ?? now + 1
        if snapshot != lastPublished {
            let structural = snapshot.phase != lastPublished?.phase
                || snapshot.players.map(\.number) != lastPublished?.players.map(\.number)
                || snapshot.isVirtualDeckMaster != lastPublished?.isVirtualDeckMaster
            if structural || now - lastPublishAt >= publishInterval {
                lastPublished = snapshot
                lastPublishAt = now
                onSnapshot?(snapshot)
            } else {
                deadline = min(deadline, lastPublishAt + publishInterval)
            }
        }
        let delay = max(0.001, deadline - now)
        timer?.schedule(deadline: .now() + delay, leeway: .milliseconds(1))
    }
}
#endif
