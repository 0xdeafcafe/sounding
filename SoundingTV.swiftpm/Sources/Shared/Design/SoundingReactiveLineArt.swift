import QuartzCore
import SwiftUI

struct SoundingLineArtPlayhead: Equatable, Sendable {
    var position: TimeInterval
    var date: Date
    var rate: Double
    var duration: TimeInterval

    static let still = SoundingLineArtPlayhead(position: 0, date: .distantPast, rate: 0, duration: 0)

    var isAdvancing: Bool { rate > 0 }

    func position(at date: Date) -> TimeInterval {
        let raw = max(0, position + rate * max(0, date.timeIntervalSince(self.date)))
        return duration > 0 ? min(duration, raw) : raw
    }
}

struct SoundingMusicEnvelope: Sendable {
    struct Key: Hashable, Sendable {
        var trackID: String?
        var count: Int
        var duration: Int
    }

    struct Onset: Sendable {
        var time: TimeInterval
        var strength: Double
    }

    let key: Key?
    let rate: Double
    let level: [Float]
    let onsets: [Onset]

    static let silent = SoundingMusicEnvelope(key: nil, rate: 1, level: [], onsets: [])

    private init(key: Key?, rate: Double, level: [Float], onsets: [Onset]) {
        self.key = key
        self.rate = rate
        self.level = level
        self.onsets = onsets
    }

    var isEmpty: Bool { level.isEmpty }

    init(key: Key, samples: [Float], duration: TimeInterval) {
        guard samples.count >= 8, duration > 1 else {
            self.init(key: key, rate: 1, level: [], onsets: [])
            return
        }
        let sorted = samples.sorted()
        let floor = sorted[Int(Double(sorted.count - 1) * 0.06)]
        let ceiling = sorted[Int(Double(sorted.count - 1) * 0.96)]
        let span = max(ceiling - floor, 0.04)
        let rate = min(16, max(2, 48_000 / duration))
        let count = Int(duration * rate) + 2
        let perSecond = Double(samples.count) / duration
        let dt = 1 / rate

        var input = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let x = Double(index) * dt * perSecond - 0.5
            let lower = min(samples.count - 1, max(0, Int(x.rounded(.down))))
            let upper = min(samples.count - 1, lower + 1)
            let f = Float(min(1, max(0, x - Double(lower))))
            let raw = samples[lower] * (1 - f) + samples[upper] * f
            input[index] = min(1, max(0, (raw - floor) / span))
        }

        func follower(attack: Double, release: Double) -> [Float] {
            let up = Float(1 - exp(-dt / attack))
            let down = Float(1 - exp(-dt / release))
            var output = [Float](repeating: 0, count: count)
            var value = input[0]
            for index in 0..<count {
                let target = input[index]
                value += (target > value ? up : down) * (target - value)
                output[index] = value
            }
            return output
        }

        let level = follower(attack: 0.18, release: 0.9)
        let fast = follower(attack: 0.05, release: 0.35)
        let slow = follower(attack: 2.4, release: 2.4)

        var novelty = [Float](repeating: 0, count: count)
        for index in 0..<count {
            novelty[index] = max(0, fast[index] - slow[index])
        }

        let radius = max(1, Int(0.7 * rate))
        var candidates: [(index: Int, value: Float)] = []
        for index in 0..<count where novelty[index] > 0.035 {
            let lo = max(0, index - radius)
            let hi = min(count - 1, index + radius)
            var isPeak = true
            for other in lo...hi where other != index {
                if novelty[other] > novelty[index] || (novelty[other] == novelty[index] && other < index) {
                    isPeak = false
                    break
                }
            }
            if isPeak { candidates.append((index, novelty[index])) }
        }
        candidates.sort { $0.value > $1.value }
        let budget = max(1, Int(duration / 3.2))
        let spacing = 1.4
        var kept: [(time: TimeInterval, value: Float)] = []
        for candidate in candidates where kept.count < budget {
            let time = Double(candidate.index) * dt
            if kept.allSatisfy({ abs($0.time - time) >= spacing }) {
                kept.append((time, candidate.value))
            }
        }
        let loudest = Double(kept.first?.value ?? 1)
        let onsets = kept
            .map { Onset(time: $0.time, strength: 0.45 + 0.55 * min(1, Double($0.value) / max(0.001, loudest * 0.7))) }
            .sorted { $0.time < $1.time }

