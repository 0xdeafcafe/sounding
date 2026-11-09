import Foundation

struct SetIntent: Codable, Sendable, Equatable {
    var text: String
    var startEnergy: Int
    var targetEnergy: Int
    var rampMinutes: Double?
    var vocalsAfterMinutes: Double?
    var minBPM: Double?
    var maxBPM: Double?
    var durationMinutes: Double?

    static let defaultRampMinutes = 60.0
    static let noVocalsEver = 1_000_000.0

    init(
        text: String,
        startEnergy: Int,
        targetEnergy: Int,
        rampMinutes: Double? = nil,
        vocalsAfterMinutes: Double? = nil,
        minBPM: Double? = nil,
        maxBPM: Double? = nil,
        durationMinutes: Double? = nil
    ) {
        self.text = text
        self.startEnergy = Self.clampedEnergy(startEnergy)
        self.targetEnergy = Self.clampedEnergy(targetEnergy)
        self.rampMinutes = rampMinutes.map { max(1, $0) }
        self.vocalsAfterMinutes = vocalsAfterMinutes.map { max(0, $0) }
        if let minBPM, let maxBPM, minBPM > maxBPM {
            self.minBPM = maxBPM
            self.maxBPM = minBPM
        } else {
            self.minBPM = minBPM
            self.maxBPM = maxBPM
        }
        self.durationMinutes = durationMinutes.map { max(1, $0) }
    }

    static func clampedEnergy(_ value: Int) -> Int { min(10, max(1, value)) }

    var effectiveRampMinutes: Double {
        rampMinutes ?? durationMinutes.map { $0 * 0.75 } ?? Self.defaultRampMinutes
    }

    func targetEnergy(atMinute minute: Double) -> Int {
        let progress = min(1, max(0, minute / effectiveRampMinutes))
        let value = Double(startEnergy) + Double(targetEnergy - startEnergy) * progress
        return Self.clampedEnergy(Int(value.rounded()))
    }

    func allowsVocals(atMinute minute: Double) -> Bool {
        guard let vocalsAfterMinutes else { return true }
        return minute >= vocalsAfterMinutes
    }

    func bpmOutsideRange(_ bpm: Double?) -> Double {
        guard let bpm, bpm > 0 else { return 0 }
        let folded = [bpm, bpm * 2, bpm / 2].filter { $0 >= 60 && $0 <= 200 }
        let candidates = folded.isEmpty ? [bpm] : folded
        return candidates.map { value in
            if let minBPM, value < minBPM { return minBPM - value }
            if let maxBPM, value > maxBPM { return value - maxBPM }
            return 0
        }.min() ?? 0
    }

    var summaryParts: [String] {
        var parts: [String] = []
        if startEnergy == targetEnergy {
            parts.append("Holds at energy \(startEnergy)")
        } else {
            let verb = targetEnergy > startEnergy ? "Builds" : "Winds down"
            let over = Self.minutesPhrase(effectiveRampMinutes)
            parts.append("\(verb) from energy \(startEnergy) to \(targetEnergy) over \(over)")
        }
        if let vocalsAfterMinutes {
            parts.append(vocalsAfterMinutes >= Self.noVocalsEver ? "No vocals" : "No vocals for \(Self.minutesPhrase(vocalsAfterMinutes))")
        }
        switch (minBPM, maxBPM) {
        case let (low?, high?): parts.append("\(Int(low.rounded()))–\(Int(high.rounded())) BPM")
        case let (low?, nil): parts.append("Over \(Int(low.rounded())) BPM")
        case let (nil, high?): parts.append("Under \(Int(high.rounded())) BPM")
        default: break
        }
        if let durationMinutes { parts.append("\(Self.minutesPhrase(durationMinutes)) long") }
        return parts
    }

    var summary: String { summaryParts.joined(separator: " · ") }

    static func minutesPhrase(_ minutes: Double) -> String {
        let rounded = Int(minutes.rounded())
        if rounded >= 60, rounded % 60 == 0 {
            let hours = rounded / 60
            return hours == 1 ? "1 hour" : "\(hours) hours"
        }
        if rounded >= 90 {
            let hours = Double(rounded) / 60
            return String(format: "%.1f hours", hours)
        }
        return rounded == 1 ? "1 minute" : "\(rounded) minutes"
    }
}

struct SetIntentDraft: Sendable, Equatable {
    var startEnergy: Int
    var targetEnergy: Int
    var reachTargetAt: String?
    var reachTargetInMinutes: Int?
    var noVocalsUntil: String?
    var noVocalsForMinutes: Int?
    var noVocalsAtAll: Bool
    var minBPM: Int?
    var maxBPM: Int?
    var durationMinutes: Int?

