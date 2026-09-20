import SwiftUI

/// Playback settings: audio quality, sleep timer, skip silence, normalization,
/// persistent queue, auto-skip on error, autoplay, equalizer.
struct PlaybackSettingsSection: View {
    @Bindable var viewModel: SettingsViewModel
    let isPremium: Bool
    let canAccessEqualizer: Bool
    let equalizerPresetName: String
    let sleepTimerIsActive: Bool
    let sleepTimerFormatted: String
    let audioQualityPicker: AnyView
    let onCancelSleepTimer: () -> Void
    let onShowEqualizerPaywall: () -> Void

    var body: some View {
        SettingsGroup(header: "Playback") {
            SettingsRow(icon: "music.note", title: "Audio Quality") {
                audioQualityPicker
            }

            SettingsDivider()

            SettingsRow(icon: "moon.fill", title: "Sleep Timer") {
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

            SettingsDivider()

            SettingsRow(icon: "forward.fill", title: "Skip Silence") {
                CustomToggle(isOn: $viewModel.skipSilence)
            }

            SettingsDivider()

            SettingsRow(icon: "waveform", title: "Normalization") {
                CustomToggle(isOn: $viewModel.audioNormalization)
            }

            SettingsDivider()

            SettingsRow(icon: "list.bullet", title: "Persistent Queue") {
                CustomToggle(isOn: $viewModel.persistentQueue)
            }

            SettingsDivider()

            SettingsRow(icon: "forward.end.alt.fill", title: "Auto-Skip on Error") {
                CustomToggle(isOn: $viewModel.autoSkipOnError)
            }

            SettingsDivider()

            SettingsRow(icon: "infinity", title: "Autoplay Related Songs") {
                CustomToggle(isOn: $viewModel.autoplayRelatedSongs)
            }

            SettingsDivider()

            if canAccessEqualizer {
                NavigationLink {
                    EqualizerView()
                } label: {
                    SettingsRow(icon: "slider.vertical.3", title: "Equalizer") {
                        Text(equalizerPresetName)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                }
            } else {
                Button {
                    onShowEqualizerPaywall()
                } label: {
                    SettingsRow(icon: "slider.vertical.3", title: "Equalizer") {
                        PremiumBadgeView()
                    }
                }
            }
        }
    }
}
