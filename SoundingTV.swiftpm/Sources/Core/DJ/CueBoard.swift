import Foundation
import SwiftUI

@MainActor
final class CueBoard: ObservableObject {
    @Published private(set) var sheet: CueSheet = .empty(trackId: "")

    private let store: CueStore

    init(store: CueStore = .shared) {
        self.store = store
    }

    private struct LoadKey: Equatable {
        let trackId: String
        let sampleCount: Int
        let durationBucket: Int
    }

    private var loadedKey: LoadKey?
    private var lastInput: CueSuggester.Input?
    private var loadTask: Task<Void, Never>?

    func ensureLoaded(
        trackId: String?,
        duration: TimeInterval,
        waveform: Waveform?,
        beatGrid: BeatGrid? = nil,
        sections: [TrackSection] = []
    ) {
        guard let trackId, duration.isFinite, duration > 0 else {
            reset()
            return
        }
        let input = CueSuggester.Input(
            trackId: trackId,
            duration: duration,
            envelope: waveform?.samples ?? [],
            beatGrid: beatGrid,
            sections: sections
        )
        let key = LoadKey(trackId: trackId, sampleCount: input.envelope.count, durationBucket: Int(duration.rounded()))
        guard key != loadedKey else { return }
        loadedKey = key
        lastInput = input
        runLoad(input, key: key)
    }

    private func runLoad(_ input: CueSuggester.Input, key: LoadKey) {
        loadTask?.cancel()
        let store = self.store
        loadTask = Task { [weak self] in
            let sheet = await store.sheet(for: input)
            guard let self, !Task.isCancelled, self.loadedKey == key else { return }
            self.sheet = sheet
        }
    }

    private func reload() async {
        guard let lastInput else { return }
        loadTask?.cancel()
        loadTask = nil
        sheet = await store.sheet(for: lastInput)
    }

    private func reset() {
        loadTask?.cancel()
        loadTask = nil
        loadedKey = nil
        lastInput = nil
        sheet = .empty(trackId: "")
    }

    @discardableResult
    func addMemoryCue(trackId: String, positionMillis: Int64, label: String = "") async -> CuePoint {
        let cue = await store.addMemoryCue(trackId: trackId, positionMillis: positionMillis, label: label)
        await reload()
        return cue
    }

    @discardableResult
    func setHotCue(trackId: String, index: Int, positionMillis: Int64, label: String = "") async -> CuePoint {
        let cue = await store.setHotCue(trackId: trackId, index: index, positionMillis: positionMillis, label: label)
        await reload()
        return cue
    }

    @discardableResult
    func setMixIn(trackId: String, positionMillis: Int64) async -> CuePoint {
        let cue = await store.setMixIn(trackId: trackId, positionMillis: positionMillis)
        await reload()
        return cue
    }

    @discardableResult
    func setMixOut(trackId: String, positionMillis: Int64) async -> CuePoint {
        let cue = await store.setMixOut(trackId: trackId, positionMillis: positionMillis)
        await reload()
        return cue
    }

    func rename(_ cue: CuePoint, to label: String) async {
        var updated = cue
        updated.label = label
        updated.origin = .user
        await store.upsert(updated)
        await reload()
    }

    func reposition(_ cue: CuePoint, toMillis positionMillis: Int64) async {
        var updated = cue
        updated.origin = .user
        updated.positionMillis = max(0, positionMillis)
        if let end = updated.endMillis, end <= updated.positionMillis {
            updated.endMillis = updated.positionMillis + 1
        }
        await store.upsert(updated)
        await reload()
    }

    func delete(_ cue: CuePoint) async {
        await store.delete(cueId: cue.id)
        await reload()
    }

    @discardableResult
    func promote(
        _ suggestion: CueSuggestion,
        asKind: CueKind? = nil,
        hotCueIndex: Int? = nil,
        label: String? = nil
    ) async -> CuePoint {
        let cue = await store.promote(suggestion, asKind: asKind, hotCueIndex: hotCueIndex, label: label)
        await reload()
        return cue
    }

    func dismiss(_ suggestion: CueSuggestion) async {
        await store.dismiss(suggestion)
        await reload()
    }

    func freeHotSlot() -> Int? {
        let taken = Set(sheet.userCues.compactMap(\.hotCueIndex))
        return (0..<CuePoint.hotCueSlotCount).first { !taken.contains($0) }
    }

    @discardableResult
    func acceptAsHotCue(_ suggestion: CueSuggestion) async -> CuePoint? {
        guard let slot = freeHotSlot() else { return nil }
        let cue = await store.promote(suggestion, asKind: .hotCue, hotCueIndex: slot)
        await reload()
        return cue
    }

    func assignHotSlot(_ cue: CuePoint, slot: Int) async {
        let moved = CuePoint(
            trackId: cue.trackId,
            kind: cue.kind == .loop ? .loop : .hotCue,
            positionMillis: cue.positionMillis,
            endMillis: cue.endMillis,
            hotCueIndex: slot,
            label: cue.label,
            color: cue.kind == .loop ? cue.color : nil,
            createdAtMillis: cue.createdAtMillis,
            promotedFrom: cue.promotedFrom
        )
        if moved.id != cue.id { await store.delete(cueId: cue.id) }
        await store.upsert(moved)
        await reload()
    }

    func refresh() async {
        await reload()
    }
}

extension CueColor {
    var color: Color {
        Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }
}

enum CueNavigation {
    static func next(after currentSeconds: TimeInterval, positions: [TimeInterval], epsilon: TimeInterval = 0.25) -> TimeInterval? {
        let sorted = positions.sorted()
        guard !sorted.isEmpty else { return nil }
        return sorted.first { $0 > currentSeconds + epsilon } ?? sorted.first
    }

    static func previous(before currentSeconds: TimeInterval, positions: [TimeInterval], epsilon: TimeInterval = 0.25) -> TimeInterval? {
        let sorted = positions.sorted()
        guard !sorted.isEmpty else { return nil }
        return sorted.last { $0 < currentSeconds - epsilon } ?? sorted.last
    }
}
