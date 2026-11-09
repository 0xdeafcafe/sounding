import SwiftUI

struct PhoneDecksTV: Equatable {
    let name: String
    let isReachable: Bool
    let canMix: Bool
    let isInDecks: Bool
}

struct PhoneDecksPlaceReader<Content: View>: View {
    @ObservedObject private var router: OutputRouter
    @ObservedObject private var client: CompanionClient
    @State private var decksOpen: Bool?
    private let feed: CompanionDecksFeed
    private let content: (PhoneDecksTV?) -> Content

    init(_ router: OutputRouter, @ViewBuilder content: @escaping (PhoneDecksTV?) -> Content) {
        _router = ObservedObject(wrappedValue: router)
        _client = ObservedObject(wrappedValue: router.client)
        _decksOpen = State(initialValue: router.client.decks.decksOpen)
        feed = router.client.decks
        self.content = content
    }

    var body: some View {
        content(tv)
            .onReceive(feed.$decksOpen.removeDuplicates()) { decksOpen = $0 }
    }

    private var tv: PhoneDecksTV? {
        let output = router.current
        guard !output.isLocal, output.deviceClass == .tv else { return nil }
        return PhoneDecksTV(
            name: output.name,
            isReachable: client.isReachable,
            canMix: decksOpen != nil,
            isInDecks: decksOpen == true
        )
    }
}

struct PhoneRemoteDecksView: View {
    let tvName: String
    let showsClose: Bool
    let onUsePhone: () -> Void
    let onClose: () -> Void

    @StateObject private var model: PhoneRemoteDecksModel
    @ObservedObject private var client: CompanionClient
    @ObservedObject private var feed: CompanionDecksFeed
    @EnvironmentObject private var coordinator: PhonePlaybackCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var showingPicker = false

