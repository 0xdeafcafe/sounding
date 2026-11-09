import SwiftUI

struct MacDJWindow: View {
    @ObservedObject private var model = MacDJPerformModel.shared
    @ObservedObject private var console = MacConsoleController.shared
    @ObservedObject private var director = PlayerService.shared.djDirector
    @StateObject private var prep = MacPrepModel()
    @State private var didClaimManualEngine = false
    @State private var loadErrorMessage: String?
    @State private var isShowingDecksView = false
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isAutoMixEnabled: Bool {
        director.snapshot?.isAutoMixEnabled ?? PlayerService.shared.isAutoMixEnabled
    }

    var body: some View {
        content
            .navigationTitle("Decks")
            .toolbar { toolbar }
            .background(modeShortcuts)
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .onKeyPress(keys: MacDJKeyboard.consoleKeys, phases: [.down, .up, .repeat]) { press in
                model.mode == .perform ? MacDJKeyboard.handle(press) : .ignored
            }
            .onAppear {
                isFocused = true
                updateEngineClaim(auto: isAutoMixEnabled)
            }
            .onChange(of: director.snapshot?.isAutoMixEnabled) { _, value in
                updateEngineClaim(auto: value ?? PlayerService.shared.isAutoMixEnabled)
            }
            .onDisappear { releaseEngineClaimIfNeeded() }
            .sheet(item: $console.loadTarget) { target in
                MacLibraryBrowserView(targetDeck: target) { track, deck in
                    Task {
                        do {
                            try await MacMixLoader.load(track, into: deck)
                        } catch {
                            loadErrorMessage = "Couldn\u{2019}t load \u{201C}\(track.title)\u{201D}. Try again."
                        }
                        console.loadTarget = nil
                    }
                }
            }
            .sheet(isPresented: $console.showingAutoDJStartConfiguration) {
                AutoDJStartConfigurationView { configuration in
                    PlayerService.shared.startDJSession(configuration: configuration, reconfigure: true)
                }
                .frame(minWidth: 560, idealWidth: 580, minHeight: 620, idealHeight: 660)
            }
            .alert("Couldn\u{2019}t Load the Track", isPresented: Binding(get: { loadErrorMessage != nil }, set: { if !$0 { loadErrorMessage = nil } })) {
                Button("OK") { loadErrorMessage = nil }
            } message: {
                Text(loadErrorMessage ?? "")
            }
            .macEffectRackPresentation()
            .tint(Color.scAccent)
            .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var content: some View {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SOUNDING_TV_DJ_FIXTURE"] == "states" {
            MacDJStatesGallery()
        } else {
            screens
        }
        #else
        screens
        #endif
    }

    @ViewBuilder
    private var screens: some View {
        switch model.mode {
        case .perform:
            MacDJPerformView(model: model, context: deckContext, prep: prep)
                .overlay(alignment: .topLeading) {
                    MacDJModeSwitch(mode: $model.mode).padding(.leading, 16).padding(.top, 6)
                }
                .overlay(alignment: .top) {
                    if let refusal = model.refusal {
                        DJRefusalBanner(message: refusal).padding(.top, 52)
                    }
                }
        case .prep:
            DJPrepScreen(model: prep, context: deckContext) {
                HStack(spacing: 12) {
                    MacDJModeSwitch(mode: $model.mode)
                    MacDJLiveStrip(state: model.state(at: Date()))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 8)
            }
        case .plan:
            MacDJPlanHost(perform: model)
                .padding(.top, 46)
                .background(DJPlanPalette.canvas)
                .environment(\.colorScheme, .dark)
                .overlay(alignment: .topLeading) {
                    MacDJModeSwitch(mode: $model.mode).padding(.leading, 16).padding(.top, 6)
                }
        }
    }

