import Foundation

/// Nonisolated storage for audio bitrate thresholds.
/// Kept outside `FeatureFlagManager` (`@MainActor`) so `PlayerRepository`
/// can read values from a non-isolated context without actor hops.
/// Mutations happen only on the main actor during `applyConfig`, so a
/// plain class is sufficient (OSAllocatedUnfairLock not warranted here).
final class AudioBitrateStorage: @unchecked Sendable {
    static let shared = AudioBitrateStorage()
    var low: Int = 64_000
    var medium: Int = 128_000
    var high: Int = 256_000
    private init() {}
}

@MainActor @Observable
final class FeatureFlagManager {

    // — Feature Toggles — CMS: Bool fields ------------------------------------
    private(set) var isDownloadEnabled: Bool = true  // download_enabled
    private(set) var isYouTubeAuthEnabled: Bool = true  // youtube_auth_enabled
    private(set) var isVideoPlaybackEnabled: Bool = true  // video_playbacktoggle
    private(set) var isDevModeEnabled: Bool = false  // dev_mode_enabled
    private(set) var isAppearanceSettingsEnabled: Bool = true  // appearance_settings
    private(set) var isAdsEnabled: Bool = false  // ads disabled — removed from remote config
    private(set) var isReviewModeEnabled: Bool = true  // review_mode_enabled (fail-safe demo mode)
    private(set) var isHomeContinuationDrainEnabled: Bool = false  // home_continuation_drain_enabled

    // — Tier 1: Monetization --------------------------------------------------
    private(set) var freeSkipLimit: Int = 12  // free_skip_limit
    private(set) var freeDownloadLimit: Int = 5  // free_download_limit
    private(set) var adsSkipFrequency: Int = 4  // ads_skip_frequency — show interstitial every N skips
    private(set) var adsSectionInterval: Int = 3  // ads_section_interval — inline ad every N sections (Home)
    private(set) var adsSongInterval: Int = 10  // ads_song_interval — inline ad every N songs (Playlist/Album/Liked)

    // — Tier 1: Premium Configuration -----------------------------------------
    private(set) var isPremiumEnabled: Bool = true  // premium_enabled
    private(set) var isLifetimeEnabled: Bool = true  // lifetime_enabled
    private(set) var termsOfServiceURL: String = ""  // terms_of_service_url
    private(set) var privacyPolicyURL: String = ""  // privacy_policy_url

    // — Tier 3: Audio Bitrate (bps) -------------------------------------------
    // Stored in `AudioBitrateStorage` so non-isolated callers can read without hops.
    nonisolated var audioBitrateLow: Int { AudioBitrateStorage.shared.low }
    nonisolated var audioBitrateMedium: Int { AudioBitrateStorage.shared.medium }
    nonisolated var audioBitrateHigh: Int { AudioBitrateStorage.shared.high }

    // — Tier 3: Animation Params (seconds) ------------------------------------
    private(set) var animationBouncyResponse: Double = 0.3  // anim_bouncy_response
    private(set) var animationBouncyDamping: Double = 0.6  // anim_bouncy_damping
    private(set) var animationSmoothResponse: Double = 0.4  // anim_smooth_response
    private(set) var animationSmoothDamping: Double = 0.8  // anim_smooth_damping
    private(set) var animationPlayerResponse: Double = 0.5  // anim_player_response
    private(set) var animationPlayerDamping: Double = 0.85  // anim_player_damping
    private(set) var animationGentleDuration: Double = 0.25  // anim_gentle_duration
    private(set) var animationCrossfadeDuration: Double = 0.3  // anim_fade_duration

    // — Tier 3: UI Layout (points) --------------------------------------------
    private(set) var homeMoodCarouselHeight: Double = 110  // home_m_carousel_heig
    private(set) var homeMoodItemWidth: Double = 180  // home_mood_item_width
    private(set) var homeMoodGridRowHeight: Double = 48  // home_m_grid_row_heig

    // — Tier 3: Scroll Performance --------------------------------------------
    // Fast 60ms linear fade for thumbnails during ScrollPhase.decelerating.
    // Prevents the "pop-in" caused by 200ms opacity crossfades firing in rapid
    // succession while the user flings a long list. Default ON.
    private(set) var scrollFastFadeDuringFling: Bool = true  // scroll_fast_fade_fling
    // Cap shimmer placeholder to 3s then swap to a music-note icon. Stops the
    // "broken app" perception when image decode fails silently. Default ON.
    private(set) var scrollShimmerTimeoutEnabled: Bool = true  // scroll_shimmer_timeout

    // — Force Update ----------------------------------------------------------
    private(set) var requiresForceUpdate: Bool = false
    private(set) var forceUpdateMessage: String = ""  // force_update_message
    private(set) var appStoreURL: String = ""  // app_store_url
    private(set) var minRequiredVersion: String = ""  // min_required_version

    // — Soft Update (Recommended) ---------------------------------------------
    private(set) var recommendsSoftUpdate: Bool = false
    private(set) var recommendedVersion: String = ""  // recommended_version
    private(set) var updateChangelog: String = ""  // update_changelog

    // — Editorial & Discovery -------------------------------------------------
    private(set) var editorial: EditorialConfig = .default
    var isEditorialEnabled: Bool { editorial.isEnabled && !editorial.featuredPlaylists.isEmpty }

    // — In-App Announcements --------------------------------------------------
    private(set) var announcements: [AnnouncementItem] = []
    var activeAnnouncement: AnnouncementItem? {
        announcements.first(where: { $0.isActive && !$0.message.isEmpty })
    }

    // — Seasonal Theme --------------------------------------------------------
    private(set) var seasonalTheme: SeasonalThemeConfig = .default

    // — Paywall Promo Experiment ----------------------------------------------
    private(set) var paywallPromo: PaywallPromoConfig = .default

    static var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Build configuration name, resolved at compile time.
    /// Hidden in Release — callers should gate display with `#if DEBUG || STAGING`.
    static var buildConfiguration: String {
        #if DEBUG
        return "Debug"
        #elseif STAGING
        return "Staging"
        #else
        return "Release"
        #endif
    }

    private let configURL: URL?
    private let apiKey: String?
    private let defaults: UserDefaults
    private let cacheKey = "feature_flags_cache"
    @ObservationIgnored nonisolated let playbackSnapshotStore: PlaybackFeatureSnapshotStore

    nonisolated var playbackControls: PlaybackFeatureSnapshot {
        playbackSnapshotStore.snapshot()
    }

    /// Tracks where the currently-applied flag values came from. Read-only; updated
    /// in `loadCachedFlags()` and `fetchFlags()`. Does NOT influence precedence —
    /// purely diagnostic. See `effectiveSourceDescription`.
    enum ConfigSource: String {
        case `default`
        case userdefaults
        case remoteConfig = "remote_config"
    }
    private(set) var configSource: ConfigSource = .default

    /// Read-only diagnostic string describing which source supplied the active
    /// feature-flag values: `"default"`, `"userdefaults"`, or `"remote_config"`.
    /// Used by DI bootstrap logging only — does NOT change any precedence logic.
    var effectiveSourceDescription: String { configSource.rawValue }

    /// `true` iff `loadCachedFlags()` decoded a valid payload from UserDefaults
    /// during init. Used by `LovelyMusicApp` bootstrap to decide whether to gate
    /// UI on a CMS fetch (first install only) — does NOT affect precedence
    /// (D-Q2 LOCKED). On corrupt or missing cache, this stays `false`.
    private(set) var hasPersistedConfig: Bool = false

    init(
        configURLString: String = {
            #if DEBUG || STAGING
            return "https://iletai.microcms.io/api/v1/app-config-develop"
            #else
            return "https://iletai.microcms.io/api/v1/app-config"
            #endif
        }(),
        apiKey: String? = SecretsProvider.microCMSAPIKey,
        defaults: UserDefaults = .standard
    ) {
        self.configURL = URL(string: configURLString)
        self.apiKey = apiKey
        self.defaults = defaults
        self.playbackSnapshotStore = PlaybackFeatureSnapshotStore(initial: .failClosed)
        loadCachedFlags()
    }

    // MARK: - Fetch from server

