import Observation
import SwiftUI
#if os(iOS) || os(macOS)
@preconcurrency import Translation
#endif

@MainActor
@Observable
final class LyricsTranslator {
    static let shared = LyricsTranslator()
    static let enabledKey = "lyrics.translate.v1"
    private static let memoryLimit = 24

    #if os(iOS) || os(macOS)
    static let isSupported = true
    #else
    static let isSupported = false
    #endif

    enum Phase: Equatable, Sendable {
        case unavailable
        case available
        case translating
        case translated
    }

    struct Offer: Hashable, Sendable {
        var source: String
        var target: String
        var texts: [String]
    }

    var isOn: Bool {
        didSet { UserDefaults.standard.set(isOn, forKey: Self.enabledKey) }
    }

    private(set) var offers: [String: Offer] = [:]
    private(set) var results: [String: LyricsTranslation] = [:]
    private(set) var running: Set<String> = []
    private(set) var failed: Set<String> = []
    private var checked: Set<String> = []
    private var order: [String] = []

    private init() {
        isOn = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    func offer(for trackID: String?) -> Offer? {
        trackID.flatMap { offers[$0] }
    }

    func translation(for trackID: String?) -> LyricsTranslation? {
        guard isOn, let trackID, let offer = offers[trackID] else { return nil }
        return results[Self.resultKey(trackID, offer.target)]
    }

    func phase(for trackID: String?) -> Phase {
        guard let trackID, let offer = offers[trackID] else { return .unavailable }
        if running.contains(trackID) { return .translating }
        if isOn, results[Self.resultKey(trackID, offer.target)] != nil { return .translated }
        return .available
    }

    func needsWork(_ trackID: String?) -> Offer? {
        guard isOn, let trackID, let offer = offers[trackID], !running.contains(trackID), !failed.contains(trackID),
              results[Self.resultKey(trackID, offer.target)] == nil else { return nil }
        return offer
    }

    func toggle(_ trackID: String?) {
        if !isOn, let trackID { failed.remove(trackID) }
        isOn.toggle()
    }

    func prepare(trackID: String, body: LyricsBody) async {
        guard Self.isSupported, !checked.contains(trackID) else { return }
        checked.insert(trackID)
        remember(trackID)
        let texts = LyricsTranslation.sourceTexts(body)
        guard !texts.isEmpty else { return }
        let target = LyricsTranslation.preferredTarget
        guard let source = await Self.detect(texts),
              LyricsTranslation.needsTranslation(source: source, target: target),
              await Self.canTranslate(from: source, to: target) else { return }
        offers[trackID] = Offer(source: source, target: target, texts: texts)
    }

    func begin(_ trackID: String) {
        running.insert(trackID)
    }

    func finish(_ trackID: String, _ translation: LyricsTranslation) {
        running.remove(trackID)
        results[Self.resultKey(trackID, translation.target)] = translation
    }

    func fail(_ trackID: String) {
        running.remove(trackID)
        failed.insert(trackID)
        isOn = false
    }

    private func remember(_ trackID: String) {
        order.removeAll { $0 == trackID }
        order.append(trackID)
        while order.count > Self.memoryLimit {
            let dropped = order.removeFirst()
            checked.remove(dropped)
            failed.remove(dropped)
            if let offer = offers.removeValue(forKey: dropped) {
                results[Self.resultKey(dropped, offer.target)] = nil
            }
        }
    }

    private static func resultKey(_ trackID: String, _ target: String) -> String {
        "\(trackID)|\(target)"
    }

    private nonisolated static func detect(_ texts: [String]) async -> String? {
        LyricsTranslation.detectLanguage(texts)
    }

    private nonisolated static func canTranslate(from source: String, to target: String) async -> Bool {
        #if os(iOS) || os(macOS)
        let availability = LanguageAvailability()
        let status = await availability.status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
        return status != .unsupported
        #else
        return false
        #endif
    }
}

#if os(iOS) || os(macOS)
struct LyricsTranslationJob: Sendable {
    var trackID: String
    var target: String
    var texts: [String]

