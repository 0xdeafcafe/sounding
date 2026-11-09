import SwiftUI

extension SleepTimerMode {
    var title: String {
        switch self {
        case .minutes(60): return "1 Hour"
        case .minutes(let minutes): return "\(minutes) Minutes"
        case .endOfTrack: return "End of Track"
        case .endOfMix: return "End of Mix"
        }
    }

    static func choices(offersEndOfMix: Bool) -> [SleepTimerMode] {
        minuteChoices.map { .minutes($0) } + [.endOfTrack] + (offersEndOfMix ? [.endOfMix] : [])
    }
}

struct SleepTimerPicker: View {
    let status: SleepTimerStatus?
    let offersEndOfMix: Bool
    let onSelect: (SleepTimerMode?) -> Void

    var body: some View {
        Picker(selection: Binding(get: { status?.mode }, set: { onSelect($0) })) {
            Text("Off").tag(SleepTimerMode?.none)
            ForEach(SleepTimerMode.choices(offersEndOfMix: offersEndOfMix), id: \.self) { mode in
                Text(mode.title).tag(Optional(mode))
            }
        } label: {
            Label("Sleep Timer", systemImage: "moon.zzz")
        }
        .pickerStyle(.menu)
    }
}

struct SleepTimerIndicator: View {
    let status: SleepTimerStatus

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "moon.zzz.fill")
                .imageScale(.small)
            if let endsAt = status.endsAt, endsAt > .now {
                Text(timerInterval: Date.now...endsAt, countsDown: true)
                    .monospacedDigit()
            } else {
                Text(status.mode.title)
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard let endsAt = status.endsAt, endsAt > .now else { return "Sleep timer, \(status.mode.title)" }
        let minutes = max(1, Int((endsAt.timeIntervalSinceNow / 60).rounded(.up)))
        return minutes == 1 ? "Sleep timer, 1 minute left" : "Sleep timer, \(minutes) minutes left"
    }
}
