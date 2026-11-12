import SwiftUI

enum TVDecksFocus: Hashable {
    case autoMix
    case energy
    case lane(DeckSlot)
    case playPause
    case mixNow
    case extend
    case next
    case moves
    case handBack
    case retry
    case show
    case emptyChoose
    case emptyStart
}

struct TVDecksChromeStyle: ButtonStyle {
    var isProminent = false
    var isAvailable = true
    var diameter: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, isProminent: isProminent, isAvailable: isAvailable, diameter: diameter)
    }

    private struct Styled: View {
        let configuration: Configuration
        let isProminent: Bool
        let isAvailable: Bool
        let diameter: CGFloat?

        @Environment(\.isFocused) private var isFocused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .font(.tvBodyEmph)
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, diameter == nil ? 36 : 0)
                .frame(width: diameter, height: diameter ?? 76)
                .foregroundStyle(labelColor)
                .background {
                    Capsule()
                        .fill(Color.scChromeFocus)
                        .opacity(isFocused ? 1 : 0)
                }
                .liquidGlass(in: Capsule(), tint: isProminent ? Color.white.opacity(0.22) : nil)
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed ? 1.02 : (isFocused ? 1.08 : 1))
                .shadow(color: isFocused ? Color.scFocusShadow : .clear, radius: 18, y: 10)
                .focusEffectDisabled()
                .animation(reduceMotion ? nil : Motion.focus, value: isFocused)
        }

        private var labelColor: Color {
            if isFocused { return Color.scChromeFocusOn }
            return isAvailable ? Color.scTextPrimary : Color.scTextSecondary
        }
    }
}

// MARK: - Top bar

struct TVDecksTopBar: View {
    let model: DecksLiveModel
    var focus: FocusState<TVDecksFocus?>.Binding
    let isShowing: Bool
    let onTonight: () -> Void
    let onSession: () -> Void
    let onGuide: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Space.base) {
            autoMixMenu
                .opacity(isShowing ? 0 : 1)
                .disabled(isShowing)
            Spacer(minLength: Space.base)
            TVDecksRemoteChip(model: model)
            Spacer(minLength: Space.base)
            TVDecksEnergyMenu(model: model, focus: focus)
                .opacity(isShowing ? 0 : 1)
                .disabled(isShowing)
        }
        .frame(height: 88)
    }

    private var autoMixMenu: some View {
        Menu {
            Button {
                model.setAutoMix(!model.isAutoMixOn)
            } label: {
                Label(model.isAutoMixOn ? "Turn Off Auto Mix" : "Turn On Auto Mix", systemImage: "wand.and.stars")
            }
            Section("Style") {
                ForEach(DJProfile.all) { profile in
                    Button {
                        model.setStyle(profile.id)
                    } label: {
                        if model.isAutoMixOn, model.styleId == profile.id {
                            Label(profile.styleName, systemImage: "checkmark")
                        } else {
                            Text(profile.styleName)
                        }
                    }
                }
            }
            Button("Tonight…", systemImage: "text.bubble", action: onTonight)
            Button("Session…", systemImage: "slider.horizontal.3", action: onSession)
            Button("Decks Guide", systemImage: "questionmark.circle", action: onGuide)
            Button("Close Decks", systemImage: "power", role: .destructive, action: onClose)
        } label: {
            HStack(spacing: Space.snug) {
                Circle()
                    .fill(model.status.willMix ? Color.scSuccess : Color.white.opacity(0.4))
                    .frame(width: 16, height: 16)
                Text(title)
            }
        }
        .buttonStyle(TVDecksChromeStyle())
        .focused(focus, equals: .autoMix)
        .accessibilityLabel("Auto Mix")
        .accessibilityValue(title)
        .accessibilityIdentifier("decks.autoMix")
    }

    private var title: String {
        guard let style = model.styleName else { return "Auto Mix Off" }
        return "Auto Mix · \(style)"
    }
}

struct TVDecksRemoteChip: View {
    let model: DecksLiveModel

