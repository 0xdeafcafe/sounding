#if os(iOS) || os(macOS)
import AppIntents
import Foundation

struct OutputEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation {
        TypeDisplayRepresentation(name: "Output")
    }

    static let defaultQuery = OutputEntityQuery()

    let id: String
    let name: String
    let deviceClass: DeviceClass

    init(id: String, name: String, deviceClass: DeviceClass) {
        self.id = id
        self.name = name
        self.deviceClass = deviceClass
    }

    init(_ device: OutputDevice) {
        self.init(id: device.id, name: device.name, deviceClass: device.deviceClass)
    }

    var device: OutputDevice {
        id == OutputDevice.localID ? .thisDevice : OutputDevice(id: id, name: name, deviceClass: deviceClass)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: deviceClass.symbolName))
    }
}

struct OutputEntityQuery: EntityQuery {
    func entities(for identifiers: [OutputEntity.ID]) async throws -> [OutputEntity] {
        let known = await MainActor.run { FocusOutputDirectory.all() }
        return identifiers.compactMap { id in known.first { $0.id == id } }
    }

    func suggestedEntities() async throws -> [OutputEntity] {
        await MainActor.run { FocusOutputDirectory.all() }
    }
}

@MainActor
enum FocusOutputDirectory {
    private struct Remembered: Codable {
        let id: String
        let name: String
        let deviceClass: DeviceClass
    }

    private static let key = "red.forbes.sounding.focus.outputs.v1"
    private static let limit = 12

    static func all(defaults: UserDefaults = .standard) -> [OutputEntity] {
        var seen = Set<String>()
        var result: [OutputEntity] = []
        func add(_ entity: OutputEntity) {
            guard seen.insert(entity.id).inserted else { return }
            result.append(entity)
        }
        add(OutputEntity(.thisDevice))
        let live = (PartyScenes.outputRouter.map { $0.devices + $0.linkedDevices } ?? []).filter { !$0.isLocal }
        live.map(OutputEntity.init).forEach(add)
        remembered(defaults).forEach(add)
        remember(result.filter { $0.id != OutputDevice.localID }, defaults: defaults)
        return result
    }

    private static func remembered(_ defaults: UserDefaults) -> [OutputEntity] {
        guard let data = defaults.data(forKey: key),
              let items = try? JSONDecoder().decode([Remembered].self, from: data) else { return [] }
        return items.map { OutputEntity(id: $0.id, name: $0.name, deviceClass: $0.deviceClass) }
    }

    private static func remember(_ entities: [OutputEntity], defaults: UserDefaults) {
        let items = entities.prefix(limit).map { Remembered(id: $0.id, name: $0.name, deviceClass: $0.deviceClass) }
        guard let data = try? JSONEncoder().encode(Array(items)) else { return }
        defaults.set(data, forKey: key)
    }
}

// MARK: - Filter

struct SoundingFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Set Sounding Filter"
    static let description = IntentDescription("Choose where music plays and how Auto Mix behaves in this Focus.")

    @Parameter(title: "Output")
    var output: OutputEntity?

    @Parameter(title: "Quiet Auto Mix", default: false)
    var quietAutoMix: Bool

    @Parameter(title: "Wind Down", default: false)
    var windDown: Bool

    @Parameter(title: "Wind Down Minutes", default: 30, inclusiveRange: (1, 120))
    var windDownMinutes: Int

    @Parameter(title: "Workout Energy", default: false)
    var workoutEnergy: Bool

    init() {}

    var settings: SoundingFocus.Settings {
        SoundingFocus.Settings(
            outputID: output?.id,
            outputName: output?.name,
            outputClass: output?.deviceClass,
            quiet: quietAutoMix,
            windDownMinutes: windDown ? windDownMinutes : nil,
            workout: workoutEnergy
        )
    }

    var displayRepresentation: DisplayRepresentation {
        let summary = settings.summary
        return DisplayRepresentation(
            title: "Sounding",
            subtitle: summary.isEmpty ? "No changes" : "\(summary)"
        )
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        await SoundingFocus.apply(settings)
        return .result()
    }
}

@MainActor
enum SoundingFocus {
    struct Settings: Codable, Equatable {
        var outputID: String?
        var outputName: String?
        var outputClass: DeviceClass?
        var quiet = false
        var windDownMinutes: Int?
        var workout = false

        var energy: AutoMixEnergy.FocusMode {
            AutoMixEnergy.FocusMode(quiet: quiet, workout: workout)
        }

        var summary: String {
            var parts: [String] = []
            if let outputName { parts.append(outputName) }
            if quiet { parts.append("Quiet Auto Mix") }
            if let windDownMinutes { parts.append(windDownMinutes == 1 ? "Wind Down over 1 minute" : "Wind Down over \(windDownMinutes) minutes") }
            if workout { parts.append("Workout Energy") }
            return parts.joined(separator: " · ")
        }
    }

    private struct Record: Codable, Equatable {
        var active = Settings()
        var previousOutputID: String?
    }

    private static let key = "red.forbes.sounding.focus.v1"

    static func apply(_ next: Settings, defaults: UserDefaults = .standard) async {
        var record = load(defaults)
        let previous = record.active
        AutoMixEnergy.shared.setFocus(next.energy)
        await route(from: previous, to: next, record: &record)
        if let minutes = next.windDownMinutes, previous.windDownMinutes == nil {
            _ = PartyScenes.windDown(minutes: Double(minutes))
        } else if next.windDownMinutes == nil, previous.windDownMinutes != nil {
            WindDownController.shared.cancel()
        }
        record.active = next
        save(record, defaults: defaults)
    }

    static func restore(defaults: UserDefaults = .standard) {
        AutoMixEnergy.shared.setFocus(load(defaults).active.energy)
        Task { @MainActor in
            guard let current = try? await SoundingFocusFilter.current else { return }
            AutoMixEnergy.shared.setFocus(current.settings.energy)
        }
    }

    private static func route(from previous: Settings, to next: Settings, record: inout Record) async {
        guard let router = PartyScenes.outputRouter else { return }
        if let id = next.outputID {
            guard id != router.current.id, let target = device(id: id, name: next.outputName, deviceClass: next.outputClass, router: router) else { return }
            if previous.outputID == nil { record.previousOutputID = router.current.id }
            _ = await router.move(to: target)
            return
        }
        defer { record.previousOutputID = nil }
        guard let focusID = previous.outputID, router.current.id == focusID,
              let backID = record.previousOutputID, backID != focusID,
              let back = device(id: backID, name: nil, deviceClass: nil, router: router) else { return }
        _ = await router.move(to: back)
    }

    private static func device(id: String, name: String?, deviceClass: DeviceClass?, router: OutputRouter) -> OutputDevice? {
        if id == OutputDevice.localID { return .thisDevice }
        if let live = (router.devices + router.linkedDevices).first(where: { $0.id == id }) { return live }
        guard let name, let deviceClass else { return nil }
        return OutputDevice(id: id, name: name, deviceClass: deviceClass)
    }

    private static func load(_ defaults: UserDefaults) -> Record {
        guard let data = defaults.data(forKey: key),
              let record = try? JSONDecoder().decode(Record.self, from: data) else { return Record() }
        return record
    }

    private static func save(_ record: Record, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: key)
    }
}
#endif