    /// Fetches CMS flags. Returns `true` if `isReviewModeEnabled` differs from the
    /// pre-fetch in-memory value — signal to the caller that a relaunch is needed
    /// for the new repository wiring (selected at `DIContainer.init`) to take effect.
    @discardableResult
    func fetchFlags() async -> Bool {
        let previousReviewMode = isReviewModeEnabled
        guard let url = configURL, let apiKey, !apiKey.isEmpty else {
            print("🚩 [FeatureFlags] No remote config credentials configured — using open-source defaults")
            return false
        }

        do {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 5  // bound network wait
            request.setValue(apiKey, forHTTPHeaderField: "X-MICROCMS-API-KEY")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                httpResponse.statusCode == 200
            else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("🚩 [FeatureFlags] HTTP \(code) — keeping cached/default flags")
                return false
            }

            guard applyRemoteConfigData(data) else {
                print("🚩 [FeatureFlags] CMS payload invalid — range controls failed closed")
                return false
            }
            print(
                "🚩 [FeatureFlags] CMS decoded — review_mode_enabled=\(isReviewModeEnabled)"
            )
            let newReviewMode = isReviewModeEnabled
            if newReviewMode != previousReviewMode {
                print(
                    "🚩 [FeatureFlags] isReviewModeEnabled changed \(previousReviewMode) → \(newReviewMode). Repository wiring is frozen for this launch — relaunch the app to apply."
                )
                return true
            }
            return false
        } catch {
            print(
                "🚩 [FeatureFlags] fetch error: \(error.localizedDescription) — keeping cached/default flags"
            )
            return false
        }
    }

    // MARK: - Cache

    /// Applies a received payload through the same path used by `fetchFlags()`.
    /// A payload that cannot be decoded must revoke the complete range-control
    /// snapshot instead of retaining a previously enabled cached snapshot.
    @discardableResult
    func applyRemoteConfigData(_ data: Data) -> Bool {
        do {
            let payload = try JSONDecoder().decode(RemoteConfigPayload.self, from: data)
            let config = payload.resolveConfig()
            applyConfig(config)
            configSource = .remoteConfig
            hasPersistedConfig = true
            cacheFlags(data)
            return true
        } catch {
            playbackSnapshotStore.update(.failClosed)
            defaults.removeObject(forKey: cacheKey)
            defaults.synchronize()
            return false
        }
    }

    private func loadCachedFlags() {
        guard let data = defaults.data(forKey: cacheKey) else {
            return
        }
        do {
            let payload = try JSONDecoder().decode(RemoteConfigPayload.self, from: data)
            let config = payload.resolveConfig()
            applyConfig(config)
            configSource = .userdefaults
            hasPersistedConfig = true
        } catch {
            playbackSnapshotStore.update(.failClosed)
            print(
                "🚩 [FeatureFlags] Cached config failed to decode (\(error.localizedDescription)) — falling back to compiled defaults"
            )
        }
    }

    private func applyConfig(_ config: AppRemoteConfig) {
        playbackSnapshotStore.update(config.playbackRange.playbackFeatureSnapshot)
        isDownloadEnabled = config.toggles.downloadEnabled
        isYouTubeAuthEnabled = config.toggles.youtubeAuthEnabled
        isVideoPlaybackEnabled = config.toggles.videoPlaybackEnabled
        isDevModeEnabled = config.toggles.devModeEnabled
        isAppearanceSettingsEnabled = config.toggles.appearanceSettingsEnabled
        isAdsEnabled = config.monetization.adsEnabled
        isReviewModeEnabled = config.toggles.reviewModeEnabled  // fail-safe: default true
        isHomeContinuationDrainEnabled = config.toggles.homeContinuationDrainEnabled
        forceUpdateMessage = config.update.forceUpdateMessage
        appStoreURL = config.update.appStoreURL
        minRequiredVersion = config.update.minRequiredVersion
        recommendedVersion = config.update.recommendedVersion
        updateChangelog = config.update.updateChangelog

        // Tier 1 — Monetization
        freeSkipLimit = config.monetization.freeSkipLimit
        freeDownloadLimit = config.monetization.freeDownloadLimit
        adsSkipFrequency = config.monetization.adsSkipFrequency
        adsSectionInterval = config.monetization.adsSectionInterval
        adsSongInterval = config.monetization.adsSongInterval

        // Tier 1 — Premium Configuration
        isPremiumEnabled = config.monetization.premiumEnabled
        isLifetimeEnabled = config.monetization.lifetimeEnabled
        termsOfServiceURL = config.monetization.termsOfServiceURL
        privacyPolicyURL = config.monetization.privacyPolicyURL

        // Tier 3 — Audio
        AudioBitrateStorage.shared.low = config.audio.low
        AudioBitrateStorage.shared.medium = config.audio.medium
        AudioBitrateStorage.shared.high = config.audio.high

        // Tier 3 — Animations → push to Theme.AnimationPresets
        animationBouncyResponse = config.animations.bouncyResponse
        animationBouncyDamping = config.animations.bouncyDamping
        animationSmoothResponse = config.animations.smoothResponse
        animationSmoothDamping = config.animations.smoothDamping
        animationPlayerResponse = config.animations.playerResponse
        animationPlayerDamping = config.animations.playerDamping
        animationGentleDuration = config.animations.gentleDuration
        animationCrossfadeDuration = config.animations.crossfadeDuration

        Theme.AnimationPresets.bouncyResponse = animationBouncyResponse
        Theme.AnimationPresets.bouncyDamping = animationBouncyDamping
        Theme.AnimationPresets.smoothResponse = animationSmoothResponse
        Theme.AnimationPresets.smoothDamping = animationSmoothDamping
        Theme.AnimationPresets.playerResponse = animationPlayerResponse
        Theme.AnimationPresets.playerDamping = animationPlayerDamping
        Theme.AnimationPresets.gentleDuration = animationGentleDuration
        Theme.AnimationPresets.crossfadeDuration = animationCrossfadeDuration

        // Tier 3 — UI Layout
        homeMoodCarouselHeight = config.ui.homeMoodCarouselHeight
        homeMoodItemWidth = config.ui.homeMoodItemWidth
        homeMoodGridRowHeight = config.ui.homeMoodGridRowHeight

        // Tier 3 — Scroll Performance
        scrollFastFadeDuringFling = config.ui.scrollFastFadeDuringFling
        scrollShimmerTimeoutEnabled = config.ui.scrollShimmerTimeoutEnabled

        // Editorial & In-App Dynamic Features
        editorial = config.editorial
        announcements = config.announcements
        seasonalTheme = config.seasonalTheme
        paywallPromo = config.paywallPromo

        let currentVersion = Self.currentAppVersion
        checkForceUpdate(currentVersion: currentVersion, minVersion: config.update.minRequiredVersion)
        checkSoftUpdate(
            currentVersion: currentVersion, recommendedVersion: config.update.recommendedVersion)
    }

    // MARK: - Force Update

    private func checkForceUpdate(currentVersion: String, minVersion: String?) {
        guard let minVersion, !minVersion.isEmpty else {
            requiresForceUpdate = false
            return
        }
        requiresForceUpdate = isVersion(currentVersion, lessThan: minVersion)
    }

    // MARK: - Soft Update

    private func checkSoftUpdate(currentVersion: String, recommendedVersion: String?) {
        guard !requiresForceUpdate,
            let recommendedVersion, !recommendedVersion.isEmpty
        else {
            recommendsSoftUpdate = false
            return
        }
        recommendsSoftUpdate = isVersion(currentVersion, lessThan: recommendedVersion)
    }

    // MARK: - Version Comparison

    static func isVersion(_ version: String, lessThan other: String) -> Bool {
        version.compare(other, options: .numeric) == .orderedAscending
    }

    private func isVersion(_ version: String, lessThan other: String) -> Bool {
        Self.isVersion(version, lessThan: other)
    }

    private func cacheFlags(_ rawData: Data) {
        defaults.set(rawData, forKey: cacheKey)
        // Force flush so the value survives a force-quit before the next launch
        // reads it during DIContainer init.
        defaults.synchronize()
    }
}

// MARK: - Modular Domain Models

