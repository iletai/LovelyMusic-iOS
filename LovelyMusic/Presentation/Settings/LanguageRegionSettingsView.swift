import SwiftUI

/// Sub-page merging App Language and Content Region/Language settings.
/// Accessed from the Settings hub via NavigationLink.
struct LanguageRegionSettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(LocalizationManager.self) private var localizationManager
    @Environment(PlayerViewModel.self) private var playerVM

    var body: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Spacing.xl) {
                // MARK: - App Language
                SettingsGroup(header: "App Language") {
                    ForEach(LocalizationManager.Language.allCases) { lang in
                        let isSelected = localizationManager.currentLanguage == lang

                        Button {
                            withAnimation(Theme.AnimationPresets.bouncy) {
                                localizationManager.currentLanguage = lang
                                viewModel.reloadContentLocale()
                            }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            HStack(spacing: Theme.Spacing.md) {
                                Text(lang.flag)
                                    .font(.title3)
                                    .frame(width: 28)

                                Text(lang.displayName)
                                    .font(Theme.Typography.body)
                                    .foregroundStyle(
                                        isSelected
                                        ? Theme.Colors.brandGradientStart
                                        : Theme.Colors.textPrimary
                                    )

                                Spacer()

                                ZStack {
                                    Circle()
                                        .stroke(
                                            isSelected
                                            ? Theme.Colors.brandGradientStart
                                            : Theme.Colors.textTertiary.opacity(0.4),
                                            lineWidth: 1.5
                                        )
                                        .frame(width: 20, height: 20)
                                    if isSelected {
                                        Circle()
                                            .fill(Theme.Colors.brandGradient)
                                            .frame(width: 12, height: 12)
                                            .transition(.scale.combined(with: .opacity))
                                    }
                                }
                                .animation(Theme.AnimationPresets.smooth, value: isSelected)
                            }
                            .padding(.horizontal, Theme.Spacing.lg)
                            .padding(.vertical, Theme.Spacing.sm + 2)
                            .background(
                                isSelected
                                ? AnyShapeStyle(Theme.Colors.brandGradientStart.opacity(0.08))
                                : AnyShapeStyle(.clear)
                            )
                        }
                        .buttonStyle(.plain)

                        if lang != LocalizationManager.Language.allCases.last {
                            SettingsDivider()
                        }
                    }
                }
                .staggeredAppear(index: 0)

                // MARK: - Content Region
                SettingsGroup(
                    header: "Content",
                    footer: "App Language controls the UI. Content Region & Language control music recommendations and search results."
                ) {
                    SettingsRow(
                        icon: "globe.asia.fill",
                        iconColor: .blue,
                        title: "Region"
                    ) {
                        CustomMenuPicker(
                            selection: $viewModel.region,
                            options: ["VN", "US", "JP", "KR"],
                            label: { regionDisplayName($0) },
                            icon: nil
                        )
                    }

                    SettingsDivider()

                    SettingsRow(
                        icon: "character.book.closed.fill",
                        iconColor: Theme.Colors.brandGradientStart,
                        title: "Content Language"
                    ) {
                        CustomMenuPicker(
                            selection: $viewModel.language,
                            options: ["vi", "en", "ja", "ko"],
                            label: { languageDisplayName($0) },
                            icon: nil
                        )
                    }
                }
                .staggeredAppear(index: 1)
                .animation(Theme.AnimationPresets.gentle, value: viewModel.region)
                .animation(Theme.AnimationPresets.gentle, value: viewModel.language)
            }
            .padding(.vertical, Theme.Spacing.lg)
        }
        .background(Theme.Colors.backgroundPrimary)
        .dockSafeBottom()
        .navigationTitle("Language & Region")
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

    // MARK: - Helpers

    private func regionDisplayName(_ code: String) -> String {
        switch code {
        case "VN": return String(localized: "🇻🇳 Vietnam")
        case "US": return String(localized: "🇺🇸 United States")
        case "JP": return String(localized: "🇯🇵 Japan")
        case "KR": return String(localized: "🇰🇷 Korea")
        default: return code
        }
    }

    private func languageDisplayName(_ code: String) -> String {
        switch code {
        case "vi": return String(localized: "🇻🇳 Vietnamese")
        case "en": return String(localized: "🇺🇸 English")
        case "ja": return String(localized: "🇯🇵 Japanese")
        case "ko": return String(localized: "🇰🇷 Korean")
        default: return code
        }
    }
}
