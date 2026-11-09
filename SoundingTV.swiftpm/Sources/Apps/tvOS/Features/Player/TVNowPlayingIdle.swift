import SwiftUI
import UIKit

@MainActor
final class NPIdleMonitor: ObservableObject {
    @Published private(set) var isIdle = false

    private var timeout: TimeInterval = NPIdleMonitor.defaultTimeout
    private var lastInput = Date.now
    private var eligible = false
    private var spy: InputSpyRecognizer?
    private var waiter: Task<Void, Never>?

    static var defaultTimeout: TimeInterval {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["SOUNDING_TV_NP_IDLE_AFTER"], let seconds = Double(raw), seconds > 0 {
            return seconds
        }
        #endif
        return 20
    }

    deinit {
        waiter?.cancel()
    }

    func setEligible(_ value: Bool) {
        guard value != eligible else { return }
        eligible = value
        if value {
            lastInput = .now
            attachSpy()
            arm()
        } else {
            waiter?.cancel()
            waiter = nil
            detachSpy()
            if isIdle { isIdle = false }
        }
    }

    func wake() {
        lastInput = .now
        guard isIdle else { return }
        isIdle = false
        arm()
    }

    private func noteInput() {
        guard !isIdle else { return }
        lastInput = .now
    }

    private func arm() {
        waiter?.cancel()
        waiter = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.eligible else { return }
                let remaining = self.timeout - Date.now.timeIntervalSince(self.lastInput)
                if remaining <= 0 {
                    self.isIdle = true
                    return
                }
                try? await Task.sleep(for: .seconds(remaining))
            }
        }
    }

    private func attachSpy() {
        guard spy == nil, let window = Self.keyWindow else { return }
        let recognizer = InputSpyRecognizer()
        recognizer.onInput = { [weak self] in self?.noteInput() }
        window.addGestureRecognizer(recognizer)
        spy = recognizer
    }

    private func detachSpy() {
        if let spy { spy.view?.removeGestureRecognizer(spy) }
        spy = nil
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
}

struct NPAmbientOverlay: View {
    let title: String
    let artist: String
    var artistTint: Color = Color.white.opacity(0.66)
    var isCentred = true

    var body: some View {
        ZStack {
            TimelineView(.everyMinute) { context in
                Text(context.date.formatted(date: .omitted, time: .shortened))
                    .font(.title3.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.trailing, 100)
                    .padding(.top, 64)
            }
            VStack(alignment: isCentred ? .center : .leading, spacing: 6) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(artist)
                    .font(.headline.weight(.medium))
                    .foregroundStyle(artistTint)
                    .lineLimit(1)
            }
            .multilineTextAlignment(isCentred ? .center : .leading)
            .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
            .frame(width: isCentred ? 1600 : 600, alignment: isCentred ? .center : .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: isCentred ? .top : .topLeading)
            .padding(.leading, isCentred ? 0 : 145)
            .padding(.top, 840)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Now Playing, \(title) by \(artist)")
    }
}
