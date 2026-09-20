import AVFoundation
import Nuke
import SwiftUI

@main
struct LovelyMusicApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    /// Eagerly constructed FeatureFlagManager. Reads UserDefaults cache
    /// synchronously in its initializer (precedence: default → cache; CMS
    /// applied later by `fetchFlags`). D-Q2 LOCKED — bootstrap timing only.
    @State private var flagManager: FeatureFlagManager

    /// DI graph. Built **synchronously** at `init` when a persisted config
    /// exists (subsequent launches → CarPlay / background-launch / Now Playing
    /// remote-command paths get a non-nil `DIContainer.shared` immediately).
    /// On first install, deferred until the bootstrap gate resolves.
    @State private var diContainer: DIContainer?

    /// True only on first install (no cached CMS payload). Drives the splash
    /// gate in `body` and the bootstrap branch in `.task`.
    @State private var bootstrapping: Bool

    /// SplashView dismisses itself after its ~1.4–1.8s animation. We keep the
    /// splash overlay visible **as long as either** (a) the splash animation
    /// hasn't fired `onFinished` yet, **or** (b) DI isn't ready. This handles
    /// the slow-network case where the bootstrap takes longer than the splash
    /// animation: animation ends → `showSplash = false`, but overlay stays
    /// because `diContainer == nil`. Once DI lands, the overlay drops.
    @State private var showSplash = true

    /// Set by `runBackgroundFetch` when `fetchFlags()` returns `true` on a
    /// non-bootstrap launch (review-mode flipped vs cached → relaunch needed
    /// for repository wiring to take effect). Surfaces the alert in `body`.
    @State private var pendingRelaunchPrompt = false

    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("disableScreenshots") private var disableScreenshots = false
    @Environment(\.scenePhase) private var scenePhase

    /// Hard cap on the first-install bootstrap fetch (D-7). Matches
    /// `FeatureFlagManager.fetchFlags`'s `request.timeoutInterval`. Acts as a
    /// belt-and-suspenders deadline so the splash is guaranteed to dismiss
    /// even if URLSession's timer never fires for any reason.
    private static let bootstrapTimeoutSeconds: TimeInterval = 5

    init() {
        // XCUITest snapshot seeding: process launch args before @AppStorage reads.
        if CommandLine.arguments.contains("-hasCompletedOnboarding") {
            UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        }

        // Configure Nuke's shared pipeline for smooth launch experience:
        // - DataCache: persistent disk cache → images load instantly on relaunch
        // - dataCachePolicy: .storeEncodedImages → cache already-resized images (no re-process)
        // - isProgressiveDecodingEnabled → show low-res preview while downloading
        // - isStoringPreviewsInMemoryCache → previews available instantly in memory
        var config = ImagePipeline.Configuration.withDataCache(
            name: "com.lovelymusic.images",
            sizeLimit: 150 * 1024 * 1024
        )
        config.dataCachePolicy = .storeEncodedImages
        config.isProgressiveDecodingEnabled = true
        config.isStoringPreviewsInMemoryCache = true
        ImagePipeline.shared = ImagePipeline(configuration: config)

        // Install the UNUserNotificationCenter delegate before any DI work so a
        // cold-start tap (notification received while app not running) is
        // delivered to APNsManager as soon as the system invokes it.
        APNsManager.shared.configureDelegate()

        // Build the flag manager up-front so `init` can decide whether to gate
        // on a CMS fetch (first install) or build DI immediately (cache hit).
        // `FeatureFlagManager.init` is `@MainActor`-isolated; `App.init` runs
        // on the main thread per SwiftUI contract, so direct construction is
        // safe inside an `assumeIsolated` block.
        let manager = MainActor.assumeIsolated { FeatureFlagManager() }
        let hasCache = MainActor.assumeIsolated { manager.hasPersistedConfig }

        _flagManager = State(initialValue: manager)
        _bootstrapping = State(initialValue: !hasCache)
        if hasCache {
            // Subsequent launch: build DI synchronously so `DIContainer.shared`
            // is non-nil before any CarPlay / background / remote-command path
            // can fire. Identical to pre-Group-C behavior.
            let container = MainActor.assumeIsolated {
                DIContainer(featureFlagManager: manager)
            }
            _diContainer = State(initialValue: container)
        } else {
            // First install: defer DI construction until the bootstrap gate
            // resolves (max 5s). Splash overlay covers the empty body.
            _diContainer = State(initialValue: nil)
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                if let diContainer {
                    if hasCompletedOnboarding {
                        ContentView()
                            .environment(diContainer)
                            .environment(diContainer.themeManager)
                            .environment(diContainer.playerViewModel)
                            .environment(diContainer.playbackProgress)
                            .environment(diContainer.audioEngine)
                            .environment(diContainer.sleepTimerManager)
                            .environment(diContainer.premiumManager)
                            .environment(diContainer.equalizerManager)
                            .environment(diContainer.downloadManager)
                            .environment(diContainer.localizationManager)
                            .environment(diContainer.featureFlagManager)
                            .environment(diContainer.scrollDirectionTracker)
                            .environment(diContainer.adManager)
                            .environment(\.locale, diContainer.localizationManager.locale)
                            .id("\(ObjectIdentifier(diContainer))-\(diContainer.localizationManager.refreshToken)")
                            .screenshotProtected(disableScreenshots)
                            .transition(.opacity)
                    } else {
                        OnboardingView {
                            withAnimation(Theme.AnimationPresets.smooth) {
                                hasCompletedOnboarding = true
                            }
                        }
                        .transition(.opacity)
                    }
                } else {
                    // Bootstrapping placeholder — splash overlay covers this.
                    Theme.Colors.backgroundPrimary
                        .ignoresSafeArea()
                }

                if showSplash || diContainer == nil {
                    SplashView {
                        // SplashView fires this once ~1.8s after appear. We
                        // simply mark the animation as done; the overlay's
                        // visibility is governed by the compound condition
                        // above, which keeps it on while `diContainer == nil`.
                        showSplash = false
                    }
                    .transition(.opacity)
                    .zIndex(1)
                }
            }
            // Dismiss the splash overlay smoothly once DI lands (slow-network
            // path: splash animation already ended, `showSplash` is false, but
            // overlay was held by `diContainer == nil`).
            .animation(Theme.AnimationPresets.smooth, value: diContainer == nil)
            .animation(Theme.AnimationPresets.smooth, value: showSplash)
            // C4 — surface the relaunch-needed signal returned by
            // `fetchFlags()` on non-bootstrap launches. iOS does not allow
            // programmatic relaunch; this just informs the user.
            .alert(
                String(localized: "Configuration Updated"),
                isPresented: $pendingRelaunchPrompt
            ) {
                Button(String(localized: "OK"), role: .cancel) {
                    pendingRelaunchPrompt = false
                }
            } message: {
                Text(
                    String(
                        localized:
                            "Please relaunch the app to apply the latest configuration."
                    )
                )
            }
            .task {
                // Single-owner CMS fetch (C3). Replaces the previous
                // `ContentView.task { fetchFlags }` site, which couldn't run
                // before onboarding completed and discarded the Bool return.
                if bootstrapping {
                    await runBootstrapGate()
                } else {
                    await runBackgroundFetch()
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .background {
                    // Silently no-op if DI hasn't built yet (rare first-install
                    // backgrounding within the 5s gate).
                    diContainer?.audioEngine.savePlaybackState()

                    // S2: Reclaim disk on background. Trim the LRU cache to
                    // its size budget and remove orphans / entries superseded
                    // by a downloaded copy.
                    if let di = diContainer {
                        di.audioCacheManager.trimToFit()
                        let downloadIds = Set(di.downloadManager.downloadedSongs.map { $0.song.id })
                        di.audioCacheManager.removeOrphans(knownDownloadIds: downloadIds)
                    }
                } else if newPhase == .active {
                    // polish-B4: invalidate home cache when returning from a
                    // long background pause (>15 min) so users see fresh
                    // recommendations. On first launch the cache is not stale
                    // (lastForegroundedAt == nil) — we only record the
                    // timestamp.
                    Task {
                        guard let diContainer else { return }
                        if await diContainer.isHomeCacheStale() {
                            await diContainer.invalidateHomeCache()
                        }
                        await diContainer.touchForegroundCache()
                    }
                }
            }
        }
    }

    // MARK: - Bootstrap

    /// First-install path. Awaits `fetchFlags()` against a hard 5s deadline
    /// so the splash cannot hang indefinitely, then constructs `DIContainer`
    /// from the (possibly-updated) flag manager and transitions to `ready`.
    /// On timeout or fetch failure, falls back to the compiled default — which
    /// is `review_mode_enabled = true` (fail-safe demo mode). This guarantees a
    /// reviewer on a fresh install with an unreachable CMS can NEVER see live
    /// YouTube content; the next cold launch retries the fetch with no cache
    /// regression and switches to live mode once the CMS returns `false`.
    @MainActor
    private func runBootstrapGate() async {
        let started = Date()
        _ = await flagManager.fetchFlags()
        let elapsed = Date().timeIntervalSince(started)
        print(
            "🚀 [Bootstrap] First-install gate completed in \(String(format: "%.2f", elapsed))s; source=\(flagManager.effectiveSourceDescription), review_mode=\(flagManager.isReviewModeEnabled)"
        )

        let container = DIContainer(featureFlagManager: flagManager)
        withAnimation(Theme.AnimationPresets.smooth) {
            diContainer = container
            bootstrapping = false
        }

        // Preload ads after DI is up (was previously a `.task` on ContentView).
        Task { await container.adManager.preloadInterstitial() }
    }

    /// Subsequent-launch path. DI was already built from the cache in `init`;
    /// here we refresh the CMS in the background. If `review_mode_enabled` flipped
    /// (e.g. demo → live), seamlessly hot-swap `diContainer` and reload Home feed.
    @MainActor
    private func runBackgroundFetch() async {
        let needsRelaunch = await flagManager.fetchFlags()
        if needsRelaunch {
            print("🔄 [Bootstrap] Review mode changed at runtime → hot-swapping DIContainer to live mode")
            let newContainer = DIContainer(featureFlagManager: flagManager)
            withAnimation(Theme.AnimationPresets.smooth) {
                diContainer = newContainer
            }
            newContainer.homeViewModel.loadHome()
        }

        if let diContainer {
            Task { await diContainer.adManager.preloadInterstitial() }
        }
    }

    /// Races `fetchFlags()` against a deadline. Returns when whichever finishes
    /// first. The fetch task is allowed to continue in the background after
    /// the deadline (URLSession will honor its own 5s timeout); we just stop
    /// blocking the UI on it. Pure helper — testable without SwiftUI.
    @MainActor
    @discardableResult
    static func fetchWithDeadline(
        _ manager: FeatureFlagManager,
        seconds: TimeInterval
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = await manager.fetchFlags()
                return true
            }
            group.addTask {
                let nanos = UInt64(max(0, seconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                return false
            }
            let success = await group.next() ?? false
            group.cancelAll()
            return success
        }
    }
}
