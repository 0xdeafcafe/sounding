import Foundation

// MARK: - ANLZ folder hashing

enum DJAnalysisPath {
    static func hash(_ devicePath: String) -> (folder: UInt32, hash: UInt32) {
        var value: UInt32 = 0
        for unit in devicePath.utf16 {
            let temp = value &* 0x5BC9 &+ UInt32(unit)
            value = temp &* 0x93B5 &+ UInt32(unit)
        }
        let h = value % 200_003
        var p: UInt32 = 0
        p |= (h >> 0) & 0x01
        p |= (h >> 1) & 0x02
        p |= (h >> 4) & 0x04
        p |= (h >> 4) & 0x08
        p |= (h >> 5) & 0x10
        p |= (h >> 8) & 0x20
        p |= (h >> 10) & 0x40
        return (p, h)
    }

    static func directory(for devicePath: String) -> String {
        let (p, h) = hash(devicePath)
        return "/PIONEER/USBANLZ/" + String(format: "P%03X/%08X", p, h)
    }
}

// MARK: - Colours

enum DJMediaColor {
    static let hotCuePalette: [(code: UInt8, rgb: UInt32)] = [
        (0x01, 0x305AFF), (0x02, 0x5073FF), (0x03, 0x508CFF), (0x04, 0x50A0FF), (0x05, 0x50B4FF),
        (0x06, 0x50B0F2), (0x07, 0x50AEE8), (0x08, 0x45ACDB), (0x09, 0x00E0FF), (0x0A, 0x19DAF0),
        (0x0B, 0x32D2E6), (0x0C, 0x21B4B9), (0x0D, 0x20AAA0), (0x0E, 0x1FA392), (0x0F, 0x19A08C),
        (0x10, 0x14A584), (0x11, 0x14AA7D), (0x12, 0x10B176), (0x13, 0x30D26E), (0x14, 0x37DE5A),
        (0x15, 0x3CEB50), (0x16, 0x28E214), (0x17, 0x7DC13D), (0x18, 0x8CC832), (0x19, 0x9BD723),
        (0x1A, 0xA5E116), (0x1B, 0xA5DC0A), (0x1C, 0xAAD208), (0x1D, 0xB4C805), (0x1E, 0xB4BE04),
        (0x1F, 0xBAB404), (0x20, 0xC3AF04), (0x21, 0xE1AA00), (0x22, 0xFFA000), (0x23, 0xFF9600),
        (0x24, 0xFF8C00), (0x25, 0xFF7500), (0x26, 0xE0641B), (0x27, 0xE0461E), (0x28, 0xE0301E),
        (0x29, 0xE02823), (0x2A, 0xE62828), (0x2B, 0xFF376F), (0x2C, 0xFF2D6F), (0x2D, 0xFF127B),
        (0x2E, 0xF51E8C), (0x2F, 0xEB2DA0), (0x30, 0xE637B4), (0x31, 0xDE44CF), (0x32, 0xDE448D),
        (0x33, 0xE630B4), (0x34, 0xE619DC), (0x35, 0xE600FF), (0x36, 0xDC00FF), (0x37, 0xCC00FF),
        (0x38, 0xB432FF), (0x39, 0xB93CFF), (0x3A, 0xC542FF), (0x3B, 0xAA5AFF), (0x3C, 0xAA72FF),
        (0x3D, 0x8272FF), (0x3E, 0x6473FF),
    ]

    static func distance(_ a: UInt32, _ b: UInt32) -> Int {
        let dr = Int((a >> 16) & 0xFF) - Int((b >> 16) & 0xFF)
        let dg = Int((a >> 8) & 0xFF) - Int((b >> 8) & 0xFF)
        let db = Int(a & 0xFF) - Int(b & 0xFF)
        return dr * dr * 3 + dg * dg * 4 + db * db * 2
    }

    static func hotCueColor(_ rgb: UInt32) -> (code: UInt8, rgb: UInt32) {
        hotCuePalette.min { distance($0.rgb, rgb) < distance($1.rgb, rgb) } ?? (0, 0)
    }

    static func trackColorId(_ rgb: UInt32?) -> UInt8 {
        guard let rgb else { return 0 }
        var best: (UInt8, Int) = (0, Int.max)
        for (id, c) in PDBDefaults.colorRGB {
            let d = distance(UInt32(c.0) << 16 | UInt32(c.1) << 8 | UInt32(c.2), rgb & 0xFFFFFF)
            if d < best.1 || (d == best.1 && id < best.0) { best = (id, d) }
        }
        return best.0
    }
}

// MARK: - Device paths

enum DJDevicePath {
    static let illegal = Set("\\/:*?\"<>|".unicodeScalars)
    static let maxComponentLength = 64

