import SwiftUI
import Combine

@MainActor
final class DJMixerModel: ObservableObject {
    static let shared: DJMixerModel = {
        #if DEBUG
        if DJMixerHarness.fixtureName != nil {
            DJMixerHarness.applyFixtureMixer(to: .shared)
            return DJMixerModel(surface: MacDeckControlSurface.shared, engine: .shared, isLive: false)
        }
        #endif
        return DJMixerModel(surface: MacDeckControlSurface.shared, engine: .shared)
    }()

    @Published private(set) var meters = DJMixerMeters()

    let surface: DeckControlSurface
    let engine: MixEngine
    private var cancellables = Set<AnyCancellable>()
    private var meterTask: Task<Void, Never>?
    private var meterClients = 0
    private var timingTask: Task<Void, Never>?
    private var fxRates: [Double] = [1, 1]

    private enum Keys {
        static let cueMix = "dj.mixer.cueMix"
        static let phones = "dj.mixer.phones"
        static let split = "dj.mixer.splitCue"
        static let crossfader = "dj.mixer.crossfaderCurve"
        static let fader = "dj.mixer.faderCurve"
    }

    init(surface: DeckControlSurface, engine: MixEngine, isLive: Bool = true) {
        self.surface = surface
        self.engine = engine
        if isLive {
            restorePreferences()
            if engine.phonesOutput.route != nil { engine.phonesOutput.start() }
        }
        engine.$masterVolume.map { _ in () }
            .merge(with: engine.$mixer.map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Mixer controls

    static func address(_ control: DeckControl, deck: MixEngine.Deck? = nil) -> DeckControlAddress {
        DeckControlAddress(group: deck.map { .deck($0) } ?? .mixer, control: control)
    }

    func value(_ address: DeckControlAddress) -> Double {
        surface.value(of: address) ?? (address.control == .masterLevel ? 1 : 0)
    }

    func set(_ address: DeckControlAddress, _ value: Double) {
        surface.setValue(min(1, max(0, value)), for: address)
    }

    func toggle(_ address: DeckControlAddress) {
        surface.press(address, isDown: true)
        surface.press(address, isDown: false)
    }

    func isCued(_ deck: MixEngine.Deck) -> Bool { engine.mixer.cue(deck) }

    func toggleCue(_ deck: MixEngine.Deck) {
        toggle(Self.address(.headphoneCue, deck: deck))
    }

    func valueText(_ control: DeckControl) -> String {
        let v = value(Self.address(control))
        switch control {
        case .masterLevel, .phonesLevel: return DJMixerUnits.decibelLabel(gain: DJMixerUnits.levelGain(knob: v))
        case .cueMix:
            if v < 0.05 { return "Cue" }
            if v > 0.95 { return "Master" }
            return abs(v - 0.5) < 0.05 ? "Even" : (v < 0.5 ? "More Cue" : "More Master")
        default: return ""
        }
    }

    // MARK: - Meters

    func startMetering() {
        meterClients += 1
        startFXTiming()
        guard meterTask == nil else { return }
        meterTask = Task { @MainActor [weak self] in
            let started = Date()
            while !Task.isCancelled {
                guard let self else { return }
                self.meters.update(self.engine.takeMeters(), at: Date().timeIntervalSince(started))
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
    }

    func stopMetering() {
        meterClients = max(0, meterClients - 1)
        guard meterClients == 0 else { return }
        meterTask?.cancel()
        meterTask = nil
    }

    // MARK: - FX

    func fx(_ deck: MixEngine.Deck) -> MixEngine.DeckFX { engine.mixer.fx(deck) }

    func selectFX(_ kind: MixFXKind, on deck: MixEngine.Deck) {
        engine.setDeckFX(kind, beats: fx(deck).beats, on: deck)
    }

    func selectFXBeats(_ beats: Double, on deck: MixEngine.Deck) {
        engine.setDeckFX(fx(deck).kind, beats: beats, on: deck)
    }

    func setFXAmount(_ amount: Double, on deck: MixEngine.Deck) {
        set(Self.address(.fxAmount, deck: deck), amount)
    }

    func toggleFX(on deck: MixEngine.Deck) {
        toggle(Self.address(.fxToggle, deck: deck))
    }

    private func startFXTiming() {
        guard timingTask == nil else { return }
        timingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                for deck in MixEngine.Deck.allCases {
                    let rate = self.engine[deck].rate
                    if abs(rate - self.fxRates[deck.rawValue]) > 0.002 {
                        self.fxRates[deck.rawValue] = rate
                        self.engine.refreshDeckFXTiming(on: deck)
                    }
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    // MARK: - Preferences

    var splitCue: Bool {
        get { engine.mixer.splitCue }
        set {
            engine.setSplitCue(newValue)
            UserDefaults.standard.set(newValue, forKey: Keys.split)
        }
    }

    var crossfaderCurve: DJCrossfaderCurve {
        get { engine.mixer.crossfaderCurve }
        set {
            engine.setCrossfaderCurve(newValue)
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.crossfader)
        }
    }

    var faderCurve: DJChannelFaderCurve {
        get { engine.mixer.faderCurve }
        set {
            engine.setChannelFaderCurve(newValue)
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.fader)
        }
    }

    func persistLevels() {
        UserDefaults.standard.set(engine.mixer.cueMix, forKey: Keys.cueMix)
        UserDefaults.standard.set(engine.mixer.phonesLevel, forKey: Keys.phones)
    }

    private func restorePreferences() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Keys.cueMix) != nil { engine.setCueMix(defaults.double(forKey: Keys.cueMix)) }
        if defaults.object(forKey: Keys.phones) != nil { engine.setPhonesLevel(defaults.double(forKey: Keys.phones)) }
        if defaults.bool(forKey: Keys.split) { engine.setSplitCue(true) }
        if let raw = defaults.string(forKey: Keys.crossfader), let curve = DJCrossfaderCurve(rawValue: raw) { engine.setCrossfaderCurve(curve) }
        if let raw = defaults.string(forKey: Keys.fader), let curve = DJChannelFaderCurve(rawValue: raw) { engine.setChannelFaderCurve(curve) }
    }
}

struct DJMixerMeters: Equatable {
    var a = DJMeterBallistics()
    var b = DJMeterBallistics()
    var master = DJMeterBallistics()
    var masterLeft = DJMeterBallistics()
    var masterRight = DJMeterBallistics()
    var phones = DJMeterBallistics()

    func deck(_ deck: MixEngine.Deck) -> DJMeterBallistics { deck == .a ? a : b }

    mutating func update(_ readings: MixEngine.Meters, at time: Double) {
        a.update(readings.a, at: time)
        b.update(readings.b, at: time)
        master.update(readings.master, at: time)
        masterLeft.update(readings.masterLeft, at: time)
        masterRight.update(readings.masterRight, at: time)
        phones.update(readings.phones, at: time)
    }

    static func display(a: Double, b: Double, master: Double, clipping: Bool = false) -> DJMixerMeters {
        func amplitude(_ fraction: Double) -> Float {
            fraction <= 0 ? 0 : Float(pow(10, (min(1, fraction) * 48 - 48) / 20))
        }
        func reading(_ fraction: Double, clips: Int = 0) -> MixMeterReading {
            MixMeterReading(peak: amplitude(min(1, fraction + 0.08)), rms: amplitude(fraction), clips: clips)
        }
        var meters = DJMixerMeters()
        meters.a.update(reading(a), at: 0)
        meters.b.update(reading(b), at: 0)
        meters.master.update(reading(master, clips: clipping ? 1 : 0), at: 0)
        meters.masterLeft.update(reading(master), at: 0)
        meters.masterRight.update(reading(master * 0.98), at: 0)
        return meters
    }
}
