import SwiftUI
import CoreTransferable

@MainActor
final class NetworkActivityModel: ObservableObject {
    @Published private(set) var entries: [NetworkActivityEntry] = []
    @Published private(set) var summary = NetworkIssueSummary([])
    @Published private(set) var isPaused = false
    @Published private(set) var savesSessionFile = false
    @Published private(set) var sessionFile: URL?

    let log: NetworkActivityLog
    private var seenVersion = -1

    init(log: NetworkActivityLog = .shared) {
        self.log = log
    }

    func run() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func refresh() async {
        let version = log.version
        guard version != seenVersion else { return }
        seenVersion = version
        let log = log
        let (entries, summary) = await Task.detached(priority: .utility) {
            let snapshot = log.snapshot()
            return (Array(snapshot.reversed()), NetworkIssueSummary(snapshot))
        }.value
        self.entries = entries
        self.summary = summary
        isPaused = log.isPaused
        savesSessionFile = log.savesSessionFile
        sessionFile = log.existingSessionFile
    }

    func togglePaused() {
        log.setPaused(!log.isPaused)
        isPaused = log.isPaused
    }

    func setSavesSessionFile(_ saves: Bool) {
        log.savesSessionFile = saves
        savesSessionFile = saves
    }

    func clear() {
        log.clear()
        Task { await refresh() }
    }

    func requests(since date: Date) -> Int {
        entries.reduce(0) { $0 + ($1.isWire && $1.date >= date && NetworkHostPolicy.isAPI($1.host) ? 1 : 0) }
    }

    var features: [NetworkFeature] {
        Array(Set(entries.map(\.feature))).sorted()
    }
}

struct NetworkActivityExport: Transferable {
    let log: NetworkActivityLog

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation { export in export.log.exportText() }
    }
}