    static func component(_ raw: String, fallback: String) -> String {
        var scalars = String.UnicodeScalarView()
        for s in raw.precomposedStringWithCanonicalMapping.unicodeScalars {
            if illegal.contains(s) || s.value < 0x20 || s.value == 0x7F {
                scalars.append("_")
            } else {
                scalars.append(s)
            }
        }
        var out = String(scalars).trimmingCharacters(in: .whitespaces)
        while out.hasSuffix(".") { out.removeLast() }
        while out.hasPrefix(".") { out.removeFirst() }
        if out.count > maxComponentLength { out = String(out.prefix(maxComponentLength)).trimmingCharacters(in: .whitespaces) }
        return out.isEmpty ? fallback : out
    }

    static func fileName(_ raw: String, fallback: String) -> String {
        let ns = raw as NSString
        let ext = component(ns.pathExtension, fallback: "").lowercased()
        let stem = component(ns.deletingPathExtension, fallback: fallback)
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }
}

// MARK: - Grid, cues and phrases

enum DJAnalysisMapping {
    static func millis(_ seconds: Double) -> UInt32 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return UInt32(min(seconds * 1000, Double(UInt32.max - 1)).rounded())
    }

    static func tempo(_ bpm: Double) -> UInt16 {
        guard bpm.isFinite, bpm > 0 else { return 0 }
        return UInt16(min(bpm * 100, Double(UInt16.max)).rounded())
    }

    static func beats(for grid: DJExportBeatGrid, duration: Double) -> [ANLZBeat] {
        let period = grid.beatPeriod
        guard period > 0.15, period < 3, duration > 0 else { return [] }
        let tempo = tempo(grid.bpm)
        let perBar = max(1, min(grid.beatsPerBar, 16))
        var times: [Double] = []
        var barPosition: [Int] = []
        if let explicit = grid.beats?.filter({ $0 >= 0 && $0 <= duration }).sorted(), explicit.count >= 2 {
            times = explicit
            let downbeats = (grid.downbeats ?? []).sorted()
            var nextDownbeat = 0
            var isDownbeat: [Bool] = []
            for t in times {
                while nextDownbeat < downbeats.count, downbeats[nextDownbeat] < t - period / 2 { nextDownbeat += 1 }
                let hit = nextDownbeat < downbeats.count && abs(downbeats[nextDownbeat] - t) <= period / 2
                if hit { nextDownbeat += 1 }
                isDownbeat.append(hit)
            }
            let firstDownbeat = isDownbeat.firstIndex(of: true) ?? grid.firstDownbeatOffset
            var position = ((-firstDownbeat % perBar) + perBar) % perBar
            for hit in isDownbeat {
                if hit { position = 0 }
                barPosition.append(position)
                position = (position + 1) % perBar
            }
        } else {
            var first = grid.firstBeatSeconds
            var skipped = 0
            if first < 0 {
                let n = Int((-first / period).rounded(.up))
                first += Double(n) * period
                skipped = n
            } else if first >= period {
                let n = Int((first / period).rounded(.down))
                first -= Double(n) * period
                skipped = -n
            }
            var position = (((skipped - grid.firstDownbeatOffset) % perBar) + perBar) % perBar
            var t = first
            while t <= duration {
                times.append(t)
                barPosition.append(position)
                position = (position + 1) % perBar
                t += period
            }
        }
        return zip(times, barPosition).map { ANLZBeat(beatNumber: UInt16($1 + 1), tempo: tempo, timeMillis: millis($0)) }
    }

    static func beatIndex(of seconds: Double, in beats: [ANLZBeat]) -> UInt16 {
        guard !beats.isEmpty else { return 1 }
        let target = millis(seconds)
        var lo = 0, hi = beats.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if beats[mid].timeMillis < target { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0, target - beats[lo - 1].timeMillis < beats[lo].timeMillis &- target { lo -= 1 }
        return UInt16(clamping: lo + 1)
    }

    static func cueLists(_ cues: [DJExportCue], grid: DJExportBeatGrid?) -> (hot: [ANLZCue], memory: [ANLZCue]) {
        var hot: [ANLZCue] = []
        var memory: [ANLZCue] = []
        var usedSlots = Set<Int>()
        for cue in cues.sorted(by: { $0.startSeconds < $1.startSeconds }) {
            var a = ANLZCue(timeMillis: millis(cue.startSeconds))
            if cue.isLoop, let end = cue.endSeconds {
                a.isLoop = true
                a.loopTimeMillis = millis(end)
                if let grid, grid.beatPeriod > 0 {
                    let fraction = quantisedLoop(beats: (end - cue.startSeconds) / grid.beatPeriod)
                    a.loopNumerator = fraction.0
                    a.loopDenominator = fraction.1
                }
            }
            switch cue.role {
            case .hotCue(let slot):
                guard (0 ..< 8).contains(slot), !usedSlots.contains(slot) else { continue }
                usedSlots.insert(slot)
                a.hotCue = UInt32(slot + 1)
                a.comment = cue.label
                let palette = DJMediaColor.hotCueColor(cue.colorRGB ?? 0x28E214)
                a.colorCode = palette.code
                a.colorRed = UInt8((palette.rgb >> 16) & 0xFF)
                a.colorGreen = UInt8((palette.rgb >> 8) & 0xFF)
                a.colorBlue = UInt8(palette.rgb & 0xFF)
                hot.append(a)
            case .memory, .mixIn, .mixOut:
                a.comment = cue.label.isEmpty ? defaultLabel(cue.role) : cue.label
                a.colorId = DJMediaColor.trackColorId(cue.colorRGB)
                memory.append(a)
            }
        }
        hot.sort { $0.hotCue < $1.hotCue }
        return (hot, memory)
    }

    static func defaultLabel(_ role: DJExportCue.Role) -> String {
        switch role {
        case .mixIn: return "Mix In"
        case .mixOut: return "Mix Out"
        default: return ""
        }
    }

    static func quantisedLoop(beats: Double) -> (UInt16, UInt16) {
        guard beats.isFinite, beats > 0 else { return (0, 0) }
        for k in -5 ... 9 {
            let size = pow(2.0, Double(k))
            if abs(beats - size) / size < 0.02 {
                return k >= 0 ? (UInt16(size), 1) : (1, UInt16(1 / size))
            }
        }
        return (0, 0)
    }

    static func songStructure(_ input: DJExportPhrases, beats: [ANLZBeat], duration: Double) -> ANLZSongStructure? {
        let sorted = input.phrases.filter { $0.startSeconds >= 0 && $0.startSeconds < duration }
            .sorted { $0.startSeconds < $1.startSeconds }
        guard !sorted.isEmpty, !beats.isEmpty else { return nil }
        let mood = input.mood ?? inferMood(sorted)
        var phrases: [ANLZPhrase] = []
        var lastBeat: UInt16 = 0
        for p in sorted {
            let beat = beatIndex(of: p.startSeconds, in: beats)
            guard beat > lastBeat else { continue }
            lastBeat = beat
            var phrase = ANLZPhrase(index: UInt16(phrases.count + 1), beat: beat, kind: kind(p.kind, mood: mood))
            if mood == .high {
                switch p.kind {
                case .intro, .chorus, .outro: phrase.k1 = 1
                default: break
                }
            }
            phrases.append(phrase)
        }
        let end = beatIndex(of: input.endSeconds ?? duration, in: beats)
        return ANLZSongStructure(mood: mood.rawValue, endBeat: max(end, lastBeat), phrases: phrases)
    }

    static func inferMood(_ phrases: [DJExportPhrase]) -> ANLZMood {
        for p in phrases {
            switch p.kind {
            case .up, .down: return .high
            case .verse, .bridge: return .mid
            default: continue
            }
        }
        return .high
    }

    static func kind(_ kind: DJExportPhrase.Kind, mood: ANLZMood) -> UInt16 {
        switch mood {
        case .high:
            switch kind {
            case .intro: return 1
            case .up, .verse: return 2
            case .down, .bridge: return 3
            case .chorus: return 5
            case .outro: return 6
            }
        case .mid:
            switch kind {
            case .intro: return 1
            case .verse(let n): return UInt16(1 + min(max(n, 1), 6))
            case .up: return 2
            case .down, .bridge: return 8
            case .chorus: return 9
            case .outro: return 10
            }
        case .low:
            switch kind {
            case .intro: return 1
            case .verse(let n): return n >= 2 ? 5 : 2
            case .up: return 2
            case .down, .bridge: return 8
            case .chorus: return 9
            case .outro: return 10
            }
        }
    }
}

