import SwiftUI

struct MacDJAutoMixPanel<Library: View>: View {
    let state: MacDJPerformState
    @ObservedObject var model: MacDJPerformModel
    @ViewBuilder var library: () -> Library

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                MacDJSegmented(
                    options: [(MacDJPanelTab.autoMix, "Auto Mix"), (MacDJPanelTab.library, "Library")],
                    selection: $model.panelTab,
                    height: 22,
                    spacing: 10
                )
                .accessibilityLabel("Panel")
                Spacer()
                Toggle("Auto Mix", isOn: Binding(get: { state.panel?.isAutoMixOn ?? false }, set: { model.setAutoMix($0) }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 12))
                    .foregroundStyle(contrast.djInk(0.7))
            }
            .frame(height: 26)
            if model.panelTab == .library {
                library()
                    .padding(.top, 12)
            } else if let panel = state.panel {
                autoMixBody(panel)
            }
        }
        .padding(EdgeInsets(top: 10, leading: 18, bottom: 12, trailing: 16))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MacDJPalette.panel)
        .overlay(alignment: .leading) { Rectangle().fill(.white.opacity(0.1)).frame(width: 0.5) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Auto Mix panel")
    }

    @ViewBuilder
    private func autoMixBody(_ panel: MacDJPanelState) -> some View {
        MacDJOwnershipSlot(state: state, panel: panel, model: model)
            .padding(.top, 12)
        if panel.isAutoMixOn {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        if let chip = panel.stageChip {
                            MacDJChip(kind: .custom(chip, MacDJPalette.auto, MacDJPalette.auto.opacity(0.15)))
                        }
                        Spacer()
                        if let left = panel.timeLeft {
                            Text(left).font(.system(size: 12).monospacedDigit()).foregroundStyle(contrast.djInk(0.65))
                        }
                    }
                    .padding(.top, 14)
                    Text(panel.headline)
                        .font(.system(size: 20, weight: .bold))
                        .tracking(-0.3)
                        .padding(.top, 8)
                        .accessibilityAddTraits(.isHeader)
                    if let subline = panel.subline {
                        Text(subline)
                            .font(.system(size: 12))
                            .foregroundStyle(contrast.djInk(0.68))
                            .padding(.top, 4)
                    }
                    if panel.from != nil || panel.move != nil {
                        sectionHeader("The Plan")
                        if let from = panel.from { planRow("From", from) }
                        if let enter = panel.enter { planRow("Enter", enter) }
                        if let move = panel.move {
                            keyValue("Move") { Text(move).font(.system(size: 12)) }
                        }
                    }
                    if !panel.why.isEmpty {
                        sectionHeader("Why This Track")
                        ForEach(panel.why) { why in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(MacDJPalette.auto)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(why.title).font(.system(size: 12))
                                    if let detail = why.detail {
                                        Text(detail).font(.system(size: 11)).foregroundStyle(contrast.djInk(0.62))
                                    }
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                    if let next = panel.next {
                        sectionHeader("Next in the Plan")
                        HStack(spacing: 10) {
                            SCArtworkResolver(url: next.artworkURL) { image in
                                SCArtwork(image: image, identity: next.identity, style: .mac, cornerRadius: 7)
                            }
                            .frame(width: 34, height: 34)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(next.title).font(.system(size: 13, weight: .semibold))
                                Text(next.detail).font(.system(size: 11)).foregroundStyle(contrast.djInk(0.65))
                            }
                        }
                        HStack(spacing: 6) {
                            Button("Change") { model.changeNext() }
                            Button("Extend 8 Bars") { model.extend() }
                                .disabled(!panel.canExtend && !model.isFixture)
                            Button("Skip") { model.skipNext() }
                        }
                        .buttonStyle(MacDJControlButtonStyle(height: 26))
                        .padding(.top, 10)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        } else {
            Spacer()
        }
        Spacer(minLength: 0)
        HStack {
            Text(panel.footer)
            Spacer()
            Button { model.isPlanPresented = true } label: {
                HStack(spacing: 4) {
                    Text("Plan")
                    Text("\u{2318}3")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 5)
                        .frame(height: 17)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
                }
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 12))
        .foregroundStyle(contrast.djInk(0.6))
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(contrast.djInk(0.65))
            .padding(.top, 14)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }

    private func planRow(_ key: String, _ row: MacDJPlanRow) -> some View {
        keyValue(key) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    MacDJDeckBadge(deck: row.deck, size: 14)
                    Text(row.title)
                    if let section = row.section {
                        Text("\u{00B7}")
                        Text(section).foregroundStyle(row.deck == .a ? MacDJPalette.leavingLabel : MacDJPalette.enteringLabel)
                    }
                }
                .font(.system(size: 12))
                if let detail = row.detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(contrast.djInk(0.62))
                }
            }
        }
    }

    private func keyValue<Content: View>(_ key: String, @ViewBuilder value: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key)
                .font(.system(size: 12))
                .foregroundStyle(contrast.djInk(0.62))
                .frame(width: 42, alignment: .leading)
            value()
        }
        .padding(.vertical, 3)
    }
}

