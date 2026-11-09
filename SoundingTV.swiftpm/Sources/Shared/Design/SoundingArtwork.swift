import CoreGraphics
import Foundation

enum SoundingArtMotif: Int, CaseIterable, Sendable {
    case jack
    case cone
    case rings
    case waves
    case vinyl
    case crossfader
    case equaliser
}

enum SoundingArtSubject: Int, Sendable {
    case track
    case collection
    case person
    case station
    case genre
    case scene

    var motifs: [SoundingArtMotif] {
        switch self {
        case .track: return [.jack, .cone, .rings, .waves, .vinyl, .jack, .crossfader, .equaliser]
        case .collection: return [.jack, .equaliser, .waves, .crossfader, .vinyl, .cone, .jack]
        case .person: return [.cone, .rings, .equaliser, .waves, .jack, .vinyl]
        case .station: return [.rings, .waves, .cone, .jack, .equaliser]
        case .genre: return [.jack, .cone, .rings, .waves, .vinyl, .crossfader, .equaliser]
        case .scene: return [.jack, .cone, .waves, .rings]
        }
    }
}

enum SoundingArtScheme: Int, Sendable {
    case light
    case dark
}

struct SoundingArtRGB: Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    func mixed(with other: SoundingArtRGB, _ amount: Double) -> SoundingArtRGB {
        SoundingArtRGB(
            red + (other.red - red) * amount,
            green + (other.green - green) * amount,
            blue + (other.blue - blue) * amount
        )
    }

    func scaled(_ factor: Double) -> SoundingArtRGB {
        SoundingArtRGB(red * factor, green * factor, blue * factor)
    }

    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    var hexKey: String {
        String(format: "%02x%02x%02x", Int(red * 255), Int(green * 255), Int(blue * 255))
    }

    static let white = SoundingArtRGB(1, 1, 1)
}

struct SoundingArtTheme: Sendable {
    var ground: SoundingArtRGB
    var masses: [SoundingArtRGB]
    var inks: [SoundingArtRGB]
    var signal: SoundingArtRGB

    static let dark = SoundingArtTheme(
        ground: SoundingArtRGB(0.063, 0.051, 0.047),
        masses: [
            SoundingArtRGB(0.42, 0.18, 0.08),
            SoundingArtRGB(0.24, 0.13, 0.22),
            SoundingArtRGB(0.09, 0.25, 0.23),
        ],
        inks: [
            SoundingArtRGB(1.00, 0.42, 0.10),
            SoundingArtRGB(0.96, 0.75, 0.40),
            SoundingArtRGB(0.43, 0.80, 0.70),
            SoundingArtRGB(0.98, 0.60, 0.56),
            SoundingArtRGB(0.95, 0.90, 0.82),
        ],
        signal: SoundingArtRGB(1.00, 0.86, 0.62)
    )

    static let light = SoundingArtTheme(
        ground: SoundingArtRGB(0.985, 0.962, 0.930),
        masses: [
            SoundingArtRGB(0.99, 0.79, 0.64),
            SoundingArtRGB(0.92, 0.82, 0.88),
            SoundingArtRGB(0.77, 0.89, 0.84),
        ],
        inks: [
            SoundingArtRGB(0.86, 0.33, 0.06),
            SoundingArtRGB(0.70, 0.50, 0.12),
            SoundingArtRGB(0.08, 0.46, 0.41),
            SoundingArtRGB(0.66, 0.21, 0.24),
            SoundingArtRGB(0.27, 0.18, 0.14),
        ],
        signal: SoundingArtRGB(1.00, 0.42, 0.10)
    )

    static func base(_ scheme: SoundingArtScheme) -> SoundingArtTheme {
        scheme == .dark ? dark : light
    }

    static func ground(_ scheme: SoundingArtScheme, tint: SoundingArtRGB?) -> SoundingArtRGB {
        let ground = base(scheme).ground
        guard let tint else { return ground }
        return ground.mixed(with: scheme == .dark ? tint.scaled(0.30) : tint.mixed(with: .white, 0.55), 0.10)
    }

    static func make(_ scheme: SoundingArtScheme, tint: SoundingArtRGB?, random: inout SoundingArtworkRandom) -> SoundingArtTheme {
        var theme = base(scheme)
        let massShift = Int(random.next() % 3)
        theme.masses = (0..<3).map { theme.masses[($0 + massShift) % 3] }
        let inkShift = Int(random.next() % 5)
        theme.inks = (0..<5).map { theme.inks[($0 + inkShift) % 5] }
        if let tint {
            let wash = scheme == .dark ? tint.scaled(0.46) : tint.mixed(with: .white, 0.58)
            theme.masses = theme.masses.enumerated().map { index, mass in
                mass.mixed(with: wash, index == 0 ? 0.85 : 0.45)
            }
            theme.ground = ground(scheme, tint: tint)
        }
        return theme
    }
}

