import SwiftUI

struct DockMiniPlayer: View {
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(PremiumManager.self) private var premiumManager
    @State private var showSkipLimitPaywall = false

    var body: some View {
        if let song = playerVM.currentSong {
            VStack(spacing: 0) {
                // Thin progress indicator
                GeometryReader { geo in
                    let progress = playerVM.duration > 0
                        ? min(playerVM.currentTime / playerVM.duration, 1.0) : 0
                    Rectangle()
                        .fill(Theme.Colors.brandGradient)
                        .frame(width: geo.size.width * progress)
                }
                .frame(height: 2)
                .background(Theme.Colors.surfaceCard)

                HStack(spacing: Theme.Spacing.md) {
                    ZStack(alignment: .bottomTrailing) {
                        AsyncThumbnail(url: song.thumbnailURL, size: 40, cornerRadius: Theme.CornerRadius.small)
                        if playerVM.isPlaying {
                            MusicWaveAnimation(color: .white, barCount: 3)
                                .frame(height: 10)
                                .padding(2)
                                .background(Color.black.opacity(0.65))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                .offset(x: 1, y: 1)
                                .transition(.opacity.combined(with: .scale))
                        }
                    }

                    VStack(alignment: .leading, spacing: Theme.Spacing.xxxs) {
                    Text(song.title)
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .lineLimit(1)
                    Text(song.artistName)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                playbackControl

                Button {
                    playerVM.next()
                    if playerVM.showSkipLimitPaywall {
                        showSkipLimitPaywall = true
                        playerVM.showSkipLimitPaywall = false
                    }
                } label: {
                    PulseIcon(
                        .next,
                        size: Theme.SizeTokens.iconSmall,
                        color: Theme.Colors.textSecondary
                    )
                }
                .buttonStyle(.bouncy)
                // Ensure minimum 44×44pt tap target (icon size unchanged)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                .accessibilityLabel("Next track")
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.xs)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                playerVM.isFullPlayerPresented = true
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Now playing: \(song.title) by \(song.artistName)")
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Double tap to open full player")
            .accessibilityIdentifier("dock_mini_player")
            .sheet(isPresented: $showSkipLimitPaywall) {
                PaywallView()
                    .environment(premiumManager)
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: playerVM.isPlaying)
            .sensoryFeedback(.selection, trigger: playerVM.currentSong?.id)
        }
    }

    @ViewBuilder
    private var playbackControl: some View {
        if playerVM.streamError != nil {
            Button {
                playerVM.retryCurrentSong()
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.Colors.error)
                        .font(.body)
                        .symbolEffect(.pulse, options: .repeating)
                    Text("Retry")
                        .font(Theme.Typography.badge)
                        .foregroundStyle(Theme.Colors.error)
                }
            }
            .frame(width: 44, height: 44)
        } else if playerVM.isBuffering {
            ProgressView()
                .tint(Theme.Colors.textPrimary)
                .frame(width: 30, height: 30)
        } else {
            Button {
                playerVM.playPause()
            } label: {
                PulseIcon(
                    playerVM.isPlaying ? .pause : .play,
                    size: Theme.SizeTokens.iconMedium,
                    color: Theme.Colors.textPrimary
                )
            }
            .buttonStyle(.bouncy)
            .frame(width: 44, height: 44)
            .accessibilityLabel(playerVM.isPlaying ? String(localized: "Pause") : String(localized: "Play"))
        }
    }
}