struct AppRemoteConfig: Codable, Equatable, Sendable {
    var schemaVersion: Int?
    var toggles: TogglesConfig
    var monetization: MonetizationConfig
    var audio: AudioBitrateConfig
    var animations: AnimationConfig
    var ui: UIConfig
    var update: AppUpdateConfig
    var playbackRange: PlaybackRangeConfig
    var editorial: EditorialConfig
    var announcements: [AnnouncementItem]
    var seasonalTheme: SeasonalThemeConfig
    var paywallPromo: PaywallPromoConfig

    static let `default` = AppRemoteConfig(
        schemaVersion: 1,
        toggles: .default,
        monetization: .default,
        audio: .default,
        animations: .default,
        ui: .default,
        update: .default,
        playbackRange: .failClosed,
        editorial: .default,
        announcements: [],
        seasonalTheme: .default,
        paywallPromo: .default
    )

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "$schema_version"
        case toggles
        case monetization
        case audio
        case animations
        case ui
        case update
        case playbackRange = "playback_range"
        case editorial
        case announcements
        case seasonalTheme = "seasonal_theme"
        case paywallPromo = "paywall_promo"
    }

    init(
        schemaVersion: Int? = 1,
        toggles: TogglesConfig = .default,
        monetization: MonetizationConfig = .default,
        audio: AudioBitrateConfig = .default,
        animations: AnimationConfig = .default,
        ui: UIConfig = .default,
        update: AppUpdateConfig = .default,
        playbackRange: PlaybackRangeConfig = .failClosed,
        editorial: EditorialConfig = .default,
        announcements: [AnnouncementItem] = [],
        seasonalTheme: SeasonalThemeConfig = .default,
        paywallPromo: PaywallPromoConfig = .default
    ) {
        self.schemaVersion = schemaVersion
        self.toggles = toggles
        self.monetization = monetization
        self.audio = audio
        self.animations = animations
        self.ui = ui
        self.update = update
        self.playbackRange = playbackRange
        self.editorial = editorial
        self.announcements = announcements
        self.seasonalTheme = seasonalTheme
        self.paywallPromo = paywallPromo
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        self.toggles = try container.decodeIfPresent(TogglesConfig.self, forKey: .toggles) ?? .default
        self.monetization = try container.decodeIfPresent(MonetizationConfig.self, forKey: .monetization) ?? .default
        self.audio = try container.decodeIfPresent(AudioBitrateConfig.self, forKey: .audio) ?? .default
        self.animations = try container.decodeIfPresent(AnimationConfig.self, forKey: .animations) ?? .default
        self.ui = try container.decodeIfPresent(UIConfig.self, forKey: .ui) ?? .default
        self.update = try container.decodeIfPresent(AppUpdateConfig.self, forKey: .update) ?? .default
        self.playbackRange = try container.decodeIfPresent(PlaybackRangeConfig.self, forKey: .playbackRange) ?? .failClosed
        self.editorial = try container.decodeIfPresent(EditorialConfig.self, forKey: .editorial) ?? .default
        self.announcements = try container.decodeIfPresent([AnnouncementItem].self, forKey: .announcements) ?? []
        self.seasonalTheme = try container.decodeIfPresent(SeasonalThemeConfig.self, forKey: .seasonalTheme) ?? .default
        self.paywallPromo = try container.decodeIfPresent(PaywallPromoConfig.self, forKey: .paywallPromo) ?? .default
    }
}

struct TogglesConfig: Codable, Equatable, Sendable {
    var downloadEnabled: Bool
    var youtubeAuthEnabled: Bool
    var videoPlaybackEnabled: Bool
    var devModeEnabled: Bool
    var appearanceSettingsEnabled: Bool
    var reviewModeEnabled: Bool
    var homeContinuationDrainEnabled: Bool

    static let `default` = TogglesConfig(
        downloadEnabled: true,
        youtubeAuthEnabled: true,
        videoPlaybackEnabled: true,
        devModeEnabled: false,
        appearanceSettingsEnabled: true,
        reviewModeEnabled: false,
        homeContinuationDrainEnabled: false
    )

    enum CodingKeys: String, CodingKey {
        case downloadEnabled = "download_enabled"
        case youtubeAuthEnabled = "youtube_auth_enabled"
        case videoPlaybackEnabled = "video_playback_enabled"
        case devModeEnabled = "dev_mode_enabled"
        case appearanceSettingsEnabled = "appearance_settings_enabled"
        case reviewModeEnabled = "review_mode_enabled"
        case homeContinuationDrainEnabled = "home_continuation_drain_enabled"
    }

    init(
        downloadEnabled: Bool = false,
        youtubeAuthEnabled: Bool = false,
        videoPlaybackEnabled: Bool = true,
        devModeEnabled: Bool = false,
        appearanceSettingsEnabled: Bool = false,
        reviewModeEnabled: Bool = true,
        homeContinuationDrainEnabled: Bool = false
    ) {
        self.downloadEnabled = downloadEnabled
        self.youtubeAuthEnabled = youtubeAuthEnabled
        self.videoPlaybackEnabled = videoPlaybackEnabled
        self.devModeEnabled = devModeEnabled
        self.appearanceSettingsEnabled = appearanceSettingsEnabled
        self.reviewModeEnabled = reviewModeEnabled
        self.homeContinuationDrainEnabled = homeContinuationDrainEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.downloadEnabled = try container.decodeIfPresent(Bool.self, forKey: .downloadEnabled) ?? Self.default.downloadEnabled
        self.youtubeAuthEnabled = try container.decodeIfPresent(Bool.self, forKey: .youtubeAuthEnabled) ?? Self.default.youtubeAuthEnabled
        self.videoPlaybackEnabled = try container.decodeIfPresent(Bool.self, forKey: .videoPlaybackEnabled) ?? Self.default.videoPlaybackEnabled
        self.devModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .devModeEnabled) ?? Self.default.devModeEnabled
        self.appearanceSettingsEnabled = try container.decodeIfPresent(Bool.self, forKey: .appearanceSettingsEnabled) ?? Self.default.appearanceSettingsEnabled
        self.reviewModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .reviewModeEnabled) ?? Self.default.reviewModeEnabled
        self.homeContinuationDrainEnabled = try container.decodeIfPresent(Bool.self, forKey: .homeContinuationDrainEnabled) ?? Self.default.homeContinuationDrainEnabled
    }
}

struct MonetizationConfig: Codable, Equatable, Sendable {
    var freeSkipLimit: Int
    var freeDownloadLimit: Int
    var premiumEnabled: Bool
    var lifetimeEnabled: Bool
    var adsEnabled: Bool
    var adsSkipFrequency: Int
    var adsSectionInterval: Int
    var adsSongInterval: Int
    var termsOfServiceURL: String
    var privacyPolicyURL: String

    static let `default` = MonetizationConfig(
        freeSkipLimit: 12,
        freeDownloadLimit: 5,
        premiumEnabled: true,
        lifetimeEnabled: true,
        adsEnabled: false,
        adsSkipFrequency: 4,
        adsSectionInterval: 3,
        adsSongInterval: 10,
        termsOfServiceURL: "",
        privacyPolicyURL: ""
    )

    enum CodingKeys: String, CodingKey {
        case freeSkipLimit = "free_skip_limit"
        case freeDownloadLimit = "free_download_limit"
        case premiumEnabled = "premium_enabled"
        case lifetimeEnabled = "lifetime_enabled"
        case adsEnabled = "ads_enabled"
        case adsSkipFrequency = "ads_skip_frequency"
        case adsSectionInterval = "ads_section_interval"
        case adsSongInterval = "ads_song_interval"
        case termsOfServiceURL = "terms_of_service_url"
        case privacyPolicyURL = "privacy_policy_url"
    }

