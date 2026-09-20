import SwiftUI

struct LikedSongsView: View {
    @Bindable var viewModel: LikedSongsViewModel
    @State private var searchText = ""
    @State private var editMode: EditMode = .inactive
    @State private var selectedSongs: Set<String> = []
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(PremiumManager.self) private var premiumManager
    @Environment(FeatureFlagManager.self) private var featureFlags
    @State private var showBulkUnlikeConfirmation = false
    @State private var showPaywall = false
    @State private var songForPlaylist: Song?
    @Environment(DIContainer.self) private var container

    init(viewModel: LikedSongsViewModel) {
        self.viewModel = viewModel
    }

    private var filteredFavorites: [Song] {
        if searchText.isEmpty { return viewModel.favorites }
        return viewModel.favorites.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.artistName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        // MARK: SafeArea — inherits dock inset from ContentView; uses .dockHidingOnScroll() + multi-select toolbar via .safeAreaInset(.bottom).
        Group {
            if viewModel.isLoading {
                // Shimmer skeleton matching song list layout (consistent with other screens)
                ScrollView {
                    LazyVStack(spacing: Theme.Spacing.xxs) {
                        ForEach(0..<8, id: \.self) { _ in
                            HStack(spacing: Theme.Spacing.md) {
                                ShimmerView(
                                    width: Theme.SizeTokens.artworkSmall,
                                    height: Theme.SizeTokens.artworkSmall,
                                    cornerRadius: Theme.CornerRadius.small
                                )
                                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                                    ShimmerView(width: 160, height: 14)
                                    ShimmerView(width: 100, height: 11)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, Theme.Spacing.lg)
                        }
                    }
                    .padding(.vertical, Theme.Spacing.sm)
                }
                .dockSafeBottom()
            } else if let error = viewModel.error {
                ErrorStateView(error) {
                    viewModel.loadFavorites()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.favorites.isEmpty {
                EmptyStateView(
                    icon: "heart",
                    title: "No Liked Songs",
                    message: "Tap the heart icon on any song to add it here"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: Theme.Spacing.xxs) {
                        // Inline search
                        InlineSearchBar(text: $searchText, placeholder: "Search liked songs")
                            .padding(.horizontal, Theme.Spacing.lg)
                            .padding(.bottom, Theme.Spacing.xs)

                        if editMode == .active {
                            selectionHeader
                        } else {
                            playbackHeader
                        }

                        ForEach(Array(filteredFavorites.enumerated()), id: \.element.id) {
                            index, song in
                            songRow(song: song, index: index)

                            // Inline ad every N songs (CMS-configurable)
                            if editMode == .inactive
                                && (index + 1) % featureFlags.adsSongInterval == 0
                                && index < filteredFavorites.count - 1
                            {
                                InlineFeedAdView()
                            }
                        }
                    }
                    .padding(.vertical, Theme.Spacing.sm)
                }
                .dockHidingOnScroll()
                .dockSafeBottom()
                .refreshable {
                    viewModel.loadFavorites()
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if editMode == .active && !selectedSongs.isEmpty {
                        multiSelectToolbar
                    }
                }
            }
        }
        .background(Theme.Colors.backgroundPrimary)
        .navigationTitle("Liked Songs")
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                CustomBackButton(style: .plain)
            }
            if !viewModel.favorites.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    SelectEditButton(isEditing: editMode == .active) {
                        withAnimation(Theme.AnimationPresets.smooth) {
                            editMode = editMode == .active ? .inactive : .active
                            if editMode == .inactive { selectedSongs.removeAll() }
                            playerVM.isDockHidden = editMode == .active
                        }
                    }
                }
            }
        }
        .task {
            viewModel.loadFavorites()
        }
        .onDisappear {
            if playerVM.isDockHidden {
                withAnimation(Theme.AnimationPresets.smooth) {
                    playerVM.isDockHidden = false
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .favoritesChanged)) { _ in
            viewModel.loadFavorites()
        }
        .confirmationDialog(
            "Remove \(selectedSongs.count) songs from favorites?",
            isPresented: $showBulkUnlikeConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove \(selectedSongs.count) Songs", role: .destructive) {
                let songsToRemove = viewModel.favorites.filter { selectedSongs.contains($0.id) }
                for song in songsToRemove {
                    viewModel.toggleFavorite(song: song)
                }
                withAnimation(Theme.AnimationPresets.smooth) {
                    selectedSongs.removeAll()
                    editMode = .inactive
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These songs will be removed from your Liked Songs.")
        }
        .sheet(item: $songForPlaylist) { song in
            AddToPlaylistSheet(song: song, managePlaylistUseCase: container.managePlaylistUseCase)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(Theme.Colors.backgroundPrimary)
        }
        .fullScreenCover(isPresented: $showPaywall) {
            PaywallView()
        }
    }

    // MARK: - Playback Header

    private var playbackHeader: some View {
        PlayShuffleButtons(
            onPlay: {
                guard let first = viewModel.favorites.first else { return }
                playerVM.play(song: first, fromQueue: viewModel.favorites)
            },
            onShuffle: {
                let shuffled = viewModel.favorites.shuffled()
                guard let first = shuffled.first else { return }
                playerVM.play(song: first, fromQueue: shuffled)
            }
        )
    }

    // MARK: - Selection

    private var selectionHeader: some View {
        HStack {
            Text("\(selectedSongs.count) selected")
                .font(Theme.Typography.subheadline)
                .foregroundStyle(Theme.Colors.textSecondary)
            Spacer()
            Button(
                selectedSongs.count == filteredFavorites.count
                    ? String(localized: "Deselect All") : String(localized: "Select All")
            ) {
                withAnimation(Theme.AnimationPresets.gentle) {
                    if selectedSongs.count == filteredFavorites.count {
                        selectedSongs.removeAll()
                    } else {
                        selectedSongs = Set(filteredFavorites.map(\.id))
                    }
                }
            }
            .font(Theme.Typography.subheadline.weight(.semibold))
            .foregroundStyle(Theme.Colors.brandGradientStart)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
    }

    @ViewBuilder
    private func songRow(song: Song, index: Int) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            if editMode == .active {
                Button { toggleSelection(song.id) } label: {
                    SelectionIndicator(isSelected: selectedSongs.contains(song.id))
                }
                .buttonStyle(.plain)
                .frame(minWidth: Theme.SizeTokens.touchTarget, minHeight: Theme.SizeTokens.touchTarget)
                .accessibilityLabel(selectedSongs.contains(song.id) ? "Deselect \(song.title)" : "Select \(song.title)")
            }

            SongRowView(
                song: song,
                isPlaying: editMode == .inactive && playerVM.currentSong?.id == song.id,
                isFavorite: true,
                onTap: {
                    if editMode == .active {
                        toggleSelection(song.id)
                    } else {
                        playerVM.play(song: song, fromQueue: viewModel.favorites)
                    }
                },
                onPlayNext: editMode == .inactive ? { playerVM.playNext(song) } : nil,
                onAddToQueue: editMode == .inactive ? { playerVM.addToQueue(song) } : nil,
                onAddToPlaylist: editMode == .inactive ? { songForPlaylist = song } : nil,
                onToggleFavorite: editMode == .inactive
                    ? {
                        viewModel.toggleFavorite(song: song)
                    } : nil,
                shareURL: editMode == .inactive ? song.youtubeURL : nil,
                shareMessage: editMode == .inactive
                    ? "\u{1F3B5} \(song.title) - \(song.artistName)" : nil,
                onGoToArtist: editMode == .inactive
                    ? song.artistId.map { artistId in
                        {
                            NotificationCenter.default.post(
                                name: .navigateToArtist,
                                object: nil,
                                userInfo: ["browseId": artistId]
                            )
                        }
                    } : nil,
                onGoToAlbum: editMode == .inactive
                    ? song.albumId.map { albumId in
                        {
                            NotificationCenter.default.post(
                                name: .navigateToAlbum,
                                object: nil,
                                userInfo: ["browseId": albumId]
                            )
                        }
                    } : nil
            )
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .staggeredAppear(index: index)
    }

    private func toggleSelection(_ id: String) {
        withAnimation(Theme.AnimationPresets.gentle) {
            if selectedSongs.contains(id) {
                selectedSongs.remove(id)
            } else {
                selectedSongs.insert(id)
            }
        }
    }

    // MARK: - Multi-Select Toolbar

    private var multiSelectToolbar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Theme.Spacing.xl) {
                Button {
                    showBulkUnlikeConfirmation = true
                } label: {
                    Label("Remove", systemImage: "heart.slash")
                }
                .tint(Theme.Colors.error)

                if featureFlags.isDownloadEnabled {
                    Button {
                        let songsToDownload = viewModel.favorites.filter {
                            selectedSongs.contains($0.id)
                                && !downloadManager.isDownloaded(songId: $0.id)
                        }
                        let availableSlots =
                            premiumManager.isPremium
                            ? songsToDownload.count
                            : max(0, premiumManager.freeDownloadLimit - downloadManager.downloadCount)

                        if availableSlots == 0 && !songsToDownload.isEmpty {
                            showPaywall = true
                            return
                        }

                        for song in songsToDownload.prefix(availableSlots) {
                            downloadManager.downloadSong(song)
                        }
                        if songsToDownload.count > availableSlots {
                            showPaywall = true
                        }
                        withAnimation(Theme.AnimationPresets.smooth) {
                            selectedSongs.removeAll()
                            editMode = .inactive
                        }
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .tint(Theme.Colors.brandGradientStart)
                }
            }
            .font(Theme.Typography.subheadline.weight(.medium))
            .padding(.vertical, Theme.Spacing.md)
            .padding(.horizontal, Theme.Spacing.lg)
            .frame(maxWidth: .infinity)
        }
        .background(.ultraThinMaterial)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
