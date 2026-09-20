import SwiftUI

/// Storage settings: cache size display and clear cache action.
struct StorageSettingsSection: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        SettingsGroup(header: "Storage") {
            SettingsRow(icon: "internaldrive", title: "Cache") {
                HStack(spacing: Theme.Spacing.xs) {
                    if viewModel.showCacheCleared {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.Colors.success)
                            .transition(.scale.combined(with: .opacity))
                    }
                    Text(viewModel.cacheSize)
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .contentTransition(.numericText())
                }
                .animation(Theme.AnimationPresets.smooth, value: viewModel.showCacheCleared)
            }

            SettingsDivider()

            Button {
                viewModel.clearCache()
            } label: {
                SettingsRow(
                    icon: viewModel.showCacheCleared ? "checkmark.circle.fill" : "trash",
                    iconColor: viewModel.showCacheCleared ? Theme.Colors.success : Theme.Colors.error,
                    title: viewModel.showCacheCleared ? "Cache Cleared!" : "Clear Cache",
                    titleColor: viewModel.showCacheCleared ? Theme.Colors.success : Theme.Colors.error
                ) {
                    EmptyView()
                }
            }
            .buttonStyle(.plain)
            .animation(Theme.AnimationPresets.smooth, value: viewModel.showCacheCleared)
        }
    }
}
