import SwiftUI

/// Circular tile for a user channel on the Home feed.
/// Visual treatment mirrors the existing artist tile — circular thumbnail
/// with channel name below.
struct UserChannelTile: View {
    let channel: UserChannel

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            AsyncThumbnail(
                url: channel.thumbnailURL,
                size: 110,
                cornerRadius: Theme.CornerRadius.full
            )
            Text(channel.name)
                .font(Theme.Typography.caption)
                .fontWeight(.medium)
                .foregroundStyle(Theme.Colors.textPrimary)
                .lineLimit(1)
        }
        .frame(width: 110)
    }
}