    init(
        freeSkipLimit: Int = 12,
        freeDownloadLimit: Int = 5,
        premiumEnabled: Bool = true,
        lifetimeEnabled: Bool = true,
        adsEnabled: Bool = false,
        adsSkipFrequency: Int = 4,
        adsSectionInterval: Int = 3,
        adsSongInterval: Int = 10,
        termsOfServiceURL: String = "",
        privacyPolicyURL: String = ""
    ) {
        self.freeSkipLimit = freeSkipLimit
        self.freeDownloadLimit = freeDownloadLimit
        self.premiumEnabled = premiumEnabled
        self.lifetimeEnabled = lifetimeEnabled
        self.adsEnabled = adsEnabled
        self.adsSkipFrequency = adsSkipFrequency
        self.adsSectionInterval = adsSectionInterval
        self.adsSongInterval = adsSongInterval
        self.termsOfServiceURL = termsOfServiceURL
        self.privacyPolicyURL = privacyPolicyURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.freeSkipLimit = try container.decodeIfPresent(Int.self, forKey: .freeSkipLimit) ?? Self.default.freeSkipLimit
        self.freeDownloadLimit = try container.decodeIfPresent(Int.self, forKey: .freeDownloadLimit) ?? Self.default.freeDownloadLimit
        self.premiumEnabled = try container.decodeIfPresent(Bool.self, forKey: .premiumEnabled) ?? Self.default.premiumEnabled
        self.lifetimeEnabled = try container.decodeIfPresent(Bool.self, forKey: .lifetimeEnabled) ?? Self.default.lifetimeEnabled
        self.adsEnabled = try container.decodeIfPresent(Bool.self, forKey: .adsEnabled) ?? Self.default.adsEnabled
        self.adsSkipFrequency = try container.decodeIfPresent(Int.self, forKey: .adsSkipFrequency) ?? Self.default.adsSkipFrequency
        self.adsSectionInterval = try container.decodeIfPresent(Int.self, forKey: .adsSectionInterval) ?? Self.default.adsSectionInterval
        self.adsSongInterval = try container.decodeIfPresent(Int.self, forKey: .adsSongInterval) ?? Self.default.adsSongInterval
        self.termsOfServiceURL = try container.decodeIfPresent(String.self, forKey: .termsOfServiceURL) ?? Self.default.termsOfServiceURL
        self.privacyPolicyURL = try container.decodeIfPresent(String.self, forKey: .privacyPolicyURL) ?? Self.default.privacyPolicyURL
    }
}

struct AudioBitrateConfig: Codable, Equatable, Sendable {
    var low: Int
    var medium: Int
    var high: Int

    static let `default` = AudioBitrateConfig(
        low: 64_000,
        medium: 128_000,
        high: 256_000
    )

    enum CodingKeys: String, CodingKey {
        case low = "bitrate_low"
        case medium = "bitrate_medium"
        case high = "bitrate_high"
    }

    init(
        low: Int = 64_000,
        medium: Int = 128_000,
        high: Int = 256_000
    ) {
        self.low = low
        self.medium = medium
        self.high = high
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.low = try container.decodeIfPresent(Int.self, forKey: .low) ?? Self.default.low
        self.medium = try container.decodeIfPresent(Int.self, forKey: .medium) ?? Self.default.medium
        self.high = try container.decodeIfPresent(Int.self, forKey: .high) ?? Self.default.high
    }
}

struct AnimationConfig: Codable, Equatable, Sendable {
    var bouncyResponse: Double
    var bouncyDamping: Double
    var smoothResponse: Double
    var smoothDamping: Double
    var playerResponse: Double
    var playerDamping: Double
    var gentleDuration: Double
    var crossfadeDuration: Double

    static let `default` = AnimationConfig(
        bouncyResponse: 0.3,
        bouncyDamping: 0.6,
        smoothResponse: 0.4,
        smoothDamping: 0.8,
        playerResponse: 0.5,
        playerDamping: 0.85,
        gentleDuration: 0.25,
        crossfadeDuration: 0.3
    )

    enum CodingKeys: String, CodingKey {
        case bouncyResponse = "bouncy_response"
        case bouncyDamping = "bouncy_damping"
        case smoothResponse = "smooth_response"
        case smoothDamping = "smooth_damping"
        case playerResponse = "player_response"
        case playerDamping = "player_damping"
        case gentleDuration = "gentle_duration"
        case crossfadeDuration = "crossfade_duration"
    }

    init(
        bouncyResponse: Double = 0.3,
        bouncyDamping: Double = 0.6,
        smoothResponse: Double = 0.4,
        smoothDamping: Double = 0.8,
        playerResponse: Double = 0.5,
        playerDamping: Double = 0.85,
        gentleDuration: Double = 0.25,
        crossfadeDuration: Double = 0.3
    ) {
        self.bouncyResponse = bouncyResponse
        self.bouncyDamping = bouncyDamping
        self.smoothResponse = smoothResponse
        self.smoothDamping = smoothDamping
        self.playerResponse = playerResponse
        self.playerDamping = playerDamping
        self.gentleDuration = gentleDuration
        self.crossfadeDuration = crossfadeDuration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.bouncyResponse = try container.decodeIfPresent(Double.self, forKey: .bouncyResponse) ?? Self.default.bouncyResponse
        self.bouncyDamping = try container.decodeIfPresent(Double.self, forKey: .bouncyDamping) ?? Self.default.bouncyDamping
        self.smoothResponse = try container.decodeIfPresent(Double.self, forKey: .smoothResponse) ?? Self.default.smoothResponse
        self.smoothDamping = try container.decodeIfPresent(Double.self, forKey: .smoothDamping) ?? Self.default.smoothDamping
        self.playerResponse = try container.decodeIfPresent(Double.self, forKey: .playerResponse) ?? Self.default.playerResponse
        self.playerDamping = try container.decodeIfPresent(Double.self, forKey: .playerDamping) ?? Self.default.playerDamping
        self.gentleDuration = try container.decodeIfPresent(Double.self, forKey: .gentleDuration) ?? Self.default.gentleDuration
        self.crossfadeDuration = try container.decodeIfPresent(Double.self, forKey: .crossfadeDuration) ?? Self.default.crossfadeDuration
    }
}

struct UIConfig: Codable, Equatable, Sendable {
    var homeMoodCarouselHeight: Double
    var homeMoodItemWidth: Double
    var homeMoodGridRowHeight: Double
    var scrollFastFadeDuringFling: Bool
    var scrollShimmerTimeoutEnabled: Bool

    static let `default` = UIConfig(
        homeMoodCarouselHeight: 110,
        homeMoodItemWidth: 180,
        homeMoodGridRowHeight: 48,
        scrollFastFadeDuringFling: true,
        scrollShimmerTimeoutEnabled: true
    )

    enum CodingKeys: String, CodingKey {
        case homeMoodCarouselHeight = "home_mood_carousel_height"
        case homeMoodItemWidth = "home_mood_item_width"
        case homeMoodGridRowHeight = "home_mood_grid_row_height"
        case scrollFastFadeDuringFling = "scroll_fast_fade_during_fling"
        case scrollShimmerTimeoutEnabled = "scroll_shimmer_timeout_enabled"
    }

    init(
        homeMoodCarouselHeight: Double = 110,
        homeMoodItemWidth: Double = 180,
        homeMoodGridRowHeight: Double = 48,
        scrollFastFadeDuringFling: Bool = true,
        scrollShimmerTimeoutEnabled: Bool = true
    ) {
        self.homeMoodCarouselHeight = homeMoodCarouselHeight
        self.homeMoodItemWidth = homeMoodItemWidth
        self.homeMoodGridRowHeight = homeMoodGridRowHeight
        self.scrollFastFadeDuringFling = scrollFastFadeDuringFling
        self.scrollShimmerTimeoutEnabled = scrollShimmerTimeoutEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.homeMoodCarouselHeight = try container.decodeIfPresent(Double.self, forKey: .homeMoodCarouselHeight) ?? Self.default.homeMoodCarouselHeight
        self.homeMoodItemWidth = try container.decodeIfPresent(Double.self, forKey: .homeMoodItemWidth) ?? Self.default.homeMoodItemWidth
        self.homeMoodGridRowHeight = try container.decodeIfPresent(Double.self, forKey: .homeMoodGridRowHeight) ?? Self.default.homeMoodGridRowHeight
        self.scrollFastFadeDuringFling = try container.decodeIfPresent(Bool.self, forKey: .scrollFastFadeDuringFling) ?? Self.default.scrollFastFadeDuringFling
        self.scrollShimmerTimeoutEnabled = try container.decodeIfPresent(Bool.self, forKey: .scrollShimmerTimeoutEnabled) ?? Self.default.scrollShimmerTimeoutEnabled
    }
}

