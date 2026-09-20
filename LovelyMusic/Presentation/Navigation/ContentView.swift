import SwiftUI

struct ContentView: View {
    @State private var selectedTab: AppTab = .home
    @State private var homePath = NavigationPath()
    @State private var searchPath = NavigationPath()
    @State private var libraryPath = NavigationPath()
    @State private var loadedTabs: Set<AppTab> = [.home]
    @AppStorage("dismissed_soft_update_version") private var dismissedSoftUpdateVersion: String = ""
    @Environment(DIContainer.self) private var container
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(ThemeManager.self) private var themeManager
    @Environment(FeatureFlagManager.self) private var featureFlagManager
    @Environment(ScrollDirectionTracker.self) private var scrollTracker

    // Layout constants — extracted from inline magic numbers
    private let dockHeightWithPlayer: CGFloat = 120
    private let dockHeightWithoutPlayer: CGFloat = 72
    private let dockHideOffset: CGFloat = 200

    /// Dock is hidden when: edit mode forces it OR user scrolled down
    private var dockHidden: Bool {
        playerVM.isDockHidden || scrollTracker.isScrollingDown
    }

    /// Single source of truth for the bottom safe-area inset reserved by
    /// `ContentView` (dock + ad-banner). Returns 0 when the dock is hidden so
    /// the inset collapses smoothly. Driving `.safeAreaInset` from one
    /// computed value couples dock auto-hide and ad-banner load into a single
    /// animated transition (polish-A5) and avoids one-frame layout clips.
    private var bottomInsetValue: CGFloat {
        guard !dockHidden else { return 0 }
        let adHeight: CGFloat = container.adManager.shouldShowAds ? 50 : 0
        let dockHeight: CGFloat =
            playerVM.currentSong != nil ? dockHeightWithPlayer : dockHeightWithoutPlayer
        return dockHeight + adHeight
    }

