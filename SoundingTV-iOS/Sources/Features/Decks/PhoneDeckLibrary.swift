import SwiftUI

struct DeckTrackSection: Identifiable, Equatable {
    var id: String
    var title: String
    var tracks: [Track]
}

@MainActor
protocol DeckTrackSource {
    var id: String { get }
    var title: String { get }
    var isAvailable: Bool { get }
    func tracks() async -> [Track]
}

@MainActor
struct LocalFilesDeckSource: DeckTrackSource {
    let id = "files"
    let title = "Files"
    var isAvailable: Bool { true }

    func tracks() async -> [Track] { LocalMusicLibrary.shared.allTracks }
}

@MainActor
struct SoundCloudLikesDeckSource: DeckTrackSource {
    let id = "soundcloud"
    let title = "SoundCloud Likes"

    var isAvailable: Bool {
        #if DEBUG
        if VisualFixtures.isEnabled { return false }
        #endif
        return SoundCloudIntentPlaybackSource().isSignedIn
    }

    func tracks() async -> [Track] {
        let total = await LibraryDB.count(.likes)
        if total > 0 {
            return await LibraryDB.tracks(.likes, offset: 0, limit: total).tracks
        }
        return await SoundCloudIntentPlaybackSource().likedTracks(limit: 100)
    }
}

@MainActor
final class PhoneDeckLibrary: ObservableObject {
    @Published private(set) var sections: [DeckTrackSection] = []
    @Published private(set) var isLoading = false

    private let sources: [any DeckTrackSource]

    init(sources: [any DeckTrackSource] = [LocalFilesDeckSource(), SoundCloudLikesDeckSource()]) {
        self.sources = sources
    }

    func reload() async {
        isLoading = true
        var result: [DeckTrackSection] = []
        for source in sources where source.isAvailable {
            let tracks = await source.tracks()
            if !tracks.isEmpty { result.append(DeckTrackSection(id: source.id, title: source.title, tracks: tracks)) }
        }
        sections = result
        isLoading = false
    }

    func filtered(_ query: String) -> [DeckTrackSection] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return sections }
        return sections.compactMap { section in
            let tracks = section.tracks.filter {
                $0.title.localizedCaseInsensitiveContains(needle) || $0.user.displayName.localizedCaseInsensitiveContains(needle)
            }
            return tracks.isEmpty ? nil : DeckTrackSection(id: section.id, title: section.title, tracks: tracks)
        }
    }
}

// MARK: Matching

enum PhoneDeckPickTarget: Hashable, Identifiable {
    case deck(MixEngine.Deck)
    case next

    var id: String {
        switch self {
        case .deck(let deck): return "deck-\(deck.label)"
        case .next: return "next"
        }
    }
}

struct PhoneDeckMatch: Equatable {
    var keyCost: Int?
    var tempoPercent: Double?
    var scale: Double = 1

    var isSuggested: Bool {
        guard keyCost != nil || tempoPercent != nil else { return false }
        if let tempoPercent, abs(tempoPercent) > 6 { return false }
        if let keyCost, keyCost > 1 { return false }
        return true
    }

    var score: Double {
        Double(keyCost ?? 1) * 2 + abs(tempoPercent ?? 4)
    }

