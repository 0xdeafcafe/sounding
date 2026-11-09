// MetalPreview — a live gallery and tuning harness for every shader in this
// repo.
//
// Why this exists
// ---------------
// Tuning a focus-gated tvOS effect in the real app costs about three minutes a
// look: rebuild, install to a simulator, launch with a screenshot hook,
// `simctl io screenshot`, crop. And it cannot show the thing that actually
// matters — the effect *moving*, and the focused card beside its unfocused
// neighbours — because `simctl` cannot synthesise a Siri Remote press, so a
// focus-gated effect is invisible without a DEBUG override that then lies
// about the cost by turning it on for every card at once.
//
// This launches in about two seconds, animates live, and puts every shaping
// value on a slider.
//
// It compiles the app's **real** `Design/Shaders/CardEffects.metal` — see
// `build.sh` — so what is tuned here is what ships. A second copy of a shader
// would drift within a day.
//
// What it is not
// --------------
// Not a performance harness. This runs on the Mac's GPU; an Apple TV 4K is an
// A15. Frame timings taken here mean nothing for the TV — measure those on the
// device with Metal System Trace, against a real tvOS target.

import SwiftUI

@main
struct MetalPreviewApp: App {
    var body: some Scene {
        WindowGroup("Sounding · Metal Preview") {
            PreviewRoot()
                .frame(minWidth: 1180, minHeight: 760)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

private enum Effect: String, CaseIterable, Identifiable {
    case cards = "Focused card"
    case backdrop = "Backdrop composite"
    var id: String { rawValue }
}

// MARK: - Root

private struct PreviewRoot: View {
    @State private var effect: Effect = .cards
    @State private var card = CardParams()
    @State private var backdrop = BackdropParams()

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $effect) {
                ForEach(Effect.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(14)

            Divider().overlay(Color.white.opacity(0.12))

            HStack(spacing: 0) {
                Group {
                    switch effect {
                    case .cards:    CardStage(params: card)
                    case .backdrop: BackdropStage(params: backdrop)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider().overlay(Color.white.opacity(0.12))

                ScrollView {
                    switch effect {
                    case .cards:    CardControls(params: $card)
                    case .backdrop: BackdropControls(params: $backdrop)
                    }
                }
                .frame(width: 310)
            }
        }
        .background(FieldBackground())
    }
}

// MARK: - Cards

private struct CardParams {
    /// Defaults are the shipping values from `ShelfArtwork`, so "Reset" always
    /// shows what the app actually does.
    var drift = 2.0
    var rake = 0.22
    var rakePeriod = 4.0
    var spill = 0.16
    var saturation = 0.18
    var contrast = 0.10
}

private struct CardStage: View {
    let params: CardParams
    @State private var focused = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Header(
                eyebrow: "YOUR STREAM",
                title: "Focused card treatment",
                note: "Click a card to move focus. Only the focused card runs the shader — "
                    + "that is the cost rule, and the comparison against its neighbours is the point."
            )

            HStack(spacing: 20) {
                ForEach(0..<4, id: \.self) { index in
                    PreviewCard(seed: index, params: params, focus: index == focused ? 1 : 0)
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.25)) { focused = index }
                        }
                }
            }
            Spacer()
        }
        .padding(40)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PreviewCard: View {
    let seed: Int
    let params: CardParams
    let focus: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.animation) { context in
                Artwork(seed: seed)
                    .layerEffect(
                        ShaderLibrary.default.cardFocusEffect(
                            .boundingRect,
                            .color(Color(red: 1.0, green: 0.42, blue: 0.10)),   // Color.scAccent
                            .float(context.date.timeIntervalSinceReferenceDate),
                            .float(focus),
                            .float(params.drift),
                            .float(params.rake),
                            .float(params.rakePeriod),
                            .float(params.spill),
                            .float(params.saturation),
                            .float(params.contrast)
                        ),
                        maxSampleOffset: CGSize(width: 8, height: 8)
                    )
            }
            .frame(width: 196, height: 196)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            // The app's focus language, and Apple Music's: scale + drop
            // shadow. Never a border, a glow, or glass.
            .scaleEffect(focus > 0.5 ? 1.06 : 1.0)
            .shadow(color: .black.opacity(focus > 0.5 ? 0.55 : 0), radius: 24, y: 12)

            Text(Self.titles[seed % Self.titles.count])
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            Text("Sounding Records")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(width: 196, alignment: .leading)
    }

    private static let titles = ["Night Bus", "Warehouse 4AM", "Coastline", "Static Bloom"]
}

/// Stand-in cover art. Deliberately different hues and high internal contrast:
/// a treatment that only looks right over one kind of cover is not finished,
/// and a browse shelf is the most heterogeneous surface in the app. The rings
/// matter specifically — displacement is invisible over a flat fill, so a flat
/// placeholder would hide the one thing only a shader can do.
private struct Artwork: View {
    let seed: Int

