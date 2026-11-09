import AppIntents
import Foundation

struct SetPlaybackIntent: SetValueIntent, AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    static let description = IntentDescription("Plays or pauses Sounding.")
    static let supportedModes: IntentModes = .background

    @available(iOS 27.0, macOS 27.0, watchOS 27.0, tvOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Playing")
    var value: Bool

    init() {}

    init(playing: Bool) {
        value = playing
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Set playback to \(\.$value)")
    }

    func perform() async throws -> some IntentResult {
        try await PlaybackControlBridge.setPlaying(value)
        return .result()
    }
}

struct SkipTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next Track"
    static let description = IntentDescription("Skips to the next track in Sounding.")
    static let supportedModes: IntentModes = .background

    @available(iOS 27.0, macOS 27.0, watchOS 27.0, tvOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    init() {}

    func perform() async throws -> some IntentResult {
        try await PlaybackControlBridge.skipToNext()
        return .result()
    }
}

struct MixNowIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Mix Now"
    static let description = IntentDescription("Starts the next Auto Mix transition in Sounding.")
    static let supportedModes: IntentModes = .background

    @available(iOS 27.0, macOS 27.0, watchOS 27.0, tvOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    init() {}

    func perform() async throws -> some IntentResult {
        try await PlaybackControlBridge.mixNow()
        return .result()
    }
}

struct ResumeLastSessionIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Resume"
    static let description = IntentDescription("Resumes your last session in Sounding.")
    static let supportedModes: IntentModes = .background

    @available(iOS 27.0, macOS 27.0, watchOS 27.0, tvOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    init() {}

    func perform() async throws -> some IntentResult {
        try await PlaybackControlBridge.setPlaying(true)
        return .result()
    }
}
