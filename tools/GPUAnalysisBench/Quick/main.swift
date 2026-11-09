import Foundation
import Metal

setvbuf(stdout, nil, _IOLBF, 0)
let device = MTLCreateSystemDefaultDevice()!
let options = MTLCompileOptions()
options.mathMode = .safe
do { _ = try device.makeLibrary(source: GPUAnalysisShaders.source, options: options); print("compiled") } catch { print("compile error: \(error)") }
print("context", GPUAnalysisContext.shared != nil)
let seconds = Double(CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? 30 : 30)
let hop = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 128 : 128
var generator = SystemRandomNumberGenerator()
var samples = [Float](repeating: 0, count: Int(22050 * seconds))
for i in samples.indices { samples[i] = sin(Float(i) * 0.05) * 0.3 + (i % 11025 < 200 ? Float.random(in: -1...1, using: &generator) : 0) }
let t0 = Date()
let cpu = samples.withUnsafeBufferPointer { AnalysisFeatureBackend.extract($0, hop: hop, expectedSeconds: seconds, backend: .cpu) }
let t1 = Date()
let ext = GPUFeatureExtractor(hop: hop, expectedSeconds: seconds, context: GPUAnalysisContext.shared!)!
samples.withUnsafeBufferPointer { all in
    var offset = 0
    while offset < all.count {
        let end = min(all.count, offset + 8192)
        ext.consume(UnsafeBufferPointer(rebasing: all[offset..<end]))
        offset = end
    }
}
let gpu = ext.finish()
let t2 = Date()
print("cpu", t1.timeIntervalSince(t0), "gpu", t2.timeIntervalSince(t1))
print("blocks gpu", ext.gpuBlocks, "cpu", ext.cpuBlocks, cpu.low.count, gpu.low.count, cpu.chroma.count, gpu.chroma.count)
func rel(_ a: [Float], _ b: [Float]) -> Float { a.count != b.count ? -1 : (zip(a, b).map { abs($0 - $1) / max(1e-6, max(abs($0), abs($1))) }.max() ?? -1) }
print("low", rel(cpu.low, gpu.low), "lowMid", rel(cpu.lowMid, gpu.lowMid), "mid", rel(cpu.mid, gpu.mid), "high", rel(cpu.high, gpu.high), "chroma", rel(cpu.chroma, gpu.chroma), "energy", rel(cpu.bandEnergy, gpu.bandEnergy), "level", rel(cpu.level, gpu.level))
print(cpu.low[100..<104], gpu.low[100..<104])
print(cpu.chroma[24..<36], gpu.chroma[24..<36])
print(cpu.bandEnergy[24..<28], gpu.bandEnergy[24..<28])
