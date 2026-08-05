import SwiftUI

/// Indicates that an exact saved search is visible while it is refreshed.
struct SearchCacheRefreshNotice: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text("Refreshing saved results…")
                .font(.scCaption)
        }
        .foregroundStyle(Color.scTextSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityLabel("Refreshing saved search results")
    }
}