    init(
        startEnergy: Int,
        targetEnergy: Int,
        reachTargetAt: String? = nil,
        reachTargetInMinutes: Int? = nil,
        noVocalsUntil: String? = nil,
        noVocalsForMinutes: Int? = nil,
        noVocalsAtAll: Bool = false,
        minBPM: Int? = nil,
        maxBPM: Int? = nil,
        durationMinutes: Int? = nil
    ) {
        self.startEnergy = startEnergy
        self.targetEnergy = targetEnergy
        self.reachTargetAt = reachTargetAt
        self.reachTargetInMinutes = reachTargetInMinutes
        self.noVocalsUntil = noVocalsUntil
        self.noVocalsForMinutes = noVocalsForMinutes
        self.noVocalsAtAll = noVocalsAtAll
        self.minBPM = minBPM
        self.maxBPM = maxBPM
        self.durationMinutes = durationMinutes
    }

    func intent(text: String, now: Date, calendar: Calendar = .current) -> SetIntent {
        let ramp = reachTargetInMinutes.map(Double.init)
            ?? reachTargetAt.flatMap { SetIntentParser.minutes(untilClock: $0, now: now, calendar: calendar) }
        let vocals: Double?
        if noVocalsAtAll {
            vocals = SetIntent.noVocalsEver
        } else {
            vocals = noVocalsForMinutes.map(Double.init)
                ?? noVocalsUntil.flatMap { SetIntentParser.minutes(untilClock: $0, now: now, calendar: calendar) }
        }
        func bpm(_ value: Int?) -> Double? {
            guard let value, (60...200).contains(value) else { return nil }
            return Double(value)
        }
        return SetIntent(
            text: text,
            startEnergy: startEnergy,
            targetEnergy: targetEnergy,
            rampMinutes: ramp,
            vocalsAfterMinutes: vocals,
            minBPM: bpm(minBPM),
            maxBPM: bpm(maxBPM),
            durationMinutes: durationMinutes.flatMap { $0 > 0 ? Double($0) : nil }
        )
    }
}

enum SetIntentParser {
    static func parse(_ raw: String, now: Date, calendar: Calendar = .current) -> SetIntent? {
        let text = raw.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "–", with: "-")
        guard text.contains(where: \.isLetter) || text.contains(where: \.isNumber) else { return nil }
        var draft = SetIntentDraft(startEnergy: 5, targetEnergy: 5)
        var understood = false

        let warm = ["warm-up", "warm up", "warmup", "chill", "easy", "gentle", "mellow", "slow start", "start slow"]
        let wind = ["wind down", "winding down", "cool down", "cool-down", "comedown", "come down", "after hours", "sunrise"]
        let peak = ["peak", "banger", "bangers", "big room", "high energy", "go hard", "all out", "party"]
        let build = ["build", "building", "climb", "ramp", "rising", "lift"]

        if contains(text, wind) {
            draft.startEnergy = 7
            draft.targetEnergy = 3
            understood = true
        } else {
            if contains(text, warm) { draft.startEnergy = 3; draft.targetEnergy = 4; understood = true }
            if contains(text, peak) { draft.targetEnergy = 9; understood = true }
            if contains(text, build) { draft.targetEnergy = max(draft.targetEnergy, 8); understood = true }
            if contains(text, peak), !contains(text, warm), !contains(text, build) { draft.startEnergy = 8 }
        }

