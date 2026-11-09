import SwiftUI

struct LyricsPlayhead: Equatable, Sendable {
    var position: TimeInterval
    var date: Date
    var rate: Double

    static let idle = LyricsPlayhead(position: 0, date: .distantPast, rate: 0)

    func position(at date: Date) -> TimeInterval {
        max(0, position + rate * max(0, date.timeIntervalSince(self.date)))
    }
}

struct LyricsStyle: Sendable {
    enum Kind: Sendable { case phone, pad, mac, tv, watch }

    var kind: Kind
    var font: Font
    var lineSpacing: CGFloat
    var horizontalInset: CGFloat
    var anchor: CGFloat
    var dimmedOpacity: Double
    var followPause: TimeInterval = 4

    static let phone = LyricsStyle(kind: .phone, font: .title2.weight(.bold), lineSpacing: 22, horizontalInset: 24, anchor: 0.3, dimmedOpacity: 0.32)
    static let pad = LyricsStyle(kind: .pad, font: .largeTitle.weight(.bold), lineSpacing: 28, horizontalInset: 32, anchor: 0.32, dimmedOpacity: 0.3)
    static let mac = LyricsStyle(kind: .mac, font: .title.weight(.bold), lineSpacing: 22, horizontalInset: 28, anchor: 0.32, dimmedOpacity: 0.3)
    static let tv = LyricsStyle(kind: .tv, font: .title.weight(.bold), lineSpacing: 40, horizontalInset: 0, anchor: 0.38, dimmedOpacity: 0.3, followPause: 6)
    static let watch = LyricsStyle(kind: .watch, font: .title3.weight(.bold), lineSpacing: 10, horizontalInset: 4, anchor: 0.3, dimmedOpacity: 0.35)
}

// MARK: - Pane

struct NowPlayingLyrics: View {
    let track: Track?
    var nextTrack: Track?
    let playhead: LyricsPlayhead
    var style: LyricsStyle = .phone
    var onSeek: (TimeInterval) -> Void

    @ObservedObject private var settings = SettingsStore.shared
    private let store = LyricsStore.shared

    private struct FocusKey: Equatable {
        var current: String?
        var next: String?
        var provider: LyricsProvider
    }

    var body: some View {
        LyricsPane(
            state: store.state(for: track?.id),
            playhead: playhead,
            style: style,
            onSeek: onSeek,
            onRetry: track.map { track in { store.retry(track) } },
            onConsent: { settings.setLyricsSource($0 ? .lrclib : .off) }
        )
        .task(id: FocusKey(current: track?.id, next: nextTrack?.id, provider: settings.lyricsSource)) {
            store.focus(current: track, next: nextTrack)
        }
    }
}

struct LyricsPane: View {
    let state: LyricsState
    let playhead: LyricsPlayhead
    var style: LyricsStyle = .phone
    var onSeek: (TimeInterval) -> Void
    var onRetry: (() -> Void)?
    var onConsent: ((Bool) -> Void)?

    var body: some View {
        switch state {
        case .needsConsent:
            ContentUnavailableView {
                Label("Show Lyrics from LRCLIB?", systemImage: "quote.bubble")
            } description: {
                Text("Sounding sends the track's title, artist and length to lrclib.net, a free lyrics database, to find lyrics.")
            } actions: {
                Button("Show Lyrics") { onConsent?(true) }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                Button("Not Now") { onConsent?(false) }
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
            .lyricsStateBacking(style.kind == .phone)
        case .off:
            ContentUnavailableView {
                Label("Lyrics Are Off", systemImage: "quote.bubble")
            } description: {
                Text("Lyrics come from lrclib.net, a free lyrics database.")
            } actions: {
                Button("Turn On Lyrics") { onConsent?(true) }
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
            .lyricsStateBacking(style.kind == .phone)
        case .idle, .loading:
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Loading Lyrics")
        case .loaded(let lyrics):
            switch lyrics.body {
            case .synced(let lines):
                SyncedLyricsView(lines: LyricsTimeline.displayLines(lines), playhead: playhead, style: style, onSeek: onSeek)
            case .plain(let lines):
                PlainLyricsView(lines: lines, style: style)
            case .instrumental:
                LyricsUnavailable(title: "Instrumental", systemImage: "music.note", message: "This track has no lyrics.", style: style)
            }
        case .notFound:
            LyricsUnavailable(title: "No Lyrics for This Track", systemImage: "quote.bubble", message: nil, style: style)
        case .mix:
            LyricsUnavailable(title: "No Lyrics for Mixes", systemImage: "quote.bubble", message: "Lyrics aren't available for mixes.", style: style)
        case .offline:
            LyricsUnavailable(title: "You're Offline", systemImage: "wifi.slash", message: "Lyrics will load when you're connected.", style: style, onRetry: onRetry)
        case .unavailable:
            LyricsUnavailable(title: "Lyrics Unavailable", systemImage: "quote.bubble", message: "Try again in a moment.", style: style, onRetry: onRetry)
        }
    }
}

private struct LyricsUnavailable: View {
    let title: String
    let systemImage: String
    let message: String?
    var style: LyricsStyle = .phone
    var onRetry: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message { Text(message) }
        } actions: {
            if let onRetry {
                Button("Try Again", action: onRetry)
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
        }
        .lyricsStateBacking(style.kind == .phone)
    }
}

struct LyricsCredit: View {
    var body: some View {
        Text("Lyrics from LRCLIB")
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.5))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - Plain

struct PlainLyricsView: View {
    let lines: [String]
    let style: LyricsStyle

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: style.lineSpacing * 0.6) {
                Text("Lyrics not synced")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.bottom, 4)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    if line.isEmpty {
                        Color.clear.frame(height: style.lineSpacing * 0.4)
                            .accessibilityHidden(true)
                    } else {
                        Text(line)
                            .font(style.font)
                            .foregroundStyle(.white.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                LyricsCredit()
                    .padding(.top, style.lineSpacing)
            }
            .padding(.horizontal, style.horizontalInset)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        #if os(tvOS)
        .focusable()
        #endif
    }
}

