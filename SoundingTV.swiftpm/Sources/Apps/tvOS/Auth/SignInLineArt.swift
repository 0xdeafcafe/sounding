import SwiftUI
import UIKit
import QuartzCore

enum SignInBackdropMode: Equatable, Sendable {
    case listening
    case connecting
    case resolved
    case unavailable
}

struct SignInLineArt: View {
    var mode: SignInBackdropMode
    var plate: CGRect?
    var showsPlate: Bool
    var palette: SoundingArtPalette = .dark

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SignInSoundField(
            plate: plate,
            isStill: reduceMotion || Self.debugForcesStill,
            isActive: scenePhase == .active,
            isQuiet: !showsPlate || mode != .listening,
            isDark: colorScheme == .dark,
            palette: palette
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static let debugForcesStill: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["SOUNDING_TV_ART_STILL"] == "1"
        #else
        false
        #endif
    }()
}

private struct SignInSoundField: UIViewRepresentable {
    let plate: CGRect?
    let isStill: Bool
    let isActive: Bool
    let isQuiet: Bool
    let isDark: Bool
    let palette: SoundingArtPalette

    func makeUIView(context: Context) -> SignInSoundFieldView {
        SignInSoundFieldView()
    }

    func updateUIView(_ view: SignInSoundFieldView, context: Context) {
        let localPlate = plate.map { view.window == nil ? $0 : view.convert($0, from: nil) }
        view.update(
            plate: localPlate,
            moving: isActive && !isStill && !isQuiet,
            quiet: isQuiet,
            dark: isDark,
            copper: palette.inks[0].resolve(in: context.environment).cgColor,
            amber: palette.inks[1].resolve(in: context.environment).cgColor,
            ground: palette.ground.resolve(in: context.environment).cgColor
        )
    }

    static func dismantleUIView(_ view: SignInSoundFieldView, coordinator: ()) {
        view.stop()
    }
}

private final class SignInSoundFieldView: UIView {
    private let field = CALayer()
    private let cable = CALayer()
    private var washes: [CAGradientLayer] = []
    private var plate: CGRect?
    private var moving = false
    private var quiet = false
    private var dark = true
    private var copper = UIColor.orange.cgColor
    private var amber = UIColor.orange.cgColor
    private var ground = UIColor.black.cgColor
    private var renderedSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.masksToBounds = true
        layer.addSublayer(field)
        layer.addSublayer(cable)
    }

    required init?(coder: NSCoder) { nil }

    func update(plate: CGRect?, moving: Bool, quiet: Bool, dark: Bool, copper: CGColor, amber: CGColor, ground: CGColor) {
        let rebuild = self.plate != plate || self.dark != dark || self.copper != copper || self.amber != amber || self.ground != ground
        let motionChanged = self.moving != moving
        self.plate = plate
        self.moving = moving
        self.quiet = quiet
        self.dark = dark
        self.copper = copper
        self.amber = amber
        self.ground = ground
        if rebuild { drawField() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        field.opacity = quiet ? 0.35 : 1
        cable.opacity = quiet ? 0.12 : 0.48
        CATransaction.commit()
        if motionChanged && !rebuild { animate() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != renderedSize { drawField() }
    }

    func stop() {
        for wash in washes { wash.removeAllAnimations() }
        cable.removeAllAnimations()
    }

    private func drawField() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        stop()
        renderedSize = bounds.size
        let centre = plate.map { CGPoint(x: $0.midX, y: $0.midY) }
            ?? CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        field.frame = bounds
        cable.frame = bounds
        field.sublayers?.forEach { $0.removeFromSuperlayer() }
        cable.sublayers?.forEach { $0.removeFromSuperlayer() }
        washes = []
        let positions = [
            CGPoint(x: centre.x - bounds.width * 0.25, y: centre.y + 80),
            CGPoint(x: centre.x + bounds.width * 0.25, y: centre.y - 60),
            CGPoint(x: centre.x + 40, y: centre.y + 150)
        ]
        for (index, position) in positions.enumerated() {
            let wash = CAGradientLayer()
            let colour = index == 1 ? amber : copper
            let width = bounds.width * (index == 2 ? 0.5 : 0.7)
            wash.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height * 0.9)
            wash.position = position
            wash.type = .radial
            wash.startPoint = CGPoint(x: 0.5, y: 0.5)
            wash.endPoint = CGPoint(x: 1, y: 1)
            wash.colors = [colour.copy(alpha: dark ? 0.14 : 0.09)!, colour.copy(alpha: 0)!]
            wash.locations = [0, 1]
            field.addSublayer(wash)
            washes.append(wash)
        }

        let tip = CGPoint(x: centre.x - 270, y: centre.y + 12)
        let length = min(330, max(190, bounds.width * 0.18))
        let placement = SoundingLineArtComposition.Placement(
            tip: tip,
            angle: -0.12,
            plugLength: length,
            cableReach: bounds.width * 0.22,
            cableBend: CGPoint(x: bounds.width * 0.08, y: centre.y + 210),
            cableEnd: CGPoint(x: -80, y: centre.y + 130),
            ringStart: 46,
            ringGap: 36,
            ringCount: 0,
            contourCount: 3,
            echoGap: 5,
            lineWeight: 1.8,
            toneShift: 0
        )
        let composition = SoundingLineArtComposition(seed: 0x54_56_4C_4E, size: bounds.size, placement: placement)
        let fill = CAShapeLayer()
        fill.frame = bounds
        fill.path = composition.plug.cgPath
        fill.fillColor = ground
        fill.shadowPath = composition.plug.cgPath
        fill.shadowColor = UIColor.black.cgColor
        fill.shadowOpacity = dark ? 0.35 : 0.12
        fill.shadowRadius = 18
        fill.shadowOffset = CGSize(width: 0, height: 12)
        cable.addSublayer(fill)
        for line in composition.lines {
            let opacity: Float
            switch line.motion {
            case .contour(let index): opacity = index == 0 ? 0.85 : 0.24 / Float(index)
            case .still: opacity = 0.65
            case .ring, .drift: continue
            }
            let stroke = CAShapeLayer()
            stroke.frame = bounds
            stroke.path = line.path.cgPath
            stroke.strokeColor = line.tone.isMultiple(of: 2) ? copper : amber
            stroke.fillColor = nil
            stroke.lineWidth = line.width
            stroke.lineCap = .round
            stroke.lineJoin = .round
            stroke.opacity = opacity
            stroke.contentsScale = traitCollection.displayScale
            cable.addSublayer(stroke)
        }
        field.opacity = quiet ? 0.35 : 1
        cable.opacity = quiet ? 0.12 : 0.48
        CATransaction.commit()
        animate()
    }

    private func animate() {
        stop()
        guard moving else { return }
        for (index, wash) in washes.enumerated() {
            let shift = CABasicAnimation(keyPath: "transform.translation.x")
            shift.fromValue = -12
            shift.toValue = index.isMultiple(of: 2) ? 22 : -22
            loop(shift, on: wash, duration: 16 + Double(index) * 3, key: "drift")
            let breath = CABasicAnimation(keyPath: "opacity")
            breath.fromValue = 0.65
            breath.toValue = 1
            loop(breath, on: wash, duration: 11 + Double(index) * 2, key: "breath")
        }
        let float = CABasicAnimation(keyPath: "transform.translation.y")
        float.fromValue = -3
        float.toValue = 3
        loop(float, on: cable, duration: 12, key: "float")
    }

    private func loop(_ animation: CABasicAnimation, on layer: CALayer, duration: Double, key: String) {
        animation.duration = duration
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        layer.add(animation, forKey: key)
    }
}
