import Foundation

enum QueueReorder {
    struct Move: Equatable {
        let from: Int
        let to: Int
    }

    static func move(source: Int, before target: Int?, count: Int) -> Move? {
        guard count > 1, (0..<count).contains(source) else { return nil }
        let final: Int
        if let target {
            guard (0...count).contains(target) else { return nil }
            final = target > source ? target - 1 : target
        } else {
            final = count - 1
        }
        guard final != source else { return nil }
        return Move(from: source, to: final)
    }

    static func moveByOne(source: Int, up: Bool, within range: Range<Int>) -> Move? {
        let target = up ? source - 1 : source + 1
        guard range.contains(source), range.contains(target) else { return nil }
        return Move(from: source, to: target)
    }
}
