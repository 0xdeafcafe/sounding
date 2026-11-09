import AppKit
import SwiftUI

// MARK: - Waveforms

struct DJPlanWaveformPair: View {
    let timeline: DJPlanTimeline
    let top: DJPlanRole
    let deck: (DJPlanRole) -> MixEngine.Deck
    let samples: [String: [Float]]

    private static let ruler: CGFloat = 22

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Spacer().frame(height: Self.ruler)
                label(top).frame(maxHeight: .infinity)
                label(top == .incoming ? .outgoing : .incoming).frame(maxHeight: .infinity)
            }
            .frame(width: DJPlanEditor.labelWidth, alignment: .leading)
            GeometryReader { proxy in
                let axis = DJPlanAxis(timeline: timeline, width: proxy.size.width)
                let laneHeight = (proxy.size.height - Self.ruler) / 2
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DJPlanPalette.canvas)
                    ruler(axis)
                    lane(top, axis: axis, height: laneHeight).offset(y: Self.ruler)
                    lane(top == .incoming ? .outgoing : .incoming, axis: axis, height: laneHeight).offset(y: Self.ruler + laneHeight)
                    boundary(axis.x(1), height: proxy.size.height)
                    boundary(axis.x(timeline.endBar), height: proxy.size.height)
                    Text("Mix · \(timeline.lengthBars) bars")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .frame(height: 16)
                        .background(.white.opacity(0.12), in: .capsule)
                        .position(x: (axis.x(1) + axis.x(timeline.endBar)) / 2, y: 10)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Waveforms of \(timeline.incoming.title) and \(timeline.outgoing.title)")
    }

    private func label(_ role: DJPlanRole) -> some View {
        let track = role == .incoming ? timeline.incoming : timeline.outgoing
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                DJPlanDeckBadge(deck: deck(role), size: 17)
                Text(track.title).font(.body.weight(.semibold)).lineLimit(1)
            }
            Text(role == .incoming ? "Incoming" : "Outgoing").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func boundary(_ x: CGFloat, height: CGFloat) -> some View {
        Rectangle().fill(.white.opacity(0.5)).frame(width: 1.5, height: height).offset(x: x - 0.75)
    }

    private func ruler(_ axis: DJPlanAxis) -> some View {
        let middle = (axis.x(1) + axis.x(timeline.endBar)) / 2
        let bars = stride(from: Int(axis.lower.rounded(.up)), through: Int(axis.upper), by: 1).filter {
            ($0 - 1) % 4 == 0 && $0 >= 1 && abs(axis.x(Double($0)) - middle) > 60
        }
        return ZStack(alignment: .topLeading) {
            ForEach(bars, id: \.self) { bar in
                Text("\(bar)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(Double(bar) <= timeline.endBar ? 0.75 : 0.5))
                    .offset(x: axis.x(Double(bar)) + 3, y: 3)
            }
        }
    }

    private struct Segment: Identifiable {
        var id: Int
        var bars: ClosedRange<Double>
        var seconds: ClosedRange<TimeInterval>
    }

    private func segments(_ role: DJPlanRole, axis: DJPlanAxis) -> [Segment] {
        let t = timeline
        switch role {
        case .outgoing:
            let end = min(axis.upper, t.outgoingEndBar)
            guard end > axis.lower else { return [] }
            return [Segment(id: 0, bars: axis.lower...end, seconds: t.outgoingSeconds(atBar: axis.lower)...t.outgoingSeconds(atBar: end))]
        case .incoming:
            var out: [Segment] = []
            if t.hasLoop, let release = t.bar(.loopRelease) {
                let loop = Double(t.loopBars)
                var start = 1.0
                while start < release - 1e-6 {
                    let end = min(release, start + loop)
                    out.append(Segment(id: out.count, bars: start...end, seconds: t.auto.entrySeconds...(t.auto.entrySeconds + (end - start) * t.incomingBarSeconds)))
                    start = end
                }
                out.append(Segment(id: out.count, bars: release...axis.upper, seconds: t.incomingSeconds(atBar: release)...t.incomingSeconds(atBar: axis.upper)))
            } else {
                out.append(Segment(id: 0, bars: 1...axis.upper, seconds: t.incomingSeconds(atBar: 1)...t.incomingSeconds(atBar: axis.upper)))
            }
            return out
        }
    }

    private func lane(_ role: DJPlanRole, axis: DJPlanAxis, height: CGFloat) -> some View {
        let track = role == .incoming ? timeline.incoming : timeline.outgoing
        let deck = self.deck(role)
        let source = MetalWaveformSourceCache.shared.envelope(id: "plan-\(track.id)", samples: samples[track.id] ?? [], duration: track.duration)
        let ribbons = self.ribbons(role, axis: axis)
        return ZStack(alignment: .topLeading) {
            ForEach(segments(role, axis: axis)) { segment in
                Group {
                    if let source {
                        MetalWaveformView(source: source, timeline: .range(segment.seconds, playhead: nil), grid: nil, overlays: [], style: style(deck))
                    } else {
                        Rectangle().fill(DJPlanPalette.deck(deck).opacity(0.12))
                    }
                }
                .frame(width: max(1, axis.x(segment.bars.upperBound) - axis.x(segment.bars.lowerBound)), height: height - 20)
                .offset(x: axis.x(segment.bars.lowerBound), y: 20)
                if role == .incoming, timeline.hasLoop, let release = timeline.bar(.loopRelease), segment.bars.upperBound <= release + 1e-6 {
                    Rectangle()
                        .fill(DJPlanPalette.auto.opacity(0.1))
                        .overlay(Rectangle().strokeBorder(DJPlanPalette.auto, lineWidth: 0.5))
                        .frame(width: axis.x(segment.bars.upperBound) - axis.x(segment.bars.lowerBound), height: height - 20)
                        .offset(x: axis.x(segment.bars.lowerBound), y: 20)
                }
            }
            ForEach(ribbons, id: \.start) { ribbon in
                Text(ribbon.label)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .frame(width: max(0, axis.x(ribbon.end) - axis.x(ribbon.start) - 2), height: 16, alignment: .leading)
                    .background(ribbon.color, in: .rect(cornerRadius: 4))
                    .offset(x: axis.x(ribbon.start) + 1, y: 2)
            }
            if role == .incoming {
                Text("Cued at \(deck.label) · \(track.section(at: timeline.auto.entrySeconds)?.kind.displayName.capitalized ?? "Start")")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
                    .offset(x: 8, y: height / 2 - 8)
            } else if timeline.outgoingEndBar < axis.upper {
                Text("End of track")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.6))
                    .offset(x: min(axis.x(timeline.outgoingEndBar) + 8, axis.width - 96), y: height / 2 - 8)
            }
        }
        .frame(width: axis.width, height: height, alignment: .topLeading)
    }

    private func style(_ deck: MixEngine.Deck) -> MetalWaveformStyle {
        var style = MetalWaveformStyle.blue
        style.playheadWidth = 0
        return style
    }

    private struct Ribbon {
        var start: Double
        var end: Double
        var label: String
        var color: Color
    }

    private func ribbons(_ role: DJPlanRole, axis: DJPlanAxis) -> [Ribbon] {
        let track = role == .incoming ? timeline.incoming : timeline.outgoing
        guard !track.sections.isEmpty else { return [] }
        let first = role == .incoming ? 1.0 : axis.lower
        let last = role == .incoming ? axis.upper : min(axis.upper, timeline.outgoingEndBar)
        var out: [Ribbon] = []
        var bar = first
        while bar < last - 1e-6 {
            let seconds = role == .incoming ? timeline.incomingSeconds(atBar: bar + 0.5) : timeline.outgoingSeconds(atBar: bar + 0.5)
            let section = track.section(at: seconds)
            let vocals = track.vocalsMeasured ? track.vocals(at: seconds) : nil
            let next = min(last, bar + 1)
            if let section {
                let name = section.kind.displayName.prefix(1).uppercased() + section.kind.displayName.dropFirst()
                let label = vocals.map { "\(name) · \($0 ? "vocals" : "no vocals")" } ?? name
                if var tail = out.last, tail.label == label, abs(tail.end - bar) < 1e-6 {
                    tail.end = next
                    out[out.count - 1] = tail
                } else {
                    let color: Color = vocals == true
                        ? Color(red: 1, green: 0.42, blue: 0.42).opacity(0.55)
                        : section.kind == .intro || section.kind == .ambientIntro
                            ? Color(red: 0.37, green: 0.55, blue: 1).opacity(0.5)
                            : Color(red: 0.28, green: 0.76, blue: 0.69).opacity(0.45)
                    out.append(Ribbon(start: bar, end: next, label: label, color: color))
                }
            }
            bar = next
        }
        return out
    }
}

