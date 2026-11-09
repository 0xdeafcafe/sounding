import AppKit
import AVFoundation
import Observation
import SwiftUI

struct ABOptions {
    var manifest: URL
    var kind: ABRender.Kind = .transition
    var variants: [String] = []
    var pad = 25.0
    var seed = UInt64(Date().timeIntervalSince1970 * 1000)
    var json = false
    var results: [URL] = []

    static func parse(_ args: [String]) throws -> ABOptions {
        guard let path = args.first else { throw ABError("missing manifest path") }
        var o = ABOptions(manifest: URL(fileURLWithPath: path).standardizedFileURL)
        var i = 1
        while i < args.count {
            let a = args[i]
            func value() throws -> String {
                i += 1
                guard i < args.count else { throw ABError("\(a) needs a value") }
                return args[i]
            }
            switch a {
            case "--long": o.kind = .long
            case "--variants": o.variants = try value().split(separator: ",").map(String.init)
            case "--pad": o.pad = Double(try value()) ?? 25
            case "--seed": o.seed = UInt64(try value()) ?? o.seed
            case "--json": o.json = true
            default: o.results.append(URL(fileURLWithPath: a))
            }
            i += 1
        }
        return o
    }

    func resolvedVariants(_ manifest: ABManifest) -> [String] {
        if variants.count == 2 { return variants }
        let all = manifest.variants
        if all.count == 2, all.contains("baseline"), let other = all.first(where: { $0 != "baseline" }) { return [other, "baseline"] }
        if all.count == 2, Set(all) == ["after", "before"] { return ["after", "before"] }
        return all
    }
}

@main
enum ABEntry {
    static let usage = """
    usage:
      automix-ab open <manifest.json> [--long] [--variants after,before] [--pad 25] [--seed N]
      automix-ab analyse <manifest.json> [results.json ...] [--variants after,before] [--json]
      automix-ab add <manifest.json> <render.json> [render.json ...]
      automix-ab check <manifest.json>
    """

    static func main() {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else { fail(usage) }
        args.removeFirst()
        do {
            switch command {
            case "open":
                ABLaunch.options = try ABOptions.parse(args)
                MainActor.assumeIsolated { openWindow() }
            case "analyse", "analyze":
                try analyse(ABOptions.parse(args))
            case "add":
                try add(args)
            case "check":
                try check(ABOptions.parse(args))
            case "selftest":
                exit(ABSelfTest.run() ? 0 : 1)
            case "snapshot":
                guard args.count >= 2 else { fail(usage) }
                let options = try ABOptions.parse(Array(args.dropLast()))
                MainActor.assumeIsolated { snapshot(options, to: URL(fileURLWithPath: args[args.count - 1])) }
            default:
                fail(usage)
            }
        } catch {
            fail("automix-ab: \(error)")
        }
    }

