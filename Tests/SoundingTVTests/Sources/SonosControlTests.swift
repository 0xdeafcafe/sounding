import XCTest
@testable import SoundingTV

final class SonosControlTests: XCTestCase {
    private let envelopeOpen = "<?xml version=\"1.0\" encoding=\"utf-8\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body>"
    private let envelopeClose = "</s:Body></s:Envelope>"

    func testSingleRoomTopology() throws {
        let groups = try SonosTopology.parseZoneGroupState(SonosFixtures.singleRoom)
        XCTAssertEqual(groups.count, 1)
        let den = try XCTUnwrap(groups.first)
        XCTAssertEqual(den.id, "RINCON_000000000D0E01400:1000000001")
        XCTAssertEqual(den.displayName, "Den")
        XCTAssertEqual(den.coordinator.id, "RINCON_000000000D0E01400")
        XCTAssertEqual(den.coordinator.host, "192.0.2.49")
        XCTAssertEqual(den.coordinator.port, 1400)
        XCTAssertFalse(den.coordinator.isInvisible)
        XCTAssertEqual(den.members.map(\.id), ["RINCON_000000000D0E01400"])
        XCTAssertTrue(den.satellites.isEmpty)
    }

    func testBondedSoundbarHidesSatellitesFromSOAPEnvelope() throws {
        let response = SonosFixtures.zoneGroupStateResponse(SonosFixtures.bondedSoundbarAndDen)
        let groups = try SonosTopology.parseZoneGroupState(response)
        XCTAssertEqual(groups.map(\.displayName), ["Den", "Soundbar"])
        let soundbar = groups[1]
        XCTAssertEqual(soundbar.coordinator.id, "RINCON_00000000BEA801400")
        XCTAssertEqual(soundbar.coordinator.host, "192.0.2.64")
        XCTAssertEqual(soundbar.members.map(\.roomName), ["Soundbar"])
        XCTAssertEqual(soundbar.satellites.count, 3)
        XCTAssertTrue(soundbar.satellites.allSatisfy(\.isInvisible))
        XCTAssertEqual(Set(soundbar.satellites.map(\.host)), ["192.0.2.26", "192.0.2.12", "192.0.2.183"])
        XCTAssertFalse(soundbar.members.contains { $0.roomName == "Sub Mini" })
    }

    func testTwoRoomGroupDisplayNameAndStereoPair() throws {
        let groups = try SonosTopology.parseZoneGroupState(SonosFixtures.soundbarGroupedWithDen)
        XCTAssertEqual(groups.map(\.displayName), ["Bedroom", "Kitchen", "Soundbar + Den"])
        let grouped = groups[2]
        XCTAssertEqual(grouped.coordinator.roomName, "Soundbar")
        XCTAssertEqual(grouped.members.map(\.roomName), ["Soundbar", "Den"])
        XCTAssertEqual(grouped.satellites.map(\.roomName), ["Sub Mini"])
        let kitchen = groups[1]
        XCTAssertEqual(kitchen.members.map(\.id), ["RINCON_00000000C1C101400"])
        XCTAssertEqual(kitchen.satellites.map(\.id), ["RINCON_00000000C1C201400"])
    }

    func testDisplayNameOrdersCoordinatorFirstThenAlphabetical() {
        let player = { (id: String, name: String) in
            SonosPlayer(id: id, roomName: name, host: "192.0.2.1", port: 1400, modelName: nil, isInvisible: false)
        }
        let coordinator = player("C", "Office")
        let group = SonosGroup(id: "G", coordinator: coordinator, members: [player("Z", "Patio"), coordinator, player("A", "Bathroom")])
        XCTAssertEqual(group.displayName, "Office + Bathroom + Patio")
        XCTAssertEqual(group.members.map(\.roomName), ["Office", "Bathroom", "Patio"])
    }

    func testMalformedTopologyThrows() {
        XCTAssertThrowsError(try SonosTopology.parseZoneGroupState("<ZoneGroupState><ZoneGroups>"))
        XCTAssertThrowsError(try SonosTopology.parseZoneGroupState(SonosFixtures.response(service: "ZoneGroupTopology", action: "GetZoneGroupState")))
    }