    var deckContext: DJDeckContext {
        var context = DJDeckContext.live { id in
            PlayerService.shared.queue.first { $0.id == id } ?? MacDeckTrackRegistry.shared.tracks.values.first { $0.id == id }
        }
        let state = model.state(at: Date())
        context.decks = context.decks.map { slot in
            var slot = slot
            let deck = state.deck(slot.deck)
            slot.bpm = deck.bpm
            slot.key = deck.key
            slot.isOnAir = deck.role == .onAir
            if slot.title.isEmpty { slot.title = deck.title }
            return slot
        }
        if state.mix != nil, let leaving = state.mix?.leaving { context.incoming = leaving.other }
        context.playedTonight = PlayerService.shared.queue.prefix(PlayerService.shared.currentIndex).reversed().map {
            DJPlayedTrack(id: $0.id, title: $0.title, artworkURL: $0.artworkURL, detail: $0.user.displayName)
        }
        context.planTransition = { _ in model.mode = .plan }
        return context
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.mode == .perform {
                Button {
                    isShowingDecksView.toggle()
                } label: {
                    Label("Decks View", systemImage: "rectangle.3.group")
                }
                .help("Choose what the decks show")
                .popover(isPresented: $isShowingDecksView, arrowEdge: .bottom) {
                    MacDJDecksViewPopover(model: model, console: console)
                }
            }
            DJPlayersToolbarButton()
            Button {
                model.mode = .perform
                model.panelTab = .library
                model.isPanelOpen = true
            } label: {
                Label("Search Library", systemImage: "magnifyingglass")
            }
            .help("Search the library (\u{2318}F)")
            switch model.mode {
            case .perform:
                Button {
                    withAnimation(reduceMotion ? nil : .snappy) { model.isPanelOpen.toggle() }
                } label: {
                    Label(model.isPanelOpen ? "Hide Auto Mix Panel" : "Show Auto Mix Panel", systemImage: "sidebar.right")
                }
                .help(model.isPanelOpen ? "Hide the Auto Mix panel" : "Show the Auto Mix panel")
            case .prep:
                Button {
                    prep.inspectorChoice = !prep.isInspectorShown
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help("Show or hide the inspector (\u{2325}\u{2318}I)")
            case .plan:
                EmptyView()
            }
        }
    }

    private var modeShortcuts: some View {
        Group {
            ForEach(MacDJMode.allCases) { mode in
                Button(mode.title) { model.mode = mode }
                    .keyboardShortcut(mode.shortcut, modifiers: .command)
            }
            Button("Library") {
                model.mode = .perform
                model.panelTab = .library
                model.isPanelOpen = true
            }
            .keyboardShortcut("f", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func updateEngineClaim(auto: Bool) {
        if auto {
            releaseEngineClaimIfNeeded()
        } else if !didClaimManualEngine, !model.isFixture {
            PlayerService.shared.beginExternalManualDeckControl()
            didClaimManualEngine = true
        }
    }

    private func releaseEngineClaimIfNeeded() {
        guard didClaimManualEngine else { return }
        PlayerService.shared.endExternalManualDeckControl()
        didClaimManualEngine = false
    }
}

struct MacDJModeSwitch: View {
    @Binding var mode: MacDJMode
    static let reservedWidth: CGFloat = 234

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(MacDJMode.allCases) { candidate in
                    modeButton(candidate)
                }
            }
        }
        .buttonBorderShape(.capsule)
        .tint(Color.scAccent)
        .environment(\.colorScheme, .dark)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mode")
    }

    @ViewBuilder
    private func modeButton(_ candidate: MacDJMode) -> some View {
        let button = Button(candidate.title) { mode = candidate }
            .help("\(candidate.title) (\u{2318}\(candidate.shortcut.character))")
            .accessibilityAddTraits(candidate == mode ? .isSelected : [])
        if candidate == mode {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.glass)
        }
    }
}

