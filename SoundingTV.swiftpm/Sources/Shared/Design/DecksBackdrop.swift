import SwiftUI

struct DecksBackdropMesh: View {
    let outgoing: URL?
    let incoming: URL?
    let blend: Double

    @State private var arts: [URL: CollectionBackdropArt] = [:]
    @State private var isVisible = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let colors = mixedColors
        ZStack {
            Color.black
            if let colors {
                if reduceMotion {
                    MeshGradient(width: 3, height: 3, points: CollectionMeshPalette.points(at: 0), colors: colors)
                        .transition(.opacity)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !isVisible || scenePhase != .active)) { context in
                        MeshGradient(
                            width: 3,
                            height: 3,
                            points: CollectionMeshPalette.points(at: context.date.timeIntervalSinceReferenceDate),
                            colors: colors
                        )
                    }
                    .transition(.opacity)
                }
            }
        }
        .animation(.easeInOut(duration: 0.8), value: colors)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .task(id: outgoing) { await load(outgoing) }
        .task(id: incoming) { await load(incoming) }
    }

    private var mixedColors: [Color]? {
        let a = tones(outgoing)
        let b = tones(incoming)
        let t = min(1, max(0, blend))
        switch (a, b) {
        case (nil, nil):
            return nil
        case (let a?, nil):
            return a.map(CollectionAccent.color)
        case (nil, let b?):
            return t > 0.5 ? b.map(CollectionAccent.color) : nil
        case (let a?, let b?):
            return zip(a, b).map { from, to in
                CollectionAccent.color(CollectionAccent.RGB(
                    r: from.r + (to.r - from.r) * t,
                    g: from.g + (to.g - from.g) * t,
                    b: from.b + (to.b - from.b) * t
                ))
            }
        }
    }

    private func tones(_ url: URL?) -> [CollectionAccent.RGB]? {
        guard let url, let art = arts[url] ?? CollectionBackdropStore.shared.cached(url), art.cells.count == 9 else { return nil }
        return art.cells.enumerated().map { index, cell in
            CollectionMeshPalette.tone(cell, scheme: colorScheme, strong: contrast == .increased, lift: index % 2 == 0 ? 0 : 0.03)
        }
    }

    private func load(_ url: URL?) async {
        guard let url, arts[url] == nil else { return }
        guard let art = await CollectionBackdropStore.shared.art(for: url), !Task.isCancelled else { return }
        arts[url] = art
        let keep = Set([outgoing, incoming].compactMap { $0 })
        arts = arts.filter { keep.contains($0.key) }
    }
}
