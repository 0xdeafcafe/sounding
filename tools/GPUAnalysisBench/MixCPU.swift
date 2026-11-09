import Foundation

enum MixCPU {
    static func threadCPU() -> Double {
        var t = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t)
        return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9
    }

    static func run(entries: [Entry], output: URL, minutes: Double) throws {
        let sr = DJEngineConstants.canonicalSampleRate
        let long = entries.filter { $0.seconds >= minutes * 60 - 15 }
        guard long.count >= 2 else { print("need two tracks over \(minutes) min"); return }
        let a = try MixSource(url: URL(fileURLWithPath: long[0].path), synchronous: true)
        let b = try MixSource(url: URL(fileURLWithPath: long[1].path), synchronous: true)
        for s in [a, b] { for i in 0..<s.chunkCount { _ = s.chunk(i) } }
        let core = MixRenderCore(sampleRate: sr)
        var seq: Int64 = 0
        func push(_ make: (Int64) -> MixCommand) { seq += 1; _ = core.ring.push(make(seq)) }
        func immediate(_ action: MixTimelineAction) { push { .event(seq: $0, time: 0, immediate: true, group: 0, action: action) } }
        push { .load(seq: $0, deck: 0, source: Unmanaged.passUnretained(a)) }
        push { .load(seq: $0, deck: 1, source: Unmanaged.passUnretained(b)) }
        immediate(.ramp(.crossfade, to: 0.5, frames: 0, curve: .linear))
        immediate(.ramp(.rate(1), to: 1.02, frames: 0, curve: .linear))
        immediate(.ramp(.eqLow(1), to: -12, frames: 0, curve: .linear))
        immediate(.ramp(.lowPass(0), to: 2_000, frames: 0, curve: .linear))
        immediate(.start(deck: 0, fromFrame: 0))
        immediate(.start(deck: 1, fromFrame: 0))
        let block = 512
        let l = UnsafeMutablePointer<Float>.allocate(capacity: block)
        let r = UnsafeMutablePointer<Float>.allocate(capacity: block)
        defer { l.deallocate(); r.deallocate() }
        var remaining = Int(minutes * 60 * sr)
        let wall0 = now(), cpu0 = threadCPU()
        var sink: Float = 0
        while remaining > 0 {
            let n = min(block, remaining)
            core.render(frames: n, left: l, right: r)
            sink += abs(l[0])
            remaining -= n
        }
        let wall = now() - wall0, cpu = threadCPU() - cpu0
        let audio = minutes * 60
        let text = """
        mix render: \(String(format: "%.0f", audio)) s of two-deck audio (crossfade 0.5, rate 1.02, EQ cut, low-pass) at \(Int(sr)) Hz, 512-frame blocks
        tracks: \(long[0].path) + \(long[1].path)
        thread CPU \(String(format: "%.2f", cpu)) s, wall \(String(format: "%.2f", wall)) s
        CPU share of real time: \(String(format: "%.2f%%", cpu / audio * 100)) of one core
        output nonzero: \(sink > 0)
        """
        print(text)
        withExtendedLifetime((a, b)) {}
        try text.write(to: output.appendingPathComponent("mix-cpu.txt"), atomically: true, encoding: .utf8)
    }
}
