import SwiftUI

struct PhoneWelcomeView: View {
    enum Step: Hashable {
        case welcome
        case music
    }

    let step: Step
    let onUseWithoutSoundCloud: () -> Void
    let onMusicAnswered: (_ addedFolder: Bool) -> Void

    @State private var isSigningIn = false
    @StateObject private var continueOffer = ContinueAsOffer()
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private static let signInTint = MusicStepPage.tint

    private var pushesMusic: Bool { step == .music }

    var body: some View {
        ZStack {
            if pushesMusic {
                MusicStepPage(onAnswered: onMusicAnswered)
                    .frame(maxWidth: PadLayout.isPad ? 540 : .infinity, maxHeight: PadLayout.isPad ? 760 : .infinity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .systemBackground))
                    .transition(.push(from: .trailing))
            } else {
                welcomeScreen
                    .transition(.push(from: .trailing))
            }
        }
        .animation(.smooth, value: pushesMusic)
        .sheet(isPresented: $isSigningIn) {
            NavigationStack {
                SoundCloudLoginView.standalone {
                    isSigningIn = false
                }
            }
        }
    }

    private var welcomeScreen: some View {
        GeometryReader { proxy in
            let topInset = proxy.safeAreaInsets.top
            let artShare = dynamicTypeSize.isAccessibilitySize ? 0.3 : 0.58
            let artHeight = max(180, proxy.size.height * artShare) + topInset
            ScrollView {
                VStack(spacing: 0) {
                    SoundingWelcomeHero(seed: 0x50_4C_55_47, isActive: step == .welcome && !isSigningIn)
                        .frame(height: artHeight)

                    Spacer(minLength: 20)

                    welcome
                        .frame(maxWidth: 440)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 12)
                }
                .frame(minHeight: proxy.size.height + topInset, alignment: .top)
            }
            .scrollBounceBehavior(.basedOnSize)
            .ignoresSafeArea(edges: .top)
        }
    }

    private var welcome: some View {
        VStack(spacing: 28) {
            SoundingWelcomeTitle(title: SoundingWelcome.stackedHeadline)

            if let line = LinkedTVAccounts.welcomeLine() {
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 6) {
                ContinueAsOfferView(model: continueOffer)
                    .tint(Self.signInTint)
                    .padding(.bottom, 6)

                if continueOffer.offer == nil {
                    signInButton.buttonStyle(.glassProminent)
                } else {
                    signInButton.buttonStyle(.glass)
                }

                Button("Use Without SoundCloud", action: onUseWithoutSoundCloud)
                    .buttonStyle(.borderless)
                    .font(.callout.weight(.medium))
                    .tint(Self.signInTint)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("welcome.withoutSoundCloud")
            }
        }
        .onAppear { continueOffer.refresh(isSignedOut: true) }
    }

    private var signInButton: some View {
        Button { isSigningIn = true } label: {
            Text("Sign In with SoundCloud")
                .frame(maxWidth: .infinity)
        }
        .tint(Self.signInTint)
        .controlSize(.large)
        .accessibilityIdentifier("welcome.signIn")
    }
}