    var body: some View {
        if let remote = model.remote {
            Label(model.isRemoteMixing ? "Mixing from \(remote.name)" : "\(remote.name) is connected", systemImage: "iphone.gen3")
                .font(.tvCalloutEmph)
                .foregroundStyle(Color.scTextPrimary)
                .lineLimit(1)
                .padding(.horizontal, 28)
                .frame(height: 64)
                .liquidGlass(in: Capsule(), tint: model.isRemoteMixing ? Color.scWarning.opacity(0.35) : nil)
                .contentTransition(.opacity)
                .accessibilityElement(children: .combine)
                .transition(.opacity)
        }
    }
}

struct TVDecksEnergyMenu: View {
    let model: DecksLiveModel
    var focus: FocusState<TVDecksFocus?>.Binding

    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        let energy = model.energy
        Menu {
            Button("Raise Energy", systemImage: "arrow.up") { model.nudgeEnergy(by: 1) }
                .disabled(!energy.canAdjust || energy.level >= 10)
            Button("Lower Energy", systemImage: "arrow.down") { model.nudgeEnergy(by: -1) }
                .disabled(!energy.canAdjust || energy.level <= 1)
            Toggle("Follow the Night", isOn: settings.djEnergyFollowsNightBinding)
        } label: {
            HStack(spacing: Space.snug) {
                TVDecksEnergyCurve(energy: energy)
                    .frame(width: 200, height: 44)
                Text("Energy \(energy.level)")
                    .monospacedDigit()
            }
        }
        .buttonStyle(TVDecksChromeStyle())
        .focused(focus, equals: .energy)
        .accessibilityLabel("Energy")
        .accessibilityValue("\(energy.level) of 10" + (energy.sourceText.map { ", \($0)" } ?? ""))
        .accessibilityIdentifier("decks.energy")
    }
}

struct TVDecksEnergyCurve: View {
    let energy: DecksEnergy

    var body: some View {
        Canvas { context, size in
            let points = energy.curve
            guard points.count > 1 else { return }
            let lower = Double(points.first?.offset ?? 0)
            let upper = Double(points.last?.offset ?? 1)
            let span = max(1, upper - lower)
            func x(_ offset: Int) -> CGFloat { CGFloat((Double(offset) - lower) / span) * size.width }
            func y(_ value: Double) -> CGFloat { size.height - 3 - CGFloat(value) * (size.height - 6) }
            let target = Double(energy.level - 1) / 9
            var guide = Path()
            guide.move(to: CGPoint(x: 0, y: y(target)))
            guide.addLine(to: CGPoint(x: size.width, y: y(target)))
            context.stroke(guide, with: .foreground, style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            var past = Path()
            var future = Path()
            var started = (past: false, future: false)
            for point in points {
                guard let value = point.energy else { continue }
                let p = CGPoint(x: x(point.offset), y: y(value))
                if point.offset <= 0 {
                    if started.past { past.addLine(to: p) } else { past.move(to: p); started.past = true }
                }
                if point.offset >= 0 {
                    if started.future { future.addLine(to: p) } else { future.move(to: p); started.future = true }
                }
            }
            context.stroke(past, with: .foreground, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            context.opacity = 0.5
            context.stroke(future, with: .foreground, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round, dash: [5, 5]))
            context.opacity = 1
            if let now = points.first(where: { $0.offset == 0 })?.energy {
                let dot = CGRect(x: x(0) - 6, y: y(now) - 6, width: 12, height: 12)
                context.fill(Path(ellipseIn: dot), with: .foreground)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Control strip

struct TVDecksControlStrip: View {
    let model: DecksLiveModel
    var focus: FocusState<TVDecksFocus?>.Binding
    let onPickNext: () -> Void

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: Space.roomy) {
                Button(action: model.togglePlayPause) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 32, weight: .semibold))
                }
                .buttonStyle(TVDecksChromeStyle(isProminent: true, diameter: 88))
                .focused(focus, equals: .playPause)
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
                .accessibilityIdentifier("decks.playPause")

                control(.mixNow, mixNowTitle, symbol: "arrow.triangle.merge", isAvailable: model.canMixNow, isProminent: model.canMixNow, id: "decks.mixNow", action: model.mixNow)
                control(.extend, "Extend", symbol: "arrow.right.to.line", isAvailable: model.canExtend, id: "decks.extend", action: model.extend)
                control(.next, "Next…", symbol: "text.badge.plus", isAvailable: true, id: "decks.next", action: onPickNext)
                TVDecksMovesMenu(model: model)
                    .focused(focus, equals: .moves)
                if !model.owned.isEmpty {
                    control(.handBack, "Hand Back", symbol: "hand.raised", isAvailable: true, id: "decks.handBack", action: model.handBack)
                        .accessibilityValue(model.owned.map(\.name).joined(separator: ", "))
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
        }
    }

    private var mixNowTitle: String {
        switch model.status {
        case .mixingLive: return "Mixing…"
        case .cutting: return "Cutting…"
        default: return "Mix Now"
        }
    }

    private func control(
        _ value: TVDecksFocus,
        _ title: String,
        symbol: String,
        isAvailable: Bool,
        isProminent: Bool = false,
        id: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            guard isAvailable else { return }
            action()
        } label: {
            Label(title, systemImage: symbol)
        }
        .buttonStyle(TVDecksChromeStyle(isProminent: isProminent, isAvailable: isAvailable))
        .focused(focus, equals: value)
        .accessibilityValue(isAvailable ? "" : "Unavailable")
        .accessibilityIdentifier(id)
    }
}

