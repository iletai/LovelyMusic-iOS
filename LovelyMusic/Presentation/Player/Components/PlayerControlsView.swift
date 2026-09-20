import SwiftUI

/// Transport controls: shuffle, prev, play/pause, next, repeat.
struct PlayerControlsView: View {
    let isPlaying: Bool
    let isBuffering: Bool
    let bufferingTooLong: Bool
    let shuffleEnabled: Bool
    let repeatMode: AudioEngine.RepeatMode
    let dominantColor: Color
    let isFreeUser: Bool
    let remainingSkips: Int
    let currentSongId: String?

    let onShuffle: () -> Void
    let onPrevious: () -> Void
    let onPlayPause: () -> Void
    let onNext: () -> Void
    let onCycleRepeat: () -> Void
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // Shuffle
            Button {
                onShuffle()
            } label: {
                VStack(spacing: Theme.Spacing.xxxs) {
                    Image(systemName: "shuffle")
                        .font(.system(size: Theme.SizeTokens.iconSmall, weight: .medium))
                        .foregroundStyle(
                            shuffleEnabled
                                ? dominantColor
                                : Theme.Colors.textTertiary
                        )
                    Circle()
                        .fill(dominantColor)
                        .frame(width: 3, height: 3)
                        .opacity(shuffleEnabled ? 1 : 0)
                }
            }
            .frame(width: 44, height: 44)
            .accessibilityLabel("Shuffle")
            .accessibilityValue(shuffleEnabled ? "On" : "Off")

            Spacer(minLength: Theme.Spacing.xxs)

            // Previous
            Button {
                onPrevious()
            } label: {
                PulseIcon(
                    .previous,
                    size: 26,
                    color: Theme.Colors.textPrimary
                )
            }
            .frame(width: 44, height: 44)
            .accessibilityLabel("Previous track")
            .accessibilityHint("Double tap to go to previous track")
            .sensoryFeedback(
                .impact(weight: .medium),
                trigger: currentSongId
            )

            Spacer(minLength: Theme.Spacing.xxs)

            // Play/Pause or Buffering. Fixed-size ZStack so the two branches
            // share the same frame; otherwise brief `isBuffering` flips during
            // seek would reflow the whole player layout.
            ZStack {
                if isBuffering {
                    VStack(spacing: Theme.Spacing.sm) {
                        ProgressView()
                            .tint(Theme.Colors.textPrimary)
                            .scaleEffect(1.5)
                            .frame(width: 64, height: 64)
                            .accessibilityLabel("Buffering")
                            .accessibilityHint("Loading audio stream")
                        if bufferingTooLong {
                            Button {
                                onRetry()
                            } label: {
                                Text("Retry")
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(.white.opacity(0.8))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                                    .background(.white.opacity(0.15), in: Capsule())
                            }
                        }
                    }
                    .transition(.opacity)
                } else {
                    Button {
                        onPlayPause()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(.ultraThinMaterial)
                            Circle()
                                .stroke(Theme.Colors.brandGradient, lineWidth: 1.5)
                            PulseIcon(
                                isPlaying ? .pause : .play,
                                size: Theme.SizeTokens.iconLarge,
                                color: Theme.Colors.textPrimary
                            )
                        }
                        .frame(width: 72, height: 72)
                        .shadow(
                            color: Theme.Shadows.glow.color,
                            radius: Theme.Shadows.glow.radius,
                            x: Theme.Shadows.glow.x,
                            y: Theme.Shadows.glow.y
                        )
                    }
                    .buttonStyle(.bouncy)
                    .accessibilityLabel(isPlaying ? "Pause" : "Play")
                    .accessibilityHint("Double tap to toggle playback")
                    .sensoryFeedback(.impact(weight: .light), trigger: isPlaying)
                    .transition(.opacity)
                }
            }
            // Fits the display-font play button (~72pt) and the buffering
            // spinner+retry pill stack without clipping.
            .frame(width: 84, height: 100)
            .animation(.easeInOut(duration: 0.15), value: isBuffering)

            Spacer(minLength: Theme.Spacing.xxs)

            // Next
            Button {
                onNext()
            } label: {
                VStack(spacing: 2) {
                    PulseIcon(
                        .next,
                        size: 26,
                        color: Theme.Colors.textPrimary
                    )
                    if isFreeUser && remainingSkips <= 4 {
                        Text("\(remainingSkips) left")
                            .font(Theme.Typography.badge)
                            .foregroundStyle(
                                remainingSkips == 0
                                    ? Theme.Colors.error
                                    : Theme.Colors.textTertiary)
                    }
                }
            }
            .frame(width: 44)
            .frame(minHeight: 56)
            .accessibilityLabel("Next track")
            .accessibilityHint("Double tap to go to next track")
            .accessibilityValue(
                isFreeUser ? "\(remainingSkips) skips remaining" : ""
            )

            Spacer(minLength: Theme.Spacing.xxs)

            // Repeat
            Button {
                onCycleRepeat()
            } label: {
                VStack(spacing: Theme.Spacing.xxxs) {
                    Image(systemName: repeatIcon)
                        .font(.system(size: Theme.SizeTokens.iconSmall, weight: .medium))
                        .foregroundStyle(repeatColor)
                    Circle()
                        .fill(dominantColor)
                        .frame(width: 3, height: 3)
                        .opacity(repeatMode == .off ? 0 : 1)
                }
            }
            .frame(width: 44, height: 44)
            .accessibilityLabel("Repeat")
            .accessibilityValue(repeatModeDescription.capitalized)
        }
        .frame(maxWidth: 430)
        .padding(.horizontal, Theme.Spacing.sm)
    }

    // MARK: - Repeat Helpers

    private var repeatIcon: String {
        switch repeatMode {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    private var repeatColor: Color {
        switch repeatMode {
        case .off: return Theme.Colors.textTertiary
        case .all, .one: return dominantColor
        }
    }

    private var repeatModeDescription: String {
        switch repeatMode {
        case .off: return "off"
        case .all: return "all"
        case .one: return "one"
        }
    }
}
