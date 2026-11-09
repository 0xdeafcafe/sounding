#if canImport(MetalKit) && !os(watchOS)
import MetalKit
import SwiftUI

extension SIMD4 where Scalar == Float {
    init(_ color: Color) {
        let resolved = color.resolve(in: EnvironmentValues())
        self.init(resolved.red, resolved.green, resolved.blue, resolved.opacity)
    }
}

final class MetalWaveformSourceCache: @unchecked Sendable {
    static let shared = MetalWaveformSourceCache()

    private let lock = NSLock()
    private var entries: [String: MetalWaveformSource] = [:]
    private var order: [String] = []
    private let limit = 16

    func envelope(id: String, samples: [Float], duration: TimeInterval) -> MetalWaveformSource? {
        guard !samples.isEmpty, duration > 0 else { return nil }
        let key = "\(id)|\(samples.count)|\(duration)"
        lock.lock()
        defer { lock.unlock() }
        if let hit = entries[key] { return hit }
        guard let source = MetalWaveformSource.envelope(id: key, samples: samples, duration: duration) else { return nil }
        entries[key] = source
        order.append(key)
        if order.count > limit { entries[order.removeFirst()] = nil }
        return source
    }
}

struct MetalWaveformView: View {
    var source: MetalWaveformSource?
    var timeline: MetalWaveformTimeline
    var grid: MetalWaveformBeatGrid?
    var overlays: [MetalWaveformOverlay] = []
    var style: MetalWaveformStyle = .blue

    static var isSupported: Bool { MetalWaveformContext.shared != nil }

    var body: some View {
        MetalWaveformSurface(configuration: MetalWaveformConfiguration(
            source: source, timeline: timeline, grid: grid, overlays: overlays, style: style
        ))
    }
}

struct MetalWaveformConfiguration {
    var source: MetalWaveformSource?
    var timeline: MetalWaveformTimeline
    var grid: MetalWaveformBeatGrid?
    var overlays: [MetalWaveformOverlay]
    var style: MetalWaveformStyle
}

@MainActor
final class MetalWaveformCoordinator: NSObject, MTKViewDelegate {
    var configuration: MetalWaveformConfiguration
    let renderer: MetalWaveformRenderer?

    init(configuration: MetalWaveformConfiguration) {
        self.configuration = configuration
        renderer = MetalWaveformRenderer()
    }

    func makeView() -> MTKView {
        let view = MTKView(frame: .zero, device: renderer?.context.device)
        view.delegate = self
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.framebufferOnly = true
        view.autoResizeDrawable = true
        #if os(macOS)
        view.layer?.isOpaque = false
        #else
        view.isOpaque = false
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        #endif
        apply(to: view)
        return view
    }

    func apply(to view: MTKView) {
        let animating = configuration.timeline.isAnimating
        let thermal = ProcessInfo.processInfo.thermalState
        let constrained = ProcessInfo.processInfo.isLowPowerModeEnabled || thermal == .serious || thermal == .critical
        view.preferredFramesPerSecond = constrained ? 30 : 120
        view.enableSetNeedsDisplay = !animating
        view.isPaused = !animating
        if !animating {
            #if os(macOS)
            view.needsDisplay = true
            #else
            view.setNeedsDisplay()
            #endif
        }
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { render(in: view) }
    }

    private func render(in view: MTKView) {
        guard let renderer,
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commands = renderer.context.queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass)
        else { return }
        let size = view.drawableSize
        let scale = view.bounds.width > 0 ? size.width / view.bounds.width : 1
        renderer.encode(
            into: encoder,
            source: configuration.source,
            timeline: configuration.timeline,
            grid: configuration.grid,
            overlays: configuration.overlays,
            style: configuration.style,
            drawableSize: size,
            scale: scale
        )
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}

#if os(macOS)
struct MetalWaveformSurface: NSViewRepresentable {
    var configuration: MetalWaveformConfiguration

    func makeCoordinator() -> MetalWaveformCoordinator { MetalWaveformCoordinator(configuration: configuration) }
    func makeNSView(context: Context) -> MTKView { context.coordinator.makeView() }
    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.configuration = configuration
        context.coordinator.apply(to: view)
    }
}
#else
struct MetalWaveformSurface: UIViewRepresentable {
    var configuration: MetalWaveformConfiguration

    func makeCoordinator() -> MetalWaveformCoordinator { MetalWaveformCoordinator(configuration: configuration) }
    func makeUIView(context: Context) -> MTKView { context.coordinator.makeView() }
    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.configuration = configuration
        context.coordinator.apply(to: view)
    }
}
#endif
#endif
