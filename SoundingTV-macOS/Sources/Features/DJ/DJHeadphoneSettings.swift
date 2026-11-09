import SwiftUI

struct DJHeadphoneOutputPicker: View {
    @ObservedObject var output: MixPhonesOutput

    init(output: MixPhonesOutput = MixEngine.shared.phonesOutput) {
        self.output = output
    }

    var body: some View {
        Picker("Output", selection: Binding(
            get: { output.route },
            set: { route in
                output.select(route)
                if route != nil { output.start() }
            }
        )) {
            Text("None").tag(MixPhonesRoute?.none)
            ForEach(output.devices) { device in
                Section(device.name) {
                    ForEach(device.channelPairs, id: \.self) { pair in
                        Text(title(device, pair: pair))
                            .tag(Optional(MixPhonesRoute(deviceUID: device.uid, channelPair: pair)))
                    }
                }
            }
            if let route = output.route, output.device(for: route.deviceUID) == nil {
                Text("Unavailable").tag(Optional(route))
            }
        }
    }

    private func title(_ device: MixOutputDevice, pair: Int) -> String {
        device.channelPairs.count > 1 ? "\(device.name) · \(MixOutputDevice.pairLabel(pair))" : device.name
    }
}

struct DJHeadphoneSettingsSection: View {
    @ObservedObject var model: DJMixerModel
    @ObservedObject var output: MixPhonesOutput

    init(model: DJMixerModel = .shared, output: MixPhonesOutput = MixEngine.shared.phonesOutput) {
        self.model = model
        self.output = output
    }

    var body: some View {
        Section {
            DJHeadphoneOutputPicker(output: output)
            Toggle("Split Cue", isOn: Binding(get: { model.splitCue }, set: { model.splitCue = $0 }))
        } header: {
            Text("Headphones")
        } footer: {
            if let failure = output.failure {
                Text(failure)
            } else {
                Text(model.splitCue
                    ? "Cue in your left ear, the master in your right."
                    : "Cue Mix blends the cue and the master. With no deck cued, the phones stay silent until you turn Cue Mix towards Master.")
            }
        }
    }
}

struct DJMixerCurvesSection: View {
    @ObservedObject var model: DJMixerModel

    init(model: DJMixerModel = .shared) {
        self.model = model
    }

    var body: some View {
        Section("Mixer") {
            Picker("Crossfader", selection: Binding(get: { model.crossfaderCurve }, set: { model.crossfaderCurve = $0 })) {
                ForEach(DJCrossfaderCurve.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Channel Faders", selection: Binding(get: { model.faderCurve }, set: { model.faderCurve = $0 })) {
                ForEach(DJChannelFaderCurve.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        }
    }
}

struct DJMixerSettingsForm: View {
    var model: DJMixerModel = .shared

    var body: some View {
        Form {
            DJHeadphoneSettingsSection(model: model)
            DJMixerCurvesSection(model: model)
        }
        .formStyle(.grouped)
    }
}
