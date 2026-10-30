import SwiftUI

/// A failed restore is not a new conversation. Keep its recovery action
/// visible while the composer remains unable to send into an empty view.
struct SessionRecoveryView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ScrollView {
            ContentUnavailableView {
                Label("Session Not Loaded", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)
            } description: {
                Text(message)
                    .foregroundStyle(Color(nsColor: Theme.quietLabel))
            } actions: {
                Button("Retry Loading Session", action: retry)
            }
            .padding(Theme.Spacing.large)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center, for: .alignment)
        .accessibilityLabel("Session recovery")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
