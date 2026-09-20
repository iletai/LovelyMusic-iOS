import Foundation
import SwiftUI
import os

@MainActor
@Observable
final class DIContainer {
    /// Shared instance for cross-scene access (CarPlay, extensions).
    /// Set automatically during init.
    private(set) static var shared: DIContainer?

    // MARK: - Core
    let themeManager: ThemeManager
    let innerTubeAPI: InnerTubeAPI
    let audioEngine: AudioEngine
    let authManager: YouTubeAuthManager
    let telemetryManager: TelemetryManager

    // MARK: - Repositories
    let innerTubeRepository: InnerTubeRepositoryProtocol
    let playerRepository: PlayerRepositoryProtocol
    let playlistRepository: PlaylistRepositoryProtocol
    let lyricsRepository: LyricsRepositoryProtocol
    let favoritesRepository: FavoritesRepositoryProtocol
    let premiumRepository: PremiumRepositoryProtocol
    let pushTokenRepository: PushTokenRepositoryProtocol

    // MARK: - Use Cases
    let searchMusicUseCase: SearchMusicUseCase
    let browseHomeUseCase: BrowseHomeUseCase
    let getArtistUseCase: GetArtistUseCase
    let getAlbumUseCase: GetAlbumUseCase
    let getPlaylistUseCase: GetPlaylistUseCase
    let resolveStreamUseCase: ResolveStreamUseCase
    let getLyricsUseCase: GetLyricsUseCase
    let managePlaylistUseCase: ManagePlaylistUseCase
    let manageFavoritesUseCase: ManageFavoritesUseCase
    let getRelatedSongsUseCase: GetRelatedSongsUseCase
    let managePremiumUseCase: ManagePremiumUseCase
    let registerDeviceTokenUseCase: RegisterDeviceTokenUseCase

    // MARK: - Managers
    let sleepTimerManager: SleepTimerManager
    let premiumManager: PremiumManager
    let apnsManager: APNsManager
    let downloadManager: DownloadManager
    let equalizerManager: EqualizerManager
    let audioCacheManager: AudioCacheManager
    let localizationManager: LocalizationManager
    let featureFlagManager: FeatureFlagManager
    let playbackQualitySettings: PlaybackQualitySettings
    let playbackNetworkMonitor: PlaybackNetworkMonitor
    let adManager: AdManager
    let scrollDirectionTracker: ScrollDirectionTracker
    let playbackStatePersistence: PlaybackStatePersistence

    // MARK: - ViewModels
    let playerViewModel: PlayerViewModel
    let homeViewModel: HomeViewModel
    let searchViewModel: SearchViewModel
    let libraryViewModel: LibraryViewModel

    // Cache invalidation closures for pull-to-refresh
    let invalidateHomeCache: () async -> Void

    /// Notify the content cache that the app has returned to the active scene
    /// phase. Called from `LovelyMusicApp` (polish-B4).
    let touchForegroundCache: () async -> Void

    /// Returns true when the home cache's last-foreground timestamp is older
    /// than 15 min. Used to decide whether to invalidate on re-foregrounding.
    let isHomeCacheStale: () async -> Bool

    // MARK: - Playback Progress (isolated for high-frequency UI)
    let playbackProgress: PlaybackProgress

