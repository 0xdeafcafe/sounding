import SwiftUI
import AppKit
import AVFoundation
import CoreAudioKit

@MainActor
final class MacEffectWindows: NSObject, NSWindowDelegate {
    static let shared = MacEffectWindows()

    private struct Entry {
        let panel: NSPanel
        let component: MacEffectComponentID
        let parameters: MacEffectParameterModel?
    }

    private var entries: [MixEngine.EffectSlot: Entry] = [:]
    private var pending: [MixEngine.EffectSlot: MacEffectComponentID] = [:]

    func show(_ audioUnit: AUAudioUnit, effect: MixEngine.LoadedEffect, slot: MixEngine.EffectSlot) {
        let component = MacEffectComponentID(effect)
        if let entry = entries[slot] {
            if entry.component == component {
                entry.panel.makeKeyAndOrderFront(nil)
                return
            }
            close(slot)
        }
        guard pending[slot] != component else { return }
        pending[slot] = component
        let title = "\(effect.name) — \(slot.title)"
        Self.requestView(audioUnit) { [weak self] box in
            guard let self, self.pending[slot] == component else { return }
            self.pending[slot] = nil
            guard MixEngine.shared.effects[slot].map(MacEffectComponentID.init) == component else { return }
            self.present(box.controller, audioUnit: audioUnit, component: component, title: title, slot: slot)
        }
    }

    func close(_ slot: MixEngine.EffectSlot) {
        pending[slot] = nil
        guard let entry = entries.removeValue(forKey: slot) else { return }
        entry.parameters?.stop()
        entry.panel.delegate = nil
        entry.panel.close()
    }

    func sync(with effects: [MixEngine.EffectSlot: MixEngine.LoadedEffect]) {
        for (slot, entry) in entries where effects[slot].map(MacEffectComponentID.init) != entry.component {
            close(slot)
        }
    }

    private func present(_ controller: NSViewController?, audioUnit: AUAudioUnit, component: MacEffectComponentID, title: String, slot: MixEngine.EffectSlot) {
        let content: NSViewController
        var parameters: MacEffectParameterModel?
        var size: NSSize
        if let controller {
            content = controller
            size = controller.preferredContentSize
            if size.width < 1 || size.height < 1 { size = controller.view.fittingSize }
            if size.width < 1 || size.height < 1 { size = controller.view.frame.size }
            if size.width < 1 || size.height < 1 { size = NSSize(width: 480, height: 320) }
        } else {
            let model = MacEffectParameterModel(audioUnit: audioUnit)
            parameters = model
            content = NSHostingController(rootView: MacEffectParameterForm(model: model))
            let rows = CGFloat(max(model.parameters.count, 3))
            size = NSSize(width: 460, height: min(560, 60 + rows * 34))
        }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: controller == nil ? [.titled, .closable, .resizable, .utilityWindow] : [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.contentViewController = content
        panel.setContentSize(size)
        if controller == nil { panel.contentMinSize = NSSize(width: 360, height: 160) }
        panel.delegate = self
        panel.center()
        entries[slot] = Entry(panel: panel, component: component, parameters: parameters)
        panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NSPanel,
              let slot = entries.first(where: { $0.value.panel === panel })?.key,
              let entry = entries.removeValue(forKey: slot) else { return }
        entry.parameters?.stop()
        MacEffectRack.shared.remember(slot)
    }

    struct ViewControllerBox: @unchecked Sendable {
        let controller: NSViewController?
    }

    nonisolated private static func requestView(_ audioUnit: AUAudioUnit, completion: @escaping @MainActor @Sendable (ViewControllerBox) -> Void) {
        audioUnit.requestViewController { controller in
            let box = ViewControllerBox(controller: controller)
            Task { @MainActor in completion(box) }
        }
    }
}

@MainActor
final class MacEffectParameterModel: ObservableObject {
    let parameters: [AUParameter]
    @Published private(set) var values: [AUParameterAddress: AUValue]
    private weak var tree: AUParameterTree?
    private var token: AUParameterObserverToken?

    init(audioUnit: AUAudioUnit) {
        let tree = audioUnit.parameterTree
        self.tree = tree
        parameters = (tree?.allParameters ?? []).filter {
            $0.flags.contains(.flag_IsWritable) && $0.maxValue > $0.minValue
        }
        values = Dictionary(parameters.map { ($0.address, $0.value) }, uniquingKeysWith: { first, _ in first })
        if let tree {
            token = tree.token(byAddingParameterObserver: Self.observer { [weak self] address, value in
                self?.values[address] = value
            })
        }
    }

    func value(of parameter: AUParameter) -> AUValue {
        values[parameter.address] ?? parameter.value
    }

    func set(_ value: AUValue, on parameter: AUParameter) {
        let clamped = min(parameter.maxValue, max(parameter.minValue, value))
        if let token {
            parameter.setValue(clamped, originator: token)
        } else {
            parameter.value = clamped
        }
        values[parameter.address] = clamped
    }

    func displayValue(of parameter: AUParameter) -> String {
        var current = value(of: parameter)
        let text = parameter.string(fromValue: &current)
        if !text.isEmpty { return text }
        return String(format: "%.2f", current)
    }

    func stop() {
        if let token, let tree { tree.removeParameterObserver(token) }
        token = nil
    }

    nonisolated private static func observer(_ sink: @escaping @MainActor @Sendable (AUParameterAddress, AUValue) -> Void) -> AUParameterObserver {
        { address, value in
            Task { @MainActor in sink(address, value) }
        }
    }
}

struct MacEffectParameterForm: View {
    @ObservedObject var model: MacEffectParameterModel

    var body: some View {
        Group {
            if model.parameters.isEmpty {
                ContentUnavailableView("No Controls", systemImage: "slider.horizontal.3", description: Text("This effect has no adjustable settings."))
            } else {
                Form {
                    Section {
                        ForEach(model.parameters, id: \.address) { parameter in
                            row(for: parameter)
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .frame(minWidth: 360, minHeight: 160)
    }

    @ViewBuilder
    private func row(for parameter: AUParameter) -> some View {
        let name = parameter.displayName
        if parameter.unit == .boolean {
            Toggle(name, isOn: Binding(
                get: { model.value(of: parameter) >= 0.5 },
                set: { model.set($0 ? 1 : 0, on: parameter) }
            ))
        } else if let strings = parameter.valueStrings, !strings.isEmpty, parameter.unit == .indexed {
            Picker(name, selection: Binding(
                get: { Int(model.value(of: parameter).rounded()) },
                set: { model.set(AUValue($0), on: parameter) }
            )) {
                ForEach(Array(strings.enumerated()), id: \.offset) { offset, label in
                    Text(label).tag(Int(parameter.minValue) + offset)
                }
            }
        } else {
            LabeledContent {
                HStack(spacing: 8) {
                    Slider(
                        value: Binding(
                            get: { Double(model.value(of: parameter)) },
                            set: { model.set(AUValue($0), on: parameter) }
                        ),
                        in: Double(parameter.minValue)...Double(parameter.maxValue)
                    )
                    .labelsHidden()
                    .accessibilityLabel(name)
                    .accessibilityValue(model.displayValue(of: parameter))
                    Text(model.displayValue(of: parameter))
                        .monospacedDigit()
                        .foregroundStyle(MacSecondaryStyle())
                        .lineLimit(1)
                        .frame(width: 72, alignment: .trailing)
                        .accessibilityHidden(true)
                }
            } label: {
                Text(name)
            }
        }
    }
}
