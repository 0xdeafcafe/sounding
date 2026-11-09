import Foundation

actor SonosClient {
    nonisolated let host: String
    nonisolated let port: Int
    private let transport: SonosHTTPTransport

    init(host: String, port: Int = 1400, transport: SonosHTTPTransport = URLSessionSonosTransport()) {
        self.host = host
        self.port = port
        self.transport = transport
    }

    init(player: SonosPlayer, transport: SonosHTTPTransport = URLSessionSonosTransport()) {
        self.init(host: player.host, port: player.port, transport: transport)
    }

    nonisolated var baseURL: URL {
        let hostPart = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return URL(string: "http://\(hostPart):\(port)")!
    }

    func zoneGroupState() async throws -> [SonosGroup] {
        let values = try await call(.zoneGroupTopology, "GetZoneGroupState", [])
        guard let state = values["ZoneGroupState"], !state.isEmpty else {
            throw SonosResponseError.malformed("Empty ZoneGroupState")
        }
        return try SonosTopology.parseZoneGroupState(state)
    }

    func modelName() async throws -> String? {
        let (status, data) = try await transport.get(url: baseURL.appendingPathComponent("xml/device_description.xml"))
        guard status == 200 else { throw SonosSOAPError(httpStatus: status, upnpErrorCode: nil) }
        return SonosTopology.modelName(fromDeviceDescription: data)
    }

    func volume() async throws -> Int {
        let values = try await call(.renderingControl, "GetVolume", [("InstanceID", "0"), ("Channel", "Master")])
        return try integer(values, "CurrentVolume")
    }

    func setVolume(_ v: Int) async throws {
        _ = try await call(.renderingControl, "SetVolume", [("InstanceID", "0"), ("Channel", "Master"), ("DesiredVolume", String(Self.clampVolume(v)))])
    }

    func isMuted() async throws -> Bool {
        let values = try await call(.renderingControl, "GetMute", [("InstanceID", "0"), ("Channel", "Master")])
        return try integer(values, "CurrentMute") != 0
    }

    func setMuted(_ m: Bool) async throws {
        _ = try await call(.renderingControl, "SetMute", [("InstanceID", "0"), ("Channel", "Master"), ("DesiredMute", m ? "1" : "0")])
    }

    func groupVolume() async throws -> Int {
        let values = try await call(.groupRenderingControl, "GetGroupVolume", [("InstanceID", "0")])
        return try integer(values, "CurrentVolume")
    }

    func setGroupVolume(_ v: Int) async throws {
        _ = try await call(.groupRenderingControl, "SnapshotGroupVolume", [("InstanceID", "0")])
        _ = try await call(.groupRenderingControl, "SetGroupVolume", [("InstanceID", "0"), ("DesiredVolume", String(Self.clampVolume(v)))])
    }

    func groupMuted() async throws -> Bool {
        let values = try await call(.groupRenderingControl, "GetGroupMute", [("InstanceID", "0")])
        return try integer(values, "CurrentMute") != 0
    }

    func setGroupMuted(_ m: Bool) async throws {
        _ = try await call(.groupRenderingControl, "SetGroupMute", [("InstanceID", "0"), ("DesiredMute", m ? "1" : "0")])
    }

    func transportState() async throws -> SonosTransportState {
        let values = try await call(.avTransport, "GetTransportInfo", [("InstanceID", "0")])
        guard let raw = values["CurrentTransportState"], let state = SonosTransportState(rawValue: raw) else {
            throw SonosResponseError.malformed("Unknown transport state")
        }
        return state
    }

    func nowPlaying() async throws -> SonosNowPlaying {
        let values = try await call(.avTransport, "GetPositionInfo", [("InstanceID", "0")])
        var result = SonosDIDL.nowPlaying(fromMetadata: values["TrackMetaData"], baseURL: baseURL)
        if let uri = values["TrackURI"], !uri.isEmpty { result.trackURI = uri }
        result.position = SonosSOAP.timeInterval(values["RelTime"])
        if let duration = SonosSOAP.timeInterval(values["TrackDuration"]), duration > 0 {
            result.duration = duration
        }
        if result.title == nil, result.trackURI != nil {
            let media = try? await call(.avTransport, "GetMediaInfo", [("InstanceID", "0")])
            let fallback = SonosDIDL.nowPlaying(fromMetadata: media?["CurrentURIMetaData"], baseURL: baseURL)
            result.title = fallback.title
            result.artist = result.artist ?? fallback.artist
            result.album = result.album ?? fallback.album
            result.artworkURL = result.artworkURL ?? fallback.artworkURL
        }
        return result
    }

    func currentURI() async throws -> String? {
        let values = try await call(.avTransport, "GetMediaInfo", [("InstanceID", "0")])
        guard let uri = values["CurrentURI"], !uri.isEmpty else { return nil }
        return uri
    }

    func setAVTransportURI(_ uri: String, metadata: String) async throws {
        _ = try await call(.avTransport, "SetAVTransportURI", [("InstanceID", "0"), ("CurrentURI", uri), ("CurrentURIMetaData", metadata)])
    }

    func play() async throws {
        _ = try await call(.avTransport, "Play", [("InstanceID", "0"), ("Speed", "1")])
    }

    func pause() async throws {
        _ = try await call(.avTransport, "Pause", [("InstanceID", "0")])
    }

    func stop() async throws {
        _ = try await call(.avTransport, "Stop", [("InstanceID", "0")])
    }

    func seek(to position: TimeInterval) async throws {
        _ = try await call(.avTransport, "Seek", [("InstanceID", "0"), ("Unit", "REL_TIME"), ("Target", SonosSOAP.timeString(position))])
    }

    func join(coordinatorID: String) async throws {
        try await setAVTransportURI("x-rincon:\(coordinatorID)", metadata: "")
    }

    func leaveGroup() async throws {
        _ = try await call(.avTransport, "BecomeCoordinatorOfStandaloneGroup", [("InstanceID", "0")])
    }

    private func call(_ service: SonosService, _ action: String, _ arguments: [(String, String)]) async throws -> [String: String] {
        let body = SonosSOAP.envelope(service: service, action: action, arguments: arguments)
        let url = baseURL.appendingPathComponent(String(service.controlPath.dropFirst()))
        let (status, data) = try await transport.post(url: url, soapAction: service.soapAction(action), body: Data(body.utf8))
        guard status == 200 else {
            throw SonosSOAPError(httpStatus: status, upnpErrorCode: SonosSOAP.upnpErrorCode(data))
        }
        return try SonosSOAP.responseValues(data, action: action)
    }

    private func integer(_ values: [String: String], _ key: String) throws -> Int {
        guard let text = values[key]?.trimmingCharacters(in: .whitespacesAndNewlines), let value = Int(text) else {
            throw SonosResponseError.malformed("Missing \(key)")
        }
        return value
    }

    private static func clampVolume(_ volume: Int) -> Int {
        min(100, max(0, volume))
    }
}