    static let idle = LyricsTranslationJob(trackID: "", target: "", texts: [])

    func run(_ session: TranslationSession) async {
        guard !trackID.isEmpty, !texts.isEmpty else { return }
        await LyricsTranslator.shared.begin(trackID)
        do {
            let requests = texts.enumerated().map {
                TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset))
            }
            let responses = try await session.translations(from: requests)
            var pairs: [(source: String, translated: String)] = []
            for response in responses {
                guard let index = response.clientIdentifier.flatMap(Int.init), texts.indices.contains(index) else { continue }
                pairs.append((texts[index], response.targetText))
            }
            await LyricsTranslator.shared.finish(trackID, LyricsTranslation(target: target, pairs: pairs))
        } catch {
            await LyricsTranslator.shared.fail(trackID)
        }
    }
}
#endif

struct LyricsTranslationHost: ViewModifier {
    let trackID: String?
    let lyrics: LyricsBody?
    let style: LyricsStyle

    private let translator = LyricsTranslator.shared
    #if os(iOS) || os(macOS)
    @State private var configuration: TranslationSession.Configuration?
    @State private var job = LyricsTranslationJob.idle
    #endif

    private struct PrepareKey: Equatable {
        var trackID: String?
        var count: Int
    }

    func body(content: Content) -> some View {
        #if os(iOS) || os(macOS)
        content
            .overlay(alignment: .topTrailing) { control }
            .task(id: PrepareKey(trackID: trackID, count: lyrics.map { LyricsTranslation.sourceTexts($0).count } ?? 0)) {
                guard let trackID, let lyrics else { return }
                await translator.prepare(trackID: trackID, body: lyrics)
            }
            .onChange(of: translator.needsWork(trackID), initial: true) { _, offer in
                request(offer)
            }
            .translationTask(configuration, action: job.run)
        #else
        content
        #endif
    }

    #if os(iOS) || os(macOS)
    @ViewBuilder
    private var control: some View {
        let phase = translator.phase(for: trackID)
        if phase != .unavailable, lyrics != nil {
            LyricsTranslateButton(isOn: translator.isOn, isWorking: phase == .translating, style: style) {
                translator.toggle(trackID)
            }
            .padding(.top, style.kind == .mac ? 4 : 2)
            .padding(.trailing, max(8, style.horizontalInset - 12))
            .transition(.opacity)
        }
    }

    private func request(_ offer: LyricsTranslator.Offer?) {
        guard let trackID, let offer else { return }
        job = LyricsTranslationJob(trackID: trackID, target: offer.target, texts: offer.texts)
        let source = Locale.Language(identifier: offer.source)
        let target = Locale.Language(identifier: offer.target)
        if configuration?.source == source, configuration?.target == target {
            configuration?.invalidate()
        } else {
            configuration = TranslationSession.Configuration(source: source, target: target)
        }
    }
    #endif
}

#if os(iOS) || os(macOS)
struct LyricsTranslateButton: View {
    let isOn: Bool
    let isWorking: Bool
    let style: LyricsStyle
    let action: () -> Void

    private var isMac: Bool { style.kind == .mac }

    var body: some View {
        if isOn {
            button
                .buttonStyle(.glassProminent)
                .tint(.white)
                .foregroundStyle(.black)
        } else {
            button
                .buttonStyle(.glass)
        }
    }

    private var button: some View {
        Button(action: action) {
            Group {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .tint(isOn ? .black : .white)
                } else {
                    Image(systemName: "translate")
                        .font(isMac ? .body : .title3)
                }
            }
            .frame(width: isMac ? 18 : 30, height: isMac ? 18 : 30)
        }
        .controlSize(isMac ? .regular : .large)
        .buttonBorderShape(.circle)
        .help(isOn ? "Show Original Lyrics" : "Translate Lyrics")
        .accessibilityLabel("Translate Lyrics")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
#endif

extension View {
    func lyricsTranslation(trackID: String?, lyrics: LyricsBody?, style: LyricsStyle) -> some View {
        modifier(LyricsTranslationHost(trackID: trackID, lyrics: lyrics, style: style))
    }
}
