import SwiftUI

/// Round 2: Play All as full-width brand pill with `Shadows.glow`;
/// Shuffle as 44pt outline icon-only on `surfaceCard`. Used by Album/Playlist detail.
struct PlayShuffleButtons: View {
    var onPlay: () -> Void
    var onShuffle: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Button(action: onPlay) {
                Label("Play All", systemImage: "play.fill")
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Colors.onBrand)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Spacing.md)
                    .background(Theme.Colors.brandGradient)
                    .clipShape(Capsule())
                    .shadow(
                        color: Theme.Shadows.glow.color,
                        radius: Theme.Shadows.glow.radius,
                        x: Theme.Shadows.glow.x,
                        y: Theme.Shadows.glow.y
                    )
            }
            .buttonStyle(.bouncy)

            Button(action: onShuffle) {
                Image(systemName: "shuffle")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Theme.Colors.surfaceCard, in: Circle())
                    .overlay(
                        Circle()
                            .stroke(Theme.Colors.divider, lineWidth: Theme.SizeTokens.dividerThick)
                    )
            }
            .buttonStyle(.bouncy)
            .accessibilityLabel("Shuffle all")
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
    }
}
