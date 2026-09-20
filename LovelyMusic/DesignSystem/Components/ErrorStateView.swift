import SwiftUI

struct ErrorStateView: View {
    let message: String
    let retryAction: (() -> Void)?

    @State private var isExpanded = false

    init(_ message: String, retryAction: (() -> Void)? = nil) {
        self.message = message
        self.retryAction = retryAction
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(Theme.Colors.warning)

            Text(message)
                .font(Theme.Typography.subheadline)
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)

            if let retryAction {
                Button("Retry", action: retryAction)
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.vertical, Theme.Spacing.sm)
                    .background(Theme.Colors.surfaceCard)
                    .clipShape(Capsule())
            }
        }
        .padding()
        .expandTransition(isExpanded: isExpanded)
        .onAppear { isExpanded = true }
    }
}
