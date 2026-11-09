#if canImport(Metal) && !os(watchOS)
import CoreGraphics
import Foundation
import Metal
import QuartzCore

struct MetalWaveformStyle: Equatable, Sendable {
    enum Mode: UInt32, Sendable {
        case mono = 0
        case blue = 1
        case rgb = 2
        case threeBand = 3
    }

    var mode: Mode
    var lowColor: SIMD4<Float>
    var midColor: SIMD4<Float>
    var highColor: SIMD4<Float>
    var sampleColor: SIMD4<Float>
    var playedTint: SIMD4<Float> = SIMD4(1, 1, 1, 1)
    var unplayedTint: SIMD4<Float> = SIMD4(1, 1, 1, 1)
    var playheadColor: SIMD4<Float> = SIMD4(1, 1, 1, 0.95)
    var playheadWidth: Float = 2
    var beatColor: SIMD4<Float> = SIMD4(1, 1, 1, 0.10)
    var barColor: SIMD4<Float> = SIMD4(1, 1, 1, 0.22)
    var phraseColor: SIMD4<Float> = SIMD4(1, 1, 1, 0.42)
    var verticalScale: Float = 0.94
    var cueLineWidth: Float = 1.5
    var loopFillOpacity: Float = 0.18

    static let blue = MetalWaveformStyle(
        mode: .blue,
        lowColor: SIMD4(0.05, 0.33, 0.95, 1),
        midColor: SIMD4(0.30, 0.60, 1.00, 1),
        highColor: SIMD4(0.80, 0.92, 1.00, 1),
        sampleColor: SIMD4(0.45, 0.70, 1.00, 1)
    )

    static let rgb = MetalWaveformStyle(
        mode: .rgb,
        lowColor: SIMD4(1.00, 0.10, 0.12, 1),
        midColor: SIMD4(0.15, 1.00, 0.20, 1),
        highColor: SIMD4(0.20, 0.35, 1.00, 1),
        sampleColor: SIMD4(0.90, 0.90, 0.90, 1)
    )

    static let threeBand = MetalWaveformStyle(
        mode: .threeBand,
        lowColor: SIMD4(0.10, 0.36, 0.95, 1),
        midColor: SIMD4(0.98, 0.62, 0.18, 1),
        highColor: SIMD4(0.98, 0.97, 0.94, 1),
        sampleColor: SIMD4(0.98, 0.62, 0.18, 1)
    )

    static func mono(_ color: SIMD4<Float>) -> MetalWaveformStyle {
        MetalWaveformStyle(mode: .mono, lowColor: color, midColor: color, highColor: color, sampleColor: color)
    }

    func dimmingUnplayed(_ amount: Float) -> MetalWaveformStyle {
        var style = self
        style.unplayedTint = SIMD4(repeating: amount)
        return style
    }
}

struct MetalWaveformBeatGrid: Equatable, Sendable {
    var bpm: Double
    var firstBeatSeconds: Double = 0
    var beatsPerBar: Int = 4
    var barsPerPhrase: Int = 8
}

struct MetalWaveformOverlay: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        case cue(TimeInterval)
        case loop(ClosedRange<TimeInterval>)
        case region(ClosedRange<TimeInterval>)
    }

    var id: String
    var kind: Kind
    var color: SIMD4<Float>
}

enum MetalWaveformTimeline: Equatable, Sendable {
    case range(ClosedRange<TimeInterval>, playhead: TimeInterval?)
    case following(anchor: TimeInterval, hostTime: CFTimeInterval, rate: Double, window: TimeInterval, playheadFraction: Double)

    var isAnimating: Bool {
        if case .following(_, _, let rate, _, _) = self { return rate != 0 }
        return false
    }

    func resolve(at hostTime: CFTimeInterval) -> (start: Double, end: Double, playhead: Double?) {
        switch self {
        case .range(let range, let playhead):
            return (range.lowerBound, max(range.upperBound, range.lowerBound + 1e-6), playhead)
        case .following(let anchor, let anchorHost, let rate, let window, let fraction):
            let now = anchor + (hostTime - anchorHost) * rate
            let span = max(window, 1e-6)
            let start = now - span * fraction
            return (start, start + span, now)
        }
    }
}

struct MetalWaveformFrameStats: Sendable {
    var level: Int
    var columns: Int
    var usesSamples: Bool
    var gridLines: Int
}

