import SwiftUI

/// polish-E1 — Dedicated detail screen for a Home shelf's "View all" tap.
///
/// Renders the full set of items already loaded in the parent `MusicSection`
/// as a vertical list. Reuses `SongRowView` for songs and the existing card
/// layout for albums/artists/playlists so visual language matches the rest
/// of the app.
///
/// v1 scope: first page only (the items already in the section). Continuation
/// pagination via `browseShelfContinuation` is intentionally deferred — see the
/// TODO inside the body.
struct HomeSectionDetailView: View {
    let section: MusicSection

    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(FeatureFlagManager.self) private var featureFlags
    @State private var songForPlaylist: Song?

    private var songsInSection: [Song] {
        section.items.compactMap { item in
            if case .song(let s) = item { return s }
            return nil
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                    rowView(for: item)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .staggeredAppear(index: index)
                }

                // TODO: polish-E1.x — wire `browseShelfContinuation` for infinite scroll.
                // v1 ships with the first page (already-loaded items) only.
            }
            .padding(.vertical, Theme.Spacing.lg)
        }
        .dockSafeBottom()
        .background(Theme.Colors.backgroundPrimary)
        .navigationTitle(section.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                CustomBackButton(style: .plain)
            }
        }
        .sheet(item: $songForPlaylist) { song in
            // Reuse the same picker pattern as QueueView / FullPlayerView.
            // DIContainer surfaces `managePlaylistUseCase` via Environment.
            AddToPlaylistSheetHost(song: song)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(Theme.Colors.backgroundPrimary)
        }
    }

    @ViewBuilder
    private func rowView(for item: MusicSectionItem) -> some View {
        switch item {
        case .song(let song):
            SongRowView(
                song: song,
                isPlaying: playerVM.currentSong?.id == song.id,
                downloadState: featureFlags.isDownloadEnabled
                    ? downloadManager.downloadState(for: song.id) : nil,
                onTap: {
                    playerVM.play(song: song, fromQueue: songsInSection)
                },
                onPlayNext: { playerVM.playNext(song) },
                onAddToQueue: { playerVM.addToQueue(song) },
                onAddToPlaylist: { songForPlaylist = song },
                onDownload: featureFlags.isDownloadEnabled
                    ? {
                        downloadManager.downloadSong(song)
                    } : nil,
                onRemoveDownload: featureFlags.isDownloadEnabled
                    ? {
                        downloadManager.removeDownload(songId: song.id)
                    } : nil,
                shareURL: song.youtubeURL,
                shareMessage: "\u{1F3B5} \(song.title) - \(song.artistName)"
            )

        case .album(let album):
            NavigationLink(value: Route.album(browseId: album.id)) {
                cardRow(
                    title: album.title,
                    subtitle: album.artistName,
                    thumbnailURL: album.thumbnailURL,
                    cornerRadius: Theme.CornerRadius.small
                )
            }
            .buttonStyle(.plain)

        case .artist(let artist):
            NavigationLink(value: Route.artist(browseId: artist.id)) {
                cardRow(
                    title: artist.name,
                    subtitle: artist.subscriberCount,
                    thumbnailURL: artist.thumbnailURL,
                    cornerRadius: 28
                )
            }
            .buttonStyle(.plain)

        case .playlist(let playlist):
            NavigationLink(value: Route.playlist(playlistId: playlist.id)) {
                cardRow(
                    title: playlist.title,
                    subtitle: playlist.songCount.map { "\($0) songs" },
                    thumbnailURL: playlist.thumbnailURL,
                    cornerRadius: Theme.CornerRadius.small
                )
            }
            .buttonStyle(.plain)

        case .audiobook(let audiobook):
            cardRow(
                title: audiobook.title,
                subtitle: audiobook.authorName,
                thumbnailURL: audiobook.thumbnailURL,
                cornerRadius: Theme.CornerRadius.small
            )

        case .userChannel(let channel):
            cardRow(
                title: channel.name,
                subtitle: nil,
                thumbnailURL: channel.thumbnailURL,
                cornerRadius: 28
            )
        }
    }

    private func cardRow(
        title: String,
        subtitle: String?,
        thumbnailURL: String?,
        cornerRadius: CGFloat
    ) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            AsyncThumbnail(url: thumbnailURL, size: 56, cornerRadius: cornerRadius)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Theme.Colors.textTertiary)
        }
        .padding(.vertical, Theme.Spacing.sm)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }
}

// MARK: - AddToPlaylist host

/// Tiny adapter that pulls `managePlaylistUseCase` from `DIContainer` so this
/// view can present the same picker sheet used elsewhere in the app.
private struct AddToPlaylistSheetHost: View {
    let song: Song
    @Environment(DIContainer.self) private var container

    var body: some View {
        AddToPlaylistSheet(
            song: song,
            managePlaylistUseCase: container.managePlaylistUseCase
        )
    }
}
