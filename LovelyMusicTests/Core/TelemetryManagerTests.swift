import XCTest
@testable import LovelyMusic

final class TelemetryManagerTests: XCTestCase {
    final class MockAnalyticsProvider: AnalyticsTrackerProtocol, @unchecked Sendable {
        var loggedEvents: [(name: String, params: [String: Any]?)] = []
        var userProperties: [String: String?] = [:]

        func logEvent(_ name: String, parameters: [String: Any]?) {
            loggedEvents.append((name, parameters))
        }
        func setUserProperty(_ value: String?, forName name: String) {
            userProperties[name] = value
        }
    }

    final class MockCrashProvider: CrashLoggerProtocol, @unchecked Sendable {
        var recordedErrors: [(error: Error, additionalInfo: [String: Any]?)] = []
        var logs: [String] = []
        var userId: String?

        func recordError(_ error: Error, additionalInfo: [String: Any]?) {
            recordedErrors.append((error, additionalInfo))
        }
        func log(_ message: String) {
            logs.append(message)
        }
        func setUserId(_ userId: String?) {
            self.userId = userId
        }
    }

    func testTelemetryManagerDispatchesToProviders() {
        let mockAnalytics = MockAnalyticsProvider()
        let mockCrash = MockCrashProvider()
        let manager = TelemetryManager(analyticsProvider: mockAnalytics, crashProvider: mockCrash)

        manager.trackEvent("song_play", parameters: ["song_id": "test_123"])
        XCTAssertEqual(mockAnalytics.loggedEvents.count, 1)
        XCTAssertEqual(mockAnalytics.loggedEvents.first?.name, "song_play")
        XCTAssertEqual(mockAnalytics.loggedEvents.first?.params?["song_id"] as? String, "test_123")

        enum DummyError: Error { case failure }
        manager.recordError(DummyError.failure, additionalInfo: ["reason": "stream_failed"])
        XCTAssertEqual(mockCrash.recordedErrors.count, 1)
        XCTAssertEqual(mockCrash.recordedErrors.first?.additionalInfo?["reason"] as? String, "stream_failed")

        manager.logBreadcrumb("testing breadcrumb")
        XCTAssertEqual(mockCrash.logs, ["testing breadcrumb"])

        manager.setUserId("user_456")
        XCTAssertEqual(mockCrash.userId, "user_456")

        manager.setUserProperty("premium", forName: "user_tier")
        XCTAssertEqual(mockAnalytics.userProperties["user_tier"], "premium")
    }

    func testNoOpProvidersDoNotCrash() {
        let noopAnalytics = NoOpAnalyticsProvider()
        noopAnalytics.logEvent("event", parameters: ["k": "v"])
        noopAnalytics.setUserProperty("val", forName: "prop")

        let noopCrash = NoOpCrashProvider()
        enum DummyError: Error { case failure }
        noopCrash.recordError(DummyError.failure, additionalInfo: ["k": "v"])
        noopCrash.log("log")
        noopCrash.setUserId("user")

        let defaultManager = TelemetryManager()
        defaultManager.trackEvent("test")
        defaultManager.recordError(DummyError.failure)
        defaultManager.logBreadcrumb("breadcrumb")
        defaultManager.setUserId("user")
        defaultManager.setUserProperty("val", forName: "prop")
    }

    @MainActor
    func testPlayerViewModelTracksSongPlay() {
        let mockAnalytics = MockAnalyticsProvider()
        let mockCrash = MockCrashProvider()
        let telemetry = TelemetryManager(analyticsProvider: mockAnalytics, crashProvider: mockCrash)

        let engine = AudioEngine()
        let vm = PlayerViewModel(
            audioEngine: engine,
            resolveStreamUseCase: ResolveStreamUseCase(repository: MockPlayerRepository()),
            getLyricsUseCase: GetLyricsUseCase(repository: MockLyricsRepository()),
            managePlaylistUseCase: ManagePlaylistUseCase(repository: MockPlaylistRepository()),
            manageFavoritesUseCase: ManageFavoritesUseCase(repository: MockFavoritesRepository()),
            premiumManager: PremiumManager(),
            getRelatedSongsUseCase: GetRelatedSongsUseCase(repository: MockInnerTubeRepository()),
            telemetryManager: telemetry
        )

        let song = Song(
            id: "track_abc",
            title: "Test Track",
            artistName: "Test Artist",
            artistId: nil,
            albumName: nil,
            albumId: nil,
            duration: 120,
            thumbnailURL: nil
        )

        vm.play(song: song)

        XCTAssertEqual(mockAnalytics.loggedEvents.count, 1)
        XCTAssertEqual(mockAnalytics.loggedEvents.first?.name, "song_play")
        XCTAssertEqual(mockAnalytics.loggedEvents.first?.params?["song_id"] as? String, "track_abc")
        XCTAssertEqual(mockAnalytics.loggedEvents.first?.params?["title"] as? String, "Test Track")
    }
}

private final class MockPlayerRepository: PlayerRepositoryProtocol, @unchecked Sendable {
    func resolveStreamURL(videoId: String) async throws -> (url: String, contentLength: Int64?) {
        ("https://example.com/audio.mp4", 1024)
    }
    func resolveVideoStreamURL(videoId: String) async throws -> (url: String, contentLength: Int64?)? {
        nil
    }
}

private final class MockLyricsRepository: LyricsRepositoryProtocol {
    func getLyrics(title: String, artist: String, duration: Int?) async throws -> SyncedLyrics? {
        nil
    }
}
