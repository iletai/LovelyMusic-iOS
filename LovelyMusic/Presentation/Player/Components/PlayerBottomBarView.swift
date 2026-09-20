import SwiftUI

/// Bottom action bar: playback speed, autoplay, video toggle, lyrics toggle, queue.
struct PlayerBottomBarView: View {
    let playbackSpeedLabel: String
    let playbackSpeed: Float
    let isAutoplayEnabled: Bool
    let isVideoMode: Bool
    let isLyricsVisible: Bool
    let canAccessFullLyrics: Bool
    let isVideoPlaybackEnabled: Bool
    let dominantColor: Color

    let onCycleSpeed: () -> Void
    let onToggleAutoplay: () -> Void
    let onToggleVideo: () -> Void
    let onToggleLyrics: () -> Void
    let onShowQueue: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.lg) {
            // Playback speed
            Button {
                onCycleSpeed()
            } label: {
                Text(playbackSpeedLabel)
                    .font(Theme.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(
                        playbackSpeed != 1.0
                            ? Theme.Colors.brandGradientStart
                            : Theme.Colors.textTertiary
                    )
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Theme.Colors.surfaceCard.opacity(0.5))
                    )
            }
            .accessibilityLabel("Playback speed")
            .accessibilityValue(playbackSpeedLabel)
            .sensoryFeedback(.impact(weight: .light), trigger: playbackSpeed)

            // Autoplay — Q4: `infinity` was ambiguous; circular arrows reads as
            // "loop / queue continuation" unambiguously.
            Button {
                onToggleAutoplay()
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.title3)
                        .foregroundStyle(
                            isAutoplayEnabled
                                ? dominantColor
                                : Theme.Colors.textTertiary
                        )
                    Text("Autoplay")
                        .font(Theme.Typography.caption2.weight(.medium))
                        .foregroundStyle(
                            isAutoplayEnabled
                                ? dominantColor
                                : Theme.Colors.textTertiary
                        )
                }
            }
            .frame(minWidth: 56, minHeight: 52)
            .accessibilityLabel("Autoplay")
            .accessibilityValue(isAutoplayEnabled ? "On" : "Off")

            // Video toggle
            Button {
                onToggleVideo()
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: isVideoMode ? "music.note" : "play.rectangle")
                        .font(.title3)
                        .foregroundStyle(
                            isVideoMode
                                ? dominantColor
                                : Theme.Colors.textTertiary
                        )
                        .contentTransition(.symbolEffect(.replace))
                    Text(isVideoMode ? "Audio" : "Video")
                        .font(Theme.Typography.caption2.weight(.medium))
                        .foregroundStyle(
                            isVideoMode
                                ? dominantColor
                                : Theme.Colors.textTertiary
                        )
                }
            }
            .frame(minWidth: 56, minHeight: 52)
            .disabled(!isVideoPlaybackEnabled)
            .opacity(isVideoPlaybackEnabled ? 1.0 : 0.3)
            .accessibilityLabel(isVideoMode ? "Switch to audio" : "Switch to video")
            .accessibilityValue(isVideoMode ? "On" : "Off")

            // Lyrics toggle — Q4: `quote.bubble` is non-standard for music apps;
            // `text.quote` is the platform-standard lyrics glyph.
            Button {
                onToggleLyrics()
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "text.quote")
                        .font(.title3)
                        .foregroundStyle(
                            isLyricsVisible
                                ? dominantColor
                                : Theme.Colors.textTertiary
                        )
                    Text("Lyrics")
                        .font(Theme.Typography.caption2.weight(.medium))
                        .foregroundStyle(
                            isLyricsVisible
                                ? dominantColor
                                : Theme.Colors.textTertiary
                        )
                }
            }
            .frame(minWidth: 56, minHeight: 52)
            .accessibilityLabel(isLyricsVisible ? "Hide lyrics" : "Show lyrics")
            .accessibilityValue(isLyricsVisible ? "Showing" : "Hidden")
            .accessibilityIdentifier("toggle_lyrics")
            .overlay(alignment: .topTrailing) {
                if !canAccessFullLyrics {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.Colors.brandGradientStart)
                        .padding(Theme.Spacing.xxxs)
                        .accessibilityHidden(true)
                }
            }

            // Queue
            Button {
                onShowQueue()
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "list.bullet")
                        .font(.title3)
                        .foregroundStyle(Theme.Colors.textTertiary)
                    Text("Queue")
                        .font(Theme.Typography.caption2.weight(.medium))
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
            }
            .frame(minWidth: 56, minHeight: 52)
            .accessibilityLabel("Queue")
            .accessibilityHint("Double tap to view play queue")
        }
    }
}
