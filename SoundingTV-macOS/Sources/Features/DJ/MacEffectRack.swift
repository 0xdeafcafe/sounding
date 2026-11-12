import SwiftUI
import AppKit
import AVFoundation
import Combine

struct MacEffectComponent: Identifiable, Hashable, Sendable {
    let id: MacEffectComponentID
    let name: String
    let manufacturer: String
}

struct MacEffectManufacturer: Identifiable, Hashable, Sendable {
    let name: String
    let components: [MacEffectComponent]
    var id: String { name }
}

@MainActor
final class MacEffectRack: ObservableObject {
    static let shared = MacEffectRack()

    @Published private(set) var effects: [MixEngine.EffectSlot: MixEngine.LoadedEffect] = [:]
    @Published private(set) var catalogue: [MacEffectManufacturer] = []
    @Published var failureMessage: String?
    @Published var namingSlot: MixEngine.EffectSlot?

    let store = MacEffectPresetStore.shared
    private var engine: MixEngine { .shared }
    private var cancellables = Set<AnyCancellable>()
    private var catalogueTask: Task<Void, Never>?
    private var hasRestored = false

    nonisolated private static let excludedSubTypes: Set<OSType> = [
        fourCharacterCode("rogr"),
        fourCharacterCode("raac"),
        fourCharacterCode("nsnd")
    ]

