import SwiftUI

enum DJPlanPalette {
    static let a = Color(red: 0.353, green: 0.663, blue: 1.0)
    static let b = Color(red: 0.824, green: 0.714, blue: 1.0)
    static let auto = Color(red: 0.427, green: 0.8, blue: 0.702)
    static let you = Color(red: 1.0, green: 0.839, blue: 0.039)
    static let live = Color(red: 1.0, green: 0.271, blue: 0.227)
    static let join = Color.scAccent
    static let canvas = Color(red: 0.016, green: 0.016, blue: 0.02)

    static func deck(_ deck: MixEngine.Deck) -> Color { deck == .a ? a : b }
}

struct DJPlanDeckBadge: View {
    let deck: MixEngine.Deck
    var size: CGFloat = 16

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        Text(deck.label)
            .font(.system(size: size * 0.62, weight: .heavy))
            .foregroundStyle(deck == .a ? Color(red: 0, green: 0.1, blue: 0.2) : DJPlanPalette.b)
            .frame(width: size, height: size)
            .background {
                if deck == .a {
                    shape.fill(DJPlanPalette.a)
                } else {
                    shape.fill(DJPlanPalette.b.opacity(0.14)).overlay(shape.strokeBorder(DJPlanPalette.b, lineWidth: max(1.5, size / 12)))
                }
            }
            .accessibilityLabel("Deck \(deck.label)")
    }
}

struct DJPlanScreen<Accessory: View>: View {
    @Bindable var model: DJPlanModel
    let accessory: Accessory

