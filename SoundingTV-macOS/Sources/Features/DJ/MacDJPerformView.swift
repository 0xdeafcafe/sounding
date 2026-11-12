import SwiftUI

struct MacDJPerformView: View {
    @ObservedObject var model: MacDJPerformModel
    let context: DJDeckContext
    let prep: MacPrepModel
    @ObservedObject private var console = MacConsoleController.shared

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let naturalSize = CGSize(width: 1280, height: 748)
    static let minimumScale: CGFloat = 0.58
    static let panelCollapseWidth: CGFloat = 760

    var body: some View {
        GeometryReader { proxy in
            let available = proxy.size
            let scale = max(Self.minimumScale, min(1, available.width / Self.naturalSize.width, available.height / Self.naturalSize.height))
            let canvas = CGSize(width: max(available.width / scale, Self.naturalSize.width * 0.5), height: max(available.height / scale, Self.naturalSize.height * 0.5))
            let state = model.state(at: Date())
            layout(state, canvas: canvas, scale: scale, roomForPanel: available.width >= Self.panelCollapseWidth)
                .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: available.width, height: available.height, alignment: .topLeading)
        }
        .background(MacDJPalette.chassis)
        .background(alignment: .top) { ambient }
        .environment(\.colorScheme, .dark)
    }

    private var ambient: some View {
        ZStack {
            RadialGradient(colors: [Color(red: 0.35, green: 0.47, blue: 0.78).opacity(0.2), .clear], center: UnitPoint(x: 0.18, y: -0.04), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Color(red: 0.59, green: 0.39, blue: 0.78).opacity(0.18), .clear], center: UnitPoint(x: 0.7, y: -0.04), startRadius: 0, endRadius: 520)
        }
        .frame(height: 360)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func deck(_ deck: MixEngine.Deck, state: MacDJPerformState, usesCanvas: Bool) -> some View {
        MacDJDeckDropZone {
            MacDJDeckView(deck: deck, state: state, usesCanvas: usesCanvas, model: model)
        } onDrop: { id in
            model.requestLoad(id, onto: deck, context: context)
        }
    }

    private func layout(_ state: MacDJPerformState, canvas: CGSize, scale: CGFloat, roomForPanel: Bool) -> some View {
        let open = model.isPanelOpen && roomForPanel
        let panelWidth: CGFloat = open ? 318 : 0
        let contentWidth = canvas.width - panelWidth - 16 - (open ? 14 : 16)
        let showsMixer = model.layout.showsMixer
        let mixerWidth: CGFloat = showsMixer ? (open ? 262 : 300) : 0
        let mixerGap: CGFloat = showsMixer ? 14 : 0
        let deckWidth = floor((contentWidth - mixerWidth - mixerGap * 2 - (showsMixer ? 0 : 14)) / 2)
        let deckBX = 16 + deckWidth + 14 + mixerWidth + mixerGap
        let deckHeight: CGFloat = 436
        let showsStrip = !open && (state.panel?.isAutoMixOn == true || !state.owned.isEmpty)
        let wavesTop: CGFloat = showsStrip ? 48 : 16
        let wavesHeight = max(180, canvas.height - wavesTop - 14 - deckHeight - 28)
        let decksTop = wavesTop + wavesHeight + 14
        let usesCanvas = model.isFixture
        return ZStack(alignment: .topLeading) {
            if showsStrip {
                MacDJAutoMixStrip(state: state, model: model)
                    .frame(width: contentWidth)
                    .offset(x: 16, y: 6)
            }
            MacDJStackedWaveforms(state: state, usesCanvas: usesCanvas, layout: model.layout) { model.zoomBars = $0 }
                .frame(width: contentWidth, height: wavesHeight)
                .offset(x: 16, y: wavesTop)
            deck(.a, state: state, usesCanvas: usesCanvas)
                .frame(width: deckWidth, height: deckHeight)
                .offset(x: 16, y: decksTop)
            if showsMixer {
                DJMixerColumn(state: state, model: model)
                    .frame(width: mixerWidth, height: 444)
                    .offset(x: 16 + deckWidth + 14, y: decksTop)
            }
            deck(.b, state: state, usesCanvas: usesCanvas)
                .frame(width: deckWidth, height: deckHeight)
                .offset(x: deckBX, y: decksTop)
            Rectangle().fill(.white.opacity(0.08)).frame(width: 0.5, height: 440).offset(x: 16 + deckWidth + 7, y: decksTop + 4)
            if showsMixer {
                Rectangle().fill(.white.opacity(0.08)).frame(width: 0.5, height: 440).offset(x: deckBX - 7, y: decksTop + 4)
            }
            if open {
                MacDJAutoMixPanel(state: state, model: model) {
                    DJLibraryPanel(model: prep, context: context)
                }
                    .frame(width: panelWidth, height: canvas.height)
                    .offset(x: canvas.width - panelWidth)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing))
            }
        }
    }
}