struct SoundingArtworkRandom {
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

    mutating func pick(_ count: Int) -> Int {
        Int(next() % UInt64(max(count, 1)))
    }
}

struct SoundingArtRequest: Hashable, Sendable {
    static let version = 2

    var seed: UInt64
    var subject: SoundingArtSubject
    var scheme: SoundingArtScheme
    var width: Double
    var height: Double
    var scale: Double
    var tint: SoundingArtRGB?
    var motif: SoundingArtMotif?

    init(
        seed: UInt64,
        subject: SoundingArtSubject = .track,
        scheme: SoundingArtScheme,
        size: CGSize,
        scale: CGFloat,
        tint: SoundingArtRGB? = nil,
        motif: SoundingArtMotif? = nil,
        maxPixels: Double = 1600,
        exactSize: Bool = false
    ) {
        self.seed = seed
        self.subject = subject
        self.scheme = scheme
        let quantized = exactSize ? size : Self.quantize(size)
        let longest = Double(max(quantized.width, quantized.height))
        self.scale = min(Double(scale), max(1, maxPixels / max(longest, 1)))
        self.width = Double(quantized.width)
        self.height = Double(quantized.height)
        self.tint = tint
        self.motif = motif
    }

    var size: CGSize { CGSize(width: width, height: height) }
    var pixelWidth: Int { max(1, Int((width * scale).rounded())) }
    var pixelHeight: Int { max(1, Int((height * scale).rounded())) }

    var cacheKey: String {
        var key = "sounding-art.v\(Self.version).\(seed).\(subject.rawValue).\(scheme.rawValue).\(pixelWidth)x\(pixelHeight)@\(Int((scale * 100).rounded()))"
        if let tint { key += ".t" + tint.hexKey }
        if let motif { key += ".m\(motif.rawValue)" }
        return key
    }

    static func quantize(_ size: CGSize) -> CGSize {
        CGSize(width: quantize(size.width), height: quantize(size.height))
    }

    private static func quantize(_ value: CGFloat) -> CGFloat {
        let value = max(8, value)
        let step: CGFloat = value < 64 ? 4 : (value < 160 ? 8 : (value < 400 ? 16 : 32))
        return (value / step).rounded(.up) * step
    }
}

enum SoundingArtRenderer {
    static func render(_ request: SoundingArtRequest) -> CGImage? {
        let width = request.pixelWidth
        let height = request.pixelHeight
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }
        draw(request, in: context)
        return context.makeImage()
    }

    static func draw(_ request: SoundingArtRequest, in context: CGContext) {
        let composition = SoundingArtComposer(request: request)
        let size = request.size
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(request.pixelHeight))
        context.scaleBy(x: CGFloat(request.scale), y: -CGFloat(request.scale))
        context.setFillColor(composition.theme.ground.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        if composition.mirrored {
            context.translateBy(x: size.width, y: 0)
            context.scaleBy(x: -1, y: 1)
        }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setShouldAntialias(true)
        for operation in composition.operations {
            switch operation {
            case .fill(let path, let colour, let alpha):
                context.setAlpha(alpha)
                context.setFillColor(colour.cgColor)
                context.addPath(path)
                context.fillPath()
            case .stroke(let path, let colour, let width, let alpha, let join):
                context.setAlpha(alpha)
                context.setStrokeColor(colour.cgColor)
                context.setLineWidth(width)
                context.setLineJoin(join)
                context.addPath(path)
                context.strokePath()
            }
        }
        context.restoreGState()
    }
}

struct SoundingArtComposer {
    enum Operation {
        case fill(CGPath, SoundingArtRGB, CGFloat)
        case stroke(CGPath, SoundingArtRGB, CGFloat, CGFloat, CGLineJoin)
    }

    struct Detail {
        var contours: Int
        var rings: Int
        var masses: Int
        var heft: CGFloat
        var ornaments: Bool
        var tiny: Bool
    }

    let canvas: CGSize
    let stage: CGRect
    let subject: SoundingArtSubject
    let detail: Detail
    let weight: CGFloat
    let gap: CGFloat
    private(set) var theme: SoundingArtTheme
    private(set) var mirrored = false
    private(set) var operations: [Operation] = []
    private var random: SoundingArtworkRandom

    var s: CGFloat { stage.width }

