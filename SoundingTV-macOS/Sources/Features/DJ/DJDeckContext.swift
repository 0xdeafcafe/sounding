import SwiftUI

struct DJDeckSlot: Equatable, Identifiable {
    let deck: MixEngine.Deck
    var trackId: String?
    var title: String = ""
    var bpm: Double?
    var key: String?
    var isOnAir = false

    var id: Int { deck.rawValue }
    var letter: String { deck == .a ? "A" : "B" }
}

struct DJPlayedTrack: Equatable, Identifiable {
    let id: String
    let title: String
    var artworkURL: URL?
    var detail: String
}

enum DJLoadResult: Equatable {
    case loaded
    case refused(String)
}

@MainActor
struct DJDeckContext {
    var decks: [DJDeckSlot] = []
    var playedTonight: [DJPlayedTrack] = []
    var incoming: MixEngine.Deck? = nil
    var load: (String, MixEngine.Deck) -> Void = { _, _ in }
    var playNext: (String) -> Void = { _ in }
    var addToAutoMix: (String) -> Void = { _ in }
    var planTransition: (String) -> Void = { _ in }

    static let none = DJDeckContext()

    func slot(_ deck: MixEngine.Deck) -> DJDeckSlot? { decks.first { $0.deck == deck } }

    func deck(holding trackId: String) -> DJDeckSlot? { decks.first { $0.trackId == trackId } }

    var current: DJDeckSlot? {
        decks.first { $0.isOnAir && $0.trackId != nil } ?? decks.first { $0.trackId != nil }
    }

    var target: DJDeckSlot? {
        guard let current else { return nil }
        return decks.first { $0.deck != current.deck && $0.trackId != nil && !$0.isOnAir }
    }

    func request(_ trackId: String, onto deck: MixEngine.Deck) -> DJLoadResult {
        if let slot = slot(deck), slot.isOnAir, slot.trackId != nil, slot.trackId != trackId {
            return .refused("\(slot.letter) is on air · it won’t be replaced mid-track")
        }
        load(trackId, deck)
        return .loaded
    }

    static func live(tracks: @escaping @MainActor (String) -> Track?) -> DJDeckContext {
        let engine = MixEngine.shared
        let registry = MacDeckTrackRegistry.shared
        let decks = MixEngine.Deck.allCases.map { deck -> DJDeckSlot in
            let state = engine[deck]
            let track = registry.track(for: deck)
            return DJDeckSlot(
                deck: deck,
                trackId: state.trackId ?? track?.id,
                title: track?.title ?? "",
                bpm: nil,
                key: nil,
                isOnAir: state.isPlaying && state.gain > 0.01
            )
        }
        return DJDeckContext(
            decks: decks,
            playedTonight: [],
            incoming: nil,
            load: { id, deck in
                guard let track = tracks(id) else { return }
                Task { try? await MacMixLoader.load(track, into: deck) }
            },
            playNext: { id in
                guard let track = tracks(id) else { return }
                MacPlayback.playNext([track])
            },
            addToAutoMix: { id in
                guard let track = tracks(id) else { return }
                MacPlayback.playLast([track])
            }
        )
    }
}

enum DJFit: Equatable {
    case fits
    case keyClash
    case tempoClash
    case unknown

    var label: String {
        switch self {
        case .fits: return "Fits"
        case .keyClash: return "Key clash"
        case .tempoClash: return "Tempo clash"
        case .unknown: return ""
        }
    }

    static func evaluate(bpm: Double?, key: String?, against reference: (bpm: Double?, key: String?)) -> DJFit {
        guard bpm != nil || key != nil, reference.bpm != nil || reference.key != nil else { return .unknown }
        if let a = key, let b = reference.key, !keysCompatible(a, b) { return .keyClash }
        if let a = bpm, let b = reference.bpm, !tempoCompatible(a, b) { return .tempoClash }
        return .fits
    }

    static func keysCompatible(_ a: String, _ b: String) -> Bool {
        guard let left = camelot(a), let right = camelot(b) else { return true }
        if left == right { return true }
        if left.letter == right.letter {
            let distance = abs(left.number - right.number)
            return distance == 1 || distance == 11
        }
        return left.number == right.number
    }

    static func tempoCompatible(_ a: Double, _ b: Double, tolerance: Double = 0.06) -> Bool {
        guard a > 0, b > 0 else { return true }
        return [b, b * 2, b / 2].contains { abs(a - $0) / $0 <= tolerance }
    }

    private static func camelot(_ text: String) -> (number: Int, letter: Character)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard let letter = trimmed.last, letter == "A" || letter == "B", let number = Int(trimmed.dropLast()), (1...12).contains(number) else { return nil }
        return (number, letter)
    }
}

struct DJKeyBadge: View {
    let key: String?
    var dimmed = false

    var body: some View {
        if let key {
            Text(key)
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(Self.color(for: key))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Self.color(for: key).opacity(dimmed ? 0.12 : 0.2), in: RoundedRectangle(cornerRadius: 4))
                .accessibilityLabel("Key \(key)")
        } else {
            Text("–").foregroundStyle(.secondary)
        }
    }

    static func color(for key: String) -> Color {
        let number = Int(key.trimmingCharacters(in: .letters)) ?? 1
        return Color(hue: Double((number - 1) % 12) / 12 * 0.85 + 0.12, saturation: 0.55, brightness: 0.95)
    }
}
