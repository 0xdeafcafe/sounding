import Foundation

struct RekordboxTempo: Hashable, Sendable {
    var inizio: Double
    var bpm: Double
    var metro: String
    var battito: Int
}

struct RekordboxMark: Hashable, Sendable {
    var name: String
    var type: Int
    var start: Double
    var end: Double?
    var num: Int
    var red: Int?
    var green: Int?
    var blue: Int?

    var rgb: UInt32? {
        guard let red, let green, let blue else { return nil }
        return (UInt32(max(0, min(255, red))) << 16) | (UInt32(max(0, min(255, green))) << 8) | UInt32(max(0, min(255, blue)))
    }
}

struct RekordboxTrack: Hashable, Sendable, Identifiable {
    var trackId: String
    var attributes: [String: String]
    var tempos: [RekordboxTempo]
    var marks: [RekordboxMark]

    var id: String { trackId }
    var name: String { attributes["Name"] ?? "" }
    var artist: String { attributes["Artist"] ?? "" }
    var totalTime: Double { attributes["TotalTime"].flatMap(Double.init) ?? 0 }
    var averageBpm: Double? { attributes["AverageBpm"].flatMap(Double.init) }
    var tonality: String? { attributes["Tonality"].flatMap { $0.isEmpty ? nil : $0 } }
    var comments: String? { attributes["Comments"].flatMap { $0.isEmpty ? nil : $0 } }
    var location: String? { attributes["Location"] }

    var colour: UInt32? {
        guard let raw = attributes["Colour"], !raw.isEmpty else { return nil }
        let hex = raw.lowercased().hasPrefix("0x") ? String(raw.dropFirst(2)) : raw
        return UInt32(hex, radix: 16).map { $0 & 0x00FF_FFFF }
    }

    var fileURL: URL? {
        guard let location, !location.isEmpty else { return nil }
        if let url = URL(string: location), url.scheme == "file" {
            return URL(fileURLWithPath: url.path(percentEncoded: false))
        }
        return nil
    }
}

indirect enum RekordboxNode: Hashable, Sendable {
    case folder(name: String, children: [RekordboxNode])
    case playlist(name: String, keyType: Int, trackKeys: [String])

    var name: String {
        switch self {
        case .folder(let name, _): return name
        case .playlist(let name, _, _): return name
        }
    }
}

struct RekordboxLibrary: Hashable, Sendable {
    var productName: String
    var productVersion: String
    var productCompany: String
    var tracks: [RekordboxTrack]
    var playlists: [RekordboxNode]

    init(
        productName: String = "rekordbox",
        productVersion: String = "",
        productCompany: String = "AlphaTheta",
        tracks: [RekordboxTrack] = [],
        playlists: [RekordboxNode] = []
    ) {
        self.productName = productName
        self.productVersion = productVersion
        self.productCompany = productCompany
        self.tracks = tracks
        self.playlists = playlists
    }

    func flattenedPlaylists() -> [(path: [String], name: String, trackIds: [String])] {
        let byLocation = Dictionary(tracks.compactMap { track in track.location.map { ($0, track.trackId) } }, uniquingKeysWith: { first, _ in first })
        var out: [(path: [String], name: String, trackIds: [String])] = []
        func walk(_ nodes: [RekordboxNode], path: [String]) {
            for node in nodes {
                switch node {
                case .folder(let name, let children):
                    walk(children, path: path + [name])
                case .playlist(let name, let keyType, let keys):
                    let ids = keyType == 1 ? keys.compactMap { byLocation[$0] } : keys
                    out.append((path, name, ids))
                }
            }
        }
        walk(playlists, path: [])
        return out
    }
}

enum RekordboxXMLError: Error, Equatable {
    case tooLarge
    case notRekordbox
    case malformed(String)
}

enum RekordboxXML {

    static let maximumBytes = 64 * 1024 * 1024

