import ActivityKit
import Combine
import CoreGraphics
import SwiftUI
import UIKit

@MainActor
final class NowPlayingLiveActivityController {
    static let shared = NowPlayingLiveActivityController()

    typealias Attributes = NowPlayingActivityAttributes
    typealias State = NowPlayingActivityAttributes.ContentState

    private static let debounce: RunLoop.SchedulerTimeType.Stride = .milliseconds(400)
    private static let minimumPushGap: TimeInterval = 3
    private static let pausedLifetime: TimeInterval = 300
    private static let mixTolerance: TimeInterval = 6
    private static let driftTolerance: TimeInterval = 3

    private var coordinator: PhonePlaybackCoordinator?
    private var cancellables = Set<AnyCancellable>()
    private var activity: Activity<Attributes>?
    private var pushed: State?
    private var lastPushAt: Date?
    private var pausedSince: Date?
    private var reconcileTask: Task<Void, Never>?
    private var deferredTask: Task<Void, Never>?
    private var entryTask: Task<Void, Never>?
    private var pausedEndTask: Task<Void, Never>?
    private var artwork: ArtworkResult?

    private struct ArtworkResult {
        var key: String
        var file: String
        var tint: [Double]
    }

    private init() {}

    // MARK: - Lifecycle

    func start(coordinator: PhonePlaybackCoordinator) {
        guard self.coordinator !== coordinator else { return }
        self.coordinator = coordinator
        cancellables.removeAll()

        PlaybackControlBridge.outputOverride = PlaybackControlBridge.OutputOverride(
            isActive: { !coordinator.currentOutput.isLocal },
            setPlaying: { playing in playing ? coordinator.play() : coordinator.pause() },
            next: { coordinator.next() },
            mixNow: { coordinator.mixNow() }
        )

        #if DEBUG
        if let fixture = ProcessInfo.processInfo.environment["SOUNDING_TV_LIVE_ACTIVITY"], !fixture.isEmpty {
            Task { await runFixture(fixture) }
            return
        }
        #endif

        activity = Activity<Attributes>.activities.first
        pushed = activity?.content.state

        let triggers: [AnyPublisher<Void, Never>] = [
            coordinator.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            PlayerService.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            SettingsStore.shared.$liveActivitiesEnabled.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification).map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(triggers)
            .debounce(for: Self.debounce, scheduler: RunLoop.main)
            .sink { [weak self] in self?.scheduleReconcile() }
            .store(in: &cancellables)

        scheduleReconcile()
    }

    private func scheduleReconcile() {
        reconcileTask?.cancel()
        reconcileTask = Task { [weak self] in await self?.reconcile() }
    }

    // MARK: - Reconcile

    private func reconcile() async {
        guard let coordinator else { return }

        guard SettingsStore.shared.liveActivitiesEnabled,
              ActivityAuthorizationInfo().areActivitiesEnabled,
              let snapshot = coordinator.nowPlaying,
              let trackID = snapshot.trackId else {
            await endActivity()
            return
        }

        let playing = snapshot.showsPauseGlyph
        let now = Date.now
        let position = snapshot.estimatedPosition(at: now)
        let dj = coordinator.djSnapshot
        let inMix = playing ? Self.inMix(trackID: trackID, position: position) : nil
        let sleepEndsAt = playing ? coordinator.sleepTimer?.endsAt.flatMap { $0 > now ? $0 : nil } : nil

        var next: String?
        var mixDate: Date?
        var move: String?
        if dj.isAutoEnabled, let title = dj.nextTitle {
            next = title
            move = coordinator.nextMoveLine
            if let seconds = dj.mixInSeconds, seconds > 1 { mixDate = now.addingTimeInterval(seconds) }
        }

        guard next != nil || inMix != nil || sleepEndsAt != nil else {
            await endActivity()
            return
        }

        if playing {
            pausedSince = nil
            pausedEndTask?.cancel()
            pausedEndTask = nil
        } else {
            if pausedSince == nil { pausedSince = .now }
            if let since = pausedSince, Date.now.timeIntervalSince(since) >= Self.pausedLifetime {
                await endActivity()
                return
            }
            schedulePausedEnd()
            if activity == nil { return }
        }

        guard let art = await resolveArtwork(urlString: snapshot.artworkURL, trackID: trackID),
              !Task.isCancelled else { return }

        let output = coordinator.currentOutput

        let state = State(
            trackID: trackID,
            title: snapshot.displayTitle,
            artist: snapshot.displayArtist,
            artworkFile: art.file,
            tint: art.tint,
            isPlaying: playing,
            position: position,
            positionDate: now,
            duration: snapshot.duration,
            outputName: output.isLocal ? nil : output.name,
            nextTitle: next,
            mixDate: mixDate,
            moveLine: move,
            inMixTitle: inMix?.title,
            inMixArtist: inMix?.artist,
            inMixPosition: inMix?.position,
            pausedAt: playing ? nil : pausedSince,
            sleepEndsAt: sleepEndsAt
        )

        scheduleEntryRefresh(trackID: trackID, position: position, playing: playing)
        await push(state)
    }

