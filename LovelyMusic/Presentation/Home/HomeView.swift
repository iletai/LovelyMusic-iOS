import SwiftUI

struct HomeView: View {
    let viewModel: HomeViewModel
    @State private var settingsIconTapped = 0
    /// Drives a once-per-minute re-evaluation of `lastUpdatedLabel` so the
    /// "Updated …" subtitle stays accurate without re-rendering the rest of
    /// the feed (polish-B5).
    @State private var minuteTick: Int = 0
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(PremiumManager.self) private var premiumManager
    @Environment(FeatureFlagManager.self) private var featureFlags
    @Environment(ThemeManager.self) private var themeManager
    @Environment(\.colorScheme) private var colorScheme
    /// Pause the freshness timer when Home is not the visible tab. ContentView
    /// keeps Home mounted (opacity-based tab switch) so `.onAppear` /
    /// `.onDisappear` will not fire on tab changes — `isTabActive` is the
    /// authoritative signal.
    @Environment(\.isTabActive) private var isTabActive
    @Environment(\.scenePhase) private var scenePhase
    @State private var showPaywall = false
    @State private var homeScrollPosition = ScrollPosition(idType: String.self)
    @Namespace private var chipNamespace

    init(viewModel: HomeViewModel) {
        self.viewModel = viewModel
    }

