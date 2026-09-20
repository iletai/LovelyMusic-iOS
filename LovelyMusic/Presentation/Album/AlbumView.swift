import SwiftUI

struct AlbumView: View {
    let browseId: String
    @State private var viewModel: AlbumViewModel
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(FeatureFlagManager.self) private var featureFlags
    @Environment(DIContainer.self) private var container
    @State private var songForPlaylist: Song?

    init(browseId: String, getAlbumUseCase: GetAlbumUseCase) {
        self.browseId = browseId
        self._viewModel = State(initialValue: AlbumViewModel(getAlbumUseCase: getAlbumUseCase))
    }

    var body: some View {
        // MARK: SafeArea — inherits dock inset from ContentView. AlbumView has no
        // `.ignoresSafeArea` itself; `.dockSafeBottom()` adds 16pt margin so the
        // last song row clears the dock cleanly during inset transitions (polish-A4).
        ScrollView {
            if let album = viewModel.album {
                LazyVStack(spacing: 0) {
                    // Album header with parallax
                    ParallaxHeaderView(thumbnailURL: album.thumbnailURL) {
                        Text(album.title)
                            .font(Theme.Typography.title)
                            .foregroundStyle(Theme.Colors.textPrimary)
                            .multilineTextAlignment(.center)

                        Text(album.artistName)
                            .font(Theme.Typography.subheadline)
                            .foregroundStyle(Theme.Colors.textSecondary)

                        Text(
                            [album.year.map { String($0) }, "\(album.songs.count) songs", album.totalDuration]
                                .compactMap { $0 }
                                .joined(separator: " · ")
                        )
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Album: \(album.title) by \(album.artistName)")

                    // Play/Shuffle buttons
                    PlayShuffleButtons(
                        onPlay: {
                            if let first = album.songs.first {
                                playerVM.play(song: first, fromQueue: album.songs)
                            }
                        },
                        onShuffle: {
                            if let random = album.songs.randomElement() {
                                playerVM.play(song: random, fromQueue: album.songs.shuffled())
                            }
                        }
                    )

                    // Track list
                    Rectangle()
                        .fill(Theme.Colors.divider)
                        .frame(height: 0.5)
                        .padding(.horizontal, Theme.Spacing.lg)

                    ForEach(Array(album.songs.enumerated()), id: \.element.id) { index, song in
                        VStack(spacing: 0) {
                            SongRowView(
                                song: song,
                                trackNumber: index + 1,
                                isPlaying: playerVM.currentSong?.id == song.id,
                                showThumbnail: false,
                                isFavorite: playerVM.isFavorite(songId: song.id),
                                onTap: {
                                    playerVM.play(song: song, fromQueue: album.songs)
                                },
                                onPlayNext: { playerVM.playNext(song) },
                                onAddToQueue: {
                                    playerVM.addToQueue(song)
                                },
                                onAddToPlaylist: { songForPlaylist = song },
                                onToggleFavorite: { Task { await playerVM.toggleFavorite(song: song) } },
                                shareURL: song.youtubeURL,
                                shareMessage: "\u{1F3B5} \(song.title) - \(song.artistName)",
                                onGoToArtist: song.artistId.map { artistId in
                                    {
                                        NotificationCenter.default.post(
                                            name: .navigateToArtist,
                                            object: nil,
                                            userInfo: ["browseId": artistId]
                                        )
                                    }
                                }
                            )
                            .padding(.horizontal, Theme.Spacing.lg)

                            if index < album.songs.count - 1 {
                                Rectangle()
                                    .fill(Theme.Colors.divider)
                                    .frame(height: 0.5)
                                    .padding(.leading, 56 + Theme.Spacing.lg)
                            }
                        }
                        .staggeredAppear(index: index)
                        .onAppear {
                            if song.id == album.songs.last?.id && viewModel.hasMoreSongs {
                                viewModel.loadMoreSongs()
                            }
                        }

                        // Inline ad every N songs (CMS-configurable)
                        if (index + 1) % featureFlags.adsSongInterval == 0
                            && index < album.songs.count - 1
                        {
                            InlineFeedAdView()
                        }
                    }

                    if viewModel.isLoadingMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.Spacing.md)
                    }
                }
            } else if viewModel.isLoading {
                VStack(spacing: Theme.Spacing.lg) {
                    ShimmerView(width: 280, height: 280, cornerRadius: Theme.CornerRadius.medium)
                    ShimmerView(width: 180, height: 22)
                    ShimmerView(width: 120, height: 16)
                }
                .padding(.top, Theme.Spacing.xxxl)
                .frame(maxWidth: .infinity)
            } else if let error = viewModel.error {
                ErrorStateView(error) {
                    Task { viewModel.loadAlbum(browseId: browseId) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .dockHidingOnScroll()
        .dockSafeBottom()
        .refreshable {
            viewModel.loadAlbum(browseId: browseId)
        }
        .background(Theme.Colors.backgroundPrimary)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                CustomBackButton(style: .glassOrb)
            }
        }
        .task {
            viewModel.loadAlbum(browseId: browseId)
        }
        .sheet(item: $songForPlaylist) { song in
            AddToPlaylistSheet(song: song, managePlaylistUseCase: container.managePlaylistUseCase)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(Theme.Colors.backgroundPrimary)
        }
    }
}
