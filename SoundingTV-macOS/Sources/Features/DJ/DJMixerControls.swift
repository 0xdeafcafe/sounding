import SwiftUI

struct DJSegmentMeter: View {
    let meter: DJMeterBallistics
    var showsClip = true
    var height: CGFloat = 76

    static let segments = 16
    static let green = Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255)
    static let hot = Color(red: 1, green: 0x6A / 255, blue: 0x5A / 255)
    static let clip = Color(red: 1, green: 0x45 / 255, blue: 0x3A / 255)

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let lit = DJMeterBallistics.meterFraction(meter.level)
        let held = DJMeterBallistics.meterFraction(meter.heldPeak)
        let clipping = showsClip && meter.isClipping
        let cell = height / CGFloat(Self.segments)
        ZStack(alignment: .bottomLeading) {
            ForEach(0..<Self.segments, id: \.self) { i in
                let t = Double(i) / Double(Self.segments)
                let on = t < lit || (clipping && i == Self.segments - 1)
                RoundedRectangle(cornerRadius: 1)
                    .fill(on ? (t > 0.86 ? Self.hot : Self.green) : .white.opacity(contrast == .increased ? 0.2 : 0.08))
                    .frame(width: 5, height: cell - 1.4)
                    .offset(y: -CGFloat(i) * cell)
            }
            if held > 0 {
                Rectangle()
                    .fill(.white)
                    .frame(width: 7, height: 1.5)
                    .offset(x: -1, y: -CGFloat(held) * height)
            }
        }
        .frame(width: 5, height: height, alignment: .bottomLeading)
        .accessibilityHidden(true)
    }
}