    private var greetingText: LocalizedStringKey {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good Morning"
        case 12..<17: return "Good Afternoon"
        case 17..<22: return "Good Evening"
        default: return "Good Night"
        }
    }

    /// Localised "Updated just now" / "Updated 5 min ago" subtitle.
    /// Re-evaluated every minute via `minuteTick` (polish-B5).
    private var lastUpdatedLabel: String? {
        guard let date = viewModel.lastSuccessfulRefreshAt else { return nil }
        // Touch tick so the computed property invalidates with the timer.
        _ = minuteTick
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return String(localized: "Updated just now")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .numeric
        let relative = formatter.localizedString(for: date, relativeTo: Date())
        return String(localized: "Updated \(relative)")
    }

    var body: some View {
        // MARK: SafeArea — inherits dock inset from ContentView (no per-view padding required).
        ScrollView {
            // Round 2: top-level section gap promoted to xxl (32pt) for shelf rhythm.
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
                if viewModel.isLoading && viewModel.sections.isEmpty {
                    ForEach(0..<3, id: \.self) { _ in
                        sectionPlaceholder
                    }
                } else if let error = viewModel.error, viewModel.sections.isEmpty {
                    ErrorStateView(error) {
                        Task { viewModel.refresh() }
                    }
                } else {
                    // Soft banner for prolonged InnerTube degraded state (polish-B2 #4).
                    if let notice = viewModel.degradationNotice {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "wifi.exclamationmark")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Text(notice)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.textSecondary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.sm)
                        .background(.orange.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.small))
                        .padding(.horizontal, Theme.Spacing.lg)
                        .accessibilityElement(children: .combine)
                    }

                    // Seasonal Hero Banner (from CMS & Theme)
                    if themeManager.isSeasonalThemeActive {
                        SeasonalBannerView(
                            config: themeManager.effectiveSeasonalTheme,
                            preset: themeManager.activeSeasonalPreset
                        )
                    }

                    // In-App Announcement Banner from CMS
                    announcementBannerView

                    // Filter chips
                    chipCloudView

                    // Editorial / Featured Playlists from CMS
                    editorialSectionView

                    // polish-B5: subtle freshness subtitle near the chip cloud.
                    if let updated = lastUpdatedLabel {
                        Text(updated)
                            .font(Theme.Typography.caption2)
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .padding(.horizontal, Theme.Spacing.lg)
                            .accessibilityLabel(updated)
                    }

                    // Premium chip for free users — brand purple in Round 2 (gold is paywall-only).
                    if !premiumManager.isPremium {
                        Button {
                            showPaywall = true
                        } label: {
                            HStack(spacing: Theme.Spacing.xxs) {
                                Image(systemName: "crown.fill")
                                    .font(Theme.Typography.caption3)
                                    .symbolEffect(.breathe, isActive: true)
                                Text("Go Premium")
                                    .font(Theme.Typography.caption)
                                    .fontWeight(.semibold)
                            }
                            .foregroundStyle(Theme.Colors.brandGradientStart)
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, Theme.Spacing.xs)
                            .background(
                                Capsule()
                                    .fill(Theme.Colors.brandGradientStart.opacity(0.10))
                                    .overlay(
                                        Capsule()
                                            .stroke(
                                                Theme.Colors.brandGradientStart.opacity(0.30),
                                                lineWidth: 1
                                            )
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .accessibilityIdentifier("go_premium")
                        .fullScreenCover(isPresented: $showPaywall) {
                            PaywallView()
                        }
                    }

                    // Quick-Play Grid (Spotify-style 2×3 recently played)
                    if viewModel.recentlyPlayed.count >= 4 {
                        quickPlayGrid
                    }

                    // Continue Listening — compact card, only when not currently playing
                    if !viewModel.recentlyPlayed.isEmpty
                        && !viewModel.continueListeningDismissed
                        && playerVM.currentSong == nil
                    {
                        continueListeningSection
                    }

                    // Mood & Genre chips
                    // Hidden during chip filter: chip filter responses do not
                    // refresh moods, and the select-path in `HomeViewModel`
                    // intentionally leaves `moodAndGenres` untouched. Guarding
                    // by `selectedChipId == nil` keeps the visible state
                    // consistent with the data-model contract.
                    if !viewModel.moodAndGenres.isEmpty, viewModel.selectedChipId == nil {
                        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                            Text("Moods & Genres")
                                .font(Theme.Typography.title3)
                                .fontWeight(.semibold)
                                .tracking(0.3)
                                .foregroundStyle(Theme.Colors.textPrimary)
                                .padding(.horizontal, Theme.Spacing.lg)

                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHGrid(
                                    rows: [
                                        GridItem(.fixed(featureFlags.homeMoodGridRowHeight)),
                                        GridItem(.fixed(featureFlags.homeMoodGridRowHeight)),
                                    ],
                                    spacing: Theme.Spacing.md
                                ) {
                                    ForEach(
                                        Array(viewModel.moodAndGenres.enumerated()),
                                        id: \.element.id
                                    ) { index, mood in
                                        NavigationLink(
                                            value: Route.playlist(
                                                playlistId: mood.browseEndpoint.browseId
                                            )
                                        ) {
                                            moodChipLabel(mood)
                                        }
                                        .buttonStyle(.chipPress)
                                        .frame(width: featureFlags.homeMoodItemWidth)
                                        .accessibilityLabel("Browse \(mood.title)")
                                        .chipAppear(index: index)
                                    }
                                }
                                .padding(.horizontal, Theme.Spacing.lg)
                            }
                            .frame(height: featureFlags.homeMoodCarouselHeight)
                        }
                    }

                    ForEach(Array(viewModel.sections.enumerated()), id: \.element.id) {
                        index, section in
                        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                            // Section header with modern tracking
                            HStack(alignment: .firstTextBaseline) {
                                Text(section.title)
                                    .font(Theme.Typography.title3)
                                    .fontWeight(.semibold)
                                    .tracking(0.3)
                                    .foregroundStyle(Theme.Colors.textPrimary)

                                Spacer()

                                if section.items.count > 4 {
                                    NavigationLink(value: Route.homeSection(section)) {
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 16, weight: .regular))
                                            .foregroundStyle(Theme.Colors.textSecondary)
                                            .frame(width: 44, height: 44)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("See all \(section.title)")
                                }
                            }
                            .padding(.horizontal, Theme.Spacing.lg)

                            if section.isSongSection {
                                songGridSection(section)
                            } else {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    LazyHStack(spacing: Theme.Spacing.md) {
                                        ForEach(section.items) { item in
                                            musicSectionItemView(item)
                                                .scrollTransition { content, phase in
                                                    content
                                                        .opacity(phase.isIdentity ? 1 : 0.3)
                                                        .scaleEffect(phase.isIdentity ? 1 : 0.95)
                                                }
                                        }
                                    }
                                    .padding(.horizontal, Theme.Spacing.lg)
                                }
                            }
                        }
                        // Rhythm variation: tighter between carousel sections, more air before pivots
                        .padding(.top, index == 0 ? 0 : (section.isSongSection ? Theme.Spacing.sm : Theme.Spacing.xs))

                        // Show inline ad after every N sections (CMS-configurable)
                        if (index + 1) % featureFlags.adsSectionInterval == 0 {
                            InlineFeedAdView()
                                .padding(.vertical, Theme.Spacing.sm)
                        }
                    }

                    if viewModel.hasMore {
                        if viewModel.isLoadingMore {
                            VStack(spacing: Theme.Spacing.sm) {
                                ForEach(0..<3, id: \.self) { _ in
                                    HStack(spacing: Theme.Spacing.md) {
                                        ShimmerView(width: 48, height: 48)
                                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                                            ShimmerView(height: 14)
                                            ShimmerView(width: 120, height: 12)
                                        }
                                    }
                                    .padding(.horizontal, Theme.Spacing.lg)
                                }
                            }
                            .padding(.vertical, Theme.Spacing.md)
                        } else {
                            Color.clear
                                .frame(height: 1)
                                .task {
                                    viewModel.loadMore()
                                }
                        }
                    }

                    if let _ = viewModel.loadMoreError {
                        HStack(spacing: Theme.Spacing.sm) {
                            Text("Failed to load more")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.textTertiary)
                            Button("Retry") {
                                viewModel.loadMore()
                            }
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.primary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                    }
                }
            }
            .padding(.vertical, Theme.Spacing.lg)
        }
        .scrollPosition($homeScrollPosition)
        .dockHidingOnScroll()
        .dockSafeBottom()
        .background {
            if let seasonalGradient = themeManager.seasonalBackgroundGradient(for: colorScheme) {
                seasonalGradient.ignoresSafeArea()
            } else {
                Theme.Colors.backgroundPrimary.ignoresSafeArea()
            }
        }
        .overlay {
            if themeManager.isSeasonalThemeActive && themeManager.effectiveSeasonalTheme.showAmbientParticles {
                SeasonalParticleView(
                    preset: themeManager.activeSeasonalPreset,
                    count: themeManager.effectiveSeasonalTheme.particleCount,
                    speedMultiplier: themeManager.effectiveSeasonalTheme.particleSpeedMultiplier,
                    durationSeconds: themeManager.effectiveSeasonalTheme.particleDurationSeconds
                )
            }
        }
        .refreshable {
            viewModel.refresh()
        }
        .task {
            viewModel.loadHome()
        }
        // polish-B5 + reviewer-codex M1: re-render the "Updated …" label every
        // minute, but only while Home is the active tab AND the app is in the
        // foreground. The `.task(id:)` is cancelled and restarted whenever
        // either condition changes, so the timer never ticks off-screen or in
        // background. On re-entry we bump `minuteTick` once immediately so the
        // relative timestamp recomputes without waiting up to 60s.
        .task(id: TimerGate(isTabActive: isTabActive, isAppActive: scenePhase == .active)) {
            guard isTabActive, scenePhase == .active else { return }
            themeManager.refreshCurrentSchedule()
            minuteTick &+= 1
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { return }
                minuteTick &+= 1
            }
        }
        .navigationTitle(greetingText)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: Route.settings) {
                    Image(systemName: "gearshape")
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .symbolEffect(.bounce, value: settingsIconTapped)
                }
                .accessibilityLabel("Settings")
                .simultaneousGesture(TapGesture().onEnded { settingsIconTapped += 1 })
            }
        }
    }

    // MARK: - In-App Announcement Banner (from CMS)

    @ViewBuilder
    private var announcementBannerView: some View {
        if let notice = featureFlags.activeAnnouncement {
            HStack(alignment: .center, spacing: Theme.Spacing.sm) {
                Image(systemName: notice.level == "warning" ? "exclamationmark.triangle.fill" : (notice.level == "critical" ? "exclamationmark.octagon.fill" : "info.circle.fill"))
                    .font(.subheadline)
                    .foregroundStyle(notice.level == "critical" ? .red : (notice.level == "warning" ? .orange : .blue))

                VStack(alignment: .leading, spacing: 2) {
                    Text(notice.message)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                if !notice.actionTitle.isEmpty, let url = URL(string: notice.actionURL) {
                    Link(destination: url) {
                        Text(notice.actionTitle)
                            .font(Theme.Typography.caption.weight(.bold))
                            .foregroundStyle(.blue)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background((notice.level == "critical" ? Color.red : (notice.level == "warning" ? Color.orange : Color.blue)).opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.medium))
            .padding(.horizontal, Theme.Spacing.lg)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Editorial / Featured Playlists (from CMS)

    @ViewBuilder
    private var editorialSectionView: some View {
        if featureFlags.isEditorialEnabled {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack {
                    Text("Editor's Picks")
                        .font(Theme.Typography.title2)
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Spacer()
                }
                .padding(.horizontal, Theme.Spacing.lg)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: Theme.Spacing.md) {
                        ForEach(featureFlags.editorial.featuredPlaylists) { item in
                            NavigationLink(value: Route.playlist(playlistId: item.playlistId)) {
                                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                                    ZStack(alignment: .topLeading) {
                                        RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                                            .fill(
                                                themeManager.seasonalCardGradient(for: colorScheme) ?? LinearGradient(
                                                    colors: [Theme.Colors.brandGradientStart.opacity(0.85), Theme.Colors.brandGradientEnd.opacity(0.65)],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                )
                                            )
                                            .frame(width: 200, height: 120)

                                        VStack(alignment: .leading) {
                                            if !item.badgeText.isEmpty {
                                                Text(item.badgeText)
                                                    .font(Theme.Typography.caption2.weight(.heavy))
                                                    .foregroundStyle(.white)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(Color.black.opacity(colorScheme == .dark ? 0.35 : 0.65))
                                                    .clipShape(Capsule())
                                            }
                                            Spacer()
                                            Image(systemName: themeManager.seasonalIcon ?? "music.note.list")
                                                .font(.title2)
                                                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.9) : Color.black.opacity(0.65))
                                        }
                                        .padding(Theme.Spacing.sm)
                                    }

                                    Text(item.title)
                                        .font(Theme.Typography.headline)
                                        .foregroundStyle(Theme.Colors.textPrimary)
                                        .lineLimit(1)

                                    if !item.subtitle.isEmpty {
                                        Text(item.subtitle)
                                            .font(Theme.Typography.caption2)
                                            .foregroundStyle(Theme.Colors.textSecondary)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(width: 200)
                            }
                            .buttonStyle(.tactileCard)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                }
            }
        }
    }

    // MARK: - Continue Listening (Compact Card)

    @ViewBuilder
    private var continueListeningSection: some View {
        if let lastSong = viewModel.recentlyPlayed.first {
            GlassmorphicCard {
                HStack(spacing: Theme.Spacing.md) {
                    // Thumbnail
                    AsyncThumbnail(
                        url: lastSong.thumbnailURL,
                        size: 48,
                        cornerRadius: Theme.CornerRadius.small
                    )

                    // Song info
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxxs) {
                        Text("Continue Listening")
                            .font(Theme.Typography.captionSecondary)
                            .foregroundStyle(Theme.Colors.textTertiary)
                        Text(lastSong.title)
                            .font(Theme.Typography.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(Theme.Colors.textPrimary)
                            .lineLimit(1)
                        Text(lastSong.artistName)
                            .font(Theme.Typography.captionSecondary)
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)

                    // Play button
                    Button {
                        playerVM.play(song: lastSong)
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Theme.Colors.brandGradient)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.bouncy)
                    .accessibilityLabel("Play \(lastSong.title)")

                    // Dismiss button
                    Button {
                        withAnimation(Theme.AnimationPresets.smooth) {
                            viewModel.dismissContinueListening()
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(Theme.Colors.textTertiary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss continue listening")
                }
                .padding(Theme.Spacing.md)
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .accessibilityIdentifier("continue_listening_card")
            .transition(
                .asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.95)),
                    removal: .opacity.combined(with: .move(edge: .top))
                ))
        }
    }

    // MARK: - Quick-Play Grid (Spotify-style 2×3)

    private let quickPlayColumns = [
        GridItem(.flexible(), spacing: Theme.Spacing.sm),
        GridItem(.flexible(), spacing: Theme.Spacing.sm)
    ]

    private var quickPlayGrid: some View {
        LazyVGrid(columns: quickPlayColumns, spacing: Theme.Spacing.sm) {
            ForEach(Array(viewModel.recentlyPlayed.prefix(6).enumerated()), id: \.element.id) { index, song in
                Button {
                    playerVM.play(song: song)
                } label: {
                    HStack(spacing: Theme.Spacing.sm) {
                        AsyncThumbnail(
                            url: song.thumbnailURL,
                            size: 44,
                            cornerRadius: Theme.CornerRadius.small
                        )

                        Text(song.title)
                            .font(Theme.Typography.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(Theme.Colors.textPrimary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 52)
                    .padding(.trailing, Theme.Spacing.sm)
                    .background(Theme.Colors.surfaceCard)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.small))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.CornerRadius.small)
                            .stroke(Theme.Colors.divider, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.bouncy)
                .staggeredAppear(index: index)
                .accessibilityLabel("\(song.title) by \(song.artistName)")
                .accessibilityHint("Double tap to play")
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
    }

    // MARK: - Chip Cloud

    @ViewBuilder
    private var chipCloudView: some View {
        if !viewModel.chips.isEmpty {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.md) {
                        ForEach(Array(viewModel.chips.enumerated()), id: \.element.id) {
                            index,
                            chip in
                            chipButton(chip)
                                .id(chip.id)
                                .chipAppear(index: index)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.xxs)
                }
                .onChange(of: viewModel.selectedChipId) { _, newId in
                    guard let newId else { return }
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) {
                        proxy.scrollTo(newId, anchor: .center)
                    }
                }
            }
        }
    }

    private func chipButton(_ chip: HomeChip) -> some View {
        let isSelected = chip.id == viewModel.selectedChipId
        return Button {
            Task {
                viewModel.selectChip(chip)
            }
        } label: {
            Text(chip.title)
                .font(Theme.Typography.subheadline.weight(.semibold))
                .tracking(0.2)
                .foregroundStyle(isSelected ? .white : Theme.Colors.textPrimary)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Theme.Colors.brandGradient)
                            .shadow(
                                color: Theme.Colors.brandGradientStart.opacity(0.35),
                                radius: 10,
                                y: 3
                            )
                            .matchedGeometryEffect(id: "chipSelector", in: chipNamespace)
                    } else {
                        Capsule()
                            .fill(Theme.Colors.surfaceCard)
                            .overlay(
                                Capsule()
                                    .strokeBorder(Theme.Colors.divider, lineWidth: 0.5)
                            )
                    }
                }
                .overlay {
                    if isSelected {
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.2), .clear],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                            .padding(1)
                            .allowsHitTesting(false)
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.72), value: isSelected)
        }
        .buttonStyle(.chipPress)
        .sensoryFeedback(.impact(weight: .light), trigger: isSelected)
        .accessibilityLabel("\(chip.title) filter")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func moodChipLabel(_ mood: MoodAndGenre) -> some View {
        let chipColor = mood.color.map { Color(argb: $0) }
        return Text(mood.title)
            .font(.system(.subheadline, weight: .semibold))
            .tracking(0.3)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .background {
                ZStack {
                    if let color = chipColor {
                        LinearGradient(
                            stops: [
                                .init(color: color, location: 0),
                                .init(color: color.opacity(0.65), location: 1),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    } else {
                        Theme.Colors.surfaceCard
                    }
                    LinearGradient(
                        colors: [.white.opacity(0.18), .clear, .black.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.medium))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
            )
    }

    // MARK: - Song Grid Section (Quick Picks style)

    private let songGridRowHeight: CGFloat = 56
    private let songGridItemWidth: CGFloat = 260

    private func songGridSection(_ section: MusicSection) -> some View {
        let songs = section.items.compactMap { item -> Song? in
            if case .song(let song) = item { return song }
            return nil
        }
        let rowCount = min(4, songs.count)
        let rows = Array(
            repeating: GridItem(.fixed(songGridRowHeight), spacing: Theme.Spacing.sm),
            count: rowCount
        )

        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(rows: rows, spacing: Theme.Spacing.md) {
                ForEach(songs) { song in
                    songGridItem(song)
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
        }
    }

    private func songGridItem(_ song: Song) -> some View {
        Button {
            playerVM.play(song: song)
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                AsyncThumbnail(
                    url: song.thumbnailURL,
                    size: 48,
                    cornerRadius: Theme.CornerRadius.small
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(Theme.Typography.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .lineLimit(1)
                    Text(song.artistName)
                        .font(Theme.Typography.captionSecondary)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .frame(width: songGridItemWidth)
            .padding(.vertical, Theme.Spacing.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(song.title) by \(song.artistName)")
        .accessibilityHint("Double tap to play")
    }

    @ViewBuilder
    private func musicSectionItemView(_ item: MusicSectionItem) -> some View {
        switch item {
        case .song(let song):
            Button {
                playerVM.play(song: song)
            } label: {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    AsyncThumbnail(
                        url: song.thumbnailURL,
                        size: 150,
                        cornerRadius: Theme.CornerRadius.medium
                    )
                    Text(song.title)
                        .font(Theme.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .lineLimit(2)
                    Text(song.artistName)
                        .font(Theme.Typography.captionSecondary)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .lineLimit(1)
                }
                .frame(width: 150)
            }
            .buttonStyle(.bouncy)
            .accessibilityLabel("\(song.title) by \(song.artistName)")

        case .album(let album):
            NavigationLink(value: Route.album(browseId: album.id)) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    AsyncThumbnail(
                        url: album.thumbnailURL,
                        size: 150,
                        cornerRadius: Theme.CornerRadius.medium
                    )
                    Text(album.title)
                        .font(Theme.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .lineLimit(2)
                    Text(album.artistName)
                        .font(Theme.Typography.captionSecondary)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .lineLimit(1)
                }
                .frame(width: 150)
            }
            .buttonStyle(.bouncy)
            .accessibilityLabel("Album: \(album.title) by \(album.artistName)")

        case .artist(let artist):
            NavigationLink(value: Route.artist(browseId: artist.id)) {
                VStack(spacing: Theme.Spacing.xs) {
                    AsyncThumbnail(
                        url: artist.thumbnailURL,
                        size: 100,
                        cornerRadius: Theme.CornerRadius.full
                    )
                    .overlay(
                        Circle()
                            .stroke(Theme.Colors.divider, lineWidth: 0.5)
                    )
                    Text(artist.name)
                        .font(Theme.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .lineLimit(1)
                }
                .frame(width: 100)
            }
            .buttonStyle(.bouncy)
            .accessibilityLabel("Artist: \(artist.name)")

        case .playlist(let playlist):
            NavigationLink(value: Route.playlist(playlistId: playlist.id)) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    AsyncThumbnail(
                        url: playlist.thumbnailURL,
                        size: 150,
                        cornerRadius: Theme.CornerRadius.medium
                    )
                    Text(playlist.title)
                        .font(Theme.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .lineLimit(2)
                }
                .frame(width: 150)
            }
            .buttonStyle(.bouncy)
            .accessibilityLabel("Playlist: \(playlist.title)")

        case .audiobook(let audiobook):
            AudiobookTile(audiobook: audiobook)
                .accessibilityLabel("Audiobook: \(audiobook.title)")

        case .userChannel(let channel):
            UserChannelTile(channel: channel)
                .accessibilityLabel("Channel: \(channel.name)")
        }
    }

    private var sectionPlaceholder: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            ShimmerView(width: 120, height: 20)
                .padding(.horizontal, Theme.Spacing.lg)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.md) {
                    ForEach(0..<4, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            ShimmerView(
                                width: 150,
                                height: 150,
                                cornerRadius: Theme.CornerRadius.medium
                            )
                            ShimmerView(width: 110, height: 12)
                            ShimmerView(width: 80, height: 10)
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.lg)
            }
        }
    }
}

/// Identity for the freshness-label tick `.task(id:)`. Restarts the timer
/// whenever either signal changes; equality drives SwiftUI's task lifecycle.
private struct TimerGate: Equatable {
    let isTabActive: Bool
    let isAppActive: Bool
}
