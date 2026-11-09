import AlarmKit
import SwiftUI

extension WakeAlarmStore {
    var summary: String {
        let on = alarms.filter(\.isEnabled)
        guard let next = on.first else { return alarms.isEmpty ? "None" : "Off" }
        return on.count == 1 ? WakeAlarmTimeText.string(for: next) : "\(on.count) On"
    }
}

enum WakeAlarmTimeText {
    static func string(for alarm: WakeAlarm) -> String {
        let date = Calendar.current.date(from: alarm.time) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }
}

struct WakeAlarmsView: View {
    @ObservedObject private var store = WakeAlarmStore.shared
    @State private var editing: WakeAlarm?
    @Environment(\.openURL) private var openURL

    var body: some View {
        content
            .navigationTitle("Alarms")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if store.authorization != .denied {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            editing = WakeAlarm.draft(target: .likes)
                        } label: {
                            Label("Add Alarm", systemImage: "plus")
                        }
                    }
                }
            }
            .sheet(item: $editing) { alarm in
                WakeAlarmEditor(alarm: alarm, isNew: !store.alarms.contains { $0.id == alarm.id })
            }
            .alert("Alarm Not Set", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(store.lastError ?? "")
            }
    }

    @ViewBuilder
    private var content: some View {
        if store.authorization == .denied {
            ContentUnavailableView {
                Label("Alarms Are Off", systemImage: "alarm")
            } description: {
                Text("Allow Sounding to set alarms in Settings.")
            } actions: {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        } else if store.alarms.isEmpty {
            ContentUnavailableView {
                Label("No Alarms", systemImage: "alarm")
            } description: {
                Text("Wake up to a track, playlist or station. Choose Wake to This from any track or playlist.")
            } actions: {
                Button("Add Alarm") { editing = WakeAlarm.draft(target: .likes) }
            }
        } else {
            Form {
                Section {
                    ForEach(store.alarms) { alarm in
                        WakeAlarmRow(alarm: alarm) { editing = alarm }
                    }
                    .onDelete { offsets in
                        for index in offsets { store.delete(store.alarms[index]) }
                    }
                } footer: {
                    Text("The music fades in after you tap Play on the alarm.")
                }
            }
            .formStyle(.grouped)
        }
    }
}

private struct WakeAlarmRow: View {
    let alarm: WakeAlarm
    let onEdit: () -> Void

    @ObservedObject private var store = WakeAlarmStore.shared

    var body: some View {
        Toggle(isOn: Binding(get: { alarm.isEnabled }, set: { on in Task { await store.setEnabled(on, for: alarm) } })) {
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(WakeAlarmTimeText.string(for: alarm))
                        .font(.largeTitle.weight(.light))
                        .monospacedDigit()
                        .foregroundStyle(alarm.isEnabled ? .primary : .secondary)
                    Text("\(alarm.target.summary), \(alarm.repeatSummary)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .accessibilityHint("Double-tap the time to edit")
    }
}

extension WakeAlarm {
    static func draft(target: WakeTarget) -> WakeAlarm {
        WakeAlarm(id: UUID(), hour: 7, minute: 0, weekdays: [], target: target, isEnabled: true)
    }
}

struct WakeAlarmEditor: View {
    @State var alarm: WakeAlarm
    let isNew: Bool
    var stationTarget: WakeTarget?

    @ObservedObject private var store = WakeAlarmStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false

    private var time: Binding<Date> {
        Binding(
            get: { Calendar.current.date(from: alarm.time) ?? .now },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                alarm.hour = parts.hour ?? 7
                alarm.minute = parts.minute ?? 0
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Time", selection: time, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                }
                Section {
                    NavigationLink {
                        WakeRepeatPicker(weekdays: $alarm.weekdays)
                    } label: {
                        LabeledContent("Repeat", value: alarm.repeatSummary)
                    }
                    if let stationTarget {
                        Picker("Wake To", selection: $alarm.target) {
                            Text(trackTarget.title).tag(trackTarget)
                            Text(stationTarget.summary).tag(stationTarget)
                        }
                    } else {
                        LabeledContent("Wake To", value: alarm.target.summary)
                    }
                }
                if !isNew {
                    Section {
                        Button("Delete Alarm", role: .destructive) {
                            store.delete(alarm)
                            dismiss()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? "Add Alarm" : "Edit Alarm")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            var saved = alarm
                            saved.isEnabled = true
                            await store.save(saved)
                            saving = false
                            dismiss()
                        }
                    }
                    .disabled(saving)
                }
            }
        }
    }

    private var trackTarget: WakeTarget {
        WakeTarget(kind: .track, id: stationTarget?.id ?? alarm.target.id, title: stationTarget?.title ?? alarm.target.title)
    }
}

private struct WakeRepeatPicker: View {
    @Binding var weekdays: [Locale.Weekday]

    var body: some View {
        Form {
            Section {
                ForEach(Locale.Weekday.allWeek, id: \.self) { day in
                    Button {
                        if let index = weekdays.firstIndex(of: day) {
                            weekdays.remove(at: index)
                        } else {
                            weekdays.append(day)
                        }
                    } label: {
                        HStack {
                            Text("Every \(Calendar.current.weekdaySymbols[day.calendarIndex])")
                                .foregroundStyle(.primary)
                            Spacer()
                            if weekdays.contains(day) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .accessibilityAddTraits(weekdays.contains(day) ? .isSelected : [])
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Repeat")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct WakeAlarmRequest: Identifiable {
    let id = UUID()
    let target: WakeTarget
    var station: WakeTarget?
}

private struct PresentWakeAlarmKey: EnvironmentKey {
    static let defaultValue: @MainActor (WakeAlarmRequest) -> Void = { _ in }
}

extension EnvironmentValues {
    var presentWakeAlarm: @MainActor (WakeAlarmRequest) -> Void {
        get { self[PresentWakeAlarmKey.self] }
        set { self[PresentWakeAlarmKey.self] = newValue }
    }
}

extension View {
    func wakeAlarmHost() -> some View { modifier(WakeAlarmHost()) }
}

private struct WakeAlarmHost: ViewModifier {
    @State private var request: WakeAlarmRequest?

    func body(content: Content) -> some View {
        content
            .environment(\.presentWakeAlarm) { request = $0 }
            .sheet(item: $request) { request in
                WakeAlarmEditor(
                    alarm: WakeAlarm.draft(target: request.target),
                    isNew: true,
                    stationTarget: request.station
                )
            }
            #if DEBUG
            .task {
                guard ProcessInfo.processInfo.environment["SOUNDING_TV_WAKE_EDITOR"] == "1",
                      request == nil, let first = VisualFixtures.tracks.first else { return }
                try? await Task.sleep(for: .seconds(1.5))
                request = WakeAlarmRequest(track: first)
            }
            #endif
    }
}

extension WakeAlarmRequest {
    init(track: Track) {
        self.init(
            target: WakeTarget(kind: .track, id: track.id, title: track.title),
            station: WakeTarget(kind: .station, id: track.id, title: track.title)
        )
    }

    init(playlist: Playlist) {
        self.init(target: WakeTarget(kind: .playlist, id: playlist.id, title: playlist.title))
    }
}

struct WakeToThisMenuButton: View {
    let request: WakeAlarmRequest
    @Environment(\.presentWakeAlarm) private var present

    init(track: Track) {
        request = WakeAlarmRequest(track: track)
    }

    init(playlist: Playlist) {
        request = WakeAlarmRequest(playlist: playlist)
    }

    var body: some View {
        Button {
            present(request)
        } label: {
            Label("Wake to This…", systemImage: "alarm")
        }
    }
}
