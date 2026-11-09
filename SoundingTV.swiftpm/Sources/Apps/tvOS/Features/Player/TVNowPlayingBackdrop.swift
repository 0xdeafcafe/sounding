import SwiftUI
import UIKit
import CoreImage

struct NPBackdrop: UIViewRepresentable {
    let artworkURL: URL?
    let palette: ArtworkColors.Palette
    let isAnimating: Bool

    func makeUIView(context: Context) -> NPBackdropView {
        NPBackdropView()
    }

    func updateUIView(_ view: NPBackdropView, context: Context) {
        view.apply(url: artworkURL, palette: palette, isAnimating: isAnimating)
    }
}

final class NPBackdropView: UIView {
    private var currentURL: URL?
    private var loadTask: Task<Void, Never>?
    private var stack: NPBackdropStack?
    private var palette: ArtworkColors.Palette = .fallback
    private var isAnimating = false
    private var hasImage = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        backgroundColor = UIColor(ArtworkColors.Palette.fallback.primary)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        loadTask?.cancel()
    }

    func apply(url: URL?, palette: ArtworkColors.Palette, isAnimating: Bool) {
        let paletteChanged = palette != self.palette
        self.palette = palette
        if paletteChanged {
            UIView.animate(withDuration: 1.1) {
                self.backgroundColor = UIColor(palette.primary)
            }
            stack?.setPalette(palette, duration: 1.1)
        }
        if isAnimating != self.isAnimating {
            self.isAnimating = isAnimating
            stack?.setAnimating(isAnimating)
        }
        guard url != currentURL else { return }
        currentURL = url
        loadTask?.cancel()
        guard let url else {
            retire(stack, duration: 0.6)
            stack = nil
            hasImage = false
            return
        }
        loadTask = Task { [weak self] in
            let image: UIImage?
            if let cached = ArtworkCache.shared.cachedImage(for: url, variant: .standard) {
                image = cached
            } else {
                image = await ArtworkCache.shared.image(for: url, variant: .standard)
            }
            guard let image, !Task.isCancelled else { return }
            let blurred = await Task.detached(priority: .utility) { NPBackdropImage.blurred(image) }.value
            guard let blurred, !Task.isCancelled, let self, self.currentURL == url else { return }
            self.present(blurred)
        }
    }

    private func present(_ image: CGImage) {
        let incoming = NPBackdropStack(image: image, palette: palette)
        incoming.frame = bounds
        incoming.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        incoming.setAnimating(isAnimating)
        let outgoing = stack
        stack = incoming
        addSubview(incoming)
        if hasImage {
            incoming.alpha = 0
            UIView.animate(withDuration: 1.1, delay: 0, options: [.curveEaseInOut]) {
                incoming.alpha = 1
            }
            retire(outgoing, duration: 1.3)
        } else {
            retire(outgoing, duration: 0)
        }
        hasImage = true
    }

    private func retire(_ old: NPBackdropStack?, duration: TimeInterval) {
        guard let old else { return }
        if duration <= 0 {
            old.removeFromSuperview()
            return
        }
        UIView.animate(withDuration: duration, delay: 0.2, options: [.curveEaseInOut]) {
            old.alpha = 0
        } completion: { _ in
            old.removeFromSuperview()
        }
    }
}

private final class NPBackdropStack: UIView {
    private let imageLayer = CALayer()
    private let swirlLayer = CALayer()
    private let blobs = [CAGradientLayer(), CAGradientLayer(), CAGradientLayer()]
    private var animating = false

    init(image: CGImage, palette: ArtworkColors.Palette) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        for layer in [imageLayer, swirlLayer] {
            layer.contents = image
            layer.contentsGravity = .resizeAspectFill
            layer.magnificationFilter = .linear
            layer.minificationFilter = .linear
            self.layer.addSublayer(layer)
        }
        swirlLayer.opacity = 0.55
        for blob in blobs {
            blob.type = .radial
            blob.startPoint = CGPoint(x: 0.5, y: 0.5)
            blob.endPoint = CGPoint(x: 1, y: 1)
            blob.locations = [0, 1]
            layer.addSublayer(blob)
        }
        setPalette(palette, duration: 0)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let wasAnimating = animating
        if wasAnimating { stopMotion() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let size = bounds.size
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        imageLayer.bounds = CGRect(x: 0, y: 0, width: size.width * 1.6, height: size.height * 1.6)
        imageLayer.position = center
        swirlLayer.bounds = CGRect(x: 0, y: 0, width: size.width * 1.9, height: size.height * 1.9)
        swirlLayer.position = center
        swirlLayer.setAffineTransform(CGAffineTransform(rotationAngle: .pi))
        let blobSize = size.width * 0.95
        blobs[0].bounds = CGRect(x: 0, y: 0, width: blobSize, height: blobSize)
        blobs[0].position = CGPoint(x: blobSize * 0.15, y: blobSize * 0.3)
        blobs[1].bounds = CGRect(x: 0, y: 0, width: blobSize, height: blobSize)
        blobs[1].position = CGPoint(x: size.width - blobSize * 0.1, y: size.height - blobSize * 0.2)
        blobs[2].bounds = CGRect(x: 0, y: 0, width: blobSize * 0.7, height: blobSize * 0.7)
        blobs[2].position = CGPoint(x: size.width * 0.45, y: size.height * 0.65)
        CATransaction.commit()
        if wasAnimating { startMotion() }
    }

