import SwiftUI

struct SoundingLineArt: View {
    enum Style: Sendable {
        case hero
        case ambient
        case banner
    }

    enum Loop: Sendable {
        case ambient
        case once
    }

    var seed: UInt64
    var style: Style = .hero
    var loop: Loop = .ambient
    var isActive = true

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var composition: SoundingLineArtComposition?
    @State private var startDate: Date?
    @State private var stage: Stage = .intro
    @State private var isOnScreen = false

    private enum Stage {
        case intro
        case idle
        case settled
    }

    var body: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: frameInterval, paused: isPaused)) { timeline in
                layer(.back, moment: moment(at: timeline.date))
            }
            TimelineView(.animation(minimumInterval: frameInterval, paused: isPaused || stage != .intro)) { timeline in
                layer(.front, moment: stage == .intro ? moment(at: timeline.date) : settledMoment)
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            guard size.width > 0, size.height > 0 else { return }
            composition = SoundingLineArtComposition(seed: seed, size: size, style: style)
        }
        .onAppear {
            isOnScreen = true
            if startDate == nil { startDate = .now }
        }
        .onDisappear { isOnScreen = false }
        .task(id: isOnScreen) { await advanceStage() }
        .accessibilityHidden(true)
    }

    private func layer(_ layer: SoundingLineArtComposition.Layer, moment: SoundingLineArtMoment) -> some View {
        let palette = SoundingArtPalette.resolve(colorScheme)
        let prepared = composition
        let seed = seed
        let style = style
        return Canvas(opaque: layer == .back) { context, size in
            let scene = prepared.flatMap { $0.fits(size) ? $0 : nil }
                ?? SoundingLineArtComposition(seed: seed, size: size, style: style)
            scene.draw(in: &context, moment: moment, palette: palette, layer: layer)
        }
    }

    private var settledMoment: SoundingLineArtMoment {
        SoundingLineArtMoment(time: introDuration, idle: 0, drifts: false)
    }

    private var introDuration: Double {
        SoundingLineArtComposition.introDuration(for: style)
    }

    private var showsStillFrame: Bool {
        reduceMotion || Self.debugForcesStill
    }

    private var isPaused: Bool {
        showsStillFrame || stage == .settled || !isOnScreen || !isActive || scenePhase != .active
    }

    private var frameInterval: Double {
        stage == .intro ? 1.0 / 60.0 : 1.0 / 24.0
    }

    private func moment(at date: Date) -> SoundingLineArtMoment {
        if showsStillFrame || stage == .settled {
            return settledMoment
        }
        let elapsed = date.timeIntervalSince(startDate ?? date)
        let idle = loop == .ambient ? SoundingLineArtComposition.smoothstep(introDuration - 0.4, introDuration + 1.6, elapsed) : 0
        return SoundingLineArtMoment(time: elapsed, idle: idle, drifts: true)
    }

    private func advanceStage() async {
        guard isOnScreen, stage == .intro, !showsStillFrame else { return }
        let elapsed = Date.now.timeIntervalSince(startDate ?? .now)
        let remaining = introDuration - elapsed
        if remaining > 0 {
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
        }
        stage = loop == .once ? .settled : .idle
    }

    private static let debugForcesStill: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["SOUNDING_TV_ART_STILL"] == "1"
        #else
        false
        #endif
    }()
}

struct SoundingLineArtMoment: Sendable {
    var time: Double
    var idle: Double
    var drifts: Bool
}

struct SoundingArtPalette: Sendable {
    var ground: Color
    var masses: [Color]
    var inks: [Color]
    var signal: Color

    static func resolve(_ scheme: ColorScheme) -> SoundingArtPalette {
        scheme == .dark ? dark : light
    }

    static let dark = SoundingArtPalette(
        ground: Color(red: 0.063, green: 0.051, blue: 0.047),
        masses: [
            Color(red: 0.42, green: 0.18, blue: 0.08),
            Color(red: 0.24, green: 0.13, blue: 0.22),
            Color(red: 0.09, green: 0.25, blue: 0.23),
        ],
        inks: [
            .scAccent,
            Color(red: 0.96, green: 0.75, blue: 0.40),
            Color(red: 0.43, green: 0.80, blue: 0.70),
            Color(red: 0.98, green: 0.60, blue: 0.56),
            Color(red: 0.95, green: 0.90, blue: 0.82),
        ],
        signal: Color(red: 1.00, green: 0.86, blue: 0.62)
    )

