import Foundation

let repo = CommandLine.arguments[1]
let outDirectory = CommandLine.arguments[2]
let src = try String(contentsOfFile: "\(repo)/SoundingTV.swiftpm/Sources/Core/DJ/DJSessionDirector.swift", encoding: .utf8)
let chars = Array(src.utf8)

func block(_ startPattern: String) -> String {
    guard let range = src.range(of: startPattern) else { fatalError("missing \(startPattern)") }
    let i = src.utf8.distance(from: src.startIndex, to: range.lowerBound)
    var lineStart = i
    while lineStart > 0, chars[lineStart - 1] != UInt8(ascii: "\n") { lineStart -= 1 }
    var k = i
    while chars[k] != UInt8(ascii: "{") { k += 1 }
    var depth = 0
    while true {
        if chars[k] == UInt8(ascii: "{") { depth += 1 }
        if chars[k] == UInt8(ascii: "}") {
            depth -= 1
            if depth == 0 { return String(decoding: chars[lineStart...k], as: UTF8.self) }
        }
        k += 1
    }
}

let parts = [
    "nonisolated static func earliestExit(position",
    "nonisolated static func decidePlan(",
    "private nonisolated static func decideTrimmedPlan(",
    "nonisolated static func classifyStructure(",
    "nonisolated static func lastFullBarEnd(",
    "nonisolated static func pullCutBack("
].map(block)
let lead = "    nonisolated static let midTrackPlanningLead: TimeInterval = 8\n    nonisolated static let cutBodyDecibels: Float = 9\n"
guard let policy = src.range(of: "enum EngineHandoverPolicy") else { fatalError("missing EngineHandoverPolicy") }
let text = "import Foundation\n\nenum DJSessionDirector {\n" + lead + parts.joined(separator: "\n\n") + "\n}\n\n" + src[policy.lowerBound...]
try text.write(toFile: "\(outDirectory)/Director.swift", atomically: true, encoding: .utf8)
