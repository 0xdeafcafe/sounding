import SwiftUI

// MARK: - List

struct MixHistoryView: View {
    @State private var store = MixHistoryStore.shared
    @State private var replay = MixReplayController.shared
    @State private var renaming: RenameTarget?
    @State private var draftName = ""
    @State private var route: MixHistoryRoute?

    enum RenameTarget: Identifiable, Equatable {
        case mix(SavedMix)
        case set(SavedSet)
        case newMix(MixHistoryEntry)
        case newSet(MixHistorySession)

        var id: String {
            switch self {
            case .mix(let mix): return "mix-\(mix.id)"
            case .set(let set): return "set-\(set.id)"
            case .newMix(let entry): return "new-mix-\(entry.id)"
            case .newSet(let session): return "new-set-\(session.id)"
            }
        }
    }

    private var isReadOnly: Bool {
        #if os(tvOS)
        true
        #else
        false
        #endif
    }

    var body: some View {
        content
            .navigationTitle("Mixes")
            .navigationDestination(item: $route) { route in
                switch route {
                case .entry(let entry): MixTransitionDetailView(entry: entry)
                case .session(let session, let name): MixSetOverviewView(session: session, name: name)
                }
            }
            .alert(renameTitle, isPresented: renameBinding) {
                TextField("Name", text: $draftName)
                Button("Save") { commitRename() }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .onAppear(perform: applyDebugRoute)
    }

    @ViewBuilder
    private var content: some View {
        let saved = store.library
        let sessions = store.sessions.filter { $0.entries.count > 1 && !store.isSaved(session: $0) }
        let recent = store.recent
        if saved.mixes.isEmpty, saved.sets.isEmpty, recent.isEmpty {
            ContentUnavailableView(
                "No Mixes Yet",
                systemImage: "arrow.triangle.merge",
                description: Text("Transitions Auto Mix plays show up here, so you can save the good ones.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .remoteFocusTarget()
        } else {
            List {
                if let message = replay.message {
                    Section {
                        Label(message, systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                if !saved.sets.isEmpty || !saved.mixes.isEmpty {
                    Section("Saved") {
                        ForEach(saved.sets) { set in
                            sessionRow(set.session, name: set.name, saved: set)
                        }
                        ForEach(saved.mixes) { mix in
                            entryRow(mix.entry, name: mix.name, saved: mix)
                        }
                    }
                }
                if !sessions.isEmpty {
                    Section("Recent Sets") {
                        ForEach(sessions.prefix(20)) { session in
                            sessionRow(session, name: session.defaultName, saved: nil)
                        }
                    }
                }
                if !recent.isEmpty {
                    Section("Recent") {
                        ForEach(recent.prefix(200)) { entry in
                            entryRow(entry, name: entry.title, saved: nil)
                        }
                    }
                }
            }
        }
    }

    private func entryRow(_ entry: MixHistoryEntry, name: String, saved: SavedMix?) -> some View {
        Button {
            route = .entry(entry)
        } label: {
            MixHistoryRow(entry: entry, title: name)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Play This Mix", systemImage: "play") {
                Task { await replay.play(entry) }
            }
            if !isReadOnly {
                if let saved {
                    Button("Rename", systemImage: "pencil") { beginRename(.mix(saved), name: saved.name) }
                    Button("Remove from Saved", systemImage: "bookmark.slash", role: .destructive) { store.delete(mix: saved.id) }
                } else if !store.isSaved(entry) {
                    Button("Save Mix", systemImage: "bookmark") { beginRename(.newMix(entry), name: entry.title) }
                }
            }
        }
        #if !os(tvOS)
        .swipeActions(edge: .trailing) {
            if let saved {
                Button("Remove", systemImage: "bookmark.slash", role: .destructive) { store.delete(mix: saved.id) }
            } else if !store.isSaved(entry) {
                Button("Save", systemImage: "bookmark") { store.save(entry) }
            }
        }
        #endif
    }

    private func sessionRow(_ session: MixHistorySession, name: String, saved: SavedSet?) -> some View {
        Button {
            route = .session(session, name)
        } label: {
            MixSessionRow(session: session, title: name)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Play This Set", systemImage: "play") {
                Task { await replay.play(session) }
            }
            if !isReadOnly {
                if let saved {
                    Button("Rename", systemImage: "pencil") { beginRename(.set(saved), name: saved.name) }
                    Button("Remove from Saved", systemImage: "bookmark.slash", role: .destructive) { store.delete(set: saved.id) }
                } else {
                    Button("Save Set", systemImage: "bookmark") { beginRename(.newSet(session), name: session.defaultName) }
                }
            }
        }
        #if !os(tvOS)
        .swipeActions(edge: .trailing) {
            if let saved {
                Button("Remove", systemImage: "bookmark.slash", role: .destructive) { store.delete(set: saved.id) }
            } else {
                Button("Save", systemImage: "bookmark") { store.save(session: session) }
            }
        }
        #endif
    }

    private var renameTitle: String {
        switch renaming {
        case .newMix: return "Save Mix"
        case .newSet: return "Save Set"
        default: return "Rename"
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private func beginRename(_ target: RenameTarget, name: String) {
        draftName = name
        renaming = target
    }

    private func commitRename() {
        switch renaming {
        case .mix(let mix): store.rename(mix: mix.id, to: draftName)
        case .set(let set): store.rename(set: set.id, to: draftName)
        case .newMix(let entry): store.save(entry, name: draftName)
        case .newSet(let session): store.save(session: session, name: draftName)
        case nil: break
        }
        renaming = nil
    }

    private func applyDebugRoute() {
        #if DEBUG
        guard route == nil else { return }
        switch ProcessInfo.processInfo.environment["SOUNDING_TV_MIXES_ROUTE"] {
        case "overview":
            if let session = store.sessions.first { route = .session(session, "Friday warm-up") }
        case "detail":
            if let entry = store.entries.first { route = .entry(entry) }
        default:
            break
        }
        #endif
    }
}

enum MixHistoryRoute: Hashable, Identifiable {
    case entry(MixHistoryEntry)
    case session(MixHistorySession, String)

    var id: String {
        switch self {
        case .entry(let entry): return entry.id.uuidString
        case .session(let session, _): return session.id.uuidString
        }
    }

    static func == (lhs: MixHistoryRoute, rhs: MixHistoryRoute) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Rows

struct MixPairArtwork: View {
    let outgoing: Track
    let incoming: Track
    var size: CGFloat = 44

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            artwork(outgoing)
                .frame(width: size, height: size)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            artwork(incoming)
                .frame(width: size, height: size)
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                        .stroke(.background, lineWidth: 2)
                }
        }
        .frame(width: size * 1.45, height: size * 1.2)
        .accessibilityHidden(true)
    }

    private func artwork(_ track: Track) -> some View {
        SCArtworkResolver(url: track.artworkURL) { image in
            SCArtwork(image: image, identity: track.id, cornerRadius: size * 0.16)
        }
    }
}

struct MixHistoryRow: View {
    let entry: MixHistoryEntry
    var title: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private func mixDetailLayout<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 6))
        return layout { content() }
    }

    var body: some View {
        HStack(spacing: 12) {
            MixPairArtwork(outgoing: entry.outgoing.track, incoming: entry.incoming.track)
            VStack(alignment: .leading, spacing: 2) {
                Text(title ?? entry.title)
                    .font(.body)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                mixDetailLayout {
                    HStack(spacing: 6) {
                        Image(systemName: entry.symbolName)
                        Text(entry.moveName)
                    }
                    if !dynamicTypeSize.isAccessibilitySize { Text("·") }
                    Text(entry.date, format: .dateTime.day().month(.abbreviated).hour().minute())
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            }
            Spacer(minLength: 8)
            if let liked = entry.liked {
                Image(systemName: liked ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(liked ? "Rated Nice" : "Rated Not Great")
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct MixSessionRow: View {
    let session: MixHistorySession
    var title: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private func mixDetailLayout<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 6))
        return layout { content() }
    }

    var body: some View {
        HStack(spacing: 12) {
            if let first = session.tracks.first, let last = session.tracks.last {
                MixPairArtwork(outgoing: first.track, incoming: last.track)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                mixDetailLayout {
                    HStack(spacing: 6) {
                        Image(systemName: "list.number")
                        Text(session.title)
                    }
                    if !dynamicTypeSize.isAccessibilitySize { Text("·") }
                    Text(session.date, format: .dateTime.day().month(.abbreviated).hour().minute())
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            }
            Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Transition detail

struct MixTransitionDetailView: View {
    let entry: MixHistoryEntry

    @State private var store = MixHistoryStore.shared
    @State private var replay = MixReplayController.shared
    @State private var naming = false
    @State private var draftName = ""

    private var scale: AutoMixLiveScale {
        #if os(tvOS)
        .tv
        #elseif os(macOS)
        .mac
        #else
        .phone
        #endif
    }

    private var current: MixHistoryEntry { store.entry(for: entry.id) ?? entry }

    var body: some View {
        let entry = current
        let state = entry.liveState(now: Date(timeIntervalSinceReferenceDate: 0))
        Form {
            Section {
                VStack(alignment: .leading, spacing: scale.spacing) {
                    AutoMixTransitionView(state: state, scale: scale, tint: .white)
                    if let outgoing = state.outgoing {
                        AutoMixDeckLane(state: state, deck: outgoing, label: "A", audibility: 1, position: outgoing.positionSeconds, scale: scale, showsLoop: true)
                    }
                    if let incoming = state.incoming {
                        AutoMixDeckLane(state: state, deck: incoming, label: "B", audibility: 1, position: incoming.positionSeconds, scale: scale)
                    }
                }
                .padding(.vertical, 8)
                .environment(\.colorScheme, .dark)
                .listRowBackground(Color.black)
            }

            Section {
                actions(entry)
            }

            Section("Mix") {
                LabeledContent("Move", value: entry.moveName)
                LabeledContent("Exit", value: Self.point(entry.plan.mixPointSeconds, bar: entry.plan.exitBar))
                LabeledContent("Entry", value: Self.point(entry.execution.entrySeconds, bar: entry.plan.entryBar))
                LabeledContent("Length", value: "\(entry.plan.lengthBars) bars, \(DJFormat.time(entry.execution.windowSeconds))")
                LabeledContent("Tempo", value: Self.tempo(entry))
                if let loops = Self.loops(entry) {
                    LabeledContent("Loops", value: loops)
                }
                if let automation = Self.automation(entry) {
                    LabeledContent("Automation", value: automation)
                }
                LabeledContent("Rating", value: entry.ratingLabel ?? "Not rated")
            }

            if !entry.performance.isEmpty {
                Section("Before the Mix") {
                    ForEach(entry.performance) { move in
                        LabeledContent(move.kind.displayName, value: DJFormat.time(move.startSeconds))
                    }
                }
            }

            Section("Tracks") {
                LabeledContent(entry.outgoing.title, value: Self.trackDetail(entry.outgoing))
                LabeledContent(entry.incoming.title, value: Self.trackDetail(entry.incoming))
            }
        }
        .formStyle(.grouped)
        .navigationTitle(entry.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert("Save Mix", isPresented: $naming) {
            TextField("Name", text: $draftName)
            Button("Save") { store.save(entry, name: draftName) }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func actions(_ entry: MixHistoryEntry) -> some View {
        Button("Play This Mix", systemImage: "play.fill") {
            Task { await replay.play(entry) }
        }
        .disabled(replay.isStarting)
        #if !os(tvOS)
        if store.isSaved(entry) {
            Label("Saved", systemImage: "bookmark.fill")
                .foregroundStyle(.secondary)
        } else {
            Button("Save Mix", systemImage: "bookmark") {
                draftName = entry.title
                naming = true
            }
        }
        #endif
        if let message = replay.message, replay.activeID == entry.id {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    static func point(_ seconds: TimeInterval, bar: Int?) -> String {
        bar.map { "\(DJFormat.time(seconds)), bar \($0)" } ?? DJFormat.time(seconds)
    }

    static func tempo(_ entry: MixHistoryEntry) -> String {
        let percent = (entry.plan.incomingRateRatio - 1) * 100
        let bpm = entry.outgoing.bpm.map { "\(Int($0.rounded())) BPM" }
        let shift = abs(percent) < 0.05 ? "no change" : String(format: "%+.1f%%", percent)
        return [bpm, shift].compactMap { $0 }.joined(separator: ", ")
    }

    static func loops(_ entry: MixHistoryEntry) -> String? {
        let regions = entry.plan.loopRegions
        guard !regions.isEmpty else { return nil }
        let bar = entry.plan.barSeconds
        return regions.map { region in
            let bars = Int(((region.upperBound - region.lowerBound) / bar).rounded())
            return "\(bars) bars at \(DJFormat.time(region.lowerBound))"
        }.joined(separator: ", ")
    }

    static func automation(_ entry: MixHistoryEntry) -> String? {
        var parts: [String] = []
        for stage in entry.plan.stages {
            switch stage.action {
            case .loop, .clearLoop: continue
            default:
                let text = stage.action.summary
                if !parts.contains(text) { parts.append(text) }
            }
        }
        if parts.isEmpty, let effect = entry.plan.move?.effect, effect != .none {
            switch effect {
            case .filterSweep: parts.append("filter sweep")
            case .echo: parts.append("echo")
            case .reverbWash: parts.append("reverb wash")
            case .none: break
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ").prefix(1).uppercased() + parts.joined(separator: ", ").dropFirst()
    }

    static func trackDetail(_ track: MixTrackSnapshot) -> String {
        [track.bpm.map { "\(Int($0.rounded())) BPM" }, track.camelot].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Set overview

struct MixSetOverviewView: View {
    let session: MixHistorySession
    var name: String

    @State private var replay = MixReplayController.shared
    @State private var store = MixHistoryStore.shared
    @State private var selectedTime: TimeInterval = 0
    @State private var zoom: CGFloat = 1
    @State private var baseZoom: CGFloat = 1
    @State private var hoverTime: TimeInterval?

    private var layout: MixSetLayout { MixSetLayout(session: session) }

    var body: some View {
        let layout = layout
        Form {
            Section {
                timeline(layout)
                    .listRowInsets(EdgeInsets())
                    .environment(\.colorScheme, .dark)
                    .listRowBackground(Color.black)
                #if !os(tvOS)
                playFromHere(layout)
                #endif
            }

            Section("Tracklist") {
                ForEach(layout.segments) { segment in
                    Button {
                        selectedTime = segment.setStart
                    } label: {
                        HStack(spacing: 12) {
                            Text(MixSetLayout.timestamp(segment.setStart))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 52, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(segment.track.title).lineLimit(1)
                                Text(segment.track.artist)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Text(MixTransitionDetailView.trackDetail(segment.track))
                                .font(.subheadline)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("Transitions") {
                ForEach(layout.blends) { blend in
                    NavigationLink {
                        MixTransitionDetailView(entry: blend.entry)
                    } label: {
                        HStack(spacing: 12) {
                            Text(MixSetLayout.timestamp(blend.setStart))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 52, alignment: .leading)
                            Image(systemName: blend.entry.symbolName)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(blend.entry.moveName)
                                Text(blend.entry.title)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            if let liked = blend.entry.liked {
                                Image(systemName: liked ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section {
                Button("Play This Set", systemImage: "play.fill") {
                    Task { await replay.play(session) }
                }
                #if !os(tvOS)
                if !store.isSaved(session: session) {
                    Button("Save Set", systemImage: "bookmark") {
                        store.save(session: session, name: name)
                    }
                }
                #endif
            }
        }
        .formStyle(.grouped)
        .navigationTitle(name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    private func playFromHere(_ layout: MixSetLayout) -> some View {
        let index = layout.transitionIndex(at: selectedTime) ?? 0
        let segment = layout.segment(at: selectedTime)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(MixSetLayout.timestamp(selectedTime))
                    .monospacedDigit()
                Text(segment?.track.title ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Play from Here", systemImage: "play.fill") {
                Task { await replay.play(session, from: index) }
            }
            .buttonStyle(.bordered)
        }
    }

    #if os(tvOS)
    private func timeline(_ layout: MixSetLayout) -> some View {
        GeometryReader { proxy in
            MixSetTimelineCanvas(layout: layout, perSecond: proxy.size.width / CGFloat(max(1, layout.duration)), selectedTime: selectedTime)
        }
        .frame(height: MixSetTimelineCanvas.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary(layout))
    }
    #else
    private func timeline(_ layout: MixSetLayout) -> some View {
        let base: CGFloat = {
            #if os(macOS)
            return 0
            #else
            return 0.6
            #endif
        }()
        return GeometryReader { proxy in
            let fit = proxy.size.width / CGFloat(max(1, layout.duration))
            let perSecond = max(fit, base * zoom)
            let width = max(proxy.size.width, CGFloat(layout.duration) * perSecond)
            ScrollView(.horizontal, showsIndicators: false) {
                MixSetTimelineCanvas(layout: layout, perSecond: perSecond, selectedTime: selectedTime, hoverTime: hoverTime)
                    .frame(width: width, height: MixSetTimelineCanvas.height)
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { value in
                        selectedTime = min(layout.duration, max(0, Double(value.location.x / perSecond)))
                    })
                    #if os(macOS)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point): hoverTime = Double(point.x / perSecond)
                        case .ended: hoverTime = nil
                        }
                    }
                    #endif
            }
            #if os(iOS)
            .simultaneousGesture(MagnifyGesture().onChanged { value in
                zoom = min(8, max(1, baseZoom * value.magnification))
            }.onEnded { _ in baseZoom = zoom })
            #endif
        }
        .frame(height: MixSetTimelineCanvas.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary(layout))
    }
    #endif

    private func accessibilitySummary(_ layout: MixSetLayout) -> String {
        let parts = layout.segments.map { "\(MixSetLayout.timestamp($0.setStart)) \($0.track.title)" }
        return "Set timeline, \(MixSetLayout.timestamp(layout.duration)). " + parts.joined(separator: ", ")
    }
}

struct MixSetTimelineCanvas: View {
    let layout: MixSetLayout
    let perSecond: CGFloat
    let selectedTime: TimeInterval
    var hoverTime: TimeInterval?

    static let height: CGFloat = 214
    static let headerHeight: CGFloat = 20
    static let energyHeight: CGFloat = 44
    static let laneHeight: CGFloat = 46
    static let laneGap: CGFloat = 8
    static let labelHeight: CGFloat = 22

    var body: some View {
        let samples = Dictionary(uniqueKeysWithValues: layout.segments.map { ($0.index, MixSetTimelineCanvas.samples(for: $0.track.track)) })
        Canvas { context, size in
            draw(&context, size: size, samples: samples)
        }
    }

    @MainActor
    static func samples(for track: Track) -> [Float]? {
        if let samples = WaveformService.shared.state(for: track.id).waveform?.samples, !samples.isEmpty {
            return SCWaveformSampler.visuallyNormalized(samples)
        }
        #if DEBUG
        guard MixHistoryStore.isFixtureRequested else { return nil }
        var seed: UInt64 = track.id.unicodeScalars.reduce(1469598103934665603) { ($0 ^ UInt64($1.value)) &* 1099511628211 }
        let count = max(64, Int(track.duration))
        return (0..<count).map { i in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = Float(seed >> 40) / Float(1 << 24)
            let shape = Float(0.55 + 0.4 * sin(Double(i) / Double(count) * .pi * 5 + Double(seed % 3)))
            return min(1, max(0.08, shape * 0.8 + noise * 0.25))
        }
        #else
        return nil
        #endif
    }

    private func x(_ t: TimeInterval) -> CGFloat { CGFloat(t) * perSecond }

    private func draw(_ context: inout GraphicsContext, size: CGSize, samples: [Int: [Float]?]) {
        let laneTop = Self.headerHeight + Self.energyHeight + Self.labelHeight
        let lanes = [laneTop, laneTop + Self.laneHeight + Self.laneGap]

        for segment in layout.segments {
            let x0 = x(segment.setStart)
            let label = [segment.track.bpm.map { "\(Int($0.rounded()))" }, segment.track.camelot].compactMap { $0 }.joined(separator: " · ")
            if !label.isEmpty {
                context.draw(Text(label).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.7)), at: CGPoint(x: x0 + 6, y: 2), anchor: .topLeading)
            }
        }

        var energy = Path()
        let energyTop = Self.headerHeight
        let points: [CGPoint] = layout.segments.map { segment in
            let level = Double(segment.track.energyLevel ?? 5)
            let y = energyTop + Self.energyHeight * CGFloat(1 - min(10, max(0, level)) / 10)
            return CGPoint(x: x((segment.setStart + segment.setEnd) / 2), y: y)
        }
        if let first = points.first {
            energy.move(to: CGPoint(x: 0, y: first.y))
            energy.addLine(to: first)
            for (a, b) in zip(points, points.dropFirst()) {
                let mid = (a.x + b.x) / 2
                energy.addCurve(to: b, control1: CGPoint(x: mid, y: a.y), control2: CGPoint(x: mid, y: b.y))
            }
            if let last = points.last { energy.addLine(to: CGPoint(x: size.width, y: last.y)) }
            var fill = energy
            fill.addLine(to: CGPoint(x: size.width, y: energyTop + Self.energyHeight))
            fill.addLine(to: CGPoint(x: 0, y: energyTop + Self.energyHeight))
            fill.closeSubpath()
            context.fill(fill, with: .color(.white.opacity(0.08)))
            context.stroke(energy, with: .color(.white.opacity(0.6)), lineWidth: 1.5)
        }

        for blend in layout.blends {
            let rect = CGRect(x: x(blend.setStart), y: lanes[0] - 4, width: max(2, x(blend.setEnd) - x(blend.setStart)), height: Self.laneHeight * 2 + Self.laneGap + 8)
            context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(.white.opacity(0.12)))
            let labelY = laneTop - Self.labelHeight + 3
            let text = Text("\(Image(systemName: blend.entry.symbolName)) \(blend.entry.moveName)").font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
            context.draw(text, at: CGPoint(x: rect.minX, y: labelY), anchor: .topLeading)
        }

        for segment in layout.segments {
            let top = lanes[segment.index % 2]
            let rect = CGRect(x: x(segment.setStart), y: top, width: max(2, x(segment.setEnd) - x(segment.setStart)), height: Self.laneHeight)
            context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(.white.opacity(0.06)))
            if let values = samples[segment.index] ?? nil, !values.isEmpty {
                let step: CGFloat = 3
                var px = rect.minX
                while px < rect.maxX {
                    let t = segment.sourceStart + Double((px - rect.minX) / perSecond)
                    let amp = CGFloat(SCWaveformSampler.amplitude(in: values, duration: segment.track.track.duration, at: t))
                    let h = max(1.5, amp * (Self.laneHeight - 8))
                    context.fill(Path(roundedRect: CGRect(x: px, y: rect.midY - h / 2, width: 1.8, height: h), cornerRadius: 0.9), with: .color(.white.opacity(0.55)))
                    px += step
                }
            }
            context.draw(Text(segment.track.title).font(.caption2).foregroundStyle(.white), at: CGPoint(x: rect.minX + 6, y: rect.minY + 3), anchor: .topLeading)
        }

        for marker in layout.markers {
            let top = lanes[marker.segment % 2]
            let px = x(marker.setTime)
            var diamond = Path()
            diamond.move(to: CGPoint(x: px, y: top + Self.laneHeight - 10))
            diamond.addLine(to: CGPoint(x: px + 4, y: top + Self.laneHeight - 6))
            diamond.addLine(to: CGPoint(x: px, y: top + Self.laneHeight - 2))
            diamond.addLine(to: CGPoint(x: px - 4, y: top + Self.laneHeight - 6))
            diamond.closeSubpath()
            context.fill(diamond, with: .color(.white.opacity(0.9)))
        }

        let playhead = x(selectedTime)
        context.fill(Path(CGRect(x: playhead - 0.75, y: Self.headerHeight, width: 1.5, height: size.height - Self.headerHeight)), with: .color(.white))
        if let hoverTime {
            let hx = x(hoverTime)
            context.fill(Path(CGRect(x: hx - 0.5, y: Self.headerHeight, width: 1, height: size.height - Self.headerHeight)), with: .color(.white.opacity(0.4)))
            let title = layout.segment(at: hoverTime)?.track.title ?? ""
            context.draw(Text("\(MixSetLayout.timestamp(hoverTime))  \(title)").font(.caption2.monospacedDigit()).foregroundStyle(.white), at: CGPoint(x: hx + 4, y: size.height - 4), anchor: .bottomLeading)
        }
    }
}
