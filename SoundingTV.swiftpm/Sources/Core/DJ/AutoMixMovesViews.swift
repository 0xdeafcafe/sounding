import SwiftUI

struct AutoMixMoveGlyphShape: Shape {
    let move: AutoMixMove

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: rect.minX + x * w, y: rect.minY + y * h) }
        var path = Path()
        switch move {
        case .loopMix:
            path.addRoundedRect(in: CGRect(origin: p(0.3, 0.08), size: CGSize(width: 0.4 * w, height: 0.34 * h)), cornerSize: CGSize(width: 0.17 * h, height: 0.17 * h))
            path.move(to: p(0, 0.25)); path.addLine(to: p(0.3, 0.25))
            path.addRoundedRect(in: CGRect(origin: p(0.36, 0.58), size: CGSize(width: 0.4 * w, height: 0.34 * h)), cornerSize: CGSize(width: 0.17 * h, height: 0.17 * h))
            path.move(to: p(0.76, 0.75)); path.addLine(to: p(1, 0.75))
        case .longBlend:
            path.move(to: p(0, 0.15)); path.addCurve(to: p(1, 0.85), control1: p(0.55, 0.15), control2: p(0.45, 0.85))
            path.move(to: p(0, 0.85)); path.addCurve(to: p(1, 0.15), control1: p(0.55, 0.85), control2: p(0.45, 0.15))
        case .filterFade:
            path.move(to: p(0, 0.2)); path.addCurve(to: p(1, 0.5), control1: p(0.35, 0.05), control2: p(0.6, 0.55))
            path.move(to: p(0, 0.55)); path.addCurve(to: p(1, 0.85), control1: p(0.35, 0.4), control2: p(0.6, 0.9))
        case .dropIn:
            path.move(to: p(0, 0.25)); path.addLine(to: p(0.5, 0.25))
            path.move(to: p(0.12, 0.85)); path.addLine(to: p(0.42, 0.85)); path.addLine(to: p(0.52, 0.3)); path.addLine(to: p(0.6, 0.85)); path.addLine(to: p(1, 0.85))
        case .quickCut:
            path.move(to: p(0, 0.22)); path.addLine(to: p(0.42, 0.22)); path.addLine(to: p(0.42, 0.82)); path.addLine(to: p(1, 0.82))
        case .echoOut:
            path.move(to: p(0, 0.35)); path.addLine(to: p(0.42, 0.35))
            for (x, half) in [(0.56, 0.2), (0.7, 0.14), (0.84, 0.08)] {
                path.move(to: p(x, 0.35 - half)); path.addLine(to: p(x, 0.35 + half))
            }
            path.move(to: p(0.4, 0.85)); path.addLine(to: p(1, 0.85))
        }
        return path
    }
}

struct AutoMixMoveGlyph: View {
    let move: AutoMixMove
    var width: CGFloat = 32
    var lineWidth: CGFloat = 1.6

    var body: some View {
        AutoMixMoveGlyphShape(move: move)
            .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .frame(width: width, height: width * 0.62)
            .accessibilityHidden(true)
    }
}

struct AutoMixHourStrip: View {
    let style: AutoMixStyle
    var count = 8
    var horizontal = false

