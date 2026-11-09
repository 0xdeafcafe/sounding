import SwiftUI

struct OnboardingFeature: Identifiable, Hashable {
    let symbol: String
    let title: String
    let detail: String

    var id: String { title }
}

struct OnboardingAccount: Hashable {
    let name: String
    let avatarURL: URL?

    init(name: String, avatarURL: URL?) {
        self.name = name
        self.avatarURL = avatarURL
    }

    init(user: User) {
        self.init(name: user.displayName, avatarURL: user.avatarURL)
    }
}

struct OnboardingFeaturePage<Actions: View>: View {
    var account: OnboardingAccount?
    let symbol: String
    let title: String
    let features: [OnboardingFeature]
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        #if os(iOS)
        ScrollView {
            page
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actionStack
        }
        #else
        VStack(spacing: 0) {
            page
            Spacer(minLength: 0)
            actionStack
        }
        #endif
    }

    private var page: some View {
        VStack(spacing: Metrics.sectionSpacing) {
            if let account {
                OnboardingSignedInLine(account: account)
            }
            VStack(spacing: Metrics.titleSpacing) {
                Image(systemName: symbol)
                    .font(.system(size: Metrics.symbolSize))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.onboardingSymbol)
                    .accessibilityHidden(true)
                Text(title)
                    .font(Metrics.titleFont)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
                ForEach(features) { FeatureRow(feature: $0) }
            }
            .frame(maxWidth: Metrics.rowsWidth, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.top, Metrics.topPadding)
        .padding(.bottom, 24)
    }

    private var actionStack: some View {
        VStack(spacing: 8) {
            actions()
        }
        .frame(maxWidth: Metrics.actionsWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.top, 12)
        .padding(.bottom, Metrics.bottomPadding)
    }
}

struct FeatureRow: View {
    let feature: OnboardingFeature

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.rowIconSpacing) {
            Image(systemName: feature.symbol)
                .font(Metrics.rowSymbolFont)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.onboardingSymbol)
                .frame(width: Metrics.rowSymbolWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title)
                    .font(Metrics.rowTitleFont)
                Text(feature.detail)
                    .font(Metrics.rowDetailFont)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

struct OnboardingSignedInLine: View {
    let account: OnboardingAccount

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .green)
            if let url = account.avatarURL {
                SCArtworkResolver(url: url, variant: .thumbnail) { image in
                    if let image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "person.crop.circle.fill")
                            .resizable()
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: Metrics.avatarSize, height: Metrics.avatarSize)
                .clipShape(Circle())
            }
            Text("Signed in as \(Text(account.name).fontWeight(.semibold))")
                .lineLimit(1)
        }
        .font(Metrics.accountFont)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Signed in as \(account.name)")
    }
}

extension Color {
    fileprivate static let onboardingSymbol = Color.scAccent
}

private enum Metrics {
    #if os(tvOS)
    static let sectionSpacing: CGFloat = 48
    static let titleSpacing: CGFloat = 24
    static let symbolSize: CGFloat = 120
    static let titleFont = Font.title2.weight(.bold)
    static let rowSpacing: CGFloat = 36
    static let rowsWidth: CGFloat = 960
    static let rowIconSpacing: CGFloat = 32
    static let rowSymbolFont = Font.title2
    static let rowSymbolWidth: CGFloat = 72
    static let rowTitleFont = Font.headline
    static let rowDetailFont = Font.callout
    static let actionsWidth: CGFloat = 560
    static let horizontalPadding: CGFloat = 80
    static let topPadding: CGFloat = 60
    static let bottomPadding: CGFloat = 60
    static let avatarSize: CGFloat = 40
    static let accountFont = Font.callout
    #elseif os(macOS)
    static let sectionSpacing: CGFloat = 28
    static let titleSpacing: CGFloat = 14
    static let symbolSize: CGFloat = 64
    static let titleFont = Font.largeTitle.weight(.bold)
    static let rowSpacing: CGFloat = 20
    static let rowsWidth: CGFloat = 400
    static let rowIconSpacing: CGFloat = 16
    static let rowSymbolFont = Font.title
    static let rowSymbolWidth: CGFloat = 40
    static let rowTitleFont = Font.headline
    static let rowDetailFont = Font.body
    static let actionsWidth: CGFloat = 280
    static let horizontalPadding: CGFloat = 40
    static let topPadding: CGFloat = 28
    static let bottomPadding: CGFloat = 28
    static let avatarSize: CGFloat = 20
    static let accountFont = Font.callout
    #else
    static let sectionSpacing: CGFloat = 32
    static let titleSpacing: CGFloat = 16
    static let symbolSize: CGFloat = 72
    static let titleFont = Font.largeTitle.weight(.bold)
    static let rowSpacing: CGFloat = 24
    static let rowsWidth: CGFloat = 420
    static let rowIconSpacing: CGFloat = 16
    static let rowSymbolFont = Font.title
    static let rowSymbolWidth: CGFloat = 44
    static let rowTitleFont = Font.headline
    static let rowDetailFont = Font.subheadline
    static let actionsWidth: CGFloat = 440
    static let horizontalPadding: CGFloat = 32
    static let topPadding: CGFloat = 40
    static let bottomPadding: CGFloat = 16
    static let avatarSize: CGFloat = 22
    static let accountFont = Font.subheadline
    #endif
}

extension OnboardingFeature {
    static var ownMusic: [OnboardingFeature] {
        [
            OnboardingFeature(
                symbol: "music.note.list",
                title: "One Library",
                detail: "Your files play next to your SoundCloud likes."
            ),
            OnboardingFeature(
                symbol: "infinity",
                title: "Auto Mix and Decks",
                detail: "Mix your own tracks like any other."
            ),
            OnboardingFeature(
                symbol: "appletv",
                title: "On Your Apple TV",
                detail: "Apple TV plays them from this \(DeviceClass.current.displayName) over your home network."
            ),
        ]
    }

    static let tvOwnMusic: [OnboardingFeature] = [
        OnboardingFeature(
            symbol: "macbook.and.iphone",
            title: "From Your Devices",
            detail: "Choose music folders in Sounding on your Mac, iPhone or iPad."
        ),
        OnboardingFeature(
            symbol: "house",
            title: "Over Your Home Network",
            detail: "Plays straight from them while Sounding is open."
        ),
        OnboardingFeature(
            symbol: "icloud",
            title: "From iCloud",
            detail: "Plays when they’re away, with Upload to iCloud turned on."
        ),
    ]
}
