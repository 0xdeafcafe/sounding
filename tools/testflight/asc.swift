import CryptoKit
import Foundation

let appID = "6767263473"

struct ASCError: Error, CustomStringConvertible {
    let description: String
}

func env(_ name: String) throws -> String {
    guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
        throw ASCError(description: "\(name) is not set")
    }
    return value
}

func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func token() throws -> String {
    let keyID = try env("ASC_KEY_ID")
    let issuer = try env("ASC_ISSUER_ID")
    let path = ProcessInfo.processInfo.environment["ASC_KEY_PATH"]
        ?? "\(NSHomeDirectory())/.appstoreconnect/private_keys/AuthKey_\(keyID).p8"
    let key = try P256.Signing.PrivateKey(pemRepresentation: String(contentsOfFile: path, encoding: .utf8))
    let now = Int(Date().timeIntervalSince1970)
    let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "kid": keyID, "typ": "JWT"])
    let claims = try JSONSerialization.data(withJSONObject: ["iss": issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"])
    let input = base64URL(header) + "." + base64URL(claims)
    let signature = try key.signature(for: Data(input.utf8))
    return input + "." + base64URL(signature.rawRepresentation)
}

@discardableResult
func call(_ method: String, _ path: String, _ body: [String: Any]? = nil, allow: Set<Int> = []) async throws -> [String: Any] {
    var request = URLRequest(url: URL(string: path.hasPrefix("http") ? path : "https://api.appstoreconnect.apple.com" + path)!)
    request.httpMethod = method
    request.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
    if let body {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if !(200..<300).contains(status) && !allow.contains(status) {
        throw ASCError(description: "\(method) \(path) -> \(status): \(String(decoding: data, as: UTF8.self).prefix(400))")
    }
    if data.isEmpty { return [:] }
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

func items(_ json: [String: Any]) -> [[String: Any]] {
    json["data"] as? [[String: Any]] ?? []
}

func attributes(_ item: [String: Any]) -> [String: Any] {
    item["attributes"] as? [String: Any] ?? [:]
}

func latestBuildNumber() async throws -> Int {
    let json = try await call("GET", "/v1/builds?filter[app]=\(appID)&sort=-uploadedDate&limit=50&fields[builds]=version")
    return items(json).compactMap { Int(attributes($0)["version"] as? String ?? "") }.max() ?? 0
}

func builds(number: Int) async throws -> [[String: Any]] {
    let json = try await call("GET", "/v1/builds?filter[app]=\(appID)&filter[version]=\(number)&limit=10&fields[builds]=version,processingState,usesNonExemptEncryption")
    return items(json)
}

func ship(number: Int, expected: Int, notesPath: String?) async throws {
    var found: [[String: Any]] = []
    for attempt in 0..<120 {
        found = try await builds(number: number)
        let states = found.map { attributes($0)["processingState"] as? String ?? "?" }
        print("builds \(number): \(found.count)/\(expected) \(states)")
        if found.count >= expected, states.allSatisfy({ $0 == "VALID" }) { break }
        if states.contains(where: { $0 == "INVALID" || $0 == "FAILED" }) {
            throw ASCError(description: "build \(number) failed processing: \(states)")
        }
        if attempt == 119 { throw ASCError(description: "timed out waiting for build \(number)") }
        try await Task.sleep(for: .seconds(30))
    }
    let groups = items(try await call("GET", "/v1/apps/\(appID)/betaGroups?limit=50&fields[betaGroups]=name,isInternalGroup"))
        .filter { (attributes($0)["name"] as? String ?? "").lowercased().contains("friends") }
    let notes = try notesPath.map { try String(contentsOfFile: $0, encoding: .utf8) }
    for build in found {
        let id = build["id"] as? String ?? ""
        if attributes(build)["usesNonExemptEncryption"] as? Bool != false {
            try await call("PATCH", "/v1/builds/\(id)", ["data": ["type": "builds", "id": id, "attributes": ["usesNonExemptEncryption": false]]])
        }
        for group in groups {
            let groupID = group["id"] as? String ?? ""
            let isInternal = attributes(group)["isInternalGroup"] as? Bool ?? false
            try await call("POST", "/v1/betaGroups/\(groupID)/relationships/builds", ["data": [["type": "builds", "id": id]]], allow: isInternal ? [409, 422] : [409])
        }
        if let notes {
            let localizations = items(try await call("GET", "/v1/builds/\(id)/betaBuildLocalizations"))
            if localizations.isEmpty {
                try await call("POST", "/v1/betaBuildLocalizations", ["data": ["type": "betaBuildLocalizations", "attributes": ["whatsNew": notes, "locale": "en-GB"], "relationships": ["build": ["data": ["type": "builds", "id": id]]]]])
            } else {
                for localization in localizations {
                    let localizationID = localization["id"] as? String ?? ""
                    try await call("PATCH", "/v1/betaBuildLocalizations/\(localizationID)", ["data": ["type": "betaBuildLocalizations", "id": localizationID, "attributes": ["whatsNew": notes]]])
                }
            }
        }
        try await call("POST", "/v1/betaAppReviewSubmissions", ["data": ["type": "betaAppReviewSubmissions", "relationships": ["build": ["data": ["type": "builds", "id": id]]]]], allow: [409, 422])
        print("shipped \(id) to \(groups.count) groups")
    }
}

let arguments = CommandLine.arguments.dropFirst()
do {
    switch arguments.first {
    case "latest":
        print(try await latestBuildNumber())
    case "ship":
        let values = Array(arguments.dropFirst())
        guard values.count >= 2, let number = Int(values[0]), let expected = Int(values[1]) else {
            throw ASCError(description: "usage: asc.swift ship <build> <expected platform count> [notes.txt]")
        }
        try await ship(number: number, expected: expected, notesPath: values.count > 2 ? values[2] : nil)
    default:
        throw ASCError(description: "usage: asc.swift latest | ship <build> <count> [notes.txt]")
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