        self.init(key: key, rate: rate, level: level, onsets: onsets)
    }

    func level(at time: TimeInterval) -> Double {
        guard !level.isEmpty else { return 0 }
        let x = max(0, time * rate)
        let index = Int(x)
        guard index + 1 < level.count else { return Double(level[level.count - 1]) }
        let f = Float(x - Double(index))
        return Double(level[index] * (1 - f) + level[index + 1] * f)
    }

    func firstOnset(after time: TimeInterval) -> Int {
        var lo = 0
        var hi = onsets.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if onsets[mid].time < time { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

struct SoundingReactiveLineArt: View {
    var trackID: String?
    var samples: [Float]
    var duration: TimeInterval
    var playhead: SoundingLineArtPlayhead
    var scrub: TimeInterval?
    var tint: Color
    var intensity: Double = 1
    var bandPosition: CGFloat = 0.075
    var tipAnchor: UnitPoint?
    var wideTipAnchor: UnitPoint?
    var isActive = true

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.soundingReducedResourceUsage) private var reducedResourceUsage

    @State private var envelope = SoundingMusicEnvelope.silent
    @State private var isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var isOnScreen = false

    private var key: SoundingMusicEnvelope.Key {
        SoundingMusicEnvelope.Key(trackID: trackID, count: samples.count, duration: Int(duration))
    }

    private var seed: UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in (trackID ?? "sounding").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

    private var isRunning: Bool {
        #if os(macOS)
        let sceneActive = true
        #else
        let sceneActive = scenePhase == .active
        #endif
        return isActive && isOnScreen && sceneActive && !isLowPower && !reducedResourceUsage
    }

    var body: some View {
        ZStack {
            SoundingLineArtStageView(
                input: SoundingLineArtStage.Input(
                    seed: seed,
                    envelope: envelope.key == key ? envelope : .silent,
                    playhead: playhead,
                    scrub: scrub,
                    opacity: intensity * (contrast == .increased ? 0.55 : 1),
                    bandPosition: bandPosition,
                    tipAnchor: tipAnchor,
                    wideTipAnchor: wideTipAnchor,
                    isStatic: reduceMotion,
                    isRunning: isRunning
                ),
                tint: tint
            )
            .id(seed)
            .transition(.opacity)
        }
        .animation(.easeInOut(duration: reduceMotion ? 0.3 : 1.2), value: seed)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
        .task(id: key) {
            let key = key
            let samples = samples
            let duration = duration
            let built = await Task.detached(priority: .utility) {
                SoundingMusicEnvelope(key: key, samples: samples, duration: duration)
            }.value
            guard !Task.isCancelled else { return }
            envelope = built
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange).receive(on: RunLoop.main)) { _ in
            isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }
}

private struct SoundingLineArtColours {
    var inks: [CGColor]
    var signal: CGColor

    init(tint: Color, environment: EnvironmentValues) {
        inks = SoundingArtPalette.dark.inks.map { $0.mix(with: tint, by: 0.55).resolve(in: environment).cgColor }
        signal = SoundingArtPalette.dark.signal.mix(with: tint, by: 0.3).resolve(in: environment).cgColor
    }
}

#if os(macOS)
private struct SoundingLineArtStageView: NSViewRepresentable {
    let input: SoundingLineArtStage.Input
    let tint: Color

    func makeNSView(context: Context) -> SoundingLineArtHostView {
        SoundingLineArtHostView()
    }

    func updateNSView(_ view: SoundingLineArtHostView, context: Context) {
        view.stage.update(input, colours: SoundingLineArtColours(tint: tint, environment: context.environment))
    }

    static func dismantleNSView(_ view: SoundingLineArtHostView, coordinator: ()) {
        view.stage.stop()
    }
}

private final class SoundingLineArtHostView: NSView {
    let stage = SoundingLineArtStage()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        stage.root.isGeometryFlipped = true
        layer?.addSublayer(stage.root)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        stage.resize(bounds.size, scale: window?.backingScaleFactor ?? 2)
    }
}
#else
private struct SoundingLineArtStageView: UIViewRepresentable {
    let input: SoundingLineArtStage.Input
    let tint: Color