    init(client: CompanionClient, tvName: String, showsClose: Bool = false, onUsePhone: @escaping () -> Void, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: PhoneRemoteDecksModel(client: client))
        _client = ObservedObject(wrappedValue: client)
        _feed = ObservedObject(wrappedValue: client.decks)
        self.tvName = tvName
        self.showsClose = showsClose
        self.onUsePhone = onUsePhone
        self.onClose = onClose
    }

    private var isPad: Bool { horizontalSizeClass == .regular && verticalSizeClass == .regular }

    var body: some View {
        TimelineView(.periodic(from: .now, by: reduceMotion ? 1 : 0.25)) { context in
            let _ = model.revision
            let state = model.state(at: context.date)
            GeometryReader { proxy in
                if isPad || proxy.size.width > proxy.size.height {
                    landscape(state, size: proxy.size)
                        .dynamicTypeSize(...(isPad ? DynamicTypeSize.xxLarge : DynamicTypeSize.xLarge))
                } else {
                    portrait(state)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                }
            }
            .background { PhoneDecksBackdrop(url: state.deck(.a).artworkURL ?? state.deck(.b).artworkURL) }
        }
        .onAppear { model.attach() }
        .onDisappear { model.detach() }
        .sheet(isPresented: $showingPicker) {
            PhoneRemoteDeckPicker(tvName: tvName, client: client) { index in
                model.loadNext(queueIndex: index)
            } onTrack: { track in
                coordinator.output.playNext(track)
            }
        }
    }

    // MARK: Layouts

    private func landscape(_ state: PhoneRemoteDecksState, size: CGSize) -> some View {
        let mixerWidth: CGFloat = isPad ? 280 : 200
        let inner = size.width - (isPad ? 40 : 16)
        let deckWidth = max(180, floor((inner - mixerWidth - 24) / 2))
        return VStack(spacing: 10) {
            header(state)
            if isUnavailable(state) {
                unavailable.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    deck(.a, state: state).frame(width: deckWidth)
                    PhoneRemoteMixer(state: state, model: model, knobSize: isPad ? 50 : 40, rowSpacing: isPad ? 10 : 2)
                        .frame(maxWidth: .infinity)
                    deck(.b, state: state).frame(width: deckWidth)
                }
                .frame(maxHeight: isPad ? 420 : .infinity, alignment: .top)
                actions(state)
                if isPad { Spacer(minLength: 0) }
            }
        }
        .padding(.horizontal, isPad ? 20 : 8)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    private func portrait(_ state: PhoneRemoteDecksState) -> some View {
        VStack(spacing: 14) {
            header(state).padding(.horizontal, 14)
            if isUnavailable(state) {
                unavailable.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 18) {
                        deck(.a, state: state).frame(minHeight: 150)
                        PhoneRemoteMixer(state: state, model: model, knobSize: 44)
                            .padding(.horizontal, 12)
                        deck(.b, state: state).frame(minHeight: 150)
                        actions(state)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 20)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    private func deck(_ slot: MixEngine.Deck, state: PhoneRemoteDecksState) -> some View {
        PhoneRemoteDeckPanel(deck: state.deck(slot), state: state, model: model) { showingPicker = true }
    }

    private func isUnavailable(_ state: PhoneRemoteDecksState) -> Bool {
        !client.isReachable || !state.hasState
    }

    @ViewBuilder
    private var unavailable: some View {
        if !client.isReachable {
            ContentUnavailableView {
                Label("\(tvName) Isn\u{2019}t Reachable", systemImage: "appletv")
            } description: {
                Text("Decks come back when it\u{2019}s on the same network.")
            } actions: {
                Button("Try Again") { client.retry() }.buttonStyle(.bordered)
                Button("Use \(DeviceClass.current.displayName) Decks", action: onUsePhone)
            }
        } else {
            ProgressView()
        }
    }

    // MARK: Header

    private func header(_ state: PhoneRemoteDecksState) -> some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                if showsClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Close Decks")
                }
                PhoneRemoteDecksStrip(tvName: tvName, state: state, model: model)
                Button(action: onUsePhone) {
                    Label(DeviceClass.current.displayName, systemImage: DeviceClass.current.symbolName)
                        .labelStyle(CompactLabelStyle())
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 4)
                        .frame(height: 44)
                        .fixedSize()
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Use \(DeviceClass.current.displayName) Decks")
                Menu {
                    Toggle("Auto Mix", isOn: Binding(get: { state.isAutoMixOn }, set: { model.setAutoMix($0) }))
                    if state.canExtend {
                        Button("Extend 8 Bars", systemImage: "plus") { model.extend() }
                    }
                    if !state.yours.isEmpty {
                        Button("Hand Back", systemImage: "arrow.uturn.backward") { model.handBack() }
                    }
                    Button("Load Next\u{2026}", systemImage: "text.line.first.and.arrowtriangle.forward") { showingPicker = true }
                    Divider()
                    Button("Use \(DeviceClass.current.displayName) Decks", systemImage: DeviceClass.current.symbolName, action: onUsePhone)
                    Button("Close Decks", systemImage: "xmark", action: onClose)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("More")
            }
        }
        .tint(.white)
    }

    // MARK: Actions

    private func actions(_ state: PhoneRemoteDecksState) -> some View {
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button { model.mixNow() } label: {
                    Label("Mix Now", systemImage: "arrow.triangle.merge")
                        .fontWeight(.semibold)
                        .frame(minHeight: 36)
                }
                .disabled(!state.canMixNow)
                Button { showingPicker = true } label: {
                    Label("Load Next\u{2026}", systemImage: "text.line.first.and.arrowtriangle.forward")
                        .frame(minHeight: 36)
                }
                if state.canExtend {
                    Button { model.extend() } label: {
                        Label("Extend", systemImage: "arrow.right.to.line")
                            .frame(minHeight: 36)
                    }
                }
            }
            .buttonStyle(.glass)
            .labelStyle(CompactLabelStyle())
            .font(.subheadline)
            .lineLimit(1)
        }
        .tint(.white)
    }
}

// MARK: - Strip