private struct FrameUniforms {
    var unplayedTint: SIMD4<Float>
    var playedTint: SIMD4<Float>
    var lowColor: SIMD4<Float>
    var midColor: SIMD4<Float>
    var highColor: SIMD4<Float>
    var sampleColor: SIMD4<Float>
    var playheadColor: SIMD4<Float>
    var beatColor: SIMD4<Float>
    var barColor: SIMD4<Float>
    var phraseColor: SIMD4<Float>
    var viewport: SIMD2<Float> = .zero
    var pixelScale: Float = 1
    var mode: UInt32 = 0
    var levelOffset: UInt32 = 0
    var levelCount: UInt32 = 0
    var originBin: Int32 = 0
    var originFraction: Float = 0
    var binsPerColumn: Float = 1
    var useSamples: UInt32 = 0
    var sampleCount: UInt32 = 0
    var originSample: Int32 = 0
    var originSampleFraction: Float = 0
    var samplesPerColumn: Float = 0
    var columnPhase: Float = 0
    var playheadX: Float = -1e9
    var playheadWidth: Float = 0
    var verticalScale: Float = 1
    var gridFirstX: Float = 0
    var gridPixelsPerBeat: Float = 0
    var gridFirstIndex: Int32 = 0
    var gridStride: UInt32 = 1
    var beatsPerBar: UInt32 = 4
    var barsPerPhrase: UInt32 = 8
    var startHi: Float = 0
    var startLo: Float = 0
    var pixelsPerSecond: Float = 0
    var centerY: Float = 0
    var baseBinCount: UInt32 = 0
    var sampleGain: Float = 1

    init(style: MetalWaveformStyle) {
        unplayedTint = style.unplayedTint
        playedTint = style.playedTint
        lowColor = style.lowColor
        midColor = style.midColor
        highColor = style.highColor
        sampleColor = style.sampleColor
        playheadColor = style.playheadColor
        beatColor = style.beatColor
        barColor = style.barColor
        phraseColor = style.phraseColor
        mode = style.mode.rawValue
        verticalScale = style.verticalScale
    }
}

private struct OverlayItem {
    var color: SIMD4<Float>
    var startHi: Float
    var startLo: Float
    var endHi: Float
    var endLo: Float
    var top: Float
    var bottom: Float
    var minWidth: Float
    var kind: UInt32
}

private func split(_ t: Double) -> (Float, Float) {
    let hi = Float(t)
    return (hi, Float(t - Double(hi)))
}

final class MetalWaveformRenderer: @unchecked Sendable {
    let context: MetalWaveformContext
    let pixelFormat: MTLPixelFormat
    private let waveformPipeline: MTLRenderPipelineState
    private let overlayPipeline: MTLRenderPipelineState
    private let gridPipeline: MTLRenderPipelineState
    private let playheadPipeline: MTLRenderPipelineState
    private let emptyBuffer: MTLBuffer
    private var overlayBuffer: MTLBuffer?
    private var overlayKey: [MetalWaveformOverlay] = []
    private var overlayScale: Float = 0
    private var backgroundOverlayCount = 0
    private var foregroundOverlayCount = 0