    private init() {
        MixEngine.shared.$effects
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] effects in
                guard let self else { return }
                self.effects = effects
                MacEffectEditors.shared.sync(with: effects)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: AVAudioUnitComponentManager.registrationsChangedNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshCatalogue() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rememberAll() }
            .store(in: &cancellables)
    }

    // MARK: - Catalogue

    @discardableResult
    func refreshCatalogue() -> Task<Void, Never> {
        catalogueTask?.cancel()
        let task = Task { [weak self] in
            let catalogue = await Task.detached(priority: .userInitiated) { Self.scanComponents() }.value
            guard !Task.isCancelled else { return }
            self?.catalogue = catalogue
        }
        catalogueTask = task
        return task
    }

    func ensureCatalogue() async {
        if !catalogue.isEmpty { return }
        if let catalogueTask {
            await catalogueTask.value
        } else {
            await refreshCatalogue().value
        }
    }

    nonisolated private static func scanComponents() -> [MacEffectManufacturer] {
        let manager = AVAudioUnitComponentManager.shared()
        let types = [kAudioUnitType_Effect, kAudioUnitType_MusicEffect]
        var seen = Set<MacEffectComponentID>()
        var components: [MacEffectComponent] = []
        for type in types {
            let query = AudioComponentDescription(componentType: type, componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
            for component in manager.components(matching: query) {
                let description = component.audioComponentDescription
                if description.componentManufacturer == kAudioUnitManufacturer_Apple, excludedSubTypes.contains(description.componentSubType) { continue }
                let id = MacEffectComponentID(type: description.componentType, subType: description.componentSubType, manufacturer: description.componentManufacturer)
                guard seen.insert(id).inserted else { continue }
                let manufacturer = component.manufacturerName.isEmpty ? "Other" : component.manufacturerName
                components.append(MacEffectComponent(id: id, name: component.name, manufacturer: manufacturer))
            }
        }
        return Dictionary(grouping: components, by: \.manufacturer)
            .map { name, list in
                MacEffectManufacturer(name: name, components: list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    nonisolated private static func fourCharacterCode(_ string: String) -> OSType {
        string.utf8.reduce(0) { ($0 << 8) | OSType($1) }
    }

    func installedComponent(_ id: MacEffectComponentID) -> MacEffectComponent? {
        for manufacturer in catalogue {
            if let match = manufacturer.components.first(where: { $0.id == id }) { return match }
        }
        return nil
    }

    // MARK: - Slots

    func isLoaded(_ component: MacEffectComponent, in slot: MixEngine.EffectSlot) -> Bool {
        effects[slot].map(MacEffectComponentID.init) == component.id
    }

    @discardableResult
    func load(_ component: MacEffectComponent, into slot: MixEngine.EffectSlot, state: Data? = nil, bypassed: Bool = false, quietly: Bool = false) async -> Bool {
        if !isLoaded(component, in: slot) {
            do {
                try await engine.loadEffect(component.id.description, name: component.name, manufacturer: component.manufacturer, into: slot)
            } catch {
                if !quietly { failureMessage = "Couldn’t load \(component.name)." }
                return false
            }
        }
        if let state { applyState(state, to: slot) }
        if bypassed { engine.setEffectBypassed(true, in: slot) }
        remember(slot)
        return true
    }

    func remove(from slot: MixEngine.EffectSlot) {
        MacEffectEditors.shared.close(slot)
        engine.removeEffect(from: slot)
        store.remember(nil, for: slot)
    }

    func toggleBypass(in slot: MixEngine.EffectSlot) {
        guard let effect = effects[slot] else { return }
        engine.setEffectBypassed(!effect.isBypassed, in: slot)
        remember(slot)
    }

    func showEditor(for slot: MixEngine.EffectSlot) {
        guard let effect = effects[slot], let audioUnit = engine.effectAudioUnit(in: slot) else { return }
        MacEffectEditors.shared.show(audioUnit, effect: effect, slot: slot)
    }

    func remember(_ slot: MixEngine.EffectSlot) {
        guard let effect = engine.effects[slot] else { return }
        let state = MacEffectPresetStore.encodeState(engine.effectAudioUnit(in: slot)?.fullState)
        store.remember(
            MacEffectSlotMemory(
                effectName: effect.name,
                effectManufacturer: effect.manufacturer,
                component: MacEffectComponentID(effect),
                state: state,
                isBypassed: effect.isBypassed
            ),
            for: slot
        )
    }

    func rememberAll() {
        for slot in MixEngine.EffectSlot.all where engine.effects[slot] != nil {
            remember(slot)
        }
    }

    func restoreIfNeeded() async {
        guard !hasRestored else { return }
        hasRestored = true
        await ensureCatalogue()
        for slot in MixEngine.EffectSlot.all where engine.effects[slot] == nil {
            guard let memory = store.memory(for: slot), let component = installedComponent(memory.component) else { continue }
            await load(component, into: slot, state: memory.state, bypassed: memory.isBypassed, quietly: true)
        }
    }

    private func applyState(_ data: Data, to slot: MixEngine.EffectSlot) {
        guard let audioUnit = engine.effectAudioUnit(in: slot), let state = MacEffectPresetStore.decodeState(data) else { return }
        audioUnit.fullState = state
    }

    // MARK: - Presets

    func defaultPresetName(for slot: MixEngine.EffectSlot) -> String {
        guard let effect = effects[slot] else { return "" }
        let taken = Set(store.presets(for: slot).map(\.name))
        var index = 1
        while taken.contains("\(effect.name) \(index)") { index += 1 }
        return "\(effect.name) \(index)"
    }

    func savePreset(named rawName: String, for slot: MixEngine.EffectSlot) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let effect = engine.effects[slot],
              let state = MacEffectPresetStore.encodeState(engine.effectAudioUnit(in: slot)?.fullState) else { return }
        store.save(
            MacEffectPreset(
                id: UUID(),
                name: name,
                effectName: effect.name,
                effectManufacturer: effect.manufacturer,
                component: MacEffectComponentID(effect),
                state: state
            ),
            for: slot
        )
    }

    func apply(_ preset: MacEffectPreset, to slot: MixEngine.EffectSlot) async {
        await ensureCatalogue()
        guard let component = installedComponent(preset.component) else {
            failureMessage = "Couldn’t load \(preset.effectName)."
            return
        }
        await load(component, into: slot, state: preset.state)
    }

    func deletePreset(_ preset: MacEffectPreset, for slot: MixEngine.EffectSlot) {
        store.delete(preset, for: slot)
    }
}

struct MacEffectMenu: View {
    let slot: MixEngine.EffectSlot
    @ObservedObject private var rack = MacEffectRack.shared
    @ObservedObject private var store = MacEffectPresetStore.shared
    @ObservedObject private var editors = MacEffectEditors.shared

    private var effect: MixEngine.LoadedEffect? { rack.effects[slot] }

    var body: some View {
        Menu {
            Toggle("None", isOn: Binding(get: { effect == nil }, set: { if $0 { rack.remove(from: slot) } }))
            Divider()
            if rack.catalogue.isEmpty {
                Text("No Effects Installed")
            }
            ForEach(rack.catalogue) { manufacturer in
                Menu(manufacturer.name) {
                    ForEach(manufacturer.components) { component in
                        Toggle(component.name, isOn: Binding(
                            get: { rack.isLoaded(component, in: slot) },
                            set: { _ in Task { await rack.load(component, into: slot) } }
                        ))
                    }
                }
            }
            Divider()
            Button("Show Effect…") { rack.showEditor(for: slot) }
                .disabled(effect == nil)
            Toggle("Bypass", isOn: Binding(
                get: { effect?.isBypassed ?? false },
                set: { _ in rack.toggleBypass(in: slot) }
            ))
            .disabled(effect == nil)
            presetsMenu
        } label: {
            Text(effect?.name ?? "Effect")
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("\(slot == .send ? "Send effect" : "Effect for \(slot.title)")")
        .accessibilityLabel(slot == .send ? "Send effect" : "Effect, \(slot.title)")
        .accessibilityValue(accessibilityValue)
        .popover(item: editors.binding(for: slot), arrowEdge: .bottom) { editor in
            MacEffectEditorView(editor: editor)
        }
        .task { await rack.ensureCatalogue() }
    }

    private var presetsMenu: some View {
        let presets = store.presets(for: slot)
        return Menu("Presets") {
            Button("Save Preset…") { rack.namingSlot = slot }
                .disabled(effect == nil)
            if !presets.isEmpty {
                Divider()
                ForEach(presets) { preset in
                    Button(preset.name) { Task { await rack.apply(preset, to: slot) } }
                        .disabled(rack.installedComponent(preset.component) == nil)
                }
                Divider()
                Menu("Delete Preset") {
                    ForEach(presets) { preset in
                        Button(preset.name, role: .destructive) { rack.deletePreset(preset, for: slot) }
                    }
                }
            }
        }
    }

    private var accessibilityValue: String {
        guard let effect else { return "None" }
        return effect.isBypassed ? "\(effect.name), bypassed" : effect.name
    }
}

struct MacEffectBypassBadge: View {
    let slot: MixEngine.EffectSlot
    @ObservedObject private var rack = MacEffectRack.shared
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if rack.effects[slot]?.isBypassed == true {
            Text("BYPASSED")
                .font(.caption2.monospaced().weight(.bold))
                .foregroundStyle(contrast.macInk(0.55, increased: 0.85))
                .fixedSize()
                .accessibilityHidden(true)
        }
    }
}

private struct MacEffectRackPresentation: ViewModifier {
    @ObservedObject private var rack = MacEffectRack.shared
    @State private var presetName = ""

    func body(content: Content) -> some View {
        content
            .task { await rack.restoreIfNeeded() }
            .onDisappear { rack.rememberAll() }
            .alert(
                rack.failureMessage ?? "",
                isPresented: Binding(get: { rack.failureMessage != nil }, set: { if !$0 { rack.failureMessage = nil } })
            ) {
                Button("OK", role: .cancel) { rack.failureMessage = nil }
            }
            .alert(
                "Save Preset",
                isPresented: Binding(get: { rack.namingSlot != nil }, set: { if !$0 { rack.namingSlot = nil } })
            ) {
                TextField("Name", text: $presetName)
                Button("Save") {
                    if let slot = rack.namingSlot { rack.savePreset(named: presetName, for: slot) }
                    rack.namingSlot = nil
                }
                .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) { rack.namingSlot = nil }
            } message: {
                if let slot = rack.namingSlot { Text(slot.title) }
            }
            .onChange(of: rack.namingSlot) { _, slot in
                if let slot { presetName = rack.defaultPresetName(for: slot) }
            }
    }
}

extension View {
    func macEffectRackPresentation() -> some View {
        modifier(MacEffectRackPresentation())
    }
}