struct MacDJLiveStrip: View {
    let state: MacDJPerformState

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 12) {
            deckChip(state.deck(state.mix?.leaving ?? .a))
            if let mix = state.mix, let step = mix.currentStep {
                Label("\(step.label) \u{00B7} bar \(max(1, Int(mix.nowBar)))/\(Int(mix.totalBars))", systemImage: "sparkle")
                    .labelStyle(MacDJAutoLabelStyle())
                    .font(.system(size: 13))
                    .lineLimit(1)
            }
            deckChip(state.deck((state.mix?.leaving ?? .a).other))
        }
        .padding(.horizontal, 6)
        .frame(height: 34)
        .modifier(MacDJStripGlass(isYours: false, reduceTransparency: reduceTransparency))
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Decks")
    }

    @ViewBuilder
    private func deckChip(_ deck: MacDJDeckState) -> some View {
        if !deck.isEmpty {
            HStack(spacing: 6) {
                MacDJDeckBadge(deck: deck.deck)
                Text(deck.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if deck.role == .onAir {
                    Text(deck.remainingText).font(.system(size: 13).monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                } else if deck.role == .mixingIn {
                    MacDJChip(kind: .mixingIn)
                }
            }
            .padding(.horizontal, 6)
        }
    }
}

struct MacDJPlanHost: View {
    @ObservedObject var perform: MacDJPerformModel
    @State private var model: DJPlanModel?
    @State private var generation = 0

    var body: some View {
        Group {
            if let model {
                DJPlanScreen(model: model)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: generation) {
            if model == nil { model = await Self.makeModel(perform: perform) { generation += 1; model = nil } }
        }
        .task(id: model.map(ObjectIdentifier.init)) {
            while !Task.isCancelled, let model {
                let live = perform.planLive(at: Date())
                if model.live != live { model.live = live }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .onDisappear { model?.headphones.stopPreview() }
    }

    static func makeModel(perform: MacDJPerformModel, reload: @escaping @MainActor () -> Void) async -> DJPlanModel {
        let player = PlayerService.shared
        let tracks = Dictionary(player.queue.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let model = await DJPlanModel.live(player: player, headphones: DJPlanCuePreview(tracks: tracks))
        model.actions.extend = { perform.extend() }
        model.actions.mixNow = {
            guard player.canStartMix else { return }
            player.startMix()
        }
        model.actions.takeOverAll = { perform.takeOverAll() }
        model.actions.skip = { track in
            guard let index = player.queue.firstIndex(where: { $0.id == track.id }), index > player.currentIndex else { return }
            Task { @MainActor in
                await player.removeFromQueue(at: index)
                reload()
            }
        }
        model.actions.reorder = { order in
            let base = max(0, player.currentIndex - 1)
            for (offset, track) in order.enumerated() {
                let target = base + offset
                guard target > player.currentIndex,
                      let source = player.queue.firstIndex(where: { $0.id == track.id }),
                      source != target else { continue }
                player.moveQueueItem(from: source, to: target)
            }
        }
        model.live = perform.planLive(at: Date())
        return model
    }
}

extension MacDJPerformModel {
    func planLive(at date: Date) -> DJPlanLive? {
        let state = state(at: date)
        let leaving = state.mix?.leaving ?? state.decks.first { $0.role == .onAir }?.deck ?? .a
        let from = state.deck(leaving)
        guard !from.isEmpty else { return nil }
        let to = state.deck(leaving.other)
        var live = DJPlanLive(from: .init(deck: leaving, title: from.title, remaining: from.duration > 0 ? max(0, from.duration - from.position) : nil))
        if let mix = state.mix, !to.isEmpty {
            live.to = .init(deck: leaving.other, title: to.title)
            if let step = mix.currentStep {
                live.step = "\(step.label) \u{00B7} bar \(max(1, Int(mix.nowBar))) of \(Int(mix.totalBars))"
            }
        }
        if let auto = AutoMixLive.shared.state, auto.stage == .upcoming {
            live.nextStartsIn = max(0, auto.clock(at: date).secondsUntilStart)
        }
        return live
    }
}

struct MacDJDecksViewPopover: View {
    @ObservedObject var model: MacDJPerformModel
    @ObservedObject var console: MacConsoleController

    var body: some View {
        Form {
            Section("Show") {
                Toggle("Mixer", isOn: $model.layout.showsMixer)
                Toggle("Effects", isOn: $model.layout.showsEffects)
                Toggle("Pads", isOn: $model.layout.showsPads)
                Toggle("Jog Wheels", isOn: $model.layout.showsJog)
                Toggle("Auto Mix Panel", isOn: $model.isPanelOpen)
                Toggle("Keyboard Shortcuts", isOn: $console.showKeyboardShortcuts)
            }
            Section("Pads") {
                ForEach(MixEngine.Deck.allCases, id: \.self) { deck in
                    Picker("Deck \(deck.label)", selection: Binding(
                        get: { model.padModes[deck] ?? .hotCue },
                        set: { model.padModes[deck] = $0 }
                    )) {
                        ForEach(MacDJPadMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }
            }
            DJHeadphoneSettingsSection()
        }
        .formStyle(.grouped)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension EnvironmentValues {
    @Entry var macMainSidebarVisible = false
    @Entry var macMainInspectorVisible = false
}
