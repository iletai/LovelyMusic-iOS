import SwiftUI

/// Compact shelf tile for an audiobook item on the Home feed.
/// Displays thumbnail, title, and optional author — matching the visual
/// density of the existing album/playlist shelf cards.
struct AudiobookTile: View {
    let audiobook: Audiobook

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            AsyncThumbnail(
                url: audiobook.thumbnailURL,
                size: 150,
                cornerRadius: Theme.CornerRadius.medium
            )
            Text(audiobook.title)
                .font(Theme.Typography.caption)
                .fontWeight(.medium)
                .foregroundStyle(Theme.Colors.textPrimary)
                .lineLimit(2)
            if let author = audiobook.authorName, !author.isEmpty {
                Text(author)
                    .font(Theme.Typography.captionSecondary)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 150)
    }
}