    private func push(_ state: State) async {
        if let pushed, activity != nil, !Self.isMeaningful(from: pushed, to: state) { return }

        if let last = lastPushAt {
            let wait = Self.minimumPushGap - Date.now.timeIntervalSince(last)
            if wait > 0 {
                deferredTask?.cancel()
                deferredTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(wait))
                    guard !Task.isCancelled else { return }
                    self?.scheduleReconcile()
                }
                return
            }
        }

        await send(state)
    }

    private func send(_ state: State) async {
        let content = ActivityContent(state: state, staleDate: Self.staleDate(for: state))
        if let id = activity?.id {
            await Self.update(id: id, content: content)
        } else {
            do {
                activity = try Activity<Attributes>.request(
                    attributes: Attributes(sessionID: UUID().uuidString),
                    content: content,
                    pushType: nil
                )
            } catch {
                #if DEBUG
                NSLog("LiveActivity request failed: \(error)")
                #endif
                return
            }
        }
        pushed = state
        lastPushAt = .now
    }

    private func endActivity() async {
        entryTask?.cancel()
        pausedEndTask?.cancel()
        deferredTask?.cancel()
        pausedSince = nil
        let hadActivity = activity != nil || !Activity<Attributes>.activities.isEmpty
        activity = nil
        pushed = nil
        lastPushAt = nil
        guard hadActivity else { return }
        await Self.endAll()
        LiveActivityArtworkStore.prune(keeping: [])
        artwork = nil
    }

    private nonisolated static func update(id: String, content: ActivityContent<State>, alert: AlertConfiguration? = nil) async {
        guard let target = Activity<Attributes>.activities.first(where: { $0.id == id }) else { return }
        if let alert {
            await target.update(content, alertConfiguration: alert)
        } else {
            await target.update(content)
        }
    }

    nonisolated static func endAll() async {
        for existing in Activity<Attributes>.activities {
            await existing.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func schedulePausedEnd() {
        guard pausedEndTask == nil, activity != nil, let since = pausedSince else { return }
        let wait = max(1, since.addingTimeInterval(Self.pausedLifetime).timeIntervalSinceNow)
        pausedEndTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.pausedEndTask = nil
            self?.scheduleReconcile()
        }
    }

    private func scheduleEntryRefresh(trackID: String, position: TimeInterval, playing: Bool) {
        entryTask?.cancel()
        entryTask = nil
        guard playing,
              let list = SetlistIntelligenceStore.shared.tracklist(for: trackID),
              let entry = list.currentEntry(at: position) else { return }
        let wait = min(1800, max(1, entry.endSeconds - position + 0.3))
        entryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.scheduleReconcile()
        }
    }

    // MARK: - Rules

    static func isMeaningful(from old: State, to new: State) -> Bool {
        if old.trackID != new.trackID || old.isPlaying != new.isPlaying { return true }
        if old.outputName != new.outputName || old.nextTitle != new.nextTitle { return true }
        if old.moveLine != new.moveLine || old.artworkFile != new.artworkFile { return true }
        if old.inMixTitle != new.inMixTitle || old.inMixArtist != new.inMixArtist || old.inMixPosition != new.inMixPosition { return true }
        switch (old.sleepEndsAt, new.sleepEndsAt) {
        case (nil, nil): break
        case let (a?, b?): if abs(a.timeIntervalSince(b)) > driftTolerance { return true }
        default: return true
        }
        switch (old.mixDate, new.mixDate) {
        case (nil, nil): break
        case let (a?, b?): if abs(a.timeIntervalSince(b)) > mixTolerance { return true }
        default: return true
        }
        if new.isPlaying {
            let predicted = old.position + new.positionDate.timeIntervalSince(old.positionDate)
            if abs(predicted - new.position) > driftTolerance { return true }
        } else if abs(old.position - new.position) > driftTolerance {
            return true
        }
        return false
    }

    static func staleDate(for state: State) -> Date? {
        if state.isPlaying {
            guard state.duration > 0 else { return nil }
            return state.startDate.addingTimeInterval(state.duration + 60)
        }
        return (state.pausedAt ?? .now).addingTimeInterval(pausedLifetime)
    }

    private static func inMix(trackID: String, position: TimeInterval) -> (title: String, artist: String?, position: String)? {
        guard let list = SetlistIntelligenceStore.shared.tracklist(for: trackID),
              let index = list.currentIndex(at: position) else { return nil }
        let entry = list.entries[index]
        guard !NowPlayingSegmentText.isUnknown(entry.segment) else { return nil }
        let parts = NowPlayingSegmentText.parts(entry.segment)
        return (parts.title, parts.artist, "\(index + 1) of \(list.entries.count)")
    }

    // MARK: - Artwork

    private func resolveArtwork(urlString: String?, trackID: String) async -> ArtworkResult? {
        let key = urlString ?? "placeholder.\(trackID)"
        if let artwork, artwork.key == key { return artwork }

        var image: CGImage?
        if let urlString, let url = URL(string: urlString) {
            image = await SCArtworkStore.shared.cgImage(for: url, variant: .thumbnail)
        }
        if Task.isCancelled { return nil }
        guard let source = image ?? Self.placeholder(seed: Self.seed(for: trackID)),
              let data = Self.jpeg(from: source) else { return nil }

        let file = "art-\(SCArtworkStore.digest(of: key).prefix(16)).jpg"
        guard LiveActivityArtworkStore.write(data, named: file) else { return nil }
        var keep: Set<String> = [file]
        if let previous = artwork?.file { keep.insert(previous) }
        if let shown = pushed?.artworkFile { keep.insert(shown) }
        LiveActivityArtworkStore.prune(keeping: keep)

        let result = ArtworkResult(key: key, file: file, tint: Self.tint(of: source))
        artwork = result
        return result
    }

    static func seed(for id: String) -> UInt64 {
        id.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }

    static func placeholder(seed: UInt64) -> CGImage? {
        let side = CGFloat(LiveActivityArtworkStore.pixelSize)
        let renderer = ImageRenderer(content: LiveActivityPlaceholderArt(seed: seed).frame(width: side, height: side))
        renderer.scale = 1
        return renderer.cgImage
    }

    static func jpeg(from image: CGImage) -> Data? {
        let side = CGFloat(LiveActivityArtworkStore.pixelSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: side, height: side)
        let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let source = CGSize(width: image.width, height: image.height)
            let factor = max(side / source.width, side / source.height)
            let drawn = CGSize(width: source.width * factor, height: source.height * factor)
            UIImage(cgImage: image).draw(in: CGRect(
                x: (side - drawn.width) / 2,
                y: (side - drawn.height) / 2,
                width: drawn.width,
                height: drawn.height
            ))
        }
        return scaled.jpegData(compressionQuality: 0.82)
    }

    static func tint(of image: CGImage) -> [Double] {
        let side = 12
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return [0.9, 0.9, 0.9] }

        var best: (score: CGFloat, hue: CGFloat, saturation: CGFloat)?
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let color = UIColor(
                red: CGFloat(pixels[index]) / 255,
                green: CGFloat(pixels[index + 1]) / 255,
                blue: CGFloat(pixels[index + 2]) / 255,
                alpha: 1
            )
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
            color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
            let score = saturation * (0.3 + brightness)
            if best == nil || score > best!.score { best = (score, hue, saturation) }
        }
        guard let best, best.saturation > 0.12 else { return [0.9, 0.9, 0.9] }
        let vivid = UIColor(hue: best.hue, saturation: min(1, max(best.saturation, 0.5)), brightness: 0.95, alpha: 1)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        vivid.getRed(&red, green: &green, blue: &blue, alpha: nil)
        return [Double(red), Double(green), Double(blue)]
    }
}

