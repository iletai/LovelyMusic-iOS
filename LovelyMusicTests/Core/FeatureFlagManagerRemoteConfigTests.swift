import XCTest

@testable import LovelyMusic

@MainActor
final class FeatureFlagManagerRemoteConfigTests: XCTestCase {

    private let cacheKey = "feature_flags_cache"
    private var testDefaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        let suiteName = "test_remote_\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
        testDefaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() async throws {
        if let suiteName = testDefaults.volatileDomainNames.first {
            testDefaults.removePersistentDomain(forName: suiteName)
        }
        testDefaults = nil
        try await super.tearDown()
    }

    // MARK: - Modern Stringified JSON (`config_json`)

    func testApplyConfigFromJsonStringDecodesCorrectly() {
        let nestedJson = """
        {
            "$schema_version": 1,
            "toggles": {
                "download_enabled": true,
                "youtube_auth_enabled": true,
                "video_playback_enabled": false,
                "dev_mode_enabled": true,
                "appearance_settings_enabled": true,
                "review_mode_enabled": false,
                "home_continuation_drain_enabled": true
            },
            "monetization": {
                "free_skip_limit": 20,
                "free_download_limit": 10,
                "premium_enabled": true,
                "lifetime_enabled": false,
                "ads_enabled": true,
                "ads_skip_frequency": 2,
                "ads_section_interval": 4,
                "ads_song_interval": 8,
                "terms_of_service_url": "https://example.com/terms",
                "privacy_policy_url": "https://example.com/privacy"
            },
            "audio": {
                "bitrate_low": 48000,
                "bitrate_medium": 96000,
                "bitrate_high": 320000
            },
            "animations": {
                "bouncy_response": 0.5,
                "bouncy_damping": 0.7,
                "smooth_response": 0.6,
                "smooth_damping": 0.9,
                "player_response": 0.8,
                "player_damping": 0.95,
                "gentle_duration": 0.35,
                "crossfade_duration": 0.45
            },
            "ui": {
                "home_mood_carousel_height": 140.0,
                "home_mood_item_width": 200.0,
                "home_mood_grid_row_height": 56.0,
                "scroll_fast_fade_during_fling": false,
                "scroll_shimmer_timeout_enabled": false
            },
            "update": {
                "min_required_version": "2.0.0",
                "recommended_version": "2.1.0",
                "force_update_message": "Please update",
                "app_store_url": "https://example.com/app",
                "update_changelog": "Major new release"
            },
            "playback_range": {
                "range_streaming_v1": true,
                "range_streaming_cohort_percent": 50,
                "bounded_preload_v1": true,
                "range_streaming_kill_switch": false,
                "range_streaming_kill_switch_epoch": 123456789,
                "range_loader_policy_version": 2,
                "range_header_schema_version": 2
            },
            "editorial": {
                "is_enabled": true,
                "featured_playlists": [
                    {
                        "id": "autumn_01",
                        "title": "Autumn Chill",
                        "subtitle": "Warm beats",
                        "playlist_id": "PL_12345",
                        "badge_text": "FEATURED"
                    }
                ]
            },
            "announcements": [
                {
                    "id": "notice_01",
                    "is_active": true,
                    "level": "warning",
                    "message": "Maintenance tonight",
                    "action_title": "Details",
                    "action_url": "https://example.com/notice"
                }
            ],
            "seasonal_theme": {
                "is_enabled": true,
                "theme_name": "autumn",
                "accent_color_light": "#C2410C",
                "accent_color_dark": "#FB923C",
                "background_gradient_light": ["#FFF7ED", "#FEF3C7"],
                "background_gradient_dark": ["#1C0E07", "#120B04"],
                "card_gradient_light": ["#FFEDD5", "#FDE68A"],
                "card_gradient_dark": ["#2E170C", "#211407"],
                "banner_title": "Autumn Melodies",
                "banner_subtitle": "Warm coffee and soothing acoustic vibes",
                "show_ambient_particles": true
            },
            "paywall_promo": {
                "is_enabled": true,
                "badge_text": "50% OFF",
                "headline": "Special Promo",
                "subheadline": "Limited time",
                "highlighted_product_id": "com.lovelymusic.lifetime"
            }
        }
        """

        let payload: [String: Any] = [
            "config_json": nestedJson
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)

        let manager = FeatureFlagManager(defaults: testDefaults)
        let result = manager.applyRemoteConfigData(data)

        XCTAssertTrue(result)
        XCTAssertTrue(manager.isDownloadEnabled)
        XCTAssertTrue(manager.isYouTubeAuthEnabled)
        XCTAssertFalse(manager.isVideoPlaybackEnabled)
        XCTAssertTrue(manager.isDevModeEnabled)
        XCTAssertTrue(manager.isAppearanceSettingsEnabled)
        XCTAssertFalse(manager.isReviewModeEnabled)
        XCTAssertTrue(manager.isHomeContinuationDrainEnabled)

        XCTAssertEqual(manager.freeSkipLimit, 20)
        XCTAssertEqual(manager.freeDownloadLimit, 10)
        XCTAssertTrue(manager.isPremiumEnabled)
        XCTAssertFalse(manager.isLifetimeEnabled)
        XCTAssertTrue(manager.isAdsEnabled)
        XCTAssertEqual(manager.adsSkipFrequency, 2)
        XCTAssertEqual(manager.adsSectionInterval, 4)
        XCTAssertEqual(manager.adsSongInterval, 8)
        XCTAssertEqual(manager.termsOfServiceURL, "https://example.com/terms")
        XCTAssertEqual(manager.privacyPolicyURL, "https://example.com/privacy")

        XCTAssertEqual(manager.audioBitrateLow, 48000)
        XCTAssertEqual(manager.audioBitrateMedium, 96000)
        XCTAssertEqual(manager.audioBitrateHigh, 320000)

        XCTAssertEqual(manager.animationBouncyResponse, 0.5)
        XCTAssertEqual(manager.animationBouncyDamping, 0.7)
        XCTAssertEqual(manager.homeMoodCarouselHeight, 140.0)
        XCTAssertEqual(manager.homeMoodItemWidth, 200.0)
        XCTAssertEqual(manager.homeMoodGridRowHeight, 56.0)
        XCTAssertFalse(manager.scrollFastFadeDuringFling)
        XCTAssertFalse(manager.scrollShimmerTimeoutEnabled)

        XCTAssertEqual(manager.minRequiredVersion, "2.0.0")
        XCTAssertEqual(manager.recommendedVersion, "2.1.0")
        XCTAssertEqual(manager.forceUpdateMessage, "Please update")
        XCTAssertEqual(manager.appStoreURL, "https://example.com/app")
        XCTAssertEqual(manager.updateChangelog, "Major new release")

        let snapshot = manager.playbackControls
        XCTAssertTrue(snapshot.rangeStreamingV1)
        XCTAssertEqual(snapshot.cohortPercent, 50)
        XCTAssertTrue(snapshot.boundedPreloadV1)
        XCTAssertFalse(snapshot.killSwitch)
        XCTAssertEqual(snapshot.killSwitchEpoch, 123456789)
        XCTAssertEqual(snapshot.loaderVersion, 2)
        XCTAssertEqual(snapshot.headerSchemaVersion, 2)

        // Editorial & Dynamic Modules
        XCTAssertTrue(manager.isEditorialEnabled)
        XCTAssertEqual(manager.editorial.featuredPlaylists.count, 1)
        XCTAssertEqual(manager.editorial.featuredPlaylists.first?.title, "Autumn Chill")
        XCTAssertEqual(manager.editorial.featuredPlaylists.first?.playlistId, "PL_12345")

        XCTAssertNotNil(manager.activeAnnouncement)
        XCTAssertEqual(manager.activeAnnouncement?.message, "Maintenance tonight")
        XCTAssertEqual(manager.activeAnnouncement?.level, "warning")

        XCTAssertTrue(manager.seasonalTheme.isEnabled)
        XCTAssertEqual(manager.seasonalTheme.themeName, "autumn")
        XCTAssertEqual(manager.seasonalTheme.accentColorLight, "#C2410C")
        XCTAssertEqual(manager.seasonalTheme.accentColorDark, "#FB923C")
        XCTAssertEqual(manager.seasonalTheme.bannerTitle, "Autumn Melodies")

        XCTAssertTrue(manager.paywallPromo.isEnabled)
        XCTAssertEqual(manager.paywallPromo.badgeText, "50% OFF")
        XCTAssertEqual(manager.paywallPromo.headline, "Special Promo")
    }