struct TVDecksMovesMenu: View {
    let model: DecksLiveModel

    var body: some View {
        Menu {
            Section("Next Mix") {
                Button {
                    model.chooseMove(nil)
                } label: {
                    if model.isMoveChosen {
                        Text("Let Auto Mix Choose")
                    } else {
                        Label("Let Auto Mix Choose", systemImage: "checkmark")
                    }
                }
                ForEach(DJPlanMoves.choices, id: \.self) { kind in
                    Button {
                        model.chooseMove(kind)
                    } label: {
                        if model.isMoveChosen, model.move == kind {
                            Label(DJPlanMoves.name(kind), systemImage: "checkmark")
                        } else {
                            Text(DJPlanMoves.name(kind))
                        }
                    }
                }
            }
            .disabled(!model.canChooseMove)
            Section("Now") {
                if model.canSwapBass {
                    Button("Swap the Bass", systemImage: "arrow.left.arrow.right") { model.swapBassNow() }
                }
                if model.onAir.loop == nil {
                    Button("Loop 4 Bars", systemImage: "repeat") { model.loop(beats: 16) }
                        .disabled(!model.canPerform(on: .onAir) || model.onAir.beats == nil)
                    Button("Loop 1 Bar", systemImage: "repeat.1") { model.loop(beats: 4) }
                        .disabled(!model.canPerform(on: .onAir) || model.onAir.beats == nil)
                } else {
                    Button("Exit Loop", systemImage: "repeat") { model.exitLoop() }
                }
                Button("Skip to Next Track", systemImage: "forward.fill") { model.skip() }
                    .disabled(model.next.isEmpty)
            }
        } label: {
            Label(title, systemImage: symbol)
        }
        .buttonStyle(TVDecksChromeStyle())
        .accessibilityLabel("Moves")
        .accessibilityValue(title)
        .accessibilityIdentifier("decks.moves")
    }

    private var title: String {
        guard let move = model.move else { return "Moves" }
        return DJPlanMoves.name(move)
    }

    private var symbol: String {
        switch model.move {
        case .loopMix?, .loopRoll?: return "repeat"
        case .cut?, .dropOnTheOne?: return "scissors"
        case .echoOut?: return "dot.radiowaves.right"
        default: return "wand.and.rays"
        }
    }
}