    func makeUIView(context: Context) -> SoundingLineArtHostView {
        SoundingLineArtHostView()
    }

    func updateUIView(_ view: SoundingLineArtHostView, context: Context) {
        view.stage.update(input, colours: SoundingLineArtColours(tint: tint, environment: context.environment))
    }

    static func dismantleUIView(_ view: SoundingLineArtHostView, coordinator: ()) {
        view.stage.stop()
    }
}

private final class SoundingLineArtHostView: UIView {
    let stage = SoundingLineArtStage()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.addSublayer(stage.root)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        stage.resize(bounds.size, scale: traitCollection.displayScale)
    }
}
#endif

@MainActor
private final class SoundingLineArtStage {
    struct Input {
        var seed: UInt64
        var envelope: SoundingMusicEnvelope
        var playhead: SoundingLineArtPlayhead
        var scrub: TimeInterval?
        var opacity: Double
        var bandPosition: CGFloat
        var tipAnchor: UnitPoint?
        var wideTipAnchor: UnitPoint?
        var isStatic: Bool
        var isRunning: Bool
    }

    private struct Item {
        var layer: CAShapeLayer
        var highlight: CAShapeLayer?
        var kind: SoundingLineArtGeometry.Kind
        var pivot: CGPoint
    }

    private struct Schedule {
        var seed: UInt64
        var key: SoundingMusicEnvelope.Key?
        var playhead: SoundingLineArtPlayhead
        var size: CGSize
    }

    let root = CALayer()
    private let back = CALayer()
    private let front = CALayer()
    private let bandHolder = CALayer()
    private let tape = CALayer()
    private var bandLines: [CAShapeLayer] = []
    private var items: [Item] = []
    private var geometry: SoundingLineArtGeometry?
    private var size: CGSize = .zero
    private var scale: CGFloat = 2
    private var input: Input?
    private var colours: SoundingLineArtColours?
    private var schedule: Schedule?
    private var tapeRange: ClosedRange<CGFloat>?
    private var tapeIsLive = false
    private var refreshTask: Task<Void, Never>?

