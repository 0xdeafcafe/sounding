import Foundation

enum SonosDIDL {
    static let namespaces = "xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\" xmlns:r=\"urn:schemas-rinconnetworks-com:metadata-1-0/\" xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\""

    static func streamMetadata(title: String, artist: String?, album: String?, artworkURL: URL?, streamURL: URL, mimeType: String) -> String {
        var item = "<item id=\"R:0/0/0\" parentID=\"R:0/0\" restricted=\"true\">"
        item += "<res protocolInfo=\"http-get:*:\(SonosXML.escape(mimeType)):*\">\(SonosXML.escape(streamURL.absoluteString))</res>"
        item += "<dc:title>\(SonosXML.escape(title))</dc:title>"
        if let artist, !artist.isEmpty {
            item += "<dc:creator>\(SonosXML.escape(artist))</dc:creator>"
        }
        if let album, !album.isEmpty {
            item += "<upnp:album>\(SonosXML.escape(album))</upnp:album>"
        }
        if let artworkURL {
            item += "<upnp:albumArtURI>\(SonosXML.escape(artworkURL.absoluteString))</upnp:albumArtURI>"
        }
        item += "<upnp:class>object.item.audioItem.audioBroadcast</upnp:class>"
        item += "<desc id=\"cdudn\" nameSpace=\"urn:schemas-rinconnetworks-com:metadata-1-0/\">SA_RINCON65031_</desc>"
        item += "</item>"
        return "<DIDL-Lite \(namespaces)>\(item)</DIDL-Lite>"
    }

    static func radioURI(for streamURL: URL) -> String {
        guard var components = URLComponents(url: streamURL, resolvingAgainstBaseURL: false) else {
            return "x-rincon-mp3radio://" + streamURL.absoluteString
        }
        components.scheme = "x-rincon-mp3radio"
        return components.string ?? "x-rincon-mp3radio://" + streamURL.absoluteString
    }

    static func nowPlaying(fromMetadata didl: String?, baseURL: URL?) -> SonosNowPlaying {
        var result = SonosNowPlaying()
        guard let didl, !didl.isEmpty, didl != "NOT_IMPLEMENTED",
              let root = try? SonosXML.parse(didl),
              let item = root.first("item") else { return result }
        result.title = clean(item.childText("title"))
        result.artist = clean(item.childText("creator")) ?? clean(item.childText("artist"))
        result.album = clean(item.childText("album"))
        result.streamContent = clean(item.childText("streamContent"))
        if let art = clean(item.childText("albumArtURI")) {
            result.artworkURL = URL(string: art, relativeTo: baseURL)?.absoluteURL
        }
        return result
    }

    private static func clean(_ string: String?) -> String? {
        guard let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
