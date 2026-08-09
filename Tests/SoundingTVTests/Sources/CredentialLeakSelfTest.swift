import Foundation
@testable import SoundingTV

@MainActor
enum CredentialLeakSelfTest {
    struct Report {
        var lines: [String] = []
        var failures: [String] = []

        var summary: String {
            let status = failures.isEmpty ? "PASS" : "FAIL (\(failures.count))"
            return (["[CredentialLeakTest] \(status)"] + lines.map { "[CredentialLeakTest]   \($0)" }
                + failures.map { "[CredentialLeakTest]   ✗ \($0)" }).joined(separator: "\n")
        }
    }

    private final class StubSource: SoundCloudCredentialSourcing {
        let accessToken: String?
        var currentUser: User? { nil }
        init(token: String?) { accessToken = token }
        func waitForCurrentUser() async -> User? { nil }
        func refreshAccessToken() async -> Bool { false }
        func handleUnauthorized() async {}
    }

    static func run() -> Report {
        var report = Report()
        strippingCases(&report)
        builtURLCases(&report)
        clientIDPolicyCases(&report)
        commentsEndpointCases(&report)
        challengeDetectionCases(&report)
        return report
    }

    private static func expect(_ report: inout Report, _ label: String, _ condition: Bool) {
        if condition { report.lines.append("\(label): ok") } else { report.failures.append(label) }
    }

    private static func strippingCases(_ report: inout Report) {
        expect(&report, "oauth_token is forbidden",
               SoundCloudAPI.forbiddenQueryNames.contains("oauth_token"))

        for name in SoundCloudAPI.forbiddenQueryNames {
            let url = URL(string: "https://api-v2.soundcloud.com/me?limit=5&\(name)=SECRET&x=1")!
            let cleaned = SoundCloudAPI.strippingCredentials(from: url)
            let query = cleaned.query ?? ""
            expect(&report, "strips \(name)", !query.contains("SECRET") && !query.contains(name))
            expect(&report, "\(name): keeps siblings", query.contains("limit=5") && query.contains("x=1"))
        }

        let mixedCase = URL(string: "https://api-v2.soundcloud.com/me?OAuth_Token=SECRET")!
        expect(&report, "case-insensitive strip",
               !(SoundCloudAPI.strippingCredentials(from: mixedCase).query ?? "").contains("SECRET"))

        let onlyToken = URL(string: "https://api-v2.soundcloud.com/me?oauth_token=SECRET")!
        expect(&report, "drops empty query",
               SoundCloudAPI.strippingCredentials(from: onlyToken).query == nil)

        let clean = URL(string: "https://api-v2.soundcloud.com/tracks?ids=1,2,3")!
        expect(&report, "leaves clean URLs alone",
               SoundCloudAPI.strippingCredentials(from: clean) == clean)

        let noQuery = URL(string: "https://api-v2.soundcloud.com/me")!
        expect(&report, "handles no query",
               SoundCloudAPI.strippingCredentials(from: noQuery) == noQuery)
    }

