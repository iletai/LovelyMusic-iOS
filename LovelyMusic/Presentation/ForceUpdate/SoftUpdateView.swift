import SwiftUI

struct SoftUpdateView: View {
    let recommendedVersion: String
    let changelog: String
    let appStoreURL: String
    let onDismiss: () -> Void

    @Environment(\.openURL) private var openURL

    private var hasValidAppStoreURL: Bool {
        guard !appStoreURL.isEmpty, let url = URL(string: appStoreURL) else { return false }
        return url.scheme == "https" || url.scheme == "itms-apps"
    }

    var body: some View {
        ZStack {
            Theme.Colors.backgroundPrimary
                .ignoresSafeArea()

            VStack(spacing: Theme.Spacing.xl) {
                // Drag indicator
                Capsule()
                    .fill(Theme.Colors.textTertiary)
                    .frame(width: 36, height: 4)
                    .padding(.top, Theme.Spacing.md)

                Spacer()

                // Illustration
                ZStack {
                    Circle()
                        .fill(Theme.Colors.info.opacity(0.1))
                        .frame(width: 120, height: 120)

                    Image(systemName: "gift.fill")
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(Theme.Colors.info)
                }

                VStack(spacing: Theme.Spacing.md) {
                    Text("Update Available")
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .multilineTextAlignment(.center)

                    Text(String(
                        localized: "Version \(recommendedVersion) is now available. You're currently on \(FeatureFlagManager.currentAppVersion)."
                    ))
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Theme.Spacing.xl)
                }

                // Changelog
                if !changelog.isEmpty {
                    changelogSection
                }

                Spacer()

                // Buttons
                VStack(spacing: Theme.Spacing.md) {
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
                    }

                    Button {
                        onDismiss()
                    } label: {
                        Text("Later")
                            .font(Theme.Typography.headline)
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.Spacing.lg)
                    }
                }
                .padding(.horizontal, Theme.Spacing.xxl)
                .padding(.bottom, Theme.Spacing.xl)
            }
        }
    }

    // MARK: - Changelog Section

    private var changelogSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("What's New")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.Colors.textPrimary)

            Text(changelog)
                .font(Theme.Typography.subheadline)
                .foregroundStyle(Theme.Colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Spacing.lg)
        .background(Theme.Colors.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.medium))
        .padding(.horizontal, Theme.Spacing.xl)
    }
}