    // MARK: - Legacy Flat Fields Fallback

    func testApplyLegacyFlatFieldsFallback() {
        let payload: [String: Any] = [
            "download_enabled": true,
            "youtube_auth_enabled": true,
            "video_playbacktoggle": false,
            "dev_mode_enabled": true,
            "appearance_settings": true,
            "review_mode_enabled": false,
            "free_skip_limit": 8,
            "free_download_limit": 3,
            "premium_enabled": true,
            "lifetime_enabled": true,
            "audio_bitrate_low": 64000,
            "audio_bitrate_medium": 128000,
            "audio_bitrate_high": 256000,
            "anim_bouncy_response": 0.3,
            "anim_bouncy_damping": 0.6,
            "home_m_carousel_heig": 110,
            "home_mood_item_width": 180,
            "home_m_grid_row_heig": 48,
            "min_required_version": "1.0.9",
            "recommended_version": "1.0.9",
            "force_update_message": "Update available",
            "app_store_url": "https://example.com",
            "update_changelog": "Bug fixes"
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)

        let manager = FeatureFlagManager(defaults: testDefaults)
        let result = manager.applyRemoteConfigData(data)

        XCTAssertTrue(result)
        XCTAssertTrue(manager.isDownloadEnabled)
        XCTAssertTrue(manager.isYouTubeAuthEnabled)
        XCTAssertFalse(manager.isVideoPlaybackEnabled)
        XCTAssertTrue(manager.isDevModeEnabled)
        XCTAssertFalse(manager.isReviewModeEnabled)
        XCTAssertEqual(manager.freeSkipLimit, 8)
        XCTAssertEqual(manager.freeDownloadLimit, 3)
        XCTAssertEqual(manager.minRequiredVersion, "1.0.9")

        XCTAssertFalse(manager.isEditorialEnabled)
        XCTAssertNil(manager.activeAnnouncement)
        XCTAssertFalse(manager.seasonalTheme.isEnabled)
        XCTAssertFalse(manager.paywallPromo.isEnabled)
    }

    // MARK: - Corrupt Payload Fails Closed

    func testCorruptPayloadFailsClosed() {
        let manager = FeatureFlagManager(defaults: testDefaults)
        let invalidData = Data("invalid json".utf8)

        let result = manager.applyRemoteConfigData(invalidData)

        XCTAssertFalse(result)
        XCTAssertEqual(manager.playbackControls, .failClosed)
    }
}