    private static let horizon: TimeInterval = 8
    private static let refreshAfter: TimeInterval = 6
    private static let frameRate: Double = 20
    private static let keyframeRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 20)
    private static let tapeFrameRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
    private static let animationKeys = ["opacity", "transform"]

    init() {
        root.actions = Self.noActions
        for layer in [back, front, bandHolder, tape] {
            layer.actions = Self.noActions
        }
        root.addSublayer(bandHolder)
        bandHolder.addSublayer(tape)
        root.addSublayer(back)
        root.addSublayer(front)
    }

    private static let noActions: [String: any CAAction] = [
        "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "opacity": NSNull(), "transform": NSNull(),
        "path": NSNull(), "strokeColor": NSNull(), "lineWidth": NSNull(), "contents": NSNull(), "sublayers": NSNull(),
        "mask": NSNull(), "hidden": NSNull(),
    ]

    func resize(_ size: CGSize, scale: CGFloat) {
        guard size != self.size || scale != self.scale else { return }
        self.size = size
        self.scale = scale
        rebuild()
    }

    func update(_ input: Input, colours: SoundingLineArtColours) {
        let previous = self.input
        self.input = input
        let geometryChanged = previous?.seed != input.seed
            || previous?.bandPosition != input.bandPosition
            || previous?.tipAnchor != input.tipAnchor
            || previous?.wideTipAnchor != input.wideTipAnchor
        let coloursChanged = self.colours?.inks != colours.inks || self.colours?.signal != colours.signal
        self.colours = colours
        if geometryChanged {
            rebuild()
        } else {
            if coloursChanged { restyle() }
            refresh(force: previous?.envelope.key != input.envelope.key || previous?.isStatic != input.isStatic)
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func rebuild() {
        guard let input, size.width > 1, size.height > 1 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = CGRect(origin: .zero, size: size)
        for layer in [back, front, bandHolder] {
            layer.frame = root.bounds
            layer.sublayers?.forEach { if $0 !== tape { $0.removeFromSuperlayer() } }
        }
        tape.sublayers?.forEach { $0.removeFromSuperlayer() }
        let anchor = size.width > size.height ? input.wideTipAnchor : input.tipAnchor
        let geometry = SoundingLineArtGeometry(seed: input.seed, size: size, bandPosition: input.bandPosition, tipAnchor: anchor)
        self.geometry = geometry
        items = geometry.strokes.map { stroke in
            let layer = makeShape(stroke.path, width: stroke.width)
            var highlight: CAShapeLayer?
            if case .ring = stroke.kind {
                highlight = makeShape(stroke.path, width: stroke.width * 1.7)
            }
            let container = stroke.isBack ? back : front
            container.addSublayer(layer)
            if let highlight { container.addSublayer(highlight) }
            let pivot: CGPoint
            switch stroke.kind {
            case .cone: pivot = stroke.centre
            case .contour: pivot = geometry.plugCentre
            case .ring: pivot = geometry.tip
            case .still: pivot = stroke.centre
            }
            return Item(layer: layer, highlight: highlight, kind: stroke.kind, pivot: pivot)
        }
        let mask = CAShapeLayer()
        mask.actions = Self.noActions
        let cutout = CGMutablePath()
        cutout.addRect(root.bounds.insetBy(dx: -size.width, dy: -size.height))
        cutout.addPath(geometry.plug)
        mask.path = cutout
        mask.fillRule = .evenOdd
        mask.frame = root.bounds
        back.mask = mask
        bandLines = (0..<SoundingLineArtGeometry.bandLines).map { _ in
            let layer = makeShape(nil, width: geometry.bandWidth)
            tape.addSublayer(layer)
            return layer
        }
        tapeRange = nil
        schedule = nil
        CATransaction.commit()
        restyle()
        refresh(force: true)
    }

    private func makeShape(_ path: CGPath?, width: CGFloat) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.actions = Self.noActions
        layer.frame = root.bounds
        layer.path = path
        layer.fillColor = nil
        layer.lineWidth = width
        layer.lineCap = .round
        layer.lineJoin = .round
        layer.contentsScale = scale
        return layer
    }

    private func restyle() {
        guard let colours, let geometry, !colours.inks.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, item) in items.enumerated() {
            item.layer.strokeColor = colours.inks[geometry.strokes[index].tone % colours.inks.count]
            item.highlight?.strokeColor = colours.signal
        }
        for (line, layer) in bandLines.enumerated() {
            layer.strokeColor = colours.inks[(geometry.bandTone + line) % colours.inks.count]
            layer.opacity = Float(0.7 - 0.08 * Double(line))
        }
        CATransaction.commit()
    }

    private func refresh(force: Bool) {
        guard let input, let geometry else { return }
        root.opacity = Float(input.opacity)
        let now = Date()
        let live = !input.isStatic && !input.envelope.isEmpty
        let animating = live && input.isRunning && input.playhead.isAdvancing && input.scrub == nil
        let position = input.scrub ?? input.playhead.position(at: now)
        guard animating else {
            stop()
            schedule = nil
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            removeAnimations()
            let frame = geometry.frame(at: position, envelope: input.envelope, live: live)
            apply(frame)
            placeTape(at: live ? position : 0, through: live ? position : 0, live: live)
            CATransaction.commit()
            return
        }
        if !force, let schedule, schedule.seed == input.seed, schedule.key == input.envelope.key, schedule.size == size,
           schedule.playhead.rate == input.playhead.rate,
           abs(schedule.playhead.position(at: now) - position) < 0.2 {
            return
        }
        animate(from: now, position: position, input: input, geometry: geometry)
    }

    private func animate(from date: Date, position: TimeInterval, input: Input, geometry: SoundingLineArtGeometry) {
        let count = Int(Self.horizon * Self.frameRate) + 1
        let rate = input.playhead.rate
        let end = input.playhead.duration > 0 ? input.playhead.duration : .infinity
        let positions = (0..<count).map { min(end, position + Double($0) / Self.frameRate * rate) }
        let frames = positions.map { geometry.frame(at: $0, envelope: input.envelope, live: true) }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let begin = root.convertTime(CACurrentMediaTime(), from: nil)
        for (index, item) in items.enumerated() {
            switch item.kind {
            case .still:
                break
            case .ring:
                if let highlight = item.highlight {
                    add(frames.map { $0.highlights[index] }, keyPath: "opacity", to: highlight, begin: begin)
                }
                add(frames.map { NSValue(caTransform3D: transform(frames: $0, index: index, pivot: item.pivot)) }, keyPath: "transform", to: item.layer, begin: begin)
                if let highlight = item.highlight {
                    add(frames.map { NSValue(caTransform3D: transform(frames: $0, index: index, pivot: item.pivot)) }, keyPath: "transform", to: highlight, begin: begin)
                }
                add(frames.map { $0.opacities[index] }, keyPath: "opacity", to: item.layer, begin: begin)
            case .cone, .contour:
                add(frames.map { $0.opacities[index] }, keyPath: "opacity", to: item.layer, begin: begin)
                add(frames.map { NSValue(caTransform3D: transform(frames: $0, index: index, pivot: item.pivot)) }, keyPath: "transform", to: item.layer, begin: begin)
            }
        }
        placeTape(at: position, through: positions[count - 1], live: true)
        let speed = geometry.bandSpeed
        let animation = CABasicAnimation(keyPath: "transform")
        let origin = tapeRange?.lowerBound ?? 0
        animation.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(origin - CGFloat(position) * speed, 0, 0))
        animation.toValue = NSValue(caTransform3D: CATransform3DMakeTranslation(origin - CGFloat(positions[count - 1]) * speed, 0, 0))
        animation.duration = Self.horizon
        animation.beginTime = begin
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        animation.preferredFrameRateRange = Self.tapeFrameRange
        tape.transform = CATransform3DMakeTranslation(origin - CGFloat(positions[count - 1]) * speed, 0, 0)
        tape.add(animation, forKey: "transform")
        CATransaction.commit()

        schedule = Schedule(seed: input.seed, key: input.envelope.key, playhead: input.playhead, size: size)
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.refreshAfter))
            guard !Task.isCancelled else { return }
            self?.refresh(force: true)
        }
    }

    private func add<Value>(_ values: [Value], keyPath: String, to layer: CALayer, begin: CFTimeInterval) {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.duration = Self.horizon
        animation.beginTime = begin
        animation.calculationMode = .linear
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        animation.preferredFrameRateRange = Self.keyframeRange
        layer.add(animation, forKey: keyPath)
        if let last = values.last {
            layer.setValue(last, forKeyPath: keyPath)
        }
    }

    private func removeAnimations() {
        for item in items {
            item.layer.removeAllAnimations()
            item.highlight?.removeAllAnimations()
        }
        tape.removeAllAnimations()
    }

    private func apply(_ frame: SoundingLineArtGeometry.Frame) {
        for (index, item) in items.enumerated() {
            item.layer.opacity = Float(frame.opacities[index])
            item.highlight?.opacity = Float(frame.highlights[index])
            let transform = transform(frames: frame, index: index, pivot: item.pivot)
            item.layer.transform = transform
            item.highlight?.transform = transform
        }
    }

    private func transform(frames frame: SoundingLineArtGeometry.Frame, index: Int, pivot: CGPoint) -> CATransform3D {
        let factor = frame.scales[index]
        guard abs(factor - 1) > 0.0001 else { return CATransform3DIdentity }
        let dx = pivot.x - size.width / 2
        let dy = pivot.y - size.height / 2
        return CATransform3DTranslate(CATransform3DScale(CATransform3DMakeTranslation(dx, dy, 0), factor, factor, 1), -dx, -dy, 0)
    }

    private func placeTape(at position: TimeInterval, through last: TimeInterval, live: Bool) {
        guard let geometry, let input else { return }
        let speed = geometry.bandSpeed
        let start = CGFloat(position) * speed
        let finish = CGFloat(last) * speed
        let needed = (start - size.width * 0.1)...(finish + size.width * 1.1)
        if live != tapeIsLive || tapeRange.map({ !($0.lowerBound <= needed.lowerBound && $0.upperBound >= needed.upperBound) }) ?? true {
            let range = (start - size.width * 0.5)...(finish + size.width * 2.5)
            let paths = geometry.tape(range, envelope: input.envelope, live: live)
            let frame = CGRect(x: 0, y: 0, width: range.upperBound - range.lowerBound, height: size.height)
            tape.transform = CATransform3DIdentity
            tape.frame = frame
            for (layer, path) in zip(bandLines, paths) {
                layer.frame = frame
                layer.path = path
            }
            tapeRange = range
            tapeIsLive = live
        }
        tape.transform = CATransform3DMakeTranslation((tapeRange?.lowerBound ?? 0) - start, 0, 0)
    }
}