struct AppUpdateConfig: Codable, Equatable, Sendable {
    var minRequiredVersion: String
    var recommendedVersion: String
    var forceUpdateMessage: String
    var appStoreURL: String
    var updateChangelog: String

    static let `default` = AppUpdateConfig(
        minRequiredVersion: "",
        recommendedVersion: "",
        forceUpdateMessage: "",
        appStoreURL: "",
        updateChangelog: ""
    )

    enum CodingKeys: String, CodingKey {
        case minRequiredVersion = "min_required_version"
        case recommendedVersion = "recommended_version"
        case forceUpdateMessage = "force_update_message"
        case appStoreURL = "app_store_url"
        case updateChangelog = "update_changelog"
    }

    init(
        minRequiredVersion: String = "",
        recommendedVersion: String = "",
        forceUpdateMessage: String = "",
        appStoreURL: String = "",
        updateChangelog: String = ""
    ) {
        self.minRequiredVersion = minRequiredVersion
        self.recommendedVersion = recommendedVersion
        self.forceUpdateMessage = forceUpdateMessage
        self.appStoreURL = appStoreURL
        self.updateChangelog = updateChangelog
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.minRequiredVersion = try container.decodeIfPresent(String.self, forKey: .minRequiredVersion) ?? Self.default.minRequiredVersion
        self.recommendedVersion = try container.decodeIfPresent(String.self, forKey: .recommendedVersion) ?? Self.default.recommendedVersion
        self.forceUpdateMessage = try container.decodeIfPresent(String.self, forKey: .forceUpdateMessage) ?? Self.default.forceUpdateMessage
        self.appStoreURL = try container.decodeIfPresent(String.self, forKey: .appStoreURL) ?? Self.default.appStoreURL
        self.updateChangelog = try container.decodeIfPresent(String.self, forKey: .updateChangelog) ?? Self.default.updateChangelog
    }
}

struct PlaybackRangeConfig: Codable, Equatable, Sendable {
    var rangeStreamingV1: Bool?
    var rangeStreamingCohortPercent: Int?
    var boundedPreloadV1: Bool?
    var rangeStreamingKillSwitch: Bool?
    var rangeStreamingKillSwitchEpoch: UInt64?
    var rangeLoaderPolicyVersion: Int?
    var rangeHeaderSchemaVersion: Int?

    static let failClosed = PlaybackRangeConfig(
        rangeStreamingV1: nil,
        rangeStreamingCohortPercent: nil,
        boundedPreloadV1: nil,
        rangeStreamingKillSwitch: nil,
        rangeStreamingKillSwitchEpoch: nil,
        rangeLoaderPolicyVersion: nil,
        rangeHeaderSchemaVersion: nil
    )

    var playbackFeatureSnapshot: PlaybackFeatureSnapshot {
        guard let rangeStreamingV1,
            let rangeStreamingCohortPercent,
            let boundedPreloadV1,
            let rangeStreamingKillSwitch,
            let rangeStreamingKillSwitchEpoch,
            let rangeLoaderPolicyVersion,
            rangeLoaderPolicyVersion > 0,
            let rangeHeaderSchemaVersion,
            rangeHeaderSchemaVersion > 0
        else {
            return .failClosed
        }

        return PlaybackFeatureSnapshot(
            rangeStreamingV1: rangeStreamingV1,
            cohortPercent: min(max(rangeStreamingCohortPercent, 0), 100),
            boundedPreloadV1: boundedPreloadV1,
            killSwitch: rangeStreamingKillSwitch,
            killSwitchEpoch: rangeStreamingKillSwitchEpoch,
            loaderVersion: rangeLoaderPolicyVersion,
            headerSchemaVersion: rangeHeaderSchemaVersion
        )
    }

    enum CodingKeys: String, CodingKey {
        case rangeStreamingV1 = "range_streaming_v1"
        case rangeStreamingCohortPercent = "range_streaming_cohort_percent"
        case boundedPreloadV1 = "bounded_preload_v1"
        case rangeStreamingKillSwitch = "range_streaming_kill_switch"
        case rangeStreamingKillSwitchEpoch = "range_streaming_kill_switch_epoch"
        case rangeLoaderPolicyVersion = "range_loader_policy_version"
        case rangeHeaderSchemaVersion = "range_header_schema_version"
    }
}

// MARK: - Dynamic Editorial, Announcement & Seasonal Models

struct EditorialConfig: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var featuredPlaylists: [FeaturedPlaylistItem]

    static let `default` = EditorialConfig(isEnabled: false, featuredPlaylists: [])

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case featuredPlaylists = "featured_playlists"
    }

    init(isEnabled: Bool = false, featuredPlaylists: [FeaturedPlaylistItem] = []) {
        self.isEnabled = isEnabled
        self.featuredPlaylists = featuredPlaylists
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        self.featuredPlaylists = try container.decodeIfPresent([FeaturedPlaylistItem].self, forKey: .featuredPlaylists) ?? []
    }
}

struct FeaturedPlaylistItem: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var subtitle: String
    var playlistId: String
    var thumbnailURL: String
    var badgeText: String

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case subtitle
        case playlistId = "playlist_id"
        case thumbnailURL = "thumbnail_url"
        case badgeText = "badge_text"
    }

    init(
        id: String,
        title: String,
        subtitle: String = "",
        playlistId: String,
        thumbnailURL: String = "",
        badgeText: String = ""
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.playlistId = playlistId
        self.thumbnailURL = thumbnailURL
        self.badgeText = badgeText
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        self.playlistId = try container.decodeIfPresent(String.self, forKey: .playlistId) ?? ""
        self.thumbnailURL = try container.decodeIfPresent(String.self, forKey: .thumbnailURL) ?? ""
        self.badgeText = try container.decodeIfPresent(String.self, forKey: .badgeText) ?? ""
    }
}

struct AnnouncementItem: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var isActive: Bool
    var level: String // "info", "warning", "critical"
    var message: String
    var actionTitle: String
    var actionURL: String

    enum CodingKeys: String, CodingKey {
        case id
        case isActive = "is_active"
        case level
        case message
        case actionTitle = "action_title"
        case actionURL = "action_url"
    }

    init(
        id: String,
        isActive: Bool = false,
        level: String = "info",
        message: String = "",
        actionTitle: String = "",
        actionURL: String = ""
    ) {
        self.id = id
        self.isActive = isActive
        self.level = level
        self.message = message
        self.actionTitle = actionTitle
        self.actionURL = actionURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
        self.level = try container.decodeIfPresent(String.self, forKey: .level) ?? "info"
        self.message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        self.actionTitle = try container.decodeIfPresent(String.self, forKey: .actionTitle) ?? ""
        self.actionURL = try container.decodeIfPresent(String.self, forKey: .actionURL) ?? ""
    }
}

