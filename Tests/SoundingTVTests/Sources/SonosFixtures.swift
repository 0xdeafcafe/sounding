import Foundation
@testable import SoundingTV

enum SonosFixtures {
    static func xmlEscaped(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func envelope(_ inner: String) -> String {
        "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body>\(inner)</s:Body></s:Envelope>"
    }

    static func response(service: String, action: String, _ values: String = "") -> String {
        envelope("<u:\(action)Response xmlns:u=\"urn:schemas-upnp-org:service:\(service):1\">\(values)</u:\(action)Response>")
    }

    static func zoneGroupStateResponse(_ state: String) -> String {
        response(service: "ZoneGroupTopology", action: "GetZoneGroupState", "<ZoneGroupState>\(xmlEscaped(state))</ZoneGroupState>")
    }

    static let singleRoom = """
    <ZoneGroupState><ZoneGroups><ZoneGroup Coordinator="RINCON_000000000D0E01400" ID="RINCON_000000000D0E01400:1000000001"><ZoneGroupMember UUID="RINCON_000000000D0E01400" Location="http://192.0.2.49:1400/xml/device_description.xml" ZoneName="Den" Icon="" Configuration="1" SoftwareVersion="97.2-81220" SWGen="2" MinCompatibleVersion="96.0-00000" LegacyCompatibleVersion="58.0-00000" BootSeq="112" TVConfigurationError="0" HdmiCecAvailable="0" WirelessMode="1" ConnectionType="5" ChannelFreq="2412" BehindWifiExtender="0" WifiEnabled="1" EthLink="0" Orientation="0" RoomCalibrationState="4" SecureRegState="3" VoiceConfigState="0" MicEnabled="1" AirPlayEnabled="1" IdleState="1" MoreInfo="" SSLPort="1443" HHSSLPort="1843"/></ZoneGroup></ZoneGroups><VanishedDevices></VanishedDevices></ZoneGroupState>
    """

    static let bondedSoundbarAndDen = """
    <ZoneGroupState><ZoneGroups><ZoneGroup Coordinator="RINCON_000000000D0E01400" ID="RINCON_000000000D0E01400:1000000001"><ZoneGroupMember UUID="RINCON_000000000D0E01400" Location="http://192.0.2.49:1400/xml/device_description.xml" ZoneName="Den" Icon="" Configuration="1" SoftwareVersion="97.2-81220" SWGen="2" MinCompatibleVersion="96.0-00000" LegacyCompatibleVersion="58.0-00000" BootSeq="112" WirelessMode="1" ConnectionType="5" SSLPort="1443" HHSSLPort="1843"/></ZoneGroup><ZoneGroup Coordinator="RINCON_00000000BEA801400" ID="RINCON_00000000BEA801400:2000000002"><ZoneGroupMember UUID="RINCON_00000000BEA801400" Location="http://192.0.2.64:1400/xml/device_description.xml" ZoneName="Soundbar" Icon="" Configuration="1" SoftwareVersion="97.2-81220" SWGen="2" MinCompatibleVersion="96.0-00000" LegacyCompatibleVersion="58.0-00000" HTSatChanMapSet="RINCON_00000000BEA801400:LF,RF;RINCON_00000000005B01400:SW;RINCON_0000000000A101400:LR,LTR;RINCON_0000000000A201400:RR,RTR" ActiveZoneID="00000000-0000-4000-8000-000000000001" BootSeq="80" HTFreq="2412" HTBondedState="1" SSLPort="1443" HHSSLPort="1843"><Satellite UUID="RINCON_0000000000A201400" Location="http://192.0.2.26:1400/xml/device_description.xml" ZoneName="Soundbar" Icon="" Configuration="1" Invisible="1" SoftwareVersion="97.2-81220" SWGen="2" HTSatChanMapSet="RINCON_00000000BEA801400:LF,RF;RINCON_0000000000A201400:RR,RTR" ActiveZoneID="00000000-0000-4000-8000-000000000001" SSLPort="1443" HHSSLPort="1843"/><Satellite UUID="RINCON_0000000000A101400" Location="http://192.0.2.12:1400/xml/device_description.xml" ZoneName="Soundbar" Icon="" Configuration="1" Invisible="1" SoftwareVersion="97.2-81220" SWGen="2" HTSatChanMapSet="RINCON_00000000BEA801400:LF,RF;RINCON_0000000000A101400:LR,LTR" ActiveZoneID="00000000-0000-4000-8000-000000000001" SSLPort="1443" HHSSLPort="1843"/><Satellite UUID="RINCON_00000000005B01400" Location="http://192.0.2.183:1400/xml/device_description.xml" ZoneName="Sub Mini" Icon="" Configuration="1" Invisible="1" SoftwareVersion="97.2-81220" SWGen="2" HTSatChanMapSet="RINCON_00000000BEA801400:LF,RF;RINCON_00000000005B01400:SW" ActiveZoneID="00000000-0000-4000-8000-000000000001" SSLPort="1443" HHSSLPort="1843"/></ZoneGroupMember></ZoneGroup></ZoneGroups><VanishedDevices></VanishedDevices></ZoneGroupState>
    """

    static let soundbarGroupedWithDen = """
    <ZoneGroupState><ZoneGroups><ZoneGroup Coordinator="RINCON_00000000BEA801400" ID="RINCON_00000000BEA801400:2000000003"><ZoneGroupMember UUID="RINCON_00000000BEA801400" Location="http://192.0.2.64:1400/xml/device_description.xml" ZoneName="Soundbar" Icon="" Configuration="1" SoftwareVersion="97.2-81220" HTSatChanMapSet="RINCON_00000000BEA801400:LF,RF;RINCON_00000000005B01400:SW"><Satellite UUID="RINCON_00000000005B01400" Location="http://192.0.2.183:1400/xml/device_description.xml" ZoneName="Sub Mini" Icon="" Configuration="1" Invisible="1" SoftwareVersion="97.2-81220"/></ZoneGroupMember><ZoneGroupMember UUID="RINCON_000000000D0E01400" Location="http://192.0.2.49:1400/xml/device_description.xml" ZoneName="Den" Icon="" Configuration="1" SoftwareVersion="97.2-81220"/></ZoneGroup><ZoneGroup Coordinator="RINCON_00000000C1C101400" ID="RINCON_00000000C1C101400:4000000005"><ZoneGroupMember UUID="RINCON_00000000C1C101400" Location="http://192.0.2.70:1400/xml/device_description.xml" ZoneName="Kitchen" Icon="" Configuration="1" SoftwareVersion="97.2-81220"/><ZoneGroupMember UUID="RINCON_00000000C1C201400" Location="http://192.0.2.71:1400/xml/device_description.xml" ZoneName="Kitchen" Icon="" Configuration="1" Invisible="1" ChannelMapSet="RINCON_00000000C1C101400:LF,LF;RINCON_00000000C1C201400:RF,RF" SoftwareVersion="97.2-81220"/></ZoneGroup><ZoneGroup Coordinator="RINCON_00000000AAAA01400" ID="RINCON_00000000AAAA01400:3000000004"><ZoneGroupMember UUID="RINCON_00000000AAAA01400" Location="http://192.0.2.80:1400/xml/device_description.xml" ZoneName="Bedroom" Icon="" Configuration="1" SoftwareVersion="97.2-81220"/></ZoneGroup></ZoneGroups><VanishedDevices></VanishedDevices></ZoneGroupState>
    """

    static let spotifyPositionInfo = """
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:GetPositionInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><Track>0</Track><TrackDuration>0:04:25</TrackDuration><TrackMetaData>&lt;DIDL-Lite xmlns:dc=&quot;http://purl.org/dc/elements/1.1/&quot; xmlns:upnp=&quot;urn:schemas-upnp-org:metadata-1-0/upnp/&quot; xmlns:r=&quot;urn:schemas-rinconnetworks-com:metadata-1-0/&quot; xmlns=&quot;urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/&quot;&gt;&lt;item id=&quot;-1&quot; parentID=&quot;-1&quot;&gt;&lt;res duration=&quot;0:04:25&quot;&gt;x-sonos-spotify:spotify:track:0000000000000000000000?sid=9&amp;amp;flags=0&amp;amp;sn=2&lt;/res&gt;&lt;upnp:albumArtURI&gt;https://i.scdn.co/image/ab67616d0000b27300000000000000000000000&lt;/upnp:albumArtURI&gt;&lt;upnp:class&gt;object.item.audioItem.musicTrack&lt;/upnp:class&gt;&lt;dc:title&gt;Boulevard Saint Germain&lt;/dc:title&gt;&lt;dc:creator&gt;Maison Blanche&lt;/dc:creator&gt;&lt;upnp:album&gt;Lovenergy&lt;/upnp:album&gt;&lt;r:streamInfo&gt;bd:16,sr:44100,c:0,l:0,d:0&lt;/r:streamInfo&gt;&lt;/item&gt;&lt;/DIDL-Lite&gt;</TrackMetaData><TrackURI>x-sonos-vli:RINCON_00000000BEA801400:2,spotify:00000000000000000000000000000000</TrackURI><RelTime>0:01:04</RelTime><AbsTime>NOT_IMPLEMENTED</AbsTime><RelCount>2147483647</RelCount><AbsCount>2147483647</AbsCount></u:GetPositionInfoResponse></s:Body></s:Envelope>
    """

    static let emptyPositionInfo = """
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:GetPositionInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><Track>0</Track><TrackDuration>0:00:00</TrackDuration><TrackMetaData></TrackMetaData><TrackURI></TrackURI><RelTime>0:00:00</RelTime><AbsTime>NOT_IMPLEMENTED</AbsTime><RelCount>2147483647</RelCount><AbsCount>2147483647</AbsCount></u:GetPositionInfoResponse></s:Body></s:Envelope>
    """

    static let radioTrackMetaData = """
    <DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:r="urn:schemas-rinconnetworks-com:metadata-1-0/" xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"><item id="-1" parentID="-1" restricted="true"><res protocolInfo="sonos.com-http:*:audio/mpeg:*">x-rincon-mp3radio://192.0.2.10:8080/stream.mp3</res><r:streamContent>Bicep - Glue &amp; Atlas</r:streamContent><r:radioShowMd></r:radioShowMd><upnp:albumArtURI>/getaa?s=1&amp;u=x-rincon-mp3radio%3a%2f%2f192.0.2.10%3a8080%2fstream.mp3</upnp:albumArtURI><dc:title>stream.mp3</dc:title><upnp:class>object.item</upnp:class></item></DIDL-Lite>
    """

    static var radioPositionInfo: String {
        response(service: "AVTransport", action: "GetPositionInfo", "<Track>1</Track><TrackDuration>0:00:00</TrackDuration><TrackMetaData>\(xmlEscaped(radioTrackMetaData))</TrackMetaData><TrackURI>x-rincon-mp3radio://192.0.2.10:8080/stream.mp3</TrackURI><RelTime>1:02:03</RelTime><AbsTime>NOT_IMPLEMENTED</AbsTime><RelCount>2147483647</RelCount><AbsCount>2147483647</AbsCount>")
    }

    static let transportInfoPlaying = """
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:GetTransportInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><CurrentTransportState>PLAYING</CurrentTransportState><CurrentTransportStatus>OK</CurrentTransportStatus><CurrentSpeed>1</CurrentSpeed></u:GetTransportInfoResponse></s:Body></s:Envelope>
    """

    static let volume12 = """
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:GetVolumeResponse xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1"><CurrentVolume>12</CurrentVolume></u:GetVolumeResponse></s:Body></s:Envelope>
    """

    static let groupVolume55 = """
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:GetGroupVolumeResponse xmlns:u="urn:schemas-upnp-org:service:GroupRenderingControl:1"><CurrentVolume>55</CurrentVolume></u:GetGroupVolumeResponse></s:Body></s:Envelope>
    """

    static let muteOff = """
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:GetMuteResponse xmlns:u="urn:schemas-upnp-org:service:RenderingControl:1"><CurrentMute>0</CurrentMute></u:GetMuteResponse></s:Body></s:Envelope>
    """

    static let invalidActionFault = """
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>401</errorCode></UPnPError></detail></s:Fault></s:Body></s:Envelope>
    """

    static let transitionNotAvailableFault = """
    <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>701</errorCode></UPnPError></detail></s:Fault></s:Body></s:Envelope>
    """

    static func deviceDescription(modelName: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8" ?><root xmlns="urn:schemas-upnp-org:device-1-0"><specVersion><major>1</major><minor>0</minor></specVersion><device><deviceType>urn:schemas-upnp-org:device:ZonePlayer:1</deviceType><friendlyName>192.0.2.64 - \(modelName)</friendlyName><manufacturer>Sonos, Inc.</manufacturer><modelName>\(modelName)</modelName><roomName>Soundbar</roomName><deviceList><device><deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType><modelName>\(modelName)</modelName></device></deviceList></device></root>
        """
    }
}

final class FakeSonosTransport: SonosHTTPTransport, @unchecked Sendable {
    struct Request: Equatable {
        let url: URL
        let soapAction: String?
        let body: String
    }

    private let lock = NSLock()
    private var recorded: [Request] = []
    private var responses: [String: (Int, String)] = [:]
    private var getResponses: [String: (Int, String)] = [:]
    private var failingHosts: Set<String> = []

    var requests: [Request] { lock.withLock { recorded } }

    func respond(to action: String, status: Int = 200, with body: String) {
        lock.withLock { responses[action] = (status, body) }
    }

    func respondToGet(host: String, status: Int = 200, with body: String) {
        lock.withLock { getResponses[host] = (status, body) }
    }

    func failRequests(to host: String) {
        lock.withLock { _ = failingHosts.insert(host) }
    }

    func post(url: URL, soapAction: String, body: Data) async throws -> (Int, Data) {
        let request = Request(url: url, soapAction: soapAction, body: String(decoding: body, as: UTF8.self))
        let reply: (Int, String)? = try lock.withLock {
            if let host = url.host, failingHosts.contains(host) { throw URLError(.cannotConnectToHost) }
            recorded.append(request)
            let action = soapAction.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).components(separatedBy: "#").last ?? ""
            return responses[action]
        }
        if let reply { return (reply.0, Data(reply.1.utf8)) }
        let parts = soapAction.trimmingCharacters(in: CharacterSet(charactersIn: "\"")).components(separatedBy: "#")
        let service = parts.first?.components(separatedBy: ":").dropLast().last ?? ""
        let action = parts.last ?? ""
        return (200, Data(SonosFixtures.response(service: service, action: action).utf8))
    }

    func get(url: URL) async throws -> (Int, Data) {
        let reply: (Int, String)? = lock.withLock {
            recorded.append(Request(url: url, soapAction: nil, body: ""))
            return getResponses[url.host ?? ""]
        }
        guard let reply else { return (404, Data()) }
        return (reply.0, Data(reply.1.utf8))
    }
}

@MainActor
final class FakeSonosBrowser: SonosServiceBrowsing {
    var onChange: (([SonosBonjourService]) -> Void)?
    private(set) var started = false
    private(set) var cancelled = false

    func start() { started = true }
    func cancel() { cancelled = true }

    func emit(_ services: [SonosBonjourService]) {
        onChange?(services)
    }
}
