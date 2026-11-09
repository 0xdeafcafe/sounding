#if DEBUG
import SwiftUI

enum DJMixerHarness {
    static var fixtureName: String? { ProcessInfo.processInfo.environment["SOUNDING_TV_DJ_FIXTURE"] }

    @MainActor
    static func applyFixtureMixer(to engine: MixEngine) {
        engine.setDeckFX(.echo, beats: 0.5, on: .a)
        engine.setDeckFXAmount(0, on: .a)
        engine.setDeckFX(.reverb, beats: 1, on: .b)
        engine.setDeckFXAmount(0.18, on: .b)
        engine.setDeckFXEnabled(true, on: .b)
        engine.setCue(true, on: .b)
        engine.setCueMix(0)
        engine.setPhonesLevel(0.5)
        engine.masterVolume = DJMixerUnits.levelGain(knob: 0.917)
    }

    @MainActor
    static func view(state name: String?) -> some View {
        let model = MacDJPerformModel.shared
        let fixtureName = name ?? "automix"
        let state = MacDJFixtures.state(named: fixtureName) ?? MacDJFixtures.automix()
        model.fixture = state
        applyFixtureMixer(to: .shared)
        let mixer = DJMixerModel(surface: MacDeckControlSurface.shared, engine: .shared, isLive: false)
        return DJMixerHarnessView(state: state, model: model, mixer: mixer)
    }
}

private struct DJMixerHarnessView: View {
    let state: MacDJPerformState
    @ObservedObject var model: MacDJPerformModel
    let mixer: DJMixerModel

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 18) {
                DJMixerColumn(state: model.fixture ?? state, model: model, mixer: mixer)
                    .frame(width: 262, height: 440)
                VStack(spacing: 10) {
                    DJDeckFXRow(deck: .a, model: mixer)
                    DJDeckFXRow(deck: .b, model: mixer)
                }
                .frame(width: 400)
            }
            DJMixerSettingsForm(model: mixer)
                .frame(width: 360, height: 360)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MacDJPalette.chassis)
        .environment(\.colorScheme, .dark)
    }
}
#endif