        if let clock = capture(text, #"\b(?:by|at|for|until|till|til)\s+((?:midnight|noon|\d{1,2}(?::\d{2})?\s*(?:am|pm)?))"#),
           !isFollowedByDuration(text, clock) {
            if let range = text.range(of: clock), !text[..<range.lowerBound].hasSuffix("until "), !precededByVocals(text, clock) {
                draft.reachTargetAt = clock
                understood = true
            }
        }
        if let minutes = capture(text, #"(?:peak|build|building|climb)\w*\s+(?:in|over|after)\s+(\d+\s*(?:hours?|hrs?|h|minutes?|mins?|m))\b"#).flatMap(durationMinutes) {
            draft.reachTargetInMinutes = minutes
            understood = true
        }

        if let vocal = capture(text, #"(?:no|without|zero)\s+(?:vocals?|singing|voices?|lyrics)\s+(?:until|till|til|before)\s+(midnight|noon|\d{1,2}(?::\d{2})?\s*(?:am|pm)?)"#) {
            draft.noVocalsUntil = vocal
            understood = true
        } else if let vocalFor = capture(text, #"(?:no|without|zero)\s+(?:vocals?|singing|voices?|lyrics)\s+for\s+(?:the\s+)?(?:first\s+)?(\d+\s*(?:hours?|hrs?|h|minutes?|mins?|m)|an?\s+hour|half\s+an\s+hour)"#).flatMap(durationMinutes) {
            draft.noVocalsForMinutes = vocalFor
            understood = true
        } else if text.range(of: #"(?:no|without|zero)\s+(?:vocals?|singing|voices?)|instrumental"#, options: .regularExpression) != nil {
            draft.noVocalsAtAll = true
            understood = true
        }

        if let range = captures(text, #"(\d{2,3})\s*(?:-|to)\s*(\d{2,3})\s*bpm"#), range.count == 2 {
            draft.minBPM = Int(range[0])
            draft.maxBPM = Int(range[1])
            understood = true
        } else if let around = capture(text, #"(?:around|about|~|at)\s*(\d{2,3})\s*bpm"#).flatMap(Int.init) {
            draft.minBPM = around - 3
            draft.maxBPM = around + 3
            understood = true
        } else if let under = capture(text, #"(?:under|below|less than|max)\s*(\d{2,3})\s*bpm"#).flatMap(Int.init) {
            draft.maxBPM = under
            understood = true
        } else if let over = capture(text, #"(?:over|above|more than|min)\s*(\d{2,3})\s*bpm"#).flatMap(Int.init) {
            draft.minBPM = over
            understood = true
        } else if let exact = capture(text, #"(\d{2,3})\s*bpm"#).flatMap(Int.init) {
            draft.minBPM = exact - 3
            draft.maxBPM = exact + 3
            understood = true
        }

        if let length = capture(text, #"(\d+(?:\.\d+)?\s*(?:hours?|hrs?|h|minutes?|mins?)|an?\s+hour|half\s+an\s+hour)\s+(?:set|long|mix)"#).flatMap(durationMinutes)
            ?? capture(text, #"for\s+(\d+(?:\.\d+)?\s*(?:hours?|hrs?|minutes?|mins?)|an?\s+hour)"#).flatMap(durationMinutes) {
            draft.durationMinutes = length
            understood = true
        }

        guard understood else { return nil }
        return draft.intent(text: raw.trimmingCharacters(in: .whitespacesAndNewlines), now: now, calendar: calendar)
    }

    static func minutes(untilClock raw: String, now: Date, calendar: Calendar = .current) -> Double? {
        guard let (hour, minute, meridiem) = clock(raw) else { return nil }
        let hours: [Int]
        switch meridiem {
        case "am": hours = [hour % 12]
        case "pm": hours = [hour % 12 + 12]
        case "24h": hours = [hour]
        default: hours = hour <= 12 ? [hour % 24, (hour % 12) + 12] : [hour]
        }
        let options = hours.compactMap { h -> Date? in
            calendar.nextDate(after: now, matching: DateComponents(hour: h, minute: minute), matchingPolicy: .nextTime)
        }
        guard let soonest = options.min() else { return nil }
        let minutes = soonest.timeIntervalSince(now) / 60
        return minutes > 0 ? minutes : nil
    }

    static func clock(_ raw: String) -> (Int, Int, String?)? {
        let text = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if text == "midnight" { return (0, 0, "am") }
        if text == "noon" { return (12, 0, "pm") }
        if let parts = captures(text, #"^(\d{2}):(\d{2})$"#), let hour = Int(parts[0]), let minute = Int(parts[1]), hour < 24, minute < 60 {
            return (hour, minute, "24h")
        }
        if let parts = captures(text, #"^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$"#), let hour = Int(parts[0]), hour < 24 {
            let minute = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            let meridiem = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
            guard minute < 60 else { return nil }
            return (hour, minute, meridiem)
        }
        return nil
    }

    static func durationMinutes(_ raw: String) -> Int? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("half") { return 30 }
        if text.hasPrefix("an hour") || text.hasPrefix("a hour") { return 60 }
        guard let parts = captures(text, #"^(\d+(?:\.\d+)?)\s*(\w+)$"#), parts.count == 2, let value = Double(parts[0]) else { return nil }
        let unit = parts[1]
        if unit.hasPrefix("h") { return Int((value * 60).rounded()) }
        return Int(value.rounded())
    }

    private static func contains(_ text: String, _ words: [String]) -> Bool {
        words.contains { word in
            text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))", options: .regularExpression) != nil
        }
    }

    private static func isFollowedByDuration(_ text: String, _ clock: String) -> Bool {
        guard let range = text.range(of: clock) else { return false }
        let rest = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return rest.hasPrefix("bpm") || rest.hasPrefix("min") || rest.hasPrefix("hour") || rest.hasPrefix("hr")
    }

    private static func precededByVocals(_ text: String, _ clock: String) -> Bool {
        guard let range = text.range(of: clock) else { return false }
        let before = text[..<range.lowerBound]
        let window = before.suffix(28)
        return window.contains("vocal") || window.contains("singing") || window.contains("voice")
    }

    private static func capture(_ text: String, _ pattern: String) -> String? {
        captures(text, pattern)?.first
    }

    private static func captures(_ text: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { i in
            Range(match.range(at: i), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespaces) } ?? ""
        }
    }
}