    private static func builtURLCases(_ report: inout Report) {
        let installed = SoundCloudAPI.credentials
        defer { SoundCloudAPI.credentials = installed }

        let marker = "SELFTEST-TOKEN-MUST-NOT-APPEAR"
        SoundCloudAPI.credentials = StubSource(token: marker)

        let paths: [(String, [URLQueryItem])] = [
            ("me", []),
            ("stream", [URLQueryItem(name: "limit", value: "50")]),
            ("me/library/all", [URLQueryItem(name: "limit", value: "50")]),
            ("search/tracks", [URLQueryItem(name: "q", value: "test"), URLQueryItem(name: "limit", value: "50")]),
            ("mixed-selections", []),
        ]

        for (path, items) in paths {
            guard let url = SoundCloudAPI.shared.urlForSelfTest(path, queryItems: items) else {
                report.failures.append("buildURL returned nil for \(path)")
                continue
            }
            let absolute = url.absoluteString
            expect(&report, "\(path): no token in URL", !absolute.contains(marker))
            let names = Set((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { $0.name.lowercased() })
            expect(&report, "\(path): no credential parameter",
                   names.isDisjoint(with: SoundCloudAPI.forbiddenQueryNames))
        }

        if let url = SoundCloudAPI.shared.urlForSelfTest("stream", queryItems: [URLQueryItem(name: "limit", value: "50")]) {
            expect(&report, "declared query items preserved", (url.query ?? "").contains("limit=50"))
        }
    }

    private static func clientIDValue(of url: URL) -> String? {
        (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .first { $0.name.lowercased() == "client_id" }?.value
    }

    private static func clientIDPolicyCases(_ report: inout Report) {
        let installed = SoundCloudAPI.credentials
        defer { SoundCloudAPI.credentials = installed }

        let marker = "SELFTEST-TOKEN-MUST-NOT-APPEAR"

        SoundCloudAPI.credentials = StubSource(token: marker)

        guard let authedURL = SoundCloudAPI.shared.urlForSelfTest("mixed-selections") else {
            report.failures.append("buildURL returned nil for mixed-selections (signed in)")
            return
        }
        expect(&report, "signed in: no client_id is added to a URL that didn't ask for one",
               clientIDValue(of: authedURL) == nil)

        guard let authedCommentsURL = SoundCloudAPI.shared.urlForSelfTest(
            "tracks/1/comments", queryItems: SoundCloudAPI.commentsQueryItems(limit: 100)
        ) else {
            report.failures.append("buildURL returned nil for tracks/1/comments (signed in)")
            return
        }
        expect(&report, "signed in: a declared client_id is emptied, never populated",
               clientIDValue(of: authedCommentsURL) == "")

        let authedRequest = SoundCloudAPI.shared.requestForSelfTest(authedURL)
        expect(&report, "signed in: the credential is in the Authorization header",
               authedRequest.value(forHTTPHeaderField: "Authorization") == "OAuth \(marker)")

        SoundCloudAPI.credentials = StubSource(token: nil)

        guard let anonURL = SoundCloudAPI.shared.urlForSelfTest("mixed-selections") else {
            report.failures.append("buildURL returned nil for mixed-selections (signed out)")
            return
        }
        let anonClientID = clientIDValue(of: anonURL)
        expect(&report, "signed out: a real client_id is attached",
               (anonClientID?.isEmpty == false))

        guard let anonCommentsURL = SoundCloudAPI.shared.urlForSelfTest(
            "tracks/1/comments", queryItems: SoundCloudAPI.commentsQueryItems(limit: 100)
        ) else {
            report.failures.append("buildURL returned nil for tracks/1/comments (signed out)")
            return
        }
        expect(&report, "signed out: a declared empty client_id is upgraded to the real one",
               clientIDValue(of: anonCommentsURL) == anonClientID)

        let anonRequest = SoundCloudAPI.shared.requestForSelfTest(anonURL)
        expect(&report, "signed out: no Authorization header is sent",
               anonRequest.value(forHTTPHeaderField: "Authorization") == nil)

        if let anonClientID, !anonClientID.isEmpty {
            expect(&report, "the anonymous client_id never appears on an authenticated URL",
                   !authedURL.absoluteString.contains(anonClientID)
                       && !authedCommentsURL.absoluteString.contains(anonClientID))
        }

        for url in [authedURL, authedCommentsURL, anonURL, anonCommentsURL] {
            let names = Set((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { $0.name.lowercased() })
            expect(&report, "client_id policy: still no credential parameter",
                   names.isDisjoint(with: SoundCloudAPI.forbiddenQueryNames))
        }
    }

    private static func commentsEndpointCases(_ report: inout Report) {
        let items = SoundCloudAPI.commentsQueryItems(limit: 100)
        let names = Set(items.map(\.name))
        expect(&report, "comments: sends `threaded` (required — api-v2 400s without it)",
               names.contains("threaded"))
        expect(&report, "comments: requests reply rows",
               items.first(where: { $0.name == "threaded" })?.value == "1")
        expect(&report, "comments: sends `client_id` (required — api-v2 400s without it)",
               names.contains("client_id"))
        expect(&report, "comments: does not send the inert `filter_replies`",
               !names.contains("filter_replies"))
    }

    private static func challengeDetectionCases(_ report: inout Report) {
        let url = URL(string: "https://api-v2.soundcloud.com/me")!
        func response(contentType: String, headers: [String: String] = [:]) -> HTTPURLResponse {
            var fields = headers
            fields["Content-Type"] = contentType
            return HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: fields)!
        }

        let json = Data(#"{"description":"DataDome is not present here"}"#.utf8)
        expect(&report, "challenge: ordinary JSON is ignored",
               !SoundCloudAPI.isBotChallenge(response: response(contentType: "application/json"), data: json))

        let challenge = Data(#"<html><script src="https://geo.captcha-delivery.com/captcha.js"></script></html>"#.utf8)
        expect(&report, "challenge: HTML CAPTCHA interstitial is detected",
               SoundCloudAPI.isBotChallenge(response: response(contentType: "text/html"), data: challenge))

        let harmlessHTML = Data(#"<html><body>SoundCloud maintenance</body></html>"#.utf8)
        expect(&report, "challenge: unrelated HTML is ignored",
               !SoundCloudAPI.isBotChallenge(response: response(contentType: "text/html"), data: harmlessHTML))

        expect(&report, "challenge: DataDome response header is detected",
               SoundCloudAPI.isBotChallenge(
                   response: response(contentType: "application/json", headers: ["X-DataDome": "protected"]),
                   data: Data()
               ))
    }
}

extension SoundCloudAPI {
    nonisolated static let likeNotificationTrackKey = "track"
    nonisolated static let likeNotificationLikedKey = "liked"

    func urlForSelfTest(_ path: String, queryItems: [URLQueryItem] = []) -> URL? {
        buildURL(path, queryItems: queryItems)
    }

    func requestForSelfTest(_ url: URL) -> URLRequest {
        authorizedRequest(url)
    }
}
