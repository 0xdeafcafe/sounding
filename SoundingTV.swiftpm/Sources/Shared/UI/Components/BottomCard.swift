import SwiftUI
import Combine

// MARK: - Presentation

#if os(iOS)
private struct BottomCardOverlay<Item: Identifiable, Phase: Equatable, Card: View>: ViewModifier {
    let item: Item?
    let isDismissible: Bool
    let phase: Phase
    let onDismiss: () -> Void
    let onAppear: (Item) -> Void
    let card: (Item) -> Card

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var drag: CGFloat = 0
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var centred: Bool { sizeClass == .regular }

    func body(content: Content) -> some View {
        content.overlay {
            ZStack(alignment: centred ? .center : .bottom) {
                if let item, centred {
                    scrim

                    card(item)
                        .frame(width: 400)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 36, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            Button { onDismiss() } label: {
                                Image(systemName: "xmark")
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 30, height: 30)
                                    .background(.quaternary, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!isDismissible)
                            .accessibilityLabel("Not Now")
                            .padding(14)
                        }
                        .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.scale(scale: 0.88).combined(with: .opacity))
                        .onAppear { onAppear(item) }
                } else if let item {
                    scrim

                    card(item)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 44, style: .continuous))
                        .overlay(alignment: .top) {
                            Capsule()
                                .fill(.tertiary)
                                .frame(width: 36, height: 5)
                                .padding(.top, 8)
                                .accessibilityHidden(true)
                        }
                        .offset(y: max(0, drag))
                        .gesture(
                            DragGesture()
                                .updating($drag) { value, state, _ in state = value.translation.height }
                                .onEnded { value in
                                    if value.translation.height > 90 || value.predictedEndTranslation.height > 240 {
                                        onDismiss()
                                    }
                                }
                        )
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                        .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.move(edge: .bottom).combined(with: .opacity))
                        .onAppear { onAppear(item) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: centred ? .center : .bottom)
            .ignoresSafeArea(.container, edges: centred ? [] : .bottom)
            .animation(
                reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.86),
                value: item?.id
            )
            .animation(.easeInOut(duration: 0.2), value: phase)
        }
    }

    private var scrim: some View {
        Color.black.opacity(0.22)
            .ignoresSafeArea()
            .onTapGesture { if isDismissible { onDismiss() } }
            .transition(.opacity)
            .accessibilityHidden(true)
    }
}
#endif

#if os(macOS)
private struct BottomCardSheet<Item: Identifiable, Phase: Equatable, Card: View>: ViewModifier {
    let item: Item?
    let phase: Phase
    let onDismiss: () -> Void
    let onAppear: (Item) -> Void
    let card: (Item) -> Card

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { item },
            set: { if $0 == nil { onDismiss() } }
        )) { item in
            card(item)
                .frame(width: 400)
                .onAppear { onAppear(item) }
                .animation(.easeInOut(duration: 0.2), value: phase)
        }
    }
}
#endif

extension View {
    @ViewBuilder
    func bottomCard<Item: Identifiable, Phase: Equatable, Card: View>(
        item: Item?,
        isDismissible: Bool = true,
        phase: Phase,
        onDismiss: @escaping () -> Void,
        onAppear: @escaping (Item) -> Void = { _ in },
        @ViewBuilder card: @escaping (Item) -> Card
    ) -> some View {
        #if os(iOS)
        modifier(BottomCardOverlay(item: item, isDismissible: isDismissible, phase: phase, onDismiss: onDismiss, onAppear: onAppear, card: card))
        #elseif os(macOS)
        modifier(BottomCardSheet(item: item, phase: phase, onDismiss: onDismiss, onAppear: onAppear, card: card))
        #else
        self
        #endif
    }
}

// MARK: - Buttons

#if !os(macOS)
struct BottomCardPlainButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }
}

struct BottomCardProminentButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.extraLarge)
        .keyboardShortcut(.defaultAction)
    }
}
#endif

// MARK: - Reconnect

@MainActor
final class ReconnectCardModel: ObservableObject {
    struct Offer: Identifiable, Equatable {
        var id: String { "reconnect" }
    }

    static let shared = ReconnectCardModel()

    @Published private(set) var offer: Offer?
    @Published var isSigningIn = false

    private let credentials: SoundCloudCredentialSource
    private var isDismissed = false
    private var wasNeedingReconnect = false
    private var subscription: AnyCancellable?

    init(credentials: SoundCloudCredentialSource = .shared) {
        self.credentials = credentials
        refresh()
        subscription = credentials.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    func notNow() {
        isDismissed = true
        refresh()
    }

    func reconnect() {
        isDismissed = true
        refresh()
        #if os(macOS)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            self?.isSigningIn = true
        }
        #else
        isSigningIn = true
        #endif
    }

    private func refresh() {
        let needsReconnect = credentials.accountStatus == .needsReconnect
        if needsReconnect, !wasNeedingReconnect { isDismissed = false }
        wasNeedingReconnect = needsReconnect
        let next = needsReconnect && !isDismissed ? Offer() : nil
        if offer != next { offer = next }
    }
}

struct ReconnectCard: View {
    let reconnect: () -> Void
    let notNow: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 92, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.scAccent)
                .frame(height: 132)
                .accessibilityHidden(true)
                .padding(.bottom, 14)

            Text("Reconnect SoundCloud")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.bottom, 12)

            Text("Sign in again to get your picks, likes and library back.")
                .font(.body)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 44, alignment: .top)
                .padding(.bottom, 20)

            actions
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(maxWidth: 440)
        .tint(Color.scAccent)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    #if os(macOS)
    private var actions: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            Button("Not Now", action: notNow)
                .keyboardShortcut(.cancelAction)
            Button("Reconnect", action: reconnect)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
    }
    #else
    private var actions: some View {
        VStack(spacing: 6) {
            BottomCardProminentButton(title: "Reconnect", action: reconnect)
            BottomCardPlainButton(title: "Not Now", action: notNow)
                .keyboardShortcut(.cancelAction)
        }
    }
    #endif
}

private struct ReconnectCardHost<SignIn: View>: ViewModifier {
    @ObservedObject var model: ReconnectCardModel
    @ObservedObject var nearby: NearbyDeviceCardModel
    let isEnabled: Bool
    let signIn: (@escaping () -> Void) -> SignIn

    func body(content: Content) -> some View {
        content
            .bottomCard(
                item: isEnabled && nearby.candidate == nil ? model.offer : nil,
                phase: false,
                onDismiss: { model.notNow() }
            ) { _ in
                ReconnectCard(reconnect: { model.reconnect() }, notNow: { model.notNow() })
            }
            .sheet(isPresented: $model.isSigningIn) {
                signIn { model.isSigningIn = false }
            }
    }
}

extension View {
    func reconnectCard<SignIn: View>(
        yieldingTo nearby: NearbyDeviceCardModel,
        isEnabled: Bool,
        @ViewBuilder signIn: @escaping (@escaping () -> Void) -> SignIn
    ) -> some View {
        modifier(ReconnectCardHost(model: .shared, nearby: nearby, isEnabled: isEnabled, signIn: signIn))
    }
}