    var body: some View {
        ZStack {
            LinearGradient(
                colors: Self.palettes[seed % Self.palettes.count],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            ForEach(0..<7, id: \.self) { i in
                Circle()
                    .stroke(Color.white.opacity(0.16), lineWidth: 3)
                    .frame(width: CGFloat(30 + i * 27))
                    .offset(x: CGFloat(seed * 9 - 20), y: CGFloat(-seed * 7 + 10))
            }
            Text("SC")
                .font(.system(size: 44, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    private static let palettes: [[Color]] = [
        [Color(red: 0.11, green: 0.15, blue: 0.35), Color(red: 0.62, green: 0.16, blue: 0.42)],
        [Color(red: 0.85, green: 0.30, blue: 0.05), Color(red: 0.20, green: 0.06, blue: 0.10)],
        [Color(red: 0.05, green: 0.35, blue: 0.32), Color(red: 0.02, green: 0.10, blue: 0.18)],
        [Color(red: 0.58, green: 0.58, blue: 0.62), Color(red: 0.92, green: 0.90, blue: 0.86)]
    ]
}

private struct CardControls: View {
    @Binding var params: CardParams

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("cardFocusEffect").font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
            ParamSlider("Drift amplitude", $params.drift, 0...6,
                        "pt of displacement — the part SwiftUI cannot do at all")
            ParamSlider("Rake strength", $params.rake, 0...0.6, "additive white sweep")
            ParamSlider("Rake period", $params.rakePeriod, 1...12, "seconds per sweep")
            ParamSlider("Spill strength", $params.spill, 0...0.6, "accent light from below")
            ParamSlider("Saturation lift", $params.saturation, 0...0.6, "")
            ParamSlider("Contrast lift", $params.contrast, 0...0.4, "")
            Button("Reset to shipping") { params = CardParams() }
                .buttonStyle(.borderedProminent)
            Text("Shipping values live in `ShelfArtwork` in HomeView.swift.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.35))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
    }
}

// MARK: - Backdrop

private struct BackdropParams {
    var meshPhase = 0.0
    var energy = 0.5
    var ceiling = 0.14
    var saturation = 1.35
    var debugMode = 0.0
    var animate = true
}

private struct BackdropStage: View {
    let params: BackdropParams

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Header(
                eyebrow: "REJECTED PROTOTYPE",
                title: "Backdrop composite",
                note: "Five SwiftUI layers collapsed into one pass, with the black scrim replaced by a "
                    + "per-pixel WCAG luminance clamp. Measured 4.3× darker than the layer stack it "
                    + "replaces, so it was not adopted — kept runnable as evidence."
            )

            TimelineView(.animation(paused: !params.animate)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    Color.black
                    // Stands in for the blurred hero artwork the real backdrop
                    // composites under everything else.
                    LinearGradient(
                        colors: [Color(red: 0.30, green: 0.42, blue: 0.34),
                                 Color(red: 0.10, green: 0.13, blue: 0.16)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    .blur(radius: 40)
                    .opacity(0.50)
                }
                .colorEffect(
                    ShaderLibrary.default.backdropComposite(
                        .boundingRect,
                        .color(Color(red: 0.33, green: 0.50, blue: 0.36)),
                        .color(Color(red: 0.20, green: 0.32, blue: 0.46)),
                        .color(Color(red: 0.26, green: 0.34, blue: 0.32)),
                        .float(params.meshPhase),
                        .float(params.animate ? (t / 46).truncatingRemainder(dividingBy: 1) * 2 * .pi : 0),
                        .float(params.energy),
                        .float(params.ceiling),
                        .float(params.saturation),
                        .float(params.debugMode)
                    )
                )
                .overlay(alignment: .topLeading) { sampleText.padding(34) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(40)
    }

    /// The text ramp the contrast contract is actually about. Present so the
    /// clamp can be judged the way it is measured — against type, not against
    /// a swatch.
    private var sampleText: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Warehouse 4AM")
                .font(.system(size: 44, weight: .heavy))
                .foregroundStyle(.white.opacity(0.90))
            Text("Sounding Records")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.60))
            Text("5:22 · 50.0K likes")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.68))
        }
    }
}

private struct BackdropControls: View {
    @Binding var params: BackdropParams

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("backdropComposite").font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)

            Toggle("Animate", isOn: $params.animate).foregroundStyle(.white.opacity(0.85))

            ParamSlider("Mesh phase", $params.meshPhase, 0...1, "")
            ParamSlider("Pulse energy", $params.energy, -0.1...1,
                        "negative = unmodulated (Reduce Motion / paused)")
            ParamSlider("Luminance ceiling", $params.ceiling, 0.02...0.60,
                        "SCAmbient.backgroundLuminanceCeiling is 0.14")
            ParamSlider("Artwork saturation", $params.saturation, 0.5...2.0, "")

            Divider().overlay(Color.white.opacity(0.12))

            Text("Debug view").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Picker("", selection: $params.debugMode) {
                Text("Normal").tag(0.0)
                Text("uv map").tag(1.0)
                Text("No clamp").tag(2.0)
                Text("Luminance").tag(3.0)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Text("`uv map` is how the worst bug in this shader was found: `position` is not in the "
                 + "view's coordinate space when the content contains a blur or a scale. Bottom-right "
                 + "must read (1, 1).")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.35))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
    }
}

// MARK: - Shared

private struct Header: View {
    let eyebrow: String
    let title: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow)
                .font(.system(size: 11, weight: .bold)).kerning(1.6)
                .foregroundStyle(.white.opacity(0.45))
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
            Text(note)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 620, alignment: .leading)
    }
}

private struct ParamSlider: View {
    let title: String
    let note: String
    let range: ClosedRange<Double>
    @Binding var value: Double

    init(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ note: String) {
        self.title = title
        self._value = value
        self.range = range
        self.note = note
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
                Text(String(format: "%.3f", value))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Slider(value: $value, in: range)
            if !note.isEmpty {
                Text(note).font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The graded field measured off `Design/reference/appletv-music/new.png`:
/// relative luminance 0.0103 at the top to 0.0497 at the bottom — a 4.8×
/// gradient — with hue drifting from near-neutral blue to mauve. Reproduced so
/// cards are judged on the field they will sit on rather than on flat black.
private struct FieldBackground: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: Color(red: 0.102, green: 0.102, blue: 0.110), location: 0.0),
                .init(color: Color(red: 0.192, green: 0.157, blue: 0.180), location: 0.62),
                .init(color: Color(red: 0.243, green: 0.247, blue: 0.247), location: 1.0)
            ],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}