    func setPalette(_ palette: ArtworkColors.Palette, duration: TimeInterval) {
        CATransaction.begin()
        if duration > 0 {
            CATransaction.setAnimationDuration(duration)
        } else {
            CATransaction.setDisableActions(true)
        }
        let tints: [(UIColor, CGFloat)] = [
            (UIColor(palette.accent), 0.36),
            (UIColor(palette.secondary), 0.46),
            (UIColor(palette.accent), 0.26),
        ]
        for (blob, tint) in zip(blobs, tints) {
            blob.colors = [tint.0.withAlphaComponent(tint.1).cgColor, tint.0.withAlphaComponent(0).cgColor]
        }
        CATransaction.commit()
    }

    func setAnimating(_ active: Bool) {
        guard active != animating else { return }
        animating = active
        if active { startMotion() } else { stopMotion() }
    }

    private func startMotion() {
        guard bounds.width > 0 else { return }
        let size = bounds.size
        imageLayer.add(
            Self.drift(
                from: Self.transform(x: -0.04, y: -0.03, degrees: -6, scale: 1.02, size: size),
                to: Self.transform(x: 0.04, y: 0.03, degrees: 8, scale: 1.16, size: size),
                duration: 41
            ),
            forKey: "drift"
        )
        var swirlFrom = Self.transform(x: 0.05, y: -0.04, degrees: 0, scale: 1, size: size)
        swirlFrom = CATransform3DRotate(swirlFrom, .pi, 0, 0, 1)
        var swirlTo = Self.transform(x: -0.05, y: 0.05, degrees: 0, scale: 1.18, size: size)
        swirlTo = CATransform3DRotate(swirlTo, .pi + 0.32, 0, 0, 1)
        swirlLayer.add(Self.drift(from: swirlFrom, to: swirlTo, duration: 57), forKey: "drift")
        let travel: [(CGFloat, CGFloat, Double)] = [(0.16, 0.12, 31), (-0.16, -0.12, 38), (0.08, -0.1, 27)]
        for (blob, motion) in zip(blobs, travel) {
            blob.add(
                Self.drift(
                    from: CATransform3DIdentity,
                    to: Self.transform(x: motion.0, y: motion.1, degrees: 0, scale: 1.22, size: size),
                    duration: motion.2
                ),
                forKey: "drift"
            )
        }
    }

    private func stopMotion() {
        imageLayer.removeAnimation(forKey: "drift")
        swirlLayer.removeAnimation(forKey: "drift")
        for blob in blobs { blob.removeAnimation(forKey: "drift") }
    }

    private static func transform(x: CGFloat, y: CGFloat, degrees: CGFloat, scale: CGFloat, size: CGSize) -> CATransform3D {
        var t = CATransform3DMakeTranslation(x * size.width, y * size.height, 0)
        t = CATransform3DRotate(t, degrees * .pi / 180, 0, 0, 1)
        return CATransform3DScale(t, scale, scale, 1)
    }

    private static func drift(from: CATransform3D, to: CATransform3D, duration: CFTimeInterval) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: from)
        animation.toValue = NSValue(caTransform3D: to)
        animation.duration = duration
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.isRemovedOnCompletion = false
        return animation
    }
}

enum NPBackdropImage {
    nonisolated private static let context = CIContext(options: [.workingColorSpace: NSNull()])

    nonisolated static func blurred(_ image: UIImage) -> CGImage? {
        guard let source = image.cgImage else { return nil }
        let input = CIImage(cgImage: source)
        let longest = max(input.extent.width, input.extent.height)
        guard longest > 0 else { return nil }
        let scale = min(1, 128 / longest)
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let blurred = small
            .clampedToExtent()
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.35])
            .applyingGaussianBlur(sigma: 9)
            .cropped(to: small.extent)
        return context.createCGImage(blurred, from: small.extent)
    }
}

struct NPLegibilityScrim: View {
    let palette: ArtworkColors.Palette

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let base = Self.base(for: palette.rawMean, increased: contrast == .increased)
        ZStack {
            Color.black.opacity(base)
            LinearGradient(
                colors: [Color.black.opacity(0), Color.black.opacity(0.3)],
                startPoint: .top,
                endPoint: .bottom
            )
            LinearGradient(
                colors: [Color.black.opacity(0.16), .clear, Color.black.opacity(0.2)],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    static func base(for mean: SCAmbient.RGB, increased: Bool) -> Double {
        let lifted = SCAmbient.RGB(r: min(1, mean.r * 1.35), g: min(1, mean.g * 1.35), b: min(1, mean.b * 1.35))
        let scrim = SCAmbient.legibilityScrim(over: lifted, textOpacity: 0.66, minimumContrast: increased ? 7 : 4.5)
        return min(0.78, max(increased ? 0.32 : 0.16, scrim))
    }
}
