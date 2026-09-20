import SwiftUI

struct ForceUpdateView: View {
    let message: String
    let appStoreURL: String
    let minRequiredVersion: String

    @Environment(\.openURL) private var openURL

    private var displayMessage: String {
        message.isEmpty
            ? String(localized: "A new version is available. Please update to continue using LovelyMusic.")
            : message
    }

    private var hasValidAppStoreURL: Bool {
        guard !appStoreURL.isEmpty, let url = URL(string: appStoreURL) else { return false }
        return url.scheme == "https" || url.scheme == "itms-apps"
    }

    var body: some View {
        ZStack {
            Theme.Colors.backgroundPrimary
                .ignoresSafeArea()

            VStack(spacing: Theme.Spacing.xl) {
                Spacer()

                // Update illustration
                ZStack {
                    Circle()
                        .fill(Theme.Colors.brandGradientStart.opacity(0.1))
                        .frame(width: 140, height: 140)

                    Circle()
                        .fill(Theme.Colors.brandGradientEnd.opacity(0.1))
                        .frame(width: 110, height: 110)

                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 44, weight: .medium))
                        .foregroundStyle(Theme.Colors.brandGradient)
                }

                VStack(spacing: Theme.Spacing.md) {
                    Text("Update Required")
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .multilineTextAlignment(.center)

                    Text(displayMessage)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Theme.Spacing.xxl)
                }

                // Version info
                versionBadge

                Spacer()

                if hasValidAppStoreURL {
                    Button {
                        if let url = URL(string: appStoreURL) {
                            openURL(url)
                        }
                    } label: {
                        Text("Update Now")
                            .font(Theme.Typography.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.Spacing.lg)
                            .background(Theme.Colors.brandGradient)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.medium))
                    }
                    .padding(.horizontal, Theme.Spacing.xxl)
                } else {
                    Text("Please update via the App Store.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textTertiary)
                }

                Spacer()
                    .frame(height: Theme.Spacing.xxxl)
            }
        }
        .interactiveDismissDisabled()
    }

    // MARK: - Version Badge

    private var versionBadge: some View {
        HStack(spacing: Theme.Spacing.lg) {
            versionLabel(
                title: "Current",
                version: FeatureFlagManager.currentAppVersion,
                color: Theme.Colors.error
            )

            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(Theme.Colors.textTertiary)

            versionLabel(
                title: "Required",
                version: minRequiredVersion.isEmpty ? "—" : minRequiredVersion,
                color: Theme.Colors.success
            )
        }
        .padding(.vertical, Theme.Spacing.md)
        .padding(.horizontal, Theme.Spacing.xl)
        .background(Theme.Colors.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.small))
    }

    private func versionLabel(title: LocalizedStringKey, version: String, color: Color) -> some View {
        VStack(spacing: Theme.Spacing.xxs) {
            Text(title)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textTertiary)
            Text(version)
                .font(Theme.Typography.headline)
                .foregroundStyle(color)
        }
    }
}