private struct SoundingLineArtGeometry {
    enum Kind {
        case cone(Int)
        case ring(Int)
        case contour(Int)
        case still
    }

    struct Stroke {
        var path: CGPath
        var tone: Int
        var width: CGFloat
        var kind: Kind
        var centre: CGPoint
        var isBack: Bool
    }

    struct Frame {
        var opacities: [Double]
        var highlights: [Double]
        var scales: [CGFloat]
    }

    static let bandLines = 4
    private static let window: TimeInterval = 24
    private static let rippleLife: TimeInterval = 2.6

    let size: CGSize
    private(set) var strokes: [Stroke] = []
    private(set) var plug = CGMutablePath()
    private(set) var tip: CGPoint = .zero
    private(set) var plugCentre: CGPoint = .zero
    private(set) var bandWidth: CGFloat = 1
    private(set) var bandTone = 0
    private var ringCount = 0
    private var bandTop: CGFloat = 0
    private var bandGap: CGFloat = 0
    private var bandAmplitude: CGFloat = 0
    private var bandWavelength: CGFloat = 1

    var bandSpeed: CGFloat { size.width / CGFloat(Self.window) }

    init(seed: UInt64, size: CGSize, bandPosition: CGFloat, tipAnchor: UnitPoint?) {
        self.size = size
        let composition = SoundingLineArtComposition(seed: seed, size: size, style: .ambient)
        var first: CGPoint?
        composition.plug.forEach { element in
            if first == nil, case .move(let point) = element { first = point }
        }
        let plugBounds = composition.plug.boundingRect
        let rawTip = first ?? CGPoint(x: plugBounds.midX, y: plugBounds.midY)
        let shift = tipAnchor.map { CGPoint(x: $0.x * size.width - rawTip.x, y: $0.y * size.height - rawTip.y) } ?? .zero
        let move = CGAffineTransform(translationX: shift.x, y: shift.y)
        for (index, line) in composition.lines.enumerated() {
            let isBack = index < composition.backLineCount
            let path = line.path.applying(move)
            let bounds = path.boundingRect
            let centre = CGPoint(x: bounds.midX, y: bounds.midY)
            let kind: Kind
            switch line.motion {
            case .drift:
                bandTone = line.tone
                bandWidth = line.width
                continue
            case .ring(let ring):
                ringCount = max(ringCount, ring + 1)
                kind = .ring(ring)
            case .contour(let contour):
                kind = isBack ? .cone(contour - 2) : .contour(contour)
            case .still:
                kind = .still
            }
            strokes.append(Stroke(path: path.cgPath, tone: line.tone, width: line.width, kind: kind, centre: centre, isBack: isBack))
        }
        plug.addPath(composition.plug.applying(move).cgPath)
        tip = CGPoint(x: rawTip.x + shift.x, y: rawTip.y + shift.y)
        plugCentre = CGPoint(x: plugBounds.midX + shift.x, y: plugBounds.midY + shift.y)
        let s = min(size.width, size.height)
        let l = max(size.width, size.height)
        bandTop = size.height * bandPosition
        bandGap = s * 0.016
        bandAmplitude = s * 0.026
        bandWavelength = l * 0.17
    }