    init(request: SoundingArtRequest) {
        var identity = SoundingArtworkRandom(seed: request.seed)
        var layout = SoundingArtworkRandom(seed: request.seed ^ 0x6A09_E667_F3BC_C908)
        canvas = request.size
        subject = request.subject
        let w = canvas.width
        let h = canvas.height
        let shortest = min(w, h)
        if w > h * 1.2 {
            let lead = subject == .genre || subject == .scene ? layout.in(0.70...0.92) : layout.in(0.30...0.70)
            stage = CGRect(x: (w - h) * lead, y: 0, width: h, height: h)
        } else if h > w * 1.2 {
            stage = CGRect(x: 0, y: (h - w) * layout.in(0.10...0.35), width: w, height: w)
        } else {
            stage = CGRect(x: (w - shortest) / 2, y: (h - shortest) / 2, width: shortest, height: shortest)
        }
        theme = SoundingArtTheme.make(request.scheme, tint: request.tint, random: &identity)
        let flips = identity.chance(0.5)
        let extraContours = identity.pick(2)
        let motifs = subject.motifs
        let motifIndex = identity.pick(motifs.count)
        if shortest < 44 {
            detail = Detail(contours: 2, rings: 3, masses: 2, heft: 1.9, ornaments: false, tiny: true)
            weight = 1.0
            gap = 2.6
        } else if shortest < 100 {
            detail = Detail(contours: 3, rings: 4, masses: 3, heft: 1.45, ornaments: false, tiny: false)
            weight = 1.1
            gap = 3.0
        } else if shortest < 220 {
            detail = Detail(contours: 4 + extraContours, rings: 6, masses: 3, heft: 1.15, ornaments: true, tiny: false)
            weight = 1.5
            gap = 4.0
        } else if shortest < 500 {
            detail = Detail(contours: 5 + extraContours, rings: 8, masses: 3, heft: 1.0, ornaments: true, tiny: false)
            weight = 2.0
            gap = 5.6
        } else {
            detail = Detail(contours: 5 + extraContours, rings: 8, masses: 3, heft: 1.0, ornaments: true, tiny: false)
            weight = 2.8
            gap = 11.0
        }
        mirrored = subject == .genre || subject == .scene ? false : flips
        random = SoundingArtworkRandom(seed: request.seed ^ 0xBB67_AE85_84CA_A73B)
        compose(request.motif ?? motifs[motifIndex], seed: request.seed)
    }

    private mutating func compose(_ motif: SoundingArtMotif, seed: UInt64) {
        var masses = SoundingArtworkRandom(seed: seed ^ 0x3C6E_F372_FE94_F82B)
        addMasses(random: &masses)
        switch motif {
        case .jack: jack()
        case .cone: coneMotif()
        case .rings: ringsMotif()
        case .waves: wavesMotif()
        case .vinyl: vinyl()
        case .crossfader: crossfader()
        case .equaliser: equaliser()
        }
    }

    private func ink(_ index: Int) -> SoundingArtRGB {
        theme.inks[((index % 5) + 5) % 5]
    }