    static func parse(_ data: Data) throws -> RekordboxLibrary {
        guard data.count <= maximumBytes else { throw RekordboxXMLError.tooLarge }
        let delegate = ParserDelegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        guard parser.parse() else {
            throw RekordboxXMLError.malformed(parser.parserError?.localizedDescription ?? "")
        }
        guard delegate.sawRoot else { throw RekordboxXMLError.notRekordbox }
        return delegate.library
    }

    private final class ParserDelegate: NSObject, XMLParserDelegate {
        var library = RekordboxLibrary()
        var sawRoot = false
        private var currentTrack: RekordboxTrack?
        private var inCollection = false
        private var inPlaylists = false
        private var nodeStack: [(name: String, type: Int, keyType: Int, children: [RekordboxNode], keys: [String])] = []

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch element {
            case "DJ_PLAYLISTS":
                sawRoot = true
            case "PRODUCT":
                library.productName = attributes["Name"] ?? library.productName
                library.productVersion = attributes["Version"] ?? ""
                library.productCompany = attributes["Company"] ?? library.productCompany
            case "COLLECTION":
                inCollection = true
            case "PLAYLISTS":
                inPlaylists = true
            case "TRACK" where inCollection:
                var attrs = attributes
                let id = attrs.removeValue(forKey: "TrackID") ?? ""
                currentTrack = RekordboxTrack(trackId: id, attributes: attrs, tempos: [], marks: [])
            case "TRACK" where inPlaylists:
                if !nodeStack.isEmpty, let key = attributes["Key"] {
                    nodeStack[nodeStack.count - 1].keys.append(key)
                }
            case "TEMPO":
                guard currentTrack != nil,
                      let inizio = attributes["Inizio"].flatMap(Double.init),
                      let bpm = attributes["Bpm"].flatMap(Double.init) else { return }
                currentTrack?.tempos.append(RekordboxTempo(
                    inizio: inizio,
                    bpm: bpm,
                    metro: attributes["Metro"] ?? "4/4",
                    battito: attributes["Battito"].flatMap(Int.init) ?? 1
                ))
            case "POSITION_MARK":
                guard currentTrack != nil, let start = attributes["Start"].flatMap(Double.init) else { return }
                currentTrack?.marks.append(RekordboxMark(
                    name: attributes["Name"] ?? "",
                    type: attributes["Type"].flatMap(Int.init) ?? 0,
                    start: start,
                    end: attributes["End"].flatMap(Double.init),
                    num: attributes["Num"].flatMap(Int.init) ?? -1,
                    red: attributes["Red"].flatMap(Int.init),
                    green: attributes["Green"].flatMap(Int.init),
                    blue: attributes["Blue"].flatMap(Int.init)
                ))
            case "NODE" where inPlaylists:
                nodeStack.append((
                    name: attributes["Name"] ?? "",
                    type: attributes["Type"].flatMap(Int.init) ?? 0,
                    keyType: attributes["KeyType"].flatMap(Int.init) ?? 0,
                    children: [],
                    keys: []
                ))
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            switch element {
            case "COLLECTION":
                inCollection = false
            case "PLAYLISTS":
                inPlaylists = false
            case "TRACK" where inCollection:
                if let track = currentTrack { library.tracks.append(track) }
                currentTrack = nil
            case "NODE" where inPlaylists:
                guard let node = nodeStack.popLast() else { return }
                let built: RekordboxNode = node.type == 1
                    ? .playlist(name: node.name, keyType: node.keyType, trackKeys: node.keys)
                    : .folder(name: node.name, children: node.children)
                if nodeStack.isEmpty {
                    if case .folder(let name, let children) = built, name == "ROOT" {
                        library.playlists = children
                    } else {
                        library.playlists.append(built)
                    }
                } else {
                    nodeStack[nodeStack.count - 1].children.append(built)
                }
            default:
                break
            }
        }
    }


