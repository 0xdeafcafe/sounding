import Foundation
import AudioToolbox

struct MacEffectComponentID: Codable, Hashable, Sendable {
    var type: UInt32
    var subType: UInt32
    var manufacturer: UInt32

    init(type: UInt32, subType: UInt32, manufacturer: UInt32) {
        self.type = type
        self.subType = subType
        self.manufacturer = manufacturer
    }

    init(_ effect: MixEngine.LoadedEffect) {
        self.init(type: effect.componentType, subType: effect.componentSubType, manufacturer: effect.componentManufacturer)
    }

    var description: AudioComponentDescription {
        AudioComponentDescription(
            componentType: type,
            componentSubType: subType,
            componentManufacturer: manufacturer,
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }
}

struct MacEffectPreset: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var effectName: String
    var effectManufacturer: String
    var component: MacEffectComponentID
    var state: Data
}

struct MacEffectSlotMemory: Codable, Equatable, Sendable {
    var effectName: String
    var effectManufacturer: String
    var component: MacEffectComponentID
    var state: Data?
    var isBypassed: Bool
}

extension MixEngine.EffectSlot {
    static let all: [MixEngine.EffectSlot] = [.deck(.a), .deck(.b), .send]

    var storageKey: String {
        switch self {
        case .deck(let deck): return "deck\(deck.label)"
        case .send: return "send"
        }
    }

    var title: String {
        switch self {
        case .deck(let deck): return "Deck \(deck.label)"
        case .send: return "Send"
        }
    }
}

@MainActor
final class MacEffectPresetStore: ObservableObject {
    static let shared = MacEffectPresetStore()

    @Published private(set) var presets: [String: [MacEffectPreset]] = [:]
    private(set) var memory: [String: MacEffectSlotMemory] = [:]
    private let fileURL: URL

    init(directory: URL = MacEffectPresetStore.defaultDirectory()) {
        fileURL = directory.appendingPathComponent("effects.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: fileURL), let archive = try? JSONDecoder().decode(Archive.self, from: data) {
            presets = archive.presets
            memory = archive.memory
        }
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("DeckEffects", isDirectory: true)
    }

    func presets(for slot: MixEngine.EffectSlot) -> [MacEffectPreset] {
        presets[slot.storageKey] ?? []
    }

    func memory(for slot: MixEngine.EffectSlot) -> MacEffectSlotMemory? {
        memory[slot.storageKey]
    }

    func save(_ preset: MacEffectPreset, for slot: MixEngine.EffectSlot) {
        var list = presets(for: slot).filter { $0.name.localizedCaseInsensitiveCompare(preset.name) != .orderedSame }
        list.append(preset)
        list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        presets[slot.storageKey] = list
        persist()
    }

    func delete(_ preset: MacEffectPreset, for slot: MixEngine.EffectSlot) {
        presets[slot.storageKey] = presets(for: slot).filter { $0.id != preset.id }
        persist()
    }

    func remember(_ value: MacEffectSlotMemory?, for slot: MixEngine.EffectSlot) {
        guard memory[slot.storageKey] != value else { return }
        memory[slot.storageKey] = value
        persist()
    }

    private func persist() {
        let archive = Archive(presets: presets, memory: memory)
        guard let data = try? JSONEncoder().encode(archive) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func encodeState(_ state: [String: Any]?) -> Data? {
        guard let state, PropertyListSerialization.propertyList(state, isValidFor: .binary) else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
    }

    static func decodeState(_ data: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }

    // MARK: - Archive

    private struct Archive: Codable {
        var presets: [String: [MacEffectPreset]]
        var memory: [String: MacEffectSlotMemory]

        init(presets: [String: [MacEffectPreset]], memory: [String: MacEffectSlotMemory]) {
            self.presets = presets
            self.memory = memory
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let lossyPresets = (try? container.decode([String: [Lossy<MacEffectPreset>]].self, forKey: .presets)) ?? [:]
            presets = lossyPresets.mapValues { $0.compactMap(\.value) }
            let lossyMemory = (try? container.decode([String: Lossy<MacEffectSlotMemory>].self, forKey: .memory)) ?? [:]
            memory = lossyMemory.compactMapValues(\.value)
        }
    }

    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: Decoder) throws {
            value = try? Value(from: decoder)
        }
    }
}