struct NetworkActivityView: View {
    @StateObject private var model = NetworkActivityModel()
    @ObservedObject private var gateway = SoundCloudGateway.shared
    @State private var feature: NetworkFeature?
    @State private var issue: NetworkIssues?
    @State private var issuesOnly = false
    @State private var query = ""
    @State private var showingClearConfirmation = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        content
            .navigationTitle("Network Activity")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $query, prompt: "Host, path or status")
            #if !os(tvOS)
            .toolbar { toolbar }
            #endif
            .confirmationDialog("Clear Network Activity", isPresented: $showingClearConfirmation) {
                Button("Clear", role: .destructive) { model.clear() }
                Button("Cancel", role: .cancel) {}
            }
            .task { await model.run() }
    }

    @ViewBuilder
    private var content: some View {
        if model.entries.isEmpty {
            #if os(tvOS)
            List {
                controls
                Section {
                    ContentUnavailableView("No Network Activity", systemImage: "network", description: Text(emptyDescription))
                }
            }
            #else
            ContentUnavailableView("No Network Activity", systemImage: "network", description: Text(emptyDescription))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            #endif
        } else {
            let visible = filtered
            #if os(tvOS)
            list(visible)
            #else
            if visible.isEmpty {
                noMatches
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list(visible)
            }
            #endif
        }
    }

    @ViewBuilder
    private var noMatches: some View {
        if query.isEmpty {
            ContentUnavailableView("No Matching Requests", systemImage: "line.3.horizontal.decrease.circle", description: Text("Try another filter."))
        } else {
            ContentUnavailableView.search(text: query)
        }
    }

    private var emptyDescription: String {
        model.isPaused
            ? "Recording is paused."
            : "Requests from this \(DeviceClass.current.displayName) appear here."
    }

    private func list(_ visible: [NetworkActivityEntry]) -> some View {
        List {
            #if os(tvOS)
            controls
            #endif
            summarySection
            Section(sectionTitle(visible.count)) {
                #if os(tvOS)
                if visible.isEmpty { noMatches }
                #endif
                ForEach(visible) { entry in
                    NavigationLink {
                        NetworkActivityDetailView(entry: entry)
                    } label: {
                        NetworkActivityRow(entry: entry)
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
    }

    private func sectionTitle(_ count: Int) -> String {
        count == model.entries.count ? "Recent" : "\(count) of \(model.entries.count)"
    }

    private var summarySection: some View {
        Section {
            if case .waiting(_, let until) = gateway.trafficSafety {
                LabeledContent("Status", value: "Limited until \(until.formatted(date: .omitted, time: .shortened))")
            }
            let now = Date()
            LabeledContent("Last Minute", value: "\(model.requests(since: now.addingTimeInterval(-60)))")
            LabeledContent("Last Hour", value: "\(model.requests(since: now.addingTimeInterval(-3600)))")
            if model.summary.isEmpty {
                LabeledContent("Issues", value: "None")
            } else {
                ForEach(model.summary.counts, id: \.issue.rawValue) { count in
                    Button {
                        issue = issue == count.issue ? nil : count.issue
                    } label: {
                        LabeledContent {
                            Text("\(count.count)").monospacedDigit()
                        } label: {
                            Label(count.issue.title, systemImage: issue == count.issue ? "checkmark.circle.fill" : NetworkActivityText.symbol(for: count.issue))
                                .foregroundStyle(.red)
                        }
                        .contentShape(Rectangle())
                    }
                    #if os(macOS)
                    .buttonStyle(.plain)
                    #endif
                }
            }
        } header: {
            Text("Summary")
        } footer: {
            Text(model.isPaused ? "Recording is paused." : "The last \(NetworkActivityLog.capacity) requests on this \(DeviceClass.current.displayName).")
        }
    }

    #if os(tvOS)
    private var controls: some View {
        Section {
            Picker("Feature", selection: $feature) {
                Text("All").tag(NetworkFeature?.none)
                ForEach(model.features, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
            }
            Toggle("Issues Only", isOn: $issuesOnly)
            Button(model.isPaused ? "Resume Recording" : "Pause Recording") { model.togglePaused() }
            Toggle("Save Session File", isOn: Binding(get: { model.savesSessionFile }, set: { model.setSavesSessionFile($0) }))
            Button("Clear", role: .destructive) { showingClearConfirmation = true }
                .disabled(model.entries.isEmpty)
        }
    }
    #endif

    #if !os(tvOS)
    @ViewBuilder
    private var filterMenuContent: some View {
        Picker("Feature", selection: $feature) {
            Text("All Features").tag(NetworkFeature?.none)
            ForEach(model.features, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
        }
        .pickerStyle(.inline)
        Toggle("Issues Only", isOn: $issuesOnly)
    }

    private var pauseButton: some View {
        Button {
            model.togglePaused()
        } label: {
            Label(model.isPaused ? "Resume" : "Pause", systemImage: model.isPaused ? "play.circle" : "pause.circle")
        }
    }

    @ViewBuilder
    private var moreMenuContent: some View {
        ShareLink(item: NetworkActivityExport(log: model.log), preview: SharePreview("Sounding Network Activity")) {
            Label("Export Log", systemImage: "square.and.arrow.up")
        }
        .disabled(model.entries.isEmpty)
        if let file = model.sessionFile {
            ShareLink(item: file) {
                Label("Export Session File", systemImage: "doc")
            }
        }
        Toggle("Save Session File", isOn: Binding(get: { model.savesSessionFile }, set: { model.setSavesSessionFile($0) }))
        Divider()
        Button("Clear", systemImage: "trash", role: .destructive) { showingClearConfirmation = true }
            .disabled(model.entries.isEmpty)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if dynamicTypeSize.isAccessibilitySize {
                Menu {
                    Menu {
                        filterMenuContent
                    } label: {
                        Label("Filter", systemImage: isFiltering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    pauseButton
                    Divider()
                    moreMenuContent
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            } else {
                Menu {
                    filterMenuContent
                } label: {
                    Label("Filter", systemImage: isFiltering ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                pauseButton
                Menu {
                    moreMenuContent
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
    }
    #endif

    private var isFiltering: Bool { feature != nil || issuesOnly || issue != nil }

    private var filtered: [NetworkActivityEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard isFiltering || !needle.isEmpty else { return model.entries }
        return model.entries.filter { entry in
            if let feature, entry.feature != feature { return false }
            if issuesOnly, !entry.hasIssues { return false }
            if let issue, !entry.issues.contains(issue) { return false }
            guard !needle.isEmpty else { return true }
            return entry.displayURL.localizedCaseInsensitiveContains(needle)
                || entry.feature.rawValue.localizedCaseInsensitiveContains(needle)
                || entry.status.map { String($0).hasPrefix(needle) } ?? false
        }
    }
}

private struct NetworkActivityRow: View {
    let entry: NetworkActivityEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(NetworkActivityText.title(for: entry))
                    .font(.subheadline.monospaced())
                    .lineLimit(2)
                Text(NetworkActivityText.detail(for: entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if entry.hasIssues {
                    Text(entry.issues.title)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer(minLength: 8)
            Text(NetworkActivityText.status(for: entry))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(entry.hasIssues ? .red : .secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct NetworkActivityDetailView: View {
    let entry: NetworkActivityEntry

    var body: some View {
        Form {
            if entry.hasIssues {
                Section("Issues") {
                    ForEach(NetworkIssues.ordered.filter(entry.issues.contains), id: \.rawValue) { issue in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(issue.title, systemImage: NetworkActivityText.symbol(for: issue))
                                .foregroundStyle(.red)
                            Text(NetworkActivityText.explanation(for: issue))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Request") {
                LabeledContent("Time", value: entry.date.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3))))
                LabeledContent("Feature", value: entry.feature.rawValue)
                LabeledContent("Method", value: entry.method)
                if !entry.host.isEmpty { LabeledContent("Host", value: entry.host) }
                LabeledContent("Path") { Text(entry.path).font(.callout.monospaced()).networkTextSelection() }
                ForEach(Array(entry.query.split(separator: "&").enumerated()), id: \.offset) { _, item in
                    let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
                    LabeledContent(pair[0]) {
                        Text(pair.count > 1 ? (pair[1].removingPercentEncoding ?? pair[1]) : "")
                            .font(.callout.monospaced())
                            .networkTextSelection()
                    }
                }
            }
            Section("Response") {
                LabeledContent("Status", value: NetworkActivityText.status(for: entry))
                if let duration = entry.duration {
                    LabeledContent("Duration", value: NetworkActivityText.duration(duration))
                }
                if let bytes = entry.bytes {
                    LabeledContent("Size", value: bytes.formatted(.byteCount(style: .file)))
                }
                LabeledContent("Source", value: NetworkActivityText.source(entry.source))
                LabeledContent("Retried", value: entry.retried ? "Yes" : "No")
                if let error = entry.error { LabeledContent("Error", value: error) }
                if let until = entry.until {
                    LabeledContent("Paused Until", value: until.formatted(date: .omitted, time: .standard))
                }
            }
            if !entry.lane.isEmpty || !entry.intent.isEmpty {
                Section("Context") {
                    if !entry.lane.isEmpty { LabeledContent("Lane", value: entry.lane) }
                    if !entry.intent.isEmpty { LabeledContent("Intent", value: entry.intent) }
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle(entry.feature.rawValue)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

enum NetworkActivityText {
    static func title(for entry: NetworkActivityEntry) -> String {
        switch entry.kind {
        case .request: return "\(entry.method) \(entry.hostAndPath)"
        case .trafficStop: return "Stopped after \(entry.path)"
        case .backgroundPause: return "Background paused after \(entry.path)"
        case .playbackPause: return "Playback paused after \(entry.path)"
        case .laneCooldown: return "\(entry.lane.capitalized) paused after \(entry.path)"
        }
    }

    static func status(for entry: NetworkActivityEntry) -> String {
        if let status = entry.status { return String(status) }
        switch entry.source {
        case .held: return "Held"
        case .rejected: return "Blocked"
        case .player: return "Player"
        default: return entry.error == "cancelled" ? "Cancelled" : "Failed"
        }
    }

    static func detail(for entry: NetworkActivityEntry) -> String {
        var parts = [entry.date.formatted(date: .omitted, time: .standard), entry.feature.rawValue]
        if let seconds = entry.duration { parts.append(Self.duration(seconds)) }
        if let bytes = entry.bytes { parts.append(bytes.formatted(.byteCount(style: .file))) }
        if entry.source != .network { parts.append(source(entry.source).lowercased()) }
        if entry.retried { parts.append("retry") }
        if let until = entry.until { parts.append("until \(until.formatted(date: .omitted, time: .shortened))") }
        return parts.joined(separator: " · ")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "\(Int((seconds * 1_000).rounded())) ms" : String(format: "%.1f s", seconds)
    }

    static func source(_ source: NetworkActivityEntry.Source) -> String {
        switch source {
        case .network: return "Network"
        case .cache: return "Cache"
        case .shared: return "Shared"
        case .revalidated: return "Revalidated"
        case .held: return "Held"
        case .rejected: return "Blocked"
        case .player: return "Player"
        }
    }

    static func symbol(for issue: NetworkIssues) -> String {
        switch issue {
        case .rateLimited: return "hand.raised"
        case .backoff: return "pause.circle"
        case .failed: return "xmark.octagon"
        case .duplicate: return "square.on.square"
        case .repeatedPing: return "megaphone"
        case .background: return "moon"
        case .unexpectedHost: return "questionmark.diamond"
        default: return "exclamationmark.triangle"
        }
    }

    static func explanation(for issue: NetworkIssues) -> String {
        switch issue {
        case .rateLimited: return "The server answered 429."
        case .backoff: return "Requests were paused after a rate limit."
        case .failed: return "The request failed or returned an error status."
        case .duplicate: return "The same request went out within \(Int(NetworkActivityLog.duplicateWindow)) seconds."
        case .repeatedPing: return "This promoted tracking URL fired more than once."
        case .background: return "Sent while the app was in the background."
        case .unexpectedHost: return "This host isn't one the app expects to talk to."
        default: return ""
        }
    }
}

private extension View {
    @ViewBuilder
    func networkTextSelection() -> some View {
        #if os(tvOS)
        self
        #else
        textSelection(.enabled)
        #endif
    }
}

#if DEBUG
enum NetworkActivityFixture {
    static var isRequested: Bool { ProcessInfo.processInfo.environment["SOUNDING_TV_NETWORK_FIXTURE"] == "1" }

    static func seed(_ log: NetworkActivityLog = .shared) {
        guard log.snapshot().isEmpty else { return }
        let base = Date().addingTimeInterval(-90)
        func at(_ offset: TimeInterval) -> Date { base.addingTimeInterval(offset) }
        func record(_ feature: NetworkFeature, _ url: String, status: Int?, ms: Double, bytes: Int?, source: NetworkActivityEntry.Source = .network, lane: String = "metadata", offset: TimeInterval) {
            log.record(NetworkRequestRecord(
                feature: feature, url: URL(string: url)!, lane: lane, intent: "userInitiated",
                status: status, duration: ms / 1_000, bytes: bytes, source: source
            ), now: at(offset))
        }
        record(.profile, "https://api-v2.soundcloud.com/me?client_id=abc", status: 200, ms: 182, bytes: 2_310, offset: 0)
        record(.feed, "https://api-v2.soundcloud.com/stream?limit=50&offset=0", status: 200, ms: 412, bytes: 48_200, lane: "feed", offset: 1)
        record(.artwork, "https://i1.sndcdn.com/artworks-000-t500x500.jpg", status: 200, ms: 64, bytes: 38_100, offset: 2)
        record(.artwork, "https://i1.sndcdn.com/artworks-001-t500x500.jpg", status: 404, ms: 51, bytes: 0, offset: 2.5)
        record(.promotedImpression, "https://promoted.soundcloud.com/impression?urn=soundcloud:ads:1", status: 204, ms: 90, bytes: 0, offset: 3)
        record(.promotedImpression, "https://promoted.soundcloud.com/impression?urn=soundcloud:ads:1", status: 204, ms: 88, bytes: 0, offset: 20)
        record(.search, "https://api-v2.soundcloud.com/search/tracks?q=house&limit=20", status: 200, ms: 240, bytes: 22_000, offset: 30)
        record(.search, "https://api-v2.soundcloud.com/search/tracks?q=house&limit=20", status: 200, ms: 236, bytes: 22_000, offset: 31)
        record(.streamResolve, "https://api-v2.soundcloud.com/media/soundcloud:tracks:1/abc/stream/hls?track_authorization=xyz", status: 200, ms: 133, bytes: 410, lane: "streamResolution", offset: 40)
        record(.waveform, "https://wave.sndcdn.com/abc_m.json", status: 200, ms: 70, bytes: 9_800, lane: "waveform", offset: 41)
        record(.likes, "https://api-v2.soundcloud.com/users/1/track_likes?limit=50", status: 200, ms: 0, bytes: 61_000, source: .cache, offset: 50)
        record(.feed, "https://api-v2.soundcloud.com/me/activities?limit=10", status: 429, ms: 120, bytes: 180, lane: "feed", offset: 60)
        log.recordStop(.trafficStop, endpoint: "v2/me/activities", lane: "feed", intent: "userInitiated", until: Date().addingTimeInterval(110), now: at(60.1))
        record(.sonos, "http://192.168.1.20:1400/MediaRenderer/AVTransport/Control", status: 200, ms: 18, bytes: 900, offset: 70)
        record(.download, "https://cf-hls-media.sndcdn.com/media/0/30000/abc.m3u8?Policy=p&Signature=s&Key-Pair-Id=k", status: 200, ms: 1_840, bytes: 7_400_000, offset: 80)
    }
}
#endif
