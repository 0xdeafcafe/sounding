import SwiftUI

struct WatchAutoMixLine: View {
    let state: AutoMixLiveState
    let date: Date
    var showsHeading = false

    var body: some View {
        if let text = text {
            VStack(alignment: .leading, spacing: 0) {
                if showsHeading, let heading {
                    Text(heading)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(1)
                }
                Label {
                    Text(text)
                        .monospacedDigit()
                        .lineLimit(1)
                } icon: {
                    Image(systemName: state.symbolName)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel([heading, text].compactMap { $0 }.joined(separator: ", "))
        }
    }

    private var resolved: AutoMixLiveState {
        var live = state
        if live.stage == .upcoming, live.clock(at: date).secondsUntilStart <= 0 { live.stage = .mixing }
        return live
    }

    private var heading: String? {
        let live = resolved
        guard live.stage == .upcoming, !live.incomingTitle.isEmpty else { return nil }
        return "Mix into \(live.incomingTitle)"
    }

    private var text: String? {
        let live = resolved
        let clock = live.clock(at: date)
        switch live.stage {
        case .upcoming:
            return "\(live.moveName) \(clock.countdownText)"
        case .mixing:
            guard clock.barInMove < Double(live.lengthBars) else { return "Mixed into \(live.incomingTitle)" }
            return clock.phase?.name ?? live.moveName
        case .finished:
            return "Mixed into \(live.incomingTitle)"
        }
    }
}

struct WatchGlassPlate: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}

extension View {
    func watchGlassPlate() -> some View {
        modifier(WatchGlassPlate())
    }
}
