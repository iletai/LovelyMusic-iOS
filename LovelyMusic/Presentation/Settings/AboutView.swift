import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(PlayerViewModel.self) private var playerVM

    private let appVersion: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }()

    private let buildNumber: String = {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }()

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xxl) {
                // App icon + name
                VStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "music.note.house.fill")
                        .font(Theme.Typography.display)
                        .foregroundStyle(Theme.Colors.brandGradient)
                        .shadow(
                            color: Theme.Colors.brandGradientStart.opacity(0.3), radius: 16, y: 8)

                    Text("LovelyMusic")
                        .font(Theme.Typography.largeTitle)
                        .fontWeight(.bold)
                        .foregroundStyle(Theme.Colors.textPrimary)

                    Text("Version \(appVersion) (\(buildNumber))")
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
                .padding(.top, Theme.Spacing.xxxl)

                // Description
                Text("A beautiful, privacy-focused music streaming experience.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Spacing.xl)

                // Links
                VStack(spacing: 0) {
                    linkRow(
                        icon: "shield.checkerboard",
                        iconColor: .blue,
                        title: "Privacy Policy",
                        url: "https://www.iletai.qzz.io/policy#privacy-policy"
                    )

                    Rectangle().fill(Theme.Colors.divider).frame(height: 0.5)
                        .padding(.leading, 58)

                    linkRow(
                        icon: "doc.text.fill",
                        iconColor: .purple,
                        title: "Terms of Use",
                        url: "https://www.iletai.qzz.io/policy#terms-of-use"
                    )

                    Rectangle().fill(Theme.Colors.divider).frame(height: 0.5)
                        .padding(.leading, 58)

                    linkRow(
                        icon: "envelope.fill",
                        iconColor: Theme.Colors.brandGradientEnd,
                        title: "Contact Developer",
                        url: "mailto:lequangtrongtai@gmail.com"
                    )
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

                // YouTube Content Notice
                VStack(spacing: 0) {
                    youTubeNoticeHeader

                    Rectangle().fill(Theme.Colors.divider).frame(height: 0.5)
                        .padding(.leading, 58)

                    linkRow(
                        icon: "play.rectangle.fill",
                        iconColor: .red,
                        title: "YouTube Terms of Service",
                        url: "https://www.youtube.com/t/terms"
                    )

                    Rectangle().fill(Theme.Colors.divider).frame(height: 0.5)
                        .padding(.leading, 58)

                    linkRow(
                        icon: "lock.shield.fill",
                        iconColor: .green,
                        title: "Google Privacy Policy",
                        url: "http://www.google.com/policies/privacy"
                    )
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

                // Music Credits (CC BY 3.0 attribution — required by license)
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("Music Credits")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                        .padding(.horizontal, Theme.Spacing.lg)

                    VStack(alignment: .leading, spacing: 0) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            Text("Kevin MacLeod — incompetech.com")
                                .font(Theme.Typography.headline)
                                .foregroundStyle(Theme.Colors.textPrimary)
                            Text(
                                "All bundled music is composed by Kevin MacLeod and used under the Creative Commons Attribution 3.0 Unported license (CC BY 3.0)."
                            )
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(Theme.Spacing.lg)

                        Rectangle().fill(Theme.Colors.divider).frame(height: 0.5)
                            .padding(.leading, 58)

                        linkRow(
                            icon: "music.note.list",
                            iconColor: Theme.Colors.brandGradientStart,
                            title: "Source — archive.org/details/Incompetech",
                            url: "https://archive.org/details/Incompetech"
                        )

                        Rectangle().fill(Theme.Colors.divider).frame(height: 0.5)
                            .padding(.leading, 58)

                        linkRow(
                            icon: "doc.plaintext.fill",
                            iconColor: .orange,
                            title: "License — CC BY 3.0",
                            url: "https://creativecommons.org/licenses/by/3.0/"
                        )

                        Rectangle().fill(Theme.Colors.divider).frame(height: 0.5)
                            .padding(.leading, 58)

                        linkRow(
                            icon: "person.crop.circle.fill",
                            iconColor: .indigo,
                            title: "Composer — incompetech.com",
                            url: "https://incompetech.com"
                        )
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
                }
                .padding(.top, Theme.Spacing.md)

                // Credits
                VStack(spacing: Theme.Spacing.sm) {
                    Text("Made with ❤️ by iletai")
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.Colors.textSecondary)

                    Text("© 2025 LovelyMusic. All rights reserved.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
                .padding(.top, Theme.Spacing.lg)
            }
            .padding(.bottom, Theme.Spacing.xxxl)
        }
        .background(Theme.Colors.backgroundPrimary)
        .dockSafeBottom()
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                CustomBackButton(style: .plain)
            }
        }
        .onAppear {
            playerVM.isDockHidden = true
        }
        .onDisappear {
            playerVM.isDockHidden = false
        }
    }

    private func linkRow(
        icon: String,
        iconColor: Color = Theme.Colors.brandGradientStart,
        title: LocalizedStringKey,
        url: String
    ) -> some View {
        Button {
            if let link = URL(string: url) {
                UIApplication.shared.open(link)
            }
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.CornerRadius.small, style: .continuous)
                        .fill(iconColor.opacity(0.12))
                        .frame(width: 32, height: 32)
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(iconColor)
                }

                Text(title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textPrimary)

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var youTubeNoticeHeader: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.CornerRadius.small, style: .continuous)
                        .fill(Theme.Colors.brandGradientStart.opacity(0.12))
                        .frame(width: 32, height: 32)
                    Image(systemName: "music.note.tv.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.Colors.brandGradientStart)
                }

                Text("YouTube Content")
                    .font(Theme.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.Colors.textPrimary)

                Spacer()
            }

            Text(
                "This app uses YouTube API Services. All video and music content is provided by YouTube. By using this app, you agree to be bound by the Google Privacy Policy."
            )
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.textTertiary)
            .padding(.leading, 44)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
    }
}