struct ThemeScheduleItem: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var priority: Int
    var startDate: String? // "MM-dd" (recurring) or "yyyy-MM-dd" (specific year)
    var endDate: String?   // "MM-dd" (recurring) or "yyyy-MM-dd" (specific year)
    var timeRange: String? // "HH:mm-HH:mm", e.g. "05:00-11:59" or "23:00-04:59"
    var theme: SeasonalThemeConfig

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case priority
        case startDate = "start_date"
        case endDate = "end_date"
        case timeRange = "time_range"
        case theme
    }

    init(
        id: String = UUID().uuidString,
        title: String = "",
        priority: Int = 0,
        startDate: String? = nil,
        endDate: String? = nil,
        timeRange: String? = nil,
        theme: SeasonalThemeConfig
    ) {
        self.id = id
        self.title = title
        self.priority = priority
        self.startDate = startDate
        self.endDate = endDate
        self.timeRange = timeRange
        self.theme = theme
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        self.startDate = try container.decodeIfPresent(String.self, forKey: .startDate)
        self.endDate = try container.decodeIfPresent(String.self, forKey: .endDate)
        self.timeRange = try container.decodeIfPresent(String.self, forKey: .timeRange)
        self.theme = try container.decodeIfPresent(SeasonalThemeConfig.self, forKey: .theme) ?? .default
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(priority, forKey: .priority)
        try container.encodeIfPresent(startDate, forKey: .startDate)
        try container.encodeIfPresent(endDate, forKey: .endDate)
        try container.encodeIfPresent(timeRange, forKey: .timeRange)
        try container.encode(theme, forKey: .theme)
    }

    func matches(date: Date, calendar: Calendar = .current) -> Bool {
        guard theme.isEnabled else { return false }

        // 1. Date Check
        if let startDate, let endDate {
            if !matchesDateRange(date: date, startStr: startDate, endStr: endDate, calendar: calendar) {
                return false
            }
        } else if let startDate {
            if !matchesStartDateOnly(date: date, startStr: startDate, calendar: calendar) {
                return false
            }
        } else if let endDate {
            if !matchesEndDateOnly(date: date, endStr: endDate, calendar: calendar) {
                return false
            }
        }

        // 2. Time Check
        if let timeRange, !timeRange.isEmpty {
            if !matchesTimeRange(date: date, rangeStr: timeRange, calendar: calendar) {
                return false
            }
        }

        return true
    }

    private func matchesDateRange(date: Date, startStr: String, endStr: String, calendar: Calendar) -> Bool {
        let startParts = startStr.split(separator: "-").compactMap { Int($0) }
        let endParts = endStr.split(separator: "-").compactMap { Int($0) }

        // yyyy-MM-dd
        if startParts.count == 3 && endParts.count == 3 {
            var startComps = DateComponents(year: startParts[0], month: startParts[1], day: startParts[2], hour: 0, minute: 0, second: 0)
            var endComps = DateComponents(year: endParts[0], month: endParts[1], day: endParts[2], hour: 23, minute: 59, second: 59)
            startComps.calendar = calendar
            endComps.calendar = calendar
            guard let startDate = calendar.date(from: startComps),
                  let endDate = calendar.date(from: endComps) else { return false }
            return date >= startDate && date <= endDate
        }

        // MM-dd recurring
        if startParts.count >= 2 && endParts.count >= 2 {
            let startM = startParts[0], startD = startParts[1]
            let endM = endParts[0], endD = endParts[1]
            let currentM = calendar.component(.month, from: date)
            let currentD = calendar.component(.day, from: date)

            let currentVal = currentM * 100 + currentD
            let startVal = startM * 100 + startD
            let endVal = endM * 100 + endD

            if startVal <= endVal {
                return currentVal >= startVal && currentVal <= endVal
            } else {
                // Crosses year boundary (e.g. 12-25 to 01-05)
                return currentVal >= startVal || currentVal <= endVal
            }
        }

        return false
    }

    private func matchesStartDateOnly(date: Date, startStr: String, calendar: Calendar) -> Bool {
        let startParts = startStr.split(separator: "-").compactMap { Int($0) }
        if startParts.count == 3 {
            var startComps = DateComponents(year: startParts[0], month: startParts[1], day: startParts[2], hour: 0, minute: 0, second: 0)
            startComps.calendar = calendar
            guard let startDate = calendar.date(from: startComps) else { return false }
            return date >= startDate
        }
        if startParts.count >= 2 {
            let startVal = startParts[0] * 100 + startParts[1]
            let currentVal = calendar.component(.month, from: date) * 100 + calendar.component(.day, from: date)
            return currentVal >= startVal
        }
        return false
    }

    private func matchesEndDateOnly(date: Date, endStr: String, calendar: Calendar) -> Bool {
        let endParts = endStr.split(separator: "-").compactMap { Int($0) }
        if endParts.count == 3 {
            var endComps = DateComponents(year: endParts[0], month: endParts[1], day: endParts[2], hour: 23, minute: 59, second: 59)
            endComps.calendar = calendar
            guard let endDate = calendar.date(from: endComps) else { return false }
            return date <= endDate
        }
        if endParts.count >= 2 {
            let endVal = endParts[0] * 100 + endParts[1]
            let currentVal = calendar.component(.month, from: date) * 100 + calendar.component(.day, from: date)
            return currentVal <= endVal
        }
        return false
    }

    private func matchesTimeRange(date: Date, rangeStr: String, calendar: Calendar) -> Bool {
        let parts = rangeStr.split(separator: "-")
        guard parts.count == 2 else { return true }
        let startSub = parts[0].split(separator: ":").compactMap { Int($0) }
        let endSub = parts[1].split(separator: ":").compactMap { Int($0) }
        guard startSub.count == 2, endSub.count == 2 else { return true }

        let startMin = startSub[0] * 60 + startSub[1]
        let endMin = endSub[0] * 60 + endSub[1]
        let curMin = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)

        if startMin <= endMin {
            return curMin >= startMin && curMin <= endMin
        } else {
            // Overnight range (e.g. 23:00 to 04:59)
            return curMin >= startMin || curMin <= endMin
        }
    }
}

