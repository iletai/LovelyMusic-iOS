import Combine
import SwiftUI

struct PlaylistDetailView: View {
    let playlistId: String
    @State private var viewModel: PlaylistDetailViewModel
    @State private var searchText = ""
    @State private var editMode: EditMode = .inactive
    @State private var selectedSongs: Set<String> = []
    @State private var topSafeAreaInset: CGFloat = 0
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(PremiumManager.self) private var premiumManager
    @Environment(FeatureFlagManager.self) private var featureFlags
    @State private var showPaywall = false
    @State private var showRemoveSongsConfirmation = false

    init(
        playlistId: String, getPlaylistUseCase: GetPlaylistUseCase,
        managePlaylistUseCase: ManagePlaylistUseCase? = nil
    ) {
        self.playlistId = playlistId
        self._viewModel = State(
            initialValue: PlaylistDetailViewModel(
                getPlaylistUseCase: getPlaylistUseCase,
                managePlaylistUseCase: managePlaylistUseCase
            ))
    }

    var body: some View {
        // Previously this used a root `GeometryReader` purely to read the
        // parent's top safe-area inset and forward it to `ParallaxHeaderView`.
        // `.onGeometryChange` captures the same value without wrapping the
        // subtree in a layout proxy, preserving ScrollView perf characteristics.
        scrollBody(topInset: topSafeAreaInset)
            .onGeometryChange(for: CGFloat.self, of: { $0.safeAreaInsets.top }) { newValue in
                topSafeAreaInset = newValue
            }
            .background(Theme.Colors.backgroundPrimary)
            .fullScreenCover(isPresented: $showPaywall) {
                PaywallView()
            }
            .confirmationDialog(
                "Remove \(selectedSongs.count) songs from playlist?",
                isPresented: $showRemoveSongsConfirmation,
                titleVisibility: .visible
            ) {
                Button("Remove \(selectedSongs.count) Songs", role: .destructive) {
                    viewModel.removeSongs(songIds: selectedSongs)
                    withAnimation(Theme.AnimationPresets.smooth) {
                        selectedSongs.removeAll()
                        editMode = .inactive
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This action cannot be undone.")
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    CustomBackButton(style: .glassOrb)
                }
                if let playlist = viewModel.playlist {
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: Theme.Spacing.sm) {
                            // Rename button (only for local playlists)
                            if playlist.isLocal {
                                Menu {
                                    Button {
                                        viewModel.startRename()
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                        .font(.body)
                                        .foregroundStyle(Theme.Colors.textPrimary)
                                }
                            }

                            if !playlist.songs.isEmpty {
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
                }
            }
            .alert("Rename Playlist", isPresented: $viewModel.isRenamingPlaylist) {
                TextField("Playlist name", text: $viewModel.renameText)
                Button("Rename") {
                    Task { await viewModel.confirmRename() }
                }
                .disabled(viewModel.renameText.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel", role: .cancel) {
                    viewModel.renameText = ""
                }
            }
            .task {
                viewModel.loadPlaylist(playlistId: playlistId)
            }
            .onChange(of: searchText) { _, newValue in
                viewModel.searchText = newValue
            }
            .onDisappear {
                if playerVM.isDockHidden {
                    withAnimation(Theme.AnimationPresets.smooth) {
                        playerVM.isDockHidden = false
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .playlistsChanged)) { _ in
                viewModel.loadPlaylist(playlistId: playlistId)
            }
    }

    private func scrollBody(topInset: CGFloat) -> some View {
        // MARK: SafeArea — `.ignoresSafeArea(edges: .top)` is restricted to top
        // only (verified polish-A4). `.dockSafeBottom()` adds 16pt margin so
        // the last track clears the dock during inset transitions.
        ScrollView {
            if let playlist = viewModel.playlist {
                LazyVStack(spacing: 0) {
                    ParallaxHeaderView(thumbnailURL: playlist.thumbnailURL, topInset: topInset) {
                        Text(playlist.title)
                            .font(Theme.Typography.title)
                            .foregroundStyle(Theme.Colors.textPrimary)
                            .multilineTextAlignment(.center)

                        if let count = playlist.songCount {
                            Text("\(count) songs")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.textTertiary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Playlist: \(playlist.title)")

                    if editMode == .active {
                        selectionHeader
                    } else {
                        PlayShuffleButtons(
                            onPlay: {
                                if let first = playlist.songs.first {
                                    playerVM.play(song: first, fromQueue: playlist.songs)
                                }
                            },
                            onShuffle: {
                                if let random = playlist.songs.randomElement() {
                                    playerVM.play(
                                        song: random, fromQueue: playlist.songs.shuffled())
                                }
                            }
                        )
                    }

                    Rectangle()
                        .fill(Theme.Colors.divider)
                        .frame(height: 0.5)
                        .padding(.horizontal, Theme.Spacing.lg)

                    // Inline search (only show when there are songs to search)
                    if playlist.songs.count > 5 {
                        InlineSearchBar(text: $searchText, placeholder: "Search songs")
                            .padding(.horizontal, Theme.Spacing.lg)
                            .padding(.vertical, Theme.Spacing.xs)
                    }

                    ForEach(Array(viewModel.filteredSongs.enumerated()), id: \.element.id) {
                        index, song in
                        let isCurrentPlaying =
                            editMode == .inactive && playerVM.currentSong?.id == song.id

                        PlaylistSongRowView(
                            song: song,
                            index: index,
                            totalCount: viewModel.filteredSongs.count,
                            isCurrentlyPlaying: isCurrentPlaying,
                            editMode: editMode,
                            isSelected: selectedSongs.contains(song.id),
                            isDownloadEnabled: featureFlags.isDownloadEnabled,
                            isDownloaded: downloadManager.isDownloaded(songId: song.id),
                            canDownload: premiumManager.canDownload(
                                currentCount: downloadManager.downloadCount),
                            onTap: {
                                if editMode == .active {
                                    toggleSelection(song.id)
                                } else if let playlist = viewModel.playlist {
                                    playerVM.play(song: song, fromQueue: playlist.songs)
                                }
                            },
                            onPlayNext: { playerVM.playNext(song) },
                            onAddToQueue: { playerVM.addToQueue(song) },
                            onDownloadTap: {
                                if downloadManager.isDownloaded(songId: song.id) {
                                    downloadManager.removeDownload(songId: song.id)
                                } else if premiumManager.canDownload(
                                    currentCount: downloadManager.downloadCount)
                                {
                                    downloadManager.downloadSong(song)
                                } else {
                                    showPaywall = true
                                }
                            }
                        )
                        .onAppear {
                            if searchText.isEmpty,
                                song.id == viewModel.filteredSongs.last?.id,
                                viewModel.hasMoreSongs
                            {
                                viewModel.loadMoreSongs()
                            }
                        }

                        // Inline ad every N songs (CMS-configurable)
                        if editMode == .inactive && (index + 1) % featureFlags.adsSongInterval == 0
                            && index < viewModel.filteredSongs.count - 1
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
                    viewModel.loadPlaylist(playlistId: playlistId)
                }
            }
        }
        .dockHidingOnScroll()
        .dockSafeBottom()
        .scrollIndicators(.visible)
        .trackScrollPhase()
        .refreshable {
            viewModel.loadPlaylist(playlistId: playlistId)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if editMode == .active && !selectedSongs.isEmpty {
                multiSelectToolbar
            }
        }
        .ignoresSafeArea(edges: .top)
    }

    // MARK: - Selection

    private var selectionHeader: some View {
        HStack {
            Text("\(selectedSongs.count) selected")
                .font(Theme.Typography.subheadline)
                .foregroundStyle(Theme.Colors.textSecondary)
            Spacer()
            Button(
                selectedSongs.count == viewModel.filteredSongs.count
                    ? String(localized: "Deselect All") : String(localized: "Select All")
            ) {
                withAnimation(Theme.AnimationPresets.gentle) {
                    if selectedSongs.count == viewModel.filteredSongs.count {
                        selectedSongs.removeAll()
                    } else {
                        selectedSongs = Set(viewModel.filteredSongs.map(\.id))
                    }
                }
            }
            .font(Theme.Typography.subheadline.weight(.semibold))
            .foregroundStyle(Theme.Colors.brandGradientStart)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
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
                if viewModel.playlist?.isLocal == true {
                    Button {
                        showRemoveSongsConfirmation = true
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    .tint(Theme.Colors.error)
                }

                if featureFlags.isDownloadEnabled {
                    Button {
                        let songsToDownload = viewModel.filteredSongs.filter {
                            selectedSongs.contains($0.id)
                                && !downloadManager.isDownloaded(songId: $0.id)
                        }
                        let availableSlots =
                            premiumManager.isPremium
                            ? songsToDownload.count
                            : max(
                                0, premiumManager.freeDownloadLimit - downloadManager.downloadCount)

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

// MARK: - Extracted Row View

private struct PlaylistSongRowView: View {
    let song: Song
    let index: Int
    let totalCount: Int
    let isCurrentlyPlaying: Bool
    let editMode: EditMode
    let isSelected: Bool
    let isDownloadEnabled: Bool
    let isDownloaded: Bool
    let canDownload: Bool
    let onTap: () -> Void
    let onPlayNext: () -> Void
    let onAddToQueue: () -> Void
    let onDownloadTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: Theme.Spacing.md) {
                    if editMode == .active {
                        SelectionIndicator(isSelected: isSelected)
                    }

                    AsyncThumbnail(
                        url: song.thumbnailURL, size: 48, cornerRadius: Theme.CornerRadius.small)

                    VStack(alignment: .leading, spacing: Theme.Spacing.xxxs) {
                        Text(song.title)
                            .font(Theme.Typography.headline)
                            .foregroundStyle(
                                isCurrentlyPlaying
                                    ? Theme.Colors.brandGradientStart : Theme.Colors.textPrimary
                            )
                            .lineLimit(1)
                        Text(song.artistName)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Text(song.formattedDuration)
                        .font(Theme.Typography.caption2)
                        .foregroundStyle(Theme.Colors.textTertiary)

                    if editMode == .inactive {
                        Menu {
                            Button {
                                onPlayNext()
                            } label: {
                                Label(
                                    "Play Next",
                                    systemImage: "text.line.first.and.arrowtriangle.forward")
                            }
                            Button {
                                onAddToQueue()
                            } label: {
                                Label("Add to Queue", systemImage: "text.badge.plus")
                            }
                            if isDownloadEnabled {
                                Button(action: onDownloadTap) {
                                    if isDownloaded {
                                        Label("Remove Download", systemImage: "trash")
                                    } else if !canDownload {
                                        Label("Download (Limit Reached)", systemImage: "lock.fill")
                                    } else {
                                        Label("Download", systemImage: "arrow.down.circle")
                                    }
                                }
                            }
                            if let url = song.youtubeURL {
                                ShareLink(
                                    item: url,
                                    subject: Text(song.title),
                                    message: Text("🎵 \(song.title) - \(song.artistName)")
                                ) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                            } else {
                                ShareLink(item: "🎵 \(song.title) - \(song.artistName)") {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .foregroundStyle(Theme.Colors.textTertiary)
                                .frame(width: 44, height: 44)
                        }
                    }
                }
                .padding(.vertical, Theme.Spacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Theme.Spacing.lg)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(song.title) by \(song.artistName)")
            .accessibilityHint(editMode == .active ? "Double tap to select" : "Double tap to play")

            if index < totalCount - 1 {
                Rectangle()
                    .fill(Theme.Colors.divider)
                    .frame(height: 0.5)
                    .padding(
                        .leading,
                        (editMode == .active ? 28 + Theme.Spacing.md : 0) + 48 + Theme.Spacing.md
                            + Theme.Spacing.lg)
            }
        }
    }
}
