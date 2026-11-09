import Foundation

enum SonosService: String, Sendable, CaseIterable {
    case avTransport = "AVTransport"
    case renderingControl = "RenderingControl"
    case groupRenderingControl = "GroupRenderingControl"
    case zoneGroupTopology = "ZoneGroupTopology"

    var urn: String { "urn:schemas-upnp-org:service:\(rawValue):1" }

    var controlPath: String {
        switch self {
        case .avTransport: return "/MediaRenderer/AVTransport/Control"
        case .renderingControl: return "/MediaRenderer/RenderingControl/Control"
        case .groupRenderingControl: return "/MediaRenderer/GroupRenderingControl/Control"
        case .zoneGroupTopology: return "/ZoneGroupTopology/Control"
        }
    }

    func soapAction(_ action: String) -> String {
        "\"\(urn)#\(action)\""
    }
}

enum SonosSOAP {
    static func envelope(service: SonosService, action: String, arguments: [(String, String)]) -> String {
        let body = arguments.map { "<\($0.0)>\(SonosXML.escape($0.1))</\($0.0)>" }.joined()
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            + "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
            + "<s:Body><u:\(action) xmlns:u=\"\(service.urn)\">\(body)</u:\(action)></s:Body></s:Envelope>"
    }

    static func responseValues(_ data: Data, action: String) throws -> [String: String] {
        let root = try SonosXML.parse(data)
        guard let response = root.first("\(action)Response") else {
            throw SonosResponseError.malformed("Missing \(action)Response")
        }
        var values: [String: String] = [:]
        for child in response.children {
            values[child.localName] = child.text
        }
        return values
    }

    static func upnpErrorCode(_ data: Data) -> Int? {
        guard let root = try? SonosXML.parse(data),
              let text = root.first("errorCode")?.text.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return Int(text)
    }

    static func timeInterval(_ string: String?) -> TimeInterval? {
        guard let string = string?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else { return nil }
        let parts = string.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total: TimeInterval = 0
        for part in parts {
            guard let value = Double(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }

    static func timeString(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.down)))
        return String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
}