    var body: some View {
        Group {
            if horizontal {
                HStack(alignment: .center, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        title
                        summary
                    }
                    .frame(maxWidth: 240, alignment: .leading)
                    Spacer(minLength: 0)
                    glyphs
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    title
                    glyphs
                    summary
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("An hour of your Auto Mix. \(style.hourSummary)")
    }

    private var title: some View {
        Text("An hour of your Auto Mix").font(.headline)
    }

    private var summary: some View {
        Text(style.hourSummary)
            .font(horizontal ? .callout : .subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var glyphs: some View {
        let moves = style.hour(count: count)
        return HStack(spacing: 0) {
            ForEach(Array(moves.enumerated()), id: \.offset) { index, move in
                AutoMixMoveGlyph(move: move, width: horizontal ? 30 : 32, lineWidth: 1.8)
                    .foregroundStyle(style.lean(move) == .favourite ? .primary : .secondary)
                if index < moves.count - 1 { Spacer(minLength: horizontal ? 12 : 6) }
            }
        }
        .frame(maxWidth: horizontal ? 420 : .infinity)
    }
}

struct AutoMixMovesView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var feedback = AutoMixFeedbackStore.shared
    @State private var history = MixHistoryStore.shared
    @State private var pickingSavedMix = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    static let lockLine = "Always on the phrase. Never two vocals at once. Never in the busy part of a track."

    var body: some View {
        ScrollViewReader { proxy in
            form
                #if DEBUG
                .task {
                    guard ProcessInfo.processInfo.environment["SOUNDING_TV_YOUR_MOVES_SCROLL"] == "flair" else { return }
                    try? await Task.sleep(for: .seconds(1.5))
                    proxy.scrollTo("flair", anchor: .top)
                }
                #endif
        }
    }

    private var form: some View {
        Form {
            #if os(macOS)
            AutoMixBasicsSections()
            #endif
            AutoMixIntentSection()
            hourSection
            transitionsSection
            betweenSection
            #if os(macOS)
            alwaysSection
            #endif
            flairSection
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .sheet(isPresented: $pickingSavedMix) {
            AutoMixSavedMixPicker(mixes: history.library.mixes) { mix in
                learn(from: mix)
                pickingSavedMix = false
            } onCancel: {
                pickingSavedMix = false
            }
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 380)
            #endif
        }
        #if DEBUG
        .onAppear(perform: installFixtureIfNeeded)
        #endif
    }

    private var style: AutoMixStyle { settings.djMoveStyle }

    // MARK: - Sections

    private var hourSection: some View {
        Section {
            #if os(macOS)
            AutoMixHourStrip(style: style, count: 10, horizontal: true)
            #else
            AutoMixHourStrip(style: style, count: 8)
            Label {
                Text(Self.lockLine)
            } icon: {
                Image(systemName: "lock.fill")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            #endif
        }
    }

    private var transitionsSection: some View {
        Section {
            ForEach(AutoMixMove.allCases) { move in
                leanRow(move)
            }
        } header: {
            Text("Transitions")
        } footer: {
            Text("Your ratings fine-tune these. Every mix still has to suit the two tracks.")
        }
    }

    @ViewBuilder
    private func leanRow(_ move: AutoMixMove) -> some View {
        let binding = Binding(
            get: { settings.djMoveStyle.lean(move) },
            set: { lean in settings.updateDJMoveStyle { $0.setLean(lean, for: move) } }
        )
        #if os(macOS)
        HStack(spacing: 10) {
            AutoMixMoveGlyph(move: move, width: 28)
                .foregroundStyle(.secondary)
            Text(move.title)
            Text(move.detail).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Picker(move.title, selection: binding) {
                ForEach(AutoMixLean.allCases) { Text($0.title).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        #elseif os(tvOS)
        Picker(selection: binding) {
            ForEach(AutoMixLean.allCases) { Text($0.title).tag($0) }
        } label: {
            Text(move.title)
        }
        .pickerStyle(.navigationLink)
        #else
        let stacked = dynamicTypeSize.isAccessibilitySize
        (stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 14))) {
            HStack(spacing: 14) {
                AutoMixMoveGlyph(move: move, width: 32)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(move.title)
                    Text(move.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if !stacked { Spacer(minLength: 4) }
            Picker(move.title, selection: binding) {
                ForEach(AutoMixLean.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .tint(.secondary)
        }
        #endif
    }

    private var betweenSection: some View {
        Section {
            Picker("Surprises", selection: settings.djPerformanceLevelBinding) {
                ForEach(MixPerformanceLevel.allCases) { level in
                    Text(level.displayName).tag(level)
                }
            }
            #if os(tvOS)
            .pickerStyle(.navigationLink)
            #endif
            #if os(macOS)
            LabeledContent("Moves") {
                HStack(spacing: 16) {
                    ForEach(MixPerformanceMove.Kind.allCases, id: \.self) { kind in
                        Toggle(Self.title(kind), isOn: allowedBinding(kind))
                            .toggleStyle(.checkbox)
                    }
                }
            }
            .disabled(settings.djPerformanceLevel == .off)
            #else
            ForEach(MixPerformanceMove.Kind.allCases, id: \.self) { kind in
                Toggle(Self.title(kind), isOn: allowedBinding(kind))
                    .disabled(settings.djPerformanceLevel == .off)
            }
            #endif
        } header: {
            Text("Between Mixes")
        } footer: {
            Text("Small moves inside a track, away from vocals and transitions.")
        }
    }

    #if os(macOS)
    private var alwaysSection: some View {
        Section {
            LabeledContent("On the phrase", value: "Always")
            LabeledContent("Two vocals at once", value: "Never")
            LabeledContent("Mixing in the busy part of a track", value: "Never")
        } header: {
            Text("Always")
        }
    }
    #endif

    private var flairSection: some View {
        let lines = flairLines
        return Section {
            if lines.count >= 2 {
                AutoMixFlairSummary(lines: lines.map(\.text))
            }
            ForEach(lines) { line in
                flairRow(line)
            }
            Button {
                pickingSavedMix = true
            } label: {
                Label("More Like a Saved Mix…", systemImage: "sparkles")
            }
            AutoMixLearnedPreferencesRow()
        } header: {
            Text("Your Flair")
        } footer: {
            Text(lines.isEmpty ? "Rate a few mixes and what Auto Mix learns shows here." : Self.flairFooter)
        }
        .id("flair")
    }

    private static var flairFooter: String {
        #if os(iOS)
        "Learned from your ratings and saved mixes. Swipe to forget one."
        #elseif os(macOS)
        "Learned from your ratings and saved mixes. Control-click to forget one."
        #else
        "Learned from your ratings and saved mixes. Press and hold to forget one."
        #endif
    }

    @ViewBuilder
    private func flairRow(_ line: AutoMixFlairLine) -> some View {
        let row = HStack(spacing: 12) {
            Label {
                Text(line.text)
            } icon: {
                Image(systemName: line.symbolName).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(line.evidence)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        #if os(tvOS)
        .focusable()
        #endif
        .accessibilityElement(children: .combine)
        .contextMenu {
            Button("Forget", systemImage: "trash", role: .destructive) { forget(line) }
        }
        #if os(iOS)
        row.swipeActions {
            Button("Forget", role: .destructive) { forget(line) }
        }
        #else
        row
        #endif
    }

    private var flairLines: [AutoMixFlairLine] {
        var nudges = style.nudges
        #if DEBUG
        if nudges.isEmpty, ProcessInfo.processInfo.environment["SOUNDING_TV_AUTOMIX_FLAIR_FIXTURE"] == "1" { nudges = AutoMixFlair.fixtureNudges }
        #endif
        return AutoMixFlair.lines(ratings: feedback.ratings, nudges: nudges)
    }

    private func forget(_ line: AutoMixFlairLine) {
        switch line.source {
        case .moves, .lengths:
            feedback.forget { AutoMixFlair.matches($0, line.source) }
        case .nudgedMove, .nudgedLength, .nudgedKey:
            settings.updateDJMoveStyle { $0.nudges = AutoMixFlair.forgetting(line.source, in: $0.nudges) }
        }
    }

    private func learn(from mix: SavedMix) {
        let traits = AutoMixFlair.traits(of: mix.entry)
        settings.updateDJMoveStyle { $0.nudges.learn(move: traits.move, blendBars: traits.blendBars, keySteps: traits.keySteps) }
    }

    private func allowedBinding(_ kind: MixPerformanceMove.Kind) -> Binding<Bool> {
        Binding(
            get: { settings.djMoveStyle.allows(kind) },
            set: { allowed in settings.updateDJMoveStyle { $0.setAllowed(allowed, kind) } }
        )
    }

    static func title(_ kind: MixPerformanceMove.Kind) -> String {
        switch kind {
        case .loopRoll: return "Loop Roll"
        case .highPassBuild: return "Filter Build"
        case .lowPassDip: return "Filter Dip"
        case .echoThrow: return "Echo Throw"
        }
    }

    #if DEBUG
    private func installFixtureIfNeeded() {
        guard ProcessInfo.processInfo.environment["SOUNDING_TV_AUTOMIX_FLAIR_FIXTURE"] == "1", feedback.ratings.isEmpty else { return }
        feedback.installFixture(AutoMixFlair.fixtureRatings())
    }
    #endif
}

struct AutoMixSavedMixPicker: View {
    let mixes: [SavedMix]
    let onPick: (SavedMix) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if mixes.isEmpty {
                    ContentUnavailableView(
                        "No Saved Mixes",
                        systemImage: "bookmark",
                        description: Text("Save a mix you love and Auto Mix can do more like it.")
                    )
                } else {
                    List(mixes) { mix in
                        Button {
                            onPick(mix)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mix.name).foregroundStyle(.primary)
                                Text(Self.summary(AutoMixFlair.traits(of: mix.entry)))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("More Like a Saved Mix")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }

    static func summary(_ traits: AutoMixSavedMixTraits) -> String {
        var parts: [String] = []
        if let move = traits.move { parts.append(move.title) }
        if let bars = traits.blendBars { parts.append("\(bars) bars") }
        if let steps = traits.keySteps { parts.append(steps == 0 ? "Same key" : steps == 1 ? "One step round the wheel" : "\(steps) steps apart") }
        return parts.isEmpty ? "Mix" : parts.joined(separator: " · ")
    }
}

#if !os(tvOS)
struct AutoMixBasicsSections: View {
    @ObservedObject private var store = SettingsStore.shared

    private var footer: String {
        guard store.djAutoMixEnabled else { return "Blends one track into the next." }
        return DJProfile.profile(id: store.djDefaultProfileId)?.adventureSummary ?? "Blends one track into the next."
    }

    var body: some View {
        Section {
            Toggle("Auto Mix", isOn: store.djAutoMixEnabledBinding)
            if store.djAutoMixEnabled {
                Picker("Style", selection: store.djDefaultProfileIdBinding) {
                    ForEach(DJProfile.all) { profile in
                        Text(profile.styleName).tag(profile.id)
                    }
                }
                Picker("Blend", selection: store.djBlendBinding) {
                    ForEach(DJBlendLength.allCases) { blend in
                        Text(blend.displayName).tag(blend)
                    }
                }
                Toggle("Keep Queue Order", isOn: store.djKeepQueueOrderBinding)
                AutoMixLiveStatusRow()
            }
        } footer: {
            Text(footer)
        }

        if store.djAutoMixEnabled {
            Section("Energy") {
                Toggle("Follow the Night", isOn: store.djEnergyFollowsNightBinding)
                Slider(value: store.djEnergyLevelBinding, in: 0...1) {
                    Text("Energy")
                } minimumValueLabel: {
                    Text("Chill")
                } maximumValueLabel: {
                    Text("Peak")
                }
                .disabled(store.djEnergyFollowsNight)
                Slider(value: store.djRiserLevelBinding, in: 0...1) {
                    Text("Riser")
                } minimumValueLabel: {
                    Text("Off")
                } maximumValueLabel: {
                    Text("Loud")
                }
                .disabled(store.djDefaultProfileId == .wedding)
            }
        }
    }
}

struct AutoMixLiveStatusRow: View {
    @ObservedObject private var player = PlayerService.shared

    var body: some View {
        let decision = player.automaticMixDecision
        let countdown = decision.countdownText(currentTime: player.currentTime)
        LabeledContent("Status", value: countdown.map { "\(decision.statusLabel) \($0)" } ?? decision.statusLabel)
    }
}
#endif