    init?(context: MetalWaveformContext? = .shared, pixelFormat: MTLPixelFormat = .bgra8Unorm) {
        guard let context else { return nil }
        self.context = context
        self.pixelFormat = pixelFormat
        func pipeline(_ vertex: String) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = context.library.makeFunction(name: vertex)
            descriptor.fragmentFunction = context.library.makeFunction(name: "waveformFragment")
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = pixelFormat
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try? context.device.makeRenderPipelineState(descriptor: descriptor)
        }
        guard let waveform = pipeline("waveformVertex"),
              let overlay = pipeline("overlayVertex"),
              let grid = pipeline("gridVertex"),
              let playhead = pipeline("playheadVertex"),
              let empty = context.device.makeBuffer(length: 64, options: .storageModeShared)
        else { return nil }
        waveformPipeline = waveform
        overlayPipeline = overlay
        gridPipeline = grid
        playheadPipeline = playhead
        emptyBuffer = empty
    }

    private func updateOverlays(_ overlays: [MetalWaveformOverlay], style: MetalWaveformStyle, scale: Float) {
        guard overlays != overlayKey || scale != overlayScale || overlayBuffer == nil else { return }
        overlayKey = overlays
        overlayScale = scale
        var background: [OverlayItem] = [], foreground: [OverlayItem] = []
        func item(_ a: Double, _ b: Double, _ color: SIMD4<Float>, top: Float = 0, bottom: Float = 1, minWidth: Float, kind: UInt32) -> OverlayItem {
            let s = split(a), e = split(b)
            return OverlayItem(color: color, startHi: s.0, startLo: s.1, endHi: e.0, endLo: e.1, top: top, bottom: bottom, minWidth: minWidth, kind: kind)
        }
        for overlay in overlays {
            switch overlay.kind {
            case .cue(let t):
                foreground.append(item(t, t, overlay.color, minWidth: style.cueLineWidth * scale, kind: 0))
                foreground.append(item(t, t, overlay.color, bottom: 0.07, minWidth: 7 * scale, kind: 0))
            case .loop(let range):
                var fill = overlay.color
                fill.w *= style.loopFillOpacity
                background.append(item(range.lowerBound, range.upperBound, fill, minWidth: 0, kind: 1))
                foreground.append(item(range.lowerBound, range.lowerBound, overlay.color, minWidth: style.cueLineWidth * scale, kind: 0))
                foreground.append(item(range.upperBound, range.upperBound, overlay.color, minWidth: style.cueLineWidth * scale, kind: 0))
            case .region(let range):
                background.append(item(range.lowerBound, range.upperBound, overlay.color, minWidth: 0, kind: 1))
            }
        }
        backgroundOverlayCount = background.count
        foregroundOverlayCount = foreground.count
        let all = background + foreground
        overlayBuffer = all.isEmpty ? nil : all.withUnsafeBytes {
            context.device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
    }

    @discardableResult
    func encode(
        into encoder: MTLRenderCommandEncoder,
        source: MetalWaveformSource?,
        timeline: MetalWaveformTimeline,
        hostTime: CFTimeInterval = CACurrentMediaTime(),
        grid: MetalWaveformBeatGrid?,
        overlays: [MetalWaveformOverlay],
        style: MetalWaveformStyle,
        drawableSize: CGSize,
        scale: CGFloat
    ) -> MetalWaveformFrameStats {
        let width = Double(drawableSize.width), height = Double(drawableSize.height)
        guard width >= 1, height >= 1 else { return MetalWaveformFrameStats(level: 0, columns: 0, usesSamples: false, gridLines: 0) }
        let view = timeline.resolve(at: hostTime)
        let secondsPerPixel = (view.end - view.start) / width
        let slot = (view.start / secondsPerPixel).rounded(.down)
        let slotStart = slot * secondsPerPixel
        let pixelScale = Float(scale)

        var u = FrameUniforms(style: style)
        u.viewport = SIMD2(Float(width), Float(height))
        u.pixelScale = pixelScale
        u.columnPhase = Float(view.start / secondsPerPixel - slot)
        u.centerY = Float(height / 2)
        u.pixelsPerSecond = Float(1 / secondsPerPixel)
        (u.startHi, u.startLo) = split(view.start)
        u.playheadWidth = style.playheadWidth * pixelScale
        if let playhead = view.playhead { u.playheadX = Float((playhead - view.start) / secondsPerPixel) }

        let columns = Int(width.rounded(.up)) + 1
        var level = 0
        var usesSamples = false
        if let source {
            let basePerPixel = source.binsPerSecond * secondsPerPixel
            level = max(0, min(source.levelOffsets.count - 1, Int(log2(max(basePerPixel, 1)).rounded(.down))))
            let levelScale = Double(1 << level)
            let startBin = slotStart * source.binsPerSecond / levelScale
            let origin = startBin.rounded(.down)
            u.levelOffset = UInt32(source.levelOffsets[level])
            u.levelCount = UInt32(source.levelCounts[level])
            u.baseBinCount = UInt32(source.levelCounts[0])
            u.originBin = Int32(clamping: Int(origin))
            u.originFraction = Float(startBin - origin)
            u.binsPerColumn = Float(basePerPixel / levelScale)
            if source.pcm != nil, source.sampleRate > 0 {
                let samplesPerPixel = source.sampleRate * secondsPerPixel
                if samplesPerPixel < Double(WaveformPyramid.samplesPerBaseBin) {
                    usesSamples = true
                    let startSample = slotStart * source.sampleRate
                    let originSample = startSample.rounded(.down)
                    u.useSamples = 1
                    u.sampleCount = UInt32(source.sampleCount)
                    u.originSample = Int32(clamping: Int(originSample))
                    u.originSampleFraction = Float(startSample - originSample)
                    u.samplesPerColumn = Float(samplesPerPixel)
                    u.sampleGain = source.sampleGain
                }
            }
        }

        var gridLines = 0
        if let grid, grid.bpm > 0 {
            let beat = 60 / grid.bpm
            let pixelsPerBeat = beat / secondsPerPixel
            let perBar = max(1, grid.beatsPerBar), perPhrase = perBar * max(1, grid.barsPerPhrase)
            let minimumSpacing = 9 * Double(scale)
            let candidates = [1, perBar, perPhrase] + [2, 4, 8, 16, 32, 64, 128].map { perPhrase * $0 }
            let stride = candidates.first { pixelsPerBeat * Double($0) >= minimumSpacing } ?? candidates[candidates.count - 1]
            let firstIndexRaw = ((view.start - grid.firstBeatSeconds) / beat).rounded(.up)
            var first = Int(firstIndexRaw)
            let remainder = ((first % stride) + stride) % stride
            if remainder != 0 { first += stride - remainder }
            let firstTime = grid.firstBeatSeconds + Double(first) * beat
            let count = Int(((view.end - firstTime) / (beat * Double(stride))).rounded(.down)) + 1
            gridLines = max(0, min(count, 8192))
            u.gridFirstIndex = Int32(clamping: first)
            u.gridFirstX = Float((firstTime - view.start) / secondsPerPixel)
            u.gridPixelsPerBeat = Float(pixelsPerBeat)
            u.gridStride = UInt32(stride)
            u.beatsPerBar = UInt32(perBar)
            u.barsPerPhrase = UInt32(max(1, grid.barsPerPhrase))
        }

        updateOverlays(overlays, style: style, scale: pixelScale)
        let length = MemoryLayout<FrameUniforms>.stride

        if let overlayBuffer, backgroundOverlayCount > 0 {
            encoder.setRenderPipelineState(overlayPipeline)
            encoder.setVertexBuffer(overlayBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&u, length: length, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: backgroundOverlayCount)
        }
        if gridLines > 0 {
            encoder.setRenderPipelineState(gridPipeline)
            encoder.setVertexBytes(&u, length: length, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: gridLines)
        }
        if let source {
            encoder.setRenderPipelineState(waveformPipeline)
            encoder.setVertexBuffer(source.bins, offset: 0, index: 0)
            encoder.setVertexBuffer(source.pcm ?? emptyBuffer, offset: 0, index: 1)
            encoder.setVertexBytes(&u, length: length, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: columns * (style.mode == .threeBand ? 3 : 1))
        }
        if let overlayBuffer, foregroundOverlayCount > 0 {
            encoder.setRenderPipelineState(overlayPipeline)
            encoder.setVertexBuffer(overlayBuffer, offset: backgroundOverlayCount * MemoryLayout<OverlayItem>.stride, index: 0)
            encoder.setVertexBytes(&u, length: length, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: foregroundOverlayCount)
        }
        if view.playhead != nil, style.playheadWidth > 0 {
            encoder.setRenderPipelineState(playheadPipeline)
            encoder.setVertexBytes(&u, length: length, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        return MetalWaveformFrameStats(level: level, columns: columns, usesSamples: usesSamples, gridLines: gridLines)
    }

    func snapshot(
        source: MetalWaveformSource?,
        timeline: MetalWaveformTimeline,
        grid: MetalWaveformBeatGrid? = nil,
        overlays: [MetalWaveformOverlay] = [],
        style: MetalWaveformStyle,
        size: CGSize,
        scale: CGFloat,
        background: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    ) -> (image: CGImage?, gpuSeconds: Double, encodeSeconds: Double, stats: MetalWaveformFrameStats)? {
        let pixels = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: Int(pixels.width), height: Int(pixels.height), mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        #if os(macOS)
        descriptor.storageMode = context.device.hasUnifiedMemory ? .shared : .managed
        #else
        descriptor.storageMode = .shared
        #endif
        guard let texture = context.device.makeTexture(descriptor: descriptor),
              let commands = context.queue.makeCommandBuffer()
        else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = background
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        let begin = CACurrentMediaTime()
        let stats = encode(into: encoder, source: source, timeline: timeline, grid: grid, overlays: overlays, style: style, drawableSize: pixels, scale: scale)
        encoder.endEncoding()
        let encodeSeconds = CACurrentMediaTime() - begin
        #if os(macOS)
        if texture.storageMode == .managed, let blit = commands.makeBlitCommandEncoder() {
            blit.synchronize(resource: texture)
            blit.endEncoding()
        }
        #endif
        commands.commit()
        commands.waitUntilCompleted()
        let gpu = commands.gpuEndTime - commands.gpuStartTime
        let width = texture.width, height = texture.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        let image = CGDataProvider(data: Data(bytes) as CFData).flatMap {
            CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: $0, decode: nil,
                    shouldInterpolate: false, intent: .defaultIntent)
        }
        return (image, gpu, encodeSeconds, stats)
    }
}
#endif