    var text: String? {
        var parts: [String] = []
        switch keyCost {
        case 0: parts.append("Same key")
        case 1: parts.append("In key")
        default: break
        }
        if let tempoPercent {
            let tempo = abs(tempoPercent) < 0.5 ? "Same tempo" : String(format: "%+.1f%%", tempoPercent)
            parts.append(scale == 1 ? tempo : "\(tempo) \(scale > 1 ? "\u{00D7}2" : "\u{00BD}")")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    static func compute(_ summary: TrackAnalysisSummary?, against reference: PhoneDeckReference) -> PhoneDeckMatch? {
        guard let summary else { return nil }
        var match = PhoneDeckMatch()
        if let bpm = summary.bpm, bpm > 0, let target = reference.bpm, target > 0 {
            let options: [Double] = [1, 2, 0.5]
            let scale = options.min { abs(bpm * $0 - target) < abs(bpm * $1 - target) } ?? 1
            match.scale = scale
            match.tempoPercent = (bpm * scale - target) / target * 100
        }
        if let key = summary.key, let target = reference.key {
            if key == target {
                match.keyCost = 0
            } else if target.harmonicallyCompatible.contains(key) {
                match.keyCost = 1
            } else {
                match.keyCost = 2 + target.wheelSteps(to: key)
            }
        }
        return match.keyCost == nil && match.tempoPercent == nil ? nil : match
    }
}

// MARK: Browser model

@MainActor
final class PhoneDeckBrowserModel: ObservableObject {
    enum Scope: String, CaseIterable, Identifiable {
        case suggested
        case upNext
        case likes
        case library

        var id: String { rawValue }

        var title: String {
            switch self {
            case .suggested: return "Suggested"
            case .upNext: return "Up Next"
            case .likes: return "Likes"
            case .library: return "Library"
            }
        }
    }

    @Published var query = ""
    @Published private(set) var scope: Scope = .library
    @Published private(set) var upNext: [Track] = []
    @Published private(set) var likes: [Track] = []
    @Published private(set) var library: [Track] = []
    @Published private(set) var suggestions: [Track] = []
    @Published private(set) var summaries: [String: TrackAnalysisSummary] = [:]
    @Published private(set) var reference = PhoneDeckReference(bpm: nil, key: nil, title: nil, excluded: [])
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false

    private var userChoseScope = false

    var scopes: [Scope] {
        var result: [Scope] = []
        if !suggestions.isEmpty { result.append(.suggested) }
        if !upNext.isEmpty { result.append(.upNext) }
        if !likes.isEmpty { result.append(.likes) }
        result.append(.library)
        return result
    }

    func select(_ scope: Scope) {
        userChoseScope = true
        self.scope = scope
    }

    func reload(reference: PhoneDeckReference) async {
        self.reference = reference
        isLoading = true
        let player = PlayerService.shared
        let queued = Array(player.queue.dropFirst(player.currentIndex + 1).prefix(60))
        let files = LocalMusicLibrary.shared.allTracks
        let likesSource = SoundCloudLikesDeckSource()
        let liked = likesSource.isAvailable ? await likesSource.tracks() : []
        upNext = queued.filter { !reference.excluded.contains($0.id) }
        likes = liked
        library = Self.unique(files + liked)
        summaries = await AnalysisLookup.summaries(for: Self.unique(queued + library))
        rank()
        isLoading = false
        hasLoaded = true
        if !userChoseScope || !scopes.contains(scope) { scope = defaultScope }
    }

    func update(reference: PhoneDeckReference) {
        guard reference != self.reference else { return }
        self.reference = reference
        upNext = upNext.filter { !reference.excluded.contains($0.id) }
        rank()
        if !scopes.contains(scope) { scope = defaultScope }
    }

    func match(_ track: Track) -> PhoneDeckMatch? {
        PhoneDeckMatch.compute(summaries[track.id], against: reference)
    }

    func tracks(in scope: Scope) -> [Track] {
        switch scope {
        case .suggested: return filter(suggestions)
        case .upNext: return filter(upNext)
        case .likes: return filter(likes)
        case .library: return filter(library)
        }
    }

    private var defaultScope: Scope {
        if !suggestions.isEmpty { return .suggested }
        if !upNext.isEmpty { return .upNext }
        return .library
    }

    private func rank() {
        guard reference.bpm != nil || reference.key != nil else {
            suggestions = []
            return
        }
        let candidates = Self.unique(upNext + library).filter { !reference.excluded.contains($0.id) }
        let scored: [(track: Track, score: Double)] = candidates.compactMap { track in
            guard let found = match(track), found.isSuggested else { return nil }
            return (track, found.score)
        }
        suggestions = scored
            .sorted { $0.score < $1.score }
            .prefix(50)
            .map { $0.track }
    }

    private func filter(_ tracks: [Track]) -> [Track] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return tracks }
        let tempo = Double(needle)
        return tracks.filter { track in
            if track.title.localizedCaseInsensitiveContains(needle) || track.user.displayName.localizedCaseInsensitiveContains(needle) { return true }
            let summary = summaries[track.id]
            if let tempo, let bpm = summary?.bpm, abs(bpm - tempo) < 1.5 { return true }
            if let key = summary?.key, key.label.caseInsensitiveCompare(needle) == .orderedSame { return true }
            return false
        }
    }