    func frame(at time: TimeInterval, envelope: SoundingMusicEnvelope, live: Bool) -> Frame {
        let level = live ? envelope.level(at: time) : 0.3
        let ripples = live ? rippleField(envelope: envelope, at: time) : Array(repeating: 0, count: ringCount)
        var opacities = [Double](repeating: 1, count: strokes.count)
        var highlights = [Double](repeating: 0, count: strokes.count)
        var scales = [CGFloat](repeating: 1, count: strokes.count)
        for (index, stroke) in strokes.enumerated() {
            switch stroke.kind {
            case .still:
                opacities[index] = 0.55
            case .cone(let cone):
                scales[index] = 1 + CGFloat(0.045 * level) * (1 - CGFloat(cone) * 0.14)
                opacities[index] = 0.28 + 0.32 * level
            case .contour(let contour):
                scales[index] = 1 + CGFloat(0.006 * level) * CGFloat(contour)
                opacities[index] = min(1, (contour == 0 ? 0.85 : 0.6 - 0.05 * Double(contour)) * (0.7 + 0.5 * level))
            case .ring(let ring):
                let lift = ring < ripples.count ? ripples[ring] : 0
                scales[index] = 1 + CGFloat(0.02 * lift)
                opacities[index] = 0.3 + 0.25 * min(1, lift)
                highlights[index] = min(1, 0.75 * lift)
            }
        }
        return Frame(opacities: opacities, highlights: highlights, scales: scales)
    }