    func testDeviceDescriptionModelName() {
        let data = Data(SonosFixtures.deviceDescription(modelName: "Sonos Beam").utf8)
        XCTAssertEqual(SonosTopology.modelName(fromDeviceDescription: data), "Sonos Beam")
    }

    func testNowPlayingFromRecordedPositionInfo() async throws {
        let transport = FakeSonosTransport()
        transport.respond(to: "GetPositionInfo", with: SonosFixtures.spotifyPositionInfo)
        let client = SonosClient(host: "192.0.2.64", transport: transport)
        let now = try await client.nowPlaying()
        XCTAssertEqual(now.title, "Boulevard Saint Germain")
        XCTAssertEqual(now.artist, "Maison Blanche")
        XCTAssertEqual(now.album, "Lovenergy")
        XCTAssertEqual(now.artworkURL?.absoluteString, "https://i.scdn.co/image/ab67616d0000b27300000000000000000000000")
        XCTAssertEqual(now.trackURI, "x-sonos-vli:RINCON_00000000BEA801400:2,spotify:00000000000000000000000000000000")
        XCTAssertEqual(now.position, 64)
        XCTAssertEqual(now.duration, 265)
        XCTAssertNil(now.streamContent)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testNowPlayingRadioStreamContentAndRelativeArtwork() async throws {
        let transport = FakeSonosTransport()
        transport.respond(to: "GetPositionInfo", with: SonosFixtures.radioPositionInfo)
        let client = SonosClient(host: "192.0.2.64", transport: transport)
        let now = try await client.nowPlaying()
        XCTAssertEqual(now.title, "stream.mp3")
        XCTAssertEqual(now.streamContent, "Bicep - Glue & Atlas")
        XCTAssertEqual(now.trackURI, "x-rincon-mp3radio://192.0.2.10:8080/stream.mp3")
        XCTAssertEqual(now.position, 3723)
        XCTAssertNil(now.duration)
        XCTAssertEqual(now.artworkURL?.absoluteString, "http://192.0.2.64:1400/getaa?s=1&u=x-rincon-mp3radio%3a%2f%2f192.0.2.10%3a8080%2fstream.mp3")
    }

    func testNowPlayingWhenIdle() async throws {
        let transport = FakeSonosTransport()
        transport.respond(to: "GetPositionInfo", with: SonosFixtures.emptyPositionInfo)
        let now = try await SonosClient(host: "192.0.2.49", transport: transport).nowPlaying()
        XCTAssertEqual(now, SonosNowPlaying(position: 0))
    }

    func testTimeParsing() {
        XCTAssertEqual(SonosSOAP.timeInterval("0:04:25"), 265)
        XCTAssertEqual(SonosSOAP.timeInterval("12:00:01"), 43201)
        XCTAssertNil(SonosSOAP.timeInterval("NOT_IMPLEMENTED"))
        XCTAssertNil(SonosSOAP.timeInterval(""))
        XCTAssertEqual(SonosSOAP.timeString(3723.9), "1:02:03")
    }

    func testReadsVolumeMuteAndTransportState() async throws {
        let transport = FakeSonosTransport()
        transport.respond(to: "GetVolume", with: SonosFixtures.volume12)
        transport.respond(to: "GetGroupVolume", with: SonosFixtures.groupVolume55)
        transport.respond(to: "GetMute", with: SonosFixtures.muteOff)
        transport.respond(to: "GetTransportInfo", with: SonosFixtures.transportInfoPlaying)
        let client = SonosClient(host: "192.0.2.64", transport: transport)
        let volume = try await client.volume()
        let groupVolume = try await client.groupVolume()
        let muted = try await client.isMuted()
        let state = try await client.transportState()
        XCTAssertEqual(volume, 12)
        XCTAssertEqual(groupVolume, 55)
        XCTAssertFalse(muted)
        XCTAssertEqual(state, .playing)
        XCTAssertEqual(transport.requests[0].body, envelopeOpen + "<u:GetVolume xmlns:u=\"urn:schemas-upnp-org:service:RenderingControl:1\"><InstanceID>0</InstanceID><Channel>Master</Channel></u:GetVolume>" + envelopeClose)
    }

    func testFaultSurfacesUPnPErrorCode() async {
        let transport = FakeSonosTransport()
        transport.respond(to: "Play", status: 500, with: SonosFixtures.transitionNotAvailableFault)
        let client = SonosClient(host: "192.0.2.64", transport: transport)
        do {
            try await client.play()
            XCTFail("Expected a fault")
        } catch let error as SonosSOAPError {
            XCTAssertEqual(error, SonosSOAPError(httpStatus: 500, upnpErrorCode: 701))
        } catch {
            XCTFail("Unexpected \(error)")
        }
        XCTAssertEqual(SonosSOAP.upnpErrorCode(Data(SonosFixtures.invalidActionFault.utf8)), 401)
        XCTAssertNil(SonosSOAP.upnpErrorCode(Data("Not XML".utf8)))
    }

    func testSetVolume() async throws {
        let transport = FakeSonosTransport()
        try await SonosClient(host: "192.0.2.49", transport: transport).setVolume(42)
        try await SonosClient(host: "192.0.2.49", transport: transport).setVolume(140)
        let request = transport.requests[0]
        XCTAssertEqual(request.url.absoluteString, "http://192.0.2.49:1400/MediaRenderer/RenderingControl/Control")
        XCTAssertEqual(request.soapAction, "\"urn:schemas-upnp-org:service:RenderingControl:1#SetVolume\"")
        XCTAssertEqual(request.body, envelopeOpen + "<u:SetVolume xmlns:u=\"urn:schemas-upnp-org:service:RenderingControl:1\"><InstanceID>0</InstanceID><Channel>Master</Channel><DesiredVolume>42</DesiredVolume></u:SetVolume>" + envelopeClose)
        XCTAssertTrue(transport.requests[1].body.contains("<DesiredVolume>100</DesiredVolume>"))
    }

    func testSetMuted() async throws {
        let transport = FakeSonosTransport()
        let client = SonosClient(host: "192.0.2.49", transport: transport)
        try await client.setMuted(true)
        try await client.setGroupMuted(false)
        XCTAssertEqual(transport.requests[0].soapAction, "\"urn:schemas-upnp-org:service:RenderingControl:1#SetMute\"")
        XCTAssertTrue(transport.requests[0].body.contains("<u:SetMute xmlns:u=\"urn:schemas-upnp-org:service:RenderingControl:1\"><InstanceID>0</InstanceID><Channel>Master</Channel><DesiredMute>1</DesiredMute></u:SetMute>"))
        XCTAssertEqual(transport.requests[1].url.path, "/MediaRenderer/GroupRenderingControl/Control")
        XCTAssertEqual(transport.requests[1].soapAction, "\"urn:schemas-upnp-org:service:GroupRenderingControl:1#SetGroupMute\"")
        XCTAssertTrue(transport.requests[1].body.contains("<InstanceID>0</InstanceID><DesiredMute>0</DesiredMute>"))
    }

    func testSetGroupVolumeSnapshotsFirst() async throws {
        let transport = FakeSonosTransport()
        try await SonosClient(host: "192.0.2.64", transport: transport).setGroupVolume(30)
        XCTAssertEqual(transport.requests.map(\.soapAction), [
            "\"urn:schemas-upnp-org:service:GroupRenderingControl:1#SnapshotGroupVolume\"",
            "\"urn:schemas-upnp-org:service:GroupRenderingControl:1#SetGroupVolume\"",
        ])
        XCTAssertTrue(transport.requests.allSatisfy { $0.url.absoluteString == "http://192.0.2.64:1400/MediaRenderer/GroupRenderingControl/Control" })
        XCTAssertEqual(transport.requests[0].body, envelopeOpen + "<u:SnapshotGroupVolume xmlns:u=\"urn:schemas-upnp-org:service:GroupRenderingControl:1\"><InstanceID>0</InstanceID></u:SnapshotGroupVolume>" + envelopeClose)
        XCTAssertEqual(transport.requests[1].body, envelopeOpen + "<u:SetGroupVolume xmlns:u=\"urn:schemas-upnp-org:service:GroupRenderingControl:1\"><InstanceID>0</InstanceID><DesiredVolume>30</DesiredVolume></u:SetGroupVolume>" + envelopeClose)
    }

    func testPlayPauseStop() async throws {
        let transport = FakeSonosTransport()
        let client = SonosClient(host: "192.0.2.64", transport: transport)
        try await client.play()
        try await client.pause()
        try await client.stop()
        XCTAssertEqual(transport.requests.map(\.soapAction), [
            "\"urn:schemas-upnp-org:service:AVTransport:1#Play\"",
            "\"urn:schemas-upnp-org:service:AVTransport:1#Pause\"",
            "\"urn:schemas-upnp-org:service:AVTransport:1#Stop\"",
        ])
        XCTAssertTrue(transport.requests.allSatisfy { $0.url.absoluteString == "http://192.0.2.64:1400/MediaRenderer/AVTransport/Control" })
        XCTAssertEqual(transport.requests[0].body, envelopeOpen + "<u:Play xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\"><InstanceID>0</InstanceID><Speed>1</Speed></u:Play>" + envelopeClose)
        XCTAssertEqual(transport.requests[1].body, envelopeOpen + "<u:Pause xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\"><InstanceID>0</InstanceID></u:Pause>" + envelopeClose)
        XCTAssertEqual(transport.requests[2].body, envelopeOpen + "<u:Stop xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\"><InstanceID>0</InstanceID></u:Stop>" + envelopeClose)
    }

    func testSetAVTransportURIDoubleEscapesMetadataAndRoundTrips() async throws {
        let stream = try XCTUnwrap(URL(string: "http://192.0.2.5:8123/sonos/stream.mp3?token=a&b=c"))
        let artwork = try XCTUnwrap(URL(string: "https://i1.sndcdn.com/artworks-000-t500x500.jpg?x=1&y=2"))
        let metadata = SonosDIDL.streamMetadata(title: "Drum & Bass <Live> \"Set\"", artist: "DJ O'Neil", album: nil, artworkURL: artwork, streamURL: stream, mimeType: "audio/mpeg")
        XCTAssertTrue(metadata.contains("<dc:title>Drum &amp; Bass &lt;Live&gt; &quot;Set&quot;</dc:title>"))
        XCTAssertTrue(metadata.contains("<upnp:class>object.item.audioItem.audioBroadcast</upnp:class>"))
        XCTAssertTrue(metadata.contains("<desc id=\"cdudn\" nameSpace=\"urn:schemas-rinconnetworks-com:metadata-1-0/\">SA_RINCON65031_</desc>"))
        XCTAssertTrue(metadata.contains("<res protocolInfo=\"http-get:*:audio/mpeg:*\">http://192.0.2.5:8123/sonos/stream.mp3?token=a&amp;b=c</res>"))
        XCTAssertFalse(metadata.contains("<upnp:album>"))

        let uri = SonosDIDL.radioURI(for: stream)
        XCTAssertEqual(uri, "x-rincon-mp3radio://192.0.2.5:8123/sonos/stream.mp3?token=a&b=c")

        let transport = FakeSonosTransport()
        try await SonosClient(host: "192.0.2.64", transport: transport).setAVTransportURI(uri, metadata: metadata)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.soapAction, "\"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI\"")
        XCTAssertTrue(request.body.contains("<CurrentURI>x-rincon-mp3radio://192.0.2.5:8123/sonos/stream.mp3?token=a&amp;b=c</CurrentURI>"))
        XCTAssertTrue(request.body.contains("<CurrentURIMetaData>&lt;DIDL-Lite xmlns:dc=&quot;http://purl.org/dc/elements/1.1/&quot;"))
        XCTAssertTrue(request.body.contains("&lt;dc:title&gt;Drum &amp;amp; Bass &amp;lt;Live&amp;gt; &amp;quot;Set&amp;quot;&lt;/dc:title&gt;"))
        XCTAssertFalse(request.body.contains("<DIDL-Lite"))

        let envelope = try SonosXML.parse(request.body)
        let action = try XCTUnwrap(envelope.first("SetAVTransportURI"))
        XCTAssertEqual(action.children.map(\.name), ["InstanceID", "CurrentURI", "CurrentURIMetaData"])
        XCTAssertEqual(action.childText("CurrentURI"), uri)
        XCTAssertEqual(action.childText("CurrentURIMetaData"), metadata)
        let decoded = SonosDIDL.nowPlaying(fromMetadata: action.childText("CurrentURIMetaData"), baseURL: nil)
        XCTAssertEqual(decoded.title, "Drum & Bass <Live> \"Set\"")
        XCTAssertEqual(decoded.artist, "DJ O'Neil")
        XCTAssertEqual(decoded.artworkURL, artwork)
    }

