import AppIntents
import Foundation

enum PartyOutputChoice: String, AppEnum {
    case current
    case thisDevice
    case appleTV

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Output"
    static let caseDisplayRepresentations: [PartyOutputChoice: DisplayRepresentation] = [
        .current: "Current Output",
        .thisDevice: "This Device",
        .appleTV: "Apple TV",
    ]
}

enum PartyLightsChoice: String, AppEnum {
    case party
    case subtle
    case off

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Lights"
    static let caseDisplayRepresentations: [PartyLightsChoice: DisplayRepresentation] = [
        .party: "Party",
        .subtle: "Subtle",
        .off: "Leave Lights Alone",
    ]

    var intensity: LightingIntensity {
        switch self {
        case .party: return .party
        case .subtle: return .subtle
        case .off: return .off
        }
    }
}

enum PartySceneError: Error, CustomLocalizedStringResourceConvertible {
    case noAppleTV
    case output(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noAppleTV: return "There's no Apple TV linked to Sounding."
        case .output(let message): return "\(message)"
        }
    }
}

@MainActor
enum PartyScenes {
    #if os(tvOS)
    static func startParty(on choice: PartyOutputChoice, lights: LightingIntensity) async throws -> String {
        performPartyHere(lights: lights)
    }

    static func windDown(minutes: Double) -> String {
        performWindDownHere(minutes: minutes)
    }
    #else
    static weak var outputRouter: OutputRouter?

    static func startParty(on choice: PartyOutputChoice, lights: LightingIntensity) async throws -> String {
        if let router = outputRouter {
            let target: OutputDevice
            switch choice {
            case .current: target = router.current
            case .thisDevice: target = .thisDevice
            case .appleTV:
                guard let linked = router.linkedDevice else { throw PartySceneError.noAppleTV }
                target = linked
            }
            if target != router.current, let message = await router.move(to: target) {
                throw PartySceneError.output(message)
            }
            if router.isRemote {
                router.client.startPartyScene(lights: lights)
                return "Party Mode is on in \(router.current.name)."
            }
        } else if choice == .appleTV {
            throw PartySceneError.noAppleTV
        }
        return performPartyHere(lights: lights)
    }

    static func windDown(minutes: Double) -> String {
        if let router = outputRouter, router.isRemote {
            router.client.startWindDown(minutes: minutes)
            return "Winding down \(router.current.name) over \(minutesText(minutes))."
        }
        return performWindDownHere(minutes: minutes)
    }
    #endif

    @discardableResult
    static func performPartyHere(lights: LightingIntensity) -> String {
        WindDownController.shared.cancel()
        let player = PlayerService.shared
        if player.isDJSessionEnabled {
            player.setAutomaticMixEnabled(true)
        } else {
            player.startDJSession(configuration: SettingsStore.shared.djStartConfiguration)
        }
        if !player.isPlaying, player.currentTrack != nil { player.play() }
        #if canImport(HomeKit)
        let director = HomeLightingDirector.shared
        if lights != .off { director.applyParty(lights) }
        if lights == .off || director.selectedLights.isEmpty {
            return "Auto Mix is on."
        }
        return "Party Mode is on."
        #else
        return "Auto Mix is on."
        #endif
    }

    @discardableResult
    static func performWindDownHere(minutes: Double) -> String {
        WindDownController.shared.start(minutes: minutes)
        return "Winding down over \(minutesText(minutes))."
    }

    private static func minutesText(_ minutes: Double) -> String {
        let whole = max(1, Int(minutes.rounded()))
        return whole == 1 ? "1 minute" : "\(whole) minutes"
    }
}

struct PartyModeIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Party Mode"
    static let description = IntentDescription("Starts Auto Mix and sets your lights to follow the music.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Output", default: .current)
    var output: PartyOutputChoice

    @Parameter(title: "Lights", default: .party)
    var lights: PartyLightsChoice

    static var parameterSummary: some ParameterSummary {
        Summary("Start Party Mode on \(\.$output) with \(\.$lights) lights")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try await PartyScenes.startParty(on: output, lights: lights.intensity)
        return .result(dialog: "\(message)")
    }
}

struct WindDownIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Wind Down"
    static let description = IntentDescription("Fades the music out and dims your lights, then pauses.")
    static let supportedModes: IntentModes = .background

    @Parameter(title: "Minutes", default: 15, inclusiveRange: (1, 120))
    var minutes: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Wind down over \(\.$minutes) minutes")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = PartyScenes.windDown(minutes: Double(minutes))
        return .result(dialog: "\(message)")
    }
}
