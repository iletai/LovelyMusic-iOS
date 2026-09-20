import SwiftUI

// MARK: - Settings Section Group

struct SettingsGroup<Content: View>: View {
    let header: LocalizedStringKey
    var footer: LocalizedStringKey? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(header)
                .font(Theme.Typography.caption)
                .textCase(.uppercase)
                .tracking(0.5)
                .foregroundStyle(Theme.Colors.textTertiary)
                .padding(.horizontal, Theme.Spacing.lg)

            VStack(spacing: 0) {
                content()
            }
            .background(Theme.Colors.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.large))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                    .stroke(Theme.Colors.divider, lineWidth: Theme.SizeTokens.dividerThick)
            )
            .shadow(
                color: Theme.Shadows.small.color,
                radius: Theme.Shadows.small.radius,
                x: Theme.Shadows.small.x,
                y: Theme.Shadows.small.y
            )
            .padding(.horizontal, Theme.Spacing.lg)

            if let footer {
                Text(footer)
                    .font(Theme.Typography.captionSecondary)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.top, Theme.Spacing.xxxs)
            }
        }
    }
}

// MARK: - Settings Row

struct SettingsRow<Trailing: View>: View {
    let icon: String
    var iconColor: Color = Theme.Colors.brandGradientStart
    let title: LocalizedStringKey
    var titleColor: Color = Theme.Colors.textPrimary
    var subtitle: LocalizedStringKey? = nil
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.CornerRadius.small, style: .continuous)
                    .fill(iconColor.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(iconColor)
            }

            if let subtitle {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxxs) {
                    Text(title)
                        .font(Theme.Typography.body)
                        .foregroundStyle(titleColor)
                    Text(subtitle)
                        .font(Theme.Typography.captionSecondary)
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(titleColor)
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
    }
}

// MARK: - Settings Divider

struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.Colors.divider)
            .frame(height: 0.5)
            .padding(.leading, 58)
    }
}

// MARK: - Settings Navigation Row (Apple Settings DNA)

/// A navigation row styled like Apple's Settings app with a colored icon square.
struct SettingsNavigationRow: View {
    let icon: String
    let iconBackground: Color
    let title: LocalizedStringKey
    let subtitle: String

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            // Colored icon in rounded square
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(iconBackground)
                )

            VStack(alignment: .leading, spacing: Theme.Spacing.xxxs) {
                Text(title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text(subtitle)
                    .font(Theme.Typography.captionSecondary)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Colors.textTertiary.opacity(0.6))
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.lg)
        .contentShape(Rectangle())
    }
}