    func testRadioURIForHTTPSAndPortlessURLs() throws {
        XCTAssertEqual(SonosDIDL.radioURI(for: try XCTUnwrap(URL(string: "https://example.com/live/a.mp3"))), "x-rincon-mp3radio://example.com/live/a.mp3")
        XCTAssertEqual(SonosDIDL.radioURI(for: try XCTUnwrap(URL(string: "http://192.0.2.5/a"))), "x-rincon-mp3radio://192.0.2.5/a")
    }

    func testJoinAndLeaveGroup() async throws {
        let transport = FakeSonosTransport()
        let den = SonosClient(host: "192.0.2.49", transport: transport)
        try await den.join(coordinatorID: "RINCON_00000000BEA801400")
        try await den.leaveGroup()
        XCTAssertEqual(transport.requests[0].soapAction, "\"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI\"")
        XCTAssertEqual(transport.requests[0].body, envelopeOpen + "<u:SetAVTransportURI xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\"><InstanceID>0</InstanceID><CurrentURI>x-rincon:RINCON_00000000BEA801400</CurrentURI><CurrentURIMetaData></CurrentURIMetaData></u:SetAVTransportURI>" + envelopeClose)
        XCTAssertEqual(transport.requests[1].soapAction, "\"urn:schemas-upnp-org:service:AVTransport:1#BecomeCoordinatorOfStandaloneGroup\"")
        XCTAssertEqual(transport.requests[1].body, envelopeOpen + "<u:BecomeCoordinatorOfStandaloneGroup xmlns:u=\"urn:schemas-upnp-org:service:AVTransport:1\"><InstanceID>0</InstanceID></u:BecomeCoordinatorOfStandaloneGroup>" + envelopeClose)
        XCTAssertEqual(transport.requests[1].url.absoluteString, "http://192.0.2.49:1400/MediaRenderer/AVTransport/Control")
    }