// MARK: - Lanes

struct DJPlanLaneRow: View {
    let model: DJPlanModel
    let timeline: DJPlanTimeline
    let base: DJPlanTimeline
    let lane: DJPlanLane
    let deck: (DJPlanRole) -> MixEngine.Deck
    @Binding var drag: (id: DJPlanPointID, bar: Double)?
    @State private var refused: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(lane.title).font(.body.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: DJPlanEditor.labelWidth, alignment: .leading)
            GeometryReader { proxy in
                let axis = DJPlanAxis(timeline: timeline, width: proxy.size.width)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.03))
                    RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.07), lineWidth: 0.5)
                    Canvas { context, size in
                        DJPlanLanePainter(timeline: timeline, lane: lane, axis: axis, size: size, deck: deck).paint(&context)
                    }
                    overlays(axis: axis, size: proxy.size)
                }
                .contentShape(.rect)
                .gesture(dragGesture(axis: axis, size: proxy.size))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(lane.title) lane")
        .accessibilityAdjustableAction { direction in
            guard let id = timeline.editablePoints.first(where: { $0.lane == lane }), let bar = timeline.bar(id) else { return }
            model.commit(id, to: bar + (direction == .increment ? 1 : -1), free: false)
        }
    }

    private var subtitle: String {
        switch lane {
        case .loop: return "\(deck(.incoming).label) · \(timeline.loopBars) bars"
        case .fade:
            return timeline.isLoopMix || timeline.isBlendFamily
                ? "\(deck(.incoming).label) in · \(deck(.outgoing).label) out"
                : "Cut at bar \(DJPlanFormat.bar(timeline.bar(.fadeInStart) ?? 1))"
        case .bass: return "Swap at bar \(DJPlanFormat.bar(timeline.bar(.bassSwap) ?? 1))"
        case .filter: return timeline.isLoopMix ? "\(deck(.outgoing).label) HPF out" : "None"
        }
    }

    @ViewBuilder
    private func overlays(axis: DJPlanAxis, size: CGSize) -> some View {
        switch lane {
        case .loop:
            if let release = timeline.bar(.loopRelease) {
                let passes = timeline.repeats
                ForEach(0..<passes, id: \.self) { pass in
                    let start = 1 + Double(pass * timeline.loopBars)
                    let end = start + Double(timeline.loopBars)
                    ViewThatFits(in: .horizontal) {
                        Label("Repeat \(pass + 1)", systemImage: "repeat").fixedSize()
                        Label("\(pass + 1)", systemImage: "repeat").fixedSize()
                        Image(systemName: "repeat")
                    }
                        .font(.callout.weight(.semibold))
                        .accessibilityLabel("Repeat \(pass + 1)")
                        .padding(.horizontal, 8)
                        .frame(width: max(0, axis.x(end) - axis.x(start) - 4), height: 26, alignment: .leading)
                        .background(DJPlanPalette.auto.opacity(pass == 0 ? 0.28 : 0.18), in: .rect(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(DJPlanPalette.auto.opacity(0.6), lineWidth: 0.5))
                        .offset(x: axis.x(start) + 2, y: (size.height - 26) / 2)
                }
                Text("Release · bar \(DJPlanFormat.bar(release))")
                    .font(.callout.weight(.semibold))
                    .offset(x: axis.x(release) + 12, y: size.height / 2 - 8)
            }
        case .bass:
            if let point = timeline.point(.bassSwap), point.isUser {
                let ghost = point.autoBar
                Text("Auto: \(DJPlanFormat.bar(ghost))")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
                    .padding(.horizontal, 3)
                    .background(Color(white: 0.07))
                    .offset(x: axis.x(ghost) - 54, y: size.height - 18)
                callout(point, axis: axis, size: size)
            }
        case .filter:
            if timeline.isLoopMix, let end = timeline.bar(.filterOutEnd) {
                Text("\(deck(.outgoing).label) HPF \(Int(MixMoveBuilder.loopMixHighPassHertz)) Hz")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(DJPlanPalette.deck(deck(.outgoing)))
                    .offset(x: min(axis.x(end) + 10, size.width - 90), y: 30)
            }
        case .fade:
            EmptyView()
        }
        if let refused {
            Text(refused)
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(.black.opacity(0.85), in: .capsule)
                .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
                .frame(maxWidth: .infinity, alignment: .center)
                .offset(y: (size.height - 24) / 2)
                .transition(.opacity)
        }
    }

    private func callout(_ point: DJPlanPoint, axis: DJPlanAxis, size: CGSize) -> some View {
        let x = axis.x(point.bar)
        return HStack(spacing: 7) {
            Image(systemName: "hand.raised")
            Text("Swap at bar \(DJPlanFormat.bar(point.bar))").foregroundStyle(.white)
            Button("Undo") { model.undo() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .font(.callout.weight(.semibold))
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 26)
        .background(Color(red: 0.16, green: 0.14, blue: 0.03).opacity(0.96), in: .capsule)
        .overlay(Capsule().strokeBorder(DJPlanPalette.you.opacity(0.7), lineWidth: 1))
        .fixedSize()
        .frame(width: max(0, x - 14), alignment: .trailing)
        .offset(y: (size.height - 26) / 2)
    }

    private func dragGesture(axis: DJPlanAxis, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let id = drag?.id ?? nearest(to: value.startLocation, axis: axis, size: size)
                guard let id else { return }
                let free = NSEvent.modifierFlags.contains(.option)
                switch model.propose(id, to: axis.bar(value.location.x), free: free) {
                case .accepted(let bar, let note):
                    drag = (id, bar)
                    refused = note
                case .refused(let reason):
                    if drag == nil { drag = (id, base.bar(id) ?? 1) }
                    refused = reason
                }
            }
            .onEnded { _ in
                guard let current = drag else { return }
                drag = nil
                let free = NSEvent.modifierFlags.contains(.option)
                model.commit(current.id, to: current.bar, free: free)
                withAnimation(.easeOut(duration: 0.2).delay(1.2)) { refused = nil }
            }
    }

    private func nearest(to location: CGPoint, axis: DJPlanAxis, size: CGSize) -> DJPlanPointID? {
        let painter = DJPlanLanePainter(timeline: base, lane: lane, axis: axis, size: size, deck: deck)
        let candidates = base.editablePoints.filter { $0.lane == lane }.compactMap { id -> (DJPlanPointID, CGFloat)? in
            guard let point = base.point(id) else { return nil }
            let p = painter.position(point)
            return (id, hypot(p.x - location.x, p.y - location.y))
        }
        guard let best = candidates.min(by: { $0.1 < $1.1 }), best.1 < 18 else { return nil }
        return best.0
    }
}