    /// Shows soft update only if the user hasn't dismissed this particular version.
    private var showSoftUpdateBinding: Binding<Bool> {
        Binding(
            get: {
                featureFlagManager.recommendsSoftUpdate
                    && dismissedSoftUpdateVersion != featureFlagManager.recommendedVersion
            },
            set: { newValue in
                if !newValue {
                    dismissedSoftUpdateVersion = featureFlagManager.recommendedVersion
                }
            }
        )
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Tab content — ZStack keeps visited tabs alive to preserve navigation state
            ZStack {
                if loadedTabs.contains(.home) {
                    NavigationStack(path: $homePath) {
                        HomeView(viewModel: container.homeViewModel)
                            .navigationDestination(for: Route.self) { route in
                                routeDestination(route)
                            }
                    }
                    .environment(\.isTabActive, selectedTab == .home)
                    .opacity(selectedTab == .home ? 1 : 0)
                    .allowsHitTesting(selectedTab == .home)
                }

                if loadedTabs.contains(.search) {
                    NavigationStack(path: $searchPath) {
                        SearchView(viewModel: container.searchViewModel)
                            .navigationDestination(for: Route.self) { route in
                                routeDestination(route)
                            }
                    }
                    .environment(\.isTabActive, selectedTab == .search)
                    .opacity(selectedTab == .search ? 1 : 0)
                    .allowsHitTesting(selectedTab == .search)
                }

                if loadedTabs.contains(.library) {
                    NavigationStack(path: $libraryPath) {
                        LibraryView(viewModel: container.libraryViewModel)
                            .navigationDestination(for: Route.self) { route in
                                routeDestination(route)
                            }
                    }
                    .environment(\.isTabActive, selectedTab == .library)
                    .opacity(selectedTab == .library ? 1 : 0)
                    .allowsHitTesting(selectedTab == .library)
                }
            }
            .onChange(of: selectedTab) { _, newTab in
                loadedTabs.insert(newTab)
                scrollTracker.resetToVisible()
            }
            // Reset dock when navigating into/out of sub-pages
            .onChange(of: homePath.count) { _, _ in scrollTracker.resetToVisible() }
            .onChange(of: searchPath.count) { _, _ in scrollTracker.resetToVisible() }
            .onChange(of: libraryPath.count) { _, _ in scrollTracker.resetToVisible() }
            .background(Theme.Colors.backgroundPrimary)
            .safeAreaInset(edge: .bottom) {
                Color.clear
                    .frame(height: bottomInsetValue)
                    .animation(Theme.AnimationPresets.smooth, value: bottomInsetValue)
            }

            // Banner ad + floating dock — sits at the bottom of the ZStack.
            // No Spacer needed: `ZStack(alignment: .bottom)` handles
            // positioning. Removing the redundant Spacer avoids forcing the
            // VStack to occupy the full ZStack height and eliminates
            // measurement issues that caused uneven dock margins.
            VStack(spacing: 0) {
                if container.adManager.shouldShowAds {
                    BannerAdView(adUnitID: container.adManager.bannerAdUnitID)
                        .frame(height: 50)
                        .background(Theme.Colors.backgroundPrimary)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                // Floating dock — consistent edge margins
                FloatingDockView(selectedTab: $selectedTab, onReselect: { tab in
                    withAnimation {
                        switch tab {
                        case .home: homePath = NavigationPath()
                        case .search: searchPath = NavigationPath()
                        case .library: libraryPath = NavigationPath()
                        }
                    }
                })
            }
            .offset(y: dockHidden ? dockHideOffset : 0)
            .opacity(dockHidden ? 0 : 1)
            .allowsHitTesting(!dockHidden)
            .animation(Theme.AnimationPresets.smooth, value: dockHidden)
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { playerVM.isFullPlayerPresented },
                set: { playerVM.isFullPlayerPresented = $0 }
            )
        ) {
            FullPlayerView()
                .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: .constant(featureFlagManager.requiresForceUpdate)) {
            ForceUpdateView(
                message: featureFlagManager.forceUpdateMessage,
                appStoreURL: featureFlagManager.appStoreURL,
                minRequiredVersion: featureFlagManager.minRequiredVersion
            )
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: showSoftUpdateBinding) {
            SoftUpdateView(
                recommendedVersion: featureFlagManager.recommendedVersion,
                changelog: featureFlagManager.updateChangelog,
                appStoreURL: featureFlagManager.appStoreURL,
                onDismiss: {
                    dismissedSoftUpdateVersion = featureFlagManager.recommendedVersion
                }
            )
        }
        .preferredColorScheme(
            featureFlagManager.isAppearanceSettingsEnabled
                ? themeManager.preferredColorScheme : .dark
        )
        // C3 — CMS fetch and ad preload are owned by `LovelyMusicApp` so they
        // run regardless of onboarding state and exactly once per launch. The
        // previous `.task { fetchFlags }` site here lost the Bool return value
        // and ran *after* `DIContainer` had already frozen repository wiring.
        .task {
            _ = await container.apnsManager.requestPushAuthorization()
            if let pendingRoute = container.apnsManager.consumePendingRoute() {
                navigateToRoute(pendingRoute)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("handleDeepLinkRoute"))) { notification in
            // Drain the pending route so the `.task` fallback doesn't navigate twice.
            _ = container.apnsManager.consumePendingRoute()
            guard let route = notification.userInfo?["targetRoute"] as? Route else { return }
            navigateToRoute(route)
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToArtist)) { notification in
            guard let browseId = notification.userInfo?["browseId"] as? String else { return }
            navigateToRoute(.artist(browseId: browseId))
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToAlbum)) { notification in
            guard let browseId = notification.userInfo?["browseId"] as? String else { return }
            navigateToRoute(.album(browseId: browseId))
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchToSearchTab)) { _ in
            selectedTab = .search
        }
    }

    private func destinationTab(for route: Route) -> AppTab {
        switch route {
        case .artist, .album:
            return .search
        case .playlist, .likedSongs, .downloads:
            return .library
        case .homeSection, .settings:
            return .home
        }
    }

    private func navigateToRoute(_ route: Route) {
        let tab = destinationTab(for: route)
        selectedTab = tab
        loadedTabs.insert(tab)
        switch tab {
        case .home:
            homePath.append(route)
        case .search:
            searchPath.append(route)
        case .library:
            libraryPath.append(route)
        }
    }

    @ViewBuilder
    private func routeDestination(_ route: Route) -> some View {
        switch route {
        case .artist(let browseId):
            ArtistView(browseId: browseId, getArtistUseCase: container.getArtistUseCase)
        case .album(let browseId):
            AlbumView(browseId: browseId, getAlbumUseCase: container.getAlbumUseCase)
        case .playlist(let playlistId):
            PlaylistDetailView(
                playlistId: playlistId,
                getPlaylistUseCase: container.getPlaylistUseCase,
                managePlaylistUseCase: container.managePlaylistUseCase
            )
        case .homeSection(let section):
            HomeSectionDetailView(section: section)
        case .likedSongs:
            LikedSongsView(
                viewModel: LikedSongsViewModel(
                    manageFavoritesUseCase: container.manageFavoritesUseCase)
            )
        case .downloads:
            DownloadsView()
        case .settings:
            SettingsView(
                authManager: container.authManager, themeManager: container.themeManager,
                audioCacheManager: container.audioCacheManager)
        }
    }
}

enum AppTab: String, Hashable, CaseIterable, Identifiable {
    case home
    case search
    case library

    var id: String { rawValue }

    var pulseIcon: PulseIconKind {
        switch self {
        case .home: return .home
        case .search: return .search
        case .library: return .library
        }
    }

    var label: String {
        switch self {
        case .home: return String(localized: "Home")
        case .search: return String(localized: "Search")
        case .library: return String(localized: "Library")
        }
    }
}