struct SeasonalThemeConfig: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var themeName: String
    var badgeText: String
    var iconName: String
    var accentColorLight: String
    var accentColorDark: String
    var backgroundGradientLight: [String]
    var backgroundGradientDark: [String]
    var cardGradientLight: [String]
    var cardGradientDark: [String]
    var bannerTitle: String
    var bannerSubtitle: String
    var bannerImageURL: String
    var showAmbientParticles: Bool
    var particleDurationSeconds: Double
    var particleSpeedMultiplier: Double
    var particleCount: Int
    var schedules: [ThemeScheduleItem]

    static let `default` = SeasonalThemeConfig(
        isEnabled: false,
        themeName: "",
        badgeText: "",
        iconName: "",
        accentColorLight: "",
        accentColorDark: "",
        backgroundGradientLight: [],
        backgroundGradientDark: [],
        cardGradientLight: [],
        cardGradientDark: [],
        bannerTitle: "",
        bannerSubtitle: "",
        bannerImageURL: "",
        showAmbientParticles: true,
        particleDurationSeconds: 0,
        particleSpeedMultiplier: 1.0,
        particleCount: 18,
        schedules: []
    )

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case themeName = "theme_name"
        case badgeText = "badge_text"
        case iconName = "icon_name"
        case accentColorLight = "accent_color_light"
        case accentColorDark = "accent_color_dark"
        case accentColorHex = "accent_color_hex"
        case backgroundGradientLight = "background_gradient_light"
        case backgroundGradientDark = "background_gradient_dark"
        case backgroundGradientHex = "background_gradient_hex"
        case cardGradientLight = "card_gradient_light"
        case cardGradientDark = "card_gradient_dark"
        case bannerTitle = "banner_title"
        case bannerSubtitle = "banner_subtitle"
        case bannerImageURL = "banner_image_url"
        case showAmbientParticles = "show_ambient_particles"
        case particleDurationSeconds = "particle_duration_seconds"
        case particleSpeedMultiplier = "particle_speed_multiplier"
        case particleCount = "particle_count"
        case schedules
    }

    init(
        isEnabled: Bool = false,
        themeName: String = "",
        badgeText: String = "",
        iconName: String = "",
        accentColorLight: String = "",
        accentColorDark: String = "",
        backgroundGradientLight: [String] = [],
        backgroundGradientDark: [String] = [],
        cardGradientLight: [String] = [],
        cardGradientDark: [String] = [],
        bannerTitle: String = "",
        bannerSubtitle: String = "",
        bannerImageURL: String = "",
        showAmbientParticles: Bool = true,
        particleDurationSeconds: Double = 0,
        particleSpeedMultiplier: Double = 1.0,
        particleCount: Int = 18,
        schedules: [ThemeScheduleItem] = []
    ) {
        self.isEnabled = isEnabled
        self.themeName = themeName
        self.badgeText = badgeText
        self.iconName = iconName
        self.accentColorLight = accentColorLight
        self.accentColorDark = accentColorDark
        self.backgroundGradientLight = backgroundGradientLight
        self.backgroundGradientDark = backgroundGradientDark
        self.cardGradientLight = cardGradientLight
        self.cardGradientDark = cardGradientDark
        self.bannerTitle = bannerTitle
        self.bannerSubtitle = bannerSubtitle
        self.bannerImageURL = bannerImageURL
        self.showAmbientParticles = showAmbientParticles
        self.particleDurationSeconds = particleDurationSeconds
        self.particleSpeedMultiplier = particleSpeedMultiplier
        self.particleCount = particleCount
        self.schedules = schedules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        self.themeName = try container.decodeIfPresent(String.self, forKey: .themeName) ?? ""
        self.badgeText = try container.decodeIfPresent(String.self, forKey: .badgeText) ?? ""
        self.iconName = try container.decodeIfPresent(String.self, forKey: .iconName) ?? ""
        let legacyAccent = try container.decodeIfPresent(String.self, forKey: .accentColorHex) ?? ""
        self.accentColorLight = try container.decodeIfPresent(String.self, forKey: .accentColorLight) ?? legacyAccent
        self.accentColorDark = try container.decodeIfPresent(String.self, forKey: .accentColorDark) ?? legacyAccent
        let legacyBg = try container.decodeIfPresent([String].self, forKey: .backgroundGradientHex) ?? []
        self.backgroundGradientLight = try container.decodeIfPresent([String].self, forKey: .backgroundGradientLight) ?? []
        self.backgroundGradientDark = try container.decodeIfPresent([String].self, forKey: .backgroundGradientDark) ?? legacyBg
        self.cardGradientLight = try container.decodeIfPresent([String].self, forKey: .cardGradientLight) ?? []
        self.cardGradientDark = try container.decodeIfPresent([String].self, forKey: .cardGradientDark) ?? []
        self.bannerTitle = try container.decodeIfPresent(String.self, forKey: .bannerTitle) ?? ""
        self.bannerSubtitle = try container.decodeIfPresent(String.self, forKey: .bannerSubtitle) ?? ""
        self.bannerImageURL = try container.decodeIfPresent(String.self, forKey: .bannerImageURL) ?? ""
        self.showAmbientParticles = try container.decodeIfPresent(Bool.self, forKey: .showAmbientParticles) ?? true
        self.particleDurationSeconds = try container.decodeIfPresent(Double.self, forKey: .particleDurationSeconds) ?? 0
        self.particleSpeedMultiplier = try container.decodeIfPresent(Double.self, forKey: .particleSpeedMultiplier) ?? 1.0
        self.particleCount = try container.decodeIfPresent(Int.self, forKey: .particleCount) ?? 18
        self.schedules = try container.decodeIfPresent([ThemeScheduleItem].self, forKey: .schedules) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(themeName, forKey: .themeName)
        try container.encode(badgeText, forKey: .badgeText)
        try container.encode(iconName, forKey: .iconName)
        try container.encode(accentColorLight, forKey: .accentColorLight)
        try container.encode(accentColorDark, forKey: .accentColorDark)
        try container.encode(backgroundGradientLight, forKey: .backgroundGradientLight)
        try container.encode(backgroundGradientDark, forKey: .backgroundGradientDark)
        try container.encode(cardGradientLight, forKey: .cardGradientLight)
        try container.encode(cardGradientDark, forKey: .cardGradientDark)
        try container.encode(bannerTitle, forKey: .bannerTitle)
        try container.encode(bannerSubtitle, forKey: .bannerSubtitle)
        try container.encode(bannerImageURL, forKey: .bannerImageURL)
        try container.encode(showAmbientParticles, forKey: .showAmbientParticles)
        try container.encode(particleDurationSeconds, forKey: .particleDurationSeconds)
        try container.encode(particleSpeedMultiplier, forKey: .particleSpeedMultiplier)
        try container.encode(particleCount, forKey: .particleCount)
        try container.encode(schedules, forKey: .schedules)
    }

    /// Resolves the currently active theme according to local time schedules.
    /// Schedules are evaluated by `priority` (highest first). If none match, falls back to `self`.
    func resolveActiveTheme(at date: Date = Date(), calendar: Calendar = .current) -> SeasonalThemeConfig {
        guard isEnabled else { return self }
        if schedules.isEmpty { return self }

        let sorted = schedules.sorted { $0.priority > $1.priority }
        for schedule in sorted {
            if schedule.matches(date: date, calendar: calendar) {
                return schedule.theme
            }
        }
        return self
    }

    /// Computes the next date/time at which a schedule state transition might occur.
    func nextTransitionDate(from date: Date = Date(), calendar: Calendar = .current) -> Date? {
        guard isEnabled, !schedules.isEmpty else { return nil }

        var candidates: [Date] = []
        let currentYear = calendar.component(.year, from: date)

        for schedule in schedules {
            // Time range boundaries (daily)
            if let timeRange = schedule.timeRange {
                let parts = timeRange.split(separator: "-")
                if parts.count == 2 {
                    let startSub = parts[0].split(separator: ":").compactMap { Int($0) }
                    let endSub = parts[1].split(separator: ":").compactMap { Int($0) }
                    if startSub.count == 2 {
                        if let startToday = calendar.date(bySettingHour: startSub[0], minute: startSub[1], second: 0, of: date) {
                            if startToday > date {
                                candidates.append(startToday)
                            } else if let startTomorrow = calendar.date(byAdding: .day, value: 1, to: startToday) {
                                candidates.append(startTomorrow)
                            }
                        }
                    }
                    if endSub.count == 2 {
                        if let endToday = calendar.date(bySettingHour: endSub[0], minute: endSub[1], second: 59, of: date)?.addingTimeInterval(1) {
                            if endToday > date {
                                candidates.append(endToday)
                            } else if let endTomorrow = calendar.date(byAdding: .day, value: 1, to: endToday) {
                                candidates.append(endTomorrow)
                            }
                        }
                    }
                }
            }

            // Date boundaries
            if let startDate = schedule.startDate {
                let parts = startDate.split(separator: "-").compactMap { Int($0) }
                if parts.count == 3 {
                    // yyyy-MM-dd
                    let comps = DateComponents(calendar: calendar, year: parts[0], month: parts[1], day: parts[2], hour: 0, minute: 0, second: 0)
                    if let d = comps.date, d > date { candidates.append(d) }
                } else if parts.count >= 2 {
                    // MM-dd
                    for year in [currentYear, currentYear + 1] {
                        let comps = DateComponents(calendar: calendar, year: year, month: parts[0], day: parts[1], hour: 0, minute: 0, second: 0)
                        if let d = comps.date, d > date { candidates.append(d) }
                    }
                }
            }

            if let endDate = schedule.endDate {
                let parts = endDate.split(separator: "-").compactMap { Int($0) }
                if parts.count == 3 {
                    // yyyy-MM-dd (transition is end of day + 1s)
                    let comps = DateComponents(calendar: calendar, year: parts[0], month: parts[1], day: parts[2], hour: 23, minute: 59, second: 59)
                    if let d = comps.date?.addingTimeInterval(1), d > date { candidates.append(d) }
                } else if parts.count >= 2 {
                    // MM-dd
                    for year in [currentYear, currentYear + 1] {
                        let comps = DateComponents(calendar: calendar, year: year, month: parts[0], day: parts[1], hour: 23, minute: 59, second: 59)
                        if let d = comps.date?.addingTimeInterval(1), d > date { candidates.append(d) }
                    }
                }
            }
        }

        return candidates.filter { $0 > date }.min()
    }
}

struct PaywallPromoConfig: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var badgeText: String
    var headline: String
    var subheadline: String
    var highlightedProductId: String

    static let `default` = PaywallPromoConfig(
        isEnabled: false,
        badgeText: "",
        headline: "",
        subheadline: "",
        highlightedProductId: ""
    )

    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case badgeText = "badge_text"
        case headline
        case subheadline
        case highlightedProductId = "highlighted_product_id"
    }

    init(
        isEnabled: Bool = false,
        badgeText: String = "",
        headline: String = "",
        subheadline: String = "",
        highlightedProductId: String = ""
    ) {
        self.isEnabled = isEnabled
        self.badgeText = badgeText
        self.headline = headline
        self.subheadline = subheadline
        self.highlightedProductId = highlightedProductId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        self.badgeText = try container.decodeIfPresent(String.self, forKey: .badgeText) ?? ""
        self.headline = try container.decodeIfPresent(String.self, forKey: .headline) ?? ""
        self.subheadline = try container.decodeIfPresent(String.self, forKey: .subheadline) ?? ""
        self.highlightedProductId = try container.decodeIfPresent(String.self, forKey: .highlightedProductId) ?? ""
    }
}