// MARK: - Waveforms

enum DJWaveformSynth {
    static let previewColumns = 400
    static let tinyPreviewColumns = 100
    static let colorPreviewColumns = 1200
    static let threeBandPreviewColumns = 1200
    static let detailEntriesPerSecond = 150.0

    struct Rendered: Equatable, Sendable {
        var preview: [UInt8]
        var tinyPreview: [UInt8]
        var detail: [UInt8]
        var colorPreview: [UInt8]
        var colorDetail: [UInt16]
        var threeBandPreview: [UInt8]
        var threeBandDetail: [UInt8]
    }

    static func detailCount(duration: Double) -> Int {
        guard duration.isFinite, duration > 0 else { return 0 }
        return Int((duration * detailEntriesPerSecond).rounded(.up))
    }

    static func resample(_ values: [Float], to count: Int) -> [Float] {
        guard count > 0 else { return [] }
        guard !values.isEmpty else { return [Float](repeating: 0, count: count) }
        let n = values.count
        if n >= count {
            return (0 ..< count).map { i in
                let start = i * n / count
                let end = max(start + 1, (i + 1) * n / count)
                var peak: Float = 0
                for j in start ..< min(end, n) { peak = max(peak, values[j]) }
                return peak
            }
        }
        return (0 ..< count).map { i in
            let x = (Double(i) + 0.5) * Double(n) / Double(count) - 0.5
            let a = max(0, min(n - 1, Int(x.rounded(.down))))
            let b = min(n - 1, a + 1)
            let f = Float(max(0, min(1, x - Double(a))))
            return values[a] * (1 - f) + values[b] * f
        }
    }

