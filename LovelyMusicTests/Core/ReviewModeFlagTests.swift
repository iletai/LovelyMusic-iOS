import XCTest

@testable import LovelyMusic

/// Verifies the `review_mode_enabled` CMS flag drives:
///   1. `FeatureFlagManager.isReviewModeEnabled` is hydrated synchronously from
///      the UserDefaults cache during `init` (so DI sees the right value before
///      any network fetch).
///   2. `DIContainer` selects `Demo*Repository` when the flag is `true` and the
///      real `InnerTube`/`Player` repositories when `false`.
///   3. The audio engine's stream headers are toggled accordingly (demo plays
///      bundled MP3s; YouTube needs custom CDN headers).
@MainActor
final class ReviewModeFlagTests: XCTestCase {

    private let cacheKey = "feature_flags_cache"
    private var savedCache: Data?

    override func setUp() async throws {
        try await super.setUp()
        // Preserve any real cached flags so tests don't pollute developer state.
        savedCache = UserDefaults.standard.data(forKey: cacheKey)
        UserDefaults.standard.removeObject(forKey: cacheKey)
    }

    override func tearDown() async throws {
        if let savedCache {
            UserDefaults.standard.set(savedCache, forKey: cacheKey)
        } else {
            UserDefaults.standard.removeObject(forKey: cacheKey)
        }
        savedCache = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Writes a minimal `RemoteConfig` JSON payload to the UserDefaults cache.
    /// Only `review_mode_enabled` is set; all other fields fall back to defaults.
    /// Keys must match the `CodingKeys` snake_case mapping in `FeatureFlagManager.RemoteConfig`.
    private func seedCachedReviewMode(_ enabled: Bool) {
        let payload: [String: Any] = ["review_mode_enabled": enabled]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        UserDefaults.standard.set(data, forKey: cacheKey)
    }

    // MARK: - FeatureFlagManager hydration

    func testFlagManagerReadsCachedReviewModeTrue() {
        seedCachedReviewMode(true)

        let manager = FeatureFlagManager()

        XCTAssertTrue(
            manager.isReviewModeEnabled,
            "isReviewModeEnabled must reflect the cached value at init"
        )
    }

    func testFlagManagerReadsCachedReviewModeFalse() {
        seedCachedReviewMode(false)

        let manager = FeatureFlagManager()

        XCTAssertFalse(
            manager.isReviewModeEnabled,
            "isReviewModeEnabled must reflect the cached value at init"
        )
    }

    func testFlagManagerDefaultsToDemoModeWhenNoCache() {
        // Cache cleared in setUp.
        let manager = FeatureFlagManager()

        XCTAssertTrue(
            manager.isReviewModeEnabled,
            "Default must be true (fail-safe demo mode) when no cache exists — CMS enables live mode explicitly so a reviewer never sees live content on a failed fetch"
        )
    }

    // MARK: - DIContainer repository wiring

    func testDIContainerWiresDemoRepositoriesWhenReviewModeEnabled() {
        seedCachedReviewMode(true)
        let manager = FeatureFlagManager()
        XCTAssertTrue(manager.isReviewModeEnabled)

        let container = DIContainer(featureFlagManager: manager)

        XCTAssertTrue(
            container.innerTubeRepository is DemoContentRepository,
            "Review mode ON must wire DemoContentRepository, got \(type(of: container.innerTubeRepository))"
        )
        XCTAssertTrue(
            container.playerRepository is DemoPlayerRepository,
            "Review mode ON must wire DemoPlayerRepository, got \(type(of: container.playerRepository))"
        )
        XCTAssertTrue(
            container.audioEngine.streamHeaders.isEmpty,
            "Demo playback uses bundled MP3s — no CDN auth headers expected"
        )
    }

    func testDIContainerWiresInnerTubeRepositoriesWhenReviewModeDisabled() {
        seedCachedReviewMode(false)
        let manager = FeatureFlagManager()
        XCTAssertFalse(manager.isReviewModeEnabled)

        let container = DIContainer(featureFlagManager: manager)

        XCTAssertFalse(
            container.innerTubeRepository is DemoContentRepository,
            "Review mode OFF must NOT wire DemoContentRepository"
        )
        XCTAssertFalse(
            container.playerRepository is DemoPlayerRepository,
            "Review mode OFF must NOT wire DemoPlayerRepository"
        )
        // Real path goes through the cache decorator wrapping InnerTubeRepository.
        XCTAssertTrue(
            container.innerTubeRepository is CachedInnerTubeRepository,
            "Review mode OFF must wire CachedInnerTubeRepository, got \(type(of: container.innerTubeRepository))"
        )
        XCTAssertTrue(
            container.playerRepository is PlayerRepository,
            "Review mode OFF must wire real PlayerRepository, got \(type(of: container.playerRepository))"
        )
        XCTAssertEqual(
            container.audioEngine.streamHeaders,
            AppConstants.youtubeStreamHeaders,
            "YouTube CDN requires custom request headers on AVURLAsset"
        )
    }

    // MARK: - Toggle semantics across launches (cache-backed)

    /// Simulates the user-visible flow: build DI with cached value, then a CMS
    /// fetch flips the cache. The current launch's repos remain frozen, but a
    /// fresh `FeatureFlagManager` (next cold launch) must see the new value.
    func testToggleAppliesOnNextColdLaunchViaCache() {
        // Launch 1: review mode ON → demo repos.
        seedCachedReviewMode(true)
        let firstLaunchManager = FeatureFlagManager()
        let firstContainer = DIContainer(featureFlagManager: firstLaunchManager)
        XCTAssertTrue(firstContainer.innerTubeRepository is DemoContentRepository)

        // CMS toggles OFF and the new value is written to cache (as fetchFlags would do).
        seedCachedReviewMode(false)

        // Launch 2: a fresh manager reads the new cached value → real repos.
        let secondLaunchManager = FeatureFlagManager()
        XCTAssertFalse(secondLaunchManager.isReviewModeEnabled)
        let secondContainer = DIContainer(featureFlagManager: secondLaunchManager)
        XCTAssertTrue(secondContainer.innerTubeRepository is CachedInnerTubeRepository)
        XCTAssertTrue(secondContainer.playerRepository is PlayerRepository)
    }
}