    /// Builds the dependency graph. Repository selection (Demo vs YouTube) is
    /// frozen here based on `featureFlagManager.isReviewModeEnabled`, which is
    /// hydrated synchronously from UserDefaults cache during `FeatureFlagManager.init`.
    /// To pick up a CMS toggle on the next cold launch, the live `fetchFlags()` call
    /// in `ContentView` updates the cache so the next `init()` reads the new value.
    init(featureFlagManager: FeatureFlagManager? = nil) {
        // Feature flags — must be populated BEFORE repository & theme selection.
        let flagManager = featureFlagManager ?? FeatureFlagManager()
        self.featureFlagManager = flagManager
        self.themeManager = ThemeManager(featureFlagManager: flagManager)

        // Resolve locale synchronously BEFORE creating InnerTubeAPI to avoid
        // race condition where first request uses device locale instead of saved preference.
        let savedRegion = UserDefaults.standard.string(forKey: "region") ?? "VN"
        let savedLanguage = UserDefaults.standard.string(forKey: "language") ?? "vi"
        let initialLocale = YouTubeLocale(gl: savedRegion, hl: savedLanguage)
        self.innerTubeAPI = InnerTubeAPI(locale: initialLocale)
        self.audioEngine = AudioEngine()
        self.authManager = YouTubeAuthManager()
        self.telemetryManager = TelemetryManager.shared
        // Override review mode from environment (used by XCUITest snapshots).
        let reviewModeOverride = ProcessInfo.processInfo.environment["REVIEW_MODE"].map { $0 != "0" }
        let isReviewMode = reviewModeOverride ?? flagManager.isReviewModeEnabled

        // Repositories — toggle between demo and real based on review mode
        let contentRepo: InnerTubeRepositoryProtocol
        let playerRepo: PlayerRepositoryProtocol
        let playlistRepo = LocalPlaylistRepository()
        let lyricsRepo = LrcLibService()
        let favoritesRepo = LocalFavoritesRepository()

        if isReviewMode {
            contentRepo = DemoContentRepository()
            playerRepo = DemoPlayerRepository()
        } else {
            let innerTubeRepo = InnerTubeRepository(api: innerTubeAPI)
            let cachedRepo = CachedInnerTubeRepository(wrapped: innerTubeRepo)
            contentRepo = cachedRepo
            playerRepo = PlayerRepository(
                api: innerTubeAPI,
                videoQualityProvider: {
                    let rawValue = UserDefaults.standard.string(forKey: "videoQuality") ?? "auto"
                    return VideoQuality(rawValue: rawValue) ?? .auto
                }
            )
        }

        // Read-only diagnostic log (polish-B1). Does NOT influence DI behaviour.
        let bootstrapLog = Logger(subsystem: "com.lovelymusic.app", category: "bootstrap")
        let mode = isReviewMode ? "demo" : "live"
        let source = flagManager.effectiveSourceDescription
        bootstrapLog.info(
            "repository_mode=\(mode, privacy: .public) source=\(source, privacy: .public)")

        self.innerTubeRepository = contentRepo
        self.playerRepository = playerRepo
        self.playlistRepository = playlistRepo
        self.lyricsRepository = lyricsRepo
        self.favoritesRepository = favoritesRepo
        let pushRepo = PushTokenRepository()
        self.pushTokenRepository = pushRepo

        // Use Cases — browse-related use cases go through content repo
        self.searchMusicUseCase = SearchMusicUseCase(repository: contentRepo)
        self.browseHomeUseCase = BrowseHomeUseCase(repository: contentRepo)
        self.getArtistUseCase = GetArtistUseCase(repository: contentRepo)
        self.getAlbumUseCase = GetAlbumUseCase(repository: contentRepo)
        self.getPlaylistUseCase = GetPlaylistUseCase(repository: contentRepo)
        self.resolveStreamUseCase = ResolveStreamUseCase(repository: playerRepo)
        self.getLyricsUseCase = GetLyricsUseCase(repository: lyricsRepo)
        self.managePlaylistUseCase = ManagePlaylistUseCase(repository: playlistRepo)
        self.manageFavoritesUseCase = ManageFavoritesUseCase(repository: favoritesRepo)
        self.getRelatedSongsUseCase = GetRelatedSongsUseCase(repository: contentRepo)
        let registerTokenUseCase = RegisterDeviceTokenUseCase(repository: pushRepo)
        self.registerDeviceTokenUseCase = registerTokenUseCase

        let apnsMgr = APNsManager.shared
        // Delegate was already installed in `LovelyMusicApp.init` (early, so a
        // cold-start notification tap is captured). Here we only inject the use case.
        apnsMgr.configureDelegate()
        apnsMgr.injectRegisterUseCase(registerTokenUseCase)
        self.apnsManager = apnsMgr

        let qualitySettings = PlaybackQualitySettings()
        self.playbackQualitySettings = qualitySettings
        let networkMonitor = PlaybackNetworkMonitor()
        self.playbackNetworkMonitor = networkMonitor

        self.sleepTimerManager = SleepTimerManager()
        self.downloadManager = DownloadManager()
        self.equalizerManager = EqualizerManager()
        self.audioCacheManager = AudioCacheManager()
        self.localizationManager = LocalizationManager()
        let premiumManager = PremiumManager(featureFlagManager: flagManager)
        self.premiumManager = premiumManager
        self.adManager = AdManager(
            premiumManager: premiumManager, featureFlagManager: flagManager)
        self.scrollDirectionTracker = ScrollDirectionTracker()
        self.playbackStatePersistence = PlaybackStatePersistence()

        let playbackHeaders: [String: String] = isReviewMode
            ? [:]
            : AppConstants.youtubeStreamHeaders
        self.audioEngine.streamURLResolver = PlaybackQualityWiring.makePlaybackResolver(
            useCase: resolveStreamUseCase,
            settings: qualitySettings,
            networkSnapshot: { await networkMonitor.currentSnapshot },
            isPremium: { premiumManager.isPremium },
            requestHeaders: playbackHeaders
        )
        self.audioEngine.videoStreamURLResolver = { [playerRepo] videoId in
            try await playerRepo.resolveVideoStreamURL(videoId: videoId)
        }
        self.audioEngine.streamHeaders = playbackHeaders
        // Provide auth cookies (SAPISID, SID, __Secure-1PSID…) for CDN download auth.
        // YouTubeAuthManager stores them in Keychain — not HTTPCookieStorage — so
        // URLSession can't auto-inject them. This closure is evaluated at download time.
        self.audioEngine.authCookieProvider = { [weak authManager] in
            authManager?.cookieHeaderString()
        }

        // Premium — Repository + Use Case
        let premiumRepo = PremiumRepository(premiumManager: premiumManager)
        self.premiumRepository = premiumRepo
        self.managePremiumUseCase = ManagePremiumUseCase(repository: premiumRepo)

        // Wire download manager into audio engine for offline playback
        self.audioEngine.downloadManager = self.downloadManager
        self.audioEngine.audioCacheManager = self.audioCacheManager
        self.audioEngine.equalizerManager = self.equalizerManager
        self.audioEngine.playbackStatePersistence = self.playbackStatePersistence
        self.audioEngine.isPremiumProvider = { [weak premiumManager] in
            premiumManager?.isPremium ?? false
        }

        PlaybackQualityWiring.installExplicitDownloadResolverFactory(
            on: downloadManager,
            useCase: resolveStreamUseCase,
            settings: qualitySettings,
            isPremium: { premiumManager.isPremium }
        )
        self.downloadManager.streamHeaders = playbackHeaders

        self.sleepTimerManager.onTimerExpired = { [weak audioEngine] in
            guard let audioEngine, audioEngine.isPlaying else { return }
            audioEngine.playPause()
        }

        self.playerViewModel = PlayerViewModel(
            audioEngine: audioEngine,
            resolveStreamUseCase: resolveStreamUseCase,
            getLyricsUseCase: getLyricsUseCase,
            managePlaylistUseCase: managePlaylistUseCase,
            manageFavoritesUseCase: manageFavoritesUseCase,
            premiumManager: premiumManager,
            getRelatedSongsUseCase: getRelatedSongsUseCase,
            adManager: adManager,
            telemetryManager: telemetryManager
        )
        // Skip restoring old YouTube playback in demo mode
        if !isReviewMode {
            self.playerViewModel.restorePersistedPlayback()
        }
        if isReviewMode {
            self.invalidateHomeCache = {}
            self.touchForegroundCache = {}
            self.isHomeCacheStale = { false }
        } else {
            self.invalidateHomeCache = {
                await (contentRepo as? CachedInnerTubeRepository)?.invalidateHome()
            }
            self.touchForegroundCache = {
                await (contentRepo as? CachedInnerTubeRepository)?.touchForeground()
            }
            self.isHomeCacheStale = {
                await (contentRepo as? CachedInnerTubeRepository)?.isStale ?? false
            }
        }
        self.homeViewModel = HomeViewModel(
            browseHomeUseCase: browseHomeUseCase,
            invalidateCache: invalidateHomeCache,
            drainPolicy: HomeContinuationDrainPolicy(
                maxPages: 10,
                maxDuration: 4.0,
                isEnabled: flagManager.isHomeContinuationDrainEnabled
            )
        )
        self.searchViewModel = SearchViewModel(
            searchUseCase: searchMusicUseCase, browseHomeUseCase: browseHomeUseCase)
        self.libraryViewModel = LibraryViewModel(
            managePlaylistUseCase: managePlaylistUseCase,
            manageFavoritesUseCase: manageFavoritesUseCase)
        self.playbackProgress = PlaybackProgress(audioEngine: audioEngine)

        // ponytail: guarded legacy path skipped in production until Task 10 Cluster F
        // delivers a measured storage calibration profile. Without it, the gate always
        // denies and no music plays. Restore by removing this guard after M2 passes.
        let hasProductionCalibrationProfile = false
        if !isReviewMode && hasProductionCalibrationProfile {
            let guardedResolver = self.resolveStreamUseCase
            let reservationLedger = PlaybackStorageReservationLedger(
                capacityProvider: VolumeImportantUsageCapacityProvider(
                    volumeURL: FileManager.default.temporaryDirectory
                )
            )
            let storagePolicy = PlaybackStoragePolicy(
                compatibilityProfile: .unavailable,
                requiredCalibrationID: nil,
                reservationLedger: reservationLedger
            )
            let transferGate = PlaybackFullResourceTransferGateAdapter(
                initialNetwork: .offline,
                storagePolicy: storagePolicy
            )
            let legacyFiles = FileManagerLegacyPlaybackFiles()
            let guardedAudioEngine = audioEngine
            let legacyDriver = LegacyPlaybackDriver(
                transport: URLSessionLegacyMediaDownloader(),
                remuxer: AudioEngineLegacyMediaRemuxer(),
                fileSystem: legacyFiles,
                clock: SystemLegacyPlaybackClock(),
                tokenValidator: { [weak guardedAudioEngine] tokens in
                    guardedAudioEngine?.acceptsGuardedLegacyTokens(tokens) ?? false
                },
                eventSink: { _ in }
            )
            audioEngine.installGuardedLegacyPlayback(
                GuardedLegacyPlaybackConfiguration(
                    descriptorResolver: { videoID in
                        let network = await networkMonitor.currentSnapshot
                        let quality = await MainActor.run {
                            qualitySettings.reloadFromDefaults()
                            return qualitySettings.effectiveStreamingQuality(
                                for: network,
                                isPremium: premiumManager.isPremium
                            )
                        }
                        return try await guardedResolver.executeDescriptor(
                            videoId: videoID,
                            quality: quality,
                            requestHeaders: playbackHeaders
                        )
                    },
                    descriptorQualifier: LegacyDescriptorQualifier(
                        probe: HeaderOnlyLegacyDescriptorProbe()
                    ),
                    transferGate: transferGate,
                    legacyDriver: legacyDriver,
                    initialNetworkSnapshot: .offline,
                    currentNetworkSnapshot: {
                        await networkMonitor.currentSnapshot
                    },
                    // Range source remains disabled in the Task 8 production profile.
                    isRangeEligible: { _ in false },
                    artifactHost: audioEngine.guardedLegacyArtifactHost,
                    disposeCompletedArtifactSynchronously: { resource in
                        legacyFiles.disposeCompletedArtifactSynchronously(resource)
                    }
                )
            )
        }
        Task { [weak audioEngine] in
            await networkMonitor.setUpdateHandler { snapshot in
                await MainActor.run {
                    audioEngine?.receivePlaybackNetworkSnapshot(snapshot)
                }
            }
            await networkMonitor.start()
        }

        // Locale is already set synchronously during InnerTubeAPI init above.
        // Only need to apply auth cookies here.
        if !isReviewMode {
            if authManager.isLoggedIn, let cookieStr = authManager.cookieHeaderString() {
                Task { await innerTubeAPI.setCookie(cookieStr) }
            }
        }

        // Observe settings changes
        let cachedRepoRef = contentRepo as? CachedInnerTubeRepository
        NotificationCenter.default.addObserver(
            forName: .settingsChanged,
            object: nil,
            queue: .main
        ) { [weak innerTubeAPI, weak authManager] _ in
            let region = UserDefaults.standard.string(forKey: "region") ?? "VN"
            let language = UserDefaults.standard.string(forKey: "language") ?? "vi"
            Task {
                await innerTubeAPI?.setLocale(YouTubeLocale(gl: region, hl: language))
                await cachedRepoRef?.invalidateAll()
            }
            // Sync auth cookie state
            if let authManager {
                let cookieStr = authManager.isLoggedIn ? authManager.cookieHeaderString() : nil
                Task { await innerTubeAPI?.setCookie(cookieStr) }
            }
        }

        Self.shared = self

        // Round 2 — Fix 4 (review-codex MED #4): notify scenes (especially
        // `CarPlaySceneDelegate`) that may have attached before the bootstrap
        // gate resolved on first install. CarPlay's `didConnect` can fire
        // before `DIContainer.shared` is non-nil during the splash gate; the
        // delegate listens for this notification and (re)builds its UI when
        // posted. A notification path is preferred over `Task` polling
        // because it is event-driven, single-shot, and survives the brief
        // window during which the scene is up but the container is not.
        NotificationCenter.default.post(
            name: .lovelyMusicDIContainerReady,
            object: self
        )
    }
}

extension Notification.Name {
    /// Posted once at the end of `DIContainer.init`, after `Self.shared` is
    /// assigned. Used by `CarPlaySceneDelegate` to recover from a CarPlay
    /// connection that occurs during first-install bootstrap (Round 2 Fix 4).
    static let lovelyMusicDIContainerReady = Notification.Name(
        "com.lovelymusic.diContainerReady"
    )
}