    @MainActor
    static func openWindow() {
        let app = NSApplication.shared
        let delegate = ABAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        let model = ABModel(options: ABLaunch.options)
        let root = ABView(model: model).frame(minWidth: 560, minHeight: 640).task { await model.start() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Auto Mix A/B"
        window.contentView = NSHostingView(rootView: root)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        withExtendedLifetime(delegate) { app.run() }
    }

    @MainActor
    static func snapshot(_ options: ABOptions, to url: URL) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let model = ABModel(options: options)
        Task { @MainActor in
            await model.start()
            model.preference = .a
            model.bFaults = [.muddyBass, .tooLong]
            let size = NSRect(x: 0, y: 0, width: 600, height: 820)
            let view = NSHostingView(rootView: ABView(model: model).frame(width: size.width, height: size.height))
            view.frame = size
            let window = NSWindow(contentRect: size, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window.orderBack(nil)
            try? await Task.sleep(for: .milliseconds(800))
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print(url.path)
            exit(0)
        }
        NSApplication.shared.run()
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }

    static func analyse(_ o: ABOptions) throws {
        let manifest = try ABManifest.load(o.manifest)
        let files = o.results.isEmpty ? ABAnalysis.resultFiles(near: o.manifest) : o.results
        let sessions = ABAnalysis.loadSessions(files)
        let judgments = sessions.flatMap(\.judgments)
        guard !judgments.isEmpty else { fail("no judgments found in \(files.map(\.path).joined(separator: ", "))") }
        let variants = o.resolvedVariants(manifest)
        guard variants.count >= 2 else { fail("need two variants") }
        let focus = variants[0], other = variants[1]
        var reports = [ABAnalysis.compare(judgments, focus: focus, other: other, kind: "all")]
        for kind in [ABRender.Kind.transition, .long] {
            let subset = judgments.filter { $0.kind == kind }
            if !subset.isEmpty, subset.count != judgments.count { reports.append(ABAnalysis.compare(subset, focus: focus, other: other, kind: kind.rawValue)) }
        }
        if o.json {
            print(String(decoding: try ABCoding.encoder.encode(reports), as: UTF8.self))
        } else {
            print("\(sessions.count) sessions, \(judgments.count) judgments from \(files.count) files")
            for r in reports { print(ABAnalysis.text(r)) }
            let pairs = Set(judgments.map(\.pair)).count
            print("training readiness: \(judgments.count)/150 ratings, \(pairs)/30 pairs")
        }
    }

    static func add(_ args: [String]) throws {
        guard args.count >= 2 else { fail(usage) }
        let url = URL(fileURLWithPath: args[0])
        var manifest = (try? ABManifest.load(url)) ?? ABManifest(name: url.deletingPathExtension().lastPathComponent, created: Date(), renders: [])
        for path in args.dropFirst() {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            if let many = try? ABCoding.decoder.decode([ABRender].self, from: data) { many.forEach { manifest.upsert($0) } } else { manifest.upsert(try ABCoding.decoder.decode(ABRender.self, from: data)) }
        }
        try manifest.save(url)
        print("\(url.path): \(manifest.renders.count) renders, variants \(manifest.variants.joined(separator: ", "))")
    }

    static func check(_ o: ABOptions) throws {
        let manifest = try ABManifest.load(o.manifest)
        print("\(manifest.name): \(manifest.renders.count) renders, variants \(manifest.variants.joined(separator: ", "))")
        for r in manifest.renders.sorted(by: { ($0.pair, $0.variant) < ($1.pair, $1.variant) }) {
            let url = ABManifest.audioURL(r, manifest: o.manifest)
            guard let d = try? ABAudio.duration(url) else { print("  MISSING \(r.id) \(url.path)"); continue }
            let w = ABTrials.window(r, pad: o.pad, duration: d)
            let l = (try? ABAudio.loudness(url, window: w)) ?? .nan
            print(String(format: "  %@ %@ %@ clip %.0f s, %.1f LUFS, %d plans", r.pair, r.kind.rawValue, r.variant, w.end - w.start, l, r.plans.count))
        }
    }
}

enum ABLaunch {
    nonisolated(unsafe) static var options: ABOptions!
}

final class ABAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ABWindowApp: App {
    @NSApplicationDelegateAdaptor(ABAppDelegate.self) var delegate
    @State private var model = ABModel(options: ABLaunch.options)

    var body: some Scene {
        Window("Auto Mix A/B", id: "ab") {
            ABView(model: model)
                .frame(minWidth: 560, minHeight: 640)
                .task { await model.start() }
        }
        .windowResizability(.contentMinSize)
    }
}

// MARK: - Model

@MainActor
@Observable
final class ABModel {
    enum Phase: Equatable { case loading, rating, done, failed(String) }
    enum Side: String { case a = "A", b = "B" }

    let options: ABOptions
    private(set) var phase = Phase.loading
    private(set) var trials: [ABTrial] = []
    private(set) var index = 0
    private(set) var side = Side.a
    private(set) var isPlaying = false
    var position = 0.0
    var preference: ABPreference?
    var aFaults = Set<ABFault>()
    var bFaults = Set<ABFault>()
    var note = ""
    private(set) var resultsURL: URL?
    private(set) var session: ABSession?

    @ObservationIgnored private var players: [Side: AVAudioPlayer] = [:]
    @ObservationIgnored private var loudness: [Side: Double] = [:]
    @ObservationIgnored private var listened: [Side: Double] = [.a: 0, .b: 0]
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var lastTick = Date()

    init(options: ABOptions) { self.options = options }

    var trial: ABTrial? { trials.indices.contains(index) ? trials[index] : nil }
    var length: Double {
        guard let t = trial else { return 0 }
        return max(t.aWindow.end - t.aWindow.start, t.bWindow.end - t.bWindow.start)
    }