// MARK: - Synced

struct SyncedLyricsView: View {
    let lines: [LyricsDisplayLine]
    let playhead: LyricsPlayhead
    let style: LyricsStyle
    var onSeek: (TimeInterval) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var active: Int?
    @State private var followResumesAt: Date = .distantPast
    @State private var isInteracting = false
    @State private var resumeTask: Task<Void, Never>?
    #if os(tvOS)
    @FocusState private var focused: Int?
    @State private var isMovingFocus = false
    #endif

    private struct TickKey: Equatable {
        var playhead: LyricsPlayhead
        var count: Int
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: style.lineSpacing) {
                        ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                            row(index: index, line: line)
                                .id(line.id)
                        }
                        LyricsCredit()
                            .padding(.top, style.lineSpacing)
                    }
                    .padding(.horizontal, style.horizontalInset)
                    .padding(.top, geometry.size.height * style.anchor)
                    .padding(.bottom, geometry.size.height * (1 - style.anchor))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
                .mask(edgeFade)
                .onScrollPhaseChange { _, phase in
                    let interacting = phase == .interacting || phase == .tracking || phase == .decelerating
                    guard interacting != isInteracting else { return }
                    isInteracting = interacting
                    if interacting {
                        resumeTask?.cancel()
                        followResumesAt = .distantFuture
                    } else {
                        scheduleResume(proxy)
                    }
                }
                .onChange(of: active) { _, index in
                    guard Date() >= followResumesAt else { return }
                    scroll(proxy, to: index, animated: true)
                    #if os(tvOS)
                    if let index, case .line(let line) = lines[index], focused != nil {
                        isMovingFocus = true
                        focused = line.id
                    }
                    #endif
                }
                .onAppear { scroll(proxy, to: currentIndex(), animated: false) }
                #if os(tvOS)
                .onChange(of: focused) { _, value in
                    if isMovingFocus {
                        isMovingFocus = false
                        return
                    }
                    guard value != nil else { return }
                    followResumesAt = .distantFuture
                    scheduleResume(proxy)
                }
                .defaultFocus($focused, currentLineID())
                #endif
            }
        }
        .task(id: TickKey(playhead: playhead, count: lines.count)) { await tick() }
        .onDisappear { resumeTask?.cancel() }
    }

    @ViewBuilder
    private func row(index: Int, line: LyricsDisplayLine) -> some View {
        let distance = active.map { index - $0 } ?? index + 1
        let isActive = distance == 0
        let blur = reduceMotion || isActive ? 0 : min(Double(abs(distance)) * 0.8, 3.2)
        let opacity = isActive ? 1 : (distance < 0 ? style.dimmedOpacity + 0.05 : style.dimmedOpacity)
        switch line {
        case .line(let lyric):
            Button {
                onSeek(lyric.start)
            } label: {
                LyricLineLabel(line: lyric, isActive: isActive, playhead: playhead, style: style, dimmedOpacity: isActive ? style.dimmedOpacity : opacity)
                    .blur(radius: blur)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(LyricLineButtonStyle(kind: style.kind))
            #if os(tvOS)
            .focused($focused, equals: line.id)
            #endif
            .accessibilityLabel(lyric.text)
            .accessibilityHint("Plays from this line")
            .accessibilityAddTraits(isActive ? .isSelected : [])
            .animation(reduceMotion ? nil : .smooth(duration: 0.45), value: active)
        case .interlude(_, let start, let end):
            InterludeDots(start: start, end: end, isActive: isActive, playhead: playhead, style: style)
                .opacity(isActive ? 1 : 0)
                .frame(height: isActive ? nil : 0, alignment: .top)
                .clipped()
                .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: active)
                .accessibilityHidden(true)
        }
    }

    private var edgeFade: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.08),
                .init(color: .black, location: 0.88),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func currentLineID() -> Int? {
        guard let index = currentIndex() else { return lines.first?.id }
        for line in lines[...index].reversed() {
            if case .line(let lyric) = line { return lyric.id }
        }
        return lines.first?.id
    }

    private func currentIndex() -> Int? {
        LyricsTimeline.activeIndex(in: lines, at: playhead.position(at: Date()))
    }

    private func tick() async {
        while !Task.isCancelled {
            let now = Date()
            let time = playhead.position(at: now)
            let index = LyricsTimeline.activeIndex(in: lines, at: time)
            if index != active {
                if reduceMotion {
                    active = index
                } else {
                    withAnimation(.smooth(duration: 0.45)) { active = index }
                }
            }
            guard playhead.rate > 0 else { return }
            let nextIndex = (index ?? -1) + 1
            let wait: TimeInterval
            if nextIndex < lines.count {
                wait = (lines[nextIndex].start - LyricsTimeline.leadIn - time) / playhead.rate
            } else {
                wait = 1
            }
            try? await Task.sleep(for: .seconds(min(1, max(0.03, wait))))
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to index: Int?, animated: Bool) {
        guard !lines.isEmpty else { return }
        let target = lines[max(0, min(lines.count - 1, index ?? 0))].id
        let anchor = UnitPoint(x: 0, y: style.anchor)
        if animated, !reduceMotion {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.86)) { proxy.scrollTo(target, anchor: anchor) }
        } else {
            proxy.scrollTo(target, anchor: anchor)
        }
    }

    private func scheduleResume(_ proxy: ScrollViewProxy) {
        resumeTask?.cancel()
        let delay = style.followPause
        followResumesAt = Date().addingTimeInterval(delay)
        resumeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            followResumesAt = .distantPast
            scroll(proxy, to: active, animated: true)
        }
    }
}