    static func normalised(_ values: [Float]) -> [Float] {
        let clean = values.map { $0.isFinite ? max(0, $0) : 0 }
        let sorted = clean.sorted()
        let reference = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.995))]
        guard reference > 0 else { return clean.map { _ in 0 } }
        return clean.map { min(1, $0 / reference) }
    }

    static func level(_ v: Float, _ maximum: Int) -> Int {
        Int((max(0, min(1, v)) * Float(maximum)).rounded())
    }

    static func render(_ waveform: DJExportWaveform, duration: Double) -> Rendered {
        let amp = normalised(waveform.amplitude)
        let low: [Float], mid: [Float], high: [Float]
        if waveform.hasBands, let l = waveform.low, let m = waveform.mid, let h = waveform.high {
            low = normalised(l)
            mid = normalised(m)
            high = normalised(h)
        } else {
            low = amp
            mid = amp.map { $0 * 0.55 }
            high = amp.map { $0 * 0.3 }
        }

        func whiteness(_ a: Float, _ h: Float) -> Int {
            let ratio = a > 0.001 ? h / a : 0
            return min(7, level(ratio * 0.8 + a * 0.35, 7))
        }

        func mono(_ count: Int, heightBits: Int) -> [UInt8] {
            let a = resample(amp, to: count)
            let h = resample(high, to: count)
            return (0 ..< count).map { i in
                if heightBits == 4 { return UInt8(level(a[i], 15)) }
                return UInt8(whiteness(a[i], h[i]) << 5 | level(a[i], 31))
            }
        }

        let detailCount = detailCount(duration: duration)
        let cpA = resample(amp, to: colorPreviewColumns)
        let cpL = resample(low, to: colorPreviewColumns)
        let cpM = resample(mid, to: colorPreviewColumns)
        let cpH = resample(high, to: colorPreviewColumns)
        var colorPreview: [UInt8] = []
        colorPreview.reserveCapacity(colorPreviewColumns * 6)
        for i in 0 ..< colorPreviewColumns {
            colorPreview.append(UInt8(level(cpA[i], 120)))
            colorPreview.append(UInt8(150 + level(cpH[i], 40)))
            colorPreview.append(UInt8(level(cpA[i], 120)))
            colorPreview.append(UInt8(level(cpL[i], 110)))
            colorPreview.append(UInt8(level(cpM[i], 72)))
            colorPreview.append(UInt8(level(cpH[i], 40)))
        }

        let dA = resample(amp, to: detailCount)
        let dL = resample(low, to: detailCount)
        let dM = resample(mid, to: detailCount)
        let dH = resample(high, to: detailCount)
        var colorDetail: [UInt16] = []
        colorDetail.reserveCapacity(detailCount)
        for i in 0 ..< detailCount {
            let total = max(dL[i] + dM[i] + dH[i], 1e-6)
            let r = UInt16(level(dL[i] / total * 1.4, 7))
            let g = UInt16(level(dM[i] / total * 1.6, 7))
            let b = UInt16(level(dH[i] / total * 2.0, 7))
            let h = UInt16(level(dA[i], 31))
            colorDetail.append(r << 13 | g << 10 | b << 7 | h << 2)
        }

        func threeBand(_ count: Int) -> [UInt8] {
            let m = resample(mid, to: count)
            let h = resample(high, to: count)
            let l = resample(low, to: count)
            var out: [UInt8] = []
            out.reserveCapacity(count * 3)
            for i in 0 ..< count {
                out.append(UInt8(level(m[i], 255)))
                out.append(UInt8(level(h[i], 255)))
                out.append(UInt8(level(l[i], 255)))
            }
            return out
        }

        return Rendered(
            preview: mono(previewColumns, heightBits: 5),
            tinyPreview: mono(tinyPreviewColumns, heightBits: 4),
            detail: mono(detailCount, heightBits: 5),
            colorPreview: colorPreview,
            colorDetail: colorDetail,
            threeBandPreview: threeBand(threeBandPreviewColumns),
            threeBandDetail: threeBand(detailCount)
        )
    }
}
