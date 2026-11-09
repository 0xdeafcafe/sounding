import Foundation

extension MixEngine {
    static let levelLeadBars = 8
    static let levelBodyBars = 16
    static let levelRoomBars = 4

    func transitionLevel(
        outgoing: Deck,
        incoming: Deck,
        anchorSeconds: TimeInterval,
        entrySeconds: TimeInterval,
        outgoingGrid: BeatGrid?,
        incomingGrid: BeatGrid?
    ) -> TransitionLevel {
        let outgoingBody = body(on: outgoing, grid: outgoingGrid, around: anchorSeconds, before: Self.levelLeadBars, after: Self.levelLeadBars)
        let incomingBody = body(on: incoming, grid: incomingGrid, around: entrySeconds, before: 0, after: Self.levelBodyBars)
        var level = TransitionLevel.plan(
            outgoing: outgoingBody,
            incoming: incomingBody,
            outgoingGain: self[outgoing].gain,
            incomingGain: self[incoming].gain
        )
        if let room = body(on: outgoing, grid: outgoingGrid, around: anchorSeconds, before: Self.levelRoomBars, after: 0) {
            level.roomLUFS = room.lufs + 20 * log10(max(1e-6, self[outgoing].gain))
        }
        return level
    }

    private func body(on deck: Deck, grid: BeatGrid?, around seconds: TimeInterval, before: Int, after: Int) -> LocalLoudness.Body? {
        guard let source = mixSource(for: deck) else { return nil }
        let downbeats = (grid?.downbeats ?? []).sorted()
        guard downbeats.count >= 4 else { return nil }
        let index = downbeats.lastIndex { $0 <= seconds + 0.01 } ?? 0
        let bars = max(0, index - before)..<min(downbeats.count, index + after)
        let key = source.url.path
        let cached = LocalLoudnessCache.shared.value(for: key).flatMap { $0.barStarts == downbeats ? $0 : nil }
        let measured = LocalLoudness.measure(source: source, barStarts: downbeats, bars: bars, into: cached)
        LocalLoudnessCache.shared.store(measured, for: key)
        return measured.body(bars: bars)
    }
}
