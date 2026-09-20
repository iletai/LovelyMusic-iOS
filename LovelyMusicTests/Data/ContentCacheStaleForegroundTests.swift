import XCTest

@testable import LovelyMusic

/// Tests for the foreground-staleness API on `ContentCache` (polish-B4).
/// The cache exposes `lastForegroundedAt`, `touchForeground()`, and
/// `isStale` so `LovelyMusicApp` can decide whether to invalidate the home
/// cache when the app returns from a long background pause.
final class ContentCacheStaleForegroundTests: XCTestCase {

    /// On first launch the cache has never been foregrounded, so it must
    /// report not-stale to avoid invalidating before any content is loaded.
    func test_isStale_returnsFalse_whenNeverForegrounded() async {
        let cache = ContentCache()

        let stale = await cache.isStale
        let last = await cache.lastForegroundedAt

        XCTAssertFalse(stale)
        XCTAssertNil(last)
    }

    /// When more than 15 min elapse between the recorded foreground time and
    /// `now`, the cache is stale.
    func test_isStale_returnsTrue_after15Minutes() async {
        let virtualNow = LockedNow(date: Date(timeIntervalSince1970: 1_000_000))
        let cache = ContentCache(now: { virtualNow.value })

        await cache.touchForeground()
        // Advance virtual clock by 16 min — past the 15 min threshold.
        virtualNow.value = virtualNow.value.addingTimeInterval(16 * 60)

        let stale = await cache.isStale
        XCTAssertTrue(stale)
    }

    /// Calling `touchForeground()` after a stale gap resets the timestamp,
    /// so subsequent reads return false until another long pause.
    func test_touchForeground_resetsStale() async {
        let virtualNow = LockedNow(date: Date(timeIntervalSince1970: 1_000_000))
        let cache = ContentCache(now: { virtualNow.value })

        await cache.touchForeground()
        virtualNow.value = virtualNow.value.addingTimeInterval(20 * 60)
        let staleBefore = await cache.isStale
        XCTAssertTrue(staleBefore, "Pre-condition: cache should be stale before reset")

        // Re-touch on the new "active" transition.
        await cache.touchForeground()

        let staleAfter = await cache.isStale
        XCTAssertFalse(staleAfter, "Cache should not be stale immediately after touchForeground()")
    }
}

/// Mutable wrapper used to simulate clock advancement inside the actor's
/// `now` closure without resorting to global state.
private final class LockedNow: @unchecked Sendable {
    var value: Date
    init(date: Date) { self.value = date }
}