    static let trackAttributeOrder = [
        "Name", "Artist", "Composer", "Album", "Grouping", "Genre", "Kind", "Size", "TotalTime",
        "DiscNumber", "TrackNumber", "Year", "AverageBpm", "DateAdded", "BitRate", "SampleRate",
        "Comments", "PlayCount", "Rating", "Location", "Remixer", "Tonality", "Label", "Mix", "Colour",
    ]

    static func write(_ library: RekordboxLibrary) -> Data {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\n"
        out += "<DJ_PLAYLISTS Version=\"1.0.0\">\n"
        out += "  <PRODUCT Name=\"\(escape(library.productName))\" Version=\"\(escape(library.productVersion))\" Company=\"\(escape(library.productCompany))\"/>\n"
        out += "  <COLLECTION Entries=\"\(library.tracks.count)\">\n"
        for track in library.tracks {
            var attributes = "TrackID=\"\(escape(track.trackId))\""
            let known = trackAttributeOrder.filter { track.attributes[$0] != nil }
            let extra = track.attributes.keys.filter { !trackAttributeOrder.contains($0) }.sorted()
            for key in known + extra {
                attributes += " \(key)=\"\(escape(track.attributes[key] ?? ""))\""
            }
            if track.tempos.isEmpty && track.marks.isEmpty {
                out += "    <TRACK \(attributes)/>\n"
                continue
            }
            out += "    <TRACK \(attributes)>\n"
            for tempo in track.tempos {
                out += "      <TEMPO Inizio=\"\(seconds(tempo.inizio))\" Bpm=\"\(bpm(tempo.bpm))\" Metro=\"\(escape(tempo.metro))\" Battito=\"\(tempo.battito)\"/>\n"
            }
            for mark in track.marks {
                var line = "      <POSITION_MARK Name=\"\(escape(mark.name))\" Type=\"\(mark.type)\" Start=\"\(seconds(mark.start))\""
                if let end = mark.end { line += " End=\"\(seconds(end))\"" }
                line += " Num=\"\(mark.num)\""
                if let red = mark.red, let green = mark.green, let blue = mark.blue {
                    line += " Red=\"\(red)\" Green=\"\(green)\" Blue=\"\(blue)\""
                }
                out += line + "/>\n"
            }
            out += "    </TRACK>\n"
        }
        out += "  </COLLECTION>\n"
        out += "  <PLAYLISTS>\n"
        out += "    <NODE Type=\"0\" Name=\"ROOT\" Count=\"\(library.playlists.count)\">\n"
        for node in library.playlists { writeNode(node, indent: 6, into: &out) }
        out += "    </NODE>\n"
        out += "  </PLAYLISTS>\n"
        out += "</DJ_PLAYLISTS>\n"
        return Data(out.utf8)
    }

    private static func writeNode(_ node: RekordboxNode, indent: Int, into out: inout String) {
        let pad = String(repeating: " ", count: indent)
        switch node {
        case .folder(let name, let children):
            out += "\(pad)<NODE Type=\"0\" Name=\"\(escape(name))\" Count=\"\(children.count)\">\n"
            for child in children { writeNode(child, indent: indent + 2, into: &out) }
            out += "\(pad)</NODE>\n"
        case .playlist(let name, let keyType, let keys):
            out += "\(pad)<NODE Name=\"\(escape(name))\" Type=\"1\" KeyType=\"\(keyType)\" Entries=\"\(keys.count)\">\n"
            for key in keys { out += "\(pad)  <TRACK Key=\"\(escape(key))\"/>\n" }
            out += "\(pad)</NODE>\n"
        }
    }

    static func seconds(_ value: Double) -> String {
        String(format: "%.3f", (value * 1000).rounded() / 1000)
    }

    static func bpm(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    static func escape(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\n": out += "&#10;"
            case "\r": out += "&#13;"
            case "\t": out += "&#9;"
            default:
                if scalar.value < 0x20 { continue }
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    static func location(for url: URL) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#[]@!$&'()*+,;=")
        let path = url.standardizedFileURL.path
        let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        return "file://localhost" + encoded
    }
}
