import SwiftUI

struct DownloadsView: View {
    @State private var editMode: EditMode = .inactive
    @State private var selectedSongs: Set<String> = []
    @State private var sortOrder: DownloadsSortOrder = .load()
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(PremiumManager.self) private var premiumManager
    @State private var showPaywall = false
    @State private var showClearAllConfirmation = false
    @State private var showRemoveSelectedConfirmation = false
    @State private var songForPlaylist: Song?
    @Environment(DIContainer.self) private var container

    /// polish-E3 — sorted view of `downloadManager.downloadedSongs` per
    /// `sortOrder`. Default `.recentlyAdded` returns insertion order.
    private var sortedDownloads: [DownloadManager.DownloadedSong] {
        sortOrder.apply(to: downloadManager.downloadedSongs)
    }

    // MARK: SafeArea — applies own .dockSafeBottom() on the downloads list ScrollView so the last row clears the floating dock + ad-banner inset by ≥ 16pt during inset transitions.
    var body: some View {
        Group {
            if downloadManager.downloadedSongs.isEmpty {
                emptyState
            } else {
                downloadsList
            }
        }
        .background(Theme.Colors.backgroundPrimary)
        .navigationTitle("Downloads")
        .navigationBarBackButtonHidden(true)
        .confirmationDialog(
            "Remove all downloads?", isPresented: $showClearAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove All", role: .destructive) {
                downloadManager.clearAllDownloads()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This will remove all downloaded songs from your device. You can re-download them later."
            )
        }
        .confirmationDialog(
            "Remove \(selectedSongs.count) downloads?",
            isPresented: $showRemoveSelectedConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove \(selectedSongs.count) Downloads", role: .destructive) {
                withAnimation(Theme.AnimationPresets.smooth) {
                    for id in selectedSongs {
                        downloadManager.removeDownload(songId: id)
                    }
                    selectedSongs.removeAll()
                    editMode = .inactive
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This will remove the selected songs from your device. You can re-download them later."
            )
        }
        .sheet(item: $songForPlaylist) { song in
            AddToPlaylistSheet(song: song, managePlaylistUseCase: container.managePlaylistUseCase)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(Theme.Colors.backgroundPrimary)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                CustomBackButton(style: .plain)
            }
            if !downloadManager.downloadedSongs.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: Theme.Spacing.md) {
                        Button(editMode == .active ? "Done" : "Select") {
                            withAnimation(Theme.AnimationPresets.smooth) {
                                editMode = editMode == .active ? .inactive : .active
                                if editMode == .inactive { selectedSongs.removeAll() }
                            }
                        }
                        .foregroundStyle(Theme.Colors.brandGradientStart)

                        if editMode == .inactive {
                            Menu {
                                Button(role: .destructive) {
                                    showClearAllConfirmation = true
                                } label: {
                                    Label("Remove All Downloads", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .foregroundStyle(Theme.Colors.textSecondary)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Downloads List

    private var downloadsList: some View {
        // ponytail: sort once per render, not per-access (4× calls eliminated)
        let sorted = sortedDownloads
        return ScrollView {
            LazyVStack(spacing: 0) {
                if editMode == .active {
                    selectionHeader
                } else {
                    storageHeader
                    playAllShuffleSortHeader
                }

                ForEach(Array(sorted.enumerated()), id: \.element.id) { index, entry in
                    HStack(spacing: Theme.Spacing.md) {
                        if editMode == .active {
                            Button { toggleSelection(entry.song.id) } label: {
                                Image(
                                    systemName: selectedSongs.contains(entry.song.id)
                                        ? "checkmark.circle.fill" : "circle"
                                )
                                .font(.title3)
                                .foregroundStyle(
                                    selectedSongs.contains(entry.song.id)
                                        ? Theme.Colors.brandGradientStart : Theme.Colors.textTertiary
                                )
                            }
                            .buttonStyle(.plain)
                            .frame(minWidth: Theme.SizeTokens.touchTarget, minHeight: Theme.SizeTokens.touchTarget)
                            .accessibilityLabel(selectedSongs.contains(entry.song.id) ? "Deselect" : "Select")
                        }

                        SongRowView(
                            song: entry.song,
                            isPlaying: editMode == .inactive
                                && playerVM.currentSong?.id == entry.song.id,
                            downloadState: editMode == .inactive
                                ? downloadManager.downloadState(for: entry.song.id) : nil,
                            onTap: {
                                if editMode == .active {
                                    toggleSelection(entry.song.id)
                                } else {
                                    let songs = sorted.map(\.song)
                                    playerVM.play(song: entry.song, fromQueue: songs)
                                }
                            },
                            onPlayNext: editMode == .inactive
                                ? { playerVM.playNext(entry.song) } : nil,
                            onAddToQueue: editMode == .inactive
                                ? {
                                    playerVM.addToQueue(entry.song)
                                } : nil,
                            onAddToPlaylist: editMode == .inactive ? { songForPlaylist = entry.song } : nil,
                            onToggleFavorite: editMode == .inactive
                                ? { Task<Void, Never> { await playerVM.toggleFavorite(song: entry.song) } } : nil,
                            onRemoveDownload: editMode == .inactive
                                ? {
                                    withAnimation(Theme.AnimationPresets.smooth) {
                                        downloadManager.removeDownload(songId: entry.song.id)
                                    }
                                } : nil,
                            shareURL: editMode == .inactive ? entry.song.youtubeURL : nil,
                            shareMessage: editMode == .inactive
                                ? "\u{1F3B5} \(entry.song.title) - \(entry.song.artistName)"
                                : nil,
                            onGoToArtist: editMode == .inactive
                                ? entry.song.artistId.map { artistId in
                                    {
                                        NotificationCenter.default.post(
                                            name: .navigateToArtist,
                                            object: nil,
                                            userInfo: ["browseId": artistId]
                                        )
                                    }
                                } : nil,
                            onGoToAlbum: editMode == .inactive
                                ? entry.song.albumId.map { albumId in
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
            }
            .padding(.vertical, Theme.Spacing.lg)
        }
        .dockSafeBottom()
        .refreshable {
            downloadManager.reloadDownloads()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if editMode == .active && !selectedSongs.isEmpty {
                multiSelectToolbar
            }
        }
    }

    // MARK: - polish-E3 — Play All / Shuffle / Sort header

    private var playAllShuffleSortHeader: some View {
        let headerSorted = sortedDownloads
        return HStack(spacing: Theme.Spacing.sm) {
            Button {
                let songs = headerSorted.map(\.song)
                guard let first = songs.first else { return }
                playerVM.play(song: first, fromQueue: songs)
            } label: {
                Label("Play All", systemImage: "play.fill")
                    .font(Theme.Typography.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .frame(maxWidth: .infinity, minHeight: Theme.SizeTokens.touchTarget)
                    .background(Theme.Colors.brandGradient, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play all downloads")

            Button {
                let songs = headerSorted.map(\.song).shuffled()
                guard let first = songs.first else { return }
                playerVM.play(song: first, fromQueue: songs)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .font(Theme.Typography.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .frame(maxWidth: .infinity, minHeight: Theme.SizeTokens.touchTarget)
                    .background(Theme.Colors.brandGradient, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Shuffle downloads")

            Menu {
                Picker("Sort", selection: $sortOrder) {
                    ForEach(DownloadsSortOrder.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(Theme.Typography.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Theme.Colors.surfaceCard, in: Circle())
            }
            .accessibilityLabel("Sort downloads. Current: \(sortOrder.displayName)")
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.md)
        .onChange(of: sortOrder) { _, newValue in
            newValue.save()
        }
    }

    // MARK: - Headers

    private var storageHeader: some View {
        VStack(spacing: Theme.Spacing.sm) {
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(Theme.Colors.brandGradientStart)
                Text("\(downloadManager.downloadCount) songs")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.Colors.textSecondary)
                Spacer()
                if !premiumManager.isPremium {
                    downloadLimitBadge
                }
                Text(downloadManager.formattedTotalSize())
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)

            if !premiumManager.isPremium
                && downloadManager.downloadCount >= premiumManager.freeDownloadLimit - 1
            {
                premiumUpsellBanner
                    .padding(.horizontal, Theme.Spacing.lg)
            }
        }
    }

    private var downloadLimitBadge: some View {
        Text("\(downloadManager.downloadCount)/\(premiumManager.freeDownloadLimit)")
            .font(Theme.Typography.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xxxs)
            .background(
                Capsule()
                    .fill(
                        downloadManager.downloadCount >= premiumManager.freeDownloadLimit
                            ? AnyShapeStyle(Theme.Colors.error)
                            : AnyShapeStyle(Theme.Colors.brandGradient))
            )
    }

    private var premiumUpsellBanner: some View {
        Button {
            showPaywall = true
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "lock.fill")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: Theme.Spacing.xxxs) {
                    Text(
                        downloadManager.downloadCount >= premiumManager.freeDownloadLimit
                            ? "Download limit reached"
                            : "Almost at your download limit"
                    )
                    .font(Theme.Typography.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    Text("Upgrade to Premium for unlimited downloads")
                        .font(Theme.Typography.caption2)
                        .foregroundStyle(.white.opacity(0.8))
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(Theme.Typography.caption2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(Theme.Spacing.md)
            .background(
                LinearGradient(
                    colors: [Theme.Colors.brandGradientStart, Theme.Colors.brandGradientEnd],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.medium))
        }
        .buttonStyle(.plain)
        .fullScreenCover(isPresented: $showPaywall) {
            PaywallView()
        }
    }

    private var selectionHeader: some View {
        HStack {
            Text("\(selectedSongs.count) selected")
                .font(Theme.Typography.subheadline)
                .foregroundStyle(Theme.Colors.textSecondary)
            Spacer()
            Button(
                selectedSongs.count == downloadManager.downloadedSongs.count
                    ? "Deselect All" : "Select All"
            ) {
                withAnimation(Theme.AnimationPresets.gentle) {
                    if selectedSongs.count == downloadManager.downloadedSongs.count {
                        selectedSongs.removeAll()
                    } else {
                        selectedSongs = Set(downloadManager.downloadedSongs.map(\.song.id))
                    }
                }
            }
            .font(Theme.Typography.subheadline.weight(.semibold))
            .foregroundStyle(Theme.Colors.brandGradientStart)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
    }

    // MARK: - Selection

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
            HStack {
                Button {
                    showRemoveSelectedConfirmation = true
                } label: {
                    Label("Remove Downloads", systemImage: "trash")
                }
                .tint(Theme.Colors.error)
            }
            .font(Theme.Typography.subheadline.weight(.medium))
            .padding(.vertical, Theme.Spacing.md)
            .padding(.horizontal, Theme.Spacing.lg)
            .frame(maxWidth: .infinity)
        }
        .background(.ultraThinMaterial)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack {
            Spacer()
            EmptyStateView(
                icon: "arrow.down.circle",
                title: "No Downloads Yet",
                message: "Download songs for offline listening",
                actionLabel: "Browse Music",
                onAction: {
                    NotificationCenter.default.post(name: .switchToSearchTab, object: nil)
                }
            )
            Spacer()
        }
    }
}
