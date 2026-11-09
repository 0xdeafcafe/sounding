import Foundation

enum SonosTopology {
    static func parseZoneGroupState(_ xml: String) throws -> [SonosGroup] {
        var root = try SonosXML.parse(xml)
        if root.localName == "Envelope" {
            guard let inner = root.first("ZoneGroupState")?.text, !inner.isEmpty else {
                throw SonosResponseError.malformed("Missing ZoneGroupState")
            }
            root = try SonosXML.parse(inner)
        }
        return root.all("ZoneGroup")
            .compactMap(group(from:))
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private static func group(from element: SonosXMLElement) -> SonosGroup? {
        guard let id = element.attributes["ID"], let coordinatorID = element.attributes["Coordinator"] else { return nil }
        var visible: [SonosPlayer] = []
        var hidden: [SonosPlayer] = []
        for memberElement in element.children where memberElement.localName == "ZoneGroupMember" {
            if let member = player(from: memberElement) {
                if member.isInvisible { hidden.append(member) } else { visible.append(member) }
            }
            for satelliteElement in memberElement.children where satelliteElement.localName == "Satellite" {
                if let satellite = player(from: satelliteElement, forceInvisible: true) {
                    hidden.append(satellite)
                }
            }
        }
        guard let coordinator = (visible + hidden).first(where: { $0.id == coordinatorID }), !visible.isEmpty else { return nil }
        let coordinatorPlayer = coordinator.isInvisible ? visible[0] : coordinator
        return SonosGroup(id: id, coordinator: coordinatorPlayer, members: visible, satellites: hidden)
    }

    private static func player(from element: SonosXMLElement, forceInvisible: Bool = false) -> SonosPlayer? {
        guard let id = element.attributes["UUID"],
              let location = element.attributes["Location"],
              let url = URL(string: location),
              let host = url.host else { return nil }
        let invisible = forceInvisible || element.attributes["Invisible"] == "1"
        return SonosPlayer(
            id: id,
            roomName: element.attributes["ZoneName"] ?? id,
            host: host,
            port: url.port ?? 1400,
            modelName: nil,
            isInvisible: invisible
        )
    }

    static func modelName(fromDeviceDescription xml: Data) -> String? {
        guard let root = try? SonosXML.parse(xml) else { return nil }
        let name = root.first("device")?.childText("modelName") ?? root.first("modelName")?.text
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

