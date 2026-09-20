import SwiftUI

/// About section: app info, privacy policy, terms of use.
struct AboutSettingsSection: View {
    let appVersion: String

    var body: some View {
        SettingsGroup(header: "About") {
            NavigationLink {
                AboutView()
            } label: {
                HStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "music.note.house.fill")
                        .font(.title2)
                        .foregroundStyle(Theme.Colors.brandGradientStart)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxxs) {
                        Text("LovelyMusic")
                            .font(Theme.Typography.headline)
                            .foregroundStyle(Theme.Colors.textPrimary)
                        Text("Version \(appVersion)")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textTertiary)
                        #if DEBUG || STAGING
                        Text(FeatureFlagManager.buildConfiguration)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.orange)
                        #endif
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            SettingsDivider()

            Button {
                if let url = URL(string: "https://www.iletai.qzz.io/policy#privacy-policy") {
                    UIApplication.shared.open(url)
                }
            } label: {
                SettingsRow(icon: "shield.checkerboard", title: "Privacy Policy") {
                    Image(systemName: "arrow.up.right")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
            }
            .buttonStyle(.plain)

            SettingsDivider()

            Button {
                if let url = URL(string: "https://www.iletai.qzz.io/policy#terms-of-use") {
                    UIApplication.shared.open(url)
                }
            } label: {
                SettingsRow(icon: "doc.text", title: "Terms of Use") {
                    Image(systemName: "arrow.up.right")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
            }
            .buttonStyle(.plain)
        }
    }
}
