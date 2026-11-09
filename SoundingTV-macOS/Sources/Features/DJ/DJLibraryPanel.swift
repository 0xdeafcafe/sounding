import SwiftUI

struct DJLibraryPanel: View {
    @StateObject private var model: MacPrepModel
    private let context: DJDeckContext
    @State private var fitMode: FitMode = .sorted
    @State private var selection: String?
    @State private var refusal: String?
    @FocusState private var searchFocused: Bool

    enum FitMode: Hashable {
        case sorted
        case only
        case off
    }

    init(model: @autoclosure @escaping () -> MacPrepModel = MacPrepModel(), context: DJDeckContext) {
        _model = StateObject(wrappedValue: model())
        self.context = context
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchField
            filters
            content
            footer
        }
        .overlay(alignment: .bottom) {
            if let refusal {
                DJRefusalBanner(message: refusal)
                    .padding(.bottom, 44)
                    .transition(.opacity)
                    .task(id: refusal) {
                        try? await Task.sleep(for: .seconds(2.5))
                        withAnimation { self.refusal = nil }
                    }
            }
        }
        .background {
            Group {
                Button("Load on Deck A") { loadSelection(.a) }
                    .keyboardShortcut("1", modifiers: .shift)
                Button("Load on Deck B") { loadSelection(.b) }
                    .keyboardShortcut("2", modifiers: .shift)
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
        .task {
            await model.reload()
            searchFocused = true
        }
    }

    // MARK: Header

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Title, artist, key, BPM", text: $model.searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { if let first = results.first { selection = first.row.id } }
            if model.searchText.isEmpty {
                Text("⌘F").font(.callout).foregroundStyle(.secondary)
            } else {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Clear Search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(searchFocused ? Color.scAccent : Color.secondary.opacity(0.3), lineWidth: searchFocused ? 2 : 1))
    }

