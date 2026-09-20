import SwiftUI

/// Sub-page merging Privacy and Storage settings.
/// Accessed from the Settings hub via NavigationLink.
struct PrivacyStorageSettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(PlayerViewModel.self) private var playerVM

    var body: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Spacing.xl) {
                // MARK: - History
                SettingsGroup(
                    header: "History",
                    footer: "Paused history prevents played tracks and search terms from influencing your recommendations."
                ) {
                    SettingsRow(
                        icon: "clock.arrow.circlepath",
                        iconColor: .orange,
                        title: "Pause Listen History"
                    ) {
                        CustomToggle(isOn: $viewModel.pauseListenHistory)
                    }

                    SettingsDivider()

                    SettingsRow(
                        icon: "magnifyingglass",
                        iconColor: .blue,
                        title: "Pause Search History"
                    ) {
                        CustomToggle(isOn: $viewModel.pauseSearchHistory)
                    }

                    SettingsDivider()

                    Button { viewModel.showClearListenHistoryAlert = true } label: {
                        SettingsRow(
                            icon: viewModel.showListenHistoryCleared ? "checkmark.circle.fill" : "clock.badge.xmark",
                            iconColor: viewModel.showListenHistoryCleared ? Theme.Colors.success : Theme.Colors.error,
                            title: viewModel.showListenHistoryCleared ? "Cleared!" : "Clear Listen History",
                            titleColor: viewModel.showListenHistoryCleared ? Theme.Colors.success : Theme.Colors.error
                        ) {
                            EmptyView()
                        }
                    }
                    .buttonStyle(.plain)
                    .animation(Theme.AnimationPresets.smooth, value: viewModel.showListenHistoryCleared)

                    SettingsDivider()

                    Button { viewModel.showClearSearchHistoryAlert = true } label: {
                        SettingsRow(
                            icon: viewModel.showSearchHistoryCleared ? "checkmark.circle.fill" : "trash",
                            iconColor: viewModel.showSearchHistoryCleared ? Theme.Colors.success : Theme.Colors.error,
                            title: viewModel.showSearchHistoryCleared ? "Cleared!" : "Clear Search History",
                            titleColor: viewModel.showSearchHistoryCleared ? Theme.Colors.success : Theme.Colors.error
                        ) {
                            EmptyView()
                        }
                    }
                    .buttonStyle(.plain)
                    .animation(Theme.AnimationPresets.smooth, value: viewModel.showSearchHistoryCleared)
                }
                .staggeredAppear(index: 0)

                // MARK: - Content Filtering
                SettingsGroup(
                    header: "Content Filtering",
                    footer: "Hides tracks containing explicit lyrics or mature themes from search and browse."
                ) {
                    SettingsRow(
                        icon: "exclamationmark.triangle.fill",
                        iconColor: .yellow,
                        title: "Hide Explicit"
                    ) {
                        CustomToggle(isOn: $viewModel.hideExplicitContent)
                    }
                }
                .staggeredAppear(index: 1)

                // MARK: - Security
                SettingsGroup(
                    header: "Security",
                    footer: "Prevents screen capture and recording while using the app to protect your privacy."
                ) {
                    SettingsRow(
                        icon: "eye.slash.fill",
                        iconColor: Theme.Colors.brandGradientStart,
                        title: "Disable Screenshots"
                    ) {
                        CustomToggle(isOn: $viewModel.disableScreenshots)
                    }
                }
                .staggeredAppear(index: 2)

                // MARK: - Storage
                SettingsGroup(
                    header: "Storage",
                    footer: "Audio caching speeds up song loading and saves cellular data on repeated plays."
                ) {
                    SettingsRow(
                        icon: "internaldrive.fill",
                        iconColor: Theme.Colors.success,
                        title: "Cache"
                    ) {
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
                        viewModel.showClearCacheAlert = true
                    } label: {
                        SettingsRow(
                            icon: viewModel.showCacheCleared ? "checkmark.circle.fill" : "trash.fill",
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
                .staggeredAppear(index: 3)
            }
            .padding(.vertical, Theme.Spacing.lg)
        }
        .background(Theme.Colors.backgroundPrimary)
        .dockSafeBottom()
        .navigationTitle("Privacy & Storage")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                CustomBackButton(style: .plain)
            }
        }
        .onAppear {
            playerVM.isDockHidden = true
            viewModel.updateCacheSize()
        }
        .onDisappear {
            playerVM.isDockHidden = false
        }
        .alert("Clear Listen History?", isPresented: $viewModel.showClearListenHistoryAlert) {
            Button("Clear", role: .destructive) { viewModel.clearListenHistory() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will remove all your recently played songs. This action cannot be undone.")
        }
        .alert("Clear Search History?", isPresented: $viewModel.showClearSearchHistoryAlert) {
            Button("Clear", role: .destructive) { viewModel.clearSearchHistory() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will remove all your search history. This action cannot be undone.")
        }
        .alert("Clear Cache?", isPresented: $viewModel.showClearCacheAlert) {
            Button("Clear", role: .destructive) { viewModel.clearCache() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will remove cached images and downloaded audio. Your playlists and history are not affected.")
        }
    }
}