    private func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: stage.minX + stage.width * x, y: stage.minY + stage.height * y)
    }

    private mutating func stroke(_ path: CGPath, _ colour: SoundingArtRGB, width: CGFloat? = nil, alpha: CGFloat = 1, join: CGLineJoin = .round) {
        operations.append(.stroke(path, colour, width ?? weight, alpha, join))
    }

    private mutating func fill(_ path: CGPath, _ colour: SoundingArtRGB, alpha: CGFloat = 1) {
        operations.append(.fill(path, colour, alpha))
    }

    private mutating func addMasses(random: inout SoundingArtworkRandom) {
        let templates: [[(CGFloat, CGFloat, CGFloat)]]
        if subject == .person {
            templates = [
                [(0.50, 0.58, 0.44), (0.95, 0.08, 0.30), (0.04, 0.96, 0.26)],
                [(0.42, 0.46, 0.42), (0.98, 0.86, 0.34), (0.10, 0.04, 0.24)],
            ]
        } else {
            templates = [
                [(0.28, 0.70, 0.48), (0.94, 0.14, 0.36), (0.04, 0.06, 0.28)],
                [(0.78, 0.76, 0.48), (0.08, 0.30, 0.36), (0.72, 0.02, 0.24)],
                [(0.50, 0.98, 0.50), (0.02, 0.12, 0.36), (0.98, 0.38, 0.30)],
                [(0.20, 0.22, 0.44), (0.86, 0.86, 0.42), (0.98, 0.04, 0.24)],
            ]
        }
        let template = templates[random.pick(templates.count)]
        let widen = canvas.width > canvas.height * 1.4 ? min(1.6, canvas.width / canvas.height * 0.7) : 1
        let shortest = min(canvas.width, canvas.height)
        for (index, anchor) in template.prefix(detail.masses).enumerated() {
            let centre: CGPoint
            if stage.width < canvas.width * 0.8 || stage.height < canvas.height * 0.8 {
                centre = CGPoint(
                    x: canvas.width * (anchor.0 + random.in(-0.05...0.05)),
                    y: canvas.height * (anchor.1 + random.in(-0.05...0.05))
                )
            } else {
                centre = point(anchor.0 + random.in(-0.06...0.06), anchor.1 + random.in(-0.06...0.06))
            }
            let radius = shortest * anchor.2 * random.in(0.90...1.10) * (index == 0 ? widen : 1)
            fill(Self.blob(centre: centre, radius: radius, random: &random), theme.masses[index % 3])
        }
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

    private static let compactProfile: [CGPoint] = [
        CGPoint(x: 0.000, y: 0.000),
        CGPoint(x: 0.020, y: 0.026),
        CGPoint(x: 0.120, y: 0.030),
        CGPoint(x: 0.140, y: 0.020),
        CGPoint(x: 0.170, y: 0.034),
        CGPoint(x: 0.440, y: 0.034),
        CGPoint(x: 0.470, y: 0.064),
        CGPoint(x: 0.880, y: 0.064),
        CGPoint(x: 1.000, y: 0.030),
    ]

    private mutating func jack() {
        let angle = -CGFloat.pi / 4 + random.in(-0.12...0.18)
        let direction = CGVector(dx: cos(angle), dy: sin(angle))
        let normal = CGVector(dx: -direction.dy, dy: direction.dx)
        let tiny = detail.tiny
        let tip = point(random.in(0.68...0.76), random.in(0.22...0.30))
        let length = s * (tiny ? random.in(0.62...0.68) : random.in(0.52...0.60))
        let heft = detail.heft
        let profile = (detail.ornaments ? Self.profile : Self.compactProfile).map { CGPoint(x: $0.x, y: $0.y * heft) }

        func world(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: tip.x - direction.dx * x * length + normal.dx * y * length,
                y: tip.y - direction.dy * x * length + normal.dy * y * length
            )
        }

        let ringCentre = CGPoint(x: tip.x + direction.dx * length * 0.05, y: tip.y + direction.dy * length * 0.05)
        let ringStart = s * (tiny ? 0.13 : 0.085)
        let ringGap = s * (tiny ? 0.11 : (detail.ornaments ? 0.066 : 0.085))
        rings(centre: ringCentre, heading: angle, count: detail.rings, start: ringStart, gap: ringGap, span: 205, toneOffset: 0)

        if detail.ornaments { secondary(near: point(0.12, 0.14), avoiding: .jack) }

        let butt = world(1, 0)
        let heading = CGVector(dx: -direction.dx, dy: -direction.dy)
        let reach = s * 0.55
        let control1 = CGPoint(x: butt.x + heading.dx * reach, y: butt.y + heading.dy * reach)
        let control2 = point(random.in(0.30...0.55), random.in(1.10...1.18))
        let end = CGPoint(x: canvas.width + s * 0.2, y: stage.minY + s * random.in(0.86...0.96))
        let cable = Self.cubicSamples(butt, control1, control2, end, count: tiny ? 28 : 64)

        let plugOutline = profile.map { world($0.x, $0.y) } + profile.reversed().dropFirst().map { world($0.x, -$0.y) }
        let plugPath = CGMutablePath()
        plugPath.addLines(between: plugOutline)
        plugPath.closeSubpath()

        let cableHalf = profile.last?.y ?? 0.03
        var contourPaths: [CGPath] = []
        for contour in 0..<detail.contours {
            let offset = CGFloat(contour) * gap / length
            let top = profile.enumerated().map { index, p in
                world(p.x - offset * (index < 2 ? 1.1 - CGFloat(index) * 0.5 : 0), p.y + (index == 0 ? 0 : offset))
            }
            let bottom = profile.enumerated().map { index, p in
                world(p.x - offset * (index < 2 ? 1.1 - CGFloat(index) * 0.5 : 0), -(p.y + (index == 0 ? 0 : offset)))
            }
            let half = (cableHalf + offset) * length
            let cableTop = cable.map { CGPoint(x: $0.point.x + $0.normal.dx * half, y: $0.point.y + $0.normal.dy * half) }
            let cableBottom = cable.map { CGPoint(x: $0.point.x - $0.normal.dx * half, y: $0.point.y - $0.normal.dy * half) }
            var points = Array(cableTop.reversed())
            points.append(contentsOf: top.reversed())
            points.append(contentsOf: bottom.dropFirst())
            points.append(contentsOf: cableBottom)
            let path = CGMutablePath()
            path.addLines(between: points)
            contourPaths.append(path)
        }

        if detail.ornaments {
            let signal = CGMutablePath()
            let from = Int(Double(cable.count) * 0.62)
            let to = Int(Double(cable.count) * 0.74)
            signal.addLines(between: cable[from...to].map(\.point))
            let half = (cableHalf + CGFloat(detail.contours) * gap / length) * length + gap
            let shifted = cable[from...to].map { CGPoint(x: $0.point.x - $0.normal.dx * half, y: $0.point.y - $0.normal.dy * half) }
            let glint = CGMutablePath()
            glint.addLines(between: shifted)
            stroke(glint, theme.signal, width: weight * 2.4, alpha: 0.55)
        }

        fill(plugPath, theme.ground)
        for (index, path) in contourPaths.enumerated().reversed() {
            stroke(path, ink(index), width: index == 0 ? weight * 1.15 : weight)
        }

        if detail.ornaments {
            let knurl = CGMutablePath()
            var x: CGFloat = 0.53
            while x < 0.84 {
                knurl.move(to: world(x, 0.064 * heft))
                knurl.addLine(to: world(x + 0.04, -0.064 * heft))
                x += detail.contours > 4 ? 0.042 : 0.06
            }
            stroke(knurl, ink(1), width: weight * 0.8)
        }
    }

    private mutating func coneMotif() {
        let person = subject == .person
        let centre = person ? point(0.5 + random.in(-0.04...0.04), 0.5 + random.in(-0.04...0.04))
            : point(random.in(0.36...0.52), random.in(0.40...0.58))
        let radius = s * (person ? random.in(0.30...0.34) : random.in(0.30...0.36))
        let leanAngle = random.in(0.0...(2 * Double.pi))
        let lean = CGVector(dx: cos(leanAngle), dy: sin(leanAngle))
        if detail.ornaments || person {
            let heading = CGFloat(leanAngle) + .pi + random.in(-0.5...0.5)
            let count = detail.tiny ? 0 : max(2, detail.rings / 2)
            rings(centre: centre, heading: heading, count: count, start: radius + gap * 2.2, gap: gap * 1.6, span: 70, toneOffset: 2)
        }
        if detail.ornaments && !person { secondary(near: point(0.88, 0.12), avoiding: .cone) }
        cone(centre: centre, radius: radius, lean: lean, count: detail.contours + 1, capped: true)
    }

    private mutating func cone(centre: CGPoint, radius: CGFloat, lean: CGVector, count: Int, capped: Bool) {
        let count = max(2, count)
        var innermost = CGRect.zero
        for index in 0..<count {
            let t = CGFloat(index) / CGFloat(count - 1)
            let r = radius * (1 - 0.68 * t)
            let shift = radius * 0.32 * t
            let c = CGPoint(x: centre.x + lean.dx * shift, y: centre.y + lean.dy * shift)
            let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            innermost = rect
            stroke(CGPath(ellipseIn: rect, transform: nil), ink(count - 1 - index), width: index == 0 ? weight * 1.15 : weight)
        }
        if capped {
            let cap = innermost.insetBy(dx: innermost.width * 0.32, dy: innermost.height * 0.32)
            fill(CGPath(ellipseIn: cap, transform: nil), detail.tiny ? ink(0) : theme.signal, alpha: detail.tiny ? 1 : 0.9)
        }
    }

    private mutating func ringsMotif() {
        let person = subject == .person
        if person {
            let centre = point(0.5, 0.5)
            let heading = CGFloat(random.in(0.0...(2 * Double.pi)))
            let count = detail.rings - (detail.tiny ? 1 : 2)
            rings(centre: centre, heading: heading, count: count, start: s * (detail.tiny ? 0.16 : 0.12), gap: s * (detail.tiny ? 0.11 : 0.075), span: 290, toneOffset: 0)
            cone(centre: centre, radius: s * (detail.tiny ? 0.10 : 0.075), lean: CGVector(dx: cos(heading), dy: sin(heading)), count: detail.tiny ? 2 : 3, capped: true)
            return
        }
        let source = point(random.in(0.14...0.30), random.in(0.66...0.84))
        let heading = -CGFloat.pi / 4 + random.in(-0.35...0.35)
        let count = detail.rings + (detail.tiny ? 0 : (detail.ornaments ? 3 : 1))
        let start = s * (detail.tiny ? 0.16 : 0.11)
        let ringGap = s * (detail.tiny ? 0.15 : (detail.ornaments ? 0.068 : 0.09))
        rings(centre: source, heading: heading, count: count, start: start, gap: ringGap, span: 210, toneOffset: 1)
        cone(centre: source, radius: s * (detail.tiny ? 0.11 : 0.085), lean: CGVector(dx: cos(heading), dy: sin(heading)), count: detail.tiny ? 2 : 3, capped: true)
    }

    private mutating func rings(centre: CGPoint, heading: CGFloat, count: Int, start: CGFloat, gap ringGap: CGFloat, span: Double, toneOffset: Int) {
        guard count > 0 else { return }
        for index in 0..<count {
            let radius = start + CGFloat(index) * ringGap
            let arc = (span - Double(index) * 7) * .pi / 180
            let path = CGMutablePath()
            path.addArc(
                center: centre,
                radius: radius,
                startAngle: heading - CGFloat(arc / 2),
                endAngle: heading + CGFloat(arc / 2),
                clockwise: false
            )
            stroke(path, ink(index + toneOffset))
        }
    }

    private mutating func wavesMotif() {
        let count = detail.contours + (detail.tiny ? 1 : 2)
        let lineGap = max(gap * 1.1, s * (detail.tiny ? 0.09 : (detail.ornaments ? 0.045 : 0.065)))
        let amplitude = s * (detail.ornaments ? random.in(0.05...0.09) : random.in(0.07...0.11))
        let wavelength = s * random.in(0.48...0.86)
        let tilt = random.in(-0.38...0.38)
        let centre = point(0.5, random.in(0.44...0.60))
        let enveloped = random.chance(0.6)
        let envelopeCentre = random.in(0.3...0.7)
        if detail.ornaments { secondary(near: point(random.chance(0.5) ? 0.12 : 0.88, 0.12), avoiding: .waves) }
        let reach = max(canvas.width, canvas.height) * 0.8 + s * 0.2
        let step = max(1.5, wavelength / 30)
        let k = 2 * CGFloat.pi / wavelength
        let total = CGFloat(count - 1) * lineGap
        for index in 0..<count {
            let shift = CGFloat(index) * 0.32
            let amp = amplitude * (1 - CGFloat(index) * 0.06)
            let baseline = CGFloat(index) * lineGap - total / 2
            let path = CGMutablePath()
            var x = -reach
            var first = true
            while x <= reach {
                let u = (x + s / 2) / s
                let envelope = enveloped ? 0.35 + 0.65 * exp(-pow((u - envelopeCentre) / 0.32, 2)) : 1
                let y = baseline + amp * envelope * (sin(k * x + shift) + 0.38 * sin(2 * k * x + shift * 1.7))
                let px = centre.x + x * cos(tilt) - y * sin(tilt)
                let py = centre.y + x * sin(tilt) + y * cos(tilt)
                if first { path.move(to: CGPoint(x: px, y: py)); first = false } else { path.addLine(to: CGPoint(x: px, y: py)) }
                x += step
            }
            stroke(path, ink(index), width: index == 0 || index == count - 1 ? weight * 1.1 : weight)
        }
    }

    private mutating func vinyl() {
        let person = subject == .person
        let centre = person ? point(0.5, 0.5) : point(random.in(0.38...0.48), random.in(0.50...0.60))
        let radius = s * (person ? 0.36 : random.in(0.34...0.40))
        let disc = CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
        let echoes = detail.tiny ? 1 : max(1, detail.contours - 2)
        for index in 0..<echoes {
            let r = radius + CGFloat(index + 1) * gap
            stroke(CGPath(ellipseIn: CGRect(x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2), transform: nil), ink(index + 3))
        }
        stroke(CGPath(ellipseIn: disc, transform: nil), ink(0), width: weight * 1.15)
        let grooves = detail.tiny ? 1 : detail.contours
        for index in 0..<grooves {
            let t = grooves == 1 ? 0.5 : CGFloat(index) / CGFloat(grooves - 1)
            let r = radius * (0.84 - 0.36 * t)
            let start = CGFloat(random.in(0.0...(2 * Double.pi)))
            let sweep = CGFloat(random.in(4.2...5.6))
            let path = CGMutablePath()
            path.addArc(center: centre, radius: r, startAngle: start, endAngle: start + sweep, clockwise: false)
            stroke(path, ink(index + 1), width: weight * 0.9)
        }
        let label = radius * 0.30
        fill(CGPath(ellipseIn: CGRect(x: centre.x - label, y: centre.y - label, width: label * 2, height: label * 2), transform: nil), theme.signal, alpha: 0.9)
        let spindle = max(weight * 1.4, radius * 0.05)
        fill(CGPath(ellipseIn: CGRect(x: centre.x - spindle, y: centre.y - spindle, width: spindle * 2, height: spindle * 2), transform: nil), theme.ground)

        guard !person, !detail.tiny else { return }
        let pivot = CGPoint(x: centre.x + radius * 1.02, y: centre.y - radius * 0.86)
        let elbow = CGPoint(x: centre.x + radius * 0.98, y: centre.y + radius * 0.10)
        let head = CGPoint(x: centre.x + radius * 0.66, y: centre.y + radius * 0.40)
        let arm = CGMutablePath()
        arm.move(to: pivot)
        arm.addLine(to: elbow)
        arm.addLine(to: head)
        let armEchoes = max(2, detail.contours - 1)
        for index in stride(from: armEchoes, through: 1, by: -1) {
            let outline = arm.copy(strokingWithWidth: CGFloat(index) * gap * 2, lineCap: .round, lineJoin: .round, miterLimit: 4).normalized()
            if index == armEchoes { fill(outline, theme.ground) }
            stroke(outline, ink(index + 2))
        }
        stroke(arm, ink(0), width: weight * 1.3)
        let hub = radius * 0.13
        fill(CGPath(ellipseIn: CGRect(x: pivot.x - hub, y: pivot.y - hub, width: hub * 2, height: hub * 2), transform: nil), theme.ground)
        stroke(CGPath(ellipseIn: CGRect(x: pivot.x - hub, y: pivot.y - hub, width: hub * 2, height: hub * 2), transform: nil), ink(0))
    }

    private mutating func crossfader() {
        let centre = point(0.5 + random.in(-0.05...0.05), random.in(0.48...0.60))
        let angle = random.chance(0.3) ? -CGFloat.pi / 2 + random.in(-0.15...0.15) : random.in(-0.45...0.45)
        let length = s * (detail.tiny ? 0.86 : 0.78)
        let slotWidth = s * (detail.tiny ? 0.10 : 0.06)
        var transform = CGAffineTransform(translationX: centre.x, y: centre.y).rotated(by: angle)
        let slot = CGPath(
            roundedRect: CGRect(x: -length / 2, y: -slotWidth / 2, width: length, height: slotWidth),
            cornerWidth: slotWidth / 2,
            cornerHeight: slotWidth / 2,
            transform: &transform
        )
        let travel = random.in(-0.28...0.28) * length
        let capLength = s * (detail.tiny ? 0.36 : 0.26)
        let capWidth = s * (detail.tiny ? 0.16 : 0.11)
        let capCorner = capWidth * 0.22
        let cap = CGPath(
            roundedRect: CGRect(x: travel - capWidth / 2, y: -capLength / 2, width: capWidth, height: capLength),
            cornerWidth: capCorner,
            cornerHeight: capCorner,
            transform: &transform
        )

        if detail.ornaments {
            secondary(near: point(random.chance(0.5) ? 0.14 : 0.86, 0.14), avoiding: .crossfader)
            let ticks = CGMutablePath()
            let tickCount = 11
            let offset = slotWidth / 2 + CGFloat(detail.contours) * gap + gap
            for index in 0..<tickCount {
                let x = -length / 2 + length * CGFloat(index) / CGFloat(tickCount - 1)
                let long = index % 5 == 0
                ticks.move(to: CGPoint(x: x, y: offset).applying(transform))
                ticks.addLine(to: CGPoint(x: x, y: offset + gap * (long ? 2.2 : 1.2)).applying(transform))
            }
            stroke(ticks, ink(4), width: weight * 0.9)
        }

        let slotEchoes = detail.tiny ? 1 : detail.contours - 1
        for index in stride(from: slotEchoes, through: 1, by: -1) {
            let grown = slot.union(slot.copy(strokingWithWidth: CGFloat(index) * gap * 2, lineCap: .round, lineJoin: .round, miterLimit: 4))
            stroke(grown, ink(index))
        }
        fill(slot, theme.masses[0].mixed(with: ink(0), 0.25))
        stroke(slot, ink(0), width: weight * 1.15)

        let capEchoes = detail.tiny ? 1 : max(2, detail.contours - 2)
        let outer = cap.union(cap.copy(strokingWithWidth: CGFloat(capEchoes) * gap * 2, lineCap: .round, lineJoin: .miter, miterLimit: 4))
        fill(outer, theme.ground)
        for index in stride(from: capEchoes, through: 1, by: -1) {
            let grown = cap.union(cap.copy(strokingWithWidth: CGFloat(index) * gap * 2, lineCap: .round, lineJoin: .miter, miterLimit: 4))
            stroke(grown, ink(index + 2), join: .miter)
        }
        stroke(cap, ink(0), width: weight * 1.15, join: .miter)
        let grip = CGMutablePath()
        let grips = detail.tiny ? 1 : 3
        for index in 0..<grips {
            let y = grips == 1 ? 0 : -capLength * 0.22 + capLength * 0.22 * CGFloat(index)
            grip.move(to: CGPoint(x: travel - capWidth * 0.28, y: y).applying(transform))
            grip.addLine(to: CGPoint(x: travel + capWidth * 0.28, y: y).applying(transform))
        }
        stroke(grip, detail.tiny ? ink(0) : theme.signal, width: weight * (detail.tiny ? 1 : 1.4))
    }

    private mutating func equaliser() {
        let person = subject == .person
        let count = detail.tiny ? 4 : (person ? 5 : (detail.ornaments ? 5 + random.pick(3) : 4 + random.pick(2)))
        let span = s * (person ? 0.62 : 0.74)
        let left = stage.minX + (s - span) / 2 + (person ? 0 : s * random.in(-0.06...0.06))
        let pitch = span / CGFloat(count)
        let barWidth = pitch * 0.52
        let grounded = person ? false : random.chance(0.5)
        let baseline = grounded ? stage.minY + s * 1.08 : stage.minY + s * (person ? 0.74 : random.in(0.78...0.86))
        let phase = random.in(0.0...(2 * Double.pi))
        let frequency = random.in(0.7...1.5)
        var bars = CGMutablePath()
        var tops: [CGRect] = []
        for index in 0..<count {
            let wave = 0.5 + 0.5 * sin(Double(index) * frequency + phase)
            let level = CGFloat(0.16 + 0.34 * wave + random.in(0.0...0.14))
            let height = s * level * (person ? 0.75 : 1) + (grounded ? s * 0.1 : 0)
            let x = left + CGFloat(index) * pitch + (pitch - barWidth) / 2
            let rect = CGRect(x: x, y: baseline - height, width: barWidth, height: height)
            tops.append(rect)
            bars.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth * 0.18, cornerHeight: barWidth * 0.18, transform: nil))
        }
        bars = bars.mutableCopy() ?? bars

        if detail.ornaments && !person { secondary(near: point(random.chance(0.5) ? 0.12 : 0.88, 0.12), avoiding: .equaliser) }

        let echoes = detail.tiny ? 1 : detail.contours - 1
        for index in stride(from: echoes, through: 1, by: -1) {
            let grown = bars.union(bars.copy(strokingWithWidth: CGFloat(index) * gap * 2, lineCap: .butt, lineJoin: .miter, miterLimit: 10))
            stroke(grown, ink(index), join: .miter)
        }
        fill(bars, theme.ground)
        stroke(bars, ink(0), width: weight * 1.15, join: .miter)
        if detail.ornaments {
            let peaks = CGMutablePath()
            for rect in tops where random.chance(0.7) {
                let y = rect.minY - CGFloat(echoes) * gap - gap * random.in(1.2...2.6)
                peaks.move(to: CGPoint(x: rect.minX + barWidth * 0.15, y: y))
                peaks.addLine(to: CGPoint(x: rect.maxX - barWidth * 0.15, y: y))
            }
            stroke(peaks, theme.signal, width: weight * 2)
        }
    }

    private mutating func secondary(near anchor: CGPoint, avoiding motif: SoundingArtMotif) {
        let choice = random.pick(3)
        switch choice {
        case 0 where motif != .cone:
            let lean = CGFloat(random.in(0.0...(2 * Double.pi)))
            cone(centre: anchor, radius: s * random.in(0.14...0.20), lean: CGVector(dx: cos(lean), dy: sin(lean)), count: 4, capped: false)
        case 1 where motif != .waves:
            let count = 4
            let top = anchor.y - CGFloat(count) * gap * 0.6
            let wavelength = s * 0.3
            let k = 2 * CGFloat.pi / wavelength
            for index in 0..<count {
                let path = CGMutablePath()
                let baseline = top + CGFloat(index) * gap * 1.2
                var x = anchor.x - s * 0.24
                path.move(to: CGPoint(x: x, y: baseline + s * 0.014 * sin(k * x + CGFloat(index) * 0.4)))
                while x < anchor.x + s * 0.24 {
                    x += 2
                    path.addLine(to: CGPoint(x: x, y: baseline + s * 0.014 * sin(k * x + CGFloat(index) * 0.4)))
                }
                stroke(path, ink(index + 2), width: weight * 0.9)
            }
        default:
            let heading = atan2(stage.midY - anchor.y, stage.midX - anchor.x) + .pi
            rings(centre: anchor, heading: heading, count: 4, start: s * 0.05, gap: s * 0.045, span: 160, toneOffset: 3)
        }
    }

    struct CableSample {
        var point: CGPoint
        var normal: CGVector
    }

    static func cubicSamples(_ start: CGPoint, _ control1: CGPoint, _ control2: CGPoint, _ end: CGPoint, count: Int) -> [CableSample] {
        (0...count).map { step in
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
            return CableSample(point: point, normal: CGVector(dx: ty / magnitude, dy: -tx / magnitude))
        }
    }

    static func blob(centre: CGPoint, radius: CGFloat, random: inout SoundingArtworkRandom) -> CGPath {
        let count = 10
        let phase = random.in(0.0...(2 * Double.pi))
        let points = (0..<count).map { index -> CGPoint in
            let factor = random.in(0.86...1.12)
            let angle = Double(index) / Double(count) * 2 * .pi + phase
            return CGPoint(x: centre.x + CGFloat(cos(angle)) * radius * factor, y: centre.y + CGFloat(sin(angle)) * radius * factor)
        }
        let path = CGMutablePath()
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
}