    private func rippleField(envelope: SoundingMusicEnvelope, at time: TimeInterval) -> [Double] {
        var field = [Double](repeating: 0, count: ringCount)
        guard ringCount > 0 else { return field }
        let life = Self.rippleLife
        var index = envelope.firstOnset(after: time - life)
        let reach = Double(ringCount) + 2
        while index < envelope.onsets.count, envelope.onsets[index].time <= time {
            let onset = envelope.onsets[index]
            let age = (time - onset.time) / life
            let front = age * reach - 1
            let fade = pow(1 - age, 1.4) * onset.strength
            for ring in 0..<ringCount {
                let distance = (front - Double(ring)) / 1.1
                field[ring] += fade * exp(-distance * distance)
            }
            index += 1
        }
        return field.map { min(1.2, $0) }
    }

    func tape(_ range: ClosedRange<CGFloat>, envelope: SoundingMusicEnvelope, live: Bool) -> [CGPath] {
        let step = max(4, size.width / 96)
        let count = Int((range.upperBound - range.lowerBound) / step) + 2
        let k = 2 * .pi / bandWavelength
        let speed = Double(bandSpeed)
        let length = envelope.isEmpty ? 0 : Double(envelope.level.count) / envelope.rate
        var amplitudes = [CGFloat](repeating: 0, count: count)
        for index in 0..<count {
            let x = range.lowerBound + CGFloat(index) * step
            let shape: Double
            if live {
                let time = Double(x) / speed - Self.window / 2
                shape = time < 0 || time > length ? 0 : envelope.level(at: time)
            } else {
                shape = 0.35
            }
            amplitudes[index] = bandAmplitude * CGFloat(0.16 + 0.84 * shape)
        }
        return (0..<Self.bandLines).map { line in
            let shift = CGFloat(line) * 0.32
            let baseline = bandTop + CGFloat(line) * bandGap
            let falloff = 1 - CGFloat(line) * 0.08
            let path = CGMutablePath()
            for index in 0..<count {
                let x = range.lowerBound + CGFloat(index) * step
                let phase = k * x + shift
                let point = CGPoint(x: x - range.lowerBound, y: baseline + amplitudes[index] * falloff * (sin(phase) + 0.38 * sin(2 * phase + shift * 1.7)))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            return path
        }
    }
}