    private var filters: some View {
        HStack(spacing: 6) {
            Picker("Crate", selection: Binding(get: { model.source }, set: { model.source = $0 })) {
                Text("All Tracks").tag(MacPrepModel.Source.all)
                Text("Likes").tag(MacPrepModel.Source.likes)
                if !model.playlists.isEmpty {
                    Divider()
                    ForEach(model.playlists) { crate in
                        Text(crate.name).tag(MacPrepModel.Source.playlist(crate.id))
                    }
                }
                Divider()
                ForEach(MacPrepModel.SmartCrate.allCases, id: \.self) { crate in
                    Text(crate.title).tag(MacPrepModel.Source.smart(crate))
                }
            }
            .labelsHidden()
            .layoutPriority(1)
            Picker("Fits", selection: $fitMode) {
                Text(reference.map { "Fits \($0.title)" } ?? "Fits Nothing Yet").tag(FitMode.sorted)
                Text("Only Tracks That Fit").tag(FitMode.only)
                Text("Any Key or Tempo").tag(FitMode.off)
            }
            .labelsHidden()
            .layoutPriority(1)
            .disabled(reference == nil)
            Spacer(minLength: 4)
            Text("\(results.count) of \(model.rows.count)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
        }
    }

    // MARK: Results

    private struct Result: Identifiable {
        let row: MacPrepModel.Row
        let fit: DJFit
        var id: String { row.id }
    }

    private var reference: (title: String, bpm: Double?, key: String?)? {
        guard let slot = context.incomingOrCurrent, let id = slot.trackId else { return nil }
        let row = model.row(id)
        return (slot.title.isEmpty ? row?.title ?? "" : slot.title, slot.bpm ?? row?.bpm, slot.key ?? row?.key)
    }

    private var results: [Result] {
        let rows = model.visibleRows
        guard fitMode != .off, let reference else { return rows.map { Result(row: $0, fit: .unknown) } }
        let scored = rows.map { Result(row: $0, fit: DJFit.evaluate(bpm: $0.bpm, key: $0.key, against: (reference.bpm, reference.key))) }
        if fitMode == .only { return scored.filter { $0.fit == .fits } }
        return scored.enumerated().sorted { lhs, rhs in
            let l = lhs.element.fit == .fits ? 0 : 1
            let r = rhs.element.fit == .fits ? 0 : 1
            return l == r ? lhs.offset < rhs.offset : l < r
        }.map(\.element)
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if results.isEmpty {
                    Group {
                        if model.searchText.isEmpty {
                            ContentUnavailableView("No Tracks", systemImage: "music.note.list", description: Text(fitMode == .only ? "Nothing here fits what’s playing." : "Add tracks in Prep."))
                        } else {
                            ContentUnavailableView.search(text: model.searchText)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                ForEach(results) { result in
                    DJLibraryRow(row: result.row, fit: result.fit, deck: context.deck(holding: result.row.id))
                        .macSelectableRow(result.row.id, selection: $selection)
                        .simultaneousGesture(TapGesture(count: 2).onEnded { context.playNext(result.row.id) })
                        .draggable(result.row.id) {
                            DJLibraryGhost(row: result.row)
                        }
                        .contextMenu {
                            DJTrackMenu(row: result.row, model: model, context: context, refusal: $refusal)
                        }
                }
                if !context.playedTonight.isEmpty {
                    Section("Played Tonight") {
                        ForEach(context.playedTonight) { played in
                            HStack(spacing: 10) {
                                ArtworkThumbnail(url: played.artworkURL, identity: played.id, size: 28, cornerRadius: 4)
                                Text(played.title).lineLimit(1)
                                Spacer()
                                Text(played.detail)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .macListKeyboardSelection(ids: results.map(\.row.id), selection: $selection) { id in
                context.playNext(id)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            hint("↩", "Play Next")
            hint("⇧1  ⇧2", "Load")
            Text("Drag to a deck")
            Spacer(minLength: 0)
        }
        .font(.callout)
        .foregroundStyle(MacSecondaryStyle())
        .lineLimit(1)
    }

    private func hint(_ keys: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(.callout.monospaced())
                .padding(.horizontal, 4)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.5)))
            Text(label)
        }
        .fixedSize()
    }

    private func loadSelection(_ deck: MixEngine.Deck) {
        guard let id = selection, let row = model.row(id), row.access.canLoad else { return }
        if case .refused(let message) = context.request(id, onto: deck) { refusal = message }
    }
}

extension DJDeckContext {
    var incomingOrCurrent: DJDeckSlot? {
        if let incoming, let slot = slot(incoming), slot.trackId != nil { return slot }
        return current
    }
}

private struct DJLibraryRow: View {
    let row: MacPrepModel.Row
    let fit: DJFit
    let deck: DJDeckSlot?
    @Environment(\.macRowSelectionInk) private var selectionInk

    var body: some View {
        HStack(spacing: 10) {
            ArtworkThumbnail(url: row.artworkURL, identity: row.id, size: 36, cornerRadius: 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if row.access != .local { Image(systemName: "cloud").imageScale(.small) }
                    Text(row.artist).lineLimit(1)
                }
                .foregroundStyle(MacSecondaryStyle())
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 1) {
                HStack(spacing: 6) {
                    if row.analysis == .analysing {
                        DJAnalysingCell()
                    } else if row.bpm == nil, row.key == nil {
                        let message = AnalysisStatusCopy.gate(AnalysisLibraryProgress.shared.currentGate(), device: .current)
                            ?? "Not analysed yet. Choose Analyse Now from the track’s menu."
                        Image(systemName: "clock")
                            .imageScale(.small)
                            .foregroundStyle(.tertiary)
                            .help(message)
                            .accessibilityLabel(message)
                    } else {
                        Text(row.bpm.map { String(Int($0.rounded())) } ?? "–").monospacedDigit()
                        DJKeyBadge(key: row.key)
                    }
                }
                Text(trailingLabel)
                    .font(.caption)
                    .foregroundStyle(fit == .fits && deck == nil ? AnyShapeStyle(selectionInk ?? Color.scAccent) : AnyShapeStyle(MacSecondaryStyle()))
            }
        }
        .opacity(row.access == .autoMixOnly ? 0.6 : 1)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityHint(row.access.canLoad ? "Drag to a deck, or press Shift 1 or Shift 2 to load" : "Auto Mix only. Go+ unlocks decks.")
    }

    private var trailingLabel: String {
        if let deck { return "On \(deck.letter)" }
        switch row.access {
        case .autoMixOnly: return "Auto Mix only"
        case .streams where fit != .fits: return "Streams · Go+"
        default: return fit.label
        }
    }
}

private struct DJLibraryGhost: View {
    let row: MacPrepModel.Row

    var body: some View {
        HStack(spacing: 10) {
            ArtworkThumbnail(url: row.artworkURL, identity: row.id, size: 34, cornerRadius: 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(.headline)
                Text([row.key, row.bpm.map { String(Int($0.rounded())) }].compactMap { $0 }.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
    }
}
