import SwiftUI

struct SearchCacheRefreshNotice: View {
    var body: some View {
        ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Refreshing results")
    }
}