private struct LiveActivityPlaceholderArt: View {
    let seed: UInt64

    var body: some View {
        Canvas(opaque: true) { context, size in
            let scene = SoundingLineArtComposition(seed: seed, size: size, style: .ambient)
            let moment = SoundingLineArtMoment(
                time: SoundingLineArtComposition.introDuration(for: .ambient),
                idle: 0,
                drifts: false
            )
            let palette = SoundingArtPalette.dark
            scene.draw(in: &context, moment: moment, palette: palette, layer: .back)
            scene.draw(in: &context, moment: moment, palette: palette, layer: .front)
        }
    }
}

#if DEBUG
extension NowPlayingLiveActivityController {
    func runFixture(_ kind: String) async {
        await Self.endAll()
        activity = nil
        pushed = nil

        let now = Date.now
        let trackID: String
        let title: String
        let artist: String
        let duration: TimeInterval
        let position: TimeInterval
        switch kind {
        case "set":
            trackID = "fixture.set"
            title = "Summer Night DJ Set"
            artist = "Night Tapes"
            duration = 8040
            position = 3412
        case "sleep":
            trackID = "fixture.sleep"
            title = "Late Night Drive"
            artist = "Maya Sol"
            duration = 241
            position = 72
        default:
            trackID = "fixture.automix"
            title = "Wavelength"
            artist = "Night Tapes"
            duration = 214
            position = 150
        }

        let source = Self.placeholder(seed: Self.seed(for: trackID))
        let data = source.flatMap { Self.jpeg(from: $0) }
        let file = "art-fixture-\(kind).jpg"
        if let data { LiveActivityArtworkStore.write(data, named: file) }

        let state = State(
            trackID: trackID,
            title: title,
            artist: artist,
            artworkFile: data == nil ? nil : file,
            tint: source.map { Self.tint(of: $0) },
            isPlaying: true,
            position: position,
            positionDate: now,
            duration: duration,
            outputName: kind == "set" ? "Living Room" : nil,
            nextTitle: kind == "set" || kind == "sleep" ? nil : "Late Night Drive",
            mixDate: kind == "set" || kind == "sleep" ? nil : now.addingTimeInterval(48),
            moveLine: kind == "set" || kind == "sleep" ? nil : "Loop build into Glue, 16 bars",
            inMixTitle: kind == "set" ? "Neon Weather" : nil,
            inMixArtist: kind == "set" ? "Maya Sol" : nil,
            inMixPosition: kind == "set" ? "7 of 24" : nil,
            pausedAt: nil,
            sleepEndsAt: kind == "sleep" ? now.addingTimeInterval(24 * 60 + 10) : nil
        )
        await send(state)

        if let delay = ProcessInfo.processInfo.environment["SOUNDING_TV_LIVE_ACTIVITY_EXPAND"].flatMap(Double.init), let id = activity?.id {
            let task = UIApplication.shared.beginBackgroundTask()
            try? await Task.sleep(for: .seconds(delay))
            let alert = AlertConfiguration(title: "Sounding", body: LocalizedStringResource(stringLiteral: state.title), sound: .default)
            await Self.update(id: id, content: ActivityContent(state: state, staleDate: Self.staleDate(for: state)), alert: alert)
            try? await Task.sleep(for: .seconds(25))
            UIApplication.shared.endBackgroundTask(task)
        }
    }
}
#endif