struct DJPlanLanePainter {
    let timeline: DJPlanTimeline
    let lane: DJPlanLane
    let axis: DJPlanAxis
    let size: CGSize
    let deck: (DJPlanRole) -> MixEngine.Deck

    func y(_ value: Double) -> CGFloat {
        8 + CGFloat(1 - value) * (size.height - 16)
    }

    func position(_ point: DJPlanPoint) -> CGPoint {
        CGPoint(x: axis.x(point.bar), y: lane == .loop ? size.height / 2 : y(point.level))
    }

    func paint(_ context: inout GraphicsContext) {
        grid(&context)
        switch lane {
        case .loop: break
        case .fade: fade(&context)
        case .bass: bass(&context)
        case .filter: filter(&context)
        }
        for id in DJPlanPointID.allCases where id.lane == lane {
            guard let point = timeline.point(id), timeline.editablePoints.contains(id) || lane == .bass else { continue }
            if lane == .fade, timeline.isBlendFamily, id == .fadeInEnd || id == .fadeOutStart { continue }
            dot(point, &context)
        }
    }

    private func grid(_ context: inout GraphicsContext) {
        var bar = axis.lower.rounded(.up)
        while bar <= axis.upper {
            let x = axis.x(bar)
            let strong = Int(bar - 1) % 8 == 0
            context.fill(Path(CGRect(x: x, y: 0, width: 0.5, height: size.height)), with: .color(.white.opacity(strong ? 0.14 : 0.05)))
            bar += 1
        }
    }

