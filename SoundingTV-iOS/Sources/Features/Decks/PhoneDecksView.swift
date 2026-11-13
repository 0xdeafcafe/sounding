import SwiftUI

struct PhoneDecksView: View {
    var onClose: (() -> Void)?

    @StateObject private var model = PhoneDecksModel.shared
    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPresented
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(DecksOrientationLock.storageKey, store: .sounding) private var locksLandscape = false
    @AppStorage("decks.showsLibrary", store: .sounding) private var showsLibrary = true
    @State private var picking: PhoneDeckPickTarget?
    @State private var showingView = false
    @State private var showingPlayOn = false
    @State private var showingControllers = false
    @State private var tempoKey: TempoKeyRequest?
    @State private var notice: String?
    @State private var place: Place?

    private enum Place {
        case here
        case tv
    }

    private enum DecksLayout {
        case pad
        case landscape
        case portrait
    }

    private struct TempoKeyRequest: Identifiable {
        let track: Track
        let deck: MixEngine.Deck
        var id: String { "\(deck.label)-\(track.id)" }
    }

    var body: some View {
        PhoneDecksPlaceReader(coordinator.output) { tv in
            Group {
                if let tv, place == .tv {
                    PhoneRemoteDecksView(client: coordinator.output.client, tvName: tv.name, showsClose: showsClose) {
                        place = .here
                    } onClose: {
                        close()
                    }
                } else {
                    local(tv)
                        .background { PhoneDecksBackdrop(url: model.backdropArtwork) }
                }
            }
            .onAppear { follow(tv) }
            .onChange(of: tv) { _, next in follow(next) }
        }
        .background(MacDJPalette.chassis.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .persistentSystemOverlays(.hidden)
        .overlay(alignment: .top) { noticeView }
        .sheet(item: $picking) { target in
            PhoneDeckPicker(target: target, reference: reference(for: target)) { track, target in
                pick(track, target)
            }
        }
        .sheet(isPresented: $showingView) {
            PhoneDecksViewSettings(model: model)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingPlayOn) {
            ConnectSheet(onDone: { showingPlayOn = false })
                .environmentObject(coordinator)
        }
        .sheet(isPresented: $showingControllers) {
            DJControllersSheet()
        }
        .sheet(item: $tempoKey, onDismiss: { refreshAnalysis() }) { request in
            TrackTempoKeySheet(track: request.track)
        }
        .onAppear { DecksOrientationLock.apply(locksLandscape) }
        .onDisappear { DecksOrientationLock.apply(false) }
        .onChange(of: locksLandscape) { _, locked in DecksOrientationLock.apply(locked) }
        #if DEBUG
        .onAppear(perform: applyFixtureOrientation)
        #endif
    }

    private var showsClose: Bool { isPresented }

    private func local(_ tv: PhoneDecksTV?) -> some View {
        GeometryReader { proxy in
            let size = proxy.size
            switch layout(for: size) {
            case .pad:
                pad(size: size, tv: mixable(tv))
            case .landscape:
                console { landscape($0, size: size, tv: mixable(tv)) }
            case .portrait:
                console { portrait($0, width: size.width, tv: mixable(tv)) }
            }
        }
    }

    private func console<Content: View>(@ViewBuilder _ content: @escaping (MacDJPerformState) -> Content) -> some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 15, paused: !consoleIsLive)) { context in
            let _ = model.tick
            content(model.state(at: context.date))
        }
    }

    private var consoleIsLive: Bool {
        scenePhase == .active && (model.fixture != nil || MixEngine.shared.decks.contains(where: \.isPlaying))
    }

    private func layout(for size: CGSize) -> DecksLayout {
        if horizontalSizeClass == .regular, verticalSizeClass == .regular, size.width >= 600 { return .pad }
        return size.width > size.height ? .landscape : .portrait
    }

    private func follow(_ tv: PhoneDecksTV?) {
        guard place == nil, let tv, tv.canMix, tv.isInDecks else { return }
        place = .tv
    }

    private func mixable(_ tv: PhoneDecksTV?) -> PhoneDecksTV? {
        guard let tv, tv.canMix, tv.isReachable else { return nil }
        return tv
    }

    // MARK: Layouts

    private func landscape(_ state: MacDJPerformState, size: CGSize, tv: PhoneDecksTV?) -> some View {
        let mixerWidth: CGFloat = 212
        let inner = size.width - 16
        let deckWidth = max(180, floor((inner - mixerWidth - 20) / 2))
        var mixerMetrics = PhoneDeckMetrics.compact
        mixerMetrics.knobRow = 46
        return VStack(spacing: 6) {
            topBar(state, tv: tv, includesStrip: true)
            waveforms(state)
                .frame(minHeight: 96, maxHeight: .infinity)
            HStack(alignment: .top, spacing: 10) {
                deck(.a, state: state, mirrored: false, narrow: deckWidth < 250)
                    .frame(width: deckWidth)
                PhoneDecksMixer(state: state, model: model, showsCaption: false, metrics: mixerMetrics)
                    .frame(width: mixerWidth)
                deck(.b, state: state, mirrored: true, narrow: deckWidth < 250)
                    .frame(width: deckWidth)
            }
            .frame(height: 180)
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    private func portrait(_ state: MacDJPerformState, width: CGFloat, tv: PhoneDecksTV?) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                portraitHeader(tv: tv)
                waveforms(state).frame(height: 160)
                deck(.a, state: state, mirrored: false, narrow: width < 360)
                    .frame(minHeight: 150)
                PhoneDecksMixer(state: state, model: model, showsAllBands: true, showsCrossfader: false, showsCaption: false)
                    .padding(.horizontal, 8)
                deck(.b, state: state, mirrored: false, narrow: width < 360)
                    .frame(minHeight: 150)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 8) {
                PhoneDecksCrossfader(state: state, model: model)
                    .padding(.horizontal, 12)
                PhoneDecksStrip(state: state, model: model) { picking = .next }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func pad(size: CGSize, tv: PhoneDecksTV?) -> some View {
        let inner = size.width - 40
        let mixerBetween = inner >= 860
        let mixerWidth: CGFloat = 300
        let deckWidth = mixerBetween ? floor((inner - mixerWidth - 32) / 2) : floor((inner - 16) / 2)
        let waveHeight = min(300, max(160, size.height * 0.26))
        let deckHeight: CGFloat = 204
        let mixerHeight = 4 * PhoneDeckMetrics.regular.knobRow + 6 + 44 + 6 + 20
        let consoleHeight = mixerBetween ? mixerHeight : deckHeight + 16 + mixerHeight
        let libraryRoom = size.height - 8 - 56 - waveHeight - consoleHeight - 36
        return VStack(spacing: 12) {
            console { state in
                VStack(spacing: 12) {
                    topBar(state, tv: tv, includesStrip: true)
                    waveforms(state).frame(height: waveHeight)
                    if mixerBetween {
                        HStack(alignment: .top, spacing: 16) {
                            deck(.a, state: state, metrics: .regular, mirrored: false, narrow: deckWidth < 320)
                                .frame(width: deckWidth, height: deckHeight)
                            PhoneDecksMixer(state: state, model: model, showsAllBands: true, metrics: .regular)
                                .frame(width: mixerWidth)
                            deck(.b, state: state, metrics: .regular, mirrored: true, narrow: deckWidth < 320)
                                .frame(width: deckWidth, height: deckHeight)
                        }
                        .frame(height: consoleHeight, alignment: .top)
                    } else {
                        HStack(alignment: .top, spacing: 16) {
                            deck(.a, state: state, metrics: .regular, mirrored: false, narrow: deckWidth < 320)
                                .frame(width: deckWidth, height: deckHeight)
                            deck(.b, state: state, metrics: .regular, mirrored: true, narrow: deckWidth < 320)
                                .frame(width: deckWidth, height: deckHeight)
                        }
                        PhoneDecksMixer(state: state, model: model, showsAllBands: true, metrics: .regular)
                            .frame(maxWidth: 460)
                            .frame(height: mixerHeight, alignment: .top)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            if showsLibrary, libraryRoom >= 180 {
                PhoneDeckBrowserPanel(reference: model.nextReference) { track, target in
                    pick(track, target)
                }
                .equatable()
                .frame(maxHeight: .infinity)
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    private func waveforms(_ state: MacDJPerformState) -> some View {
        MacDJStackedWaveforms(state: state, usesCanvas: model.isFixture) { model.zoomBars = $0 }
            .overlay { PhoneDecksWaveformTouch(model: model) }
    }

    private func deck(_ deck: MixEngine.Deck, state: MacDJPerformState, metrics: PhoneDeckMetrics = .compact, mirrored: Bool, narrow: Bool) -> some View {
        PhoneDeckPanel(deck: deck, state: state, model: model, metrics: metrics, mirrored: mirrored, showsTempoLabel: !narrow) {
            picking = .deck(deck)
        } onTempoKey: { track in
            tempoKey = TempoKeyRequest(track: track, deck: deck)
        }
    }

    // MARK: Chrome

    private func topBar(_ state: MacDJPerformState, tv: PhoneDecksTV?, includesStrip: Bool) -> some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                if showsClose { closeButton }
                if includesStrip {
                    PhoneDecksStrip(state: state, model: model) { picking = .next }
                } else {
                    Spacer(minLength: 0)
                }
                if let tv { tvButton(tv) }
                if horizontalSizeClass == .regular, verticalSizeClass == .regular {
                    libraryButton
                }
                moreMenu(tv: tv)
            }
        }
        .tint(.white)
    }

    private func portraitHeader(tv: PhoneDecksTV?) -> some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                if showsClose { closeButton }
                Spacer(minLength: 0)
                if let tv { tvButton(tv) }
                moreMenu(tv: tv)
            }
            .overlay {
                Text("Decks")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                    .allowsHitTesting(false)
            }
        }
        .tint(.white)
    }

    private var closeButton: some View {
        Button {
            close()
        } label: {
            Image(systemName: "xmark")
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel("Close Decks")
    }

    private func tvButton(_ tv: PhoneDecksTV) -> some View {
        Button {
            place = .tv
        } label: {
            Label(tv.name, systemImage: "appletv.fill")
                .labelStyle(CompactLabelStyle())
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .frame(height: 44)
                .fixedSize()
        }
        .buttonStyle(.glass)
        .accessibilityLabel("Mix on \(tv.name)")
    }

    private var libraryButton: some View {
        Button {
            withAnimation(.snappy) { showsLibrary.toggle() }
        } label: {
            Image(systemName: "music.note.list")
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(showsLibrary ? "Hide Library" : "Show Library")
    }

    private func moreMenu(tv: PhoneDecksTV?) -> some View {
        Menu {
            Section {
                Button("Load Deck A\u{2026}", systemImage: "a.square") { picking = .deck(.a) }
                Button("Load Deck B\u{2026}", systemImage: "b.square") { picking = .deck(.b) }
                Button("Mix In Next\u{2026}", systemImage: "text.line.first.and.arrowtriangle.forward") { picking = .next }
            }
            Section {
                if let session = model.savableSet {
                    if MixHistoryStore.shared.isSaved(session: session) {
                        Button("Set Saved to Mixes", systemImage: "checkmark") {}
                            .disabled(true)
                    } else {
                        Button("Save This Set", systemImage: "square.and.arrow.down.on.square") { save(session) }
                    }
                }
                Button("Play On\u{2026}", systemImage: "airplay.audio") { showingPlayOn = true }
                if let tv {
                    Button("Mix on \(tv.name)", systemImage: "appletv") { place = .tv }
                }
            }
            Section {
                Button("Decks View\u{2026}", systemImage: "slider.horizontal.3") { showingView = true }
                if UIDevice.current.userInterfaceIdiom == .pad {
                    Button("Controllers\u{2026}", systemImage: SidebarSymbol.hardware) { showingControllers = true }
                }
                if DecksOrientationLock.isAvailable {
                    Toggle("Lock to Landscape", systemImage: "lock.rotation", isOn: $locksLandscape)
                }
            }
            Button("Close Decks", systemImage: "xmark") { close() }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel("More")
    }

    @ViewBuilder
    private var noticeView: some View {
        if let notice {
            Label(notice, systemImage: "checkmark.circle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .glassEffect(.regular, in: Capsule())
                .padding(.top, 56)
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    // MARK: Actions

    private func reference(for target: PhoneDeckPickTarget) -> PhoneDeckReference {
        switch target {
        case .deck(let deck): return model.reference(for: deck)
        case .next: return model.nextReference
        }
    }

    private func pick(_ track: Track, _ target: PhoneDeckPickTarget) {
        switch target {
        case .deck(let deck):
            model.load(track, onto: deck)
        case .next:
            model.chooseNext(track) { coordinator.playNext($0) }
            show("Mixing in \(track.title) next")
        }
    }

    private func save(_ session: MixHistorySession) {
        MixHistoryStore.shared.save(session: session)
        DeckHaptics.success()
        show("Saved to Mixes")
    }

    private func show(_ text: String) {
        withAnimation(.snappy) { notice = text }
        UIAccessibility.post(notification: .announcement, argument: text)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard notice == text else { return }
            withAnimation(.snappy) { notice = nil }
        }
    }

    private func refreshAnalysis() {
        for deck in MixEngine.Deck.allCases { model.refreshAnalysis(deck) }
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    #if DEBUG
    private func applyFixtureOrientation() {
        guard ProcessInfo.processInfo.environment["SOUNDING_TV_DJ_ORIENTATION"] == "landscape",
              let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { _ in }
    }
    #endif
}

// MARK: - Waveform touch

struct PhoneDecksWaveformTouch: View {
    let model: PhoneDecksModel

    @State private var deck: MixEngine.Deck?
    @State private var lastX: CGFloat = 0
    @State private var isHorizontal: Bool?
    @State private var pinchStart: Double?

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .contentShape(Rectangle())
                .simultaneousGesture(drag(in: proxy.size))
                .simultaneousGesture(pinch)
        }
        .accessibilityHidden(true)
    }

    private func drag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { gesture in
                if isHorizontal == nil {
                    isHorizontal = abs(gesture.translation.width) >= abs(gesture.translation.height)
                }
                guard isHorizontal == true, pinchStart == nil else { return }
                if deck == nil {
                    let touched: MixEngine.Deck = gesture.startLocation.y < size.height / 2 ? .a : .b
                    deck = touched
                    lastX = 0
                    model.beginTouch(touched)
                }
                let dx = gesture.translation.width - lastX
                lastX = gesture.translation.width
                if let deck { model.drag(deck, by: dx, laneWidth: size.width - 64) }
            }
            .onEnded { _ in
                if let deck { model.endTouch(deck) }
                deck = nil
                lastX = 0
                isHorizontal = nil
            }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchStart == nil { pinchStart = model.zoomBars }
                model.setZoom(from: pinchStart ?? 16, magnification: value.magnification)
            }
            .onEnded { _ in pinchStart = nil }
    }
}

// MARK: - Strip

struct PhoneDecksStrip: View {
    let state: MacDJPerformState
    @ObservedObject var model: PhoneDecksModel
    var onChooseNext: () -> Void = {}

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let owned = state.owned.first
        HStack(spacing: 10) {
            if let owned {
                yours(owned)
            } else if state.isAutoMixDriving {
                autoMix
            } else {
                off
            }
        }
        .font(.footnote)
        .foregroundStyle(.white)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(minHeight: 44)
        .modifier(StripGlass(isYours: owned != nil, reduceTransparency: reduceTransparency))
        .animation(.easeInOut(duration: 0.2), value: owned?.id)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Auto Mix")
    }

    // MARK: States

    @ViewBuilder
    private func yours(_ owned: MacDJOwnership) -> some View {
        Image(systemName: "hand.raised").foregroundStyle(MacDJPalette.yours).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 1) {
            Text(state.owned.count == 1 ? owned.title : "\(state.owned.count) controls are yours")
                .fontWeight(.semibold)
                .foregroundStyle(MacDJPalette.yours)
            Text(state.owned.count == 1 ? owned.valueText : "Auto Mix waits for you")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color(red: 1, green: 0.93, blue: 0.59).opacity(0.9))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .layoutPriority(1)
        Spacer(minLength: 4)
        ViewThatFits(in: .horizontal) {
            Button("Take Over All") { model.takeOverAll() }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .fixedSize()
            Color.clear.frame(width: 0, height: 0)
        }
        Button {
            state.owned.count == 1 ? model.handBack(owned.control) : model.handBackAll()
        } label: {
            Label("Hand Back", systemImage: "arrow.uturn.backward")
                .labelStyle(CompactLabelStyle())
                .fontWeight(.semibold)
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .background(Capsule().fill(MacDJPalette.yours))
                .foregroundStyle(.black)
                .fixedSize()
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Auto Mix takes it back on the next beat")
    }

    @ViewBuilder
    private var autoMix: some View {
        Image(systemName: "sparkle").foregroundStyle(MacDJPalette.auto).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 1) {
            Text(state.panel?.headline ?? "Auto Mix")
                .fontWeight(.semibold)
            if let detail {
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(contrast.djInk(0.72))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .layoutPriority(1)
        if let mix = state.mix, mix.countdown == nil {
            ViewThatFits(in: .horizontal) {
                dots(mix)
                Color.clear.frame(width: 0, height: 0)
            }
        }
        Spacer(minLength: 4)
        if model.canMixNow {
            Button("Mix Now") { model.mixNow() }
                .buttonStyle(.plain)
                .fontWeight(.semibold)
                .foregroundStyle(MacDJPalette.auto)
                .frame(minHeight: 44)
                .fixedSize()
        }
        autoMixMenu
    }

    @ViewBuilder
    private var off: some View {
        Image(systemName: "sparkle").foregroundStyle(contrast.djInk(0.5)).accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 1) {
            Text("Auto Mix is off").foregroundStyle(contrast.djInk(0.8))
            Text("You have both decks")
                .font(.caption)
                .foregroundStyle(contrast.djInk(0.55))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        Spacer(minLength: 4)
        Button("Turn On") { model.setAutoMix(true) }
            .buttonStyle(.plain)
            .fontWeight(.semibold)
            .frame(minHeight: 44)
            .fixedSize()
            .accessibilityLabel("Turn On Auto Mix")
    }

    private var detail: String? {
        guard let mix = state.mix else { return nil }
        if let countdown = mix.countdown {
            return [state.panel?.subline, countdown].compactMap { $0 }.joined(separator: " \u{00B7} ")
        }
        let bar = "Bar \(max(1, Int(mix.nowBar))) of \(Int(mix.totalBars))"
        return [mix.currentStep?.label, bar].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    private func dots(_ mix: MacDJMixState) -> some View {
        HStack(spacing: 4) {
            ForEach(mix.steps) { step in
                let mode = mix.mode(of: step)
                Capsule()
                    .fill(mode == .next ? .white.opacity(0.2) : MacDJPalette.auto)
                    .frame(width: mode == .now ? 14 : 6, height: 6)
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }

    private var autoMixMenu: some View {
        Menu {
            Toggle("Auto Mix", isOn: Binding(get: { state.isAutoMixDriving }, set: { model.setAutoMix($0) }))
            Section {
                if model.canMixNow {
                    Button("Mix Now", systemImage: "arrow.triangle.merge") { model.mixNow() }
                }
                if model.canExtend {
                    Button("Extend 8 Bars", systemImage: "arrow.right.to.line") { model.extend() }
                }
                Button("Mix In Next\u{2026}", systemImage: "text.line.first.and.arrowtriangle.forward", action: onChooseNext)
                Button("Skip Next Track", systemImage: "forward") { model.skip() }
            }
            Button("Take Over All", systemImage: "hand.raised") { model.takeOverAll() }
        } label: {
            Image(systemName: "chevron.down.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .font(.title3)
                .frame(width: 44, height: 44)
        }
        .tint(.white)
        .accessibilityLabel("Auto Mix Options")
    }

    private struct StripGlass: ViewModifier {
        let isYours: Bool
        let reduceTransparency: Bool

        func body(content: Content) -> some View {
            if reduceTransparency {
                content
                    .background(Capsule().fill(isYours ? Color(red: 0.24, green: 0.21, blue: 0.03) : Color(white: 0.16)))
                    .overlay(Capsule().strokeBorder(isYours ? MacDJPalette.yours.opacity(0.8) : .white.opacity(0.4), lineWidth: 1))
            } else {
                content
                    .glassEffect(isYours ? .regular.tint(MacDJPalette.yours.opacity(0.22)) : .regular, in: Capsule())
                    .overlay {
                        if isYours { Capsule().strokeBorder(MacDJPalette.yours.opacity(0.6), lineWidth: 1) }
                    }
            }
        }
    }
}

// MARK: - Decks View

struct PhoneDecksViewSettings: View {
    @ObservedObject var model: PhoneDecksModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(DecksOrientationLock.storageKey, store: .sounding) private var locksLandscape = false
    @AppStorage("decks.showsLibrary", store: .sounding) private var showsLibrary = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Zoom", selection: $model.zoomBars) {
                        ForEach(PhoneDecksModel.zoomSteps, id: \.self) { bars in
                            Text("\(Int(bars)) bars").tag(bars)
                        }
                    }
                    if DecksOrientationLock.isAvailable {
                        Toggle("Lock to Landscape", isOn: $locksLandscape)
                    } else {
                        Toggle("Show Library", isOn: $showsLibrary)
                    }
                } header: {
                    Text("Waveform")
                } footer: {
                    Text("Drag a waveform to nudge a playing deck or scrub a paused one. Pinch to zoom.")
                }
                Section {
                    Picker("EQ Band", selection: $model.eqBand) {
                        Text("High").tag(MixControl.Kind.high)
                        Text("Mid").tag(MixControl.Kind.mid)
                        Text("Low").tag(MixControl.Kind.low)
                    }
                } header: {
                    Text("Mixer")
                } footer: {
                    Text("Double-tap a knob to reset it. Touch and hold for fine control. In landscape on iPhone the mixer shows one EQ band.")
                }
                Section {
                    LabeledContent("Headphone Cue", value: "Not on \(DeviceClass.current.displayName)")
                } footer: {
                    Text("\(DeviceClass.current.displayName) has one audio output, so cueing a deck in headphones needs a Mac.")
                }
            }
            .navigationTitle("Decks View")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
