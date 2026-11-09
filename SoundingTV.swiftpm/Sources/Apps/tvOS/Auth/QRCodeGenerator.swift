import SwiftUI

enum QRCodeGenerator {

    private static let linkBaseURL = "https://sounding.forbes.red/auth/"

    static func matrix(for credentials: SessionCredentials) -> QRMatrix? {
        matrix(for: buildPairingURL(for: credentials))
    }

    static func matrix(for string: String) -> QRMatrix? {
        QRMatrix.make(from: string)
    }

    static func buildPairingURL(for credentials: SessionCredentials) -> String {
        var components = URLComponents(string: linkBaseURL)
            ?? URLComponents(string: "https://sounding.forbes.red/auth/")
            ?? URLComponents()
        components.queryItems = [
            URLQueryItem(name: "session", value: credentials.sessionId),
            URLQueryItem(name: "secret", value: credentials.secretBase64URL)
        ]
        let urlString = components.url?.absoluteString ?? linkBaseURL
        #if DEBUG
        NSLog("[QRCodeGenerator] PairingURL session=%@", credentials.sessionId)
        #endif
        return urlString
    }
}