    init(model: DJPlanModel, @ViewBuilder accessory: () -> Accessory) {
        self.model = model
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                accessory
                DJPlanLiveStrip(model: model)
            }
            HStack(alignment: .top, spacing: 0) {
                DJPlanCrateColumn(model: model)
                    .frame(width: 240)
                Divider().opacity(0.6)
                Group {
                    if let timeline = model.selectedTimeline {
                        ScrollView(.vertical) {
                            DJPlanEditor(model: model, timeline: timeline)
                                .padding(.trailing, 2)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                    } else if model.selectedKey == nil {
                        ContentUnavailableView("No Transitions", systemImage: "arrow.triangle.merge", description: Text("Add two tracks to plan a mix."))
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.leading, 16)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .task { await model.load() }
    }
}

extension DJPlanScreen where Accessory == EmptyView {
    init(model: DJPlanModel) {
        self.init(model: model) { EmptyView() }
    }
}

// MARK: - Live strip

struct DJPlanLiveStrip: View {
    let model: DJPlanModel

    var body: some View {
        HStack(spacing: 10) {
            if let live = model.live {
                HStack(spacing: 5) {
                    Circle().fill(DJPlanPalette.live).frame(width: 7, height: 7)
                    Text("Live").fontWeight(.bold).foregroundStyle(Color(red: 1, green: 0.61, blue: 0.57))
                }
                deck(live.from)
                if let to = live.to {
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                    deck(to)
                }
                if let step = live.step {
                    Divider().frame(height: 14)
                    Image(systemName: "sparkle").foregroundStyle(DJPlanPalette.auto)
                    Text(step).monospacedDigit()
                }
                Spacer(minLength: 8)
                HStack(spacing: 16) {
                    if let extend = model.actions.extend { Button("Extend 8 Bars", action: extend) }
                    if let mixNow = model.actions.mixNow { Button("Mix Now", action: mixNow) }
                    if let takeOver = model.actions.takeOverAll { Button("Take Over All", action: takeOver) }
                }
                .buttonStyle(.borderless)
            } else {
                Text("Not playing").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.callout)
        .foregroundStyle(Color.white)
        .tint(.white)
        .lineLimit(1)
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(height: 34)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .capsule)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live")
    }

    private func deck(_ deck: DJPlanLive.Deck) -> some View {
        HStack(spacing: 6) {
            DJPlanDeckBadge(deck: deck.deck)
            Text(deck.title).fontWeight(.semibold)
            if let remaining = deck.remaining {
                Text("−\(DJPlanFormat.time(remaining))").monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Crate

struct DJPlanCrateColumn: View {
    @Bindable var model: DJPlanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.crate.name).font(.title3.bold())
                Text("Drag a track to reorder").font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
            List {
                ForEach(Array(model.crate.tracks.enumerated()), id: \.element.id) { index, track in
                    DJPlanCrateRow(model: model, index: index, track: track)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .moveDisabled(!model.crate.canMove(from: index))
                }
                .onMove { source, destination in
                    guard let first = source.first else { return }
                    model.move(from: first, to: destination)
                }
                Text("Moving a track replans only its own transitions.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 6)
                    .listRowSeparator(.hidden)
                    .moveDisabled(true)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            if let refusal = model.refusal, model.selectedTimeline == nil {
                Text(refusal).font(.callout).foregroundStyle(.secondary).padding(6)
            }
        }
    }
}

struct DJPlanCrateRow: View {
    let model: DJPlanModel
    let index: Int
    let track: DJPlanTrack

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            trackRow
            if index < model.crate.joins.count {
                DJPlanJoinRow(model: model, index: index)
            }
        }
    }

    private var isSelectedIncoming: Bool { model.selectedKey?.incomingId == track.id }

    private var trackRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .opacity(model.crate.canMove(from: index) ? 1 : 0.4)
            DJPlanArtwork(seed: track.id)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title).font(.body.weight(.semibold)).lineLimit(1)
                Text(model.status(for: index)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if index >= model.crate.lockedCount - 2, index < model.crate.lockedCount, let deck = model.deck(for: track.id) {
                DJPlanDeckBadge(deck: deck, size: 18)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 40)
        .background(isSelectedIncoming ? Color.white.opacity(0.1) : .clear, in: .rect(cornerRadius: 7))
        .opacity(model.joinState(max(0, index)) == .played && index < model.crate.lockedCount - 2 ? 0.5 : 1)
        .accessibilityElement(children: .combine)
    }
}

struct DJPlanJoinRow: View {
    let model: DJPlanModel
    let index: Int

    var body: some View {
        let key = model.crate.joins[index]
        let label = model.joinLabel(index)
        let selected = model.selectedKey == key
        let replans = model.replans.contains(key)
        let state = model.joinState(index)
        Button {
            model.select(key)
        } label: {
            HStack(spacing: 6) {
                if label.warning { Image(systemName: "exclamationmark.triangle").font(.caption) }
                if state == .live { Circle().fill(DJPlanPalette.auto).frame(width: 6, height: 6) }
                Text(label.text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(.callout)
            .foregroundStyle(color(selected: selected, replans: replans, state: state))
            .padding(.leading, 14)
            .frame(minHeight: 26)
            .contentShape(.rect)
            .background(alignment: .leading) {
                Rectangle()
                    .fill(selected || replans ? DJPlanPalette.join : Color.white.opacity(0.18))
                    .frame(width: 1.5)
                    .mask {
                        if replans {
                            VStack(spacing: 2) { ForEach(0..<7, id: \.self) { _ in Rectangle().frame(height: 2) } }
                        } else {
                            Rectangle()
                        }
                    }
            }
            .background(selected ? DJPlanPalette.join.opacity(0.16) : .clear, in: UnevenRoundedRectangle(bottomTrailingRadius: 6, topTrailingRadius: 6))
        }
        .buttonStyle(.plain)
        .padding(.leading, 21)
        .accessibilityLabel("Transition \(label.text)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func color(selected: Bool, replans: Bool, state: DJPlanModel.JoinState) -> Color {
        if selected { return .primary }
        if replans { return Color.scAccent.opacity(0.85) }
        switch state {
        case .played: return .secondary
        case .live: return DJPlanPalette.auto
        case .upcoming: return Color.white.opacity(0.65)
        }
    }
}

struct DJPlanArtwork: View {
    let seed: String

    var body: some View {
        let hash = seed.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let hue = Double(hash % 360) / 360
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(Color(hue: hue, saturation: 0.55, brightness: 0.35))
            .overlay {
                ZStack {
                    ForEach(0..<4, id: \.self) { ring in
                        Circle()
                            .strokeBorder(Color(hue: hue + 0.08 * Double(ring), saturation: 0.6, brightness: 0.95), lineWidth: 1.5)
                            .padding(CGFloat(ring) * 3)
                    }
                }
                .padding(2)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityHidden(true)
    }
}
