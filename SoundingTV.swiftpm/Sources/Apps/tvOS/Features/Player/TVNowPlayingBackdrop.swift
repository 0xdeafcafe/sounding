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
        let incoming = NPBackdropStack(image: image)
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
            incoming.alpha = 0
            UIView.animate(withDuration: 0.5) {
                incoming.alpha = 1
            }
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
    private var animating = false

    init(image: CGImage) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        imageLayer.contents = image
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .linear
        layer.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let wasAnimating = animating
        if wasAnimating { stopMotion() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let size = bounds.size
        imageLayer.bounds = CGRect(x: 0, y: 0, width: size.width * 1.2, height: size.height * 1.2)
        imageLayer.position = CGPoint(x: size.width / 2, y: size.height / 2)
        CATransaction.commit()
        if wasAnimating { startMotion() }
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
                from: Self.transform(x: -0.025, y: -0.02, scale: 1, size: size),
                to: Self.transform(x: 0.025, y: 0.02, scale: 1.08, size: size),
                duration: 46
            ),
            forKey: "drift"
        )
    }

    private func stopMotion() {
        imageLayer.removeAnimation(forKey: "drift")
    }

    private static func transform(x: CGFloat, y: CGFloat, scale: CGFloat, size: CGSize) -> CATransform3D {
        let t = CATransform3DMakeTranslation(x * size.width, y * size.height, 0)
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
        let scale = min(1, 240 / longest)
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let blurred = small
            .clampedToExtent()
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.3])
            .applyingGaussianBlur(sigma: 3.5)
            .cropped(to: small.extent)
        return context.createCGImage(blurred, from: small.extent)
    }
}

struct NPLegibilityScrim: View {
    let palette: ArtworkColors.Palette
    var extraDarkening: Double = 0

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let base = Self.base(for: palette.rawMean, increased: contrast == .increased)
        ZStack {
            Color.black.opacity(min(0.8, base + extraDarkening))
            LinearGradient(
                stops: [
                    .init(color: Color.black.opacity(0.32), location: 0),
                    .init(color: Color.black.opacity(0.08), location: 0.45),
                    .init(color: Color.black.opacity(0.5), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    static func base(for mean: SCAmbient.RGB, increased: Bool) -> Double {
        let scrim = SCAmbient.legibilityScrim(over: mean, textOpacity: 0.66, minimumContrast: increased ? 7 : 4.5)
        return min(increased ? 0.7 : 0.58, max(increased ? 0.5 : 0.4, scrim))
    }
}

struct NPCoverBackdrop: View {
    let artworkURL: URL?
    let palette: ArtworkColors.Palette

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            NPBackdrop(artworkURL: artworkURL, palette: palette, isAnimating: !reduceMotion && scenePhase == .active)
            NPLegibilityScrim(palette: palette, extraDarkening: 0.1)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
