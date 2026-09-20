import SwiftUI

struct SongRowView: View {
    let song: Song
    var trackNumber: Int?
    let isPlaying: Bool
    var showThumbnail: Bool = true
    var isFavorite: Bool = false
    var downloadState: DownloadManager.DownloadState?
    let onTap: () -> Void
    var onPlayNext: (() -> Void)?
    var onAddToQueue: (() -> Void)?
    var onAddToPlaylist: (() -> Void)?
    var onToggleFavorite: (() -> Void)?
    var onDownload: (() -> Void)?
    var onRemoveDownload: (() -> Void)?
    /// Optional URL surfaced as the primary share target via SwiftUI's native
    /// `ShareLink` in the row menu. Pass `song.youtubeURL` for YouTube-origin
    /// songs. Set both this and `shareMessage` to nil to hide the Share menu
    /// item.
    var shareURL: URL?
    /// Optional fallback share text rendered when `shareURL` is nil (e.g.,
    /// local-only songs without a YouTube origin). Mirrors the
    /// `"\u{1F3B5} {title} - {artist}"` pattern used elsewhere in the app.
    var shareMessage: String?
    var onGoToArtist: (() -> Void)?
    var onGoToAlbum: (() -> Void)?

    init(
        song: Song, trackNumber: Int? = nil, isPlaying: Bool = false, showThumbnail: Bool = true,
        isFavorite: Bool = false, downloadState: DownloadManager.DownloadState? = nil,
        onTap: @escaping () -> Void,
        onPlayNext: (() -> Void)? = nil,
        onAddToQueue: (() -> Void)? = nil,
        onAddToPlaylist: (() -> Void)? = nil, onToggleFavorite: (() -> Void)? = nil,
        onDownload: (() -> Void)? = nil, onRemoveDownload: (() -> Void)? = nil,
        shareURL: URL? = nil,
        shareMessage: String? = nil,
        onGoToArtist: (() -> Void)? = nil,
        onGoToAlbum: (() -> Void)? = nil
    ) {
        self.song = song
        self.trackNumber = trackNumber
        self.isPlaying = isPlaying
        self.showThumbnail = showThumbnail
        self.isFavorite = isFavorite
        self.downloadState = downloadState
        self.onTap = onTap
        self.onPlayNext = onPlayNext
        self.onAddToQueue = onAddToQueue
        self.onAddToPlaylist = onAddToPlaylist
        self.onToggleFavorite = onToggleFavorite
        self.onDownload = onDownload
        self.onRemoveDownload = onRemoveDownload
        self.shareURL = shareURL
        self.shareMessage = shareMessage
        self.onGoToArtist = onGoToArtist
        self.onGoToAlbum = onGoToAlbum
    }

    /// Whether the trailing ellipsis menu should be rendered. Hides when no
    /// optional handlers are wired so callers don't get an empty popover.
    private var hasMenuItems: Bool {
        onPlayNext != nil
            || onAddToQueue != nil
            || onAddToPlaylist != nil
            || onGoToArtist != nil
            || onGoToAlbum != nil
            || shareURL != nil
            || shareMessage != nil
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Theme.Spacing.md) {
                if let number = trackNumber {
                    if isPlaying {
                        MusicWaveAnimation(color: Theme.Colors.brandGradientStart)
                            .frame(width: 24, height: 16)
                    } else {
                        Text("\(number)")
                            .font(Theme.Typography.subheadline)
                            .foregroundStyle(Theme.Colors.textTertiary)
                            .frame(width: 24)
                    }
                } else if showThumbnail {
                    AsyncThumbnail(
                        url: song.thumbnailURL, size: 48, cornerRadius: Theme.CornerRadius.small
                    )
                    .overlay {
                        if isPlaying {
                            ZStack {
                                Color.black.opacity(0.4)
                                MusicWaveAnimation(color: .white)
                                    .frame(width: 20, height: 16)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.small))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: Theme.Spacing.xxxs) {
                    Text(song.title)
                        .font(Theme.Typography.subheadline.weight(.semibold))
                        .foregroundStyle(
                            isPlaying ? Theme.Colors.brandGradientStart : Theme.Colors.textPrimary
                        )
                        .lineLimit(1)
                    HStack(spacing: Theme.Spacing.xxxs) {
                        Text(song.artistName)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .lineLimit(1)
                        if song.isExplicit {
                            Text("E")
                                .font(Theme.Typography.caption2.weight(.semibold))
                                .foregroundStyle(Theme.Colors.textTertiary)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.Colors.textTertiary, lineWidth: 1))
                        }
                    }
                }

                Spacer()

                Text(song.formattedDuration)
                    .font(Theme.Typography.caption2)
                    .foregroundStyle(Theme.Colors.textTertiary)

                if let onToggleFavorite {
                    FavoriteButton(isFavorite: isFavorite, action: onToggleFavorite)
                }

                if let downloadState {
                    DownloadButton(
                        state: downloadState,
                        onDownload: { onDownload?() },
                        onRemove: { onRemoveDownload?() }
                    )
                }

                if hasMenuItems {
                    Menu {
                        if let onPlayNext {
                            Button(
                                "Play Next",
                                systemImage: "text.line.first.and.arrowtriangle.forward"
                            ) {
                                onPlayNext()
                            }
                        }
                        if let onAddToQueue {
                            Button("Add to Queue", systemImage: "text.append") {
                                onAddToQueue()
                            }
                        }
                        if let onAddToPlaylist {
                            Button("Add to Playlist", systemImage: "plus") {
                                onAddToPlaylist()
                            }
                        }
                        if let onGoToArtist {
                            Button("Go to Artist", systemImage: "person.fill") {
                                onGoToArtist()
                            }
                        }
                        if let onGoToAlbum {
                            Button("Go to Album", systemImage: "square.stack") {
                                onGoToAlbum()
                            }
                        }
                        if let shareURL {
                            ShareLink(
                                item: shareURL,
                                subject: Text(song.title),
                                message: Text(
                                    shareMessage
                                        ?? "\u{1F3B5} \(song.title) - \(song.artistName)"
                                )
                            ) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                        } else if let shareMessage {
                            ShareLink(item: shareMessage) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                }
            }
            // Round 2 SongRow recipe: 8pt vertical padding, 56pt min height.
            // Horizontal padding is owned by the parent list (lg/16pt) to avoid
            // compounding with existing call sites.
            .padding(.vertical, Theme.Spacing.sm)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(SongRowButtonStyle())
        .swipeActions(edge: .leading) {
            if let onPlayNext {
                Button { onPlayNext() } label: { Label("Play Next", systemImage: "text.insert") }
                    .tint(.green)
            }
        }
        .swipeActions(edge: .trailing) {
            if let onAddToQueue {
                Button { onAddToQueue() } label: { Label("Queue", systemImage: "text.append") }
                    .tint(.blue)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(song.title) by \(song.artistName)")
        .accessibilityHint("Double tap to play")
    }
}

// MARK: - Button Style

struct SongRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}