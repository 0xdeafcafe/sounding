import Foundation

protocol SonosHTTPTransport: Sendable {
    func post(url: URL, soapAction: String, body: Data) async throws -> (Int, Data)
    func get(url: URL) async throws -> (Int, Data)
}

struct URLSessionSonosTransport: SonosHTTPTransport {
    static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }()

    let session: URLSession

    init(session: URLSession = URLSessionSonosTransport.defaultSession) {
        self.session = session
    }

    func post(url: URL, soapAction: String, body: Data) async throws -> (Int, Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue(soapAction, forHTTPHeaderField: "SOAPACTION")
        let (data, response) = try await session.loggedData(for: request, feature: .sonos)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    func get(url: URL) async throws -> (Int, Data) {
        let (data, response) = try await session.loggedData(from: url, feature: .sonos)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}