private struct LyricLineButtonStyle: ButtonStyle {
    let kind: LyricsStyle.Kind
    #if os(tvOS)
    @Environment(\.isFocused) private var isFocused
    #endif

    func makeBody(configuration: Configuration) -> some View {
        #if os(tvOS)
        LyricLineFocusBody(configuration: configuration)
        #else
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
        #endif
    }
}

#if os(tvOS)
private struct LyricLineFocusBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .brightness(isFocused ? 0.25 : 0)
            .scaleEffect(isFocused ? 1.04 : (configuration.isPressed ? 0.98 : 1), anchor: .leading)
            .shadow(color: .black.opacity(isFocused ? 0.35 : 0), radius: 18, y: 10)
            .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: isFocused)
    }
}
#endif

private struct LyricLineLabel: View {
    let line: LyricLine
    let isActive: Bool
    let playhead: LyricsPlayhead
    let style: LyricsStyle
    let dimmedOpacity: Double

    var body: some View {
        if isActive, line.hasWordTiming {
            TimelineView(.animation(minimumInterval: 1 / 30, paused: playhead.rate == 0)) { context in
                text(at: playhead.position(at: context.date))
            }
        } else {
            Text(line.text)
                .font(style.font)
                .foregroundStyle(.white.opacity(isActive ? 1 : dimmedOpacity))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func text(at time: TimeInterval) -> some View {
        let words = line.words
        var combined = Text("")
        for (index, word) in words.enumerated() {
            let next = index + 1 < words.count ? words[index + 1].start : line.end
            let progress = LyricsTimeline.wordProgress(word, next: next, at: time)
            let opacity = dimmedOpacity + (1 - dimmedOpacity) * progress
            combined = combined + Text(word.text).foregroundStyle(.white.opacity(opacity))
        }
        return combined
            .font(style.font)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct InterludeDots: View {
    let start: TimeInterval
    let end: TimeInterval
    let isActive: Bool
    let playhead: LyricsPlayhead
    let style: LyricsStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var size: CGFloat {
        switch style.kind {
        case .tv: 22
        case .pad, .mac: 14
        case .phone: 12
        case .watch: 8
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !isActive || playhead.rate == 0 || reduceMotion)) { context in
            let time = playhead.position(at: context.date)
            let progress = end > start ? min(1, max(0, (time - start) / (end - start))) : 0
            let breathe = reduceMotion ? 1 : 1 + 0.08 * sin(context.date.timeIntervalSinceReferenceDate * 2.4)
            HStack(spacing: size * 0.7) {
                ForEach(0..<3, id: \.self) { dot in
                    let fill = min(1, max(0, progress * 3 - Double(dot)))
                    Circle()
                        .fill(.white.opacity(0.3 + 0.7 * fill))
                        .frame(width: size, height: size)
                }
            }
            .scaleEffect(breathe, anchor: .leading)
            .padding(.vertical, size * 0.5)
        }
    }
}

private extension View {
    func lyricsStateBacking(_ backed: Bool) -> some View {
        GeometryReader { proxy in
            ScrollView {
                self
                    .padding(24)
                    .background(backed ? Color.black.opacity(0.62) : Color.clear, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}