    private static func unique(_ tracks: [Track]) -> [Track] {
        var seen = Set<String>()
        return tracks.filter { seen.insert($0.id).inserted }
    }
}

// MARK: Browser list

struct PhoneDeckBrowserList: View {
    @ObservedObject var model: PhoneDeckBrowserModel
    let target: PhoneDeckPickTarget?
    var onAddFolder: () -> Void
    let onPick: (Track, PhoneDeckPickTarget) -> Void

    var body: some View {
        let tracks = model.tracks(in: model.scope)
        List {
            Section {
                ForEach(tracks) { track in
                    row(track)
                }
            } header: {
                if model.scope == .suggested, let header = suggestionHeader {
                    Text(header)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay { overlay(isEmpty: tracks.isEmpty) }
    }

    private var suggestionHeader: String? {
        let reference = model.reference
        let values = [reference.bpm.map { String(format: "%.1f BPM", $0) }, reference.key?.label].compactMap { $0 }
        guard let title = reference.title else { return nil }
        return (["Matches \(title)"] + values).joined(separator: " \u{00B7} ")
    }

    @ViewBuilder
    private func overlay(isEmpty: Bool) -> some View {
        if isEmpty {
            if !model.hasLoaded || (model.isLoading && model.library.isEmpty) {
                ProgressView()
            } else if !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
                ContentUnavailableView.search(text: model.query)
            } else {
                LocalMusicEmptyState(onAdd: onAddFolder)
            }
        }
    }

    @ViewBuilder
    private func row(_ track: Track) -> some View {
        let content = PhoneDeckBrowserRow(
            track: track,
            summary: model.summaries[track.id],
            match: model.scope == .suggested ? model.match(track) : nil,
            showsDeckButtons: target == nil
        ) { onPick(track, $0) }
        if let target {
            Button {
                onPick(track, target)
            } label: {
                content
            }
            .tint(.primary)
            .trackDragSource(track)
            .swipeActions(edge: .trailing) { swipe(track, target: target) }
            .contextMenu { menu(track) }
        } else {
            content
                .trackDragSource(track)
                .contextMenu { menu(track) }
        }
    }

    @ViewBuilder
    private func swipe(_ track: Track, target: PhoneDeckPickTarget) -> some View {
        switch target {
        case .deck(let deck):
            Button("Load on \(deck.other.label)") { onPick(track, .deck(deck.other)) }
        case .next:
            EmptyView()
        }
    }

    @ViewBuilder
    private func menu(_ track: Track) -> some View {
        Button("Load on Deck A", systemImage: "a.square") { onPick(track, .deck(.a)) }
        Button("Load on Deck B", systemImage: "b.square") { onPick(track, .deck(.b)) }
        Button("Mix In Next", systemImage: "text.line.first.and.arrowtriangle.forward") { onPick(track, .next) }
    }
}

struct PhoneDeckBrowserRow: View {
    let track: Track
    let summary: TrackAnalysisSummary?
    let match: PhoneDeckMatch?
    var showsDeckButtons = false
    var onDeck: (PhoneDeckPickTarget) -> Void = { _ in }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 12) {
            ArtworkImage(url: track.artworkURL, variant: .thumbnail, identity: track.id)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                HStack(spacing: 4) {
                    Image(systemName: track.isLocal ? "folder" : "cloud")
                        .imageScale(.small)
                        .accessibilityLabel(track.isLocal ? "File" : "SoundCloud")
                    Text(detail)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
            }
            Spacer(minLength: 8)
            if !dynamicTypeSize.isAccessibilitySize {
                readout
            }
            if showsDeckButtons {
                deckButton(.a)
                deckButton(.b)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: showsDeckButtons ? .contain : .combine)
    }

    private var detail: String {
        var parts = [track.user.displayName]
        if let match, let text = match.text { parts.append(text) }
        if let note = PhoneDecksModel.deckNote(for: track) { parts.append(note) }
        if dynamicTypeSize.isAccessibilitySize, let readoutText { parts.append(readoutText) }
        return parts.joined(separator: " \u{00B7} ")
    }

    private var readoutText: String? {
        let values = [summary?.bpm.map { "\(Int($0.rounded())) BPM" }, summary?.key?.label].compactMap { $0 }
        return values.isEmpty ? nil : values.joined(separator: " \u{00B7} ")
    }

    private var readout: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(summary?.bpm.map { "\(Int($0.rounded()))" } ?? "\u{2014}")
                .font(.subheadline.monospacedDigit())
            Text(summary?.key?.label ?? " ")
                .font(.caption.monospacedDigit())
                .foregroundStyle(match?.keyCost.map { $0 <= 1 } == true ? Color.green : Color.secondary)
        }
        .frame(minWidth: 36, alignment: .trailing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(readoutText ?? "Not analysed")
    }

