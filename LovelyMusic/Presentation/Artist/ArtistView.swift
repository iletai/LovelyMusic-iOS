import SwiftUI

struct ArtistView: View {
    let browseId: String
    @State private var viewModel: ArtistViewModel
    @State private var showAllSongs = false
    @State private var topSafeAreaInset: CGFloat = 0
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(DIContainer.self) private var container
    @State private var songForPlaylist: Song?

    init(browseId: String, getArtistUseCase: GetArtistUseCase) {
        self.browseId = browseId
        self._viewModel = State(initialValue: ArtistViewModel(getArtistUseCase: getArtistUseCase))
    }

    var body: some View {
        scrollBody
            .onGeometryChange(for: CGFloat.self, of: { $0.safeAreaInsets.top }) { newValue in
                topSafeAreaInset = newValue
            }
            .background(Theme.Colors.backgroundPrimary)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    CustomBackButton(style: .glassOrb)
                }
            }
            .task {
                viewModel.loadArtist(browseId: browseId)
            }
            .sheet(item: $songForPlaylist) { song in
                AddToPlaylistSheet(song: song, managePlaylistUseCase: container.managePlaylistUseCase)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(Theme.Colors.backgroundPrimary)
            }
    }

    private var scrollBody: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let artist = viewModel.artist {
                    ParallaxHeaderView(
                        thumbnailURL: artist.thumbnailURL,
                        height: 400,
                        isCircular: true,
                        topInset: topSafeAreaInset
                    ) {
                        Text(artist.name)
                            .font(Theme.Typography.largeTitle)
                            .foregroundStyle(Theme.Colors.textPrimary)
                            .accessibilityAddTraits(.isHeader)

                        if let subs = artist.subscriberCount {
                            Text(subs)
                                .font(Theme.Typography.subheadline)
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                    }

                    PlayShuffleButtons(
                        onPlay: {
                            if let first = artist.songs.first {
                                playerVM.play(song: first, fromQueue: artist.songs)
                            }
                        },
                        onShuffle: {
                            if let random = artist.songs.randomElement() {
                                playerVM.play(song: random, fromQueue: artist.songs.shuffled())
                            }
                        }
                    )

                    // Popular songs
                    if !artist.songs.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            HStack {
                                Text("Popular Songs")
                                    .font(Theme.Typography.title)
                                    .foregroundStyle(Theme.Colors.textPrimary)
                                    .accessibilityAddTraits(.isHeader)
                                Spacer()
                                if artist.songs.count > 5 {
                                    Button {
                                        withAnimation(Theme.AnimationPresets.smooth) {
                                            showAllSongs.toggle()
                                        }
                                    } label: {
                                        Text(
                                            showAllSongs
                                                ? String(localized: "Show Less")
                                                : String(localized: "See All")
                                        )
                                        .font(Theme.Typography.caption)
                                        .foregroundStyle(Theme.Colors.textSecondary)
                                    }
                                }
                            }
                            .padding(.horizontal, Theme.Spacing.lg)

                            let displayedSongs =
                                showAllSongs ? artist.songs : Array(artist.songs.prefix(5))
                            ForEach(Array(displayedSongs.enumerated()), id: \.element.id) {
                                index, song in
                                SongRowView(
                                    song: song,
                                    trackNumber: index + 1,
                                    isPlaying: playerVM.currentSong?.id == song.id,
                                    showThumbnail: false,
                                    isFavorite: playerVM.isFavorite(songId: song.id),
                                    onTap: {
                                        playerVM.play(song: song, fromQueue: artist.songs)
                                    },
                                    onPlayNext: { playerVM.playNext(song) },
                                    onAddToQueue: { playerVM.addToQueue(song) },
                                    onAddToPlaylist: { songForPlaylist = song },
                                    onToggleFavorite: { Task { await playerVM.toggleFavorite(song: song) } },
                                    shareURL: song.youtubeURL,
                                    shareMessage:
                                        "\u{1F3B5} \(song.title) - \(song.artistName)",
                                    onGoToAlbum: song.albumId.map { albumId in
                                        {
                                            NotificationCenter.default.post(
                                                name: .navigateToAlbum,
                                                object: nil,
                                                userInfo: ["browseId": albumId]
                                            )
                                        }
                                    }
                                )
                                .padding(.horizontal, Theme.Spacing.lg)
                                .staggeredAppear(index: index)
                                .onAppear {
                                    if showAllSongs && song.id == artist.songs.last?.id
                                        && viewModel.hasMoreSongs
                                    {
                                        viewModel.loadMoreSongs()
                                    }
                                }
                            }

                            if viewModel.isLoadingMore {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, Theme.Spacing.sm)
                            }
                        }
                    }

                    // Inline ad between songs and albums
                    InlineFeedAdView()

                    // Albums
                    if !artist.albums.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                            Text("Albums")
                                .font(Theme.Typography.title)
                                .foregroundStyle(Theme.Colors.textPrimary)
                                .padding(.horizontal, Theme.Spacing.lg)
                                .accessibilityAddTraits(.isHeader)

                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: Theme.Spacing.md) {
                                    ForEach(artist.albums) { album in
                                        NavigationLink(value: Route.album(browseId: album.id)) {
                                            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                                                AsyncThumbnail(
                                                    url: album.thumbnailURL, size: 180,
                                                    cornerRadius: Theme.CornerRadius.medium)
                                                Text(album.title)
                                                    .font(Theme.Typography.subheadline)
                                                    .foregroundStyle(Theme.Colors.textPrimary)
                                                    .lineLimit(2)
                                                if let year = album.year {
                                                    Text(year)
                                                        .font(Theme.Typography.caption)
                                                        .foregroundStyle(Theme.Colors.textSecondary)
                                                }
                                            }
                                            .frame(width: 180)
                                        }
                                        .buttonStyle(.bouncy)
                                        .accessibilityLabel("Album: \(album.title)")
                                    }
                                }
                                .padding(.horizontal, Theme.Spacing.lg)
                            }
                        }
                    }

                    // Singles
                    if !artist.singles.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                            Text("Singles")
                                .font(Theme.Typography.title)
                                .foregroundStyle(Theme.Colors.textPrimary)
                                .padding(.horizontal, Theme.Spacing.lg)
                                .accessibilityAddTraits(.isHeader)

                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: Theme.Spacing.md) {
                                    ForEach(artist.singles) { single in
                                        NavigationLink(value: Route.album(browseId: single.id)) {
                                            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                                                AsyncThumbnail(
                                                    url: single.thumbnailURL, size: 150,
                                                    cornerRadius: Theme.CornerRadius.medium)
                                                Text(single.title)
                                                    .font(Theme.Typography.subheadline)
                                                    .foregroundStyle(Theme.Colors.textPrimary)
                                                    .lineLimit(2)
                                                if let year = single.year {
                                                    Text(year)
                                                        .font(Theme.Typography.caption)
                                                        .foregroundStyle(Theme.Colors.textSecondary)
                                                }
                                            }
                                            .frame(width: 150)
                                        }
                                        .buttonStyle(.bouncy)
                                        .accessibilityLabel("Single: \(single.title)")
                                    }
                                }
                                .padding(.horizontal, Theme.Spacing.lg)
                            }
                        }
                    }
                } else if viewModel.isLoading {
                    VStack {
                        ShimmerView(height: 350)
                        ShimmerView(width: 200, height: 28)
                            .padding(.horizontal, Theme.Spacing.lg)
                    }
                } else if let error = viewModel.error {
                    ErrorStateView(error) {
                        viewModel.loadArtist(browseId: browseId)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .ignoresSafeArea(edges: .top)
        .dockHidingOnScroll()
        .dockSafeBottom()
        .refreshable {
            viewModel.loadArtist(browseId: browseId)
        }
    }
}