    func start() async {
        guard phase == .loading, trials.isEmpty else { return }
        do {
            let manifest = try ABManifest.load(options.manifest)
            let variants = options.resolvedVariants(manifest)
            var rng = ABRandom(state: options.seed)
            trials = try ABTrials.build(manifest, manifestURL: options.manifest, kind: options.kind, variants: variants, pad: options.pad, rng: &rng)
            guard !trials.isEmpty else { phase = .failed("No \(options.kind == .long ? "long excerpts" : "transitions") with both \(variants.joined(separator: " and ")) renders."); return }
            let dir = options.manifest.deletingLastPathComponent().appendingPathComponent("results", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime]).replacingOccurrences(of: ":", with: "")
            resultsURL = dir.appendingPathComponent("\(stamp)-\(options.kind.rawValue).json")
            session = ABSession(manifest: options.manifest.path, manifestName: manifest.name, session: UUID(), seed: options.seed, mode: options.kind, variants: variants, padSeconds: options.pad, started: Date(), judgments: [])
            try await prepare()
            phase = .rating
        } catch {
            phase = .failed("\(error)")
        }
    }

    private func prepare() async throws {
        stop()
        guard let t = trial else { return }
        let manifest = options.manifest
        let a = try await Task.detached { try ABAudio.loudness(ABManifest.audioURL(t.a, manifest: manifest), window: t.aWindow) }.value
        let b = try await Task.detached { try ABAudio.loudness(ABManifest.audioURL(t.b, manifest: manifest), window: t.bWindow) }.value
        loudness = [.a: a, .b: b]
        let (ga, gb) = ABAudio.matchedGains(a, b)
        let pa = try AVAudioPlayer(contentsOf: ABManifest.audioURL(t.a, manifest: manifest))
        let pb = try AVAudioPlayer(contentsOf: ABManifest.audioURL(t.b, manifest: manifest))
        pa.volume = Float(pow(10, ga / 20))
        pb.volume = Float(pow(10, gb / 20))
        pa.prepareToPlay()
        pb.prepareToPlay()
        players = [.a: pa, .b: pb]
        listened = [.a: 0, .b: 0]
        position = 0
        side = .a
        preference = nil
        aFaults = []
        bFaults = []
        note = ""
    }

    private func window(_ s: Side) -> ABRegion? {
        guard let t = trial else { return nil }
        return s == .a ? t.aWindow : t.bWindow
    }

    func select(_ s: Side) {
        guard s != side || !isPlaying else { return }
        let wasPlaying = isPlaying || s != side
        players[side]?.pause()
        side = s
        if wasPlaying { play() }
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard let player = players[side], let w = window(side) else { return }
        if position >= w.end - w.start - 0.05 { position = 0 }
        player.currentTime = w.start + position
        player.play()
        isPlaying = true
        lastTick = Date()
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func pause() {
        players.values.forEach { $0.pause() }
        isPlaying = false
        ticker?.invalidate()
        ticker = nil
    }

    func seek(to seconds: Double) {
        position = max(0, min(length, seconds))
        if isPlaying { play() }
    }

    func skip(_ delta: Double) { seek(to: position + delta) }

    private func stop() {
        pause()
        players = [:]
    }

    private func tick() {
        guard let player = players[side], let w = window(side) else { return }
        let now = Date()
        listened[side, default: 0] += now.timeIntervalSince(lastTick)
        lastTick = now
        position = player.currentTime - w.start
        if player.currentTime >= w.end || !player.isPlaying {
            pause()
            position = w.end - w.start
        }
    }

    var canSubmit: Bool { preference != nil }

    func submit() async {
        guard let t = trial, let preference, var session, let resultsURL else { return }
        let la = loudness[.a] ?? .nan, lb = loudness[.b] ?? .nan
        let (ga, gb) = ABAudio.matchedGains(la, lb)
        let preferred: String? = preference == .a ? t.a.variant : preference == .b ? t.b.variant : nil
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        session.judgments.append(ABJudgment(
            trial: t.id, pair: t.pair, kind: t.kind, aRender: t.a.id, bRender: t.b.id, aVariant: t.a.variant, bVariant: t.b.variant,
            preference: preference, preferredVariant: preferred,
            aFaults: ABFault.allCases.filter(aFaults.contains), bFaults: ABFault.allCases.filter(bFaults.contains),
            note: trimmed.isEmpty ? nil : trimmed, aLoudnessLUFS: la, bLoudnessLUFS: lb, aGainDB: ga, bGainDB: gb,
            listenedA: listened[.a] ?? 0, listenedB: listened[.b] ?? 0, tracks: t.a.tracks, date: Date()
        ))
        self.session = session
        do {
            try ABCoding.encoder.encode(session).write(to: resultsURL, options: .atomic)
        } catch {
            phase = .failed("Couldn’t save results: \(error.localizedDescription)")
            return
        }
        index += 1
        if trial == nil {
            stop()
            phase = .done
            return
        }
        do { try await prepare() } catch { phase = .failed("\(error)") }
    }
}

// MARK: - Views

struct ABView: View {
    @Bindable var model: ABModel

