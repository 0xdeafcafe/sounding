import Foundation

struct DJProfileID: Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
    init(stringLiteral value: String) { self.rawValue = value }
    var description: String { rawValue }

    static let wedding: DJProfileID = "wedding"
    static let automatic: DJProfileID = "automatic"
    static let junkie: DJProfileID = "junkie"
}
