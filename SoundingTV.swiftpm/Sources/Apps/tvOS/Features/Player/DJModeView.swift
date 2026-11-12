import SwiftUI
import Combine

struct DJModeView: View {
    var onClose: (() -> Void)? = nil

    @EnvironmentObject private var authService: AuthenticationService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var model = DecksLiveModel()
    @State private var show = TVDecksShowMode()
    @State private var accent: Color = .white
    @FocusState private var focus: TVDecksFocus?
    @State private var focusBeforeShow: TVDecksFocus?
    @State private var showingPicker = false
    @State private var showingGuide = false
    @State private var showingStartConfiguration = false
    @State private var showingTonight = false
    @Namespace private var decksSpace

    var body: some View {
        ZStack {
            TVDecksBackdropLayer(model: model)
            Group {
                if model.hasTrack {
                    stage
                } else {
                    empty
                }
            }
            .disabled(showingPicker)
            if show.isShowing {
                showTarget
            }
            if showingPicker {
                TVDecksPicker(model: model, onClose: closePicker)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .environment(\.colorScheme, .dark)
        .animation(reduceMotion ? nil : Motion.settle, value: showingPicker)
        .animation(reduceMotion ? nil : .smooth(duration: 0.6), value: show.isShowing)
        .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: model.hasNext)
        .onExitCommand(perform: exitAction)
        .onPlayPauseCommand {
            if show.isShowing { wake() } else { model.togglePlayPause() }
        }
        .defaultFocus($focus, model.hasTrack ? (model.canMixNow ? .mixNow : .playPause) : .emptyChoose)
        .onChange(of: authService.sessionHealth) { _, health in
            if health.needsSignIn { close() }
        }
        .onChange(of: showEligible, initial: true) { _, eligible in
            show.setEligible(eligible)
        }
        .onChange(of: show.isShowing) { _, isShowing in
            showDidChange(isShowing)
        }
        .task(id: model.nextArtwork) {
            guard let url = model.nextArtwork else {
                accent = .white
                return
            }
            let resolved = await CollectionAccentStore.shared.accent(for: url)
            guard !Task.isCancelled else { return }
            accent = resolved.map { $0.isNeutral ? .white : $0.tint(for: .dark) } ?? .white
        }
        .onAppear(perform: appear)
        .onDisappear(perform: disappear)
        .fullScreenCover(isPresented: $showingGuide) {
            DJModeGuideView()
        }
        .sheet(isPresented: $showingStartConfiguration) {
            AutoDJStartConfigurationView(configuration: SettingsStore.shared.djStartConfiguration) { configuration in
                Task {
                    if !(await model.startAutoMix(configuration)) { openPicker() }
                }
            }
        }
        .sheet(isPresented: $showingTonight) {
            NavigationStack {
                Form {
                    AutoMixIntentSection()
                }
                .navigationTitle("Tonight")
            }
        }
    }

    // MARK: Stage

    private var stage: some View {
        VStack(spacing: 0) {
            TVDecksTopBar(
                model: model,
                focus: $focus,
                isShowing: show.isShowing,
                onTonight: { showingTonight = true },
                onSession: { showingStartConfiguration = true },
                onGuide: { showingGuide = true },
                onClose: closeDecks
            )
            .focusSection()
            Spacer(minLength: Space.base)
            TVDeckHeads(model: model, accent: accent, namespace: decksSpace)
            Spacer(minLength: Space.roomy)
            TVDeckLane(model: model, slot: .onAir, accent: accent, isShowing: show.isShowing, focus: $focus, onPickNext: openPicker)
            TVDecksMixBand(model: model, accent: accent, focus: $focus, isShowing: show.isShowing)
            Group {
                if model.hasNext {
                    TVDeckLane(model: model, slot: .next, accent: accent, isShowing: show.isShowing, focus: $focus, onPickNext: openPicker)
                } else {
                    TVDecksNextEmpty(model: model, isShowing: show.isShowing, focus: $focus, onPickNext: openPicker)
                }
            }
            .transition(.opacity)
            Spacer(minLength: Space.roomy)
            TVDecksControlStrip(model: model, focus: $focus, onPickNext: openPicker)
                .focusSection()
                .opacity(show.isShowing ? 0 : 1)
                .disabled(show.isShowing)
        }
        .padding(.horizontal, 88)
        .padding(.top, 48)
        .padding(.bottom, 52)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("Nothing on the Decks", systemImage: "opticaldiscdrive")
        } description: {
            Text("Choose a track to start, or let Auto Mix start from your Likes.")
        } actions: {
            HStack(spacing: Space.base) {
                Button("Choose a Track…", systemImage: "music.note.list", action: openPicker)
                    .buttonStyle(TVDecksChromeStyle(isProminent: true))
                    .focused($focus, equals: .emptyChoose)
                    .accessibilityIdentifier("decks.empty.choose")
                Button("Start Auto Mix…", systemImage: "wand.and.stars") { showingStartConfiguration = true }
                    .buttonStyle(TVDecksChromeStyle())
                    .focused($focus, equals: .emptyStart)
                    .accessibilityIdentifier("decks.empty.start")
            }
            .padding(.top, Space.base)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var showTarget: some View {
        Color.clear
            .contentShape(Rectangle())
            .ignoresSafeArea()
            .focusable()
            .focused($focus, equals: .show)
            .focusEffectDisabled()
            .onTapGesture(perform: wake)
            .onMoveCommand { _ in wake() }
            .accessibilityLabel("Decks")
            .accessibilityHint("Press any button to show the controls")
            .accessibilityIdentifier("decks.show")
    }

    // MARK: Behaviour

    private var showEligible: Bool {
        model.hasTrack && model.isPlaying && !showingPicker && !showingGuide && !showingStartConfiguration && !showingTonight
    }

    private var exitAction: (() -> Void)? {
        if show.isShowing { return wake }
        if showingPicker { return closePicker }
        if onClose == nil { return { dismiss() } }
        return nil
    }

    private func appear() {
        DJTransitionService.shared.isEnabled = true
        PlayerService.shared.armMixSessionIfNeeded()
        let remote = CompanionServer.shared.$decksRemote
            .map { $0.map { DecksRemoteState(name: $0.name, touchedAt: $0.touchedAt) } }
            .eraseToAnyPublisher()
        model.start(remote: remote)
        CompanionServer.shared.noteDecksVisible(true)
        TVDecksPresence.isOnScreen = true
    }

    private func disappear() {
        CompanionServer.shared.noteDecksVisible(false)
        TVDecksPresence.isOnScreen = false
        show.setEligible(false)
        model.stop()
    }

    private func wake() {
        show.wake()
    }

    private func showDidChange(_ isShowing: Bool) {
        if isShowing {
            focusBeforeShow = focus
            focus = .show
        } else {
            focus = focusBeforeShow ?? (model.canMixNow ? .mixNow : .playPause)
            focusBeforeShow = nil
        }
    }

    private func openPicker() {
        show.wake()
        showingPicker = true
    }

    private func closePicker() {
        showingPicker = false
        focus = model.hasTrack ? .lane(.next) : .emptyChoose
    }

    private func closeDecks() {
        PlayerService.shared.endDJSession()
        close()
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }
}

private struct TVDecksBackdropLayer: View {
    let model: DecksLiveModel

    var body: some View {
        ZStack {
            DecksBackdropMesh(outgoing: model.onAirArtwork, incoming: model.nextArtwork, blend: model.blend)
            LinearGradient(
                colors: [Color.black.opacity(0.2), Color.black.opacity(0.5)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

enum TVDecksEntry: Equatable {
    case stayOnNowPlaying
    case openDecks
    case configureFirst

    enum Event: Equatable {
        case nowPlayingAppeared
        case choseDecks
    }

    static func entry(for event: Event, sessionIsActive: Bool, hasStartOptions: Bool) -> TVDecksEntry {
        switch event {
        case .nowPlayingAppeared:
            return .stayOnNowPlaying
        case .choseDecks:
            return sessionIsActive || hasStartOptions ? .openDecks : .configureFirst
        }
    }
}