// MARK: - Dual-Decoding MicroCMS Payload

/// Decodes from MicroCMS (either modern `config_json` string or 35 legacy flat fields).
private struct RemoteConfigPayload: Codable {
    let configJson: String?

    // Legacy flat fields
    let rangeStreamingV1: Bool?
    let rangeStreamingCohortPercent: Int?
    let boundedPreloadV1: Bool?
    let rangeStreamingKillSwitch: Bool?
    let rangeStreamingKillSwitchEpoch: UInt64?
    let rangeLoaderPolicyVersion: Int?
    let rangeHeaderSchemaVersion: Int?
    let downloadEnabled: Bool?
    let youtubeAuthEnabled: Bool?
    let videoPlaybackEnabled: Bool?
    let devModeEnabled: Bool?
    let appearanceSettingsEnabled: Bool?
    let reviewModeEnabled: Bool?
    let homeContinuationDrainEnabled: Bool?
    let minRequiredVersion: String?
    let forceUpdateMessage: String?
    let appStoreURL: String?
    let recommendedVersion: String?
    let updateChangelog: String?
    let freeSkipLimit: Int?
    let freeDownloadLimit: Int?
    let premiumEnabled: Bool?
    let lifetimeEnabled: Bool?
    let termsOfServiceURL: String?
    let privacyPolicyURL: String?
    let audioBitrateLow: Int?
    let audioBitrateMedium: Int?
    let audioBitrateHigh: Int?
    let animationBouncyResponse: Double?
    let animationBouncyDamping: Double?
    let animationSmoothResponse: Double?
    let animationSmoothDamping: Double?
    let animationPlayerResponse: Double?
    let animationPlayerDamping: Double?
    let animationGentleDuration: Double?
    let animationCrossfadeDuration: Double?
    let homeMoodCarouselHeight: Double?
    let homeMoodItemWidth: Double?
    let homeMoodGridRowHeight: Double?
    let scrollFastFadeDuringFling: Bool?
    let scrollShimmerTimeoutEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case configJson = "config_json"
        case rangeStreamingV1 = "range_streaming_v1"
        case rangeStreamingCohortPercent = "range_streaming_cohort_percent"
        case boundedPreloadV1 = "bounded_preload_v1"
        case rangeStreamingKillSwitch = "range_streaming_kill_switch"
        case rangeStreamingKillSwitchEpoch = "range_streaming_kill_switch_epoch"
        case rangeLoaderPolicyVersion = "range_loader_policy_version"
        case rangeHeaderSchemaVersion = "range_header_schema_version"
        case downloadEnabled = "download_enabled"
        case youtubeAuthEnabled = "youtube_auth_enabled"
        case videoPlaybackEnabled = "video_playbacktoggle"
        case devModeEnabled = "dev_mode_enabled"
        case appearanceSettingsEnabled = "appearance_settings"
        case reviewModeEnabled = "review_mode_enabled"
        case homeContinuationDrainEnabled = "home_continuation_drain_enabled"
        case minRequiredVersion = "min_required_version"
        case forceUpdateMessage = "force_update_message"
        case appStoreURL = "app_store_url"
        case recommendedVersion = "recommended_version"
        case updateChangelog = "update_changelog"
        case freeSkipLimit = "free_skip_limit"
        case freeDownloadLimit = "free_download_limit"
        case premiumEnabled = "premium_enabled"
        case lifetimeEnabled = "lifetime_enabled"
        case termsOfServiceURL = "terms_of_service_url"
        case privacyPolicyURL = "privacy_policy_url"
        case audioBitrateLow = "audio_bitrate_low"
        case audioBitrateMedium = "audio_bitrate_medium"
        case audioBitrateHigh = "audio_bitrate_high"
        case animationBouncyResponse = "anim_bouncy_response"
        case animationBouncyDamping = "anim_bouncy_damping"
        case animationSmoothResponse = "anim_smooth_response"
        case animationSmoothDamping = "anim_smooth_damping"
        case animationPlayerResponse = "anim_player_response"
        case animationPlayerDamping = "anim_player_damping"
        case animationGentleDuration = "anim_gentle_duration"
        case animationCrossfadeDuration = "anim_fade_duration"
        case homeMoodCarouselHeight = "home_m_carousel_heig"
        case homeMoodItemWidth = "home_mood_item_width"
        case homeMoodGridRowHeight = "home_m_grid_row_heig"
        case scrollFastFadeDuringFling = "scroll_fast_fade_fling"
        case scrollShimmerTimeoutEnabled = "scroll_shimmer_timeout"
    }

    func resolveConfig() -> AppRemoteConfig {
        if let configJson,
           let data = configJson.data(using: .utf8),
           let structured = try? JSONDecoder().decode(AppRemoteConfig.self, from: data) {
            return structured
        }

        // Fallback to legacy flat fields
        return AppRemoteConfig(
            toggles: TogglesConfig(
                downloadEnabled: downloadEnabled ?? false,
                youtubeAuthEnabled: youtubeAuthEnabled ?? {
                    #if DEBUG || STAGING
                    return true
                    #else
                    return false
                    #endif
                }(),
                videoPlaybackEnabled: videoPlaybackEnabled ?? true,
                devModeEnabled: devModeEnabled ?? false,
                appearanceSettingsEnabled: appearanceSettingsEnabled ?? false,
                reviewModeEnabled: reviewModeEnabled ?? false,
                homeContinuationDrainEnabled: homeContinuationDrainEnabled ?? false
            ),
            monetization: MonetizationConfig(
                freeSkipLimit: freeSkipLimit ?? 12,
                freeDownloadLimit: freeDownloadLimit ?? 5,
                premiumEnabled: premiumEnabled ?? true,
                lifetimeEnabled: lifetimeEnabled ?? true,
                adsEnabled: false,
                adsSkipFrequency: 4,
                adsSectionInterval: 3,
                adsSongInterval: 10,
                termsOfServiceURL: termsOfServiceURL ?? "",
                privacyPolicyURL: privacyPolicyURL ?? ""
            ),
            audio: AudioBitrateConfig(
                low: audioBitrateLow ?? 64_000,
                medium: audioBitrateMedium ?? 128_000,
                high: audioBitrateHigh ?? 256_000
            ),
            animations: AnimationConfig(
                bouncyResponse: animationBouncyResponse ?? 0.3,
                bouncyDamping: animationBouncyDamping ?? 0.6,
                smoothResponse: animationSmoothResponse ?? 0.4,
                smoothDamping: animationSmoothDamping ?? 0.8,
                playerResponse: animationPlayerResponse ?? 0.5,
                playerDamping: animationPlayerDamping ?? 0.85,
                gentleDuration: animationGentleDuration ?? 0.25,
                crossfadeDuration: animationCrossfadeDuration ?? 0.3
            ),
            ui: UIConfig(
                homeMoodCarouselHeight: homeMoodCarouselHeight ?? 110,
                homeMoodItemWidth: homeMoodItemWidth ?? 180,
                homeMoodGridRowHeight: homeMoodGridRowHeight ?? 48,
                scrollFastFadeDuringFling: scrollFastFadeDuringFling ?? true,
                scrollShimmerTimeoutEnabled: scrollShimmerTimeoutEnabled ?? true
            ),
            update: AppUpdateConfig(
                minRequiredVersion: minRequiredVersion ?? "",
                recommendedVersion: recommendedVersion ?? "",
                forceUpdateMessage: forceUpdateMessage ?? "",
                appStoreURL: appStoreURL ?? "",
                updateChangelog: updateChangelog ?? ""
            ),
            playbackRange: PlaybackRangeConfig(
                rangeStreamingV1: rangeStreamingV1,
                rangeStreamingCohortPercent: rangeStreamingCohortPercent,
                boundedPreloadV1: boundedPreloadV1,
                rangeStreamingKillSwitch: rangeStreamingKillSwitch,
                rangeStreamingKillSwitchEpoch: rangeStreamingKillSwitchEpoch,
                rangeLoaderPolicyVersion: rangeLoaderPolicyVersion,
                rangeHeaderSchemaVersion: rangeHeaderSchemaVersion
            ),
            editorial: .default,
            announcements: [],
            seasonalTheme: .default,
            paywallPromo: .default
        )
    }
}
