import SwiftUI

struct FloatingDockView: View {
    @Binding var selectedTab: AppTab
    var onReselect: ((AppTab) -> Void)?
    @Environment(PlayerViewModel.self) private var playerVM

    private var hasSong: Bool { playerVM.currentSong != nil }

    var body: some View {
        VStack(spacing: 0) {
            // Progress bar at the top edge of the dock (isolated sub-view)
            if hasSong {
                DockProgressBar()
            }

            // Mini player row
            if hasSong {
                DockMiniPlayer()
                    .transition(
                        .asymmetric(
                            insertion: .push(from: .bottom).combined(with: .opacity),
                            removal: .push(from: .top).combined(with: .opacity)
                        ))

                // Divider between mini player and tabs — Round 2 Q3: 1px hairline.
                Rectangle()
                    .fill(Theme.Colors.divider)
                    .frame(height: Theme.SizeTokens.dividerThick)
                    .padding(.horizontal, 12)
            }

            // Tab bar (always visible)
            DockTabBar(selectedTab: $selectedTab, onReselect: onReselect)
        }
        // Round 2 Q3: depth via solid surface + hairline + shadow, NOT material.
        .background(Theme.Colors.miniPlayerBackground)
        .clipShape(
            RoundedRectangle(
                cornerRadius: hasSong ? Theme.CornerRadius.extraLarge : 28,
                style: .continuous
            )
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: hasSong ? Theme.CornerRadius.extraLarge : 28,
                style: .continuous
            )
            .stroke(Theme.Colors.divider, lineWidth: Theme.SizeTokens.dividerThick)
        )
        .shadow(
            color: Theme.Shadows.medium.color,
            radius: Theme.Shadows.medium.radius,
            x: Theme.Shadows.medium.x,
            y: Theme.Shadows.medium.y
        )
        .padding(.horizontal, hasSong ? Theme.Spacing.lg : Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.sm)
        .animation(Theme.AnimationPresets.smooth, value: hasSong)
    }
}

/// Isolated sub-view: only this tiny progress bar re-renders every 0.5s,
/// instead of the entire FloatingDockView + DockMiniPlayer + DockTabBar.
private struct DockProgressBar: View {
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(PlaybackProgress.self) private var playbackProgress

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.Colors.divider)
                    .frame(height: 2.5)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [playerVM.dominantColor, playerVM.dominantColor.opacity(0.8)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, geo.size.width * playbackProgress.progress), height: 2.5)
                    .shadow(color: playerVM.dominantColor.opacity(0.6), radius: 4, y: 0)
                    .animation(.linear(duration: 0.5), value: playbackProgress.progress)
            }
        }
        .frame(height: 2.5)
        .transition(.opacity.animation(.easeIn(duration: 0.3).delay(0.1)))
    }
}