    static let light = SoundingArtPalette(
        ground: Color(red: 0.985, green: 0.962, blue: 0.930),
        masses: [
            Color(red: 0.99, green: 0.79, blue: 0.64),
            Color(red: 0.92, green: 0.82, blue: 0.88),
            Color(red: 0.77, green: 0.89, blue: 0.84),
        ],
        inks: [
            Color(red: 0.86, green: 0.33, blue: 0.06),
            Color(red: 0.70, green: 0.50, blue: 0.12),
            Color(red: 0.08, green: 0.46, blue: 0.41),
            Color(red: 0.66, green: 0.21, blue: 0.24),
            Color(red: 0.27, green: 0.18, blue: 0.14),
        ],
        signal: .scAccent
    )
}

struct SoundingLineArtComposition {
    enum Motion {
        case still
        case ring(Int)
        case contour(Int)
        case drift(speed: CGFloat, wavelength: CGFloat)
    }

    struct Line {
        var path: Path
        var tone: Int
        var width: CGFloat
        var delay: Double
        var duration: Double
        var origin: CGFloat
        var motion: Motion
    }

    struct Mass {
        var center: CGPoint
        var radius: CGFloat
        var rest: [CGFloat]
        var flood: [CGFloat]
        var restPath: Path
        var sweep: CGVector
        var floodScale: CGFloat
        var tone: Int
        var phase: Double
        var delay: Double
    }

    let size: CGSize
    let style: SoundingLineArt.Style
    private(set) var masses: [Mass] = []
    private(set) var plug = Path()
    private(set) var lines: [Line] = []
    private(set) var signal = Path()
    private(set) var signalWidth: CGFloat = 2
    private(set) var backLineCount = 0

    static func introDuration(for style: SoundingLineArt.Style) -> Double {
        switch style {
        case .hero: return 3.6
        case .ambient: return 4.4
        case .banner: return 3.2
        }
    }

    func fits(_ other: CGSize) -> Bool {
        abs(other.width - size.width) < 0.5 && abs(other.height - size.height) < 0.5
    }

    struct Placement {
        var tip: CGPoint
        var angle: CGFloat
        var plugLength: CGFloat
        var cableReach: CGFloat
        var cableBend: CGPoint
        var cableEnd: CGPoint
        var ringStart: CGFloat
        var ringGap: CGFloat
        var ringCount: Int
        var contourCount: Int
        var echoGap: CGFloat
        var lineWeight: CGFloat
        var toneShift: Int
    }

    init(seed: UInt64, size: CGSize, style: SoundingLineArt.Style) {
        self.init(seed: seed, size: size, style: style, placement: nil)
    }

    init(seed: UInt64, size: CGSize, placement: Placement) {
        self.init(seed: seed, size: size, style: .hero, placement: placement)
    }

    private init(seed: UInt64, size: CGSize, style: SoundingLineArt.Style, placement: Placement?) {
        self.size = size
        self.style = style
        guard size.width > 1, size.height > 1 else { return }

        var random = SoundingArtRandom(seed: seed)
        let layout: Layout
        if let placement {
            layout = Layout(placement: placement, size: size)
        } else {
            layout = Layout(style: style, size: size, random: &random)
        }
        let tempo = style == .ambient ? 1.25 : 1.0
        let drawnShift = Int(random.next() % 5)
        let toneShift = placement.map { (($0.toneShift % 5) + 5) % 5 } ?? drawnShift
        let weight = layout.lineWeight

        masses = Self.makeMasses(layout: layout, random: &random, style: style)

        let direction = CGVector(dx: cos(layout.angle), dy: sin(layout.angle))
        let normal = CGVector(dx: -direction.dy, dy: direction.dx)
        let tip = layout.tip
        let length = layout.plugLength

        func world(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: tip.x - direction.dx * x * length + normal.dx * y * length,
                y: tip.y - direction.dy * x * length + normal.dy * y * length
            )
        }