struct PhoneRemoteDecksStrip: View {
    let tvName: String
    let state: PhoneRemoteDecksState
    @ObservedObject var model: PhoneRemoteDecksModel

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var isYours: Bool { !state.yours.isEmpty }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "appletv.fill")
                .foregroundStyle(isYours ? MacDJPalette.yours : .white)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text("Mixing on \(tvName)")
                    .fontWeight(.semibold)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(isYours ? Color(red: 1, green: 0.93, blue: 0.59).opacity(0.9) : contrast.djInk(0.66))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .layoutPriority(1)
            Spacer(minLength: 4)
            trailing
        }
        .font(.footnote)
        .foregroundStyle(.white)
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .frame(minHeight: 36)
        .modifier(Glass(isYours: isYours, reduceTransparency: reduceTransparency))
        .animation(.easeInOut(duration: 0.2), value: isYours)
        .accessibilityElement(children: .contain)
    }

    private var status: String {
        if !state.isDecksOpen { return "Decks aren\u{2019}t open on \(tvName)" }
        if isYours { return state.yours.count == 1 ? "\(state.yours.first?.name ?? "Control") is yours" : "\(state.yours.count) controls are yours" }
        if state.isAutoMixOn { return state.headline ?? "Auto Mix" }
        return "Auto Mix is off"
    }

    @ViewBuilder
    private var trailing: some View {
        if isYours {
            Button { model.handBack() } label: {
                Label("Hand Back", systemImage: "arrow.uturn.backward")
                    .labelStyle(CompactLabelStyle())
                    .fontWeight(.semibold)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 28)
                    .background(Capsule().fill(MacDJPalette.yours))
                    .foregroundStyle(.black)
                    .fixedSize()
            }
            .buttonStyle(.plain)
        } else if state.hasState, !state.isAutoMixOn {
            Button("Turn On") { model.setAutoMix(true) }
                .buttonStyle(.plain)
                .fontWeight(.semibold)
                .fixedSize()
                .accessibilityLabel("Turn On Auto Mix")
        }
    }

    private struct Glass: ViewModifier {
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

// MARK: - Deck

struct PhoneRemoteDeckPanel: View {
    let deck: PhoneRemoteDeck
    let state: PhoneRemoteDecksState
    @ObservedObject var model: PhoneRemoteDecksModel
    let onLoadNext: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    private var canTransport: Bool { deck.isLive || (state.isEngineLive && deck.isLoaded) }
    private var tempoControl: MixControl { MixControl(.tempo, deck: deck.slot) }

    var body: some View {
        Group {
            if deck.isEmpty {
                ContentUnavailableView {
                    Label(deck.slot == .a ? "Nothing Playing" : "Nothing Up Next", systemImage: "opticaldisc")
                } actions: {
                    if deck.slot == .b {
                        Button("Load Next\u{2026}", action: onLoadNext).buttonStyle(.bordered)
                    }
                }
                .controlSize(.small)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    header
                    progress
                    transport
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Deck \(deck.slot.label)")
    }

    private var header: some View {
        HStack(spacing: 10) {
            ArtworkImage(url: deck.artworkURL, variant: .thumbnail) {
                LinearGradient(colors: [MacDJPalette.deck(deck.slot).opacity(0.5), MacDJPalette.panel], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    MacDJDeckBadge(deck: deck.slot, size: 16)
                    Text(deck.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                Text(deck.artist)
                    .font(.caption)
                    .foregroundStyle(contrast.djInk(0.6))
                    .lineLimit(1)
            }
            .layoutPriority(-1)
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\u{2212}\(MacDJPadTime.text(deck.remaining))")
                    .font(.title3.weight(.semibold).monospacedDigit())
                if let bpm = deck.bpm {
                    Text(String(format: "%.1f BPM", bpm))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(contrast.djInk(0.55))
                }
            }
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var progress: some View {
        VStack(spacing: 4) {
            ProgressView(value: min(deck.position, max(deck.duration, 0.01)), total: max(deck.duration, 0.01))
                .tint(MacDJPalette.deck(deck.slot))
                .accessibilityLabel("Position")
                .accessibilityValue("\(MacDJPadTime.text(deck.position)) of \(MacDJPadTime.text(deck.duration))")
            HStack(spacing: 8) {
                Text(MacDJPadTime.text(deck.position))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(contrast.djInk(0.55))
                if let cue = deck.cuePoint {
                    Text("Cue \(MacDJPadTime.text(cue))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(contrast.djInk(0.55))
                }
                Spacer(minLength: 0)
                chip
            }
        }
    }

    @ViewBuilder
    private var chip: some View {
        if deck.isLive, deck.isPlaying {
            MacDJChip(kind: .onAir)
        } else if !deck.isLive, deck.isPlaying {
            MacDJChip(kind: .mixingIn)
        } else if !deck.isLoaded, deck.slot == .b {
            MacDJChip(kind: .custom("Up Next", contrast.djInk(0.75), .white.opacity(0.1)))
        }
    }

    private var transport: some View {
        HStack(spacing: 6) {
            Button { DeckHaptics.press(); model.cue(deck.slot) } label: {
                Text("CUE").font(.caption.weight(.bold))
            }
            .buttonStyle(MacDJControlButtonStyle(height: 44, shape: .circle))
            .accessibilityLabel("Cue")
            .accessibilityHint(deck.isPlaying ? "Returns to the cue point" : "Sets the cue point here")
            Button { DeckHaptics.press(); model.togglePlay(deck.slot) } label: {
                Image(systemName: deck.isPlaying ? "pause.fill" : "play.fill").font(.body)
            }
            .buttonStyle(MacDJControlButtonStyle(tint: MacDJPalette.play, height: 44, shape: .circle))
            .accessibilityLabel(deck.isPlaying ? "Pause" : "Play")
            Button { DeckHaptics.press(); model.sync(deck.slot) } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(MacDJControlButtonStyle(height: 44, shape: .circle))
            .disabled(!deck.isLoaded || deck.bpm == nil)
            .accessibilityLabel("Sync")
            Spacer(minLength: 4)
            tempo
        }
        .disabled(!canTransport)
        .opacity(canTransport ? 1 : 0.4)
    }

    private var tempo: some View {
        let value = state.value(tempoControl)
        let text = PhoneDecksModel.valueText(.tempo, value: value)
        return HStack(spacing: 6) {
            Text(text)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(contrast.djInk(0.6))
                .fixedSize()
                .accessibilityHidden(true)
            PhoneDeckKnob(
                value: value,
                isYours: state.yours.contains(tempoControl),
                isDisabled: !deck.isLoaded,
                size: 40,
                valueText: text,
                onGrab: { model.grab(tempoControl) },
                onChange: { model.set(tempoControl, to: $0) }
            )
            .accessibilityLabel("Tempo")
        }
    }
}

// MARK: - Mixer

struct PhoneRemoteMixer: View {
    let state: PhoneRemoteDecksState
    @ObservedObject var model: PhoneRemoteDecksModel
    var knobSize: CGFloat = 44
    var rowSpacing: CGFloat = 8

    @Environment(\.colorSchemeContrast) private var contrast

    private var rowHeight: CGFloat { max(44, knobSize) }

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                knobs(.a)
                VStack(spacing: rowSpacing) {
                    ForEach(PhoneRemoteDecksModel.bands, id: \.self) { kind in
                        Text(MixControl(kind, deck: nil).name)
                            .font(.caption)
                            .foregroundStyle(contrast.djInk(0.6))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(height: rowHeight)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity)
                knobs(.b)
            }
            PhoneDeckCrossfader(
                value: state.value(.crossfader),
                isYours: state.yours.contains(.crossfader),
                isDisabled: !state.isEngineLive,
                onGrab: { model.grab(.crossfader) },
                onChange: { model.set(.crossfader, to: $0) }
            )
            caption
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mixer")
    }

    private func knobs(_ slot: MixEngine.Deck) -> some View {
        VStack(spacing: rowSpacing) {
            ForEach(PhoneRemoteDecksModel.bands, id: \.self) { kind in
                let control = MixControl(kind, deck: slot)
                PhoneDeckKnob(
                    value: state.value(control),
                    isYours: state.yours.contains(control),
                    isDisabled: !state.deck(slot).isLoaded,
                    size: knobSize,
                    valueText: PhoneDecksModel.valueText(kind, value: state.value(control)),
                    onGrab: { model.grab(control) },
                    onChange: { model.set(control, to: $0) }
                )
                .frame(height: rowHeight)
                .accessibilityLabel(control.name)
            }
        }
    }

    @ViewBuilder
    private var caption: some View {
        if state.isAutoMixOn, state.yours.isEmpty {
            Label("Touch any control to take over", systemImage: "sparkle")
                .labelStyle(CompactLabelStyle())
                .font(.caption2)
                .foregroundStyle(MacDJPalette.auto)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

// MARK: - Load Next

struct PhoneRemoteDeckPicker: View {
    let tvName: String
    @ObservedObject var client: CompanionClient
    let onQueued: (Int) -> Void
    let onTrack: (Track) -> Void

    @StateObject private var library = PhoneDeckLibrary(sources: [SoundCloudLikesDeckSource()])
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hasLoaded = false

    private struct Queued: Identifiable {
        let index: Int
        let track: QueueTrack
        var id: Int { index }
    }

    private var queued: [Queued] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return client.upNext
            .map { Queued(index: $0.index, track: $0.track) }
            .filter {
                needle.isEmpty
                    || $0.track.title.localizedCaseInsensitiveContains(needle)
                    || $0.track.artist.localizedCaseInsensitiveContains(needle)
            }
    }

    var body: some View {
        NavigationStack {
            List {
                let queued = queued
                if !queued.isEmpty {
                    Section("Up Next on \(tvName)") {
                        ForEach(queued) { item in
                            row(title: item.track.title, artist: item.track.artist, artworkURL: item.track.artworkURL) {
                                onQueued(item.index)
                            }
                        }
                    }
                }
                ForEach(library.filtered(query)) { section in
                    Section(section.title) {
                        ForEach(section.tracks) { track in
                            row(title: track.title, artist: track.user.displayName, artworkURL: track.artworkURL) {
                                onTrack(track)
                            }
                        }
                    }
                }
            }
            .overlay { overlay }
            .searchable(text: $query, prompt: "Title or artist")
            .navigationTitle("Load Next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                await library.reload()
                hasLoaded = true
            }
        }
    }

    @ViewBuilder
    private var overlay: some View {
        let isEmpty = queued.isEmpty && library.filtered(query).isEmpty
        if isEmpty {
            if !hasLoaded || library.isLoading {
                ProgressView()
            } else if !query.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ContentUnavailableView {
                    Label("No Tracks to Load", systemImage: "music.note.list")
                } description: {
                    Text("Queue tracks on \(tvName) or like them on SoundCloud.")
                }
            }
        }
    }

    private func row(title: String, artist: String, artworkURL: URL?, action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack(spacing: 12) {
                ArtworkImage(url: artworkURL, variant: .thumbnail) {
                    Color.secondary.opacity(0.2)
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).lineLimit(1)
                    Text(artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .tint(.primary)
    }
}