struct MacDJOwnershipSlot: View {
    let state: MacDJPerformState
    let panel: MacDJPanelState
    @ObservedObject var model: MacDJPerformModel

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let height: CGFloat = 72

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Group {
            if let owned = state.owned.first {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 6) {
                        Image(systemName: "hand.raised")
                        Text(state.owned.count == 1 ? owned.title : "\(state.owned.count) controls are yours")
                        Spacer()
                        Text(state.owned.count == 1 ? owned.valueText : "")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(MacDJPalette.yours)
                    HStack(spacing: 6) {
                        Button {
                            state.owned.count == 1 ? model.handBack(owned.control) : model.handBackAll()
                        } label: {
                            Label(state.owned.count == 1 ? "Hand Back" : "Hand Back All", systemImage: "arrow.uturn.backward")
                                .font(.system(size: 12, weight: .semibold))
                                .fixedSize()
                                .padding(.horizontal, 10)
                                .frame(height: 26)
                                .background(Capsule().fill(MacDJPalette.yours))
                                .foregroundStyle(.black)
                        }
                        .buttonStyle(.plain)
                        Button("Take Over All") { model.takeOverAll() }
                            .buttonStyle(MacDJControlButtonStyle(height: 26))
                            .fixedSize()
                        Spacer(minLength: 4)
                        Text("Returns on\nthe beat")
                            .fixedSize()
                            .font(.system(size: 11))
                            .foregroundStyle(contrast.djInk(0.62))
                            .multilineTextAlignment(.trailing)
                    }
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(shape.fill(MacDJPalette.yours.opacity(0.1)))
                .overlay(shape.strokeBorder(MacDJPalette.yours.opacity(0.55), lineWidth: 1))
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkle").foregroundStyle(MacDJPalette.auto)
                        Text(slotTitle)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 6) {
                        if let note = panel.playsBothDecksNote {
                            Label(note, systemImage: "cloud")
                                .font(.system(size: 12))
                                .foregroundStyle(contrast.djInk(0.65))
                        } else if panel.isAutoMixOn {
                            Button("Take Over All") { model.takeOverAll() }
                                .buttonStyle(MacDJControlButtonStyle(height: 26))
                            Spacer()
                            Text("Or grab any control")
                                .font(.system(size: 11))
                                .foregroundStyle(contrast.djInk(0.62))
                        } else {
                            Button("Turn On Auto Mix") { model.setAutoMix(true) }
                                .buttonStyle(MacDJControlButtonStyle(height: 26))
                            Spacer()
                            Text("The decks are yours")
                                .font(.system(size: 11))
                                .foregroundStyle(contrast.djInk(0.62))
                        }
                    }
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(shape.fill(.white.opacity(0.05)))
                .overlay(shape.strokeBorder(.white.opacity(contrast == .increased ? 0.5 : 0.1), lineWidth: 0.5))
            }
        }
        .frame(height: Self.height)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: state.owned)
        .accessibilityElement(children: .contain)
    }

    private var slotTitle: String {
        if panel.playsBothDecksNote != nil { return "Auto Mix plays both decks" }
        return panel.isAutoMixOn ? "Auto Mix has the controls" : "Auto Mix is off"
    }
}

