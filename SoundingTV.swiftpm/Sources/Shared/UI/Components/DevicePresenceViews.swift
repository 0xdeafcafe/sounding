import SwiftUI

struct DevicePresenceMenuItems: View {
    let entries: [DevicePresenceEntry]

    @ObservedObject private var model = DevicePresenceModel.shared

    var body: some View {
        let now = Date()
        if entries.count == 1, let entry = entries.first {
            Section(entry.sentence(at: now)) {
                actions(for: entry, now: now)
            }
        } else if !entries.isEmpty {
            Section("Other Devices") {
                ForEach(entries) { entry in
                    Menu {
                        Section(entry.sentence(at: now)) {
                            actions(for: entry, now: now)
                        }
                    } label: {
                        Text(entry.displayName)
                        Text(entry.isLive ? entry.displayTitle : entry.caption(at: now))
                        Image(systemName: entry.deviceClass.symbolName)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actions(for entry: DevicePresenceEntry, now: Date) -> some View {
        let available = model.actions(for: entry)
        if available.isEmpty {
            Text(entry.caption(at: now))
        }
        ForEach(available) { action in
            Button {
                model.perform(action, on: entry)
            } label: {
                Label(model.title(for: action, entry: entry), systemImage: model.symbol(for: action, entry: entry))
            }
            .disabled(model.busyEntryID != nil)
        }
    }
}

struct DevicePresenceBadge: View {
    let entries: [DevicePresenceEntry]
    var font: Font = .body

    var body: some View {
        if let first = entries.first {
            HStack(spacing: 2) {
                Image(systemName: first.deviceClass.symbolName)
                    .font(font.weight(.semibold))
                if let more = DevicePresence.moreLabel(count: entries.count) {
                    Text(more)
                        .font(.caption2.weight(.bold).monospacedDigit())
                }
            }
            .foregroundStyle(first.isLive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
    }
}

struct DevicePresenceLine: View {
    let entries: [DevicePresenceEntry]

    var body: some View {
        if let first = entries.first {
            HStack(spacing: 4) {
                Image(systemName: first.deviceClass.symbolName)
                    .imageScale(.small)
                Text(first.sentence(at: Date()))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let more = DevicePresence.moreLabel(count: entries.count) {
                    Text(more)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .layoutPriority(1)
                }
            }
            .foregroundStyle(.secondary)
        }
    }
}

struct DevicePresenceFailureAlert: ViewModifier {
    @ObservedObject private var model = DevicePresenceModel.shared

    func body(content: Content) -> some View {
        content.alert("Couldn\u{2019}t Switch Device", isPresented: Binding(
            get: { model.failure != nil },
            set: { if !$0 { model.failure = nil } }
        )) {
            Button("OK", role: .cancel) { model.failure = nil }
        } message: {
            Text(model.failure ?? "")
        }
    }
}

extension View {
    func devicePresenceFailureAlert() -> some View {
        modifier(DevicePresenceFailureAlert())
    }
}
