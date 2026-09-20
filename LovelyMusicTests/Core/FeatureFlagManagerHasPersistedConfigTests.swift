import XCTest

@testable import LovelyMusic

/// Group C — C1: `FeatureFlagManager.hasPersistedConfig` semantics.
///
/// The bootstrap gate in `LovelyMusicApp` uses this flag to decide whether to
/// block UI on a CMS fetch (true first install) or proceed with cached values
/// (subsequent launches). It is **purely additive** — it does not influence
/// the precedence chain (default → cache → CMS). D-Q2 LOCKED.
@MainActor
final class FeatureFlagManagerHasPersistedConfigTests: XCTestCase {

    private let cacheKey = "feature_flags_cache"
    private var testDefaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        let suiteName = "test_\(UUID().uuidString)"
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

    func testHasPersistedConfigIsFalseOnFreshInstall() {
        // No cache present in isolated defaults.
        let manager = FeatureFlagManager(defaults: testDefaults)

        XCTAssertFalse(
            manager.hasPersistedConfig,
            "A fresh install (empty UserDefaults) must report no persisted config so the bootstrap gate engages"
        )
    }

    func testHasPersistedConfigIsTrueWithValidCache() {
        let payload: [String: Any] = ["review_mode_enabled": false]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        testDefaults.set(data, forKey: cacheKey)

        let manager = FeatureFlagManager(defaults: testDefaults)

        XCTAssertTrue(
            manager.hasPersistedConfig,
            "A valid cached payload must mark the manager as persisted so subsequent launches skip the gate"
        )
    }

    func testHasPersistedConfigIsFalseWithCorruptCache() {
        testDefaults.set(Data("{not-json".utf8), forKey: cacheKey)

        let manager = FeatureFlagManager(defaults: testDefaults)

        XCTAssertFalse(
            manager.hasPersistedConfig,
            "Corrupt cache must be treated as no cache — bootstrap gate engages and a fresh fetch is attempted"
        )
    }

    /// D-Q2 preservation check: `hasPersistedConfig` is purely diagnostic and
    /// must not alter `isReviewModeEnabled`'s value at any point in the
    /// precedence chain.
    func testHasPersistedConfigDoesNotAffectReviewModeDefault() {
        // Empty cache → isReviewModeEnabled stays at compiled fail-safe default `true`.
        let manager = FeatureFlagManager(defaults: testDefaults)

        XCTAssertFalse(manager.hasPersistedConfig)
        XCTAssertTrue(
            manager.isReviewModeEnabled,
            "Default value must remain `true` (fail-safe demo mode) regardless of `hasPersistedConfig`"
        )
    }

    func testHasPersistedConfigDoesNotAffectReviewModeFromCache() {
        let payload: [String: Any] = ["review_mode_enabled": false]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        testDefaults.set(data, forKey: cacheKey)

        let manager = FeatureFlagManager(defaults: testDefaults)

        XCTAssertTrue(manager.hasPersistedConfig)
        XCTAssertFalse(
            manager.isReviewModeEnabled,
            "Cached value (`false`) must override the default — precedence chain unchanged"
        )
    }
}
