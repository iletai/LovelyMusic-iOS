import SwiftUI

/// Sub-page combining Playback, Audio, and Lyrics settings.
/// Accessed from the Settings hub via NavigationLink.
struct PlaybackAudioSettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(PlayerViewModel.self) private var playerVM
    let isPremium: Bool
    let canAccessEqualizer: Bool
    let equalizerPresetName: String
    let sleepTimerIsActive: Bool
    let sleepTimerFormatted: String
    let audioQualityPicker: AnyView
    let canAccessLyrics: Bool
    let onCancelSleepTimer: () -> Void
    let onShowEqualizerPaywall: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Spacing.xl) {
                // MARK: - Audio
                SettingsGroup(
                    header: "Audio",
                    footer: "Audio quality controls streaming bitrate and data usage. Normalization maintains consistent volume between songs."
                ) {
                    SettingsRow(
                        icon: "music.note",
                        iconColor: Theme.Colors.brandGradientStart,
                        title: "Audio Quality"
                    ) {
                        audioQualityPicker
                    }

                    SettingsDivider()

                    SettingsRow(
                        icon: "play.rectangle.fill",
                        iconColor: .pink,
                        title: "Video Quality"
                    ) {
                        CustomMenuPicker(
                            selection: $viewModel.videoQuality,
                            options: VideoQuality.allCases,
                            label: { $0.displayName },
                            icon: nil
                        )
                    }

                    SettingsDivider()

                    if canAccessEqualizer {
                        NavigationLink {
                            EqualizerView()
                        } label: {
                            SettingsRow(
                                icon: "slider.vertical.3",
                                iconColor: .purple,
                                title: "Equalizer"
                            ) {
                                HStack(spacing: Theme.Spacing.xs) {
                                    Text(equalizerPresetName)
                                        .font(Theme.Typography.caption)
                                        .foregroundStyle(Theme.Colors.textSecondary)
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Theme.Colors.textTertiary)
                                }
                            }
                        }
                    } else {
                        Button {
                            onShowEqualizerPaywall()
                        } label: {
                            SettingsRow(
                                icon: "slider.vertical.3",
                                iconColor: .purple,
                                title: "Equalizer"
                            ) {
                                PremiumBadgeView()
                            }
                        }
                    }

                    SettingsDivider()

                    SettingsRow(
                        icon: "waveform",
                        iconColor: .indigo,
                        title: "Normalization"
                    ) {
                        CustomToggle(isOn: $viewModel.audioNormalization)
                    }
                }
                .staggeredAppear(index: 0)

                // MARK: - Playback
                SettingsGroup(
                    header: "Playback",
                    footer: "Crossfade smoothly blends audio between songs. Autoplay continuously queues similar tracks when the current queue finishes."
                ) {
                    SettingsRow(
                        icon: "forward.fill",
                        iconColor: .cyan,
                        title: "Skip Silence"
                    ) {
                        CustomToggle(isOn: $viewModel.skipSilence)
                    }

                    SettingsDivider()

                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        SettingsRow(
                            icon: "wave.3.right",
                            iconColor: Theme.Colors.brandGradientStart,
                            title: "Crossfade"
                        ) {
                            Text(
                                viewModel.crossfadeDuration == 0
                                    ? "Off" : "\(Int(viewModel.crossfadeDuration))s"
                            )
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.brandGradientStart)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                        }

                        Slider(
                            value: $viewModel.crossfadeDuration,
                            in: 0...12,
                            step: 1
                        )
                        .tint(Theme.Colors.brandGradientStart)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.bottom, Theme.Spacing.xs)
                    }

                    SettingsDivider()

                    SettingsRow(
                        icon: "infinity",
                        iconColor: .purple,
                        title: "Autoplay Related Songs"
                    ) {
                        CustomToggle(isOn: $viewModel.autoplayRelatedSongs)
                    }

                    SettingsDivider()

                    SettingsRow(
                        icon: "moon.fill",
                        iconColor: .indigo,
                        title: "Sleep Timer"
                    ) {
                        CustomMenuPicker(
                            selection: $viewModel.sleepTimer,
                            options: SleepTimerOption.allCases,
                            label: { $0.displayName },
                            icon: nil
                        )
                    }

                    if sleepTimerIsActive {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "moon.fill")
                                .foregroundStyle(Theme.Colors.brandGradientStart)
                                .font(.caption)
                            Text("Timer: \(sleepTimerFormatted)")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.brandGradientStart)
                                .monospacedDigit()
                            Spacer()
                            Button("Cancel") {
                                onCancelSleepTimer()
                            }
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.error)
                        }
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.sm)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .staggeredAppear(index: 1)

                // MARK: - Advanced
                SettingsGroup(
                    header: "Advanced",
                    footer: "Persistent queue restores your playlist state across app launches. Auto-skip advances past unplayable network tracks."
                ) {
                    SettingsRow(
                        icon: "list.bullet.rectangle.portrait.fill",
                        iconColor: .blue,
                        title: "Persistent Queue"
                    ) {
                        CustomToggle(isOn: $viewModel.persistentQueue)
                    }

                    SettingsDivider()

                    SettingsRow(
                        icon: "forward.end.alt.fill",
                        iconColor: .orange,
                        title: "Auto-Skip on Error"
                    ) {
                        CustomToggle(isOn: $viewModel.autoSkipOnError)
                    }
                }
                .staggeredAppear(index: 2)

                // MARK: - Lyrics
                SettingsGroup(
                    header: "Lyrics",
                    footer: "Synced lyrics scroll in real-time with playback. Translation displays side-by-side lyrics when available."
                ) {
                    SettingsRow(
                        icon: "quote.bubble.fill",
                        iconColor: Theme.Colors.brandGradientEnd,
                        title: "Auto-Show Lyrics"
                    ) {
                        HStack(spacing: Theme.Spacing.xs) {
                            if !canAccessLyrics {
                                PremiumBadgeView()
                            }
                            CustomToggle(
                                isOn: Binding(
                                    get: { viewModel.showLyricsAutomatically },
                                    set: { newValue in
                                        if canAccessLyrics {
                                            viewModel.showLyricsAutomatically = newValue
                                        }
                                    }
                                )
                            )
                            .disabled(!canAccessLyrics)
                        }
                    }

                    SettingsDivider()

                    SettingsRow(
                        icon: "textformat.size",
                        iconColor: .purple,
                        title: "Lyrics Font Size"
                    ) {
                        HStack(spacing: Theme.Spacing.xs) {
                            if !canAccessLyrics {
                                PremiumBadgeView()
                            }
                            CustomMenuPicker(
                                selection: Binding(
                                    get: { viewModel.lyricsFontSize },
                                    set: { newValue in
                                        if canAccessLyrics {
                                            viewModel.lyricsFontSize = newValue
                                        }
                                    }
                                ),
                                options: LyricsFontSize.allCases,
                                label: { $0.displayName },
                                icon: nil
                            )
                            .disabled(!canAccessLyrics)
                        }
                    }

                    SettingsDivider()

                    SettingsRow(
                        icon: "character.bubble.fill",
                        iconColor: .indigo,
                        title: "Show Translation"
                    ) {
                        HStack(spacing: Theme.Spacing.xs) {
                            if !canAccessLyrics {
                                PremiumBadgeView()
                            }
                            CustomToggle(
                                isOn: Binding(
                                    get: { viewModel.showLyricsTranslation },
                                    set: { newValue in
                                        if canAccessLyrics {
                                            viewModel.showLyricsTranslation = newValue
                                        }
                                    }
                                )
                            )
                            .disabled(!canAccessLyrics)
                        }
                    }
                }
                .staggeredAppear(index: 3)
            }
            .padding(.vertical, Theme.Spacing.lg)
        }
        .background(Theme.Colors.backgroundPrimary)
        .dockSafeBottom()
        .navigationTitle("Playback & Audio")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                CustomBackButton(style: .plain)
            }
        }
        .animation(Theme.AnimationPresets.gentle, value: viewModel.audioQuality)
        .animation(Theme.AnimationPresets.gentle, value: viewModel.videoQuality)
        .animation(Theme.AnimationPresets.gentle, value: viewModel.sleepTimer)
        .animation(Theme.AnimationPresets.gentle, value: viewModel.skipSilence)
        .animation(Theme.AnimationPresets.gentle, value: viewModel.audioNormalization)
        .animation(Theme.AnimationPresets.gentle, value: viewModel.persistentQueue)
        .animation(Theme.AnimationPresets.gentle, value: viewModel.autoSkipOnError)
        .animation(Theme.AnimationPresets.gentle, value: viewModel.autoplayRelatedSongs)
        .animation(Theme.AnimationPresets.gentle, value: viewModel.crossfadeDuration)
        .onAppear {
            playerVM.isDockHidden = true
        }
        .onDisappear {
            playerVM.isDockHidden = false
        }
    }
}