struct MacDJAutoMixStrip: View {
    let state: MacDJPerformState
    @ObservedObject var model: MacDJPerformModel

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let owned = state.owned.first
        HStack(spacing: 12) {
            if let owned {
                Image(systemName: "hand.raised").foregroundStyle(MacDJPalette.yours)
                Text(state.owned.count == 1 ? owned.title : "\(state.owned.count) controls are yours")
                    .fontWeight(.bold)
                    .foregroundStyle(MacDJPalette.yours)
                if state.owned.count == 1 {
                    Text(owned.valueText).monospacedDigit().foregroundStyle(Color(red: 1, green: 0.93, blue: 0.59).opacity(0.9))
                }
                divider
                ViewThatFits(in: .horizontal) {
                    ForEach(0..<3, id: \.self) { level in
                        Text(keepsText(level: level)).fixedSize()
                    }
                    Color.clear.frame(width: 0, height: 0)
                }
                .foregroundStyle(.white.opacity(0.8))
                Spacer(minLength: 8)
                Button("Take Over All") { model.takeOverAll() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 6)
                Button {
                    state.owned.count == 1 ? model.handBack(owned.control) : model.handBackAll()
                } label: {
                    Label("Hand Back", systemImage: "arrow.uturn.backward")
                        .fontWeight(.semibold)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Capsule().fill(MacDJPalette.yours))
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "sparkle").foregroundStyle(MacDJPalette.auto)
                Text(state.panel?.headline ?? "Auto Mix").fontWeight(.semibold).lineLimit(1)
                if let mix = state.mix {
                    Text("bar \(max(1, Int(mix.nowBar))) of \(Int(mix.totalBars))")
                        .monospacedDigit()
                        .foregroundStyle(contrast.djInk(0.66))
                    divider
                    steps(mix)
                }
                Spacer(minLength: 8)
                HStack(spacing: 2) {
                    Button("Extend 8 Bars") { model.extend() }
                    Button("Take Over All") { model.takeOverAll() }
                    Button {
                        model.isPanelOpen = true
                    } label: {
                        Label("Show", systemImage: "sidebar.right")
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(.white)
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .frame(height: 34)
        .modifier(MacDJStripGlass(isYours: owned != nil, reduceTransparency: reduceTransparency))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Auto Mix strip")
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.22)).frame(width: 0.5, height: 14)
    }

    private func keepsText(level: Int) -> String {
        let ownedKinds = Set(state.owned.map(\.control.kind))
        var keeps: [String] = []
        if !ownedKinds.contains(.tempo) { keeps.append("loop") }
        if ownedKinds.isDisjoint(with: [.high, .mid, .low]) { keeps.append("EQ") }
        if !ownedKinds.contains(.filter) { keeps.append("filters") }
        if ownedKinds.isDisjoint(with: [.volume, .crossfader]) { keeps.append("faders") }
        let list: String
        switch keeps.count {
        case 0: list = "the timing"
        case 1: list = "the \(keeps[0])"
        default: list = "the " + keeps.dropLast().joined(separator: ", ") + " and " + keeps.last!
        }
        var parts = level < 2 ? ["Auto Mix keeps \(list)"] : []
        if level == 0 || level == 2, let step = state.mix?.currentStep { parts.append(step.label) }
        if level == 0 || level == 2, let mix = state.mix { parts.append("bar \(max(1, Int(mix.nowBar))) of \(Int(mix.totalBars))") }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func steps(_ mix: MacDJMixState) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(mix.steps.enumerated()), id: \.element.id) { index, step in
                if index > 0 {
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.white.opacity(0.3))
                }
                let mode = mix.mode(of: step)
                HStack(spacing: 6) {
                    if mode == .done {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(MacDJPalette.auto)
                    } else if mode == .now {
                        Circle().fill(MacDJPalette.auto).frame(width: 6, height: 6)
                    }
                    Text(step.label)
                        .fontWeight(mode == .now ? .semibold : .regular)
                        .foregroundStyle(mode == .next ? .white.opacity(0.62) : mode == .done ? .white.opacity(0.75) : .white)
                }
                .font(.system(size: 12.5))
                .fixedSize()
            }
        }
    }
}

struct MacDJStripGlass: ViewModifier {
    let isYours: Bool
    let reduceTransparency: Bool

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(Capsule().fill(isYours ? Color(red: 0.24, green: 0.21, blue: 0.03) : Color(white: 0.16)))
                .overlay(Capsule().strokeBorder(isYours ? MacDJPalette.yours.opacity(0.8) : .white.opacity(0.4), lineWidth: 1))
        } else {
            content
                .background {
                    if isYours { Capsule().fill(MacDJPalette.yours.opacity(0.16)) }
                }
                .glassEffect(.regular, in: Capsule())
                .overlay {
                    if isYours { Capsule().strokeBorder(MacDJPalette.yours.opacity(0.6), lineWidth: 1) }
                }
        }
    }
}