        let cable = Self.cableCentre(
            from: world(1, 0),
            heading: CGVector(dx: -direction.dx, dy: -direction.dy),
            layout: layout,
            random: &random
        )

        if let cone = layout.cone {
            for index in 0..<5 {
                let shrink = 1 - CGFloat(index) * 0.17
                let radius = cone.radius * shrink
                let centre = CGPoint(
                    x: cone.centre.x + cone.lean.dx * CGFloat(index) * cone.radius * 0.10,
                    y: cone.centre.y + cone.lean.dy * CGFloat(index) * cone.radius * 0.10
                )
                lines.append(Line(
                    path: Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)),
                    tone: (index + toneShift + 3) % 5,
                    width: weight * 0.9,
                    delay: (0.9 + Double(index) * 0.09) * tempo,
                    duration: 1.1 * tempo,
                    origin: 0,
                    motion: .contour(index + 2)
                ))
            }
        }

        if let waves = layout.waves {
            for index in 0..<waves.count {
                let amplitude = waves.amplitude * (1 - CGFloat(index) * 0.07)
                let shift = CGFloat(index) * 0.32
                let baseline = waves.top + CGFloat(index) * waves.gap
                var path = Path()
                let step = max(3, waves.wavelength / 28)
                var x = -waves.wavelength
                let k = 2 * .pi / waves.wavelength
                path.move(to: CGPoint(x: x, y: baseline + amplitude * (sin(k * x + shift) + 0.38 * sin(2 * k * x + shift * 1.7))))
                while x < size.width + waves.wavelength {
                    x += step
                    path.addLine(to: CGPoint(x: x, y: baseline + amplitude * (sin(k * x + shift) + 0.38 * sin(2 * k * x + shift * 1.7))))
                }
                lines.append(Line(
                    path: path,
                    tone: (index + toneShift + 2) % 5,
                    width: weight * 0.85,
                    delay: (1.1 + Double(index) * 0.07) * tempo,
                    duration: 1.4 * tempo,
                    origin: 0,
                    motion: .drift(speed: waves.wavelength / CGFloat(9 + index), wavelength: waves.wavelength)
                ))
            }
        }

        let ringCentre = CGPoint(x: tip.x + direction.dx * length * 0.05, y: tip.y + direction.dy * length * 0.05)
        let heading = atan2(direction.dy, direction.dx)
        for index in 0..<layout.ringCount {
            let radius = layout.ringStart + CGFloat(index) * layout.ringGap
            let span = (205.0 - Double(index) * 7.0) * .pi / 180
            var path = Path()
            path.addArc(
                center: ringCentre,
                radius: radius,
                startAngle: .radians(Double(heading) - span / 2),
                endAngle: .radians(Double(heading) + span / 2),
                clockwise: false
            )
            lines.append(Line(
                path: path,
                tone: (index + toneShift) % 4,
                width: weight,
                delay: (0.7 + Double(index) * 0.08) * tempo,
                duration: 1.0 * tempo,
                origin: 0.5,
                motion: .ring(index)
            ))
        }

        backLineCount = lines.count

        var plugOutline: [CGPoint] = Self.profile.map { world($0.x, $0.y) }
        plugOutline.append(contentsOf: Self.profile.reversed().dropFirst().map { world($0.x, -$0.y) })
        plug = Path { path in
            path.addLines(plugOutline)
            path.closeSubpath()
        }

        let echoGap: CGFloat = layout.echoGap / length
        for contour in 0..<layout.contourCount {
            let offset = CGFloat(contour) * echoGap
            let topSide = Self.profile.enumerated().map { index, point in
                world(point.x - offset * (index < 2 ? 1.1 - CGFloat(index) * 0.5 : 0), point.y + (index == 0 ? 0 : offset))
            }
            let bottomSide = topSide.map { point -> CGPoint in
                let local = Self.local(point, tip: tip, direction: direction, normal: normal, length: length)
                return world(local.x, -local.y)
            }
            let cableHalf = (Self.profile.last?.y ?? 0.026) + offset
            let cableTop = cable.map { sample in
                CGPoint(x: sample.point.x + sample.normal.dx * cableHalf * length, y: sample.point.y + sample.normal.dy * cableHalf * length)
            }
            let cableBottom = cable.map { sample in
                CGPoint(x: sample.point.x - sample.normal.dx * cableHalf * length, y: sample.point.y - sample.normal.dy * cableHalf * length)
            }
            var points: [CGPoint] = Array(cableTop.reversed())
            points.append(contentsOf: topSide.reversed())
            let tipIndex = points.count - 1
            points.append(contentsOf: bottomSide.dropFirst())
            points.append(contentsOf: cableBottom)
            let origin = Self.fraction(of: tipIndex, along: points)
            lines.append(Line(
                path: Path { $0.addLines(points) },
                tone: (contour + toneShift + 4) % 5,
                width: weight * (contour == 0 ? 1.15 : 0.9),
                delay: (0.95 + Double(contour) * 0.12) * tempo,
                duration: 1.7 * tempo,
                origin: origin,
                motion: .contour(contour)
            ))
        }

        let knurl = Path { path in
            var x: CGFloat = 0.53
            while x < 0.84 {
                path.move(to: world(x, 0.064))
                path.addLine(to: world(x + 0.04, -0.064))
                x += 0.042
            }
        }
        lines.append(Line(
            path: knurl,
            tone: toneShift % 5,
            width: weight * 0.8,
            delay: 2.2 * tempo,
            duration: 0.7 * tempo,
            origin: 0,
            motion: .still
        ))

        signal = Path { $0.addLines(cable.reversed().map(\.point)) }
        signalWidth = weight * 2.2
    }

    enum Layer {
        case back
        case front
        case all
        case inks
    }

    func draw(in context: inout GraphicsContext, moment: SoundingLineArtMoment, palette: SoundingArtPalette, layer: Layer = .all) {
        let time = moment.time
        let lineOpacity = style == .ambient ? 0.34 : (style == .banner ? 0.92 : 1.0)
        let pulseClock = time / 4.8

        if layer == .inks {
            for line in lines.prefix(backLineCount) {
                stroke(line, in: context, moment: moment, palette: palette, opacity: lineOpacity, pulseClock: pulseClock)
            }
            var cut = context
            cut.blendMode = .clear
            cut.fill(plug, with: .color(.black))
            for line in lines.dropFirst(backLineCount) {
                stroke(line, in: context, moment: moment, palette: palette, opacity: lineOpacity, pulseClock: pulseClock)
            }
            return
        }

        if layer != .front {
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(palette.ground))
            let massOpacity = style == .ambient ? 0.32 : 1.0
            for mass in masses {
                drawMass(mass, in: context, moment: moment, palette: palette, opacity: massOpacity)
            }
            for line in lines.prefix(backLineCount) {
                stroke(line, in: context, moment: moment, palette: palette, opacity: lineOpacity, pulseClock: pulseClock)
            }
            drawSignal(in: context, moment: moment, palette: palette, opacity: lineOpacity, pulseClock: pulseClock)
        }

        if layer != .back {
            let plugReveal = Self.easeInOut(Self.progress(time, delay: 1.9 * tempo, duration: 0.8 * tempo))
            if plugReveal > 0 {
                var fill = context
                fill.opacity = plugReveal
                fill.fill(plug, with: .color(palette.ground))
            }
            for line in lines.dropFirst(backLineCount) {
                stroke(line, in: context, moment: moment, palette: palette, opacity: lineOpacity, pulseClock: pulseClock)
            }
        }
    }

    private func stroke(
        _ line: Line,
        in context: GraphicsContext,
        moment: SoundingLineArtMoment,
        palette: SoundingArtPalette,
        opacity: Double,
        pulseClock: Double
    ) {
        let time = moment.time
        let reveal = Self.easeInOut(Self.progress(time, delay: line.delay, duration: line.duration))
        guard reveal > 0 else { return }
        var layer = context
        var alpha = opacity
        var width = line.width
        switch line.motion {
        case .still:
            break
        case .ring(let index):
            let bump = Self.bump(pulseClock - 0.36 - Double(index) * 0.055, width: 0.05)
            alpha *= 1 - 0.5 * moment.idle * (1 - bump)
            width *= 1 + 0.7 * moment.idle * bump
        case .contour(let index):
            let bump = Self.bump(time / 7.3 - Double(index) * 0.07, width: 0.08)
            alpha *= 1 - 0.35 * moment.idle * (1 - bump)
        case .drift(let speed, let wavelength):
            if moment.drifts {
                let travelled = CGFloat(time) * speed
                layer.translateBy(x: -travelled.truncatingRemainder(dividingBy: wavelength), y: 0)
            }
        }
        layer.opacity = alpha
        let path: Path
        if reveal >= 1 {
            path = line.path
        } else {
            let from = line.origin * (1 - reveal)
            let to = line.origin + (1 - line.origin) * reveal
            path = line.path.trimmedPath(from: from, to: to)
        }
        layer.stroke(
            path,
            with: .color(palette.inks[line.tone % palette.inks.count]),
            style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawSignal(
        in context: GraphicsContext,
        moment: SoundingLineArtMoment,
        palette: SoundingArtPalette,
        opacity: Double,
        pulseClock: Double
    ) {
        guard moment.idle > 0 else { return }
        let travel = (pulseClock - floor(pulseClock)) / 0.36
        guard travel < 1.12 else { return }
        var glow = context
        glow.opacity = opacity * moment.idle * (1 - Self.smoothstep(0.95, 1.12, travel))
        glow.stroke(
            signal.trimmedPath(from: max(0, travel - 0.14), to: min(1, travel)),
            with: .color(palette.signal),
            style: StrokeStyle(lineWidth: signalWidth, lineCap: .round, lineJoin: .round)
        )
    }

    private var tempo: Double { style == .ambient ? 1.25 : 1.0 }

    private func drawMass(
        _ mass: Mass,
        in context: GraphicsContext,
        moment: SoundingLineArtMoment,
        palette: SoundingArtPalette,
        opacity: Double
    ) {
        let duration = style == .hero ? 1.5 : 1.8 * tempo
        let settle = Self.easeInOut(Self.progress(moment.time, delay: mass.delay, duration: duration))
        var layer = context
        layer.opacity = style == .hero ? opacity : opacity * Self.easeInOut(min(1, settle * 1.6))
        let colour = palette.masses[mass.tone % palette.masses.count]
        if settle < 1 {
            layer.fill(shape(of: mass, settle: settle), with: .color(colour))
            return
        }
        let wobble = moment.idle
        let phase = mass.phase
        let angle = 0.07 * sin(moment.time * 2 * .pi / 17 + phase) * wobble
        let scale = 1 + 0.04 * sin(moment.time * 2 * .pi / 13 + phase * 1.7) * wobble
        layer.translateBy(x: mass.center.x, y: mass.center.y)
        layer.rotate(by: .radians(angle))
        layer.scaleBy(x: scale, y: scale)
        layer.translateBy(x: -mass.center.x, y: -mass.center.y)
        layer.fill(mass.restPath, with: .color(colour))
    }

    private func shape(of mass: Mass, settle: Double) -> Path {
        let u = CGFloat(settle)
        let centre = CGPoint(x: mass.center.x + mass.sweep.dx * (1 - u), y: mass.center.y + mass.sweep.dy * (1 - u))
        let radius = mass.radius * (mass.floodScale + (1 - mass.floodScale) * u)
        let twist = Double(1 - u) * 0.9
        let points = mass.rest.indices.map { index -> CGPoint in
            let factor = mass.flood[index] + (mass.rest[index] - mass.flood[index]) * u
            let angle = Double(index) / Double(mass.rest.count) * 2 * .pi + mass.phase + twist
            return CGPoint(x: centre.x + CGFloat(cos(angle)) * radius * factor, y: centre.y + CGFloat(sin(angle)) * radius * factor)
        }
        return Self.smoothClosed(points)
    }

    // MARK: - Geometry

    private struct Layout {
        struct Waves {
            var top: CGFloat
            var gap: CGFloat
            var count: Int
            var amplitude: CGFloat
            var wavelength: CGFloat
        }

        struct Cone {
            var centre: CGPoint
            var radius: CGFloat
            var lean: CGVector
        }

        var size: CGSize
        var tip: CGPoint
        var angle: CGFloat
        var plugLength: CGFloat
        var ringStart: CGFloat
        var ringGap: CGFloat
        var ringCount: Int
        var contourCount: Int
        var echoGap: CGFloat
        var lineWeight: CGFloat
        var cableEnd: CGPoint
        var cableBend: CGPoint
        var cableReach: CGFloat
        var waves: Waves?
        var cone: Cone?
        var massAnchors: [(CGPoint, CGFloat)]

        init(placement: Placement, size: CGSize) {
            self.size = size
            tip = placement.tip
            angle = placement.angle
            plugLength = placement.plugLength
            ringStart = placement.ringStart
            ringGap = placement.ringGap
            ringCount = placement.ringCount
            contourCount = placement.contourCount
            echoGap = placement.echoGap
            lineWeight = placement.lineWeight
            cableEnd = placement.cableEnd
            cableBend = placement.cableBend
            cableReach = placement.cableReach
            waves = nil
            cone = nil
            massAnchors = []
        }

        init(style: SoundingLineArt.Style, size: CGSize, random: inout SoundingArtRandom) {
            self.size = size
            let w = size.width
            let h = size.height
            let s = min(w, h)
            let l = max(w, h)
            cableReach = s * 0.42
            switch style {
            case .hero:
                tip = CGPoint(x: w * random.in(0.60...0.70), y: h * random.in(0.30...0.38))
                angle = -.pi / 4 + random.in(-0.18...0.14)
                plugLength = s * random.in(0.60...0.68)
                ringStart = s * 0.075
                ringGap = s * 0.062
                ringCount = 8
                contourCount = 5
                echoGap = s * 0.016
                lineWeight = min(max(s * 0.0046, 1.3), 2.4)
                cableBend = CGPoint(x: w * random.in(0.05...0.30), y: h * 1.02)
                cableEnd = CGPoint(x: w * 1.2, y: h * random.in(0.80...0.95))
                waves = random.chance(0.5)
                    ? Waves(top: h * 0.06, gap: s * 0.022, count: 5, amplitude: s * 0.018, wavelength: s * 0.42)
                    : nil
                cone = waves == nil
                    ? Cone(centre: CGPoint(x: w * random.in(0.06...0.16), y: h * random.in(0.10...0.20)), radius: s * 0.24, lean: CGVector(dx: 0.7, dy: 0.7))
                    : nil
                massAnchors = [
                    (CGPoint(x: w * random.in(0.22...0.36), y: h * random.in(0.58...0.70)), s * random.in(0.40...0.48)),
                    (CGPoint(x: w * random.in(0.86...0.98), y: h * random.in(0.10...0.24)), s * random.in(0.32...0.40)),
                    (CGPoint(x: w * random.in(0.02...0.14), y: h * random.in(0.02...0.14)), s * random.in(0.26...0.32)),
                ]
            case .ambient:
                tip = CGPoint(x: w * random.in(0.20...0.28), y: h * random.in(0.34...0.42))
                angle = -.pi / 4 + random.in(-0.12...0.12)
                plugLength = s * random.in(0.56...0.62)
                ringStart = s * 0.06
                ringGap = s * 0.052
                ringCount = 10
                contourCount = 6
                echoGap = s * 0.012
                lineWeight = min(max(s * 0.0024, 1.4), 2.6)
                cableBend = CGPoint(x: w * random.in(0.30...0.45), y: h * 1.1)
                cableEnd = CGPoint(x: w * 1.15, y: h * random.in(0.78...0.92))
                waves = Waves(top: h * 0.955, gap: s * 0.012, count: 4, amplitude: s * 0.010, wavelength: l * 0.18)
                cone = Cone(
                    centre: CGPoint(x: w * random.in(0.90...0.96), y: h * random.in(0.56...0.66)),
                    radius: s * 0.22,
                    lean: CGVector(dx: -0.7, dy: 0.7)
                )
                massAnchors = [
                    (CGPoint(x: w * random.in(0.14...0.24), y: h * random.in(0.62...0.76)), s * random.in(0.42...0.50)),
                    (CGPoint(x: w * random.in(0.84...0.96), y: h * random.in(0.08...0.20)), s * random.in(0.34...0.40)),
                    (CGPoint(x: w * random.in(0.56...0.70), y: h * random.in(0.96...1.06)), s * random.in(0.30...0.36)),
                ]
            case .banner:
                tip = CGPoint(x: w * random.in(0.78...0.86), y: h * random.in(0.24...0.34))
                angle = -.pi / 5 + random.in(-0.10...0.10)
                plugLength = s * random.in(0.80...0.90)
                ringStart = s * 0.10
                ringGap = s * 0.085
                ringCount = 9
                contourCount = 4
                echoGap = s * 0.020
                lineWeight = min(max(s * 0.0062, 1.2), 2.0)
                cableBend = CGPoint(x: w * random.in(0.55...0.65), y: h * 1.25)
                cableEnd = CGPoint(x: w * random.in(0.30...0.40), y: h * 1.4)
                waves = Waves(top: h * 0.70, gap: s * 0.035, count: 5, amplitude: s * 0.035, wavelength: s * 0.9)
                cone = nil
                massAnchors = [
                    (CGPoint(x: w * random.in(0.70...0.80), y: h * random.in(0.70...0.90)), s * random.in(0.60...0.70)),
                    (CGPoint(x: w * random.in(0.94...1.02), y: h * random.in(0.00...0.15)), s * random.in(0.45...0.55)),
                    (CGPoint(x: w * random.in(0.48...0.58), y: h * random.in(0.05...0.20)), s * random.in(0.30...0.38)),
                ]
            }
        }
    }

    private struct CableSample {
        var point: CGPoint
        var normal: CGVector
    }

    private static let profile: [CGPoint] = [
        CGPoint(x: 0.000, y: 0.000),
        CGPoint(x: 0.014, y: 0.022),
        CGPoint(x: 0.036, y: 0.030),
        CGPoint(x: 0.070, y: 0.030),
        CGPoint(x: 0.076, y: 0.019),
        CGPoint(x: 0.094, y: 0.019),
        CGPoint(x: 0.100, y: 0.031),
        CGPoint(x: 0.170, y: 0.031),
        CGPoint(x: 0.176, y: 0.019),
        CGPoint(x: 0.196, y: 0.019),
        CGPoint(x: 0.202, y: 0.034),
        CGPoint(x: 0.440, y: 0.034),
        CGPoint(x: 0.446, y: 0.052),
        CGPoint(x: 0.490, y: 0.052),
        CGPoint(x: 0.496, y: 0.064),
        CGPoint(x: 0.860, y: 0.064),
        CGPoint(x: 0.930, y: 0.046),
        CGPoint(x: 1.000, y: 0.026),
    ]

    private static func local(_ point: CGPoint, tip: CGPoint, direction: CGVector, normal: CGVector, length: CGFloat) -> CGPoint {
        let dx = point.x - tip.x
        let dy = point.y - tip.y
        return CGPoint(
            x: -(dx * direction.dx + dy * direction.dy) / length,
            y: (dx * normal.dx + dy * normal.dy) / length
        )
    }

    private static func cableCentre(
        from start: CGPoint,
        heading: CGVector,
        layout: Layout,
        random: inout SoundingArtRandom
    ) -> [CableSample] {
        let reach = layout.cableReach
        let control1 = CGPoint(x: start.x + heading.dx * reach, y: start.y + heading.dy * reach)
        let control2 = layout.cableBend
        let end = layout.cableEnd
        let count = 72
        var samples: [CableSample] = []
        samples.reserveCapacity(count + 1)
        for step in 0...count {
            let t = CGFloat(step) / CGFloat(count)
            let mt = 1 - t
            let a = mt * mt * mt
            let b = 3 * mt * mt * t
            let c = 3 * mt * t * t
            let d = t * t * t
            let point = CGPoint(
                x: a * start.x + b * control1.x + c * control2.x + d * end.x,
                y: a * start.y + b * control1.y + c * control2.y + d * end.y
            )
            let tx = 3 * mt * mt * (control1.x - start.x) + 6 * mt * t * (control2.x - control1.x) + 3 * t * t * (end.x - control2.x)
            let ty = 3 * mt * mt * (control1.y - start.y) + 6 * mt * t * (control2.y - control1.y) + 3 * t * t * (end.y - control2.y)
            let magnitude = max(0.0001, sqrt(tx * tx + ty * ty))
            samples.append(CableSample(point: point, normal: CGVector(dx: ty / magnitude, dy: -tx / magnitude)))
        }
        return samples
    }

    private static func makeMasses(layout: Layout, random: inout SoundingArtRandom, style: SoundingLineArt.Style) -> [Mass] {
        let s = min(layout.size.width, layout.size.height)
        let l = max(layout.size.width, layout.size.height)
        let sweeps: [CGVector] = [
            CGVector(dx: -l * 0.30, dy: l * 0.25),
            CGVector(dx: l * 0.35, dy: -l * 0.10),
            CGVector(dx: -l * 0.10, dy: -l * 0.35),
        ]
        return layout.massAnchors.enumerated().map { index, anchor in
            let count = 10
            let rest: [CGFloat] = (0..<count).map { _ in random.in(0.84...1.12) }
            let flood: [CGFloat] = (0..<count).map { _ in random.in(0.80...1.30) }
            let phase: Double = random.in(0.0...(2 * Double.pi))
            let points = (0..<count).map { item -> CGPoint in
                let angle = Double(item) / Double(count) * 2 * .pi + phase
                return CGPoint(
                    x: anchor.0.x + CGFloat(cos(angle)) * anchor.1 * rest[item],
                    y: anchor.0.y + CGFloat(sin(angle)) * anchor.1 * rest[item]
                )
            }
            let hero = style == .hero
            return Mass(
                center: anchor.0,
                radius: anchor.1,
                rest: rest,
                flood: flood,
                restPath: smoothClosed(points),
                sweep: hero ? sweeps[index % sweeps.count] : CGVector(dx: 0, dy: s * 0.04),
                floodScale: hero ? [3.2, 2.4, 2.0][index % 3] : 0.82,
                tone: index,
                phase: phase,
                delay: hero ? Double(index) * 0.16 : Double(index) * 0.22
            )
        }
    }

    private static func fraction(of index: Int, along points: [CGPoint]) -> CGFloat {
        var total: CGFloat = 0
        var upTo: CGFloat = 0
        for item in 1..<points.count {
            let dx = points[item].x - points[item - 1].x
            let dy = points[item].y - points[item - 1].y
            total += sqrt(dx * dx + dy * dy)
            if item == index { upTo = total }
        }
        return total > 0 ? upTo / total : 0.5
    }

    static func smoothClosed(_ points: [CGPoint]) -> Path {
        var path = Path()
        let count = points.count
        guard count > 2 else { return path }
        path.move(to: points[0])
        for index in 0..<count {
            let p0 = points[(index - 1 + count) % count]
            let p1 = points[index]
            let p2 = points[(index + 1) % count]
            let p3 = points[(index + 2) % count]
            path.addCurve(
                to: p2,
                control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            )
        }
        path.closeSubpath()
        return path
    }

    static func progress(_ time: Double, delay: Double, duration: Double) -> Double {
        min(1, max(0, (time - delay) / duration))
    }

    static func easeInOut(_ x: Double) -> Double {
        x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    static func smoothstep(_ lower: Double, _ upper: Double, _ x: Double) -> Double {
        let t = min(1, max(0, (x - lower) / (upper - lower)))
        return t * t * (3 - 2 * t)
    }

    static func bump(_ clock: Double, width: Double) -> Double {
        let phase = clock - floor(clock)
        let distance = min(phase, 1 - phase) / width
        return exp(-distance * distance)
    }
}

struct SoundingArtRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    mutating func `in`(_ range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * unit()
    }

    mutating func `in`(_ range: ClosedRange<CGFloat>) -> CGFloat {
        range.lowerBound + (range.upperBound - range.lowerBound) * CGFloat(unit())
    }

    mutating func chance(_ probability: Double) -> Bool {
        unit() < probability
    }
}
