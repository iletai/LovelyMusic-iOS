import SwiftUI

struct SearchView: View {
    @Bindable var viewModel: SearchViewModel
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(FeatureFlagManager.self) private var featureFlags
    @Environment(DIContainer.self) private var container
    @FocusState private var isSearchFocused: Bool
    @State private var songForPlaylist: Song?

    init(viewModel: SearchViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if !viewModel.query.isEmpty {
                filterChips
            }

            if let errorMessage = viewModel.error {
                ErrorStateView(errorMessage) {
                    Task { viewModel.search() }
                }
            } else if viewModel.isSearching && !hasVisibleResults {
                shimmerLoading
            } else if viewModel.showSuggestions {
                suggestionsList
            } else if hasVisibleResults {
                searchResults
            } else if isSearchFocused && viewModel.query.isEmpty
                && (!viewModel.searchHistory.isEmpty || !viewModel.trendingSuggestions.isEmpty)
            {
                searchHistorySection
            } else if !viewModel.query.isEmpty {
                searchEmptyState
            } else {
                exploreSection
            }
        }
        .task {
            viewModel.loadExplore()
        }
        .background(Theme.Colors.backgroundPrimary)
        .navigationTitle("Search")
        .sheet(item: $songForPlaylist) { song in
            AddToPlaylistSheet(
                song: song,
                managePlaylistUseCase: container.managePlaylistUseCase
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
            .presentationBackground(Theme.Colors.backgroundPrimary)
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                PulseIcon(
                    .search,
                    size: Theme.SizeTokens.iconSmall,
                    color: Theme.Colors.textTertiary
                )
                .accessibilityHidden(true)

                TextField("Search songs, artists, albums...", text: $viewModel.query)
                    .focused($isSearchFocused)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .submitLabel(.search)
                    .accessibilityLabel("Search songs, artists, albums")
                    .onSubmit {
                        isSearchFocused = false
                        Task { viewModel.search() }
                    }

                if !viewModel.query.isEmpty {
                    Button {
                        viewModel.clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.Colors.textTertiary)
                            .frame(
                                width: Theme.SizeTokens.touchTarget,
                                height: Theme.SizeTokens.touchTarget
                            )
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.leading, Theme.Spacing.md)
            .padding(.trailing, viewModel.query.isEmpty ? Theme.Spacing.md : Theme.Spacing.xxs)
            .frame(minHeight: 52)
            .glass(cornerRadius: Theme.CornerRadius.large)

            if isSearchFocused {
                Button("Cancel") {
                    isSearchFocused = false
                    viewModel.clearSearch()
                }
                .font(Theme.Typography.subheadline)
                .foregroundStyle(Theme.Colors.textSecondary)
                .frame(
                    minWidth: Theme.SizeTokens.touchTarget,
                    minHeight: Theme.SizeTokens.touchTarget
                )
                .contentShape(Rectangle())
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .animation(.easeInOut(duration: 0.25), value: isSearchFocused)
    }

    // MARK: - Explore (Idle State)

    private var exploreSection: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                if viewModel.isLoadingExplore {
                    exploreShimmer
                } else {
                    quickSearchChips

                    if !viewModel.moodAndGenres.isEmpty {
                        moodAndGenresGrid
                    }

                    ForEach(Array(viewModel.exploreSections.enumerated()), id: \.element.id) {
                        index, section in
                        exploreSectionView(section, index: index)
                    }
                }
            }
            .padding(.top, Theme.Spacing.md)
        }
        .dockHidingOnScroll()
        .dockSafeBottom()
        .scrollDismissesKeyboard(.interactively)
    }

    private var quickSearchChips: some View {
        let chips: [(searchTerm: String, displayKey: String.LocalizationValue, icon: String)] = [
            ("Top Charts", "Top Charts", "chart.line.uptrend.xyaxis"),
            ("New Releases", "New Releases", "sparkles"),
            ("Podcasts", "Podcasts", "mic.fill"),
            ("Live", "Live", "antenna.radiowaves.left.and.right"),
        ]

        return VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Quick Search")
                .font(Theme.Typography.title3)
                .foregroundStyle(Theme.Colors.textPrimary)
                .padding(.horizontal, Theme.Spacing.lg)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.sm) {
                    ForEach(chips, id: \.searchTerm) { chip in
                        Button {
                            isSearchFocused = false
                            viewModel.resetFilterToDefault()
                            viewModel.query = chip.searchTerm
                            Task { viewModel.search() }
                        } label: {
                            Label(String(localized: chip.displayKey), systemImage: chip.icon)
                                .font(Theme.Typography.subheadline)
                                .fontWeight(.medium)
                                .foregroundStyle(Theme.Colors.textPrimary)
                                .padding(.horizontal, Theme.Spacing.lg)
                                .padding(.vertical, Theme.Spacing.sm)
                                .frame(minHeight: Theme.SizeTokens.touchTarget)
                                .background(Theme.Colors.surfaceCard, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Search \(String(localized: chip.displayKey))")
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
            }
        }
        .staggeredAppear(index: 0)
    }

    private var moodAndGenresGrid: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Moods & Genres")
                .font(Theme.Typography.title3)
                .foregroundStyle(Theme.Colors.textPrimary)
                .padding(.horizontal, Theme.Spacing.lg)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHGrid(
                    rows: [GridItem(.fixed(44)), GridItem(.fixed(44))],
                    spacing: Theme.Spacing.sm
                ) {
                    ForEach(Array(viewModel.moodAndGenres.enumerated()), id: \.element.id) {
                        index, mood in
                        NavigationLink(
                            value: Route.playlist(playlistId: mood.browseEndpoint.browseId)
                        ) {
                            Text(mood.title)
                                .font(Theme.Typography.subheadline)
                                .fontWeight(.medium)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .padding(.horizontal, Theme.Spacing.lg)
                                .padding(.vertical, Theme.Spacing.sm)
                                .background {
                                    if let color = mood.color.map({ Color(argb: $0) }) {
                                        color.overlay(Color.black.opacity(0.15))
                                    } else {
                                        Theme.Colors.surfaceCard
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.small))
                        }
                        .frame(width: 170)
                        .accessibilityLabel("Browse \(mood.title)")
                        .staggeredAppear(index: index)
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
            }
            .frame(height: 100)
        }
        .staggeredAppear(index: 1)
    }

    @ViewBuilder
    private func exploreSectionView(_ section: MusicSection, index: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text(section.title)
                .font(Theme.Typography.title3)
                .foregroundStyle(Theme.Colors.textPrimary)
                .padding(.horizontal, Theme.Spacing.lg)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Theme.Spacing.md) {
                    ForEach(section.items) { item in
                        exploreItemView(item)
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
            }
        }
        .staggeredAppear(index: index + 2)
    }

    @ViewBuilder
    private func exploreItemView(_ item: MusicSectionItem) -> some View {
        switch item {
        case .song(let song):
            Button {
                playerVM.play(song: song, fromQueue: [song])
            } label: {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    AsyncThumbnail(url: song.thumbnailURL, size: 150)

                    Text(song.title)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .lineLimit(2)

                    Text(song.artistName)
                        .font(Theme.Typography.caption2)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .lineLimit(1)
                }
                .frame(width: 150)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play \(song.title) by \(song.artistName)")

        case .album(let album):
            NavigationLink(value: Route.album(browseId: album.id)) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    AsyncThumbnail(url: album.thumbnailURL, size: 150)

                    Text(album.title)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .lineLimit(2)

                    Text(album.artistName)
                        .font(Theme.Typography.caption2)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .lineLimit(1)
                }
                .frame(width: 150)
            }

        case .artist(let artist):
            NavigationLink(value: Route.artist(browseId: artist.id)) {
                VStack(spacing: Theme.Spacing.xs) {
                    AsyncThumbnail(url: artist.thumbnailURL, size: 110, cornerRadius: 55)

                    Text(artist.name)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .lineLimit(1)
                }
                .frame(width: 110)
            }

        case .playlist(let playlist):
            NavigationLink(value: Route.playlist(playlistId: playlist.id)) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    AsyncThumbnail(url: playlist.thumbnailURL, size: 150)

                    Text(playlist.title)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .lineLimit(2)

                    if let description = playlist.description {
                        Text(description)
                            .font(Theme.Typography.caption2)
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(width: 150)
            }

        case .audiobook(let audiobook):
            AudiobookTile(audiobook: audiobook)

        case .userChannel(let channel):
            UserChannelTile(channel: channel)
        }
    }

    private var exploreShimmer: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.sm) {
                    ForEach(0..<4, id: \.self) { _ in
                        ShimmerView()
                            .frame(width: 120, height: 36)
                            .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                ShimmerView().frame(width: 140, height: 20).padding(.horizontal, Theme.Spacing.lg)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.sm) {
                        ForEach(0..<6, id: \.self) { _ in
                            ShimmerView()
                                .frame(width: 170, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.small))
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                }
            }

            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    ShimmerView().frame(width: 160, height: 20).padding(
                        .horizontal, Theme.Spacing.lg)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Theme.Spacing.md) {
                            ForEach(0..<4, id: \.self) { _ in
                                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                                    ShimmerView()
                                        .frame(width: 150, height: 150)
                                        .clipShape(
                                            RoundedRectangle(cornerRadius: Theme.CornerRadius.small)
                                        )
                                    ShimmerView().frame(width: 120, height: 14)
                                    ShimmerView().frame(width: 80, height: 12)
                                }
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.lg)
                    }
                }
            }
        }
    }

    // MARK: - Filter Chips

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(SearchFilter.allCases, id: \.self) { filter in
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            viewModel.selectFilter(
                                viewModel.selectedFilter == filter ? nil : filter
                            )
                        }
                        Task { viewModel.search() }
                    } label: {
                        Text(filter.displayName)
                            .font(Theme.Typography.subheadline)
                            .padding(.horizontal, Theme.Spacing.lg)
                            .padding(.vertical, Theme.Spacing.sm)
                            .frame(minHeight: Theme.SizeTokens.touchTarget)
                            .background(
                                viewModel.selectedFilter == filter
                                    ? AnyShapeStyle(Theme.Colors.brandGradient)
                                    : AnyShapeStyle(Theme.Colors.surfaceCard)
                            )
                            .foregroundStyle(
                                viewModel.selectedFilter == filter
                                    ? .white : Theme.Colors.textSecondary
                            )
                            .clipShape(Capsule())
                    }
                    .accessibilityLabel("\(filter.displayName) filter")
                    .accessibilityAddTraits(viewModel.selectedFilter == filter ? .isSelected : [])
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
        .padding(.bottom, Theme.Spacing.sm)
    }

    // MARK: - Search History

    private var searchHistorySection: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                // Search History
                if !viewModel.searchHistory.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        HStack {
                            Text("Recent Searches")
                                .font(Theme.Typography.headline)
                                .foregroundStyle(Theme.Colors.textPrimary)
                            Spacer()
                            Button("Clear") {
                                withAnimation(Theme.AnimationPresets.gentle) {
                                    viewModel.clearHistory()
                                }
                            }
                            .font(Theme.Typography.subheadline)
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .accessibilityLabel("Clear search history")
                        }
                        .padding(.horizontal, Theme.Spacing.lg)

                        ForEach(viewModel.searchHistory, id: \.self) { term in
                            Button {
                                isSearchFocused = false
                                viewModel.query = term
                                Task { viewModel.search() }
                            } label: {
                                HStack(spacing: Theme.Spacing.sm) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .font(.caption2)
                                        .foregroundStyle(Theme.Colors.textTertiary)
                                    Text(term)
                                        .font(Theme.Typography.body)
                                        .foregroundStyle(Theme.Colors.textPrimary)
                                    Spacer()
                                    Image(systemName: "arrow.up.left")
                                        .font(.caption)
                                        .foregroundStyle(Theme.Colors.textTertiary)
                                }
                                .padding(.vertical, Theme.Spacing.xxs)
                                .frame(minHeight: 44)
                                .padding(.horizontal, Theme.Spacing.lg)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Search for \(term)")
                            .overlay(alignment: .trailing) {
                                Button {
                                    withAnimation {
                                        viewModel.deleteFromHistory(term)
                                    }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.caption2)
                                        .foregroundStyle(Theme.Colors.textTertiary)
                                        .padding(Theme.Spacing.sm)
                                }
                                .accessibilityLabel("Remove \(term) from history")
                                .padding(.trailing, Theme.Spacing.lg)
                            }
                        }
                    }
                }

                // Trending Searches
                if !viewModel.trendingSuggestions.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        HStack(spacing: Theme.Spacing.sm) {
                            Image(systemName: "arrow.trend.up")
                                .font(.caption)
                                .foregroundStyle(Theme.Colors.textTertiary)
                            Text("Trending")
                                .font(Theme.Typography.headline)
                                .foregroundStyle(Theme.Colors.textPrimary)
                        }
                        .padding(.horizontal, Theme.Spacing.lg)

                        FlowLayout(spacing: Theme.Spacing.sm) {
                            ForEach(viewModel.trendingSuggestions, id: \.self) { term in
                                Button {
                                    isSearchFocused = false
                                    viewModel.query = term
                                    Task { viewModel.search() }
                                } label: {
                                    Text(term)
                                        .font(Theme.Typography.subheadline)
                                        .foregroundStyle(Theme.Colors.textPrimary)
                                        .padding(.horizontal, Theme.Spacing.lg)
                                        .padding(.vertical, Theme.Spacing.sm)
                                        .background(Theme.Colors.surfaceCard, in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Search trending: \(term)")
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.lg)
                    }
                } else if viewModel.isLoadingTrending {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        ShimmerView().frame(width: 100, height: 20).padding(
                            .horizontal, Theme.Spacing.lg)
                        HStack(spacing: Theme.Spacing.sm) {
                            ForEach(0..<4, id: \.self) { _ in
                                ShimmerView()
                                    .frame(width: 90, height: 32)
                                    .clipShape(Capsule())
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.lg)
                    }
                }
            }
            .padding(.top, Theme.Spacing.md)
        }
        .dockSafeBottom()
        .scrollDismissesKeyboard(.interactively)
        .frame(maxHeight: .infinity, alignment: .top)
        .task {
            viewModel.loadTrending()
        }
    }

    // MARK: - Suggestions

    private var suggestionsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(viewModel.suggestions, id: \.self) { suggestion in
                    Button {
                        isSearchFocused = false
                        viewModel.selectSuggestion(suggestion)
                    } label: {
                        HStack(spacing: Theme.Spacing.md) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(Theme.Colors.textTertiary)
                            Text(suggestion)
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Colors.textPrimary)
                            Spacer()
                            Image(systemName: "arrow.up.left")
                                .foregroundStyle(Theme.Colors.textTertiary)
                                .font(.caption)
                        }
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.vertical, Theme.Spacing.md)
                        // Ensure minimum 44pt tap target height
                        .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .dockSafeBottom()
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Shimmer Loading

    private var shimmerLoading: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Spacing.md) {
                ForEach(0..<6, id: \.self) { _ in
                    HStack(spacing: Theme.Spacing.md) {
                        ShimmerView()
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.small))
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            ShimmerView()
                                .frame(width: 150, height: 14)
                            ShimmerView()
                                .frame(width: 100, height: 12)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                }
            }
            .padding(.top, Theme.Spacing.md)
        }
        .dockSafeBottom()
        .allowsHitTesting(false)
    }

    // MARK: - Search Results

    /// Songs filtered to exclude permanently unavailable, episodes, and invalid items.
    private var playableSongs: [Song] {
        viewModel.results.songs.filter { song in
            song.hasYouTubeOrigin
                && !song.isEpisode
                && (song.duration ?? 0) > 0
                && !playerVM.unavailableSongIds.contains(song.id)
        }
    }

    /// True when at least one result section has visible content after filtering.
    private var hasVisibleResults: Bool {
        !playableSongs.isEmpty
            || !viewModel.results.albums.isEmpty
            || !viewModel.results.artists.isEmpty
            || !viewModel.results.playlists.isEmpty
    }

    // MARK: - Context-Aware Empty State

    @ViewBuilder
    private var searchEmptyState: some View {
        if let filter = viewModel.selectedFilter, !viewModel.hasResults {
            // Filter active but that category returned nothing from API
            EmptyStateView(
                icon: filterIcon(for: filter),
                title: "No \(filter.displayName) found",
                message: "Try removing the filter or search for something else",
                actionLabel: "Clear filter",
                onAction: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        viewModel.selectFilter(nil)
                    }
                    Task { viewModel.search() }
                }
            )
        } else if !viewModel.results.songs.isEmpty && playableSongs.isEmpty
            && viewModel.results.albums.isEmpty && viewModel.results.artists.isEmpty
            && viewModel.results.playlists.isEmpty
        {
            // API returned songs but all are unavailable
            EmptyStateView(
                icon: "music.note.slash",
                title: "Songs unavailable",
                message: "All results for this search are currently unavailable in your region"
            )
        } else {
            // Generic no results
            EmptyStateView(
                icon: "magnifyingglass",
                title: "No results for '\(viewModel.query)'",
                message: "Try different keywords or check spelling"
            )
        }
    }

    private func filterIcon(for filter: SearchFilter) -> String {
        switch filter {
        case .songs: return "music.note"
        case .albums: return "square.stack"
        case .artists: return "person.2"
        case .playlists: return "music.note.list"
        }
    }

    private var searchResults: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                // Songs
                if !playableSongs.isEmpty {
                    Section {
                        ForEach(Array(playableSongs.enumerated()), id: \.element.id) {
                            index, song in
                            SongRowView(
                                song: song,
                                isPlaying: playerVM.currentSong?.id == song.id,
                                downloadState: featureFlags.isDownloadEnabled
                                    ? downloadManager.downloadState(for: song.id) : nil,
                                onTap: {
                                    playerVM.play(song: song, fromQueue: playableSongs)
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
                                shareMessage: "\u{1F3B5} \(song.title) - \(song.artistName)",
                                onGoToArtist: song.artistId.map { artistId in
                                    {
                                        NotificationCenter.default.post(
                                            name: .navigateToArtist,
                                            object: nil,
                                            userInfo: ["browseId": artistId]
                                        )
                                    }
                                },
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
                            .id(song.id)
                        }
                    } header: {
                        resultSectionHeader("Songs", icon: "music.note")
                    }
                }

                // Inline ad between songs and albums
                InlineFeedAdView()

                // Albums
                if !viewModel.results.albums.isEmpty {
                    Section {
                        ForEach(Array(viewModel.results.albums.enumerated()), id: \.element.id) {
                            index, album in
                            NavigationLink(value: Route.album(browseId: album.id)) {
                                albumRow(album)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                NavigationLink(value: Route.album(browseId: album.id)) {
                                    Label("View Album", systemImage: "square.stack")
                                }
                                if let artistId = album.artistId {
                                    NavigationLink(value: Route.artist(browseId: artistId)) {
                                        Label("Go to Artist", systemImage: "person.fill")
                                    }
                                }
                                ShareLink(
                                    item: "\(album.title) — \(album.artistName)",
                                    subject: Text(album.title)
                                ) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                            }
                            .padding(.horizontal, Theme.Spacing.lg)
                            .staggeredAppear(index: index)
                            .id(album.id)
                        }
                    } header: {
                        resultSectionHeader("Albums", icon: "square.stack")
                    }
                }

                // Artists
                if !viewModel.results.artists.isEmpty {
                    Section {
                        ForEach(Array(viewModel.results.artists.enumerated()), id: \.element.id) {
                            index, artist in
                            NavigationLink(value: Route.artist(browseId: artist.id)) {
                                artistRow(artist)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                NavigationLink(value: Route.artist(browseId: artist.id)) {
                                    Label("View Artist", systemImage: "person.fill")
                                }
                                ShareLink(
                                    item: artist.name,
                                    subject: Text(artist.name)
                                ) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                            }
                            .padding(.horizontal, Theme.Spacing.lg)
                            .staggeredAppear(index: index)
                            .id(artist.id)
                        }
                    } header: {
                        resultSectionHeader("Artists", icon: "person.2")
                    }
                }

                // Playlists
                if !viewModel.results.playlists.isEmpty {
                    Section {
                        ForEach(Array(viewModel.results.playlists.enumerated()), id: \.element.id) {
                            index, playlist in
                            NavigationLink(value: Route.playlist(playlistId: playlist.id)) {
                                playlistRow(playlist)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                NavigationLink(value: Route.playlist(playlistId: playlist.id)) {
                                    Label("View Playlist", systemImage: "music.note.list")
                                }
                                ShareLink(
                                    item: playlist.title,
                                    subject: Text(playlist.title)
                                ) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                            }
                            .padding(.horizontal, Theme.Spacing.lg)
                            .staggeredAppear(index: index)
                            .id(playlist.id)
                        }
                    } header: {
                        resultSectionHeader("Playlists", icon: "music.note.list")
                    }
                }

                // Pagination
                if let paginationError = viewModel.paginationError {
                    VStack(spacing: Theme.Spacing.sm) {
                        VStack(spacing: Theme.Spacing.xxs) {
                            Text("Couldn't load more results")
                                .font(Theme.Typography.subheadline)
                                .foregroundStyle(Theme.Colors.textSecondary)
                            Text(paginationError)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.textTertiary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                        }
                        .accessibilityElement(children: .combine)

                        Button("Retry") {
                            viewModel.loadMore()
                        }
                        .font(Theme.Typography.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.Colors.primary)
                        .frame(
                            minWidth: Theme.SizeTokens.touchTarget,
                            minHeight: Theme.SizeTokens.touchTarget
                        )
                        .contentShape(Rectangle())
                        .accessibilityLabel("Retry loading more results")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.md)
                } else if let continuation = viewModel.results.continuation {
                    ProgressView()
                        .tint(Theme.Colors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .accessibilityLabel("Loading more results")
                        .task(id: continuation) {
                            viewModel.loadMore()
                        }
                }
            }
        }
        .id(viewModel.resultRevision)
        .dockHidingOnScroll()
        .dockSafeBottom()
        .scrollDismissesKeyboard(.interactively)
        .refreshable {
            viewModel.search()
        }
    }

    // MARK: - Result Row Components

    private func resultSectionHeader(_ title: LocalizedStringKey, icon: String) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(Theme.Colors.textTertiary)
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textTertiary)
                .textCase(.uppercase)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.top, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.xs)
        .background(Theme.Colors.backgroundPrimary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(.isHeader)
    }

    private func albumRow(_ album: Album) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            AsyncThumbnail(
                url: album.thumbnailURL, size: 56, cornerRadius: Theme.CornerRadius.small)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)
                Text(album.artistName)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1)
                if let year = album.year {
                    Text(year)
                        .font(Theme.Typography.caption2)
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Theme.Colors.textTertiary)
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(album.title) by \(album.artistName)")
    }

    private func artistRow(_ artist: Artist) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            AsyncThumbnail(url: artist.thumbnailURL, size: 56, cornerRadius: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(artist.name)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)
                if let subscribers = artist.subscriberCount {
                    Text(subscribers)
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
        .padding(.vertical, Theme.Spacing.xxs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Artist: \(artist.name)")
    }

    private func playlistRow(_ playlist: Playlist) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            AsyncThumbnail(
                url: playlist.thumbnailURL, size: 56, cornerRadius: Theme.CornerRadius.small)

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)
                if let count = playlist.songCount {
                    Text("\(count) songs")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Theme.Colors.textTertiary)
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Playlist: \(playlist.title)")
    }
}

// MARK: - Flow Layout for History Chips

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let result = arrangeSubviews(
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height),
            subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified)
        }
    }

    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (
        size: CGSize, positions: [CGPoint]
    ) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), positions)
    }
}