    private func line(_ points: [(Double, Double)], role: DJPlanRole, fill: Bool, _ context: inout GraphicsContext) {
        guard let first = points.first, let last = points.last else { return }
        let d = deck(role)
        var path = Path()
        path.move(to: CGPoint(x: axis.x(first.0), y: y(first.1)))
        for p in points.dropFirst() { path.addLine(to: CGPoint(x: axis.x(p.0), y: y(p.1))) }
        if fill {
            var area = path
            area.addLine(to: CGPoint(x: axis.x(last.0), y: y(0)))
            area.addLine(to: CGPoint(x: axis.x(first.0), y: y(0)))
            area.closeSubpath()
            context.fill(area, with: .color(DJPlanPalette.deck(d).opacity(0.1)))
        }
        context.stroke(path, with: .color(DJPlanPalette.deck(d)), style: StrokeStyle(lineWidth: 2.2, lineJoin: .round, dash: d == .b ? [6, 4] : []))
    }

    private func fade(_ context: inout GraphicsContext) {
        let t = timeline
        let inStart = t.bar(.fadeInStart) ?? 1
        let inEnd = t.bar(.fadeInEnd) ?? t.endBar
        let outStart = t.bar(.fadeOutStart) ?? 1
        let outEnd = t.bar(.fadeOutEnd) ?? t.endBar
        let startLevel = t.point(.fadeInStart)?.level ?? 0
        let endLevel = t.point(.fadeOutEnd)?.level ?? 0
        line([(inStart, startLevel), (inEnd, 1), (axis.upper, 1)], role: .incoming, fill: true, &context)
        line([(axis.lower, 1), (outStart, 1), (outEnd, endLevel), (axis.upper, endLevel)], role: .outgoing, fill: true, &context)
    }