    func testZoneGroupStateRequest() async throws {
        let transport = FakeSonosTransport()
        transport.respond(to: "GetZoneGroupState", with: SonosFixtures.zoneGroupStateResponse(SonosFixtures.bondedSoundbarAndDen))
        let groups = try await SonosClient(host: "192.0.2.49", transport: transport).zoneGroupState()
        XCTAssertEqual(groups.map(\.displayName), ["Den", "Soundbar"])
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url.absoluteString, "http://192.0.2.49:1400/ZoneGroupTopology/Control")
        XCTAssertEqual(request.soapAction, "\"urn:schemas-upnp-org:service:ZoneGroupTopology:1#GetZoneGroupState\"")
        XCTAssertEqual(request.body, envelopeOpen + "<u:GetZoneGroupState xmlns:u=\"urn:schemas-upnp-org:service:ZoneGroupTopology:1\"></u:GetZoneGroupState>" + envelopeClose)
    }

    func testBonjourServiceIdentity() {
        let fromTXT = SonosBonjourService.make(serviceName: "RINCON_00000000BEA801400@Soundbar", txt: ["uuid": "RINCON_00000000BEA801400", "location": "http://192.0.2.64:1400/xml/device_description.xml"])
        XCTAssertEqual(fromTXT, SonosBonjourService(name: "RINCON_00000000BEA801400@Soundbar", rinconID: "RINCON_00000000BEA801400", host: "192.0.2.64", port: 1400))
        let fromName = SonosBonjourService.make(serviceName: "RINCON_000000000D0E01400@Den", txt: [:])
        XCTAssertEqual(fromName?.rinconID, "RINCON_000000000D0E01400")
        XCTAssertNil(fromName?.host)
        XCTAssertNil(SonosBonjourService.make(serviceName: "Living Room", txt: [:]))
    }

    @MainActor
    func testDiscoveryDedupesAndFetchesTopologyOnBrowseChange() async throws {
        let transport = FakeSonosTransport()
        transport.respond(to: "GetZoneGroupState", with: SonosFixtures.zoneGroupStateResponse(SonosFixtures.bondedSoundbarAndDen))
        transport.respondToGet(host: "192.0.2.64", with: SonosFixtures.deviceDescription(modelName: "Sonos Beam"))
        transport.respondToGet(host: "192.0.2.49", with: SonosFixtures.deviceDescription(modelName: "Sonos Move"))
        let browser = FakeSonosBrowser()
        let discovery = SonosDiscovery(transport: transport, browserFactory: { browser }, refreshDelay: .zero)
        discovery.start()
        XCTAssertTrue(browser.started)
        XCTAssertTrue(discovery.isBrowsing)

        let soundbar = SonosBonjourService(name: "RINCON_00000000BEA801400@Soundbar", rinconID: "RINCON_00000000BEA801400", host: "192.0.2.64", port: 1400)
        let soundbarAgain = SonosBonjourService(name: "RINCON_00000000BEA801400@Soundbar", rinconID: "RINCON_00000000BEA801400", host: nil, port: 1400)
        let sub = SonosBonjourService(name: "RINCON_00000000005B01400@Sub Mini", rinconID: "RINCON_00000000005B01400", host: "192.0.2.183", port: 1400)
        browser.emit([soundbar, soundbarAgain, sub])
        XCTAssertEqual(discovery.discoveredServices.count, 2)
        XCTAssertEqual(discovery.discoveredServices.first { $0.rinconID == soundbar.rinconID }?.host, "192.0.2.64")

        for _ in 0..<200 where discovery.groups.first?.coordinator.modelName == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(discovery.groups.map(\.displayName), ["Den", "Soundbar"])
        XCTAssertEqual(discovery.groups.map(\.coordinator.modelName), ["Sonos Move", "Sonos Beam"])
        XCTAssertEqual(discovery.groups[1].satellites.count, 3)

        let topologyCalls = transport.requests.filter { $0.soapAction?.hasSuffix("#GetZoneGroupState\"") == true }
        XCTAssertEqual(topologyCalls.count, 1)

        discovery.stop()
        XCTAssertTrue(browser.cancelled)
        XCTAssertFalse(discovery.isBrowsing)
        XCTAssertTrue(discovery.groups.isEmpty)
    }

    @MainActor
    func testDiscoveryFallsBackToAnotherPlayerAndCoalescesRefreshes() async throws {
        let transport = FakeSonosTransport()
        transport.respond(to: "GetZoneGroupState", with: SonosFixtures.zoneGroupStateResponse(SonosFixtures.singleRoom))
        transport.failRequests(to: "192.0.2.183")
        let browser = FakeSonosBrowser()
        let discovery = SonosDiscovery(transport: transport, browserFactory: { browser }, refreshDelay: .seconds(60))
        discovery.start()
        browser.emit([
            SonosBonjourService(name: "RINCON_00000000005B01400@Sub Mini", rinconID: "RINCON_00000000005B01400", host: "192.0.2.183", port: 1400),
            SonosBonjourService(name: "RINCON_000000000D0E01400@Den", rinconID: "RINCON_000000000D0E01400", host: "192.0.2.49", port: 1400),
        ])

        async let first: Void = discovery.refreshTopology()
        async let second: Void = discovery.refreshTopology()
        async let third: Void = discovery.refreshTopology()
        _ = await (first, second, third)

        XCTAssertEqual(discovery.groups.map(\.displayName), ["Den"])
        let topologyCalls = transport.requests.filter { $0.soapAction?.hasSuffix("#GetZoneGroupState\"") == true }
        XCTAssertGreaterThanOrEqual(topologyCalls.count, 1)
        XCTAssertLessThanOrEqual(topologyCalls.count, 2)
        XCTAssertTrue(topologyCalls.allSatisfy { $0.url.host == "192.0.2.49" })

        browser.emit([])
        XCTAssertTrue(discovery.groups.isEmpty)
        discovery.stop()
    }
}