    private func deckButton(_ deck: MixEngine.Deck) -> some View {
        Button {
            onDeck(.deck(deck))
        } label: {
            MacDJDeckBadge(deck: deck, size: 26)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Load on Deck \(deck.label)")
    }
}

// MARK: Picker sheet

struct PhoneDeckPicker: View {
    let target: PhoneDeckPickTarget
    let reference: PhoneDeckReference
    let onPick: (Track, PhoneDeckPickTarget) -> Void

    @StateObject private var browser = PhoneDeckBrowserModel()
    @ObservedObject private var files = LocalMusicLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @State private var isAdding = false

    var body: some View {
        NavigationStack {
            PhoneDeckBrowserList(model: browser, target: target, onAddFolder: { isAdding = true }) { track, target in
                onPick(track, target)
                dismiss()
            }
            .searchable(text: $browser.query, prompt: "Title, artist, BPM or key")
            .safeAreaBar(edge: .top) {
                PhoneDeckScopePicker(model: browser)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Folder", systemImage: "folder.badge.plus") { isAdding = true }
                }
            }
            .addMusicFolderImporter(isPresented: $isAdding)
            .task(id: files.allTracks.count) { await browser.reload(reference: reference) }
        }
    }

    private var title: String {
        switch target {
        case .deck(let deck): return "Load Deck \(deck.label)"
        case .next: return "Mix In Next"
        }
    }
}

struct PhoneDeckScopePicker: View {
    @ObservedObject var model: PhoneDeckBrowserModel

    var body: some View {
        if model.scopes.count > 1 {
            Picker("Show", selection: Binding(get: { model.scope }, set: { model.select($0) })) {
                ForEach(model.scopes) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}

// MARK: Inline browser

struct PhoneDeckBrowserPanel: View, @MainActor Equatable {
    let reference: PhoneDeckReference
    let onPick: (Track, PhoneDeckPickTarget) -> Void

    @StateObject private var browser = PhoneDeckBrowserModel()
    @ObservedObject private var files = LocalMusicLibrary.shared
    @State private var isAdding = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.reference == rhs.reference
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                PhoneDeckScopePicker(model: browser)
                    .frame(maxWidth: 420)
                Spacer(minLength: 0)
                searchField
                    .frame(maxWidth: 280)
            }
            PhoneDeckBrowserList(model: browser, target: nil, onAddFolder: { isAdding = true }, onPick: onPick)
        }
        .addMusicFolderImporter(isPresented: $isAdding)
        .task(id: files.allTracks.count) { await browser.reload(reference: reference) }
        .onChange(of: reference) { _, next in browser.update(reference: next) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Library")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Title, artist, BPM or key", text: $browser.query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !browser.query.isEmpty {
                Button {
                    browser.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Clear Search")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .glassEffect(.regular, in: Capsule())
    }
}