    var body: some View {
        switch model.phase {
        case .loading:
            ProgressView("Measuring loudness")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView("Can’t Start", systemImage: "exclamationmark.triangle", description: Text(message))
        case .done:
            ContentUnavailableView {
                Label("All Rated", systemImage: "checkmark.circle")
            } description: {
                Text("\(model.session?.judgments.count ?? 0) judgments saved to \(model.resultsURL?.path ?? "")")
                    .textSelection(.enabled)
            } actions: {
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut(.defaultAction)
            }
        case .rating:
            ABTrialForm(model: model)
        }
    }
}

struct ABTrialForm: View {
    @Bindable var model: ABModel
    private let columns = [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)]

    var body: some View {
        Form {
            Section {
                HStack {
                    Button { model.select(.a) } label: { Text("A").frame(minWidth: 60) }
                        .buttonStyle(SideButtonStyle(active: model.side == .a))
                        .keyboardShortcut("a", modifiers: [])
                    Button { model.select(.b) } label: { Text("B").frame(minWidth: 60) }
                        .buttonStyle(SideButtonStyle(active: model.side == .b))
                        .keyboardShortcut("b", modifiers: [])
                    Spacer()
                    Button { model.skip(-10) } label: { Image(systemName: "gobackward.10") }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                    Button { model.toggle() } label: { Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(minWidth: 24) }
                        .keyboardShortcut(.space, modifiers: [])
                    Button { model.skip(10) } label: { Image(systemName: "goforward.10") }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                }
                Slider(value: Binding(get: { model.position }, set: { model.seek(to: $0) }), in: 0...max(1, model.length)) {
                    Text("Position")
                } minimumValueLabel: {
                    Text(Self.time(model.position)).monospacedDigit()
                } maximumValueLabel: {
                    Text(Self.time(model.length)).monospacedDigit()
                }
            } header: {
                Text("Trial \(model.index + 1) of \(model.trials.count)")
            } footer: {
                Text("A and B are matched in loudness. Switching keeps your place.")
            }

            Section("Preference") {
                Picker("Better", selection: $model.preference) {
                    Text("A").tag(ABPreference?.some(.a))
                    Text("No Preference").tag(ABPreference?.some(.neither))
                    Text("B").tag(ABPreference?.some(.b))
                }
                .pickerStyle(.segmented)
            }

            faults("Faults in A", selection: $model.aFaults)
            faults("Faults in B", selection: $model.bFaults)

            Section("Note") {
                TextField("Optional", text: $model.note, axis: .vertical)
                    .lineLimit(1...3)
            }

            Section {
                HStack {
                    Spacer()
                    Button(model.index + 1 == model.trials.count ? "Finish" : "Next") { Task { await model.submit() } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(!model.canSubmit)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func faults(_ title: String, selection: Binding<Set<ABFault>>) -> some View {
        Section(title) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(ABFault.allCases, id: \.self) { fault in
                    Toggle(fault.label, isOn: Binding(
                        get: { selection.wrappedValue.contains(fault) },
                        set: { on in if on { selection.wrappedValue.insert(fault) } else { selection.wrappedValue.remove(fault) } }
                    ))
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    static func time(_ s: Double) -> String {
        let t = Int(max(0, s).rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

struct SideButtonStyle: PrimitiveButtonStyle {
    var active: Bool
    func makeBody(configuration: Configuration) -> some View {
        if active {
            Button(role: nil, action: configuration.trigger) { configuration.label }.buttonStyle(.borderedProminent)
        } else {
            Button(role: nil, action: configuration.trigger) { configuration.label }.buttonStyle(.bordered)
        }
    }
}
