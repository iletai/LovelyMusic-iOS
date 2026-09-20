import SwiftUI

struct EmptyStateView: View {
    let icon: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var actionLabel: LocalizedStringKey?
    var onAction: (() -> Void)?

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: icon)
                .font(.system(size: 50))
                .foregroundStyle(Theme.Colors.textTertiary)
                .accessibilityHidden(true)

            Text(title)
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Colors.textPrimary)

            Text(message)
                .font(Theme.Typography.subheadline)
                .foregroundStyle(Theme.Colors.textSecondary)
                .multilineTextAlignment(.center)

            if let actionLabel, let onAction {
                Button(action: onAction) {
                    Text(actionLabel)
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .padding(.horizontal, Theme.Spacing.xl)
                        .padding(.vertical, Theme.Spacing.sm)
                        .frame(minHeight: Theme.SizeTokens.touchTarget)
                        .background(Theme.Colors.surfaceCard)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(Theme.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .expandTransition(isExpanded: isExpanded)
        .onAppear { isExpanded = true }
    }
}
