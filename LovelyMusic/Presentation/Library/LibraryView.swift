import Combine
import SwiftUI

struct LibraryView: View {
    @Bindable var viewModel: LibraryViewModel
    @State private var searchText = ""
    @State private var editMode: EditMode = .inactive
    @State private var selectedPlaylists: Set<String> = []
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(PremiumManager.self) private var premiumManager
    @Environment(FeatureFlagManager.self) private var featureFlags
    @AppStorage("libraryPremiumBannerDismissed") private var bannerDismissed = false
    @State private var showPaywall = false
    @State private var libraryScrollPosition = ScrollPosition(idType: String.self)
    @State private var showBulkDeleteConfirmation = false

    init(viewModel: LibraryViewModel) {
        self.viewModel = viewModel
    }

    private var filteredPlaylists: [Playlist] {
        if searchText.isEmpty { return viewModel.playlists }
        return viewModel.playlists.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        // MARK: SafeArea — inherits dock inset from ContentView; .safeAreaInset(.bottom) below carries the multi-select toolbar only.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                // Inline search
                InlineSearchBar(text: $searchText, placeholder: "Search library")
                    .padding(.horizontal, Theme.Spacing.lg)

                // Premium upsell banner
                libraryPremiumBanner

                // Error state
                if let error = viewModel.error {
                    ErrorStateView(
                        error,
                        retryAction: {
                            Task { await viewModel.loadLibrary() }
                        })
                }

                // Recently Played section
                recentlyPlayedSection

                // Playlists section
                playlistsSection

                // Round 2: removed duplicate global empty state. The playlists section
                // already shows "No Playlists Yet" when both lists are empty.
            }
            .padding(.vertical, Theme.Spacing.lg)
        }
        .scrollPosition($libraryScrollPosition)
        .dockHidingOnScroll()
        .dockSafeBottom()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if editMode == .active && !selectedPlaylists.isEmpty {
                multiSelectToolbar
            }
        }
        .background(Theme.Colors.backgroundPrimary)
        .navigationTitle("Library")
        .toolbar {
            if !viewModel.playlists.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    SelectEditButton(isEditing: editMode == .active) {
                        withAnimation(Theme.AnimationPresets.smooth) {
                            editMode = editMode == .active ? .inactive : .active
                            if editMode == .inactive { selectedPlaylists.removeAll() }
                            playerVM.isDockHidden = editMode == .active
                        }
                    }
                }
            }
        }
        .refreshable {
            await viewModel.loadLibrary()
        }
        .task {
            await viewModel.loadLibrary()
        }
        .onDisappear {
            if playerVM.isDockHidden {
                withAnimation(Theme.AnimationPresets.smooth) {
                    playerVM.isDockHidden = false
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .playlistsChanged)) { _ in
            Task { await viewModel.loadLibrary() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .recentlyPlayedChanged)) { _ in
            Task { await viewModel.loadLibrary() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .favoritesChanged)) { _ in
            Task { await viewModel.loadLibrary() }
        }
        .alert("New Playlist", isPresented: $viewModel.isCreatingPlaylist) {
            TextField("Playlist name", text: $viewModel.newPlaylistName)
            Button("Create") {
                Task { await viewModel.createPlaylist() }
            }
            .disabled(viewModel.newPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {
                viewModel.newPlaylistName = ""
            }
        } message: {
            Text("Give your playlist a name")
        }
        .alert("Rename Playlist", isPresented: $viewModel.isRenamingPlaylist) {
            TextField("Playlist name", text: $viewModel.renameText)
            Button("Rename") {
                Task { await viewModel.confirmRename() }
            }
            .disabled(viewModel.renameText.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {
                viewModel.renameText = ""
                viewModel.renamingPlaylistId = nil
            }
        }
        .confirmationDialog(
            "Delete \"\(viewModel.playlistToDelete?.title ?? "")\"?",
            isPresented: $viewModel.showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task { await viewModel.confirmDelete() }
            }
            Button("Cancel", role: .cancel) {
                viewModel.playlistToDelete = nil
            }
        } message: {
            Text("This action cannot be undone.")
        }
        .confirmationDialog(
            "Delete \(selectedPlaylists.count) playlists?",
            isPresented: $showBulkDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete \(selectedPlaylists.count) Playlists", role: .destructive) {
                viewModel.deletePlaylists(ids: selectedPlaylists)
                withAnimation(Theme.AnimationPresets.smooth) {
                    selectedPlaylists.removeAll()
                    editMode = .inactive
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
    }

    // MARK: - Premium Banner

    @ViewBuilder
    private var libraryPremiumBanner: some View {
        if featureFlags.isDownloadEnabled && !premiumManager.isPremium && !bannerDismissed {
            Button {
                showPaywall = true
            } label: {
                HStack(spacing: Theme.Spacing.md) {
                    // Round 2 Q2: gold scoped to paywall only — use brand purple here.
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.Colors.brandGradientStart)

                    Text("Unlock unlimited downloads & more")
                        .font(Theme.Typography.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(Theme.Colors.textPrimary)

                    Spacer()

                    Button {
                        withAnimation(Theme.AnimationPresets.smooth) {
                            bannerDismissed = true
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.Colors.textTertiary)
                            // Enlarge tap target to 44×44pt minimum (icon stays 10pt visually)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.md)
                .frame(maxHeight: 60)
                .background(
                    Theme.Colors.brandGradientStart.opacity(0.08)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                        .stroke(Theme.Colors.brandGradientStart.opacity(0.25), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.medium))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Theme.Spacing.lg)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .fullScreenCover(isPresented: $showPaywall) {
                PaywallView()
            }
        }
    }

    // MARK: - Recently Played

    @ViewBuilder
    private var recentlyPlayedSection: some View {
        if viewModel.isLoading {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Recently Played")
                    .font(Theme.Typography.title3.weight(.bold))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .padding(.horizontal, Theme.Spacing.lg)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.md) {
                        ForEach(0..<5, id: \.self) { _ in
                            VStack(spacing: Theme.Spacing.xs) {
                                ShimmerView()
                                    .frame(width: 80, height: 80)
                                    .clipShape(Circle())
                                ShimmerView()
                                    .frame(width: 50, height: 10)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                }
            }
        } else if !viewModel.recentlyPlayed.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack {
                    Text("Recently Played")
                        .font(Theme.Typography.title3.weight(.bold))
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Text("\(viewModel.recentlyPlayed.prefix(10).count)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.Colors.surfaceCard)
                        .clipShape(Capsule())
                    Spacer()
                }
                .padding(.horizontal, Theme.Spacing.lg)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: Theme.Spacing.md) {
                        ForEach(
                            Array(viewModel.recentlyPlayed.prefix(10).enumerated()),
                            id: \.element.id
                        ) { index, song in
                            Button {
                                playerVM.play(song: song)
                            } label: {
                                VStack(spacing: Theme.Spacing.sm) {
                                    AsyncThumbnail(
                                        url: song.thumbnailURL, size: 80,
                                        cornerRadius: Theme.CornerRadius.full)
                                    Text(song.title)
                                        .font(Theme.Typography.caption)
                                        .foregroundStyle(Theme.Colors.textPrimary)
                                        .lineLimit(1)
                                }
                                .frame(width: 80)
                            }
                            .buttonStyle(.bouncy)
                            .accessibilityLabel("Play \(song.title)")
                            .staggeredAppear(index: index)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                }
            }
        } else if !viewModel.isLoading && viewModel.error == nil && !viewModel.playlists.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Text("Recently Played")
                    .font(Theme.Typography.title3.weight(.bold))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .padding(.horizontal, Theme.Spacing.lg)

                Text("Start listening to see your history here")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .padding(.horizontal, Theme.Spacing.lg)
            }
        }
    }

    // MARK: - Playlists

    @ViewBuilder
    private var playlistsSection: some View {
        let cachedPlaylists = filteredPlaylists
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // Section header
            if editMode == .active {
                HStack {
                    Text("\(selectedPlaylists.count) selected")
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.Colors.textSecondary)
                    Spacer()
                    Button(
                        selectedPlaylists.count == cachedPlaylists.count
                            ? String(localized: "Deselect All") : String(localized: "Select All")
                    ) {
                        withAnimation(Theme.AnimationPresets.gentle) {
                            if selectedPlaylists.count == cachedPlaylists.count {
                                selectedPlaylists.removeAll()
                            } else {
                                selectedPlaylists = Set(cachedPlaylists.map(\.id))
                            }
                        }
                    }
                    .font(Theme.Typography.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.Colors.brandGradientStart)
                }
                .padding(.horizontal, Theme.Spacing.lg)
            } else {
                HStack {
                    Text("Playlists")
                        .font(Theme.Typography.title3.weight(.bold))
                        .foregroundStyle(Theme.Colors.textPrimary)
                    if !viewModel.playlists.isEmpty {
                        Text("\(viewModel.playlists.count)")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textTertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.Colors.surfaceCard)
                            .clipShape(Capsule())
                    }
                    Spacer()
                }
                .padding(.horizontal, Theme.Spacing.lg)
            }

            VStack(spacing: Theme.Spacing.xxs) {
                if editMode == .inactive {
                    // Create playlist button
                    Button {
                        viewModel.isCreatingPlaylist = true
                    } label: {
                        HStack(spacing: Theme.Spacing.md) {
                            ZStack {
                                Theme.Colors.surfaceCard
                                Image(systemName: "plus")
                                    .font(.title3)
                                    .foregroundStyle(Theme.Colors.textSecondary)
                            }
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.small))

                            Text("New Playlist")
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Colors.textPrimary)

                            Spacer()
                        }
                        .padding(.vertical, Theme.Spacing.xxs)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .accessibilityLabel("Create new playlist")

                    // Liked Songs row
                    NavigationLink(value: Route.likedSongs) {
                        HStack(spacing: Theme.Spacing.md) {
                            ZStack {
                                LinearGradient(
                                    colors: [
                                        Theme.Colors.brandGradientStart,
                                        Theme.Colors.brandGradientEnd,
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                Image(systemName: "heart.fill")
                                    .font(.title3)
                                    .foregroundStyle(.white)
                            }
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.small))

                            VStack(alignment: .leading, spacing: Theme.Spacing.xxxs) {
                                Text("Liked Songs")
                                    .font(Theme.Typography.body)
                                    .foregroundStyle(Theme.Colors.textPrimary)
                                Text("\(viewModel.favoritesCount) songs")
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Colors.textSecondary)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(Theme.Colors.textTertiary)
                        }
                        .padding(.vertical, Theme.Spacing.xxs)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Liked Songs, \(viewModel.favoritesCount) songs")

                    // Downloads row
                    if featureFlags.isDownloadEnabled {
                        NavigationLink(value: Route.downloads) {
                            HStack(spacing: Theme.Spacing.md) {
                                ZStack {
                                    Theme.Colors.success.opacity(0.15)
                                    Image(systemName: "arrow.down.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(Theme.Colors.success)
                                }
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.small))

                                VStack(alignment: .leading, spacing: Theme.Spacing.xxxs) {
                                    Text("Downloads")
                                        .font(Theme.Typography.body)
                                        .foregroundStyle(Theme.Colors.textPrimary)
                                    Text("\(downloadManager.downloadCount) songs")
                                        .font(Theme.Typography.caption)
                                        .foregroundStyle(Theme.Colors.textSecondary)
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(Theme.Colors.textTertiary)
                            }
                            .padding(.vertical, Theme.Spacing.xxs)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Downloads, \(downloadManager.downloadCount) songs")
                    }
                }

                if viewModel.isLoading {
                    ForEach(0..<4, id: \.self) { _ in
                        HStack(spacing: Theme.Spacing.md) {
                            ShimmerView()
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.small))
                            VStack(alignment: .leading, spacing: 4) {
                                ShimmerView()
                                    .frame(width: 120, height: 14)
                                ShimmerView()
                                    .frame(width: 80, height: 12)
                            }
                            Spacer()
                        }
                        .padding(.vertical, Theme.Spacing.xxs)
                        .padding(.horizontal, Theme.Spacing.lg)
                    }
                } else if viewModel.playlists.isEmpty && viewModel.error == nil {
                    EmptyStateView(
                        icon: "music.note.list",
                        title: "No Playlists Yet",
                        message: "Create your first playlist to organize your music",
                        actionLabel: "Create Playlist",
                        onAction: { viewModel.isCreatingPlaylist = true }
                    )
                } else if cachedPlaylists.isEmpty && !searchText.isEmpty {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        title: "No playlists match '\(searchText)'",
                        message: "Try a different search term"
                    )
                } else {
                    ForEach(cachedPlaylists) { playlist in
                        if editMode == .active {
                            Button { togglePlaylistSelection(playlist.id) } label: {
                                HStack(spacing: Theme.Spacing.md) {
                                    SelectionIndicator(
                                        isSelected: selectedPlaylists.contains(playlist.id))

                                    playlistRowContent(playlist: playlist)
                                }
                                .padding(.horizontal, Theme.Spacing.lg)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(selectedPlaylists.contains(playlist.id) ? "Deselect \(playlist.title)" : "Select \(playlist.title)")
                        } else {
                            NavigationLink(value: Route.playlist(playlistId: playlist.id)) {
                                playlistRowContent(playlist: playlist)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, Theme.Spacing.lg)
                            .contextMenu {
                                Button {
                                    viewModel.startRename(playlist: playlist)
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    viewModel.requestDelete(playlist: playlist)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func playlistRowContent(playlist: Playlist) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            AsyncThumbnail(
                url: playlist.thumbnailURL, size: 48, cornerRadius: Theme.CornerRadius.small)

            VStack(alignment: .leading, spacing: Theme.Spacing.xxxs) {
                Text(playlist.title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text("\(playlist.songs.count) songs")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
            }

            Spacer()

            if editMode == .inactive {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(playlist.title), \(playlist.songs.count) songs")
    }

    private func togglePlaylistSelection(_ id: String) {
        withAnimation(Theme.AnimationPresets.gentle) {
            if selectedPlaylists.contains(id) {
                selectedPlaylists.remove(id)
            } else {
                selectedPlaylists.insert(id)
            }
        }
    }

    // MARK: - Multi-Select Toolbar

    private var multiSelectToolbar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Button {
                    showBulkDeleteConfirmation = true
                } label: {
                    Label("Delete Playlists", systemImage: "trash")
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
}