    private func bass(_ context: inout GraphicsContext) {
        let swap = timeline.bar(.bassSwap) ?? 1
        line([(axis.lower, 0.85), (swap, 0.85), (swap, 0.15), (axis.upper, 0.15)], role: .outgoing, fill: false, &context)
        line([(timeline.overlap.lowerBound, 0.15), (swap, 0.15), (swap, 0.85), (axis.upper, 0.85)], role: .incoming, fill: false, &context)
        if let point = timeline.point(.bassSwap), point.isUser {
            var ghost = Path()
            ghost.move(to: CGPoint(x: axis.x(point.autoBar), y: y(0.15)))
            ghost.addLine(to: CGPoint(x: axis.x(point.autoBar), y: y(0.85)))
            context.stroke(ghost, with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
        }
    }

    private func filter(_ context: inout GraphicsContext) {
        guard timeline.isLoopMix else { return }
        let start = timeline.bar(.filterOutStart) ?? 1
        let end = timeline.bar(.filterOutEnd) ?? timeline.endBar
        let a = timeline.point(.filterOutStart)?.level ?? 0.04
        let b = timeline.point(.filterOutEnd)?.level ?? 0.85
        line([(axis.lower, a), (start, a), (end, b), (axis.upper, b)], role: .outgoing, fill: false, &context)
    }

    private func dot(_ point: DJPlanPoint, _ context: inout GraphicsContext) {
        let p = position(point)
        let d = deck(point.id.role)
        if point.isUser {
            let rect = CGRect(x: p.x - 8.5, y: p.y - 8.5, width: 17, height: 17)
            context.fill(Path(ellipseIn: rect), with: .color(DJPlanPalette.you))
            context.fill(Path(ellipseIn: rect.insetBy(dx: 3, dy: 3)), with: .color(.white))
        } else if lane == .loop {
            let rect = CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)
            context.fill(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)), with: .color(DJPlanPalette.auto))
            context.fill(Path(ellipseIn: rect), with: .color(.white))
        } else if d == .b {
            let rect = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
            context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(Color(white: 0.045)))
            context.stroke(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(DJPlanPalette.b), lineWidth: 2)
        } else {
            let rect = CGRect(x: p.x - 5.5, y: p.y - 5.5, width: 11, height: 11)
            context.fill(Path(ellipseIn: rect), with: .color(Color(white: 0.045)))
            context.stroke(Path(ellipseIn: rect), with: .color(DJPlanPalette.a), lineWidth: 2)
        }
    }
}
